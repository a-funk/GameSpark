"""Virtual Xbox 360 controller (Linux uinput), for games that only take gamepad input in some screens (DOS2 shows
a controller-only interface while a controller is connected). Games under Proton see it like a real pad.

  python3 -I tools/gamepad.py start            create the pad and keep it (background); games need ~2 s to see it
  python3 -I tools/gamepad.py send SPEC...     A B X Y LB RB BACK START GUIDE LS RS, UP DOWN LEFT RIGHT (d-pad);
                                               SPEC*N repeats, SPEC~S holds S seconds, "sleep:S" pauses
  python3 -I tools/gamepad.py stop
  python3 -I tools/gamepad.py --selftest

Needs write access to /dev/uinput (the desktop seat's user has it on DGX OS). The pad lives in a small background
process that reads commands from a FIFO, so the game sees one stable controller rather than a plug/unplug per press.
"""
import fcntl
import os
import struct
import sys
import time

FIFO = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "gamespark-pad.fifo")
PIDFILE = FIFO + ".pid"
EV_SYN, EV_KEY, EV_ABS = 0, 1, 3
BUTTONS = {"A": 0x130, "B": 0x131, "X": 0x133, "Y": 0x134, "LB": 0x136, "RB": 0x137, "BACK": 0x13a,
           "START": 0x13b, "GUIDE": 0x13c, "LS": 0x13d, "RS": 0x13e}
DPAD = {"UP": (0x11, -1), "DOWN": (0x11, 1), "LEFT": (0x10, -1), "RIGHT": (0x10, 1)}   # ABS_HAT0Y / ABS_HAT0X
AXES = {0x00: (-32768, 32767), 0x01: (-32768, 32767), 0x03: (-32768, 32767), 0x04: (-32768, 32767),  # sticks
        0x02: (0, 255), 0x05: (0, 255), 0x10: (-1, 1), 0x11: (-1, 1)}                             # triggers, hat
UI_SET_EVBIT, UI_SET_KEYBIT, UI_SET_ABSBIT, UI_DEV_CREATE, UI_DEV_DESTROY = 0x40045564, 0x40045565, 0x40045567, 0x5501, 0x5502


def parse(spec):
    """'X~2' -> ('X', 1, 2.0); 'DOWN*3' -> ('DOWN', 3, 0.0); 'sleep:1' -> ('sleep', 1, 1.0)"""
    if spec.lower().startswith("sleep:"):
        return "sleep", 1, float(spec[6:])
    spec, _, hold = spec.partition("~")
    name, _, n = spec.partition("*")
    name = name.upper()
    if name not in BUTTONS and name not in DPAD:
        raise ValueError(f"unknown control {name}")
    return name, int(n or 1), float(hold or 0)


def create():
    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    for ev in (EV_KEY, EV_ABS):
        fcntl.ioctl(fd, UI_SET_EVBIT, ev)
    for code in BUTTONS.values():
        fcntl.ioctl(fd, UI_SET_KEYBIT, code)
    absmin, absmax = [0] * 64, [0] * 64
    for code, (lo, hi) in AXES.items():
        fcntl.ioctl(fd, UI_SET_ABSBIT, code)
        absmin[code], absmax[code] = lo, hi
    # struct uinput_user_dev: name[80], input_id (bustype, vendor, product, version), ff_effects_max, 4 x int32[64]
    dev = struct.pack("80sHHHHi", b"GameSpark virtual Xbox 360 pad", 0x03, 0x045e, 0x028e, 0x0110, 0)
    dev += struct.pack("64i", *absmax) + struct.pack("64i", *absmin) + struct.pack("64i", *[0] * 64) * 2
    os.write(fd, dev)
    fcntl.ioctl(fd, UI_DEV_CREATE)
    return fd


def emit(fd, typ, code, value):
    os.write(fd, struct.pack("llHHi", 0, 0, typ, code, value) + struct.pack("llHHi", 0, 0, EV_SYN, 0, 0))


def act(fd, spec):
    name, n, hold = parse(spec)
    for _ in range(n):
        if name == "sleep":
            time.sleep(hold)
            continue
        typ, code, on = (EV_KEY, BUTTONS[name], 1) if name in BUTTONS else (EV_ABS, *DPAD[name])
        emit(fd, typ, code, on)
        time.sleep(max(hold, 0.1))
        emit(fd, typ, code, 0)
        time.sleep(0.25)


def serve():
    fd = create()
    if not os.path.exists(FIFO):
        os.mkfifo(FIFO, 0o600)
    open(PIDFILE, "w").write(str(os.getpid()))
    try:
        while True:
            with open(FIFO) as f:            # blocks until a sender opens it; one line per send
                for line in f:
                    if line.strip() == "stop":
                        return
                    for spec in line.split():
                        act(fd, spec)
    finally:
        fcntl.ioctl(fd, UI_DEV_DESTROY)
        os.close(fd)
        for p in (FIFO, PIDFILE):
            if os.path.exists(p):
                os.remove(p)


def running():
    try:
        os.kill(int(open(PIDFILE).read()), 0)
        return True
    except (OSError, ValueError):
        return False


def main(argv):
    cmd = argv[0] if argv else "help"
    if cmd == "start":
        if running():
            return print("pad already running")
        if os.fork() == 0:
            os.setsid()
            serve()
            os._exit(0)
        time.sleep(2)                        # let udev and the game's input backend pick the new device up
        print("pad started" if running() else "pad failed to start")
    elif cmd == "send":
        for spec in argv[1:]:
            parse(spec)                      # reject typos before anything is pressed
        if not running():
            sys.exit("pad not running (tools/gamepad.py start)")
        with open(FIFO, "w") as f:
            f.write(" ".join(argv[1:]) + "\n")
        print("sent", " ".join(argv[1:]))
    elif cmd == "stop":
        if running():
            with open(FIFO, "w") as f:
                f.write("stop\n")
        print("pad stopped")
    elif cmd == "--selftest":
        assert parse("X~2") == ("X", 1, 2.0) and parse("down*3") == ("DOWN", 3, 0.0) and parse("sleep:1") == ("sleep", 1, 1.0)
        try:
            parse("Z")
            raise AssertionError("accepted an unknown control")
        except ValueError:
            pass
        assert len(struct.pack("80sHHHHi", b"", 0, 0, 0, 0, 0)) == 92   # uinput_user_dev header
        print("ok")
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
