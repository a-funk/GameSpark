# shellcheck shell=bash
# OCR-gated menu driving for game adapters (bench/games/*.sh). Every step names the text its screen must show, so a
# dropped keypress or an unexpected screen stops the run instead of sending keys blind (on RDR2's main menu a blind
# Return starts Story mode on the player's save).
#
#   MENU_DIR=$out                       screenshots land in $MENU_DIR/<name>.png (kept with the run)
#   menu_wait NAME REGEX TRIES SECS     poll until the screen matches REGEX (case-insensitive ERE)
#   menu_press NAME REGEX TRIES INPUT…  send INPUT (tools/xinput.py arguments), then expect REGEX; repeat up to
#                                       TRIES times, so only use TRIES > 1 for inputs that are safe to repeat
#   menu_send INPUT…                    send INPUT with no check (only where the previous step proved the screen)
#   menu_pause SECS                     sleep (skipped in replay)
#
# Replay: MENU_REPLAY=1 checks the PNGs already in $MENU_DIR and sends nothing (tests/menu-replay.sh).

screen_has() {  # NAME REGEX
  [ -n "${MENU_REPLAY:-}" ] || "$ROOT/tools/shot.sh" "$MENU_DIR/$1.png" >/dev/null || return 1
  "$ROOT/tools/ocr.sh" "$MENU_DIR/$1.png" | grep -qiE "$2"
}

menu_send() {
  if [ -n "${MENU_REPLAY:-}" ]; then echo "replay: would send $*"; else python3 -I "$ROOT/tools/xinput.py" "$@"; fi
}

menu_pause() { [ -n "${MENU_REPLAY:-}" ] || sleep "$1"; }

menu_wait() {  # NAME REGEX TRIES SECS
  for _ in $(seq "$3"); do
    screen_has "$1" "$2" && return 0
    [ -n "${MENU_REPLAY:-}" ] && break
    sleep "$4"
  done
  echo "screen '$1' never showed /$2/"; return 1
}

menu_press() {  # NAME REGEX TRIES INPUT...
  local name=$1 re=$2 tries=$3; shift 3
  for _ in $(seq "$tries"); do
    menu_send "$@"
    [ -n "${MENU_REPLAY:-}" ] || sleep 4
    screen_has "$name" "$re" && return 0
    [ -n "${MENU_REPLAY:-}" ] && break
  done
  echo "after '$*' the screen '$name' did not show /$re/"; return 1
}
