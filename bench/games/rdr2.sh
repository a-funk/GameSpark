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
#   tools/steam-config.sh launch-options 1174180 "VK_LOADER_DRIVERS_SELECT=*nvidia* %command%"
#     (with system/fex-system.sh the host's Mesa drivers are visible too, and RDR2 can pick llvmpipe; keep NVAPI
#     enabled: on an NVIDIA GPU the game waits forever for nvapi64.dll)
# Env: RDR2_API=dx12|vulkan (default dx12; vulkan crashes at start under FEX 2610 Vulkan thunking)
APPID=1174180
GAME_PROC='^[A-Z]:.*\\RDR2\.exe'   # the game, not PlayRDR2.exe (Steam's stub) or the launcher
LAUNCH_ARGS=''
LAUNCH_RETRIES=3; LAUNCH_WAIT=150   # the launcher's sign-in sometimes stalls; a fresh launch clears it
RDR2_DOC="$(compat_user $APPID)/Documents/Rockstar Games/Red Dead Redemption 2"

rdr2_kill() {
  local p
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

ocr_has() { "$ROOT/tools/shot.sh" "$1" >/dev/null && "$ROOT/tools/ocr.sh" "$1" | grep -qiE "$2"; }

# Every key is sent only after OCR confirms the screen it is meant for: on the main menu Return starts Story mode
# (the user's save) and Backspace quits. Any surprise stops the run and closes the game.
game_drive() {  # $1 run dir, $2 game pid
  local out=$1 i
  for i in $(seq 60); do sleep 5; ocr_has "$out/menu.png" "QUIT ?GAME|SOCIAL ?CLUB" && break; done
  ocr_has "$out/menu.png" "QUIT ?GAME|SOCIAL ?CLUB" || { echo "main menu not found"; rdr2_kill; return 1; }
  sleep 10                                                            # the menu ignores keys while it settles
  for i in 1 2 3 4; do                                                # Z = Settings; only Z until it is open
    python3 -I "$ROOT/tools/xinput.py" key z; sleep 4
    ocr_has "$out/settings.png" "Build [0-9]" && break               # the grid's footer (tile labels OCR unreliably)
  done
  ocr_has "$out/settings.png" "Build [0-9]" || { echo "settings grid not found"; rdr2_kill; return 1; }
  # The grid's selection follows the mouse pointer, so select Graphics (bottom left) by hovering it.
  python3 -I "$ROOT/tools/xinput.py" move 365 710; sleep 1
  python3 -I "$ROOT/tools/xinput.py" key Return; sleep 4
  ocr_has "$out/graphics.png" "BENCHMARK" || { echo "graphics page not found"; rdr2_kill; return 1; }
  python3 -I "$ROOT/tools/xinput.py" key "x~4"; sleep 2               # Run Benchmark Tests: a tap is ignored
  ocr_has "$out/alert.png" "benchmark tests" || { echo "benchmark alert not found"; rdr2_kill; return 1; }
  python3 -I "$ROOT/tools/xinput.py" key Return
  date +%s > "$out/bench_start"
  # Five passes take about 5 minutes; the results file is only written after Exit Benchmarking on the end screen.
  sleep 240
  for i in $(seq 120); do
    kill -0 "$2" 2>/dev/null || { echo "game exited during the benchmark"; break; }
    if ocr_has "$out/end.png" "End of benchmark"; then
      date +%s > "$out/bench_end"
      python3 -I "$ROOT/tools/xinput.py" key BackSpace                  # Exit Benchmarking: writes the file
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
