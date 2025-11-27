#!/bin/bash

# Constants
readonly JSONPATH_SPEC_REPLICAS='{.spec.replicas}'
readonly JSONPATH_READY_REPLICAS='{.status.readyReplicas}'

# Set error handling based on mode
if [[ "${MODE}" = "emergency" ]]; then
  # Emergency mode: lenient error handling
  set -eu
  echo "🚨 EMERGENCY MODE: Lenient error handling active" >&2
else
  # Normal mode: strict error handling
  set -eux
  echo "⚙️  NORMAL MODE: Strict error handling active" >&2
fi

echo "🔄 Starting StatefulSet scaling operation"
echo "StatefulSet: ${STATEFULSET_NAME}"
echo "Namespace: ${NAMESPACE}"
echo "Target Replicas: ${REPLICAS}"
echo "Mode: ${MODE}"
echo "Component: ${COMPONENT_NAME}"
echo "Pipeline Status: ${PIPELINE_STATUS}"
echo "Timestamp: $(date)"
echo "================================"

# Function for emergency mode error handling
emergency_handle_error() {
  local error_msg="$1"

  echo "⚠️  Emergency mode error: $error_msg" >&2
  echo "💡 Attempting recovery strategies..." >&2

  # Don't exit in emergency mode - log and continue
  echo "🔄 Continuing with emergency recovery..." >&2
  return 0
}

# Function for normal mode error handling
normal_handle_error() {
  local error_msg="$1"
  local exit_code="$2"

  echo "❌ Normal mode error: $error_msg" >&2
  echo "🛑 Failing pipeline due to error" >&2
  exit "$exit_code"
}

# Unified error handler
handle_error() {
  local error_msg="$1"
  local exit_code="${2:-1}"

  if [[ "${MODE}" = "emergency" ]]; then
    emergency_handle_error "$error_msg"
  else
    normal_handle_error "$error_msg" "$exit_code"
  fi
  return 0
}

# Check if StatefulSet exists
echo "🔍 Checking if StatefulSet exists..."
if ! kubectl get statefulset "${STATEFULSET_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
  ERROR_MSG="StatefulSet ${STATEFULSET_NAME} not found in namespace ${NAMESPACE}"

  if [[ "${MODE}" = "emergency" ]]; then
    echo "⚠️  $ERROR_MSG" >&2
    echo "🔍 Available StatefulSets in namespace:" >&2
    kubectl get statefulsets -n "${NAMESPACE}" || echo "No StatefulSets found" >&2
    echo "🔄 Emergency mode: Continuing despite missing StatefulSet" >&2
    echo "✅ Emergency scaling completed (no action possible)"
    exit 0
  else
    echo "❌ $ERROR_MSG" >&2
    echo "🔍 Available StatefulSets:" >&2
    kubectl get statefulsets -n "${NAMESPACE}" >&2
    handle_error "$ERROR_MSG" 1
  fi
fi

# Get current state
echo "📊 Checking current StatefulSet state..."
CURRENT_REPLICAS=$(kubectl get statefulset "${STATEFULSET_NAME}" -n "${NAMESPACE}" -o jsonpath="${JSONPATH_SPEC_REPLICAS}" 2>/dev/null || echo "0")
READY_REPLICAS=$(kubectl get statefulset "${STATEFULSET_NAME}" -n "${NAMESPACE}" -o jsonpath="${JSONPATH_READY_REPLICAS}" 2>/dev/null || echo "0")

echo "📊 Current state:"
echo "Current replicas: ${CURRENT_REPLICAS}"
echo "Ready replicas: ${READY_REPLICAS}"
echo "Target replicas: ${REPLICAS}"

# Emergency mode: Check if scaling is actually needed
if [[ "${MODE}" = "emergency" ]]; then
  if [[ "${CURRENT_REPLICAS}" = "${REPLICAS}" ]] && [[ "${READY_REPLICAS}" = "${REPLICAS}" ]]; then
    echo "✅ StatefulSet is already correctly scaled (${READY_REPLICAS}/${REPLICAS})"
    echo "🎉 No emergency action needed - service is healthy!"
    echo ""
    echo "📊 Emergency Recovery Report:"
    echo "=============================="
    echo "StatefulSet: ${STATEFULSET_NAME}"
    echo "Component: ${COMPONENT_NAME}"
    echo "Pipeline Status: ${PIPELINE_STATUS}"
    echo "Final State: ${READY_REPLICAS}/${REPLICAS} (Healthy)"
    echo "Action Taken: None required"
    echo "Recovery Time: $(date)"
    echo "✅ Emergency scaling completed successfully"
    exit 0
  else
    echo "⚠️  StatefulSet needs emergency scaling!"
    echo "Current: ${CURRENT_REPLICAS}, Ready: ${READY_REPLICAS}, Target: ${REPLICAS}"
  fi
fi

# Perform scaling operation
echo "🔧 Scaling StatefulSet ${STATEFULSET_NAME} → ${REPLICAS} replicas..."

if ! kubectl scale statefulset "${STATEFULSET_NAME}" -n "${NAMESPACE}" --replicas="${REPLICAS}"; then
  ERROR_MSG="Failed to scale StatefulSet ${STATEFULSET_NAME}"

  if [[ "${MODE}" = "emergency" ]]; then
    echo "⚠️  $ERROR_MSG" >&2
    echo "🔍 StatefulSet details:" >&2
    kubectl describe statefulset "${STATEFULSET_NAME}" -n "${NAMESPACE}" >&2 || echo "Cannot describe StatefulSet" >&2
    echo "🔄 Emergency mode: Attempting alternative recovery..." >&2

    # Try to get current state again
    RETRY_REPLICAS=$(kubectl get statefulset "${STATEFULSET_NAME}" -n "${NAMESPACE}" -o jsonpath="${JSONPATH_SPEC_REPLICAS}" 2>/dev/null || echo "unknown")
    if [[ "${RETRY_REPLICAS}" = "${REPLICAS}" ]]; then
      echo "✅ Scale command may have succeeded despite error"
    else
      echo "❌ Scale command definitely failed"
      echo "💡 Manual intervention may be required"
    fi

    # Don't exit in emergency mode - continue with status report
    echo "🔄 Continuing with emergency recovery completion..." >&2
  else
    echo "❌ $ERROR_MSG" >&2
    echo "🔍 StatefulSet details:" >&2
    kubectl describe statefulset "${STATEFULSET_NAME}" -n "${NAMESPACE}" >&2
    handle_error "$ERROR_MSG" 1
  fi
else
  echo "✅ Scale command executed successfully"
fi

# Wait for rollout if scaling up (and not in emergency mode with errors)
if [[ "${REPLICAS}" != "0" ]]; then
  echo "⏳ Waiting for StatefulSet rollout to complete..."

  if [[ "${MODE}" = "emergency" ]]; then
    echo "🚨 Emergency mode: Shorter timeout for rollout"
    TIMEOUT="180s"
  else
    echo "⚙️  Normal mode: Standard timeout for rollout"
    TIMEOUT="300s"
  fi

  echo "Timeout: ${TIMEOUT}"

  if kubectl rollout status statefulset/"${STATEFULSET_NAME}" -n "${NAMESPACE}" --timeout="${TIMEOUT}"; then
    echo "🎉 StatefulSet rollout completed successfully!"
  else
    ERROR_MSG="StatefulSet rollout timed out or failed"

    echo "⚠️  $ERROR_MSG"
    echo "🔍 Current pod status:"
    kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name="${STATEFULSET_NAME}" -o wide 2>/dev/null || echo "Cannot get pods"
    echo ""
    echo "🔍 StatefulSet status:"
    kubectl describe statefulset "${STATEFULSET_NAME}" -n "${NAMESPACE}" 2>/dev/null || echo "Cannot describe StatefulSet"

    if [[ "${MODE}" = "emergency" ]]; then
      echo "🚨 Emergency mode: Checking if scaling succeeded despite timeout..." >&2

      # Check final state
      FINAL_REPLICAS=$(kubectl get statefulset "${STATEFULSET_NAME}" -n "${NAMESPACE}" -o jsonpath="${JSONPATH_SPEC_REPLICAS}" 2>/dev/null || echo "0")
      FINAL_READY=$(kubectl get statefulset "${STATEFULSET_NAME}" -n "${NAMESPACE}" -o jsonpath="${JSONPATH_READY_REPLICAS}" 2>/dev/null || echo "0")

      if [[ "${FINAL_REPLICAS}" = "${REPLICAS}" ]]; then
        echo "✅ StatefulSet spec is correct (${FINAL_REPLICAS}/${REPLICAS}), pods may still be starting"
        echo "🔄 Emergency mode: Considering this a partial success"
      else
        echo "❌ StatefulSet scaling failed completely in emergency mode"
        echo "💡 Manual intervention required"
      fi
    else
      echo "💡 Normal mode: Checking final state..."

      # Check final state
      FINAL_REPLICAS=$(kubectl get statefulset "${STATEFULSET_NAME}" -n "${NAMESPACE}" -o jsonpath="${JSONPATH_SPEC_REPLICAS}" 2>/dev/null || echo "0")
      FINAL_READY=$(kubectl get statefulset "${STATEFULSET_NAME}" -n "${NAMESPACE}" -o jsonpath="${JSONPATH_READY_REPLICAS}" 2>/dev/null || echo "0")

      if [[ "${FINAL_REPLICAS}" = "${REPLICAS}" ]]; then
        echo "✅ StatefulSet spec is correct, pods may still be starting"
        echo "🔄 Continuing with pipeline..."
      else
        echo "❌ StatefulSet scaling failed completely"
        handle_error "$ERROR_MSG" 1
      fi
    fi
  fi
else
  echo "⏳ Waiting for pods to terminate..."
  # Give some time for pods to terminate gracefully
  sleep 10

  REMAINING_PODS=$(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name="${STATEFULSET_NAME}" --no-headers 2>/dev/null | wc -l)
  if [[ "${REMAINING_PODS}" -eq 0 ]]; then
    echo "✅ All pods terminated successfully"
  else
    echo "⚠️  ${REMAINING_PODS} pods still exist"
    kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name="${STATEFULSET_NAME}" 2>/dev/null || echo "Cannot list pods"

    if [[ "${MODE}" = "normal" ]]; then
      echo "🔄 Normal mode: Continuing despite remaining pods..."
    else
      echo "🚨 Emergency mode: Accepting partial termination..."
    fi
  fi
fi

# Final status report
echo ""
echo "📊 Final Status Report:"
echo "======================"
FINAL_REPLICAS=$(kubectl get statefulset "${STATEFULSET_NAME}" -n "${NAMESPACE}" -o jsonpath="${JSONPATH_SPEC_REPLICAS}" 2>/dev/null || echo "unknown")
FINAL_READY=$(kubectl get statefulset "${STATEFULSET_NAME}" -n "${NAMESPACE}" -o jsonpath="${JSONPATH_READY_REPLICAS}" 2>/dev/null || echo "unknown")

echo "StatefulSet: ${STATEFULSET_NAME}"
echo "Component: ${COMPONENT_NAME}"
echo "Mode: ${MODE}"
echo "Final Replicas: ${FINAL_REPLICAS}"
echo "Ready Replicas: ${FINAL_READY}"
echo "Target Replicas: ${REPLICAS}"
echo "Pipeline Status: ${PIPELINE_STATUS}"

if [[ "${FINAL_REPLICAS}" = "${REPLICAS}" ]]; then
  echo "Status: SUCCESS"
  echo "✅ Scale operation completed successfully"
else
  echo "Status: PARTIAL"
  if [[ "${MODE}" = "emergency" ]]; then
    echo "⚠️  Emergency scaling completed with warnings"
    echo "💡 Manual verification recommended"
  else
    echo "⚠️  Normal scaling completed with warnings"
  fi
fi

echo "Completed: $(date)"

# Emergency mode: Always succeed to avoid failing the finally block
if [[ "${MODE}" = "emergency" ]]; then
  echo ""
  echo "🚨 Emergency mode: Task completed (never fails)"
  echo "✅ Emergency scaling task finished"
  exit 0
fi

# Normal mode: Exit with success
echo "✅ Normal scaling task completed"
exit 0