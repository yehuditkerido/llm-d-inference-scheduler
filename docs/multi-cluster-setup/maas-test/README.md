# MaaS Multi-Cluster Testing Resources

This directory contains MaaS (Models-as-a-Service) resources for testing multi-cluster inference through the Hub-and-Spoke architecture.

**Status: Working E2E**

## Architecture

```
Tenant Cluster (MaaS)  →  Hub (MC Gateway)  →  Spokes (vLLM)
   User + API Key           EPP Routing          Inference
   Authorino + Limitador    Let's Encrypt TLS    TinyLlama
```

## Prerequisites

1. MaaS deployed on tenant cluster (`aigrid-consumer`)
2. Hub Gateway with Let's Encrypt certificate (`aigrid-hub`)
3. Spoke clusters with vLLM running (`aigrid-tenant1`, `aigrid-tenant2`)

## Resources

| File | Resource Type | Description |
|------|---------------|-------------|
| `external-model.yaml` | ExternalModel | Points to Hub Gateway (maas-hub.apps...) |
| `maas-model-ref.yaml` | MaaSModelRef | Registers model in MaaS |
| `maas-auth-policy.yaml` | MaaSAuthPolicy | Access permissions |
| `maas-subscription.yaml` | MaaSSubscription | Rate limiting (10k tokens/min) |

## TLS Solution

The Hub Gateway uses a Let's Encrypt certificate to enable cross-cluster TLS.
See `../hub-tls/` for the certificate configuration.

## Deployment

```bash
# Set kubeconfig to tenant cluster
export KUBECONFIG=~/Projects/llm-d-inference-scheduler/docs/multi-cluster-setup/tenant-consumer/auth/kubeconfig

# Create credentials secret (one-time)
oc create secret generic hub-gateway-credentials \
    -n models-as-a-service \
    --from-literal=api-key=dummy-key-for-testing

# Apply all resources
oc apply -k .
```

## Testing

Use the test script for easy testing:

```bash
# Check status
./test-maas-flow.sh status

# Login and get token
./test-maas-flow.sh login

# Create API key
export OC_TOKEN='<token-from-login>'
./test-maas-flow.sh api-key

# Test inference
export API_KEY='<key-from-api-key>'
./test-maas-flow.sh test
```

## Endpoints

| Component | URL | Notes |
|-----------|-----|-------|
| MaaS Gateway | `https://maas.apps.aigrid-consumer.aigriddev.sysdeseng.com` | User entry point |
| Hub Gateway (MaaS) | `https://maas-hub.apps.aigrid-hub.aigriddev.sysdeseng.com` | Let's Encrypt cert |
| Hub Gateway (Demo) | `https://inference.apps.aigrid-hub.aigriddev.sysdeseng.com` | Self-signed, demo only |

## Inference Request

Use the `X-Gateway-Model-Name` header for routing:

```bash
curl -sk -X POST \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -H "X-Gateway-Model-Name: TinyLlama/TinyLlama-1.1B-Chat-v1.0" \
    -d '{
        "model": "TinyLlama/TinyLlama-1.1B-Chat-v1.0",
        "messages": [{"role": "user", "content": "Hello!"}],
        "max_tokens": 50
    }' \
    "https://maas.apps.aigrid-consumer.aigriddev.sysdeseng.com/v1/chat/completions"
```

## Troubleshooting

```bash
# Check MaaS API logs
oc logs -n redhat-ods-applications -l app.kubernetes.io/name=maas-api --tail=100

# Check MaaSModelRef status
oc describe maasmodelref hub-tinyllama -n models-as-a-service

# Check if Hub Gateway is reachable (Let's Encrypt)
curl -sk https://maas-hub.apps.aigrid-hub.aigriddev.sysdeseng.com/health

# Verify certificate
openssl s_client -connect maas-hub.apps.aigrid-hub.aigriddev.sysdeseng.com:443 \
    -servername maas-hub.apps.aigrid-hub.aigriddev.sysdeseng.com 2>/dev/null | \
    openssl x509 -noout -issuer
# Should show: issuer=C=US, O=Let's Encrypt, CN=...
```
