#!/bin/bash
# session-end.sh - Mark agent as ended and cleanup transient data
#
# On SessionEnd:
# 1. Look up agent by TTY or session_id
# 2. Mark agent as ended in Milvus (preserve for TTY recovery)
# 3. Release file locks held by this agent
# 4. DO NOT delete .hivemind directory - preserve config
#
# Preserved: .env, .env.example, .gitignore, all knowledge/memory/tasks data
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

# Check if Milvus is available
if ! milvus_ready; then
  exit 0
fi

# Get TTY for stable identity lookup
AGENT_TTY=$(get_current_tty)

# Look up agent name (TTY first, then session_id)
AGENT_NAME=""
AGENT_JSON=""

# Try TTY first (most stable)
if [[ -n "$AGENT_TTY" ]]; then
  AGENT_JSON=$(milvus_query "agents" "tty == $(db_quote "$AGENT_TTY")" "*" 1)
  AGENT_NAME=$(echo "$AGENT_JSON" | jq -r '.[0].name // empty')
fi

# Fall back to session_id
if [[ -z "$AGENT_NAME" && -n "$SESSION_ID" ]]; then
  AGENT_JSON=$(milvus_query "agents" "session_id == $(db_quote "$SESSION_ID")" "*" 1)
  AGENT_NAME=$(echo "$AGENT_JSON" | jq -r '.[0].name // empty')
fi

if [ -z "$AGENT_NAME" ]; then
  exit 0
fi

# Current timestamp
NOW=$(get_timestamp)

# Get existing agent data to preserve fields
current_task=$(echo "$AGENT_JSON" | jq -r '.[0].current_task // empty')
started_at=$(echo "$AGENT_JSON" | jq -r '.[0].started_at // 0')

# Mark agent as ended:
# - Clear session_id
# - Set ended_at timestamp
# - Copy current_task to last_task, clear current_task
# - Keep TTY for recovery on restart
upsert_agent "$AGENT_NAME" "" "$AGENT_TTY" "$started_at" "$NOW" "" "$current_task"

# Release file locks held by this agent
release_agent_locks "$AGENT_NAME"

# Delete all messages sent to or from this agent
milvus_delete "messages" "from_agent == $(db_quote "$AGENT_NAME")"
milvus_delete "messages" "to_agent == $(db_quote "$AGENT_NAME")"

# Check if any active agents remain
active_count_json=$(milvus_query "agents" "ended_at < 1" "id" 100)
ACTIVE_COUNT=$(echo "$active_count_json" | jq 'length')

if [[ "$ACTIVE_COUNT" == "0" ]]; then
  # No active agents - clean up old data
  # Note: With Milvus, we don't delete the database file, just transient data
  # Optionally could delete all agents here for clean slate
  :
fi

exit 0
