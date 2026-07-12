#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../config/war.env"

mkdir -p "$ENGINE_DIR" "$DATA_DIR"

# 1. Latest Recoil engine release for linux64 (.7z asset)
if [ ! -x "$ENGINE_DIR/spring-headless" ]; then
  url=$(curl -s https://api.github.com/repos/beyond-all-reason/RecoilEngine/releases/latest \
        | grep -o 'https://[^"]*amd64-linux\.7z' | head -1)
  echo "Engine: $url"
  curl -sL "$url" -o "$ENGINE_DIR/engine.7z"
  7zz x -y -o"$ENGINE_DIR" "$ENGINE_DIR/engine.7z" > /dev/null
  rm "$ENGINE_DIR/engine.7z"
  # some releases nest a dir; flatten if spring-headless isn't at top level
  if [ ! -x "$ENGINE_DIR/spring-headless" ]; then
    inner=$(find "$ENGINE_DIR" -maxdepth 3 -name spring-headless | head -1)
    if [ -n "$inner" ]; then mv "$(dirname "$inner")"/* "$ENGINE_DIR/"; fi
  fi
  chmod +x "$ENGINE_DIR"/spring* "$ENGINE_DIR"/pr-downloader 2>/dev/null || true
fi

# 2. BAR game archive via rapid (BAR hosts its own rapid repo master)
export PRD_RAPID_REPO_MASTER="https://repos-cdn.beyondallreason.dev/repos.gz"
export PRD_RAPID_USE_STREAMER=false
"$ENGINE_DIR/pr-downloader" --filesystem-writepath "$DATA_DIR" --download-game "$GAME_RAPID_TAG"

# 3. Map
"$ENGINE_DIR/pr-downloader" --filesystem-writepath "$DATA_DIR" --download-map "$MAP_NAME"

# 4. Resolve concrete game name from rapid index and persist it into war.env
game_name=$(zcat "$DATA_DIR"/rapid/*/versions.gz 2>/dev/null \
            | awk -F, -v tag="$GAME_RAPID_TAG" '$1==tag {print $4; exit}')
if [ -n "$game_name" ]; then
  sed -i "s|^GAME_NAME=.*|GAME_NAME=\"$game_name\"|" "$(dirname "$0")/../config/war.env"
fi
echo "Installed: ${game_name:-UNRESOLVED} on $MAP_NAME"
