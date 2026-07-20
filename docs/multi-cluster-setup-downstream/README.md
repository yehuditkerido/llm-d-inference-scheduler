# Multi-Cluster Setup - Downstream Environment

This directory contains configuration for testing with **downstream** IPP (ai-gateway-payload-processing) in a hub-and-spoke multi-cluster setup.

## Cluster Layout

| Cluster | Name | Region | Workers | Purpose |
|---------|------|--------|---------|---------|
| Hub | aigrid-ds-hub | us-east-1 | 0 (control plane only) | Central routing hub |
| Spoke 1 | aigrid-ds-spoke1 | us-east-2 | 2 GPU (g4dn.xlarge) | Model serving |
| Spoke 2 | aigrid-ds-spoke2 | us-west-2 | 2 GPU (g4dn.xlarge) | Model serving |
| Spoke 3 | aigrid-ds-spoke3 | eu-west-1 | 2 GPU (g4dn.xlarge) | Model serving |
| Tenant | aigrid-ds-tenant | us-east-1 | 0 (control plane only) | Consumer entry point |

## Quick Start

### 1. Configure Secrets

Before creating clusters, update the `install-config.yaml.backup` files with your pull secret and SSH key:

```bash
# Get your pull secret from https://console.redhat.com/openshift/downloads
# Your SSH public key from ~/.ssh/id_rsa.pub

# For each cluster directory, replace placeholders:
for dir in hub spoke1 spoke2 spoke3 tenant; do
  # Edit ${dir}/install-config.yaml.backup
  # Replace <YOUR_PULL_SECRET_HERE> with your pull secret JSON
  # Replace <YOUR_SSH_PUBLIC_KEY_HERE> with your SSH public key
done
```

Or copy from the upstream setup (if using same credentials):
```bash
cp ../multi-cluster-setup/pull-secret.json .
```

### 2. Create Clusters

```bash
# Create a single cluster
./create-cluster.sh hub

# Create all clusters (takes ~45 min each)
./create-cluster.sh all
```

### 3. Manage Clusters

```bash
# Check status
./manage-clusters.sh status

# Stop all clusters (to save costs)
./manage-clusters.sh stop all -y

# Start specific cluster
./manage-clusters.sh start spoke1

# Start all clusters
./manage-clusters.sh start all -y
```

## Directory Structure

```
multi-cluster-setup-downstream/
├── hub/                    # Hub cluster config
│   ├── install-config.yaml.backup
│   ├── auth/              # Generated after creation
│   │   └── kubeconfig
│   └── metadata.json      # Generated after creation
├── spoke1/                # Spoke 1 cluster config
├── spoke2/                # Spoke 2 cluster config
├── spoke3/                # Spoke 3 cluster config
├── tenant/                # Tenant cluster config
├── create-cluster.sh      # Cluster creation script
├── manage-clusters.sh     # Start/stop/status script
└── README.md
```

## Differences from Upstream Environment

| Aspect | Upstream (`multi-cluster-setup/`) | Downstream (`multi-cluster-setup-downstream/`) |
|--------|-----------------------------------|-----------------------------------------------|
| Cluster prefix | `aigrid-` | `aigrid-ds-` |
| IPP Image | `llm-d-inference-payload-processor` | `ai-gateway-payload-processing` |
| IPP CRDs | `inference.llm-d.ai` ExternalModel/Provider | MaaS ExternalModel |
| Directory names | `spoke-tenant1`, `spoke-tenant2`, etc. | `spoke1`, `spoke2`, etc. |

## Kubeconfig Access

After cluster creation, kubeconfigs are at:
```bash
export KUBECONFIG_HUB=$PWD/hub/auth/kubeconfig
export KUBECONFIG_SPOKE1=$PWD/spoke1/auth/kubeconfig
export KUBECONFIG_SPOKE2=$PWD/spoke2/auth/kubeconfig
export KUBECONFIG_SPOKE3=$PWD/spoke3/auth/kubeconfig
export KUBECONFIG_TENANT=$PWD/tenant/auth/kubeconfig
```

## Console URLs

After creation:
- Hub: https://console-openshift-console.apps.aigrid-ds-hub.aigriddev.sysdeseng.com
- Spoke 1: https://console-openshift-console.apps.aigrid-ds-spoke1.aigriddev.sysdeseng.com
- Spoke 2: https://console-openshift-console.apps.aigrid-ds-spoke2.aigriddev.sysdeseng.com
- Spoke 3: https://console-openshift-console.apps.aigrid-ds-spoke3.aigriddev.sysdeseng.com
- Tenant: https://console-openshift-console.apps.aigrid-ds-tenant.aigriddev.sysdeseng.com
