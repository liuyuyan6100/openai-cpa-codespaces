#!/bin/bash
# Save current data + tag as the single known-good snapshot (overwrites previous)
set -euo pipefail

CONFIG_DIR="/workspaces/openai-cpa-codespaces"
SNAPSHOT_DIR="$CONFIG_DIR/.codespaces/snapshots/latest"
DATA_DIR="/workspaces/openai-cpa-runtime/data"

mkdir -p "$SNAPSHOT_DIR/data"

# Read current tag
CURRENT_TAG="${1:-${CPA_TAG:-v12.0.1}}"

# Backup data (overwrite)
rm -rf "$SNAPSHOT_DIR/data/"*
cp -r "$DATA_DIR/"* "$SNAPSHOT_DIR/data/" 2>/dev/null || true

# Record tag
echo "$CURRENT_TAG" > "$SNAPSHOT_DIR/tag.txt"

echo "$CURRENT_TAG"
