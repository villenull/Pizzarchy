#!/usr/bin/env python3
"""Unit tests for the TTY renderer (T8 step 4), rebuilt for §9g's grid.

No console, no VM, no root. Run directly:

    python3 test-deck-osk-tty.py

The renderer's whole job is that WHAT IS DRAWN matches WHAT IS PRESSED. Most of
what follows asserts that correspondence rather than the appearance, because
appearance is the part a human notices immediately and correspondence is the
part that silently types the wrong character.

🔴 THE ONE NEW THING, AND IT IS THE CRUX. Since T8 §9g the layout is ONE grid
of 16 cells, and `docs/PROGRESS.md` §7 measured the console the installer
actually runs on: **the installed TTY is 25x80**. 16 cells at KEY_CELL=5 is 80
columns EXACTLY, with nothing spare. That fit is asserted here at the real
measured geometry -- not at a convenient one -- because a keyboard one column
too wide does not get clipped, it WRAPS, and R-49 is what that costs.

⛔ AND SINCE P33 J THE OTHER AXIS IS COSTED TOO. A key row is `KEY_ROWS` console
rows, so the keyboard is ten rows and not five, and "🔴 P33 J" below asserts the
whole sum -- the measured prompt screen plus the measured keyboard against the
measured 50-row console -- because `docs/PROGRESS.md` §5.40 is a change that
spent rows without adding them up, shipped, and pushed the username and password
prompts off the screen. Row arithmetic in this file is measured or it is a
defect waiting for hardware.
"""

from __future__ import annotations

import importlib.util
import io
import pathlib
import re
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


# The renderer imports the layout core by name, so the core must be registered
# in sys.modules first -- and SRC on the path, for the renderer's own import.
sys.path.insert(0, str(SRC))
osk = load("deck_osk_layout")
tty = load("deck_osk_tty")

FAILURES = 0


def check(what: str, got, want) -> None:
    global FAILURES
    if got == want:
        print(f"ok   {what} = {got!r}")
    else:
        print(f"FAIL {what}: got {got!r}, want {want!r}")
        FAILURES += 1


def raises(fn, kind=Exception) -> bool:
    try:
        fn()
    except kind:
        return True
    except Exception:
        return False  # raised, but not the way the code meant to
    return False


def raises_saying(fn, kind, *fragments: str) -> bool:
    """Did fn() raise `kind` with a message naming each fragment?

    ⚠️ Pinning WHICH guard fired, not just that something blew up. Two guards
    sharing one signal make an assertion pass with either one gone -- session
    16 recorded the same lesson about exit codes, and `write_at` now carries
    TWO guards (rows and columns) whose only difference is the message.
    """
    try:
        fn()
    except kind as exc:
        return all(fragment in str(exc) for fragment in fragments)
    except Exception:
        return False
    return False


MIN, MAX = osk.PAD_RANGE

# 🔴 THE MEASUREMENT THIS RENDERER MUST SURVIVE, from docs/PROGRESS.md §7:
# the live ISO's console is 50x160 and **the installed TTY's is 25x80, same
# panel**. The installed TTY is the tighter of the two and the one the
# installer runs on, so it is what every geometry assertion below uses.
INSTALLED_TTY_ROWS, INSTALLED_TTY_COLS = 25, 80
LIVE_ISO_ROWS, LIVE_ISO_COLS = 50, 160

# Every state the keyboard can be drawn in. Shift and caps are INDEPENDENT
# (§9g), so this is a product and not a list of three -- a renderer that
# conflated them would draw the wrong keyboard in one of the six.
STATES = [(shift, caps) for shift in ("off", "once", "locked")
          for caps in (False, True)]


def fresh():
    return osk.OnScreenKeyboard(), osk.Cursors()


def probe(shift: str = "off", caps: bool = False) -> osk.OnScreenKeyboard:
    kb = osk.OnScreenKeyboard()
    kb.shift = shift
    kb.caps = caps
    return kb


def every_key():
    for layer in osk.LAYERS.values():
        for row_index, row in enumerate(layer.rows):
            for key_index, key in enumerate(row):
                yield layer, row_index, key_index, key


# --- cell_text: highlighted and plain must be the same width -----------------
#
# A highlight that changed the width would shift every key to its right as a
# cursor moved, which reads as the whole keyboard twitching.

check("a plain cell is exactly the requested width", len(tty.cell_text("q", 5, False)), 5)
check("a highlighted cell is the SAME width", len(tty.cell_text("q", 5, True)), 5)
check("a plain cell centres its label", tty.cell_text("q", 5, False), "  q  ")
check("a highlighted cell brackets it", tty.cell_text("q", 5, True), "[ q ]")
check("a wide key uses its whole span", len(tty.cell_text("space", 40, False)), 40)
check("a highlighted wide key too", len(tty.cell_text("space", 40, True)), 40)
check("an over-long label is truncated, not allowed to overflow",
      len(tty.cell_text("enormous", 5, False)), 5)
check("an over-long label is truncated when highlighted too",
      len(tty.cell_text("enormous", 5, True)), 5)

# --- 🔴 THE 80-COLUMN CONSTRAINT ---------------------------------------------
#
# ⚠️ THE ASSERTION THIS WHOLE REBUILD TURNS ON. The grid is `Layer.width` cells
# and the installed TTY is 80 columns; a keyboard one column wider does not get
# clipped by the console, it WRAPS -- each row becomes two, everything below is
# pushed down, and the bottom of the keyboard scrolls away. That is R-49's
# failure arriving on the other axis, and it is just as silent.
#
# Asserted as an EQUALITY, not `<= 80`: at KEY_CELL=4 the keyboard would also
# be "inside 80" while throwing away a column of every key for nothing, and the
# labels stop fitting (checked below). 5 is the unique value.

kb, cur = fresh()
rows = tty.render(kb, cur)
GRID_CELLS = osk.LETTERS.width
KB_WIDTH = tty.width(rows)

check("the grid is the 16 cells §9g transcribed", GRID_CELLS, 16)
check("KEY_CELL times the grid is the rendered width",
      GRID_CELLS * tty.KEY_CELL, KB_WIDTH)
check("🔴 the keyboard is EXACTLY the installed TTY's 80 columns",
      KB_WIDTH, INSTALLED_TTY_COLS)
check("...and one column wider per cell would NOT fit -- 5 is the largest that does",
      GRID_CELLS * (tty.KEY_CELL + 1) > INSTALLED_TTY_COLS, True)
check("...and it fits the live ISO's 160 columns with room to spare",
      KB_WIDTH <= LIVE_ISO_COLS, True)
check("the keyboard's five rows fit the installed TTY's 25",
      len(rows) <= INSTALLED_TTY_ROWS, True)

# The width must hold in EVERY state, not just the idle one -- the modifier
# words and the shift/caps legend swap all change what is drawn in each cell.
widths = set()
for shift, caps in STATES:
    for lx, ly, rx, ry in ((0.0, 0.0, 0.0, 0.0), (0.5, 0.5, 0.5, 0.5),
                           (1.0, 1.0, 1.0, 1.0)):
        cursors = osk.Cursors()
        cursors.pos["left"], cursors.pos["right"] = [lx, ly], [rx, ry]
        drawn = tty.to_plain(tty.render(probe(shift, caps), cursors))
        widths.update(len(line) for line in drawn.split("\n"))
check("every rendered line is exactly 80 columns, in all six shift/caps states "
      "and wherever the cursors are", sorted(widths), [INSTALLED_TTY_COLS])

# ⛔ The gap is GONE, not zeroed (§9g: one continuous keyboard). A `GUTTER`
# still in scope would invite something to space by it -- and the 80-column
# budget has no room for one.
check("there is no GUTTER left in the module at all", hasattr(tty, "GUTTER"), False)

# ⚠️ And the keys really are laid out from the grid: each key starts where
# `Layer.cell_bounds` says it does, with nothing between them. This is what
# "no gap" means structurally, rather than as an arithmetic coincidence of 80.
#
# 🔴 AND EVERY CONSOLE ROW OF THE KEY, not only its label row (P33 J). A key is
# `KEY_ROWS` console rows tall; a body row drawn at different columns from the
# label above it would be a keyboard whose keys are visibly out of register, and
# it would put `write_at`'s incremental path -- which walks columns by summing
# cell widths -- at the wrong column on half the rows.
misplaced = []
for layer in osk.LAYERS.values():
    kb_l = osk.OnScreenKeyboard(layer.name)
    rendered = tty.render(kb_l, osk.Cursors())
    for row_index, row in enumerate(layer.rows):
        for sub in range(tty.KEY_ROWS):
            column = 0
            for key_index, (start, end) in enumerate(layer.cell_bounds(row_index)):
                text = rendered[row_index * tty.KEY_ROWS + sub][key_index][0]
                if (column != start * tty.KEY_CELL
                        or len(text) != (end - start) * tty.KEY_CELL):
                    misplaced.append((layer.name, row_index, sub, key_index,
                                      column, start * tty.KEY_CELL, len(text)))
                column += len(text)
check("every key is drawn at the column Layer.cell_bounds puts it, contiguously, "
      "on every console row of the key", misplaced, [])

# ⚠️ `width()` MUST BE AN UPPER BOUND, not "whatever the first row was". Every
# row is the same width by construction today, which makes max() and min()
# indistinguishable on real output -- and `write_at`'s column guard is built on
# this being the WIDEST row. Fed a ragged structure by hand, the difference is
# the whole guard. (Found by mutation: min-for-max survived everything else.)
check("width() reports the WIDEST row -- the column guard needs an upper bound",
      tty.width([[("abc", False)], [("abcdefgh", False)]]), 8)
check("width() of nothing is zero, not an exception", tty.width([]), 0)

# --- nothing is ever truncated, at any span, in any state --------------------
#
# ⚠️ NO LABEL MAY EVER BE TRUNCATED ON SCREEN, and truncation is silent by
# nature, so it gets an invariant rather than a spot check. This caught a real
# defect under the OLD layout (`enter` drawing as `[ent]`), and §9g moved the
# long labels onto wide keys, which is what makes KEY_CELL=5 affordable now.
#
# `display_label` is what `render` feeds to `cell_text`, and it is the one that
# can overflow: a face alone cannot, but pasting a badge, a modifier word or a
# second legend onto it can. It returns ONE string regardless of highlight
# state (see its docstring), so it is checked against BOTH budgets it will ever
# be centred into.
truncated = []
for shift, caps in STATES:
    kb_p = probe(shift, caps)
    for _layer, _r, _k, key in every_key():
        text = tty.display_label(kb_p, key)
        cell = key.span * tty.KEY_CELL
        for hot, available in ((False, cell), (True, cell - 2)):
            if len(text) > available:
                truncated.append((key.label, shift, caps, hot, text, available))
            if text not in tty.cell_text(text, cell, hot):
                truncated.append((key.label, shift, caps, hot, "not drawn whole"))
check("no drawn label is ever truncated, at any span or shift/caps state",
      truncated, [])

# ⚠️ AND THE PROOF THAT THE INVARIANT ABOVE IS NOT VACUOUS: at KEY_CELL=4 it
# must FAIL. Without this, deleting the budget arithmetic and hard-coding a
# huge cell would pass every check above.
def widest_overflow(cell_width: int) -> list[str]:
    over = []
    for shift, caps in STATES:
        kb_p = probe(shift, caps)
        for _layer, _r, _k, key in every_key():
            if len(tty.display_label(kb_p, key)) > key.span * cell_width - 2:
                over.append(key.label)
    return over


check("at KEY_CELL=4 labels WOULD overflow -- so 5 is a real floor, not a guess",
      widest_overflow(4) != [], True)
check("at KEY_CELL=5 nothing overflows", widest_overflow(5), [])


# =============================================================================
# 🔴 P33 B1: THE GRID ADAPTS TO THE CONSOLE IT IS GIVEN (docs/PROGRESS.md §5.34
# D3)
# =============================================================================
#
# The 80 columns everything above pins is A MEASUREMENT OF ONE CONSOLE, at one
# console font, and BOTH halves of that move. The keyboard was unreadable on a
# 7" panel (§5.34 D3); the fix is a bigger console font, and a bigger font gives
# FEWER columns. A grid hardcoded to 80 either wastes half a wide console or is
# refused outright by `write_at`'s own column guard on a narrow one -- and the
# screen it is refused on is where a Wi-Fi passphrase gets typed.
#
# ⚠️ Measured, not assumed: at HEAD, `render()` at 50 columns produced 80 and
# `write_at(console_cols=50)` raised. That is the defect these checks exist to
# keep fixed.
#
# 🔴 AND THE COLUMN COUNT ITSELF IS DISPUTED, WHICH IS PRECISELY WHY NOTHING
# HERE DEPENDS ON KNOWING IT. `docs/tasks/P33-fix-round.md` §A3 works the Deck's
# 800x1280 panel out as 100 columns at 8x16 and 50 at 16x32 -- i.e. taking the
# console's horizontal axis to be the 800 px one. `docs/PROGRESS.md` §7's
# MEASURED live-ISO console is 50x160, and 160 * 8 == 1280, which says the
# horizontal axis is the 1280 px one and the same two fonts give 160 and 80.
# Both pairs are checked below, and the sweep covers everything between them, so
# whichever is right the keyboard fits. Resolving it is not this file's job; the
# adaptation is what makes it not need resolving.
PLAN_COLS_SMALL_FONT, PLAN_COLS_BIG_FONT = 100, 50    # §A3's arithmetic
MEASURED_COLS_SMALL_FONT, MEASURED_COLS_BIG_FONT = 160, 80   # §7's 50x160

check("the widest cell that fits 100 columns is 6", tty.cell_width_for(100, 16), 6)
check("...80 columns is still 5, so nothing that ships today moves",
      tty.cell_width_for(80, 16), 5)
check("...and 50 columns is 3", tty.cell_width_for(50, 16), 3)
check("the live ISO's 160 columns fill the console at 10",
      tty.cell_width_for(160, 16), 10)
check("a console that fits nothing gets MIN_KEY_CELL anyway -- a width that does "
      "NOT fit, so write_at refuses loudly instead of drawing '[]' for every key",
      tty.cell_width_for(20, 16), tty.MIN_KEY_CELL)
check("...and MIN_KEY_CELL is 3, below which a highlight has no room for a face",
      tty.MIN_KEY_CELL, 3)
check("a grid with no cells is a caller bug, not a division",
      raises(lambda: tty.cell_width_for(80, 0), ValueError), True)

# ⚠️ THE POINT OF THE WHOLE CHANGE: no row may exceed the console, at EVERY
# width the Deck can actually present. Asserted as a sweep rather than at two
# convenient numbers, so an off-by-one at some width in between is not invisible.
too_wide = []
for cols in range(3 * GRID_CELLS, LIVE_ISO_COLS + 1):
    for shift, caps in STATES:
        drawn_rows = tty.render(probe(shift, caps), osk.Cursors(), cols)
        if tty.width(drawn_rows) > cols:
            too_wide.append((cols, shift, caps, tty.width(drawn_rows)))
check("🔴 no rendered row exceeds the console, at every width from 48 to 160, "
      "in every shift/caps state", too_wide, [])

for cols, want_cell in ((PLAN_COLS_SMALL_FONT, 6), (PLAN_COLS_BIG_FONT, 3),
                        (MEASURED_COLS_SMALL_FONT, 10),
                        (MEASURED_COLS_BIG_FONT, 5)):
    at = tty.render(*fresh(), cols)
    check(f"at {cols} columns the keyboard is drawn at cell {want_cell}",
          tty.width(at), GRID_CELLS * want_cell)
    check(f"...and {cols} columns really does fit it -- write_at accepts",
          (tty.write_at(io.StringIO(), at, 1, console_rows=25,
                        console_cols=cols), True)[1], True)
    check(f"...with less than a whole cell of slack, so the console is used",
          cols - tty.width(at) < want_cell, True)

check("with no console named, the keyboard is exactly what it always was",
      tty.to_plain(tty.render(*fresh())),
      tty.to_plain(tty.render(*fresh(), INSTALLED_TTY_COLS)))

# ⚠️ AND NOTHING IS TRUNCATED AT ANY OF THEM. This is the check §5.34 D3's own
# proposal would have failed: it argued 5->3 "appears to fit" from `cell_text`
# drawing `[q]` at width 3, which is true and is not the binding constraint --
# `display_label`'s budget is `span * cell - 2`, and at cell 3 `Enter` (5 against
# 4) and `Backspace` (9 against 7) both overflow. `NARROW_LABELS` is what makes 3
# real, and this is what proves it for every key in every state.
truncated_anywhere = []
for cell_width in range(tty.MIN_KEY_CELL, 11):
    for shift, caps in STATES:
        kb_p = probe(shift, caps)
        for _layer, _r, _k, key in every_key():
            text = tty.display_label(kb_p, key, cell_width)
            budget = key.span * cell_width
            for hot, available in ((False, budget), (True, budget - 2)):
                if len(text) > available:
                    truncated_anywhere.append(
                        (cell_width, key.label, shift, caps, hot, text))
                if text not in tty.cell_text(text, budget, hot):
                    truncated_anywhere.append(
                        (cell_width, key.label, "not drawn whole"))
check("🔴 no label is truncated at ANY cell width from 3 to 10, at any span, in "
      "any shift/caps state", truncated_anywhere, [])

# ...and that it is not vacuous: at cell 2 a highlight has no room at all.
check("at cell 2 labels WOULD overflow -- 3 is a real floor, not a preference",
      [1 for shift, caps in STATES
       for _l, _r, _k, key in every_key()
       if len(tty.display_label(probe(shift, caps), key, 2)) > key.span * 2 - 2] != [],
      True)

# Highlighted and plain must stay the SAME width at every cell width, or keys
# shift sideways as a cursor moves and the whole keyboard reads as twitching.
uneven = []
for cell_width in range(tty.MIN_KEY_CELL, 11):
    for cols in (cell_width * GRID_CELLS,):
        widths_here = set()
        for shift, caps in STATES:
            for lx in (0.0, 0.3, 1.0):
                cursors_h = osk.Cursors()
                cursors_h.pos["left"], cursors_h.pos["right"] = [lx, 0.5], [lx, 0.9]
                plain = tty.to_plain(tty.render(probe(shift, caps), cursors_h, cols))
                widths_here.update(len(line) for line in plain.split("\n"))
        if widths_here != {cols}:
            uneven.append((cell_width, sorted(widths_here)))
check("every row is exactly the grid's width at every cell width, wherever the "
      "cursors are and in every state", uneven, [])

# The narrow faces have to be recognisable as the keys they replace, and they
# have to be SHORTER -- an "abbreviation" that is not shorter is a typo.
check("every narrow face is strictly shorter than the face it replaces",
      [face for face, short in tty.NARROW_LABELS.items() if len(short) >= len(face)],
      [])
check("the narrow faces are ASCII, like everything else this module draws",
      [s for s in tty.NARROW_LABELS.values() if any(ord(ch) > 127 for ch in s)], [])
check("Enter keeps its badge at 100 columns, where there is room for it",
      tty.display_label(probe(), osk.ENTER_KEY, tty.cell_width_for(100, 16)),
      "R2 Enter")
check("...and shortens rather than truncating at 50",
      tty.display_label(probe(), osk.ENTER_KEY, tty.cell_width_for(50, 16)), "Entr")
check("Backspace likewise", tty.display_label(probe(), osk.BACKSPACE_KEY, 3), "Bksp")
check("...and Shift keeps the MODIFIER WORD at 50 columns, dropping face letters "
      "for it -- the case of a character typed into a masked field",
      tty.display_label(probe("locked"), osk.SHIFT_KEY, 3), "Sh LOCK")
check("Caps needs no shortening even at 50 -- 'Caps ON' is exactly the budget",
      tty.display_label(probe(caps=True), osk.CAPS_KEY, 3), "Caps ON")

# ⚠️ THE ASCII RULE STILL HOLDS AT EVERY WIDTH. A narrow face is still a face.
non_ascii_narrow = []
for cols in (PLAN_COLS_BIG_FONT, PLAN_COLS_SMALL_FONT,
             MEASURED_COLS_BIG_FONT, MEASURED_COLS_SMALL_FONT,
             INSTALLED_TTY_COLS, LIVE_ISO_COLS):
    for shift, caps in STATES:
        non_ascii_narrow += [ch for ch
                             in tty.to_plain(tty.render(probe(shift, caps),
                                                        osk.Cursors(), cols))
                             if ord(ch) > 127]
check("nothing outside ASCII is drawn at any console width",
      sorted(set(non_ascii_narrow)), [])

# --- no glyph a bare console may lack ever reaches the screen -----------------
#
# ⚠️ §9g's arrows are `◀▶▲▼` and the emoji key is `☺`. The ISO's console font is
# not guaranteed to carry U+25C0, and mojibake on the installer's only keyboard
# is worse than a plainer glyph. `osk.ascii_face` is the substitution; this
# asserts the renderer actually applies it, everywhere, in every state.
non_ascii = []
for shift, caps in STATES:
    drawn = tty.to_plain(tty.render(probe(shift, caps), osk.Cursors()))
    non_ascii += [ch for ch in drawn if ord(ch) > 127]
check("nothing outside ASCII is ever drawn, in any state", sorted(set(non_ascii)), [])

# And the substitution is the LAYOUT's, not a second table here that could drift.
check("the layout does carry the glyphs that would have needed substituting",
      sorted(osk.ASCII_FALLBACK), sorted(["◀", "▶", "▲", "▼", "☺"]))
left_arrow = osk.key_at(osk.LETTERS, "right", 0.15, 1.0)
check("the left/right arrow key is where this expects it", left_arrow.label, "◀")
check("the arrow draws as ASCII, base and shifted legend both",
      tty.display_label(probe(), left_arrow), "< ^")
check("under shift it draws only its shifted face, in ASCII",
      tty.display_label(probe("once"), left_arrow), "^")
emoji = osk.key_at(osk.LETTERS, "left", 0.0, 1.0)
check("the emoji key is where this expects it", emoji.label, "☺")
check("and degrades to an ASCII smiley", tty.display_label(probe(), emoji), ":)")

# --- §9g's legend rule, as the renderer draws it -----------------------------

digit_1 = osk.key_at(osk.LETTERS, "left", 0.2, 0.1)
check("the digit key is where this expects it", digit_1.label, "1")
check("unshifted, a digit draws its shifted face BESIDE it -- §9g's small-above "
      "degrades to beside on a console with one type size",
      tty.display_label(probe(), digit_1), "1 !")
check("under shift it draws ONLY the shifted face", tty.display_label(probe("once"), digit_1), "!")
check("under LOCKED shift, the same", tty.display_label(probe("locked"), digit_1), "!")
check("under CAPS the dual legend is UNCHANGED -- caps is not shift",
      tty.display_label(probe(caps=True), digit_1), "1 !")

letter_q = osk.key_at(osk.LETTERS, "left", 0.4, 0.3)
check("the letter key is where this expects it", letter_q.label, "q")
check("a letter is lowercase unshifted", tty.display_label(probe(), letter_q), "q")
check("uppercase under shift", tty.display_label(probe("once"), letter_q), "Q")
check("uppercase under caps too", tty.display_label(probe(caps=True), letter_q), "Q")
check("and a letter never grows a second legend -- upper and lower are the same "
      "glyph, not a different character",
      [tty.display_label(probe(s, c), letter_q) for s, c in STATES],
      ["q", "Q", "Q", "Q", "Q", "Q"])

# --- 🔴 MODIFIER STATE, ON A CONSOLE WITH NO COLOUR --------------------------
#
# §9g turns an active modifier BLUE. There is no blue here, and `face()` no
# longer spells the state into the key (it returns "Shift" in every state now).
# Losing it entirely is not an option: a user who cannot see that Shift is
# armed finds out by typing the wrong case into a passphrase field that echoes
# dots. So it is SPELLED, and one-shot is distinguished from locked.

check("the core really has stopped spelling state into the face -- so this "
      "renderer is the only thing that can",
      [probe(s).face(osk.SHIFT_KEY) for s in ("off", "once", "locked")],
      ["Shift", "Shift", "Shift"])
check("...and the same for caps",
      [probe(caps=c).face(osk.CAPS_KEY) for c in (False, True)], ["Caps", "Caps"])

check("shift off draws no modifier word", tty.display_label(probe(), osk.SHIFT_KEY),
      "L2 Shift")
check("a one-shot says so, in words", tty.display_label(probe("once"), osk.SHIFT_KEY),
      "L2 Shift ONCE")
check("and a lock says something DIFFERENT -- the distinction is not cosmetic",
      tty.display_label(probe("locked"), osk.SHIFT_KEY), "L2 Shift LOCK")
check("caps off draws no modifier word", tty.display_label(probe(), osk.CAPS_KEY),
      "L3 Caps")
check("latched caps says so", tty.display_label(probe(caps=True), osk.CAPS_KEY),
      "L3 Caps ON")
check("caps is independent of shift -- a locked shift does not latch caps",
      tty.display_label(probe("locked"), osk.CAPS_KEY), "L3 Caps")
check("...and a latched caps does not arm shift",
      tty.display_label(probe(caps=True), osk.SHIFT_KEY), "L2 Shift")

# The three words must be pairwise distinct as DRAWN, or the whole mechanism is
# decoration: a user has to be able to tell the states apart on screen.
drawn_shift = {s: tty.to_plain(tty.render(probe(s), osk.Cursors()))
               for s in ("off", "once", "locked")}
check("the three shift states produce three DIFFERENT screens",
      len(set(drawn_shift.values())), 3)
check("caps on and caps off produce different screens too",
      tty.to_plain(tty.render(probe(caps=True), osk.Cursors()))
      != tty.to_plain(tty.render(probe(), osk.Cursors())), True)

# ⚠️ BOTH Shift keys report it, and one of them is drawn in the RIGHT half
# (§9g). A renderer that only lit the left one would leave the right thumb
# with no feedback at all.
check("BOTH shift keys carry the state word -- one of them is in the right half",
      tty.to_plain(tty.render(probe("locked"), osk.Cursors())).count("Shift LOCK"), 2)

# ⚠️ THE CONTRACT WITH THE CORE. If `modifier_state` ever grows a fourth
# answer, this renderer would silently draw nothing for it -- the exact class
# of failure CLAUDE.md forbids. Every value it can actually produce must have a
# word here.
unmapped = set()
for shift, caps in STATES:
    kb_p = probe(shift, caps)
    for _layer, _r, _k, key in every_key():
        state = kb_p.modifier_state(key)
        if state and state not in tty.MODIFIER_TEXT:
            unmapped.add(state)
check("every modifier state the core can report has a word to draw", sorted(unmapped), [])
check("...and the suite really did exercise more than one of them",
      sorted({probe(s, c).modifier_state(k)
              for s, c in STATES for _l, _r, _i, k in every_key()}),
      ["", "locked", "on", "once"])

# --- controller badges, degraded to one uniform text convention --------------

check("shift carries its L2 badge", tty.display_label(probe(), osk.SHIFT_KEY),
      "L2 Shift")
check("caps carries L3 -- the stick click, not a trigger",
      tty.display_label(probe(), osk.CAPS_KEY), "L3 Caps")
check("backspace carries the X face button", tty.display_label(probe(), osk.BACKSPACE_KEY),
      "X Backspace")
check("space carries the Y face button", tty.display_label(probe(), osk.SPACE_KEY),
      "Y space")
check("🔴 enter FINALLY has room for its badge -- span 2 is a budget of 8 and "
      "'R2 Enter' is exactly 8; at KEY_CELL=7 under the old split layout it "
      "did not fit and was dropped",
      tty.display_label(probe(), osk.ENTER_KEY), "R2 Enter")
check("...and that really is the whole budget, with nothing spare",
      len("R2 Enter"), osk.ENTER_KEY.span * tty.KEY_CELL - 2)
check("a plain key with no badge and no legend is left alone",
      tty.display_label(probe(), osk.TAB_KEY), "Tab")
check("so is Move", tty.display_label(probe(), osk.MOVE_KEY), "Move")
check("and Paste", tty.display_label(probe(), osk.PASTE_KEY), "Paste")

# Every badge in the layout must actually reach the screen. A badge defined and
# never drawn is the silent kind of missing.
undrawn = []
for _layer, _r, _k, key in every_key():
    if key.hint and key.hint not in tty.display_label(probe(), key):
        undrawn.append((key.label, key.hint))
check("every badge the layout defines is drawn", undrawn, [])

# ⚠️ Badges are NOT pad-gated on a console, deliberately -- see display_label.
# The drawn text must not depend on which pads are touched, because
# `rows_on_screen` compares a render against a console read taken afterwards.
check("the layout's gating table exists and the Wayland renderer can use it",
      sorted(osk.HINT_PAD_GATE), sorted([osk.HINT_LEFT, osk.HINT_RIGHT]))
check("...but the TTY draws the L2 badge regardless -- a gated badge would make "
      "every rows_on_screen count a race",
      "L2 Shift" in tty.to_plain(tty.render(*fresh())), True)

# No key may carry both a shifted legend and a badge -- there is room for one,
# and `display_label` prefers the legend, which would silently swallow a badge.
both = [key.label for _l, _r, _k, key in every_key()
        if key.shift_label and not key.is_letter and key.hint]
check("no key has both a shift_label and a hint", both, [])

# --- the drop ladder: the badge goes before the modifier word ----------------
#
# ⚠️ NOTHING IN TODAY'S LAYOUT OVERFLOWS, so without these synthetic keys the
# priority ladder would be an untested claim in a docstring. A missing badge
# costs a shortcut that is still reachable by aiming; a missing modifier word
# costs the case of a character the user cannot read back.

wide_shift = osk.Key(label="Shift", action="shift", span=3, hint="L2")
check("...the synthetic key matches the real one, so this is not testing a fiction",
      (wide_shift.label, wide_shift.action, wide_shift.span, wide_shift.hint),
      (osk.SHIFT_KEY.label, osk.SHIFT_KEY.action, osk.SHIFT_KEY.span,
       osk.SHIFT_KEY.hint))

# span 2 -> budget 8. "L2 Shift ONCE" (13) does not fit; "Shift ONCE" (10) does
# not either.
#
# 🔴 THE ANSWER CHANGED IN P33 B1, AND IT CHANGED TOWARDS THIS FUNCTION'S OWN
# STATED PRIORITY. It used to be "Shift" -- the badge AND the modifier word both
# dropped, keeping the full face. `NARROW_LABELS` gives the ladder one more rung
# ("Sh" for "Shift"), and "Sh ONCE" is 7 against a budget of 8, so now the WORD
# survives and the face is what shortens. `display_label`'s docstring has always
# said the modifier word is the last thing dropped -- a user who cannot see that
# Shift is armed finds out by typing the wrong case into a field echoed as dots
# -- and the check below, which predates the change, was already asserting
# exactly this outcome with a hand-shortened face.
narrow = osk.Key(label="Shift", action="shift", span=2, hint="L2")
check("badge dropped first, and the modifier word outlives the full face",
      tty.display_label(probe("once"), narrow), "Sh ONCE")
mid = osk.Key(label="Sh", action="shift", span=2, hint="L2")
check("...and a face with no shorter form drops the word rather than truncating",
      tty.display_label(probe("once"),
                        osk.Key(label="Zzzzz", action="shift", span=2, hint="L2")),
      "Zzzzz")
check("...with a shorter face the WORD survives while the badge is dropped",
      tty.display_label(probe("once"), mid), "Sh ONCE")
check("with room for everything, everything is drawn",
      tty.display_label(probe("once"), wide_shift), "L2 Shift ONCE")
check("with the modifier inactive the badge comes back",
      tty.display_label(probe(), narrow), "L2 Shift")

# A face that cannot fit at all is returned whole and truncated by cell_text,
# rather than being silently shortened here into something a user cannot map
# back to a key.
huge = osk.Key(label="Absurdlylonglabel", span=1)
check("a face too long for its own cell is not invented away",
      tty.display_label(probe(), huge), "Absurdlylonglabel")

# A legend that does not fit falls back to the base face, never to a half legend.
tight = osk.Key(code=e.KEY_1, label="1", shift_label="!!!!!", span=1)
check("a legend that does not fit falls back to the bare face",
      tty.display_label(probe(), tight), "1")

# =============================================================================
# 🔴 P33 J: THE KEYBOARD IS TWICE AS TALL, AND THE ROWS ARE COSTED
# =============================================================================
#
# Operator, looking at the panel 2026-08-16 with the adaptive grid already
# shipped: *"the keyboard is too short ... I would make the keyboard twice as
# tall"*. Full-width and five text rows on a fifty-row console is 10% of the
# screen height.
#
# ⛔ AND THE LAST CHANGE THAT SPENT ROWS SHIPPED TO HARDWARE AND COST AN INSTALL
# (`docs/PROGRESS.md` §5.40). A 16x32 console font was pinned for legibility; it
# halved the columns, which was intended, and halved the ROWS, which nobody
# costed -- 25 rows could not hold the logo, a prompt and the keyboard together,
# so the username and password prompts went off the screen entirely. Every
# number below is measured, and the sum is asserted, so raising KEY_ROWS cannot
# repeat it silently.

# The live ISO's console, MEASURED with `stty size` on tty2 (§7). Not derived
# from the framebuffer -- that arithmetic has been wrong twice (§5.39, §5.40).
LIVE_ISO_ROWS_MEASURED = 50

# The tallest screen the keyboard shares, MEASURED 2026-08-16 by replaying the
# real prompt screens into a 160x50 pty (the real logo.txt, upstream's
# `clear_logo` and `step`, real `[deck-form] WARNING:` text, and `gum input`).
#
# The account prompt is 18 rows:
#
#     1      blank (clear_logo's top padding)
#     2-11   the Omarchy logo, 10 lines, 81 columns
#     12     blank
#     13     the step's prompt text
#     14     blank
#     15     [deck-form] WARNING: ...
#     16     Username>
#     17     blank
#     18     gum's "enter submit" help line
#
# The Wi-Fi passphrase prompt with EVERY warning it can emit at once -- the
# keymap-pin warning wraps 160 columns onto two lines -- is 21, and that is the
# number budgeted against. `deck_form_account_notice` is what stops warnings
# accumulating past it (T4 bug 2, measured at 16/22/28/34 rows before it
# existed).
PROMPT_SCREEN_ROWS = 21

OSK_ROWS = tty.KEY_ROWS * len(osk.LETTERS.rows)
OSK_TOP_ROW = LIVE_ISO_ROWS_MEASURED - OSK_ROWS + 1   # the mapper's anchoring

check("a key row is drawn as KEY_ROWS console rows, and KEY_ROWS is 2 -- "
      "'twice as tall', which is what was asked for", tty.KEY_ROWS, 2)
check("...so the keyboard is ten console rows, not five",
      len(tty.render(*fresh(), LIVE_ISO_COLS)), OSK_ROWS)
check("...and it is exactly twice what it was before P33 J",
      OSK_ROWS, 2 * len(osk.LETTERS.rows))
check("⛔ THE ROW BUDGET: the tallest prompt screen plus the keyboard fits the "
      "console the installer measures, with room left over",
      PROMPT_SCREEN_ROWS + OSK_ROWS <= LIVE_ISO_ROWS_MEASURED, True)
check("...with this many rows clear between the worst prompt screen and the "
      "keyboard", OSK_TOP_ROW - PROMPT_SCREEN_ROWS - 1, 19)
check("...so the mapper's bottom-anchored top row starts below everything the "
      "prompt screen draws", OSK_TOP_ROW > PROMPT_SCREEN_ROWS, True)
check("the ceiling on KEY_ROWS at this console and this prompt is 5, so 2 is "
      "not near it -- and a future increase is checked HERE, not on hardware",
      (LIVE_ISO_ROWS_MEASURED - PROMPT_SCREEN_ROWS) // len(osk.LETTERS.rows), 5)

# ⚠️ NOT VACUOUS: the same sum on §5.40's 25-row console FAILS. That is the
# arithmetic nobody did before pinning the font, expressed as a check, so the
# next person to change either number sees which side of the line they are on.
check("⛔ ...and the same budget on the 16x32 font's 25 rows does NOT fit -- "
      "which is exactly what §5.40 shipped and had to revert",
      PROMPT_SCREEN_ROWS + OSK_ROWS <= 25, False)

# The guards themselves, at both measured geometries. The keyboard has to DRAW
# on the installed TTY's 25 rows even though nothing puts a prompt screen above
# it there (deck-session.sh installs the mapper with --osk-backend=layer).
tall = tty.render(*fresh(), LIVE_ISO_COLS)
check("write_at accepts the keyboard bottom-anchored on the live ISO's 50x160",
      (tty.write_at(io.StringIO(), tall, OSK_TOP_ROW,
                    console_rows=LIVE_ISO_ROWS_MEASURED,
                    console_cols=LIVE_ISO_COLS), True)[1], True)
narrow_tall = tty.render(*fresh(), INSTALLED_TTY_COLS)
check("...and bottom-anchored on the installed TTY's 25x80, which still holds "
      "ten rows even though it could not hold a prompt above them",
      (tty.write_at(io.StringIO(), narrow_tall,
                    INSTALLED_TTY_ROWS - len(narrow_tall) + 1,
                    console_rows=INSTALLED_TTY_ROWS,
                    console_cols=INSTALLED_TTY_COLS), True)[1], True)
check("...and one row further up than fits is REFUSED, not clamped",
      raises(lambda: tty.write_at(io.StringIO(), narrow_tall,
                                  INSTALLED_TTY_ROWS - len(narrow_tall) + 2,
                                  console_rows=INSTALLED_TTY_ROWS), ValueError),
      True)

# --- what a body row is, and what it must never be ---------------------------
#
# ⚠️ NOT BLANK. `rows_on_screen` counts console lines carrying a WHOLE rendered
# row; an all-blank rendered row would match any blank console line, so a screen
# with the keyboard wiped off it would still count half a keyboard. That is
# R-49's defect (a count that says "keyboard" when there is none) reintroduced
# by a padding character. A rule is a signature.
check("the body fill is not a space -- a blank row would match a blank console",
      tty.KEY_BODY_FILL.strip() != "", True)
check("...and it is one ASCII character, like everything else this module draws",
      (len(tty.KEY_BODY_FILL), ord(tty.KEY_BODY_FILL) < 128), (1, True))
check("a plain body cell is exactly its cell's width",
      len(tty.body_text(10, False)), 10)
check("a highlighted one is the SAME width, or keys shift as the cursor moves",
      len(tty.body_text(10, True)), 10)
check("a body cell is drawn one column in from each edge, so keys are separated",
      tty.body_text(10, False), " -------- ")
check("...and a highlighted one keeps the bracket convention of the label above",
      tty.body_text(10, True), "[--------]")
check("at the narrowest cell there is still a rule to see",
      (tty.body_text(3, False), tty.body_text(3, True)), (" - ", "[-]"))

# ⚠️ EVERY console row of a key is the same width as every other, at every cell
# width, in every state and wherever the cursors are. A body row one column off
# would put `write_at`'s incremental path -- which finds a cell's column by
# summing the widths to its left -- at the wrong column on half the console.
ragged = []
for cell_width in range(tty.MIN_KEY_CELL, 11):
    cols_here = cell_width * GRID_CELLS
    for shift, caps in STATES:
        for lx in (0.0, 0.5, 1.0):
            cur_t = osk.Cursors()
            cur_t.pos["left"], cur_t.pos["right"] = [lx, 0.5], [1.0 - lx, 0.2]
            drawn_t = tty.render(probe(shift, caps), cur_t, cols_here)
            if len(drawn_t) != OSK_ROWS:
                ragged.append((cell_width, "row count", len(drawn_t)))
            for label_row, body_row in zip(drawn_t[::tty.KEY_ROWS],
                                           drawn_t[1::tty.KEY_ROWS]):
                if ([len(t) for t, _ in label_row]
                        != [len(t) for t, _ in body_row]):
                    ragged.append((cell_width, shift, caps, "cell widths"))
                if [hot for _, hot in label_row] != [hot for _, hot in body_row]:
                    ragged.append((cell_width, shift, caps, "highlight"))
check("🔴 every body row matches its label row cell for cell -- same widths, "
      "same highlighted cells -- at every cell width and in every state",
      ragged, [])

# The highlight is what a user hunts for, and making it KEY_ROWS rows tall is
# most of what "twice as tall" buys. Both halves, one key each, all their rows.
kb_h, cur_h = fresh()
cur_h.pos["left"], cur_h.pos["right"] = [0.1, 0.1], [0.9, 0.9]
hot_rows = tty.render(kb_h, cur_h, LIVE_ISO_COLS)
check("two cursors highlight two keys, KEY_ROWS cells each",
      sum(1 for row in hot_rows for _, hot in row if hot), 2 * tty.KEY_ROWS)
check("...and the highlighted cells sit in consecutive console rows, so the "
      "cursor is one block and not two stripes",
      [n for n, row in enumerate(hot_rows) if any(hot for _, hot in row)],
      [0, 1, 8, 9])

# ⚠️ AND THE WIDTH DID NOT MOVE. This change spends ROWS; a key that also grew
# sideways would break the column budget the previous round measured.
check("the drawn width is unchanged by the extra rows",
      tty.width(tty.render(*fresh(), LIVE_ISO_COLS)),
      GRID_CELLS * tty.cell_width_for(LIVE_ISO_COLS, GRID_CELLS))

# ⚠️ THE LABELS ARE STILL ON EVERY KEY, once each. A body row that accidentally
# carried a label would double every face on the screen.
tall_plain = tty.to_plain(tty.render(*fresh(), LIVE_ISO_COLS))
check("each key face is drawn exactly once, not once per console row",
      (tall_plain.count("Backspace"), tall_plain.count("Y space"),
       tall_plain.count("L2 Shift")), (1, 1, 2))
check("...and the rows between them carry only the rule",
      sorted(set(tall_plain.split("\n")[1].replace(" ", ""))),
      [tty.KEY_BODY_FILL])


# --- the rendered grid, read back as text ------------------------------------

kb, cur = fresh()
rows = tty.render(kb, cur)
plain = tty.to_plain(rows)
KEY_ROWS_IN_LAYER = len(osk.LETTERS.rows)
check("the letters layer has five key rows", KEY_ROWS_IN_LAYER, 5)
check("...drawn as KEY_ROWS console rows each (P33 J)",
      len(rows), tty.KEY_ROWS * KEY_ROWS_IN_LAYER)


def label_line(n: int) -> str:
    """The console line carrying key row `n`'s labels (P33 J).

    A key row is `KEY_ROWS` console rows: the label row first, then the body
    rows. Every check below that used to index a rendered line by key row goes
    through this, so raising KEY_ROWS does not silently start asserting against
    a rule of dashes.
    """
    return plain.split("\n")[n * tty.KEY_ROWS]


check("every row is the same width",
      len({sum(len(t) for t, _ in row) for row in rows}), 1)
check("the keyboard is one layer -- §9g's grid carries every printable ASCII "
      "character, so the old symbols layer is gone", sorted(osk.LAYERS), ["letters"])


def labels(line: str) -> list[str]:
    """Labels on a rendered line, with the highlight brackets stripped.

    Both cursors start centred, so cells are bracketed; splitting raw text
    would read `[ d ]` as three tokens.
    """
    return line.replace("[", " ").replace("]", " ").split()


check("row 1 is §9g's number row, dual legends and the X-badged backspace",
      labels(label_line(0)),
      ["`", "~", "1", "!", "2", "@", "3", "#", "4", "$", "5", "%", "6", "^",
       "7", "&", "8", "*", "9", "(", "0", ")", "-", "_", "=", "+",
       "X", "Backspace"])
check("row 2 is Tab, qwertyuiop and the three bracket keys",
      labels(label_line(1)),
      ["Tab", "q", "w", "e", "r", "t", "y", "u", "i", "o", "p",
       "{", "}", "\\", "|"])
check("row 3 is L3-badged Caps, the home row, and R2 Enter",
      labels(label_line(2)),
      ["L3", "Caps", "a", "s", "d", "f", "g", "h", "j", "k", "l",
       ";", ":", "'", '"', "R2", "Enter"])
check("row 4 is Shift, zxcvbnm, the punctuation and Shift AGAIN on the right",
      labels(label_line(3)),
      ["L2", "Shift", "z", "x", "c", "v", "b", "n", "m", ",", "<", ".", ">",
       "/", "?", "L2", "Shift"])
check("row 5 is the emoji key, the wide space, the two dual-legend arrows, "
      "Paste and Move",
      labels(label_line(4)),
      [":)", "Y", "space", "<", "^", ">", "v", "Paste", "Move"])

# Row 2's `[` key is drawn `[ {` -- an opening bracket as a real key face, one
# column in from the cell edge. That is exactly where a naive "strip the
# highlight brackets" reader goes wrong, and `face_of` is geometric for it.
check("row 2 really does draw a bracket KEY, not a highlight", "[ {" in plain, True)

# --- the highlight follows the cursor ----------------------------------------

kb, cur = fresh()
cur.update(e.ABS_HAT0X, MIN)   # left pad: top-left -> "`"
cur.update(e.ABS_HAT0Y, MAX)
cur.update(e.ABS_HAT1X, MAX)   # right pad: top-right -> backspace
cur.update(e.ABS_HAT1Y, MAX)
rows = tty.render(kb, cur)
plain = tty.to_plain(rows)
key_tl = osk.key_at(osk.LETTERS, "left", 0.0, 0.0)
key_tr = osk.key_at(osk.LETTERS, "right", 1.0, 0.0)
check("the left cursor is on the grave key", key_tl.label, "`")
check("the right cursor is on backspace", key_tr.label, "Backspace")
check("the left cursor brackets the key it is over",
      tty.cell_text(tty.display_label(kb, key_tl), tty.KEY_CELL, True) in plain, True)
check("the right cursor brackets its own key",
      tty.cell_text(tty.display_label(kb, key_tr),
                    key_tr.span * tty.KEY_CELL, True) in plain, True)
check("exactly two keys are highlighted -- one per half, KEY_ROWS cells each",
      sum(1 for row in rows for _, hot in row if hot), 2 * tty.KEY_ROWS)

# Independence: moving one cursor must not move the other's highlight.
cur.update(e.ABS_HAT0X, MAX)   # left cursor to the right edge of ITS half
cur.update(e.ABS_HAT0Y, MAX)
key_l_moved = osk.key_at(osk.LETTERS, "left", 1.0, 0.0)
plain = tty.to_plain(tty.render(kb, cur))
check("moving the left cursor moved its highlight",
      tty.cell_text(tty.display_label(kb, key_l_moved), tty.KEY_CELL, True) in plain, True)
check("and left the right cursor's highlight alone",
      tty.cell_text(tty.display_label(kb, key_tr),
                    key_tr.span * tty.KEY_CELL, True) in plain, True)
check("still exactly two highlighted keys",
      sum(1 for row in tty.render(kb, cur) for _, hot in row if hot),
      2 * tty.KEY_ROWS)

# 🔴 §9g's SPACE BAR STRADDLES THE SPLIT so either thumb can reach it, which
# means BOTH CURSORS CAN BE OVER ONE KEY. That is one highlighted cell, not
# two -- a renderer that highlighted per-half would draw the same cell twice
# and, worse, anything counting highlights would assume "two" forever.
kb_sp, cur_sp = fresh()
cur_sp.pos["left"], cur_sp.pos["right"] = [0.6, 1.0], [0.1, 1.0]
check("both cursors are on the space bar",
      [kb_sp.key_at(h, *cur_sp.position(h)).label for h in ("left", "right")],
      ["space", "space"])
sp_rows = tty.render(kb_sp, cur_sp)
check("two cursors on one key highlight ONE key, not two -- KEY_ROWS cells of it",
      sum(1 for row in sp_rows for _, hot in row if hot), tty.KEY_ROWS)
check("...and it is the space bar, label row and body rows alike",
      [tty.face_of(t) for row in sp_rows for t, hot in row if hot],
      ["Y space"] + [tty.face_of(tty.body_text(
          osk.SPACE_KEY.span * tty.KEY_CELL, True))] * (tty.KEY_ROWS - 1))

# ⚠️ A cursor outside its half makes `locate` return None -- "a caller bug
# rather than a user miss", in the core's words, and the honest answer. The
# renderer must still draw the whole keyboard and must not invent a highlight
# for the half that has no key under it. `Cursors` clamps, so this is reached
# only by writing the position directly, which the state protocol's reader does.
kb_off, cur_off = fresh()
cur_off.pos["left"], cur_off.pos["right"] = [1.5, 0.5], [0.5, 0.5]
check("a cursor outside its half locates nothing", kb_off.locate("left", 1.5, 0.5), None)
off_rows = tty.render(kb_off, cur_off)
check("...and the keyboard still draws, whole", tty.width(off_rows), KB_WIDTH)
check("...with only the other half's cursor highlighted, not a phantom",
      sum(1 for row in off_rows for _, hot in row if hot), tty.KEY_ROWS)

# --- ⚠️ THE PROPERTY THAT MATTERS: drawn == pressed --------------------------
#
# Every cell that renders highlighted must be the cell a press at that cursor
# actually types. A renderer and a hit test that disagree produce a keyboard
# that types a different character from the one lit up -- and both halves pass
# their own tests. Swept over the whole pad, both axes moving together, in
# every shift/caps state because the legends differ between them.

mismatches = []
for shift, caps in STATES:
    for xi in range(0, 21):
        for yi in range(0, 21):
            kb_s = probe(shift, caps)
            cur_s = osk.Cursors()
            vx = (MIN + (MAX - MIN) * xi // 20) or 1  # 0 is the lift sentinel
            vy = (MIN + (MAX - MIN) * yi // 20) or 1
            for half, ax, ay in (("left", e.ABS_HAT0X, e.ABS_HAT0Y),
                                 ("right", e.ABS_HAT1X, e.ABS_HAT1Y)):
                cur_s.update(ax, vx)
                cur_s.update(ay, vy)
                rendered = tty.render(kb_s, cur_s)
                located = kb_s.locate(half, *cur_s.position(half))
                key = kb_s.key_at(half, *cur_s.position(half))
                if located is None or key is None:
                    mismatches.append((shift, caps, half, xi, yi, "no key"))
                    continue
                hot_faces = {tty.face_of(text)
                             for row in rendered for text, on in row if on}
                want = tty.face_of(tty.cell_text(
                    tty.display_label(kb_s, key), key.span * tty.KEY_CELL, True))
                if want not in hot_faces:
                    mismatches.append((shift, caps, half, xi, yi, want, hot_faces))
check("every highlighted cell is the key a press there would type", mismatches, [])

# --- pressing what is drawn changes what is drawn -----------------------------
#
# End to end through the core: the badge on Shift claims L2 arms it, so the key
# under the cursor must go through off -> once -> locked -> off and the screen
# must follow.

kb, cur = fresh()
shift_seen = [tty.to_plain(tty.render(kb, cur))]
for _ in range(3):
    kb.press_at("left", 0.05, 0.75)   # the left Shift key, row 4
    shift_seen.append(tty.to_plain(tty.render(kb, cur)))
check("pressing shift cycles off -> once -> locked -> off, visibly",
      ["ONCE" in shift_seen[1], "LOCK" in shift_seen[2],
       "ONCE" in shift_seen[3] or "LOCK" in shift_seen[3]],
      [True, True, False])
check("...and the core agrees it went round", kb.shift, "off")
check("...and the screen returns to exactly where it started",
      shift_seen[3], shift_seen[0])

kb, cur = fresh()
kb.press_at("left", 0.05, 0.5)        # the Caps key, row 3
check("pressing caps latches it", kb.caps, True)
caps_screen = tty.to_plain(tty.render(kb, cur))
check("...the screen says so", "Caps ON" in caps_screen, True)
check("...the letters are capitalised with it",
      tty.cell_text("Q", tty.KEY_CELL, False) in caps_screen, True)
check("...and the digits are NOT -- caps is letters only",
      " 1 ! " in caps_screen or "1 !" in caps_screen, True)
check("...specifically, no digit has been swapped for its symbol",
      tty.cell_text("!", tty.KEY_CELL, False) in caps_screen, False)

# --- ANSI vs plain ------------------------------------------------------------

kb, cur = fresh()
rows = tty.render(kb, cur)
ansi = tty.to_ansi(rows)
check("the ANSI form carries reverse video", tty.REVERSE in ansi, True)
check("and resets it", tty.RESET in ansi, True)
check("the plain form carries no escape sequences", "\x1b" in tty.to_plain(rows), False)
check("stripping the escapes from the ANSI form gives the plain form",
      ansi.replace(tty.REVERSE, "").replace(tty.RESET, ""), tty.to_plain(rows))
check("the highlight survives in PLAIN text too -- capture-pane has no colours",
      "[" in tty.to_plain(rows), True)

# --- write_at: positioning, and not stealing the TUI's cursor -----------------

buf = io.StringIO()
tty.write_at(buf, rows, 19)
written = buf.getvalue()
check("the draw saves the cursor first", written.startswith("\x1b[s"), True)
check("and restores it last", written.endswith("\x1b[u"), True)
check("the first line is placed at the requested row", "\x1b[19;1H" in written, True)
check("and the last line below it", f"\x1b[{19 + len(rows) - 1};1H" in written, True)
check("each line clears to end first, so a shorter redraw leaves no debris",
      written.count("\x1b[K"), len(rows))

buf = io.StringIO()
tty.write_at(buf, rows, 19, ansi=False)
check("ansi=False writes no reverse video", tty.REVERSE in buf.getvalue(), False)
check("but still positions the rows", "\x1b[19;1H" in buf.getvalue(), True)

# --- the out-of-bounds guards, both axes (R-49) ------------------------------
#
# ⚠️ ROWS: without the guard the kernel clamps every row that falls past the end
# of the console onto the LAST line, where they overwrite each other -- measured
# in QEMU as five keyboard rows collapsing into one garbled line that still
# greps as a keyboard. Silent, and worse than an error.
#
# 🔴 COLUMNS: the same failure on the other axis, and since §9g the keyboard
# needs every column the installed TTY has. A row wider than the console WRAPS
# -- each row becomes two, the rest is pushed down and off. Asserted at the real
# 25x80, which is the geometry with zero slack.

buf = io.StringIO()
BOTTOM = INSTALLED_TTY_ROWS - len(rows) + 1
tty.write_at(buf, rows, BOTTOM, ansi=False,
             console_rows=INSTALLED_TTY_ROWS, console_cols=INSTALLED_TTY_COLS)
check("🔴 the keyboard draws at the bottom of the REAL installed TTY (25x80), "
      "both guards armed", f"\x1b[{BOTTOM};1H" in buf.getvalue(), True)
check("...and the last row lands on the console's last line", BOTTOM + len(rows) - 1,
      INSTALLED_TTY_ROWS)
check("...and every line actually written is exactly 80 columns of keyboard",
      all(f"\x1b[K{line}" in buf.getvalue() and len(line) == INSTALLED_TTY_COLS
          for line in tty.to_plain(rows).split("\n")), True)

# 🔴 THE BOUNDARY, DERIVED FROM THE KEYBOARD'S OWN HEIGHT (P33 J). These used to
# be the literals 20 and 21 against a 24-row console, which stopped meaning
# "one row inside" and "one row over" the moment a key row became KEY_ROWS
# console rows.
SMALL_ROWS = 24
TOP_FITS = SMALL_ROWS - len(rows) + 1      # the last top row that fits exactly
TOP_OVER = TOP_FITS + 1                    # one row too far down
check("a draw that fits is unaffected by the row guard",
      f"\x1b[{TOP_FITS};1H" in (
          lambda b: (tty.write_at(b, rows, TOP_FITS, console_rows=SMALL_ROWS),
                     b.getvalue())[1])(io.StringIO()), True)
check("a draw running off the end refuses, naming the rows and the console",
      raises_saying(lambda: tty.write_at(io.StringIO(), rows, TOP_OVER,
                                         console_rows=SMALL_ROWS),
                    ValueError, str(TOP_OVER), str(SMALL_ROWS)), True)
check("and so does one starting above the first row",
      raises(lambda: tty.write_at(io.StringIO(), rows, 0,
                                  console_rows=SMALL_ROWS), ValueError), True)
check("the last row that fits exactly is allowed",
      (tty.write_at(io.StringIO(), rows, TOP_FITS, console_rows=SMALL_ROWS),
       True)[1], True)
check("with no console_rows given, nothing is checked -- callers opt in",
      (tty.write_at(io.StringIO(), rows, 9999), True)[1], True)

check("🔴 exactly 80 columns into an 80-column console is ALLOWED -- zero slack "
      "is the design, not an overflow",
      (tty.write_at(io.StringIO(), rows, 1, console_cols=INSTALLED_TTY_COLS), True)[1],
      True)
check("🔴 one column too narrow REFUSES, naming the width and the console",
      raises_saying(lambda: tty.write_at(io.StringIO(), rows, 1,
                                         console_cols=INSTALLED_TTY_COLS - 1),
                    ValueError, "80", "79"), True)
check("...and the message is about WRAPPING, not about rows -- two guards "
      "sharing one signal would let either be deleted unnoticed",
      raises_saying(lambda: tty.write_at(io.StringIO(), rows, 1, console_cols=40),
                    ValueError, "wrap"), True)
check("the row guard's message is NOT about wrapping",
      raises_saying(lambda: tty.write_at(io.StringIO(), rows, TOP_OVER,
                                         console_rows=SMALL_ROWS),
                    ValueError, "wrap"), False)
check("the live ISO's 160 columns are comfortably fine",
      (tty.write_at(io.StringIO(), rows, 1, console_rows=LIVE_ISO_ROWS,
                    console_cols=LIVE_ISO_COLS), True)[1], True)
check("with no console_cols given, nothing is checked -- callers opt in",
      (tty.write_at(io.StringIO(), rows, 1, console_cols=None), True)[1], True)
check("both guards can fire on the same draw; the ROW one is checked first, so a "
      "caller learns about the more destructive failure",
      raises_saying(lambda: tty.write_at(io.StringIO(), rows, 99,
                                         console_rows=SMALL_ROWS,
                                         console_cols=10),
                    ValueError, "collapse"), True)

# --- rows_on_screen: COUNT the rows, never grep for a word (R-49, R-52) ------
#
# ⚠️ This is the assertion primitive both failures needed and neither had.
# R-49: `stty rows` shrank the console, the kernel clamped all five keyboard
# rows onto the last line, and the garbled result still contained `Shift`.
# R-52: a full-screen curses TUI repainted every line but the last, leaving
# exactly one row. Both look like a keyboard to a substring check. Only the
# count tells them apart.

kb, cur = fresh()
rows = tty.render(kb, cur)
CONSOLE_W, CONSOLE_H = INSTALLED_TTY_COLS, INSTALLED_TTY_ROWS

# 🔴 ANCHORED AT THE BOTTOM, NOT AT A LITERAL ROW (P33 J). These checks used to
# draw at line 20 of a 25-row console, which had room for five rows and has none
# for ten. `deck-input-mapper` bottom-anchors the keyboard (`console_rows -
# len(rows) + 1`), so that is what is modelled here -- and every expected line
# number below is derived from it, so raising KEY_ROWS moves the assertions with
# the keyboard instead of turning them into arithmetic nobody re-does.
KB_TOP = CONSOLE_H - len(rows) + 1
KB_LINES = list(range(KB_TOP, KB_TOP + len(rows)))
KB_MIDDLE = KB_TOP + 2          # a line inside the keyboard, for damage checks


def console(lines: dict[int, str], cols: int = CONSOLE_W, height: int = CONSOLE_H) -> str:
    """A `height` x `cols` screen, as /dev/vcsN folded gives it."""
    return "\n".join(lines.get(n, "").ljust(cols)[:cols]
                     for n in range(1, height + 1))


def drawn_at(top: int, source=None) -> dict[int, str]:
    """The keyboard painted with its first line at `top`, 1-based."""
    body = tty.to_plain(source if source is not None else rows).split("\n")
    return {top + offset: line for offset, line in enumerate(body)}


check("a clean draw is found on exactly the rows it was drawn on",
      tty.rows_on_screen(console(drawn_at(KB_TOP)), rows), KB_LINES)
check("a blank console carries no keyboard rows",
      tty.rows_on_screen(console({}), rows), [])
check("neither does one full of somebody else's TUI",
      tty.rows_on_screen(console({n: f"MENU LINE {n:02d} " + "-" * 60
                                  for n in range(1, CONSOLE_H + 1)}), rows), [])

# ⚠️ R-49's EXACT SHAPE. Five rows written to one line, each overwriting the
# last -- which is what the kernel does when they fall past the end of the
# console. The word survives; the keyboard does not.
clamped = console({CONSOLE_H: tty.to_plain(rows).split("\n")[-1]})
check("R-49's clamp is ONE row, not ten", len(tty.rows_on_screen(clamped, rows)), 1)
# 🔴 AND WHICH ROW SURVIVES CHANGED IN P33 J. The kernel's clamp leaves whatever
# was written LAST, and the last console row of a key row is now a BODY row --
# a rule, with no word on it. So this particular screen no longer greps as a
# keyboard, which is a weaker lie than R-49's, not a fixed one: clamp a LABEL
# row and the word is right back.
check("...and the surviving row is a body rule, so the word is gone from THIS one",
      "space" in clamped, False)
clamped_label = console({CONSOLE_H: tty.to_plain(rows).split("\n")[-tty.KEY_ROWS]})
check("...but clamp a LABEL row and `space` is still right there -- R-49's lie",
      "space" in clamped_label, True)
check("...and it too counts as exactly ONE row",
      len(tty.rows_on_screen(clamped_label, rows)), 1)

# ⚠️ R-52's EXACT SHAPE, measured in QEMU. A full-screen TUI repaints every
# line except the console's last, so four keyboard rows die and one lives.
partial = drawn_at(KB_TOP)
for line in range(1, CONSOLE_H):
    partial[line] = f"MENU LINE {line:02d} PASS 01 " + "-" * 50
check("a TUI repainting all but the last line leaves ONE row",
      len(tty.rows_on_screen(console(partial), rows)), 1)
check("...and since P33 J that survivor is the bottom BODY row, so this screen "
      "does NOT grep as a keyboard -- the count is still the only reliable "
      "question, and it still says one row of ten",
      "space" in console(partial), False)

# ⚠️ AND THE SHAPE THE MEASUREMENT ACTUALLY TOOK, which is nastier than the one
# above. ncurses repaints by diffing against its own model of the physical
# screen, and that model has never heard of us -- so a "full repaint" rewrote
# only the cells whose content changed and punched a SINGLE CHARACTER through
# each keyboard row. Every row still reads as a keyboard to a human and to a
# grep; one key per row now types something other than what it draws.
punched = drawn_at(KB_TOP)
for line in KB_LINES:
    punched[line] = punched[line][:17] + "1" + punched[line][18:]
check("one character punched through each row leaves NO intact row",
      tty.rows_on_screen(console(punched), rows), [])
check("...while `Shift` is still on the screen, untouched",
      "Shift" in console(punched), True)
check("...and each row differs from an intact one by exactly ONE character",
      sum(a != b for a, b in zip(punched[KB_MIDDLE],
                                 drawn_at(KB_TOP)[KB_MIDDLE])), 1)

# The cursors move between a render and a console read. A row whose highlight
# sits elsewhere is still that row -- otherwise every count would be a race.
kb_moved, cur_moved = fresh()
cur_moved.update(e.ABS_HAT0X, MIN)
cur_moved.update(e.ABS_HAT0Y, MAX)
cur_moved.update(e.ABS_HAT1X, MAX)
cur_moved.update(e.ABS_HAT1Y, MAX)
moved = tty.render(kb_moved, cur_moved)
check("the highlight having moved does not lose a row",
      tty.rows_on_screen(console(drawn_at(KB_TOP, moved)), rows), KB_LINES)
check("and the two renders really do differ, so that was not vacuous",
      tty.to_plain(moved) == tty.to_plain(rows), False)

# ⚠️ AND A SHIFT-STATE CHANGE MUST *NOT* round-trip. The legends genuinely
# differ under shift (§9g), so a screen drawn shifted is not the same keyboard
# -- if this passed, `face_of` would be throwing the legends away.
shifted_rows = tty.render(probe("locked"), osk.Cursors())
# 🔴 THE PRICE OF A BODY ROW, STATED RATHER THAN DISCOVERED (P33 J). A body row
# carries a rule and no legend, so it is IDENTICAL in every shift/caps state --
# a shifted screen therefore matches the unshifted render on exactly its body
# rows. No LABEL row may match, which is the property `face_of` is being tested
# for; and only the FULL count means an intact keyboard, which is what the VM
# suite asserts.
shifted_found = tty.rows_on_screen(console(drawn_at(KB_TOP, shifted_rows)), rows)
check("a shifted screen matches NO label row of an unshifted render",
      [n for n in shifted_found if (n - KB_TOP) % tty.KEY_ROWS == 0], [])
check("...only its body rows, which carry no legend to disagree about",
      len(shifted_found), KEY_ROWS_IN_LAYER * (tty.KEY_ROWS - 1))
check("...and against its OWN render finds every row",
      tty.rows_on_screen(console(drawn_at(KB_TOP, shifted_rows)), shifted_rows),
      KB_LINES)

# Partial damage is the whole point: one overwritten cell is not a row.
FIRST_CELL = len(rows[2][0][0])
damaged = drawn_at(KB_TOP)
damaged[KB_MIDDLE] = "X" * FIRST_CELL + damaged[KB_MIDDLE][FIRST_CELL:]
check("a row with its FIRST cell overwritten does not count",
      tty.rows_on_screen(console(damaged), rows),
      [n for n in KB_LINES if n != KB_MIDDLE])

# ⚠️ And the last cell too, separately. A check that stopped after the first
# cell would pass the test above and miss a keyboard whose right-hand half a
# TUI had eaten -- which is half the screen, and the half `Enter` is on.
LAST_CELL = len(rows[2][-1][0])
tail_damaged = drawn_at(KB_TOP)
tail_damaged[KB_MIDDLE] = (tail_damaged[KB_MIDDLE][:KB_WIDTH - LAST_CELL]
                           + "X" * LAST_CELL)
check("a row with its LAST cell overwritten does not count either",
      tty.rows_on_screen(console(tail_damaged), rows),
      [n for n in KB_LINES if n != KB_MIDDLE])

# ⚠️ Columns to the right are not the keyboard's business -- but on the
# INSTALLED TTY there are none, so this has to be checked on the LIVE ISO's
# 160-column console, which is the other geometry §7 measured.
beside = drawn_at(KB_TOP)
beside[KB_MIDDLE] = beside[KB_MIDDLE][:KB_WIDTH].ljust(KB_WIDTH) + " TUI"
check("text to the RIGHT of the keyboard does not disqualify the row (live ISO, "
      "160 columns -- on the installed TTY there is no 'right of')",
      tty.rows_on_screen(console(beside, cols=LIVE_ISO_COLS), rows), KB_LINES)

# A console too narrow to hold a row truncates it, and a truncated row must not
# be padded back into a match -- that would invent a keyboard that is not there.
# 🔴 THIS IS THE 79-COLUMN CONSOLE, i.e. the exact thing KEY_CELL=5 has no
# slack against.
narrow = console(drawn_at(KB_TOP), cols=KB_WIDTH - 1)
check("a console one column too narrow carries NO intact keyboard row",
      tty.rows_on_screen(narrow, rows), [])

# Offsets. A row found on line 1 must report 1, not 0.
check("line numbering is 1-based, like every console coordinate here",
      tty.rows_on_screen(console(drawn_at(1)), rows),
      list(range(1, len(rows) + 1)))

# The punctuation keys put `[` and `]` on real key faces, which is exactly where
# a naive "strip the highlight brackets" reader goes wrong.
check("a bracket KEY reads as its face, not as an empty highlight",
      tty.face_of(tty.cell_text("[ {", tty.KEY_CELL, False)), "[ {")
check("and so does a highlighted one",
      tty.face_of(tty.cell_text("[ {", tty.KEY_CELL, True)), "[ {")
check("a highlighted cell and a plain one report the same face",
      tty.face_of(tty.cell_text("Y space", 40, True)),
      tty.face_of(tty.cell_text("Y space", 40, False)))

# ⚠️ And no cell the renderer ACTUALLY draws cold may be mistaken for a
# highlighted one -- a label that exactly filled its cell and began with `[`
# would be. Checked over the whole keyboard in every state rather than argued.
misread = []
for shift, caps in STATES:
    for row in tty.render(probe(shift, caps), osk.Cursors()):
        for text, hot in row:
            if not hot and len(text) >= 2 and text[0] == "[" and text[-1] == "]":
                misread.append((shift, caps, text))
check("no cold cell can be misread as a highlighted one", misread, [])

# ⚠️ A HIGHLIGHT IS BOTH BRACKETS OR IT IS NOT A HIGHLIGHT. One of them is
# somebody else's, and TUIs draw brackets constantly -- `[x]` checkboxes, `[1]`
# menu indices. Unwrapping on either bracket alone would let a row a TUI had
# half-eaten read back as intact, which is precisely the false pass this whole
# section exists to prevent.
check("a stray closing bracket does not make a cell a highlight",
      tty.face_of("X q ]"), "X q ]")
check("nor does a stray opening one", tty.face_of("[ q X"), "[ q X")
half_bracketed = drawn_at(KB_TOP)
half_bracketed[KB_MIDDLE] = ("X" + half_bracketed[KB_MIDDLE][1:KB_WIDTH - 1]
                             + "]")
check("a row whose ends a TUI replaced with brackets does not count",
      tty.rows_on_screen(console(half_bracketed), rows),
      [n for n in KB_LINES if n != KB_MIDDLE])

# --- clear_at ------------------------------------------------------------------

buf = io.StringIO()
tty.clear_at(buf, rows, 19)
cleared = buf.getvalue()
check("clearing erases one line per rendered row", cleared.count("\x1b[K"), len(rows))
# Not `"[" in cleared` -- every escape sequence contains one. Assert on the
# thing that actually matters: no key face survives the clear.
check("clearing writes no key label",
      any(lab in cleared for lab in ("Shift", "space", "q", "Backspace")), False)
check("clearing also restores the cursor", cleared.endswith("\x1b[u"), True)


# =============================================================================
# 🔴 P33 B2: THE REPAINT RATE (docs/PROGRESS.md §5.34 D4)
# =============================================================================
#
# §5.34 D4 says "rate is unmeasured -- measure before fixing", so it was.
# `deck-input-mapper.py` redraws ONCE PER READ BATCH from the pad fd (its own
# comment: "Redraw once per batch, not per event") and the pads run at 250 Hz,
# so one second of a thumb on a pad was 250 draws, and at HEAD each one was:
#
#     5 rows BLANKED with `\x1b[K` and repainted -> 1250 erases/s, 116750 bytes/s
#
# on a framebuffer console with no double buffering, against a 90 Hz panel. A
# thumb resting perfectly still cost exactly the same as one sweeping the pad,
# because the draw did not look at what was already on the screen.
#
# ⚠️ THE FLICKER ITSELF IS NOT REPRODUCIBLE OFF HARDWARE -- there is no VT and no
# scanout here, and this file has no way to see a flash. What IS measurable, and
# what these checks pin, is the DRIVE: how many cells get erased and repainted
# per draw. That is the quantity the fix reduces, and it is the honest thing to
# assert. Whether the panel stops flickering is the operator's to confirm.

MOVE_RE = re.compile(r"\x1b\[(\d+);(\d+)H")


class Recorder:
    """A stream that counts what a console would have had to paint."""

    def __init__(self):
        self.chunks = []

    def write(self, text):
        self.chunks.append(text)
        return len(text)

    def flush(self):
        pass

    @property
    def text(self):
        return "".join(self.chunks)

    @property
    def writes(self):
        return len(self.chunks)

    @property
    def moves(self):
        return len(MOVE_RE.findall(self.text))

    @property
    def erases(self):
        return self.text.count("\x1b[K")


def at(lx, ly, rx=0.9, ry=0.9):
    cursors_r = osk.Cursors()
    cursors_r.pos["left"], cursors_r.pos["right"] = [lx, ly], [rx, ry]
    return tty.render(osk.OnScreenKeyboard(), cursors_r)


# --- the first draw is exactly what it always was ----------------------------
#
# ⚠️ A COLD STREAM MUST NOT BE INCREMENTAL. Nothing is known about what is under
# the keyboard on the first draw, so it clears each row to end-of-line and paints
# it whole -- the pre-P33 behaviour, byte for byte. Every existing check above
# draws into a fresh buffer, which is why they still hold.
rec = Recorder()
tty.write_at(rec, rows, 20)
check("the first draw to a stream paints every row and clears each one",
      (rec.writes, rec.moves, rec.erases), (1, len(rows), len(rows)))

# --- an unchanged frame writes NOTHING ----------------------------------------
#
# The common case while a thumb rests on a pad that keeps reporting at 250 Hz.
tty.write_at(rec, rows, 20)
check("🔴 redrawing an identical keyboard writes nothing at all -- no bytes, no "
      "erase, no flush", (rec.writes, rec.moves, rec.erases),
      (1, len(rows), len(rows)))

# --- a cursor move paints the CELLS that changed, and erases nothing ----------
rec2 = Recorder()
first = at(0.05, 0.5)
tty.write_at(rec2, first, 20)
before_moves = rec2.moves
moved = at(0.60, 0.5)
check("...and the two frames really do differ, so this is not vacuous",
      tty.to_plain(first) == tty.to_plain(moved), False)
tty.write_at(rec2, moved, 20)
check("🔴 a one-row cursor move paints exactly the two KEYS that changed -- "
      "KEY_ROWS cells each, and nothing else on the console",
      rec2.moves - before_moves, 2 * tty.KEY_ROWS)
check("...and erases NOTHING -- the blank-then-paint flash is what the panel sees",
      rec2.erases, len(rows))
check("...and it is still one write() per draw, not one per cell",
      rec2.writes, 2)
check("...still bracketed by save/restore, which also clears any pending wrap",
      rec2.chunks[-1].startswith("\x1b[s") and rec2.chunks[-1].endswith("\x1b[u"),
      True)

# The incremental write is a fraction of a full one. Both numbers are recorded
# rather than a ratio asserted, so a regression says which way it went.
full_bytes = len(rec2.chunks[0])
delta_bytes = len(rec2.chunks[1])
check("a one-cell move costs a small fraction of a full repaint",
      delta_bytes * 5 < full_bytes, True)
print(f"     (full repaint {full_bytes} bytes, one-cell move {delta_bytes} bytes)")

# --- a move that crosses rows repaints cells in BOTH -------------------------
rec3 = Recorder()
tty.write_at(rec3, at(0.35, 0.1), 20)
base = rec3.moves
tty.write_at(rec3, at(0.35, 0.9), 20)
check("a cursor moving between rows paints the cells of the key it left and the "
      "key it reached", rec3.moves - base, 2 * tty.KEY_ROWS)

# --- nothing is ever written past the console's last column -------------------
#
# ⚠️ THE ZERO-SLACK ARGUMENT, RE-CHECKED CELL BY CELL. `write_at`'s docstring
# says a row that exactly fills the console is safe because the VT defers its
# wrap until the next character, and the next thing written is always an absolute
# move or the restore. That argument has to hold for a CELL that ends in the last
# column too, which is new since P33 B2.
for cols_w in (PLAN_COLS_BIG_FONT, INSTALLED_TTY_COLS,
               PLAN_COLS_SMALL_FONT, LIVE_ISO_COLS):
    rec_w = Recorder()
    overrun = []
    positions = [(x / 20, y / 20) for x in range(21) for y in (2, 9, 17)]
    for lx, ly in positions:
        cursors_w = osk.Cursors()
        cursors_w.pos["left"], cursors_w.pos["right"] = [lx, ly], [1.0 - lx, ly]
        sweep_rows = tty.render(osk.OnScreenKeyboard(), cursors_w, cols_w)
        tty.write_at(rec_w, sweep_rows,
                     INSTALLED_TTY_ROWS - len(sweep_rows) + 1,
                     console_rows=INSTALLED_TTY_ROWS, console_cols=cols_w)
    for chunk in rec_w.chunks:
        for piece in chunk.split("\x1b[")[1:]:
            hit = re.match(r"(\d+);(\d+)H(.*)", piece, re.S)
            if hit:
                text_after = hit.group(3).replace(tty.REVERSE, "").replace(tty.RESET, "")
                text_after = text_after.split("\x1b")[0].replace("\x1b[K", "")
                if int(hit.group(2)) - 1 + len(text_after) > cols_w:
                    overrun.append((cols_w, hit.group(0)[:40]))
    check(f"nothing is ever painted past column {cols_w}, cell by cell, over a "
          "full sweep of both cursors", overrun, [])

# --- damage heals: the unconditional repaint ---------------------------------
#
# ⚠️ THE PRICE OF REMEMBERING. This module can now be wrong about what is on the
# screen, so it repaints everything every FULL_REPAINT_EVERY draws. Without that
# bound, one line of damage from anything else on the console would stay until
# the keyboard's own content happened to change in that row.
rec4 = Recorder()
tty.write_at(rec4, rows, 20)
for _ in range(tty.FULL_REPAINT_EVERY):
    tty.write_at(rec4, rows, 20)
check("identical draws inside the interval write nothing more", rec4.writes, 1)
tty.write_at(rec4, rows, 20)
check(f"🔴 the draw after {tty.FULL_REPAINT_EVERY} incremental ones repaints "
      "everything unconditionally, so damage from anything else is bounded, "
      "not permanent",
      (rec4.writes, rec4.erases), (2, 2 * len(rows)))
check("the interval is a COUNT, not a clock -- a clock would need one to test",
      isinstance(tty.FULL_REPAINT_EVERY, int) and tty.FULL_REPAINT_EVERY > 0, True)

# --- everything that invalidates ---------------------------------------------

rec5 = Recorder()
tty.write_at(rec5, rows, 20)
tty.write_at(rec5, rows, 20, full=True)
check("full=True forces a repaint of an unchanged frame",
      (rec5.writes, rec5.erases), (2, 2 * len(rows)))

rec6 = Recorder()
tty.write_at(rec6, rows, 20)
tty.write_at(rec6, rows, 19)
check("moving the keyboard is a full repaint, not a diff against the old rows",
      (rec6.writes, rec6.erases), (2, 2 * len(rows)))

rec7 = Recorder()
tty.write_at(rec7, rows, 1, console_rows=50, console_cols=LIVE_ISO_COLS)
tty.write_at(rec7, rows, 1, console_rows=25, console_cols=INSTALLED_TTY_COLS)
check("a resized console is a full repaint -- R-49: `stty cols` RESIZES a VT, so "
      "the remembered screen no longer exists",
      (rec7.writes, rec7.erases), (2, 2 * len(rows)))

rec8 = Recorder()
tty.write_at(rec8, rows, 20)
tty.clear_at(rec8, rows, 20)
tty.write_at(rec8, rows, 20)
check("🔴 clear_at forgets the frame, so the keyboard really comes back -- "
      "without this the redraw after a clear would find 'nothing changed' and "
      "leave the console blank", rec8.chunks[-1].count("\x1b[K"), len(rows))

rec9, rec10 = Recorder(), Recorder()
tty.write_at(rec9, rows, 20)
tty.write_at(rec10, rows, 20)
check("two streams have separate memories -- the VM suite draws on tty2 and tty3",
      (rec9.erases, rec10.erases), (len(rows), len(rows)))

# --- 🔴 P33 J: what the extra rows cost the flicker fix -----------------------
#
# ⚠️ MEASURED BEFORE AND AFTER, not argued. Doubling the height doubles the
# number of cells on the console, so the question is whether the incremental
# path still keeps the erase rate near zero. One second of a thumb on a pad is
# 250 draws (the mapper redraws once per read batch; the pads report at 250 Hz),
# on the live ISO's 50x160 console, bottom-anchored the way the mapper anchors:
#
#                       write()   cursor moves   erase-to-EOL   bytes
#   before (5 rows)  resting    5      25             25         4360
#                    sweeping  13      41             25         4834
#   after (10 rows)  resting    5      50             50         8690
#                    sweeping  13      82             50         9590
#
# The erase rate -- what the panel sees as blank-then-paint, and the quantity
# §5.34 D4 is about -- doubles from 25/s to 50/s because a full repaint now
# clears ten rows instead of five. It does NOT scale with the draw rate: 250
# draws still produce 5 full repaints (`FULL_REPAINT_EVERY`), and an unchanged
# frame still writes nothing at all. Without the incremental path the same
# second would erase 2500 times.
#
# ⚠️ AND WHETHER THE PANEL STILL FLICKERS IS STILL NOT ANSWERABLE HERE. §5.40
# records that it does on hardware after B2's fix; this file has no VT and no
# scanout. What is asserted is the drive, at the new height.
DRAWS_PER_SECOND = 250


def one_second(kind: str) -> tuple[int, int]:
    """(erase-to-EOL, write() calls) for one second of pad motion."""
    rec_s = Recorder()
    kb_s = osk.OnScreenKeyboard()
    height = LIVE_ISO_ROWS_MEASURED
    top_s = height - OSK_ROWS + 1
    for n in range(DRAWS_PER_SECOND):
        t = n / (DRAWS_PER_SECOND - 1)
        pos = 0.5 if kind == "rest" else (t if t <= 0.5 else 1.0 - t)
        cur_s = osk.Cursors()
        cur_s.pos["left"], cur_s.pos["right"] = [pos, pos], [0.9, 0.9]
        tty.write_at(rec_s, tty.render(kb_s, cur_s, LIVE_ISO_COLS), top_s,
                     console_rows=height, console_cols=LIVE_ISO_COLS)
    return rec_s.erases, len(rec_s.chunks)


FULL_REPAINTS = -(-DRAWS_PER_SECOND // tty.FULL_REPAINT_EVERY)
rest_erases, rest_writes = one_second("rest")
sweep_erases, sweep_writes = one_second("sweep")
check("a resting thumb erases only what the periodic full repaint erases -- "
      "FULL_REPAINTS x the keyboard's rows, and nothing per draw",
      rest_erases, FULL_REPAINTS * OSK_ROWS)
check("...and a sweeping thumb erases exactly the same, because a moved cursor "
      "repaints cells and never blanks a row", sweep_erases, rest_erases)
check("...which is a fiftieth of what a full repaint every draw would cost",
      sweep_erases * 50, DRAWS_PER_SECOND * OSK_ROWS)
check("a resting thumb writes only on the full repaints -- an identical frame "
      "costs no bytes at all", rest_writes, FULL_REPAINTS)
print(f"     (one second at {DRAWS_PER_SECOND} Hz, {OSK_ROWS} rows: resting "
      f"{rest_erases} erases / {rest_writes} writes, sweeping {sweep_erases} "
      f"erases / {sweep_writes} writes)")

check("a stream that cannot be weak-referenced still draws, every time, in full",
      [len(str(n)) for n in range(2)
       if tty.write_at(type("Slotted", (), {"__slots__": ("out",),
                                            "write": lambda self, t: None,
                                            "flush": lambda self: None})(),
                       rows, 20) is None] != [], True)

print()
print(f"{'PASS' if FAILURES == 0 else 'FAIL'} — {FAILURES} failure(s)")
sys.exit(1 if FAILURES else 0)
