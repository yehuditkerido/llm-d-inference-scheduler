# Multi-Cluster Hub-and-Spoke Demo

Live demo tools for visualizing full E2E multi-cluster routing in the llm-d router.

## Architecture (Full E2E Flow)

```
     Client Request
          │
          ▼
  ┌───────────────────┐
  │   Hub Gateway     │  inference.apps.aigrid-hub...
  │   (Envoy)         │
  └─────────┬─────────┘
            │ ext_proc
            ▼
  ┌───────────────────┐
  │     Hub EPP       │  Scores Spoke clusters
  │   file-discovery  │  Picks best Spoke
  │   spoke-epp type  │
  └─────────┬─────────┘
            │ x-gateway-destination-endpoint
            ▼
   ┌────────┴────────┐
   │                 │
   ▼                 ▼
┌─────────────┐  ┌─────────────┐
│Spoke1 Envoy │  │Spoke2 Envoy │  inference-gateway-llm-d-system.apps...
└──────┬──────┘  └──────┬──────┘
       │ ext_proc       │ ext_proc
       ▼                ▼
┌─────────────┐  ┌─────────────┐
│ Spoke1 EPP  │  │ Spoke2 EPP  │  Scores local vLLM pods
│ k8s-disc    │  │ k8s-disc    │  Picks best pod
└──────┬──────┘  └──────┬──────┘
       │                │
  ┌────┴────┐      ┌────┴────┐
  ▼         ▼      ▼         ▼
┌────┐   ┌────┐  ┌────┐   ┌────┐
│vLLM│   │vLLM│  │vLLM│   │vLLM│
└────┘   └────┘  └────┘   └────┘
```

## Demo Files

| File | Description |
|------|-------------|
| `load-generator.sh` | Production load through Hub Gateway |
| `continuous-load.sh` | Sustained concurrent load through Hub |
| `fetch-metrics.sh` | One-shot metrics snapshot from all EPPs |
| `live-dashboard.sh` | Real-time terminal dashboard |
| `live-server.py` | Web dashboard with live metrics |

## Quick Start

### 1. Send Requests Through Hub Gateway

```bash
# Single request - see full E2E routing
curl -sk -X POST "https://inference.apps.aigrid-hub.aigriddev.sysdeseng.com/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model": "TinyLlama/TinyLlama-1.1B-Chat-v1.0", "messages": [{"role": "user", "content": "Hello"}], "max_tokens": 50}'
```

### 2. Watch Hub Routing Decisions

```bash
# In a separate terminal - see which Spoke each request goes to
KUBECONFIG=~/Projects/llm-d-inference-scheduler/docs/multi-cluster-setup/hub/auth/kubeconfig \
  oc -n llm-d-system logs -f deploy/envoy | grep POST
```

### 3. Generate Sustained Load

```bash
# Steady load (1 req/sec for 60s)
./load-generator.sh steady 1 60

# Burst mode (10 concurrent every 5s)
./load-generator.sh burst 1 60

# Ramp up (increasing concurrency)
./load-generator.sh ramp 1 60

# Continuous high load (10 concurrent, 3s between batches)
./continuous-load.sh 10 3
```

## Endpoints

| Component | URL |
|-----------|-----|
| **Hub Gateway (E2E Entry)** | https://inference.apps.aigrid-hub.aigriddev.sysdeseng.com |
| Hub EPP Metrics | https://epp-metrics-llm-d-system.apps.aigrid-hub.aigriddev.sysdeseng.com/metrics |
| Spoke1 Gateway | https://inference-gateway-llm-d-system.apps.aigrid-tenant1.aigriddev.sysdeseng.com |
| Spoke2 Gateway | https://inference-gateway-llm-d-system.apps.aigrid-tenant2.aigriddev.sysdeseng.com |

## What This Proves

1. **Full E2E Routing**: Requests flow Hub Envoy -> Hub EPP -> Spoke Envoy -> Spoke EPP -> vLLM
2. **Two-Level Scheduling**: Hub picks cluster, Spoke picks pod within cluster
3. **Cross-Cluster Metrics**: Hub scrapes aggregated metrics from Spoke EPPs via HTTPS
4. **Load-Based Routing**: Requests distributed based on real-time cluster load
5. **Engine Type Auto-Detection**: Hub uses `spoke-epp` engine type for cluster endpoints
6. **Header-Based Routing**: Hub Envoy routes to Spoke based on EPP's `x-gateway-destination-endpoint` header

## Demo Scenario

```bash
# Terminal 1: Watch Hub routing
KUBECONFIG=.../hub/auth/kubeconfig oc -n llm-d-system logs -f deploy/envoy | grep POST

# Terminal 2: Generate load
./continuous-load.sh 10 3
```

Watch Terminal 1 to see routing decisions:
```
POST /v1/chat/completions -> inference-gateway-llm-d-system.apps.aigrid-tenant1... 200 450ms
POST /v1/chat/completions -> inference-gateway-llm-d-system.apps.aigrid-tenant2... 200 380ms
POST /v1/chat/completions -> inference-gateway-llm-d-system.apps.aigrid-tenant1... 200 520ms
```

Requests are distributed between Spokes based on their current load metrics.
