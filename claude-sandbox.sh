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
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
WORKDIR="/workspace"
INTERACTIVE=true
MOUNTS=()
DIND_MODE=true      # Default: isolated Docker daemon
INSECURE_MODE=false # When true: expose host Docker socket and PID namespace
CLAUDE_CREDS=true
EXTRA_ARGS=()
INITIAL_PROMPT=""

usage() {
    cat << EOF
${BLUE}Claude Code Development Sandbox${NC}

Usage: $(basename "$0") [OPTIONS] [-- COMMAND]

${GREEN}Options:${NC}
  -w, --workdir PATH       Set working directory inside container (default: /workspace)
  -m, --mount SRC:DST      Mount a host directory (can be used multiple times)
                           SRC = host path, DST = container path
                           If DST is omitted, mounts to /workspace/\$(basename SRC)
                           Default: current directory mounted to /workspace
  -p, --prompt PROMPT      Initial prompt to pass to Claude Code
  -d, --detach             Run container in background
  --insecure               Expose host Docker socket and PID namespace (less isolated)
  --no-creds               Don't mount Claude credentials
  -n, --name NAME          Set container name (default: auto-generated)
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
    - Claude Code runs with --permission-mode bypassPermissions (no prompts)

${GREEN}Mount Handling:${NC}
  Mounts are automatically checked for accessibility:
    - If a mount is owned by root or not writable, bindfs is used to remap
      ownership to the claude user inside the container
    - This ensures the claude user can always read/write mounted directories
    - Permission issues are detected before container startup

EOF
    exit 0
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

# Default to mounting current directory if no mounts specified
if [ ${#MOUNTS[@]} -eq 0 ]; then
    MOUNTS+=("$(pwd):/workspace")
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

    # If no destination, use /workspace/basename
    if [ -z "$DST" ]; then
        DST="/workspace/$(basename "$SRC")"
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

    # Check for ~/.claude.json (main config with onboarding state)
    if [ -f "$HOME/.claude.json" ]; then
        log_info "Mounting Claude config: ~/.claude.json (via bindfs)"
        STAGE_PATH="/mnt/bindfs/claude-json"
        DOCKER_CMD+=(-v "$HOME/.claude.json:$STAGE_PATH")
        if [ -n "$BINDFS_MOUNTS" ]; then
            BINDFS_MOUNTS="${BINDFS_MOUNTS};"
        fi
        BINDFS_MOUNTS="${BINDFS_MOUNTS}${STAGE_PATH}:/home/claude/.claude.json"
        CREDS_MOUNTED=true
    fi

    # Check for ~/.claude directory (includes credentials, agents, skills, commands, plugins)
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
    DOCKER_CMD+=(claude --allow-dangerously-skip-permissions --permission-mode bypassPermissions -p "$INITIAL_PROMPT")
else
    # Run claude interactively with all permissions skipped (using wrapper to auto-confirm)
    log_info "Running Claude Code interactively (all permissions skipped)"
    DOCKER_CMD+=(claude-wrapper)
fi

# Print the command being run (for debugging)
log_info "Starting sandbox container..."

# Run the container
exec "${DOCKER_CMD[@]}"
