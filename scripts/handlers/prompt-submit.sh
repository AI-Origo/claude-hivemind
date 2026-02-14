#!/bin/bash
# prompt-submit.sh - Deliver pending messages and inject identity
#
# On UserPromptSubmit:
# 1. Look up this agent via Milvus
# 2. Check for unread messages in Milvus
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

# Look up agent name using TTY first, then session_id
lookup_agent_name() {
  local tty="$1"
  local session_id="$2"
  local agent_name=""

  # Try TTY first (most stable)
  if [[ -n "$tty" ]]; then
    agent_name=$(get_agent_by_tty "$tty" | jq -r '.[0].name // empty')
  fi

  # Fall back to session_id
  if [[ -z "$agent_name" && -n "$session_id" ]]; then
    agent_name=$(get_agent_by_session "$session_id" | jq -r '.[0].name // empty')
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

# Check if Milvus is available
if ! milvus_ready; then
  exit 0
fi

# Get TTY for stable identity lookup
AGENT_TTY=$(get_current_tty)

# Look up agent name
AGENT_NAME=$(lookup_agent_name "$AGENT_TTY" "$SESSION_ID")
if [ -z "$AGENT_NAME" ]; then
  exit 0
fi

# Query pending messages from Milvus
MESSAGES=""
messages_json=$(get_pending_messages "$AGENT_NAME")

# Process each message
message_ids="[]"
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  msg_id=$(echo "$line" | jq -r '.id // empty')
  [[ -z "$msg_id" ]] && continue

  from=$(echo "$line" | jq -r '.from_agent // "unknown"')
  body=$(echo "$line" | jq -r '.body // ""')
  priority=$(echo "$line" | jq -r '.priority // "normal"')
  ts_epoch=$(echo "$line" | jq -r '.created_at // 0')
  ts=$(epoch_to_iso "$ts_epoch")

  priority_prefix=""
  [ "$priority" = "urgent" ] && priority_prefix="[URGENT] "
  [ "$priority" = "high" ] && priority_prefix="[HIGH] "

  if [ -n "$MESSAGES" ]; then
    MESSAGES="$MESSAGES\n"
  fi
  MESSAGES="${MESSAGES}${priority_prefix}[HIVE AGENT MESSAGE] From $from ($ts): $body"

  # Collect message IDs for marking as delivered
  message_ids=$(echo "$message_ids" | jq --arg id "$msg_id" '. + [$id]')
done < <(echo "$messages_json" | jq -c '.[]' 2>/dev/null || echo "")

# Mark messages as delivered
if [[ $(echo "$message_ids" | jq 'length') -gt 0 ]]; then
  mark_messages_delivered "$message_ids"
fi

# Track delegation: if messages came from other agents, set delegated_by flag
if [ -n "$MESSAGES" ]; then
  SENDERS=""
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    sender=$(echo "$line" | jq -r '.from_agent // empty')
    [[ -z "$sender" ]] && continue
    if [ -z "$SENDERS" ]; then
      SENDERS="$sender"
    elif ! echo "$SENDERS" | grep -qw "$sender"; then
      SENDERS="$SENDERS,$sender"
    fi
  done < <(echo "$messages_json" | jq -c '.[]' 2>/dev/null || echo "")

  if [ -n "$SENDERS" ]; then
    # Merge with existing delegated_by flag (don't overwrite)
    existing=$(get_agent_flag "$AGENT_NAME" "delegated_by")
    if [ -n "$existing" ]; then
      for s in $(echo "$SENDERS" | tr ',' '\n'); do
        echo "$existing" | grep -qw "$s" || existing="$existing,$s"
      done
      SENDERS="$existing"
    fi
    set_agent_flag "$AGENT_NAME" "delegated_by" "$SENDERS"
  fi
fi

# Output messages if any
if [ -n "$MESSAGES" ]; then
  echo "[HIVEMIND MESSAGES]"
  echo -e "$MESSAGES"
  echo ""
fi

# Check for active tasks assigned to this agent
active_tasks=$(milvus_query "tasks" "assignee == $(db_quote "$AGENT_NAME") and state == \"in_progress\"" "seq_id,title,state" 100)
active_tasks=$(echo "$active_tasks" | jq -c 'sort_by(.seq_id)')
TASK_REMINDER=""
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  task_id=$(echo "$line" | jq -r '.seq_id // empty')
  [[ -z "$task_id" ]] && continue

  task_title=$(echo "$line" | jq -r '.title // ""')
  task_state=$(echo "$line" | jq -r '.state // ""')

  if [ -n "$TASK_REMINDER" ]; then
    TASK_REMINDER="$TASK_REMINDER, "
  fi
  TASK_REMINDER="${TASK_REMINDER}#$task_id: $task_title [$task_state]"
done < <(echo "$active_tasks" | jq -c '.[]' 2>/dev/null || echo "")

# Check for tasks in review that this agent might want to review
review_tasks=$(milvus_query "tasks" "state == \"review\" and assignee != $(db_quote "$AGENT_NAME")" "seq_id,title,assignee" 3)
review_tasks=$(echo "$review_tasks" | jq -c 'sort_by(.seq_id)')
REVIEW_REMINDER=""
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  task_id=$(echo "$line" | jq -r '.seq_id // empty')
  [[ -z "$task_id" ]] && continue

  task_title=$(echo "$line" | jq -r '.title // ""')
  task_assignee=$(echo "$line" | jq -r '.assignee // ""')

  if [ -n "$REVIEW_REMINDER" ]; then
    REVIEW_REMINDER="$REVIEW_REMINDER, "
  fi
  REVIEW_REMINDER="${REVIEW_REMINDER}#$task_id: $task_title (by $task_assignee)"
done < <(echo "$review_tasks" | jq -c '.[]' 2>/dev/null || echo "")

# Inject task tracking section
echo "[HIVEMIND TASK TRACKING]"

if [ -n "$TASK_REMINDER" ]; then
  echo "You are agent $AGENT_NAME. Active tasks: $TASK_REMINDER"
  echo "If the user's message changes what you're working on, call hive_task with a short description of the new activity. Only clear your task (empty description) when the work is fully complete and you have nothing left to do."
else
  echo "You are agent $AGENT_NAME. You have no active task. IMPORTANT: Your very first action must be to call hive_task with a short description of what you're about to do. Do this before any other tool call. Keep it set across turns until the work is fully complete, then clear it (empty description). Never set it to 'idle' or 'waiting'."
fi

if [ -n "$REVIEW_REMINDER" ]; then
  echo "Tasks awaiting review: $REVIEW_REMINDER"
fi

echo ""
echo "[HIVEMIND DELEGATION PROTOCOL]"
echo "When delegating work to other agents: (1) DELEGATE EARLY - If your plan involves work that can be parallelized, delegate to idle agents as soon as possible so work proceeds concurrently. (2) Assign ONE task at a time - research what's needed, assign it, wait for acknowledgment before the next. Do NOT bulk-assign. (3) After delegating, if you have no other work, clear your task and STOP. You will be woken up when agents report back. Do NOT poll or pester for status."

exit 0
