#!/bin/bash
# Hivemind MCP Server - All commands as deterministic tools
# Pure bash - only requires jq and curl
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
START_SCRIPT="$SCRIPT_DIR/../scripts/start-milvus.sh"

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

# Check Milvus availability at startup
HAS_MILVUS=false
if milvus_ready; then
  HAS_MILVUS=true
  log "Milvus is ready"
else
  log "Milvus not available"
fi

# Look up agent name using TTY first, then session_id
lookup_agent_name() {
  local tty="$1"
  local session_id="$2"

  if [[ "$HAS_MILVUS" != "true" ]]; then
    echo ""
    return
  fi

  local agent_name=""
  if [[ -n "$tty" ]]; then
    agent_name=$(get_agent_by_tty "$tty" | jq -r '.[0].name // empty')
  fi
  if [[ -z "$agent_name" && -n "$session_id" ]]; then
    agent_name=$(get_agent_by_session "$session_id" | jq -r '.[0].name // empty')
  fi
  echo "$agent_name"
}

# Derive TTY from process tree (fallback when not provided by client)
derive_tty() {
  local pid=$$
  local tty=""
  while [[ -n "$pid" && "$pid" != "1" ]]; do
    local ptty=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
    if [[ -n "$ptty" && "$ptty" != "??" ]]; then
      tty="/dev/$ptty"
      break
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  done
  echo "$tty"
}

# Get HIVEMIND_DIR for the current TTY (set by session-start hook)
# This ensures MCP server uses the same collection as the hook
resolve_hivemind_dir() {
  local tty=$(derive_tty)
  if [[ -n "$tty" ]]; then
    local tty_key=$(echo "$tty" | tr '/' '_')
    local dir_file="/tmp/hivemind-dir-${tty_key}"
    if [[ -f "$dir_file" ]]; then
      local dir=$(cat "$dir_file")
      if [[ -n "$dir" && -d "$dir" ]]; then
        export HIVEMIND_DIR="$dir"
        log "HIVEMIND_DIR resolved from TTY $tty: $dir"
      fi
    fi
  fi
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

  if [[ "$HAS_MILVUS" != "true" ]]; then
    echo "offline"
    return
  fi

  local agent_json
  agent_json=$(milvus_query "agents" "id == $(db_quote "$target_agent") and ended_at < 1" "current_task" 1)
  local task=$(echo "$agent_json" | jq -r '.[0].current_task // empty')

  if [[ -z "$task" ]]; then
    # Check if agent exists at all
    if [[ $(echo "$agent_json" | jq 'length') -eq 0 ]]; then
      echo "offline"
    else
      echo "idle"
    fi
  else
    echo "active"
  fi
}

# Wake an idle agent by sending a keystroke to their iTerm session
wake_agent() {
  local target_agent="$1"

  if [[ "$HAS_MILVUS" != "true" ]]; then
    log "wake_agent: Milvus not available"
    return 1
  fi

  local agent_json
  agent_json=$(milvus_query "agents" "id == $(db_quote "$target_agent") and ended_at < 1" "tty" 1)
  local agent_tty=$(echo "$agent_json" | jq -r '.[0].tty // empty')

  if [[ -z "$agent_tty" ]]; then
    log "wake_agent: no TTY registered for $target_agent"
    return 1
  fi

  if [[ ! -x "$WAKE_SCRIPT" ]]; then
    log "wake_agent: wake script not found or not executable: $WAKE_SCRIPT"
    return 1
  fi

  log "wake_agent: waking $target_agent at $agent_tty"
  "$WAKE_SCRIPT" "$agent_tty" >> "$MCP_DEBUG_LOG" 2>&1 &

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
  if [[ "$HAS_MILVUS" != "true" ]]; then
    text_result "Hivemind Milvus not available. Run hive_setup first."
    return
  fi

  local output=""
  local agents_json=$(get_active_agents)
  local count=0

  if [[ -n "$agents_json" && "$agents_json" != "[]" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      local name=$(echo "$line" | jq -r '.name')
      # Check tasks collection for in_progress tasks
      local agent_tasks=$(milvus_query "tasks" "assignee == $(db_quote "$name") and state == \"in_progress\"" "seq_id,title" 5)
      local task_str=""
      while IFS= read -r tline; do
        [[ -z "$tline" ]] && continue
        local tid=$(echo "$tline" | jq -r '.seq_id // empty')
        [[ -z "$tid" ]] && continue
        local ttitle=$(echo "$tline" | jq -r '.title // ""')
        [[ -n "$task_str" ]] && task_str+=", "
        task_str+="#$tid: $ttitle"
      done < <(echo "$agent_tasks" | jq -c '.[]' 2>/dev/null || echo "")
      # Fall back to agents.current_task if no tasks in collection
      if [[ -z "$task_str" ]]; then
        local fallback=$(echo "$line" | jq -r '.current_task // ""')
        [[ -n "$fallback" && "$fallback" != "null" ]] && task_str="$fallback"
      fi
      if [[ -n "$task_str" ]]; then
        output+="$name: $task_str\n"
      else
        output+="$name: idle\n"
      fi
      ((count++))
    done < <(echo "$agents_json" | jq -c '.[]')
  fi

  [[ $count -eq 0 ]] && output="No active agents."
  text_result "$output"
}

tool_status() {
  if [[ "$HAS_MILVUS" != "true" ]]; then
    text_result "Hivemind Milvus not available. Run hive_setup first."
    return
  fi

  local output="Agents:\n"
  local agents_json=$(get_active_agents)

  if [[ -n "$agents_json" && "$agents_json" != "[]" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      local name=$(echo "$line" | jq -r '.name')
      # Check tasks collection for in_progress tasks
      local agent_tasks=$(milvus_query "tasks" "assignee == $(db_quote "$name") and state == \"in_progress\"" "seq_id,title" 5)
      local task_str=""
      while IFS= read -r tline; do
        [[ -z "$tline" ]] && continue
        local tid=$(echo "$tline" | jq -r '.seq_id // empty')
        [[ -z "$tid" ]] && continue
        local ttitle=$(echo "$tline" | jq -r '.title // ""')
        [[ -n "$task_str" ]] && task_str+=", "
        task_str+="#$tid: $ttitle"
      done < <(echo "$agent_tasks" | jq -c '.[]' 2>/dev/null || echo "")
      # Fall back to agents.current_task
      if [[ -z "$task_str" ]]; then
        local fallback=$(echo "$line" | jq -r '.current_task // ""')
        [[ -n "$fallback" && "$fallback" != "null" ]] && task_str="$fallback"
      fi
      if [[ -n "$task_str" ]]; then
        output+="  $name: $task_str\n"
      else
        output+="  $name: idle\n"
      fi
    done < <(echo "$agents_json" | jq -c '.[]')
  else
    output+="  (none)\n"
  fi

  # File locks
  local locks_json=$(milvus_query "file_locks" "locked_at > 0" "file_path,agent_name" 100)
  local lock_count=0
  local lock_output=""

  if [[ -n "$locks_json" && "$locks_json" != "[]" ]]; then
    while IFS= read -r lock_line; do
      [[ -z "$lock_line" ]] && continue
      local file_path=$(echo "$lock_line" | jq -r '.file_path')
      local agent_name=$(echo "$lock_line" | jq -r '.agent_name')
      lock_output+="  $file_path ($agent_name)\n"
      ((lock_count++))
    done < <(echo "$locks_json" | jq -c '.[]')
  fi

  if [[ $lock_count -gt 0 ]]; then
    output+="Locks:\n$lock_output"
  fi

  # Recent changes
  local changes_json=$(get_recent_changelog 5)

  if [[ -n "$changes_json" && "$changes_json" != "[]" ]]; then
    output+="Recent changes:\n"
    while IFS= read -r change; do
      [[ -z "$change" ]] && continue
      local ts_epoch=$(echo "$change" | jq -r '.timestamp // 0')
      local ts=$(epoch_to_iso "$ts_epoch")
      local ts_time=$(echo "$ts" | cut -d'T' -f2 | cut -d'.' -f1)
      local agent=$(echo "$change" | jq -r '.agent')
      local action=$(echo "$change" | jq -r '.action')
      local file_path=$(echo "$change" | jq -r '.file_path')
      output+="  [$ts_time] $agent: $action $file_path\n"
    done < <(echo "$changes_json" | jq -c '.[]')
  fi

  text_result "$output"
}

tool_message() {
  local session_id="$1" target="$2" body="$3" tty="$4"
  local msg_id="msg-$(date +%s)-$$-$RANDOM"

  if [[ "$HAS_MILVUS" != "true" ]]; then
    text_result "Hivemind Milvus not available. Run hive_setup first."
    return
  fi

  # Look up agent name (TTY first, then session_id)
  local from_agent=$(lookup_agent_name "$tty" "$session_id")
  if [[ -z "$from_agent" ]]; then
    from_agent="unknown"
  fi

  if [[ "$target" == "all" ]]; then
    # Fan-out: send individual message to each active agent (from Milvus)
    local recipient_count=0
    local recipients=""
    local agents_json=$(get_active_agents)

    if [[ -n "$agents_json" && "$agents_json" != "[]" ]]; then
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local agent_name=$(echo "$line" | jq -r '.name')
        # Don't send to self
        [[ "$agent_name" == "$from_agent" ]] && continue
        # Create unique message ID for each recipient
        local recipient_msg_id="msg-$(date +%s)-$$-$RANDOM"
        # Insert message into Milvus
        insert_message "$recipient_msg_id" "$from_agent" "$agent_name" "[BROADCAST] $body" "normal"
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
    # Check if target exists in Milvus
    if ! db_exists "agents" "id == $(db_quote "$target") and ended_at < 1"; then
      local available=$(get_active_agents | jq -r '.[].name' | tr '\n' ', ' | sed 's/,$//')
      text_result "Agent '$target' not found. Active agents: $available"
      return
    fi
    # Insert message into Milvus
    insert_message "$msg_id" "$from_agent" "$target" "$body" "normal"

    # Check recipient status and report accordingly
    local recipient_status=$(get_agent_status "$target")
    if [[ "$recipient_status" == "idle" ]]; then
      # Small delay to ensure Milvus write is visible before wake
      sleep 0.1
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

  [[ "$HAS_MILVUS" != "true" ]] && { text_result "Hivemind Milvus not available. Run hive_setup first."; return; }

  local agent_name=$(lookup_agent_name "$tty" "$session_id")
  [[ -z "$agent_name" ]] && { text_result "Agent not registered."; return; }

  limit=${limit:-10}
  local filter="to_agent == $(db_quote "$agent_name")"
  [[ "$unread_only" == "true" ]] && filter="$filter and delivered_at == 0"

  local messages=$(milvus_query "messages" "$filter" "*" "$limit")

  if [[ -z "$messages" || "$messages" == "[]" ]]; then
    text_result "No messages found."
  else
    local output="Your recent messages:\n"
    # Sort by created_at descending
    messages=$(echo "$messages" | jq -c 'sort_by(-.created_at)')
    while IFS= read -r msg; do
      local from=$(echo "$msg" | jq -r '.from_agent')
      local body=$(echo "$msg" | jq -r '.body')
      local ts_epoch=$(echo "$msg" | jq -r '.created_at // 0')
      local time=$(epoch_to_iso "$ts_epoch")
      local delivered_at=$(echo "$msg" | jq -r '.delivered_at // 0')
      local status=$([[ "$delivered_at" == "0" ]] && echo "[UNREAD]" || echo "")
      output+="$status From $from ($time): $body\n"
    done < <(echo "$messages" | jq -c '.[]')
    text_result "$output"
  fi
}

tool_task() {
  local session_id="$1" description="$2" tty="$3"

  if [[ "$HAS_MILVUS" != "true" ]]; then
    text_result "Hivemind Milvus not available. Run hive_setup first."
    return
  fi

  # Look up agent name (TTY first, then session_id)
  local agent_name=$(lookup_agent_name "$tty" "$session_id")
  if [[ -z "$agent_name" ]]; then
    text_result "Error: Unknown session"
    return
  fi

  # Get current agent data
  local agent_json=$(milvus_query "agents" "id == $(db_quote "$agent_name")" "*" 1)
  if [[ $(echo "$agent_json" | jq 'length') -eq 0 ]]; then
    text_result "Error: Agent not found in database"
    return
  fi

  # Get existing fields
  local session=$(echo "$agent_json" | jq -r '.[0].session_id // empty')
  local tty_val=$(echo "$agent_json" | jq -r '.[0].tty // empty')
  local started_at=$(echo "$agent_json" | jq -r '.[0].started_at // 0')
  local ended_at=$(echo "$agent_json" | jq -r '.[0].ended_at // 0')
  local current_task=$(echo "$agent_json" | jq -r '.[0].current_task // empty')

  # Helper: complete all in_progress tasks for this agent
  _complete_active_tasks() {
    local active_tasks
    active_tasks=$(milvus_query "tasks" "assignee == $(db_quote "$agent_name") and (state == \"claimed\" or state == \"in_progress\")" "seq_id" 100)
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      local task_seq_id=$(echo "$line" | jq -r '.seq_id // empty')
      [[ -z "$task_seq_id" ]] && continue
      update_task "$task_seq_id" "state" "done"
      update_task "$task_seq_id" "completed_at" "$(get_timestamp)"
    done < <(echo "$active_tasks" | jq -c '.[]' 2>/dev/null || echo "")
  }

  if [[ -n "$description" ]]; then
    # Complete any existing in_progress tasks for this agent
    _complete_active_tasks

    # Create new task in tasks collection
    local new_task_id
    new_task_id=$(create_task "$description" "" "" "$agent_name" "in_progress")

    # Sync agents.current_task for status line compatibility
    upsert_agent "$agent_name" "$session" "$tty_val" "$started_at" "$ended_at" "$description" ""
    # Write status file for instant status line reads
    if [[ -n "$tty_val" ]]; then
      local tty_key=$(echo "$tty_val" | tr '/' '_')
      printf '%s\n%s\n\n' "$agent_name" "$description" > "/tmp/hivemind-status-${tty_key}"
    fi
    # Clear awaiting_task flag since task is now set
    clear_agent_flag "$agent_name" "awaiting_task"
    text_result "Task #$new_task_id set: \"$description\""
  else
    # Get the earliest claimed_at from active tasks for elapsed time
    local active_before
    active_before=$(milvus_query "tasks" "assignee == $(db_quote "$agent_name") and (state == \"claimed\" or state == \"in_progress\")" "seq_id" 100)
    local task_claimed_at
    task_claimed_at=$(echo "$active_before" | jq -r '[.[].claimed_at // 0 | tonumber] | map(select(. > 0)) | min // 0')

    # Complete any existing in_progress tasks for this agent
    _complete_active_tasks

    # Clear agents.current_task (move to last_task)
    upsert_agent "$agent_name" "$session" "$tty_val" "$started_at" "$ended_at" "" "$current_task"
    # Update status file (task cleared, previous task moves to last_task)
    if [[ -n "$tty_val" ]]; then
      local tty_key=$(echo "$tty_val" | tr '/' '_')
      printf '%s\n\n%s\n' "$agent_name" "$current_task" > "/tmp/hivemind-status-${tty_key}"
    fi

    # Compute elapsed time string
    local elapsed_str=""
    if [[ "$task_claimed_at" != "0" && -n "$task_claimed_at" ]]; then
      local now
      now=$(get_timestamp)
      local elapsed=$(( now - task_claimed_at ))
      if (( elapsed < 0 )); then elapsed=0; fi
      local mins=$(( elapsed / 60 ))
      local secs=$(( elapsed % 60 ))
      elapsed_str=" [${mins}m ${secs}s]"
    fi
    text_result "Task cleared.${elapsed_str}"
  fi
}

tool_changes() {
  local count="${1:-20}"
  local output=""

  # Query changelog from Milvus
  local changes_json=$(get_recent_changelog "$count")

  if [[ -z "$changes_json" || "$changes_json" == "[]" ]]; then
    text_result "No changes recorded yet."
    return
  fi

  # Format changes for display
  while IFS= read -r change; do
    [[ -z "$change" ]] && continue
    local ts_epoch=$(echo "$change" | jq -r '.timestamp // 0')
    local ts=$(epoch_to_iso "$ts_epoch")
    local ts_time=$(echo "$ts" | cut -d'T' -f2 | cut -d'.' -f1)
    local agent=$(echo "$change" | jq -r '.agent')
    local action=$(echo "$change" | jq -r '.action')
    local file_path=$(echo "$change" | jq -r '.file_path')
    output+="[$ts_time] $agent: $action $file_path
"
  done < <(echo "$changes_json" | jq -c '.[]')

  text_result "$output"
}

tool_help() {
  text_result "hive_setup - First-time setup (starts Milvus, configures status line)
hive_whoami - Get your agent name
hive_agents - List active agents and their tasks
hive_status - Coordination dashboard (agents, locks, recent changes)
hive_message target=<name|all> body=<text> - Send message to agent or broadcast
hive_task description=<text> - Set current task (empty to clear)
hive_changes count=<n> - View recent file changes (default 20)
hive_inbox limit=<n> unread_only=<bool> - View message history
Messages from other agents are delivered automatically each prompt."
}

tool_setup() {
  local output=""

  # Step 1: Start Milvus if not running
  if ! milvus_ready; then
    output+="Starting Milvus...\n"
    if [[ -x "$START_SCRIPT" ]]; then
      # Run start-milvus.sh which also initializes collections
      if "$START_SCRIPT" >> "$MCP_DEBUG_LOG" 2>&1; then
        output+="✓ Milvus started and collections initialized\n"
        HAS_MILVUS=true
      else
        output+="✗ Failed to start Milvus. Check logs: $MCP_DEBUG_LOG\n"
        output+="  Ensure Docker is running and try again.\n"
        text_result "$(echo -e "$output")"
        return
      fi
    else
      output+="✗ Start script not found: $START_SCRIPT\n"
      text_result "$(echo -e "$output")"
      return
    fi
  else
    output+="✓ Milvus is ready\n"
    HAS_MILVUS=true
    # Ensure collections exist for this project
    local init_script="$SCRIPT_DIR/../scripts/init-collections.sh"
    if [[ -x "$init_script" ]]; then
      "$init_script" >> "$MCP_DEBUG_LOG" 2>&1
      output+="✓ Collections initialized\n"
    fi
  fi

  # Step 2: Install status line config
  local settings_dir="$HOME/.claude"
  local settings_file="$settings_dir/settings.json"
  # Status line reads agent info from file cache (written by hooks/MCP), falls back to Milvus
  local statusline_cmd='input=$(cat); cwd=$(echo "$input" | jq -r '"'"'.workspace.current_dir'"'"'); dir=$(basename "$cwd"); hivemind='"'"''"'"'; task_info='"'"''"'"'; agent='"'"''"'"'; task='"'"''"'"'; lastTask='"'"''"'"'; hivemind_dir='"'"''"'"'; d="$cwd"; while [ "$d" != "/" ]; do if [ -d "$d/.hivemind" ]; then hivemind_dir="$d/.hivemind"; break; fi; d=$(dirname "$d"); done; if [ -n "$hivemind_dir" ]; then pid=$$; tty=""; while [ -n "$pid" ] && [ "$pid" != "1" ]; do ptty=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d '"'"' '"'"'); if [ -n "$ptty" ] && [ "$ptty" != "??" ]; then tty="/dev/$ptty"; break; fi; pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '"'"' '"'"'); done; if [ -n "$tty" ]; then tty_key=$(echo "$tty" | tr '"'"'/'"'"' '"'"'_'"'"'); status_file="/tmp/hivemind-status-${tty_key}"; if [ -f "$status_file" ]; then agent=$(sed -n '"'"'1p'"'"' "$status_file"); task=$(sed -n '"'"'2p'"'"' "$status_file"); lastTask=$(sed -n '"'"'3p'"'"' "$status_file"); else project_root=$(dirname "$hivemind_dir"); project_name=$(basename "$project_root" | tr "[:upper:]" "[:lower:]" | sed "s/[^a-z]/_/g" | sed "s/__*/_/g" | sed "s/^_//;s/_$//"); collection="${project_name}_hivemind_agents"; result=$(curl -sf --max-time 2 -X POST "http://localhost:19531/v2/vectordb/entities/query" -H "Authorization: Bearer root:Milvus" -H "Content-Type: application/json" -d "{\"dbName\":\"default\",\"collectionName\":\"$collection\",\"filter\":\"tty == \\\"$tty\\\" and ended_at < 1\",\"outputFields\":[\"name\",\"current_task\",\"last_task\"],\"limit\":1}" 2>/dev/null); if [ -n "$result" ]; then agent=$(echo "$result" | jq -r '"'"'.data[0].name // empty'"'"' 2>/dev/null); task=$(echo "$result" | jq -r '"'"'.data[0].current_task // empty'"'"' 2>/dev/null); lastTask=$(echo "$result" | jq -r '"'"'.data[0].last_task // empty'"'"' 2>/dev/null); fi; fi; fi; fi; if [ -n "$agent" ]; then hivemind=$(printf '"'"'\033[1;35m[%s]\033[0m '"'"' "$agent"); if [ -n "$task" ]; then task_info=$(printf '"'"'\n\033[0;33m%s\033[0m'"'"' "$task"); elif [ -n "$lastTask" ]; then task_info=$(printf '"'"'\n\033[0;90m%s\033[0m'"'"' "$lastTask"); elif [ -f "$hivemind_dir/version.txt" ]; then version=$(cat "$hivemind_dir/version.txt"); task_info=$(printf '"'"'\n\033[0;35mhivemind v%s\033[0m'"'"' "$version"); fi; fi; git_info='"'"''"'"'; if cd "$cwd" 2>/dev/null && git rev-parse --git-dir > /dev/null 2>&1; then branch=$(git --no-optional-locks branch --show-current 2>/dev/null || git --no-optional-locks rev-parse --short HEAD 2>/dev/null); if [ -n "$branch" ]; then if [ -n "$(git --no-optional-locks status --porcelain 2>/dev/null)" ]; then git_info=$(printf '"'"' \033[1;34mgit:(\033[0;31m%s\033[1;34m) \033[0;33m✗\033[0m'"'"' "$branch"); else git_info=$(printf '"'"'\033[1;34mgit:(\033[0;31m%s\033[1;34m)\033[0m'"'"' "$branch"); fi; fi; fi; printf '"'"'%s\033[1;32m➜\033[0m  \033[0;36m%s\033[0m%s%s'"'"' "$hivemind" "$dir" "$git_info" "$task_info"'

  mkdir -p "$settings_dir"

  if [[ -f "$settings_file" ]]; then
    jq --arg cmd "$statusline_cmd" '.statusLine = {"type": "command", "command": $cmd}' \
      "$settings_file" > "$settings_file.tmp" && mv "$settings_file.tmp" "$settings_file"
  else
    jq -n --arg cmd "$statusline_cmd" '{"statusLine": {"type": "command", "command": $cmd}}' \
      > "$settings_file"
  fi
  output+="✓ Status line config installed to ~/.claude/settings.json\n"

  # Step 3: Update version file
  local plugin_json="$SCRIPT_DIR/../.claude-plugin/plugin.json"
  if [[ -f "$plugin_json" && -d "$HIVEMIND_DIR" ]]; then
    local version
    version=$(jq -r '.version // "unknown"' "$plugin_json")
    echo "$version" > "$HIVEMIND_DIR/version.txt"
    output+="✓ Version updated to $version\n"
  fi

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
    {"name":"hive_setup","description":"Set up Hivemind: checks Milvus and configures status line. Run this first when using Hivemind in a new project.","inputSchema":{"type":"object","properties":{},"required":[]}}
  ]}'
}

handle_tools_call() {
  local id="$1" line="$2"

  # Resolve HIVEMIND_DIR for current TTY before any tool runs
  resolve_hivemind_dir

  # Re-check Milvus availability if not yet detected (may have been started
  # by session-start hook or another process since MCP server startup)
  if [[ "$HAS_MILVUS" != "true" ]] && milvus_ready; then
    HAS_MILVUS=true
    log "Milvus now available (detected on tool call)"
  fi

  local tool=$(echo "$line" | jq -r '.params.name')
  local args=$(echo "$line" | jq -r '.params.arguments // {}')

  case "$tool" in
    hive_whoami)
      local sid=$(echo "$args" | jq -r '.session_id // ""')
      local tty=$(echo "$args" | jq -r '.tty // ""')
      # Derive TTY automatically if not provided
      if [[ -z "$sid" && -z "$tty" ]]; then
        tty=$(derive_tty)
      fi
      send_response "$id" "$(tool_whoami "$sid" "$tty")"
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
      # Derive TTY automatically if not provided
      if [[ -z "$sid" && -z "$tty" ]]; then
        tty=$(derive_tty)
      fi
      log "hive_message parsed: sid='$sid' tty='$tty' target='$target' body='$body'"
      if [[ -z "$target" || -z "$body" ]]; then
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
      # Derive TTY automatically if not provided
      if [[ -z "$sid" && -z "$tty" ]]; then
        tty=$(derive_tty)
      fi
      send_response "$id" "$(tool_task "$sid" "$desc" "$tty")"
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
      # Derive TTY automatically if not provided
      if [[ -z "$sid" && -z "$tty" ]]; then
        tty=$(derive_tty)
      fi
      send_response "$id" "$(tool_inbox "$sid" "$limit" "$unread_only" "$tty")"
      ;;
    hive_setup)
      send_response "$id" "$(tool_setup)"
      # tool_setup runs in a subshell (command substitution) so HAS_MILVUS
      # changes are lost — re-check in the parent shell
      if [[ "$HAS_MILVUS" != "true" ]] && milvus_ready; then
        HAS_MILVUS=true
        log "Milvus now available (after setup)"
      fi
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
