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

# Ensure database is initialized
db_ensure_initialized

# Find agent by session_id in database
AGENT_NAME=$(db_query "SELECT name FROM agents WHERE session_id = $(db_quote "$SESSION_ID") LIMIT 1" | jq -r '.[0].name // empty')

if [ -n "$AGENT_NAME" ]; then
  # Only clear if there's a task set
  CURRENT_TASK=$(db_query "SELECT current_task FROM agents WHERE name = $(db_quote "$AGENT_NAME")" | jq -r '.[0].current_task // empty')

  if [ -n "$CURRENT_TASK" ]; then
    # Move current_task to last_task, clear current_task
    db_exec "UPDATE agents SET last_task = current_task, current_task = NULL WHERE name = $(db_quote "$AGENT_NAME")"
  fi
fi

# Notify if working in subdirectory
PROJECT_ROOT=$(dirname "$HIVEMIND_DIR")
if [ "$WORKING_DIR" != "$PROJECT_ROOT" ]; then
  echo "[hivemind] You're in a subdirectory. Consider: cd $PROJECT_ROOT" >&2
fi

exit 0
