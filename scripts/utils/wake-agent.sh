#!/bin/bash
# wake-agent.sh - Wake an idle agent by sending a message to their iTerm2 session
#
# Usage: wake-agent.sh <tty> [message]
# Example: wake-agent.sh /dev/ttys007 "New message!                "

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -lt 1 ]]; then
    echo "Error: TTY argument required" >&2
    echo "Usage: wake-agent.sh <tty> [message]" >&2
    exit 1
fi

TTY="$1"
MESSAGE="${2:-New message!                }"

# Run the AppleScript
osascript "$SCRIPT_DIR/send-keystroke.scpt" "$TTY" "$MESSAGE"
