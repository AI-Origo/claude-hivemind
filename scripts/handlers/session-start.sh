#!/bin/bash
# session-start.sh - Register agent with auto-assigned phonetic codename
#
# On SessionStart:
# 1. Find first available phonetic codename
# 2. Create agent record in Milvus
# 3. Output context about other active agents and assigned tasks

set -uo pipefail

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

# Coordination directory - search up for existing .hivemind, fall back to current dir
# Track if .hivemind existed before this session (for purge-on-delete detection)
HIVEMIND_EXISTED=true
HIVEMIND_DIR=$(find_hivemind_dir "$WORKING_DIR")
if [ -z "$HIVEMIND_DIR" ]; then
  HIVEMIND_EXISTED=false
  HIVEMIND_DIRNAME="${HIVEMIND_DIRNAME:-.hivemind}"
  HIVEMIND_DIR="$WORKING_DIR/$HIVEMIND_DIRNAME"
fi
export HIVEMIND_DIR

# Copy templates (creates .hivemind directory if needed)
db_full_init

# Write version file from plugin.json (before Milvus check so it always updates)
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLUGIN_JSON="$PLUGIN_ROOT/.claude-plugin/plugin.json"
if [[ -f "$PLUGIN_JSON" ]]; then
  VERSION=$(jq -r '.version // "unknown"' "$PLUGIN_JSON")
  echo "$VERSION" > "$HIVEMIND_DIR/version.txt"
fi

# If .hivemind didn't exist, purge stale project data and reinitialize collections
if [[ "$HIVEMIND_EXISTED" == "false" ]] && milvus_ready 2>/dev/null; then
  db_purge_project
  # Reinitialize collections from project root
  INIT_SCRIPT="$SCRIPT_DIR/../init-collections.sh"
  if [[ -x "$INIT_SCRIPT" ]]; then
    (cd "$(dirname "$HIVEMIND_DIR")" && "$INIT_SCRIPT") 2>/dev/null || true
  fi
fi

# Check if Milvus is available - if not, exit silently (user should run start-milvus.sh)
if ! milvus_ready; then
  exit 0
fi

# Current timestamp (Unix epoch)
NOW=$(get_timestamp)

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
current_task=""
last_task=""

# Priority 1: Check if this session already has an agent assigned
existing_agent=$(get_agent_by_session "$SESSION_ID" | jq -r '.[0].name // empty')
if [[ -n "$existing_agent" ]]; then
  ASSIGNED_NAME="$existing_agent"
fi

# Priority 2: Check for TTY-based recovery (same terminal recovers same agent)
# Only recover if: agent is still active OR there are other active agents
# When no active agents exist, start fresh from "alfa"
if [[ -z "$ASSIGNED_NAME" && -n "$AGENT_TTY" ]]; then
  tty_agent_json=$(milvus_query "agents" "tty == $(db_quote "$AGENT_TTY")" "*" 1)
  tty_agent=$(echo "$tty_agent_json" | jq -r '.[0].name // empty')
  if [[ -n "$tty_agent" ]]; then
    tty_agent_ended=$(echo "$tty_agent_json" | jq -r '.[0].ended_at // 0')
    active_count=$(get_active_agents | jq 'length')
    # Recover if agent is active OR there are other active agents
    if [[ "$tty_agent_ended" -lt 1 || "$active_count" -gt 0 ]]; then
      ASSIGNED_NAME="$tty_agent"
      # Update agent with new session, clear ended_at, update started_at
      current_task=$(echo "$tty_agent_json" | jq -r '.[0].current_task // empty')
      last_task=$(echo "$tty_agent_json" | jq -r '.[0].last_task // empty')
      upsert_agent "$ASSIGNED_NAME" "$SESSION_ID" "$AGENT_TTY" "$NOW" 0 "$current_task" "$last_task"
    fi
  fi
fi

# Priority 3: Find first available codename
if [[ -z "$ASSIGNED_NAME" ]]; then
  # Get list of active agent names (ended agents release their names)
  existing_names=$(get_active_agents | jq -r '.[].name' 2>/dev/null || echo "")

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
agent_exists=$(milvus_query "agents" "id == $(db_quote "$ASSIGNED_NAME")" "id" 1)

if [[ $(echo "$agent_exists" | jq 'length') -eq 0 ]]; then
  # Insert new agent
  upsert_agent "$ASSIGNED_NAME" "$SESSION_ID" "$AGENT_TTY" "$NOW" 0 "" ""
else
  # Update existing agent (recovery case)
  existing=$(milvus_query "agents" "id == $(db_quote "$ASSIGNED_NAME")" "*" 1)
  current_task=$(echo "$existing" | jq -r '.[0].current_task // empty')
  last_task=$(echo "$existing" | jq -r '.[0].last_task // empty')
  upsert_agent "$ASSIGNED_NAME" "$SESSION_ID" "$AGENT_TTY" "$NOW" 0 "$current_task" "$last_task"
fi

# Store HIVEMIND_DIR for MCP server to use (keyed by TTY)
if [[ -n "$AGENT_TTY" ]]; then
  tty_key=$(echo "$AGENT_TTY" | tr '/' '_')
  echo "$HIVEMIND_DIR" > "/tmp/hivemind-dir-${tty_key}"
  # Write initial status file for instant status line reads
  printf '%s\n%s\n%s\n' "$ASSIGNED_NAME" "$current_task" "$last_task" > "/tmp/hivemind-status-${tty_key}"
fi

# Gather info about other active agents
OTHER_AGENTS=""
AGENT_COUNT=0

other_agents_json=$(milvus_query "agents" "ended_at < 1 and id != $(db_quote "$ASSIGNED_NAME")" "name,current_task" 100)
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
assigned_tasks_json=$(milvus_query "tasks" "assignee == $(db_quote "$ASSIGNED_NAME") and state != \"done\"" "seq_id,title,state" 100)
assigned_tasks_json=$(echo "$assigned_tasks_json" | jq -c 'sort_by(.seq_id)')
TASK_INFO=""
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  task_id=$(echo "$line" | jq -r '.seq_id // empty')
  [[ -z "$task_id" ]] && continue

  task_title=$(echo "$line" | jq -r '.title // empty')
  task_state=$(echo "$line" | jq -r '.state // empty')

  if [[ -n "$TASK_INFO" ]]; then
    TASK_INFO="$TASK_INFO, "
  fi
  TASK_INFO="${TASK_INFO}#$task_id: $task_title [$task_state]"
done < <(echo "$assigned_tasks_json" | jq -c '.[]' 2>/dev/null || echo "")

# Check for tasks in review awaiting approval
review_tasks_json=$(milvus_query "tasks" "state == \"review\" and assignee != $(db_quote "$ASSIGNED_NAME")" "seq_id,title,assignee" 100)
review_tasks_json=$(echo "$review_tasks_json" | jq -c 'sort_by(.seq_id)')
REVIEW_INFO=""
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  task_id=$(echo "$line" | jq -r '.seq_id // empty')
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
