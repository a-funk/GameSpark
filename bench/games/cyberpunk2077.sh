# shellcheck shell=bash disable=SC2034  # variables are read by bench/run.sh
# Cyberpunk 2077 (REDengine, DirectX 12 -> VKD3D-Proton). Sourced by bench/run.sh.
# Built-in benchmark launch recipe from the Phoronix Test Suite cyberpunk2077 profile: fully unattended, about 3 minutes.
# Env: CP_CANDIDATE=P0|A|B|C  writes that candidate (profiles/settings/1091500/candidates.sh) into UserSettings.json for
#        this run only; the player's file goes back once the game has closed. Unset: the file as it is.
#      CP_SET="/group/option=value[@index];..."  more settings for this run, after the candidate, separated by ";" (a value
#        may hold spaces), e.g. "/graphics/presets/DLSS=Ultra Performance@5;/graphics/performance/CrowdDensity=Low@0".
# The output resolution is the display's (lib/env.sh game_res; GAME_RES=WxH overrides). Measured runs also force VSync off
# and lift the frame cap. The run dir keeps the UserSettings.json the game ran with and a "preset" line; the benchmark's
# summary.json says what the game used (renderWidth/Height, DLSSEnabled, DLSSQuality: 0 Performance, 1 Balanced, 2 Quality,
# 3 Ultra Performance, 5 DLAA), and this adapter warns when it is not the resolution asked for.
APPID=1091500
GAME_PROC='^[A-Z]:.*Cyberpunk2077\.exe'   # the Wine process (S:\...\Cyberpunk2077.exe)
LAUNCH_ARGS='--launcher-skip -benchmark -skipStartScreen'
CP_USER=$(compat_user $APPID)
CP_RESULTS="$CP_USER/Documents/CD Projekt Red/Cyberpunk 2077/benchmarkResults"
CP_SETTINGS=${CP_USERSETTINGS:-$CP_USER/AppData/Local/CD Projekt Red/Cyberpunk 2077/UserSettings.json}
CP_PENDING=$SG_DATA/launch/cyberpunk-candidate.pending   # the backup to put back; present only until the restore is done
# shellcheck source=profiles/settings/lib.sh
. "$ROOT/profiles/settings/lib.sh"
# shellcheck source=profiles/settings/1091500/candidates.sh
. "$ROOT/profiles/settings/1091500/candidates.sh"

cp_tool() { CP_USERSETTINGS=$CP_SETTINGS python3 -I "$ROOT/bench/cyberpunk2077_settings.py" "$@"; }

cp_restore() {   # the player's file back from the pending backup; refused while the game runs
  local b
  [ -f "$CP_PENDING" ] || return 0
  if pgrep -f "$GAME_PROC" >/dev/null; then
    echo "warning: Cyberpunk 2077 is running; its settings stay as they are" >&2
    return 1
  fi
  read -r b < "$CP_PENDING"
  cp -p "$b" "$CP_SETTINGS" && rm -f "$CP_PENDING" && echo "restored the player's UserSettings.json from $b"
}

game_prepare() {   # $1 run dir; runs with the game closed (the game rewrites the file)
  local b res r s
  local -a keys=() extra=()
  cp_restore || die "an earlier run's settings are still in place (see above)"
  [ -f "$CP_SETTINGS" ] || die "no $CP_SETTINGS: launch the game once first"
  res=$(game_res) || die "cannot read the display's resolution (DISPLAY?); set GAME_RES=WxH"
  case ${CP_CANDIDATE:-} in
    '') ;;
    P0) keys=("${CP_P0[@]}") ;;
    A) keys=("${CP_A[@]}") ;;
    B) keys=("${CP_B[@]}") ;;
    C) keys=("${CP_C[@]}") ;;
    *) die "CP_CANDIDATE=$CP_CANDIDATE: P0, A, B or C" ;;
  esac
  r=$res; [ "$res" = 3840x2160 ] && r=$res@9   # the index the candidates use for 4K
  keys+=("/video/display/Resolution=$r" /video/display/WindowMode=BorderlessWindowed@1)
  [ -n "${BENCH_RUN:-}" ] && keys+=(/video/display/VSync=UI-Settings-Video-QualitySetting-Off@0 /video/display/MaximumFPS_OnOff=false)
  IFS=';' read -ra extra <<< "${CP_SET:-}"
  for s in "${extra[@]}"; do [ -n "$s" ] && keys+=("$s"); done
  mkdir -p "$SG_DATA/launch"
  b=$(sg_backup "$APPID" "$CP_SETTINGS" "bench run ${CP_CANDIDATE:-settings}") || die "backup failed"
  echo "$b" > "$CP_PENDING"
  cp_tool set "${keys[@]}" > "$1/settings-changes.txt" || { cat "$1/settings-changes.txt"; die "settings not written (see above)"; }
  echo "settings for this run written (the player's file: $b)"
  cp "$CP_SETTINGS" "$1/UserSettings.json"
  echo "candidate ${CP_CANDIDATE:-as is} · $(cp_tool describe)" > "$1/preset"
}

game_cleanup() {   # EXIT trap of bench/run.sh: wait for the game to close, then the player's file back
  [ -f "$CP_PENDING" ] || return 0
  for _ in $(seq 30); do pgrep -f "$GAME_PROC" >/dev/null || break; sleep 1; done
  cp_restore || true
}

# The benchmark writes benchmarkResults/<timestamp>/{summary.json,frames.csv}; take the one written during this run.
game_collect() {
  local d rw rh
  d=$(find "$CP_RESULTS" -mindepth 1 -maxdepth 1 -type d -newer "$1/start" | sort | tail -1)
  if [ -n "$d" ] && [ -f "$d/summary.json" ]; then
    cp -r "$d" "$1/result"
    read -r rw rh < <(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1]))["Data"]; print(d["renderWidth"], d["renderHeight"])' "$d/summary.json")
    [ "${rw:-0}x${rh:-0}" = "$(game_res 2>/dev/null)" ] ||
      echo "warning: the game's output resolution was ${rw:-?}x${rh:-?}, the run asked for $(game_res 2>/dev/null)" >&2
    game_cleanup
    return 0
  fi
  game_cleanup
  return 1
}
