# shellcheck shell=bash disable=SC2034  # variables are read by bench/run.sh
# CONTROL Resonant (Remedy's Northlight engine, DirectX 12 via VKD3D-Proton). Sourced by bench/run.sh.
#
# No built-in benchmark. At 4K the game is GPU-bound (35 fps with DLSS Quality, 2560x1440 render, GPU 94% busy, CPU 29%),
# so the runs compare the DLSS mode (the render size in renderer.ini) and the costly settings. game_drive loads the
# player's newest save (main menu > Continue) and MangoHud logs frame times while the character stands still: a run
# measures wherever the save is, the same place every time. The log starts on a hotkey once the loading screen is gone
# (FRAMES_DELAY=key), so loading never counts; a screenshot of the scene is kept to compare the look of the candidates.
# One-time setup: system/frametimes.sh install; Steam launch options "<gamespark>/tools/launch.sh %command%".
# Seen for real (2026-10-13): the Photosensitivity Warning, the save-icon notice, "Press [Return] to Start"; the main menu's words (CONTINUE
# and OPTIONS) and the loading screen's ("Cycle Tips", seen on a loading screen) are guesses. Every step is gated on OCR
# and anything unexpected ends the run, with the screens kept in the run dir. Watch the first run, or use CTRL_MANUAL=1.
# Env: CTRL_CANDIDATE=P0|A|B|C  writes that candidate (profiles/settings/3669870/candidates.sh) into renderer.ini for this
#        run only; the player's file goes back once the game has closed. Unset: the file as it is.
#      CTRL_SET="m_key=value ..."  more renderer.ini values for this run, after the candidate (JSON numbers/true/false),
#        e.g. m_bDLSSLegacy=true (the older DLSS model) or m_iRenderResolutionX=2227 m_iRenderResolutionY=1253.
#      CTRL_MANUAL=1  no menu drive: load the save yourself and press Shift_R+Scroll_Lock (MangoHud's hotkey) once the
#        scene is steady; the run ends when the log is written.
# Measured runs also lift the game's frame cap and VSync (m_maxFrameRate=360.0, m_eVSync=0).
APPID=3669870
GAME_NAME="CONTROL Resonant"
GAME_API="DirectX 12 (VKD3D-Proton)"
GAME_EXE='CONTROL Resonant/CONTROLResonant.exe'   # under steamapps/common (64-bit)
GAME_PROC='^[A-Z]:.*CONTROLResonant\.exe'
LAUNCH_ARGS=''
: "${FRAMES:=60}" "${FRAMES_DELAY:=key}"
CTRL_CFG=${CTRL_INI:-$(compat_user "$APPID")/AppData/Local/Remedy/CONTROLResonant/renderer.ini}
CTRL_PENDING=$SG_DATA/launch/control-candidate.pending   # the backup to put back; present only until the restore is done
# shellcheck source=lib/menu.sh
. "$ROOT/lib/menu.sh"
# shellcheck source=profiles/settings/lib.sh
. "$ROOT/profiles/settings/lib.sh"
# shellcheck source=profiles/settings/3669870/candidates.sh
. "$ROOT/profiles/settings/3669870/candidates.sh"

ctrl_restore() {   # the player's file back from the pending backup; refused while the game runs
  local b
  [ -f "$CTRL_PENDING" ] || return 0
  if pgrep -f "$GAME_PROC" >/dev/null; then
    echo "warning: $GAME_NAME is running; its settings stay as they are" >&2
    return 1
  fi
  read -r b < "$CTRL_PENDING"
  cp -p "$b" "$CTRL_CFG" && rm -f "$CTRL_PENDING" && echo "restored the player's renderer.ini from $b"
}

ctrl_val() { sed -n "s/^[[:space:]]*\"$1\":[[:space:]]*\([^,]*\),\{0,1\}.*/\1/p" "$CTRL_CFG" | head -1; }

ctrl_describe() {   # $1 run dir: the run's resolution and preset, for the record
  local rx ry mode
  rx=$(ctrl_val m_iRenderResolutionX); ry=$(ctrl_val m_iRenderResolutionY)
  case $rx in 3840) mode=DLAA ;; 2560) mode=Quality ;; 1920) mode=Performance ;; 1280) mode="Ultra Performance" ;; *) mode="${rx}x${ry}" ;; esac
  echo "$(ctrl_val m_iOutputResolutionX)x$(ctrl_val m_iOutputResolutionY)" > "$1/resolution"
  echo "DLSS $mode (render ${rx}x${ry}) · candidate ${CTRL_CANDIDATE:-as is} · SDF $(ctrl_val m_eSDFQuality), GI $(ctrl_val m_eGIQuality)" > "$1/preset"
}

game_prepare() {   # $1 run dir; runs with the game closed (it rewrites renderer.ini at launch and exit)
  local b
  local -a keys=()
  ctrl_restore || die "an earlier run's settings are still in place (see above)"
  [ -f "$CTRL_CFG" ] || die "no $CTRL_CFG: launch the game once first"
  case ${CTRL_CANDIDATE:-} in
    '') ;;
    P0) keys=("${CTRL_P0[@]}") ;;
    A) keys=("${CTRL_A[@]}") ;;
    B) keys=("${CTRL_B[@]}") ;;
    C) keys=("${CTRL_C[@]}") ;;
    *) die "CTRL_CANDIDATE=$CTRL_CANDIDATE: P0, A, B or C" ;;
  esac
  [ -n "${BENCH_RUN:-}" ] && keys+=(m_maxFrameRate=360.0 m_eVSync=0)
  # shellcheck disable=SC2206  # CTRL_SET is a space-separated list by design
  keys+=(${CTRL_SET:-})
  if [ ${#keys[@]} -gt 0 ]; then
    mkdir -p "$SG_DATA/launch"
    b=$(sg_backup "$APPID" "$CTRL_CFG" "bench run ${CTRL_CANDIDATE:-settings}") || die "backup failed"
    echo "$b" > "$CTRL_PENDING"
    python3 -I "$ROOT/profiles/settings/flatjson_set.py" "$CTRL_CFG" "${keys[@]}" || die "settings not written (see above)"
    echo "settings for this run written (the player's file: $b)"
  fi
  cp "$CTRL_CFG" "$1/renderer.ini"
  ctrl_describe "$1"
}

game_cleanup() {   # EXIT trap of bench/run.sh: wait for the game to close, then the player's file back
  [ -f "$CTRL_PENDING" ] || return 0
  for _ in $(seq 30); do pgrep -f "$GAME_PROC" >/dev/null || break; sleep 1; done
  ctrl_restore || true
}

ctrl_look() {   # the screen now: its picture in $MENU_DIR/menu.png, its text in CTRL_TEXT
  [ -n "${MENU_REPLAY:-}" ] || "$ROOT/tools/shot.sh" "$MENU_DIR/menu.png" >/dev/null || return 1
  CTRL_TEXT=$("$ROOT/tools/ocr.sh" "$MENU_DIR/menu.png")
}

# The main menu: CONTINUE and OPTIONS on screen; not the Photosensitivity Warning ("Return Continue"), the "press a
# key" notices or the loading screen's tips, which also say Continue.
ctrl_on_menu() {
  grep -qi "CONTINUE" <<<"$CTRL_TEXT" && grep -qi "OPTIONS" <<<"$CTRL_TEXT" &&
    ! grep -qiE "Photosensitivity|Cycle Tips|PRESS (ANY|SPACE|ENTER|START)" <<<"$CTRL_TEXT"
}

# Every key waits for OCR to confirm its screen (lib/menu.sh). Return is only sent to the main menu once it is
# recognised and to the loading screen while its tips still show, so nothing reaches the game world.
game_drive() {  # $1 run dir, $2 game pid
  local out=$1
  MENU_DIR=$out
  if [ -n "${CTRL_MANUAL:-}" ]; then
    echo "manual: load the save, then press $FRAMES_KEY when the scene is steady; the run ends when the log is written"
    return 0
  fi
  for _ in $(seq 90); do   # logos and notices first, then the main menu
    ctrl_look && ctrl_on_menu && break
    [ -n "${MENU_REPLAY:-}" ] && break
    # Agreements and sign-ins need a person: never answered here.
    grep -qiE "EULA|terms of|I agree|licen[cs]e|privacy|sign in|log in" <<<"$CTRL_TEXT" &&
      { echo "a screen that needs a person (agreement or sign-in): see menu.png"; kill "$2"; return 1; }
    # The Photosensitivity Warning and the save-icon notice ("... being saved", both "[Return] Continue"), the title
    # screen ("Press [Return] to Start") and "press a key" prompts get Return.
    grep -qiE "Photosensitivity|being saved|PRESS (ANY|SPACE|ENTER|START)|TO START" <<<"$CTRL_TEXT" && menu_send key "Return~0.2"
    sleep 4
  done
  ctrl_on_menu || { echo "main menu never showed"; kill "$2"; return 1; }
  menu_pause 5                                              # the menu ignores keys while it settles
  menu_send key "Return~0.2"                                # Continue: the newest save
  menu_wait load "Cycle Tips|LOADING" 10 3 || { kill "$2"; return 1; }   # the loading screen has to follow
  for _ in $(seq 90); do   # its Continue prompt (bottom right) takes Return once the load is done
    screen_has load "Cycle Tips" || break
    [ -n "${MENU_REPLAY:-}" ] && break
    menu_send key "Return~0.2"; menu_pause 3
    menu_send key "space~0.2"; menu_pause 3
  done
  screen_has load "Cycle Tips" && { echo "the loading screen never ended"; kill "$2"; return 1; }
  menu_pause 25                                             # streaming and the camera settle
  frames_start
  menu_pause 8
  [ -n "${MENU_REPLAY:-}" ] || "$ROOT/tools/shot.sh" "$out/scene.png" >/dev/null   # the scene being measured
}

game_collect() {  # $1 run dir: the player's settings back; the result is the frame log
  game_cleanup
  compgen -G "$1/frames/*_summary.csv" >/dev/null
}
