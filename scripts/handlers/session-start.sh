#!/bin/bash
# session-start.sh - Register agent with auto-assigned phonetic codename
#
# On SessionStart:
# 1. Find first available phonetic codename
# 2. Create agent record in database
# 3. Output context about other active agents and assigned tasks

set -uo pipefail

# Check for DuckDB FIRST - before sourcing any libraries
# If DuckDB is not installed, exit silently (user should run /hive setup)
if ! command -v duckdb &> /dev/null; then
    exit 0
fi

# Phonetic alphabet for agent naming
AGENT_NAMES=(
  alfa bravo charlie delta echo foxtrot golf hotel
  india juliet kilo lima mike november oscar papa
  quebec romeo sierra tango uniform victor whiskey
  xray yankee zulu
)

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

# Read input from stdin
INPUT=$(cat)

# Get working directory and session ID from hook input
WORKING_DIR=$(echo "$INPUT" | jq -r '.cwd // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')

if [ -z "$WORKING_DIR" ] || [ -z "$SESSION_ID" ]; then
  exit 0
fi

# Current timestamp
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Coordination directory - search up for existing .hivemind, fall back to current dir
HIVEMIND_DIR=$(find_hivemind_dir "$WORKING_DIR")
if [ -z "$HIVEMIND_DIR" ]; then
  HIVEMIND_DIRNAME="${HIVEMIND_DIRNAME:-.hivemind}"
  HIVEMIND_DIR="$WORKING_DIR/$HIVEMIND_DIRNAME"
fi
export HIVEMIND_DIR

# Ensure database is initialized (creates schema and copies templates)
db_full_init

# Write version file from plugin.json
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLUGIN_JSON="$PLUGIN_ROOT/.claude-plugin/plugin.json"
if [[ -f "$PLUGIN_JSON" ]]; then
  VERSION=$(jq -r '.version // "unknown"' "$PLUGIN_JSON")
  echo "$VERSION" > "$HIVEMIND_DIR/version.txt"
fi

# Determine agent's TTY by walking up process tree
AGENT_TTY=""
if command -v tty &>/dev/null; then
  AGENT_TTY=$(tty 2>/dev/null || true)
fi
if [[ -z "$AGENT_TTY" || "$AGENT_TTY" == "not a tty" ]]; then
  # Walk up process tree to find a process with a TTY
  pid=$$
  while [[ -n "$pid" && "$pid" != "1" ]]; do
    ptty=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
    if [[ -n "$ptty" && "$ptty" != "??" ]]; then
      AGENT_TTY="/dev/$ptty"
      break
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  done
fi
[[ "$AGENT_TTY" == "not a tty" || "$AGENT_TTY" == "??" ]] && AGENT_TTY=""

ASSIGNED_NAME=""

# Priority 1: Check if this session already has an agent assigned
existing_agent=$(db_query "SELECT name FROM agents WHERE session_id = $(db_quote "$SESSION_ID") AND ended_at IS NULL LIMIT 1" | jq -r '.[0].name // empty')
if [[ -n "$existing_agent" ]]; then
  ASSIGNED_NAME="$existing_agent"
fi

# Priority 2: Check for TTY-based recovery (same terminal recovers same agent)
if [[ -z "$ASSIGNED_NAME" && -n "$AGENT_TTY" ]]; then
  tty_agent=$(db_query "SELECT name FROM agents WHERE tty = $(db_quote "$AGENT_TTY") LIMIT 1" | jq -r '.[0].name // empty')
  if [[ -n "$tty_agent" ]]; then
    ASSIGNED_NAME="$tty_agent"
    # Update agent with new session, clear ended_at, update started_at
    db_exec "UPDATE agents SET session_id = $(db_quote "$SESSION_ID"), started_at = '$NOW', ended_at = NULL WHERE name = $(db_quote "$ASSIGNED_NAME")"
  fi
fi

# Priority 3: Find first available codename
if [[ -z "$ASSIGNED_NAME" ]]; then
  # Get list of active agent names (ended agents release their names)
  existing_names=$(db_query "SELECT name FROM agents WHERE ended_at IS NULL" | jq -r '.[].name' 2>/dev/null || echo "")

  for name in "${AGENT_NAMES[@]}"; do
    if ! echo "$existing_names" | grep -q "^${name}$"; then
      ASSIGNED_NAME="$name"
      break
    fi
  done
fi

# Fallback: Use session ID prefix if all 26 names taken
if [[ -z "$ASSIGNED_NAME" ]]; then
  ASSIGNED_NAME="agent-${SESSION_ID:0:8}"
fi

# Check if agent exists in database
agent_exists=$(db_query "SELECT 1 FROM agents WHERE name = $(db_quote "$ASSIGNED_NAME")" | jq -r '.[0] // empty')

if [[ -z "$agent_exists" ]]; then
  # Insert new agent
  db_exec "INSERT INTO agents (name, session_id, tty, started_at) VALUES ($(db_quote "$ASSIGNED_NAME"), $(db_quote "$SESSION_ID"), $(db_quote "$AGENT_TTY"), '$NOW')"
else
  # Update existing agent (recovery case)
  db_exec "UPDATE agents SET session_id = $(db_quote "$SESSION_ID"), tty = $(db_quote "$AGENT_TTY"), started_at = '$NOW', ended_at = NULL WHERE name = $(db_quote "$ASSIGNED_NAME")"
fi

# Status line now reads directly from DuckDB - no file-based mappings needed

# Gather info about other active agents
OTHER_AGENTS=""
AGENT_COUNT=0

other_agents_json=$(db_query "SELECT name, current_task FROM agents WHERE name != $(db_quote "$ASSIGNED_NAME") AND ended_at IS NULL")
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  agent_name=$(echo "$line" | jq -r '.name // empty')
  [[ -z "$agent_name" ]] && continue

  task=$(echo "$line" | jq -r '.current_task // empty')
  ((AGENT_COUNT++))

  if [[ -n "$OTHER_AGENTS" ]]; then
    OTHER_AGENTS="$OTHER_AGENTS, "
  fi
  if [[ -n "$task" ]]; then
    OTHER_AGENTS="${OTHER_AGENTS}$agent_name ($task)"
  else
    OTHER_AGENTS="${OTHER_AGENTS}$agent_name"
  fi
done < <(echo "$other_agents_json" | jq -c '.[]' 2>/dev/null || echo "")

# Check for tasks assigned to this agent
assigned_tasks_json=$(db_query "SELECT id, title, state FROM tasks WHERE assignee = $(db_quote "$ASSIGNED_NAME") AND state NOT IN ('done') ORDER BY id")
TASK_INFO=""
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  task_id=$(echo "$line" | jq -r '.id // empty')
  [[ -z "$task_id" ]] && continue

  task_title=$(echo "$line" | jq -r '.title // empty')
  task_state=$(echo "$line" | jq -r '.state // empty')

  if [[ -n "$TASK_INFO" ]]; then
    TASK_INFO="$TASK_INFO, "
  fi
  TASK_INFO="${TASK_INFO}#$task_id: $task_title [$task_state]"
done < <(echo "$assigned_tasks_json" | jq -c '.[]' 2>/dev/null || echo "")

# Check for tasks in review awaiting approval
review_tasks_json=$(db_query "SELECT id, title, assignee FROM tasks WHERE state = 'review' AND assignee != $(db_quote "$ASSIGNED_NAME") ORDER BY id")
REVIEW_INFO=""
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  task_id=$(echo "$line" | jq -r '.id // empty')
  [[ -z "$task_id" ]] && continue

  task_title=$(echo "$line" | jq -r '.title // empty')
  task_assignee=$(echo "$line" | jq -r '.assignee // empty')

  if [[ -n "$REVIEW_INFO" ]]; then
    REVIEW_INFO="$REVIEW_INFO, "
  fi
  REVIEW_INFO="${REVIEW_INFO}#$task_id: $task_title (by $task_assignee)"
done < <(echo "$review_tasks_json" | jq -c '.[]' 2>/dev/null || echo "")

# Build context message
MSG="[HIVEMIND] You are agent '$ASSIGNED_NAME'."

if [[ "$AGENT_COUNT" -gt 0 ]]; then
  MSG="$MSG Other agents: $OTHER_AGENTS."
else
  MSG="$MSG No other agents active."
fi

if [[ -n "$TASK_INFO" ]]; then
  MSG="$MSG Your tasks: $TASK_INFO."
fi

if [[ -n "$REVIEW_INFO" ]]; then
  MSG="$MSG Tasks awaiting review: $REVIEW_INFO."
fi

MSG="$MSG Use /hive status for coordination."

# Escape for JSON
MSG_ESCAPED=$(echo "$MSG" | sed 's/\\/\\\\/g; s/"/\\"/g; s/`/\\`/g')
printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}' "$MSG_ESCAPED"

exit 0
