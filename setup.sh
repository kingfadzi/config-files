#!/bin/bash
set -euo pipefail
trap 'echo "[ERROR] Script failed at line $LINENO" >&2; exit 1' ERR

##############################################################################
# SUDO CHECK
##############################################################################
if [ -z "${SUDO_USER:-}" ]; then
    echo "[ERROR] This script must be run using sudo." >&2
    exit 1
fi

##############################################################################
# CONFIGURATION VARIABLES
##############################################################################

USE_PGDG=false

# Determine the real home directory to use for installations.
USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)

# Default repave the installation to true.
REPAVE_INSTALLATION=${REPAVE_INSTALLATION:-true}

# Git repository for text configuration files.
TEXT_FILES_REPO="https://github.com/kingfadzi/config-files.git"
# Temporary directory to clone the repository.
TEXT_FILES_DIR="/tmp/config-files"

# Declare Redis configuration file variable.
REDIS_CONF_FILE="/etc/redis.conf"

##############################################################################
# ENVIRONMENT CONFIGURATION
##############################################################################

export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
export PYTHONUNBUFFERED=1
export SUPERSET_HOME="$USER_HOME/tools/superset"
export SUPERSET_CONFIG_PATH="$SUPERSET_HOME/superset_config.py"
export METABASE_HOME="$USER_HOME/tools/metabase"
export AFFINE_HOME="$USER_HOME/tools/affinity-main"
# Blob files (binary artifacts) still come from S3/Minio.
export MINIO_BASE_URL="http://192.168.1.194:9000/blobs"
export POSTGRES_DATA_DIR="/var/lib/pgsql/13/data"
export INITDB_BIN="/usr/pgsql-13/bin/initdb"
export PGCTL_BIN="/usr/pgsql-13/bin/pg_ctl"
export PG_RESTORE_BIN="/usr/pgsql-13/bin/pg_restore"
export PG_MAX_WAIT=30
export PG_DATABASES=${PG_DATABASES:-"superset metabase affine"}

##############################################################################
# LOGGING FUNCTION
##############################################################################

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

##############################################################################
# FUNCTION TO STOP POSTGRESQL
##############################################################################

stop_postgresql() {
    if [ -f "$POSTGRES_DATA_DIR/postmaster.pid" ]; then
        log "Stopping PostgreSQL..."
        if ! sudo -u postgres "$PGCTL_BIN" -D "$POSTGRES_DATA_DIR" stop; then
            log "WARNING: Failed to stop PostgreSQL. Attempting to kill the process..."
            pkill -u postgres -f "postgres:"
        fi
    else
        log "PostgreSQL is not running."
    fi
}

##############################################################################
# FUNCTION TO ENSURE PERMISSIONS
##############################################################################

ensure_permissions() {
    mkdir -p "$POSTGRES_DATA_DIR"
    if ! chown postgres:postgres "$POSTGRES_DATA_DIR"; then
        log "FATAL: Failed to set ownership on $POSTGRES_DATA_DIR. Aborting."
        exit 1
    fi
    chmod 700 "$POSTGRES_DATA_DIR"
}

##############################################################################
# FUNCTION TO CHECK PSQL CONNECTION
##############################################################################

psql_check() {
    sudo -u postgres psql -c "SELECT 1;" &>/dev/null
    return $?
}

##############################################################################
# FUNCTION TO RESTORE DATABASE BACKUP
##############################################################################

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

##############################################################################
# FUNCTION TO INITIALIZE POSTGRESQL
##############################################################################

init_postgres() {
    ensure_permissions
    if [ -f "$POSTGRES_DATA_DIR/PG_VERSION" ]; then
        log "PostgreSQL already initialized"
        return 0
    fi

    log "Initializing PostgreSQL cluster..."
    if ! sudo -u postgres "$INITDB_BIN" -D "$POSTGRES_DATA_DIR"; then
        log "FATAL: Failed to initialize PostgreSQL cluster. Aborting."
        exit 1
    fi

    log "Configuring network access..."
    if ! sudo -u postgres sed -i "s/^#listen_addresses = 'localhost'/listen_addresses = '*'/" "$POSTGRES_DATA_DIR/postgresql.conf"; then
        log "FATAL: Failed to configure postgresql.conf. Aborting."
        exit 1
    fi
    echo "host all all 0.0.0.0/0 md5" | sudo -u postgres tee -a "$POSTGRES_DATA_DIR/pg_hba.conf" >/dev/null

    log "Starting temporary PostgreSQL instance..."
    if ! sudo -u postgres "$PGCTL_BIN" -D "$POSTGRES_DATA_DIR" start -l "$POSTGRES_DATA_DIR/postgres_init.log"; then
        log "FATAL: Failed to start temporary PostgreSQL instance. Aborting."
        exit 1
    fi

    local init_ok=false
    for i in $(seq 1 $PG_MAX_WAIT); do
        if psql_check; then
            log "Securing PostgreSQL user..."
            sudo -u postgres psql -c "ALTER USER postgres WITH PASSWORD 'postgres';"

            log "Creating databases..."
            for db in $PG_DATABASES; do
                if ! sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname = '$db'" | grep -q 1; then
                    sudo -u postgres psql -c "CREATE DATABASE $db WITH OWNER postgres;"
                    log "Created database: $db"
                fi
                restore_backup "$db"
            done
            init_ok=true
            break
        fi
        sleep 1
    done

    if [ "$init_ok" = false ]; then
        log "FATAL: PostgreSQL initialization failed. Aborting."
        sudo -u postgres "$PGCTL_BIN" -D "$POSTGRES_DATA_DIR" stop &>/dev/null
        exit 1
    fi

    log "Stopping initialization instance..."
    sudo -u postgres "$PGCTL_BIN" -D "$POSTGRES_DATA_DIR" stop
    sleep 2
}

##############################################################################
# PRE-INSTALLATION: REPAVE
##############################################################################

if [ "$REPAVE_INSTALLATION" = "true" ]; then
    echo "[INFO] Repave flag detected (default=true). Stopping services and removing old installation files..."
    stop_postgresql
    stop_redis  # Stop Redis if running
    rm -rf "$USER_HOME/tools/superset" "$USER_HOME/tools/metabase" "$USER_HOME/tools/affinity-main"
    rm -rf "$POSTGRES_DATA_DIR"
fi

##############################################################################
# CHECK FOR ROOT PRIVILEGES
##############################################################################

if [ "$EUID" -ne 0 ]; then
    log "FATAL: This script must be run as root (use sudo)"
    exit 1
fi

# Change working directory to avoid permission issues for the postgres user.
cd /tmp

##############################################################################
# PACKAGE INSTALLATION (non-PostgreSQL packages)
##############################################################################

log "Installing system packages..."
if ! dnf -y install --disablerepo=epel \
    wget \
    git \
    curl \
    gcc \
    gcc-c++ \
    make \
    zlib-devel \
    bzip2 \
    readline-devel \
    openssl-devel \
    libffi-devel \
    xz-devel \
    tar \
    java-21-openjdk \
    cronie \
    logrotate \
    sudo \
    iproute \
    redis \
    python3.11 \
    python3.11-devel \
    nodejs; then
    log "FATAL: Package installation failed. Aborting."
    exit 1
fi

##############################################################################
# POSTGRESQL INSTALLATION VIA PGDG REPOSITORY
##############################################################################

log "Updating system and installing dnf-plugins-core..."
dnf -y update --disablerepo=epel || { log "FATAL: dnf update failed. Aborting."; exit 1; }
dnf -y install dnf-plugins-core --disablerepo=epel || { log "FATAL: Failed to install dnf-plugins-core. Aborting."; exit 1; }

if [ "$USE_PGDG" = "true" ]; then
    log "Using PGDG repository for PostgreSQL installation."
    if ! dnf -y install https://download.postgresql.org/pub/repos/yum/reporpms/EL-8-x86_64/pgdg-redhat-repo-latest.noarch.rpm; then
        log "FATAL: Failed to install PGDG repository RPM. Aborting."
        exit 1
    fi
    if ! dnf -qy module disable postgresql; then
        log "WARNING: Failed to disable default PostgreSQL module. Continuing..."
    fi
    if ! dnf -y install postgresql13 postgresql13-server postgresql13-contrib; then
        log "FATAL: PostgreSQL package installation via PGDG repository failed. Aborting."
        exit 1
    fi
    # Set environment variables for PGDG installation
    export POSTGRES_DATA_DIR="/var/lib/pgsql/13/data"
    export INITDB_BIN="/usr/pgsql-13/bin/initdb"
    export PGCTL_BIN="/usr/pgsql-13/bin/pg_ctl"
    export PG_RESTORE_BIN="/usr/pgsql-13/bin/pg_restore"
else
    log "Using default PostgreSQL modules installation via dnf for PostgreSQL 13."
    # This single command enables the PostgreSQL 13 server module and installs the packages.
    if ! dnf -y module install postgresql:13/server; then
        log "FATAL: PostgreSQL 13 module installation failed. Aborting."
        exit 1
    fi
    # Set environment variables for the default installation.
    export POSTGRES_DATA_DIR="/var/lib/pgsql/data"
    export INITDB_BIN="/usr/bin/initdb"
    export PGCTL_BIN="/usr/bin/pg_ctl"
    export PG_RESTORE_BIN="/usr/bin/pg_restore"
fi

if ! dnf clean all; then
    log "FATAL: dnf clean all failed. Aborting."
    exit 1
fi

# Verify postgres user exists.
if ! id -u postgres >/dev/null 2>&1; then
    log "FATAL: postgres user does not exist. Aborting."
    exit 1
fi

##############################################################################
# POSTGRESQL SETUP
##############################################################################

log "Configuring PostgreSQL..."
stop_postgresql

if ! init_postgres; then
    log "FATAL: PostgreSQL initialization failed. Aborting."
    exit 1
fi

log "Starting PostgreSQL..."
if ! sudo -u postgres "$PGCTL_BIN" -D "$POSTGRES_DATA_DIR" start; then
    log "FATAL: Could not start PostgreSQL service. Aborting."
    exit 1
fi

log "Verifying PostgreSQL is listening on 0.0.0.0:5432..."
if ! ss -tnlp | grep -q '0.0.0.0:5432'; then
    log "FATAL: PostgreSQL is not listening on 0.0.0.0:5432. Aborting."
    exit 1
fi
log "PostgreSQL is confirmed to be listening on 0.0.0.0:5432."

##############################################################################
# REDIS CONFIGURATION
##############################################################################

log "Setting up Redis..."
stop_redis  # Stop Redis if running
if ! sed -i "s/^# bind 127.0.0.1 ::1/bind 0.0.0.0/" "$REDIS_CONF_FILE"; then
    log "FATAL: Failed to configure Redis binding. Aborting."
    exit 1
fi
if ! sed -i "s/^protected-mode yes/protected-mode no/" "$REDIS_CONF_FILE"; then
    log "FATAL: Failed to disable Redis protected mode. Aborting."
    exit 1
fi

# Ensure Redis log directory exists and has proper permissions
sudo mkdir -p /var/log/redis
sudo chown redis:redis /var/log/redis

log "Starting Redis..."
if ! redis-server "$REDIS_CONF_FILE" &>/var/log/redis/redis.log & then
    log "FATAL: Could not start Redis service. Aborting."
    log "Check Redis logs at /var/log/redis/redis.log for more details."
    exit 1
fi

# Verify Redis is running
sleep 2  # Give Redis time to start
if ! pgrep redis-server >/dev/null; then
    log "FATAL: Redis failed to start. Aborting."
    log "Check Redis logs at /var/log/redis/redis.log for more details."
    exit 1
fi

log "Redis is running."

##############################################################################
# FUNCTION TO STOP REDIS
##############################################################################

stop_redis() {
    if pgrep redis-server >/dev/null; then
        log "Stopping Redis..."
        pkill redis-server || { log "WARNING: Failed to stop Redis. Attempting to kill forcefully..."; pkill -9 redis-server; }
    else
        log "Redis is not running."
    fi
}

##############################################################################
# FINALIZATION
##############################################################################

log "Provisioning complete!"
echo "=================================================="
echo "Service Summary:"
echo "- PostgreSQL: 5432 (Databases: $PG_DATABASES)"
echo "- Redis: 6379"
echo "- Superset: 8099"
echo "- AFFiNE: $AFFINE_HOME"
echo "=================================================="
echo "Post-Installation Steps:"
echo "1. To initialize Superset (if not already done), run:"
echo "   sudo /usr/local/bin/services.sh start superset"
echo "2. Start Metabase with:"
echo "   java -jar $METABASE_HOME/metabase.jar"
echo "3. Verify backups with:"
echo "   ls -l /mnt/pgdb_backups"
