#!/bin/bash
# Initialize Milvus collections for Hivemind
# Creates all collections with appropriate schemas (project-scoped)

set -euo pipefail

# Get the script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Find .hivemind directory by searching up from current directory
find_hivemind_dir() {
    local dir="${1:-$(pwd)}"
    while [[ "$dir" != "/" ]]; do
        if [[ -d "$dir/.hivemind" ]]; then
            echo "$dir/.hivemind"
            return 0
        fi
        dir=$(dirname "$dir")
    done
    return 1
}

HIVEMIND_DIR=$(find_hivemind_dir)
if [[ -z "$HIVEMIND_DIR" ]]; then
    echo "Error: .hivemind directory not found. Run from a project with hivemind initialized."
    exit 1
fi

PROJECT_ROOT=$(dirname "$HIVEMIND_DIR")
PROJECT_NAME=$(basename "$PROJECT_ROOT" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z]/_/g' | sed 's/__*/_/g' | sed 's/^_//;s/_$//')
COLLECTION_PREFIX="${PROJECT_NAME}_hivemind"

# Configuration
MILVUS_HOST="${MILVUS_HOST:-localhost}"
MILVUS_PORT="${MILVUS_PORT:-19531}"
MILVUS_AUTH="${MILVUS_AUTH:-root:Milvus}"
MILVUS_URL="http://${MILVUS_HOST}:${MILVUS_PORT}"
DB_NAME="${MILVUS_DB:-default}"

# Helper function to make authenticated POST requests
milvus_post() {
  local endpoint="$1"
  local data="$2"
  curl -sf -X POST "${MILVUS_URL}${endpoint}" \
    -H "Authorization: Bearer ${MILVUS_AUTH}" \
    -H "Content-Type: application/json" \
    -d "$data"
}

# Check if a collection exists
collection_exists() {
  local name="$1"
  local result
  result=$(milvus_post "/v2/vectordb/collections/has" "{\"dbName\":\"${DB_NAME}\",\"collectionName\":\"${name}\"}" 2>/dev/null)
  [[ $(echo "$result" | jq -r '.data.has // false') == "true" ]]
}

# Create a collection with placeholder vector (8 dimensions)
# Used for non-vector tables (agents, locks, messages, etc.)
create_placeholder_collection() {
  local name="$1"
  local description="${2:-}"

  if collection_exists "$name"; then
    echo "  Collection $name already exists, skipping"
    return 0
  fi

  echo "  Creating collection: $name (placeholder 8-dim)"
  # Use simplified API format - enableDynamicField must be in params
  milvus_post "/v2/vectordb/collections/create" "{
    \"dbName\": \"${DB_NAME}\",
    \"collectionName\": \"${name}\",
    \"dimension\": 8,
    \"metricType\": \"L2\",
    \"primaryFieldName\": \"id\",
    \"vectorFieldName\": \"embedding\",
    \"idType\": \"VarChar\",
    \"params\": {
      \"max_length\": 256,
      \"enableDynamicField\": true
    }
  }" > /dev/null

  # Load collection into memory
  milvus_post "/v2/vectordb/collections/load" "{
    \"dbName\": \"${DB_NAME}\",
    \"collectionName\": \"${name}\"
  }" > /dev/null
}

# Create a collection with semantic vector (3072 dimensions for text-embedding-3-large)
create_vector_collection() {
  local name="$1"
  local description="${2:-}"

  if collection_exists "$name"; then
    echo "  Collection $name already exists, skipping"
    return 0
  fi

  echo "  Creating collection: $name (vector 3072-dim)"
  # Use simplified API format - enableDynamicField must be in params
  milvus_post "/v2/vectordb/collections/create" "{
    \"dbName\": \"${DB_NAME}\",
    \"collectionName\": \"${name}\",
    \"dimension\": 3072,
    \"metricType\": \"IP\",
    \"primaryFieldName\": \"id\",
    \"vectorFieldName\": \"embedding\",
    \"idType\": \"VarChar\",
    \"params\": {
      \"max_length\": 256,
      \"enableDynamicField\": true
    }
  }" > /dev/null

  # Load collection into memory
  milvus_post "/v2/vectordb/collections/load" "{
    \"dbName\": \"${DB_NAME}\",
    \"collectionName\": \"${name}\"
  }" > /dev/null
}

# Create sequences collection for ID generation
create_sequences_collection() {
  local name="${COLLECTION_PREFIX}_sequences"

  if collection_exists "$name"; then
    echo "  Collection $name already exists, skipping"
    return 0
  fi

  echo "  Creating collection: $name (ID sequences)"
  # Use simplified API format - enableDynamicField must be in params
  milvus_post "/v2/vectordb/collections/create" "{
    \"dbName\": \"${DB_NAME}\",
    \"collectionName\": \"${name}\",
    \"dimension\": 8,
    \"metricType\": \"L2\",
    \"primaryFieldName\": \"id\",
    \"vectorFieldName\": \"embedding\",
    \"idType\": \"VarChar\",
    \"params\": {
      \"max_length\": 256,
      \"enableDynamicField\": true
    }
  }" > /dev/null

  # Load collection
  milvus_post "/v2/vectordb/collections/load" "{
    \"dbName\": \"${DB_NAME}\",
    \"collectionName\": \"${name}\"
  }" > /dev/null

  # Initialize sequences with starting values
  local placeholder_vec="[0,0,0,0,0,0,0,0]"
  echo "  Initializing sequences..."
  milvus_post "/v2/vectordb/entities/insert" "{
    \"dbName\": \"${DB_NAME}\",
    \"collectionName\": \"${name}\",
    \"data\": [
      {\"id\": \"changelog_id_seq\", \"embedding\": ${placeholder_vec}, \"current_value\": 0},
      {\"id\": \"task_id_seq\", \"embedding\": ${placeholder_vec}, \"current_value\": 0},
      {\"id\": \"decision_id_seq\", \"embedding\": ${placeholder_vec}, \"current_value\": 0},
      {\"id\": \"metrics_id_seq\", \"embedding\": ${placeholder_vec}, \"current_value\": 0},
      {\"id\": \"context_injection_id_seq\", \"embedding\": ${placeholder_vec}, \"current_value\": 0}
    ]
  }" > /dev/null
}

echo "Initializing Hivemind Milvus collections..."
echo "  Project: $PROJECT_NAME"
echo "  Collection prefix: $COLLECTION_PREFIX"
echo "  URL: ${MILVUS_URL}"
echo "  Database: ${DB_NAME}"
echo ""

# Check connectivity
if ! curl -sf -X POST "${MILVUS_URL}/v2/vectordb/collections/list" \
    -H "Authorization: Bearer ${MILVUS_AUTH}" \
    -H "Content-Type: application/json" \
    -d "{\"dbName\":\"${DB_NAME}\"}" > /dev/null 2>&1; then
  echo "Error: Cannot connect to Milvus at ${MILVUS_URL}"
  exit 1
fi

# Create placeholder collections (8-dim vectors for non-vector data)
echo "Creating placeholder collections..."
create_placeholder_collection "${COLLECTION_PREFIX}_agents" "Agent state and coordination"
create_placeholder_collection "${COLLECTION_PREFIX}_file_locks" "Concurrent file edit prevention"
create_placeholder_collection "${COLLECTION_PREFIX}_messages" "Inter-agent messaging"
create_placeholder_collection "${COLLECTION_PREFIX}_changelog" "File change audit log"
create_placeholder_collection "${COLLECTION_PREFIX}_metrics" "Observability metrics"
create_placeholder_collection "${COLLECTION_PREFIX}_context_injections" "Token budget tracking"
create_placeholder_collection "${COLLECTION_PREFIX}_wake_queue" "Sequential agent wakeup queue"

# Create vector collections (3072-dim for semantic search)
echo ""
echo "Creating vector collections..."
create_vector_collection "${COLLECTION_PREFIX}_tasks" "Task queue with semantic search"
create_vector_collection "${COLLECTION_PREFIX}_knowledge" "Knowledge base with embeddings"
create_vector_collection "${COLLECTION_PREFIX}_memory" "Key-value store with embeddings"
create_vector_collection "${COLLECTION_PREFIX}_decisions" "Decision log with embeddings"

# Create sequences collection
echo ""
echo "Creating sequences..."
create_sequences_collection

echo ""
echo "Collection initialization complete!"

# List all collections
echo ""
echo "Verifying collections:"
result=$(milvus_post "/v2/vectordb/collections/list" "{\"dbName\":\"${DB_NAME}\"}" 2>/dev/null)
echo "$result" | jq -r '.data[]' 2>/dev/null | grep "^${PROJECT_NAME}_hivemind_" | while read -r col; do
  echo "  - $col"
done
