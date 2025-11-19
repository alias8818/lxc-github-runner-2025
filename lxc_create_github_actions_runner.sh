#!/usr/bin/env bash

# This script automates the creation and registration of a Github self-hosted runner within a Proxmox LXC (Linux Container).
# The runner is based on Ubuntu 24.04 LTS. Before running the script, ensure you have your GITHUB_TOKEN
# and the OWNERREPO (github owner/repository) available.
#
# SECURITY WARNING: This creates a PRIVILEGED container with Docker support. Only use with trusted code/repositories.

set -euo pipefail

# Container cleanup tracking
CONTAINER_CREATED=0
PCTID=""

# Cleanup function - destroys container on script failure
cleanup_on_error() {
    local exit_code=$?
    if [ $exit_code -ne 0 ] && [ $CONTAINER_CREATED -eq 1 ] && [ -n "$PCTID" ]; then
        echo ""
        error "Script failed with exit code $exit_code. Cleaning up container $PCTID..."
        pct stop "$PCTID" 2>/dev/null || true
        pct destroy "$PCTID" 2>/dev/null || true
        error "Container $PCTID has been destroyed"
    fi
}

# Set trap for cleanup on error
trap cleanup_on_error EXIT

# Variables
GITHUB_RUNNER_VERSION="2.329.0"
GITHUB_RUNNER_URL="https://github.com/actions/runner/releases/download/v${GITHUB_RUNNER_VERSION}/actions-runner-linux-x64-${GITHUB_RUNNER_VERSION}.tar.gz"
GITHUB_RUNNER_SHA256="194f1e1e4bd02f80b7e9633fc546084d8d4e19f3928a324d512ea53430102e1d"
TEMPL_URL="http://download.proxmox.com/images/system/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
PCTSIZE="20G"
PCT_ARCH="amd64"
PCT_CORES="4"
PCT_MEMORY="4096"
PCT_SWAP="4096"
DEFAULT_STORAGE="local-lvm"
DEFAULT_BRIDGE="vmbr0"
USE_DHCP="yes"  # Set to "no" to use static IP configuration
DEFAULT_IP_ADDR="192.168.0.132/24"
DEFAULT_GATEWAY="192.168.0.1"
DEFAULT_DNS_SERVER="1.1.1.1"

# Parse command-line arguments
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Creates a GitHub Actions self-hosted runner in an LXC container on Proxmox.

RUNNER SCOPE:
    Repository-level (default):
        --user <username> --repo <repository>

    Organization-level:
        --org <organization>

OPTIONS:
    --user <username>       GitHub username (for repo-level runners)
    --repo <repository>     GitHub repository name (for repo-level runners)
    --org <organization>    GitHub organization (for org-level runners)
    --token <token>         GitHub Personal Access Token
    --storage <storage>     Proxmox storage backend (default: $DEFAULT_STORAGE)
    --bridge <bridge>       Network bridge (default: $DEFAULT_BRIDGE)
    --dns <dns>             DNS server (default: $DEFAULT_DNS_SERVER)
    -h, --help              Show this help message

EXAMPLES:
    # Interactive mode (will prompt for missing values)
    $0

    # Repository-level runner
    $0 --user alias8818 --repo BarrierClone --token ghp_xxxxx

    # Organization-level runner (available to all repos in org)
    $0 --org alias8818 --token ghp_xxxxx

    # Partial automation
    $0 --user alias8818 --repo BarrierClone --storage pve_storage
EOF
}

GITHUB_USER=""
GITHUB_REPO=""
GITHUB_ORG=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --user)
            GITHUB_USER="$2"
            shift 2
            ;;
        --repo)
            GITHUB_REPO="$2"
            shift 2
            ;;
        --org)
            GITHUB_ORG="$2"
            shift 2
            ;;
        --token)
            GITHUB_TOKEN="$2"
            shift 2
            ;;
        --storage)
            PCT_STORAGE="$2"
            shift 2
            ;;
        --bridge)
            BRIDGE="$2"
            shift 2
            ;;
        --dns)
            DNS_SERVER="$2"
            shift 2
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

# Check for required commands
for cmd in pct pvesh curl jq sha256sum; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: Required command '$cmd' not found. Please install it first."
        exit 1
    fi
done

# Define helper functions early (before they're used)
# log function prints text in yellow
log() {
  local text="$1"
  echo -e "\033[33m$text\033[0m"
}

# error function prints text in red
error() {
  local text="$1"
  echo -e "\033[31mError: $text\033[0m" >&2
}

# Wait for network connectivity in container
wait_for_network() {
    local container_id=$1
    local max_attempts=30
    local attempt=0

    log "-- Waiting for network connectivity..."

    while [ $attempt -lt $max_attempts ]; do
        # Test DNS resolution and connectivity using ping (available in base image)
        if pct exec "$container_id" -- ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
            # Test DNS resolution
            if pct exec "$container_id" -- ping -c 1 -W 2 archive.ubuntu.com >/dev/null 2>&1; then
                log "-- Network connectivity confirmed (DNS and internet working)"
                return 0
            else
                log "-- Internet reachable but DNS not working yet, continuing to wait..."
            fi
        fi

        attempt=$((attempt + 1))
        echo -n "."
        sleep 2
    done

    echo ""
    error "Network connectivity check timed out after $((max_attempts * 2)) seconds"
    return 1
}

# Determine runner scope (org vs repo)
RUNNER_SCOPE=""
if [ -n "$GITHUB_ORG" ]; then
    RUNNER_SCOPE="org"
    OWNERREPO="$GITHUB_ORG"
elif [ -n "$GITHUB_USER" ] && [ -n "$GITHUB_REPO" ]; then
    RUNNER_SCOPE="repo"
    OWNERREPO="$GITHUB_USER/$GITHUB_REPO"
fi

# Ask for GitHub token if not set
if [ -z "${GITHUB_TOKEN:-}" ]; then
    read -r -p "Enter GitHub token: " GITHUB_TOKEN
    echo
fi

# Ask for runner scope if not determined
if [ -z "$RUNNER_SCOPE" ]; then
    echo "Select runner scope:"
    select scope in "Repository (single repo)" "Organization (all repos in org)"; do
        case $scope in
            "Repository (single repo)")
                RUNNER_SCOPE="repo"
                break
                ;;
            "Organization (all repos in org)")
                RUNNER_SCOPE="org"
                break
                ;;
            *)
                echo "Invalid selection. Please try again."
                ;;
        esac
    done
    echo
fi

# Collect owner/repo or org based on scope
if [ "$RUNNER_SCOPE" = "org" ]; then
    if [ -z "$GITHUB_ORG" ]; then
        read -r -p "Enter GitHub organization name: " GITHUB_ORG
        OWNERREPO="$GITHUB_ORG"
    fi
    RUNNER_URL="https://github.com/$GITHUB_ORG"
    API_URL="https://api.github.com/orgs/$GITHUB_ORG/actions/runners/registration-token"
else
    # Repository scope
    if [ -z "$OWNERREPO" ]; then
        if [ -z "$GITHUB_USER" ]; then
            read -r -p "Enter GitHub username/organization: " GITHUB_USER
        fi
        if [ -z "$GITHUB_REPO" ]; then
            read -r -p "Enter GitHub repository name: " GITHUB_REPO
        fi
        OWNERREPO="$GITHUB_USER/$GITHUB_REPO"
    fi

    # Validate OWNERREPO format (must contain a slash)
    if [[ ! "$OWNERREPO" =~ ^[^/]+/[^/]+$ ]]; then
        echo "Error: Repository must be in format 'owner/repository' (e.g., 'octocat/Hello-World')"
        echo "You provided: '$OWNERREPO'"
        exit 1
    fi

    RUNNER_URL="https://github.com/$OWNERREPO"
    API_URL="https://api.github.com/repos/$OWNERREPO/actions/runners/registration-token"
fi

# Validate final inputs
if [ -z "$GITHUB_TOKEN" ] || [ -z "$OWNERREPO" ]; then
    echo "Error: GitHub token and repository/organization are required"
    show_usage
    exit 1
fi

echo ""
log "Runner scope: $RUNNER_SCOPE"
log "Target: $OWNERREPO"
echo ""

# Proxmox infrastructure configuration
log "=== Proxmox Configuration ==="

# Prompt for storage backend with dropdown menu
if [ -z "${PCT_STORAGE:-}" ]; then
    echo ""
    echo "Select storage backend:"
    mapfile -t storage_options < <(pvesm status | awk 'NR>1 {print $1 " (" $2 ")"}')
    storage_names=($(pvesm status | awk 'NR>1 {print $1}'))

    PS3="Enter number (default is $DEFAULT_STORAGE): "
    select storage_choice in "${storage_options[@]}" "Use default ($DEFAULT_STORAGE)"; do
        if [ "$REPLY" -eq "${#storage_options[@]}" ] 2>/dev/null || [ -z "$storage_choice" ]; then
            PCT_STORAGE="$DEFAULT_STORAGE"
            echo "Using default storage: $PCT_STORAGE"
            break
        elif [ -n "$storage_choice" ]; then
            PCT_STORAGE="${storage_names[$((REPLY-1))]}"
            echo "Selected storage: $PCT_STORAGE"
            break
        else
            echo "Invalid selection. Please try again."
        fi
    done
fi

# Validate storage exists
if ! pvesm status | awk 'NR>1 {print $1}' | grep -q "^${PCT_STORAGE}$"; then
    error "Storage backend '$PCT_STORAGE' not found"
    exit 1
fi

# Prompt for network bridge with dropdown menu
if [ -z "${BRIDGE:-}" ]; then
    echo ""
    echo "Select network bridge:"
    mapfile -t bridge_options < <(brctl show 2>/dev/null | awk 'NR>1 && $1 !~ /^[[:space:]]*$/ {print $1}' || ip link show type bridge | grep -oP '^\d+:\s+\K[^:]+')

    PS3="Enter number (default is $DEFAULT_BRIDGE): "
    select bridge_choice in "${bridge_options[@]}" "Use default ($DEFAULT_BRIDGE)"; do
        if [ "$REPLY" -eq "$((${#bridge_options[@]}+1))" ] 2>/dev/null || [ -z "$bridge_choice" ]; then
            BRIDGE="$DEFAULT_BRIDGE"
            echo "Using default bridge: $BRIDGE"
            break
        elif [ -n "$bridge_choice" ]; then
            BRIDGE="$bridge_choice"
            echo "Selected bridge: $BRIDGE"
            break
        else
            echo "Invalid selection. Please try again."
        fi
    done
fi

echo ""

# Network configuration
if [ "$USE_DHCP" = "yes" ]; then
    log "Using DHCP for network configuration"
    # Disable firewall to prevent DHCP blocking (common Proxmox DHCP issue fix)
    NETWORK_CONFIG="name=eth0,bridge=$BRIDGE,ip=dhcp,type=veth,firewall=0"
else
    log "Using static IP configuration"
    read -r -e -p "Container Address IP (CIDR format) [$DEFAULT_IP_ADDR]: " input_ip_addr
    IP_ADDR=${input_ip_addr:-$DEFAULT_IP_ADDR}
    read -r -e -p "Container Gateway IP [$DEFAULT_GATEWAY]: " input_gateway
    GATEWAY=${input_gateway:-$DEFAULT_GATEWAY}
    NETWORK_CONFIG="name=eth0,bridge=$BRIDGE,gw=$GATEWAY,ip=$IP_ADDR,type=veth,firewall=0"
fi

# DNS configuration (applies to both DHCP and static)
if [ -z "${DNS_SERVER:-}" ]; then
    read -r -e -p "Container DNS Server [$DEFAULT_DNS_SERVER]: " input_dns
    DNS_SERVER=${input_dns:-$DEFAULT_DNS_SERVER}
fi

# Get filename from the URLs
TEMPL_FILE=$(basename "$TEMPL_URL")
GITHUB_RUNNER_FILE=$(basename "$GITHUB_RUNNER_URL")

# Get the next available ID from Proxmox
PCTID=$(pvesh get /cluster/nextid)

# Download Ubuntu template if not already present
if [ -f "$TEMPL_FILE" ]; then
    log "-- Template $TEMPL_FILE already exists, skipping download"
else
    log "-- Downloading $TEMPL_FILE template..."
    if ! curl -fsSL -C - -o "$TEMPL_FILE" "$TEMPL_URL"; then
        error "Failed to download template"
        exit 1
    fi
fi

# Create LXC container
log "-- Creating LXC container with ID:$PCTID"
if ! pct create "$PCTID" "$TEMPL_FILE" \
    -arch "$PCT_ARCH" \
    -ostype ubuntu \
    -hostname "github-runner-proxmox-$(openssl rand -hex 3)" \
    -cores "$PCT_CORES" \
    -memory "$PCT_MEMORY" \
    -swap "$PCT_SWAP" \
    -storage "$PCT_STORAGE" \
    -features nesting=1,keyctl=1 \
    -net0 "$NETWORK_CONFIG" \
    -nameserver "$DNS_SERVER"; then
    error "Failed to create container"
    exit 1
fi

# Mark container as created for cleanup trap
CONTAINER_CREATED=1

# Resize the container
log "-- Resizing container to $PCTSIZE"
if ! pct resize "$PCTID" rootfs "$PCTSIZE"; then
    error "Failed to resize container"
    exit 1
fi

# Start the container & wait for it to be ready
log "-- Starting container"
if ! pct start "$PCTID"; then
    error "Failed to start container"
    exit 1
fi

# DHCP fix: Restart container once to ensure DHCP client gets IP
# This solves the common "container starts too fast before DHCP" issue
log "-- Restarting container to ensure DHCP obtains IP address..."
sleep 5
pct reboot "$PCTID"
sleep 5

log "-- Waiting for container to be ready..."
for i in {1..30}; do
    if pct exec "$PCTID" -- test -f /var/lib/dpkg/lock-frontend 2>/dev/null; then
        break
    fi
    sleep 2
done

# Wait for network connectivity
if ! wait_for_network "$PCTID"; then
    error "Container network is not ready"
    exit 1
fi

# Run updates inside container with retry logic
log "-- Running updates"
retry_count=0
max_retries=3
while [ $retry_count -lt $max_retries ]; do
    if pct exec "$PCTID" -- bash -c "apt-get update -y && apt-get install -y git curl zip jq"; then
        break
    fi
    retry_count=$((retry_count + 1))
    if [ $retry_count -lt $max_retries ]; then
        log "-- Package installation failed, retrying ($retry_count/$max_retries)..."
        sleep 5
    else
        error "Failed to install basic packages after $max_retries attempts"
        exit 1
    fi
done

# Install Docker inside the container
log "-- Installing docker"
if ! pct exec "$PCTID" -- bash -c "curl -fsSL https://get.docker.com | sh"; then
    error "Failed to install Docker"
    exit 1
fi

# Install .NET 9.0 SDK and development tools
log "-- Installing .NET 9.0 SDK and development tools"
pct exec "$PCTID" -- bash -c "
    set -euo pipefail

    # Install .NET 9.0 SDK
    echo 'Installing .NET 9.0 SDK...'
    apt-get install -y dotnet-sdk-9.0

    # Verify .NET installation
    dotnet --version
    dotnet --list-sdks

    # Install PowerShell
    echo 'Installing PowerShell...'
    wget -q https://packages.microsoft.com/config/ubuntu/\$(lsb_release -rs)/packages-microsoft-prod.deb
    dpkg -i packages-microsoft-prod.deb
    rm packages-microsoft-prod.deb
    apt-get update
    apt-get install -y powershell

    # Install build tools
    echo 'Installing build essentials and utilities...'
    apt-get install -y build-essential bc

    # Verify installations
    echo '=== Installed Versions ==='
    echo \".NET SDK: \$(dotnet --version)\"
    echo \"PowerShell: \$(pwsh --version | head -1)\"
    echo \"Git: \$(git --version)\"
"

# Configure sudo for runner user (for cache dropping in CI)
log "-- Configuring sudo permissions for runner user"
pct exec "$PCTID" -- bash -c "
    # Create runner user first if it doesn't exist (for sudo config)
    if ! id -u runner &>/dev/null; then
        useradd -m -s /bin/bash runner
        usermod -aG docker runner
    fi

    # Allow runner to drop caches without password (useful for benchmarks)
    echo 'runner ALL=(ALL) NOPASSWD: /usr/bin/tee /proc/sys/vm/drop_caches' > /etc/sudoers.d/github-runner-cache
    chmod 0440 /etc/sudoers.d/github-runner-cache
"

# Get runner installation token
log "-- Getting runner installation token for $RUNNER_SCOPE: $OWNERREPO"
RES=$(curl -fsSL \
  -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $GITHUB_TOKEN"  \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "$API_URL")

if ! RUNNER_TOKEN=$(echo "$RES" | jq -r '.token'); then
    error "Failed to extract runner token. Response: $RES"
    exit 1
fi

if [ -z "$RUNNER_TOKEN" ] || [ "$RUNNER_TOKEN" = "null" ]; then
    error "Invalid runner token received. Check your GITHUB_TOKEN and permissions"
    error "For org-level runners, you need admin:org permissions"
    exit 1
fi

# Download and verify GitHub Actions runner
log "-- Downloading GitHub Actions runner v$GITHUB_RUNNER_VERSION"
pct exec "$PCTID" -- bash -c "
    set -euo pipefail
    mkdir -p /opt/actions-runner && cd /opt/actions-runner
    if ! curl -fsSL -o '$GITHUB_RUNNER_FILE' '$GITHUB_RUNNER_URL'; then
        echo 'Failed to download GitHub runner'
        exit 1
    fi

    # Verify checksum
    echo '$GITHUB_RUNNER_SHA256  $GITHUB_RUNNER_FILE' | sha256sum -c - || {
        echo 'Checksum verification failed!'
        exit 1
    }

    tar xzf '$GITHUB_RUNNER_FILE'
"

# Install and start the runner
log "-- Configuring and starting runner"
pct exec "$PCTID" -- bash -c "
    set -euo pipefail

    # Create a runner user instead of running as root
    if ! id -u runner &>/dev/null; then
        useradd -m -s /bin/bash runner
        usermod -aG docker runner
    fi

    # Change ownership
    chown -R runner:runner /opt/actions-runner

    # Configure and start as runner user
    cd /opt/actions-runner
    sudo -u runner ./config.sh --unattended --url $RUNNER_URL --token $RUNNER_TOKEN
    ./svc.sh install runner
    ./svc.sh start
"

# Show container IP address
if [ "$USE_DHCP" = "yes" ]; then
    log "-- Container created successfully with ID: $PCTID"
    sleep 2
    IP_INFO=$(pct exec "$PCTID" -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo "Unable to determine IP")
    log "-- Container IP address: $IP_INFO"
else
    log "-- Container created successfully with ID: $PCTID"
    log "-- Container IP address: ${IP_ADDR%/*}"
fi

log "-- GitHub Actions runner has been installed and started"
log "-- Check your repository's Actions settings to see the new runner"

# Mark successful completion to prevent cleanup
CONTAINER_CREATED=0

# Cleanup downloaded template (optional - comment out if you want to keep it for future use)
# rm -f "$TEMPL_FILE"
