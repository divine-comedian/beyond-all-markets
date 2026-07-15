#!/usr/bin/env bash
# Option B: the WHOLE Market War on one cloud GPU box — host + render + stream,
# all localhost, zero NAT. feedd (public keyless feeds) + a full rendering `spring`
# running as the authoritative host + NVENC → RTMP. This replaces the split
# home-host / cloud-spectator design once double-NAT proved unsolvable.
#
# Usage on the cloud box:
#   STREAM=off  FEED_MODE=live ./war-cloud.sh     # host+render only (measure sim)
#   STREAM=null FEED_MODE=live ./war-cloud.sh     # + NVENC to /dev/null (measure full load)
#   STREAM=youtube STREAM_KEY=xxx ./war-cloud.sh  # live to YouTube
set -uo pipefail

BASE="${BASE:-/root/bar-render}"
ENGINE="$BASE/engine/spring"
DATA="$BASE/data"
LOGS="$BASE/logs"; mkdir -p "$LOGS"
VENV_PY="${VENV_PY:-/venv/main/bin/python3}"

FEED_PORT="${FEED_PORT:-8642}"
FEED_MODE="${FEED_MODE:-live}"          # live | synthetic
DISP="${DISPLAY_NUM:-:99}"
RES="${RES:-1920x1080}"
FPS="${FPS:-30}"
BITRATE="${BITRATE:-6M}"
RTMP_URL="${RTMP_URL:-rtmp://a.rtmp.youtube.com/live2}"
STREAM="${STREAM:-off}"                 # off | null | youtube
LOAD_WAIT="${LOAD_WAIT:-40}"

# springsettings: the feed-bridge permission is mandatory (market_feed LuaUI widget
# connects to feedd); the rest is a capture-friendly window on a real GPU.
cat > "$DATA/springsettings.cfg" <<EOF
XResolution = ${RES%x*}
YResolution = ${RES#*x}
Fullscreen = 0
WindowPosX = 0
WindowPosY = 0
WindowBorderless = 1
TCPAllowConnect = 127.0.0.1:$FEED_PORT
Shadows = 1
ShadowMapSize = 1024
Water = 1
VSync = 0
LogFlushLevel = 3
CamMode = 3
music = 0
EOF

FEED_PID=""; SPRING_PID=""; FFMPEG_PID=""
# Runs on EVERY exit path (normal, signal, or `set -e/-u` error) so a crash can never
# leak an orphaned spring/feedd — orphans piling up is what OOM-killed the box once.
cleanup() { kill $FEED_PID $SPRING_PID $FFMPEG_PID 2>/dev/null; }
trap cleanup EXIT
trap 'exit 0' INT TERM

# The X display :99 is owned by a SEPARATE process (display-cloud.sh / pm2 "display")
# so restarting the war never orphans the stream's capture. Wait for it to exist.
for _ in $(seq 1 30); do
    [ -S "/tmp/.X11-unix/X${DISP#:}" ] && break
    sleep 1
done

# 1) market feed (public exchange websockets; no creds)
feed_args="--port $FEED_PORT"; [ "$FEED_MODE" = synthetic ] && feed_args="$feed_args --synthetic"
"$VENV_PY" "$BASE/feed/feedd.py" $feed_args >> "$LOGS/feedd.log" 2>&1 &
FEED_PID=$!
sleep 2

# 2) authoritative host + renderer. Audio goes to the pipewire-pulse "Dummy Output"
# sink; the streamer captures that sink's monitor. (Was SDL_AUDIODRIVER=dummy = silent.)
( cd "$DATA" && DISPLAY="$DISP" VGL_DISPLAY=egl \
    SDL_AUDIODRIVER=pulse PULSE_SERVER=unix:/run/user/1001/pulse/native XDG_RUNTIME_DIR=/run/user/1001 \
    vglrun "$ENGINE" --write-dir "$DATA" "$DATA/script.txt" ) \
    >> "$LOGS/spring.log" 2>&1 &
SPRING_PID=$!
echo "war host + render loading (feed=$FEED_MODE, stream=$STREAM)..."
sleep "$LOAD_WAIT"

# 4) encode (optional)
case "$STREAM" in
  off) echo "sim-only: no encode" ;;
  null|youtube)
    if [ "$STREAM" = youtube ]; then
        [ -n "${STREAM_KEY:-}" ] || { echo "STREAM_KEY unset"; cleanup; }
        OUT=(-f flv "$RTMP_URL/$STREAM_KEY")
    else
        OUT=(-f null -)
    fi
    ffmpeg -hide_banner -loglevel warning \
        -f x11grab -framerate "$FPS" -video_size "$RES" -i "$DISP" \
        -f lavfi -i anullsrc=channel_layout=stereo:sample_rate=44100 \
        -c:v h264_nvenc -preset p5 -b:v "$BITRATE" -maxrate "$BITRATE" \
            -bufsize "$BITRATE" -g $((FPS * 2)) \
        -c:a aac -b:a 128k "${OUT[@]}" >> "$LOGS/ffmpeg.log" 2>&1 &
    FFMPEG_PID=$! ;;
esac

echo "$(date -Is) war-cloud up: feed=$FEED_PID spring=$SPRING_PID ffmpeg=${FFMPEG_PID:-none}"
wait $SPRING_PID
cleanup
