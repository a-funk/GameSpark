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
#        ENGINE_INI="r.A=1 r.B=0"  Unreal Engine.ini lines for this run, over the game's profiles/launch/<appid>.Engine.ini
#                    (tools/launch.sh merges them key by key)
#        WINE_FPS=1  also log Wine's present rate (its fps debug channel: one average about every 1.5 s, no frame times)
#                    into the run dir: the record's fallback where MangoHud cannot load, e.g. 32-bit games
#        GAME_RES=WxH  output resolution adapters write into the game's settings (default: the display's current mode,
#                    lib/env.sh game_res); the display mode itself is recorded with the run (display) for bench/ingest.py
#        TARGET_AVG, TARGET_LOW1, TARGET_HITCHES  pass criterion in the record (bench/ingest.py; default 58 fps average,
#                    48 fps 1% low, at most 2 frames over 50 ms per minute)
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
# With the TV off (HDMI disconnected) a game cannot show a frame: the run would time out in its menus minutes later.
display_mode >/dev/null || die "no display: xrandr shows no connected output with a mode (is the TV on?)"
hold_quiet_locks

RUN_ENV=$SG_DATA/launch/run.env RUN_INI=$SG_DATA/launch/run.Engine.ini
# tools/launch.sh applies these to every game launched while they exist: one left behind by a killed run or by another
# tool would silently change this run (and is not this run's to delete).
for f in "$RUN_ENV" "$RUN_INI"; do
  [ -e "$f" ] && die "$f exists (left by an earlier run or another tool) and would apply to this run: check it, remove it"
done
OUT=$SG_DATA/runs/$(date +%Y%m%d-%H%M%S)-$GAME-$LABEL; mkdir -p "$OUT"
# Background helpers must not inherit the run lock (fd 8); the driver is stopped with the run. game_cleanup (adapter)
# undoes game_prepare's changes even when the run dies early.
trap 'rm -f "$RUN_ENV" "$RUN_INI"; declare -F game_cleanup >/dev/null && game_cleanup; kill ${TEL:-} 2>/dev/null; [ -n "${DRIVE:-}" ] && { pkill -P "$DRIVE" 2>/dev/null; kill "$DRIVE" 2>/dev/null; }; [ -n "${KIOSK:-}" ] && python3 -I "$ROOT/tools/xinput.py" activate "$KIOSK" >/dev/null 2>&1' EXIT
trap 'exit 143' INT TERM   # (bash skips the EXIT trap when a signal ends it)
# BENCH_RUN tells game_prepare this run is measured (e.g. VSync off); bench/tune.py --apply leaves it unset.
# shellcheck disable=SC2034  # read by the sourced adapter
BENCH_RUN=1
declare -F game_prepare >/dev/null && game_prepare "$OUT"
cp "$FEX_CONFIG_DIR/Config.json" "$OUT/fex-Config.json" 2>/dev/null
printf '{"game": "%s", "api": "%s"}\n' "${GAME_NAME:-$GAME}" "${GAME_API:-}" > "$OUT/meta.json"
# The mode the TV runs ("3840x2160 59.94"): ingest labels the run with it and counts frames slower than one refresh.
display_mode > "$OUT/display" || { rm -f "$OUT/display"; echo "warning: could not read the display mode (DISPLAY?)" >&2; }
if [ -n "${FRAMES:-}" ]; then
  # The layer must match the game's Vulkan loader: 64-bit games reach the native arm64 loader through FEX's Vulkan thunk
  # ($SG_DATA/vklayers, system/frametimes.sh install); 32-bit (PE32) games run an i386 loader under FEX, which needs an
  # i386 MangoHud in $SG_DATA/vklayers32. GAME_EXE (path under steamapps/common, set by the adapter) tells them apart;
  # FRAMES_LAYERS=DIR overrides.
  layers=${FRAMES_LAYERS:-$SG_DATA/vklayers}
  if [ -z "${FRAMES_LAYERS:-}" ] && [ -n "${GAME_EXE:-}" ] && [ "$(pe_bits "$STEAM_ROOT/steamapps/common/$GAME_EXE")" = 32 ]; then
    layers=$SG_DATA/vklayers32
  fi
  [ -f "$layers/MangoHud.json" ] || die "frame capture is not installed in $layers (64-bit games: system/frametimes.sh install; 32-bit games need an i386 MangoHud there)"
  mkdir -p "$SG_DATA/launch" "$OUT/frames"
  start=autostart_log=${FRAMES_DELAY:-30}
  [ "${FRAMES_DELAY:-}" = key ] && start=toggle_logging=${FRAMES_KEY:?FRAMES_DELAY=key needs lib/menu.sh frames_start}
  printf 'MANGOHUD=1\nMANGOHUD_CONFIG=no_display,cpu_stats=0,gpu_stats=0,%s,log_duration=%s,output_folder=%s\nCONTAINER_VK_IMPLICIT_LAYER_PATH=%s:/usr/lib/pressure-vessel/overrides/share/vulkan/implicit_layer.d\n' \
    "$start" "$FRAMES" "$OUT/frames" "$layers" > "$RUN_ENV"
fi
if [ -n "${WINE_FPS:-}" ]; then   # Proton writes steam-<appid>.log into the run dir; only the fps channel is on
  mkdir -p "$SG_DATA/launch"
  printf 'PROTON_LOG=1\nPROTON_LOG_DIR=%s\nWINEDEBUG=-all,+timestamp,+fps\n' "$OUT" >> "$RUN_ENV"
fi
if [ -n "${RUN_ENV_EXTRA:-}" ]; then
  mkdir -p "$SG_DATA/launch"
  for kv in $RUN_ENV_EXTRA; do echo "$kv" >> "$RUN_ENV"; done
fi
if [ -n "${ENGINE_INI:-}" ]; then
  mkdir -p "$SG_DATA/launch"; printf '%s\n' $ENGINE_INI > "$RUN_INI"; cp "$RUN_INI" "$OUT/run.Engine.ini"
fi
[ -f "$RUN_ENV" ] && cp "$RUN_ENV" "$OUT/run.env"
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
# A game killed by the previous run takes a while to leave (Wine shuts down, then Steam's reaper): Steam refuses a launch
# in the meantime (WaitingPrevProcess, then AppError_16) and the run would wait LAUNCH_WAIT for nothing.
for _ in $(seq 90); do pgrep -f "[r]eaper SteamLaunch AppId=$APPID " >/dev/null || break; sleep 1; done
# A game that dies at startup can leave its launch chain behind: Epic Online Services helpers, or the game itself as a
# zombie whose leftover threads hang (no command line, so GAME_PROC no longer matches). Steam then refuses every launch
# (WaitingPrevProcess, AppError_16). If the reaper outlived the wait and no live game matches, end its process tree.
proc_tree() { local c; echo "$1"; for c in $(pgrep -P "$1"); do proc_tree "$c"; done; }
reaper=$(pgrep -f "[r]eaper SteamLaunch AppId=$APPID " | head -1)
if [ -n "$reaper" ] && ! pgrep -f "$GAME_PROC" >/dev/null; then
  echo "ending a stale launch chain of app $APPID (reaper $reaper, no game process)"
  # shellcheck disable=SC2046  # a list of PIDs
  kill -TERM $(proc_tree "$reaper") 2>/dev/null; sleep 5
  # shellcheck disable=SC2046
  kill -KILL $(proc_tree "$reaper") 2>/dev/null
  for _ in $(seq 30); do pgrep -f "[r]eaper SteamLaunch AppId=$APPID " >/dev/null || break; sleep 1; done
fi
# Windows left drawing behind the game take GPU and X server time from it: with SparkHome's kiosk page and Steam's Big
# Picture open behind it, Galactic Racer ran at 18 fps, and at 58 (its 60 Hz cap) with both minimised (2026-10-18).
# SparkHome minimises its kiosk when it hands a tile's game the screen; this launch is not its own, so minimise both here
# and give the kiosk the screen back after the run (EXIT trap). Big Picture stays minimised until it is opened again.
for w in "Steam Big Picture Mode" "SparkHome - Google Chrome"; do
  python3 -I "$ROOT/tools/xinput.py" iconify "$w" >/dev/null 2>&1 || continue
  echo "minimised \"$w\" for the run"; [[ $w == SparkHome* ]] && KIOSK=$w
done
LAUNCH_LOG=$SG_DATA/launch/launches.log; launches=$(wc -l < "$LAUNCH_LOG" 2>/dev/null || echo 0)
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
# run.env (FRAMES, RUN_ENV_EXTRA) reaches only games Steam starts through tools/launch.sh, which logs each launch. Without
# that line a frame capture would wait 30 minutes for a log that never comes.
if [ -f "$RUN_ENV" ] && ! tail -n +"$((launches + 1))" "$LAUNCH_LOG" 2>/dev/null | grep -q "app $APPID applied: .*run\.env"; then
  msg="$GAME did not start through tools/launch.sh, so this run's settings did not apply: it needs profiles/launch/$APPID.env and tools/steam-config.sh launch-options profiled"
  [ -n "${FRAMES:-}" ] && { kill "$G"; die "$msg"; }
  echo "warning: $msg" >&2
fi
# The governor (system/governor.sh) may switch schedulers once the game appears; record what the run used.
(sleep 10; echo "$(cat /sys/kernel/sched_ext/state 2>/dev/null) $(cat /sys/kernel/sched_ext/root/ops 2>/dev/null)" > "$OUT/sched") 8>&- &
if [ "${PIN_FAST:-0}" = 1 ]; then
  for p in $(pgrep -f "$GAME_PROC"); do taskset -a -cp "$(fast_cpus)" "$p" >/dev/null; done; echo "pinned to $(fast_cpus)"
fi
# Games whose benchmark has no command-line switch: the adapter drives the menus and closes the game when done.
# A drive that fails (an unexpected screen) ends the run instead of leaving the game running until the 30 min limit.
declare -F game_drive >/dev/null && {
  { game_drive "$OUT" "$G" || { echo "drive failed: ending the run"; kill "$G"; }; } > "$OUT/drive.log" 2>&1 8>&- & DRIVE=$!
}
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
elif [ -n "${WINE_FPS:-}" ]; then
  grep -qs "trace:fps:" "$OUT"/steam-*.log || die "no Wine fps lines in $OUT (did the game use tools/launch.sh?)"
fi
gpu_apps
[ -s "$OUT/gpu-apps" ] && echo "warning: other GPU work during the run: $(sort -u "$OUT/gpu-apps" | xargs -n1 basename | xargs)" >&2
python3 -I "$ROOT/bench/ingest.py" "$OUT" "$GAME" "$LABEL" > "$OUT/run.json" || die "ingest failed"
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print({k: d.get(k) for k in ("resolution","display","avg_fps","low1_fps","rendered_fps","frames_over_50ms","gpu_util","cpu_x925","cpu_a725")}); t=d.get("target") or {}; print("target:", t.get("verdict"), "; ".join(t.get("why") or []))' "$OUT/run.json"
echo "$OUT"
