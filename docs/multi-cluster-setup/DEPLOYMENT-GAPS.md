# Multi-Cluster E2E Testing: Deployment Gaps & Next Steps

This document identifies what's missing to test the **Hub-and-Spoke multi-cluster routing** with the new `spoke-epp` engine type and `file-discovery` extension.

## Current State (July 8, 2026)

| Cluster | Nodes | GPUs | vLLM Status | EPP Status | Gateway/Route |
|---------|-------|------|-------------|------------|---------------|
| **Hub** | 3 CP (schedulable) | 0 | N/A | **NOT DEPLOYED** | **NOT DEPLOYED** |
| **Spoke1** | 3 CP + 2 workers | 2x T4 | **2 pods running** | **NOT DEPLOYED** | **NOT DEPLOYED** |
| **Spoke2** | 3 CP + 2 workers | 2x T4 | **2 pods running** | **NOT DEPLOYED** | **NOT DEPLOYED** |

**What's working:**
- All 3 clusters are up and accessible
- GPU drivers installed on Spoke clusters
- vLLM (TinyLlama) running on both Spokes with 2 replicas each

---

## Gaps Overview

| # | Gap | Priority | Effort | Owner |
|---|-----|----------|--------|-------|
| 1 | Deploy Spoke EPP on Spoke1 & Spoke2 | **HIGH** | Medium | You |
| 2 | Expose Spoke EPPs via OpenShift Routes | **HIGH** | Low | You |
| 3 | Deploy Hub EPP with file-discovery config | **HIGH** | Medium | You + Colleague |
| 4 | Cross-cluster authentication (mTLS or token) | **HIGH** | High | Platform/You |
| 5 | Expose Hub Gateway for external traffic | **MEDIUM** | Low | You |
| 6 | Envoy ext_proc integration (optional for full routing) | LOW | High | Later |

---

## Gap 1: Deploy Spoke EPP on Spoke Clusters

### What's Needed
Each Spoke cluster needs an EPP that:
1. Discovers local vLLM pods (via Kubernetes API)
2. Scrapes metrics from vLLM pods
3. Exposes pool-average metrics for Hub to scrape (`llm_d_epp_average_*`)
4. Has `/metrics` endpoint accessible from Hub

### Agent Prompt: Deploy Spoke EPP

```
Deploy llm-d-router (EPP) to the Spoke1 cluster with the following configuration:

Cluster access:
- KUBECONFIG: ~/Projects/llm-d-inference-scheduler/docs/multi-cluster-setup/spoke-tenant1/auth/kubeconfig

Requirements:
1. Create namespace "llm-d-system" for EPP deployment
2. Build and push EPP image from current repo (or use existing image if available)
3. Deploy EPP as a Deployment with:
   - 1 replica
   - ServiceAccount with RBAC to watch pods in "llm-inference" namespace
   - ConfigMap with EPP config (see below)
   - Service exposing port 9002 (metrics) and 9001 (grpc)
4. Configure EPP to discover vLLM pods with label "app=vllm-tinyllama" in namespace "llm-inference"

EPP Config (ConfigMap):
- Use "vllm" as default engine type
- Enable metrics exposure for pool averages
- Do NOT enable file-discovery (Spokes use Kubernetes discovery)

After deployment, verify:
- EPP pod is running
- EPP can see the 2 vLLM pods
- curl http://<epp-service>:9002/metrics shows llm_d_epp_average_* metrics

Repeat for Spoke2 cluster using:
- KUBECONFIG: ~/Projects/llm-d-inference-scheduler/docs/multi-cluster-setup/spoke-tenant2/auth/kubeconfig
```

---

## Gap 2: Expose Spoke EPPs via OpenShift Routes

### What's Needed
Hub EPP needs to reach Spoke EPPs over the network. On OpenShift, use Routes.

### Agent Prompt: Create Routes for Spoke EPPs

```
Create OpenShift Routes to expose the Spoke EPP metrics endpoints externally.

For Spoke1:
- KUBECONFIG: ~/Projects/llm-d-inference-scheduler/docs/multi-cluster-setup/spoke-tenant1/auth/kubeconfig
- Create a Route in namespace "llm-d-system"
- Route name: "spoke-epp-metrics"
- Target service: epp service on port 9002
- Host: epp-metrics.apps.aigrid-tenant1.aigriddev.sysdeseng.com
- TLS: edge termination (uses cluster's wildcard cert)

For Spoke2:
- KUBECONFIG: ~/Projects/llm-d-inference-scheduler/docs/multi-cluster-setup/spoke-tenant2/auth/kubeconfig
- Route name: "spoke-epp-metrics"
- Host: epp-metrics.apps.aigrid-tenant2.aigriddev.sysdeseng.com
- TLS: edge termination

After creating routes, verify:
- curl -k https://epp-metrics.apps.aigrid-tenant1.aigriddev.sysdeseng.com/metrics
- Should return Prometheus metrics including llm_d_epp_average_*
```

---

## Gap 3: Deploy Hub EPP with file-discovery

### What's Needed
Hub EPP uses `file-discovery` plugin (your colleague's work) to:
1. Read cluster endpoints from a ConfigMap (not Kubernetes pods)
2. Scrape metrics from Spoke EPP routes
3. Use `spoke-epp` engine type (auto-detected by `PodName=""`)

### Prerequisites
- Colleague's PR for file-discovery must be merged or cherry-picked
- Spoke EPP routes must be accessible from Hub

### Agent Prompt: Deploy Hub EPP

```
Deploy llm-d-router (EPP) to the Hub cluster with file-discovery configuration.

Cluster access:
- KUBECONFIG: ~/Projects/llm-d-inference-scheduler/docs/multi-cluster-setup/hub/auth/kubeconfig

Requirements:
1. Ensure the file-discovery plugin code is available (cherry-pick from colleague's branch if needed)
2. Create namespace "llm-d-system"
3. Create ConfigMap "cluster-endpoints" with endpoints.yaml:

```yaml
endpoints:
  - name: spoke-tenant1
    address: epp-metrics.apps.aigrid-tenant1.aigriddev.sysdeseng.com
    port: "443"
    labels:
      region: us-east-2
      cluster: spoke-tenant1

  - name: spoke-tenant2
    address: epp-metrics.apps.aigrid-tenant2.aigriddev.sysdeseng.com
    port: "443"
    labels:
      region: us-west-2
      cluster: spoke-tenant2
```

4. Deploy EPP with:
   - ConfigMap mounted at /etc/epp/endpoints.yaml
   - EPP config using file-discovery plugin pointing to that file
   - RBAC (minimal - no pod watching needed)

5. EPP Config should include:
   - file-discovery plugin with path "/etc/epp/endpoints.yaml"
   - core-metrics-extractor (will auto-detect spoke-epp for cluster endpoints)
   - queue-scorer or kv-cache-utilization-scorer for ranking clusters

Verify:
- Hub EPP can reach both Spoke EPP routes
- Hub EPP logs show it discovered 2 cluster endpoints
- Hub EPP metrics show aggregated values from both Spokes
```

---

## Gap 4: Cross-Cluster Authentication (mTLS)

### Reference: hexfusion POC
Based on [hexfusion/experiments POC](https://github.com/hexfusion/experiments/tree/main/llm-d/spoke-and-hub/poc), the approach is **mTLS for metrics scraping**.

### Architecture (from POC)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Hub Cluster                                     │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │  Hub EPP (cluster-epp)                                                │   │
│  │  - file-discovery reads endpoints.yaml                               │   │
│  │  - metrics-data-source with mTLS client cert                         │   │
│  │  - Mounts: /etc/epp-tls/tls.crt, tls.key (client cert)              │   │
│  │  - Mounts: /etc/epp/spoke-ca.pem (spoke server CAs)                 │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                              │                                               │
│                   mTLS (client cert)                                        │
│                              │                                               │
└──────────────────────────────┼───────────────────────────────────────────────┘
                               │
          ┌────────────────────┴────────────────────┐
          │                                         │
          ▼                                         ▼
┌─────────────────────────────────┐   ┌─────────────────────────────────┐
│      Spoke1 Cluster             │   │      Spoke2 Cluster             │
│  ┌─────────────────────────┐    │   │  ┌─────────────────────────┐    │
│  │  Spoke EPP              │    │   │  │  Spoke EPP              │    │
│  │  + metrics-server mTLS  │    │   │  │  + metrics-server mTLS  │    │
│  │  - Server cert (SAN=LB) │    │   │  │  - Server cert (SAN=LB) │    │
│  │  - Hub CA for client    │    │   │  │  - Hub CA for client    │    │
│  └───────────┬─────────────┘    │   │  └───────────┬─────────────┘    │
│              │                  │   │              │                  │
│  ┌───────────▼─────────────┐    │   │  ┌───────────▼─────────────┐    │
│  │  LoadBalancer :9090     │    │   │  │  LoadBalancer :9090     │    │
│  │  (metrics endpoint)     │    │   │  │  (metrics endpoint)     │    │
│  └─────────────────────────┘    │   │  └─────────────────────────┘    │
└─────────────────────────────────┘   └─────────────────────────────────┘
```

### Key Components

| Component | Location | Secret Name | Contents |
|-----------|----------|-------------|----------|
| **Hub client cert** | Hub | `cluster-epp-metrics-client` | `tls.crt`, `tls.key` |
| **Spoke server CAs** | Hub | ConfigMap `cluster-epp-config` | `spoke-ca.pem` (concatenated) |
| **Spoke server cert** | Each Spoke | `aig-epp-server-cert` | `tls.crt`, `tls.key` (SAN=LB FQDN) |
| **Hub client CA** | Each Spoke | `aig-hub-ca` | `ca.crt` |

### Required PRs Status

| PR | Description | Status | Notes |
|----|-------------|--------|-------|
| [#1857](https://github.com/llm-d/llm-d-router/pull/1857) | `metricsAddress` field | **CLOSED** | Superseded by #1903 |
| [#1858](https://github.com/llm-d/llm-d-router/pull/1858) | mTLS client for scraping | **OPEN** | Still needed for mTLS |
| [#1903](https://github.com/llm-d/llm-d-router/issues/1903) | hostname in file-discovery | **OPEN** | Liav's work (your colleague!) |
| [#1913](https://github.com/llm-d/llm-d-router/issues/1913) | spoke-epp engine type | **YOUR PR** | Auto-detect cluster endpoints |

**Key difference from hexfusion POC:**
- POC has **separate** `address` (traffic) and `metricsAddress` (scrape)
- Liav's #1903 uses **same** address for both (`MetricsHost = Address:Port`)
- This is simpler but requires spoke gateway to serve both inference AND metrics on same endpoint

### Hub EPP Config (from POC)

```yaml
plugins:
- type: file-discovery
  parameters: { path: /etc/epp/endpoints.yaml, watchFile: true }
- type: metrics-data-source
  parameters:
    scheme: https
    insecureSkipVerify: false
    caCertPath: /etc/epp/spoke-ca.pem
    clientCertPath: /etc/epp-tls/tls.crt
    clientKeyPath: /etc/epp-tls/tls.key
- type: core-metrics-extractor
  parameters:
    defaultEngine: cluster
    engineConfigs:
    - name: cluster
      queuedRequestsSpec: "inference_pool_average_queue_size"
      kvUsageSpec: "inference_pool_average_kv_cache_utilization"
```

### endpoints.yaml (from POC)

```yaml
endpoints:
  - name: spoke1
    address: "3.143.47.169"           # Inference traffic target
    port: "443"
    metricsAddress: "a3e003...elb.amazonaws.com"  # mTLS metrics scrape
    metricsPort: "9090"
    labels:
      cluster: spoke1
      region: us-east-2
```

**Note:** The POC uses **separate `address` and `metricsAddress`**:
- `address` = inference traffic destination (maas IP)
- `metricsAddress` = metrics scraping endpoint (LoadBalancer FQDN)

### Agent Prompt: Set Up mTLS Certificates

```
Set up mTLS certificates for Hub-to-Spoke metrics scraping.

**Step 1: Generate CA and Certificates (on your workstation)**

# Create directories
mkdir -p ~/certs/{hub,spoke1,spoke2}
cd ~/certs

# Generate Hub CA (signs Hub client cert)
openssl genrsa -out hub/ca.key 4096
openssl req -x509 -new -nodes -key hub/ca.key -sha256 -days 365 \
  -out hub/ca.crt -subj "/CN=hub-metrics-client-ca"

# Generate Hub client cert (used to authenticate to Spokes)
openssl genrsa -out hub/client.key 2048
openssl req -new -key hub/client.key -out hub/client.csr \
  -subj "/CN=hub-metrics-client"
openssl x509 -req -in hub/client.csr -CA hub/ca.crt -CAkey hub/ca.key \
  -CAcreateserial -out hub/client.crt -days 365 -sha256

# Generate Spoke1 server cert (SAN must match LoadBalancer FQDN)
# First, get the LB FQDN after creating the LoadBalancer service
SPOKE1_LB_FQDN="epp-metrics-lb.apps.aigrid-tenant1.aigriddev.sysdeseng.com"
openssl genrsa -out spoke1/server.key 2048
cat > spoke1/server.ext << EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:${SPOKE1_LB_FQDN}
EOF
openssl req -new -key spoke1/server.key -out spoke1/server.csr \
  -subj "/CN=${SPOKE1_LB_FQDN}"
# Self-signed for POC (or use same CA)
openssl x509 -req -in spoke1/server.csr -signkey spoke1/server.key \
  -out spoke1/server.crt -days 365 -sha256 -extfile spoke1/server.ext

# Repeat for Spoke2 with its FQDN

**Step 2: Create Secrets on Spoke Clusters**

# Spoke1
export KUBECONFIG=~/Projects/llm-d-inference-scheduler/docs/multi-cluster-setup/spoke-tenant1/auth/kubeconfig
kubectl create namespace llm-d-system --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret tls aig-epp-server-cert \
  --cert=~/certs/spoke1/server.crt \
  --key=~/certs/spoke1/server.key \
  -n llm-d-system
kubectl create secret generic aig-hub-ca \
  --from-file=ca.crt=~/certs/hub/ca.crt \
  -n llm-d-system

# Repeat for Spoke2

**Step 3: Create Secrets on Hub Cluster**

export KUBECONFIG=~/Projects/llm-d-inference-scheduler/docs/multi-cluster-setup/hub/auth/kubeconfig
kubectl create namespace llm-d-system --dry-run=client -o yaml | kubectl apply -f -

# Hub client cert
kubectl create secret tls cluster-epp-metrics-client \
  --cert=~/certs/hub/client.crt \
  --key=~/certs/hub/client.key \
  -n llm-d-system

# Concatenate spoke server CAs (or use self-signed, so use spoke certs as CA)
cat ~/certs/spoke1/server.crt ~/certs/spoke2/server.crt > ~/certs/spoke-ca.pem
kubectl create configmap cluster-epp-ca \
  --from-file=spoke-ca.pem=~/certs/spoke-ca.pem \
  -n llm-d-system
```

### Difference: LoadBalancer vs Route

The POC uses **AWS LoadBalancer** (type: LoadBalancer) because:
- Direct TCP/TLS passthrough (no OpenShift router in the path)
- mTLS works end-to-end without Route termination issues

**For OpenShift**, options:
1. **LoadBalancer Service** (like POC) - works if cloud provider supports it
2. **Route with passthrough TLS** - OpenShift router passes TLS through without terminating
3. **NodePort + external LB** - more manual setup

**Recommendation:** Use LoadBalancer if on AWS/cloud, or passthrough Route on OpenShift.

---

## Gap 5: Expose Hub Gateway

### What's Needed
External clients send requests to Hub Gateway, which routes to Spokes.

### Agent Prompt: Create Hub Gateway Route

```
Create OpenShift Route for Hub inference gateway.

Cluster: Hub
- KUBECONFIG: ~/Projects/llm-d-inference-scheduler/docs/multi-cluster-setup/hub/auth/kubeconfig

Requirements:
1. Deploy Gateway API resources (Gateway, HTTPRoute) in llm-d-system namespace
2. Create Route for external access:
   - Host: inference.apps.aigrid-hub.aigriddev.sysdeseng.com
   - Target: Gateway service
   - TLS: edge termination

After setup, inference requests to:
  https://inference.apps.aigrid-hub.aigriddev.sysdeseng.com/v1/chat/completions

Should be routed by Hub EPP to one of the Spokes.
```

---

## Gap 6: Envoy ext_proc Integration (Optional)

### What's Needed
Full routing requires Envoy with ext_proc filter calling EPP.

### For POC
Skip this - test EPP scoring/selection logic directly:
1. Call Hub EPP's internal API to get selected endpoint
2. Manually curl that endpoint

### For Full Demo
Deploy Envoy as Gateway with ext_proc pointing to Hub EPP.

---

## Demo Options

### Option 1: CLI Demo (Simplest)

```bash
# Show Hub EPP seeing both Spokes
curl -s http://hub-epp:9002/metrics | grep llm_d_epp

# Show different queue sizes on Spokes
curl -s https://epp-metrics.apps.aigrid-tenant1.aigriddev.sysdeseng.com/metrics | grep average_queue
curl -s https://epp-metrics.apps.aigrid-tenant2.aigriddev.sysdeseng.com/metrics | grep average_queue

# Send requests and show routing decision
for i in {1..10}; do
  curl -s http://hub-gateway/v1/chat/completions -d '...' | jq .
done
```

### Option 2: Grafana Dashboard

Deploy Prometheus + Grafana on Hub:
1. Scrape all 3 EPPs
2. Create dashboard showing:
   - Queue sizes per cluster (bar chart)
   - KV cache utilization per cluster (gauge)
   - Requests routed to each cluster (pie chart)
   - Latency by cluster (line graph)

**Agent Prompt:**
```
Deploy Prometheus and Grafana on Hub cluster for multi-cluster monitoring.

Requirements:
1. Install Prometheus Operator (or use OpenShift built-in monitoring)
2. Create ServiceMonitors for:
   - Hub EPP (local)
   - Spoke1 EPP (via federation or remote-write)
   - Spoke2 EPP (via federation or remote-write)
3. Deploy Grafana with datasource pointing to Prometheus
4. Import/create dashboard with panels for:
   - llm_d_epp_average_queue_size (per cluster)
   - llm_d_epp_average_kv_cache_utilization (per cluster)
   - Request routing distribution
5. Expose Grafana via Route
```

### Option 3: Open WebUI (Best Visual Demo)

Deploy Open WebUI as chat interface:
1. Point it at Hub Gateway
2. Send chat messages
3. Show requests being routed to different clusters
4. Add cluster info in response headers for visibility

**Agent Prompt:**
```
Deploy Open WebUI as a chat interface for the multi-cluster demo.

Requirements:
1. Deploy Open WebUI on Hub cluster:
   - Image: ghcr.io/open-webui/open-webui:main
   - Configure OPENAI_API_BASE_URL to point to Hub Gateway
   - Model: TinyLlama/TinyLlama-1.1B-Chat-v1.0

2. Create Route:
   - Host: chat.apps.aigrid-hub.aigriddev.sysdeseng.com

3. For demo visibility, modify Hub EPP to add response header:
   - X-Routed-To-Cluster: spoke-tenant1 (or spoke-tenant2)

4. Open WebUI settings to show headers (or use browser dev tools)

Demo flow:
- Open https://chat.apps.aigrid-hub.aigriddev.sysdeseng.com
- Send chat messages
- Watch network tab to see X-Routed-To-Cluster header
- Generate load on one Spoke, watch routing shift to other
```

---

## Recommended Deployment Order

1. **Spoke EPPs first** (can test independently)
2. **Spoke Routes** (verify external access)
3. **Hub EPP with file-discovery** (depends on colleague's PR)
4. **Hub Gateway Route** (for external access)
5. **Demo UI** (Grafana or Open WebUI)

---

## Quick Verification Commands

```bash
# Set up aliases
alias hub='export KUBECONFIG=~/Projects/llm-d-inference-scheduler/docs/multi-cluster-setup/hub/auth/kubeconfig'
alias spoke1='export KUBECONFIG=~/Projects/llm-d-inference-scheduler/docs/multi-cluster-setup/spoke-tenant1/auth/kubeconfig'
alias spoke2='export KUBECONFIG=~/Projects/llm-d-inference-scheduler/docs/multi-cluster-setup/spoke-tenant2/auth/kubeconfig'

# Check vLLM pods
spoke1 && kubectl get pods -n llm-inference
spoke2 && kubectl get pods -n llm-inference

# Check EPP (after deployment)
spoke1 && kubectl get pods -n llm-d-system
hub && kubectl get pods -n llm-d-system

# Check routes (after creation)
spoke1 && kubectl get routes -n llm-d-system
hub && kubectl get routes -n llm-d-system

# Test metrics (after routes)
curl -k https://epp-metrics.apps.aigrid-tenant1.aigriddev.sysdeseng.com/metrics | grep llm_d_epp_average
curl -k https://epp-metrics.apps.aigrid-tenant2.aigriddev.sysdeseng.com/metrics | grep llm_d_epp_average
```

---

## Questions to Resolve

### Verified Information

- **Issue #1903** (Liav's work) = your colleague's file-discovery extension
- **PR #1857** was CLOSED in favor of #1903 (no separate `metricsAddress` field)
- **PR #1858** (mTLS client) is still OPEN and needed

### Critical Questions

1. **PR #1858 (mTLS client)**: When will this be merged?
   - Without it, Hub EPP can't authenticate to Spokes via mTLS
   - Can we test without mTLS first (insecure) and add mTLS later?

2. **Metrics-server mTLS**: Is there a PR for Spoke EPP to **serve** metrics over mTLS?
   - hexfusion POC uses `--metrics-cert-dir` and `--metrics-client-ca-file` flags
   - Without this, Spokes can't verify Hub's client cert (one-way TLS only)
   - OR does OpenShift Route TLS termination handle the server side?

3. **Same address for traffic AND metrics** (from #1903):
   - Liav's approach: `MetricsHost = Address:Port` (same endpoint)
   - This means Spoke Gateway must serve both inference requests AND `/metrics`
   - Is this the intended architecture? Or do we need separate endpoints?

4. **Metric names**: hexfusion POC uses old names (`inference_pool_average_*`)
   - Your PR #1913 uses new names (`llm_d_epp_average_*`)
   - Which should we target? Are Spokes exposing new or old names?

### Important Questions

5. **Liav's PR status**: Is #1903 ready to merge? Can we use it now?

6. **Image to use**: 
   - hexfusion's `quay.io/sbatsche/llm-d-router-endpoint-picker:mtls-fqdn-v5`
   - Or build from main + cherry-pick #1903 + #1858?

7. **Testing without mTLS first**:
   - Can we deploy and test with `insecureSkipVerify: true`?
   - Add mTLS once PR #1858 is merged?

### Architecture Clarification

8. **Spoke Gateway setup**:
   - Does the Spoke need a separate metrics LoadBalancer (like hexfusion POC)?
   - Or can we use the same gateway that serves inference?
   - If same gateway: how does `/metrics` reach EPP (not vLLM)?

9. **IPP plugin**: Do we need token injection per-spoke?
   - hexfusion POC uses `destination-provider-resolver` IPP
   - Is this needed for our setup?

---

## Reference Links

- [hexfusion POC repo](https://github.com/hexfusion/experiments/tree/main/llm-d/spoke-and-hub/poc)
- [PR #1857 - metricsAddress](https://github.com/llm-d/llm-d-router/pull/1857)
- [PR #1858 - mTLS client](https://github.com/llm-d/llm-d-router/pull/1858)
- [IPP plugin branch](https://github.com/opendatahub-io/ai-gateway-payload-processing/compare/main...hexfusion:destination-keyed-credential)

---

*Last updated: July 8, 2026*
