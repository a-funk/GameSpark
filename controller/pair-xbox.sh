#!/bin/bash
# Pair (or re-pair) an Xbox Wireless Controller over Bluetooth.
# Hold the controller's pair button until the logo flashes fast, then run: controller/pair-xbox.sh [MAC]
# Without MAC, the first advertising device named "Xbox Wireless Controller" is used.
# Needs /etc/bluetooth/main.conf: Privacy = device, JustWorksRepairing = always (see controller/README.md).
MAC=${1:-}
# The GB10's MediaTek radio sometimes stops hearing anything; a power cycle clears it.
bluetoothctl power off >/dev/null 2>&1; sleep 2; bluetoothctl power on >/dev/null 2>&1; sleep 2
[ -n "$MAC" ] && bluetoothctl remove "$MAC" >/dev/null 2>&1
bluetoothctl --timeout 120 scan on >/dev/null 2>&1 &
SCAN=$!
for i in $(seq 1 115); do
  if [ -z "$MAC" ]; then
    MAC=$(bluetoothctl devices | awk '/Xbox Wireless Controller/ {print $2; exit}')
    [ -n "$MAC" ] && bluetoothctl info "$MAC" | grep -q "Paired: yes" && { bluetoothctl remove "$MAC" >/dev/null; MAC=""; }
  fi
  [ -n "$MAC" ] && bluetoothctl info "$MAC" >/dev/null 2>&1 && break
  sleep 1
done
[ -n "$MAC" ] && bluetoothctl info "$MAC" >/dev/null 2>&1 || { kill $SCAN; echo "not seen: hold the pair button until the logo flashes fast, then retry"; exit 1; }
echo "found $MAC after ${i}s"
kill $SCAN 2>/dev/null; bluetoothctl scan off >/dev/null 2>&1
bluetoothctl --timeout 20 pair "$MAC" 2>&1 | grep -E "Pairing successful|Failed|Error" | tail -1
bluetoothctl trust "$MAC" | tail -1
bluetoothctl --timeout 15 connect "$MAC" 2>&1 | grep -E "Connection successful|Failed|Error" | tail -1
sleep 3
bluetoothctl info "$MAC" | grep -E "Paired|Trusted|Connected"
