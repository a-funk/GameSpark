#!/bin/bash
# Cyberpunk 2077 (1091500): the game's graphics settings, UserSettings.json in its Proton prefix
# (AppData/Local/CD Projekt Red/Cyberpunk 2077/). The file had a 1920x1080 leftover: DLSS Quality, fog, clouds and SSR on
# Ultra (an upscaler plus SSR Ultra draws SSR in Psycho mode), no frame cap, VSync off. The game is CPU-bound at about 69 fps
# at 1080p (benchmark, FINDINGS.md), so at 4K the render size decides whether the GPU becomes the limit.
# Usage: profiles/settings/1091500/apply.sh A|B|C|P0|show|revert   (the candidates are in candidates.sh)
#   A  recommended: 3840x2160 borderless, DLSS Performance (transformer, 1920x1080 render), fog and clouds Medium, SSR High,
#      cascaded shadow resolution, AO and color precision Medium, decals High, crowd density Medium, frame cap 60.
#      Not changed: textures High, anisotropy 16, shadows' range, mirrors, LOD, motion blur and the other effects, VSync.
#   B  more fidelity: DLSS Balanced (about 2227x1253 render), fog, clouds High, SSR High, shadows, AO, decals, color High.
#   C  more fps: DLSS Performance, contact shadows off, shadows, mirrors, LOD, decals Medium, fog Low, SSR Medium, AO Low,
#      crowd density Low.
#   P0 the file as found on 2026-10-13 (DLSS Quality, fog and clouds Ultra, SSR Ultra) at 4K, to measure the old settings.
# Frame generation, ray tracing and DLSS Ray Reconstruction stay off in all four: the TV is 60 Hz, and with VSync a frame
# generator holds the game to half the refresh rate (30 fps rendered); ray tracing is out of reach at 4K here.
# VSync is not touched: its "On" token is unknown (only ...QualitySetting-Off is in the file), so the frame cap stands in.
# Refuses to write while the game runs. Backups: profiles/settings/lib.sh (SG_DATA/backups/1091500/).
# Env: CP_USERSETTINGS=PATH points at another file (tests only).
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
# shellcheck source=profiles/settings/lib.sh
. "$ROOT/profiles/settings/lib.sh"
# shellcheck source=lib/env.sh
. "$ROOT/lib/env.sh"
# shellcheck source=profiles/settings/1091500/candidates.sh
. "$ROOT/profiles/settings/1091500/candidates.sh"
set -u
APPID=1091500
CFG=${CP_USERSETTINGS:-$(compat_user "$APPID")/AppData/Local/CD Projekt Red/Cyberpunk 2077/UserSettings.json}
PENDING=$SG_DATA/launch/cyberpunk-candidate.pending

running() { pgrep -f "[S]teamLaunch AppId=$APPID " >/dev/null || pgrep -f '[C]yberpunk2077\.exe' >/dev/null; }
tool() { CP_USERSETTINGS=$CFG python3 -I "$ROOT/bench/cyberpunk2077_settings.py" "$@"; }

apply() {   # A|B|C|P0
  local -a keys
  case $1 in A) keys=("${CP_A[@]}") ;; B) keys=("${CP_B[@]}") ;; C) keys=("${CP_C[@]}") ;; P0) keys=("${CP_P0[@]}") ;; esac
  [ -f "$CFG" ] || die "no $CFG: launch the game once first"
  running && die "Cyberpunk 2077 is running: its settings stay as they are"
  [ -f "$PENDING" ] && die "a benchmark run's settings are still in place ($PENDING): bench/run.sh puts the player's file back"
  sg_backup "$APPID" "$CFG" "apply $1" >/dev/null || die "backup failed"
  tool set "${keys[@]}" >/dev/null || die "nothing written (the file is unchanged)"
  tool show
}

revert() {
  running && die "Cyberpunk 2077 is running: its settings stay as they are"
  [ -f "$PENDING" ] && die "a benchmark run's settings are still in place ($PENDING): bench/run.sh puts the player's file back"
  sg_revert "$APPID" "$CFG" && tool show
}

case ${1:-} in
  A|B|C|P0) apply "$1" ;;
  revert) revert ;;
  show) tool show ;;
  *) echo "usage: $0 A|B|C|P0|show|revert" >&2; exit 2 ;;
esac
