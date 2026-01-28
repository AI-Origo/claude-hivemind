#!/bin/bash
# Generate embeddings via OpenAI API
# Usage: source this file, then call embed_text "text to embed" "/path/to/.hivemind"
# Returns: JSON array of floats (3072 dimensions for text-embedding-3-large)
# Note: Reads OPENAI_API_KEY from .env file, not exposed in process list

# Generate embedding for text
# Args:
#   $1 - text to embed
#   $2 - hivemind directory path (containing .env)
# Returns: JSON array of floats, or "null" if no API key or error
embed_text() {
    local text="$1"
    local hivemind_dir="$2"

    # Validate inputs
    if [[ -z "$text" ]]; then
        echo "null"
        return 1
    fi

    if [[ -z "$hivemind_dir" ]]; then
        echo "null"
        return 1
    fi

    # Load API key from .env without exposing in process list
    local api_key=""
    if [[ -f "$hivemind_dir/.env" ]]; then
        api_key=$(grep -E '^OPENAI_API_KEY=' "$hivemind_dir/.env" 2>/dev/null | cut -d'=' -f2-)
    fi

    if [[ -z "$api_key" ]] || [[ "$api_key" == "sk-..." ]]; then
        # No API key configured, return null (embeddings disabled)
        echo "null"
        return 1
    fi

    # Escape text for JSON (handle special characters)
    local escaped_text
    escaped_text=$(printf '%s' "$text" | jq -Rs '.')

    # Build request body
    local request_body
    request_body=$(cat <<EOF
{
    "input": $escaped_text,
    "model": "text-embedding-3-large"
}
EOF
)

    # Call OpenAI API (curl output not logged to avoid exposing key in errors)
    local response
    response=$(curl -s --max-time 30 "https://api.openai.com/v1/embeddings" \
        -H "Authorization: Bearer $api_key" \
        -H "Content-Type: application/json" \
        -d "$request_body" 2>/dev/null)

    # Check for errors
    if [[ -z "$response" ]]; then
        echo "null"
        return 1
    fi

    # Check for API error
    local error
    error=$(echo "$response" | jq -r '.error.message // empty' 2>/dev/null)
    if [[ -n "$error" ]]; then
        # Log error but don't expose to caller
        echo "null"
        return 1
    fi

    # Extract embedding array
    local embedding
    embedding=$(echo "$response" | jq -c '.data[0].embedding // null' 2>/dev/null)

    if [[ "$embedding" == "null" ]] || [[ -z "$embedding" ]]; then
        echo "null"
        return 1
    fi

    echo "$embedding"
    return 0
}

# Check if embeddings are available (API key configured)
# Args:
#   $1 - hivemind directory path
# Returns: 0 if available, 1 if not
embeddings_available() {
    local hivemind_dir="$1"

    if [[ ! -f "$hivemind_dir/.env" ]]; then
        return 1
    fi

    local api_key
    api_key=$(grep -E '^OPENAI_API_KEY=' "$hivemind_dir/.env" 2>/dev/null | cut -d'=' -f2-)

    if [[ -z "$api_key" ]] || [[ "$api_key" == "sk-..." ]]; then
        return 1
    fi

    return 0
}

# Format embedding array for Milvus insertion
# Milvus expects array format: [1.0, 2.0, 3.0, ...]
# Args:
#   $1 - JSON embedding array from OpenAI
# Returns: Milvus-compatible array string, or "null" if input is null
format_embedding_for_db() {
    local embedding="$1"

    if [[ "$embedding" == "null" ]] || [[ -z "$embedding" ]]; then
        # Return null - caller should generate zero vector if needed
        echo "null"
        return 1
    fi

    # OpenAI returns JSON array which is already Milvus compatible
    echo "$embedding"
    return 0
}
