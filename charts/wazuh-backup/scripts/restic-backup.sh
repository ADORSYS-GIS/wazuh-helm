#!/bin/bash
# restic-backup.sh - Perform incremental backup with Restic
# Usage: restic-backup.sh <component-name> <pod-name> <pod-namespace> <include-paths>
#
# Features:
# - Backs up directly from pod to S3 (no staging PVC)
# - Uses tags for component/pod/namespace identification
# - Provides detailed statistics (new/changed/unchanged files)
# - Shows data deduplication savings
#
# Environment variables required:
# - RESTIC_REPOSITORY: S3 repository URL
# - RESTIC_PASSWORD: Repository encryption password
# - AWS_ACCESS_KEY_ID: AWS access key
# - AWS_SECRET_ACCESS_KEY: AWS secret key

set -euo pipefail

# --- Input validation ---
COMPONENT_NAME="${1:-}"
POD_NAME="${2:-}"
POD_NAMESPACE="${3:-}"
INCLUDE_PATHS="${4:-}"

if [[ -z "$COMPONENT_NAME" ]] || [[ -z "$POD_NAME" ]] || [[ -z "$POD_NAMESPACE" ]]; then
  echo "❌ ERROR: Missing required parameters"
  echo "Usage: $0 <component-name> <pod-name> <pod-namespace> <include-paths>"
  exit 1
fi

# Check environment variables
if [[ -z "${RESTIC_REPOSITORY:-}" ]] || [[ -z "${RESTIC_PASSWORD:-}" ]]; then
  echo "❌ ERROR: RESTIC_REPOSITORY and RESTIC_PASSWORD must be set"
  exit 1
fi

# --- Parse include paths ---
IFS=',' read -ra PATHS <<< "$INCLUDE_PATHS"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🗂️  Restic Incremental Backup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📦 Component:  $COMPONENT_NAME"
echo "🎯 Pod:        $POD_NAMESPACE/$POD_NAME"
echo "📂 Paths:      ${#PATHS[@]} path(s)"
for path in "${PATHS[@]}"; do
  echo "   - $path"
done
echo "🗄️  Repository: $RESTIC_REPOSITORY"
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

# --- Create temporary directory for backup ---
TEMP_BACKUP_DIR="/tmp/restic-backup-$COMPONENT_NAME-$$"
mkdir -p "$TEMP_BACKUP_DIR"

# Cleanup function
cleanup() {
  echo ""
  echo "🧹 Cleaning up temporary files..."
  rm -rf "$TEMP_BACKUP_DIR"
}
trap cleanup EXIT

# --- Copy data from pod to temporary directory ---
echo "📋 Copying data from pod..."
BACKUP_START_TIME=$(date +%s)

for path in "${PATHS[@]}"; do
  # Trim whitespace
  path=$(echo "$path" | xargs)

  if [[ -z "$path" ]]; then
    continue
  fi

  echo "   📁 Copying: $path"

  # Extract directory structure
  DIR_PATH=$(dirname "$path")
  BASE_NAME=$(basename "$path")

  # Create destination directory
  mkdir -p "$TEMP_BACKUP_DIR$DIR_PATH"

  # Copy from pod using kubectl cp
  # Note: kubectl cp handles wildcards differently, so we use exec + tar
  if [[ "$path" == *"*"* ]] || [[ "$path" == */ ]]; then
    # Path contains wildcards or is a directory - use tar
    kubectl exec -n "$POD_NAMESPACE" "$POD_NAME" -- \
      tar czf - -C / "${path#/}" 2>/dev/null | \
      tar xzf - -C "$TEMP_BACKUP_DIR" || {
        echo "   ⚠️  Warning: Could not copy $path (may not exist)"
        continue
      }
  else
    # Single file/directory - use kubectl cp
    kubectl cp "$POD_NAMESPACE/$POD_NAME:$path" \
      "$TEMP_BACKUP_DIR$path" 2>/dev/null || {
        echo "   ⚠️  Warning: Could not copy $path (may not exist)"
        continue
      }
  fi

  echo "   ✅ Copied: $path"
done

COPY_END_TIME=$(date +%s)
COPY_DURATION=$((COPY_END_TIME - BACKUP_START_TIME))

echo ""
echo "✅ Data copy completed in ${COPY_DURATION}s"
echo ""

# --- Perform Restic backup ---
echo "💾 Performing incremental backup..."
RESTIC_START_TIME=$(date +%s)

# Build restic backup command with tags
BACKUP_TAGS=(
  "component=$COMPONENT_NAME"
  "pod=$POD_NAME"
  "namespace=$POD_NAMESPACE"
  "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
)

# Build tag arguments
TAG_ARGS=()
for tag in "${BACKUP_TAGS[@]}"; do
  TAG_ARGS+=(--tag "$tag")
done

# Perform backup with detailed output
BACKUP_OUTPUT=$(restic backup "$TEMP_BACKUP_DIR" \
  "${TAG_ARGS[@]}" \
  --host "$POD_NAME" \
  --verbose 2>&1) || {
    echo "❌ ERROR: Restic backup failed"
    echo "$BACKUP_OUTPUT"
    exit 1
  }

RESTIC_END_TIME=$(date +%s)
RESTIC_DURATION=$((RESTIC_END_TIME - RESTIC_START_TIME))

echo "$BACKUP_OUTPUT"
echo ""
echo "✅ Restic backup completed in ${RESTIC_DURATION}s"
echo ""

# --- Parse statistics from output ---
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Backup Statistics"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Extract snapshot ID
SNAPSHOT_ID=$(echo "$BACKUP_OUTPUT" | grep -oP 'snapshot [a-f0-9]{8} saved' | awk '{print $2}')
if [[ -n "$SNAPSHOT_ID" ]]; then
  echo "📸 Snapshot ID:     $SNAPSHOT_ID"
fi

# Extract file counts
FILES_NEW=$(echo "$BACKUP_OUTPUT" | grep -oP '\d+(?= new)' || echo "0")
FILES_CHANGED=$(echo "$BACKUP_OUTPUT" | grep -oP '\d+(?= changed)' || echo "0")
FILES_UNCHANGED=$(echo "$BACKUP_OUTPUT" | grep -oP '\d+(?= unchanged)' || echo "0")

echo "📁 Files new:       $FILES_NEW"
echo "📝 Files changed:   $FILES_CHANGED"
echo "📋 Files unchanged: $FILES_UNCHANGED"

# Extract data sizes
DATA_ADDED=$(echo "$BACKUP_OUTPUT" | grep -oP 'Added to the repository: \K[\d.]+ [KMGT]iB' || echo "N/A")
DATA_PROCESSED=$(echo "$BACKUP_OUTPUT" | grep -oP 'processed \K[\d.]+ [KMGT]iB' || echo "N/A")

echo "➕ Data added:      $DATA_ADDED"
echo "⚙️  Data processed:  $DATA_PROCESSED"

# Calculate deduplication ratio
if [[ "$DATA_ADDED" != "N/A" ]] && [[ "$DATA_PROCESSED" != "N/A" ]]; then
  # Convert to bytes for calculation (simplified)
  ADDED_VALUE=$(echo "$DATA_ADDED" | awk '{print $1}')
  PROCESSED_VALUE=$(echo "$DATA_PROCESSED" | awk '{print $1}')

  if (( $(echo "$PROCESSED_VALUE > 0" | bc -l) )); then
    DEDUP_RATIO=$(echo "scale=2; (1 - $ADDED_VALUE/$PROCESSED_VALUE) * 100" | bc -l)
    echo "♻️  Deduplication:   ${DEDUP_RATIO}%"
  fi
fi

echo ""
echo "⏱️  Copy time:       ${COPY_DURATION}s"
echo "⏱️  Backup time:     ${RESTIC_DURATION}s"
TOTAL_DURATION=$((COPY_DURATION + RESTIC_DURATION))
echo "⏱️  Total time:      ${TOTAL_DURATION}s"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# --- Show recent snapshots ---
echo "📜 Recent snapshots for $COMPONENT_NAME:"
restic snapshots --tag "component=$COMPONENT_NAME" --last 5 --compact || {
  echo "⚠️  Warning: Could not list snapshots"
}
echo ""

# --- Repository statistics ---
echo "📊 Repository statistics:"
restic stats --mode raw-data --json | jq -r '
  "   Total size:  \(.total_size / 1024 / 1024 | floor)MB",
  "   Total files: \(.total_file_count)"
' 2>/dev/null || {
  echo "   (Statistics unavailable)"
}
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Backup completed successfully!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

exit 0
