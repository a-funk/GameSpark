#!/bin/bash
# Run one built-in game benchmark with 1 Hz GPU/CPU telemetry and save a run record.
# Usage: bench/run.sh GAME LABEL       GAME = an adapter in bench/games/ (e.g. cyberpunk2077)
# Env:   PIN_FAST=1  pin the game process to the fastest cores after launch
#        SHOT_AT=N   take a screenshot N seconds after launch (needs gnome-screenshot)
#        FRAMES=SECS log frame times with MangoHud for SECS seconds, starting FRAMES_DELAY (default 30) seconds after
#                    the game's first frame, or when the adapter calls frames_start (FRAMES_DELAY=key, lib/menu.sh);
#                    needs system/frametimes.sh install and the game's Steam launch options
#                    set to tools/launch.sh %command%. Adapters without their own benchmark use this; the run ends
#                    (game_stop, else the game is killed) when MangoHud finishes its log.
#        RUN_ENV_EXTRA="K=V ..."  more settings for this run's launch (through tools/launch.sh), e.g. the profiler's
#                    FEX_LIBRARYJITNAMING=1
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
RUN_ENV=$SG_DATA/launch/run.env
# Background helpers must not inherit the run lock (fd 8); the driver is stopped with the run.
trap 'rm -f "$RUN_ENV"; kill ${TEL:-} 2>/dev/null; [ -n "${DRIVE:-}" ] && { pkill -P "$DRIVE" 2>/dev/null; kill "$DRIVE" 2>/dev/null; }' EXIT
# BENCH_RUN tells game_prepare this run is measured (e.g. VSync off); bench/tune.py --apply leaves it unset.
# shellcheck disable=SC2034  # read by the sourced adapter
BENCH_RUN=1
declare -F game_prepare >/dev/null && game_prepare "$OUT"
cp "$FEX_CONFIG_DIR/Config.json" "$OUT/fex-Config.json" 2>/dev/null
printf '{"game": "%s", "api": "%s"}\n' "${GAME_NAME:-$GAME}" "${GAME_API:-}" > "$OUT/meta.json"
if [ -n "${FRAMES:-}" ]; then
  [ -f "$SG_DATA/vklayers/MangoHud.json" ] || die "frame capture is not installed (system/frametimes.sh install)"
  mkdir -p "$SG_DATA/launch" "$OUT/frames"
  start=autostart_log=${FRAMES_DELAY:-30}
  [ "${FRAMES_DELAY:-}" = key ] && start=toggle_logging=${FRAMES_KEY:?FRAMES_DELAY=key needs lib/menu.sh frames_start}
  printf 'MANGOHUD=1\nMANGOHUD_CONFIG=no_display,cpu_stats=0,gpu_stats=0,%s,log_duration=%s,output_folder=%s\nCONTAINER_VK_IMPLICIT_LAYER_PATH=%s:/usr/lib/pressure-vessel/overrides/share/vulkan/implicit_layer.d\n' \
    "$start" "$FRAMES" "$OUT/frames" "$SG_DATA/vklayers" > "$RUN_ENV"
fi
if [ -n "${RUN_ENV_EXTRA:-}" ]; then
  mkdir -p "$SG_DATA/launch"
  for kv in $RUN_ENV_EXTRA; do echo "$kv" >> "$RUN_ENV"; done
fi
python3 -I "$ROOT/bench/telemetry.py" "$OUT/telemetry.jsonl" 8>&- & TEL=$!
# Other GPU compute work (e.g. a local LLM server) competes with the game; record it at the start and the end.
# The game itself is listed too (VKD3D uses compute queues), so it is filtered out.
gpu_apps() { nvidia-smi --query-compute-apps=process_name --format=csv,noheader 2>/dev/null | grep -vE "$GAME_PROC" >> "$OUT/gpu-apps"; }
gpu_apps
date +%s > "$OUT/start"
[ -n "${SHOT_AT:-}" ] && (sleep "$SHOT_AT"; "$ROOT/tools/shot.sh" "$OUT/mid.png" >/dev/null) 8>&- &

# Steam can hold a launch for a dialog only someone at the TV sees ("LaunchApp waiting for user response to X").
# Informational notices (ShowInterstitials, e.g. "Controller using Steam Input") get OK; agreements never do.
steam_notice_ok() {
  local png=$OUT/steam-notice.png text xy
  "$ROOT/tools/shot.sh" "$png" >/dev/null || return 1
  text=$("$ROOT/tools/ocr.sh" "$png")
  echo "$text" | grep -qiE "agree|EULA|terms|licen[cs]e" && die "Steam shows an agreement before launching $GAME; accept it once at the TV"
  xy=$("$ROOT/tools/ocr.sh" "$png" --find '^OK$') || return 1
  echo "Steam notice before launch: $(echo "$text" | grep -m1 -iE '[a-z]{4}' | cut -c1-80) -> OK"
  # shellcheck disable=SC2086  # "x y"
  python3 -I "$ROOT/tools/xinput.py" click $xy >/dev/null
}
# "Unable to Sync" (a failed Steam Cloud sync) offers "Play anyway", which can cost the player's saved progress:
# always Cancel, which leaves the saves alone and makes Steam sync again; this run fails, the next launch is normal.
steam_sync_cancel() {
  local png=$OUT/steam-sync.png xy
  if "$ROOT/tools/shot.sh" "$png" >/dev/null && "$ROOT/tools/ocr.sh" "$png" | grep -q "Unable to Sync" \
     && xy=$("$ROOT/tools/ocr.sh" "$png" --find 'Cancel'); then
    # shellcheck disable=SC2086  # "x y"
    python3 -I "$ROOT/tools/xinput.py" click $xy >/dev/null
  fi
  die "Steam could not sync $GAME's saves with Steam Cloud; cancelled the launch (saves untouched)"
}
steam_prompt() {  # what Steam waits on for this app (step and argument), if its latest launch line (after $1) is a wait
  tail -n +"$(( $1 + 1 ))" "$STEAM_LOG" | grep -E "AppID $APPID, " | tail -1 \
    | grep -oE 'waiting for user response to [A-Za-z]+ "[^"]*"' | cut -d' ' -f6-
}

# Launchers can stall before starting the game (RDR2's Rockstar launcher at sign-in): adapters set LAUNCH_RETRIES,
# LAUNCH_WAIT and a game_abort that clears the stuck launch.
for attempt in $(seq "${LAUNCH_RETRIES:-1}"); do
  seen=$(wc -l < "$STEAM_LOG")
  steam_launch "$APPID" "$LAUNCH_ARGS" || die "Steam did not accept the launch"
  for i in $(seq "${LAUNCH_WAIT:-300}"); do
    G=$(pgrep -f "$GAME_PROC" | head -1); [ -n "$G" ] && break
    # Steam also logs brief waits for its own steps (CreatingProcess, ProcessingShaderCache), which continue by
    # themselves; only these three are dialogs.
    case $(steam_prompt "$seen") in
      ShowInterstitials*) steam_notice_ok && seen=$(wc -l < "$STEAM_LOG") ;;
      ShowEula*) die "Steam wants $GAME's EULA accepted before it launches; accept it once at the TV" ;;
      *'"syncfailed"') steam_sync_cancel ;;
    esac
    sleep 1
  done
  [ -n "${G:-}" ] && break
  declare -F game_abort >/dev/null && { echo "game did not start (attempt $attempt)"; game_abort; }
done
[ -z "${G:-}" ] && die "game never started"
echo "game pid $G after ${i}s"
# The governor (system/governor.sh) may switch schedulers once the game appears; record what the run used.
(sleep 10; echo "$(cat /sys/kernel/sched_ext/state 2>/dev/null) $(cat /sys/kernel/sched_ext/root/ops 2>/dev/null)" > "$OUT/sched") 8>&- &
if [ "${PIN_FAST:-0}" = 1 ]; then
  for p in $(pgrep -f "$GAME_PROC"); do taskset -a -cp "$(fast_cpus)" "$p" >/dev/null; done; echo "pinned to $(fast_cpus)"
fi
# Games whose benchmark has no command-line switch: the adapter drives the menus and closes the game when done.
declare -F game_drive >/dev/null && { game_drive "$OUT" "$G" > "$OUT/drive.log" 2>&1 8>&- & DRIVE=$!; }
for i in $(seq 1800); do
  pgrep -f "$GAME_PROC" >/dev/null || break
  if [ -n "${FRAMES:-}" ] && compgen -G "$OUT/frames/*_summary.csv" >/dev/null; then   # MangoHud's log is complete
    sleep 2; date +%s > "$OUT/bench_end"
    if declare -F game_stop >/dev/null; then game_stop "$G"; else kill "$G"; fi
    for _ in $(seq 60); do pgrep -f "$GAME_PROC" >/dev/null || break; sleep 1; done
    break
  fi
  sleep 1
done
date +%s > "$OUT/end"; sleep 3

if declare -F game_collect >/dev/null; then
  game_collect "$OUT" || die "no benchmark result found (game crashed or the benchmark did not finish)"
elif [ -n "${FRAMES:-}" ]; then
  compgen -G "$OUT/frames/*_summary.csv" >/dev/null || die "no frame log (did the game use tools/launch.sh?)"
fi
gpu_apps
[ -s "$OUT/gpu-apps" ] && echo "warning: other GPU work during the run: $(sort -u "$OUT/gpu-apps" | xargs -n1 basename | xargs)" >&2
python3 -I "$ROOT/bench/ingest.py" "$OUT" "$GAME" "$LABEL" > "$OUT/run.json" || die "ingest failed"
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print({k: d[k] for k in ("avg_fps","low1_fps","rendered_fps","gpu_util","cpu_x925","cpu_a725")})' "$OUT/run.json"
echo "$OUT"
