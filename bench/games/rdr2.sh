# shellcheck shell=bash disable=SC2034  # variables are read by bench/run.sh
# Red Dead Redemption 2 (RAGE): native Vulkan or DirectX 12 via VKD3D-Proton. Sourced by bench/run.sh.
#
# Started by the Rockstar Games Launcher; the benchmark is in Settings > Graphics and has no command-line switch,
# so game_drive works the menus (keyboard; Run Benchmark Tests needs X held for seconds) and waits for the results
# file the game writes to Documents\Rockstar Games\Red Dead Redemption 2\Benchmarks.
# One-time setup (docs/FINDINGS.md has the reasons):
#   launch once from Steam and sign in to the Rockstar launcher. Its sign-in page only renders inside a Wine
#   virtual desktop:  PFX=<Steam>/steamapps/compatdata/1174180/pfx
#     python3 -I tools/winereg.py $PFX 'Software\Wine\Explorer' Desktop=Default
#     python3 -I tools/winereg.py $PFX 'Software\Wine\Explorer\Desktops' Default=1920x1080
#   start Steam with tools/steam-console.sh, which hides the host's software Vulkan drivers (lib/env.sh); RDR2
#   otherwise picks llvmpipe. Keep NVAPI enabled: on an NVIDIA GPU the game waits forever for nvapi64.dll.
# Env: RDR2_API=dx12|vulkan (default dx12; vulkan crashes at start under FEX 2610 Vulkan thunking)
APPID=1174180
GAME_PROC='^[A-Z]:.*\\RDR2\.exe'   # the game, not PlayRDR2.exe (Steam's stub) or the launcher
LAUNCH_ARGS=''
LAUNCH_RETRIES=3; LAUNCH_WAIT=150   # the launcher's sign-in sometimes stalls; a fresh launch clears it
RDR2_DOC="$(compat_user $APPID)/Documents/Rockstar Games/Red Dead Redemption 2"
# shellcheck source=lib/menu.sh
. "$ROOT/lib/menu.sh"

rdr2_kill() {
  local p
  [ -n "${MENU_REPLAY:-}" ] && return 0
  for p in $(pgrep -f "^[A-Z]:.*(\\\\RDR2\.exe|Rockstar Games|PlayRDR2)"); do kill "$p"; done
  for _ in $(seq 20); do pgrep -f "^[A-Z]:.*(\\\\RDR2\.exe|Rockstar Games|PlayRDR2)" >/dev/null || return 0; sleep 2; done
  pkill -9 -f "^[A-Z]:.*(\\\\RDR2\.exe|Rockstar Games|PlayRDR2)"; sleep 4
}
game_abort() { rdr2_kill; }

# 1920x1080 borderless (fullscreen mode switches resize the Wine virtual desktop), VSync off, first GPU.
game_prepare() {
  local api=kSettingAPI_DX12 s="$RDR2_DOC/Settings/system.xml"
  [ "${RDR2_API:-dx12}" = vulkan ] && api=kSettingAPI_Vulkan
  [ -f "$s" ] || die "no $s: launch the game once first"
  sed -i -E "s#<API>[^<]*</API>#<API>$api</API>#; s#<adapterIndex value=\"[0-9]+\" />#<adapterIndex value=\"0\" />#;
    s#<screen(Width|WidthWindowed) value=\"[0-9]+\" />#<screen\1 value=\"1920\" />#;
    s#<screen(Height|HeightWindowed) value=\"[0-9]+\" />#<screen\1 value=\"1080\" />#;
    s#<windowed value=\"[0-9]+\" />#<windowed value=\"2\" />#; s#<vSync value=\"[0-9]+\" />#<vSync value=\"0\" />#" "$s"
  cp "$s" "$1/system.xml"
}

# Every key waits for OCR to confirm its screen (lib/menu.sh); any surprise stops the run and closes the game.
game_drive() {  # $1 run dir, $2 game pid
  local out=$1 i
  MENU_DIR=$out
  menu_wait menu "QUIT ?GAME|SOCIAL ?CLUB" 60 5 || { rdr2_kill; return 1; }
  menu_pause 10                                                 # the menu ignores keys while it settles
  # Z opens Settings and is harmless to repeat; the grid is recognised by its footer (tile labels OCR unreliably).
  menu_press settings "Build [0-9]" 4 key z || { rdr2_kill; return 1; }
  menu_send move 365 710; menu_pause 1                          # the grid selects what the pointer hovers: Graphics
  menu_press graphics "BENCHMARK" 1 key Return || { rdr2_kill; return 1; }
  menu_press alert "benchmark tests" 1 key "x~4" || { rdr2_kill; return 1; }   # Run Benchmark Tests: a tap is ignored
  menu_send key Return
  date +%s > "$out/bench_start"
  [ -n "${MENU_REPLAY:-}" ] && { menu_wait end "End of benchmark" 1 0; return; }
  sleep 240                                                     # five passes take about 5 minutes
  for i in $(seq 120); do
    kill -0 "$2" 2>/dev/null || { echo "game exited during the benchmark"; break; }
    if screen_has end "End of benchmark"; then
      date +%s > "$out/bench_end"
      menu_send key BackSpace                                   # Exit Benchmarking: the results file is written now
      for _ in $(seq 30); do sleep 2; [ -n "$(find "$RDR2_DOC/Benchmarks" -type f -newer "$out/start" 2>/dev/null)" ] && break; done
      break
    fi
    sleep 10
  done
  sleep 5
  rdr2_kill
}

game_collect() {
  local f
  f=$(find "$RDR2_DOC/Benchmarks" -type f -newer "$1/start" 2>/dev/null | sort | tail -1)
  [ -n "$f" ] && mkdir -p "$1/result" && cp "$f" "$1/result/" && cp "$1/bench_start" "$1/bench_end" "$1/result/"
}
