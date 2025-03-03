#!/bin/bash
set -uo pipefail
trap 'echo "[ERROR] Script failed at line $LINENO" >&2' ERR

BACKUP_DIR="${BACKUP_DIR:-./pgdb_backups}"
PG_USER="${PG_USER:-postgres}"
PG_HOST="${PG_HOST:-localhost}"
PG_PORT="${PG_PORT:-5432}"
PG_DUMP="${PG_DUMP:-/usr/bin/pg_dump}"
LOG_FILE="${LOG_FILE:-/var/log/pg_backup.log}"
MINIO_BASE_URL="${MINIO_BASE_URL:-http://192.168.1.194:9000/blobs}"
PGPASSWORD="${PGPASSWORD:-postgres}"

mkdir -p "$BACKUP_DIR" || echo "[WARNING] Failed to create backup directory: $BACKUP_DIR" >&2
mkdir -p "$(dirname "$LOG_FILE")" || echo "[WARNING] Failed to create log directory: $(dirname "$LOG_FILE")" >&2

touch "$LOG_FILE" || echo "[WARNING] Failed to create log file: $LOG_FILE" >&2
exec >> "$LOG_FILE" 2>&1

echo "[$(date)] Starting PostgreSQL backup..."

databases=$(psql -U "$PG_USER" -h "$PG_HOST" -p "$PG_PORT" -t -c "SELECT datname FROM pg_database WHERE datistemplate = false;" 2>&1) || {
  echo "[ERROR] Failed to retrieve database list. Skipping backup process." >&2
  exit 1
}

for db in $databases; do
  echo "[$(date)] Backing up database: $db"
  "$PG_DUMP" -U "$PG_USER" -h "$PG_HOST" -p "$PG_PORT" -Fc "$db" > "$BACKUP_DIR/$db.dump" 2>&1 || {
    echo "[ERROR] Failed to back up database: $db. Skipping to the next database." >&2
    continue
  }

  echo "[$(date)] Uploading $db.dump to Minio..."
  curl -X PUT -T "$BACKUP_DIR/$db.dump" "${MINIO_BASE_URL}/${db}.dump" 2>&1 || {
    echo "[ERROR] Failed to upload $db.dump to Minio. Skipping to the next database." >&2
    continue
  }
  echo "[$(date)] Backup for $db completed and uploaded."
done

echo "[$(date)] PostgreSQL backup process completed."
