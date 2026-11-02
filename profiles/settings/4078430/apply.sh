#!/bin/bash
# STAR WARS: Galactic Racer (4078430): the game's graphics settings, GameUserSettings.ini (CRLF line ends) in its Proton
# prefix: AppData/Local/StarWarsGalacticRacer/Saved/Config/Windows/. Found 2026-10-13: 2560x1440 exclusive fullscreen
# that the TV scales to 4K, DLSS Super Resolution Performance (1280x720 inside), frame generation off, Reflex on, cap 60;
# 61-67 fps in the Landspeeder Ace race with the launch profile (60.8 on the 4K desktop: 1% low 26.6, 12 frames over
# 50 ms). That file is deliberate, not a 1080p leftover, so nothing here is applied until a run says it is better.
# Usage: profiles/settings/4078430/apply.sh A|B|C|U|P0|show|revert   (the candidates are in candidates.sh)
#   U  3840x2160 (the TV's own mode, no scaling) with DLSS Ultra Performance: the same 1280x720 inside as today,
#      reconstructed at 4K (preset L, the mode's default), native 4K HUD; today's groups. Isolates what the 4K output
#      costs (DLSS and the post effects work on 8.3 MP instead of 3.7 MP).
#   A  recommended: U with global illumination, reflections and post processing one step down (1 = Medium). In the
#      4K baseline's slow seconds (50-54 fps) the GPU was 88% busy at 62-65 W against 76% in its fast ones, and
#      Ultra Performance did not speed the old runs up: the cost that matters does not shrink with the render size
#      (Lumen's gather and reflections, the post effects), so A pays for the 4K output there.
#   B  more fidelity: 3840x2160 with DLSS Performance (1920x1080 inside, preset M), today's groups, texture quality 3.
#   C  more fps: A plus view distance 0, effects 0, foliage 1, shading 1 (the CPU gains too).
#   P0 the file as found, to measure the old settings again.
# None of these touches the hitches: in every run on record the same frames stall at the same moments of the race
# (1.5, 5, 7.5, 9.8, 21 s: first-time work and the scripted crash), at 480p inside as at 720p, so the 1% low is theirs.
# Every candidate keeps Nanite, ray tracing and frame generation as the launch profile has them (Engine.ini: Nanite
# off; DLSS frame generation off after the GPU hangs of docs/FINDINGS.md). DLSS modes: DLAA, UltraQuality, Quality,
# Balanced, Performance, UltraPerformance (enum names in the exe).
# Refuses to write while the game runs. Backups: profiles/settings/lib.sh (SG_DATA/backups/4078430/).
# Env: GR_INI=PATH points at another file (tests only).
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
# shellcheck source=profiles/settings/lib.sh
. "$ROOT/profiles/settings/lib.sh"
# shellcheck source=lib/env.sh
. "$ROOT/lib/env.sh"
# shellcheck source=profiles/settings/4078430/candidates.sh
. "$ROOT/profiles/settings/4078430/candidates.sh"
set -u
APPID=4078430
CFG=${GR_INI:-$(compat_user "$APPID")/AppData/Local/StarWarsGalacticRacer/Saved/Config/Windows/GameUserSettings.ini}

running() { pgrep -f "[S]teamLaunch AppId=$APPID " >/dev/null || pgrep -f '[S]WGR-Win64-Shipping\.exe' >/dev/null; }
show() {
  tr -d '\r' < "$CFG" | grep -E '^(ResolutionSize[XY]|LastUserConfirmedResolutionSize[XY]|FullscreenMode|FrameRateLimit|bIsVSyncEnabled|Current3PAAUMode|DLSSSuperResolutionMode|DLSSFrameGenerationMode|CurrentFrameGenerationProvider|bIsDLSSRayReconstructionEnabled|ReflexMode|bUseDynamicResolution|sg\.[A-Za-z]+|CustomScalabilityGroupSettings\[[0-9]+\])='
}

apply() {   # A|B|C|U|P0
  local -a keys
  case $1 in
    A) keys=("${GR_A[@]}") ;; B) keys=("${GR_B[@]}") ;; C) keys=("${GR_C[@]}") ;; U) keys=("${GR_U[@]}") ;;
    P0) keys=("${GR_P0[@]}") ;;
  esac
  [ -f "$CFG" ] || die "no $CFG: launch the game once first"
  running && die "Galactic Racer is running: its settings stay as they are"
  sg_backup "$APPID" "$CFG" "apply $1" >/dev/null || die "backup failed"
  python3 -I "$ROOT/profiles/settings/ini_set.py" "$CFG" "${keys[@]}" || die "nothing written (the file is unchanged)"
  show
}

revert() {
  running && die "Galactic Racer is running: its settings stay as they are"
  sg_revert "$APPID" "$CFG" && show
}

case ${1:-} in
  A|B|C|U|P0) apply "$1" ;;
  revert) revert ;;
  show) show ;;
  *) echo "usage: $0 A|B|C|U|P0|show|revert" >&2; exit 2 ;;
esac
