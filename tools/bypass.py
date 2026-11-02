"""Let a fullscreen game bypass GNOME's compositor (Mutter on X11).

Mutter only stops compositing ("unredirects") the topmost visible window, and only when that window is fullscreen. A
game can be shown fullscreen and still be composited, which puts Mutter's own vsync'd repaint between every game frame
and the TV: Galactic Racer had a 1x1 override-redirect window of the Epic Online Services overlay (opacity 0) and one of
Wine's own mapped above it, so Mutter composited it, and in its pause menu only 24 of the game's 36 fps reached the
screen (docs/FINDINGS.md). Override-redirect windows are not the window manager's to stack, so any client may lower
them: this lowers tiny (at most 4x4) mapped override-redirect windows that sit above a fullscreen window. Nothing is
unmapped or closed.

  python3 -I tools/bypass.py check     the fullscreen window, what is mapped above it, and whether Mutter composites it
  python3 -I tools/bypass.py fix       lower the tiny windows above it once (exits 1 if there is no fullscreen window)
  python3 -I tools/bypass.py watch [PID]  keep doing that every 2 s (windows come back) until PID exits (tools/launch.sh
                                       passes its own, which becomes the game's launch chain); without PID, until 60 s
                                       pass with no fullscreen window on top (loading screens can briefly have none)
  python3 -I tools/bypass.py --selftest
"""
import ctypes
import os
import sys
import time

TINY = 4


def x11():
    X = ctypes.CDLL("libX11.so.6")
    C = ctypes.CDLL("libXcomposite.so.1")
    X.XOpenDisplay.restype = ctypes.c_void_p
    X.XDefaultRootWindow.restype = ctypes.c_ulong
    X.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
    X.XInternAtom.restype = ctypes.c_ulong
    X.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
    X.XQueryTree.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(ctypes.c_ulong),
                             ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.POINTER(ctypes.c_ulong)),
                             ctypes.POINTER(ctypes.c_uint)]
    X.XGetWindowAttributes.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_void_p]
    X.XGetWindowProperty.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_long, ctypes.c_long,
                                     ctypes.c_int, ctypes.c_ulong, ctypes.POINTER(ctypes.c_ulong),
                                     ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_ulong),
                                     ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_void_p)]
    X.XLowerWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
    X.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
    X.XFreePixmap.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
    X.XFree.argtypes = [ctypes.c_void_p]
    C.XCompositeNameWindowPixmap.restype = ctypes.c_ulong
    C.XCompositeNameWindowPixmap.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
    return X, C


class Attrs(ctypes.Structure):   # XWindowAttributes
    _fields_ = [("x", ctypes.c_int), ("y", ctypes.c_int), ("width", ctypes.c_int), ("height", ctypes.c_int),
                ("border_width", ctypes.c_int), ("depth", ctypes.c_int), ("visual", ctypes.c_void_p),
                ("root", ctypes.c_ulong), ("c_class", ctypes.c_int), ("bit_gravity", ctypes.c_int),
                ("win_gravity", ctypes.c_int), ("backing_store", ctypes.c_int), ("backing_planes", ctypes.c_ulong),
                ("backing_pixel", ctypes.c_ulong), ("save_under", ctypes.c_int), ("colormap", ctypes.c_ulong),
                ("map_installed", ctypes.c_int), ("map_state", ctypes.c_int), ("all_event_masks", ctypes.c_long),
                ("your_event_mask", ctypes.c_long), ("do_not_propagate_mask", ctypes.c_long),
                ("override_redirect", ctypes.c_int), ("screen", ctypes.c_void_p)]


ERRORS = []


@ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p)
def on_error(_d, _e):
    ERRORS.append(1)
    return 0


def windows(X, d):
    """Root's children top-most first: (id, attrs, fullscreen?)"""
    root = X.XDefaultRootWindow(d)
    r, p, n = ctypes.c_ulong(), ctypes.c_ulong(), ctypes.c_uint()
    ch = ctypes.POINTER(ctypes.c_ulong)()
    X.XQueryTree(d, root, ctypes.byref(r), ctypes.byref(p), ctypes.byref(ch), ctypes.byref(n))
    state, fs = X.XInternAtom(d, b"_NET_WM_STATE", 0), X.XInternAtom(d, b"_NET_WM_STATE_FULLSCREEN", 0)
    out = []
    ids = [ch[i] for i in range(n.value)]
    if ch:
        X.XFree(ch)
    for w in reversed(ids):
        a = Attrs()
        ERRORS.clear()
        X.XGetWindowAttributes(d, w, ctypes.byref(a))
        if ERRORS:
            continue
        t, f, cnt, left, data = ctypes.c_ulong(), ctypes.c_int(), ctypes.c_ulong(), ctypes.c_ulong(), ctypes.c_void_p()
        X.XGetWindowProperty(d, w, state, 0, 32, 0, 4, ctypes.byref(t), ctypes.byref(f), ctypes.byref(cnt),
                             ctypes.byref(left), ctypes.byref(data))
        atoms = ctypes.cast(data, ctypes.POINTER(ctypes.c_ulong))[:cnt.value] if data.value else []
        if data.value:
            X.XFree(data)
        out.append((w, a, fs in atoms))
    return out


def to_lower(ws):
    """(fullscreen window or None, tiny mapped override-redirect windows above it)"""
    viewable = 2   # IsViewable
    above = []
    for w, a, fullscreen in ws:
        if a.map_state != viewable:
            continue
        if fullscreen and not a.override_redirect:
            return w, above
        if a.override_redirect and a.width <= TINY and a.height <= TINY:
            above.append(w)
        else:
            return None, []   # something real is on top: leave the stack alone
    return None, []


def composited(X, C, d, w):
    ERRORS.clear()
    pm = C.XCompositeNameWindowPixmap(d, w)
    X.XSync(d, 0)
    if ERRORS:
        return False
    X.XFreePixmap(d, pm)
    X.XSync(d, 0)
    return True


def main(cmd, pid=None):
    X, C = x11()
    X.XSetErrorHandler(on_error)
    d = X.XOpenDisplay(None)
    if not d:
        sys.exit("cannot open the X display (DISPLAY?)")
    misses = 0
    while pid is None or os.path.exists(f"/proc/{pid}"):
        game, tiny = to_lower(windows(X, d))
        if cmd == "check":
            if game is None:
                sys.exit("no fullscreen window on top (or a real window above it)")
            print(f"fullscreen 0x{game:x}: composited by the compositor: {composited(X, C, d, game)}; "
                  f"tiny override-redirect windows above it: {' '.join(f'0x{w:x}' for w in tiny) or 'none'}")
            return
        if game is None:
            if cmd == "fix":
                sys.exit("no fullscreen window on top")
            misses += 1
            if pid is None and misses * 2 >= 60:
                return   # watch: the game is gone
            time.sleep(2)
            continue
        misses = 0
        for w in tiny:
            X.XLowerWindow(d, w)
        X.XSync(d, 0)
        if tiny:
            print(f"{time.strftime('%T')} lowered {' '.join(f'0x{w:x}' for w in tiny)} below 0x{game:x}", flush=True)
        if cmd == "fix":
            return
        time.sleep(2)


def selftest():
    def att(w, h, mapped=True, o_r=False):
        a = Attrs()
        a.width, a.height, a.map_state, a.override_redirect = w, h, 2 if mapped else 0, int(o_r)
        return a
    game = (3, att(3840, 2160), True)
    assert to_lower([(1, att(1, 1, o_r=True), False), (2, att(1, 1, mapped=False), False), game]) == (3, [1])
    assert to_lower([game, (1, att(1, 1, o_r=True), False)]) == (3, [])
    # a real window (a dialog) above the game: leave everything alone
    assert to_lower([(5, att(400, 300), False), (1, att(1, 1, o_r=True), False), game]) == (None, [])
    assert to_lower([(1, att(1, 1, o_r=True), False)]) == (None, [])
    print("selftest ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["--selftest"]:
        selftest()
    elif sys.argv[1:2] in (["check"], ["fix"]) and len(sys.argv) == 2:
        main(sys.argv[1])
    elif sys.argv[1:2] == ["watch"] and len(sys.argv) in (2, 3):
        main("watch", int(sys.argv[2]) if len(sys.argv) == 3 else None)
    else:
        sys.exit(__doc__)
