#!/bin/bash
#
# Entrypoint script for Claude Code Sandbox
# Handles bindfs remounting of volumes to ensure claude user has access
#

set -e

# Ensure Claude config exists (fallback if ~/.claude.json not mounted)
ensure_claude_config() {
    local config_file="/home/claude/.claude.json"

    # Only create if it doesn't exist (prefer mounted config from host)
    if [ ! -f "$config_file" ]; then
        log_warn "No ~/.claude.json mounted, creating minimal config"
        echo '{"hasCompletedOnboarding":true,"numStartups":1}' > "$config_file"
        chown claude:claude "$config_file" 2>/dev/null || true
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

# Execute the command passed to the container
exec "$@"
