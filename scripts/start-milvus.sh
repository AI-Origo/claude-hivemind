#!/bin/bash
# Start Milvus containers for Hivemind
# Usage: ./start-milvus.sh [--with-ui]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/../infrastructure/docker-compose.yml"

# Configuration
MILVUS_HOST="${MILVUS_HOST:-localhost}"
MILVUS_PORT="${MILVUS_PORT:-19531}"
HEALTH_PORT="${HEALTH_PORT:-9092}"
MAX_WAIT=120  # seconds

# Parse arguments
PROFILE_ARGS=""
for arg in "$@"; do
  case "$arg" in
    --with-ui)
      PROFILE_ARGS="--profile ui"
      ;;
  esac
done

echo "Starting Hivemind Milvus..."

# Check if docker-compose or docker compose is available
if command -v docker-compose &> /dev/null; then
  COMPOSE_CMD="docker-compose"
elif docker compose version &> /dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
else
  echo "Error: Neither docker-compose nor docker compose is available"
  exit 1
fi

# Start containers
$COMPOSE_CMD -f "$COMPOSE_FILE" $PROFILE_ARGS up -d

echo "Waiting for Milvus to be healthy..."

# Wait for health endpoint
start_time=$(date +%s)
while true; do
  if curl -sf "http://${MILVUS_HOST}:${HEALTH_PORT}/healthz" > /dev/null 2>&1; then
    echo "Milvus is healthy!"
    break
  fi

  elapsed=$(($(date +%s) - start_time))
  if [[ $elapsed -ge $MAX_WAIT ]]; then
    echo "Error: Milvus did not become healthy within ${MAX_WAIT}s"
    echo "Check logs with: docker logs hivemind-milvus"
    exit 1
  fi

  echo "  Waiting... (${elapsed}s elapsed)"
  sleep 5
done

# Wait for API to be ready (health check passes before API is available)
echo "Waiting for API to be ready..."
start_time=$(date +%s)
while true; do
  if curl -sf -X POST "http://${MILVUS_HOST}:${MILVUS_PORT}/v2/vectordb/collections/list" \
      -H "Authorization: Bearer root:Milvus" \
      -H "Content-Type: application/json" \
      -d '{"dbName":"default"}' > /dev/null 2>&1; then
    echo "API is ready!"
    break
  fi

  elapsed=$(($(date +%s) - start_time))
  if [[ $elapsed -ge $MAX_WAIT ]]; then
    echo "Error: Milvus API did not become ready within ${MAX_WAIT}s"
    echo "Check logs with: docker logs hivemind-milvus"
    exit 1
  fi

  sleep 2
done

# Initialize collections if needed
INIT_SCRIPT="$SCRIPT_DIR/init-collections.sh"
if [[ -x "$INIT_SCRIPT" ]]; then
  echo "Initializing collections..."
  "$INIT_SCRIPT"
fi

echo ""
echo "Hivemind Milvus is ready!"
echo "  API: http://${MILVUS_HOST}:${MILVUS_PORT}"
echo "  Health: http://${MILVUS_HOST}:${HEALTH_PORT}/healthz"
if [[ -n "$PROFILE_ARGS" ]]; then
  echo "  Attu UI: http://${MILVUS_HOST}:8083"
fi
