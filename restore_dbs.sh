#!/usr/bin/env bash
set -eo pipefail

# Force TCP connections only
export PGHOST=localhost
export PGPORT=5432
export PGUSER=postgres
export PGDATABASE=postgres

# Environment Configuration
export POSTGRES_DATA_DIR="${POSTGRES_DATA_DIR:-/var/lib/pgsql/data}"
export PG_RESTORE_BIN="${PG_RESTORE_BIN:-/usr/bin/pg_restore}"
export MINIO_BASE_URL="${MINIO_BASE_URL:-http://localhost:9000/blobs}"
export DB_CONFIGS="${DB_CONFIGS:-prefect:postgres,gitlab-usage:postgres}"

# Security Check
if [[ $EUID -ne 0 ]]; then
  echo "This script requires root privileges" >&2
  exit 1
fi

# Simple logging
log() {
  printf "%(%Y-%m-%d %H:%M:%S)T - %s\n" -1 "$*" >&2
}

# Direct TCP connection test
verify_postgres_connection() {
  if ! psql -c "SELECT 1" >/dev/null; then
    log "FATAL: Cannot connect to PostgreSQL via TCP at ${PGHOST}:${PGPORT}"
    log "Check: 1) PG server running 2) listen_addresses in postgresql.conf"
    exit 1
  fi
}

# Single-attempt download
download_backup() {
  local db=$1
  local backup_file="${db}.dump"
  local backup_url="${MINIO_BASE_URL}/${backup_file}"
  local backup_path="/tmp/${backup_file}"

  log "Downloading ${db} backup from ${backup_url}"
  if ! curl -fsSL -o "$backup_path" "$backup_url"; then
    log "ERROR: Download failed for ${db} (curl error $?)"
    return 1
  fi

  # Validate backup
  if ! head -c5 "$backup_path" | grep -q "PGDMP"; then
    log "ERROR: Invalid backup header for ${db}"
    return 1
  fi

  echo "$backup_path"
}

# Database operations
terminate_connections() {
  local db=$1
  psql <<-SQL
    SELECT pg_terminate_backend(pid)
    FROM pg_stat_activity
    WHERE datname = '${db}' AND pid <> pg_backend_pid();
SQL
}

recreate_database() {
  local db=$1 owner=$2
  psql <<-SQL
    DROP DATABASE IF EXISTS "${db}";
    CREATE DATABASE "${db}" WITH OWNER ${owner};
SQL
}

# Main execution
verify_postgres_connection
cd "${POSTGRES_DATA_DIR}" || exit 1

IFS=',' read -ra databases <<< "${DB_CONFIGS}"
for config in "${databases[@]}"; do
  IFS=':' read -r db owner <<< "$config"
  log "Processing ${db} (owner: ${owner})"

  if ! backup_path=$(download_backup "$db"); then
    log "Skipping ${db} due to download failure"
    continue
  fi

  terminate_connections "$db" || continue
  recreate_database "$db" "$owner" || continue

  log "Restoring ${db}"
  if ! "${PG_RESTORE_BIN}" -d "$db" "$backup_path"; then
    log "Restoration failed for ${db}"
    continue
  fi

  rm -f "$backup_path"
  log "Successfully restored ${db}"
done

log "Script completed"
