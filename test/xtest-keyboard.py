#!/usr/bin/env python3
"""Can XTEST type into a Wayland-native client? And into an XWayland one?

The second question is the POSITIVE CONTROL and the whole reason this test is
worth anything: without it, "nothing was typed" cannot be distinguished from
"my XTEST call is wrong", which is the exact failure mode this project keeps
hitting (R-29: every check passing while the thing under test was a no-op).

Method: run a terminal whose only job is `cat > FILE`, focus it, fake keystrokes
through XTEST, then read the FILE. The oracle is what the program actually
received -- not a screenshot, not an assumption.
"""
import ctypes
import ctypes.util
import os
import pathlib
import subprocess
import sys
import time

SCRATCH = pathlib.Path(__file__).resolve().parent

x11 = ctypes.CDLL(ctypes.util.find_library("X11"))
xtst = ctypes.CDLL(ctypes.util.find_library("Xtst"))
x11.XOpenDisplay.restype = ctypes.c_void_p
x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
x11.XStringToKeysym.restype = ctypes.c_ulong
x11.XStringToKeysym.argtypes = [ctypes.c_char_p]
x11.XKeysymToKeycode.restype = ctypes.c_ubyte
x11.XKeysymToKeycode.argtypes = [ctypes.c_void_p, ctypes.c_ulong]

dpy = x11.XOpenDisplay(None)
if not dpy:
    sys.exit("cannot open DISPLAY")


def xtest_type(text):
    """Fake key press+release for each character, the way an X11 client would."""
    for ch in text:
        keysym = x11.XStringToKeysym(ch.encode())
        code = x11.XKeysymToKeycode(ctypes.c_void_p(dpy), ctypes.c_ulong(keysym))
        if code == 0:
            print(f"  (no keycode for {ch!r}, skipped)")
            continue
        xtst.XTestFakeKeyEvent(ctypes.c_void_p(dpy), ctypes.c_uint(code), True, 0)
        xtst.XTestFakeKeyEvent(ctypes.c_void_p(dpy), ctypes.c_uint(code), False, 0)
    x11.XFlush(ctypes.c_void_p(dpy))


def active_window():
    """Also report whether the focused window is XWAYLAND -- without that, case B
    could silently be a Wayland client and the 'control' would prove nothing."""
    import json
    out = subprocess.run(["hyprctl", "-j", "activewindow"],
                         capture_output=True, text=True)
    try:
        w = json.loads(out.stdout)
        return f"class={w.get('class')!r} xwayland={w.get('xwayland')} pid={w.get('pid')}"
    except Exception:
        return out.stdout.strip().splitlines()[0] if out.stdout.strip() else "?"


def run_case(label, outfile, env_extra):
    outfile = SCRATCH / outfile
    outfile.unlink(missing_ok=True)
    env = dict(os.environ, **env_extra)
    for var in env_extra:
        if env_extra[var] == "":
            env.pop(var, None)

    proc = subprocess.Popen(
        ["alacritty", "-e", "sh", "-c", f"cat > {outfile}"],
        env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    time.sleep(2.5)                      # let it map and take focus
    print(f"\n=== {label} ===")
    print(f"  active window: {active_window()}")
    # ⚠️ The terminal line discipline is in CANONICAL mode, so `cat` receives
    # NOTHING until a newline is submitted. The first run of this test typed
    # "hello" with no Return and read back "" from BOTH cases -- which looked
    # exactly like "XTEST reaches nothing" and was really "the oracle never got
    # a chance to see anything". Send Return.
    xtest_type("hello")
    keysym = x11.XStringToKeysym(b"Return")
    code = x11.XKeysymToKeycode(ctypes.c_void_p(dpy), ctypes.c_ulong(keysym))
    xtst.XTestFakeKeyEvent(ctypes.c_void_p(dpy), ctypes.c_uint(code), True, 0)
    xtst.XTestFakeKeyEvent(ctypes.c_void_p(dpy), ctypes.c_uint(code), False, 0)
    x11.XFlush(ctypes.c_void_p(dpy))
    time.sleep(1.0)
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
    time.sleep(0.3)

    got = outfile.read_text() if outfile.exists() else "<no file>"
    print(f"  typed 'hello' via XTEST -> the program received: {got!r}")
    return got


# Wayland-native: WAYLAND_DISPLAY set, so alacritty uses the Wayland backend.
wayland_got = run_case("A. Wayland-native client", "xtest-wayland.txt", {})

# XWayland: remove WAYLAND_DISPLAY so alacritty falls back to X11 via DISPLAY.
xwayland_got = run_case("B. XWayland (X11) client  [POSITIVE CONTROL]",
                        "xtest-xwayland.txt", {"WAYLAND_DISPLAY": ""})

print("\n" + "=" * 62)
w_ok = "hello" in wayland_got
x_ok = "hello" in xwayland_got
print(f"  Wayland-native received the keystrokes: {w_ok}")
print(f"  XWayland      received the keystrokes: {x_ok}")

if x_ok and not w_ok:
    print("VERDICT: ✅ XTEST reaches X11 clients and NOT Wayland-native ones.")
    print("         R-42's inferred mechanism is now MEASURED. Steam's desktop")
    print("         input cannot reach an Omarchy desktop. Option closed.")
elif x_ok and w_ok:
    print("VERDICT: 🔴 XTEST reached BOTH. The inference is WRONG and the Steam")
    print("         option deserves re-examination.")
elif not x_ok:
    print("VERDICT: ⚠️ THE CONTROL FAILED -- XTEST did not even reach an X11")
    print("         client, so this run proves nothing about Wayland. Fix the")
    print("         instrument (focus? keycodes?) before concluding anything.")
