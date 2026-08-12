#!/usr/bin/env python3
"""deck_osk_wayland -- Desktop Mode's on-screen keyboard, as a layer-shell overlay.

T8 step 5. Same layout core as the installer's TTY keyboard
(`deck_osk_layout`), drawn with GTK4 + gtk4-layer-shell instead of characters.

    deck_osk_wayland.py            # read state lines on stdin (the mapper)
    deck_osk_wayland.py --demo     # draw a fixed pose and stay up, for eyes

⚠️ THIS DOES NOT TAKE INPUT FROM WAYLAND, AND THAT IS THE WHOLE DESIGN.

    T8's "escalate if" was: the overlay cannot take input without stealing
    focus from the field being typed into. It is designed away rather than
    solved. Input arrives from the PAD, over evdev, in the mapper process --
    this surface only ever draws. So it asks the compositor for nothing:

      * `KeyboardMode.NONE`  -- never focused, so the text field keeps focus
      * an EMPTY input region -- pointer events pass straight through to
        whatever is underneath, and the overlay cannot be clicked at all

    Typing leaves through the mapper's uinput keyboard, which the compositor
    delivers to the focused surface exactly as it would a real one. Nothing
    under the keyboard knows a controller or an overlay exists.

    This is the property squeekboard cannot have: it IS a surface being
    pointed at, so it needs the pointer, so a Wayland seat's single pointer
    is the ceiling (docs/PROGRESS.md §2.6). Ours needs neither.

⚠️ SEPARATE PROCESS, DELIBERATELY. The mapper spawns this and feeds it state
    on stdin. With `lizard_mode=N` the mapper is the ONLY input path on the
    device (docs/PROGRESS.md §5.9, §5.21), so a GTK crash, a compositor
    restart, or a missing library must not be able to take it down. The cost
    is a pipe; the alternative is a handheld with no input.

DEPENDENCIES -- both already present on the Deck and both in Arch `extra`,
    never the AUR (CLAUDE.md): `gtk4-layer-shell` and `python-gobject`.
    `gi` is imported inside main(), not at module scope, so the pure geometry
    below is importable and testable on a machine with neither.
"""

from __future__ import annotations

import ctypes.util
import os
import sys

import deck_osk_layout as osk

# --- ⚠️ the linking trap, found by running it --------------------------------
#
# gtk4-layer-shell works by interposing on libwayland-client, so it MUST be
# loaded first. Under PyGObject it never is: `import gi.repository.Gtk` pulls in
# libwayland-client through GTK before anything of ours runs, and there is no
# link order to fix because nothing here is linked.
#
# The failure is quiet in the way that matters. The process starts, GTK warns on
# stderr, and a perfectly normal WINDOW appears -- floating, focusable, stealing
# keyboard focus from the field being typed into. Every behaviour this design
# depends on is gone and the only evidence is a warning line, which is precisely
# the shape of defect this project keeps finding on screens rather than in logs.
#
# Upstream's documented escape is LD_PRELOAD, so the program arranges its own:
# it re-execs itself once with the library preloaded. Doing it here rather than
# in the mapper keeps the knowledge with the code that needs it -- a caller that
# forgot would get a normal window and a warning.

LAYER_SHELL_SONAME = "libgtk4-layer-shell.so"


def _ensure_layer_shell_preloaded() -> None:
    """Re-exec once with gtk4-layer-shell preloaded, if it is not already."""
    if LAYER_SHELL_SONAME in os.environ.get("LD_PRELOAD", ""):
        return  # already done: this is the second exec, or a caller set it
    found = ctypes.util.find_library("gtk4-layer-shell")
    if not found:
        print("deck-osk-wayland: cannot find gtk4-layer-shell to preload; the "
              "overlay would come up as an ordinary focusable window. "
              "sudo pacman -S --needed gtk4-layer-shell",
              file=sys.stderr, flush=True)
        raise SystemExit(2)
    env = dict(os.environ)
    existing = env.get("LD_PRELOAD", "")
    env["LD_PRELOAD"] = f"{found}:{existing}" if existing else found
    os.execve(sys.executable,
              [sys.executable, os.path.abspath(__file__)] + sys.argv[1:], env)

# --- geometry (pure: no GTK, no display, no compositor) ----------------------
#
# The layout core answers in 0..1 within a half; this turns that into pixels
# and back. It is separate from the drawing for the same reason the TTY
# renderer's row model is: the correctness is here, and it is testable with no
# screen. `test-deck-osk-wayland.py` asserts the round trip -- every drawn key
# rectangle must hit-test back to the key it was drawn for.

# 🔴 THERE IS NO GUTTER, AND THERE MUST NEVER BE ONE AGAIN.
#
#     This file used to split the surface into two half-grids with 48 blank
#     pixels between them. The operator saw it beside the real thing -- "i
#     still see a gap between the left half and the right half" -- and the
#     reference was then measured: `docs/findings/T8-reference-metrics.md` §6
#     puts ours at ~62px of dead space where Valve's has the ordinary ~4.5px
#     inter-key gap. Ten times too wide; a whole key of nothing.
#
#     `Layer.split` is a CURSOR-ADDRESSING boundary, not a visual one. Keys are
#     placed from `Layer.cell_bounds()` across the FULL width, and the split
#     only tells `cursor_pixel` which cell range a given thumb ranges over. The
#     space bar straddles it deliberately, which a drawn gap could not even
#     represent.

HALVES = ("left", "right")

# `docs/findings/T8-reference-metrics.md` §1: a 3px bar in `#79A0F7` spans the
# full width directly above the keyboard whenever it is being driven, and is
# absent at idle. In the reference it sits just OUTSIDE the panel (the panel
# starts at y=430; the bar is y=427..429), so the band is reserved at the top
# of our own surface -- ALWAYS reserved, painted only when in use. Reserving it
# unconditionally is the whole point: a band that appeared and disappeared
# would shift every key by 3px the instant a modifier was pressed.
STRIPE_HEIGHT_RATIO = 3.0 / 358.0


def stripe_height(height: float) -> float:
    """Pixels reserved at the top of the surface for the in-use stripe."""
    return min(max(1.0, height * STRIPE_HEIGHT_RATIO), height)


def grid_origin(height: float) -> tuple[float, float]:
    """(top y, height) of the key grid itself, below the reserved stripe."""
    top = stripe_height(height)
    return (top, height - top)


def key_rects(layer: osk.Layer, width: float, height: float) -> list[tuple]:
    """Every key's pixel rectangle: (row, col, x, y, w, h).

    ONE CONTINUOUS GRID (T8 §9g). `Layer.cell_bounds` gives each key its
    [start, end) cells in a row that is `Layer.width` cells wide on EVERY row,
    so columns line up all the way down and a ragged row cannot be drawn.
    There is no `half` in the answer any more: a key belongs to the grid, and
    whether a given thumb can REACH it is a separate question that
    `half_pixel_range` answers.
    """
    top, grid_h = grid_origin(height)
    row_h = grid_h / len(layer.rows)
    cell_w = width / layer.width
    out = []
    for row_index in range(len(layer.rows)):
        for key_index, (start, end) in enumerate(layer.cell_bounds(row_index)):
            out.append((row_index, key_index,
                        start * cell_w, top + row_index * row_h,
                        (end - start) * cell_w, row_h))
    return out


def half_pixel_range(layer: osk.Layer, half: str, width: float) -> tuple[float, float]:
    """(x start, x end) of the cell range this pad's cursor addresses.

    ⚠️ NOT a drawn boundary -- nothing paints it, and nothing may. It exists
    because a cursor reports 0..1 WITHIN its half and has to be placed on a
    full-width grid.
    """
    start, end = layer.half_cells(half)  # raises on an unknown half
    cell_w = width / layer.width
    return (start * cell_w, end * cell_w)


def cursor_pixel(layer: osk.Layer, half: str, position: tuple[float, float],
                 width: float, height: float) -> tuple[float, float]:
    """A cursor's 0..1 position within its half, in surface pixels."""
    x0, x1 = half_pixel_range(layer, half, width)
    top, grid_h = grid_origin(height)
    return (x0 + position[0] * (x1 - x0), top + position[1] * grid_h)


# --- appearance ---------------------------------------------------------------
#
# ⛔ NOT VALVE'S ARTWORK. Every value below is a NUMBER READ OFF A SCREENSHOT
# and every mark is drawn from primitives this file already has -- rectangles,
# circles and Cairo's own font API. Placement and metrics transcribed from
# measurement are fine; assets are not
# (`docs/findings/P16-redistribution-and-trademark.md`).
#
# 📐 EVERY colour and ratio here comes from `docs/findings/T8-reference-metrics.md`,
# measured 2026-08-12 from `grim` captures of the reference keyboard on this
# exact panel. Nothing is inlined at a call site: retuning the look means
# editing this block and nothing else. Where the metrics doc says ESTIMATED,
# the constant says so too.
#
# Deliberately not themed, and that predates the parity work: this has to be
# legible over an unknown wallpaper on a handheld held at arm's length, and a
# theme that follows the desktop can make it invisible. Cairo's toy font API
# rather than Pango -- one fewer dependency.


def _rgba(hex_colour: str, alpha: float = 1.0) -> tuple[float, float, float, float]:
    """`"#0E141B"` -> Cairo's 0..1 floats. The metrics doc speaks in hex; so
    does this file, so a value can be diffed against the doc by eye."""
    h = hex_colour.lstrip("#")
    return (int(h[0:2], 16) / 255.0, int(h[2:4], 16) / 255.0,
            int(h[4:6], 16) / 255.0, alpha)


# metrics §1. ⚠️ FULLY OPAQUE, measured: the gap colour is bit-for-bit
# identical over a purple browser dropdown and over saturated game art, which
# an alpha-blended panel could not be. Ours used to be 0.94 alpha.
PANEL_FILL = _rgba("#23262E")
KEY_FACE = _rgba("#0E141B")          # letters, digits, punctuation
KEY_FACE_ACTION = _rgba("#000000")   # metrics §2's black keys -- see is_action
MODIFIER_ACTIVE = _rgba("#1A9FFF")   # §9g's blue: shift held, caps latched
CURSOR_FACE = _rgba("#FFFFFF")       # the cursor INVERTS the key face
CURSOR_DOT_FILL = _rgba("#8CCFFF")   # a lighter blue than MODIFIER_ACTIVE
CURSOR_DOT_RING = _rgba("#7F7F7F")   # measured, and NOT antialiasing (§1)
KEY_TEXT = _rgba("#FFFFFF")
KEY_TEXT_INVERTED = _rgba("#000000")  # on a cursor's white face
# metrics §1 calls this one "a rough read, not a clean flat sample" -- the
# glyph is a few pixels thick and mixes with antialiasing everywhere. Near
# white, slightly down.
SECONDARY_TEXT = _rgba("#EBEBF3")
# On a cursor's white face the near-white secondary legend would vanish, so it
# inverts with everything else -- grey rather than black, so it still reads as
# the smaller, quieter of the two faces.
CURSOR_TEXT_SECONDARY = _rgba("#3A3A42")
BADGE_FILL = _rgba("#FFFFFF")
BADGE_TEXT = _rgba("#000000")        # ESTIMATED in metrics §1, not isolated
# metrics §1: a solid 3px bar above the keyboard in every "in use" frame and
# absent at idle. ⚠️ The gating condition is OBSERVED, not proven -- 4/4
# non-idle frames, but not every combination was tested.
STRIPE_FILL = _rgba("#79A0F7")

# 🔴 SQUARE CORNERS, measured (metrics §0.1). Key corners in the reference step
# from border colour to fill in ONE pixel, in x and y independently, with no
# diagonal blend -- at the key level and at the panel's own outer corner. Ours
# had a 6px radius and a visible 2-3px antialiased gradient, so matching means
# REMOVING rounding, not adding it. §9d's "dark rounded keys" was wrong.
# Badges keep their shapes; only key faces are square.
KEY_CORNER = 0.0

# metrics §2: rows are 66px tall and inter-key/inter-row gaps are a flat 4-5px
# at 1280x800, i.e. one gap of ~4.5px. Expressed against ROW HEIGHT so the
# whole keyboard scales with the panel instead of pinning to one resolution.
# The gap between two keys is twice this, because each key insets its own face.
KEY_GAP_RATIO = 4.5 / 66.0

# metrics §3. The base glyph is ~17px of cap height in a 66px row; a sans-serif
# cap height is ~0.72 of its point size, so ~0.36 of the row.
FACE_SIZE_RATIO = 0.36
# 🔴 metrics §0.2 CORRECTS §9g: the shift-active face is NOT larger than the
# small dual-legend glyph -- same size, RE-CENTRED from high in the key to the
# key's vertical middle. Measured on `!`, `@` and `&`: bboxes match within
# antialiasing noise, only the y-centre moves (~32% -> ~53% down).
SECONDARY_SIZE_RATIO = 0.85
# Where each legend's optical centre sits, as a fraction down the row.
SECONDARY_CENTRE_Y = 0.32   # the small shifted face, high in the key
FACE_CENTRE_Y_DUAL = 0.69   # the large base face, low in the key
FACE_CENTRE_Y_SOLO = 0.50   # one legend only: the key's own middle
# Fraction of a key's inner width a label may occupy before `_fit` shrinks it.
LABEL_WIDTH_BUDGET = 0.86

# metrics §4: the dot is ~24-25px across with a ~3px #7F7F7F ring, ~29-31px
# outer, in a 66px row.
CURSOR_DOT_RATIO = 24.5 / 66.0   # diameter, against row height
CURSOR_RING_RATIO = 3.0 / 66.0   # ring thickness, against row height

# metrics §5: face-button badges are 26x26px circles, trigger/stick badges
# ~30x26px rounded rects, and BOTH sit ~23.5px from their key's left edge and
# ~61-67% down the 66px row -- lower half, not dead centre.
BADGE_SIZE_RATIO = 26.0 / 66.0
BADGE_CENTRE_X_RATIO = 23.5 / 66.0
BADGE_CENTRE_Y_RATIO = 0.64
BADGE_MIN_WIDTH_RATIO = 30.0 / 26.0   # of the badge's own height, for "L2"
BADGE_TEXT_RATIO = 0.62               # glyph size within the badge
BADGE_CORNER_RATIO = 0.30             # ESTIMATED: metrics §5 did not trace it

# The reference's legends are a proportional sans, not a monospace. Named
# rather than inlined so a machine missing it has one line to change.
FONT_FAMILY = "sans-serif"

# metrics §2: the reference panel is y=430..788 on an 800px-tall screen. Ours
# was 0.42, which measured ~14% short on every row.
HEIGHT_FRACTION = 358.0 / 800.0


TAU = 6.283185307179586


def touched_halves(keyboard: osk.OnScreenKeyboard) -> frozenset:
    """Which pads have a finger on them, as `hint_visible` wants it.

    `OnScreenKeyboard.touched` is a `{"left": bool, "right": bool}` dict fed
    over the wire by `parse_state_line`/`apply_state`; an old writer that omits
    the fields means NOTHING touched, which is T8 §9f's every-badge-visible
    frame. `getattr` because this renderer must keep running against a core
    that predates the field rather than crash the only keyboard on the device.
    """
    state = getattr(keyboard, "touched", None) or {}
    return frozenset(half for half in HALVES if state.get(half))


def in_use(keyboard: osk.OnScreenKeyboard, touched) -> bool:
    """Is the keyboard being DRIVEN right now? -- the stripe's gate.

    ⚠️ OBSERVED, NOT PROVEN (`docs/findings/T8-reference-metrics.md` §1). The
    stripe is present in all four non-idle captures -- shift held, caps
    latched, either pad touched -- and absent in both idle ones. That is the
    best-fitting rule from the evidence and not a measured law; it is one
    predicate, here, if a later capture disagrees.
    """
    return bool(keyboard.shift_active or keyboard.caps or touched)


def draw(cr, keyboard: osk.OnScreenKeyboard, cursors: osk.Cursors,
         width: float, height: float) -> None:
    """Paint the keyboard. `cr` is a Cairo context; nothing else is needed."""
    layer = keyboard.layer
    touched = touched_halves(keyboard)

    cr.set_source_rgba(*PANEL_FILL)
    cr.rectangle(0, 0, width, height)
    cr.fill()

    top, grid_h = grid_origin(height)
    if in_use(keyboard, touched):
        cr.set_source_rgba(*STRIPE_FILL)
        cr.rectangle(0, 0, width, top)
        cr.fill()

    row_h = grid_h / len(layer.rows)
    pad = row_h * KEY_GAP_RATIO / 2.0

    # 🔴 NOTHING IS DRAWN AT THE SPLIT. Both cursors are resolved against the
    # same continuous grid, and a key either half can reach (the space bar
    # straddles cell 8) simply lights for whichever thumb is on it.
    hot = {found for found in
           (keyboard.locate(half, *cursors.position(half)) for half in HALVES)
           if found is not None}

    cr.select_font_face(FONT_FAMILY)
    for row_index, key_index, x, y, w, h in key_rects(layer, width, height):
        key = layer.rows[row_index][key_index]
        is_hot = (row_index, key_index) in hot
        # T8 §9g's precedence, and it only ever bites on the shift/caps keys:
        # the cursor's white face WINS over an active modifier's blue, because
        # "where is my thumb" is the answer that changes every frame and the
        # modifier is still legible from the other shift key.
        if is_hot:
            face_colour, ink = CURSOR_FACE, KEY_TEXT_INVERTED
        elif keyboard.modifier_state(key):
            face_colour, ink = MODIFIER_ACTIVE, KEY_TEXT
        elif osk.is_action_key(key):
            face_colour, ink = KEY_FACE_ACTION, KEY_TEXT
        else:
            face_colour, ink = KEY_FACE, KEY_TEXT

        fx, fy = x + pad, y + pad
        fw, fh = w - 2 * pad, h - 2 * pad
        _key_face(cr, fx, fy, fw, fh)
        cr.set_source_rgba(*face_colour)
        cr.fill()
        # ⚠️ No stroked edge. The reference has none: keys are solid rects on
        # the panel's own paint and the "border" IS the gap (metrics §1).

        # T8 §9g's legend rule, which ours got wrong on every screen before
        # this. `secondary_face()` owns the state machine -- it returns "" the
        # moment shift is active, which is what collapses a dual legend down to
        # the single shifted face.
        label = keyboard.face(key)
        secondary = keyboard.secondary_face(key)
        base_size = row_h * FACE_SIZE_RATIO
        small_size = base_size * SECONDARY_SIZE_RATIO
        # A badge is drawn INSIDE its key at the left, so the legend is centred
        # in what is left rather than over the top of it -- which is what the
        # reference does (its `Ⓧ Backspace` reads as two marks, not one on top
        # of another) and what ours did NOT do: `R2` and `Enter` collided.
        badged = osk.hint_visible(key, touched)
        lx, lw = fx, fw
        if badged:
            edge = min(_badge_right_edge(cr, key, fx, row_h) + pad, fx + fw)
            lx, lw = edge, max(fx + fw - edge, 1.0)
        if secondary:
            _text(cr, secondary, lx, lw, y + row_h * SECONDARY_CENTRE_Y,
                  _fit(cr, secondary, lw, small_size),
                  CURSOR_TEXT_SECONDARY if is_hot else SECONDARY_TEXT)
            _text(cr, label, lx, lw, y + row_h * FACE_CENTRE_Y_DUAL,
                  _fit(cr, label, lw, base_size), ink)
        else:
            # 🔴 metrics §0.2: under shift the lone shifted face is the SAME
            # SIZE as the small legend it replaced, only re-centred. It is not
            # enlarged, however much §9g's prose said "larger".
            size = small_size if _shift_only_face(keyboard, key) else base_size
            _text(cr, label, lx, lw, y + row_h * FACE_CENTRE_Y_SOLO,
                  _fit(cr, label, lw, size), ink)

        # Which controller button fires this key. §9g's gate is PER-PAD:
        # touching a pad hides only its own trigger's badge, because while that
        # pad is in use the trigger means "commit this cursor" rather than the
        # idle meaning the badge advertises. Ⓧ/Ⓨ/L3 never gate. The whole rule
        # lives in `hint_visible`, so both renderers ask one table.
        if badged:
            _hint_badge(cr, key, fx, y, row_h, inverted=is_hot)

    # The exact cursor point, on top of the inverted key face. The white face
    # answers "which key"; the dot answers "where within it", which is what
    # tells a user which way to move when they are between two keys. Both
    # cursors are drawn identically -- metrics §6: the reference has ONE cursor
    # treatment, not a colour per thumb, and ours used to tint whole keys cyan
    # and amber instead.
    dot_r = row_h * CURSOR_DOT_RATIO / 2.0
    ring = row_h * CURSOR_RING_RATIO
    for half in HALVES:
        cx, cy = cursor_pixel(layer, half, cursors.position(half), width, height)
        cr.set_source_rgba(*CURSOR_DOT_RING)
        cr.arc(cx, cy, dot_r + ring, 0, TAU)
        cr.fill()
        cr.set_source_rgba(*CURSOR_DOT_FILL)
        cr.arc(cx, cy, dot_r, 0, TAU)
        cr.fill()


def _shift_only_face(keyboard: osk.OnScreenKeyboard, key: osk.Key) -> bool:
    """Is this key showing its shifted face ALONE because shift is active?

    Letters are excluded: their two faces are the same glyph in two cases, so
    they never had a small legend to shrink back to.
    """
    return bool(keyboard.shift_active and key.shift_label and not key.is_letter)


def _key_face(cr, x, y, w, h) -> None:
    """The key's own shape. 🔴 SQUARE -- see KEY_CORNER."""
    if KEY_CORNER <= 0:
        cr.rectangle(x, y, w, h)
        return
    _rounded(cr, x, y, w, h, KEY_CORNER)


def _rounded(cr, x, y, w, h, r) -> None:
    from math import pi
    r = min(r, w / 2, h / 2)
    cr.new_sub_path()
    cr.arc(x + w - r, y + r, r, -pi / 2, 0)
    cr.arc(x + w - r, y + h - r, r, 0, pi / 2)
    cr.arc(x + r, y + h - r, r, pi / 2, pi)
    cr.arc(x + r, y + r, r, pi, 3 * pi / 2)
    cr.close_path()


# ⛔ WE DRAW THESE OURSELVES, and not only for the licence reason.
#
# DejaVu Sans -- what `sans-serif` resolves to on the Deck and in the ISO --
# carries U+25B2/U+25BC (▲ ▼) but NOT U+25C0/U+25B6 (◀ ▶): the left and right
# arrows came out as tofu boxes on the very first render. A missing glyph on
# the installer's only keyboard is exactly the kind of defect this project
# keeps finding on screens rather than in logs, and font coverage is not
# something the ISO can promise. Four filled triangles from Cairo primitives
# depend on no font at all, and they match each other in weight, which four
# glyphs from two different Unicode blocks would not.
#
# (x, y) unit vectors: apex first, then the two base corners.
ARROW_GLYPHS: dict[str, tuple[tuple[float, float], ...]] = {
    "◀": ((-0.5, 0.0), (0.5, -0.5), (0.5, 0.5)),
    "▶": ((0.5, 0.0), (-0.5, -0.5), (-0.5, 0.5)),
    "▲": ((0.0, -0.5), (-0.5, 0.5), (0.5, 0.5)),
    "▼": ((0.0, 0.5), (-0.5, -0.5), (0.5, -0.5)),
}
ARROW_SIZE_RATIO = 0.62   # of the font size it stands in for


def _arrow(cr, glyph: str, cx: float, cy: float, size: float, colour) -> None:
    """One of `ARROW_GLYPHS`, filled, centred on (cx, cy)."""
    span = size * ARROW_SIZE_RATIO
    points = ARROW_GLYPHS[glyph]
    cr.new_sub_path()
    cr.move_to(cx + points[0][0] * span, cy + points[0][1] * span)
    for px, py in points[1:]:
        cr.line_to(cx + px * span, cy + py * span)
    cr.close_path()
    cr.set_source_rgba(*colour)
    cr.fill()


def _text(cr, text: str, x: float, w: float, centre_y: float, size: float,
          colour) -> None:
    """`text` centred horizontally in [x, x+w] and vertically about `centre_y`."""
    if not text:
        return
    if text in ARROW_GLYPHS:
        _arrow(cr, text, x + w / 2.0, centre_y, size, colour)
        return
    cr.set_font_size(size)
    extents = cr.text_extents(text)
    cr.move_to(x + (w - extents.width) / 2 - extents.x_bearing,
               centre_y - extents.height / 2 - extents.y_bearing)
    cr.set_source_rgba(*colour)
    cr.show_text(text)


def _hint_badge(cr, key: osk.Key, key_x: float, row_y: float, row_h: float,
                inverted: bool = False) -> None:
    """The badge naming the button that fires this key.

    Placed from measurement (`docs/findings/T8-reference-metrics.md` §5): the
    centre sits ~23.5px from the key's left FILL edge and ~64% down a 66px row
    -- the lower half, not dead centre -- and that same offset holds for a
    149px Backspace and a 725px space bar alike, so it is an offset from the
    left edge and not a fraction of the key.

    ⛔ Our own primitives and our own strings, never Valve's artwork. The SHAPE
    is semantic and measured: face buttons in a 26x26 circle, triggers and
    stick clicks in a ~30x26 rounded rectangle. `key.hint_shape` selects;
    anything unrecognised falls back to the rectangle.

    `inverted` is for a key under a cursor, whose face is white -- a white
    badge on a white key is an invisible badge.
    """
    cx, cy, badge_w, badge_h = _badge_box(cr, key, key_x, row_y, row_h)
    fill = BADGE_TEXT if inverted else BADGE_FILL
    ink = BADGE_FILL if inverted else BADGE_TEXT

    if key.hint_shape == osk.HINT_SHAPE_CIRCLE:
        cr.new_sub_path()
        cr.arc(cx, cy, badge_h / 2.0, 0, TAU)
    else:
        _rounded(cr, cx - badge_w / 2.0, cy - badge_h / 2.0, badge_w, badge_h,
                 badge_h * BADGE_CORNER_RATIO)
    cr.set_source_rgba(*fill)
    cr.fill()

    cr.set_font_size(badge_h * BADGE_TEXT_RATIO)
    extents = cr.text_extents(key.hint)
    cr.set_source_rgba(*ink)
    cr.move_to(cx - extents.width / 2 - extents.x_bearing,
               cy - extents.height / 2 - extents.y_bearing)
    cr.show_text(key.hint)


def _badge_box(cr, key: osk.Key, key_x: float, row_y: float,
               row_h: float) -> tuple[float, float, float, float]:
    """(centre x, centre y, width, height) of this key's badge.

    Shared by the badge itself and by the legend, which is centred in what the
    badge leaves rather than on top of it. ⚠️ Sets the Cairo font size as a
    side effect, because a rounded rect's width depends on the string inside.
    """
    badge_h = row_h * BADGE_SIZE_RATIO
    cx = key_x + row_h * BADGE_CENTRE_X_RATIO
    cy = row_y + row_h * BADGE_CENTRE_Y_RATIO
    if key.hint_shape == osk.HINT_SHAPE_CIRCLE:
        return (cx, cy, badge_h, badge_h)
    cr.set_font_size(badge_h * BADGE_TEXT_RATIO)
    width = max(badge_h * BADGE_MIN_WIDTH_RATIO,
                cr.text_extents(key.hint).width + badge_h * 0.3)
    return (cx, cy, width, badge_h)


def _badge_right_edge(cr, key: osk.Key, key_x: float, row_h: float) -> float:
    """Where a badge stops, so a legend can start after it."""
    cx, _cy, width, _h = _badge_box(cr, key, key_x, 0.0, row_h)
    return cx + width / 2.0


def _fit(cr, label: str, w: float, size: float) -> float:
    """`size`, shrunk until `label` fits inside `w`.

    Word labels ("Backspace", "space") are much longer than "q", and a single
    size either overflows them or wastes the letters. The TTY renderer hit the
    same thing and answered it with a wider cell; here the size can just
    shrink, which is what the reference does too -- its Backspace legend is
    visibly smaller than its letters.
    """
    if not label or w <= 0 or label in ARROW_GLYPHS:
        return size
    budget = w * LABEL_WIDTH_BUDGET
    cr.set_font_size(size)
    measured = cr.text_extents(label).width
    if measured <= budget:
        return size
    # One proportional step, because Cairo's advance widths scale linearly with
    # the font size, and then a few small ones because HINTING does not: a
    # fixed number of blind 0.88 steps used to give up quietly on a narrow key,
    # which is the failure mode CLAUDE.md forbids.
    if measured > 0:
        size *= budget / measured
    for _ in range(6):
        cr.set_font_size(size)
        if cr.text_extents(label).width <= budget:
            break
        size *= 0.94
    return size


# --- the overlay --------------------------------------------------------------


def main() -> int:
    import argparse

    ap = argparse.ArgumentParser(description="Desktop Mode's on-screen keyboard")
    ap.add_argument("--demo", action="store_true",
                    help="draw a fixed pose and stay up, instead of reading stdin")
    ap.add_argument("--height", type=int, default=0, metavar="PX",
                    help="overlay height in pixels "
                         "(default: %.2f%%%% of the output, measured)"
                         % (HEIGHT_FRACTION * 100))
    ap.add_argument("--no-exclusive", action="store_true",
                    help="do not reserve space; overlap the window underneath")
    args = ap.parse_args()

    # Before `import gi`, and it may not return -- see the note at the top.
    _ensure_layer_shell_preloaded()

    # Imported here, not at module scope: the geometry above must stay testable
    # on a machine with no GTK and no display.
    try:
        import gi
        gi.require_version("Gtk", "4.0")
        gi.require_version("Gtk4LayerShell", "1.0")
        from gi.repository import Gtk, GLib, Gtk4LayerShell as LayerShell
        import cairo
    except (ImportError, ValueError) as exc:
        print(f"deck-osk-wayland: cannot load GTK4 + gtk4-layer-shell ({exc}). "
              "Both are in Arch [extra]: "
              "sudo pacman -S --needed gtk4-layer-shell python-gobject",
              file=sys.stderr, flush=True)
        return 2

    keyboard = osk.OnScreenKeyboard()
    cursors = osk.Cursors()

    app = Gtk.Application(application_id="dev.pizzarchy.DeckOsk")

    def on_activate(_app):
        window = Gtk.ApplicationWindow(application=app)
        LayerShell.init_for_window(window)
        LayerShell.set_layer(window, LayerShell.Layer.OVERLAY)
        LayerShell.set_namespace(window, "deck-osk")
        for edge in (LayerShell.Edge.LEFT, LayerShell.Edge.RIGHT, LayerShell.Edge.BOTTOM):
            LayerShell.set_anchor(window, edge, True)
        # ⚠️ NONE, not ON_DEMAND. The overlay must never be focusable: the whole
        # point is that the text field being typed into keeps keyboard focus
        # while this is on screen.
        LayerShell.set_keyboard_mode(window, LayerShell.KeyboardMode.NONE)

        height = args.height
        if height <= 0:
            display = window.get_display()
            monitors = display.get_monitors()
            geometry = monitors.get_item(0).get_geometry() if monitors.get_n_items() else None
            height = int((geometry.height if geometry else 800) * HEIGHT_FRACTION)
        window.set_default_size(-1, height)
        if not args.no_exclusive:
            # Reserve the space, so the compositor moves the focused window up
            # instead of letting the keyboard cover the field being typed into.
            LayerShell.set_exclusive_zone(window, height)

        area = Gtk.DrawingArea()
        area.set_draw_func(lambda _a, cr, w, h: draw(cr, keyboard, cursors, w, h))
        window.set_child(area)
        window.present()

        # Empty input region: every pointer event passes through to whatever is
        # underneath. Set after present(), because the surface does not exist
        # until then.
        surface = window.get_surface()
        if surface is not None:
            surface.set_input_region(cairo.Region())

        if args.demo:
            cursors.update(0x10, -32000)   # ABS_HAT0X, left cursor left
            cursors.update(0x11, 3000)     # ABS_HAT0Y
            cursors.update(0x12, -20000)   # ABS_HAT1X
            cursors.update(0x13, 3000)     # ABS_HAT1Y
            area.queue_draw()
            return

        def on_stdin(_fd, condition):
            line = sys.stdin.readline()
            if not line:              # the mapper closed the pipe: we are done
                app.quit()
                return GLib.SOURCE_REMOVE
            if line.strip() == "quit":
                app.quit()
                return GLib.SOURCE_REMOVE
            state = osk.parse_state_line(line)
            if state is not None:
                osk.apply_state(keyboard, cursors, state)
                area.queue_draw()
            return GLib.SOURCE_CONTINUE

        GLib.unix_fd_add_full(GLib.PRIORITY_DEFAULT, sys.stdin.fileno(),
                              GLib.IOCondition.IN, on_stdin)

    app.connect("activate", on_activate)
    return app.run([])


if __name__ == "__main__":
    sys.exit(main())
