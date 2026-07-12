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
    MyPlayerName=Warhost;
    NumPlayers=1;
    NumTeams=2;
    NumAllyTeams=2;
    [MODOPTIONS]
    {
        deathmode=neverend;
    }
    [PLAYER0]
    {
        Name=Warhost;
        Spectator=1;
    }
    [AI0]
    {
        Name=Bulls;
        ShortName=BARb;
        Host=0;
        Team=$BULLS_TEAM;
    }
    [AI1]
    {
        Name=Bears;
        ShortName=BARb;
        Host=0;
        Team=$BEARS_TEAM;
    }
    [TEAM0]
    {
        TeamLeader=0;
        AllyTeam=0;
        Side=Armada;
    }
    [TEAM1]
    {
        TeamLeader=0;
        AllyTeam=1;
        Side=Cortex;
    }
    [ALLYTEAM0] { NumAllies=0; }
    [ALLYTEAM1] { NumAllies=0; }
}
EOF
echo "Wrote $DATA_DIR/script.txt (GameType=$GAMETYPE)"
