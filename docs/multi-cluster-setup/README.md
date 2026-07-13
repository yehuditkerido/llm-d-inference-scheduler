# Multi-Cluster Test Environment Setup

This directory contains configuration and scripts for setting up a Hub-and-Spoke
multi-cluster environment on AWS using OpenShift.

## Architecture

```
                              ┌─────────────────────┐
                              │   Hub Cluster       │
                              │   (aigrid-hub)      │
                              │   us-east-1         │
                              │   No GPUs - routing │
                              └──────────┬──────────┘
                                         │
              ┌──────────────────────────┼──────────────────────────┐
              │                          │                          │
              ▼                          ▼                          ▼
┌─────────────────────┐    ┌─────────────────────┐    ┌─────────────────────┐
│   Spoke Cluster 1   │    │   Spoke Cluster 2   │    │   Spoke Cluster 3   │
│   (aigrid-tenant1)  │    │   (aigrid-tenant2)  │    │   (aigrid-tenant3)  │
│   us-east-2         │    │   us-west-2         │    │   eu-west-1         │
│   2x g4dn.xlarge    │    │   2x g4dn.xlarge    │    │   2x g4dn.xlarge    │
│   (NVIDIA T4 GPUs)  │    │   (NVIDIA T4 GPUs)  │    │   (NVIDIA T4 GPUs)  │
└─────────────────────┘    └─────────────────────┘    └─────────────────────┘
```

## Prerequisites

1. **AWS Credentials** - Place in `~/.aws/credentials`:
   ```ini
   [default]
   aws_access_key_id = <Your_Access_Key>
   aws_secret_access_key = <Your_Secret_Access_Key>
   ```

2. **OpenShift Installer** - Download from mirror.redhat.com:
   ```bash
   curl -LO https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-install-linux.tar.gz
   tar -xzf openshift-install-linux.tar.gz
   sudo mv openshift-install /usr/local/bin/
   ```

3. **Red Hat Pull Secret** - Get from https://console.redhat.com/openshift/downloads

4. **SSH Key** - Generate if you don't have one:
   ```bash
   ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""
   ```

## Quick Start

1. Edit the install configs in each cluster directory:
   - Replace `<YOUR_PULL_SECRET_HERE>` with your pull secret
   - Replace `<YOUR_SSH_PUBLIC_KEY_HERE>` with your SSH public key

2. Create clusters:
   ```bash
   # Create Hub (takes ~30-45 minutes)
   cd hub
   openshift-install create cluster --dir=. --log-level=info

   # Create Spoke 1 (takes ~30-45 minutes)
   cd ../spoke-tenant1
   openshift-install create cluster --dir=. --log-level=info

   # Create Spoke 2 (optional, takes ~30-45 minutes)
   cd ../spoke-tenant2
   openshift-install create cluster --dir=. --log-level=info

   # Create Spoke 3 (optional, takes ~30-45 minutes)
   cd ../spoke-tenant3
   openshift-install create cluster --dir=. --log-level=info
   ```

3. Access clusters:
   ```bash
   # Hub
   export KUBECONFIG=~/Projects/llm-d-inference-scheduler/docs/multi-cluster-setup/hub/auth/kubeconfig
   oc get nodes

   # Spoke 1
   export KUBECONFIG=~/Projects/llm-d-inference-scheduler/docs/multi-cluster-setup/spoke-tenant1/auth/kubeconfig
   oc get nodes
   ```

## IMPORTANT: Cost Management

These clusters cost money! **Shut them down when not using them:**

```bash
# Destroy clusters when done
cd hub && openshift-install destroy cluster --dir=.
cd ../spoke-tenant1 && openshift-install destroy cluster --dir=.
cd ../spoke-tenant2 && openshift-install destroy cluster --dir=.
```

Approximate costs (if left running 24/7):
- Hub: ~$300-400/month (3x c5a.4xlarge control plane)
- Each Spoke: ~$500-700/month (3x control plane + 2x g4dn.xlarge GPU workers)

## Cluster Details

| Cluster | Region | Workers | Instance Type | Purpose |
|---------|--------|---------|---------------|---------|
| aigrid-hub | us-east-1 | 0 | c5a.4xlarge (control) | Hub EPP routing |
| aigrid-tenant1 | us-east-2 | 2 | g4dn.xlarge (GPU) | Inference workloads |
| aigrid-tenant2 | us-west-2 | 2 | g4dn.xlarge (GPU) | Inference workloads |
| aigrid-tenant3 | eu-west-1 | 2 | g4dn.xlarge (GPU) | Inference workloads |

## DNS

The DNS zone `aigriddev.sysdeseng.com` is pre-configured. The installer
automatically creates DNS records for:
- `api.<cluster-name>.aigriddev.sysdeseng.com`
- `*.apps.<cluster-name>.aigriddev.sysdeseng.com`

## Next Steps After Cluster Creation

1. Install llm-d components on each cluster
2. Configure mTLS between clusters
3. Set up the Hub EPP with file-discovery pointing to spoke gateways
4. Deploy test models on spoke clusters
5. Test multi-cluster routing
