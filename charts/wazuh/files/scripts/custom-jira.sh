#!/bin/sh
# Copyright (C) 2015, Wazuh Inc.
# Created by Wazuh, Inc. <info@wazuh.com>.
# This program is free software; you can redistribute it and/or modify it under the terms of GPLv2

# Define the Python binary path (using Wazuh's bundled Python)
WPYTHON_BIN="framework/python/bin/python3"

# Get the script's directory and name
SCRIPT_PATH_NAME="$0"
DIR_NAME="$(cd $(dirname "${SCRIPT_PATH_NAME}"); pwd -P)"
SCRIPT_NAME="$(basename "${SCRIPT_PATH_NAME}")"

# Set the Wazuh path if not already defined
if [ -z "${WAZUH_PATH}" ]; then
    WAZUH_PATH="$(cd "${DIR_NAME}/.."; pwd)"
fi

# Define the Python script path
PYTHON_SCRIPT="${DIR_NAME}/${SCRIPT_NAME}.py"

# Log file for debugging
LOG_FILE="${WAZUH_PATH}/logs/integrations.log"

# Check if the Python script exists
if [ ! -f "${PYTHON_SCRIPT}" ]; then
    echo "$(date '+%Y/%m/%d %H:%M:%S') - ERROR: Python script ${PYTHON_SCRIPT} not found" >> "${LOG_FILE}"
    exit 1
fi

# Check if at least 5 arguments are provided
if [ $# -lt 5 ]; then
    echo "$(date '+%Y/%m/%d %H:%M:%S') - ERROR: Expected at least 5 arguments, got $#" >> "${LOG_FILE}"
    exit 1
fi

# Execute the Python script with the first 5 arguments
"${WAZUH_PATH}/${WPYTHON_BIN}" "${PYTHON_SCRIPT}" "$1" "$2" "$3" "$4" "$5"

# Check the exit status of the Python script
if [ $? -ne 0 ]; then
    echo "$(date '+%Y/%m/%d %H:%M:%S') - ERROR: Python script ${PYTHON_SCRIPT} failed with arguments $1 $2 $3 $4 $5" >> "${LOG_FILE}"
    exit 1
fi

exit 0