# shellcheck shell=bash disable=SC2034  # sourced by profiles/settings/3669870/apply.sh and bench/games/controlresonant.sh
# CONTROL Resonant candidates at 4K: key=value pairs for renderer.ini (flatjson_set.py); apply.sh describes A, B and C.
# Each one pins what decides the cost: output size, upscaler, ray tracing, frame generation. The render size IS the DLSS
# mode (output 3840x2160): 2560x1440 is Quality, 1920x1080 Performance, 1280x720 Ultra Performance.
CTRL_BASE=(m_iOutputResolutionX=3840 m_iOutputResolutionY=2160 m_eSSAAMethod=2 m_bDLSSLegacy=false m_DLSSRR=false
  m_eDLSSFGMode=0 m_eFSRFGMode=0 m_eHighQualityPost=0 m_eRTReflectionQuality=0 m_eRTTransparentQuality=0
  m_eRTIndirectDiffuseQuality=0 m_eRTReSTIRQuality=0 m_eRTDirectLightDenoisingQuality=0 m_eRTDebrisQuality=0
  m_ePTQuality=0 m_ePTDenoisingQuality=0)
# P0: the player's file as found on 2026-10-13 (measured: 35 fps, GPU 94% busy). For re-measuring after A is applied.
CTRL_P0=("${CTRL_BASE[@]}" m_iRenderResolutionX=2560 m_iRenderResolutionY=1440 m_eSDFQuality=2 m_eGIQuality=2
  m_eSSRQuality=2 m_eMotionBlur=1 m_maxFrameRate=360.0)
CTRL_A=("${CTRL_BASE[@]}" m_iRenderResolutionX=1920 m_iRenderResolutionY=1080 m_eSDFQuality=0 m_eGIQuality=2
  m_eSSRQuality=2 m_eMotionBlur=1 m_maxFrameRate=60.0)
CTRL_B=("${CTRL_BASE[@]}" m_iRenderResolutionX=2560 m_iRenderResolutionY=1440 m_eSDFQuality=1 m_eGIQuality=2
  m_eSSRQuality=2 m_eMotionBlur=1 m_maxFrameRate=60.0)
CTRL_C=("${CTRL_BASE[@]}" m_iRenderResolutionX=1280 m_iRenderResolutionY=720 m_eSDFQuality=0 m_eGIQuality=1
  m_eSSRQuality=1 m_eMotionBlur=0 m_maxFrameRate=60.0)
# D, measured 2026-10-13 and applied: C's lighter effects at the Performance render size with the older DLSS model
# (CNN; the transformer model costs about 10 fps at 4K output here): 64.1 fps, 1% low 51.0, every target passed
# (run 20261013-214304-controlresonant-4k-C1080L). VSync on, for the 59.94 Hz TV.
CTRL_D=("${CTRL_C[@]}" m_iRenderResolutionX=1920 m_iRenderResolutionY=1080 m_bDLSSLegacy=true m_eVSync=1)
