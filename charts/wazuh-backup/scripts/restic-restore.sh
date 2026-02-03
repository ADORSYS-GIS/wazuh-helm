#!/bin/bash
# restic-restore.sh - Restore from Restic backup
# Usage: restic-restore.sh <component-name> <target-path> [snapshot-id]
#
# Features:
# - Lists available snapshots for component
# - Restores to specified target path
# - Verifies restore integrity
#
# Environment variables required:
# - RESTIC_REPOSITORY: S3 repository URL
# - RESTIC_PASSWORD: Repository encryption password
# - AWS_ACCESS_KEY_ID: AWS access key
# - AWS_SECRET_ACCESS_KEY: AWS secret key

set -euo pipefail

# --- Input validation ---
COMPONENT_NAME="${1:-}"
TARGET_PATH="${2:-}"
SNAPSHOT_ID="${3:-latest}"

if [[ -z "$COMPONENT_NAME" ]] || [[ -z "$TARGET_PATH" ]]; then
  echo "❌ ERROR: Missing required parameters"
  echo "Usage: $0 <component-name> <target-path> [snapshot-id]"
  echo ""
  echo "Examples:"
  echo "  $0 master /tmp/restore latest"
  echo "  $0 worker-0 /restore/path abc12345"
  exit 1
fi

# Check environment variables
if [[ -z "${RESTIC_REPOSITORY:-}" ]] || [[ -z "${RESTIC_PASSWORD:-}" ]]; then
  echo "❌ ERROR: RESTIC_REPOSITORY and RESTIC_PASSWORD must be set"
  exit 1
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔄 Restic Restore"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📦 Component:     $COMPONENT_NAME"
echo "📂 Target path:   $TARGET_PATH"
echo "📸 Snapshot:      $SNAPSHOT_ID"
echo "🗄️  Repository:    $RESTIC_REPOSITORY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# --- Check repository accessibility ---
echo "🔍 Checking repository accessibility..."
if ! restic snapshots --json > /dev/null 2>&1; then
  echo "❌ ERROR: Cannot access Restic repository"
  echo "   Repository: $RESTIC_REPOSITORY"
  echo "   Check credentials and S3 bucket permissions"
  exit 1
fi
echo "✅ Repository accessible"
echo ""

# --- List available snapshots ---
echo "📜 Available snapshots for $COMPONENT_NAME:"
echo ""

SNAPSHOTS_JSON=$(restic snapshots --tag "component=$COMPONENT_NAME" --json 2>/dev/null)

if [[ -z "$SNAPSHOTS_JSON" ]] || [[ "$SNAPSHOTS_JSON" == "[]" ]]; then
  echo "❌ ERROR: No snapshots found for component: $COMPONENT_NAME"
  echo ""
  echo "Available components:"
  restic snapshots --json | jq -r '.[].tags[]' | grep '^component=' | cut -d= -f2 | sort -u | sed 's/^/  - /'
  exit 1
fi

# Display snapshots in table format
echo "$SNAPSHOTS_JSON" | jq -r '
  ["ID", "Time", "Host", "Paths"] as $headers |
  (["--------", "-------------------", "----------", "-----"] as $sep |
  $headers, $sep),
  (.[] | [
    .short_id,
    .time[:19],
    .hostname,
    (.paths | join(", ") | if length > 30 then .[:27] + "..." else . end)
  ]) | @tsv
' | column -t -s $'\t'

echo ""

# --- Resolve snapshot ID ---
if [[ "$SNAPSHOT_ID" == "latest" ]]; then
  # Get the latest snapshot for this component
  RESOLVED_SNAPSHOT_ID=$(echo "$SNAPSHOTS_JSON" | jq -r 'sort_by(.time) | last | .short_id')
  echo "📸 Resolved 'latest' to snapshot: $RESOLVED_SNAPSHOT_ID"
else
  # Verify the specified snapshot exists
  RESOLVED_SNAPSHOT_ID=$(echo "$SNAPSHOTS_JSON" | jq -r --arg id "$SNAPSHOT_ID" '
    .[] | select(.short_id == $id or .id == $id) | .short_id
  ' | head -n1)

  if [[ -z "$RESOLVED_SNAPSHOT_ID" ]]; then
    echo "❌ ERROR: Snapshot not found: $SNAPSHOT_ID"
    echo "   Use one of the IDs listed above"
    exit 1
  fi
  echo "📸 Using snapshot: $RESOLVED_SNAPSHOT_ID"
fi
echo ""

# --- Get snapshot details ---
SNAPSHOT_INFO=$(echo "$SNAPSHOTS_JSON" | jq -r --arg id "$RESOLVED_SNAPSHOT_ID" '
  .[] | select(.short_id == $id)
')

SNAPSHOT_TIME=$(echo "$SNAPSHOT_INFO" | jq -r '.time')
SNAPSHOT_HOST=$(echo "$SNAPSHOT_INFO" | jq -r '.hostname')
SNAPSHOT_PATHS=$(echo "$SNAPSHOT_INFO" | jq -r '.paths | join(", ")')

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 Snapshot Details"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "   ID:        $RESOLVED_SNAPSHOT_ID"
echo "   Time:      $SNAPSHOT_TIME"
echo "   Host:      $SNAPSHOT_HOST"
echo "   Paths:     $SNAPSHOT_PATHS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# --- Prepare target directory ---
echo "📁 Preparing target directory..."
mkdir -p "$TARGET_PATH"

if [[ ! -d "$TARGET_PATH" ]]; then
  echo "❌ ERROR: Cannot create target directory: $TARGET_PATH"
  exit 1
fi

# Check if target is writable
if [[ ! -w "$TARGET_PATH" ]]; then
  echo "❌ ERROR: Target directory is not writable: $TARGET_PATH"
  exit 1
fi

echo "✅ Target directory ready: $TARGET_PATH"
echo ""

# --- Perform restore ---
echo "🔄 Restoring snapshot $RESOLVED_SNAPSHOT_ID to $TARGET_PATH..."
RESTORE_START_TIME=$(date +%s)

RESTORE_OUTPUT=$(restic restore "$RESOLVED_SNAPSHOT_ID" \
  --target "$TARGET_PATH" \
  --verbose 2>&1) || {
    echo "❌ ERROR: Restore failed"
    echo "$RESTORE_OUTPUT"
    exit 1
  }

RESTORE_END_TIME=$(date +%s)
RESTORE_DURATION=$((RESTORE_END_TIME - RESTORE_START_TIME))

echo "$RESTORE_OUTPUT"
echo ""
echo "✅ Restore completed in ${RESTORE_DURATION}s"
echo ""

# --- Parse statistics ---
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Restore Statistics"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Extract file counts
FILES_RESTORED=$(echo "$RESTORE_OUTPUT" | grep -oP 'restoring \K\d+(?= files)' || echo "N/A")
DATA_RESTORED=$(echo "$RESTORE_OUTPUT" | grep -oP '\K[\d.]+ [KMGT]iB(?= in)' || echo "N/A")

echo "📁 Files restored: $FILES_RESTORED"
echo "💾 Data restored:  $DATA_RESTORED"
echo "⏱️  Duration:       ${RESTORE_DURATION}s"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# --- Verify restore ---
echo "🔍 Verifying restored files..."

# Count files in target directory
RESTORED_FILE_COUNT=$(find "$TARGET_PATH" -type f | wc -l)
RESTORED_DIR_COUNT=$(find "$TARGET_PATH" -type d | wc -l)

echo "   Files:       $RESTORED_FILE_COUNT"
echo "   Directories: $RESTORED_DIR_COUNT"

if [[ "$RESTORED_FILE_COUNT" -eq 0 ]]; then
  echo "⚠️  Warning: No files found in restore directory"
  echo "   This might indicate an issue with the restore"
else
  echo "✅ Restore verification passed"
fi
echo ""

# --- Display sample of restored files ---
echo "📂 Sample of restored files (top 10):"
find "$TARGET_PATH" -type f -printf '%P\n' | head -10 | sed 's/^/   /'

TOTAL_FILES=$(find "$TARGET_PATH" -type f | wc -l)
if [[ "$TOTAL_FILES" -gt 10 ]]; then
  echo "   ... and $((TOTAL_FILES - 10)) more files"
fi
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Restore completed successfully!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📂 Restored to: $TARGET_PATH"
echo ""
echo "Next steps:"
echo "  1. Verify the restored data: ls -lah $TARGET_PATH"
echo "  2. Copy to pod if needed: kubectl cp $TARGET_PATH pod-name:/var/ossec/"
echo "  3. Restart services if required"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

exit 0
