#!/bin/bash
# dashboard.sh - Top-like terminal UI for Hivemind monitoring
#
# Usage:
#   hivemind dashboard           # Live dashboard (refreshes every 2s)
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

# Ensure database exists
if [ ! -f "$HIVEMIND_DIR/hive.db" ]; then
  echo "Error: Database not found at $HIVEMIND_DIR/hive.db"
  echo "Run hivemind init first."
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

  # Clear screen
  clear

  # Header
  echo -e "${BOLD}${TL_CORNER}${H_LINE} HIVEMIND DASHBOARD ${H_LINE}${H_LINE}${H_LINE}${H_LINE}${H_LINE}${H_LINE}${H_LINE}${H_LINE}${H_LINE}${H_LINE}${H_LINE}${H_LINE}${H_LINE}${H_LINE}${H_LINE}${H_LINE}${H_LINE}${H_LINE}${H_LINE}${H_LINE}${H_LINE} ${now} ${H_LINE}${TR_CORNER}${RESET}"
  echo -e "${V_LINE}${RESET}"

  # ===== AGENTS SECTION =====
  local active_count=$(db_query "SELECT COUNT(*) as c FROM agents WHERE ended_at IS NULL AND current_task IS NOT NULL" | jq -r '.[0].c // 0')
  local idle_count=$(db_query "SELECT COUNT(*) as c FROM agents WHERE ended_at IS NULL AND current_task IS NULL" | jq -r '.[0].c // 0')
  local offline_count=$(db_query "SELECT COUNT(*) as c FROM agents WHERE ended_at IS NOT NULL" | jq -r '.[0].c // 0')

  echo -e "${V_LINE} ${BOLD}AGENTS${RESET}          active: ${GREEN}$active_count${RESET}  idle: ${YELLOW}$idle_count${RESET}  offline: ${DIM}$offline_count${RESET}"
  echo -e "${V_LINE} $(draw_line "${H_LINE}" | head -c $((width - 4)))"

  # List agents
  local agents=$(db_query "SELECT name, current_task, last_task, ended_at FROM agents ORDER BY ended_at NULLS FIRST, name")
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local name=$(echo "$line" | jq -r '.name // empty')
    [[ -z "$name" ]] && continue

    local task=$(echo "$line" | jq -r '.current_task // empty')
    local last_task=$(echo "$line" | jq -r '.last_task // empty')
    local ended_at=$(echo "$line" | jq -r '.ended_at // empty')

    local status_color="$GREEN"
    local status="working"
    local display_task="$task"

    if [[ -n "$ended_at" ]]; then
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

    printf "${V_LINE}  ${status_color}%-8s${RESET} [${status_color}%s${RESET}] %s\n" "$name" "$status" "$display_task"
  done < <(echo "$agents" | jq -c '.[]' 2>/dev/null || echo "")

  echo -e "${V_LINE}"

  # ===== TASKS SECTION =====
  local pending=$(db_query "SELECT COUNT(*) as c FROM tasks WHERE state = 'pending'" | jq -r '.[0].c // 0')
  local in_progress=$(db_query "SELECT COUNT(*) as c FROM tasks WHERE state IN ('claimed', 'in_progress')" | jq -r '.[0].c // 0')
  local review=$(db_query "SELECT COUNT(*) as c FROM tasks WHERE state = 'review'" | jq -r '.[0].c // 0')

  echo -e "${V_LINE} ${BOLD}TASKS${RESET}      pending: ${CYAN}$pending${RESET}  active: ${GREEN}$in_progress${RESET}  review: ${PURPLE}$review${RESET}"
  echo -e "${V_LINE} $(draw_line "${H_LINE}" | head -c $((width - 4)))"

  # List recent tasks (not done)
  local tasks=$(db_query "SELECT id, title, state, assignee FROM tasks WHERE state != 'done' ORDER BY id LIMIT 5")
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local id=$(echo "$line" | jq -r '.id // empty')
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

    printf "${V_LINE}  #%-3d [${state_color}%-11s${RESET}] %s%s\n" "$id" "$state" "$title" "$assignee_str"
  done < <(echo "$tasks" | jq -c '.[]' 2>/dev/null || echo "")

  # Check for blocked tasks
  local blocked=$(db_query "SELECT COUNT(*) as c FROM tasks t WHERE t.state = 'pending' AND EXISTS (SELECT 1 FROM unnest(t.depends_on) AS dep_id JOIN tasks d ON d.id = dep_id WHERE d.state != 'done')" | jq -r '.[0].c // 0')
  if [[ "$blocked" -gt 0 ]]; then
    echo -e "${V_LINE}  ${DIM}($blocked task(s) blocked by dependencies)${RESET}"
  fi

  echo -e "${V_LINE}"

  # ===== HOTSPOTS SECTION =====
  echo -e "${V_LINE} ${BOLD}HOTSPOTS${RESET} (files with most edits today)"
  echo -e "${V_LINE} $(draw_line "${H_LINE}" | head -c $((width - 4)))"

  local hotspots=$(db_query "SELECT file_path, COUNT(*) as edit_count FROM changelog WHERE timestamp > now() - INTERVAL '24 hours' GROUP BY file_path ORDER BY edit_count DESC LIMIT 3")
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

    printf "${V_LINE}  %-${max_file_len}s ${YELLOW}%s${DIM}%s${RESET} %d\n" "$file" "$bar" "$empty" "$count"
  done < <(echo "$hotspots" | jq -c '.[]' 2>/dev/null || echo "")

  # If no hotspots
  if [[ $(echo "$hotspots" | jq 'length') -eq 0 ]]; then
    echo -e "${V_LINE}  ${DIM}No file edits in the last 24 hours${RESET}"
  fi

  echo -e "${V_LINE}"

  # ===== METRICS SECTION =====
  echo -e "${V_LINE} ${BOLD}METRICS${RESET} (24h)"
  echo -e "${V_LINE} $(draw_line "${H_LINE}" | head -c $((width - 4)))"

  local completed=$(db_query "SELECT COUNT(*) as c FROM metrics WHERE event_type = 'task_completed' AND timestamp > now() - INTERVAL '24 hours'" | jq -r '.[0].c // 0')
  local approved=$(db_query "SELECT COUNT(*) as c FROM metrics WHERE event_type = 'review_approved' AND timestamp > now() - INTERVAL '24 hours'" | jq -r '.[0].c // 0')
  local rejected=$(db_query "SELECT COUNT(*) as c FROM metrics WHERE event_type = 'review_rejected' AND timestamp > now() - INTERVAL '24 hours'" | jq -r '.[0].c // 0')

  # Get most active file
  local hottest=$(db_query "SELECT file_path, COUNT(*) as c FROM changelog WHERE timestamp > now() - INTERVAL '24 hours' GROUP BY file_path ORDER BY c DESC LIMIT 1")
  local hottest_file=$(echo "$hottest" | jq -r '.[0].file_path // "none"')
  local hottest_count=$(echo "$hottest" | jq -r '.[0].c // 0')

  echo -e "${V_LINE}  Tasks completed: ${GREEN}$completed${RESET}"
  echo -e "${V_LINE}  Reviews: ${GREEN}$approved${RESET} approved, ${RED}$rejected${RESET} rejected"
  if [[ "$hottest_file" != "none" ]]; then
    echo -e "${V_LINE}  Hottest file: ${YELLOW}$hottest_file${RESET} ($hottest_count edits)"
  fi

  echo -e "${V_LINE}"

  # Footer
  echo -e "${BL_CORNER}$(draw_line "${H_LINE}" | head -c $((width - 30)))${H_LINE}${H_LINE} q: quit  r: refresh ${H_LINE}${BR_CORNER}"
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
    if read -t 2 -n 1 key; then
      case "$key" in
        q|Q) break ;;
        r|R) continue ;;
      esac
    fi
  done
fi
