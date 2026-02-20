#!/bin/bash
# stop.sh - Clear agent task when Claude finishes responding

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

INPUT=$(cat)
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

# Find agent by session_id in Milvus
agent_json=$(get_agent_by_session "$SESSION_ID")
AGENT_NAME=$(echo "$agent_json" | jq -r '.[0].name // empty')

if [ -n "$AGENT_NAME" ]; then
  # Get agent fields
  CURRENT_TASK=$(echo "$agent_json" | jq -r '.[0].current_task // empty')
  tty=$(echo "$agent_json" | jq -r '.[0].tty // empty')
  started_at=$(echo "$agent_json" | jq -r '.[0].started_at // 0')
  ended_at=$(echo "$agent_json" | jq -r '.[0].ended_at // 0')

  # Auto-complete all in_progress/claimed tasks (equivalent to hive_task '')
  active_tasks=$(milvus_query "tasks" "assignee == $(db_quote "$AGENT_NAME") and (state == \"claimed\" or state == \"in_progress\")" "seq_id" 100)
  now=$(get_timestamp)
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    task_seq_id=$(echo "$line" | jq -r '.seq_id // empty')
    [[ -z "$task_seq_id" ]] && continue
    update_task "$task_seq_id" "state" "done"
    update_task "$task_seq_id" "completed_at" "$now"
  done < <(echo "$active_tasks" | jq -c '.[]' 2>/dev/null || echo "")

  if [ -n "$CURRENT_TASK" ]; then
    # Move current_task to last_task, clear current_task
    upsert_agent "$AGENT_NAME" "$SESSION_ID" "$tty" "$started_at" "$ended_at" "" "$CURRENT_TASK"
    # Update status file
    if [ -n "$tty" ]; then
      tty_key=$(echo "$tty" | tr '/' '_')
      printf '%s\n\n%s\n' "$AGENT_NAME" "$CURRENT_TASK" > "/tmp/hivemind-status-${tty_key}"
    fi
  fi
fi

# Notify if working in subdirectory
PROJECT_ROOT=$(dirname "$HIVEMIND_DIR")
if [ "$WORKING_DIR" != "$PROJECT_ROOT" ]; then
  echo "[hivemind] You're in a subdirectory. Consider: cd $PROJECT_ROOT" >&2
fi

exit 0
