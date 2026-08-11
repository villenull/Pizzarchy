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
import importlib.util
import pathlib
import selectors
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


def _load_osk_layout():
    """Import the layout core, or say loudly why the OSK is unavailable."""
    for directory in OSK_SEARCH_DIRS:
        path = directory / _OSK_MODULE
        if not path.is_file():
            continue
        try:
            spec = importlib.util.spec_from_file_location("deck_osk_layout", path)
            module = importlib.util.module_from_spec(spec)
            sys.modules["deck_osk_layout"] = module
            spec.loader.exec_module(module)
            return module
        except Exception as exc:  # a broken core must not cost us navigation
            print(f"deck-input-mapper: {path} failed to import ({exc}); "
                  "the on-screen keyboard is DISABLED, navigation still works",
                  file=sys.stderr, flush=True)
            return None
    print(f"deck-input-mapper: {_OSK_MODULE} not found in "
          f"{', '.join(str(d) for d in OSK_SEARCH_DIRS)}; the on-screen keyboard "
          "is DISABLED, navigation still works",
          file=sys.stderr, flush=True)
    return None


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
    # Actions the caller should perform, drained by main(). Kept as data rather
    # than executed here so the whole chord is unit-testable without a DBus
    # session or a subprocess.
    pending_actions: list[str] = field(default_factory=list)

    # Right-trackpad pointer state: last absolute sample per axis, and when it
    # arrived, so a lift-and-retouch re-baselines instead of hurling the cursor.
    pointer_last: dict[int, int] = field(default_factory=dict)
    pointer_last_seen: float = 0.0

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

    def translate(self, etype: int, code: int, value: int, now: float) -> list[tuple[int, int]]:
        if etype == e.EV_KEY:
            # STEAM+X toggles the on-screen keyboard. Checked before every
            # other key path so the X in the chord does not also type Tab.
            if code == OSK_CHORD_HOLD:
                if value in (0, 1):
                    self.mode_held = bool(value)
                return []
            if code == OSK_CHORD_PRESS and self.mode_held:
                if value == 1:
                    self.pending_actions.append("toggle-osk")
                return []
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

    def run_pending(actions: list[str]) -> None:
        """Perform queued side effects. Never blocks the input loop: a DBus
        call that hangs must not freeze the pointer."""
        nonlocal osk_visible
        while actions:
            action = actions.pop(0)
            if action != "toggle-osk":
                continue
            osk_visible = not osk_visible
            argv = OSK_TOGGLE_ARGV_SHOW if osk_visible else OSK_TOGGLE_ARGV_HIDE
            if args.verbose or ui is None:
                print(f"osk -> {'show' if osk_visible else 'hide'}", file=sys.stderr, flush=True)
            if ui is None:
                continue
            try:
                subprocess.Popen(
                    argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
                )
            except OSError as exc:
                # Loud, but not fatal: losing the OSK toggle must not take the
                # pointer down with it.
                print(f"deck-input-mapper: could not toggle the OSK: {exc}",
                      file=sys.stderr, flush=True)

    if args.grab:
        pad.grab()
    print(f"deck-input-mapper: reading {pad.path} ({pad.name})", file=sys.stderr, flush=True)

    sel = selectors.DefaultSelector()
    sel.register(pad.fd, selectors.EVENT_READ)
    try:
        while True:
            deadline = mapper.next_deadline()
            timeout = max(0.0, deadline - time.monotonic()) if deadline is not None else None
            ready = sel.select(timeout)
            now = time.monotonic()
            if ready:
                # Pointer deltas accumulate across ONE report and are emitted
                # together on SYN_REPORT. A real mouse sends REL_X and REL_Y in
                # a single report; emitting them as two separate syn'd events
                # makes the cursor staircase -- right, then down, then right --
                # which is felt as jerkiness even though the input stream is a
                # steady 250Hz. Measured on hardware.
                pending_dx = pending_dy = 0
                for event in pad.read():
                    if event.type == e.EV_SYN and event.code == e.SYN_REPORT:
                        if pending_dx or pending_dy:
                            emit_motion(pending_dx, pending_dy)
                            pending_dx = pending_dy = 0
                        continue
                    if event.type == e.EV_ABS and event.code in POINTER_AXES:
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
            for key, value in mapper.due_repeats(now):
                emit(key, value)
    except KeyboardInterrupt:
        pass
    finally:
        if args.grab:
            pad.ungrab()
        if ui is not None:
            ui.close()


if __name__ == "__main__":
    main()
