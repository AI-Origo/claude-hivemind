#!/bin/bash
# Stop Milvus containers for Hivemind
# Usage: ./stop-milvus.sh [--remove-volumes]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/../infrastructure/docker-compose.yml"

# Parse arguments
VOLUME_ARGS=""
for arg in "$@"; do
  case "$arg" in
    --remove-volumes)
      VOLUME_ARGS="-v"
      echo "Warning: This will remove all Milvus data!"
      read -p "Are you sure? (y/N) " -n 1 -r
      echo
      if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
      fi
      ;;
  esac
done

echo "Stopping Hivemind Milvus..."

# Check if docker-compose or docker compose is available
if command -v docker-compose &> /dev/null; then
  COMPOSE_CMD="docker-compose"
elif docker compose version &> /dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
else
  echo "Error: Neither docker-compose nor docker compose is available"
  exit 1
fi

# Stop containers
$COMPOSE_CMD -f "$COMPOSE_FILE" --profile ui down $VOLUME_ARGS

echo "Hivemind Milvus stopped."
