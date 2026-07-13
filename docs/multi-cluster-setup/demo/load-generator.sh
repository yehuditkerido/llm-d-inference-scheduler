#!/bin/bash
# Multi-Cluster Load Generator (Production Mode)
# Sends all requests through the Hub Gateway - the EPP decides which Spoke to route to
# Uses streaming mode to keep connections open longer (better for metrics observation)

HUB_GATEWAY="https://inference.apps.aigrid-hub.aigriddev.sysdeseng.com"

# Request payload - uses streaming for sustained load visibility
PAYLOAD='{
  "model": "TinyLlama/TinyLlama-1.1B-Chat-v1.0",
  "messages": [{"role": "user", "content": "Write a detailed story about space exploration with many characters and plot developments. Include technical details about the spacecraft and mission objectives."}],
  "max_tokens": 1000,
  "temperature": 0.7,
  "stream": true
}'

REQUEST_COUNT=0

send_request() {
    REQUEST_COUNT=$((REQUEST_COUNT + 1))
    echo "[$(date +%H:%M:%S)] Request #$REQUEST_COUNT -> Hub Gateway (EPP will route to best Spoke)"
    curl -sk -N -X POST "$HUB_GATEWAY/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" \
        -o /dev/null -w "  Response: %{http_code} in %{time_total}s\n" 2>&1
}

echo "========================================"
echo "  Multi-Cluster Load Generator"
echo "  (Production Mode - All via Hub)"
echo "========================================"
echo ""
echo "Hub Gateway: $HUB_GATEWAY"
echo ""
echo "Flow: Client -> Hub Envoy -> Hub EPP -> Spoke Envoy -> Spoke EPP -> vLLM"
echo ""

# Parse arguments
MODE="${1:-steady}"   # steady, burst, ramp
RATE="${2:-1}"        # requests per second (for steady mode)
DURATION="${3:-60}"   # duration in seconds

echo "Configuration:"
echo "  Mode: $MODE"
echo "  Rate: $RATE req/sec"
echo "  Duration: ${DURATION}s"
echo ""
echo "Press Ctrl+C to stop"
echo "========================================"
echo ""

cleanup() {
    echo ""
    echo "Stopping... Total requests sent: $REQUEST_COUNT"
    jobs -p | xargs -r kill 2>/dev/null
    exit 0
}
trap cleanup SIGINT SIGTERM

SLEEP_TIME=$(echo "scale=2; 1/$RATE" | bc)
END_TIME=$((SECONDS + DURATION))

case $MODE in
    steady)
        echo "Steady load at $RATE req/sec..."
        while [ $SECONDS -lt $END_TIME ]; do
            send_request
            sleep $SLEEP_TIME
        done
        ;;
    burst)
        echo "Burst mode: 10 concurrent requests every 5 seconds..."
        while [ $SECONDS -lt $END_TIME ]; do
            echo "[$(date +%H:%M:%S)] Burst: 10 concurrent requests..."
            for i in {1..10}; do
                curl -sk -N -X POST "$HUB_GATEWAY/v1/chat/completions" \
                    -H "Content-Type: application/json" \
                    -d "$PAYLOAD" \
                    -o /dev/null &
                REQUEST_COUNT=$((REQUEST_COUNT + 1))
            done
            wait
            echo "  Burst complete"
            sleep 5
        done
        ;;
    ramp)
        echo "Ramp mode: Increasing concurrency over time..."
        CONCURRENCY=1
        while [ $SECONDS -lt $END_TIME ]; do
            echo "[$(date +%H:%M:%S)] Concurrency: $CONCURRENCY"
            for i in $(seq 1 $CONCURRENCY); do
                curl -sk -N -X POST "$HUB_GATEWAY/v1/chat/completions" \
                    -H "Content-Type: application/json" \
                    -d "$PAYLOAD" \
                    -o /dev/null &
                REQUEST_COUNT=$((REQUEST_COUNT + 1))
            done
            wait
            sleep 3
            CONCURRENCY=$((CONCURRENCY + 1))
            [ $CONCURRENCY -gt 20 ] && CONCURRENCY=20
        done
        ;;
esac

echo ""
echo "Load generation complete! Total requests: $REQUEST_COUNT"
