#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../config/war.env"

mkdir -p "$ENGINE_DIR" "$DATA_DIR"

# 1. Engine: Recoil MASTER CI build (linux64).
# Tagged releases (<= 2026.06.11) all carry issue #2923: headless icon-atlas
# rebuild loop that caps sim at ~4fps. The fix (PR #2924) is master-only, so we
# take the newest successful "Build Engine v2" CI artifact on master.
# Requires an authed `gh` (artifact downloads need a GitHub token; artifacts
# expire after ~90 days — pin a tagged release here once one ships the fix).
if [ ! -x "$ENGINE_DIR/spring-headless" ]; then
  run_id=$(gh run list -R beyond-all-reason/RecoilEngine -b master \
             -w "Build Engine v2" -s success -L 1 --json databaseId \
             --jq '.[0].databaseId')
  echo "Engine: RecoilEngine master CI run $run_id"
  tmp=$(mktemp -d)
  gh run download "$run_id" -R beyond-all-reason/RecoilEngine \
     -n "engine-artifacts-amd64-linux-" -D "$tmp"
  7zz x -y -o"$ENGINE_DIR" "$tmp"/recoil_*_amd64-linux.7z > /dev/null
  rm -rf "$tmp"
  chmod +x "$ENGINE_DIR"/spring* "$ENGINE_DIR"/pr-downloader 2>/dev/null || true
fi

# 1b. Graphical client needs libSDL2/libopenal; extract locally (no sudo).
if [ ! -e "$SYSLIBS_DIR/libSDL2-2.0.so.0" ]; then
  mkdir -p "$SYSLIBS_DIR"
  tmp=$(mktemp -d)
  (cd "$tmp" && apt-get download libsdl2-2.0-0 libopenal1 libsndio7.0 libdecor-0-0 \
    && for f in *.deb; do dpkg -x "$f" x/; done \
    && cp x/usr/lib/x86_64-linux-gnu/* "$SYSLIBS_DIR/")
  rm -rf "$tmp"
fi

# 2. BAR game archive via rapid (BAR hosts its own rapid repo master)
export PRD_RAPID_REPO_MASTER="https://repos-cdn.beyondallreason.dev/repos.gz"
export PRD_RAPID_USE_STREAMER=false
"$ENGINE_DIR/pr-downloader" --filesystem-writepath "$DATA_DIR" --download-game "$GAME_RAPID_TAG"

# 3. Map
"$ENGINE_DIR/pr-downloader" --filesystem-writepath "$DATA_DIR" --download-map "$MAP_NAME"

# 4. Resolve concrete game name from rapid index and persist it into war.env
game_name=$(find "$DATA_DIR/rapid" -name versions.gz -exec zcat {} + 2>/dev/null \
            | awk -F, -v tag="$GAME_RAPID_TAG" '$1==tag {print $4; exit}')
if [ -n "$game_name" ]; then
  sed -i "s|^GAME_NAME=.*|GAME_NAME=\"$game_name\"|" "$(dirname "$0")/../config/war.env"
fi

# 5. Engine settings (write-dir). LogFlushLevel=0: unbuffered infolog — buffered
# logs lose their tail on kill and make healthy runs look hung.
cat > "$DATA_DIR/springsettings.cfg" <<EOF
TCPAllowConnect = 127.0.0.1:$FEED_PORT
LogFlushLevel = 0
MaxTextureAtlasSizeX = 16384
MaxTextureAtlasSizeY = 16384
EOF

# 6. Mutator dev-archive link + pin its BAR dependency to the exact version.
# A floating tag (rapid://byar:test) resolves differently on each machine as
# BAR updates, breaking spectators whose index is newer than the host's game.
if [ -n "$game_name" ]; then
  sed -i "s|^        \".*\",$|        \"$game_name\",|" "$ROOT/mutator/MarketWar.sdd/modinfo.lua"
fi
mkdir -p "$DATA_DIR/games"
ln -sfn "$ROOT/mutator/MarketWar.sdd" "$DATA_DIR/games/MarketWar.sdd"

echo "Installed: ${game_name:-UNRESOLVED} on $MAP_NAME (engine: master CI)"
