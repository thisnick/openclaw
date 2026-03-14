#!/usr/bin/env bash
# Starts Xvfb + x11vnc + noVNC in the background, then execs the gateway.
# Chromium itself is launched by the gateway's browser control service.
set -euo pipefail

export DISPLAY=:1

# Clean stale X lock files from previous runs (container restarts)
rm -f /tmp/.X1-lock /tmp/.X11-unix/X1

# Clean stale Chrome singleton locks (prevents "File exists" abort on restart)
rm -f /home/node/.openclaw/browser/*/user-data/Singleton*

# Virtual framebuffer
Xvfb :1 -screen 0 1280x800x24 -ac -nolisten tcp &

# Wait for Xvfb to be ready
for _ in $(seq 1 50); do
  if xdpyinfo -display :1 >/dev/null 2>&1; then break; fi
  sleep 0.1
done

# VNC server (localhost-only — noVNC proxies it to the network)
x11vnc -display :1 -rfbport 5900 -shared -forever -nopw -localhost &

# noVNC web client
websockify --web /usr/share/novnc/ 6080 localhost:5900 &

# Hand off to the original command (gateway)
exec "$@"
