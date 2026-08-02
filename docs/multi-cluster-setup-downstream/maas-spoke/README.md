# Spoke MaaS Setup (Downstream)

MaaS resources for Spoke clusters so Hub can authenticate and call Spoke models.

## Prerequisites

Install the MaaS platform on each spoke (same path as Hub/Tenant):

```bash
cd ~/Projects/models-as-a-service/scripts
export KUBECONFIG=~/Projects/llm-d-inference-scheduler/docs/multi-cluster-setup-downstream/spoke2/auth/kubeconfig
./deploy.sh --operator-type rhoai --verbose
```

Repeat for `spoke3` and `spoke1`. Spoke1 may already have `rhods-operator` + DSCI; the script should create DSC with `modelsAsService`.

## Apply model CRs

```bash
BASE=~/Projects/llm-d-inference-scheduler/docs/multi-cluster-setup-downstream

# Spoke1 / Spoke2 (TinyLlama)
KUBECONFIG=$BASE/spoke1/auth/kubeconfig kubectl apply -k $BASE/maas-spoke/overlays/tinyllama
KUBECONFIG=$BASE/spoke2/auth/kubeconfig kubectl apply -k $BASE/maas-spoke/overlays/tinyllama

# Spoke3 (Qwen)
KUBECONFIG=$BASE/spoke3/auth/kubeconfig kubectl apply -k $BASE/maas-spoke/overlays/qwen
```

A2 ExternalModels point at vLLM ClusterIP (`port: 8000`, `tls: false`). A3 switches them to Spoke Envoy/EPP.

After ExternalModel is Ready, add HTTPRoute URLRewrite (see `deployments/spoke-path-rewrite.yaml`).

## Hub consumer API key

```bash
TOKEN=$(oc create token hub-consumer-sa -n hub-consumers --duration=1h)
curl -sk "https://maas.apps.aigrid-ds-spoke2.aigriddev.sysdeseng.com/maas-api/v1/api-keys" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"hub-consumer-key","expiration":"2027-08-01T00:00:00Z"}'
```

Store the returned `key` on Hub as Secrets for ExternalModel `credentialRef` (Person B / A4).
On Spoke2 it is also kept as Secret `models-as-a-service/hub-consumer-maas-api-key`.

Requires `MaaSSubscription` `hub-consumer-subscription` (included in base).

## Smoke

```bash
KEY=$(oc get secret hub-consumer-maas-api-key -n models-as-a-service -o jsonpath='{.data.api-key}' | base64 -d)
curl -sk "https://maas.apps.aigrid-ds-spoke2.aigriddev.sysdeseng.com/models-as-a-service/spoke-inference-model/v1/completions" \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"TinyLlama/TinyLlama-1.1B-Chat-v1.0","prompt":"Hello","max_tokens":8}'
```

## Capacity notes (g4dn.xlarge spokes)

GPU workers are tight after RHOAI/MaaS. Typical POC pins:

- `rhods-operator` replicas=1 + tolerate `node-role.kubernetes.io/master`
- `lws-controller-manager` replicas=0 (operator may fight)
- `kube-auth-proxy` / `data-science-gateway` scaled down
- vLLM requests lowered (e.g. `500m` / `4Gi`) so both replicas schedule

Authorino TLS: `AUTHORINO_NAMESPACE=rh-connectivity-link ./scripts/setup-authorino-tls.sh`