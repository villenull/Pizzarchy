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


def raised(call):
    """The exception `call` raised, or None. For asserting on the LOUD paths --
    CLAUDE.md forbids swallowing, so "it complains" is itself a contract."""
    try:
        call()
    except Exception as exc:      # noqa: BLE001 -- the point is to catch anything
        return exc
    return None


# --- buttons -----------------------------------------------------------------

mm = fresh()
check("A press -> Enter down", mm.translate(e.EV_KEY, e.BTN_SOUTH, 1, 0.0), [(e.KEY_ENTER, 1)])
check("A release -> Enter up", mm.translate(e.EV_KEY, e.BTN_SOUTH, 0, 0.0), [(e.KEY_ENTER, 0)])
check("B press -> Esc down", mm.translate(e.EV_KEY, e.BTN_EAST, 1, 0.0), [(e.KEY_ESC, 1)])
check("Y press -> Space down", mm.translate(e.EV_KEY, e.BTN_WEST, 1, 0.0), [(e.KEY_SPACE, 1)])
# ⚠️ X IS BACKSPACE, NOT TAB, since the operator's 2026-08-12 decision
# (docs/tasks/T8-onscreen-keyboard.md, the block above §9f). Tab was §2.3's
# "next field" for archinstall and was given up deliberately for parity with
# the Ⓧ badge Valve paints on Backspace.
check("X press -> Backspace down", mm.translate(e.EV_KEY, e.BTN_NORTH, 1, 0.0),
      [(e.KEY_BACKSPACE, 1)])
check("X release -> Backspace up", mm.translate(e.EV_KEY, e.BTN_NORTH, 0, 0.0),
      [(e.KEY_BACKSPACE, 0)])
check("no face button emits Tab any more",
      e.KEY_TAB in set(m.BUTTON_MAP.values()), False)
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
check("X while STEAM is held does not also type Backspace",
      mm.translate(e.EV_KEY, e.BTN_NORTH, 1, 0.1), [])
check("the chord queued an OSK toggle", mm.pending_actions, ["toggle-osk"])
check("and releasing the chord's X types nothing either",
      mm.translate(e.EV_KEY, e.BTN_NORTH, 0, 0.15), [])

# X on its own must still be Backspace, or the chord would cost the keyboard
# its delete key.
mm = fresh()
check("X alone is Backspace", mm.translate(e.EV_KEY, e.BTN_NORTH, 1, 0.0),
      [(e.KEY_BACKSPACE, 1)])
check("X alone queues nothing", mm.pending_actions, [])

# 🔴 A HELD X ALWAYS GETS ITS RELEASE. X down, THEN steam grabbed, then X up:
# the chord branch used to swallow that release wholesale, which left the key
# held down. Survivable when it was Tab; with Backspace it empties the field.
mm = fresh()
check("X down first emits Backspace down",
      mm.translate(e.EV_KEY, e.BTN_NORTH, 1, 0.0), [(e.KEY_BACKSPACE, 1)])
mm.translate(e.EV_KEY, e.BTN_MODE, 1, 0.1)          # STEAM grabbed mid-hold
check("the release still reaches the consumer, or Backspace sticks down",
      mm.translate(e.EV_KEY, e.BTN_NORTH, 0, 0.2), [(e.KEY_BACKSPACE, 0)])
check("and that release did NOT arm the chord",
      "toggle-osk" in mm.pending_actions, False)

# Same hazard through the other door: the keyboard opening between press and
# release. `_osk_event` swallows face buttons' releases by design.
mm = fresh()
mm.translate(e.EV_KEY, e.BTN_NORTH, 1, 0.0)
mm.osk_active = True
check("a held X released after the keyboard opened is still released",
      mm.translate(e.EV_KEY, e.BTN_NORTH, 0, 0.1), [(e.KEY_BACKSPACE, 0)])

# Releasing STEAM must disarm the chord.
mm = fresh()
mm.translate(e.EV_KEY, e.BTN_MODE, 1, 0.0)
mm.translate(e.EV_KEY, e.BTN_MODE, 0, 0.1)
check("X after STEAM is released is Backspace again",
      mm.translate(e.EV_KEY, e.BTN_NORTH, 1, 0.2), [(e.KEY_BACKSPACE, 1)])
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
check("the emoji key runs omarchy-menu-emoji directly, NOT `omarchy-menu emoji` "
      "-- that verb does not exist on omarchy-menu's own dispatcher",
      m.MENU_ACTIONS["emoji"], ["omarchy-menu-emoji"])

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

# Any button disarms the tap, not just the CHORD_PRESSES partners: one that has
# no chord meaning still emits its own key underneath, and letting go afterwards
# must not also open a menu nobody asked for.
#
# ⚠️ THIS USED TO BE SPELLED WITH STEAM+A, back when A had no chord meaning. A
# is BROWSER_CHORD_PRESS now and emits nothing under STEAM (covered in its own
# section below), so the example moved to Start -- which is still KEY_ENTER in
# BUTTON_MAP and still not a partner, i.e. it makes the point the old one made.
# The key is read out of BUTTON_MAP rather than retyped, so a remap cannot leave
# this asserting a keycode the mapper no longer emits.
_PLAIN_UNDER_STEAM = e.BTN_START
check("the button this is spelled with is genuinely NOT a chord partner",
      _PLAIN_UNDER_STEAM in m.CHORD_PRESSES, False)
mm = fresh()
mm.translate(e.EV_KEY, e.BTN_MODE, 1, 0.0)
check("a non-partner pressed under STEAM still sends its own key",
      mm.translate(e.EV_KEY, _PLAIN_UNDER_STEAM, 1, 0.1),
      [(m.BUTTON_MAP[_PLAIN_UNDER_STEAM], 1)])
mm.translate(e.EV_KEY, _PLAIN_UNDER_STEAM, 0, 0.2)
mm.translate(e.EV_KEY, e.BTN_MODE, 0, 0.3)
check("...and it is still a chord, not a tap: no menu", mm.pending_actions, [])

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

# The emoji action goes through the exact same run_menu_action/spawn_detached
# path as the two menu buttons -- it just carries a different argv -- so it
# gets the same DEVNULL/no-shell/never-waited guarantees for free.
_result, _fake, _err = with_fake_subprocess(lambda: m.run_menu_action("emoji"))
check("the emoji action spawns omarchy-menu-emoji with no arguments",
      [argv for argv, _kw in _fake.calls], [["omarchy-menu-emoji"]])
check("and reports that it started", _result, True)
_result, _fake, _err = with_fake_subprocess(
    lambda: m.run_menu_action("emoji", dry_run=True))
check("--dry-run reports it instead of spawning, exactly like the menu buttons",
      (_fake.calls, "omarchy-menu-emoji" in _err, _result), ([], True, True))

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


# --- 🆕 STEAM+Y CLOSES THE FOCUSED WINDOW (docs/PROGRESS.md §5.37) -----------
#
# The controller equivalent of Omarchy's SUPER+W. Same shape as the STEAM+X
# chord above and the menus beside it: translate() queues a NAME, main()
# resolves it to an argv, and nothing here starts a process.
#
# 🔴 THE COMMAND IS NOT `killactive`, AND THAT IS A MEASUREMENT, NOT A STYLE
# CHOICE. On the Deck's Hyprland `hyprctl dispatch` takes a LUA EXPRESSION, so
# a classic dispatcher name is evaluated as a bare global and resolves to nil
# (`type(killactive)` is `nil`, probed on hardware 2026-08-15 -- via an
# `error()` because `hyprctl eval` never reports a value). The call then dies
# in stderr while the button looks perfectly bound, which is the §5.28 shape
# and what test/unit/test-hyprctl-syntax.sh exists to catch.
#
# Omarchy 4.0 binds it in Lua, in default/hypr/bindings/tiling.lua:
#     o.bind("SUPER + W", "Close window", hl.dsp.window.close())
# and `grep -rn killactive /usr/share/omarchy/` returns nothing at all.

check("STEAM+Y runs the SAME dispatcher Omarchy's own SUPER+W runs",
      m.CLOSE_WINDOW_ARGV, ["hyprctl", "dispatch", "hl.dsp.window.close()"])
# The two halves of that, asserted separately so a rewrite cannot quietly
# satisfy the shape while losing the point.
check("...in the Lua form test-hyprctl-syntax.sh's scanner accepts",
      m.CLOSE_WINDOW_ARGV[-1].startswith("hl."), True)
check("...and NOT as the old bareword dispatcher, which is nil on this Hyprland",
      any("killactive" in part for part in m.CLOSE_WINDOW_ARGV), False)
# ⚠️ Exec'd, never synthesised. A SUPER+W keystroke would do nothing at all the
# moment the user or upstream rebinds it, with nothing to read anywhere -- the
# reasoning the menus above are built on, applied to a second button.
#
# ⚠️ ASSERTED ON *SUPER*, NOT ON W. KEY_W is in EMITTED_KEYS and must be: the
# on-screen keyboard has a W key like every other letter, so its presence
# proves nothing either way. SUPER is the half a synthesised chord cannot do
# without, this uinput device has never declared it, and the kernel drops an
# undeclared code silently -- so a future "just send SUPER+W" would fail
# exactly as quietly as the nil dispatcher above.
check("it EXECs rather than synthesising a SUPER+W keystroke: no SUPER is emitted",
      (e.KEY_LEFTMETA in m.EMITTED_KEYS, e.KEY_RIGHTMETA in m.EMITTED_KEYS),
      (False, False))

# Y was genuinely unclaimed. Every other candidate on this pad is spoken for,
# and this is the assertion that fails if one of them is ever moved onto Y.
check("STEAM+Y collides with nothing else bound on this pad",
      (m.CLOSE_CHORD_PRESS == m.OSK_CHORD_PRESS,
       m.CLOSE_CHORD_PRESS == m.OSK_CHORD_HOLD,
       m.CLOSE_CHORD_PRESS == m.QAM_BUTTON,
       m.CLOSE_CHORD_PRESS == m.OSK_CAPS_BUTTON,
       m.CLOSE_CHORD_PRESS in m.TRIGGER_BUTTON_MAP,
       m.CLOSE_CHORD_PRESS in m.PAD_CLICK_HALF,
       m.CLOSE_CHORD_PRESS in m.DPAD_BUTTON_MAP),
      (False, False, False, False, False, False, False))
check("and it is physical Y", m.CLOSE_CHORD_PRESS, e.BTN_WEST)

# 🔴 ACCEPTANCE, HALF ONE: the chord closes a window and does NOT touch the OSK.
mm = fresh()
mm.translate(e.EV_KEY, e.BTN_MODE, 1, 0.0)
check("Y while STEAM is held does not also type Space",
      mm.translate(e.EV_KEY, e.BTN_WEST, 1, 0.1), [])
check("the chord queued a window close", mm.pending_actions, ["close-window"])
check("🔴 and did NOT toggle the on-screen keyboard",
      "toggle-osk" in mm.pending_actions, False)
check("releasing the chord's Y types nothing either",
      mm.translate(e.EV_KEY, e.BTN_WEST, 0, 0.15), [])
check("releasing STEAM after the chord emits nothing",
      mm.translate(e.EV_KEY, e.BTN_MODE, 0, 0.2), [])
check("🔴 and STEAM+Y is a CHORD, not a tap: no apps menu underneath it",
      mm.pending_actions, ["close-window"])

# 🔴 ACCEPTANCE, HALF TWO: the chord-less tap is untouched. This is the binding
# STEAM has had since §5.23, and adding a partner to STEAM must not cost it.
mm = fresh()
mm.translate(e.EV_KEY, e.BTN_MODE, 1, 0.0)
mm.translate(e.EV_KEY, e.BTN_MODE, 0, 0.1)
check("🔴 STEAM alone still opens the apps menu", mm.pending_actions, ["menu-apps"])
check("...and opened no window-close on the way", "close-window" in mm.pending_actions, False)

# Y on its own must still be Space, or the chord would cost the keyboard its
# space bar -- the exact trade X/Backspace is protected against above.
mm = fresh()
check("Y alone is Space", mm.translate(e.EV_KEY, e.BTN_WEST, 1, 0.0),
      [(e.KEY_SPACE, 1)])
check("...and its release is Space up",
      mm.translate(e.EV_KEY, e.BTN_WEST, 0, 0.1), [(e.KEY_SPACE, 0)])
check("Y alone queues nothing", mm.pending_actions, [])

# 🔴 A HELD Y ALWAYS GETS ITS RELEASE. Y down, THEN STEAM grabbed, then Y up.
# The chord branch swallows that release wholesale unless the guard at the top
# of translate() pairs it -- and Y is SPACE, so a lost release types spaces for
# ever into whatever has focus. Identical hazard to X/Backspace; it arrived the
# moment Y became a chord partner.
mm = fresh()
check("Y down first emits Space down",
      mm.translate(e.EV_KEY, e.BTN_WEST, 1, 0.0), [(e.KEY_SPACE, 1)])
mm.translate(e.EV_KEY, e.BTN_MODE, 1, 0.1)          # STEAM grabbed mid-hold
check("🔴 the release still reaches the consumer, or Space sticks down",
      mm.translate(e.EV_KEY, e.BTN_WEST, 0, 0.2), [(e.KEY_SPACE, 0)])
check("and that release did NOT arm the chord",
      "close-window" in mm.pending_actions, False)

# Same hazard through the other door: the keyboard opening between press and
# release, where `_osk_event` swallows face buttons' releases by design.
mm = fresh()
mm.translate(e.EV_KEY, e.BTN_WEST, 1, 0.0)
mm.osk_active = True
check("a held Y released after the keyboard opened is still released",
      mm.translate(e.EV_KEY, e.BTN_WEST, 0, 0.1), [(e.KEY_SPACE, 0)])

# 🔴 THE CHORD PARTNERS MUST NOT SHARE ONE FLAG. This is what a single boolean
# gets wrong: X's release clears the flag, and the next partner's release then
# finds nothing to pair with and sticks its own key down for ever. ALL of them
# held, STEAM grabbed over the lot, all of them released.
#
# ⚠️ DRIVEN FROM `CHORD_PRESSES` ITSELF, not from a list of buttons written out
# here. A fifth partner added to that table is covered by this the day it lands,
# which is the only way a test like this stays true of a table that grows.
_partners = sorted(m.CHORD_PRESSES)
check("there is more than one partner, or this proves nothing at all",
      len(_partners) > 1, True)
mm = fresh()
check("every partner's press emits its own plain key",
      [mm.translate(e.EV_KEY, code, 1, 0.01 * i) for i, code in enumerate(_partners)],
      [[(m.BUTTON_MAP[code], 1)] for code in _partners])
mm.translate(e.EV_KEY, e.BTN_MODE, 1, 0.5)          # STEAM grabbed over them all
check("🔴 ...and every one of those releases is still delivered -- one shared "
      "flag loses all but the first",
      [mm.translate(e.EV_KEY, code, 0, 0.6 + 0.01 * i)
       for i, code in enumerate(_partners)],
      [[(m.BUTTON_MAP[code], 0)] for code in _partners])
check("...and none of those releases armed a chord", mm.pending_actions, [])

# The chord stays reachable while the keyboard is up, exactly as STEAM+X is:
# the chord branch sits ABOVE the `osk_active` routing on purpose.
mm = fresh()
mm.osk_active = True
mm.translate(e.EV_KEY, e.BTN_MODE, 1, 0.0)
check("STEAM+Y with the keyboard up closes the window rather than typing a space",
      (mm.translate(e.EV_KEY, e.BTN_WEST, 1, 0.1), mm.pending_actions),
      ([], ["close-window"]))

# Disarming works the same way it does for X.
mm = fresh()
mm.translate(e.EV_KEY, e.BTN_MODE, 1, 0.0)
mm.translate(e.EV_KEY, e.BTN_MODE, 0, 0.1)
mm.pending_actions.clear()
check("Y after STEAM is released is Space again",
      mm.translate(e.EV_KEY, e.BTN_WEST, 1, 0.2), [(e.KEY_SPACE, 1)])
check("and no window close is queued", "close-window" in mm.pending_actions, False)

# The pad's own autorepeat under a held STEAM must not fire it repeatedly --
# a held Y would otherwise close every window on the workspace in turn.
mm = fresh()
mm.translate(e.EV_KEY, e.BTN_MODE, 1, 0.0)
mm.translate(e.EV_KEY, e.BTN_WEST, 1, 0.1)
mm.translate(e.EV_KEY, e.BTN_WEST, 2, 0.2)
mm.translate(e.EV_KEY, e.BTN_WEST, 2, 0.3)
check("🔴 a HELD Y closes ONE window, not one per autorepeat",
      mm.pending_actions, ["close-window"])

# ⚠️ CHORD_PRESSES is what the release guard reads, so every partner in it must
# have a plain BUTTON_MAP meaning to hand back. A partner added without one
# makes the guard raise KeyError on a perfectly ordinary button release -- in
# the input loop of the only input path on the device.
check("every chord partner has a plain key to release",
      sorted(code for code in m.CHORD_PRESSES if code not in m.BUTTON_MAP), [])
# ⚠️ RELATIONSHIPS, NOT A COPY OF THE TABLE. A list of the action names written
# out here would have to be edited every time a chord is added, which is exactly
# how a test stops asserting anything and starts being maintained.
check("no two chords queue the SAME action -- one of them would be unreachable",
      len(set(m.CHORD_PRESSES.values())), len(m.CHORD_PRESSES))
# 🔴 run_pending tests `action in MENU_ACTIONS` BEFORE it reaches the close or
# the launchers, so a chord action name that collided with a menu's would open a
# menu instead and every behavioural test here would still pass.
check("no chord action collides with a menu action name",
      sorted(set(m.CHORD_PRESSES.values()) & set(m.MENU_ACTIONS)), [])
# The two tables that have to agree: everything LAUNCH_ACTIONS can run must be
# something a chord can actually queue, or it is a launcher no button reaches.
check("every launch action is reachable from a chord",
      sorted(set(m.LAUNCH_ACTIONS) - set(m.CHORD_PRESSES.values())), [])

# --- and the spawn, through the same stub the menus use ----------------------

_result, _fake, _err = with_fake_subprocess(lambda: m.run_close_window())
check("closing a window spawns exactly the measured argv",
      [argv for argv, _kw in _fake.calls],
      [["hyprctl", "dispatch", "hl.dsp.window.close()"]])
check("and reports that it started", _result, True)
check("nothing waits on it -- hyprctl must never freeze the input loop",
      [p.waited for p in _fake.procs], [False])
check("and it is an argv, never a shell string",
      _fake.calls[0][1].get("shell"), None)
# 🔴 §5.28: hyprctl needs HYPRLAND_INSTANCE_SIGNATURE, which this service does
# NOT inherit -- measured on the Deck, whose running mapper's environ carries
# XDG_RUNTIME_DIR and no signature at all. Without the RESOLVED environment
# this binding is dead and says nothing. (The AST sweep below enforces the
# general rule; this pins that THIS spawn is covered by it.)
check("it runs with the RESOLVED session environment, not what it inherited",
      _fake.calls[0][1].get("env") is not None, True)
check("a successful spawn says nothing on stderr", _err, "")

_result, _fake, _err = with_fake_subprocess(
    lambda: m.run_close_window(),
    error=FileNotFoundError(2, "No such file or directory", "hyprctl"))
check("a missing hyprctl does not raise", _result, False)
check("it is LOUD about it", "could not run" in _err, True)
check("and names the command it tried", "hl.dsp.window.close()" in _err, True)
# 🔴 AND BLAMES THE RIGHT BINARY. run_menu_action's message names omarchy-menu;
# printing that for a missing hyprctl sends whoever reads the journal after a
# dead button to the wrong package entirely.
check("🔴 and names hyprctl, NOT omarchy-menu", ("hyprctl" in _err, "omarchy-menu" in _err),
      (True, False))
check("and says the rest of the mapper is unaffected",
      "the rest of the mapper is unaffected" in _err, True)

_result, _fake, _err = with_fake_subprocess(lambda: m.run_close_window(dry_run=True))
check("--dry-run reports it instead of spawning, exactly like the menu buttons",
      (_fake.calls, "hl.dsp.window.close()" in _err, _result), ([], True, True))

# End to end, the way main() drives it: translate queues a NAME, the dispatcher
# resolves it to an argv. Either half alone still passes if the two are crossed.
mm = fresh()
mm.translate(e.EV_KEY, e.BTN_MODE, 1, 0.0)
mm.translate(e.EV_KEY, e.BTN_WEST, 1, 0.1)
mm.translate(e.EV_KEY, e.BTN_WEST, 0, 0.2)
mm.translate(e.EV_KEY, e.BTN_MODE, 0, 0.3)
check("STEAM+Y queues exactly one action, and it is the close",
      mm.pending_actions, ["close-window"])
_result, _fake, _err = with_fake_subprocess(
    lambda: [m.run_close_window() for _a in mm.pending_actions])
check("a STEAM+Y chord closes the window end to end",
      [argv for argv, _kw in _fake.calls],
      [["hyprctl", "dispatch", "hl.dsp.window.close()"]])

# ⚠️ The close is NOT in MENU_ACTIONS, and that is the point: run_menu_action's
# failure message names omarchy-menu, so an entry there would blame the wrong
# package for a dead STEAM+Y. That no queued name falls through to main()'s
# "no handler" branch is asserted against the SOURCE at the end of this file.
check("the window close is not smuggled into the menus' table",
      "close-window" in m.MENU_ACTIONS, False)


# --- 🆕 STEAM+B OPENS A TERMINAL, STEAM+A A BROWSER --------------------------
#
# Operator request. The controller equivalents of Omarchy's SUPER+RETURN and
# SUPER+SHIFT+B, and the same shape as every binding above: translate() queues a
# NAME, main() resolves it to an argv, nothing here starts a process.
#
# 🔴 WHAT MAKES THESE DIFFERENT FROM THE TWO CHORDS BEFORE THEM: A and B ALREADY
# HAD PLAIN MEANINGS THE USER USES (Enter and Esc). Every assertion about what
# they still do alone is therefore load-bearing, not ceremony.

check("B is the terminal chord and A is the browser chord",
      (m.CHORD_PRESSES.get(m.TERMINAL_CHORD_PRESS),
       m.CHORD_PRESSES.get(m.BROWSER_CHORD_PRESS)),
      ("launch-terminal", "launch-browser"))
check("...and they are physical B and physical A",
      (m.TERMINAL_CHORD_PRESS, m.BROWSER_CHORD_PRESS), (e.BTN_EAST, e.BTN_SOUTH))
check("the two chords are different buttons and different commands",
      (m.TERMINAL_CHORD_PRESS == m.BROWSER_CHORD_PRESS,
       m.LAUNCH_TERMINAL_ARGV == m.LAUNCH_BROWSER_ARGV),
      (False, False))
check("neither collides with the chords that were already bound",
      sorted({m.TERMINAL_CHORD_PRESS, m.BROWSER_CHORD_PRESS}
             & {m.OSK_CHORD_PRESS, m.CLOSE_CHORD_PRESS, m.OSK_CHORD_HOLD}), [])


# 🔴 THE COMMANDS MUST NOT NAME AN APPLICATION. The operator's instruction was
# "it should go to whatever is the default terminal": `omarchy-launch-terminal`
# resolves the user's default through `xdg-terminal-exec` and
# `omarchy-launch-browser` resolves the xdg default. Hard-coding today's answer
# (foot, chromium) would be a binding that quietly stops obeying the user the
# moment they change their default -- and it would still pass every behavioural
# assertion in this file, because a spawn is a spawn.
_CONCRETE_APPS = ("foot", "kitty", "alacritty", "ghostty", "wezterm", "konsole",
                  "chromium", "chrome", "firefox", "brave", "zen")


def names_a_concrete_app(argv) -> bool:
    """True if this argv names a specific application rather than a resolver."""
    return any(part == app or part.endswith("/" + app)
               for part in argv for app in _CONCRETE_APPS)


# ⚠️ THE POSITIVE CONTROL, IN THE SAME BREATH. An "it does not contain X" check
# whose predicate is broken passes for ever and looks like a guarantee. These
# two prove the predicate can actually see a hard-coded application.
check("the app-name detector really fires on a hard-coded terminal",
      names_a_concrete_app(["foot", "-e", "bash"]), True)
check("...and on a hard-coded browser behind a path",
      names_a_concrete_app(["uwsm-app", "--", "/usr/bin/chromium"]), True)
check("🔴 the terminal chord names a RESOLVER, never a terminal",
      names_a_concrete_app(m.LAUNCH_TERMINAL_ARGV), False)
check("🔴 the browser chord names a RESOLVER, never a browser",
      names_a_concrete_app(m.LAUNCH_BROWSER_ARGV), False)
# Both are Omarchy's own launchers, which is what makes the controller land on
# the same command SUPER+RETURN and SUPER+SHIFT+B already run.
check("both go through Omarchy's own launcher binaries",
      [argv[0].startswith("omarchy-launch-")
       for argv in (m.LAUNCH_TERMINAL_ARGV, m.LAUNCH_BROWSER_ARGV)],
      [True, True])
# The resolution happens INSIDE those binaries. An argument list would mean this
# file had an opinion about the user's default, which is the thing it must not.
check("neither carries arguments of its own",
      [len(argv) for argv in (m.LAUNCH_TERMINAL_ARGV, m.LAUNCH_BROWSER_ARGV)],
      [1, 1])
# Exec'd, never synthesised -- the same argument CLOSE_WINDOW_ARGV makes, and
# the same evidence: SUPER is not a key this uinput device has ever declared, so
# a synthesised SUPER+RETURN would be dropped by the kernel with no error.
check("no SUPER is emitted, so nothing here could be a synthesised keystroke",
      (e.KEY_LEFTMETA in m.EMITTED_KEYS, e.KEY_RIGHTMETA in m.EMITTED_KEYS),
      (False, False))
check("and the launchers are not smuggled into the menus' table",
      sorted(set(m.LAUNCH_ACTIONS) & set(m.MENU_ACTIONS)), [])

# 🔴 ACCEPTANCE: the chord launches, and does nothing else.
mm = fresh()
mm.translate(e.EV_KEY, e.BTN_MODE, 1, 0.0)
check("B while STEAM is held does not also type Esc",
      mm.translate(e.EV_KEY, e.BTN_EAST, 1, 0.1), [])
check("the chord queued a terminal", mm.pending_actions, ["launch-terminal"])
check("🔴 and toggled no keyboard and closed no window",
      ("toggle-osk" in mm.pending_actions, "close-window" in mm.pending_actions),
      (False, False))
check("releasing the chord's B types nothing either",
      mm.translate(e.EV_KEY, e.BTN_EAST, 0, 0.15), [])
check("🔴 and STEAM+B is a CHORD, not a tap: no apps menu underneath it",
      (mm.translate(e.EV_KEY, e.BTN_MODE, 0, 0.2), mm.pending_actions),
      ([], ["launch-terminal"]))

mm = fresh()
mm.translate(e.EV_KEY, e.BTN_MODE, 1, 0.0)
check("A while STEAM is held does not also type Enter",
      mm.translate(e.EV_KEY, e.BTN_SOUTH, 1, 0.1), [])
check("the chord queued a browser", mm.pending_actions, ["launch-browser"])
check("🔴 and STEAM+A is a CHORD, not a tap: no apps menu underneath it",
      (mm.translate(e.EV_KEY, e.BTN_SOUTH, 0, 0.15),
       mm.translate(e.EV_KEY, e.BTN_MODE, 0, 0.2),
       mm.pending_actions),
      ([], [], ["launch-browser"]))

# 🔴 THE COST, ASSERTED RATHER THAN ASSUMED. A and B are the installer's confirm
# and cancel (BUTTON_MAP), and they keep those meanings everywhere except under
# a held STEAM. If this ever regresses, the controller stops being able to
# answer a prompt at all.
mm = fresh()
check("A alone is still Enter, down and up",
      (mm.translate(e.EV_KEY, e.BTN_SOUTH, 1, 0.0),
       mm.translate(e.EV_KEY, e.BTN_SOUTH, 0, 0.1)),
      ([(e.KEY_ENTER, 1)], [(e.KEY_ENTER, 0)]))
check("B alone is still Esc, down and up",
      (mm.translate(e.EV_KEY, e.BTN_EAST, 1, 0.2),
       mm.translate(e.EV_KEY, e.BTN_EAST, 0, 0.3)),
      ([(e.KEY_ESC, 1)], [(e.KEY_ESC, 0)]))
check("and neither queued anything on its own", mm.pending_actions, [])

# Disarming works the same way it does for X and Y.
mm = fresh()
mm.translate(e.EV_KEY, e.BTN_MODE, 1, 0.0)
mm.translate(e.EV_KEY, e.BTN_MODE, 0, 0.1)
mm.pending_actions.clear()
check("B after STEAM is released is Esc again",
      mm.translate(e.EV_KEY, e.BTN_EAST, 1, 0.2), [(e.KEY_ESC, 1)])
check("A after STEAM is released is Enter again",
      mm.translate(e.EV_KEY, e.BTN_SOUTH, 1, 0.25), [(e.KEY_ENTER, 1)])
check("and nothing was launched", mm.pending_actions, [])

# The pad's own autorepeat under a held STEAM must not fire it repeatedly -- a
# thumb resting on B would otherwise open a terminal several times a second.
mm = fresh()
mm.translate(e.EV_KEY, e.BTN_MODE, 1, 0.0)
mm.translate(e.EV_KEY, e.BTN_EAST, 1, 0.1)
mm.translate(e.EV_KEY, e.BTN_EAST, 2, 0.2)
mm.translate(e.EV_KEY, e.BTN_EAST, 2, 0.3)
check("🔴 a HELD B opens ONE terminal, not one per autorepeat",
      mm.pending_actions, ["launch-terminal"])

# Reachable with the keyboard up, exactly as STEAM+X and STEAM+Y are: the chord
# branch sits ABOVE the `osk_active` routing on purpose.
mm = fresh()
mm.osk_active = True
mm.translate(e.EV_KEY, e.BTN_MODE, 1, 0.0)
check("STEAM+B with the keyboard up opens a terminal rather than reaching the OSK",
      (mm.translate(e.EV_KEY, e.BTN_EAST, 1, 0.1), mm.pending_actions),
      ([], ["launch-terminal"]))

# --- and the spawn, through the same stub the menus and the close use --------

_result, _fake, _err = with_fake_subprocess(lambda: m.run_launch_action("launch-terminal"))
check("the terminal chord spawns the terminal launcher and nothing else",
      [argv for argv, _kw in _fake.calls], [m.LAUNCH_TERMINAL_ARGV])
check("and reports that it started", _result, True)
check("nothing waits on it -- a slow launcher must never freeze the input loop",
      [p.waited for p in _fake.procs], [False])
check("and it is an argv, never a shell string",
      _fake.calls[0][1].get("shell"), None)
check("its output is discarded rather than mixed into our journal",
      (_fake.calls[0][1].get("stdout"), _fake.calls[0][1].get("stderr")),
      (_subprocess.DEVNULL, _subprocess.DEVNULL))
# 🔴 §5.28 again. `omarchy-launch-terminal` execs `uwsm-app`, which needs the
# session's own environment; a launcher started with what a cold-booted service
# inherited is another dead button that says nothing.
check("it runs with the RESOLVED session environment, not what it inherited",
      _fake.calls[0][1].get("env") is not None, True)
check("a successful spawn says nothing on stderr", _err, "")

_result, _fake, _err = with_fake_subprocess(lambda: m.run_launch_action("launch-browser"))
check("the browser chord spawns the browser launcher",
      [argv for argv, _kw in _fake.calls], [m.LAUNCH_BROWSER_ARGV])

# 🔴 AND IT BLAMES THE RIGHT BINARY. run_menu_action names omarchy-menu and
# run_close_window names hyprctl; either sentence printed for a missing launcher
# sends whoever reads the journal to the wrong package entirely.
_result, _fake, _err = with_fake_subprocess(
    lambda: m.run_launch_action("launch-terminal"),
    error=FileNotFoundError(2, "No such file or directory", "omarchy-launch-terminal"))
check("a missing launcher does not raise", _result, False)
check("it is LOUD about it", "could not run" in _err, True)
check("and names the command it tried", m.LAUNCH_TERMINAL_ARGV[0] in _err, True)
check("🔴 and blames neither omarchy-menu nor hyprctl",
      ("omarchy-menu" in _err, "hyprctl" in _err), (False, False))
check("and says the rest of the mapper is unaffected",
      "the rest of the mapper is unaffected" in _err, True)

_result, _fake, _err = with_fake_subprocess(
    lambda: m.run_launch_action("launch-browser"),
    error=FileNotFoundError(2, "No such file or directory", "omarchy-launch-browser"))
check("🔴 the browser's failure names the BROWSER launcher, not the terminal's",
      (m.LAUNCH_BROWSER_ARGV[0] in _err, m.LAUNCH_TERMINAL_ARGV[0] in _err),
      (True, False))

_result, _fake, _err = with_fake_subprocess(
    lambda: m.run_launch_action("launch-terminal", dry_run=True))
check("--dry-run reports it instead of spawning, exactly like every other spawn",
      (_fake.calls, m.LAUNCH_TERMINAL_ARGV[0] in _err, _result), ([], True, True))

# Unreachable from translate(), which queues only CHORD_PRESSES' names -- and
# therefore loud rather than an ignored default branch.
_result, _fake, _err = with_fake_subprocess(lambda: m.run_launch_action("launch-nope"))
check("an unknown launch action starts nothing and says so",
      (_fake.calls, _result, "launch-nope" in _err), ([], False, True))

# End to end, the way main() drives it: the chord queues a NAME, the runner
# resolves it to an argv. Either half alone still passes if the two are crossed.
mm = fresh()
mm.translate(e.EV_KEY, e.BTN_MODE, 1, 0.0)
mm.translate(e.EV_KEY, e.BTN_SOUTH, 1, 0.1)
mm.translate(e.EV_KEY, e.BTN_SOUTH, 0, 0.2)
mm.translate(e.EV_KEY, e.BTN_MODE, 0, 0.3)
check("STEAM+A queues exactly one action, and it is the browser",
      mm.pending_actions, ["launch-browser"])
_result, _fake, _err = with_fake_subprocess(
    lambda: [m.run_launch_action(a) for a in mm.pending_actions])
check("🔴 a STEAM+A chord opens the BROWSER end to end -- not the terminal",
      [argv for argv, _kw in _fake.calls], [m.LAUNCH_BROWSER_ARGV])
check("and the mapper still translates afterwards",
      fresh().translate(e.EV_KEY, e.BTN_TL, 1, 0.0), [(m.BUTTON_MAP[e.BTN_TL], 1)])


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
# 🆕 The launchers are in the same report and for the same reason: "I pressed
# STEAM+B and nothing happened" has to be diagnosable from the journal alone.
check("startup names both launcher commands",
      [argv[0] in _report_n
       for argv in (m.LAUNCH_TERMINAL_ARGV, m.LAUNCH_BROWSER_ARGV)],
      [True, True])
check("...and which button runs which",
      ("STEAM+B" in _report_n, "STEAM+A" in _report_n), (True, True))
# 🔴 AND WHAT THEY COST. A and B carried Enter and Esc; "STEAM+A stopped
# confirming" is otherwise a mystery with nothing to read anywhere.
check("🔴 startup says the two no longer emit Enter and Esc under STEAM",
      ("Enter" in _report_n, "Esc" in _report_n), (True, True))

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

# --- 🔴 THE LIFT MUST NOT MOVE THE POINTER (T8 §9h #3) -----------------------
#
# The operator, 2026-08-12: *"when i release, often the mouse moves a non-zero
# distance in an annoying way. almost as if in the release the deck is reading
# exactly how i released and moving the mouse that way"*.
#
# ⚠️ AND `POINTER_JUMP_RAW` ABOVE IS WHY THAT IS NOT ALREADY FIXED. It catches
# the step to centre only when the thumb was FURTHER OUT than 4000 counts.
# Lifting from anywhere nearer produces a step the clamp calls ordinary
# movement, and `int(step/125)` pixels of cursor travel toward the pad centre --
# in the exact direction the finger was sitting, which is what the operator
# described. The fixtures below are the SAME 23 real lifts §9h #1 was measured
# from, so this is not a hypothetical shape: it is the hardware's.
#
# The capture recorded the LEFT pad and the pointer is the RIGHT one. That is
# not a substitution: the shipped `hid-steam.ko` compiles the two pairs
# identically (`Mapper.pointer_lifted` quotes both), so a left-pad lift and a
# right-pad lift are the same four instructions with a different axis constant.
CAPTURED_LIFT_TAILS = [
    "L.y=3338 L.x=4782 L.y=3370 L.x=4651 L.x=0 L.y=0",
    "R.y=-14856 R.x=-8610 R.x=-8435 R.x=-8192 R.x=0 R.y=0",
    "L.x=8973 L.x=8746 L.x=8208 L.x=8070 L.x=0 L.y=0",
    "L.x=11646 L.y=-1358 L.x=11500 L.y=-1198 L.x=0 L.y=0",
    "L.x=2799 L.y=6849 L.x=2612 L.y=6980 L.x=0 L.y=0",
    "L.y=10920 L.x=-997 L.x=-1147 L.y=10881 L.x=0 L.y=0",
    "L.x=16846 L.y=-860 L.x=16624 L.y=-904 L.x=0 L.y=0",
    "L.x=270 L.y=17200 L.x=96 L.y=17234 L.x=-121 L.y=0",   # <-- the residual
    "L.x=7803 L.y=-3163 L.x=7614 L.y=-2972 L.x=0 L.y=0",
    "L.x=14951 L.x=14216 L.x=14057 L.x=13897 L.x=0 L.y=0",
    "L.x=21238 L.y=-4032 L.x=21379 L.y=-4093 L.x=0 L.y=0",
    "L.x=19461 L.y=-6206 L.x=19516 L.y=-6354 L.x=0 L.y=0",
    "L.x=15803 L.y=4620 L.x=14922 L.y=4587 L.x=0 L.y=0",
    "L.y=-4215 L.y=-4349 L.y=-4485 L.y=-4626 L.x=0 L.y=0",
    "L.x=6808 L.y=4190 L.x=6853 L.y=4156 L.x=0 L.y=0",
    "R.y=14871 R.y=14832 R.y=14800 R.y=13996 R.x=0 R.y=0",
    "L.y=-10616 L.y=-10581 L.x=0 L.y=0 R.x=0 R.y=0",
    "L.x=20373 L.y=-18616 L.x=20529 L.y=-18671 L.x=0 L.y=0",
    "L.x=6356 L.y=4565 L.x=6131 L.y=4724 L.x=0 L.y=0",
    "L.x=-6725 L.x=-6853 L.x=-6900 L.x=-6936 L.x=0 L.y=0",
    "L.x=24931 L.y=-14478 L.y=-14424 L.y=-14379 L.x=0 L.y=0",
    "L.x=16309 L.y=-12116 L.x=16439 L.y=-12255 L.x=0 L.y=0",
    "L.x=-8998 L.y=9646 L.x=-9163 L.y=9812 L.x=0 L.y=0",
]
check("all 23 captured lifts are carried, not a convenient subset",
      len(CAPTURED_LIFT_TAILS), 23)

RIGHT_AXIS = {"x": e.ABS_HAT1X, "y": e.ABS_HAT1Y}


def reports_from_tail(tail: str) -> list:
    """Group a captured tail into evdev REPORTS -- the unit main() emits on.

    The capture logged samples, not SYN_REPORTs (it was taken to answer a
    different question). An axis repeating is the only place a report can have
    ended, so that is the split: `x=96 y=17234 x=-121 y=0` is two reports, and
    the lift's `x` and `y` land in ONE. That grouping is not a guess -- the
    disassembly quoted in `pointer_lifted` shows the driver emitting a pad's
    two zeroes back to back with no `input_sync` between them.
    """
    reports, current, seen = [], [], set()
    for token in tail.split():
        label, value = token.split("=")
        axis = label.split(".")[1]
        if axis in seen:
            reports.append(current)
            current, seen = [], set()
        current.append((axis, int(value)))
        seen.add(axis)
    if current:
        reports.append(current)
    return reports


def replay(reports: list, lift_check: bool = True) -> list:
    """Drive one Mapper the way main() does: accumulate a report's motion, then
    drain it at the report boundary. `lift_check=False` is the OLD behaviour --
    kept so the fixtures can be shown to actually reproduce the defect."""
    mm = fresh()
    emitted, now = [], 0.0
    for report in reports:
        dx = dy = 0
        for axis, value in report:
            ddx, ddy = mm.pointer_delta(RIGHT_AXIS[axis], value, now)
            dx += ddx
            dy += ddy
        if lift_check and mm.pointer_lifted():
            dx = dy = 0
        emitted.append((dx, dy))
        # 250 Hz, so nothing here is ever more than 4 ms apart: the touch-gap
        # timer CANNOT be what suppresses these. The release rule has to.
        now += 0.004
    return emitted


check("the fixture's reports are grouped as the driver emits them -- the "
      "residual lift's x and y are ONE report",
      reports_from_tail(CAPTURED_LIFT_TAILS[7])[-1], [("x", -121), ("y", 0)])
check("...and a tail that reports one axis at a time stays one axis per report",
      reports_from_tail(CAPTURED_LIFT_TAILS[2])[:2], [[("x", 8973)], [("x", 8746)]])
check("no fixture is replayed near the touch-gap threshold -- 23 lifts of at "
      "most 6 samples at 250Hz",
      max(len(reports_from_tail(t)) for t in CAPTURED_LIFT_TAILS) * 0.004
      < m.POINTER_TOUCH_GAP, True)

# 🔴 THE DEFECT, MEASURED ON THE FIXTURE. If this number is 0 the fixtures
# prove nothing -- they would pass against code that never had the bug. It is
# the count of captured lifts whose FINAL report moved the cursor under the
# rule that shipped.
jumped_before = [i for i, tail in enumerate(CAPTURED_LIFT_TAILS, 1)
                 if replay(reports_from_tail(tail), lift_check=False)[-1] != (0, 0)]
check("the captured lifts really did move the pointer under the OLD rule -- "
      "these fixtures can fail", len(jumped_before) >= 7, True)
check("...and the worst of them is a jump a user would call annoying "
      "(measured: 26 px, lift #1)",
      max(max(abs(dx), abs(dy)) for dx, dy in
          [replay(reports_from_tail(t), lift_check=False)[-1]
           for t in CAPTURED_LIFT_TAILS]) >= 20, True)

# 🔴 AND THE FIX: not one of the 23 moves the pointer on its lift.
jumped_after = [i for i, tail in enumerate(CAPTURED_LIFT_TAILS, 1)
                if replay(reports_from_tail(tail))[-1] != (0, 0)]
check("NOT ONE of the 23 captured lifts moves the pointer", jumped_after, [])

# ...including the one lift in 23 that does not reach centre on both axes.
# `pad_touched`'s residual is what catches this one, which is the whole reason
# there is one release rule here and not two.
check("the residual lift (#8, x stops at -121) emits nothing either",
      replay(reports_from_tail(CAPTURED_LIFT_TAILS[7]))[-1], (0, 0))
check("...and it is genuinely the residual doing it, not an exact zero",
      reports_from_tail(CAPTURED_LIFT_TAILS[7])[-1][0][1] != 0, True)

# ⚠️ THE OTHER HALF, and without it `return True` passes everything above.
# Real movement inside these same captures must still reach the cursor.
moved_before_lift = [tail for tail in CAPTURED_LIFT_TAILS
                     if any(step != (0, 0)
                            for step in replay(reports_from_tail(tail))[:-1])]
check("the captured strokes still move the cursor before they end -- 20 of the "
      "23 tails carry real motion, and all of it survives",
      len(moved_before_lift), 20)

# A deliberate, ordinary stroke: no zeroes anywhere, nothing may be suppressed.
stroke = [[("x", 10000), ("y", 10000)]]
stroke += [[("x", 10000 + m.POINTER_DIVISOR * n),
            ("y", 10000 + m.POINTER_DIVISOR * n)] for n in range(1, 6)]
check("an ordinary diagonal stroke emits on every report and on both axes",
      replay(stroke)[1:], [(1, -1)] * 5)

# ⚠️ AND THE RE-BASELINE MUST NOT WIPE THE OTHER AXIS. §7 records a measured
# defect where re-baselining replaced the whole dict, X and Y wiped each other,
# and diagonal motion emitted NOTHING. `pointer_lifted` clears both -- at a
# release, which is a real touch boundary -- so this drives a lift and then a
# fresh diagonal stroke through the same mapper the way the device would.
lift_then_stroke = [[("x", 8000), ("y", 8000)],
                    [("x", 8000 + m.POINTER_DIVISOR * 2),
                     ("y", 8000 + m.POINTER_DIVISOR * 2)],
                    [("x", 0), ("y", 0)]]                      # the lift
# ⚠️ The re-touch lands WITHIN POINTER_JUMP_RAW of the lift's zero, on
# purpose: further out and the jump clamp would absorb it and this would pass
# against a `pointer_lifted` that forgot to re-baseline at all.
retouch = -(m.POINTER_JUMP_RAW - 1000)
lift_then_stroke += [[("x", retouch), ("y", retouch)]]         # touched down again
lift_then_stroke += [[("x", retouch + m.POINTER_DIVISOR * n),
                      ("y", retouch + m.POINTER_DIVISOR * n)] for n in range(1, 4)]
replayed = replay(lift_then_stroke)
check("the lift itself emits nothing", replayed[2], (0, 0))
check("...and the re-touch elsewhere does not hurl the cursor there",
      replayed[3], (0, 0))
check("...and diagonal motion after the lift still emits on BOTH axes",
      replayed[4:], [(1, -1)] * 3)

# The release rule here is `pad_touched`'s, so its boundary is the same one.
# One count outside the residual is a touch and MUST still move the cursor --
# otherwise the "fix" is a deadband that eats real motion near the centre.
mm = fresh()
mm.pointer_delta(e.ABS_HAT1X, m.PAD_RELEASE_RESIDUAL + 1 + m.POINTER_DIVISOR, 0.0)
mm.pointer_delta(e.ABS_HAT1Y, 20000, 0.0)
mm.pointer_lifted()
dx, _ = mm.pointer_delta(e.ABS_HAT1X, m.PAD_RELEASE_RESIDUAL + 1, 0.004)
mm.pointer_delta(e.ABS_HAT1Y, 0, 0.004)
check("a sample one count OUTSIDE the residual is a touch, and still moves",
      (dx, mm.pointer_lifted()), (-1, False))
mm = fresh()
mm.pointer_delta(e.ABS_HAT1X, m.PAD_RELEASE_RESIDUAL + m.POINTER_DIVISOR, 0.0)
mm.pointer_delta(e.ABS_HAT1Y, 20000, 0.0)
mm.pointer_lifted()
mm.pointer_delta(e.ABS_HAT1X, m.PAD_RELEASE_RESIDUAL, 0.004)
mm.pointer_delta(e.ABS_HAT1Y, 0, 0.004)
check("...and one count INSIDE it, with the other axis zeroed, is the lift",
      mm.pointer_lifted(), True)

# ⚠️ AND IT MUST BE `pad_touched`'S RULE, NOT A LOOKALIKE. A plain deadband
# (|x| and |y| both within the residual) catches all 23 lifts above just as
# well -- and reads a thumb resting NEAR dead centre as lifted, which T8 §9h #1
# rejected precisely because dead centre is a legitimate place to aim. The
# exact-zero requirement is what keeps that thumb touched; nothing above can
# see the difference, so this does.
mm = fresh()
mm.pointer_delta(e.ABS_HAT1X, 100 + m.POINTER_DIVISOR, 0.0)
mm.pointer_delta(e.ABS_HAT1Y, 100 + m.POINTER_DIVISOR, 0.0)
mm.pointer_lifted()
dx, _ = mm.pointer_delta(e.ABS_HAT1X, 100, 0.004)
_, dy = mm.pointer_delta(e.ABS_HAT1Y, 100, 0.004)
check("a thumb creeping NEAR dead centre, neither axis zero, is still touched "
      "-- and still moves the cursor",
      (mm.pointer_lifted(), dx, dy), (False, -1, 1))

# The pointer path must feed the same state the badges read, or `pad_touched`
# is answering about a sample from the last time the keyboard was up.
mm = fresh()
mm.pointer_delta(e.ABS_HAT1X, 11111, 0.0)
mm.pointer_delta(e.ABS_HAT1Y, -2222, 0.0)
check("pointer samples are recorded into the pad state the release rule reads",
      mm.pad_last["right"], [11111, -2222])
check("...and the LEFT pad is untouched by the pointer path",
      mm.pad_last["left"], [0, 0])

# A quiet pad (no pointer events at all, e.g. a report carrying only a button)
# reads as lifted, and that must be harmless rather than a source of motion.
mm = fresh()
check("an untouched pad reports lifted, costing nothing",
      (mm.pointer_lifted(), mm.pointer_last), (True, {}))

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


def touch(mm, half, x=None, y=None):
    """Put a thumb on a pad at a real, off-centre position.

    ⚠️ Every trigger assertion below needs this first. A trigger only commits
    while its own pad is TOUCHED, and a fresh Mapper reports both pads lifted --
    which is correct (§9f's idle screenshot is the all-badges-visible state) and
    means an untouched trigger means Shift or Enter instead.
    """
    axes = {"left": (e.ABS_HAT0X, e.ABS_HAT0Y), "right": (e.ABS_HAT1X, e.ABS_HAT1Y)}
    ax, ay = axes[half]
    mm.translate(e.EV_ABS, ax, MINV if x is None else x, 0.0)
    mm.translate(e.EV_ABS, ay, MAXV if y is None else y, 0.0)


def key_under(mm, half):
    """The keycode the layout says sits under that cursor, right now.

    ⚠️ DERIVED, NOT HARD-CODED. The reference layout (T8 §9g) is being rebuilt
    in `deck_osk_layout.py`, and which character sits in a corner is that file's
    business, not this one's. What THIS suite pins is that the LEFT trigger
    commits the LEFT cursor's key and the right the right's -- so it asks the
    layout what that key is rather than asserting a character and going red
    every time a key moves.
    """
    return mm.osk.key_at(half, *mm.cursors.position(half)).code


mm = osk_mapper()
check("with the OSK up, a pad axis emits no keystroke",
      mm.translate(e.EV_ABS, e.ABS_HAT1X, MAXV, 0.0), [])
check("but it did move that cursor", mm.cursors.position("right")[0], 1.0)
check("and left the other cursor alone", mm.cursors.position("left"), (0.5, 0.5))

# Each trigger presses the key under its OWN cursor -- the whole point of two.
mm = osk_mapper()
touch(mm, "left", MINV, MAXV)     # left cursor -> top-left
touch(mm, "right", MAXV, MAXV)    # right cursor -> top-right
left_key, right_key = key_under(mm, "left"), key_under(mm, "right")
check("the two cursors are on different keys (or the check below proves nothing)",
      left_key != right_key, True)
check("the LEFT trigger types the key under the LEFT cursor",
      mm.translate(e.EV_KEY, e.BTN_TL2, 1, 0.1), [(left_key, 1), (left_key, 0)])
check("the RIGHT trigger types the key under the RIGHT cursor",
      mm.translate(e.EV_KEY, e.BTN_TR2, 1, 0.2), [(right_key, 1), (right_key, 0)])
check("a trigger RELEASE types nothing (or every key would double)",
      mm.translate(e.EV_KEY, e.BTN_TR2, 0, 0.3), [])

# With the keyboard up, the navigation profile underneath must be silent, or
# every press does two things at once.
mm = osk_mapper()
check("A no longer sends Enter while the keyboard is up",
      mm.translate(e.EV_KEY, e.BTN_SOUTH, 1, 0.0), [])
check("B no longer sends Esc", mm.translate(e.EV_KEY, e.BTN_EAST, 1, 0.0), [])
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

# --- 🔴 PAD TOUCH: `0,0` MEANS LIFTED (measured on hardware 2026-08-12) ------
#
# There is NO touch bit on this hardware -- the native node declares 24 buttons
# and none of them is BTN_TOUCH or BTN_TOOL_FINGER (capability dump AND a live
# capture in which no button fired during rest, lift or click). What was
# measured instead: a lift terminates at EXACTLY 0 on BOTH axes, while a resting
# thumb keeps emitting jittery samples at its real off-centre position.
#
# Everything Valve's badge gating and both trigger meanings hang off this rule,
# so it is asserted in both directions and at the boundary.

mm = osk_mapper()
check("a fresh mapper reports both pads LIFTED -- §9f's all-badges state",
      (mm.pad_touched("left"), mm.pad_touched("right")), (False, False))

# The two captured RESTS, replayed verbatim. Neither is centre; both are a thumb.
mm = osk_mapper()
mm.translate(e.EV_ABS, e.ABS_HAT0X, -26331, 0.0)
mm.translate(e.EV_ABS, e.ABS_HAT0Y, 6687, 0.0)
check("a resting thumb at the first captured position is TOUCHED",
      mm.pad_touched("left"), True)
mm.translate(e.EV_ABS, e.ABS_HAT0X, -25598, 1.0)
mm.translate(e.EV_ABS, e.ABS_HAT0Y, 966, 1.0)
check("...and still touched a second later without moving -- no timeout",
      mm.pad_touched("left"), True)

# The lift, and it is the ONLY thing that reports released.
mm.translate(e.EV_ABS, e.ABS_HAT0X, 0, 2.0)
check("one axis at 0 is NOT a lift -- a stroke crosses the centre line",
      mm.pad_touched("left"), True)
mm.translate(e.EV_ABS, e.ABS_HAT0Y, 0, 2.0)
check("BOTH axes at exactly 0 is the lift", mm.pad_touched("left"), False)
# ...and the axes may arrive in either order, since nothing measured says
# `hid-steam` sends them in one report.
mm = osk_mapper()
mm.translate(e.EV_ABS, e.ABS_HAT0Y, 6687, 0.0)
mm.translate(e.EV_ABS, e.ABS_HAT0X, 0, 0.0)
check("y-then-x order: still touched on one zero", mm.pad_touched("left"), True)
mm.translate(e.EV_ABS, e.ABS_HAT0Y, 0, 0.0)
check("y-then-x order: lifted on the second", mm.pad_touched("left"), False)

# ⚠️ THE ACCEPTED FAILURE MODE, pinned so nobody "fixes" it by accident: a thumb
# resting at exact dead centre is byte-for-byte a lift, and reads as released.
# Documented at PAD_TOUCH_AXES; do not add a heuristic without asking.
mm = osk_mapper()
mm.translate(e.EV_ABS, e.ABS_HAT0X, 0, 0.0)
mm.translate(e.EV_ABS, e.ABS_HAT0Y, 0, 0.0)
check("a thumb at EXACT dead centre reads as lifted (known, accepted)",
      mm.pad_touched("left"), False)

# --- 🔴 4% OF LIFTS DO NOT LAND ON (0, 0) -- 23 CAPTURED LIFTS, 2026-08-12 ---
#
# The operator: *"sometimes, when i release my fingers the aiming circle still
# appears (happens one out of every 7 times maybe)"*. Measured by capturing 23
# consecutive real lifts over 45s: 22 ended {x: 0, y: 0}, and ONE ended
# {y: 0, x: -121} -- one axis zeroed, the other stopped 121 counts short. The
# old rule wanted BOTH on zero, so it never saw that release and the cursor and
# badges froze until the next touch.
#
# 🔴 EVERY FIXTURE BELOW IS TRANSCRIBED FROM THAT CAPTURE, tail and all. The
# point of using the real tails rather than invented sequences is that an
# invented one would only ever contain the shapes whoever invented it thought
# of, and the shape that broke this is one nobody thought of.

PAD_AXIS_BY_NAME = {
    "L.x": e.ABS_HAT0X, "L.y": e.ABS_HAT0Y,
    "R.x": e.ABS_HAT1X, "R.y": e.ABS_HAT1Y,
}
HALF_BY_LETTER = {"L": "left", "R": "right"}

# The last six samples of each of the 23 bursts, verbatim.
CAPTURED_LIFT_TAILS = [
    ("#1",  [("L.y", 3338), ("L.x", 4782), ("L.y", 3370), ("L.x", 4651), ("L.x", 0), ("L.y", 0)]),
    ("#2",  [("R.y", -14856), ("R.x", -8610), ("R.x", -8435), ("R.x", -8192), ("R.x", 0), ("R.y", 0)]),
    ("#3",  [("L.x", 8973), ("L.x", 8746), ("L.x", 8208), ("L.x", 8070), ("L.x", 0), ("L.y", 0)]),
    ("#4",  [("L.x", 11646), ("L.y", -1358), ("L.x", 11500), ("L.y", -1198), ("L.x", 0), ("L.y", 0)]),
    ("#5",  [("L.x", 2799), ("L.y", 6849), ("L.x", 2612), ("L.y", 6980), ("L.x", 0), ("L.y", 0)]),
    ("#6",  [("L.y", 10920), ("L.x", -997), ("L.x", -1147), ("L.y", 10881), ("L.x", 0), ("L.y", 0)]),
    ("#7",  [("L.x", 16846), ("L.y", -860), ("L.x", 16624), ("L.y", -904), ("L.x", 0), ("L.y", 0)]),
    # 🔴 THE FAILURE. Note the x column: 270, 96, -121 -- and never 0.
    ("#8",  [("L.x", 270), ("L.y", 17200), ("L.x", 96), ("L.y", 17234), ("L.x", -121), ("L.y", 0)]),
    ("#9",  [("L.x", 7803), ("L.y", -3163), ("L.x", 7614), ("L.y", -2972), ("L.x", 0), ("L.y", 0)]),
    ("#10", [("L.x", 14951), ("L.x", 14216), ("L.x", 14057), ("L.x", 13897), ("L.x", 0), ("L.y", 0)]),
    ("#11", [("L.x", 21238), ("L.y", -4032), ("L.x", 21379), ("L.y", -4093), ("L.x", 0), ("L.y", 0)]),
    ("#12", [("L.x", 19461), ("L.y", -6206), ("L.x", 19516), ("L.y", -6354), ("L.x", 0), ("L.y", 0)]),
    ("#13", [("L.x", 15803), ("L.y", 4620), ("L.x", 14922), ("L.y", 4587), ("L.x", 0), ("L.y", 0)]),
    ("#14", [("L.y", -4215), ("L.y", -4349), ("L.y", -4485), ("L.y", -4626), ("L.x", 0), ("L.y", 0)]),
    ("#15", [("L.x", 6808), ("L.y", 4190), ("L.x", 6853), ("L.y", 4156), ("L.x", 0), ("L.y", 0)]),
    ("#16", [("R.y", 14871), ("R.y", 14832), ("R.y", 14800), ("R.y", 13996), ("R.x", 0), ("R.y", 0)]),
    # Both pads in one tail -- the only burst in the capture that lifts two.
    ("#17", [("L.y", -10616), ("L.y", -10581), ("L.x", 0), ("L.y", 0), ("R.x", 0), ("R.y", 0)]),
    ("#18", [("L.x", 20373), ("L.y", -18616), ("L.x", 20529), ("L.y", -18671), ("L.x", 0), ("L.y", 0)]),
    ("#19", [("L.x", 6356), ("L.y", 4565), ("L.x", 6131), ("L.y", 4724), ("L.x", 0), ("L.y", 0)]),
    ("#20", [("L.x", -6725), ("L.x", -6853), ("L.x", -6900), ("L.x", -6936), ("L.x", 0), ("L.y", 0)]),
    ("#21", [("L.x", 24931), ("L.y", -14478), ("L.y", -14424), ("L.y", -14379), ("L.x", 0), ("L.y", 0)]),
    ("#22", [("L.x", 16309), ("L.y", -12116), ("L.x", 16439), ("L.y", -12255), ("L.x", 0), ("L.y", 0)]),
    ("#23", [("L.x", -8998), ("L.y", 9646), ("L.x", -9163), ("L.y", 9812), ("L.x", 0), ("L.y", 0)]),
]


def replay_tail(mm, tail, now=0.0):
    """Feed one captured tail through `translate`, as the device sent it."""
    for name, value in tail:
        mm.translate(e.EV_ABS, PAD_AXIS_BY_NAME[name], value, now)


check("all 23 captured lifts are here, the failing one included",
      len(CAPTURED_LIFT_TAILS), 23)

stuck = []
for label, tail in CAPTURED_LIFT_TAILS:
    mm = osk_mapper()
    replay_tail(mm, tail)
    halves = sorted({HALF_BY_LETTER[name[0]] for name, _ in tail})
    if any(mm.pad_touched(half) for half in halves):
        stuck.append(label)
check("EVERY captured lift reads as released -- the operator's stuck cursor",
      stuck, [])

# ⚠️ Pinned separately so the suite cannot go green by #8 quietly becoming a
# clean (0, 0) fixture. If this stops being the awkward shape, the test above
# stops testing anything.
mm = osk_mapper()
replay_tail(mm, dict(CAPTURED_LIFT_TAILS)["#8"])
check("lift #8's final sample really is the one that used to stick",
      mm.pad_last["left"], [-121, 0])
check("...and the OLD rule -- exactly 0 on BOTH -- called that a TOUCH",
      any(mm.pad_last["left"]), True)
check("...while the rule now in force releases it", mm.pad_touched("left"), False)

# --- and the other half of the fix: a thumb still on the pad stays touched ---
#
# 🔴 EITHER ASSERTION ALONE IS NOT THE FIX. "Every lift releases" is satisfied
# by `return False`; "a resting thumb is touched" is satisfied by the rule that
# was just replaced. Only both together say the boundary moved to the right
# place.
RESTING_SAMPLES = [
    # The two captured rests, replayed verbatim.
    ((-26331, 6687), "the first captured rest"),
    ((-25598, 966), "the second captured rest"),
    # The same thumb after a 1.29s quiet gap in the same capture -- still down.
    ((-26265, 6815), "a rest that has not moved for over a second"),
    # ⚠️ ON a centre line, which is the shape the exact-zero half of the rule
    # has to survive: one axis really is 0 and the thumb really is down.
    ((0, 966), "a thumb resting on the vertical centre line"),
    ((966, 0), "...and on the horizontal one"),
    # One count outside the residual, on both sides and both axes.
    ((0, m.PAD_RELEASE_RESIDUAL + 1), "one count outside the residual, +y"),
    ((0, -(m.PAD_RELEASE_RESIDUAL + 1)), "one count outside the residual, -y"),
    ((m.PAD_RELEASE_RESIDUAL + 1, 0), "one count outside the residual, +x"),
    ((-(m.PAD_RELEASE_RESIDUAL + 1), 0), "one count outside the residual, -x"),
    # 🔴 THE CASE A PLAIN DEADBAND WOULD LOSE. A thumb aiming at the middle of
    # the keyboard half sits near dead centre with NEITHER axis on zero; at
    # +/-512 this reads as lifted and its click dies silently.
    ((300, -400), "a thumb aiming at the middle key, neither axis on zero"),
    ((-121, 300), "the failing lift's residual with a real y beside it"),
    ((1, 1), "one count out on BOTH axes"),
]
released_by_mistake = []
for (x, y), what in RESTING_SAMPLES:
    mm = osk_mapper()
    mm.translate(e.EV_ABS, e.ABS_HAT0X, x, 0.0)
    mm.translate(e.EV_ABS, e.ABS_HAT0Y, y, 0.0)
    if not mm.pad_touched("left"):
        released_by_mistake.append(what)
check("no plausible resting position reads as a lift", released_by_mistake, [])

# The boundary itself, from both sides. This is the whole difference between
# "exactly 0" and "near centre", and it sits at PAD_RELEASE_RESIDUAL exactly.
mm = osk_mapper()
mm.translate(e.EV_ABS, e.ABS_HAT0X, m.PAD_RELEASE_RESIDUAL, 0.0)
check("the residual's own value, with the other axis on 0, is a LIFT",
      mm.pad_touched("left"), False)
mm = osk_mapper()
mm.translate(e.EV_ABS, e.ABS_HAT0X, m.PAD_RELEASE_RESIDUAL + 1, 0.0)
check("...and one count further out is a touch", mm.pad_touched("left"), True)
mm = osk_mapper()
mm.translate(e.EV_ABS, e.ABS_HAT0X, m.PAD_RELEASE_RESIDUAL, 0.0)
mm.translate(e.EV_ABS, e.ABS_HAT0Y, m.PAD_RELEASE_RESIDUAL, 0.0)
check("BOTH axes inside the residual and NEITHER on zero is still a touch -- "
      "this is a residual, not a deadband", mm.pad_touched("left"), True)

# The value itself, bounded by what was measured rather than by what looks safe.
check("the residual clears the one measured 121-count shortfall",
      m.PAD_RELEASE_RESIDUAL > 121, True)
check("...and stays under 512, where the blind spot would be 1.6% of the axis",
      m.PAD_RELEASE_RESIDUAL < 512, True)

# ⚠️ THE WIDENED BLIND SPOT, pinned honestly rather than left to be discovered:
# a thumb resting exactly ON a centre line and within the residual of centre
# reads as lifted. That is the price of the fix and it is documented at
# PAD_TOUCH_AXES; it is a plus-sign of 1025 sample positions, where a plain
# +/-256 deadband would have blinded 263169.
mm = osk_mapper()
mm.translate(e.EV_ABS, e.ABS_HAT0X, 0, 0.0)
mm.translate(e.EV_ABS, e.ABS_HAT0Y, 200, 0.0)
check("a thumb ON the centre line within the residual reads as lifted "
      "(known, accepted, the price of the fix)", mm.pad_touched("left"), False)

# Per-pad, never shared: §9e's rule is that each trigger's badge is gated on its
# OWN side's pad, and the operator confirmed that on hardware.
mm = osk_mapper()
touch(mm, "left")
check("touching the left pad does not make the right pad touched",
      (mm.pad_touched("left"), mm.pad_touched("right")), (True, False))
touch(mm, "right")
check("and both can be touched at once",
      (mm.pad_touched("left"), mm.pad_touched("right")), (True, True))

check("an unknown half is an error, not a quiet False",
      isinstance(raised(lambda: osk_mapper().pad_touched("middle")), ValueError), True)

# --- 🔴 AND IT REACHES THE OVERLAY. This is the defect, not `pad_touched`. ---
#
# The wire protocol was extended to carry pad touch, the layout core's
# `hint_visible()` was taught to consume it -- and the mapper went on calling
# `format_state_line(osk, cursors)` with two arguments. Every frame told the
# overlay both pads were lifted, so no badge ever gated and neither cursor ever
# vanished, WHILE EVERY `pad_touched` TEST ABOVE STAYED GREEN. The state line
# is the entire contract between the two processes; assert on the line.

mm = osk_mapper()
check("both pads lifted serialise as `up up`",
      osk_mod.format_state_line(mm.osk, mm.cursors, mm.pad_touch_state())
      .split()[-2:], ["up", "up"])
touch(mm, "left")
check("a thumb on the left pad reaches the wire as `down up`",
      osk_mod.format_state_line(mm.osk, mm.cursors, mm.pad_touch_state())
      .split()[-2:], ["down", "up"])
touch(mm, "right")
check("...and both as `down down`",
      osk_mod.format_state_line(mm.osk, mm.cursors, mm.pad_touch_state())
      .split()[-2:], ["down", "down"])
check("the sides are not swapped -- right alone is `up down`",
      osk_mod.format_state_line(osk_mapper().osk, osk_mapper().cursors,
                                {"left": False, "right": True}).split()[-2:],
      ["up", "down"])

# End to end, through the parser the overlay actually uses, to the question the
# renderer actually asks. A mapper that reports touch and a badge rule that
# consumes it are worth nothing if the two do not meet.
mm = osk_mapper()
touch(mm, "left")
parsed = osk_mod.parse_state_line(
    osk_mod.format_state_line(mm.osk, mm.cursors, mm.pad_touch_state()))
far_kb, far_cur = osk_mod.OnScreenKeyboard(), osk_mod.Cursors()
osk_mod.apply_state(far_kb, far_cur, parsed)
check("the overlay ends up believing exactly what the mapper measured",
      far_kb.touched, {"left": True, "right": False})
gates = {half: [osk_mod.hint_visible(key, frozenset(
             h for h in ("left", "right") if far_kb.touched[h]))
         for row in far_kb.layer.rows for key in row if key.hint == hint]
         for half, hint in (("left", osk_mod.HINT_LEFT),
                            ("right", osk_mod.HINT_RIGHT))}
check("...so the L2 badges are hidden -- BOTH of them, on both Shift keys",
      (len(gates["left"]), any(gates["left"])), (2, False))
check("...and the R2 badge is not, because that pad is lifted",
      all(gates["right"]) and len(gates["right"]) > 0, True)

# A showing starts from a known state, or a sample left over from the last one
# decides the first frame's badges.
mm = osk_mapper()
touch(mm, "left")
mm.osk.caps = True
mm.osk.shift = "once"
mm.reset_osk_state()
check("reset_osk_state lifts both pads and clears both modifiers",
      (mm.pad_touched("left"), mm.osk_shift, mm.osk_caps), (False, False, False))

# --- L2/R2: TWO meanings each, chosen by that pad's touch state (§9g) --------

# TOUCHED -> commit, which is what they have always done.
mm = osk_mapper()
touch(mm, "left", MINV, MAXV)
expected = key_under(mm, "left")
check("L2 with the left pad TOUCHED commits the left cursor's key",
      mm.translate(e.EV_KEY, e.BTN_TL2, 1, 0.1), [(expected, 1), (expected, 0)])

# LIFTED -> Shift. No keycode: the modifier is applied inside the layout core
# when a character is committed.
mm = osk_mapper()
check("L2 with the left pad LIFTED emits no keycode",
      mm.translate(e.EV_KEY, e.BTN_TL2, 1, 0.0), [])
check("...it engages Shift instead", mm.osk_shift, True)
check("...and does NOT latch Caps -- Caps is L3's, and they are not the same",
      mm.osk_caps, False)

# --- 🔴 SHIFT IS MOMENTARY, NOT A TOGGLE (operator, 2026-08-12) --------------
#
# "the shift L2 button works but as an on/off. shift should only be engaged
# when i hold down l2 (as on a pc)". This REVERSES the one-shot decision that
# shipped, whose reasoning is answered in full at `Mapper.hold_osk_shift` --
# read that before simplifying any of this back.
#
# The release is the whole point, and it is the ONLY release the OSK path acts
# on: everything else here emits a complete tap on the press so that a keyboard
# dismissed mid-press cannot strand a key down.

mm = osk_mapper()
mm.translate(e.EV_KEY, e.BTN_TL2, 1, 0.0)
check("Shift is engaged while L2 is held", mm.osk_shift, True)
check("...and RELEASING L2 lets it go, which is the entire complaint",
      (mm.translate(e.EV_KEY, e.BTN_TL2, 0, 0.1), mm.osk_shift), ([], False))

# The mutation this catches is the old code verbatim: a toggle reads the same
# on one press and differs on the second.
mm = osk_mapper()
mm.translate(e.EV_KEY, e.BTN_TL2, 1, 0.0)
mm.translate(e.EV_KEY, e.BTN_TL2, 0, 0.1)
check("a SECOND press engages it again -- a toggle would have turned it off",
      (mm.translate(e.EV_KEY, e.BTN_TL2, 1, 0.2), mm.osk_shift), ([], True))
check("...and the second release lets go again",
      (mm.translate(e.EV_KEY, e.BTN_TL2, 0, 0.3), mm.osk_shift), ([], False))

# 🔴 NOT SPENT BY THE FIRST KEY. A one-shot dropped after one character, which
# is exactly what "hold to shift" must not do: on a PC the hold shifts every
# key struck during it. This is why the hold uses the layout core's "locked"
# rather than its "once".
mm = osk_mapper()
mm.translate(e.EV_ABS, e.ABS_HAT1X, MINV, 0.0)
mm.translate(e.EV_ABS, e.ABS_HAT1Y, -1, 0.0)      # a letter, right pad touched
mm.translate(e.EV_KEY, e.BTN_TL2, 1, 0.1)         # ...and L2 held for Shift
first = mm.translate(e.EV_KEY, e.BTN_TR2, 1, 0.2)
second = mm.translate(e.EV_KEY, e.BTN_TR2, 1, 0.3)
check("a key committed during the hold carries the shift modifier",
      first[0] if first else None, (osk_mod.SHIFT_CODE, 1))
check("...and so does the NEXT one -- the hold is not spent by one key",
      second[0] if second else None, (osk_mod.SHIFT_CODE, 1))
check("...and Shift is still engaged after both", mm.osk_shift, True)
check("...until L2 comes up",
      (mm.translate(e.EV_KEY, e.BTN_TL2, 0, 0.4), mm.osk_shift), ([], False))

# ⚠️ THE INTERACTION THE ONE-SHOT DESIGN WAS WORRIED ABOUT, pinned so it cannot
# be "simplified" into either of its wrong answers. With L2 held for Shift the
# user may still put a thumb on the LEFT pad -- the trigger that would commit
# it is the one already down. Nothing about that touch may disturb Shift: a
# modifier that evaporated when a thumb brushed a pad would type a lowercase
# letter while the user was visibly holding shift.
mm = osk_mapper()
mm.translate(e.EV_KEY, e.BTN_TL2, 1, 0.0)         # held, left pad lifted
touch(mm, "left", MINV, MAXV)                     # ...then a thumb lands on it
check("a thumb landing on the left pad mid-hold leaves Shift engaged",
      (mm.pad_touched("left"), mm.osk_shift), (True, True))
check("...and the release still lets go, though the pad is now TOUCHED -- the "
      "release is deliberately not gated the way the press is",
      (mm.translate(e.EV_KEY, e.BTN_TL2, 0, 0.1), mm.osk_shift), ([], False))

# The other order: a commit pull (pad touched) is not a Shift, and its release
# must not clear a Shift somebody else set.
mm = osk_mapper()
mm.osk.shift = "locked"                            # e.g. the on-screen Shift key
touch(mm, "left", MINV, MAXV)
mm.translate(e.EV_KEY, e.BTN_TL2, 1, 0.1)          # commits, does not hold Shift
check("a commit pull leaves the shift state alone",
      (mm.osk.shift, mm.osk_shift_prev), ("locked", None))
check("...and its release does not clear a lock it never set",
      (mm.translate(e.EV_KEY, e.BTN_TL2, 0, 0.2), mm.osk.shift), ([], "locked"))

# 🔴 THE HOLD RESTORES WHAT IT FOUND. The on-screen Shift key still cycles
# off -> once -> locked, and a trigger pull that silently cancelled a lock the
# user set there would be a second, invisible way to lose it.
for prior in ("off", "once", "locked"):
    mm = osk_mapper()
    mm.osk.shift = prior
    mm.translate(e.EV_KEY, e.BTN_TL2, 1, 0.0)
    check(f"L2 held over shift={prior!r} engages Shift", mm.osk_shift, True)
    check(f"...and releasing it puts {prior!r} back",
          (mm.translate(e.EV_KEY, e.BTN_TL2, 0, 0.1), mm.osk.shift), ([], prior))

# The pad's own autorepeat is not a second press. Letting one through would
# overwrite the saved state with the state the hold itself installed, and the
# release would then "restore" Shift to on -- the toggle, back by accident.
mm = osk_mapper()
mm.translate(e.EV_KEY, e.BTN_TL2, 1, 0.0)
mm.translate(e.EV_KEY, e.BTN_TL2, 2, 0.1)
mm.translate(e.EV_KEY, e.BTN_TL2, 2, 0.2)
check("an autorepeat during the hold does not corrupt what the release restores",
      (mm.osk_shift_prev, mm.osk_shift), ("off", True))
check("...so the release still lets go",
      (mm.translate(e.EV_KEY, e.BTN_TL2, 0, 0.3), mm.osk_shift), ([], False))

# ⚠️ Asked of the METHODS, because `_osk_event` filters the autorepeat above
# before it can get this far -- so the event path alone cannot see whether the
# hold is re-entrant, and a second press with no release in between (one lost
# while the keyboard was hidden, an autorepeat let through by some later edit)
# would save "locked" over the real state and "restore" Shift to ON. Belt and
# braces, and the braces are only visible from here.
mm = osk_mapper()
mm.osk.shift = "once"
mm.hold_osk_shift()
mm.hold_osk_shift()
check("a second hold does not overwrite what the first one saved",
      mm.osk_shift_prev, "once")
check("...so one release still puts the real state back",
      (mm.release_osk_shift(), mm.osk.shift), (None, "once"))
check("...and a second release is a no-op, not a second restore",
      (mm.release_osk_shift(), mm.osk.shift, mm.osk_shift_prev),
      (None, "once", None))

# A keyboard dismissed with L2 physically down never sees that release: the
# STEAM+X chord is handled ABOVE the OSK branch, and once hidden the release
# goes to the navigation profile. The next showing must not restore anything.
mm = osk_mapper()
mm.translate(e.EV_KEY, e.BTN_TL2, 1, 0.0)
mm.reset_osk_state()
check("reset_osk_state forgets a hold that was interrupted by a dismissal",
      (mm.osk_shift_prev, mm.osk.shift), (None, "off"))
mm.translate(e.EV_KEY, e.BTN_TL2, 0, 0.1)
check("...so the stray release that arrives afterwards changes nothing",
      mm.osk.shift, "off")

# R2 is unaffected by any of it: Enter is a complete tap on the press, and its
# release stays silent (a held Enter would repeat into whatever has focus).
mm = osk_mapper()
mm.translate(e.EV_KEY, e.BTN_TR2, 1, 0.0)
check("R2's release is still silent and still touches no modifier",
      (mm.translate(e.EV_KEY, e.BTN_TR2, 0, 0.1), mm.osk_shift, mm.osk.caps),
      ([], False, False))

# LIFTED -> Enter, on the right. A full tap: nothing can stay held.
mm = osk_mapper()
check("R2 with the right pad LIFTED types Enter",
      mm.translate(e.EV_KEY, e.BTN_TR2, 1, 0.0),
      [(e.KEY_ENTER, 1), (e.KEY_ENTER, 0)])
check("...and its release types nothing, so Enter cannot stick down",
      mm.translate(e.EV_KEY, e.BTN_TR2, 0, 0.1), [])
mm = osk_mapper()
touch(mm, "right", MAXV, MAXV)
committed = key_under(mm, "right")
check("R2 with the right pad TOUCHED commits instead of sending Enter",
      mm.translate(e.EV_KEY, e.BTN_TR2, 1, 0.1), [(committed, 1), (committed, 0)])
check("...and that really was NOT Enter", committed != e.KEY_ENTER, True)

# The gate is per-pad in both directions: a thumb on the LEFT pad must not turn
# R2 into a commit, and vice versa (§9e, answered by the operator 2026-08-12).
mm = osk_mapper()
touch(mm, "left")
check("the left pad being touched leaves R2 as Enter",
      mm.translate(e.EV_KEY, e.BTN_TR2, 1, 0.1),
      [(e.KEY_ENTER, 1), (e.KEY_ENTER, 0)])
mm = osk_mapper()
touch(mm, "right")
check("the right pad being touched leaves L2 as Shift",
      (mm.translate(e.EV_KEY, e.BTN_TL2, 1, 0.1), mm.osk_shift), ([], True))

# Lifting mid-session flips the meaning back, which is the badge reappearing.
mm = osk_mapper()
touch(mm, "left", MINV, MAXV)
mm.translate(e.EV_KEY, e.BTN_TL2, 1, 0.1)          # committed
mm.translate(e.EV_ABS, e.ABS_HAT0X, 0, 0.2)
mm.translate(e.EV_ABS, e.ABS_HAT0Y, 0, 0.2)        # ...thumb lifted
check("after a lift the SAME trigger is Shift again",
      (mm.translate(e.EV_KEY, e.BTN_TL2, 1, 0.3), mm.osk_shift), ([], True))

# --- 🔴 CLICKING A PAD COMMITS THAT PAD'S CURSOR (operator, 2026-08-12) ------
#
# *"when i press shift and then aim, i press harder on the trackpad and that's
# registered as a press"*. This is not a convenience: it is the half of
# hold-to-Shift the trigger cannot provide, because the trigger that would
# commit the LEFT cursor is the same trigger holding Shift. `PAD_CLICK_HALF`
# has the measurement and `Mapper.hold_osk_shift` the gesture.

check("the pad CLICKS are BTN_THUMB/BTN_THUMB2, never the stick clicks",
      m.PAD_CLICK_HALF, {e.BTN_THUMB: "left", e.BTN_THUMB2: "right"})
check("...so no pad click collides with the Caps binding",
      m.OSK_CAPS_BUTTON in m.PAD_CLICK_HALF, False)

# Each click commits its OWN side. The mutation this kills is the swap.
mm = osk_mapper()
touch(mm, "left", MINV, MAXV)      # left cursor -> top-left
touch(mm, "right", MAXV, MAXV)     # right cursor -> top-right
left_key, right_key = key_under(mm, "left"), key_under(mm, "right")
check("the two cursors are on different keys (or the checks below prove nothing)",
      left_key != right_key, True)
check("clicking the LEFT pad types the key under the LEFT cursor",
      mm.translate(e.EV_KEY, e.BTN_THUMB, 1, 0.1), [(left_key, 1), (left_key, 0)])
check("clicking the RIGHT pad types the key under the RIGHT cursor",
      mm.translate(e.EV_KEY, e.BTN_THUMB2, 1, 0.2),
      [(right_key, 1), (right_key, 0)])
check("a click RELEASE types nothing, so no key can stick down",
      (mm.translate(e.EV_KEY, e.BTN_THUMB, 0, 0.3),
       mm.translate(e.EV_KEY, e.BTN_THUMB2, 0, 0.4)), ([], []))
check("...and the pad's own autorepeat is not a second press",
      mm.translate(e.EV_KEY, e.BTN_THUMB, 2, 0.5), [])

# 🔴 THE WHOLE POINT: a click commits WITHOUT touching the trigger, so a Shift
# held on L2 is still held afterwards -- and still held for the NEXT key. The
# one-handed gesture the old design had to declare unreachable.
mm = osk_mapper()
mm.translate(e.EV_KEY, e.BTN_TL2, 1, 0.0)          # L2 held: Shift engaged
touch(mm, "left", MINV, -1)                        # aim the SAME hand's pad...
mm.cursors.pos["left"] = [0.5, 0.5]                # ...at a LETTER, which shifts
check("the left cursor is on a key that types (or this proves nothing)",
      bool(key_under(mm, "left")), True)
strokes = mm.translate(e.EV_KEY, e.BTN_THUMB, 1, 0.1)
check("a click under a held L2 commits WITH Shift engaged",
      strokes[0] if strokes else None, (osk_mod.SHIFT_CODE, 1))
check("...and Shift is STILL held afterwards -- the trigger never came up",
      mm.osk_shift, True)
second = mm.translate(e.EV_KEY, e.BTN_THUMB, 1, 0.2)
check("...so the next click is shifted too", second[0] if second else None,
      (osk_mod.SHIFT_CODE, 1))
check("...and only L2 coming up ends it",
      (mm.translate(e.EV_KEY, e.BTN_TL2, 0, 0.3), mm.osk_shift), ([], False))

# The same key, committed both ways, must produce the same strokes -- one
# emission path. Two paths would drift on shift, caps and the one-shot.
def committed_by(button, half, at=(0.5, 0.5)):
    mm = osk_mapper()
    mm.osk.shift = "once"          # so the ONE-SHOT's spending is compared too
    touch(mm, half, MINV, -1)
    mm.cursors.pos[half] = list(at)
    return (mm.translate(e.EV_KEY, button, 1, 0.1), mm.osk.shift)


check("a click and a trigger commit the same key identically, one-shot and all",
      committed_by(e.BTN_THUMB, "left"), committed_by(e.BTN_TL2, "left"))
check("...on the right side too",
      committed_by(e.BTN_THUMB2, "right"), committed_by(e.BTN_TR2, "right"))
check("...and that comparison is not two empty answers",
      bool(committed_by(e.BTN_THUMB, "left")[0]), True)

# ⚠️ A CLICK OVER A LIFTED PAD DOES NOTHING, where the trigger has a second
# meaning. Valve badges the triggers on Shift and Enter and badges the pad
# clicks on nothing, so an idle meaning here would be behaviour the keyboard
# never advertises -- and an untouched pad draws no cursor to commit.
mm = osk_mapper()
check("clicking a LIFTED left pad types nothing",
      mm.translate(e.EV_KEY, e.BTN_THUMB, 1, 0.0), [])
check("...and does not engage Shift the way the trigger would",
      (mm.osk_shift, mm.osk_caps), (False, False))
mm = osk_mapper()
check("clicking a LIFTED right pad types nothing -- no Enter either",
      mm.translate(e.EV_KEY, e.BTN_THUMB2, 1, 0.0), [])

# Per-pad in both directions, like the triggers: the other pad's thumb must not
# arm this pad's click.
mm = osk_mapper()
touch(mm, "right", MAXV, MAXV)
check("a thumb on the RIGHT pad does not make the LEFT click commit",
      mm.translate(e.EV_KEY, e.BTN_THUMB, 1, 0.1), [])
check("...while the right click, on the touched pad, does",
      bool(mm.translate(e.EV_KEY, e.BTN_THUMB2, 1, 0.2)), True)

# A click on a state key is a real press with no keycode, exactly as the
# trigger's would be -- not a silent nothing.
mm = osk_mapper()
touch(mm, "left", MINV, MAXV)
mm.cursors.pos["left"] = [0.05, 0.75]              # the left Shift key
check("clicking the on-screen Shift key emits nothing and arms the one-shot",
      (mm.translate(e.EV_KEY, e.BTN_THUMB, 1, 0.1), mm.osk.shift), ([], "once"))

# With the keyboard DOWN the LEFT pad click is still nobody's business: it is
# not in BUTTON_MAP and must not become a mouse button by accident.
#
# ⚠️ THE RIGHT ONE IS NO LONGER SILENT HERE, and this comment is the record of
# the change rather than a deletion. Since the operator's 2026-08-12 request the
# right pad's click is the LEFT MOUSE BUTTON while the keyboard is down; it has
# its own section further down, and the left pad deliberately did NOT get a
# binding alongside it.
mm = fresh()
check("with the OSK down the left pad click emits nothing",
      mm.translate(e.EV_KEY, e.BTN_THUMB, 1, 0.0), [])
check("...and its release emits nothing either -- it was never bound",
      mm.translate(e.EV_KEY, e.BTN_THUMB, 0, 0.1), [])

# --- 🆕 AND THE CLICK BUZZES (operator, 2026-08-12) -------------------------
#
# *"on the steam deck when i pad click it gives me some haptic feedback to feel
# like i pressed the trackpad"*. The trackpads have no key travel, so on a
# keyboard reached only by pointing the buzz IS the press confirmation.
#
# The interface, established by inspecting the machine rather than recalled:
# there is no haptic sysfs node and no LED-class node; what exists is EV_FF on
# the SAME evdev node this process already reads, advertising FF_RUMBLE with 16
# effect slots, and hid-steam's `steam_play_effect` forwards the two rumble
# magnitudes to ID_TRIGGER_RUMBLE_CMD. See `PAD_HAPTIC_MAGNITUDES`.
#
# 🔴 EVERY TEST HERE IS ALSO A FAIL-SOFT TEST. With lizard_mode=N this process
# is the only input path on the device, so a haptics fault must cost the buzz
# and nothing else -- never the commit, never the pointer, never the process.

import evdev.ff as real_ff        # noqa: E402 -- the real structs, not a stub


class FakeFFDevice:
    """An evdev node that records what was uploaded and played.

    Real `evdev.ff` structs go in, so a wrong field name or a swapped argument
    fails here rather than on hardware.
    """

    def __init__(self, caps=(e.FF_RUMBLE,), upload_error=None, write_error=None):
        self.path = "/dev/input/fake"
        self.caps = list(caps)
        self.upload_error = upload_error
        self.write_error = write_error
        self.uploaded: list = []      # the ff.Effect objects, in order
        self.by_id: dict = {}         # effect id -> the effect uploaded under it
        self.played: list = []        # (code, value) written as EV_FF
        self.erased: list = []
        self.next_id = 40

    def capabilities(self):
        return {e.EV_ABS: [], e.EV_FF: self.caps}

    def upload_effect(self, effect):
        if self.upload_error is not None and len(self.uploaded) >= self.upload_error:
            raise OSError(22, "Invalid argument")
        self.uploaded.append(effect)
        self.next_id += 1
        self.by_id[self.next_id] = effect
        return self.next_id

    def write(self, etype, code, value):
        if self.write_error:
            raise OSError(19, "No such device")
        if etype != e.EV_FF:
            raise AssertionError(f"haptics wrote EV type {etype}, not EV_FF")
        self.played.append((code, value))

    def erase_effect(self, effect_id):
        self.erased.append(effect_id)


def rumble_of(dev, effect_id):
    """(strong, weak) as they were actually uploaded under that effect id."""
    rumble = dev.by_id[effect_id].u.ff_rumble_effect
    return (rumble.strong_magnitude, rumble.weak_magnitude)


class Recorder:
    """A `Haptics` stand-in for the wiring tests: records halves, never buzzes."""

    def __init__(self):
        self.buzzed: list[str] = []

    def buzz(self, half):
        self.buzzed.append(half)
        return True


def said(log):
    return " ".join(log)


check("the magnitudes are per pad, one actuator each, strong then weak",
      m.PAD_HAPTIC_MAGNITUDES,
      {"left": (m.PAD_HAPTIC_MAGNITUDE, 0), "right": (0, m.PAD_HAPTIC_MAGNITUDE)})
check("...and the two halves do not both drive the same actuator",
      m.PAD_HAPTIC_MAGNITUDES["left"] != m.PAD_HAPTIC_MAGNITUDES["right"], True)
check("the pulse is a click, not a rumble: well under a tenth of a second",
      0 < m.PAD_HAPTIC_MS <= 100, True)
check("...and long enough to survive CONFIG_HZ=300's 3.3ms jiffy",
      m.PAD_HAPTIC_MS >= 10, True)

# --- 🆕 THE TOUCH TICK (operator, 2026-08-16) -------------------------------
#
# *"when touching the osk to type, the deck should vibrate very slightly (as the
# real deck does)"*. A finger on the glass has no side, so this one effect
# drives BOTH actuators, and it is its own slot so that its feel can be tuned
# without touching the pad click's.
#
# ⛔ NOT ONE ASSERTION ON HOW STRONG OR HOW LONG IT IS, DELIBERATELY. Only the
# operator's hands can set that (PAD_HAPTIC_MS says the same of the click), and
# a suite that pinned a magnitude would go red the first time it is tuned --
# this repo's most-repeated defect, a test pinning a value it does not own.
# What is pinned is the STRUCTURE: its own slot, both actuators, one effect
# uploaded, one play per touch, given back on close.
check("the touch tick is a slot of its own, not one of the pad halves",
      m.OSK_TOUCH_HAPTIC_SLOT in m.PAD_HAPTIC_MAGNITUDES, False)
check("every slot the code can buzz is one start() uploads",
      sorted(m.HAPTIC_EFFECTS),
      sorted([*m.PAD_HAPTIC_MAGNITUDES, m.OSK_TOUCH_HAPTIC_SLOT]))
check("...each pad half keeping exactly the magnitudes measured for it",
      {half: (strong, weak)
       for half, (strong, weak, _) in m.HAPTIC_EFFECTS.items()
       if half in m.PAD_HAPTIC_MAGNITUDES},
      dict(m.PAD_HAPTIC_MAGNITUDES))
touch_strong, touch_weak, touch_ms = m.HAPTIC_EFFECTS[m.OSK_TOUCH_HAPTIC_SLOT]
check("...and the touch tick driving BOTH actuators, a finger having no side",
      (touch_strong > 0, touch_strong == touch_weak), (True, True))
check("the tick is inside the FF API's 0..0xFFFF -- the range the API owns",
      0 < touch_strong <= 0xFFFF, True)
check("...and is a tick, not a rumble, and clears the 3.3ms jiffy",
      10 <= touch_ms <= 100, True)

# --- start(): one effect per slot, uploaded once, with its own magnitudes ----
dev, log = FakeFFDevice(), []
h = m.Haptics(dev, ff_module=real_ff, log=log.append)
check("start() arms", (h.start(), h.enabled), (True, True))
check("...uploading exactly one effect per slot, and no more",
      len(dev.uploaded), len(m.HAPTIC_EFFECTS))
check("...as FF_RUMBLE effects, each of its own slot's length",
      sorted({(f.type, f.ff_replay.length) for f in dev.uploaded}),
      sorted({(e.FF_RUMBLE, length) for _, _, length in m.HAPTIC_EFFECTS.values()}))
# 🔴 BY EFFECT ID, not by upload order. This is what makes the buzz tests below
# mean something: the slot `buzz("left")` plays is the slot the LEFT pad's
# magnitudes went into, so a swap anywhere between the constant and the ioctl
# lands here.
check("...carrying each slot's own magnitudes, under that slot's own id",
      {slot: rumble_of(dev, effect_id) for slot, effect_id in h.effects.items()},
      {slot: (strong, weak) for slot, (strong, weak, _) in m.HAPTIC_EFFECTS.items()})
check("...and saying nothing, because nothing went wrong", log, [])

# --- buzz(): the right slot, on the right side ------------------------------
check("buzzing the left pad plays the LEFT effect",
      (h.buzz("left"), dev.played), (True, [(h.effects["left"], 1)]))
dev.played.clear()
check("buzzing the right pad plays the RIGHT one -- the sides are not swapped",
      (h.buzz("right"), dev.played), (True, [(h.effects["right"], 1)]))
check("the two slots really are different", h.effects["left"] != h.effects["right"], True)
dev.played.clear()
check("buzzing the touch slot plays the TOUCH effect, once, not a pad's",
      (h.buzz(m.OSK_TOUCH_HAPTIC_SLOT), dev.played),
      (True, [(h.effects[m.OSK_TOUCH_HAPTIC_SLOT], 1)]))
check("...and it is a third slot, neither pad's",
      h.effects[m.OSK_TOUCH_HAPTIC_SLOT] in (h.effects["left"], h.effects["right"]),
      False)
check("an unknown half buzzes nothing rather than raising", h.buzz("middle"), False)
armed_slots = sorted(h.effects.values())
h.close()
check("close() hands both slots back, and disarms",
      (sorted(dev.erased), h.enabled), (armed_slots, False))
check("...and a closed Haptics buzzes nothing", h.buzz("left"), False)
h.close()
check("...and closing twice erases nothing a second time -- it is idempotent",
      sorted(dev.erased), armed_slots)

# --- fail-soft, every way it can fail ---------------------------------------
dev, log = FakeFFDevice(caps=()), []
h = m.Haptics(dev, ff_module=real_ff, log=log.append)
check("a node with no FF_RUMBLE does not arm", (h.start(), h.enabled), (False, False))
check("...and SAYS so, naming what is lost and what is not",
      ("FF_RUMBLE" in said(log) and "SILENTLY" in said(log)
       and "unaffected" in said(log)), True)
check("...and uploads nothing to it", dev.uploaded, [])
check("...and buzzing it is a quiet False, not an exception", h.buzz("left"), False)

dev, log = FakeFFDevice(), []
h = m.Haptics(dev, ff_module=None, log=log.append)
check("no evdev.ff at all does not arm, and says why",
      (h.start(), "evdev.ff" in said(log)), (False, True))

# 🔴 A HALF-ARMED HAPTICS IS WORSE THAN NONE: one pad buzzing and the other not
# reads as "the right pad's click is broken".
dev, log = FakeFFDevice(upload_error=1), []
h = m.Haptics(dev, ff_module=real_ff, log=log.append)
check("an upload that fails half way does not arm", (h.start(), h.enabled), (False, False))
check("...and gives back the slot that DID upload", len(dev.erased), 1)
check("...and says which pad failed and that the rest still works",
      ("SILENTLY" in said(log) and "unaffected" in said(log)), True)
check("...and buzzes nothing afterwards", h.buzz("left"), False)

dev, log = FakeFFDevice(), []
h = m.Haptics(dev, ff_module=real_ff, log=log.append)
h.start()
dev.write_error = True
check("a write that fails is a False, never an exception", h.buzz("left"), False)
check("...said ONCE -- a line per click at 250Hz would bury the journal",
      len(log), 1)
check("...and it disables itself rather than repeating",
      (h.buzz("left"), h.buzz("right"), len(log)), (False, False, 1))

# --- the wiring: which press buzzes, and which does not ---------------------
check("a Mapper with no haptics at all is the default",
      m.Mapper().haptics, None)
mm = osk_mapper()
touch(mm, "left", MINV, MAXV)
check("...and a pad click still commits without one",
      bool(mm.translate(e.EV_KEY, e.BTN_THUMB, 1, 0.1)), True)

mm, rec = osk_mapper(), Recorder()
mm.haptics = rec
touch(mm, "left", MINV, MAXV)
touch(mm, "right", MAXV, MAXV)
check("clicking the LEFT pad buzzes the LEFT pad, and commits",
      (bool(mm.translate(e.EV_KEY, e.BTN_THUMB, 1, 0.1)), rec.buzzed), (True, ["left"]))
check("clicking the RIGHT pad buzzes the RIGHT one -- not swapped, not both",
      (bool(mm.translate(e.EV_KEY, e.BTN_THUMB2, 1, 0.2)), rec.buzzed),
      (True, ["left", "right"]))
check("a click RELEASE buzzes nothing -- one buzz per press",
      (mm.translate(e.EV_KEY, e.BTN_THUMB, 0, 0.3), rec.buzzed),
      ([], ["left", "right"]))
check("...and neither does the pad's autorepeat",
      (mm.translate(e.EV_KEY, e.BTN_THUMB, 2, 0.4), rec.buzzed),
      ([], ["left", "right"]))

# ⚠️ A click over a LIFTED pad commits nothing, so it must not buzz either: a
# buzz there announces a keypress that never happened.
mm, rec = osk_mapper(), Recorder()
mm.haptics = rec
check("clicking a LIFTED pad neither commits nor buzzes",
      (mm.translate(e.EV_KEY, e.BTN_THUMB, 1, 0.0), rec.buzzed), ([], []))

# 🔴 THE TRIGGERS DO NOT BUZZ, DELIBERATELY. L2/R2 are switches with real
# travel; the finger already knows. The pad has none, which is the operator's
# own reason for asking.
mm, rec = osk_mapper(), Recorder()
mm.haptics = rec
touch(mm, "left", MINV, MAXV)
check("committing with the TRIGGER does not buzz",
      (bool(mm.translate(e.EV_KEY, e.BTN_TL2, 1, 0.1)), rec.buzzed), (True, []))
check("...and neither does commit_at on its own -- the buzz is a separate call",
      (bool(mm.commit_at("left")), rec.buzzed), (True, []))

# A commit that types nothing is still a commit. Shift and Caps have no other
# feedback at all, so gating the buzz on emissions would go quiet on exactly
# the two keys that need it most.
mm, rec = osk_mapper(), Recorder()
mm.haptics = rec
touch(mm, "left", MINV, MAXV)
mm.cursors.pos["left"] = [0.05, 0.75]              # the left Shift key
check("clicking a key that TYPES NOTHING still buzzes",
      (mm.translate(e.EV_KEY, e.BTN_THUMB, 1, 0.1), mm.osk.shift, rec.buzzed),
      ([], "once", ["left"]))

# --- 🆕 AND A KEY TOUCHED ON THE GLASS TICKS TOO (operator, 2026-08-16) ------
#
# *"when touching the osk to type, the deck should vibrate very slightly"*. The
# pad click's buzz never depended on which backend was drawing -- it hangs off
# `_osk_event`, which never asks. What buzzed nothing was `press_key_index`,
# the TOUCH path, which only the `layer` overlay feeds; that is where the
# operator met the silence.
mm, rec = osk_mapper(), Recorder()
mm.haptics = rec
touch_rows = mm.osk.layer.rows
letter_index = next((r, k) for r, row in enumerate(touch_rows)
                    for k, key in enumerate(row) if key.is_letter)
check("a touch on a letter types it AND ticks, exactly once",
      (bool(mm.press_key_index(*letter_index)), rec.buzzed),
      (True, [m.OSK_TOUCH_HAPTIC_SLOT]))
check("...and the next key ticks again -- one per key, not one per showing",
      (bool(mm.press_key_index(*letter_index)), len(rec.buzzed)), (True, 2))

# Shift and Caps type nothing at all, so the tick is their ONLY confirmation --
# the same reason the pad click's buzz is not gated on emissions.
mm, rec = osk_mapper(), Recorder()
mm.haptics = rec
shift_touch = next((r, k) for r, row in enumerate(touch_rows)
                   for k, key in enumerate(row) if key.action == "shift")
check("touching a key that TYPES NOTHING still ticks",
      (mm.press_key_index(*shift_touch), rec.buzzed),
      ([], [m.OSK_TOUCH_HAPTIC_SLOT]))

# ⛔ AN INDEX THIS KEYBOARD DOES NOT HAVE TICKS NOTHING. `None` is reserved for
# the overlay and this process disagreeing about the layout, and a tick there
# would announce, through the palms, a keystroke that nothing typed.
mm, rec = osk_mapper(), Recorder()
mm.haptics = rec
check("an off-layout index neither types nor ticks",
      (mm.press_key_index(len(touch_rows), 0), mm.press_key_index(0, -1), rec.buzzed),
      (None, None, []))
mm = m.Mapper()
mm.haptics = rec
check("...and neither does a touch at a mapper with no keyboard attached",
      (mm.press_key_index(0, 0), rec.buzzed), (None, []))

# 🔴 AND A DEAD ACTUATOR COSTS THE TICK, NOT THE TYPING -- end to end through
# the real class, exactly as the pad click's fail-soft test below does it.
dev, log = FakeFFDevice(), []
mm = osk_mapper()
mm.haptics = m.Haptics(dev, ff_module=real_ff, log=log.append)
mm.haptics.start()
dev.write_error = True
touched_key = mm.osk.layer.rows[letter_index[0]][letter_index[1]]
check("a dead actuator costs the tick and NOT the touched keystroke",
      mm.press_key_index(*letter_index),
      [(touched_key.code, 1), (touched_key.code, 0)])
check("...having said so, once", len(log), 1)
mm.haptics.close()

# --- 🔴 A BUZZ THAT THROWS MUST NOT TAKE THE INPUT PATH DOWN ----------------
#
# End to end through the real class, with the device failing underneath it: the
# click still types, because with lizard_mode=N there is nothing else to type
# with.
dev, log = FakeFFDevice(), []
mm = osk_mapper()
mm.haptics = m.Haptics(dev, ff_module=real_ff, log=log.append)
mm.haptics.start()
dev.write_error = True
touch(mm, "left", MINV, MAXV)
expected = key_under(mm, "left")
check("a dead actuator costs the buzz and NOT the keystroke",
      mm.translate(e.EV_KEY, e.BTN_THUMB, 1, 0.1), [(expected, 1), (expected, 0)])
check("...having said so, once", len(log), 1)

# --- main() wires it up, and re-wires it when the pad re-enumerates ---------
#
# ⚠️ The effect ids belong to the node they were uploaded to. §5.9's ENODEV
# path swaps that node out; a Haptics carried across it writes to a dead slot
# and the keyboard is silent for the rest of the session.
import ast as _ast  # noqa: E402 -- local to this block, like the imports above

main_def = next(
    node for node in _ast.walk(
        _ast.parse((REPO_ROOT / "src" / "deck-input-mapper.py").read_text()))
    if isinstance(node, _ast.FunctionDef) and node.name == "main")
arm_calls = [node for node in _ast.walk(main_def)
             if isinstance(node, _ast.Call) and isinstance(node.func, _ast.Name)
             and node.func.id == "arm_haptics"]
check("main() arms haptics at startup AND again after a re-enumeration",
      len(arm_calls), 2)
# ⚠️ `mapper.haptics.close()` SPECIFICALLY, and counted. `close` alone matches
# the uinput device and the overlay's stream, so a bare name check here passed
# with both of these deleted -- it was a mutation survivor before it was this.
# Two: once before rebinding to a replacement node, once on the way out.
closes = [node for node in _ast.walk(main_def)
          if isinstance(node, _ast.Call) and isinstance(node.func, _ast.Attribute)
          and node.func.attr == "close"
          and isinstance(node.func.value, _ast.Attribute)
          and node.func.value.attr == "haptics"]
check("...closing the dead node's effects before rebinding, AND on the way out",
      len(closes), 2)
# ⚠️ And guarded on there BEING haptics. `if False:` in front of either one
# leaves the call in the tree and survived the count above -- so the guard is
# checked too, and checked for mentioning `haptics` rather than for existing.
guarded = [node for node in _ast.walk(main_def)
           if isinstance(node, _ast.If)
           and any(sub in closes for sub in _ast.walk(node))
           and any(isinstance(sub, _ast.Attribute) and sub.attr == "haptics"
                   for sub in _ast.walk(node.test))]
check("...each behind a real `mapper.haptics is not None`, not a constant",
      len(guarded), 2)
arm_def = next(node for node in _ast.walk(main_def)
               if isinstance(node, _ast.FunctionDef) and node.name == "arm_haptics")
check("--dry-run arms no haptics: a buzz is an emission a user would FEEL",
      any(isinstance(node, _ast.Attribute) and node.attr == "dry_run"
          for node in _ast.walk(arm_def)), True)

# --- 🆕 THE RIGHT PAD'S CLICK IS THE LEFT MOUSE BUTTON (operator, 2026-08-12) -
#
# *"i should be able to click now with the right trackpad by pressing down (and
# getting a haptic response) this is the same as what we did for the keyboard
# but for the mouse"*. The right pad has driven the pointer for two sessions;
# pressing it reached nothing, so the only click was R2 -- the other finger on
# the same hand that is doing the pointing.
#
# 🔴 `osk_active` IS THE WHOLE CONDITION, AND BOTH SIDES ARE ASSERTED HERE. The
# same physical switch commits the highlighted key while the keyboard is up
# (the section above; verified on the panel by the operator) and is the left
# mouse button while it is down. A suite that only covered the pointer case
# would let the keyboard's commit be eaten with nothing going red -- so every
# claim below has a partner on the other side of the gate.

# --- which button, and the one-letter mistakes it must not be ----------------
check("the mouse click is the RIGHT pad's click, as PAD_CLICK_HALF measured it",
      m.POINTER_CLICK_BUTTON, e.BTN_THUMB2)
check("...and NOT either STICK click -- BTN_THUMBR is one letter away",
      m.POINTER_CLICK_BUTTON in (e.BTN_THUMBL, e.BTN_THUMBR), False)
check("...nor the Caps binding, nor the LEFT pad's click",
      (m.POINTER_CLICK_BUTTON == m.OSK_CAPS_BUTTON,
       m.POINTER_CLICK_BUTTON == e.BTN_THUMB), (False, False))
# 🔴 DERIVED, so the mouse click and the keyboard's commit are the same switch
# on the same side by construction. Asserting the literal alone would let the
# two drift the moment the measurement was corrected in one place.
check("...and it is derived FROM that table, not spelled a second time",
      m.PAD_CLICK_HALF[m.POINTER_CLICK_BUTTON], m.POINTER_CLICK_HALF)
check("the half it clicks is the half the POINTER itself reads",
      {m.PAD_TOUCH_AXES[code][0] for code in m.POINTER_AXES}, {m.POINTER_CLICK_HALF})
check("and what it emits is a real mouse button", m.POINTER_CLICK_KEY, e.BTN_LEFT)
check("...declared on the uinput device, or the kernel drops it in silence",
      m.POINTER_CLICK_KEY in m.EMITTED_KEYS, True)

# --- a press and a release, never a synthesised tap --------------------------
mm = fresh()
check("with the keyboard DOWN, pressing the right pad presses the left button",
      mm.translate(e.EV_KEY, e.BTN_THUMB2, 1, 0.0), [(e.BTN_LEFT, 1)])
check("...and the release lets go", mm.translate(e.EV_KEY, e.BTN_THUMB2, 0, 0.1),
      [(e.BTN_LEFT, 0)])
check("...leaving nothing held", mm.pad_click_down, False)
check("the pad's own autorepeat is not a second click",
      mm.translate(e.EV_KEY, e.BTN_THUMB2, 2, 0.2), [])

# 🔴 THE PAIRING, PROVED OVER A DRAG rather than one event at a time. A press
# that emitted (down, up) together passes both checks above if they are read as
# "a click happened"; it cannot pass this one, because the button has to still
# be DOWN while the pointer moves. Drag, text selection and press-and-hold are
# all this assertion.
mm = fresh()
down = mm.translate(e.EV_KEY, e.BTN_THUMB2, 1, 0.0)
mm.pointer_delta(e.ABS_HAT1X, 1000, 0.10)
moved = mm.pointer_delta(e.ABS_HAT1X, 3000, 0.15)
still_down = mm.pad_click_down
up = mm.translate(e.EV_KEY, e.BTN_THUMB2, 0, 0.2)
check("a drag: down, real pointer motion with the button STILL held, then up",
      (down, moved != (0, 0), still_down, up),
      ([(e.BTN_LEFT, 1)], True, True, [(e.BTN_LEFT, 0)]))

# ⚠️ NOT GATED ON `pad_touched`, where the keyboard's commit IS. An untouched
# pad draws no cursor to commit, but the POINTER is always somewhere, so a click
# always has a target -- and gating would hand the documented dead-centre blind
# spot the power to swallow a click.
mm = fresh()
check("a click over a pad reading LIFTED still clicks (the pointer is somewhere)",
      (mm.pad_touched("right"), mm.translate(e.EV_KEY, e.BTN_THUMB2, 1, 0.0)),
      (False, [(e.BTN_LEFT, 1)]))

# --- the other side of the gate: the keyboard's commit is untouched ----------
mm = osk_mapper()
touch(mm, "right", MAXV, MAXV)
expected = key_under(mm, "right")
strokes = mm.translate(e.EV_KEY, e.BTN_THUMB2, 1, 0.1)
check("with the keyboard UP the same click still commits the highlighted key",
      strokes, [(expected, 1), (expected, 0)])
check("...and that key is not a mouse button", expected in (e.BTN_LEFT, e.BTN_RIGHT), False)
check("...no mouse button went out underneath it",
      [stroke for stroke in strokes if stroke[0] == e.BTN_LEFT], [])
check("...and nothing was left holding one", mm.pad_click_down, False)

# 🔴 THE KEYBOARD OPENING MID-CLICK. STEAM+X is handled above the OSK branch, so
# a thumb still pressing the pad through the chord is exactly this sequence.
# Routed into `_osk_event` the release is swallowed and BTN_LEFT stays down at
# the kernel for ever: every later movement a drag, every later click a no-op.
mm = fresh()
check("a click that starts with the keyboard down goes down",
      mm.translate(e.EV_KEY, e.BTN_THUMB2, 1, 0.0), [(e.BTN_LEFT, 1)])
mm.osk = osk_mod.OnScreenKeyboard()
mm.cursors = osk_mod.Cursors()
mm.osk_active = True
check("...and its release still lets go after the keyboard opened over it",
      mm.translate(e.EV_KEY, e.BTN_THUMB2, 0, 0.1), [(e.BTN_LEFT, 0)])
check("...and the keyboard did not also see it as a commit", mm.osk.shift, "off")

# The same door in the other direction: a click that COMMITTED A KEY must not
# leave an unpaired mouse-button UP behind when the keyboard closes under it.
mm = osk_mapper()
touch(mm, "right", MAXV, MAXV)
mm.translate(e.EV_KEY, e.BTN_THUMB2, 1, 0.1)          # committed a key
mm.osk_active = False
check("a release left over from a keyboard commit does not click the desktop",
      mm.translate(e.EV_KEY, e.BTN_THUMB2, 0, 0.2), [])
check("a stray release with no press behind it invents no UP either",
      fresh().translate(e.EV_KEY, e.BTN_THUMB2, 0, 0.0), [])
# One down, one up: a repeated press cannot stack a second BTN_LEFT down.
mm = fresh()
mm.translate(e.EV_KEY, e.BTN_THUMB2, 1, 0.0)
check("a duplicate press sends no second down",
      mm.translate(e.EV_KEY, e.BTN_THUMB2, 1, 0.1), [])

# ⛔ SCOPE: THE RIGHT PAD ONLY. The operator asked for the pad that carries the
# pointer. A binding invented for the left pad would be a control nothing
# advertises -- §9a's rule applied to a button instead of a badge.
mm, rec = fresh(), Recorder()
mm.haptics = rec
check("the LEFT pad's click is still unbound with the keyboard down",
      (mm.translate(e.EV_KEY, e.BTN_THUMB, 1, 0.0),
       mm.translate(e.EV_KEY, e.BTN_THUMB, 0, 0.1)), ([], []))
check("...and buzzes nothing, because nothing happened", rec.buzzed, [])

# --- the buzz: on the PRESS, once, on the right pad --------------------------
mm, rec = fresh(), Recorder()
mm.haptics = rec
check("the mouse click buzzes the RIGHT pad on the press",
      (mm.translate(e.EV_KEY, e.BTN_THUMB2, 1, 0.0), rec.buzzed),
      ([(e.BTN_LEFT, 1)], ["right"]))
check("...and the RELEASE does not buzz again -- one buzz per press, as the OSK's is",
      (mm.translate(e.EV_KEY, e.BTN_THUMB2, 0, 0.1), rec.buzzed),
      ([(e.BTN_LEFT, 0)], ["right"]))
check("...nor does the autorepeat",
      (mm.translate(e.EV_KEY, e.BTN_THUMB2, 2, 0.2), rec.buzzed), ([], ["right"]))
# The trigger keeps its own rule: L2/R2 are switches with travel, and the finger
# already knows they went down.
mm, rec = fresh(), Recorder()
mm.haptics = rec
check("R2's left click still does not buzz -- only the pad, which has no travel",
      (mm.translate(e.EV_KEY, e.BTN_TR2, 1, 0.0), rec.buzzed),
      ([(e.BTN_LEFT, 1)], []))

# --- 🔴 A HAPTIC THAT IS MISSING OR FAILING MUST NEVER SWALLOW THE CLICK ------
#
# Haptics are best-effort on hardware that may advertise no FF_RUMBLE at all. A
# click that silently did not happen because a buzz failed is precisely the
# failure class CLAUDE.md exists to forbid.
mm = fresh()
check("a Mapper with NO haptics still clicks, and still lets go",
      (mm.haptics, mm.translate(e.EV_KEY, e.BTN_THUMB2, 1, 0.0),
       mm.translate(e.EV_KEY, e.BTN_THUMB2, 0, 0.1)),
      (None, [(e.BTN_LEFT, 1)], [(e.BTN_LEFT, 0)]))

dev, log = FakeFFDevice(), []
mm = fresh()
mm.haptics = m.Haptics(dev, ff_module=real_ff, log=log.append)
mm.haptics.start()
dev.write_error = True
check("a dead actuator costs the buzz and NOT the click",
      mm.translate(e.EV_KEY, e.BTN_THUMB2, 1, 0.0), [(e.BTN_LEFT, 1)])
check("...nor the release", mm.translate(e.EV_KEY, e.BTN_THUMB2, 0, 0.1),
      [(e.BTN_LEFT, 0)])
check("...having said so, once", len(log), 1)

dev, log = FakeFFDevice(caps=()), []
mm = fresh()
mm.haptics = m.Haptics(dev, ff_module=real_ff, log=log.append)
check("a node advertising no FF_RUMBLE never arms...", mm.haptics.start(), False)
check("...and the click goes out anyway",
      mm.translate(e.EV_KEY, e.BTN_THUMB2, 1, 0.0), [(e.BTN_LEFT, 1)])

# --- the one release that never arrives: the pad's node vanishing ------------
#
# Every other lost release is caught inside `translate`. A node that is GONE
# sends nothing at all, so main() has to hand the button back on its behalf --
# or the replacement pad arrives with BTN_LEFT still down at the kernel.
mm = fresh()
mm.translate(e.EV_KEY, e.BTN_THUMB2, 1, 0.0)
check("release_pointer_click gives back a button the dead node was holding",
      mm.release_pointer_click(), [(e.BTN_LEFT, 0)])
check("...once, and then it is empty -- idempotent",
      (mm.release_pointer_click(), mm.pad_click_down), ([], False))
check("...and a mapper holding nothing gives back nothing",
      fresh().release_pointer_click(), [])

# ⚠️ AND main() CALLS IT ON THE ENODEV PATH SPECIFICALLY. A call anywhere else
# in main() would pass a bare name check while the recovery path stayed broken,
# so this asks for it inside an `except` handler.
drain_calls = [node for node in _ast.walk(main_def)
               if isinstance(node, _ast.Call) and isinstance(node.func, _ast.Attribute)
               and node.func.attr == "release_pointer_click"]
check("main() drains a held mouse button when the pad disappears", len(drain_calls), 1)
check("...from inside the ENODEV handler, not from somewhere else in the loop",
      any(sub in drain_calls
          for handler in _ast.walk(main_def) if isinstance(handler, _ast.ExceptHandler)
          for sub in _ast.walk(handler)), True)

# --- 🔴 A COMMIT HIT-TESTS IN THE METRIC THE RENDERER DREW IN ---------------
#
# A key carries two widths and they are not redundant: `cells` is the integer
# addressing grid `deck_osk_tty` draws, `units` is the measured visual width
# `deck_osk_wayland` draws. They differ by up to half a key INSIDE a half, so a
# commit resolved in the wrong one types a key the user is not pointing at while
# the correct key is drawn white -- §9a's confidently wrong, arriving through
# the commit instead of through a badge. `press_at` hard-codes the layout core's
# default, which is why `Mapper.commit_at` exists at all.

check("the default metric is the layout core's own -- the tty renderer's",
      m.Mapper().osk_metric, osk_mod.CELLS)

# The two metrics must actually disagree somewhere, or nothing below is a test.
DISAGREE = [(half, x, y)
            for half in ("left", "right")
            for x in (i / 100 for i in range(101))
            for y in (0.1, 0.3, 0.5, 0.7, 0.9)
            if osk_mod.key_at(osk_mod.LETTERS, half, x, y, osk_mod.UNITS)
            is not osk_mod.key_at(osk_mod.LETTERS, half, x, y, osk_mod.CELLS)]
check("the two metrics really do disagree, on hundreds of cursor positions",
      len(DISAGREE) > 100, True)

for button, half in ((e.BTN_TL2, "left"), (e.BTN_THUMB, "left"),
                     (e.BTN_TR2, "right"), (e.BTN_THUMB2, "right")):
    where = next(s for s in DISAGREE if s[0] == half)
    wrong = []
    for metric in (osk_mod.CELLS, osk_mod.UNITS):
        mm = osk_mapper()
        mm.osk_metric = metric
        touch(mm, half, MINV, -1)
        mm.cursors.pos[half] = [where[1], where[2]]
        want = mm.osk.key_at(half, *mm.cursors.position(half), metric).code
        got = mm.translate(e.EV_KEY, button, 1, 0.1)
        if got != [(want, 1), (want, 0)]:
            wrong.append((metric, got, want))
    check(f"a commit on {half} follows osk_metric, in BOTH metrics", wrong, [])

# --- 🔴 TOUCH: the overlay reports a KEY INDEX and this presses it -----------
#
# Operator, on hardware, 2026-08-12: *"touch on the keyboard still does not work
# (works in desktop)"*. The overlay now takes touch inside its own key grid
# (`deck_osk_wayland.input_region_rect`), hit-tests it against the rectangles it
# PAINTED, and sends the index home. This end presses it.
#
# ⚠️ AN INDEX AND NOT A COORDINATE, deliberately: the overlay draws and
# hit-tests in `UNITS`, `press_at` resolves in `CELLS`, and the two differ by up
# to half a key inside a half -- so a coordinate sent home would be re-resolved
# in the wrong metric and would sometimes type the neighbour of the key under
# the finger. See `Mapper.press_key_index`.

mm = osk_mapper()
rows = mm.osk.layer.rows
letter = next((r, k) for r, row in enumerate(rows)
              for k, key in enumerate(row) if key.is_letter)
key = rows[letter[0]][letter[1]]
check("a touch on a letter types exactly that letter",
      mm.press_key_index(*letter), [(key.code, 1), (key.code, 0)])

# The same key, committed by a trigger and by a touch, must agree -- ONE
# emission path. The trigger route goes through press_at; this goes through the
# index; both must end in OnScreenKeyboard.press.
mm = osk_mapper()
touch(mm, "left", MINV, -1)
mm.cursors.pos["left"] = [0.5, 0.5]
under = mm.osk.key_at("left", *mm.cursors.position("left"))
by_index = osk_mapper().press_key_index(
    *next((r, k) for r, row in enumerate(rows)
          for k, kk in enumerate(row) if kk is under))
check("a touch and a trigger commit the same key identically",
      mm.translate(e.EV_KEY, e.BTN_TL2, 1, 0.1), by_index)

# The MODIFIERS have to travel that path too, or a touch would type lowercase
# under a held Shift while the screen showed shift engaged.
mm = osk_mapper()
mm.translate(e.EV_KEY, e.BTN_TL2, 1, 0.0)          # Shift held on L2
strokes = mm.press_key_index(*letter)
check("a touch under a held Shift carries the modifier",
      strokes[0] if strokes else None, (osk_mod.SHIFT_CODE, 1))
check("...and Shift is still held afterwards", mm.osk_shift, True)

# A state key answers with an EMPTY LIST, which is not the same as "no such
# key" -- the caller distinguishes them, and complains about only one.
mm = osk_mapper()
shift_index = next((r, k) for r, row in enumerate(rows)
                   for k, key in enumerate(row) if key.action == "shift")
check("touching the on-screen Shift key emits nothing and arms the one-shot",
      (mm.press_key_index(*shift_index), mm.osk.shift), ([], "once"))
caps_index = next((r, k) for r, row in enumerate(rows)
                  for k, key in enumerate(row) if key.action == "caps")
check("touching Caps latches it, emitting no keycode",
      (mm.press_key_index(*caps_index), mm.osk.caps), ([], True))

# 🔴 None IS RESERVED FOR "no such key" -- the two processes disagreeing about
# the layout. Anything else would make a real defect indistinguishable from a
# Shift key, and the journal would never say so.
mm = osk_mapper()
OFF_LAYOUT = ((len(rows), 0), (0, len(rows[0])), (-1, 0), (0, -1))
# Asked FIRST, and as "did it raise": an index error out of here would climb
# into the input loop, and with lizard_mode=N that is a handheld with no keys.
check("no index the overlay could send can raise",
      [raised(lambda r=r, c=c: mm.press_key_index(r, c)) for r, c in OFF_LAYOUT],
      [None] * 4)
check("a row past the end of the layout is None, not a crash and not []",
      mm.press_key_index(len(rows), 0), None)
check("...a column past the end of its row too",
      mm.press_key_index(0, len(rows[0])), None)
check("...and negatives, which no hit test should ever produce",
      (mm.press_key_index(-1, 0), mm.press_key_index(0, -1)), (None, None))
check("a mapper with no keyboard attached answers None rather than raising",
      m.Mapper().press_key_index(0, 0), None)

# --- 🔴 THE EMOJI KEY: a renderer-owned request, queued and cleared once -----
#
# EMOJI_KEY (deck_osk_layout.py) is the one key on the board with no keycode
# of its own: `OnScreenKeyboard.press()` records the ask in `self.osk.request`
# and stops there -- opening the panel is this process's job, not the layout
# core's. `Mapper._consume_osk_request` is what turns that into a queued
# action for `run_pending` to spawn, and what clears `request` so a press
# fires exactly once, not on every subsequent loop iteration -- see that
# method's docstring, and the comment above MENU_ACTIONS for why the argv it
# queues is `omarchy-menu-emoji`, not `omarchy-menu emoji`.

mm = osk_mapper()
rows = mm.osk.layer.rows
emoji_index = next((r, k) for r, row in enumerate(rows)
                   for k, key in enumerate(row) if key.action == "emoji")
emoji_key = rows[emoji_index[0]][emoji_index[1]]
check("pressing the emoji key by touch emits no keycode",
      mm.press_key_index(*emoji_index), [])
check("...and queues exactly the emoji action, once",
      mm.pending_actions, ["emoji"])
check("...and the request is cleared, so it does not linger for something "
      "else to pick up twice", mm.osk.request, "")

# A later, unrelated press must not re-queue anything -- `request` is only
# ever non-empty right after an emoji press, but this pins that
# `_consume_osk_request` does not somehow resurrect a stale value.
letter = next((r, k) for r, row in enumerate(rows)
              for k, key in enumerate(row) if key.is_letter)
key = rows[letter[0]][letter[1]]
mm.pending_actions.clear()
check("a following, unrelated touch queues nothing more",
      (mm.press_key_index(*letter), mm.pending_actions),
      ([(key.code, 1), (key.code, 0)], []))

# `commit_at` (the trigger/pad-click path) is the SAME emission path as touch
# -- see press_key_index's own docstring -- so the emoji key has to behave
# identically committed either way, not just through the overlay's index.
mm = osk_mapper()
touch(mm, "left", MINV, -1)
emoji_pos = next(
    ((x, y) for x in (i / 200 for i in range(201))
     for y in (0.1, 0.3, 0.5, 0.7, 0.9)
     if mm.osk.key_at("left", x, y, mm.osk_metric) is emoji_key),
    None)
check("a cursor position lands on the emoji key (or the checks below prove "
      "nothing)", emoji_pos is not None, True)
mm.cursors.pos["left"] = list(emoji_pos)
check("committing the emoji key via a trigger emits no keycode either",
      mm.commit_at("left"), [])
check("...and queues the same action touch did",
      mm.pending_actions, ["emoji"])
check("...and clears the request the same way",
      mm.osk.request, "")

# --- X, Y and L3: unconditional shortcuts, exactly as Valve badges them ------
#
# §9g: only the TRIGGER badges gate on touch. Ⓧ, Ⓨ and L3 are always shown,
# so they must always work -- touched, lifted, or one of each.

for state in ("lifted", "left", "right", "both"):
    mm = osk_mapper()
    if state in ("left", "both"):
        touch(mm, "left")
    if state in ("right", "both"):
        touch(mm, "right")
    check(f"X types Backspace with the pads {state}",
          mm.translate(e.EV_KEY, e.BTN_NORTH, 1, 0.1),
          [(e.KEY_BACKSPACE, 1), (e.KEY_BACKSPACE, 0)])
    check(f"Y types Space with the pads {state}",
          mm.translate(e.EV_KEY, e.BTN_WEST, 1, 0.2),
          [(e.KEY_SPACE, 1), (e.KEY_SPACE, 0)])
    check(f"L3 latches Caps with the pads {state}",
          (mm.translate(e.EV_KEY, e.BTN_THUMBL, 1, 0.3), mm.osk_caps), ([], True))

# A complete tap on the press, nothing on the release. Anything else can leave
# Backspace held when the keyboard is dismissed mid-press.
mm = osk_mapper()
mm.translate(e.EV_KEY, e.BTN_NORTH, 1, 0.0)
check("a face-button shortcut emits nothing on its release",
      mm.translate(e.EV_KEY, e.BTN_NORTH, 0, 0.1), [])
check("...and nothing on the pad's own autorepeat either",
      mm.translate(e.EV_KEY, e.BTN_NORTH, 2, 0.2), [])

# 🔴 CAPS IS NOT SHIFT (§9g). Caps changes letter case only; Shift changes
# symbols, case AND the arrow keys. The layout core keeps them as two fields
# for exactly that reason, and L3 must reach the caps one.
mm = osk_mapper()
mm.translate(e.EV_KEY, e.BTN_THUMBL, 1, 0.0)
check("L3 sets `caps`, and leaves `shift` alone",
      (mm.osk.caps, mm.osk.shift), (True, "off"))
check("so the mapper reports caps without reporting shift",
      (mm.osk_caps, mm.osk_shift), (True, False))
check("L3 again unlatches it",
      (mm.translate(e.EV_KEY, e.BTN_THUMBL, 1, 0.1), mm.osk.caps), ([], False))

# The two are independent: latching one must not disturb the other.
mm = osk_mapper()
mm.translate(e.EV_KEY, e.BTN_THUMBL, 1, 0.0)       # Caps on
mm.translate(e.EV_KEY, e.BTN_TL2, 1, 0.1)          # Shift held (pads lifted)
check("Caps and Shift can be on at once", (mm.osk_caps, mm.osk_shift), (True, True))
mm.translate(e.EV_KEY, e.BTN_TL2, 0, 0.2)          # Shift let go
check("letting Shift go leaves Caps latched", (mm.osk_caps, mm.osk_shift), (True, False))

# ⚠️ BTN_THUMBL IS THE LEFT STICK CLICK. BTN_THUMB, one letter shorter, is the
# left TRACKPAD's click -- measured in the same capture (press 14.079s, release
# 14.551s). Binding the wrong one fires Caps every time a thumb clicks the pad
# it is already resting on.
mm = osk_mapper()
check("the caps binding is the left STICK click, not the left PAD click",
      m.OSK_CAPS_BUTTON, e.BTN_THUMBL)
check("the left TRACKPAD click does nothing to Caps",
      (mm.translate(e.EV_KEY, e.BTN_THUMB, 1, 0.0), mm.osk_caps), ([], False))

# --- the ON-SCREEN Shift key is untouched by any of that ---------------------
#
# ⚠️ THE ONE-SHOT DID NOT GO AWAY, IT MOVED BACK TO WHERE IT ALWAYS WAS. L2 is
# now a hold; the one-handed way to use it is to aim with the left pad and CLICK
# it (see the pad-click block above and `Mapper.hold_osk_shift`), and the route
# that needs no trigger at all is the Shift KEY on the keyboard, still cycling
# off -> once -> locked and still spent by the key it modifies. Losing that
# quietly would leave a user with no way to type a capital at all.
mm = osk_mapper()
touch(mm, "left", MINV, MAXV)
mm.cursors.pos["left"] = [0.05, 0.75]              # the left Shift key
check("the left cursor really is on a Shift key (or this proves nothing)",
      mm.osk.key_at("left", *mm.cursors.position("left")).action, "shift")
check("pressing it emits no keycode and arms a ONE-SHOT",
      (mm.translate(e.EV_KEY, e.BTN_TL2, 1, 0.1), mm.osk.shift), ([], "once"))
mm.translate(e.EV_ABS, e.ABS_HAT1X, MINV, 0.2)
mm.translate(e.EV_ABS, e.ABS_HAT1Y, -1, 0.2)       # a letter, right pad touched
strokes = mm.translate(e.EV_KEY, e.BTN_TR2, 1, 0.3)
check("a committed key under it carries the shift modifier",
      strokes[0] if strokes else None, (osk_mod.SHIFT_CODE, 1))
check("...and the one-shot is spent by the key it modified",
      mm.osk_shift, False)

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

# ⚠️ KEY_TAB IS GONE from here and KEY_BACKSPACE has taken its place: X was
# rebound 2026-08-12 for parity with Valve's Ⓧ badge. KEY_TAB survives in
# EMITTED_KEYS only because the layout still has a Tab KEY, which is a different
# thing from a face button that types one.
NAV_KEYS = {e.KEY_ENTER, e.KEY_ESC, e.KEY_SPACE, e.KEY_BACKSPACE, e.KEY_PAGEUP,
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

# ⚠️ THE OSK's OWN SHORTCUTS, checked separately. They overlap the navigation
# table today (X/Backspace, Y/Space, R2/Enter are all navigation keys as well),
# so a shortcut rebound to something the navigation profile does NOT emit would
# be dropped by the kernel with no error and no test failure anywhere else.
check("every OSK button shortcut is declared on the uinput device",
      sorted(set(m.OSK_SHORTCUTS.values()) - set(m.EMITTED_KEYS)), [])
check("...and so is every idle-trigger key",
      sorted(set(m.OSK_IDLE_TRIGGER_KEYS.values()) - set(m.EMITTED_KEYS)), [])
# Backspace must survive the layout core failing to load: with it gone the OSK
# is disabled but X still has to delete.
check("Backspace comes from the NAVIGATION table, not only from the layout",
      e.KEY_BACKSPACE in set(m.BUTTON_MAP.values()), True)
# Caps is a STATE, not a keycode. A KEY_CAPSLOCK left latched in the kernel
# would outlive the keyboard and shout into whatever the user typed next.
check("no caps-lock keycode is ever declared", e.KEY_CAPSLOCK in m.EMITTED_KEYS, False)

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
# ⚠️ THE ANSWER IS NOT THE ASSERTION HERE -- THE CLOCK IS. A `read_lock_state`
# that ignored `timeout` entirely would ALSO return None from this, five
# seconds later, having blocked the only input path on the device for five
# seconds. So the elapsed time is what is checked. 2.0s is far above a Python
# interpreter's start-up and far below the 5s this process would otherwise
# wait for.
import time as _time  # noqa: E402 -- the suite is a script; block-local by design
_started = _time.monotonic()
check("a process that outlasts the timeout is unknown, never blocks forever",
      m.read_lock_state(argv=(sys.executable, "-c", "import time; time.sleep(5)"),
                        timeout=0.2),
      None)
check("...and it was CUT OFF at the bound, not merely answered late",
      _time.monotonic() - _started < 2.0, True)

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
      lw.tick(1_000_000.0, reader=queue_reader(), screensaver=queue_reader()), None)
check("...and its deadline is None -- nothing to wait for", lw.next_deadline(), None)

lw.start(now=0.0)
check("start() arms it", lw.armed, True)
check("start() checks right away -- summoned-while-locked is the common case",
      lw.next_deadline(), 0.0)
check("start() clears any earlier saw_lock", lw.saw_lock, False)

# The FIRST poll observes LOCKED: no edge yet, but the state latches.
check("a LOCKED reading reports no edge -- it must not hide the keyboard",
      lw.tick(0.0, reader=queue_reader(True), screensaver=queue_reader()), None)
check("...and is remembered", lw.saw_lock, True)
check("the next check is scheduled one interval out", lw.next_deadline(), 10.0)

# Asking again before the interval elapses must NOT poll -- queue_reader()
# with no values raises if it is called, so this also proves the throttle.
check("polling again before the interval is due does nothing, and does not "
      "even call the reader",
      lw.tick(5.0, reader=queue_reader(), screensaver=queue_reader()), None)
check("saw_lock is unaffected by a tick that did not poll", lw.saw_lock, True)

# Still locked on the next legitimate poll: still no edge.
check("a SECOND locked reading still reports no edge",
      lw.tick(10.0, reader=queue_reader(True), screensaver=queue_reader()), None)
check("saw_lock stays latched", lw.saw_lock, True)

# NOW it unlocks. This is the one and only case that must report True.
check("LOCKED -> UNLOCKED is exactly the edge that fires",
      lw.tick(20.0, reader=queue_reader(False), screensaver=queue_reader()),
      "unlock")
check("the edge consumes saw_lock -- it will not fire twice for one unlock",
      lw.saw_lock, False)
check("a further UNLOCKED reading reports no edge -- there was nothing to "
      "transition FROM",
      lw.tick(30.0, reader=queue_reader(False), screensaver=queue_reader(False)),
      None)

# ⚠️ THE PROPERTY THE WHOLE DESIGN EXISTS FOR: a keyboard shown in an ALREADY
# unlocked desktop, that never observes a LOCK, must NEVER report an edge --
# there is nothing to have unlocked from. Getting this backwards would hide
# the keyboard on some other read entirely, which is the failure this
# mechanism must not have.
lw2 = m.LockWatcher(interval=10.0)
lw2.start(now=0.0)
never_locked = queue_reader(False, False, False, False)
no_screensaver = queue_reader(False, False, False, False)
saw_edge = False
t = 0.0
for _ in range(4):
    if lw2.tick(t, reader=never_locked, screensaver=no_screensaver):
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
lw3.tick(0.0, reader=queue_reader(True), screensaver=queue_reader())
check("still locked before the unknown reading", lw3.saw_lock, True)
check("an unknown reading (None) reports no edge",
      lw3.tick(10.0, reader=queue_reader(None), screensaver=queue_reader()), None)
check("...and does not clear saw_lock -- a later real reading can still fire",
      lw3.saw_lock, True)
check("the very next legitimate poll can still detect the real unlock",
      lw3.tick(20.0, reader=queue_reader(False), screensaver=queue_reader()),
      "unlock")

# stop() disarms unconditionally, from any state.
lw4 = m.LockWatcher(interval=10.0)
lw4.start(now=0.0)
lw4.tick(0.0, reader=queue_reader(True), screensaver=queue_reader())
lw4.stop()
check("stop() disarms", lw4.armed, False)
check("stop() clears saw_lock too -- a re-show must start from scratch",
      lw4.saw_lock, False)
check("a stopped watcher's deadline is None", lw4.next_deadline(), None)
check("ticking a stopped watcher never polls or fires",
      lw4.tick(999.0, reader=queue_reader(), screensaver=queue_reader()), None)

# start() while already armed re-arms cleanly -- the shape a real re-show
# takes (hide, then show again) rather than a fresh object every time.
lw5 = m.LockWatcher(interval=10.0)
lw5.start(now=0.0)
lw5.tick(0.0, reader=queue_reader(True), screensaver=queue_reader())
check("mid-sequence: locked once", lw5.saw_lock, True)
lw5.start(now=100.0)   # hidden and re-shown
check("re-starting clears the earlier LOCK -- it belongs to the last showing",
      lw5.saw_lock, False)
check("re-starting resets the poll clock too", lw5.next_deadline(), 100.0)

# --- the SCREENSAVER: hide for it, and NEVER mistake it for the lock ---------
#
# Operator, 2026-08-12: *"can we hide the keyboard prior to going into
# screensaver? right now the screensaver plays and the keyboard is still
# there"*.
#
# 🔴 THE DANGEROUS DIRECTION IS THE OTHER ONE. §5.24 records that the power
# button produces a password screen the user cannot answer without this
# keyboard, verified in pixels; T8 request 1 says the same. So the assertions
# that matter most below are the ones proving a LOCKED session hides nothing --
# and, stronger, that the screensaver is not even ASKED ABOUT while locked.
#
# What tells them apart: the screensaver is an ordinary toplevel WINDOW (a
# terminal running `omarchy-screensaver`, launched with an explicit app-id) and
# appears in `hyprctl -j clients`. The lock is an `ext_session_lock_v1` and
# appears as LOCK in `solitaryBlockedBy` in `hyprctl -j monitors`. Different
# objects, different queries; neither can show up in the other's answer. Both
# shapes below were read off the Deck on 2026-08-12 with the screensaver
# actually playing.

SCREENSAVER_UP = ('[{"class": "org.omarchy.screensaver", '
                  '"initialClass": "org.omarchy.screensaver", '
                  '"title": "foot", "mapped": true, "fullscreen": 2}]')
ORDINARY_WINDOWS = ('[{"class": "Alacritty", "initialClass": "Alacritty", '
                    '"title": "deck@steamdeck"}, '
                    '{"class": "chromium", "initialClass": "chromium", '
                    '"title": "Omarchy"}]')

check("the screensaver's own window is recognised",
      m.screensaver_from_clients(SCREENSAVER_UP), True)
check("ordinary windows are not the screensaver",
      m.screensaver_from_clients(ORDINARY_WINDOWS), False)
check("an empty desktop is not the screensaver",
      m.screensaver_from_clients("[]"), False)
check("a window that only kept its INITIAL app-id still counts",
      m.screensaver_from_clients(
          '[{"class": "foot", "initialClass": "org.omarchy.screensaver"}]'), True)
check("a window merely TITLED like it is not it -- the app-id is the handle",
      m.screensaver_from_clients(
          '[{"class": "foot", "title": "org.omarchy.screensaver"}]'), False)
check("malformed JSON is UNKNOWN, not 'no screensaver'",
      m.screensaver_from_clients("{not json"), None)
check("a JSON object instead of a list is unknown -- the shape changed",
      m.screensaver_from_clients('{"class": "org.omarchy.screensaver"}'), None)
check("a non-dict client entry is skipped, not fatal",
      m.screensaver_from_clients('["not a client object", '
                                 '{"class": "org.omarchy.screensaver"}]'), True)
check("empty input is unknown", m.screensaver_from_clients(""), None)
check("the app-id matched is the one upstream launches every terminal with",
      m.SCREENSAVER_APP_ID, "org.omarchy.screensaver")
check("...and it is looked for in the CLIENT list, which is where windows are "
      "-- the lock lives in `monitors` and is read separately",
      m.SCREENSAVER_STATE_ARGV, ("hyprctl", "-j", "clients"))
check("the two sensors really do ask different questions",
      m.SCREENSAVER_STATE_ARGV != m.LOCK_STATE_ARGV, True)

# read_screensaver_state: the same bounded, fail-quiet contract as the lock.
check("a real hyprctl-shaped process's stdout is parsed",
      m.read_screensaver_state(argv=(sys.executable, "-c",
                                     f"print({SCREENSAVER_UP!r})")), True)
check("a nonzero exit is unknown, not 'no screensaver'",
      m.read_screensaver_state(argv=(sys.executable, "-c",
                                     f"import sys; print({SCREENSAVER_UP!r}); "
                                     "sys.exit(1)")),
      None)
check("a binary that does not exist is unknown, never raises",
      m.read_screensaver_state(argv=("/nonexistent/hyprctl", "-j", "clients")), None)
_started = _time.monotonic()
check("a process that outlasts the timeout is unknown, never blocks forever",
      m.read_screensaver_state(argv=(sys.executable, "-c", "import time; time.sleep(5)"),
                               timeout=0.2),
      None)
check("...and it too was CUT OFF at the bound -- see read_lock_state above for "
      "why the clock is the assertion and the None is not",
      _time.monotonic() - _started < 2.0, True)


def spy_reader(value):
    """A reader that records whether it was called at all. Being able to assert
    NOT CALLED is the point: "we asked and ignored the answer" and "we never
    asked" are the same result today and diverge the moment someone reorders
    `tick`."""
    calls = []

    def reader():
        calls.append(value)
        return value
    return reader, calls


# The plain case the operator asked for: unlocked desktop, screensaver comes up.
sw = m.LockWatcher(interval=10.0)
sw.start(now=0.0)
saver, saver_calls = spy_reader(True)
check("an UNLOCKED session with the screensaver up hides the keyboard",
      sw.tick(0.0, reader=queue_reader(False), screensaver=saver), "screensaver")
check("...and it really did read the client list to decide", len(saver_calls), 1)
check("...without inventing a lock it never saw", sw.saw_lock, False)

# Level-triggered, not edge-triggered: a screensaver that is still up on the
# next poll still says hide. main() will have hidden the keyboard and stopped
# the watcher by then, so this only matters if that hide failed -- in which
# case retrying is the behaviour that recovers.
check("a screensaver still up on the next poll still says hide",
      sw.tick(10.0, reader=queue_reader(False), screensaver=spy_reader(True)[0]),
      "screensaver")
check("and no screensaver means no hide",
      sw.tick(20.0, reader=queue_reader(False), screensaver=spy_reader(False)[0]),
      None)
check("an UNREADABLE client list hides nothing -- unknown is not 'up'",
      sw.tick(30.0, reader=queue_reader(False), screensaver=spy_reader(None)[0]),
      None)

# 🔴 THE ASSERTION THIS WHOLE FEATURE HAS TO EARN. A locked session hides
# NOTHING, with the screensaver playing on top of the lock and reporting so.
# Getting this wrong takes away the only keyboard that can answer the password
# prompt, on a device with no other input path (§5.9, §5.24).
locked = m.LockWatcher(interval=10.0)
locked.start(now=0.0)
saver, saver_calls = spy_reader(True)
check("🔴 a LOCKED session with the screensaver up hides NOTHING",
      locked.tick(0.0, reader=queue_reader(True), screensaver=saver), None)
check("🔴 ...and the screensaver was never even asked about while locked",
      saver_calls, [])
check("...the lock is still latched, so the later unlock still fires",
      locked.saw_lock, True)
check("🔴 still nothing on a second locked poll, however long it stays up",
      locked.tick(10.0, reader=queue_reader(True), screensaver=saver), None)
check("🔴 ...still never asked", saver_calls, [])

# ...and an UNKNOWN lock reading is treated as locked for this purpose: we did
# not establish that it is safe to hide, so we do not hide.
unknown = m.LockWatcher(interval=10.0)
unknown.start(now=0.0)
saver, saver_calls = spy_reader(True)
check("🔴 an UNKNOWN lock reading hides nothing, screensaver or not",
      unknown.tick(0.0, reader=queue_reader(None), screensaver=saver), None)
check("🔴 ...and the screensaver was not asked about either",
      saver_calls, [])

# The unlock edge still wins, and still spends no subprocess deciding.
both = m.LockWatcher(interval=10.0)
both.start(now=0.0)
both.tick(0.0, reader=queue_reader(True), screensaver=queue_reader())
saver, saver_calls = spy_reader(True)
check("an unlock edge reports the UNLOCK, not the screensaver behind it",
      both.tick(10.0, reader=queue_reader(False), screensaver=saver), "unlock")
check("...and does not spend a second hyprctl to say so", saver_calls, [])

# The throttle covers both sensors, or a keyboard on screen runs two
# subprocesses per pass through the input loop.
throttled = m.LockWatcher(interval=10.0)
throttled.start(now=0.0)
throttled.tick(0.0, reader=queue_reader(False), screensaver=queue_reader(False))
saver, saver_calls = spy_reader(True)
check("a tick before the interval is due polls NEITHER sensor",
      throttled.tick(5.0, reader=queue_reader(), screensaver=saver), None)
check("...proven by the screensaver reader never running", saver_calls, [])


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

# ⚠️ Same technique, same reason, different invariant. EMITTED_KEYS must be
# built from the OSK's button tables as well as the navigation ones. Today the
# two OVERLAP -- Backspace, Space and Enter are navigation keys too -- so
# deleting the fold changes nothing and no behavioural test can see it. The day
# a shortcut is rebound to a key the navigation profile does not emit, the
# kernel drops it with no error on any side. Assert the structure, because the
# behaviour cannot be asserted until it is already too late.
emitted = next(node for node in ast.walk(tree)
               if isinstance(node, ast.Assign)
               and any(isinstance(t, ast.Name) and t.id == "EMITTED_KEYS"
                       for t in node.targets))
emitted_names = {node.id for node in ast.walk(emitted.value) if isinstance(node, ast.Name)}
check("EMITTED_KEYS is built from the OSK's button tables too",
      sorted({"OSK_SHORTCUTS", "OSK_IDLE_TRIGGER_KEYS"} - emitted_names), [])

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

# Same problem, same technique: `reset_osk_state()` is only worth anything if
# main() calls it on every show, and there are two show paths (tty and layer).
# Without both, a keyboard dismissed with Caps latched comes back latched.
mapper_calls = [node for node in ast.walk(main_def)
                if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                and isinstance(node.func.value, ast.Name)
                and node.func.value.id == "mapper"]
check("main() resets the OSK's state on BOTH show paths (tty and layer)",
      sum(node.func.attr == "reset_osk_state" for node in mapper_calls), 2)

# 🔴 THE LIFT GATE, PINNED THE SAME WAY. `Mapper.pointer_lifted` can be as
# green as it likes above and the cursor still jumps on every release, because
# whether it is CONSULTED is main()'s business and main() is a 400-line
# function around a live device. Two report boundaries drain the accumulated
# motion (SYN_REPORT, and the end of a batch from a device that sends none);
# a gate on only one of them is a gate that can be walked around.
flush_def = next(node for node in ast.walk(main_def)
                 if isinstance(node, ast.FunctionDef) and node.name == "flush_motion")
check("main() emits pointer motion from exactly ONE place",
      [node.func.id for node in ast.walk(main_def)
       if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
       and node.func.id == "emit_motion"],
      ["emit_motion"])
check("...and that place asks the mapper whether the report was a LIFT",
      any(isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
          and node.func.attr == "pointer_lifted" for node in ast.walk(flush_def)),
      True)
check("...asked once, so there is one gate rather than a scattering",
      sum(isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
          and node.func.attr == "pointer_lifted" for node in ast.walk(main_def)),
      1)
check("...and BOTH report boundaries go through it",
      sum(isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
          and node.func.id == "flush_motion" for node in ast.walk(main_def)),
      2)

# Every reason `tick` can return must have a journal line. A hide with no
# explanation looks exactly like a crash on a device this process is the only
# input path for.
tick_def = next(node for node in ast.walk(
    next(n for n in ast.walk(tree)
         if isinstance(n, ast.ClassDef) and n.name == "LockWatcher"))
    if isinstance(node, ast.FunctionDef) and node.name == "tick")
tick_reasons = sorted({node.value.value for node in ast.walk(tick_def)
                       if isinstance(node, ast.Return)
                       and isinstance(node.value, ast.Constant)
                       and isinstance(node.value.value, str)})
check("tick() returns exactly the two reasons this file knows about",
      tick_reasons, ["screensaver", "unlock"])
check("...and every one of them has a line for the journal",
      sorted(set(tick_reasons) - set(m.HIDE_REASONS)), [])
check("...with no orphan lines for reasons that cannot happen",
      sorted(set(m.HIDE_REASONS) - set(tick_reasons)), [])

# 🔴 AND THE HIDE ITSELF IS GATED ON THE WATCHER'S ANSWER, in main(), where no
# behavioural test here can reach. The watcher may only be asked while the
# LAYER keyboard is actually on screen: `above_lock=2` is what makes it visible
# over a lock at all, and no other backend has this problem.
lock_ticks = [node for node in ast.walk(main_def)
              if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
              and node.func.attr == "tick"
              and isinstance(node.func.value, ast.Name)
              and node.func.value.id == "lock_watcher"]
check("main() polls the watcher from exactly one place", len(lock_ticks), 1)
tick_guard = next(node for node in ast.walk(main_def)
                  if isinstance(node, ast.If)
                  and any(sub in lock_ticks for sub in ast.walk(node)))
check("...only while a LAYER keyboard is actually visible",
      sorted(name.id for name in ast.walk(tick_guard.test)
             if isinstance(name, ast.Name)), ["osk_backend", "osk_visible"])
check("...and the only thing it does with a reason is hide",
      sorted({node.func.id for node in ast.walk(tick_guard)
              if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)}),
      ["say", "set_osk_visible"])
# ...for ANY reason the watcher can give. A call site that hard-codes one of
# them silently drops the other -- green everywhere else in this file, because
# `tick` would still be returning it.
check("...and it acts on whatever reason comes back, never a hard-coded one",
      sorted({node.value for node in ast.walk(tick_guard)
              if isinstance(node, ast.Constant) and isinstance(node.value, str)}
             & set(tick_reasons)),
      [])

# Same shape again: `osk_metric` defaults to the tty renderer's metric, so the
# LAYER backend has to say so, and if it stops saying so every commit quietly
# lands up to half a key from the key drawn under the cursor. Nothing else in
# this suite can see that line, because setting it is main()'s job.
metric_sets = [node for node in ast.walk(main_def) if isinstance(node, ast.Assign)
               and any(isinstance(t, ast.Attribute) and t.attr == "osk_metric"
                       and isinstance(t.value, ast.Name) and t.value.id == "mapper"
                       for t in node.targets)]
check("main() tells the mapper which metric the LAYER renderer draws in",
      [ast.unparse(node.value) for node in metric_sets], ["osk_layout.UNITS"])

# 🔴 THE DEFECT ITSELF, AND THE ONLY PLACE IT CAN BE SEEN. `format_state_line`
# takes `touched` as an OPTIONAL third argument, because an older mapper must
# still produce a line a newer overlay can parse -- so dropping it is not a
# TypeError, it is a silent frame that says "nothing is being touched" for ever.
# The call lives inside main(), around a live subprocess no unit test can enter,
# so it is asserted structurally, exactly like the §5.28 environment rule above.
state_lines = [node for node in ast.walk(tree)
               if isinstance(node, ast.Call)
               and isinstance(node.func, ast.Attribute)
               and node.func.attr == "format_state_line"]
check("the mapper writes exactly one state line, so there is one call to pin",
      len(state_lines), 1)
check("...and it passes THREE arguments -- the third is the pad touch state",
      [len(node.args) for node in state_lines], [3])
# ...from the mapper's own measurement, not a placeholder. `{}` and
# `{"left": False, "right": False}` both type-check and both reinstate the bug.
check("...taken from mapper.pad_touch_state(), not invented at the call site",
      [node.args[2].func.attr for node in state_lines
       if isinstance(node.args[2], ast.Call)
       and isinstance(node.args[2].func, ast.Attribute)],
      ["pad_touch_state"])

# 🔴 THE TOUCH PATH, PINNED THE SAME WAY AND FOR THE SAME REASON. Every one of
# these lives inside main(), around a live subprocess and a live selector that
# no unit test can enter, and every one of them fails SILENTLY: the overlay
# keeps drawing, the pads keep committing, and a finger on the glass does
# nothing at all with no error on either side. `press_key_index` can be as
# green as it likes above and touch can still be dead on the device.
overlay_popen = [node for node in ast.walk(main_def)
                 if isinstance(node, ast.Call)
                 and isinstance(node.func, ast.Attribute)
                 and node.func.attr == "Popen"]
check("main() starts exactly one child of its own -- the overlay",
      len(overlay_popen), 1)
# Without stdout=PIPE the overlay's touches go to the journal as text and this
# process never sees one. The pipe IS the touch path.
check("...and it captures the overlay's stdout, which is where touches arrive",
      sorted(kw.arg for kw in overlay_popen[0].keywords),
      ["env", "stdin", "stdout", "text"])
check("...with a real pipe, not an inherited fd",
      ["subprocess.PIPE" in ast.unparse(kw.value)
       for kw in overlay_popen[0].keywords if kw.arg == "stdout"], [True])
# ...and DEVNULL when the protocol could not be loaded, because a pipe with no
# reader fills and then BLOCKS the overlay's GTK thread -- a keyboard frozen
# mid-draw, on a device where this process is the only other input path.
check("...falling back to DEVNULL rather than to an undrained pipe",
      ["subprocess.DEVNULL" in ast.unparse(kw.value)
       for kw in overlay_popen[0].keywords if kw.arg == "stdout"], [True])

# A pipe nobody selects on is a keystroke that waits for the next pad event --
# which, when the user is typing with a finger, may never come.
# The input loop, and not `run_pending`'s `while actions` -- the one that blocks
# in the selector is the one that has to know about this fd.
loop = next(node for node in ast.walk(main_def)
            if isinstance(node, ast.While)
            and any(isinstance(inner, ast.Call)
                    and isinstance(inner.func, ast.Attribute)
                    and inner.func.attr == "select"
                    for inner in ast.walk(node)))
loop_calls = {node.func.id for node in ast.walk(loop)
              if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)}
loop_names = {node.id for node in ast.walk(loop) if isinstance(node, ast.Name)}
check("the loop pumps the overlay's pipe when the selector says it is ready",
      ("osk_layer_pump" in loop_calls, "osk_layer_fd" in loop_names),
      (True, True))
main_names = {node.id for node in ast.walk(main_def) if isinstance(node, ast.Name)}
check("...and that fd is registered and unregistered around the overlay's life",
      sorted({"osk_layer_watch", "osk_layer_unwatch"} - main_names), [])
check("...and what arrives is pressed through the mapper, not typed here",
      sum(1 for node in ast.walk(main_def)
          if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
          and node.func.attr == "press_key_index"), 1)
# The protocol is parsed by the module that WROTE it -- one definition, like
# `AutoShow` and `deck_osk_focus`. A hand-rolled `line.split()` here is two
# definitions that agree only until one of them moves.
loaded = [node.args[0].value for node in ast.walk(main_def)
          if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
          and node.func.id == "_load_module"
          and node.args and isinstance(node.args[0], ast.Constant)]
check("main() imports the overlay's own line protocol rather than reinventing it",
      "deck_osk_wayland" in loaded, True)

# --- the console's WIDTH, read at runtime (T8 §9g) ---------------------------
#
# 🔴 THE AXIS THAT CORRUPTS RATHER THAN CLIPS. A keyboard row taller than the
# console is clipped; a row WIDER than it is wrapped by the VT, which turns one
# row into two, pushes every row below it down, and scrolls the bottom of the
# keyboard away -- R-49's defect on the other axis. `docs/PROGRESS.md` §7
# measured 50x160 in the live ISO and 25x80 on the installed TTY, ON THE SAME
# PANEL, so neither number may be assumed; and since §9g the keyboard is exactly
# 80 columns, so on the narrow one the slack is ZERO.

import fcntl       # noqa: E402 -- local to this block, like the imports above
import pty         # noqa: E402
import struct      # noqa: E402
import termios     # noqa: E402


def pty_sized(rows, cols):
    """A pty fd whose window size really is `rows`x`cols`."""
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    return master, slave


master, slave = pty_sized(25, 80)
check("console_geometry reads a real console's size",
      m.console_geometry(slave), (25, 80))

# The ORDER matters and is the cheapest possible mistake: `.lines` where
# `.columns` was meant reads 25 as a width and refuses to draw an 80-column
# keyboard forever. A non-square console is the only thing that can see it.
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 160, 0, 0))
check("...as (rows, columns), in that order -- not transposed",
      m.console_geometry(slave), (50, 160))

# 🔴 NOT CACHED, ON EITHER AXIS. This is R-49's whole point: `stty rows`/`stty
# cols` do not merely change what a VT reports, they RESIZE it, so a geometry
# read once is a geometry that can be wrong by the time it is drawn with.
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 25, 40, 0, 0))
check("...and re-read every call, so a console resized mid-run is seen",
      m.console_geometry(slave), (25, 40))
os.close(master)
os.close(slave)

# The fallback. A pipe is not a console, so TIOCGWINSZ fails -- exactly what a
# VT that has been switched away or reconfigured does. It must ANSWER, not
# raise: this runs on the drawing path, and a console write that fails must not
# take the only input path on the device down with it (§5.9).
r_fd, w_fd = os.pipe()
check("a size that cannot be read falls back instead of raising",
      m.console_geometry(r_fd), (m.CONSOLE_ROWS_DEFAULT, m.CONSOLE_COLS_DEFAULT))
check("...to the INSTALLED tty's measured geometry -- the smaller console",
      (m.CONSOLE_ROWS_DEFAULT, m.CONSOLE_COLS_DEFAULT), (25, 80))
os.close(r_fd)
os.close(w_fd)

# A closed fd raises OSError too (EBADF), and it is the shape a stream that went
# away actually takes. Same answer.
c_fd = os.dup(1)
os.close(c_fd)
check("...and a dead fd is the same, not an exception",
      m.console_geometry(c_fd), (25, 80))

# --- what the too-narrow console gets instead of a corrupted keyboard --------
#
# Refuse and RETRY, deliberately -- never `osk_fall_back`, which on the tty
# backend is terminal (no squeekboard, no session bus in the installer) and
# would answer a width reading with "no keyboard for the rest of the session".

notice_80 = m.narrow_console_notice(80, 40)
check("a notice is one row", len(notice_80), 1)
check("...of one segment, highlighted -- reverse video is the console's only "
      "emphasis", [hot for _, hot in notice_80[0]], [True])
check("...and it carries BOTH numbers, which are the whole payload",
      all(n in notice_80[0][0][0] for n in ("80", "40")), True)

# Each rung pinned at the width that selects it, so none of them is dead copy
# saying the same thing as the rung above. 41 is where the longest form fits
# EXACTLY -- the same "exactly full is fine" rule the keyboard itself lives by.
check("the full form is used where it exactly fits",
      m.narrow_console_notice(80, 41)[0][0][0],
      "KEYBOARD NEEDS 80 COLUMNS, CONSOLE HAS 41")
check("...one column less and it drops to the short form, still both numbers",
      m.narrow_console_notice(80, 40)[0][0][0], "KEYBOARD NEEDS 80 COLS, HAS 40")

# ⚠️ THE ONE THING IT MAY NEVER DO IS THE THING IT EXISTS TO PREVENT. A notice
# wider than the console wraps, which is the corruption it was drawn instead of.
too_wide = sorted(cols for cols in range(0, 121)
                  if len(m.narrow_console_notice(80, cols)[0][0][0]) > cols)
check("NO width of console gets a notice wider than itself", too_wide, [])

check("it degrades rather than truncating the numbers away",
      m.narrow_console_notice(80, 20)[0][0][0], "OSK 80>20")
check("...and keeps a marker when even that will not fit",
      m.narrow_console_notice(80, 5)[0][0][0], "OSK !")
check("...and answers at all for a console with no columns to speak of",
      m.narrow_console_notice(80, 0)[0][0][0], "")

# --- the boundary itself, which is one column wide ---------------------------
#
# ⚠️ `>` AND NOT `>=`: a row that exactly fills the console is safe (write_at's
# docstring has the mechanism), and that is the ONLY reason 80-in-80 works. One
# column of drift either way is invisible until a Deck is in front of someone --
# too tight and the installed tty never gets a keyboard, too loose and it gets a
# wrapped one.
KB = [[("x" * 80, False)]]
check("a keyboard that exactly fills the console is drawn",
      m.rows_for_console(KB, 80, 80), (KB, True))
check("...one column narrower and it is refused",
      m.rows_for_console(KB, 80, 79)[1], False)
check("...one column wider and it is still drawn",
      m.rows_for_console(KB, 80, 81), (KB, True))
check("the refusal hands back the notice, not the keyboard",
      m.rows_for_console(KB, 80, 79)[0], m.narrow_console_notice(80, 79))
check("and the boundary is exactly where the width is, at every width",
      [cols for cols in range(0, 200)
       if m.rows_for_console(KB, 80, cols)[1] != (cols >= 80)], [])

# --- the zero-slack 80-column fit, measured rather than asserted -------------

tty_mod = m._load_module("deck_osk_tty")
osk_mod = m._load_osk_layout()
if tty_mod is None or osk_mod is None:
    check("the OSK modules load for the width check", False, True)
else:
    kb_rows = tty_mod.render(osk_mod.OnScreenKeyboard(), osk_mod.Cursors())
    kb_width = tty_mod.width(kb_rows)
    check("the rendered keyboard is exactly the installed tty's width",
          kb_width, 80)

    def drew(cols, rows_arg=None):
        """Did write_at draw, given a console `cols` wide? (None = it refused.)"""
        sink = io.StringIO()
        try:
            tty_mod.write_at(sink, kb_rows if rows_arg is None else rows_arg, 1,
                             console_rows=25, console_cols=cols)
        except ValueError:
            return None
        return sink.getvalue()

    check("80 columns is enough -- the zero-slack fit really does hold",
          drew(80) is not None, True)
    check("...and 79 is not, loudly", drew(79), None)
    # The notice is what runs in that second case, and it must survive the very
    # guard that rejected the keyboard -- otherwise the too-narrow path raises
    # into osk_fall_back and disables the keyboard after all.
    narrow_ok = sorted(cols for cols in range(1, 80)
                       if drew(cols, m.narrow_console_notice(80, cols)) is None)
    check("the notice passes the same guard at EVERY width the keyboard fails",
          narrow_ok, [])

# --- the wiring, enforced against the SOURCE ---------------------------------
#
# `_osk_draw` lives inside main(), which is 400 lines around a live device that
# no unit test can enter. Every check above tests a helper the drawing path
# CALLS; none of them can see the path stopping calling it. Deleting the width
# read would leave a keyboard that wraps on a narrow console and this whole
# suite green -- which is the exact defect class §5.28 was.

nested = {node.name: node for node in ast.walk(main_def)
          if isinstance(node, ast.FunctionDef)}
check("main() reads the console's WIDTH, not only its height",
      sorted(n for n in ("_console_rows", "_console_cols") if n in nested),
      ["_console_cols", "_console_rows"])

# Both axes share ONE fallback, so the documented behaviour on an unreadable
# console cannot drift apart between them.
for name, half in (("_console_rows", 0), ("_console_cols", 1)):
    check(f"{name} delegates to console_geometry",
          any(isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
              and node.func.id == "console_geometry"
              for node in ast.walk(nested[name])), True)
    # ...and takes the right half of the pair. Swapping these reads 25 as a
    # width, which refuses to draw an 80-column keyboard on every console
    # forever -- and reads 80 as a height, which is R-49's collapse.
    check(f"...and {name} takes half {half} of it",
          [node.slice.value for node in ast.walk(nested[name])
           if isinstance(node, ast.Subscript)
           and isinstance(node.slice, ast.Constant)], [half])

draw_def = nested.get("_osk_draw")
check("_osk_draw exists to be pinned", draw_def is not None, True)
draw_names = [node.id for node in ast.walk(draw_def)
              if isinstance(node, ast.Name) and isinstance(node.ctx, ast.Load)]
check("the width is read INSIDE the draw -- per draw, like the height",
      sorted({n for n in ("_console_rows", "_console_cols") if n in draw_names}),
      ["_console_cols", "_console_rows"])

# ...and read NOWHERE ELSE, which is what "not cached" means structurally: a
# width hoisted to main()'s body would be read once at startup and be wrong the
# moment `stty cols` ran (R-49).
per_draw = {nested[n].lineno: nested[n].end_lineno
            for n in ("_osk_draw", "_osk_erase") if n in nested}
geometry_calls = [node for node in ast.walk(main_def)
                  if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
                  and node.func.id in ("_console_rows", "_console_cols")]
# ...and every per-draw function really does the read, rather than a literal
# standing in for it. A hardcoded 25 here puts the keyboard's top row in the
# wrong place on the 50-row live console, and leaves the erase clearing rows the
# keyboard is not on.
for name in ("_osk_draw", "_osk_erase"):
    reads = {node.func.id for node in ast.walk(nested[name])
             if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)}
    check(f"{name} measures the console's height rather than assuming it",
          "_console_rows" in reads, True)

check("every geometry read sits in a per-draw function -- none is hoisted",
      sorted(node.lineno for node in geometry_calls
             if not any(lo <= node.lineno <= hi for lo, hi in per_draw.items())),
      [])

writes = [node for node in ast.walk(main_def)
          if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
          and node.func.attr == "write_at"]
check("the tty backend has exactly one write_at, so no path escapes the guards",
      len(writes), 1)
check("EVERY write_at names both console guards",
      sorted(node.lineno for node in writes
             if {"console_rows", "console_cols"} -
             {kw.arg for kw in node.keywords}), [])
# A literal here would be the assumption §7 forbids -- 80 is a measurement of
# one console, not a property of all of them.
check("...and the width it names is a read value, never a literal",
      sorted(node.lineno for node in writes for kw in node.keywords
             if kw.arg == "console_cols" and not isinstance(kw.value, ast.Name)),
      [])

draw_calls = {node.func.id for node in ast.walk(draw_def)
              if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)}
draw_attrs = {node.func.attr for node in ast.walk(draw_def)
              if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)}
check("the draw asks rows_for_console what to draw, so the boundary is the "
      "tested one",
      "rows_for_console" in draw_calls, True)

# 🔴 AND IT DRAWS WHAT IT WAS TOLD. Asking and then writing the keyboard anyway
# is the single mutation that reinstates the wrapped-row corruption in full
# while leaving every behavioural test above green.
chosen = next(node for node in ast.walk(draw_def)
              if isinstance(node, ast.Assign) and isinstance(node.value, ast.Call)
              and isinstance(node.value.func, ast.Name)
              and node.value.func.id == "rows_for_console")
chosen_rows = chosen.targets[0].elts[0].id
check("...and writes what it chose, not the keyboard regardless",
      [node.args[1].id for node in writes if isinstance(node.args[1], ast.Name)],
      [chosen_rows])

# The complaint is per DISTINCT width, not once per process and not once per
# draw: a thumb on a pad redraws several times a second, and a console that
# narrows, widens and narrows again has failed twice.
guard = next(node for node in ast.walk(draw_def)
             if isinstance(node, ast.If) and isinstance(node.test, ast.Compare)
             and isinstance(node.test.left, ast.Name)
             and node.test.left.id == "osk_narrow_at")
check("the too-narrow complaint is keyed on the width, not on having said it once",
      [c.id for c in guard.test.comparators if isinstance(c, ast.Name)], ["cols"])
check("...and the state is re-armed when the console fits again",
      sum(1 for node in ast.walk(draw_def) if isinstance(node, ast.Name)
          and node.id == "osk_narrow_at" and isinstance(node.ctx, ast.Store)), 2)
check("...over a cleared region, so half a keyboard does not survive under it",
      "clear_at" in draw_attrs, True)
check("...decided by measuring the render against the console, not by guessing",
      "width" in draw_attrs, True)
# 🔴 The decision this file makes, pinned so it cannot be quietly reversed: a
# width reading must not disable the installer's only keyboard for the session.
check("...and NEVER by falling back -- that would be terminal on the tty backend",
      "osk_fall_back" in draw_calls, False)

# =============================================================================
# T4 §2.3 -- `--osk-start-shown` and the machine-readable "bound" line
# =============================================================================
#
# 🔴 WHAT MAKES THESE TESTS WORTH ANYTHING. `deck-form.sh` waits up to 5 s
# for BOUND_MARKER and then starts typing a Wi-Fi passphrase into a MASKED
# field. Two failures are therefore possible and only one of them is obvious:
#
#   never printing it   -> the prompt degrades loudly after 5 s. Annoying,
#                          visible, and already handled by the consumer.
#   printing it EARLY   -> the consumer types into a device that is not
#                          reading its pad yet, or onto a screen with no
#                          keyboard drawn. Nothing complains, on either side.
#
# The second is the one this project keeps shipping (docs/PROGRESS.md §5.30c:
# "every pointer test drove one axis, which is exactly why the suite stayed
# green while the cursor was unusable"), so the checks below are split to catch
# it two independent ways: the STATE machine refuses to call an undrawn
# keyboard ready, and the ORDER of main()'s statements is pinned so the report
# cannot drift above the show or above the selector registration.

# --- the state machine, behaviourally ----------------------------------------

check("no keyboard asked for -> ready, and said to be navigation only",
      m.osk_state_at_bind(False, "tty", visible=False, usable=False),
      m.OSK_NOT_ASKED)
# ...and `want` decides that ALONE. A mapper started without --osk-start-shown
# is ready as soon as it is bound, whatever the keyboard happens to be doing.
check("...whatever the keyboard is doing",
      {m.osk_state_at_bind(False, backend, visible=v, usable=u)
       for backend in ("dbus", "tty", "layer", "none")
       for v in (True, False) for u in (True, False)},
      {m.OSK_NOT_ASKED})

check("asked for, drawn, and believed -> the strong promise",
      m.osk_state_at_bind(True, "tty", visible=True, usable=True), m.OSK_DRAWN)
# 🔴 THE "TOO EARLY" CASE, and it is the whole point of taking two inputs.
# Reporting before `set_osk_visible(True)` runs leaves `visible` False with the
# machinery perfectly healthy -- a state that reads as "fine" from every
# direction except the screen the user is looking at.
check("asked for but not shown YET -> not ready (the too-early case)",
      m.osk_state_at_bind(True, "tty", visible=False, usable=True),
      m.OSK_MISSING)
# ...and the mirror: `set_osk_visible(True)` sets `osk_visible` unconditionally,
# including when the tty backend was disabled before it ran, so believing the
# flag alone is how a mapper claims a keyboard it never drew.
check("shown according to us, but nothing can draw -> not ready",
      m.osk_state_at_bind(True, "tty", visible=True, usable=False),
      m.OSK_MISSING)
check("...same for a layer keyboard whose overlay died",
      m.osk_state_at_bind(True, "layer", visible=True, usable=False),
      m.OSK_MISSING)
# `osk_fall_back` degrades the tty backend to "none" at RUNTIME, after argparse
# has long since accepted the flags. A re-bind report must notice.
check("...and for a backend that degraded to none while running",
      m.osk_state_at_bind(True, "none", visible=True, usable=False),
      m.OSK_MISSING)
check("squeekboard is REQUESTED, never confirmed -- and says so",
      m.osk_state_at_bind(True, "dbus", visible=True, usable=False),
      m.OSK_DISPATCHED)

# --- the report lines --------------------------------------------------------

for state, want_marker in ((m.OSK_NOT_ASKED, True), (m.OSK_DRAWN, True),
                           (m.OSK_DISPATCHED, True), (m.OSK_MISSING, False)):
    lines = m.bound_report("/dev/input/event7", "Valve Steam Deck", state)
    check(f"{state}: exactly one line, so a consumer's grep is unambiguous",
          len(lines), 1)
    check(f"{state}: the marker is {'present' if want_marker else 'ABSENT'}",
          any(m.BOUND_MARKER in line for line in lines), want_marker)
    # The device is named on every path INCLUDING the refusal -- "not ready" is
    # useless in a journal if it does not say which node it is not ready on.
    check(f"{state}: names the node and the device",
          all("/dev/input/event7" in line and "Valve Steam Deck" in line
              for line in lines), True)

# 🔴 THE SUBSTRING TRAP. The consumer greps with `grep -F`, so any wording that
# happens to contain the marker turns the refusal into a false "ready" --
# "bound to the pad but the keyboard is missing" would do exactly that. This is
# the single most likely way a future edit to that sentence breaks the contract
# without touching a line of logic.
missing_line = m.bound_report("/dev/input/event7", "Valve Steam Deck",
                              m.OSK_MISSING)[0]
check("the refusal cannot be mistaken for the marker by a fixed-string grep",
      m.BOUND_MARKER in missing_line, False)
check("...and it says what still works, so it is a degradation and not a crash",
      "avigation" in missing_line, True)

# --- the marker string itself, and the consumer that greps for it ------------

check("the marker is anchored at the start of its line",
      m.bound_report("/dev/x", "y", m.OSK_DRAWN)[0].startswith(m.BOUND_MARKER),
      True)
# The re-bind line has always existed and must NOT read as a readiness signal:
# "re-bound" does not contain "bound" with the prefix attached, and that near
# miss is load-bearing rather than lucky.
check("the long-standing re-bind line is not mistaken for the marker",
      m.BOUND_MARKER in "deck-input-mapper: re-bound to /dev/input/event7 (x)",
      False)

# 🔴 CROSS-FILE, and the reason this check is in the PRODUCER's suite as well as
# the consumer's: these are two files in two languages that must spell one
# string identically, and whichever suite the next editor runs has to go red.
# Repointed 2026-08-12 (T5e): deck-form.sh moved to its SHIPPED path inside the
# ISO overlay (iso/bin/build rsyncs overlay/configs/ over the upstream tree, so
# this is /usr/share/omarchy-iso/deck-form.sh on the ISO). One copy, no src/
# duplicate -- read_text() raising FileNotFoundError is the intended, loud
# failure if that ever stops being true.
DECK_FORM_SH = (REPO_ROOT / "iso" / "overlay" / "configs" / "airootfs"
                / "usr" / "share" / "omarchy-iso" / "deck-form.sh")
form_sh = DECK_FORM_SH.read_text()
form_marker = next(
    (line.split("=", 1)[1].strip().strip('"')
     for line in form_sh.splitlines()
     if line.startswith("readonly DECK_OSK_BOUND_MARKER=")), None)
check("deck-form.sh still declares the marker this suite can find",
      form_marker is not None, True)
check("...and it is spelled EXACTLY as the mapper prints it",
      form_marker, m.BOUND_MARKER)
# The flags deck-form.sh spawns the mapper with must be flags the mapper has.
# A rename here is silent on both sides: argparse rejects the argv, the mapper
# exits 2, and deck-form.sh sees only a marker that never came.
form_args = next(
    (line for line in form_sh.splitlines()
     if line.startswith("readonly -a DECK_MAPPER_ARGS=")), "")
check("deck-form.sh's mapper argv is still the one this file parses",
      sorted(word.split("=")[0] for word in form_args.split("(", 1)[-1]
             .rstrip(")").split() if word.startswith("--")),
      ["--osk-backend", "--osk-start-shown"])

# --- argparse: the contradiction is refused, loudly --------------------------

import contextlib as _contextlib   # noqa: E402 -- block-local, like the others
import io as _io                   # noqa: E402


class _Reached(Exception):
    """`main()` got past argument handling. Raised instead of touching a real
    device -- this suite has no pad, and pick_device WAITS for one."""


def parsed(argv: list[str]):
    """Run main()'s argument handling only. Returns (exception, stderr).

    ⚠️ `raised()` above is deliberately not reused: it catches `Exception`, and
    argparse refuses by raising `SystemExit`, which is a BaseException. Using it
    here made this whole block exit(2) silently mid-run -- a suite that stops
    early looks a lot like a suite that passed.
    """
    saved_argv, saved_pick = sys.argv, m.pick_device
    sys.argv = ["deck-input-mapper", *argv]
    m.pick_device = lambda selector: (_ for _ in ()).throw(_Reached())
    err = _io.StringIO()
    try:
        with _contextlib.redirect_stderr(err):
            try:
                m.main()
            except BaseException as exc:   # noqa: BLE001 -- SystemExit included
                return exc, err.getvalue()
        return None, err.getvalue()
    finally:
        sys.argv, m.pick_device = saved_argv, saved_pick


exc, err = parsed(["--osk-backend=none", "--osk-start-shown"])
check("--osk-start-shown with --osk-backend=none is REFUSED, not reconciled",
      isinstance(exc, SystemExit), True)
check("...with argparse's usage exit status", getattr(exc, "code", None), 2)
check("...naming BOTH halves of the contradiction, on stderr",
      all(flag in err for flag in ("--osk-start-shown", "--osk-backend=none")),
      True)
# The order of the two flags on the command line must not decide whether the
# contradiction is seen -- it is a property of the parsed arguments.
exc, _ = parsed(["--osk-start-shown", "--osk-backend=none"])
check("...whichever order they were given in", isinstance(exc, SystemExit), True)

exc, _ = parsed(["--osk-backend=tty", "--osk-start-shown"])
check("--osk-start-shown with a real backend is accepted",
      isinstance(exc, _Reached), True)
# Idempotent: `store_true` twice is the same argv as once. A wrapper that
# appends the flag to a command line that already carries it must not fail.
exc, _ = parsed(["--osk-backend=tty", "--osk-start-shown", "--osk-start-shown"])
check("...and repeating it changes nothing (idempotent flags)",
      isinstance(exc, _Reached), True)
exc, _ = parsed(["--osk-backend=none"])
check("--osk-backend=none on its own is still perfectly legal",
      isinstance(exc, _Reached), True)

# --- a REAL main() run, start to finish --------------------------------------
#
# 🔴 EVERYTHING ELSE IN THIS BLOCK TESTS A PIECE. This runs the actual `main()`
# -- its argument handling, its device setup, its uinput, its selector, one
# pass of its loop and its teardown -- with a pad-shaped object on a real pipe
# and the keyboard drawn into a real file. Only three things are replaced
# (`pick_device`, `UInput`, and which copy of `deck_osk_tty` gets loaded, so the
# draw can be timestamped); the ordering under test is main()'s own.
#
# It exists because the ordering checks below are read off the source tree, and
# a source-shaped check cannot see a `set_osk_visible` that returns without
# drawing. Here the marker and the draw land in ONE recording, in the order they
# actually happened, so "printed the marker too early" is a failed assertion
# rather than an argument about the AST.

import evdev as _evdev   # noqa: E402 -- block-local, like the others


class LivePad:
    """A pad-shaped object with a REAL fd, so main()'s selector really selects.

    `read()` raises KeyboardInterrupt: main() catches exactly that and runs its
    teardown, which is how one pass of an infinite loop is a unit test.
    """

    def __init__(self, path="/dev/input/event9", name="Valve Steam Deck fake"):
        self.path, self.name = path, name
        self._r, self._w = os.pipe()
        self.fd = self._r
        self.reads = 0

    def capabilities(self):
        info = _evdev.AbsInfo(value=0, min=-32767, max=32767, fuzz=0, flat=0,
                              resolution=0)
        axes = sorted({*m.STICK_AXES, *m.POINTER_AXES, *osk_mod.PAD_AXES})
        return {e.EV_KEY: [e.BTN_SOUTH], e.EV_ABS: [(c, info) for c in axes]}

    def wake(self):
        os.write(self._w, b"\0")

    def read(self):
        self.reads += 1
        raise KeyboardInterrupt

    def close(self):
        os.close(self._r)
        os.close(self._w)


class FakeUInput:
    def __init__(self, *args, **kwargs):
        self.closed = False

    def write(self, *args):
        pass

    def syn(self):
        pass

    def close(self):
        self.closed = True


class Tape:
    """A stderr-shaped recorder that shares ONE timeline with the OSK's draws."""

    def __init__(self, log):
        self.log = log

    def write(self, text):
        if text.strip():
            self.log.append(("stderr", text))
        return len(text)

    def flush(self):
        pass


def run_main(argv, osk_tty_path):
    """One whole main() run. Returns (timeline, what the tty got, the pad)."""
    timeline = []
    pad = LivePad()
    pad.wake()   # so the first select() returns at once and the loop ends
    tty_module = m._load_module("deck_osk_tty")
    real_write_at = tty_module.write_at

    def spy_write_at(*args, **kwargs):
        timeline.append(("draw", None))
        return real_write_at(*args, **kwargs)

    tty_module.write_at = spy_write_at
    saved = (sys.argv, m.pick_device, m.UInput, m._load_module)
    sys.argv = ["deck-input-mapper", f"--osk-tty={osk_tty_path}", *argv]
    m.pick_device = lambda selector: pad
    m.UInput = FakeUInput
    m._load_module = (lambda name, _real=saved[3]:
                      tty_module if name == "deck_osk_tty" else _real(name))
    try:
        with _contextlib.redirect_stderr(Tape(timeline)):
            m.main()
    finally:
        sys.argv, m.pick_device, m.UInput, m._load_module = saved
        tty_module.write_at = real_write_at
        pad.close()
    target = pathlib.Path(osk_tty_path)
    drawn = target.read_text() if target.is_file() else ""
    return timeline, drawn, pad


def marker_index(timeline) -> int:
    return next((i for i, (kind, text) in enumerate(timeline)
                 if kind == "stderr" and m.BOUND_MARKER in text), -1)


import tempfile as _tempfile   # noqa: E402

with _tempfile.TemporaryDirectory() as _tmp:
    console = pathlib.Path(_tmp) / "console"

    # 1. THE INSTALLER'S OWN COMMAND LINE, exactly as deck-form.sh spawns it.
    timeline, drawn, pad = run_main(["--osk-backend=tty", "--osk-start-shown"],
                                    str(console))
    i_marker = marker_index(timeline)
    check("a real main() run prints the marker on stderr", i_marker >= 0, True)
    i_draw = next((i for i, (kind, _) in enumerate(timeline) if kind == "draw"), -1)
    check("...having actually drawn the keyboard first, in one timeline",
          0 <= i_draw < i_marker, True)
    # The draw is a real one: the keyboard's own glyphs reached the console.
    check("...and what it drew is the keyboard, not an empty frame",
          all(label in drawn for label in ("Backspace", "Shift", "space")), True)
    # ...and the loop really was entered: the marker is printed on the way IN
    # to select(), so a run that never got there would still have printed it.
    check("...and the loop was entered, so this is a run and not a setup",
          pad.reads, 1)

    # 2. THE DEGRADE PATH, run for real: an unopenable console. `--osk-tty` at a
    #    DIRECTORY is the cheapest honest stand-in for the three ways the tty
    #    keyboard fails to come up on the ISO. Nothing is drawn, so nothing may
    #    be promised -- and deck-form.sh's five-second timeout is what turns
    #    this into the visible degradation §2.3 asks for.
    timeline, _, _ = run_main(["--osk-backend=tty", "--osk-start-shown"], _tmp)
    check("an OSK that cannot be drawn gets NO marker, from a real run",
          marker_index(timeline), -1)
    check("...and says so, naming the keyboard and what still works",
          any(kind == "stderr" and "NOT reporting ready" in text
              for kind, text in timeline), True)
    check("...and nothing was drawn to claim otherwise",
          [kind for kind, _ in timeline if kind == "draw"], [])

    # 3. Navigation only: no keyboard was asked for, so being bound IS ready.
    console2 = pathlib.Path(_tmp) / "console2"
    timeline, drawn, _ = run_main(["--osk-backend=tty"], str(console2))
    check("without --osk-start-shown the mapper is ready as soon as it is bound",
          marker_index(timeline) >= 0, True)
    check("...and no keyboard was drawn uninvited",
          [kind for kind, _ in timeline if kind == "draw"], [])

# --- the wiring in main(), enforced against the SOURCE ------------------------
#
# Everything above tests functions main() CALLS. None of it can see main()
# calling them in the wrong order, or from the wrong place -- and the ordering
# IS the contract here, exactly as it is for the lift gate and the §5.28
# resolver above.

marker_loads = [node for node in ast.walk(tree)
                if isinstance(node, ast.Name) and node.id == "BOUND_MARKER"
                and isinstance(node.ctx, ast.Load)]
report_def = next(node for node in ast.walk(tree)
                  if isinstance(node, ast.FunctionDef) and node.name == "bound_report")
check("BOUND_MARKER is produced in exactly one function, so 'ready' has one "
      "definition",
      [node.lineno for node in marker_loads
       if not report_def.lineno <= node.lineno <= report_def.end_lineno], [])
# ...and nothing anywhere else spells it out as a literal and sidesteps that.
check("...and no other string in the file spells the marker out by hand",
      [node.lineno for node in ast.walk(tree)
       if isinstance(node, ast.Constant) and isinstance(node.value, str)
       and "deck-input-mapper: bound" in node.value
       and node.lineno != next(n.lineno for n in ast.walk(tree)
                               if isinstance(n, ast.Assign)
                               and any(isinstance(t, ast.Name) and t.id == "BOUND_MARKER"
                                       for t in n.targets))],
      [])

report_calls = [node for node in ast.walk(main_def)
                if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
                and node.func.id == "report_bound"]
check("main() reports bound at exactly two points -- startup and the re-bind",
      len(report_calls), 2)
check("...and both go through the one report builder",
      len([node for node in ast.walk(main_def)
           if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
           and node.func.id == "bound_report"]), 1)
# 🔴 The re-bind's argument is the CAPTURED state, never a constant. `True`
# here forces a keyboard back onto a user who dismissed it and then calls a
# missing one a failure; `False` reports ready with the keyboard torn down.
check("...each asked what SHOULD be on screen, from a variable not a literal",
      sorted(ast.unparse(node.args[0]) for node in report_calls),
      ["args.osk_start_shown", "osk_was_visible"])


def body_index(body, pred) -> int:
    """Where in a statement list the statement containing `pred` sits. -1 if
    absent -- which fails the comparisons below rather than raising.

    ⚠️ NESTED `def`s ARE SKIPPED. main() defines ~20 closures before it runs a
    single statement, and several of them call `set_osk_visible` and
    `sel.register`. Counting those made every ordering check below trivially
    true (a definition near the top of main() precedes everything), which is a
    check that cannot fail -- caught here by writing the mutation first.
    """
    for index, stmt in enumerate(body):
        if isinstance(stmt, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            continue
        if any(pred(node) for node in ast.walk(stmt)):
            return index
    return -1


def calls(name):
    return lambda node: (isinstance(node, ast.Call)
                         and isinstance(node.func, ast.Name)
                         and node.func.id == name)


def calls_attr(name, on=None):
    return lambda node: (isinstance(node, ast.Call)
                         and isinstance(node.func, ast.Attribute)
                         and node.func.attr == name
                         and (on is None or (isinstance(node.func.value, ast.Name)
                                             and node.func.value.id == on)))


def calls_with(name, first_arg):
    """`name(first_arg, ...)` specifically. The ENODEV branch both HIDES and
    SHOWS the keyboard, so "a statement mentioning set_osk_visible" cannot tell
    the two apart -- and an ordering check that cannot tell them apart passed a
    mutation that redrew the keyboard from the dead pad's axis ranges."""
    return lambda node: (isinstance(node, ast.Call)
                         and isinstance(node.func, ast.Name)
                         and node.func.id == name and node.args
                         and ast.unparse(node.args[0]) == first_arg)


# STARTUP. `sel.register(pad.fd, ...)` is what makes the pad's events reachable
# at all; a marker above it is T4-screen-spec.md §6.4 lie #2 (a bound-looking,
# silent input path) printed by us rather than merely tolerated.
top = main_def.body
i_register = body_index(top, calls_attr("register", on="sel"))
i_show = body_index(top, calls_with("set_osk_visible", "True"))
i_report = body_index(top, calls("report_bound"))
check("the startup report comes AFTER the pad's fd is in the selector",
      i_register != -1 and i_report > i_register, True)
check("...and AFTER the start-shown keyboard has been drawn",
      i_show != -1 and i_report > i_show, True)
# ...and that show is the one --osk-start-shown asked for, not an unconditional
# one that would open a keyboard on every Desktop Mode boot.
start_show = top[i_show]
check("...which is drawn only when --osk-start-shown asked for it",
      isinstance(start_show, ast.If)
      and "osk_start_shown" in ast.unparse(start_show.test), True)

# THE RE-BIND, in the ENODEV handler. Same three orderings, and one more: the
# replacement pad's axis ranges must be in place before the keyboard is redrawn
# from them.
handler = next(node for node in ast.walk(main_def)
               if isinstance(node, ast.ExceptHandler)
               and any(calls("pick_device")(sub) for sub in ast.walk(node)))
hb = handler.body
i_pick = body_index(hb, calls("pick_device"))
i_reregister = body_index(hb, calls_attr("register", on="sel"))
i_ranges = body_index(hb, lambda node: isinstance(node, ast.Attribute)
                      and node.attr == "ranges" and isinstance(node.ctx, ast.Store))
i_rehide = body_index(hb, calls_with("set_osk_visible", "False"))
i_reshow = body_index(hb, calls_with("set_osk_visible", "True"))
i_rereport = body_index(hb, calls("report_bound"))
check("the re-bind picks a replacement pad before anything else happens",
      0 <= i_pick < i_reregister, True)
# 🔴 The replacement pad may advertise different axis ranges. Redrawing before
# they are in place puts both cursors where the old device's midpoint was --
# which on a keyboard is a different key, and reads as "the keyboard came back
# wrong" rather than as anything anyone would call a bug.
check("...re-ranges the cursors before the keyboard is put back",
      0 <= i_ranges < i_reshow, True)
check("...and reports bound last of all",
      i_rereport > max(i_reregister, i_ranges, i_reshow), True)
# The hide is the mapper's own (the node is gone); the show is the restore.
# Capturing the state after the hide reads False every time, which silently
# converts "put the keyboard back" into "never".
i_capture = body_index(hb, lambda node: isinstance(node, ast.Name)
                       and node.id == "osk_was_visible"
                       and isinstance(node.ctx, ast.Store))
check("what was on screen is captured BEFORE the mapper's own hide",
      0 <= i_capture < i_rehide, True)
check("...and the restore is conditional on it, not unconditional",
      "osk_was_visible" in ast.unparse(hb[i_reshow]), True)

# `osk_usable` is the half of the state machine no behavioural test can reach --
# it reads main()'s own locals. Pinned by the facts it consults: dropping any
# one of them makes some real, measured failure invisible.
usable_def = next(node for node in ast.walk(main_def)
                  if isinstance(node, ast.FunctionDef) and node.name == "osk_usable")
usable_names = {node.id for node in ast.walk(usable_def)
                if isinstance(node, ast.Name)}
check("osk_usable asks every way the keyboard we draw can be absent",
      sorted({"osk_backend", "osk_tty", "osk_stream", "osk_narrow_at",
              "osk_layer_proc", "osk_drawn_here"} - usable_names), [])
# 🔴 `osk_narrow_at` specifically. A console too narrow for the keyboard draws
# a NOTICE where the keyboard would be (R-49 / §9g) -- the process is healthy,
# the pads commit, and the user types blind. It is the only "on screen" failure
# with nothing broken behind it, and so the easiest one to drop from this list.
check("...including the too-narrow console, where nothing is broken but the "
      "keyboard is still not on the screen",
      "osk_narrow_at" in usable_names, True)
state_calls = [node for node in ast.walk(main_def)
               if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
               and node.func.id == "osk_state_at_bind"]
check("the report asks for BOTH halves -- what we believe and what is true",
      [sorted(kw.arg for kw in node.keywords) for node in state_calls],
      [["usable", "visible"]])
check("...taking `usable` from the live check, not from a placeholder",
      [ast.unparse(kw.value) for node in state_calls for kw in node.keywords
       if kw.arg == "usable"], ["osk_usable()"])

# --- 🆕 every queued action reaches a handler in main() (§5.37) --------------
#
# 🔴 THE DEAD-BUTTON GUARD, AND IT IS THE P32 DEFECT FAMILY'S OWN SHAPE:
# written, unit-tested, documented, never wired. Everything above proves
# translate() QUEUES "close-window"; none of it can see main()'s run_pending
# dispatching on it, and a name with no branch falls through to the "queued
# action has no handler" print -- a button that does nothing, reported once in
# a journal nobody reads.

pending_def = next(node for node in ast.walk(main_def)
                   if isinstance(node, ast.FunctionDef) and node.name == "run_pending")
pending_src = ast.unparse(pending_def)
check("main()'s run_pending dispatches on the close-window action",
      "'close-window'" in pending_src, True)
check("...and reaches the runner that spawns hyprctl",
      [node.func.id for node in ast.walk(pending_def)
       if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
       and node.func.id == "run_close_window"],
      ["run_close_window"])
# ⚠️ Every action name translate() can produce, checked against what
# run_pending answers to. `CHORD_PRESSES` is the table the chord branch reads,
# so a third chord added there without a branch here is caught by this rather
# than by a user pressing it.
check("every chord's action name appears in run_pending",
      sorted(name for name in m.CHORD_PRESSES.values()
             if f"'{name}'" not in pending_src), [])
# --dry-run must reach it too, or `--dry-run` silently starts closing real
# windows -- the emitters above print instead of injecting for the same reason.
check("...and the close honours --dry-run like every other spawn",
      [ast.unparse(kw) for node in ast.walk(pending_def)
       if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
       and node.func.id == "run_close_window" for kw in node.keywords],
      ["dry_run=ui is None"])
# 🆕 The same guard for the launchers, from the other side. The check above
# starts at CHORD_PRESSES; this one starts at LAUNCH_ACTIONS, so a launcher
# added to that table and wired to no branch is caught even if nobody ever binds
# a button to it -- and `--dry-run` must not open real windows either.
check("every launch action reaches a branch in run_pending",
      sorted(name for name in m.LAUNCH_ACTIONS if f"'{name}'" not in pending_src), [])
check("...and reaches the runner that spawns it",
      sorted({node.func.id for node in ast.walk(pending_def)
              if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
              and node.func.id == "run_launch_action"}),
      ["run_launch_action"])
check("...honouring --dry-run like every other spawn",
      [ast.unparse(kw) for node in ast.walk(pending_def)
       if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
       and node.func.id == "run_launch_action" for kw in node.keywords],
      ["dry_run=ui is None"])

# --- 🆕 THE POINTER DISAPPEARS WHILE OUR KEYBOARD IS UP ----------------------
#
# The residual half of the doubled-pointer defect. `--grab` on the unit stopped
# the pad MOVING Hyprland's pointer with the OSK up; the cursor was still DRAWN
# where it had been left, sometimes on top of a key. Motion and visibility are
# two defects and this covers the second.
#
# ⚠️ WHAT IS PINNED HERE IS THE SHAPE, NOT THE SENTENCE. The exact Lua Hyprland
# accepts is its business and can change under us; what this repo owns is that
# the call is `eval` and not `keyword` (0.56.2 rejects `keyword` for a Lua
# config -- docs/PROGRESS.md §7), that the two directions really are different
# commands, and that every failure is loud. Measured live on the Deck
# 2026-08-16: `hyprctl getoption cursor:invisible` reads the flag back, with
# `cursor:deck_nope` -> "no such option" as its negative control, and `eval`
# exits 7 on a key Hyprland does not know.

def say_and_return(fn):
    """Run fn(), returning (result, stderr). Real processes, real output --
    this helper stubs nothing, unlike with_fake_subprocess above."""
    sink = io.StringIO()
    with contextlib.redirect_stderr(sink):
        result = fn()
    return result, sink.getvalue()


_hide = m.cursor_invisible_argv(True)
_show = m.cursor_invisible_argv(False)
check("the pointer is toggled through `hyprctl eval`, never `keyword`",
      (_hide[:2], any("keyword" in part for part in _hide)),
      (["hyprctl", "eval"], False))
check("...with a Lua expression, the only form this Hyprland accepts",
      _hide[-1].startswith("hl.config("), True)
# Hiding and showing must not be the same command. A builder that ignored its
# argument would satisfy every other assertion here and never give the pointer
# back.
check("🔴 hiding and restoring are genuinely different commands",
      _hide != _show, True)
check("...and they differ in the boolean, not in anything else",
      (_hide[-1].replace("true", "?"), _show[-1].replace("false", "?")),
      (_show[-1].replace("false", "?"), _hide[-1].replace("true", "?")))

# The call itself, through real processes -- the same technique read_lock_state
# is tested with, and for the same reason: this one blocks the input loop.
check("a hyprctl that succeeds is reported as success",
      m.set_pointer_hidden(True, argv=(sys.executable, "-c", "pass")), True)
_result, _err = say_and_return(lambda: m.set_pointer_hidden(
    True, argv=(sys.executable, "-c", "pass")))
check("...and says nothing when it worked", _err, "")

_result, _err = say_and_return(lambda: m.set_pointer_hidden(
    False, argv=(sys.executable, "-c",
                 "import sys; sys.stderr.write('unknown config key\\n'); "
                 "sys.exit(7)")))
check("a nonzero hyprctl is a FAILURE, not a shrug", _result, False)
check("...and it is loud about it", "could not" in _err, True)
check("...naming which direction failed, so a stuck pointer is diagnosable",
      "give the pointer back" in _err, True)
check("...and quoting what hyprctl actually said",
      "unknown config key" in _err, True)
# 🔴 The failure must not take the keyboard with it. This is the sentence that
# tells whoever reads the journal that the rest of the mapper is still alive.
check("...and says the keyboard is unaffected", "keyboard is unaffected" in _err, True)

_result, _err = say_and_return(
    lambda: m.set_pointer_hidden(True, argv=("/nonexistent/hyprctl",)))
check("a missing hyprctl does not raise", _result, False)
check("...and is still loud", "could not" in _err, True)

# ⚠️ THE CLOCK, NOT THE ANSWER -- read_lock_state's note applies verbatim. This
# runs inside the input loop of the only input path on the device, so a
# set_pointer_hidden that ignored `timeout` would freeze a handheld.
_started = _time.monotonic()
check("a hyprctl that outlasts the bound fails instead of blocking for ever",
      m.set_pointer_hidden(True, argv=(sys.executable, "-c", "import time; time.sleep(5)"),
                           timeout=0.2),
      False)
check("...and it was CUT OFF at the bound, not merely answered late",
      _time.monotonic() - _started < 2.0, True)

_result, _err = say_and_return(lambda: m.set_pointer_hidden(True, dry_run=True))
check("--dry-run reports instead of running hyprctl, like every other spawn",
      (_result, "hl.config(" in _err), (True, True))

# §5.28 again: hyprctl is dead without HYPRLAND_INSTANCE_SIGNATURE, which this
# service does not inherit. The AST sweep above enforces that every subprocess
# call NAMES an env; this pins that the default is the resolver.
_marked = (sys.executable, "-c",
           f"import os, sys; sys.exit(0 if os.environ.get({MARK!r}) else 3)")
check("the pointer toggle runs with the RESOLVED session environment",
      m.set_pointer_hidden(True, argv=_marked, env={**os.environ, MARK: "1"}), True)
check("...and its default is the resolver, not a bare inherit",
      say_and_return(lambda: m.set_pointer_hidden(True, argv=_marked))[0], False)

# --- and the wiring, against the SOURCE --------------------------------------
#
# 🔴 THE WHOLE FIX IS WIRING. Every assertion above passes with
# set_pointer_hidden never called from anywhere -- P32's "written, tested,
# never wired" defect, in a function main() is too large to enter. Each call
# site below is one of the ways the pointer could be stranded; the comment on
# set_pointer_hidden in the source enumerates them.
_pointer_calls = [node for node in ast.walk(main_def)
                  if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
                  and node.func.id == "set_pointer_hidden"]
check("main() actually calls it -- at least show/hide, fallback, startup, exit",
      len(_pointer_calls) >= 4, True)

_visible_def = next(node for node in ast.walk(main_def)
                    if isinstance(node, ast.FunctionDef) and node.name == "set_osk_visible")
check("🔴 showing or hiding the keyboard toggles the pointer with it",
      any(isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
          and node.func.id == "set_pointer_hidden"
          for node in ast.walk(_visible_def)), True)

# The overlay dying does NOT go through set_osk_visible. Without a restore
# here, a crashed keyboard leaves a Deck with no cursor and hands over to
# squeekboard, which is a keyboard you drive WITH the cursor.
_fallback_def = next(node for node in ast.walk(main_def)
                     if isinstance(node, ast.FunctionDef) and node.name == "osk_fall_back")
check("🔴 the fallback to squeekboard gives the pointer back first",
      any(isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
          and node.func.id == "set_pointer_hidden"
          for node in ast.walk(_fallback_def)), True)

# The exit path. `finally` is what covers a normal stop AND the SIGTERM below;
# a restore written anywhere else in main() is skipped by every early exit.
_finally_calls = [node for handler in ast.walk(main_def)
                  if isinstance(handler, ast.Try)
                  for node in ast.walk(ast.Module(body=handler.finalbody, type_ignores=[]))
                  if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
                  and node.func.id == "set_pointer_hidden"]
check("🔴 a `finally` restores it, so no ordinary exit can strand the pointer",
      len(_finally_calls) >= 1, True)

# 🔴 AND THE SIGNAL THAT WOULD OTHERWISE SKIP THAT `finally`. SIGTERM's default
# disposition kills the process without unwinding, and SIGTERM is how this
# service is normally stopped, restarted, and ended with the session. Without a
# handler the restore above is dead code on the path that matters most.
_sigterm = [node for node in ast.walk(main_def)
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
            and node.func.attr == "signal"
            and isinstance(node.func.value, ast.Name) and node.func.value.id == "signal"]
check("🔴 SIGTERM is turned into an unwind, so `finally` runs on a normal stop",
      [ast.unparse(node.args[0]) for node in _sigterm], ["signal.SIGTERM"])

# ⚠️ IT MIRRORS, IT DOES NOT COUNT. A counter would fall out of balance on
# "show, show, hide" and leave the pointer hidden; the source's own comment
# says so, and this pins that the show/hide call takes a boolean EXPRESSION of
# the visible flag rather than a bare literal that could only ever hide.
_visible_args = [ast.unparse(node.args[0]) for node in ast.walk(_visible_def)
                 if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
                 and node.func.id == "set_pointer_hidden"]
check("...and the show/hide call is driven by `visible`, never a bare True",
      [arg for arg in _visible_args if "visible" in arg], _visible_args)

print(f"\n{'PASS' if FAILURES == 0 else 'FAILED'} — {FAILURES} failure(s)")
sys.exit(1 if FAILURES else 0)
