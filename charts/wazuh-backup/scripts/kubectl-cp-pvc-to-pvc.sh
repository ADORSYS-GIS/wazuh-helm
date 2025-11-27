#!/bin/sh
set -eu

# Parameters passed via environment variables
POD_NAME="${POD_NAME:-}"
POD_NAMESPACE="${POD_NAMESPACE:-}"
CONTAINER_NAME="${CONTAINER_NAME:-}"
INCLUDE_PATHS="${INCLUDE_PATHS:-}"  # Comma-separated list of paths to backup
DESTINATION_PATH="${DESTINATION_PATH:-}"

echo "🔍 Kubectl CP Configuration:"
echo "  POD_NAME: ${POD_NAME}"
echo "  POD_NAMESPACE: ${POD_NAMESPACE}"
echo "  CONTAINER_NAME: ${CONTAINER_NAME}"
echo "  INCLUDE_PATHS: ${INCLUDE_PATHS}"
echo "  DESTINATION_PATH: ${DESTINATION_PATH}"
echo ""

# Validate required parameters
if [[ -z "$POD_NAME" ]]; then
  echo "❌ POD_NAME environment variable must be set" >&2
  exit 1
fi

if [[ -z "$POD_NAMESPACE" ]]; then
  echo "❌ POD_NAMESPACE environment variable must be set" >&2
  exit 1
fi

if [[ -z "$DESTINATION_PATH" ]]; then
  echo "❌ DESTINATION_PATH environment variable must be set" >&2
  exit 1
fi

if [[ -z "$INCLUDE_PATHS" ]]; then
  echo "❌ INCLUDE_PATHS environment variable must be set" >&2
  exit 1
fi

DEST_DIR="/backup/${DESTINATION_PATH}"

# Refuse to treat / (root) as destination
if [[ "$DEST_DIR" = "/" ]]; then
  echo "❌ Refusing to use / as destination." >&2
  exit 1
fi

# Create destination if it is missing
if [[ ! -d "$DEST_DIR" ]]; then
  echo "📂 Destination $DEST_DIR not found. Creating it…"
  mkdir -p "$DEST_DIR"
fi

# Build container argument if specified
CONTAINER_ARG=""
if [[ -n "$CONTAINER_NAME" ]]; then
  CONTAINER_ARG="-c $CONTAINER_NAME"
fi

echo "📦 Backing up specified paths using kubectl cp"
echo ""

# Create temporary files
TEMP_PATHS="/tmp/backup-paths-$$.txt"
TEMP_EXPANDED="/tmp/backup-expanded-$$.txt"
> "$TEMP_PATHS"
> "$TEMP_EXPANDED"

# Parse paths from INCLUDE_PATHS
# Constant for trimming whitespace
readonly TRIM_WHITESPACE_SED='s/^[[:space:]]*//;s/[[:space:]]*$//'

echo "📋 Parsing backup paths..."
echo "$INCLUDE_PATHS" | tr ',' '\n' | while IFS= read -r path; do
  # Trim whitespace
  path=$(echo "$path" | sed "${TRIM_WHITESPACE_SED}")
  if [[ -n "$path" ]]; then
    echo "$path" >> "$TEMP_PATHS"
  fi
done

# Check if paths contain wildcards and expand them
echo "🔎 Checking and expanding paths in pod..."
echo ""

while IFS= read -r path; do
  if [[ -z "$path" ]]; then
    continue
  fi

  # Check if path contains wildcard characters
  if echo "$path" | grep -qE '[\*\?\[]'; then
    echo "🔍 Expanding wildcard: $path"

    # Use kubectl exec to expand wildcards in the pod
    EXPANDED=$(kubectl exec -n "$POD_NAMESPACE" "$POD_NAME" $CONTAINER_ARG -- sh -c "ls -1d $path 2>/dev/null || true")

    if [[ -n "$EXPANDED" ]]; then
      echo "$EXPANDED" | while IFS= read -r expanded_path; do
        if [[ -n "$expanded_path" ]]; then
          echo "   ✓ Found: $expanded_path"
          echo "$expanded_path" >> "$TEMP_EXPANDED"
        fi
      done
    else
      echo "   ⚠️  No matches found for pattern: $path"
    fi
  else
    # No wildcard - check if path exists
    if kubectl exec -n "$POD_NAMESPACE" "$POD_NAME" $CONTAINER_ARG -- test -e "$path" 2>/dev/null; then
      echo "✓ Found: $path"
      echo "$path" >> "$TEMP_EXPANDED"
    else
      echo "⚠️  Not found (skipping): $path"
    fi
  fi
done < "$TEMP_PATHS"

echo ""

# Count expanded paths
PATH_COUNT=$(wc -l < "$TEMP_EXPANDED" 2>/dev/null | tr -d ' ' || echo "0")

if [[ "$PATH_COUNT" -eq 0 ]]; then
  echo "❌ No valid paths found to backup (all paths were missing or wildcards didn't match)" >&2
  rm -f "$TEMP_PATHS" "$TEMP_EXPANDED"
  exit 1
fi

echo "📦 Starting kubectl cp for $PATH_COUNT file(s)/director(ies)..."
echo ""

# Copy each path\
SUCCESS_COUNT=0
FAIL_COUNT=0

while IFS= read -r path; do
  if [[ -z "$path" ]]; then
    continue
  fi

  echo "📂 Copying: $path"

  # Build the kubectl cp source reference
  POD_SOURCE="${POD_NAMESPACE}/${POD_NAME}:${path}"

  # Get the parent directory to preserve structure
  parent_dir=$(dirname "$path")
  dest_parent="$DEST_DIR/$parent_dir"

  # Create parent directory structure if needed
  if [[ ! -d "$dest_parent" ]]; then
    mkdir -p "$dest_parent" 2>/dev/null || {
      echo "   ⚠️  Warning: Failed to create directory $dest_parent" >&2
      FAIL_COUNT=$((FAIL_COUNT + 1))
      echo ""
      continue
    }
  fi

  # Execute kubectl cp - capture output and check exit code
  OUTPUT=$(kubectl cp $CONTAINER_ARG "$POD_SOURCE" "$DEST_DIR/$path" 2>&1)
  EXIT_CODE=$?

  if [[ $EXIT_CODE -eq 0 ]]; then
    echo "   ✓ Copied successfully"
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
  else
    echo "   ⚠️  Warning: kubectl cp failed for $path" >&2
    # Show error details (filter out tar warnings)
    echo "$OUTPUT" | grep -v "^tar:" | sed 's/^/      /' >&2 || true
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
  echo ""
done < "$TEMP_EXPANDED"

# Cleanup
rm -f "$TEMP_PATHS" "$TEMP_EXPANDED"

# Summary
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Backup Summary:"
echo "   Total paths: $PATH_COUNT"
echo "   Successful: $SUCCESS_COUNT"
echo "   Failed: $FAIL_COUNT"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ "$SUCCESS_COUNT" -eq 0 ]]; then
  echo "❌ All backup operations failed" >&2
  exit 1
elif [[ "$FAIL_COUNT" -gt 0 ]]; then
  echo "⚠️  Backup completed with warnings (some files could not be copied)"
  exit 0
else
  echo "✅ Backup completed successfully"
  exit 0
fi
