# Custom OpenClaw Docker Setup (WSL2)

This documents the custom OpenClaw Docker setup running on WSL2, including
the agent-wechat integration, browser stack, and additional tools.

## Architecture

```
docker-compose.yml (upstream)
  + docker-compose.override.yml (custom overrides)

openclaw:local     ← upstream Dockerfile (base OpenClaw image)
openclaw:custom    ← Dockerfile.custom (adds tools + browser stack)

Services:
  openclaw-gateway  — OpenClaw gateway + Xvfb/VNC + Chromium
  openclaw-cli      — OpenClaw CLI (shares network with gateway)
  agent-wechat      — WeChat automation server (port 6174)
```

## Files

| File                                | Purpose                                                           |
| ----------------------------------- | ----------------------------------------------------------------- |
| `Dockerfile.custom`                 | Custom image layer: Chromium, VNC, gh, uv, bird, gogcli, goplaces |
| `docker-compose.override.yml`       | Service definitions, volumes, ports, agent-wechat                 |
| `scripts/gateway-vnc-entrypoint.sh` | Starts Xvfb + x11vnc + noVNC before the gateway                   |
| `~/.openclaw/openclaw.json`         | OpenClaw runtime config (browser, channels, plugins)              |

## How It Works

### Two-layer Docker build

1. **Base image** (`openclaw:local`): Built from the upstream `Dockerfile`.
   Contains the OpenClaw gateway, CLI, and all official code.

2. **Custom image** (`openclaw:custom`): Built from `Dockerfile.custom`,
   which starts `FROM openclaw:local`. Adds your tools and customizations.

The `docker-compose.override.yml` tells Compose to build `openclaw:custom`
via `build: { context: ., dockerfile: Dockerfile.custom }`.

### Volumes

| Volume                     | Mount          | Purpose                                                      |
| -------------------------- | -------------- | ------------------------------------------------------------ |
| `openclaw-node-home`       | `/home/node`   | All user data: configs, keyrings, Chrome profiles, npm cache |
| `agent-wechat-data`        | `/data`        | agent-wechat SQLite DB                                       |
| `agent-wechat-wechat-home` | `/home/wechat` | WeChat app data                                              |

The `/home/node` named volume auto-populates from the image on first create.
Bind mounts for specific paths (like `/home/node/code`) override within it.

### Networking

All services share a Docker Compose bridge network (`openclaw_default`).
Containers reach each other by service name:

- Gateway → agent-wechat: `http://agent-wechat:6174`
- CLI shares gateway's network via `network_mode: "service:openclaw-gateway"`

### Browser (Chromium + VNC)

The gateway container runs a headless Chromium with a virtual display:

- `Xvfb :1` — virtual framebuffer
- `x11vnc` on port 5900 (localhost only)
- `noVNC` (websockify) on port 6080 — web-based VNC client

Access the VNC view at `http://localhost:6080/vnc.html`.

The entrypoint script cleans stale Chrome lock files on restart to prevent
"File exists" errors.

## Common Operations

### Updating to a new OpenClaw release

```bash
cd /home/nick/code/openclaw

# Fetch the new release tag
git fetch origin --tags

# Rebase your custom branch onto the new tag
git rebase v2026.x.y

# Rebuild both images
docker build -t openclaw:local -f Dockerfile .
docker compose build openclaw-gateway

# Restart (preserves volumes/data)
docker compose down openclaw-gateway openclaw-cli
docker compose up -d openclaw-gateway openclaw-cli
```

### Adding a system package

Edit `Dockerfile.custom`, add to the appropriate `apt-get install` block
or add a new `RUN` layer:

```dockerfile
RUN apt-get update && \
    apt-get install -y --no-install-recommends your-package && \
    apt-get clean && rm -rf /var/lib/apt/lists/*
```

Then rebuild:

```bash
docker compose build openclaw-gateway
docker compose down openclaw-gateway openclaw-cli
docker compose up -d openclaw-gateway openclaw-cli
```

### Adding a CLI tool (binary)

Add a `RUN` layer in `Dockerfile.custom` that downloads and installs to
`/usr/local/bin/`:

```dockerfile
RUN curl -fsSL https://example.com/tool-v1.0.tar.gz \
      | tar -xz -C /usr/local/bin tool-binary-name
```

### Adding an npm global package

```dockerfile
RUN npm install -g package-name
```

### Upgrading a tool version

Change the version in the relevant `RUN` layer in `Dockerfile.custom`,
then rebuild with `--no-cache` to force re-download:

```bash
docker compose build --no-cache openclaw-gateway
```

### Restarting only the gateway

```bash
# Must restart both gateway and CLI together (CLI depends on gateway's network)
docker compose down openclaw-gateway openclaw-cli
docker compose up -d openclaw-gateway openclaw-cli
```

Using `docker compose restart openclaw-gateway` alone will break the CLI
container because it uses `network_mode: "service:openclaw-gateway"`.

### Restarting agent-wechat

```bash
docker compose restart agent-wechat
```

### Clearing agent-wechat data (fresh start)

```bash
docker compose stop agent-wechat
docker compose rm -f agent-wechat
docker volume rm openclaw_agent-wechat-data openclaw_agent-wechat-wechat-home
docker compose up -d agent-wechat
```

### Viewing logs

```bash
docker compose logs -f openclaw-gateway      # follow gateway logs
docker compose logs -f agent-wechat          # follow agent-wechat logs
docker compose logs --tail=100 openclaw-gateway  # last 100 lines
```

### Docker disk cleanup

```bash
# Remove stopped containers, unused networks, dangling images
docker system prune

# WARNING: prune -a also removes ALL unused images including openclaw:local
# You'll need to rebuild from scratch if you do this
docker system prune -a
```

### OpenClaw TUI (terminal UI)

```bash
docker compose exec -it openclaw-cli openclaw tui
```

## Installed Tools

| Tool              | Version    | Purpose                                                    |
| ----------------- | ---------- | ---------------------------------------------------------- |
| Chromium          | (apt)      | Browser tool for web tasks                                 |
| GitHub CLI (`gh`) | (apt)      | GitHub operations                                          |
| `uv` / `uvx`      | latest     | Python package manager (e.g., `uvx awesome-cheap-flights`) |
| `bird`            | npm global | @steipete/bird                                             |
| `gogcli` (`gog`)  | v0.11.0    | GOG game library management                                |
| `goplaces`        | v0.3.0     | Google Places API tool                                     |

## WeChat Integration

The agent-wechat extension is bind-mounted into the gateway at
`/app/extensions/wechat/` (read-only). Source files live at
`/home/nick/code/agent-wechat/packages/openclaw-extension/`.

Configuration in `~/.openclaw/openclaw.json`:

```json
{
  "channels": {
    "wechat": {
      "enabled": true,
      "serverUrl": "http://agent-wechat:6174",
      "dmPolicy": "open",
      "groupPolicy": "open"
    }
  },
  "plugins": {
    "entries": {
      "wechat": { "enabled": true }
    }
  }
}
```

### WeChat login

```bash
cd /home/nick/code/agent-wechat
pnpm cli auth login
```

Scan the QR code with your phone. Login state persists in the
`agent-wechat-wechat-home` volume.

## Git Workflow

Custom changes live on the `nick/custom` branch. The workflow for updating:

```bash
git fetch origin --tags
git rebase v2026.x.y       # rebase onto new release
# resolve any conflicts
docker build -t openclaw:local -f Dockerfile .
docker compose build openclaw-gateway
docker compose down openclaw-gateway openclaw-cli
docker compose up -d openclaw-gateway openclaw-cli
```
