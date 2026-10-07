#!/bin/bash
# Console mode: start Steam (GAMESPARK_STEAM=snap|fex, see lib/env.sh) if needed, then open Big Picture on the TV.
# Use as a GNOME autostart entry (see README) or run by hand. Works from ssh too (display defaults in lib/env.sh).
ROOT=$(cd "$(dirname "$0")/.." && pwd); . "$ROOT/lib/env.sh"
steam_running || setsid -f $STEAM_START >/dev/null 2>&1 < /dev/null
for i in $(seq 180); do pgrep -f "[s]teamwebhelper" >/dev/null && [ -p "$STEAM_PIPE" ] && break; sleep 1; done
sleep 20   # Steam ignores pipe commands until "Loading user data" finishes
steam_cmd steam://open/bigpicture
