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
      ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"])
check("the home row reads asdfg / hjkl + backspace",
      labels(plain.split("\n")[2]),
      ["a", "s", "d", "f", "g", "h", "j", "k", "l", "back"])
check("the function row carries shift, the layer key, tab, space and close",
      labels(plain.split("\n")[4]), ["shift", "?#=", "tab", "space", "close"])

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
check("the left cursor brackets the key it is over",
      tty.cell_text("1", tty.KEY_CELL, True) in plain, True)
check("the right cursor brackets its own key",
      tty.cell_text("0", tty.KEY_CELL, True) in plain, True)
check("exactly two keys are highlighted -- one per half",
      sum(1 for row in rows for _, hot in row if hot), 2)

# Independence again, at the render layer: moving one cursor must not move the
# other's highlight. Session 17's lesson was that shared state looks fine until
# both sources move.
cur.update(e.ABS_HAT0X, MAX)   # left cursor moves to the right edge of ITS half
cur.update(e.ABS_HAT0Y, MAX)
plain = tty.to_plain(tty.render(kb, cur))
check("moving the left cursor moved its highlight",
      tty.cell_text("5", tty.KEY_CELL, True) in plain, True)
check("and left the right cursor's highlight alone",
      tty.cell_text("0", tty.KEY_CELL, True) in plain, True)
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

buf = io.StringIO()
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
