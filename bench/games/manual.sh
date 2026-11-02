# shellcheck shell=bash disable=SC2034  # variables are read by bench/run.sh
# Any game, measured where someone else brings it: MangoHud frame times (bench/run.sh FRAMES=SECS) of the scene on
# screen when the log starts. For games without an adapter of their own; sourced by bench/run.sh.
#
#   APPID=3669870 GAME_EXE='CONTROL Resonant/CONTROLResonant.exe' bench/run.sh manual control-4k-dlss-p
#
# The run launches the game; the operator (a person at the TV, or an agent with tools/xinput.py or tools/gamepad.py)
# brings up the scene, then starts the log with MangoHud's hotkey:
#   python3 -I tools/xinput.py key Shift_R+Scroll_Lock~0.3
# (or FRAMES_DELAY=SECS starts it that many seconds after the game's first frame). When the log is written the run
# kills the game, as every frame-capture adapter does: progress since the game's last save is lost.
# 32-bit games (PE32) cannot load the arm64 MangoHud; until an i386 build is in $SG_DATA/vklayers32, measure them with
# Wine's present rate instead: FRAMES= WINE_FPS=1 MANUAL_SECS=180 (the run kills the game after MANUAL_SECS; the record
# keeps the last WINE_FPS_LAST seconds, default 60, so bring the scene up before then).
# Env: APPID (required); GAME_EXE, the executable under steamapps/common (required: it names the process, and a 32-bit
#      exe gets the i386 layer); GAME_NAME, GAME_API for the record; FRAMES (default 60; empty for none), FRAMES_DELAY
#      (default key); MANUAL_SECS.
# The game must start through tools/launch.sh (a profiles/launch/<appid>.env), or run settings never reach it:
# bench/run.sh stops the run if Steam starts it some other way.
: "${APPID:?manual: set APPID}" "${GAME_EXE:?manual: set GAME_EXE (the exe under steamapps/common)}"
GAME_NAME=${GAME_NAME:-$(basename "$GAME_EXE" .exe)}
# Wine's process for the exe (Z:\...\Name.exe or C:\...), not Steam's reaper, whose command line names it too
GAME_PROC="^[A-Z]:.*[\\/]$(basename "$GAME_EXE" | sed 's/[][\.*^$+?(){}|]/\\&/g')"
LAUNCH_ARGS=${LAUNCH_ARGS:-}
LAUNCH_WAIT=${LAUNCH_WAIT:-600}
: "${FRAMES=60}" "${FRAMES_DELAY=key}"
# shellcheck source=lib/menu.sh
. "$ROOT/lib/menu.sh"   # FRAMES_KEY, the hotkey bench/run.sh binds for FRAMES_DELAY=key

if [ -n "${MANUAL_SECS:-}" ]; then
  game_drive() {  # $1 run dir, $2 game pid: a run without a frame log ends here
    sleep "$MANUAL_SECS"
    date +%s > "$1/bench_end"
    kill "$2"
  }
fi
