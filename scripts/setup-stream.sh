#!/usr/bin/env bash
# One-time privileged setup for the phase-2 streamer. Idempotent.
# Run:  sudo bash scripts/setup-stream.sh
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
REAL_USER="${SUDO_USER:?run via sudo, not as root login}"

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    ffmpeg xvfb vainfo intel-media-va-driver-non-free intel-gpu-tools

# persistent GPU access for future sessions
usermod -aG render,video "$REAL_USER"
# immediate access for the CURRENT session (no relogin)
setfacl -m "u:$REAL_USER:rw" /dev/dri/renderD128 /dev/dri/card0

echo "--- verify VAAPI:"
sudo -u "$REAL_USER" vainfo --display drm --device /dev/dri/renderD128 2>/dev/null \
    | grep -m4 "Driver version\|H264" || echo "vainfo failed — check driver"
echo "setup done. ffmpeg $(ffmpeg -version | head -c 30)"
