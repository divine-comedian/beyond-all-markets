#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../config/war.env"
MUTATOR="${1:-}"   # pass "Market War $VERSION" later to play the mutator; empty = plain BAR
GAMETYPE="${MUTATOR:-$GAME_NAME}"

# low-eco experiment: eco structures buildable at 10% output; market income is
# primary. BAR executes the base64 `tweakdefs` modoption after unitdefs_post.
# BAR's lua decoder is base64url-only (- and _; NO + or /) and silently DROPS
# bytes on standard-alphabet chars — hence the tr. Verified against the
# decoder in the game archive (base64bytes table has no '+' / '/' entries).
TWEAKDEFS_LINE=""
if [[ "${LOW_ECO:-0}" == "1" ]]; then
    TWEAKDEFS_LINE="tweakdefs=$(base64 -w0 < "$ROOT/config/tweakdefs-low-eco.lua" | tr '+/' '-_');"
fi

# Three market lanes on Supreme Isthmus (12288x12288, land NE<->SW, water NW+SE).
# Spawns are the map's own team-game positions (guaranteed land). Assets NE,
# USD SW; two alliance blocks. Mid pair (BTC) is land-locked: no ship or hover
# labs. Flank pairs' battle lines cross the ponds — they build whatever they want.
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
    NumTeams=8;
    NumAllyTeams=2;
    StartPosType=3;
    [MODOPTIONS]
    {
        deathmode=neverend;
        MinSpeed=1;
        MaxSpeed=1;
        $TWEAKDEFS_LINE
    }
    [PLAYER0]
    {
        Name=Warhost;
        Spectator=1;
    }
    [AI0] { Name=BTC;       ShortName=BARb; Host=0; Team=0; [OPTIONS] { disabledunits=$AI_DISABLED_UNITS_MID; } }
    [AI1] { Name=USD-BTC;   ShortName=BARb; Host=0; Team=1; [OPTIONS] { disabledunits=$AI_DISABLED_UNITS_MID; } }
    [AI2] { Name=SP500;     ShortName=BARb; Host=0; Team=2; [OPTIONS] { disabledunits=$AI_DISABLED_UNITS_FLANK; } }
    [AI3] { Name=USD-SP500; ShortName=BARb; Host=0; Team=3; [OPTIONS] { disabledunits=$AI_DISABLED_UNITS_FLANK; } }
    [AI4] { Name=GOLD;      ShortName=BARb; Host=0; Team=4; [OPTIONS] { disabledunits=$AI_DISABLED_UNITS_FLANK; } }
    [AI5] { Name=USD-GOLD;  ShortName=BARb; Host=0; Team=5; [OPTIONS] { disabledunits=$AI_DISABLED_UNITS_FLANK; } }
    [AI6] { Name=ETH;       ShortName=BARb; Host=0; Team=6; [OPTIONS] { disabledunits=$AI_DISABLED_UNITS_AIR; } }
    [AI7] { Name=USD-ETH;   ShortName=BARb; Host=0; Team=7; [OPTIONS] { disabledunits=$AI_DISABLED_UNITS_AIR; } }
    [TEAM0] { TeamLeader=0; AllyTeam=0; Side=Armada; StartPosX=7600;  StartPosZ=4900;  RgbColor=0.97 0.58 0.10; }
    [TEAM1] { TeamLeader=0; AllyTeam=1; Side=Cortex; StartPosX=4600;  StartPosZ=7400;  RgbColor=0.30 0.69 0.31; }
    [TEAM2] { TeamLeader=0; AllyTeam=0; Side=Armada; StartPosX=7400;  StartPosZ=1200;  RgbColor=0.25 0.55 0.95; }
    [TEAM3] { TeamLeader=0; AllyTeam=1; Side=Cortex; StartPosX=1150;  StartPosZ=5400;  RgbColor=0.15 0.85 0.60; }
    [TEAM4] { TeamLeader=0; AllyTeam=0; Side=Armada; StartPosX=10530; StartPosZ=5606;  RgbColor=0.95 0.80 0.15; }
    [TEAM5] { TeamLeader=0; AllyTeam=1; Side=Cortex; StartPosX=4800;  StartPosZ=11100; RgbColor=0.60 0.85 0.25; }
    [TEAM6] { TeamLeader=0; AllyTeam=0; Side=Armada; StartPosX=10150; StartPosZ=600;   RgbColor=0.62 0.40 0.95; }
    [TEAM7] { TeamLeader=0; AllyTeam=1; Side=Cortex; StartPosX=2200;  StartPosZ=11750; RgbColor=0.20 0.60 0.35; }
    [ALLYTEAM0] { NumAllies=0; }
    [ALLYTEAM1] { NumAllies=0; }
}
EOF
echo "Wrote $DATA_DIR/script.txt (GameType=$GAMETYPE, 3 lanes / 6 teams)"
