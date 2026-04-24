#!/bin/bash
# API health check for openai-cpa engine
set -uo pipefail

API_BASE="${1:-http://127.0.0.1:8000}"
PASSWORD="${CPA_WEB_PASSWORD:-admin}"
TIMEOUT="${2:-60}"

for i in $(seq 1 "$TIMEOUT"); do
    TOKEN=$(curl -s --max-time 5 -X POST "$API_BASE/api/login" \
        -H "Content-Type: application/json" \
        -d "{\"password\":\"$PASSWORD\"}" 2>/dev/null | \
        python3 -c 'import sys,json; print(json.load(sys.stdin).get("token",""))' 2>/dev/null)
    if [ -n "$TOKEN" ]; then
        STATUS=$(curl -s --max-time 5 "$API_BASE/api/status" -H "Authorization: Bearer $TOKEN" 2>/dev/null)
        if echo "$STATUS" | grep -q '"is_running"'; then
            echo "HEALTHY"
            exit 0
        fi
    fi
    sleep 1
done

echo "UNHEALTHY"
exit 1
