#!/bin/bash
# Run one built-in game benchmark with 1 Hz GPU/CPU telemetry and save a run record.
# Usage: bench/run.sh GAME LABEL       GAME = an adapter in bench/games/ (e.g. cyberpunk2077)
# Env:   PIN_FAST=1  pin the game process to the fastest cores after launch
#        SHOT_AT=N   take a screenshot N seconds after launch (needs gnome-screenshot)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/lib/env.sh"
GAME=${1:?usage: run.sh GAME LABEL}; LABEL=${2:?usage: run.sh GAME LABEL}
[ -f "$ROOT/bench/games/$GAME.sh" ] || die "no adapter bench/games/$GAME.sh"
# shellcheck source=/dev/null
. "$ROOT/bench/games/$GAME.sh"

exec 8>"${TMPDIR:-/tmp}/gamespark-bench.lock"; flock -n 8 || die "another benchmark run is active"
pgrep -f "$GAME_PROC" >/dev/null && die "$GAME is already running"
steam_running || die "Steam is not running (tools/steam-console.sh starts it)"
hold_quiet_locks

OUT=$SG_DATA/runs/$(date +%Y%m%d-%H%M%S)-$GAME-$LABEL; mkdir -p "$OUT"
game_prepare "$OUT"
cp "$FEX_CONFIG_DIR/Config.json" "$OUT/fex-Config.json" 2>/dev/null
python3 -I "$ROOT/bench/telemetry.py" "$OUT/telemetry.jsonl" 8>&- & TEL=$!
# Background helpers must not inherit the run lock (fd 8); the driver is stopped with the run.
trap 'kill $TEL 2>/dev/null; [ -n "${DRIVE:-}" ] && { pkill -P "$DRIVE" 2>/dev/null; kill "$DRIVE" 2>/dev/null; }' EXIT
date +%s > "$OUT/start"
[ -n "${SHOT_AT:-}" ] && (sleep "$SHOT_AT"; "$ROOT/tools/shot.sh" "$OUT/mid.png" >/dev/null) 8>&- &

steam_launch "$APPID" "$LAUNCH_ARGS" || die "Steam did not accept the launch"
for i in $(seq 300); do G=$(pgrep -f "$GAME_PROC" | head -1); [ -n "$G" ] && break; sleep 1; done
[ -z "${G:-}" ] && die "game never started"
echo "game pid $G after ${i}s"
# The governor (system/governor.sh) may switch schedulers once the game appears; record what the run used.
(sleep 10; echo "$(cat /sys/kernel/sched_ext/state 2>/dev/null) $(cat /sys/kernel/sched_ext/root/ops 2>/dev/null)" > "$OUT/sched") 8>&- &
if [ "${PIN_FAST:-0}" = 1 ]; then
  for p in $(pgrep -f "$GAME_PROC"); do taskset -a -cp "$(fast_cpus)" "$p" >/dev/null; done; echo "pinned to $(fast_cpus)"
fi
# Games whose benchmark has no command-line switch: the adapter drives the menus and closes the game when done.
declare -F game_drive >/dev/null && { game_drive "$OUT" "$G" > "$OUT/drive.log" 2>&1 8>&- & DRIVE=$!; }
for i in $(seq 1800); do pgrep -f "$GAME_PROC" >/dev/null || break; sleep 1; done
date +%s > "$OUT/end"; sleep 3

game_collect "$OUT" || die "no benchmark result found (game crashed or the benchmark did not finish)"
python3 -I "$ROOT/bench/ingest.py" "$OUT" "$GAME" "$LABEL" > "$OUT/run.json" || die "ingest failed"
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print({k: d[k] for k in ("avg_fps","low1_fps","rendered_fps","gpu_util","cpu_x925","cpu_a725")})' "$OUT/run.json"
echo "$OUT"
