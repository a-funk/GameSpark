#!/bin/bash
# Change a game's Steam settings: close Steam, edit its config, restart Steam: in Big Picture, or silently when the
# SparkHome kiosk is the TV's front end (it starts games itself, and Big Picture would cover it).
# Usage: tools/steam-config.sh launch-options APPID "OPTIONS"      e.g. 1091500 "PROTON_ENABLE_NVAPI=1 %command%"
#        tools/steam-config.sh launch-options profiled             every game with a profiles/launch/<appid>.env starts
#                                                                  through tools/launch.sh, however it is launched
#        tools/steam-config.sh compat-tool    APPID TOOL           e.g. 391220 proton_experimental (forces the
#                                                                  Windows build of games that also ship for Linux)
# Launch options are per Steam account: every account on this machine gets them.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); . "$ROOT/lib/env.sh"
WHAT=${1:?launch-options|compat-tool}; APP=${2:?appid}
if [ "$APP" = profiled ]; then
  [ "$WHAT" = launch-options ] || die "profiled only applies to launch-options"
  APP=$(cd "$ROOT/profiles/launch" && ls -- *.env | sed 's/\.env$//' | paste -sd, -); VAL="$ROOT/tools/launch.sh %command%"
else
  VAL=${3?value}
fi
case "$WHAT" in
  launch-options) CFGS=("$STEAM_ROOT"/userdata/*/config/localconfig.vdf) ;;   # per account: set every account's
  compat-tool)    CFGS=("$STEAM_ROOT/config/config.vdf") ;;
  *) die "unknown setting $WHAT" ;;
esac
[ -f "${CFGS[0]}" ] || die "Steam config not found (${CFGS[0]}); sign in to Steam once first"
SP=$(pgrep -f "[u]buntu12_32/steam " | head -1)
if [ -n "$SP" ]; then
  steam_cmd -shutdown
  for _ in $(seq 120); do kill -0 "$SP" 2>/dev/null || break; sleep 1; done
  kill -0 "$SP" 2>/dev/null && die "Steam did not exit"
fi
rc=0
for c in "${CFGS[@]}"; do python3 -I "$ROOT/tools/steamcfg.py" "$WHAT" "$c" "$APP" "$VAL" || rc=1; done
if pgrep -f "[-]-class=SparkHome" >/dev/null; then
  steam_start -silent
else
  "$ROOT/tools/steam-console.sh"
fi
exit $rc
