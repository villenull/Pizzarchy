#!/usr/bin/env python3
"""deck_osk_layout -- the on-screen keyboard's layout core (T8 steps 1-2).

WHAT THIS IS
    The pure half of `docs/tasks/T8-onscreen-keyboard.md`: a split keyboard
    layout, hit-testing in normalised coordinates, shift/layer state, the
    keystroke sequences to emit, and the two cursors that drive it. No
    rendering, no device access, no evdev device -- the same discipline as
    `Mapper.translate()`, so all of it is testable without a screen or a human.

WHY IT IS A SEPARATE FILE, AND WHY THE NAME HAS UNDERSCORES
    T8 ships TWO renderers over one core: a bare-TTY one for the installer
    (which has no compositor at all -- `docs/findings/T2-gamepad-spike.md` §4
    measured that on the built 4.0 ISO) and a Wayland layer-shell one for
    Desktop Mode. Two renderers plus `deck-input-mapper.py` make three
    importers, so the core cannot live inside any of them.

    Everything else in `src/` is hyphenated, which is fine for a script and
    fatal for a module: `import deck-osk-layout` is a syntax error. This one is
    imported, so it gets underscores. Do not "fix" it for consistency.

THE MODEL
    Two halves, left and right, one per trackpad -- both pads report ABSOLUTE
    position over +/-32767 (measured, R-29..R-31), so a cursor per half is a
    direct mapping with no delta accumulation. This core does not care: it
    takes x/y already normalised to 0..1 WITHIN A HALF and answers which key
    is there.

    Rows are equal height; keys within a row are as wide as their `span`. Row
    counts are per LAYER (the letters layer has five rows, symbols four), so
    both halves of one layer always line up visually.

SHIFT
    Three states, and the distinction is deliberate:

      off     nothing held
      once    one-shot -- applies to the next key, then clears. Applies to
              EVERY key, so `1` types `!`.
      locked  caps lock -- applies to LETTERS ONLY, so `ABC12` is typeable
              without toggling. This is what a lock key means everywhere else.

    `face()` reports the label under the current state, so the screen never
    shows a character the next press will not type. That property is the whole
    reason the label function lives in the core rather than in a renderer.
"""

from __future__ import annotations

from dataclasses import dataclass

from evdev import ecodes as e

# --- the pieces --------------------------------------------------------------


@dataclass(frozen=True)
class Key:
    """One key. `code` is what it types; action keys type nothing."""

    code: int = 0
    label: str = ""
    shift_label: str = ""  # "" -> shift does not change the face
    action: str = ""  # "" types; else "shift" | "layer" | "close"
    target: str = ""  # layer name, for action == "layer"
    span: int = 1
    is_letter: bool = False  # caps lock applies to these and nothing else
    hint: str = ""  # "" -> no controller-glyph hint; else HINT_LEFT | HINT_RIGHT

    @property
    def types(self) -> bool:
        return not self.action and self.code != 0


@dataclass(frozen=True)
class Layer:
    """One layer's two halves. Each half is a tuple of rows of keys."""

    name: str
    left: tuple[tuple[Key, ...], ...]
    right: tuple[tuple[Key, ...], ...]

    def half(self, half: str) -> tuple[tuple[Key, ...], ...]:
        if half == "left":
            return self.left
        if half == "right":
            return self.right
        raise ValueError(f"half must be 'left' or 'right', got {half!r}")


# --- layout construction helpers ---------------------------------------------
#
# Terse on purpose: the layout tables below are the thing a human reads to
# check the keyboard, and they only read as a keyboard if one key is one token.


def letter(ch: str) -> Key:
    """A-Z. The only keys caps lock applies to."""
    return Key(code=getattr(e, f"KEY_{ch.upper()}"), label=ch.lower(),
               shift_label=ch.upper(), is_letter=True)


def sym(code: int, base: str, shifted: str) -> Key:
    """A key whose two faces are both printable -- digits and punctuation."""
    return Key(code=code, label=base, shift_label=shifted)


def act(action: str, label: str, span: int = 1, target: str = "", code: int = 0,
        hint: str = "") -> Key:
    """A key that changes state (shift/layer/close) or types a control key."""
    return Key(code=code, label=label, action=action, target=target, span=span,
               hint=hint)


# --- controller-glyph hints (T8 §9, operator request 2026-08-11) -------------
#
# ⛔ Not Valve's artwork -- these are two of OUR OWN strings, not an icon lifted
# from anywhere (docs/findings/P16-redistribution-and-trademark.md). "L2"/"R2"
# is what this project calls the triggers everywhere else (docs/PROGRESS.md
# §7), so a hint reading "R2" teaches the same vocabulary the rest of the repo
# already uses rather than inventing a second one.
#
# ⚠️ MUST MATCH TRIGGER_HALF, defined further down this file: a hint naming the
# WRONG trigger would be worse than no hint at all -- confidently wrong rather
# than merely absent. `test-deck-osk-layout.py` asserts every hinted key's
# glyph agrees with the half it is actually drawn in, on every layer.
HINT_LEFT = "L2"
HINT_RIGHT = "R2"


# --- the layouts -------------------------------------------------------------
#
# Read these as a keyboard. Left half is what the LEFT trackpad's cursor moves
# over, right half the right's; each trigger clicks its own side.
#
# The digit row is repeated on both layers deliberately. A Wi-Fi passphrase --
# the screen this whole task exists for -- mixes digits with everything else,
# and a spare row costs nothing.

_D = {  # digits, with their US-layout shifted faces
    "1": sym(e.KEY_1, "1", "!"), "2": sym(e.KEY_2, "2", "@"),
    "3": sym(e.KEY_3, "3", "#"), "4": sym(e.KEY_4, "4", "$"),
    "5": sym(e.KEY_5, "5", "%"), "6": sym(e.KEY_6, "6", "^"),
    "7": sym(e.KEY_7, "7", "&"), "8": sym(e.KEY_8, "8", "*"),
    "9": sym(e.KEY_9, "9", "("), "0": sym(e.KEY_0, "0", ")"),
}

DIGITS_LEFT = tuple(_D[c] for c in "12345")
DIGITS_RIGHT = tuple(_D[c] for c in "67890")

# The function row, shared in shape by both layers so muscle memory carries.
#
# Shift, Backspace and Enter carry a controller-glyph hint (T8 §9): they are
# the three keys a user reaches for constantly while correcting a passphrase,
# and each lives on exactly one half in EVERY layer it appears in below -- so
# one hint per key is honest in every layer, not just the one it was written
# against.
SHIFT_KEY = act("shift", "shift", span=2, hint=HINT_LEFT)
CLOSE_KEY = act("close", "close", span=2)
SPACE_KEY = act("", "space", span=3, code=e.KEY_SPACE)
TAB_KEY = act("", "tab", code=e.KEY_TAB)
BACKSPACE_KEY = act("", "back", code=e.KEY_BACKSPACE, hint=HINT_RIGHT)
ENTER_KEY = act("", "enter", code=e.KEY_ENTER, hint=HINT_RIGHT)

LETTERS = Layer(
    name="letters",
    left=(
        DIGITS_LEFT,
        tuple(letter(c) for c in "qwert"),
        tuple(letter(c) for c in "asdfg"),
        tuple(letter(c) for c in "zxcvb"),
        (SHIFT_KEY, act("layer", "?#=", span=2, target="symbols"), TAB_KEY),
    ),
    right=(
        DIGITS_RIGHT,
        tuple(letter(c) for c in "yuiop"),
        tuple(letter(c) for c in "hjkl") + (BACKSPACE_KEY,),
        tuple(letter(c) for c in "nm")
        + (sym(e.KEY_COMMA, ",", "<"), sym(e.KEY_DOT, ".", ">"), ENTER_KEY),
        (SPACE_KEY, CLOSE_KEY),
    ),
)

# Four rows, not five: with shift covering !@#$%^&*() and _+{}|:"<>? there are
# exactly eleven unshifted punctuation keys left, and the spare cells go to
# cursor movement -- which is what fixing a typo mid-passphrase actually needs.
SYMBOLS = Layer(
    name="symbols",
    left=(
        DIGITS_LEFT,
        (sym(e.KEY_MINUS, "-", "_"), sym(e.KEY_EQUAL, "=", "+"),
         sym(e.KEY_LEFTBRACE, "[", "{"), sym(e.KEY_RIGHTBRACE, "]", "}"),
         sym(e.KEY_BACKSLASH, "\\", "|")),
        (sym(e.KEY_SLASH, "/", "?"),
         act("", "left", code=e.KEY_LEFT), act("", "up", code=e.KEY_UP),
         act("", "down", code=e.KEY_DOWN), act("", "right", code=e.KEY_RIGHT)),
        (SHIFT_KEY, act("layer", "abc", span=2, target="letters"), TAB_KEY),
    ),
    right=(
        DIGITS_RIGHT,
        (sym(e.KEY_SEMICOLON, ";", ":"), sym(e.KEY_APOSTROPHE, "'", '"'),
         sym(e.KEY_GRAVE, "`", "~"), sym(e.KEY_COMMA, ",", "<"),
         sym(e.KEY_DOT, ".", ">")),
        (act("", "home", code=e.KEY_HOME), act("", "end", code=e.KEY_END),
         act("", "del", code=e.KEY_DELETE), BACKSPACE_KEY, ENTER_KEY),
        (SPACE_KEY, CLOSE_KEY),
    ),
)

LAYERS: dict[str, Layer] = {layer.name: layer for layer in (LETTERS, SYMBOLS)}
INITIAL_LAYER = "letters"

SHIFT_CODE = e.KEY_LEFTSHIFT

# Every keycode this keyboard can emit, shift included.
#
# ⚠️ LOAD-BEARING. A uinput device emits ONLY the codes it declared when it was
# created -- an undeclared code is dropped by the kernel with no error anywhere.
# `deck-input-mapper.py` folds this into its own EMITTED_KEYS for exactly that
# reason. If this set drifts from the layouts, the affected keys go silently
# dead, which is the failure mode CLAUDE.md forbids; `test-deck-osk-layout.py`
# pins it against the tables.
OSK_KEYCODES: frozenset[int] = frozenset(
    [SHIFT_CODE]
    + [key.code for layer in LAYERS.values()
       for half in (layer.left, layer.right)
       for row in half for key in row if key.code]
)


# --- hit-testing (pure) ------------------------------------------------------


def locate(layer: Layer, half: str, x: float, y: float) -> tuple[int, int] | None:
    """Which (row index, key index) is at (x, y), normalised 0..1 in that half?

    Returns None outside the half. A cursor is clamped to its half by
    construction, so None means a caller bug rather than a user miss -- but it
    is still the honest answer, and silently clamping would hide it.

    Renderers need the INDICES, not just the key: highlighting by comparing Key
    objects would light up every cell sharing an instance (space and shift are
    module-level singletons reused across layers).
    """
    rows = layer.half(half)
    if not (0.0 <= x <= 1.0 and 0.0 <= y <= 1.0) or not rows:
        return None

    # int() then clamp, rather than rounding: the last row/column owns its
    # closing edge, so y == 1.0 lands on the bottom row instead of off the end.
    row_index = min(int(y * len(rows)), len(rows) - 1)
    row = rows[row_index]
    if not row:
        return None

    # Integer cell arithmetic, not accumulated float fractions: with spans of
    # 2 and 3 in the function row, summing x against fractions drifts at the
    # boundaries and puts a click on the wrong key.
    cells = sum(key.span for key in row)
    cell = min(int(x * cells), cells - 1)
    seen = 0
    for key_index, key in enumerate(row):
        seen += key.span
        if cell < seen:
            return (row_index, key_index)
    return (row_index, len(row) - 1)  # unreachable while span >= 1


def key_at(layer: Layer, half: str, x: float, y: float) -> Key | None:
    """Which key is at (x, y), normalised 0..1 WITHIN that half?"""
    found = locate(layer, half, x, y)
    if found is None:
        return None
    return layer.half(half)[found[0]][found[1]]


# --- the state machine -------------------------------------------------------


class OnScreenKeyboard:
    """Layer + shift state, and the keystrokes a press produces.

    `press()` returns (keycode, value) pairs in the same shape as
    `Mapper.translate()`, so `deck-input-mapper.py` can feed them to the emit
    path it already has rather than growing a second one.
    """

    def __init__(self, layer: str = INITIAL_LAYER) -> None:
        if layer not in LAYERS:
            raise ValueError(f"unknown layer {layer!r}")
        self.layer_name = layer
        self.shift = "off"  # "off" | "once" | "locked"
        self.closed = False

    @property
    def layer(self) -> Layer:
        return LAYERS[self.layer_name]

    def shift_applies_to(self, key: Key) -> bool:
        """Is shift in force for THIS key right now?

        `once` is a shift and hits everything. `locked` is a caps lock and hits
        letters only, so a passphrase can mix capitals and unshifted digits
        without toggling between them.
        """
        if self.shift == "once":
            return True
        if self.shift == "locked":
            return key.is_letter
        return False

    def face(self, key: Key) -> str:
        """The label to draw, under the current shift state.

        The shift key reports its OWN state here rather than in a renderer, so
        both renderers show the same thing and neither has to know the state
        machine. Without it a user cannot tell one-shot from locked, and the
        only feedback is typing a character and seeing the wrong case.
        """
        if key.action == "shift":
            return {"off": "shift", "once": "Shift", "locked": "LOCK"}[self.shift]
        if key.shift_label and self.shift_applies_to(key):
            return key.shift_label
        return key.label

    def secondary_face(self, key: Key) -> str:
        """The OTHER face of a dual-legend key -- the one `face()` is not
        currently showing -- or "" if this key has none (T8 §9: "shifted
        symbols shown above the digit on the same key").

        Digits and punctuation carry both faces AT ONCE, the way a real
        keycap does -- "1" and "!" on the same key -- so a renderer with room
        can draw the one `face()` is not returning as a small secondary
        legend, without waiting for a shift press to reveal it exists.

        Letters are deliberately excluded: upper and lower case are the same
        glyph rotated, not a different character, and a redundant "Q" drawn
        over every one of 26 keys is clutter this was written to avoid. Action
        keys (space/tab/shift itself/…) have no `shift_label` at all, so they
        fall out of the `not key.shift_label` check with no special-casing.
        """
        if key.is_letter or not key.shift_label:
            return ""
        return key.shift_label if self.face(key) == key.label else key.label

    def key_at(self, half: str, x: float, y: float) -> Key | None:
        return key_at(self.layer, half, x, y)

    def locate(self, half: str, x: float, y: float) -> tuple[int, int] | None:
        return locate(self.layer, half, x, y)

    def press(self, key: Key | None) -> list[tuple[int, int]]:
        """Apply a press. Returns the keystrokes to emit, possibly empty."""
        if key is None:
            return []

        if key.action == "shift":
            self.shift = {"off": "once", "once": "locked"}.get(self.shift, "off")
            return []
        if key.action == "layer":
            self.layer_name = key.target
            return []
        if key.action == "close":
            self.closed = True
            return []
        if not key.code:
            return []

        shifted = self.shift_applies_to(key)
        strokes = [(key.code, 1), (key.code, 0)]
        if shifted:
            strokes = [(SHIFT_CODE, 1)] + strokes + [(SHIFT_CODE, 0)]
        # One-shot shift is spent by the key it modified -- including keys with
        # no shifted face, which is what makes it a shift rather than a mode.
        if self.shift == "once":
            self.shift = "off"
        return strokes

    def press_at(self, half: str, x: float, y: float) -> list[tuple[int, int]]:
        """Hit-test and press in one call -- what a renderer's click does."""
        return self.press(self.key_at(half, x, y))


# --- two cursors, one per trackpad (T8 step 3) -------------------------------
#
# Both pads report ABSOLUTE position over the full range (measured 2026-08-10,
# R-29..R-31), so a cursor is a direct mapping and not an accumulated delta.
# That is why the OSK can have two of them while a Wayland seat has one pointer:
# nothing outside this process needs to know either exists.
#
# ⚠️ `ABS_HAT0X/Y` IS THE LEFT TRACKPAD. It is called a hat, advertised as a
# hat, and is not one -- the d-pad is `BTN_DPAD_*`. `deck-input-mapper.py`
# separately reuses those two codes as internal names for "horizontal" and
# "vertical" direction; that reuse stops at its own module boundary and has
# nothing to do with these. Read DEVICE_AXES in the mapper before touching this.

PAD_RANGE = (-32768, 32767)

PAD_AXES: dict[int, tuple[str, str]] = {
    e.ABS_HAT0X: ("left", "x"),
    e.ABS_HAT0Y: ("left", "y"),
    e.ABS_HAT1X: ("right", "x"),
    e.ABS_HAT1Y: ("right", "y"),
}

# Each trigger clicks its OWN side. Matching lizard mode's convention would put
# right=left-click, but there are two cursors here and no single pointer to
# left- or right-click: the side is the meaning.
TRIGGER_HALF: dict[int, str] = {
    e.BTN_TL2: "left",
    e.BTN_TR2: "right",
}


class Cursors:
    """Both trackpads -> two cursor positions, each in 0..1 within its half.

    Feed it raw EV_ABS events; ask it where each cursor is. Pure: no device, no
    screen, no compositor.
    """

    def __init__(self, ranges: dict[int, tuple[int, int]] | None = None) -> None:
        # Ranges come from the device's own absinfo where available. The default
        # is what the Deck measured, so a caller with no device still gets the
        # right geometry.
        self.ranges = dict(ranges or {})
        # Start both cursors centred: visible, neutral, and on no key in
        # particular. Nothing has been touched yet, so any other guess is a lie.
        self.pos: dict[str, list[float]] = {"left": [0.5, 0.5], "right": [0.5, 0.5]}

    def position(self, half: str) -> tuple[float, float]:
        if half not in self.pos:
            raise ValueError(f"half must be 'left' or 'right', got {half!r}")
        return (self.pos[half][0], self.pos[half][1])

    def update(self, code: int, value: int) -> str | None:
        """Apply one EV_ABS event. Returns the half that moved, or None.

        ⚠️ A reading of EXACTLY 0 is treated as no reading at all, and that axis
        holds its previous position. This is the lift.

        The pads report 0 (centre) when a finger leaves, which under an absolute
        mapping would snap the cursor to the middle of its half on every
        release -- and put the next trigger click on whatever key sits there.
        Holding instead of snapping costs exactly one position, the pad's dead
        centre, which no finger can hit deliberately and which is half a key
        away from any hit-test boundary. A stroke that passes through the centre
        line loses one 4 ms sample on that axis (the pads run at 250 Hz), which
        is not perceivable.

        This deliberately does NOT depend on both zeros arriving in the same
        report. Whether `hid-steam` sends them together is unmeasured, and a
        rule that needed them together would fail differently depending on the
        answer.
        """
        axis = PAD_AXES.get(code)
        if axis is None:
            return None
        half, which = axis
        if value == 0:
            return None

        low, high = self.ranges.get(code, PAD_RANGE)
        span = high - low
        if span <= 0:
            return None  # a degenerate range would divide by zero; report nothing

        fraction = (value - low) / span
        fraction = min(1.0, max(0.0, fraction))  # the device may exceed absinfo
        if which == "y":
            # The pad's Y grows UPWARD and every screen coordinate grows
            # downward. The relative pointer in deck-input-mapper.py negates the
            # same axis for the same reason; if one of them is ever wrong, they
            # are wrong together and the cursor moves the wrong way vertically.
            fraction = 1.0 - fraction

        self.pos[half][0 if which == "x" else 1] = fraction
        return half


# --- typing text directly, without a renderer --------------------------------
#
# Layers are a DISPLAY concern: emission only needs a keycode and whether shift
# is held, so text can be typed without any cursor, layer switching or screen.
#
# This exists so the emission path is verifiable before a renderer exists --
# `deck-input-mapper --type` drives it. Session 17 cost nine defects to the
# pattern of a path that was present, enumerated and silent, and this is the
# cheapest way to point a human at the real one and ask whether text appeared.


def find_face(ch: str) -> tuple[int, bool] | None:
    """Which (keycode, shifted) types `ch`? None if the layout cannot."""
    shifted_hit = None
    for layer in LAYERS.values():
        for half in (layer.left, layer.right):
            for row in half:
                for key in row:
                    if not key.types:
                        continue
                    if key.label == ch:
                        return (key.code, False)  # prefer the unshifted face
                    if key.shift_label == ch and shifted_hit is None:
                        shifted_hit = (key.code, True)
    return shifted_hit


def strokes_for_text(text: str) -> list[tuple[int, int]]:
    """Every keystroke needed to type `text`. Raises on an unreachable char.

    Raising rather than skipping is the point: a passphrase silently missing a
    character is a device that will not join the network, with nothing on
    screen or in a log to say why.
    """
    out: list[tuple[int, int]] = []
    for ch in text:
        if ch == " ":
            found: tuple[int, bool] | None = (e.KEY_SPACE, False)
        else:
            found = find_face(ch)
        if found is None:
            raise ValueError(f"no key in any layer types {ch!r}")
        code, shifted = found
        if shifted:
            out.append((SHIFT_CODE, 1))
        out += [(code, 1), (code, 0)]
        if shifted:
            out.append((SHIFT_CODE, 0))
    return out


# --- the state protocol -------------------------------------------------------
#
# One line per update, written by the mapper to a renderer running in ANOTHER
# PROCESS. It lives here rather than in a renderer because both sides speak
# it and the mapper must not import anything GTK-adjacent to do so.
#
# Text on a pipe rather than a socket or DBus: trivially inspectable with
# `tee`, needs no session bus (the installer has none), and a malformed line
# can only be ignored -- this crosses a process boundary, so a parser that
# raised would take the keyboard down with it.

def parse_state_line(line: str) -> dict | None:
    """`state <layer> <shift> <lx> <ly> <rx> <ry>` -> a dict, or None."""
    parts = line.split()
    if len(parts) != 7 or parts[0] != "state":
        return None
    _, layer, shift, lx, ly, rx, ry = parts
    if layer not in LAYERS or shift not in ("off", "once", "locked"):
        return None
    try:
        values = [float(v) for v in (lx, ly, rx, ry)]
    except ValueError:
        return None
    if not all(0.0 <= v <= 1.0 for v in values):
        return None
    return {"layer": layer, "shift": shift,
            "left": (values[0], values[1]), "right": (values[2], values[3])}


def format_state_line(keyboard: OnScreenKeyboard, cursors: Cursors) -> str:
    """The mapper's side of the same protocol."""
    left, right = cursors.position("left"), cursors.position("right")
    return (f"state {keyboard.layer_name} {keyboard.shift} "
            f"{left[0]:.4f} {left[1]:.4f} {right[0]:.4f} {right[1]:.4f}\n")


def apply_state(keyboard: OnScreenKeyboard, cursors: Cursors,
                state: dict) -> None:
    keyboard.layer_name = state["layer"]
    keyboard.shift = state["shift"]
    for half in ("left", "right"):
        cursors.pos[half] = [state[half][0], state[half][1]]
