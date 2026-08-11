#!/usr/bin/env python3
"""The mapper must survive its pad disappearing (session 18, hardware finding).

    python3 test/mapper-pad-loss-e2e.py

⚠️ WHY THIS EXISTS. T8 step 7's hardware pass found the mapper crashing six
times in one boot on the real Deck: `OSError: [Errno 19] No such device` out of
`pad.read()`, when the controller re-enumerated. Each crash killed the process
and systemd restarted it -- until it would not, because `StartLimitBurst` is 5
in 60 seconds. With `lizard_mode=N` this process is the ONLY input path on the
device, so exhausting that limit leaves a handheld with no pointer and no keys,
recoverable only over SSH.

Nothing in the repo could see it. The unit suites drive `Mapper.translate()`,
which never touches a device; the OSK end-to-end suite uses a pad that stays
put. The failure needs the node to go away underneath a live read, which is
what this does.

⚠️ NOT IN CI and NOT in the `test/unit/` glob: it needs a writable
`/dev/uinput`, and a suite that skips itself when a device is missing reports
green while asserting nothing.

⚠️ SAFETY: `--dry-run`, so the mapper creates no virtual keyboard and nothing is
injected into the session running this. Only the gamepad is virtual.
"""

from __future__ import annotations

import os
import subprocess
import sys
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
    print(f"CANNOT RUN: /dev/uinput is not writable ({exc}). Exiting non-zero so")
    print("nothing reads this as a green run.")
    sys.exit(2)

PAD_CAPS = {
    e.EV_KEY: [e.BTN_SOUTH, e.BTN_EAST, e.BTN_NORTH, e.BTN_WEST, e.BTN_MODE,
               e.BTN_TL2, e.BTN_TR2, e.BTN_DPAD_UP],
    e.EV_ABS: [(c, (0, -32768, 32767, 0, 0, 0)) for c in
               (e.ABS_X, e.ABS_Y, e.ABS_HAT0X, e.ABS_HAT0Y, e.ABS_HAT1X, e.ABS_HAT1Y)],
}
PAD_NAME = "Deck padloss e2e pad"

pad = UInput(PAD_CAPS, name=PAD_NAME, version=1)
time.sleep(0.6)

proc = subprocess.Popen(
    [sys.executable, MAPPER, "--device", PAD_NAME, "--dry-run"],
    stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True,
)
time.sleep(1.2)
check("the mapper starts on the pad", proc.poll(), None)

# A press, so we know it is really reading before the node goes away.
pad.write(e.EV_KEY, e.BTN_SOUTH, 1)
pad.syn()
time.sleep(0.3)

# ⚠️ THE EVENT ITSELF: destroy the node underneath a live read.
pad.close()
time.sleep(2.0)

check("the mapper SURVIVES the pad vanishing (it used to exit 1)",
      proc.poll(), None)

# Bring an identical pad back, as a re-enumeration would.
pad2 = UInput(PAD_CAPS, name=PAD_NAME, version=1)
time.sleep(2.5)
check("and it is still alive once the pad returns", proc.poll(), None)

pad2.write(e.EV_KEY, e.BTN_SOUTH, 1)
pad2.syn()
pad2.write(e.EV_KEY, e.BTN_SOUTH, 0)
pad2.syn()
time.sleep(0.8)

proc.terminate()
try:
    _, err = proc.communicate(timeout=6)
except subprocess.TimeoutExpired:
    proc.kill()
    _, err = proc.communicate()
pad2.close()

check("it said the pad disappeared, rather than dying quietly",
      "the pad disappeared" in err, True)
check("and it re-bound to the replacement", "re-bound to" in err, True)
check("no traceback escaped", "Traceback" in err, False)

# The proof it is genuinely working again, not merely running: a press on the
# REPLACEMENT pad has to come out the other side.
after = err.split("re-bound to", 1)[-1]
check("a press on the new pad still maps to Enter",
      "KEY_ENTER 1" in after, True)

print()
print(f"{'PASS' if FAILURES == 0 else 'FAIL'} — {FAILURES} failure(s)")
sys.exit(1 if FAILURES else 0)
