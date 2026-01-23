#!/bin/bash
# prompt-submit.sh - Deliver pending messages and inject identity
#
# On UserPromptSubmit:
# 1. Look up this agent's codename via session mapping
# 2. Check inbox for unread messages
# 3. Inject identity and messages as context

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

# Get current TTY from process hierarchy
get_current_tty() {
  local tty=""
  if command -v tty &>/dev/null; then
    tty=$(tty 2>/dev/null || true)
  fi
  if [[ -z "$tty" || "$tty" == "not a tty" ]]; then
    local ppid=$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')
    if [[ -n "$ppid" ]]; then
      tty=$(ps -o tty= -p "$ppid" 2>/dev/null | tr -d ' ')
      [[ -n "$tty" && "$tty" != "??" ]] && tty="/dev/$tty"
    fi
  fi
  [[ "$tty" == "not a tty" || "$tty" == "??" ]] && tty=""
  echo "$tty"
}

# Hash TTY path for safe filename
hash_tty() {
  local tty="$1"
  echo -n "$tty" | md5 2>/dev/null || \
  echo -n "$tty" | md5sum 2>/dev/null | cut -d' ' -f1 || \
  echo -n "$tty" | shasum | cut -d' ' -f1
}

# Look up agent name using TTY first, then session_id
lookup_agent_name() {
  local tty="$1"
  local session_id="$2"
  local tty_sessions_dir="$3"
  local sessions_dir="$4"
  local agent_name=""

  # Try TTY mapping first (most stable)
  if [[ -n "$tty" ]]; then
    local tty_hash=$(hash_tty "$tty")
    local tty_file="$tty_sessions_dir/$tty_hash.txt"
    if [[ -f "$tty_file" ]]; then
      agent_name=$(cat "$tty_file")
    fi
  fi

  # Fall back to session_id mapping
  if [[ -z "$agent_name" && -n "$session_id" ]]; then
    local session_file="$sessions_dir/$session_id.txt"
    if [[ -f "$session_file" ]]; then
      agent_name=$(cat "$session_file")
    fi
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

# Find hivemind directory (search parent directories)
HIVEMIND_DIR=$(find_hivemind_dir "$WORKING_DIR")
if [ -z "$HIVEMIND_DIR" ]; then
  exit 0
fi
SESSIONS_DIR="$HIVEMIND_DIR/sessions"
TTY_SESSIONS_DIR="$HIVEMIND_DIR/tty-sessions"
MESSAGES_DIR="$HIVEMIND_DIR/messages"

# Get TTY for stable identity lookup
AGENT_TTY=$(get_current_tty)

# Look up codename (TTY first, then session_id)
AGENT_NAME=$(lookup_agent_name "$AGENT_TTY" "$SESSION_ID" "$TTY_SESSIONS_DIR" "$SESSIONS_DIR")
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
echo ""
echo "[HIVEMIND DELEGATION PROTOCOL]"
echo "When delegating work to other agents: (1) Assign ONE task at a time - research what's needed, assign it, wait for acknowledgment before the next. Do NOT bulk-assign. (2) After delegating, if you have no other work, clear your task and STOP. You will be woken up when agents report back. Do NOT poll or pester for status."

exit 0
