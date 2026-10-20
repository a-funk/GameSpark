#!/bin/bash
# The Witcher 3: Wild Hunt - Remastered (292030): the game's graphics settings, dx12user.settings in its Proton prefix
# (Documents/The Witcher 3/; CRLF line ends; the game is DirectX 12 only since patch 5.0). The file held 1920x1080 borderless
# (a 1920x1080 window in a corner of the 4K screen), the Ultra preset auto-detected on GB10, XeSS Auto, VSync on.
# At 1080p the game is CPU-bound at about 88 fps in Novigrad (with the shim, FINDINGS.md); at 4K the render size decides.
# Usage: profiles/settings/292030/apply.sh A|B|C|D|E|P0|show|revert   (the candidates are in candidates.sh)
#   A  recommended: 3840x2160 borderless, DLSS Performance (1920x1080 render), the Ultra settings stay, VSync on.
#   B  more fidelity: A with DLSS Quality (2560x1440 render).
#   C  more fps: A with the High preset's shadows (2048), terrain, water, foliage, grass, LOD, crowd and GTAO.
#   P0 the file as found at 4K: XeSS Auto, Ultra, to measure the old settings (XeSS runs its DP4a path on NVIDIA).
#   D  closest to 60 fps: C's detail with FSR Quality (2560x1440 render) and HairWorks off (A-C never ran DLSS).
#   E  DLSS: C's detail with XeSS Performance, which OptiScaler runs as DLSS Performance (CNN), HairWorks off.
# Whether DLSS really runs shows in a bench run's modules.txt (nvngx_dlss.dll mapped); with `ShouldRefetchUpscaler=false`
# the game does not re-detect the upscaler at start.
# Refuses to write while the game runs. Backups: profiles/settings/lib.sh (SG_DATA/backups/292030/).
# Env: W3_DX12_SETTINGS=PATH points at another file (tests only).
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
# shellcheck source=profiles/settings/lib.sh
. "$ROOT/profiles/settings/lib.sh"
# shellcheck source=lib/env.sh
. "$ROOT/lib/env.sh"
# shellcheck source=profiles/settings/292030/candidates.sh
. "$ROOT/profiles/settings/292030/candidates.sh"
set -u
APPID=292030
CFG=${W3_DX12_SETTINGS:-$(compat_user "$APPID")/Documents/The Witcher 3/dx12user.settings}
PENDING=$SG_DATA/launch/witcher3-candidate.pending

running() { pgrep -f "[S]teamLaunch AppId=$APPID " >/dev/null || pgrep -f '[w]itcher3\.exe' >/dev/null; }
show() {
  tr -d '\r' < "$CFG" | grep -E '^(Resolution|FullScreenMode|VSync|LimitFPS|AAMode|DLSSQuality|XESSQuality|FSR2Quality|DLSSGMode|EnableDLSSRR|CascadeShadowmapSize|GTAOQuality|GrassDensity|MaxVisibilityDepth|SpawnedLimit)='
}

apply() {   # A|B|C|P0
  local -a keys
  case $1 in A) keys=("${W3_A[@]}") ;; B) keys=("${W3_B[@]}") ;; C) keys=("${W3_C[@]}") ;; D) keys=("${W3_D[@]}") ;;
    E) keys=("${W3_E[@]}") ;; P0) keys=("${W3_P0[@]}") ;; esac
  [ -f "$CFG" ] || die "no $CFG: launch the game once first"
  running && die "The Witcher 3 is running: its settings stay as they are"
  [ -f "$PENDING" ] && die "a benchmark run's settings are still in place ($PENDING): bench/run.sh puts the player's file back"
  sg_backup "$APPID" "$CFG" "apply $1" >/dev/null || die "backup failed"
  python3 -I "$ROOT/profiles/settings/ini_set.py" "$CFG" "${keys[@]}" || die "nothing written (the file is unchanged)"
  show
}

revert() {
  running && die "The Witcher 3 is running: its settings stay as they are"
  [ -f "$PENDING" ] && die "a benchmark run's settings are still in place ($PENDING): bench/run.sh puts the player's file back"
  sg_revert "$APPID" "$CFG" && show
}

case ${1:-} in
  A|B|C|D|E|P0) apply "$1" ;;
  revert) revert ;;
  show) show ;;
  *) echo "usage: $0 A|B|C|D|E|P0|show|revert" >&2; exit 2 ;;
esac
