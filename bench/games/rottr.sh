# shellcheck shell=bash disable=SC2034  # variables are read by bench/run.sh
# Rise of the Tomb Raider (Foundation engine): DirectX 11 via DXVK or DirectX 12 via VKD3D-Proton. Sourced by bench/run.sh.
#
# The Windows build has no command-line benchmark switch and writes no results file, so game_drive selects
# START BENCHMARK in the main menu and reads the results screen with OCR (tools/ocr.sh).
# One-time setup:
#   tools/steam-config.sh compat-tool 391220 proton_experimental   # Windows build, not Feral's native port
#   launch once and acknowledge Square Enix's terms in-game
# Env: ROTTR_API=dx11|dx12 (default dx11)
#      ROTTR_CANDIDATE=P0|N4K|A|B|C  one of the 4K candidates of profiles/settings/391220/candidates.sh (P0 = the 1080p
#        key found on 2026-10-13, N4K = native 4K without DLSS, A = 4K + DLSS Quality, B = A + Very High textures,
#        shadows and detail, C = DLSS Performance) for this run; the player's registry goes back once the game has closed.
#      ROTTR_SET="Name=Value ..."  more registry values for this run, after the candidate (winereg.py: digits are DWORDs).
# Measured runs set VSync=0 and put the player's user.reg back afterwards (so they no longer leave VSync off or the last
# run's API behind); tune.py --apply, which has no BENCH_RUN, persists the API only.
# The three scenes take about 2.5 min and the results screen is read at whatever size the screen has. Discard the first
# run after a settings change: DX12 pipelines and DLSS start cold (102.7 against 131 fps in docs/FINDINGS.md).
TUNE_KNOBS='ROTTR_API=dx11,dx12'   # searched by bench/tune.py
APPID=391220
GAME_NAME="Rise of the Tomb Raider"
GAME_EXE='Rise of the Tomb Raider/ROTTR.exe'   # under steamapps/common (64-bit)
GAME_PROC='^[A-Z]:.*ROTTR\.exe'   # the Wine process (S:\...\ROTTR.exe), not Steam's reaper, whose command line also names it
LAUNCH_ARGS=''
ROTTR_PFX=${ROTTR_PFX:-$STEAM_ROOT/steamapps/compatdata/$APPID/pfx}
ROTTR_REG=$ROTTR_PFX/user.reg
ROTTR_PENDING=$SG_DATA/launch/rottr-candidate.pending   # the backup to put back; present only until the restore is done
# shellcheck source=lib/menu.sh
. "$ROOT/lib/menu.sh"
# shellcheck source=profiles/settings/lib.sh
. "$ROOT/profiles/settings/lib.sh"
# shellcheck source=profiles/settings/391220/candidates.sh
. "$ROOT/profiles/settings/391220/candidates.sh"

rottr_busy() { pgrep -f "[r]eaper SteamLaunch AppId=$APPID " >/dev/null || pgrep -f "$GAME_PROC" >/dev/null; }

# The player's user.reg back from the pending backup. Wine writes its registry when the prefix's last process exits, so
# wait for the game and Steam's reaper to be gone first, or Wine would write the run's values over the restore.
rottr_restore() {
  local b
  [ -f "$ROTTR_PENDING" ] || return 0
  for _ in $(seq 90); do rottr_busy || break; sleep 1; done
  if rottr_busy; then echo "warning: $GAME_NAME is still running; its settings stay as they are" >&2; return 1; fi
  read -r b < "$ROTTR_PENDING"
  cp -p "$b" "$ROTTR_REG" && rm -f "$ROTTR_PENDING" && echo "restored the player's registry from $b"
}

rottr_dword() {  # FILE NAME: a DWORD of the settings.txt dump, in decimal
  local h
  h=$(sed -n "s/^\"$2\"=dword:\([0-9a-f]*\).*/\1/p" "$1" | head -1)
  [ -n "$h" ] && echo $((16#$h))
}

rottr_describe() {   # $1 run dir: the run's resolution and preset, for the record
  local f=$1/settings.txt dlss
  case $(rottr_dword "$f" DLSS) in
    0) dlss="no DLSS" ;; 1) dlss="DLSS Ultra Performance" ;; 2) dlss="DLSS Performance" ;; 3) dlss="DLSS Balanced" ;;
    4) dlss="DLSS Quality" ;; *) dlss="DLSS ?" ;;
  esac
  echo "$(rottr_dword "$f" FullscreenWidth)x$(rottr_dword "$f" FullscreenHeight)" > "$1/resolution"
  echo "${ROTTR_API:-dx11} · $dlss · candidate ${ROTTR_CANDIDATE:-as is} · VSync off" > "$1/preset"
}

# Runs with the game closed, so the registry edit sticks (Wine rewrites user.reg on exit).
game_prepare() {
  local dx12=0 b
  local -a keys=()
  rottr_restore || die "an earlier run's settings are still in place (see above)"
  [ "${ROTTR_API:-dx11}" = dx12 ] && dx12=1
  case ${ROTTR_CANDIDATE:-} in
    '') ;;
    P0) keys=("${ROTTR_P0[@]}") ;;
    N4K) keys=("${ROTTR_N4K[@]}") ;;
    A) keys=("${ROTTR_A[@]}") ;;
    B) keys=("${ROTTR_B[@]}") ;;
    C) keys=("${ROTTR_C[@]}") ;;
    *) die "ROTTR_CANDIDATE=$ROTTR_CANDIDATE: P0, N4K, A, B or C" ;;
  esac
  # shellcheck disable=SC2206  # ROTTR_SET is a space-separated list by design
  keys+=(${ROTTR_SET:-})
  mkdir -p "$SG_DATA/launch"
  b=$(sg_backup "$APPID" "$ROTTR_REG" "bench run ${ROTTR_CANDIDATE:-settings}") || die "backup failed"
  [ -n "${BENCH_RUN:-}" ] && echo "$b" > "$ROTTR_PENDING"
  python3 -I "$ROOT/tools/winereg.py" "$ROTTR_PFX" "$ROTTR_KEY" "${keys[@]}" ${BENCH_RUN:+VSync=0} EnableDX12=$dx12 > "$1/settings.txt"
  awk '/^\[Software\\\\Crystal Dynamics\\\\Rise of the Tomb Raider\\\\Graphics\]/,/^$/' "$ROTTR_PFX/user.reg" >> "$1/settings.txt"
  rottr_describe "$1"
}

game_cleanup() { rottr_restore || true; }   # EXIT trap of bench/run.sh

game_drive() {  # $1 run dir, $2 game pid
  local out=$1
  MENU_DIR=$out
  menu_wait menu "BENCHMARK" 60 5 || { kill "$2"; return 1; }   # main menu shows about 50 s after launch
  menu_pause 3
  # Return activates the keyboard cursor's item (a mouse click only moves the highlight). The cursor starts on
  # the first item and Up wraps to the last one, START BENCHMARK, whether or not a CONTINUE entry exists.
  menu_send key Up sleep:1 Return
  date +%s > "$out/bench_start"
  menu_pause 120            # three scenes take about 2.5 min; avoid screenshot/OCR load while they run
  local found=0
  menu_wait results "Overall score" 60 4 && "$ROOT/tools/ocr.sh" "$out/results.png" > "$out/results.txt" || found=1
  date +%s > "$out/bench_end"
  [ -n "${MENU_REPLAY:-}" ] || kill "$2"
  return $found
}

game_collect() {
  game_cleanup
  grep -q "Overall score" "$1/results.txt" 2>/dev/null || return 1
  mkdir -p "$1/result" && cp "$1/results.txt" "$1/results.png" "$1/bench_start" "$1/bench_end" "$1/settings.txt" "$1/result/"
}
