# Hub MaaS Setup

MaaS resources for the Hub cluster (aigrid-hub) that enable tenant-level rate limiting.

## Architecture

```
Tenant Cluster                        Hub Cluster
+-----------------+                   +------------------+
| User requests   |                   | Tenant quota:    |
| (sk-oai-* keys) |                   | - consumer: 500  |
+-----------------+                   | (per SA token)   |
        |                             +------------------+
        v                                     |
+-----------------+                           v
| Tenant MaaS     |    SA Token      +------------------+
| (user/team      | ---------------> | Hub MaaS         |
|  rate limits)   |                  | (tenant limits)  |
+-----------------+                  +------------------+
                                              |
                                              v
                                     +------------------+
                                     | Hub EPP          |
                                     | (routes to Spokes|
                                     |  by metrics)     |
                                     +------------------+
```

## Concept: Two-Level Rate Limiting

1. **Hub Level (Tenant Quota)**: Each tenant cluster gets a fixed quota (e.g., 500 tokens/min)
2. **Tenant Level (User/Team Quota)**: Tenant internally splits among users/teams

The Hub doesn't know about internal tenant structure. Each tenant:
- "Buys" a fixed quota from Hub
- Splits it internally as they see fit
- Must ensure user+team limits don't exceed their Hub quota

## Files

| File | Purpose |
|------|---------|
| `tenant-service-accounts.yaml` | SAs for tenant clusters (used to authenticate) |
| `dummy-credentials-secret.yaml` | Dummy secret for ExternalModel (Envoy needs no auth) |
| `external-model.yaml` | Wraps Envoy/EPP endpoint for MaaS rate limiting |
| `maas-model-ref.yaml` | Registers ExternalModel with MaaS |
| `maas-auth-policy.yaml` | Which tenants can access the model |
| `maas-subscription.yaml` | Rate limits per tenant cluster |

## How It Works

### 1. Tenant Identity
Each tenant cluster is identified by a Service Account on Hub:
```yaml
# Tenant SA in tenants namespace
apiVersion: v1
kind: ServiceAccount
metadata:
  name: tenant-consumer-sa
  namespace: tenants
```

### 2. Tenant Subscription
Hub enforces total quota for the tenant:
```yaml
spec:
  modelRefs:
    - name: hub-model
      tokenRateLimits:
        - limit: 500      # Total for entire tenant
          window: 1m
  owner:
    users:
      - "system:serviceaccount:tenants:tenant-consumer-sa"
```

### 3. Tenant ExternalModel
The tenant's ExternalModel uses the SA token to authenticate to Hub:
```yaml
# On Tenant cluster
spec:
  endpoint: maas.apps.aigrid-hub.aigriddev.sysdeseng.com
  credentialRef:
    name: hub-sa-token-secret  # Contains SA token from Hub
```

## Deployment

```bash
# Set kubeconfig to Hub cluster
export KUBECONFIG=~/Projects/llm-d-inference-scheduler/docs/multi-cluster-setup/hub/auth/kubeconfig

# Apply all resources
kubectl apply -k .

# Verify
kubectl get maassubscription,maasauthpolicy,externalmodel -n models-as-a-service
```

## Creating Tenant SA Token

```bash
# Generate token for tenant SA (valid 24h)
oc create token tenant-consumer-sa -n tenants --duration=24h

# Use this token in the tenant's ExternalModel credentialRef secret
```

## Testing Hub Rate Limits

```bash
# Create API key using tenant SA token
TOKEN=$(oc create token tenant-consumer-sa -n tenants --duration=1h)

curl -sk "https://maas.apps.aigrid-hub.aigriddev.sysdeseng.com/maas-api/v1/api-keys" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "hub-test-key"}'
```
