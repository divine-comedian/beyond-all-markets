#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../config/war.env"
HOST="${1:-127.0.0.1}"
NAME="${2:-Viewer$RANDOM}"
BIN="${3:-spring-headless}"   # pass "spring" for the graphical client
SPEC_DIR="$DATA_DIR/spec"; mkdir -p "$SPEC_DIR"

# joining client needs the same game+map archives: share the host pool
for d in pool packages maps games rapid; do
    [ -e "$DATA_DIR/$d" ] && ln -sfn "$DATA_DIR/$d" "$SPEC_DIR/$d"
done

cat > "$SPEC_DIR/join.txt" <<EOF
[GAME]
{
    HostIP=$HOST;
    HostPort=$HOST_PORT;
    MyPlayerName=$NAME;
    IsHost=0;
    Spectator=1;
}
EOF
exec "$ENGINE_DIR/$BIN" --write-dir "$SPEC_DIR" "$SPEC_DIR/join.txt"
