#!/usr/bin/env python3
"""End-to-end drive of the TTY on-screen keyboard (T8 step 4).

    virtual gamepad (uinput) -> deck-input-mapper -> two cursors
                                                  -> rendered console (a pty)
                                                  -> keystrokes (dry-run)

Everything from a pad event to a drawn key to an emitted keycode, through the
real script, with nothing stubbed. The unit suites assert each piece in
isolation; this is the one that fails if the SEAMS are wrong.

    python3 test/osk-tty-e2e.py

⚠️ NOT IN CI, AND NOT IN THE `test/unit/` GLOB, DELIBERATELY. It needs a
writable `/dev/uinput`, which a CI runner may not have -- and a test that skips
itself when a device is missing is a test that reports green while asserting
nothing. That is the exact failure mode this project exists to attack, so
running this is a deliberate act. `test/unit/test-deck-osk-tty.py` is the part
that runs everywhere.

⚠️ SAFETY: the mapper runs with `--dry-run`, so it creates NO virtual keyboard
and no keystroke reaches the session running this. Only the GAMEPAD is real,
and a gamepad node cannot type. Do not remove `--dry-run` on a desktop.
"""

from __future__ import annotations

import fcntl
import os
import re
import struct
import subprocess
import sys
import termios
import time

from evdev import UInput, ecodes as e

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAPPER = os.path.join(REPO_ROOT, "src", "deck-input-mapper.py")

FAILURES = 0


def check(what: str, got, want) -> None:
    global FAILURES
    if got == want:
        print(f"ok   {what}")
    else:
        print(f"FAIL {what}: got {got!r}, want {want!r}")
        FAILURES += 1


try:
    os.close(os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK))
except OSError as exc:
    print(f"CANNOT RUN: /dev/uinput is not writable ({exc}).")
    print("This suite needs it. It is NOT skipped-as-passed on purpose --")
    print("exiting non-zero so nothing reads this as a green run.")
    sys.exit(2)

# A Deck-shaped pad. The axis ranges are the measured ones (R-29..R-31), so the
# mapper reads its cursor geometry from the device exactly as it will on hardware.
PAD_CAPS = {
    e.EV_KEY: [e.BTN_SOUTH, e.BTN_EAST, e.BTN_NORTH, e.BTN_WEST, e.BTN_TL, e.BTN_TR,
               e.BTN_START, e.BTN_SELECT, e.BTN_MODE, e.BTN_TL2, e.BTN_TR2,
               e.BTN_DPAD_UP, e.BTN_DPAD_DOWN, e.BTN_DPAD_LEFT, e.BTN_DPAD_RIGHT],
    e.EV_ABS: [(code, (0, -32768, 32767, 0, 0, 0)) for code in
               (e.ABS_X, e.ABS_Y, e.ABS_HAT0X, e.ABS_HAT0Y, e.ABS_HAT1X, e.ABS_HAT1Y)]
    + [(code, (0, 0, 32767, 0, 0, 0)) for code in (e.ABS_HAT2X, e.ABS_HAT2Y)],
}
PAD_NAME = "Deck OSK e2e pad"

pad = UInput(PAD_CAPS, name=PAD_NAME, version=1)
time.sleep(0.6)  # udev has to settle before the mapper can enumerate it

master, slave = os.openpty()
# Give the pty a real size or "as low as it fits" has nothing to measure.
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))

proc = subprocess.Popen(
    [sys.executable, MAPPER, "--device", PAD_NAME, "--osk-backend", "tty",
     "--osk-tty", os.ttyname(slave), "--dry-run"],
    stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True,
)
time.sleep(1.2)

ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
ROW_MOVE = re.compile(r"\x1b\[(\d+);1H")


def press(code: int, value: int = 1) -> None:
    pad.write(e.EV_KEY, code, value)
    pad.syn()
    time.sleep(0.05)


def move(code: int, value: int) -> None:
    pad.write(e.EV_ABS, code, value)
    pad.syn()
    time.sleep(0.05)


def drain() -> str:
    out = b""
    os.set_blocking(master, False)
    for _ in range(40):
        try:
            chunk = os.read(master, 65536)
        except BlockingIOError:
            time.sleep(0.02)
            continue
        if not chunk:
            break
        out += chunk
    return out.decode(errors="replace")


def screen(raw: str) -> str:
    """Reassemble the console from the mapper's positioned writes.

    ⚠️ Segments must be CONCATENATED, not replaced. A highlighted line is split
    into several text tokens by the reverse-video escapes around the bracketed
    key, so keeping only the last one silently drops most of the row -- which
    is exactly how this harness first mis-read a correct render.
    """
    rows: dict[int, str] = {}
    pos = None
    for token in re.split(r"(\x1b\[[0-9;]*[A-Za-z])", raw):
        moved = ROW_MOVE.fullmatch(token)
        if moved:
            pos = int(moved.group(1))
            rows[pos] = ""
            continue
        if token.startswith("\x1b"):
            continue
        if pos is not None:
            rows[pos] += token
    return "\n".join(rows[n].rstrip() for n in sorted(rows) if rows[n].strip())


def chord() -> None:
    """STEAM+X."""
    press(e.BTN_MODE, 1)
    press(e.BTN_NORTH, 1)
    press(e.BTN_NORTH, 0)
    press(e.BTN_MODE, 0)
    time.sleep(0.4)


try:
    # --- nothing is drawn until the chord ------------------------------------
    check("nothing is drawn before the keyboard is summoned", screen(drain()), "")

    chord()
    shown = screen(drain())
    check("the chord draws the keyboard", "shift" in shown and "space" in shown, True)
    check("it draws five rows", len(shown.split("\n")), 5)
    check("both cursors start centred, one highlight per half",
          shown.count("[") == 2 and "[  d  ]" in shown and "[  k  ]" in shown, True)

    # --- two cursors, moved together, staying independent --------------------
    move(e.ABS_HAT0X, -32000)   # left pad -> top-left
    move(e.ABS_HAT0Y, 32000)
    move(e.ABS_HAT1X, 32000)    # right pad -> top-right
    move(e.ABS_HAT1Y, 32000)
    time.sleep(0.4)
    corners = screen(drain())
    # Digits carry their shifted symbol beside them now (T8 §9), in every
    # state including highlighted -- see deck_osk_tty.display_label's own
    # docstring for why that has to be true in BOTH states, not just at rest.
    check("the left cursor reached its half's top-left key", "[ 1 ! ]" in corners, True)
    check("the right cursor reached its OWN half's top-right key",
          "[ 0 ) ]" in corners, True)
    check("still exactly two highlights", corners.count("["), 2)

    # Both axes moving together on both pads -- the failure mode that shipped
    # once already (session 17: diagonals emitted nothing).
    move(e.ABS_HAT0X, -32000)
    move(e.ABS_HAT0Y, 3000)
    move(e.ABS_HAT1X, -20000)
    move(e.ABS_HAT1Y, 3000)
    time.sleep(0.4)
    home = screen(drain())
    check("a diagonal move lands the left cursor on the home row", "[  a  ]" in home, True)
    check("and the right cursor on its own home row", "[  h  ]" in home, True)

    # --- each trigger types the key under ITS OWN cursor ---------------------
    press(e.BTN_TL2, 1); press(e.BTN_TL2, 0)
    press(e.BTN_TR2, 1); press(e.BTN_TR2, 0)
    time.sleep(0.4)
    drain()

    # --- shift redraws the whole keyboard, and the next key is capitalised ---
    move(e.ABS_HAT0X, -32000)   # left cursor -> bottom-left = shift
    move(e.ABS_HAT0Y, -32000)
    time.sleep(0.2)
    press(e.BTN_TL2, 1); press(e.BTN_TL2, 0)
    time.sleep(0.3)
    shifted = screen(drain())
    check("pressing shift redraws the letters capitalised", "  Q  " in shifted, True)
    # The composite always leads with the CURRENTLY ACTIVE face -- "! 1", not
    # "1 !" -- once shift makes "!" the face `kb.face()` reports.
    check("and the digits as their shifted faces", "! 1" in shifted, True)
    check("and the shift key reports its own state", "Shift" in shifted, True)

    move(e.ABS_HAT1X, -20000)
    move(e.ABS_HAT1Y, 3000)
    time.sleep(0.2)
    press(e.BTN_TR2, 1); press(e.BTN_TR2, 0)
    time.sleep(0.4)
    drain()

    # --- the chord hides it, and erases what it drew -------------------------
    chord()
    tail = drain()
    # The tail also holds one legitimate redraw: BTN_MODE arrives as its own
    # report while the keyboard is still up. The erase is the LAST write.
    last = tail.rsplit("\x1b[s", 1)[-1]
    check("hiding erases every row it drew", last.count("\x1b[K"), 5)
    check("and writes no key text doing it",
          ANSI.sub("", last).strip(), "")
    check("and restores the cursor it borrowed", last.endswith("\x1b[u"), True)
finally:
    proc.terminate()
    try:
        _, err = proc.communicate(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        _, err = proc.communicate()
    pad.close()
    os.close(master)
    os.close(slave)

emitted = [ln.split(None, 1)[1] for ln in err.splitlines() if ln.startswith("emit ")]
check("the left trigger typed the key under the LEFT cursor (a)",
      emitted[:2], ["KEY_A 1", "KEY_A 0"])
check("the right trigger typed the key under the RIGHT cursor (h)",
      emitted[2:4], ["KEY_H 1", "KEY_H 0"])
check("a capital arrives as shift WRAPPING the key, not beside it",
      emitted[4:8],
      ["KEY_LEFTSHIFT 1", "KEY_H 1", "KEY_H 0", "KEY_LEFTSHIFT 0"])
check("and nothing else was emitted -- navigation keys stay silent while up",
      len(emitted), 8)

# --- the fallback that makes retiring squeekboard safe (T8 step 7) ----------
#
# ⚠️ The whole justification for pointing the unit at our own keyboard is that
# a failure hands the job back to squeekboard rather than leaving a handheld
# with no way to type. That claim is worth exactly as much as this test.
#
# Broken on purpose: no WAYLAND_DISPLAY, so the overlay cannot reach a
# compositor and exits. The mapper must notice and say so.

pad2 = UInput(PAD_CAPS, name="Deck OSK fallback pad", version=1)
time.sleep(0.6)
broken_env = {k: v for k, v in os.environ.items()
              if k not in ("WAYLAND_DISPLAY", "DISPLAY")}
fallback = subprocess.Popen(
    [sys.executable, MAPPER, "--device", "Deck OSK fallback pad",
     "--osk-backend", "layer", "--dry-run"],
    stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, env=broken_env,
)
time.sleep(1.2)
try:
    for code, value in ((e.BTN_MODE, 1), (e.BTN_NORTH, 1), (e.BTN_NORTH, 0), (e.BTN_MODE, 0)):
        pad2.write(e.EV_KEY, code, value)
        pad2.syn()
        time.sleep(0.05)
    time.sleep(2.5)
    # Nudge a pad so the mapper takes another run at the dead overlay: the
    # failure is detected on the next state write, not at spawn.
    for _ in range(3):
        pad2.write(e.EV_ABS, e.ABS_HAT1X, 20000)
        pad2.syn()
        time.sleep(0.3)
    time.sleep(1.0)
finally:
    fallback.terminate()
    try:
        _, fb_err = fallback.communicate(timeout=6)
    except subprocess.TimeoutExpired:
        fallback.kill()
        _, fb_err = fallback.communicate()
    pad2.close()

check("a failing overlay is reported, not swallowed",
      "falling back to squeekboard" in fb_err, True)
check("and the mapper survives it -- navigation outlives the keyboard",
      fallback.returncode in (0, -15), True)
check("the reason is named, not just the fact",
      any(word in fb_err for word in ("exited with status", "could not start",
                                      "went away")), True)

# --- a console that stops accepting writes (QEMU finding, session 18) -------
#
# ⚠️ Found in the VM suite, not here: `OSError: [Errno 5] Input/output error`
# out of `write_at`'s flush KILLED the whole mapper mid-run. A tty can start
# refusing writes for reasons that have nothing to do with us -- the VT was
# switched away, the console reconfigured -- and drawing a keyboard is optional
# while this process is the only input path. Closing the master end of a pty
# makes writes to the slave fail exactly that way.

pad3 = UInput(PAD_CAPS, name="Deck OSK eio pad", version=1)
time.sleep(0.6)
m3, s3 = os.openpty()
fcntl.ioctl(s3, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
eio = subprocess.Popen(
    [sys.executable, MAPPER, "--device", "Deck OSK eio pad", "--osk-backend", "tty",
     "--osk-tty", os.ttyname(s3), "--osk-top-row", "19", "--dry-run"],
    stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True,
)
time.sleep(1.2)
try:
    for code, value in ((e.BTN_MODE, 1), (e.BTN_NORTH, 1), (e.BTN_NORTH, 0), (e.BTN_MODE, 0)):
        pad3.write(e.EV_KEY, code, value)
        pad3.syn()
        time.sleep(0.05)
    time.sleep(0.8)
    check("the keyboard is up before the console breaks", eio.poll(), None)

    os.close(m3)          # the console stops accepting writes, mid-keyboard
    os.close(s3)
    time.sleep(0.4)
    for _ in range(4):    # every one of these tries to redraw
        pad3.write(e.EV_ABS, e.ABS_HAT1X, 20000)
        pad3.syn()
        time.sleep(0.25)
    time.sleep(1.0)
    check("the mapper SURVIVES a console that stops accepting writes",
          eio.poll(), None)
    # Navigation must outlive the keyboard: a button still maps to a key.
    pad3.write(e.EV_KEY, e.BTN_SOUTH, 1)
    pad3.syn()
    time.sleep(0.4)
finally:
    eio.terminate()
    try:
        _, eio_err = eio.communicate(timeout=6)
    except subprocess.TimeoutExpired:
        eio.kill()
        _, eio_err = eio.communicate()
    pad3.close()

check("it says the tty keyboard is disabled, rather than dying",
      "DISABLED" in eio_err, True)
check("and names the reason", "could not draw" in eio_err or "could not clear" in eio_err, True)
check("no traceback escaped", "Traceback" in eio_err, False)
check("navigation still works afterwards -- A still sends Enter",
      "KEY_ENTER 1" in eio_err.split("DISABLED", 1)[-1], True)

print()
print(f"{'PASS' if FAILURES == 0 else 'FAIL'} — {FAILURES} failure(s)")
sys.exit(1 if FAILURES else 0)
