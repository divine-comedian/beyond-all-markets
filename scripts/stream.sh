#!/usr/bin/env bash
# Phase-2 streamer: render the war as a LOCAL SPECTATOR and push it out.
# Never touches the host engine — a separate spring process with its own
# write-dir joins 127.0.0.1:$HOST_PORT like any remote viewer.
#
# Usage:
#   scripts/stream.sh --test          # 30s capture to data/streamer/test.mp4 (measure fps/quality)
#   STREAM_KEY=xxxx scripts/stream.sh # live to $STREAM_RTMP_URL/$STREAM_KEY
#
# Requires scripts/setup-stream.sh to have been run once (ffmpeg, xvfb, vaapi).
set -uo pipefail
source "$(dirname "$0")/../config/war.env"

MODE="${1:-live}"
DISP="${STREAM_DISPLAY:-:99}"
RES="${STREAM_RES:-1280x720}"
FPS="${STREAM_FPS:-30}"
BITRATE="${STREAM_BITRATE:-4500k}"
RTMP_URL="${STREAM_RTMP_URL:-rtmp://a.rtmp.youtube.com/live2}"

SPEC_DIR="$DATA_DIR/streamer"
mkdir -p "$SPEC_DIR" "$DATA_DIR/logs"

# streamer shares the host's archives (same trick as spectate.sh)
for d in pool packages maps games rapid; do
    [ -e "$DATA_DIR/$d" ] && ln -sfn "$DATA_DIR/$d" "$SPEC_DIR/$d"
done

# graphics settings that keep software GL alive; harmless on a real GPU
cat > "$SPEC_DIR/springsettings.cfg" <<EOF
XResolution = ${RES%x*}
YResolution = ${RES#*x}
Fullscreen = 0
Shadows = 0
ShadowMapSize = 1024
Water = 0
AdvUnitShading = 0
AdvMapShading = 0
UsePBO = 0
MSAALevel = 0
VSync = 0
LogFlushLevel = 0
EOF

cat > "$SPEC_DIR/join.txt" <<EOF
[GAME]
{
    HostIP=127.0.0.1;
    HostPort=$HOST_PORT;
    MyPlayerName=Streamer;
    IsHost=0;
    Spectator=1;
}
EOF

XVFB_PID=""; SPRING_PID=""; FFMPEG_PID=""
cleanup() { kill $XVFB_PID $SPRING_PID $FFMPEG_PID 2>/dev/null; exit 0; }
trap cleanup INT TERM

Xvfb "$DISP" -screen 0 "${RES}x24" -nolisten tcp \
    >> "$DATA_DIR/logs/xvfb.log" 2>&1 &
XVFB_PID=$!
sleep 2

# VirtualGL if present (GPU GL); llvmpipe otherwise
RUNNER=""
command -v vglrun >/dev/null && RUNNER="vglrun -d /dev/dri/renderD128"

( cd "$SPEC_DIR" && DISPLAY="$DISP" LD_LIBRARY_PATH="$SYSLIBS_DIR" \
    $RUNNER "$ENGINE_DIR/spring" --write-dir "$SPEC_DIR" "$SPEC_DIR/join.txt" ) \
    >> "$DATA_DIR/logs/streamer-spring.log" 2>&1 &
SPRING_PID=$!
echo "waiting for the spectator client to load..."
sleep 45

ENC=(-vaapi_device /dev/dri/renderD128 -vf "format=nv12,hwupload"
     -c:v h264_vaapi -b:v "$BITRATE" -maxrate "$BITRATE" -g $((FPS * 2)))
# fallback to x264 if vaapi is unavailable
ffmpeg -hide_banner -v error -init_hw_device vaapi=va:/dev/dri/renderD128 -f lavfi -i nullsrc=s=64x64 -frames:v 1 -f null - 2>/dev/null \
    || ENC=(-c:v libx264 -preset veryfast -b:v "$BITRATE" -g $((FPS * 2)))

if [ "$MODE" = "--test" ]; then
    OUT=("$SPEC_DIR/test.mp4"); EXTRA=(-t 30 -y)
    echo "test capture: 30s -> $SPEC_DIR/test.mp4"
else
    [ -n "${STREAM_KEY:-}" ] || { echo "STREAM_KEY not set"; cleanup; }
    OUT=(-f flv "$RTMP_URL/$STREAM_KEY"); EXTRA=()
    echo "streaming to $RTMP_URL/<key>"
fi

ffmpeg -hide_banner -loglevel warning \
    -f x11grab -framerate "$FPS" -video_size "$RES" -i "$DISP" \
    -f lavfi -i anullsrc=channel_layout=stereo:sample_rate=44100 \
    "${ENC[@]}" -c:a aac -b:a 128k -shortest "${EXTRA[@]}" "${OUT[@]}" \
    >> "$DATA_DIR/logs/ffmpeg.log" 2>&1 &
FFMPEG_PID=$!

echo "$(date -Is) streamer up: xvfb=$XVFB_PID spring=$SPRING_PID ffmpeg=$FFMPEG_PID"
wait $FFMPEG_PID
cleanup
