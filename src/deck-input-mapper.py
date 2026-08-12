#!/usr/bin/env python3
"""deck-input-mapper -- gamepad -> keyboard events at the kernel input layer.

T2's prototype (TASK-T2, PLAN.md 6.1), and the intended shipping mechanism for
both the controller-only installer (T4) and Desktop Mode navigation (T3, R1
10.3 design (b)).

WHAT IT DOES
    Reads a gamepad's evdev node and emits keyboard events through a uinput
    virtual keyboard. The kernel delivers those to whatever owns the active
    VT or the compositor focus -- archinstall's TUI, gum prompts, or a
    desktop app. Nothing under test knows a controller exists; that is the
    whole point (one mapping layer drives every UI).

THE INSTALLER PROFILE (deliberately small)
    d-pad / left stick   arrow keys (auto-repeat while held)
    A (BTN_SOUTH)        Enter        confirm
    B (BTN_EAST)         Esc          back/cancel
    Y (BTN_WEST)         Space        toggle (archinstall multi-select)
    X (BTN_NORTH)        Tab          next field
    L1 / R1              PageUp/Down  long lists
    Start / Select       Enter / Esc  mirrors, controller-menu convention

DESKTOP MODE ADDS TWO BUTTONS (docs/PROGRESS.md §5.23)
    STEAM (tap, no chord)  `omarchy-menu toggle apps`  the apps menu
    STEAM + X              the on-screen keyboard      (unchanged)
    QAM                    `omarchy-menu toggle`       Omarchy's own menu
                           -- INERT until QAM's evdev code is measured

    Both need lizard_mode=N, or the firmware swallows the presses and no evdev
    node ever sees them. Startup says which of those is in force.

    --osk-auto-show   additionally opens the keyboard when a text field takes
                      focus, and closes it when focus leaves. OFF by default:
                      it needs the Wayland input-method seat, which costs
                      fcitx5 its Wayland-native clients (R-51). The chord works
                      with or without it, and outlives it if it fails.

    The `layer` backend also auto-HIDES itself once the session it was shown
    across UNLOCKS (docs/PROGRESS.md §5.24a request 3). This is always on for
    that backend, no flag: unlike auto-show it costs nobody's Wayland seat, it
    only ever hides a keyboard the user already asked for, and getting it
    wrong in the direction of "stays up a little longer" is the ONLY safe
    direction -- STEAM+X still dismisses it by hand either way. See
    `LockWatcher` for the mechanism and why it cannot fire on LOCK.

    Text entry is DELIBERATELY absent: free text comes from an on-screen
    keyboard (squeekboard) under a compositor, or from a TUI-native picker --
    that fork is exactly what FINDING-T2-gamepad-spike.md decides. A nav-only
    profile keeps every key here semantically safe to hold down.

PERMISSIONS
    In the live ISO and in VM tests this runs as root: no ceremony. On an
    installed desktop it needs read on the pad's evdev node (seat ACL grants
    it -- verified on hardware, FINDING-R1-10.3) and write on /dev/uinput
    (udev rule + the user in the `input` group; `uaccess` alone does NOT
    cover uinput -- same finding).

USAGE
    deck-input-mapper.py --list
    deck-input-mapper.py [--device SUBSTRING|/dev/input/eventN] [--grab]
    deck-input-mapper.py --dry-run ...   print emissions instead of injecting
"""

from __future__ import annotations

import argparse
import errno
import importlib.util
import json
import os
import pathlib
import selectors
import shlex
import subprocess
import sys
import time
from dataclasses import dataclass, field

from evdev import InputDevice, UInput, ecodes as e, list_devices

# --- the on-screen keyboard's layout core (T8) -------------------------------
#
# Imported rather than copied. OSK_KEYCODES decides which keycodes this
# process's uinput device DECLARES, and a uinput device emits only what it
# declared at creation -- an undeclared code is dropped by the kernel with no
# error anywhere. A second copy of that list here would drift from the layouts
# and take character keys down silently.
#
# The two files sit side by side in `src/` and are installed side by side by
# `deck-session.sh stage-input-mapper`: the script in /usr/local/bin, the module
# in /usr/local/lib/deck-osk.
#
# ⚠️ A MISSING CORE IS LOUD BUT NOT FATAL, and that is deliberate. With
# lizard_mode=N this process is the ONLY input path on the device
# (docs/PROGRESS.md §5.9); refusing to start would leave a handheld with no
# pointer and no keys, recoverable only over SSH. Navigation keeps working and
# the OSK is what is lost -- the same trade the DBus OSK toggle already makes.

_OSK_MODULE = "deck_osk_layout.py"
_HERE = pathlib.Path(__file__).resolve().parent
OSK_SEARCH_DIRS = (
    _HERE,                                  # src/, and any dev run
    _HERE.parent / "lib" / "deck-osk",      # /usr/local/bin -> /usr/local/lib
)


def _load_module(name: str):
    """Import an OSK module by name, or say loudly why the OSK is unavailable.

    Registered in sys.modules under its own name, because the modules import
    each other by name -- `deck_osk_tty` does `import deck_osk_layout`, and it
    must get the copy loaded from beside this script rather than searching the
    system path for a different one.
    """
    for directory in OSK_SEARCH_DIRS:
        path = directory / f"{name}.py"
        if not path.is_file():
            continue
        try:
            spec = importlib.util.spec_from_file_location(name, path)
            module = importlib.util.module_from_spec(spec)
            sys.modules[name] = module
            spec.loader.exec_module(module)
            return module
        except Exception as exc:  # a broken module must not cost us navigation
            print(f"deck-input-mapper: {path} failed to import ({exc}); "
                  "the on-screen keyboard is DISABLED, navigation still works",
                  file=sys.stderr, flush=True)
            return None
    print(f"deck-input-mapper: {name}.py not found in "
          f"{', '.join(str(d) for d in OSK_SEARCH_DIRS)}; the on-screen keyboard "
          "is DISABLED, navigation still works",
          file=sys.stderr, flush=True)
    return None


def _find_module_path(name: str) -> pathlib.Path | None:
    """Where an OSK module lives, or None. Used for the ones we RUN rather than
    import -- the layer-shell renderer is a separate process on purpose."""
    for directory in OSK_SEARCH_DIRS:
        path = directory / f"{name}.py"
        if path.is_file():
            return path
    return None


def _load_osk_layout():
    """The layout core. Loaded at import time: it decides EMITTED_KEYS."""
    return _load_module("deck_osk_layout")


osk_layout = _load_osk_layout()

# --- the mapping tables ------------------------------------------------------

BUTTON_MAP: dict[int, int] = {
    e.BTN_SOUTH: e.KEY_ENTER,
    e.BTN_EAST: e.KEY_ESC,
    e.BTN_WEST: e.KEY_SPACE,
    e.BTN_NORTH: e.KEY_TAB,
    e.BTN_TL: e.KEY_PAGEUP,
    e.BTN_TR: e.KEY_PAGEDOWN,
    e.BTN_START: e.KEY_ENTER,
    e.BTN_SELECT: e.KEY_ESC,
}

# ⚠️ THESE ARE INTERNAL AXIS IDENTIFIERS, NOT DEVICE AXES.
#
# ABS_HAT0X/Y are reused here purely as names for "horizontal direction" and
# "vertical direction", because the d-pad and both sticks all resolve onto them
# and must share one held-direction state.
#
# On the Deck's own pad those codes mean something completely different --
# ABS_HAT0X/Y is the LEFT TRACKPAD (measured 2026-08-10: sliding it moved
# ABS_HAT0X -1130 / ABS_HAT0Y 2408, full +/-32767 analog range). Feeding device
# ABS_HAT0* events in here as if they were a d-pad emits arrow keys for a
# thumb resting on the trackpad. DEVICE_AXES below is the authority on what the
# hardware actually sends; nothing routes ABS_HAT0* from the device into these.
HAT_MAP: dict[tuple[int, int], int] = {
    (e.ABS_HAT0X, -1): e.KEY_LEFT,
    (e.ABS_HAT0X, +1): e.KEY_RIGHT,
    (e.ABS_HAT0Y, -1): e.KEY_UP,
    (e.ABS_HAT0Y, +1): e.KEY_DOWN,
}

# --- what the Deck's pad ACTUALLY sends, measured on hardware 2026-08-10 -----
#
# Every one of these was named by a human moving that control while a probe
# watched, not read off a datasheet. The capability list alone is misleading:
# it advertises ABS_HAT0X/Y, which looks like a d-pad and is not.
DECK_LEFT_TRACKPAD = (e.ABS_HAT0X, e.ABS_HAT0Y)
DECK_RIGHT_TRACKPAD = (e.ABS_HAT1X, e.ABS_HAT1Y)
DECK_TRIGGERS = (e.ABS_HAT2X, e.ABS_HAT2Y)  # X is R2, Y is L2; both 0..32767

# The pointer comes from the RIGHT trackpad, matching where a thumb rests and
# what lizard mode does when it is enabled.
POINTER_AXES = {e.ABS_HAT1X: "x", e.ABS_HAT1Y: "y"}

# Trackpads report ABSOLUTE position while touched and nothing while lifted, so
# consecutive samples across a lift would jump the cursor across the screen.
# There is no touch flag we have measured, so a gap longer than this re-baselines.
#
# ⚠️ Deliberately LOOSE. At 0.12s this was the main source of jerkiness: during
# slow movement the pad reports sparsely, gaps exceeded the threshold, and each
# re-baseline silently SWALLOWED that movement. POINTER_JUMP_RAW is what
# actually catches a lift, so this only needs to cover a long pause.
POINTER_TOUCH_GAP = 0.5

# Trackpad units per emitted pixel. Lower is faster. Tuned on hardware with the
# operator moving the cursor and saying how it felt, which is the only way this
# number can be set: 90 unusably slow, 24 and 40 over-sensitive, 80 and 100 still fast, 125 right.
#
# Note the early attempts were judging the wrong thing -- the cursor was
# "jerky" because diagonal movement emitted nothing at all, not because of
# speed. Do not re-tune this without first checking both axes still move.
POINTER_DIVISOR = 125

# Any single-sample jump larger than this is a DISCONTINUITY, not a movement:
# re-baseline and emit nothing.
#
# Measured on hardware 2026-08-10: the cursor "jumped around" because lifting a
# finger makes the pad report 0 (centre), so the release itself looks like a
# swipe from wherever the thumb was all the way to the middle. The touch-gap
# timer alone does not catch it -- a quick lift-and-retouch lands inside the
# gap. Clamping the step catches both, and needs no touch flag we have not
# measured.
#
# The pad spans +/-32767, so a real inter-sample movement is small; anything
# this large is the finger leaving or arriving.
POINTER_JUMP_RAW = 4000

# Mouse buttons, matching lizard mode's own convention so muscle memory carries
# over: right trigger clicks, left trigger context-clicks.
TRIGGER_BUTTON_MAP: dict[int, int] = {
    e.BTN_TR2: e.BTN_LEFT,
    e.BTN_TL2: e.BTN_RIGHT,
}

# STEAM+X toggles the on-screen keyboard. BTN_MODE is the STEAM button and is
# only visible with lizard_mode=N -- with lizard mode on, the firmware swallows
# it and no evdev node ever sees it.
OSK_CHORD_HOLD = e.BTN_MODE
OSK_CHORD_PRESS = e.BTN_NORTH  # physical X

# --- Omarchy's menus on STEAM and QAM (docs/PROGRESS.md §5.23 item 3) --------
#
# Operator request, 2026-08-11, for Desktop Mode: STEAM opens the apps menu and
# QAM opens Omarchy's own menu -- the one at the top-left of the bar.
#
# ⚠️ EXEC'd DIRECTLY, NOT SYNTHESISED AS A KEY CHORD. Emitting SUPER+ALT+SPACE
# would work only while the user's keybinds still say what upstream's defaults
# say, and upstream edited those bindings in this very release cycle; a stale
# binding then does nothing at all, with nothing to read anywhere. Exec'ing
# couples us to `omarchy-menu`'s SUBCOMMAND NAMES instead, which is a narrower
# surface and a loud one -- a wrong subcommand exits non-zero and says so.
#
# Both commands were measured from upstream quattro's
# default/hypr/bindings/utilities.lua on 2026-08-11:
#
#     apps menu             omarchy-menu toggle apps   (stock SUPER + ALT + SPACE)
#     the bar's own menu    omarchy-menu toggle        (stock SUPER + SPACE)
#
# Nothing here adds a keycode, so EMITTED_KEYS is deliberately untouched: these
# buttons spawn a process, they do not type.
OMARCHY_MENU = "omarchy-menu"
MENU_ACTIONS: dict[str, list[str]] = {
    "menu-apps": [OMARCHY_MENU, "toggle", "apps"],
    "menu-root": [OMARCHY_MENU, "toggle"],
}

# ✅ MEASURED ON HARDWARE 2026-08-11: QAM is BTN_BASE (294), on the "Steam Deck"
# node (/dev/input/event7), with lizard_mode=N.
#
# The capture bracketed two QAM presses between two BTN_SOUTH presses, so the
# attribution is not inference -- 304, 294, 294, 304, then 316 (BTN_MODE, STEAM).
# docs/PROGRESS.md §7 carries the measurement beside the other button facts.
#
# ⚠️ The name is another entry in this hardware's list of misleading labels, like
# the trackpads that report as hats. BTN_BASE is nominally a joystick base
# button; nothing about the name says "quick access menu". Do not "correct" it.
#
# ⚠️ Two of the four enumerated nodes were COMPLETELY SILENT during that capture
# (event5 and event6, both named "Valve Software Steam Controller"). A probe that
# picks one node and waits would have reported QAM as dead. That is R-29's exact
# failure shape; the probe that answered this watched every node at once and
# labelled the source. Reuse that approach, not a single-node read.
QAM_BUTTON: int | None = 294

# Where the knob that makes STEAM and QAM exist at all lives. Read only to
# REPORT it (docs/PROGRESS.md §5.21 owns setting it); with lizard mode on, both
# buttons reach no evdev node and neither binding can possibly fire.
LIZARD_MODE_PATH = "/sys/module/hid_steam/parameters/lizard_mode"

# The Deck's d-pad arrives as DISCRETE BUTTONS. `hid-steam` advertises
# ABS_HAT0X/Y *and* BTN_DPAD_*, and (as above) those axes are the left
# trackpad, so the buttons are the only d-pad input there is. Before this table
# the d-pad fell through BUTTON_MAP and emitted nothing at all. Route it onto
# the internal axes so a d-pad press and a stick push cannot double-hold one
# direction.
DPAD_BUTTON_MAP: dict[int, tuple[int, int]] = {
    e.BTN_DPAD_UP: (e.ABS_HAT0Y, -1),
    e.BTN_DPAD_DOWN: (e.ABS_HAT0Y, +1),
    e.BTN_DPAD_LEFT: (e.ABS_HAT0X, -1),
    e.BTN_DPAD_RIGHT: (e.ABS_HAT0X, +1),
}

STICK_AXES: dict[int, int] = {e.ABS_X: e.ABS_HAT0X, e.ABS_Y: e.ABS_HAT0Y}

# Stick thresholds as fractions of half-range, with hysteresis so jitter at
# the edge cannot machine-gun key events: engage past 0.5, release under 0.35.
STICK_ENGAGE = 0.5
STICK_RELEASE = 0.35

# Held-direction auto-repeat, tuned to console feel.
REPEAT_DELAY = 0.40
REPEAT_INTERVAL = 0.15

# ⚠️ The uinput device declares exactly this set, and emits NOTHING else -- the
# kernel drops an undeclared code without an error. Every character key the OSK
# can type therefore has to be in here before a renderer ever draws it, which is
# why the layout core is imported at module load rather than when the OSK opens.
EMITTED_KEYS = sorted(
    set(BUTTON_MAP.values())
    | set(HAT_MAP.values())
    | set(TRIGGER_BUTTON_MAP.values())
    | (set(osk_layout.OSK_KEYCODES) if osk_layout else set())
)
EMITTED_RELS = [e.REL_X, e.REL_Y]

# Which half each trigger clicks, when the OSK is up. Empty without the layout
# core, which is what makes a missing core cost the keyboard and nothing else.
TRIGGER_HALF: dict[int, str] = dict(osk_layout.TRIGGER_HALF) if osk_layout else {}

# Toggling squeekboard is a DBus call, not an input event. Kept as an argv
# rather than a shell string so nothing here goes through a shell.
OSK_TOGGLE_ARGV_SHOW = [
    "busctl", "--user", "call", "sm.puri.OSK0", "/sm/puri/OSK0",
    "sm.puri.OSK0", "SetVisible", "b", "true",
]
OSK_TOGGLE_ARGV_HIDE = OSK_TOGGLE_ARGV_SHOW[:-1] + ["false"]


# --- pure translation core (unit-tested without any device) ------------------

@dataclass
class AxisState:
    """Per-directional-axis state: which key (if any) is held, and when it
    next auto-repeats. One instance per HAT axis; sticks resolve onto the
    same instances so stick and d-pad cannot double-hold a direction.

    Each INPUT SOURCE keeps its own current direction, and the emitted key is
    derived from all of them. They cannot share one field: a resting stick
    genuinely asserts "neutral", so folding it into the same slot as the d-pad
    makes stick jitter cancel a d-pad press. That is a real measured failure,
    not a hypothetical -- see _stick_direction."""

    active_key: int | None = None
    next_repeat: float = 0.0
    stick_dir: int = 0  # from the analog stick, after hysteresis

    # There is deliberately NO hat_dir. A pad that genuinely reports a hat axis
    # would need one, but the Deck does not have one to report: its d-pad is
    # BTN_DPAD_* and ABS_HAT0X/Y is the left trackpad. Carrying a field nothing
    # can set invites someone to "fix" the missing wiring and reintroduce arrow
    # keys under a resting thumb. Phase 4's profile interface is where a real
    # hat belongs.


@dataclass
class Mapper:
    """translate(type, code, value, now) -> list of (key, value) emissions.

    value follows evdev key semantics: 1 press, 0 release, 2 autorepeat.
    Callers wrap each returned emission in an EV_KEY write + EV_SYN.
    """

    axis_ranges: dict[int, tuple[int, int]] = field(default_factory=dict)
    hats: dict[int, AxisState] = field(
        default_factory=lambda: {e.ABS_HAT0X: AxisState(), e.ABS_HAT0Y: AxisState()}
    )
    # Which d-pad buttons are physically down. The Deck lets you hold two
    # opposing edges at once, so the direction is recomputed from the held
    # set rather than from whichever event arrived last.
    dpad_held: set[int] = field(default_factory=set)

    # STEAM (BTN_MODE) held, for the STEAM+X chord.
    mode_held: bool = False
    # Whether anything was pressed DURING this hold of STEAM. STEAM is both the
    # chord's hold key and a button of its own (it opens the apps menu), so the
    # two are told apart on release: a hold that had a partner was a chord and
    # fires nothing, a clean tap fires the menu. Armed on every STEAM press --
    # a chord must not poison the tap that follows it.
    mode_chorded: bool = False
    # Actions the caller should perform, drained by main(). Kept as data rather
    # than executed here so the whole chord is unit-testable without a DBus
    # session or a subprocess.
    pending_actions: list[str] = field(default_factory=list)

    # Right-trackpad pointer state: last absolute sample per axis, and when it
    # arrived, so a lift-and-retouch re-baselines instead of hurling the cursor.
    pointer_last: dict[int, int] = field(default_factory=dict)
    pointer_last_seen: float = 0.0

    # On-screen keyboard (T8). `osk_active` gates the whole routing change, and
    # it is set ONLY by the tty backend -- with squeekboard the pads must keep
    # driving the system pointer, because squeekboard is a surface being
    # pointed at rather than something we draw.
    osk_active: bool = False
    osk: "object | None" = None       # deck_osk_layout.OnScreenKeyboard
    cursors: "object | None" = None   # deck_osk_layout.Cursors

    def pointer_delta(self, code: int, value: int, now: float) -> tuple[int, int]:
        """Right trackpad -> relative pointer motion. Returns (dx, dy).

        The trackpad reports ABSOLUTE position while a finger is on it and
        stops entirely when lifted, so differencing consecutive samples across
        a lift would jump the cursor the width of the pad. No touch flag has
        been measured, so a gap longer than POINTER_TOUCH_GAP is treated as a
        new touch: re-baseline and emit nothing for that sample.
        """
        if code not in POINTER_AXES:
            return (0, 0)
        # ⚠️ Re-baselining must NOT wipe the other axis.
        #
        # This previously did `self.pointer_last = {code: value}`, which cleared
        # the whole dict. Since X and Y arrive in the same report and each one
        # re-baselines on its first sample, they wiped each other forever: the
        # pointer emitted NOTHING whenever both axes moved together, and worked
        # only during pure-horizontal or pure-vertical strokes. Every pointer
        # test drove a single axis, so the suite passed throughout.
        #
        # A genuine new touch (a real pause) re-baselines BOTH. A jump on one
        # axis re-baselines only that axis.
        stale = (now - self.pointer_last_seen) > POINTER_TOUCH_GAP
        self.pointer_last_seen = now
        if stale:
            self.pointer_last.clear()
        previous = self.pointer_last.get(code)
        if previous is not None and abs(value - previous) > POINTER_JUMP_RAW:
            previous = None
        self.pointer_last[code] = value
        if previous is None:
            return (0, 0)
        # int(x / d), NOT x // d. Floor division rounds toward negative
        # infinity, so -30 // 24 == -2 while 30 // 24 == 1 -- left would move
        # nearly twice as fast as right, and the rounding would flip sign
        # mid-gesture. Measured as a cursor that "jumps between movements".
        raw = value - previous
        delta = int(raw / POINTER_DIVISOR)
        if delta == 0:
            # Hold the old baseline so slow movement accumulates instead of
            # being discarded a fraction at a time.
            self.pointer_last[code] = previous
            return (0, 0)
        # Advance the baseline by exactly what was EMITTED, not to the current
        # sample: baselining to `value` throws away the sub-pixel remainder on
        # every step, which is the other half of the stutter.
        self.pointer_last[code] = previous + delta * POINTER_DIVISOR
        # The pad's Y axis grows upward; screens grow downward.
        return (delta, 0) if POINTER_AXES[code] == "x" else (0, -delta)

    def _dpad_direction(self, hat_axis: int) -> int:
        """Resolve one axis from the held d-pad buttons. Opposing edges held
        together cancel to neutral, which is the same thing a physical hat
        does and keeps a stuck key impossible."""
        directions = {
            direction
            for code, (axis, direction) in DPAD_BUTTON_MAP.items()
            if axis == hat_axis and code in self.dpad_held
        }
        if len(directions) != 1:
            return 0
        return directions.pop()

    def _stick_direction(self, axis: int, value: int) -> int:
        lo, hi = self.axis_ranges.get(axis, (-32768, 32767))
        mid = (lo + hi) / 2
        half = (hi - lo) / 2 or 1
        frac = (value - mid) / half
        state = self.hats[STICK_AXES[axis]]
        # Hysteresis keys off THE STICK's own engagement, not off active_key.
        # Measured on hardware 2026-08-10: keying it off active_key meant that
        # once the d-pad engaged a direction, the next resting-stick sample
        # took the hysteresis branch, computed frac ~ 0 and reported neutral --
        # releasing the d-pad's key within ~10ms and killing auto-repeat. The
        # sticks emit jitter constantly, so a held d-pad direction never
        # survived. Nothing in the suite caught it: it only ever pushed the
        # stick to an ENGAGED position while a direction was held, never to
        # rest.
        if state.stick_dir != 0:
            return 0 if abs(frac) < STICK_RELEASE else (1 if frac > 0 else -1)
        if frac >= STICK_ENGAGE:
            return 1
        if frac <= -STICK_ENGAGE:
            return -1
        return 0

    def _effective_direction(self, hat_axis: int) -> int:
        """Combine the sources for one axis. Digital input wins over the
        stick, so resting-stick neutrality can never cancel a held d-pad."""
        dpad = self._dpad_direction(hat_axis)
        if dpad:
            return dpad
        return self.hats[hat_axis].stick_dir

    def _hat_transition(self, hat_axis: int, direction: int, now: float) -> list[tuple[int, int]]:
        state = self.hats[hat_axis]
        want = HAT_MAP.get((hat_axis, direction)) if direction else None
        if want == state.active_key:
            return []
        out: list[tuple[int, int]] = []
        if state.active_key is not None:
            out.append((state.active_key, 0))
        if want is not None:
            out.append((want, 1))
            state.next_repeat = now + REPEAT_DELAY
        state.active_key = want
        return out

    def _osk_event(self, etype: int, code: int, value: int) -> list[tuple[int, int]]:
        """Route one event to the on-screen keyboard. Returns keystrokes.

        Both pads become cursors and each trigger presses the key under its OWN
        cursor. Everything else is deliberately swallowed: with the keyboard up,
        A must not also send Enter and X must not also send Tab, or every key
        press does two things at once.
        """
        if self.osk is None or self.cursors is None:
            return []
        if etype == e.EV_ABS:
            self.cursors.update(code, value)
            return []
        if etype == e.EV_KEY and value == 1:
            half = TRIGGER_HALF.get(code)
            if half is not None:
                return self.osk.press_at(half, *self.cursors.position(half))
        return []

    def translate(self, etype: int, code: int, value: int, now: float) -> list[tuple[int, int]]:
        if etype == e.EV_KEY:
            # STEAM+X toggles the on-screen keyboard. Checked before every
            # other key path so the X in the chord does not also type Tab.
            #
            # ⚠️ STEAM IS RESOLVED ON RELEASE, and it has to be. It is the
            # chord's hold key AND the apps-menu button, so firing on the press
            # would open the menu underneath every STEAM+X the operator makes --
            # and STEAM+X is hardware-proven (R-43) and relied on.
            if code == OSK_CHORD_HOLD:
                if value == 1:
                    self.mode_held = True
                    self.mode_chorded = False
                elif value == 0:
                    # `mode_held` as well as `mode_chorded`: a release we never
                    # saw the press for (re-binding to a pad mid-hold) is not a
                    # tap the user made.
                    tap = self.mode_held and not self.mode_chorded
                    self.mode_held = False
                    if tap:
                        self.pending_actions.append("menu-apps")
                return []
            # Any button pressed while STEAM is down makes this hold a CHORD.
            # Deliberately EVERY button, not just X: STEAM+A still emits Enter
            # underneath, and letting go afterwards must not also open a menu the
            # user never asked for. Axes are excluded on purpose -- a thumb
            # resting on a trackpad is not a chord partner.
            if self.mode_held and value == 1:
                self.mode_chorded = True
            if code == OSK_CHORD_PRESS and self.mode_held:
                if value == 1:
                    self.pending_actions.append("toggle-osk")
                return []
            # QAM opens Omarchy's own menu. INERT while QAM_BUTTON is unset,
            # which is its shipped state -- see the constant. No chord to
            # disambiguate here, so it fires on the press.
            if QAM_BUTTON is not None and code == QAM_BUTTON:
                if value == 1:
                    self.pending_actions.append("menu-root")
                return []
        # ⚠️ AFTER the chord, BEFORE everything else. The chord has to keep
        # working while the keyboard is up -- it is how a user dismisses one
        # they opened by accident -- and nothing else may reach the navigation
        # profile underneath.
        if self.osk_active:
            return self._osk_event(etype, code, value)
        if etype == e.EV_KEY:
            if code in TRIGGER_BUTTON_MAP:
                if value in (0, 1):
                    return [(TRIGGER_BUTTON_MAP[code], value)]
                return []
            if code in DPAD_BUTTON_MAP:
                if value not in (0, 1):
                    return []  # the pad's own autorepeat; we schedule our own
                if value:
                    self.dpad_held.add(code)
                else:
                    self.dpad_held.discard(code)
                hat_axis = DPAD_BUTTON_MAP[code][0]
                return self._hat_transition(hat_axis, self._effective_direction(hat_axis), now)
            key = BUTTON_MAP.get(code)
            if key is None:
                return []
            if value in (0, 1):
                return [(key, value)]
            return []  # ignore the pad's own autorepeat; we schedule our own
        if etype == e.EV_ABS:
            # ⚠️ NO ABS_HAT0X/Y BRANCH HERE, DELIBERATELY. On this hardware
            # those are the LEFT TRACKPAD (measured), not a d-pad, so treating
            # them as directions emitted arrow keys for a resting thumb. The
            # d-pad is BTN_DPAD_*, handled above.
            if code in POINTER_AXES or code in DECK_TRIGGERS:
                return []  # pointer motion and analog triggers are not keys
            if code in STICK_AXES:
                hat_axis = STICK_AXES[code]
                self.hats[hat_axis].stick_dir = self._stick_direction(code, value)
                return self._hat_transition(hat_axis, self._effective_direction(hat_axis), now)
        return []

    def due_repeats(self, now: float) -> list[tuple[int, int]]:
        """Auto-repeat (value 2) for every held direction whose deadline
        passed. The kernel forwards value-2 events to the console exactly
        like held-key typematic."""
        out: list[tuple[int, int]] = []
        for state in self.hats.values():
            if state.active_key is not None and now >= state.next_repeat:
                out.append((state.active_key, 2))
                state.next_repeat = now + REPEAT_INTERVAL
        return out

    def next_deadline(self) -> float | None:
        deadlines = [s.next_repeat for s in self.hats.values() if s.active_key is not None]
        return min(deadlines) if deadlines else None


# --- auto-hide on UNLOCK, layer backend only (docs/PROGRESS.md §5.24a #3) ----
#
# Request 1, 2026-08-11: "the OSK must auto-hide after unlock". Today it does
# not -- `layer_rule({match={namespace="deck-osk"}, above_lock=2})` (§5.24)
# means our overlay draws ABOVE `ext-session-lock` on purpose, so the keyboard
# a user summoned to type their password keeps drawing straight through the
# unlock and into the desktop session behind it.
#
# ⚠️ THE DESIGN QUESTION, ANSWERED: HOW DOES THIS PROCESS LEARN "UNLOCKED"?
#
#   ext-session-lock itself   Binding it as a THIRD PARTY does not work: the
#                             protocol is for IMPLEMENTING a locker (one
#                             object per compositor, whoever gets there
#                             first), not for observing one that already
#                             exists. `deck_osk_focus.py` hand-rolls
#                             zwp_input_method_v2 the same way, and that
#                             protocol at least has an observer role; this one
#                             does not.
#   a Hyprland IPC event      Traced (docs/findings/T9-lock-service-mitigation
#                             .md §1.3, from Hyprland's OWN source): the only
#                             producer of session-lock state is
#                             `g_pSessionLockManager->isSessionLocked()`,
#                             read by `getSolitaryBlockedReason()` and
#                             surfaced in `hyprctl -j monitors` as
#                             `solitaryBlockedBy`. There is no lock/unlock
#                             line on the event socket (`socket2`) -- nothing
#                             else in Hyprland's IPC touches that bit.
#   something the mapper can already see   No: this process reads a gamepad
#                             node and writes to uinput. It has never had any
#                             visibility into compositor or session state.
#
# So the answer is the same ground truth upstream's OWN sensor reads --
# `bin/omarchy-hyprland-session-locked` is exactly this query, one exec of
# `hyprctl -j monitors` -- polled from here rather than subscribed to,
# because there is nothing to subscribe to.
#
# ⚠️ WHY POLLING IS THE SAFER CHOICE HERE, NOT JUST THE AVAILABLE ONE.
# CLAUDE.md's operator instructions were explicit: prefer a mechanism that
# CANNOT leave the keyboard stuck up if the signal is missed. An event-based
# design has a failure mode polling does not -- a dropped or unsubscribed
# event is gone forever, so a keyboard waiting on "the one event that tells
# me to hide" can wait forever. A poll that misses one cycle asks again on
# the next one: the worst case is late, never wrong and never permanent, and
# `hyprctl` succeeding or not is dead simple to reason about next to a
# hand-rolled protocol client staying in sync with a compositor's socket.
#
# ⚠️ read_lock_state() BLOCKS THE INPUT LOOP, up to LOCK_STATE_TIMEOUT --
# `spawn_detached()` elsewhere in this file is built specifically to NEVER do
# that. The difference is scope: that helper fires on every STEAM/QAM press,
# so a stall there is felt as lag on every press. This runs at most once
# every LOCK_POLL_INTERVAL seconds, and only while the layer-shell keyboard
# is actually on screen -- a local AF_UNIX round trip to a compositor that
# is, by construction, still painting frames (it is drawing the lock screen
# or the desktop this keyboard sits above) is not the risk spawning an
# unbounded helper process is. An async spawn-and-poll design was considered
# and rejected: it earns a THIRD fd in the main selector (after the pad and
# the focus watcher) to avoid a bound that is already small.
LOCK_STATE_ARGV: tuple[str, ...] = ("hyprctl", "-j", "monitors")
LOCK_POLL_INTERVAL = 0.75   # seconds between checks while the layer OSK is up
LOCK_STATE_TIMEOUT = 0.3    # bounded: a hung hyprctl costs at most this, rarely


def lock_state_from_monitors(monitors_json: str) -> bool | None:
    """True if any monitor's `solitaryBlockedBy` names LOCK; False if the
    JSON parses and none does; None if it cannot be read this way at all.

    Mirrors upstream's own sensor, `bin/omarchy-hyprland-session-locked`
    (docs/findings/T9-lock-service-mitigation.md §1.3): `solitaryBlockedBy`
    contains "LOCK" iff Hyprland's session-lock manager is ACTUALLY holding
    an `ext_session_lock_v1` at the moment `hyprctl` was asked -- a direct
    read of ground truth, not a heuristic like the DPMS/backlight confusion
    §5.24 already recorded one of. So False is exactly as trustworthy as
    True; only a malformed or unexpected answer (this is not Hyprland,
    `hyprctl` failed, the JSON shape changed) returns None, and a caller
    seeing None must change nothing -- see `LockWatcher`.
    """
    try:
        monitors = json.loads(monitors_json)
    except (TypeError, ValueError):
        return None
    if not isinstance(monitors, list):
        return None
    for monitor in monitors:
        if not isinstance(monitor, dict):
            continue
        blocked = monitor.get("solitaryBlockedBy")
        if isinstance(blocked, list) and "LOCK" in blocked:
            return True
    return False


def read_lock_state(argv: tuple[str, ...] = LOCK_STATE_ARGV,
                    timeout: float = LOCK_STATE_TIMEOUT,
                    env=None) -> bool | None:
    """One bounded, synchronous read of Hyprland's own lock state. See the
    module-level note above this section for why blocking here is a
    deliberate, scoped exception to `spawn_detached`'s "never block" rule.

    ⚠️ `hyprctl` needs `HYPRLAND_INSTANCE_SIGNATURE`, which a cold-booted
    service does not have (§5.28). Without the session environment every
    reading here is None, which fails toward "does not auto-hide" -- quiet,
    survivable, and invisible to every check. Hence the explicit `env`.
    """
    try:
        result = subprocess.run(
            list(argv), capture_output=True, text=True, timeout=timeout,
            env=session_environ() if env is None else env)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    return lock_state_from_monitors(result.stdout)


@dataclass
class LockWatcher:
    """Detects a LOCKED -> UNLOCKED edge, throttled and self-correcting.

    `tick()` is meant to be called on every pass through the main loop while
    the layer-shell keyboard is on screen; it polls at most once per
    `interval` seconds and reports True exactly once, on the transition.

    ⚠️ EDGE-TRIGGERED, IN ONE DIRECTION ONLY -- THIS IS WHAT KEEPS IT FROM
    EVER FIRING ON LOCK. `saw_lock` starts False every time `start()` is
    called (i.e. every time the keyboard is shown) and only ever latches
    True on an OBSERVED True reading. `tick()` reports "hide it" only on a
    False reading that follows a True one in THIS showing. A keyboard
    summoned in an already-unlocked desktop therefore never dismisses
    itself -- there is nothing it could have unlocked FROM -- and nothing
    here can report "hide" while `solitaryBlockedBy` still contains LOCK,
    however many times it is asked. Getting this backwards would hide the
    only keyboard a user has to answer a lock prompt, which is precisely
    the defect `above_lock=2` (§5.24) exists to prevent -- read
    `docs/tasks/T8-onscreen-keyboard.md` request 1 before touching this.

    ⚠️ FAILS TOWARD DOING NOTHING. `read_lock_state()` returning None --
    `hyprctl` missing, this is not actually Hyprland, a timeout -- leaves
    `saw_lock` exactly where it was: the keyboard just keeps behaving as it
    does today, staying up until STEAM+X. The only failure mode this adds is
    "does not auto-hide"; it cannot add "cannot be hidden at all", because
    the chord never goes through this class.
    """

    interval: float = LOCK_POLL_INTERVAL
    saw_lock: bool = False
    next_check: float = field(default=float("inf"))

    def start(self, now: float) -> None:
        """Arm for a fresh showing. Call every time the keyboard is shown."""
        self.saw_lock = False
        self.next_check = now  # check right away -- summoned-while-locked is the common case

    def stop(self) -> None:
        """Disarm. Call every time the keyboard is hidden, for any reason."""
        self.saw_lock = False
        self.next_check = float("inf")

    @property
    def armed(self) -> bool:
        return self.next_check != float("inf")

    def tick(self, now: float, reader=read_lock_state) -> bool:
        """Poll if due. Returns True exactly on a LOCKED -> UNLOCKED edge."""
        if not self.armed or now < self.next_check:
            return False
        self.next_check = now + self.interval
        state = reader()
        if state is None:
            return False
        if state:
            self.saw_lock = True
            return False
        was_locked = self.saw_lock
        self.saw_lock = False
        return was_locked

    def next_deadline(self) -> float | None:
        """For the caller's select() timeout. None when not armed."""
        return self.next_check if self.armed else None


def say(message: str) -> None:
    """One line to the journal, prefixed the way everything else here is."""
    print(f"deck-input-mapper: {message}", file=sys.stderr, flush=True)


# --- the session environment: resolved at RUN time, never inherited (§5.28) --
#
# 🔴 THIS SECTION EXISTS BECAUSE OF A RELEASE BLOCKER, MEASURED ON A COLD BOOT.
#
# On a freshly booted desktop this service's ENTIRE environment is one variable:
#
#     XDG_RUNTIME_DIR=/run/user/1000
#
# No WAYLAND_DISPLAY, no OMARCHY_PATH, no HYPRLAND_INSTANCE_SIGNATURE. The unit
# is `WantedBy=wayland-session@hyprland.desktop.target` with NO ordering, so it
# wins the race against uwsm's `systemctl --user import-environment`. The mapper
# itself does not care -- it reads evdev and writes uinput. ⚠️ ITS CHILDREN DO,
# and every user-visible affordance on this device is a child:
#
#     omarchy-menu       STEAM / QAM      needs OMARCHY_PATH   -> exits at once
#     deck_osk_wayland   the keyboard     needs WAYLAND_DISPLAY
#     deck_osk_focus     auto-show        needs WAYLAND_DISPLAY
#     hyprctl            the lock watcher needs HYPRLAND_INSTANCE_SIGNATURE
#
# So a cold-booted Deck had no keyboard, no launcher and no menu, while every
# check said the service was healthy -- R-29's shape, one layer up. A
# `systemctl --user restart deck-input-mapper` fixed all three, because by then
# the manager's environment was populated.
#
# ⚠️ THE OBVIOUS FIX IS A TRAP, and the unit says so in its own comment:
# `After=graphical-session.target` creates an ordering cycle with the target
# this unit is `WantedBy`, and systemd resolves the cycle by DELETING the start
# job -- the service then silently never runs at all. Measured on hardware.
#
# The fix is to stop relying on INHERITANCE and ask the manager for its
# environment at run time, which works however late the variables arrive and
# reintroduces no ordering. Asking is a subprocess, so it happens on the main
# loop's clock (like LockWatcher), never on a button press: by the time a user
# can press anything the answer is cached, and `spawn_detached`'s "never block"
# rule survives intact.
#
# ⚠️ WHATEVER YOU CHANGE HERE, THE TEST MUST BOOT THE MACHINE. A mapper
# restarted by hand always passes -- that is exactly how this shipped.
SESSION_ENV_ARGV: tuple[str, ...] = ("systemctl", "--user", "show-environment")
SESSION_ENV_TIMEOUT = 0.3    # bounded, like LOCK_STATE_TIMEOUT and for the same reason
SESSION_ENV_INTERVAL = 1.0   # between attempts, while still unresolved
SESSION_ENV_WINDOW = 60.0    # then stop asking: see `gave_up` below
# The variables whose absence was actually measured to break a child. All three
# are required before we stop polling, because they arrive from different places
# (uwsm's import, Hyprland's own export, Omarchy's session snippet) and the
# first one landing does not imply the rest have.
SESSION_ENV_REQUIRED: tuple[str, ...] = (
    "WAYLAND_DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE", "OMARCHY_PATH",
)


def parse_show_environment(text: str) -> dict[str, str]:
    """Parse `systemctl --user show-environment` into a dict.

    systemd's output is "suitable for eval in a shell", so a value containing
    anything interesting comes back QUOTED -- `PATH=/usr/bin` but
    `FOO='a b'`. Unquoting with shlex rather than stripping characters keeps
    an embedded space or quote intact instead of corrupting it silently.

    ⚠️ A line this cannot make sense of is SKIPPED, not fatal. This parses
    another program's output on a device whose only input path is this
    process; one unexpected line must cost that variable and nothing else.
    """
    found: dict[str, str] = {}
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        name, sep, raw = line.partition("=")
        # A shell variable name: ASCII, and never leading with a digit --
        # `isidentifier()` is exactly that rule, and `1INVALID=x` is not a line
        # any shell would accept either.
        if not sep or not name.isascii() or not name.isidentifier():
            continue
        if raw[:1] in ("'", '"'):
            try:
                parts = shlex.split(raw)
            except ValueError:
                continue          # an unbalanced quote: drop the line, keep the rest
            if len(parts) != 1:
                continue
            raw = parts[0]
        found[name] = raw
    return found


def read_show_environment(argv: tuple[str, ...] = SESSION_ENV_ARGV,
                          timeout: float = SESSION_ENV_TIMEOUT) -> str | None:
    """One bounded read of the user manager's environment block. None if it
    could not be read at all -- no user manager (the live ISO has none), no
    session bus, `systemctl` missing, or a timeout.

    ⚠️ Deliberately runs with the environment WE inherited: reaching the user
    manager needs `XDG_RUNTIME_DIR`/`DBUS_SESSION_BUS_ADDRESS`, and those are
    the two the cold-boot environment does have. Passing `env=` explicitly
    rather than inheriting implicitly is the invariant every spawn in this
    file now holds, and `test-deck-input-mapper.py` asserts it by parsing this
    source -- a new spawn added without one is the §5.28 bug returning.
    """
    try:
        result = subprocess.run(list(argv), capture_output=True, text=True,
                                timeout=timeout, env=os.environ.copy())
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    return result.stdout


@dataclass
class SessionEnv:
    """The session's environment, polled until it exists, then cached.

    `environ()` is what every child of this process is started with. It is
    always usable -- before anything has been resolved it is simply what we
    inherited, which is what shipped -- so this can only ever add variables,
    never take a working spawn away.

    ⚠️ MERGED, NEVER REPLACED. A later read that omits a variable an earlier
    one had leaves the earlier value in place. The manager's environment only
    grows during a session, and a transient empty answer (the manager busy,
    the bus momentarily unavailable) must not un-set the keyboard's display.
    """

    interval: float = SESSION_ENV_INTERVAL
    window: float = SESSION_ENV_WINDOW
    required: tuple[str, ...] = SESSION_ENV_REQUIRED
    log: object = say
    variables: dict = field(default_factory=dict)
    next_check: float = 0.0     # due immediately: the first refresh always asks
    started: float | None = None
    gave_up: bool = False
    complained: bool = False

    @property
    def resolved(self) -> bool:
        return all(name in self.variables for name in self.required)

    def missing(self) -> list[str]:
        return [name for name in self.required if name not in self.variables]

    def environ(self) -> dict:
        """What to start a child with. Resolved variables win over inherited
        ones: the manager's block is the session's truth, ours is a snapshot
        of whatever systemd happened to have when this unit started."""
        merged = dict(os.environ)
        merged.update(self.variables)
        return merged

    def refresh(self, now: float, reader=read_show_environment) -> bool:
        """Ask, if due. True when this call learned a required variable.

        Stops asking once resolved -- and also once `window` seconds have
        passed without success, because in the live ISO there is no user
        manager at all and a poll every second forever is a subprocess every
        second forever for nothing.
        """
        if self.gave_up or self.resolved or now < self.next_check:
            return False
        if self.started is None:
            self.started = now
        self.next_check = now + self.interval
        text = reader()
        if text is not None:
            self.variables.update(parse_show_environment(text))
        if self.resolved:
            self.log("session environment resolved; menus and the keyboard "
                     "have a compositor to talk to")
            return True
        if now - self.started >= self.window:
            self.gave_up = True
            if not self.complained:
                self.complained = True
                self.log("no session environment after "
                         f"{self.window:.0f}s (missing {', '.join(self.missing())}); "
                         "children run with what we inherited -- expected in the "
                         "installer, a defect on the desktop")
        return False

    def next_deadline(self) -> float | None:
        """For the caller's select() timeout. None once there is nothing left
        to ask for."""
        if self.gave_up or self.resolved:
            return None
        return self.next_check


# The one this process actually uses. A singleton because `spawn_detached` is
# module-level and every spawn must go through the same answer; the class takes
# all its collaborators as arguments so the suite never touches this object.
SESSION_ENV = SessionEnv()


def session_environ() -> dict:
    """The environment for a child of this process, right now."""
    return SESSION_ENV.environ()


# --- spawning helpers, and what the menu buttons will actually do ------------


# Children we have started and not yet reaped.
#
# ⚠️ A Popen nobody waits on becomes a ZOMBIE and holds its PID until the parent
# reaps it. That was survivable while the only spawn was the occasional
# squeekboard toggle; STEAM and QAM make spawning a per-button-press action in a
# service that runs for the life of the session, so "never reap" would leak a
# PID every time the user opens a menu. Reaping is done here rather than with a
# SIGCHLD handler because this module is imported by a unit suite that must not
# install process-wide signal handlers, and because a handler would also reap
# `osk_layer_proc`, which main() polls itself.
_spawned: list = []


def reap_spawned() -> int:
    """Drop children that have exited. Returns how many were reaped.

    `poll()` is what actually releases the zombie; keeping the object in a list
    and polling later is the whole mechanism.
    """
    before = len(_spawned)
    _spawned[:] = [proc for proc in _spawned if proc.poll() is None]
    return before - len(_spawned)


def spawn_detached(argv: list[str], what: str, env=None) -> bool:
    """Start a helper process and never wait for it. True if it started.

    `start_new_session=True` puts the helper in its own session, so a signal
    aimed at this process's group (a Ctrl-C in a foreground debug run) does not
    also kill the menu the user just opened. It does NOT survive the service
    being stopped -- systemd kills the whole control group -- and it is not
    meant to.

    ⚠️ NEITHER BLOCKING NOR FATAL, AND NEVER SILENT. Popen without a wait, so a
    helper that hangs cannot freeze the input loop -- with lizard_mode=N this
    process is the only input path on the device (docs/PROGRESS.md §5.9), and a
    frozen loop is a handheld with no pointer and no keys. A helper that is
    missing entirely raises OSError here, which must cost that one button and
    nothing else; it is reported loudly because a button that silently does
    nothing is indistinguishable from lizard mode swallowing the press.

    ⚠️ `env` IS NOT OPTIONAL DECORATION -- see §5.28 above. A menu started with
    what this service inherited on a cold boot exits immediately with
    `OMARCHY_PATH is not set`, which the user experiences as a dead button.
    """
    reap_spawned()
    try:
        proc = subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                start_new_session=True,
                                env=session_environ() if env is None else env)
    except OSError as exc:
        print(f"deck-input-mapper: could not {what}: {exc}",
              file=sys.stderr, flush=True)
        return False
    _spawned.append(proc)
    return True


def run_menu_action(action: str, dry_run: bool = False) -> bool:
    """Open one of Omarchy's menus. Returns True if the helper was started."""
    argv = MENU_ACTIONS.get(action)
    if argv is None:
        # Unreachable from translate(), which queues only these two names --
        # which is exactly why it is loud rather than an ignored default branch.
        print(f"deck-input-mapper: unknown menu action {action!r}; nothing opened",
              file=sys.stderr, flush=True)
        return False
    if dry_run:
        print(f"menu -> {' '.join(argv)}", file=sys.stderr, flush=True)
        return True
    if not spawn_detached(argv, f"run `{' '.join(argv)}`"):
        print(f"deck-input-mapper: that button does nothing until {OMARCHY_MENU} "
              "is installed and on PATH; the rest of the mapper is unaffected",
              file=sys.stderr, flush=True)
        return False
    return True


# --- focus-triggered auto-show (T8 step 8) -----------------------------------


class AutoShow:
    """Show the keyboard when a text field takes focus, hide it when it leaves.

    STEAM+X summons the keyboard by hand and always will; this is the other
    half, and it is the one regression step 7 shipped -- squeekboard auto-shows
    on focus (§5.20) and ours did not.

    WHERE THE FOCUS SIGNAL COMES FROM, and why it is a whole process
        Only `zwp_input_method_v2` knows that a text field took focus: it is
        client-internal state, surfaced by no window manager IPC. R-50 ruled out
        Hyprland's IPC (its events are about windows) and fcitx5's DBus object
        (three methods, no signals -- the inbound direction only). So we bind
        the input method ourselves, in `deck_osk_focus.py`.

        ⚠️ THAT MEANS TAKING THE SEAT, and the seat is single-occupancy. R-51
        measured the cost exactly: fcitx5 launched with `--disable waylandim`
        keeps XIM, IBus and `/virtualkeyboard` untouched and loses only its
        WAYLAND-NATIVE clients. Cheap for a Latin-script Deck, real for someone
        typing CJK into a Wayland-native application -- so this is opt-in
        (`--osk-auto-show`), never a silent default.

    ⚠️ A SEPARATE PROCESS, for the same reason the layer-shell overlay is one:
        with lizard_mode=N this mapper is the only input path on the device
        (§5.9). A protocol bug, a compositor restart, or a seat we are refused
        must cost auto-show and nothing else. Everything below degrades: it
        reports, disables itself, and leaves the chord working.
    """

    def __init__(self, module, argv: list[str], log=say,
                 env_source=session_environ) -> None:
        self.module = module        # deck_osk_focus: it owns the line protocol
        self.argv = list(argv)
        self.log = log
        # ⚠️ The watcher binds `zwp_input_method_v2`, so it needs
        # WAYLAND_DISPLAY, which a cold-booted service does not have (§5.28).
        # Resolved when it is STARTED, not when this object was built.
        self.env_source = env_source
        self.proc = None
        self.buffer = b""
        self.ignored = 0
        self.enabled = False

    def start(self) -> bool:
        """Spawn the watcher. False (loudly) if it could not start."""
        try:
            # stderr is INHERITED on purpose: the watcher explains itself there
            # -- no compositor, no protocol, seat taken -- and that belongs in
            # the same journal as everything else this service says.
            self.proc = subprocess.Popen(
                self.argv, stdout=subprocess.PIPE, bufsize=0,
                env=self.env_source())
        except OSError as exc:
            self.proc = None
            self.log(f"could not start the focus watcher ({exc}); auto-show is "
                     "DISABLED, the STEAM+X chord still works")
            return False
        self.enabled = True
        return True

    def fileno(self) -> int | None:
        if self.proc is None or self.proc.stdout is None:
            return None
        return self.proc.stdout.fileno()

    def pump(self, visible: bool) -> bool | None:
        """Read what the watcher has said. Returns the visibility it asks for,
        or None for "nothing to do".

        ⚠️ LAST ONE WINS. Several changes can arrive in one read -- focus moves
        out of one field and into another in a few milliseconds -- and only the
        final state matters. Acting on each in turn would hide and re-show the
        keyboard, which for the layer backend means killing and re-spawning a
        GTK process for a state we are about to leave.
        """
        if self.proc is None or self.proc.stdout is None:
            return None
        try:
            chunk = os.read(self.proc.stdout.fileno(), 4096)
        except (BlockingIOError, InterruptedError):
            return None
        except OSError as exc:
            self._die(f"the focus watcher's pipe failed ({exc})")
            return None
        if not chunk:
            self._die("the focus watcher exited")
            return None
        lines, self.buffer = self.module.split_lines(self.buffer + chunk)
        want = None
        for line in lines:
            value = self.module.parse_focus_line(line)
            if value is None:
                # Not fatal -- this crosses a process boundary -- but not
                # silent either. Once, so a chatty producer cannot flood the
                # journal.
                self.ignored += 1
                if self.ignored == 1:
                    self.log(f"the focus watcher said {line!r}, which is not a "
                             "focus line; ignoring it and any like it")
                continue
            want = value
        if want is None or want == visible:
            return None
        return want

    def _die(self, detail: str) -> None:
        """Disable auto-show, naming the watcher's own reason if it has one."""
        status = None
        if self.proc is not None:
            try:
                # It has hit EOF, so it has exited or is a breath away from it.
                # The wait is what turns a bare "it stopped" into "the seat was
                # taken" -- worth a bounded pause, once, in a lifetime.
                status = self.proc.wait(timeout=0.5)
            except subprocess.TimeoutExpired:
                status = None
        reason = self.module.EXIT_REASONS.get(status)
        self.log(f"{detail}"
                 + (f": {reason}" if reason else "")
                 + "; auto-show is DISABLED, the STEAM+X chord still works")
        self._close()

    def _close(self) -> None:
        self.enabled = False
        proc, self.proc = self.proc, None
        if proc is not None and proc.stdout is not None:
            try:
                proc.stdout.close()
            except OSError:
                pass

    def stop(self) -> None:
        """Shut the watcher down. Idempotent: called on every exit path."""
        proc = self.proc
        self._close()
        if proc is None:
            return
        try:
            proc.terminate()
        except OSError:
            pass
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            proc.kill()


def read_lizard_mode(path: str = LIZARD_MODE_PATH) -> str | None:
    """`Y`, `N`, or None when the knob cannot be read (no hid_steam, not a Deck)."""
    try:
        return pathlib.Path(path).read_text().strip()
    except OSError:
        return None


def menu_binding_report(lizard: str | None) -> list[str]:
    """What the menu buttons will and will not do, said once at startup.

    ⚠️ THE JOURNAL IS THE POINT. The overwhelmingly likely field report about
    either of these buttons is "I pressed it and nothing happened", and there
    are three different causes: lizard mode is on so the press reaches no evdev
    node at all (§5.9, §5.21), QAM's code has never been measured so its binding
    is inert (see QAM_BUTTON), or `omarchy-menu` is not installed. Each is
    named here, so whoever reads the log does not have to rediscover them.
    """
    lines = [
        f"STEAM (tap, no chord) -> `{' '.join(MENU_ACTIONS['menu-apps'])}`; "
        "STEAM+X still toggles the on-screen keyboard",
    ]
    if QAM_BUTTON is None:
        lines.append(
            f"QAM -> `{' '.join(MENU_ACTIONS['menu-root'])}` is INERT: QAM_BUTTON "
            "is unset because QAM's evdev code has never been measured. One "
            "press fills it in -- see the comment beside QAM_BUTTON in this "
            "script for the exact command")
    else:
        name = e.bytype[e.EV_KEY].get(QAM_BUTTON, QAM_BUTTON)
        if isinstance(name, (list, tuple)):
            name = "/".join(name)
        lines.append(f"QAM ({name}) -> `{' '.join(MENU_ACTIONS['menu-root'])}`")
    if lizard is None:
        lines.append(
            f"could not read {LIZARD_MODE_PATH}, so this cannot tell you whether "
            "lizard mode is on -- and with it on, STEAM and QAM reach no evdev "
            "node and NEITHER binding above can fire")
    elif lizard.strip().upper() == "N":
        lines.append(f"lizard_mode is {lizard}: STEAM and QAM reach this process")
    else:
        lines.append(
            f"lizard_mode is {lizard}, so the firmware SWALLOWS STEAM and QAM "
            "entirely -- they reach no evdev node and NEITHER binding above can "
            f"fire. `echo N | sudo tee {LIZARD_MODE_PATH}` re-enables them, and "
            "does not survive a reboot (docs/PROGRESS.md §5.21)")
    return [f"deck-input-mapper: {line}" for line in lines]


# --- device plumbing ---------------------------------------------------------

# Steam takes the controller over via hidraw and re-presents it as a virtual
# Xbox pad, in Desktop Mode as well as Gaming Mode -- measured 2026-08-10, when
# starting Steam on the desktop made the native "Steam Deck" node disappear and
# this mapper re-bind to Steam's replacement. Binding that pad is always wrong:
# Steam is already handling those buttons for its own UI, so every press would
# act twice, once in Steam and once as an injected keystroke.
#
# Match on the name Steam gives it. The trailing index varies ("... pad 0"), and
# a real, physically attached Xbox controller would also match -- which is the
# right call anyway, since this mapper exists to drive an installer from the
# Deck's built-in controls, not to remap arbitrary gamepads.
STEAM_VIRTUAL_PAD_MARKERS = ("x-box", "xbox")


def is_steam_virtual_pad(dev: InputDevice) -> bool:
    name = dev.name.lower()
    return any(marker in name for marker in STEAM_VIRTUAL_PAD_MARKERS)


def looks_like_gamepad(dev: InputDevice) -> bool:
    caps = dev.capabilities()
    if e.BTN_SOUTH not in caps.get(e.EV_KEY, []):
        return False
    # Capability alone matches Steam's virtual pad too -- that is exactly how
    # this mapper latched onto it.
    return not is_steam_virtual_pad(dev)


def _match(candidates: list[InputDevice], selector: str | None) -> InputDevice | None:
    for dev in candidates:
        if selector:
            if selector.lower() in dev.name.lower() and looks_like_gamepad(dev):
                return dev
        elif looks_like_gamepad(dev):
            return dev
    return None


# How long to wait between rescans while Steam owns the controller.
STEAM_RESCAN_INTERVAL = 5.0

# How long to tolerate NO pad at all before giving up and exiting.
#
# Measured 2026-08-10: while Steam takes the controller over there is a window
# where neither pad exists -- the native node is already gone and Steam's
# virtual pad has not appeared yet. Exiting immediately on that gap burned 4 of
# the unit's 5 StartLimitBurst restarts during a single Steam start/stop cycle.
# One more and the mapper would have been permanently dead, which is exactly
# what pick_device's wait was written to prevent.
#
# Bounded, not infinite: a pad that never appears is still a real failure and
# must still exit loudly. This only absorbs the enumeration gap.
NO_PAD_GRACE_SECONDS = 30.0


def pick_device(selector: str | None) -> InputDevice:
    """Find the pad, WAITING (not exiting) while Steam owns the controller.

    The distinction matters and is not cosmetic. `Restart=on-failure` with
    `StartLimitBurst=5` means exiting here would burn every restart within ~10s
    of Steam starting, trip the start limit, and leave the mapper permanently
    dead -- including after Steam quits and the native pad comes back. So:

      Steam's virtual pad is present  -> expected and temporary; wait and rescan
      no gamepad of any kind          -> a real failure; exit loudly

    Never collapse those two into one "not found" branch. CLAUDE.md forbids
    swallowing the second, and the unit's restart policy cannot survive the
    first.
    """
    if selector and selector.startswith("/dev/"):
        return InputDevice(selector)

    announced_wait = False
    no_pad_deadline: float | None = None
    while True:
        candidates = [InputDevice(p) for p in list_devices()]
        dev = _match(candidates, selector)
        if dev is not None:
            return dev

        steam_pads = [d.name for d in candidates if is_steam_virtual_pad(d)]
        if not steam_pads:
            # No pad of any kind. Usually the enumeration gap during Steam's
            # takeover, so absorb it briefly -- but keep it bounded, because a
            # pad that never arrives is a genuine failure.
            now = time.monotonic()
            if no_pad_deadline is None:
                no_pad_deadline = now + NO_PAD_GRACE_SECONDS
                print(
                    f"deck-input-mapper: no gamepad present; waiting up to "
                    f"{NO_PAD_GRACE_SECONDS:.0f}s for one to enumerate",
                    file=sys.stderr,
                    flush=True,
                )
            if now < no_pad_deadline:
                time.sleep(1.0)
                continue
            names = ", ".join(f"{d.path}:{d.name}" for d in candidates) or "none"
            sys.exit(f"deck-input-mapper: no gamepad matched {selector!r}. Devices: {names}")

        # A pad reappeared (Steam's). Re-arm the grace window so a later gap
        # gets its own full allowance rather than inheriting a spent one.
        no_pad_deadline = None
        if not announced_wait:
            # Say it once, then stay quiet -- this can last for hours.
            print(
                f"deck-input-mapper: Steam owns the controller ({steam_pads[0]}); "
                f"waiting for the native pad, rescanning every {STEAM_RESCAN_INTERVAL:.0f}s",
                file=sys.stderr,
                flush=True,
            )
            announced_wait = True
        time.sleep(STEAM_RESCAN_INTERVAL)


# A freshly created uinput device is not usable the instant UInput() returns:
# udev has to process it and the compositor has to open it. Typing immediately
# lands in a device nothing is reading yet, and every character is lost with no
# error -- the exact shape of the defects session 17 spent a day on. Measured
# nowhere yet; 0.4s is the conventional settle used by ydotool and friends, and
# --type prints what it sent so a human can see the difference.
UINPUT_SETTLE = 0.4


def type_text(text: str, dry_run: bool = False) -> None:
    """Type `text` through the OSK layout core and exit.

    This exists so the character-emission path can be proven on hardware before
    a renderer exists (T8 steps 4-5). It needs no pad, no compositor and no
    cursor: focus a text field, run it, and see whether the text appears.
    """
    if osk_layout is None:
        print("deck-input-mapper: --type needs the OSK layout core, which did "
              "not load (see the message above)", file=sys.stderr, flush=True)
        raise SystemExit(2)

    strokes = osk_layout.strokes_for_text(text)  # raises on an unreachable char
    if dry_run:
        for code, value in strokes:
            print(f"emit {e.KEY.get(code, code)} {value}", file=sys.stderr, flush=True)
        return

    with UInput({e.EV_KEY: EMITTED_KEYS, e.EV_REL: EMITTED_RELS},
                name="deck-input-mapper virtual keyboard") as ui:
        time.sleep(UINPUT_SETTLE)
        for code, value in strokes:
            ui.write(e.EV_KEY, code, value)
            ui.syn()
    print(f"deck-input-mapper: typed {len(strokes)} events for {text!r}",
          file=sys.stderr, flush=True)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--device", help="evdev path or a substring of the device name")
    ap.add_argument("--grab", action="store_true", help="EVIOCGRAB the pad so nothing else also reads it")
    ap.add_argument("--dry-run", action="store_true", help="print emissions instead of injecting")
    ap.add_argument("--verbose", action="store_true", help="log every emission to stderr")
    ap.add_argument("--list", action="store_true", help="list input devices and exit")
    ap.add_argument("--type", metavar="TEXT",
                    help="type TEXT through the OSK layout and exit (no pad needed)")
    ap.add_argument("--osk-backend", choices=("dbus", "tty", "layer", "none"),
                    default="dbus",
                    help="what STEAM+X opens: squeekboard over DBus (default), the "
                         "TTY keyboard we draw (the installer, which has no "
                         "compositor), our layer-shell overlay (Desktop Mode), "
                         "or nothing")
    ap.add_argument("--osk-tty", metavar="PATH", default="/dev/tty",
                    help="where the tty backend draws (default /dev/tty)")
    ap.add_argument("--osk-top-row", type=int, default=0, metavar="N",
                    help="1-based console row for the keyboard's first line; "
                         "0 means 'as low as it fits' (default)")
    ap.add_argument("--osk-auto-show", action="store_true",
                    help="also show the keyboard when a text field takes focus, "
                         "and hide it when focus leaves. ⚠️ Needs the Wayland "
                         "input-method seat, which costs fcitx5 its "
                         "Wayland-native clients (R-51) -- opt in deliberately")
    ap.add_argument("--osk-focus-watcher", metavar="PATH", default=None,
                    help="the program whose stdout carries `focus 0`/`focus 1` "
                         "(default: deck_osk_focus.py beside the other OSK "
                         "modules)")
    args = ap.parse_args()

    if args.list:
        for path in list_devices():
            dev = InputDevice(path)
            tag = " [gamepad]" if looks_like_gamepad(dev) else ""
            print(f"{path}  {dev.name}{tag}")
        return

    if args.type is not None:
        type_text(args.type, dry_run=args.dry_run)
        return

    pad = pick_device(args.device)
    mapper = Mapper(axis_ranges={
        code: (ai.min, ai.max)
        for code, ai in dict(pad.capabilities().get(e.EV_ABS, [])).items()
        if code in STICK_AXES
    })

    ui = None
    if not args.dry_run:
        # EV_REL as well as EV_KEY: this device is the pointer too when lizard
        # mode is off, and a device that advertises no REL axes has its motion
        # events silently dropped.
        ui = UInput(
            {e.EV_KEY: EMITTED_KEYS, e.EV_REL: EMITTED_RELS},
            name="deck-input-mapper virtual keyboard",
        )

    def emit(key: int, value: int) -> None:
        if args.verbose or ui is None:
            name = e.KEY.get(key) or e.BTN.get(key) or key
            if isinstance(name, (list, tuple)):
                name = "/".join(name)
            print(f"emit {name} {value}", file=sys.stderr, flush=True)
        if ui is None:
            return
        ui.write(e.EV_KEY, key, value)
        ui.syn()

    def emit_motion(dx: int, dy: int) -> None:
        if args.verbose or ui is None:
            print(f"emit REL {dx:+d},{dy:+d}", file=sys.stderr, flush=True)
        if ui is None:
            return
        if dx:
            ui.write(e.EV_REL, e.REL_X, dx)
        if dy:
            ui.write(e.EV_REL, e.REL_Y, dy)
        ui.syn()

    osk_visible = False

    # Auto-hide on unlock (docs/PROGRESS.md §5.24a #3). Only the `layer`
    # backend can be shown ABOVE a lock (`above_lock=2`, §5.24) and so is the
    # only one that needs this; harmless to construct unconditionally, since
    # it is only ever start()ed/tick()ed under that backend below.
    lock_watcher = LockWatcher()

    # --- the tty backend: the keyboard we draw ourselves (T8) ----------------
    #
    # Only set up when asked for. The default stays `dbus` so the installed
    # Deck's user service keeps toggling squeekboard exactly as it does today --
    # this whole path is dead weight there, and dead weight that cannot run is
    # the point.
    osk_tty = None
    osk_stream = None
    osk_layer_proc = None
    # MUTABLE: degrades to "dbus" if our own keyboard fails at runtime. See
    # osk_fall_back -- this is what makes step 7 safe to ship.
    osk_backend = args.osk_backend
    # Both of our own backends share the routing: pads become cursors, triggers
    # press. Only the DRAWING differs -- characters on a console, or a
    # layer-shell surface. That is the seam T8 asked for, and it is why
    # `mapper.osk_active` is set the same way for both.
    osk_drawn_here = args.osk_backend in ("tty", "layer")
    osk_layer_script = _find_module_path("deck_osk_wayland")
    if args.osk_backend == "layer":
        if osk_layout is None or osk_layer_script is None:
            print("deck-input-mapper: --osk-backend=layer needs deck_osk_wayland.py "
                  f"in {', '.join(str(d) for d in OSK_SEARCH_DIRS)}; the keyboard "
                  "is DISABLED, navigation still works",
                  file=sys.stderr, flush=True)
            osk_drawn_here = False
        else:
            pad_abs = dict(pad.capabilities().get(e.EV_ABS, []))
            mapper.osk = osk_layout.OnScreenKeyboard()
            mapper.cursors = osk_layout.Cursors(ranges={
                code: (ai.min, ai.max) for code, ai in pad_abs.items()
                if code in osk_layout.PAD_AXES
            })
    if args.osk_backend == "tty":
        osk_tty = _load_module("deck_osk_tty")
        if osk_layout is None or osk_tty is None:
            print("deck-input-mapper: --osk-backend=tty needs both OSK modules; "
                  "the keyboard is DISABLED, navigation still works",
                  file=sys.stderr, flush=True)
            osk_tty = None
        else:
            try:
                osk_stream = open(args.osk_tty, "w")
            except OSError as exc:
                print(f"deck-input-mapper: cannot draw on {args.osk_tty} ({exc}); "
                      "the keyboard is DISABLED, navigation still works",
                      file=sys.stderr, flush=True)
                osk_tty = None
        if osk_tty is not None:
            pad_abs = dict(pad.capabilities().get(e.EV_ABS, []))
            mapper.osk = osk_layout.OnScreenKeyboard()
            # The pads' OWN advertised ranges, not the measured default: this is
            # the one place the two can disagree, and the device is the authority.
            mapper.cursors = osk_layout.Cursors(ranges={
                code: (ai.min, ai.max) for code, ai in pad_abs.items()
                if code in osk_layout.PAD_AXES
            })

    def osk_draw() -> None:
        try:
            _osk_draw()
        except (OSError, ValueError) as exc:
            # ⚠️ A CONSOLE WRITE THAT FAILS MUST NOT TAKE THE INPUT LAYER DOWN.
            #
            # Measured in QEMU (session 18): `OSError: [Errno 5] Input/output
            # error` out of `stream.flush()` in write_at killed the whole
            # mapper mid-run. A tty can start refusing writes for reasons that
            # have nothing to do with us -- the VT was switched away, the
            # console was reconfigured, the device went away -- and DRAWING A
            # KEYBOARD IS OPTIONAL while this process is the only input path
            # (docs/PROGRESS.md §5.9). Same lesson as the ENODEV crash: the
            # mapper degrades, it does not die.
            osk_fall_back(f"could not draw on {args.osk_tty}: {exc}")

    def osk_erase() -> None:
        try:
            _osk_erase()
        except (OSError, ValueError) as exc:
            osk_fall_back(f"could not clear {args.osk_tty}: {exc}")

    def _console_rows() -> int:
        """The console's height RIGHT NOW.

        Measured every draw, not cached: `stty rows` resizes a Linux VT (R-49),
        so a height read at startup can be wrong by the time we draw.
        """
        try:
            return os.get_terminal_size(osk_stream.fileno()).lines
        except OSError:
            return 25  # the console default when the size is unknowable

    def _osk_draw() -> None:
        rows = osk_tty.render(mapper.osk, mapper.cursors)
        height = _console_rows()
        top = args.osk_top_row
        if top <= 0:
            top = max(1, height - len(rows) + 1)
        osk_tty.write_at(osk_stream, rows, top, console_rows=height)

    def _osk_erase() -> None:
        rows = osk_tty.render(mapper.osk, mapper.cursors)
        top = args.osk_top_row
        if top <= 0:
            top = max(1, _console_rows() - len(rows) + 1)
        osk_tty.clear_at(osk_stream, rows, top)

    def osk_layer_start() -> None:
        """Spawn the overlay and give it the current state.

        A SEPARATE PROCESS on purpose: with lizard_mode=N this mapper is the
        only input path on the device, so a GTK crash or a compositor restart
        must not be able to take it down. The cost is a pipe.

        ⚠️ It is a layer-shell client, so it needs WAYLAND_DISPLAY -- which a
        cold-booted service does not have (§5.28). Started with the resolved
        session environment, not ours; without that this exits immediately and
        the device a user just booted has no keyboard.
        """
        nonlocal osk_layer_proc
        if osk_layer_proc is not None and osk_layer_proc.poll() is None:
            return
        try:
            osk_layer_proc = subprocess.Popen(
                [sys.executable, str(osk_layer_script)],
                stdin=subprocess.PIPE, text=True, env=session_environ(),
            )
        except OSError as exc:
            osk_layer_proc = None
            osk_fall_back(f"could not start the overlay: {exc}")
            return
        osk_layer_send()

    def osk_layer_send() -> None:
        """One state line. A dead overlay is reported, never fatal."""
        nonlocal osk_layer_proc
        if osk_layer_proc is None or osk_layer_proc.stdin is None:
            return
        # An overlay that started and then died is the likeliest failure --
        # a missing library, a compositor without layer-shell, a GTK error --
        # and it looks identical to a healthy one until the pipe is used.
        exited = osk_layer_proc.poll()
        if exited is not None:
            osk_layer_proc = None
            osk_fall_back(f"the overlay exited with status {exited}")
            osk_dbus_toggle(True)
            return
        try:
            osk_layer_proc.stdin.write(
                osk_layout.format_state_line(mapper.osk, mapper.cursors))
            osk_layer_proc.stdin.flush()
        except (BrokenPipeError, OSError) as exc:
            osk_layer_proc = None
            osk_fall_back(f"the overlay went away: {exc}")
            osk_dbus_toggle(True)

    def osk_layer_stop() -> None:
        nonlocal osk_layer_proc
        if osk_layer_proc is None:
            return
        try:
            if osk_layer_proc.stdin is not None:
                osk_layer_proc.stdin.close()   # EOF is the overlay's exit signal
        except OSError:
            pass
        try:
            osk_layer_proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            osk_layer_proc.kill()
        osk_layer_proc = None

    def osk_fall_back(reason: str) -> None:
        """Give up on our own keyboard and hand the job back to squeekboard.

        ⚠️ THIS IS WHAT MAKES RETIRING SQUEEKBOARD SAFE (T8 step 7). Our overlay
        needs a compositor, a library that must be preloaded, and a process that
        must stay alive; squeekboard needs none of that and is already installed.
        Without this, any one of those failing on a device with no keyboard
        attached leaves it with no way to type at all -- and with lizard_mode=N
        no way to recover except SSH.

        So squeekboard is retired as the DEFAULT, not removed as the fallback.
        The worst case is the behaviour that shipped before this step.
        """
        nonlocal osk_backend, osk_tty
        if osk_backend == "dbus":
            return
        if osk_backend == "tty":
            # Nothing to hand over to: the installer has no squeekboard and no
            # session bus. Stop drawing, keep navigating, say why.
            print(f"deck-input-mapper: the tty keyboard failed ({reason}); "
                  "it is DISABLED for the rest of this session, navigation "
                  "still works", file=sys.stderr, flush=True)
            osk_backend = "none"
            osk_tty = None
            mapper.osk_active = False
            return
        print(f"deck-input-mapper: the {osk_backend} keyboard failed ({reason}); "
              "falling back to squeekboard over DBus for the rest of this session",
              file=sys.stderr, flush=True)
        osk_backend = "dbus"
        mapper.osk_active = False

    def osk_dbus_toggle(visible: bool) -> None:
        if ui is None:
            return
        argv = OSK_TOGGLE_ARGV_SHOW if visible else OSK_TOGGLE_ARGV_HIDE
        # Loud, but not fatal: losing the OSK toggle must not take the pointer
        # down with it. Same contract as every other helper we spawn.
        spawn_detached(argv, "toggle the OSK")

    def set_osk_visible(visible: bool) -> None:
        nonlocal osk_visible
        osk_visible = visible
        if args.verbose or ui is None:
            print(f"osk -> {'show' if visible else 'hide'} ({osk_backend})",
                  file=sys.stderr, flush=True)
        if osk_backend == "tty" and osk_tty is not None:
            mapper.osk_active = visible
            if visible:
                mapper.osk.closed = False
                osk_draw()
            else:
                osk_erase()
            return
        if osk_backend == "layer" and osk_drawn_here:
            mapper.osk_active = visible
            if visible:
                mapper.osk.closed = False
                osk_layer_start()
            else:
                osk_layer_stop()
            # osk_layer_start may have fallen back; honour it in the same call
            # rather than leaving the user with nothing until the next press.
            if osk_backend == "dbus" and visible:
                osk_dbus_toggle(True)
            # Arm the unlock watcher for exactly the span this showing covers
            # -- fresh on every show, so a keyboard summoned in an already
            # unlocked desktop has no LOCK reading to ever transition away
            # from. Only while STILL "layer": the fallback just above may
            # have changed it, and dbus/squeekboard's own visibility is not
            # this mechanism's business.
            if osk_backend == "layer" and visible:
                lock_watcher.start(time.monotonic())
            else:
                lock_watcher.stop()
            return
        if osk_backend == "dbus":
            osk_dbus_toggle(visible)

    def run_pending(actions: list[str]) -> None:
        """Perform queued side effects. Never blocks the input loop: a DBus
        call, or a menu that takes a moment to draw, must not freeze the
        pointer."""
        while actions:
            action = actions.pop(0)
            if action == "toggle-osk":
                set_osk_visible(not osk_visible)
                continue
            if action in MENU_ACTIONS:
                if args.verbose and ui is not None:
                    print(f"menu -> {' '.join(MENU_ACTIONS[action])}",
                          file=sys.stderr, flush=True)
                # --dry-run reports instead of spawning, exactly as the emitters
                # above print instead of injecting.
                run_menu_action(action, dry_run=ui is None)
                continue
            # An action queued by translate() and handled by nobody is a bug
            # that would otherwise present as a dead button.
            print(f"deck-input-mapper: queued action {action!r} has no handler; "
                  "nothing happened", file=sys.stderr, flush=True)

    # --- auto-show: the keyboard appears when a text field takes focus -------
    #
    # Off unless asked for. It takes the Wayland input-method seat away from
    # fcitx5 (R-51), which is a trade the operator makes, not one we make for
    # them -- and in the installer there is no compositor to ask at all.
    auto = None
    if args.osk_auto_show:
        watcher_path = args.osk_focus_watcher or _find_module_path("deck_osk_focus")
        focus_module = _load_module("deck_osk_focus")
        if watcher_path is None or focus_module is None:
            say("--osk-auto-show needs deck_osk_focus.py in "
                f"{', '.join(str(d) for d in OSK_SEARCH_DIRS)}; auto-show is "
                "DISABLED, the STEAM+X chord still works")
        else:
            auto = AutoShow(focus_module, [sys.executable, str(watcher_path)])
            if not auto.start():
                auto = None

    if args.grab:
        pad.grab()
    print(f"deck-input-mapper: reading {pad.path} ({pad.name})", file=sys.stderr, flush=True)
    for line in menu_binding_report(read_lizard_mode()):
        print(line, file=sys.stderr, flush=True)

    # First ask, before the loop: on a warm start this resolves immediately and
    # nothing else here ever runs. On a cold boot it fails, and the loop keeps
    # asking. ⚠️ The startup line matters as EVIDENCE -- §5.28 was invisible
    # precisely because a healthy-looking service said nothing about this.
    SESSION_ENV.refresh(time.monotonic())
    if not SESSION_ENV.resolved:
        say("the session environment is not ready yet (missing "
            f"{', '.join(SESSION_ENV.missing())}); menus and the keyboard stay "
            "dead until it arrives, which is what this polls for (§5.28)")

    sel = selectors.DefaultSelector()
    sel.register(pad.fd, selectors.EVENT_READ)
    auto_fd = auto.fileno() if auto is not None else None
    if auto_fd is not None:
        sel.register(auto_fd, selectors.EVENT_READ)
    try:
        while True:
            deadline = mapper.next_deadline()
            # ⚠️ The lock watcher's own deadline must also bound the wait, or
            # select() blocks indefinitely whenever nothing else is pending --
            # exactly the state a user leaves the pad in right after typing
            # their password and letting go. Without this the unlock could
            # sit undetected until the NEXT pad event gave the loop a reason
            # to wake up, which might be much later than the user expects
            # "auto-hide" to mean.
            lock_deadline = lock_watcher.next_deadline()
            if lock_deadline is not None:
                deadline = lock_deadline if deadline is None else min(deadline, lock_deadline)
            # ⚠️ Same reasoning, and it is the load-bearing half of §5.28's fix:
            # a Deck sitting untouched on a fresh boot generates no pad events,
            # so without this deadline select() blocks until the user presses
            # something -- and the press they make is the one that must already
            # have a working environment. Polling on the loop's clock is what
            # keeps the answer ready BEFORE the first press instead of after it.
            env_deadline = SESSION_ENV.next_deadline()
            if env_deadline is not None:
                deadline = env_deadline if deadline is None else min(deadline, env_deadline)
            timeout = max(0.0, deadline - time.monotonic()) if deadline is not None else None
            ready = sel.select(timeout)
            now = time.monotonic()
            SESSION_ENV.refresh(now)
            ready_fds = {key.fd for key, _ in ready}
            # ⚠️ DISPATCH BY FD, never "something was ready so read the pad".
            # evdev opens the device non-blocking, so a read on a quiet pad
            # raises BlockingIOError -- which, once a second fd is in this
            # selector, is no longer a theoretical branch.
            if auto_fd is not None and auto_fd in ready_fds:
                want = auto.pump(osk_visible)
                if want is not None:
                    set_osk_visible(want)
                if not auto.enabled:
                    # It reported why on its way out. Stop selecting on a pipe
                    # that will be ready with EOF forever.
                    try:
                        sel.unregister(auto_fd)
                    except (KeyError, ValueError, OSError):
                        pass
                    auto_fd = None
            if pad.fd in ready_fds:
                # Pointer deltas accumulate across ONE report and are emitted
                # together on SYN_REPORT. A real mouse sends REL_X and REL_Y in
                # a single report; emitting them as two separate syn'd events
                # makes the cursor staircase -- right, then down, then right --
                # which is felt as jerkiness even though the input stream is a
                # steady 250Hz. Measured on hardware.
                pending_dx = pending_dy = 0
                try:
                    events = list(pad.read())
                except OSError as exc:
                    # ⚠️ ENODEV: the pad's node vanished WHILE BEING READ.
                    #
                    # Measured on hardware 2026-08-10 (session 18's T8 step 7
                    # pass): six crashes in one boot, `OSError: [Errno 19] No
                    # such device` out of `pad.read()`, each one killing the
                    # process. systemd restarted it -- until it would not,
                    # because StartLimitBurst is 5 in 60s, and a burst of
                    # re-enumerations exhausts that. With lizard_mode=N this
                    # process is the ONLY input path, so exhausting it leaves a
                    # handheld with no pointer and no keys.
                    #
                    # `pick_device` already knows how to wait patiently for a
                    # pad to come back -- that is what it does while Steam owns
                    # the controller. Reuse it rather than dying and hoping the
                    # restart limit holds.
                    if exc.errno != errno.ENODEV:
                        raise
                    print(f"deck-input-mapper: the pad disappeared ({exc}); "
                          "waiting for it to come back",
                          file=sys.stderr, flush=True)
                    if osk_visible:
                        set_osk_visible(False)
                    try:
                        sel.unregister(pad.fd)
                    except (KeyError, ValueError, OSError):
                        pass
                    pad = pick_device(args.device)
                    if args.grab:
                        pad.grab()
                    sel.register(pad.fd, selectors.EVENT_READ)
                    print(f"deck-input-mapper: re-bound to {pad.path} ({pad.name})",
                          file=sys.stderr, flush=True)
                    # The replacement pad may advertise different ranges.
                    if mapper.cursors is not None and osk_layout is not None:
                        mapper.cursors.ranges = {
                            code: (ai.min, ai.max)
                            for code, ai in dict(pad.capabilities().get(e.EV_ABS, [])).items()
                            if code in osk_layout.PAD_AXES
                        }
                    continue
                for event in events:
                    if event.type == e.EV_SYN and event.code == e.SYN_REPORT:
                        if pending_dx or pending_dy:
                            emit_motion(pending_dx, pending_dy)
                            pending_dx = pending_dy = 0
                        continue
                    # ⚠️ `not mapper.osk_active`. With the keyboard up the right
                    # pad is a CURSOR, not the pointer; without this it would be
                    # both at once, and the system pointer would wander across
                    # whatever is behind the keyboard. This is T8 step 6's
                    # pointer-suppression question, answered for the tty backend
                    # by never generating the motion in the first place.
                    if (event.type == e.EV_ABS and event.code in POINTER_AXES
                            and not mapper.osk_active):
                        dx, dy = mapper.pointer_delta(event.code, event.value, now)
                        pending_dx += dx
                        pending_dy += dy
                        continue
                    for key, value in mapper.translate(event.type, event.code, event.value, now):
                        emit(key, value)
                    run_pending(mapper.pending_actions)
                # A device that never sends SYN_REPORT must still move.
                if pending_dx or pending_dy:
                    emit_motion(pending_dx, pending_dy)
                # Redraw once per batch, not per event: the pads run at 250 Hz
                # and a redraw per sample would spend the whole loop writing
                # escape sequences.
                if osk_visible and osk_drawn_here:
                    if mapper.osk.closed:
                        set_osk_visible(False)
                    elif osk_tty is not None:
                        osk_draw()
                    else:
                        osk_layer_send()
            for key, value in mapper.due_repeats(now):
                emit(key, value)
            # ⚠️ OUTSIDE the `pad.fd in ready_fds` branch, like due_repeats
            # above -- this must run on every pass, including the ones woken
            # by nothing but the timeout this class asked for, or an unlock
            # with no pad activity after it goes undetected until the pad
            # moves again.
            if osk_backend == "layer" and osk_visible and lock_watcher.tick(now):
                say("the session unlocked; hiding the keyboard it was shown "
                    "across (docs/PROGRESS.md §5.24a #3)")
                set_osk_visible(False)
    except KeyboardInterrupt:
        pass
    finally:
        lock_watcher.stop()
        if auto is not None:
            auto.stop()
        if args.grab:
            pad.ungrab()
        # Erase the keyboard before leaving. A mapper that exits with its own
        # rows still painted leaves the installer looking corrupted, and the
        # TUI underneath has no reason to redraw them.
        if osk_visible and osk_tty is not None:
            try:
                osk_erase()
            except OSError:
                pass
        if osk_stream is not None:
            osk_stream.close()
        if osk_layer_proc is not None:
            osk_layer_stop()
        if ui is not None:
            ui.close()


if __name__ == "__main__":
    main()
