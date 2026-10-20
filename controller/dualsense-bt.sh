#!/bin/bash
# DualSense haptics over Bluetooth for games that play them as USB audio (CONTROL Resonant). Two halves:
# libdualsense-bt.so (dualsense-bt.c), LD_PRELOADed into the game, shows the Bluetooth pad to Proton as a USB one;
# dualsense-bt-haptics.py gives it a stand-in USB sound card and sends what the game plays there to the pad as
# Bluetooth haptics. Profiles turn it on with DUALSENSE_BT_HAPTICS=1 (tools/launch.sh runs "start").
#   controller/dualsense-bt.sh build       compile the library (x86-64 cross compiler: apt install
#                                          gcc-x86-64-linux-gnu libc6-dev-amd64-cross) and run its self-test
#   controller/dualsense-bt.sh start PID   with the pad on Bluetooth: haptics until PID exits, then print the library
#                                          for LD_PRELOAD; otherwise print why not and exit 1 (pad on USB: haptics
#                                          work natively there)
#   controller/dualsense-bt.sh status
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); . "$ROOT/lib/env.sh"
OUT=$SG_DATA/dualsense
LIB=$OUT/libdualsense-bt.so
UNIT=gamespark-dualsense-haptics
pad_on() { grep -qs "HID_ID=$1:0000054C:00000CE6" /sys/class/hidraw/*/device/uevent; }

case "${1:-status}" in
  build)
    command -v x86_64-linux-gnu-gcc >/dev/null ||
      die "needs the x86-64 cross compiler: sudo apt install gcc-x86-64-linux-gnu libc6-dev-amd64-cross"
    mkdir -p "$OUT"
    { echo "static const unsigned char usb_rdesc[] = {"; od -An -v -tx1 "$ROOT/controller/dualsense-usb.rdesc" |
        sed 's/ \([0-9a-f][0-9a-f]\)/0x\1,/g'; echo "};"; } > "$OUT/dualsense-usb-rdesc.h"
    flags=(-O2 -Wall -Wextra -fPIC -I"$OUT" "$ROOT/controller/dualsense-bt.c")
    x86_64-linux-gnu-gcc -shared "${flags[@]}" -o "$LIB.new" -ldl &&
      x86_64-linux-gnu-gcc -DSELFTEST "${flags[@]}" -o "$OUT/selftest" -ldl &&
      FEX "$OUT/selftest" && mv "$LIB.new" "$LIB" && echo "built $LIB" ;;
  start)
    pid=${2:?usage: $0 start PID}
    [ -f "$LIB" ] || { echo "not built ($0 build)"; exit 1; }
    pad_on 0003 && { echo "the pad is on USB (haptics work natively)"; exit 1; }
    pad_on 0005 || { echo "no DualSense on Bluetooth"; exit 1; }
    : > "$OUT/shim.log"   # tools/launch.sh points DUALSENSE_BT_LOG here
    # A user unit, outside the game's process tree: Steam's reaper waits for every process under it.
    systemctl --user stop "$UNIT" 2>/dev/null
    # DUALSENSE_HAPTICS_GAIN (a profile line, default 1.0) scales the haptics; a user unit does not inherit our env.
    systemd-run --user --quiet --collect --unit="$UNIT" --setenv=DUALSENSE_HAPTICS_GAIN="${DUALSENSE_HAPTICS_GAIN:-1.0}" \
      python3 -I "$ROOT/controller/dualsense-bt-haptics.py" run --while-pid "$pid" || { echo "could not start $UNIT"; exit 1; }
    for _ in $(seq 30); do   # Proton lists the sound cards when the game starts: the stand-in must be there
      pw-cli ls Node 2>/dev/null | grep -q "gamespark.dualsense-bt-haptics" && { echo "$LIB"; exit 0; }
      sleep 0.1
    done
    echo "the haptics sink did not appear (journalctl --user -u $UNIT)"; exit 1 ;;
  status)
    echo "library: $([ -f "$LIB" ] && echo "$LIB" || echo "not built ($0 build)")"
    echo "pad: $(pad_on 0005 && echo Bluetooth || { pad_on 0003 && echo USB || echo "not connected"; })"
    echo "haptics: $(systemctl --user is-active "$UNIT" 2>/dev/null)"
    if [ -s "$OUT/shim.log" ]; then
      echo "last launch: $(grep -c "reads bus USB" "$OUT/shim.log") HID reads as USB," \
        "$(grep -c "shown as a USB pad" "$OUT/shim.log") pad opens converted ($OUT/shim.log)"
    fi ;;
  *) die "usage: $0 build|start PID|status" ;;
esac
