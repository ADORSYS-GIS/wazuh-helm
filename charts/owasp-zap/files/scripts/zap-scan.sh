#!/bin/bash

#set -e

# Create a temporary directory
TEMP_DIR=$(mktemp -d)

# Function to log messages with timestamps
log_message() {
    echo "-- $1"
}

# Function to clean up temporary directory
cleanup() {
    log_message "Cleaning up temporary directory ${TEMP_DIR}"
    rm -rf "${TEMP_DIR}"
}
trap cleanup EXIT

log_message "Verifying if ${WORK_DIR} directory exists and is writable..."
# Create the working directory if it doesn't exist, and check if it is writable
if mkdir -p "${WORK_DIR}"; then
    log_message "${WORK_DIR} is ready"
else
    log_message "${WORK_DIR} is not writable"
    exit 1
fi

log_message "Running the zap-full-scan.py script with url ${APP_URL}..."
# Run the ZAP full scan
su -c "/zap/zap-full-scan.py -t ${APP_URL} -J ${TEMP_DIR}/${REPORT_JSON} -r ${TEMP_DIR}/${REPORT_HTML}"

log_message "Verifying if ${REPORT_JSON} was created..."
# Check if the JSON report was created
if [ -f "${TEMP_DIR}/${REPORT_JSON}" ]; then
    log_message "${REPORT_JSON} was created successfully"
else
    log_message "Failed to create ${REPORT_JSON}"
    exit 1
fi

# Copy the JSON report to the output path
cp "${TEMP_DIR}/${REPORT_JSON}" "${MEM_PATH}/tmp-${REPORT_JSON}"
log_message "${REPORT_JSON} was copied to tmp-${REPORT_JSON}"

# Copy the HTML report to the output path
cp "${TEMP_DIR}/${REPORT_HTML}" "${OUTPUT_PATH}/${REPORT_HTML}"
log_message "${REPORT_HTML} was copied to ${OUTPUT_PATH}/${REPORT_HTML}"

# Clean up temporary directory (done automatically by the trap)
