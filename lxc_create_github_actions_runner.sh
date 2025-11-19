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

# Check for required commands
for cmd in pct pvesh curl jq sha256sum; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: Required command '$cmd' not found. Please install it first."
        exit 1
    fi
done

# Ask for GitHub token and owner/repo if they're not set
if [ -z "${GITHUB_TOKEN:-}" ]; then
    read -r -p "Enter github token: " GITHUB_TOKEN
    echo
fi
if [ -z "${OWNERREPO:-}" ]; then
    read -r -p "Enter github owner/repo (format: owner/repository): " OWNERREPO
    echo
fi

# Validate inputs
if [ -z "$GITHUB_TOKEN" ] || [ -z "$OWNERREPO" ]; then
    echo "Error: GITHUB_TOKEN and OWNERREPO are required"
    exit 1
fi

# Validate OWNERREPO format (must contain a slash)
if [[ ! "$OWNERREPO" =~ ^[^/]+/[^/]+$ ]]; then
    echo "Error: OWNERREPO must be in format 'owner/repository' (e.g., 'octocat/Hello-World')"
    echo "You provided: '$OWNERREPO'"
    exit 1
fi

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

# Proxmox infrastructure configuration
log "=== Proxmox Configuration ==="

# Prompt for storage backend
echo "Available storage backends:"
pvesm status | awk 'NR>1 {print "  - " $1 " (" $2 ")"}'
echo ""
read -r -e -p "Storage backend for container [$DEFAULT_STORAGE]: " input_storage
PCT_STORAGE=${input_storage:-$DEFAULT_STORAGE}

# Validate storage exists
if ! pvesm status | awk 'NR>1 {print $1}' | grep -q "^${PCT_STORAGE}$"; then
    error "Storage backend '$PCT_STORAGE' not found"
    exit 1
fi

# Prompt for network bridge
echo ""
echo "Available network bridges:"
brctl show 2>/dev/null | awk 'NR>1 {print "  - " $1}' || ip link show type bridge | grep -oP '^\d+:\s+\K[^:]+' | sed 's/^/  - /'
echo ""
read -r -e -p "Network bridge for container [$DEFAULT_BRIDGE]: " input_bridge
BRIDGE=${input_bridge:-$DEFAULT_BRIDGE}

echo ""

# Network configuration
if [ "$USE_DHCP" = "yes" ]; then
    log "Using DHCP for network configuration"
    NETWORK_CONFIG="name=eth0,bridge=$BRIDGE,ip=dhcp,type=veth"
else
    log "Using static IP configuration"
    read -r -e -p "Container Address IP (CIDR format) [$DEFAULT_IP_ADDR]: " input_ip_addr
    IP_ADDR=${input_ip_addr:-$DEFAULT_IP_ADDR}
    read -r -e -p "Container Gateway IP [$DEFAULT_GATEWAY]: " input_gateway
    GATEWAY=${input_gateway:-$DEFAULT_GATEWAY}
    NETWORK_CONFIG="name=eth0,bridge=$BRIDGE,gw=$GATEWAY,ip=$IP_ADDR,type=veth"
fi

# DNS configuration (applies to both DHCP and static)
read -r -e -p "Container DNS Server [$DEFAULT_DNS_SERVER]: " input_dns
DNS_SERVER=${input_dns:-$DEFAULT_DNS_SERVER}

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

# Get runner installation token
log "-- Getting runner installation token"
RES=$(curl -fsSL \
  -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $GITHUB_TOKEN"  \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/$OWNERREPO/actions/runners/registration-token")

if ! RUNNER_TOKEN=$(echo "$RES" | jq -r '.token'); then
    error "Failed to extract runner token. Response: $RES"
    exit 1
fi

if [ -z "$RUNNER_TOKEN" ] || [ "$RUNNER_TOKEN" = "null" ]; then
    error "Invalid runner token received. Check your GITHUB_TOKEN and OWNERREPO"
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
    sudo -u runner ./config.sh --unattended --url https://github.com/$OWNERREPO --token $RUNNER_TOKEN
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
