#!/usr/bin/env bash
# Persistent Xvfb display for the cloud render box, owned separately from the war.
# Both the war (spring) and the stream (ffmpeg) attach to this :99, so a war restart
# never tears the display out from under the stream's x11grab. pm2 keeps it alive.
set -uo pipefail
DISP="${DISPLAY_NUM:-:99}"
RES="${RES:-1920x1080}"
exec Xvfb "$DISP" -screen 0 "${RES}x24" \
    +extension GLX +extension RANDR +extension RENDER +extension MIT-SHM +iglx \
    -nolisten tcp
