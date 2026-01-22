#!/bin/bash
# session-end.sh - Unregister agent and cleanup
#
# On SessionEnd:
# 1. Look up codename for this session
# 2. Remove agent registry entry (frees the codename for reuse)
# 3. Remove session mapping
# 4. Clean up any locks held by this agent
# 5. Remove inbox messages

set -uo pipefail

# Read input from stdin
INPUT=$(cat)

# Get working directory and session ID from hook input
WORKING_DIR=$(echo "$INPUT" | jq -r '.cwd // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')

if [ -z "$WORKING_DIR" ] || [ -z "$SESSION_ID" ]; then
  exit 0
fi

# Coordination directories
HIVEMIND_DIR="$WORKING_DIR/.hivemind"
AGENTS_DIR="$HIVEMIND_DIR/agents"
SESSIONS_DIR="$HIVEMIND_DIR/sessions"
MESSAGES_DIR="$HIVEMIND_DIR/messages"
LOCKS_DIR="$HIVEMIND_DIR/locks"

# Look up codename for this session
SESSION_FILE="$SESSIONS_DIR/$SESSION_ID.txt"
if [ ! -f "$SESSION_FILE" ]; then
  exit 0
fi

AGENT_NAME=$(cat "$SESSION_FILE")

# Remove agent registry entry
rm -f "$AGENTS_DIR/$AGENT_NAME.json"

# Remove session mapping
rm -f "$SESSION_FILE"

# Clean up locks held by this agent
if [ -d "$LOCKS_DIR" ]; then
  for lock_file in "$LOCKS_DIR"/*.lock; do
    [ -f "$lock_file" ] || continue

    lock_owner=$(jq -r '.sessionName // empty' "$lock_file" 2>/dev/null || true)
    if [ "$lock_owner" = "$AGENT_NAME" ]; then
      rm -f "$lock_file"
    fi
  done
fi

# Keep inbox - messages persist until explicitly read via hive_read_messages
# (Previously deleted inbox here, but messages should survive session restarts)

exit 0
