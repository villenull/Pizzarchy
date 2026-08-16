#!/usr/bin/env python3
"""Unit tests for the on-screen keyboard's layout core (T8 steps 1-2, §9g).

No device, no uinput, no compositor, no root. Run directly:

    python3 test-deck-osk-layout.py

⚠️ The character expectations here are DELIBERATELY INDEPENDENT of
`src/deck_osk_layout.py`. Decoding a keystroke with the same table that
produced it proves only that the module agrees with itself: a key labelled "a"
carrying KEY_B round-trips perfectly and types the wrong letter. So letters are
resolved through evdev's own KEY_* names, the punctuation faces are written out
longhand below from the US layout, and the ROW TRANSCRIPTION and the BADGE
BINDINGS are written out longhand from T8 §9g rather than read back out of the
module under test.
"""

from __future__ import annotations

import importlib.util
import pathlib
import string
import sys

from evdev import ecodes as e

# ⚠️ Before loading anything. Python validates a cached .pyc against the
# source's (mtime, size), both at one-second granularity -- so an edit that
# keeps the byte count and lands in the same second as the last run silently
# executes the PREVIOUS version. This bit during session 18's mutation testing:
# restoring the original file left the mutant's bytecode in place and the suite
# reported four failures against correct source. Any same-size edit can do it,
# and mutation testing makes same-size edits on purpose.
sys.dont_write_bytecode = True

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "deck_osk_layout", REPO_ROOT / "src" / "deck_osk_layout.py"
)
osk = importlib.util.module_from_spec(spec)
sys.modules["deck_osk_layout"] = osk
spec.loader.exec_module(osk)

FAILURES = 0


def check(what: str, got, want) -> None:
    global FAILURES
    if got == want:
        print(f"ok   {what} = {got!r}")
    else:
        print(f"FAIL {what}: got {got!r}, want {want!r}")
        FAILURES += 1


def raises(fn) -> bool:
    """Did calling fn() raise ValueError? Silence here would be the bug."""
    try:
        fn()
    except ValueError:
        return True
    return False


# --- an independent US-layout table, for decoding emitted keystrokes ---------

# Letters come from evdev's own naming, not from the layout under test.
LETTER_FACE = {getattr(e, f"KEY_{c.upper()}"): c for c in string.ascii_lowercase}

# Digits and punctuation, written out from the US layout.
PUNCT_FACE = {
    e.KEY_1: ("1", "!"), e.KEY_2: ("2", "@"), e.KEY_3: ("3", "#"),
    e.KEY_4: ("4", "$"), e.KEY_5: ("5", "%"), e.KEY_6: ("6", "^"),
    e.KEY_7: ("7", "&"), e.KEY_8: ("8", "*"), e.KEY_9: ("9", "("),
    e.KEY_0: ("0", ")"), e.KEY_MINUS: ("-", "_"), e.KEY_EQUAL: ("=", "+"),
    e.KEY_LEFTBRACE: ("[", "{"), e.KEY_RIGHTBRACE: ("]", "}"),
    e.KEY_BACKSLASH: ("\\", "|"), e.KEY_SEMICOLON: (";", ":"),
    e.KEY_APOSTROPHE: ("'", '"'), e.KEY_GRAVE: ("`", "~"),
    e.KEY_COMMA: (",", "<"), e.KEY_DOT: (".", ">"), e.KEY_SLASH: ("/", "?"),
    e.KEY_SPACE: (" ", " "),
}


def decode(strokes: list[tuple[int, int]]) -> str:
    """Replay keystrokes the way the kernel's consumer would, into text."""
    out, shift = [], False
    for code, value in strokes:
        if code == e.KEY_LEFTSHIFT:
            shift = value == 1
            continue
        if value != 1:  # key-up types nothing
            continue
        if code in PUNCT_FACE:
            out.append(PUNCT_FACE[code][1 if shift else 0])
        elif code in LETTER_FACE:
            out.append(LETTER_FACE[code].upper() if shift else LETTER_FACE[code])
        else:
            out.append(f"<{'SHIFT+' if shift else ''}{e.KEY[code]}>")
    return "".join(out)


def press(kb, half: str, x: float, y: float) -> str:
    """Press at a point and return what it typed, decoded."""
    return decode(kb.press_at(half, x, y))


def every_key():
    """Every key in every layer, as (layer name, row, index, key)."""
    for layer in osk.LAYERS.values():
        for r, row in enumerate(layer.rows):
            for i, key in enumerate(row):
                yield (layer.name, r, i, key)


# --- T8 §9g: ONE CONTINUOUS GRID, transcribed longhand ------------------------
#
# The reference, from six `grim` captures of Valve's keyboard on this Deck:
#
#   row 1  [~`][!1][@2][#3][$4][%5][^6][&7][*8][(9][)0][_-][+=]  (Ⓧ) Backspace
#   row 2  [Tab]  q w e r t y u i o p  [{[] [}]] [|\]
#   row 3  [Caps L3]  a s d f g h j k l  [:;] ["']  [R2] Enter
#   row 4  [Shift L2]  z x c v b n m  [<,] [>.] [?/]  [L2 Shift]
#   row 5  [☺] (Ⓨ) ---- space ---- [▲/◀] [▼/▶] [Paste] [Move]
#
# Written out here rather than derived, so a layout that quietly loses a key
# fails rather than agreeing with itself.

REFERENCE_ROWS = [
    ["`", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "=",
     "Backspace"],
    ["Tab", "q", "w", "e", "r", "t", "y", "u", "i", "o", "p", "[", "]", "\\"],
    ["Caps", "a", "s", "d", "f", "g", "h", "j", "k", "l", ";", "'", "Enter"],
    ["Shift", "z", "x", "c", "v", "b", "n", "m", ",", ".", "/", "Shift"],
    ["☺", "space", "◀", "▶", "Paste", "Move"],
]
# The shifted face of every dual-legend key, in the same order. "" where the
# key has none.
REFERENCE_SHIFTED = [
    ["~", "!", "@", "#", "$", "%", "^", "&", "*", "(", ")", "_", "+", ""],
    ["", "Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P", "{", "}", "|"],
    ["", "A", "S", "D", "F", "G", "H", "J", "K", "L", ":", '"', ""],
    ["", "Z", "X", "C", "V", "B", "N", "M", "<", ">", "?", ""],
    ["", "", "▲", "▼", "", ""],
]

LETTERS = osk.LETTERS

check("there is exactly ONE layer -- the ?#= symbol layer is gone",
      sorted(osk.LAYERS), ["letters"])
check("no key anywhere switches layers",
      [k.label for _n, _r, _i, k in every_key() if k.action == "layer"], [])
check("and no key closes the keyboard -- Valve's has none either",
      [k.label for _n, _r, _i, k in every_key() if k.action == "close"], [])

check("the grid has five rows", len(LETTERS.rows), 5)
for r, expected in enumerate(REFERENCE_ROWS):
    check(f"row {r} transcribes §9g exactly",
          [k.label for k in LETTERS.rows[r]], expected)
for r, expected in enumerate(REFERENCE_SHIFTED):
    check(f"row {r}'s shifted faces transcribe §9g exactly",
          [k.shift_label for k in LETTERS.rows[r]], expected)

check("the number row is THIRTEEN keys, not ten -- ~` through +=",
      len([k for k in LETTERS.rows[0] if k.shift_label]), 13)

# 🔴 One continuous grid. The old model was two independent half-grids drawn
# side by side, and the gap between them was the operator's first complaint.
check("a layer exposes ONE grid, not a left half and a right half",
      (hasattr(LETTERS, "rows"), hasattr(LETTERS, "left"), hasattr(LETTERS, "right")),
      (True, False, False))
check("every row is the same width in cells",
      {sum(k.span for k in row) for row in LETTERS.rows}, {LETTERS.width})
check("the grid is 16 cells wide", LETTERS.width, 16)

# The two halves are two WINDOWS on one grid: contiguous, non-overlapping, and
# together they cover every cell. A gap here would be the split coming back.
left_cells = LETTERS.half_cells("left")
right_cells = LETTERS.half_cells("right")
check("the left half starts at cell 0", left_cells[0], 0)
check("the right half starts exactly where the left one ends",
      right_cells[0], left_cells[1])
check("the right half ends at the last cell", right_cells[1], LETTERS.width)
check("the halves leave no cell unreachable",
      set(range(*left_cells)) | set(range(*right_cells)),
      set(range(LETTERS.width)))
check("and no cell reachable twice",
      set(range(*left_cells)) & set(range(*right_cells)), set())
check("an unknown half raises rather than guessing a side",
      raises(lambda: LETTERS.half_cells("middle")), True)

# The installer's TTY is 25x80 in the worst case (docs/PROGRESS.md §7). 16
# cells is what makes 80 columns divide evenly; a wider grid cannot be drawn on
# the one console with no fallback.
check("the grid divides 80 columns evenly, so the installer's TTY can draw it",
      80 % LETTERS.width, 0)
check("five rows fit a 25-row console with room for a prompt",
      len(LETTERS.rows) * 3 <= 25, True)

# A ragged grid cannot line up on screen, and drawing one anyway would hide the
# bug rather than report it.
# ⚠️ The split of this one is deliberately VALID for both rows, so only the
# width check can be what rejects it. A ragged layer whose split also happened
# to be out of range would pass this assertion with the width check deleted --
# it did, during mutation testing.
check("a layer with rows of differing widths is refused",
      raises(lambda: osk.Layer(name="ragged", split=1,
                               rows=((osk.letter("a"), osk.letter("b"),
                                      osk.letter("c")),
                                     (osk.letter("a"), osk.letter("b"))))),
      True)
check("a split outside the grid is refused",
      raises(lambda: osk.Layer(name="bad", split=9,
                               rows=((osk.letter("a"), osk.letter("b")),))),
      True)
check("a split of 0 is refused -- one pad would address nothing",
      raises(lambda: osk.Layer(name="bad", split=0,
                               rows=((osk.letter("a"), osk.letter("b")),))),
      True)
check("a layer with no rows is refused",
      raises(lambda: osk.Layer(name="empty", split=1, rows=())), True)

check("cell_bounds places keys across the full width, contiguously",
      LETTERS.cell_bounds(4),
      ((0, 1), (1, 9), (9, 10), (10, 11), (11, 13), (13, 16)))


# --- the SECOND width: visual units, measured off the reference ---------------
#
# 🔴 The largest remaining visual difference from Valve's keyboard, and the
# reason a key now carries two widths. Ours drew a uniform 16-cell grid, which
# makes Tab and Caps THREE TIMES a letter where the reference draws them at
# 1.03 and 1.36. A 16-cell integer grid cannot express 0.52 or 1.71, and the
# grid cannot simply be refined: 16 cells x KEY_CELL=5 is exactly the installed
# TTY's 80 columns with nothing spare (`docs/PROGRESS.md` §7), and that
# keyboard is how a user types a Wi-Fi passphrase with no physical keyboard.
#
# ⚠️ THE NUMBERS BELOW ARE metrics §2's PIXEL TABLE, NOT ITS RATIO COLUMN.
# §2 reports both: measured FILL WIDTHS in px (42, 89, 149, 119, 149, 178, 104,
# 725 against an 85px unit key) and a derived "x unit" column (0.49, 1.05,
# 1.75, ...). The ratio column divides fill by fill and so drops the inter-key
# gap; the pixel widths are the primary measurement. This test rebuilds the
# reference's geometry from the module's `units` and compares against the PIXEL
# widths, which is the only form that can be checked without re-deriving the
# thing under test.
#
# The reconstruction, all from metrics §2: the panel's key fill spans x=5..1273
# on a 1280-wide screen (1269px), the inter-key gap is ~4.5px, and EVERY ROW IS
# SCALED TO THE FULL WIDTH ON ITS OWN -- §2 measures a unit key at 85px in row 1
# and 86-87px in rows 2-4, which is what per-row normalisation looks like.

REF_FILL_SPAN = 1269.0   # metrics §2: fill x=5..1273 inclusive, 1280-wide screen
REF_GAP = 4.5            # metrics §2: inter-key gap alternates 4-5px

# Every key's measured FILL WIDTH in px, written out longhand from metrics §2
# rather than read back out of the module.
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


def rebuild_row(row_index: int) -> list[tuple[str, float]]:
    """(label, fill width in px) for one row, laid out the way a renderer must.

    Scale the row by `(span + gap) / row_units`, then each key's painted fill
    is `units * pitch - gap`. If this does not reproduce metrics §2's pixel
    table, `units` is wrong.
    """
    pitch = (REF_FILL_SPAN + REF_GAP) / LETTERS.row_units(row_index)
    return [(key.label, key.units * pitch - REF_GAP)
            for key in LETTERS.rows[row_index]]


for r in range(5):
    check(f"row {r}'s units name the same keys metrics §2 measured, in order",
          [k.label for k in LETTERS.rows[r]], [n for n, _ in REF_FILL_PX[r]])
    rebuilt = rebuild_row(r)
    check(f"row {r} rebuilds metrics §2's measured fill widths to within 1.5px",
          [n for (n, got), (_, want) in zip(rebuilt, REF_FILL_PX[r])
           if abs(got - want) > 1.5], [])
    # A row that reproduced every key and still ended short would leave a
    # ragged right edge -- the defect this replaced, in a new place.
    check(f"row {r} ends flush at the panel's right edge",
          round(sum(w for _n, w in rebuilt) + REF_GAP * (len(rebuilt) - 1)),
          round(REF_FILL_SPAN))

# ⚠️ WHY THE RATIO COLUMN IS NOT USED, asserted rather than asserted-in-a-
# comment. Laying row 0 out with metrics §2's "x unit" column instead misplaces
# the widest key by more than the 1.5px tolerance above -- that is the entire
# reason this module carries pitch ratios and the finding does not.
RATIO_COLUMN = {"`": 0.49, "Backspace": 1.75}
ratio_units = [RATIO_COLUMN.get(k.label, 1.0) for k in LETTERS.rows[0]]
ratio_pitch = (REF_FILL_SPAN + REF_GAP) / sum(ratio_units)
check("metrics §2's ratio column would misplace Backspace by >1.5px",
      abs((RATIO_COLUMN["Backspace"] * ratio_pitch - REF_GAP) - 149) > 1.5, True)

# The two widths are INDEPENDENT, and these three keys are the proof: one cell
# and half a unit, three cells and one unit, three cells and two units. Any
# attempt to derive one from the other fails on this row alone.
check("span and units are independent -- backtick, Tab and Shift prove it",
      [(k.span, k.units) for k in
       (LETTERS.rows[0][0], osk.TAB_KEY, osk.SHIFT_KEY)],
      [(1, 0.52), (3, 1.03), (3, 2.01)])
check("a letter key is exactly one unit -- what every other width is measured against",
      {k.units for r in LETTERS.rows for k in r if k.is_letter}, {1.0})

check("unit_bounds places keys contiguously from 0 to the row's own total",
      (LETTERS.unit_bounds(4)[0][0],
       abs(LETTERS.unit_bounds(4)[-1][1] - LETTERS.row_units(4)) < 1e-9,
       [round(b, 2) for _a, b in LETTERS.unit_bounds(4)]),
      (0.0, True, [1.2, 9.28, 10.48, 11.68, 12.88, 14.08]))
check("unit_bounds leaves no overlap and no hole in any row",
      [(r, i) for r in range(5)
       for i, ((_, end), (start, _)) in
       enumerate(zip(LETTERS.unit_bounds(r), LETTERS.unit_bounds(r)[1:]))
       if abs(end - start) > 1e-9], [])

# 🔴 ROWS DIFFER IN UNITS AND THAT IS THE MEASUREMENT, not a bug: the reference
# fixes its special keys and lets the unit keys absorb the remainder, which is
# why a unit key is 85px in row 1 and 86-87px in rows 2-4. `width` (cells) is
# still identical on every row; `row_units` is not.
row_unit_totals = [round(LETTERS.row_units(r), 2) for r in range(5)]
check("every row is the same width in CELLS", {LETTERS.width}, {16})
check("the rows are NOT the same width in units", len(set(row_unit_totals)), 5)
check("but they stay within the tolerance a layer will accept",
      max(row_unit_totals) - min(row_unit_totals) <= osk.ROW_UNITS_TOLERANCE,
      True)
check("and the tolerance still admits the reference's own 0.21 spread",
      osk.ROW_UNITS_TOLERANCE >= 0.21, True)

check("a key with zero visual width is refused",
      raises(lambda: osk.Layer(name="bad", split=1,
                               rows=((osk.letter("a"),
                                      osk.Key(label="b", units=0.0)),))), True)
check("a key with negative visual width is refused",
      raises(lambda: osk.Layer(name="bad", split=1,
                               rows=((osk.letter("a"),
                                      osk.Key(label="b", units=-1.0)),))), True)
# ⚠️ Same cell width on both rows, so ONLY the units check can reject this.
check("a layer whose rows disagree wildly in units is refused",
      raises(lambda: osk.Layer(name="bad", split=1,
                               rows=((osk.letter("a"), osk.letter("b")),
                                     (osk.letter("a"),
                                      osk.Key(label="wide", units=5.0))))),
      True)

# --- the 80-column fit, which the visual widths must not have disturbed -------
#
# `docs/PROGRESS.md` §7: the installed TTY is 25x80. `deck_osk_tty.py`'s
# KEY_CELL is 5 and 16 x 5 = 80 EXACTLY -- `test-deck-osk-tty.py` and
# `test-osk-install-layout.sh` both assert that as an equality. Restated here
# because this file is where a change to `span` would originate.
check("16 cells at 5 columns each is exactly the installed TTY's 80",
      LETTERS.width * 5, 80)
check("no key's span changed -- every row still totals 16 cells",
      {sum(k.span for k in row) for row in LETTERS.rows}, {16})
check("and spans are still integers, which a text console requires",
      {type(k.span) for _n, _r, _i, k in every_key()}, {int})


# --- hit-testing: rows AND columns together ----------------------------------
#
# T8's first named failure mode is testing one axis at a time -- session 17's
# pointer emitted nothing on diagonal movement while every single-axis test
# passed. So every hit test below varies x and y together, and each half is
# walked cell by cell rather than sampled.

kb = osk.OnScreenKeyboard()
check("starts on the letters layer", kb.layer_name, "letters")
check("starts unshifted", kb.shift, "off")
check("starts with caps off", kb.caps, False)
check("starts open", kb.closed, False)

# Eight cells per half, five rows: centres at (2i+1)/16 and (2r+1)/10.
CX = tuple((2 * i + 1) / 16 for i in range(8))
CY = tuple((2 * r + 1) / 10 for r in range(5))

WALK_LEFT = [
    ["`", "1", "2", "3", "4", "5", "6", "7"],
    ["Tab", "Tab", "Tab", "q", "w", "e", "r", "t"],
    ["Caps", "Caps", "Caps", "a", "s", "d", "f", "g"],
    ["Shift", "Shift", "Shift", "z", "x", "c", "v", "b"],
    ["☺", "space", "space", "space", "space", "space", "space", "space"],
]
WALK_RIGHT = [
    ["8", "9", "0", "-", "=", "Backspace", "Backspace", "Backspace"],
    ["y", "u", "i", "o", "p", "[", "]", "\\"],
    ["h", "j", "k", "l", ";", "'", "Enter", "Enter"],
    ["n", "m", ",", ".", "/", "Shift", "Shift", "Shift"],
    ["space", "◀", "▶", "Paste", "Paste", "Move", "Move", "Move"],
]
for r in range(5):
    check(f"left half row {r} reads across, cell by cell",
          [osk.key_at(LETTERS, "left", x, CY[r]).label for x in CX], WALK_LEFT[r])
    check(f"right half row {r} reads across, cell by cell",
          [osk.key_at(LETTERS, "right", x, CY[r]).label for x in CX], WALK_RIGHT[r])

# 🔴 The space bar STRADDLES the split, and that is the point: the two-cursor
# model does not need a visual gap, and a key wide enough to cross the boundary
# is reachable by either thumb.
check("space is reachable from the LEFT half",
      osk.key_at(LETTERS, "left", 0.5, 0.9).label, "space")
check("space is reachable from the RIGHT half too",
      osk.key_at(LETTERS, "right", 0.01, 0.9).label, "space")
check("both halves land on the SAME space key object",
      osk.key_at(LETTERS, "left", 0.5, 0.9)
      is osk.key_at(LETTERS, "right", 0.01, 0.9), True)

# Span arithmetic, which is where a hit test actually goes wrong. Equal-width
# column maths passes the walks above and fails every one of these.
check("row 0 right: x=0.62 is the last '=' cell",
      osk.key_at(LETTERS, "right", 0.62, 0.1).label, "=")
check("row 0 right: x=0.63 crosses into Backspace",
      osk.key_at(LETTERS, "right", 0.63, 0.1).label, "Backspace")
check("row 1 left: x=0.37 is the last Tab cell",
      osk.key_at(LETTERS, "left", 0.37, 0.3).label, "Tab")
check("row 1 left: x=0.38 crosses into q",
      osk.key_at(LETTERS, "left", 0.38, 0.3).label, "q")
check("row 3 right: x=0.62 is the last '/' cell",
      osk.key_at(LETTERS, "right", 0.62, 0.7).label, "/")
check("row 3 right: x=0.63 crosses into the right Shift",
      osk.key_at(LETTERS, "right", 0.63, 0.7).label, "Shift")

# Edges. The last row and column own their closing edge, so a cursor pinned to
# the corner of its half lands on a key rather than nothing.
check("x=1.0 lands on the last column, not off the end",
      osk.key_at(LETTERS, "left", 1.0, 0.1).label, "7")
check("y=1.0 lands on the last row, not off the end",
      osk.key_at(LETTERS, "left", 0.0, 1.0).label, "☺")
check("top-left corner of the left half is the backtick key",
      osk.key_at(LETTERS, "left", 0.0, 0.0).label, "`")
check("bottom-right corner of the right half is Move",
      osk.key_at(LETTERS, "right", 1.0, 1.0).label, "Move")
check("x below range misses", osk.key_at(LETTERS, "left", -0.01, 0.5), None)
check("x above range misses", osk.key_at(LETTERS, "left", 1.01, 0.5), None)
check("y below range misses", osk.key_at(LETTERS, "left", 0.5, -0.01), None)
check("y above range misses", osk.key_at(LETTERS, "left", 0.5, 1.01), None)
check("an unknown half raises rather than guessing a side",
      raises(lambda: osk.key_at(LETTERS, "middle", 0.5, 0.5)), True)
check("an unknown half raises even for out-of-range coordinates",
      raises(lambda: osk.key_at(LETTERS, "middle", -5.0, -5.0)), True)
check("an unknown initial layer raises",
      raises(lambda: osk.OnScreenKeyboard("dvorak")), True)

# locate() returns INDICES, not keys: both Shift keys are the same object, so a
# renderer highlighting by identity would light up both at once.
check("the two Shift keys are the same object",
      LETTERS.rows[3][0] is LETTERS.rows[3][-1], True)
check("but they locate to different indices",
      (osk.locate(LETTERS, "left", 0.0, 0.7), osk.locate(LETTERS, "right", 1.0, 0.7)),
      ((3, 0), (3, 11)))


# --- hit-testing in the OTHER metric ------------------------------------------
#
# 🔴 A pixel renderer draws from `unit_bounds` and MUST hit-test from the same
# thing. Drawing units while hit-testing cells lights up a key the cursor's dot
# is not sitting on -- up to half a key away, because Tab is 3/16 of a row in
# cells and 1.03/14.03 of it in units.
#
# The two metrics must agree on WHICH KEYS each thumb can reach and must NOT
# agree on where the boundaries fall inside a half. Both halves of that are
# asserted: the first is the property a user depends on, the second is the
# whole reason the parameter exists.

REACHABLE_LEFT = [
    ["`", "1", "2", "3", "4", "5", "6", "7"],
    ["Tab", "q", "w", "e", "r", "t"],
    ["Caps", "a", "s", "d", "f", "g"],
    ["Shift", "z", "x", "c", "v", "b"],
    ["☺", "space"],
]
REACHABLE_RIGHT = [
    ["8", "9", "0", "-", "=", "Backspace"],
    ["y", "u", "i", "o", "p", "[", "]", "\\"],
    ["h", "j", "k", "l", ";", "'", "Enter"],
    ["n", "m", ",", ".", "/", "Shift"],
    ["space", "◀", "▶", "Paste", "Move"],
]


def sweep(half: str, row: int, metric: str) -> list[str]:
    """Every key a thumb can reach on this row, in order, under this metric.

    Swept at 1/500 of a half rather than sampled at cell centres: a key 0.52
    units wide is narrower than any cell, so a centre-sampling walk would step
    straight over it.
    """
    y = (2 * row + 1) / 10
    seen = []
    for i in range(501):
        label = osk.key_at(LETTERS, half, i / 500, y, metric).label
        if not seen or seen[-1] != label:
            seen.append(label)
    return seen


for r in range(5):
    check(f"row {r}: both metrics reach exactly the same keys from the left pad",
          (sweep("left", r, osk.CELLS), sweep("left", r, osk.UNITS)),
          (REACHABLE_LEFT[r], REACHABLE_LEFT[r]))
    check(f"row {r}: both metrics reach exactly the same keys from the right pad",
          (sweep("right", r, osk.CELLS), sweep("right", r, osk.UNITS)),
          (REACHABLE_RIGHT[r], REACHABLE_RIGHT[r]))

# ...and they place the boundaries differently, which is the point. In cells
# Tab owns the left half's first 3/8; in units it owns 1.03/6.03, so x=0.30 is
# past it. A renderer that mixed the two would be wrong by exactly this much.
check("cells and units disagree inside a half -- x=0.30 on row 1",
      (osk.key_at(LETTERS, "left", 0.30, 0.3, osk.CELLS).label,
       osk.key_at(LETTERS, "left", 0.30, 0.3, osk.UNITS).label),
      ("Tab", "q"))
check("and on row 0, where the backtick key is half a letter wide",
      (osk.key_at(LETTERS, "left", 0.10, 0.1, osk.CELLS).label,
       osk.key_at(LETTERS, "left", 0.10, 0.1, osk.UNITS).label),
      ("`", "1"))

# The closing edge belongs to the LAST key of the half in BOTH metrics -- in
# units that needs its own clamp, because x=1.0 lands exactly on a boundary
# that is also the next key's start.
check("x=1.0 in units lands on the half's last key, not the next half's first",
      (osk.key_at(LETTERS, "left", 1.0, 0.1, osk.UNITS).label,
       osk.key_at(LETTERS, "left", 1.0, 0.3, osk.UNITS).label,
       osk.key_at(LETTERS, "right", 1.0, 1.0, osk.UNITS).label),
      ("7", "t", "Move"))
check("x=0.0 in units lands on the half's first key",
      (osk.key_at(LETTERS, "left", 0.0, 0.1, osk.UNITS).label,
       osk.key_at(LETTERS, "right", 0.0, 0.1, osk.UNITS).label),
      ("`", "8"))
# The space bar straddles the split in cells; `half_units` interpolates that
# split ACROSS the key, so it still straddles in units.
check("space straddles the split in units too",
      (osk.key_at(LETTERS, "left", 1.0, 0.9, osk.UNITS).label,
       osk.key_at(LETTERS, "right", 0.0, 0.9, osk.UNITS).label),
      ("space", "space"))
check("and it is the same object from either side, as in cells",
      osk.key_at(LETTERS, "left", 1.0, 0.9, osk.UNITS)
      is osk.key_at(LETTERS, "right", 0.0, 0.9, osk.UNITS), True)

# 🔴 WHICH KEY OWNS A BOUNDARY. A key owns its LEFT edge and not its right --
# the rule the cell metric gets for free from `int()`, and one the unit metric
# has to state. This is not a limit argument: 50 of this layout's interior
# boundaries sit at an x that is exactly representable, so `x = (boundary -
# start) / reach` round-trips to the boundary itself and a cursor really does
# land there. Off by one key, every time, if the comparison is `<=`.
boundary_owners = []
for r in range(5):
    for half in ("left", "right"):
        lo, hi = LETTERS.half_units(r, half)
        reach = hi - lo
        for i, (_start, end) in enumerate(LETTERS.unit_bounds(r)):
            if not lo < end < hi:
                continue
            x = (end - lo) / reach
            if lo + x * reach != end:
                continue      # not exactly representable; not a real case
            got = osk.locate(LETTERS, half, x, (2 * r + 1) / 10, osk.UNITS)[1]
            boundary_owners.append((r, half, LETTERS.rows[r][i].label, got == i + 1))
check("every exactly-reachable boundary belongs to the key on its RIGHT",
      [b for b in boundary_owners if not b[3]], [])
check("and there are enough of them for that to be worth asserting",
      len(boundary_owners) >= 40, True)

check("half_units meets in the middle: the left half ends where the right begins",
      [LETTERS.half_units(r, "left")[1] == LETTERS.half_units(r, "right")[0]
       for r in range(5)], [True] * 5)
check("half_units spans the whole row, 0 to its own total",
      [(LETTERS.half_units(r, "left")[0],
        abs(LETTERS.half_units(r, "right")[1] - LETTERS.row_units(r)) < 1e-9)
       for r in range(5)], [(0.0, True)] * 5)
check("the split falls INSIDE the space bar on row 4, not on a key boundary",
      LETTERS.unit_bounds(4)[1][0] < LETTERS.half_units(4, "left")[1]
      < LETTERS.unit_bounds(4)[1][1], True)
check("half_units rejects an unknown half rather than guessing a side",
      raises(lambda: LETTERS.half_units(0, "middle")), True)

# An unknown metric must raise. Defaulting to either one silently mis-places
# every hit test in whichever renderer got it wrong.
check("an unknown metric raises rather than picking one",
      raises(lambda: osk.key_at(LETTERS, "left", 0.5, 0.5, "pixels")), True)
check("the default metric is still cells, so no existing caller changed meaning",
      (osk.key_at(LETTERS, "left", 0.30, 0.3).label,
       osk.OnScreenKeyboard().key_at("left", 0.30, 0.3).label),
      ("Tab", "Tab"))
check("OnScreenKeyboard passes the metric through rather than dropping it",
      (osk.OnScreenKeyboard().key_at("left", 0.30, 0.3, osk.UNITS).label,
       osk.OnScreenKeyboard().locate("left", 0.30, 0.3, osk.UNITS)),
      ("q", (1, 1)))
check("an unknown half still raises in the units metric",
      raises(lambda: osk.key_at(LETTERS, "middle", 0.5, 0.5, osk.UNITS)), True)
check("out-of-range coordinates still miss in the units metric",
      [osk.key_at(LETTERS, "left", x, y, osk.UNITS)
       for x, y in ((-0.01, 0.5), (1.01, 0.5), (0.5, -0.01), (0.5, 1.01))],
      [None] * 4)


# --- typing, decoded independently -------------------------------------------

kb = osk.OnScreenKeyboard()
check("pressing q types q", press(kb, "left", CX[3], CY[1]), "q")
check("pressing p types p", press(kb, "right", CX[4], CY[1]), "p")
check("pressing the backtick types a backtick", press(kb, "left", CX[0], CY[0]), "`")
check("space types a space", press(kb, "left", 0.5, CY[4]), " ")
check("Tab emits KEY_TAB",
      kb.press_at("left", CX[0], CY[1]), [(e.KEY_TAB, 1), (e.KEY_TAB, 0)])
check("Backspace emits KEY_BACKSPACE",
      kb.press_at("right", CX[7], CY[0]),
      [(e.KEY_BACKSPACE, 1), (e.KEY_BACKSPACE, 0)])
check("Enter emits KEY_ENTER",
      kb.press_at("right", CX[7], CY[2]), [(e.KEY_ENTER, 1), (e.KEY_ENTER, 0)])
check("a typed key is a full press AND release",
      kb.press_at("left", CX[3], CY[1]), [(e.KEY_Q, 1), (e.KEY_Q, 0)])
check("a miss types nothing", kb.press(None), [])

# Paste is a real key, not a label. Shift+Insert rather than Ctrl+V: it pastes
# in a VTE terminal AND a GTK entry, which is the pair this keyboard is used
# in front of.
kb = osk.OnScreenKeyboard()
check("Paste holds a modifier around its own key",
      kb.press_at("right", CX[3], CY[4]),
      [(e.KEY_LEFTSHIFT, 1), (e.KEY_INSERT, 1), (e.KEY_INSERT, 0),
       (e.KEY_LEFTSHIFT, 0)])
# A one-shot shift armed when Paste is pressed must not press shift twice and
# release it twice -- the consumer would see a stray shift-up mid-sequence.
kb = osk.OnScreenKeyboard()
kb.shift = "once"
check("Paste with a one-shot armed presses its modifier exactly once",
      kb.press_at("right", CX[3], CY[4]),
      [(e.KEY_LEFTSHIFT, 1), (e.KEY_INSERT, 1), (e.KEY_INSERT, 0),
       (e.KEY_LEFTSHIFT, 0)])

# Modifiers are RELEASED IN REVERSE, so the sequence nests rather than
# interleaving. No key in the layout holds two at once, so this is driven
# through the public press() with a key built for it -- the live Paste key
# would report the same strokes either way and prove nothing.
kb = osk.OnScreenKeyboard()
check("several held modifiers nest: pressed in order, released in reverse",
      kb.press(osk.Key(code=e.KEY_V,
                       modifiers=(e.KEY_LEFTCTRL, e.KEY_LEFTALT))),
      [(e.KEY_LEFTCTRL, 1), (e.KEY_LEFTALT, 1),
       (e.KEY_V, 1), (e.KEY_V, 0),
       (e.KEY_LEFTALT, 0), (e.KEY_LEFTCTRL, 0)])

# Emoji: no renderer implements it yet. It is in the reference, so it is in
# the layout; the core records the request and invents no behaviour.
kb = osk.OnScreenKeyboard()
check("the emoji key emits no keystroke", kb.press_at("left", CX[0], CY[4]), [])
check("...it records a request instead", kb.request, "emoji")
check("the emoji key does not close the keyboard", kb.closed, False)

# Move: repurposed to collapse the keyboard (operator decision, 2026-08-12).
# Valve's Move repositions a floating window; ours has no floating window, so
# it is rebound to dismiss instead, through the exact same `closed` flag the
# close action uses -- the signal `deck-input-mapper.py` already reads at 4
# call sites to actually hide the overlay.
kb = osk.OnScreenKeyboard()
check("the Move key emits no keystroke", kb.press_at("right", CX[7], CY[4]), [])
check("...and it collapses the keyboard, exactly like the close action",
      kb.closed, True)
check("Move does NOT also set a renderer request -- nothing reads it, so it "
      "would be dead state (see the module's MOVE_KEY comment)",
      kb.request, "")

# The emoji key's request-recording and Move's close-collapsing must not leak
# into each other or into a fresh instance -- closed and request are per-
# keyboard state, not module-level.
kb_emoji = osk.OnScreenKeyboard()
kb_emoji.press_at("left", CX[0], CY[4])  # emoji
check("pressing emoji on one keyboard leaves it open", kb_emoji.closed, False)
kb_move = osk.OnScreenKeyboard()
kb_move.press_at("right", CX[7], CY[4])  # Move
check("pressing Move on a SEPARATE keyboard instance does not close the "
      "first one too", kb_emoji.closed, False)
check("...and a brand new instance still starts open, unaffected by either",
      osk.OnScreenKeyboard().closed, False)

# The `layer` and `close` actions survive with no key using them, so a future
# layer needs no new mechanism. Driven directly, since nothing in the grid does.
kb = osk.OnScreenKeyboard()
check("the close action still sets the closed flag",
      (kb.press(osk.act("close", "x")), kb.closed), ([], True))
# Move driven directly through the live MOVE_KEY object, not just by
# coordinates -- proves the action code path itself, independent of where the
# key happens to sit in the grid.
kb = osk.OnScreenKeyboard()
check("pressing MOVE_KEY itself sets closed, same as the close action",
      (kb.press(osk.MOVE_KEY), kb.closed), ([], True))
kb = osk.OnScreenKeyboard()
check("the layer action still switches layer",
      (kb.press(osk.act("layer", "x", target="letters")), kb.layer_name),
      ([], "letters"))
check("a layer action naming a layer that does not exist raises",
      raises(lambda: osk.OnScreenKeyboard().press(
          osk.act("layer", "x", target="dvorak"))), True)
check("an action nobody handles raises rather than silently doing nothing",
      raises(lambda: osk.OnScreenKeyboard().press(osk.act("teleport", "x"))), True)


# --- shift: the three states ---------------------------------------------------

SHIFT = ("left", CX[0], CY[3])
CAPS = ("left", CX[0], CY[2])
Q = ("left", CX[3], CY[1])
W = ("left", CX[4], CY[1])
ONE = ("left", CX[1], CY[0])
COMMA = ("right", CX[2], CY[3])

kb = osk.OnScreenKeyboard()
check("the Shift key emits no keystroke of its own", kb.press_at(*SHIFT), [])
check("one tap arms one-shot", kb.shift, "once")
check("one-shot capitalises", press(kb, *Q), "Q")
check("one-shot is spent by the key it modified", kb.shift, "off")
check("the key after it is lowercase again", press(kb, *W), "w")

kb = osk.OnScreenKeyboard()
kb.press_at(*SHIFT)
check("one-shot shifts digits too", press(kb, *ONE), "!")

kb = osk.OnScreenKeyboard()
kb.press_at(*SHIFT)
check("one-shot is spent even by a key with no shifted face",
      (press(kb, "left", 0.5, CY[4]), kb.shift), (" ", "off"))

kb = osk.OnScreenKeyboard()
kb.press_at(*SHIFT)
kb.press_at(*SHIFT)
check("two taps latch shift", kb.shift, "locked")
check("latched shift capitalises letters", press(kb, *Q), "Q")
check("...and does NOT release after one letter", kb.shift, "locked")
check("...and shifts digits too, unlike caps", press(kb, *ONE), "!")
kb.press_at(*SHIFT)
check("a third tap clears it", kb.shift, "off")
check("and letters are lowercase again", press(kb, *Q), "q")

# The right-hand Shift key is the same modifier, not a decoration.
kb = osk.OnScreenKeyboard()
check("the RIGHT Shift key arms shift as well",
      (kb.press_at("right", CX[7], CY[3]), kb.shift), ([], "once"))

# The shift keystroke must WRAP the key, or the modifier is not held when the
# key-down reaches the consumer and the capital silently arrives as lowercase.
kb = osk.OnScreenKeyboard()
kb.press_at(*SHIFT)
check("shift wraps the keystroke",
      kb.press_at(*Q),
      [(e.KEY_LEFTSHIFT, 1), (e.KEY_Q, 1), (e.KEY_Q, 0), (e.KEY_LEFTSHIFT, 0)])
kb = osk.OnScreenKeyboard()
check("unshifted emits no modifier at all", kb.press_at(*Q),
      [(e.KEY_Q, 1), (e.KEY_Q, 0)])


# --- 🔴 CAPS IS NOT SHIFT (T8 §9g, and the part it names as easy to get wrong)
#
# Caps changes LETTER CASE ONLY. Shift changes symbols, case AND the arrow
# keys, and it changes the legends. A renderer that treats them as one dial
# draws the wrong keyboard in one of the two states.

kb = osk.OnScreenKeyboard()
check("the Caps key emits no keystroke of its own", kb.press_at(*CAPS), [])
check("one tap latches caps", kb.caps, True)
check("caps leaves shift alone -- they are two modifiers, not one", kb.shift, "off")
check("caps capitalises letters", press(kb, *Q), "Q")
check("caps does NOT release after one letter", kb.caps, True)
check("caps capitalises the next letter as well", press(kb, *W), "W")
check("🔴 caps leaves DIGITS alone", press(kb, *ONE), "1")
check("🔴 caps leaves PUNCTUATION alone", press(kb, *COMMA), ",")
check("🔴 caps leaves the ARROWS alone",
      press(kb, "right", CX[1], CY[4]), "<KEY_LEFT>")
kb.press_at(*CAPS)
check("a second tap clears caps", kb.caps, False)
check("and letters are lowercase again", press(kb, *Q), "q")

# Both at once. Caps is not consumed by a one-shot, and a one-shot is still
# spent while caps is latched.
kb = osk.OnScreenKeyboard()
kb.press_at(*CAPS)
kb.press_at(*SHIFT)
check("shift and caps are both live at once", (kb.shift, kb.caps), ("once", True))
check("shift wins on a digit while caps is latched", press(kb, *ONE), "!")
check("the one-shot was spent, and caps was not", (kb.shift, kb.caps),
      ("off", True))
check("caps still capitalises after the one-shot went", press(kb, *Q), "Q")


# --- 🔴 ▲/▼ ARE THE SHIFTED FACES OF ◀/▶ (T8 §9g) ---------------------------
#
# Two dual-legend keys, not four keys. Shift is HOW a user reaches up and down,
# so a layout that gave the arrows their own keys would make shift's arrow
# behaviour unreachable.

arrow_keys = [k for _n, _r, _i, k in every_key()
              if k.label in ("◀", "▶", "▲", "▼")]
check("there are exactly TWO arrow keys, not four", len(arrow_keys), 2)
check("their base faces are left and right, in that order",
      [k.label for k in arrow_keys], ["◀", "▶"])
check("▲ and ▼ appear ONLY as shifted faces, never as a key of their own",
      [k.shift_label for k in arrow_keys], ["▲", "▼"])
check("no key anywhere has ▲ or ▼ as its base label",
      [k.label for _n, _r, _i, k in every_key() if k.label in ("▲", "▼")], [])

LEFT_ARROW = ("right", CX[1], CY[4])
RIGHT_ARROW = ("right", CX[2], CY[4])
kb = osk.OnScreenKeyboard()
check("unshifted, the left arrow emits KEY_LEFT",
      kb.press_at(*LEFT_ARROW), [(e.KEY_LEFT, 1), (e.KEY_LEFT, 0)])
kb.press_at(*SHIFT)
check("🔴 shifted, it emits KEY_UP -- a DIFFERENT KEY, not SHIFT+KEY_LEFT",
      kb.press_at(*LEFT_ARROW), [(e.KEY_UP, 1), (e.KEY_UP, 0)])
kb = osk.OnScreenKeyboard()
kb.press_at(*SHIFT)
check("🔴 and the right arrow shifted emits KEY_DOWN, unwrapped",
      kb.press_at(*RIGHT_ARROW), [(e.KEY_DOWN, 1), (e.KEY_DOWN, 0)])
kb = osk.OnScreenKeyboard()
check("unshifted, the right arrow emits KEY_RIGHT",
      kb.press_at(*RIGHT_ARROW), [(e.KEY_RIGHT, 1), (e.KEY_RIGHT, 0)])
check("KEY_UP and KEY_DOWN are declared, or a shifted arrow is silently dead",
      (e.KEY_UP in osk.OSK_KEYCODES, e.KEY_DOWN in osk.OSK_KEYCODES),
      (True, True))
kb = osk.OnScreenKeyboard()
kb.press_at(*SHIFT)
check("a shifted arrow spends the one-shot like any other key",
      (kb.press_at(*LEFT_ARROW) and kb.shift), "off")


# --- 🔴 THE LEGEND RULE (T8 §9g) ---------------------------------------------
#
# | state      | number/punctuation/arrow keys        | letters   |
# | unshifted  | dual: shifted SMALL ABOVE, base big  | lowercase |
# | shift      | ONLY the shifted face, big, centred  | UPPERCASE |
# | caps       | dual, UNCHANGED                      | UPPERCASE |
#
# `face()` is the large legend; `secondary_face()` is the small one above it.

kb = osk.OnScreenKeyboard()
one = osk.key_at(LETTERS, *ONE[0:1], *ONE[1:])
q = osk.key_at(LETTERS, *Q[0:1], *Q[1:])
tab = osk.key_at(LETTERS, "left", CX[0], CY[1])
arrow = osk.key_at(LETTERS, *LEFT_ARROW[0:1], *LEFT_ARROW[1:])

check("unshifted: the big legend of 1 is the digit",
      (kb.face(one), kb.secondary_face(one)), ("1", "!"))
check("unshifted: a letter is lowercase with no second legend",
      (kb.face(q), kb.secondary_face(q)), ("q", ""))
check("unshifted: the arrow shows ◀ with ▲ above it",
      (kb.face(arrow), kb.secondary_face(arrow)), ("◀", "▲"))
check("a key with no shifted face has no second legend",
      (kb.face(tab), kb.secondary_face(tab)), ("Tab", ""))

kb.press_at(*SHIFT)
check("🔴 shift: ONLY the shifted face -- nothing above it",
      (kb.face(one), kb.secondary_face(one)), ("!", ""))
check("shift: letters go uppercase",
      (kb.face(q), kb.secondary_face(q)), ("Q", ""))
check("🔴 shift: the arrow shows ▲ alone",
      (kb.face(arrow), kb.secondary_face(arrow)), ("▲", ""))

kb = osk.OnScreenKeyboard()
kb.press_at(*CAPS)
check("🔴 caps: the digit's legends are UNCHANGED from unshifted",
      (kb.face(one), kb.secondary_face(one)), ("1", "!"))
check("🔴 caps: the arrow's legends are UNCHANGED too",
      (kb.face(arrow), kb.secondary_face(arrow)), ("◀", "▲"))
check("caps: letters go uppercase, and that is the ONLY change",
      (kb.face(q), kb.secondary_face(q)), ("Q", ""))

# The whole rule, exhaustively rather than sampled: what changes between
# unshifted and caps must be letters and NOTHING else.
plain = osk.OnScreenKeyboard()
capsed = osk.OnScreenKeyboard()
capsed.caps = True
caps_changed_a_non_letter = [
    (k.label, plain.face(k), capsed.face(k))
    for _n, _r, _i, k in every_key()
    if not k.is_letter
    and (plain.face(k), plain.secondary_face(k))
    != (capsed.face(k), capsed.secondary_face(k))
]
check("🔴 caps changes the face of NOTHING that is not a letter",
      caps_changed_a_non_letter, [])
caps_missed_a_letter = [
    k.label for _n, _r, _i, k in every_key()
    if k.is_letter and capsed.face(k) != k.label.upper()
]
check("...and caps uppercases EVERY letter", caps_missed_a_letter, [])

# Under shift, no key anywhere draws a second legend.
for state in ("once", "locked"):
    shifted_probe = osk.OnScreenKeyboard()
    shifted_probe.shift = state
    check(f"🔴 shift={state}: not one key in the grid draws a second legend",
          [k.label for _n, _r, _i, k in every_key()
           if shifted_probe.secondary_face(k)], [])

# Unshifted and caps, the second legend is present on exactly the dual-legend
# non-letter keys and nowhere else.
for probe, name in ((osk.OnScreenKeyboard(), "unshifted"), (capsed, "caps")):
    wrong = [(k.label, probe.secondary_face(k))
             for _n, _r, _i, k in every_key()
             if bool(probe.secondary_face(k))
             != (bool(k.shift_label) and not k.is_letter)]
    check(f"{name}: a second legend appears iff the key is a non-letter with "
          f"a shifted face", wrong, [])
    wrong_text = [(k.label, probe.secondary_face(k))
                  for _n, _r, _i, k in every_key()
                  if probe.secondary_face(k)
                  and probe.secondary_face(k) != k.shift_label]
    check(f"{name}: the second legend is always the SHIFTED face, never the "
          f"base one", wrong_text, [])

# Every printable key's face must match what pressing it types, in every state.
# This is the property that keeps the rendered keyboard honest.
face_mismatches = []
for shift_state in ("off", "once", "locked"):
    for caps_state in (False, True):
        for _name, _r, _i, key in every_key():
            if not key.types or len(key.label) != 1:
                continue
            if key.code not in set(PUNCT_FACE) | set(LETTER_FACE):
                continue
            probe = osk.OnScreenKeyboard()
            probe.shift = shift_state
            probe.caps = caps_state
            shown = probe.face(key)
            typed = decode(probe.press(key))
            if shown != typed:
                face_mismatches.append((shift_state, caps_state, shown, typed))
check("every printable key types exactly the face it shows, in all six states",
      face_mismatches, [])


# --- modifier_state(): the blue key, and the TTY's only way to say it ---------

kb = osk.OnScreenKeyboard()
shift_key = LETTERS.rows[3][0]
caps_key = LETTERS.rows[2][0]
right_shift = LETTERS.rows[3][-1]
check("nothing is an active modifier at rest",
      [kb.modifier_state(k) for k in (shift_key, caps_key, q, one)],
      ["", "", "", ""])
check("the Shift key keeps its label in every state, and does not spell its "
      "own state into it", kb.face(shift_key), "Shift")
kb.press_at(*SHIFT)
check("one-shot shift makes BOTH Shift keys active",
      (kb.modifier_state(shift_key), kb.modifier_state(right_shift)),
      ("once", "once"))
check("...and does not make Caps active", kb.modifier_state(caps_key), "")
kb.press_at(*SHIFT)
check("a latched shift is reported as a DIFFERENT state from a one-shot",
      kb.modifier_state(shift_key), "locked")
kb = osk.OnScreenKeyboard()
kb.press_at(*CAPS)
check("latched caps makes the Caps key active",
      kb.modifier_state(caps_key), "on")
check("...and leaves the Shift keys alone",
      kb.modifier_state(shift_key), "")
check("a letter is never an active modifier, whatever is latched",
      kb.modifier_state(q), "")


# --- badges: every one must be TRUE of the mapper's real binding -------------
#
# T8 §9a: a badge naming a button that does something else is CONFIDENTLY
# WRONG, which is worse than no badge. The operator's 2026-08-12 decision fixed
# the bindings, so these five are now all honest. Written out longhand from
# §9g rather than read back out of the module.

BADGE_TYPES = {          # badge -> the keycode its key must emit
    "X": e.KEY_BACKSPACE,
    "Y": e.KEY_SPACE,
    "R2": e.KEY_ENTER,
}
BADGE_ACTS = {           # badge -> the action its key must perform
    "L2": "shift",
    "L3": "caps",
}
BADGE_SHAPES = {         # face buttons are circles; triggers/sticks are rects
    "X": "circle", "Y": "circle",
    "L2": "rect", "R2": "rect", "L3": "rect",
}

check("the module's badge constants are the five §9g draws",
      sorted([osk.HINT_LEFT, osk.HINT_RIGHT, osk.HINT_CAPS, osk.HINT_SPACE,
              osk.HINT_BACKSPACE]),
      sorted(list(BADGE_TYPES) + list(BADGE_ACTS)))

badged = [(k.label, k.hint) for _n, _r, _i, k in every_key() if k.hint]
check("exactly the six §9g keys carry a badge, both Shift keys included",
      sorted(badged),
      sorted([("Backspace", "X"), ("Caps", "L3"), ("Enter", "R2"),
              ("Shift", "L2"), ("Shift", "L2"), ("space", "Y")]))

badge_lies = []
for _name, _r, _i, key in every_key():
    if not key.hint:
        continue
    if key.hint in BADGE_TYPES and key.code != BADGE_TYPES[key.hint]:
        badge_lies.append((key.label, key.hint, "wrong keycode"))
    if key.hint in BADGE_ACTS and key.action != BADGE_ACTS[key.hint]:
        badge_lies.append((key.label, key.hint, "wrong action"))
check("every badge names a button that really does what the key does",
      badge_lies, [])

shape_wrong = [(k.label, k.hint, k.hint_shape)
               for _n, _r, _i, k in every_key()
               if k.hint and k.hint_shape != BADGE_SHAPES[k.hint]]
check("face buttons draw as circles and triggers/sticks as rectangles",
      shape_wrong, [])
check("a key with no badge carries no shape either",
      [k.label for _n, _r, _i, k in every_key()
       if bool(k.hint) != bool(k.hint_shape)], [])
check("the two shapes are distinct strings",
      osk.HINT_SHAPE_CIRCLE != osk.HINT_SHAPE_RECT, True)

# ⚠️ The RIGHT-hand Shift key carries the LEFT trigger's badge, and that is
# correct: L2's idle meaning is Shift wherever the Shift key is drawn. The old
# "a hint must name the trigger for the half it sits in" rule would reject it.
check("the right-hand Shift key carries L2, not R2", right_shift.hint, "L2")


# --- badge gating: per-pad, and only the triggers gate (T8 §9g) ---------------

badge_keys = {k.hint: k for _n, _r, _i, k in every_key() if k.hint}
GATING = {
    # badge: (visible with nothing touched, left touched, right touched)
    "L2": (True, False, True),
    "R2": (True, True, False),
    "X": (True, True, True),
    "Y": (True, True, True),
    "L3": (True, True, True),
}
for badge, (idle, left, right) in GATING.items():
    key = badge_keys[badge]
    check(f"{badge} badge with no pad touched", osk.hint_visible(key, set()), idle)
    check(f"{badge} badge with the LEFT pad touched",
          osk.hint_visible(key, {"left"}), left)
    check(f"{badge} badge with the RIGHT pad touched",
          osk.hint_visible(key, {"right"}), right)
check("both trigger badges vanish when both pads are touched",
      [osk.hint_visible(badge_keys[b], {"left", "right"}) for b in ("L2", "R2")],
      [False, False])
check("a key with no badge is never 'visible'",
      osk.hint_visible(q, set()), False)
check("only the two trigger badges gate at all",
      sorted(osk.HINT_PAD_GATE), ["L2", "R2"])
check("and each gates on its OWN side's pad",
      (osk.HINT_PAD_GATE["L2"], osk.HINT_PAD_GATE["R2"]), ("left", "right"))


# --- is_action_key: the black-versus-dark-grey classification ----------------
#
# 🔴 CORRECTED 2026-08-12 AGAINST `docs/findings/T8-reference-metrics.md` §2,
# which pixel-sampled row 5 TWICE (y=779 and y=750, to rule out a corner
# artifact) and disagrees with §9g's earlier prose list on five keys:
#
#     §9g's prose  black = Tab, Caps, Shift, Backspace, Enter, Move
#     metrics §2   black = Tab, Caps, Shift, Backspace, Enter,
#                          ☺, ◀, ▶, Paste          Move is GREY
#
# Written out longhand from the measurement, and deliberately NOT as a rule:
# metrics §2 states it does not reduce to one, and every rule tried so far
# fails on ☺/Move (same width, same kind of key, opposite colours) or on
# space (grey) versus Paste (black).

BLACK = {"Tab", "Caps", "Shift", "Backspace", "Enter", "☺", "◀", "▶", "Paste"}
GREY = {"space", "Move", "`"}
wrong_colour = [(k.label, osk.is_action_key(k))
                for _n, _r, _i, k in every_key()
                if osk.is_action_key(k) != (k.label in BLACK)]
check("exactly metrics §2's nine keys are drawn as action keys", wrong_colour, [])
check("space is GREY, despite being the widest special key on the board",
      osk.is_action_key(osk.SPACE_KEY), False)
check("Move is GREY -- §9g's prose listed it as black and the pixels disagree",
      osk.is_action_key(osk.MOVE_KEY), False)
check("Paste is BLACK, despite modifying nothing",
      osk.is_action_key(osk.PASTE_KEY), True)
check("the emoji key is BLACK", osk.is_action_key(osk.EMOJI_KEY), True)
check("both arrows are BLACK, unlike every other dual-legend key",
      [osk.is_action_key(k) for k in arrow_keys], [True, True])
check("a letter is never an action key", osk.is_action_key(q), False)
check("a digit is never an action key", osk.is_action_key(one), False)
# ☺ and Move are the same width, sit in the same row and do the same KIND of
# thing (both are renderer requests, `press()` handles them on one line), and
# they are opposite colours. That pair is the standing proof that no predicate
# derives this, so it is asserted rather than left as a comment.
check("☺ and Move are the same kind of key and opposite colours",
      (osk.EMOJI_KEY.units == osk.MOVE_KEY.units,
       osk.is_action_key(osk.EMOJI_KEY), osk.is_action_key(osk.MOVE_KEY)),
      (True, True, False))
check("no key is both black and grey in the transcription", BLACK & GREY, set())


# --- a real Wi-Fi passphrase, end to end --------------------------------------
#
# T8's second "done when" criterion is a mixed-case passphrase with digits and
# symbols typed with no keyboard attached. The renderer and the hardware are the
# other half of that, but the core can prove the layout REACHES every character
# -- which is the part that silently fails if a key was left off the grid. And
# with the symbol layer gone, this is the assertion that says so.

TARGET = "Hunter2!_deck"
kb = osk.OnScreenKeyboard()
script = [
    SHIFT, ("right", CX[0], CY[2]),   # H   shift, then h
    ("right", CX[1], CY[1]),          # u
    ("right", CX[0], CY[3]),          # n
    ("left", CX[7], CY[1]),           # t
    ("left", CX[5], CY[1]),           # e
    ("left", CX[6], CY[1]),           # r
    ("left", CX[2], CY[0]),           # 2
    SHIFT, ("left", CX[1], CY[0]),    # !   shift, then 1
    SHIFT, ("right", CX[3], CY[0]),   # _   shift, then -
    ("left", CX[5], CY[2]),           # d
    ("left", CX[5], CY[1]),           # e
    ("left", CX[5], CY[3]),           # c
    ("right", CX[2], CY[2]),          # k
]
check("a mixed-case passphrase with a digit and two symbols types correctly",
      "".join(press(kb, *p) for p in script), TARGET)
check("with no shift left latched", kb.shift, "off")
check("and no caps latched either", kb.caps, False)

# Every character a WPA2 passphrase may contain (printable ASCII) must exist
# somewhere in the layout, or that passphrase cannot be entered at all. There
# is only ONE layer now, so this is the assertion that the number row's
# thirteen dual-legend keys really do replace the symbol layer.
reachable = set()
for _n, _r, _i, key in every_key():
    if key.label:
        reachable.add(key.label)
    if key.shift_label:
        reachable.add(key.shift_label)
printable = set(string.ascii_letters + string.digits + string.punctuation)
check("every printable ASCII character is reachable on the ONE layer",
      sorted(printable - reachable - {" "}), [])


# --- OSK_KEYCODES: the set the uinput device must declare ---------------------
#
# ⚠️ A uinput device emits only what it declared at creation; an undeclared code
# is dropped by the kernel silently. If this set misses a key, that key is dead
# on the Deck and nothing anywhere reports it.

from_tables = set()
for _n, _r, _i, key in every_key():
    if key.code:
        from_tables.add(key.code)
    if key.shift_code:
        from_tables.add(key.shift_code)
    from_tables |= set(key.modifiers)
check("OSK_KEYCODES covers every code in the layout",
      sorted(from_tables - osk.OSK_KEYCODES), [])
check("OSK_KEYCODES declares the shift modifier it emits",
      e.KEY_LEFTSHIFT in osk.OSK_KEYCODES, True)
check("OSK_KEYCODES contains nothing the layout cannot emit",
      sorted(osk.OSK_KEYCODES - from_tables - {e.KEY_LEFTSHIFT}), [])
check("Paste's own key is declared", e.KEY_INSERT in osk.OSK_KEYCODES, True)

# All three places a key can hide a code, on a layer built to hide one in each.
# The live layout's only modifier is KEY_LEFTSHIFT, which is declared anyway,
# so nothing above would notice the modifier arm being dropped -- and nothing
# did, until this was added.
probe_layer = osk.Layer(
    name="probe", split=1,
    rows=((osk.Key(code=e.KEY_F13),
           osk.Key(code=e.KEY_F14, shift_code=e.KEY_F15),
           osk.Key(code=e.KEY_F16, modifiers=(e.KEY_LEFTMETA, e.KEY_LEFTALT))),),
)
check("keycodes_for collects plain codes, shifted-face codes AND modifiers",
      sorted(osk.keycodes_for([probe_layer])),
      sorted({e.KEY_LEFTSHIFT, e.KEY_F13, e.KEY_F14, e.KEY_F15, e.KEY_F16,
              e.KEY_LEFTMETA, e.KEY_LEFTALT}))
check("OSK_KEYCODES is exactly what keycodes_for says about the real layout",
      osk.OSK_KEYCODES, osk.keycodes_for(osk.LAYERS.values()))
check("the layout really carries all 26 letters",
      len({k.code for _n, _r, _i, k in every_key() if k.is_letter}), 26)


# --- ASCII fallbacks, for the console that has no glyph for an arrow ---------

check("the arrows have an ASCII fallback",
      [osk.ascii_face(c) for c in ("◀", "▶", "▲", "▼")], ["<", ">", "^", "v"])
check("so does the emoji key", osk.ascii_face("☺"), ":)")
check("an ordinary face passes through untouched", osk.ascii_face("q"), "q")
check("every non-ASCII face in the layout has a fallback",
      sorted({t for _n, _r, _i, k in every_key()
              for t in (k.label, k.shift_label)
              if t and not t.isascii() and osk.ascii_face(t) == t}), [])
check("and every fallback is ASCII",
      sorted(v for v in osk.ASCII_FALLBACK.values() if not v.isascii()), [])


# --- strokes_for_text: the renderer-free emission path -----------------------
#
# Round-tripped through the INDEPENDENT decoder above, so this asserts the
# layout types what was asked for, not that it agrees with itself.

check("a plain word round-trips", decode(osk.strokes_for_text("deck")), "deck")
check("mixed case round-trips", decode(osk.strokes_for_text("DeckOS")), "DeckOS")
check("digits and symbols round-trip",
      decode(osk.strokes_for_text("a1!_~|?")), "a1!_~|?")
check("a space round-trips", decode(osk.strokes_for_text("a b")), "a b")

ALL_PRINTABLE = string.ascii_letters + string.digits + string.punctuation + " "
check("every printable ASCII character round-trips",
      decode(osk.strokes_for_text(ALL_PRINTABLE)), ALL_PRINTABLE)

check("shift wraps only the character that needs it",
      osk.strokes_for_text("aA"),
      [(e.KEY_A, 1), (e.KEY_A, 0),
       (e.KEY_LEFTSHIFT, 1), (e.KEY_A, 1), (e.KEY_A, 0), (e.KEY_LEFTSHIFT, 0)])
check("an unreachable character raises rather than being skipped",
      raises(lambda: osk.strokes_for_text("é")), True)
check("empty text emits nothing", osk.strokes_for_text(""), [])

check("find_face prefers the unshifted face", osk.find_face(","), (e.KEY_COMMA, False))
check("find_face returns the shifted face when that is the only one",
      osk.find_face("<"), (e.KEY_COMMA, True))
check("find_face misses cleanly", osk.find_face("€"), None)
# An arrow's shifted face is a different KEY, so find_face must report it
# unshifted -- reporting (KEY_LEFT, True) would emit "extend selection left".
check("find_face reports a shifted-to-another-key face with no modifier",
      osk.find_face("▲"), (e.KEY_UP, False))
# Paste holds a modifier this signature cannot carry, so it is skipped rather
# than reported as a plain KEY_INSERT.
check("find_face refuses a key that needs extra modifiers",
      osk.find_face("Paste"), None)


# --- two cursors, one per trackpad (step 3) ----------------------------------
#
# ⚠️ T8's first named failure mode, and the one that actually happened: session
# 17's pointer emitted NOTHING on diagonal movement while every single-axis test
# passed, because each axis wiped the other's state. Every gesture below that
# can move two axes moves them TOGETHER.

cur = osk.Cursors()
check("both cursors start centred",
      (cur.position("left"), cur.position("right")), ((0.5, 0.5), (0.5, 0.5)))
check("an unknown half is rejected", raises(lambda: cur.position("middle")), True)

MIN, MAX = osk.PAD_RANGE

# X maps left-to-right; Y is INVERTED, because the pad's Y grows upward and
# every screen coordinate grows downward.
cur = osk.Cursors()
check("left pad at min X puts the left cursor at the left edge",
      (cur.update(e.ABS_HAT0X, MIN), cur.position("left")[0]), ("left", 0.0))
check("left pad at max X puts it at the right edge",
      (cur.update(e.ABS_HAT0X, MAX), cur.position("left")[0]), ("left", 1.0))
check("left pad at max Y puts it at the TOP (y is inverted)",
      (cur.update(e.ABS_HAT0Y, MAX), cur.position("left")[1]), ("left", 0.0))
check("left pad at min Y puts it at the BOTTOM",
      (cur.update(e.ABS_HAT0Y, MIN), cur.position("left")[1]), ("left", 1.0))

# --- the two cursors are INDEPENDENT ------------------------------------------
#
# This is the claim T8 exists for: Wayland gives one pointer per seat, so if
# these ever share state there is no dual-cursor keyboard.

cur = osk.Cursors()
cur.update(e.ABS_HAT0X, MIN)
cur.update(e.ABS_HAT0Y, MIN)
check("driving the LEFT pad leaves the right cursor untouched",
      cur.position("right"), (0.5, 0.5))
check("and the left cursor moved", cur.position("left"), (0.0, 1.0))
cur.update(e.ABS_HAT1X, MAX)
cur.update(e.ABS_HAT1Y, MAX)
check("driving the RIGHT pad leaves the left cursor where it was",
      cur.position("left"), (0.0, 1.0))
check("and the right cursor moved to the opposite corner",
      cur.position("right"), (1.0, 0.0))
check("the right pad reports as the right half", cur.update(e.ABS_HAT1X, 100), "right")
check("an axis that is not a pad moves nothing", cur.update(e.ABS_X, 30000), None)

# --- DIAGONAL: both axes moving together --------------------------------------

cur = osk.Cursors()
diagonal = []
for step in range(1, 5):
    vx = MIN + (MAX - MIN) * step // 5
    vy = MIN + (MAX - MIN) * step // 5
    cur.update(e.ABS_HAT1X, vx)
    cur.update(e.ABS_HAT1Y, vy)
    diagonal.append(cur.position("right"))
check("a diagonal stroke moves BOTH axes on every sample",
      all(a[0] != b[0] and a[1] != b[1] for a, b in zip(diagonal, diagonal[1:])), True)
check("x increases along the stroke",
      [round(p[0], 3) for p in diagonal] == sorted(round(p[0], 3) for p in diagonal), True)
check("y decreases along the stroke (inverted axis)",
      [round(p[1], 3) for p in diagonal] == sorted((round(p[1], 3) for p in diagonal),
                                                   reverse=True), True)

# --- the lift: exactly 0 is NO READING, not the centre ------------------------

cur = osk.Cursors()
cur.update(e.ABS_HAT1X, MAX)
cur.update(e.ABS_HAT1Y, MAX)
before = cur.position("right")
check("a lift reports no movement on X", cur.update(e.ABS_HAT1X, 0), None)
check("a lift reports no movement on Y", cur.update(e.ABS_HAT1Y, 0), None)
check("and the cursor HOLDS instead of snapping to the centre",
      cur.position("right"), before)
check("the lift did not disturb the other cursor either",
      cur.position("left"), (0.5, 0.5))

cur = osk.Cursors()
cur.update(e.ABS_HAT0X, MIN)
cur.update(e.ABS_HAT0Y, MAX)
cur.update(e.ABS_HAT0Y, 0)      # crossed the centre line vertically
cur.update(e.ABS_HAT0X, MAX)    # ...while still moving horizontally
check("a zero on one axis holds only that axis, and the other keeps moving",
      cur.position("left"), (1.0, 0.0))

# --- ranges: the device's own absinfo wins, and the edges are safe ------------

cur = osk.Cursors(ranges={e.ABS_HAT0X: (0, 1000)})
cur.update(e.ABS_HAT0X, 1000)
# The advertised maximum is the cursor's maximum. Under the DEFAULT range the
# same value is a hair past centre, so this fails loudly if the range is ignored.
check("a device-supplied range is used instead of the default",
      cur.position("left")[0], 1.0)
cur.update(e.ABS_HAT0X, 500)
check("...and its own midpoint is still the middle of the half",
      cur.position("left")[0], 0.5)
cur.update(e.ABS_HAT0X, 5000)
check("a value beyond the advertised range clamps rather than escaping the half",
      cur.position("left")[0], 1.0)
cur.update(e.ABS_HAT0X, -5000)
check("and clamps at the low end too", cur.position("left")[0], 0.0)

cur = osk.Cursors(ranges={e.ABS_HAT1X: (7, 7)})
check("a degenerate range reports nothing rather than dividing by zero",
      cur.update(e.ABS_HAT1X, 7), None)
check("and leaves the cursor alone", cur.position("right"), (0.5, 0.5))


# --- 🔴 THE PAD INSET: the rim is not needed to reach the outer keys ----------
#
# Operator, on the installed Deck, 2026-08-16:
#
#     "the trackpad mapping [is] too insensitive... to type the t for example I
#      have to move my left thumb all the way to the edge of the trackpad to
#      highlight. And then at that edge it's kind of hard to press the thumb."
#
# The pad's full travel used to map onto the full keyboard, so the outermost
# column demanded the outermost rim -- least reach, least leverage, and the
# hardest place to squeeze L2/R2 to commit. An INSET region of the pad now
# covers the whole keyboard instead.
#
# ⚠️ FEEL CANNOT BE TESTED HERE. Whether 0.12 is the right amount is a question
# only a thumb on hardware answers. What IS testable, and is what these assert,
# is that the transform cannot be wrong in the ways that would matter: the
# extremes stay reachable, it is monotonic, it stays clamped to 0..1, and the
# centre is still the centre.
#
# ⚠️ The margin is written out LONGHAND below rather than imported, like every
# other expectation in this file. Retuning is therefore a deliberate two-file
# edit: change `PAD_EDGE_MARGIN` in the module and `MARGIN` here, together.

MARGIN = 0.12          # must equal osk.PAD_EDGE_MARGIN -- asserted immediately


def inset(f: float) -> float:
    """The rule, written out from the module's prose rather than imported."""
    return min(1.0, max(0.0, (f - MARGIN) / (1.0 - 2.0 * MARGIN)))


def at(fraction: float) -> int:
    """The raw axis value `fraction` of the way along the DEFAULT pad range."""
    value = round(MIN + (MAX - MIN) * fraction)
    # ⚠️ Dead centre of this range rounds to exactly 0, which the module treats
    # as a LIFT rather than a reading. One count off is the closest a test can
    # legally sample, and it is 0.0015% of the axis.
    return value if value else -1


check("the shipped inset is the one this file was written against -- change "
      "BOTH when retuning", osk.PAD_EDGE_MARGIN, MARGIN)
check("the margin leaves a usable pad: strictly inside [0, 0.5)",
      0.0 <= osk.PAD_EDGE_MARGIN < 0.5, True)
check("the active span is derived, so the two cannot drift",
      round(osk.PAD_ACTIVE_SPAN, 12),
      round(1.0 - 2.0 * osk.PAD_EDGE_MARGIN, 12))
check("...and it is a real span, not a collapsed point",
      osk.PAD_ACTIVE_SPAN > 0.0, True)

# 🔴 INVARIANT 1: THE EXTREMES ARE STILL REACHABLE. A fix that put the last
# column out of reach would be worse than the complaint it answers. All four
# axes, both ends, exactly 0.0 and 1.0 -- no "close enough".
cur = osk.Cursors()
extremes = {}
for code, (half, which) in sorted(osk.PAD_AXES.items()):
    cur.update(code, MIN)
    lo = cur.position(half)[0 if which == "x" else 1]
    cur.update(code, MAX)
    hi = cur.position(half)[0 if which == "x" else 1]
    extremes[(half, which)] = (lo, hi)
check("every axis still reaches BOTH extremes exactly (y inverted)",
      extremes,
      {("left", "x"): (0.0, 1.0), ("left", "y"): (1.0, 0.0),
       ("right", "x"): (0.0, 1.0), ("right", "y"): (1.0, 0.0)})

# ...and the extremes still land on the outermost KEYS, which is what a thumb
# actually cares about. Corners of both halves, in the metric each renderer uses.
kb_edge = osk.OnScreenKeyboard()
cur = osk.Cursors()
cur.update(e.ABS_HAT0X, MIN)
cur.update(e.ABS_HAT0Y, MAX)
check("the left pad's top-left corner still reaches the backtick key",
      kb_edge.key_at("left", *cur.position("left")).label, "`")
cur.update(e.ABS_HAT1X, MAX)
cur.update(e.ABS_HAT1Y, MIN)
check("the right pad's bottom-right corner still reaches Move",
      kb_edge.key_at("right", *cur.position("right")).label, "Move")
check("...in the units metric too, which the Wayland renderer draws from",
      kb_edge.key_at("right", *cur.position("right"), osk.UNITS).label, "Move")

# 🔴 INVARIANT 2: THE COMPLAINT ITSELF. `t` is the LAST cell of the left half on
# row 1, so it used to need 87.5% of the pad's travel. It must now arrive well
# before the rim -- and the old linear mapping must NOT have got there, or this
# asserts nothing.
Y_ROW1 = at(1.0 - (2 * 1 + 1) / 10)      # row 1's centre, in raw pad counts
cur = osk.Cursors()
cur.update(e.ABS_HAT0Y, Y_ROW1)
cur.update(e.ABS_HAT0X, at(0.80))
check("🔴 't' is reachable at 80% of the left pad's travel, not at the rim",
      kb_edge.key_at("left", *cur.position("left")).label, "t")
check("...and the old full-range mapping would still have been on 'r' there",
      osk.key_at(LETTERS, "left", 0.80, 0.30).label, "r")
cur.update(e.ABS_HAT0X, at(1.0 - MARGIN))
check("the last column is fully selected a whole margin short of the edge",
      (round(cur.position("left")[0], 6),
       kb_edge.key_at("left", *cur.position("left")).label), (1.0, "t"))

# Both axes, not just x: the top row must arrive early too.
cur = osk.Cursors()
cur.update(e.ABS_HAT0X, at(0.5))
cur.update(e.ABS_HAT0Y, at(0.75))
check("the top row is reachable at 75% of the pad's upward travel",
      kb_edge.locate("left", *cur.position("left"))[0], 0)
check("...where the old full-range mapping was still on row 1",
      osk.locate(LETTERS, "left", 0.5, 0.25)[0], 1)
cur.update(e.ABS_HAT0Y, at(0.25))
check("and the bottom row likewise, at 25% of it",
      kb_edge.locate("left", *cur.position("left"))[0], 4)

# 🔴 INVARIANT 3: MONOTONIC, AND CLAMPED TO 0..1 THROUGHOUT. A gain applied
# wrongly is most likely to show up as a fold-back or an escape past 1.0, and
# either would put the cursor somewhere the thumb is not.
cur = osk.Cursors()
xs, ys = [], []
for step in range(0, 201):
    raw = at(step / 200)
    cur.update(e.ABS_HAT1X, raw)
    cur.update(e.ABS_HAT1Y, raw)
    px, py = cur.position("right")
    xs.append(px)
    ys.append(py)
check("x never goes backwards across the whole sweep", xs == sorted(xs), True)
check("y never goes forwards -- it is inverted, and stays inverted",
      ys == sorted(ys, reverse=True), True)
check("nothing in the sweep escapes 0..1",
      [v for v in xs + ys if not 0.0 <= v <= 1.0], [])
check("the sweep really does reach both ends, so the above is not vacuous",
      (min(xs), max(xs)), (0.0, 1.0))
check("and it is not a constant -- the middle still moves",
      len({round(v, 4) for v in xs}) > 100, True)

# 🔴 INVARIANT 4: THE CENTRE IS STILL THE CENTRE. The inset is symmetric about
# the middle of the pad, so a thumb resting where it always rested finds the
# cursor where it always was. Checked on a range whose midpoint is NOT zero,
# because zero is the lift value and never reaches the transform.
cur = osk.Cursors(ranges={e.ABS_HAT0X: (0, 1000), e.ABS_HAT0Y: (0, 1000)})
cur.update(e.ABS_HAT0X, 500)
cur.update(e.ABS_HAT0Y, 500)
check("the middle of the pad is still the middle of the half, on both axes",
      cur.position("left"), (0.5, 0.5))
cur = osk.Cursors()
cur.update(e.ABS_HAT1X, -1)   # one count off dead centre, the closest legal read
cur.update(e.ABS_HAT1Y, -1)
check("a hair off dead centre is still within half a key of the middle",
      [round(v, 3) for v in cur.position("right")
       if abs(v - 0.5) > 0.5 / LETTERS.width], [])

# The inset is applied in NORMALISED space, after each axis's own absinfo, so
# two pads advertising DIFFERENT ranges each give up the same PROPORTION of
# their own travel. ⚠️ The two pads' ranges are unverified on this hardware --
# the mapper re-reads absinfo per axis, so this must not assume they agree.
# ⚠️ The second range deliberately avoids putting its quarter point on 0, which
# would be read as a LIFT and silently leave that cursor centred -- this test
# caught itself doing exactly that with (-500, 1500).
cur = osk.Cursors(ranges={e.ABS_HAT0X: (0, 1000), e.ABS_HAT1X: (-600, 1400)})
cur.update(e.ABS_HAT0X, 250)                    # a quarter along a 1000 range
cur.update(e.ABS_HAT1X, -100)                   # a quarter along a 2000 range
check("two pads with DIFFERENT advertised ranges land on the same fraction",
      (round(cur.position("left")[0], 9), round(cur.position("right")[0], 9)),
      (round(inset(0.25), 9), round(inset(0.25), 9)))
check("...and that fraction is the inset one, not the raw quarter",
      round(cur.position("left")[0], 9) != 0.25, True)
cur.update(e.ABS_HAT1X, 1400)   # its OWN advertised maximum, not beyond it
check("the second pad still reaches its own extreme",
      cur.position("right")[0], 1.0)

# Everything inside the outer margin collapses onto the extreme -- deliberately.
# That is the clamp doing its job, and it is the only reason the overshoot the
# inset creates by construction is safe.
cur = osk.Cursors()
folded = []
for f in (1.0 - MARGIN, 1.0 - MARGIN / 2, 1.0):
    cur.update(e.ABS_HAT0X, at(f))
    folded.append(round(cur.position("left")[0], 6))
check("the outer margin is all 'the last column', not an overflow", folded,
      [1.0, 1.0, 1.0])

# The wire protocol carries DISPLAY fractions, already inset. apply_state must
# not put them through the transform a second time -- that would compound on
# every hop between the mapper and the overlay.
kb_wire = osk.OnScreenKeyboard()
cur_wire = osk.Cursors()
osk.apply_state(kb_wire, cur_wire,
                osk.parse_state_line("state letters off 0.25 0.25 0.75 0.75 off"))
check("apply_state does NOT re-apply the inset to an already-inset position",
      (cur_wire.position("left"), cur_wire.position("right")),
      ((0.25, 0.25), (0.75, 0.75)))

# --- triggers commit their own side --------------------------------------------

check("the left trigger belongs to the left half", osk.TRIGGER_HALF[e.BTN_TL2], "left")
check("the right trigger belongs to the right half", osk.TRIGGER_HALF[e.BTN_TR2], "right")
check("exactly two triggers are mapped", len(osk.TRIGGER_HALF), 2)


# --- the state protocol, now carrying caps ------------------------------------

kb = osk.OnScreenKeyboard()
cur = osk.Cursors()
cur.update(e.ABS_HAT0X, MIN)
cur.update(e.ABS_HAT0Y, MAX)
NOTOUCH = {"left": False, "right": False}
check("a formatted line carries caps, then both pad-touch fields",
      osk.format_state_line(kb, cur),
      "state letters off 0.0000 0.0000 0.5000 0.5000 off up up\n")
kb.caps = True
kb.shift = "locked"
check("...and reports both modifiers independently",
      osk.format_state_line(kb, cur),
      "state letters locked 0.0000 0.0000 0.5000 0.5000 on up up\n")
# §9g's gate is PER PAD, so the two fields must move independently -- one
# field for "a pad is touched" would hide both triggers' badges at once,
# which is exactly the behaviour the operator measured as wrong.
check("each pad's touch state is carried separately",
      osk.format_state_line(kb, cur, {"left": True, "right": False}),
      "state letters locked 0.0000 0.0000 0.5000 0.5000 on down up\n")
check("...and the other way round",
      osk.format_state_line(kb, cur, {"left": False, "right": True}),
      "state letters locked 0.0000 0.0000 0.5000 0.5000 on up down\n")

parsed = osk.parse_state_line(
    "state letters once 0.1000 0.2000 0.3000 0.4000 on")
check("a full line parses", parsed,
      {"layer": "letters", "shift": "once", "caps": True,
       "left": (0.1, 0.2), "right": (0.3, 0.4), "touched": NOTOUCH})
check("a SEVEN-field line still parses, with caps off -- an older writer has "
      "no caps state and that is exactly what it means",
      osk.parse_state_line("state letters once 0.1 0.2 0.3 0.4"),
      {"layer": "letters", "shift": "once", "caps": False,
       "left": (0.1, 0.2), "right": (0.3, 0.4), "touched": NOTOUCH})
# ⚠️ THE DEFAULT IS THE SAFE ONE, AND IT IS ASSERTED. An older mapper sends
# no touch fields; "nothing touched" shows every badge. A badge wrongly
# shown is cosmetic; a badge wrongly hidden lies about what the trigger does.
check("a ten-field line carries the pad-touch state through",
      osk.parse_state_line("state letters once 0.1 0.2 0.3 0.4 on down up"),
      {"layer": "letters", "shift": "once", "caps": True,
       "left": (0.1, 0.2), "right": (0.3, 0.4),
       "touched": {"left": True, "right": False}})
check("...and the right pad independently",
      osk.parse_state_line("state letters once 0.1 0.2 0.3 0.4 off up down")["touched"],
      {"left": False, "right": True})
check("a bad touch field is rejected rather than guessed",
      osk.parse_state_line("state letters off 0.1 0.2 0.3 0.4 off down maybe"), None)
check("a NINE-field line (one touch field, not two) is rejected, not half-read",
      osk.parse_state_line("state letters off 0.1 0.2 0.3 0.4 off down"), None)
# The round trip is what actually ships: whatever format_state_line writes,
# parse_state_line must read back identically. A mismatch here is a keyboard
# whose badges disagree with the device, and no single-sided test sees it.
rt = osk.parse_state_line(
    osk.format_state_line(kb, cur, {"left": True, "right": True}).strip())
check("format -> parse round-trips the touch state", rt["touched"],
      {"left": True, "right": True})
check("a bad caps field is rejected rather than guessed",
      osk.parse_state_line("state letters off 0.1 0.2 0.3 0.4 maybe"), None)
check("a bad shift state is rejected",
      osk.parse_state_line("state letters sideways 0.1 0.2 0.3 0.4 off"), None)
check("an unknown layer is rejected",
      osk.parse_state_line("state dvorak off 0.1 0.2 0.3 0.4 off"), None)
check("a non-numeric coordinate is rejected",
      osk.parse_state_line("state letters off x 0.2 0.3 0.4 off"), None)
check("an out-of-range coordinate is rejected",
      osk.parse_state_line("state letters off 1.5 0.2 0.3 0.4 off"), None)
check("a line that is not a state line is rejected",
      osk.parse_state_line("hello letters off 0.1 0.2 0.3 0.4 off"), None)
check("a nine-field line is rejected",
      osk.parse_state_line("state letters off 0.1 0.2 0.3 0.4 off extra"), None)
check("an empty line is rejected", osk.parse_state_line(""), None)

# Round trip: what the mapper writes is what a renderer reconstructs.
writer = osk.OnScreenKeyboard()
writer.caps = True
writer.shift = "once"
wcur = osk.Cursors()
wcur.update(e.ABS_HAT1X, MAX)
reader = osk.OnScreenKeyboard()
rcur = osk.Cursors()
osk.apply_state(reader, rcur, osk.parse_state_line(
    osk.format_state_line(writer, wcur)))
check("a state line round-trips shift, caps and both cursors",
      (reader.shift, reader.caps, rcur.position("left"), rcur.position("right")),
      (writer.shift, writer.caps, wcur.position("left"), wcur.position("right")))
# apply_state must not leave a stale caps behind when the writer clears it.
reader.caps = True
osk.apply_state(reader, rcur, osk.parse_state_line(
    "state letters off 0.1 0.2 0.3 0.4 off"))
check("apply_state CLEARS caps when the line says off", reader.caps, False)


# --- the whole chain: pad -> cursor -> hit test -> keystroke ------------------
#
# Each piece above is tested alone; this is the one assertion that fails if the
# SEAMS are wrong -- an inverted axis, a half swapped, a range misread.

kb = osk.OnScreenKeyboard()
cur = osk.Cursors()
cur.update(e.ABS_HAT1X, MIN)   # right pad, far left...
cur.update(e.ABS_HAT1Y, MAX)   # ...and top
x, y = cur.position("right")
check("top-left of the right pad lands on the right half's first number key",
      kb.key_at("right", x, y).label, "8")

cur.update(e.ABS_HAT1X, MAX)   # far right, still top
x, y = cur.position("right")
check("top-right of the right pad lands on Backspace",
      kb.key_at("right", x, y).label, "Backspace")

cur.update(e.ABS_HAT0X, MIN)   # left pad, bottom-left: the emoji key
cur.update(e.ABS_HAT0Y, MIN)
x, y = cur.position("left")
check("bottom-left of the left pad lands on the emoji key",
      kb.key_at("left", x, y).label, "☺")

cur.update(e.ABS_HAT0X, MIN)   # left pad, far left, row 4: Shift
cur.update(e.ABS_HAT0Y, MIN + (MAX - MIN) * 3 // 10)
x, y = cur.position("left")
check("the left pad reaches Shift", kb.key_at("left", x, y).label, "Shift")
check("and pressing there arms one-shot shift rather than typing",
      (kb.press_at("left", x, y), kb.shift), ([], "once"))

cur.update(e.ABS_HAT1X, -1)  # right pad, a hair off centre (0 would be a lift)
cur.update(e.ABS_HAT1Y, -1)
x, y = cur.position("right")
# ⚠️ Read the face BEFORE pressing. The shift armed just above is a ONE-SHOT:
# pressing spends it, so a face read afterwards describes the next press, not
# the one that just happened.
expected_face = kb.face(kb.key_at("right", x, y))
check("a press at the centre of the right pad types the key drawn there",
      decode(kb.press_at("right", x, y)), expected_face)
check("and the one-shot shift is spent by it", kb.shift, "off")

print()
print(f"{'PASS' if FAILURES == 0 else 'FAIL'} — {FAILURES} failure(s)")
sys.exit(1 if FAILURES else 0)
