# shellcheck shell=bash disable=SC2034  # sourced by profiles/settings/1174180/apply.sh and bench/games/rdr2.sh
# Red Dead Redemption 2 candidates at 4K: KEY=VALUE for system.xml (profiles/settings/xml_set.py); apply.sh describes P0, A, B, C.
# Each array pins every key a candidate varies, so the result does not depend on what the file held before.
# dlssIndex is the menu's choice (the order a community parser of system.xml uses: 0 Off, 1 Auto, 2 Quality, 3 Balanced,
# 4 Performance, 5 Ultra Performance); dlssQuality is NVIDIA's own enum (0 MaxPerf, 1 Balanced, 2 MaxQuality, 3 UltraPerf,
# 4 UltraQuality, 5 DLAA), the pair the game saves (the same parser calls dlssIndex enough on its own). anisotropicFiltering
# is an index too: 0 Off, 1 2x, 2 4x, 3 8x, 4 16x. vSync 1 is On (the parser: 1 yes, 0 no). The game's DLSS is 2.2 (the DLL
# in its folder); FSR 2.2 is the only other upscaler, there is no frame generation and no ray tracing.
RDR2_DESKTOP_ORIG=1920x1080   # the Wine virtual desktop (Explorer\Desktops\Default) before 2026-10-13
RDR2_BASE=(API=kSettingAPI_DX12 adapterIndex=0 windowed=2 scalingMode=kSettingScale_Mode1o1 msaa=0 reflectionMSAA=0
  fxaaEnabled=false motionBlur=false fsr2Index=0 textureQuality=kSettingLevel_Ultra
  screenWidth=3840 screenHeight=2160 screenWidthWindowed=3840 screenHeightWindowed=2160)
# What the game's "Safe" config (as found: every quality Low, textures Ultra, SSAO Medium) sets of the keys B raises.
RDR2_SAFE=(tessellation=kSettingLevel_Low shadowQuality=kSettingLevel_Low farShadowQuality=kSettingLevel_Low
  reflectionQuality=kSettingLevel_Low mirrorQuality=kSettingLevel_Low particleQuality=kSettingLevel_Low
  waterQuality=kSettingLevel_Low volumetricsQuality=kSettingLevel_Low lightingQuality=kSettingLevel_Low
  ambientLightingQuality=kSettingLevel_Low shadowSoftShadows=kSettingLevel_Low particleLightingQuality=kSettingLevel_Low
  waterRefractionQuality=kSettingLevel_Low waterReflectionQuality=kSettingLevel_Low
  volumetricsRaymarchQuality=kSettingLevel_Low volumetricsLightingQuality=kSettingLevel_Low
  scatteringVolumeQuality=kSettingLevel_Low terrainShadowQuality=kSettingLevel_Low decalQuality=kSettingLevel_Low
  treeQuality=kSettingLevel_Low POMQuality=kSettingLevel_Low ssdoResolution=kSettingLevel_Low
  deepsurfaceQuality=kSettingLevel_Low)
RDR2_MED=()
for _e in "${RDR2_SAFE[@]}"; do RDR2_MED+=("${_e%Low}Medium"); done
unset _e
# P0: the player's file as found on 2026-10-13 (Safe, DLSS off, TAA Medium, no anisotropic filtering, VSync off) at 4K.
RDR2_P0=("${RDR2_BASE[@]}" "${RDR2_SAFE[@]}" dlssIndex=0 dlssQuality=5 anisotropicFiltering=0 taa=kSettingLevel_Medium vSync=0)
# A: recommended. DLSS Quality (2560x1440 render), 16x anisotropic filtering, TAA High, VSync on; the Safe qualities stay.
RDR2_A=("${RDR2_BASE[@]}" "${RDR2_SAFE[@]}" dlssIndex=2 dlssQuality=2 anisotropicFiltering=4 taa=kSettingLevel_High vSync=1)
# B: more fidelity. A with the 23 Safe qualities raised from Low to Medium (shadows, reflections, water, volumetrics,
# lighting, particles, trees, decals); MSAA, tree tessellation and water physics stay off.
RDR2_B=("${RDR2_BASE[@]}" "${RDR2_MED[@]}" dlssIndex=2 dlssQuality=2 anisotropicFiltering=4 taa=kSettingLevel_High vSync=1)
# C: more fps. A with DLSS Performance (1920x1080 render): only worth it if A is GPU-limited; at 1080p the game is
# CPU-limited at about 75 fps.
RDR2_C=("${RDR2_BASE[@]}" "${RDR2_SAFE[@]}" dlssIndex=4 dlssQuality=0 anisotropicFiltering=4 taa=kSettingLevel_High vSync=1)
