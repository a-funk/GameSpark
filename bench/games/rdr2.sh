# shellcheck shell=bash disable=SC2034  # variables are read by bench/run.sh
# Red Dead Redemption 2 (RAGE): native Vulkan or DirectX 12 via VKD3D-Proton. Sourced by bench/run.sh.
#
# Started by the Rockstar Games Launcher; the benchmark is in Settings > Graphics and has no command-line switch,
# so game_drive works the menus (keyboard; Run Benchmark Tests needs X held for seconds) and waits for the results
# file the game writes to Documents\Rockstar Games\Red Dead Redemption 2\Benchmarks. About 9 minutes, unattended.
# One-time setup (docs/FINDINGS.md has the reasons):
#   launch once from Steam and sign in to the Rockstar launcher. Its sign-in page only renders inside a Wine
#   virtual desktop (prefix registry Software\Wine\Explorer, Desktop=Default): game_prepare keeps its size, Desktops\Default,
#   at the game's output resolution, because the game's window sits inside it (a 1920x1080 desktop cut a 4K game to a corner).
#   start Steam with tools/steam-console.sh, which hides the host's software Vulkan drivers (lib/env.sh); RDR2
#   otherwise picks llvmpipe. Keep NVAPI enabled: on an NVIDIA GPU the game waits forever for nvapi64.dll.
# Env: RDR2_API=dx12|vulkan (default dx12; vulkan crashes at start under FEX 2610 Vulkan thunking)
#      RDR2_CANDIDATE=P0|A|B|C  writes that candidate (profiles/settings/1174180/candidates.sh) into system.xml for this run
#        only; the player's file goes back once the game has closed. Unset: the file as it is.
#      RDR2_SET="key=value ..."  more system.xml values for this run, after the candidate (xml_set.py: numbers, true/false or
#        kSetting tokens, no spaces), e.g. "dlssIndex=4 dlssQuality=0".
# The output resolution is the display's (lib/env.sh game_res; GAME_RES=WxH overrides). Measured runs also force VSync off.
# The run dir keeps system.xml as the game ran with it, a "preset" line and modules.txt: the DLSS DLL the running game has
# mapped (empty with DLSS off; when a DLSS candidate leaves it empty, DLSS did not engage and the fps are native-resolution's).
APPID=1174180
GAME_PROC='^[A-Z]:.*\\RDR2\.exe'   # the game, not PlayRDR2.exe (Steam's stub) or the launcher
LAUNCH_ARGS=''
LAUNCH_RETRIES=3; LAUNCH_WAIT=150   # the launcher's sign-in sometimes stalls; a fresh launch clears it
RDR2_DOC="$(compat_user $APPID)/Documents/Rockstar Games/Red Dead Redemption 2"
RDR2_XML=${RDR2_SYSTEM_XML:-$RDR2_DOC/Settings/system.xml}
RDR2_PFX=${RDR2_PREFIX:-$STEAM_ROOT/steamapps/compatdata/$APPID/pfx}
RDR2_PENDING=$SG_DATA/launch/rdr2-candidate.pending   # the backup to put back; present only until the restore is done
# shellcheck source=lib/menu.sh
. "$ROOT/lib/menu.sh"
# shellcheck source=profiles/settings/lib.sh
. "$ROOT/profiles/settings/lib.sh"
# shellcheck source=profiles/settings/1174180/candidates.sh
. "$ROOT/profiles/settings/1174180/candidates.sh"

rdr2_kill() {
  local p
  [ -n "${MENU_REPLAY:-}" ] && return 0
  for p in $(pgrep -f "^[A-Z]:.*(\\\\RDR2\.exe|Rockstar Games|PlayRDR2)"); do kill "$p"; done
  for _ in $(seq 20); do pgrep -f "^[A-Z]:.*(\\\\RDR2\.exe|Rockstar Games|PlayRDR2)" >/dev/null || return 0; sleep 2; done
  pkill -9 -f "^[A-Z]:.*(\\\\RDR2\.exe|Rockstar Games|PlayRDR2)"; sleep 4
}
game_abort() { rdr2_kill; }

rdr2_restore() {   # the player's file back from the pending backup; refused while the game runs
  local b
  [ -f "$RDR2_PENDING" ] || return 0
  if pgrep -f "$GAME_PROC" >/dev/null; then
    echo "warning: Red Dead Redemption 2 is running; its settings stay as they are" >&2
    return 1
  fi
  read -r b < "$RDR2_PENDING"
  cp -p "$b" "$RDR2_XML" && rm -f "$RDR2_PENDING" && echo "restored the player's system.xml from $b"
}

rdr2_desktop() {   # WxH: the Wine virtual desktop's size, set once the previous run's Wine has exited (it rewrites user.reg)
  local cur
  cur=$(awk '/^\[Software\\\\Wine\\\\Explorer\\\\Desktops\]/ { on = 1; next } /^\[/ { on = 0 }
    on && /^"Default"=/ { gsub(/^"Default"="|"$/, ""); print; exit }' "$RDR2_PFX/user.reg")
  [ "$cur" = "$1" ] && return 0
  for _ in $(seq 90); do pgrep -f "[r]eaper SteamLaunch AppId=$APPID " >/dev/null || break; sleep 1; done
  if pgrep -f "^[A-Z]:.*(\\\\RDR2\.exe|Rockstar Games|PlayRDR2)" >/dev/null; then
    echo "warning: Red Dead Redemption 2 is running; the Wine virtual desktop stays at $cur" >&2
    return 1
  fi
  sg_backup "$APPID" "$RDR2_PFX/user.reg" "wine virtual desktop ${cur:-none} -> $1" >/dev/null || return 1
  python3 -I "$ROOT/tools/winereg.py" "$RDR2_PFX" 'Software\Wine\Explorer' Desktop=Default >/dev/null &&
    python3 -I "$ROOT/tools/winereg.py" "$RDR2_PFX" 'Software\Wine\Explorer\Desktops' "Default=$1" >/dev/null &&
    echo "Wine virtual desktop: ${cur:-none} -> $1"
}

rdr2_val() { sed -n "s#.*<$1 value=\"\([^\"]*\)\" />.*#\1#p; s#.*<$1>\([^<]*\)</$1>.*#\1#p" "$RDR2_XML" | head -1; }

rdr2_describe() {   # $1 run dir: the run's resolution and preset, for the record
  local w h mode ratio render up
  w=$(rdr2_val screenWidth); h=$(rdr2_val screenHeight)
  lv() { rdr2_val "$1" | sed 's/kSettingLevel_//'; }
  case $(rdr2_val dlssIndex) in
    1) mode=Auto; ratio=1 ;;
    2) mode=Quality; ratio=0.6667 ;;
    3) mode=Balanced; ratio=0.58 ;;
    4) mode=Performance; ratio=0.5 ;;
    5) mode="Ultra Performance"; ratio=0.3333 ;;
    *) mode=; ratio=1 ;;
  esac
  render=$(awk -v w="$w" -v h="$h" -v r="$ratio" 'BEGIN { printf "%dx%d", w * r + 0.5, h * r + 0.5 }')
  if [ -n "$mode" ]; then up="DLSS $mode (render $render)"; else up="native ${w}x${h}"; fi
  echo "${w}x${h}" > "$1/resolution"
  echo "$up · candidate ${RDR2_CANDIDATE:-as is} · TAA $(lv taa), shadows $(lv shadowQuality), reflections $(lv reflectionQuality), volumetrics $(lv volumetricsQuality)" > "$1/preset"
}

rdr2_modules() {   # $1 run dir, $2 game pid: the upscaler DLLs the running game has mapped (what is really in use)
  grep -o -i -E 'nvngx_dlss[a-z]*\.dll|ffx_fsr2_api[a-z0-9_]*\.dll' "/proc/$2/maps" 2>/dev/null | tr 'A-Z' 'a-z' | sort -u > "$1/modules.txt"
  echo "upscaler DLLs mapped: $(paste -sd' ' "$1/modules.txt")"
}

game_prepare() {   # $1 run dir; runs with the game closed
  local api=kSettingAPI_DX12 res b
  local -a keys=()
  [ "${RDR2_API:-dx12}" = vulkan ] && api=kSettingAPI_Vulkan
  rdr2_restore || die "an earlier run's settings are still in place (see above)"
  [ -f "$RDR2_XML" ] || die "no $RDR2_XML: launch the game once first"
  res=$(game_res) || die "cannot read the display's resolution (DISPLAY?); set GAME_RES=WxH"
  case ${RDR2_CANDIDATE:-} in
    '') ;;
    P0) keys=("${RDR2_P0[@]}") ;;
    A) keys=("${RDR2_A[@]}") ;;
    B) keys=("${RDR2_B[@]}") ;;
    C) keys=("${RDR2_C[@]}") ;;
    *) die "RDR2_CANDIDATE=$RDR2_CANDIDATE: P0, A, B or C" ;;
  esac
  keys+=("API=$api" adapterIndex=0 windowed=2 "screenWidth=${res%x*}" "screenHeight=${res#*x}"
    "screenWidthWindowed=${res%x*}" "screenHeightWindowed=${res#*x}")
  [ -n "${BENCH_RUN:-}" ] && keys+=(vSync=0)
  # shellcheck disable=SC2206  # RDR2_SET is a space-separated list by design
  keys+=(${RDR2_SET:-})
  rdr2_desktop "$res" || die "could not set the Wine virtual desktop to $res (see above)"
  mkdir -p "$SG_DATA/launch"
  b=$(sg_backup "$APPID" "$RDR2_XML" "bench run ${RDR2_CANDIDATE:-settings}") || die "backup failed"
  echo "$b" > "$RDR2_PENDING"
  python3 -I "$ROOT/profiles/settings/xml_set.py" "$RDR2_XML" "${keys[@]}" || die "settings not written (see above)"
  echo "settings for this run written (the player's file: $b)"
  cp "$RDR2_XML" "$1/system.xml"
  rdr2_describe "$1"
}

game_cleanup() {   # EXIT trap of bench/run.sh: wait for the game to close, then the player's file back
  [ -f "$RDR2_PENDING" ] || return 0
  for _ in $(seq 30); do pgrep -f "$GAME_PROC" >/dev/null || break; sleep 1; done
  rdr2_restore || true
}

# Every key waits for OCR to confirm its screen (lib/menu.sh); any surprise stops the run and closes the game.
game_drive() {  # $1 run dir, $2 game pid
  local out=$1 i res gw gh
  MENU_DIR=$out
  res=$(game_res) || res=1920x1080
  gw=${res%x*}; gh=${res#*x}   # the game's window sits at the top left of the screen: point positions scale with its size
  menu_wait menu "QUIT ?GAME|SOCIAL ?CLUB" 60 5 || { rdr2_kill; return 1; }
  menu_pause 10                                                 # the menu ignores keys while it settles
  # Z opens Settings and is harmless to repeat; the grid is recognised by its footer (tile labels OCR unreliably).
  menu_press settings "Build [0-9]" 4 key z || { rdr2_kill; return 1; }
  menu_send move $((365 * gw / 1920)) $((710 * gh / 1080)); menu_pause 1   # the grid selects what the pointer hovers: Graphics
  menu_press graphics "BENCHMARK" 1 key Return || { rdr2_kill; return 1; }
  menu_press alert "benchmark tests" 1 key "x~4" || { rdr2_kill; return 1; }   # Run Benchmark Tests: a tap is ignored
  menu_send key Return
  date +%s > "$out/bench_start"
  [ -n "${MENU_REPLAY:-}" ] && { menu_wait end "End of benchmark" 1 0; return; }
  sleep 60; rdr2_modules "$out" "$2"                            # the first pass is running: DLSS is loaded by now
  sleep 180                                                     # five passes take about 5 minutes
  for i in $(seq 120); do
    kill -0 "$2" 2>/dev/null || { echo "game exited during the benchmark"; break; }
    if screen_has end "End of benchmark"; then
      date +%s > "$out/bench_end"
      menu_send key BackSpace                                   # Exit Benchmarking: the results file is written now
      for _ in $(seq 30); do sleep 2; [ -n "$(find "$RDR2_DOC/Benchmarks" -type f -newer "$out/start" 2>/dev/null)" ] && break; done
      break
    fi
    sleep 10
  done
  sleep 5
  rdr2_kill
}

game_collect() {
  local f rc=1
  f=$(find "$RDR2_DOC/Benchmarks" -type f -newer "$1/start" 2>/dev/null | sort | tail -1)
  if [ -n "$f" ] && mkdir -p "$1/result" && cp "$f" "$1/result/" && cp "$1/bench_start" "$1/bench_end" "$1/result/"; then rc=0; fi
  game_cleanup
  return $rc
}
