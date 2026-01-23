#!/bin/bash
# post-tool.sh - Track changes after Write/Edit
#
# On PostToolUse (Write/Edit):
# 1. Append entry to changelog
# 2. Release file lock

set -euo pipefail

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

# Coordination directories
HIVEMIND_DIR="$WORKING_DIR/.hivemind"
SESSIONS_DIR="$HIVEMIND_DIR/sessions"
LOCKS_DIR="$HIVEMIND_DIR/locks"
CHANGELOG="$HIVEMIND_DIR/changelog.jsonl"

# Look up codename for this session
SESSION_FILE="$SESSIONS_DIR/$SESSION_ID.txt"
if [ ! -f "$SESSION_FILE" ]; then
  exit 0
fi

AGENT_NAME=$(cat "$SESSION_FILE")

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
