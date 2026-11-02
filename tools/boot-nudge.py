"""Nudge a game that stalls while it boots until its window is activated again: Street Fighter 6 in Borderless mode
under Wine sits on its health warning (and later on a still frame) until focus leaves its window and comes back.
While the screen stands still, focus moves to a 1-pixel window of ours and back to the game (EWMH activation, as a
pager would; plain X focus changes do not do it), until TEXT shows on screen (OCR), LIMIT seconds pass after the game's
window appears, or the launch ends. Started by tools/launch.sh for profiles with BOOT_NUDGE=TEXT.

  python3 -I tools/boot-nudge.py APPID TEXT PID   PID: the launch's process (the helper stops when it exits)
  python3 -I tools/boot-nudge.py --selftest
Needs xwininfo, ffmpeg and tesseract; DISPLAY/XAUTHORITY come from the env.
"""
import ctypes
import hashlib
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import xinput  # noqa: E402  (tools/xinput.py: libX11 through ctypes, EWMH activation)

STILL = 8      # seconds of an unchanged screen before a nudge
SETTLE = 12    # seconds after a nudge before the next one
LIMIT = 300    # seconds after the game's window appears
POLL = 3


def log(msg):
    print(time.strftime("%F %T"), msg, flush=True)


def main_window(tree, appid):
    """The id of the largest top-level window of class steam_app_APPID in `xwininfo -root -children` output."""
    best = None
    pat = r'^\s*(0x[0-9a-f]+) .*\("steam_app_%s" "steam_app_%s"\)\s+(\d+)x(\d+)' % (appid, appid)
    for m in re.finditer(pat, tree, re.M):
        area = int(m.group(2)) * int(m.group(3))
        if area > 100 * 100 and (best is None or area > best[1]):
            best = (int(m.group(1), 16), area)
    return best[0] if best else None


class Still:
    """How long the screen has looked the same (by a hash of a tiny grey thumbnail)."""
    def __init__(self):
        self.last, self.since = None, None

    def update(self, digest, now):
        if digest != self.last:
            self.last, self.since = digest, now
        return now - self.since


def grab(size):
    """(hash of a 64x36 grey thumbnail, OCR text of the screen at 1280x720)."""
    w, h = size
    png = "/tmp/gamespark-boot-nudge.png"
    thumb = subprocess.run(["ffmpeg", "-loglevel", "error", "-f", "x11grab", "-video_size", f"{w}x{h}", "-i",
                            os.environ.get("DISPLAY", ":0"), "-frames:v", "1", "-filter_complex",
                            "split=2[a][b];[a]scale=64:36,format=gray[t];[b]scale=1280:720[o]",
                            "-map", "[t]", "-f", "rawvideo", "-", "-map", "[o]", "-y", png],
                           capture_output=True, timeout=20).stdout
    text = subprocess.run(["tesseract", png, "-"], capture_output=True, text=True, timeout=30).stdout
    return hashlib.sha1(thumb).hexdigest(), " ".join(text.split())


def nudge(d, game):
    """Activate a 1x1 undecorated window of ours, then the game again: the game sees itself deactivated and activated."""
    X = xinput.X
    root = X.XDefaultRootWindow(d)
    X.XCreateSimpleWindow.restype = ctypes.c_ulong
    X.XCreateSimpleWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_int, ctypes.c_uint,
                                      ctypes.c_uint, ctypes.c_uint, ctypes.c_ulong, ctypes.c_ulong]
    X.XChangeProperty.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_int,
                                  ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
    X.XStoreName.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_char_p]
    X.XMapWindow.argtypes = X.XDestroyWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
    X.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
    w = X.XCreateSimpleWindow(d, root, 0, 0, 1, 1, 0, 0, 0)
    motif = X.XInternAtom(d, b"_MOTIF_WM_HINTS", 0)
    hints = (ctypes.c_long * 5)(2, 0, 0, 0, 0)   # flags: decorations; decorations: none
    X.XChangeProperty(d, w, motif, motif, 32, 0, hints, 5)
    X.XStoreName(d, w, b"GameSpark boot nudge")
    X.XMapWindow(d, w)
    X.XSync(d, 0)
    time.sleep(0.3)
    xinput.activate(d, w)
    time.sleep(1.5)
    xinput.activate(d, game)
    time.sleep(0.3)
    X.XDestroyWindow(d, w)
    X.XSync(d, 0)


def run(appid, text, pid):
    xinput.load()
    d = xinput.X.XOpenDisplay(None)
    if not d:
        sys.exit("boot-nudge: cannot open the display")
    scr = xinput.X.XDefaultScreen(d)
    size = (xinput.X.XDisplayWidth(d, scr), xinput.X.XDisplayHeight(d, scr))
    want = text.lower()
    still, seen, nudged, n = Still(), None, 0.0, 0
    log(f"app {appid}: waiting for its window; nudging until {text!r}")
    while os.path.exists(f"/proc/{pid}"):
        now = time.monotonic()
        tree = subprocess.run(["xwininfo", "-root", "-children"], capture_output=True, text=True).stdout
        game = main_window(tree, appid)
        if game and seen is None:
            seen = now
            log(f"window 0x{game:x}")
        if seen is not None:
            if now - seen > LIMIT:
                log(f"gave up after {LIMIT} s ({n} nudges)")
                return
            digest, screen = grab(size)
            if want in screen.lower():
                log(f"{text!r} on screen after {now - seen:.0f} s ({n} nudges)")
                return
            if game and still.update(digest, now) >= STILL and now - nudged >= SETTLE:
                nudge(d, game)
                nudged, n = time.monotonic(), n + 1
                log(f"nudge {n} at {now - seen:.0f} s (screen: {screen[:60]!r})")
        time.sleep(POLL)
    log(f"launch ended ({n} nudges)")


def selftest():
    tree = ('     0xa000003 (has no name): ("steam_app_42" "steam_app_42")  1x1+0+0  +0+0\n'
            '     0xa000001 "Game": ("steam_app_42" "steam_app_42")  3840x2160+0+0  +0+0\n'
            '     0x5800039 "Steam": ("steamwebhelper" "steam")  2879x1710+961+450  +961+450\n')
    assert main_window(tree, 42) == 0xa000001
    assert main_window(tree, 43) is None
    s = Still()
    assert s.update("a", 0) == 0 and s.update("a", 5) == 5 and s.update("b", 6) == 0 and s.update("b", 20) == 14
    print("ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["--selftest"]:
        selftest()
    elif len(sys.argv) == 4:
        run(sys.argv[1], sys.argv[2], int(sys.argv[3]))
    else:
        sys.exit(__doc__)
