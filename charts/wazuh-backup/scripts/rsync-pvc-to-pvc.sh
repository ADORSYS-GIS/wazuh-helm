#!/bin/bash
set -euxo pipefail

# Parameters passed via environment variables
SOURCE_PATH="${SOURCE_PATH:-}"
DESTINATION_PATH="${DESTINATION_PATH:-}"

if [[ -z "$SOURCE_PATH" ]]; then
  echo "❌ SOURCE_PATH environment variable must be set"
  exit 1
fi

if [[ -z "$DESTINATION_PATH" ]]; then
  echo "❌ DESTINATION_PATH environment variable must be set"
  exit 1
fi

SRC_DIR="/source/${SOURCE_PATH}"
DEST_DIR="/backup/${DESTINATION_PATH}"

# 1. Source must exist
if [[ ! -d "$SRC_DIR" ]]; then
  echo "❌ Source directory $SRC_DIR does not exist."
  exit 1
fi

# 2. Refuse to treat / (root) as either source or destination
if [[ "$SRC_DIR" == "/" || "$DEST_DIR" == "/" ]]; then
  echo "❌ Refusing to use / as source or destination."
  exit 1
fi

# 3. Create destination if it is missing
if [[ ! -d "$DEST_DIR" ]]; then
  echo "📂 Destination $DEST_DIR not found. Creating it…"
  mkdir -p "$DEST_DIR"
fi

echo "📦 Rsyncing from $SRC_DIR/ → $DEST_DIR/"
# -a : archive (recursive, preserve permissions/owners/timestamps, etc.)
# -v : verbose (helps with Tekton log visibility)
# -h : human-readable numbers
# --delete : remove files in DEST that were deleted from SRC
rsync -avh --delete "$SRC_DIR/" "$DEST_DIR/"
echo "✅ Rsync complete."