# proxmox_scripts

Set of Proxmox scripts that can be useful for anyone.

Tested on Proxmox VE 8.

## Run a command in all nodes

Needs `jq`. Install with `apt update && apt install -y jq`

Write the following script into a file name `cssh`:
```bash
#!/bin/bash
if [ ! -n "$1" ]; then echo "Usage: $0 [command]"; else
  for n in $(cat /etc/pve/.members  | jq -r '.nodelist[].ip'); do
    echo --- $n -----------------------------------------------------
    ssh -T $n "$@"
  done
fi
```

Example output:
```bash
root@proxmox-1:~# chmod ./cssh
root@proxmox-1:~# ./cssh cat /etc/debian_version
--- 192.168.1.10 -----------------------------------------------------
12.2
--- 192.168.1.10 -----------------------------------------------------
12.2
--- 192.168.1.11 -----------------------------------------------------
12.2
--- 192.168.1.12 -----------------------------------------------------
12.2
--- 192.168.1.13 -----------------------------------------------------
12.2
```

## [lxc_create_github_actions_runner.sh](./lxc_create_github_actions_runner.sh)

Creates and sets up a self-hosted GitHub Actions runner in an LXC container on Proxmox:

1. Creates a new LXC container based on Ubuntu 24.04 LTS
1. Configures networking (DHCP by default, static IP optional)
1. Installs apt-get dependencies (git, curl, zip, jq)
1. Installs Docker
1. Installs .NET 9.0 SDK for building .NET applications
1. Installs PowerShell for running PowerShell scripts in CI
1. Installs build tools (build-essential, bc)
1. Configures sudo permissions for cache dropping (useful for benchmarks)
1. Downloads and verifies GitHub Actions runner (with SHA256 checksum)
1. Configures runner to run as dedicated 'runner' user (not root)
1. Registers and starts the runner as a system service

### Features

- **DHCP by default**: Containers get IP addresses automatically (configurable via `USE_DHCP` variable)
- **Interactive configuration**: Prompts for storage backend and network bridge with available options displayed
- **Network connectivity check**: Waits for DNS and internet before installing packages (up to 60 seconds)
- **Retry logic**: Automatically retries package installation on network failures (3 attempts)
- **Automatic cleanup**: Failed containers are automatically destroyed on script errors
- **Security improvements**: Runner runs as dedicated user, not root
- **Checksum verification**: Downloads are verified with SHA256 checksums
- **Template caching**: Avoids re-downloading Ubuntu template if already present
- **Latest versions**: Uses GitHub Actions runner v2.329.0 and Ubuntu 24.04 LTS
- **.NET 9.0 ready**: Pre-installed with .NET 9.0 SDK, PowerShell, and build tools for .NET development

### Security Warning

Since the new container has Docker support, it cannot be run unprivileged. This approach is more insecure than using a full-blown VM, at the benefit of being much faster most times. That being said, make sure you only use this self-hosted runner in contexts that you can control at all times (e.g., **avoid using with public repositories or untrusted code**).

### Instructions

```bash
# Download the script
curl -O https://raw.githubusercontent.com/oNaiPs/proxmox-scripts/main/lxc_create_github_actions_runner.sh

# Inspect script, customize variables if needed

# Run the script
bash lxc_create_github_actions_runner.sh
```

The script will prompt you for:
- GitHub Token (or set `GITHUB_TOKEN` environment variable)
- GitHub Owner/Repo (or set `OWNERREPO` environment variable)
- Storage backend (shows available options, default: `local-lvm`)
- Network bridge (shows available options, default: `vmbr0`)
- DNS Server (default: `1.1.1.1`)

To use static IP instead of DHCP, edit the script and set `USE_DHCP="no"` before running.

Warning: make sure you read and understand the code you are running before executing it on your machine.
