#!/bin/sh
set -euo pipefail

# Parameters passed via environment variables
COMPONENT_NAME="${COMPONENT_NAME:-}"
SOURCE_DIRECTORY_PATH="${SOURCE_DIRECTORY_PATH:-}"

if [[ -z "$COMPONENT_NAME" ]]; then
  echo "❌ COMPONENT_NAME environment variable must be set"
  exit 1
fi

if [[ -z "$SOURCE_DIRECTORY_PATH" ]]; then
  echo "❌ SOURCE_DIRECTORY_PATH environment variable must be set"
  exit 1
fi

SRC_DIR="/backup/${SOURCE_DIRECTORY_PATH}"

if [ ! -d "${SRC_DIR}" ]; then
  echo "❌ Source directory ${SRC_DIR} does not exist."
  exit 1
fi

# Create timestamp in DD-MM-YY format
DATE_STAMP="$(date +'%d-%m-%y')"
TIME_STAMP="$(date +'%H%M%S')"
ARCHIVE_NAME="${COMPONENT_NAME}-backup-${DATE_STAMP}-${TIME_STAMP}.tar.gz"
ARCHIVE_PATH="/backup/${ARCHIVE_NAME}"

echo "📦 Creating ${ARCHIVE_NAME} from ${SRC_DIR}/ …"
tar -czf "${ARCHIVE_PATH}" -C "${SRC_DIR}" .
echo "✅ Archive created at ${ARCHIVE_PATH}"

# Store the archive name for the next step
echo "${ARCHIVE_NAME}" > /backup/archive-name.txt
echo "${DATE_STAMP}" > /backup/date-stamp.txt