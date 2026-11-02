#!/bin/bash
# Rise of the Tomb Raider (391220): the game's settings are registry values in its Proton prefix (user.reg, key
# HKCU\Software\Crystal Dynamics\Rise of the Tomb Raider\Graphics). Found 2026-10-13: FullscreenWidth/Height 1920x1080
# (a leftover from before the TV ran 4K), borderless fullscreen, DirectX 12, DLSS off, FXAA, VSync off (a side effect of
# the benchmark runs), the game's first-run High values otherwise. 131 fps at 1080p, CPU-bound: the GPU was 65% busy.
# Usage: profiles/settings/391220/apply.sh A|B|C|P0|N4K|show|revert   (the candidates are in candidates.sh)
#   A  recommended: 3840x2160 borderless, DLSS Quality (2560x1440 inside; the game ships DLSS 2.3.2), film grain and
#      depth of field off (they run before DLSS), VSync on for the 60 Hz TV. Expect about 90-100 fps unlocked, so a
#      locked 60 (the GPU needs 4x the pixels of 1080p but DLSS renders 1.8x; not measured).
#   B  more fidelity: A with texture, shadow and level-of-detail quality 3 (Very High) and texture filtering 4 (16x).
#      The value numbers assume the menus' lists run from 0 = lowest (Low ... Very High; 1x ... 16x); check Options >
#      Graphics after the first start. Expect 80-95 fps (not measured).
#   C  more fps: DLSS Performance (1920x1080 inside), the rest as A. Expect about the 1080p figure, 120-130 fps, the
#      CPU limit; only useful on a display faster than 60 Hz.
#   P0 the key as found (1080p, DLSS off), N4K native 4K with no upscaler (the 4K baseline: about 50 fps expected).
# The DLSS value is the position in the game's own list (Off, Ultra Performance, Performance, Balanced, Quality), read
# from the order of its menu strings in ROTTR.exe, not seen on screen: confirm in Options > Graphics after the first
# start (or with DXVK_NVAPI_SET_NGX_DEBUG_OPTIONS=DLSSIndicator=1024).
# Refuses to write while the game runs (Wine rewrites user.reg when it exits). Backups: profiles/settings/lib.sh
# (SG_DATA/backups/391220/; `revert` puts the whole user.reg back as it was before the first change).
# Env: ROTTR_PFX=PATH points at another prefix (tests only).
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
# shellcheck source=profiles/settings/lib.sh
. "$ROOT/profiles/settings/lib.sh"
# shellcheck source=lib/env.sh
. "$ROOT/lib/env.sh"
# shellcheck source=profiles/settings/391220/candidates.sh
. "$ROOT/profiles/settings/391220/candidates.sh"
set -u
APPID=391220
PFX=${ROTTR_PFX:-$STEAM_ROOT/steamapps/compatdata/$APPID/pfx}
REG=$PFX/user.reg

running() { pgrep -f "[S]teamLaunch AppId=$APPID " >/dev/null || pgrep -f '[R]OTTR\.exe' >/dev/null; }
show() {
  python3 -I - "$REG" "$ROTTR_KEY" <<'PY'
import re
import sys

path, key = sys.argv[1], sys.argv[2]
text = open(path, encoding='utf-8', errors='replace').read()
head = '[' + key.replace(chr(92), chr(92) * 2) + ']'
start = text.find(head)
if start < 0:
    sys.exit('no key ' + key)
end = text.find('\n[', start + 1)
want = ('FullscreenWidth', 'FullscreenHeight', 'Fullscreen', 'ExclusiveFullscreen', 'EnableDX12', 'DLSS', 'FXAA', 'SMAA',
        'SSAAQuality', 'VSync', 'FilmGrain', 'DOFQuality', 'TextureQuality', 'ShadowQuality', 'LevelOfDetail',
        'TextureFiltering', 'AmbientOcclusionQuality', 'ResolutionModifier')
for m in re.finditer(r'^"([^"]+)"=dword:([0-9a-f]{8})\s*$', text[start:end if end > 0 else len(text)], re.M):
    if m.group(1) in want:
        print('%s = %d' % (m.group(1), int(m.group(2), 16)))
PY
}

apply() {   # A|B|C|P0|N4K
  local -a keys
  case $1 in
    A) keys=("${ROTTR_A[@]}") ;; B) keys=("${ROTTR_B[@]}") ;; C) keys=("${ROTTR_C[@]}") ;;
    P0) keys=("${ROTTR_P0[@]}") ;; N4K) keys=("${ROTTR_N4K[@]}") ;;
  esac
  [ -f "$REG" ] || die "no $REG: launch the game once first"
  running && die "Rise of the Tomb Raider is running: its settings stay as they are"
  sg_backup "$APPID" "$REG" "apply $1" >/dev/null || die "backup failed"
  python3 -I "$ROOT/tools/winereg.py" "$PFX" "$ROTTR_KEY" "${keys[@]}" >/dev/null || die "nothing written"
  show
}

revert() {
  running && die "Rise of the Tomb Raider is running: its settings stay as they are"
  sg_revert "$APPID" "$REG" && show
}

case ${1:-} in
  A|B|C|P0|N4K) apply "$1" ;;
  revert) revert ;;
  show) show ;;
  *) echo "usage: $0 A|B|C|P0|N4K|show|revert" >&2; exit 2 ;;
esac
