#!/usr/bin/env python3
"""Can XTEST move a Wayland compositor's pointer?

This is the exact mechanism R-42 INFERRED that Steam uses to drive desktop input
(`libXtst` mapped into the Steam process), and it is the one link in the
Steam-in-background argument that was never measured -- P17:566-570 says so in
as many words: "The behaviour is measured; the mechanism is a strong inference."

No Steam, no VM, no controller needed: XTEST is a generic X11 facility, and this
dev machine runs Hyprland with Xwayland, which is the same shape as the Deck.

Reads the compositor's own cursor position via `hyprctl cursorpos` before and
after, so the oracle is the compositor, not the X server's idea of itself.
"""
import ctypes
import ctypes.util
import subprocess
import sys
import time


def hypr_cursor():
    """The COMPOSITOR's cursor position -- the thing that actually matters."""
    out = subprocess.run(["hyprctl", "cursorpos"], capture_output=True, text=True)
    if out.returncode != 0:
        return None
    try:
        x, y = (int(v) for v in out.stdout.strip().split(","))
        return (x, y)
    except ValueError:
        return None


xtst = ctypes.CDLL(ctypes.util.find_library("Xtst"))
x11 = ctypes.CDLL(ctypes.util.find_library("X11"))
x11.XOpenDisplay.restype = ctypes.c_void_p
x11.XOpenDisplay.argtypes = [ctypes.c_char_p]

dpy = x11.XOpenDisplay(None)
if not dpy:
    print("FAIL: cannot open X display -- is Xwayland running and DISPLAY set?")
    sys.exit(2)
print(f"opened X display (Xwayland) at DISPLAY={subprocess.os.environ.get('DISPLAY')}")

# Is the extension even there? If XTEST is absent the whole question is moot.
major = ctypes.c_int()
minor = ctypes.c_int()
ev = ctypes.c_int()
err = ctypes.c_int()
have = xtst.XTestQueryExtension(ctypes.c_void_p(dpy), ctypes.byref(ev),
                                ctypes.byref(err), ctypes.byref(major),
                                ctypes.byref(minor))
print(f"XTEST extension present: {bool(have)}  (version {major.value}.{minor.value})")
if not have:
    print("VERDICT: no XTEST at all -- cannot test the mechanism here.")
    sys.exit(1)

before = hypr_cursor()
print(f"compositor cursor BEFORE: {before}")

# Move via XTEST, the way an X11 client would.
TARGET = (400, 400) if before != (400, 400) else (900, 500)
xtst.XTestFakeMotionEvent(ctypes.c_void_p(dpy), -1,
                          ctypes.c_int(TARGET[0]), ctypes.c_int(TARGET[1]),
                          ctypes.c_ulong(0))
x11.XFlush(ctypes.c_void_p(dpy))
time.sleep(0.4)

after = hypr_cursor()
print(f"XTestFakeMotionEvent -> {TARGET}")
print(f"compositor cursor AFTER : {after}")

if before is None or after is None:
    print("VERDICT: could not read the compositor cursor; oracle broken.")
    sys.exit(2)
if after == TARGET:
    print("VERDICT: 🔴 XTEST MOVED THE COMPOSITOR POINTER. The R-42 inference is "
          "WRONG for the pointer, and the Steam option deserves re-examination.")
    sys.exit(0)
if after == before:
    print("VERDICT: ✅ XTEST did NOT move the compositor pointer -- the request "
          "was accepted by Xwayland and went nowhere. This is what R-42 inferred.")
    sys.exit(0)
print(f"VERDICT: ambiguous -- cursor moved to {after}, which is neither the "
      f"target nor the original. Something else moved it (a real mouse?). Retry "
      f"without touching the pointer.")
sys.exit(3)
