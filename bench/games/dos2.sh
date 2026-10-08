# shellcheck shell=bash disable=SC2034  # variables are read by bench/run.sh
# Divinity: Original Sin 2 - Definitive Edition (Divinity Engine 3.6, DirectX 11 via DXVK). Sourced by bench/run.sh.
#
# No built-in benchmark: frame times come from MangoHud (bench/run.sh FRAMES=SECS, on by default here). Without menu
# driving this measures the main menu scene, which the game caps at the display rate, so it checks the pipeline
# rather than gameplay performance. One-time setup: system/frametimes.sh install; Steam launch options
# "<gamespark>/tools/launch.sh %command%" (profiles/launch/435150.env skips the Larian launcher).
APPID=435150
GAME_NAME="Divinity: Original Sin 2"
GAME_API="DirectX 11 (DXVK)"
GAME_PROC='^[A-Z]:.*EoCApp\.exe'
LAUNCH_ARGS=''
: "${FRAMES:=20}" "${FRAMES_DELAY:=40}"
