#!/usr/bin/env python3
"""Unit tests for the TTY renderer (T8 step 4).

No console, no VM, no root. Run directly:

    python3 test-deck-osk-tty.py

The renderer's whole job is that WHAT IS DRAWN matches WHAT IS PRESSED. Most of
what follows asserts that correspondence rather than the appearance, because
appearance is the part a human notices immediately and correspondence is the
part that silently types the wrong character.
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

    ⚠️ Pinning WHICH guard fired, not just that something blew up. Removing the
    ragged-layer check survived a plain `raises()`: without it the render walks
    off the end of the shorter half and throws IndexError, so a test that only
    asked "did it raise" passed with the guard deleted. Session 16 recorded the
    same lesson about exit codes -- two guards sharing one signal make an
    assertion pass with either one gone.
    """
    try:
        fn()
    except kind as exc:
        return all(fragment in str(exc) for fragment in fragments)
    except Exception:
        return False
    return False


MIN, MAX = osk.PAD_RANGE


def fresh():
    return osk.OnScreenKeyboard(), osk.Cursors()


# --- cell_text: highlighted and plain must be the same width -----------------
#
# A highlight that changed the width would shift every key to its right as a
# cursor moved, which reads as the whole keyboard twitching.

check("a plain cell is exactly the requested width", len(tty.cell_text("q", 5, False)), 5)
check("a highlighted cell is the SAME width", len(tty.cell_text("q", 5, True)), 5)
check("a plain cell centres its label", tty.cell_text("q", 5, False), "  q  ")
check("a highlighted cell brackets it", tty.cell_text("q", 5, True), "[ q ]")
check("a wide key uses its whole span", len(tty.cell_text("space", 15, False)), 15)
check("a highlighted wide key too", len(tty.cell_text("space", 15, True)), 15)
check("an over-long label is truncated, not allowed to overflow",
      len(tty.cell_text("enormous", 5, False)), 5)
check("an over-long label is truncated when highlighted too",
      len(tty.cell_text("enormous", 5, True)), 5)

# ⚠️ NO LABEL MAY EVER BE TRUNCATED ON SCREEN.
#
# This caught a real defect: at KEY_CELL=5 the brackets left three columns, so
# `enter` drew as `[ent]` and `right` as `[rig]` -- and only while the cursor
# was ON them, which is the one moment the label has to be readable. Truncation
# is silent by nature, so it gets an invariant rather than a spot check.
truncated = []
for layer in osk.LAYERS.values():
    for half in ("left", "right"):
        for row in layer.half(half):
            for key in row:
                for state in ("off", "once", "locked"):
                    probe = osk.OnScreenKeyboard(layer.name)
                    probe.shift = state
                    label = probe.face(key)
                    for hot in (False, True):
                        drawn = tty.cell_text(label, key.span * tty.KEY_CELL, hot)
                        if label not in drawn:
                            truncated.append((layer.name, label, key.span, hot, drawn))
check("no key label is ever truncated, at any span or shift state", truncated, [])

# --- T8 §9: shifted-symbol legends and controller-glyph hints, degraded ------
#
# ⚠️ SAME INVARIANT AS ABOVE, EXTENDED TO THE COMPOSITE TEXT AND TO BOTH
# WIDTHS A KEY IS EVER DRAWN AT. `display_label` is what `render()` actually
# feeds to `cell_text()` now, and it is the one that could overflow --
# `kb.face(key)` alone cannot, by the invariant just checked above, but
# pasting a hint or a second legend onto it can. `display_label` returns ONE
# string regardless of highlight state (see its own docstring for why), so
# this checks that string against BOTH budgets it will ever be centred into.
truncated_composite = []
for layer in osk.LAYERS.values():
    for half in ("left", "right"):
        for row in layer.half(half):
            for key in row:
                for state in ("off", "once", "locked"):
                    probe = osk.OnScreenKeyboard(layer.name)
                    probe.shift = state
                    text = tty.display_label(probe, key)
                    width = key.span * tty.KEY_CELL
                    for hot, available in ((False, width), (True, width - 2)):
                        if len(text) > available:
                            truncated_composite.append(
                                (layer.name, key.label, state, hot, text, available))
check("the composite display text never exceeds its cell, at any span, "
      "shift state, or highlight state", truncated_composite, [])

# No key may carry both a shifted-symbol legend and a controller hint -- the
# format only has room for one, and `display_label` prefers the legend, which
# would silently swallow a hint on a key that happened to have both.
both = [key.label for layer in osk.LAYERS.values()
        for half in ("left", "right") for row in layer.half(half) for key in row
        if key.shift_label and not key.is_letter and key.hint]
check("no key has both a shift_label and a hint", both, [])

# Hints must name the trigger that ACTUALLY fires the key -- the half it is
# drawn in, in every layer it appears in. A hint naming the wrong trigger
# would be confidently wrong, which T8 §9's request singles out as worse than
# no hint at all. Scoped to hint_shape == RECT: HINT_SPACE (T8 §9f) is a
# face-button shortcut, not a trigger, so it has no "half" to agree with.
HINT_TO_HALF = {osk.HINT_LEFT: "left", osk.HINT_RIGHT: "right"}
mislabelled_hints = []
for layer in osk.LAYERS.values():
    for half in ("left", "right"):
        for row in layer.half(half):
            for key in row:
                if (key.hint and key.hint_shape == osk.HINT_SHAPE_RECT
                        and HINT_TO_HALF.get(key.hint) != half):
                    mislabelled_hints.append((layer.name, half, key.label, key.hint))
check("every trigger hint names the trigger for the half it is actually "
      "drawn in", mislabelled_hints, [])
check("shift is hinted for the LEFT trigger", osk.SHIFT_KEY.hint, osk.HINT_LEFT)
check("backspace is hinted for the RIGHT trigger", osk.BACKSPACE_KEY.hint, osk.HINT_RIGHT)
check("enter is hinted for the RIGHT trigger", osk.ENTER_KEY.hint, osk.HINT_RIGHT)
check("space is hinted with the Y face-button badge, not a trigger",
      (osk.SPACE_KEY.hint, osk.SPACE_KEY.hint_shape),
      (osk.HINT_SPACE, osk.HINT_SHAPE_CIRCLE))

# --- display_label: exact composition ------------------------------------

kb2, cur2 = fresh()
digit_1 = osk.key_at(osk.LETTERS, "left", 0.1, 0.1)   # "1"
check("a digit shows its shifted symbol beside it",
      tty.display_label(kb2, digit_1), "1 !")

check("shift shows its trigger hint -- it fits (span 2, plenty of room)",
      tty.display_label(kb2, osk.SHIFT_KEY), "Lshift")
check("backspace shows its trigger hint -- it fits EXACTLY (4 + 1 = 5)",
      tty.display_label(kb2, osk.BACKSPACE_KEY), "Rback")
check("enter shows NO hint -- 'Renter' is 6 characters and the highlighted "
      "budget is 5; 'enter' alone already fills it",
      tty.display_label(kb2, osk.ENTER_KEY), "enter")
check("space shows its Y face-button hint (T8 §9f) -- 'Yspace' is 6 "
      "characters and space's own highlighted budget (span 3) is 19",
      tty.display_label(kb2, osk.SPACE_KEY), "Yspace")

kb2.press_at("left", 0.1, 0.9)   # shift -> once
check("the hint survives a shift-state change -- it names a button, not a face",
      tty.display_label(kb2, osk.SHIFT_KEY), "LShift")

# A key with neither a shift_label nor a hint (e.g. tab) is unaffected --
# display_label must not invent decoration for a plain key.
check("a plain key with no legend and no hint is unaffected",
      tty.display_label(kb2, osk.TAB_KEY), "tab")

# ⚠️ THE PROPERTY THIS WHOLE REDESIGN EXISTS FOR: cell_text()'s FACE (brackets
# stripped) must be identical whether or not a key happens to be highlighted,
# or `rows_on_screen` cannot tell a moved highlight from a damaged row -- see
# "the highlight having moved does not lose a row" below, and
# `display_label`'s own docstring for the defect this reproduces directly.
for probed in (digit_1, osk.SHIFT_KEY, osk.BACKSPACE_KEY, osk.ENTER_KEY,
               osk.SPACE_KEY, osk.TAB_KEY):
    text = tty.display_label(kb2, probed)
    width = probed.span * tty.KEY_CELL
    cold_face = tty.face_of(tty.cell_text(text, width, False))
    hot_face = tty.face_of(tty.cell_text(text, width, True))
    check(f"{probed.label}'s face is byte-identical whether or not it is "
          "highlighted", cold_face, hot_face)

# --- the rendered grid --------------------------------------------------------

kb, cur = fresh()
rows = tty.render(kb, cur)
check("the letters layer renders five rows", len(rows), 5)
check("every row is the same width",
      len({sum(len(t) for t, _ in row) for row in rows}), 1)
check("width is two halves of five cells plus the gutter",
      tty.width(rows), 5 * tty.KEY_CELL * 2 + tty.GUTTER)
check("it fits in an 80-column console", tty.width(rows) <= 80, True)

plain = tty.to_plain(rows)


def labels(line: str) -> list[str]:
    """Labels on a rendered line, with the highlight brackets stripped.

    Both cursors start centred, so two cells are always bracketed; splitting
    raw text would read `[ d ]` as three tokens.
    """
    return line.replace("[", " ").replace("]", " ").split()


check("the top row carries both halves' digits, gutter between",
      labels(plain.split("\n")[0]),
      # Cold, so each digit carries its shifted symbol beside it (T8 §9) --
      # `labels()` splits on the internal space, so each digit is its own
      # token followed by its symbol's.
      ["1", "!", "2", "@", "3", "#", "4", "$", "5", "%",
       "6", "^", "7", "&", "8", "*", "9", "(", "0", ")"])
check("the home row reads asdfg / hjkl + backspace, hinted",
      labels(plain.split("\n")[2]),
      ["a", "s", "d", "f", "g", "h", "j", "k", "l", "Rback"])
check("the function row carries shift (hinted), the layer key, tab, "
      "space (Y-hinted, T8 §9f) and close",
      labels(plain.split("\n")[4]), ["Lshift", "?#=", "tab", "Yspace", "close"])

# Both halves must be present on every line, or one thumb has nothing to drive.
check("every rendered line spans both halves",
      all(len(line) == tty.width(rows) for line in plain.split("\n")), True)

# --- the highlight follows the cursor, and marks exactly one key per half -----

kb, cur = fresh()
cur.update(e.ABS_HAT0X, MIN)   # left pad: top-left -> "1"
cur.update(e.ABS_HAT0Y, MAX)
cur.update(e.ABS_HAT1X, MAX)   # right pad: top-right -> "0"
cur.update(e.ABS_HAT1Y, MAX)
rows = tty.render(kb, cur)
plain = tty.to_plain(rows)
# Digits carry their shifted symbol beside them now (T8 §9), in every state --
# see display_label's docstring -- so the drawn cell is "1 !"/"0 )", not a
# bare digit; `key_at` is the independent source for what that composite is.
key_1 = osk.key_at(osk.LETTERS, "left", 0.0, 0.0)
key_0 = osk.key_at(osk.LETTERS, "right", 1.0, 0.0)
key_5 = osk.key_at(osk.LETTERS, "left", 1.0, 0.0)
check("the left cursor brackets the key it is over",
      tty.cell_text(tty.display_label(kb, key_1), tty.KEY_CELL, True) in plain, True)
check("the right cursor brackets its own key",
      tty.cell_text(tty.display_label(kb, key_0), tty.KEY_CELL, True) in plain, True)
check("exactly two keys are highlighted -- one per half",
      sum(1 for row in rows for _, hot in row if hot), 2)

# Independence again, at the render layer: moving one cursor must not move the
# other's highlight. Session 17's lesson was that shared state looks fine until
# both sources move.
cur.update(e.ABS_HAT0X, MAX)   # left cursor moves to the right edge of ITS half
cur.update(e.ABS_HAT0Y, MAX)
plain = tty.to_plain(tty.render(kb, cur))
check("moving the left cursor moved its highlight",
      tty.cell_text(tty.display_label(kb, key_5), tty.KEY_CELL, True) in plain, True)
check("and left the right cursor's highlight alone",
      tty.cell_text(tty.display_label(kb, key_0), tty.KEY_CELL, True) in plain, True)
check("still exactly two highlights",
      sum(1 for row in tty.render(kb, cur) for _, hot in row if hot), 2)

# --- ⚠️ THE PROPERTY THAT MATTERS: drawn == pressed --------------------------
#
# Every cell that renders highlighted must be the cell a press at that cursor
# actually types. A renderer and a hit test that disagree produce a keyboard
# that types a different character from the one lit up -- and both halves pass
# their own tests. Swept over the whole pad, both axes moving together.

mismatches = []
for layer_name in ("letters", "symbols"):
    for xi in range(0, 21):
        for yi in range(0, 21):
            kb = osk.OnScreenKeyboard(layer_name)
            cur = osk.Cursors()
            vx = MIN + (MAX - MIN) * xi // 20
            vy = MIN + (MAX - MIN) * yi // 20
            # 0 is the lift sentinel; nudge off it so the cursor actually moves.
            vx = vx or 1
            vy = vy or 1
            for half, ax, ay in (("left", e.ABS_HAT0X, e.ABS_HAT0Y),
                                 ("right", e.ABS_HAT1X, e.ABS_HAT1Y)):
                cur.update(ax, vx)
                cur.update(ay, vy)
                rendered = tty.render(kb, cur)
                located = kb.locate(half, *cur.position(half))
                key = kb.key_at(half, *cur.position(half))
                if located is None or key is None:
                    mismatches.append((layer_name, half, xi, yi, "no key under cursor"))
                    continue
                # The highlighted cell's text must contain that key's face.
                hot = [text for row in rendered for text, on in row if on]
                want = kb.face(key)
                if not any(want in cell for cell in hot):
                    mismatches.append((layer_name, half, xi, yi, want, hot))
check("every highlighted cell is the key a press there would type", mismatches, [])

# --- the shift key reports its own state --------------------------------------
#
# Without this a user cannot tell one-shot from locked, and the only feedback is
# typing a character and seeing the wrong case.

kb, cur = fresh()
check("shift reads 'shift' when off", "shift" in tty.to_plain(tty.render(kb, cur)), True)
kb.press_at("left", 0.1, 0.9)
check("one-shot changes the shift key's face",
      "Shift" in tty.to_plain(tty.render(kb, cur)), True)
kb.press_at("left", 0.1, 0.9)
check("caps lock changes it again",
      "LOCK" in tty.to_plain(tty.render(kb, cur)), True)
check("and the letters are drawn capitalised with it",
      tty.cell_text("Q", tty.KEY_CELL, False) in tty.to_plain(tty.render(kb, cur)), True)
kb.press_at("left", 0.1, 0.9)
check("a third press returns it to 'shift'",
      "LOCK" not in tty.to_plain(tty.render(kb, cur)), True)

# --- layers -------------------------------------------------------------------

kb, cur = fresh()
kb.press_at("left", 0.5, 0.9)   # -> symbols
rows = tty.render(kb, cur)
check("the symbols layer renders four rows", len(rows), 4)
check("and shows the punctuation", "\\" in tty.to_plain(rows), True)
check("and the way back", "abc" in tty.to_plain(rows), True)
check("rows stay the same width across layers",
      len({sum(len(t) for t, _ in row) for row in rows}), 1)

# A layer whose halves disagree on row count cannot line up on screen, and
# rendering it ragged would hide the layout bug.
broken = osk.Layer(name="broken", left=osk.LETTERS.left, right=osk.SYMBOLS.right)
kb_broken = osk.OnScreenKeyboard()
osk.LAYERS["broken"] = broken
kb_broken.layer_name = "broken"
check("a layer with mismatched halves raises ValueError, naming both row counts",
      raises_saying(lambda: tty.render(kb_broken, osk.Cursors()),
                    ValueError, "broken", "5", "4"), True)
del osk.LAYERS["broken"]

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
rows = tty.render(*fresh())
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

# --- the out-of-bounds guard (R-49) ------------------------------------------
#
# ⚠️ Without it the kernel clamps every row that falls past the end of the
# console onto the LAST line, where they overwrite each other -- measured in
# QEMU as five keyboard rows collapsing into one garbled line that still greps
# as a keyboard. Silent, and worse than an error.

buf = io.StringIO()
tty.write_at(buf, rows, 20, console_rows=24)
check("a draw that fits is unaffected by the guard", "\x1b[20;1H" in buf.getvalue(), True)
check("a draw running off the end refuses",
      raises_saying(lambda: tty.write_at(io.StringIO(), rows, 21, console_rows=24),
                    ValueError, "21", "24"), True)
check("and so does one starting above the first row",
      raises(lambda: tty.write_at(io.StringIO(), rows, 0, console_rows=24), ValueError), True)
check("the last row that fits exactly is allowed",
      (tty.write_at(io.StringIO(), rows, 24 - len(rows) + 1, console_rows=24), True)[1], True)
check("with no console_rows given, nothing is checked -- callers opt in",
      (tty.write_at(io.StringIO(), rows, 9999), True)[1], True)

# --- rows_on_screen: COUNT the rows, never grep for a word (R-49, R-52) ------
#
# ⚠️ This is the assertion primitive both failures needed and neither had.
# R-49: `stty rows` shrank the console, the kernel clamped all five keyboard
# rows onto the last line, and the garbled result still contained `shift`.
# R-52: a full-screen curses TUI repainted every line but the last, leaving
# exactly the function row -- which is the row `shift` is on. Both look like a
# keyboard to a substring check. Only the count tells them apart.

kb, cur = fresh()
rows = tty.render(kb, cur)
KB_WIDTH = tty.width(rows)
CONSOLE_W, CONSOLE_H = 80, 25


def console(lines: dict[int, str]) -> str:
    """A `CONSOLE_H` x `CONSOLE_W` screen, as /dev/vcsN folded gives it."""
    return "\n".join(lines.get(n, "").ljust(CONSOLE_W)[:CONSOLE_W]
                     for n in range(1, CONSOLE_H + 1))


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
check("...while the word `shift` is still right there on it -- the lie",
      "shift" in clamped, True)

# ⚠️ R-52's EXACT SHAPE, measured in QEMU. A full-screen TUI repaints every
# line except the console's last, so four keyboard rows die and the function
# row lives. Same lie, different cause.
partial = drawn_at(CONSOLE_H - len(rows) + 1)
for line in range(1, CONSOLE_H):
    partial[line] = f"MENU LINE {line:02d} PASS 01 " + "-" * 50
check("a TUI repainting all but the last line leaves ONE row",
      len(tty.rows_on_screen(console(partial), rows)), 1)
check("...and that surviving row still carries `shift`", "shift" in console(partial), True)

# ⚠️ AND THE SHAPE THE MEASUREMENT ACTUALLY TOOK, which is nastier than the one
# above and was not the one predicted. ncurses repaints by diffing against its
# own model of the physical screen, and that model has never heard of us -- so
# a "full repaint" rewrote only the cells whose content changed and punched a
# SINGLE CHARACTER through each keyboard row. Every row still reads as a
# keyboard to a human and to a grep; one key per row now types something other
# than what it draws.
punched = drawn_at(20)
for line in range(20, 25):
    punched[line] = punched[line][:17] + "1" + punched[line][18:]
check("one character punched through each row leaves NO intact row",
      tty.rows_on_screen(console(punched), rows), [])
check("...while `shift` is still on the screen, untouched",
      "shift" in console(punched), True)
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

# Partial damage is the whole point: one overwritten cell is not a row.
damaged = drawn_at(20)
damaged[22] = "XXXXXXX" + damaged[22][7:]
check("a row with its FIRST cell overwritten does not count",
      tty.rows_on_screen(console(damaged), rows), [20, 21, 23, 24])

# ⚠️ And the last cell too, separately. A check that stopped after the first
# cell would pass the test above and miss a keyboard whose right-hand half a
# TUI had eaten -- which is half the screen, and the half `enter` is on.
tail_damaged = drawn_at(20)
tail_damaged[22] = tail_damaged[22][:KB_WIDTH - 7] + "XXXXXXX"
check("a row with its LAST cell overwritten does not count either",
      tty.rows_on_screen(console(tail_damaged), rows), [20, 21, 23, 24])

# The keyboard is 73 columns; the other 7 are not its business.
beside = drawn_at(20)
beside[22] = beside[22][:KB_WIDTH].ljust(KB_WIDTH) + " TUI"
check("text to the RIGHT of the keyboard does not disqualify the row",
      tty.rows_on_screen(console(beside), rows), [20, 21, 22, 23, 24])

# A console too narrow to hold a row truncates it, and a truncated row must not
# be padded back into a match -- that would invent a keyboard that is not there.
narrow = "\n".join(tty.to_plain(rows).split("\n")[i][:KB_WIDTH - 1] for i in range(len(rows)))
check("a row cut off by a narrow console does not count",
      tty.rows_on_screen(narrow, rows), [])

# Offsets. A row found on line 1 must report 1, not 0.
check("line numbering is 1-based, like every console coordinate here",
      tty.rows_on_screen(console(drawn_at(1)), rows), [1, 2, 3, 4, 5])

# The symbols layer puts `[` and `]` on real keys, which is exactly where a
# naive "strip the highlight brackets" reader goes wrong.
kb_sym, cur_sym = fresh()
kb_sym.press_at("left", 0.5, 0.9)
sym_rows = tty.render(kb_sym, cur_sym)
check("the symbols layer round-trips too, bracket keys and all",
      tty.rows_on_screen(console(drawn_at(20, sym_rows)), sym_rows), [20, 21, 22, 23])
check("a bracket KEY reads as its face, not as an empty highlight",
      tty.face_of(tty.cell_text("[", tty.KEY_CELL, False)), "[")
check("and so does a highlighted one",
      tty.face_of(tty.cell_text("[", tty.KEY_CELL, True)), "[")
check("a highlighted cell and a plain one report the same face",
      tty.face_of(tty.cell_text("space", 15, True)),
      tty.face_of(tty.cell_text("space", 15, False)))

# ⚠️ A HIGHLIGHT IS BOTH BRACKETS OR IT IS NOT A HIGHLIGHT. One of them is
# somebody else's, and TUIs draw brackets constantly -- `[x]` checkboxes, `[1]`
# menu indices. Unwrapping on either bracket alone would let a row a TUI had
# half-eaten read back as intact, which is precisely the false pass this whole
# section exists to prevent.
check("a stray closing bracket does not make a cell a highlight",
      tty.face_of("X  q  ]"), "X  q  ]")
check("nor does a stray opening one", tty.face_of("[  q  X"), "[  q  X")
half_bracketed = drawn_at(20)
half_bracketed[22] = "X" + half_bracketed[22][1:KB_WIDTH - 1] + "]"
check("a row whose ends a TUI replaced with brackets does not count",
      tty.rows_on_screen(console(half_bracketed), rows), [20, 21, 23, 24])
# Cross-layer: only the digits row is shared between the two layers, so a
# symbols screen read against the letters render must find that one row and no
# other. Both halves matter -- `[20]` alone would also be produced by a matcher
# that had stopped looking after the first hit.
check("a symbols screen read against the letters render finds only the shared digits row",
      tty.rows_on_screen(console(drawn_at(20, sym_rows)), rows), [20])
check("...and that row really is identical between the layers",
      tty.to_plain(sym_rows).split("\n")[0], tty.to_plain(rows).split("\n")[0])
check("...while the rows below it are not",
      tty.to_plain(sym_rows).split("\n")[1] == tty.to_plain(rows).split("\n")[1], False)

buf = io.StringIO()
kb, cur = fresh()
rows = tty.render(kb, cur)
tty.clear_at(buf, rows, 19)
cleared = buf.getvalue()
check("clearing erases one line per rendered row", cleared.count("\x1b[K"), len(rows))
# Not `"[" in cleared` -- every escape sequence contains one. Assert on the
# thing that actually matters: no key face survives the clear.
check("clearing writes no key label", any(lab in cleared for lab in ("shift", "space", "q")), False)
check("clearing also restores the cursor", cleared.endswith("\x1b[u"), True)

print()
print(f"{'PASS' if FAILURES == 0 else 'FAIL'} — {FAILURES} failure(s)")
sys.exit(1 if FAILURES else 0)
