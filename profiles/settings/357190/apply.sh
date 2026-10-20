#!/bin/bash
# Ultimate Marvel vs. Capcom 3 (357190): the game's graphics settings, config.ini in its Proton prefix (CRLF line ends).
# Usage: profiles/settings/357190/apply.sh A|B|show|revert
#   A  4K: Resolution=3840x2160 (the file had a 1920x1080 leftover). FullScreen, VSYNC, RefreshRate and the rest stay as
#      they were. The desktop already runs 3840x2160 @ 59.94 Hz, so the game sets no new mode.
#   B  A + AntiAlias=MSAA4X (4x MSAA). The enum is ANTIALIAS_MSAA4X in umvc3.exe; that the file takes the bare token
#      MSAA4X is not confirmed. The game rewrites config.ini when it exits: if AntiAlias comes back as NONE after a run,
#      it did not take the token (try MSAA2X, or set AA in the Options menu and diff the file).
# Refuses to write while the game runs. Backups: profiles/settings/lib.sh (SG_DATA/backups/357190/).
# Env: MVC3_CONFIG=PATH points at another file (tests only).
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
# shellcheck source=profiles/settings/lib.sh
. "$ROOT/profiles/settings/lib.sh"
# shellcheck source=lib/env.sh
. "$ROOT/lib/env.sh"
set -u
APPID=357190
CFG=${MVC3_CONFIG:-$(compat_user "$APPID")/AppData/Local/CAPCOM/ULTIMATE MARVEL VS. CAPCOM 3/config.ini}

running() { pgrep -f "[S]teamLaunch AppId=$APPID " >/dev/null || pgrep -f '[u]mvc3\.exe' >/dev/null; }
show() { tr -d '\r' < "$CFG" | grep -E '^(VSYNC|Resolution|RefreshRate|FullScreen|AntiAlias|AltAntiAlias|TextureDetail|TextureMipLimite)='; }

apply() {   # A|B
  local -a keys=(Resolution=3840x2160)
  [ "$1" = B ] && keys+=(AntiAlias=MSAA4X)
  [ -f "$CFG" ] || die "no $CFG: launch the game once first"
  running && die "Ultimate Marvel vs. Capcom 3 is running: its settings stay as they are"
  sg_backup "$APPID" "$CFG" "apply $1" >/dev/null || die "backup failed"
  python3 -I "$ROOT/profiles/settings/ini_set.py" "$CFG" "${keys[@]}" || die "nothing written (the file is unchanged)"
  show
}

revert() {
  running && die "Ultimate Marvel vs. Capcom 3 is running: its settings stay as they are"
  sg_revert "$APPID" "$CFG" && show
}

case ${1:-} in
  A|B) apply "$1" ;;
  revert) revert ;;
  show) show ;;
  *) echo "usage: $0 A|B|show|revert" >&2; exit 2 ;;
esac
