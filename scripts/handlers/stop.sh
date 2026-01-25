#!/bin/bash
# stop.sh - Clear agent task when Claude finishes responding

set -uo pipefail

INPUT=$(cat)
WORKING_DIR=$(echo "$INPUT" | jq -r '.cwd // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')

if [ -z "$WORKING_DIR" ] || [ -z "$SESSION_ID" ]; then
  exit 0
fi

AGENTS_DIR="$WORKING_DIR/.hivemind/agents"
SESSIONS_DIR="$WORKING_DIR/.hivemind/sessions"

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

exit 0
