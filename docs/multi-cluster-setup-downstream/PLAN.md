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

1. **Hub topology = downstream hub-mode on MaaS gateway**, not upstream's dual standalone IPP pods.
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

## Target architecture (downstream)

```
TENANT
  User → MaaS Gateway (auth + rate limit)
       → PP (standard, NOT hubMode): body→header + resolver + apikey → Hub key
       → HTTPS to Hub MaaS
       (single ExternalModel → Hub only; no candidates / no EPP)

HUB
  MaaS Gateway (auth + rate limit)
       → Auth (Authorino)   # MaaS default EnvoyFilter is INSERT_AFTER kuadrant today
       → MaaS PP (PRE): body→header only → X-Gateway-Model-Name
       → EPP: model-affinity-filter on that header + scorers → x-gateway-destination-endpoint
       → IPP-Post [hubMode TRANSFORM]: match destination → apikey + host/path
       → HTTPS to selected Spoke MaaS

SPOKE (1/2/3)
  MaaS Gateway (auth)
       → path rewrite (strip /models-as-a-service/<model>/)
       → Spoke EPP → vLLM pod
```

**Tenant PP:** standard chain only. One destination (Hub), so weight-based resolve with a single ExternalModel is fine — there is nothing for EPP to choose. Do **not** enable `hubMode` on Tenant. Stock RHOAI PP is enough if resolver + apikey-injection work; otherwise use the hub-mode image with `hubMode: false`.

**Critical (Hub only):** filter order must be  
`IPP-Pre → Auth → EPP → IPP-Post`  
(not the default `IPP-Post` before EPP). That is what PR #416 / hub-pre + hub-post values provide.

---

## Current env snapshot (2026-08-03)

| Cluster | Status | Notes |
|---------|--------|-------|
| All 5 | EC2 running | Started for this work |
| Tenant | MaaS + stock PP | Only default Tenant CR; no model/auth CRs |
| Hub | MaaS + stock PP | PP stabilized (NetworkPolicy); no EPP; no hubMode yet |
| Spoke1 | A2 MaaS Ready + TinyLlama | Tenant Ready, key, URLRewrite, smoke 200; no Spoke EPP yet |
| Spoke2 | A2 MaaS Ready + TinyLlama | Same as Spoke1; baseline for capacity pins |
| Spoke3 | A2 MaaS Ready + Qwen | Same pattern; vLLM kept at 1 replica (2 GPUs); smoke 200 |
| This dir | Lifecycle + NP + maas-spoke | `maas-spoke/` overlays applied on all three spokes |

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

- [ ] Deploy Spoke EPP (upstream `spoke-epp.yaml` pattern)
- [ ] Path rewrite after MaaS: strip `/models-as-a-service/[^/]+/` before EPP/vLLM
- [ ] Metrics route + mTLS so Hub EPP can scrape `metricsAddress` (same as upstream)
- [ ] Smoke: request via Spoke MaaS key → MaaS → EPP → vLLM

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

### B1. Hub PP: reuse MaaS PP for PRE; add hub-post only

Hub already has **MaaS-managed** stock `payload-processing` (Deployment + EnvoyFilter, `INSERT_AFTER` kuadrant). For PRE we only need `body-field-to-header` → `X-Gateway-Model-Name` — that plugin is already in the MaaS ConfigMap. Prefer **keeping** that Deployment/EnvoyFilter as PRE instead of disabling MaaS IPP and installing a second pre.

Today the MaaS PP chain also runs `model-provider-resolver` + `apikey-injection` **without** hubMode (weight-pick before EPP). That must not stay in PRE.

**Preferred (downstream demo):**

1. Reuse MaaS PP as PRE: plugins = **`body-field-to-header` only** (drop resolver / api-translation / apikey from the Hub PP args/ConfigMap for this demo).
2. Keep its EnvoyFilter (after auth is fine: Auth → PRE → EPP → POST).
3. Deploy **only hub-post** with `ghcr.io/yehuditkerido/ai-gateway-payload-processing:hub-mode` (`hubMode` TRANSFORM + apikey), EnvoyFilter `INSERT_AFTER` EPP.
4. Watch that `maas-controller` does not reconcile the plugin list back; if it does, pin/workaround or revisit.

- [ ] Inventory Hub MaaS PP Deployment + EnvoyFilter + `payload-processing-plugins` CM
- [ ] Narrow Hub MaaS PP to body-field-to-header only
- [ ] Deploy hub-post (hub-mode image) after EPP — not a second full MaaS PP
- [ ] Confirm gateway chain: Auth → MaaS PP (header) → EPP → hub-post (no duplicate PRE)
- [ ] Tenant: leave full MaaS PP as-is (standard hop to Hub)

**Exit:** One PRE (MaaS, header only), one EPP, one hub-post; no weight-pick before EPP.

### B2. Filter chain: IPP header → EPP nominates → IPP-post transforms

Model nomination is **EPP’s job**, via [`model-affinity-filter`](https://github.com/yehuditkerido/llm-d-router/pull/3): reads `x-gateway-model-name` from IPP, matches file-discovery `labels.model`.

| Piece | Role |
|-------|------|
| **Auth** | Authorino (existing) |
| **MaaS PP (PRE)** | `body-field-to-header` only → `X-Gateway-Model-Name` |
| **EPP** | `model-affinity-filter` on that header + scorers → `x-gateway-destination-endpoint` |
| **hub-post** | hubMode TRANSFORM: match EPP destination → CycleState → `apikey-injection` |

- [ ] Order: Auth → PRE → EPP → hub-post
- [ ] Hub EPP: `model-affinity-filter` (`modelHeader: x-gateway-model-name`, `labelKey: model`)
- [ ] file-discovery entries labeled with `model:` (A4)
- [ ] Spoke choice is EPP (header + labels + scorers), not IPP weights

**Note:** Full hub-mode PROPOSE (`subset_hint`) is optional here if model-affinity + labeled file-discovery already nominates correctly. hub-post still needs hubMode TRANSFORM so credentials follow EPP’s pick.

### B3. Hub EPP (same as upstream live config)

- [ ] Deploy Hub EPP image that includes model-affinity-filter (fork/`multi-cluster-test` / whatever ships PR #3)
- [ ] **file-discovery** from A4 (`address` = Spoke MaaS, `metricsAddress` = metrics, `labels.model` set)
- [ ] Scheduling profile: model-affinity-filter then scorers
- [ ] `spoke-epp` engine / pool-average metrics if required
- [ ] Attach EPP ext_proc **between** hub-pre and hub-post

**Exit:** EPP logs show model-affinity filtering (e.g. TinyLlama → spoke1/2 only); destination header is Spoke MaaS host:443.

### B4. Hub MaaS / ExternalModel plane (MaaS → MaaS)

- [ ] Hub consumer identities (Tenant SA + Spoke consumer SAs as needed)
- [ ] ExternalModel (or DS provider refs) per spoke: **`endpoint` = same MaaS FQDN as file-discovery `address`**; `credentialRef` → Spoke API key Secret
- [ ] TinyLlama aggregates spoke1+spoke2; Qwen → spoke3
- [ ] hubMode: weights only mark eligibility for TRANSFORM matching; EPP chooses
- [ ] `MaaSModelRef` / subscription / auth policy for Tenant→Hub model names
- [ ] ReferenceGrant / HTTPRoute overrides only if still required after PP path rewrite

**SYNC:** needs Workstream A spoke FQDNs + API key Secret values (or sealed placeholders).

---

## Workstream C — Tenant (can start in parallel; finish after Hub keys)

### C1. Manifests / identities (parallel-safe)

- [ ] User/team SAs (alice, charlie, team-alpha) — same as DEMO.md
- [ ] Dummy/local ExternalModel scaffolding pointing at Hub FQDN
- [ ] DestinationRule / TLS to Hub MaaS if needed

### C2. Wire after Hub is ready

- [ ] Generate Tenant→Hub API key on Hub; store in Tenant Secret for PP `apikey-injection`
- [ ] Tenant PP = **standard only** (no hubMode, no EPP): body→header + resolver + apikey → single Hub ExternalModel
- [ ] Subscriptions + auth policies per DEMO.md (alice TinyLlama 50/min, charlie Qwen 50/min, team-alpha 200/min, Hub tenant 500/min)
- [ ] Prefer stock RHOAI PP on Tenant; only swap image if resolver/apikey are broken on stock

**Exit:** Tenant `curl` with alice key reaches Hub (Hub may 502 until EPP/Spokes wired — still progress).

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

---

## Directory layout to create

```text
docs/multi-cluster-setup-downstream/
├── PLAN.md                 ← this file
├── CLUSTERS.md
├── README.md
├── DEMO.md                 ← to write (from upstream DEMO + routing tests)
├── deployments/
│   ├── hub-epp.yaml
│   ├── spoke-epp.yaml
│   ├── spoke-path-rewrite.yaml   # or EnvoyFilter
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
