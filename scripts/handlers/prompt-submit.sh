#!/bin/bash
# prompt-submit.sh - Deliver pending messages and inject identity
#
# On UserPromptSubmit:
# 1. Look up this agent's codename via session mapping
# 2. Check inbox for unread messages
# 3. Inject identity and messages as context

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
SESSIONS_DIR="$HIVEMIND_DIR/sessions"
MESSAGES_DIR="$HIVEMIND_DIR/messages"

# Look up codename for this session
SESSION_FILE="$SESSIONS_DIR/$SESSION_ID.txt"
if [ ! -f "$SESSION_FILE" ]; then
  exit 0
fi

AGENT_NAME=$(cat "$SESSION_FILE")
if [ -z "$AGENT_NAME" ]; then
  exit 0
fi

# Collect messages
MESSAGES=""
PROCESSED_FILES=""

# Check agent-specific inbox
INBOX_DIR="$MESSAGES_DIR/inbox-$AGENT_NAME"
if [ -d "$INBOX_DIR" ]; then
  for msg_file in "$INBOX_DIR"/*.json; do
    [ -f "$msg_file" ] || continue

    from=$(jq -r '.from // "unknown"' "$msg_file" 2>/dev/null || echo "unknown")
    body=$(jq -r '.body // ""' "$msg_file" 2>/dev/null || echo "")
    priority=$(jq -r '.priority // "normal"' "$msg_file" 2>/dev/null || echo "normal")

    priority_prefix=""
    [ "$priority" = "urgent" ] && priority_prefix="[URGENT] "
    [ "$priority" = "high" ] && priority_prefix="[HIGH] "

    ts=$(jq -r '.timestamp // ""' "$msg_file" 2>/dev/null || echo "")

    if [ -n "$MESSAGES" ]; then
      MESSAGES="$MESSAGES\\n"
    fi
    MESSAGES="${MESSAGES}${priority_prefix}[HIVE AGENT MESSAGE] From $from ($ts): $body"

    PROCESSED_FILES="$PROCESSED_FILES $msg_file"
  done
fi

# Delete processed direct messages (inbox)
if [ -n "$PROCESSED_FILES" ]; then
  for f in $PROCESSED_FILES; do
    rm -f "$f"
  done
fi

# Output messages if any
if [ -n "$MESSAGES" ]; then
  echo "[HIVEMIND MESSAGES]"
  echo -e "$MESSAGES"
  echo ""
fi

# Always inject task recording reminder
echo "[HIVEMIND TASK TRACKING]"
echo "You are agent $AGENT_NAME. Record your current task using hive_task so other agents can see what you're working on. When you finish processing or are waiting for user input, clear your task by calling hive_task with an empty description - never set it to 'idle', 'waiting', or similar."

exit 0
