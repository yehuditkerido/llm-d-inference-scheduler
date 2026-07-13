#!/bin/bash
# Fetch metrics from EPPs and output in formats usable by dashboard

SPOKE1_EPP="https://epp-metrics.apps.aigrid-tenant1.aigriddev.sysdeseng.com"
SPOKE2_EPP="https://epp-metrics.apps.aigrid-tenant2.aigriddev.sysdeseng.com"
HUB_EPP="https://epp-metrics-llm-d-system.apps.aigrid-hub.aigriddev.sysdeseng.com"

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║       Multi-Cluster Hub-and-Spoke Metrics Snapshot              ║"
echo "║       $(date '+%Y-%m-%d %H:%M:%S')                                        ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

fetch_spoke_metrics() {
    local url=$1
    local name=$2
    
    echo "┌────────────────────────────────────────────────────────────────┐"
    echo "│ $name"
    echo "├────────────────────────────────────────────────────────────────┤"
    local metrics=$(curl -sk "$url/metrics" 2>/dev/null)
    
    if [ -z "$metrics" ]; then
        echo "│  ERROR: Could not fetch metrics"
        echo "└────────────────────────────────────────────────────────────────┘"
        return
    fi
    
    local queue=$(echo "$metrics" | grep "^llm_d_epp_average_queue_size{" | grep -oP '\} \K[0-9.]+' | head -1)
    local kv=$(echo "$metrics" | grep "^llm_d_epp_average_kv_cache_utilization{" | grep -oP '\} \K[0-9.]+' | head -1)
    local running=$(echo "$metrics" | grep "^llm_d_epp_average_running_requests{" | grep -oP '\} \K[0-9.]+' | head -1)
    local ready=$(echo "$metrics" | grep "^llm_d_epp_ready_endpoints{" | grep -oP '\} \K[0-9.]+' | head -1)
    
    printf "│  %-20s %s\n" "Ready vLLM Pods:" "${ready:-0}"
    printf "│  %-20s %s\n" "Avg Queue Depth:" "${queue:-0}"
    printf "│  %-20s %s\n" "Avg Running Reqs:" "${running:-0}"
    printf "│  %-20s %s\n" "Avg KV Cache:" "${kv:-0}"
    echo "└────────────────────────────────────────────────────────────────┘"
    echo ""
}

fetch_hub_metrics() {
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║ HUB EPP (aigrid-hub) - Cluster-Level View                     ║"
    echo "╠════════════════════════════════════════════════════════════════╣"
    
    local metrics=$(curl -sk "$HUB_EPP/metrics" 2>/dev/null)
    
    if [ -z "$metrics" ]; then
        echo "║  ERROR: Could not fetch Hub metrics"
        echo "╚════════════════════════════════════════════════════════════════╝"
        return
    fi
    
    local ready=$(echo "$metrics" | grep "^llm_d_epp_ready_endpoints{" | grep -oP '\} \K[0-9.]+' | head -1)
    local queue=$(echo "$metrics" | grep "^llm_d_epp_average_queue_size{" | grep -oP '\} \K[0-9.]+' | head -1)
    local kv=$(echo "$metrics" | grep "^llm_d_epp_average_kv_cache_utilization{" | grep -oP '\} \K[0-9.]+' | head -1)
    local running=$(echo "$metrics" | grep "^llm_d_epp_average_running_requests{" | grep -oP '\} \K[0-9.]+' | head -1)
    
    printf "║  %-20s %s Spoke clusters\n" "Ready Endpoints:" "${ready:-0}"
    printf "║  %-20s %s\n" "Avg Queue Depth:" "${queue:-0}"
    printf "║  %-20s %s\n" "Avg Running Reqs:" "${running:-0}"
    printf "║  %-20s %s\n" "Avg KV Cache:" "${kv:-0}"
    echo "╠════════════════════════════════════════════════════════════════╣"
    echo "║  Per-Cluster Metrics (from Hub's perspective):                ║"
    echo "$metrics" | grep "^llm_d_epp_per_endpoint" | while read line; do
        endpoint=$(echo "$line" | grep -oP 'model_server_endpoint="\K[^"]+')
        value=$(echo "$line" | grep -oP '\} \K[0-9.]+')
        metric_type=$(echo "$line" | grep -oP '^llm_d_epp_per_endpoint_\K[^{]+')
        printf "║    %-15s %s: %s\n" "$endpoint" "$metric_type" "$value"
    done
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
}

# Fetch from all components
fetch_spoke_metrics "$SPOKE1_EPP" "SPOKE 1 (aigrid-tenant1 / us-east-2)"
fetch_spoke_metrics "$SPOKE2_EPP" "SPOKE 2 (aigrid-tenant2 / us-west-2)"
fetch_hub_metrics

echo "Press Enter to refresh, Ctrl+C to exit"
