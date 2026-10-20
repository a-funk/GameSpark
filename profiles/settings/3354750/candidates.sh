# shellcheck shell=bash disable=SC2034  # sourced by profiles/settings/3354750/apply.sh and bench/games/skate.sh
# skate. candidates at 4K, as menu entries ("Option=Value"): the game has never been started on this Spark, so no
# settings file exists to edit, and the file's name and format are unknown (see apply.sh). Option names are the ones
# PCGamesN's guide shows in the game's menu (early access, RTX 4070: 4K High, no upscaler, FXAA = 72 fps average, 1% low 48;
# 1440p 109; 1080p 121). The install ships DLSS Super Resolution, Ray Reconstruction and Frame Generation (310.6.0),
# XeSS 2 and XeFG, which older guides say the game lacked: use the menu's own list.
SKATE_A=("Resolution=3840x2160" "Display Mode=Borderless" "VSync=Off" "Dynamic Resolution=Off"
  "Upscaling Method=DLSS Super Resolution (XeSS if the list has no DLSS)" "Upscaling Quality=Quality"
  "Graphics Preset=High" "Texture Quality=High" "Texture Filtering=High" "Global Illumination=Dynamic"
  "Depth of Field Quality=Medium" "Frame Generation=Off")
SKATE_B=("Resolution=3840x2160" "Display Mode=Borderless" "VSync=Off" "Dynamic Resolution=Off" "Upscaling Method=None"
  "Anti-Aliasing=FXAA" "Graphics Preset=High" "Texture Quality=Ultra" "Texture Filtering=Ultra"
  "Global Illumination=Dynamic" "Frame Generation=Off")
SKATE_C=("Resolution=3840x2160" "Display Mode=Borderless" "VSync=Off" "Dynamic Resolution=Off"
  "Upscaling Method=DLSS Super Resolution (XeSS if the list has no DLSS)" "Upscaling Quality=Performance"
  "Graphics Preset=Medium" "Texture Quality=High" "Texture Filtering=High" "Global Illumination=Dynamic"
  "Frame Generation=Off")
