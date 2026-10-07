# shellcheck shell=bash disable=SC2034  # variables are read by bench/run.sh
# Cyberpunk 2077 (REDengine, DirectX 12 -> VKD3D-Proton). Sourced by bench/run.sh.
# Built-in benchmark launch recipe from the Phoronix Test Suite cyberpunk2077 profile.
APPID=1091500
GAME_PROC='^[A-Z]:.*Cyberpunk2077\.exe'   # the Wine process (S:\...\Cyberpunk2077.exe)
LAUNCH_ARGS='--launcher-skip -benchmark -skipStartScreen'
CP_USER=$(compat_user $APPID)
CP_RESULTS="$CP_USER/Documents/CD Projekt Red/Cyberpunk 2077/benchmarkResults"
CP_SETTINGS="$CP_USER/AppData/Local/CD Projekt Red/Cyberpunk 2077/UserSettings.json"

game_prepare() { cp "$CP_SETTINGS" "$1/UserSettings.json" 2>/dev/null; mkdir -p "$CP_RESULTS"; }

# The benchmark writes benchmarkResults/<timestamp>/{summary.json,frames.csv}; take the one written during this run.
game_collect() {
  local d; d=$(find "$CP_RESULTS" -mindepth 1 -maxdepth 1 -type d -newer "$1/start" | sort | tail -1)
  [ -n "$d" ] && [ -f "$d/summary.json" ] && cp -r "$d" "$1/result"
}
