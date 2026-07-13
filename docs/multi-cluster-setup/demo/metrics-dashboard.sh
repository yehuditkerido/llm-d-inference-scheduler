#!/bin/bash
# Real-time Metrics Dashboard for Multi-Cluster Demo
# Shows EPP metrics and simulated routing decisions

SPOKE1_EPP="https://epp-metrics.apps.aigrid-tenant1.aigriddev.sysdeseng.com"
SPOKE2_EPP="https://epp-metrics.apps.aigrid-tenant2.aigriddev.sysdeseng.com"
HUB_EPP="http://localhost:9002"  # Port-forward required

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

fetch_metric() {
    local url=$1
    local metric=$2
    curl -sk "$url/metrics" 2>/dev/null | grep "^$metric{" | grep -oP '\} \K[0-9.]+' | head -1
}

fetch_ready_endpoints() {
    local url=$1
    curl -sk "$url/metrics" 2>/dev/null | grep "^llm_d_epp_ready_endpoints{" | grep -oP '\} \K[0-9.]+' | head -1
}

calculate_score() {
    # Simple scoring: lower queue + lower kv_cache = better
    # Score = (1 - kv_cache) * 2 + (10 - queue) * 2
    local queue=$1
    local kv=$2
    local running=$3
    
    # Normalize and calculate (higher score = better)
    local kv_score=$(echo "scale=2; (1 - $kv) * 2" | bc 2>/dev/null || echo "2")
    local queue_score=$(echo "scale=2; (10 - $queue) / 5" | bc 2>/dev/null || echo "2")
    local total=$(echo "scale=2; $kv_score + $queue_score" | bc 2>/dev/null || echo "4")
    echo "$total"
}

while true; do
    clear
    
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║         Multi-Cluster Hub-and-Spoke Dashboard                    ║${NC}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}Time:${NC} $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    
    # Fetch Spoke1 metrics
    S1_QUEUE=$(fetch_metric "$SPOKE1_EPP" "llm_d_epp_average_queue_size")
    S1_KV=$(fetch_metric "$SPOKE1_EPP" "llm_d_epp_average_kv_cache_utilization")
    S1_RUNNING=$(fetch_metric "$SPOKE1_EPP" "llm_d_epp_average_running_requests")
    S1_READY=$(fetch_ready_endpoints "$SPOKE1_EPP")
    S1_QUEUE=${S1_QUEUE:-0}
    S1_KV=${S1_KV:-0}
    S1_RUNNING=${S1_RUNNING:-0}
    S1_READY=${S1_READY:-0}
    
    # Fetch Spoke2 metrics
    S2_QUEUE=$(fetch_metric "$SPOKE2_EPP" "llm_d_epp_average_queue_size")
    S2_KV=$(fetch_metric "$SPOKE2_EPP" "llm_d_epp_average_kv_cache_utilization")
    S2_RUNNING=$(fetch_metric "$SPOKE2_EPP" "llm_d_epp_average_running_requests")
    S2_READY=$(fetch_ready_endpoints "$SPOKE2_EPP")
    S2_QUEUE=${S2_QUEUE:-0}
    S2_KV=${S2_KV:-0}
    S2_RUNNING=${S2_RUNNING:-0}
    S2_READY=${S2_READY:-0}
    
    # Calculate scores
    S1_SCORE=$(calculate_score "$S1_QUEUE" "$S1_KV" "$S1_RUNNING")
    S2_SCORE=$(calculate_score "$S2_QUEUE" "$S2_KV" "$S2_RUNNING")
    
    # Determine winner
    if (( $(echo "$S1_SCORE > $S2_SCORE" | bc -l 2>/dev/null || echo "1") )); then
        WINNER="Spoke1 (us-east-2)"
        WINNER_COLOR=$GREEN
    elif (( $(echo "$S2_SCORE > $S1_SCORE" | bc -l 2>/dev/null || echo "0") )); then
        WINNER="Spoke2 (us-west-2)"
        WINNER_COLOR=$BLUE
    else
        WINNER="Tie - Round Robin"
        WINNER_COLOR=$YELLOW
    fi
    
    echo -e "${BOLD}┌─────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}│  ${GREEN}SPOKE 1 (aigrid-tenant1 / us-east-2)${NC}                           ${BOLD}│${NC}"
    echo -e "${BOLD}├─────────────────────────────────────────────────────────────────┤${NC}"
    printf "│  %-20s │  %-40s │\n" "Ready Endpoints:" "$S1_READY vLLM pods"
    printf "│  %-20s │  %-40s │\n" "Avg Queue Depth:" "$S1_QUEUE"
    printf "│  %-20s │  %-40s │\n" "Avg KV Cache:" "${S1_KV} ($(echo "scale=0; $S1_KV * 100" | bc 2>/dev/null || echo "0")%)"
    printf "│  %-20s │  %-40s │\n" "Avg Running Reqs:" "$S1_RUNNING"
    echo -e "${BOLD}│  ${CYAN}Routing Score:${NC}       │  ${BOLD}$S1_SCORE${NC}                                     │"
    echo -e "${BOLD}└─────────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    
    echo -e "${BOLD}┌─────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}│  ${BLUE}SPOKE 2 (aigrid-tenant2 / us-west-2)${NC}                           ${BOLD}│${NC}"
    echo -e "${BOLD}├─────────────────────────────────────────────────────────────────┤${NC}"
    printf "│  %-20s │  %-40s │\n" "Ready Endpoints:" "$S2_READY vLLM pods"
    printf "│  %-20s │  %-40s │\n" "Avg Queue Depth:" "$S2_QUEUE"
    printf "│  %-20s │  %-40s │\n" "Avg KV Cache:" "${S2_KV} ($(echo "scale=0; $S2_KV * 100" | bc 2>/dev/null || echo "0")%)"
    printf "│  %-20s │  %-40s │\n" "Avg Running Reqs:" "$S2_RUNNING"
    echo -e "${BOLD}│  ${CYAN}Routing Score:${NC}       │  ${BOLD}$S2_SCORE${NC}                                     │"
    echo -e "${BOLD}└─────────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    
    echo -e "${BOLD}╔═════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║  ${YELLOW}ROUTING DECISION${NC}                                                ${BOLD}║${NC}"
    echo -e "${BOLD}╠═════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BOLD}║${NC}  Next request would route to: ${WINNER_COLOR}${BOLD}$WINNER${NC}"
    echo -e "${BOLD}║${NC}                                                                 ${BOLD}║${NC}"
    echo -e "${BOLD}║${NC}  Scoring formula: (1 - kv_cache)*2 + (10 - queue)/5            ${BOLD}║${NC}"
    echo -e "${BOLD}║${NC}  Higher score = lower load = preferred target                  ${BOLD}║${NC}"
    echo -e "${BOLD}╚═════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}Press Ctrl+C to exit${NC}  |  Refreshing every 2 seconds..."
    
    sleep 2
done
