#!/bin/sh
# trigger-backup-cronjob.sh
# Script to trigger Wazuh backup via EventListener webhook

set -e

# Required environment variables:
# - COMPONENT_NAME: Name of the component (master, indexer, worker)
# - S3_BUCKET_NAME: S3 bucket name
# - S3_ENDPOINT_URL: Optional S3 endpoint URL
# - EVENT_LISTENER_URL: EventListener service URL

echo "Scheduled backup triggered for ${COMPONENT_NAME} at $(date)"

# Build JSON payload
JSON_PAYLOAD=$(cat <<JSONEOF
{
  "component": "${COMPONENT_NAME}",
  "s3BucketName": "${S3_BUCKET_NAME}",
  "s3EndpointUrl": "${S3_ENDPOINT_URL}",
  "triggeredBy": "cronjob"
}
JSONEOF
)

# Send POST request to EventListener
curl -X POST \
  -H "Content-Type: application/json" \
  -d "${JSON_PAYLOAD}" \
  "${EVENT_LISTENER_URL}"

if [ $? -eq 0 ]; then
  echo "Backup request sent successfully for ${COMPONENT_NAME}"
  exit 0
else
  echo "Failed to send backup request for ${COMPONENT_NAME}"
  exit 1
fi
