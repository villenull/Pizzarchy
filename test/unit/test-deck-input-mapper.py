#!/usr/bin/env python3
"""Unit tests for deck-input-mapper's pure translation core.

No device, no uinput, no root: this drives Mapper.translate()/due_repeats()
with synthetic sequences and asserts on the emissions. Run directly:

    python3 test-deck-input-mapper.py
"""

from __future__ import annotations

import importlib.util
import pathlib
import sys

from evdev import ecodes as e

# ⚠️ Before loading anything -- see test-deck-osk-layout.py for the full story.
# A cached .pyc is validated against the source's (mtime, size) at one-second
# granularity, so a same-size edit within the same second runs the OLD code.
# The mapper imports deck_osk_layout at module load, so this suite can be hit
# through that import as well as directly.
sys.dont_write_bytecode = True

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "deck_input_mapper", REPO_ROOT / "src" / "deck-input-mapper.py"
)
m = importlib.util.module_from_spec(spec)
# Register before exec: dataclasses resolves field types via
# sys.modules[cls.__module__], which is None for an unregistered module.
sys.modules["deck_input_mapper"] = m
spec.loader.exec_module(m)

FAILURES = 0


def check(what: str, got, want) -> None:
    global FAILURES
    if got == want:
        print(f"ok   {what} = {got!r}")
    else:
        print(f"FAIL {what}: got {got!r}, want {want!r}")
        FAILURES += 1


def fresh() -> "m.Mapper":
    return m.Mapper(axis_ranges={e.ABS_X: (-32768, 32767), e.ABS_Y: (-32768, 32767)})


# --- buttons -----------------------------------------------------------------

mm = fresh()
check("A press -> Enter down", mm.translate(e.EV_KEY, e.BTN_SOUTH, 1, 0.0), [(e.KEY_ENTER, 1)])
check("A release -> Enter up", mm.translate(e.EV_KEY, e.BTN_SOUTH, 0, 0.0), [(e.KEY_ENTER, 0)])
check("B press -> Esc down", mm.translate(e.EV_KEY, e.BTN_EAST, 1, 0.0), [(e.KEY_ESC, 1)])
check("Y press -> Space down", mm.translate(e.EV_KEY, e.BTN_WEST, 1, 0.0), [(e.KEY_SPACE, 1)])
check("pad autorepeat ignored", mm.translate(e.EV_KEY, e.BTN_SOUTH, 2, 0.0), [])
check("unmapped button ignored", mm.translate(e.EV_KEY, e.BTN_THUMBL, 1, 0.0), [])
check("unmapped type ignored", mm.translate(e.EV_REL, e.REL_X, 5, 0.0), [])

# --- device ABS_HAT0* is the LEFT TRACKPAD, and must be IGNORED -------------
#
# Measured on hardware 2026-08-10: sliding the left trackpad moves ABS_HAT0X/Y
# across the full +/-32767 analog range. The suite used to drive those codes as
# a d-pad, because the capability list advertises them and the name looks like
# one. Treating them as directions emits arrow keys for a thumb resting on the
# pad. The real d-pad is BTN_DPAD_*, covered below.

mm = fresh()
check("left-trackpad motion emits no key (was read as a d-pad)",
      mm.translate(e.EV_ABS, e.ABS_HAT0Y, 20000, 0.0), [])
check("left-trackpad motion on the other axis is also silent",
      mm.translate(e.EV_ABS, e.ABS_HAT0X, -25000, 0.1), [])
check("returning to centre stays silent too",
      mm.translate(e.EV_ABS, e.ABS_HAT0Y, 0, 0.2), [])

# Analog triggers are buttons elsewhere; their axes must not become directions.
check("analog trigger axis emits no key",
      mm.translate(e.EV_ABS, e.ABS_HAT2X, 32767, 0.3), [])

# --- d-pad as DISCRETE BUTTONS -- what the Deck actually sends ----------------
#
# The section above models the d-pad as hat axes. `hid-steam` advertises those
# axes but never sends them: on hardware the d-pad arrives as BTN_DPAD_*, and
# before DPAD_BUTTON_MAP existed every one of those presses emitted nothing.
# The suite passed anyway, because it only ever asked about the axes. These
# assertions are the ones that fail if that regresses.

mm = fresh()
check("d-pad Up button -> Up down", mm.translate(e.EV_KEY, e.BTN_DPAD_UP, 1, 0.0), [(e.KEY_UP, 1)])
check("d-pad button autorepeat ignored", mm.translate(e.EV_KEY, e.BTN_DPAD_UP, 2, 0.1), [])
# The check above cannot fail alone: repeating an already-held direction is a
# no-op through the hat state machine whether or not the value-2 guard exists
# (mutation-tested -- it survived). This one pins the guard itself, because
# without it a stray repeat would be treated as a press and engage a direction
# that was never pressed.
check("autorepeat for an UNHELD d-pad button stays quiet",
      fresh().translate(e.EV_KEY, e.BTN_DPAD_UP, 2, 0.0), [])
check("d-pad Up release -> Up up", mm.translate(e.EV_KEY, e.BTN_DPAD_UP, 0, 0.2), [(e.KEY_UP, 0)])
check("d-pad Down button -> Down down", mm.translate(e.EV_KEY, e.BTN_DPAD_DOWN, 1, 0.3), [(e.KEY_DOWN, 1)])
check("d-pad Left button -> Left down", mm.translate(e.EV_KEY, e.BTN_DPAD_LEFT, 1, 0.4), [(e.KEY_LEFT, 1)])
check("d-pad Right on the other axis is independent",
      mm.translate(e.EV_KEY, e.BTN_DPAD_LEFT, 0, 0.5), [(e.KEY_LEFT, 0)])

# Opposing edges held together cancel, exactly as a physical hat would, so no
# key can stick down when both are released out of order.
mm = fresh()
mm.translate(e.EV_KEY, e.BTN_DPAD_UP, 1, 0.0)
check("opposing d-pad edge cancels to neutral",
      mm.translate(e.EV_KEY, e.BTN_DPAD_DOWN, 1, 0.1), [(e.KEY_UP, 0)])
check("releasing one edge re-engages the other",
      mm.translate(e.EV_KEY, e.BTN_DPAD_UP, 0, 0.2), [(e.KEY_DOWN, 1)])

# The d-pad buttons must share the hat state with the stick, or holding both
# would double-press one direction.
mm = fresh()
mm.translate(e.EV_KEY, e.BTN_DPAD_DOWN, 1, 0.0)
check("stick agreeing with a held d-pad button is quiet",
      mm.translate(e.EV_ABS, e.ABS_Y, 25000, 0.1), [])

# Auto-repeat has to work for a direction engaged by button, not just by axis.
mm = fresh()
mm.translate(e.EV_KEY, e.BTN_DPAD_LEFT, 1, 100.0)
check("d-pad button schedules auto-repeat",
      mm.due_repeats(100.0 + m.REPEAT_DELAY + 0.01), [(e.KEY_LEFT, 2)])
mm.translate(e.EV_KEY, e.BTN_DPAD_LEFT, 0, 101.0)
check("d-pad button release clears repeats", mm.due_repeats(200.0), [])

# --- a RESTING stick must not cancel a held direction -------------------------
#
# Measured on hardware: with the d-pad held, the very next resting-stick sample
# released the key ~10ms in and killed auto-repeat, because the stick's
# hysteresis branch keyed off "a key is held" rather than "the stick is
# engaged". The sticks jitter continuously, so this fired constantly and made
# the d-pad useless for holding a direction.
#
# The old suite only ever moved the stick to an ENGAGED position while a
# direction was held, which agrees with the held key and is quiet either way.
# Resting is the case that distinguishes the two.

mm = fresh()
mm.translate(e.EV_KEY, e.BTN_DPAD_UP, 1, 0.0)
check("resting stick does NOT release a held d-pad direction",
      mm.translate(e.EV_ABS, e.ABS_Y, 0, 0.1), [])
check("stick jitter does NOT release a held d-pad direction",
      mm.translate(e.EV_ABS, e.ABS_Y, 900, 0.2), [])
check("auto-repeat survives stick jitter under a held d-pad",
      mm.due_repeats(m.REPEAT_DELAY + 0.3), [(e.KEY_UP, 2)])
check("the d-pad still releases on its own release",
      mm.translate(e.EV_KEY, e.BTN_DPAD_UP, 0, 0.4), [(e.KEY_UP, 0)])

# Two separate changes fix the hardware defect above, and the checks so far
# only pin one of them: direction precedence. Reverting the hysteresis to key
# off active_key still passes them, because the d-pad wins regardless
# (mutation-tested -- it survived). This case pins the hysteresis itself.
#
# A stick between RELEASE (0.35) and ENGAGE (0.5) has NOT engaged from rest.
# Keyed off active_key it would take the hysteresis branch while the d-pad
# holds the axis, latch stick_dir, and then grab the axis the moment the d-pad
# lets go -- a direction the user never pushed hard enough to ask for.
mm = fresh()
mm.translate(e.EV_KEY, e.BTN_DPAD_UP, 1, 0.0)
mm.translate(e.EV_ABS, e.ABS_Y, 13000, 0.1)  # frac 0.397: past release, under engage
check("a sub-engage stick does not latch while the d-pad owns the axis",
      mm.translate(e.EV_KEY, e.BTN_DPAD_UP, 0, 0.2), [(e.KEY_UP, 0)])

# With no digital input held, the stick still owns the axis outright.
mm = fresh()
mm.translate(e.EV_ABS, e.ABS_Y, 25000, 0.0)
check("stick alone still releases when it returns to rest",
      mm.translate(e.EV_ABS, e.ABS_Y, 0, 0.1), [(e.KEY_DOWN, 0)])

# Releasing the d-pad while the stick is genuinely pushed hands the axis back
# to the stick rather than going neutral.
mm = fresh()
mm.translate(e.EV_ABS, e.ABS_Y, 25000, 0.0)          # stick down -> KEY_DOWN
mm.translate(e.EV_KEY, e.BTN_DPAD_UP, 1, 0.1)        # d-pad up overrides
check("d-pad overrides a pushed stick",
      mm.translate(e.EV_KEY, e.BTN_DPAD_UP, 2, 0.15), [])
check("releasing the d-pad hands the axis back to the pushed stick",
      mm.translate(e.EV_KEY, e.BTN_DPAD_UP, 0, 0.2), [(e.KEY_UP, 0), (e.KEY_DOWN, 1)])

# --- stick with hysteresis ---------------------------------------------------

mm = fresh()
check("stick at rest is quiet", mm.translate(e.EV_ABS, e.ABS_Y, 0, 0.0), [])
check("stick past engage -> Down", mm.translate(e.EV_ABS, e.ABS_Y, 20000, 0.0), [(e.KEY_DOWN, 1)])
check("stick jitter above release holds", mm.translate(e.EV_ABS, e.ABS_Y, 13000, 0.1), [])
check("stick under release -> Down up", mm.translate(e.EV_ABS, e.ABS_Y, 5000, 0.2), [(e.KEY_DOWN, 0)])
check("sub-engage after release stays quiet", mm.translate(e.EV_ABS, e.ABS_Y, 14000, 0.3), [])
check("stick up direction", mm.translate(e.EV_ABS, e.ABS_Y, -30000, 0.4), [(e.KEY_UP, 1)])

# stick and d-pad share the hat state: no double-hold of one direction
mm = fresh()
mm.translate(e.EV_KEY, e.BTN_DPAD_DOWN, 1, 0.0)
check("stick agreeing with a held d-pad is quiet", mm.translate(e.EV_ABS, e.ABS_Y, 25000, 0.1), [])

# --- auto-repeat scheduling --------------------------------------------------

mm = fresh()
mm.translate(e.EV_KEY, e.BTN_DPAD_DOWN, 1, 100.0)
check("no repeat before delay", mm.due_repeats(100.0 + m.REPEAT_DELAY - 0.01), [])
check("repeat after delay", mm.due_repeats(100.0 + m.REPEAT_DELAY + 0.01), [(e.KEY_DOWN, 2)])
check(
    "second repeat after interval",
    mm.due_repeats(100.0 + m.REPEAT_DELAY + m.REPEAT_INTERVAL + 0.02),
    [(e.KEY_DOWN, 2)],
)
check("deadline exists while held", mm.next_deadline() is not None, True)
mm.translate(e.EV_KEY, e.BTN_DPAD_DOWN, 0, 101.0)
check("release clears repeats", mm.due_repeats(200.0), [])
check("deadline cleared on release", mm.next_deadline(), None)

# --- triggers become mouse buttons ------------------------------------------
#
# Matching lizard mode's own convention so muscle memory carries over: R2 is
# left click, L2 is right click. Without these the pointer below can move but
# can never select anything.

mm = fresh()
check("R2 press -> left click down", mm.translate(e.EV_KEY, e.BTN_TR2, 1, 0.0), [(e.BTN_LEFT, 1)])
check("R2 release -> left click up", mm.translate(e.EV_KEY, e.BTN_TR2, 0, 0.1), [(e.BTN_LEFT, 0)])
check("L2 press -> right click down", mm.translate(e.EV_KEY, e.BTN_TL2, 1, 0.2), [(e.BTN_RIGHT, 1)])
check("trigger autorepeat ignored", mm.translate(e.EV_KEY, e.BTN_TR2, 2, 0.3), [])

# --- STEAM+X toggles the on-screen keyboard ---------------------------------
#
# BTN_MODE is the STEAM button, visible only with lizard_mode=N. The action is
# QUEUED rather than performed so the chord is testable without a DBus session,
# and so a hung DBus call can never block the input loop.

mm = fresh()
check("STEAM alone emits nothing", mm.translate(e.EV_KEY, e.BTN_MODE, 1, 0.0), [])
check("X while STEAM is held does not also type Tab",
      mm.translate(e.EV_KEY, e.BTN_NORTH, 1, 0.1), [])
check("the chord queued an OSK toggle", mm.pending_actions, ["toggle-osk"])

# X on its own must still be Tab, or the chord would cost the installer its
# next-field key.
mm = fresh()
check("X alone is still Tab", mm.translate(e.EV_KEY, e.BTN_NORTH, 1, 0.0), [(e.KEY_TAB, 1)])
check("X alone queues nothing", mm.pending_actions, [])

# Releasing STEAM must disarm the chord.
mm = fresh()
mm.translate(e.EV_KEY, e.BTN_MODE, 1, 0.0)
mm.translate(e.EV_KEY, e.BTN_MODE, 0, 0.1)
check("X after STEAM is released is Tab again",
      mm.translate(e.EV_KEY, e.BTN_NORTH, 1, 0.2), [(e.KEY_TAB, 1)])
check("no toggle queued once STEAM is released", mm.pending_actions, [])

# --- the pointer, from the RIGHT trackpad -----------------------------------
#
# The pad reports ABSOLUTE position while touched and nothing when lifted, so
# differencing across a lift would hurl the cursor the width of the pad.

mm = fresh()
check("first sample of a touch only baselines, it does not move",
      mm.pointer_delta(e.ABS_HAT1X, 10000, 0.0), (0, 0))
check("a later sample in the same touch moves by the difference",
      mm.pointer_delta(e.ABS_HAT1X, 10000 + m.POINTER_DIVISOR * 3, 0.05), (3, 0))

# The Y axis is inverted: the pad grows upward, screens grow downward.
mm = fresh()
mm.pointer_delta(e.ABS_HAT1Y, 0, 0.0)
check("pad Y is inverted for the screen",
      mm.pointer_delta(e.ABS_HAT1Y, m.POINTER_DIVISOR * 4, 0.05), (0, -4))

# The case that makes a trackpad usable at all: lift, move the finger, touch
# down elsewhere. Without a re-baseline this jumps the cursor across the screen.
mm = fresh()
mm.pointer_delta(e.ABS_HAT1X, 0, 0.0)
mm.pointer_delta(e.ABS_HAT1X, m.POINTER_DIVISOR, 0.05)
check("a gap longer than the touch threshold re-baselines instead of jumping",
      mm.pointer_delta(e.ABS_HAT1X, 30000, 0.05 + m.POINTER_TOUCH_GAP + 0.01), (0, 0))
check("and motion resumes normally from the new baseline",
      mm.pointer_delta(e.ABS_HAT1X, 30000 + m.POINTER_DIVISOR * 2,
                       0.05 + m.POINTER_TOUCH_GAP + 0.06), (2, 0))

# Sub-threshold movement must accumulate, or slow precise motion never moves
# the cursor at all.
mm = fresh()
mm.pointer_delta(e.ABS_HAT1X, 0, 0.0)
mm.pointer_delta(e.ABS_HAT1X, 10, 0.02)
check("a sub-pixel sample emits nothing but keeps its baseline",
      mm.pointer_delta(e.ABS_HAT1X, 20, 0.04), (0, 0))
check("accumulated sub-pixel motion eventually moves the cursor",
      mm.pointer_delta(e.ABS_HAT1X, m.POINTER_DIVISOR + 5, 0.06), (1, 0))

# Lifting a finger makes the pad report 0, which differencing turns into a
# swipe from wherever the thumb was to the centre -- the measured cause of the
# cursor "jumping around". A quick lift-and-retouch lands inside the touch-gap
# window, so the gap timer alone does not catch it.
mm = fresh()
mm.pointer_delta(e.ABS_HAT1X, 0, 0.0)
mm.pointer_delta(e.ABS_HAT1X, 20000, 0.01)   # discontinuity: absorbed
check("a release-to-centre jump emits no motion",
      mm.pointer_delta(e.ABS_HAT1X, 0, 0.02), (0, 0))
check("and the next real movement is measured from the new baseline",
      mm.pointer_delta(e.ABS_HAT1X, m.POINTER_DIVISOR * 5, 0.03), (5, 0))

# The clamp must not swallow ordinary movement, or the pointer stops working.
mm = fresh()
mm.pointer_delta(e.ABS_HAT1X, 0, 0.0)
check("a normal-sized movement still passes the jump clamp",
      mm.pointer_delta(e.ABS_HAT1X, m.POINTER_JUMP_RAW - 1, 0.01),
      ((m.POINTER_JUMP_RAW - 1) // m.POINTER_DIVISOR, 0))

# Motion must be SYMMETRIC. Floor division rounds toward negative infinity, so
# `//` made leftward movement nearly twice as fast as rightward and flipped the
# rounding mid-gesture -- measured as a cursor that jumped between movements.
mm = fresh()
mm.pointer_delta(e.ABS_HAT1X, 0, 0.0)
right = mm.pointer_delta(e.ABS_HAT1X, m.POINTER_DIVISOR + m.POINTER_DIVISOR // 4, 0.01)
mm = fresh()
mm.pointer_delta(e.ABS_HAT1X, 0, 0.0)
left = mm.pointer_delta(e.ABS_HAT1X, -(m.POINTER_DIVISOR + m.POINTER_DIVISOR // 4), 0.01)
check("equal movement left and right travels equally far",
      (right[0], -left[0]), (1, 1))

# The emitted remainder must be carried, or every step silently drops a
# fraction of a pixel and slow motion crawls unevenly.
mm = fresh()
mm.pointer_delta(e.ABS_HAT1X, 0, 0.0)
mm.pointer_delta(e.ABS_HAT1X, m.POINTER_DIVISOR + m.POINTER_DIVISOR - 1, 0.01)  # emits 1, carries the rest
check("the sub-pixel remainder carries into the next sample",
      mm.pointer_delta(e.ABS_HAT1X, m.POINTER_DIVISOR * 2, 0.02), (1, 0))

# ⚠️ BOTH AXES TOGETHER -- the case every other pointer test here missed.
#
# X and Y arrive in the same report. Re-baselining used to replace the whole
# baseline dict, so each axis wiped the other's baseline every sample and the
# pointer emitted NOTHING while both moved -- it worked only for pure
# horizontal or pure vertical strokes. Every test above drives one axis, which
# is exactly why the suite stayed green while the cursor was unusable.
mm = fresh()
mm.pointer_delta(e.ABS_HAT1X, 0, 0.0)
mm.pointer_delta(e.ABS_HAT1Y, 0, 0.0)
dx, _ = mm.pointer_delta(e.ABS_HAT1X, m.POINTER_DIVISOR * 3, 0.004)
_, dy = mm.pointer_delta(e.ABS_HAT1Y, m.POINTER_DIVISOR * 3, 0.004)
check("diagonal movement emits on BOTH axes", (dx, dy), (3, -3))

# And it must keep working sample after sample, not just once.
dx2, _ = mm.pointer_delta(e.ABS_HAT1X, m.POINTER_DIVISOR * 6, 0.008)
_, dy2 = mm.pointer_delta(e.ABS_HAT1Y, m.POINTER_DIVISOR * 6, 0.008)
check("diagonal movement keeps emitting on both axes", (dx2, dy2), (3, -3))

# A jump on one axis must not re-baseline the other.
mm = fresh()
mm.pointer_delta(e.ABS_HAT1X, 0, 0.0)
mm.pointer_delta(e.ABS_HAT1Y, 0, 0.0)
mm.pointer_delta(e.ABS_HAT1X, 30000, 0.004)          # X jumps: X alone re-baselines
_, dy3 = mm.pointer_delta(e.ABS_HAT1Y, m.POINTER_DIVISOR * 2, 0.004)
check("a jump on one axis leaves the other axis measuring normally", dy3, -2)

# The LEFT trackpad must never drive the pointer -- only the right one does.
mm = fresh()
mm.pointer_delta(e.ABS_HAT0X, 0, 0.0)
check("left trackpad does not move the pointer",
      mm.pointer_delta(e.ABS_HAT0X, 30000, 0.05), (0, 0))

# --- emitted-keys contract ---------------------------------------------------
#
# ⚠️ The sharpest assertion in this suite. A uinput device emits ONLY the codes
# it declared at creation, and the kernel drops the rest with no error on any
# side -- so a key missing from here is dead on the Deck and nothing reports it.
#
# The navigation set is written out longhand rather than derived from the
# mapping tables: deriving it would make the assertion agree with whatever the
# tables happen to say, which is not a contract.

NAV_KEYS = {e.KEY_ENTER, e.KEY_ESC, e.KEY_SPACE, e.KEY_TAB, e.KEY_PAGEUP,
            e.KEY_PAGEDOWN, e.KEY_LEFT, e.KEY_RIGHT, e.KEY_UP, e.KEY_DOWN,
            e.BTN_LEFT, e.BTN_RIGHT}

check("the OSK layout core loaded (without it every character key is absent)",
      m.osk_layout is not None, True)
check(
    "virtual keyboard advertises the navigation keys AND every OSK key",
    sorted(m.EMITTED_KEYS),
    sorted(NAV_KEYS | set(m.osk_layout.OSK_KEYCODES)),
)
check("it advertises nothing beyond those two sources",
      sorted(set(m.EMITTED_KEYS) - NAV_KEYS - set(m.osk_layout.OSK_KEYCODES)), [])
check("the shift modifier is advertised -- capitals are silent without it",
      e.KEY_LEFTSHIFT in m.EMITTED_KEYS, True)
# Spot-check a character key by hand, so this cannot pass by both sides being
# empty: KEY_A is on no navigation path and must arrive purely from the layouts.
check("a character key made it into the declared set", e.KEY_A in m.EMITTED_KEYS, True)

# --- the missing-core fallback -----------------------------------------------
#
# With lizard_mode=N the mapper is the only input path on the device, so a
# missing layout core must cost the OSK and nothing else. This asserts the
# search is a real lookup rather than a hardcoded path that happens to exist.

check("the core is searched for beside the script and in the install dir",
      [p.name for p in m.OSK_SEARCH_DIRS], ["src", "deck-osk"])

import contextlib  # noqa: E402 -- local to this block
import io  # noqa: E402
import pathlib as _pathlib  # noqa: E402

_saved_dirs = m.OSK_SEARCH_DIRS
m.OSK_SEARCH_DIRS = (_pathlib.Path("/nonexistent/deck-osk"),)
_stderr = io.StringIO()
with contextlib.redirect_stderr(_stderr):
    _missing = m._load_osk_layout()
m.OSK_SEARCH_DIRS = _saved_dirs
check("a missing core returns None rather than raising", _missing, None)
check("and says so on stderr rather than failing silently",
      "DISABLED" in _stderr.getvalue(), True)
check("and names the module it could not find",
      "deck_osk_layout.py" in _stderr.getvalue(), True)

# --- device selection: Steam's virtual pad must never be bound ----------------
#
# Measured 2026-08-10: starting Steam on the DESKTOP makes the native "Steam
# Deck" node disappear and re-presents the controller as "Microsoft X-Box 360
# pad 0". Selecting purely on the BTN_SOUTH capability matched that pad too, so
# the mapper latched onto it and would have injected a keystroke for every
# press Steam was already handling.


class FakeDev:
    """Minimal stand-in for evdev.InputDevice: name + capabilities only."""

    def __init__(self, name, path="/dev/input/eventX", south=True):
        self.name = name
        self.path = path
        self._south = south

    def capabilities(self):
        return {e.EV_KEY: [e.BTN_SOUTH]} if self._south else {e.EV_KEY: [e.BTN_A - 1]}


check("the native Deck pad is accepted",
      m.looks_like_gamepad(FakeDev("Steam Deck")), True)
check("Steam's virtual pad is REJECTED",
      m.looks_like_gamepad(FakeDev("Microsoft X-Box 360 pad 0")), False)
check("the virtual pad is identified by name",
      m.is_steam_virtual_pad(FakeDev("Microsoft X-Box 360 pad 0")), True)
check("a differently-indexed virtual pad is still identified",
      m.is_steam_virtual_pad(FakeDev("Microsoft X-Box 360 pad 3")), True)
check("the native pad is not mistaken for Steam's",
      m.is_steam_virtual_pad(FakeDev("Steam Deck")), False)
check("a device without BTN_SOUTH is still rejected",
      m.looks_like_gamepad(FakeDev("Steam Deck Motion Sensors", south=False)), False)

# The selector path must apply the same exclusion, or --device would reintroduce it.
check("_match skips Steam's pad and finds the native one",
      m._match([FakeDev("Microsoft X-Box 360 pad 0"), FakeDev("Steam Deck")], None).name,
      "Steam Deck")
check("_match returns None when only Steam's pad is present",
      m._match([FakeDev("Microsoft X-Box 360 pad 0")], None), None)
check("_match with a selector still excludes Steam's pad",
      m._match([FakeDev("Microsoft X-Box 360 pad 0")], "x-box"), None)

print(f"\n{'PASS' if FAILURES == 0 else 'FAILED'} — {FAILURES} failure(s)")
sys.exit(1 if FAILURES else 0)
