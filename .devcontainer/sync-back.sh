#!/bin/bash
# Sync tokens from Codespace back to VPS
# Requires VPS_SSH_HOST, VPS_SSH_USER, VPS_SSH_KEY to be set in environment

REPO_DIR="$(dirname "$0")/.."
cd "$REPO_DIR"

LOG_DIR=".codespaces/logs"
VPS_AUTHS_DIR="/home/ubuntu/cpa/data/auths"
VPS_SSH_PORT="${VPS_SSH_PORT:-22}"

if [ -z "$VPS_SSH_HOST" ] || [ -z "$VPS_SSH_USER" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: VPS_SSH_HOST and VPS_SSH_USER must be set" >> "$LOG_DIR/sync-back.log"
    exit 1
fi

# Write SSH key if provided via env
if [ -n "$VPS_SSH_KEY" ]; then
    mkdir -p ~/.ssh
    echo "$VPS_SSH_KEY" > ~/.ssh/codespace_sync_key
    chmod 600 ~/.ssh/codespace_sync_key
    SSH_OPTS="-i ~/.ssh/codespace_sync_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
else
    SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
fi

# Find new token files
TOKEN_DIR="data/tokens"
if [ ! -d "$TOKEN_DIR" ]; then
    TOKEN_DIR="cpa/data/auths"
fi
if [ ! -d "$TOKEN_DIR" ]; then
    TOKEN_DIR="/home/ubuntu/cpa/data/auths"
fi

# Fallback: find any json files with oauth tokens
json_files=$(find . -name '*.json' -path '*/auths/*' 2>/dev/null | head -50)
if [ -z "$json_files" ]; then
    json_files=$(find . -name 'codex_oauth_*.json' 2>/dev/null | head -50)
fi

if [ -z "$json_files" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] No token files found to sync" >> "$LOG_DIR/sync-back.log"
    exit 0
fi

# Sync via SCP
echo "$json_files" | tar czf - -T - | ssh $SSH_OPTS -p "$VPS_SSH_PORT" "$VPS_SSH_USER@$VPS_SSH_HOST" \
    "mkdir -p $VPS_AUTHS_DIR && cd $VPS_AUTHS_DIR && tar xzf -"

if [ $? -eq 0 ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Synced $(echo "$json_files" | wc -l) tokens to $VPS_SSH_HOST" >> "$LOG_DIR/sync-back.log"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Sync failed" >> "$LOG_DIR/sync-back.log"
fi
