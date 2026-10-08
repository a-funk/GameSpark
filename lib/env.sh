# shellcheck shell=bash
# Shared paths and helpers for GameSpark scripts. Source it; every variable can be overridden from the environment.
# Two Steam setups on DGX OS (Ubuntu 24.04, GNOME on Xorg), chosen with GAMESPARK_STEAM:
#   snap  Canonical's arm64 Steam snap with its bundled FEX
#   fex   Valve's Steam launcher under a system FEX (system/fex-system.sh), sharing the snap's Steam folder
# Unset: whichever is running, else snap.

steam_setup() {   # the running Steam's setup: Valve's launcher runs as the system FEX binary
  local p; p=$(pgrep -f "[u]buntu12_32/steam " | head -1)
  if [ -n "$p" ] && [ "$(readlink "/proc/$p/exe")" = /usr/bin/FEX ]; then echo fex; else echo snap; fi
}
: "${GAMESPARK_STEAM:=$(steam_setup)}"
if [ "$GAMESPARK_STEAM" = fex ]; then
  : "${STEAM_HOME:=$HOME}"
  : "${FEX_CONFIG_DIR:=${XDG_CONFIG_HOME:-$HOME/.config}/fex-emu}"
  : "${SNAP_TMP:=/tmp}"
  : "${STEAM_START:=FEX /bin/bash /usr/lib/steam/bin_steam.sh}"
else
  : "${STEAM_HOME:=$HOME/snap/steam/common}"               # snap's $HOME for Steam
  : "${FEX_CONFIG_DIR:=$STEAM_HOME/fex_config}"
  : "${SNAP_TMP:=/tmp/snap-private-tmp/snap.steam/tmp}"    # where the snap (and FEX inside it) sees /tmp
  : "${STEAM_START:=snap run steam}"
fi
: "${STEAM_ROOT:=$STEAM_HOME/.local/share/Steam}"
: "${STEAM_PIPE:=$STEAM_HOME/.steam/steam.pipe}"            # the snap launcher drops CLI args; commands go through this pipe
: "${STEAM_LOG:=$STEAM_ROOT/logs/console_log.txt}"
: "${SG_DATA:=$HOME/.local/share/gamespark}"            # run records, profiles, screenshots
: "${QUIET_LOCKS:=}"                                       # colon-separated flock files held during runs (pause cron jobs)

uid=$(id -u)
: "${DISPLAY:=:1}" "${XAUTHORITY:=/run/user/$uid/gdm/Xauthority}"
: "${XDG_RUNTIME_DIR:=/run/user/$uid}" "${DBUS_SESSION_BUS_ADDRESS:=unix:path=/run/user/$uid/bus}"
export DISPLAY XAUTHORITY XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS

die() { echo "error: $*" >&2; exit 1; }

# Fast CPUs as a taskset list: capacity above the midpoint of min and max. GB10 reports 997-1024 for its
# Cortex-X925 cores and 718-731 for its Cortex-A725 cores, so "equal to max" would pick a single core.
fast_cpus() {
  local caps
  caps=$(for c in /sys/devices/system/cpu/cpu[0-9]*; do echo "${c##*cpu} $(cat "$c/cpu_capacity" 2>/dev/null || echo 1)"; done)
  echo "$caps" | sort -n | awk '{cpu[NR]=$1; cap[NR]=$2; if (NR==1||$2<lo) lo=$2; if ($2>hi) hi=$2}
    END {for (i=1;i<=NR;i++) if (hi==lo || cap[i] > (lo+hi)/2) out = out (out?",":"") cpu[i]; print out}'
}

# Run a command as root: directly, via passwordless sudo, or via a privileged container (docker group).
as_root() {
  if [ "$uid" = 0 ]; then "$@"
  elif sudo -n true 2>/dev/null; then sudo "$@"
  else docker run --rm --privileged --pid=host -v /tmp:/tmp alpine nsenter -t 1 -m -u -i -n -p -- "$@"
  fi
}

steam_running() { pgrep -f "[u]buntu12_32/steam " >/dev/null; }

# Send a command to the running Steam client.
steam_cmd() { timeout 10 sh -c 'printf "%s\n" "$1" > "$2"' _ "$1" "$STEAM_PIPE"; }

# Launch an app and confirm Steam received the command (it silently drops pipe commands while loading). Retries 4x.
# Confirms on Steam's ExecCommandLine log line, not on the game process: that can take over 20 s to appear (first-run
# install scripts take minutes), and a retry while the game starts would send a second launch.
steam_launch() {
  local appid=$1 args=$2 before attempt seen="ExecCommandLine: \"-applaunch $1 "
  for attempt in 1 2 3 4; do
    before=$(grep -cF "$seen" "$STEAM_LOG" 2>/dev/null)
    steam_cmd "-applaunch $appid $args"
    for _ in $(seq 20); do
      [ "$(grep -cF "$seen" "$STEAM_LOG" 2>/dev/null)" -gt "${before:-0}" ] && return 0
      sleep 1
    done
    echo "launch not accepted (attempt $attempt), retrying" >&2
  done
  return 1
}

# A Proton prefix's Windows user directory for an app.
compat_user() { echo "$STEAM_ROOT/steamapps/compatdata/$1/pfx/drive_c/users/steamuser"; }

# Hold each lock in $QUIET_LOCKS for the life of the calling shell (non-blocking; warns if busy).
hold_quiet_locks() {
  local f fd
  for f in ${QUIET_LOCKS//:/ }; do
    exec {fd}>"$f" && flock -n "$fd" || echo "warning: could not take quiet lock $f" >&2
  done
}
