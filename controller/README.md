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
flashes fast, then run `controller/pair-xbox.sh`. Check input with `python3 -I controller/xbox-watch.py 30`.

Measured during bring-up (btmon): before the change the controller sent zero input notifications; after
it, 949 notifications in the first minute. The connection interval settings come from the
[xpadneo troubleshooting guide](https://github.com/atar-axis/xpadneo/blob/master/docs/TROUBLESHOOTING.md)
and did not fix input on their own; `Privacy = device` with a fresh pairing did. We changed the two
`[General]` settings together, so we can't say which one fixed it.

Known quirks:
- Holding the pair button wipes the controller's side of the bond; the Spark then logs
  `PIN or Key Missing` until you pair again.
- The MT7925 radio occasionally stops hearing any device (`bluetoothctl scan on` finds nothing).
  `bluetoothctl power off; bluetoothctl power on` clears it; `pair-xbox.sh` does this first.
- A USB-C cable always works (kernel `xpad` driver), with no pairing at all.
