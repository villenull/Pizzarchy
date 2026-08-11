#!/usr/bin/env python3
"""Unit tests for the layer-shell renderer's pure half (T8 step 5).

No GTK, no compositor, no display -- `deck_osk_wayland` imports `gi` inside
main() precisely so this suite runs anywhere. What is covered is the geometry
and the state protocol; the drawing itself needs eyes, and `--demo` is for that.

    python3 test-deck-osk-wayland.py
"""

from __future__ import annotations

import importlib.util
import pathlib
import sys

from evdev import ecodes as e

# ⚠️ Before loading anything -- a cached .pyc is validated against the source's
# (mtime, size) at one-second granularity, so a same-size edit within the same
# second runs the OLD code. See test-deck-osk-layout.py for the full story.
sys.dont_write_bytecode = True

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SRC = REPO_ROOT / "src"


def load(name: str):
    spec = importlib.util.spec_from_file_location(name, SRC / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


sys.path.insert(0, str(SRC))
osk = load("deck_osk_layout")
wl = load("deck_osk_wayland")

FAILURES = 0


def check(what: str, got, want) -> None:
    global FAILURES
    if got == want:
        print(f"ok   {what} = {got!r}")
    else:
        print(f"FAIL {what}: got {got!r}, want {want!r}")
        FAILURES += 1


# The Deck's panel as Gaming Mode presents it, and a deliberately odd size --
# geometry that only works on round numbers is geometry that will break on the
# first different monitor.
SIZES = ((1280, 336, 48), (1280, 337, 48), (997, 211, 31), (640, 200, 0))

# --- halves ------------------------------------------------------------------

bounds = wl.half_bounds(1280, 48)
check("the left half starts at the left edge", bounds["left"][0], 0.0)
check("the right half starts after the gutter",
      bounds["right"][0], bounds["left"][1] + 48)
check("both halves are the same width", bounds["left"][1], bounds["right"][1])
check("halves plus gutter fill the width exactly",
      bounds["left"][1] + 48 + bounds["right"][1], 1280.0)
check("a zero gutter still splits evenly", wl.half_bounds(640, 0)["right"][0], 320.0)

# --- key rectangles ----------------------------------------------------------

rects = wl.key_rects(osk.LETTERS, 1280, 336, 48)
expected = sum(len(row) for half in ("left", "right") for row in osk.LETTERS.half(half))
check("one rectangle per key in the layer", len(rects), expected)

for width, height, gutter in SIZES:
    for layer in (osk.LETTERS, osk.SYMBOLS):
        rects = wl.key_rects(layer, width, height, gutter)
        b = wl.half_bounds(width, gutter)

        # Nothing may cross the gutter into the other thumb's half.
        strays = [r for r in rects
                  if r[3] < b[r[0]][0] - 1e-9
                  or r[3] + r[5] > b[r[0]][0] + b[r[0]][1] + 1e-9]
        check(f"no key escapes its half ({width}x{height}/{gutter}, {layer.name})",
              strays, [])

        # Rows must tile the full height, and each row's keys the full width --
        # a gap is a place a cursor can sit on a key that was never drawn.
        rows = layer.half("left")
        heights = sorted({round(r[6], 6) for r in rects})
        check(f"every key is one row tall ({width}x{height}/{gutter}, {layer.name})",
              len(heights), 1)
        check(f"rows tile the height ({width}x{height}/{gutter}, {layer.name})",
              round(heights[0] * len(rows), 6), round(float(height), 6))

# --- ⚠️ THE SEAM: every drawn rectangle hit-tests back to its own key --------
#
# The renderer and the hit test compute positions independently. If they
# disagree, the keyboard types a different character from the one under the
# cursor -- and both halves pass their own tests. Same property the TTY
# renderer is held to, checked here in pixels.

mismatches = []
for width, height, gutter in SIZES:
    for layer in (osk.LETTERS, osk.SYMBOLS):
        b = wl.half_bounds(width, gutter)
        for half, row_index, key_index, x, y, w, h in wl.key_rects(
                layer, width, height, gutter):
            x0, half_w = b[half]
            # Probe the centre AND every corner, pulled a pixel inside: the
            # centre alone passes even when a rectangle is the wrong size.
            probes = [(x + w / 2, y + h / 2),
                      (x + 1, y + 1), (x + w - 1, y + 1),
                      (x + 1, y + h - 1), (x + w - 1, y + h - 1)]
            for px, py in probes:
                nx = (px - x0) / half_w
                ny = py / height
                found = osk.locate(layer, half, min(max(nx, 0.0), 1.0),
                                   min(max(ny, 0.0), 1.0))
                if found != (row_index, key_index):
                    mismatches.append((layer.name, half, row_index, key_index,
                                       round(px, 2), round(py, 2), found))
check("every drawn rectangle hit-tests back to the key it was drawn for",
      mismatches, [])

# --- cursor placement --------------------------------------------------------

check("a cursor at 0,0 sits at its half's origin",
      wl.cursor_pixel("left", (0.0, 0.0), 1280, 336, 48), (0.0, 0.0))
check("a cursor at 1,1 sits at its half's far corner",
      wl.cursor_pixel("left", (1.0, 1.0), 1280, 336, 48), (616.0, 336.0))
check("the right cursor is offset past the gutter",
      wl.cursor_pixel("right", (0.0, 0.0), 1280, 336, 48)[0], 664.0)
check("the right cursor reaches the right edge",
      wl.cursor_pixel("right", (1.0, 0.5), 1280, 336, 48), (1280.0, 168.0))
check("the two halves' cursors never coincide at the same normalised point",
      wl.cursor_pixel("left", (0.5, 0.5), 1280, 336, 48)
      != wl.cursor_pixel("right", (0.5, 0.5), 1280, 336, 48), True)

# A cursor must land inside the key it highlights, or the dot and the highlight
# disagree and the user is told two different things at once.
kb = osk.OnScreenKeyboard()
cur = osk.Cursors()
MIN, MAX = osk.PAD_RANGE
outside = []
for xi in range(0, 11):
    for yi in range(0, 11):
        vx = (MIN + (MAX - MIN) * xi // 10) or 1
        vy = (MIN + (MAX - MIN) * yi // 10) or 1
        for half, ax, ay in (("left", e.ABS_HAT0X, e.ABS_HAT0Y),
                             ("right", e.ABS_HAT1X, e.ABS_HAT1Y)):
            cur.update(ax, vx)
            cur.update(ay, vy)
            px, py = wl.cursor_pixel(half, cur.position(half), 1280, 336, 48)
            located = kb.locate(half, *cur.position(half))
            rect = next(r for r in wl.key_rects(kb.layer, 1280, 336, 48)
                        if (r[0], r[1], r[2]) == (half, located[0], located[1]))
            _, _, _, x, y, w, h = rect
            if not (x - 1e-6 <= px <= x + w + 1e-6 and y - 1e-6 <= py <= y + h + 1e-6):
                outside.append((half, xi, yi, round(px, 2), round(py, 2), rect))
check("the cursor dot always falls inside the key it highlights", outside, [])

# --- the state protocol -------------------------------------------------------

kb = osk.OnScreenKeyboard()
cur = osk.Cursors()
line = osk.format_state_line(kb, cur)
check("a fresh state serialises to one line", line.count("\n"), 1)
check("and parses back",
      osk.parse_state_line(line),
      {"layer": "letters", "shift": "off", "left": (0.5, 0.5), "right": (0.5, 0.5)})

kb.press_at("left", 0.1, 0.9)     # shift -> once
kb.press_at("left", 0.5, 0.9)     # -> symbols
cur.update(e.ABS_HAT1X, MAX)
round_tripped = osk.parse_state_line(osk.format_state_line(kb, cur))
check("layer survives the round trip", round_tripped["layer"], "symbols")
check("shift state survives it", round_tripped["shift"], "once")
check("cursor positions survive it", round_tripped["right"], (1.0, 0.5))

target_kb = osk.OnScreenKeyboard()
target_cur = osk.Cursors()
osk.apply_state(target_kb, target_cur, round_tripped)
check("applying it reproduces the layer", target_kb.layer_name, "symbols")
check("...the shift state", target_kb.shift, "once")
check("...and both cursors",
      (target_cur.position("left"), target_cur.position("right")),
      (cur.position("left"), cur.position("right")))

# A malformed line may only be ignored. This runs across a pipe from another
# process; a parser that raised would take the keyboard down with it.
for bad in ("", "\n", "state", "quit", "state letters off 0 0 0",
            "state letters off 0 0 0 0 0", "notstate letters off 0 0 0 0",
            "state dvorak off 0 0 0 0", "state letters sideways 0 0 0 0",
            "state letters off x y 0 0", "state letters off 1.5 0 0 0",
            "state letters off -0.1 0 0 0", "state letters off 0 0 0 nan"):
    if osk.parse_state_line(bad) is not None:
        check(f"a malformed line is rejected: {bad!r}", osk.parse_state_line(bad), None)
check("every malformed line above was rejected",
      [b for b in ("", "state", "state letters off 0 0 0", "state dvorak off 0 0 0 0",
                   "state letters off 1.5 0 0 0")
       if osk.parse_state_line(b) is not None], [])

check("a valid line with extra whitespace still parses",
      osk.parse_state_line("  state   letters  off  0.25 0.75 0.5 0.5  \n") is not None, True)

print()
print(f"{'PASS' if FAILURES == 0 else 'FAIL'} — {FAILURES} failure(s)")
sys.exit(1 if FAILURES else 0)
