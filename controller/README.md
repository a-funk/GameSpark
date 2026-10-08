# Xbox controller on the DGX Spark

Xbox Series controllers with firmware 5.x pair over Bluetooth Low Energy. On the Spark (MediaTek MT7925
radio, BlueZ 5.72) they pair and encrypt with stock settings, but the logo keeps flashing, no input
arrives, and the link drops after about two minutes. Two BlueZ settings fix it:

```ini
# /etc/bluetooth/main.conf
[General]
Privacy = device
JustWorksRepairing = always

[LE]
MinConnectionInterval=7
MaxConnectionInterval=9
ConnectionLatency=0
```

Restart BlueZ (`sudo systemctl restart bluetooth`), hold the controller's pair button until the logo
flashes fast, then run `controller/pair.sh`. Check input with `python3 -I controller/xbox-watch.py 30`.

Measured during bring-up (btmon): before the change the controller sent zero input notifications; after
it, 949 notifications in the first minute. The connection interval settings come from the
[xpadneo troubleshooting guide](https://github.com/atar-axis/xpadneo/blob/master/docs/TROUBLESHOOTING.md)
and did not fix input on their own; `Privacy = device` with a fresh pairing did. We changed the two
`[General]` settings together, so we can't say which one fixed it.

Known quirks:
- Holding the pair button wipes the controller's side of the bond; the Spark then logs
  `PIN or Key Missing` until you pair again.
- The MT7925 radio occasionally stops hearing any device (`bluetoothctl scan on` finds nothing).
  `bluetoothctl power off; bluetoothctl power on` clears it; `pair.sh --reset` does this first (and drops connected pads).
- A USB-C cable always works (kernel `xpad` driver), with no pairing at all.

## Steam Big Picture

Steam reads a Bluetooth Xbox pad through raw HID only if the desktop user can open its hidraw node; otherwise it
falls back to evdev. On the Spark the 32-bit Steam client runs under FEX, which hands it the kernel's 64-bit
`input_event` layout, so every evdev event is misread: in Big Picture the sticks and D-pad do nothing, while games
(64-bit Wine) work. `system/fex-system.sh controllers` installs `60-gamespark-xbox-hidraw.rules`, after which the
FEX Steam opens the pad as raw HID like the DualSense. Restart Steam (or reconnect the pad) once afterwards.

- The snap Steam has no hidraw access, so use the FEX Steam for Big Picture (`system/console-mode.sh enable fex`).
- `python3 -I controller/evdev32_check.py` checks the FEX behaviour: exit 1 while FEX passes 24-byte events, 0 once
  a FEX release converts them (then the rule is no longer needed).
- Wired Xbox pads (kernel `xpad`) have no hidraw node and still go through evdev.
