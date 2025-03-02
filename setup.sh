#!/bin/bash
set -euo pipefail
trap 'echo "[ERROR] Script failed at line $LINENO" >&2; exit 1' ERR

##############################################################################
# SUDO USER CREATION (if running as root without a sudo user)
##############################################################################
if [ "$EUID" -eq 0 ] && [ -z "${SUDO_USER:-}" ]; then
    # Use NEW_USER environment variable if provided, otherwise default to "xxxxx"
    NEW_USER=${NEW_USER:-"fadzi"}
    if ! id -u "$NEW_USER" >/dev/null 2>&1; then
        echo "[INFO] Creating new user: $NEW_USER"
        useradd -m "$NEW_USER"
        # Set a default password; you should change this later.
        echo "$NEW_USER:changeme" | chpasswd
        # Add the user to the wheel group for sudo privileges.
        usermod -aG wheel "$NEW_USER"
        # Allow passwordless sudo for the new user.
        echo "$NEW_USER ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/$NEW_USER
    fi
    echo "[INFO] Re-executing script as $NEW_USER..."
    exec sudo -u "$NEW_USER" -i bash "$0" "$@"
fi

##############################################################################
# CONFIGURATION VARIABLES
##############################################################################

# Determine the real home directory for installations.
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
# Blob files (binary artifacts) come from S3/Minio.
export MINIO_BASE_URL="http://192.168.1.194:9000/blobs"
export POSTGRES_DATA_DIR="/var/lib/pgsql/data"
export INITDB_BIN="/usr/bin/initdb"
export PGCTL_BIN="/usr/bin/pg_ctl"
export PG_RESTORE_BIN="/usr/bin/pg_restore"
export PG_MAX_WAIT=30
export PG_DATABASES=${PG_DATABASES:-"superset metabase affine"}

##############################################################################
# LOGGING FUNCTION
##############################################################################

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

##############################################################################
# PRE-INSTALLATION: REPAVE
##############################################################################

if [ "$REPAVE_INSTALLATION" = "true" ]; then
    echo "[INFO] Repave flag detected. Stopping services and removing old installation files..."
    systemctl stop postgresql-13 || true
    systemctl stop redis || true
    rm -rf "$USER_HOME/tools/superset" "$USER_HOME/tools/metabase" "$USER_HOME/tools/affinity-main"
    rm -rf "/var/lib/pgsql/data"
fi

##############################################################################
# CHECK FOR ROOT PRIVILEGES (if still running as root, exit)
##############################################################################
if [ "$EUID" -eq 0 ]; then
    log "FATAL: This script should not be run as root. It must be executed via sudo as the non-root user."
    exit 1
fi

# Change working directory to avoid permission issues for the postgres user.
cd /tmp

##############################################################################
# PACKAGE INSTALLATION (non-PostgreSQL packages)
##############################################################################

log "Installing system packages..."
if ! dnf -y install \
    epel-release \
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
# POSTGRESQL INSTALLATION VIA DNF MODULE
##############################################################################

log "Installing PostgreSQL via dnf modules..."
if ! dnf -y install dnf-plugins-core; then
    log "FATAL: Failed to install dnf-plugins-core. Aborting."
    exit 1
fi

if ! dnf -y module enable PostgreSQL:13; then
    log "FATAL: Failed to enable PostgreSQL:13 module. Aborting."
    exit 1
fi

if ! dnf -y install postgresql-server postgres-contrib; then
    log "FATAL: PostgreSQL package installation failed. Aborting."
    exit 1
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

# Verify postgres user exists.
if ! id -u postgres >/dev/null 2>&1; then
    log "FATAL: postgres user does not exist. Aborting."
    exit 1
fi

##############################################################################
# POSTGRESQL MANAGEMENT FUNCTIONS
##############################################################################

ensure_permissions() {
    mkdir -p "$POSTGRES_DATA_DIR"
    if ! chown postgres:postgres "$POSTGRES_DATA_DIR"; then
        log "FATAL: Failed to set ownership on $POSTGRES_DATA_DIR. Aborting."
        exit 1
    fi
    chmod 700 "$POSTGRES_DATA_DIR"
}

psql_check() {
    sudo -u postgres psql -c "SELECT 1;" &>/dev/null
    return $?
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
# POSTGRESQL SETUP
##############################################################################

log "Configuring PostgreSQL..."
if ! systemctl enable postgresql-13; then
    log "FATAL: Could not enable PostgreSQL service. Aborting."
    exit 1
fi

if ! init_postgres; then
    log "FATAL: PostgreSQL initialization failed. Aborting."
    exit 1
fi

if ! systemctl start postgresql-13; then
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
if ! sed -i "s/^# bind 127.0.0.1 ::1/bind 0.0.0.0/" "$REDIS_CONF_FILE"; then
    log "FATAL: Failed to configure Redis binding. Aborting."
    exit 1
fi
if ! sed -i "s/^protected-mode yes/protected-mode no/" "$REDIS_CONF_FILE"; then
    log "FATAL: Failed to disable Redis protected mode. Aborting."
    exit 1
fi
if ! systemctl enable redis; then
    log "FATAL: Could not enable Redis service. Aborting."
    exit 1
fi
if ! systemctl start redis; then
    log "FATAL: Could not start Redis service. Aborting."
    exit 1
fi

##############################################################################
# NODE.JS ENVIRONMENT SETUP
##############################################################################

log "Configuring Node.js..."
if ! npm install -g yarn; then
    log "FATAL: Failed to install Yarn. Aborting."
    exit 1
fi

##############################################################################
# PYTHON SETUP
##############################################################################

log "Setting up Python..."
if ! python3.11 -m ensurepip --upgrade; then
    log "FATAL: Failed to ensure Python pip. Aborting."
    exit 1
fi
if ! python3.11 -m pip install --upgrade pip; then
    log "FATAL: Failed to upgrade pip. Aborting."
    exit 1
fi
if ! alternatives --set python3 /usr/bin/python3.11; then
    log "FATAL: Failed to set default Python. Aborting."
    exit 1
fi

##############################################################################
# APACHE SUPERSET INSTALLATION & VENV CREATION
##############################################################################

log "Creating Python virtual environment for Superset..."
if [ ! -d "$SUPERSET_HOME/env" ]; then
    python3.11 -m venv "$SUPERSET_HOME/env"
fi

log "Activating virtual environment and installing Apache Superset..."
source "$SUPERSET_HOME/env/bin/activate"
if ! pip install --upgrade pip setuptools wheel; then
    log "FATAL: Failed to upgrade pip/setuptools/wheel in venv. Aborting."
    exit 1
fi
if ! pip install "apache-superset[postgres]==4.1.0rc3"; then
    log "FATAL: Failed to install Apache Superset in venv. Aborting."
    exit 1
fi
deactivate

##############################################################################
# FILE MANAGEMENT: Creating application directories
##############################################################################

log "Creating application directories..."
mkdir -p "$SUPERSET_HOME" "$METABASE_HOME" "$AFFINE_HOME"

##############################################################################
# CONFIGURATION DOWNLOADS
##############################################################################
# Clone the Git repository for text configuration files.
log "Cloning text configuration files from Git repository: $TEXT_FILES_REPO"
if [ -d "$TEXT_FILES_DIR" ]; then
    rm -rf "$TEXT_FILES_DIR"
fi
git clone "$TEXT_FILES_REPO" "$TEXT_FILES_DIR"

log "Copying text configuration files..."
cp "$TEXT_FILES_DIR/our-logs.conf" /etc/logrotate.d/our-logs
cp "$TEXT_FILES_DIR/backup_postgres.sh" /usr/local/bin/backup_postgres.sh
cp "$TEXT_FILES_DIR/superset_config.py" "$SUPERSET_CONFIG_PATH"
cp "$TEXT_FILES_DIR/services.sh" /usr/local/bin/services.sh
chmod +x /usr/local/bin/backup_postgres.sh /usr/local/bin/services.sh

# Download blob files (binary artifacts) from S3/Minio.
declare -A blob_files=(
    ["metabase.jar"]="$METABASE_HOME/metabase.jar"
    ["affine.tar.gz"]="$AFFINE_HOME/affine.tar.gz"
)

log "Downloading blob files from S3/Minio..."
for file in "${!blob_files[@]}"; do
    dest="${blob_files[$file]}"
    url="${MINIO_BASE_URL}/${file}"
    log "Downloading $file from $url"
    if ! wget -q "$url" -O "$dest"; then
        log "FATAL: Failed to download $file from $url. Aborting."
        exit 1
    fi
done

##############################################################################
# AFFiNE SETUP
##############################################################################

log "Deploying AFFiNE..."
if ! tar -xzf "$AFFINE_HOME/affine.tar.gz" -C "$AFFINE_HOME" --strip-components=1; then
    log "FATAL: Failed to extract AFFiNE package. Aborting."
    exit 1
fi
rm -f "$AFFINE_HOME/affine.tar.gz"
if ! chown -R $SUDO_USER:$SUDO_USER "$AFFINE_HOME"; then
    log "FATAL: Failed to set ownership for AFFiNE. Aborting."
    exit 1
fi
find "$AFFINE_HOME" -type d -exec chmod 755 {} \;
find "$AFFINE_HOME" -type f -exec chmod 644 {} \;

##############################################################################
# MAINTENANCE CONFIGURATION
##############################################################################

log "Configuring maintenance jobs..."
if ! chmod +x /usr/local/bin/backup_postgres.sh; then
    log "FATAL: Failed to make backup_postgres.sh executable. Aborting."
    exit 1
fi
if ! chmod +x /usr/local/bin/services.sh; then
    log "FATAL: Failed to make services.sh executable. Aborting."
    exit 1
fi
mkdir -p /var/lib/logs /var/log/redis /mnt/pgdb_backups

echo '0 2 * * * /usr/sbin/logrotate /etc/logrotate.conf' > /etc/cron.d/logrotate
echo '0 3 * * * /usr/local/bin/backup_postgres.sh' > /etc/cron.d/pgbackup

##############################################################################
# INIT SUPERSET
##############################################################################

init_superset() {
    # Ensure Postgres is running
    if ! psql_check; then
        log "ERROR: PostgreSQL is not running; cannot init Superset."
        return 1
    fi

    # Ensure Redis is running
    if ! redis_check; then
        log "ERROR: Redis is not running; cannot init Superset."
        return 1
    fi

    export FLASK_APP=superset
    export SUPERSET_CONFIG_PATH="$SUPERSET_CONFIG"

    ensure_dir "$SUPERSET_LOG_DIR"
    local LOGFILE="$SUPERSET_LOG_DIR/superset_init.log"

    log "Initializing Superset (logging to $LOGFILE)..."

    # 1) Database upgrade
    "$SUPERSET_HOME/env/bin/superset" db upgrade >> "$LOGFILE" 2>&1

    # 2) Create admin user
    "$SUPERSET_HOME/env/bin/superset" fab create-admin \
        --username admin \
        --password admin \
        --firstname Admin \
        --lastname User \
        --email admin@admin.com \
        >> "$LOGFILE" 2>&1

    # 3) Finalize
    "$SUPERSET_HOME/env/bin/superset" init >> "$LOGFILE" 2>&1

    touch "$SUPERSET_HOME/.superset_init_done"

    log "Superset initialization complete."
    return 0
}

start_superset() {
    if ! psql_check; then
        log "ERROR: Postgres is not running; cannot start Superset."
        return 1
    fi
    if ! redis_check; then
        log "ERROR: Redis is not running; cannot start Superset."
        return 1
    fi
    if [ ! -f "$SUPERSET_HOME/.superset_init_done" ]; then
        log "Superset not initialized. Initializing now..."
        init_superset || { log "FATAL: Superset initialization failed."; return 1; }
    fi
    ensure_dir "$SUPERSET_HOME"
    ensure_dir "$SUPERSET_LOG_DIR"
    if ss -tnlp | grep ":$SUPERSET_PORT" &>/dev/null; then
        log "Superset is already running."
        return 0
    fi
    cd "$SUPERSET_HOME" || return 1
    export SUPERSET_HOME="$SUPERSET_HOME"
    log "Starting Superset..."
    nohup "$SUPERSET_HOME/env/bin/superset" run -p "$SUPERSET_PORT" -h 0.0.0.0 --with-threads --reload --debugger \
      > "$SUPERSET_LOG_DIR/superset_log.log" 2>&1 &
    for i in {1..60}; do
        if ss -tnlp | grep ":$SUPERSET_PORT" &>/dev/null; then
            log "Superset started."
            return 0
        fi
        sleep 1
    done
    log "ERROR: Superset failed to start after 60 seconds."
    return 1
}

stop_superset() {
    log "Stopping Superset..."
    pkill -f "superset run"
    sleep 1
    if ss -tnlp | grep ":$SUPERSET_PORT" &>/dev/null; then
        log "ERROR: Superset did not stop."
        return 1
    fi
    log "Superset stopped."
    return 0
}

##############################################################################
# START/STOP ALL
##############################################################################

start_all() {
    log "Starting all services..."
    start_postgres || { log "ERROR: Postgres is required."; return 1; }
    start_redis || { log "ERROR: Redis is required."; return 1; }
    start_metabase || return 1
    start_superset || return 1
    start_affine || return 1
    log "All services started."
    return 0
}

stop_all() {
    log "Stopping all services..."
    stop_superset
    stop_metabase
    stop_affine
    stop_redis
    stop_postgres
    log "All services stopped."
}

##############################################################################
# RESTART
##############################################################################

restart_postgres() {
    stop_postgres
    start_postgres
}

restart_redis() {
    stop_redis
    start_redis
}

restart_affine() {
    stop_affine
    start_affine
}

restart_metabase() {
    stop_metabase
    start_metabase
}

restart_superset() {
    stop_superset
    start_superset
}

restart_all() {
    log "Restarting all services..."
    stop_all
    start_all
}

##############################################################################
# STATUS FUNCTIONS
##############################################################################

status_postgres() {
    if psql_check; then
        log "PostgreSQL is running."
    else
        log "PostgreSQL is NOT running."
    fi
}

status_redis() {
    if pgrep -f "redis-server" &>/dev/null; then
        log "Redis is running."
    else
        log "Redis is NOT running."
    fi
}

status_affine() {
    if ss -tnlp | grep ":$AFFINE_PORT" &>/dev/null; then
        log "AFFiNE is running."
    else
        log "AFFiNE is NOT running."
    fi
}

status_metabase() {
    if ss -tnlp | grep ":$METABASE_PORT" &>/dev/null; then
        log "Metabase is running."
    else
        log "Metabase is NOT running."
    fi
}

status_superset() {
    if ss -tnlp | grep ":$SUPERSET_PORT" &>/dev/null; then
        log "Superset is running."
    else
        log "Superset is NOT running."
    fi
}

status_all() {
    status_postgres
    status_redis
    status_affine
    status_metabase
    status_superset
}

##############################################################################
# MENU
##############################################################################

case "$1" in
    start)
        case "$2" in
            all) start_all ;;
            postgres) start_postgres ;;
            redis) start_redis ;;
            affine) start_affine ;;
            metabase) start_metabase ;;
            superset) start_superset ;;
            *) echo "Usage: $0 start {all|postgres|redis|affine|metabase|superset}" ;;
        esac
        ;;
    stop)
        case "$2" in
            all) stop_all ;;
            postgres) stop_postgres ;;
            redis) stop_redis ;;
            affine) stop_affine ;;
            metabase) stop_metabase ;;
            superset) stop_superset ;;
            *) echo "Usage: $0 stop {all|postgres|redis|affine|metabase|superset}" ;;
        esac
        ;;
    restart)
        case "$2" in
            all) restart_all ;;
            postgres) restart_postgres ;;
            redis) restart_redis ;;
            affine) restart_affine ;;
            metabase) restart_metabase ;;
            superset) restart_superset ;;
            *) echo "Usage: $0 restart {all|postgres|redis|affine|metabase|superset}" ;;
        esac
        ;;
    status)
        case "$2" in
            all) status_all ;;
            postgres) status_postgres ;;
            redis) status_redis ;;
            affine) status_affine ;;
            metabase) status_metabase ;;
            superset) status_superset ;;
            *) echo "Usage: $0 status {all|postgres|redis|affine|metabase|superset}" ;;
        esac
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status} {service|all}"
        ;;
esac
