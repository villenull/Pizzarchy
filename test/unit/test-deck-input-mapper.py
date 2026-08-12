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
# ⚠️ NOT `pending_actions == []` any more. That bare press-and-release is now a
# TAP, and a tap queues the apps menu (§5.23, covered in its own section below).
# What must stay true here is that the CHORD is disarmed -- X arriving after the
# release must not toggle the keyboard.
check("no OSK toggle queued once STEAM is released",
      "toggle-osk" in mm.pending_actions, False)

# --- STEAM taps and QAM open Omarchy's menus (docs/PROGRESS.md §5.23) --------
#
# Operator request: STEAM -> the apps menu, QAM -> the menu at the bar's
# top-left. The menus are EXEC'd rather than synthesised as SUPER+ALT+SPACE,
# because a synthesised chord only works while the user's keybinds still say
# what upstream's defaults say -- and upstream edited those bindings in this
# release cycle. What that costs is a coupling to `omarchy-menu`'s subcommand
# NAMES, which is what the argv assertions below pin.
#
# STEAM is already the OSK chord's hold key, so a tap is only a tap if nothing
# was pressed during the hold -- which is why it resolves on RELEASE.
#
# ⚠️ NOTHING HERE STARTS A PROCESS. translate() only queues an action name; the
# spawn is stubbed (FakeSubprocess) so this suite still needs no Omarchy, no
# compositor, no DBus and no root.

import contextlib  # noqa: E402 -- the suite is a script; these are block-local
import io  # noqa: E402
import subprocess as _subprocess  # noqa: E402
import tempfile  # noqa: E402

check("the apps menu is exactly upstream's command",
      m.MENU_ACTIONS["menu-apps"], ["omarchy-menu", "toggle", "apps"])
check("the bar's own menu is the ROOT command, with no subcommand",
      m.MENU_ACTIONS["menu-root"], ["omarchy-menu", "toggle"])

# Fire on RELEASE, not on press: firing on the press would open the apps menu
# underneath every STEAM+X the operator makes, and STEAM+X is hardware-proven.
mm = fresh()
check("STEAM pressed emits nothing", mm.translate(e.EV_KEY, e.BTN_MODE, 1, 0.0), [])
check("and queues nothing yet -- a tap is not decided until the release",
      mm.pending_actions, [])
check("STEAM released emits no keystroke either",
      mm.translate(e.EV_KEY, e.BTN_MODE, 0, 0.1), [])
check("a clean STEAM tap queues the APPS menu", mm.pending_actions, ["menu-apps"])

# The chord must be untouched: it is hardware-proven (R-43) and relied on.
mm = fresh()
mm.translate(e.EV_KEY, e.BTN_MODE, 1, 0.0)
check("X under STEAM still does not type Tab",
      mm.translate(e.EV_KEY, e.BTN_NORTH, 1, 0.1), [])
mm.translate(e.EV_KEY, e.BTN_NORTH, 0, 0.2)
check("releasing STEAM after the chord emits nothing",
      mm.translate(e.EV_KEY, e.BTN_MODE, 0, 0.3), [])
check("STEAM+X toggles the OSK and opens NO menu", mm.pending_actions, ["toggle-osk"])

# Any partner disarms the tap, not just X: STEAM+A still sends Enter underneath,
# and letting go afterwards must not also open a menu nobody asked for.
mm = fresh()
mm.translate(e.EV_KEY, e.BTN_MODE, 1, 0.0)
check("A pressed under STEAM still sends Enter",
      mm.translate(e.EV_KEY, e.BTN_SOUTH, 1, 0.1), [(e.KEY_ENTER, 1)])
mm.translate(e.EV_KEY, e.BTN_SOUTH, 0, 0.2)
mm.translate(e.EV_KEY, e.BTN_MODE, 0, 0.3)
check("STEAM+A is a chord, not a tap: no menu", mm.pending_actions, [])

mm = fresh()
mm.translate(e.EV_KEY, e.BTN_MODE, 1, 0.0)
mm.translate(e.EV_KEY, e.BTN_TR2, 1, 0.1)          # a trigger click counts too
mm.translate(e.EV_KEY, e.BTN_MODE, 0, 0.2)
check("a trigger click under STEAM also disarms the tap", mm.pending_actions, [])

# Only presses that START during the hold count. A button already down when
# STEAM goes down, and let go during it, is not a chord the user performed.
# ⚠️ `value in (0, 1)` here -- a plausible copy-paste from the branch above --
# swallows that tap, and this is the only assertion that catches it
# (mutation-tested: without it, that fault survives the whole suite).
mm = fresh()
mm.translate(e.EV_KEY, e.BTN_SOUTH, 1, 0.0)     # A is already held
mm.translate(e.EV_KEY, e.BTN_MODE, 1, 0.1)
mm.translate(e.EV_KEY, e.BTN_SOUTH, 0, 0.2)     # and released during the hold
mm.translate(e.EV_KEY, e.BTN_MODE, 0, 0.3)
check("a button released -- not pressed -- during the hold still leaves a tap",
      mm.pending_actions, ["menu-apps"])

# A resting thumb is NOT a chord partner, or the tap would be unusable on a
# handheld where both pads are under the thumbs.
mm = fresh()
mm.translate(e.EV_KEY, e.BTN_MODE, 1, 0.0)
mm.translate(e.EV_ABS, e.ABS_HAT1X, 20000, 0.1)    # right trackpad
mm.translate(e.EV_ABS, e.ABS_Y, 25000, 0.15)       # and the stick
mm.translate(e.EV_KEY, e.BTN_MODE, 0, 0.2)
check("pad and stick movement during the hold still leaves a tap",
      mm.pending_actions, ["menu-apps"])

# The partner flag is armed on every PRESS, so a chord cannot poison the tap
# that follows it -- the failure mode of clearing it only on release.
mm = fresh()
mm.translate(e.EV_KEY, e.BTN_MODE, 1, 0.0)
mm.translate(e.EV_KEY, e.BTN_NORTH, 1, 0.1)
mm.translate(e.EV_KEY, e.BTN_MODE, 0, 0.2)
mm.pending_actions.clear()
mm.translate(e.EV_KEY, e.BTN_MODE, 1, 1.0)
mm.translate(e.EV_KEY, e.BTN_MODE, 0, 1.1)
check("a chord does not poison the tap after it", mm.pending_actions, ["menu-apps"])

mm = fresh()
mm.translate(e.EV_KEY, e.BTN_MODE, 1, 0.0)
mm.translate(e.EV_KEY, e.BTN_MODE, 0, 0.1)
mm.translate(e.EV_KEY, e.BTN_MODE, 1, 0.5)
mm.translate(e.EV_KEY, e.BTN_MODE, 0, 0.6)
check("two taps in a row fire twice", mm.pending_actions, ["menu-apps", "menu-apps"])

# A release whose press we never saw -- the pad re-binding mid-hold does this
# (the ENODEV path re-enters pick_device) -- is not a tap the user made.
mm = fresh()
check("a STEAM release with no press emits nothing",
      mm.translate(e.EV_KEY, e.BTN_MODE, 0, 0.0), [])
check("and is not treated as a tap", mm.pending_actions, [])

mm = fresh()
mm.translate(e.EV_KEY, e.BTN_MODE, 1, 0.0)
check("the pad's own autorepeat on STEAM emits nothing",
      mm.translate(e.EV_KEY, e.BTN_MODE, 2, 0.1), [])
mm.translate(e.EV_KEY, e.BTN_MODE, 0, 0.2)
check("and does not count as a chord partner", mm.pending_actions, ["menu-apps"])

# ✅ QAM was MEASURED on hardware 2026-08-11: BTN_BASE (294), on the "Steam Deck"
# node with lizard_mode=N, bracketed between two BTN_SOUTH delimiter presses so
# the attribution is evidence rather than inference (docs/PROGRESS.md §7).
#
# The INERT path below is still exercised deliberately. It is reachable code --
# a port to other hardware, or a future button whose code is unmeasured, lands
# straight back in it -- and it is the branch that keeps a dead button from
# being a silent mystery. Deleting its coverage because this one button is now
# known would throw away the guard, not the obsolete part.

check("QAM_BUTTON ships as the MEASURED code, not a guess and not unset",
      m.QAM_BUTTON, e.BTN_BASE)
check("and BTN_BASE is 294, so a rename upstream cannot silently move it",
      m.QAM_BUTTON, 294)

_saved_qam = m.QAM_BUTTON
m.QAM_BUTTON = None
mm = fresh()
check("with QAM_BUTTON unset, an unbound button queues nothing",
      (mm.translate(e.EV_KEY, e.BTN_TRIGGER_HAPPY1, 1, 0.0), mm.pending_actions),
      ([], []))
m.QAM_BUTTON = _saved_qam

# The stand-in code is deliberately NOT the real one: it proves the binding
# follows the constant rather than a 294 baked into translate().
m.QAM_BUTTON = e.BTN_TRIGGER_HAPPY1
mm = fresh()
check("with a code set, QAM queues the ROOT menu on the press",
      (mm.translate(e.EV_KEY, m.QAM_BUTTON, 1, 0.0), mm.pending_actions),
      ([], ["menu-root"]))
check("and the release does not queue it a second time",
      (mm.translate(e.EV_KEY, m.QAM_BUTTON, 0, 0.1), mm.pending_actions),
      ([], ["menu-root"]))
m.QAM_BUTTON = _saved_qam
check("QAM_BUTTON is restored to the measured code for the rest of the suite",
      m.QAM_BUTTON, e.BTN_BASE)

# And the real code, end to end -- the stand-in above cannot catch a 294 that
# collides with something else this mapper already binds.
mm = fresh()
check("the REAL QAM code (294) queues the root menu and nothing else",
      (mm.translate(e.EV_KEY, 294, 1, 0.0), mm.pending_actions),
      ([], ["menu-root"]))


# --- the spawn: loud, non-blocking, never fatal ------------------------------
#
# The mapper spawns and forgets, exactly as it does for squeekboard's busctl
# call. Two properties matter more than the argv: it must never WAIT (with
# lizard_mode=N this process is the only input path, so a blocked loop is a
# handheld with no pointer and no keys), and a missing `omarchy-menu` must cost
# that one button loudly rather than killing the process.


class FakeProc:
    """A spawned process that records whether anyone waited on it.

    `exits_after` is how many poll() calls it survives: 0 means "already gone",
    None means "still running forever", which is the default because most cases
    here care about the spawn, not the reap.
    """

    def __init__(self, exits_after=None):
        self.waited = False
        self.polls = 0
        self.exits_after = exits_after

    def wait(self, timeout=None):
        self.waited = True
        return 0

    def poll(self):
        self.polls += 1
        if self.exits_after is None:
            return None
        return 0 if self.polls > self.exits_after else None


class FakeSubprocess:
    """Stands in for the `subprocess` module inside the mapper. Nothing in this
    suite may start a real process: CI has no Omarchy, no compositor, no DBus."""

    DEVNULL = _subprocess.DEVNULL

    def __init__(self, error=None):
        self.calls = []
        self.procs = []
        self.error = error

    def Popen(self, argv, **kwargs):
        self.calls.append((list(argv), kwargs))
        if self.error is not None:
            raise self.error
        proc = FakeProc()
        self.procs.append(proc)
        return proc


def with_fake_subprocess(fn, error=None):
    """Run fn() with the mapper's `subprocess` stubbed out.

    Returns (result, fake, stderr). The stub is restored in a finally: a leaked
    one would silently disarm every later spawn assertion.
    """
    fake = FakeSubprocess(error)
    real = m.subprocess
    m.subprocess = fake
    captured = io.StringIO()
    try:
        with contextlib.redirect_stderr(captured):
            result = fn()
    finally:
        m.subprocess = real
    return result, fake, captured.getvalue()


_result, _fake, _err = with_fake_subprocess(lambda: m.run_menu_action("menu-apps"))
check("running the apps menu spawns exactly upstream's argv",
      [argv for argv, _kw in _fake.calls], [["omarchy-menu", "toggle", "apps"]])
check("and reports that it started", _result, True)
check("nothing waits on it -- a slow menu must never freeze the input loop",
      [p.waited for p in _fake.procs], [False])
check("its output is discarded rather than mixed into our journal",
      (_fake.calls[0][1].get("stdout"), _fake.calls[0][1].get("stderr")),
      (_subprocess.DEVNULL, _subprocess.DEVNULL))
check("and it is an argv, never a shell string -- nothing here goes through sh",
      _fake.calls[0][1].get("shell"), None)
check("a successful spawn says nothing on stderr", _err, "")

_result, _fake, _err = with_fake_subprocess(lambda: m.run_menu_action("menu-root"))
check("the root menu spawns the bare `toggle`",
      [argv for argv, _kw in _fake.calls], [["omarchy-menu", "toggle"]])

# A missing binary is the likeliest failure of all -- the installer has no
# `omarchy-menu`, and neither does a Deck mid-install.
_result, _fake, _err = with_fake_subprocess(
    lambda: m.run_menu_action("menu-apps"),
    error=FileNotFoundError(2, "No such file or directory", "omarchy-menu"))
check("a missing omarchy-menu does not raise", _result, False)
check("it is LOUD about it", "could not run" in _err, True)
check("and names the command it tried", "omarchy-menu toggle apps" in _err, True)
check("and says the rest of the mapper is unaffected",
      "the rest of the mapper is unaffected" in _err, True)
mm = fresh()
check("and the mapper still translates afterwards",
      mm.translate(e.EV_KEY, e.BTN_SOUTH, 1, 0.0), [(e.KEY_ENTER, 1)])

_result, _fake, _err = with_fake_subprocess(lambda: m.run_menu_action("menu-nope"))
check("an unknown menu action spawns nothing", _fake.calls, [])
check("and is reported rather than ignored",
      ("unknown menu action" in _err, _result), (True, False))

_result, _fake, _err = with_fake_subprocess(
    lambda: m.run_menu_action("menu-apps", dry_run=True))
check("--dry-run reports the menu instead of spawning it",
      (_fake.calls, "omarchy-menu toggle apps" in _err, _result), ([], True, True))

# End to end, the way main() drives it: translate queues a NAME, the dispatcher
# resolves it to an argv. This is the pair that catches a button wired to the
# wrong menu -- either half alone still passes if they are swapped.
mm = fresh()
mm.translate(e.EV_KEY, e.BTN_MODE, 1, 0.0)
mm.translate(e.EV_KEY, e.BTN_MODE, 0, 0.1)
_result, _fake, _err = with_fake_subprocess(
    lambda: [m.run_menu_action(a) for a in mm.pending_actions])
check("a STEAM tap runs the APPS menu end to end",
      [argv for argv, _kw in _fake.calls], [["omarchy-menu", "toggle", "apps"]])

m.QAM_BUTTON = e.BTN_TRIGGER_HAPPY1
mm = fresh()
mm.translate(e.EV_KEY, m.QAM_BUTTON, 1, 0.0)
m.QAM_BUTTON = _saved_qam
_result, _fake, _err = with_fake_subprocess(
    lambda: [m.run_menu_action(a) for a in mm.pending_actions])
check("a QAM press runs the ROOT menu end to end",
      [argv for argv, _kw in _fake.calls], [["omarchy-menu", "toggle"]])


# --- what startup says, so a dead button is never a mystery ------------------
#
# ⚠️ Both buttons exist only with lizard_mode=N (§5.9, §5.21), and QAM's binding
# is inert until its code is measured. Three different causes, one symptom --
# "I pressed it and nothing happened" -- so the journal has to name which is in
# force. An inert binding that says nothing is exactly the silent failure
# CLAUDE.md forbids.

_report_n = "\n".join(m.menu_binding_report("N"))
check("startup names the apps-menu command",
      "omarchy-menu toggle apps" in _report_n, True)
check("startup says STEAM+X still works, so nobody thinks the tap replaced it",
      "STEAM+X" in _report_n, True)
check("startup names the MEASURED QAM button rather than calling it inert",
      ("BTN_BASE" in _report_n, "INERT" in _report_n), (True, False))

# The inert announcement is still the guard against a silent dead button, so it
# keeps its coverage -- forced, since the shipped constant is no longer None.
m.QAM_BUTTON = None
_report_inert = "\n".join(m.menu_binding_report("N"))
m.QAM_BUTTON = _saved_qam
check("with no code set, startup ANNOUNCES the inert binding rather than omitting it",
      "INERT" in _report_inert, True)
check("and names the constant to fill in", "QAM_BUTTON" in _report_inert, True)
check("with lizard_mode=N it says the presses reach us",
      "reach this process" in _report_n, True)
check("every line is prefixed, so it is greppable in a journal",
      all(line.startswith("deck-input-mapper: ") for line in m.menu_binding_report("N")),
      True)

_report_y = "\n".join(m.menu_binding_report("Y"))
check("with lizard mode ON it says the presses never arrive",
      "SWALLOWS" in _report_y, True)
check("and gives the knob that fixes it", m.LIZARD_MODE_PATH in _report_y, True)
check("and warns it does not survive a reboot",
      "does not survive a reboot" in _report_y, True)
check("an unreadable knob is reported, never assumed to be fine",
      "could not read" in "\n".join(m.menu_binding_report(None)), True)

m.QAM_BUTTON = e.BTN_TRIGGER_HAPPY1
_report_set = "\n".join(m.menu_binding_report("N"))
m.QAM_BUTTON = _saved_qam
check("once a code is measured the report names the button instead of INERT",
      ("BTN_TRIGGER_HAPPY1" in _report_set, "INERT" in _report_set), (True, False))
check("QAM_BUTTON is still the measured code after the report checks",
      m.QAM_BUTTON, e.BTN_BASE)

check("an unreadable lizard_mode knob reads as None rather than raising",
      m.read_lizard_mode("/nonexistent/hid_steam/lizard_mode"), None)
with tempfile.NamedTemporaryFile("w", suffix=".lizard_mode") as _fh:
    _fh.write("N\n")
    _fh.flush()
    # The trailing newline matters: menu_binding_report compares against "N".
    check("a readable knob is reported with its whitespace stripped",
          m.read_lizard_mode(_fh.name), "N")

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

# --- OSK routing: what changes when the keyboard is up (T8 step 4) -----------
#
# ⚠️ `osk_active` is set ONLY by the tty backend. With squeekboard the pads must
# keep driving the system pointer, because squeekboard is a surface being
# pointed AT rather than something this process draws. Everything below asserts
# the gate as much as the routing: the default path must be untouched.

osk_mod = m.osk_layout
MINV, MAXV = osk_mod.PAD_RANGE


def osk_mapper():
    mm = fresh()
    mm.osk = osk_mod.OnScreenKeyboard()
    mm.cursors = osk_mod.Cursors()
    mm.osk_active = True
    return mm


mm = osk_mapper()
check("with the OSK up, a pad axis emits no keystroke",
      mm.translate(e.EV_ABS, e.ABS_HAT1X, MAXV, 0.0), [])
check("but it did move that cursor", mm.cursors.position("right")[0], 1.0)
check("and left the other cursor alone", mm.cursors.position("left"), (0.5, 0.5))

# Each trigger presses the key under its OWN cursor -- the whole point of two.
mm = osk_mapper()
mm.translate(e.EV_ABS, e.ABS_HAT0X, MINV, 0.0)   # left cursor -> top-left "1"
mm.translate(e.EV_ABS, e.ABS_HAT0Y, MAXV, 0.0)
mm.translate(e.EV_ABS, e.ABS_HAT1X, MAXV, 0.0)   # right cursor -> top-right "0"
mm.translate(e.EV_ABS, e.ABS_HAT1Y, MAXV, 0.0)
check("the LEFT trigger types the key under the LEFT cursor",
      mm.translate(e.EV_KEY, e.BTN_TL2, 1, 0.1), [(e.KEY_1, 1), (e.KEY_1, 0)])
check("the RIGHT trigger types the key under the RIGHT cursor",
      mm.translate(e.EV_KEY, e.BTN_TR2, 1, 0.2), [(e.KEY_0, 1), (e.KEY_0, 0)])
check("a trigger RELEASE types nothing (or every key would double)",
      mm.translate(e.EV_KEY, e.BTN_TR2, 0, 0.3), [])

# With the keyboard up, the navigation profile underneath must be silent, or
# every press does two things at once.
mm = osk_mapper()
check("A no longer sends Enter while the keyboard is up",
      mm.translate(e.EV_KEY, e.BTN_SOUTH, 1, 0.0), [])
check("Y no longer sends Space", mm.translate(e.EV_KEY, e.BTN_WEST, 1, 0.0), [])
check("the d-pad no longer sends arrows",
      mm.translate(e.EV_KEY, e.BTN_DPAD_UP, 1, 0.0), [])
check("the stick no longer sends arrows",
      mm.translate(e.EV_ABS, e.ABS_Y, -32768, 0.0), [])

# The chord must survive: it is how a user dismisses a keyboard opened by
# accident, and it is checked BEFORE the OSK branch for exactly that reason.
mm = osk_mapper()
mm.translate(e.EV_KEY, e.BTN_MODE, 1, 0.0)
check("STEAM+X still queues a toggle while the keyboard is up",
      (mm.translate(e.EV_KEY, e.BTN_NORTH, 1, 0.1), mm.pending_actions),
      ([], ["toggle-osk"]))
check("and releasing STEAM after that chord opens no menu",
      (mm.translate(e.EV_KEY, e.BTN_MODE, 0, 0.2), mm.pending_actions),
      ([], ["toggle-osk"]))

# A STEAM tap does the SAME thing with the keyboard up as with it down --
# deliberately, and for the same reason the chord is checked before the OSK
# branch: a button whose meaning depends on invisible state is worse than one
# that opens a menu over a keyboard the user can dismiss.
mm = osk_mapper()
mm.translate(e.EV_KEY, e.BTN_MODE, 1, 0.0)
check("a STEAM tap still opens the apps menu with the keyboard up",
      (mm.translate(e.EV_KEY, e.BTN_MODE, 0, 0.1), mm.pending_actions),
      ([], ["menu-apps"]))

# --- and none of that may happen with the OSK DOWN ---------------------------

mm = fresh()
check("with the OSK down, the triggers are mouse buttons again",
      mm.translate(e.EV_KEY, e.BTN_TR2, 1, 0.0), [(e.BTN_LEFT, 1)])
check("A sends Enter again", mm.translate(e.EV_KEY, e.BTN_SOUTH, 1, 0.0), [(e.KEY_ENTER, 1)])
check("the d-pad sends arrows again",
      mm.translate(e.EV_KEY, e.BTN_DPAD_UP, 1, 0.0), [(e.KEY_UP, 1)])
check("a pad axis is not a keystroke either way",
      mm.translate(e.EV_ABS, e.ABS_HAT1X, MAXV, 0.0), [])
check("osk_active defaults to off", fresh().osk_active, False)
check("and a mapper with no OSK attached routes nothing even if flagged",
      m.Mapper(osk_active=True).translate(e.EV_KEY, e.BTN_TR2, 1, 0.0), [])

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

# --- auto-show: this end of the focus watcher's pipe (T8 step 8) -------------
#
# The watcher itself is a separate program with its own suite, driven against a
# fake compositor. THIS is the half that lives in the only input path on the
# device, so everything below is about what happens when the far side
# misbehaves: partial lines, several changes in one read, junk, and death.

import os          # noqa: E402
import select      # noqa: E402
import subprocess  # noqa: E402

# Loaded the way the mapper loads it, which also pins that it is findable where
# the mapper looks -- a module the mapper cannot find is auto-show that never
# starts.
focus_mod = m._load_module("deck_osk_focus")
check("the mapper can find the focus watcher module", focus_mod is not None, True)


class FakeStdout:
    """A pipe's read end, shaped like Popen.stdout."""

    def __init__(self, fd):
        self._fd = fd
        self.closed = False

    def fileno(self):
        return self._fd

    def close(self):
        self.closed = True


class PipeProc:
    """A process-shaped object whose stdout is a real pipe the test writes into.

    Real fds and real os.read -- only the far end is under the test's control,
    which is what makes partial reads and batching assertable at all.
    """

    def __init__(self, status=None):
        self.read_fd, self.write_fd = os.pipe()
        self.stdout = FakeStdout(self.read_fd)
        self.status = status
        self.waits = 0

    def wait(self, timeout=None):
        self.waits += 1
        if self.status is None:
            raise subprocess.TimeoutExpired("watcher", timeout)
        return self.status

    def write(self, data):
        os.write(self.write_fd, data)

    def eof(self):
        os.close(self.write_fd)


def attach(status=None):
    """An AutoShow already 'started', wired to a pipe. Returns (auto, proc, log)."""
    log = []
    auto = m.AutoShow(focus_mod, ["/nonexistent"], log=log.append)
    proc = PipeProc(status)
    auto.proc = proc
    auto.enabled = True
    return auto, proc, log


def readable(fd, timeout=5.0):
    return bool(select.select([fd], [], [], timeout)[0])


auto, proc, log = attach()
proc.write(b"focus 1\n")
check("`focus 1` asks for the keyboard", auto.pump(False), True)
proc.write(b"focus 0\n")
check("`focus 0` asks for it to go away", auto.pump(True), False)

# ⚠️ Idempotence, and it is not cosmetic. For the layer backend a redundant
# "show" re-enters osk_layer_start, and a redundant "hide" would kill and
# re-spawn a GTK process for a state it is already in.
proc.write(b"focus 1\n")
check("a change to the state we are already in asks for nothing",
      auto.pump(True), None)
proc.write(b"focus 0\n")
check("and neither does the other one", auto.pump(False), None)

# ⚠️ A PIPE READ IS NOT A LINE BOUNDARY.
auto, proc, log = attach()
proc.write(b"focus ")
check("half a line asks for nothing yet", auto.pump(False), None)
proc.write(b"1\n")
check("and the rest of it completes the change", auto.pump(False), True)

# ⚠️ LAST ONE WINS. Focus leaving one field and entering another arrives as two
# changes in one read; obeying each in turn hides and re-shows the keyboard.
auto, proc, log = attach()
proc.write(b"focus 1\nfocus 0\n")
check("two changes that cancel out ask for nothing", auto.pump(False), None)
auto, proc, log = attach()
proc.write(b"focus 0\nfocus 1\n")
check("two changes that land somewhere new ask for the LAST one",
      auto.pump(False), True)
auto, proc, log = attach()
proc.write(b"focus 1\nfocus 0\nfocus 1\n")
check("three of them too", auto.pump(False), True)

# Junk crosses a process boundary; it must be ignored, counted, and mentioned
# once -- never fatal, and never silent either.
auto, proc, log = attach()
proc.write(b"deck-osk-focus: something went wrong\n")
check("a line that is not a focus line asks for nothing", auto.pump(False), None)
check("it is counted", auto.ignored, 1)
check("and reported once", len(log), 1)
check("quoting what it actually said",
      "something went wrong" in log[0], True)
proc.write(b"more junk\n")
check("a second one is counted", (auto.pump(False), auto.ignored), (None, 2))
check("but not reported again", len(log), 1)
proc.write(b"junk\nfocus 1\n")
check("junk in the same read does not swallow a real change",
      auto.pump(False), True)

# --- the watcher dying: loud, named, and never fatal -------------------------

auto, proc, log = attach(status=focus_mod.EXIT_SEAT_TAKEN)
proc.eof()
check("EOF asks for no change", auto.pump(False), None)
check("auto-show turns itself off", auto.enabled, False)
check("the watcher's own exit code becomes a sentence",
      "waylandim" in log[-1], True)
check("and the chord is named as still working", "STEAM+X" in log[-1], True)
check("the pipe is closed rather than left readable forever",
      proc.stdout.closed, True)
check("pumping a dead watcher is a no-op, not a crash", auto.pump(False), None)

auto, proc, log = attach(status=focus_mod.EXIT_NO_CONNECTION)
proc.eof()
auto.pump(False)
check("a different exit gets a different sentence",
      "no Wayland connection" in log[-1], True)

# An exit code nobody has a sentence for must still be reported.
auto, proc, log = attach(status=99)
proc.eof()
auto.pump(False)
check("an unrecognised exit is still reported", len(log), 1)
check("without inventing a reason for it", "waylandim" in log[-1], False)

# A watcher that has hit EOF but not yet exited: the wait times out, and that
# must not become an exception in the input loop.
auto, proc, log = attach(status=None)
proc.eof()
check("a watcher that has not exited yet is still handled", auto.pump(False), None)
check("it was waited for exactly once", proc.waits, 1)
check("and auto-show is off either way", auto.enabled, False)

# A broken fd is the same story from the other direction.
auto, proc, log = attach(status=None)
proc.stdout = FakeStdout(-1)
check("a read that fails asks for no change", auto.pump(False), None)
check("and turns auto-show off", auto.enabled, False)
check("naming the pipe", "pipe" in log[-1], True)

# --- a REAL subprocess: start, fileno, a real exit status, stop ---------------

STUB = ("import sys, time\n"
        "sys.stdout.write('focus 1\\n')\n"
        "sys.stdout.flush()\n"
        "time.sleep(0.2)\n"
        "sys.exit(5)\n")
log = []
auto = m.AutoShow(focus_mod, [sys.executable, "-c", STUB], log=log.append)
check("a real watcher starts", auto.start(), True)
# The main loop stops selecting on the pipe the moment this goes false, so a
# watcher that started without it is a watcher nobody ever reads.
check("and says it is enabled", auto.enabled, True)
check("and offers an fd to select on", isinstance(auto.fileno(), int), True)
check("its output is readable without waiting for it to exit",
      readable(auto.fileno()), True)
check("a real `focus 1` over a real pipe asks for the keyboard",
      auto.pump(False), True)
check("its exit closes the pipe", readable(auto.fileno(), 5.0), True)
check("which is read as EOF", auto.pump(True), None)
check("the REAL exit status is turned into the REAL reason",
      "waylandim" in log[-1], True)

log = []
auto = m.AutoShow(focus_mod, ["/nonexistent/deck_osk_focus"], log=log.append)
check("a watcher that cannot start says so", auto.start(), False)
check("and stays off", auto.enabled, False)
check("naming what failed", "could not start" in log[0], True)
check("a watcher that never started has no fd", auto.fileno(), None)
check("stopping one that never started is a no-op", auto.stop(), None)

log = []
auto = m.AutoShow(focus_mod,
                  [sys.executable, "-c", "import time; time.sleep(30)"],
                  log=log.append)
auto.start()
live = auto.proc
auto.stop()
check("stop() ends a live watcher", live.poll() is not None, True)
check("and forgets it", auto.fileno(), None)
check("stop() twice is still a no-op", auto.stop(), None)

# --- lock_state_from_monitors: reading Hyprland's own ground truth -----------
#
# `docs/findings/T9-lock-service-mitigation.md` §1.3 traced this straight into
# Hyprland's source: `solitaryBlockedBy` is `null` with no blockers at all,
# else a JSON array of names, and "LOCK" appears in it iff
# `g_pSessionLockManager->isSessionLocked()`. Every shape below is one this
# module has to tell apart correctly, or the unlock signal is either missed
# (stuck up) or invented (hidden while still locked -- the one direction
# CLAUDE.md's request forbids).

LOCKED_ONE_MONITOR = '[{"name": "eDP-1", "solitaryBlockedBy": ["LOCK"]}]'
UNLOCKED_NULL = '[{"name": "eDP-1", "solitaryBlockedBy": null}]'
UNLOCKED_OTHER_REASON = '[{"name": "eDP-1", "solitaryBlockedBy": ["WORKSPACE"]}]'
TWO_MONITORS_ONE_LOCKED = ('[{"name": "eDP-1", "solitaryBlockedBy": null}, '
                           '{"name": "DP-1", "solitaryBlockedBy": ["LOCK"]}]')

check("a monitor whose solitaryBlockedBy names LOCK reads as locked",
      m.lock_state_from_monitors(LOCKED_ONE_MONITOR), True)
check("solitaryBlockedBy: null reads as unlocked, not unknown",
      m.lock_state_from_monitors(UNLOCKED_NULL), False)
check("a different blocker (not LOCK) still reads as unlocked",
      m.lock_state_from_monitors(UNLOCKED_OTHER_REASON), False)
check("ANY monitor holding the lock is enough on a multi-monitor read",
      m.lock_state_from_monitors(TWO_MONITORS_ONE_LOCKED), True)
check("an empty monitor list reads as unlocked", m.lock_state_from_monitors("[]"), False)
check("malformed JSON is UNKNOWN, not unlocked", m.lock_state_from_monitors("{not json"), None)
check("a JSON object instead of a list is unknown -- the shape changed",
      m.lock_state_from_monitors('{"solitaryBlockedBy": ["LOCK"]}'), None)
check("a non-dict monitor entry is skipped, not fatal",
      m.lock_state_from_monitors('["not a monitor object"]'), False)
check("empty input is unknown", m.lock_state_from_monitors(""), None)

# --- read_lock_state: the one bounded, blocking subprocess call --------------

check("a real hyprctl-shaped process's stdout is parsed",
      m.read_lock_state(argv=(sys.executable, "-c",
                              f"print({LOCKED_ONE_MONITOR!r})")), True)
check("a nonzero exit is treated as unknown, not unlocked",
      m.read_lock_state(argv=(sys.executable, "-c",
                              f"import sys; print({UNLOCKED_NULL!r}); sys.exit(1)")),
      None)
check("a binary that does not exist is unknown, never raises",
      m.read_lock_state(argv=("/nonexistent/hyprctl", "-j", "monitors")), None)
check("a process that outlasts the timeout is unknown, never blocks forever",
      m.read_lock_state(argv=(sys.executable, "-c", "import time; time.sleep(5)"),
                        timeout=0.2),
      None)

# --- LockWatcher: the edge-trigger, throttled and self-correcting -----------


def queue_reader(*results):
    """A fake `reader` -- each call to tick() that actually polls consumes
    one queued result, in order. Running out raises, so a test that expected
    fewer polls than it got fails loudly instead of returning a stale value."""
    values = list(results)

    def reader():
        return values.pop(0)
    return reader


lw = m.LockWatcher(interval=10.0)
check("a fresh watcher is not armed", lw.armed, False)
check("an unarmed watcher never polls or fires, however long is passed",
      lw.tick(1_000_000.0, reader=queue_reader()), False)
check("...and its deadline is None -- nothing to wait for", lw.next_deadline(), None)

lw.start(now=0.0)
check("start() arms it", lw.armed, True)
check("start() checks right away -- summoned-while-locked is the common case",
      lw.next_deadline(), 0.0)
check("start() clears any earlier saw_lock", lw.saw_lock, False)

# The FIRST poll observes LOCKED: no edge yet, but the state latches.
check("a LOCKED reading reports no edge -- it must not hide the keyboard",
      lw.tick(0.0, reader=queue_reader(True)), False)
check("...and is remembered", lw.saw_lock, True)
check("the next check is scheduled one interval out", lw.next_deadline(), 10.0)

# Asking again before the interval elapses must NOT poll -- queue_reader()
# with no values raises if it is called, so this also proves the throttle.
check("polling again before the interval is due does nothing, and does not "
      "even call the reader", lw.tick(5.0, reader=queue_reader()), False)
check("saw_lock is unaffected by a tick that did not poll", lw.saw_lock, True)

# Still locked on the next legitimate poll: still no edge.
check("a SECOND locked reading still reports no edge",
      lw.tick(10.0, reader=queue_reader(True)), False)
check("saw_lock stays latched", lw.saw_lock, True)

# NOW it unlocks. This is the one and only case that must report True.
check("LOCKED -> UNLOCKED is exactly the edge that fires",
      lw.tick(20.0, reader=queue_reader(False)), True)
check("the edge consumes saw_lock -- it will not fire twice for one unlock",
      lw.saw_lock, False)
check("a further UNLOCKED reading reports no edge -- there was nothing to "
      "transition FROM", lw.tick(30.0, reader=queue_reader(False)), False)

# ⚠️ THE PROPERTY THE WHOLE DESIGN EXISTS FOR: a keyboard shown in an ALREADY
# unlocked desktop, that never observes a LOCK, must NEVER report an edge --
# there is nothing to have unlocked from. Getting this backwards would hide
# the keyboard on some other read entirely, which is the failure this
# mechanism must not have.
lw2 = m.LockWatcher(interval=10.0)
lw2.start(now=0.0)
never_locked = queue_reader(False, False, False, False)
saw_edge = False
t = 0.0
for _ in range(4):
    if lw2.tick(t, reader=never_locked):
        saw_edge = True
    t += 10.0
check("a keyboard that never observed LOCK never reports an unlock edge",
      saw_edge, False)

# A reading of None (hyprctl missing, wrong compositor, timed out) must leave
# saw_lock exactly where it was -- CLAUDE.md's "cannot leave the keyboard
# stuck" requirement, applied to the state machine directly: the safe
# failure is "does not auto-hide", never a spurious hide while still locked.
lw3 = m.LockWatcher(interval=10.0)
lw3.start(now=0.0)
lw3.tick(0.0, reader=queue_reader(True))
check("still locked before the unknown reading", lw3.saw_lock, True)
check("an unknown reading (None) reports no edge",
      lw3.tick(10.0, reader=queue_reader(None)), False)
check("...and does not clear saw_lock -- a later real reading can still fire",
      lw3.saw_lock, True)
check("the very next legitimate poll can still detect the real unlock",
      lw3.tick(20.0, reader=queue_reader(False)), True)

# stop() disarms unconditionally, from any state.
lw4 = m.LockWatcher(interval=10.0)
lw4.start(now=0.0)
lw4.tick(0.0, reader=queue_reader(True))
lw4.stop()
check("stop() disarms", lw4.armed, False)
check("stop() clears saw_lock too -- a re-show must start from scratch",
      lw4.saw_lock, False)
check("a stopped watcher's deadline is None", lw4.next_deadline(), None)
check("ticking a stopped watcher never polls or fires",
      lw4.tick(999.0, reader=queue_reader()), False)

# start() while already armed re-arms cleanly -- the shape a real re-show
# takes (hide, then show again) rather than a fresh object every time.
lw5 = m.LockWatcher(interval=10.0)
lw5.start(now=0.0)
lw5.tick(0.0, reader=queue_reader(True))
check("mid-sequence: locked once", lw5.saw_lock, True)
lw5.start(now=100.0)   # hidden and re-shown
check("re-starting clears the earlier LOCK -- it belongs to the last showing",
      lw5.saw_lock, False)
check("re-starting resets the poll clock too", lw5.next_deadline(), 100.0)

# --- §5.28: the session environment, resolved at run time --------------------
#
# 🔴 THE BUG THIS SECTION EXISTS FOR shipped on hardware: a cold-booted mapper
# inherits ONE variable (XDG_RUNTIME_DIR), wins the race against uwsm's
# import-environment, and every child it starts is born blind -- no menus, no
# launcher, no keyboard, on a device with no physical keyboard. A mapper
# RESTARTED BY HAND has all 33 variables and passes every check, which is
# exactly why nothing caught it.
#
# ⚠️ NOTHING BELOW CAN PROVE THE FIX ON THE DECK. These assertions pin the
# mechanism -- children are started with the RESOLVED environment, and the
# resolution keeps being attempted until it succeeds -- but the only evidence
# that matters comes from booting the machine and pressing STEAM before
# touching anything else. Do not read a green run here as §5.28 closed.

import ast  # noqa: E402 -- local to this block, like the imports above

# --- parse_show_environment: systemd's own output format ---------------------

env_text = "\n".join([
    "WAYLAND_DISPLAY=wayland-1",
    "HYPRLAND_INSTANCE_SIGNATURE=abc123_17",
    "OMARCHY_PATH=/home/deck/.local/share/omarchy",
    "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus",
    "QUOTED='a value with spaces'",
    "EMPTY=",
])
# 🔴 THE FORM THAT ACTUALLY OCCURS, and the one this suite originally missed.
# These six lines are VERBATIM from the test Deck's own `systemctl --user
# show-environment` on a real session (captured 2026-08-11). On that machine
# SIX values are ANSI-C quoted and ZERO are plain-quoted -- so the `'...'`
# fixtures below test a form systemd never emitted here, while the form it
# always emits went unhandled.
#
# The cost was not theoretical: `$'wayland,x11,*'` reached GTK verbatim, GTK
# reported `No such backend: $'wayland`, and the layer-shell keyboard fell
# back to an ordinary window. It still appeared -- full-screen instead of
# anchored -- and would NOT have rendered above `ext-session-lock`, silently
# undoing the §5.24 lock fix that had been verified in pixels. **The keyboard
# worked, and was wrong.** Caught only because a human looked at the panel
# and said the keyboard was the size of the screen.
DECK_REAL_ENV = "\n".join([
    "DEBUGINFOD_URLS=$'https://debuginfod.archlinux.org '",
    "EDITOR=$'omarchy-launch-editor --inline'",
    "GDK_BACKEND=$'wayland,x11,*'",
    "HYPRLAND_CMD=$'Hyprland --watchdog-fd 4'",
    "QT_QPA_PLATFORM=$'wayland;xcb'",
    "UWSM_FINALIZE_VARNAMES=$'HYPRLAND_INSTANCE_SIGNATURE HYPRLAND_CMD HYPRCURSOR_THEME'",
    "WAYLAND_DISPLAY=wayland-1",
])
real = m.parse_show_environment(DECK_REAL_ENV)
check("the ANSI-C form GTK choked on parses to a usable backend list",
      real.get("GDK_BACKEND"), "wayland,x11,*")
check("...and Qt's, which would have broken every Qt child the same way",
      real.get("QT_QPA_PLATFORM"), "wayland;xcb")
check("an ANSI-C value containing spaces survives whole",
      real.get("HYPRLAND_CMD"), "Hyprland --watchdog-fd 4")
check("a trailing space inside the quotes is not trimmed away",
      real.get("DEBUGINFOD_URLS"), "https://debuginfod.archlinux.org ")
check("bare values still parse alongside them",
      real.get("WAYLAND_DISPLAY"), "wayland-1")
check("all seven real lines parsed", len(real), 7)

# The escapes systemd's own cescape_char can emit.
check("\\n decodes", m.unescape_ansi_c(r"a\nb"), "a\nb")
check("\\t decodes", m.unescape_ansi_c(r"a\tb"), "a\tb")
check("an escaped quote decodes -- the reason the form exists at all",
      m.unescape_ansi_c(r"it\'s"), "it's")
check("a literal backslash decodes to one backslash",
      m.unescape_ansi_c(r"a\\b"), "a\\b")
check("\\xNN decodes", m.unescape_ansi_c(r"a\x41b"), "aAb")
check("octal decodes", m.unescape_ansi_c(r"a\101b"), "aAb")
# Bytes, not characters: a multi-byte UTF-8 character arrives as several \xNN
# pairs and must reassemble, not become two replacement characters.
check("two \\xNN halves of one UTF-8 character reassemble",
      m.unescape_ansi_c(r"\xc3\xa9"), "é")
# ⚠️ Unknown escapes are kept LITERALLY. Guessing corrupts a value silently;
# leaving it visible does not.
check("an unrecognised escape is kept whole, backslash included",
      m.unescape_ansi_c(r"a\qb"), "a\\qb")
check("a trailing backslash never raises", m.unescape_ansi_c("a\\"), "a\\")
check("a truncated hex escape is kept literal, not half-decoded",
      m.unescape_ansi_c(r"a\x4"), "a\\x4")
check("an out-of-range octal escape stays literal rather than wrapping",
      m.unescape_ansi_c(r"a\777b"), "a\\777b")
check("an empty ANSI-C value is empty, not dropped",
      m.parse_show_environment("FOO=$''").get("FOO"), "")
# ⚠️ THROUGH THE PARSER, not the decoder directly. Every escape assertion
# above calls unescape_ansi_c() itself, so all of them still pass if the
# parser merely strips the `$'` and `'` and never decodes anything -- which
# is a real mutation this suite let through until this line existed. The
# whole point of the branch is that it DECODES, so that is what gets checked.
check("the parser actually decodes, it does not just strip the wrapper",
      m.parse_show_environment(r"FOO=$'a\tb\nc'").get("FOO"), "a\tb\nc")

parsed = m.parse_show_environment(env_text)
check("a plain assignment parses", parsed.get("WAYLAND_DISPLAY"), "wayland-1")
# The DBus address contains '=' in its VALUE. Splitting on every '=' rather
# than the first truncates it, and a truncated bus address is a child that
# cannot reach the session bus -- a subtler version of the bug being fixed.
check("a value containing '=' survives",
      parsed.get("DBUS_SESSION_BUS_ADDRESS"), "unix:path=/run/user/1000/bus")
check("a shell-quoted value is unquoted, spaces intact",
      parsed.get("QUOTED"), "a value with spaces")
check("an empty value is kept as empty, not dropped", parsed.get("EMPTY"), "")
check("all six lines parsed", len(parsed), 6)

# A malformed line must cost that line and nothing else: this parses another
# program's output on a device whose only input path is this process.
messy = m.parse_show_environment("\n".join([
    "GOOD=1", "", "no-equals-here", "# a comment", "BAD='unbalanced",
    "1INVALID=x", "ALSO_GOOD=2",
]))
check("garbage lines are skipped, the good ones survive",
      sorted(messy), ["ALSO_GOOD", "GOOD"])
check("an unbalanced quote does not raise or poison the rest",
      messy.get("ALSO_GOOD"), "2")
check("empty input parses to nothing", m.parse_show_environment(""), {})

# --- SessionEnv: ask until it answers, then stop -----------------------------

READY = ("WAYLAND_DISPLAY=wayland-1\n"
         "HYPRLAND_INSTANCE_SIGNATURE=abc123_17\n"
         "OMARCHY_PATH=/home/deck/.local/share/omarchy\n")
COLD = ""            # what a cold boot's user manager actually holds: nothing useful


def reader_returning(*answers):
    """A reader that hands back each answer in turn, then repeats the last.
    Counts its calls on `.calls` -- the throttle assertions need that."""
    queue = list(answers)

    def read():
        read.calls += 1
        return queue.pop(0) if len(queue) > 1 else queue[0]

    read.calls = 0
    return read


log = []
se = m.SessionEnv(interval=1.0, window=60.0, log=log.append)
check("a fresh resolver has nothing", se.resolved, False)
check("and names everything it is missing", se.missing(), list(m.SESSION_ENV_REQUIRED))
check("its deadline is due immediately -- the first refresh always asks",
      se.next_deadline(), 0.0)

cold = reader_returning(COLD)
check("a cold-boot answer resolves nothing", se.refresh(now=100.0, reader=cold), False)
check("the reader was actually called", cold.calls, 1)
# THE THROTTLE. Without it the main loop would ask on every pass -- 250 Hz of
# pad samples means 250 subprocesses a second, on the process that IS the
# device's input path.
check("asking again before the interval does not call the reader",
      se.refresh(now=100.5, reader=cold), False)
check("...and the reader stayed uncalled", cold.calls, 1)
check("the deadline is one interval out", se.next_deadline(), 101.0)

# The late arrival: uwsm has imported by now. This is the transition the whole
# fix turns on -- the mapper is already running, and nothing restarted it.
warm = reader_returning(READY)
check("the environment arriving LATE is picked up", se.refresh(now=101.0, reader=warm), True)
check("and the resolver latches", se.resolved, True)
check("it says so, once, in the journal",
      sum("session environment resolved" in line for line in log), 1)
check("a resolved resolver stops polling entirely", se.next_deadline(), None)
check("...and never calls the reader again", se.refresh(now=200.0, reader=warm), False)
check("proved by the call count", warm.calls, 1)

# environ(): inherited variables stay, resolved ones win.
os.environ["DECK_TEST_INHERITED"] = "kept"
merged = se.environ()
check("inherited variables are carried through", merged.get("DECK_TEST_INHERITED"), "kept")
check("the resolved session variables are present too",
      merged.get("WAYLAND_DISPLAY"), "wayland-1")
del os.environ["DECK_TEST_INHERITED"]

# ⚠️ MERGED, NEVER REPLACED. A later read that omits a variable must not
# un-set it: a transient empty answer would otherwise take the keyboard's
# display away from a session that is running fine.
se2 = m.SessionEnv(interval=1.0, log=log.append)
se2.refresh(now=0.0, reader=reader_returning("WAYLAND_DISPLAY=wayland-1\n"))
se2.refresh(now=1.0, reader=reader_returning("OMARCHY_PATH=/opt/omarchy\n"))
check("a variable from an earlier read survives a later one that omits it",
      se2.variables.get("WAYLAND_DISPLAY"), "wayland-1")
check("and the later one is added", se2.variables.get("OMARCHY_PATH"), "/opt/omarchy")
check("still unresolved while one required variable is missing", se2.resolved, False)
check("which it names", se2.missing(), ["HYPRLAND_INSTANCE_SIGNATURE"])

# Giving up: the live ISO has no user manager at all, and a poll every second
# forever is a subprocess every second forever for nothing.
log3 = []
se3 = m.SessionEnv(interval=1.0, window=5.0, log=log3.append)
never = reader_returning(None)
now = 0.0
while se3.next_deadline() is not None and now < 20.0:
    se3.refresh(now=now, reader=never)
    now += 1.0
check("a resolver that never succeeds gives up", se3.gave_up, True)
check("after roughly the window, not forever", never.calls, 6)
check("and stops asking", se3.next_deadline(), None)
check("saying why, once", sum("no session environment" in line for line in log3), 1)
check("naming what was missing", "WAYLAND_DISPLAY" in log3[-1], True)
check("a resolver that gave up refreshes to nothing",
      se3.refresh(now=999.0, reader=reader_returning(READY)), False)

# --- the children are started with it ----------------------------------------
#
# The assertions above are about a dict. THESE are the ones that would have
# caught §5.28: they run real processes and read back the environment those
# processes actually got.

MARK = "DECK_SESSION_ENV_PROOF"
ECHO_ENV = ("import os, sys; "
            f"open(sys.argv[1], 'w').write(os.environ.get({MARK!r}, 'MISSING'))")


def spawn_and_read(env=None):
    """Run a child through spawn_detached and return the marker it saw."""
    with tempfile.TemporaryDirectory() as tmp:
        out = pathlib.Path(tmp) / "env"
        started = m.spawn_detached(
            [sys.executable, "-c", ECHO_ENV, str(out)], "prove the env", env=env)
        if not started:
            return "NOT STARTED"
        m._spawned[-1].wait(timeout=10)
        return out.read_text() if out.exists() else "NO OUTPUT"


check("an explicit env reaches the child",
      spawn_and_read(env={**os.environ, MARK: "explicit"}), "explicit")

# The default path: no env argument, so the child gets whatever the module's
# resolver holds. THIS is the cold-boot bug's exact shape -- omarchy-menu
# started with an environment that has no OMARCHY_PATH exits immediately, and
# the user calls that a dead button.
saved = dict(m.SESSION_ENV.variables)
try:
    m.SESSION_ENV.variables[MARK] = "resolved"
    check("a spawn with no env argument gets the RESOLVED session environment",
          spawn_and_read(), "resolved")
finally:
    m.SESSION_ENV.variables.clear()
    m.SESSION_ENV.variables.update(saved)

check("...and without it, the child sees nothing -- the bug, reproduced",
      spawn_and_read(), "MISSING")

# The focus watcher takes its environment from a source consulted at START
# time, not at construction: the object is built while the environment is
# still missing and started (or restarted) after it arrives.
FOCUS_STUB = ("import os, sys; "
              f"sys.stdout.write('focus 1\\n' if os.environ.get({MARK!r}) else 'focus 0\\n'); "
              "sys.stdout.flush(); "
              "import time; time.sleep(0.2)")
log4 = []
auto = m.AutoShow(focus_mod, [sys.executable, "-c", FOCUS_STUB], log=log4.append,
                  env_source=lambda: {**os.environ, MARK: "1"})
check("the focus watcher starts", auto.start(), True)
check("it was started with the session environment", auto.pump(False), True)
auto.stop()

log5 = []
auto = m.AutoShow(focus_mod, [sys.executable, "-c", FOCUS_STUB], log=log5.append,
                  env_source=lambda: {k: v for k, v in os.environ.items() if k != MARK})
auto.start()
check("without it the watcher reports the other state -- the env is really the source",
      auto.pump(True), False)
auto.stop()

# hyprctl needs HYPRLAND_INSTANCE_SIGNATURE, and a lock reading of None fails
# toward "does not auto-hide" -- silent, survivable, and invisible to every
# check. The env must reach it too.
HYPRCTL_STUB = ("import os; "
                f"print({LOCKED_ONE_MONITOR!r} if os.environ.get({MARK!r}) "
                f"else {UNLOCKED_NULL!r})")
check("read_lock_state passes the session environment to hyprctl",
      m.read_lock_state(argv=(sys.executable, "-c", HYPRCTL_STUB),
                        env={**os.environ, MARK: "1"}), True)
check("...and its default is the resolver, not a bare inherit",
      m.read_lock_state(argv=(sys.executable, "-c", HYPRCTL_STUB)), False)

# --- the invariant, enforced against the SOURCE ------------------------------
#
# ⚠️ THIS IS THE ONE THAT CATCHES THE NEXT §5.28. The bug was not a wrong line;
# it was a spawn added years after the justification for inheriting stopped
# being true, in a file where nothing forced the question. Every subprocess
# call in the mapper must NAME the environment it runs with -- including the
# resolver itself, which explicitly passes what it inherited because that is
# where XDG_RUNTIME_DIR and the bus address live.

MAPPER_SOURCE = REPO_ROOT / "src" / "deck-input-mapper.py"
tree = ast.parse(MAPPER_SOURCE.read_text())
spawns = [
    node for node in ast.walk(tree)
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
    and node.func.attr in ("Popen", "run")
    and isinstance(node.func.value, ast.Name) and node.func.value.id == "subprocess"
]
check("the mapper's subprocess call sites are all still accounted for",
      len(spawns) >= 4, True)
envless = sorted(node.lineno for node in spawns
                 if not any(kw.arg == "env" for kw in node.keywords))
check("EVERY subprocess call in the mapper names its environment (§5.28)",
      envless, [])

# The resolver is only worth anything if main() actually drives it, and main()
# is a 400-line function around a live device that no unit test can enter. So
# its wiring is asserted structurally instead of not at all -- deleting any of
# these three leaves a resolver that never resolves, which is §5.28 verbatim
# and would otherwise leave this whole suite green.
main_def = next(node for node in ast.walk(tree)
                if isinstance(node, ast.FunctionDef) and node.name == "main")
main_calls = [node for node in ast.walk(main_def)
              if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
              and isinstance(node.func.value, ast.Name)
              and node.func.value.id == "SESSION_ENV"]
called = sorted({node.func.attr for node in main_calls})
check("main() both asks at startup and keeps asking in the loop",
      sum(node.func.attr == "refresh" for node in main_calls) >= 2, True)
# Without this the select() blocks until the user presses something -- and the
# press they make is the one that needed the environment to be ready already.
check("...and its deadline bounds the select(), so an untouched Deck still polls",
      "next_deadline" in called, True)

print(f"\n{'PASS' if FAILURES == 0 else 'FAILED'} — {FAILURES} failure(s)")
sys.exit(1 if FAILURES else 0)
