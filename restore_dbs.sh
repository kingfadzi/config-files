#!/usr/bin/env bash
set -eo pipefail
shopt -s inherit_errexit

# Environment Configuration
export POSTGRES_DATA_DIR="${POSTGRES_DATA_DIR:-/var/lib/pgsql/data}"
export PG_RESTORE_BIN="${PG_RESTORE_BIN:-/usr/bin/pg_restore}"
export MINIO_BASE_URL="${MINIO_BASE_URL:-http://192.168.1.194:9000/blobs}"
export DB_CONFIGS="${DB_CONFIGS:-gitlab-usage:postgres,prefect:prefect}"
export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-postgres}"
export MAX_RETRIES=2
export CURL_TIMEOUT=30

# Security Check
if [[ $EUID -ne 0 ]]; then
  echo "🔒 This script requires root privileges" >&2
  exit 1
fi

# Initialize logging
exec 3>&2
log() {
  local level=$1
  shift
  printf "%(%Y-%m-%d %H:%M:%S)T - %-8s - %s\n" -1 "$level" "$*" >&3
}

# Cleanup temporary files
cleanup() {
  local status=$?
  trap - EXIT ERR
  log "INFO" "Starting cleanup process"

  if [[ -n "${backup_path:-}" && -f "$backup_path" ]]; then
    rm -f "$backup_path" || log "WARNING" "Failed to remove ${backup_path}"
  fi

  exit $status
}
trap cleanup EXIT ERR

# Enhanced download function with retries
download_backup() {
  local db=$1
  local backup_file="${db}.dump"
  local backup_url="${MINIO_BASE_URL}/${backup_file}"
  local backup_path retry=0

  backup_path=$(mktemp "/tmp/${db}-XXXXXX.dump")
  log "INFO" "Downloading ${db} backup to ${backup_path}"

  while (( retry <= MAX_RETRIES )); do
    local http_code curl_output
    curl_output=$(curl -fSL \
      --write-out '%{http_code}' \
      --max-time "$CURL_TIMEOUT" \
      -o "$backup_path" \
      "$backup_url" 2>&1) || true

    http_code="${curl_output##*$'\n'}"
    curl_message="${curl_output%$'\n'*}"

    if [[ $http_code -eq 200 ]]; then
      # Validate backup integrity
      if ! head -c5 "$backup_path" | grep -q "PGDMP"; then
        log "ERROR" "Invalid backup header in ${backup_file}"
        return 1
      fi

      log "DEBUG" "Download validation passed for ${db}"
      echo "$backup_path"
      return 0
    fi

    log "WARNING" "Download attempt $((retry+1)) failed (HTTP ${http_code}): ${curl_message}"
    ((retry++)) || true
    sleep $((retry * 2))
  done

  log "ERROR" "Max download retries (${MAX_RETRIES}) exceeded for ${db}"
  return 1
}

# Database Management Functions
terminate_connections() {
  local db=$1
  log "INFO" "Terminating active connections to ${db}"

  if ! sudo -u postgres psql -v ON_ERROR_STOP=1 <<EOF
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = '${db}' AND pid <> pg_backend_pid();
EOF
  then
    log "ERROR" "Connection termination failed for ${db}"
    return 1
  fi
}


recreate_database() {
  local db=$1 owner=$2
  log "INFO" "Recreating database ${db} with owner ${owner}"

  sudo -u postgres psql -v ON_ERROR_STOP=1 <<-EOSQL
    DROP DATABASE IF EXISTS "${db}";
    CREATE DATABASE "${db}" WITH OWNER ${owner};
EOSQL
}

# Main Execution Flow
cd "${POSTGRES_DATA_DIR}" || {
  log "ERROR" "Failed to access ${POSTGRES_DATA_DIR}"
  exit 1
}

IFS=',' read -ra databases <<< "${DB_CONFIGS}"
for config in "${databases[@]}"; do
  IFS=':' read -r db owner <<< "$config"
  backup_path=""

  log "INFO" "Processing database: ${db} (owner: ${owner})"

  if ! backup_path=$(download_backup "$db"); then
    log "ERROR" "Backup acquisition failed for ${db}"
    continue
  fi

  if ! terminate_connections "$db"; then
    continue
  fi

  if ! recreate_database "$db" "$owner"; then
    log "ERROR" "Database recreation failed for ${db}"
    continue
  fi

  log "INFO" "Restoring ${db} from ${backup_path}"
  if ! sudo -u postgres "$PG_RESTORE_BIN" -d "$db" "$backup_path"; then
    log "ERROR" "Restoration failed for ${db}"
    continue
  fi

  log "SUCCESS" "Completed restoration of ${db}"
done

log "INFO" "All database operations completed"
