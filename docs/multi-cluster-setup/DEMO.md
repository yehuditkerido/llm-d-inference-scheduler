# Two-Level MaaS Multi-Cluster Demo

This document explains the Two-Level MaaS configuration and provides test commands to demonstrate rate limiting at all levels.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         Tenant Cluster (aigrid-consumer)                 │
│                                                                          │
│  User Request                                                            │
│  (sk-oai-alice-key)                                                      │
│       │                                                                  │
│       ▼                                                                  │
│  ┌─────────────────┐      ┌─────────────────┐                           │
│  │ MaaS Gateway    │      │ Rate Limits     │                           │
│  │                 │ ───► │ alice: 50/min   │                           │
│  │ Validates key   │      │ bob: 100/min    │                           │
│  │ Applies limits  │      │ team-alpha: 200 │                           │
│  └────────┬────────┘      └─────────────────┘                           │
│           │                                                              │
│           ▼                                                              │
│  ┌─────────────────┐                                                    │
│  │ ExternalModel   │  Injects Hub API key in Authorization header       │
│  │ HTTPRoute       │  Rewrites path to Hub model path                   │
│  └────────┬────────┘                                                    │
└───────────┼──────────────────────────────────────────────────────────────┘
            │
            │ HTTPS (cross-cluster)
            ▼
┌───────────────────────────────────────────────────────────────────────────┐
│                           Hub Cluster (aigrid-hub)                        │
│                                                                           │
│  ┌─────────────────┐      ┌─────────────────┐                            │
│  │ MaaS Gateway    │      │ Rate Limits     │                            │
│  │                 │ ───► │ tenant: 500/min │                            │
│  │ Validates Hub   │      │                 │                            │
│  │ API key         │      │                 │                            │
│  └────────┬────────┘      └─────────────────┘                            │
│           │                                                               │
│           ▼                                                               │
│  ┌─────────────────┐      ┌─────────────────┐                            │
│  │ Envoy Gateway   │ ───► │ EPP             │                            │
│  │ (internal:8080) │      │ Selects best    │                            │
│  └─────────────────┘      │ Spoke by metrics│                            │
│                           └────────┬────────┘                            │
└────────────────────────────────────┼──────────────────────────────────────┘
                                     │
                    ┌────────────────┴────────────────┐
                    ▼                                 ▼
           ┌──────────────┐                  ┌──────────────┐
           │ Spoke 1      │                  │ Spoke 2      │
           │ vLLM         │                  │ vLLM         │
           │ TinyLlama    │                  │ TinyLlama    │
           └──────────────┘                  └──────────────┘
```

---

## Configuration by Cluster

### Hub Cluster Configuration

#### 1. ExternalModel - Routes to Internal Envoy

**File:** [maas-hub/external-model.yaml](maas-hub/external-model.yaml)

```yaml
spec:
  endpoint: envoy.llm-d-system.svc.cluster.local  # Internal service, not public route
  provider: openai
  targetModel: TinyLlama/TinyLlama-1.1B-Chat-v1.0
  credentialRef:
    name: dummy-credentials  # Envoy doesn't need auth
```

**Why it works:** Uses internal Kubernetes service to avoid TLS hairpin issues. MaaS creates an ExternalName service pointing to this endpoint.

#### 2. ReferenceGrant - Allows Cross-Namespace Backend

**File:** [maas-hub/reference-grant.yaml](maas-hub/reference-grant.yaml)

```yaml
spec:
  from:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    namespace: models-as-a-service
  to:
  - group: ""
    kind: Service
    name: envoy
```

**Why it works:** Gateway API requires explicit permission to reference services in other namespaces. This grants `models-as-a-service` namespace permission to use `envoy` service in `llm-d-system`.

#### 3. HTTPRoute Override - Internal Routing

**File:** [maas-hub/httproute-override.yaml](maas-hub/httproute-override.yaml)

```yaml
spec:
  rules:
  - backendRefs:
    - name: envoy
      namespace: llm-d-system
      port: 8080  # Internal HTTP port, not 443
    filters:
    - type: URLRewrite
      urlRewrite:
        path:
          replacePrefixMatch: /  # Strip model path prefix
```

**Why it works:** MaaS creates HTTPRoute pointing to port 443, but internal Envoy runs on 8080 (HTTP). This override fixes the port and adds path rewriting.

#### 4. Tenant Service Account - Identity for Tenant Cluster

**File:** [maas-hub/tenant-service-accounts.yaml](maas-hub/tenant-service-accounts.yaml)

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: tenant-consumer-sa
  namespace: tenants
```

**Why it works:** Each tenant cluster is identified by a Service Account. The tenant's MaaS gets an API key bound to this SA for Hub authentication.

#### 5. MaaSSubscription - Tenant Rate Limit

**File:** [maas-hub/maas-subscription.yaml](maas-hub/maas-subscription.yaml)

```yaml
spec:
  modelRefs:
    - name: hub-model
      tokenRateLimits:
        - limit: 500       # Total quota for entire tenant cluster
          window: 1m
  owner:
    users:
      - "system:serviceaccount:tenants:tenant-consumer-sa"
```

**Why it works:** Creates a TokenRateLimitPolicy that counts tokens against the tenant SA. All requests through the tenant's API key share this 500 tokens/min quota.

---

### Tenant Cluster Configuration

#### 1. ExternalModel - Points to Hub MaaS

**File:** [maas-tenant/external-model.yaml](maas-tenant/external-model.yaml)

```yaml
spec:
  endpoint: maas.apps.aigrid-hub.aigriddev.sysdeseng.com  # Hub MaaS gateway
  provider: openai
  targetModel: TinyLlama/TinyLlama-1.1B-Chat-v1.0
  credentialRef:
    name: hub-tenant-sa-token  # Contains Hub API key
```

**Why it works:** Points to Hub's MaaS gateway (not direct Envoy). The credential contains the Hub API key for tenant authentication.

#### 2. Hub Credentials Secret

**File:** [maas-tenant/hub-credentials-secret.yaml](maas-tenant/hub-credentials-secret.yaml)

```yaml
stringData:
  api-key: "sk-oai-SkpVRYKbErJA..."  # Hub API key for tenant-consumer-sa
```

**Why it works:** This API key was generated on Hub using the tenant SA token. It identifies this tenant for Hub-level rate limiting.

#### 3. HTTPRoute Override - Header Injection

**File:** [maas-tenant/httproute-override.yaml](maas-tenant/httproute-override.yaml)

```yaml
filters:
- type: URLRewrite
  urlRewrite:
    path:
      replacePrefixMatch: /models-as-a-service/hub-inference-model
- type: RequestHeaderModifier
  requestHeaderModifier:
    set:
    - name: Host
      value: maas.apps.aigrid-hub.aigriddev.sysdeseng.com
    - name: Authorization
      value: "Bearer sk-oai-SkpVRYKbErJA..."  # Hub API key
```

**Why it works:** MaaS doesn't inject credentials into forwarded requests (designed for external AI providers with BBR). We manually inject the Hub API key via HTTPRoute header modifier.

#### 4. DestinationRule - TLS Configuration

**File:** [maas-tenant/destination-rule.yaml](maas-tenant/destination-rule.yaml)

```yaml
spec:
  host: maas.apps.aigrid-hub.aigriddev.sysdeseng.com
  trafficPolicy:
    tls:
      mode: SIMPLE
      insecureSkipVerify: true  # Cross-cluster CA may not be trusted
```

**Why it works:** The Hub's ingress certificate may not be in Tenant's trust store. `insecureSkipVerify` allows the connection while still encrypting traffic.

#### 5. Service Accounts - User/Team Identities

**File:** [maas-tenant/service-accounts.yaml](maas-tenant/service-accounts.yaml)

```yaml
# Users
- name: user-alice
- name: user-bob
- name: user-charlie

# Teams
- name: team-alpha
- name: team-beta
```

**Why it works:** Each SA simulates a user or team. In production, these would be real OIDC identities. API keys are generated per SA.

#### 6. MaaSSubscriptions - User/Team Rate Limits

**File:** [maas-tenant/maas-subscription.yaml](maas-tenant/maas-subscription.yaml)

```yaml
# Alice: 50 tokens/min
- name: user-alice-subscription
  spec:
    modelRefs:
      - name: hub-tinyllama
        tokenRateLimits:
          - limit: 50
            window: 1m
    owner:
      users:
        - "system:serviceaccount:models-as-a-service:user-alice"
    priority: 10

# Bob: 100 tokens/min
- name: user-bob-subscription
  spec:
    modelRefs:
      - name: hub-tinyllama
        tokenRateLimits:
          - limit: 100
            window: 1m
    owner:
      users:
        - "system:serviceaccount:models-as-a-service:user-bob"
    priority: 10

# Team Alpha: 200 tokens/min
- name: team-alpha-subscription
  spec:
    modelRefs:
      - name: hub-tinyllama
        tokenRateLimits:
          - limit: 200
            window: 1m
    owner:
      users:
        - "system:serviceaccount:models-as-a-service:team-alpha"
    priority: 15
```

**Why it works:** Higher priority subscriptions (10, 15) take precedence over the default shared subscription (priority 0). Each user/team gets independent token counting.

---

## API Keys

| Identity | Type | Limit | API Key |
|----------|------|-------|---------|
| alice | User | 50 tokens/min | `sk-oai-1CTVKCWMXkjRcNOsf_1ktSNCHiKzJYNyMf808AWO8sgSsBn25TnTNYj9Ky8CP` |
| bob | User | 100 tokens/min | `sk-oai-u64sxjpmGdiPX22u_XCzWf6lZBNNbeD14QAGZU3u1Ia9Yc8YsAvcbxGYldJu` |
| team-alpha | Team | 200 tokens/min | `sk-oai-13h03RLzWMnGBhHpe_i744ymrfDai2XvAj2Wu2aX6URLy2tAjsJ6XvJUZykNM` |
| team-beta | Team | (shared) | `sk-oai-KUCSorjb4vovmfvk_uNUlH4F98YyHcm62HkAu52n6VpyBa5EFrv2ea6S4Dnn` |
| tenant-consumer | Hub Tenant | 500 tokens/min | `sk-oai-SkpVRYKbErJALEQH_bjV3riwKk6NhyNscnJO3TpHiIvLPOgMzZDhQLWAWAjB` |

---

## Demo Test Commands

### Setup: Watch MaaS Gateway Logs

Open two terminals to watch requests flowing through both MaaS gateways:

**Terminal 1 - Tenant MaaS Gateway Logs:**
```bash
export KUBECONFIG=~/Projects/llm-d-inference-scheduler/docs/multi-cluster-setup/tenant-consumer/auth/kubeconfig
oc logs -n openshift-ingress -l gateway.networking.k8s.io/gateway-name=maas-default-gateway -f 2>/dev/null | grep --line-buffered -E "hub-multicluster|POST|429|200"
```

**Terminal 2 - Hub MaaS Gateway Logs:**
```bash
export KUBECONFIG=~/Projects/llm-d-inference-scheduler/docs/multi-cluster-setup/hub/auth/kubeconfig
oc logs -n openshift-ingress -l gateway.networking.k8s.io/gateway-name=maas-default-gateway -f 2>/dev/null | grep --line-buffered -E "hub-inference|POST|429|200"
```

**What to look for:**
- Tenant logs show: `POST /models-as-a-service/hub-multicluster-model/...`
- Hub logs show: `POST /models-as-a-service/hub-inference-model/...` (path rewritten!)
- Status codes: `200` (success) or `429` (rate limited)

This proves requests flow through **both** MaaS gateways.

---

### Test 1: Basic Two-Level Flow

**What it tests:** Full request flow through Tenant MaaS → Hub MaaS → EPP → Spoke vLLM

```bash
# Send a single request through the full flow
curl -sk "https://maas.apps.aigrid-consumer.aigriddev.sysdeseng.com/models-as-a-service/hub-multicluster-model/v1/completions" \
  -H "Authorization: Bearer sk-oai-1CTVKCWMXkjRcNOsf_1ktSNCHiKzJYNyMf808AWO8sgSsBn25TnTNYj9Ky8CP" \
  -H "Content-Type: application/json" \
  -d '{"model": "TinyLlama/TinyLlama-1.1B-Chat-v1.0", "prompt": "Hello world", "max_tokens": 10, "stream": false}'
```

**Expected:** HTTP 200 with completion response. This proves:
- Tenant MaaS validates Alice's API key
- Request is forwarded to Hub MaaS with Hub API key
- Hub MaaS validates tenant key and forwards to Envoy
- EPP selects a Spoke based on metrics
- vLLM generates response

---

### Test 2: User-Level Rate Limiting (Alice: 50 tokens/min)

**What it tests:** Alice's individual rate limit is enforced

```bash
# Send 5 requests as Alice (~17 tokens each = ~85 tokens)
for i in {1..5}; do
  echo -n "Request $i: "
  curl -sk "https://maas.apps.aigrid-consumer.aigriddev.sysdeseng.com/models-as-a-service/hub-multicluster-model/v1/completions" \
    -H "Authorization: Bearer sk-oai-1CTVKCWMXkjRcNOsf_1ktSNCHiKzJYNyMf808AWO8sgSsBn25TnTNYj9Ky8CP" \
    -H "Content-Type: application/json" \
    -d '{"model": "TinyLlama/TinyLlama-1.1B-Chat-v1.0", "prompt": "Hello", "max_tokens": 15, "stream": false}' \
    -w " HTTP:%{http_code}\n" -o /dev/null --max-time 10
done
```

**Expected:** First 3 requests return 200, then 429 (rate limited). This proves:
- Alice's 50 token/min limit is enforced at Tenant MaaS level
- Rate limiting happens BEFORE forwarding to Hub

---

### Test 3: User Isolation (Bob works while Alice limited)

**What it tests:** Different users have independent rate limits

```bash
# First, exhaust Alice's limit
for i in {1..5}; do
  curl -sk "https://maas.apps.aigrid-consumer.aigriddev.sysdeseng.com/models-as-a-service/hub-multicluster-model/v1/completions" \
    -H "Authorization: Bearer sk-oai-1CTVKCWMXkjRcNOsf_1ktSNCHiKzJYNyMf808AWO8sgSsBn25TnTNYj9Ky8CP" \
    -H "Content-Type: application/json" \
    -d '{"model": "TinyLlama/TinyLlama-1.1B-Chat-v1.0", "prompt": "Hi", "max_tokens": 15, "stream": false}' \
    -o /dev/null --max-time 5
done

# Now test Bob - should still work
echo "Testing Bob while Alice is limited:"
curl -sk "https://maas.apps.aigrid-consumer.aigriddev.sysdeseng.com/models-as-a-service/hub-multicluster-model/v1/completions" \
  -H "Authorization: Bearer sk-oai-u64sxjpmGdiPX22u_XCzWf6lZBNNbeD14QAGZU3u1Ia9Yc8YsAvcbxGYldJu" \
  -H "Content-Type: application/json" \
  -d '{"model": "TinyLlama/TinyLlama-1.1B-Chat-v1.0", "prompt": "Hello", "max_tokens": 10, "stream": false}' \
  -w "\nHTTP: %{http_code}\n"
```

**Expected:** Bob's request returns 200. This proves:
- Each user has independent token counting
- Alice's exhausted limit doesn't affect Bob

---

### Test 4: Team Rate Limit (team-alpha: 200 tokens/min)

**What it tests:** Team has higher quota than individual users

```bash
# Send 15 requests as team-alpha with longer prompt (~30 tokens each = ~450 tokens, exceeds 200 limit)
for i in {1..15}; do
  echo -n "$i:"
  curl -sk "https://maas.apps.aigrid-consumer.aigriddev.sysdeseng.com/models-as-a-service/hub-multicluster-model/v1/completions" \
    -H "Authorization: Bearer sk-oai-13h03RLzWMnGBhHpe_i744ymrfDai2XvAj2Wu2aX6URLy2tAjsJ6XvJUZykNM" \
    -H "Content-Type: application/json" \
    -d '{"model": "TinyLlama/TinyLlama-1.1B-Chat-v1.0", "prompt": "Write a detailed explanation about the benefits of cloud computing for enterprise applications", "max_tokens": 15, "stream": false}' \
    -w "%{http_code} " -o /dev/null --max-time 10
done
echo ""
```

**Expected:** First ~7 requests return 200, then 429. This proves:
- Team subscriptions work with higher quotas (200 vs alice's 50)
- Priority 15 subscription takes precedence over shared (priority 0)

---

### Test 5: Hub Tenant Rate Limit (500 tokens/min)

**What it tests:** Hub enforces cluster-wide tenant limit

```bash
# Send 20 requests with longer prompt to exhaust the 500 token tenant limit (~40 tokens each = ~800 tokens)
echo "Sending 20 requests to exhaust Hub tenant limit..."
for i in {1..20}; do
  echo -n "$i:"
  curl -sk "https://maas.apps.aigrid-consumer.aigriddev.sysdeseng.com/models-as-a-service/hub-multicluster-model/v1/completions" \
    -H "Authorization: Bearer sk-oai-13h03RLzWMnGBhHpe_i744ymrfDai2XvAj2Wu2aX6URLy2tAjsJ6XvJUZykNM" \
    -H "Content-Type: application/json" \
    -d '{"model": "TinyLlama/TinyLlama-1.1B-Chat-v1.0", "prompt": "Explain the key differences between microservices and monolithic architectures in software engineering", "max_tokens": 25, "stream": false}' \
    -w "%{http_code} " -o /dev/null --max-time 10
done
echo -e "\nDone"
```

**Expected:** First ~12 requests return 200, then 429. This proves:
- Hub MaaS enforces tenant-level rate limit (500 tokens/min)
- All requests from this tenant (regardless of user) count against this quota
- Two-level rate limiting: user limits at Tenant + tenant limit at Hub

**Note:** Run this test in a fresh minute window (wait 60s after previous tests) to isolate Hub limit from Tenant user limits.

---

### Test 6: Direct Hub Test (Bypass Tenant)

**What it tests:** Hub rate limiting works independently

```bash
# Send requests directly to Hub MaaS with longer prompt (~40 tokens each)
for i in {1..20}; do
  echo -n "$i:"
  curl -sk "https://maas.apps.aigrid-hub.aigriddev.sysdeseng.com/models-as-a-service/hub-inference-model/v1/completions" \
    -H "Authorization: Bearer sk-oai-SkpVRYKbErJALEQH_bjV3riwKk6NhyNscnJO3TpHiIvLPOgMzZDhQLWAWAjB" \
    -H "Content-Type: application/json" \
    -d '{"model": "TinyLlama/TinyLlama-1.1B-Chat-v1.0", "prompt": "Explain the key differences between microservices and monolithic architectures in software engineering", "max_tokens": 25, "stream": false}' \
    -w "%{http_code} " -o /dev/null --max-time 10
done
echo ""
```

**Expected:** First ~12 requests return 200, then 429. This proves:
- Hub MaaS rate limiting works independently of Tenant MaaS
- The tenant API key is properly validated

---

## Verification Commands

### Check Tenant Rate Limits

```bash
export KUBECONFIG=~/Projects/llm-d-inference-scheduler/docs/multi-cluster-setup/tenant-consumer/auth/kubeconfig
oc get maassubscription -n models-as-a-service \
  -o custom-columns="NAME:.metadata.name,LIMIT:.spec.modelRefs[0].tokenRateLimits[0].limit,WINDOW:.spec.modelRefs[0].tokenRateLimits[0].window,PRIORITY:.spec.priority"
```

### Check Hub Rate Limits

```bash
export KUBECONFIG=~/Projects/llm-d-inference-scheduler/docs/multi-cluster-setup/hub/auth/kubeconfig
oc get maassubscription -n models-as-a-service \
  -o custom-columns="NAME:.metadata.name,LIMIT:.spec.modelRefs[0].tokenRateLimits[0].limit,WINDOW:.spec.modelRefs[0].tokenRateLimits[0].window"
```

### Check Hub Gateway Logs

```bash
export KUBECONFIG=~/Projects/llm-d-inference-scheduler/docs/multi-cluster-setup/hub/auth/kubeconfig
oc logs -n openshift-ingress -l gateway.networking.k8s.io/gateway-name=maas-default-gateway --tail=20 | grep -E "200|429"
```

---

## Summary

| Rate Limit Level | Where Enforced | Limit | Proven By |
|------------------|----------------|-------|-----------|
| User (alice) | Tenant MaaS | 50 tokens/min | Test 2 |
| User (bob) | Tenant MaaS | 100 tokens/min | Test 3 |
| Team (alpha) | Tenant MaaS | 200 tokens/min | Test 4 |
| Tenant | Hub MaaS | 500 tokens/min | Test 5 |

**Key Takeaways:**
1. Two-level rate limiting works: user/team limits at Tenant, tenant limit at Hub
2. Users are isolated - one user's exhausted limit doesn't affect others
3. The full flow (Tenant → Hub → EPP → Spoke) is functional
4. All rate limits are enforced before reaching the vLLM backend
