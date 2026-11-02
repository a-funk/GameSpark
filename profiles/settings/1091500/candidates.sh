# shellcheck shell=bash disable=SC2034  # sourced by profiles/settings/1091500/apply.sh and bench/games/cyberpunk2077.sh
# Cyberpunk 2077 candidates at 4K: group/option=value[@index] for bench/cyberpunk2077_settings.py (apply.sh describes P0, A, B, C).
# Each array pins every option a candidate varies, so the result does not depend on what the file held before.
# Dynamic lists (Resolution, WindowMode, ResolutionScaling, DLSS, FrameGeneration) carry an index: the game wrote 1920x1080
# at 8, BorderlessWindowed at 1, DLSS at 1, Quality at 2 and Off at 0; the other indexes follow the game's list order and are
# a best guess (3840x2160 comes after 1920x1080 in the TV's mode list, DLSS: Auto, DLAA, Quality, Balanced, Performance,
# Ultra Performance). The game is believed to match a dynamic list by its value, so a wrong index is harmless (not verified).
# VSync is not listed: the file only shows its Off token (UI-Settings-Video-QualitySetting-Off); the On token is not known.
# The candidates cap the frame rate at 60 instead (MaximumFPS); measured runs lift it and force VSync off.
CP_BASE=(
  /video/display/Resolution=3840x2160@9
  /video/display/WindowMode=BorderlessWindowed@1
  /graphics/presets/ResolutionScaling=DLSS@1
  /graphics/presets/DLSS_BackendPreset=Transformer
  /graphics/presets/DLSS_D=false
  /graphics/presets/FrameGeneration=Off@0
  /graphics/presets/DLSSFrameGen=false
  /graphics/presets/DynamicResolutionScaling=false
  /graphics/presets/TextureQuality=High
  /graphics/raytracing/RayTracing=false
  /graphics/raytracing/RayTracedPathTracing=false
  /graphics/advanced/FacialTangentUpdates=true
  /graphics/advanced/Anisotropy=16
)
CP_CAP60=(/video/display/MaximumFPS_OnOff=true /video/display/MaximumFPS_Value=60)
# P0: the player's file as found on 2026-10-13 (DLSS Quality, the Custom preset with fog, clouds and SSR on Ultra), at 4K.
# An upscaler plus SSR on Ultra makes the game draw SSR in its Psycho mode (PCGamingWiki), the costliest one.
CP_P0=("${CP_BASE[@]}" /video/display/MaximumFPS_OnOff=false /video/display/MaximumFPS_Value=30 /graphics/presets/DLSS=Quality@2
  /graphics/advanced/ContactShadows=true /graphics/advanced/ShadowMeshQuality=High /graphics/advanced/LocalShadowsQuality=High
  /graphics/advanced/CascadedShadowsRange=High /graphics/advanced/CascadedShadowsResolution=High
  /graphics/advanced/DistantShadowsResolution=High /graphics/advanced/VolumetricFogResolution=Ultra
  /graphics/advanced/VolumetricCloudsQuality=Ultra /graphics/advanced/MaxDynamicDecals=Ultra
  /graphics/advanced/ScreenSpaceReflectionsQuality=Ultra /graphics/advanced/SubsurfaceScatteringQuality=High
  /graphics/advanced/AmbientOcclusion=High /graphics/advanced/ColorPrecision=High /graphics/advanced/MirrorQuality=High
  /graphics/advanced/LODPreset=High /graphics/performance/CrowdDensity=High /gameplay/performance/CrowdDensity=High)
# A: recommended. DLSS Performance (1920x1080 render), the costliest per-pixel options one step down (DF's 4K advice: fog and
# clouds Medium; SSR High, which also avoids the Psycho bug; cascaded shadow resolution Medium; AO and color precision
# Medium), crowd density Medium (the CPU lever).
CP_A=("${CP_BASE[@]}" "${CP_CAP60[@]}" /graphics/presets/DLSS=Performance@4
  /graphics/advanced/ContactShadows=true /graphics/advanced/ShadowMeshQuality=High /graphics/advanced/LocalShadowsQuality=High
  /graphics/advanced/CascadedShadowsRange=High /graphics/advanced/CascadedShadowsResolution=Medium
  /graphics/advanced/DistantShadowsResolution=High /graphics/advanced/VolumetricFogResolution=Medium
  /graphics/advanced/VolumetricCloudsQuality=Medium /graphics/advanced/MaxDynamicDecals=High
  /graphics/advanced/ScreenSpaceReflectionsQuality=High /graphics/advanced/SubsurfaceScatteringQuality=High
  /graphics/advanced/AmbientOcclusion=Medium /graphics/advanced/ColorPrecision=Medium /graphics/advanced/MirrorQuality=High
  /graphics/advanced/LODPreset=High /graphics/performance/CrowdDensity=Medium /gameplay/performance/CrowdDensity=Medium)
# B: more fidelity. DLSS Balanced (about 2227x1253 render), shadows, AO, decals and color precision as in P0, fog and clouds
# High, SSR High (not Ultra), crowd density High.
CP_B=("${CP_BASE[@]}" "${CP_CAP60[@]}" /graphics/presets/DLSS=Balanced@3
  /graphics/advanced/ContactShadows=true /graphics/advanced/ShadowMeshQuality=High /graphics/advanced/LocalShadowsQuality=High
  /graphics/advanced/CascadedShadowsRange=High /graphics/advanced/CascadedShadowsResolution=High
  /graphics/advanced/DistantShadowsResolution=High /graphics/advanced/VolumetricFogResolution=High
  /graphics/advanced/VolumetricCloudsQuality=High /graphics/advanced/MaxDynamicDecals=Ultra
  /graphics/advanced/ScreenSpaceReflectionsQuality=High /graphics/advanced/SubsurfaceScatteringQuality=High
  /graphics/advanced/AmbientOcclusion=High /graphics/advanced/ColorPrecision=High /graphics/advanced/MirrorQuality=High
  /graphics/advanced/LODPreset=High /graphics/performance/CrowdDensity=High /gameplay/performance/CrowdDensity=High)
# C: more fps. DLSS Performance with what costs GPU and CPU one more step down: contact shadows off, local and cascaded
# shadows, mirrors, LOD and decals Medium, fog Low, SSR Medium, AO Low, crowd density Low.
CP_C=("${CP_BASE[@]}" "${CP_CAP60[@]}" /graphics/presets/DLSS=Performance@4
  /graphics/advanced/ContactShadows=false /graphics/advanced/ShadowMeshQuality=Medium /graphics/advanced/LocalShadowsQuality=Medium
  /graphics/advanced/CascadedShadowsRange=Medium /graphics/advanced/CascadedShadowsResolution=Medium
  /graphics/advanced/DistantShadowsResolution=Low /graphics/advanced/VolumetricFogResolution=Low
  /graphics/advanced/VolumetricCloudsQuality=Medium /graphics/advanced/MaxDynamicDecals=Medium
  /graphics/advanced/ScreenSpaceReflectionsQuality=Medium /graphics/advanced/SubsurfaceScatteringQuality=Medium
  /graphics/advanced/AmbientOcclusion=Low /graphics/advanced/ColorPrecision=Medium /graphics/advanced/MirrorQuality=Medium
  /graphics/advanced/LODPreset=Medium /graphics/performance/CrowdDensity=Low /gameplay/performance/CrowdDensity=Low)
