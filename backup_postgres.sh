#!/bin/bash

# Configuration
BACKUP_DIR="./pgdb_backups"  # This is the mounted folder in the container
DATE=$(date +%Y-%m-%d_%H-%M-%S)
PG_USER="postgres"
PG_HOST="192.168.1.188"
PG_PORT="5432"
PG_DUMP="/usr/bin/pg_dump"
KEEP_DAYS="7"          # How many days of backups to keep
LOG_FILE="/var/log/pg_backup.log"

# If you need a password, either set PGPASSWORD here
# export PGPASSWORD="postgres"

# Create backup directory if it doesn't exist
mkdir -p "$BACKUP_DIR"

echo "[$(date)] Starting PostgreSQL backup..." >> "$LOG_FILE"

# Get the list of DBs (excluding templates)
databases=$(psql -U "$PG_USER" -h "$PG_HOST" -p "$PG_PORT" -t -c "SELECT datname FROM pg_database WHERE datistemplate = false;")

for db in $databases; do
  echo "[$(date)] Backing up database: $db" >> "$LOG_FILE"
  # -Fc => custom format, you can also use -F c for plain text if you prefer
  $PG_DUMP -U "$PG_USER" -h "$PG_HOST" -p "$PG_PORT" -Fc "$db" > "$BACKUP_DIR/$db-$DATE.dump"
done

# (Optional) Remove old backups older than KEEP_DAYS
find "$BACKUP_DIR" -type f -mtime +$KEEP_DAYS -name "*.dump" -exec rm -f {} \;

echo "[$(date)] PostgreSQL backup completed." >> "$LOG_FILE"
