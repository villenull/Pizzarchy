#!/usr/bin/env python3
"""deck_osk_layout -- the on-screen keyboard's layout core (T8 steps 1-2).

WHAT THIS IS
    The pure half of `docs/tasks/T8-onscreen-keyboard.md`: the keyboard's
    grid, hit-testing in normalised coordinates, shift/caps state, the
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

THE MODEL -- ONE CONTINUOUS GRID, NOT TWO HALF-GRIDS (T8 §9g)
    🔴 This changed on 2026-08-12 and it is the single most visible thing in
    the module. The keyboard is ONE grid spanning the full width. It used to be
    two independent half-grids drawn side by side with a gutter between them,
    and the operator's first words on seeing ours next to Valve's were "i still
    see a gap between the left half and the right half".

    The two-cursor model never needed a split. Each trackpad's cursor addresses
    its own CONTIGUOUS RANGE OF CELLS within the one grid:

        cells [0, split)      <- the left pad's cursor
        cells [split, width)  <- the right pad's cursor

    A key WIDE ENOUGH TO STRADDLE `split` is reachable from both halves, which
    is a feature and not an accident: the space bar is exactly that key, and
    either thumb can hit it. `locate()` maps a normalised x within a half onto
    that half's cell range, so the arithmetic is identical to before -- what
    changed is that the cell ranges are two windows onto one row instead of two
    separate rows.

    Rows are equal height and every row is the same total width in cells
    (`Layer.__post_init__` refuses a layout where that is not true, because a
    ragged grid cannot line up on screen and silently drawing one would hide
    the bug).

    ⚠️ GEOMETRY THE TTY RENDERER MUST LIVE WITH. The grid is 16 cells wide.
    `docs/PROGRESS.md` §7 measured the two consoles this has to survive: the
    live ISO's is 50x160 and the installed TTY's is 25x80. 16 cells fit in 80
    columns at FIVE columns per cell, exactly, with nothing spare -- so the TTY
    renderer's KEY_CELL cannot stay at 7 (that would be 112 columns and the
    keyboard would wrap or be clamped, which is R-49's defect returning). Five
    columns still fits a dual legend on a one-cell key ("1 !" is 3 characters
    against a highlighted budget of KEY_CELL-2 = 3), so no legend is lost.

TWO WIDTHS PER KEY, AND THAT IS DELIBERATE (T8 §9g, metrics §2)
    🔴 Added 2026-08-12. A key carries BOTH `span` (integer cells) and `units`
    (a float, visual width). They are not redundant and neither can be derived
    from the other -- the backtick key is one CELL and 0.52 UNITS; Tab is
    three cells and 1.03 units. They exist because the cell grid was doing two
    unrelated jobs:

      `span`   ADDRESSING and the TTY's own layout. Integer, because a text
               console has integer columns and because 16 x 5 = 80 is the
               installed TTY's entire width with nothing spare. Not negotiable:
               `test-deck-osk-tty.py` and `test-osk-install-layout.sh` assert
               that 80 as an equality, and this keyboard is how a user types a
               Wi-Fi passphrase with no physical keyboard.
      `units`  VISUAL WIDTH for a pixel renderer, in multiples of one letter
               key. Measured off Valve's own keyboard; a 16-cell integer grid
               cannot express 0.52 or 1.71, and forcing it to try is what made
               ours draw `Tab` and `Caps` three times a letter's width when the
               reference draws them at 1.03 and 1.36.

    ⚠️ ROWS DIFFER IN UNITS, AND EACH ROW IS NORMALISED TO THE FULL WIDTH ON
    ITS OWN. `Layer.width` (cells) is identical for every row; `row_units` is
    NOT -- 14.02 to 14.23 across the five. That is not sloppiness in the
    measurement, it is what Valve's pixels do: re-measured from `01-idle.png`,
    every row's fill spans exactly x=5..1273, while a unit key is 85px wide in
    row 1 and 86-87px in rows 2-4. The fixed keys are fixed and the unit keys
    absorb the remainder, which is why the rows do not line up vertically.

    A renderer therefore scales EACH ROW by `width / row_units(row)`. Doing it
    once for the whole layer would reintroduce a ragged right edge.

    ⚠️ A PIXEL RENDERER MUST ALSO HIT-TEST IN UNITS -- `locate(..., metric=
    "units")`. Drawing by units while hit-testing by cells puts the cursor's
    dot up to half a key away from the key it lights up. The two metrics agree
    on WHICH KEYS each pad can reach (`half_units` interpolates the cell split
    onto the row's own key boundaries); they disagree on where the boundaries
    fall inside a half, and each renderer must ask for the one it draws.

SHIFT AND CAPS ARE TWO DIFFERENT MODIFIERS (T8 §9g)
    ⚠️ THE SUBTLE PART, AND THE ONE §9g SINGLES OUT AS EASY TO GET WRONG.
    They are not two settings of one dial:

      shift   "off" | "once" (one-shot, spent by the next key) | "locked"
              Applies to EVERYTHING: letters go uppercase, `1` types `!`, and
              `◀` becomes `▲`. It also changes the LEGENDS -- under shift a
              key shows ONLY its shifted face.
      caps    a separate boolean, latched by its own key (L3 on the reference).
              Applies to LETTERS AND NOTHING ELSE. `1` still types `1`, the
              arrows still go left/right, and every dual legend stays exactly
              as it was drawn unshifted.

    So `caps` is not `shift == "locked"`, and a renderer that treats them as
    the same thing draws the wrong keyboard in one of the two states.

THE LEGEND RULE (T8 §9g)
    | state      | number/punctuation/arrow keys        | letters   |
    | unshifted  | dual: shifted SMALL ABOVE, base big  | lowercase |
    | shift      | ONLY the shifted face, big, centred  | UPPERCASE |
    | caps       | dual, unchanged                      | UPPERCASE |

    `face()` returns the LARGE legend; `secondary_face()` returns the small one
    drawn ABOVE it, or "" when there is none to draw. Both live here rather
    than in a renderer so the two renderers cannot disagree, and so the screen
    never shows a character the next press will not type.
"""

from __future__ import annotations

from dataclasses import dataclass

from evdev import ecodes as e

# --- the pieces --------------------------------------------------------------

# How far apart the widest and narrowest rows may be, in units, before a layer
# is refused. The reference's own five rows span 0.21 (14.02..14.23), so this
# has to admit that; adding, dropping or fat-fingering a key moves a row by at
# least 0.5, so it still catches every mistake that matters.
ROW_UNITS_TOLERANCE = 0.4


@dataclass(frozen=True)
class Key:
    """One key. `code` is what it types; action keys type nothing."""

    code: int = 0
    label: str = ""
    shift_label: str = ""  # "" -> shift does not change the face
    # T8 §9g: `▲`/`▼` are the SHIFTED FACES of `◀`/`▶`, and a shifted arrow is
    # a DIFFERENT KEYCODE rather than the same one with a modifier held --
    # SHIFT+KEY_LEFT is "extend the selection left", not "up". So a key whose
    # shifted face is a different key entirely says so here, and `press()`
    # emits this code with NO modifier wrapped around it.
    shift_code: int = 0
    action: str = ""  # "" types; else shift|caps|layer|close|emoji|move
    target: str = ""  # layer name, for action == "layer"
    span: int = 1
    # VISUAL width, in multiples of one letter key, measured off the reference
    # (metrics §2 + the re-measurement in this module's header). Independent of
    # `span`, which is the ADDRESSING/TTY width -- see the header. A key that
    # gives one and not the other is a key drawn at the wrong size, so every
    # non-unit key below states both.
    units: float = 1.0
    is_letter: bool = False  # caps applies to these and nothing else
    # Modifier keycodes held around this key's own code. Paste is the only user
    # today; it exists as a field rather than a special case so the next one
    # does not need a second mechanism.
    modifiers: tuple[int, ...] = ()
    # T8 §9g: some keys are drawn BLACK (#000000), the rest dark grey
    # (#0E141B). ⚠️ THIS IS A MEASUREMENT AND IT DOES NOT REDUCE TO A RULE --
    # metrics §2 sampled row 5 twice, at two heights, to rule out a sampling
    # artifact, and got: `☺`, `◀`, `▶` and `Paste` BLACK; `space` and `Move`
    # GREY. So `Move` is grey despite being a special-function key and `Paste`
    # is black despite not modifying anything. Carried as data per key; do not
    # invent a predicate that "explains" it, because the next key added would
    # then be classified by a rule that is not true.
    is_action: bool = False
    hint: str = ""  # "" -> no controller-glyph hint; else one of HINT_*
    # T8 §9g draws two badge SHAPES and the distinction is semantic, not
    # decorative -- face buttons (Ⓧ/Ⓨ) in a circle, triggers and stick clicks
    # (L2/R2/L3) in a rounded rectangle. "" whenever hint == "".
    hint_shape: str = ""

    @property
    def types(self) -> bool:
        return not self.action and (self.code != 0 or self.shift_code != 0)


@dataclass(frozen=True)
class Layer:
    """One layer as ONE CONTINUOUS GRID of rows (T8 §9g).

    `split` is the cell index where the RIGHT pad's half begins. It is a
    cursor-addressing boundary, NOT a visual one: nothing here says to draw a
    gap, and §9g is explicit that there must not be one.
    """

    name: str
    rows: tuple[tuple[Key, ...], ...]
    split: int

    def __post_init__(self) -> None:
        if not self.rows:
            raise ValueError(f"layer {self.name!r} has no rows")
        widths = {sum(key.span for key in row) for row in self.rows}
        if len(widths) != 1:
            # A ragged grid cannot line up on screen. Rendering it anyway would
            # hide the bug, which is the failure mode CLAUDE.md forbids.
            raise ValueError(
                f"layer {self.name!r} has rows of differing widths {sorted(widths)}; "
                "one continuous grid means every row is the same number of cells"
            )
        if not 0 < self.split < self.width:
            raise ValueError(
                f"layer {self.name!r} split {self.split} must fall strictly "
                f"inside 0..{self.width}, or one pad addresses no keys at all"
            )
        if any(key.units <= 0 for row in self.rows for key in row):
            # A zero- or negative-width key is invisible or inverts the row's
            # cumulative bounds, and either would be drawn without complaint.
            raise ValueError(
                f"layer {self.name!r} has a key with units <= 0; a visual "
                "width must be positive"
            )
        totals = [self.row_units(i) for i in range(len(self.rows))]
        if max(totals) - min(totals) > ROW_UNITS_TOLERANCE:
            # ⚠️ NOT an equality, unlike the cell check above: the reference's
            # own rows really do differ, 14.02 to 14.23 (0.21). Each row is
            # normalised to the full width on its own, so a wrong `units`
            # rescales that row silently instead of leaving a visible hole.
            # This is the only thing that can catch it. The tolerance is loose
            # enough for the measurement and far tighter than adding, dropping
            # or mis-typing a key, which all move a row by >= 0.5.
            raise ValueError(
                f"layer {self.name!r} has row unit totals {totals} spanning "
                f"more than {ROW_UNITS_TOLERANCE}; one of them is mis-measured"
            )

    @property
    def width(self) -> int:
        """Total cells across, the same for every row."""
        return sum(key.span for key in self.rows[0])

    def half_cells(self, half: str) -> tuple[int, int]:
        """The [start, end) cell range this pad's cursor addresses."""
        if half == "left":
            return (0, self.split)
        if half == "right":
            return (self.split, self.width)
        raise ValueError(f"half must be 'left' or 'right', got {half!r}")

    def cell_bounds(self, row_index: int) -> tuple[tuple[int, int], ...]:
        """Each key's [start, end) cells in this row -- what a renderer needs
        to place it across the full width. Derived rather than stored so it
        cannot drift from `span`.
        """
        out: list[tuple[int, int]] = []
        start = 0
        for key in self.rows[row_index]:
            out.append((start, start + key.span))
            start += key.span
        return tuple(out)

    # --- the visual metric (metrics §2) --------------------------------------
    #
    # The same three questions as above, asked in UNITS instead of cells. A
    # pixel renderer uses these; the TTY renderer uses the cell ones. Neither
    # set is derivable from the other -- see the module header.

    def row_units(self, row_index: int) -> float:
        """This row's total visual width, in letter-key units.

        ⚠️ ROW-SPECIFIC, unlike `width`. Rows differ (14.02..14.23 measured),
        and a renderer scales each row by `pixels / row_units(row)` so every
        row still ends flush at the right edge -- which is exactly what the
        reference does.
        """
        return sum(key.units for key in self.rows[row_index])

    def unit_bounds(self, row_index: int) -> tuple[tuple[float, float], ...]:
        """Each key's [start, end) in units -- `cell_bounds`' visual twin.

        Derived rather than stored, for the same reason: it cannot drift from
        `units`.
        """
        out: list[tuple[float, float]] = []
        start = 0.0
        for key in self.rows[row_index]:
            out.append((start, start + key.units))
            start += key.units
        return tuple(out)

    def _cells_to_units(self, row_index: int, cell: float) -> float:
        """A position on the cell grid, in units, for THIS row.

        Piecewise-linear through the row's own key boundaries, so a boundary
        that falls between two keys in cells falls between the SAME two keys in
        units. Inside a straddling key (the space bar spans cells 1..8 while
        the split is 8) it interpolates across that key, which is the only
        answer that keeps both halves able to reach it.
        """
        cells = self.cell_bounds(row_index)
        units = self.unit_bounds(row_index)
        for (c0, c1), (u0, u1) in zip(cells, units):
            if cell < c1:
                return u0 + (u1 - u0) * (cell - c0) / (c1 - c0)
        return units[-1][1]

    def half_units(self, row_index: int, half: str) -> tuple[float, float]:
        """The [start, end) UNIT range this pad's cursor addresses in this row.

        The cell split mapped onto this row's key boundaries, so the two
        metrics agree on which keys a thumb can reach even though they
        disagree on where the boundaries sit inside a half.
        """
        start, end = self.half_cells(half)  # raises on an unknown half
        return (self._cells_to_units(row_index, start),
                self._cells_to_units(row_index, end))


# --- layout construction helpers ---------------------------------------------
#
# Terse on purpose: the layout tables below are the thing a human reads to
# check the keyboard, and they only read as a keyboard if one key is one token.


def letter(ch: str) -> Key:
    """A-Z. The only keys caps applies to."""
    return Key(code=getattr(e, f"KEY_{ch.upper()}"), label=ch.lower(),
               shift_label=ch.upper(), is_letter=True)


def sym(code: int, base: str, shifted: str, shift_code: int = 0,
        span: int = 1, units: float = 1.0, is_action: bool = False) -> Key:
    """A dual-legend key: two faces, either of which the key can produce.

    `shift_code` is for the arrows, whose shifted face is a DIFFERENT KEY
    rather than a shifted variant of the same one (T8 §9g).

    `is_action` is here because the arrows need it: metrics §2 measures them
    BLACK even though they are dual-legend keys like the digits, which are
    grey. Data, not a rule -- see `Key.is_action`.
    """
    return Key(code=code, label=base, shift_label=shifted,
               shift_code=shift_code, span=span, units=units,
               is_action=is_action)


def act(action: str, label: str, span: int = 1, target: str = "", code: int = 0,
        hint: str = "", hint_shape: str = "", is_action: bool = True,
        modifiers: tuple[int, ...] = (), units: float = 1.0) -> Key:
    """A key that changes state (shift/caps/layer/...) or types a control key.

    `is_action` defaults True because most of these are §9g's black keys, but
    it is a MEASUREMENT and not a derivation -- `space` and `Move` measure
    GREY and pass False, while `Paste` and the emoji key measure BLACK and
    take the default.

    `units` defaults to one letter-key width, which is right for none of the
    keys built here -- every call site states its own measured value.
    """
    # A hint with no explicit shape defaults to "rect": triggers and stick
    # clicks outnumber face buttons here, and every call site that wants a
    # circle says so.
    if hint and not hint_shape:
        hint_shape = HINT_SHAPE_RECT
    return Key(code=code, label=label, action=action, target=target, span=span,
               units=units, hint=hint, hint_shape=hint_shape,
               is_action=is_action, modifiers=modifiers)


# --- controller-glyph hints (T8 §9g) -----------------------------------------
#
# ⛔ Not Valve's artwork -- these are OUR OWN strings, not icons lifted from
# anywhere (docs/findings/P16-redistribution-and-trademark.md). "L2"/"R2"/"L3"
# is what this project calls those controls everywhere else (docs/PROGRESS.md
# §7), so a hint reading "R2" teaches the same vocabulary the rest of the repo
# already uses rather than inventing a second one.
#
# ⚠️ EVERY ONE OF THESE MUST BE TRUE OF THE MAPPER'S REAL BINDINGS. A badge
# naming a button that does something else is CONFIDENTLY WRONG, which T8 §9a
# establishes is worse than a badge being absent. The operator's 2026-08-12
# decision settled the bindings these five assert (§9g, "MATCH VALVE EXACTLY,
# INCLUDING THE BINDINGS"):
#
#     Ⓧ  BTN_NORTH  -> Backspace      (was KEY_TAB; deliberately given up)
#     Ⓨ  BTN_WEST   -> Space
#     L3 BTN_THUMBL -> Caps
#     L2 BTN_TL2    -> commit the left cursor, and Shift while the left pad is
#                      untouched
#     R2 BTN_TR2    -> commit the right cursor, and Enter while the right pad
#                      is untouched
#
# `test-deck-osk-layout.py` checks each badge against what its key actually
# does, written out longhand from §9g rather than read back out of this file.
HINT_LEFT = "L2"        # shift -- BOTH shift keys carry it, see HINT_PAD_GATE
HINT_RIGHT = "R2"       # enter
HINT_CAPS = "L3"        # caps
HINT_SPACE = "Y"        # space
HINT_BACKSPACE = "X"    # backspace

# T8 §9g: two badge SHAPES, and the distinction is semantic -- face buttons in
# a white CIRCLE, triggers/stick-clicks in a white ROUNDED RECTANGLE.
# Reproduced with our own glyphs and our own shapes, never Valve's artwork: the
# renderer draws these primitives itself from `hint_shape`.
HINT_SHAPE_CIRCLE = "circle"  # face buttons -- HINT_SPACE, HINT_BACKSPACE
HINT_SHAPE_RECT = "rect"      # triggers and stick clicks -- L2/R2/L3

# T8 §9g's badge gating, confirmed symmetric and PER-PAD: touching a pad hides
# only ITS OWN trigger's badge, because while that pad is in use the trigger
# means "commit this cursor" rather than the idle meaning the badge advertises.
# Ⓧ, Ⓨ and L3 never gate -- face buttons and the stick click are unconditional.
#
# ⚠️ Both shift keys carry L2 even though one of them is drawn in the RIGHT
# half. That is deliberate and it is why this module no longer checks a badge
# against the half its key sits in: L2's idle meaning is Shift wherever the
# Shift key happens to be drawn.
HINT_PAD_GATE: dict[str, str] = {HINT_LEFT: "left", HINT_RIGHT: "right"}


def hint_visible(key: Key, touched: "frozenset[str] | set[str] | tuple" = ()) -> bool:
    """Should this key's badge be drawn, given which pads are being touched?

    `touched` is whichever of "left"/"right" currently have a finger on them.
    Pure, so both renderers ask the same question of the same table.

    ⚠️ §9e's implementation caveat still stands: a lifted pad reports exactly
    0,0, so "untouched" is a real state, but the CALLER has to derive it. This
    function only says what to do with the answer.
    """
    if not key.hint:
        return False
    gate = HINT_PAD_GATE.get(key.hint)
    return gate is None or gate not in touched


def is_action_key(key: Key) -> bool:
    """Is this key drawn BLACK (#000000) rather than dark grey (#0E141B)?

    ⚠️ READ FROM DATA, NOT DERIVED, AND EVERY RULE PROPOSED SO FAR HAS BEEN
    WRONG. "Not a letter and no shifted face" fails on the arrows (dual legends
    and black) and on space (neither, and grey). "Special-function key" fails
    on `Move`, which is grey. "Types nothing" fails on Paste and Backspace,
    which both type and are black. metrics §2 measured row 5 twice, at two
    heights, precisely because the result looks like a bug: `☺ ◀ ▶ Paste` are
    black; `space` and `Move` are grey. The transcription wins over the rule,
    so this reads one flag and does not think.

    Pure and renderer-agnostic on purpose: only the Wayland renderer can PAINT
    the distinction (a bare console has no colour), but the classification
    belongs in the shared core so both renderers read it from one place.
    """
    return key.is_action


# --- glyphs a bare console cannot draw ---------------------------------------
#
# The arrow and emoji faces are the layout's real labels -- §9g's keyboard
# draws arrows, so ours does. A Linux VT running the ISO's console font is not
# guaranteed to have U+25C0 and friends, and mojibake on the installer's only
# keyboard is worse than a plainer glyph. The TTY renderer substitutes; the
# Wayland one does not need to.
#
# ⚠️ These are lossy on purpose. "<" is also the shifted face of ",", so a
# console showing "<" is ambiguous between the two. Ambiguous beats unreadable,
# and only the bare console pays it.
ASCII_FALLBACK: dict[str, str] = {
    "◀": "<", "▶": ">", "▲": "^", "▼": "v", "☺": ":)",
}


def ascii_face(text: str) -> str:
    """`text` with any glyph a bare console may lack swapped for ASCII."""
    return ASCII_FALLBACK.get(text, text)


# --- the layout --------------------------------------------------------------
#
# Transcribed from T8 §9g -- six states captured with `grim` from Valve's own
# keyboard on this Deck, 2026-08-12. ⛔ PLACEMENT ONLY. Not one pixel, glyph or
# asset is copied (docs/findings/P16-redistribution-and-trademark.md); every
# face below is a character we chose ourselves.
#
#   row 1  [~`][!1][@2][#3][$4][%5][^6] | [&7][*8][(9][)0][_-][+=] [Ⓧ Backspace]
#   row 2  [Tab   ] q  w  e  r  t       | y  u  i  o  p  [{[][}]][|\]
#   row 3  [L3 Caps] a  s  d  f  g      | h  j  k  l  [:;]["'] [R2 Enter]
#   row 4  [L2 Shift] z  x  c  v  b     | n  m  [<,][>.][?/]  [L2 Shift]
#   row 5  [☺][Ⓨ ————— space ————————— | —] [▲◀][▼▶] [Paste] [Move]
#
# The `|` marks cell 8, where the right pad's cursor takes over. It is NOT a
# gap and nothing draws it. Every row but the last happens to break on a key
# boundary there; the space bar straddles it deliberately, so either thumb can
# reach space.

WIDTH = 16
SPLIT = 8

# --- visual widths (metrics §2, re-measured) ---------------------------------
#
# 🔴 THESE ARE NOT metrics §2's "x unit" COLUMN, AND THE DIFFERENCE MATTERS.
# That column divides one key's FILL by another key's FILL (149/85 = 1.75 for
# Backspace), which drops the inter-key gap -- so laying a row out with those
# numbers overshoots every wide key by 2-4px and undershoots `~\``. The numbers
# below are PITCH ratios: fill + one gap, over fill + one gap, which is the
# quantity a renderer actually lays out with. They were re-derived by rescanning
# `01-idle.png` row by row for runs of non-gap colour (metrics §1's #23262E),
# reading each key's fill start and end directly.
#
# Reconstructing the reference from them -- five rows, each scaled to
# `1273.5 / row_units`, each key drawn `units * pitch - 4.5` wide -- reproduces
# every measured fill width in metrics §2 to within 1.3px at 1280 (worst case
# the 725px space bar, 0.18%). `test-deck-osk-layout.py` re-runs that
# reconstruction against §2's pixel table rather than trusting these constants.
#
# ⚠️ Row 5 has no unit key in it, so only the RATIOS within that row are
# measured; its absolute scale is chosen to put its total (14.08) among the
# other four rows' (14.02..14.23) rather than derived.
UNITS_GRAVE = 0.52       # 42px fill  -- metrics §2 says 0.49x, see above
UNITS_TAB = 1.03         # 89px fill  -- §2 says 1.05x
UNITS_BACKSPACE = 1.71   # 149px fill -- §2 says 1.75x
UNITS_CAPS = 1.36        # 119px fill -- §2 says 1.40x
UNITS_ENTER = 1.69       # 149px fill -- §2 says 1.75x
UNITS_SHIFT = 2.01       # 178px fill -- §2 says 2.09x
UNITS_ROW5 = 1.20        # 104px fill -- §2 says 1.22x; ☺ ◀ ▶ Paste Move alike
UNITS_SPACE = 8.08       # 725px fill -- §2 says 8.53x, the largest divergence

_D = {  # digits, with their US-layout shifted faces
    "1": sym(e.KEY_1, "1", "!"), "2": sym(e.KEY_2, "2", "@"),
    "3": sym(e.KEY_3, "3", "#"), "4": sym(e.KEY_4, "4", "$"),
    "5": sym(e.KEY_5, "5", "%"), "6": sym(e.KEY_6, "6", "^"),
    "7": sym(e.KEY_7, "7", "&"), "8": sym(e.KEY_8, "8", "*"),
    "9": sym(e.KEY_9, "9", "("), "0": sym(e.KEY_0, "0", ")"),
}

# ⚠️ Both shift keys are the SAME object, reused. That is safe because
# `locate()` returns INDICES rather than keys -- highlighting by comparing Key
# objects would light up both at once, which is exactly why it returns indices.
SHIFT_KEY = act("shift", "Shift", span=3, units=UNITS_SHIFT, hint=HINT_LEFT)
CAPS_KEY = act("caps", "Caps", span=3, units=UNITS_CAPS, hint=HINT_CAPS)
TAB_KEY = act("", "Tab", span=3, units=UNITS_TAB, code=e.KEY_TAB)
BACKSPACE_KEY = act("", "Backspace", span=3, units=UNITS_BACKSPACE,
                    code=e.KEY_BACKSPACE,
                    hint=HINT_BACKSPACE, hint_shape=HINT_SHAPE_CIRCLE)
ENTER_KEY = act("", "Enter", span=2, units=UNITS_ENTER, code=e.KEY_ENTER,
                hint=HINT_RIGHT)
# Space is ONE WIDE KEY with the Ⓨ badge at its LEFT EDGE (§9g), not a separate
# Y key beside a plain space. It straddles SPLIT so either thumb reaches it.
# ⚠️ GREY, not black, despite being the widest special key on the board --
# metrics §2, measured twice. See `Key.is_action`.
SPACE_KEY = act("", "space", span=8, units=UNITS_SPACE, code=e.KEY_SPACE,
                hint=HINT_SPACE, hint_shape=HINT_SHAPE_CIRCLE, is_action=False)

# ⚠️ Shift+Insert rather than Ctrl+V, deliberately. Ctrl+V pastes in a GTK
# entry and types a literal control character in a terminal; Shift+Insert
# pastes in BOTH a VTE terminal and a GTK entry, which is the pair this
# keyboard is actually used in front of. Neither works on a bare Linux VT,
# which has no clipboard at all -- nothing here can fix that.
#
# ⚠️ BLACK, despite modifying nothing and belonging to no group Tab/Backspace/
# Shift/Enter belong to -- metrics §2, measured twice. See `Key.is_action`.
PASTE_KEY = act("", "Paste", span=2, units=UNITS_ROW5, code=e.KEY_INSERT,
                modifiers=(e.KEY_LEFTSHIFT,))

# ⚠️ EMOJI IS THE ONE KEY LEFT THAT NO RENDERER IMPLEMENTS. §9g's keyboard has
# it and the operator asked for "identical"; leaving a visible hole in the
# bottom row would be the bigger divergence. `press()` records the request in
# `OnScreenKeyboard.request` and does NOTHING else -- opening an emoji panel is
# renderer work, and inventing behaviour for it here would be worse than
# recording the ask.
#
# ⚠️ MOVE IS REPURPOSED, NOT UNIMPLEMENTED (operator decision, 2026-08-12,
# made after using the physical keyboard). On Valve's reference this key
# repositions a FLOATING keyboard window; ours is a fixed layer-shell overlay
# with no window to move, so that behaviour was never something a renderer
# could implement here. Rather than leave it dead, Move now collapses the
# keyboard: `press()` routes `action == "move"` through the exact same
# `self.closed = True` as `action == "close"`, which `deck-input-mapper.py`
# already reads at four call sites to hide the overlay -- see that module's
# `osk.closed` reads for the working consumer this reuses.
#
# `self.request` is deliberately NOT set for Move any more. It used to be, but
# nothing anywhere reads `OnScreenKeyboard.request` for "move" -- not this
# module, not the mapper, only this file's own tests, and those are updated
# below to match. `closed` is a complete, already-tested signal on its own, so
# setting `request = "move"` as well would be dead state left for a renderer
# that does not exist, which is exactly what CLAUDE.md says not to leave
# without saying so -- so it is dropped rather than kept "just in case".
#
# ⚠️ Emoji and Move still land on OPPOSITE SIDES of the black/grey split, which
# remains the clearest evidence that split is not a rule: ☺ is black, Move is
# grey, they are the same width and the same kind of key (metrics §2, measured
# twice), and that classification has nothing to do with what either key's
# action does.
EMOJI_KEY = act("emoji", "☺", units=UNITS_ROW5)
MOVE_KEY = act("move", "Move", span=3, units=UNITS_ROW5, is_action=False)

LETTERS = Layer(
    name="letters",
    split=SPLIT,
    rows=(
        # ⚠️ `~` is HALF a letter key wide and one WHOLE cell -- the sharpest
        # case of the two metrics disagreeing (module header).
        (sym(e.KEY_GRAVE, "`", "~", units=UNITS_GRAVE),)
        + tuple(_D[c] for c in "1234567890")
        + (sym(e.KEY_MINUS, "-", "_"), sym(e.KEY_EQUAL, "=", "+"),
           BACKSPACE_KEY),

        (TAB_KEY,) + tuple(letter(c) for c in "qwertyuiop")
        + (sym(e.KEY_LEFTBRACE, "[", "{"), sym(e.KEY_RIGHTBRACE, "]", "}"),
           sym(e.KEY_BACKSLASH, "\\", "|")),

        (CAPS_KEY,) + tuple(letter(c) for c in "asdfghjkl")
        + (sym(e.KEY_SEMICOLON, ";", ":"), sym(e.KEY_APOSTROPHE, "'", '"'),
           ENTER_KEY),

        (SHIFT_KEY,) + tuple(letter(c) for c in "zxcvbnm")
        + (sym(e.KEY_COMMA, ",", "<"), sym(e.KEY_DOT, ".", ">"),
           sym(e.KEY_SLASH, "/", "?"), SHIFT_KEY),

        (EMOJI_KEY, SPACE_KEY,
         # 🔴 §9g: `▲`/`▼` are the SHIFTED FACES of `◀`/`▶` -- TWO keys with
         # dual legends, not four keys. Shift is how a user reaches up and
         # down, and a layout that gave the arrows their own keys would make
         # shift's arrow behaviour unreachable.
         # ⚠️ BLACK, unlike every other dual-legend key on the board (metrics
         # §2, measured twice). See `Key.is_action`.
         sym(e.KEY_LEFT, "◀", "▲", shift_code=e.KEY_UP, units=UNITS_ROW5,
             is_action=True),
         sym(e.KEY_RIGHT, "▶", "▼", shift_code=e.KEY_DOWN, units=UNITS_ROW5,
             is_action=True),
         PASTE_KEY, MOVE_KEY),
    ),
)

# One layer, and that is the whole keyboard: with dual legends on all thirteen
# number-row keys plus the six punctuation keys, every printable ASCII
# character is reachable without a second layer. The `?#=` symbol layer ours
# used to carry has no counterpart in §9g and is gone -- its contents are all
# on this one grid now. `press()` keeps the "layer" action so a future layer
# needs no new mechanism.
LAYERS: dict[str, Layer] = {layer.name: layer for layer in (LETTERS,)}
INITIAL_LAYER = "letters"

SHIFT_CODE = e.KEY_LEFTSHIFT


def _all_keys():
    for layer in LAYERS.values():
        for row in layer.rows:
            yield from row


def keycodes_for(layers) -> frozenset[int]:
    """Every keycode these layers can emit, shift included.

    ⚠️ LOAD-BEARING. A uinput device emits ONLY the codes it declared when it
    was created -- an undeclared code is dropped by the kernel with no error
    anywhere. `deck-input-mapper.py` folds `OSK_KEYCODES` into its own
    EMITTED_KEYS for exactly that reason. If this misses a key, that key is
    dead on the Deck and nothing reports it, which is the failure mode
    CLAUDE.md forbids.

    THREE places a key can hide a code, and every one of them has bitten
    something: its own `code`, the `shift_code` of a key whose shifted face is
    a different key (the arrows), and any `modifiers` it holds (Paste). A
    function rather than a comprehension so a test can hand it a layer built
    for the purpose -- the live layout happens to hold only KEY_LEFTSHIFT as a
    modifier, which is declared anyway, so the modifier arm would otherwise be
    untestable until the day it mattered.
    """
    codes = {SHIFT_CODE}
    for layer in layers:
        for row in layer.rows:
            for key in row:
                if key.code:
                    codes.add(key.code)
                if key.shift_code:
                    codes.add(key.shift_code)
                codes.update(key.modifiers)
    return frozenset(codes)


OSK_KEYCODES: frozenset[int] = keycodes_for(LAYERS.values())


# --- hit-testing (pure) ------------------------------------------------------


CELLS = "cells"
UNITS = "units"


def locate(layer: Layer, half: str, x: float, y: float,
           metric: str = CELLS) -> tuple[int, int] | None:
    """Which (row index, key index) is at (x, y), normalised 0..1 in that half?

    The grid is continuous; `half` selects which range of it this pad's cursor
    addresses. A key straddling the boundary is reachable from both under
    EITHER metric, which is how the space bar works.

    ⚠️ `metric` MUST MATCH WHAT THE CALLER DRAWS, and the default is the
    historical answer so no existing caller changes meaning:

        "cells"  the integer addressing grid -- what `deck_osk_tty.py` draws
                 from (`Layer.cell_bounds`), and what the mapper used before
                 this parameter existed.
        "units"  the measured visual widths -- what a pixel renderer draws from
                 (`Layer.unit_bounds`).

    They agree on which KEYS each half can reach and disagree on where the
    boundaries fall inside it, by up to half a key. A renderer that draws one
    and hit-tests the other lights up a key its cursor is not sitting on.

    Returns None outside the half. A cursor is clamped to its half by
    construction, so None means a caller bug rather than a user miss -- but it
    is still the honest answer, and silently clamping would hide it.

    Renderers need the INDICES, not just the key: highlighting by comparing Key
    objects would light up every cell sharing an instance (space and both shift
    keys are module-level singletons).
    """
    if metric not in (CELLS, UNITS):
        # Guessing a metric would silently mis-place every hit test.
        raise ValueError(f"metric must be {CELLS!r} or {UNITS!r}, got {metric!r}")
    layer.half_cells(half)  # raises on an unknown half, in EITHER metric
    rows = layer.rows
    if not (0.0 <= x <= 1.0 and 0.0 <= y <= 1.0) or not rows:
        return None

    # int() then clamp, rather than rounding: the last row/column owns its
    # closing edge, so y == 1.0 lands on the bottom row instead of off the end.
    row_index = min(int(y * len(rows)), len(rows) - 1)
    row = rows[row_index]
    if not row:
        return None

    if metric == CELLS:
        start, end = layer.half_cells(half)
        # Integer cell arithmetic, not accumulated float fractions: with spans
        # of 2, 3 and 8 in this grid, summing x against fractions drifts at the
        # boundaries and puts a click on the wrong key.
        reach = end - start
        if reach <= 0:
            return None
        cell = start + min(int(x * reach), reach - 1)
        seen = 0
        for key_index, key in enumerate(row):
            seen += key.span
            if cell < seen:
                return (row_index, key_index)
        return (row_index, len(row) - 1)  # unreachable while span >= 1

    start_u, end_u = layer.half_units(row_index, half)
    reach_u = end_u - start_u
    if reach_u <= 0:
        return None
    where = start_u + x * reach_u
    last = 0
    for key_index, (key_start, key_end) in enumerate(layer.unit_bounds(row_index)):
        if key_start >= end_u:
            break   # this key and every one after it is in the other half
        # STRICTLY less-than: a key owns its LEFT edge and not its right, which
        # is the rule the cell branch gets from `int()`. 50 of this layout's
        # interior boundaries are reachable at an exactly-representable x, so
        # this is a case a cursor really does land on, not a limit argument.
        if where < key_end:
            return (row_index, key_index)
        last = key_index
    # No left-hand skip is needed: `where >= start_u`, and a key entirely in
    # the other half has `key_end <= start_u`, so it can never win the test
    # above -- it only walks past.
    #
    # Falling out means x == 1.0, which puts `where` exactly on the half's
    # closing edge. That belongs to the LAST key of this half rather than the
    # first of the next one -- again what the cell branch gets from clamping.
    return (row_index, last)


def key_at(layer: Layer, half: str, x: float, y: float,
           metric: str = CELLS) -> Key | None:
    """Which key is at (x, y), normalised 0..1 WITHIN that half?"""
    found = locate(layer, half, x, y, metric)
    if found is None:
        return None
    return layer.rows[found[0]][found[1]]


# --- the state machine -------------------------------------------------------


class OnScreenKeyboard:
    """Layer, shift and caps state, and the keystrokes a press produces.

    `press()` returns (keycode, value) pairs in the same shape as
    `Mapper.translate()`, so `deck-input-mapper.py` can feed them to the emit
    path it already has rather than growing a second one.
    """

    def __init__(self, layer: str = INITIAL_LAYER) -> None:
        if layer not in LAYERS:
            raise ValueError(f"unknown layer {layer!r}")
        self.layer_name = layer
        self.shift = "off"  # "off" | "once" | "locked"
        self.caps = False   # a SEPARATE modifier -- letters only, see the header
        self.closed = False
        # The last renderer-owned request a press made ("emoji"), for a
        # renderer to pick up and clear. "" once handled. Move used to land
        # here too; it now goes through `closed` instead (see MOVE_KEY), so
        # this only ever holds "emoji" or "".
        self.request = ""
        # Which pads currently have a thumb on them, for §9g's per-pad badge
        # gating. ⚠️ THE OVERLAY CANNOT COMPUTE THIS ITSELF: pad contact is an
        # evdev fact derived from "the last sample was exactly 0,0" (measured
        # on hardware 2026-08-12), and the layer-shell renderer is a separate
        # process that never sees the device. It arrives over the wire; see
        # format_state_line. Defaults to nothing touched, which is the frame
        # where every badge is visible -- a badge wrongly shown is cosmetic, a
        # badge wrongly hidden lies about what the controls do.
        self.touched = {"left": False, "right": False}

    @property
    def layer(self) -> Layer:
        return LAYERS[self.layer_name]

    @property
    def shift_active(self) -> bool:
        """Is SHIFT (not caps) in force? This is what changes the legends."""
        return self.shift in ("once", "locked")

    def shift_applies_to(self, key: Key) -> bool:
        """Is a shifted face in force for THIS key right now?

        Shift hits everything. Caps hits letters only, so a passphrase can mix
        capitals with unshifted digits and working arrow keys without toggling.
        """
        if self.shift_active:
            return True
        return self.caps and key.is_letter

    def face(self, key: Key) -> str:
        """The LARGE legend to draw, under the current state.

        The screen never shows a character the next press will not type; that
        property is the whole reason this function lives in the core rather
        than in a renderer.

        ⚠️ The shift and caps keys keep their own label in every state. They
        used to spell their state into their face ("shift"/"Shift"/"LOCK"),
        which §9g's reference does not do -- it turns the key BLUE instead.
        `modifier_state()` is where that feedback lives now, so a renderer with
        colour can paint it and one without can spell it.
        """
        if key.shift_label and self.shift_applies_to(key):
            return key.shift_label
        return key.label

    def secondary_face(self, key: Key) -> str:
        """The SMALL legend drawn ABOVE `face()`, or "" when there is none.

        T8 §9g's legend rule, and the part ours got wrong on every screen:

          unshifted  -> the shifted face, small, above the base face
          shift      -> "" -- under shift the key shows ONLY its shifted face
          caps       -> unchanged from unshifted, because caps is not shift

        Letters are deliberately excluded: upper and lower case are the same
        glyph, not a different character, and a redundant "Q" over every one of
        26 keys is clutter. Action keys have no `shift_label` at all, so they
        fall out of the same check with no special-casing.
        """
        if key.is_letter or not key.shift_label:
            return ""
        if self.shift_active:
            return ""
        return key.shift_label

    def modifier_state(self, key: Key) -> str:
        """"" unless this key is an ACTIVE modifier, in which case which one.

        T8 §9g: "An active modifier turns BLUE -- both Shift keys under Shift,
        the Caps key when latched. Nothing else changes colour." A renderer
        with colour draws blue on any non-empty answer; the TTY renderer, which
        has neither colour nor a spare row, needs the string to say it in text.

        "once" and "locked" are distinguished because a user who cannot tell a
        one-shot from a lock finds out by typing the wrong case.
        """
        if key.action == "shift":
            return self.shift if self.shift != "off" else ""
        if key.action == "caps":
            return "on" if self.caps else ""
        return ""

    def key_at(self, half: str, x: float, y: float,
               metric: str = CELLS) -> Key | None:
        return key_at(self.layer, half, x, y, metric)

    def locate(self, half: str, x: float, y: float,
               metric: str = CELLS) -> tuple[int, int] | None:
        return locate(self.layer, half, x, y, metric)

    def press(self, key: Key | None) -> list[tuple[int, int]]:
        """Apply a press. Returns the keystrokes to emit, possibly empty."""
        if key is None:
            return []

        if key.action == "shift":
            self.shift = {"off": "once", "once": "locked"}.get(self.shift, "off")
            return []
        if key.action == "caps":
            self.caps = not self.caps
            return []
        if key.action == "layer":
            if key.target not in LAYERS:
                raise ValueError(f"key {key.label!r} targets unknown layer "
                                 f"{key.target!r}")
            self.layer_name = key.target
            return []
        if key.action in ("close", "move"):
            # Move collapses the keyboard exactly like close (operator
            # decision, 2026-08-12): Valve's Move repositions a floating
            # window, ours has no floating window to move, so it is
            # repurposed to dismiss instead. `self.request` is deliberately
            # NOT set here -- nothing reads it (see MOVE_KEY's comment
            # above), and `closed` is the one signal `deck-input-mapper.py`
            # already consumes to hide the overlay.
            self.closed = True
            return []
        if key.action == "emoji":
            self.request = key.action
            return []
        if key.action:
            raise ValueError(f"key {key.label!r} has unknown action {key.action!r}")

        shifted = self.shift_applies_to(key)
        if shifted and key.shift_code:
            # A shifted arrow is a DIFFERENT KEY, not this key with a modifier:
            # SHIFT+KEY_LEFT extends a selection, KEY_UP moves up.
            code, hold_shift = key.shift_code, False
        else:
            code, hold_shift = key.code, shifted
        if not code:
            return []

        # dict.fromkeys de-duplicates while keeping order: Paste already holds
        # shift, and pressing it with a one-shot armed must not press shift
        # twice and release it twice.
        held = list(dict.fromkeys(
            key.modifiers + ((SHIFT_CODE,) if hold_shift else ())
        ))
        strokes = ([(m, 1) for m in held]
                   + [(code, 1), (code, 0)]
                   + [(m, 0) for m in reversed(held)])
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
# ⚠️ Direct, but no longer one-to-one: an INSET of that range covers the whole
# keyboard, so the rim is not needed to reach the outer keys. See
# PAD_EDGE_MARGIN below -- it is the one number here a human is meant to retune.
# That is why the OSK can have two of them while a Wayland seat has one pointer:
# nothing outside this process needs to know either exists.
#
# ⚠️ `ABS_HAT0X/Y` IS THE LEFT TRACKPAD. It is called a hat, advertised as a
# hat, and is not one -- the d-pad is `BTN_DPAD_*`. `deck-input-mapper.py`
# separately reuses those two codes as internal names for "horizontal" and
# "vertical" direction; that reuse stops at its own module boundary and has
# nothing to do with these. Read DEVICE_AXES in the mapper before touching this.

PAD_RANGE = (-32768, 32767)

# --- how much of the pad's travel the keyboard uses (operator, 2026-08-16) ---
#
# 🔴 THIS IS A FEEL CONSTANT AND IT CANNOT BE JUDGED WITHOUT THE HARDWARE IN
# YOUR HANDS. Every other number in this module is a measurement; this one is a
# choice, and it is here to be nudged. The operator's report, typing on the
# installed Deck:
#
#     "the trackpad mapping [is] too insensitive... to type the t for example I
#      have to move my left thumb all the way to the edge of the trackpad to
#      highlight. And then at that edge it's kind of hard to press the thumb."
#
# The cause was that the pad's FULL physical range mapped linearly onto the FULL
# keyboard, so the outermost column demanded the outermost rim of the pad --
# exactly where a thumb has least reach and least leverage, and where pressing
# L2/R2 to commit is hardest. `t` is the last cell of the left half on row 1, so
# it needed 87.5% of the pad's travel before this existed.
#
# So an INSET region of the pad is mapped onto the whole keyboard instead: the
# outer PAD_EDGE_MARGIN of travel on each side, on each axis, is already the
# extreme. At 0.12 the last column starts at 78.5% of travel instead of 87.5%
# and its far edge is reached at 88% instead of 100%.
#
# ⚠️ THE TRADE, both directions, because there is no free setting:
#   larger   the extremes get easier, and the CENTRE gets twitchier -- every
#            count of pad travel covers 1/(1-2m) more keyboard, so a resting
#            thumb wanders further and the middle columns get harder to hold.
#            Past 0.5 the pad would collapse to a point (refused below).
#   smaller  the centre stays calm and the operator's complaint comes back.
#
# ⚠️ THE EXTREMES MUST STAY REACHABLE, and it is the CLAMP below that guarantees
# it, not this number: the inset deliberately overshoots 0..1 and the clamp
# folds the overshoot back onto the outermost cell. Never remove that clamp to
# "fix" the overshoot.
#
# Applies to cursor POSITION, which is the only coordinate there is: the commit
# path hit-tests at `cursors.position(half)` (`deck-input-mapper.py` :1428) and
# both renderers DRAW the dot from the same call, so the drawn dot, the
# highlighted key and the committed key move together. Insetting the commit
# separately would recreate the exact defect session 21 measured, where the key
# drawn white and the key typed disagreed on 287 of 1010 positions.
PAD_EDGE_MARGIN = 0.12

# Derived, so the two never drift: the share of travel that still maps to
# 0..1 after the margins are taken off both ends.
PAD_ACTIVE_SPAN = 1.0 - 2.0 * PAD_EDGE_MARGIN
if not 0.0 <= PAD_EDGE_MARGIN < 0.5:
    # Loud at import rather than silently inverting or dividing by zero: at
    # exactly 0.5 the whole pad is one point, and beyond it every axis runs
    # backwards. CLAUDE.md's "never silently swallow a failure", applied to the
    # one constant in this file a human is expected to edit.
    raise ValueError(
        f"PAD_EDGE_MARGIN must be in [0.0, 0.5), got {PAD_EDGE_MARGIN!r}; "
        "0.0 disables the inset, 0.5 would collapse the pad to a point"
    )

PAD_AXES: dict[int, tuple[str, str]] = {
    e.ABS_HAT0X: ("left", "x"),
    e.ABS_HAT0Y: ("left", "y"),
    e.ABS_HAT1X: ("right", "x"),
    e.ABS_HAT1Y: ("right", "y"),
}

# Each trigger commits its OWN side's cursor. Matching lizard mode's convention
# would put right=left-click, but there are two cursors here and no single
# pointer to left- or right-click: the side is the meaning.
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
        # An INSET region of the pad covers the WHOLE keyboard -- see
        # PAD_EDGE_MARGIN. Done here, in normalised space AFTER each axis's own
        # absinfo, so the four axes may advertise four different ranges (the
        # mapper re-reads absinfo per axis on every re-enumeration, and this
        # module has never been able to assume the two pads agree) and each one
        # still gives up the same PROPORTION of its own travel.
        fraction = (fraction - PAD_EDGE_MARGIN) / PAD_ACTIVE_SPAN
        # ⚠️ LOAD-BEARING TWICE OVER. The device may exceed absinfo -- and the
        # inset above overshoots 0..1 BY CONSTRUCTION, for every reading in the
        # outer margin. Folding that overshoot back onto the ends is what keeps
        # the outermost column and row selectable at all; without it the fix
        # would make the last column UNREACHABLE, which is worse than the
        # complaint it answers.
        fraction = min(1.0, max(0.0, fraction))
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
    """Which (keycode, shifted) types `ch`? None if the layout cannot.

    A key needing extra modifiers (Paste) is skipped: this returns one code and
    one shift flag, and a caller that pressed it would emit the wrong thing.
    """
    shifted_hit = None
    for key in _all_keys():
        if not key.types or key.modifiers:
            continue
        if key.label == ch and key.code:
            return (key.code, False)  # prefer the unshifted face
        if key.shift_label == ch and shifted_hit is None:
            # A shifted face that is a different KEY (the arrows) types itself
            # with no modifier held.
            if key.shift_code:
                shifted_hit = (key.shift_code, False)
            elif key.code:
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
#
# ⚠️ CAPS IS AN OPTIONAL EIGHTH FIELD, and that is deliberate rather than lazy.
# The writer (the mapper) and the readers (both renderers) are separate
# processes started separately, and during a rolling change one of them is the
# old build. A seven-field line still parses, with caps off -- which is what an
# older writer that has no caps state actually means.

STATE_FIELDS = 7  # without the optional trailing caps flag


def parse_state_line(line: str) -> dict | None:
    """`state <layer> <shift> <lx> <ly> <rx> <ry> [caps] [ltouch rtouch]`.

    Returns a dict, or None for anything it cannot make sense of.

    ⚠️ GROWN TWICE, BOTH TIMES BACKWARD-COMPATIBLY, AND THAT IS DELIBERATE.
    The layer-shell keyboard is a SEPARATE PROCESS (T8 step 7: a GTK crash
    must not take the only input path on the device down with it), so this
    line is the entire contract between the mapper and what a user sees.
    An older mapper talking to a newer overlay, or the reverse, happens
    every time one is deployed without the other -- `stage-input-mapper`
    installs both, but a hand-run debug build routinely mixes them.

    Fields 8 (caps) and 9-10 (pad touch) are therefore OPTIONAL, and their
    absence means the safe default: no caps, nothing touched. "Nothing
    touched" is the safe default because it is §9f's all-badges-visible
    frame -- a badge shown when it should be hidden is cosmetic; a badge
    hidden when the trigger really does something is a lie about the
    controls.
    """
    parts = line.split()
    if not parts or parts[0] != "state":
        return None
    if len(parts) not in (STATE_FIELDS, STATE_FIELDS + 1, STATE_FIELDS + 3):
        return None
    _, layer, shift, lx, ly, rx, ry = parts[:STATE_FIELDS]
    caps_field = parts[STATE_FIELDS] if len(parts) > STATE_FIELDS else "off"
    touch_fields = parts[STATE_FIELDS + 1:STATE_FIELDS + 3] or ["up", "up"]
    if layer not in LAYERS or shift not in ("off", "once", "locked"):
        return None
    if caps_field not in ("on", "off"):
        return None
    if any(t not in ("down", "up") for t in touch_fields):
        return None
    try:
        values = [float(v) for v in (lx, ly, rx, ry)]
    except ValueError:
        return None
    if not all(0.0 <= v <= 1.0 for v in values):
        return None
    return {"layer": layer, "shift": shift, "caps": caps_field == "on",
            "left": (values[0], values[1]), "right": (values[2], values[3]),
            "touched": {"left": touch_fields[0] == "down",
                        "right": touch_fields[1] == "down"}}


def format_state_line(keyboard: OnScreenKeyboard, cursors: Cursors,
                     touched: dict | None = None) -> str:
    """The mapper's side of the same protocol.

    `touched` is `{"left": bool, "right": bool}` -- `Mapper.pad_touched()`
    for each half. It drives §9g's per-pad badge gating, which the overlay
    cannot compute for itself: pad contact is an evdev fact, and the overlay
    never sees the device. Omitted means "nothing touched", i.e. every badge
    visible.
    """
    left, right = cursors.position("left"), cursors.position("right")
    touched = touched or {}
    lt = "down" if touched.get("left") else "up"
    rt = "down" if touched.get("right") else "up"
    return (f"state {keyboard.layer_name} {keyboard.shift} "
            f"{left[0]:.4f} {left[1]:.4f} {right[0]:.4f} {right[1]:.4f} "
            f"{'on' if keyboard.caps else 'off'} {lt} {rt}\n")


def apply_state(keyboard: OnScreenKeyboard, cursors: Cursors,
                state: dict) -> None:
    keyboard.layer_name = state["layer"]
    keyboard.shift = state["shift"]
    keyboard.caps = bool(state.get("caps", False))
    keyboard.touched = dict(state.get("touched", {"left": False, "right": False}))
    for half in ("left", "right"):
        cursors.pos[half] = [state[half][0], state[half][1]]
