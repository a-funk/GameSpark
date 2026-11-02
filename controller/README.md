# Xbox controller on the DGX Spark

Xbox Series controllers with firmware 5.x pair over Bluetooth Low Energy. On the Spark (MediaTek MT7925
radio, BlueZ 5.72) they pair and encrypt with stock settings, but the logo keeps flashing, no input
arrives, and the link drops after about two minutes. Pairing with Bluetooth privacy on fixes it, and
`controller/pair.sh` turns privacy on only while it pairs an Xbox pad. Left on, privacy broke reconnects for
an Apple Siri Remote used as the TV remote (46 of 47 attempts failed with HCI error 0x3E).

```ini
# /etc/bluetooth/main.conf
[General]
Privacy = off
JustWorksRepairing = always

[LE]
MinConnectionInterval=7
MaxConnectionInterval=9
ConnectionLatency=0
```

Restart BlueZ (`sudo systemctl restart bluetooth`), hold the controller's pair button until the logo
flashes fast, then run `controller/pair.sh`. Privacy can only change while the radio is off, so pairing an
Xbox pad drops other connected devices twice; they reconnect on their next button press. The switch needs
root: passwordless sudo or the docker group. Check input with `python3 -I controller/xbox-watch.py 30`.

Measured during bring-up (btmon): with stock settings the controller sent zero input notifications; with
`Privacy = device` and a fresh pairing, 949 notifications in the first minute. The connection interval
settings come from the
[xpadneo troubleshooting guide](https://github.com/atar-axis/xpadneo/blob/master/docs/TROUBLESHOOTING.md)
and did not fix input on their own. `JustWorksRepairing = always` changed at the same time, but it only
applies when a device that is still paired pairs again, and the pairing script had removed the old pairing.

Why privacy matters only while pairing: Linux hands a device the Spark's identity key (IRK and identity
address) during pairing only when privacy is on (`net/bluetooth/smp.c`: `HCI_PRIVACY` adds
`SMP_DIST_ID_KEY`). Afterwards the Spark connects from its public address, which is the identity address
the pad stored. `pair.sh` hands over BlueZ's own key from `/var/lib/bluetooth/<adapter>/identity`, the one
BlueZ uses when main.conf turns privacy on. Still to confirm on the Spark: a pad paired with privacy on
reconnecting, with input, after privacy is off again.

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

## DualSense haptics (USB)

A DualSense's haptics are audio: on USB the pad is also a 4-channel sound card, channels 1-2 for its speaker and
3-4 for the two haptic actuators. Games that use Sony's libScePad (e.g. CONTROL Resonant) find it through Proton's
"Wireless Controller" audio device and play haptics there; over Bluetooth there is no such device. Measured with
CONTROL Resonant (profiles/launch/3669870.env): on Bluetooth adaptive triggers work but the game sends no vibration
at all; on USB both work, as long as the pad is on USB before the game starts.

- **Plugging in a Bluetooth-connected pad.** The kernel refuses the USB pad as a duplicate of the Bluetooth one
  ("Duplicate device found for MAC address"), so games keep the Bluetooth link. `61-gamespark-dualsense-usb.rules`
  runs `dualsense-usb.sh`, which drops the Bluetooth link and re-probes the USB interface. Unplug and press PS to go
  back to Bluetooth.
- **Audio stays on the TV.** Games open their own stream to the pad; `51-gamespark-dualsense-not-default.lua` keeps
  WirePlumber from ever choosing the pad as the default output (takes effect at the next login).
- Both are installed by `system/fex-system.sh controllers`. To check haptics reach the pad while a game runs, record
  the pad's sink (`pw-record --target alsa_output.usb-Sony_Interactive_Entertainment_DualSense_Wireless_Controller-00.analog-surround-40
  -P stream.capture.sink=true --channels 4 --channel-map FL,FR,RL,RR out.wav`): haptics are channels 3-4, mostly
  below 300 Hz.
