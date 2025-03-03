#!/bin/bash

DB_CONFIGS=("affine:affine" "mydb:postgres" "analytics:analytics")

export PG_RESTORE_BIN="/usr/bin/pg_restore"
export MINIO_BASE_URL="http://localhost:9000/blobs"

export PGHOST="localhost"
export PGPORT="5432"
export PGUSER="postgres"
export PGDATABASE="postgres"

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

    if ! sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname = '$db'" | grep -q 1; then
        sudo -u postgres psql -c "CREATE DATABASE $db WITH OWNER $owner;"
        log "Created database: $db with owner: $owner"
    else
        log "Database $db already exists"
    fi

    restore_backup "$db"
done
