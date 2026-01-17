# Claude Code Development Sandbox

A comprehensive Docker-based development environment pre-configured with multiple language runtimes, network diagnostics, and debugging tools. Designed for use with Claude Code.

## Included Tools

### Language Runtimes
- **Node.js** (v24 LTS Krypton) + npm
- **Bun** (latest ~1.3.x)
- **Rust** (stable) + cargo, rustfmt, clippy, rust-analyzer
- **Zig** (0.15.2) + zls 0.15.0 language server
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
docker build -t claude-sandbox .
```

Or let the script build it automatically on first run.

### 2. Run the Sandbox

```bash
# Run interactive shell with current directory mounted
./claude-sandbox.sh -m .:/workspace

# Run with a specific project directory
./claude-sandbox.sh -m ~/my-project:/workspace

# Mount multiple directories
./claude-sandbox.sh -m ~/projects:/workspace -m ~/data:/data
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
  -d, --detach             Run container in background
  --dind                   Enable Docker-in-Docker mode (isolated Docker daemon)
  --no-docker              Don't mount Docker socket
  --no-creds               Don't mount Claude credentials
  -n, --name NAME          Set container name
  -h, --help               Show help message
```

## Examples

### Basic Usage

```bash
# Interactive shell in current directory
./claude-sandbox.sh -m .:/workspace

# Run a specific command
./claude-sandbox.sh -m .:/workspace -- cargo build --release

# Start Claude Code directly
./claude-sandbox.sh -m ~/project:/workspace -- claude
```

### Multiple Mounts

```bash
# Mount project and shared data
./claude-sandbox.sh \
  -m ~/project:/workspace \
  -m ~/shared-libs:/libs \
  -m ~/.ssh:/root/.ssh:ro
```

### Run Build Commands

```bash
# Run npm install and build
./claude-sandbox.sh -m .:/workspace -- bash -c "npm install && npm run build"

# Run Rust tests
./claude-sandbox.sh -m .:/workspace -- cargo test

# Run Zig build
./claude-sandbox.sh -m .:/workspace -- zig build
```

### Docker-in-Docker

The sandbox supports two Docker modes:

**Default mode** - mounts the host's Docker socket:
```bash
./claude-sandbox.sh -m .:/workspace

# Inside the container - containers run on HOST
docker ps
docker build -t myimage .
```

**Dind mode** - runs an isolated Docker daemon inside the sandbox:
```bash
./claude-sandbox.sh --dind -m .:/workspace

# Inside the container - containers run INSIDE the sandbox
docker run -p 8080:80 nginx
curl localhost:8080  # Works! Port is accessible within sandbox
```

Use `--dind` when:
- You need to access ports exposed by containers you create
- You want complete isolation from host Docker
- You're running services that need to communicate via localhost

## Claude Credentials

The script automatically mounts Claude credentials from your home directory:

| Host Path | Container Path | Mode |
|-----------|----------------|------|
| `~/.claude/` | `/root/.claude/` | read-only |
| `~/.config/claude/` | `/root/.config/claude/` | read-only |
| `~/.anthropic/` | `/root/.anthropic/` | read-only |

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
./claude-sandbox.sh --no-creds -m .:/workspace
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
  -v cargo-cache:/root/.cargo/registry \
  -v $(pwd):/workspace \
  claude-sandbox
```

### Custom Shell Configuration

Mount your dotfiles:

```bash
./claude-sandbox.sh \
  -m .:/workspace \
  -m ~/.bashrc:/root/.bashrc:ro \
  -m ~/.vimrc:/root/.vimrc:ro
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

1. **Docker Socket**: Mounting the Docker socket gives container access to host Docker. Use `--no-docker` if not needed, or use `--dind` for an isolated Docker daemon.

2. **Docker-in-Docker**: The `--dind` mode runs a separate Docker daemon inside the container. This provides isolation but requires privileged mode. Containers created in dind mode are fully isolated from the host.

3. **Credentials**: Claude credentials are mounted read-only. The container cannot modify your host credentials.

4. **Network**: The container has full network access. Use `--network none` to disable if needed.

5. **Root User**: The container runs as root. For production use, consider creating a non-root user.

## License

MIT
