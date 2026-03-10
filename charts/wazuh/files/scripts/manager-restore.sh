#!/bin/sh
# manager-restore.sh
#
# Restores a Wazuh Manager configuration backup from S3 by streaming a tar
# archive directly into the manager pod via kubectl exec. No intermediate file
# is written to disk — the S3 object is piped straight to 'tar xzf -' inside
# the pod.
#
# Requires the container image to have both kubectl and aws-cli installed
# (see utils/packages/wazuh-manager-backup/Dockerfile).
#
# kubectl authenticates using the pod's auto-mounted ServiceAccount token.
# The ServiceAccount must be bound to a Role with pods/exec permission in the
# wazuh namespace (see templates/manager/role.manager-backup.yaml).
#
# Required environment variables:
#   MANAGER_POD    Name of the manager-master StatefulSet pod (e.g. release-manager-master-0)
#   NAMESPACE      Kubernetes namespace (injected via Downward API)
#   S3_BUCKET      S3 bucket name
#   BACKUP_FILE    Filename of the backup to restore (e.g. manager-config-20260309-231725.tar.gz)
#
# Optional environment variables (with defaults):
#   S3_REGION      AWS region of the bucket              (default: eu-central-1)
#   S3_BASE_PATH   Prefix inside the bucket              (default: manager-backups)
#
# Read-only paths (ConfigMap mounts) are detected dynamically at restore time by running
# 'find /var/ossec/etc/shared -not -writable' inside the manager pod, so only
# Helm-managed files are skipped — dashboard-configured group files are always restored.

set -eu

# ─── Logging helpers ──────────────────────────────────────────────────────────

log()  { printf '[%s] INFO  %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
warn() { printf '[%s] WARN  %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
err()  { printf '[%s] ERROR %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }

# ─── Required env var validation ─────────────────────────────────────────────

: "${MANAGER_POD:?Required env var MANAGER_POD is not set}"
: "${NAMESPACE:?Required env var NAMESPACE is not set}"
: "${S3_BUCKET:?Required env var S3_BUCKET is not set}"
: "${BACKUP_FILE:?Required env var BACKUP_FILE is not set}"

# ─── Configuration (with defaults) ───────────────────────────────────────────

S3_REGION="${S3_REGION:-eu-central-1}"
S3_BASE_PATH="${S3_BASE_PATH:-manager-backups}"

S3_KEY="${S3_BASE_PATH}/${BACKUP_FILE}"

# ─── Step 1: Configure kubectl in-cluster context ────────────────────────────

log "=== Manager Configuration Restore Starting ==="
log "Backup file:   s3://${S3_BUCKET}/${S3_KEY}"
log "Manager pod:   ${NAMESPACE}/${MANAGER_POD}"
log ""

# Configure kubectl to use the auto-mounted ServiceAccount token
KUBE_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
KUBE_CA=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt

kubectl config set-cluster in-cluster \
  --server=https://kubernetes.default.svc \
  --certificate-authority="${KUBE_CA}" \
  --embed-certs=true > /dev/null 2>&1

kubectl config set-credentials backup-sa \
  --token="${KUBE_TOKEN}" > /dev/null 2>&1

kubectl config set-context in-cluster \
  --cluster=in-cluster \
  --user=backup-sa > /dev/null 2>&1

kubectl config use-context in-cluster > /dev/null 2>&1

log "kubectl configured with in-cluster ServiceAccount credentials."

# ─── Step 2: Verify backup object exists in S3 ───────────────────────────────

log "Verifying backup object exists in S3..."

if ! aws s3 ls "s3://${S3_BUCKET}/${S3_KEY}" \
    --region "${S3_REGION}" > /dev/null 2>&1; then
  err "Backup object not found: s3://${S3_BUCKET}/${S3_KEY}"
  err "List available backups with: aws s3 ls s3://${S3_BUCKET}/${S3_BASE_PATH}/"
  exit 1
fi

log "Backup object found: s3://${S3_BUCKET}/${S3_KEY}"

# ─── Step 3: Verify manager pod is reachable ─────────────────────────────────

log "Verifying manager pod '${MANAGER_POD}' is reachable..."

if ! kubectl get pod "${MANAGER_POD}" -n "${NAMESPACE}" > /dev/null 2>&1; then
  err "Manager pod '${MANAGER_POD}' not found in namespace '${NAMESPACE}'."
  err "Check that the manager StatefulSet is running: kubectl get pods -n ${NAMESPACE}"
  exit 1
fi

POD_PHASE=$(kubectl get pod "${MANAGER_POD}" -n "${NAMESPACE}" \
  -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")

if [ "${POD_PHASE}" != "Running" ]; then
  err "Manager pod '${MANAGER_POD}' is not Running (phase: ${POD_PHASE})."
  err "Cannot exec into a non-running pod. Check pod status and try again."
  exit 1
fi

log "Manager pod is Running."

# ─── Step 4: Stream tar from S3 into the manager pod ─────────────────────────

log "Streaming restore from s3://${S3_BUCKET}/${S3_KEY} into pod..."

# aws s3 cp downloads from S3 and writes to stdout (-).
# kubectl exec reads from stdin (-i) and extracts with tar into the pod filesystem.
# The -C / flag extracts to absolute paths (tar archives strip leading /, so
# var/ossec/etc/ossec.conf lands at /var/ossec/etc/ossec.conf).

# Detect read-only paths under shared/ (ConfigMap mounts) before extracting.
# Only non-writable paths are excluded — dashboard-configured writable group
# configs in the same directory are restored normally.
log "Detecting read-only paths under /var/ossec/etc/shared/..."
READONLY_PATHS=$(kubectl exec -n "${NAMESPACE}" "${MANAGER_POD}" -- \
  find /var/ossec/etc/shared -not -writable -print 2>/dev/null || true)

TAR_EXCLUDE_FLAGS=""
if [ -n "${READONLY_PATHS}" ]; then
  for ABS_PATH in ${READONLY_PATHS}; do
    REL_PATH="${ABS_PATH#/}"
    TAR_EXCLUDE_FLAGS="${TAR_EXCLUDE_FLAGS} --exclude=${REL_PATH}"
    warn "Excluding read-only path (ConfigMap-managed): ${ABS_PATH}"
  done
else
  log "No read-only paths detected under /var/ossec/etc/shared/ — restoring all."
fi

# shellcheck disable=SC2086
if ! aws s3 cp "s3://${S3_BUCKET}/${S3_KEY}" - \
    --region "${S3_REGION}" \
  | kubectl exec -n "${NAMESPACE}" "${MANAGER_POD}" -i -- tar xzf - -C / --overwrite ${TAR_EXCLUDE_FLAGS}; then
  err "Restore stream failed."
  err "Check aws s3 cp permissions and kubectl exec access."
  exit 1
fi

log "Restore stream completed."

# ─── Step 5: Verify key files exist after extraction ─────────────────────────

log "Verifying restored files..."

for FILE in /var/ossec/etc/ossec.conf /var/ossec/etc/client.keys; do
  if kubectl exec -n "${NAMESPACE}" "${MANAGER_POD}" -- \
      test -f "${FILE}" > /dev/null 2>&1; then
    log "  OK: ${FILE}"
  else
    warn "  Not found after restore: ${FILE} (may not have been in the backup)"
  fi
done

# ─── Step 6: Summary ─────────────────────────────────────────────────────────

log ""
log "=== Manager Configuration Restore Completed ==="
log "Restored: s3://${S3_BUCKET}/${S3_KEY}"
log ""
log "IMPORTANT: Restart the manager pod to reload the restored configuration:"
log "  kubectl rollout restart statefulset/${MANAGER_POD%-0} -n ${NAMESPACE}"
