#!/bin/bash
#
# create-cluster.sh - Create OpenShift clusters for the downstream test environment.
#
# Usage:
#   ./create-cluster.sh <cluster|all>
#
# Examples:
#   ./create-cluster.sh hub
#   ./create-cluster.sh spoke1
#   ./create-cluster.sh all
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_DIRS=("hub" "spoke1" "spoke2" "spoke3" "tenant")

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

msg()  { echo -e "${GREEN}==>${NC} $*"; }
warn() { echo -e "${YELLOW}WARNING:${NC} $*"; }
err()  { echo -e "${RED}ERROR:${NC} $*" >&2; }

usage() {
    cat <<EOF
Usage: $(basename "$0") <cluster|all>

Clusters:
  hub      Create the hub cluster (us-east-1)
  spoke1   Create spoke cluster 1 (us-east-2)
  spoke2   Create spoke cluster 2 (us-west-2)
  spoke3   Create spoke cluster 3 (eu-west-1)
  tenant   Create the tenant cluster (us-east-1)
  all      Create all clusters sequentially

EOF
    exit 1
}

check_prereqs() {
    if ! command -v openshift-install &>/dev/null; then
        err "openshift-install not found. Download from:"
        echo "  https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/"
        exit 1
    fi

    if [[ ! -f ~/.aws/credentials ]]; then
        err "AWS credentials not found at ~/.aws/credentials"
        exit 1
    fi
}

create_cluster() {
    local cluster_dir="$1"
    local full_path="${SCRIPT_DIR}/${cluster_dir}"
    local config_backup="${full_path}/install-config.yaml.backup"
    local config_file="${full_path}/install-config.yaml"

    if [[ ! -f "$config_backup" ]]; then
        err "Config not found: $config_backup"
        return 1
    fi

    # Check if placeholders are still present
    if grep -q '<YOUR_PULL_SECRET_HERE>' "$config_backup" || grep -q '<YOUR_SSH_PUBLIC_KEY_HERE>' "$config_backup"; then
        err "Please configure secrets in $config_backup first"
        echo "  Replace <YOUR_PULL_SECRET_HERE> with your pull secret"
        echo "  Replace <YOUR_SSH_PUBLIC_KEY_HERE> with your SSH public key"
        return 1
    fi

    local cluster_name
    cluster_name=$(grep 'name:' "$config_backup" | head -1 | awk '{print $2}')

    echo ""
    msg "Creating cluster: ${cluster_name}"
    echo "    Directory: ${full_path}"
    echo "    Config: ${config_backup}"
    echo ""
    warn "This will take 30-45 minutes and incur AWS charges!"
    echo ""

    read -rp "Continue? [y/N] " answer
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        warn "Skipped"
        return
    fi

    # Copy backup to install-config.yaml (installer consumes it)
    cp "$config_backup" "$config_file"

    cd "$full_path"
    msg "Running openshift-install..."
    openshift-install create cluster --dir=. --log-level=info 2>&1 | tee cluster-creation.log

    echo ""
    msg "Cluster ${cluster_name} created!"
    echo "    Kubeconfig: ${full_path}/auth/kubeconfig"
    echo "    Console: https://console-openshift-console.apps.${cluster_name}.aigriddev.sysdeseng.com"
    echo ""
}

main() {
    check_prereqs

    if [[ $# -lt 1 ]]; then
        usage
    fi

    local target="$1"
    local dirs_to_create=()

    case "$target" in
        hub|spoke1|spoke2|spoke3|tenant)
            dirs_to_create=("$target")
            ;;
        all)
            dirs_to_create=("${CLUSTER_DIRS[@]}")
            ;;
        -h|--help)
            usage
            ;;
        *)
            err "Unknown cluster: $target"
            usage
            ;;
    esac

    echo ""
    msg "[DOWNSTREAM] Creating cluster(s): ${dirs_to_create[*]}"
    echo ""

    for cluster_dir in "${dirs_to_create[@]}"; do
        create_cluster "$cluster_dir"
    done
}

main "$@"
