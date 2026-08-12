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

# Two keys no renderer implements yet. They are in the reference, so they are
# in the layout; the core records the request and invents no behaviour.
kb = osk.OnScreenKeyboard()
check("the emoji key emits no keystroke", kb.press_at("left", CX[0], CY[4]), [])
check("...it records a request instead", kb.request, "emoji")
check("the Move key emits no keystroke", kb.press_at("right", CX[7], CY[4]), [])
check("...and records its own request", kb.request, "move")
check("neither of them closed the keyboard", kb.closed, False)

# The `layer` and `close` actions survive with no key using them, so a future
# layer needs no new mechanism. Driven directly, since nothing in the grid does.
kb = osk.OnScreenKeyboard()
check("the close action still sets the closed flag",
      (kb.press(osk.act("close", "x")), kb.closed), ([], True))
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


# --- is_action_key: T8 §9g's black-versus-dark-grey classification -----------
#
# §9g names exactly six: Tab, Caps, Shift, Backspace, Enter, Move. Space,
# Paste, the emoji key and the arrows are NOT in that list. Written out
# longhand, because the plausible RULE ("not a letter, no shifted face")
# disagrees with the measurement on four keys.

BLACK = {"Tab", "Caps", "Shift", "Backspace", "Enter", "Move"}
wrong_colour = [(k.label, osk.is_action_key(k))
                for _n, _r, _i, k in every_key()
                if osk.is_action_key(k) != (k.label in BLACK)]
check("exactly §9g's six keys are drawn as action keys", wrong_colour, [])
check("space is NOT an action key -- §9g does not list it",
      osk.is_action_key(osk.SPACE_KEY), False)
check("Paste is NOT an action key either", osk.is_action_key(osk.PASTE_KEY), False)
check("the arrows are NOT action keys",
      [osk.is_action_key(k) for k in arrow_keys], [False, False])
check("a letter is never an action key", osk.is_action_key(q), False)
check("a digit is never an action key", osk.is_action_key(one), False)


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
cur.update(e.ABS_HAT0X, 250)
check("a device-supplied range is used instead of the default",
      cur.position("left")[0], 0.25)
cur.update(e.ABS_HAT0X, 5000)
check("a value beyond the advertised range clamps rather than escaping the half",
      cur.position("left")[0], 1.0)
cur.update(e.ABS_HAT0X, -5000)
check("and clamps at the low end too", cur.position("left")[0], 0.0)

cur = osk.Cursors(ranges={e.ABS_HAT1X: (7, 7)})
check("a degenerate range reports nothing rather than dividing by zero",
      cur.update(e.ABS_HAT1X, 7), None)
check("and leaves the cursor alone", cur.position("right"), (0.5, 0.5))

# --- triggers commit their own side --------------------------------------------

check("the left trigger belongs to the left half", osk.TRIGGER_HALF[e.BTN_TL2], "left")
check("the right trigger belongs to the right half", osk.TRIGGER_HALF[e.BTN_TR2], "right")
check("exactly two triggers are mapped", len(osk.TRIGGER_HALF), 2)


# --- the state protocol, now carrying caps ------------------------------------

kb = osk.OnScreenKeyboard()
cur = osk.Cursors()
cur.update(e.ABS_HAT0X, MIN)
cur.update(e.ABS_HAT0Y, MAX)
check("a formatted line carries caps as an eighth field",
      osk.format_state_line(kb, cur),
      "state letters off 0.0000 0.0000 0.5000 0.5000 off\n")
kb.caps = True
kb.shift = "locked"
check("...and reports both modifiers independently",
      osk.format_state_line(kb, cur),
      "state letters locked 0.0000 0.0000 0.5000 0.5000 on\n")

parsed = osk.parse_state_line(
    "state letters once 0.1000 0.2000 0.3000 0.4000 on")
check("a full line parses", parsed,
      {"layer": "letters", "shift": "once", "caps": True,
       "left": (0.1, 0.2), "right": (0.3, 0.4)})
check("a SEVEN-field line still parses, with caps off -- an older writer has "
      "no caps state and that is exactly what it means",
      osk.parse_state_line("state letters once 0.1 0.2 0.3 0.4"),
      {"layer": "letters", "shift": "once", "caps": False,
       "left": (0.1, 0.2), "right": (0.3, 0.4)})
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
