FROM almalinux:8

ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    PYTHONUNBUFFERED=1 \
    SUPERSET_HOME="/root/tools/superset" \
    SUPERSET_CONFIG_PATH="/root/tools/superset/superset_config.py" \
    METABASE_HOME="/root/tools/metabase"

# 1) Update and install base packages
RUN dnf -y update && \
    dnf -y install \
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
    && dnf clean all

# 2) Install PostgreSQL 13 (no initdb yet)
RUN dnf -y install \
    https://download.postgresql.org/pub/repos/yum/reporpms/EL-8-x86_64/pgdg-redhat-repo-latest.noarch.rpm \
    && dnf -qy module disable postgresql \
    && dnf -y install \
        postgresql13 \
        postgresql13-server \
        postgresql13-contrib \
    && dnf clean all

# 3) Configure PostgreSQL sample files for remote access
RUN sed -i "s/^#listen_addresses = 'localhost'/listen_addresses = '*'/" /usr/pgsql-13/share/postgresql.conf.sample && \
    echo "host all all 0.0.0.0/0 md5" >> /usr/pgsql-13/share/pg_hba.conf.sample

# 4) Install Redis and configure for remote access
RUN dnf -y install redis && \
    dnf clean all && \
    sed -i "s/^# bind 127.0.0.1 ::1/bind 0.0.0.0/" /etc/redis.conf && \
    sed -i "s/^protected-mode yes/protected-mode no/" /etc/redis.conf

# 5) Install Node.js 22 + Yarn from NodeSource
RUN curl -sL https://rpm.nodesource.com/setup_22.x | bash - && \
    dnf -y install nodejs && \
    npm install -g yarn && \
    node --version && npm --version && yarn --version

# 6) Install Python 3.11, then bootstrap pip via ensurepip
RUN dnf -y install python3.11 python3.11-devel && \
    dnf clean all

RUN python3.11 -m ensurepip --upgrade && \
    python3.11 -m pip install --upgrade pip

RUN alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1 && \
    ln -s /usr/local/bin/pip3 /usr/bin/pip3.11 && \
    alternatives --install /usr/bin/pip3 pip3 /usr/bin/pip3.11 1

# 7) Install a specific version of Apache Superset (4.1.0rc3) with Postgres extras
RUN pip3 install --upgrade setuptools wheel && \
    pip3 install "apache-superset[postgres]==4.1.0rc3"

# Example lines in your Dockerfile
RUN dnf -y install logrotate cronie && \
    dnf clean all

# Copy a custom logrotate config
COPY our-logs.conf /etc/logrotate.d/our-logs

# Create needed directories for logs
RUN mkdir -p /var/lib/logs && \
    mkdir -p /var/log/redis

RUN echo '#!/bin/bash\n/usr/sbin/logrotate /etc/logrotate.conf' > /etc/cron.daily/logrotate-custom && \
    chmod +x /etc/cron.daily/logrotate-custom

RUN mkdir -p /mnt/pgdb_backups

# Copy the backup script
COPY backup_postgres.sh /usr/local/bin/backup_postgres.sh
RUN chmod +x /usr/local/bin/backup_postgres.sh

RUN echo '#!/bin/bash\n/usr/local/bin/backup_postgres.sh' > /etc/cron.daily/pgbackup && \
    chmod +x /etc/cron.daily/pgbackup

# 8) Create Superset directory (matching the script)
RUN mkdir -p "$SUPERSET_HOME/logs"

# Copy your custom superset_config.py into the container
# Make sure superset_config.py is in the same dir as your Dockerfile
COPY superset_config.py "$SUPERSET_HOME/superset_config.py"

# 1) Create a Metabase folder
RUN mkdir -p "$METABASE_HOME/logs"

# 2) Download Metabase v0.52.4 jar
RUN cd /root/tools/metabase && \
    wget https://downloads.metabase.com/v0.52.4/metabase.jar -O metabase.jar

# 9) Copy your manual services script
COPY services.sh /usr/local/bin/services.sh
RUN chmod +x /usr/local/bin/services.sh

# Expose Postgres (5432), Redis (6379), and Superset (8099)
EXPOSE 5432 6379 8099 3000 3010 8088

CMD ["/bin/bash"]
