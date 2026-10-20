# shellcheck shell=bash disable=SC2034  # sourced by profiles/settings/391220/apply.sh and bench/games/rottr.sh
# Rise of the Tomb Raider candidates at 4K: Name=Value pairs for the registry key below (tools/winereg.py writes digits
# as DWORDs); apply.sh describes A, B and C. DirectX 12 (EnableDX12=1) and the other keys stay as they are.
ROTTR_KEY='Software\Crystal Dynamics\Rise of the Tomb Raider\Graphics'
ROTTR_4K=(FullscreenWidth=3840 FullscreenHeight=2160 Fullscreen=1 ExclusiveFullscreen=0)
# P0: the key as found on 2026-10-13 (a 1920x1080 leftover from before 4K; VSync was off from the benchmark runs).
ROTTR_P0=(FullscreenWidth=1920 FullscreenHeight=1080 Fullscreen=1 ExclusiveFullscreen=0 DLSS=0 FilmGrain=1 DOFQuality=1
  VSync=0)
# N4K: native 4K with no upscaler (FXAA as before): the 4K baseline, to see what DLSS buys.
ROTTR_N4K=("${ROTTR_4K[@]}" DLSS=0 FilmGrain=1 DOFQuality=1)
# DLSS (ROTTR.exe's own list, in the order its menu strings come): 0 Off, 1 Ultra Performance, 2 Performance,
# 3 Balanced, 4 Quality. Film grain and depth of field run before DLSS in this game and smear its output (PCGamingWiki).
ROTTR_A=("${ROTTR_4K[@]}" DLSS=4 FilmGrain=0 DOFQuality=0 VSync=1)
ROTTR_B=("${ROTTR_A[@]}" TextureQuality=3 ShadowQuality=3 LevelOfDetail=3 TextureFiltering=4)
ROTTR_C=("${ROTTR_4K[@]}" DLSS=2 FilmGrain=0 DOFQuality=0 VSync=1)
