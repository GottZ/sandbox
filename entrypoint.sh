#!/bin/bash
#
# Entrypoint script for Claude Code Sandbox
# Handles bindfs remounting of volumes to ensure claude user has access
#

set -e

# Ensure Claude config has bypassPermissionsModeAccepted and hasCompletedOnboarding.
# The new ELF binary (Bun-compiled) checks two config paths in order:
#   1. ~/.claude/.config.json  (new path, takes precedence if exists)
#   2. ~/.claude.json           (legacy path)
# We must patch whichever file the binary will actually read.
ensure_claude_config() {
    local claude_dir="/home/claude/.claude"
    local new_config="${claude_dir}/.config.json"
    local legacy_config="/home/claude/.claude.json"
    local required_fields='{"hasCompletedOnboarding":true,"numStartups":1,"bypassPermissionsModeAccepted":true}'

    # Determine which config file the binary will use
    local config_file="$legacy_config"
    if [ -f "$new_config" ]; then
        config_file="$new_config"
    fi

    if [ ! -f "$config_file" ]; then
        # No config exists — create minimal config at legacy path
        log_warn "No config found, creating minimal config at $config_file"
        mkdir -p "$(dirname "$config_file")"
        echo "$required_fields" > "$config_file"
        chown claude:claude "$config_file" 2>/dev/null || true
    else
        # Config exists — ensure bypass and onboarding fields are set
        if command -v jq > /dev/null 2>&1; then
            local needs_update=false
            if [ "$(jq -r '.bypassPermissionsModeAccepted // false' "$config_file" 2>/dev/null)" != "true" ]; then
                needs_update=true
            fi
            if [ "$(jq -r '.hasCompletedOnboarding // false' "$config_file" 2>/dev/null)" != "true" ]; then
                needs_update=true
            fi
            if [ "$needs_update" = "true" ]; then
                log_info "Setting bypassPermissionsModeAccepted + hasCompletedOnboarding in $config_file"
                local tmp_file="${config_file}.tmp"
                jq '. + {"bypassPermissionsModeAccepted": true, "hasCompletedOnboarding": true}' "$config_file" > "$tmp_file" && mv "$tmp_file" "$config_file"
                chown claude:claude "$config_file" 2>/dev/null || true
            fi
        fi
    fi
}

# Colors for output
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[entrypoint]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[entrypoint]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[entrypoint]${NC} $1"
}

log_error() {
    echo -e "${RED}[entrypoint]${NC} $1"
}

# Create symlink for host's $HOME if it differs from /home/claude and /root
# HOST_HOME is passed from claude-sandbox.sh when host $HOME is something else (e.g., /Users/username on macOS)
# /root is already a symlink to /home/claude (created in Dockerfile)
if [ -n "$HOST_HOME" ] && [ "$HOST_HOME" != "/home/claude" ] && [ "$HOST_HOME" != "/root" ]; then
    log_info "Creating symlink for host HOME: $HOST_HOME -> /home/claude"
    # Create parent directories if needed
    mkdir -p "$(dirname "$HOST_HOME")"
    # Remove if exists (file or directory)
    rm -rf "$HOST_HOME" 2>/dev/null || true
    # Create symlink
    ln -s /home/claude "$HOST_HOME"
    log_success "$HOST_HOME is now a symlink to /home/claude"
fi

# Process bindfs mounts from environment variable
# Format: BINDFS_MOUNTS="src1:dst1;src2:dst2;..."
if [ -n "$BINDFS_MOUNTS" ]; then
    log_info "Processing bindfs mounts..."

    IFS=';' read -ra MOUNT_PAIRS <<< "$BINDFS_MOUNTS"
    for pair in "${MOUNT_PAIRS[@]}"; do
        if [ -z "$pair" ]; then
            continue
        fi

        IFS=':' read -ra PARTS <<< "$pair"
        SRC="${PARTS[0]}"
        DST="${PARTS[1]}"

        if [ -z "$SRC" ] || [ -z "$DST" ]; then
            log_warn "Invalid mount pair: $pair"
            continue
        fi

        if [ ! -e "$SRC" ]; then
            log_warn "Source does not exist: $SRC"
            continue
        fi

        # Create destination parent directory if it doesn't exist
        DST_PARENT=$(dirname "$DST")
        sudo mkdir -p "$DST_PARENT"
        sudo chown claude:claude "$DST_PARENT" 2>/dev/null || true

        # Handle file vs directory mounts differently
        if [ -f "$SRC" ]; then
            # For files, copy with proper ownership instead of bindfs
            log_info "Copying file $SRC -> $DST (with claude ownership)"
            sudo cp "$SRC" "$DST"
            sudo chown claude:claude "$DST"
            sudo chmod 666 "$DST"
        else
            # Create destination directory for directory mounts
            sudo mkdir -p "$DST"

            # Use bindfs to remap ownership to claude user
            # --force-user/group ensures all files appear owned by claude
            # --perms=a+rwX ensures full read-write-execute permissions
            log_info "Bindfs mounting $SRC -> $DST (remapping to claude:claude)"
            sudo bindfs \
                --force-user=claude \
                --force-group=claude \
                --perms=a+rwX \
                --create-for-user=1000 \
                --create-for-group=1000 \
                -o nonempty \
                "$SRC" "$DST"
        fi

        log_success "Mounted: $SRC -> $DST"
    done
fi

# Process individual BINDFS_MOUNT_N variables for flexibility
i=0
while true; do
    VAR_NAME="BINDFS_MOUNT_$i"
    MOUNT_SPEC="${!VAR_NAME}"

    if [ -z "$MOUNT_SPEC" ]; then
        break
    fi

    IFS=':' read -ra PARTS <<< "$MOUNT_SPEC"
    SRC="${PARTS[0]}"
    DST="${PARTS[1]}"

    if [ -n "$SRC" ] && [ -n "$DST" ] && [ -e "$SRC" ]; then
        DST_PARENT=$(dirname "$DST")
        sudo mkdir -p "$DST_PARENT"
        sudo chown claude:claude "$DST_PARENT" 2>/dev/null || true

        if [ -f "$SRC" ]; then
            log_info "Copying file $SRC -> $DST (with claude ownership)"
            sudo cp "$SRC" "$DST"
            sudo chown claude:claude "$DST"
            sudo chmod 666 "$DST"
        else
            sudo mkdir -p "$DST"
            log_info "Bindfs mounting $SRC -> $DST (remapping ownership)"
            sudo bindfs \
                --force-user=claude \
                --force-group=claude \
                --perms=a+rwX \
                --create-for-user=1000 \
                --create-for-group=1000 \
                -o nonempty \
                "$SRC" "$DST"
        fi

        log_success "Mounted: $SRC -> $DST"
    fi

    ((i++))
done

# Ensure Claude config exists (fallback)
ensure_claude_config

# Apply forwarded git configuration
# These are passed as environment variables from the host
if [ -n "$GIT_USER_NAME" ]; then
    log_info "Setting git user.name: $GIT_USER_NAME"
    git config --global user.name "$GIT_USER_NAME"
fi
if [ -n "$GIT_USER_EMAIL" ]; then
    log_info "Setting git user.email: $GIT_USER_EMAIL"
    git config --global user.email "$GIT_USER_EMAIL"
fi
if [ -n "$GIT_DEFAULT_BRANCH" ]; then
    log_info "Setting git init.defaultBranch: $GIT_DEFAULT_BRANCH"
    git config --global init.defaultBranch "$GIT_DEFAULT_BRANCH"
fi

# Start Docker daemon if DIND_MODE is enabled
if [ "$DIND_MODE" = "true" ] || [ "$DIND_MODE" = "1" ]; then
    log_info "Starting Docker-in-Docker daemon..."

    # Create docker data directory
    sudo mkdir -p /var/lib/docker

    # Start containerd first (redirect handled inside sudo)
    sudo sh -c 'containerd > /var/log/containerd.log 2>&1 &'
    sleep 1

    # Start dockerd in background
    # Use fuse-overlayfs if available, otherwise fall back to vfs
    # (overlay2 doesn't work well in nested container environments)
    if command -v fuse-overlayfs > /dev/null 2>&1; then
        STORAGE_DRIVER="fuse-overlayfs"
    else
        STORAGE_DRIVER="vfs"
    fi
    log_info "Using storage driver: $STORAGE_DRIVER"

    sudo sh -c "dockerd \
        --host=unix:///var/run/docker.sock \
        --host=tcp://0.0.0.0:2375 \
        --tls=false \
        --storage-driver=$STORAGE_DRIVER \
        > /var/log/dockerd.log 2>&1 &"

    # Wait for Docker to be ready
    log_info "Waiting for Docker daemon to be ready..."
    ATTEMPTS=0
    MAX_ATTEMPTS=30
    while ! sudo docker info > /dev/null 2>&1; do
        ATTEMPTS=$((ATTEMPTS + 1))
        if [ $ATTEMPTS -ge $MAX_ATTEMPTS ]; then
            log_error "Docker daemon failed to start. Check /var/log/dockerd.log"
            sudo cat /var/log/dockerd.log 2>/dev/null | tail -50
            exit 1
        fi
        sleep 1
    done
    log_success "Docker daemon is ready"

    # Add claude user to docker group for socket access
    sudo usermod -aG docker claude 2>/dev/null || true
    sudo chmod 666 /var/run/docker.sock
fi

# Execute the command passed to the container as claude user
# Use sudo with -E to preserve env vars, but explicitly set PATH (sudo filters it by default)
exec sudo -u claude -E PATH="/home/claude/.local/bin:/home/claude/go/bin:/home/claude/.cargo/bin:/home/claude/.bun/bin:/usr/local/go/bin:/opt/zig:$PATH" -- "$@"
