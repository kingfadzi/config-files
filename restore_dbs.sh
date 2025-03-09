#!/bin/bash
set -o pipefail
# Uncomment the next line for shell debugging:
# set -x

if [ "$EUID" -ne 0 ]; then
  echo "This script must be run as root (via sudo)" >&2
  exit 1
fi

export POSTGRES_DATA_DIR="${POSTGRES_DATA_DIR:-/var/lib/pgsql/data}"
export PG_RESTORE_BIN="${PG_RESTORE_BIN:-/usr/bin/pg_restore}"
export MINIO_BASE_URL="${MINIO_BASE_URL:-http://localhost:9000/blobs}"
export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-postgres}"
export PGDATABASE="${PGDATABASE:-postgres}"

if [ -z "${DB_CONFIGS+x}" ]; then
    DB_CONFIGS=("my-db:postgres" "analytics:analytics")
else
    IFS=',' read -ra DB_CONFIGS <<< "$DB_CONFIGS"
fi

cd "${POSTGRES_DATA_DIR}" || { echo "Failed to cd to ${POSTGRES_DATA_DIR}"; exit 1; }

log() {
    # Immediately flush output by redirecting to stderr (which is usually unbuffered)
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

download_backup() {
    local db=$1
    local backup_file="${db}.dump"
    local backup_url="${MINIO_BASE_URL}/${backup_file}"
    local backup_path="/tmp/${backup_file}"
    log "DEBUG: Entered download_backup for ${db}"  # Debug marker
    log "Attempting to download ${db} backup from URL: ${backup_url}"
    local wget_output
    # Remove the quiet flag so we capture all output; use --no-verbose to avoid progress bar noise.
    wget_output=$(wget --no-verbose "${backup_url}" -O "$backup_path" 2>&1)
    local ret=$?
    if [ $ret -ne 0 ]; then
        log "ERROR: Failed to download backup for ${db} from URL: ${backup_url}. wget error: ${wget_output}"
        return 1
    fi
    log "Successfully downloaded backup for ${db} to ${backup_path}"
    echo "$backup_path"
}

for config in "${DB_CONFIGS[@]}"; do
    IFS=":" read -r db owner <<< "$config"
    log "Processing database: ${db} with owner: ${owner}"

    backup_path=$(download_backup "$db")
    if [ $? -ne 0 ] || [ -z "$backup_path" ]; then
         log "Skipping ${db} due to backup download failure."
         continue
    fi

    log "Replacing database: $db"

    if ! sudo -u postgres psql -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$db' AND pid <> pg_backend_pid();"; then
        log "ERROR: Failed to terminate connections for ${db}. Skipping ${db}."
        rm -f "$backup_path"
        continue
    fi

    if ! sudo -u postgres psql -c "DROP DATABASE IF EXISTS \"$db\";"; then
        log "ERROR: Failed to drop database ${db}. Skipping ${db}."
        rm -f "$backup_path"
        continue
    fi

    if ! sudo -u postgres psql -c "CREATE DATABASE \"$db\" WITH OWNER $owner;"; then
        log "ERROR: Failed to create database ${db} with owner ${owner}. Skipping ${db}."
        rm -f "$backup_path"
        continue
    fi
    log "Created database: $db with owner: $owner"

    log "Restoring ${db} database..."
    if ! sudo -u postgres "$PG_RESTORE_BIN" -d "$db" "$backup_path"; then
        log "ERROR: Failed to restore ${db} from backup file ${backup_path}. Skipping ${db}."
        rm -f "$backup_path"
        continue
    fi
    log "Successfully restored ${db} database."
    rm -f "$backup_path"
done
