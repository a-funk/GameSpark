#!/bin/bash
# Change a game's Steam settings: close Steam, edit its config, restart Steam in Big Picture.
# Usage: tools/steam-config.sh launch-options APPID "OPTIONS"      e.g. 1091500 "PROTON_ENABLE_NVAPI=1 %command%"
#        tools/steam-config.sh compat-tool    APPID TOOL           e.g. 391220 proton_experimental (forces the
#                                                                  Windows build of games that also ship for Linux)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); . "$ROOT/lib/env.sh"
WHAT=${1:?launch-options|compat-tool}; APP=${2:?appid}; VAL=${3?value}
case "$WHAT" in
  launch-options) CFG=$(ls "$STEAM_ROOT"/userdata/*/config/localconfig.vdf 2>/dev/null | head -1) ;;
  compat-tool)    CFG=$STEAM_ROOT/config/config.vdf ;;
  *) die "unknown setting $WHAT" ;;
esac
[ -f "$CFG" ] || die "Steam config not found ($CFG); sign in to Steam once first"
SP=$(pgrep -f "[u]buntu12_32/steam " | head -1)
if [ -n "$SP" ]; then
  steam_cmd -shutdown
  for _ in $(seq 120); do kill -0 "$SP" 2>/dev/null || break; sleep 1; done
  kill -0 "$SP" 2>/dev/null && die "Steam did not exit"
fi
python3 -I "$ROOT/tools/steamcfg.py" "$WHAT" "$CFG" "$APP" "$VAL"
"$ROOT/tools/steam-console.sh"
