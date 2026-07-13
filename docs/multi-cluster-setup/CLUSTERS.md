# Multi-Cluster Environment Details

This document contains all access information and details for the Hub-and-Spoke test environment.

## Architecture Overview

```
                         ┌─────────────────────────────┐
                         │       Hub Cluster           │
                         │       (aigrid-hub)          │
                         │       us-east-1             │
                         │                             │
                         │  ┌─────────────────────┐    │
                         │  │     Hub EPP         │    │
                         │  │  (routes requests)  │    │
                         │  └─────────────────────┘    │
                         └─────────────┬───────────────┘
                                       │
                    ┌──────────────────┴──────────────────┐
                    │                                     │
                    ▼                                     ▼
┌─────────────────────────────────┐   ┌─────────────────────────────────┐
│      Spoke Cluster 1            │   │      Spoke Cluster 2            │
│      (aigrid-tenant1)           │   │      (aigrid-tenant2)           │
│      us-east-2                  │   │      us-west-2                  │
│                                 │   │                                 │
│  ┌─────────────────────┐        │   │  ┌─────────────────────┐        │
│  │    Spoke EPP        │        │   │  │    Spoke EPP        │        │
│  │  + vLLM/SGLang pods │        │   │  │  + vLLM/SGLang pods │        │
│  │  (2x g4dn.xlarge)   │        │   │  │  (2x g4dn.xlarge)   │        │
│  └─────────────────────┘        │   │  └─────────────────────┘        │
└─────────────────────────────────┘   └─────────────────────────────────┘
```

---

## Cluster Access Details

### Hub Cluster (aigrid-hub)

| Property | Value |
|----------|-------|
| **Name** | `aigrid-hub` |
| **Region** | `us-east-1` |
| **API URL** | `https://api.aigrid-hub.aigriddev.sysdeseng.com:6443` |
| **Console URL** | https://console-openshift-console.apps.aigrid-hub.aigriddev.sysdeseng.com |
| **Username** | `kubeadmin` |
| **Password** | `HHXA3-Tx39V-3viHn-mdifI` |
| **Kubeconfig** | `docs/multi-cluster-setup/hub/auth/kubeconfig` |
| **Workers** | 0 (control plane only, masters are schedulable) |
| **Instance Type** | `c5a.4xlarge` (control plane) |
| **Purpose** | Hub EPP - routes requests to spoke clusters |

**Access commands:**
```bash
# Set kubeconfig
export KUBECONFIG=~/Projects/llm-d-inference-scheduler/docs/multi-cluster-setup/hub/auth/kubeconfig

# Verify access
oc whoami
oc get nodes
oc get clusterversion
```

---

### Spoke Cluster 1 (aigrid-tenant1)

| Property | Value |
|----------|-------|
| **Name** | `aigrid-tenant1` |
| **Region** | `us-east-2` |
| **API URL** | `https://api.aigrid-tenant1.aigriddev.sysdeseng.com:6443` |
| **Console URL** | https://console-openshift-console.apps.aigrid-tenant1.aigriddev.sysdeseng.com |
| **Username** | `kubeadmin` |
| **Password** | `34G28-nBw3G-imF9K-45Uyr` |
| **Kubeconfig** | `docs/multi-cluster-setup/spoke-tenant1/auth/kubeconfig` |
| **Workers** | 2 GPU nodes |
| **Instance Type** | `g4dn.xlarge` (NVIDIA T4 GPU) |
| **Purpose** | Inference workloads with Spoke EPP |

**Access commands:**
```bash
# Set kubeconfig
export KUBECONFIG=~/Projects/llm-d-inference-scheduler/docs/multi-cluster-setup/spoke-tenant1/auth/kubeconfig

# Verify access
oc whoami
oc get nodes
oc get clusterversion
```

---

### Spoke Cluster 2 (aigrid-tenant2)

| Property | Value |
|----------|-------|
| **Name** | `aigrid-tenant2` |
| **Region** | `us-west-2` |
| **API URL** | `https://api.aigrid-tenant2.aigriddev.sysdeseng.com:6443` |
| **Console URL** | https://console-openshift-console.apps.aigrid-tenant2.aigriddev.sysdeseng.com |
| **Username** | `kubeadmin` |
| **Password** | `jLDq2-vJ6I4-jFv9j-zk6G9` |
| **Kubeconfig** | `docs/multi-cluster-setup/spoke-tenant2/auth/kubeconfig` |
| **Workers** | 2 GPU nodes |
| **Instance Type** | `g4dn.xlarge` (NVIDIA T4 GPU) |
| **Purpose** | Inference workloads with Spoke EPP |

---

### Tenant/Consumer Cluster (aigrid-consumer)

| Property | Value |
|----------|-------|
| **Name** | `aigrid-consumer` |
| **Region** | `us-east-1` |
| **API URL** | `https://api.aigrid-consumer.aigriddev.sysdeseng.com:6443` |
| **Console URL** | https://console-openshift-console.apps.aigrid-consumer.aigriddev.sysdeseng.com |
| **Username** | `kubeadmin` |
| **Password** | `yHnKE-Ks2AZ-PAvwp-T64J4` |
| **Kubeconfig** | `docs/multi-cluster-setup/tenant-consumer/auth/kubeconfig` |
| **Workers** | 0 (control plane only) |
| **Instance Type** | `m5.xlarge` (control plane) |
| **Purpose** | Tenant cluster - consumes AI models via MaaS + ExternalModel |

**Access commands:**
```bash
# Set kubeconfig
export KUBECONFIG=~/Projects/llm-d-inference-scheduler/docs/multi-cluster-setup/tenant-consumer/auth/kubeconfig

# Verify access
oc whoami
oc get nodes
oc get clusterversion
```

---

## Quick Access Scripts

### Switch between clusters

```bash
# Hub
alias hub='export KUBECONFIG=~/Projects/llm-d-inference-scheduler/docs/multi-cluster-setup/hub/auth/kubeconfig && echo "Switched to Hub"'

# Spoke 1
alias spoke1='export KUBECONFIG=~/Projects/llm-d-inference-scheduler/docs/multi-cluster-setup/spoke-tenant1/auth/kubeconfig && echo "Switched to Spoke1"'

# Spoke 2
alias spoke2='export KUBECONFIG=~/Projects/llm-d-inference-scheduler/docs/multi-cluster-setup/spoke-tenant2/auth/kubeconfig && echo "Switched to Spoke2"'

# Tenant/Consumer
alias tenant='export KUBECONFIG=~/Projects/llm-d-inference-scheduler/docs/multi-cluster-setup/tenant-consumer/auth/kubeconfig && echo "Switched to Tenant"'
```

Add these to your `~/.bashrc` for convenience.

---

## Network Connectivity

### DNS

All clusters use the pre-configured DNS zone: `aigriddev.sysdeseng.com`

| Cluster | API Endpoint | Apps Wildcard |
|---------|--------------|---------------|
| Tenant | `api.aigrid-consumer.aigriddev.sysdeseng.com` | `*.apps.aigrid-consumer.aigriddev.sysdeseng.com` |
| Hub | `api.aigrid-hub.aigriddev.sysdeseng.com` | `*.apps.aigrid-hub.aigriddev.sysdeseng.com` |
| Spoke1 | `api.aigrid-tenant1.aigriddev.sysdeseng.com` | `*.apps.aigrid-tenant1.aigriddev.sysdeseng.com` |
| Spoke2 | `api.aigrid-tenant2.aigriddev.sysdeseng.com` | `*.apps.aigrid-tenant2.aigriddev.sysdeseng.com` |

### Cross-Cluster Communication

For Hub-to-Spoke communication:
- **Inference requests**: Hub Gateway → Spoke Gateway (via mTLS)
- **Metrics scraping**: Hub EPP → Spoke EPP `/metrics` endpoint (via mTLS)

The Gateway addresses for the Hub's `file-discovery` config:
```yaml
# endpoints.yaml on Hub EPP
endpoints:
  - name: spoke-tenant1
    address: <spoke1-gateway-route>  # Will be the Route/Ingress of Spoke1 Gateway
    port: "443"
    labels:
      region: us-east-2

  - name: spoke-tenant2
    address: <spoke2-gateway-route>  # Will be the Route/Ingress of Spoke2 Gateway
    port: "443"
    labels:
      region: us-west-2
```

---

## Cost Information

| Cluster | Nodes | Instance Type | Approx. Cost/Hour |
|---------|-------|---------------|-------------------|
| Hub | 3 control plane | c5a.4xlarge | ~$1.50/hr |
| Spoke1 | 3 CP + 2 workers | m5.xlarge + g4dn.xlarge | ~$2.50/hr |
| Spoke2 | 3 CP + 2 workers | m5.xlarge + g4dn.xlarge | ~$2.50/hr |
| Tenant | 3 control plane | m5.xlarge | ~$0.60/hr |
| **Total** | | | **~$7.10/hr (~$170/day)** |

**IMPORTANT**: Stop or destroy clusters when not in use!

---

## Power Management (Stop/Start Without Destroying)

For overnight or weekend breaks, you can **stop** clusters instead of destroying them.
This saves ~80% of costs while preserving configuration.

### Using the Management Script

The `manage-clusters.sh` script uses `metadata.json` from each cluster directory to discover
the unique `infraID`, ensuring it only affects YOUR clusters (not others with similar names).

```bash
cd ~/Projects/llm-d-inference-scheduler/docs/multi-cluster-setup

# Check status of all clusters
./manage-clusters.sh status

# Stop all clusters (with confirmation prompt)
./manage-clusters.sh stop all

# Stop all clusters (skip confirmation)
./manage-clusters.sh stop all -y

# Start all clusters
./manage-clusters.sh start all -y

# Stop/start individual clusters
./manage-clusters.sh stop hub
./manage-clusters.sh stop spoke-tenant1
./manage-clusters.sh start spoke-tenant2
```

**Note:** The script waits for instances to fully reach the target state before returning.

### Cost Comparison

| State | Approx. Cost/Day |
|-------|------------------|
| All running | ~$156/day |
| All stopped | ~$15-20/day (EBS + Load Balancers only) |
| Destroyed | $0 |

### Verify Clusters Are Stopped

**Option 1: Use the script**
```bash
./manage-clusters.sh status
```

**Option 2: AWS Console (UI)**
1. Go to: https://console.aws.amazon.com/ec2/v2/home
2. Select region (us-east-1 for Hub, us-east-2 for Spoke1, us-west-2 for Spoke2)
3. Click "Instances" in left sidebar
4. Filter by: `kubernetes.io/cluster/aigrid-hub` (or tenant1/tenant2)
5. Check "Instance state" column - should show "stopped"

**Option 3: AWS CLI**
```bash
# Check Hub instances (us-east-1)
aws ec2 describe-instances \
  --filters "Name=tag:kubernetes.io/cluster/aigrid-hub,Values=owned" \
  --query 'Reservations[].Instances[].[InstanceId,State.Name]' \
  --output table --region us-east-1

# Check Spoke1 instances (us-east-2)
aws ec2 describe-instances \
  --filters "Name=tag:kubernetes.io/cluster/aigrid-tenant1,Values=owned" \
  --query 'Reservations[].Instances[].[InstanceId,State.Name]' \
  --output table --region us-east-2
```

### Important Notes

- **Startup time**: After starting, clusters take 5-10 minutes to become fully ready
- **Short breaks** (overnight/weekend): Use stop/start
- **Long breaks** (1+ week): Destroy and recreate is cleaner
- **Certificates**: If stopped for very long periods, certificates might expire

---

## Cluster Lifecycle Commands

### Destroy clusters (for long breaks or cleanup)

```bash
cd ~/Projects/llm-d-inference-scheduler/docs/multi-cluster-setup

# Destroy Tenant
cd tenant-consumer && openshift-install destroy cluster --dir=. --log-level=info

# Destroy Hub
cd ../hub && openshift-install destroy cluster --dir=. --log-level=info

# Destroy Spoke1
cd ../spoke-tenant1 && openshift-install destroy cluster --dir=. --log-level=info

# Destroy Spoke2
cd ../spoke-tenant2 && openshift-install destroy cluster --dir=. --log-level=info
```

### Re-create clusters

```bash
cd ~/Projects/llm-d-inference-scheduler/docs/multi-cluster-setup

# Restore config from backup and create
cd hub && cp install-config.yaml.backup install-config.yaml
openshift-install create cluster --dir=. --log-level=info
```

---

## Next Steps After Cluster Creation

1. **Install NVIDIA GPU Operator** (on Spoke clusters)
   ```bash
   # On each Spoke cluster
   oc apply -f https://raw.githubusercontent.com/NVIDIA/gpu-operator/main/deployments/gpu-operator/crds/nvidia.com_clusterpolicies.yaml
   # ... (full instructions TBD)
   ```

2. **Deploy llm-d components**
   - Spoke EPP on each Spoke cluster
   - Hub EPP on Hub cluster
   - Configure `file-discovery` with Spoke Gateway addresses

3. **Configure mTLS between clusters**
   - Install cert-manager
   - Create cross-cluster certificates
   - Configure Gateway mTLS

4. **Deploy test model** (e.g., TinyLlama on Spokes)

5. **Test multi-cluster routing**
   - Send request to Hub Gateway
   - Verify routing to Spoke based on metrics

---

## Troubleshooting

### Can't access cluster API

```bash
# Check if kubeconfig exists
ls -la docs/multi-cluster-setup/<cluster>/auth/kubeconfig

# Check DNS resolution
nslookup api.<cluster-name>.aigriddev.sysdeseng.com

# Check API connectivity
curl -k https://api.<cluster-name>.aigriddev.sysdeseng.com:6443/version
```

### Cluster creation failed

```bash
# Check logs
cat docs/multi-cluster-setup/<cluster>/cluster-creation.log

# Check AWS resources (may need cleanup)
aws ec2 describe-instances --filters "Name=tag:kubernetes.io/cluster/<cluster-name>,Values=owned"
```

### Force destroy stuck cluster

```bash
cd docs/multi-cluster-setup/<cluster>
openshift-install destroy cluster --dir=. --log-level=debug
```

---

## Files Reference

```
docs/multi-cluster-setup/
├── CLUSTERS.md              # This file
├── README.md                # Setup instructions
├── manage-clusters.sh       # Stop/start clusters safely (uses infraID)
├── setup.sh                 # Interactive setup script
├── pull-secret.json         # Red Hat pull secret (DO NOT COMMIT)
├── hub/
│   ├── install-config.yaml.backup
│   ├── auth/
│   │   ├── kubeconfig       # Cluster access
│   │   └── kubeadmin-password
│   └── cluster-creation.log
├── spoke-tenant1/
│   ├── install-config.yaml.backup
│   ├── auth/
│   │   ├── kubeconfig
│   │   └── kubeadmin-password
│   └── cluster-creation.log
└── spoke-tenant2/
    ├── install-config.yaml.backup
    └── (auth/ created after cluster creation)
```

---

*Last updated: July 7, 2026*
