"""Synthetic mouse and keyboard input on the Spark's X display (XTest), for driving game menus.

  python3 -I tools/xinput.py click X Y
  python3 -I tools/xinput.py key KEY [KEY ...]       X keysym names: Down, Up, Return, Escape, Tab, a, F1 ...;
                                                     combos with +: Alt_L+Tab
                                                     KEY*N repeats (Down*3); "sleep:0.5" pauses between keys
Uses libX11/libXtst through ctypes, so it needs no extra packages. DISPLAY/XAUTHORITY come from the environment.
"""
import ctypes
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


def main(argv):
    d = ctypes.c_void_p(X.XOpenDisplay(None))
    if not d.value:
        sys.exit("cannot open X display (set DISPLAY and XAUTHORITY)")
    try:
        if argv[0] == "click":
            x, y = int(argv[1]), int(argv[2])
            T.XTestFakeMotionEvent(d, -1, x, y, 0); X.XFlush(d); time.sleep(0.15)
            T.XTestFakeButtonEvent(d, 1, 1, 0); time.sleep(0.05); T.XTestFakeButtonEvent(d, 1, 0, 0); X.XFlush(d)
            print(f"clicked {x},{y}")
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
        else:
            sys.exit(__doc__)
    finally:
        X.XCloseDisplay(d)


if __name__ == "__main__":
    main(sys.argv[1:] or ["help"])
