#!/bin/bash
# Upgrade openai-cpa to a new tag with automatic rollback on failure
# Uses single latest snapshot for rollback target
set -euo pipefail

NEW_TAG="${1:-}"
if [ -z "$NEW_TAG" ]; then
    echo "Usage: upgrade.sh <tag>"
    echo "Example: upgrade.sh v13.0.0"
    exit 1
fi

CONFIG_DIR="/workspaces/openai-cpa-codespaces"
CODE_DIR="/workspaces/openai-cpa-runtime"
SNAPSHOT_DIR="$CONFIG_DIR/.codespaces/snapshots/latest"
PATCH_DIR="$CONFIG_DIR/.devcontainer/patches"
LOG_DIR="$CONFIG_DIR/.codespaces/logs"
RUN_DIR="$CONFIG_DIR/.codespaces/run"
SCRIPTS_DIR="$CONFIG_DIR/.devcontainer/scripts"

mkdir -p "$LOG_DIR" "$RUN_DIR"

# Read current tag from running engine or env
CURRENT_TAG="${CPA_TAG:-v12.0.1}"
if [ -f "$SNAPSHOT_DIR/tag.txt" ]; then
    CURRENT_TAG=$(cat "$SNAPSHOT_DIR/tag.txt")
fi

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_DIR/upgrade.log"
}

rollback() {
    log "ROLLBACK triggered"
    bash "$SCRIPTS_DIR/rollback.sh"
}

log "=== Upgrade $CURRENT_TAG -> $NEW_TAG ==="

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

# 2. Backup old runtime
BAK_SUFFIX="bak-$(date +%s)"
if [ -d "$CODE_DIR" ]; then
    mv "$CODE_DIR" "${CODE_DIR}.${BAK_SUFFIX}"
fi

# 3. Fetch new tag
TMP=$(mktemp -d)
cd "$TMP"
git init --quiet
git remote add origin https://github.com/wenfxl/openai-cpa.git

if ! git fetch origin tag "$NEW_TAG" --no-tags --depth=1 > /dev/null 2>&1; then
    log "ERROR: Failed to fetch tag $NEW_TAG"
    rm -rf "$TMP"
    mv "${CODE_DIR}.${BAK_SUFFIX}" "$CODE_DIR"
    rollback
    exit 1
fi

git checkout "$NEW_TAG" --quiet

# 4. Apply patches
PATCH_OK=true
PATCH_FAILED=""
for p in "$PATCH_DIR"/*.patch; do
    if [ -f "$p" ]; then
        if ! patch -p1 --forward --quiet < "$p" > /dev/null 2>&1; then
            PATCH_OK=false
            PATCH_FAILED="$PATCH_FAILED $(basename "$p")"
            log "WARNING: Patch failed: $(basename "$p")"
        fi
    fi
done

if [ "$PATCH_OK" = false ]; then
    log "ERROR: Patches failed:$PATCH_FAILED"
    rm -rf "$TMP"
    mv "${CODE_DIR}.${BAK_SUFFIX}" "$CODE_DIR"
    rollback
    exit 1
fi

# 5. Deploy
mkdir -p "$CODE_DIR"
cp -r ./* "$CODE_DIR/"
rm -rf "$TMP"

# 6. Restore data from latest snapshot (if exists) to preserve accounts/config
if [ -d "$SNAPSHOT_DIR/data" ]; then
    mkdir -p "$CODE_DIR/data"
    cp -r "$SNAPSHOT_DIR/data/"* "$CODE_DIR/data/" 2>/dev/null || true
fi

# 7. Inject config
if [ -f "$CONFIG_DIR/.devcontainer/config.template.yaml" ] && [ -f "$CONFIG_DIR/.devcontainer/inject-config.py" ]; then
    python3 "$CONFIG_DIR/.devcontainer/inject-config.py" \
        "$CONFIG_DIR/.devcontainer/config.template.yaml" \
        "$CODE_DIR/data/config.yaml" > /dev/null 2>&1 || true
fi

# 8. Install deps if requirements changed
cd "$CODE_DIR"
if [ -f requirements.txt ] && [ -f ".venv/bin/pip" ]; then
    ".venv/bin/pip" install -r requirements.txt -q > /dev/null 2>&1 || true
fi

# 9. Start engine
export PYTHONPATH="$CODE_DIR"
export PYTHONUNBUFFERED=1
"$CODE_DIR/.venv/bin/python" wfxl_openai_regst.py >> "$LOG_DIR/openai-cpa.log" 2>&1 &
PID=$!
echo $PID > "$RUN_DIR/openai-cpa.pid"
log "Started engine PID=$PID"

# 10. Health check
sleep 8
if ! bash "$SCRIPTS_DIR/health-check.sh" > /dev/null 2>&1; then
    log "ERROR: Health check failed after $NEW_TAG upgrade"
    kill "$PID" 2>/dev/null || true
    rm -f "$RUN_DIR/openai-cpa.pid"
    rm -rf "$CODE_DIR"
    mv "${CODE_DIR}.${BAK_SUFFIX}" "$CODE_DIR"
    rollback
    exit 1
fi

# 11. Upgrade succeeded: overwrite latest snapshot with new known-good state
bash "$SCRIPTS_DIR/snapshot.sh" "$NEW_TAG" > /dev/null 2>&1
log "Snapshot updated to $NEW_TAG"

# 12. Cleanup old backup
rm -rf "${CODE_DIR}.${BAK_SUFFIX}"

log "SUCCESS: Upgraded to $NEW_TAG"
