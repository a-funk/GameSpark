# One left click on the Spark display. Usage: DISPLAY=:1 python3 -I xclick.py X Y   (screen pixels)
import ctypes, sys, time
X = ctypes.CDLL("libX11.so.6"); T = ctypes.CDLL("libXtst.so.6")
X.XOpenDisplay.restype = ctypes.c_void_p
d = ctypes.c_void_p(X.XOpenDisplay(None))
x, y = int(sys.argv[1]), int(sys.argv[2])
T.XTestFakeMotionEvent(d, -1, x, y, 0); X.XFlush(d); time.sleep(0.15)
T.XTestFakeButtonEvent(d, 1, 1, 0); time.sleep(0.05); T.XTestFakeButtonEvent(d, 1, 0, 0); X.XFlush(d)
X.XCloseDisplay(d)
print(f"clicked {x},{y}")
