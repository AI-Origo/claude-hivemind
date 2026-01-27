#!/bin/bash
# session-end.sh - Mark agent as ended and cleanup transient data
#
# On SessionEnd:
# 1. Look up agent by TTY or session_id
# 2. Mark agent as ended in database (preserve for TTY recovery)
# 3. Release file locks held by this agent
# 4. DO NOT delete .hivemind directory - preserve database and config
#
# Preserved: .env, .env.example, .gitignore, hive.db, all knowledge/memory/tasks data
# Cleaned: agent sessions (marked ended), file locks (released)

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

# Get current TTY by walking up process tree
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

# Look up agent name (TTY first, then session_id)
AGENT_NAME=""

# Try TTY first (most stable)
if [[ -n "$AGENT_TTY" ]]; then
  AGENT_NAME=$(db_query "SELECT name FROM agents WHERE tty = $(db_quote "$AGENT_TTY") LIMIT 1" | jq -r '.[0].name // empty')
fi

# Fall back to session_id
if [[ -z "$AGENT_NAME" && -n "$SESSION_ID" ]]; then
  AGENT_NAME=$(db_query "SELECT name FROM agents WHERE session_id = $(db_quote "$SESSION_ID") LIMIT 1" | jq -r '.[0].name // empty')
fi

if [ -z "$AGENT_NAME" ]; then
  exit 0
fi

# Current timestamp
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Mark agent as ended
# - Clear session_id
# - Set ended_at timestamp
# - Copy current_task to last_task, clear current_task
# - Keep TTY for recovery on restart
db_exec "UPDATE agents SET
  session_id = NULL,
  ended_at = '$NOW',
  last_task = current_task,
  current_task = NULL
WHERE name = $(db_quote "$AGENT_NAME")"

# Release file locks held by this agent
db_exec "DELETE FROM file_locks WHERE agent_name = $(db_quote "$AGENT_NAME")"

# Delete all messages sent to or from this agent
db_exec "DELETE FROM messages WHERE from_agent = $(db_quote "$AGENT_NAME") OR to_agent = $(db_quote "$AGENT_NAME")"

# Check if any active agents remain
ACTIVE_COUNT=$(db_query "SELECT COUNT(*) as cnt FROM agents WHERE ended_at IS NULL" | jq -r '.[0].cnt // 0')

if [[ "$ACTIVE_COUNT" == "0" ]]; then
  # No active agents - remove database file for clean slate
  DB_PATH="$HIVEMIND_DIR/hive.db"
  if [[ -f "$DB_PATH" ]]; then
    rm -f "$DB_PATH"
    rm -f "$DB_PATH.wal" 2>/dev/null || true
  fi
fi

exit 0
