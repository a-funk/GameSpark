#!/bin/bash
# Red Dead Redemption 2 (1174180): the game's graphics settings, Documents/Rockstar Games/Red Dead Redemption 2/Settings/
# system.xml in its Proton prefix, and the Wine virtual desktop the Rockstar launcher needs (user.reg, Explorer\Desktops
# Default), which has to be as large as the game's window. The file had a 1920x1080 leftover (and the desktop 1920x1080, so a
# 4K game would sit in a corner), the game's "Safe" config (everything Low, textures Ultra), DLSS off, VSync off.
# At 1080p the game is CPU-limited at about 75 fps (FINDINGS.md); at 4K without an upscaler the GPU would be the limit.
# Usage: profiles/settings/1174180/apply.sh A|B|C|P0|show|revert   (the candidates are in candidates.sh)
#   A  recommended: 3840x2160 borderless, DLSS Quality (2560x1440 render), 16x anisotropic filtering, TAA High, VSync on;
#      the Safe qualities stay (expected: still CPU-limited, so about the 1080p rate; not measured).
#   B  more fidelity: A with the 23 Safe qualities raised to Medium.
#   C  more fps: A with DLSS Performance (1920x1080 render).
#   P0 the file as found at 4K: Safe, DLSS off (native 4K), TAA Medium, no anisotropic filtering, VSync off.
# DLSS needs the game to see NVAPI and NGX (Proton enables NVAPI by default); the game shows "Reflex" in its menu, so
# NVAPI works. Whether DLSS really runs shows in a bench run's modules.txt (nvngx_dlss.dll mapped).
# The Wine virtual desktop is set to the candidates' size, 3840x2160 (the adapter keeps it at the display's size).
# revert: system.xml from its first backup, the virtual desktop back to 1920x1080 (the rest of user.reg is not touched).
# Refuses to write while the game or its launcher runs. Backups: profiles/settings/lib.sh (SG_DATA/backups/1174180/).
# Env: RDR2_SYSTEM_XML=PATH and RDR2_PREFIX=DIR point at other files (tests only).
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
# shellcheck source=profiles/settings/lib.sh
. "$ROOT/profiles/settings/lib.sh"
# shellcheck source=lib/env.sh
. "$ROOT/lib/env.sh"
# shellcheck source=profiles/settings/1174180/candidates.sh
. "$ROOT/profiles/settings/1174180/candidates.sh"
set -u
APPID=1174180
PFX=${RDR2_PREFIX:-$STEAM_ROOT/steamapps/compatdata/$APPID/pfx}
CFG=${RDR2_SYSTEM_XML:-$PFX/drive_c/users/steamuser/Documents/Rockstar Games/Red Dead Redemption 2/Settings/system.xml}
PENDING=$SG_DATA/launch/rdr2-candidate.pending

running() {
  pgrep -f "[S]teamLaunch AppId=$APPID " >/dev/null || pgrep -f '^[A-Z]:.*(\\RDR2\.exe|Rockstar Games|PlayRDR2)' >/dev/null
}
desktop() {   # the Wine virtual desktop's size in user.reg
  awk '/^\[Software\\\\Wine\\\\Explorer\\\\Desktops\]/ { on = 1; next } /^\[/ { on = 0 }
    on && /^"Default"=/ { gsub(/^"Default"="|"$/, ""); print; exit }' "$PFX/user.reg"
}
set_desktop() {   # WxH
  [ "$(desktop)" = "$1" ] && return 0
  sg_backup "$APPID" "$PFX/user.reg" "wine virtual desktop $(desktop) -> $1" >/dev/null || return 1
  python3 -I "$ROOT/tools/winereg.py" "$PFX" 'Software\Wine\Explorer' Desktop=Default >/dev/null &&
    python3 -I "$ROOT/tools/winereg.py" "$PFX" 'Software\Wine\Explorer\Desktops' "Default=$1" >/dev/null
}
show() {
  python3 -I "$ROOT/profiles/settings/xml_set.py" "$CFG" |
    grep -E '^(screenWidth|screenHeight|windowed|vSync|API|dlssIndex|dlssQuality|dlssSharpen|fsr2Index|taa|anisotropicFiltering|textureQuality|shadowQuality|reflectionQuality|waterQuality|volumetricsQuality|lightingQuality|scalingMode|msaa) = '
  echo "wine virtual desktop = $(desktop)"
}

apply() {   # A|B|C|P0
  local -a keys
  case $1 in A) keys=("${RDR2_A[@]}") ;; B) keys=("${RDR2_B[@]}") ;; C) keys=("${RDR2_C[@]}") ;; P0) keys=("${RDR2_P0[@]}") ;; esac
  [ -f "$CFG" ] || die "no $CFG: launch the game once first"
  running && die "Red Dead Redemption 2 (or its launcher) is running: its settings stay as they are"
  [ -f "$PENDING" ] && die "a benchmark run's settings are still in place ($PENDING): bench/run.sh puts the player's file back"
  sg_backup "$APPID" "$CFG" "apply $1" >/dev/null || die "backup failed"
  python3 -I "$ROOT/profiles/settings/xml_set.py" "$CFG" "${keys[@]}" || die "nothing written (the file is unchanged)"
  set_desktop 3840x2160 || die "the Wine virtual desktop was not changed (see above)"
  show
}

revert() {
  running && die "Red Dead Redemption 2 (or its launcher) is running: its settings stay as they are"
  [ -f "$PENDING" ] && die "a benchmark run's settings are still in place ($PENDING): bench/run.sh puts the player's file back"
  sg_revert "$APPID" "$CFG" || exit 1
  set_desktop "$RDR2_DESKTOP_ORIG" || die "the Wine virtual desktop was not changed (see above)"
  show
}

case ${1:-} in
  A|B|C|P0) apply "$1" ;;
  revert) revert ;;
  show) show ;;
  *) echo "usage: $0 A|B|C|P0|show|revert" >&2; exit 2 ;;
esac
