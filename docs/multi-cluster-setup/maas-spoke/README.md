# Spoke MaaS Setup

MaaS resources for Spoke clusters that enable Hub-to-Spoke authentication.

## Architecture

```
Hub Cluster                           Spoke Cluster
+------------------+                  +---------------------+
| Hub EPP          |   SA Token       | Spoke MaaS          |
| (routes to       | ---------------> | (validates Hub is   |
|  spokes)         |                  |  authorized)        |
+------------------+                  +---------------------+
                                              |
                                              v
                                      +---------------------+
                                      | vLLM Pods           |
                                      | (serve inference)   |
                                      +---------------------+
```

## Files

| File | Purpose |
|------|---------|
| `hub-consumer-sa.yaml` | ServiceAccount for Hub to authenticate as |
| `maas-auth-policy.yaml` | Policy allowing Hub SA to access models |

## Deployment

Apply to each Spoke cluster:
```bash
# Spoke 1
export KUBECONFIG=~/Projects/llm-d-inference-scheduler/docs/multi-cluster-setup/spoke-tenant1/auth/kubeconfig
kubectl apply -k .

# Spoke 2
export KUBECONFIG=~/Projects/llm-d-inference-scheduler/docs/multi-cluster-setup/spoke-tenant2/auth/kubeconfig
kubectl apply -k .

# Spoke 3
export KUBECONFIG=~/Projects/llm-d-inference-scheduler/docs/multi-cluster-setup/spoke-tenant3/auth/kubeconfig
kubectl apply -k .
```

## Generating Hub Token

After applying the manifests, generate a token for Hub to use:
```bash
# On each spoke
oc create token hub-consumer-sa -n hub-consumers --duration=24h
```

This token should be stored in a Secret on the Hub cluster and used in
the Hub's ExternalModel `credentialRef` when calling the Spoke.
