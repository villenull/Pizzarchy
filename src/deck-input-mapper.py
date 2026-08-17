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
    X (BTN_NORTH)        Backspace    delete  -- ⚠️ WAS Tab; see BUTTON_MAP
    L1 / R1              PageUp/Down  long lists
    Start / Select       Enter / Esc  mirrors, controller-menu convention

WITH THE ON-SCREEN KEYBOARD UP, the buttons match Valve's keyboard exactly
(docs/tasks/T8-onscreen-keyboard.md §9g, operator decision 2026-08-12)
    X (BTN_NORTH)        Backspace
    Y (BTN_WEST)         Space
    L3 (BTN_THUMBL)      Caps        -- state, not a keycode
    L2 (BTN_TL2)         left pad TOUCHED -> commit the left cursor's key
                         left pad LIFTED  -> Shift
    R2 (BTN_TR2)         right pad TOUCHED -> commit the right cursor's key
                         right pad LIFTED  -> Enter

DESKTOP MODE ADDS THREE BUTTONS (docs/PROGRESS.md §5.23, §5.37)
    STEAM (tap, no chord)  `omarchy-menu toggle apps`  the apps menu
    STEAM + X              the on-screen keyboard      (unchanged)
    STEAM + Y              close the focused window    the controller's SUPER+W
    QAM (the ... button)   `omarchy-menu toggle`       the Omarchy menu

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

# The force-feedback structs the pad click's haptic is built from (`Haptics`).
# ⚠️ Guarded, and the guard is not decoration: this is the one import here that
# a python-evdev old enough to still satisfy every other import could lack, and
# with lizard_mode=N an ImportError at module load costs the whole input path.
try:
    from evdev import ff as evdev_ff
except ImportError:                      # pragma: no cover -- see Haptics.start
    evdev_ff = None

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

# ⚠️ X IS BACKSPACE, NOT TAB, AND TAB IS DELIBERATELY GIVEN UP.
#
# Operator decision 2026-08-12 (docs/tasks/T8-onscreen-keyboard.md, the block
# above §9f): *"i dont care about the x is supposed to be tab functionality. i
# want the functionality of the buttons as they appear in the deck images to be
# matched exactly with our OSK"*. Valve's keyboard paints an Ⓧ badge on its
# Backspace key, and until this change ours would have been painting a badge
# that lied -- §9a records that a confidently wrong badge is worse than none.
#
# The cost is real and was weighed: §2.3 wanted Tab for archinstall's "next
# field", and nothing else emits Tab from a face button any more (the OSK still
# has a Tab KEY, so KEY_TAB stays in EMITTED_KEYS). ⛔ Do not reintroduce it as
# a binding or a badge without asking the operator.
BUTTON_MAP: dict[int, int] = {
    e.BTN_SOUTH: e.KEY_ENTER,
    e.BTN_EAST: e.KEY_ESC,
    e.BTN_WEST: e.KEY_SPACE,
    e.BTN_NORTH: e.KEY_BACKSPACE,
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

# --- IS A PAD BEING TOUCHED? measured on hardware 2026-08-12 -----------------
#
# 🔴 THERE IS NO TOUCH BIT. The native node declares 24 buttons and not one of
# them is BTN_TOUCH or BTN_TOOL_FINGER -- confirmed by a capability dump AND by
# a live capture in which no button fired during rest, lift or click. So the
# question "is a finger on this pad" cannot be asked directly, and T8 §9e warned
# that without an answer Valve's badge gating could not be reproduced at all.
#
# ✅ WHAT DOES WORK, AND IT IS A STATE RATHER THAN A TIMEOUT: a lift ZEROES the
# pad, while a resting thumb keeps emitting jittery samples at its real
# off-centre position. Captured rests sat at {-26331, 6687} and {-25598, 966};
# every captured lift put at least one axis on exactly 0.
#
#     released  <=>  at least one axis is EXACTLY 0, and neither axis is
#                    further from centre than PAD_RELEASE_RESIDUAL
#
# A timeout would get the motionless case exactly wrong -- a thumb held still
# off-centre is still touching, and would have "timed out" into released. This
# rule keeps it touched. ⛔ AND DO NOT ADD ONE AS A BACKSTOP: a capture of a
# RESTING thumb (2026-08-12) contains quiet gaps of 0.46s, 1.10s, 1.29s and
# 1.70s with the finger never leaving the pad. Silence is not a lift on this
# hardware, at any threshold a human would pick.
#
# 🔴 THE RULE USED TO BE "EXACTLY 0 ON BOTH AXES", AND THAT STUCK THE AIMING
# CURSOR ON 4% OF LIFTS. Reported by the operator as "one out of every 7 times
# maybe"; measured 2026-08-12 by capturing 23 consecutive real lifts over 45s:
#
#     22 of 23 ended {x: 0, y: 0}
#      1 of 23 ended {y: 0, x: -121}   <-- one axis zeroed, the other did not
#
#     tail of the failure:  x=270  y=17200  x=96  y=17234  x=-121  y=0
#
# So the driver can zero ONE axis and leave the other just short of centre. A
# rule demanding both never saw that release, `pad_touched` stayed True
# forever, and the cursor and badges froze until the next touch.
#
# WHY A RESIDUAL AND NOT A PLAIN DEADBAND. Three shapes were considered:
#
#   a plain deadband (|x| <= D and |y| <= D)
#       catches this and any hypothetical both-axes-short residual, but its
#       blind spot is a DISC: every thumb resting within D of dead centre reads
#       as lifted. Dead centre is a legitimate place to aim -- it is the middle
#       of the keyboard half -- so this trades a rare stuck cursor for a
#       reachable dead-and-silent click. Rejected.
#   an exact 0 on EITHER axis, with no bound on the other
#       catches this, but blinds the whole of both centre LINES: a thumb
#       resting anywhere on a centreline reads as lifted. Rejected.
#   an exact 0 on either axis AND the other within D   <-- chosen
#       the exact zero is what keeps a resting thumb touched; D only has to
#       cover how far short of centre the un-zeroed axis stops.
#
# ⚠️ KNOWN AND ACCEPTED FAILURE MODE, now slightly wider than it was: a thumb
# resting at exact dead centre reads as released, because that is byte-for-byte
# what a lift looks like -- and so does a thumb resting exactly ON a centreline
# within PAD_RELEASE_RESIDUAL of centre. That is a plus-sign of 1025 sample
# positions rather than the single point it used to be; a plain +/-256 deadband
# would have been 263169, and +/-512 would have been 1050625. `Cursors.update`
# already makes the same trade for the same reason. Do NOT paper over it with a
# heuristic (a "recently moved" timer, a jitter detector) without asking --
# every such heuristic reintroduces the timeout failure above.
#
# ⚠️ BTN_THUMB IS THE LEFT TRACKPAD'S CLICK, not a touch flag and not the left
# stick. Measured in the same capture (press 14.079s, release 14.551s). The left
# STICK click is BTN_THUMBL, which is the Caps binding below. This hardware's
# names mislead in both directions; do not "correct" either one.
PAD_TOUCH_AXES: dict[int, tuple[str, str]] = {
    DECK_LEFT_TRACKPAD[0]: ("left", "x"),
    DECK_LEFT_TRACKPAD[1]: ("left", "y"),
    DECK_RIGHT_TRACKPAD[0]: ("right", "x"),
    DECK_RIGHT_TRACKPAD[1]: ("right", "y"),
}

# How far short of centre the un-zeroed axis may stop and still be a lift.
#
# ⚠️ DERIVED FROM THE MEASUREMENT, NOT PICKED FOR ROUNDNESS. The one failing
# lift in 23 stopped 121 counts out -- 0.37% of the axis's +/-32767 half-range.
# 256 is 2.1x that: enough headroom for a residual larger than the single one
# we have seen, and small enough that the blind plus-sign above stays tiny.
#
# In the units that matter to a user: a pad's full range maps onto ONE HALF of
# the keyboard, whose widest row is 14 keys, so a half-row is 7 keys across
# 65535 counts and one key is ~9362 counts wide. 256 counts is 2.7% of a key.
# The old accepted blind spot was 0% of a key and one sample wide; this is
# still far inside the nearest hit-test boundary.
#
# ⛔ DO NOT RAISE THIS "to be safe". It is not what stops a resting thumb being
# read as lifted -- the exact-zero requirement in `pad_touched` is -- so every
# count added here buys nothing and lengthens the blind plus-sign directly.
PAD_RELEASE_RESIDUAL = 256

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

# --- 🆕 STEAM+Y CLOSES THE FOCUSED WINDOW (operator, docs/PROGRESS.md §5.37) --
#
# The controller equivalent of Omarchy's SUPER+W. Y is the only face button
# STEAM does not already claim: X is the OSK chord above, and every other
# candidate is spoken for elsewhere in this file -- QAM is BTN_BASE
# (QAM_BUTTON), L3 is Caps (OSK_CAPS_BUTTON), the pad clicks are
# BTN_THUMB/BTN_THUMB2 (PAD_CLICK_HALF) and the stick clicks BTN_THUMBL/R.
# BTN_WEST appears in BUTTON_MAP (Space) and OSK_SHORTCUTS (Space) but in
# neither case as a CHORD partner, so STEAM+Y was genuinely unbound.
CLOSE_CHORD_PRESS = e.BTN_WEST  # physical Y

# Every button that means something WHILE STEAM IS HELD, and what it queues.
#
# ⚠️ ONE TABLE, BECAUSE THE STUCK-KEY GUARD READS IT. Each of these codes also
# has a plain meaning in BUTTON_MAP (X is Backspace, Y is Space), so a press
# that lands BEFORE Steam is grabbed and a release that lands AFTER must still
# be paired -- see `chord_keys_down` and the guard at the top of `translate`.
# Adding a chord partner here without adding it to BUTTON_MAP's release path is
# how a face button gets held down forever; keeping the set in one place is what
# makes that impossible rather than merely unlikely.
CHORD_PRESSES: dict[int, str] = {
    OSK_CHORD_PRESS: "toggle-osk",
    CLOSE_CHORD_PRESS: "close-window",
}

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

# The OSK's emoji key (EMOJI_KEY, deck_osk_layout.py) queues this the same way
# QAM does -- see OnScreenKeyboard.press()'s "emoji" branch there, and
# Mapper._consume_osk_request below, which is what turns that into an entry
# here.
#
# ⚠️ NOT `[OMARCHY_MENU, "emoji"]`, even though that would follow the
# menu-root/menu-apps pattern above. `omarchy-menu` (the script OMARCHY_MENU
# names) is its own small dispatcher with a FIXED verb set --
# toggle/summon/close/refresh/ping -- and "emoji" is none of them; that argv
# would print "omarchy-menu: unknown verb 'emoji'." and exit 2. The emoji
# picker is a SEPARATE script, `omarchy-menu-emoji`, which toggles Quickshell's
# `omarchy.emojis` panel directly. Confirmed by reading, in the pinned
# checkout (iso/RUNTIME, commit 6d7826d), both `omarchy-menu-emoji` itself and
# the top-level `omarchy` dispatcher's `resolve_direct_route`: `omarchy menu
# emoji` resolves the binary `omarchy-menu-emoji` and execs it with no
# arguments -- the same script, the same effect, one fewer process and no
# ~80-file metadata scan. That script's own header comment
# (`omarchy:examples=omarchy menu emoji`) documents the indirect route; this
# takes the direct one to the same place.
EMOJI_MENU = "omarchy-menu-emoji"

MENU_ACTIONS: dict[str, list[str]] = {
    "menu-apps": [OMARCHY_MENU, "toggle", "apps"],
    "menu-root": [OMARCHY_MENU, "toggle"],
    "emoji": [EMOJI_MENU],
}

# --- what STEAM+Y runs, and why it is not `killactive` -----------------------
#
# 🔴 THE BAREWORD `killactive` DOES NOT WORK ON THIS HYPRLAND, and the way it
# fails is this project's own worst shape: `hyprctl dispatch` now takes a LUA
# EXPRESSION, so a classic dispatcher name is evaluated as a bare global,
# resolves to nil, and the call dies in stderr while the button looks bound.
# `test/unit/test-hyprctl-syntax.sh` exists for exactly this (docs/PROGRESS.md
# §5.30b) and its scanner accepts only a first argument beginning `hl.`.
#
# ✅ MEASURED ON THE DECK 2026-08-15 (Omarchy 4.0, omarchy-dev
# 4.0.0.r1744.gf002044-1, Hyprland's Lua config), not inferred from any other
# Hyprland setup:
#
#   * Omarchy binds it in LUA, and there is no `killactive` anywhere in it.
#     `grep -rn killactive /usr/share/omarchy/` returns NOTHING. The real
#     binding is one line of default/hypr/bindings/tiling.lua:
#
#         o.bind("SUPER + W", "Close window", hl.dsp.window.close())
#
#     so this is the same dispatcher SUPER+W is, spelled the same way.
#   * `type(killactive)` is `nil`; `type(hl.dsp.window.close)` is `function`
#     and `type(hl.dsp.window.close())` is `userdata` -- the Dispatcher object
#     `hl.dispatch` wants. Probed by handing `error("TYPEIS:" .. type(...))` to
#     `hyprctl dispatch`, because `hyprctl eval` NEVER REPORTS A VALUE (hazard
#     3 in test-hyprctl-syntax.sh) and an error is the only channel that does.
#   * The argv below was run live against a deliberately non-existent window
#     class and returned `ok` with the client count unchanged -- proving the
#     expression parses and dispatches without closing anything to find out.
#
# ⚠️ EXEC'd DIRECTLY, NOT SYNTHESISED AS SUPER+W, for the reason the menu block
# above gives: a synthesised chord does nothing at all if the user or upstream
# rebinds SUPER+W, with nothing to read anywhere. Exec'ing couples us to the
# dispatcher NAME instead, which is narrower and loud -- a wrong name prints a
# Lua error and exits non-zero.
#
# ⚠️ `hyprctl` NEEDS `HYPRLAND_INSTANCE_SIGNATURE`, which this service does NOT
# inherit -- the running mapper's /proc/PID/environ on the Deck carries
# XDG_RUNTIME_DIR and no signature at all, and hyprctl does not auto-detect
# (`HYPRLAND_INSTANCE_SIGNATURE not set! (is hyprland running?)`, exit non-zero).
# `spawn_detached` passes `session_environ()`, which resolves it at spawn time;
# that is §5.28's fix and this binding is dead without it.
CLOSE_WINDOW_ARGV = ["hyprctl", "dispatch", "hl.dsp.window.close()"]

# ⚠️ DELIBERATELY NOT FOLDED INTO `MENU_ACTIONS`. That table is the menus'
# alone: `run_menu_action`'s failure message names `omarchy-menu` as the thing
# to install, and `menu_binding_report` speaks about menu buttons. An entry
# here would inherit a sentence that sends whoever reads the journal after a
# dead STEAM+Y to the wrong package. `run_close_window` is the handler, and
# main()'s `run_pending` dispatches to it by name; the suite asserts that
# wiring against the source, because an action queued and handled by nobody is
# exactly the P32 "written, tested, never wired" defect.

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

# --- the OSK's button profile: Valve's, reproduced (T8 §9g) ------------------
#
# Operator decision 2026-08-12: match the buttons as they are BADGED on Valve's
# keyboard, exactly. Every entry below is drawn on that keyboard as a badge, and
# every badge drawn there is implemented here -- that symmetry is the whole
# point, because §9a established that a badge nothing implements is worse than
# no badge at all.
#
# ⚠️ THESE APPLY ONLY WHILE THE OSK IS UP. With the keyboard down the triggers
# are mouse buttons (TRIGGER_BUTTON_MAP), the pads drive the system pointer and
# the RIGHT pad's click is the left mouse button (POINTER_CLICK_BUTTON);
# nothing on Valve's keyboard says anything about that state.
#
# ⚠️ EMITTED AS A COMPLETE TAP ON THE PRESS, and nothing on the release. Same
# shape as `OnScreenKeyboard.press()`, and stuck-key-proof by construction: a
# keyboard dismissed between a button's press and its release cannot leave
# Backspace held down, which on a password field would empty it. The cost is
# that holding X does not repeat; the on-screen Backspace key does not repeat
# either, so the two agree.
OSK_SHORTCUTS: dict[int, int] = {
    e.BTN_NORTH: e.KEY_BACKSPACE,   # Ⓧ, drawn on Backspace
    e.BTN_WEST: e.KEY_SPACE,        # Ⓨ, drawn at the left edge of space
}

# ⚠️ BTN_THUMBL IS THE LEFT STICK CLICK. BTN_THUMB, one letter shorter, is the
# left TRACKPAD's click and is a different button entirely (see PAD_TOUCH_AXES).
# Binding the wrong one makes Caps fire every time a thumb clicks the pad it is
# already resting on.
#
# Caps emits NO KEYCODE. It is a state this process holds and the renderers
# draw; KEY_CAPSLOCK is deliberately never sent, because a caps lock left latched
# in the kernel would outlive the keyboard and silently shout into whatever the
# user typed next. See `Mapper.osk_caps`.
OSK_CAPS_BUTTON = e.BTN_THUMBL      # L3, drawn on the Caps key

# What a trigger means while ITS OWN pad is UNTOUCHED. Touched, it commits the
# key under that side's cursor -- which is what it has always done, and what the
# operator confirmed on hardware ("that's exactly as it should be"). The idle
# meaning is the second one Valve has and we did not.
#
# "shift" changes STATE and emits no keycode; the actual KEY_LEFTSHIFT wrapping
# happens inside `OnScreenKeyboard.press()` when a character is committed.
OSK_IDLE_TRIGGER: dict[int, str] = {
    e.BTN_TL2: "shift",   # L2, drawn on both Shift keys
    e.BTN_TR2: "enter",   # R2, drawn on Enter
}
OSK_IDLE_TRIGGER_KEYS: dict[str, int] = {"enter": e.KEY_ENTER}

# --- 🔴 CLICKING A PAD COMMITS THAT PAD'S CURSOR -----------------------------
#
# Operator, on hardware, 2026-08-12: *"the way the keyboard works in gaming mode
# is that when i press shift and then aim, i press harder on the trackpad and
# that's registered as a press"*. Valve's keyboard commits on the PAD CLICK as
# well as on the trigger, and this is not a third way of doing the same thing --
# it is the missing half of hold-to-Shift. A click needs no trigger, so the L2
# that is holding Shift never has to come up, which is the gesture
# `hold_osk_shift` was written around and previously had to declare unreachable.
#
# ⚠️ BTN_THUMB IS THE LEFT PAD'S CLICK AND BTN_THUMB2 THE RIGHT'S -- measured in
# the same 2026-08-12 capture as the touch rule above (left: press 14.079s,
# release 14.551s). ⛔ NOT `BTN_THUMBL`/`BTN_THUMBR`, one letter longer, which
# are the STICK clicks; `BTN_THUMBL` is the Caps binding below. Swapping the two
# pairs makes Caps latch every time a thumb clicks the pad it is resting on, and
# makes the click commit nothing.
#
# ⚠️ NO KEYCODE OF ITS OWN, so EMITTED_KEYS is deliberately untouched: a click
# commits through the layout core exactly as a trigger does, and every character
# key it can reach is already declared there.
#
# ⚠️ AND IT IS CONSULTED ONLY WHILE THE KEYBOARD IS UP. With the keyboard DOWN
# the right pad's click is the left mouse button instead (POINTER_CLICK_BUTTON
# below); `Mapper.translate` routes on `osk_active` and reaches exactly one of
# the two, never both.
PAD_CLICK_HALF: dict[int, str] = {
    e.BTN_THUMB: "left",
    e.BTN_THUMB2: "right",
}

# --- 🆕 AND IT BUZZES (operator, 2026-08-12) ---------------------------------
#
# Operator, on hardware: *"on the steam deck when i pad click it gives me some
# haptic feedback to feel like i pressed the trackpad"*. Ours committed
# silently. This is an ADDITION to T8's spec, not a bug fix, and it matters
# because the trackpads have no key travel: on a keyboard reached only by
# pointing, the buzz IS the press confirmation, and without it the only
# confirmation is watching the screen for a character to appear.
#
# ✅ THE INTERFACE, ESTABLISHED BY INSPECTING THE MACHINE (2026-08-12), not by
# recalling how Deck haptics usually work:
#
#   * NO haptic sysfs node and NO LED-class node. /sys/class/leds carries only
#     the keyboard LEDs, mmc0 and status:white; nothing under /sys named
#     *haptic* exists; the hid device directory
#     (/sys/bus/hid/devices/0003:28DE:1205.0003) exposes only country,
#     modalias, report_descriptor, uevent and power.
#   * WHAT DOES EXIST is force feedback on the SAME evdev node this process
#     already reads -- "Steam Deck", /dev/input/event7 -- advertising
#     FF_RUMBLE, FF_PERIODIC, FF_SQUARE/TRIANGLE/SINE and FF_GAIN, with 16
#     simultaneous effect slots (EVIOCGEFFECTS).
#   * The shipped module was disassembled to confirm what FF_RUMBLE reaches:
#     hid-steam calls input_ff_create_memless, and `steam_play_effect` copies
#     ff_effect.u.rumble.strong_magnitude and .weak_magnitude into a report
#     that `steam_haptic_rumble_cb` sends as ID_TRIGGER_RUMBLE_CMD (0xEB).
#     The Deck's "rumble" hardware IS its two trackpad actuators.
#   * The node is root:input 0660 and the session user is in group `input`,
#     so python-evdev's InputDevice already opens it O_RDWR. No new privilege,
#     no second file descriptor, no extra device.
#
# ⚠️ WHICH ACTUATOR IS PHYSICALLY WHICH IS NOT PROVEN. The report carries two
# independent magnitudes and hid-steam names them left and right; confirming
# which pad each one shakes needs an effect actually played on hardware, which
# this could not do without buzzing the operator's device mid-session. The
# mapping therefore lives in ONE dict, so flipping it is a one-line change if
# the operator reports a click on one pad buzzing the other.
PAD_HAPTIC_MAGNITUDE = 0x8000   # half of the 0..0xFFFF the FF API takes

# ⚠️ FEEL IS UNTUNED, and this is the honest state of it: 30 ms at half scale
# is a starting point chosen to be short enough to read as a click rather than
# a rumble (the kernel is CONFIG_HZ=300, so 30 ms is 9 jiffies -- comfortably
# above the timer granularity ff-memless schedules on) and strong enough to be
# felt through a thumb already pressing the pad. POINTER_DIVISOR's history is
# the precedent: only the operator saying "stronger"/"shorter" can set it.
PAD_HAPTIC_MS = 30

# strong first, weak second -- the order `steam_play_effect` reads them in.
PAD_HAPTIC_MAGNITUDES: dict[str, tuple[int, int]] = {
    "left": (PAD_HAPTIC_MAGNITUDE, 0),
    "right": (0, PAD_HAPTIC_MAGNITUDE),
}

# --- 🆕 AND SO DOES A KEY TOUCHED ON THE GLASS (operator, 2026-08-16) ---------
#
# Operator: *"when touching the osk to type, the deck should vibrate very
# slightly (as the real deck does)"*. The pad CLICK has buzzed since 2026-08-12
# (above) and always did so under BOTH OSK backends -- the buzz hangs off
# `_osk_event`, which never asked which renderer was drawing. What buzzed
# nothing at all was the TOUCH path: a finger on the overlay arrives as a key
# INDEX (`deck_osk_wayland.format_press_line`) and is committed by
# `Mapper.press_key_index`, which had no buzz in it. Only the `layer` overlay
# takes touch, so that is the backend where the silence showed.
#
# ⛔ ITS OWN EFFECT, NOT THE PAD'S ONE PLAYED TWICE. A finger on the glass has
# no side -- both actuators fire, so this is one effect carrying both magnitudes
# and one write, not two writes of the pad effects. Playing THOSE on both sides
# would also be twice the click's energy for the one gesture the operator asked
# to be *very slight*. A separate slot is what lets the two be tuned apart.
#
# ⚠️ 🎚️ THESE TWO ARE THE TUNING KNOBS, AND NOBODY WHO WROTE THEM HAS FELT
# THEM -- no tier below the operator's own hands can judge a buzz, exactly as
# PAD_HAPTIC_MS says of the click. Change them HERE and nowhere else; no test
# asserts either literal, deliberately, so tuning cannot turn a suite red.
#
#   * MAGNITUDE is the FF API's 0..0xFFFF, both actuators at once. A quarter of
#     the pad click's PAD_HAPTIC_MAGNITUDE, chosen to err quiet: on a handheld
#     resting against both palms, a tick that is too strong on EVERY keystroke
#     is worse than no tick at all.
#   * MS is MILLISECONDS of replay. Half the click's, to read as a tick rather
#     than a rumble, and still above the 3.3 ms jiffy CONFIG_HZ=300 schedules
#     ff-memless on (see PAD_HAPTIC_MS).
OSK_TOUCH_HAPTIC_MAGNITUDE = 0x2000
OSK_TOUCH_HAPTIC_MS = 15

# ⚠️ NOT A PAD HALF, but it shares `Haptics.effects`' keyspace with "left" and
# "right", so it must not collide with either. `Mapper.buzz` takes this the same
# way it takes a half; the slot is just a name for an uploaded effect.
OSK_TOUCH_HAPTIC_SLOT = "touch"

# Every effect `Haptics` uploads, in ONE table: slot -> (strong, weak, ms).
# One table because `start()` arms all-or-nothing and `buzz()` may be asked for
# any of them -- a second list would let the two drift and leave a slot that is
# asked for and was never uploaded.
HAPTIC_EFFECTS: dict[str, tuple[int, int, int]] = {
    **{half: (strong, weak, PAD_HAPTIC_MS)
       for half, (strong, weak) in PAD_HAPTIC_MAGNITUDES.items()},
    OSK_TOUCH_HAPTIC_SLOT: (OSK_TOUCH_HAPTIC_MAGNITUDE,
                            OSK_TOUCH_HAPTIC_MAGNITUDE, OSK_TOUCH_HAPTIC_MS),
}

# --- 🆕 WITH THE KEYBOARD DOWN, THE RIGHT PAD'S CLICK IS THE LEFT MOUSE BUTTON
#
# Operator, on hardware 2026-08-12: *"i should be able to click now with the
# right trackpad by pressing down (and getting a haptic response) this is the
# same as what we did for the keyboard but for the mouse"*. The right pad has
# driven the pointer since POINTER_AXES existed; pressing it down reached
# nothing at all, so the only way to click was R2 (TRIGGER_BUTTON_MAP) -- a
# different finger from the one doing the pointing, on a device where the pad
# and the trigger are on the same hand.
#
# ⛔ DERIVED FROM `PAD_CLICK_HALF`, NOT SPELLED OUT A SECOND TIME. The code is
# BTN_THUMB2 and it is measured, but this file's entire history with these four
# names is one-letter mistakes: BTN_THUMBL/BTN_THUMBR are the STICK clicks and
# BTN_THUMBL is the OSK's Caps binding. Inverting the measured table makes the
# mouse click and the keyboard's commit the SAME physical switch on the SAME
# side BY CONSTRUCTION -- they cannot drift, and if the measurement is ever
# corrected the correction lands in both at once.
#
# ⛔ THE RIGHT PAD ONLY. The left pad's click stays the keyboard's alone. The
# operator asked for the pad that carries the pointer, and a middle- or
# right-click invented for the other pad would be a binding nothing anywhere
# advertises -- T8 §9a's rule, applied to a control instead of a badge.
PAD_CLICK_BUTTONS: dict[str, int] = {half: code for code, half in PAD_CLICK_HALF.items()}
POINTER_CLICK_HALF = "right"                            # the pad POINTER_AXES reads
POINTER_CLICK_BUTTON = PAD_CLICK_BUTTONS[POINTER_CLICK_HALF]

# ⚠️ A PRESS AND A RELEASE, NOT A SYNTHESISED TAP -- see `Mapper.translate`. A
# left button that goes down and straight back up on the press makes dragging, a
# text selection and every press-and-hold in the installer impossible, and none
# of that is visible in a test that only asserts "a click happened".
POINTER_CLICK_KEY = e.BTN_LEFT

# ⚠️ The uinput device declares exactly this set, and emits NOTHING else -- the
# kernel drops an undeclared code without an error. Every character key the OSK
# can type therefore has to be in here before a renderer ever draws it, which is
# why the layout core is imported at module load rather than when the OSK opens.
#
# ⚠️ The OSK's own button shortcuts are folded in EXPLICITLY rather than left to
# overlap with BUTTON_MAP by luck. They do overlap today -- X/Backspace, Y/Space
# and R2/Enter are all navigation keys as well -- but rebinding either table
# without the other is exactly how a shortcut goes silently dead.
EMITTED_KEYS = sorted(
    set(BUTTON_MAP.values())
    | set(HAT_MAP.values())
    | set(TRIGGER_BUTTON_MAP.values())
    # ⚠️ FOLDED IN EXPLICITLY, exactly as the OSK's shortcuts are below and for
    # the same reason. BTN_LEFT is already here via TRIGGER_BUTTON_MAP today, so
    # this line changes nothing -- until someone rebinds R2, at which point the
    # pad click would go dead on the Deck with no error on any side.
    | {POINTER_CLICK_KEY}
    | set(OSK_SHORTCUTS.values())
    | set(OSK_IDLE_TRIGGER_KEYS.values())
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

    # 🔴 WHICH METRIC A COMMIT HIT-TESTS IN, AND IT IS NOT COSMETIC.
    #
    # A key carries two widths (`deck_osk_layout`'s header): `cells` is the
    # integer addressing grid the TTY renderer draws, `units` is the MEASURED
    # VISUAL width the layer-shell renderer draws. They reach the same keys per
    # row and disagree about where the boundaries fall INSIDE a half -- by up to
    # half a key.
    #
    # ⚠️ So the metric has to follow the RENDERER THAT IS ON SCREEN. Committing
    # in `cells` under the layer overlay types a key up to half a key away from
    # the white one the user is looking at: sampled across the letters layer,
    # 287 of 1010 cursor positions disagree. That is §9a's confidently-wrong
    # failure, arriving through the commit rather than through a badge.
    #
    # Defaults to `cells`, which is the TTY renderer's metric and the layout
    # core's own default -- so a backend that forgets to say gets the behaviour
    # it had, and only the layer backend has to opt in (main() does).
    osk_metric: str = "cells"

    # --- state the RENDERERS read (T8 §9g) -----------------------------------
    #
    # The keyboard's look is downstream of all three of these, so they live here
    # rather than in a renderer: two renderers must agree, and only this object
    # sees the events that change them.
    #
    #   pad_last      the last sample per pad, per axis. `pad_touched(half)` is
    #                 the badge gate: hide that side's trigger badge while its
    #                 pad is touched. Starts released, which is the
    #                 all-badges-visible state §9f screenshotted.
    #
    # ⚠️ SHIFT AND CAPS ARE NOT DUPLICATED HERE. `OnScreenKeyboard` owns them --
    # `shift` ("off"/"once"/"locked") and `caps` (a SEPARATE boolean, letters
    # only) -- and `format_state_line` already carries both to the renderers.
    # A second copy on this object would be a second truth to keep in sync, and
    # the one the renderers read is not this one. L2 and L3 below therefore
    # TOGGLE the keyboard's own state rather than shadowing it.
    pad_last: dict[str, list[int]] = field(
        default_factory=lambda: {"left": [0, 0], "right": [0, 0]}
    )

    # The `Haptics` above, or None. None in --dry-run, in every unit test that
    # does not ask for one, and whenever `Haptics.start()` said why it could
    # not arm -- which is exactly the set of cases where a pad click must still
    # commit, just without the buzz.
    haptics: "object | None" = None

    # What `shift` was before L2 was pulled, or None while L2 is not holding it.
    # This is the ONE piece of shift state this object owns, and it is not a
    # mirror: it is what a MOMENTARY modifier has to remember in order to put
    # back what it found. See `hold_osk_shift`.
    osk_shift_prev: "str | None" = None

    # Which CHORD_PRESSES buttons we are holding that emitted a real key-down.
    # See translate(): without this, pressing X, then STEAM, then releasing X
    # swallows the release and leaves Backspace held down forever.
    #
    # 🔴 A SET, NOT A BOOLEAN, SINCE STEAM+Y JOINED THE CHORDS (§5.37). Y is
    # KEY_SPACE in BUTTON_MAP, so the identical sequence -- press Y, press
    # STEAM, release Y -- would hold SPACE down for ever, and one boolean
    # shared by both buttons would have let X's release clear Y's flag. The
    # membership is per-code so the two cannot interfere.
    chord_keys_down: set[int] = field(default_factory=set)

    # Whether a BTN_LEFT we emitted from the RIGHT PAD'S CLICK is still down.
    #
    # 🔴 THE INVARIANT, AND IT IS THE WHOLE REASON THIS FIELD EXISTS: true if and
    # only if we have sent a `POINTER_CLICK_KEY` DOWN with no UP after it. Both
    # sides of `translate` consult it, so a duplicate press cannot send two
    # downs and a release we never pressed for cannot send a stray up. A stuck
    # BTN_LEFT is not a cosmetic fault on a handheld -- it is a machine that
    # drag-selects everything the pointer passes over and clicks nothing again.
    pad_click_down: bool = False

    # --- pad touch: the badge gate (measured 2026-08-12, see PAD_TOUCH_AXES) --

    def note_pad_sample(self, code: int, value: int) -> str | None:
        """Record one raw pad sample. Returns the half it belongs to, or None.

        Records EVERY value including 0 -- unlike `Cursors.update`, which
        deliberately ignores a 0 so the cursor does not snap to centre on a
        lift. The two want opposite things from the same sample: the cursor
        wants the last MEANINGFUL position, this wants the last ACTUAL one.
        """
        axis = PAD_TOUCH_AXES.get(code)
        if axis is None:
            return None
        half, which = axis
        self.pad_last[half][0 if which == "x" else 1] = value
        return half

    def pad_touched(self, half: str) -> bool:
        """Is a finger on that pad right now?

        ⚠️ `released` <=> AT LEAST ONE axis is exactly 0 and NEITHER is further
        from centre than PAD_RELEASE_RESIDUAL. The exact zero is the whole
        guard: a resting thumb reports two jittering off-centre values and can
        never satisfy it, so a motionless thumb stays touched forever, which is
        what no timeout could do. The residual exists only because 1 lift in 23
        zeroes one axis and stops 121 counts short on the other -- see
        PAD_TOUCH_AXES for the capture and for why a plain deadband was
        rejected. The blind plus-sign around dead centre is documented and
        accepted there too.
        """
        sample = self.pad_last.get(half)
        if sample is None:
            raise ValueError(f"half must be 'left' or 'right', got {half!r}")
        x, y = sample
        if x != 0 and y != 0:
            # No lift this hardware has produced looks like this. A touch --
            # including a stroke passing near, but not through, the centre.
            return True
        return max(abs(x), abs(y)) > PAD_RELEASE_RESIDUAL

    def pad_touch_state(self) -> dict[str, bool]:
        """Both pads at once, in the shape the wire protocol wants.

        🔴 THIS IS THE THIRD ARGUMENT TO `format_state_line`, AND FOR ONE
        RELEASE IT WAS NEVER PASSED. The protocol carried pad touch, the layout
        core's `hint_visible()` consumed it, and the call site in `main()` still
        used the two-argument form -- so the overlay was told every frame that
        both pads were lifted. Badges never gated and both cursors stayed on
        screen highlighting letters nobody was pointing at. Kept as a method
        rather than a dict literal at the call site so the suite can assert the
        call site passes THIS, and not a freshly-invented `{}`.
        """
        return {half: self.pad_touched(half) for half in self.pad_last}

    def reset_pad_touch(self) -> None:
        """Forget both pads. Called when the keyboard is shown, so a stale
        sample from the last showing cannot decide the first badge state."""
        for sample in self.pad_last.values():
            sample[0] = sample[1] = 0

    def reset_osk_state(self) -> None:
        """Start a showing from a known state: no modifiers, both pads lifted.

        Called by main() on every show. Without it a keyboard dismissed with
        Caps latched comes back latched, with nothing on screen having said so
        while it was gone -- and a lifted-pad reading left over from the last
        showing decides the first frame's badges.
        """
        self.reset_pad_touch()
        # A keyboard dismissed with L2 physically down never sees that release
        # (the chord is handled above the OSK branch, and a hidden keyboard
        # routes the release to the navigation profile instead). Forgetting the
        # saved value here is what stops the NEXT showing from restoring it.
        self.osk_shift_prev = None
        if self.osk is not None:
            self.osk.shift = "off"
            self.osk.caps = False

    # --- Shift and Caps: read out of the keyboard, never mirrored ------------
    #
    # ⚠️ CAPS IS NOT `shift == "locked"` (T8 §9g). "locked" is a SHIFT lock and
    # changes symbols and the arrow keys too; Caps changes letter case and
    # nothing else. The layout core keeps them as two fields for exactly that
    # reason, and these two accessors exist so nothing here has to remember it.

    @property
    def osk_shift(self) -> bool:
        """Is Shift in force? Drawn blue on both Shift keys."""
        return self.osk is not None and self.osk.shift != "off"

    @property
    def osk_caps(self) -> bool:
        """Is Caps latched? Drawn blue on the Caps key."""
        return self.osk is not None and bool(self.osk.caps)

    # --- L2 is a MOMENTARY Shift (operator, 2026-08-12) ----------------------
    #
    # 🔴 THIS REVERSES A DELIBERATE DESIGN DECISION. L2 used to arm a ONE-SHOT
    # shift, on the reasoning that "hold L2 while aiming" is a gesture this
    # input model cannot offer -- the same trigger commits the instant a thumb
    # lands on the left pad. The operator tested it and asked for hold-to-shift,
    # "as on a pc". Their call wins; the interaction the old note worried about
    # is real, so it is answered here rather than left to be rediscovered.
    #
    #   ⚠️ WHAT HAPPENS IF THE LEFT PAD IS TOUCHED WHILE L2 IS HELD: nothing at
    #   all to the shift. It stays engaged until L2 physically comes up. A
    #   modifier that evaporated because a thumb brushed a pad would type a
    #   lowercase letter while the user was visibly holding shift, which §9a
    #   calls the worst failure available -- confidently wrong. So touching the
    #   left pad under a held L2 only AIMS (its cursor and highlight appear,
    #   both L2 badges gate away), and committing from that pad must not need a
    #   fresh L2 pull, because pulling L2 again means it came up first and took
    #   Shift with it.
    #
    #   🔴 THE PAD CLICK IS WHAT MAKES THAT WHOLE PROBLEM GO AWAY, and this
    #   paragraph used to say the opposite. Until 2026-08-12 it recorded that
    #   "hold Shift and aim with the same hand" was a gesture this input model
    #   could not offer, and left the user a two-handed one. That was true only
    #   while the trigger was the sole way to commit. `PAD_CLICK_HALF` measured
    #   the other way -- press harder on the pad you are already aiming with --
    #   and it touches no trigger, so nothing about it disturbs a held L2. The
    #   reachable shifted-typing gestures are therefore:
    #
    #     one-handed -- hold L2, aim with the LEFT pad, CLICK it. Shift is
    #                   engaged the whole time, because the only thing that
    #                   releases it is L2 coming up. This is the operator's own
    #                   description of Gaming Mode, and it is what Valve's
    #                   keyboard does.
    #     two-handed -- hold L2, aim with the RIGHT pad, commit with R2 or with
    #                   that pad's click. Either way the hold is a LOCK for its
    #                   duration, so every key committed while L2 is down is
    #                   shifted, not just the first.
    #     no trigger -- the on-screen Shift key, untouched by any of this. It
    #                   still cycles off -> once -> locked, so the one-shot the
    #                   trigger used to offer is exactly where it always was.
    #
    # "locked" and not "once" is load-bearing: `OnScreenKeyboard.press()` spends
    # a "once" on the first key it modifies, which would drop shift mid-hold
    # after one character and make a held trigger behave like a tapped one.
    # The old objection to a trigger reaching a shift LOCK was that a LATCHED
    # lock is indistinguishable from Caps on screen; a lock that ends when the
    # finger lifts cannot be latched, so that objection does not apply here.

    def hold_osk_shift(self) -> None:
        """Engage Shift for as long as L2 is down, remembering what it replaced.

        Saving and restoring rather than forcing "off" on release: a lock the
        user set from the on-screen Shift key must survive a trigger pull it
        had nothing to do with. Re-entrant on purpose -- a second press with no
        release in between (one lost while the keyboard was hidden) must not
        overwrite the saved value with "locked".
        """
        if self.osk is None or self.osk_shift_prev is not None:
            return
        self.osk_shift_prev = self.osk.shift
        self.osk.shift = "locked"

    def release_osk_shift(self) -> None:
        """L2 came up: put back whatever was there before it went down.

        Runs whatever the left pad is doing now. The pad may well have been
        touched since the press -- that is the interaction documented above --
        and a shift left engaged after the trigger is up is the toggle the
        operator asked us to remove.
        """
        if self.osk is None or self.osk_shift_prev is None:
            return
        self.osk.shift = self.osk_shift_prev
        self.osk_shift_prev = None

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
        # Feed the SAME state the badge gate reads, so `pointer_lifted()` below
        # can ask `pad_touched` the one release question this file knows how to
        # ask. Without this line `pad_last` is only ever written on the OSK
        # path (`_osk_event`), and the pointer -- which runs when the keyboard
        # is NOT up -- would be asking about a sample from minutes ago.
        self.note_pad_sample(code, value)
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

    def pointer_lifted(self) -> bool:
        """Report boundary: is the right pad RELEASED? True means throw this
        report's accumulated motion away and re-baseline.

        🔴 THE OPERATOR'S "when i release, the mouse moves a non-zero distance
        in an annoying way" (2026-08-12), AND IT IS THE SAME LIFT SIGNATURE
        `pad_touched` WAS FIXED FOR AN HOUR EARLIER, in the path that had no
        such rule. `POINTER_JUMP_RAW` alone does not catch a lift: it catches
        the step to centre only when the thumb was FURTHER than 4000 counts
        out. A thumb lifting from anywhere nearer emits `int(step/125)` pixels
        of real motion toward the pad centre -- up to 31 px, in the exact
        direction the finger happened to be sitting, which is why the operator
        described the cursor as "reading exactly how i released". A lift from
        `x=-1147` (capture #6) jumps 9 px; `x=96 -> -121` (capture #8's
        residual) jumps 1. Nothing about the sample says "discontinuity"
        because, on that axis, it is not one.

        ⚠️ ONE RELEASE RULE, NOT TWO. This asks `pad_touched("right")` -- the
        PAD_RELEASE_RESIDUAL rule measured over 23 real lifts -- and asks it of
        the same `pad_last` the badges and the aiming cursor read. Two release
        rules that disagree would mean a lift that hides a badge but still
        moves the pointer, or the reverse; there is no version of that which is
        better than one imperfect rule. Its documented blind spot (a thumb at
        dead centre, or on a centre line within 256 counts) costs the pointer
        one report of motion -- ~4 ms at 250 Hz -- and then re-baselines.

        🔴 WHY AT THE REPORT BOUNDARY AND NOT PER SAMPLE. The rule needs BOTH
        axes, and a lift delivers them one after the other: `x` first, then
        `y`. Asked at the `x=0` sample, `y` still holds its pre-lift value and
        the pad reads TOUCHED -- which is exactly the sample whose motion has
        to be dropped. Asked once the report closes, both axes are in and the
        rule sees the lift it was measured on. main() already accumulates a
        report's motion and emits it on SYN_REPORT for an unrelated reason
        (staircasing), so the buffer this needs is the one already there.

        ✅ AND THE TWO ZEROES REALLY ARE IN ONE REPORT -- read out of the
        SHIPPED `hid-steam.ko` (2026-08-12), because the Deck was idle and no
        live capture could be taken. `steam_do_input_event` is inlined into
        `steam_raw_event`; the untouched-pad path is a cold block that emits
        the two axes back to back with nothing in between:

            2072:  xor %ecx,%ecx        # value = 0
                   mov $0x12,%edx       # ABS_HAT1X
                   mov $0x3,%esi        # EV_ABS
                   call input_event
            2090:  xor %ecx,%ecx        # value = 0
                   mov $0x13,%edx       # ABS_HAT1Y
                   mov $0x3,%esi
                   call input_event

        There is no `input_event(dev, EV_SYN, SYN_REPORT, 0)` between them --
        the driver syncs once, after the whole HID packet is unpacked. So a
        lift can never be split across two SYN_REPORTs, and this check can
        never run with only half of it visible. (The left pad's pair,
        `ABS_HAT0X`/`ABS_HAT0Y`, is compiled identically at `2031`.)

        ⚠️ CLEARING BOTH AXES IS DELIBERATE AND IS NOT THE RE-BASELINING BUG.
        That defect (§7) was `pointer_last = {code: value}` running on EVERY
        sample, so X and Y wiped each other and diagonal motion emitted
        nothing. This clears both only at a release -- a real touch boundary,
        exactly like the `stale` path above -- and both axes re-baseline
        together on the next touch. It is also what finally kills the
        lift-and-retouch jump inside POINTER_TOUCH_GAP that the jump clamp only
        half caught.
        """
        if self.pad_touched("right"):
            return False
        self.pointer_last.clear()
        return True

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

    def _osk_idle_trigger(self, code: int) -> list[tuple[int, int]]:
        """A trigger pulled while its own pad is UNTOUCHED -- Valve's second
        meaning for L2 and R2 (T8 §9g, and the operator's own words in §9e).

        ⚠️ L2's Shift is MOMENTARY: engaged here, released in `_osk_release`.
        The whole design, and the awkward case it has to answer, is written out
        at `hold_osk_shift`. R2's Enter is unchanged -- a complete tap on the
        press, nothing on the release, so it cannot stick down.
        """
        meaning = OSK_IDLE_TRIGGER.get(code)
        if meaning == "shift":
            self.hold_osk_shift()
            return []
        key = OSK_IDLE_TRIGGER_KEYS.get(meaning)
        if key is None:
            return []
        return [(key, 1), (key, 0)]

    def _osk_release(self, code: int) -> list[tuple[int, int]]:
        """A button coming back UP while the keyboard is shown.

        ⚠️ THE ONLY RELEASE THIS KEYBOARD ACTS ON, and it exists solely because
        Shift is momentary. Everything else here emits a complete tap on the
        press precisely so a keyboard dismissed mid-press cannot leave a key
        held down, so their releases have nothing left to do.

        Deliberately NOT gated on `pad_touched`: the press decided whether this
        trigger was a Shift or a commit, and the pad state can have changed in
        between. Gating the release the way the press is gated is the bug where
        a thumb landing on the left pad during a hold strands Shift on for ever.
        """
        if OSK_IDLE_TRIGGER.get(code) == "shift":
            self.release_osk_shift()
        return []

    def _osk_event(self, etype: int, code: int, value: int) -> list[tuple[int, int]]:
        """Route one event to the on-screen keyboard. Returns keystrokes.

        Both pads become cursors, and each trigger EITHER presses the key under
        its own cursor (that pad touched) or acts as Shift/Enter (that pad
        lifted). CLICKING a pad commits that pad's cursor and does nothing else,
        which is the gesture that lets one hand hold Shift and aim at once
        (`PAD_CLICK_HALF`). X, Y and L3 are unconditional shortcuts, exactly as
        Valve badges them. Everything else is deliberately swallowed: with the
        keyboard up, A must not also send Enter underneath, or every press does
        two things at once.

        🔴 A TRIGGER OVER AN UNTOUCHED PAD NEVER COMMITS, and since the
        operator's 2026-08-12 report that is also what the screen says: an
        untouched pad draws no cursor dot and highlights no key, because there
        is no thumb to point at one. The two halves of that rule have to agree
        or the keyboard lies -- a visible highlight the trigger would not
        commit is exactly §9a's confidently-wrong failure. The renderer's half
        is `deck_osk_wayland.draw`, fed by `pad_touch_state()` over the wire.

        ⚠️ THE BUTTONS HERE ARE THE BADGES DRAWN ON THE KEYBOARD. Changing one
        without changing the other makes the keyboard lie about itself, which
        §9a records as worse than saying nothing.
        """
        if self.osk is None or self.cursors is None:
            return []
        if etype == e.EV_ABS:
            # Touch FIRST and unconditionally: `Cursors.update` throws the 0
            # away, and the 0 is the entire lift signal.
            self.note_pad_sample(code, value)
            self.cursors.update(code, value)
            return []
        if etype != e.EV_KEY:
            return []
        if value == 0:
            # ⚠️ Releases USED to be discarded here wholesale. L2's Shift is
            # momentary now, so exactly one of them matters; see `_osk_release`.
            return self._osk_release(code)
        if value != 1:
            # The pad's own autorepeat. Never a new press, and a repeat of L2
            # must not be allowed to re-enter the hold and lose the saved state.
            return []
        half = TRIGGER_HALF.get(code)
        if half is not None:
            if self.pad_touched(half):
                return self.commit_at(half)
            return self._osk_idle_trigger(code)
        half = PAD_CLICK_HALF.get(code)
        if half is not None:
            # 🔴 THE SAME EMISSION PATH AS THE TRIGGER, on purpose: one call,
            # `commit_at` on that side's cursor. A click and a pull commit
            # identically or they will drift on shift, caps and the one-shot.
            #
            # ⚠️ GATED ON TOUCH, exactly as the trigger is, and for the same
            # reason the docstring below gives: an untouched pad draws no cursor
            # and highlights no key, so committing one would type a key nothing
            # on screen was pointing at. Physically a click IS a touch -- the
            # switch is under the pad's own surface -- so this only ever bites
            # in the documented dead-centre blind spot, where the trigger is
            # equally blind.
            #
            # ⚠️ AND A CLICK OVER A LIFTED PAD DOES NOTHING AT ALL, where the
            # trigger has a second meaning. That asymmetry is the reference's:
            # Valve badges L2/R2 on Shift and Enter and badges the pad clicks on
            # nothing, so inventing an idle meaning here would be a behaviour
            # the keyboard never advertises. §9a: worse than silence.
            if self.pad_touched(half):
                # 🔴 THE BUZZ LIVES HERE AND NOT IN `commit_at`, DELIBERATELY.
                # `commit_at` is shared with the TRIGGER, and L2/R2 are real
                # switches with real travel -- the finger already knows they
                # went down. The pad has no travel at all, which is the
                # operator's own reason for asking (PAD_HAPTIC_MAGNITUDES), so
                # the pad click is the press that needs confirming.
                #
                # ⚠️ INSIDE the touched branch. A click over a LIFTED pad
                # commits nothing (see above), and a buzz there would announce
                # a keypress that never happened -- §9a's confidently-wrong
                # failure, delivered through the thumb instead of the screen.
                self.buzz(half)
                return self.commit_at(half)
            return []
        if code == OSK_CAPS_BUTTON:
            # Caps is a state, never a keycode: see OSK_CAPS_BUTTON.
            self.osk.caps = not self.osk.caps
            return []
        key = OSK_SHORTCUTS.get(code)
        if key is not None:
            return [(key, 1), (key, 0)]
        return []

    def buzz(self, half: str) -> bool:
        """Confirm a press through the actuators. False if nothing was felt.

        `half` is a slot in `HAPTIC_EFFECTS`: a pad half for that pad's click,
        or OSK_TOUCH_HAPTIC_SLOT for a key touched on the glass.

        ⚠️ A SEPARATE CALL FROM THE COMMIT, not a return value folded into it.
        A commit that types nothing is still a commit -- Shift and Caps are real
        keys -- so the buzz cannot be conditioned on emissions without going
        quiet on exactly the two keys whose only feedback is the buzz.
        """
        if self.haptics is None:
            return False
        return bool(self.haptics.buzz(half))

    def release_pointer_click(self) -> list[tuple[int, int]]:
        """Give back a mouse button we are holding. [] if we hold none.

        🔴 FOR THE ONE RELEASE THAT NEVER ARRIVES: the pad's node vanishing
        (ENODEV) while the thumb is still pressing it. Every other way a release
        can be lost is caught inside `translate` -- the keyboard opening or
        closing mid-click routes elsewhere but the guard at the top of that
        method fires whatever state it is in. A node that is GONE sends nothing
        at all, ever, so main() has to hand the button back on its behalf before
        it rebinds. Without this the replacement pad arrives with BTN_LEFT still
        down at the kernel and every pointer movement from then on is a drag.

        Idempotent, so calling it on a mapper holding nothing is free.
        """
        if not self.pad_click_down:
            return []
        self.pad_click_down = False
        return [(POINTER_CLICK_KEY, 0)]

    def _consume_osk_request(
            self, strokes: list[tuple[int, int]]) -> list[tuple[int, int]]:
        """Turn a renderer-owned OSK request into a queued action, once.

        `OnScreenKeyboard.press()` sets `self.osk.request = "emoji"` for the
        emoji key and does nothing else -- opening the panel is this process's
        job (spawn a helper), not the layout core's. This is the one place
        both press paths (`commit_at`'s trigger/pad-click, `press_key_index`'s
        touch) funnel through, so the queue-and-clear only has to live once:
        cleared IMMEDIATELY, so the same request cannot queue twice from a
        later, unrelated press that leaves `request` untouched.

        `strokes` passes through unchanged -- this only ever sees a request
        alongside an EMPTY stroke list (the emoji key emits no keycode), but
        it does not assume that; it is a side channel, not a substitute.
        """
        request, self.osk.request = self.osk.request, ""
        if request:
            self.pending_actions.append(request)
        return strokes

    def commit_at(self, half: str) -> list[tuple[int, int]]:
        """Press the key under that side's cursor. THE one commit path.

        Both things that commit -- the trigger over a touched pad and that pad's
        CLICK -- come through here, so they cannot drift apart, and both
        hit-test in `osk_metric`, so what is typed is what is drawn. This is
        `OnScreenKeyboard.press_at` with the metric filled in; `press_at` itself
        hard-codes the layout core's default, which is right for the TTY and
        wrong under the overlay.

        Also drains any renderer-owned request that press queued (the emoji
        key) into `pending_actions` -- see `_consume_osk_request`.
        """
        return self._consume_osk_request(self.osk.press(
            self.osk.key_at(half, *self.cursors.position(half), self.osk_metric)))

    def press_key_index(self, row: int, key_index: int) -> "list[tuple[int, int]] | None":
        """Commit the key at (row, key_index) -- what a TOUCH on the overlay asks for.

        🔴 AN INDEX, NOT A COORDINATE, AND THAT IS THE WHOLE DESIGN OF THE TOUCH
        PATH. `commit_at` has to be told which metric the renderer on screen
        drew in (`osk_metric`); the overlay already knows, because it hit-tests
        its own painted rectangles (`deck_osk_wayland.key_at_pixel`). A touch
        that sent COORDINATES home would have to be re-resolved here against a
        metric this end merely believes, and the two metrics differ by up to
        half a key. The overlay resolves the key it drew; this presses it, and
        no metric is involved at all.

        🔴 AND IT IS THE SAME EMISSION PATH. Both routes end in
        `OnScreenKeyboard.press`, so shift, caps, the one-shot being spent, the
        layer switch and `closed` all behave identically whether a trigger, a
        pad click or a finger committed.

        None -- and ONLY None -- means "there is no such key": this process and
        the overlay disagree about the layout, which is a defect and is said out
        loud by the caller. An EMPTY LIST is an ordinary answer: Shift and Caps
        are real keys that type nothing.

        Also drains any renderer-owned request that press queued (the emoji
        key) into `pending_actions` -- see `_consume_osk_request`.
        """
        if self.osk is None:
            return None
        rows = self.osk.layer.rows
        if not 0 <= row < len(rows) or not 0 <= key_index < len(rows[row]):
            return None
        # 🔴 AND IT TICKS (OSK_TOUCH_HAPTIC_MAGNITUDE). Glass has even less
        # travel than a trackpad, so the argument that won the pad click its
        # buzz applies here at full strength: without it the only confirmation a
        # finger gets is watching for a character to appear.
        #
        # ⚠️ AFTER the bounds check, so an index this keyboard does not have --
        # the overlay and this process disagreeing about the layout, the one
        # thing `None` is reserved for -- announces a keystroke through the
        # palms that nothing typed. BEFORE the press, and its answer discarded,
        # for the reason `Mapper.buzz` gives: a commit that types nothing
        # (Shift, Caps) is still a commit, and haptics are best-effort.
        self.buzz(OSK_TOUCH_HAPTIC_SLOT)
        return self._consume_osk_request(self.osk.press(rows[row][key_index]))

    def translate(self, etype: int, code: int, value: int, now: float) -> list[tuple[int, int]]:
        if etype == e.EV_KEY:
            # 🔴 A HELD CHORD BUTTON ALWAYS GETS ITS RELEASE, whatever changed
            # underneath.
            #
            # X's or Y's press can be followed by STEAM being grabbed for a
            # chord, or by the keyboard opening -- and both of those branches
            # below swallow the release that belongs to a key which is
            # PHYSICALLY DOWN. Since 2026-08-12 X's key is BACKSPACE (see
            # BUTTON_MAP), so a lost release holds it down and empties whatever
            # field has focus; Y's is SPACE, which types for ever instead.
            # Blanket swallowing was survivable while X was Tab; it is not now.
            #
            # Checked before everything, because the point is that it does not
            # care what state was entered in between.
            if code in CHORD_PRESSES and value == 0 and code in self.chord_keys_down:
                self.chord_keys_down.discard(code)
                return [(BUTTON_MAP[code], 0)]
            # 🔴 AND SO DOES A HELD MOUSE BUTTON, for the same reason and with a
            # worse failure. The right pad's click is BTN_LEFT while the keyboard
            # is DOWN (POINTER_CLICK_BUTTON), and the keyboard can go UP between
            # that press and its release -- the chord is handled right here,
            # above the OSK branch, so STEAM+X with a thumb still pressing the
            # pad is exactly that sequence. Routed to `_osk_event` the release
            # would be swallowed (it acts on L2's alone) and the desktop would be
            # left with the left mouse button held down for ever: every
            # subsequent pointer movement a drag, every click a no-op.
            #
            # ⚠️ GATED ON `pad_click_down`, not on the code alone. If we never
            # emitted the down -- the press landed on the keyboard and committed
            # a key there -- this must not invent an unpaired UP, and the release
            # must go on to its normal routing rather than being eaten here.
            if code == POINTER_CLICK_BUTTON and value == 0 and self.pad_click_down:
                self.pad_click_down = False
                return [(POINTER_CLICK_KEY, 0)]
            # STEAM+X toggles the on-screen keyboard. Checked before every
            # other key path so the X in the chord does not also type Backspace.
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
            # STEAM+X toggles the keyboard, STEAM+Y closes the focused window.
            #
            # ⚠️ ONE BRANCH FOR BOTH, off CHORD_PRESSES, so a partner cannot be
            # given a chord meaning without also being given the release
            # pairing above -- the two read the same table.
            #
            # ⚠️ REACHED WHILE THE KEYBOARD IS UP TOO, deliberately: this sits
            # above the `osk_active` branch exactly as the OSK chord always
            # has. STEAM+Y therefore closes the window UNDER the keyboard
            # rather than typing a space, which is the same trade STEAM+X makes
            # (it dismisses the keyboard instead of typing Backspace).
            if code in CHORD_PRESSES and self.mode_held:
                if value == 1:
                    self.pending_actions.append(CHORD_PRESSES[code])
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
            # --- 🆕 THE RIGHT PAD'S CLICK IS THE LEFT MOUSE BUTTON -----------
            #
            # ⚠️ REACHED ONLY WITH THE KEYBOARD DOWN, and that is the entire
            # condition: `osk_active` above returned into `_osk_event`, where
            # this same button COMMITS THE HIGHLIGHTED KEY (`PAD_CLICK_HALF`) --
            # behaviour the operator verified on the panel. One button, two
            # meanings, and `osk_active` is the only thing choosing between
            # them; there is no state here that could let both fire.
            #
            # ⚠️ NOT GATED ON `pad_touched`, where the keyboard's commit IS.
            # The reason the commit is gated does not exist here: an untouched
            # pad draws no cursor and highlights no key, so committing one would
            # type a letter nothing on screen pointed at -- but the POINTER is
            # always somewhere, so a click always has a target. Gating it would
            # buy nothing and hand the documented dead-centre blind spot
            # (PAD_RELEASE_RESIDUAL) the power to swallow a click, which is the
            # silent failure this project exists to avoid. A click is also
            # physically a touch: the switch is under the pad's own surface.
            if code == POINTER_CLICK_BUTTON:
                if value != 1:
                    # A release is handled by the guard at the top of this
                    # method, whatever state it arrives in; 2 is the pad's own
                    # autorepeat and is never a new press.
                    return []
                if self.pad_click_down:
                    return []      # already down: one down, one up. See the field.
                self.pad_click_down = True
                # 🔴 BUZZ FIRST, EMIT REGARDLESS. `buzz` reports whether anything
                # was felt and the answer is DELIBERATELY discarded: haptics are
                # best-effort on hardware that may advertise no FF_RUMBLE at all
                # (`Haptics.start` says so, once, and disarms). A click that did
                # not happen because a buzz failed would be a silent swallow of
                # the one thing the user asked for.
                self.buzz(POINTER_CLICK_HALF)
                return [(POINTER_CLICK_KEY, 1)]
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
                if code in CHORD_PRESSES:
                    # Remember that this one really went down, so a release
                    # arriving after STEAM was grabbed still reaches the
                    # consumer. See the chord branch above.
                    if value:
                        self.chord_keys_down.add(code)
                    else:
                        self.chord_keys_down.discard(code)
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


# --- the SCREENSAVER, which is a different thing from the lock ---------------
#
# 🔴 THE OPERATOR'S REQUEST (2026-08-12): *"can we hide the keyboard prior to
# going into screensaver? right now the screensaver plays and the keyboard is
# still there"*. The keyboard is an `overlay` layer with `above_lock=2`, so it
# sits above a fullscreen toplevel exactly as it sits above the lock, and the
# screensaver plays around it.
#
# 🔴 AND THE ONE WAY THIS MUST NOT BE BUILT: hiding on the screensaver must
# never become hiding on the LOCK. §5.24 records that the power button produces
# a password screen the user cannot answer without this keyboard, and the fix
# was verified in pixels. `LockWatcher`'s docstring says the same. So the whole
# question is: what tells the two states apart, and how sure is that?
#
# ✅ THEY ARE DIFFERENT OBJECTS IN DIFFERENT hyprctl QUERIES. Measured on the
# Deck 2026-08-12 with the screensaver actually playing:
#
#     hyprctl -j clients   ->  [{"class": "org.omarchy.screensaver",
#                                "initialClass": "org.omarchy.screensaver",
#                                "title": "foot", "mapped": true,
#                                "fullscreen": 2, ...}]
#     hyprctl -j monitors  ->  eDP-1 solitaryBlockedBy: null
#
# The screensaver is an ordinary TOPLEVEL WINDOW -- a terminal running
# `omarchy-screensaver`. The lock is an `ext_session_lock_v1` held by the
# compositor's session-lock manager, which is what `solitaryBlockedBy` reports
# and what `lock_state_from_monitors` above reads. A window cannot appear in
# `solitaryBlockedBy` and a session lock cannot appear in `clients`: telling
# them apart is not a heuristic, it is asking two different questions of two
# different objects. That matters here more than anywhere else in this file,
# because §5.24's failure is the one this feature could reintroduce.
#
# ⚠️ THE APP-ID IS A CONTRACT, NOT AN INCIDENTAL STRING. Upstream's
# `omarchy-launch-screensaver` passes `--class=org.omarchy.screensaver` (or
# `--app-id=`) to every one of the four terminals it supports, then identifies
# its own window two ways: `pgrep -f '[o]rg.omarchy.screensaver'` for the
# already-running check, and `openwindow>>*,org.omarchy.screensaver,*` on
# Hyprland's event socket to wait for it to map. We match what upstream names
# it, and against the same field it sets.
#
# ⚠️ AND THE CHECK IS STILL NOT ALLOWED TO DECIDE ALONE. `LockWatcher.tick`
# only ever reaches this query after an EXPLICIT unlocked reading -- not
# "unknown", not "we did not ask". A screensaver playing over a lock screen
# (the idle service does not stop firing because the session locked) is
# therefore invisible to it, and the keyboard stays exactly where the user
# needs it. Fails toward doing nothing, like everything else here: unreadable,
# unparseable or an unexpected shape all return None and hide nothing.
SCREENSAVER_STATE_ARGV: tuple[str, ...] = ("hyprctl", "-j", "clients")
SCREENSAVER_APP_ID = "org.omarchy.screensaver"


def screensaver_from_clients(clients_json: str) -> bool | None:
    """True if any client window is Omarchy's screensaver; False if the JSON
    parses and none is; None if it cannot be read this way at all.

    Both `class` and `initialClass` are checked. Hyprland reports the app-id a
    window currently has AND the one it mapped with, and a terminal that
    re-announces its app-id after start would change only the first -- matching
    either costs nothing and neither field can hold this value by accident.
    """
    try:
        clients = json.loads(clients_json)
    except (TypeError, ValueError):
        return None
    if not isinstance(clients, list):
        return None
    for client in clients:
        if not isinstance(client, dict):
            continue
        if any(client.get(key) == SCREENSAVER_APP_ID
               for key in ("class", "initialClass")):
            return True
    return False


def read_screensaver_state(argv: tuple[str, ...] = SCREENSAVER_STATE_ARGV,
                           timeout: float = LOCK_STATE_TIMEOUT,
                           env=None) -> bool | None:
    """One bounded, synchronous read of Hyprland's client list.

    Same shape, same bound and same `env` requirement as `read_lock_state` --
    see the module note above that function for why a blocking call is a
    deliberate, scoped exception here. This one is asked LESS often than that
    one: `LockWatcher.tick` skips it entirely while locked, while the state is
    unknown, and on the unlock edge itself.

    ⚠️ WHAT IT COSTS, MEASURED RATHER THAN ASSUMED. On the Deck, 2026-08-12,
    eight runs each: `hyprctl -j monitors` 9.1-10.0 ms, `hyprctl -j clients`
    9.2-9.9 ms. So the worst case this adds is ~10 ms once per
    LOCK_POLL_INTERVAL (0.75 s) -- about 1.3% of the input loop, and only while
    the layer keyboard is on screen in an unlocked session. LOCK_STATE_TIMEOUT
    still bounds a hung compositor at 0.3 s, which is the number that matters.
    """
    try:
        result = subprocess.run(
            list(argv), capture_output=True, text=True, timeout=timeout,
            env=session_environ() if env is None else env)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    return screensaver_from_clients(result.stdout)


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


# What the journal says for each reason `LockWatcher.tick` can return. A dict
# rather than an if-chain at the call site so a reason added to the watcher and
# forgotten here still logs SOMETHING (the raw reason) instead of hiding the
# keyboard silently -- on this device an unexplained disappearance is the same
# symptom as a crash.
HIDE_REASONS = {
    "unlock": ("the session unlocked; hiding the keyboard it was shown across "
               "(docs/PROGRESS.md §5.24a #3)"),
    "screensaver": ("the screensaver is up and the session is NOT locked; "
                    "hiding the keyboard (T8 §9h #3)"),
}


@dataclass
class LockWatcher:
    """Decides when the keyboard should take itself off screen.

    `tick()` is meant to be called on every pass through the main loop while
    the layer-shell keyboard is on screen; it polls at most once per
    `interval` seconds and names a reason to hide, or None:

        "unlock"       a LOCKED -> UNLOCKED edge, reported exactly once
        "screensaver"  the session is UNLOCKED and Omarchy's screensaver is
                       on screen (operator request, T8 §9h #3)

    ⚠️ ONE POLL FEEDS BOTH, and the lock reading is the gate on the other.
    The screensaver query is only reached after an EXPLICIT unlocked reading:
    locked hides nothing, and unknown hides nothing. A second, independent
    watcher would have had to read the lock state for itself anyway -- and
    could have got a different answer for the same instant, which on this
    device means hiding the keyboard over a password prompt.

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
    the chord never goes through this class. `read_screensaver_state()` fails
    the same way, and one step further out: only a literal True hides.
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

    def tick(self, now: float, reader=read_lock_state,
             screensaver=read_screensaver_state) -> "str | None":
        """Poll if due. Returns why the keyboard should hide, or None.

        🔴 EVERY EARLY RETURN BELOW IS A REFUSAL TO HIDE, and the order they
        appear in is the safety argument. Nothing past the `if state:` line
        runs while the session is locked, so no reading of any other sensor --
        present or future -- can hide the keyboard a lock prompt needs.
        """
        if not self.armed or now < self.next_check:
            return None
        self.next_check = now + self.interval
        state = reader()
        if state is None:
            return None
        if state:
            self.saw_lock = True
            return None
        was_locked = self.saw_lock
        self.saw_lock = False
        if was_locked:
            return "unlock"
        # Unlocked, and not an unlock edge: the screensaver is the only other
        # thing that hides. `is True` and not truthiness -- None means the
        # question could not be answered, and an unanswered question changes
        # nothing here exactly as it changes nothing above.
        if screensaver() is True:
            return "screensaver"
        return None

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


# The C escapes systemd's `cescape_char` can emit, plus the quote characters
# it escapes inside a `$'...'` string.
_C_ESCAPES = {"a": 7, "b": 8, "e": 27, "f": 12, "n": 10, "r": 13, "t": 9,
              "v": 11, "\\": 92, "'": 39, '"': 34, "?": 63}
_HEX = "0123456789abcdefABCDEF"


def unescape_ansi_c(text: str) -> str:
    r"""Decode the body of a shell `$'...'` string.

    🔴 MEASURED ON THE DECK, and it is why this function exists at all: on a
    real session `systemctl --user show-environment` emits **six** values in
    `$'...'` form and **zero** in plain `'...'` or `"..."` form --

        GDK_BACKEND=$'wayland,x11,*'
        QT_QPA_PLATFORM=$'wayland;xcb'
        HYPRLAND_CMD=$'Hyprland --watchdog-fd 4'
        ...

    -- so the ANSI-C form is not an exotic case, it is the ONLY quoted form
    that actually occurs, and the plain-quote path below never fires here.
    Passing `$'wayland,x11,*'` through verbatim gave GTK a backend named
    `$'wayland`, which made the layer-shell keyboard fall back to an ordinary
    window: it still appeared, full-screen instead of anchored, and would
    NOT have rendered above `ext-session-lock` -- silently undoing the §5.24
    lock fix that was verified in pixels. **The keyboard worked, and was
    wrong.** Nothing on the desktop looks broken; only the lock screen does.

    Works in BYTES and decodes once at the end, so a `\xNN` pair that is half
    of a multi-byte UTF-8 character reassembles instead of becoming two
    replacement characters.

    ⚠️ An escape this does not recognise is kept LITERALLY, backslash
    included. Guessing at an unknown escape silently corrupts a value; the
    conservative choice leaves it visible.
    """
    out = bytearray()
    i, end = 0, len(text)
    while i < end:
        char = text[i]
        if char != "\\":
            out += char.encode("utf-8")
            i += 1
            continue
        i += 1
        if i >= end:                     # a trailing backslash: keep it, never crash
            out += b"\\"
            break
        esc = text[i]
        i += 1
        if esc in _C_ESCAPES:
            out.append(_C_ESCAPES[esc])
            continue
        if esc == "x" and len(text[i:i + 2]) == 2 and all(c in _HEX for c in text[i:i + 2]):
            out.append(int(text[i:i + 2], 16))
            i += 2
            continue
        if esc in "01234567":
            digits = esc
            while len(digits) < 3 and i < end and text[i] in "01234567":
                digits += text[i]
                i += 1
            value = int(digits, 8)
            # \777 is 511, which is not a byte. Keep the whole thing literal
            # rather than truncating it into a different character.
            if value <= 0xFF:
                out.append(value)
                continue
            out += ("\\" + digits).encode("utf-8")
            continue
        out += ("\\" + esc).encode("utf-8")
    return out.decode("utf-8", "replace")


def parse_show_environment(text: str) -> dict[str, str]:
    """Parse `systemctl --user show-environment` into a dict.

    systemd's output is "suitable for eval in a shell", so a value containing
    anything interesting comes back QUOTED. Three forms are handled: bare,
    shell-quoted (`'a b'` / `"a b"`), and **ANSI-C quoted (`$'a\\tb'`), which
    is the one this machine actually produces** -- see `unescape_ansi_c`.
    Unquoting rather than stripping characters keeps an embedded space,
    quote or separator intact instead of corrupting it silently.

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
        # ANSI-C first: `$'...'` also starts with a `$`, so testing for the
        # plain quote characters first would never reach it.
        if raw.startswith("$'") and raw.endswith("'") and len(raw) >= 3:
            raw = unescape_ansi_c(raw[2:-1])
        elif raw[:1] in ("'", '"'):
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


def run_close_window(dry_run: bool = False) -> bool:
    """STEAM+Y: close the focused window. True if the helper was started.

    ⚠️ SEPARATE FROM `run_menu_action` ON PURPOSE, and it is the FAILURE
    MESSAGE that earns the duplication. That function's message names
    `omarchy-menu` as the thing to install; printing it for a missing `hyprctl`
    would send whoever reads the journal after a dead button to the wrong
    package entirely. Same shape, same `spawn_detached`, accurate sentence.

    ⚠️ FIRE AND FORGET, LIKE THE MENUS. `spawn_detached` does not wait, so a
    Lua error from `hyprctl` lands in its own stderr rather than here -- what
    this can promise is that the process STARTED. See CLOSE_WINDOW_ARGV for the
    live check that the expression itself dispatches.
    """
    printable = " ".join(CLOSE_WINDOW_ARGV)
    if dry_run:
        print(f"close-window -> {printable}", file=sys.stderr, flush=True)
        return True
    if not spawn_detached(CLOSE_WINDOW_ARGV, f"run `{printable}`"):
        print("deck-input-mapper: STEAM+Y does nothing until `hyprctl` is "
              "installed and on PATH; the rest of the mapper is unaffected",
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


class Haptics:
    """One short buzz per press -- the pad that was clicked, or both actuators
    for a key touched on the glass. See HAPTIC_EFFECTS.

    🔴 FAIL-SOFT IS THE WHOLE DESIGN, AND IT IS NOT THE USUAL EXCUSE FOR
    SWALLOWING. With lizard_mode=N this process is the ONLY input path on the
    device (docs/PROGRESS.md §5.9), so an exception escaping a buzz would take
    the pointer and every key down with it. A haptics failure must cost the
    buzz and nothing else.

    ⚠️ IT IS STILL LOUD. CLAUDE.md forbids failing silently, so every reason
    this ends up disabled is printed -- ONCE. Once, because the alternative is
    a line per pad click at 250Hz, which is how a journal becomes unreadable
    and a real message becomes invisible.

    Every effect is uploaded ONCE at start. Uploading per press would put an
    ioctl and a kernel allocation on the commit path, and the device only has
    16 slots to leak into.
    """

    def __init__(self, device, ff_module=None, log=say):
        self.device = device
        self.ff = ff_module
        self.log = log
        self.enabled = False
        # half -> effect id handed back by EVIOCSFF.
        self.effects: dict[str, int] = {}

    def start(self) -> bool:
        """Upload one effect per pad. False (and a reason) if haptics are off.

        ⚠️ THE CAPABILITY IS CHECKED, not assumed. `--device` accepts any node,
        Steam's virtual pad is a real thing this mapper has latched onto before
        (see `is_steam_virtual_pad`), and a node without FF_RUMBLE would fail
        the upload with a bare errno and no hint of why.
        """
        if self.ff is None:
            self.log("no evdev.ff in this python-evdev; the pad click commits "
                     "SILENTLY (no haptic), everything else is unaffected")
            return False
        try:
            rumbles = self.device.capabilities().get(e.EV_FF, [])
        except OSError as exc:
            self.log(f"could not read {getattr(self.device, 'path', '?')}'s "
                     f"capabilities ({exc}); the pad click commits SILENTLY")
            return False
        if e.FF_RUMBLE not in rumbles:
            self.log(f"{getattr(self.device, 'path', '?')} advertises no "
                     "FF_RUMBLE; the pad click commits SILENTLY (no haptic), "
                     "everything else is unaffected")
            return False
        for slot, (strong, weak, length_ms) in HAPTIC_EFFECTS.items():
            effect = self.ff.Effect(
                e.FF_RUMBLE, -1, 0,
                self.ff.Trigger(0, 0),
                self.ff.Replay(length_ms, 0),
                self.ff.EffectType(
                    ff_rumble_effect=self.ff.Rumble(strong_magnitude=strong,
                                                   weak_magnitude=weak)),
            )
            try:
                self.effects[slot] = self.device.upload_effect(effect)
            except (OSError, ValueError) as exc:
                # ⚠️ Give back whatever went up before the failure. A half-armed
                # Haptics that buzzed one pad and not the other -- or the pads
                # and not the glass -- would read as "the right pad's click is
                # broken", which is a worse lie than no haptics at all.
                self.log(f"uploading the {slot} haptic failed ({exc}); "
                         "the pad click and touch typing commit SILENTLY, "
                         "everything else is unaffected")
                self.close()
                return False
        self.enabled = True
        return True

    def buzz(self, half: str) -> bool:
        """Play that pad's effect. Never raises; False means nothing buzzed."""
        if not self.enabled:
            return False
        effect_id = self.effects.get(half)
        if effect_id is None:
            return False
        try:
            self.device.write(e.EV_FF, effect_id, 1)
        except (OSError, ValueError) as exc:
            # Said once, then disabled. A pad whose node has gone (ENODEV on
            # re-enumeration) would otherwise print on every click forever.
            self.enabled = False
            self.log(f"the haptic write failed ({exc}); pad clicks now commit "
                     "SILENTLY, everything else is unaffected")
            return False
        return True

    def close(self) -> None:
        """Hand the effect slots back. Idempotent; called on every exit path
        and before re-binding to a replacement pad."""
        self.enabled = False
        for effect_id in self.effects.values():
            try:
                self.device.erase_effect(effect_id)
            except (OSError, ValueError):
                # The node going away IS the usual reason to be here.
                pass
        self.effects = {}


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
        # STEAM+Y is here rather than in a report of its own because it fails
        # for the SAME first reason: no STEAM button, no chord. The `hyprctl`
        # caveat is its own and is named where it bites (CLOSE_WINDOW_ARGV).
        f"STEAM+Y (close the focused window) -> `{' '.join(CLOSE_WINDOW_ARGV)}`",
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
            "node and NONE of the bindings above can fire")
    elif lizard.strip().upper() == "N":
        lines.append(f"lizard_mode is {lizard}: STEAM and QAM reach this process")
    else:
        lines.append(
            f"lizard_mode is {lizard}, so the firmware SWALLOWS STEAM and QAM "
            "entirely -- they reach no evdev node and NONE of the bindings above can "
            f"fire. `echo N | sudo tee {LIZARD_MODE_PATH}` re-enables them, and "
            "does not survive a reboot (docs/PROGRESS.md §5.21)")
    return [f"deck-input-mapper: {line}" for line in lines]


# --- the readiness signal: "bound" (T4-screen-spec.md §2.3) ------------------
#
# 🔴 WHAT THIS MARKER PROMISES, AND WHY A CONSUMER MAY TRUST IT.
#
# `src/deck-form.sh` starts a mapper, waits up to 5 s for a line containing
# `DECK_OSK_BOUND_MARKER` (its own constant, spelled exactly as BOUND_MARKER
# below), and then runs a `gum` prompt that the user types into. So the marker
# is not "the process started" and not "a device was opened": it is
#
#     EVERY INPUT PATH THIS INVOCATION WAS ASKED FOR IS LIVE RIGHT NOW.
#
# Concretely, at the moment it is printed:
#
#   1. a pad has been picked (`pick_device` WAITS rather than returning a
#      half-open device, so reaching this point is itself the guarantee), it
#      has been grabbed if `--grab` asked, its haptics are armed, and
#   2. its fd is registered in the selector -- i.e. the very next thing this
#      process does is read that pad. A marker printed before the register is
#      a marker printed while the pad's events go nowhere, which is exactly
#      T4-screen-spec.md §6.4's lie #2 ("a silent input path"), and
#   3. the uinput keyboard is open (or `--dry-run` deliberately replaced it
#      with printing), so a keystroke has somewhere to go, and
#   4. if `--osk-start-shown` asked for a keyboard, THE KEYBOARD IS DRAWN.
#      Not requested -- drawn. The tty backend can fail to draw for three
#      separate reasons that all leave the process alive and navigating (no
#      OSK modules, an unopenable tty, a console too narrow to fit a row), and
#      every one of them would otherwise produce a mapper that looks ready and
#      types blind.
#
# When 4 cannot be established the marker is NOT printed and a line saying so
# is printed instead -- deliberately worded so it does NOT contain BOUND_MARKER
# as a substring, because the consumer greps for it with `grep -F`. The
# consumer then times out and degrades loudly, which is the behaviour
# T4-screen-spec.md §2.3 step 2 specifies ("the prompt runs WITHOUT an OSK,
# which is a degradation the screen must state, not swallow").
#
# ⚠️ THE ONE THING IT CANNOT VOUCH FOR IS SQUEEKBOARD. The `dbus` backend shows
# the keyboard by spawning a detached toggle command in another process; there
# is nothing to observe and nothing to wait on. Rather than either lying or
# hanging, the marker is printed with the state named in the line itself. No
# consumer waits on a dbus mapper today (deck-form.sh spawns `--osk-backend=tty`
# only), and a future one reading this line can see exactly which half of the
# promise it is getting.
BOUND_MARKER = "deck-input-mapper: bound"

# The four things the report can say about the keyboard. Named rather than
# spelled inline at each site so a typo is an ImportError-shaped failure
# instead of a branch that quietly never matches.
OSK_NOT_ASKED = "not-asked"    # no --osk-start-shown: navigation only, and ready
OSK_DRAWN = "drawn"            # ours, and on the screen. The strong promise
OSK_DISPATCHED = "dispatched"  # squeekboard was asked over DBus; unobservable
OSK_MISSING = "missing"        # asked for, ours to draw, and NOT on the screen


def osk_state_at_bind(want: bool, backend: str, *, visible: bool,
                      usable: bool) -> str:
    """Which OSK_* state a bind report should carry.

    `want`    -- should a keyboard be on the screen at this instant? At startup
                 that is `--osk-start-shown`; after a re-enumeration it is
                 whether one was up when the pad vanished, so a keyboard the
                 user dismissed on purpose is not reported as missing.
    `visible` -- what this process BELIEVES (`osk_visible`).
    `usable`  -- what is actually true of the drawing machinery (the caller
                 knows which backend it is; see `osk_usable` in main()).

    Both of the last two, never one: `set_osk_visible(True)` sets `osk_visible`
    unconditionally, including on the paths where the tty backend has already
    been disabled and nothing is drawn at all.
    """
    if not want:
        return OSK_NOT_ASKED
    if backend == "dbus":
        return OSK_DISPATCHED
    return OSK_DRAWN if (visible and usable) else OSK_MISSING


def bound_report(path: str, name: str, osk: str) -> list[str]:
    """The lines to print at a bind -- with the marker, or with the reason.

    ⚠️ THE ONLY PLACE BOUND_MARKER IS PRODUCED. Both bind sites in main()
    (startup and the ENODEV re-bind) go through here, so "ready" has one
    definition rather than two that agreed on the day they were written.
    """
    if osk == OSK_MISSING:
        # NB: must not contain BOUND_MARKER -- the consumer greps -F.
        return [f"deck-input-mapper: reading {path} ({name}), but the "
                "on-screen keyboard was asked for and is NOT on the screen; "
                "NOT reporting ready. Navigation still works and text entry "
                "does not"]
    suffix = {
        OSK_NOT_ASKED: "no keyboard was asked for, so this is navigation only",
        OSK_DRAWN: "with the on-screen keyboard drawn",
        OSK_DISPATCHED: "the keyboard was requested from squeekboard over "
                        "DBus, whose appearance this process cannot observe",
    }[osk]
    return [f"{BOUND_MARKER} to {path} ({name}) -- {suffix}"]


# --- the tty keyboard's console geometry (T8 §9g) ----------------------------
#
# 🔴 READ AT RUNTIME, ON BOTH AXES, NEVER ASSUMED. `docs/PROGRESS.md` §7 measured
# the two consoles this ships to and they are NOT the same size: the live ISO's
# is 50x160 and the installed TTY's is 25x80, on the same panel. And R-49
# measured that neither number is even stable for the life of the process --
# `TIOCSWINSZ` (`stty rows`/`stty cols`) does not merely change what a Linux VT
# REPORTS, it resizes the console itself -- so a geometry read once at startup
# can be wrong by the time anything is drawn with it.
#
# ⚠️ WIDTH IS NOT THE COSMETIC AXIS. A row too tall is clipped; a row too WIDE is
# wrapped by the VT, which turns each keyboard row into two, pushes the rows
# below it down, and scrolls the bottom of the keyboard off the screen -- R-49's
# defect arriving sideways. Since §9g the 16-cell grid at `KEY_CELL = 5` is
# EXACTLY 80 columns, so on the installed TTY there is no slack at all: one
# column of error is a corrupted keyboard, on the only keyboard the installer
# has.

# What to assume when the size cannot be read at all. The INSTALLED TTY's
# measured geometry -- deliberately the SMALLER of the two consoles above, so a
# wrong assumption makes the width guard refuse to draw rather than let it draw
# off the edge of a console that turned out to be narrow.
CONSOLE_ROWS_DEFAULT = 25
CONSOLE_COLS_DEFAULT = 80


def console_geometry(fd: int) -> tuple[int, int]:
    """`(rows, columns)` of the console behind `fd`, RIGHT NOW.

    ⚠️ A FAILED READ FALLS BACK; IT DOES NOT RAISE. Same contract as everything
    else on the drawing path: a console that will not answer must not take the
    input layer down with it (see `osk_draw`, and `docs/PROGRESS.md` §5.9 --
    with `lizard_mode=N` this process is the only input path on the device).
    Falling back is not swallowing: the caller still checks the geometry it got
    against the keyboard it wants to draw, and refuses loudly if they disagree.

    Not cached, by contract -- see the section header. Callers re-ask on every
    draw and the cost is one `TIOCGWINSZ`.
    """
    try:
        size = os.get_terminal_size(fd)
    except OSError:
        return CONSOLE_ROWS_DEFAULT, CONSOLE_COLS_DEFAULT
    return size.lines, size.columns


def narrow_console_notice(needed: int, cols: int) -> list[list[tuple[str, bool]]]:
    """The one line drawn INSTEAD of a keyboard too wide for the console.

    🔴 WHY A NOTICE AND NOT `osk_fall_back()`. On the `tty` backend the fallback
    is terminal: there is no squeekboard and no session bus in the installer, so
    it disables the keyboard for the rest of the session. Doing that on a width
    reading would be wrong twice over -- the reading is not necessarily
    permanent (`stty cols` resizes a VT mid-run, R-49, which is the same reason
    the geometry is re-read every draw), and the outcome it produces is the
    worst one available: no way to type a Wi-Fi passphrase on a device with no
    keyboard attached. So this is REFUSE AND RETRY, not refuse and give up:
    nothing is drawn wider than the console, the next draw re-measures, and a
    console widened back gets its keyboard back with no restart.

    ⚠️ AND IT IS SAID ON THE SCREEN, not only to stderr. The failure mode this
    replaces -- wrapped rows -- looks to a user like a garbled keyboard with no
    explanation, and in the installer stderr goes to a journal nobody is
    reading. A line that says the two numbers is the difference between "this is
    broken" and "widen the console".

    The text degrades down a ladder rather than being truncated at an arbitrary
    point, because the numbers are the whole payload; the last rung keeps the
    marker even when nothing else fits. Returned already shaped as
    `deck_osk_tty` rows (one highlighted segment -- reverse video, because on a
    console that is the only emphasis there is) so the caller hands it to the
    same `write_at`, under the same guards, as the keyboard it replaces.
    """
    for text in (f"KEYBOARD NEEDS {needed} COLUMNS, CONSOLE HAS {cols}",
                 f"KEYBOARD NEEDS {needed} COLS, HAS {cols}",
                 f"OSK {needed}>{cols}",
                 "OSK !"):
        if len(text) <= cols:
            return [[(text, True)]]
    return [[("OSK !"[:max(cols, 0)], True)]]


def rows_for_console(keyboard: list, needed: int, cols: int) -> tuple[list, bool]:
    """What to draw on a console `cols` wide, and whether it is the keyboard.

    ⚠️ THE BOUNDARY LIVES HERE, in a function a test can enter, rather than as a
    comparison buried in a closure inside `main()` that no unit test can reach.
    One column of drift in either direction is a real defect -- too tight and
    the installed TTY never gets a keyboard at all, too loose and it gets a
    wrapped one -- and neither is visible until a Deck is in front of someone.

    `>` and not `>=`: a row that EXACTLY fills the console is safe, which is the
    whole reason 80-in-80 is usable rather than merely arithmetic. `write_at`'s
    docstring has the mechanism -- the VT defers its wrap until the next
    character, and the next thing written is always an absolute cursor move.
    """
    if needed > cols:
        return narrow_console_notice(needed, cols), False
    return keyboard, True


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
    ap.add_argument("--osk-start-shown", action="store_true",
                    help="come up with the keyboard already on the screen, "
                         "instead of waiting for the STEAM+X chord. The "
                         "installer's entry point (T4-screen-spec.md §2.3): "
                         "the chord is one of the six buttons lizard mode "
                         "swallows, so it cannot be how the keyboard is first "
                         "summoned on a Deck that has not yet turned lizard "
                         "mode off")
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

    # ⚠️ REFUSED, NOT RECONCILED. "Start with the keyboard shown" and "there is
    # no keyboard" cannot both be honoured, and silently dropping either one
    # ships a caller that believes something false: drop the flag and a prompt
    # waits out its whole deadline for a marker that will never come; drop the
    # backend and a device the operator deliberately gave no keyboard grows
    # one. CLAUDE.md: never silently swallow a failure. `ap.error` exits 2 with
    # the message on stderr, which is where every other complaint here goes.
    #
    # Repeating either flag is a no-op (`store_true`), so this stays true of
    # `--osk-start-shown --osk-start-shown` and of a wrapper that appends the
    # flag to an argv that already had it -- the idempotence the installer's
    # re-runnable scripts need.
    if args.osk_start_shown and args.osk_backend == "none":
        ap.error("--osk-start-shown asks for the keyboard to be on the screen "
                 "at startup, and --osk-backend=none asks for there to be no "
                 "keyboard at all. Pick one: drop --osk-start-shown for "
                 "navigation only, or name a backend (dbus, tty, layer)")

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

    # --- the pad click's haptic confirmation (PAD_HAPTIC_MAGNITUDES) --------
    #
    # ⚠️ NOT UNDER --dry-run. That flag's promise is that nothing leaves this
    # process, and a buzz is the one emission a user would feel rather than
    # read. `mapper.haptics` staying None is exactly the silent-commit path,
    # which is what --dry-run should behave like.
    def arm_haptics(device) -> "Haptics | None":
        """A started `Haptics`, or None -- having said which, and why."""
        if args.dry_run:
            return None
        haptics = Haptics(device, ff_module=evdev_ff)
        return haptics if haptics.start() else None

    mapper.haptics = arm_haptics(pad)

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

    def flush_motion() -> None:
        """Emit one report's worth of accumulated pointer motion -- unless that
        report was the LIFT, in which case it is dropped.

        🔴 THE ONLY DRAIN, and that is the point. There are two places a report
        can end (SYN_REPORT, and the end of a batch from a device that sends
        none), and a release check on only one of them is a release check that
        can be walked around. `Mapper.pointer_lifted` carries the reasoning and
        the measurement; this is where it has to be asked, because the buffer it
        needs to discard lives here.
        """
        nonlocal pending_dx, pending_dy
        if mapper.pointer_lifted():
            pending_dx = pending_dy = 0
        if pending_dx or pending_dy:
            emit_motion(pending_dx, pending_dy)
        pending_dx = pending_dy = 0

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
    # The overlay's stdout -- the ONE thing that travels UP the pipe, and it
    # exists only for touch (`deck_osk_wayland.parse_press_line`). Registered in
    # the selector for exactly the span the overlay is alive, so a finger on the
    # keyboard wakes this loop the same way a thumb on a pad does.
    osk_layer_fd = None
    osk_layer_buffer = b""
    osk_layer_module = None
    # How many lines the overlay sent that were not press lines. Counted so the
    # complaint is made ONCE: this crosses a process boundary, and a chatty or
    # mismatched overlay must not be able to flood the journal from a keypress.
    osk_layer_ignored = 0
    # The console width we last complained about being too narrow, or None while
    # the keyboard fits. NOT a cache of the width -- that is re-read every draw
    # (`_console_cols`). It exists so the complaint is made once per distinct
    # width rather than several times a second for as long as a thumb is moving
    # a cursor, and so a console widened and re-narrowed complains again.
    osk_narrow_at = None
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
            # 🔴 THIS RENDERER DRAWS IN `units`, SO COMMITS MUST HIT-TEST IN
            # `units`. Without this line a trigger or a pad click types a key up
            # to half a key away from the white one under the cursor -- 287 of
            # 1010 sampled positions disagree. See `Mapper.osk_metric`. The tty
            # backend below deliberately does NOT set it: it draws `cells`.
            mapper.osk_metric = osk_layout.UNITS
            # ⚠️ IMPORTED FOR ITS PROTOCOL, NOT RUN. The overlay is a separate
            # process (see `osk_layer_start`); this is the same trick `AutoShow`
            # uses with `deck_osk_focus` -- the module that WRITES a line is the
            # module that parses it, so there is one definition of the format
            # rather than two that agreed on the day they were written.
            #
            # Safe to import here: `deck_osk_wayland` imports `gi` inside its
            # own main() precisely so its geometry is importable on a machine
            # with no GTK, and nothing at its module scope touches a display.
            osk_layer_module = _load_module("deck_osk_wayland")
            if osk_layer_module is None:
                # It said why. The keyboard still draws and the pads still
                # drive it; only TOUCHING the glass is lost.
                say("the overlay's line protocol could not be imported, so "
                    "TOUCH on the keyboard is DISABLED; the pads, the triggers "
                    "and the pad clicks are unaffected")
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
        return console_geometry(osk_stream.fileno())[0]

    def _console_cols() -> int:
        """The console's WIDTH right now -- the twin of `_console_rows`.

        Measured every draw and for the same reason: `stty cols` resizes a VT
        exactly as `stty rows` does (R-49), and the two consoles this ships to
        are 160 and 80 columns wide (`docs/PROGRESS.md` §7). An unread width is
        not a cosmetic risk but a wrapped row, which pushes every row below it
        down and corrupts the whole drawing. An unreadable console falls back
        rather than raising; see `console_geometry`.

        🔴 SINCE P33/B THIS VALUE IS AN INPUT TO THE RENDER, NOT ONLY A CHECK ON
        IT. The keyboard is no longer "exactly 80 columns" -- `osk_tty.render`
        derives its cell width from the number passed here, so this must be read
        BEFORE the render and handed to it. It was read after, and passed to
        nothing, until 2026-08-15: the adaptive grid was written, unit-tested and
        completely inert, because the one call site still rendered at the
        default. That is the P32 shape (`docs/PROGRESS.md` §5.32) and it very
        nearly shipped again inside the fix for it.
        """
        return console_geometry(osk_stream.fileno())[1]

    def _osk_draw() -> None:
        nonlocal osk_narrow_at
        height = _console_rows()
        cols = _console_cols()
        rows = osk_tty.render(mapper.osk, mapper.cursors, cols)
        needed = osk_tty.width(rows)
        top = args.osk_top_row
        if top <= 0:
            top = max(1, height - len(rows) + 1)
        draw, fits = rows_for_console(rows, needed, cols)
        if fits:
            osk_narrow_at = None
        else:
            # Too narrow to draw. Refuse and retry -- never fall back, never
            # crash, never put a single column past the edge. The reasoning is
            # on `narrow_console_notice`; the region is cleared first so a
            # keyboard drawn at a wider size a moment ago does not survive
            # underneath the notice and read as half a keyboard.
            if osk_narrow_at != cols:
                osk_narrow_at = cols
                print(f"deck-input-mapper: the keyboard needs {needed} columns "
                      f"but {args.osk_tty} has {cols}; drawing it would wrap "
                      "every row and push the keyboard off the bottom, so a "
                      "notice is drawn instead. Widen the console "
                      f"(`stty cols {needed}`) and it comes back on the next "
                      "draw -- nothing is disabled",
                      file=sys.stderr, flush=True)
            osk_tty.clear_at(osk_stream, rows, top)
        osk_tty.write_at(osk_stream, draw, top, console_rows=height,
                         console_cols=cols)

    def _osk_erase() -> None:
        # Same width as _osk_draw, though only len(rows) is used below: an erase
        # computed at a different cell width than the draw it undoes is a trap
        # waiting for the day this starts reading the row TEXT.
        rows = osk_tty.render(mapper.osk, mapper.cursors, _console_cols())
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
            # ⚠️ stdout IS A PIPE NOW, AND A PIPE MUST BE DRAINED -- see
            # `osk_layer_pump`. It carries touches back and nothing else; the
            # overlay says everything a human needs on stderr, which stays
            # INHERITED so it lands in this service's own journal.
            #
            # ⚠️ ...AND DEVNULL IF WE COULD NOT LOAD ITS PROTOCOL. A pipe with
            # no reader fills at 64KB and then BLOCKS the writer -- which here
            # is the overlay's GTK thread, i.e. a keyboard frozen mid-draw on a
            # device whose only other input path is this process. Discarding is
            # the only safe thing to do with a stream nothing can parse.
            osk_layer_proc = subprocess.Popen(
                [sys.executable, str(osk_layer_script)],
                stdin=subprocess.PIPE,
                stdout=(subprocess.PIPE if osk_layer_module is not None
                        else subprocess.DEVNULL),
                text=True, env=session_environ(),
            )
        except OSError as exc:
            osk_layer_proc = None
            osk_fall_back(f"could not start the overlay: {exc}")
            return
        osk_layer_watch()
        osk_layer_send()

    def osk_layer_watch() -> None:
        """Select on the overlay's stdout for as long as it lives.

        🔴 IT HAS TO BE IN THE SELECTOR, not polled after pad events. A finger
        on the glass is often the ONLY thing happening -- both thumbs are off
        the pads -- so a loop that woke only for the pad would sit in select()
        holding the keystroke until something else moved.
        """
        nonlocal osk_layer_fd, osk_layer_buffer
        # `stdout is None` is exactly the DEVNULL case above: no protocol, no
        # touch, nothing to select on -- and nothing that can block, either.
        if osk_layer_proc is None or osk_layer_proc.stdout is None:
            return
        if osk_layer_module is None:
            return
        osk_layer_buffer = b""
        osk_layer_fd = osk_layer_proc.stdout.fileno()
        try:
            sel.register(osk_layer_fd, selectors.EVENT_READ)
        except (KeyError, ValueError, OSError) as exc:
            osk_layer_fd = None
            # Not fatal, and not silent: the keyboard still draws and the pads
            # still commit; only touch is lost.
            say(f"could not watch the overlay's pipe ({exc}); TOUCH on the "
                "keyboard is DISABLED for this showing")

    def osk_layer_unwatch() -> None:
        """Stop selecting on it. Called before anything closes it."""
        nonlocal osk_layer_fd
        if osk_layer_fd is None:
            return
        try:
            sel.unregister(osk_layer_fd)
        except (KeyError, ValueError, OSError):
            pass
        osk_layer_fd = None

    def osk_layer_pump() -> None:
        """A touch arrived on the overlay: commit the key it landed on.

        ⚠️ NEVER BLOCKS. Called only when the selector says this fd is ready, so
        one `os.read` returns what is there or EOF -- with `lizard_mode=N` this
        process is the only input path on the device (docs/PROGRESS.md §5.9) and
        a read that waited would freeze the pad, the pointer and the keys.
        """
        nonlocal osk_layer_buffer, osk_layer_ignored
        if osk_layer_proc is None or osk_layer_proc.stdout is None:
            return
        try:
            chunk = os.read(osk_layer_fd, 4096)
        except (BlockingIOError, InterruptedError):
            return
        except OSError as exc:
            osk_layer_died(f"the overlay's pipe failed ({exc})")
            return
        if not chunk:
            # EOF: it exited. Previously this was only ever noticed on the next
            # state line, i.e. the next time a thumb moved.
            osk_layer_died("the overlay exited")
            return
        lines, osk_layer_buffer = osk_layer_module.split_lines(
            osk_layer_buffer + chunk)
        pressed = False
        for line in lines:
            index = osk_layer_module.parse_press_line(line)
            strokes = None if index is None else mapper.press_key_index(*index)
            if strokes is None:
                osk_layer_ignored += 1
                if osk_layer_ignored == 1:
                    say(f"the overlay said {line!r}, which is not a key this "
                        "keyboard has; ignoring it and any like it")
                continue
            for key, value in strokes:
                emit(key, value)
            pressed = True
        if not pressed:
            return
        # The press may have latched Shift, toggled Caps, switched layer or
        # closed the keyboard, and nothing else will redraw until a pad moves --
        # which after a touch may be never.
        if mapper.osk.closed:
            set_osk_visible(False)
            return
        osk_layer_send()

    def osk_layer_died(reason: str) -> None:
        """The overlay is gone. Same handling as a failed write, one place."""
        nonlocal osk_layer_proc
        osk_layer_unwatch()
        try:
            if osk_layer_proc is not None and osk_layer_proc.stdout is not None:
                osk_layer_proc.stdout.close()   # or the fd leaks on every failure
        except OSError:
            pass
        osk_layer_proc = None
        osk_fall_back(reason)
        osk_dbus_toggle(True)

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
            osk_layer_unwatch()
            osk_layer_proc = None
            osk_fall_back(f"the overlay exited with status {exited}")
            osk_dbus_toggle(True)
            return
        try:
            # 🔴 THREE ARGUMENTS. The third is what tells the overlay which
            # pads have a thumb on them -- the badge gate AND, since the
            # operator's 2026-08-12 report, whether each cursor is drawn at
            # all. The overlay cannot work it out: pad contact is an evdev
            # fact (the last sample being exactly 0,0) and the overlay never
            # sees the device. Dropping it back to two arguments compiles,
            # runs, and silently reinstates both defects.
            osk_layer_proc.stdin.write(
                osk_layout.format_state_line(mapper.osk, mapper.cursors,
                                             mapper.pad_touch_state()))
            osk_layer_proc.stdin.flush()
        except (BrokenPipeError, OSError) as exc:
            osk_layer_died(f"the overlay went away: {exc}")

    def osk_layer_stop() -> None:
        nonlocal osk_layer_proc
        # ⚠️ BEFORE anything closes the pipe: an fd left in the selector is
        # ready-with-EOF for ever, which spins this loop at 100% -- and once the
        # number is reused by the next overlay, it is ready for the WRONG one.
        osk_layer_unwatch()
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
        try:
            if osk_layer_proc.stdout is not None:
                osk_layer_proc.stdout.close()   # or the fd leaks, one per showing
        except OSError:
            pass
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
                mapper.reset_osk_state()
                osk_draw()
            else:
                osk_erase()
            return
        if osk_backend == "layer" and osk_drawn_here:
            mapper.osk_active = visible
            if visible:
                mapper.osk.closed = False
                mapper.reset_osk_state()
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

    def osk_usable() -> bool:
        """Is the keyboard WE draw actually on the screen right now?

        The counterpart to `osk_visible`, which is only ever what this process
        was ASKED for. Every branch below is a way the tty or layer keyboard
        can be absent while `osk_visible` is True and this process is happily
        alive and navigating:

          * `osk_tty is None`   -- the modules would not load, `--osk-tty`
                                   would not open, or `osk_fall_back` disabled
                                   it after a failed write (backend "none").
          * `osk_narrow_at`     -- the console is narrower than the keyboard,
                                   so `_osk_draw` drew a NOTICE instead of a
                                   keyboard (§9g / R-49). Blind typing, drawn
                                   politely.
          * the overlay's exit  -- a layer-shell client that started and died
                                   looks identical to a healthy one until its
                                   pipe is used.

        Only consulted at a bind, so `poll()` here costs nothing in the loop.
        """
        if osk_backend == "tty":
            return (osk_tty is not None and osk_stream is not None
                    and osk_narrow_at is None)
        if osk_backend == "layer":
            return (osk_drawn_here and osk_layer_proc is not None
                    and osk_layer_proc.poll() is None)
        return False

    def report_bound(want_osk: bool) -> None:
        """Say whether this mapper is ready to deliver keystrokes.

        🔴 CALLED FROM EXACTLY TWO PLACES -- once after the startup bind, once
        after the ENODEV re-bind -- and from nowhere else, because everything
        the marker promises (BOUND_MARKER's comment) has to be true at the call
        site and only those two sites can make it so.

        THE RE-BIND RE-EMITS IT, DELIBERATELY. `src/deck-form.sh` waits once and
        then types for as long as the user takes, so re-emitting cannot confuse
        it (its `grep -F` already matched the first line, and matching again is
        the same answer). What re-emitting buys is the honesty of the pairing:
        a re-enumeration TEARS THE KEYBOARD DOWN (§5.9's ENODEV path hides it
        before rescanning), and a mapper that came back with no keyboard, or
        that came back on a pad whose axes it could not re-range, would
        otherwise be indistinguishable in the log from one that never wobbled.
        R-44 made this a hot path, not a theoretical one. So: one line per bind,
        each one meaning the same thing about the state at that moment, and a
        consumer that wants "is it ready NOW" can read the last one.
        """
        for line in bound_report(
                pad.path, pad.name,
                osk_state_at_bind(want_osk, osk_backend,
                                  visible=osk_visible, usable=osk_usable())):
            print(line, file=sys.stderr, flush=True)

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
            if action == "close-window":
                if args.verbose and ui is not None:
                    print(f"close-window -> {' '.join(CLOSE_WINDOW_ARGV)}",
                          file=sys.stderr, flush=True)
                run_close_window(dry_run=ui is None)
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
    # ⚠️ ORDER IS THE WHOLE POINT OF THESE TWO STATEMENTS, and it is why they
    # sit here rather than beside the "reading ..." line 15 lines up. The
    # keyboard is drawn BEFORE readiness is claimed, and readiness is claimed
    # AFTER the pad's fd is in the selector. Move the report above either one
    # and it starts meaning "the process got this far", which is precisely the
    # marker T4-screen-spec.md §2.3 refused to accept.
    if args.osk_start_shown:
        set_osk_visible(True)
    report_bound(args.osk_start_shown)
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
            # ⚠️ DISPATCHED LIKE THE OTHERS, by fd. The overlay's stdout carries
            # touches (§5.30c made the panel's touch usable at all); a finger on
            # the glass may be the only thing happening, with both thumbs off
            # the pads.
            if osk_layer_fd is not None and osk_layer_fd in ready_fds:
                osk_layer_pump()
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
                    # 🔴 HAND BACK A MOUSE BUTTON THE DEAD NODE WAS HOLDING. A
                    # pad that vanishes under a pressed thumb never sends the
                    # release, and `translate` can only give back a release it
                    # is handed. Left down, BTN_LEFT survives the rebind at the
                    # KERNEL, and the recovered session drags everything the
                    # pointer touches. Before anything else here, because the
                    # keyboard hide below can take a redraw with it.
                    for key, value in mapper.release_pointer_click():
                        emit(key, value)
                    # What was on the screen when the pad went away -- read
                    # BEFORE the hide below, because that hide is ours and not
                    # the user's. It decides two things: whether the keyboard
                    # comes back (a user who pressed `close` must not have one
                    # forced back on), and what the re-bind report is allowed
                    # to promise.
                    osk_was_visible = osk_visible
                    if osk_visible:
                        set_osk_visible(False)
                    try:
                        sel.unregister(pad.fd)
                    except (KeyError, ValueError, OSError):
                        pass
                    # ⚠️ The effect ids belonged to the node that just vanished.
                    # Dropped and re-uploaded against the replacement, or every
                    # pad click from here on writes to a dead slot -- which
                    # `Haptics.buzz` would survive, and would then leave the
                    # keyboard permanently silent after one re-enumeration.
                    if mapper.haptics is not None:
                        mapper.haptics.close()
                        mapper.haptics = None
                    pad = pick_device(args.device)
                    if args.grab:
                        pad.grab()
                    mapper.haptics = arm_haptics(pad)
                    sel.register(pad.fd, selectors.EVENT_READ)
                    # Kept verbatim: this is the line the journal has always
                    # carried for a recovery, and it is the ONLY thing that
                    # distinguishes the report below from the startup one.
                    print(f"deck-input-mapper: re-bound to {pad.path} ({pad.name})",
                          file=sys.stderr, flush=True)
                    # ⚠️ RE-RANGED BEFORE IT IS RE-DRAWN, and both before the
                    # report. The replacement pad may advertise different
                    # ranges, and the show below places both cursors from them
                    # -- with the old ones the keyboard comes back with its
                    # cursors somewhere the thumbs are not, until the next
                    # sample moves them.
                    if mapper.cursors is not None and osk_layout is not None:
                        mapper.cursors.ranges = {
                            code: (ai.min, ai.max)
                            for code, ai in dict(pad.capabilities().get(e.EV_ABS, [])).items()
                            if code in osk_layout.PAD_AXES
                        }
                    # Put back what the re-enumeration took away. Without this
                    # a pad that wobbles mid-passphrase leaves the user typing
                    # into a masked field with no keyboard drawn and no way to
                    # know why -- and on the installer's own screens the chord
                    # that would summon it back is not something a first-time
                    # user knows exists.
                    if osk_was_visible:
                        set_osk_visible(True)
                    report_bound(osk_was_visible)
                    continue
                for event in events:
                    if event.type == e.EV_SYN and event.code == e.SYN_REPORT:
                        flush_motion()
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
                # A device that never sends SYN_REPORT must still move -- and
                # must still not move on a lift, hence the same drain.
                flush_motion()
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
            if osk_backend == "layer" and osk_visible:
                hide_because = lock_watcher.tick(now)
                if hide_because is not None:
                    say(HIDE_REASONS.get(hide_because, hide_because))
                    set_osk_visible(False)
    except KeyboardInterrupt:
        pass
    finally:
        lock_watcher.stop()
        if mapper.haptics is not None:
            # Hand the 16 effect slots back. Not strictly required -- closing
            # the fd does it -- but this process is restarted by systemd and a
            # leak here would be invisible until the 9th restart.
            mapper.haptics.close()
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
