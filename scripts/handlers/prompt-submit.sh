#!/bin/bash
# prompt-submit.sh - Deliver pending messages and inject identity
#
# On UserPromptSubmit:
# 1. Look up this agent via database
# 2. Check for unread messages in database
# 3. Inject identity, messages, and task reminders as context

set -uo pipefail

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

# Read input from stdin
INPUT=$(cat)

# Get working directory and session ID from hook input
WORKING_DIR=$(echo "$INPUT" | jq -r '.cwd // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')

if [ -z "$WORKING_DIR" ] || [ -z "$SESSION_ID" ]; then
  exit 0
fi

# Find hivemind directory
HIVEMIND_DIR=$(find_hivemind_dir "$WORKING_DIR")
if [ -z "$HIVEMIND_DIR" ]; then
  exit 0
fi
export HIVEMIND_DIR

# Ensure database is initialized
db_ensure_initialized

# Get TTY for stable identity lookup
AGENT_TTY=$(get_current_tty)

# Look up agent name from database
AGENT_NAME=$(lookup_agent_name "$AGENT_TTY" "$SESSION_ID")
if [ -z "$AGENT_NAME" ]; then
  exit 0
fi

# Query pending messages from database
MESSAGES=""
messages_json=$(db_query "SELECT id, from_agent, body, priority, created_at FROM messages WHERE to_agent = $(db_quote "$AGENT_NAME") AND delivered_at IS NULL ORDER BY created_at")

# Process each message
message_ids=""
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  msg_id=$(echo "$line" | jq -r '.id // empty')
  [[ -z "$msg_id" ]] && continue

  from=$(echo "$line" | jq -r '.from_agent // "unknown"')
  body=$(echo "$line" | jq -r '.body // ""')
  priority=$(echo "$line" | jq -r '.priority // "normal"')
  ts=$(echo "$line" | jq -r '.created_at // ""')

  priority_prefix=""
  [ "$priority" = "urgent" ] && priority_prefix="[URGENT] "
  [ "$priority" = "high" ] && priority_prefix="[HIGH] "

  if [ -n "$MESSAGES" ]; then
    MESSAGES="$MESSAGES\n"
  fi
  MESSAGES="${MESSAGES}${priority_prefix}[HIVE AGENT MESSAGE] From $from ($ts): $body"

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

# Output messages if any
if [ -n "$MESSAGES" ]; then
  echo "[HIVEMIND MESSAGES]"
  echo -e "$MESSAGES"
  echo ""
fi

# Check for claimed tasks assigned to this agent
claimed_tasks=$(db_query "SELECT id, title, state FROM tasks WHERE assignee = $(db_quote "$AGENT_NAME") AND state IN ('claimed', 'in_progress') ORDER BY id")
TASK_REMINDER=""
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  task_id=$(echo "$line" | jq -r '.id // empty')
  [[ -z "$task_id" ]] && continue

  task_title=$(echo "$line" | jq -r '.title // ""')
  task_state=$(echo "$line" | jq -r '.state // ""')

  if [ -n "$TASK_REMINDER" ]; then
    TASK_REMINDER="$TASK_REMINDER, "
  fi
  TASK_REMINDER="${TASK_REMINDER}#$task_id: $task_title [$task_state]"
done < <(echo "$claimed_tasks" | jq -c '.[]' 2>/dev/null || echo "")

# Check for tasks in review that this agent might want to review
review_tasks=$(db_query "SELECT id, title, assignee FROM tasks WHERE state = 'review' AND assignee != $(db_quote "$AGENT_NAME") ORDER BY id LIMIT 3")
REVIEW_REMINDER=""
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  task_id=$(echo "$line" | jq -r '.id // empty')
  [[ -z "$task_id" ]] && continue

  task_title=$(echo "$line" | jq -r '.title // ""')
  task_assignee=$(echo "$line" | jq -r '.assignee // ""')

  if [ -n "$REVIEW_REMINDER" ]; then
    REVIEW_REMINDER="$REVIEW_REMINDER, "
  fi
  REVIEW_REMINDER="${REVIEW_REMINDER}#$task_id: $task_title (by $task_assignee)"
done < <(echo "$review_tasks" | jq -c '.[]' 2>/dev/null || echo "")

# Always inject task recording reminder
echo "[HIVEMIND TASK TRACKING]"
echo "You are agent $AGENT_NAME. Record your current task using hive_task so other agents can see what you're working on. When you finish processing or are waiting for user input, clear your task by calling hive_task with an empty description - never set it to 'idle', 'waiting', or similar."

if [ -n "$TASK_REMINDER" ]; then
  echo "Your active tasks: $TASK_REMINDER"
fi

if [ -n "$REVIEW_REMINDER" ]; then
  echo "Tasks awaiting review: $REVIEW_REMINDER"
fi

echo ""
echo "[HIVEMIND DELEGATION PROTOCOL]"
echo "When delegating work to other agents: (1) DELEGATE EARLY - If your plan involves work that can be parallelized, delegate to idle agents as soon as possible so work proceeds concurrently. (2) Assign ONE task at a time - research what's needed, assign it, wait for acknowledgment before the next. Do NOT bulk-assign. (3) After delegating, if you have no other work, clear your task and STOP. You will be woken up when agents report back. Do NOT poll or pester for status."

exit 0
