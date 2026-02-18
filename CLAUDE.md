# Claude Code Development Sandbox

Docker-based sandbox for running Claude Code in an isolated container with full dev tooling.

## Architecture

```
Host                          Container (/home/claude)
~/.claude/ ──bindfs──────────> .claude/        (config, creds, agents, skills, commands, plugins, hooks)
~/.secrets/ ──bindfs─────────> .secrets/       (auth keys, e.g. n8n-ctx)
/usr/local/bin/ctx ──direct──> /usr/local/bin/ctx (read-only)
$(pwd) ──mount/overlay───────> /workspace      (working directory)
```

**User model:** Container runs as `claude` (uid 1000). `/root` is a symlink to `/home/claude`. Host volumes are bindfs-remapped to `claude:claude` ownership.

## Key Files

| File | Purpose |
|---|---|
| `Dockerfile` | Image build — Ubuntu 24.04, Node 24, Bun, Go, Rust, Zig, Playwright, Claude Code |
| `claude-sandbox.sh` | Host-side launcher — argument parsing, mount setup, docker run assembly |
| `entrypoint.sh` | Container-side init — bindfs remounts, overlay mounts, config patching, dind, git config |
| `claude-wrapper.sh` | Thin wrapper: `exec claude --dangerously-skip-permissions "$@"` |
| `build.sh` | `docker build -t claude-sandbox .` with optional `--clean` |

## How Mounts Work

1. **Regular mounts (`-m`):** If host dir is root-owned or not writable, staged to `/mnt/bindfs/N` then bindfs-remounted to final destination by entrypoint.
2. **Overlay mounts (`-M`):** Host dir mounted `:ro` to `/mnt/overlay/N`, then overlayfs with tmpfs-backed upper layer gives ephemeral writes.
3. **Credential mounts:** `~/.claude/`, `~/.secrets/`, `~/.anthropic/`, `~/.config/claude/` always go through bindfs for permission remapping. `/usr/local/bin/ctx` mounted read-only directly.

## Config Patching (entrypoint)

Claude Code binary (Bun-compiled ELF) checks config in order:
1. `~/.claude/.config.json` (new path, takes precedence)
2. `~/.claude.json` (legacy)

Entrypoint ensures `bypassPermissionsModeAccepted: true` and `hasCompletedOnboarding: true` in whichever file exists, so the binary starts without interactive dialogs.

## Conventions

- Default branch: `root` (not main/master)
- Commit style: imperative, concise — see git log
- All scripts use `set -e` and are bash
- No `~/.config/claude/` exists on the host currently — the mount is conditional
- `DIND_MODE=true` by default (isolated docker daemon); `--insecure` exposes host docker
- `HOST_HOME` env var handles macOS-style home paths (`/Users/...`) by creating a symlink
- `HOST_IPS` env var + iptables DNAT lets container reach host services via their LAN IPs
