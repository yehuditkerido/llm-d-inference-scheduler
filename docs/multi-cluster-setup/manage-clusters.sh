#!/bin/bash
#
# manage-clusters.sh - Start, stop, or check status of OCP clusters on AWS.
#
# Reads metadata.json from each cluster directory to discover infraID and
# region, then uses the AWS CLI to manage the EC2 instances.
#
# Usage:
#   manage-clusters.sh <start|stop|status> [cluster-name|all] [-y]
#
# Examples:
#   manage-clusters.sh status
#   manage-clusters.sh stop aigrid-ifc1
#   manage-clusters.sh start all -y
#

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_DIRS=("hub" "spoke-tenant1" "spoke-tenant2" "tenant-consumer")

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
msg()   { echo -e "${BOLD}==> ${NC}$*"; }
info()  { echo -e "    ${CYAN}$*${NC}"; }
ok()    { echo -e "    ${GREEN}$*${NC}"; }
warn()  { echo -e "    ${YELLOW}$*${NC}"; }
err()   { echo -e "    ${RED}$*${NC}" >&2; }

state_color() {
    local state="$1"
    case "$state" in
        running)          echo -e "${GREEN}${state}${NC}" ;;
        stopped)          echo -e "${RED}${state}${NC}" ;;
        stopping|pending|shutting-down) echo -e "${YELLOW}${state}${NC}" ;;
        terminated)       echo -e "${RED}${state}${NC}" ;;
        *)                echo "$state" ;;
    esac
}

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [cluster] [-y]

Commands:
  start    Start all stopped EC2 instances for the cluster(s)
  stop     Stop all running EC2 instances for the cluster(s)
  status   Show current state of EC2 instances for the cluster(s)

Cluster:
  hub              Manage only the hub cluster (us-east-1)
  spoke-tenant1    Manage only spoke cluster 1 (us-east-2)
  spoke-tenant2    Manage only spoke cluster 2 (us-west-2)
  tenant-consumer  Manage only the tenant/consumer cluster (us-east-1)
  all              Manage all clusters (default)

Options:
  -y       Skip confirmation prompt

EOF
    exit 1
}

# ---------------------------------------------------------------------------
# Prereq checks
# ---------------------------------------------------------------------------
check_prereqs() {
    local missing=0
    for cmd in aws jq; do
        if ! command -v "$cmd" &>/dev/null; then
            err "Required command not found: $cmd"
            missing=1
        fi
    done
    if [[ $missing -eq 1 ]]; then
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Metadata helpers
# ---------------------------------------------------------------------------
parse_metadata() {
    local cluster_dir="$1"
    local metadata_file="${SCRIPT_DIR}/${cluster_dir}/metadata.json"

    if [[ ! -f "$metadata_file" ]]; then
        err "metadata.json not found: $metadata_file"
        return 1
    fi

    CLUSTER_NAME=$(jq -r '.clusterName' "$metadata_file")
    INFRA_ID=$(jq -r '.infraID' "$metadata_file")
    AWS_REGION=$(jq -r '.aws.region' "$metadata_file")
    CLUSTER_DOMAIN=$(jq -r '.aws.clusterDomain' "$metadata_file")
}

# ---------------------------------------------------------------------------
# Instance discovery
# ---------------------------------------------------------------------------
get_instances() {
    # Args: region, infraID
    # Returns JSON array of instances with ID, State, Type, Name
    local region="$1"
    local infra_id="$2"

    aws ec2 describe-instances \
        --region "$region" \
        --filters "Name=tag:kubernetes.io/cluster/${infra_id},Values=owned" \
                  "Name=instance-state-name,Values=running,stopped,stopping,pending" \
        --query 'Reservations[].Instances[].{ID:InstanceId,State:State.Name,Type:InstanceType,Name:Tags[?Key==`Name`]|[0].Value}' \
        --output json
}

get_instance_ids_by_state() {
    # Args: instances_json, desired_state
    local instances_json="$1"
    local state="$2"

    echo "$instances_json" | jq -r --arg s "$state" '.[] | select(.State == $s) | .ID'
}

# ---------------------------------------------------------------------------
# Display
# ---------------------------------------------------------------------------
print_instances() {
    local instances_json="$1"
    local count
    count=$(echo "$instances_json" | jq 'length')

    if [[ "$count" -eq 0 ]]; then
        warn "No instances found"
        return
    fi

    printf "    %-22s %-14s %-15s %s\n" "INSTANCE ID" "TYPE" "STATE" "NAME"
    printf "    %-22s %-14s %-15s %s\n" "-----------" "----" "-----" "----"

    while IFS=$'\t' read -r id type state name; do
        local colored_state
        colored_state=$(state_color "$state")
        printf "    %-22s %-14s %-15b %s\n" "$id" "$type" "$colored_state" "$name"
    done < <(echo "$instances_json" | jq -r '.[] | [.ID, .Type, .State, .Name // "N/A"] | @tsv')
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------
do_status() {
    local cluster_dir="$1"
    parse_metadata "$cluster_dir"

    msg "Cluster: ${BOLD}${CLUSTER_NAME}${NC} (${INFRA_ID})"
    info "Region: ${AWS_REGION} | Domain: ${CLUSTER_DOMAIN}"

    local instances
    instances=$(get_instances "$AWS_REGION" "$INFRA_ID")
    print_instances "$instances"
    echo
}

do_stop() {
    local cluster_dir="$1"
    local skip_confirm="$2"
    parse_metadata "$cluster_dir"

    msg "Cluster: ${BOLD}${CLUSTER_NAME}${NC} (${INFRA_ID})"
    info "Region: ${AWS_REGION} | Domain: ${CLUSTER_DOMAIN}"

    local instances
    instances=$(get_instances "$AWS_REGION" "$INFRA_ID")

    local running_ids
    running_ids=$(get_instance_ids_by_state "$instances" "running")

    if [[ -z "$running_ids" ]]; then
        ok "No running instances to stop"
        echo
        return
    fi

    local id_array
    mapfile -t id_array <<< "$running_ids"
    info "Found ${#id_array[@]} running instance(s) to stop:"
    print_instances "$(echo "$instances" | jq '[.[] | select(.State == "running")]')"

    if [[ "$skip_confirm" != "yes" ]]; then
        echo
        read -rp "    Stop these instances? [y/N] " answer
        if [[ ! "$answer" =~ ^[Yy]$ ]]; then
            warn "Skipped"
            echo
            return
        fi
    fi

    info "Stopping instances..."
    aws ec2 stop-instances \
        --region "$AWS_REGION" \
        --instance-ids "${id_array[@]}" \
        --output json > /dev/null

    info "Waiting for instances to reach 'stopped' state..."
    aws ec2 wait instance-stopped \
        --region "$AWS_REGION" \
        --instance-ids "${id_array[@]}"

    ok "All instances stopped"
    echo
}

do_start() {
    local cluster_dir="$1"
    local skip_confirm="$2"
    parse_metadata "$cluster_dir"

    msg "Cluster: ${BOLD}${CLUSTER_NAME}${NC} (${INFRA_ID})"
    info "Region: ${AWS_REGION} | Domain: ${CLUSTER_DOMAIN}"

    local instances
    instances=$(get_instances "$AWS_REGION" "$INFRA_ID")

    local stopped_ids
    stopped_ids=$(get_instance_ids_by_state "$instances" "stopped")

    if [[ -z "$stopped_ids" ]]; then
        ok "No stopped instances to start"
        echo
        return
    fi

    local id_array
    mapfile -t id_array <<< "$stopped_ids"
    info "Found ${#id_array[@]} stopped instance(s) to start:"
    print_instances "$(echo "$instances" | jq '[.[] | select(.State == "stopped")]')"

    if [[ "$skip_confirm" != "yes" ]]; then
        echo
        read -rp "    Start these instances? [y/N] " answer
        if [[ ! "$answer" =~ ^[Yy]$ ]]; then
            warn "Skipped"
            echo
            return
        fi
    fi

    info "Starting instances..."
    aws ec2 start-instances \
        --region "$AWS_REGION" \
        --instance-ids "${id_array[@]}" \
        --output json > /dev/null

    info "Waiting for instances to reach 'running' state..."
    aws ec2 wait instance-running \
        --region "$AWS_REGION" \
        --instance-ids "${id_array[@]}"

    ok "All instances started"
    echo
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    check_prereqs

    local command=""
    local target="all"
    local skip_confirm="no"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            start|stop|status)
                command="$1"
                ;;
            hub|spoke-tenant1|spoke-tenant2|tenant-consumer|all)
                target="$1"
                ;;
            -y|--yes)
                skip_confirm="yes"
                ;;
            -h|--help)
                usage
                ;;
            *)
                err "Unknown argument: $1"
                usage
                ;;
        esac
        shift
    done

    if [[ -z "$command" ]]; then
        err "No command specified"
        usage
    fi

    # Build list of cluster dirs to process
    local dirs_to_process=()
    if [[ "$target" == "all" ]]; then
        dirs_to_process=("${CLUSTER_DIRS[@]}")
    else
        dirs_to_process=("$target")
    fi

    echo
    msg "${BOLD}Action: ${command}${NC} | Target: ${target}"
    echo

    for cluster_dir in "${dirs_to_process[@]}"; do
        case "$command" in
            status) do_status "$cluster_dir" ;;
            stop)   do_stop "$cluster_dir" "$skip_confirm" ;;
            start)  do_start "$cluster_dir" "$skip_confirm" ;;
        esac
    done
}

main "$@"