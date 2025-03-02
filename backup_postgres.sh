#!/bin/bash
set -euo pipefail
trap 'echo "[ERROR] Script failed at line $LINENO" >&2; exit 1' ERR

# Configuration – override these with environment variables as needed.
BACKUP_DIR="${BACKUP_DIR:-./pgdb_backups}"   # Mounted folder in the container.
PG_USER="${PG_USER:-postgres}"
PG_HOST="${PG_HOST:-192.168.1.188}"
PG_PORT="${PG_PORT:-5432}"
PG_DUMP="${PG_DUMP:-/usr/bin/pg_dump}"
LOG_FILE="${LOG_FILE:-/var/log/pg_backup.log}"
MINIO_BASE_URL="${MINIO_BASE_URL:-http://192.168.1.194:9000/blobs}"  # Ensure this points to your Minio bucket URL.

# (Optional) If a password is required, set it here:
# export PGPASSWORD="${PGPASSWORD:-postgres}"

# Create backup and log directories if they don't exist.
mkdir -p "$BACKUP_DIR"
mkdir -p "$(dirname "$LOG_FILE")"

# Create (or touch) the log file and redirect all output to it.
touch "$LOG_FILE"
exec >> "$LOG_FILE" 2>&1

echo "[$(date)] Starting PostgreSQL backup..."

# Get the list of databases (excluding templates)
databases=$(psql -U "$PG_USER" -h "$PG_HOST" -p "$PG_PORT" -t -c "SELECT datname FROM pg_database WHERE datistemplate = false;")

for db in $databases; do
  echo "[$(date)] Backing up database: $db"
  # Create backup file with name "[database].dump" in custom format (-Fc).
  "$PG_DUMP" -U "$PG_USER" -h "$PG_HOST" -p "$PG_PORT" -Fc "$db" > "$BACKUP_DIR/$db.dump"
  
  echo "[$(date)] Uploading $db.dump to Minio..."
  # Upload the backup file to Minio using HTTP PUT via curl.
  curl -X PUT -T "$BACKUP_DIR/$db.dump" "${MINIO_BASE_URL}/${db}.dump"
  echo "[$(date)] Backup for $db completed and uploaded."
done

echo "[$(date)] PostgreSQL backup process completed."