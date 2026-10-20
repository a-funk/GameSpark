#!/bin/bash
# Record a player's STAR WARS: Galactic Racer races for the replay benchmark (bench/games/galacticracer.sh,
# GR_ROUTE=replay): the DualSense's raw input (Bluetooth) and a 440x200 screen strip at 30 fps, which holds the race
# clock and the letterbox edges replays anchor on. A full-screen capture made the game feel laggy; this strip did not.
#   bench/gr-record.sh start    then race Arcade events; menus, restarts and retries are fine
#   bench/gr-record.sh stop     end the recording and cut each finished race into $SG_DATA/gr-inputs/races
#   bench/gr-record.sh status
# Each race file still needs its event notes before the bench can reach it (tools/padreplay.py note).
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); . "$ROOT/lib/env.sh"
IN=$SG_DATA/gr-inputs RACES=$SG_DATA/gr-inputs/races
PR=$ROOT/tools/padreplay.py
# gr_strip, gr_slow_cpus, GR_LOCAL
# shellcheck source=bench/games/galacticracer.sh
. "$ROOT/bench/games/galacticracer.sh"
cur=$(cat "$IN/current" 2>/dev/null)
alive() { [ -s "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null; }

pad_node() {  # the player's DualSense on Bluetooth (not a replay's virtual one)
  local h
  for h in /sys/class/hidraw/hidraw*; do
    grep -qs "HID_ID=0005:0000054C:00000CE6" "$h/device/uevent" || continue
    [[ $(realpath "$h/device") == */virtual/misc/uhid/* ]] && continue
    echo "/dev/${h##*/}"; return 0
  done
  return 1
}

case "${1:-status}" in
  start)
    [ -n "$cur" ] && alive "$cur/padrec.pid" && die "already recording into $cur (bench/gr-record.sh stop)"
    dev=$(pad_node) || die "no DualSense on Bluetooth (a USB pad sends other reports: replays need Bluetooth)"
    cur=$IN/$(date +%Y%m%d-%H%M%S); mkdir -p "$cur"; echo "$cur" > "$IN/current"
    date +%s%N > "$cur/started"
    # Both on the A725 cores the game leaves alone; 4 h at most.
    setsid nohup taskset -c "$(gr_slow_cpus)" python3 -I "$PR" record "$dev" "$cur/pad.rec" 14400 \
      > "$cur/padrec.log" 2>&1 < /dev/null & echo $! > "$cur/padrec.pid"
    size=$(gr_strip); xy=${size#*+}
    setsid nohup timeout -s INT 14400 taskset -c "$(gr_slow_cpus)" nice -n 10 ffmpeg -nostdin -loglevel error \
      -use_wallclock_as_timestamps 1 -f x11grab -framerate 30 -video_size "${size%%+*}" -i "$DISPLAY+${xy/+/,}" \
      -c:v libx264 -preset ultrafast -crf 10 -copyts "$cur/hud.mkv" > "$cur/hud.log" 2>&1 < /dev/null & echo $! > "$cur/hud.pid"
    sleep 3
    alive "$cur/padrec.pid" && alive "$cur/hud.pid" || { cat "$cur"/*.log; die "recording did not start"; }
    echo "recording $dev and the screen strip ($size) into $cur" ;;
  stop)
    [ -n "$cur" ] || die "nothing recorded yet"
    for p in hud padrec; do alive "$cur/$p.pid" && kill -INT "$(cat "$cur/$p.pid")"; done   # both close their files on INT
    for _ in $(seq 20); do alive "$cur/padrec.pid" || alive "$cur/hud.pid" || break; sleep 0.5; done
    rm -f "$cur/padrec.pid" "$cur/hud.pid" "$IN/current"
    # Map loads from the game's crash-reporter breadcrumbs (every session since the start): "ns map" lines.
    cat "$GR_LOCAL"/.sentry-native/*.run/__sentry-breadcrumb* 2>/dev/null | LC_ALL=C tr -c '[:print:]' '\n' | awk '
      /^20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T/ { t = $0 } /PostLoadMapWithWorld/ { want = 1; next }
      want && /^L_/ { print t, $0; want = 0 }' | sort -u | python3 -I -c '
import datetime, sys
since = int(open(sys.argv[1]).read()) - 60_000_000_000
for l in sys.stdin:
    t, m = l.split()
    ns = round(datetime.datetime.fromisoformat(t.replace("Z", "+00:00")).timestamp() * 1e9)
    if ns >= since: print(ns, m)' "$cur/started" > "$cur/loads.txt"
    taskset -c "$(gr_slow_cpus)" nice -n 10 python3 -I "$PR" edges "$cur/hud.mkv" > "$cur/edges.json" 2>/dev/null \
      || die "could not read the screen strip $cur/hud.mkv"
    mkdir -p "$RACES"
    echo "$(wc -l < "$cur/loads.txt") map loads, $(python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$cur/edges.json") letterbox edges; races:"
    python3 -I "$PR" races "$cur/pad.rec" "$cur/edges.json" "$cur/loads.txt" "$RACES" 'L_FrontEnd' | tee "$cur/races.txt"
    build=$(gr_buildid)   # a game update can change the tracks: the bench warns when the build differs
    cut -d: -f1 "$cur/races.txt" | while read -r r; do python3 -I "$PR" note "$r" "buildid=$build" >/dev/null; done
    echo "next: name each race's event (tools/padreplay.py note RACE event_keys=... event_re=...)" ;;
  status)
    if [ -n "$cur" ] && alive "$cur/padrec.pid"; then
      echo "recording into $cur: $(du -h "$cur/pad.rec" | cut -f1) input, $(du -h "$cur/hud.mkv" | cut -f1) strip"
    else echo "not recording"; fi
    ls "$RACES" 2>/dev/null | sed 's/^/race: /' ;;
  *) die "usage: $0 start|stop|status" ;;
esac
