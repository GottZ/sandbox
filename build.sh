#!/usr/bin/env bash
#
# Build the Claude Code Development Sandbox image
#

set -e

# Resolve the real directory of this script (handles symlinks)
resolve_script_dir() {
    local source="${BASH_SOURCE[0]}"
    while [ -L "$source" ]; do
        local dir="$(cd -P "$(dirname "$source")" && pwd)"
        source="$(readlink "$source")"
        [[ "$source" != /* ]] && source="$dir/$source"
    done
    cd -P "$(dirname "$source")" && pwd
}

SCRIPT_DIR="$(resolve_script_dir)"
IMAGE_NAME="claude-sandbox"
NO_CACHE=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --clean)
            NO_CACHE="--no-cache"
            shift
            ;;
        *)
            echo "Usage: $(basename "$0") [--clean]"
            echo "  --clean   Build from scratch (no cache)"
            exit 1
            ;;
    esac
done

if [ -n "$NO_CACHE" ]; then
    echo "Building $IMAGE_NAME from scratch (no cache)..."
else
    echo "Building $IMAGE_NAME..."
fi

docker build $NO_CACHE -t "$IMAGE_NAME" "$SCRIPT_DIR"
