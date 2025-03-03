#!/bin/bash

POSTGRES_DATA_DIR="/var/lib/pgsql/data"
DB_CONFIGS=("my-db:postgres" "analytics:analytics")

export PG_RESTORE_BIN="/usr/bin/pg_restore"
export MINIO_BASE_URL="http://localhost:9000/blobs"
export PGHOST="localhost"
export PGPORT="5432"
export PGUSER="postgres"
export PGDATABASE="postgres"
cd "${POSTGRES_DATA_DIR}" || { echo "Failed to cd to ${POSTGRES_DATA_DIR}"; exit 1; }

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

restore_backup() {
    local db=$1
    local backup_file="${db}.dump"
    local backup_url="${MINIO_BASE_URL}/${backup_file}"
    local backup_path="/tmp/${backup_file}"
    log "Downloading ${db} backup from Minio: ${backup_url}"
    if ! wget -q "${backup_url}" -O "$backup_path"; then
        log "FATAL: No backup found for ${db} at URL: ${backup_url}. Aborting."
        exit 1
    fi
    log "Restoring ${db} database..."
    if ! sudo -u postgres "$PG_RESTORE_BIN" -d "$db" "$backup_path"; then
        log "FATAL: Error restoring ${db} database. Aborting."
        exit 1
    fi
    rm -f "$backup_path"
}

for config in "${DB_CONFIGS[@]}"; do
    IFS=":" read -r db owner <<< "$config"
    log "Replacing database: $db"
    sudo -u postgres psql -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$db' AND pid <> pg_backend_pid();"
    sudo -u postgres psql -c "DROP DATABASE IF EXISTS \"$db\";"
    sudo -u postgres psql -c "CREATE DATABASE \"$db\" WITH OWNER $owner;"
    log "Created database: $db with owner: $owner"
    restore_backup "$db"
done
