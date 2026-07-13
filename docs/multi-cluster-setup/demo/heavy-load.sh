#!/bin/bash
# Heavy continuous load - fires requests as fast as possible through Hub Gateway

HUB_GATEWAY="https://inference.apps.aigrid-hub.aigriddev.sysdeseng.com"

CONCURRENCY="${1:-20}"  # Default 20 concurrent

echo "============================================================"
echo "  HEAVY LOAD GENERATOR - $CONCURRENCY concurrent requests"
echo "============================================================"
echo "  Target: $HUB_GATEWAY"
echo "  Press Ctrl+C to stop"
echo "============================================================"
echo ""

cleanup() {
    echo ""
    echo "Stopping... Sent $TOTAL requests"
    pkill -P $$ 2>/dev/null
    exit 0
}
trap cleanup SIGINT SIGTERM

TOTAL=0

while true; do
    for i in $(seq 1 $CONCURRENCY); do
        curl -sk -X POST "$HUB_GATEWAY/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d '{"model": "TinyLlama/TinyLlama-1.1B-Chat-v1.0", "messages": [{"role": "user", "content": "Write a long detailed story"}], "max_tokens": 500, "stream": true}' \
            -o /dev/null &
    done
    TOTAL=$((TOTAL + CONCURRENCY))
    echo "[$(date +%H:%M:%S)] Fired $CONCURRENCY requests (total: $TOTAL)"
    sleep 0.5
done
