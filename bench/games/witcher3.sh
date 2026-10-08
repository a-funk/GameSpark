# shellcheck shell=bash disable=SC2034  # variables are read by bench/run.sh
# The Witcher 3: Wild Hunt - Remastered (REDengine 3, 4.x+ build): DirectX 12 via VKD3D-Proton. Sourced by bench/run.sh.
#
# No built-in benchmark: game_drive loads the latest save (main menu > Continue) and MangoHud logs frame times while
# Geralt stands still, so a run measures wherever the player's save is. The log starts on a hotkey once the in-world
# HUD shows (bench/run.sh FRAMES_DELAY=key), so loading screens never count. Saves come down from Steam Cloud.
# One-time setup: system/frametimes.sh install; system/shim.sh install 292030 (without it the game stalls ~35 ms
# every ~100 ms, docs/FINDINGS.md); Steam launch options "<gamespark>/tools/launch.sh %command%"
# (profiles/launch/292030.env skips CDPR's launcher); launch once to accept the EULA and answer the telemetry question.
# Env: W3_UPSCALE=xess|dlss|dlss-p|fsr (default xess, the game's own pick on GB10; AAMode values from the game's
#      bin/config/r4game/user_config_matrix/pc/graphics.xml)
TUNE_KNOBS='W3_UPSCALE=xess,dlss'   # searched by bench/tune.py
APPID=292030
GAME_NAME="The Witcher 3: Wild Hunt"
GAME_API="DirectX 12 (VKD3D-Proton)"
GAME_PROC='^[A-Z]:.*witcher3\.exe'
LAUNCH_ARGS=''
: "${FRAMES:=60}" "${FRAMES_DELAY:=key}"
W3_SETTINGS="$(compat_user $APPID)/Documents/The Witcher 3/dx12user.settings"
# shellcheck source=lib/menu.sh
. "$ROOT/lib/menu.sh"

# Runs with the game closed (it rewrites the file on exit). The file has CRLF line ends; each key appears once.
# VSync is off only for measured runs; for play on the 60 Hz TV it stays on (game_collect restores it after a run).
game_prepare() {
  local aa q vsync=true
  [ -n "${BENCH_RUN:-}" ] && vsync=false
  [ -f "$W3_SETTINGS" ] || die "no $W3_SETTINGS: launch the game once first"
  case ${W3_UPSCALE:-xess} in
    xess) aa=7 q="XESSQuality=0" ;;      # Auto
    dlss) aa=6 q="DLSSQuality=0" ;;      # Auto
    dlss-p) aa=6 q="DLSSQuality=3" ;;    # Performance
    fsr) aa=5 q="FSR2Quality=0" ;;       # Auto
    *) die "W3_UPSCALE=${W3_UPSCALE}?" ;;
  esac
  # Without the two Should* flags the game re-detects a preset and upscaler at start and overwrites these. Frame
  # generation stays off: the TV runs at 60 Hz and the game renders above that (it would only add latency).
  local kv expr=""
  for kv in VSync=$vsync 'Resolution="1920x1080"' FullScreenMode=1 LimitFPS=0 AAMode=$aa "$q" DLSSGMode=0 \
            FSRFramegen=0 ShouldDetectEditorGraphicsPreset=false ShouldRefetchUpscaler=false; do
    expr+="s#^${kv%%=*}=[^\r]*#$kv#;"
  done
  sed -i -E "$expr" "$W3_SETTINGS"
  cp "$W3_SETTINGS" "$1/dx12user.settings"
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
  menu_send move 333 385; menu_pause 5                         # the menu drops keys while it settles
  for i in 1 2 3; do   # repeating is safe: E only reaches the menu while it still shows, on Continue
    menu_send key "e~0.2"; menu_pause 15                       # the loading screen varies (story recap, tips)
    screen_has loading "LOAD GAME" || break
    [ -n "${MENU_REPLAY:-}" ] && break
  done
  screen_has loading "LOAD GAME" && { echo "Continue was not taken"; kill "$2"; return 1; }
  menu_wait world "Sprint Left|Witcher Senses|Call Horse" 45 4 || { kill "$2"; return 1; }   # ~40 s to load
  menu_pause 15                                                # let streaming settle
  frames_start
}

game_collect() {  # $1 run dir: back to the play setting; the run's result is its frame log
  sed -i -E 's#^VSync=[^\r]*#VSync=true#' "$W3_SETTINGS"
  compgen -G "$1/frames/*_summary.csv" >/dev/null
}
