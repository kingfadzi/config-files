#!/bin/bash
set -e

# Configuration
MINIO_URL="http://localhost:9000/blobs"
# Temporary directory on host to store files copied from the container
CONTAINER_COPY_DIR="/tmp/container_tools"
# Final destination for the tarball on host
DEST_DIR="${HOME}/tools"
TAR_FILE="${DEST_DIR}/tools.tar.gz"

# Verify container ID provided
if [ -z "$1" ]; then
    echo "Error: Container ID must be provided"
    echo "Usage: $0 [CONTAINER_ID]"
    exit 1
fi

CONTAINER_ID=$1

echo "Creating destination directories on host..."
mkdir -p "${DEST_DIR}"
mkdir -p "${CONTAINER_COPY_DIR}"

# List of paths to copy from the container
paths=(
    "/home/prefect/.cache"
    "/home/prefect/.grype"
    "/home/prefect/.kantra"
    "/home/prefect/.semgrep"
    "/home/prefect/.syft"
    "/home/prefect/.trivy"
    "/usr/local/bin/xeol"
    "/usr/local/bin/syft"
    "/usr/local/bin/trivy"
    "/usr/local/bin/kantra"
    "/usr/local/bin/grype"
    "/usr/local/bin/go-enry"
    "/usr/local/bin/cloc"
)

echo "Copying files from container ${CONTAINER_ID}..."
for path in "${paths[@]}"; do
    # Prepare the host destination directory preserving the container's file structure
    host_dest_dir="${CONTAINER_COPY_DIR}${path}"
    mkdir -p "$(dirname "${host_dest_dir}")"
    echo "Copying ${path}..."
    docker cp "${CONTAINER_ID}:${path}" "${host_dest_dir}"
done

echo "Creating tarball on host..."
# Create tarball; use -C to change into the temporary directory so the archive structure matches the container's paths
tar -czvf "${TAR_FILE}" -C "${CONTAINER_COPY_DIR}" .

echo "Uploading to ${MINIO_URL}..."
curl -X PUT --upload-file "${TAR_FILE}" "${MINIO_URL}/tools.tar.gz"

echo "Cleaning up temporary files..."
rm -rf "${CONTAINER_COPY_DIR}"

echo -e "\n✅ Success! File available at:"
echo "${MINIO_URL}/tools.tar.gz"
echo "Local copy: ${TAR_FILE}"
