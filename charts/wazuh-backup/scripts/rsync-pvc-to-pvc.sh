#!/bin/sh
set -eu

# Parameters passed via environment variables
SOURCE_PATH="${SOURCE_PATH:-}"
DESTINATION_PATH="${DESTINATION_PATH:-}"
INCLUDE_PATHS="${INCLUDE_PATHS:-}"  # Comma-separated list of paths to include
EXCLUDE_PATTERNS="${EXCLUDE_PATTERNS:-}"  # Comma-separated list of patterns to exclude

echo "🔍 Rsync Configuration:"
echo "  SOURCE_PATH: ${SOURCE_PATH}"
echo "  DESTINATION_PATH: ${DESTINATION_PATH}"
echo "  INCLUDE_PATHS: ${INCLUDE_PATHS}"
echo "  EXCLUDE_PATTERNS: ${EXCLUDE_PATTERNS}"
echo ""

# Validate required parameters
if [ -z "$DESTINATION_PATH" ]; then
  echo "❌ DESTINATION_PATH environment variable must be set"
  exit 1
fi

DEST_DIR="/backup/${DESTINATION_PATH}"

# 2. Refuse to treat / (root) as destination
if [ "$DEST_DIR" = "/" ]; then
  echo "❌ Refusing to use / as destination."
  exit 1
fi

# 3. Create destination if it is missing
if [ ! -d "$DEST_DIR" ]; then
  echo "📂 Destination $DEST_DIR not found. Creating it…"
  mkdir -p "$DEST_DIR"
fi

# Determine backup mode: single path or multiple paths
if [ -n "$INCLUDE_PATHS" ]; then
  # Advanced mode: Multiple paths with include/exclude
  echo "📦 Advanced Mode: Backing up specific paths"

  # Build rsync arguments
  RSYNC_ARGS="-avh --relative"

  # Add exclude patterns if provided
  if [ -n "$EXCLUDE_PATTERNS" ]; then
    echo "🚫 Exclude patterns:"
    # Convert comma-separated patterns to rsync --exclude arguments
    echo "$EXCLUDE_PATTERNS" | tr ',' '\n' | while IFS= read -r pattern; do
      pattern=$(echo "$pattern" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')  # trim whitespace
      if [ -n "$pattern" ]; then
        echo "   - $pattern"
        RSYNC_ARGS="$RSYNC_ARGS --exclude=$pattern"
      fi
    done
  fi

  # Process each include path
  echo "✅ Include paths:"
  PATHS_TO_BACKUP=""
  echo "$INCLUDE_PATHS" | tr ',' '\n' | while IFS= read -r path; do
    path=$(echo "$path" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')  # trim whitespace
    if [ -n "$path" ]; then
      echo "   - $path"
      FULL_PATH="/source/$path"

      # Check if path exists
      if [ -e "$FULL_PATH" ]; then
        echo "     ✓ Found"
      else
        echo "     ⚠️  Not found (skipping)"
      fi
    fi
  done

  # Build the file list for rsync
  INCLUDE_FILE="/tmp/rsync-include-list.txt"
  > "$INCLUDE_FILE"  # Clear file

  echo "$INCLUDE_PATHS" | tr ',' '\n' | while IFS= read -r path; do
    path=$(echo "$path" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [ -n "$path" ] && [ -e "/source/$path" ]; then
      echo "$path" >> "$INCLUDE_FILE"
    fi
  done

  # Count paths to backup
  PATH_COUNT=$(wc -l < "$INCLUDE_FILE" || echo "0")

  if [ "$PATH_COUNT" -eq 0 ]; then
    echo "❌ No valid paths found to backup"
    exit 1
  fi

  echo ""
  echo "📦 Starting rsync for $PATH_COUNT path(s)..."

  # Build exclude arguments
  EXCLUDE_ARGS=""
  if [ -n "$EXCLUDE_PATTERNS" ]; then
    echo "$EXCLUDE_PATTERNS" | tr ',' '\n' | while IFS= read -r pattern; do
      pattern=$(echo "$pattern" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      if [ -n "$pattern" ]; then
        EXCLUDE_ARGS="$EXCLUDE_ARGS --exclude=$pattern"
      fi
    done
  fi

  # Execute rsync for each path
  while IFS= read -r path; do
    if [ -n "$path" ]; then
      FULL_PATH="/source/$path"
      echo "  📂 Syncing: $path"

      # Use --relative to preserve directory structure
      rsync -avh --relative $EXCLUDE_ARGS "/source/./$path" "$DEST_DIR/" || {
        echo "  ⚠️  Warning: rsync failed for $path"
      }
    fi
  done < "$INCLUDE_FILE"

  echo "✅ Advanced backup complete."

elif [ -n "$SOURCE_PATH" ]; then
  # Simple mode: Single source path (backward compatible)
  echo "📦 Simple Mode: Backing up single path"

  SRC_DIR="/source/${SOURCE_PATH}"

  # 1. Source must exist
  if [ ! -d "$SRC_DIR" ]; then
    echo "❌ Source directory $SRC_DIR does not exist."
    exit 1
  fi

  # 2. Refuse to treat / (root) as source
  if [ "$SRC_DIR" = "/" ]; then
    echo "❌ Refusing to use / as source."
    exit 1
  fi

  echo "📦 Rsyncing from $SRC_DIR/ → $DEST_DIR/"

  # Build exclude arguments for simple mode too
  EXCLUDE_ARGS=""
  if [ -n "$EXCLUDE_PATTERNS" ]; then
    echo "🚫 Applying exclude patterns:"
    echo "$EXCLUDE_PATTERNS" | tr ',' '\n' | while IFS= read -r pattern; do
      pattern=$(echo "$pattern" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      if [ -n "$pattern" ]; then
        echo "   - $pattern"
        EXCLUDE_ARGS="$EXCLUDE_ARGS --exclude=$pattern"
      fi
    done
  fi

  # -a : archive (recursive, preserve permissions/owners/timestamps, etc.)
  # -v : verbose (helps with Tekton log visibility)
  # -h : human-readable numbers
  # --delete : remove files in DEST that were deleted from SRC
  rsync -avh --delete $EXCLUDE_ARGS "$SRC_DIR/" "$DEST_DIR/"
  echo "✅ Rsync complete."

else
  echo "❌ Either SOURCE_PATH or INCLUDE_PATHS must be set"
  exit 1
fi
