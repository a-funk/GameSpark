#!/bin/bash
# CONTROL Resonant (3669870): the game's graphics settings, renderer.ini (JSON) in its Proton prefix:
# AppData/Local/Remedy/CONTROLResonant/. At 4K the game is GPU-bound (35 fps with DLSS Quality, GPU 94% busy, CPU 29%).
# On a 3840x2160 output the render size is the DLSS mode: 2560x1440 Quality, 1920x1080 Performance, 1280x720 Ultra
# Performance. Frame generation, ray tracing and DLSS Ray Reconstruction stay off, DLSS stays the transformer model.
# Usage: profiles/settings/3669870/apply.sh A|B|C|D|P0|show|revert   (the candidates are in candidates.sh)
#   A  recommended: render 1920x1080 (DLSS Performance), SDF reflections off (m_eSDFQuality=0), frame cap 60.
#      Everything else in the file (shadows, volumetrics, textures, GI, SSR, effects) stays as the player set it.
#   B  more fidelity: render 2560x1440 (DLSS Quality, as before), SDF reflections Medium (1), cap 60.
#   C  more fps: render 1280x720 (DLSS Ultra Performance), SDF off, GI 1, SSR 1, motion blur off, cap 60.
#   P0 the file as found on 2026-10-13 (Quality, SDF 2, cap 360), to measure the old settings again.
# What the numbers are: 0 is the lowest step of each quality setting. The levels' names (Low/Medium/High/Ultra) are not
# stored in the file; the guides that name them call SDF reflections the setting that costs the most for the least
# visible gain without ray tracing. A's expected cost: 56% of B's render pixels and no SDF, so roughly 50-58 fps
# against 35 (not measured). The game rewrites renderer.ini at launch and exit: after a run, `show` says what it kept.
# Refuses to write while the game runs. Backups: profiles/settings/lib.sh (SG_DATA/backups/3669870/).
# Env: CTRL_INI=PATH points at another file (tests only).
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
# shellcheck source=profiles/settings/lib.sh
. "$ROOT/profiles/settings/lib.sh"
# shellcheck source=lib/env.sh
. "$ROOT/lib/env.sh"
# shellcheck source=profiles/settings/3669870/candidates.sh
. "$ROOT/profiles/settings/3669870/candidates.sh"
set -u
APPID=3669870
CFG=${CTRL_INI:-$(compat_user "$APPID")/AppData/Local/Remedy/CONTROLResonant/renderer.ini}

running() { pgrep -f "[S]teamLaunch AppId=$APPID " >/dev/null || pgrep -f '[C]ONTROLResonant\.exe' >/dev/null; }
show() {
  python3 -I "$ROOT/profiles/settings/flatjson_set.py" "$CFG" |
    grep -E '^(m_iOutputResolution[XY]|m_iRenderResolution[XY]|m_eWindowMode|m_eVSync|m_maxFrameRate|m_eSSAAMethod|m_bDLSSLegacy|m_DLSSRR|m_eDLSSFGMode|m_eFSRFGMode|m_eSDFQuality|m_eGIQuality|m_eSSRQuality|m_eMotionBlur|m_eHighQualityPost|m_eRTReflectionQuality|m_ePTQuality) = '
}

apply() {   # A|B|C|D|P0
  local -a keys
  case $1 in A) keys=("${CTRL_A[@]}") ;; B) keys=("${CTRL_B[@]}") ;; C) keys=("${CTRL_C[@]}") ;; D) keys=("${CTRL_D[@]}") ;; P0) keys=("${CTRL_P0[@]}") ;; esac
  [ -f "$CFG" ] || die "no $CFG: launch the game once first"
  running && die "CONTROL Resonant is running: its settings stay as they are"
  sg_backup "$APPID" "$CFG" "apply $1" >/dev/null || die "backup failed"
  python3 -I "$ROOT/profiles/settings/flatjson_set.py" "$CFG" "${keys[@]}" || die "nothing written (the file is unchanged)"
  show
}

revert() {
  running && die "CONTROL Resonant is running: its settings stay as they are"
  sg_revert "$APPID" "$CFG" && show
}

case ${1:-} in
  A|B|C|D|P0) apply "$1" ;;
  revert) revert ;;
  show) show ;;
  *) echo "usage: $0 A|B|C|D|P0|show|revert" >&2; exit 2 ;;
esac
