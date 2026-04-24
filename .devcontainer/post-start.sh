#!/bin/bash
# Codespace openai-cpa launcher (python:3.11-slim native venv edition)
# Pulls official tag, applies local patches, injects config from env/secrets, starts engine
# v3: pre-start snapshot + post-start health check + auto-rollback on failure

set -euo pipefail

CPA_TAG="${CPA_TAG:-v12.0.1}"
CODE_DIR="/workspaces/openai-cpa-runtime"
CONFIG_DIR="/workspaces/openai-cpa-codespaces"
PATCH_DIR="$CONFIG_DIR/.devcontainer/patches"
SCRIPTS_DIR="$CONFIG_DIR/.devcontainer/scripts"
LOG_DIR="$CONFIG_DIR/.codespaces/logs"
RUN_DIR="$CONFIG_DIR/.codespaces/run"
SNAPSHOT_DIR="$CONFIG_DIR/.codespaces/snapshots"

mkdir -p "$LOG_DIR" "$RUN_DIR" "$SNAPSHOT_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_DIR/codespace.log"
}

# Pre-start: snapshot current data if it exists
if [ -d "$CODE_DIR/data" ]; then
    log "Pre-start snapshot ..."
    bash "$SCRIPTS_DIR/snapshot.sh" "$CPA_TAG" > /dev/null 2>&1 || true
fi

# Step 1: fetch official code if not present
if [[ ! -f "$CODE_DIR/wfxl_openai_regst.py" ]]; then
    log "Fetching openai-cpa $CPA_TAG ..."
    TMP=$(mktemp -d)
    cd "$TMP"
    git init --quiet
    git remote add origin https://github.com/wenfxl/openai-cpa.git
    if ! git fetch origin tag "$CPA_TAG" --no-tags --depth=1 > /dev/null 2>&1; then
        log "ERROR: Failed to fetch tag $CPA_TAG"
        rm -rf "$TMP"
        exit 1
    fi
    git checkout "$CPA_TAG" --quiet

    log "Applying patches ..."
    PATCH_OK=true
    for p in "$PATCH_DIR"/*.patch; do
        if [[ -f "$p" ]]; then
            if ! patch -p1 --forward --quiet < "$p" > /dev/null 2>&1; then
                PATCH_OK=false
                log "WARN: $(basename "$p") failed"
            fi
        fi
    done

    if [ "$PATCH_OK" = false ]; then
        log "WARNING: Some patches failed. Engine may not function correctly."
    fi

    mkdir -p "$CODE_DIR"
    cp -r ./* "$CODE_DIR/"
    cp ./.gitignore "$CODE_DIR/" 2>/dev/null || true
    rm -rf "$TMP"
fi

cd "$CODE_DIR"

# Step 2: setup native venv (python:3.11-slim, no conda)
VENV_DIR="/workspaces/openai-cpa-runtime/.venv"
if [[ ! -f "$VENV_DIR/bin/python" ]]; then
    log "Creating native venv ..."
    python3 -m venv "$VENV_DIR"
fi
"$VENV_DIR/bin/pip" install -r requirements.txt -q 2>&1 | tail -3

# Step 3: inject config from environment / secrets
mkdir -p data
CONFIG_TEMPLATE="$CONFIG_DIR/.devcontainer/config.template.yaml"
if [[ -f "$CONFIG_TEMPLATE" ]]; then
    log "Injecting config from template ..."
    python3 "$CONFIG_DIR/.devcontainer/inject-config.py" \
        "$CONFIG_TEMPLATE" data/config.yaml
else
    log "WARNING: config.template.yaml not found"
fi

# Step 4: start engine
PORT="${PORT:-8000}"
export PYTHONPATH="$CODE_DIR"
export PYTHONUNBUFFERED=1
"$VENV_DIR/bin/python" wfxl_openai_regst.py >> "$LOG_DIR/openai-cpa.log" 2>&1 &
PID=$!
echo $PID > "$RUN_DIR/openai-cpa.pid"
log "Started openai-cpa PID=$PID on port $PORT"

# Step 4b: post-start health check + auto-rollback
sleep 8
if ! bash "$SCRIPTS_DIR/health-check.sh" > /dev/null 2>&1; then
    log "WARN: Health check failed after initial start."
    # Try to rollback to previous known-good tag if available
    if [ -f "$SNAPSHOT_DIR/latest/tag.txt" ]; then
        PREV_TAG=$(cat "$SNAPSHOT_DIR/latest/tag.txt")
        if [ "$PREV_TAG" != "$CPA_TAG" ]; then
            log "Attempting rollback to previous tag $PREV_TAG ..."
            if bash "$SCRIPTS_DIR/rollback.sh" > /dev/null 2>&1; then
                log "Rollback to $PREV_TAG completed."
            else
                log "ERROR: Rollback failed. Manual intervention required."
            fi
        fi
    fi
fi

# Step 5: start monitor
bash "$CONFIG_DIR/.devcontainer/monitor.sh" >> "$LOG_DIR/monitor.log" 2>&1 &
echo $! > "$RUN_DIR/monitor.pid"

# Step 6: print access URL
CODESPACE_NAME="${CODESPACE_NAME:-}"
if [[ -n "$CODESPACE_NAME" ]]; then
    log "Access URL: https://${CODESPACE_NAME}-8000.app.github.dev/"
fi

# Step 7: auto-start registration engine
sleep 5
bash "$CONFIG_DIR/.devcontainer/auto-start-reg.sh"
