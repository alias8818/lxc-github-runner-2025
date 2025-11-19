# LXC GitHub Actions Runner for Proxmox

Automated script to create and configure self-hosted GitHub Actions runners in LXC containers on Proxmox VE.

Tested on **Proxmox VE 8** with **Ubuntu 24.04 LTS** containers.

## Features

- **Automated setup**: Creates LXC container, installs dependencies, and registers runner with GitHub
- **DHCP networking**: Automatic IP assignment with Proxmox DHCP fixes applied
- **Interactive & CLI modes**: Use interactive menus or pass arguments for automation
- **Organization & repository runners**: Support for both repo-level and org-level runners
- **.NET 9.0 ready**: Pre-installed with .NET 9.0 SDK, PowerShell, and build tools
- **Security focused**: Runner runs as dedicated user (not root)
- **Robust error handling**: Automatic cleanup on failures, network retry logic
- **Template caching**: Reuses downloaded Ubuntu templates for faster deployment

## What Gets Installed

The script creates an LXC container with:

1. **Ubuntu 24.04 LTS** base system
2. **GitHub Actions Runner** v2.329.0 (with SHA256 verification)
3. **Development tools**:
   - Git, curl, zip, jq
   - .NET 9.0 SDK (via Ubuntu backports PPA)
   - PowerShell
   - build-essential, bc
4. **Network configuration**: DHCP with firewall disabled (prevents common DHCP issues)
5. **System service**: Runner configured to start automatically on boot

## Quick Start

### Interactive Mode

```bash
# Download the script
curl -O https://raw.githubusercontent.com/alias8818/lxc-github-runner-2025/main/lxc_create_github_actions_runner.sh

# Make it executable
chmod +x lxc_create_github_actions_runner.sh

# Run interactively
./lxc_create_github_actions_runner.sh
```

You'll be prompted for:
- GitHub token
- Username/organization
- Repository name (or organization scope)
- Storage backend (dropdown menu)
- Network bridge (dropdown menu)
- DNS server (default: 1.1.1.1)

### Automated Mode

For automation, CI/CD, or deploying multiple runners:

```bash
# Repository-level runner (single repo)
./lxc_create_github_actions_runner.sh \
  --user alias8818 \
  --repo BarrierClone \
  --token ghp_xxxxxxxxxxxxx

# Organization-level runner (available to ALL repos)
./lxc_create_github_actions_runner.sh \
  --org alias8818 \
  --token ghp_xxxxxxxxxxxxx

# With custom infrastructure settings
./lxc_create_github_actions_runner.sh \
  --user alias8818 \
  --repo BarrierClone \
  --token ghp_xxxxxxxxxxxxx \
  --storage pve_storage \
  --bridge vmbr0 \
  --dns 1.1.1.1
```

## Command-Line Options

| Option | Description |
|--------|-------------|
| `--user <username>` | GitHub username (for repo-level runners) |
| `--repo <repository>` | Repository name (for repo-level runners) |
| `--org <organization>` | Organization name (for org-level runners) |
| `--token <token>` | GitHub Personal Access Token (required) |
| `--storage <storage>` | Proxmox storage backend (optional) |
| `--bridge <bridge>` | Network bridge (optional) |
| `--dns <dns>` | DNS server (default: 1.1.1.1) |
| `-h, --help` | Show help message |

## Runner Scope

### Repository-Level Runners

Dedicated to a **single repository**:

```bash
./lxc_create_github_actions_runner.sh \
  --user <username> \
  --repo <repository> \
  --token <token>
```

**Token permissions required**: `repo` (full control of private repositories)

### Organization-Level Runners

Available to **all repositories** in your organization:

```bash
./lxc_create_github_actions_runner.sh \
  --org <organization> \
  --token <token>
```

**Token permissions required**: `admin:org` (full control of organizations)

## Networking

### DHCP (Default)

The script uses DHCP by default with these fixes for common Proxmox issues:

- **Firewall disabled** on network interface (prevents DHCP blocking)
- **Container restart** after creation (ensures DHCP lease acquisition)
- **Network connectivity check** before package installation (waits up to 60 seconds)

### Static IP (Optional)

To use static IP addressing instead, edit the script and set:

```bash
USE_DHCP="no"
```

Then run the script. You'll be prompted for IP address, gateway, and netmask.

## GitHub Token

### Creating a Personal Access Token

1. Go to GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic)
2. Click "Generate new token (classic)"
3. Select scopes:
   - For **repository runners**: `repo` (Full control of private repositories)
   - For **organization runners**: `admin:org` (Full control of orgs and teams)
4. Copy the token (starts with `ghp_`)

### Using the Token

```bash
./lxc_create_github_actions_runner.sh \
  --user alias8818 \
  --repo BarrierClone \
  --token ghp_xxxxxxxxxxxxx
```

**Note**: Tokens are sensitive. Never commit them to version control.

## Using Your Runner

Once created, use your self-hosted runner in workflows:

```yaml
name: Build

on: [push]

jobs:
  build:
    runs-on: self-hosted  # Uses your LXC runner

    steps:
      - uses: actions/checkout@v4

      - name: Build with .NET
        run: |
          dotnet --version
          dotnet build
          dotnet test
```

## Troubleshooting

### Network Issues

If containers can't reach the internet:

1. Verify DHCP is working: `pct exec <container-id> -- ip addr`
2. Check DNS resolution: `pct exec <container-id> -- ping -c 1 google.com`
3. Review Proxmox firewall rules on the bridge

### Runner Not Appearing in GitHub

1. Check the runner service: `pct exec <container-id> -- systemctl status actions.runner.*`
2. Verify token permissions (repo or admin:org)
3. Check logs: `pct exec <container-id> -- journalctl -u actions.runner.* -n 50`

### .NET SDK Issues

The script installs .NET 9.0 via Ubuntu's backports PPA. If you need .NET 8.0 instead:

```bash
# Inside the container
apt remove dotnet-sdk-9.0
apt install dotnet-sdk-8.0
```

## Security Considerations

- **Runner user**: The runner operates as a dedicated `runner` user (not root)
- **Sudo permissions**: Limited to cache dropping (`/proc/sys/vm/drop_caches`) for benchmarking
- **Container isolation**: LXC provides namespace isolation from the host
- **Token handling**: Tokens are only used during registration and not stored long-term

**⚠️ Important**: Only use self-hosted runners with repositories you control. Avoid public repositories or untrusted code, as runners execute arbitrary workflow code.

## Requirements

- Proxmox VE 8 or later
- Internet connectivity for package downloads
- Sufficient storage for Ubuntu 24.04 template (~500MB) + container disk (default: 20GB)
- GitHub Personal Access Token with appropriate permissions

## License

This project is provided as-is for public use. Feel free to modify and adapt to your needs.

## Contributing

Issues and pull requests are welcome! Please ensure any contributions maintain compatibility with Proxmox VE 8 and Ubuntu 24.04 LTS.
