#!/bin/sh
# Wazuh → Teams (Dynamic URL detection)

WPYTHON_BIN="framework/python/bin/python3"
SCRIPT_PATH_NAME="$0"
DIR_NAME="$(cd "$(dirname "${SCRIPT_PATH_NAME}")"; pwd -P)"
SCRIPT_NAME="$(basename "${SCRIPT_PATH_NAME}")"

if [ -z "${WAZUH_PATH}" ]; then
    WAZUH_PATH="$(cd "${DIR_NAME}/.."; pwd)"
fi

PYTHON_SCRIPT="${DIR_NAME}/${SCRIPT_NAME}.py"
LOG_FILE="${WAZUH_PATH}/logs/integrations.log"

# DEBUG
echo "$(date '+%Y/%m/%d %H:%M:%S') WAZUH CALL: ARGS=[$*] COUNT=$#" >> "${LOG_FILE}"

if [ ! -f "${PYTHON_SCRIPT}" ]; then
    echo "ERROR: ${PYTHON_SCRIPT} not found" >> "${LOG_FILE}"
    exit 1
fi

# Pass ALL arguments to Python
"${WAZUH_PATH}/${WPYTHON_BIN}" "${PYTHON_SCRIPT}" "$@" >> "${LOG_FILE}" 2>&1
exit $?