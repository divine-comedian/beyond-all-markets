#!/usr/bin/env bash
# Standalone NVENC stream of the running war (X display :99) -> RTMP/YouTube.
# Kept separate from war-cloud.sh so pm2 can restart the stream on a network blip
# without disturbing the match. STREAM_KEY comes from $BASE/stream.env (chmod 600,
# NEVER committed) or the environment — same rule as war.env states for STREAM_KEY.
set -uo pipefail

BASE="${BASE:-/root/bar-render}"
DISP="${DISPLAY_NUM:-:99}"
RES="${RES:-1920x1080}"
FPS="${FPS:-30}"
BITRATE="${BITRATE:-6M}"
RTMP_URL="${RTMP_URL:-rtmp://a.rtmp.youtube.com/live2}"

[ -f "$BASE/stream.env" ] && . "$BASE/stream.env"
[ -n "${STREAM_KEY:-}" ] || { echo "STREAM_KEY unset (put it in $BASE/stream.env)"; exit 1; }

# x11grab the rendered game + LIVE game audio (the pipewire "Dummy Output" monitor,
# which carries whatever Spring plays). h264_nvenc on the GPU; 2s keyframes for YouTube.
exec env PULSE_SERVER=unix:/run/user/1001/pulse/native XDG_RUNTIME_DIR=/run/user/1001 \
    ffmpeg -hide_banner -loglevel warning \
    -thread_queue_size 1024 -f x11grab -framerate "$FPS" -video_size "$RES" -i "$DISP" \
    -thread_queue_size 8192 -use_wallclock_as_timestamps 1 -f pulse -i auto_null.monitor \
    -c:v h264_nvenc -preset p5 -b:v "$BITRATE" -maxrate "$BITRATE" -bufsize "$BITRATE" \
        -g $((FPS * 2)) -pix_fmt yuv420p \
    -af "aresample=async=1000:min_hard_comp=0.100:first_pts=0,loudnorm=I=-16:TP=-1.5:LRA=11" \
    -c:a aac -b:a 160k -f flv "$RTMP_URL/$STREAM_KEY"
