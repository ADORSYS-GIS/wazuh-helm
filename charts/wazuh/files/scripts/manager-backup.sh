#!/bin/sh
# manager-backup.sh
#
# Backs up Wazuh Manager configuration files to S3 by streaming a tar archive
# directly from the manager pod via kubectl exec. No intermediate file is written
# to disk — the tar output is piped straight to 'aws s3 cp'.
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
#   HELM_RELEASE   Helm release name (used for helm get values)
#
# Optional environment variables (with defaults):
#   S3_REGION      AWS region of the bucket              (default: eu-central-1)
#   S3_BASE_PATH   Prefix inside the bucket              (default: manager-backups)
#   RETENTION_DAYS Delete objects older than N days       (default: 30)
#   BACKUP_PATHS   Space-separated paths to tar           (default: all critical paths)
#   HELM_NAMESPACE    Namespace for helm get values           (default: $NAMESPACE)
#   HELM_FULLNAME     Helm fullname (release + chart, e.g. wazuh-wazuh-helm) injected
#                     by the CronJob template; used as prefix for chart-generated secrets
#   CRITICAL_SECRETS  Space-separated secret names to back up individually
#                     (default: wazuh-root-ca + HELM_FULLNAME-prefixed chart secrets)

set -eu

# ─── Logging helpers ──────────────────────────────────────────────────────────

log()  { printf '[%s] INFO  %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
warn() { printf '[%s] WARN  %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
err()  { printf '[%s] ERROR %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }

# ─── Required env var validation ─────────────────────────────────────────────

: "${MANAGER_POD:?Required env var MANAGER_POD is not set}"
: "${NAMESPACE:?Required env var NAMESPACE is not set}"
: "${S3_BUCKET:?Required env var S3_BUCKET is not set}"
: "${HELM_RELEASE:?Required env var HELM_RELEASE is not set}"

# ─── Configuration (with defaults) ───────────────────────────────────────────

S3_REGION="${S3_REGION:-eu-central-1}"
S3_BASE_PATH="${S3_BASE_PATH:-manager-backups}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
BACKUP_PATHS="${BACKUP_PATHS:-/var/ossec/etc/ossec.conf /var/ossec/etc/client.keys /var/ossec/etc/rules/ /var/ossec/etc/decoders/ /var/ossec/etc/lists/ /var/ossec/etc/shared/}"
HELM_NAMESPACE="${HELM_NAMESPACE:-${NAMESPACE}}"
# Helm fullname is injected by the CronJob template as HELM_FULLNAME.
# Falls back to HELM_RELEASE if not set (e.g. when running the script manually).
HELM_FULLNAME="${HELM_FULLNAME:-${HELM_RELEASE}}"
# Critical secrets to back up individually (for easy targeted restore).
# Defaults to wazuh-root-ca (fixed name) plus the fullname-prefixed secrets
# created by the chart. Override with CRITICAL_SECRETS if your cluster differs.
CRITICAL_SECRETS="${CRITICAL_SECRETS:-wazuh-root-ca ${HELM_FULLNAME}-api-cred ${HELM_FULLNAME}-indexer-cred ${HELM_FULLNAME}-certificates ${HELM_FULLNAME}-dashboard-cred}"

BACKUP_DATE=$(date -u '+%Y%m%d-%H%M%S')
BACKUP_FILE="manager-config-${BACKUP_DATE}.tar.gz"
S3_KEY="${S3_BASE_PATH}/${BACKUP_FILE}"

# ─── Step 1: Configure kubectl in-cluster context ────────────────────────────

log "=== Manager Configuration Backup Starting ==="
log "Manager pod:  ${NAMESPACE}/${MANAGER_POD}"
log "S3 target:    s3://${S3_BUCKET}/${S3_KEY}"
log "Backup paths: ${BACKUP_PATHS}"
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

# ─── Step 2: Verify manager pod is reachable ─────────────────────────────────

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

# ─── Step 3: Stream tar directly to S3 ───────────────────────────────────────

log "Streaming backup to s3://${S3_BUCKET}/${S3_KEY}..."

# kubectl exec tars the paths inside the manager pod and writes to stdout.
# aws s3 cp reads from stdin (-) and uploads directly to S3.
# The pipe means no intermediate file is written locally.
# shellcheck disable=SC2086
if ! kubectl exec -n "${NAMESPACE}" "${MANAGER_POD}" -- \
    tar czf - ${BACKUP_PATHS} 2>/dev/null \
  | aws s3 cp - "s3://${S3_BUCKET}/${S3_KEY}" \
      --region "${S3_REGION}" \
      --no-progress; then
  err "Backup stream to S3 failed."
  err "Check kubectl exec permissions and AWS credentials."
  exit 1
fi

log "Backup uploaded successfully."

# ─── Step 4: Verify the object exists in S3 ──────────────────────────────────

log "Verifying object exists in S3..."

if ! aws s3 ls "s3://${S3_BUCKET}/${S3_KEY}" \
    --region "${S3_REGION}" > /dev/null 2>&1; then
  err "Object not found in S3 after upload: s3://${S3_BUCKET}/${S3_KEY}"
  exit 1
fi

log "Verification succeeded: s3://${S3_BUCKET}/${S3_KEY}"

# ─── Step 5: Back up Kubernetes secrets ──────────────────────────────────────

log "=== Backing up Kubernetes secrets ==="

SECRETS_FILE="secrets-${BACKUP_DATE}.yaml"
S3_SECRETS_KEY="${S3_BASE_PATH}/${SECRETS_FILE}"

if ! kubectl get secrets -n "${NAMESPACE}" -o yaml \
    | aws s3 cp - "s3://${S3_BUCKET}/${S3_SECRETS_KEY}" \
        --region "${S3_REGION}" --no-progress; then
  warn "Failed to upload secrets dump — continuing."
else
  log "Secrets dump uploaded: s3://${S3_BUCKET}/${S3_SECRETS_KEY}"
fi

# Individual critical secrets for easy targeted restore
# shellcheck disable=SC2086
for SECRET in ${CRITICAL_SECRETS}; do
  if kubectl get secret "${SECRET}" -n "${NAMESPACE}" > /dev/null 2>&1; then
    kubectl get secret "${SECRET}" -n "${NAMESPACE}" -o yaml \
      | aws s3 cp - "s3://${S3_BUCKET}/${S3_BASE_PATH}/secrets/${SECRET}-${BACKUP_DATE}.yaml" \
          --region "${S3_REGION}" --no-progress
    log "  Backed up secret: ${SECRET}"
  else
    log "  Secret not found, skipping: ${SECRET}"
  fi
done

# ─── Step 6: Back up Helm release values ─────────────────────────────────────

log "=== Backing up Helm release values ==="

if ! command -v helm > /dev/null 2>&1; then
  warn "helm binary not found — skipping Helm values backup."
else
  HELM_VALUES=$(helm get values "${HELM_RELEASE}" -n "${HELM_NAMESPACE}" 2>&1) || {
    warn "helm get values failed — continuing. Output: ${HELM_VALUES}"
    HELM_VALUES=""
  }
  if [ -n "${HELM_VALUES}" ]; then
    if ! printf '%s\n' "${HELM_VALUES}" \
        | aws s3 cp - "s3://${S3_BUCKET}/${S3_BASE_PATH}/helm-values-${BACKUP_DATE}.yaml" \
            --region "${S3_REGION}" --no-progress; then
      warn "Failed to upload helm values — continuing."
    else
      log "Helm user values uploaded."
    fi
  else
    warn "helm get values returned empty output — skipping upload."
  fi

  HELM_VALUES_ALL=$(helm get values "${HELM_RELEASE}" -n "${HELM_NAMESPACE}" --all 2>&1) || {
    warn "helm get values --all failed — continuing."
    HELM_VALUES_ALL=""
  }
  if [ -n "${HELM_VALUES_ALL}" ]; then
    if ! printf '%s\n' "${HELM_VALUES_ALL}" \
        | aws s3 cp - "s3://${S3_BUCKET}/${S3_BASE_PATH}/helm-values-all-${BACKUP_DATE}.yaml" \
            --region "${S3_REGION}" --no-progress; then
      warn "Failed to upload helm values (--all) — continuing."
    else
      log "Helm all values uploaded."
    fi
  else
    warn "helm get values --all returned empty output — skipping upload."
  fi
fi

# ─── Step 7: Create backup manifest ──────────────────────────────────────────

log "=== Creating backup manifest ==="

SECRET_COUNT=$(kubectl get secrets -n "${NAMESPACE}" --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo 0)

# Write the manifest as YAML then stream it to S3
{
  printf 'backup_date: %s\n' "${BACKUP_DATE}"
  printf 'manager_pod: %s\n' "${MANAGER_POD}"
  printf 'namespace: %s\n'   "${NAMESPACE}"
  printf 's3_bucket: %s\n'   "${S3_BUCKET}"
  printf 's3_base_path: %s\n' "${S3_BASE_PATH}"
  printf 'helm_release: %s\n' "${HELM_RELEASE}"
  printf 'items:\n'
  printf '  - manager_config: %s\n'  "${BACKUP_FILE}"
  printf '  - secrets_dump: %s\n'    "${SECRETS_FILE}"
  printf '  - helm_values: helm-values-%s.yaml\n'     "${BACKUP_DATE}"
  printf '  - helm_values_all: helm-values-all-%s.yaml\n' "${BACKUP_DATE}"
  printf 'secret_count: %s\n' "${SECRET_COUNT}"
} | aws s3 cp - "s3://${S3_BUCKET}/${S3_BASE_PATH}/manifest-${BACKUP_DATE}.yaml" \
      --region "${S3_REGION}" --no-progress

log "Manifest uploaded: s3://${S3_BUCKET}/${S3_BASE_PATH}/manifest-${BACKUP_DATE}.yaml"

# ─── Step 8: Retention cleanup ───────────────────────────────────────────────

log "Enforcing retention policy: deleting backups older than ${RETENTION_DAYS} days..."

CUTOFF_EPOCH=$(( $(date -u +%s) - RETENTION_DAYS * 86400 ))
CUTOFF_DATE=$(date -u -d "@${CUTOFF_EPOCH}" '+%Y%m%d' 2>/dev/null \
  || date -u -r "${CUTOFF_EPOCH}" '+%Y%m%d' 2>/dev/null \
  || echo "00000000")

DELETED=0
KEPT=0
FAILED=0

# List all objects under the backup prefix, extract the filename from each line.
# grep -v '^.*PRE ' filters out subdirectory prefix lines (e.g. "PRE secrets/").
aws s3 ls "s3://${S3_BUCKET}/${S3_BASE_PATH}/" --region "${S3_REGION}" 2>/dev/null | \
grep -v ' PRE ' | \
while read -r _ _ _ OBJECT_NAME; do
  # Extract first 8-digit sequence from the filename as YYYYMMDD
  OBJECT_DATE=$(echo "${OBJECT_NAME}" | grep -o '[0-9]\{8\}' | head -1)

  if [ -z "${OBJECT_DATE}" ]; then
    log "Skipping '${OBJECT_NAME}' — no date found in name."
    KEPT=$(( KEPT + 1 ))
    continue
  fi

  if [ "${OBJECT_DATE}" -lt "${CUTOFF_DATE}" ]; then
    log "Deleting old backup: ${OBJECT_NAME} (date: ${OBJECT_DATE}, cutoff: ${CUTOFF_DATE})"
    if aws s3 rm "s3://${S3_BUCKET}/${S3_BASE_PATH}/${OBJECT_NAME}" \
        --region "${S3_REGION}" > /dev/null 2>&1; then
      DELETED=$(( DELETED + 1 ))
    else
      warn "Failed to delete: ${OBJECT_NAME}"
      FAILED=$(( FAILED + 1 ))
    fi
  else
    KEPT=$(( KEPT + 1 ))
  fi
done

log "Retention cleanup complete."

# ─── Step 9: Summary ─────────────────────────────────────────────────────────

log ""
log "=== Manager Configuration Backup Completed ==="
log "Backup: s3://${S3_BUCKET}/${S3_KEY}"
exit 0
