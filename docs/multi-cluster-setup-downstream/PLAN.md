# Downstream AI Grid E2E — Implementation Plan

**Goal:** Reproduce the upstream AI Grid multi-cluster flow (Tenant → Hub → Spoke → vLLM) using:

| Layer | Component | Image / source |
|-------|-----------|----------------|
| Platform | [MaaS](https://github.com/opendatahub-io/models-as-a-service) | Already partially installed (RHOAI) |
| IPP | [ai-gateway-payload-processing](https://github.com/opendatahub-io/ai-gateway-payload-processing) | `ghcr.io/yehuditkerido/ai-gateway-payload-processing:hub-mode` (PRs [#412](https://github.com/opendatahub-io/ai-gateway-payload-processing/pull/412), [#415](https://github.com/opendatahub-io/ai-gateway-payload-processing/pull/415), [#416](https://github.com/opendatahub-io/ai-gateway-payload-processing/pull/416)) |
| EPP | llm-d-router (same as upstream) | `ghcr.io/yehuditkerido/llm-d-router-endpoint-picker:multi-cluster-test` (override if you have a newer tag) |

**Reference:** upstream working env in `docs/multi-cluster-setup/`, E2E PDF (AI-Grid E2E), demo tests in [`../multi-cluster-setup/DEMO.md`](../multi-cluster-setup/DEMO.md).

**Clusters:** `aigrid-ds-{tenant,hub,spoke1,spoke2,spoke3}` — see [CLUSTERS.md](CLUSTERS.md).

---

## Decisions (locked)

1. **Hub topology = hybrid two-gateway.** GW1 = MaaS gateway (auth + rate limit + full PP, controller-managed). GW2 = standalone Envoy (EPP + hub-post, our deployment). Avoids `maas-controller` reconciliation conflicts (decision 2026-08-04).
2. **EPP owns spoke selection.** Downstream IPP must not pick by weight (`selectByWeight`). Use `hubMode: true` so IPP only PROPOSEs eligible endpoints, then TRANSFORMs after EPP sets `x-gateway-destination-endpoint`.
3. **All three spokes must be healthy** — fix Spoke1 before calling the env "ready".
4. **EPP config/behavior matches upstream**; fix any DS integration gaps as they appear.
5. **Test bar = DEMO.md suite + PDF routing tests** (model affinity, load split, credential injection).
6. **Shared manifests live under this directory** (same idea as upstream `multi-cluster-setup/`), so both people apply the same YAML. We create them as we implement — they do not exist yet.

### Clarifications from earlier questions

**"Deploy with this image" (image pull):**  
We patch/redeploy `payload-processing` (and hub-pre/hub-post if split) to use  
`ghcr.io/yehuditkerido/ai-gateway-payload-processing:hub-mode`.  
If pods go `ImagePullBackOff`, we add a GHCR pull secret to `openshift-ingress` (or the deploy namespace). No other registry work unless pull fails.

**"Manifests question":**  
Upstream keeps deploy YAML under `docs/multi-cluster-setup/` (`maas-hub/`, `deployments/`, …).  
Downstream only has cluster lifecycle scripts today. As we implement, we add the same kind of tree here (`maas-spoke/`, `maas-hub/`, `maas-tenant/`, `deployments/`, …) so work is reviewable and repeatable — not ad-hoc `oc` only.

---

## Target architecture (downstream) — Hybrid Two-Gateway

**Decision (2026-08-04):** Use a **hybrid two-gateway** approach on the Hub. MaaS gateway stays untouched (no scaling down `maas-controller`, no narrowing the PP chain). A separate gateway handles EPP + hub-post.

**Why not single gateway?** The `maas-controller` reconciles `payload-processing` (Deployment + EnvoyFilter) to its desired state. There is no CRD field or ConfigMap to disable individual plugins. If the controller restarts for any reason, it reverts our customizations — silently breaking the entire ext_proc chain. This was validated experimentally: controller restored all 4 plugins and reverted the EnvoyFilter match.

```
TENANT
  User → MaaS Gateway (auth + rate limit)
       → PP (standard, NOT hubMode): body→header + resolver + apikey → Hub key
       → HTTPS to Hub MaaS
       (single ExternalModel → Hub only; no candidates / no EPP)

HUB — Gateway 1: MaaS (untouched, controller-managed)
  MaaS Gateway (auth + rate limit)
       → Auth (Authorino)
       → MaaS PP (full chain, untouched): body→header + resolver + apikey + api-translation
       → HTTPRoute → Hub routing gateway (GW2)
       Note: resolver/apikey run here but are harmless — hub-post overwrites on GW2

HUB — Gateway 2: Standalone (EPP + hub-post, our deployment) — namespace `llm-d-system`
  Standalone Envoy (`envoy` Deployment + Service)
       → EPP: model-affinity-filter on X-Gateway-Model-Name + scorers → x-gateway-destination-endpoint
       → hub-post [hubMode TRANSFORM]: match EPP destination → apikey-injection
       → HTTPS to selected Spoke MaaS

SPOKE (1/2/3) — namespace `llm-d-system`
  MaaS Gateway (auth)
       → HTTPRoute → Standalone Envoy (`envoy` in `llm-d-system`)
       → Spoke EPP (placeholder, uncomment ext_proc when ready)
       → vLLM pod
```

**Tenant PP:** standard chain only. One destination (Hub), so weight-based resolve with a single ExternalModel is fine — there is nothing for EPP to choose. Do **not** enable `hubMode` on Tenant. Stock RHOAI PP is enough if resolver + apikey-injection work; otherwise use the hub-mode image with `hubMode: false`.

**Why the "unnecessary" MaaS PP plugins are harmless on GW1:** MaaS PP runs `model-provider-resolver` (non-hubMode) + `apikey-injection` before the request reaches GW2. The resolver may match an ExternalModel by path and inject a key. This is overwritten by hub-post on GW2 after EPP picks the actual Spoke. No functional impact — just redundant work.

---

## Current env snapshot (2026-08-05)

| Cluster | Status | Notes |
|---------|--------|-------|
| All 5 | EC2 running | Started for this work |
| Tenant | MaaS + PP + auth CRs | E2E validated: Alice → Tenant → Hub → EPP → Spoke (503 = vLLM Pending). `api-translation` removed from PP. |
| Hub | MaaS PP + Hub Envoy (EPP + static keys) | EPP picks spokes, Hub Envoy routes with static spoke API keys. hub-post blocked (Gap #9). |
| Spoke1 | A2 MaaS Ready + TinyLlama + Envoy GW | GW in `llm-d-system`; vLLM Pending (capacity); routed correctly (503) |
| Spoke2 | A2 MaaS Ready + TinyLlama + Envoy GW | GW in `llm-d-system`; vLLM Pending (capacity); routed correctly (503) |
| Spoke3 | A2 MaaS Ready + Qwen + Envoy GW | GW in `llm-d-system`; pre-existing 403 from MaaS auth; EPP placeholder |
| This dir | Lifecycle + NP + maas-spoke + maas-hub + deployments | `maas-spoke/`, `maas-hub/`, `deployments/` overlays applied |

---

## Parallel workstreams

Work is split so **Person A** and **Person B** can run in parallel. Sync points are marked.

```text
                    S0 Stabilize APIs / PP (either; quick)
                                    |
          +-------------------------+-------------------------+
          |                         |                         |
          v                         v                         v
   A: Spokes                 B: Hub EPP+PP              C: Tenant prep
   (fix Spoke1,            (hub-mode image,           (SAs, local
    MaaS, Spoke EPP)          hubMode filters, EPP)      manifests)
          |                         |                         |
          +-------------------------+-------------------------+
                                    |
                                    v
                     SYNC: spoke endpoints + Hub ExternalModels
                                    |
                                    v
                     D: Wire keys (Tenant <-> Hub <-> Spoke)
                                    |
                                    v
                     E: E2E tests (DEMO.md + PDF routing)
```

Suggested split:

| Person | Owns | Primary dirs to add |
|--------|------|---------------------|
| **A** | All spokes: Spoke1 fix, MaaS, Spoke EPP, path rewrite, routes | `deployments/spoke-*`, `maas-spoke/` |
| **B** | Hub: hub-mode PP, Hub EPP, Hub MaaS model CRs, filter order | `deployments/hub-*`, `maas-hub/`, PP values |
| **Either / together** | Tenant wiring + E2E (needs Hub+Spoke endpoints/keys) | `maas-tenant/`, `DEMO-downstream.md` |

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
- [ ] Deploy Spoke EPP (upstream `spoke-epp.yaml` pattern) — **on hold** (waiting for Sam’s EPP image)
- [ ] Path rewrite after MaaS: strip `/models-as-a-service/[^/]+/` before EPP/vLLM
- [ ] Metrics route + mTLS so Hub EPP can scrape `metricsAddress` (same as upstream)
- [ ] Smoke: request via Spoke MaaS key → MaaS → EPP → vLLM

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

- [ ] Confirm both FQDNs per spoke (from A2 + A3)
- [ ] Give table + Spoke API key Secret names to Person B
- [ ] B puts them in Hub `cluster-endpoints` and ExternalModel `endpoint` (= `address`, must match exactly)

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
- [ ] Tenant: leave full MaaS PP as-is (standard hop to Hub)

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
- [ ] Hub EPP ext_proc on GW2 **before** hub-post (**B3, on hold**)
- [ ] file-discovery entries labeled with `model:` (A4)
- [ ] Spoke choice is EPP (header + labels + scorers), not IPP weights

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

- [ ] End-to-end secret matrix documented (no keys in git; use local sealed files or cluster-only Secrets)
- [ ] Hub EPP endpoints file matches live Spoke routes
- [ ] Hub ExternalModels match EPP endpoint hostnames (port-strip matching — covered by hubMode TRANSFORM)
- [ ] Fix any DS↔EPP contract gaps (metadata namespace/key, header names, provider enum)

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

## Gaps to fix once EPP is deployed

These are temporary workarounds in the current E2E flow that must be replaced with proper solutions once Hub EPP and Spoke EPP are operational.

### 1. Hub Envoy: static Spoke API key injection (`request_headers_to_add`)

**Current:** Hub Envoy route config injects Spoke API keys statically per-route via `request_headers_to_add`.  
**Why:** `hub-post` runs in `hubMode: TRANSFORM` which only works AFTER EPP sets `x-gateway-destination-endpoint`. Without EPP, hub-post passes through without injecting credentials.  
**Proper fix:** Once Hub EPP is deployed and sets the destination header, hub-post (TRANSFORM mode) will dynamically inject the correct Spoke key by matching the EPP-selected endpoint to an ExternalModel/ExternalProvider. Remove ALL `request_headers_to_add: Authorization` entries from Hub Envoy config.

### 2. Hub Envoy: path-based Spoke routing (fallback routes)

**Current:** Without EPP, Hub Envoy uses `prefix: "/models-as-a-service/spoke1-tinyllama/"` routes to select Spokes.  
**Why:** EPP normally sets `x-gateway-destination-endpoint` header, and the header-based routes (already configured) take priority. Without EPP, no header is set.  
**Proper fix:** Once Hub EPP is deployed, header-based routes handle all traffic. Remove path-based fallback routes (or keep as a 503 safety net).

### 3. Hub Envoy: `spoke1` cluster pointing to Spoke2 — FIXED

**Fixed (2026-08-05):** Reverted to `maas.apps.aigrid-ds-spoke1.aigriddev.sysdeseng.com`. Also updated all Spoke API keys to correct values (`spoke1: sk-oai-D09k...`, `spoke2: sk-oai-1WdS...`, `spoke3: sk-oai-d4Aq...`).

### 4. Tenant PP: `api-translation` plugin removed from deployment

**Current:** Patched `payload-processing` Deployment to remove `--plugin $(API_TRANSLATION)`.  
**Why:** `api-translation` rewrites `:path` to `/v1/chat/completions` which runs BEFORE the router filter, breaking HTTPRoute matching. `maas-controller` may revert this patch.  
**Proper fix (options):**
  - **(a)** Deploy a separate custom IPP instance for the Tenant (not managed by maas-controller) with only the needed plugins (`body-field-to-header` + `model-provider-resolver` + `apikey-injection`). Our EnvoyFilter points to this instance.
  - **(b)** Fix `maas-controller` to support per-tenant plugin customization (ConfigMap toggle or CRD field).
  - **(c)** Fix `api-translation` plugin to NOT rewrite `:path` when running pre-route (add a "pre-route" mode that only translates the body, not the path).

### 5. Tenant PP: corrected EnvoyFilter (`payload-processing-fix`) — RHOAIENG-76228

**Current:** Created a separate EnvoyFilter `payload-processing-fix` with the correct `subFilter: envoy.filters.http.wasm` anchor and `priority: 10`. The maas-controller's original `payload-processing` EnvoyFilter remains but is harmless (its anchor never matches).

**Root cause:** This is a **known Red Hat bug** ([RHOAIENG-76228](https://redhat.atlassian.net/browse/RHOAIENG-76228)). RHOAI 3.4.2 ships MaaS v0.1.1 which was built for RHCL 1.3 (uses WasmPlugin CRs → filter named `extensions.istio.io/wasmplugin/...`). However, RHCL 1.3 is **no longer available** in the OLM catalog — only RHCL 1.4.2 is offered in the `stable` channel. RHCL 1.4 deploys auth via EnvoyFilter (no WasmPlugin CR), naming it `envoy.filters.http.wasm`. The maas-controller's `subFilter` match never fires, so ext_proc is never inserted.

**Fix status:**
  - Fix merged to `main` on 2026-07-10: [PR #1146](https://github.com/opendatahub-io/models-as-a-service/pull/1146) (dual-anchor approach: 4 configPatches covering both WasmPlugin and RHCL 1.4 naming).
  - Will ship in **RHOAI 3.5** (MaaS v0.2.1). Currently only available as EA (`3.5.0-ea.2` on `beta` channel).
  - RHCL downgrade to 1.3 is not possible (removed from catalog).
  - The env var approach (PR #1144) is also not in the deployed binary.

**Our workaround is stable:** The custom `payload-processing-fix` EnvoyFilter is safe because:
  - `maas-controller` only reconciles its own EF by name (`payload-processing`) — it never touches ours.
  - The controller's original EF is inert (wrong anchor = no match = no effect).
  - Both coexist without conflict.

**Resolution:** Upgrade to RHOAI 3.5 when GA. The controller will then generate the correct dual-anchor EF natively, and `payload-processing-fix` can be removed.

### 6. Credential Secret: manual label `inference.networking.k8s.io/bbr-managed`

**Current:** Manually added label to `hub-gateway-credentials` Secret so the PP's `apikey-injection` plugin discovers it (label-filtered informer).  
**Why:** The `maas-controller` creates ExternalModels and credential Secrets but does NOT add the required label for the PP's Secret informer.  
**Proper fix:** Fix `maas-controller` to add `inference.networking.k8s.io/bbr-managed: "true"` to any Secret referenced by `credentialRef` in ExternalModels. File a bug upstream.

### 7. Spoke Envoy: path rewrite (strip MaaS prefix)

**Current:** Spoke Envoy has `regex_rewrite` to strip `/models-as-a-service/[model-name]/` before forwarding to vLLM.  
**Why:** MaaS routes include the namespace/model prefix; vLLM only understands `/v1/...` paths.  
**Proper fix:** Once Spoke EPP is deployed, it should handle path normalization (or this stays as a permanent Envoy config — it's not a workaround, it's correct behavior for any Spoke sitting between MaaS and vLLM).

### 8. Hub EPP ext_proc: `processing_mode` must be `FULL_DUPLEX_STREAMED`

**Root cause found (2026-08-05):** The Hub Envoy ext_proc filter was initially configured with `request_body_mode: BUFFERED` (and later `NONE`), which caused an ext_proc protocol deadlock:
  - With `BUFFERED`: Envoy waits for EPP's HeadersResponse before sending body. EPP waits for body before responding to headers → **deadlock**.
  - With `NONE`: Envoy never sends body, EPP cannot extract model name → hangs or falls back incorrectly.

**Correct configuration:** ALL standard llm-d-router deployment manifests use `FULL_DUPLEX_STREAMED`:
```yaml
processing_mode:
  request_header_mode: SEND
  response_header_mode: SEND
  request_body_mode: FULL_DUPLEX_STREAMED
  response_body_mode: FULL_DUPLEX_STREAMED
  request_trailer_mode: SEND
  response_trailer_mode: SEND
message_timeout: 1000s
```
With `FULL_DUPLEX_STREAMED`, Envoy sends headers AND body to EPP without waiting for intermediate responses.

**Status:** Fixed. Hub EPP is now correctly receiving requests, selecting endpoints, and setting `x-gateway-destination-endpoint`. Verified rotation across spoke1/spoke2/spoke3.

### 9. Hub-post: `hubMode: true` doesn't implement endpoint-based resolution

**Current:** The hub-post image (`ghcr.io/yehuditkerido/ai-gateway-payload-processing:hub-mode`, build `pr-416`) is deployed with `hubMode: true` parameter. However, the `model-provider-resolver` plugin in this image still resolves by model NAME (from request body or `x-gateway-model-name` header), not by endpoint from `x-gateway-destination-endpoint` header.

**Impact:** Hub-post cannot dynamically select which Spoke's credentials to inject based on EPP's routing decision. Static API key injection in Envoy routes is used instead (Gap #1).

**Proper fix:** The `model-provider-resolver` plugin needs a TRANSFORM mode that:
1. Reads `x-gateway-destination-endpoint` header (set by EPP)
2. Matches endpoint to ExternalProvider's `spec.endpoint` field
3. Retrieves credentials from the matched provider's `auth.secretRef`
4. Passes to `apikey-injection` for header injection

**Workaround (current):** Static `request_headers_to_add: Authorization` in Hub Envoy routes per-spoke. Functionally correct for the demo.

### 10. Pre-existing cluster issues

| Cluster | Issue | Fix needed |
|---------|-------|-----------|
| Spoke1 | vLLM pods Pending (GPU capacity) | Free GPU resources or scale node group |
| Spoke3 | MaaS auth 403 PERMISSION_DENIED | Authorino OPA `require-group-membership` failing; investigate AuthConfig |

---

## Gap risks (watch list)

| Risk | Why | Mitigation |
|------|-----|------------|
| IPP still weight-picks | Default DS resolver behavior | `hubMode: true` + verify no CycleState in PROPOSE |
| Filter order wrong | Default chart inserts IPP before EPP | hub-pre / hub-post EnvoyFilters (PR #416) |
| MaaS ExternalModel vs upstream ExternalProvider | Different CRDs/API | Use MaaS ExternalModel only; map fields for resolver |
| Hub PP CrashLoop | API unreachable after hibernate | S0; restart after API Ready |
| Spoke1 unschedulable | CPU/mem requests | A1 |
| EPP subset metadata mismatch | Wrong namespace/key | Align with EPP `candidates.go` + PR #412 |
| Image pull from GHCR | Private/package perms | Pull secret on deploy SA |
| PRs need-rebase | Upstream moving | Demo uses prebuilt `hub-mode` image; rebase later |
| maas-controller reverts PP patch | Controller reconciles deployment args | Gap #4: deploy separate IPP or fix controller |
| Kuadrant wasm mismatch | EnvoyFilter vs WasmPlugin naming | Gap #5: upgrade Kuadrant or patch controller |
| Secret label missing after recreate | maas-controller doesn't add bbr-managed label | Gap #6: patch controller or add to Helm values |

---

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
│   ├── hub-epp.yaml            # Hub EPP (on hold)
│   ├── spoke-epp.yaml          # Spoke EPP (on hold)
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

## Suggested day-one assignment

| Person A | Person B |
|----------|----------|
| S0 together (15 min) | S0 together (15 min) |
| A1 Spoke1 vLLM fix | B1 PP image → hub-mode on Hub (and Tenant if needed) |
| A2 MaaS on Spoke2 (healthy baseline) then Spoke3 | B2 hub-pre/hub-post EnvoyFilter + hubMode config |
| A2 MaaS on Spoke1 after A1 | B3 Hub EPP deploy (endpoints stubbed) |
| A3 Spoke EPP + rewrite on all spokes | B4 Hub ExternalModel drafts |
| A4 Fill spoke address table | Update Hub endpoints from A's table |
| Join D + E | Join D + E |

---

## Open items before execute

1. Confirm EPP image tag if not `ghcr.io/yehuditkerido/llm-d-router-endpoint-picker:multi-cluster-test`.
2. Confirm DS provider string for remote MaaS ExternalModel (`remote-maas` vs `openai` + endpoint) against hub-mode resolver code in the `hub-mode` image.
3. Assign Person A / Person B names on the table above.

When this plan looks good, we start with **S0 + A1 + B1** in parallel.
