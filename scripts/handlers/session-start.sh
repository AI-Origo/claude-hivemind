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
MESSAGES_DIR="$HIVEMIND_DIR/messages"
LOCKS_DIR="$HIVEMIND_DIR/locks"

# Create directories if they don't exist
mkdir -p "$AGENTS_DIR" "$SESSIONS_DIR" "$MESSAGES_DIR" "$LOCKS_DIR"

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
      # Update agent file with our Claude session ID
      jq --arg sid "$SESSION_ID" '.sessionId = $sid' "$agent_file" > "$agent_file.tmp" && mv "$agent_file.tmp" "$agent_file"
      break
    fi
  done

  # If no MCP agent found, find first available codename
  if [ -z "$ASSIGNED_NAME" ]; then
    for name in "${AGENT_NAMES[@]}"; do
      if [ ! -f "$AGENTS_DIR/$name.json" ]; then
        ASSIGNED_NAME="$name"
        break
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
  "lastHeartbeat": "$NOW",
  "currentTask": "",
  "workingOn": [],
  "status": "active"
}
EOF
  fi

  # Create session -> name mapping
  echo "$ASSIGNED_NAME" > "$SESSIONS_DIR/$SESSION_ID.txt"

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
