#!/bin/bash
set -euo pipefail

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

# Validate directories exist in container
echo "Verifying directories in container ${CONTAINER_ID}..."
required_dirs=(
    "/home/prefect/.cache"
    "/home/prefect/.grype"
    "/home/prefect/.kantra"
    "/home/prefect/.semgrep"
    "/home/prefect/.syft"
    "/home/prefect/.trivy"
)

for dir in "${required_dirs[@]}"; do
    docker exec "${CONTAINER_ID}" test -d "${dir}" || {
        echo "Error: Directory ${dir} not found in container"
        exit 1
    }
done

# Validate files exist in container
echo "Verifying binaries in container ${CONTAINER_ID}..."
required_files=(
    "/usr/local/bin/xeol"
    "/usr/local/bin/syft"
    "/usr/local/bin/trivy"
    "/usr/local/bin/kantra"
    "/usr/local/bin/grype"
    "/usr/local/bin/go-enry"
    "/usr/local/bin/cloc"
)

for file in "${required_files[@]}"; do
    docker exec "${CONTAINER_ID}" test -f "${file}" || {
        echo "Error: File ${file} not found in container"
        exit 1
    }
done

# Create archive with explicit type verification
echo "Packaging files..."
docker exec "${CONTAINER_ID}" tar -czvf "${CONTAINER_TAR_PATH}" \
    --transform='s,^home/prefect/,,' \
    --transform='s,^usr/local/bin/,,' \
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
echo "Copying archive to ${DEST_DIR}..."
mkdir -p "${DEST_DIR}"
docker cp "${CONTAINER_ID}:${CONTAINER_TAR_PATH}" "${DEST_DIR}/tools.tar.gz"

# Upload to MinIO
echo "Uploading to MinIO..."
if ! curl -X PUT --fail --upload-file "${DEST_DIR}/tools.tar.gz" \
    "${MINIO_URL}/tools.tar.gz"; then
    echo "Error: Failed to upload to MinIO"
    exit 1
fi

# Cleanup
docker exec "${CONTAINER_ID}" rm -f "${CONTAINER_TAR_PATH}"

echo -e "\n✅ Success! File available at:"
echo "${MINIO_URL}/tools.tar.gz"
echo "Local copy: ${DEST_DIR}/tools.tar.gz"
