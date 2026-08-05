# Downstream AI Grid E2E — Implementation Plan

**Goal:** Reproduce the upstream AI Grid multi-cluster flow (Tenant → Hub → Spoke → vLLM) using:

| Layer | Component | Image / source |
|-------|-----------|----------------|
| Platform | [MaaS](https://github.com/opendatahub-io/models-as-a-service) | Already partially installed (RHOAI) |
| IPP | [ai-gateway-payload-processing](https://github.com/opendatahub-io/ai-gateway-payload-processing) | `ghcr.io/yehuditkerido/ai-gateway-payload-processing:hub-mode` (PRs [#412](https://github.com/opendatahub-io/ai-gateway-payload-processing/pull/412), [#415](https://github.com/opendatahub-io/ai-gateway-payload-processing/pull/415), [#416](https://github.com/opendatahub-io/ai-gateway-payload-processing/pull/416)) |
| EPP | llm-d-router (same as upstream) | `ghcr.io/llm-d/llm-d-router-endpoint-picker:main` |

**Reference:** upstream working env in `docs/multi-cluster-setup/`, E2E PDF (AI-Grid E2E), demo tests in [`../multi-cluster-setup/DEMO.md`](../multi-cluster-setup/DEMO.md).

**Clusters:** `aigrid-ds-{tenant,hub,spoke1,spoke2,spoke3}` — see [CLUSTERS.md](CLUSTERS.md).


---

## Target architecture (downstream)

All clusters use a **hybrid two-gateway** approach: MaaS gateway (controller-managed, handles auth + rate limiting) stays untouched. A standalone Envoy in `llm-d-system` handles EPP and custom routing logic. This avoids `maas-controller` reconciliation conflicts.

```
TENANT
  User → MaaS Gateway (auth + rate limit + Authorino)
       → PP (body→header + resolver + apikey-injection) → injects Hub API key
       → HTTPS to Hub MaaS

HUB — GW1: MaaS (controller-managed, openshift-ingress)
  MaaS Gateway (auth + rate limit + Authorino)
       → MaaS PP (full chain, untouched)
       → HTTPRoute → GW2

HUB — GW2: Standalone Envoy (llm-d-system)
  Envoy
       → EPP (multicluster: picks best Spoke based on metrics/affinity)
       → Static Spoke API key injection (per-route)
       → HTTPS to selected Spoke MaaS

SPOKE (1/2/3) — GW1: MaaS (controller-managed, openshift-ingress)
  MaaS Gateway (auth + rate limit + Authorino)
       → MaaS PP (full chain, untouched)
       → HTTPRoute → GW2

SPOKE (1/2/3) — GW2: Standalone Envoy (llm-d-system)
  Envoy
       → Spoke EPP (pod selection: picks best vLLM pod based on metrics)
       → vLLM pod
```

**Key design points:**
- **Tenant:** No EPP needed (single destination = Hub). PP injects Hub API key.
- **Hub GW1 → GW2:** MaaS routes to standalone Envoy via ExternalModel endpoint. PP plugins on GW1 are harmless (hub-post would overwrite on GW2 once dynamic injection is implemented).
- **Spoke GW1 → GW2:** MaaS routes to standalone Envoy via ExternalModel. Spoke EPP selects the best pod within the cluster.

---

## Current env snapshot (2026-08-05)

| Cluster | Component | Status |
|---------|-----------|--------|
| **Tenant** | MaaS Gateway | ✅ Auth working (API key + Authorino) |
|  | Payload Processor | ✅ Running (api-translation removed, payload-processing-fix EF) |
|  | ExternalModels | ✅ `hub-tinyllama` + `hub-qwen` → Hub MaaS |
|  | Subscriptions/Auth | ✅ alice, charlie, team-alpha configured |
| **Hub** | MaaS Gateway (GW1) | ✅ Auth + rate limiting working |
|  | MaaS PP (GW1) | ✅ Stock full chain, controller-managed |
|  | Standalone Envoy (GW2) | ✅ EPP + static spoke keys |
|  | Hub EPP | ✅ Multicluster plugins, picks spokes, `FULL_DUPLEX_STREAMED` |
|  | stub-metrics | ⚠️ Temporary dummy metrics — replace with real Spoke EPP metrics routes (see item #4) |
| **Spoke1** | MaaS Gateway | ✅ Auth working |
|  | Standalone Envoy | ✅ EPP ext_proc enabled |
|  | Spoke EPP | ✅ Running, discovers 2 vLLM pods |
|  | vLLM (TinyLlama) | ❌ Pending (GPU capacity) |
| **Spoke2** | MaaS Gateway | ✅ Auth working |
|  | Standalone Envoy | ✅ EPP ext_proc enabled |
|  | Spoke EPP | ✅ Running, discovers 2 vLLM pods |
|  | vLLM (TinyLlama) | ❌ Pending (GPU capacity) |
| **Spoke3** | MaaS Gateway | ⚠️ Pre-existing 403 (Authorino OPA issue) |
|  | Standalone Envoy | ✅ EPP ext_proc enabled |
|  | Spoke EPP | ✅ Running, discovers 1 vLLM pod |
|  | vLLM (Qwen) | ❌ Pending (GPU capacity) |

### What’s needed for E2E HTTP 200

| # | Item | Blocker type | Effort |
|---|------|-------------|--------|
| 1 | **vLLM pods Running** on at least one Spoke | Infrastructure (GPU nodes) | Need GPU capacity |
| 2 | **Spoke Envoy path rewrite** | Config (2 min per spoke) | Add `regex_rewrite` to strip `/models-as-a-service/<model>/` prefix |
| 3 | **Spoke3 auth fix** (optional — Spoke1/2 sufficient) | Investigation | Authorino OPA `require-group-membership` rule |
| 4 | **Expose Spoke EPP metrics + remove stub-metrics** | Config + mTLS route | See details below |

Once items #1 and #2 are resolved, the full E2E chain will return HTTP 200:
```
Alice → Tenant MaaS (auth) → Tenant PP (Hub key) → Hub MaaS (auth)
  → Hub EPP (pick spoke) → Hub Envoy (spoke key) → Spoke MaaS (auth)
  → Spoke Envoy → Spoke EPP (pick pod) → vLLM → 200
```

### Item #4: Spoke metrics exposure + stub-metrics removal

**Current state:** Hub EPP’s `multicluster-file-discovery` needs to scrape metrics from each Spoke to make intelligent routing decisions (KV-cache utilization, queue depth). Currently, Hub EPP’s `epp-clusters` ConfigMap points all `metricsAddress` entries to a temporary `stub-metrics` pod in `llm-d-system` (Hub) that returns empty Prometheus metrics. This makes EPP treat all Spokes as equal (random rotation).

**What’s needed:**
1. Create an OpenShift Route on each Spoke exposing Spoke EPP’s metrics port (9002) — e.g. `epp-metrics-llm-d-system.apps.aigrid-ds-spoke1.aigriddev.sysdeseng.com`
2. Configure mTLS on these routes (Hub EPP must authenticate when scraping) — or use passthrough TLS if Spoke EPP serves TLS metrics
3. Update Hub `epp-clusters` ConfigMap: change `metricsAddress` for each spoke from `stub-metrics.llm-d-system.svc.cluster.local` to the real Spoke metrics route
4. Delete `stub-metrics` Deployment + Service from Hub `llm-d-system`

**Impact of not doing this:** E2E will still return 200 (basic functionality works), but Hub EPP won’t make load-aware decisions — it will just round-robin across Spokes. For the demo, this is acceptable. For production-like behavior (tests #9, #10 in the test plan), real metrics are required.

---


## Workstream S0 — Stabilize (blocking, ~30–60 min)

**Owner:** either

- [x] Confirm all APIs: `oc get nodes` on tenant/hub/spoke1/2/3
- [x] Hub/Tenant `payload-processing` Running (see fix below)
- [x] PP image override method decided (see below)

**Exit:** Hub and Tenant PP pods Running (even on stock image); all cluster APIs Ready.

### S0 findings (2026-08-02)

**APIs:** All five clusters Ready.

**PP CrashLoop root cause:** `openshift-ingress` has `openshift-ingress-deny-all` (deny Ingress+Egress for all pods). Gateway pods have allow NetworkPolicies; `payload-processing` did not, so it could not reach `172.30.0.1:443` (API) and failed ExternalModel/Secret cache sync.

**Fix applied:** `deployments/payload-processing-networkpolicy.yaml` (`payload-processing-allow`) on Hub and Tenant. After apply + pod restart: API healthz 200, caches populated, 0 restarts.

**PP on Hub (for B1 later):** Reuse MaaS stock PP as PRE (`body-field-to-header` only). Add a separate hub-post (hub-mode image) after EPP. Do not run full MaaS plugin chain (resolver/apikey) before EPP.

---

## Workstream A — Spokes (Person A)

### A1. Fix Spoke1 vLLM (before anything else on Spoke1)

**Problem:** pods Pending — `Insufficient cpu/memory` on GPU workers (requests: 2 CPU + 8Gi + 1 GPU).

- [x] Compare working Spoke2 vLLM Deployment requests/limits with Spoke1
- [x] Align Spoke1 requests (or free/cordon competing workloads) until both replicas schedule
- [x] Confirm `/health` on both pods

**Exit:** `vllm-tinyllama` 2/2 Ready on Spoke1 (same as Spoke2).

**Done (2026-08-03):** Spoke2 keeps `cpu: 2` / `memory: 8Gi`. Spoke1 GPU workers were packed (MaaS/LWS/ingress), so Spoke1 was patched to `cpu: 1` / `memory: 6Gi` + GPU. Both replicas Ready on `ip-10-0-14-22` and `ip-10-0-49-177`; `/health` → 200. Temporary scale-down of LWS / `kube-auth-proxy` helped free capacity; CSV/operator may restore their replicas — if vLLM goes Pending again, re-check allocatable on GPU workers.

### A2. MaaS on each Spoke

Mirror upstream spoke MaaS pattern (`maas-spoke/`). Manifests: `maas-spoke/overlays/{tinyllama,qwen}`.

Per spoke (1 → 2 → 3, or 2/3 while A1 runs):

- [x] Spoke2: MaaS platform via `deploy.sh --operator-type rhoai` (+ postgres, Authorino TLS)
- [x] Spoke1 / Spoke3: same platform install
- [x] All spokes: Tenant Ready / `ModelsAsServiceReady`
- [x] All spokes: ExternalModel → vLLM + ModelRef + AuthPolicy + Subscription
- [x] All spokes: Hub consumer API key (`models-as-a-service/hub-consumer-maas-api-key`)
- [x] All spokes: Authorino TLS + HTTPRoute URLRewrite (`deployments/spoke-path-rewrite.yaml`)
- [x] Smoke 200: Spoke1 TinyLlama, Spoke2 TinyLlama, Spoke3 Qwen (direct vLLM backend; no Spoke EPP yet)
- [x] Rate-limit proof (Spoke2): lowered `tokenRateLimits` to 30/1m → HTTP 200×2 then 429; restored to 100000; post-restore smoke 200

**Exit:** `curl` with Spoke API key → MaaS path returns 200; rate-limit policy can return 429 when limit is hit.

**Install notes (2026-08-03):** GPU workers are capacity-starved after RHOAI. Pin `rhods-operator` to 1 + master toleration; scale down LWS / data-science-gateway / kube-auth-proxy; lower vLLM requests (`500m`/`4Gi`). `deploy.sh` may time out waiting for DSC before postgres — run `setup-database.sh` with `MAAS_CONTROLLER_NAMESPACE=redhat-ods-applications` then wait for Tenant Ready. Authorino TLS needs `AUTHORINO_NAMESPACE=rh-connectivity-link`. Spoke3: keep `vllm-qwen` at 1 replica while only 2 GPUs are free.

### A3. Spoke EPP + path rewrite + mTLS metrics

A2 already brings up Spoke **MaaS** (`maas.apps...`, API-key auth). A3 adds what sits **behind** MaaS and the **second** address Hub file-discovery needs:

| file-discovery field | What it is | Auth |
|----------------------|------------|------|
| `address` | Spoke MaaS FQDN (from A2) — Hub routes inference here | MaaS API key (IPP injects) |
| `metricsAddress` | Spoke EPP / inference-gateway metrics route | mTLS (Hub EPP scrape) |

**Spoke standalone Envoy deployed (2026-08-04):**

Same hybrid two-gateway pattern as Hub: MaaS gateway stays untouched; a standalone Envoy in `llm-d-system` sits between MaaS and vLLM, ready to host the Spoke EPP.

| Component | Namespace | Details |
|-----------|-----------|---------|
| MaaS gateway | `openshift-ingress` | Untouched; auth + rate limit + PP (stock) |
| ExternalModel | `models-as-a-service` | `spoke-inference-model` → `envoy.llm-d-system.svc.cluster.local:8080` |
| Standalone Envoy | `llm-d-system` | EPP ext_proc placeholder (commented), routes → vLLM backend |
| DestinationRule | `llm-d-system` | `envoy-no-mtls` — disables Istio mTLS for envoy service |

Manifest: `deployments/spoke-envoy.yaml` (uses `VLLM_SERVICE_PLACEHOLDER` — deployed via `sed` substitution per Spoke).

- [x] Deploy Spoke Envoy (EPP placeholder) on all 3 Spokes — `llm-d-system` namespace ✓
- [x] Update ExternalModels: `spoke-inference-model` endpoint → `envoy.llm-d-system.svc.cluster.local` ✓
- [x] DestinationRule `envoy-no-mtls` on all Spokes ✓
- [x] Smoke test Spoke2: MaaS → Envoy → vLLM = 404 (path rewrite pending, flow confirmed) ✓
- [x] Deploy Spoke EPP on all 3 Spokes ✔ (2026-08-05)
  - Image: `ghcr.io/llm-d/llm-d-router-endpoint-picker:main`
  - Spoke1/2: `--endpoint-selector=app=vllm-tinyllama`, Spoke3: `--endpoint-selector=app=vllm-qwen`
  - All: `--pool-namespace=llm-inference`, `--grpc-port=9001`, `--secure-serving=false`
  - RBAC: `epp-pod-reader` ClusterRole (pods, services, endpointslices)
  - Config: `core-metrics-extractor` with vLLM engine specs
- [x] Envoy ConfigMap: EPP ext_proc (`FULL_DUPLEX_STREAMED`) + EPP cluster enabled on all 3 Spokes ✔
- [ ] Path rewrite after MaaS: strip `/models-as-a-service/[^/]+/` before EPP/vLLM
- [ ] Metrics route + mTLS so Hub EPP can scrape `metricsAddress` (same as upstream)
- [ ] Smoke: request via Spoke MaaS key → MaaS → EPP → vLLM (blocked: vLLM Pending on all Spokes)

**Pre-existing issues (not from Envoy deployment):**
- Spoke1: vLLM pods Pending (GPU worker capacity — see A1)
- Spoke3: MaaS auth returns 403 PERMISSION_DENIED (Authorino config issue — key validates but group-membership authorization fails; needs investigation)

**Exit:** Both FQDNs exist per spoke (MaaS + metrics). No separate “exposure” step beyond that.

### A4. Hand off addresses to Hub (not a new component)

A4 is only the sync table for Person B’s Hub file-discovery + ExternalModels. Same hostnames; no extra Routes.

```yaml
# Hub cluster-endpoints (file-discovery)
endpoints:
  - name: spoke1
    address: maas.apps.aigrid-ds-spoke1.aigriddev.sysdeseng.com          # MaaS auth
    port: "443"
    metricsAddress: inference-gateway-llm-d-system.apps.aigrid-ds-spoke1.aigriddev.sysdeseng.com  # mTLS
    metricsPort: "443"
    labels:
      model: TinyLlama/TinyLlama-1.1B-Chat-v1.0
```

| Spoke | Model | `address` (MaaS) | `metricsAddress` (mTLS scrape) |
|-------|-------|------------------|--------------------------------|
| spoke1 | TinyLlama | `maas.apps.aigrid-ds-spoke1.aigriddev.sysdeseng.com` | `inference-gateway-llm-d-system.apps.aigrid-ds-spoke1.aigriddev.sysdeseng.com` |
| spoke2 | TinyLlama | `maas.apps.aigrid-ds-spoke2.aigriddev.sysdeseng.com` | `inference-gateway-llm-d-system.apps.aigrid-ds-spoke2.aigriddev.sysdeseng.com` |
| spoke3 | Qwen | `maas.apps.aigrid-ds-spoke3.aigriddev.sysdeseng.com` | `inference-gateway-llm-d-system.apps.aigrid-ds-spoke3.aigriddev.sysdeseng.com` |

- [x] Confirmed both FQDNs per spoke (MaaS + metrics stub)
- [x] Spoke API keys configured in Hub Envoy routes
- [x] Hub `epp-clusters` ConfigMap configured with all 3 Spoke endpoints

**SYNC with B:** Hub file-discovery + ExternalModels.

---

## Workstream B — Hub (Person B)

### B1. Hub MaaS PP: leave untouched; `maas-controller` runs normally

Hub already has **MaaS-managed** stock `payload-processing` (Deployment + EnvoyFilter). The controller reconciles it with the full plugin chain (`body-field-to-header` + `model-provider-resolver` + `api-translation` + `apikey-injection`). There is **no mechanism** to disable individual plugins (no CRD field, no ConfigMap toggle — validated experimentally on 2026-08-04).

**Decision (2026-08-04):** Leave MaaS PP **untouched**. Let `maas-controller` run normally (replicas=1). The "unnecessary" plugins (resolver, apikey, api-translation) are harmless on GW1 — hub-post on GW2 overwrites after EPP picks the actual Spoke.

**Why not narrow the PP?** Scaling `maas-controller` to 0 is fragile. If the controller restarts for any reason (pod eviction, operator upgrade, node drain), it reverts PP args + EnvoyFilter match — silently breaking the entire ext_proc chain.

- [x] Inventory Hub MaaS PP Deployment + EnvoyFilter + `payload-processing-plugins` CM
- [x] Confirmed: no plugin-disable mechanism exists; controller always reconciles full chain
- [x] **Decision: leave MaaS PP untouched, `maas-controller` replicas=1**
- [x] Scale `maas-controller` back to 1 ✓ (2026-08-04)
- [x] Remove `hub-post` EnvoyFilter from MaaS gateway ✓ (moved to GW2)
- [x] Tenant: MaaS PP runs standard chain (api-translation removed for Hub routing)

**Exit:** MaaS PP runs the full chain on GW1. `maas-controller` runs normally. `X-Gateway-Model-Name` header is set.

### B2. Hub standalone gateway (GW2): EPP + hub-post — namespace `llm-d-system`

Deploy a **separate standalone Envoy** (`envoy`) in the `llm-d-system` namespace, independent from MaaS and its controller.

**GW1 (MaaS, controller-managed, `openshift-ingress`)** → HTTPRoute/backend → **GW2 (`envoy`, `llm-d-system`)** → Spoke MaaS

| Piece | Gateway | Role |
|-------|---------|------|
| **Auth** | GW1 (MaaS) | Authorino (existing) |
| **MaaS PP** | GW1 (MaaS) | full chain, untouched (sets `X-Gateway-Model-Name` + harmless resolver/apikey) |
| **EPP** | GW2 (standalone) | `model-affinity-filter` on `X-Gateway-Model-Name` + scorers → `x-gateway-destination-endpoint` |
| **hub-post** | GW2 (standalone) | hubMode TRANSFORM: match EPP destination → `apikey-injection` |

- [x] Deploy standalone Envoy `envoy` (Deployment + Service + ConfigMap) in `llm-d-system` ✓
- [x] Configure MaaS GW1 → GW2: changed ExternalModel endpoints to `envoy.llm-d-system.svc.cluster.local`; `maas-controller` auto-reconciled HTTPRoutes + ExternalName services ✓
- [x] hub-post ext_proc configured in GW2 Envoy config (grpc cluster → `hub-post.llm-d-system:9004`) ✓
- [x] GW2 → Spoke TLS: mounts `spoke-ca-certs` ConfigMap with Spoke ingress CAs; each cluster has `UpstreamTlsContext` with `trusted_ca` + SNI ✓
- [x] DestinationRule `envoy-no-mtls`: disable Istio mTLS for GW2 ✓
- [x] Hub EPP ext_proc on GW2 before hub-post (WORKING — see B3)
- [x] file-discovery entries labeled with `model:` (clusters.yaml configured)
- [x] Spoke choice is EPP (verified: rotation across spoke1/2/3)

**Smoke test (2026-08-04):** MaaS GW1 → hub-router GW2 → Spoke1 MaaS = **404** (expected — Spoke path rewrite A3 pending). Confirms full two-gateway flow works: auth ✓, rate limiting ✓, hub-post ext_proc processes request ✓, path-based routing to correct Spoke ✓.

**Manifest:** `deployments/envoy.yaml`, `deployments/hub-post.yaml`.

**Note:** hub-post still needs hubMode TRANSFORM so credentials follow EPP's pick. Without EPP, hub-post receives no `x-gateway-destination-endpoint` → does nothing; MaaS PP on GW1 already injected the Spoke key (matched ExternalModel by path).

### B3. Hub EPP (on GW2)

### B3. Hub EPP (on GW2) — WORKING ✓

**Status (2026-08-05):** Hub EPP is deployed and functional. Root cause of ext_proc hang was incorrect `processing_mode` — must use `FULL_DUPLEX_STREAMED` (see Gap #8).

- [x] Deploy Hub EPP image with Sam's multicluster plugins (`multicluster-file-discovery`, `multicluster-metrics-*`, scorers)
- [x] Configure `clusters.yaml` with Spoke endpoints (using `stub-metrics` for metrics)
- [x] Wire EPP ext_proc on Hub Envoy with correct `FULL_DUPLEX_STREAMED` processing mode
- [x] Verify EPP picks endpoints and sets `x-gateway-destination-endpoint` (rotation across spokes confirmed)
- [x] Hub Envoy routes inject correct Spoke API keys per-route (static injection; see Gap #1)
- [x] Validated full chain: Hub Envoy → EPP → Spoke MaaS (auth passes) → Spoke Envoy → vLLM (503 = GPU Pending)
- [ ] Hub-post dynamic credential injection (blocked: `pr-416` image doesn't implement endpoint-based hubMode TRANSFORM resolution — see Gap #9)

**Exit:** EPP logs show model-affinity filtering (e.g. TinyLlama → spoke1/2 only); destination header is Spoke MaaS host:443.

### B4. Hub MaaS / ExternalModel plane (MaaS → MaaS)

- [x] Hub consumer identities: `tenant-consumers/tenant-consumer-sa` namespace + SA
- [x] ExternalModel per spoke: `spoke1-tinyllama`, `spoke2-tinyllama`, `spoke3-qwen` — endpoint = Spoke MaaS FQDN, credentialRef → Spoke API key Secret
- [x] Spoke API key Secrets: `spoke1-api-key`, `spoke2-api-key`, `spoke3-api-key`
- [x] TinyLlama aggregates spoke1+spoke2; Qwen → spoke3
- [x] `MaaSModelRef`: `hub-tinyllama` (Ready), `hub-qwen` (Ready)
- [x] `MaaSAuthPolicy`: `tenant-access-policy` — allows `tenant-consumer-sa` — Active
- [x] `MaaSSubscription`: `tenant-subscription` — 500 tokens/min per model — Active
- [x] Tenant API key: generated via MaaS API, stored in `tenant-hub-gateway-credentials` Secret
- [x] Hub→Spoke TLS: Spoke ingress CAs injected into gateway pod system CA bundle; DestinationRules with SIMPLE TLS + SNI per spoke
- [x] Auth smoke test: correct key passes (503 — no EPP yet), wrong key → 403

**Done (2026-08-04):** All Hub MaaS CRs created. `maas-controller` running (replicas=1) and reconciles normally. HTTPRoutes auto-created for all 3 ExternalModels — now point to `envoy.llm-d-system` GW2 (ExternalModel endpoints updated). Hub gateway trusts Spoke ingress CAs (OCP self-signed) via `spoke-ca-certs` ConfigMap. Smoke test: auth works; 404 from Spoke MaaS expected (A3 path rewrite pending).

**Manifests:** `maas-hub/external-models.yaml`, `maas-hub/tenant-access.yaml`, `maas-hub/hub-to-spoke-tls.yaml`.

**SYNC:** Spoke FQDNs + API keys obtained from Workstream A (completed by Yehudit).

---

## Workstream C — Tenant (can start in parallel; finish after Hub keys)

### C1. Manifests / identities — DONE ✓

- [x] User/team SAs (alice, charlie, team-alpha) — created in `models-as-a-service`
- [x] ExternalModels `hub-tinyllama` + `hub-qwen` → endpoint `maas.apps.aigrid-ds-hub.aigriddev.sysdeseng.com`
- [x] MaaSModelRefs mapping `tinyllama` → `hub-tinyllama`, `qwen` → `hub-qwen`
- [x] TLS handled by MaaS gateway (ExternalName Service + `maas.opendatahub.io/port: "443"` annotation)

### C2. Wire after Hub is ready — DONE ✓

- [x] Hub API key stored in Tenant Secret `hub-gateway-credentials` (ns `models-as-a-service`, both labels present)
- [x] Tenant PP = **standard** (no hubMode): body→header + resolver + apikey-injection (api-translation REMOVED to preserve MaaS path for Hub routing)
- [x] Subscriptions: `alice-subscription` (tinyllama), `charlie-subscription` (qwen), `team-alpha-subscription` (both), `tenant-global-subscription` (system:authenticated)
- [x] AuthPolicies: `alice-tinyllama-access`, `charlie-qwen-access`, `team-alpha-all-access`
- [x] Stock RHOAI PP image with `payload-processing-fix` EnvoyFilter (same fix as Hub — Gap #5)

### C2. Tenant E2E — VALIDATED ✓ (2026-08-05)

Full chain confirmed working:
```
Alice (sk-oai-...) → Tenant MaaS (auth passes)
  → Tenant PP (injects Hub key from hub-gateway-credentials)
  → Hub MaaS (auth passes with Hub API key)
  → Hub EPP (picks spoke — x-session-token: default/spoke2)
  → Hub Envoy (routes to spoke2, injects spoke2 API key)
  → Spoke2 MaaS (auth passes)
  → 503 (vLLM Pending — GPU capacity, expected)
```
Response time: ~264ms (Hub upstream). E2E returns HTTP 503 = vLLM pods are Pending on all Spokes.

**Note:** `api-translation` plugin MUST be removed from Tenant PP args. It rewrites the path to `/v1/chat/completions` which breaks Hub MaaS routing (Hub needs `/models-as-a-service/<model>/...` prefix). The `maas-controller` may re-add it if it reconciles; monitor and re-patch if needed.

**Exit:** ✓ Tenant `curl` with Alice API key reaches Hub → EPP → Spoke (503 = vLLM down, not a routing issue).

---

## Workstream D — Cross-cluster glue (together / after A+B sync)

- [x] End-to-end secret matrix: keys stored in cluster-only Secrets (not in git)
- [x] Hub EPP endpoints file matches live Spoke routes (clusters.yaml)
- [x] Hub ExternalModels match EPP endpoint hostnames (static key injection in Envoy routes)
- [x] DS↔EPP contract: validated FULL_DUPLEX_STREAMED mode, model extraction from body, endpoint selection

---

## Workstream E — Test plan

Adapt [`../multi-cluster-setup/DEMO.md`](../multi-cluster-setup/DEMO.md) hosts to `aigrid-ds-*`. Add PDF routing tests.

| # | Test | Expected |
|---|------|----------|
| 1 | Full E2E Alice → TinyLlama | HTTP 200; logs show Tenant PP key inject, Hub IPP-Pre/EPP/IPP-Post, Spoke EPP, vLLM |
| 2 | Alice rate limit 50/min | 200 then 429 |
| 3 | team-alpha 200/min | 200 then 429 |
| 4 | Hub tenant 500/min | 200 then 429 |
| 5 | Direct Hub with tenant key | 200 |
| 6 | Alice → Qwen | 403 |
| 7 | Charlie → Qwen | 200 (Spoke3 only) |
| 8 | Charlie → TinyLlama | 403 |
| 9 | Model affinity TinyLlama | Only Spoke1/2 in EPP/IPP logs; never Spoke3 |
| 10 | Load distribution (10× TinyLlama) | Spread across Spoke1/2; Spoke3 = 0 |
| 11 | Dynamic credentials | No static API keys in Envoy config; Secrets + ExternalModel only |
| 12 | hubMode proof | With EPP forced/mocked destination, IPP-Post injects **that** spoke's key (not weight pick) |

Deliverable: `DEMO.md` (or `DEMO-downstream.md`) in this directory with real hostnames and placeholder key names.

---

## Open gaps (blocking full E2E)

These must be resolved before the E2E returns HTTP 200 or before the demo is production-ready.

### 1. Spoke Envoy: path rewrite (strip MaaS prefix)

**Status:** Not yet applied to all Spokes.  
**Problem:** MaaS routes requests to Spoke Envoy with path `/models-as-a-service/<model>/v1/chat/completions`. vLLM only understands `/v1/...`.  
**Fix:** Add `regex_rewrite` to Spoke Envoy route config to strip the `/models-as-a-service/[^/]+/` prefix. 2 min per Spoke.

### 2. Spoke EPP metrics not exposed (stub-metrics in use)

**Status:** Hub EPP scrapes a dummy `stub-metrics` pod instead of real Spoke EPP metrics.  
**Problem:** Without real metrics, Hub EPP can’t make load-aware decisions (KV-cache, queue depth). It just round-robins.  
**Fix:**
1. Create OpenShift Route per Spoke exposing EPP metrics (port 9002)
2. Configure mTLS or passthrough TLS on these routes
3. Update Hub `epp-clusters` ConfigMap → real Spoke metrics addresses
4. Delete `stub-metrics` Deployment + Service from Hub `llm-d-system`

### 3. vLLM pods Pending (GPU capacity)

**Status:** All 5 vLLM pods across 3 Spokes are Pending.  
**Problem:** No GPU worker capacity available.  
**Fix:** Free GPU resources or scale node group.

### 4. Spoke3 MaaS auth 403 (pre-existing)

**Status:** Optional — Spoke1/2 are sufficient for E2E.  
**Problem:** Authorino OPA `require-group-membership` rule fails on Spoke3.  
**Fix:** Investigate AuthConfig on Spoke3.

### 5. Tenant PP: `api-translation` removal may be reverted

**Status:** Patched Tenant PP to remove `--plugin $(API_TRANSLATION)`. Working now.  
**Risk:** `maas-controller` may re-add it if it reconciles the Deployment.  
**Proper fix options:**
  - (a) Deploy a separate IPP instance for Tenant (not managed by maas-controller)
  - (b) Fix `maas-controller` to support per-tenant plugin customization
  - (c) Fix `api-translation` plugin to not rewrite `:path` pre-route

### 6. Tenant/Hub PP: EnvoyFilter workaround (`payload-processing-fix`) — RHOAIENG-76228

**Status:** Stable workaround in place (custom EF with correct anchor).  
**Root cause:** RHOAI 3.4.2 MaaS v0.1.1 hardcodes WasmPlugin anchor name; RHCL 1.4 uses `envoy.filters.http.wasm`.  
**Resolution:** Upgrade to RHOAI 3.5 when GA ([PR #1146](https://github.com/opendatahub-io/models-as-a-service/pull/1146) fixes this).  
**Our workaround is safe:** `maas-controller` only reconciles its own EF by name; ours coexists without conflict.

---

## Future improvements (not blocking E2E)

These are not needed for the demo but should be addressed for production readiness.

### Hub-post dynamic credential injection

**Current:** Static API keys in Hub Envoy routes per-spoke.  
**Why blocked:** The `pr-416` hub-post image’s `model-provider-resolver` doesn’t implement endpoint-based resolution from `x-gateway-destination-endpoint` header. It only resolves by model name.  
**Proper fix:** `model-provider-resolver` needs a TRANSFORM mode that reads EPP’s destination header, matches it to an ExternalProvider endpoint, and injects the correct credential.

### Credential Secret label automation

**Current:** Manually added `inference.networking.k8s.io/bbr-managed: "true"` label to credential Secrets.  
**Why:** `maas-controller` doesn’t add the label that the PP’s `apikey-injection` informer needs.  
**Proper fix:** File upstream bug for `maas-controller` to auto-label Secrets referenced by `credentialRef`.

---

## Fixes applied (reference)

Issues discovered and resolved during this work. Kept for documentation.

| # | Issue | Root cause | Fix applied |
|---|-------|-----------|-------------|
| 1 | Hub EPP ext_proc deadlock | `processing_mode: BUFFERED` caused protocol deadlock | Changed to `FULL_DUPLEX_STREAMED` for all ext_proc filters |
| 2 | Hub Envoy `spoke1` cluster wrong address | Config error: pointed to Spoke2 | Corrected to `maas.apps.aigrid-ds-spoke1...`; updated all Spoke API keys |
| 3 | Hub Envoy path-based fallback routes | Needed before EPP was deployed | EPP now sets `x-gateway-destination-endpoint`; header-based routes take priority |
| 4 | PP NetworkPolicy blocked | `openshift-ingress-deny-all` blocked PP → API server | Added `payload-processing-allow` NetworkPolicy |
| 5 | Credential Secret not discovered by PP | Missing `bbr-managed` label | Manually labeled `hub-gateway-credentials` Secret |
| 6 | Tenant E2E 404 (path rewrite too early) | `api-translation` stripped MaaS prefix before gateway routing | Removed `api-translation` from Tenant PP args |
## Directory layout to create

```text
docs/multi-cluster-setup-downstream/
├── PLAN.md                 ← this file
├── CLUSTERS.md
├── README.md
├── DEMO.md                 ← to write (from upstream DEMO + routing tests)
├── deployments/
│   ├── envoy.yaml              # Hub standalone Envoy (llm-d-system)
│   ├── hub-post.yaml           # Hub hub-post IPP (llm-d-system)
│   ├── spoke-envoy.yaml        # Spoke standalone Envoy template (llm-d-system)
│   ├── hub-epp.yaml            # Hub EPP (multicluster)
│   ├── spoke-epp.yaml          # Spoke EPP (pod selection)
│   └── ...
├── maas-hub/
├── maas-tenant/
├── maas-spoke/             # shared + per-spoke overlays if needed
└── pp-hub/
    ├── values-hub-pre.yaml
    └── values-hub-post.yaml
```

Copy/adapt from `docs/multi-cluster-setup/`; do not invent a second pattern.

---
