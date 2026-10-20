# shellcheck shell=bash disable=SC2034  # sourced by profiles/settings/292030/apply.sh and bench/games/witcher3.sh
# The Witcher 3 Remastered candidates at 4K: KEY=VALUE lines for dx12user.settings (profiles/settings/ini_set.py, CRLF kept;
# every key occurs once in the file); apply.sh describes P0, A, B and C. The values come from the game's own option matrix
# (bin/config/r4game/user_config_matrix/pc/graphics.xml): AAMode 0 off, 1 FXAA, 5 FSR, 6 DLSS, 7 XeSS; DLSSQuality 0 Auto,
# 1 Quality, 2 Balanced, 3 Performance, 4 Ultra Performance, 5 DLAA; XESSQuality 0 Auto, 4 Quality, 5 Balanced, 6 Performance.
# Each array pins every key a candidate varies, so the result does not depend on what the file held before.
# VSync is on for play (the 60 Hz TV); measured runs force it off. Frame generation, ray tracing and DLSS Ray
# Reconstruction stay off: with VSync a frame generator holds the game to half the refresh rate.
W3_BASE=('Resolution="3840x2160"' FullScreenMode=1 LimitFPS=0 VSync=true DLSSGMode=0 FSRFramegen=0 XessFrameGeneration=false
  EnableDLSSRR=false SharpenAmount=0 ShouldDetectEditorGraphicsPreset=false ShouldRefetchUpscaler=false)
# The game's Ultra ("uber") preset, which the file held (auto-detected on GB10): what the preset sets of the keys C lowers.
W3_UBER=(CascadeShadowmapSize=3072 CascadeShadowDistanceScale2=1.5 CascadeShadowDistanceScale3=1.5 TerrainErrorMetricMultiplier=6
  TerrainScreenSpaceErrorThreshold=1.6 TerrainScreenSpaceErrorThresholdFar=3.5 GlobalOceanTesselationFactor=48
  MaxVisibilityDepth=24 FoliageDistanceScale=1.8 GrassDistanceScale=2.5 GrassRingSize=8388608 FoliageShadowDistanceScale=48
  GrassDensity=4750 DecalsHideDistance=80 MeshLODDistanceScale=1.3 SpawnedLimit=150 GTAOQuality=3)
# The same keys at the High preset (textures stay as they are: they cost memory, not time).
W3_HIGH=(CascadeShadowmapSize=2048 CascadeShadowDistanceScale2=1.2 CascadeShadowDistanceScale3=1.2 TerrainErrorMetricMultiplier=10
  TerrainScreenSpaceErrorThreshold=2 TerrainScreenSpaceErrorThresholdFar=5 GlobalOceanTesselationFactor=32
  MaxVisibilityDepth=12 FoliageDistanceScale=1.5 GrassDistanceScale=2 GrassRingSize=6291456 FoliageShadowDistanceScale=16
  GrassDensity=3500 DecalsHideDistance=40 MeshLODDistanceScale=1.2 SpawnedLimit=130 GTAOQuality=2)
# P0: the player's file as found on 2026-10-13 (XeSS Auto, Ultra) at 4K, VSync as played.
W3_P0=("${W3_BASE[@]}" "${W3_UBER[@]}" AAMode=7 XESSQuality=0 DLSSQuality=0)
# A: recommended. DLSS Performance (1920x1080 render) with the Ultra settings the file held.
W3_A=("${W3_BASE[@]}" "${W3_UBER[@]}" AAMode=6 DLSSQuality=3)
# B: more fidelity. DLSS Quality (2560x1440 render), Ultra settings.
W3_B=("${W3_BASE[@]}" "${W3_UBER[@]}" AAMode=6 DLSSQuality=1)
# C: more fps. DLSS Performance with the High preset's shadows, terrain, water, foliage, grass, LOD, crowd and GTAO.
W3_C=("${W3_BASE[@]}" "${W3_HIGH[@]}" AAMode=6 DLSSQuality=3)
# A, B and C never ran DLSS (the game's Streamline never starts NGX here): they measured native 4K with TAA.
# D: closest to 60 (2026-10-17). C's detail, FSR Quality (2560x1440 render), HairWorks off: 59.1 fps in Novigrad.
# The render size barely matters here (FSR at 720p, 1080p and 1440p and native 4K all gave 53-56 fps with HairWorks).
W3_D=("${W3_BASE[@]}" "${W3_HIGH[@]}" AAMode=5 FSR2Quality=2 HairWorksLevel=0)
# E: DLSS through OptiScaler (bin/x64_dx12/dxgi.dll): the game's XeSS Performance (1920x1080 render) runs as DLSS
# Performance with the CNN model (OptiScaler.ini: preset E for Performance), HairWorks off: 55.4 fps. The
# transformer model gave 49.6 there; DLSS Quality 37-39, DLAA 22.4: DLSS costs a lot on GB10 from 1440p up.
W3_E=("${W3_BASE[@]}" "${W3_HIGH[@]}" AAMode=7 XESSQuality=6 HairWorksLevel=0)
