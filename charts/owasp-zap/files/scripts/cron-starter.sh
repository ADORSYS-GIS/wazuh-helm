#!/bin/bash

# Create a temporary directory and ensure it is removed on exit
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# Define the payload file
PAYLOAD_FILE="$TEMP_DIR/payload.json"

# Write the payload to the file
cat <<EOF > "$PAYLOAD_FILE"
{
  "body": {},
  "headers": {
    "Content-Type": "application/json"
  }
}
EOF

# Send the HTTP POST request
RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://el-{{ include "common.names.fullname" $ }}-event-listener:8080" \
  -H "Content-Type: application/json" \
  -d @"$PAYLOAD_FILE")

# Check if the request was successful (2xx status code)
if [[ "$RESPONSE" -ge 200 && "$RESPONSE" -lt 300 ]]; then
  echo "Request was successful with status code $RESPONSE."
else
  echo "Request failed with status code $RESPONSE."
fi
