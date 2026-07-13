#!/bin/bash

set -euo pipefail

TENANT_KUBECONFIG="${TENANT_KUBECONFIG:-$HOME/Projects/llm-d-inference-scheduler/docs/multi-cluster-setup/tenant-consumer/auth/kubeconfig}"
TENANT_PASSWORD_FILE="$HOME/Projects/llm-d-inference-scheduler/docs/multi-cluster-setup/tenant-consumer/auth/kubeadmin-password"
MAAS_URL="https://maas.apps.aigrid-consumer.aigriddev.sysdeseng.com"
MAAS_API_URL="$MAAS_URL/maas-api"
MODEL_ENDPOINT="$MAAS_URL/v1/chat/completions"
MODEL_NAME="TinyLlama/TinyLlama-1.1B-Chat-v1.0"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
echo_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
echo_error() { echo -e "${RED}[ERROR]${NC} $1"; }

show_usage() {
    cat <<EOF
Usage: $0 <command>

Commands:
    status      Check MaaS resources status
    login       Login to tenant cluster and get token
    api-key     Create a new API key (requires login first)
    test        Test inference with API key
    full-test   Run complete test flow

Environment Variables:
    API_KEY     Your MaaS API key (required for 'test' command)

EOF
}

check_status() {
    echo_info "Checking MaaS resources on tenant cluster..."
    export KUBECONFIG="$TENANT_KUBECONFIG"
    
    echo ""
    echo "=== ExternalModel ==="
    oc get externalmodel -n models-as-a-service 2>/dev/null || echo "Not found"
    
    echo ""
    echo "=== MaaSModelRef ==="
    oc get maasmodelref -n models-as-a-service 2>/dev/null || echo "Not found"
    
    echo ""
    echo "=== MaaSAuthPolicy ==="
    oc get maasauthpolicy -n models-as-a-service 2>/dev/null || echo "Not found"
    
    echo ""
    echo "=== MaaSSubscription ==="
    oc get maassubscription -n models-as-a-service 2>/dev/null || echo "Not found"
}

do_login() {
    echo_info "Logging in to tenant cluster..."
    export KUBECONFIG="$TENANT_KUBECONFIG"
    
    if [[ ! -f "$TENANT_PASSWORD_FILE" ]]; then
        echo_error "Password file not found: $TENANT_PASSWORD_FILE"
        exit 1
    fi
    
    PASS=$(cat "$TENANT_PASSWORD_FILE")
    oc login -u kubeadmin -p "$PASS" https://api.aigrid-consumer.aigriddev.sysdeseng.com:6443 --insecure-skip-tls-verify
    
    echo ""
    echo_info "Getting token..."
    TOKEN=$(oc whoami -t)
    echo "Token: $TOKEN"
    echo ""
    echo "Export this token for API key creation:"
    echo "  export OC_TOKEN='$TOKEN'"
}

create_api_key() {
    if [[ -z "${OC_TOKEN:-}" ]]; then
        echo_error "OC_TOKEN not set. Run 'login' first and export the token."
        exit 1
    fi
    
    echo_info "Creating API key..."
    echo "URL: $MAAS_API_URL/v1/api-keys"
    echo "Token (first 20 chars): ${OC_TOKEN:0:20}..."
    echo ""
    
    RESPONSE=$(curl -sk -w "\n---HTTP_CODE:%{http_code}---" -X POST \
        -H "Authorization: Bearer $OC_TOKEN" \
        -H "Content-Type: application/json" \
        -d '{"name": "multicluster-test-key", "subscription": "multicluster-subscription"}' \
        "$MAAS_API_URL/v1/api-keys" 2>&1)
    
    HTTP_CODE=$(echo "$RESPONSE" | grep -o 'HTTP_CODE:[0-9]*' | cut -d: -f2)
    BODY=$(echo "$RESPONSE" | sed 's/---HTTP_CODE:[0-9]*---//')
    
    echo "HTTP Status: $HTTP_CODE"
    echo "Response:"
    echo "$BODY" | jq . 2>/dev/null || echo "$BODY"
    
    if [[ "$HTTP_CODE" == "201" || "$HTTP_CODE" == "200" ]]; then
        API_KEY=$(echo "$BODY" | jq -r '.key // empty')
        if [[ -n "$API_KEY" && "$API_KEY" != "null" ]]; then
            echo ""
            echo_info "API Key created successfully!"
            echo "Export this key for testing:"
            echo "  export API_KEY='$API_KEY'"
        fi
    else
        echo_error "Failed to create API key (HTTP $HTTP_CODE)"
    fi
}

test_inference() {
    if [[ -z "${API_KEY:-}" ]]; then
        echo_error "API_KEY not set. Create an API key first."
        exit 1
    fi
    
    echo_info "Testing inference through MaaS..."
    echo "Endpoint: $MODEL_ENDPOINT"
    echo "Model: $MODEL_NAME"
    echo ""
    
    RESPONSE=$(curl -sk -w "\n---HTTP_CODE:%{http_code}---" -X POST \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json" \
        -H "X-Gateway-Model-Name: $MODEL_NAME" \
        -d "{
            \"model\": \"$MODEL_NAME\",
            \"messages\": [{\"role\": \"user\", \"content\": \"Hello!\"}],
            \"max_tokens\": 50
        }" \
        "$MODEL_ENDPOINT" 2>&1)
    
    HTTP_CODE=$(echo "$RESPONSE" | grep -o 'HTTP_CODE:[0-9]*' | cut -d: -f2)
    BODY=$(echo "$RESPONSE" | sed 's/---HTTP_CODE:[0-9]*---//')
    
    echo "HTTP Status: $HTTP_CODE"
    echo "Response:"
    echo "$BODY" | jq . 2>/dev/null || echo "$BODY"
    
    if [[ "$HTTP_CODE" == "200" ]]; then
        echo_info "Inference successful!"
    elif [[ "$HTTP_CODE" == "401" ]]; then
        echo_error "Auth failed (401). Check API key."
    elif [[ "$HTTP_CODE" == "403" ]]; then
        echo_error "Forbidden (403). Check auth policies."
    elif [[ "$HTTP_CODE" == "429" ]]; then
        echo_warn "Rate limited (429). Quota exceeded."
    else
        echo_warn "Unexpected status: $HTTP_CODE"
    fi
}

case "${1:-help}" in
    status)
        check_status
        ;;
    login)
        do_login
        ;;
    api-key)
        create_api_key
        ;;
    test)
        test_inference
        ;;
    full-test)
        check_status
        echo ""
        do_login
        echo ""
        create_api_key
        echo ""
        test_inference
        ;;
    help|--help|-h)
        show_usage
        ;;
    *)
        echo_error "Unknown command: $1"
        show_usage
        exit 1
        ;;
esac
