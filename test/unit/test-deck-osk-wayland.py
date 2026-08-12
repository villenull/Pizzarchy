#!/usr/bin/env python3
"""Unit tests for the layer-shell renderer (T8 step 5, §9g parity pass).

No GTK, no compositor, no display -- `deck_osk_wayland` imports `gi` inside
main() precisely so this suite runs anywhere. Two layers of coverage:

  * the pure geometry -- one continuous grid at the reference's own MEASURED
    KEY WIDTHS, and every drawn rectangle hit-testing back to the key it was
    drawn for IN THE METRIC IT WAS DRAWN IN. This renderer draws
    `Layer.unit_bounds` (visual widths, per row); `deck_osk_tty.py` draws
    `Layer.cell_bounds` (the integer addressing grid). Drawing one and
    hit-testing the other puts the cursor's dot up to half a key from the key
    it lights, so every check about the two agreeing is run under BOTH metrics
    and the wrong one has to FAIL;
  * the RASTER -- `draw()` onto an in-memory Cairo surface, read back pixel by
    pixel. "Completes without raising" cannot tell a drawn legend from a
    skipped one, a square corner from a rounded one, or a white cursor face
    from the cyan/amber tint this renderer used to paint. Every §9g claim that
    is about what a user SEES is checked against the actual pixels.

The numbers come from `docs/findings/T8-reference-metrics.md`, measured from
`grim` captures of the reference keyboard on this panel.

    python3 test-deck-osk-wayland.py
"""

from __future__ import annotations

import importlib.util
import math
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


# The Deck's panel as Gaming Mode presents it (1280 x 0.4475*800), plus
# deliberately odd sizes -- geometry that only works on round numbers is
# geometry that will break on the first different monitor.
SIZES = ((1280, 358), (1280, 357), (997, 211), (640, 200))
MIN, MAX = osk.PAD_RANGE
LAYERS = tuple(osk.LAYERS.values())

# --- the grid is CONTINUOUS: no gutter, no halves, no seam ------------------

for width, height in SIZES:
    for layer in LAYERS:
        rects = wl.key_rects(layer, width, height)
        check(f"one rectangle per key ({width}x{height}, {layer.name})",
              len(rects), sum(len(row) for row in layer.rows))

        top, grid_h = wl.grid_origin(height)
        heights = sorted({round(r[5], 6) for r in rects})
        check(f"every key is exactly one row tall ({width}x{height}, {layer.name})",
              len(heights), 1)
        check(f"the rows tile the grid height ({width}x{height}, {layer.name})",
              # `heights` is rounded to 6 places, so five of them can drift by
              # 5e-6. Any REAL tiling error is a whole pixel or more.
              abs(heights[0] * len(layer.rows) - grid_h) < 1e-3, True)
        check(f"the grid starts below the reserved stripe "
              f"({width}x{height}, {layer.name})",
              min(r[3] for r in rects), top)
        check(f"and ends at the bottom edge ({width}x{height}, {layer.name})",
              round(max(r[3] + r[5] for r in rects), 6), round(float(height), 6))

        # 🔴 THE OPERATOR'S HEADLINE COMPLAINT, pinned in geometry: every row
        # must start at x=0, end at x=width, and every key must butt directly
        # against its neighbour. A gutter of ANY width -- the old 48px, the
        # ~62px that was measured on screen, or one stray pixel -- breaks one
        # of these three.
        for row_index in range(len(layer.rows)):
            row = [r for r in rects if r[0] == row_index]
            check(f"row {row_index} starts at the left edge "
                  f"({width}x{height}, {layer.name})", row[0][2], 0.0)
            check(f"row {row_index} ends at the right edge "
                  f"({width}x{height}, {layer.name})",
                  round(row[-1][2] + row[-1][4], 6), round(float(width), 6))
            seams = [round(nxt[2] - (cur[2] + cur[4]), 9)
                     for cur, nxt in zip(row, row[1:])]
            check(f"row {row_index} has NO gap between any two keys "
                  f"({width}x{height}, {layer.name})", set(seams), {0.0})

# --- 🔴 PROPORTIONAL WIDTHS, against the reference's own pixel table ---------
#
# The single largest remaining visual difference before this: the renderer drew
# the 16-cell ADDRESSING grid, which puts `Tab` and `Caps` at THREE TIMES a
# letter where the reference draws them at 1.03 and 1.36 units. It now draws
# `Layer.unit_bounds`, per row.
#
# The numbers below are `docs/findings/T8-reference-metrics.md` §2's measured
# FILL WIDTHS in pixels, written out longhand rather than read back out of
# `Key.units` -- a wrong `units` must fail here, not agree with itself.
#
# ⚠️ NOT §2's "x unit" RATIO COLUMN. That column divides one key's fill by
# another key's fill and so drops the inter-key gap; laying a row out with
# 1.75/1.40/2.09/8.53 overshoots every wide key by 2-4px.
REF_FILL_PX = {
    0: [("`", 42)] + [(d, 85) for d in "1234567890"]
       + [("-", 85), ("=", 85), ("Backspace", 149)],
    1: [("Tab", 89)] + [(c, 86) for c in "qwertyuiop"]
       + [("[", 86), ("]", 86), ("\\", 86)],
    2: [("Caps", 119)] + [(c, 86) for c in "asdfghjkl"]
       + [(";", 86), ("'", 86), ("Enter", 149)],
    3: [("Shift", 178)] + [(c, 86) for c in "zxcvbnm"]
       + [(",", 86), (".", 86), ("/", 86), ("Shift", 178)],
    4: [("☺", 104), ("space", 725), ("◀", 104), ("▶", 104),
        ("Paste", 104), ("Move", 104)],
}

# TWO DOCUMENTED DIFFERENCES between our panel and the one §2 was measured on,
# and they are the only two -- so a drawn fill can be carried back into the
# reference's own frame and compared there, which is a real comparison and not
# a restatement of `units`:
#
#   * the reference's key fill spans x=5..1273 of a 1280 screen (1269px, i.e.
#     1273.5 including one gap); ours spans the full width, because the tests
#     above pin every row to x=0..width and a side inset would read as exactly
#     the edge gap this renderer had to have removed;
#   * the reference's inter-key gap is a flat ~4.5px in a 66px row; ours is
#     KEY_GAP_RATIO of OUR row height, and our rows are 71px because the 358px
#     panel is tiled over five rows after the 3px stripe band is reserved.
REF_PANEL_PITCH = 1273.5   # metrics §2: 1269px of fill plus one 4.5px gap
REF_GAP = 4.5


def in_reference_frame(fill_px: float, width: float, gap: float) -> float:
    """A fill width we drew, expressed as the reference would have measured it."""
    return (fill_px + gap) * (REF_PANEL_PITCH / width) - REF_GAP


_W, _H = 1280.0, 358.0
_top, _grid_h = wl.grid_origin(_H)
_row_h = _grid_h / len(osk.LETTERS.rows)
_gap = _row_h * wl.KEY_GAP_RATIO
_fills = {}
for _r, _k, _x, _y, _w, _h in wl.key_rects(osk.LETTERS, _W, _H):
    _fills.setdefault(_r, []).append((osk.LETTERS.rows[_r][_k].label, _w - _gap))

for _r in range(len(osk.LETTERS.rows)):
    check(f"row {_r} draws the keys metrics §2 measured, in order",
          [n for n, _ in _fills[_r]], [n for n, _ in REF_FILL_PX[_r]])
    check(f"row {_r}'s DRAWN fill widths match metrics §2 to within 1.5px "
          f"(the same tolerance the units themselves are held to)",
          [(n, round(in_reference_frame(got, _W, _gap), 1), want)
           for (n, got), (_n, want) in zip(_fills[_r], REF_FILL_PX[_r])
           if abs(in_reference_frame(got, _W, _gap) - want) > 1.5], [])

# The headline defect, named. `Tab` at three letters wide is what a 16-cell
# grid draws and what the operator saw; the reference draws it at barely more
# than one, and `Caps` at about one and a third.
_row1 = dict(_fills[1])
_row2 = dict(_fills[2])
check("Tab is about ONE letter wide, not the three cells it spans",
      round(_row1["Tab"] / _row1["q"], 2), round(89 / 86, 2))
check("Caps is about a third wider than a letter, not three times",
      abs(_row2["Caps"] / _row2["a"] - 119 / 86) < 0.03, True)
check("...and the backtick is HALF a letter, though it is a whole cell",
      abs(dict(_fills[0])["`"] / dict(_fills[0])["1"] - 42 / 85) < 0.03, True)

# 🔴 EACH ROW IS NORMALISED ON ITS OWN. Scaling the whole layer by one factor
# would leave a ragged right edge; the reference instead fixes its special keys
# and lets the unit keys absorb the remainder, so a unit key is 85px in row 1
# and 86-87px in rows 2-4. If these were equal, the per-row scale is gone.
check("a unit key is NOT the same width on every row -- the rows are scaled "
      "independently, exactly as the reference's are",
      round(dict(_fills[0])["1"], 3) == round(_row1["q"], 3), False)
check("...and the row with more units draws the narrower unit key",
      (osk.LETTERS.row_units(0) > osk.LETTERS.row_units(1),
       dict(_fills[0])["1"] < _row1["q"]), (True, True))
check("row_scale is the row's own pitch, in pixels per unit",
      [round(wl.row_scale(osk.LETTERS, r, _W)
             * osk.LETTERS.row_units(r) - _W, 9) for r in range(5)],
      [0.0] * 5)

# The split is a cursor boundary and must be invisible to the placement code:
# the key spanning it (the space bar) is ONE rectangle, not two.
def split_pixel(layer, row_index, width):
    """Where the two halves meet on this row, in pixels. PER ROW -- see
    `half_pixel_range`; the cell split interpolates onto each row's own key
    boundaries and lands at a different x on every one of the five."""
    return wl.half_pixel_range(layer, "left", width, row_index)[1]


straddlers = [r for r in wl.key_rects(osk.LETTERS, 1280, 358)
              if r[2] < split_pixel(osk.LETTERS, r[0], 1280.0) < r[2] + r[4]]
check("a key straddles the split as a single rectangle, so no seam can be "
      "drawn there", len(straddlers), 1)
check("...and it is the space bar",
      osk.LETTERS.rows[straddlers[0][0]][straddlers[0][1]].label, "space")

for _r in range(len(osk.LETTERS.rows)):
    check(f"row {_r}: half_pixel_range covers the whole width between the two "
          f"halves",
          (wl.half_pixel_range(osk.LETTERS, "left", 1280.0, _r)[0],
           round(wl.half_pixel_range(osk.LETTERS, "right", 1280.0, _r)[1], 6)),
          (0.0, 1280.0))
    check(f"row {_r}: ...and they meet exactly, with nothing between them",
          wl.half_pixel_range(osk.LETTERS, "left", 1280.0, _r)[1],
          wl.half_pixel_range(osk.LETTERS, "right", 1280.0, _r)[0])
# ⚠️ The boundary is NOT at the same pixel on every row, and it is not at the
# cell split's 640 on most of them. A renderer that kept one layer-wide
# boundary would place four of the five cursors' ranges wrongly.
check("the halves meet at a DIFFERENT pixel on each row",
      len({round(split_pixel(osk.LETTERS, r, 1280.0), 3) for r in range(5)}), 5)
check("...and on row 4 the boundary falls INSIDE the space bar, which is how "
      "both thumbs reach it",
      (straddlers[0][2] < split_pixel(osk.LETTERS, 4, 1280.0)
       < straddlers[0][2] + straddlers[0][4], straddlers[0][0]), (True, 4))
try:
    wl.half_pixel_range(osk.LETTERS, "middle", 1280.0, 0)
    check("an unknown half raises rather than guessing", "no raise", "ValueError")
except ValueError:
    check("an unknown half raises rather than guessing", "ValueError", "ValueError")

# --- ⚠️ THE SEAM: every drawn rectangle hit-tests back to its own key --------
#
# The renderer and the hit test compute positions independently. If they
# disagree the keyboard types a different character from the one under the
# cursor -- and both halves pass their own tests.
#
# 🔴 AND THE METRIC IS THE WHOLE POINT. This file draws `osk.UNITS`; the
# layout core's default is `osk.CELLS`, which is right for the TTY renderer and
# wrong here by up to half a key. So the same probe set is run under BOTH, and
# the cell metric must FAIL -- a suite where either answer passed would let the
# cursor-offset bug straight through.


def seam_mismatches(metric):
    out = []
    for width, height in SIZES:
        for layer in LAYERS:
            top, grid_h = wl.grid_origin(height)
            for half in wl.HALVES:
                for row_index, key_index, x, y, w, h in wl.key_rects(
                        layer, width, height):
                    hx0, hx1 = wl.half_pixel_range(layer, half, width, row_index)
                    # Only the part of the key this thumb can actually reach.
                    lo, hi = max(x, hx0), min(x + w, hx1)
                    if hi - lo < 2:
                        continue
                    probes = [((lo + hi) / 2, y + h / 2),
                              (lo + 0.5, y + 0.5), (hi - 0.5, y + 0.5),
                              (lo + 0.5, y + h - 0.5), (hi - 0.5, y + h - 0.5)]
                    for px, py in probes:
                        nx = (px - hx0) / (hx1 - hx0)
                        ny = (py - top) / grid_h
                        found = osk.locate(layer, half, min(max(nx, 0.0), 1.0),
                                           min(max(ny, 0.0), 1.0), metric)
                        if found != (row_index, key_index):
                            out.append((layer.name, half, row_index, key_index,
                                        round(px, 2), round(py, 2), found))
    return out


check("every drawn rectangle hit-tests back to the key it was drawn for, in "
      "the metric this renderer DRAWS", seam_mismatches(osk.UNITS), [])
check("...and the cell metric, which the TTY renderer draws, does NOT agree -- "
      "so the check above is about the metric and not a tautology",
      len(seam_mismatches(osk.CELLS)) > 100, True)

# --- cursor placement --------------------------------------------------------

check("a left cursor at 0,0 sits at the grid's top-left",
      wl.cursor_pixel(osk.LETTERS, "left", (0.0, 0.0), 1280, 358),
      (0.0, wl.stripe_height(358)))
check("a left cursor at 1,1 sits on ROW 4's split, at the bottom",
      wl.cursor_pixel(osk.LETTERS, "left", (1.0, 1.0), 1280, 358),
      (split_pixel(osk.LETTERS, 4, 1280.0), 358.0))
check("...which is a point inside the space bar, and NOT the 640 the cell "
      "grid would have put it at",
      round(split_pixel(osk.LETTERS, 4, 1280.0), 2), 751.82)
check("the right cursor starts ON the split, with no gutter to skip",
      wl.cursor_pixel(osk.LETTERS, "right", (0.0, 0.0), 1280, 358)[0],
      split_pixel(osk.LETTERS, 0, 1280.0))
check("the right cursor reaches the right edge",
      tuple(round(v, 6) for v in
            wl.cursor_pixel(osk.LETTERS, "right", (1.0, 1.0), 1280, 358)),
      (1280.0, 358.0))

# 🔴 THE ROW IS DERIVED FIRST. Each row has its own pitch and its own half
# boundary, so the same x in two rows is two different pixels. A `cursor_pixel`
# that resolved x before y -- or against one layer-wide boundary -- would
# return the same number five times.
check("the same x in every row lands at five different pixels",
      len({round(wl.cursor_pixel(osk.LETTERS, "left", (0.5, (r + 0.5) / 5),
                                 1280, 358)[0], 4) for r in range(5)}), 5)
check("cursor_row picks the same row `locate` does, at every boundary",
      [wl.cursor_row(osk.LETTERS, y)
       for y in (0.0, 0.19, 0.2, 0.5, 0.79, 0.8, 0.99, 1.0)],
      [osk.locate(osk.LETTERS, "left", 0.5, y)[0]
       for y in (0.0, 0.19, 0.2, 0.5, 0.79, 0.8, 0.99, 1.0)])

# A cursor must land inside the key it highlights, or the dot and the white
# face disagree and the user is told two different things at once.
kb = osk.OnScreenKeyboard()
cur = osk.Cursors()
outside = []
for xi in range(0, 11):
    for yi in range(0, 11):
        vx = (MIN + (MAX - MIN) * xi // 10) or 1
        vy = (MIN + (MAX - MIN) * yi // 10) or 1
        for half, ax, ay in (("left", e.ABS_HAT0X, e.ABS_HAT0Y),
                             ("right", e.ABS_HAT1X, e.ABS_HAT1Y)):
            cur.update(ax, vx)
            cur.update(ay, vy)
            px, py = wl.cursor_pixel(kb.layer, half, cur.position(half), 1280, 358)
            located = kb.locate(half, *cur.position(half), osk.UNITS)
            rect = next(r for r in wl.key_rects(kb.layer, 1280, 358)
                        if (r[0], r[1]) == located)
            _, _, x, y, w, h = rect
            if not (x - 1e-6 <= px <= x + w + 1e-6
                    and y - 1e-6 <= py <= y + h + 1e-6):
                outside.append((half, xi, yi, round(px, 2), round(py, 2), rect))
check("the cursor dot always falls inside the key it highlights", outside, [])

# The same sweep against the metric this renderer does NOT draw. Every one of
# these is a frame where the white face and the dot would be on different keys,
# which is the defect the `metric=` parameter exists to prevent -- so the pass
# above has to be about the metric, and here is the proof that it is.
cells_outside = 0
for xi in range(0, 11):
    for yi in range(0, 11):
        vx = (MIN + (MAX - MIN) * xi // 10) or 1
        vy = (MIN + (MAX - MIN) * yi // 10) or 1
        for half, ax, ay in (("left", e.ABS_HAT0X, e.ABS_HAT0Y),
                             ("right", e.ABS_HAT1X, e.ABS_HAT1Y)):
            cur.update(ax, vx)
            cur.update(ay, vy)
            px, py = wl.cursor_pixel(kb.layer, half, cur.position(half), 1280, 358)
            located = kb.locate(half, *cur.position(half))   # CELLS, the default
            x, y, w, h = next((r[2], r[3], r[4], r[5])
                              for r in wl.key_rects(kb.layer, 1280, 358)
                              if (r[0], r[1]) == located)
            if not (x - 1e-6 <= px <= x + w + 1e-6):
                cells_outside += 1
check("hit-testing in CELLS while drawing in units puts the dot outside the "
      "highlighted key in dozens of poses -- the bug this suite must be able "
      "to see", cells_outside > 20, True)

# --- the state protocol -------------------------------------------------------

kb = osk.OnScreenKeyboard()
cur = osk.Cursors()
line = osk.format_state_line(kb, cur)
check("a fresh state serialises to one line", line.count("\n"), 1)
parsed = osk.parse_state_line(line)
check("and parses back",
      (parsed["layer"], parsed["shift"], parsed["left"], parsed["right"]),
      ("letters", "off", (0.5, 0.5), (0.5, 0.5)))
check("a line with no touch fields means NOTHING touched -- the "
      "every-badge-visible frame", parsed["touched"],
      {"left": False, "right": False})

kb.press_at("left", 0.05, 0.75)     # shift -> once
cur.update(e.ABS_HAT1X, MAX)
round_tripped = osk.parse_state_line(
    osk.format_state_line(kb, cur, {"left": True, "right": False}))
check("shift state survives the round trip", round_tripped["shift"], "once")
check("cursor positions survive it", round_tripped["right"], (1.0, 0.5))
check("pad touch survives it", round_tripped["touched"],
      {"left": True, "right": False})

target_kb = osk.OnScreenKeyboard()
target_cur = osk.Cursors()
osk.apply_state(target_kb, target_cur, round_tripped)
check("applying it reproduces the shift state", target_kb.shift, "once")
check("...and both cursors",
      (target_cur.position("left"), target_cur.position("right")),
      (cur.position("left"), cur.position("right")))
check("...and the renderer reads the touch state back out as a set of halves",
      wl.touched_halves(target_kb), frozenset({"left"}))

blank = osk.OnScreenKeyboard()
check("a core with no touch state at all still yields an empty set, rather "
      "than taking the only keyboard on the device down",
      wl.touched_halves(blank), frozenset())

check("the stripe is OFF while nothing is happening",
      wl.in_use(osk.OnScreenKeyboard(), frozenset()), False)
shifted_kb = osk.OnScreenKeyboard()
shifted_kb.shift = "once"
check("...ON under shift", wl.in_use(shifted_kb, frozenset()), True)
capped_kb = osk.OnScreenKeyboard()
capped_kb.caps = True
check("...ON under caps", wl.in_use(capped_kb, frozenset()), True)
check("...ON while a pad is touched",
      wl.in_use(osk.OnScreenKeyboard(), frozenset({"right"})), True)

# A malformed line may only be ignored. This runs across a pipe from another
# process; a parser that raised would take the keyboard down with it.
bad_lines = ("", "\n", "state", "quit", "state letters off 0 0 0",
             "notstate letters off 0 0 0 0", "state dvorak off 0 0 0 0",
             "state letters sideways 0 0 0 0", "state letters off x y 0 0",
             "state letters off 1.5 0 0 0", "state letters off -0.1 0 0 0",
             "state letters off 0 0 0 nan")
check("every malformed line is rejected rather than raising",
      [b for b in bad_lines if osk.parse_state_line(b) is not None], [])
check("a valid line with extra whitespace still parses",
      osk.parse_state_line("  state   letters  off  0.25 0.75 0.5 0.5  \n")
      is not None, True)

# --- 🔴 TOUCH: the input region, and the key under a finger ------------------
#
# Operator, on hardware, 2026-08-12: *"touch on the keyboard still does not work
# (works in desktop)"*. It did not work because this surface declared an EMPTY
# input region -- deliberately, and it is what guaranteed the overlay could
# never swallow a click meant for the window underneath. That guarantee is the
# thing being traded, so everything below pins how far the trade goes:
#
#   * the region is NON-EMPTY (or touch is dead again, silently -- nothing on
#     screen changes and no error is produced anywhere);
#   * it is BOUNDED to the key grid, never the whole surface, so the reserved
#     stripe band still passes events through;
#   * and a touch inside it resolves to the key that was DRAWN there, in the
#     metric it was drawn in.

for width, height in SIZES:
    x, y, w, h = wl.input_region_rect(width, height)
    check(f"the input region is not empty ({width}x{height})", w > 0 and h > 0, True)
    check(f"...and it is integers, which is all a Wayland region can be "
          f"({width}x{height})",
          all(isinstance(v, int) for v in (x, y, w, h)), True)
    top, _grid = wl.grid_origin(height)
    check(f"...it starts BELOW the reserved stripe, never inside it "
          f"({width}x{height})", y >= top, True)
    check(f"...it is bounded by the surface ({width}x{height})",
          (x, x + w <= width, y + h <= height), (0, True, True))
    check(f"...and it reaches the bottom edge, where the last row is "
          f"({width}x{height})", y + h, int(height))
    # Everything inside the region must BE a key, or the surface would swallow
    # events over dead paint.
    corners = ((x, y), (x + w - 1, y), (x, y + h - 1), (x + w - 1, y + h - 1))
    for layer in LAYERS:
        check(f"every corner of the region is on a key ({width}x{height}, "
              f"{layer.name})",
              [wl.key_at_pixel(layer, width, height, px, py) is None
               for px, py in corners], [False] * 4)

# The stripe band is what the bound BUYS: it is outside the region, so a touch
# up there still reaches whatever is underneath.
check("a pixel in the stripe band is on no key",
      wl.key_at_pixel(osk.LETTERS, 1280, 358, 640, 0), None)
check("...and off the surface entirely is on no key either",
      [wl.key_at_pixel(osk.LETTERS, 1280, 358, px, py)
       for px, py in ((-1, 100), (1280, 100), (640, 358), (640, -5))],
      [None] * 4)

# 🔴 THE ROUND TRIP, IN THE METRIC THIS FILE DRAWS IN. Every painted rectangle
# must hit-test back to the key it was painted for -- the same contract the
# geometry above holds for the cursor, now for a finger.
for width, height in SIZES:
    for layer in LAYERS:
        misses = []
        for row, col, rx, ry, rw, rh in wl.key_rects(layer, width, height):
            got = wl.key_at_pixel(layer, width, height,
                                  rx + rw / 2.0, ry + rh / 2.0)
            if got != (row, col):
                misses.append(((row, col), got))
        check(f"every drawn key's centre hit-tests back to itself "
              f"({width}x{height}, {layer.name})", misses, [])
        # The rectangles TILE: a finger in the 4-5px trough between two keys
        # commits the nearer one instead of falling through an opaque panel.
        top, grid_h = wl.grid_origin(height)
        holes = [(px, py)
                 for py in (top + 0.5, height - 0.5)
                 for px in range(0, int(width))
                 if wl.key_at_pixel(layer, width, height, px + 0.5, py) is None]
        check(f"no dead pixel anywhere along a row ({width}x{height}, "
              f"{layer.name})", holes, [])

# A rectangle owns its top-left corner and NOT its bottom-right one, or two
# adjacent keys would both claim the boundary and the answer would depend on
# iteration order.
rects = {(r, k): (x, y, w, h) for r, k, x, y, w, h in
         wl.key_rects(osk.LETTERS, 1280, 358)}
rx, ry, rw, rh = rects[(1, 2)]
check("a key owns its own top-left pixel",
      wl.key_at_pixel(osk.LETTERS, 1280, 358, rx, ry), (1, 2))
check("...and its right edge belongs to its NEIGHBOUR, not to it",
      wl.key_at_pixel(osk.LETTERS, 1280, 358, rx + rw, ry), (1, 3))

# 🔴 AND IT AGREES WITH THE HIGHLIGHT. `draw()` lights the key under a cursor
# using `locate(..., UNITS)`; a touch must land on the same key, or the keyboard
# would type one key while showing another as selected -- §9a's confidently
# wrong. Checked against the WRONG metric too, which has to disagree somewhere,
# or this check is passing for free.
SAMPLES = [(half, x, y) for half in ("left", "right")
           # ⚠️ 0.999 and not 1.0. A cursor at EXACTLY the end of its half sits
           # on a boundary the rectangles do not include (each owns its left
           # edge, not its right), so at 1.0 the pixel under the dot belongs to
           # the next key -- or, on the right half, is one past the surface.
           # That is the same clamp `locate` makes and not a disagreement about
           # any key a finger can land on.
           for x in (0.0, 0.13, 0.37, 0.5, 0.62, 0.88, 0.999)
           for y in (0.05, 0.3, 0.5, 0.7, 0.95)]
by_touch, by_units, by_cells = [], [], []
for half, x, y in SAMPLES:
    px, py = wl.cursor_pixel(osk.LETTERS, half, (x, y), 1280.0, 358.0)
    by_touch.append(wl.key_at_pixel(osk.LETTERS, 1280.0, 358.0, px, py))
    by_units.append(osk.locate(osk.LETTERS, half, x, y, osk.UNITS))
    by_cells.append(osk.locate(osk.LETTERS, half, x, y, osk.CELLS))
check("a touch at the cursor's own pixel commits the key the cursor highlights",
      by_touch, by_units)
check("...and the OTHER metric really would have disagreed (so that proves "
      "something)", by_touch == by_cells, False)

# --- the line a touch goes home on -------------------------------------------
#
# ⚠️ ONE definition of this protocol, in the file that WRITES it; the mapper
# imports this module to read it. Both directions are asserted here for the same
# reason `parse_state_line` is: it crosses a process boundary, and a line the
# other end cannot read is a key the user pressed and did not get.

check("a press line names its key by index",
      wl.format_press_line(3, 7), "press 3 7\n")
check("...and parses back to exactly that",
      wl.parse_press_line(wl.format_press_line(3, 7)), (3, 7))
check("...for every key in the layout, round trip",
      [wl.parse_press_line(wl.format_press_line(r, k)) != (r, k)
       for r, row in enumerate(osk.LETTERS.rows) for k in range(len(row))],
      [False] * sum(len(row) for row in osk.LETTERS.rows))
check("...and it is one line, terminated -- a reader splits on that",
      wl.format_press_line(0, 0).endswith("\n"), True)
check("every malformed press line is rejected rather than raising",
      [line for line in ("", "\n", "press", "press 1", "press 1 2 3",
                         "state letters off 0 0 0 0", "press x y",
                         "press -1 0", "press 0 -1", "quit", "press 1.5 2")
       if wl.parse_press_line(line) is not None], [])
check("a press line with extra whitespace still parses",
      wl.parse_press_line("  press   4   1  \n"), (4, 1))

check("split_lines keeps an unterminated remainder for the next read",
      wl.split_lines(b"press 1 2\npress 3"), (["press 1 2"], b"press 3"))
check("...hands back several at once",
      wl.split_lines(b"press 1 2\npress 3 4\n"),
      (["press 1 2", "press 3 4"], b""))
check("...and nothing at all when nothing is complete",
      wl.split_lines(b"pre"), ([], b"pre"))
check("...and a corrupt byte costs one line, not the reader",
      wl.split_lines(b"pre\xffss 1 2\n")[0][0].startswith("pre"), True)

# --- the GTK wiring, which no unit test can enter ----------------------------
#
# 🔴 EVERY CLAIM ABOVE IS WORTHLESS IF main() DOES NOT APPLY IT. The region is a
# pure function; the surface is a live Wayland object. Both of the failures this
# guards against are SILENT -- an empty region gives a keyboard that ignores
# every finger, and a missing `KeyboardMode.NONE` gives one that steals focus
# from the field being typed into and looks perfect on screen.

import ast  # noqa: E402 -- local to this block

wl_tree = ast.parse((SRC / "deck_osk_wayland.py").read_text())
regions = [node for node in ast.walk(wl_tree)
           if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
           and node.func.attr == "set_input_region"]
check("the surface's input region is set exactly once", len(regions), 1)
check("...from a REGION WITH A RECTANGLE IN IT, never `cairo.Region()`",
      [ast.unparse(node.args[0]) for node in regions],
      ["cairo.Region(cairo.RectangleInt(rx, ry, rw, rh))"])
region_sources = {node.func.id for node in ast.walk(wl_tree)
                  if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)}
check("...whose rectangle comes from input_region_rect, not from the surface",
      "input_region_rect" in region_sources, True)
# ⚠️ NOT ON_DEMAND, NOT EXCLUSIVE. This is the half of the design that did NOT
# change, and the one that keeps the text field focused while we draw over it.
modes = [ast.unparse(node) for node in ast.walk(wl_tree)
         if isinstance(node, ast.Attribute)
         and ast.unparse(node).startswith("LayerShell.KeyboardMode.")]
check("keyboard focus is still refused outright", modes,
      ["LayerShell.KeyboardMode.NONE"])
# The gesture, and the fact that what it produces is a LINE rather than a key
# event: this process has no uinput device and must never grow one.
main_fn = next(node for node in ast.walk(wl_tree)
               if isinstance(node, ast.FunctionDef) and node.name == "main")
main_calls = {ast.unparse(node.func) for node in ast.walk(main_fn)
              if isinstance(node, ast.Call)}
check("a click/touch controller is attached to the drawing area",
      ("Gtk.GestureClick" in main_calls, "area.add_controller" in main_calls),
      (True, True))
check("...and what it produces is a press LINE, not a keystroke",
      "format_press_line" in main_calls, True)
check("...written to stdout, which carries nothing else",
      "sys.stdout.write" in main_calls, True)
# A region applied once at present() describes the size we ASKED for; a
# compositor that gives a different one leaves the keyboard partly untouchable.
check("the region is re-applied when the surface is resized",
      sum(1 for node in ast.walk(main_fn) if isinstance(node, ast.Call)
          and ast.unparse(node.func) == "apply_input_region"), 2)

# --- the raster ---------------------------------------------------------------

try:
    import cairo as _cairo
except ImportError:
    print("skip -- pycairo not importable here; draw() was not exercised")
else:
    W, H = 1280.0, 358.0
    TOP, GRID_H = wl.grid_origin(H)
    ROW_H = GRID_H / len(osk.LETTERS.rows)
    PAD = ROW_H * wl.KEY_GAP_RATIO / 2.0
    RECTS = {(r, k): (x, y, w, h) for r, k, x, y, w, h in
             wl.key_rects(osk.LETTERS, W, H)}

    def render(keyboard=None, cursors=None, width=W, height=H):
        keyboard = keyboard if keyboard is not None else osk.OnScreenKeyboard()
        cursors = cursors if cursors is not None else osk.Cursors()
        surface = _cairo.ImageSurface(_cairo.FORMAT_ARGB32,
                                      int(width), int(height))
        wl.draw(_cairo.Context(surface), keyboard, cursors, float(width),
                float(height))
        surface.flush()
        return surface

    def pixel(surf, px, py):
        """(r, g, b) at one pixel. ARGB32 is little-endian BGRA in memory."""
        stride = surf.get_stride()
        buf = surf.get_data()
        off = int(py) * stride + int(px) * 4
        return (buf[off + 2], buf[off + 1], buf[off])

    def rgb(colour):
        """A `wl` 0..1 colour tuple as 0..255 ints, for exact comparison."""
        return tuple(round(c * 255) for c in colour[:3])

    def near(a, b, tol=6):
        return all(abs(p - q) <= tol for p, q in zip(a, b))

    def region_is(surf, x0, y0, w, h, colour, tol=6):
        """Is EVERY pixel in the box this colour? -- a flat fill."""
        want = rgb(colour)
        return all(near(pixel(surf, px, py), want, tol)
                   for py in range(int(y0), int(y0 + h))
                   for px in range(int(x0), int(x0 + w)))

    def region_has(surf, x0, y0, w, h, colour, tol=6):
        """Is ANY pixel in the box this colour?"""
        want = rgb(colour)
        return any(near(pixel(surf, px, py), want, tol)
                   for py in range(int(y0), int(y0 + h))
                   for px in range(int(x0), int(x0 + w)))

    def ink_rows(surf, x0, y0, w, h, background, tol=24):
        """Which y offsets inside the box carry paint that is not `background`?

        This is how the reference itself was measured
        (`docs/findings/T8-reference-metrics.md` §3): find the glyph's rows,
        not "did anything get drawn".
        """
        bg = rgb(background)
        found = []
        for py in range(int(y0), int(y0 + h)):
            for px in range(int(x0), int(x0 + w)):
                if not near(pixel(surf, px, py), bg, tol):
                    found.append(py)
                    break
        return found

    def touching(*halves):
        """A keyboard with a thumb on the named pads -- both, by default.

        🔴 EVERY CURSOR ASSERTION BELOW NEEDS ONE. A cursor is only drawn for a
        pad that is being TOUCHED (the operator's 2026-08-12 report: the dots
        used to stay behind, highlighting letters nobody was pointing at), and
        a fresh `OnScreenKeyboard` reports both pads lifted -- which is correct,
        and is §9f's idle frame.
        """
        halves = halves or wl.HALVES
        keyboard = osk.OnScreenKeyboard()
        keyboard.touched = {half: half in halves for half in wl.HALVES}
        return keyboard

    def face_box(row, col):
        """The key's own painted rectangle, inside the inter-key gap."""
        x, y, w, h = RECTS[(row, col)]
        return (x + PAD, y + PAD, w - 2 * PAD, h - 2 * PAD)

    # Coordinates of the keys these tests talk about, asserted rather than
    # assumed: a layout change must fail loudly here, not silently retarget
    # every probe below onto some other key.
    def key(row, col):
        return osk.LETTERS.rows[row][col]

    check("row 0 col 1 is the digit 1", key(0, 1).label, "1")
    check("row 0 col 13 is Backspace", key(0, 13).label, "Backspace")
    check("row 1 col 1 is the letter q", key(1, 1).label, "q")
    check("row 2 col 0 is Caps", key(2, 0).label, "Caps")
    check("row 2 col 12 is Enter", key(2, 12).label, "Enter")
    check("row 3 col 0 is the left Shift", key(3, 0).label, "Shift")
    check("row 3 col 11 is the right Shift", key(3, 11).label, "Shift")
    check("row 4 col 1 is space", key(4, 1).label, "space")

    idle = render()

    # --- the measured constants, pinned to their source ----------------------
    #
    # Every one of these is a number read off a `grim` capture in
    # `docs/findings/T8-reference-metrics.md`, not a taste decision. Pinning
    # them means a later restyle that drifts away from the reference has to say
    # so out loud, instead of the probes below silently following it.
    check("the letter fill is the measured #0E141B", rgb(wl.KEY_FACE),
          (0x0E, 0x14, 0x1B))
    check("the action fill is pure black", rgb(wl.KEY_FACE_ACTION), (0, 0, 0))
    check("the panel/gap colour is the measured #23262E", rgb(wl.PANEL_FILL),
          (0x23, 0x26, 0x2E))
    check("the panel is OPAQUE -- measured, and ours used to be 0.94",
          wl.PANEL_FILL[3], 1.0)
    check("the active-modifier blue is the measured #1A9FFF",
          rgb(wl.MODIFIER_ACTIVE), (0x1A, 0x9F, 0xFF))
    check("the cursor dot is #8CCFFF, a LIGHTER blue than the modifier",
          rgb(wl.CURSOR_DOT_FILL), (0x8C, 0xCF, 0xFF))
    check("...and its ring is the measured #7F7F7F",
          rgb(wl.CURSOR_DOT_RING), (0x7F, 0x7F, 0x7F))
    check("the badge fill is white", rgb(wl.BADGE_FILL), (255, 255, 255))
    check("the in-use stripe is #79A0F7", rgb(wl.STRIPE_FILL),
          (0x79, 0xA0, 0xF7))
    check("the badge sits ~23.5px from the key's left edge in a 66px row",
          round(wl.BADGE_CENTRE_X_RATIO * 66, 1), 23.5)
    check("...and in the row's LOWER half, not dead centre",
          wl.BADGE_CENTRE_Y_RATIO > 0.55, True)
    check("a face-button badge is 26px across in a 66px row",
          round(wl.BADGE_SIZE_RATIO * 66), 26)
    check("the cursor dot is ~24.5px across in a 66px row",
          round(wl.CURSOR_DOT_RATIO * 66, 1), 24.5)
    check("...ringed 3px thick", round(wl.CURSOR_RING_RATIO * 66), 3)
    check("the inter-key gap is ~4.5px in a 66px row",
          round(wl.KEY_GAP_RATIO * 66, 1), 4.5)
    check("the keyboard is 0.4475 of the screen, not the 0.42 ours used",
          round(wl.HEIGHT_FRACTION, 4), 0.4475)
    check("the shifted legend is ~85% of the base glyph's point size",
          wl.SECONDARY_SIZE_RATIO, 0.85)
    check("the small legend sits high in the key and the base face low",
          wl.SECONDARY_CENTRE_Y < wl.FACE_CENTRE_Y_SOLO < wl.FACE_CENTRE_Y_DUAL,
          True)

    # --- 🔴 NO GAP BETWEEN THE HALVES, read off the pixels -------------------
    #
    # The geometry tests above pin the rectangles; this pins what is PAINTED.
    # A renderer that placed keys correctly and then filled a band of panel
    # colour over the middle would pass those and fail this.
    #
    # The rule: on any horizontal scan through a row, a run of panel colour is
    # an inter-key gap and may never be wider than one. The measured reference
    # gap is 4-5px at this size; ours is 2*PAD. The old gutter was 48px and the
    # thing the operator saw on screen measured ~62px, so any bound near the
    # ordinary gap catches it by an order of magnitude.
    MAX_GAP = math.ceil(2 * PAD) + 2

    def widest_panel_run(surf, y):
        worst = run = 0
        for px in range(int(W)):
            if near(pixel(surf, px, y), rgb(wl.PANEL_FILL)):
                run += 1
                worst = max(worst, run)
            else:
                run = 0
        return worst

    for row_index in range(len(osk.LETTERS.rows)):
        y = TOP + row_index * ROW_H + ROW_H / 2
        check(f"row {row_index}: no run of background wider than an ordinary "
              f"inter-key gap ({MAX_GAP}px)",
              widest_panel_run(idle, y) <= MAX_GAP, True)

    # And the split itself, directly. Rows 0-3 break on a key boundary there,
    # so an ordinary gap is correct; row 4's space bar straddles it, so there
    # must be no background at all.
    #
    # ⚠️ THE SPLIT IS AT A DIFFERENT PIXEL ON EVERY ROW now that each row is
    # scaled on its own -- 676, 550, 579, 640, 752 at this width. Probing the
    # cell grid's 640 on all five would test row 3 and, on the other four, a
    # patch of solid key that proves nothing.
    for row_index in range(4):
        y = int(TOP + row_index * ROW_H + ROW_H / 2)
        split_x = int(split_pixel(osk.LETTERS, row_index, W))
        band = [px for px in range(split_x - 30, split_x + 30)
                if near(pixel(idle, px, y), rgb(wl.PANEL_FILL))]
        check(f"row {row_index}: the split carries an ordinary gap and nothing "
              f"more", 0 < len(band) <= MAX_GAP, True)
    y_space = int(TOP + 4 * ROW_H + ROW_H / 2)
    split_x = int(split_pixel(osk.LETTERS, 4, W))
    check("row 4: the space bar straddles the split, so there is NO background "
          "there at all",
          region_has(idle, split_x - 20, y_space - 2, 40, 4, wl.PANEL_FILL),
          False)

    # --- 🔴 THE DRAWN WIDTHS, MEASURED THE WAY THE REFERENCE WAS -------------
    #
    # `docs/findings/T8-reference-metrics.md` §2 was produced by scanning a row
    # of `01-idle.png` for runs of non-gap colour and reading each key's fill
    # start and end. This does the same thing to our own raster, so it checks
    # what is PAINTED rather than what `key_rects` returns -- a renderer that
    # computed the right rectangle and then filled the wrong one passes every
    # geometry test above and fails here.
    #
    # The scan line sits high in the row, clear of every legend and badge: a
    # glyph's antialiased edge passes through greys near the panel colour, and
    # a scan through one would split a key's run in two.
    def fill_runs(surf, y):
        out, start = [], None
        for px in range(int(W)):
            if near(pixel(surf, px, y), rgb(wl.PANEL_FILL)):
                if start is not None:
                    out.append(px - start)
                    start = None
            elif start is None:
                start = px
        if start is not None:
            out.append(int(W) - start)
        return out

    # Two poses, so no row is ever scanned with a cursor dot on it -- the dot
    # is the one thing drawn across the gaps, and it would bridge two runs.
    #
    # ⚠️ BOTH PADS MARKED TOUCHED, deliberately. Since the cursors gate on
    # touch, a default keyboard draws no dots at all and this scan would have
    # nothing to avoid -- the parking would still pass while testing less than
    # it says. Touched keeps the dots real and the avoidance meaningful.
    def parked(y):
        c = osk.Cursors()
        c.pos["left"] = [0.5, y]
        c.pos["right"] = [0.5, y]
        return render(touching(), cursors=c)

    parked_low, parked_high = parked(0.98), parked(0.02)
    for row_index in range(len(osk.LETTERS.rows)):
        surface = parked_high if row_index == 4 else parked_low
        scan_y = int(TOP + row_index * ROW_H + 0.12 * ROW_H)
        measured = fill_runs(surface, scan_y)
        want = [w for _n, w in REF_FILL_PX[row_index]]
        check(f"row {row_index}: the raster carries one run of key colour per "
              f"key, so the gaps are where they should be",
              len(measured), len(want))
        # ⚠️ Tolerance 2.0, not the 1.5 the geometry is held to: a fill edge at
        # a fractional x antialiases, and a blended pixel reads as key rather
        # than gap, which inflates every run by about 1px.
        check(f"row {row_index}: and every painted fill matches metrics §2's "
              f"measured pixels",
              [(n, m, w) for (n, _u), m, w in
               zip(REF_FILL_PX[row_index], measured, want)
               if abs(in_reference_frame(m, W, PAD * 2) - w) > 2.0], [])

    # Nothing a key draws may spill into the gap beside it. A legend that
    # overflowed its own key -- `_fit` failing to shrink "Backspace", an arrow
    # drawn too large -- reads as one smeared key rather than two, and it
    # cannot be seen by any test that only asks "was something painted".
    # Rows 2 is skipped: both idle cursors sit there, and the dot is allowed
    # to overhang, being the one thing drawn on top of the whole grid.
    spills = []
    for row_index in (0, 1, 3, 4):
        row = sorted((r for r in wl.key_rects(osk.LETTERS, W, H)
                      if r[0] == row_index), key=lambda r: r[2])
        for cur_rect, nxt in zip(row, row[1:]):
            gx = cur_rect[2] + cur_rect[4]
            y0 = cur_rect[3] + 2
            if not region_is(idle, math.ceil(gx - PAD) + 1, y0,
                             max(int(2 * PAD) - 2, 1), int(ROW_H) - 4,
                             wl.PANEL_FILL):
                spills.append((row_index, round(gx, 1)))
    check("nothing a key paints escapes into the gap beside it", spills, [])

    # --- key fills, measured hex ---------------------------------------------

    qx, qy, qw, qh = face_box(1, 1)
    check("a letter key is filled #0E141B, flat",
          region_is(idle, qx + 4, qy + 4, 6, 6, wl.KEY_FACE), True)
    dx, dy, dw, dh = face_box(0, 1)
    check("a digit key shares the letter fill -- digits are not a third tone",
          region_is(idle, dx + 4, dy + 4, 6, 6, wl.KEY_FACE), True)
    tx, ty, tw, th = face_box(1, 0)          # Tab
    check("an action key is filled pure black",
          region_is(idle, tx + 4, ty + 4, 6, 6, wl.KEY_FACE_ACTION), True)
    check("...which is NOT the letter fill",
          rgb(wl.KEY_FACE_ACTION) == rgb(wl.KEY_FACE), False)
    check("the panel behind the keys is the measured gap colour",
          region_is(idle, W / 2 - 1, TOP + ROW_H - 1, 2, 2, wl.PANEL_FILL),
          True)

    # 🔴 SQUARE CORNERS (metrics §0.1). A rounded key leaves its own corner
    # showing the panel; a square one fills it. Probing one pixel inside the
    # corner is exactly the difference, and it is what the reference was
    # measured on.
    check("a key's top-left corner is filled, not rounded away",
          region_is(idle, math.ceil(qx) + 1, math.ceil(qy) + 1, 2, 2,
                    wl.KEY_FACE), True)
    check("...and its bottom-right corner too",
          region_is(idle, math.floor(qx + qw) - 3, math.floor(qy + qh) - 3, 2, 2,
                    wl.KEY_FACE), True)
    check("KEY_CORNER is zero, so nothing can round them back",
          wl.KEY_CORNER, 0.0)

    # --- the legend rule (T8 §9g, corrected by metrics §0.2) -----------------
    #
    # Unshifted: shifted face small ABOVE, base face large BELOW.
    # Shift:     ONLY the shifted face, SAME SIZE as the small legend, centred.
    # Caps:      legends unchanged; letters uppercase.

    # Two bands per key. `high` is the strip a small legend occupies and a
    # centred one does not, so presence/absence there IS the legend rule.
    # `upper` is looser and only used to MEASURE the small legend's height,
    # which needs the whole glyph rather than a strip of it.
    def high(box):
        return (box[0] + 2, box[1] + 2, box[2] - 4, ROW_H * 0.28)

    def upper(box):
        return (box[0] + 2, box[1] + 2, box[2] - 4, ROW_H * 0.45)

    def lower(box):
        return (box[0] + 2, box[1] + ROW_H * 0.55, box[2] - 4, ROW_H * 0.40)

    digit_box = (dx, dy, dw, dh)
    letter_box = (qx, qy, qw, qh)
    check("the digit key paints a small legend high in the key",
          bool(ink_rows(idle, *high(digit_box), wl.KEY_FACE)), True)
    check("...and its base face low in the key",
          bool(ink_rows(idle, *lower(digit_box), wl.KEY_FACE)), True)
    check("a letter key has NO second legend -- upper and lower case are the "
          "same glyph, so 26 redundant capitals would be clutter",
          bool(ink_rows(idle, *high(letter_box), wl.KEY_FACE)), False)

    shift_kb = osk.OnScreenKeyboard()
    shift_kb.shift = "locked"
    shifted = render(shift_kb)
    check("under shift the small legend high in the key is GONE",
          bool(ink_rows(shifted, *high(digit_box), wl.KEY_FACE)), False)
    check("...replaced by a single face at the key's middle",
          bool(ink_rows(shifted, dx + 2, dy + ROW_H * 0.34, dw - 4,
                        ROW_H * 0.32, wl.KEY_FACE)), True)

    # 🔴 metrics §0.2 -- "reposition to centre, do NOT scale up". §9g's prose
    # said the shift-active face is larger; the pixels say it is the same size.
    idle_small = ink_rows(idle, *upper(digit_box), wl.KEY_FACE)
    shift_only = ink_rows(shifted, dx + 2, dy + 2, dw - 4, dh - 4, wl.KEY_FACE)
    check("the shift-active face is the SAME height as the small legend it "
          "replaced, not larger",
          abs((max(shift_only) - min(shift_only))
              - (max(idle_small) - min(idle_small))) <= 2, True)
    check("...and it has moved DOWN, from high in the key to its middle",
          (min(shift_only) + max(shift_only)) / 2
          > (min(idle_small) + max(idle_small)) / 2 + 4, True)

    caps_kb = osk.OnScreenKeyboard()
    caps_kb.caps = True
    capped = render(caps_kb)
    check("caps leaves the dual legend exactly as it was -- caps is not shift",
          ink_rows(capped, dx + 2, dy + 2, dw - 4, dh - 4, wl.KEY_FACE),
          ink_rows(idle, dx + 2, dy + 2, dw - 4, dh - 4, wl.KEY_FACE))
    check("...but the letters change case, which the raster can see",
          ink_rows(capped, qx, qy, qw, qh, wl.KEY_FACE)
          != ink_rows(idle, qx, qy, qw, qh, wl.KEY_FACE), True)

    # The arrows are drawn by us, not by the font: DejaVu Sans has ▲/▼ but not
    # ◀/▶, and a tofu box on the installer's only keyboard is not acceptable.
    ax_, ay_, aw_, ah_ = face_box(4, 2)
    check("the left-arrow key paints both of its faces",
          len(ink_rows(idle, ax_ + 2, ay_ + 2, aw_ - 4, ah_ - 4,
                       wl.KEY_FACE)) > 6, True)
    check("...and all four glyphs come from our own primitives, not a font we "
          "cannot guarantee", set(wl.ARROW_GLYPHS), {"◀", "▶", "▲", "▼"})

    # ⛔ And `_text` really does take that route. DejaVu Sans -- what
    # `sans-serif` resolves to on the Deck and in the ISO -- carries ▲/▼ but
    # NOT ◀/▶, so a `_text` that fell through to `show_text` would draw tofu
    # boxes on the installer's only keyboard, and every "was something
    # painted" probe would still pass. Rasterise both routes and compare:
    # byte-identical means the arrow branch was taken.
    def one_glyph(draw_it):
        surface = _cairo.ImageSurface(_cairo.FORMAT_ARGB32, 40, 40)
        context = _cairo.Context(surface)
        context.select_font_face(wl.FONT_FAMILY)
        draw_it(context)
        surface.flush()
        return bytes(surface.get_data())

    for glyph in sorted(wl.ARROW_GLYPHS):
        check(f"`{glyph}` is drawn from our own path and never handed to the "
              f"font",
              one_glyph(lambda c, g=glyph:
                        wl._text(c, g, 0, 40, 20, 24, wl.KEY_TEXT))
              == one_glyph(lambda c, g=glyph:
                           wl._arrow(c, g, 20, 20, 24, wl.KEY_TEXT)),
              True)
    arrow_labels = {k.label for row in osk.LETTERS.rows for k in row}
    arrow_labels |= {k.shift_label for row in osk.LETTERS.rows for k in row}
    check("...and every arrow the layout uses has one",
          {g for g in arrow_labels if g in "◀▶▲▼" and g} <= set(wl.ARROW_GLYPHS),
          True)

    # --- active modifiers turn blue ------------------------------------------

    sfx, sfy, sfw, sfh = face_box(3, 11)     # the RIGHT shift key
    check("an idle shift key is black, like any other action key",
          region_is(idle, sfx + 4, sfy + 4, 6, 6, wl.KEY_FACE_ACTION), True)
    check("under shift it turns blue",
          region_is(shifted, sfx + 4, sfy + 4, 6, 6, wl.MODIFIER_ACTIVE), True)
    lsx, lsy, lsw, lsh = face_box(3, 0)      # the LEFT shift key
    check("...and so does the other one, both at once",
          region_is(shifted, lsx + 4, lsy + 4, 6, 6, wl.MODIFIER_ACTIVE), True)
    cpx, cpy, cpw, cph = face_box(2, 0)      # Caps
    check("shift does NOT colour the caps key -- caps is a separate modifier",
          region_is(shifted, cpx + 4, cpy + 4, 6, 6, wl.MODIFIER_ACTIVE), False)
    check("caps latched turns the caps key blue",
          region_is(capped, cpx + 4, cpy + 4, 6, 6, wl.MODIFIER_ACTIVE), True)
    check("...and leaves the shift keys black",
          region_is(capped, sfx + 4, sfy + 4, 6, 6, wl.KEY_FACE_ACTION), True)
    check("nothing else on an idle keyboard is blue",
          region_has(idle, 0, TOP, W, GRID_H, wl.MODIFIER_ACTIVE), False)

    # --- the cursor: a WHITE key face plus a BLUE DOT ------------------------
    #
    # Ours used to tint the whole key cyan (left) or amber (right) and draw no
    # dot at all -- metrics §6 calls that a structurally different cursor
    # model. Both cursors now get the same treatment, which is the point.

    # Positions chosen so both dots sit comfortably inside their key rather
    # than half off the panel edge -- an edge case worth its own test, but not
    # the one that answers "is the cursor drawn the way the reference draws
    # it".
    cursor_cur = osk.Cursors()
    cursor_cur.pos["left"] = [0.30, 0.55]
    cursor_cur.pos["right"] = [0.60, 0.28]
    cursored = render(touching(), cursors=cursor_cur)

    # ⚠️ `osk.UNITS` -- the metric this renderer draws. With the default the
    # probes below would look for a white face on the key the CELL grid points
    # at, which at this pose is a different key entirely.
    hits = [osk.locate(osk.LETTERS, half, *cursor_cur.position(half), osk.UNITS)
            for half in wl.HALVES]
    check("the two cursors are on two different keys", hits[0] != hits[1], True)
    for half, hit in zip(wl.HALVES, hits):
        hx, hy, hw, hh = face_box(*hit)
        check(f"the {half} cursor's key face is WHITE",
              region_has(cursored, hx + 2, hy + 2, hw - 4, 4, wl.CURSOR_FACE),
              True)
        cx, cy = wl.cursor_pixel(osk.LETTERS, half,
                                 cursor_cur.position(half), W, H)
        check(f"the {half} cursor paints a blue dot at the thumb's position",
              region_has(cursored, cx - 1, cy - 1, 3, 3, wl.CURSOR_DOT_FILL),
              True)
        ring_r = ROW_H * wl.CURSOR_DOT_RATIO / 2.0 + ROW_H * wl.CURSOR_RING_RATIO
        check(f"...ringed in grey, which is a measured colour and not "
              f"antialiasing ({half})",
              region_has(cursored, cx - ring_r, cy - 2,
                         ring_r - ROW_H * wl.CURSOR_DOT_RATIO / 2.0 + 1, 4,
                         wl.CURSOR_DOT_RING),
              True)
    check("neither cursor tints a key with a per-thumb accent colour -- one "
          "treatment, both thumbs",
          rgb(wl.CURSOR_FACE), (255, 255, 255))

    # The dot follows the thumb WITHIN the key rather than snapping to its
    # centre: move only the left pad and the dot must move while the white
    # face stays put.
    def dot_left_edge(surf, y):
        want = rgb(wl.CURSOR_DOT_FILL)
        for px in range(int(W)):
            if near(pixel(surf, px, y), want):
                return px
        return None

    nudged = osk.Cursors()
    nudged.pos["left"] = [0.34, 0.55]
    nudged.pos["right"] = [0.60, 0.28]
    nudged_surface = render(touching(), cursors=nudged)
    scan_y = int(wl.cursor_pixel(osk.LETTERS, "left", (0.30, 0.55), W, H)[1])
    check("the nudge stays on the same key, so only the dot can have moved",
          osk.locate(osk.LETTERS, "left", *nudged.position("left"), osk.UNITS),
          hits[0])
    check("moving the thumb inside one key moves the dot, so it is a position "
          "and not a decoration",
          dot_left_edge(nudged_surface, scan_y) > dot_left_edge(cursored, scan_y),
          True)

    # --- 🔴 A LIFTED PAD HAS NO CURSOR AT ALL --------------------------------
    #
    # The operator's first reported defect, 2026-08-12: "the two circle
    # indicators for the thumb trackpads should disappear if i don't have any
    # fingers on the trackpad (they are currently still on the keyboard and
    # highlighting letters)". BOTH halves of the cursor have to go -- the dot
    # AND the white key face. Leaving the highlight behind would be the worse
    # half of the two: it says a key is selected when the trigger over that
    # lifted pad is Shift or Enter and would never commit it.
    #
    # The poses are the ones above, so the only difference between these
    # surfaces and `cursored` is which pads are reported touched.

    def dot_at(surf, half, cursors=cursor_cur):
        cx, cy = wl.cursor_pixel(osk.LETTERS, half, cursors.position(half), W, H)
        return region_has(surf, cx - 1, cy - 1, 3, 3, wl.CURSOR_DOT_FILL)

    def face_lit(surf, hit):
        hx, hy, hw, hh = face_box(*hit)
        return region_has(surf, hx + 2, hy + 2, hw - 4, 4, wl.CURSOR_FACE)

    lifted = render(osk.OnScreenKeyboard(), cursors=cursor_cur)
    check("both pads lifted: neither dot is drawn",
          (dot_at(lifted, "left"), dot_at(lifted, "right")), (False, False))
    check("...and neither key is highlighted",
          (face_lit(lifted, hits[0]), face_lit(lifted, hits[1])), (False, False))
    # Not merely moved: nothing anywhere on the panel is cursor-coloured. A
    # mutation that parked the dots off-key instead of skipping them would pass
    # the two probes above and fail here.
    check("...and no dot is drawn ANYWHERE, so they were skipped and not moved",
          region_has(lifted, 0, 0, W, H, wl.CURSOR_DOT_FILL), False)

    # Per pad, in both directions: one thumb down draws one cursor.
    only_left = render(touching("left"), cursors=cursor_cur)
    check("left pad alone draws the LEFT dot and highlight",
          (dot_at(only_left, "left"), face_lit(only_left, hits[0])), (True, True))
    check("...and neither the right dot nor the right highlight",
          (dot_at(only_left, "right"), face_lit(only_left, hits[1])),
          (False, False))
    only_right = render(touching("right"), cursors=cursor_cur)
    check("right pad alone draws the RIGHT dot and highlight",
          (dot_at(only_right, "right"), face_lit(only_right, hits[1])),
          (True, True))
    check("...and neither the left dot nor the left highlight",
          (dot_at(only_right, "left"), face_lit(only_right, hits[0])),
          (False, False))
    check("and with both down, both are drawn -- the gate is per pad, not a "
          "switch that turns cursors off",
          (dot_at(cursored, "left"), dot_at(cursored, "right"),
           face_lit(cursored, hits[0]), face_lit(cursored, hits[1])),
          (True, True, True, True))

    # --- 🔴 THE DRAWN RECT AND THE HIT-TESTED KEY AGREE, IN THE RASTER -------
    #
    # The reason `locate()` took a `metric=` parameter at all. These four poses
    # are ones where the two metrics name DIFFERENT keys -- up to half a key
    # apart -- so a renderer that drew units and hit-tested cells would light
    # the wrong key while the dot sat on the right one, and every width test
    # above would still pass. Read off the pixels, not off `key_rects`.
    DISAGREEING = (("left", 0.457, 0.30, (1, 2), (1, 1)),    # w, not q
                   ("right", 0.478, 0.90, (4, 3), (4, 4)),   # ▶, not Paste
                   ("right", 0.535, 0.10, (0, 11), (0, 12)),  # -, not =
                   ("left", 0.342, 0.10, (0, 3), (0, 2)))    # 3, not 2
    for half, cx_n, cy_n, want_units, want_cells in DISAGREEING:
        check(f"{half} at ({cx_n}, {cy_n}): the two metrics really do disagree",
              (osk.locate(osk.LETTERS, half, cx_n, cy_n, osk.UNITS),
               osk.locate(osk.LETTERS, half, cx_n, cy_n)),
              (want_units, want_cells))
        probe = osk.Cursors()
        # The other pad is parked in a corner, well clear of both keys.
        probe.pos[half] = [cx_n, cy_n]
        other = "right" if half == "left" else "left"
        probe.pos[other] = [0.99 if other == "right" else 0.01, 0.02]
        surface = render(touching(), cursors=probe)
        ux, uy, uw, uh = face_box(*want_units)
        check(f"{half} at ({cx_n}, {cy_n}): the WHITE face is on the key the "
              f"UNITS hit test names -- the one the renderer drew there",
              region_has(surface, ux + 2, uy + 2, uw - 4, 4, wl.CURSOR_FACE),
              True)
        kx, ky, kw, kh = face_box(*want_cells)
        check(f"...and NOT on the key the CELL grid would have named",
              region_has(surface, kx + 2, ky + 2, kw - 4, 4, wl.CURSOR_FACE),
              False)
        dx_, dy_ = wl.cursor_pixel(osk.LETTERS, half, (cx_n, cy_n), W, H)
        check(f"...and the blue dot is inside that same white key, so the two "
              f"halves of the cursor agree",
              (ux - PAD <= dx_ <= ux + uw + PAD,
               region_has(surface, dx_ - 1, dy_ - 1, 3, 3, wl.CURSOR_DOT_FILL)),
              (True, True))

    # --- badges: shape is semantic, and the gate is per-pad ------------------

    import cairo as _c
    _probe = _c.Context(_c.ImageSurface(_c.FORMAT_ARGB32, 8, 8))
    _probe.select_font_face(wl.FONT_FAMILY)

    def badge_centre(row, col):
        fx, _fy, _fw, _fh = face_box(row, col)
        return wl._badge_box(_probe, key(row, col), fx,
                             RECTS[(row, col)][1], ROW_H)

    def badge_probe(row, col):
        """A 3x3 box inside the badge and CLEAR OF ITS OWN GLYPH.

        The badge centre is where the "X"/"L2" text is painted in near-black,
        so probing there reads the glyph, not the badge. Straight up from the
        centre is inside both shapes -- a circle of radius r at 0.36r off
        centre, and a rounded rect well inside its own height -- and above the
        text's cap height.
        """
        bx, by, _bw, bh = badge_centre(row, col)
        return (bx - 1.5, by - bh * 0.36, 3, 3)

    BADGED = {"backspace": (0, 13), "enter": (2, 12), "caps": (2, 0),
              "shift-left": (3, 0), "shift-right": (3, 11), "space": (4, 1)}
    for name, (row, col) in BADGED.items():
        check(f"{name}'s badge is painted white, idle",
              region_is(idle, *badge_probe(row, col), wl.BADGE_FILL), True)

    # SHAPE. A circle of radius r does not reach the corner of its own 2r
    # bounding square (the corner is r*sqrt(2) away); a rounded rect with a
    # small radius very nearly does. That corner is the only pixel that tells
    # the two apart, so a mutation swapping the shapes is caught here and
    # nowhere else.
    bx, by, bw, bh = badge_centre(0, 13)     # Backspace: circle (face button)
    # ⚠️ Probed at 0.40 of the box in BOTH axes, which is the one place a
    # circle and a rounded SQUARE of the same size differ by more than
    # antialiasing: 0.57 of the radius out at 45 degrees is outside the circle
    # and comfortably inside the rounded rect's corner arc. Probing nearer the
    # true corner reads the rect's own antialiased edge and cannot tell them
    # apart, which let a shape mutation survive.
    check("the Ⓧ badge is a CIRCLE -- it does not reach the corner a rounded "
          "rect of the same size would fill",
          region_has(idle, bx + bh * 0.40, by - bh * 0.40, 2, 2, wl.BADGE_FILL),
          False)
    bx, by, bw, bh = badge_centre(2, 12)     # Enter: rounded rect (trigger)
    check("the R2 badge is a ROUNDED RECT -- its own bounding-box corner IS "
          "badge colour, the opposite of the circle above",
          region_has(idle, bx + bw / 2 - 3, by - bh * 0.30, 2, 2, wl.BADGE_FILL),
          True)

    def badge_shown(surface, row, col):
        return region_is(surface, *badge_probe(row, col), wl.BADGE_FILL)

    left_kb = osk.OnScreenKeyboard()
    left_kb.touched = {"left": True, "right": False}
    left_touched = render(left_kb)
    check("left pad touched hides the LEFT shift's L2 badge",
          badge_shown(left_touched, 3, 0), False)
    check("...and the RIGHT shift's L2 badge too -- both carry it, and the "
          "gate is on the trigger, not on the half the key sits in",
          badge_shown(left_touched, 3, 11), False)
    check("...while R2 stays", badge_shown(left_touched, 2, 12), True)
    check("...and L3 stays -- the stick click is unconditional",
          badge_shown(left_touched, 2, 0), True)
    check("...and Ⓧ stays", badge_shown(left_touched, 0, 13), True)
    check("...and Ⓨ stays", badge_shown(left_touched, 4, 1), True)

    right_kb = osk.OnScreenKeyboard()
    right_kb.touched = {"left": False, "right": True}
    right_touched = render(right_kb)
    check("right pad touched hides the R2 badge", badge_shown(right_touched, 2, 12),
          False)
    check("...and leaves BOTH L2 badges alone",
          (badge_shown(right_touched, 3, 0), badge_shown(right_touched, 3, 11)),
          (True, True))
    check("...and Ⓧ, Ⓨ, L3",
          (badge_shown(right_touched, 0, 13), badge_shown(right_touched, 4, 1),
           badge_shown(right_touched, 2, 0)), (True, True, True))

    both_kb = osk.OnScreenKeyboard()
    both_kb.touched = {"left": True, "right": True}
    both_touched = render(both_kb)
    check("both pads touched hides every trigger badge and no other",
          (badge_shown(both_touched, 3, 0), badge_shown(both_touched, 2, 12),
           badge_shown(both_touched, 0, 13), badge_shown(both_touched, 2, 0)),
          (False, False, True, True))

    # A badge sits INSIDE its key at the left, and the legend is centred in
    # what is left -- `R2` and `Enter` used to be drawn on top of each other.
    ex, ey, ew, eh = face_box(2, 12)
    bx, by, bw, bh = badge_centre(2, 12)
    check("Enter's legend starts clear of its badge",
          region_is(idle, bx + bw / 2 + 1, by - 2, 3, 4, wl.KEY_FACE_ACTION),
          True)

    def first_ink_x(surf, x_from, y, background, tol=24):
        bg = rgb(background)
        for px in range(int(x_from), int(W)):
            if not near(pixel(surf, px, y), bg, tol):
                return px
        return int(W)

    # ⚠️ "There is a gap after the badge" is not enough: a legend centred over
    # the WHOLE key still leaves one, it just sits further left than it should.
    # Compare the same key with its badge gated away -- the legend must move.
    # `right_touched` is the R2 badge's hidden frame, so Enter there is the
    # un-badged version of the very same key.
    band_y = int(RECTS[(2, 12)][1] + ROW_H * 0.50)
    scan_from = int(bx + bw / 2 + 2)
    check("Enter's legend is RE-CENTRED into what the badge leaves, not merely "
          "drawn beside it",
          first_ink_x(idle, scan_from, band_y, wl.KEY_FACE_ACTION)
          > first_ink_x(right_touched, scan_from, band_y,
                        wl.KEY_FACE_ACTION) + 8,
          True)

    # `_fit` shrinks a label that will not fit. At the Deck's own size no
    # legend needs it, so a raster probe there cannot see the difference --
    # this asks the function directly, which is where the behaviour lives.
    _probe.set_font_face(_probe.get_font_face())
    wide = wl._fit(_probe, "Backspace", 400.0, 30.0)
    narrow = wl._fit(_probe, "Backspace", 40.0, 30.0)
    check("_fit leaves a label that already fits alone", wide, 30.0)
    check("_fit shrinks one that does not", narrow < 30.0, True)
    _probe.set_font_size(narrow)
    check("...until it actually fits",
          _probe.text_extents("Backspace").width <= 40.0 * wl.LABEL_WIDTH_BUDGET,
          True)
    check("_fit never tries to measure an arrow -- those are our own paths, "
          "and the font may have no glyph to measure",
          wl._fit(_probe, "◀", 1.0, 30.0), 30.0)

    # --- the in-use stripe ---------------------------------------------------

    check("the stripe band is reserved at the top in every state",
          wl.stripe_height(H) > 0, True)
    check("idle paints no stripe -- it is the panel colour up there",
          region_is(idle, 0, 0, W, wl.stripe_height(H), wl.PANEL_FILL), True)
    check("shift paints the stripe, full width",
          region_is(shifted, 0, 0, W, wl.stripe_height(H), wl.STRIPE_FILL), True)
    check("caps paints it too",
          region_is(capped, 0, 0, W, wl.stripe_height(H), wl.STRIPE_FILL), True)
    check("a touched pad paints it",
          region_is(left_touched, 0, 0, W, wl.stripe_height(H), wl.STRIPE_FILL),
          True)
    check("and the stripe never eats into row 0's keys",
          region_is(idle, math.ceil(qx) + 1, math.ceil(TOP + PAD) + 1, 2, 2,
                    wl.STRIPE_FILL), False)

    # --- it survives odd sizes ----------------------------------------------

    draw_failures = []
    for width, height in SIZES + ((320, 96), (2560, 716)):
        for layer_name in osk.LAYERS:
            keyboard = osk.OnScreenKeyboard(layer_name)
            # Touched, so the cursor path is exercised at every size too -- with
            # the pads lifted `cursor_pixel` is never called and a geometry
            # crash there would go unseen at all but the Deck's own dimensions.
            keyboard.touched = {"left": True, "right": True}
            cursors = osk.Cursors()
            cursors.update(e.ABS_HAT0X, MIN + 1)
            cursors.update(e.ABS_HAT0Y, MIN + 1)
            try:
                render(keyboard, cursors, width, height)
            except Exception as exc:      # noqa: BLE001 -- report, do not hide
                draw_failures.append((width, height, layer_name, repr(exc)))
    check("draw() completes without raising across every size and layer",
          draw_failures, [])
    check("draw() actually paints -- the surface is not left blank",
          any(b for b in render().get_data()), True)

print()
print(f"{'PASS' if FAILURES == 0 else 'FAIL'} — {FAILURES} failure(s)")
sys.exit(1 if FAILURES else 0)
