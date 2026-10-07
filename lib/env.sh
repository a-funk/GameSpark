# Shared paths and helpers for spark-gaming scripts. Source it; every variable can be overridden from the environment.
# Defaults target Canonical's arm64 Steam snap on DGX OS (Ubuntu 24.04, GNOME on Xorg).

: "${STEAM_HOME:=$HOME/snap/steam/common}"                 # snap's $HOME for Steam
: "${STEAM_ROOT:=$STEAM_HOME/.local/share/Steam}"
: "${STEAM_PIPE:=$STEAM_HOME/.steam/steam.pipe}"            # the snap launcher drops CLI args; commands go through this pipe
: "${STEAM_LOG:=$STEAM_ROOT/logs/console_log.txt}"
: "${FEX_CONFIG_DIR:=$STEAM_HOME/fex_config}"
: "${SNAP_TMP:=/tmp/snap-private-tmp/snap.steam/tmp}"      # where the snap (and FEX inside it) sees /tmp
: "${SG_DATA:=$HOME/.local/share/spark-gaming}"            # run records, profiles, screenshots
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

# Launch an app and confirm Steam accepted it (it silently drops pipe commands while loading). Retries 4x.
steam_launch() {
  local appid=$1 args=$2 before attempt i
  for attempt in 1 2 3 4; do
    before=$(grep -c "Game process added : AppID $appid" "$STEAM_LOG" 2>/dev/null)
    steam_cmd "-applaunch $appid $args"
    for i in $(seq 20); do
      [ "$(grep -c "Game process added : AppID $appid" "$STEAM_LOG" 2>/dev/null)" -gt "${before:-0}" ] && return 0
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
