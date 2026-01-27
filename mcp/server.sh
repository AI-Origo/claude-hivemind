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
# - hive_inbox - View message history
# - hive_help - Show command reference

set -u

# Get the script directory for finding utils
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WAKE_SCRIPT="$SCRIPT_DIR/../scripts/utils/wake-agent.sh"

# Debug logging (defined early so we can log during startup)
MCP_DEBUG_LOG="/tmp/hivemind-mcp-debug.log"
log() {
  echo "[Hivemind MCP] $*" >&2
  echo "[$(date)] $*" >> "$MCP_DEBUG_LOG"
}

# Name of the hivemind directory (can be customized via env)
HIVEMIND_DIRNAME="${HIVEMIND_DIRNAME:-.hivemind}"

# Find hivemind directory by searching up from current directory
find_hivemind_dir() {
  local dir="${1:-$(pwd)}"
  while [[ "$dir" != "/" ]]; do
    if [[ -d "$dir/$HIVEMIND_DIRNAME" ]]; then
      echo "$dir/$HIVEMIND_DIRNAME"
      return 0
    fi
    dir=$(dirname "$dir")
  done
  return 1
}

# Debug logging for subdirectory investigation
log "=== MCP SERVER STARTUP ==="
log "pwd: $(pwd)"
log "HIVEMIND_DIRNAME env: ${HIVEMIND_DIRNAME}"

# Search up directory tree for .hivemind, fall back to current dir
HIVEMIND_DIR=$(find_hivemind_dir)
if [[ -z "$HIVEMIND_DIR" ]]; then
  HIVEMIND_DIR="$HIVEMIND_DIRNAME"
fi

log "HIVEMIND_DIR resolved: $HIVEMIND_DIR"
log "HIVEMIND_DIR exists: $(test -d "$HIVEMIND_DIR" && echo yes || echo no)"

# Source database functions
export HIVEMIND_DIR
source "$SCRIPT_DIR/../scripts/lib/db.sh"

# Check DuckDB availability at startup
HAS_DUCKDB=false
if command -v duckdb &> /dev/null; then
  if db_ensure_initialized; then
    HAS_DUCKDB=true
  else
    log "DuckDB installed but database initialization failed"
  fi
fi

# Look up agent name using TTY first, then session_id
lookup_agent_name() {
  local tty="$1"
  local session_id="$2"

  if [[ "$HAS_DUCKDB" != "true" ]]; then
    echo ""
    return
  fi

  local agent_name=""
  if [[ -n "$tty" ]]; then
    agent_name=$(db_query "SELECT name FROM agents WHERE tty = $(db_quote "$tty") AND ended_at IS NULL LIMIT 1" | jq -r '.[0].name // empty')
  fi
  if [[ -z "$agent_name" && -n "$session_id" ]]; then
    agent_name=$(db_query "SELECT name FROM agents WHERE session_id = $(db_quote "$session_id") AND ended_at IS NULL LIMIT 1" | jq -r '.[0].name // empty')
  fi
  echo "$agent_name"
}

cleanup() {
  # MCP server no longer registers agents - hooks handle all registration.
  # Nothing to clean up here.
  :
}
trap cleanup EXIT

# Check agent status based on task
# Returns: "idle" (no task), "active" (has task), or "offline" (not in DB)
get_agent_status() {
  local target_agent="$1"

  if [[ "$HAS_DUCKDB" != "true" ]]; then
    echo "offline"
    return
  fi

  local task=$(db_query "SELECT current_task FROM agents WHERE name = $(db_quote "$target_agent") AND ended_at IS NULL" | jq -r '.[0].current_task // empty')

  if [[ -z "$task" ]]; then
    # Check if agent exists at all
    local exists=$(db_query "SELECT 1 FROM agents WHERE name = $(db_quote "$target_agent") AND ended_at IS NULL" | jq -r '.[0] // empty')
    if [[ -z "$exists" ]]; then
      echo "offline"
    else
      echo "idle"
    fi
  else
    echo "active"
  fi
}

# Wake an idle agent by sending a keystroke to their iTerm2 session
# Only wakes if the agent has a TTY registered and the wake script exists
wake_agent() {
  local target_agent="$1"

  if [[ "$HAS_DUCKDB" != "true" ]]; then
    log "wake_agent: DuckDB not available"
    return 1
  fi

  local agent_tty=$(db_query "SELECT tty FROM agents WHERE name = $(db_quote "$target_agent") AND ended_at IS NULL" | jq -r '.[0].tty // empty')
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
  local tty="$2"
  local agent_name=$(lookup_agent_name "$tty" "$session_id")
  if [[ -n "$agent_name" ]]; then
    text_result "$agent_name"
  else
    text_result "Unknown session"
  fi
}

tool_agents() {
  if [[ "$HAS_DUCKDB" != "true" ]]; then
    text_result "DuckDB not installed. Run hive_setup first."
    return
  fi

  local output="HIVEMIND AGENTS
===============
"
  local agents_json=$(db_query "SELECT name, current_task FROM agents WHERE ended_at IS NULL ORDER BY name")
  local count=0

  if [[ -n "$agents_json" && "$agents_json" != "[]" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      local name=$(echo "$line" | jq -r '.name')
      local task=$(echo "$line" | jq -r '.current_task // ""')
      local status="idle"
      [[ -n "$task" ]] && status="active"
      output+="
Agent: $name ($status)"
      [[ -n "$task" && "$task" != "null" ]] && output+="
  Task: $task"
      output+="
  Files: (none)"
      ((count++))
    done < <(echo "$agents_json" | jq -c '.[]')
  fi

  output+="

Total: $count agent(s)"
  text_result "$output"
}

tool_status() {
  if [[ "$HAS_DUCKDB" != "true" ]]; then
    text_result "DuckDB not installed. Run hive_setup first."
    return
  fi

  local output="HIVEMIND STATUS DASHBOARD
=========================

AGENTS
------"
  local agents_json=$(db_query "SELECT name, current_task FROM agents WHERE ended_at IS NULL ORDER BY name")

  if [[ -n "$agents_json" && "$agents_json" != "[]" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      local name=$(echo "$line" | jq -r '.name')
      local task=$(echo "$line" | jq -r '.current_task // ""')
      [[ -z "$task" || "$task" == "null" ]] && task="(none)"
      output+="
$name
  Task: $task
  Files: (none)"
    done < <(echo "$agents_json" | jq -c '.[]')
  fi

  # File locks (from database)
  output+="

FILE LOCKS
----------"
  local locks_json=$(db_query "SELECT file_path, agent_name FROM file_locks")
  local lock_count=0

  if [[ -n "$locks_json" && "$locks_json" != "[]" ]]; then
    while IFS= read -r lock_line; do
      [[ -z "$lock_line" ]] && continue
      output+="
$lock_line"
      ((lock_count++))
    done < <(echo "$locks_json" | jq -r '.[] | "\(.file_path) (held by \(.agent_name))"' 2>/dev/null)
  fi

  [[ $lock_count -eq 0 ]] && output+="
No active file locks."

  # Message summary
  output+="

MESSAGES
--------
Messages from other agents are delivered automatically with each prompt."

  # Recent changes (from database)
  output+="

RECENT CHANGES
--------------"
  local changes_json=$(db_query "SELECT timestamp, agent, action, file_path FROM changelog ORDER BY id DESC LIMIT 5")

  if [[ -n "$changes_json" && "$changes_json" != "[]" ]]; then
    local changes=$(echo "$changes_json" | jq -r '.[] | "[\(.timestamp | split("T")[1] | split(".")[0])] \(.agent): \(.action) \(.file_path)"' 2>/dev/null)
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
  local session_id="$1" target="$2" body="$3" tty="$4"
  local msg_id="msg-$(date +%s)-$$-$RANDOM"

  if [[ "$HAS_DUCKDB" != "true" ]]; then
    text_result "DuckDB not installed. Run hive_setup first."
    return
  fi

  # Look up agent name (TTY first, then session_id)
  local from_agent=$(lookup_agent_name "$tty" "$session_id")
  if [[ -z "$from_agent" ]]; then
    from_agent="unknown"
  fi

  if [[ "$target" == "all" ]]; then
    # Fan-out: send individual message to each active agent (from DB)
    local recipient_count=0
    local recipients=""
    local agents_json=$(db_query "SELECT name FROM agents WHERE ended_at IS NULL ORDER BY name")

    if [[ -n "$agents_json" && "$agents_json" != "[]" ]]; then
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local agent_name=$(echo "$line" | jq -r '.name')
        # Don't send to self
        [[ "$agent_name" == "$from_agent" ]] && continue
        # Create unique message ID for each recipient
        local recipient_msg_id="msg-$(date +%s)-$$-$RANDOM"
        # Insert message into database
        db_exec "INSERT INTO messages (id, from_agent, to_agent, body, priority, created_at)
                 VALUES ($(db_quote "$recipient_msg_id"), $(db_quote "$from_agent"), $(db_quote "$agent_name"),
                         $(db_quote "[BROADCAST] $body"), 'normal', now())"
        ((recipient_count++))
        [[ -n "$recipients" ]] && recipients+=", "
        recipients+="$agent_name"
      done < <(echo "$agents_json" | jq -c '.[]')
    fi

    if [[ $recipient_count -eq 0 ]]; then
      text_result "Broadcast sent but no other agents are active."
    else
      text_result "Broadcast sent to $recipient_count agent(s): $recipients"
    fi
  else
    # Check if target exists in DB
    if ! db_exists "agents" "name = $(db_quote "$target") AND ended_at IS NULL"; then
      local available=$(db_query "SELECT name FROM agents WHERE ended_at IS NULL ORDER BY name" | jq -r '.[].name' | tr '\n' ', ' | sed 's/,$//')
      text_result "Agent '$target' not found. Active agents: $available"
      return
    fi
    # Insert message into database
    db_exec "INSERT INTO messages (id, from_agent, to_agent, body, priority, created_at)
             VALUES ($(db_quote "$msg_id"), $(db_quote "$from_agent"), $(db_quote "$target"),
                     $(db_quote "$body"), 'normal', now())"

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

tool_inbox() {
  local session_id="$1" limit="$2" unread_only="$3" tty="$4"

  [[ "$HAS_DUCKDB" != "true" ]] && { text_result "DuckDB not installed."; return; }

  local agent_name=$(lookup_agent_name "$tty" "$session_id")
  [[ -z "$agent_name" ]] && { text_result "Agent not registered."; return; }

  limit=${limit:-10}
  local where_clause="to_agent = $(db_quote "$agent_name")"
  [[ "$unread_only" == "true" ]] && where_clause="$where_clause AND delivered_at IS NULL"

  local messages=$(db_query "SELECT from_agent, body, created_at, delivered_at FROM messages WHERE $where_clause ORDER BY created_at DESC LIMIT $limit")

  if [[ -z "$messages" || "$messages" == "[]" ]]; then
    text_result "No messages found."
  else
    local output="Your recent messages:\n"
    while IFS= read -r msg; do
      local from=$(echo "$msg" | jq -r '.from_agent')
      local body=$(echo "$msg" | jq -r '.body')
      local time=$(echo "$msg" | jq -r '.created_at')
      local status=$([[ $(echo "$msg" | jq -r '.delivered_at') == "null" ]] && echo "[UNREAD]" || echo "")
      output+="$status From $from ($time): $body\n"
    done < <(echo "$messages" | jq -c '.[]')
    text_result "$output"
  fi
}

tool_task() {
  local session_id="$1" description="$2" tty="$3"

  if [[ "$HAS_DUCKDB" != "true" ]]; then
    text_result "DuckDB not installed. Run hive_setup first."
    return
  fi

  # Look up agent name (TTY first, then session_id)
  local agent_name=$(lookup_agent_name "$tty" "$session_id")
  if [[ -z "$agent_name" ]]; then
    text_result "Error: Unknown session"
    return
  fi

  # Check agent exists in DB
  local exists=$(db_query "SELECT 1 FROM agents WHERE name = $(db_quote "$agent_name") AND ended_at IS NULL" | jq -r '.[0] // empty')
  if [[ -z "$exists" ]]; then
    text_result "Error: Agent not found in database"
    return
  fi

  if [[ -z "$description" ]]; then
    # Copy current_task to last_task before clearing
    db_exec "UPDATE agents SET last_task = current_task, current_task = NULL WHERE name = $(db_quote "$agent_name")"
    text_result "Task cleared."
  else
    # Set new task and clear last_task
    db_exec "UPDATE agents SET current_task = $(db_quote "$description"), last_task = NULL WHERE name = $(db_quote "$agent_name")"
    text_result "Task set: \"$description\""
  fi
}

tool_changes() {
  local count="${1:-20}"
  local output="HIVEMIND CHANGELOG
==================

Last $count changes:
"

  # Query changelog from database
  local changes_json=$(db_query "SELECT timestamp, agent, action, file_path FROM changelog ORDER BY id DESC LIMIT $count")

  if [[ -z "$changes_json" || "$changes_json" == "[]" ]]; then
    text_result "No changes recorded yet."
    return
  fi

  # Format changes for display
  local changes=$(echo "$changes_json" | jq -r '.[] | "[\(.timestamp | split("T")[1] | split(".")[0])] \(.agent): \(.action) \(.file_path)"' 2>/dev/null)

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

hive_setup
  First-time setup: installs DuckDB and configures status line
  Run this once when starting with Hivemind

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

hive_inbox
  View your message history
  Parameters:
    limit (optional) - Maximum messages to return (default 10)
    unread_only (optional) - Only show undelivered messages (default false)

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

tool_setup() {
  local output=""

  # Step 1: Check/Install DuckDB
  if command -v duckdb &> /dev/null; then
    output+="✓ DuckDB is installed ($(duckdb --version 2>/dev/null | head -1 || echo 'version unknown'))\n"
  else
    output+="Installing DuckDB...\n"
    if command -v brew &> /dev/null; then
      if brew install duckdb >> "$MCP_DEBUG_LOG" 2>&1; then
        output+="✓ DuckDB installed successfully via Homebrew\n"
      else
        output+="✗ Failed to install DuckDB. Please install manually: brew install duckdb\n"
      fi
    elif command -v apt-get &> /dev/null; then
      if sudo apt-get update >> "$MCP_DEBUG_LOG" 2>&1 && sudo apt-get install -y duckdb >> "$MCP_DEBUG_LOG" 2>&1; then
        output+="✓ DuckDB installed successfully via apt\n"
      else
        output+="✗ Failed to install DuckDB. Please install manually.\n"
      fi
    else
      output+="✗ Cannot auto-install DuckDB. Please install manually:\n"
      output+="  macOS:  brew install duckdb\n"
      output+="  Linux:  https://duckdb.org/docs/installation\n"
    fi
  fi

  # Step 2: Initialize database (if DuckDB now available)
  if command -v duckdb &> /dev/null; then
    if db_ensure_initialized; then
      HAS_DUCKDB=true
      output+="✓ Database initialized\n"
    else
      output+="✗ Database initialization failed. Check $MCP_DEBUG_LOG for details.\n"
    fi
  fi

  # Step 3: Install status line config
  local settings_dir="$HOME/.claude"
  local settings_file="$settings_dir/settings.json"
  # Status line queries DuckDB directly for agent info
  # Walks up process tree to find a process with a TTY (needed because status line runs in subprocess)
  local statusline_cmd='input=$(cat); cwd=$(echo "$input" | jq -r '"'"'.workspace.current_dir'"'"'); dir=$(basename "$cwd"); hivemind='"'"''"'"'; task_info='"'"''"'"'; agent='"'"''"'"'; hivemind_dir='"'"''"'"'; d="$cwd"; while [ "$d" != "/" ]; do if [ -d "$d/.hivemind" ]; then hivemind_dir="$d/.hivemind"; break; fi; d=$(dirname "$d"); done; if [ -n "$hivemind_dir" ] && [ -f "$hivemind_dir/hive.db" ]; then pid=$$; tty=""; while [ -n "$pid" ] && [ "$pid" != "1" ]; do ptty=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d '"'"' '"'"'); if [ -n "$ptty" ] && [ "$ptty" != "??" ]; then tty="/dev/$ptty"; break; fi; pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '"'"' '"'"'); done; if [ -n "$tty" ]; then row=$(duckdb -json "$hivemind_dir/hive.db" "SELECT name, current_task, last_task FROM agents WHERE tty = '"'"'$tty'"'"' AND ended_at IS NULL LIMIT 1" 2>/dev/null | jq -r '"'"'.[0] // empty'"'"'); if [ -n "$row" ]; then agent=$(echo "$row" | jq -r '"'"'.name // empty'"'"'); task=$(echo "$row" | jq -r '"'"'.current_task // empty'"'"'); lastTask=$(echo "$row" | jq -r '"'"'.last_task // empty'"'"'); fi; fi; fi; if [ -n "$agent" ]; then hivemind=$(printf '"'"'\033[1;35m[%s]\033[0m '"'"' "$agent"); if [ -n "$task" ]; then task_info=$(printf '"'"'\n\033[0;33m%s\033[0m'"'"' "$task"); elif [ -n "$lastTask" ]; then task_info=$(printf '"'"'\n\033[0;90m%s\033[0m'"'"' "$lastTask"); elif [ -f "$hivemind_dir/version.txt" ]; then version=$(cat "$hivemind_dir/version.txt"); task_info=$(printf '"'"'\n\033[0;35mhivemind v%s\033[0m'"'"' "$version"); fi; fi; git_info='"'"''"'"'; if cd "$cwd" 2>/dev/null && git rev-parse --git-dir > /dev/null 2>&1; then branch=$(git --no-optional-locks branch --show-current 2>/dev/null || git --no-optional-locks rev-parse --short HEAD 2>/dev/null); if [ -n "$branch" ]; then if [ -n "$(git --no-optional-locks status --porcelain 2>/dev/null)" ]; then git_info=$(printf '"'"' \033[1;34mgit:(\033[0;31m%s\033[1;34m) \033[0;33m✗\033[0m'"'"' "$branch"); else git_info=$(printf '"'"'\033[1;34mgit:(\033[0;31m%s\033[1;34m)\033[0m'"'"' "$branch"); fi; fi; fi; printf '"'"'%s\033[1;32m➜\033[0m  \033[0;36m%s\033[0m%s%s'"'"' "$hivemind" "$dir" "$git_info" "$task_info"'

  mkdir -p "$settings_dir"

  if [[ -f "$settings_file" ]]; then
    jq --arg cmd "$statusline_cmd" '.statusLine = {"type": "command", "command": $cmd}' \
      "$settings_file" > "$settings_file.tmp" && mv "$settings_file.tmp" "$settings_file"
  else
    jq -n --arg cmd "$statusline_cmd" '{"statusLine": {"type": "command", "command": $cmd}}' \
      > "$settings_file"
  fi
  output+="✓ Status line config installed to ~/.claude/settings.json\n"

  output+="\nIMPORTANT! For semantic search across tasks, knowledge, and memory:\n"
  output+="  cp .hivemind/.env.example .hivemind/.env\n"
  output+="  # Then add your OpenAI API key to .hivemind/.env\n"

  output+="\nSetup complete! Restart Claude Code to apply changes."
  text_result "$(echo -e "$output")"
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
    {"name":"hive_inbox","description":"View your message history. Returns recent messages you have received.","inputSchema":{"type":"object","properties":{"limit":{"type":"number","description":"Maximum messages to return (default: 10)"},"unread_only":{"type":"boolean","description":"Only show undelivered messages (default: false)"}},"required":[]}},
    {"name":"hive_help","description":"Show Hivemind command reference. Display the full output to the user as-is.","inputSchema":{"type":"object","properties":{},"required":[]}},
    {"name":"hive_setup","description":"Set up Hivemind: installs DuckDB (if missing) and configures status line. Run this first when using Hivemind in a new project.","inputSchema":{"type":"object","properties":{},"required":[]}}
  ]}'
}

handle_tools_call() {
  local id="$1" line="$2"
  local tool=$(echo "$line" | jq -r '.params.name')
  local args=$(echo "$line" | jq -r '.params.arguments // {}')

  case "$tool" in
    hive_whoami)
      local sid=$(echo "$args" | jq -r '.session_id // ""')
      local tty=$(echo "$args" | jq -r '.tty // ""')
      if [[ -z "$sid" && -z "$tty" ]]; then
        send_error "$id" "-32602" "Missing session_id or tty"
      else
        send_response "$id" "$(tool_whoami "$sid" "$tty")"
      fi
      ;;
    hive_agents)  send_response "$id" "$(tool_agents)" ;;
    hive_status)  send_response "$id" "$(tool_status)" ;;
    hive_help)    send_response "$id" "$(tool_help)" ;;
    hive_message)
      log "hive_message called with args: $args"
      local sid=$(echo "$args" | jq -r '.session_id // ""')
      local tty=$(echo "$args" | jq -r '.tty // ""')
      local target=$(echo "$args" | jq -r '.target // ""')
      local body=$(echo "$args" | jq -r '.body // ""')
      log "hive_message parsed: sid='$sid' tty='$tty' target='$target' body='$body'"
      if [[ -z "$sid" && -z "$tty" ]]; then
        log "hive_message ERROR: Missing session_id and tty"
        send_error "$id" "-32602" "Missing session_id or tty"
      elif [[ -z "$target" || -z "$body" ]]; then
        log "hive_message ERROR: Missing target or body"
        send_error "$id" "-32602" "Missing required parameters: target and body"
      else
        log "hive_message: calling tool_message"
        send_response "$id" "$(tool_message "$sid" "$target" "$body" "$tty")"
      fi
      ;;
    hive_task)
      local sid=$(echo "$args" | jq -r '.session_id // ""')
      local tty=$(echo "$args" | jq -r '.tty // ""')
      local desc=$(echo "$args" | jq -r '.description // ""')
      if [[ -z "$sid" && -z "$tty" ]]; then
        send_error "$id" "-32602" "Missing session_id or tty"
      else
        send_response "$id" "$(tool_task "$sid" "$desc" "$tty")"
      fi
      ;;
    hive_changes)
      local count=$(echo "$args" | jq -r '.count // 20')
      send_response "$id" "$(tool_changes "$count")"
      ;;
    hive_inbox)
      local sid=$(echo "$args" | jq -r '.session_id // ""')
      local tty=$(echo "$args" | jq -r '.tty // ""')
      local limit=$(echo "$args" | jq -r '.limit // ""')
      local unread_only=$(echo "$args" | jq -r '.unread_only // ""')
      if [[ -z "$sid" && -z "$tty" ]]; then
        send_error "$id" "-32602" "Missing session_id or tty"
      else
        send_response "$id" "$(tool_inbox "$sid" "$limit" "$unread_only" "$tty")"
      fi
      ;;
    hive_setup)
      send_response "$id" "$(tool_setup)"
      ;;
    *) send_error "$id" "-32601" "Unknown tool: $tool" ;;
  esac
}

main() {
  # Agent registration is handled by hooks (session-start.sh), not MCP server.
  # The MCP server just looks up agents by TTY/session_id when needed.

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
