#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../config/war.env"
MUTATOR="${1:-}"   # pass "Market War $VERSION" later to play the mutator; empty = plain BAR
GAMETYPE="${MUTATOR:-$GAME_NAME}"

cat > "$DATA_DIR/script.txt" <<EOF
[GAME]
{
    GameType=$GAMETYPE;
    MapName=$MAP_NAME;
    IsHost=1;
    HostIP=0.0.0.0;
    HostPort=$HOST_PORT;
    AutohostIP=127.0.0.1;
    AutohostPort=8453;
    MyPlayerName=Warhost;
    NumPlayers=1;
    NumTeams=2;
    NumAllyTeams=2;
    [MODOPTIONS]
    {
        deathmode=neverend;
        MinSpeed=1;
        MaxSpeed=1;
    }
    [PLAYER0]
    {
        Name=Warhost;
        Spectator=1;
    }
    [AI0]
    {
        Name=BTC;
        ShortName=BARb;
        Host=0;
        Team=$BULLS_TEAM;
    }
    [AI1]
    {
        Name=USD;
        ShortName=BARb;
        Host=0;
        Team=$BEARS_TEAM;
    }
    [TEAM0]
    {
        TeamLeader=0;
        AllyTeam=0;
        Side=Armada;
        RgbColor=0.97 0.58 0.10;
    }
    [TEAM1]
    {
        TeamLeader=0;
        AllyTeam=1;
        Side=Cortex;
        RgbColor=0.30 0.69 0.31;
    }
    [ALLYTEAM0] { NumAllies=0; }
    [ALLYTEAM1] { NumAllies=0; }
}
EOF
echo "Wrote $DATA_DIR/script.txt (GameType=$GAMETYPE)"
