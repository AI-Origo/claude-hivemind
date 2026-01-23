#!/bin/bash
# session-start.sh - Register agent with auto-assigned phonetic codename
#
# On SessionStart:
# 1. Find first available phonetic codename
# 2. Create agent registry entry
# 3. Map session_id -> codename
# 4. Output context about other active agents

set -uo pipefail

# Phonetic alphabet for agent naming
AGENT_NAMES=(
  alfa bravo charlie delta echo foxtrot golf hotel
  india juliet kilo lima mike november oscar papa
  quebec romeo sierra tango uniform victor whiskey
  xray yankee zulu
)

# Hash TTY path for safe filename
hash_tty() {
  local tty="$1"
  echo -n "$tty" | md5 2>/dev/null || \
  echo -n "$tty" | md5sum 2>/dev/null | cut -d' ' -f1 || \
  echo -n "$tty" | shasum | cut -d' ' -f1
}

# Read input from stdin
INPUT=$(cat)

# Get working directory and session ID from hook input
WORKING_DIR=$(echo "$INPUT" | jq -r '.cwd // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')

if [ -z "$WORKING_DIR" ] || [ -z "$SESSION_ID" ]; then
  exit 0
fi

# Coordination directories
HIVEMIND_DIR="$WORKING_DIR/.hivemind"
AGENTS_DIR="$HIVEMIND_DIR/agents"
SESSIONS_DIR="$HIVEMIND_DIR/sessions"
TTY_SESSIONS_DIR="$HIVEMIND_DIR/tty-sessions"
MESSAGES_DIR="$HIVEMIND_DIR/messages"
LOCKS_DIR="$HIVEMIND_DIR/locks"

# Create directories if they don't exist
mkdir -p "$AGENTS_DIR" "$SESSIONS_DIR" "$TTY_SESSIONS_DIR" "$MESSAGES_DIR" "$LOCKS_DIR"

# Determine agent's TTY
# Try the tty command first, fall back to parent process lookup
AGENT_TTY=""
if command -v tty &>/dev/null; then
  AGENT_TTY=$(tty 2>/dev/null || true)
fi
# If tty command failed or returned "not a tty", try parent process lookup
if [[ -z "$AGENT_TTY" || "$AGENT_TTY" == "not a tty" ]]; then
  # Look up TTY from parent process (Claude Code runs in the terminal)
  PARENT_PID=$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')
  if [[ -n "$PARENT_PID" ]]; then
    AGENT_TTY=$(ps -o tty= -p "$PARENT_PID" 2>/dev/null | tr -d ' ')
    [[ -n "$AGENT_TTY" && "$AGENT_TTY" != "??" ]] && AGENT_TTY="/dev/$AGENT_TTY"
  fi
fi
# Final fallback: empty string (no TTY available)
[[ "$AGENT_TTY" == "not a tty" || "$AGENT_TTY" == "??" ]] && AGENT_TTY=""

# Check if this session already has an agent assigned
if [ -f "$SESSIONS_DIR/$SESSION_ID.txt" ]; then
  ASSIGNED_NAME=$(cat "$SESSIONS_DIR/$SESSION_ID.txt")
else
  # Current timestamp
  NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # First check if there's an MCP-registered agent we should adopt
  # MCP server may have registered an agent before this hook runs
  ASSIGNED_NAME=""
  ADOPTED_MCP_AGENT=false
  for agent_file in "$AGENTS_DIR"/*.json; do
    [ -f "$agent_file" ] || continue
    agent_name=$(basename "$agent_file" .json)
    agent_session_id=$(jq -r '.sessionId // ""' "$agent_file" 2>/dev/null)

    # If this is an MCP-registered agent (session ID starts with mcp-), adopt it
    if [[ "$agent_session_id" == mcp-* ]]; then
      ASSIGNED_NAME="$agent_name"
      ADOPTED_MCP_AGENT=true
      # Update agent file with our Claude session ID and TTY
      jq --arg sid "$SESSION_ID" --arg tty "$AGENT_TTY" '.sessionId = $sid | .tty = $tty' "$agent_file" > "$agent_file.tmp" && mv "$agent_file.tmp" "$agent_file"
      break
    fi
  done

  # If no MCP agent found, check for TTY-based recovery (ended agent in same terminal)
  if [ -z "$ASSIGNED_NAME" ] && [[ -n "$AGENT_TTY" ]]; then
    for agent_file in "$AGENTS_DIR"/*.json; do
      [ -f "$agent_file" ] || continue
      agent_name=$(basename "$agent_file" .json)
      agent_tty=$(jq -r '.tty // ""' "$agent_file" 2>/dev/null)
      agent_session_id=$(jq -r '.sessionId // ""' "$agent_file" 2>/dev/null)

      # If same TTY and agent is ended (empty sessionId), reclaim it
      if [[ "$agent_tty" == "$AGENT_TTY" && -z "$agent_session_id" ]]; then
        ASSIGNED_NAME="$agent_name"
        # Update agent file with new session ID, clear endedAt
        jq --arg sid "$SESSION_ID" '.sessionId = $sid | del(.endedAt)' "$agent_file" > "$agent_file.tmp" \
          && mv "$agent_file.tmp" "$agent_file"
        ADOPTED_MCP_AGENT=true  # Reuse flag to skip creating new agent file
        break
      fi
    done
  fi

  # If no ended agent found, find first available codename
  if [ -z "$ASSIGNED_NAME" ]; then
    for name in "${AGENT_NAMES[@]}"; do
      if [ ! -f "$AGENTS_DIR/$name.json" ]; then
        ASSIGNED_NAME="$name"
        break
      else
        # Check if this agent file is from an ended agent (we can reuse this name
        # only if it's from a different TTY or has been ended for >24 hours)
        # For now, skip files that exist - they may be reclaimed by their original terminal
        continue
      fi
    done
  fi

  if [ -z "$ASSIGNED_NAME" ]; then
    # All 26 names taken (unlikely) - use session ID prefix
    ASSIGNED_NAME="agent-${SESSION_ID:0:8}"
  fi

  # Only create new agent registry entry if we didn't adopt an MCP agent
  if [ "$ADOPTED_MCP_AGENT" = false ]; then
    cat > "$AGENTS_DIR/$ASSIGNED_NAME.json" << EOF
{
  "sessionName": "$ASSIGNED_NAME",
  "sessionId": "$SESSION_ID",
  "startedAt": "$NOW",
  "currentTask": "",
  "workingOn": [],
  "tty": "$AGENT_TTY"
}
EOF
  fi

  # Create session -> name mapping
  echo "$ASSIGNED_NAME" > "$SESSIONS_DIR/$SESSION_ID.txt"

  # Also create TTY-based mapping for stable identity (survives session_id changes)
  if [[ -n "$AGENT_TTY" ]]; then
    TTY_HASH=$(hash_tty "$AGENT_TTY")
    echo "$ASSIGNED_NAME" > "$TTY_SESSIONS_DIR/$TTY_HASH.txt"
  fi

  # Create inbox directory for this agent
  mkdir -p "$MESSAGES_DIR/inbox-$ASSIGNED_NAME"
fi

# Gather info about other active agents
OTHER_AGENTS=""
AGENT_COUNT=0
for agent_file in "$AGENTS_DIR"/*.json; do
  [ -f "$agent_file" ] || continue

  agent_name=$(basename "$agent_file" .json)
  [ "$agent_name" = "$ASSIGNED_NAME" ] && continue

  task=$(jq -r '.currentTask // ""' "$agent_file" 2>/dev/null || echo "")
  ((AGENT_COUNT++))

  if [ -n "$OTHER_AGENTS" ]; then
    OTHER_AGENTS="$OTHER_AGENTS, "
  fi
  if [ -n "$task" ] && [ "$task" != "null" ]; then
    OTHER_AGENTS="${OTHER_AGENTS}$agent_name ($task)"
  else
    OTHER_AGENTS="${OTHER_AGENTS}$agent_name"
  fi
done

# Build context message
if [ "$AGENT_COUNT" -gt 0 ]; then
  printf '{"message": "[HIVEMIND] You are agent '\''%s'\''. Other agents: %s. Use /hive status for coordination."}' "$ASSIGNED_NAME" "$OTHER_AGENTS"
else
  printf '{"message": "[HIVEMIND] You are agent '\''%s'\''. No other agents active. Use /hive status for coordination."}' "$ASSIGNED_NAME"
fi

exit 0
