#!/bin/bash
# Deploy GPU Operator and vLLM to a Spoke cluster
# Tested on OpenShift 4.22 with kernel 5.14.0-687.x and Tesla T4 GPUs
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo "=========================================="
echo "  GPU Operator + vLLM Deployment Script"
echo "=========================================="
echo ""

# Check KUBECONFIG
if [[ -z "$KUBECONFIG" ]]; then
    echo -e "${RED}ERROR: KUBECONFIG not set${NC}"
    echo "Run: export KUBECONFIG=<path-to-kubeconfig>"
    exit 1
fi

echo -e "${YELLOW}Using KUBECONFIG: $KUBECONFIG${NC}"
echo "Cluster: $(oc whoami --show-server)"
echo ""

# Step 1: Install NFD Operator
echo -e "${YELLOW}Step 1: Installing Node Feature Discovery Operator...${NC}"
oc apply -f "$SCRIPT_DIR/01-nfd-operator.yaml"
echo "Waiting for NFD operator to be ready..."
sleep 30

# Wait for NFD operator CSV to be ready
echo "Waiting for NFD CSV..."
timeout 300 bash -c 'until oc get csv -n openshift-nfd 2>/dev/null | grep -q Succeeded; do sleep 10; echo "  waiting..."; done' || {
    echo "WARNING: NFD CSV not ready yet, continuing..."
}

# Step 2: Create NFD Instance
echo -e "${YELLOW}Step 2: Creating NFD Instance...${NC}"
oc apply -f "$SCRIPT_DIR/02-nfd-instance.yaml"
sleep 10

# Step 3: Install GPU Operator
echo -e "${YELLOW}Step 3: Installing NVIDIA GPU Operator...${NC}"
oc apply -f "$SCRIPT_DIR/03-gpu-operator.yaml"
echo "Waiting for GPU operator to be ready (this may take a few minutes)..."
sleep 60

# Wait for GPU operator CSV
echo "Waiting for GPU Operator CSV..."
timeout 600 bash -c 'until oc get csv -n nvidia-gpu-operator 2>/dev/null | grep -q Succeeded; do sleep 15; echo "  waiting..."; done' || {
    echo "WARNING: GPU Operator CSV not ready yet, continuing..."
}

# Step 4: Create ClusterPolicy (driver 570.211.01 for kernel 5.14.0-687.x)
echo -e "${YELLOW}Step 4: Creating GPU ClusterPolicy (driver 570.211.01)...${NC}"
oc apply -f "$SCRIPT_DIR/04-gpu-clusterpolicy.yaml"
echo "Waiting for GPU drivers to compile and install (5-10 minutes)..."

# Wait for driver pods to be ready
timeout 900 bash -c '
until oc get pods -n nvidia-gpu-operator -l app=nvidia-driver-daemonset 2>/dev/null | grep -q "2/2.*Running"; do
    sleep 30
    echo "  waiting for driver pods... ($(oc get pods -n nvidia-gpu-operator -l app=nvidia-driver-daemonset 2>/dev/null | tail -1 | awk "{print \$2, \$3}"))"
done
' || {
    echo "WARNING: Driver pods not fully ready yet. Check: oc get pods -n nvidia-gpu-operator"
}

# Step 5: Wait for GPU nodes to be ready
echo -e "${YELLOW}Step 5: Waiting for GPU resources to be available...${NC}"
timeout 300 bash -c 'until oc get nodes -o jsonpath="{.items[*].status.allocatable}" 2>/dev/null | grep -q "nvidia.com/gpu"; do sleep 30; echo "  waiting for nvidia.com/gpu resource..."; done' || {
    echo "WARNING: GPU resources not showing yet. Check: oc get nodes -o yaml | grep -A5 allocatable"
}

# Show GPU status
echo ""
echo "GPU status on nodes:"
oc get nodes -o custom-columns='NAME:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu'
echo ""

# Step 6: Create vLLM namespace and ServiceAccount
echo -e "${YELLOW}Step 6: Creating vLLM namespace and ServiceAccount...${NC}"
oc apply -f "$SCRIPT_DIR/05-vllm-namespace.yaml"
oc apply -f "$SCRIPT_DIR/05-vllm-serviceaccount.yaml"

# Grant anyuid SCC to the ServiceAccount (required for vLLM/PyTorch on OpenShift)
echo "Granting anyuid SCC to vllm-sa..."
oc adm policy add-scc-to-user anyuid -z vllm-sa -n llm-inference

# Step 7: Deploy vLLM
echo -e "${YELLOW}Step 7: Deploying vLLM v0.6.3 with TinyLlama (float16 for Tesla T4)...${NC}"
oc apply -f "$SCRIPT_DIR/06-vllm-deployment.yaml"

# Wait for vLLM pods
echo "Waiting for vLLM pods to start (image pull ~5 minutes first time)..."
timeout 600 bash -c '
until oc get pods -n llm-inference -l app=vllm-tinyllama 2>/dev/null | grep -q "1/1.*Running"; do
    sleep 30
    echo "  waiting for vLLM pods... ($(oc get pods -n llm-inference -l app=vllm-tinyllama 2>/dev/null | tail -1 | awk "{print \$2, \$3}"))"
done
' || {
    echo "WARNING: vLLM pods not ready yet. Check: oc get pods -n llm-inference"
}

echo ""
echo -e "${GREEN}=========================================="
echo "  Deployment Complete!"
echo "==========================================${NC}"
echo ""
echo "vLLM pods:"
oc get pods -n llm-inference -o wide
echo ""
echo "Test inference:"
echo '  POD=$(oc get pods -n llm-inference -l app=vllm-tinyllama -o jsonpath="{.items[0].metadata.name}")'
echo '  oc exec $POD -n llm-inference -- curl -s http://localhost:8000/v1/chat/completions \'
echo '    -H "Content-Type: application/json" \'
echo '    -d '\''{"model":"TinyLlama/TinyLlama-1.1B-Chat-v1.0","messages":[{"role":"user","content":"Hello!"}],"max_tokens":50}'\'''
echo ""
