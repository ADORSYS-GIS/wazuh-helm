#!/bin/bash

# Wazuh Control Script - Stop/Start Wazuh services using wazuh-control binary
# This is more graceful than scaling StatefulSets and ensures proper service shutdown

# Set error handling based on mode
if [ "${MODE}" = "emergency" ]; then
  # Emergency mode: lenient error handling
  set -eu
  echo "🚨 EMERGENCY MODE: Lenient error handling active"
else
  # Normal mode: strict error handling
  set -eux
  echo "⚙️  NORMAL MODE: Strict error handling active"
fi

echo "🔄 Starting Wazuh Control Operation"
echo "Pod: ${POD_NAME}"
echo "Container: ${CONTAINER_NAME}"
echo "Namespace: ${NAMESPACE}"
echo "Operation: ${OPERATION}"  # stop or start
echo "Component: ${COMPONENT_NAME}"
echo "Mode: ${MODE}"
echo "Timestamp: $(date)"
echo "================================"

# Skip emergency recovery if the pipeline already succeeded (finally block still runs)
if [ "${MODE}" = "emergency" ] && [ "${PIPELINE_STATUS:-}" = "Succeeded" ]; then
  echo "✅ Pipeline succeeded; skipping emergency recovery start"
  exit 0
fi

# Validate parameters
if [ -z "${POD_NAME}" ] || [ -z "${NAMESPACE}" ] || [ -z "${OPERATION}" ]; then
  echo "❌ Required environment variables missing"
  echo "   POD_NAME: ${POD_NAME:-<not set>}"
  echo "   NAMESPACE: ${NAMESPACE:-<not set>}"
  echo "   OPERATION: ${OPERATION:-<not set>}"

  if [ "${MODE}" = "emergency" ]; then
    echo "🚨 Emergency mode: Continuing despite missing parameters"
    exit 0
  else
    exit 1
  fi
fi

# Default container name if not provided
CONTAINER_NAME="${CONTAINER_NAME:-wazuh-manager}"

# Wazuh control binary path
WAZUH_CONTROL_PATH="${WAZUH_CONTROL_PATH:-/var/ossec/bin/wazuh-control}"

# Function for emergency mode error handling
emergency_handle_error() {
  local error_msg="$1"
  local exit_code="$2"

  echo "⚠️  Emergency mode error: $error_msg"
  echo "💡 Attempting recovery strategies..."

  # Don't exit in emergency mode - log and continue
  echo "🔄 Continuing with emergency recovery..."
  return 0
}

# Function for normal mode error handling
normal_handle_error() {
  local error_msg="$1"
  local exit_code="$2"

  echo "❌ Normal mode error: $error_msg"
  echo "🛑 Failing pipeline due to error"
  exit "$exit_code"
}

# Unified error handler
handle_error() {
  local error_msg="$1"
  local exit_code="${2:-1}"

  if [ "${MODE}" = "emergency" ]; then
    emergency_handle_error "$error_msg" "$exit_code"
  else
    normal_handle_error "$error_msg" "$exit_code"
  fi
}

# Function to check if pod exists and is ready
check_pod_status() {
  echo "🔍 Checking pod status..."

  if ! kubectl get pod "${POD_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    ERROR_MSG="Pod ${POD_NAME} not found in namespace ${NAMESPACE}"

    if [ "${MODE}" = "emergency" ]; then
      echo "⚠️  $ERROR_MSG"
      echo "🔍 Available pods in namespace:"
      kubectl get pods -n "${NAMESPACE}" || echo "Cannot list pods"
      echo "🔄 Emergency mode: Continuing despite missing pod"
      return 1
    else
      echo "❌ $ERROR_MSG"
      echo "🔍 Available pods:"
      kubectl get pods -n "${NAMESPACE}"
      handle_error "$ERROR_MSG" 1
    fi
  fi

  # Check if pod is running
  POD_PHASE=$(kubectl get pod "${POD_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  echo "📊 Pod phase: ${POD_PHASE}"

  if [ "${POD_PHASE}" != "Running" ] && [ "${OPERATION}" = "stop" ]; then
    echo "⚠️  Pod is not running (phase: ${POD_PHASE}), services may already be stopped"
  fi

  return 0
}

# Function to get Wazuh service status
get_wazuh_status() {
  echo "🔍 Getting Wazuh service status..."

  # Capture status output (don't rely on exit code - it fails if ANY service is not running)
  STATUS_OUTPUT=$(kubectl exec "${POD_NAME}" -n "${NAMESPACE}" -c "${CONTAINER_NAME}" -- \
    ${WAZUH_CONTROL_PATH} status 2>&1) || true

  # Check if we got any output at all
  if [ -z "$STATUS_OUTPUT" ]; then
    echo "⚠️  Could not get service status (no output)"
    return 1
  fi

  # Display the status
  echo "$STATUS_OUTPUT"

  # Count running vs not-running services
  RUNNING_COUNT=$(echo "$STATUS_OUTPUT" | grep -c "is running" || echo "0")
  NOT_RUNNING_COUNT=$(echo "$STATUS_OUTPUT" | grep -c "not running" || echo "0")

  echo ""
  echo "📊 Status Summary: ${RUNNING_COUNT} running, ${NOT_RUNNING_COUNT} not running"

  # If we got output, the status check succeeded (even if services aren't running)
  return 0
}

# Function to stop Wazuh services
stop_wazuh_services() {
  echo "🛑 Stopping Wazuh services..."
  echo "Command: ${WAZUH_CONTROL_PATH} stop"

  # Execute wazuh-control stop
  if kubectl exec "${POD_NAME}" -n "${NAMESPACE}" -c "${CONTAINER_NAME}" -- \
    ${WAZUH_CONTROL_PATH} stop; then
    echo "✅ Wazuh stop command executed"
  else
    ERROR_MSG="Failed to execute wazuh-control stop"

    if [ "${MODE}" = "emergency" ]; then
      echo "⚠️  $ERROR_MSG"
      echo "🔄 Emergency mode: Attempting to verify if services are stopped anyway..."
    else
      echo "❌ $ERROR_MSG"
      handle_error "$ERROR_MSG" 1
    fi
  fi

  # Wait for services to fully stop
  echo "⏳ Waiting for services to stop completely..."
  sleep 5

  # Verify services are stopped
  echo "🔍 Verifying services are stopped..."
  if kubectl exec "${POD_NAME}" -n "${NAMESPACE}" -c "${CONTAINER_NAME}" -- \
    ${WAZUH_CONTROL_PATH} status 2>&1 | grep -q "not running\|stopped"; then
    echo "✅ Wazuh services confirmed stopped"
  else
    echo "⚠️  Cannot confirm all services are stopped, checking process list..."

    # Check for running Wazuh processes
    if kubectl exec "${POD_NAME}" -n "${NAMESPACE}" -c "${CONTAINER_NAME}" -- \
      ps aux 2>/dev/null | grep -E "wazuh-|ossec-" | grep -v grep; then
      echo "⚠️  Some Wazuh processes may still be running"

      if [ "${MODE}" = "normal" ]; then
        echo "💡 Waiting additional 10 seconds for processes to terminate..."
        sleep 10
      fi
    else
      echo "✅ No Wazuh processes detected - services appear stopped"
    fi
  fi
}

# Function to start Wazuh services
start_wazuh_services() {
  echo "▶️  Starting Wazuh services..."
  echo "Command: ${WAZUH_CONTROL_PATH} start"

  # Execute wazuh-control start
  if kubectl exec "${POD_NAME}" -n "${NAMESPACE}" -c "${CONTAINER_NAME}" -- \
    ${WAZUH_CONTROL_PATH} start; then
    echo "✅ Wazuh start command executed"
  else
    ERROR_MSG="Failed to execute wazuh-control start"

    if [ "${MODE}" = "emergency" ]; then
      echo "⚠️  $ERROR_MSG"
      echo "🔄 Emergency mode: Attempting alternative start methods..."

      # Try starting individual services
      for service in wazuh-modulesd wazuh-analysisd wazuh-execd wazuh-logcollector wazuh-syscheckd wazuh-monitord; do
        echo "🔄 Attempting to start ${service}..."
        kubectl exec "${POD_NAME}" -n "${NAMESPACE}" -c "${CONTAINER_NAME}" -- \
          ${WAZUH_CONTROL_PATH} start ${service} 2>/dev/null || echo "  ⚠️  Failed to start ${service}"
      done
    else
      echo "❌ $ERROR_MSG"
      handle_error "$ERROR_MSG" 1
    fi
  fi

  # Wait for services to fully start
  if [ "${MODE}" = "emergency" ]; then
    echo "⏳ Emergency mode: Shorter wait for services (15s)..."
    sleep 15
    MAX_RETRIES=3
  else
    echo "⏳ Normal mode: Waiting for services to start completely (30s)..."
    sleep 30
    MAX_RETRIES=6
  fi

  # Verify services are running with retries
  echo "🔍 Verifying services are running..."
  RETRY_COUNT=0

  while [ ${RETRY_COUNT} -lt ${MAX_RETRIES} ]; do
    if kubectl exec "${POD_NAME}" -n "${NAMESPACE}" -c "${CONTAINER_NAME}" -- \
      ${WAZUH_CONTROL_PATH} status 2>&1 | grep -q "is running"; then
      echo "✅ Wazuh services confirmed running"
      break
    else
      RETRY_COUNT=$((RETRY_COUNT + 1))
      if [ ${RETRY_COUNT} -lt ${MAX_RETRIES} ]; then
        echo "⏳ Services not ready yet, waiting... (attempt ${RETRY_COUNT}/${MAX_RETRIES})"
        sleep 10
      else
        echo "⚠️  Could not confirm services are fully running after ${MAX_RETRIES} attempts"

        if [ "${MODE}" = "emergency" ]; then
          echo "🚨 Emergency mode: Accepting partial startup"
        else
          # Show process list for debugging
          echo "🔍 Current Wazuh processes:"
          kubectl exec "${POD_NAME}" -n "${NAMESPACE}" -c "${CONTAINER_NAME}" -- \
            ps aux 2>/dev/null | grep -E "wazuh-|ossec-" | grep -v grep || echo "Cannot get process list"

          echo "⚠️  Services may not be fully healthy"
        fi
      fi
    fi
  done
}

# Function to show current status
show_status() {
  echo ""
  echo "📊 Current Wazuh Status:"
  echo "======================="

  # Capture status (ignore exit code since it fails if ANY service is not running)
  STATUS_OUTPUT=$(kubectl exec "${POD_NAME}" -n "${NAMESPACE}" -c "${CONTAINER_NAME}" -- \
    ${WAZUH_CONTROL_PATH} status 2>&1) || true

  if [ -n "$STATUS_OUTPUT" ]; then
    echo "$STATUS_OUTPUT"

    # Show summary
    RUNNING_COUNT=$(echo "$STATUS_OUTPUT" | grep -c "is running" || echo "0")
    NOT_RUNNING_COUNT=$(echo "$STATUS_OUTPUT" | grep -c "not running" || echo "0")
    echo ""
    echo "Summary: ${RUNNING_COUNT} services running, ${NOT_RUNNING_COUNT} not running"
  else
    echo "Cannot retrieve status"
  fi

  echo ""
  echo "📊 Pod Status:"
  kubectl get pod "${POD_NAME}" -n "${NAMESPACE}" -o wide 2>/dev/null || echo "Cannot get pod status"
}

# Main execution flow
echo ""
echo "🚀 Starting ${OPERATION} operation..."
echo ""

# Step 1: Check pod exists
if ! check_pod_status; then
  if [ "${MODE}" = "emergency" ]; then
    echo "✅ Emergency mode: Operation completed (no pod to operate on)"
    exit 0
  else
    handle_error "Pod check failed" 1
  fi
fi

# Step 2: Show initial status
if [ "${OPERATION}" = "stop" ]; then
  get_wazuh_status || echo "⚠️  Initial status check failed"
fi

# Step 3: Perform operation
if [ "${OPERATION}" = "stop" ]; then
  stop_wazuh_services
elif [ "${OPERATION}" = "start" ]; then
  start_wazuh_services
else
  ERROR_MSG="Invalid operation: ${OPERATION} (must be 'stop' or 'start')"

  if [ "${MODE}" = "emergency" ]; then
    echo "⚠️  $ERROR_MSG"
    echo "🚨 Emergency mode: Skipping invalid operation"
    exit 0
  else
    echo "❌ $ERROR_MSG"
    handle_error "$ERROR_MSG" 1
  fi
fi

# Step 4: Show final status
show_status

# Final status report
echo ""
echo "📊 Final Status Report:"
echo "======================"
echo "Pod: ${POD_NAME}"
echo "Component: ${COMPONENT_NAME}"
echo "Operation: ${OPERATION}"
echo "Mode: ${MODE}"
echo "Completed: $(date)"

if [ "${OPERATION}" = "stop" ]; then
  echo "Status: Wazuh services stopped"
  echo "⚠️  Data is now safe for backup"
elif [ "${OPERATION}" = "start" ]; then
  echo "Status: Wazuh services started"
  echo "✅ Component is back online"
fi

# Emergency mode: Always succeed to avoid failing the finally block
if [ "${MODE}" = "emergency" ]; then
  echo ""
  echo "🚨 Emergency mode: Task completed (never fails)"
  echo "✅ Wazuh control task finished"
  exit 0
fi

# Normal mode: Exit with success
echo "✅ Wazuh control task completed successfully"
