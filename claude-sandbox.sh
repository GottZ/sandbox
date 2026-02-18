#!/usr/bin/env bash
#
# Claude Code Development Sandbox
# A script to run the development sandbox container with proper mounts
#

set -e

# Resolve the real directory of this script (handles symlinks)
resolve_script_dir() {
    local source="${BASH_SOURCE[0]}"
    # Resolve symlinks
    while [ -L "$source" ]; do
        local dir="$(cd -P "$(dirname "$source")" && pwd)"
        source="$(readlink "$source")"
        # Handle relative symlinks
        [[ "$source" != /* ]] && source="$dir/$source"
    done
    cd -P "$(dirname "$source")" && pwd
}

SCRIPT_DIR="$(resolve_script_dir)"

# Configuration
IMAGE_NAME="claude-sandbox"
CONTAINER_NAME="claude-sandbox-$$"

# Colors for output
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m' # No Color

# Default values
WORKDIR="/workspace"
INTERACTIVE=true
MOUNTS=()
OVERLAY_MOUNTS=()
DIND_MODE=true      # Default: isolated Docker daemon
INSECURE_MODE=false # When true: expose host Docker socket and PID namespace
CLAUDE_CREDS=true
EXTRA_ARGS=()
INITIAL_PROMPT=""
VERBOSE=false

usage() {
    cat << EOF
${BLUE}Claude Code Development Sandbox${NC}

Usage: $(basename "$0") [OPTIONS] [-- COMMAND]

${GREEN}Options:${NC}
  -w, --workdir PATH       Set working directory inside container (default: /workspace)
  -m, --mount SRC:DST      Mount a host directory (can be used multiple times)
                           SRC = host path, DST = container path
                           If DST is omitted, mounts to the same path inside the container
                           Default /workspace mount (current dir) is always added
                           unless you explicitly specify a mount with DST=/workspace
  -M, --overlay SRC:DST    Mount a host directory read-only with ephemeral writes (overlayfs)
                           Writes inside the container are temporary and never persist to host
                           If DST is omitted, mounts to the same path inside the container
  -p, --prompt PROMPT      Initial prompt to pass to Claude Code
  -d, --detach             Run container in background
  --insecure               Expose host Docker socket and PID namespace (less isolated)
  --no-creds               Don't mount Claude credentials
  -n, --name NAME          Set container name (default: auto-generated)
  -v, --verbose            Show the full docker command being executed
  -h, --help               Show this help message

${GREEN}Examples:${NC}
  # Run Claude Code in current directory (default)
  $(basename "$0")

  # Run Claude Code with an initial prompt
  $(basename "$0") -p "Review the codebase and suggest improvements"

  # Run with additional mounts
  $(basename "$0") -m ~/data:/data

  # Run a specific command
  $(basename "$0") -- cargo build

  # Run without Claude credentials
  $(basename "$0") --no-creds

${GREEN}Claude Configuration:${NC}
  The script automatically mounts Claude configuration from:
    - ~/.claude/         -> /home/claude/.claude/ (read-write)
    - ~/.config/claude/  -> /home/claude/.config/claude/ (read-write)

  This includes:
    - Credentials for authentication
    - Custom agents (~/.claude/agents/)
    - Custom skills (~/.claude/skills/)
    - Custom commands (~/.claude/commands/)
    - MCP plugins (~/.claude/plugins/)
    - Secrets (~/.secrets/) for Context Store auth etc.
    - ctx CLI (/usr/local/bin/ctx) if installed

  Note: Container runs as non-root 'claude' user with passwordless sudo.

${GREEN}Docker Support:${NC}
  By default, the sandbox runs an isolated Docker daemon (dind mode):
    - Containers created are fully accessible via localhost
    - Ports exposed by containers work correctly within the sandbox
    - Host Docker environment is not exposed
    - Host PID namespace is isolated

  Use --insecure to expose host Docker instead:
    - Mounts host Docker socket at /var/run/docker.sock
    - Exposes host PID namespace
    - Containers run on the host (ports not accessible via localhost)
    - Use only when you need direct host Docker access

${GREEN}Permissions:${NC}
  The container runs with full privileges to allow Claude unrestricted operation:
    - Privileged mode enabled
    - All Linux capabilities added
    - Seccomp and AppArmor disabled
    - Host PID namespace access
    - Claude Code runs with --dangerously-skip-permissions (no prompts)

${GREEN}Mount Handling:${NC}
  Mounts are automatically checked for accessibility:
    - If a mount is owned by root or not writable, bindfs is used to remap
      ownership to the claude user inside the container
    - This ensures the claude user can always read/write mounted directories
    - Permission issues are detected before container startup

EOF
    exit 0
}

# Detect host IPs for routing inside container (excludes loopback, docker, and virtual interfaces)
detect_host_ips() {
    if command -v ip &> /dev/null; then
        ip -4 addr show scope global | grep -v -E 'docker|br-|veth' | grep -oP 'inet \K[\d.]+' | paste -sd, -
    elif command -v ifconfig &> /dev/null; then
        ifconfig | grep 'inet ' | awk '{print $2}' | grep -v '^127\.' | paste -sd, -
    fi
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -w|--workdir)
            WORKDIR="$2"
            shift 2
            ;;
        -m|--mount)
            MOUNTS+=("$2")
            shift 2
            ;;
        -M|--overlay)
            OVERLAY_MOUNTS+=("$2")
            shift 2
            ;;
        -p|--prompt)
            INITIAL_PROMPT="$2"
            shift 2
            ;;
        -d|--detach)
            INTERACTIVE=false
            shift
            ;;
        --insecure)
            INSECURE_MODE=true
            DIND_MODE=false
            shift
            ;;
        --no-creds)
            CLAUDE_CREDS=false
            shift
            ;;
        -n|--name)
            CONTAINER_NAME="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        --)
            shift
            EXTRA_ARGS=("$@")
            break
            ;;
        *)
            log_error "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Check if Docker is available
if ! command -v docker &> /dev/null; then
    log_error "Docker is not installed or not in PATH"
    exit 1
fi

# Check if image exists, build if not
if ! docker image inspect "$IMAGE_NAME" &> /dev/null; then
    log_warn "Image '$IMAGE_NAME' not found. Building..."
    docker build -t "$IMAGE_NAME" "$SCRIPT_DIR"
    log_success "Image built successfully"
fi

# Check if any mount explicitly targets /workspace
HAS_WORKSPACE_MOUNT=false
for mount in "${MOUNTS[@]}"; do
    IFS=':' read -ra PARTS <<< "$mount"
    DST="${PARTS[1]:-}"
    if [ "$DST" = "/workspace" ]; then
        HAS_WORKSPACE_MOUNT=true
        break
    fi
done

# Also check overlay mounts — resolve DST the same way the processing loop will
if [ "$HAS_WORKSPACE_MOUNT" = false ]; then
    for mount in "${OVERLAY_MOUNTS[@]}"; do
        IFS=':' read -ra PARTS <<< "$mount"
        OV_SRC="${PARTS[0]}"
        OV_DST="${PARTS[1]:-}"
        OV_SRC=$(eval echo "$OV_SRC")
        if [[ ! "$OV_SRC" = /* ]]; then
            OV_SRC="$(cd "$OV_SRC" 2>/dev/null && pwd)" || true
        fi
        # Resolve implicit DST the same way the overlay loop does
        if [ -z "$OV_DST" ] && [ "$OV_SRC" = "$(pwd)" ]; then
            OV_DST="$WORKDIR"
        fi
        if [ "$OV_DST" = "/workspace" ]; then
            HAS_WORKSPACE_MOUNT=true
            break
        fi
    done
fi

# Add default workspace mount unless explicitly overridden
if [ "$HAS_WORKSPACE_MOUNT" = false ]; then
    # Prepend default mount so user mounts are processed after
    MOUNTS=("$(pwd):/workspace" "${MOUNTS[@]}")
fi

# Build docker run command
DOCKER_CMD=(docker run --rm)

# Interactive mode - only add -t if we have a TTY
if [ "$INTERACTIVE" = true ]; then
    DOCKER_CMD+=(-i)
    if [ -t 0 ] && [ -t 1 ]; then
        DOCKER_CMD+=(-t)
    fi
fi

# Container name
DOCKER_CMD+=(--name "$CONTAINER_NAME")

# Grant permissions based on mode
if [ "$INSECURE_MODE" = true ]; then
    log_warn "Running in INSECURE mode (host Docker and PID namespace exposed)"
    DOCKER_CMD+=(--privileged)
    DOCKER_CMD+=(--cap-add=ALL)
    DOCKER_CMD+=(--security-opt seccomp=unconfined)
    DOCKER_CMD+=(--security-opt apparmor=unconfined)
    DOCKER_CMD+=(--pid=host)
else
    log_info "Running in isolated mode (dind)"
    DOCKER_CMD+=(--privileged)  # Required for dind
    DOCKER_CMD+=(--security-opt seccomp=unconfined)
fi

# Working directory
DOCKER_CMD+=(-w "$WORKDIR")

# Process mounts with permission checking and bindfs setup
BINDFS_MOUNTS=""
MOUNT_INDEX=0

for mount in "${MOUNTS[@]}"; do
    # Split on colon
    IFS=':' read -ra PARTS <<< "$mount"
    SRC="${PARTS[0]}"
    DST="${PARTS[1]:-}"

    # Expand paths
    SRC=$(eval echo "$SRC")

    # Convert to absolute path if relative
    if [[ ! "$SRC" = /* ]]; then
        SRC="$(cd "$SRC" 2>/dev/null && pwd)" || {
            log_error "Source path does not exist: $SRC"
            exit 1
        }
    fi

    # Check if source exists
    if [ ! -e "$SRC" ]; then
        log_error "Source path does not exist: $SRC"
        exit 1
    fi

    # Check if source is readable
    if [ ! -r "$SRC" ]; then
        log_error "Source path is not readable: $SRC"
        log_error "Try running with sudo or check permissions"
        exit 1
    fi

    # If no destination, mirror the source path inside the container
    if [ -z "$DST" ]; then
        DST="$SRC"
    fi

    # Create staging path for bindfs
    STAGE_PATH="/mnt/bindfs/$MOUNT_INDEX"

    # Check if elevated permissions needed (not owned by current user or not writable)
    NEEDS_BINDFS=false
    if [ -d "$SRC" ]; then
        # Check if directory is writable
        if ! test -w "$SRC" 2>/dev/null; then
            NEEDS_BINDFS=true
        fi
        # Check ownership - if owned by root, needs bindfs
        OWNER_UID=$(stat -c '%u' "$SRC" 2>/dev/null || stat -f '%u' "$SRC" 2>/dev/null)
        if [ "$OWNER_UID" = "0" ]; then
            NEEDS_BINDFS=true
        fi
    fi

    if [ "$NEEDS_BINDFS" = true ]; then
        log_info "Mounting (via bindfs): $SRC -> $DST"
        # Mount to staging area, entrypoint will bindfs to final destination
        DOCKER_CMD+=(-v "$SRC:$STAGE_PATH")
        # Add to bindfs mounts list
        if [ -n "$BINDFS_MOUNTS" ]; then
            BINDFS_MOUNTS="${BINDFS_MOUNTS};"
        fi
        BINDFS_MOUNTS="${BINDFS_MOUNTS}${STAGE_PATH}:${DST}"
    else
        log_info "Mounting: $SRC -> $DST"
        DOCKER_CMD+=(-v "$SRC:$DST")
    fi

    ((++MOUNT_INDEX))
done

# Process overlay mounts (-M flag): host dir mounted read-only with ephemeral writes via overlayfs
OVERLAY_MOUNT_INDEX=0
OVERLAY_MOUNTS_ENV=""

for mount in "${OVERLAY_MOUNTS[@]}"; do
    IFS=':' read -ra PARTS <<< "$mount"
    SRC="${PARTS[0]}"
    DST="${PARTS[1]:-}"

    # Expand paths
    SRC=$(eval echo "$SRC")

    # Convert to absolute path if relative
    if [[ ! "$SRC" = /* ]]; then
        SRC="$(cd "$SRC" 2>/dev/null && pwd)" || {
            log_error "Overlay source path does not exist: $SRC"
            exit 1
        }
    fi

    # Check if source exists
    if [ ! -e "$SRC" ]; then
        log_error "Overlay source path does not exist: $SRC"
        exit 1
    fi

    # Check if source is readable
    if [ ! -r "$SRC" ]; then
        log_error "Overlay source path is not readable: $SRC"
        exit 1
    fi

    # If no destination: current directory maps to WORKDIR, everything else mirrors the path
    if [ -z "$DST" ]; then
        if [ "$SRC" = "$(pwd)" ]; then
            DST="$WORKDIR"
        else
            DST="$SRC"
        fi
    fi

    STAGE_PATH="/mnt/overlay/$OVERLAY_MOUNT_INDEX"

    log_info "Mounting (overlay, ephemeral writes): $SRC -> $DST"
    DOCKER_CMD+=(-v "$SRC:$STAGE_PATH:ro")

    if [ -n "$OVERLAY_MOUNTS_ENV" ]; then
        OVERLAY_MOUNTS_ENV="${OVERLAY_MOUNTS_ENV};"
    fi
    OVERLAY_MOUNTS_ENV="${OVERLAY_MOUNTS_ENV}${STAGE_PATH}:${DST}"

    ((++OVERLAY_MOUNT_INDEX))
done

# Pass overlay mount configuration to entrypoint
if [ -n "$OVERLAY_MOUNTS_ENV" ]; then
    log_info "Overlay mounts configured for ephemeral writes"
    DOCKER_CMD+=(-e "OVERLAY_MOUNTS=$OVERLAY_MOUNTS_ENV")
fi

# Mount Docker socket only in insecure mode
if [ "$INSECURE_MODE" = true ]; then
    if [ -S /var/run/docker.sock ]; then
        log_info "Mounting host Docker socket"
        DOCKER_CMD+=(-v /var/run/docker.sock:/var/run/docker.sock)
        # Add user to docker group by matching host docker GID
        DOCKER_GID=$(stat -c '%g' /var/run/docker.sock 2>/dev/null || stat -f '%g' /var/run/docker.sock 2>/dev/null)
        DOCKER_CMD+=(--group-add "$DOCKER_GID")
    else
        log_warn "Docker socket not found at /var/run/docker.sock"
    fi
fi

# Mount Claude credentials and configuration if enabled (using bindfs for permission handling)
if [ "$CLAUDE_CREDS" = true ]; then
    CREDS_MOUNTED=false

    # Mount legacy ~/.claude.json if it exists (binary checks this as fallback)
    # Note: The new binary (v2.1.34+) prefers ~/.claude/.config.json which is
    # included automatically when ~/.claude/ is mounted below.
    if [ -f "$HOME/.claude.json" ]; then
        log_info "Mounting Claude config: ~/.claude.json (legacy, via bindfs)"
        STAGE_PATH="/mnt/bindfs/claude-json"
        DOCKER_CMD+=(-v "$HOME/.claude.json:$STAGE_PATH")
        if [ -n "$BINDFS_MOUNTS" ]; then
            BINDFS_MOUNTS="${BINDFS_MOUNTS};"
        fi
        BINDFS_MOUNTS="${BINDFS_MOUNTS}${STAGE_PATH}:/home/claude/.claude.json"
        CREDS_MOUNTED=true
    fi

    # Check for ~/.claude directory (includes credentials, config, agents, skills, commands, plugins)
    # This also includes ~/.claude/.config.json (new config path since v2.1.34+)
    if [ -d "$HOME/.claude" ]; then
        log_info "Mounting Claude directory: ~/.claude (via bindfs for permissions)"
        STAGE_PATH="/mnt/bindfs/claude-home"
        DOCKER_CMD+=(-v "$HOME/.claude:$STAGE_PATH")
        if [ -n "$BINDFS_MOUNTS" ]; then
            BINDFS_MOUNTS="${BINDFS_MOUNTS};"
        fi
        BINDFS_MOUNTS="${BINDFS_MOUNTS}${STAGE_PATH}:/home/claude/.claude"
        CREDS_MOUNTED=true

        # Log available extensions
        [ -d "$HOME/.claude/agents" ] && log_info "  - Custom agents available"
        [ -d "$HOME/.claude/skills" ] && log_info "  - Custom skills available"
        [ -d "$HOME/.claude/commands" ] && log_info "  - Custom commands available"
        [ -d "$HOME/.claude/plugins" ] && log_info "  - MCP plugins available"
    fi

    # Check for ~/.config/claude directory
    if [ -d "$HOME/.config/claude" ]; then
        log_info "Mounting Claude config: ~/.config/claude (via bindfs)"
        STAGE_PATH="/mnt/bindfs/claude-config"
        DOCKER_CMD+=(-v "$HOME/.config/claude:$STAGE_PATH")
        if [ -n "$BINDFS_MOUNTS" ]; then
            BINDFS_MOUNTS="${BINDFS_MOUNTS};"
        fi
        BINDFS_MOUNTS="${BINDFS_MOUNTS}${STAGE_PATH}:/home/claude/.config/claude"
        CREDS_MOUNTED=true
    fi

    # Also mount .anthropic if it exists (alternative location)
    if [ -d "$HOME/.anthropic" ]; then
        log_info "Mounting Anthropic config: ~/.anthropic (via bindfs)"
        STAGE_PATH="/mnt/bindfs/anthropic"
        DOCKER_CMD+=(-v "$HOME/.anthropic:$STAGE_PATH")
        if [ -n "$BINDFS_MOUNTS" ]; then
            BINDFS_MOUNTS="${BINDFS_MOUNTS};"
        fi
        BINDFS_MOUNTS="${BINDFS_MOUNTS}${STAGE_PATH}:/home/claude/.anthropic"
        CREDS_MOUNTED=true
    fi

    # Mount secrets needed for Claude workflow (e.g., Context Store auth key)
    if [ -d "$HOME/.secrets" ]; then
        log_info "Mounting secrets: ~/.secrets (via bindfs)"
        STAGE_PATH="/mnt/bindfs/secrets"
        DOCKER_CMD+=(-v "$HOME/.secrets:$STAGE_PATH")
        if [ -n "$BINDFS_MOUNTS" ]; then
            BINDFS_MOUNTS="${BINDFS_MOUNTS};"
        fi
        BINDFS_MOUNTS="${BINDFS_MOUNTS}${STAGE_PATH}:/home/claude/.secrets"
        CREDS_MOUNTED=true
    fi

    # Mount ctx CLI if installed (Context Store CLI used by CLAUDE.md workflow)
    if [ -f "/usr/local/bin/ctx" ]; then
        log_info "Mounting ctx CLI: /usr/local/bin/ctx"
        DOCKER_CMD+=(-v "/usr/local/bin/ctx:/usr/local/bin/ctx:ro")
    fi

    # Pass through API key environment variables if set
    if [ -n "$ANTHROPIC_API_KEY" ]; then
        log_info "Passing through ANTHROPIC_API_KEY"
        DOCKER_CMD+=(-e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
        CREDS_MOUNTED=true
    fi

    if [ "$CREDS_MOUNTED" = false ]; then
        log_warn "No Claude credentials found. Run 'claude login' on host first."
    fi
fi

# Pass bindfs mount configuration to entrypoint (after all mounts are processed)
if [ -n "$BINDFS_MOUNTS" ]; then
    log_info "Bindfs remounts configured for permission handling"
    DOCKER_CMD+=(-e "BINDFS_MOUNTS=$BINDFS_MOUNTS")
fi

# Mount /etc/DIR_COLORS if it exists (for ls color support)
if [ -e "/etc/DIR_COLORS" ]; then
    # Follow symlink if it is one
    DIR_COLORS_PATH=$(readlink -f "/etc/DIR_COLORS" 2>/dev/null || echo "/etc/DIR_COLORS")
    if [ -f "$DIR_COLORS_PATH" ]; then
        log_info "Mounting DIR_COLORS: $DIR_COLORS_PATH"
        DOCKER_CMD+=(-v "$DIR_COLORS_PATH:/etc/DIR_COLORS:ro")
    fi
fi

# Set terminal type for proper rendering
DOCKER_CMD+=(-e "TERM=${TERM:-xterm-256color}")

# Forward git configuration (user.name, user.email, init.defaultBranch)
# Read specific settings via git commands to respect includes and conditional configs
GIT_USER_NAME=$(git config --global --get user.name 2>/dev/null || true)
GIT_USER_EMAIL=$(git config --global --get user.email 2>/dev/null || true)
GIT_DEFAULT_BRANCH=$(git config --global --get init.defaultBranch 2>/dev/null || true)

if [ -n "$GIT_USER_NAME" ]; then
    log_info "Forwarding git user.name: $GIT_USER_NAME"
    DOCKER_CMD+=(-e "GIT_USER_NAME=$GIT_USER_NAME")
fi
if [ -n "$GIT_USER_EMAIL" ]; then
    log_info "Forwarding git user.email: $GIT_USER_EMAIL"
    DOCKER_CMD+=(-e "GIT_USER_EMAIL=$GIT_USER_EMAIL")
fi
if [ -n "$GIT_DEFAULT_BRANCH" ]; then
    log_info "Forwarding git init.defaultBranch: $GIT_DEFAULT_BRANCH"
    DOCKER_CMD+=(-e "GIT_DEFAULT_BRANCH=$GIT_DEFAULT_BRANCH")
fi

# Enable Docker-in-Docker mode (default, unless --insecure)
if [ "$DIND_MODE" = true ]; then
    DOCKER_CMD+=(-e "DIND_MODE=true")
fi

# Pass host HOME to container if it differs from /home/claude and /root
# This allows the entrypoint to create a symlink for compatibility (e.g., /Users/username on macOS)
if [ "$HOME" != "/home/claude" ] && [ "$HOME" != "/root" ]; then
    log_info "Passing host HOME path: $HOME"
    DOCKER_CMD+=(-e "HOST_HOME=$HOME")
fi

# Always provide host.docker.internal for reaching the host
DOCKER_CMD+=(--add-host=host.docker.internal:host-gateway)

# Detect host IPs and pass to container for transparent routing
HOST_IPS=$(detect_host_ips)
if [ -n "$HOST_IPS" ]; then
    log_info "Detected host IPs for routing: $HOST_IPS"
    DOCKER_CMD+=(-e "HOST_IPS=$HOST_IPS")
fi

# Add hostname
DOCKER_CMD+=(--hostname sandbox)

# Add the image
DOCKER_CMD+=("$IMAGE_NAME")

# Determine what command to run
if [ ${#EXTRA_ARGS[@]} -gt 0 ]; then
    # User provided explicit command
    DOCKER_CMD+=("${EXTRA_ARGS[@]}")
elif [ -n "$INITIAL_PROMPT" ]; then
    # Run claude with the provided prompt and all permissions skipped
    log_info "Running Claude Code with initial prompt (all permissions skipped)"
    DOCKER_CMD+=(claude --dangerously-skip-permissions -p "$INITIAL_PROMPT")
else
    # Run claude interactively with all permissions skipped (using wrapper to auto-confirm)
    log_info "Running Claude Code interactively (all permissions skipped)"
    DOCKER_CMD+=(claude-wrapper)
fi

# Print the command being run
log_info "Starting sandbox container..."
if [ "$VERBOSE" = true ]; then
    log_info "Docker command: ${DOCKER_CMD[*]}"
fi

# Run the container
exec "${DOCKER_CMD[@]}"
