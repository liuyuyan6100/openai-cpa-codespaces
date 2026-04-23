#!/usr/bin/env bash
# Codespace 自动启动 openai-cpa 注册功能
# v2: single-thread slow mode, daily limit, random delay
set -euo pipefail

LOG_FILE="/workspaces/openai-cpa-codespaces/.codespaces/logs/auto-start.log"
mkdir -p "$(dirname "$LOG_FILE")"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

API_BASE="http://127.0.0.1:8000"
DEFAULT_PASSWORD="${CPA_WEB_PASSWORD:-admin}"
MAX_DAILY_SUCCESS=${MAX_DAILY_SUCCESS:-30}
LOG_DIR="/workspaces/openai-cpa-codespaces/.codespaces/logs"

# Random startup delay: 0-15 minutes (simulate human sitting down)
RANDOM_DELAY=$(( RANDOM % 900 ))
log "Random startup delay: ${RANDOM_DELAY}s ($((RANDOM_DELAY/60)) min)..."
sleep "$RANDOM_DELAY"

# Check daily limit
get_today_success() {
    local today=$(date +%Y-%m-%d)
    local count=$(grep "$today" "$LOG_DIR/openai-cpa.log" 2>/dev/null | grep -cE '注册成功|凭据提取成功|一气呵成')
    echo "${count:-0}"
}

# Wait for service ready
wait_for_service() {
    local max_wait=60
    local waited=0
    log "Waiting for openai-cpa service..."
    while ! curl -s -o /dev/null "$API_BASE/" 2>/dev/null; do
        sleep 2
        waited=$((waited + 2))
        if [[ $waited -ge $max_wait ]]; then
            log "Service not ready in ${max_wait}s"
            return 1
        fi
    done
    log "Service ready (${waited}s)"
    return 0
}

# Get login token
get_token() {
    local password="${1:-$DEFAULT_PASSWORD}"
    local response
    response=$(curl -s -X POST "$API_BASE/api/login" \
        -H "Content-Type: application/json" \
        -d "{\"password\":\"$password\"}" 2>/dev/null)
    echo "$response" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("token",""))' 2>/dev/null || echo ""
}

# Query status
get_status() {
    local token="$1"
    curl -s "$API_BASE/api/status" \
        -H "Authorization: Bearer $token" 2>/dev/null | \
        python3 -c 'import sys,json; print("running" if json.load(sys.stdin).get("is_running") else "stopped")' 2>/dev/null || echo "unknown"
}

# Start registration
start_registration() {
    local token="$1"
    local response
    response=$(curl -s -X POST "$API_BASE/api/start" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" 2>/dev/null)
    log "Start response: $response"
    if echo "$response" | grep -q '"status":"success"'; then
        log "Registration started"
        return 0
    else
        log "Start failed: $response"
        return 1
    fi
}

log "=== Auto-start (slow mode) ==="

# Check daily limit before starting
today_count=$(get_today_success)
if [[ "$today_count" -ge "$MAX_DAILY_SUCCESS" ]]; then
    log "Daily limit reached: $today_count/$MAX_DAILY_SUCCESS. Skipping start."
    exit 0
fi
log "Daily progress: $today_count/$MAX_DAILY_SUCCESS"

# 1. Wait for service
if ! wait_for_service; then
    log "Service not ready, exit"
    exit 1
fi

# 2. Get token
TOKEN=$(get_token)
if [[ -z "$TOKEN" ]]; then
    log "Login failed"
    exit 1
fi
log "Login OK"

# 3. Check current status
STATUS=$(get_status "$TOKEN")
log "Current status: $STATUS"

if [[ "$STATUS" == "running" ]]; then
    log "Already running"
    exit 0
fi

# 4. Start
if start_registration "$TOKEN"; then
    sleep 3
    NEW_STATUS=$(get_status "$TOKEN")
    log "Post-start status: $NEW_STATUS"
else
    log "Start command failed"
    exit 1
fi

log "=== Done ==="
