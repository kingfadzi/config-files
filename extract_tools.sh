#!/bin/bash
set -e

MINIO_URL="http://localhost:9000"
BUCKET="blobs"

if [ -z "$1" ]; then
    echo "Error: Container name must be provided as first argument"
    echo "Usage: $0 [CONTAINER_NAME]"
    exit 1
fi

CONTAINER_NAME=$1
DEST_DIR="/mnt/archives"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
ARCHIVE_NAME="tools_${TIMESTAMP}.tar.gz"

echo "Creating archive ${ARCHIVE_NAME} from container ${CONTAINER_NAME}..."
docker run -v $(pwd):/backup --rm -it ${CONTAINER_NAME} \
    tar -czvf /backup/${ARCHIVE_NAME} \
        /home/prefect/ \
        /usr/local/bin/{xeol,syft,trivy,kantra,grype,go-enry,cloc}

echo "Staging in ${DEST_DIR}..."
mkdir -p "${DEST_DIR}"
mv "${ARCHIVE_NAME}" "${DEST_DIR}"

echo "Uploading to ${MINIO_URL}..."
curl -X PUT --upload-file "${DEST_DIR}/${ARCHIVE_NAME}" \
    "${MINIO_URL}/${BUCKET}/${ARCHIVE_NAME}"

echo -e "\nUpload complete! Public URL:"
echo "${MINIO_URL}/${BUCKET}/${ARCHIVE_NAME}"
