#!/usr/bin/env python3
# Clicks at screen points on an X display through XTest: click.py x,y [x,y ...]
import ctypes, sys, time
x11 = ctypes.CDLL("libX11.so.6"); xt = ctypes.CDLL("libXtst.so.6")
x11.XOpenDisplay.restype = ctypes.c_void_p
d = x11.XOpenDisplay(None)
for arg in sys.argv[1:]:
    x, y = map(int, arg.split(','))
    xt.XTestFakeMotionEvent(ctypes.c_void_p(d), -1, x, y, 0); x11.XFlush(ctypes.c_void_p(d)); time.sleep(0.4)
    xt.XTestFakeButtonEvent(ctypes.c_void_p(d), 1, 1, 0); x11.XFlush(ctypes.c_void_p(d)); time.sleep(0.1)
    xt.XTestFakeButtonEvent(ctypes.c_void_p(d), 1, 0, 0); x11.XFlush(ctypes.c_void_p(d)); time.sleep(1.2)
