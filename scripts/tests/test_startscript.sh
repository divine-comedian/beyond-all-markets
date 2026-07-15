#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
# gen-startscript.sh writes the TDF to data/script.txt (its stdout is just a
# one-line confirmation), so read the generated file, not the command's stdout.
bash scripts/gen-startscript.sh >/dev/null 2>&1 || true
out=$(cat data/script.txt)
grep -q 'Name=SOL;' <<<"$out"      || { echo "FAIL: no SOL AI"; exit 1; }
grep -q 'Name=BAM;' <<<"$out"      || { echo "FAIL: no BAM AI"; exit 1; }
grep -q 'Name=USD-BAM;' <<<"$out"  || { echo "FAIL: no USD-BAM AI"; exit 1; }
# teams 6/7 must use the BAM roster (naval+hover banned, bots/veh/air allowed)
grep -E 'AI6.*disabledunits=.*armsy' <<<"$out" || { echo "FAIL: AI6 not on BAM roster"; exit 1; }
grep -Eq 'AI6.*armlab' <<<"$out" && { echo "FAIL: AI6 bans bot lab (should allow)"; exit 1; }
echo PASS
