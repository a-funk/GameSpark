# shellcheck shell=bash disable=SC2034  # variables are read by bench/run.sh
# The Witcher 3: Wild Hunt - Remastered (REDengine 3, 5.0 build, DirectX 12 only): VKD3D-Proton. Sourced by bench/run.sh.
#
# No built-in benchmark: game_drive loads the latest save (main menu > Continue) and MangoHud logs frame times while
# Geralt stands still, so a run measures wherever the player's save is. The log starts on a hotkey once the in-world
# HUD shows (bench/run.sh FRAMES_DELAY=key), so loading screens never count. Saves come down from Steam Cloud.
# About 4 minutes, unattended (the menu steps are OCR-gated, lib/menu.sh).
# One-time setup: system/frametimes.sh install; system/shim.sh install 292030 (without it the game stalls ~35 ms
# every ~100 ms, docs/FINDINGS.md); Steam launch options "<gamespark>/tools/launch.sh %command%"
# (profiles/launch/292030.env skips CDPR's launcher); launch once to accept the EULA and answer the telemetry question.
# Env: W3_CANDIDATE=P0|A-E  writes that candidate (profiles/settings/292030/candidates.sh) into dx12user.settings for this
#        run only; the player's file goes back once the game has closed. Unset: the file as it is.
#      W3_SET="Key=Value ..."  more dx12user.settings values for this run, after the candidate (ini_set.py: each key once, no
#        spaces), e.g. "AAMode=6 DLSSQuality=2" (AAMode and quality values: the game's bin/config/r4game/user_config_matrix/pc/
#        graphics.xml, listed in candidates.sh).
#      W3_UPSCALE=xess|dlss|dlss-p|fsr  the older knob bench/tune.py searches: AAMode and the quality "Auto" (dlss-p:
#        Performance); with no W3_CANDIDATE and no W3_UPSCALE the player's upscaler stands.
# The output resolution is the display's (lib/env.sh game_res; GAME_RES=WxH overrides). Measured runs also force VSync off,
# and keep what stops the game re-detecting its settings (the two Should* flags). Frame generation stays off: the TV runs
# at 60 Hz, and with VSync a frame generator holds the game to half the refresh rate (it would only add latency).
# The run dir keeps dx12user.settings as the game ran with it, a "preset" line, scene.png (the scene before the log starts,
# to compare the look of the candidates) and modules.txt: the upscaler DLLs the running game has mapped (nvngx_dlss*.dll for
# DLSS, libxess*.dll for XeSS, amd_fidelityfx_*.dll for FSR). A DLSS candidate without nvngx_dlss.dll there did not run DLSS.
TUNE_KNOBS='W3_UPSCALE=xess,dlss'   # searched by bench/tune.py
APPID=292030
GAME_NAME="The Witcher 3: Wild Hunt"
GAME_API="DirectX 12 (VKD3D-Proton)"
GAME_PROC='^[A-Z]:.*witcher3\.exe'
LAUNCH_ARGS=''
: "${FRAMES:=60}" "${FRAMES_DELAY:=key}"
W3_SETTINGS=${W3_DX12_SETTINGS:-$(compat_user $APPID)/Documents/The Witcher 3/dx12user.settings}
W3_PENDING=$SG_DATA/launch/witcher3-candidate.pending   # the backup to put back; present only until the restore is done
# shellcheck source=lib/menu.sh
. "$ROOT/lib/menu.sh"
# shellcheck source=profiles/settings/lib.sh
. "$ROOT/profiles/settings/lib.sh"
# shellcheck source=profiles/settings/292030/candidates.sh
. "$ROOT/profiles/settings/292030/candidates.sh"

w3_restore() {   # the player's file back from the pending backup; refused while the game runs
  local b
  [ -f "$W3_PENDING" ] || return 0
  if pgrep -f "$GAME_PROC" >/dev/null; then
    echo "warning: $GAME_NAME is running; its settings stay as they are" >&2
    return 1
  fi
  read -r b < "$W3_PENDING"
  cp -p "$b" "$W3_SETTINGS" && rm -f "$W3_PENDING" && echo "restored the player's dx12user.settings from $b"
}

w3_val() { tr -d '\r' < "$W3_SETTINGS" | sed -n "s/^$1=\"\{0,1\}\([^\"]*\).*/\1/p" | head -1; }

w3_describe() {   # $1 run dir: the run's resolution and preset, for the record
  local res aa q mode ratio render up
  res=$(w3_val Resolution)
  aa=$(w3_val AAMode)
  ratio=
  case $aa in
    6) q=$(w3_val DLSSQuality)
       case $q in 0) mode=Auto ;; 1) mode=Quality; ratio=0.6667 ;; 2) mode=Balanced; ratio=0.58 ;; 3) mode=Performance; ratio=0.5 ;;
         4) mode="Ultra Performance"; ratio=0.3333 ;; 5) mode=DLAA; ratio=1 ;; *) mode="quality $q" ;; esac
       up="DLSS $mode" ;;
    7) q=$(w3_val XESSQuality)
       case $q in 0) mode=Auto ;; 1) mode=NativeAA; ratio=1 ;; 4) mode=Quality; ratio=0.6667 ;; 5) mode=Balanced; ratio=0.5882 ;;
         6) mode=Performance; ratio=0.5 ;; 7) mode="Ultra Performance"; ratio=0.3333 ;; *) mode="quality $q" ;; esac
       up="XeSS $mode (DP4a on NVIDIA)" ;;
    5) q=$(w3_val FSR2Quality)
       case $q in 0) mode=Auto ;; 2) mode=Quality; ratio=0.6667 ;; 3) mode=Balanced; ratio=0.5882 ;; 4) mode=Performance; ratio=0.5 ;;
         5) mode="Ultra Performance"; ratio=0.3333 ;; *) mode="quality $q" ;; esac
       up="FSR $mode" ;;
    1) up=FXAA ;;
    0) up="no anti-aliasing" ;;
    *) up="AAMode $aa" ;;
  esac
  if [ -n "$ratio" ] && [[ $res =~ ^([0-9]+)x([0-9]+)$ ]]; then
    render=$(awk -v w="${BASH_REMATCH[1]}" -v h="${BASH_REMATCH[2]}" -v r="$ratio" 'BEGIN { printf "%dx%d", w * r + 0.5, h * r + 0.5 }')
    up="$up (render $render)"
  fi
  echo "$res" > "$1/resolution"
  echo "$up · candidate ${W3_CANDIDATE:-as is} · shadows $(w3_val CascadeShadowmapSize), GTAO $(w3_val GTAOQuality), grass $(w3_val GrassDensity), foliage depth $(w3_val MaxVisibilityDepth)" > "$1/preset"
}

w3_modules() {   # $1 run dir, $2 game pid: the upscaler DLLs the running game has mapped (what is really in use)
  grep -o -i -E 'nvngx_dlss[a-z]*\.dll|libxess[a-z_]*\.dll|amd_fidelityfx_(upscaler|framegeneration)[a-z0-9_]*\.dll' "/proc/$2/maps" 2>/dev/null |
    tr 'A-Z' 'a-z' | sort -u > "$1/modules.txt"
  echo "upscaler DLLs mapped: $(paste -sd' ' "$1/modules.txt")"
}

# Runs with the game closed (it rewrites the file on exit). The file has CRLF line ends; each key appears once.
game_prepare() {   # $1 run dir
  local res b
  local -a keys=()
  w3_restore || die "an earlier run's settings are still in place (see above)"
  [ -f "$W3_SETTINGS" ] || die "no $W3_SETTINGS: launch the game once first"
  res=$(game_res) || die "cannot read the display's resolution (DISPLAY?); set GAME_RES=WxH"   # lib/env.sh
  case ${W3_CANDIDATE:-} in
    '') ;;
    P0) keys=("${W3_P0[@]}") ;;
    A) keys=("${W3_A[@]}") ;;
    B) keys=("${W3_B[@]}") ;;
    C) keys=("${W3_C[@]}") ;;
    D) keys=("${W3_D[@]}") ;;
    E) keys=("${W3_E[@]}") ;;
    *) die "W3_CANDIDATE=$W3_CANDIDATE: P0 or A-E" ;;
  esac
  case ${W3_UPSCALE:-} in
    '') ;;
    xess) keys+=(AAMode=7 XESSQuality=0) ;;      # Auto
    dlss) keys+=(AAMode=6 DLSSQuality=0) ;;      # Auto
    dlss-p) keys+=(AAMode=6 DLSSQuality=3) ;;    # Performance
    fsr) keys+=(AAMode=5 FSR2Quality=0) ;;       # Auto
    *) die "W3_UPSCALE=${W3_UPSCALE}?" ;;
  esac
  # Without the two Should* flags the game re-detects a preset and upscaler at start and overwrites these. Frame
  # generation stays off (see the header).
  keys+=("Resolution=\"$res\"" FullScreenMode=1 LimitFPS=0 DLSSGMode=0 FSRFramegen=0
    ShouldDetectEditorGraphicsPreset=false ShouldRefetchUpscaler=false)
  [ -n "${BENCH_RUN:-}" ] && keys+=(VSync=false)
  # shellcheck disable=SC2206  # W3_SET is a space-separated list by design
  keys+=(${W3_SET:-})
  b=$(sg_backup "$APPID" "$W3_SETTINGS" "${BENCH_RUN:+bench run }${W3_CANDIDATE:-settings}") || die "backup failed"
  if [ -n "${BENCH_RUN:-}" ]; then   # bench/tune.py --apply (no BENCH_RUN) keeps its knobs, as before
    mkdir -p "$SG_DATA/launch"; echo "$b" > "$W3_PENDING"
  fi
  python3 -I "$ROOT/profiles/settings/ini_set.py" "$W3_SETTINGS" "${keys[@]}" || die "settings not written (see above)"
  [ -n "${BENCH_RUN:-}" ] && echo "settings for this run written (the player's file: $b)"
  cp "$W3_SETTINGS" "$1/dx12user.settings"
  w3_describe "$1"
}

game_cleanup() {   # EXIT trap of bench/run.sh: wait for the game to close, then the player's file back
  [ -f "$W3_PENDING" ] || return 0
  for _ in $(seq 30); do pgrep -f "$GAME_PROC" >/dev/null || break; sleep 1; done
  w3_restore || true
}

# Every key waits for OCR to confirm its screen (lib/menu.sh). Continue loads the newest save; the pointer is
# parked on it first because the menu highlights whatever the pointer hovers.
game_drive() {  # $1 run dir, $2 game pid
  local out=$1 i
  MENU_DIR=$out
  for i in $(seq 40); do   # intro video, then the CD PROJEKT RED account notice, then the main menu
    if screen_has menu "LOAD GAME"; then break
    elif screen_has menu "Skip"; then menu_send key "space~0.2"
    elif screen_has menu "Continue"; then menu_send key "e~0.2"
    fi
    [ -n "${MENU_REPLAY:-}" ] && break
    sleep 4
  done
  screen_has menu "LOAD GAME" || { echo "main menu never showed"; kill "$2"; return 1; }
  menu_send --ref 1920x1080 move 333 385; menu_pause 5         # the menu drops keys while it settles
  for i in 1 2 3; do   # repeating is safe: E only reaches the menu while it still shows, on Continue
    menu_send key "e~0.2"; menu_pause 15                       # the loading screen varies (story recap, tips)
    screen_has loading "LOAD GAME" || break
    [ -n "${MENU_REPLAY:-}" ] && break
  done
  screen_has loading "LOAD GAME" && { echo "Continue was not taken"; kill "$2"; return 1; }
  menu_wait world "Sprint Left|Witcher Senses|Call Horse" 45 4 || { kill "$2"; return 1; }   # ~40 s to load
  menu_pause 15                                                # let streaming settle
  [ -n "${MENU_REPLAY:-}" ] || "$ROOT/tools/shot.sh" "$out/scene.png" >/dev/null   # before the log starts: no cost to it
  frames_start
  menu_pause 5
  [ -n "${MENU_REPLAY:-}" ] || w3_modules "$out" "$2"
}

game_collect() {  # $1 run dir: the player's settings back; the run's result is its frame log
  game_cleanup
  compgen -G "$1/frames/*_summary.csv" >/dev/null
}
