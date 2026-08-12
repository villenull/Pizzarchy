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

# --- draw(): a real smoke test, when pycairo happens to be importable --------
#
# The module header says "the drawing itself needs eyes" and that is still
# true for APPEARANCE -- but `draw()` only needs a Cairo context, not a
# display, a compositor, or `gi` (that import stays inside `main()` on
# purpose). Where pycairo is present this at least proves the T8 §9 additions
# -- the secondary legend, the hint badges, the gutter divider -- run without
# raising, across both layers, a highlighted and an unhighlighted key, and a
# handful of the same odd sizes the geometry tests above use. It cannot check
# what was drawn; `--demo` is still how a human confirms that.
try:
    import cairo as _cairo
except ImportError:
    print("skip -- pycairo not importable here; draw() was not exercised")
else:
    draw_failures = []
    for w, h, g in SIZES:
        w, h = max(w, 40), max(h, 40)  # a real key needs positive room
        for layer_name in ("letters", "symbols"):
            kb = osk.OnScreenKeyboard(layer_name)
            cur = osk.Cursors()
            cur.update(e.ABS_HAT0X, MIN)   # put a real highlight on screen
            cur.update(e.ABS_HAT0Y, MIN)
            surface = _cairo.ImageSurface(_cairo.FORMAT_ARGB32, int(w), int(h))
            cr = _cairo.Context(surface)
            try:
                wl.draw(cr, kb, cur, float(w), float(h), float(g))
            except Exception as exc:  # noqa: BLE001 -- report, do not hide, which key
                draw_failures.append((w, h, g, layer_name, repr(exc)))
    check("draw() completes without raising, both layers, several sizes",
          draw_failures, [])

    # A blank surface would mean nothing was actually painted -- catches a
    # `draw()` that raced past every `cr.fill()`/`show_text()` call for some
    # reason without technically raising.
    surface = _cairo.ImageSurface(_cairo.FORMAT_ARGB32, 1280, 336)
    cr = _cairo.Context(surface)
    wl.draw(cr, osk.OnScreenKeyboard(), osk.Cursors(), 1280.0, 336.0, 48.0)
    check("draw() actually paints something -- the surface is not left blank",
          any(b for b in surface.get_data()), True)

    # --- T8 §9, checked in PIXELS: "completes without raising" cannot tell a
    # drawn hint from a silently-skipped one -- the mutation that proved it
    # is `if False and key.hint:`, which still runs clean and still paints a
    # non-blank surface. These read the actual raster.

    def pixel(surf, px, py):
        """(r, g, b, a) at one pixel. ARGB32 is little-endian BGRA in memory."""
        surf.flush()
        stride = surf.get_stride()
        buf = surf.get_data()
        off = int(py) * stride + int(px) * 4
        b, g, r, a = buf[off], buf[off + 1], buf[off + 2], buf[off + 3]
        return (r, g, b, a)

    def region_differs(surf, x0, y0, w, h, from_rgb, tol=10):
        """True if ANY pixel in the box differs from `from_rgb` (0..1 floats)
        by more than `tol` on any channel -- "something was drawn here"."""
        want = tuple(round(c * 255) for c in from_rgb)
        for py in range(int(y0), int(y0 + h)):
            for px in range(int(x0), int(x0 + w)):
                r, g, b, _a = pixel(surf, px, py)
                if (abs(r - want[0]) > tol or abs(g - want[1]) > tol
                        or abs(b - want[2]) > tol):
                    return True
        return False

    W, H, G = 1280.0, 336.0, 48.0
    kb_hint = osk.OnScreenKeyboard("letters")
    cur_hint = osk.Cursors()   # centred: nothing highlighted at row 0/4
    surface = _cairo.ImageSurface(_cairo.FORMAT_ARGB32, int(W), int(H))
    cr = _cairo.Context(surface)
    wl.draw(cr, kb_hint, cur_hint, W, H, G)
    rects = {(half, r, k): (x, y, w, h) for half, r, k, x, y, w, h in
             wl.key_rects(kb_hint.layer, W, H, G)}

    KEY_PAD = wl.KEY_PAD

    # Shift (row 4, col 0, left) carries a hint; tab (row 4, col 2, left)
    # does not. Same row -> same height -> the badge's anchor is comparable
    # between them. `_hint_badge` is anchored at (x+KEY_PAD+2, y+h-KEY_PAD-2)
    # and hangs UP and RIGHT from there -- probe a small box just inside that
    # anchor, well clear of the rounded rect's own 1px border and the corner
    # radius, both of which are "not KEY_FACE" for every key and would make
    # this pass even with the badge deleted.
    sx, sy, sw, sh = rects[("left", 4, 0)]
    check("shift's key rect is where key_rects says it is", sw > 0 and sh > 0, True)
    badge_probe = (sx + KEY_PAD + 4, sy + sh - KEY_PAD - 14, 8, 8)
    check("the hint badge actually paints non-key-colour pixels in shift's "
          "bottom-left corner",
          region_differs(surface, *badge_probe, wl.KEY_FACE), True)
    tx, ty, tw, th = rects[("left", 4, 2)]
    check("the SAME corner of an un-hinted key (tab) is left plain",
          region_differs(surface, tx + KEY_PAD + 4, ty + th - KEY_PAD - 14, 8, 8,
                         wl.KEY_FACE),
          False)

    # Digit "1" (row 0, col 0, left) carries a secondary legend; letter "q"
    # (row 1, col 0, left) does not. Same probe-inset reasoning as above,
    # against the secondary legend's own top-right anchor.
    dx, dy, dw, dh = rects[("left", 0, 0)]
    check("the secondary legend paints non-key-colour pixels in the digit's "
          "top-right corner",
          region_differs(surface, dx + dw - KEY_PAD - 12, dy + KEY_PAD + 4, 8, 8,
                         wl.KEY_FACE),
          True)
    qx, qy, qw, qh = rects[("left", 1, 0)]
    check("the SAME corner of a letter key (q) is left plain -- letters are "
          "excluded by secondary_face() itself",
          region_differs(surface, qx + qw - KEY_PAD - 12, qy + KEY_PAD + 4, 8, 8,
                         wl.KEY_FACE),
          False)

    # The gutter divider: the exact centre column differs from a column well
    # inside the same blank gutter but away from the 1.5px line -- proving a
    # line was actually stroked there, not merely that "gutter" is blank.
    x0_left, half_w = wl.half_bounds(W, G)["left"]
    divider_x = x0_left + half_w + G / 2.0
    check("the gutter divider line is visibly different from the surrounding "
          "blank gutter",
          region_differs(surface, divider_x - 1, H / 2 - 4, 2, 8, wl.BACKDROP),
          True)
    check("...but a column elsewhere in the same blank gutter is not",
          region_differs(surface, divider_x - 15, H / 2 - 4, 2, 8, wl.BACKDROP),
          False)

    # No gutter, no line to draw -- must not raise (already covered by the
    # SIZES sweep above) and must not paint anything IN the seam either, since
    # there is no seam: the halves are adjacent.
    surface0 = _cairo.ImageSurface(_cairo.FORMAT_ARGB32, 640, 200)
    cr0 = _cairo.Context(surface0)
    wl.draw(cr0, osk.OnScreenKeyboard(), osk.Cursors(), 640.0, 200.0, 0.0)
    check("draw() with gutter=0 does not raise (no divider to place)", True, True)

print()
print(f"{'PASS' if FAILURES == 0 else 'FAIL'} — {FAILURES} failure(s)")
sys.exit(1 if FAILURES else 0)
