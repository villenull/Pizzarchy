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
"""

from __future__ import annotations

import importlib.util
import io
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
misplaced = []
for layer in osk.LAYERS.values():
    kb_l = osk.OnScreenKeyboard(layer.name)
    rendered = tty.render(kb_l, osk.Cursors())
    for row_index, row in enumerate(layer.rows):
        column = 0
        for key_index, (start, end) in enumerate(layer.cell_bounds(row_index)):
            text = rendered[row_index][key_index][0]
            if (column != start * tty.KEY_CELL
                    or len(text) != (end - start) * tty.KEY_CELL):
                misplaced.append((layer.name, row_index, key_index, column,
                                  start * tty.KEY_CELL, len(text)))
            column += len(text)
check("every key is drawn at the column Layer.cell_bounds puts it, contiguously",
      misplaced, [])

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
# not either; "Shift" (5) does. The word is kept as long as it can be.
narrow = osk.Key(label="Shift", action="shift", span=2, hint="L2")
check("badge dropped first when both cannot fit",
      tty.display_label(probe("once"), narrow), "Shift")
mid = osk.Key(label="Sh", action="shift", span=2, hint="L2")
check("...and with a shorter face the WORD survives while the badge is dropped",
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

# --- the rendered grid, read back as text ------------------------------------

kb, cur = fresh()
rows = tty.render(kb, cur)
plain = tty.to_plain(rows)
check("the letters layer renders five rows", len(rows), 5)
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
      labels(plain.split("\n")[0]),
      ["`", "~", "1", "!", "2", "@", "3", "#", "4", "$", "5", "%", "6", "^",
       "7", "&", "8", "*", "9", "(", "0", ")", "-", "_", "=", "+",
       "X", "Backspace"])
check("row 2 is Tab, qwertyuiop and the three bracket keys",
      labels(plain.split("\n")[1]),
      ["Tab", "q", "w", "e", "r", "t", "y", "u", "i", "o", "p",
       "{", "}", "\\", "|"])
check("row 3 is L3-badged Caps, the home row, and R2 Enter",
      labels(plain.split("\n")[2]),
      ["L3", "Caps", "a", "s", "d", "f", "g", "h", "j", "k", "l",
       ";", ":", "'", '"', "R2", "Enter"])
check("row 4 is Shift, zxcvbnm, the punctuation and Shift AGAIN on the right",
      labels(plain.split("\n")[3]),
      ["L2", "Shift", "z", "x", "c", "v", "b", "n", "m", ",", "<", ".", ">",
       "/", "?", "L2", "Shift"])
check("row 5 is the emoji key, the wide space, the two dual-legend arrows, "
      "Paste and Move",
      labels(plain.split("\n")[4]),
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
check("exactly two keys are highlighted -- one per half",
      sum(1 for row in rows for _, hot in row if hot), 2)

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
check("still exactly two highlights",
      sum(1 for row in tty.render(kb, cur) for _, hot in row if hot), 2)

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
check("two cursors on one key highlight ONE cell, not two",
      sum(1 for row in sp_rows for _, hot in row if hot), 1)
check("...and it is the space bar",
      [tty.face_of(t) for row in sp_rows for t, hot in row if hot], ["Y space"])

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
      sum(1 for row in off_rows for _, hot in row if hot), 1)

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

check("a draw that fits is unaffected by the row guard",
      "\x1b[20;1H" in (lambda b: (tty.write_at(b, rows, 20, console_rows=24),
                                  b.getvalue())[1])(io.StringIO()), True)
check("a draw running off the end refuses, naming the rows and the console",
      raises_saying(lambda: tty.write_at(io.StringIO(), rows, 21, console_rows=24),
                    ValueError, "21", "24"), True)
check("and so does one starting above the first row",
      raises(lambda: tty.write_at(io.StringIO(), rows, 0, console_rows=24), ValueError), True)
check("the last row that fits exactly is allowed",
      (tty.write_at(io.StringIO(), rows, 24 - len(rows) + 1, console_rows=24), True)[1], True)
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
      raises_saying(lambda: tty.write_at(io.StringIO(), rows, 21, console_rows=24),
                    ValueError, "wrap"), False)
check("the live ISO's 160 columns are comfortably fine",
      (tty.write_at(io.StringIO(), rows, 1, console_rows=LIVE_ISO_ROWS,
                    console_cols=LIVE_ISO_COLS), True)[1], True)
check("with no console_cols given, nothing is checked -- callers opt in",
      (tty.write_at(io.StringIO(), rows, 1, console_cols=None), True)[1], True)
check("both guards can fire on the same draw; the ROW one is checked first, so a "
      "caller learns about the more destructive failure",
      raises_saying(lambda: tty.write_at(io.StringIO(), rows, 99, console_rows=24,
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


def console(lines: dict[int, str], cols: int = CONSOLE_W, height: int = CONSOLE_H) -> str:
    """A `height` x `cols` screen, as /dev/vcsN folded gives it."""
    return "\n".join(lines.get(n, "").ljust(cols)[:cols]
                     for n in range(1, height + 1))


def drawn_at(top: int, source=None) -> dict[int, str]:
    """The keyboard painted with its first line at `top`, 1-based."""
    body = tty.to_plain(source if source is not None else rows).split("\n")
    return {top + offset: line for offset, line in enumerate(body)}


check("a clean draw is found on exactly the rows it was drawn on",
      tty.rows_on_screen(console(drawn_at(20)), rows), [20, 21, 22, 23, 24])
check("a blank console carries no keyboard rows",
      tty.rows_on_screen(console({}), rows), [])
check("neither does one full of somebody else's TUI",
      tty.rows_on_screen(console({n: f"MENU LINE {n:02d} " + "-" * 60
                                  for n in range(1, CONSOLE_H + 1)}), rows), [])

# ⚠️ R-49's EXACT SHAPE. Five rows written to one line, each overwriting the
# last -- which is what the kernel does when they fall past the end of the
# console. The word survives; the keyboard does not.
clamped = console({CONSOLE_H: tty.to_plain(rows).split("\n")[-1]})
check("R-49's clamp is ONE row, not five", len(tty.rows_on_screen(clamped, rows)), 1)
check("...while the word `space` is still right there on it -- the lie",
      "space" in clamped, True)

# ⚠️ R-52's EXACT SHAPE, measured in QEMU. A full-screen TUI repaints every
# line except the console's last, so four keyboard rows die and one lives.
partial = drawn_at(CONSOLE_H - len(rows) + 1)
for line in range(1, CONSOLE_H):
    partial[line] = f"MENU LINE {line:02d} PASS 01 " + "-" * 50
check("a TUI repainting all but the last line leaves ONE row",
      len(tty.rows_on_screen(console(partial), rows)), 1)
check("...and that surviving row still carries `space`", "space" in console(partial), True)

# ⚠️ AND THE SHAPE THE MEASUREMENT ACTUALLY TOOK, which is nastier than the one
# above. ncurses repaints by diffing against its own model of the physical
# screen, and that model has never heard of us -- so a "full repaint" rewrote
# only the cells whose content changed and punched a SINGLE CHARACTER through
# each keyboard row. Every row still reads as a keyboard to a human and to a
# grep; one key per row now types something other than what it draws.
punched = drawn_at(20)
for line in range(20, 25):
    punched[line] = punched[line][:17] + "1" + punched[line][18:]
check("one character punched through each row leaves NO intact row",
      tty.rows_on_screen(console(punched), rows), [])
check("...while `Shift` is still on the screen, untouched",
      "Shift" in console(punched), True)
check("...and each row differs from an intact one by exactly ONE character",
      sum(a != b for a, b in zip(punched[24], drawn_at(20)[24])), 1)

# The cursors move between a render and a console read. A row whose highlight
# sits elsewhere is still that row -- otherwise every count would be a race.
kb_moved, cur_moved = fresh()
cur_moved.update(e.ABS_HAT0X, MIN)
cur_moved.update(e.ABS_HAT0Y, MAX)
cur_moved.update(e.ABS_HAT1X, MAX)
cur_moved.update(e.ABS_HAT1Y, MAX)
moved = tty.render(kb_moved, cur_moved)
check("the highlight having moved does not lose a row",
      tty.rows_on_screen(console(drawn_at(20, moved)), rows), [20, 21, 22, 23, 24])
check("and the two renders really do differ, so that was not vacuous",
      tty.to_plain(moved) == tty.to_plain(rows), False)

# ⚠️ AND A SHIFT-STATE CHANGE MUST *NOT* round-trip. The legends genuinely
# differ under shift (§9g), so a screen drawn shifted is not the same keyboard
# -- if this passed, `face_of` would be throwing the legends away.
shifted_rows = tty.render(probe("locked"), osk.Cursors())
check("a shifted screen read against an unshifted render finds nothing",
      tty.rows_on_screen(console(drawn_at(20, shifted_rows)), rows), [])
check("...and against its OWN render finds every row",
      tty.rows_on_screen(console(drawn_at(20, shifted_rows)), shifted_rows),
      [20, 21, 22, 23, 24])

# Partial damage is the whole point: one overwritten cell is not a row.
FIRST_CELL = len(rows[2][0][0])
damaged = drawn_at(20)
damaged[22] = "X" * FIRST_CELL + damaged[22][FIRST_CELL:]
check("a row with its FIRST cell overwritten does not count",
      tty.rows_on_screen(console(damaged), rows), [20, 21, 23, 24])

# ⚠️ And the last cell too, separately. A check that stopped after the first
# cell would pass the test above and miss a keyboard whose right-hand half a
# TUI had eaten -- which is half the screen, and the half `Enter` is on.
LAST_CELL = len(rows[2][-1][0])
tail_damaged = drawn_at(20)
tail_damaged[22] = tail_damaged[22][:KB_WIDTH - LAST_CELL] + "X" * LAST_CELL
check("a row with its LAST cell overwritten does not count either",
      tty.rows_on_screen(console(tail_damaged), rows), [20, 21, 23, 24])

# ⚠️ Columns to the right are not the keyboard's business -- but on the
# INSTALLED TTY there are none, so this has to be checked on the LIVE ISO's
# 160-column console, which is the other geometry §7 measured.
beside = drawn_at(20)
beside[22] = beside[22][:KB_WIDTH].ljust(KB_WIDTH) + " TUI"
check("text to the RIGHT of the keyboard does not disqualify the row (live ISO, "
      "160 columns -- on the installed TTY there is no 'right of')",
      tty.rows_on_screen(console(beside, cols=LIVE_ISO_COLS), rows),
      [20, 21, 22, 23, 24])

# A console too narrow to hold a row truncates it, and a truncated row must not
# be padded back into a match -- that would invent a keyboard that is not there.
# 🔴 THIS IS THE 79-COLUMN CONSOLE, i.e. the exact thing KEY_CELL=5 has no
# slack against.
narrow = console(drawn_at(20), cols=KB_WIDTH - 1)
check("a console one column too narrow carries NO intact keyboard row",
      tty.rows_on_screen(narrow, rows), [])

# Offsets. A row found on line 1 must report 1, not 0.
check("line numbering is 1-based, like every console coordinate here",
      tty.rows_on_screen(console(drawn_at(1)), rows), [1, 2, 3, 4, 5])

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
half_bracketed = drawn_at(20)
half_bracketed[22] = "X" + half_bracketed[22][1:KB_WIDTH - 1] + "]"
check("a row whose ends a TUI replaced with brackets does not count",
      tty.rows_on_screen(console(half_bracketed), rows), [20, 21, 23, 24])

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

print()
print(f"{'PASS' if FAILURES == 0 else 'FAIL'} — {FAILURES} failure(s)")
sys.exit(1 if FAILURES else 0)
