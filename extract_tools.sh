#!/bin/bash
set -e

MINIO_URL="http://localhost:9000/blobs"
CONTAINER_TAR_PATH="/tmp/tools.tar.gz"
DEST_DIR="/mnt/archives"

if [ -z "$1" ]; then
    echo "Error: Container name/ID must be provided"
    echo "Usage: $0 [CONTAINER_NAME]"
    exit 1
fi

CONTAINER_NAME=$1

echo "Creating tarball in container ${CONTAINER_NAME}..."
docker exec "${CONTAINER_NAME}" tar -czvf "${CONTAINER_TAR_PATH}" \
    /home/prefect/ \
    /usr/local/bin/{xeol,syft,trivy,kantra,grype,go-enry,cloc}

echo "Extracting tarball to host..."
mkdir -p "${DEST_DIR}"
docker cp "${CONTAINER_NAME}:${CONTAINER_TAR_PATH}" "${DEST_DIR}/tools.tar.gz"

echo "Uploading to MinIO..."
curl -X PUT --upload-file "${DEST_DIR}/tools.tar.gz" \
    "${MINIO_URL}/tools.tar.gz"

echo -e "\nUpload successful! Public URL:"
echo "${MINIO_URL}/tools.tar.gz"
