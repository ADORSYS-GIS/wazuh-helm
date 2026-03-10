#!/bin/sh
# s3-snapshot.sh
#
# Triggers an OpenSearch snapshot to a registered S3 snapshot repository.
# Designed to run as a Kubernetes CronJob in a production environment.
#
# Required environment variables:
#   OPENSEARCH_URL         Base URL of the OpenSearch API (e.g. https://my-indexer-api:9200)
#   OPENSEARCH_USERNAME    OpenSearch admin username
#   OPENSEARCH_PASSWORD    OpenSearch admin password
#   SNAPSHOT_REPOSITORY    Name of the registered S3 snapshot repository (e.g. s3-repo)
#
# Optional environment variables (with defaults):
#   SNAPSHOT_NAME_PREFIX   Prefix for snapshot names          (default: "snapshot")
#   MAX_RETRIES            Max attempts before giving up       (default: 3)
#   RETRY_DELAY            Seconds between retry attempts      (default: 30)
#   CURL_TIMEOUT           Max seconds for a single curl call  (default: 600)

set -eu

# ─── Logging helpers ──────────────────────────────────────────────────────────

log()  { printf '[%s] INFO  %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
warn() { printf '[%s] WARN  %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
err()  { printf '[%s] ERROR %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }

# ─── Required env var validation ─────────────────────────────────────────────
# The :? operator exits with an error if the variable is unset or empty.

: "${OPENSEARCH_URL:?Required env var OPENSEARCH_URL is not set}"
: "${OPENSEARCH_USERNAME:?Required env var OPENSEARCH_USERNAME is not set}"
: "${OPENSEARCH_PASSWORD:?Required env var OPENSEARCH_PASSWORD is not set}"
: "${SNAPSHOT_REPOSITORY:?Required env var SNAPSHOT_REPOSITORY is not set}"

# ─── Configuration (with defaults) ───────────────────────────────────────────

SNAPSHOT_NAME_PREFIX="${SNAPSHOT_NAME_PREFIX:-snapshot}"
MAX_RETRIES="${MAX_RETRIES:-3}"
RETRY_DELAY="${RETRY_DELAY:-30}"
CURL_TIMEOUT="${CURL_TIMEOUT:-600}"

# ─── OpenSearch API helper ────────────────────────────────────────────────────
# Usage: opensearch_api <METHOD> <PATH> [<JSON_BODY>]
# Returns the response body followed by a newline and the HTTP status code.
# Credentials are passed as direct curl arguments — never interpolated into
# a shell string — so special characters in passwords are handled safely.

opensearch_api() {
  _method="$1"
  _path="$2"
  _body="${3:-}"

  if [ -n "$_body" ]; then
    curl -sk \
      --max-time "${CURL_TIMEOUT}" \
      -u "${OPENSEARCH_USERNAME}:${OPENSEARCH_PASSWORD}" \
      -w "\n%{http_code}" \
      -X "${_method}" \
      "${OPENSEARCH_URL}${_path}" \
      -H "Content-Type: application/json" \
      -d "${_body}"
  else
    curl -sk \
      --max-time "${CURL_TIMEOUT}" \
      -u "${OPENSEARCH_USERNAME}:${OPENSEARCH_PASSWORD}" \
      -w "\n%{http_code}" \
      -X "${_method}" \
      "${OPENSEARCH_URL}${_path}" \
      -H "Content-Type: application/json"
  fi
}

# Extract the last line (HTTP code) and everything before it (body).
http_code() { echo "$1" | tail -1; }
body()      { echo "$1" | head -n -1; }

# Extract a JSON string field value by key from a flat JSON response.
# Uses only grep and cut — no jq required.
json_str() {
  _key="$1"
  _json="$2"
  echo "$_json" | grep -o "\"${_key}\":\"[^\"]*\"" | head -1 | cut -d'"' -f4
}

# ─── Step 1: Cluster health check ────────────────────────────────────────────

log "=== S3 Snapshot Job Starting ==="
log "OpenSearch URL:      ${OPENSEARCH_URL}"
log "Snapshot repository: ${SNAPSHOT_REPOSITORY}"

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
  err "Cluster is in RED state. Aborting snapshot to avoid capturing a degraded state."
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

# ─── Step 3: Determine snapshot name (idempotency) ───────────────────────────

SNAPSHOT_NAME="${SNAPSHOT_NAME_PREFIX}-$(date -u '+%Y%m%d')"
log "Checking if snapshot '${SNAPSHOT_NAME}' already exists..."

EXISTING_RESP=$(opensearch_api GET "/_snapshot/${SNAPSHOT_REPOSITORY}/${SNAPSHOT_NAME}")
EXISTING_CODE=$(http_code "$EXISTING_RESP")
EXISTING_BODY=$(body "$EXISTING_RESP")

if [ "$EXISTING_CODE" = "200" ]; then
  EXISTING_STATE=$(json_str "state" "$EXISTING_BODY")
  case "$EXISTING_STATE" in
    SUCCESS)
      log "Snapshot '${SNAPSHOT_NAME}' already exists with state SUCCESS. Nothing to do."
      log "=== S3 Snapshot Job Completed (skipped — already succeeded) ==="
      exit 0 ;;
    IN_PROGRESS)
      warn "Snapshot '${SNAPSHOT_NAME}' is already IN_PROGRESS (possibly from a concurrent run)."
      err "Aborting to avoid interfering with the in-progress snapshot."
      exit 1 ;;
    FAILED|PARTIAL|*)
      warn "Snapshot '${SNAPSHOT_NAME}' exists but state is '${EXISTING_STATE}'."
      SNAPSHOT_NAME="${SNAPSHOT_NAME}-$(date -u '+%H%M%S')"
      log "Using new name with time suffix: '${SNAPSHOT_NAME}'" ;;
  esac
elif [ "$EXISTING_CODE" != "404" ]; then
  warn "Unexpected response checking existing snapshot (HTTP ${EXISTING_CODE}) — proceeding anyway."
fi

log "Snapshot name: ${SNAPSHOT_NAME}"

# ─── Step 4: Trigger snapshot with retry logic ───────────────────────────────

SNAPSHOT_BODY='{"indices":"*","ignore_unavailable":true,"include_global_state":false}'
ATTEMPT=0
SUCCESS=false

while [ "$ATTEMPT" -lt "$MAX_RETRIES" ]; do
  ATTEMPT=$((ATTEMPT + 1))
  log "Attempt ${ATTEMPT}/${MAX_RETRIES}: triggering snapshot..."

  SNAP_RESP=$(opensearch_api PUT \
    "/_snapshot/${SNAPSHOT_REPOSITORY}/${SNAPSHOT_NAME}?wait_for_completion=true" \
    "${SNAPSHOT_BODY}")
  SNAP_CODE=$(http_code "$SNAP_RESP")
  SNAP_BODY=$(body "$SNAP_RESP")

  log "Response (HTTP ${SNAP_CODE}): ${SNAP_BODY}"

  if [ "$SNAP_CODE" != "200" ]; then
    warn "Snapshot API returned HTTP ${SNAP_CODE}"
    if [ "$ATTEMPT" -lt "$MAX_RETRIES" ]; then
      log "Retrying in ${RETRY_DELAY}s..."
      sleep "$RETRY_DELAY"
    fi
    continue
  fi

  SNAP_STATE=$(json_str "state" "$SNAP_BODY")

  case "$SNAP_STATE" in
    SUCCESS)
      SUCCESS=true
      break ;;
    PARTIAL)
      warn "Snapshot completed with state PARTIAL (some shards may be missing)."
      FAILURES=$(echo "$SNAP_BODY" | grep -o '"failures":\[[^]]*\]' || true)
      [ -n "$FAILURES" ] && warn "Failures: ${FAILURES}"
      if [ "$ATTEMPT" -lt "$MAX_RETRIES" ]; then
        log "Retrying in ${RETRY_DELAY}s..."
        sleep "$RETRY_DELAY"
      fi ;;
    FAILED)
      err "Snapshot failed."
      FAILURES=$(echo "$SNAP_BODY" | grep -o '"failures":\[[^]]*\]' || true)
      [ -n "$FAILURES" ] && err "Failures: ${FAILURES}"
      if [ "$ATTEMPT" -lt "$MAX_RETRIES" ]; then
        log "Retrying in ${RETRY_DELAY}s..."
        sleep "$RETRY_DELAY"
      fi ;;
    IN_PROGRESS)
      warn "Snapshot still in progress after wait_for_completion — this is unexpected."
      if [ "$ATTEMPT" -lt "$MAX_RETRIES" ]; then
        log "Retrying in ${RETRY_DELAY}s..."
        sleep "$RETRY_DELAY"
      fi ;;
    "")
      warn "Could not parse snapshot state from response."
      if [ "$ATTEMPT" -lt "$MAX_RETRIES" ]; then
        log "Retrying in ${RETRY_DELAY}s..."
        sleep "$RETRY_DELAY"
      fi ;;
    *)
      warn "Unexpected snapshot state: '${SNAP_STATE}'"
      if [ "$ATTEMPT" -lt "$MAX_RETRIES" ]; then
        log "Retrying in ${RETRY_DELAY}s..."
        sleep "$RETRY_DELAY"
      fi ;;
  esac
done

# ─── Result ───────────────────────────────────────────────────────────────────

if [ "$SUCCESS" = "true" ]; then
  log "Snapshot '${SNAPSHOT_NAME}' completed successfully."
  log "=== S3 Snapshot Job Completed ==="
  exit 0
else
  err "Snapshot '${SNAPSHOT_NAME}' failed after ${MAX_RETRIES} attempt(s)."
  err "=== S3 Snapshot Job Failed ==="
  exit 1
fi
