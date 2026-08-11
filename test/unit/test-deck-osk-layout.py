#!/usr/bin/env python3
"""Unit tests for the on-screen keyboard's layout core (T8 steps 1-2).

No device, no uinput, no compositor, no root. Run directly:

    python3 test-deck-osk-layout.py

⚠️ The character expectations here are DELIBERATELY INDEPENDENT of
`src/deck_osk_layout.py`. Decoding a keystroke with the same table that
produced it proves only that the module agrees with itself: a key labelled "a"
carrying KEY_B round-trips perfectly and types the wrong letter. So letters are
resolved through evdev's own KEY_* names and the punctuation faces are written
out longhand below, from the US layout.
"""

from __future__ import annotations

import importlib.util
import pathlib
import string
import sys

from evdev import ecodes as e

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
            out.append(f"<{e.KEY[code]}>")
    return "".join(out)


def press(kb, half: str, x: float, y: float) -> str:
    """Press at a point and return what it typed, decoded."""
    return decode(kb.press_at(half, x, y))


# --- hit-testing: rows AND columns together ----------------------------------
#
# T8's first named failure mode is testing one axis at a time -- session 17's
# pointer emitted nothing on diagonal movement while every single-axis test
# passed. So every hit test below varies x and y together, and the letters
# layer's whole left half is walked cell by cell rather than sampled.

kb = osk.OnScreenKeyboard()
check("starts on the letters layer", kb.layer_name, "letters")
check("starts unshifted", kb.shift, "off")
check("starts open", kb.closed, False)

# Five rows of five, so cell centres sit at 0.1/0.3/0.5/0.7/0.9 on both axes.
CENTRES = (0.1, 0.3, 0.5, 0.7, 0.9)
LEFT_LETTERS = ("12345", "qwert", "asdfg", "zxcvb")
for r, expected_row in enumerate(LEFT_LETTERS):
    got = "".join(
        osk.key_at(osk.LETTERS, "left", cx, CENTRES[r]).label for cx in CENTRES
    )
    check(f"letters/left row {r} reads across", got, expected_row)

RIGHT_LETTERS = ("67890", "yuiop", "hjkl", "nm,.")
for r, expected_row in enumerate(RIGHT_LETTERS):
    got = "".join(
        osk.key_at(osk.LETTERS, "right", cx, CENTRES[r]).label
        for cx in CENTRES[: len(expected_row)]
    )
    check(f"letters/right row {r} reads across", got, expected_row)

check("letters/right row 2 ends in backspace",
      osk.key_at(osk.LETTERS, "right", 0.9, 0.5).label, "back")
check("letters/right row 3 ends in enter",
      osk.key_at(osk.LETTERS, "right", 0.9, 0.7).label, "enter")

# --- span arithmetic, which is where a hit test actually goes wrong ----------
#
# The function row is shift(2) + layer(2) + tab(1) on the left and space(3) +
# close(2) on the right. Equal-width column maths passes every test above and
# fails every one of these.

FN_Y = 0.9
check("fn row: x=0.00 is shift", osk.key_at(osk.LETTERS, "left", 0.00, FN_Y).label, "shift")
check("fn row: x=0.30 is still shift", osk.key_at(osk.LETTERS, "left", 0.30, FN_Y).label, "shift")
check("fn row: x=0.39 is the last shift cell",
      osk.key_at(osk.LETTERS, "left", 0.39, FN_Y).label, "shift")
check("fn row: x=0.41 crosses into the layer key",
      osk.key_at(osk.LETTERS, "left", 0.41, FN_Y).label, "?#=")
check("fn row: x=0.79 is the last layer cell",
      osk.key_at(osk.LETTERS, "left", 0.79, FN_Y).label, "?#=")
check("fn row: x=0.81 crosses into tab",
      osk.key_at(osk.LETTERS, "left", 0.81, FN_Y).label, "tab")
check("fn row: right x=0.59 is space",
      osk.key_at(osk.LETTERS, "right", 0.59, FN_Y).label, "space")
check("fn row: right x=0.61 is close",
      osk.key_at(osk.LETTERS, "right", 0.61, FN_Y).label, "close")

# Edges. The last row and column own their closing edge, so a cursor pinned to
# the corner of its half lands on a key rather than nothing.
check("x=1.0 lands on the last column, not off the end",
      osk.key_at(osk.LETTERS, "left", 1.0, 0.1).label, "5")
check("y=1.0 lands on the last row, not off the end",
      osk.key_at(osk.LETTERS, "left", 0.0, 1.0).label, "shift")
check("bottom-right corner of the left half is tab",
      osk.key_at(osk.LETTERS, "left", 1.0, 1.0).label, "tab")
check("top-left corner of the left half is 1",
      osk.key_at(osk.LETTERS, "left", 0.0, 0.0).label, "1")
check("x below range misses", osk.key_at(osk.LETTERS, "left", -0.01, 0.5), None)
check("x above range misses", osk.key_at(osk.LETTERS, "left", 1.01, 0.5), None)
check("y below range misses", osk.key_at(osk.LETTERS, "left", 0.5, -0.01), None)
check("y above range misses", osk.key_at(osk.LETTERS, "left", 0.5, 1.01), None)

# Row boundaries are exact: at four rows the symbols layer's rows are 0.25 tall,
# so a hit test that assumed five rows everywhere lands one row off here.
check("symbols layer has four rows", len(osk.SYMBOLS.left), 4)
check("symbols/left y=0.26 is row 1, not row 0",
      osk.key_at(osk.SYMBOLS, "left", 0.1, 0.26).label, "-")
check("symbols/left y=0.24 is still row 0",
      osk.key_at(osk.SYMBOLS, "left", 0.1, 0.24).label, "1")
check("symbols/left row 1 reads across",
      "".join(osk.key_at(osk.SYMBOLS, "left", cx, 0.3).label for cx in CENTRES),
      "-=[]\\")
check("symbols/right row 1 reads across",
      "".join(osk.key_at(osk.SYMBOLS, "right", cx, 0.3).label for cx in CENTRES),
      ";'`,.")
check("symbols/left row 2 is / plus the arrows",
      [osk.key_at(osk.SYMBOLS, "left", cx, 0.6).label for cx in CENTRES],
      ["/", "left", "up", "down", "right"])
check("symbols/right row 2 is the editing keys",
      [osk.key_at(osk.SYMBOLS, "right", cx, 0.6).label for cx in CENTRES],
      ["home", "end", "del", "back", "enter"])


def raises(fn) -> bool:
    """Did calling fn() raise ValueError? Silence here would be the bug."""
    try:
        fn()
    except ValueError:
        return True
    return False


check("an unknown half raises rather than guessing a side",
      raises(lambda: osk.key_at(osk.LETTERS, "middle", 0.5, 0.5)), True)
check("an unknown initial layer raises",
      raises(lambda: osk.OnScreenKeyboard("dvorak")), True)


# --- typing, decoded independently -------------------------------------------

kb = osk.OnScreenKeyboard()
check("pressing q types q", press(kb, "left", 0.1, 0.3), "q")
check("pressing p types p", press(kb, "right", 0.9, 0.3), "p")
check("pressing 5 types 5", press(kb, "left", 0.9, 0.1), "5")
check("space types a space", press(kb, "right", 0.3, 0.9), " ")
check("tab emits KEY_TAB", kb.press_at("left", 0.9, 0.9), [(e.KEY_TAB, 1), (e.KEY_TAB, 0)])
check("backspace emits KEY_BACKSPACE",
      kb.press_at("right", 0.9, 0.5), [(e.KEY_BACKSPACE, 1), (e.KEY_BACKSPACE, 0)])
check("enter emits KEY_ENTER",
      kb.press_at("right", 0.9, 0.7), [(e.KEY_ENTER, 1), (e.KEY_ENTER, 0)])
check("a typed key is a full press AND release",
      kb.press_at("left", 0.1, 0.3), [(e.KEY_Q, 1), (e.KEY_Q, 0)])
check("a miss types nothing", kb.press(None), [])

# --- shift: the three states ---------------------------------------------------

kb = osk.OnScreenKeyboard()
SHIFT = ("left", 0.1, 0.9)
check("shift key emits no keystroke of its own", kb.press_at(*SHIFT), [])
check("one tap arms one-shot", kb.shift, "once")
check("one-shot capitalises", press(kb, "left", 0.1, 0.3), "Q")
check("one-shot is spent by the key it modified", kb.shift, "off")
check("the key after it is lowercase again", press(kb, "left", 0.3, 0.3), "w")

kb = osk.OnScreenKeyboard()
kb.press_at(*SHIFT)
check("one-shot shifts digits too", press(kb, "left", 0.1, 0.1), "!")

kb = osk.OnScreenKeyboard()
kb.press_at(*SHIFT)
check("one-shot is spent even by a key with no shifted face",
      (press(kb, "right", 0.3, 0.9), kb.shift), (" ", "off"))

kb = osk.OnScreenKeyboard()
kb.press_at(*SHIFT)
kb.press_at(*SHIFT)
check("two taps latch caps lock", kb.shift, "locked")
check("caps lock capitalises letters", press(kb, "left", 0.1, 0.3), "Q")
check("caps lock does NOT release after one letter", kb.shift, "locked")
check("caps lock capitalises the next letter as well", press(kb, "left", 0.3, 0.3), "W")
check("caps lock leaves digits ALONE -- it is a lock, not a shift",
      press(kb, "left", 0.1, 0.1), "1")
check("caps lock leaves punctuation alone too", press(kb, "right", 0.5, 0.7), ",")
kb.press_at(*SHIFT)
check("a third tap clears caps lock", kb.shift, "off")
check("and letters are lowercase again", press(kb, "left", 0.1, 0.3), "q")

# The shift keystroke must WRAP the key, or the modifier is not held when the
# key-down reaches the consumer and the capital silently arrives as lowercase.
kb = osk.OnScreenKeyboard()
kb.press_at(*SHIFT)
check("shift wraps the keystroke",
      kb.press_at("left", 0.1, 0.3),
      [(e.KEY_LEFTSHIFT, 1), (e.KEY_Q, 1), (e.KEY_Q, 0), (e.KEY_LEFTSHIFT, 0)])
kb = osk.OnScreenKeyboard()
check("unshifted emits no modifier at all",
      kb.press_at("left", 0.1, 0.3), [(e.KEY_Q, 1), (e.KEY_Q, 0)])

# --- face(): the screen must not show what the next press will not type -------

kb = osk.OnScreenKeyboard()
q = osk.key_at(osk.LETTERS, "left", 0.1, 0.3)
one = osk.key_at(osk.LETTERS, "left", 0.1, 0.1)
tab = osk.key_at(osk.LETTERS, "left", 0.9, 0.9)
check("unshifted face of q", kb.face(q), "q")
check("unshifted face of 1", kb.face(one), "1")
kb.press_at(*SHIFT)
check("one-shot face of q", kb.face(q), "Q")
check("one-shot face of 1", kb.face(one), "!")
check("a key with no shifted face keeps its label", kb.face(tab), "tab")
kb.press_at(*SHIFT)
check("caps-lock face of q", kb.face(q), "Q")
check("caps-lock face of 1 stays 1 -- matching what it will type",
      kb.face(one), "1")

# Every printable key's face must match what pressing it types, in every shift
# state. This is the property that keeps the rendered keyboard honest, and it
# is checked exhaustively rather than sampled.
#
# Single-character faces only: keys like space/tab/enter are labelled with a
# word on purpose, and "space" is not meant to equal " ".
face_mismatches = []
for state in ("off", "once", "locked"):
    for layer in osk.LAYERS.values():
        for half in ("left", "right"):
            for row in layer.half(half):
                for key in row:
                    if not key.types or len(key.label) != 1:
                        continue
                    if key.code not in set(PUNCT_FACE) | set(LETTER_FACE):
                        continue
                    probe = osk.OnScreenKeyboard(layer.name)
                    probe.shift = state
                    shown = probe.face(key)
                    typed = decode(probe.press(key))
                    if shown != typed:
                        face_mismatches.append((layer.name, half, state, shown, typed))
check("every printable key types exactly the face it shows", face_mismatches, [])

# --- layers -------------------------------------------------------------------

kb = osk.OnScreenKeyboard()
check("the layer key emits no keystroke", kb.press_at("left", 0.5, 0.9), [])
check("it switches to symbols", kb.layer_name, "symbols")
check("and the layout under the cursor changed", press(kb, "left", 0.1, 0.3), "-")
check("the way back is labelled abc", osk.key_at(osk.SYMBOLS, "left", 0.5, 0.9).label, "abc")
kb.press_at("left", 0.5, 0.9)
check("and returns to letters", kb.layer_name, "letters")

kb = osk.OnScreenKeyboard()
kb.press_at(*SHIFT)
kb.press_at("left", 0.5, 0.9)
check("one-shot shift is still armed after switching layer", kb.shift, "once")
check("and applies on the new layer", press(kb, "left", 0.1, 0.3), "_")

kb = osk.OnScreenKeyboard()
check("close emits no keystroke", kb.press_at("right", 0.9, 0.9), [])
check("close sets the closed flag", kb.closed, True)

# --- a real Wi-Fi passphrase, end to end --------------------------------------
#
# T8's second "done when" criterion is a mixed-case passphrase with digits and
# symbols typed with no keyboard attached. The renderer and the hardware are the
# other half of that, but the core can prove the layout REACHES every character
# -- which is the part that silently fails if a key was left off a layer.

TARGET = "Hunter2!_deck"
kb = osk.OnScreenKeyboard()
script = [
    SHIFT, ("right", 0.1, 0.5),   # H   shift, then h
    ("right", 0.3, 0.3),          # u
    ("right", 0.1, 0.7),          # n
    ("left", 0.9, 0.3),           # t
    ("left", 0.5, 0.3),           # e
    ("left", 0.7, 0.3),           # r
    ("left", 0.3, 0.1),           # 2
    SHIFT, ("left", 0.1, 0.1),    # !   shift, then 1
    ("left", 0.5, 0.9),           #     -> symbols
    SHIFT, ("left", 0.1, 0.3),    # _   shift, then -
    ("left", 0.5, 0.9),           #     -> letters
    ("left", 0.5, 0.5),           # d
    ("left", 0.5, 0.3),           # e
    ("left", 0.5, 0.7),           # c
    ("right", 0.5, 0.5),          # k
]
check("a mixed-case passphrase with a digit and two symbols types correctly",
      "".join(press(kb, *p) for p in script), TARGET)
check("and the keyboard is back on the letters layer afterwards",
      kb.layer_name, "letters")
check("with no shift left latched", kb.shift, "off")

# Every character a WPA2 passphrase may contain (printable ASCII) must exist
# somewhere in the layout, or that passphrase cannot be entered at all.
reachable = set()
for layer in osk.LAYERS.values():
    for half in ("left", "right"):
        for row in layer.half(half):
            for key in row:
                if key.label:
                    reachable.add(key.label)
                if key.shift_label:
                    reachable.add(key.shift_label)
printable = set(string.ascii_letters + string.digits + string.punctuation)
check("every printable ASCII character is reachable",
      sorted(printable - reachable - {" "}), [])

# --- OSK_KEYCODES: the set the uinput device must declare ---------------------
#
# ⚠️ A uinput device emits only what it declared at creation; an undeclared code
# is dropped by the kernel silently. If this set misses a key, that key is dead
# on the Deck and nothing anywhere reports it.

from_tables = {
    key.code
    for layer in osk.LAYERS.values()
    for half in ("left", "right")
    for row in layer.half(half)
    for key in row
    if key.code
}
check("OSK_KEYCODES covers every code in the layouts",
      sorted(from_tables - osk.OSK_KEYCODES), [])
check("OSK_KEYCODES declares the shift modifier it emits",
      e.KEY_LEFTSHIFT in osk.OSK_KEYCODES, True)
check("OSK_KEYCODES contains nothing the layouts cannot emit",
      sorted(osk.OSK_KEYCODES - from_tables - {e.KEY_LEFTSHIFT}), [])
check("the letters layer really carries all 26 letters",
      len({k.code for k in
           [key for half in ("left", "right") for row in osk.LETTERS.half(half)
            for key in row]
           if k.is_letter}), 26)

# --- strokes_for_text: the renderer-free emission path -----------------------
#
# Round-tripped through the INDEPENDENT decoder above, so this asserts the
# layout types what was asked for, not that it agrees with itself.

check("a plain word round-trips", decode(osk.strokes_for_text("deck")), "deck")
check("mixed case round-trips", decode(osk.strokes_for_text("DeckOS")), "DeckOS")
check("digits and symbols round-trip",
      decode(osk.strokes_for_text("a1!_~|?")), "a1!_~|?")
check("a space round-trips", decode(osk.strokes_for_text("a b")), "a b")

# The whole printable ASCII set in one string. If any character is unreachable
# or mislabelled, this is the assertion that says which.
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

# find_face prefers the unshifted key: "," exists unshifted on both layers and
# is also shift-of-nothing, so a preference bug would emit a stray modifier.
check("find_face prefers the unshifted face", osk.find_face(","), (e.KEY_COMMA, False))
check("find_face returns the shifted face when that is the only one",
      osk.find_face("<"), (e.KEY_COMMA, True))
check("find_face misses cleanly", osk.find_face("€"), None)

print()
print(f"{'PASS' if FAILURES == 0 else 'FAIL'} — {FAILURES} failure(s)")
sys.exit(1 if FAILURES else 0)
