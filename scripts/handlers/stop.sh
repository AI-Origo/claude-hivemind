#!/bin/bash
# stop.sh - Clear agent task when Claude finishes responding

set -uo pipefail

# Find .hivemind directory by searching up from given path
find_hivemind_dir() {
  local dir="$1"
  while [[ "$dir" != "/" ]]; do
    if [[ -d "$dir/.hivemind" ]]; then
      echo "$dir/.hivemind"
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

# Find hivemind directory (search parent directories)
HIVEMIND_DIR=$(find_hivemind_dir "$WORKING_DIR")
if [ -z "$HIVEMIND_DIR" ]; then
  exit 0
fi

AGENTS_DIR="$HIVEMIND_DIR/agents"
SESSIONS_DIR="$HIVEMIND_DIR/sessions"

# Find agent by session mapping
if [ -f "$SESSIONS_DIR/$SESSION_ID.txt" ]; then
  AGENT_NAME=$(cat "$SESSIONS_DIR/$SESSION_ID.txt")
  AGENT_FILE="$AGENTS_DIR/$AGENT_NAME.json"

  if [ -f "$AGENT_FILE" ]; then
    # Only clear if there's a task set
    CURRENT_TASK=$(jq -r '.currentTask // ""' "$AGENT_FILE" 2>/dev/null)
    if [ -n "$CURRENT_TASK" ]; then
      jq '.lastTask = .currentTask | .currentTask = ""' "$AGENT_FILE" > "$AGENT_FILE.tmp" \
        && mv "$AGENT_FILE.tmp" "$AGENT_FILE"
    fi
  fi
fi

# Notify if working in subdirectory
PROJECT_ROOT=$(dirname "$HIVEMIND_DIR")
if [ "$WORKING_DIR" != "$PROJECT_ROOT" ]; then
  echo "[hivemind] You're in a subdirectory. Consider: cd $PROJECT_ROOT" >&2
fi

exit 0
