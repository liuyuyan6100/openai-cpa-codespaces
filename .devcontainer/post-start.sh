#!/bin/bash
# Codespace openai-cpa launcher (python:3.11-slim native venv edition)
# Pulls official tag, applies local patches, injects config from env/secrets, starts engine

set -euo pipefail

CPA_TAG="${CPA_TAG:-v12.0.1}"
CODE_DIR="/workspaces/openai-cpa-runtime"
PATCH_DIR="/workspaces/openai-cpa-codespaces/.devcontainer/patches"
LOG_DIR="/workspaces/openai-cpa-codespaces/.codespaces/logs"
RUN_DIR="/workspaces/openai-cpa-codespaces/.codespaces/run"

mkdir -p "$LOG_DIR" "$RUN_DIR"

# Step 1: fetch official code if not present
if [[ ! -f "$CODE_DIR/wfxl_openai_regst.py" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Fetching openai-cpa $CPA_TAG ..." | tee -a "$LOG_DIR/codespace.log"
    TMP=$(mktemp -d)
    cd "$TMP"
    git init --quiet
    git remote add origin https://github.com/wenfxl/openai-cpa.git
    git fetch origin tag "$CPA_TAG" --no-tags --depth=1
    git checkout "$CPA_TAG" --quiet

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Applying patches ..." | tee -a "$LOG_DIR/codespace.log"
    for p in "$PATCH_DIR"/*.patch; do
        if [[ -f "$p" ]]; then
            patch -p1 --forward --quiet < "$p" || echo "  warn: $(basename "$p") may have conflicts or already applied"
        fi
    done

    mkdir -p "$CODE_DIR"
    cp -r ./* "$CODE_DIR/"
    cp ./.gitignore "$CODE_DIR/" 2>/dev/null || true
    rm -rf "$TMP"
fi

cd "$CODE_DIR"

# Step 2: setup native venv (python:3.11-slim, no conda)
VENV_DIR="/workspaces/openai-cpa-runtime/.venv"
if [[ ! -f "$VENV_DIR/bin/python" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Creating native venv ..." | tee -a "$LOG_DIR/codespace.log"
    python3 -m venv "$VENV_DIR"
fi
"$VENV_DIR/bin/pip" install -r requirements.txt -q 2>&1 | tail -3

# Step 3: inject config from environment / secrets
mkdir -p data
CONFIG_TEMPLATE="/workspaces/openai-cpa-codespaces/.devcontainer/config.template.yaml"
if [[ -f "$CONFIG_TEMPLATE" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Injecting config from template ..." | tee -a "$LOG_DIR/codespace.log"
    python3 /workspaces/openai-cpa-codespaces/.devcontainer/inject-config.py         "$CONFIG_TEMPLATE" data/config.yaml
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: config.template.yaml not found" | tee -a "$LOG_DIR/codespace.log"
fi

# Step 4: start engine
PORT="${PORT:-8000}"
export PYTHONPATH="$CODE_DIR"
export PYTHONUNBUFFERED=1
"$VENV_DIR/bin/python" wfxl_openai_regst.py >> "$LOG_DIR/openai-cpa.log" 2>&1 &
PID=$!
echo $PID > "$RUN_DIR/openai-cpa.pid"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Started openai-cpa PID=$PID on port $PORT" | tee -a "$LOG_DIR/codespace.log"

# Step 5: start monitor
bash /workspaces/openai-cpa-codespaces/.devcontainer/monitor.sh >> "$LOG_DIR/monitor.log" 2>&1 &
echo $! > "$RUN_DIR/monitor.pid"

# Step 6: print access URL
CODESPACE_NAME="${CODESPACE_NAME:-}"
if [[ -n "$CODESPACE_NAME" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Access URL: https://${CODESPACE_NAME}-8000.app.github.dev/" | tee -a "$LOG_DIR/codespace.log"
fi

# Step 7: auto-start registration engine
sleep 5
bash /workspaces/openai-cpa-codespaces/.devcontainer/auto-start-reg.sh
