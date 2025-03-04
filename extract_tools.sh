#!/bin/bash
set -e

# Configuration
MINIO_URL="http://localhost:9000/blobs"
CONTAINER_TAR_PATH="/tmp/tools.tar.gz"
DEST_DIR="${HOME}/tools"

# Verify container ID provided
if [ -z "$1" ]; then
    echo "Error: Container ID must be provided"
    echo "Usage: $0 [CONTAINER_ID]"
    exit 1
fi

CONTAINER_ID=$1

# Create archive with explicit path listing
echo "Packaging files in container ${CONTAINER_ID}..."
docker exec "${CONTAINER_ID}" tar -czvf "${CONTAINER_TAR_PATH}" \
    /home/prefect/.cache \
    /home/prefect/.grype \
    /home/prefect/.kantra \
    /home/prefect/.semgrep \
    /home/prefect/.syft \
    /home/prefect/.trivy \
    /usr/local/bin/xeol \
    /usr/local/bin/syft \
    /usr/local/bin/trivy \
    /usr/local/bin/kantra \
    /usr/local/bin/grype \
    /usr/local/bin/go-enry \
    /usr/local/bin/cloc

# Copy to host
echo "Extracting to ${DEST_DIR}..."
mkdir -p "${DEST_DIR}"
docker cp "${CONTAINER_ID}:${CONTAINER_TAR_PATH}" "${DEST_DIR}/tools.tar.gz"

# Upload to MinIO
echo "Uploading to ${MINIO_URL}..."
curl -X PUT --upload-file "${DEST_DIR}/tools.tar.gz" \
    "${MINIO_URL}/tools.tar.gz"

# Cleanup container file
docker exec "${CONTAINER_ID}" rm -f "${CONTAINER_TAR_PATH}"

echo -e "\n✅ Success! File available at:"
echo "${MINIO_URL}/tools.tar.gz"
echo "Local copy: ${DEST_DIR}/tools.tar.gz"
