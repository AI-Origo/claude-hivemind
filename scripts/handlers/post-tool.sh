#!/bin/bash
# post-tool.sh - Track changes after Write/Edit
#
# On PostToolUse (Write/Edit):
# 1. Insert entry into changelog table
# 2. Release file lock from database

set -euo pipefail

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

# Get current TTY from process hierarchy
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

# Look up agent name using TTY first, then session_id from database
lookup_agent_name() {
  local tty="$1"
  local session_id="$2"
  local agent_name=""

  # Try TTY first (most stable)
  if [[ -n "$tty" ]]; then
    agent_name=$(db_query "SELECT name FROM agents WHERE tty = $(db_quote "$tty") LIMIT 1" | jq -r '.[0].name // empty')
  fi

  # Fall back to session_id
  if [[ -z "$agent_name" && -n "$session_id" ]]; then
    agent_name=$(db_query "SELECT name FROM agents WHERE session_id = $(db_quote "$session_id") LIMIT 1" | jq -r '.[0].name // empty')
  fi

  echo "$agent_name"
}

# Read input from stdin
INPUT=$(cat)

# Get working directory, session ID, and tool info
WORKING_DIR=$(echo "$INPUT" | jq -r '.cwd // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
TOOL_RESULT=$(echo "$INPUT" | jq -r '.tool_result // empty')

if [ -z "$WORKING_DIR" ] || [ -z "$SESSION_ID" ] || [ -z "$FILE_PATH" ]; then
  exit 0
fi

# Only handle Write and Edit tools
if [ "$TOOL_NAME" != "Write" ] && [ "$TOOL_NAME" != "Edit" ]; then
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

# Look up agent name from database
AGENT_NAME=$(lookup_agent_name "$AGENT_TTY" "$SESSION_ID")
if [ -z "$AGENT_NAME" ]; then
  exit 0
fi

# Get relative path
REL_PATH="${FILE_PATH#$WORKING_DIR/}"

# Determine action type
ACTION="edit"
if [ "$TOOL_NAME" = "Write" ]; then
  ACTION="write"
fi

# Generate summary based on tool result
SUMMARY=""
if [ "$TOOL_NAME" = "Write" ] && echo "$TOOL_RESULT" | grep -qi "created"; then
  SUMMARY="Created file"
  ACTION="create"
elif echo "$TOOL_RESULT" | grep -qi "updated\|modified\|edited"; then
  SUMMARY="Modified file"
fi

# Get next changelog ID
CHANGELOG_ID=$(db_next_id "changelog_id_seq")

# Insert changelog entry into database
db_exec "INSERT INTO changelog (id, agent, action, file_path, summary) VALUES ($CHANGELOG_ID, $(db_quote "$AGENT_NAME"), $(db_quote "$ACTION"), $(db_quote "$REL_PATH"), $(db_quote "$SUMMARY"))"

# Release file lock from database (only if owned by this agent)
db_exec "DELETE FROM file_locks WHERE file_path = $(db_quote "$REL_PATH") AND agent_name = $(db_quote "$AGENT_NAME")"

# No output needed for PostToolUse
exit 0
