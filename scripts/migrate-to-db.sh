#!/bin/bash
# migrate-to-db.sh - One-time migration of file-based data to DuckDB
#
# This script migrates existing hivemind data from file-based storage to DuckDB:
# - .hivemind/agents/*.json -> agents table
# - .hivemind/locks/*.lock -> file_locks table
# - .hivemind/messages/inbox-*/*.json -> messages table
# - .hivemind/changelog.jsonl -> changelog table
#
# After migration, old files are moved to .hivemind/backup/

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

echo "Hivemind File-to-Database Migration"
echo "===================================="
echo ""

# Find hivemind directory
HIVEMIND_DIR=$(find_hivemind_dir)
if [ -z "$HIVEMIND_DIR" ]; then
  echo "Error: No .hivemind directory found. Nothing to migrate."
  exit 1
fi
export HIVEMIND_DIR

echo "Found hivemind directory: $HIVEMIND_DIR"

# Check if DuckDB is available
if ! db_check_duckdb; then
  exit 1
fi

# Initialize database (creates schema if needed)
echo "Initializing database..."
db_full_init

# Create backup directory
BACKUP_DIR="$HIVEMIND_DIR/backup"
mkdir -p "$BACKUP_DIR"
echo "Backup directory: $BACKUP_DIR"
echo ""

# Counters
AGENTS_MIGRATED=0
LOCKS_MIGRATED=0
MESSAGES_MIGRATED=0
CHANGELOG_MIGRATED=0

# ============================================================================
# Migrate Agents
# ============================================================================
AGENTS_DIR="$HIVEMIND_DIR/agents"
if [ -d "$AGENTS_DIR" ]; then
  echo "Migrating agents..."
  for agent_file in "$AGENTS_DIR"/*.json; do
    [ -f "$agent_file" ] || continue

    name=$(jq -r '.sessionName // empty' "$agent_file" 2>/dev/null)
    [ -z "$name" ] && continue

    session_id=$(jq -r '.sessionId // ""' "$agent_file" 2>/dev/null)
    tty=$(jq -r '.tty // ""' "$agent_file" 2>/dev/null)
    started_at=$(jq -r '.startedAt // ""' "$agent_file" 2>/dev/null)
    ended_at=$(jq -r '.endedAt // ""' "$agent_file" 2>/dev/null)
    current_task=$(jq -r '.currentTask // ""' "$agent_file" 2>/dev/null)
    last_task=$(jq -r '.lastTask // ""' "$agent_file" 2>/dev/null)

    # Handle empty values for timestamps
    [ "$started_at" = "" ] && started_at="NULL" || started_at="'$started_at'"
    [ "$ended_at" = "" ] || [ "$ended_at" = "null" ] && ended_at="NULL" || ended_at="'$ended_at'"
    [ "$session_id" = "" ] && session_id="NULL" || session_id=$(db_quote "$session_id")
    [ "$tty" = "" ] && tty="NULL" || tty=$(db_quote "$tty")
    [ "$current_task" = "" ] || [ "$current_task" = "null" ] && current_task="NULL" || current_task=$(db_quote "$current_task")
    [ "$last_task" = "" ] || [ "$last_task" = "null" ] && last_task="NULL" || last_task=$(db_quote "$last_task")

    # Check if agent already exists
    if db_exists "agents" "name = $(db_quote "$name")"; then
      echo "  - Agent '$name' already exists, skipping"
    else
      db_exec "INSERT INTO agents (name, session_id, tty, started_at, ended_at, current_task, last_task) VALUES ($(db_quote "$name"), $session_id, $tty, $started_at, $ended_at, $current_task, $last_task)"
      echo "  - Migrated agent: $name"
      ((AGENTS_MIGRATED++))
    fi
  done

  # Move agents directory to backup
  if [ $AGENTS_MIGRATED -gt 0 ]; then
    mv "$AGENTS_DIR" "$BACKUP_DIR/agents"
    echo "  Backed up: $BACKUP_DIR/agents"
  fi
  echo ""
fi

# ============================================================================
# Migrate File Locks
# ============================================================================
LOCKS_DIR="$HIVEMIND_DIR/locks"
if [ -d "$LOCKS_DIR" ]; then
  echo "Migrating file locks..."
  for lock_file in "$LOCKS_DIR"/*.lock; do
    [ -f "$lock_file" ] || continue

    file_path=$(jq -r '.filePath // empty' "$lock_file" 2>/dev/null)
    [ -z "$file_path" ] && continue

    agent_name=$(jq -r '.sessionName // ""' "$lock_file" 2>/dev/null)
    [ -z "$agent_name" ] && continue

    locked_at=$(jq -r '.lockedAt // ""' "$lock_file" 2>/dev/null)
    [ "$locked_at" = "" ] && locked_at="now()" || locked_at="'$locked_at'"

    # Check if lock already exists
    if db_exists "file_locks" "file_path = $(db_quote "$file_path")"; then
      echo "  - Lock for '$file_path' already exists, skipping"
    else
      db_exec "INSERT INTO file_locks (file_path, agent_name, locked_at) VALUES ($(db_quote "$file_path"), $(db_quote "$agent_name"), $locked_at)"
      echo "  - Migrated lock: $file_path (held by $agent_name)"
      ((LOCKS_MIGRATED++))
    fi
  done

  # Move locks directory to backup
  if [ $LOCKS_MIGRATED -gt 0 ]; then
    mv "$LOCKS_DIR" "$BACKUP_DIR/locks"
    echo "  Backed up: $BACKUP_DIR/locks"
  fi
  echo ""
fi

# ============================================================================
# Migrate Messages
# ============================================================================
MESSAGES_DIR="$HIVEMIND_DIR/messages"
if [ -d "$MESSAGES_DIR" ]; then
  echo "Migrating messages..."
  for inbox_dir in "$MESSAGES_DIR"/inbox-*; do
    [ -d "$inbox_dir" ] || continue

    for msg_file in "$inbox_dir"/*.json; do
      [ -f "$msg_file" ] || continue

      msg_id=$(jq -r '.id // empty' "$msg_file" 2>/dev/null)
      [ -z "$msg_id" ] && msg_id="msg-$(date +%s)-$$-$RANDOM"

      from_agent=$(jq -r '.from // ""' "$msg_file" 2>/dev/null)
      to_agent=$(jq -r '.to // ""' "$msg_file" 2>/dev/null)
      body=$(jq -r '.body // ""' "$msg_file" 2>/dev/null)
      priority=$(jq -r '.priority // "normal"' "$msg_file" 2>/dev/null)
      timestamp=$(jq -r '.timestamp // ""' "$msg_file" 2>/dev/null)

      [ -z "$from_agent" ] && continue
      [ -z "$to_agent" ] && continue

      [ "$timestamp" = "" ] && created_at="now()" || created_at="'$timestamp'"

      # Check if message already exists
      if db_exists "messages" "id = $(db_quote "$msg_id")"; then
        echo "  - Message '$msg_id' already exists, skipping"
      else
        db_exec "INSERT INTO messages (id, from_agent, to_agent, body, priority, created_at) VALUES ($(db_quote "$msg_id"), $(db_quote "$from_agent"), $(db_quote "$to_agent"), $(db_quote "$body"), $(db_quote "$priority"), $created_at)"
        echo "  - Migrated message from $from_agent to $to_agent"
        ((MESSAGES_MIGRATED++))
      fi
    done
  done

  # Move messages directory to backup
  if [ $MESSAGES_MIGRATED -gt 0 ]; then
    mv "$MESSAGES_DIR" "$BACKUP_DIR/messages"
    echo "  Backed up: $BACKUP_DIR/messages"
  fi
  echo ""
fi

# ============================================================================
# Migrate Changelog
# ============================================================================
CHANGELOG_FILE="$HIVEMIND_DIR/changelog.jsonl"
if [ -f "$CHANGELOG_FILE" ]; then
  echo "Migrating changelog..."
  while IFS= read -r line; do
    [ -z "$line" ] && continue

    timestamp=$(echo "$line" | jq -r '.timestamp // ""' 2>/dev/null)
    agent=$(echo "$line" | jq -r '.agent // ""' 2>/dev/null)
    action=$(echo "$line" | jq -r '.action // ""' 2>/dev/null)
    file_path=$(echo "$line" | jq -r '.file // ""' 2>/dev/null)
    summary=$(echo "$line" | jq -r '.summary // ""' 2>/dev/null)

    [ -z "$agent" ] && continue
    [ -z "$action" ] && continue
    [ -z "$file_path" ] && continue

    [ "$timestamp" = "" ] && ts="now()" || ts="'$timestamp'"
    [ "$summary" = "" ] || [ "$summary" = "null" ] && summary="NULL" || summary=$(db_quote "$summary")

    # Get next ID
    changelog_id=$(db_next_id "changelog_id_seq")

    db_exec "INSERT INTO changelog (id, timestamp, agent, action, file_path, summary) VALUES ($changelog_id, $ts, $(db_quote "$agent"), $(db_quote "$action"), $(db_quote "$file_path"), $summary)"
    ((CHANGELOG_MIGRATED++))
  done < "$CHANGELOG_FILE"

  echo "  - Migrated $CHANGELOG_MIGRATED changelog entries"

  # Move changelog to backup
  if [ $CHANGELOG_MIGRATED -gt 0 ]; then
    mv "$CHANGELOG_FILE" "$BACKUP_DIR/changelog.jsonl"
    echo "  Backed up: $BACKUP_DIR/changelog.jsonl"
  fi
  echo ""
fi

# ============================================================================
# Clean up session mapping directories (no longer needed)
# ============================================================================
SESSIONS_DIR="$HIVEMIND_DIR/sessions"
TTY_SESSIONS_DIR="$HIVEMIND_DIR/tty-sessions"

if [ -d "$SESSIONS_DIR" ]; then
  mv "$SESSIONS_DIR" "$BACKUP_DIR/sessions" 2>/dev/null || true
  echo "Backed up session mappings: $BACKUP_DIR/sessions"
fi

if [ -d "$TTY_SESSIONS_DIR" ]; then
  mv "$TTY_SESSIONS_DIR" "$BACKUP_DIR/tty-sessions" 2>/dev/null || true
  echo "Backed up TTY session mappings: $BACKUP_DIR/tty-sessions"
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "Migration Complete!"
echo "==================="
echo "Agents migrated:   $AGENTS_MIGRATED"
echo "Locks migrated:    $LOCKS_MIGRATED"
echo "Messages migrated: $MESSAGES_MIGRATED"
echo "Changelog entries: $CHANGELOG_MIGRATED"
echo ""
echo "Original files have been backed up to: $BACKUP_DIR"
echo ""
echo "Database location: $HIVEMIND_DIR/hive.db"
echo ""
echo "You can verify the migration with:"
echo "  duckdb $HIVEMIND_DIR/hive.db \"SELECT * FROM agents\""
echo "  duckdb $HIVEMIND_DIR/hive.db \"SELECT COUNT(*) FROM changelog\""
