#!/bin/bash
# dashboard.sh - Top-like terminal UI for Hivemind monitoring
#
# Usage:
#   hivemind dashboard           # Live dashboard (refreshes every 5s)
#   hivemind dashboard --once    # Single snapshot
#
# Features:
#   - Agent status overview (active, idle, offline)
#   - Task queue summary
#   - File hotspots (conflict-prone files)
#   - 24h metrics

set -euo pipefail

# Get script directory and source helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/db.sh"

# Find .hivemind directory
find_hivemind_dir() {
  local dir="${1:-$(pwd)}"
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

# Parse arguments
ONCE_MODE=false
for arg in "$@"; do
  case "$arg" in
    --once) ONCE_MODE=true ;;
  esac
done

# Find hivemind directory
HIVEMIND_DIR=$(find_hivemind_dir)
if [ -z "$HIVEMIND_DIR" ]; then
  echo "Error: No .hivemind directory found"
  exit 1
fi
export HIVEMIND_DIR

# Check Milvus is available
if ! milvus_ready; then
  echo "Error: Milvus not available"
  echo "Run ./scripts/start-milvus.sh first."
  exit 1
fi

# Colors
RESET="\033[0m"
BOLD="\033[1m"
DIM="\033[2m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
BLUE="\033[0;34m"
PURPLE="\033[0;35m"
CYAN="\033[0;36m"
WHITE="\033[0;37m"

# Clear to end of line (prevents stale content)
EOL="\033[K"

# Box drawing characters
H_LINE="─"
V_LINE="│"
TL_CORNER="┌"
TR_CORNER="┐"
BL_CORNER="└"
BR_CORNER="┘"
T_DOWN="┬"
T_UP="┴"
T_RIGHT="├"
T_LEFT="┤"

# Get terminal width
get_width() {
  tput cols 2>/dev/null || echo 80
}

# Draw a horizontal line
draw_line() {
  local width=$(get_width)
  local char="${1:-$H_LINE}"
  printf '%*s' "$width" '' | tr ' ' "$char"
}

# Render the dashboard
render_dashboard() {
  local width=$(get_width)
  local now=$(date +"%H:%M:%S")

  # Move cursor to home position (no flicker)
  tput home

  # Header
  echo -e "${BOLD}${TL_CORNER}${H_LINE} HIVEMIND DASHBOARD ${H_LINE}${H_LINE}${H_LINE}${H_LINE}${H_LINE}${H_LINE}${H_LINE}${H_LINE}${H_LINE}${H_LINE}${H_LINE}${H_LINE}${H_LINE}${H_LINE}${H_LINE}${H_LINE}${H_LINE}${H_LINE}${H_LINE}${H_LINE}${H_LINE} ${now} ${H_LINE}${TR_CORNER}${RESET}${EOL}"
  echo -e "${V_LINE}${RESET}${EOL}"

  # ===== AGENTS SECTION =====
  # Count active and idle agents (active = has current_task, idle = no current_task)
  local all_agents=$(get_active_agents)
  local active_count=0
  local idle_count=0

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local task=$(echo "$line" | jq -r '.current_task // empty')
    if [[ -n "$task" ]]; then
      ((active_count++))
    else
      ((idle_count++))
    fi
  done < <(echo "$all_agents" | jq -c '.[]' 2>/dev/null || echo "")

  # Count offline agents (ended_at != 0)
  local offline_agents=$(milvus_query "agents" "ended_at > 0" "id" 100)
  local offline_count=$(echo "$offline_agents" | jq 'length')

  echo -e "${V_LINE} ${BOLD}AGENTS${RESET}          active: ${GREEN}$active_count${RESET}  idle: ${YELLOW}$idle_count${RESET}  offline: ${DIM}$offline_count${RESET}${EOL}"
  echo -e "${V_LINE} $(draw_line "${H_LINE}" | head -c $((width - 4)))${EOL}"

  # List agents (active first, then offline)
  local agents=$(milvus_query "agents" "started_at > 0" "name,current_task,last_task,ended_at" 100)
  # Sort by ended_at (nulls first means active agents first)
  agents=$(echo "$agents" | jq -c 'sort_by(.ended_at) | .[]' 2>/dev/null || echo "")

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local name=$(echo "$line" | jq -r '.name // empty')
    [[ -z "$name" ]] && continue

    local task=$(echo "$line" | jq -r '.current_task // empty')
    local last_task=$(echo "$line" | jq -r '.last_task // empty')
    local ended_at=$(echo "$line" | jq -r '.ended_at // 0')

    local status_color="$GREEN"
    local status="working"
    local display_task="$task"

    if [[ "$ended_at" != "0" ]]; then
      status_color="$DIM"
      status="offline"
      display_task="$last_task"
    elif [[ -z "$task" ]]; then
      status_color="$YELLOW"
      status="idle   "
      display_task="$last_task"
    fi

    # Truncate task to fit
    local max_task_len=$((width - 30))
    if [[ ${#display_task} -gt $max_task_len ]]; then
      display_task="${display_task:0:$max_task_len}..."
    fi

    printf "${V_LINE}  ${status_color}%-8s${RESET} [${status_color}%s${RESET}] %s${EOL}\n" "$name" "$status" "$display_task"
  done <<< "$agents"

  echo -e "${V_LINE}${EOL}"

  # ===== TASKS SECTION =====
  local pending=$(milvus_query "tasks" "state == \"pending\"" "id" 100 | jq 'length')
  local in_progress_json=$(milvus_query "tasks" "state == \"claimed\" or state == \"in_progress\"" "id" 100)
  local in_progress=$(echo "$in_progress_json" | jq 'length')
  local review=$(milvus_query "tasks" "state == \"review\"" "id" 100 | jq 'length')

  echo -e "${V_LINE} ${BOLD}TASKS${RESET}      pending: ${CYAN}$pending${RESET}  active: ${GREEN}$in_progress${RESET}  review: ${PURPLE}$review${RESET}${EOL}"
  echo -e "${V_LINE} $(draw_line "${H_LINE}" | head -c $((width - 4)))${EOL}"

  # List recent tasks (not done)
  local tasks=$(milvus_query "tasks" "state != \"done\"" "seq_id,title,state,assignee" 100)
  tasks=$(echo "$tasks" | jq -c 'sort_by(.seq_id) | .[:5]')

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local id=$(echo "$line" | jq -r '.seq_id // empty')
    [[ -z "$id" ]] && continue

    local title=$(echo "$line" | jq -r '.title // empty')
    local state=$(echo "$line" | jq -r '.state // empty')
    local assignee=$(echo "$line" | jq -r '.assignee // empty')

    local state_color="$WHITE"
    case "$state" in
      pending) state_color="$CYAN" ;;
      claimed|in_progress) state_color="$GREEN" ;;
      review) state_color="$PURPLE" ;;
    esac

    # Truncate title
    local max_title_len=$((width - 40))
    if [[ ${#title} -gt $max_title_len ]]; then
      title="${title:0:$max_title_len}..."
    fi

    local assignee_str=""
    [[ -n "$assignee" ]] && assignee_str=" <- $assignee"

    printf "${V_LINE}  #%-3d [${state_color}%-11s${RESET}] %s%s${EOL}\n" "$id" "$state" "$title" "$assignee_str"
  done < <(echo "$tasks" | jq -c '.[]' 2>/dev/null || echo "")

  # Note: Blocked task detection would require parsing depends_on JSON array
  # Skipping for now as Milvus doesn't have good support for array contains

  echo -e "${V_LINE}${EOL}"

  # ===== HOTSPOTS SECTION =====
  echo -e "${V_LINE} ${BOLD}HOTSPOTS${RESET} (files with most edits today)${EOL}"
  echo -e "${V_LINE} $(draw_line "${H_LINE}" | head -c $((width - 4)))${EOL}"

  # Get changelog entries from last 24 hours and aggregate with jq
  local cutoff=$(($(get_timestamp) - 86400))
  local changelog=$(milvus_query "changelog" "timestamp >= $cutoff" "file_path" 1000)

  # Aggregate by file_path using jq
  local hotspots=$(echo "$changelog" | jq -c '
    group_by(.file_path) |
    map({file_path: .[0].file_path, edit_count: length}) |
    sort_by(-.edit_count) |
    .[:3]
  ')

  local max_edits=$(echo "$hotspots" | jq -r '.[0].edit_count // 10')
  [[ "$max_edits" -lt 1 ]] && max_edits=1

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local file=$(echo "$line" | jq -r '.file_path // empty')
    [[ -z "$file" ]] && continue

    local count=$(echo "$line" | jq -r '.edit_count // 0')

    # Create bar (max 10 chars)
    local bar_len=$((count * 10 / max_edits))
    [[ $bar_len -lt 1 ]] && bar_len=1
    local bar=$(printf '%*s' "$bar_len" '' | tr ' ' '█')
    local empty=$(printf '%*s' "$((10 - bar_len))" '' | tr ' ' '░')

    # Truncate filename
    local max_file_len=$((width - 25))
    if [[ ${#file} -gt $max_file_len ]]; then
      file="...${file: -$((max_file_len - 3))}"
    fi

    printf "${V_LINE}  %-${max_file_len}s ${YELLOW}%s${DIM}%s${RESET} %d${EOL}\n" "$file" "$bar" "$empty" "$count"
  done < <(echo "$hotspots" | jq -c '.[]' 2>/dev/null || echo "")

  # If no hotspots
  if [[ $(echo "$hotspots" | jq 'length') -eq 0 ]]; then
    echo -e "${V_LINE}  ${DIM}No file edits in the last 24 hours${RESET}${EOL}"
  fi

  echo -e "${V_LINE}${EOL}"

  # ===== METRICS SECTION =====
  echo -e "${V_LINE} ${BOLD}METRICS${RESET} (24h)${EOL}"
  echo -e "${V_LINE} $(draw_line "${H_LINE}" | head -c $((width - 4)))${EOL}"

  local completed=$(get_metrics_since "$cutoff" "task_completed" | jq 'length')
  local approved=$(get_metrics_since "$cutoff" "review_approved" | jq 'length')
  local rejected=$(get_metrics_since "$cutoff" "review_rejected" | jq 'length')

  # Get most active file from hotspots
  local hottest_file=$(echo "$hotspots" | jq -r '.[0].file_path // "none"')
  local hottest_count=$(echo "$hotspots" | jq -r '.[0].edit_count // 0')

  echo -e "${V_LINE}  Tasks completed: ${GREEN}$completed${RESET}${EOL}"
  echo -e "${V_LINE}  Reviews: ${GREEN}$approved${RESET} approved, ${RED}$rejected${RESET} rejected${EOL}"
  if [[ "$hottest_file" != "none" && "$hottest_file" != "null" ]]; then
    echo -e "${V_LINE}  Hottest file: ${YELLOW}$hottest_file${RESET} ($hottest_count edits)${EOL}"
  fi

  echo -e "${V_LINE}${EOL}"

  # Footer
  echo -e "${BL_CORNER}$(draw_line "${H_LINE}" | head -c $((width - 30)))${H_LINE}${H_LINE} q: quit  r: refresh ${H_LINE}${BR_CORNER}${EOL}"
}

# Main loop
if $ONCE_MODE; then
  render_dashboard
else
  # Trap for cleanup
  cleanup() {
    tput cnorm  # Show cursor
    clear
  }
  trap cleanup EXIT

  tput civis  # Hide cursor

  while true; do
    render_dashboard

    # Wait for keypress or timeout
    if read -t 5 -n 1 key; then
      case "$key" in
        q|Q) break ;;
        r|R) continue ;;
      esac
    fi
  done
fi
