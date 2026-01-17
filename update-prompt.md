# Updating Tool Versions

Use this prompt with Claude Code to update all tool versions in the Dockerfile to their latest releases.

## Update Prompt

```
Research the latest stable versions for all tools in the Dockerfile and update them:

1. **Node.js** - Check nodejs.org for current LTS version
2. **Zig** - Check ziglang.org/download for latest stable
3. **zls** - Must match Zig version, check github.com/zigtools/zls/releases
4. **ripgrep** - Check github.com/BurntSushi/ripgrep/releases
5. **fd** - Check github.com/sharkdp/fd/releases
6. **bat** - Check github.com/sharkdp/bat/releases
7. **yq** - Using /latest redirect, verify it works
8. **Bun** - Using install script, always gets latest

Update the Dockerfile with correct:
- Version numbers in URLs
- Extracted directory names (they include version)
- Any changed URL patterns

Also update README.md version references.
```

## Manual Version Check URLs

| Tool | Check URL |
|------|-----------|
| Node.js LTS | https://nodejs.org/en/about/previous-releases |
| Zig | https://ziglang.org/download/ |
| zls | https://github.com/zigtools/zls/releases |
| ripgrep | https://github.com/BurntSushi/ripgrep/releases |
| fd | https://github.com/sharkdp/fd/releases |
| bat | https://github.com/sharkdp/bat/releases |
| yq | https://github.com/mikefarah/yq/releases |
| Bun | https://github.com/oven-sh/bun/releases |
| Ubuntu | https://hub.docker.com/_/ubuntu/tags |

## Version Patterns in Dockerfile

When updating, watch for these patterns:

### ripgrep
```dockerfile
# URL pattern: /download/VERSION/ripgrep_VERSION-1_amd64.deb
curl -LO https://github.com/BurntSushi/ripgrep/releases/download/15.1.0/ripgrep_15.1.0-1_amd64.deb
```

### fd
```dockerfile
# URL pattern: /download/vVERSION/fd_VERSION_amd64.deb
curl -LO https://github.com/sharkdp/fd/releases/download/v10.3.0/fd_10.3.0_amd64.deb
```

### bat
```dockerfile
# URL pattern: /download/vVERSION/bat_VERSION_amd64.deb
curl -LO https://github.com/sharkdp/bat/releases/download/v0.26.0/bat_0.26.0_amd64.deb
```

### Node.js
```dockerfile
# URL pattern: setup_MAJOR.x
curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
```

### Zig
```dockerfile
# URL pattern includes version in both URL and extracted dir name
curl -LO https://ziglang.org/download/0.15.2/zig-x86_64-linux-0.15.2.tar.xz
tar -xf zig-x86_64-linux-0.15.2.tar.xz
mv zig-x86_64-linux-0.15.2 /opt/zig
```

### zls
```dockerfile
# Must match Zig major.minor version
curl -LO https://github.com/zigtools/zls/releases/download/0.15.0/zls-x86_64-linux.tar.xz
```

## Verification After Update

After updating, build and verify:

```bash
# Rebuild image
docker build --no-cache -t claude-sandbox .

# Verify versions
docker run --rm claude-sandbox bash -c '
echo "=== Versions ==="
node --version
bun --version
rustc --version
zig version
zls --version
rg --version
fd --version
bat --version
yq --version
'
```

## Current Versions (as of January 2026)

| Tool | Version |
|------|---------|
| Ubuntu | 24.04 LTS |
| Node.js | 24.x LTS (Krypton) |
| Bun | ~1.3.x |
| Rust | stable |
| Zig | 0.15.2 |
| zls | 0.15.0 |
| ripgrep | 15.1.0 |
| fd | 10.3.0 |
| bat | 0.26.0 |
| yq | 4.50.x |
