#!/bin/sh
# s3-snapshot-cleanup.sh
#
# Deletes OpenSearch snapshots older than RETENTION_DAYS from an S3 repository.
# Designed to run as a Kubernetes CronJob in a production environment.
#
# Snapshot names must contain an 8-digit date (YYYYMMDD) to be eligible for
# age-based deletion. Snapshots whose names contain no such date are skipped
# and preserved — this protects any manually-created snapshots with custom names.
#
# Required environment variables:
#   OPENSEARCH_URL         Base URL of the OpenSearch API (e.g. https://my-indexer-api:9200)
#   OPENSEARCH_USERNAME    OpenSearch admin username
#   OPENSEARCH_PASSWORD    OpenSearch admin password
#   SNAPSHOT_REPOSITORY    Name of the registered S3 snapshot repository (e.g. s3-repo)
#
# Optional environment variables (with defaults):
#   RETENTION_DAYS         Delete snapshots older than this many days  (default: 30)
#   CURL_TIMEOUT           Max seconds per curl call                   (default: 300)

set -eu

# ─── Logging helpers ──────────────────────────────────────────────────────────

log()  { printf '[%s] INFO  %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
warn() { printf '[%s] WARN  %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
err()  { printf '[%s] ERROR %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }

# ─── Required env var validation ─────────────────────────────────────────────

: "${OPENSEARCH_URL:?Required env var OPENSEARCH_URL is not set}"
: "${OPENSEARCH_USERNAME:?Required env var OPENSEARCH_USERNAME is not set}"
: "${OPENSEARCH_PASSWORD:?Required env var OPENSEARCH_PASSWORD is not set}"
: "${SNAPSHOT_REPOSITORY:?Required env var SNAPSHOT_REPOSITORY is not set}"

# ─── Configuration (with defaults) ───────────────────────────────────────────

RETENTION_DAYS="${RETENTION_DAYS:-30}"
CURL_TIMEOUT="${CURL_TIMEOUT:-300}"

# ─── OpenSearch API helper ────────────────────────────────────────────────────
# Usage: opensearch_api <METHOD> <PATH>
# Returns the response body followed by a newline and the HTTP status code.
# Credentials are passed as direct curl arguments — never interpolated into
# a shell string — so special characters in passwords are handled safely.

opensearch_api() {
  _method="$1"
  _path="$2"

  curl -sk \
    --max-time "${CURL_TIMEOUT}" \
    -u "${OPENSEARCH_USERNAME}:${OPENSEARCH_PASSWORD}" \
    -w "\n%{http_code}" \
    -X "${_method}" \
    "${OPENSEARCH_URL}${_path}" \
    -H "Content-Type: application/json"
}

http_code() { echo "$1" | tail -1; }
body()      { echo "$1" | head -n -1; }

json_str() {
  _key="$1"
  _json="$2"
  echo "$_json" | grep -o "\"${_key}\":\"[^\"]*\"" | head -1 | cut -d'"' -f4
}

# ─── Step 1: Cluster health check ────────────────────────────────────────────

log "=== S3 Snapshot Cleanup Job Starting ==="
log "OpenSearch URL:      ${OPENSEARCH_URL}"
log "Snapshot repository: ${SNAPSHOT_REPOSITORY}"
log "Retention:           ${RETENTION_DAYS} days"

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
  err "Cluster is in RED state. Aborting cleanup to avoid deleting snapshots during degraded state."
  exit 1
fi

# ─── Step 2: Verify snapshot repository ──────────────────────────────────────

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

# ─── Step 3: Compute the cutoff date ─────────────────────────────────────────
# Alpine BusyBox date supports: date -d @<epoch>

CUTOFF_EPOCH=$(($(date +%s) - RETENTION_DAYS * 86400))
CUTOFF_DATE=$(date -u -d "@${CUTOFF_EPOCH}" '+%Y%m%d')
log "Cutoff date: ${CUTOFF_DATE} (snapshots with an earlier date will be deleted)"

# ─── Step 4: List all snapshots ───────────────────────────────────────────────

log "Listing all snapshots in '${SNAPSHOT_REPOSITORY}'..."
LIST_RESP=$(opensearch_api GET "/_snapshot/${SNAPSHOT_REPOSITORY}/_all")
LIST_CODE=$(http_code "$LIST_RESP")
LIST_BODY=$(body "$LIST_RESP")

if [ "$LIST_CODE" = "404" ]; then
  log "No snapshots found in repository '${SNAPSHOT_REPOSITORY}'. Nothing to clean up."
  log "=== S3 Snapshot Cleanup Job Completed (nothing to do) ==="
  exit 0
fi

if [ "$LIST_CODE" != "200" ]; then
  err "Failed to list snapshots (HTTP ${LIST_CODE}): ${LIST_BODY}"
  exit 1
fi

# Extract all snapshot names (one per line).
# Matches the "snapshot":"<name>" field in the JSON array.
SNAPSHOT_NAMES=$(echo "$LIST_BODY" | grep -o '"snapshot":"[^"]*"' | cut -d'"' -f4)

if [ -z "$SNAPSHOT_NAMES" ]; then
  log "Repository is empty. Nothing to clean up."
  log "=== S3 Snapshot Cleanup Job Completed (nothing to do) ==="
  exit 0
fi

TOTAL=$(echo "$SNAPSHOT_NAMES" | wc -l)
log "Found ${TOTAL} snapshot(s) in repository."

# ─── Step 5: Delete old snapshots ────────────────────────────────────────────

COUNT_DELETED=0
COUNT_SKIPPED=0
COUNT_FAILED=0

echo "$SNAPSHOT_NAMES" | while read -r SNAP_NAME; do
  # Extract the first 8-digit sequence as the snapshot date (YYYYMMDD).
  # This handles names like:
  #   snapshot-20260101           → 20260101
  #   snapshot-20260101-120000    → 20260101 (time suffix ignored)
  DATE_PART=$(echo "$SNAP_NAME" | grep -o '[0-9]\{8\}' | head -1)

  if [ -z "$DATE_PART" ]; then
    warn "Snapshot '${SNAP_NAME}' has no 8-digit date in its name — skipping (manually-named snapshot)."
    COUNT_SKIPPED=$((COUNT_SKIPPED + 1))
    continue
  fi

  # Integer comparison: YYYYMMDD strings are lexicographically and numerically ordered.
  if [ "$DATE_PART" -ge "$CUTOFF_DATE" ]; then
    log "Keeping  '${SNAP_NAME}' (date ${DATE_PART} is within retention window)."
    COUNT_SKIPPED=$((COUNT_SKIPPED + 1))
    continue
  fi

  log "Deleting '${SNAP_NAME}' (date ${DATE_PART} is older than cutoff ${CUTOFF_DATE})..."
  DEL_RESP=$(opensearch_api DELETE "/_snapshot/${SNAPSHOT_REPOSITORY}/${SNAP_NAME}")
  DEL_CODE=$(http_code "$DEL_RESP")
  DEL_BODY=$(body "$DEL_RESP")

  if [ "$DEL_CODE" = "200" ]; then
    log "Deleted  '${SNAP_NAME}' successfully."
    COUNT_DELETED=$((COUNT_DELETED + 1))
  else
    err "Failed to delete '${SNAP_NAME}' (HTTP ${DEL_CODE}): ${DEL_BODY}"
    COUNT_FAILED=$((COUNT_FAILED + 1))
    # Continue processing remaining snapshots rather than aborting.
  fi
done

# ─── Step 6: Summary ─────────────────────────────────────────────────────────

log "─────────────────────────────────────────"
log "Cleanup summary:"
log "  Total snapshots:  ${TOTAL}"
log "  Deleted:          ${COUNT_DELETED}"
log "  Kept (in window): ${COUNT_SKIPPED}"
log "  Failed:           ${COUNT_FAILED}"
log "─────────────────────────────────────────"

if [ "$COUNT_FAILED" -gt 0 ]; then
  err "${COUNT_FAILED} snapshot(s) could not be deleted. Review the errors above."
  err "=== S3 Snapshot Cleanup Job Completed with Errors ==="
  exit 1
fi

log "=== S3 Snapshot Cleanup Job Completed Successfully ==="
exit 0
