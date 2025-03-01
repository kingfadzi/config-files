#!/bin/bash
set -e

IMAGE_NAME="dev-environment"
CONTAINER_NAME="dev-environment"

usage() {
  echo "Usage: $0 <POSTGRES_DATA_DIR> <POSTGRES_BACKUPS_DIR>"
  echo "Example: $0 /home/fadzi/tools/dev-environment/postgres_data /home/fadzi/tools/dev-environment/postgres_backups"
  echo "Both arguments are required, and the specified directories must already exist."
  exit 1
}

if [ $# -ne 2 ]; then
  echo "ERROR: You must specify exactly two directories (data + backups)."
  usage
fi

HOST_POSTGRES_DATA_DIR="$1"
HOST_POSTGRES_BACKUPS_DIR="$2"

CONTAINER_POSTGRES_DATA_DIR="/var/lib/pgsql/13/data"
CONTAINER_POSTGRES_BACKUPS_DIR="/mnt/pgdb_backups"

echo "Using host Postgres data dir: $HOST_POSTGRES_DATA_DIR"
echo "Using host Postgres backups dir: $HOST_POSTGRES_BACKUPS_DIR"

if [ ! -d "$HOST_POSTGRES_DATA_DIR" ]; then
  echo "ERROR: Directory '$HOST_POSTGRES_DATA_DIR' does not exist."
  usage
fi

if [ ! -d "$HOST_POSTGRES_BACKUPS_DIR" ]; then
  echo "ERROR: Directory '$HOST_POSTGRES_BACKUPS_DIR' does not exist."
  usage
fi

# Build the Docker image
docker build -t "$IMAGE_NAME" .

# If a container by this name exists, remove it
EXISTING_CONTAINER_ID="$(docker ps -aq -f name="$CONTAINER_NAME" 2>/dev/null || true)"

if [ -n "$EXISTING_CONTAINER_ID" ]; then
  echo "A container named '$CONTAINER_NAME' already exists. Removing it..."
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
fi

# Run the new container
docker run -d \
  --name "$CONTAINER_NAME" \
  -p 5432:5432 \
  -p 6370:6379 \
  -p 3000:3000 \
  -p 3010:3010 \
  -p 8099:8099 \
  -p 8888:8088 \
  -v "$HOST_POSTGRES_DATA_DIR":"$CONTAINER_POSTGRES_DATA_DIR" \
  -v "$HOST_POSTGRES_BACKUPS_DIR":"$CONTAINER_POSTGRES_BACKUPS_DIR" \
  "$IMAGE_NAME" \
  tail -f /dev/null

echo "Container '$CONTAINER_NAME' started with volumes mounted."
