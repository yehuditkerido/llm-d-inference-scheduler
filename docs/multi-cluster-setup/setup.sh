#!/bin/bash
# Multi-Cluster Test Environment Setup Script
# This script helps configure and create OpenShift clusters for testing Hub-and-Spoke

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=============================================="
echo "  Multi-Cluster Test Environment Setup"
echo "=============================================="
echo ""

# Check prerequisites
check_prerequisites() {
    echo "Checking prerequisites..."
    
    # Check AWS credentials
    if [[ ! -f ~/.aws/credentials ]]; then
        echo -e "${RED}ERROR: AWS credentials not found at ~/.aws/credentials${NC}"
        echo "Please create the file with your credentials:"
        echo ""
        echo "[default]"
        echo "aws_access_key_id = YOUR_ACCESS_KEY"
        echo "aws_secret_access_key = YOUR_SECRET_KEY"
        exit 1
    fi
    echo -e "${GREEN}✓${NC} AWS credentials found"
    
    # Check openshift-install
    if ! command -v openshift-install &> /dev/null; then
        echo -e "${RED}ERROR: openshift-install not found${NC}"
        echo "Download it from:"
        echo "  curl -LO https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-install-linux.tar.gz"
        echo "  tar -xzf openshift-install-linux.tar.gz"
        echo "  sudo mv openshift-install /usr/local/bin/"
        exit 1
    fi
    echo -e "${GREEN}✓${NC} openshift-install found: $(openshift-install version | head -1)"
    
    # Check SSH key
    if [[ ! -f ~/.ssh/id_rsa.pub ]]; then
        echo -e "${YELLOW}WARNING: SSH public key not found at ~/.ssh/id_rsa.pub${NC}"
        read -p "Generate a new SSH key? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""
        else
            echo "Please create an SSH key or update the install configs with your key path"
            exit 1
        fi
    fi
    echo -e "${GREEN}✓${NC} SSH key found"
    
    echo ""
}

# Configure install configs with user's secrets
configure_secrets() {
    echo "Configuring secrets..."
    
    # Get SSH key
    SSH_KEY=$(cat ~/.ssh/id_rsa.pub)
    
    # Get pull secret
    echo ""
    echo "You need a Red Hat pull secret from:"
    echo "  https://console.redhat.com/openshift/downloads"
    echo ""
    echo "Paste your pull secret (single line JSON, press Enter when done):"
    read -r PULL_SECRET
    
    if [[ -z "$PULL_SECRET" ]]; then
        echo -e "${RED}ERROR: Pull secret cannot be empty${NC}"
        exit 1
    fi
    
    # Update all install configs
    for dir in hub spoke-tenant1 spoke-tenant2; do
        config_file="${SCRIPT_DIR}/${dir}/install-config.yaml"
        if [[ -f "$config_file" ]]; then
            # Create backup
            cp "$config_file" "${config_file}.template"
            
            # Replace placeholders
            sed -i "s|<YOUR_PULL_SECRET_HERE>|'${PULL_SECRET}'|g" "$config_file"
            sed -i "s|<YOUR_SSH_PUBLIC_KEY_HERE>|${SSH_KEY}|g" "$config_file"
            
            echo -e "${GREEN}✓${NC} Configured ${dir}/install-config.yaml"
        fi
    done
    
    echo ""
}

# Create a specific cluster
create_cluster() {
    local cluster_dir=$1
    local cluster_name=$(basename "$cluster_dir")
    
    echo "=============================================="
    echo "  Creating cluster: $cluster_name"
    echo "=============================================="
    echo ""
    echo -e "${YELLOW}WARNING: This will take 30-45 minutes and incur AWS charges!${NC}"
    read -p "Continue? (y/n) " -n 1 -r
    echo
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Skipping $cluster_name"
        return
    fi
    
    cd "$cluster_dir"
    
    # The install-config.yaml is CONSUMED by the installer, so we need to back it up
    if [[ -f install-config.yaml.template ]]; then
        cp install-config.yaml.template install-config.yaml
    fi
    
    openshift-install create cluster --dir=. --log-level=info
    
    echo ""
    echo -e "${GREEN}Cluster $cluster_name created!${NC}"
    echo "Kubeconfig: ${cluster_dir}/auth/kubeconfig"
    echo "Console URL: https://console-openshift-console.apps.${cluster_name}.aigriddev.sysdeseng.com"
    echo ""
}

# Destroy a specific cluster
destroy_cluster() {
    local cluster_dir=$1
    local cluster_name=$(basename "$cluster_dir")
    
    echo "=============================================="
    echo "  Destroying cluster: $cluster_name"
    echo "=============================================="
    echo ""
    echo -e "${RED}WARNING: This will permanently delete the cluster!${NC}"
    read -p "Are you sure? (y/n) " -n 1 -r
    echo
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Skipping destruction of $cluster_name"
        return
    fi
    
    cd "$cluster_dir"
    openshift-install destroy cluster --dir=. --log-level=info
    
    echo ""
    echo -e "${GREEN}Cluster $cluster_name destroyed${NC}"
}

# Main menu
main_menu() {
    while true; do
        echo ""
        echo "=============================================="
        echo "  What would you like to do?"
        echo "=============================================="
        echo "1) Check prerequisites"
        echo "2) Configure secrets (pull secret + SSH key)"
        echo "3) Create Hub cluster"
        echo "4) Create Spoke Tenant1 cluster"
        echo "5) Create Spoke Tenant2 cluster"
        echo "6) Create ALL clusters"
        echo "7) Destroy Hub cluster"
        echo "8) Destroy Spoke Tenant1 cluster"
        echo "9) Destroy Spoke Tenant2 cluster"
        echo "10) Destroy ALL clusters"
        echo "q) Quit"
        echo ""
        read -p "Enter choice: " choice
        
        case $choice in
            1) check_prerequisites ;;
            2) configure_secrets ;;
            3) create_cluster "${SCRIPT_DIR}/hub" ;;
            4) create_cluster "${SCRIPT_DIR}/spoke-tenant1" ;;
            5) create_cluster "${SCRIPT_DIR}/spoke-tenant2" ;;
            6) 
                create_cluster "${SCRIPT_DIR}/hub"
                create_cluster "${SCRIPT_DIR}/spoke-tenant1"
                create_cluster "${SCRIPT_DIR}/spoke-tenant2"
                ;;
            7) destroy_cluster "${SCRIPT_DIR}/hub" ;;
            8) destroy_cluster "${SCRIPT_DIR}/spoke-tenant1" ;;
            9) destroy_cluster "${SCRIPT_DIR}/spoke-tenant2" ;;
            10)
                destroy_cluster "${SCRIPT_DIR}/hub"
                destroy_cluster "${SCRIPT_DIR}/spoke-tenant1"
                destroy_cluster "${SCRIPT_DIR}/spoke-tenant2"
                ;;
            q|Q) 
                echo "Goodbye!"
                exit 0
                ;;
            *) echo -e "${RED}Invalid choice${NC}" ;;
        esac
    done
}

# Run
main_menu
