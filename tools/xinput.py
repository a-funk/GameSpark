"""Synthetic mouse and keyboard input on the Spark's X display (XTest), for driving game menus.

  python3 -I tools/xinput.py move X Y                 pointer only (hover; no click)
  python3 -I tools/xinput.py click X Y [BUTTON]          BUTTON 1 left (default), 2 middle, 3 right
  python3 -I tools/xinput.py key KEY [KEY ...]       X keysym names: Down, Up, Return, Escape, Tab, a, F1 ...;
                                                     combos with +: Alt_L+Tab
                                                     KEY*N repeats (Down*3); "sleep:0.5" pauses between keys
  python3 -I tools/xinput.py activate TITLE|0xID     bring a window to the front (e.g. a sign-in dialog hidden
                                                     behind Big Picture); TITLE = exact name from xwininfo -tree
Uses libX11/libXtst through ctypes (activate also needs xwininfo for titles). DISPLAY/XAUTHORITY come from the env.
"""
import ctypes
import re
import subprocess
import sys
import time

X = ctypes.CDLL("libX11.so.6")
T = ctypes.CDLL("libXtst.so.6")
X.XOpenDisplay.restype = ctypes.c_void_p
X.XStringToKeysym.restype = ctypes.c_ulong
X.XStringToKeysym.argtypes = [ctypes.c_char_p]
X.XKeysymToKeycode.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
for fn in (T.XTestFakeMotionEvent, T.XTestFakeButtonEvent, T.XTestFakeKeyEvent, X.XFlush, X.XCloseDisplay):
    fn.argtypes = None
X.XDefaultRootWindow.restype = X.XInternAtom.restype = ctypes.c_ulong
X.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
X.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]


class ClientMessage(ctypes.Structure):  # XClientMessageEvent, padded to sizeof(XEvent)
    _fields_ = [("type", ctypes.c_int), ("serial", ctypes.c_ulong), ("send_event", ctypes.c_int),
                ("display", ctypes.c_void_p), ("window", ctypes.c_ulong), ("message_type", ctypes.c_ulong),
                ("format", ctypes.c_int), ("data", ctypes.c_long * 5), ("pad", ctypes.c_long * 12)]


def window_id(spec):
    if spec.startswith("0x"):
        return int(spec, 16)
    tree = subprocess.run(["xwininfo", "-root", "-tree"], capture_output=True, text=True, check=True).stdout
    m = re.search(r"^\s*(0x[0-9a-f]+) " + re.escape(f'"{spec}"'), tree, re.M)
    if not m:
        sys.exit(f"no window named {spec!r}")
    return int(m.group(1), 16)


def activate(d, win):
    """Ask the window manager to focus and raise win (EWMH _NET_ACTIVE_WINDOW, as a pager would)."""
    ev = ClientMessage(type=33, send_event=1, window=win, format=32,
                       message_type=X.XInternAtom(d, b"_NET_ACTIVE_WINDOW", 0))
    ev.data[0] = 2   # source indication: pager, so the window manager does not apply focus-stealing prevention
    X.XSendEvent(d, ctypes.c_ulong(X.XDefaultRootWindow(d)), 0, (1 << 19) | (1 << 20), ctypes.byref(ev))
    X.XFlush(d)


def main(argv):
    d = ctypes.c_void_p(X.XOpenDisplay(None))
    if not d.value:
        sys.exit("cannot open X display (set DISPLAY and XAUTHORITY)")
    try:
        if argv[0] == "move":
            T.XTestFakeMotionEvent(d, -1, int(argv[1]), int(argv[2]), 0); X.XFlush(d)
            print(f"moved to {argv[1]},{argv[2]}")
        elif argv[0] == "click":
            x, y, b = int(argv[1]), int(argv[2]), int(argv[3]) if len(argv) > 3 else 1
            T.XTestFakeMotionEvent(d, -1, x, y, 0); X.XFlush(d); time.sleep(0.15)
            T.XTestFakeButtonEvent(d, b, 1, 0); time.sleep(0.05); T.XTestFakeButtonEvent(d, b, 0, 0); X.XFlush(d)
            print(f"clicked {x},{y}" + (f" button {b}" if b != 1 else ""))
        elif argv[0] == "key":
            for spec in argv[1:]:
                if spec.startswith("sleep:"):
                    time.sleep(float(spec[6:]))
                    continue
                name, _, n = spec.partition("*")
                codes = []
                for part in name.split("+"):  # combos: Alt_L+Tab, Control_L+a
                    sym = X.XStringToKeysym(part.encode())
                    code = X.XKeysymToKeycode(d, sym) if sym else 0
                    if not code:
                        sys.exit(f"unknown key {part}")
                    codes.append(code)
                for _ in range(int(n or 1)):
                    for c in codes:
                        T.XTestFakeKeyEvent(d, c, 1, 0); X.XFlush(d); time.sleep(0.06)
                    for c in reversed(codes):
                        T.XTestFakeKeyEvent(d, c, 0, 0); X.XFlush(d); time.sleep(0.06)
                    time.sleep(0.2)
            print("keys", " ".join(argv[1:]))
        elif argv[0] == "activate":
            win = window_id(argv[1])
            activate(d, win)
            print(f"activated 0x{win:x}")
        else:
            sys.exit(__doc__)
    finally:
        X.XCloseDisplay(d)


if __name__ == "__main__":
    main(sys.argv[1:] or ["help"])
