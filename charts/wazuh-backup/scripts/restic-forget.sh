#!/bin/bash
# restic-forget.sh - Cleanup old snapshots based on retention policy
# Usage: restic-forget.sh [component-name]
#
# Features:
# - Applies retention policy (keep last N, daily, weekly, monthly)
# - Prunes unused data to free storage
# - Shows repository stats after cleanup
#
# Environment variables required:
# - RESTIC_REPOSITORY: S3 repository URL
# - RESTIC_PASSWORD: Repository encryption password
# - AWS_ACCESS_KEY_ID: AWS access key
# - AWS_SECRET_ACCESS_KEY: AWS secret key
# - KEEP_LAST: Number of latest snapshots to keep (default: 7)
# - KEEP_DAILY: Number of daily snapshots to keep (default: 30)
# - KEEP_WEEKLY: Number of weekly snapshots to keep (default: 12)
# - KEEP_MONTHLY: Number of monthly snapshots to keep (default: 12)

set -euo pipefail

# --- Input validation ---
COMPONENT_NAME="${1:-}"

# Check environment variables
if [[ -z "${RESTIC_REPOSITORY:-}" ]] || [[ -z "${RESTIC_PASSWORD:-}" ]]; then
  echo "❌ ERROR: RESTIC_REPOSITORY and RESTIC_PASSWORD must be set"
  exit 1
fi

# Retention policy (from environment or defaults)
KEEP_LAST="${KEEP_LAST:-7}"
KEEP_DAILY="${KEEP_DAILY:-30}"
KEEP_WEEKLY="${KEEP_WEEKLY:-12}"
KEEP_MONTHLY="${KEEP_MONTHLY:-12}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🗑️  Restic Cleanup & Retention"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ -n "$COMPONENT_NAME" ]]; then
  echo "📦 Component:     $COMPONENT_NAME (specific cleanup)"
else
  echo "📦 Component:     ALL (repository-wide cleanup)"
fi
echo "🗄️  Repository:    $RESTIC_REPOSITORY"
echo ""
echo "📋 Retention Policy:"
echo "   Keep last:     $KEEP_LAST snapshots"
echo "   Keep daily:    $KEEP_DAILY days"
echo "   Keep weekly:   $KEEP_WEEKLY weeks"
echo "   Keep monthly:  $KEEP_MONTHLY months"
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

# --- Get statistics before cleanup ---
echo "📊 Repository statistics BEFORE cleanup:"
STATS_BEFORE=$(restic stats --mode raw-data --json 2>/dev/null) || {
  echo "   (Statistics unavailable)"
  STATS_BEFORE="{}"
}

SIZE_BEFORE=$(echo "$STATS_BEFORE" | jq -r '.total_size // 0')
FILES_BEFORE=$(echo "$STATS_BEFORE" | jq -r '.total_file_count // 0')

if [[ "$SIZE_BEFORE" != "0" ]]; then
  SIZE_BEFORE_MB=$((SIZE_BEFORE / 1024 / 1024))
  echo "   Total size:  ${SIZE_BEFORE_MB}MB"
  echo "   Total files: $FILES_BEFORE"
else
  echo "   (Statistics unavailable)"
fi
echo ""

# --- Count snapshots before cleanup ---
if [[ -n "$COMPONENT_NAME" ]]; then
  SNAPSHOTS_BEFORE=$(restic snapshots --tag "component=$COMPONENT_NAME" --json | jq 'length')
  echo "📸 Snapshots for $COMPONENT_NAME before cleanup: $SNAPSHOTS_BEFORE"
else
  SNAPSHOTS_BEFORE=$(restic snapshots --json | jq 'length')
  echo "📸 Total snapshots before cleanup: $SNAPSHOTS_BEFORE"
fi
echo ""

# --- Apply retention policy (forget) ---
echo "🗑️  Applying retention policy..."
FORGET_START_TIME=$(date +%s)

# Build forget command
FORGET_ARGS=(
  --keep-last "$KEEP_LAST"
  --keep-daily "$KEEP_DAILY"
  --keep-weekly "$KEEP_WEEKLY"
  --keep-monthly "$KEEP_MONTHLY"
  --prune  # Also prune data (free storage)
  --verbose
)

# Add component filter if specified
if [[ -n "$COMPONENT_NAME" ]]; then
  FORGET_ARGS+=(--tag "component=$COMPONENT_NAME")
fi

# Execute forget command
FORGET_OUTPUT=$(restic forget "${FORGET_ARGS[@]}" 2>&1) || {
  echo "❌ ERROR: Restic forget failed"
  echo "$FORGET_OUTPUT"
  exit 1
}

FORGET_END_TIME=$(date +%s)
FORGET_DURATION=$((FORGET_END_TIME - FORGET_START_TIME))

echo "$FORGET_OUTPUT"
echo ""
echo "✅ Retention policy applied in ${FORGET_DURATION}s"
echo ""

# --- Parse forget output ---
REMOVED_COUNT=$(echo "$FORGET_OUTPUT" | grep -oP '\d+(?= snapshots have been removed)' || echo "0")
echo "📸 Snapshots removed: $REMOVED_COUNT"
echo ""

# --- Count snapshots after cleanup ---
if [[ -n "$COMPONENT_NAME" ]]; then
  SNAPSHOTS_AFTER=$(restic snapshots --tag "component=$COMPONENT_NAME" --json | jq 'length')
  echo "📸 Snapshots for $COMPONENT_NAME after cleanup: $SNAPSHOTS_AFTER"
else
  SNAPSHOTS_AFTER=$(restic snapshots --json | jq 'length')
  echo "📸 Total snapshots after cleanup: $SNAPSHOTS_AFTER"
fi
echo ""

# --- Get statistics after cleanup ---
echo "📊 Repository statistics AFTER cleanup:"
STATS_AFTER=$(restic stats --mode raw-data --json 2>/dev/null) || {
  echo "   (Statistics unavailable)"
  STATS_AFTER="{}"
}

SIZE_AFTER=$(echo "$STATS_AFTER" | jq -r '.total_size // 0')
FILES_AFTER=$(echo "$STATS_AFTER" | jq -r '.total_file_count // 0')

if [[ "$SIZE_AFTER" != "0" ]]; then
  SIZE_AFTER_MB=$((SIZE_AFTER / 1024 / 1024))
  echo "   Total size:  ${SIZE_AFTER_MB}MB"
  echo "   Total files: $FILES_AFTER"
else
  echo "   (Statistics unavailable)"
fi
echo ""

# --- Calculate savings ---
if [[ "$SIZE_BEFORE" != "0" ]] && [[ "$SIZE_AFTER" != "0" ]]; then
  SPACE_FREED=$((SIZE_BEFORE - SIZE_AFTER))
  SPACE_FREED_MB=$((SPACE_FREED / 1024 / 1024))

  if [[ "$SPACE_FREED" -gt 0 ]]; then
    SAVINGS_PERCENT=$(echo "scale=2; $SPACE_FREED * 100 / $SIZE_BEFORE" | bc -l)
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "💾 Storage Savings"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "   Space freed: ${SPACE_FREED_MB}MB (${SAVINGS_PERCENT}%)"
    echo "   Before:      ${SIZE_BEFORE_MB}MB"
    echo "   After:       ${SIZE_AFTER_MB}MB"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
  else
    echo "ℹ️  No storage freed (data still referenced by other snapshots)"
    echo ""
  fi
fi

# --- Show remaining snapshots ---
if [[ -n "$COMPONENT_NAME" ]]; then
  echo "📜 Remaining snapshots for $COMPONENT_NAME:"
  restic snapshots --tag "component=$COMPONENT_NAME" --compact || {
    echo "   (No snapshots)"
  }
else
  echo "📜 Remaining snapshots (grouped by component):"
  restic snapshots --group-by tags --compact || {
    echo "   (No snapshots)"
  }
fi
echo ""

# --- Repository integrity check (optional) ---
echo "🔍 Verifying repository integrity..."
CHECK_OUTPUT=$(restic check --read-data-subset=5% 2>&1) || {
  echo "⚠️  Warning: Repository check found issues"
  echo "$CHECK_OUTPUT"
  echo ""
  echo "Run 'restic check --read-data' for a full integrity check"
}

CHECK_STATUS=$?
if [[ $CHECK_STATUS -eq 0 ]]; then
  echo "✅ Repository integrity verified (5% sample check)"
else
  echo "⚠️  Repository integrity check completed with warnings"
fi
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Cleanup completed successfully!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "⏱️  Duration:         ${FORGET_DURATION}s"
echo "📸 Snapshots removed: $REMOVED_COUNT"
if [[ "$SPACE_FREED_MB" -gt 0 ]] 2>/dev/null; then
  echo "💾 Space freed:       ${SPACE_FREED_MB}MB"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

exit 0
