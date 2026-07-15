#!/usr/bin/env bash
# Run the endless market war, supervised: feedd + engine host, each restarted
# on death. Usage: run-war.sh [live|synthetic] [spring-headless|spring]
set -uo pipefail
source "$(dirname "$0")/../config/war.env"
export BAM_MINT PUMP_WS_URL
MODE="${1:-live}"
BIN="${2:-spring-headless}"
mkdir -p "$DATA_DIR/logs"

feed_args=""
[ "$MODE" = "synthetic" ] && feed_args="--synthetic"
[ "$MODE" = "live" ] && [ -z "${BAM_MINT:-}" ] && feed_args="$feed_args --bam-proxy"

start_feed() {
    python3 "$ROOT/feed/feedd.py" --port "$FEED_PORT" $feed_args \
        >> "$DATA_DIR/logs/feedd.log" 2>&1 &
    FEED_PID=$!
}

start_engine() {
    # Spring truncates infolog.txt on boot, so a restart silently destroys the
    # previous match's telemetry (lost a 2h47m run this way). Archive it first.
    if [ -s "$DATA_DIR/infolog.txt" ]; then
        last=$(grep -oE '\[f=[0-9]+\]' "$DATA_DIR/infolog.txt" | tail -1 | tr -dc '0-9')
        mv "$DATA_DIR/infolog.txt" \
           "$DATA_DIR/logs/infolog-$(date +%Y%m%d-%H%M%S)-f${last:-0}.txt"
    fi
    bash "$ROOT/scripts/gen-startscript.sh" 'Market War $VERSION' > /dev/null
    # publish the current mutator for spectator auto-sync
    mkdir -p "$DATA_DIR/www"
    ( cd "$ROOT/mutator" && rm -f "$DATA_DIR/www/MarketWar.sdd.zip" \
      && zip -qr "$DATA_DIR/www/MarketWar.sdd.zip" MarketWar.sdd )
    ( cd "$DATA_DIR" && LD_LIBRARY_PATH="$SYSLIBS_DIR" \
        "$ENGINE_DIR/$BIN" --write-dir "$DATA_DIR" script.txt ) \
        >> "$DATA_DIR/logs/engine.log" 2>&1 &
    ENGINE_PID=$!
}

start_www() {
    ( cd "$DATA_DIR/www" && python3 -m http.server "$MUTATOR_HTTP_PORT" --bind 0.0.0.0 ) \
        >> "$DATA_DIR/logs/www.log" 2>&1 &
    WWW_PID=$!
}

stop_all() {
    kill "$FEED_PID" "$ENGINE_PID" "$WWW_PID" 2>/dev/null
    exit 0
}
trap stop_all INT TERM

start_feed
start_engine
start_www
echo "$(date -Is) war running: feedd=$FEED_PID engine=$ENGINE_PID www=$WWW_PID (mode=$MODE bin=$BIN)"

while true; do
    sleep 10
    if ! kill -0 "$FEED_PID" 2>/dev/null; then
        echo "$(date -Is) feedd died, restarting"
        start_feed
    fi
    if ! kill -0 "$ENGINE_PID" 2>/dev/null; then
        echo "$(date -Is) engine died, restarting match"
        start_engine
    fi
    if ! kill -0 "$WWW_PID" 2>/dev/null; then
        echo "$(date -Is) mutator http server died, restarting"
        start_www
    fi
done
