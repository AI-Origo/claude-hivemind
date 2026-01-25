#!/bin/bash
# router.sh - Central dispatcher for Hivemind multi-agent coordination
#
# All hooks route through this single entry point.

set -euo pipefail

# Debug log location
DEBUG_LOG="/tmp/hivemind-debug.log"

# Get script directory for handler dispatch
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HANDLERS_DIR="$SCRIPT_DIR/handlers"

# Read hook input from stdin
INPUT=$(cat)

# Log input for debugging
echo "=== $(date) ===" >> "$DEBUG_LOG"
echo "INPUT: $INPUT" >> "$DEBUG_LOG"

# Determine which handler to call based on hook event
# Hook input contains 'hook_event_name' for lifecycle hooks
EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // .event // "unknown"')
echo "EVENT: $EVENT" >> "$DEBUG_LOG"

case "$EVENT" in
  "SessionStart")
    exec "$HANDLERS_DIR/session-start.sh" <<< "$INPUT"
    ;;
  "SessionEnd")
    exec "$HANDLERS_DIR/session-end.sh" <<< "$INPUT"
    ;;
  "UserPromptSubmit")
    exec "$HANDLERS_DIR/prompt-submit.sh" <<< "$INPUT"
    ;;
  "PreToolUse")
    exec "$HANDLERS_DIR/pre-tool.sh" <<< "$INPUT"
    ;;
  "PostToolUse")
    exec "$HANDLERS_DIR/post-tool.sh" <<< "$INPUT"
    ;;
  "Stop")
    exec "$HANDLERS_DIR/stop.sh" <<< "$INPUT"
    ;;
  *)
    # Unknown event, exit silently
    exit 0
    ;;
esac
