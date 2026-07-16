#!/usr/bin/env bash
# Build a self-contained Windows spectator pack for the market war.
# Network play needs the EXACT engine version of the host (master CI build) and
# the MarketWar mutator archive — a stock BAR install has neither, so we ship
# both plus a join .bat. First run downloads game+map via pr-downloader (~2GB).
set -euo pipefail
source "$(dirname "$0")/../config/war.env"
HOST_IP="${1:?usage: make-spectator-pack.sh <host-ip> [out-dir]}"
OUT="${2:-$ROOT/dist}"

# The pack engine MUST match the host engine bit-for-bit or spectators desync on
# join. The host build is often NOT the newest CI run (engine-master/ is only
# refreshed by install.sh), so pin the run explicitly. Priority:
#   1. PACK_ENGINE_RUN_ID env / 3rd arg  -> use verbatim
#   2. else derive the host engine commit and find its "Build Engine v2" run
#   3. else fall back to newest (with a loud warning)
run_id="${PACK_ENGINE_RUN_ID:-${3:-}}"
if [ -z "$run_id" ]; then
    host_sha=$(LD_LIBRARY_PATH="$SYSLIBS_DIR" "$ENGINE_DIR/spring-headless" --version 2>/dev/null \
                 | grep -oE '\-g[0-9a-f]+' | head -1 | sed 's/^-g//')
    if [ -n "$host_sha" ]; then
        run_id=$(gh api "repos/beyond-all-reason/RecoilEngine/actions/runs?head_sha=$host_sha&per_page=20" \
                   --jq '[.workflow_runs[] | select(.name=="Build Engine v2" and .conclusion=="success")][0].id' 2>/dev/null)
        [ "$run_id" = "null" ] && run_id=""
    fi
    if [ -n "$run_id" ]; then
        echo "Pinned pack engine to host build $host_sha (Build Engine v2 run $run_id)."
    else
        run_id=$(gh run list -R beyond-all-reason/RecoilEngine -b master \
                   -w "Build Engine v2" -s success -L 1 --json databaseId --jq '.[0].databaseId')
        echo "WARNING: could not match host engine commit; using NEWEST CI run ($run_id)." \
             "If the host is not on this build, spectators WILL desync."
    fi
else
    echo "Pack engine pinned via PACK_ENGINE_RUN_ID/arg = $run_id."
fi

mkdir -p "$OUT"
tmp=$(mktemp -d)
gh run download "$run_id" -R beyond-all-reason/RecoilEngine \
   -n "engine-artifacts-amd64-windows-" -D "$tmp"

pack="$tmp/bar-market-war-spectator"
mkdir -p "$pack/engine" "$pack/data/games"
7zz x -y -o"$pack/engine" "$tmp"/recoil_*_amd64-windows.7z > /dev/null
cp -r "$ROOT/mutator/MarketWar.sdd" "$pack/data/games/MarketWar.sdd"

cat > "$pack/data/springsettings.cfg" <<EOF
RapidTagResolutionOrder = repos-cdn.beyondallreason.dev
LogFlushLevel = 0
MaxTextureAtlasSizeX = 16384
MaxTextureAtlasSizeY = 16384
EOF

cat > "$pack/spectate.bat" <<EOF
@echo off
cd /d "%~dp0"
set NAME=%1
if "%NAME%"=="" set NAME=Viewer%RANDOM%

set PRD_RAPID_REPO_MASTER=https://repos-cdn.beyondallreason.dev/repos.gz
set PRD_RAPID_USE_STREAMER=false

rem --- auto-sync the mutator from the host so versions can never drift ---
curl.exe -s -m 15 -o mw.zip http://$HOST_IP:$MUTATOR_HTTP_PORT/MarketWar.sdd.zip
if exist mw.zip (
  echo Updating Market War mod from host...
  powershell -NoProfile -Command "Remove-Item -Recurse -Force 'data\\games\\MarketWar.sdd' -ErrorAction SilentlyContinue; Expand-Archive -Force 'mw.zip' 'data\\games'"
  del mw.zip
) else (
  echo WARNING: could not fetch current mod from host - using local copy, may be stale
)

set BARDATA=
if exist "C:\\Program Files\\Beyond-All-Reason\\data\\pool" set "BARDATA=C:\\Program Files\\Beyond-All-Reason\\data"
if exist "%LOCALAPPDATA%\\Programs\\Beyond-All-Reason\\data\\pool" set "BARDATA=%LOCALAPPDATA%\\Programs\\Beyond-All-Reason\\data"

if defined BARDATA (
  echo Reusing existing BAR install at %BARDATA%
  set "SPRING_DATADIR=%BARDATA%"
  rem try delta-fetch into the existing pool; Program Files may deny writes
  engine\\pr-downloader.exe --filesystem-writepath "%BARDATA%" --download-game "$GAME_NAME" --download-map "$MAP_NAME"
  if errorlevel 1 (
    echo Existing install not writable - downloading into the pack instead...
    engine\\pr-downloader.exe --filesystem-writepath "%~dp0data" --download-game "$GAME_NAME" --download-map "$MAP_NAME"
  )
) else if not exist "data\\packages" (
  echo No BAR install found - downloading game data, about 2GB, one time...
  engine\\pr-downloader.exe --filesystem-writepath "%~dp0data" --download-game "$GAME_NAME" --download-map "$MAP_NAME"
)

(
  echo [GAME]
  echo {
  echo     HostIP=$HOST_IP;
  echo     HostPort=$HOST_PORT;
  echo     MyPlayerName=%NAME%;
  echo     IsHost=0;
  echo     Spectator=1;
  echo }
) > "data\\join.txt"

echo Joining the war at $HOST_IP:$HOST_PORT as %NAME% ...
engine\\spring.exe --write-dir "%~dp0data" "data\\join.txt"
EOF

(cd "$tmp" && zip -qr "$OUT/bar-market-war-spectator.zip" bar-market-war-spectator)
rm -rf "$tmp"
echo "Pack: $OUT/bar-market-war-spectator.zip (unzip anywhere, run spectate.bat [name])"
