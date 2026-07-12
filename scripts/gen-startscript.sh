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
        $TWEAKDEFS_LINE
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
        [OPTIONS] { disabledunits=$AI_DISABLED_UNITS; }
    }
    [AI1]
    {
        Name=USD;
        ShortName=BARb;
        Host=0;
        Team=$BEARS_TEAM;
        [OPTIONS] { disabledunits=$AI_DISABLED_UNITS; }
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
