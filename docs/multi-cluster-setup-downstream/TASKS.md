# Downstream AI Grid — Parallel Task Board

Full context: [PLAN.md](PLAN.md). Check boxes as you go. Sync before starting D.

**Person A:** _______________  
**Person B:** _______________

---

## S0 — Stabilize (together, first)

- [x] All 5 clusters: `oc get nodes` Ready
- [x] Tenant PP Running
- [x] Hub PP Running (stock image OK for S0)
- [x] Decide PP image override method (document in PLAN)
- [x] Applied `deployments/payload-processing-networkpolicy.yaml` on Hub + Tenant (deny-all was blocking API egress)

---

## Person A — Spokes

### A1 Spoke1 vLLM
- [x] Diff Spoke1 vs Spoke2 vLLM resources
- [x] Spoke1 `vllm-tinyllama` 2/2 Ready
- [x] Health checks pass (`/health` → 200 on both pods)
- Note: Spoke1 GPU workers packed; patched requests to `cpu: 1`, `memory: 6Gi` (Spoke2 stays `2`/`8Gi`). Scaled LWS/kube-auth-proxy temporarily; operator may reconcile them back.

### A2 MaaS on spokes
- [x] Spoke2 MaaS + model + Hub consumer key (smoke 200 via MaaS→vLLM; key in `hub-consumer-maas-api-key`)
- [x] Spoke3 MaaS + model + Hub consumer key (Qwen smoke 200; vLLM replicas=1)
- [x] Spoke1 MaaS + model + Hub consumer key (TinyLlama smoke 200)
- [x] Authorino TLS on all spokes (`AUTHORINO_NAMESPACE=rh-connectivity-link`) + HTTPRoute URLRewrite
- [x] Smoke Spoke1/2/3: curl MaaS with Spoke API key → 200
- [x] Rate-limit proof on Spoke2 (limit 30/1m → 200×2 then 429; restored 100000)

### A3 Spoke EPP + path rewrite + mTLS metrics
- [ ] Spoke EPP on spoke1/2/3
- [ ] Path rewrite after MaaS prefix
- [ ] mTLS metrics route (`metricsAddress` for Hub file-discovery)
- [ ] Smoke: Spoke MaaS (API key) → EPP → vLLM

### A4 Hand off to Hub (file-discovery only — no new Routes)
- [ ] Confirm PLAN A4 table: `address`=MaaS (API key), `metricsAddress`=metrics (mTLS)
- [ ] Share Spoke API key Secret names with Person B
- [ ] B fills Hub `cluster-endpoints` + ExternalModel `endpoint` = same MaaS `address`

---

## Person B — Hub

### B1 Hub PP (reuse MaaS PRE; add hub-post only)
- [ ] Inventory MaaS `payload-processing` + plugins CM + EnvoyFilter
- [ ] Narrow Hub MaaS PP to body-field-to-header only (no resolver/apikey in PRE)
- [ ] Deploy hub-post (`hub-mode` image) after EPP
- [ ] Confirm chain: Auth → MaaS PP → EPP → hub-post (no duplicate PRE)
- [ ] Tenant keeps full MaaS PP unchanged

### B2 Filter chain (IPP header → EPP model-affinity → hub-post)
- [ ] PRE = MaaS body→header only
- [ ] hub-post = hubMode TRANSFORM + apikey after EPP
- [ ] Order: Auth → PRE → EPP → hub-post
- [ ] EPP model-affinity-filter on `x-gateway-model-name` (PR #3)

### B3 Hub EPP
- [ ] Deploy Hub EPP with file-discovery from A4 + `labels.model`
- [ ] model-affinity-filter in scheduling profile
- [ ] EPP between pre and post IPP

### B4 Hub MaaS CRs
- [ ] Tenant SA + subscriptions/auth on Hub
- [ ] ExternalModels for spokes — endpoint = Spoke **MaaS** FQDN (same as file-discovery address)
- [ ] Credential Secrets for Spoke keys
- [ ] ModelRefs for Tenant-facing models

---

## Person A or B — Tenant (C)

### C1 (parallel-safe anytime)
- [ ] SAs: alice, charlie, team-alpha
- [ ] Manifest scaffolding under `maas-tenant/`

### C2 (after Hub keys exist)
- [ ] Tenant→Hub API key Secret
- [ ] Tenant PP standard only (resolver + apikey → single Hub ExternalModel; no hubMode/EPP)
- [ ] Subscriptions/limits per DEMO.md
- [ ] DestinationRule/TLS to Hub if needed

---

## Together — D Glue + E Tests

### D
- [ ] Secret matrix (cluster-only; not committed)
- [ ] Hub EPP endpoints == live Spoke FQDNs
- [ ] ExternalModel hostnames match EPP destinations
- [ ] Fix DS↔EPP gaps if found

### E (see PLAN test table)
- [ ] Tests 1–8 (DEMO.md rate limit + authz)
- [ ] Tests 9–10 (model affinity + load split)
- [ ] Tests 11–12 (credentials + hubMode proof)
- [ ] Write `DEMO.md` in this directory with ds hostnames

---

## Manifests created (track here)

| Path | Owner | Status |
|------|-------|--------|
| `deployments/payload-processing-networkpolicy.yaml` | S0 | applied on hub+tenant |
| `deployments/spoke-epp.yaml` | A | |
| `deployments/spoke-path-rewrite.yaml` | A | notes + URLRewrite procedure (Spoke2 applied) |
| `maas-spoke/` | A | overlays tinyllama/qwen; Spoke2 applied |
| `deployments/hub-epp.yaml` | B | |
| `pp-hub/values-hub-pre.yaml` | B | |
| `pp-hub/values-hub-post.yaml` | B | |
| `maas-hub/` | B | |
| `maas-tenant/` | A/B | |
| `DEMO.md` | A/B | |
