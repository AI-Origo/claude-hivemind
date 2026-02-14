#!/bin/bash
# Milvus helper functions for Hivemind
# Usage: source this file after setting HIVEMIND_DIR, then call functions
#
# Migrated from DuckDB to Milvus REST API (v2.5.4)
# All timestamps stored as Unix epoch (int64)
# Arrays stored as JSON strings

# Get the script directory (where db.sh is located)
DB_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Milvus configuration
MILVUS_HOST="${MILVUS_HOST:-localhost}"
MILVUS_PORT="${MILVUS_PORT:-19531}"
MILVUS_AUTH="${MILVUS_AUTH:-root:Milvus}"
MILVUS_URL="http://${MILVUS_HOST}:${MILVUS_PORT}"
MILVUS_DB="${MILVUS_DB:-default}"

# Placeholder vector for non-vector collections (8 dimensions)
PLACEHOLDER_VECTOR="[0,0,0,0,0,0,0,0]"

# Get the log file path for database operations
get_db_log_path() {
    local hivemind_dir="${HIVEMIND_DIR:-.hivemind}"
    echo "$hivemind_dir/logs/db.log"
}

# Get collection prefix from HIVEMIND_DIR (directory containing .hivemind)
# Called lazily since HIVEMIND_DIR may not be set when db.sh is sourced
# Returns: <project>_hivemind (e.g., euskb_hivemind)
get_collection_prefix() {
    if [[ -n "${HIVEMIND_DIR:-}" ]]; then
        local project_root
        project_root=$(dirname "$HIVEMIND_DIR")
        local project_name
        project_name=$(basename "$project_root")
        # Sanitize for Milvus: lowercase, only [a-z_] allowed
        project_name=$(echo "$project_name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z]/_/g' | sed 's/__*/_/g' | sed 's/^_//;s/_$//')
        echo "${project_name}_hivemind"
    else
        echo "default_hivemind"
    fi
}

# Generic POST request to Milvus with retry for rate limiting
# Args:
#   $1 - endpoint (e.g., /v2/vectordb/entities/query)
#   $2 - JSON body
# Returns: response JSON
milvus_post() {
    local endpoint="$1"
    local data="$2"
    local db_log
    db_log=$(get_db_log_path)

    local max_retries=3
    local retry_delay=0.2  # Start with 200ms
    local attempt=0

    while [[ $attempt -lt $max_retries ]]; do
        local response
        response=$(curl -sf -X POST "${MILVUS_URL}${endpoint}" \
            -H "Authorization: Bearer ${MILVUS_AUTH}" \
            -H "Content-Type: application/json" \
            -d "$data" 2>>"$db_log")

        if [[ $? -ne 0 ]]; then
            echo '{"code":1,"message":"curl failed"}' >&2
            return 1
        fi

        # Check for Milvus error response
        local code
        code=$(echo "$response" | jq -r '.code // 0' 2>/dev/null)

        # Rate limit error (code 1807) - retry with backoff
        if [[ "$code" == "1807" ]]; then
            ((attempt++))
            if [[ $attempt -lt $max_retries ]]; then
                sleep "$retry_delay"
                retry_delay=$(echo "$retry_delay * 2" | bc)  # Exponential backoff
                continue
            fi
        fi

        if [[ "$code" != "0" ]]; then
            echo "$response" >> "$db_log"
            echo "$response"
            return 1
        fi

        echo "$response"
        return 0
    done

    echo '{"code":1807,"message":"rate limit exceeded after retries"}' >&2
    return 1
}

# Health check
# Returns: 0 if healthy, 1 if not
milvus_health() {
    curl -sf "http://${MILVUS_HOST}:${HEALTH_PORT:-9092}/healthz" > /dev/null 2>&1
}

# Check if Milvus is available and collections are initialized
# Returns: 0 if ready, 1 if not
milvus_ready() {
    local collection="$(get_collection_prefix)_agents"
    local result
    result=$(milvus_post "/v2/vectordb/collections/has" "{\"dbName\":\"${MILVUS_DB}\",\"collectionName\":\"$collection\"}" 2>/dev/null)
    [[ $(echo "$result" | jq -r '.data.has // false') == "true" ]]
}

# Query entities from a collection
# Args:
#   $1 - collection name (without prefix)
#   $2 - filter expression (Milvus filter syntax)
#   $3 - output fields (comma-separated, optional)
#   $4 - limit (optional, default 100)
# Returns: JSON array of matching entities
milvus_query() {
    local collection="$(get_collection_prefix)_$1"
    local filter="$2"
    local output_fields="${3:-*}"
    local limit="${4:-100}"

    local output_fields_json
    if [[ "$output_fields" == "*" ]]; then
        output_fields_json='["*"]'
    else
        output_fields_json=$(echo "$output_fields" | jq -R 'split(",") | map(gsub("^\\s+|\\s+$";""))')
    fi

    local body
    body=$(jq -n \
        --arg db "$MILVUS_DB" \
        --arg col "$collection" \
        --arg filter "$filter" \
        --argjson fields "$output_fields_json" \
        --argjson limit "$limit" \
        '{dbName:$db,collectionName:$col,filter:$filter,outputFields:$fields,limit:$limit}')

    local result
    result=$(milvus_post "/v2/vectordb/entities/query" "$body")
    if [[ $? -ne 0 ]]; then
        echo "[]"
        return 1
    fi

    # Extract data array from response
    echo "$result" | jq -c '.data // []'
}

# Flush collection to ensure writes are visible to subsequent reads
# This provides read-after-write consistency for cross-agent visibility
# Args:
#   $1 - collection name (without prefix)
# Returns: 0 on success, 1 on error
milvus_flush() {
    local collection="$(get_collection_prefix)_$1"

    local body
    body=$(jq -n \
        --arg db "$MILVUS_DB" \
        --arg col "$collection" \
        '{dbName:$db,collectionName:$col}')

    local result
    result=$(milvus_post "/v2/vectordb/collections/flush" "$body")
    [[ $? -eq 0 ]]
}

# Insert entities into a collection
# Args:
#   $1 - collection name (without prefix)
#   $2 - JSON array of entities to insert
#   $3 - (optional) "no_flush" to skip flush for eventual consistency
# Returns: 0 on success, 1 on error
milvus_insert() {
    local collection="$(get_collection_prefix)_$1"
    local data="$2"
    local skip_flush="${3:-}"

    local body
    body=$(jq -n \
        --arg db "$MILVUS_DB" \
        --arg col "$collection" \
        --argjson data "$data" \
        '{dbName:$db,collectionName:$col,data:$data}')

    local result
    result=$(milvus_post "/v2/vectordb/entities/insert" "$body")
    local rc=$?

    # Flush to ensure write is visible to other processes (unless skipped)
    if [[ $rc -eq 0 && "$skip_flush" != "no_flush" ]]; then
        milvus_flush "$1"
    fi

    [[ $rc -eq 0 ]]
}

# Upsert entities into a collection (insert or update)
# Args:
#   $1 - collection name (without prefix)
#   $2 - JSON array of entities to upsert
# Returns: 0 on success, 1 on error
milvus_upsert() {
    local collection="$(get_collection_prefix)_$1"
    local data="$2"

    local body
    body=$(jq -n \
        --arg db "$MILVUS_DB" \
        --arg col "$collection" \
        --argjson data "$data" \
        '{dbName:$db,collectionName:$col,data:$data}')

    local result
    result=$(milvus_post "/v2/vectordb/entities/upsert" "$body")
    local rc=$?

    # Flush to ensure write is visible to other processes
    if [[ $rc -eq 0 ]]; then
        milvus_flush "$1"
    fi

    [[ $rc -eq 0 ]]
}

# Delete entities from a collection by filter
# Args:
#   $1 - collection name (without prefix)
#   $2 - filter expression (Milvus filter syntax)
# Returns: 0 on success, 1 on error
milvus_delete() {
    local collection="$(get_collection_prefix)_$1"
    local filter="$2"

    local body
    body=$(jq -n \
        --arg db "$MILVUS_DB" \
        --arg col "$collection" \
        --arg filter "$filter" \
        '{dbName:$db,collectionName:$col,filter:$filter}')

    local result
    result=$(milvus_post "/v2/vectordb/entities/delete" "$body")
    [[ $? -eq 0 ]]
}

# Delete entities by ID
# Args:
#   $1 - collection name (without prefix)
#   $2 - JSON array of IDs to delete
# Returns: 0 on success, 1 on error
milvus_delete_by_ids() {
    local collection="$(get_collection_prefix)_$1"
    local ids="$2"

    local body
    body=$(jq -n \
        --arg db "$MILVUS_DB" \
        --arg col "$collection" \
        --argjson ids "$ids" \
        '{dbName:$db,collectionName:$col,id:$ids}')

    local result
    result=$(milvus_post "/v2/vectordb/entities/delete" "$body")
    [[ $? -eq 0 ]]
}

# Vector similarity search
# Args:
#   $1 - collection name (without prefix)
#   $2 - embedding vector as JSON array
#   $3 - filter expression (optional)
#   $4 - limit (optional, default 10)
#   $5 - output fields (comma-separated, optional)
# Returns: JSON array of matching entities with distances
milvus_search() {
    local collection="$(get_collection_prefix)_$1"
    local vector="$2"
    local filter="${3:-}"
    local limit="${4:-10}"
    local output_fields="${5:-*}"

    local output_fields_json
    if [[ "$output_fields" == "*" ]]; then
        output_fields_json='["*"]'
    else
        output_fields_json=$(echo "$output_fields" | jq -R 'split(",") | map(gsub("^\\s+|\\s+$";""))')
    fi

    local body
    if [[ -n "$filter" ]]; then
        body=$(jq -n \
            --arg db "$MILVUS_DB" \
            --arg col "$collection" \
            --argjson vec "[$vector]" \
            --arg filter "$filter" \
            --argjson limit "$limit" \
            --argjson fields "$output_fields_json" \
            '{dbName:$db,collectionName:$col,data:$vec,filter:$filter,limit:$limit,outputFields:$fields}')
    else
        body=$(jq -n \
            --arg db "$MILVUS_DB" \
            --arg col "$collection" \
            --argjson vec "[$vector]" \
            --argjson limit "$limit" \
            --argjson fields "$output_fields_json" \
            '{dbName:$db,collectionName:$col,data:$vec,limit:$limit,outputFields:$fields}')
    fi

    local result
    result=$(milvus_post "/v2/vectordb/entities/search" "$body")
    if [[ $? -ne 0 ]]; then
        echo "[]"
        return 1
    fi

    # Extract data array from response
    echo "$result" | jq -c '.data // []'
}

# Get next sequence value (atomic increment)
# Args:
#   $1 - sequence name (e.g., changelog_id_seq)
# Returns: next integer value
milvus_next_id() {
    local seq_name="$1"

    # Query current value
    local result
    result=$(milvus_query "sequences" "id == \"$seq_name\"" "current_value" 1)
    local current
    current=$(echo "$result" | jq -r '.[0].current_value // 0')

    # Increment
    local next=$((current + 1))

    # Upsert with new value
    milvus_upsert "sequences" "[{\"id\":\"$seq_name\",\"embedding\":$PLACEHOLDER_VECTOR,\"current_value\":$next}]"

    echo "$next"
}

# Get current Unix timestamp
get_timestamp() {
    date +%s
}

# Convert ISO timestamp to Unix epoch
iso_to_epoch() {
    local iso="$1"
    if [[ -z "$iso" || "$iso" == "null" ]]; then
        echo "0"
        return
    fi
    # macOS date command
    if date -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null; then
        return
    fi
    # GNU date command
    date -d "$iso" +%s 2>/dev/null || echo "0"
}

# Convert Unix epoch to ISO timestamp
epoch_to_iso() {
    local epoch="$1"
    if [[ -z "$epoch" || "$epoch" == "0" ]]; then
        echo ""
        return
    fi
    # macOS date command
    if date -r "$epoch" -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null; then
        return
    fi
    # GNU date command
    date -u -d "@$epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo ""
}

# Escape a string for Milvus filter expression
# Args:
#   $1 - string to escape
# Returns: escaped string (with quotes escaped)
db_escape() {
    local str="$1"
    # Escape backslashes first, then double quotes
    str="${str//\\/\\\\}"
    str="${str//\"/\\\"}"
    echo "$str"
}

# Quote a string for Milvus filter (wraps in double quotes)
# Args:
#   $1 - string to quote
# Returns: quoted string ready for filter
db_quote() {
    local str="$1"
    local escaped
    escaped=$(db_escape "$str")
    echo "\"$escaped\""
}

# ============================================================================
# BACKWARDS-COMPATIBLE WRAPPER FUNCTIONS
# These emulate the DuckDB interface for easier migration
# ============================================================================

# Check if Milvus is ready (replaces db_check_duckdb)
db_check_milvus() {
    milvus_ready
}

# Ensure database is initialized (now checks Milvus)
db_ensure_initialized() {
    milvus_ready
}

# Execute a query and return JSON results (compatibility wrapper)
# Now uses milvus_query internally
# Args:
#   $1 - pseudo-SQL query (parsed and converted to Milvus operations)
# Returns: JSON array of results
db_query() {
    local query="$1"

    # This is a compatibility shim - actual implementation in handlers
    # should be migrated to use milvus_query directly
    echo "[]"
    return 1
}

# Execute a statement without returning results (compatibility wrapper)
# Args:
#   $1 - pseudo-SQL statement
# Returns: exit code
db_exec() {
    local statement="$1"

    # This is a compatibility shim - actual implementation in handlers
    # should be migrated to use milvus_insert/upsert/delete directly
    return 1
}

# Get a single value (compatibility wrapper)
# Args:
#   $1 - pseudo-SQL query
# Returns: the value, or empty string if not found
db_get_value() {
    local query="$1"

    # This is a compatibility shim
    echo ""
    return 1
}

# Get next sequence value (compatibility wrapper, uses milvus_next_id)
db_next_id() {
    local seq_name="$1"
    milvus_next_id "$seq_name"
}

# Check if a record exists (compatibility wrapper)
# Args:
#   $1 - collection name (without prefix)
#   $2 - filter expression
# Returns: 0 if exists, 1 if not
db_exists() {
    local collection="$1"
    local filter="$2"
    local result
    result=$(milvus_query "$collection" "$filter" "id" 1)
    [[ $(echo "$result" | jq 'length') -gt 0 ]]
}

# Copy template files to hivemind directory
db_copy_templates() {
    local hivemind_dir="${HIVEMIND_DIR:-.hivemind}"
    local template_dir="$DB_SCRIPT_DIR/../../templates"

    # Create hivemind directory and logs subdirectory
    mkdir -p "$hivemind_dir/logs"

    # Copy .env.example if it doesn't exist
    if [[ ! -f "$hivemind_dir/.env.example" ]] && [[ -f "$template_dir/.env.example" ]]; then
        cp "$template_dir/.env.example" "$hivemind_dir/.env.example"
    fi

    # Copy .gitignore if it doesn't exist
    if [[ ! -f "$hivemind_dir/.gitignore" ]] && [[ -f "$template_dir/.gitignore" ]]; then
        cp "$template_dir/.gitignore" "$hivemind_dir/.gitignore"
    fi
}

# Full initialization: copy templates (no longer creates database)
db_full_init() {
    db_copy_templates
    # Milvus collections are initialized separately via init-collections.sh
}

# Purge all Milvus collections for the current project and clean up temp files
# Used when .hivemind is deleted to reset project state
db_purge_project() {
    local prefix
    prefix=$(get_collection_prefix)

    local result
    result=$(curl -sf -X POST "${MILVUS_URL}/v2/vectordb/collections/list" \
        -H "Authorization: Bearer ${MILVUS_AUTH}" \
        -H "Content-Type: application/json" \
        -d "{\"dbName\":\"${MILVUS_DB}\"}" 2>/dev/null) || return 0

    local collections
    collections=$(echo "$result" | jq -r '.data[]' 2>/dev/null | grep "^${prefix}_" || true)

    [[ -z "$collections" ]] && return 0

    while IFS= read -r col; do
        [[ -z "$col" ]] && continue
        curl -sf -X POST "${MILVUS_URL}/v2/vectordb/collections/drop" \
            -H "Authorization: Bearer ${MILVUS_AUTH}" \
            -H "Content-Type: application/json" \
            -d "{\"dbName\":\"${MILVUS_DB}\",\"collectionName\":\"$col\"}" > /dev/null 2>&1 || true
    done <<< "$collections"

    rm -f /tmp/hivemind-status-* /tmp/hivemind-dir-* 2>/dev/null || true
}

# Clean up transient data (for session end)
db_cleanup_transient() {
    local agent_name="$1"

    if [[ -n "$agent_name" ]]; then
        # Clean up specific agent's transient data
        milvus_delete "file_locks" "agent_name == $(db_quote "$agent_name")"

        # Delete all messages sent to or from this agent
        milvus_delete "messages" "from_agent == $(db_quote "$agent_name")"
        milvus_delete "messages" "to_agent == $(db_quote "$agent_name")"

        # Mark agent as ended
        local now
        now=$(get_timestamp)
        # Note: We need to query and re-upsert to update the agent
        # This is handled in session-end.sh directly
    fi

    # Clean up delivered messages older than 24 hours
    local cutoff=$(($(get_timestamp) - 86400))
    milvus_delete "messages" "delivered_at > 0 and delivered_at < $cutoff"
}

# ============================================================================
# AGENT HELPERS
# ============================================================================

# Get agent by TTY
get_agent_by_tty() {
    local tty="$1"
    milvus_query "agents" "tty == $(db_quote "$tty") and ended_at < 1" "*" 1
}

# Get agent by session ID
get_agent_by_session() {
    local session_id="$1"
    milvus_query "agents" "session_id == $(db_quote "$session_id") and ended_at < 1" "*" 1
}

# Get agent by name
get_agent_by_name() {
    local name="$1"
    milvus_query "agents" "id == $(db_quote "$name")" "*" 1
}

# Get all active agents
get_active_agents() {
    milvus_query "agents" "ended_at < 1" "*" 100
}

# Create or update agent
upsert_agent() {
    local name="$1"
    local session_id="$2"
    local tty="$3"
    local started_at="$4"
    local ended_at="${5:-0}"
    local current_task="${6:-}"
    local last_task="${7:-}"

    local data
    data=$(jq -n \
        --arg id "$name" \
        --arg name "$name" \
        --arg session_id "$session_id" \
        --arg tty "$tty" \
        --argjson started_at "$started_at" \
        --argjson ended_at "$ended_at" \
        --arg current_task "$current_task" \
        --arg last_task "$last_task" \
        --argjson embedding "$PLACEHOLDER_VECTOR" \
        '[{id:$id,name:$name,session_id:$session_id,tty:$tty,started_at:$started_at,ended_at:$ended_at,current_task:$current_task,last_task:$last_task,embedding:$embedding}]')

    milvus_upsert "agents" "$data"
}

# ============================================================================
# MESSAGE HELPERS
# ============================================================================

# Insert a message
insert_message() {
    local msg_id="$1"
    local from_agent="$2"
    local to_agent="$3"
    local body="$4"
    local priority="${5:-normal}"
    local created_at="${6:-$(get_timestamp)}"

    local data
    data=$(jq -n \
        --arg id "$msg_id" \
        --arg from_agent "$from_agent" \
        --arg to_agent "$to_agent" \
        --arg body "$body" \
        --arg priority "$priority" \
        --argjson created_at "$created_at" \
        --argjson delivered_at 0 \
        --argjson embedding "$PLACEHOLDER_VECTOR" \
        '[{id:$id,from_agent:$from_agent,to_agent:$to_agent,body:$body,priority:$priority,created_at:$created_at,delivered_at:$delivered_at,embedding:$embedding}]')

    milvus_insert "messages" "$data"
}

# Get pending messages for an agent
get_pending_messages() {
    local agent_name="$1"
    milvus_query "messages" "to_agent == $(db_quote "$agent_name") and delivered_at == 0" "*" 100
}

# Mark messages as delivered
mark_messages_delivered() {
    local msg_ids="$1"  # JSON array of IDs
    local delivered_at
    delivered_at=$(get_timestamp)

    # For each message ID, we need to query, update, and upsert
    echo "$msg_ids" | jq -r '.[]' | while read -r msg_id; do
        local msg
        msg=$(milvus_query "messages" "id == $(db_quote "$msg_id")" "*" 1)
        if [[ $(echo "$msg" | jq 'length') -gt 0 ]]; then
            local updated
            updated=$(echo "$msg" | jq --argjson ts "$delivered_at" '.[0] | .delivered_at = $ts' | jq -c '[.]')
            milvus_upsert "messages" "$updated"
        fi
    done
}

# ============================================================================
# FILE LOCK HELPERS
# ============================================================================

# Acquire file lock
acquire_lock() {
    local file_path="$1"
    local agent_name="$2"
    local locked_at="${3:-$(get_timestamp)}"

    # Use file_path as ID
    local data
    data=$(jq -n \
        --arg id "$file_path" \
        --arg file_path "$file_path" \
        --arg agent_name "$agent_name" \
        --argjson locked_at "$locked_at" \
        --argjson embedding "$PLACEHOLDER_VECTOR" \
        '[{id:$id,file_path:$file_path,agent_name:$agent_name,locked_at:$locked_at,embedding:$embedding}]')

    milvus_upsert "file_locks" "$data"
}

# Get lock for file
get_file_lock() {
    local file_path="$1"
    milvus_query "file_locks" "id == $(db_quote "$file_path")" "*" 1
}

# Release lock
release_lock() {
    local file_path="$1"
    local agent_name="$2"
    milvus_delete "file_locks" "id == $(db_quote "$file_path") and agent_name == $(db_quote "$agent_name")"
}

# Release all locks for agent
release_agent_locks() {
    local agent_name="$1"
    milvus_delete "file_locks" "agent_name == $(db_quote "$agent_name")"
}

# ============================================================================
# WAKE QUEUE HELPERS
# ============================================================================

# Insert a wake request into the queue
insert_wake_request() {
    local tty="$1"
    local id="wake-$(date +%s%N)-$$"
    local created_at
    created_at=$(get_timestamp)

    local data
    data=$(jq -n \
        --arg id "$id" \
        --arg tty "$tty" \
        --argjson created_at "$created_at" \
        --argjson embedding "$PLACEHOLDER_VECTOR" \
        '[{id:$id,tty:$tty,created_at:$created_at,embedding:$embedding}]')

    milvus_insert "wake_queue" "$data"
}

# Get the oldest wake request from the queue
get_next_wake_request() {
    local result
    result=$(milvus_query "wake_queue" "created_at > 0" "*" 100)
    echo "$result" | jq -c 'sort_by(.created_at) | .[0] // empty'
}

# Delete a wake request by ID
delete_wake_request() {
    local id="$1"
    milvus_delete "wake_queue" "id == $(db_quote "$id")"
    milvus_flush "wake_queue"
}

# ============================================================================
# CHANGELOG HELPERS
# ============================================================================

# Insert changelog entry
insert_changelog() {
    local agent="$1"
    local action="$2"
    local file_path="$3"
    local summary="${4:-}"

    local seq_id
    seq_id=$(milvus_next_id "changelog_id_seq")
    local id="changelog-$seq_id"
    local timestamp
    timestamp=$(get_timestamp)

    local data
    data=$(jq -n \
        --arg id "$id" \
        --argjson seq_id "$seq_id" \
        --argjson timestamp "$timestamp" \
        --arg agent "$agent" \
        --arg action "$action" \
        --arg file_path "$file_path" \
        --arg summary "$summary" \
        --argjson embedding "$PLACEHOLDER_VECTOR" \
        '[{id:$id,seq_id:$seq_id,timestamp:$timestamp,agent:$agent,action:$action,file_path:$file_path,summary:$summary,embedding:$embedding}]')

    # Skip flush for changelog - eventual consistency is acceptable
    milvus_insert "changelog" "$data" "no_flush"
}

# Get recent changelog entries
get_recent_changelog() {
    local limit="${1:-20}"
    # Note: Milvus doesn't support ORDER BY, so we query all and sort with jq
    local result
    result=$(milvus_query "changelog" "timestamp > 0" "*" "$limit")
    echo "$result" | jq -c 'sort_by(-.seq_id) | .[:'"$limit"']'
}

# ============================================================================
# TASK HELPERS
# ============================================================================

# Create task
create_task() {
    local title="$1"
    local description="${2:-}"
    local embedding="${3:-}"  # JSON array or empty
    local assignee="${4:-}"
    local initial_state="${5:-pending}"

    local seq_id
    seq_id=$(milvus_next_id "task_id_seq")
    local id="task-$seq_id"
    local created_at
    created_at=$(get_timestamp)

    # Set claimed_at if task starts in an active state
    local claimed_at=0
    if [[ "$initial_state" == "in_progress" || "$initial_state" == "claimed" ]]; then
        claimed_at="$created_at"
    fi

    # Use proper embedding or null placeholder for 3072-dim
    local embed_vec
    if [[ -n "$embedding" && "$embedding" != "null" ]]; then
        embed_vec="$embedding"
    else
        # Milvus requires embedding, use zeros
        embed_vec=$(python3 -c "import json; print(json.dumps([0.0]*3072))" 2>/dev/null || echo "[$(seq -s, 0 1 3071 | sed 's/[0-9]*/0.0/g')]")
    fi

    local data
    data=$(jq -n \
        --arg id "$id" \
        --argjson seq_id "$seq_id" \
        --arg title "$title" \
        --arg description "$description" \
        --arg state "$initial_state" \
        --arg assignee "$assignee" \
        --arg depends_on "[]" \
        --argjson parent_id 0 \
        --argjson created_at "$created_at" \
        --argjson claimed_at "$claimed_at" \
        --argjson completed_at 0 \
        --arg rejection_note "" \
        --argjson embedding "$embed_vec" \
        '[{id:$id,seq_id:$seq_id,title:$title,description:$description,state:$state,assignee:$assignee,depends_on:$depends_on,parent_id:$parent_id,created_at:$created_at,claimed_at:$claimed_at,completed_at:$completed_at,rejection_note:$rejection_note,embedding:$embedding}]')

    milvus_insert "tasks" "$data"
    echo "$seq_id"
}

# Get task by seq_id
get_task_by_id() {
    local seq_id="$1"
    local id="task-$seq_id"
    milvus_query "tasks" "id == $(db_quote "$id")" "*" 1
}

# Get tasks by state
get_tasks_by_state() {
    local state="$1"
    local limit="${2:-100}"
    milvus_query "tasks" "state == $(db_quote "$state")" "*" "$limit"
}

# Get tasks for agent
get_tasks_for_agent() {
    local agent_name="$1"
    milvus_query "tasks" "assignee == $(db_quote "$agent_name")" "*" 100
}

# Update task (query, modify, upsert)
update_task() {
    local seq_id="$1"
    local field="$2"
    local value="$3"

    local id="task-$seq_id"
    local task
    task=$(milvus_query "tasks" "id == $(db_quote "$id")" "*" 1)

    if [[ $(echo "$task" | jq 'length') -eq 0 ]]; then
        return 1
    fi

    local updated
    # Handle different value types
    if [[ "$value" =~ ^[0-9]+$ ]]; then
        updated=$(echo "$task" | jq --arg f "$field" --argjson v "$value" '.[0] | .[$f] = $v')
    else
        updated=$(echo "$task" | jq --arg f "$field" --arg v "$value" '.[0] | .[$f] = $v')
    fi

    milvus_upsert "tasks" "[$updated]"
}

# ============================================================================
# AGENT FLAG HELPERS
# ============================================================================

# Set a flag on an agent (stored in agent's flags field as JSON)
set_agent_flag() {
  local agent_name="$1"
  local flag="$2"
  local value="$3"

  # Get current agent data
  local agent_json
  agent_json=$(milvus_query "agents" "id == $(db_quote "$agent_name")" "*" 1)
  if [[ $(echo "$agent_json" | jq 'length') -eq 0 ]]; then
    return 1
  fi

  # Get or initialize flags field
  local current_flags
  current_flags=$(echo "$agent_json" | jq -r '.[0].flags // "{}"')
  [[ "$current_flags" == "null" || -z "$current_flags" ]] && current_flags="{}"

  # Update the flag
  local new_flags
  new_flags=$(echo "$current_flags" | jq --arg f "$flag" --arg v "$value" '.[$f] = $v')

  # Re-upsert the agent with updated flags
  local updated
  updated=$(echo "$agent_json" | jq --arg flags "$new_flags" '.[0] | .flags = $flags')
  milvus_upsert "agents" "[$updated]"
}

# Get a flag value from an agent
get_agent_flag() {
  local agent_name="$1"
  local flag="$2"

  local agent_json
  agent_json=$(milvus_query "agents" "id == $(db_quote "$agent_name")" "flags" 1)
  if [[ $(echo "$agent_json" | jq 'length') -eq 0 ]]; then
    echo ""
    return
  fi

  local flags
  flags=$(echo "$agent_json" | jq -r '.[0].flags // "{}"')
  [[ "$flags" == "null" || -z "$flags" ]] && flags="{}"

  echo "$flags" | jq -r --arg f "$flag" '.[$f] // ""'
}

# Clear a flag from an agent
clear_agent_flag() {
  local agent_name="$1"
  local flag="$2"

  # Get current agent data
  local agent_json
  agent_json=$(milvus_query "agents" "id == $(db_quote "$agent_name")" "*" 1)
  if [[ $(echo "$agent_json" | jq 'length') -eq 0 ]]; then
    return 1
  fi

  # Get or initialize flags field
  local current_flags
  current_flags=$(echo "$agent_json" | jq -r '.[0].flags // "{}"')
  [[ "$current_flags" == "null" || -z "$current_flags" ]] && current_flags="{}"

  # Remove the flag
  local new_flags
  new_flags=$(echo "$current_flags" | jq --arg f "$flag" 'del(.[$f])')

  # Re-upsert the agent with updated flags
  local updated
  updated=$(echo "$agent_json" | jq --arg flags "$new_flags" '.[0] | .flags = $flags')
  milvus_upsert "agents" "[$updated]"
}

# ============================================================================
# METRICS HELPERS
# ============================================================================

# Insert metric event
insert_metric() {
    local event_type="$1"
    local task_id="${2:-0}"
    local agent="${3:-}"
    local duration_minutes="${4:-0}"
    local metadata="${5:-}"

    local seq_id
    seq_id=$(milvus_next_id "metrics_id_seq")
    local id="metric-$seq_id"
    local timestamp
    timestamp=$(get_timestamp)

    local data
    data=$(jq -n \
        --arg id "$id" \
        --argjson seq_id "$seq_id" \
        --arg event_type "$event_type" \
        --argjson task_id "$task_id" \
        --arg agent "$agent" \
        --argjson timestamp "$timestamp" \
        --argjson duration_minutes "$duration_minutes" \
        --arg metadata "$metadata" \
        --argjson embedding "$PLACEHOLDER_VECTOR" \
        '[{id:$id,seq_id:$seq_id,event_type:$event_type,task_id:$task_id,agent:$agent,timestamp:$timestamp,duration_minutes:$duration_minutes,metadata:$metadata,embedding:$embedding}]')

    # Skip flush for metrics - eventual consistency is acceptable
    milvus_insert "metrics" "$data" "no_flush"
}

# Get metrics in time window
get_metrics_since() {
    local since_epoch="$1"
    local event_type="${2:-}"

    if [[ -n "$event_type" ]]; then
        milvus_query "metrics" "timestamp >= $since_epoch and event_type == $(db_quote "$event_type")" "*" 1000
    else
        milvus_query "metrics" "timestamp >= $since_epoch" "*" 1000
    fi
}
