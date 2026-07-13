#!/bin/bash
# Live Multi-Cluster Dashboard (Full E2E)
# Shows metrics, predicted routing, and actual Hub routing decisions

SPOKE1_EPP="https://epp-metrics.apps.aigrid-tenant1.aigriddev.sysdeseng.com"
SPOKE2_EPP="https://epp-metrics.apps.aigrid-tenant2.aigriddev.sysdeseng.com"
HUB_EPP="https://epp-metrics-llm-d-system.apps.aigrid-hub.aigriddev.sysdeseng.com"

# Hub Gateway for actual routing
HUB_GATEWAY="https://inference.apps.aigrid-hub.aigriddev.sysdeseng.com"

# Kubeconfig for Hub (adjust path if needed)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HUB_KUBECONFIG="$SCRIPT_DIR/../hub/auth/kubeconfig"

# Colors
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

fetch_metric() {
    local metrics=$1
    local pattern=$2
    echo "$metrics" | grep "^$pattern{" | grep -oP '\} \K[0-9.e+-]+' | head -1
}

calculate_scores() {
    # Demo scoring: absolute reference (produces fractional scores for visualization)
    # Preserves correctness: same winner as EPP min-max normalization
    # queue-scorer weight=2, kv-cache-scorer weight=2
    local s1_queue=$1 s1_kv=$2 s1_running=$3
    local s2_queue=$4 s2_kv=$5 s2_running=$6
    
    # Queue: lower is better. Score 1.0 at queue=0, score 0.0 at queue>=50
    S1_Q_SCORE=$(echo "scale=2; x = 1 - $s1_queue / 50; if (x < 0) 0 else x" | bc 2>/dev/null || echo "1.00")
    S2_Q_SCORE=$(echo "scale=2; x = 1 - $s2_queue / 50; if (x < 0) 0 else x" | bc 2>/dev/null || echo "1.00")
    
    # KV cache: lower is better. kv is 0-1, so score = 1 - kv
    S1_KV_SCORE=$(echo "scale=2; 1 - $s1_kv" | bc 2>/dev/null || echo "1.00")
    S2_KV_SCORE=$(echo "scale=2; 1 - $s2_kv" | bc 2>/dev/null || echo "1.00")
    
    # Final weighted score: queue*2 + kv*2 (0-4 range)
    S1_SCORE=$(echo "scale=2; $S1_Q_SCORE * 2 + $S1_KV_SCORE * 2" | bc 2>/dev/null || echo "2.00")
    S2_SCORE=$(echo "scale=2; $S2_Q_SCORE * 2 + $S2_KV_SCORE * 2" | bc 2>/dev/null || echo "2.00")
}

while true; do
    clear
    
    # Fetch all metrics
    S1_METRICS=$(curl -sk "$SPOKE1_EPP/metrics" 2>/dev/null)
    S2_METRICS=$(curl -sk "$SPOKE2_EPP/metrics" 2>/dev/null)
    HUB_METRICS=$(curl -sk "$HUB_EPP/metrics" 2>/dev/null)
    
    # Parse Spoke1
    S1_QUEUE=$(fetch_metric "$S1_METRICS" "llm_d_epp_average_queue_size")
    S1_KV=$(fetch_metric "$S1_METRICS" "llm_d_epp_average_kv_cache_utilization")
    S1_RUNNING=$(fetch_metric "$S1_METRICS" "llm_d_epp_average_running_requests")
    S1_READY=$(fetch_metric "$S1_METRICS" "llm_d_epp_ready_endpoints")
    S1_QUEUE=${S1_QUEUE:-0}; S1_KV=${S1_KV:-0}; S1_RUNNING=${S1_RUNNING:-0}; S1_READY=${S1_READY:-0}
    
    # Parse Spoke2
    S2_QUEUE=$(fetch_metric "$S2_METRICS" "llm_d_epp_average_queue_size")
    S2_KV=$(fetch_metric "$S2_METRICS" "llm_d_epp_average_kv_cache_utilization")
    S2_RUNNING=$(fetch_metric "$S2_METRICS" "llm_d_epp_average_running_requests")
    S2_READY=$(fetch_metric "$S2_METRICS" "llm_d_epp_ready_endpoints")
    S2_QUEUE=${S2_QUEUE:-0}; S2_KV=${S2_KV:-0}; S2_RUNNING=${S2_RUNNING:-0}; S2_READY=${S2_READY:-0}
    
    # Parse Hub
    HUB_READY=$(fetch_metric "$HUB_METRICS" "llm_d_epp_ready_endpoints")
    HUB_READY=${HUB_READY:-0}
    
    # Calculate scores (EPP-style: normalized, weighted)
    calculate_scores "$S1_QUEUE" "$S1_KV" "$S1_RUNNING" "$S2_QUEUE" "$S2_KV" "$S2_RUNNING"
    
    # Determine routing decision
    if (( $(echo "$S1_SCORE > $S2_SCORE" | bc -l 2>/dev/null || echo 1) )); then
        WINNER="Spoke1 (aigrid-tenant1)"
        WINNER_COLOR=$GREEN
        LOSER_COLOR=$RED
    elif (( $(echo "$S2_SCORE > $S1_SCORE" | bc -l 2>/dev/null || echo 0) )); then
        WINNER="Spoke2 (aigrid-tenant2)"
        WINNER_COLOR=$CYAN
        LOSER_COLOR=$RED
    else
        WINNER="Either (Tie)"
        WINNER_COLOR=$YELLOW
        LOSER_COLOR=$YELLOW
    fi
    
    # Display
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║        Multi-Cluster Hub-and-Spoke Live Dashboard                       ║${NC}"
    echo -e "${BOLD}${CYAN}║        $(date '+%Y-%m-%d %H:%M:%S')                                                   ║${NC}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Hub Status
    echo -e "${BOLD}╔═══════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║ ${YELLOW}HUB EPP${NC} - aigrid-hub | Ready Spokes: ${BOLD}$HUB_READY${NC}                                ${BOLD}║${NC}"
    echo -e "${BOLD}╚═══════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Spoke comparison table
    echo -e "${BOLD}┌─────────────────────────────────┬─────────────────────────────────┐${NC}"
    echo -e "${BOLD}│${NC} ${GREEN}SPOKE 1 (aigrid-tenant1)${NC}        ${BOLD}│${NC} ${CYAN}SPOKE 2 (aigrid-tenant2)${NC}        ${BOLD}│${NC}"
    echo -e "${BOLD}├─────────────────────────────────┼─────────────────────────────────┤${NC}"
    printf "│  Ready Pods:       %-12s │  Ready Pods:       %-12s │\n" "$S1_READY" "$S2_READY"
    printf "│  Queue Depth:      %-12s │  Queue Depth:      %-12s │\n" "$S1_QUEUE" "$S2_QUEUE"
    printf "│  Running Requests: %-12s │  Running Requests: %-12s │\n" "$S1_RUNNING" "$S2_RUNNING"
    printf "│  KV Cache Usage:   %-12s │  KV Cache Usage:   %-12s │\n" "$S1_KV" "$S2_KV"
    echo -e "${BOLD}├─────────────────────────────────┼─────────────────────────────────┤${NC}"
    printf "│  ${BOLD}ROUTING SCORE:     %-12s${NC} │  ${BOLD}ROUTING SCORE:     %-12s${NC} │\n" "$S1_SCORE" "$S2_SCORE"
    echo -e "${BOLD}└─────────────────────────────────┴─────────────────────────────────┘${NC}"
    echo ""
    
    # Routing Decision
    echo -e "${BOLD}╔═══════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║${NC}  ${BOLD}PREDICTED ROUTING:${NC} Next request routes to ${WINNER_COLOR}${BOLD}$WINNER${NC}"
    echo -e "${BOLD}║${NC}  EPP scoring: queue_score*2 + kv_score*2 (higher = preferred)"
    echo -e "${BOLD}╚═══════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Recent Hub Routing Decisions (actual traffic)
    echo -e "${BOLD}╔═══════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║${NC}  ${YELLOW}RECENT HUB ROUTING (last 5 requests)${NC}"
    echo -e "${BOLD}╠═══════════════════════════════════════════════════════════════════════════╣${NC}"
    
    # Try to get Hub Envoy logs if kubeconfig exists
    if [ -f "$HUB_KUBECONFIG" ]; then
        RECENT_ROUTES=$(KUBECONFIG="$HUB_KUBECONFIG" oc -n llm-d-system logs deploy/envoy --tail=20 2>/dev/null | grep "POST" | tail -5)
        if [ -n "$RECENT_ROUTES" ]; then
            while IFS= read -r line; do
                # Extract timestamp, destination, status, and duration
                TS=$(echo "$line" | grep -oP '\[\K[^\]]+')
                DEST=$(echo "$line" | grep -oP 'aigrid-tenant\d')
                STATUS=$(echo "$line" | grep -oP '\d{3}(?=\s+\d+ms)')
                DURATION=$(echo "$line" | grep -oP '\d+(?=ms)')
                
                if [ -n "$DEST" ]; then
                    if [ "$DEST" = "aigrid-tenant1" ]; then
                        echo -e "${BOLD}║${NC}  ${GREEN}[${TS}] -> Spoke1${NC} (${STATUS}, ${DURATION}ms)"
                    else
                        echo -e "${BOLD}║${NC}  ${CYAN}[${TS}] -> Spoke2${NC} (${STATUS}, ${DURATION}ms)"
                    fi
                fi
            done <<< "$RECENT_ROUTES"
        else
            echo -e "${BOLD}║${NC}  (No recent requests)"
        fi
    else
        echo -e "${BOLD}║${NC}  (Hub kubeconfig not found - run from demo directory)"
    fi
    
    echo -e "${BOLD}╚═══════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}Hub Gateway:${NC} $HUB_GATEWAY"
    echo -e "  Refreshing every 2 seconds... Press ${BOLD}Ctrl+C${NC} to stop"
    
    sleep 2
done
