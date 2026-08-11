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
import selectors
import sys
import time
from dataclasses import dataclass, field

from evdev import InputDevice, UInput, ecodes as e, list_devices

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

# (axis, direction) -> key. Direction is the sign of the axis value.
HAT_MAP: dict[tuple[int, int], int] = {
    (e.ABS_HAT0X, -1): e.KEY_LEFT,
    (e.ABS_HAT0X, +1): e.KEY_RIGHT,
    (e.ABS_HAT0Y, -1): e.KEY_UP,
    (e.ABS_HAT0Y, +1): e.KEY_DOWN,
}

# The Deck's d-pad arrives as DISCRETE BUTTONS, not as the hat axes above.
# `hid-steam` advertises ABS_HAT0X/Y *and* BTN_DPAD_* but only ever sends the
# buttons -- measured on hardware 2026-08-10 with lizard mode off, where
# BTN_DPAD_UP appeared on the pad node and no ABS_HAT0Y event ever did. Before
# this table the d-pad fell through BUTTON_MAP and emitted nothing at all.
# Route it onto the same hat axes so a d-pad press and a stick push cannot
# double-hold one direction.
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

EMITTED_KEYS = sorted(set(BUTTON_MAP.values()) | set(HAT_MAP.values()))


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
    hat_dir: int = 0  # from ABS_HAT0* events, for pads that send them
    stick_dir: int = 0  # from the analog stick, after hysteresis


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
        state = self.hats[hat_axis]
        dpad = self._dpad_direction(hat_axis)
        if dpad:
            return dpad
        if state.hat_dir:
            return state.hat_dir
        return state.stick_dir

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
            if code in (e.ABS_HAT0X, e.ABS_HAT0Y):
                self.hats[code].hat_dir = 0 if value == 0 else (1 if value > 0 else -1)
                return self._hat_transition(code, self._effective_direction(code), now)
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
    while True:
        candidates = [InputDevice(p) for p in list_devices()]
        dev = _match(candidates, selector)
        if dev is not None:
            return dev

        steam_pads = [d.name for d in candidates if is_steam_virtual_pad(d)]
        if not steam_pads:
            names = ", ".join(f"{d.path}:{d.name}" for d in candidates) or "none"
            sys.exit(f"deck-input-mapper: no gamepad matched {selector!r}. Devices: {names}")

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


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--device", help="evdev path or a substring of the device name")
    ap.add_argument("--grab", action="store_true", help="EVIOCGRAB the pad so nothing else also reads it")
    ap.add_argument("--dry-run", action="store_true", help="print emissions instead of injecting")
    ap.add_argument("--verbose", action="store_true", help="log every emission to stderr")
    ap.add_argument("--list", action="store_true", help="list input devices and exit")
    args = ap.parse_args()

    if args.list:
        for path in list_devices():
            dev = InputDevice(path)
            tag = " [gamepad]" if looks_like_gamepad(dev) else ""
            print(f"{path}  {dev.name}{tag}")
        return

    pad = pick_device(args.device)
    mapper = Mapper(axis_ranges={
        code: (ai.min, ai.max)
        for code, ai in dict(pad.capabilities().get(e.EV_ABS, [])).items()
        if code in STICK_AXES
    })

    ui = None
    if not args.dry_run:
        ui = UInput({e.EV_KEY: EMITTED_KEYS}, name="deck-input-mapper virtual keyboard")

    def emit(key: int, value: int) -> None:
        if args.verbose or ui is None:
            print(f"emit {e.KEY[key]} {value}", file=sys.stderr, flush=True)
        if ui is None:
            return
        ui.write(e.EV_KEY, key, value)
        ui.syn()

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
                for event in pad.read():
                    for key, value in mapper.translate(event.type, event.code, event.value, now):
                        emit(key, value)
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
