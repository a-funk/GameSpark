# shellcheck shell=bash disable=SC2034  # variables are read by bench/run.sh
# skate. (EA / Full Circle, Frostbite, DirectX 12 via VKD3D-Proton). Sourced by bench/run.sh.
#
# THIS GAME PROBABLY DOES NOT START UNDER PROTON. EA's EA Javelin anti-cheat has no Linux support (EA: no Linux, Proton or
# Steam Deck), and the game has never been launched on this Spark. A run needs SKATE_TRY=1, so that nobody starts the
# anti-cheat's installer by accident; read profiles/settings/3354750/apply.sh first. Steam has a 3 GB update waiting and the
# game wants an EA account sign-in, which no script here does: a person at the TV signs in, or the run stops.
# If it does start: no menu drive (nobody has seen its menus). The operator picks a candidate in the menus
# (profiles/settings/3354750/candidates.sh: A, B, C), brings up a skate park or street spot, and starts the log with
# python3 -I tools/xinput.py key Shift_R+Scroll_Lock~0.3 ; the run ends when MangoHud has written FRAMES seconds.
# Measure the same spot, the same camera and the same minute of standing still for every candidate.
# Env: SKATE_TRY=1 (required), FRAMES (default 60), FRAMES_DELAY (default key).
APPID=3354750
GAME_NAME="skate."
GAME_API="DirectX 12 (VKD3D-Proton)"
GAME_EXE='Skate/Skate.exe'   # under steamapps/common (64-bit)
GAME_PROC='^[A-Z]:.*\\Skate\.exe'
LAUNCH_ARGS=''
LAUNCH_WAIT=${LAUNCH_WAIT:-900}   # the anti-cheat's installer and an update come first
: "${FRAMES:=60}" "${FRAMES_DELAY:=key}"
# shellcheck source=lib/menu.sh
. "$ROOT/lib/menu.sh"

game_prepare() {   # $1 run dir
  [ -n "${SKATE_TRY:-}" ] || die "skate. is blocked on Linux by EA Javelin anti-cheat (profiles/settings/3354750/apply.sh): SKATE_TRY=1 to try one launch"
  echo "skate.: first launches run the anti-cheat installer; a person must handle any EA sign-in" > "$1/skate.note"
}

game_drive() {   # $1 run dir, $2 game pid: nothing is driven; say so and wait for the operator
  echo "manual: choose a candidate in the menus, bring up the spot, then press $FRAMES_KEY; the run ends when the log is written"
}
