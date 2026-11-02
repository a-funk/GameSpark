# shellcheck shell=bash disable=SC2034  # sourced by profiles/settings/4078430/apply.sh and bench/games/galacticracer.sh
# STAR WARS: Galactic Racer candidates at 4K: Key=Value pairs for GameUserSettings.ini (ini_set.py); apply.sh describes
# P0, U, A, B and C. The game keeps every scalability group twice: sg.* in [ScalabilityGroups] and the same values in
# CustomScalabilityGroupSettings[0..11] of [/Script/Griffin.GfnUserSettingsPC] (same order: ResolutionQuality,
# ViewDistance, AntiAliasing, Shadow, GlobalIllumination, Reflection, PostProcess, Texture, Effects, Foliage, Shading,
# Landscape), so a group is changed in both places. Frame generation stays off in every candidate (docs/FINDINGS.md:
# GPU hangs with dynamic frame generation), as do Nanite and ray tracing (profiles/launch/4078430.*).
GR_4K=(ResolutionSizeX=3840 ResolutionSizeY=2160 LastUserConfirmedResolutionSizeX=3840 LastUserConfirmedResolutionSizeY=2160
  FullscreenMode=0 DLSSFrameGenerationMode=Off CurrentFrameGenerationProvider=Off bIsDLSSRayReconstructionEnabled=False)
# P0: the file as found on 2026-10-13 (2560x1440 exclusive fullscreen, scaled to the TV; DLSS Performance; 61-67 fps).
GR_P0=(ResolutionSizeX=2560 ResolutionSizeY=1440 LastUserConfirmedResolutionSizeX=1920 LastUserConfirmedResolutionSizeY=1080
  FullscreenMode=0 DLSSFrameGenerationMode=Off CurrentFrameGenerationProvider=Off bIsDLSSRayReconstructionEnabled=False
  DLSSSuperResolutionMode=Performance)
# U: 4K output with today's 1280x720 inside and today's groups: what the 4K output alone costs.
GR_U=("${GR_4K[@]}" DLSSSuperResolutionMode=UltraPerformance)
# The groups whose cost does not shrink with the render size (Lumen's gather and reflections, the post effects), one
# step down: 1 = Medium.
GR_LITE=(sg.GlobalIlluminationQuality=1 'CustomScalabilityGroupSettings[4]=1' sg.ReflectionQuality=1
  'CustomScalabilityGroupSettings[5]=1' sg.PostProcessQuality=1 'CustomScalabilityGroupSettings[6]=1')
GR_A=("${GR_U[@]}" "${GR_LITE[@]}")
GR_B=("${GR_4K[@]}" DLSSSuperResolutionMode=Performance sg.TextureQuality=3 'CustomScalabilityGroupSettings[7]=3')
GR_C=("${GR_A[@]}" sg.ViewDistanceQuality=0 'CustomScalabilityGroupSettings[1]=0' sg.EffectsQuality=0
  'CustomScalabilityGroupSettings[8]=0' sg.FoliageQuality=1 'CustomScalabilityGroupSettings[9]=1' sg.ShadingQuality=1
  'CustomScalabilityGroupSettings[10]=1')
