#!/bin/bash
# Create a snapshot of current data + tag before upgrade/rebuild
set -euo pipefail

CONFIG_DIR="/workspaces/openai-cpa-codespaces"
SNAPSHOT_DIR="$CONFIG_DIR/.codespaces/snapshots"
DATA_DIR="/workspaces/openai-cpa-runtime/data"

mkdir -p "$SNAPSHOT_DIR"

# Read current tag (fallback to env or file)
CURRENT_TAG="${1:-}"
if [ -z "$CURRENT_TAG" ]; then
    CURRENT_TAG="${CPA_TAG:-v12.0.1}"
fi
if [ -f "$SNAPSHOT_DIR/latest/tag.txt" ]; then
    CURRENT_TAG=$(cat "$SNAPSHOT_DIR/latest/tag.txt")
fi

SNAPSHOT_ID=$(date +%Y%m%d-%H%M%S)
SNAPSHOT_PATH="$SNAPSHOT_DIR/$SNAPSHOT_ID"
mkdir -p "$SNAPSHOT_PATH/data"

# Backup data
cp -r "$DATA_DIR/"* "$SNAPSHOT_PATH/data/" 2>/dev/null || true

# Record tag
echo "$CURRENT_TAG" > "$SNAPSHOT_PATH/tag.txt"

# Update latest symlink
ln -sfn "$SNAPSHOT_PATH" "$SNAPSHOT_DIR/latest"

# Cleanup old snapshots (keep last 10)
cd "$SNAPSHOT_DIR"
ls -1d [0-9]*-[0-9]* 2>/dev/null | sort | head -n -10 | xargs -r rm -rf 2>/dev/null || true

echo "$SNAPSHOT_ID"
