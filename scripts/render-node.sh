#!/usr/bin/env bash
# Render-node streamer for a cloud GPU box (vast.ai). A GPU spectator joins the
# war over the internet (home router forwards HOST_PORT/udp) and NVENC-encodes
# the rendered game to RTMP.
#
# This is stream.sh's twin, retargeted from the home iGPU to a real NVIDIA card:
#   - VirtualGL uses the EGL backend (VGL_DISPLAY=egl), not a GLX device path.
#     A cloud desktop container runs a *software* Xvfb; EGL routes GL to the GPU
#     and reads pixels back into that framebuffer for x11grab to capture.
#   - Encoder is h264_nvenc, not VAAPI.
#   - HostIP is the war host's PUBLIC ip, not 127.0.0.1.
#
# Usage on the render node:
#   HOST_IP=1.2.3.4 ./render-node.sh --test          # 30s capture -> $BASE/test.mp4
#   HOST_IP=1.2.3.4 STREAM_KEY=xxxx ./render-node.sh  # live to $RTMP_URL/$STREAM_KEY
set -uo pipefail

BASE="${BASE:-/root/bar-render}"
ENGINE="$BASE/engine/spring"
DATA="$BASE/data"
LOGS="$BASE/logs"; mkdir -p "$LOGS"

HOST_IP="${HOST_IP:?set HOST_IP to the war host public IP}"
HOST_PORT="${HOST_PORT:-8452}"
NAME="${NAME:-Director}"
DISP="${DISPLAY_NUM:-:99}"
RES="${RES:-1920x1080}"
FPS="${FPS:-30}"
BITRATE="${BITRATE:-6M}"
RTMP_URL="${RTMP_URL:-rtmp://a.rtmp.youtube.com/live2}"
LOAD_WAIT="${LOAD_WAIT:-45}"
MODE="${1:-live}"

# Real GPU: we can afford quality. VSync off so ffmpeg paces the capture.
cat > "$DATA/springsettings.cfg" <<EOF
XResolution = ${RES%x*}
YResolution = ${RES#*x}
Fullscreen = 0
WindowPosX = 0
WindowPosY = 0
Shadows = 1
Water = 1
VSync = 0
LogFlushLevel = 3
EOF

cat > "$DATA/join.txt" <<EOF
[GAME]
{
    HostIP=$HOST_IP;
    HostPort=$HOST_PORT;
    MyPlayerName=$NAME;
    IsHost=0;
    Spectator=1;
}
EOF

XVFB_PID=""; SPRING_PID=""; FFMPEG_PID=""
cleanup() { kill $XVFB_PID $SPRING_PID $FFMPEG_PID 2>/dev/null; exit 0; }
trap cleanup INT TERM

# Software X framebuffer sized exactly to the capture; GL is redirected to the
# GPU by VirtualGL/EGL, so this display only holds the read-back pixels.
Xvfb "$DISP" -screen 0 "${RES}x24" \
    +extension GLX +extension RANDR +extension RENDER +extension MIT-SHM +iglx \
    -nolisten tcp >> "$LOGS/xvfb.log" 2>&1 &
XVFB_PID=$!
sleep 3

# SDL_AUDIODRIVER=dummy: the container's PipeWire runs as another user, so real
# audio init aborts the engine. We stream silence anyway, so give it a null sink.
( cd "$DATA" && DISPLAY="$DISP" VGL_DISPLAY=egl SDL_AUDIODRIVER=dummy vglrun \
    "$ENGINE" --write-dir "$DATA" "$DATA/join.txt" ) \
    >> "$LOGS/spring.log" 2>&1 &
SPRING_PID=$!
echo "spectator loading (connecting to $HOST_IP:$HOST_PORT as $NAME)..."
sleep "$LOAD_WAIT"

if [ "$MODE" = "--test" ]; then
    OUT=("$BASE/test.mp4"); EXTRA=(-t 30 -y)
    echo "test capture: 30s -> $BASE/test.mp4"
else
    [ -n "${STREAM_KEY:-}" ] || { echo "STREAM_KEY not set"; cleanup; }
    OUT=(-f flv "$RTMP_URL/$STREAM_KEY"); EXTRA=()
    echo "streaming to $RTMP_URL/<key>"
fi

ffmpeg -hide_banner -loglevel warning \
    -f x11grab -framerate "$FPS" -video_size "$RES" -i "$DISP" \
    -f lavfi -i anullsrc=channel_layout=stereo:sample_rate=44100 \
    -c:v h264_nvenc -preset p5 -b:v "$BITRATE" -maxrate "$BITRATE" \
        -bufsize "$BITRATE" -g $((FPS * 2)) \
    -c:a aac -b:a 128k -shortest "${EXTRA[@]}" "${OUT[@]}" \
    >> "$LOGS/ffmpeg.log" 2>&1 &
FFMPEG_PID=$!

echo "$(date -Is) render-node up: xvfb=$XVFB_PID spring=$SPRING_PID ffmpeg=$FFMPEG_PID"
wait $FFMPEG_PID
cleanup
