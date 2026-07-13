# Tenant MaaS Setup

MaaS resources for the Tenant cluster (aigrid-consumer) that enable user/team-level authentication and rate limiting.

## Architecture

```
User Request (sk-oai-* API key)
        |
        v
+---------------------------+
| Tenant MaaS Gateway       |  <- Validates API key, enforces user/team rate limits
+---------------------------+
        |
        v
+---------------------------+
| ExternalModel Service     |  <- Routes to Hub cluster
+---------------------------+
        |
        v
    Hub Cluster
```

## Files

| File | Purpose |
|------|---------|
| `service-accounts.yaml` | Test identities (simulate users/teams for POC) |
| `hub-credentials-secret.yaml` | Credentials for ExternalModel (dummy for Hub) |
| `external-model.yaml` | Points to Hub cluster's inference endpoint |
| `maas-model-ref.yaml` | Registers ExternalModel with MaaS |
| `maas-auth-policy.yaml` | Defines who can access the model |
| `maas-subscription.yaml` | Rate limits per user/team |

## How It Works

### 1. ExternalModel
Routes requests to an external endpoint (Hub cluster):
```yaml
spec:
  endpoint: maas-hub.apps.aigrid-hub.aigriddev.sysdeseng.com
  provider: openai
  targetModel: TinyLlama/TinyLlama-1.1B-Chat-v1.0
  credentialRef:
    name: hub-gateway-credentials  # Required by CRD
```

### 2. MaaSAuthPolicy
Grants access to authenticated users:
```yaml
spec:
  modelRefs:
    - name: hub-tinyllama
  subjects:
    groups:
      - name: system:authenticated
```

### 3. MaaSSubscription
Defines rate limits. Each user/team can have their own subscription:
```yaml
spec:
  modelRefs:
    - name: hub-tinyllama
      tokenRateLimits:
        - limit: 50      # tokens
          window: 1m     # per minute
  owner:
    users:
      - "system:serviceaccount:models-as-a-service:user-alice"
  priority: 10  # Higher priority = preferred when user has multiple subscriptions
```

## Rate Limits (POC Testing)

| Subscription | Owner | Limit | Priority |
|--------------|-------|-------|----------|
| `multicluster-subscription` | All authenticated | 10000 tokens/min | 0 |
| `user-alice-subscription` | user-alice SA | 50 tokens/min | 10 |
| `user-bob-subscription` | user-bob SA | 100 tokens/min | 10 |
| `team-alpha-subscription` | team-alpha SA | 200 tokens/min | 15 |

## Deployment

```bash
# Set kubeconfig to Tenant cluster
export KUBECONFIG=~/Projects/llm-d-inference-scheduler/docs/multi-cluster-setup/tenant-consumer/auth/kubeconfig

# Apply all resources
kubectl apply -k .

# Verify
kubectl get maassubscription,maasauthpolicy,externalmodel -n models-as-a-service
```

## Creating API Keys

```bash
# Get token for a Service Account
TOKEN=$(oc create token user-alice -n models-as-a-service --duration=24h)

# Create API key bound to specific subscription
curl -sk "https://maas.apps.aigrid-consumer.aigriddev.sysdeseng.com/maas-api/v1/api-keys" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "alice-key", "subscription": "user-alice-subscription"}'
```

## Testing Rate Limits

```bash
# Use the API key for inference
curl -sk "https://maas.apps.aigrid-consumer.aigriddev.sysdeseng.com/models-as-a-service/hub-multicluster-model/v1/completions" \
  -H "Authorization: Bearer sk-oai-..." \
  -H "Content-Type: application/json" \
  -d '{"model": "TinyLlama/TinyLlama-1.1B-Chat-v1.0", "prompt": "Hello", "max_tokens": 10}'

# When rate limit is exceeded, you'll get HTTP 429
```
