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

USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
REPAVE_INSTALLATION=${REPAVE_INSTALLATION:-true}
TEXT_FILES_REPO="https://github.com/kingfadzi/config-files.git"
MINIO_BASE_URL="http://192.168.1.194:9000/blobs"

##############################################################################
# ENVIRONMENT CONFIGURATION
##############################################################################

export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
export PYTHONUNBUFFERED=1
export SUPERSET_HOME="$USER_HOME/.superset"
export SUPERSET_CONFIG_PATH="$SUPERSET_HOME/superset_config.py"
export METABASE_HOME="$USER_HOME/.metabase"
export AFFINE_HOME="$USER_HOME/.affinity-main"
export TEXT_FILES_DIR="/tmp/config-files"
export REDIS_CONF_FILE="/etc/redis.conf"
export POSTGRES_DATA_DIR="/var/lib/pgsql/data"
export INITDB_BIN="/usr/bin/initdb"
export PGCTL_BIN="/usr/bin/pg_ctl"
export PG_RESTORE_BIN="/usr/bin/pg_restore"
export PG_MAX_WAIT=30
export PG_DATABASES=${PG_DATABASES:-"superset metabase affine"}
export LD_LIBRARY_PATH="/usr/pgsql-13/lib:${LD_LIBRARY_PATH:-}"

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
# FUNCTION TO STOP REDIS
##############################################################################

stop_redis() {
    log "Force-stopping Redis with SIGKILL..."
    pkill -9 -f "redis-server" || true
    sleep 0.5

    if pgrep -f "redis-server" &>/dev/null; then
        log "ERROR: Redis still running after SIGKILL!"
        return 1
    else
        log "Redis terminated forcefully."
        return 0
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
    if ! sudo -u postgres bash -c "cd ${POSTGRES_DATA_DIR} && exec ${PGCTL_BIN} -D ${POSTGRES_DATA_DIR} start -l ${POSTGRES_LOG_DIR}/postgres.log"; then
        log "FATAL: Failed to start temporary PostgreSQL instance. Aborting."
        exit 1
    fi

    local init_ok=false
      for i in $(seq 1 $PG_MAX_WAIT); do
          if psql_check; then
              log "Securing PostgreSQL user..."
              sudo -u postgres psql -c "ALTER USER postgres WITH PASSWORD 'postgres';"

              log "Ensuring affine user exists..."
              if ! sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname = 'affine'" | grep -q 1; then
                  sudo -u postgres psql -c "CREATE USER affine WITH PASSWORD 'affine';"
                  log "Created user: affine"
              else
                  log "User affine already exists"
              fi

              log "Creating databases..."
              for db in $PG_DATABASES; do
                  if ! sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname = '$db'" | grep -q 1; then
                      if [ "$db" = "affine" ]; then
                          sudo -u postgres psql -c "CREATE DATABASE $db WITH OWNER affine;"
                      else
                          sudo -u postgres psql -c "CREATE DATABASE $db WITH OWNER postgres;"
                      fi
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
    stop_redis
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
    procps-ng \
    redis \
    socat \
    hostname \
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


log "Using default PostgreSQL modules installation via dnf for PostgreSQL 13."

if ! dnf -y module install postgresql:13/server; then
    log "FATAL: PostgreSQL 13 module installation failed. Aborting."
    exit 1
fi

if ! dnf -y install postgresql-contrib; then
    log "FATAL: PostgreSQL 13 contrib installation failed. Aborting."
    exit 1
fi


if ! dnf clean all; then
    log "FATAL: dnf clean all failed. Aborting."
    exit 1
fi

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

start_redis() {
    if pgrep -f "redis-server" &>/dev/null; then
        log "Redis is already running."
        return 0
    fi

    log "Starting Redis..."
    redis-server "$REDIS_CONF_FILE" &
    sleep 1
    if ! pgrep -f "redis-server" &>/dev/null; then
        log "ERROR: Redis failed to start."
        return 1
    fi
    log "Redis started."
    return 0
}

log "Setting up Redis..."
stop_redis

if ! sed -i "s/^daemonize no/daemonize yes/" "$REDIS_CONF_FILE"; then
    log "WARNING: Failed to configure Redis to run as a daemon. Continuing..."
fi

if ! sed -i "s/^# bind 127.0.0.1 ::1/bind 0.0.0.0/" "$REDIS_CONF_FILE"; then
    log "FATAL: Failed to configure Redis binding. Aborting."
    exit 1
fi
if ! sed -i "s/^protected-mode yes/protected-mode no/" "$REDIS_CONF_FILE"; then
    log "FATAL: Failed to disable Redis protected mode. Aborting."
    exit 1
fi

sudo mkdir -p /var/log/redis
sudo chown redis:redis /var/log/redis

log "Starting Redis..."
if ! start_redis; then
    log "FATAL: Could not start Redis service. Aborting."
    log "Check Redis logs at /var/log/redis/redis.log for more details."
    exit 1
fi

log "Redis is running."

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
chmod 755 -R /mnt/pgdb_backups

echo '0 2 * * * /usr/sbin/logrotate /etc/logrotate.conf' > /etc/cron.d/logrotate
echo '0 3 * * * /usr/local/bin/backup_postgres.sh' > /etc/cron.d/pgbackup

##############################################################################
# FINALIZATION
##############################################################################

log "Provisioning complete!"

