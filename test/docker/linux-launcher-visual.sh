#!/bin/bash
# Run the Linux launcher in a container with a VISIBLE screen you can watch and
# click on from macOS, via VNC (Screen Sharing). The game renders inside the
# container with software OpenGL (llvmpipe) — correct but sluggish; this is for
# eyeballing/interacting, not perf. Streaming the framebuffer over VNC avoids the
# flakiness of forwarding an OpenGL app over X11.
#
# Requires colima + docker:  brew install colima docker && colima start
# Usage:
#   zsh test/docker/linux-launcher-visual.sh [LAUNCHER_ZIP_URL]
# Env: IMAGE (default ubuntu:22.04), VNC_PASS (default "panel"), NAME (default palinux)
# Stop it when done:  docker rm -f palinux

set -euo pipefail

LAUNCHER_URL="${1:-https://github.com/briankeegan/panel-game/releases/download/launcher/unofficial-panel-attack-ffa-and-team-linux.zip}"
IMAGE="${IMAGE:-ubuntu:22.04}"
VNC_PASS="${VNC_PASS:-panel}"
NAME="${NAME:-palinux}"

command -v docker >/dev/null 2>&1 || { echo "docker not found. Run: brew install colima docker && colima start"; exit 2; }
docker info >/dev/null 2>&1 || { echo "docker daemon unreachable. Run: colima start"; exit 2; }

# colima only mounts $HOME (NOT /tmp), so stage the container script under $HOME.
RUNFILE="$HOME/.palinux-run.sh"
cat > "$RUNFILE" <<EOF
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq curl unzip ca-certificates x11vnc xvfb \\
  libgl1-mesa-dri libgl1 libglx-mesa0 libegl1 \\
  libx11-6 libxext6 libxrandr2 libxcursor1 libxi6 libxinerama1 libxfixes3 \\
  libssl3 libopenal1 >/dev/null 2>&1
export SDL_AUDIODRIVER=dummy
cd /root
curl -fsSL "$LAUNCHER_URL" -o l.zip
unzip -q -o l.zip -d app < /dev/null      # .DirIcon collision + dirs stored mode 000
cd app && chmod -R u+rwX .
Xvfb :99 -screen 0 1280x720x24 >/dev/null 2>&1 &
sleep 3
export DISPLAY=:99
# Bake the password in from the start: macOS Screen Sharing refuses to connect to a
# no-password VNC server, so -nopw will not work here.
x11vnc -storepasswd "$VNC_PASS" /tmp/vncpw >/dev/null 2>&1
x11vnc -display :99 -forever -shared -rfbauth /tmp/vncpw -rfbport 5900 -bg -o /tmp/x11vnc.log >/dev/null 2>&1
echo READY
exec ./AppRun
EOF

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run --rm -d -p 5900:5900 --name "$NAME" -v "$RUNFILE:/run.sh:ro" "$IMAGE" bash /run.sh >/dev/null
echo "Starting '$NAME' (installing deps + downloading launcher, ~1-2 min)..."
for _ in $(seq 1 90); do
  docker logs "$NAME" 2>&1 | grep -q READY && break
  docker ps --filter "name=$NAME" -q | grep -q . || { echo "container exited early:"; docker logs "$NAME" 2>&1 | tail -15; exit 1; }
  sleep 3
done

echo
echo "Ready. Connect from macOS:"
echo "    open vnc://localhost:5900       (password: $VNC_PASS)"
echo "First scene may be Input Config (fresh machine has no controls set) — normal."
echo "Stop when done:   docker rm -f $NAME"
open "vnc://localhost:5900" 2>/dev/null || true
