#!/bin/bash
# Rollback openai-cpa to a previous snapshot
set -euo pipefail

CONFIG_DIR="/workspaces/openai-cpa-codespaces"
CODE_DIR="/workspaces/openai-cpa-runtime"
SNAPSHOT_DIR="$CONFIG_DIR/.codespaces/snapshots"
LOG_DIR="$CONFIG_DIR/.codespaces/logs"
RUN_DIR="$CONFIG_DIR/.codespaces/run"
PATCH_DIR="$CONFIG_DIR/.devcontainer/patches"

mkdir -p "$LOG_DIR" "$RUN_DIR"

SNAPSHOT_ID="${1:-}"
if [ -z "$SNAPSHOT_ID" ]; then
    # Use latest snapshot
    if [ -L "$SNAPSHOT_DIR/latest" ]; then
        SNAPSHOT_PATH=$(readlink -f "$SNAPSHOT_DIR/latest")
        SNAPSHOT_ID=$(basename "$SNAPSHOT_PATH")
    else
        echo "ERROR: No snapshot found. Usage: rollback.sh <snapshot-id>"
        exit 1
    fi
fi

SNAPSHOT_PATH="$SNAPSHOT_DIR/$SNAPSHOT_ID"
if [ ! -d "$SNAPSHOT_PATH" ]; then
    echo "ERROR: Snapshot $SNAPSHOT_PATH not found"
    exit 1
fi

TARGET_TAG=$(cat "$SNAPSHOT_PATH/tag.txt" 2>/dev/null || echo "v12.0.1")

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_DIR/rollback.log"
}

log "=== Rollback to $SNAPSHOT_ID (tag: $TARGET_TAG) ==="

# 1. Stop current engine
if [ -f "$RUN_DIR/openai-cpa.pid" ]; then
    PID=$(cat "$RUN_DIR/openai-cpa.pid")
    if kill -0 "$PID" 2>/dev/null; then
        log "Stopping engine PID=$PID"
        kill "$PID" 2>/dev/null || true
        sleep 3
    fi
    rm -f "$RUN_DIR/openai-cpa.pid"
fi

# 2. Re-fetch old tag
rm -rf "$CODE_DIR"
TMP=$(mktemp -d)
cd "$TMP"
git init --quiet
git remote add origin https://github.com/wenfxl/openai-cpa.git

if ! git fetch origin tag "$TARGET_TAG" --no-tags --depth=1 > /dev/null 2>&1; then
    log "ERROR: Failed to fetch tag $TARGET_TAG"
    rm -rf "$TMP"
    exit 1
fi

git checkout "$TARGET_TAG" --quiet

# 3. Apply patches
for p in "$PATCH_DIR"/*.patch; do
    if [ -f "$p" ]; then
        patch -p1 --forward --quiet < "$p" > /dev/null 2>&1 || log "WARN: Patch $(basename "$p") skipped"
    fi
done

mkdir -p "$CODE_DIR"
cp -r ./* "$CODE_DIR/"
rm -rf "$TMP"

# 4. Restore data
mkdir -p "$CODE_DIR/data"
cp -r "$SNAPSHOT_PATH/data/"* "$CODE_DIR/data/" 2>/dev/null || true

# 5. Inject config
if [ -f "$CONFIG_DIR/.devcontainer/config.template.yaml" ] && [ -f "$CONFIG_DIR/.devcontainer/inject-config.py" ]; then
    python3 "$CONFIG_DIR/.devcontainer/inject-config.py" \
        "$CONFIG_DIR/.devcontainer/config.template.yaml" \
        "$CODE_DIR/data/config.yaml" > /dev/null 2>&1 || true
fi

# 6. Start engine
cd "$CODE_DIR"
export PYTHONPATH="$CODE_DIR"
export PYTHONUNBUFFERED=1
"$CODE_DIR/.venv/bin/python" wfxl_openai_regst.py >> "$LOG_DIR/openai-cpa.log" 2>&1 &
PID=$!
echo $PID > "$RUN_DIR/openai-cpa.pid"
log "Started engine PID=$PID"

# 7. Health check
sleep 5
if bash "$CONFIG_DIR/.devcontainer/scripts/health-check.sh" > /dev/null 2>&1; then
    log "SUCCESS: Rollback completed, engine healthy"
else
    log "WARNING: Rollback completed but engine may not be fully ready yet"
fi
