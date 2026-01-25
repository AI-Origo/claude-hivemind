#!/bin/bash
# session-end.sh - Mark agent as ended and cleanup
#
# On SessionEnd:
# 1. Look up codename for this session
# 2. Mark agent as ended (preserve file for TTY recovery on restart)
# 3. Remove session mapping
# 4. Clean up any locks held by this agent
# 5. Keep inbox (messages may arrive while session is down)

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
AGENTS_DIR="$HIVEMIND_DIR/agents"
SESSIONS_DIR="$HIVEMIND_DIR/sessions"
TTY_SESSIONS_DIR="$HIVEMIND_DIR/tty-sessions"
MESSAGES_DIR="$HIVEMIND_DIR/messages"
LOCKS_DIR="$HIVEMIND_DIR/locks"

# Get TTY for stable identity lookup
AGENT_TTY=$(get_current_tty)

# Look up codename (TTY first, then session_id) - handles case where session_id changed
AGENT_NAME=$(lookup_agent_name "$AGENT_TTY" "$SESSION_ID" "$TTY_SESSIONS_DIR" "$SESSIONS_DIR")
if [ -z "$AGENT_NAME" ]; then
  exit 0
fi

AGENT_FILE="$AGENTS_DIR/$AGENT_NAME.json"

# Mark agent as ended (preserve file for TTY recovery on restart)
# Clear sessionId and add endedAt timestamp
if [ -f "$AGENT_FILE" ]; then
  NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  jq --arg ts "$NOW" '.sessionId = "" | .endedAt = $ts | .lastTask = .currentTask | .currentTask = ""' "$AGENT_FILE" > "$AGENT_FILE.tmp" \
    && mv "$AGENT_FILE.tmp" "$AGENT_FILE"
fi

# Remove session mapping
SESSION_FILE="$SESSIONS_DIR/$SESSION_ID.txt"
rm -f "$SESSION_FILE"

# Keep TTY mapping - it persists across session changes so SessionStart can recover
# the correct agent identity. If the TTY is later reused by a different agent,
# SessionStart will overwrite the mapping naturally.

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

# Keep inbox - messages may arrive while session is down and be delivered on restart

# Check if any agents have active sessions
# Only clean up hivemind directory if NO agents have active sessionIds
if [ -d "$AGENTS_DIR" ]; then
  active_count=0
  for agent_file in "$AGENTS_DIR"/*.json; do
    [ -f "$agent_file" ] || continue
    session_id=$(jq -r '.sessionId // ""' "$agent_file" 2>/dev/null)
    if [ -n "$session_id" ]; then
      ((active_count++)) || true
    fi
  done

  # Only clean up if no active agents remain
  if [ "$active_count" -eq 0 ]; then
    rm -rf "$HIVEMIND_DIR"
  fi
fi

exit 0
