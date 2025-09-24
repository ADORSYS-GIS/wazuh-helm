#!/bin/bash
set -euxo pipefail

# Directory that must be wiped - use parameter passed via environment variable
DIRECTORY_PATH="${DIRECTORY_PATH:-}"
if [[ -z "$DIRECTORY_PATH" ]]; then
  echo "❌ DIRECTORY_PATH environment variable must be set"
  exit 1
fi

BACKUP_DIR="/backup/${DIRECTORY_PATH}"

# Safety checks ──────────────────────────────────────────────────────────────
# 1. Make sure the directory actually exists.
if [[ ! -d "$BACKUP_DIR" ]]; then
  echo "❌ Backup directory $BACKUP_DIR does not exist."
  exit 1
fi

# 2. Never allow / (filesystem root) or the workspace root to be nuked.
if [[ "$BACKUP_DIR" == "/" ]] || [[ "$BACKUP_DIR" == "/backup" ]]; then
  echo "❌ Refusing to clean unsafe directory: $BACKUP_DIR"
  exit 1
fi

# Cleanup ────────────────────────────────────────────────────────────────────
echo "🧹 Cleaning contents of $BACKUP_DIR ..."
# `find` is POSIX-portable and avoids "Argument list too long" issues.
find "$BACKUP_DIR" -mindepth 1 -delete
echo "✅ Cleanup complete."