# QuickVM Proxmox Provider

The QuickVM Proxmox Provider enables your Proxmox VE host to work as a provider for the QuickVM service. This script automates the setup of an LXC container running the QuickVM provider service.

## Overview

The QuickVM Proxmox Provider:
- Creates and configures a Fedora LXC container
- Sets up the QuickVM provider service using containerized deployment
- Configures Proxmox API users and permissions for VM management
- Provides secure API access for VM lifecycle operations
- Supports both DHCP and static IP configuration
- Includes automatic LXC template download and resource allocation

## But why?

While Proxmox VE offers comprehensive VM and container management capabilities, it lacks a dedicated API for programmatic snippet management. This provider bridges that functionality gap, so QuickVM can provision Fedora CoreOS to your Proxmox cluster. It was either this or doing snippit uploads via SSH... we all know we don't want that.

We also wanted to have a quick way to create an API user that we can use to configure a Proxmox provider in QuickVM. This provider installer does that too.

## Prerequisites

- **Proxmox VE** cluster or standalone host
- **Root access** to the Proxmox host
- **Active storage** for container creation
- **Internet connectivity** for downloading templates and container images

### Required Proxmox Tools
The script requires the following Proxmox tools (typically pre-installed):
- `pveum` - Proxmox user management
- `pct` - Proxmox container toolkit
- `pveam` - Proxmox appliance manager
- `pvesm` - Proxmox storage manager

## Installation

### Quick Start (Recommended)

For most installations, simply run the script with default settings as the root user on your Proxmox cluster:

```bash
# Download and make executable
wget https://raw.githubusercontent.com/quickvm/proxmox-provider/refs/heads/master/quickvm-proxmox-provider.sh
chmod +x quickvm-proxmox-provider.sh

# Run with defaults (auto-detects storage, uses DHCP)
sudo ./quickvm-proxmox-provider.sh
```

### Basic Installation Options

#### Specify Storage
```bash
# Use specific storage
sudo ./quickvm-proxmox-provider.sh --storage local-lvm

# Or use environment variable
STORAGE=local-btrfs sudo ./quickvm-proxmox-provider.sh
```

#### Configure Resources
```bash
# Custom memory, CPU, and disk
sudo ./quickvm-proxmox-provider.sh --memory 4096 --cores 4 --disk 16
```

#### Static IP Configuration
```bash
# Static IP (both IP and gateway required)
sudo ./quickvm-proxmox-provider.sh \
  --ip-address 192.168.1.100/24 \
  --gateway 192.168.1.1
```

## Configuration Options

### Command Line Arguments

| Option | Environment Variable | Default | Description |
|--------|---------------------|---------|-------------|
| `-c, --container-id ID` | - | Auto-select | Container ID to use |
| `-s, --storage NAME` | `STORAGE` | Auto-detect | Storage pool to use |
| `-m, --memory MB` | `MEMORY` | 2048 | Memory allocation in MB |
| `--cpu, --cores NUM` | `CORES` | 2 | CPU core allocation |
| `-d, --disk GB` | `ROOTFS_SIZE` | 8 | Root filesystem size in GB |
| `-i, --ip-address IP` | `IP` | DHCP | Static IP in CIDR format |
| `-g, --gateway IP` | `GATEWAY` | - | Gateway IP (required with static IP) |
| `-k, --api-key KEY` | `API_KEY` | Auto-generated | API key for the service |
| `-b, --bridge NAME` | `BRIDGE` | vmbr0 | Network bridge to use |
| `-p, --port PORT` | `HOST_PORT` | 8071 | Host port for the service |
| `-t, --tag TAG` | - | sha-0760b32 | Container image tag |

### Special Options

| Option | Description |
|--------|-------------|
| `--debug` | Enable debug mode (leaves container on failure) |
| `--skip-api-user` | Skip API user creation (manual setup required) |
| `--uninstall` | Remove the service and clean up resources |
| `-h, --help` | Show detailed help and current VM/Container IDs |

## Installation Examples

### Basic Installation
```bash
# Minimal installation with auto-detection
sudo ./quickvm-proxmox-provider.sh
```

### Production Installation
```bash
# Production setup with specific resources and static IP
sudo ./quickvm-proxmox-provider.sh \
  --storage local-lvm \
  --memory 4096 \
  --cores 4 \
  --disk 20 \
  --ip-address 10.0.1.50/24 \
  --gateway 10.0.1.1 \
  --bridge vmbr1
```

### Development Installation
```bash
# Development setup with debug mode
sudo ./quickvm-proxmox-provider.sh \
  --memory 1024 \
  --cores 1 \
  --debug \
  --tag latest
```

### Custom API Key
```bash
# Use custom API key
sudo ./quickvm-proxmox-provider.sh \
  --api-key "your-secure-48-character-api-key-here-123456789"
```

## What the Installation Does

### 1. System Preparation
- Validates Proxmox environment and dependencies
- Detects and validates storage configuration
- Finds the next available container ID
- Downloads the latest Fedora template if needed

### 2. Proxmox API Setup
- Creates a custom `quickvm` role with VM management permissions
- Creates a `quickvm` group for API users
- Creates a `quickvm@pve` user account
- Generates API tokens for secure authentication
- Sets appropriate permissions on the root path

### 3. Container Creation
- Creates a Fedora LXC container with specified resources
- Configures network settings (DHCP or static IP)
- Sets up bind mounts for persistent storage
- Configures container for the QuickVM service

### 4. Service Configuration
- Installs required packages (Podman, systemd, etc.)
- Creates systemd service using Quadlet
- Configures firewall rules
- Starts and enables the QuickVM provider service

### 5. Resource Management
- Creates host directories for data persistence
- Sets up proper ownership and permissions
- Configures storage mappings between host and container

## Post-Installation

After successful installation, the script will display:

1. **Container Information**: ID, IP address, resource allocation
2. **API Token Details**: Token ID and secret (save securely!)
3. **Service Status**: Confirmation that the service is running
4. **Access Information**: How to connect to the provider

### Verification

Check that the service is running:
```bash
# Check container status
sudo pct list | grep quickvm-provider

# Check service status inside container
sudo pct exec <container-id> -- systemctl status quickvm-provider

# Check service accessibility
curl -k https://<container-ip>:8071/health
```

## Networking

### DHCP Configuration (Default)
The container will automatically receive an IP address from your network's DHCP server.

### Static IP Configuration
When using static IP, both `--ip-address` and `--gateway` must be specified:
```bash
sudo ./quickvm-proxmox-provider.sh \
  --ip-address 192.168.1.100/24 \
  --gateway 192.168.1.1
```

### Firewall
The installation automatically configures firewall rules to allow:
- Inbound connections on the specified port (default: 8071)
- Required VM management operations

## Storage Requirements

### Automatic Detection
If only one active storage pool exists, it will be automatically selected.

### Manual Selection
For multiple storage pools, specify which one to use:
```bash
# List available storage
sudo pvesm status

# Use specific storage
sudo ./quickvm-proxmox-provider.sh --storage local-lvm
```

## Troubleshooting

### Common Issues

#### 1. Storage Detection Failure
```bash
# Check available storage
sudo pvesm status

# Specify storage manually
sudo ./quickvm-proxmox-provider.sh --storage <storage-name>
```

#### 2. Container ID Conflicts
```bash
# Check existing containers
sudo pct list

# Use specific container ID
sudo ./quickvm-proxmox-provider.sh --container-id 150
```

#### 3. Network Configuration Issues
```bash
# Verify bridge exists
ip link show vmbr0

# Use different bridge
sudo ./quickvm-proxmox-provider.sh --bridge vmbr1
```

#### 4. Template Download Issues
```bash
# Update template list manually
sudo pveam update

# Check available templates
sudo pveam available | grep -i fedora
```

### Debug Mode
Enable debug mode to keep the container running on failure for troubleshooting:
```bash
sudo ./quickvm-proxmox-provider.sh --debug
```

## Uninstallation

To remove the QuickVM Proxmox Provider:

```bash
# Complete cleanup
sudo ./quickvm-proxmox-provider.sh --uninstall
```

This will:
- Stop and remove the container
- Clean up API users and roles
- Remove host directories and configurations
- Clean up firewall rules

## Security Considerations

### API Security
- API tokens are automatically generated with 48-character complexity
- Users are created with minimal required permissions
- Token secrets are only displayed during initial creation

### Network Security
- Service runs on HTTPS with TLS encryption
- Firewall rules restrict access to the service port only
- Container isolation provides additional security boundaries

### Storage Security
- Container uses unprivileged mode by default
- Host directories have restricted permissions
- Data persistence is isolated to designated directories

## Support

For issues and questions:
1. Check the troubleshooting section above
2. Review the installation logs for error messages
3. Use `--debug` mode for detailed troubleshooting
4. Verify all prerequisites are met

## License

Copyright (c) 2025 QuickVM, LLC. All rights reserved.
