#!/bin/bash
# Divinity: Original Sin 2 - Definitive Edition (435150): graphics settings in graphicSettings.lsx (Proton prefix,
# Documents/Larian Studios/Divinity Original Sin 2 Definitive Edition/). The file reads CurrentSettings=Ultra with
# ScreenWidth=0 and ScreenHeight=0 (the game's automatic size, not a 1080p leftover), so the game may already render at
# 4K: candidate A makes 3840x2160 explicit rather than changing anything the player chose.
# Usage: profiles/settings/435150/apply.sh A|B|show|revert   (the candidates are in candidates.sh)
#   A  ScreenWidth=3840, ScreenHeight=2160. Fullscreen=1 (exclusive), VSync=1 and the Ultra values stay as they are.
#   B  A + SSAOEnabled=0 + GodRaysEnabled=0 (screen-space occlusion and light shafts: the usual costliest effects per
#      pixel at 4K; not measured on this unit).
# Refuses to write while the game runs. Backups: profiles/settings/lib.sh (SG_DATA/backups/435150/).
# Env: DOS2_CFG=PATH points at another file (tests only).
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
# shellcheck source=profiles/settings/lib.sh
. "$ROOT/profiles/settings/lib.sh"
# shellcheck source=lib/env.sh
. "$ROOT/lib/env.sh"
# shellcheck source=profiles/settings/435150/candidates.sh
. "$ROOT/profiles/settings/435150/candidates.sh"
set -u
APPID=435150
CFG=${DOS2_CFG:-$(compat_user "$APPID")/Documents/Larian Studios/Divinity Original Sin 2 Definitive Edition/graphicSettings.lsx}

running() { pgrep -f "[S]teamLaunch AppId=$APPID " >/dev/null || pgrep -f '[E]oCApp\.exe' >/dev/null; }
show() {
  python3 -I "$ROOT/profiles/settings/lsx_set.py" "$CFG" |
    grep -E '^(CurrentSettings|ScreenWidth|ScreenHeight|Fullscreen|FakeFullscreenEnabled|VSync|AntiAliasing|TextureFiltering|SSAOEnabled|GodRaysEnabled|DOFEnabled) = '
}

apply() {   # A|B
  local -a keys
  case $1 in A) keys=("${DOS2_A[@]}") ;; B) keys=("${DOS2_B[@]}") ;; esac
  [ -f "$CFG" ] || die "no $CFG: launch the game once first"
  running && die "Divinity: Original Sin 2 is running: its settings stay as they are"
  sg_backup "$APPID" "$CFG" "apply $1" >/dev/null || die "backup failed"
  python3 -I "$ROOT/profiles/settings/lsx_set.py" "$CFG" "${keys[@]}" || die "nothing written (the file is unchanged)"
  show
}

revert() {
  running && die "Divinity: Original Sin 2 is running: its settings stay as they are"
  sg_revert "$APPID" "$CFG" && show
}

case ${1:-} in
  A|B) apply "$1" ;;
  revert) revert ;;
  show) show ;;
  *) echo "usage: $0 A|B|show|revert" >&2; exit 2 ;;
esac
