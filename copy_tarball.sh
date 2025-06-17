#!/usr/bin/env bash
# tar_and_scp.sh
# Creates a gzip-compressed tarball of a given path and SCPs it to a remote server.
#
# ─── CONFIGURATION ────────────────────────────────────────────────────────────
# Set your remote user/host and target directory here:
REMOTE_TARGET="user@remote_host"
REMOTE_DIR="/path/to/remote/directory"
# ────────────────────────────────────────────────────────────────────────────────

set -euo pipefail

usage() {
  echo "Usage: $0 -s <source_path>"
  echo
  echo "  -s   Path to file or directory to archive"
  exit 1
}

# Parse arguments
while getopts ":s:" opt; do
  case ${opt} in
    s) SRC_PATH=$OPTARG ;;
    *) usage ;;
  esac
done

# Ensure source path is provided
if [ -z "${SRC_PATH-}" ]; then
  usage
fi

# Check that the source exists
if [ ! -e "$SRC_PATH" ]; then
  echo "Error: source path '$SRC_PATH' does not exist." >&2
  exit 2
fi

# Build tarball name from the input path
BASE=$(basename "$SRC_PATH")
DATE=$(date +%F)
TARBALL="${BASE}-${DATE}.tar.gz"

# Create the tarball
echo "Creating archive '$TARBALL' from '$SRC_PATH'..."
tar -czf "$TARBALL" -C "$(dirname "$SRC_PATH")" "$BASE"
echo "Archive created."

# Copy via SCP
echo "Copying '$TARBALL' to '$REMOTE_TARGET:$REMOTE_DIR'..."
scp "$TARBALL" "${REMOTE_TARGET}:${REMOTE_DIR}/"
echo "Copy complete."

# (Optional) remove local tarball after transfer
# rm -f "$TARBALL"
