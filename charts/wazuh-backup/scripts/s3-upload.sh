#!/bin/sh
set -eu

# Parameters passed via environment variables
COMPONENT_NAME="${COMPONENT_NAME:-}"

if [ -z "$COMPONENT_NAME" ]; then
  echo "❌ COMPONENT_NAME environment variable must be set"
  exit 1
fi

# Read the archive name and date from previous step
ARCHIVE_NAME="$(cat /backup/archive-name.txt)"
DATE_STAMP="$(cat /backup/date-stamp.txt)"

ARCHIVE_PATH="/backup/${ARCHIVE_NAME}"

if [ ! -f "${ARCHIVE_PATH}" ]; then
  echo "❌ Expected archive ${ARCHIVE_PATH} not found"
  exit 1
fi

# S3 path structure: DD-MM-YY-wazuh-backup/component-name/filename
S3_PATH="s3://${S3_BUCKET_NAME}/${DATE_STAMP}-wazuh-backup/${COMPONENT_NAME}/${ARCHIVE_NAME}"

AWS_ARGS=""
if [ -n "${S3_ENDPOINT_URL}" ]; then
  AWS_ARGS="--endpoint-url ${S3_ENDPOINT_URL}"
fi

echo "☁️  Uploading ${ARCHIVE_PATH} → ${S3_PATH}"
aws s3 cp ${AWS_ARGS} "${ARCHIVE_PATH}" "${S3_PATH}"
echo "✅ S3 upload complete: ${S3_PATH}"

# Clean up the archive file after successful upload
rm -f "${ARCHIVE_PATH}" /backup/archive-name.txt /backup/date-stamp.txt
