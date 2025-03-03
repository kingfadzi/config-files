#!/bin/bash
set -uo pipefail
trap 'echo "[ERROR] Script failed at line $LINENO" >&2' ERR

BACKUP_DIR="${BACKUP_DIR:-./pgdb_backups}"
PG_USER="${PG_USER:-postgres}"
PG_HOST="${PG_HOST:-192.168.1.188}"
PG_PORT="${PG_PORT:-5422}"
PG_DUMP="${PG_DUMP:-/usr/bin/pg_dump}"
LOG_FILE="${LOG_FILE:-/tmp/pg_backup.log}"
MINIO_BASE_URL="${MINIO_BASE_URL:-http://192.168.1.194:9000/blobs}"
PGPASSWORD="${PGPASSWORD:-password}"
export PGPASSWORD

mkdir -p "$BACKUP_DIR" || echo "[WARNING] Failed to create backup directory: $BACKUP_DIR" | tee -a "$LOG_FILE" >&2
mkdir -p "$(dirname "$LOG_FILE")" || echo "[WARNING] Failed to create log directory: $(dirname "$LOG_FILE")" | tee -a "$LOG_FILE" >&2

touch "$LOG_FILE" || echo "[WARNING] Failed to create log file: $LOG_FILE" | tee -a "$LOG_FILE" >&2

# Function to log messages to both stdout and the log file
log() {
  echo "$1" | tee -a "$LOG_FILE"
}

log "[$(date)] Starting PostgreSQL backup..."

databases=$(psql -U "$PG_USER" -h "$PG_HOST" -p "$PG_PORT" -t -c "SELECT datname FROM pg_database WHERE datistemplate = false;" 2>/dev/null)
if [ $? -ne 0 ]; then
  log "[ERROR] Failed to retrieve database list. Error: $databases"
  exit 1
fi

for db in $databases; do
  if [[ "$db" =~ ^[a-zA-Z0-9_\-]+$ ]]; then
    log "[$(date)] Backing up database: $db"
    "$PG_DUMP" -U "$PG_USER" -h "$PG_HOST" -p "$PG_PORT" -Fc "$db" > "$BACKUP_DIR/$db.dump" 2>&1 || {
      log "[ERROR] Failed to back up database: $db. Skipping to the next database."
      continue
    }

    log "[$(date)] Uploading $db.dump to Minio..."
    curl -X PUT -T "$BACKUP_DIR/$db.dump" "${MINIO_BASE_URL}/${db}.dump" 2>&1 || {
      log "[ERROR] Failed to upload $db.dump to Minio. Skipping to the next database."
      continue
    }
    log "[$(date)] Backup for $db completed and uploaded."
  else
    log "[WARNING] Skipping invalid database name: $db"
  fi
done

log "[$(date)] PostgreSQL backup process completed."
