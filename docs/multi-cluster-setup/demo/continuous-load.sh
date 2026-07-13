#!/bin/bash
# Continuous streaming load generator (Production Mode)
# Sends all requests through Hub Gateway - EPP decides routing
# Run this in a separate terminal while watching the dashboard

HUB_GATEWAY="https://inference.apps.aigrid-hub.aigriddev.sysdeseng.com"

CONCURRENCY="${1:-10}"  # Number of concurrent requests per batch
INTERVAL="${2:-3}"      # Seconds between batches

echo "============================================================"
echo "  Continuous Load Generator (Production Mode)"
echo "============================================================"
echo ""
echo "  Hub Gateway: $HUB_GATEWAY"
echo "  Concurrency: $CONCURRENCY requests per batch"
echo "  Interval: ${INTERVAL}s between batches"
echo ""
echo "  Flow: Client -> Hub -> EPP -> Spoke -> EPP -> vLLM"
echo ""
echo "  Press Ctrl+C to stop"
echo "============================================================"
echo ""

cleanup() {
    echo ""
    echo "Stopping... Total batches: $BATCH, Total requests: $TOTAL_REQUESTS"
    jobs -p | xargs -r kill 2>/dev/null
    exit 0
}
trap cleanup SIGINT SIGTERM

BATCH=0
TOTAL_REQUESTS=0

while true; do
    BATCH=$((BATCH + 1))
    echo "[$(date +%H:%M:%S)] Batch $BATCH: Sending $CONCURRENCY requests through Hub..."
    
    for i in $(seq 1 $CONCURRENCY); do
        curl -sk -N -X POST "$HUB_GATEWAY/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d '{"model": "TinyLlama/TinyLlama-1.1B-Chat-v1.0", "messages": [{"role": "user", "content": "Write a very detailed and long story about adventures in space with many plot twists and character developments. Include dialogue between characters."}], "max_tokens": 1500, "stream": true}' \
            -o /dev/null &
    done
    TOTAL_REQUESTS=$((TOTAL_REQUESTS + CONCURRENCY))
    
    # Wait for batch to complete, then pause before next
    wait
    echo "  Batch complete. Total requests so far: $TOTAL_REQUESTS"
    sleep $INTERVAL
done
