# shellcheck shell=bash disable=SC2034  # variables are read by bench/run.sh
# Divinity: Original Sin 2 - Definitive Edition (Divinity Engine 3.6, DirectX 11 via DXVK). Sourced by bench/run.sh.
#
# No built-in benchmark: frame times come from MangoHud (bench/run.sh FRAMES=SECS, on by default here). Without menu
# driving this measures the main menu scene, which the game caps at the display rate, so it checks the pipeline
# rather than gameplay performance. One-time setup: system/frametimes.sh install; Steam launch options
# "<gamespark>/tools/launch.sh %command%" (profiles/launch/435150.env skips the Larian launcher).
# Env: DOS2_CANDIDATE=A|B applies that graphics candidate (profiles/settings/435150/candidates.sh) to graphicSettings.lsx
#      for this run only; the player's file goes back once the game has closed. Unset: the file as it is.
APPID=435150
GAME_NAME="Divinity: Original Sin 2"
GAME_API="DirectX 11 (DXVK)"
GAME_PROC='^[A-Z]:.*EoCApp\.exe'
LAUNCH_ARGS=''
: "${FRAMES:=20}" "${FRAMES_DELAY:=40}"
DOS2_CFG="$(compat_user "$APPID")/Documents/Larian Studios/Divinity Original Sin 2 Definitive Edition/graphicSettings.lsx"
DOS2_PENDING=$SG_DATA/launch/dos2-candidate.pending   # the backup to put back; present only until the restore is done
# shellcheck source=profiles/settings/lib.sh
. "$ROOT/profiles/settings/lib.sh"
# shellcheck source=profiles/settings/435150/candidates.sh
. "$ROOT/profiles/settings/435150/candidates.sh"

dos2_restore() {   # the player's file back from the pending backup; refused while the game runs
  local b
  [ -f "$DOS2_PENDING" ] || return 0
  if pgrep -f "$GAME_PROC" >/dev/null; then
    echo "warning: $GAME_NAME is running; its settings stay as they are" >&2
    return 1
  fi
  read -r b < "$DOS2_PENDING"
  cp -p "$b" "$DOS2_CFG" && rm -f "$DOS2_PENDING" && echo "restored the player's graphicSettings.lsx from $b"
}

game_prepare() {   # $1 run dir; runs with the game closed (the game rewrites the file when it exits)
  local b
  local -a keys
  dos2_restore || die "an earlier candidate's settings are still in place (see above)"
  [ -n "${DOS2_CANDIDATE:-}" ] || return 0
  case $DOS2_CANDIDATE in
    A) keys=("${DOS2_A[@]}") ;;
    B) keys=("${DOS2_B[@]}") ;;
    *) die "DOS2_CANDIDATE=$DOS2_CANDIDATE: A or B" ;;
  esac
  [ -f "$DOS2_CFG" ] || die "no $DOS2_CFG: launch the game once first"
  mkdir -p "$SG_DATA/launch"
  b=$(sg_backup "$APPID" "$DOS2_CFG" "bench run $DOS2_CANDIDATE") || die "backup failed"
  echo "$b" > "$DOS2_PENDING"
  python3 -I "$ROOT/profiles/settings/lsx_set.py" "$DOS2_CFG" "${keys[@]}" || die "candidate $DOS2_CANDIDATE not applied"
  cp "$DOS2_CFG" "$1/graphicSettings.lsx"
  echo "candidate $DOS2_CANDIDATE applied for this run (the player's file: $b)"
}

game_cleanup() {   # EXIT trap of bench/run.sh: wait for the game to close, then the player's file back
  [ -f "$DOS2_PENDING" ] || return 0
  for _ in $(seq 30); do pgrep -f "$GAME_PROC" >/dev/null || break; sleep 1; done
  dos2_restore || true
}
