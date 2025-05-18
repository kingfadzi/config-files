#!/bin/bash

set -e

CONFIG_FILE="$1"
if [ -z "$CONFIG_FILE" ]; then
  echo "Usage: $0 <config.yaml>"
  exit 1
fi

if ! command -v yq &> /dev/null; then
  echo "Error: 'yq' is required (https://github.com/mikefarah/yq)"
  exit 1
fi

REPO_OWNER=$(yq e '.repo_owner' "$CONFIG_FILE")
REPO_NAME=$(yq e '.repo_name' "$CONFIG_FILE")
BRANCH=$(yq e '.branch' "$CONFIG_FILE")
TARGET_DIR=$(yq e '.target_dir' "$CONFIG_FILE")
DIRS_TO_COPY=($(yq e '.dirs_to_copy[]' "$CONFIG_FILE"))

ZIP_URL="https://github.com/$REPO_OWNER/$REPO_NAME/archive/refs/heads/$BRANCH.zip"
TMP_ZIP="$HOME/Downloads/${REPO_NAME}_${BRANCH}.zip"
UNZIP_DIR="$HOME/Downloads/${REPO_NAME}-${BRANCH}"

# Step 1: git pull if target is a git repo
if [ -d "$TARGET_DIR/.git" ]; then
  echo "Running git pull in $TARGET_DIR"
  git -C "$TARGET_DIR" pull
fi

# Step 2: Download ZIP
echo "Downloading: $ZIP_URL"
curl --proxy "${https_proxy:-}" -L "$ZIP_URL" -o "$TMP_ZIP"

# Step 3: Unzip
echo "Unzipping to: $UNZIP_DIR"
unzip -q -o "$TMP_ZIP" -d "$HOME/Downloads"

# Step 4: Delete specific directories in destination
echo "Cleaning target directories in: $TARGET_DIR"
for dir in "${DIRS_TO_COPY[@]}"; do
  TARGET_SUBDIR="$TARGET_DIR/$dir"
  if [ -d "$TARGET_SUBDIR" ]; then
    echo "Deleting $TARGET_SUBDIR"
    rm -rf "$TARGET_SUBDIR"
  fi
done

# Step 5: Copy new versions
echo "Copying updated directories"
for dir in "${DIRS_TO_COPY[@]}"; do
  SRC="$UNZIP_DIR/$dir"
  DEST="$TARGET_DIR/$dir"
  if [ -d "$SRC" ]; then
    mkdir -p "$(dirname "$DEST")"
    cp -r "$SRC" "$DEST"
    echo "Copied $SRC → $DEST"
  else
    echo "Warning: $SRC not found"
  fi
done

echo "Done."