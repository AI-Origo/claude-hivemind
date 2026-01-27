#!/bin/bash
# pre-tool.sh - PreToolUse handler for agent coordination
#
# Runs before EVERY tool execution:
# 1. Message delivery - check database and deliver messages (silent if none)
#
# Tool-specific handling:
# - EnterPlanMode: Remind to set task as "Planning: <topic>"
# - ExitPlanMode: Task tracking reminder + delegation guidance
# - Hivemind tools: Session ID injection
# - Write/Edit: File locking and conflict warnings

set -euo pipefail

# Get script directory and source helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/db.sh"

# Find .hivemind directory by searching up from given path
find_hivemind_dir() {
  local dir="$1"
  local dirname="${HIVEMIND_DIRNAME:-.hivemind}"
  while [[ "$dir" != "/" ]]; do
    if [[ -d "$dir/$dirname" ]]; then
      echo "$dir/$dirname"
      return 0
    fi
    dir=$(dirname "$dir")
  done
  return 1
}

# Get current TTY from process hierarchy
get_current_tty() {
  local tty=""
  if command -v tty &>/dev/null; then
    tty=$(tty 2>/dev/null || true)
  fi
  if [[ -z "$tty" || "$tty" == "not a tty" ]]; then
    # Walk up process tree to find a process with a TTY
    local pid=$$
    while [[ -n "$pid" && "$pid" != "1" ]]; do
      local ptty=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
      if [[ -n "$ptty" && "$ptty" != "??" ]]; then
        tty="/dev/$ptty"
        break
      fi
      pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    done
  fi
  [[ "$tty" == "not a tty" || "$tty" == "??" ]] && tty=""
  echo "$tty"
}

# Look up agent name using TTY first, then session_id from database
lookup_agent_name() {
  local tty="$1"
  local session_id="$2"
  local agent_name=""

  # Try TTY first (most stable)
  if [[ -n "$tty" ]]; then
    agent_name=$(db_query "SELECT name FROM agents WHERE tty = $(db_quote "$tty") LIMIT 1" | jq -r '.[0].name // empty')
  fi

  # Fall back to session_id
  if [[ -z "$agent_name" && -n "$session_id" ]]; then
    agent_name=$(db_query "SELECT name FROM agents WHERE session_id = $(db_quote "$session_id") LIMIT 1" | jq -r '.[0].name // empty')
  fi

  echo "$agent_name"
}

# Debug log file
DEBUG_LOG="${HIVEMIND_DEBUG_LOG:-/tmp/hivemind-pre-tool-debug.log}"

# Read input from stdin
INPUT=$(cat)

# Get working directory, session ID, and tool info
WORKING_DIR=$(echo "$INPUT" | jq -r '.cwd // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# Debug logging
{
  echo "=== $(date) PreToolUse ==="
  echo "TOOL_NAME: '$TOOL_NAME'"
  echo "SESSION_ID: '$SESSION_ID'"
  echo "WORKING_DIR: '$WORKING_DIR'"
} >> "$DEBUG_LOG" 2>&1

if [ -z "$WORKING_DIR" ] || [ -z "$SESSION_ID" ]; then
  echo "EXIT: Missing WORKING_DIR or SESSION_ID" >> "$DEBUG_LOG"
  exit 0
fi

# ============================================================================
# MESSAGE DELIVERY (runs for ALL tools, silent if no messages)
# ============================================================================
HIVEMIND_DIR=$(find_hivemind_dir "$WORKING_DIR")
if [ -z "$HIVEMIND_DIR" ]; then
  echo "EXIT: No .hivemind directory found" >> "$DEBUG_LOG"
  exit 0
fi
export HIVEMIND_DIR

# Ensure database is initialized
db_ensure_initialized

# Get TTY for stable identity lookup
AGENT_TTY=$(get_current_tty)

# Look up agent name from database
AGENT_NAME=$(lookup_agent_name "$AGENT_TTY" "$SESSION_ID")

MESSAGES_OUTPUT=""
if [ -n "$AGENT_NAME" ]; then
  # Query pending messages from database
  messages_json=$(db_query "SELECT id, from_agent, body, priority, created_at FROM messages WHERE to_agent = $(db_quote "$AGENT_NAME") AND delivered_at IS NULL ORDER BY created_at")

  # Process each message
  message_ids=""
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    msg_id=$(echo "$line" | jq -r '.id // empty')
    [[ -z "$msg_id" ]] && continue

    FROM=$(echo "$line" | jq -r '.from_agent // "unknown"')
    TIMESTAMP=$(echo "$line" | jq -r '.created_at // ""')
    CONTENT=$(echo "$line" | jq -r '.body // ""')
    PRIORITY=$(echo "$line" | jq -r '.priority // "normal"')

    PRIORITY_PREFIX=""
    [ "$PRIORITY" = "urgent" ] && PRIORITY_PREFIX="[URGENT] "
    [ "$PRIORITY" = "high" ] && PRIORITY_PREFIX="[HIGH] "

    MESSAGES_OUTPUT="${MESSAGES_OUTPUT}${PRIORITY_PREFIX}[HIVE AGENT MESSAGE] From ${FROM} (${TIMESTAMP}): ${CONTENT}\n"

    # Collect message IDs for marking as delivered
    if [[ -n "$message_ids" ]]; then
      message_ids="${message_ids}, $(db_quote "$msg_id")"
    else
      message_ids="$(db_quote "$msg_id")"
    fi
  done < <(echo "$messages_json" | jq -c '.[]' 2>/dev/null || echo "")

  # Mark messages as delivered
  if [[ -n "$message_ids" ]]; then
    db_exec "UPDATE messages SET delivered_at = now() WHERE id IN ($message_ids)"
  fi
fi

# Store for later output
DELIVERY_OUTPUT=""
if [ -n "$MESSAGES_OUTPUT" ]; then
  DELIVERY_OUTPUT="[HIVEMIND MESSAGES]\n${MESSAGES_OUTPUT}"
fi

echo "Message delivery check: AGENT_NAME='$AGENT_NAME', has_messages=$([[ -n \"$MESSAGES_OUTPUT\" ]] && echo yes || echo no)" >> "$DEBUG_LOG"

# ============================================================================
# TOOL-SPECIFIC HANDLING
# ============================================================================

# Handle EnterPlanMode - remind agent to set task as "Planning: <topic>"
if [[ "$TOOL_NAME" == "EnterPlanMode" ]]; then
  echo "ENTER PLAN MODE detected for agent $AGENT_NAME" >> "$DEBUG_LOG"

  COMBINED_OUTPUT=""

  if [ -n "$DELIVERY_OUTPUT" ]; then
    COMBINED_OUTPUT="${DELIVERY_OUTPUT}"
  fi

  if [ -n "$AGENT_NAME" ]; then
    COMBINED_OUTPUT="${COMBINED_OUTPUT}[HIVEMIND TASK TRACKING] Agent ${AGENT_NAME}: You are entering plan mode. Set your task to 'Planning: <short topic>' using hive_task so other agents know you are planning (e.g., 'Planning: auth refactor' or 'Planning: API endpoints').\n\n"
  fi

  if [ -n "$COMBINED_OUTPUT" ]; then
    ESCAPED_OUTPUT=$(printf '%s' "$COMBINED_OUTPUT" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
    printf '{"message": "%s"}' "$ESCAPED_OUTPUT"
  fi
  exit 0
fi

# Handle ExitPlanMode - remind agent to record task + show delegation guidance
if [[ "$TOOL_NAME" == "ExitPlanMode" ]]; then
  echo "EXIT PLAN MODE detected for agent $AGENT_NAME" >> "$DEBUG_LOG"

  COMBINED_OUTPUT=""

  if [ -n "$DELIVERY_OUTPUT" ]; then
    COMBINED_OUTPUT="${DELIVERY_OUTPUT}"
  fi

  if [ -n "$AGENT_NAME" ]; then
    COMBINED_OUTPUT="${COMBINED_OUTPUT}[HIVEMIND TASK TRACKING] Plan accepted. Agent ${AGENT_NAME}: Record this plan as your current task using hive_task so other agents can see what you are working on.\n\n"
  fi

  # Build delegation guidance from database
  DELEGATION_OUTPUT=""
  IDLE_AGENTS=""
  IDLE_COUNT=0

  other_agents_json=$(db_query "SELECT name, current_task FROM agents WHERE name != $(db_quote "$AGENT_NAME") AND ended_at IS NULL")
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    OTHER_NAME=$(echo "$line" | jq -r '.name // empty')
    [[ -z "$OTHER_NAME" ]] && continue

    OTHER_TASK=$(echo "$line" | jq -r '.current_task // empty')

    if [ -n "$OTHER_TASK" ]; then
      DELEGATION_OUTPUT="${DELEGATION_OUTPUT}  - ${OTHER_NAME}: ${OTHER_TASK}\n"
    else
      IDLE_AGENTS="${IDLE_AGENTS}  - ${OTHER_NAME}\n"
      ((IDLE_COUNT++)) || true
    fi
  done < <(echo "$other_agents_json" | jq -c '.[]' 2>/dev/null || echo "")

  if [ -n "$DELEGATION_OUTPUT" ]; then
    COMBINED_OUTPUT="${COMBINED_OUTPUT}[HIVEMIND COLLABORATION] Other agents are working on:\n${DELEGATION_OUTPUT}\nWhen you encounter work that overlaps with another agent's task, delegate it to them rather than doing it yourself. When delegating, include all relevant context: file paths, implementation details, and any decisions you've already made.\n\n"
  fi

  if [ $IDLE_COUNT -gt 0 ]; then
    COMBINED_OUTPUT="${COMBINED_OUTPUT}[HIVEMIND DELEGATION] The following agent(s) are idle and available for delegation:\n${IDLE_AGENTS}\nDelegation rules:\n1. DELEGATE EARLY: If your plan involves work that can be parallelized, delegate to idle agents AS SOON AS POSSIBLE so work proceeds concurrently. Do not wait until you've finished your own tasks.\n2. ONE TASK AT A TIME: Research what's needed, then assign to one agent. Wait for their acknowledgment or questions before the next delegation. Do not bulk-assign.\n3. AFTER DELEGATING: If you have delegated work and have nothing else to do, clear your task (hive_task with empty description) and STOP. You will be woken up when agents report back. Do NOT poll or pester for status.\n4. CONTEXT IS KEY: Include file paths, implementation details, and decisions so agents can start immediately.\n\n"
  fi

  if [ -n "$COMBINED_OUTPUT" ]; then
    ESCAPED_OUTPUT=$(printf '%s' "$COMBINED_OUTPUT" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
    printf '{"message": "%s"}' "$ESCAPED_OUTPUT"
  fi
  exit 0
fi

# Handle hivemind tools that need session_id and tty injection
if [[ "$TOOL_NAME" == *"hive_whoami"* ]] || [[ "$TOOL_NAME" == *"hive_task"* ]] || [[ "$TOOL_NAME" == *"hive_message"* ]] || [[ "$TOOL_NAME" == *"hive_inbox"* ]]; then
  TOOL_INPUT=$(echo "$INPUT" | jq -c '.tool_input // {}')

  if [ -n "$DELIVERY_OUTPUT" ]; then
    ESCAPED_MSG=$(printf '%s' "$DELIVERY_OUTPUT" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
    OUTPUT=$(echo "$TOOL_INPUT" | jq -c \
      --arg sid "$SESSION_ID" \
      --arg tty "$AGENT_TTY" \
      --arg msg "$ESCAPED_MSG" \
      '{message:$msg,hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",updatedInput:(. + {session_id:$sid,tty:$tty})}}')
  else
    OUTPUT=$(echo "$TOOL_INPUT" | jq -c \
      --arg sid "$SESSION_ID" \
      --arg tty "$AGENT_TTY" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",updatedInput:(. + {session_id:$sid,tty:$tty})}}')
  fi

  echo "OUTPUT for hivemind tool (matched '$TOOL_NAME'): $OUTPUT" >> "$DEBUG_LOG"
  printf '%s' "$OUTPUT"
  exit 0
fi

# For Write/Edit, we need a file path
# For other tools, just deliver messages if any and exit
if [ -z "$FILE_PATH" ] || { [ "$TOOL_NAME" != "Write" ] && [ "$TOOL_NAME" != "Edit" ]; }; then
  if [ -n "$DELIVERY_OUTPUT" ]; then
    ESCAPED_MSG=$(printf '%s' "$DELIVERY_OUTPUT" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
    printf '{"message": "%s"}' "$ESCAPED_MSG"
  fi
  exit 0
fi

# ============================================================================
# WRITE/EDIT FILE LOCKING (using database)
# ============================================================================

# If no agent name, deliver messages and exit
if [ -z "$AGENT_NAME" ]; then
  if [ -n "$DELIVERY_OUTPUT" ]; then
    ESCAPED_MSG=$(printf '%s' "$DELIVERY_OUTPUT" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
    printf '{"message": "%s"}' "$ESCAPED_MSG"
  fi
  exit 0
fi

# Get relative path
REL_PATH="${FILE_PATH#$WORKING_DIR/}"

WARNING=""

# Check if file is locked by another agent in database
lock_info=$(db_query "SELECT agent_name, locked_at FROM file_locks WHERE file_path = $(db_quote "$REL_PATH") LIMIT 1")
LOCK_OWNER=$(echo "$lock_info" | jq -r '.[0].agent_name // empty')

if [ -n "$LOCK_OWNER" ] && [ "$LOCK_OWNER" != "$AGENT_NAME" ]; then
  WARNING="[HIVEMIND WARNING] File '$REL_PATH' is being edited by agent '$LOCK_OWNER'. Consider coordinating to avoid conflicts."
fi

# Create/update lock for this agent in database
# Use INSERT OR REPLACE (upsert) pattern
db_exec "INSERT OR REPLACE INTO file_locks (file_path, agent_name, locked_at) VALUES ($(db_quote "$REL_PATH"), $(db_quote "$AGENT_NAME"), now())"

# Combine message delivery with any file lock warning
FINAL_OUTPUT=""
if [ -n "$DELIVERY_OUTPUT" ]; then
  FINAL_OUTPUT="${DELIVERY_OUTPUT}"
fi
if [ -n "$WARNING" ]; then
  FINAL_OUTPUT="${FINAL_OUTPUT}${WARNING}"
fi

# Output combined message if there's anything to say
if [ -n "$FINAL_OUTPUT" ]; then
  ESCAPED_OUTPUT=$(printf '%s' "$FINAL_OUTPUT" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
  printf '{"message": "%s"}' "$ESCAPED_OUTPUT"
fi

exit 0
