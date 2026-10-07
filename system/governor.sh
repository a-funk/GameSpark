#!/bin/bash
# Per-game scheduler governor: watches for running games and applies each game's scheduler profile.
# A profile is profiles/<game>.conf (SCHED=bpfland|default), where <game> names a bench/games/<game>.sh adapter
# (its GAME_PROC pattern identifies the running game). No game running -> the kernel's default scheduler.
# Measured: scx_bpfland -m performance is +10% in Cyberpunk 2077 and -3% in Rise of the Tomb Raider.
#
# Usage: system/governor.sh run          foreground loop (what the service runs)
#        system/governor.sh install      systemd user service, starts now and at login
#        system/governor.sh uninstall | status
#        system/governor.sh set bpfland|default   switch now (pause the loop first, or it switches back)
# Pause (e.g. for scheduler A/B benchmarks): touch $SG_DATA/governor.pause
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); . "$ROOT/lib/env.sh"
NAME=gamespark-scx
UNIT=$HOME/.config/systemd/user/gamespark-governor.service

scx_running() { docker ps -q --filter "name=^$NAME$" | grep -q .; }
apply() {   # $1 = bpfland|default
  if [ "$1" = bpfland ] && ! scx_running; then
    docker rm -f "$NAME" >/dev/null 2>&1
    docker run -d --name "$NAME" --privileged --pid=host alpine nsenter -t 1 -m -u -i -n -p -- scx_bpfland -m performance >/dev/null
  elif [ "$1" = default ] && scx_running; then
    docker rm -f "$NAME" >/dev/null
  fi
}

wanted() {  # scheduler for the first profiled game that is running, else default
  local conf game SCHED GAME_PROC
  for conf in "$ROOT"/profiles/*.conf; do
    game=$(basename "$conf" .conf); SCHED=default
    # shellcheck source=/dev/null
    . "$conf"
    # shellcheck source=/dev/null
    GAME_PROC=$(. "$ROOT/bench/games/$game.sh"; echo "$GAME_PROC")
    pgrep -f "$GAME_PROC" >/dev/null && { echo "$SCHED $game"; return; }
  done
  echo "default none"
}

case "${1:-status}" in
  run)
    last=""
    while true; do
      if [ ! -e "$SG_DATA/governor.pause" ]; then
        read -r sched game <<<"$(wanted)"
        [ "$sched $game" != "$last" ] && { apply "$sched"; echo "$(date +%T) $game -> $sched"; last="$sched $game"; }
      fi
      sleep 3
    done ;;
  install)
    mkdir -p "$(dirname "$UNIT")" "$SG_DATA"
    printf '[Unit]\nDescription=GameSpark per-game scheduler governor\n\n[Service]\nExecStart=%s run\nRestart=on-failure\n\n[Install]\nWantedBy=default.target\n' \
      "$ROOT/system/governor.sh" > "$UNIT"
    systemctl --user daemon-reload && systemctl --user enable --now gamespark-governor.service && "$0" status ;;
  uninstall)
    systemctl --user disable --now gamespark-governor.service; rm -f "$UNIT"; apply default; echo removed ;;
  status)
    echo "service: $(systemctl --user is-active gamespark-governor.service 2>/dev/null)"
    echo "sched_ext: $(cat /sys/kernel/sched_ext/state) $(cat /sys/kernel/sched_ext/root/ops 2>/dev/null)"
    [ -e "$SG_DATA/governor.pause" ] && echo "paused ($SG_DATA/governor.pause)"
    for c in "$ROOT"/profiles/*.conf; do echo "profile $(basename "$c" .conf): $(grep -h '^SCHED=' "$c")"; done ;;
  set)
    case "${2:-}" in bpfland|default) apply "$2"; echo "scheduler: $2" ;; *) die "usage: $0 set bpfland|default" ;; esac ;;
  *) die "usage: $0 run|install|uninstall|status|set" ;;
esac
