"""Synthetic mouse and keyboard input on the Spark's X display (XTest), for driving game menus.

  python3 -I tools/xinput.py move X Y                 pointer only (hover; no click)
  python3 -I tools/xinput.py click X Y [BUTTON]          BUTTON 1 left (default), 2 middle, 3 right
  python3 -I tools/xinput.py key KEY [KEY ...]       X keysym names: Down, Up, Return, Escape, Tab, a, F1 ...;
                                                     combos with +: Alt_L+Tab
                                                     KEY*N repeats (Down*3); KEY~S holds S seconds (x~1);
                                                     "sleep:0.5" pauses between keys
  python3 -I tools/xinput.py activate TITLE|0xID     bring a window to the front (e.g. a sign-in dialog hidden
                                                     behind Big Picture); TITLE = exact name from xwininfo -tree
  python3 -I tools/xinput.py iconify TITLE|0xID      minimise a window (exits 1 if there is none): one left drawing
                                                     behind a game takes GPU and X server time from it
  python3 -I tools/xinput.py --ref WxH move|click X Y ...   X Y are for a WxH screen (e.g. --ref 1920x1080 for a point
                                                     measured on a 1080p screenshot) and are scaled to the actual
                                                     screen, for games that fill it (the TV runs 3840x2160 now)
  python3 -I tools/xinput.py --selftest
Uses libX11/libXtst through ctypes (activate also needs xwininfo for titles). DISPLAY/XAUTHORITY come from the env.
"""
import ctypes
import re
import subprocess
import sys
import time

X = T = None


def load():
    """libX11/libXtst with the prototypes used here (loaded on first use, so --selftest needs no X libraries)."""
    global X, T
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
    X.XDefaultScreen.argtypes = [ctypes.c_void_p]
    X.XDisplayWidth.argtypes = X.XDisplayHeight.argtypes = [ctypes.c_void_p, ctypes.c_int]
    X.XIconifyWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int]


class ClientMessage(ctypes.Structure):  # XClientMessageEvent, padded to sizeof(XEvent)
    _fields_ = [("type", ctypes.c_int), ("serial", ctypes.c_ulong), ("send_event", ctypes.c_int),
                ("display", ctypes.c_void_p), ("window", ctypes.c_ulong), ("message_type", ctypes.c_ulong),
                ("format", ctypes.c_int), ("data", ctypes.c_long * 5), ("pad", ctypes.c_long * 12)]


def scaled(x, y, ref, size):
    """Point (x, y) given for a screen of size ref=(w, h), on a screen of size `size`."""
    if not ref:
        return x, y
    return round(x * size[0] / ref[0]), round(y * size[1] / ref[1])


def find_window(tree, spec):
    """The window named spec in xwininfo -tree output. mutter's frame around a window carries its name too and comes
    first: skip it, since the window manager acts on the client window."""
    m = re.search(r"^\s*(0x[0-9a-f]+) " + re.escape(f'"{spec}"') + r': \((?!"mutter-x11-frames")', tree, re.M)
    return int(m.group(1), 16) if m else None


def window_id(spec):
    if spec.startswith("0x"):
        return int(spec, 16)
    tree = subprocess.run(["xwininfo", "-root", "-tree"], capture_output=True, text=True, check=True).stdout
    win = find_window(tree, spec)
    if win is None:
        sys.exit(f"no window named {spec!r}")
    return win


def activate(d, win):
    """Ask the window manager to focus and raise win (EWMH _NET_ACTIVE_WINDOW, as a pager would)."""
    ev = ClientMessage(type=33, send_event=1, window=win, format=32,
                       message_type=X.XInternAtom(d, b"_NET_ACTIVE_WINDOW", 0))
    ev.data[0] = 2   # source indication: pager, so the window manager does not apply focus-stealing prevention
    X.XSendEvent(d, ctypes.c_ulong(X.XDefaultRootWindow(d)), 0, (1 << 19) | (1 << 20), ctypes.byref(ev))
    X.XFlush(d)


def selftest():
    assert scaled(365, 710, (1920, 1080), (3840, 2160)) == (730, 1420)
    assert scaled(333, 385, None, (3840, 2160)) == (333, 385)
    assert scaled(960, 540, (1920, 1080), (2560, 1440)) == (1280, 720)
    tree = ('     0x600027 "Steam Big Picture Mode": ("mutter-x11-frames" "mutter-x11-frames")  3840x2160+0+0  +0+0\n'
            '        0x58000a2 "Steam Big Picture Mode": ("steamwebhelper" "steam")  3840x2160+0+0  +0+0\n'
            '     0x1a00000 "Chromium clipboard": ()  10x10+-100+-100  +-100+-100\n')
    assert find_window(tree, "Steam Big Picture Mode") == 0x58000a2   # the client, not mutter's frame
    assert find_window(tree, "Chromium clipboard") == 0x1a00000
    assert find_window(tree, "Steam") is None                         # exact names only
    print("ok")


def main(argv):
    ref = None
    if argv[:1] == ["--ref"]:
        m = re.fullmatch(r"(\d+)x(\d+)", argv[1] if len(argv) > 1 else "")
        if not m:
            sys.exit("--ref takes WIDTHxHEIGHT, e.g. --ref 1920x1080")
        ref, argv = (int(m.group(1)), int(m.group(2))), argv[2:]
    if not argv or argv[0] not in ("move", "click", "key", "activate", "iconify"):
        sys.exit(__doc__)
    load()
    d = ctypes.c_void_p(X.XOpenDisplay(None))
    if not d.value:
        sys.exit("cannot open X display (set DISPLAY and XAUTHORITY)")
    try:
        scr = X.XDefaultScreen(d)
        size = (X.XDisplayWidth(d, scr), X.XDisplayHeight(d, scr))
        if argv[0] == "move":
            x, y = scaled(int(argv[1]), int(argv[2]), ref, size)
            T.XTestFakeMotionEvent(d, -1, x, y, 0); X.XFlush(d)
            print(f"moved to {x},{y}")
        elif argv[0] == "click":
            (x, y), b = scaled(int(argv[1]), int(argv[2]), ref, size), int(argv[3]) if len(argv) > 3 else 1
            T.XTestFakeMotionEvent(d, -1, x, y, 0); X.XFlush(d); time.sleep(0.15)
            T.XTestFakeButtonEvent(d, b, 1, 0); time.sleep(0.05); T.XTestFakeButtonEvent(d, b, 0, 0); X.XFlush(d)
            print(f"clicked {x},{y}" + (f" button {b}" if b != 1 else ""))
        elif argv[0] == "key":
            for spec in argv[1:]:
                if spec.startswith("sleep:"):
                    time.sleep(float(spec[6:]))
                    continue
                spec, _, hold = spec.partition("~")
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
                    time.sleep(float(hold or 0))
                    for c in reversed(codes):
                        T.XTestFakeKeyEvent(d, c, 0, 0); X.XFlush(d); time.sleep(0.06)
                    time.sleep(0.2)
            print("keys", " ".join(argv[1:]))
        elif argv[0] == "activate":
            win = window_id(argv[1])
            activate(d, win)
            print(f"activated 0x{win:x}")
        elif argv[0] == "iconify":
            win = window_id(argv[1])
            if not X.XIconifyWindow(d, win, scr):
                sys.exit(f"could not minimise 0x{win:x}")
            X.XFlush(d)
            print(f"minimised 0x{win:x}")
    finally:
        X.XCloseDisplay(d)


if __name__ == "__main__":
    selftest() if sys.argv[1:] == ["--selftest"] else main(sys.argv[1:] or ["help"])
