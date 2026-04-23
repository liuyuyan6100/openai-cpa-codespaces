#!/bin/bash
# Monitor daemon: track process + registration state, auto-restart reg if stopped
# v2: single-thread slow mode, reduced check frequency, daily limit
set -euo pipefail

REPO_DIR="$(dirname "$0")/.."
cd "$REPO_DIR"

LOG_DIR=".codespaces/logs"
RUN_DIR=".codespaces/run"
MIN_RUNTIME_MINUTES=${MIN_RUNTIME_MINUTES:-60}
MAX_CONSECUTIVE_FAILS=${MAX_CONSECUTIVE_FAILS:-5}
CHECK_INTERVAL=${CHECK_INTERVAL:-600}
REG_CHECK_INTERVAL=${REG_CHECK_INTERVAL:-1800}
API_BASE="http://127.0.0.1:8000"
DEFAULT_PASSWORD="${CPA_WEB_PASSWORD:-admin}"
MAX_DAILY_SUCCESS=${MAX_DAILY_SUCCESS:-30}

consecutive_fails=0
start_time=$(date +%s)
last_account_count=0
last_reg_check=0

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_DIR/monitor.log"
}

get_token() {
    curl -s -X POST "$API_BASE/api/login" \
        -H "Content-Type: application/json" \
        -d "{\"password\":\"$DEFAULT_PASSWORD\"}" 2>/dev/null | \
        python3 -c 'import sys,json; print(json.load(sys.stdin).get("token",""))' 2>/dev/null || echo ""
}

get_reg_status() {
    local token="$1"
    curl -s "$API_BASE/api/status" \
        -H "Authorization: Bearer $token" 2>/dev/null | \
        python3 -c 'import sys,json; print("running" if json.load(sys.stdin).get("is_running") else "stopped")' 2>/dev/null || echo "unknown"
}

get_today_success() {
    local today=$(date +%Y-%m-%d)
    local count=$(grep "$today" "$LOG_DIR/openai-cpa.log" 2>/dev/null | grep -cE '注册成功|凭据提取成功|一气呵成')
    echo "${count:-0}"
}
start_registration() {
    local token="$1"
    local response
    response=$(curl -s -X POST "$API_BASE/api/start" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" 2>/dev/null)
    log "Auto-start response: $response"
}

log "=== Monitor started (slow mode) ==="

while true; do
    sleep 60
    now=$(date +%s)
    elapsed=$(( (now - start_time) / 60 ))

    # Check 1: Process alive
    if [ -f "$RUN_DIR/openai-cpa.pid" ]; then
        pid=$(cat "$RUN_DIR/openai-cpa.pid")
        if ! kill -0 "$pid" 2>/dev/null; then
            log "openai-cpa process died. Exiting monitor."
            exit 1
        fi
    fi

    # Check 2: Daily limit
    today_success=$(get_today_success)
    if [ "$today_success" -ge "$MAX_DAILY_SUCCESS" ]; then
        log "Daily limit reached: $today_success/$MAX_DAILY_SUCCESS. Pausing auto-restart."
        continue
    fi

    # Check 3: Registration state (every REG_CHECK_INTERVAL seconds)
    if (( now - last_reg_check >= REG_CHECK_INTERVAL )); then
        last_reg_check=$now
        TOKEN=$(get_token)
        if [[ -n "$TOKEN" ]]; then
            STATUS=$(get_reg_status "$TOKEN")
            if [[ "$STATUS" == "stopped" ]]; then
                log "Registration is STOPPED. Auto-starting..."
                start_registration "$TOKEN"
            elif [[ "$STATUS" == "running" ]]; then
                : # normal
            else
                log "Unknown registration status: $STATUS"
            fi
        else
            log "Failed to get token for status check"
        fi
    fi

    # Check 4: Success/fail tracking (every CHECK_INTERVAL)
    if (( now - start_time < CHECK_INTERVAL )); then
        continue
    fi

    current_success=$(grep -cE '注册成功|凭据提取成功|一气呵成' "$LOG_DIR/openai-cpa.log" 2>/dev/null || echo 0)
    current_fail=$(grep -cE '注册失败|风控|手机验证|Cloudflare|403|429' "$LOG_DIR/openai-cpa.log" 2>/dev/null || echo 0)

    if [ "$current_success" -le "$last_account_count" ]; then
        consecutive_fails=$((consecutive_fails + 1))
        log "No new success. consecutive_fails=$consecutive_fails elapsed=${elapsed}m"
    else
        consecutive_fails=0
        last_account_count=$current_success
        log "Success detected. Total=$current_success elapsed=${elapsed}m"
    fi

    if [ "$elapsed" -lt "$MIN_RUNTIME_MINUTES" ]; then
        continue
    fi

    if [ "$consecutive_fails" -ge "$MAX_CONSECUTIVE_FAILS" ]; then
        log "THRESHOLD REACHED: $consecutive_fails consecutive failures. Stopping."
        if [ -f "$RUN_DIR/openai-cpa.pid" ]; then
            kill "$(cat "$RUN_DIR/openai-cpa.pid")" 2>/dev/null || true
        fi
        bash .devcontainer/sync-back.sh 2>/dev/null || true
        exit 0
    fi
done
