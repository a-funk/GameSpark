#!/bin/bash
# Run as root by 61-gamespark-dualsense-usb.rules when a DualSense's USB HID interface appears (argument: the USB
# interface, e.g. 3-1:1.3). A pad still connected over Bluetooth makes the kernel's playstation driver refuse the USB
# one ("Duplicate device found for MAC address ..."), so games keep the Bluetooth link, which has no haptics: those
# are a 4-channel USB audio stream (channels 3-4) that only exists on the cable. Drop the Bluetooth link and probe the
# USB interface again. Unplugging the cable and pressing PS reconnects over Bluetooth as usual.
set -u
intf=${1:?usage: $0 <usb interface, e.g. 3-1:1.3>}
sys=/sys/bus/usb/devices/$intf
# Not a virtual pad on USB/IP (vhci_hcd): leave Bluetooth alone.
case $(readlink -f "$sys") in */vhci_hcd.*) exit 0 ;; esac
sleep 1   # let the first probe finish and log
ls "$sys"/*/hidraw >/dev/null 2>&1 && exit 0   # the USB pad was accepted: nothing to do
mac=$(journalctl -k --since "-30s" --no-pager -o cat 2>/dev/null |
  sed -n 's/.*Duplicate device found for MAC address \([0-9a-fA-F:]\{17\}\).*/\1/p' | tail -1)
[ -n "$mac" ] || { logger -t gamespark "DualSense on $intf has no hidraw and no duplicate-MAC message; left alone"; exit 0; }
bluetoothctl disconnect "$mac" >/dev/null 2>&1
for _ in 1 2 3 4 5; do   # the playstation driver frees the MAC only once the Bluetooth device is gone
  grep -qsi "HID_UNIQ=$mac" /sys/class/hidraw/*/device/uevent || break; sleep 0.5
done
echo "$intf" > /sys/bus/usb/drivers/usbhid/unbind 2>/dev/null
echo "$intf" > /sys/bus/usb/drivers/usbhid/bind
ls "$sys"/*/hidraw >/dev/null 2>&1 && r=ok || r=FAILED
logger -t gamespark "DualSense $mac: Bluetooth link dropped for USB on $intf: $r"
