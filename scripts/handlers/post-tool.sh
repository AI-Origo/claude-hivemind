#!/bin/bash
# post-tool.sh - Track changes after Write/Edit
#
# On PostToolUse (Write/Edit):
# 1. Append entry to changelog
# 2. Release file lock

set -euo pipefail

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

# Find hivemind directory (search parent directories)
HIVEMIND_DIR=$(find_hivemind_dir "$WORKING_DIR")
if [ -z "$HIVEMIND_DIR" ]; then
  exit 0
fi
SESSIONS_DIR="$HIVEMIND_DIR/sessions"
TTY_SESSIONS_DIR="$HIVEMIND_DIR/tty-sessions"
LOCKS_DIR="$HIVEMIND_DIR/locks"
CHANGELOG="$HIVEMIND_DIR/changelog.jsonl"

# Get TTY for stable identity lookup
AGENT_TTY=$(get_current_tty)

# Look up codename (TTY first, then session_id)
AGENT_NAME=$(lookup_agent_name "$AGENT_TTY" "$SESSION_ID" "$TTY_SESSIONS_DIR" "$SESSIONS_DIR")
if [ -z "$AGENT_NAME" ]; then
  exit 0
fi

# Get relative path
REL_PATH="${FILE_PATH#$WORKING_DIR/}"

# Current timestamp
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

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

# Append to changelog (JSONL format)
CHANGELOG_ENTRY=$(jq -n \
  --arg ts "$NOW" \
  --arg agent "$AGENT_NAME" \
  --arg action "$ACTION" \
  --arg file "$REL_PATH" \
  --arg summary "$SUMMARY" \
  '{timestamp: $ts, agent: $agent, action: $action, file: $file, summary: $summary}')

echo "$CHANGELOG_ENTRY" >> "$CHANGELOG"

# Release file lock
LOCK_HASH=$(echo -n "$REL_PATH" | md5sum 2>/dev/null | cut -d' ' -f1 || \
            echo -n "$REL_PATH" | md5 2>/dev/null || \
            echo -n "$REL_PATH" | shasum | cut -d' ' -f1)
LOCK_FILE="$LOCKS_DIR/$LOCK_HASH.lock"

if [ -f "$LOCK_FILE" ]; then
  LOCK_OWNER=$(jq -r '.sessionName // empty' "$LOCK_FILE" 2>/dev/null || true)
  if [ "$LOCK_OWNER" = "$AGENT_NAME" ]; then
    rm -f "$LOCK_FILE"
  fi
fi

# No output needed for PostToolUse
exit 0
