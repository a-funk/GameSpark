#!/bin/bash
# Pair a Bluetooth game controller: Xbox Wireless Controller, DualSense (PS5) or DualShock 4.
# Put it in pairing mode, then run: controller/pair.sh [--reset] [NAME|MAC]
#   Xbox: hold the pair button until the logo flashes fast. DualSense / DualShock 4: hold Create (Share) + PS until
#   the light bar double-flashes.
# NAME is an extended regex matched against advertised names (default: any of the above). Controllers that are
# already paired are left alone, so a second pad can be added while the first is in use; a MAC re-pairs that device.
# --reset power-cycles the radio first: the GB10's MediaTek radio sometimes stops hearing anything (a 20 s scan sees
# no devices at all), but the reset also drops connected controllers.
# Needs /etc/bluetooth/main.conf: Privacy = device, JustWorksRepairing = always (see controller/README.md).
RESET=; [ "${1:-}" = --reset ] && { RESET=1; shift; }
ARG=${1:-}; MAC=; NAME='Xbox Wireless Controller|DualSense|Wireless Controller'
if [[ $ARG =~ ^([0-9A-F]{2}:){5}[0-9A-F]{2}$ ]]; then MAC=$ARG; elif [ -n "$ARG" ]; then NAME=$ARG; fi
if [ -n "$RESET" ]; then bluetoothctl power off >/dev/null 2>&1; sleep 2; bluetoothctl power on >/dev/null 2>&1; sleep 2; fi
[ -n "$MAC" ] && bluetoothctl remove "$MAC" >/dev/null 2>&1
# A non-pairable adapter pairs without bonding (no stored link key), and BlueZ then rejects the controller's input
# (ClassicBondedOnly). Allow pairing for this run only.
bluetoothctl pairable on >/dev/null; trap 'bluetoothctl pairable off >/dev/null' EXIT
bluetoothctl --timeout 120 scan on >/dev/null 2>&1 &
SCAN=$!
for i in $(seq 1 115); do
  if [ -z "$MAC" ]; then
    for m in $(bluetoothctl devices | grep -E "$NAME" | awk '{print $2}'); do
      bluetoothctl info "$m" | grep -q "Paired: yes" || { MAC=$m; break; }
    done
  fi
  [ -n "$MAC" ] && bluetoothctl info "$MAC" >/dev/null 2>&1 && break
  sleep 1
done
[ -n "$MAC" ] && bluetoothctl info "$MAC" >/dev/null 2>&1 || { kill $SCAN; echo "not seen: put the controller in pairing mode and retry (--reset if nothing is ever found)"; exit 1; }
echo "found $MAC ($(bluetoothctl info "$MAC" | sed -n 's/^\tName: //p')) after ${i}s"
kill $SCAN 2>/dev/null; bluetoothctl scan off >/dev/null 2>&1
# Pair with an agent registered (and the adapter pairable, above): otherwise the link key is not stored ("Bonded: no")
# and a DualSense connects but never shows up as an input device.
bluetoothctl --agent NoInputNoOutput --timeout 20 pair "$MAC" 2>&1 | grep -E "Pairing successful|Failed|Error" | tail -1
bluetoothctl info "$MAC" | grep -q "Bonded: yes" || echo "warning: paired but not bonded; input will be rejected (retry pairing)"
bluetoothctl trust "$MAC" | tail -1
bluetoothctl --timeout 15 connect "$MAC" 2>&1 | grep -E "Connection successful|Failed|Error" | tail -1
sleep 3
bluetoothctl info "$MAC" | grep -E "Name|Paired|Bonded|Trusted|Connected"
