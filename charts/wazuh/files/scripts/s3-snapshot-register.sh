#!/bin/sh
# s3-snapshot-register.sh
#
# Idempotently registers (or updates) the S3 snapshot repository in OpenSearch.
# Designed to run as a one-shot Kubernetes Job triggered via a Helm
# post-install/post-upgrade hook. The job waits for OpenSearch to become
# reachable before proceeding, so it is safe to deploy alongside the Indexer.
#
# A PUT request to /_snapshot/{repo} is idempotent in OpenSearch: if the
# repository already exists with the same settings, the call is a no-op.
# If settings differ, they are updated. This makes the job safe to run on
# every helm upgrade without side effects.
#
# Authentication uses OpenSearch basic auth. The admin user has permission
# to register snapshot repositories without requiring the admin TLS cert.
#
# Required environment variables:
#   OPENSEARCH_URL         Base URL of the OpenSearch API (e.g. https://my-indexer-api:9200)
#   OPENSEARCH_USERNAME    OpenSearch admin username
#   OPENSEARCH_PASSWORD    OpenSearch admin password
#   SNAPSHOT_REPOSITORY    Name to register the repository under (e.g. s3-repo)
#   S3_BUCKET              S3 bucket name
#
# Optional environment variables (with defaults):
#   S3_REGION              AWS region of the S3 bucket              (default: eu-central-1)
#   S3_BASE_PATH           Path prefix inside the bucket            (default: snapshots)
#   S3_ENDPOINT            Custom S3-compatible endpoint URL        (default: empty — uses AWS)
#                          Example: https://minio.example.com
#   WAIT_TIMEOUT           Max seconds to wait for OpenSearch       (default: 300)
#   CURL_TIMEOUT           Max seconds per curl call                (default: 30)

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
: "${S3_BUCKET:?Required env var S3_BUCKET is not set}"

# ─── Configuration (with defaults) ───────────────────────────────────────────

S3_REGION="${S3_REGION:-eu-central-1}"
S3_BASE_PATH="${S3_BASE_PATH:-snapshots}"
S3_ENDPOINT="${S3_ENDPOINT:-}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-300}"
CURL_TIMEOUT="${CURL_TIMEOUT:-30}"

# ─── OpenSearch API helper ────────────────────────────────────────────────────
# Usage: opensearch_api <METHOD> <PATH> [<JSON_BODY>]
# Returns the response body followed by a newline and the HTTP status code.

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

http_code() { echo "$1" | tail -1; }
body()      { echo "$1" | head -n -1; }

# ─── Step 1: Wait for OpenSearch to become reachable ─────────────────────────

log "=== S3 Snapshot Repository Registration Starting ==="
log "OpenSearch URL:      ${OPENSEARCH_URL}"
log "Snapshot repository: ${SNAPSHOT_REPOSITORY}"
log "S3 bucket:           ${S3_BUCKET}"
log "S3 region:           ${S3_REGION}"
log "S3 base path:        ${S3_BASE_PATH}"
if [ -n "$S3_ENDPOINT" ]; then
  log "S3 endpoint:         ${S3_ENDPOINT}"
fi
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

  PROBE=$(curl -sk --max-time 10 \
    -u "${OPENSEARCH_USERNAME}:${OPENSEARCH_PASSWORD}" \
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

# ─── Step 2: Check if the repository already exists ─────────────────────────

CHECK_RESP=$(opensearch_api GET "/_snapshot/${SNAPSHOT_REPOSITORY}")
CHECK_CODE=$(http_code "$CHECK_RESP")

if [ "$CHECK_CODE" = "200" ]; then
  REPO_ACTION="Updating existing"
elif [ "$CHECK_CODE" = "404" ]; then
  REPO_ACTION="Creating new"
else
  REPO_ACTION="Registering"
fi

# ─── Step 3: Build repository settings JSON ──────────────────────────────────

if [ -n "$S3_ENDPOINT" ]; then
  REPO_BODY=$(printf '{"type":"s3","settings":{"bucket":"%s","region":"%s","base_path":"%s","endpoint":"%s"}}' \
    "$S3_BUCKET" "$S3_REGION" "$S3_BASE_PATH" "$S3_ENDPOINT")
else
  REPO_BODY=$(printf '{"type":"s3","settings":{"bucket":"%s","region":"%s","base_path":"%s"}}' \
    "$S3_BUCKET" "$S3_REGION" "$S3_BASE_PATH")
fi

# ─── Step 4: Register (or update) the snapshot repository ────────────────────

log "${REPO_ACTION} snapshot repository '${SNAPSHOT_REPOSITORY}'..."
log "Settings: ${REPO_BODY}"

REGISTER_RESP=$(opensearch_api PUT "/_snapshot/${SNAPSHOT_REPOSITORY}" "${REPO_BODY}")
REGISTER_CODE=$(http_code "$REGISTER_RESP")
REGISTER_BODY=$(body "$REGISTER_RESP")

log "Response (HTTP ${REGISTER_CODE}): ${REGISTER_BODY}"

if [ "$REGISTER_CODE" != "200" ]; then
  err "Failed to register snapshot repository (HTTP ${REGISTER_CODE})."
  err "Check that the repository-s3 plugin is installed in the indexer image."
  err "Check that AWS credentials are correctly configured in the keystore."
  exit 1
fi

# ─── Step 5: Verify the repository is usable ─────────────────────────────────

log "Verifying repository '${SNAPSHOT_REPOSITORY}' is reachable from the cluster..."
VERIFY_RESP=$(opensearch_api POST "/_snapshot/${SNAPSHOT_REPOSITORY}/_verify")
VERIFY_CODE=$(http_code "$VERIFY_RESP")
VERIFY_BODY=$(body "$VERIFY_RESP")

if [ "$VERIFY_CODE" = "200" ]; then
  log "Repository verification succeeded."
  log "Response: ${VERIFY_BODY}"
else
  warn "Repository verification returned HTTP ${VERIFY_CODE}: ${VERIFY_BODY}"
  warn "The repository was registered but could not be verified."
  warn "Check S3 bucket permissions and AWS credentials."
  ## Do not exit — the repository is registered; the user can investigate further.
fi

log "=== S3 Snapshot Repository Registration Completed ==="
exit 0
