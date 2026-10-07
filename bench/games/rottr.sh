# Rise of the Tomb Raider (Foundation engine): DirectX 11 via DXVK or DirectX 12 via VKD3D-Proton. Sourced by bench/run.sh.
#
# The Windows build has no command-line benchmark switch and writes no results file, so game_drive selects
# START BENCHMARK in the main menu and reads the results screen with OCR (tools/ocr.sh).
# One-time setup:
#   tools/steam-config.sh compat-tool 391220 proton_experimental   # Windows build, not Feral's native port
#   launch once and acknowledge Square Enix's terms in-game
# Env: ROTTR_API=dx11|dx12 (default dx11)
APPID=391220
GAME_PROC='^[A-Z]:.*ROTTR\.exe'   # the Wine process (S:\...\ROTTR.exe), not Steam's reaper, whose command line also names it
LAUNCH_ARGS=''
ROTTR_PFX=$STEAM_ROOT/steamapps/compatdata/$APPID/pfx
ROTTR_KEY='Software\Crystal Dynamics\Rise of the Tomb Raider\Graphics'

# Runs with the game closed, so the registry edit sticks (Wine rewrites user.reg on exit).
game_prepare() {
  local dx12=0
  [ "${ROTTR_API:-dx11}" = dx12 ] && dx12=1
  python3 -I "$ROOT/tools/winereg.py" "$ROTTR_PFX" "$ROTTR_KEY" VSync=0 EnableDX12=$dx12 > "$1/settings.txt"
  awk '/^\[Software\\\\Crystal Dynamics\\\\Rise of the Tomb Raider\\\\Graphics\]/,/^$/' "$ROTTR_PFX/user.reg" >> "$1/settings.txt"
}

game_drive() {  # $1 run dir, $2 game pid
  local out=$1 i xy
  for i in $(seq 60); do    # main menu shows about 50 s after launch
    sleep 5
    "$ROOT/tools/shot.sh" "$out/menu.png" >/dev/null
    xy=$("$ROOT/tools/ocr.sh" "$out/menu.png" --find BENCHMARK) && break
  done
  [ -z "${xy:-}" ] && { echo "main menu not found"; kill "$2"; return 1; }
  # Return activates the keyboard cursor's item (a mouse click only moves the highlight). The cursor starts on
  # the first item and Up wraps to the last one, START BENCHMARK, whether or not a CONTINUE entry exists.
  sleep 3
  python3 -I "$ROOT/tools/xinput.py" key Up sleep:1 Return
  date +%s > "$out/bench_start"
  sleep 120                 # three scenes take about 2.5 min; avoid screenshot/OCR load while they run
  for i in $(seq 60); do
    "$ROOT/tools/shot.sh" "$out/results.png" >/dev/null
    "$ROOT/tools/ocr.sh" "$out/results.png" > "$out/results.txt"
    grep -q "Overall score" "$out/results.txt" && break
    sleep 4
  done
  date +%s > "$out/bench_end"
  kill "$2"
}

game_collect() {
  grep -q "Overall score" "$1/results.txt" 2>/dev/null || return 1
  mkdir -p "$1/result" && cp "$1/results.txt" "$1/results.png" "$1/bench_start" "$1/bench_end" "$1/settings.txt" "$1/result/"
}
