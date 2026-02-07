# Claude Code Development Sandbox

A comprehensive Docker-based development environment pre-configured with multiple language runtimes, network diagnostics, and debugging tools. Designed for use with Claude Code.

## Included Tools

### Language Runtimes
- **Node.js** (v24 LTS Krypton) + npm
- **Bun** (latest ~1.3.x)
- **Go** (1.25.x)
- **Rust** (stable) + cargo, rustfmt, clippy, rust-analyzer
- **Zig** (0.15.2) + zls 0.15.1 language server
- **Python 3** + pip, venv

### Network Diagnostics
- ping, traceroute, mtr
- nmap, tcpdump, netcat
- dig, nslookup, host, whois
- iperf3, net-tools, iproute2

### Development Tools
- **Git** + git-lfs
- **Docker CLI** + docker-compose
- **PostgreSQL client** (psql)
- **ImageMagick** (convert)
- **Build tools**: cmake, ninja, make, gcc, g++

### Debugging & Utilities
- strace, ltrace, gdb, valgrind
- htop, btop, lsof
- ripgrep (rg), fd-find (fd), bat
- jq, yq (JSON/YAML processing)
- vim, nano, tmux, screen
- curl, wget

### Rust CLI Tools
- cargo-watch, cargo-edit, cargo-audit
- tokei (code statistics)
- hyperfine (benchmarking)

### Claude Code
- Pre-installed and ready to use

## Quick Start

### 1. Build the Image

```bash
./build.sh
# or: docker build -t claude-sandbox .
```

Or let the script build it automatically on first run.

### 2. Run the Sandbox

```bash
# Run in current directory (auto-mounted to /workspace)
./claude-sandbox.sh

# Run with a specific project directory
./claude-sandbox.sh -m ~/my-project:/workspace

# Run with an initial prompt
./claude-sandbox.sh -p "Review the codebase and suggest improvements"

# Mount additional directories
./claude-sandbox.sh -m ~/data:/data
```

### 3. Use Claude Code Inside the Container

Once inside the container:

```bash
# Start Claude Code
claude

# Or run a specific command
claude "explain this codebase"
```

## Usage

```
./claude-sandbox.sh [OPTIONS] [-- COMMAND]

Options:
  -w, --workdir PATH       Set working directory inside container (default: /workspace)
  -m, --mount SRC:DST      Mount a host directory (can be used multiple times)
                           If DST is omitted, mounts to the same path inside the container
  -M, --overlay SRC:DST    Mount read-only with ephemeral writes (overlayfs)
                           Writes are temporary and never persist to host
  -p, --prompt PROMPT      Initial prompt to pass to Claude Code
  -d, --detach             Run container in background
  --insecure               Expose host Docker socket and PID namespace (less isolated)
  --no-creds               Don't mount Claude credentials
  -n, --name NAME          Set container name
  -v, --verbose            Show the full docker command being executed
  -h, --help               Show help message
```

## Examples

### Basic Usage

```bash
# Interactive Claude Code in current directory
./claude-sandbox.sh

# Run a specific command
./claude-sandbox.sh -- cargo build --release

# Start Claude Code directly with a prompt
./claude-sandbox.sh -p "explain this codebase"
```

### Multiple Mounts

```bash
# Mount project and shared data
./claude-sandbox.sh \
  -m ~/project:/workspace \
  -m ~/shared-libs:/libs
```

### Read-Only Overlay Mounts (Ephemeral Writes)

```bash
# Mount a directory read-only with temporary writes (lost when container stops)
./claude-sandbox.sh -M ~/sensitive-project:/workspace

# Combine regular and overlay mounts
./claude-sandbox.sh -m ~/data:/data -M ~/config:/config
```

### Run Build Commands

```bash
# Run npm install and build
./claude-sandbox.sh -- bash -c "npm install && npm run build"

# Run Rust tests
./claude-sandbox.sh -- cargo test

# Run Zig build
./claude-sandbox.sh -- zig build
```

### Docker-in-Docker

The sandbox runs an isolated Docker daemon by default:

```bash
./claude-sandbox.sh

# Inside the container - containers run INSIDE the sandbox
docker run -p 8080:80 nginx
curl localhost:8080  # Works! Port is accessible within sandbox
```

This provides:
- Full isolation from host Docker environment
- Containers accessible via localhost
- No host PID namespace exposure

**Insecure mode** - exposes host Docker socket:
```bash
./claude-sandbox.sh --insecure

# Inside the container - containers run on HOST
docker ps  # Shows host containers
# Ports NOT accessible via localhost inside sandbox
```

Use `--insecure` only when you specifically need host Docker access.

## Claude Credentials

The script automatically mounts Claude configuration from your home directory
using bindfs to remap ownership to the container's `claude` user:

| Host Path | Container Path | Notes |
|-----------|----------------|-------|
| `~/.claude/` | `/home/claude/.claude/` | Config (`.config.json`), credentials, agents, skills, commands, plugins |
| `~/.claude.json` | `/home/claude/.claude.json` | Legacy config (fallback if `~/.claude/.config.json` doesn't exist) |
| `~/.config/claude/` | `/home/claude/.config/claude/` | Additional config |
| `~/.anthropic/` | `/home/claude/.anthropic/` | Alternative config location |

If `ANTHROPIC_API_KEY` is set on the host, it's passed through to the container.

### First-Time Setup

If you haven't logged in to Claude Code yet:

```bash
# On your host machine (not in container)
claude login

# Then run the sandbox
./claude-sandbox.sh -m .:/workspace
```

### Running Without Credentials

```bash
./claude-sandbox.sh --no-creds
```

## Customization

### Adding More Tools

Edit the Dockerfile and rebuild:

```dockerfile
# Add your tools
RUN apt-get update && apt-get install -y \
    your-tool \
    another-tool
```

Then rebuild:

```bash
docker build -t claude-sandbox .
```

### Persisting Container State

The container is ephemeral by default. To persist state:

```bash
# Create a named volume for cargo cache
docker volume create cargo-cache

# Run with volume mounted
docker run -it --rm \
  -v cargo-cache:/home/claude/.cargo/registry \
  -v $(pwd):/workspace \
  claude-sandbox
```

### Custom Shell Configuration

Mount your dotfiles:

```bash
./claude-sandbox.sh \
  -m ~/.bashrc:/home/claude/.bashrc:ro \
  -m ~/.vimrc:/home/claude/.vimrc:ro
```

## Network Diagnostics Examples

```bash
# Inside the container

# Check connectivity
ping -c 4 google.com

# Trace route
traceroute github.com
mtr --report google.com

# Port scanning (authorized targets only)
nmap -p 80,443 example.com

# DNS lookup
dig github.com
nslookup api.anthropic.com

# Network connections
netstat -tulpn
ss -tulpn

# Bandwidth testing
iperf3 -c iperf.he.net
```

## Troubleshooting

### Docker Socket Permission Denied

If you get permission errors with Docker commands:

```bash
# The script tries to add the correct group automatically
# If it fails, you may need to run with --privileged (not recommended)
# Or fix docker socket permissions on the host
sudo chmod 666 /var/run/docker.sock
```

### Claude Code Authentication Errors

```bash
# Exit the container and login on host
exit
claude login

# Re-run the sandbox
./claude-sandbox.sh -m .:/workspace
```

### Image Build Fails

```bash
# Try building with no cache
docker build --no-cache -t claude-sandbox .

# Or pull fresh base image
docker pull ubuntu:24.04
docker build -t claude-sandbox .
```

### Slow Container Start

The first run builds the image which takes several minutes. Subsequent runs start instantly.

## Security Notes

1. **Isolated by Default**: The sandbox runs an isolated Docker daemon (dind) by default. Host Docker socket and PID namespace are NOT exposed unless you use `--insecure`.

2. **Insecure Mode**: Using `--insecure` exposes the host Docker socket and PID namespace. Only use this when you specifically need host Docker access.

3. **Credentials**: Claude credentials are mounted with bindfs for permission handling. The container can read and write to credential files.

4. **Network**: The container has full network access. Use `--network none` to disable if needed. The sandbox automatically detects host IPs and sets up routing so containers can reach services on the host (e.g., MCP servers, local APIs). If your host runs a firewall, you may need to allow traffic from Docker bridge interfaces (`docker0`, `br-*`, `veth*`) to the relevant host ports.

5. **Privileged Mode**: The container runs in privileged mode (required for dind). This grants elevated capabilities inside the container.

## License

MIT
