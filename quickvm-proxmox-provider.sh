#!/bin/bash

# Copyright (c) 2025 QuickVM, LLC. All rights reserved.

# QuickVM Provider LXC Setup Script
# Creates a Fedora LXC container and configures the quickvm-provider service

set -euo pipefail

# Generate secure API key function
generate_api_key() {
    # Generate a 48-character alphanumeric password
    if command -v openssl >/dev/null 2>&1; then
        # Use openssl if available (more reliable)
        openssl rand -base64 36 | tr -d "=+/" | cut -c1-48
    else
        # Fallback to /dev/urandom
        tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 48
    fi
}

# Default configuration values
CONTAINER_NAME="quickvm-provider"
TEMPLATE_NAME=""  # Will be set dynamically by detecting latest Fedora template

# API User configuration
API_USERNAME="quickvm"
API_REALM="pve"
ROLE_NAME="quickvm"
GROUP_NAME="quickvm"

# Cluster configuration
CURRENT_NODE=""
NODE_ID=""

# Initialize variables with environment variable defaults
MEMORY=${MEMORY:-2048}
CORES=${CORES:-2}
ROOTFS_SIZE=${ROOTFS_SIZE:-8}
BRIDGE=${BRIDGE:-"vmbr0"}
HOST_PORT=${HOST_PORT:-"8071"}
STORAGE=${STORAGE:-""}
TEMPLATE_STORAGE=${TEMPLATE_STORAGE:-""}
IP_ADDRESS=${IP:-""}
GATEWAY=${GATEWAY:-""}
DEBUG_MODE=${DEBUG:-false}
IMAGE_TAG=${TAG:-"stable"}
CONTAINER_ID_MANUAL=""
CONFIG_FILE="/etc/quickvm/quickvm-provider.env"
SKIP_API_USER=${SKIP_API_USER:-false}
AUTO_UPDATE=${AUTO_UPDATE:-false}
INTERFACES=${INTERFACES:-""}

# API key handling
if [[ -z "${API_KEY:-}" ]]; then
    GENERATED_API_KEY=$(generate_api_key)
    API_KEY="${GENERATED_API_KEY}"
    API_KEY_WAS_GENERATED=true
else
    API_KEY_WAS_GENERATED=false
fi

# API token storage variables
API_TOKEN_ID=""
API_TOKEN_SECRET=""

# Logging functions
log_info() {
    echo "[INFO] $1"
}

log_success() {
    echo "[SUCCESS] $1"
}

log_warning() {
    echo "[WARNING] $1"
}

log_error() {
    echo "[ERROR] $1"
}

# Validate specified interfaces exist and have IP addresses
validate_interfaces() {
    if [[ -z "${INTERFACES}" ]]; then
        return 0  # No validation needed if no interfaces specified
    fi

    log_info "Validating specified interfaces: ${INTERFACES}"

    IFS=',' read -ra INTERFACE_ARRAY <<< "${INTERFACES}"
    local INVALID_INTERFACES=()
    local VALID_IPS=()

    for INTERFACE in "${INTERFACE_ARRAY[@]}"; do
        INTERFACE=$(echo "${INTERFACE}" | xargs)  # trim whitespace

        # Check if interface exists
        if ! ip link show "${INTERFACE}" >/dev/null 2>&1; then
            INVALID_INTERFACES+=("${INTERFACE} (does not exist)")
            continue
        fi

        # Check if interface has an IP address
        local IP=$(ip addr show "${INTERFACE}" 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -n1 || true)
        if [[ -z "${IP}" ]]; then
            INVALID_INTERFACES+=("${INTERFACE} (no IP address)")
            continue
        fi

        VALID_IPS+=("${INTERFACE}:${IP}")
        log_info "  ✓ ${INTERFACE}: ${IP}"
    done

    if [[ ${#INVALID_INTERFACES[@]} -gt 0 ]]; then
        log_error "Invalid interfaces specified:"
        for INVALID in "${INVALID_INTERFACES[@]}"; do
            log_error "  ✗ ${INVALID}"
        done
        log_error ""
        log_error "Available interfaces with IP addresses:"
        ip addr show | grep -E '^[0-9]+:' | while read LINE; do
            IFACE=$(echo "${LINE}" | awk -F': ' '{print $2}' | cut -d'@' -f1)
            if [[ "${IFACE}" != "lo" ]]; then
                    IP_LOCAL=$(ip addr show "${IFACE}" 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -n1 || true)
                    if [[ -n "${IP_LOCAL}" ]]; then
                        echo "    ${IFACE}: ${IP_LOCAL}"
                    fi
                fi
        done
        exit 1
    fi

    log_success "All specified interfaces are valid and have IP addresses"
}

# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--container-id)
                CONTAINER_ID_MANUAL="$2"
                shift 2
                ;;
            -m|--memory)
                MEMORY="$2"
                shift 2
                ;;
            --cpu|--cores)
                CORES="$2"
                shift 2
                ;;
            -d|--disk)
                ROOTFS_SIZE="$2"
                shift 2
                ;;
            -k|--api-key)
                API_KEY="$2"
                API_KEY_WAS_GENERATED=false
                shift 2
                ;;
            -b|--bridge)
                BRIDGE="$2"
                shift 2
                ;;
            -p|--port)
                HOST_PORT="$2"
                shift 2
                ;;
            -s|--storage)
                STORAGE="$2"
                shift 2
                ;;
            -ts|--template-storage)
                TEMPLATE_STORAGE="$2"
                shift 2
                ;;
            -i|--ip-address)
                IP_ADDRESS="$2"
                shift 2
                ;;
            -g|--gateway)
                GATEWAY="$2"
                shift 2
                ;;
            --debug)
                DEBUG_MODE=true
                shift
                ;;
            --debug-storage)
                show_storage_debug_info
                exit 0
                ;;
            -t|--tag)
                IMAGE_TAG="$2"
                shift 2
                ;;
            --skip-api-user)
                SKIP_API_USER=true
                shift
                ;;
            --auto-update)
                # Handle optional argument (true/false)
                if [[ $# -gt 1 && -n "${2:-}" && "$2" != -* ]]; then
                    case "$2" in
                        true|True|TRUE|yes|Yes|YES|1)
                            AUTO_UPDATE=true
                            ;;
                        false|False|FALSE|no|No|NO|0)
                            AUTO_UPDATE=false
                            ;;
                        *)
                            log_error "Invalid value for --auto-update: $2. Use 'true' or 'false'"
                            exit 1
                            ;;
                    esac
                    shift 2
                else
                    # No argument provided, default to true
                    AUTO_UPDATE=true
                    shift
                fi
                ;;
            --interfaces)
                INTERFACES="$2"
                shift 2
                ;;
            --list-interfaces)
                echo "Available network interfaces with IP addresses:"
                echo ""

                # Use array-based approach to avoid pipe/subshell issues
                local INTERFACE_ARRAY=()
                while IFS= read -r LINE; do
                    INTERFACE_ARRAY+=("${LINE}")
                done < <(ip addr show | grep -E '^[0-9]+:')

                for LINE in "${INTERFACE_ARRAY[@]}"; do
                    IFACE=$(echo "${LINE}" | awk -F': ' '{print $2}' | cut -d'@' -f1)
                    if [[ "${IFACE}" != "lo" ]]; then
                        IP_LOCAL=$(ip addr show "${IFACE}" 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -n1 || true)
                        STATE=$(echo "${LINE}" | grep -o 'state [A-Z]*' | awk '{print $2}' || echo "UNKNOWN")

                        # Check interface flags to provide more intuitive status
                        if [[ "${STATE}" == "UNKNOWN" ]]; then
                            FLAGS=$(echo "${LINE}" | grep -o '<[^>]*>')
                            if [[ "${FLAGS}" =~ UP && "${FLAGS}" =~ LOWER_UP ]]; then
                                STATE="ACTIVE"
                            fi
                        fi

                        if [[ -n "${IP_LOCAL}" ]]; then
                            printf "  %-15s %s (%s)\n" "${IFACE}" "${IP_LOCAL}" "${STATE}"
                        else
                            printf "  %-15s %s (%s)\n" "${IFACE}" "no IP" "${STATE}"
                        fi
                    fi
                done

                echo ""
                echo "Use --interfaces with a comma-separated list of interface names."
                echo "Example: --interfaces eno1,defined1"
                exit 0
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            --uninstall)
                uninstall_service
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

# Check if Proxmox VE is installed
check_proxmox() {
    if ! command -v pveum &> /dev/null; then
        error "Proxmox VE user management tool (pveum) not found. Are you on a Proxmox node?"
        exit 1
    fi
}

# Detect cluster configuration and assign node-specific settings
detect_cluster_config() {
    log_info "Detecting cluster configuration..."

    # Get current node name
    CURRENT_NODE=$(hostname)
    log_info "Current node: ${CURRENT_NODE}"

    # Check if this is a cluster setup
    local CLUSTER_STATUS=""
    if command -v pvesh >/dev/null 2>&1; then
        CLUSTER_STATUS=$(pvesh get /cluster/status --output-format json 2>/dev/null || echo "[]")
    fi

    # Parse cluster nodes and assign node ID
    local NODES=()
    if [[ "${CLUSTER_STATUS}" != "[]" ]] && command -v jq >/dev/null 2>&1; then
        # Parse JSON to get node list
        while IFS= read -r NODE; do
            NODES+=("$NODE")
        done < <(echo "${CLUSTER_STATUS}" | jq -r '.[] | select(.type == "node") | .name' 2>/dev/null | sort)
    fi

    # Fallback: try to detect nodes from /etc/pve/nodes if cluster detection fails
    # Fallback: get node list from filesystem if cluster status is not available
    if [[ ${#NODES[@]} -eq 0 ]] && [[ -d "/etc/pve/nodes" ]]; then
        while IFS= read -r NODE; do
            NODES+=("$NODE")
        done < <(ls /etc/pve/nodes/ 2>/dev/null | sort)
    fi

    # If still no nodes found, assume single node setup
    if [[ ${#NODES[@]} -eq 0 ]]; then
        NODES=("${CURRENT_NODE}")
        log_info "Single node setup detected"
    else
        log_info "Cluster nodes detected: ${NODES[*]}"
    fi

    # Find current node's position in sorted list to determine node ID
    NODE_ID=0
    for I in "${!NODES[@]}"; do
        if [[ "${NODES[$I]}" == "${CURRENT_NODE}" ]]; then
            NODE_ID=$I
            break
        fi
    done

    log_success "Node configuration:"
    log_success "  Node: ${CURRENT_NODE}"
    log_success "  Node ID: ${NODE_ID}"
    log_success "  Port: ${HOST_PORT} (same port on all nodes)"

    # Show cluster info for reference
    if [[ ${#NODES[@]} -gt 1 ]]; then
        echo ""
        log_info "Cluster setup detected - ${#NODES[@]} nodes:"
        for I in "${!NODES[@]}"; do
            if [[ "${NODES[$I]}" == "${CURRENT_NODE}" ]]; then
                echo "  ${NODES[$I]} (this node) - port ${HOST_PORT}"
            else
                echo "  ${NODES[$I]} - port ${HOST_PORT}"
            fi
        done
        echo ""
        log_info "Run this script on each node to enable snippet writing on all nodes."
        echo ""
    fi
}

# Function to get the latest Fedora template
get_latest_fedora_template() {
    log_info "Detecting latest available Fedora template..."

    # Update template list first
    log_info "Updating template list..."
    pveam update

    # Get available templates and find the latest Fedora one
    local LATEST_FEDORA=$(pveam available --section system | grep -i fedora | tail -n1 | awk '{print $2}')

    if [[ -z "${LATEST_FEDORA}" ]]; then
        log_error "No Fedora templates found in available templates"
        log_info "Available system templates:"
        pveam available --section system | head -10
        exit 1
    fi

    TEMPLATE_NAME="${LATEST_FEDORA}"
    log_success "Latest Fedora template found: ${TEMPLATE_NAME}"
}

# Check for existing containers with the same name
check_existing_containers() {
    log_info "Checking for existing ${CONTAINER_NAME} containers..."

    # Find containers with the same name
    local CONTAINERS=$(pct list | grep "${CONTAINER_NAME}" | awk '{print $1}' || true)

    if [[ -n "${CONTAINERS}" ]]; then
        log_error "Existing ${CONTAINER_NAME} container(s) found with ID(s): ${CONTAINERS}"
        echo ""
        log_error "A ${CONTAINER_NAME} container already exists on this system."
        log_info "To avoid conflicts, only one ${CONTAINER_NAME} container is allowed per host."
        echo ""
        log_info "Options:"
        echo "  1. Use the existing container (no action needed)"
        echo "  2. Remove the existing container first:"
        echo "     $0 --uninstall"
        echo "     Then run this script again to create a new one"
        echo ""
        log_info "Existing container details:"
        pct list | head -1  # Show header
        pct list | grep "${CONTAINER_NAME}" || true
        echo ""
        exit 1
    fi

    log_success "No existing ${CONTAINER_NAME} containers found - proceeding with installation"
}

# Validate static IP configuration
validate_static_ip() {
    # Check if only one of IP or gateway is provided
    if [[ -n "${IP_ADDRESS}" && -z "${GATEWAY}" ]]; then
        log_error "IP address provided but gateway is missing"
        log_info "For static IP configuration, both --ip-address and --gateway must be specified"
        log_info "Example: $0 --ip-address 192.168.1.100/24 --gateway 192.168.1.1"
        exit 1
    elif [[ -z "${IP_ADDRESS}" && -n "${GATEWAY}" ]]; then
        log_error "Gateway provided but IP address is missing"
        log_info "For static IP configuration, both --ip-address and --gateway must be specified"
        log_info "Example: $0 --ip-address 192.168.1.100/24 --gateway 192.168.1.1"
        exit 1
    fi

    # Validate IP format if provided
    if [[ -n "${IP_ADDRESS}" ]]; then
        if [[ ! "${IP_ADDRESS}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
            log_error "Invalid IP address format: ${IP_ADDRESS}"
            log_info "IP address must be in CIDR format (e.g., 192.168.1.100/24)"
            exit 1
        fi
        log_info "Using static IP configuration: ${IP_ADDRESS} via ${GATEWAY}"
    else
        log_info "Using DHCP for IP configuration"
    fi
}

# Check if storage supports specific content types
check_storage_content_support() {
    local STORAGE_NAME="$1"
    local REQUIRED_CONTENT="$2"

    # First check if storage is active using pvesm status
    local STORAGE_INFO=$(pvesm status | grep "^${STORAGE_NAME}")
    if [[ -z "${STORAGE_INFO}" ]]; then
        return 1  # Storage not found
    fi

    # Check if storage is active
    if ! echo "${STORAGE_INFO}" | grep -q "active"; then
        return 1  # Storage not active
    fi

    # Parse /etc/pve/storage.cfg to get supported content types
    if [[ ! -f "/etc/pve/storage.cfg" ]]; then
        log_warning "Cannot find /etc/pve/storage.cfg, falling back to basic checks"
        return 0  # Default to supported if we can't determine
    fi

            # Check if storage is disabled in config and get content types
    local STORAGE_BLOCK=$(awk -v storage="${STORAGE_NAME}" '
        /^[a-zA-Z]+: / {
            # If we were processing a previous storage, output its result
            if (current_storage && current_storage == storage) {
                if (disabled) print "DISABLED"
                else if (content) print content
                else print "NO_CONTENT"
                exit
            }
            # Start processing new storage
            current_storage = $2
            disabled = 0
            content = ""
        }
        current_storage == storage && /^[[:space:]]*disable[[:space:]]*$/ {
            disabled = 1
        }
        current_storage == storage && /^[[:space:]]*content[[:space:]]/ {
            content = $0
            gsub(/^[[:space:]]*content[[:space:]]*/, "", content)
        }
        END {
            # Handle the last storage in the file
            if (current_storage == storage) {
                if (disabled) print "DISABLED"
                else if (content) print content
                else print "NO_CONTENT"
            }
        }
    ' /etc/pve/storage.cfg)

        if [[ "${STORAGE_BLOCK}" == "DISABLED" ]]; then
        return 1  # Storage is disabled
    fi

    if [[ -z "${STORAGE_BLOCK}" || "${STORAGE_BLOCK}" == "NO_CONTENT" ]]; then
        log_warning "Could not find content configuration for storage '${STORAGE_NAME}'"
        return 1  # Fail if we can't determine (don't assume supported)
    fi

    # Check if the required content type is in the content string
    if [[ "${STORAGE_BLOCK}" =~ ${REQUIRED_CONTENT} ]]; then
        return 0  # Content type is supported
    else
        return 1  # Content type not supported
    fi
}

# Show detailed storage information for debugging
show_storage_debug_info() {
    echo "=== Storage Configuration Debug Information ==="
    echo ""

    # Show pvesm status output
    log_info "Active storage from 'pvesm status':"
    pvesm status | grep "active" | while read -r LINE; do
        local STORAGE_NAME=$(echo "$LINE" | awk '{print $1}')
        local STORAGE_TYPE=$(echo "$LINE" | awk '{print $2}')
        local STORAGE_AVAIL=$(echo "$LINE" | awk '{print $6}')
        echo "  ${STORAGE_NAME} (${STORAGE_TYPE}) - Available: ${STORAGE_AVAIL}"
    done
    echo ""

    # Show storage.cfg content types
    if [[ -f "/etc/pve/storage.cfg" ]]; then
                log_info "Storage content types from '/etc/pve/storage.cfg':"
        awk '
            /^[a-zA-Z]+: / {
                # Output previous storage info
                if (storage_name) {
                    status = disabled ? " (DISABLED)" : ""
                    printf "  %s: %s%s\n", storage_name, content ? content : "no content specified", status
                }
                # Start new storage
                storage_type = $1
                storage_name = $2
                disabled = 0
                content = ""
            }
                        /^[[:space:]]*disable[[:space:]]*$/ { disabled = 1 }
            /^[[:space:]]*content[[:space:]]/ {
                content = $0
                gsub(/^[[:space:]]*content[[:space:]]*/, "", content)
            }
            END {
                # Output the last storage
                if (storage_name) {
                    status = disabled ? " (DISABLED)" : ""
                    printf "  %s: %s%s\n", storage_name, content ? content : "no content specified", status
                }
            }
        ' /etc/pve/storage.cfg
    else
        log_warning "Cannot read /etc/pve/storage.cfg"
    fi
    echo ""

    # Check specific content type support for active storage
    log_info "Container support (rootdir) check:"
    pvesm status | grep "active" | while read -r LINE; do
        local STORAGE_NAME=$(echo "$LINE" | awk '{print $1}')
        if check_storage_content_support "${STORAGE_NAME}" "rootdir"; then
            echo "  ✓ ${STORAGE_NAME} supports containers"
        else
            echo "  ✗ ${STORAGE_NAME} does not support containers"
        fi
    done
    echo ""

    log_info "Template support (vztmpl) check:"
    pvesm status | grep "active" | while read -r LINE; do
        local STORAGE_NAME=$(echo "$LINE" | awk '{print $1}')
        if check_storage_content_support "${STORAGE_NAME}" "vztmpl"; then
            echo "  ✓ ${STORAGE_NAME} supports templates"
        else
            echo "  ✗ ${STORAGE_NAME} does not support templates"
        fi
    done
    echo ""
}

# Detect and validate storage
detect_storage() {
    # Detect container storage
    if [[ -n "${STORAGE}" ]]; then
        log_info "Using specified container storage: ${STORAGE}"

        # Verify the storage exists and is active
        if ! pvesm status | grep -q "^${STORAGE}.*active"; then
            log_error "Container storage '${STORAGE}' is not found or not active"
            log_info "Available active storage:"
            pvesm status | grep "active" | awk '{print "  " $1 " (" $2 ")"}'
            exit 1
        fi

        # Check if storage supports containers (rootdir content)
        if ! check_storage_content_support "${STORAGE}" "rootdir"; then
            log_warning "Storage '${STORAGE}' may not support LXC containers"
            log_info "This storage will be used anyway as explicitly specified"
        fi
    else
        log_info "No container storage specified, detecting available storage..."
        detect_container_storage
    fi

    # Detect template storage
    if [[ -n "${TEMPLATE_STORAGE}" ]]; then
        log_info "Using specified template storage: ${TEMPLATE_STORAGE}"

        # Verify the storage exists and is active
        if ! pvesm status | grep -q "^${TEMPLATE_STORAGE}.*active"; then
            log_error "Template storage '${TEMPLATE_STORAGE}' is not found or not active"
            log_info "Available active storage:"
            pvesm status | grep "active" | awk '{print "  " $1 " (" $2 ")"}'
            exit 1
        fi

        # Check if storage supports templates (vztmpl content)
        if ! check_storage_content_support "${TEMPLATE_STORAGE}" "vztmpl"; then
            log_error "Template storage '${TEMPLATE_STORAGE}' does not support LXC templates (vztmpl content)"
            log_info "Please choose a different storage for templates or omit --template-storage to auto-detect"
            exit 1
        fi
    else
        log_info "No template storage specified, detecting available template storage..."
        detect_template_storage
    fi

    log_success "Storage configuration:"
    log_success "  Container storage: ${STORAGE}"
    log_success "  Template storage: ${TEMPLATE_STORAGE}"
}

# Detect container storage
detect_container_storage() {
    # Get list of active storage
    local ACTIVE_STORAGE=($(pvesm status | grep "active" | awk '{print $1}'))

    if [[ ${#ACTIVE_STORAGE[@]} -eq 0 ]]; then
        log_error "No active storage found"
        log_info "Available storage:"
        pvesm status | awk 'NR>1 {print "  " $1 " (" $2 ", " $3 ")"}'
        exit 1
    fi

    # Filter storage that supports containers
    local CONTAINER_STORAGE=()
    for STORAGE in "${ACTIVE_STORAGE[@]}"; do
        if check_storage_content_support "${STORAGE}" "rootdir"; then
            CONTAINER_STORAGE+=("${STORAGE}")
        fi
    done

    if [[ ${#CONTAINER_STORAGE[@]} -eq 0 ]]; then
        log_error "No active storage found that supports LXC containers"
        log_info "Available active storage (may not support containers):"
        for STORAGE in "${ACTIVE_STORAGE[@]}"; do
            local STORAGE_INFO=$(pvesm status | grep "^${STORAGE}")
            local STORAGE_TYPE=$(echo "$STORAGE_INFO" | awk '{print $2}')
            local STORAGE_AVAIL=$(echo "$STORAGE_INFO" | awk '{print $6}')
            echo "  ${STORAGE} (${STORAGE_TYPE}) - Available: ${STORAGE_AVAIL}"
        done
        echo ""
        log_info "You can force using a storage with: --storage <name>"
        exit 1
    elif [[ ${#CONTAINER_STORAGE[@]} -eq 1 ]]; then
        STORAGE="${CONTAINER_STORAGE[0]}"
        log_success "Auto-selected container storage: ${STORAGE}"
    else
        log_error "Multiple active storage found that support containers. Please specify which one to use."
        echo ""
        log_info "Available container-compatible storage:"
        log_info "Available container-compatible storage:"
        for STORAGE in "${CONTAINER_STORAGE[@]}"; do
            local STORAGE_INFO=$(pvesm status | grep "^${STORAGE}")
            local STORAGE_TYPE=$(echo "$STORAGE_INFO" | awk '{print $2}')
            local STORAGE_AVAIL=$(echo "$STORAGE_INFO" | awk '{print $6}')
            echo "  ${STORAGE} (${STORAGE_TYPE}) - Available: ${STORAGE_AVAIL}"
        done
        echo ""
        log_info "Use one of these commands:"
        log_info "  STORAGE=<name> $0 [other options]"
        log_info "  $0 --storage <name> [other options]"
        echo ""
        log_info "Example: $0 --storage ${CONTAINER_STORAGE[0]}"
        exit 1
    fi
}

# Detect template storage
detect_template_storage() {
    # Get list of active storage
    local ACTIVE_STORAGE=($(pvesm status | grep "active" | awk '{print $1}'))

    # Filter storage that supports templates
    local TEMPLATE_STORAGE_LIST=()
    for STORAGE in "${ACTIVE_STORAGE[@]}"; do
        if check_storage_content_support "${STORAGE}" "vztmpl"; then
            TEMPLATE_STORAGE_LIST+=("${STORAGE}")
        fi
    done

    if [[ ${#TEMPLATE_STORAGE_LIST[@]} -eq 0 ]]; then
        log_error "No active storage found that supports LXC templates"
        log_info "Available active storage (may not support templates):"
        for STORAGE in "${ACTIVE_STORAGE[@]}"; do
            local STORAGE_INFO=$(pvesm status | grep "^${STORAGE}")
            local STORAGE_TYPE=$(echo "$STORAGE_INFO" | awk '{print $2}')
            local STORAGE_AVAIL=$(echo "$STORAGE_INFO" | awk '{print $6}')
            echo "  ${STORAGE} (${STORAGE_TYPE}) - Available: ${STORAGE_AVAIL}"
        done
        echo ""
        log_info "You can force using a storage with: --template-storage <name>"
        exit 1
    elif [[ ${#TEMPLATE_STORAGE_LIST[@]} -eq 1 ]]; then
        TEMPLATE_STORAGE="${TEMPLATE_STORAGE_LIST[0]}"
        log_success "Auto-selected template storage: ${TEMPLATE_STORAGE}"
    else
        # If container storage is set and supports templates, prefer it
        if [[ -n "${STORAGE}" ]] && check_storage_content_support "${STORAGE}" "vztmpl"; then
            TEMPLATE_STORAGE="${STORAGE}"
            log_success "Using container storage for templates: ${TEMPLATE_STORAGE}"
            return
        fi

        log_error "Multiple active storage found that support templates. Please specify which one to use."
        echo ""
        log_info "Available template-compatible storage:"
        log_info "Available template-compatible storage:"
        for STORAGE in "${TEMPLATE_STORAGE_LIST[@]}"; do
            local STORAGE_INFO=$(pvesm status | grep "^${STORAGE}")
            local STORAGE_TYPE=$(echo "$STORAGE_INFO" | awk '{print $2}')
            local STORAGE_AVAIL=$(echo "$STORAGE_INFO" | awk '{print $6}')
            echo "  ${STORAGE} (${STORAGE_TYPE}) - Available: ${STORAGE_AVAIL}"
        done
        echo ""
        log_info "Use one of these commands:"
        log_info "  TEMPLATE_STORAGE=<name> $0 [other options]"
        log_info "  $0 --template-storage <name> [other options]"
        echo ""
        log_info "Example: $0 --template-storage ${TEMPLATE_STORAGE_LIST[0]}"
        exit 1
    fi
}

# Find next available container ID
find_next_container_id() {
    log_info "Finding next available container ID..."

    # Get list of existing container and VM IDs
    local USED_IDS=($(pvesh get /cluster/resources --type vm --output-format json | jq -r '.[].vmid' 2>/dev/null))

    # If jq is not available, use alternative method
    if [[ ${#USED_IDS[@]} -eq 0 ]]; then
        # Try using pct list and qm list
        USED_IDS+=($(pct list | awk 'NR>1 {print $1}' 2>/dev/null))
        USED_IDS+=($(qm list | awk 'NR>1 {print $1}' 2>/dev/null))
    fi

    # Sort the IDs
    if [[ ${#USED_IDS[@]} -gt 0 ]]; then
        IFS=$'\n' USED_IDS=($(sort -n <<<"${USED_IDS[*]}"))
    fi

    log_info "Currently used IDs: ${USED_IDS[*]:-none}"

    # Find the first available ID starting from 100
    local NEXT_ID=100
    for USED_ID in "${USED_IDS[@]}"; do
        if [[ $NEXT_ID -eq $USED_ID ]]; then
            ((NEXT_ID++))
        fi
    done

    CONTAINER_ID=$NEXT_ID
    log_success "Using container ID: ${CONTAINER_ID}"
}

# Check if container ID is already in use (now only used for manual override)
check_container_exists() {
    if [[ -n "${CONTAINER_ID_OVERRIDE:-}" ]] && pct list | grep -q "^${CONTAINER_ID_OVERRIDE}"; then
        log_error "Container ID ${CONTAINER_ID_OVERRIDE} already exists"
        log_info "Please choose a different container ID or remove the existing container"
        exit 1
    fi
}

# Download Fedora template if not available
download_template() {
    log_info "Checking for Fedora template '${TEMPLATE_NAME}' on storage '${TEMPLATE_STORAGE}'..."

    if ! pveam list "${TEMPLATE_STORAGE}" | grep -q "${TEMPLATE_NAME}"; then
        log_info "Fedora template '${TEMPLATE_NAME}' not found on '${TEMPLATE_STORAGE}'..."

        log_info "Downloading Fedora template '${TEMPLATE_NAME}' to '${TEMPLATE_STORAGE}'..."
        pveam download "${TEMPLATE_STORAGE}" "${TEMPLATE_NAME}"
        log_success "Template '${TEMPLATE_NAME}' downloaded successfully to '${TEMPLATE_STORAGE}'"
    else
        log_success "Fedora template '${TEMPLATE_NAME}' already available on '${TEMPLATE_STORAGE}'"
    fi
}

# Create host directories
create_host_directories() {
    log_info "Creating host directories..."

    # Create snippets directory
    mkdir -p /var/quickvm
    chown -R 100000:100000 /var/quickvm
    chmod 755 /var/quickvm

    # Add snippets directory to Proxmox storage
    log_info "Adding snippets directory to Proxmox storage as 'quickvm'..."
    if pvesm status | grep -q "^quickvm"; then
        log_info "Storage 'quickvm' already exists, skipping creation"
    else
        pvesm add dir quickvm --path /var/quickvm --content snippets
        log_success "Storage 'quickvm' created successfully"
    fi

    # Create QuickVM config directory
    mkdir -p /etc/quickvm/certs
    chown -R 100000:100000 /etc/quickvm
    chmod 755 /etc/quickvm
    chmod 755 /etc/quickvm/certs

    log_success "Host directories created and configured"
}

# Create LXC container
create_container() {
    # Get MAC address for container
    local MAC_ADDRESS=$(get_mac_address)

    # Log MAC address information
    local EXISTING_MAC=$(read_existing_mac)
    if [[ -n "${EXISTING_MAC}" ]]; then
        log_info "Using existing MAC address: ${MAC_ADDRESS}"
    else
        log_info "Generated new MAC address: ${MAC_ADDRESS}"
    fi

    # Store MAC address for future use
    store_mac_address "${MAC_ADDRESS}"

    # Determine network configuration
    local NET_CONFIG=""
    # Create container with dynamic network configuration
    if [[ -n "${IP_ADDRESS}" && -n "${GATEWAY}" ]]; then
        NET_CONFIG="name=eth0,bridge=${BRIDGE},gw=${GATEWAY},ip=${IP_ADDRESS},firewall=1,hwaddr=${MAC_ADDRESS}"
    else
        NET_CONFIG="name=eth0,bridge=${BRIDGE},firewall=1,hwaddr=${MAC_ADDRESS}"
    fi

    # Create container with bridged networking
    pct create "${CONTAINER_ID}" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_NAME}" \
        --hostname "${CONTAINER_NAME}" \
        --memory "${MEMORY}" \
        --cores "${CORES}" \
        --rootfs "${STORAGE}:${ROOTFS_SIZE}" \
        --net0 "${NET_CONFIG}" \
        --nameserver 1.1.1.1 \
        --nameserver 8.8.8.8 \
        --onboot 1 \
        --unprivileged 1 \
        --features nesting=1

    log_success "Container created successfully with bridged networking and MAC address ${MAC_ADDRESS}"
}

# Configure container bind mounts
configure_bind_mounts() {
    log_info "Configuring bind mounts..."

    # Add bind mounts
    pct set "${CONTAINER_ID}" -mp0 "/var/quickvm,mp=/var/quickvm,acl=1"
    pct set "${CONTAINER_ID}" -mp1 "/etc/quickvm,mp=/etc/quickvm,acl=1"

    log_success "Bind mounts configured"
}

# Start container
start_container() {
    log_info "Starting container..."
    pct start "${CONTAINER_ID}"

    # Wait for container to be ready
    log_info "Waiting for container to be ready..."
    sleep 10

    # Wait for network to be available
    local MAX_ATTEMPTS=30
    local ATTEMPT=1

    while ! pct exec "${CONTAINER_ID}" -- ping -c 1 8.8.8.8 &>/dev/null; do
        if [[ $ATTEMPT -ge $MAX_ATTEMPTS ]]; then
            log_error "Container network not ready after ${MAX_ATTEMPTS} attempts"
            exit 1
        fi
        log_info "Waiting for network... (attempt $ATTEMPT/$MAX_ATTEMPTS)"
        sleep 2
        ((ATTEMPT++))
    done

    log_success "Container started and network is ready"
}

# Update system and install packages
setup_container_packages() {
    log_info "Updating system and installing packages..."

    # Update system
    pct exec "${CONTAINER_ID}" -- dnf update -y

    # Install required packages (podman should already be available in Fedora 42)
    pct exec "${CONTAINER_ID}" -- dnf install -y --setopt=install_weak_deps=False podman curl firewalld

    # Enable and start firewalld
    pct exec "${CONTAINER_ID}" -- systemctl enable firewalld
    pct exec "${CONTAINER_ID}" -- systemctl start firewalld

    log_success "Packages installed and configured"
}

# Configure firewall
configure_firewall() {
    log_info "Configuring firewall..."

    # Open port 8071
    pct exec "${CONTAINER_ID}" -- firewall-cmd --permanent --add-port=${HOST_PORT}/tcp
    pct exec "${CONTAINER_ID}" -- firewall-cmd --reload

    log_success "Firewall configured - port ${HOST_PORT} opened"
}

# Configure Proxmox node port access
configure_node_access() {
    log_info "Configuring Proxmox node access for port ${HOST_PORT}..."

    # Get container IP address for reference
    local CONTAINER_IP_LOCAL=""
    local MAX_ATTEMPTS_LOCAL=10
    local ATTEMPT_LOCAL=1

    while [[ -z "${CONTAINER_IP_LOCAL}" && $ATTEMPT_LOCAL -le $MAX_ATTEMPTS_LOCAL ]]; do
        CONTAINER_IP_LOCAL=$(pct exec "${CONTAINER_ID}" -- ip addr show eth0 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -n1 2>/dev/null || true)
        if [[ -z "${CONTAINER_IP_LOCAL}" ]]; then
            log_info "Waiting for container network... (attempt $ATTEMPT_LOCAL/$MAX_ATTEMPTS_LOCAL)"
            sleep 5
            ((ATTEMPT_LOCAL++))
        fi
    done

    if [[ -z "${CONTAINER_IP}" ]]; then
        log_warning "Could not determine container IP address - skipping node access configuration"
        return 0
    fi

    log_info "Container IP: ${CONTAINER_IP}"

    # Create firewall directory if it doesn't exist
    mkdir -p /etc/pve/firewall

    # Create node-specific firewall rules to allow access to the port
    local NODE_FW_FILE_LOCAL="/etc/pve/nodes/${CURRENT_NODE}/host.fw"

    # Backup existing firewall file if it exists
    if [[ -f "${NODE_FW_FILE_LOCAL}" ]]; then
        cp "${NODE_FW_FILE_LOCAL}" "${NODE_FW_FILE_LOCAL}.backup.$(date +%Y%m%d%H%M%S)"
        log_info "Backed up existing node firewall configuration"
    fi

    # Create nodes directory if it doesn't exist
    mkdir -p "/etc/pve/nodes/${CURRENT_NODE}"

    # Check if our rule already exists
    local RULE_EXISTS_LOCAL=false
    if [[ -f "${NODE_FW_FILE_LOCAL}" ]] && grep -q "quickvm-provider-${HOST_PORT}" "${NODE_FW_FILE_LOCAL}"; then
        RULE_EXISTS_LOCAL=true
    fi

    log_info "Configuring node firewall to allow access to port ${HOST_PORT}"

    # Create or update the firewall configuration
    if [[ "${RULE_EXISTS_LOCAL}" == "true" ]]; then
        # Update existing rule by removing old one and adding new one
        sed -i "/# quickvm-provider-${HOST_PORT}/,+1d" "${NODE_FW_FILE_LOCAL}"
    fi

    # Add the node access rule
    {
        if [[ ! -f "${NODE_FW_FILE}" ]] || ! grep -q "^\[OPTIONS\]" "${NODE_FW_FILE}"; then
            echo "[OPTIONS]"
            echo "enable: 1"
            echo ""
        fi

        if ! grep -q "^\[RULES\]" "${NODE_FW_FILE}" 2>/dev/null; then
            echo "[RULES]"
        fi

        echo "# quickvm-provider-${HOST_PORT}"
        echo "IN ACCEPT -p tcp --dport ${HOST_PORT} -source +management"
    } >> "${NODE_FW_FILE}"

    # Setup port forwarding using iptables (persistent approach)
    log_info "Setting up persistent port forwarding..."

    # Create a helper script that reads config dynamically
    cat > "/usr/local/bin/quickvm-port-forward.sh" << 'EOF'
#!/bin/bash
# QuickVM Port Forwarding Helper Script
# Reads configuration from container environment and sets up iptables rules

CONFIG_FILE="/etc/quickvm/quickvm-provider.env"
CONTAINER_NAME="quickvm-provider"

# Function to get container IP
get_container_ip() {
    local CONTAINER_ID_LOCAL=$(pct list | grep "${CONTAINER_NAME}" | awk '{print $1}' | head -n1)
    if [[ -n "${CONTAINER_ID_LOCAL}" ]]; then
        pct exec "${CONTAINER_ID_LOCAL}" -- ip addr show eth0 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -n1 2>/dev/null || true
    fi
}

# Function to read port from config
get_port() {
    if [[ -f "${CONFIG_FILE}" ]]; then
        grep "^PORT=" "${CONFIG_FILE}" | cut -d'=' -f2 | tr -d ' '
    else
        echo "8071"  # Default fallback
    fi
}

# Function to get IPs from specified interfaces or auto-detect
get_forwarding_ips() {
    local INTERFACES=""

    # Read interfaces from config file
    if [[ -f "${CONFIG_FILE}" ]]; then
        INTERFACES=$(grep "^INTERFACES=" "${CONFIG_FILE}" 2>/dev/null | cut -d'=' -f2 | tr -d ' ' || true)
    fi

    # If no interfaces specified, use legacy behavior (vmbr0 or hostname -I)
    if [[ -z "${INTERFACES}" ]]; then
        local CLUSTER_IP=$(pvesh get /nodes/$(hostname)/network --output-format json 2>/dev/null | \
            jq -r '.[] | select(.iface == "vmbr0" and .address != null) | .address' 2>/dev/null | head -n1)

        if [[ -z "${CLUSTER_IP}" || "${CLUSTER_IP}" == "null" ]]; then
            CLUSTER_IP=$(hostname -I | awk '{print $1}')
        fi

        echo "${CLUSTER_IP}"
        return
    fi

    # Get IPs from specified interfaces
    local IP_LIST_LOCAL=""
    IFS=',' read -ra INTERFACE_ARRAY <<< "${INTERFACES}"
    for INTERFACE in "${INTERFACE_ARRAY[@]}"; do
        INTERFACE=$(echo "${INTERFACE}" | xargs)  # trim whitespace
        local IP_LOCAL=$(ip addr show "${INTERFACE}" 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -n1 || true)
        if [[ -n "${IP_LOCAL}" ]]; then
            if [[ -n "${IP_LIST_LOCAL}" ]]; then
                IP_LIST_LOCAL="${IP_LIST_LOCAL} ${IP_LOCAL}"
            else
                IP_LIST_LOCAL="${IP_LOCAL}"
            fi
        fi
    done
    echo "${IP_LIST_LOCAL}"
}

# Get current values
CONTAINER_IP=$(get_container_ip)
PORT=$(get_port)
FORWARDING_IPS=$(get_forwarding_ips)

if [[ -z "${CONTAINER_IP}" ]]; then
    echo "Error: Could not determine container IP address"
    exit 1
fi

if [[ -z "${PORT}" ]]; then
    echo "Error: Could not determine port from configuration"
    exit 1
fi

if [[ -z "${FORWARDING_IPS}" ]]; then
    echo "Error: Could not determine forwarding IP addresses"
    exit 1
fi

echo "Setting up port forwarding: ${FORWARDING_IPS}:${PORT} -> ${CONTAINER_IP}:${PORT}"

case "$1" in
    start)
        # Add DNAT rules for each forwarding IP
        IFS=',' read -ra IP_ARRAY <<< "${FORWARDING_IPS}"
        for IP in "${IP_ARRAY[@]}"; do
            IP=$(echo "${IP}" | xargs)  # trim whitespace
            echo "Adding forwarding rule for ${IP}:${PORT} -> ${CONTAINER_IP}:${PORT}"

            # Add DNAT rule scoped to this IP if it doesn't exist
            iptables -t nat -C PREROUTING -d "${IP}" -p tcp --dport "${PORT}" -j DNAT --to-destination "${CONTAINER_IP}:${PORT}" 2>/dev/null || \
            iptables -t nat -A PREROUTING -d "${IP}" -p tcp --dport "${PORT}" -j DNAT --to-destination "${CONTAINER_IP}:${PORT}"
        done

        # Add MASQUERADE rule if it doesn't exist (only need one)
        iptables -t nat -C POSTROUTING -p tcp -d "${CONTAINER_IP}" --dport "${PORT}" -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -p tcp -d "${CONTAINER_IP}" --dport "${PORT}" -j MASQUERADE
        ;;
    stop)
        # Remove rules for each forwarding IP
        IFS=',' read -ra IP_ARRAY <<< "${FORWARDING_IPS}"
        for IP in "${IP_ARRAY[@]}"; do
            IP=$(echo "${IP}" | xargs)  # trim whitespace
            echo "Removing forwarding rule for ${IP}:${PORT} -> ${CONTAINER_IP}:${PORT}"

            # Remove DNAT rule (ignore errors if rules don't exist)
            iptables -t nat -D PREROUTING -d "${IP}" -p tcp --dport "${PORT}" -j DNAT --to-destination "${CONTAINER_IP}:${PORT}" 2>/dev/null || true
        done

        # Remove MASQUERADE rule (ignore errors if rule doesn't exist)
        iptables -t nat -D POSTROUTING -p tcp -d "${CONTAINER_IP}" --dport "${PORT}" -j MASQUERADE 2>/dev/null || true
        ;;
    *)
        echo "Usage: ${0} {start|stop}"
        exit 1
        ;;
esac
EOF

    # Make the script executable
    chmod +x "/usr/local/bin/quickvm-port-forward.sh"

    # Create a systemd service for port forwarding
    cat > "/etc/systemd/system/quickvm-port-forward.service" << EOF
[Unit]
Description=QuickVM Port Forwarding
After=network.target pve-firewall.service
Requires=pve-firewall.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/quickvm-port-forward.sh start
ExecStop=/usr/local/bin/quickvm-port-forward.sh stop

[Install]
WantedBy=multi-user.target
EOF

    # Enable and start the port forwarding service
    systemctl daemon-reload
    systemctl enable "quickvm-port-forward.service"
    systemctl start "quickvm-port-forward.service"

    # Reload Proxmox firewall
    if command -v pve-firewall >/dev/null; then
        log_info "Reloading Proxmox firewall..."
        if pve-firewall compile 2>/dev/null; then
            systemctl reload pve-firewall
            log_success "Node access configured for port ${HOST_PORT}"

            # Show which interfaces are being used for port forwarding
            if [[ -n "${INTERFACES}" ]]; then
                # Get the actual IPs for the specified interfaces
                local FORWARDING_DETAILS_LOCAL=""
                IFS=',' read -ra INTERFACE_ARRAY <<< "${INTERFACES}"
                for INTERFACE in "${INTERFACE_ARRAY[@]}"; do
                    INTERFACE=$(echo "${INTERFACE}" | xargs)  # trim whitespace
                    local IP_LOCAL=$(ip addr show "${INTERFACE}" 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -n1 || true)
                    if [[ -n "${IP_LOCAL}" ]]; then
                        if [[ -n "${FORWARDING_DETAILS_LOCAL}" ]]; then
                            FORWARDING_DETAILS_LOCAL="${FORWARDING_DETAILS_LOCAL}, ${INTERFACE}:${IP_LOCAL}"
                        else
                            FORWARDING_DETAILS_LOCAL="${INTERFACE}:${IP_LOCAL}"
                        fi
                    fi
                done
                log_success "Port forwarding active on specified interfaces: ${FORWARDING_DETAILS}:${HOST_PORT} -> ${CONTAINER_IP}:${HOST_PORT}"
            else
                log_success "Port forwarding active: ${CURRENT_NODE}:${HOST_PORT} -> ${CONTAINER_IP}:${HOST_PORT}"
            fi
        else
            log_warning "Firewall compilation had warnings - but port forwarding should still work"
        fi
    else
        log_warning "pve-firewall command not found - manual firewall reload may be required"
    fi
}

# Update environment file for host networking
update_environment_for_host_network() {
    log_info "Updating environment file for host networking..."

    # Create quickvm directory for config files
    pct exec "${CONTAINER_ID}" -- mkdir -p /etc/quickvm

    # Check if config file already exists in container and has meaningful content
    local HAS_FULL_CONFIG=false
    if pct exec "${CONTAINER_ID}" -- test -f /etc/quickvm/quickvm-provider.env; then
        # Check if the file has more than just MAC/API_KEY/PORT (i.e., has ENABLE_TLS or ENVIRONMENT)
        if pct exec "${CONTAINER_ID}" -- grep -q "ENABLE_TLS\|ENVIRONMENT" /etc/quickvm/quickvm-provider.env; then
            HAS_FULL_CONFIG=true
        fi
    fi

    if [[ "${HAS_FULL_CONFIG}" == "true" ]]; then
        log_info "Existing environment file with full configuration found, preserving user configuration..."

        # Get current MAC address from host config
        local CURRENT_MAC=$(read_existing_mac)

        # Update only essential values, preserving other configuration
        if [[ -n "${CURRENT_MAC}" ]]; then
            pct exec "${CONTAINER_ID}" -- bash -c "
                # Create backup of existing config
                cp /etc/quickvm/quickvm-provider.env /etc/quickvm/quickvm-provider.env.backup

                # Update or add essential values while preserving others
                sed -i '/^MAC=/d' /etc/quickvm/quickvm-provider.env
                echo 'MAC=${CURRENT_MAC}' >> /etc/quickvm/quickvm-provider.env

                # Update API_KEY if it doesn't exist
                if ! grep -q '^API_KEY=' /etc/quickvm/quickvm-provider.env; then
                    echo 'API_KEY=${API_KEY}' >> /etc/quickvm/quickvm-provider.env
                fi

                # Update PORT if it doesn't exist
                if ! grep -q '^PORT=' /etc/quickvm/quickvm-provider.env; then
                    echo 'PORT=${HOST_PORT}' >> /etc/quickvm/quickvm-provider.env
                fi

                # Update INTERFACES if specified
                if [[ -n '${INTERFACES}' ]]; then
                    sed -i '/^INTERFACES=/d' /etc/quickvm/quickvm-provider.env
                    echo 'INTERFACES=${INTERFACES}' >> /etc/quickvm/quickvm-provider.env
                fi
            "
        fi

        # Read back the API key that's actually in the file to update our global variable
        local EXISTING_API_KEY_LOCAL=$(grep "^API_KEY=" /etc/quickvm/quickvm-provider.env | cut -d'=' -f2 | tr -d ' ')
        if [[ -n "${EXISTING_API_KEY_LOCAL}" ]]; then
            API_KEY="${EXISTING_API_KEY_LOCAL}"
            API_KEY_WAS_GENERATED=false
            log_info "Using existing API key from configuration file"
        fi

        log_info "Preserved existing configuration, updated essential values only"
    else
        # Create new environment file with all default values (or replace minimal config)
        local CURRENT_MAC=$(read_existing_mac)
        local EXISTING_API_KEY_LOCAL=""

        # Check if there's an existing API key in a minimal config file before replacing it
        if pct exec "${CONTAINER_ID}" -- test -f /etc/quickvm/quickvm-provider.env; then
            log_info "Found minimal configuration file, checking for existing API key..."
            EXISTING_API_KEY_LOCAL=$(grep "^API_KEY=" /etc/quickvm/quickvm-provider.env 2>/dev/null | cut -d'=' -f2 | tr -d ' ' || true)
            if [[ -n "${EXISTING_API_KEY_LOCAL}" ]]; then
                log_info "Found existing API key in minimal config, preserving it..."
                API_KEY="${EXISTING_API_KEY_LOCAL}"
                API_KEY_WAS_GENERATED=false
            fi
            log_info "Replacing minimal configuration with full default configuration..."
        else
            log_info "Creating new environment file with default configuration..."
        fi

        pct exec "${CONTAINER_ID}" -- bash -c "cat > /etc/quickvm/quickvm-provider.env << 'EOF'
API_KEY=${API_KEY}
ENABLE_TLS=true
ENVIRONMENT=production
WORKERS=4
TLS_GENERATE_SELF_SIGNED=true
TLS_CERT_SUBJECT=/C=US/ST=IL/L=Chicago/O=QuickVM/CN=quickvm-provider
PORT=${HOST_PORT}
MAC=${CURRENT_MAC}
EOF"

        # Add INTERFACES line separately if specified
        if [[ -n "${INTERFACES}" ]]; then
            pct exec "${CONTAINER_ID}" -- bash -c "echo 'INTERFACES=${INTERFACES}' >> /etc/quickvm/quickvm-provider.env"
        fi

        if [[ -n "${EXISTING_API_KEY}" ]]; then
            log_info "Preserved existing API key from previous configuration"
        else
            log_info "Created environment file with new API key"
        fi
    fi

    # Secure the environment file
    pct exec "${CONTAINER_ID}" -- chmod 600 /etc/quickvm/quickvm-provider.env

    log_success "Environment file updated for host networking on port ${HOST_PORT}"
}

# Create Podman Quadlet service
create_quadlet_service() {
    log_info "Creating Podman Quadlet service..."

    # Create quadlet directory
    pct exec "${CONTAINER_ID}" -- mkdir -p /etc/containers/systemd

    # Create the quadlet file
    pct exec "${CONTAINER_ID}" -- bash -c "cat > /etc/containers/systemd/quickvm-provider.container << 'EOF'
[Unit]
Description=QuickVM Provider
After=network-online.target
Wants=network-online.target

[Container]
Image=ghcr.io/quickvm/proxmox-provider/proxmox-provider:${IMAGE_TAG}
ContainerName=quickvm-provider
PublishPort=${HOST_PORT}:${HOST_PORT}
Volume=/etc/ssl/certs/ca-certificates.crt:/etc/ssl/certs/ca-certificates.crt:ro
Volume=/var/quickvm:/var/quickvm:Z
Volume=/etc/quickvm/certs:/app/certs:Z
EnvironmentFile=/etc/quickvm/quickvm-provider.env
AutoUpdate=registry

[Service]
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF"

    log_success "Quadlet service file created"
}

# Configure auto-update service
configure_auto_update() {
    if [[ "${AUTO_UPDATE}" == "true" ]]; then
        log_info "Enabling Podman auto-update service..."

        # Enable and start the podman auto-update timer
        pct exec "${CONTAINER_ID}" -- systemctl enable podman-auto-update.timer
        pct exec "${CONTAINER_ID}" -- systemctl start podman-auto-update.timer

        log_success "Podman auto-update service enabled"
        log_info "Container will check for updates daily and restart if newer images are available"
    elif [[ "${AUTO_UPDATE}" == "false" ]]; then
        log_info "Disabling Podman auto-update service..."

        # Stop and disable the podman auto-update timer if it exists
        if pct exec "${CONTAINER_ID}" -- systemctl is-enabled podman-auto-update.timer >/dev/null 2>&1; then
            pct exec "${CONTAINER_ID}" -- systemctl stop podman-auto-update.timer 2>/dev/null || true
            pct exec "${CONTAINER_ID}" -- systemctl disable podman-auto-update.timer 2>/dev/null || true
            log_success "Podman auto-update service disabled"
        else
            log_info "Podman auto-update service was not enabled"
        fi

        log_info "Container will not automatically update"
    else
        log_info "Auto-update not specified - container will not automatically update"
    fi
}

# Start the service
start_service() {
    log_info "Starting the service..."

    # Reload systemd to pick up the quadlet
    pct exec "${CONTAINER_ID}" -- systemctl daemon-reload

    # Start the service
    pct exec "${CONTAINER_ID}" -- systemctl start quickvm-provider.service || log_warning "Service failed to start"

    pct exec "${CONTAINER_ID}" -- systemctl status quickvm-provider.service --no-pager
    log_success "Service started successfully"
}

# Check service status
check_service_status() {
    log_info "Checking service status..."

    # Wait a moment for the service to start
    sleep 5

    if pct exec "${CONTAINER_ID}" -- systemctl is-active --quiet quickvm-provider.service; then
        log_success "Service is running successfully"

        # Show service status
        echo ""
        log_info "Service status:"
        pct exec "${CONTAINER_ID}" -- systemctl status quickvm-provider.service --no-pager

        # Show container logs
        echo ""
        log_info "Recent container logs:"
        pct exec "${CONTAINER_ID}" -- podman logs quickvm-provider --tail 10 2>/dev/null || log_warning "Container logs not available yet"

    else
        log_error "Service failed to start"
        echo ""
        log_info "Service status:"
        pct exec "${CONTAINER_ID}" -- systemctl status quickvm-provider.service --no-pager
        echo ""
        log_info "Service logs:"
        pct exec "${CONTAINER_ID}" -- journalctl -u quickvm-provider.service --no-pager -n 20
    fi
}

# Show completion information
show_completion_info() {
    # Get container IP address
    local CONTAINER_IP_INFO=""

    # Try to get container IP from pct exec
    if CONTAINER_IP_INFO=$(pct exec "${CONTAINER_ID}" -- ip addr show eth0 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -n1 2>/dev/null || true) && [[ -n "${CONTAINER_IP_INFO}" ]]; then
        log_info "Container has IP address: ${CONTAINER_IP_INFO}"
    else
        log_warning "Could not determine container IP address"
        CONTAINER_IP_INFO="<container-ip>"
    fi

    echo ""
    echo "=== Setup Complete ==="
    echo ""
    echo "Container ID: ${CONTAINER_ID}"
    echo "Container Name: ${CONTAINER_NAME}"
    echo "Container IP: ${CONTAINER_IP}"
    echo "MAC Address: ${STORED_MAC}"
    echo "Node: ${CURRENT_NODE}"
    echo "Node ID: ${NODE_ID}"
    echo "Service URL (via container): https://${CONTAINER_IP}:${HOST_PORT}"

    # Show interface-specific URLs if interfaces are configured
    if [[ -n "${INTERFACES}" ]]; then
        echo ""
        echo "Service URLs (via configured interfaces):"
        IFS=',' read -ra INTERFACE_ARRAY <<< "${INTERFACES}"
        for INTERFACE in "${INTERFACE_ARRAY[@]}"; do
            INTERFACE=$(echo "${INTERFACE}" | xargs)  # trim whitespace
            local IP_LOCAL=$(ip addr show "${INTERFACE}" 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -n1 || true)
            if [[ -n "${IP_LOCAL}" ]]; then
                echo "  ${INTERFACE}: https://${IP_LOCAL}:${HOST_PORT}"
            fi
        done
        echo ""
        echo "Port forwarding configured for interfaces: ${INTERFACES}"
        echo "Service is accessible via specified interfaces and directly via container IP"
    else
        echo "Service URL (via Proxmox node): https://$(hostname -I | awk '{print $1}'):${HOST_PORT}"
        echo ""
        echo "Port forwarding configured: ${CURRENT_NODE}:${HOST_PORT} -> container:${HOST_PORT}"
        echo "Service is accessible both directly via container IP and through the Proxmox node"
    fi
    echo ""
    echo "Test the service health endpoint:"
    echo "  curl -s https://${CONTAINER_IP}:${HOST_PORT}/health --insecure"
    echo "  curl -s https://$(hostname -I | awk '{print $1}'):${HOST_PORT}/health --insecure"
    echo ""
    echo "To check service status:"
    echo "  pct exec ${CONTAINER_ID} -- systemctl status quickvm-provider.service"
    echo ""
    echo "To check service logs:"
    echo "  pct exec ${CONTAINER_ID} -- journalctl -u quickvm-provider.service -f"
    echo ""
    echo "To check container logs:"
    echo "  pct exec ${CONTAINER_ID} -- podman logs quickvm-provider -f"
    echo ""
    echo "To enter the container:"
    echo "  pct enter ${CONTAINER_ID}"
    echo ""
    echo "Host directories created:"
    echo "  /var/quickvm (mounted to /var/quickvm in container)"
    echo "  /etc/quickvm (mounted to /etc/quickvm in container)"
    echo ""

    if [[ "${API_KEY_WAS_GENERATED}" == "true" ]]; then
        echo "Generated API Key: ${API_KEY}"
        echo "This API key has been automatically configured in the container."
        echo "Save this key securely - it will be required for API access."
    else
        echo "Using API Key: ${API_KEY}"
        echo "This API key is configured in the container."
    fi

    echo ""

    # Show API user information
    if [[ "${SKIP_API_USER}" != "true" ]]; then
        echo "=== PROXMOX API CREDENTIALS ==="
        echo "Use these credentials to configure your QuickVM proxmox provider:"
        echo ""
        echo "  Username: ${API_USERNAME}@${API_REALM}"
        echo "  Role: ${ROLE_NAME}"
        echo "  Group: ${GROUP_NAME}"
        echo ""
        if [[ -n "${API_TOKEN_ID}" ]]; then
            echo "  API Token ID: ${API_TOKEN_ID}"
            if [[ -n "${API_TOKEN_SECRET}" ]]; then
                echo "  API Token Secret: ${API_TOKEN_SECRET}"
                echo ""
                echo "IMPORTANT: Save these credentials securely!"
                echo "This API token secret is only shown once during creation."
            else
                echo "  API Token Secret: (existing token - secret not available)"
                echo ""
                echo "NOTE: Using existing API resources. If you don't have the token secret,"
                echo "you can create a new token with:"
                echo "  pveum user token remove ${API_USERNAME}@${API_REALM} quickvm"
                echo "  pveum user token add ${API_USERNAME}@${API_REALM} quickvm --privsep 0"
            fi
        else
            echo "  API Token: Failed to retrieve token information"
            echo ""
            echo "You may need to manually check your API setup with:"
            echo "  pveum user token list ${API_USERNAME}@${API_REALM}"
        fi
        echo ""
        echo "You will need these credentials to configure your QuickVM provider."
        echo ""
    else
        echo "API User Setup: Skipped"
        echo "  You will need to create the API user manually for VM management functionality."
        echo ""
    fi

    # Show MAC address information
    local STORED_MAC_INFO=$(read_existing_mac)
    echo "Container MAC address: ${STORED_MAC_INFO:-unknown}"
    echo "  (Stored in ${CONFIG_FILE})"
    echo ""

    # Add DHCP reservation info if using DHCP
    if [[ -z "${IP_ADDRESS}" || -z "${GATEWAY}" ]]; then
        log_info "DHCP CONFIGURATION:"
        echo "The container uses DHCP with a consistent MAC address (${STORED_MAC:-unknown})"
        echo "to ensure it receives the same IP address on each restart."
        echo ""
        echo "For a permanent IP assignment, configure your DHCP server"
        echo "(router/firewall) to reserve IP ${CONTAINER_IP} for MAC ${STORED_MAC:-unknown}."
        echo ""
    fi
}

# Cleanup function for errors
cleanup_on_error() {
    if [[ $? -ne 0 ]]; then
        if [[ "${DEBUG_MODE}" == "true" ]]; then
            log_error "Script failed. Debug mode enabled - leaving container for debugging..."
            echo ""
            log_info "=== DEBUG INFORMATION ==="
            log_info "Container ID: ${CONTAINER_ID:-unknown}"
            echo ""
            log_info "To debug the container:"
            echo "  pct enter ${CONTAINER_ID:-unknown}"
            echo ""
            log_info "Useful debugging commands inside the container:"
            echo "  systemctl status quickvm-provider.service"
            echo "  journalctl -u quickvm-provider.service -f"
            echo "  podman ps -a"
            echo "  podman logs quickvm-provider"
            echo "  cat /etc/containers/systemd/quickvm-provider.container"
            echo "  cat /etc/quickvm/quickvm-provider.env"
            echo ""
            log_info "Manual cleanup when debugging is complete:"
            echo "  pct stop ${CONTAINER_ID:-unknown}"
            echo "  pct destroy ${CONTAINER_ID:-unknown}"
            echo ""
        else
            log_error "Script failed. Cleaning up..."

            # Remove container if it was created
            if [[ -n "${CONTAINER_ID:-}" ]] && pct list | grep -q "^${CONTAINER_ID}"; then
                log_info "Removing container ${CONTAINER_ID}..."
                pct stop "${CONTAINER_ID}" 2>/dev/null || true
                pct destroy "${CONTAINER_ID}" 2>/dev/null || true
            fi
        fi
    fi
}

# Uninstall function
uninstall_service() {
    echo "=== Proxmox Provider Uninstaller ==="
    echo ""

    log_warning "This will remove the quickvm-provider service and clean up associated resources."
    echo ""
    log_info "The following actions will be performed:"
    echo "  1. Stop and destroy the LXC container"
    echo "  2. Remove the 'quickvm' storage definition from Proxmox"
    echo "  3. Remove container firewall configuration (if exists)"
    echo ""
    log_info "The following will NOT be removed (manual cleanup required):"
    echo "  - Host directories: /var/quickvm and /etc/quickvm"
    echo "  - Downloaded Fedora template"
    echo ""

    # Find containers with the same name
    local CONTAINERS=$(pct list | grep "${CONTAINER_NAME}" | awk '{print $1}' || true)

    if [[ -z "$CONTAINERS" ]]; then
        log_error "No ${CONTAINER_NAME} containers found."
        log_info "Use 'pct list' to see all containers."
        exit 1
    fi

    log_info "Found ${CONTAINER_NAME} container(s): $CONTAINERS"
    echo ""

    # Confirmation prompt
    read -p "Do you want to proceed with the uninstall? [y/N]: " -n 1 -r
    echo ""

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Uninstall cancelled."
        exit 0
    fi

    echo ""
    log_info "Starting uninstall process..."

    # Get storage and template information from the first container before destroying it
    local CONTAINER_STORAGE_INFO=""
    local CONTAINER_TEMPLATE_INFO=""
    local FIRST_CONTAINER=$(echo $CONTAINERS | awk '{print $1}')
    if [[ -n "$FIRST_CONTAINER" ]]; then
        # Extract storage from container config (rootfs line format: "rootfs: storage:size")
        CONTAINER_STORAGE_INFO=$(pct config "$FIRST_CONTAINER" | grep "^rootfs:" | sed 's/.*: *\([^:]*\):.*/\1/' || true)
        if [[ -n "$CONTAINER_STORAGE_INFO" ]]; then
            log_info "Detected storage from container: $CONTAINER_STORAGE_INFO"
        fi

        # Try to detect the template by looking at OS info and matching against available templates
        log_info "Attempting to detect template used for container..."
        local OS_INFO=$(pct exec "$FIRST_CONTAINER" -- cat /etc/os-release 2>/dev/null | grep '^PRETTY_NAME=' | cut -d'"' -f2 || true)
        if [[ -n "$OS_INFO" ]]; then
            log_info "Container OS: $OS_INFO"
            # Try to find matching Fedora template
            if [[ "$CONTAINER_STORAGE_INFO" != "" ]]; then
                CONTAINER_TEMPLATE_INFO=$(pveam list "$CONTAINER_STORAGE_INFO" 2>/dev/null | grep -i fedora | tail -n1 | awk '{print $1}' | cut -d':' -f2 || true)
                if [[ -n "$CONTAINER_TEMPLATE_INFO" ]]; then
                    log_info "Detected template: $CONTAINER_TEMPLATE_INFO"
                else
                    log_warning "Could not detect template from storage"
                fi
            fi
        fi
    fi

    # Process each container
    for CONTAINER_ID_ITEM in $CONTAINERS; do
        log_info "Processing container $CONTAINER_ID_ITEM..."

        # Stop container if running
        if pct status "$CONTAINER_ID_ITEM" | grep -q "running"; then
            log_info "Stopping container $CONTAINER_ID_ITEM..."
            pct stop "$CONTAINER_ID_ITEM"
        fi

        # Destroy container
        log_info "Destroying container $CONTAINER_ID_ITEM..."
        pct destroy "$CONTAINER_ID_ITEM"

        # Remove container firewall file if it exists
        local FIREWALL_FILE_LOCAL="/etc/pve/firewall/${CONTAINER_ID_ITEM}.fw"
        if [[ -f "${FIREWALL_FILE_LOCAL}" ]]; then
            log_info "Removing container firewall configuration..."
            rm -f "${FIREWALL_FILE_LOCAL}"
        fi

        # Remove node firewall rule
        local NODE_FW_LOCAL="/etc/pve/nodes/$(hostname)/host.fw"
        if [[ -f "${NODE_FW_LOCAL}" ]] && grep -q "quickvm-provider-${HOST_PORT}" "${NODE_FW_LOCAL}"; then
            log_info "Removing node firewall rule..."
            sed -i "/quickvm-provider-${HOST_PORT}/d" "${NODE_FW_LOCAL}"
        fi

        # Remove port forwarding service and helper script
        local PORT_SERVICE="quickvm-port-forward.service"
        if systemctl is-enabled "${PORT_SERVICE}" >/dev/null 2>&1; then
            log_info "Removing port forwarding service..."
            systemctl stop "${PORT_SERVICE}" 2>/dev/null || true
            systemctl disable "${PORT_SERVICE}" 2>/dev/null || true
            rm -f "/etc/systemd/system/${PORT_SERVICE}"
            rm -f "/usr/local/bin/quickvm-port-forward.sh"
            systemctl daemon-reload
        fi

        log_success "Container $CONTAINER_ID_ITEM removed successfully"
    done

    # Reload firewall if pve-firewall is available
    if command -v pve-firewall >/dev/null; then
        log_info "Reloading Proxmox firewall..."
        pve-firewall compile >/dev/null 2>&1 || log_warning "Firewall compile had warnings"
        systemctl reload pve-firewall 2>/dev/null || log_warning "Could not reload pve-firewall service"
    fi

    echo ""
    log_success "=== Uninstall Complete ==="
    echo ""
    echo "Manual cleanup still required:"
    echo "  1. Remove host directories if no longer needed:"
    echo "     rm -rf /var/quickvm"
    echo "     rm -rf /etc/quickvm"
    echo ""
    echo "  2. Remove Fedora template if no longer needed:"
    if [[ -n "$CONTAINER_STORAGE_INFO" ]]; then
        if [[ -n "$CONTAINER_TEMPLATE_INFO" ]]; then
            echo "     pveam remove $CONTAINER_STORAGE_INFO:$CONTAINER_TEMPLATE_INFO"
        else
            echo "     # Check downloaded templates with: pveam list $CONTAINER_STORAGE_INFO"
            echo "     # Remove with: pveam remove $CONTAINER_STORAGE_INFO:vztmpl/<template-name>"
        fi
    else
        echo "     # Check downloaded templates with: pveam list <storage>"
        echo "     # Remove with: pveam remove <storage>:vztmpl/<template-name>"
    fi
    echo ""
    echo "  3. Remove snippets storage if no longer needed:"
    echo "     pvesm remove quickvm"
    echo ""
    echo "  4. Remove QuickVM API user and related resources:"
    echo "     pveum user token remove ${API_USERNAME}@${API_REALM} quickvm"
    echo "     pveum acl delete / --users ${API_USERNAME}@${API_REALM} --roles ${ROLE_NAME}"
    echo "     pveum user delete ${API_USERNAME}@${API_REALM}"
    echo "     pveum role delete ${ROLE_NAME}"
    echo "     pveum group delete ${GROUP_NAME}"
}

# Main execution
main() {
    # Parse command line arguments first (which may exit for --list-interfaces)
    parse_arguments "$@"

    echo "=== QuickVM Proxmox Provider Setup ==="
    echo ""

    # Validate static IP configuration
    validate_static_ip

    # Validate interface configuration
    validate_interfaces

    # Detect and validate storage
    detect_storage

    # Handle container ID logic
    if [[ -n "${CONTAINER_ID_MANUAL}" ]]; then
        CONTAINER_ID="${CONTAINER_ID_MANUAL}"
        CONTAINER_ID_OVERRIDE="${CONTAINER_ID_MANUAL}"
        log_info "Using manual container ID: ${CONTAINER_ID}"
    else
        # Find next available container ID automatically
        find_next_container_id
        log_info "Auto-selected container ID: ${CONTAINER_ID}"
    fi

    log_info "Starting setup with the following configuration:"
    log_info "Container ID: ${CONTAINER_ID}"
    log_info "Template: ${TEMPLATE_NAME}"
    log_info "Container Storage: ${STORAGE}"
    log_info "Template Storage: ${TEMPLATE_STORAGE}"
    log_info "Memory: ${MEMORY}MB"
    log_info "CPU Cores: ${CORES}"
    log_info "Root FS Size: ${ROOTFS_SIZE}GB"
    if [[ -n "${IP_ADDRESS}" && -n "${GATEWAY}" ]]; then
        log_info "Network: Static IP ${IP_ADDRESS} via ${GATEWAY}"
    else
        log_info "Network: DHCP"
    fi
    log_info "API Key: ${API_KEY}"
    log_info "Bridge: ${BRIDGE}"
    log_info "Host Port: ${HOST_PORT}"
    if [[ -n "${INTERFACES}" ]]; then
        log_info "Port Forwarding Interfaces: ${INTERFACES}"
    else
        log_info "Port Forwarding Interfaces: auto-detect"
    fi
    log_info "Image Tag: ${IMAGE_TAG}"
    log_info "Auto Update: ${AUTO_UPDATE}"
    echo ""

    # Set up error handling
    trap cleanup_on_error EXIT

    # Execute setup steps
    check_root
    check_proxmox
    detect_cluster_config
    get_latest_fedora_template
    check_existing_containers
    check_container_exists

    # Setup API user unless skipped
    if [[ "${SKIP_API_USER}" != "true" ]]; then
        setup_api_user
    else
        log_info "Skipping API user setup (--skip-api-user flag provided)"
    fi

    download_template
    create_host_directories
    create_container
    configure_bind_mounts
    start_container
    setup_container_packages
    configure_firewall
    configure_node_access
    update_environment_for_host_network
    create_quadlet_service
    configure_auto_update
    start_service
    check_service_status
    show_completion_info

    # Disable cleanup on success
    trap - EXIT
}

# Show usage information
show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Configures your Proxmox host to work as a QuickVM Proxmox provider"
    echo ""
    echo "OPTIONS:"
    echo "  -c, --container-id ID    Container ID to use (default: auto-select next available)"
    echo "  -s, --storage NAME       Container storage to use (default: auto-detect)"
    echo "  -ts, --template-storage NAME  Template storage to use (default: auto-detect)"
    echo "  -m, --memory MB          Memory in MB (default: 2048)"
    echo "      --cpu, --cores NUM   CPU cores (default: 2)"
    echo "  -d, --disk GB            Root filesystem size in GB (default: 8)"
    echo "  -i, --ip-address IP      Static IP address in CIDR format (e.g., 192.168.1.100/24)"
    echo "  -g, --gateway IP         Gateway IP address (required with --ip-address)"
    echo "  -k, --api-key KEY        API key for the service (default: auto-generated 48-char key)"
    echo "  -b, --bridge NAME        Network bridge to use (default: vmbr0)"
    echo "  -p, --port PORT          Port on Proxmox host (default: 8071)"
    echo "  -t, --tag TAG            Container image tag (default: stable)"
    echo "      --interfaces LIST    Comma-separated list of interfaces for port forwarding (default: auto-detect)"
    echo "      --list-interfaces    Show available network interfaces and their IP addresses"
    echo "  -h, --help               Show this help message"
    echo "      --debug              Enable debug mode (leave container on failure for debugging)"
    echo "      --debug-storage      Show storage configuration debug information and exit"
    echo "      --skip-api-user      Skip API user creation (user must be created manually)"
    echo "      --auto-update [true|false]  Enable/disable automatic container updates (default: disabled)"
    echo "      --uninstall          Uninstall the service and clean up resources"
    echo ""
    echo "Environment variables (flags take precedence):"
    echo "  STORAGE          - Container storage to use"
    echo "  TEMPLATE_STORAGE - Template storage to use"
    echo "  MEMORY           - Memory in MB"
    echo "  CORES            - CPU cores"
    echo "  ROOTFS_SIZE      - Root filesystem size in GB"
    echo "  IP               - Static IP address in CIDR format"
    echo "  GATEWAY          - Gateway IP address"
    echo "  API_KEY          - API key for the service"
    echo "  BRIDGE           - Network bridge to use"
    echo "  HOST_PORT        - Port on Proxmox host"
    echo "  DEBUG            - Enable debug mode (true/false)"
    echo "  SKIP_API_USER    - Skip API user creation (true/false)"
    echo "  AUTO_UPDATE      - Enable automatic container updates (true/false)"
    echo "  INTERFACES       - Comma-separated list of interfaces for port forwarding"
    echo ""
    echo "Examples:"
    echo "  $0                                    # Use all defaults with auto-detected storage and DHCP"
    echo "  $0 --debug-storage                   # Show storage configuration and content type support"
    echo "  $0 -s local-btrfs -c 201 -m 2048     # Specific container storage and resources"
    echo "  $0 -s local-lvm -ts local             # Container on local-lvm, templates on local"
    echo "  $0 -i 192.168.1.100/24 -g 192.168.1.1  # Static IP configuration"
    echo "  $0 -s local-lvm --template-storage local --cpu 4  # Separate storage for containers and templates"
    echo "  $0 -k myapikey123 -b vmbr1           # Custom API key and bridge"
    echo "  $0 -t latest                         # Use latest image tag instead of default"
    echo "  $0 --interfaces eno1,defined1        # Forward traffic only from specific interfaces"
    echo "  $0 --list-interfaces                 # Show available network interfaces"
    echo "  $0 --debug                           # Enable debug mode (leaves container running on failure)"
    echo "  $0 --skip-api-user                   # Skip API user creation"
    echo "  $0 --auto-update                     # Enable automatic container updates (defaults to true)"
    echo "  $0 --auto-update true                # Explicitly enable automatic container updates"
    echo "  $0 --auto-update false               # Explicitly disable automatic container updates"
    echo "  IP=192.168.1.100/24 GATEWAY=192.168.1.1 $0  # Environment variables for static IP"
    echo "  TEMPLATE_STORAGE=local $0             # Use environment variable for template storage"
    echo "  AUTO_UPDATE=true $0                  # Enable auto-updates via environment variable"
    echo "  INTERFACES=eno1,defined1 $0          # Use environment variable for interface selection"
    echo "  $0 --uninstall                       # Uninstall the service and clean up"
    echo ""
    echo "Current quickvm-provider containers:"
    local QUICKVM_CONTAINERS=$(pct list | grep "${CONTAINER_NAME}" | awk '{print $1 " (" $2 ")"}'|| true)
    if [[ -n "${QUICKVM_CONTAINERS}" ]]; then
        echo "  ${QUICKVM_CONTAINERS}"
    else
        echo "  None found"
    fi
    echo ""
}

# Function to read existing MAC address from config file
read_existing_mac() {
    if [[ -f "${CONFIG_FILE}" ]]; then
        local EXISTING_MAC=$(grep "^MAC=" "${CONFIG_FILE}" 2>/dev/null | cut -d'=' -f2 | tr -d ' ')
        # Validate MAC address format before returning it
        if [[ -n "${EXISTING_MAC}" && "${EXISTING_MAC}" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]]; then
            echo "${EXISTING_MAC}"
        fi
    fi
}

# Function to generate or retrieve MAC address
get_mac_address() {
    local EXISTING_MAC=$(read_existing_mac)

    if [[ -n "${EXISTING_MAC}" ]]; then
        echo "${EXISTING_MAC}"
    else
        # Generate a random MAC address with VMware OUI (00:50:56)
        local MAC="00:50:56:$(printf "%02x:%02x:%02x" $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))"
        echo "${MAC}"
    fi
}

# Function to record MAC address in config file
# Store MAC address in config file
store_mac_address() {
    local MAC_ADDRESS="$1"

    # Validate MAC address format
    if [[ ! "${MAC_ADDRESS}" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]]; then
        log_error "Invalid MAC address format: ${MAC_ADDRESS}"
        return 1
    fi

    log_info "Recording MAC address in ${CONFIG_FILE}..."

    # Create directory if it doesn't exist
    mkdir -p "$(dirname "${CONFIG_FILE}")"

    if [[ -f "${CONFIG_FILE}" ]]; then
        # Remove any malformed MAC lines first
        sed -i '/^MAC=/d' "${CONFIG_FILE}"
        # Add clean MAC line
        echo "MAC=${MAC_ADDRESS}" >> "${CONFIG_FILE}"
        log_info "Updated MAC address in existing config file"
    else
        # Create new config file with MAC address
        echo "MAC=${MAC_ADDRESS}" > "${CONFIG_FILE}"
        chmod 600 "${CONFIG_FILE}"
        chown 100000:100000 "${CONFIG_FILE}"
        log_info "Created new config file with MAC address"
    fi
}

# Create custom role with VM management permissions
create_vm_role() {
    log_info "Creating custom role: ${ROLE_NAME}"

    # Define comprehensive VM management privileges
    local privileges=(
        # VM lifecycle management
        "VM.Allocate"       # Create/remove VMs
        "VM.Audit"          # VM Audit
        "VM.Clone"          # Clone VMs
        "VM.Config.CDROM"   # Change CD/DVD
        "VM.Config.CPU"     # Modify CPU settings
        "VM.Config.Cloudinit" # Cloud-init configuration
        "VM.Config.Disk"    # Add/modify/delete disks
        "VM.Config.HWType"  # Modify hardware type
        "VM.Config.Memory"  # Modify memory
        "VM.Config.Network" # Add/modify/delete network devices
        "VM.Config.Options" # Modify VM options
        "VM.Console"        # Access VM console
        "VM.Migrate"        # Migrate VMs
        "VM.Monitor"        # Monitor VM
        "VM.PowerMgmt"      # Start/stop/reset/shutdown VMs
        "VM.Snapshot"       # Create/delete snapshots
        "VM.Snapshot.Rollback" # Rollback snapshots

        # Storage management for VMs
        "Datastore.Allocate" # Use datastores
        "Datastore.AllocateSpace" # Allocate space on datastores
        "Datastore.Audit"    # View datastore usage
        "Datastore.AllocateTemplate" # Allocate templates
        "Sys.Modify"      # Modify system settings and use download-url
        "Sys.Audit"        # View system settings

        # Pool management (if using resource pools)
        "Pool.Allocate"     # Use resource pools

        # Node access for VM operations
        "Sys.Console"       # Access node console (needed for some operations)

	# SDN (Software Defined Network) permissions
        "SDN.Use"          # Use SDN zones and bridges
        "SDN.Audit"        # View SDN configuration
    )

    # Join privileges with comma
    local privilege_string
    privilege_string=$(IFS=','; echo "${privileges[*]}")

    # Check if role exists using JSON output and jq
    local role_exists=false
    if pveum role list --output-format json 2>/dev/null | jq -e ".[] | select(.roleid == \"${ROLE_NAME}\")" >/dev/null 2>&1; then
        role_exists=true
    fi

    # Create or update the role
    if [[ "${role_exists}" == "true" ]]; then
        log_info "Role ${ROLE_NAME} already exists, updating privileges..."
        if pveum role modify "${ROLE_NAME}" --privs "${privilege_string}" 2>/dev/null; then
            log_success "Role ${ROLE_NAME} privileges updated"
        else
            log_warning "Failed to update role privileges, but role exists"
        fi
    else
        log_info "Creating new role ${ROLE_NAME}..."
        if pveum role add "${ROLE_NAME}" --privs "${privilege_string}" 2>/dev/null; then
            log_success "Role ${ROLE_NAME} created with VM management privileges"
        else
            log_error "Failed to create role ${ROLE_NAME}"
            return 1
        fi
    fi
}

# Create group for API users
create_api_group() {
    log_info "Creating group: ${GROUP_NAME}"

    # Check if group exists using JSON output and jq
    local group_exists=false
    if pveum group list --output-format json 2>/dev/null | jq -e ".[] | select(.groupid == \"${GROUP_NAME}\")" >/dev/null 2>&1; then
        group_exists=true
    fi

    if [[ "${group_exists}" == "true" ]]; then
        log_info "Group ${GROUP_NAME} already exists, skipping creation"
    else
        log_info "Creating new group ${GROUP_NAME}..."
        if pveum group add "${GROUP_NAME}" --comment "API automation users" 2>/dev/null; then
            log_success "Group ${GROUP_NAME} created"
        else
            log_error "Failed to create group ${GROUP_NAME}"
            return 1
        fi
    fi
}

# Create API user
create_api_user() {
    local full_username="${API_USERNAME}@${API_REALM}"

    log_info "Creating API user: ${full_username}"

    # Check if user exists using JSON output and jq
    local user_exists=false
    if pveum user list --output-format json 2>/dev/null | jq -e ".[] | select(.userid == \"${full_username}\")" >/dev/null 2>&1; then
        user_exists=true
    fi

    if [[ "${user_exists}" == "true" ]]; then
        log_info "User ${full_username} already exists, skipping creation"
    else
        log_info "Creating new user ${full_username}..."
        # Create user without password (API token authentication only)
        if pveum user add "${full_username}" \
            --comment "API automation user for VM management" \
            --groups "${GROUP_NAME}" 2>/dev/null; then
            log_success "User ${full_username} created"
        else
            log_error "Failed to create user ${full_username}"
            return 1
        fi
    fi
}

# Generate API token
generate_api_token() {
    local full_username="${API_USERNAME}@${API_REALM}"
    local token_id="quickvm"

    log_info "Checking API token for user: ${full_username}"

    # Check if token already exists
    if pveum user token list "${full_username}" 2>/dev/null | grep -q "^${token_id}"; then
        log_info "API token '${token_id}' already exists for user ${full_username}"
        # Set the token ID for display even if we can't get the secret
        API_TOKEN_ID="${full_username}!${token_id}"
        log_warning "Using existing token - secret is not available (only shown during creation)"
        return 0
    fi

    log_info "Creating new API token..."

    # Generate token - use JSON output for easier parsing
    local token_output
    if token_output=$(pveum user token add "${full_username}" "${token_id}" \
        --comment "QuickVM automation token" \
        --privsep 0 \
        --output-format json 2>/dev/null); then  # privsep=0 means token has same privileges as user

        echo ""
        log_success "API Token created successfully!"

        # Parse JSON output to extract token information using jq
        API_TOKEN_ID=$(echo "$token_output" | jq -r '.["full-tokenid"]' 2>/dev/null)
        API_TOKEN_SECRET=$(echo "$token_output" | jq -r '.value' 2>/dev/null)

        # Display the token information
        echo "IMPORTANT: Save this token information securely!"
        echo ""
        if [[ -n "$API_TOKEN_ID" ]]; then
            echo "Token ID: ${API_TOKEN_ID}"
        fi
        if [[ -n "$API_TOKEN_SECRET" ]]; then
            echo "Token Secret: ${API_TOKEN_SECRET}"
        fi
        echo ""
    else
        log_warning "Failed to create API token, but continuing (token may already exist)"
        # Still set the token ID for display
        API_TOKEN_ID="${full_username}!${token_id}"
        return 0
    fi
}

# Set permissions on the root path
set_api_permissions() {
    local full_username="${API_USERNAME}@${API_REALM}"

    log_info "Setting permissions for user on root path"

    # Grant the custom role to the user on the root path
    if pveum acl modify / --users "${full_username}" --roles "${ROLE_NAME}" 2>/dev/null; then
        log_success "Permissions set for ${full_username} with role ${ROLE_NAME} on path /"
    else
        log_warning "Failed to set permissions, but continuing (permissions may already exist)"
    fi
}

# Setup API user and permissions
setup_api_user() {
    log_info "Setting up Proxmox API user for QuickVM..."

    create_vm_role
    create_api_group
    create_api_user
    set_api_permissions
    generate_api_token

    log_success "API user setup completed successfully"
}

# Run main function
main "$@"
