#!/bin/bash
# pre-tool.sh - PreToolUse handler for agent coordination
#
# Runs before EVERY tool execution:
# 1. Message delivery - check inbox and deliver messages (silent if none)
#
# Tool-specific handling:
# - ExitPlanMode: Task tracking reminder + delegation guidance
# - Hivemind tools: Session ID injection
# - Write/Edit: File locking and conflict warnings

set -euo pipefail

# Debug log file
DEBUG_LOG="${HIVEMIND_DEBUG_LOG:-/tmp/hivemind-pre-tool-debug.log}"

# Read input from stdin
INPUT=$(cat)

# Get working directory, session ID, and tool info
WORKING_DIR=$(echo "$INPUT" | jq -r '.cwd // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# Debug logging - always log to see what tools come through
{
  echo "=== $(date) PreToolUse ==="
  echo "TOOL_NAME: '$TOOL_NAME'"
  echo "SESSION_ID: '$SESSION_ID'"
  echo "WORKING_DIR: '$WORKING_DIR'"
  echo "INPUT (raw):"
  echo "$INPUT" | jq . 2>/dev/null || echo "$INPUT"
  echo ""
} >> "$DEBUG_LOG" 2>&1

if [ -z "$WORKING_DIR" ] || [ -z "$SESSION_ID" ]; then
  echo "EXIT: Missing WORKING_DIR or SESSION_ID" >> "$DEBUG_LOG"
  exit 0
fi

# ============================================================================
# MESSAGE DELIVERY (runs for ALL tools, silent if no messages)
# ============================================================================
HIVEMIND_DIR="$WORKING_DIR/.hivemind"
SESSIONS_DIR="$HIVEMIND_DIR/sessions"
AGENTS_DIR="$HIVEMIND_DIR/agents"

# Look up agent name for this session
SESSION_FILE="$SESSIONS_DIR/$SESSION_ID.txt"
AGENT_NAME=""
if [ -f "$SESSION_FILE" ]; then
  AGENT_NAME=$(cat "$SESSION_FILE")
fi

MESSAGES_OUTPUT=""
if [ -n "$AGENT_NAME" ]; then
  INBOX_DIR="$HIVEMIND_DIR/messages/inbox-$AGENT_NAME"
  if [ -d "$INBOX_DIR" ]; then
    # Collect all messages
    for msg_file in "$INBOX_DIR"/*.json; do
      [ -f "$msg_file" ] || continue

      FROM=$(jq -r '.from // "unknown"' "$msg_file" 2>/dev/null)
      TIMESTAMP=$(jq -r '.timestamp // ""' "$msg_file" 2>/dev/null)
      CONTENT=$(jq -r '.body // ""' "$msg_file" 2>/dev/null)
      URGENT=$(jq -r '.urgent // false' "$msg_file" 2>/dev/null)

      URGENT_PREFIX=""
      if [ "$URGENT" = "true" ]; then
        URGENT_PREFIX="[URGENT] "
      fi

      MESSAGES_OUTPUT="${MESSAGES_OUTPUT}${URGENT_PREFIX}[HIVE AGENT MESSAGE] From ${FROM} (${TIMESTAMP}): ${CONTENT}\n"

      # Consume (delete) the message after reading
      rm -f "$msg_file"
    done
  fi
fi

# Store for later output (will be combined with other outputs)
DELIVERY_OUTPUT=""
if [ -n "$MESSAGES_OUTPUT" ]; then
  DELIVERY_OUTPUT="[HIVEMIND MESSAGES]\n${MESSAGES_OUTPUT}"
fi

echo "Message delivery check: AGENT_NAME='$AGENT_NAME', MESSAGES_OUTPUT='$MESSAGES_OUTPUT'" >> "$DEBUG_LOG"

# ============================================================================
# TOOL-SPECIFIC HANDLING
# ============================================================================

# Handle ExitPlanMode - remind agent to record task + show delegation guidance
if [[ "$TOOL_NAME" == "ExitPlanMode" ]]; then
  echo "EXIT PLAN MODE detected for agent $AGENT_NAME" >> "$DEBUG_LOG"

  COMBINED_OUTPUT=""

  # Add any pending messages first
  if [ -n "$DELIVERY_OUTPUT" ]; then
    COMBINED_OUTPUT="${DELIVERY_OUTPUT}"
  fi

  # Task tracking reminder
  if [ -n "$AGENT_NAME" ]; then
    COMBINED_OUTPUT="${COMBINED_OUTPUT}[HIVEMIND TASK TRACKING] Plan accepted. Agent ${AGENT_NAME}: Record this plan as your current task using hive_task so other agents can see what you are working on.\n\n"
  fi

  # Build delegation guidance from other agents' tasks and track idle agents
  DELEGATION_OUTPUT=""
  IDLE_AGENTS=""
  IDLE_COUNT=0
  if [ -d "$AGENTS_DIR" ]; then
    for agent_file in "$AGENTS_DIR"/*.json; do
      [ -f "$agent_file" ] || continue

      OTHER_NAME=$(jq -r '.name // empty' "$agent_file" 2>/dev/null)
      # Skip self
      if [ "$OTHER_NAME" = "$AGENT_NAME" ]; then
        continue
      fi

      OTHER_TASK=$(jq -r '.task // empty' "$agent_file" 2>/dev/null)
      OTHER_FILES=$(jq -r '.workingOn // [] | join(", ")' "$agent_file" 2>/dev/null)

      # Include agents that have a task set (busy)
      if [ -n "$OTHER_TASK" ] && [ "$OTHER_TASK" != "null" ]; then
        if [ -n "$OTHER_FILES" ]; then
          DELEGATION_OUTPUT="${DELEGATION_OUTPUT}  - ${OTHER_NAME}: ${OTHER_TASK} (files: ${OTHER_FILES})\n"
        else
          DELEGATION_OUTPUT="${DELEGATION_OUTPUT}  - ${OTHER_NAME}: ${OTHER_TASK}\n"
        fi
      else
        # Agent has no task (idle)
        IDLE_AGENTS="${IDLE_AGENTS}  - ${OTHER_NAME}\n"
        ((IDLE_COUNT++)) || true
      fi
    done
  fi

  # Add delegation guidance if other agents have tasks
  if [ -n "$DELEGATION_OUTPUT" ]; then
    COMBINED_OUTPUT="${COMBINED_OUTPUT}[HIVEMIND COLLABORATION] Other agents are working on:\n${DELEGATION_OUTPUT}\nWhen you encounter work that overlaps with another agent's task, delegate it to them rather than doing it yourself. When delegating, include all relevant context: file paths, implementation details, and any decisions you've already made.\n\n"
  fi

  # Add idle agent guidance if any are available
  if [ $IDLE_COUNT -gt 0 ]; then
    COMBINED_OUTPUT="${COMBINED_OUTPUT}[HIVEMIND DELEGATION] The following agent(s) are idle and available for delegation:\n${IDLE_AGENTS}Feel free to delegate subtasks to them using hive_message. When delegating, include all relevant context: file paths, implementation details, and any decisions you've already made so they can start immediately.\n\n"
  fi

  # Output combined message if there's anything to say
  if [ -n "$COMBINED_OUTPUT" ]; then
    # Escape for JSON and use printf -v to handle newlines
    ESCAPED_OUTPUT=$(printf '%s' "$COMBINED_OUTPUT" | sed 's/"/\\"/g' | sed 's/\\n/\\n/g')
    printf '{"message": "%s"}' "$ESCAPED_OUTPUT"
  fi
  exit 0
fi

# Handle hivemind tools that need session_id injection
# These tools need to know which agent is calling
if [[ "$TOOL_NAME" == *"hive_whoami"* ]] || [[ "$TOOL_NAME" == *"hive_task"* ]] || [[ "$TOOL_NAME" == *"hive_message"* ]] || [[ "$TOOL_NAME" == *"hive_read_messages"* ]]; then
  # Merge existing tool_input with session_id (preserves user-provided parameters)
  TOOL_INPUT=$(echo "$INPUT" | jq -c '.tool_input // {}')

  # Build output with session_id injection
  if [ -n "$DELIVERY_OUTPUT" ]; then
    # Include messages in the output
    ESCAPED_MSG=$(printf '%s' "$DELIVERY_OUTPUT" | sed 's/"/\\"/g' | sed 's/\\n/\\n/g')
    OUTPUT=$(echo "$TOOL_INPUT" | jq -c \
      --arg sid "$SESSION_ID" \
      --arg msg "$ESCAPED_MSG" \
      '{message:$msg,hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",updatedInput:(. + {session_id:$sid})}}')
  else
    OUTPUT=$(echo "$TOOL_INPUT" | jq -c \
      --arg sid "$SESSION_ID" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",updatedInput:(. + {session_id:$sid})}}')
  fi

  echo "TOOL_INPUT (original): $TOOL_INPUT" >> "$DEBUG_LOG"
  echo "OUTPUT for hivemind tool (matched '$TOOL_NAME'): $OUTPUT" >> "$DEBUG_LOG"
  # Use printf without newline to ensure clean output
  printf '%s' "$OUTPUT"
  exit 0
fi

# For Write/Edit, we need a file path
# For other tools, just deliver messages if any and exit
if [ -z "$FILE_PATH" ] || { [ "$TOOL_NAME" != "Write" ] && [ "$TOOL_NAME" != "Edit" ]; }; then
  # Deliver any pending messages for non-Write/Edit tools
  if [ -n "$DELIVERY_OUTPUT" ]; then
    ESCAPED_MSG=$(printf '%s' "$DELIVERY_OUTPUT" | sed 's/"/\\"/g' | sed 's/\\n/\\n/g')
    printf '{"message": "%s"}' "$ESCAPED_MSG"
  fi
  exit 0
fi

# ============================================================================
# WRITE/EDIT FILE LOCKING
# ============================================================================
LOCKS_DIR="$HIVEMIND_DIR/locks"
mkdir -p "$LOCKS_DIR"

# If no agent name, deliver messages and exit
if [ -z "$AGENT_NAME" ]; then
  if [ -n "$DELIVERY_OUTPUT" ]; then
    ESCAPED_MSG=$(printf '%s' "$DELIVERY_OUTPUT" | sed 's/"/\\"/g' | sed 's/\\n/\\n/g')
    printf '{"message": "%s"}' "$ESCAPED_MSG"
  fi
  exit 0
fi

# Create a hash of the file path for the lock filename
# Use relative path if possible
REL_PATH="${FILE_PATH#$WORKING_DIR/}"
LOCK_HASH=$(echo -n "$REL_PATH" | md5sum 2>/dev/null | cut -d' ' -f1 || \
            echo -n "$REL_PATH" | md5 2>/dev/null || \
            echo -n "$REL_PATH" | shasum | cut -d' ' -f1)
LOCK_FILE="$LOCKS_DIR/$LOCK_HASH.lock"

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
WARNING=""

# Check if file is locked by another agent
if [ -f "$LOCK_FILE" ]; then
  LOCK_OWNER=$(jq -r '.sessionName // empty' "$LOCK_FILE" 2>/dev/null || true)

  if [ -n "$LOCK_OWNER" ] && [ "$LOCK_OWNER" != "$AGENT_NAME" ]; then
    # File is locked by another agent
    LOCK_PATH=$(jq -r '.filePath // "unknown"' "$LOCK_FILE" 2>/dev/null || echo "$REL_PATH")
    LOCK_TIME=$(jq -r '.lockedAt // ""' "$LOCK_FILE" 2>/dev/null || echo "")

    WARNING="[HIVEMIND WARNING] File '$REL_PATH' is being edited by agent '$LOCK_OWNER'. Consider coordinating to avoid conflicts."
  fi
fi

# Create/update lock for this agent
cat > "$LOCK_FILE" << EOF
{
  "sessionName": "$AGENT_NAME",
  "sessionId": "$SESSION_ID",
  "filePath": "$REL_PATH",
  "lockedAt": "$NOW"
}
EOF

# Update agent's workingOn list
AGENT_FILE="$AGENTS_DIR/$AGENT_NAME.json"
if [ -f "$AGENT_FILE" ]; then
  # Add file to workingOn if not already there
  jq --arg file "$REL_PATH" '
    .workingOn = ((.workingOn // []) | if index($file) then . else . + [$file] end)
  ' "$AGENT_FILE" > "$AGENT_FILE.tmp" && mv "$AGENT_FILE.tmp" "$AGENT_FILE"
fi

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
  ESCAPED_OUTPUT=$(printf '%s' "$FINAL_OUTPUT" | sed 's/"/\\"/g' | sed 's/\\n/\\n/g')
  printf '{"message": "%s"}' "$ESCAPED_OUTPUT"
fi

exit 0
