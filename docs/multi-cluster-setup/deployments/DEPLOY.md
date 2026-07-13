# Multi-Cluster EPP Deployment Guide

## Prerequisites

1. Committed code changes (spoke-epp engine type + file-discovery hostname support)
2. Access to all 3 clusters
3. vLLM pods running on Spoke clusters (already done)

## Step 1: Build and Push Image

```bash
cd ~/Projects/llm-d-inference-scheduler

# Build with your registry
make image-build IMAGE_REGISTRY=ghcr.io/yehuditkerido EPP_TAG=multi-cluster-test

# Login to GHCR (if not already)
echo $GITHUB_TOKEN | docker login ghcr.io -u yehuditkerido --password-stdin

# Push
make image-push IMAGE_REGISTRY=ghcr.io/yehuditkerido EPP_TAG=multi-cluster-test
```

## Step 2: Deploy Spoke EPP on Spoke1

```bash
# Set kubeconfig for Spoke1
export KUBECONFIG=~/Projects/llm-d-inference-scheduler/docs/multi-cluster-setup/spoke-tenant1/auth/kubeconfig

# Verify access
oc whoami
oc get nodes

# Deploy EPP
oc apply -f docs/multi-cluster-setup/deployments/spoke-epp.yaml

# Wait for pod to be ready
oc -n llm-d-system wait --for=condition=Ready pod -l app=epp --timeout=120s

# Verify EPP sees vLLM pods
oc -n llm-d-system logs -l app=epp | head -50

# Create route (update hostname first!)
# Edit spoke-routes.yaml: replace CLUSTER_NAME with aigrid-tenant1
sed 's/CLUSTER_NAME/aigrid-tenant1/g' docs/multi-cluster-setup/deployments/spoke-routes.yaml | oc apply -f -

# Verify route
oc -n llm-d-system get route epp-metrics
```

## Step 3: Deploy Spoke EPP on Spoke2

```bash
# Set kubeconfig for Spoke2
export KUBECONFIG=~/Projects/llm-d-inference-scheduler/docs/multi-cluster-setup/spoke-tenant2/auth/kubeconfig

# Deploy EPP
oc apply -f docs/multi-cluster-setup/deployments/spoke-epp.yaml

# Wait for pod
oc -n llm-d-system wait --for=condition=Ready pod -l app=epp --timeout=120s

# Create route
sed 's/CLUSTER_NAME/aigrid-tenant2/g' docs/multi-cluster-setup/deployments/spoke-routes.yaml | oc apply -f -

# Verify route
oc -n llm-d-system get route epp-metrics
```

## Step 4: Test Spoke EPP Metrics

From any machine with internet access:

```bash
# Test Spoke1 metrics endpoint
curl -k https://epp-metrics.apps.aigrid-tenant1.aigriddev.sysdeseng.com/metrics | grep llm_d_epp_average

# Test Spoke2 metrics endpoint  
curl -k https://epp-metrics.apps.aigrid-tenant2.aigriddev.sysdeseng.com/metrics | grep llm_d_epp_average
```

You should see metrics like:
- `llm_d_epp_average_queue_size`
- `llm_d_epp_average_running_requests`
- `llm_d_epp_average_kv_cache_utilization`

## Step 5: Deploy Hub EPP

```bash
# Set kubeconfig for Hub
export KUBECONFIG=~/Projects/llm-d-inference-scheduler/docs/multi-cluster-setup/hub/auth/kubeconfig

# Verify access
oc whoami
oc get nodes

# Deploy Hub EPP with file-discovery
oc apply -f docs/multi-cluster-setup/deployments/hub-epp.yaml

# Wait for pod
oc -n llm-d-system wait --for=condition=Ready pod -l app=epp --timeout=120s

# Check logs - should show discovered clusters
oc -n llm-d-system logs -l app=epp | head -100
```

## Step 6: Verify End-to-End

```bash
# On Hub cluster
export KUBECONFIG=~/Projects/llm-d-inference-scheduler/docs/multi-cluster-setup/hub/auth/kubeconfig

# Check Hub EPP logs for cluster discovery
oc -n llm-d-system logs -l app=epp | grep -E "(spoke-tenant|discovered|endpoint)"

# Check Hub EPP metrics - should include cluster metrics
oc -n llm-d-system port-forward svc/epp 9002:9002 &
curl http://localhost:9002/metrics | grep -E "(spoke_tenant|cluster)"
```

## Troubleshooting

### EPP can't reach Spoke metrics
```bash
# From Hub cluster, test connectivity
oc -n llm-d-system exec -it deploy/epp -- curl -k https://epp-metrics.apps.aigrid-tenant1.aigriddev.sysdeseng.com/metrics
```

### EPP not discovering vLLM pods (Spoke)
```bash
# Check if vLLM pods have correct labels
oc -n llm-inference get pods -l app=vllm-tinyllama

# Check EPP logs for discovery errors
oc -n llm-d-system logs -l app=epp | grep -i error
```

### File-discovery not loading endpoints (Hub)
```bash
# Verify ConfigMap is mounted
oc -n llm-d-system exec -it deploy/epp -- cat /etc/epp/endpoints.yaml

# Check for file-discovery logs
oc -n llm-d-system logs -l app=epp | grep -i file-discovery
```
