#!/bin/bash
# DuckDB helper functions for Hivemind
# Usage: source this file after setting HIVEMIND_DIR, then call functions

# Get the script directory (where db.sh is located)
DB_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Database path - set HIVEMIND_DIR before sourcing this file
# Falls back to .hivemind in current directory
get_db_path() {
    local hivemind_dir="${HIVEMIND_DIR:-.hivemind}"
    echo "$hivemind_dir/hive.db"
}

# Initialize the database with schema
# Creates the database file and all tables
db_init() {
    local db_path
    db_path=$(get_db_path)
    local schema_file="$DB_SCRIPT_DIR/../db/schema.sql"

    # Ensure directory exists
    mkdir -p "$(dirname "$db_path")"

    # Check if schema file exists
    if [[ ! -f "$schema_file" ]]; then
        echo "Error: Schema file not found at $schema_file" >&2
        return 1
    fi

    # Initialize with VSS extension and HNSW persistence enabled
    duckdb "$db_path" <<'EOF'
INSTALL vss;
LOAD vss;
SET hnsw_enable_experimental_persistence = true;
EOF

    # Load schema (requires VSS loaded again in same session)
    duckdb "$db_path" <<EOF
LOAD vss;
SET hnsw_enable_experimental_persistence = true;
.read $schema_file
EOF
    return $?
}

# Execute a query and return JSON results
# Args:
#   $1 - SQL query
# Returns: JSON array of results (empty array if DuckDB not installed)
db_query() {
    local query="$1"
    local db_path
    db_path=$(get_db_path)

    # Ensure database exists (returns 1 if DuckDB not installed)
    if ! db_ensure_initialized; then
        echo "[]"
        return 1
    fi

    # Load VSS for HNSW index support
    duckdb -json "$db_path" "LOAD vss; $query" 2>/dev/null
}

# Execute a query without returning results (INSERT, UPDATE, DELETE)
# Args:
#   $1 - SQL query
# Returns: exit code (0 on success, 1 if DuckDB not installed)
db_exec() {
    local query="$1"
    local db_path
    db_path=$(get_db_path)

    # Ensure database exists (returns 1 if DuckDB not installed)
    if ! db_ensure_initialized; then
        return 1
    fi

    # Load VSS for HNSW index support
    duckdb "$db_path" "LOAD vss; $query" 2>/dev/null
    return $?
}

# Execute multiple statements (useful for transactions)
# Args:
#   $1 - SQL statements (can include multiple statements separated by ;)
# Returns: exit code (0 on success, 1 if DuckDB not installed)
db_exec_multi() {
    local statements="$1"
    local db_path
    db_path=$(get_db_path)

    # Ensure database exists (returns 1 if DuckDB not installed)
    if ! db_ensure_initialized; then
        return 1
    fi

    # Execute statements
    echo "$statements" | duckdb "$db_path" 2>/dev/null
    return $?
}

# Check if database is initialized, initialize if not
# Returns: 0 on success, 1 if DuckDB not installed or init fails
db_ensure_initialized() {
    local db_path
    db_path=$(get_db_path)

    if [[ ! -f "$db_path" ]]; then
        # Don't try to init if duckdb isn't installed
        if ! command -v duckdb &> /dev/null; then
            return 1
        fi
        db_init
    fi
}

# Escape a string for safe SQL insertion
# Args:
#   $1 - string to escape
# Returns: escaped string (with single quotes escaped)
db_escape() {
    local str="$1"
    # Escape single quotes by doubling them
    echo "${str//\'/\'\'}"
}

# Quote a string for SQL (wraps in single quotes and escapes)
# Args:
#   $1 - string to quote
# Returns: quoted string ready for SQL
db_quote() {
    local str="$1"
    local escaped
    escaped=$(db_escape "$str")
    echo "'$escaped'"
}

# Check if a record exists
# Args:
#   $1 - table name
#   $2 - where clause (e.g., "id = 1" or "name = 'alfa'")
# Returns: 0 if exists, 1 if not (also 1 if DuckDB not installed)
db_exists() {
    local table="$1"
    local where_clause="$2"
    local db_path
    db_path=$(get_db_path)

    # Ensure database exists (returns 1 if DuckDB not installed)
    if ! db_ensure_initialized; then
        return 1
    fi

    local result
    result=$(duckdb -json "$db_path" "SELECT 1 FROM $table WHERE $where_clause LIMIT 1" 2>/dev/null)

    if [[ "$result" == "[]" ]] || [[ -z "$result" ]]; then
        return 1
    fi
    return 0
}

# Get a single value from the database
# Args:
#   $1 - SQL query (should return single row, single column)
# Returns: the value, or empty string if not found (also empty if DuckDB not installed)
db_get_value() {
    local query="$1"
    local db_path
    db_path=$(get_db_path)

    # Ensure database exists (returns 1 if DuckDB not installed)
    if ! db_ensure_initialized; then
        return 1
    fi

    local result
    result=$(duckdb -json "$db_path" "$query" 2>/dev/null)

    # Extract first column of first row
    echo "$result" | jq -r '.[0] | to_entries | .[0].value // empty' 2>/dev/null
}

# Get next sequence value
# Args:
#   $1 - sequence name
# Returns: next value
db_next_id() {
    local seq_name="$1"
    db_get_value "SELECT nextval('$seq_name')"
}

# Copy template files to hivemind directory if they don't exist
# Should be called during first-time initialization
db_copy_templates() {
    local hivemind_dir="${HIVEMIND_DIR:-.hivemind}"
    local template_dir="$DB_SCRIPT_DIR/../../templates"

    # Create hivemind directory if it doesn't exist
    mkdir -p "$hivemind_dir"

    # Copy .env.example if it doesn't exist
    if [[ ! -f "$hivemind_dir/.env.example" ]] && [[ -f "$template_dir/.env.example" ]]; then
        cp "$template_dir/.env.example" "$hivemind_dir/.env.example"
    fi

    # Copy .gitignore if it doesn't exist
    if [[ ! -f "$hivemind_dir/.gitignore" ]] && [[ -f "$template_dir/.gitignore" ]]; then
        cp "$template_dir/.gitignore" "$hivemind_dir/.gitignore"
    fi
}

# Full initialization: copy templates + create database
db_full_init() {
    db_copy_templates
    db_init
}

# Clean up transient data (for session end)
# Preserves: .env, .env.example, .gitignore, hive.db, all knowledge/memory/tasks data
# Cleans: agent sessions, locks, messages to/from agent
db_cleanup_transient() {
    local agent_name="$1"

    if [[ -n "$agent_name" ]]; then
        # Clean up specific agent's transient data
        db_exec "DELETE FROM file_locks WHERE agent_name = $(db_quote "$agent_name")"
        # Delete all messages sent to or from this agent
        db_exec "DELETE FROM messages WHERE from_agent = $(db_quote "$agent_name") OR to_agent = $(db_quote "$agent_name")"
        db_exec "UPDATE agents SET session_id = NULL, ended_at = now() WHERE name = $(db_quote "$agent_name")"
    fi

    # Clean up delivered messages older than 24 hours
    db_exec "DELETE FROM messages WHERE delivered_at IS NOT NULL AND delivered_at < now() - INTERVAL '24 hours'"
}

# Check if DuckDB is installed
db_check_duckdb() {
    command -v duckdb &> /dev/null
}

# Install DuckDB (called by /hive setup)
db_install_duckdb() {
    if db_check_duckdb; then
        echo "DuckDB is already installed."
        return 0
    fi

    if command -v brew &> /dev/null; then
        echo "Installing DuckDB via Homebrew..."
        brew install duckdb
        return $?
    elif command -v apt-get &> /dev/null; then
        echo "Installing DuckDB via apt..."
        sudo apt-get update && sudo apt-get install -y duckdb
        return $?
    else
        echo "Cannot auto-install. Please install manually:"
        echo "  macOS:  brew install duckdb"
        echo "  Linux:  https://duckdb.org/docs/installation"
        return 1
    fi
}
