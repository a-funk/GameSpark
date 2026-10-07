#!/bin/bash
# Set a game's Steam launch options: close Steam, edit localconfig.vdf, restart Steam in Big Picture.
# Usage: tools/steam-launch-options.sh APPID "OPTIONS"     e.g. 1091500 "PROTON_ENABLE_NVAPI=1 %command%"
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); . "$ROOT/lib/env.sh"
APP=${1:?appid}; OPTS=${2?options}
SP=$(pgrep -f "[u]buntu12_32/steam " | head -1)
if [ -n "$SP" ]; then
  steam_cmd -shutdown
  for i in $(seq 120); do kill -0 "$SP" 2>/dev/null || break; sleep 1; done
  kill -0 "$SP" 2>/dev/null && die "Steam did not exit"
fi
CFG=$(ls "$STEAM_ROOT"/userdata/*/config/localconfig.vdf 2>/dev/null | head -1)
[ -n "$CFG" ] || die "no localconfig.vdf under $STEAM_ROOT/userdata (sign in to Steam once first)"
python3 -I "$ROOT/tools/set-launch-options.py" "$CFG" "$APP" "$OPTS"
"$ROOT/tools/steam-console.sh"
