"""Log controller input and Bluetooth link changes, to check that a pad actually delivers input.
Usage: python3 -I controller/xbox-watch.py [seconds] [MAC]   (MAC defaults to the paired "Xbox Wireless Controller")"""
import struct, time, select, glob, subprocess, sys
mac = sys.argv[2] if len(sys.argv) > 2 else next((l.split()[1] for l in subprocess.run(["bluetoothctl", "devices", "Paired"], capture_output=True, text=True).stdout.splitlines() if "Xbox" in l), "")
P = "/org/bluez/hci0/dev_" + mac.replace(":", "_")
def state():
    g = lambda k: subprocess.run(["busctl", "get-property", "org.bluez", P, "org.bluez.Device1", k], capture_output=True, text=True).stdout[2:3]
    return f"connected={g('Connected')} resolved={g('ServicesResolved')}"
end = time.time() + float(sys.argv[1] if len(sys.argv) > 1 else 300)
f = None; last = None; n = 0; tick = 0
while time.time() < end:
    if time.time() - tick > 1:
        tick = time.time(); s = state()
        if s != last: print(time.strftime("%T"), s, flush=True); last = s
    if f is None:
        js = sorted(glob.glob("/dev/input/js*"))
        if js:
            try: f = open(js[0], "rb", buffering=0)
            except OSError: f = None
        if f is None: time.sleep(0.5); continue
    try:
        r, _, _ = select.select([f], [], [], 0.5)
        if not r: continue
        t, val, typ, num = struct.unpack("IhBB", f.read(8))
    except OSError:
        f = None; continue  # device vanished on disconnect
    if typ & 0x80: continue
    n += 1
    if n <= 15 or n % 100 == 0:
        print(time.strftime("%T"), "INPUT", "button" if typ == 1 else "axis", num, val, f"(total {n})", flush=True)
print("done, total input events:", n)
