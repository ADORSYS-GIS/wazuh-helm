#!/bin/sh
# s3-snapshot-restore.sh
#
# Restores an OpenSearch snapshot from an S3 repository.
# Designed to run as a one-shot Kubernetes Job triggered via a Helm
# post-install/post-upgrade hook. The job waits for OpenSearch to become
# reachable before proceeding, so it is safe to deploy alongside the Indexer.
#
# Authentication uses the OpenSearch admin TLS certificate (mTLS) rather than
# username/password. The admin certificate bypasses the security plugin entirely,
# granting full cluster access — this is required for privileged operations such
# as closing indices and triggering a snapshot restore.
#
# Required environment variables:
#   OPENSEARCH_URL         Base URL of the OpenSearch API (e.g. https://my-indexer-api:9200)
#   ADMIN_CERT             Path to the admin client certificate (admin.pem)
#   ADMIN_KEY              Path to the admin client key (admin-key.pem)
#   SNAPSHOT_REPOSITORY    Name of the registered S3 snapshot repository (e.g. s3-repo)
#   SNAPSHOT_NAME          Name of the snapshot to restore (e.g. snapshot-20260301)
#
# Optional environment variables (with defaults):
#   CLOSE_INDICES          Close all open indices before restoring     (default: true)
#                          Required when restoring to a cluster that already has data.
#   WAIT_TIMEOUT           Max seconds to wait for OpenSearch to start  (default: 300)
#   CURL_TIMEOUT           Max seconds per curl call                    (default: 600)

set -eu

# ─── Logging helpers ──────────────────────────────────────────────────────────

log()  { printf '[%s] INFO  %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
warn() { printf '[%s] WARN  %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
err()  { printf '[%s] ERROR %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }

# ─── Required env var validation ─────────────────────────────────────────────

: "${OPENSEARCH_URL:?Required env var OPENSEARCH_URL is not set}"
: "${ADMIN_CERT:?Required env var ADMIN_CERT is not set}"
: "${ADMIN_KEY:?Required env var ADMIN_KEY is not set}"
: "${SNAPSHOT_REPOSITORY:?Required env var SNAPSHOT_REPOSITORY is not set}"
: "${SNAPSHOT_NAME:?Required env var SNAPSHOT_NAME is not set}"

if [ -z "$SNAPSHOT_NAME" ]; then
  err "SNAPSHOT_NAME is empty. Specify the snapshot to restore (e.g. snapshot-20260301)."
  exit 1
fi

if [ ! -f "$ADMIN_CERT" ]; then
  err "Admin certificate not found at '${ADMIN_CERT}'."
  exit 1
fi

if [ ! -f "$ADMIN_KEY" ]; then
  err "Admin key not found at '${ADMIN_KEY}'."
  exit 1
fi

# ─── Configuration (with defaults) ───────────────────────────────────────────

CLOSE_INDICES="${CLOSE_INDICES:-true}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-300}"
CURL_TIMEOUT="${CURL_TIMEOUT:-600}"

# ─── OpenSearch API helper ────────────────────────────────────────────────────
# Usage: opensearch_api <METHOD> <PATH> [<JSON_BODY>]
# Returns the response body followed by a newline and the HTTP status code.
# Uses the admin TLS certificate for mTLS authentication, bypassing the
# OpenSearch security plugin and granting full cluster admin access.

opensearch_api() {
  _method="$1"
  _path="$2"
  _body="${3:-}"

  if [ -n "$_body" ]; then
    curl -sk \
      --max-time "${CURL_TIMEOUT}" \
      --cert "${ADMIN_CERT}" \
      --key "${ADMIN_KEY}" \
      -w "\n%{http_code}" \
      -X "${_method}" \
      "${OPENSEARCH_URL}${_path}" \
      -H "Content-Type: application/json" \
      -d "${_body}"
  else
    curl -sk \
      --max-time "${CURL_TIMEOUT}" \
      --cert "${ADMIN_CERT}" \
      --key "${ADMIN_KEY}" \
      -w "\n%{http_code}" \
      -X "${_method}" \
      "${OPENSEARCH_URL}${_path}" \
      -H "Content-Type: application/json"
  fi
}

http_code() { echo "$1" | tail -1; }
body()      { echo "$1" | head -n -1; }

json_str() {
  _key="$1"
  _json="$2"
  echo "$_json" | grep -o "\"${_key}\":\"[^\"]*\"" | head -1 | cut -d'"' -f4
}

json_num() {
  _key="$1"
  _json="$2"
  echo "$_json" | grep -o "\"${_key}\":[0-9]*" | head -1 | cut -d':' -f2
}

# ─── Step 1: Wait for OpenSearch to become reachable ─────────────────────────
# The restore job starts as soon as Helm deploys the resources. The Indexer pod
# may still be initialising, so we poll until it responds or timeout is reached.

log "=== S3 Snapshot Restore Job Starting ==="
log "OpenSearch URL:      ${OPENSEARCH_URL}"
log "Snapshot repository: ${SNAPSHOT_REPOSITORY}"
log "Snapshot name:       ${SNAPSHOT_NAME}"
log "Close indices first: ${CLOSE_INDICES}"
log "Admin cert:          ${ADMIN_CERT}"
log ""
log "Waiting up to ${WAIT_TIMEOUT}s for OpenSearch to become reachable..."

WAIT_START=$(date +%s)

while true; do
  ELAPSED=$(( $(date +%s) - WAIT_START ))
  if [ "$ELAPSED" -ge "$WAIT_TIMEOUT" ]; then
    err "OpenSearch did not become reachable within ${WAIT_TIMEOUT}s."
    err "Check that the Indexer pod started correctly: kubectl logs -n <ns> <indexer-pod>"
    exit 1
  fi

  # Use a short per-request timeout for the readiness probe.
  PROBE=$(curl -sk --max-time 10 \
    --cert "${ADMIN_CERT}" \
    --key "${ADMIN_KEY}" \
    -w "\n%{http_code}" \
    "${OPENSEARCH_URL}/_cluster/health" 2>/dev/null || true)
  PROBE_CODE=$(http_code "$PROBE")

  if [ "$PROBE_CODE" = "200" ]; then
    log "OpenSearch is reachable (${ELAPSED}s elapsed)."
    break
  fi

  log "OpenSearch not ready yet (HTTP ${PROBE_CODE}) — retrying in 10s... (${ELAPSED}/${WAIT_TIMEOUT}s)"
  sleep 10
done

# ─── Step 2: Cluster health check ────────────────────────────────────────────

log "Checking cluster health (waiting up to 60s for yellow/green)..."
HEALTH_RESP=$(opensearch_api GET "/_cluster/health?wait_for_status=yellow&timeout=60s")
HEALTH_CODE=$(http_code "$HEALTH_RESP")
HEALTH_BODY=$(body "$HEALTH_RESP")

if [ "$HEALTH_CODE" != "200" ]; then
  err "Cluster health check failed (HTTP ${HEALTH_CODE}): ${HEALTH_BODY}"
  exit 1
fi

CLUSTER_STATUS=$(json_str "status" "$HEALTH_BODY")
log "Cluster status: ${CLUSTER_STATUS}"

if [ "$CLUSTER_STATUS" = "red" ]; then
  err "Cluster is in RED state. A restore into a degraded cluster may cause data loss."
  err "Resolve the cluster health issue before retrying the restore."
  exit 1
fi

# ─── Step 3: Verify snapshot repository ──────────────────────────────────────

log "Verifying snapshot repository '${SNAPSHOT_REPOSITORY}'..."
REPO_RESP=$(opensearch_api GET "/_snapshot/${SNAPSHOT_REPOSITORY}")
REPO_CODE=$(http_code "$REPO_RESP")

case "$REPO_CODE" in
  200)
    log "Repository '${SNAPSHOT_REPOSITORY}' exists." ;;
  404)
    err "Snapshot repository '${SNAPSHOT_REPOSITORY}' not found."
    err "Register it first: PUT /_snapshot/${SNAPSHOT_REPOSITORY} with S3 settings."
    exit 1 ;;
  *)
    err "Unexpected response verifying repository (HTTP ${REPO_CODE}): $(body "$REPO_RESP")"
    exit 1 ;;
esac

# ─── Step 4: Verify the target snapshot exists and is usable ─────────────────

log "Verifying snapshot '${SNAPSHOT_NAME}' exists and is in SUCCESS state..."
SNAP_RESP=$(opensearch_api GET "/_snapshot/${SNAPSHOT_REPOSITORY}/${SNAPSHOT_NAME}")
SNAP_CODE=$(http_code "$SNAP_RESP")
SNAP_BODY=$(body "$SNAP_RESP")

case "$SNAP_CODE" in
  200) ;;
  404)
    err "Snapshot '${SNAPSHOT_NAME}' not found in repository '${SNAPSHOT_REPOSITORY}'."
    err "List available snapshots: GET /_snapshot/${SNAPSHOT_REPOSITORY}/_all"
    exit 1 ;;
  *)
    err "Unexpected response checking snapshot (HTTP ${SNAP_CODE}): ${SNAP_BODY}"
    exit 1 ;;
esac

SNAP_STATE=$(json_str "state" "$SNAP_BODY")
log "Snapshot '${SNAPSHOT_NAME}' state: ${SNAP_STATE}"

if [ "$SNAP_STATE" != "SUCCESS" ]; then
  err "Snapshot '${SNAPSHOT_NAME}' is not in SUCCESS state (got: '${SNAP_STATE}')."
  err "Only SUCCESS snapshots can be restored safely."
  exit 1
fi

# ─── Step 5: Close all indices (if requested) ─────────────────────────────────
# Restoring over existing open indices is not allowed in OpenSearch.
# Closing them first allows the restore to write over them.
# With mTLS admin cert auth this operation is always permitted.

if [ "$CLOSE_INDICES" = "true" ]; then
  log "Closing all open indices before restore (including hidden/system indices)..."
  CLOSE_RESP=$(opensearch_api POST "/_all/_close?expand_wildcards=all")
  CLOSE_CODE=$(http_code "$CLOSE_RESP")
  CLOSE_BODY=$(body "$CLOSE_RESP")

  case "$CLOSE_CODE" in
    200)
      log "All indices closed successfully." ;;
    404)
      # No indices exist yet (fresh cluster) — nothing to close.
      log "No indices to close (fresh cluster). Proceeding." ;;
    *)
      err "Failed to close indices (HTTP ${CLOSE_CODE}): ${CLOSE_BODY}"
      err "You may need to close indices manually before retrying."
      exit 1 ;;
  esac
else
  warn "CLOSE_INDICES is false. Restore will fail if any target indices are currently open."
fi

# ─── Step 6: Trigger restore ─────────────────────────────────────────────────

RESTORE_BODY='{"indices":"*","ignore_unavailable":true,"include_global_state":false}'

log "Triggering restore of snapshot '${SNAPSHOT_NAME}' (waiting for completion)..."
log "This may take several minutes depending on snapshot size."

RESTORE_RESP=$(opensearch_api POST \
  "/_snapshot/${SNAPSHOT_REPOSITORY}/${SNAPSHOT_NAME}/_restore?wait_for_completion=true" \
  "${RESTORE_BODY}")
RESTORE_CODE=$(http_code "$RESTORE_RESP")
RESTORE_BODY_RESP=$(body "$RESTORE_RESP")

log "Response (HTTP ${RESTORE_CODE}): ${RESTORE_BODY_RESP}"

if [ "$RESTORE_CODE" != "200" ]; then
  err "Restore API returned HTTP ${RESTORE_CODE}."
  exit 1
fi

# ─── Step 7: Validate restore results ────────────────────────────────────────

TOTAL_SHARDS=$(json_num "total" "$RESTORE_BODY_RESP")
FAILED_SHARDS=$(json_num "failed" "$RESTORE_BODY_RESP")
SUCCESSFUL_SHARDS=$(json_num "successful" "$RESTORE_BODY_RESP")

log "─────────────────────────────────────────"
log "Restore results:"
log "  Total shards:      ${TOTAL_SHARDS:-unknown}"
log "  Successful shards: ${SUCCESSFUL_SHARDS:-unknown}"
log "  Failed shards:     ${FAILED_SHARDS:-0}"
log "─────────────────────────────────────────"

if [ -n "$FAILED_SHARDS" ] && [ "$FAILED_SHARDS" -gt 0 ]; then
  err "${FAILED_SHARDS} shard(s) failed to restore. Review the response above for details."
  err "=== S3 Snapshot Restore Job Completed with Errors ==="
  exit 1
fi

log "Snapshot '${SNAPSHOT_NAME}' restored successfully."
log "=== S3 Snapshot Restore Job Completed ==="
exit 0
