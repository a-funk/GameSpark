#!/bin/bash
# Per-layer CPU profile of one benchmark run: which part of the stack the game's CPU time goes to.
#
# FEX labels translated code with the x86 library it came from when FEX_LIBRARYJITNAMING=1 is in the game's
# launch options (the Config.json key does not reach games inside Steam's container):
#   tools/steam-config.sh launch-options APPID "FEX_LIBRARYJITNAMING=1 <your other options> %command%"
# perf samples every core; analyze.py resolves translated addresses through FEX's perf maps.
#
# Usage: profile/profile.sh GAME LABEL [DELAY_AFTER_GAME_START_S] [SECONDS]
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); . "$ROOT/lib/env.sh"
GAME=${1:?game}; L=${2:?label}; DELAY=${3:-50}; SECS=${4:-45}
# shellcheck source=/dev/null
. "$ROOT/bench/games/$GAME.sh"
OUT=$SG_DATA/profiles/$(date +%Y%m%d-%H%M%S)-$GAME-$L; mkdir -p "$OUT"
DATA=/tmp/gamespark-$GAME-$L.perf

"$ROOT/bench/run.sh" "$GAME" "prof-$L" > "$OUT/bench.log" 2>&1 &
BENCH=$!
for _ in $(seq 300); do G=$(pgrep -f "$GAME_PROC" | head -1); [ -n "$G" ] && break; sleep 1; done
[ -z "${G:-}" ] && { wait $BENCH; cat "$OUT/bench.log"; die "game never started"; }
echo "game pid $G; sampling in ${DELAY}s for ${SECS}s"
sleep "$DELAY"
as_root perf record -a -F 499 -o "$DATA" -- sleep "$SECS" 2> "$OUT/perf-record.log"
wait $BENCH

# FEX writes perf-<pid>.map into the snap's private /tmp; collect them next to the profile.
as_root sh -c "cp $SNAP_TMP/perf-*.map /tmp/ 2>/dev/null; chmod 644 /tmp/perf-*.map 2>/dev/null"
cp /tmp/perf-[0-9]*.map "$OUT/" 2>/dev/null
echo "perf maps: $(ls "$OUT"/*.map 2>/dev/null | wc -l)"
[ "$(ls "$OUT"/*.map 2>/dev/null | wc -l)" = 0 ] && echo "warning: no perf maps; is FEX_LIBRARYJITNAMING=1 in the launch options?" >&2
as_root perf script -i "$DATA" -F comm,pid,tid,ip,sym,dso 2>/dev/null > "$OUT/perf-script.txt"
python3 -I "$ROOT/profile/analyze.py" "$OUT/perf-script.txt" "$OUT" > "$OUT/layers.json"
cp "$(tail -1 "$OUT/bench.log")/run.json" "$OUT/" 2>/dev/null
rm -f "$OUT/perf-script.txt" /tmp/perf-[0-9]*.map   # large; layers.json keeps the result
as_root sh -c "rm -f $SNAP_TMP/perf-*.map"          # FEX writes a new map per process every run
cat "$OUT/layers.json"; echo "$OUT"
