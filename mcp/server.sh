#!/bin/bash
# Hivemind MCP Server - All commands as deterministic tools
# Pure bash - only requires jq
#
# This server provides:
# - hive_whoami - Get your agent name
# - hive_agents - List all active agents
# - hive_status - Full coordination dashboard
# - hive_message - Send message to agent or broadcast
# - hive_task - Set or clear current task
# - hive_changes - View recent file changes
# - hive_help - Show command reference

set -u

# Get the script directory for finding utils
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WAKE_SCRIPT="$SCRIPT_DIR/../scripts/utils/wake-agent.sh"

AGENT_NAMES=(
  alfa bravo charlie delta echo foxtrot golf hotel
  india juliet kilo lima mike november oscar papa
  quebec romeo sierra tango uniform victor whiskey
  xray yankee zulu
)

HIVEMIND_DIR="${HIVEMIND_DIR:-.hivemind}"
AGENTS_DIR="$HIVEMIND_DIR/agents"
SESSIONS_DIR="$HIVEMIND_DIR/sessions"
LOCKS_DIR="$HIVEMIND_DIR/locks"
MESSAGES_DIR="$HIVEMIND_DIR/messages"
CHANGELOG="$HIVEMIND_DIR/changelog.jsonl"
MY_AGENT_NAME=""

MCP_DEBUG_LOG="/tmp/hivemind-mcp-debug.log"
log() {
  echo "[Hivemind MCP] $*" >&2
  echo "[$(date)] $*" >> "$MCP_DEBUG_LOG"
}

ensure_dirs() {
  mkdir -p "$AGENTS_DIR" "$LOCKS_DIR" "$MESSAGES_DIR"
}

# Claim agent name with file locking
# Coordinates with hook-based registration: if hooks already registered an agent,
# reuse that name instead of claiming a new one.
# Uses mkdir for atomic locking (cross-platform compatible)
claim_agent_name() {
  ensure_dirs
  local lockdir="$LOCKS_DIR/name-assignment.lockdir"

  # Acquire lock using mkdir (atomic on all platforms)
  local max_attempts=50
  local attempt=0
  while ! mkdir "$lockdir" 2>/dev/null; do
    ((attempt++))
    if [[ $attempt -ge $max_attempts ]]; then
      log "Failed to acquire lock after $max_attempts attempts"
      break
    fi
    sleep 0.1
  done

  # First, check if there's an agent registered by hooks (non-MCP session ID)
  local claimed_name=""

  # Check for hook-registered agent
  if [[ -z "$claimed_name" ]]; then
    for f in "$AGENTS_DIR"/*.json; do
      [[ -f "$f" ]] || continue
      local session_id=$(jq -r '.sessionId // ""' "$f" 2>/dev/null)
      # Skip MCP-registered agents (they have session IDs starting with "mcp-")
      [[ "$session_id" == mcp-* ]] && continue

      # Found a hook-registered agent - reuse this name
      claimed_name=$(jq -r '.sessionName' "$f" 2>/dev/null)
      break
    done
  fi

  # If no hook-registered agent found, claim a new name
  if [[ -z "$claimed_name" ]]; then
    for name in "${AGENT_NAMES[@]}"; do
      if [[ ! -f "$AGENTS_DIR/$name.json" ]]; then
        claimed_name="$name"
        break
      fi
    done

    # Fallback if all names taken
    if [[ -z "$claimed_name" ]]; then
      claimed_name="agent-$(date +%s)-$$"
    fi

    # Create agent file (only if we're claiming a new name)
    local now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    cat > "$AGENTS_DIR/$claimed_name.json" << EOF
{"sessionName":"$claimed_name","sessionId":"mcp-$$","startedAt":"$now","currentTask":"","workingOn":[]}
EOF
    mkdir -p "$MESSAGES_DIR/inbox-$claimed_name"
  fi

  # Release lock
  rmdir "$lockdir" 2>/dev/null || true

  echo "$claimed_name"
}

cleanup() {
  if [[ -n "$MY_AGENT_NAME" && -f "$AGENTS_DIR/$MY_AGENT_NAME.json" ]]; then
    # Only clean up if this agent was created by MCP (not by hooks)
    local session_id=$(jq -r '.sessionId // ""' "$AGENTS_DIR/$MY_AGENT_NAME.json" 2>/dev/null)
    if [[ "$session_id" == "mcp-$$" ]]; then
      rm -f "$AGENTS_DIR/$MY_AGENT_NAME.json"
      rm -rf "$MESSAGES_DIR/inbox-$MY_AGENT_NAME"
      # Clean up locks held by this agent
      if [[ -d "$LOCKS_DIR" ]]; then
        for lock_file in "$LOCKS_DIR"/*.lock; do
          [[ -f "$lock_file" ]] || continue
          local lock_owner=$(jq -r '.sessionName // empty' "$lock_file" 2>/dev/null || true)
          if [[ "$lock_owner" == "$MY_AGENT_NAME" ]]; then
            rm -f "$lock_file"
          fi
        done
      fi
      log "Agent $MY_AGENT_NAME cleaned up"
    else
      log "Agent $MY_AGENT_NAME owned by hooks, not cleaning up"
    fi
  fi
}
trap cleanup EXIT

# Check agent status based on task
# Returns: "idle" (no task), "active" (has task), or "offline" (no agent file)
get_agent_status() {
  local target_agent="$1"
  local agent_file="$AGENTS_DIR/$target_agent.json"

  if [[ ! -f "$agent_file" ]]; then
    echo "offline"
    return
  fi

  local current_task=$(jq -r '.currentTask // ""' "$agent_file")
  if [[ -z "$current_task" ]]; then
    echo "idle"
  else
    echo "active"
  fi
}

# Wake an idle agent by sending a keystroke to their iTerm2 session
# Only wakes if the agent has a TTY registered and the wake script exists
wake_agent() {
  local target_agent="$1"
  local agent_file="$AGENTS_DIR/$target_agent.json"

  if [[ ! -f "$agent_file" ]]; then
    log "wake_agent: agent file not found for $target_agent"
    return 1
  fi

  local agent_tty=$(jq -r '.tty // ""' "$agent_file")
  if [[ -z "$agent_tty" ]]; then
    log "wake_agent: no TTY registered for $target_agent"
    return 1
  fi

  if [[ ! -x "$WAKE_SCRIPT" ]]; then
    log "wake_agent: wake script not found or not executable: $WAKE_SCRIPT"
    return 1
  fi

  log "wake_agent: waking $target_agent at $agent_tty"
  "$WAKE_SCRIPT" "$agent_tty" >/dev/null 2>&1 &
  return 0
}

send_response() {
  local id="$1" result="$2"
  printf '%s\n' "$(jq -c -n --argjson id "$id" --argjson result "$result" '{jsonrpc:"2.0",id:$id,result:$result}')"
}

send_error() {
  local id="$1" code="$2" msg="$3"
  printf '%s\n' "$(jq -c -n --argjson id "$id" --arg c "$code" --arg m "$msg" '{jsonrpc:"2.0",id:$id,error:{code:($c|tonumber),message:$m}}')"
}

text_result() {
  jq -c -n --arg t "$1" '{content:[{type:"text",text:$t}]}'
}

# === TOOL IMPLEMENTATIONS ===

tool_whoami() {
  local session_id="$1"
  local session_file="$SESSIONS_DIR/$session_id.txt"
  if [[ -f "$session_file" ]]; then
    text_result "$(cat "$session_file")"
  else
    text_result "Unknown session"
  fi
}

tool_agents() {
  local output="HIVEMIND AGENTS
===============
"
  local count=0
  for f in "$AGENTS_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    local name=$(jq -r '.sessionName' "$f")
    local task=$(jq -r '.currentTask // ""' "$f")
    local status=$(jq -r '.status' "$f")
    local files=$(jq -r '.workingOn | if length > 0 then join(", ") else "(none)" end' "$f")
    output+="
Agent: $name ($status)"
    [[ -n "$task" && "$task" != "null" ]] && output+="
  Task: $task"
    output+="
  Files: $files"
    ((count++))
  done
  output+="

Total: $count agent(s)"
  text_result "$output"
}

tool_status() {
  local output="HIVEMIND STATUS DASHBOARD
=========================

AGENTS
------"
  for f in "$AGENTS_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    local name=$(jq -r '.sessionName' "$f")
    local task=$(jq -r '.currentTask // "(none)"' "$f")
    [[ "$task" == "" || "$task" == "null" ]] && task="(none)"
    local files=$(jq -r '.workingOn | if length > 0 then join(", ") else "(none)" end' "$f")
    output+="
$name
  Task: $task
  Files: $files"
  done

  # File locks
  output+="

FILE LOCKS
----------"
  local lock_count=0
  if [[ -d "$LOCKS_DIR" ]]; then
    for lock_file in "$LOCKS_DIR"/*.lock; do
      [[ -f "$lock_file" ]] || continue
      [[ "$(basename "$lock_file")" == "name-assignment.lock" ]] && continue
      local lock_owner=$(jq -r '.sessionName // "unknown"' "$lock_file" 2>/dev/null)
      local lock_path=$(jq -r '.filePath // "unknown"' "$lock_file" 2>/dev/null)
      output+="
$lock_path (held by $lock_owner)"
      ((lock_count++))
    done
  fi
  [[ $lock_count -eq 0 ]] && output+="
No active file locks."

  # Message summary
  output+="

MESSAGES
--------
Messages from other agents are delivered automatically with each prompt."

  # Recent changes
  output+="

RECENT CHANGES
--------------"
  if [[ -f "$CHANGELOG" ]]; then
    local changes=$(tail -5 "$CHANGELOG" | while IFS= read -r line; do
      local ts=$(echo "$line" | jq -r '.timestamp // ""' | cut -d'T' -f2 | cut -d'.' -f1)
      local agent=$(echo "$line" | jq -r '.agent // "unknown"')
      local action=$(echo "$line" | jq -r '.action // "changed"')
      local file=$(echo "$line" | jq -r '.file // "unknown"')
      echo "[$ts] $agent: $action $file"
    done)
    if [[ -n "$changes" ]]; then
      output+="
$changes"
    else
      output+="
No changes recorded."
    fi
  else
    output+="
No changes recorded."
  fi

  text_result "$output"
}

tool_message() {
  local session_id="$1" target="$2" body="$3"
  local now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local msg_id="msg-$(date +%s)-$$-$RANDOM"

  # Look up agent name from session
  local session_file="$SESSIONS_DIR/$session_id.txt"
  local from_agent="unknown"
  if [[ -f "$session_file" ]]; then
    from_agent=$(cat "$session_file")
  fi

  if [[ "$target" == "all" ]]; then
    # Fan-out: send individual message to each active agent's inbox
    local recipient_count=0
    local recipients=""
    for agent_file in "$AGENTS_DIR"/*.json; do
      [[ -f "$agent_file" ]] || continue
      local agent_name
      agent_name=$(basename "$agent_file" .json)
      # Don't send to self
      [[ "$agent_name" == "$from_agent" ]] && continue
      # Create unique message ID for each recipient
      local recipient_msg_id="msg-$(date +%s)-$$-$RANDOM"
      mkdir -p "$MESSAGES_DIR/inbox-$agent_name"
      jq -n --arg id "$recipient_msg_id" --arg from "$from_agent" --arg to "$agent_name" \
            --arg ts "$now" --arg body "[BROADCAST] $body" \
            '{id:$id,from:$from,to:$to,timestamp:$ts,body:$body}' \
            > "$MESSAGES_DIR/inbox-$agent_name/$recipient_msg_id.json"
      ((recipient_count++))
      [[ -n "$recipients" ]] && recipients+=", "
      recipients+="$agent_name"
    done
    if [[ $recipient_count -eq 0 ]]; then
      text_result "Broadcast sent but no other agents are active."
    else
      text_result "Broadcast sent to $recipient_count agent(s): $recipients"
    fi
  else
    # Check if target exists
    if [[ ! -f "$AGENTS_DIR/$target.json" ]]; then
      local available=$(ls "$AGENTS_DIR"/*.json 2>/dev/null | xargs -I{} basename {} .json | tr '\n' ', ' | sed 's/,$//')
      text_result "Agent '$target' not found. Active agents: $available"
      return
    fi
    mkdir -p "$MESSAGES_DIR/inbox-$target"
    # Use jq to properly escape JSON
    jq -n --arg id "$msg_id" --arg from "$from_agent" --arg to "$target" \
          --arg ts "$now" --arg body "$body" \
          '{id:$id,from:$from,to:$to,timestamp:$ts,body:$body}' \
          > "$MESSAGES_DIR/inbox-$target/$msg_id.json"

    # Check recipient status and report accordingly
    local recipient_status=$(get_agent_status "$target")
    if [[ "$recipient_status" == "idle" ]]; then
      # Wake the idle agent
      if wake_agent "$target"; then
        text_result "Message sent to $target (idle - waking agent): \"$body\""
      else
        text_result "Message sent to $target (idle - will deliver on their next action): \"$body\""
      fi
    elif [[ "$recipient_status" == "offline" ]]; then
      text_result "Message sent to $target (offline - will deliver when they reconnect): \"$body\""
    else
      text_result "Message sent to $target (active): \"$body\""
    fi
  fi
}

tool_task() {
  local session_id="$1" description="$2"

  # Look up agent name from session
  local session_file="$SESSIONS_DIR/$session_id.txt"
  if [[ ! -f "$session_file" ]]; then
    text_result "Error: Unknown session"
    return
  fi
  local agent_name=$(cat "$session_file")

  local agent_file="$AGENTS_DIR/$agent_name.json"
  if [[ ! -f "$agent_file" ]]; then
    text_result "Error: Agent file not found"
    return
  fi

  if [[ -z "$description" ]]; then
    jq '.currentTask = ""' "$agent_file" > "$agent_file.tmp" && mv "$agent_file.tmp" "$agent_file"
    text_result "Task cleared."
  else
    jq --arg t "$description" '.currentTask = $t' "$agent_file" > "$agent_file.tmp" && mv "$agent_file.tmp" "$agent_file"
    text_result "Task set: \"$description\""
  fi
}

tool_changes() {
  local count="${1:-20}"
  local output="HIVEMIND CHANGELOG
==================

Last $count changes:
"

  if [[ ! -f "$CHANGELOG" ]]; then
    text_result "No changes recorded yet."
    return
  fi

  local changes=$(tail -"$count" "$CHANGELOG" | while IFS= read -r line; do
    local ts=$(echo "$line" | jq -r '.timestamp // ""' | cut -d'T' -f2 | cut -d'.' -f1)
    local agent=$(echo "$line" | jq -r '.agent // "unknown"')
    local action=$(echo "$line" | jq -r '.action // "changed"')
    local file=$(echo "$line" | jq -r '.file // "unknown"')
    echo "[$ts] $agent: $action $file"
  done)

  if [[ -n "$changes" ]]; then
    output+="$changes"
  else
    output+="No changes recorded."
  fi

  text_result "$output"
}

tool_help() {
  text_result "HIVEMIND COMMANDS
=================

hive_whoami
  Get my agent identity (no parameters)

hive_agents
  List all active agents (no parameters)

hive_status
  Show coordination dashboard (no parameters)

hive_message
  Send message to another agent or broadcast
  Parameters:
    target (required) - Agent name (alfa, bravo, etc.) or \"all\" for broadcast
    body (required)   - Message content

hive_task
  Set or clear my current task
  Parameters:
    description (optional) - Task description, omit or empty to clear

hive_changes
  View recent file changes
  Parameters:
    count (optional) - Number of changes to show (default 20)

hive_help
  Show this help (no parameters)

Each session gets a unique phonetic codename (alfa, bravo, charlie...).
Names are released when the session ends.

MESSAGE DELIVERY
----------------
Messages from other agents are delivered automatically with each prompt.
When another agent sends you a message, you will see it prefixed with
[HIVE AGENT MESSAGE] in your context.

COORDINATION TIPS
-----------------
1. Set your task so others know what you're working on
2. Check hive_status before editing shared files
3. Use hive_message to coordinate on conflicts
4. Review hive_changes to see recent activity"
}

# === MCP PROTOCOL ===

handle_initialize() {
  send_response "$1" '{"protocolVersion":"2024-11-05","serverInfo":{"name":"hivemind","version":"1.0.0"},"capabilities":{"tools":{}}}'
}

handle_tools_list() {
  send_response "$1" '{"tools":[
    {"name":"hive_whoami","description":"Get my own agent identity. When reporting this to the user, respond in first person: I am agent X.","inputSchema":{"type":"object","properties":{},"required":[]}},
    {"name":"hive_agents","description":"List all active Hivemind agents with status, tasks, and files they are working on","inputSchema":{"type":"object","properties":{},"required":[]}},
    {"name":"hive_status","description":"Show full Hivemind coordination dashboard with agents, file locks, messages, and recent changes","inputSchema":{"type":"object","properties":{},"required":[]}},
    {"name":"hive_message","description":"Send a message to another agent or broadcast to all agents","inputSchema":{"type":"object","properties":{"target":{"type":"string","description":"Agent name (alfa, bravo, etc.) or \"all\" for broadcast"},"body":{"type":"string","description":"Message content"}},"required":["target","body"]}},
    {"name":"hive_task","description":"Set or clear your current task (visible to other agents in status)","inputSchema":{"type":"object","properties":{"description":{"type":"string","description":"Task description (omit or empty string to clear)"}},"required":[]}},
    {"name":"hive_changes","description":"View recent file changes made by all agents","inputSchema":{"type":"object","properties":{"count":{"type":"integer","description":"Number of changes to show (default 20)"}},"required":[]}},
    {"name":"hive_help","description":"Show Hivemind command reference. Display the full output to the user as-is.","inputSchema":{"type":"object","properties":{},"required":[]}}
  ]}'
}

handle_tools_call() {
  local id="$1" line="$2"
  local tool=$(echo "$line" | jq -r '.params.name')
  local args=$(echo "$line" | jq -r '.params.arguments // {}')

  case "$tool" in
    hive_whoami)
      local sid=$(echo "$args" | jq -r '.session_id // ""')
      if [[ -z "$sid" ]]; then
        send_error "$id" "-32602" "Missing session_id"
      else
        send_response "$id" "$(tool_whoami "$sid")"
      fi
      ;;
    hive_agents)  send_response "$id" "$(tool_agents)" ;;
    hive_status)  send_response "$id" "$(tool_status)" ;;
    hive_help)    send_response "$id" "$(tool_help)" ;;
    hive_message)
      log "hive_message called with args: $args"
      local sid=$(echo "$args" | jq -r '.session_id // ""')
      local target=$(echo "$args" | jq -r '.target // ""')
      local body=$(echo "$args" | jq -r '.body // ""')
      log "hive_message parsed: sid='$sid' target='$target' body='$body'"
      if [[ -z "$sid" ]]; then
        log "hive_message ERROR: Missing session_id"
        send_error "$id" "-32602" "Missing session_id"
      elif [[ -z "$target" || -z "$body" ]]; then
        log "hive_message ERROR: Missing target or body"
        send_error "$id" "-32602" "Missing required parameters: target and body"
      else
        log "hive_message: calling tool_message"
        send_response "$id" "$(tool_message "$sid" "$target" "$body")"
      fi
      ;;
    hive_task)
      local sid=$(echo "$args" | jq -r '.session_id // ""')
      local desc=$(echo "$args" | jq -r '.description // ""')
      if [[ -z "$sid" ]]; then
        send_error "$id" "-32602" "Missing session_id"
      else
        send_response "$id" "$(tool_task "$sid" "$desc")"
      fi
      ;;
    hive_changes)
      local count=$(echo "$args" | jq -r '.count // 20')
      send_response "$id" "$(tool_changes "$count")"
      ;;
    *) send_error "$id" "-32601" "Unknown tool: $tool" ;;
  esac
}

main() {
  MY_AGENT_NAME=$(claim_agent_name)
  log "Claimed agent name: $MY_AGENT_NAME"

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    log "INCOMING: $line"
    local method=$(echo "$line" | jq -r '.method // empty')
    local id=$(echo "$line" | jq '.id // null')

    case "$method" in
      initialize) handle_initialize "$id" ;;
      notifications/initialized) ;; # No response
      tools/list) handle_tools_list "$id" ;;
      tools/call) handle_tools_call "$id" "$line" ;;
      *) [[ "$id" != "null" ]] && send_error "$id" "-32601" "Method not found: $method" ;;
    esac
  done
}

main
