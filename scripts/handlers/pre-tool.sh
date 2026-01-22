#!/bin/bash
# pre-tool.sh - File locking for Write/Edit operations
#
# On PreToolUse (Write/Edit):
# 1. Check if file is locked by another agent
# 2. If locked, output warning (advisory only, not blocking)
# 3. Create/update lock for this agent

set -euo pipefail

# Debug log file
DEBUG_LOG="${HIVEMIND_DEBUG_LOG:-/tmp/hivemind-pre-tool-debug.log}"

# Read input from stdin
INPUT=$(cat)

# Get working directory, session ID, and tool info
WORKING_DIR=$(echo "$INPUT" | jq -r '.cwd // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# Debug logging - always log to see what tools come through
{
  echo "=== $(date) PreToolUse ==="
  echo "TOOL_NAME: '$TOOL_NAME'"
  echo "SESSION_ID: '$SESSION_ID'"
  echo "WORKING_DIR: '$WORKING_DIR'"
  echo "INPUT (raw):"
  echo "$INPUT" | jq . 2>/dev/null || echo "$INPUT"
  echo ""
} >> "$DEBUG_LOG" 2>&1

if [ -z "$WORKING_DIR" ] || [ -z "$SESSION_ID" ]; then
  echo "EXIT: Missing WORKING_DIR or SESSION_ID" >> "$DEBUG_LOG"
  exit 0
fi

# Handle hivemind tools that need session_id injection
# These tools need to know which agent is calling
if [[ "$TOOL_NAME" == *"hive_whoami"* ]] || [[ "$TOOL_NAME" == *"hive_task"* ]] || [[ "$TOOL_NAME" == *"hive_message"* ]] || [[ "$TOOL_NAME" == *"hive_read_messages"* ]]; then
  # Merge existing tool_input with session_id (preserves user-provided parameters)
  TOOL_INPUT=$(echo "$INPUT" | jq -c '.tool_input // {}')
  OUTPUT=$(echo "$TOOL_INPUT" | jq -c \
    --arg sid "$SESSION_ID" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",updatedInput:(. + {session_id:$sid})}}')
  echo "TOOL_INPUT (original): $TOOL_INPUT" >> "$DEBUG_LOG"
  echo "OUTPUT for hivemind tool (matched '$TOOL_NAME'): $OUTPUT" >> "$DEBUG_LOG"
  # Use printf without newline to ensure clean output
  printf '%s' "$OUTPUT"
  exit 0
fi

# For Write/Edit, we need a file path
if [ -z "$FILE_PATH" ]; then
  exit 0
fi

# Only handle Write and Edit tools from here
if [ "$TOOL_NAME" != "Write" ] && [ "$TOOL_NAME" != "Edit" ]; then
  exit 0
fi

# Coordination directories
HIVEMIND_DIR="$WORKING_DIR/.hivemind"
SESSIONS_DIR="$HIVEMIND_DIR/sessions"
LOCKS_DIR="$HIVEMIND_DIR/locks"
AGENTS_DIR="$HIVEMIND_DIR/agents"

mkdir -p "$LOCKS_DIR"

# Look up codename for this session
SESSION_FILE="$SESSIONS_DIR/$SESSION_ID.txt"
if [ ! -f "$SESSION_FILE" ]; then
  exit 0
fi

AGENT_NAME=$(cat "$SESSION_FILE")

# Create a hash of the file path for the lock filename
# Use relative path if possible
REL_PATH="${FILE_PATH#$WORKING_DIR/}"
LOCK_HASH=$(echo -n "$REL_PATH" | md5sum 2>/dev/null | cut -d' ' -f1 || \
            echo -n "$REL_PATH" | md5 2>/dev/null || \
            echo -n "$REL_PATH" | shasum | cut -d' ' -f1)
LOCK_FILE="$LOCKS_DIR/$LOCK_HASH.lock"

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
WARNING=""

# Check if file is locked by another agent
if [ -f "$LOCK_FILE" ]; then
  LOCK_OWNER=$(jq -r '.sessionName // empty' "$LOCK_FILE" 2>/dev/null || true)

  if [ -n "$LOCK_OWNER" ] && [ "$LOCK_OWNER" != "$AGENT_NAME" ]; then
    # File is locked by another agent
    LOCK_PATH=$(jq -r '.filePath // "unknown"' "$LOCK_FILE" 2>/dev/null || echo "$REL_PATH")
    LOCK_TIME=$(jq -r '.lockedAt // ""' "$LOCK_FILE" 2>/dev/null || echo "")

    WARNING="[HIVEMIND WARNING] File '$REL_PATH' is being edited by agent '$LOCK_OWNER'. Consider coordinating to avoid conflicts."
  fi
fi

# Create/update lock for this agent
cat > "$LOCK_FILE" << EOF
{
  "sessionName": "$AGENT_NAME",
  "sessionId": "$SESSION_ID",
  "filePath": "$REL_PATH",
  "lockedAt": "$NOW"
}
EOF

# Update agent's workingOn list
AGENT_FILE="$AGENTS_DIR/$AGENT_NAME.json"
if [ -f "$AGENT_FILE" ]; then
  # Add file to workingOn if not already there
  jq --arg file "$REL_PATH" '
    .workingOn = ((.workingOn // []) | if index($file) then . else . + [$file] end) |
    .lastHeartbeat = (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
  ' "$AGENT_FILE" > "$AGENT_FILE.tmp" && mv "$AGENT_FILE.tmp" "$AGENT_FILE"
fi

# Output warning if file was locked by another agent
if [ -n "$WARNING" ]; then
  printf '{"message": "%s"}' "$(echo "$WARNING" | sed 's/"/\\"/g')"
fi

exit 0
