#!/bin/bash
set -eo pipefail

# RHEL WSL Cleanup Script (No wsl.exe Commands)
# Purpose: Clean a RHEL-based WSL instance to reclaim space before exporting it.
# Warning: This operation is irreversible:
#  - All hidden directories in your home (dot-folders except . and ..) will be deleted.
#  - System caches, logs, and temporary files will be removed.
#  - PostgreSQL databases will be vacuumed to reclaim space.
#  - Docker resources (images, containers, etc.) will be pruned.
#
# Usage: ./wsl_cleanup.sh

# Remove all hidden directories from the user's home directory (excluding . and ..)
echo "Removing all hidden directories from $HOME (except . and ..)..."
find "$HOME" -maxdepth 1 -type d -name ".*" ! -name "." ! -name ".." -exec rm -rf {} +

# System cleanup for RHEL
echo "Starting system cleanup..."
sudo dnf update -y
sudo dnf upgrade --refresh -y
sudo dnf autoremove -y
sudo dnf clean all
sudo rm -rf /var/cache/dnf/*
sudo rm -rf /tmp/* /var/tmp/*
sudo rm -rf /var/log/*.log /var/log/dnf /var/log/journal/*
rm -rf ~/.cache/* ~/.npm/* ~/.m2/* ~/.gradle/* ~/.ivy2/* ~/.nuget/*

# PostgreSQL vacuum
echo "Vacuuming PostgreSQL databases..."
if command -v vacuumdb >/dev/null 2>&1; then
    sudo -u postgres vacuumdb --all --analyze
else
    echo "vacuumdb not found. Skipping PostgreSQL vacuum."
fi

# Docker cleanup (if Docker is used within WSL)
echo "Cleaning Docker resources..."
docker system prune --all --force || true
docker image prune --force 2>/dev/null || true

if [ "$(docker ps -aq)" ]; then
    docker stop $(docker ps -aq) 2>/dev/null || true
    docker rm $(docker ps -aq) 2>/dev/null || true
fi

echo "Cleanup complete!"