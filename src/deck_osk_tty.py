#!/usr/bin/env python3
"""deck_osk_tty -- the installer's on-screen keyboard, drawn on a bare TTY.

T8 step 4. The live ISO has **no Wayland compositor of any kind** -- measured
on the built 4.0 ISO, `docs/findings/T2-gamepad-spike.md` §4 -- so the screen
where a Wi-Fi passphrase gets typed has no surface to put a keyboard on. This
draws one out of characters instead.

WHY TEXT AND NOT THE FRAMEBUFFER
    A framebuffer OSK would be a true overlay, and would also be invisible to
    every tool that can observe a console: `tmux capture-pane`, a serial log,
    the existing `test/vm/vm-gamepad-spike-test.sh` harness. Text costs some
    polish and buys a keyboard that can be ASSERTED ON, in CI, without a
    screen or a human. Given this project's history -- three separate paths
    that were present, enumerated and silent -- that trade is not close.

    It also removes the whole font-rendering problem, and a console font is
    not guaranteed to carry box-drawing glyphs. Everything here is ASCII,
    including the arrows and the emoji key -- see `osk.ascii_face`.

ONE CONTINUOUS GRID, NO GUTTER (T8 §9g)
    🔴 Changed 2026-08-12 with the layout core. The keyboard used to be two
    half-grids drawn side by side with `GUTTER` blank columns between them;
    the operator's first words on seeing ours next to Valve's were "i still
    see a gap between the left half and the right half". `Layer.split` is a
    CURSOR-ADDRESSING boundary and nothing draws it. `GUTTER` is gone, not
    set to zero: there is no gap to tune.

    Keys are placed from `Layer.cell_bounds(row)`, so a key's columns are
    derived from the one grid rather than from a per-half loop that could
    drift from it.

TWO CURSORS, WITHOUT A POINTER
    Each cursor highlights the key it is over rather than floating between
    them. For a keyboard that is not a compromise: the question a user is
    asking is "which key am I on", and snapping answers it exactly. It is also
    what makes two cursors possible at all -- there is no pointer to own.

    The highlight is **brackets as well as reverse video**. Reverse video alone
    is invisible to `tmux capture-pane` without `-e`, unreadable on some console
    fonts, and gone entirely in a plain log. `[ q ]` survives all three.

    ⚠️ TWO CURSORS CAN LAND ON ONE KEY, and since §9g the space bar straddles
    `split` precisely so either thumb can reach it. When they do, ONE cell is
    highlighted, not two. Anything counting highlights must count cells and not
    assume the number of pads.

WHAT THIS MODULE DOES NOT DO
    It does not own the screen. `render()` returns lines; the caller decides
    where they go. The installer's TUI is drawing on the same console, so
    something has to keep them apart -- see `write_at()` and the note there.

    It also does not, and cannot, draw COLOUR or SHAPE. §9g asks for three
    things this renderer has no primitive for: action keys visibly darker than
    letter keys, two badge shapes (a circle for face buttons, a rounded
    rectangle for triggers/stick-clicks), and an ACTIVE MODIFIER DRAWN BLUE. A
    bare console has neither a second shade nor a curve -- everything here is
    the SAME colour and the SAME rectangle of characters.

    Two of the three degrade to nothing rather than to a lie: `is_action` is
    simply not drawn, and every badge degrades to the same one text convention
    (see `display_label`). The third does NOT get to degrade to nothing --
    a user who cannot see that Shift is armed finds out by typing the wrong
    case into a passphrase field they cannot read back. So modifier state is
    SPELLED OUT IN WORDS, which is the one channel a colourless console still
    has. `MODIFIER_TEXT` is that decision; `display_label` gives it priority
    over the badge when both cannot fit.

WHO IT MAY SHARE A CONSOLE WITH -- A POLICY, AND IT IS MEASURED
    **Line-oriented prompts, and nothing else.** `gum input` and its siblings
    lay out in their top few rows and never reach the bottom, so the keyboard
    takes the rows underneath and both stay legible: proven in QEMU, with
    `gum.received = hlH1` typed from the trackpads (R-47).

    **A full-screen curses TUI is not shareable, and it does not fail the way
    it looks like it should.** Measured, R-52. The keyboard draws over such a
    TUI perfectly well -- five rows of five. What breaks it is the TUI's next
    repaint, and an ORDINARY curses repaint does not erase the keyboard at all:
    ncurses diffs against its own model of the physical screen, which has never
    heard of us, so it rewrites only the cells whose content changed and
    punches a single character through each keyboard row. Five intact rows
    become zero while the screen still looks like a keyboard. Only a hard clear
    -- `clearok`, which is what upstream's own `clear_logo` does on every
    validation failure (T4 §2.5) -- actually removes it. Going the other way,
    one pad sample repaints the keyboard and takes five rows off the TUI, which
    has no idea it lost them. Neither side is wrong and neither yields.

    🔴 THAT LAST SENTENCE CHANGED IN P33 B2 AND THE CONCLUSION DID NOT. Since
    `write_at` paints only the cells that changed, an ordinary pad sample no
    longer takes ANY rows off a co-tenant -- it usually writes nothing at all.
    Do not read that as the two now coexisting. It cuts the other way as well:
    this module remembers what it drew, so a TUI that punches a character
    through a keyboard row is no longer repaired by the next pad sample either.
    Both directions of R-52's damage are now quieter and neither is fixed.
    `FULL_REPAINT_EVERY` bounds our side of it; the policy below is still what
    makes the question moot.

    ⚠️ A ROW WHOSE LABELS NOW LIE is the whole reason `rows_on_screen` exists.
    A punched-through row still reads as a keyboard -- to a human and to every
    substring check -- while one label per row is no longer the label this
    module drew there (the layer key read `2#=` for `?#=`, R-52's own capture).
    `grep -c shift` returned 1 after BOTH ordinary
    repaints, i.e. on every screen where the keyboard had in fact been
    destroyed, and only went to 0 after the hard clear, by which point there
    was nothing left to catch. That is R-49's defect exactly, from a new cause:
    count the rows, do not grep the word.

    So the keyboard is **summoned for the duration of one text-entry prompt
    and killed after it** (`docs/tasks/T4-screen-spec.md` §2.3), and T4 §1's
    decision to WRAP upstream's configurator rather than replace it is what
    makes that sufficient rather than hopeful: every text-entry moment in the
    installer is a prompt function of ours (§1.2), and archinstall's own curses
    menu never runs at all -- upstream drives the install from the JSON the
    wrapped configurator wrote (§1.1). The two do not coexist by construction,
    so no pty relay has to make them.
"""

from __future__ import annotations

import weakref

import deck_osk_layout as osk

# Characters per unit-span key -- THE FALLBACK, for a caller that names no
# console. `cell_width_for()` below is what a caller with a real console uses.
#
# 🔴 5 IS A MEASUREMENT OF ONE CONSOLE AND IT STOPPED BEING TRUE (P33 B1,
# `docs/PROGRESS.md` §5.34 D3). Since T8 §9g the layout is ONE grid of
# `Layer.width` == 16 cells, and §7 measured the two consoles this was written
# for: the live ISO's 50x160 and **the installed TTY's 25x80, on the same
# panel**. 16 * 5 == 80 EXACTLY, so 5 was the unique fit -- for ONE of those two
# consoles. On the OTHER, the live ISO's 160, the same 80 columns is HALF THE
# SCREEN, which is a large part of why §5.34 D3 reads "far too small on a 7"
# panel". And the fix for legibility is a BIGGER CONSOLE FONT, which gives FEWER
# COLUMNS -- at which point a hardcoded 80 is REFUSED by `write_at`'s own column
# guard and the installer has no keyboard at all on the screen where a Wi-Fi
# passphrase is typed. A constant is wrong in both directions at once.
#
# ⚠️ HOW MANY COLUMNS THE DECK ACTUALLY HAS IS DISPUTED, AND THIS CODE DOES NOT
# NEED TO KNOW. `docs/tasks/P33-fix-round.md` §A3 reads the 800x1280 panel as
# 100 columns at 8x16 and 50 at 16x32; §7's MEASURED live-ISO console is 50x160,
# and 160 * 8 == 1280, which makes the same two fonts 160 and 80. Reading the
# width at runtime is what makes the disagreement irrelevant, and it is what §7
# says to do anyway.
#
# So the cell width is DERIVED FROM THE COLUMN COUNT AT DRAW TIME. This constant
# survives only as the answer for `render()` called without one, and it is
# deliberately still 5 so that every caller and test written against the 25x80
# console keeps its exact previous output. Nothing about 5 is a law.
#
# ⚠️ THE LABELS ARE THE FLOOR, NOT THE ARITHMETIC. §5.34 D3 proposed 3 on the
# strength of `cell_text` drawing `[q]` at width 3 -- true, and not the binding
# constraint. `display_label`'s budget is `span * cell - 2`, and at cell 4 the
# widest labels are `Backspace` (9, budget 10) and `Shift LOCK` (10, budget 10);
# at cell 3 both overflow and `NARROW_LABELS` is what keeps them whole. Below 3 a
# highlighted unit cell is `[]` with no room for the face at all, so 3 is a hard
# floor and not a preference. `test-deck-osk-tty.py` asserts NOTHING is ever
# truncated, at every span, in every shift/caps state, AT EVERY CELL WIDTH.
KEY_CELL = 5

# The narrowest cell that can still show a face. A highlight spends two columns
# on `[` and `]`, so at 2 there is nothing left to centre into and every key
# would draw as `[]`. Refusing is better than that, and `write_at`'s column
# guard is what does the refusing -- see `cell_width_for`.
MIN_KEY_CELL = 3


def cell_width_for(console_cols: int, grid_cells: int) -> int:
    """The widest cell that fits `grid_cells` of them into `console_cols`.

    ⚠️ NEVER RETURNS SOMETHING TOO NARROW TO READ, AND NEVER LIES ABOUT FITTING.
    On a console too narrow even for `MIN_KEY_CELL` this returns `MIN_KEY_CELL`
    anyway -- deliberately a width that does NOT fit -- so the drawn keyboard is
    wider than the console and `write_at`'s existing `console_cols` guard
    refuses it, loudly, exactly as it always has. Clamping to something that fit
    would silently draw `[]` for every key, which is the failure this project
    forbids: present, enumerated and useless.

    There is no upper clamp. On the live ISO's 160 columns this returns 10 and
    the keyboard fills the console, which is what the one-continuous-grid model
    already wanted (T8 §9g) and what makes the keys as large as the screen
    allows -- the entire point of §5.34 D3.
    """
    if grid_cells <= 0:
        raise ValueError(f"a grid needs at least one cell, got {grid_cells}")
    return max(MIN_KEY_CELL, console_cols // grid_cells)

# ⛔ There is no GUTTER any more, and it is deliberately not defined as 0.
# T8 §9g: one continuous keyboard, no gap. `Layer.split` addresses cursors; it
# draws nothing. A name still in scope would invite something to space by it.

REVERSE = "\x1b[7m"
RESET = "\x1b[0m"

# A rendered row is a list of (text, highlighted) segments.
Segment = tuple[str, bool]


def cell_text(label: str, width: int, highlighted: bool) -> str:
    """One key, drawn to exactly `width` characters.

    Highlighted and plain are the SAME width -- a highlight that changed the
    width would shift every key to its right as a cursor moved, which reads as
    the whole keyboard twitching.
    """
    if highlighted:
        inner = label.center(width - 2)[: width - 2]
        return f"[{inner}]"
    return label.center(width)[:width]


# --- visual parity with SteamOS's keyboard (T8 §9g, degraded honestly) --------
#
# 🔴 AN ACTIVE MODIFIER IS BLUE ON THE REFERENCE AND WE HAVE NO COLOUR, so it
# is spelled. `OnScreenKeyboard.modifier_state()` answers "" | "once" |
# "locked" | "on"; this is the word each becomes, appended to the key's face.
#
# WHY WORDS RATHER THAN A SYMBOL OR AN ATTRIBUTE:
#   * Reverse video is already taken -- it is the CURSOR, and a second meaning
#     for one attribute makes an armed Shift indistinguishable from a Shift the
#     thumb happens to be resting on.
#   * Bold/underline survive neither `tmux capture-pane` without `-e` nor a
#     plain serial log, which is the medium this module chose in the first
#     place (see the header). Words survive all three, and grep.
#   * A bare marker (`*`, `!`) has to be learnt and cannot distinguish a
#     one-shot from a lock. That distinction is not cosmetic: a user who cannot
#     tell them apart finds out by typing the wrong case, and this keyboard's
#     job is a Wi-Fi passphrase that is echoed as dots.
#
# ONCE and LOCK are the same length on purpose, so the Shift key's drawn width
# does not change as it cycles off -> once -> locked; only its text does.
MODIFIER_TEXT: dict[str, str] = {"once": "ONCE", "locked": "LOCK", "on": "ON"}

# 🔴 FACES FOR A CONSOLE TOO NARROW TO SPELL THEM (P33 B1). Keyed by the face
# `osk.ascii_face()` produces, so this table never has to know about the layout's
# own glyphs.
#
# ⚠️ THESE EXIST BECAUSE THE ALTERNATIVE IS TRUNCATION, WHICH IS SILENT.
# `cell_text` crops, so without this the 50-column console draws `Ente`, `Backspa`
# and `Shift LOC` -- each of which still reads as a word and is not the word.
# `test-deck-osk-tty.py`'s no-truncation invariant runs at every cell width
# precisely so a new key with a long label fails the suite here rather than
# cropping on the one keyboard the installer has.
#
# ⚠️ AND THEY LIVE IN THE RENDERER, NOT IN `deck_osk_layout`. Running out of
# columns is a bare console's problem: the Wayland renderer has pixels and draws
# the full word. A `short_label` on `Key` would put a console's constraint into
# the shared core, where the other renderer would have to remember to ignore it.
#
# Chosen so the abbreviation is the conventional keycap one where there is one
# (`Bksp`) and otherwise keeps the first letters, which is what a user scanning
# a keyboard actually matches on. `Sh` exists so the MODIFIER WORD survives: at
# cell 3 a span-3 budget is 7, `Shift LOCK` is 10 and `Sh LOCK` is exactly 7 --
# and `display_label`'s own ladder says the modifier word is the LAST thing
# dropped, because a user who cannot see that Shift is armed finds out by typing
# the wrong case into a field echoed as dots.
#
# ⚠️ `:)` -> `:` IS A REAL LOSS AND IT IS THE LEAST BAD ONE AVAILABLE. The emoji
# key is span 1, so at cell 3 its budget is ONE column and no two-character face
# fits. It is also the one key no renderer implements (`osk.EMOJI_KEY`'s comment:
# `press()` records the request and does nothing), so a degraded face costs a
# user a key that does nothing anyway -- whereas truncating it to `[:]` would
# look like a punctuation key that types a colon, which is a lie about what the
# key does.
NARROW_LABELS: dict[str, str] = {
    "Backspace": "Bksp",
    "Enter": "Entr",
    "Paste": "Pste",
    "Shift": "Sh",
    "Caps": "Cap",
    ":)": ":",
}


def display_label(kb: osk.OnScreenKeyboard, key: osk.Key,
                  cell: int = KEY_CELL) -> str:
    """The text `cell_text` draws for one key.

    Built from three things the core supplies, in descending priority when they
    cannot all fit:

      1. `face()` -- always drawn.
      2. `modifier_state()` -- §9g's blue, spelled (`MODIFIER_TEXT`).
      3. either `secondary_face()`, the shifted legend §9g draws SMALL ABOVE,
         or the controller-button badge. Never both: no key in the layout has
         both a `shift_label` and a `hint` (asserted in `test-deck-osk-tty.py`).

    ⚠️ §9g's SMALL-ABOVE BECOMES BESIDE. A console has one type size, so
    "smaller" is not available; drawing a second console line per grid row
    would double the keyboard's height without buying the size difference that
    made the reference readable. `1 !` beside is the honest degrade, and it is
    what fits three columns.

    ⚠️ THE BADGE IS THE FIRST THING DROPPED, THE MODIFIER WORD THE LAST. A
    missing badge costs a user a shortcut they can also reach by aiming at the
    key; a missing modifier word costs them the case of a character they cannot
    read back. Nothing in today's layout actually overflows -- every candidate
    below fits at KEY_CELL=5 -- so the ladder is exercised by synthetic keys in
    the suite rather than left as an untested claim.

    ⚠️ BADGES ARE NOT PAD-GATED HERE, though `osk.hint_visible()` exists and
    the Wayland renderer uses it. §9g hides a trigger badge while that pad is
    touched; doing that on a console would make a key's drawn TEXT depend on
    something that changes several times a second, and `rows_on_screen` (docs
    on `face_of`) compares a REFERENCE render against a console captured
    afterwards. A badge that came and went between the two would make every
    row count a race -- the same trap the paragraph below records paying for
    once already. The badge names a BUTTON, which is true whether or not a
    thumb is on the pad.

    ⚠️ THE SAME TEXT WHETHER THE KEY IS HIGHLIGHTED OR NOT, DELIBERATELY --
    THIS IS NOT AN OVERSIGHT, IT IS THE ONE THING THIS FUNCTION MUST NEVER DO.
    `rows_on_screen` assumes a key's drawn TEXT is invariant to the cursor's
    position: only the brackets and reverse video may differ, because that
    machinery compares a reference render against a console read after the
    cursors had time to move. A hint that appeared cold and vanished hot would
    make that comparison a race, and a first version of this function did
    exactly that: it passed the unit suite that exercises `display_label`
    directly and then failed "the highlight having moved does not lose a row"
    two hundred lines later, for a reason that took a while to see. Fixed by
    deciding ONCE, against the TIGHTER of the two budgets a key will ever be
    drawn at (`key.span * cell - 2`, the highlighted one -- brackets always
    cost exactly 2 columns), and applying that decision unconditionally.

    ⚠️ `cell` IS THE WIDTH THIS KEYBOARD IS BEING DRAWN AT, NOT A CONSTANT ANY
    MORE (P33 B1). It defaults to `KEY_CELL` so a caller that names no console
    gets exactly the label it always got; `render()` passes the width it derived
    from the console's real column count. Passing a different number here from
    the one the cell is drawn at is the one way to reintroduce truncation, which
    is why `render` derives the budget and the drawn width from the same value.
    """
    face = osk.ascii_face(kb.face(key))
    secondary = osk.ascii_face(kb.secondary_face(key))
    state = MODIFIER_TEXT.get(kb.modifier_state(key), "")
    # "" when there is no shorter form. Empty rungs are filtered out below
    # rather than branched around, so every ladder reads the same way.
    narrow = NARROW_LABELS.get(face, "")

    if secondary:
        candidates = (f"{face} {secondary}", face, narrow)
    elif state:
        # ⚠️ THE SHORTENED FACE STILL CARRYING THE MODIFIER WORD (`Sh LOCK`)
        # COMES BEFORE THE FULL FACE WITHOUT IT. That is this function's own
        # priority order, applied one rung further down than it used to reach:
        # the badge goes first, the modifier word last.
        candidates = (f"{key.hint} {face} {state}" if key.hint else "",
                      f"{face} {state}",
                      f"{narrow} {state}" if narrow else "",
                      face, narrow)
    else:
        candidates = (f"{key.hint} {face}" if key.hint else "", face, narrow)

    candidates = tuple(text for text in candidates if text)
    budget = key.span * cell - 2  # the highlighted width -- the tighter one
    for text in candidates:
        if len(text) <= budget:
            return text
    # Nothing fits, not even the bare face. Returning it anyway lets `cell_text`
    # truncate, which the suite's no-truncation invariant turns red on --
    # inventing a shorter label here would hide that instead.
    return candidates[-1]


def render(kb: osk.OnScreenKeyboard, cursors: osk.Cursors,
           console_cols: int | None = None) -> list[list[Segment]]:
    """The keyboard as rows of (text, highlighted) segments.

    Pure: no escape sequences, no file descriptors, no terminal size. Both the
    ANSI writer below and the tests consume this, so what CI asserts on is the
    same structure a user sees.

    🔴 `console_cols` IS THE CONSOLE'S REAL WIDTH AND IT SIZES THE KEYS (P33 B1,
    §5.34 D3). Given it, the grid is drawn at the widest cell that fits -- 100
    columns gives 6, 80 gives 5, 50 gives 3 -- so a bigger console font makes
    the keys BIGGER rather than making the keyboard vanish behind
    `write_at`'s column guard. `None` keeps `KEY_CELL`, which is what a caller
    with no geometry to offer should get: this function stays PURE, so it cannot
    read the console for itself, and guessing a width it was not told would be
    the assumption `docs/PROGRESS.md` §7 says never to make.

    ⚠️ The caller must pass the SAME width to `write_at`'s `console_cols` guard.
    They are not redundant: this one sizes the keys, that one refuses to draw
    what will not fit, and on a console too narrow even for `MIN_KEY_CELL` the
    second is what stops a keyboard being drawn off the edge.

    One continuous grid (T8 §9g): every row spans all `Layer.width` cells and
    each key's columns come from `Layer.cell_bounds`, so the drawn width cannot
    drift from the grid the hit test uses. `Layer.__post_init__` already refuses
    a layer whose rows disagree on width, which is why nothing here re-checks
    it -- the ragged-layer guard this function used to carry belonged to the old
    two-half model and is gone with it.
    """
    layer = kb.layer
    cell = (KEY_CELL if console_cols is None
            else cell_width_for(console_cols, layer.width))
    # ⚠️ A SET OF CELLS, NOT ONE PER HALF. Both cursors can be over the SAME key
    # -- the space bar straddles `split` exactly so either thumb reaches it --
    # and that key is one highlighted cell, drawn once.
    hot_cells = {found for found in
                 (kb.locate(half, *cursors.position(half))
                  for half in ("left", "right"))
                 if found is not None}

    out: list[list[Segment]] = []
    for row_index, row in enumerate(layer.rows):
        bounds = layer.cell_bounds(row_index)
        segments: list[Segment] = []
        for key_index, key in enumerate(row):
            start, end = bounds[key_index]
            hot = (row_index, key_index) in hot_cells
            segments.append((
                cell_text(display_label(kb, key, cell), (end - start) * cell, hot),
                hot,
            ))
        out.append(segments)
    return out


def to_plain(rows: list[list[Segment]]) -> str:
    """Rows as text with no escape sequences.

    This is what `tmux capture-pane` shows without `-e`, and what a serial log
    keeps -- so it is what the VM suite asserts against.
    """
    return "\n".join("".join(text for text, _ in row) for row in rows)


def to_ansi(rows: list[list[Segment]]) -> str:
    """Rows with reverse video on the highlighted keys, for a real console."""
    lines = []
    for row in rows:
        line = "".join(
            f"{REVERSE}{text}{RESET}" if hot else text for text, hot in row
        )
        lines.append(line)
    return "\n".join(lines)


def width(rows: list[list[Segment]]) -> int:
    """Rendered width in columns. Every row is the same width by construction."""
    return max((sum(len(text) for text, _ in row) for row in rows), default=0)


def face_of(cell: str) -> str:
    """The key face a drawn cell shows, whether or not it is highlighted.

    `[  q  ]` and `   q   ` are the same key under two cursors, so a check that
    reads a console back must not care which one it finds -- the cursors move
    between a render and a read, and a keyboard that is intact except for where
    the highlight sits is intact.

    ⚠️ Geometry, not string surgery, and the punctuation keys are why: `[` and
    `]` are KEYS on this layout. A plain one draws as ` [ {`, whose first
    column is a space, so it is read as its own face and not as an empty
    highlight. A highlighted one draws as `[[ {]` and unwraps to the same face.
    """
    if len(cell) >= 2 and cell[0] == "[" and cell[-1] == "]":
        return cell[1:-1].strip()
    return cell.strip()


def rows_on_screen(screen: str, rows: list[list[Segment]]) -> list[int]:
    """Which 1-based lines of `screen` carry a WHOLE rendered keyboard row.

    ⚠️ COUNT THE ROWS. DO NOT GREP FOR A WORD. R-49's defect was five keyboard
    rows clamped onto one line by a console that had shrunk underneath them:
    garbled, unusable, and still carrying the word `Shift` -- so `osk.shown=1`
    passed and a human glancing at a screenshot saw "a keyboard". R-52 then
    reproduced the same lie from the opposite direction: a full-screen TUI
    repainting every line but the last leaves exactly the function row alive,
    which is the row `space` is on. Only the count separates those from a
    keyboard that is actually on screen.

    `screen` is the console as text, one line per console row. `/dev/vcsN`
    folded to the console's width is exactly that, and is the kernel's own copy
    of the screen rather than a reconstruction of it (R-47).

    A line counts only if EVERY cell of some rendered row is on it, at the
    column that row puts it. Partial credit is the thing being guarded against:
    half a keyboard row is not a keyboard row, and a user typing on it has no
    way to tell. Columns to the right of the keyboard are not inspected -- the
    keyboard is `Layer.width` times whatever cell width it was RENDERED at and
    does not own anything past that. It takes the rendered `rows` rather than
    re-deriving that width for exactly this reason: since P33 B1 the width
    depends on the console the keyboard was drawn on, so a checker that computed
    it from a constant would disagree with the screen on any console but one.
    """
    return [n for n, line in enumerate(screen.split("\n"), start=1)
            if any(_line_carries(line, row) for row in rows)]


def _line_carries(line: str, row: list[Segment]) -> bool:
    """Is this whole rendered row present on this console line, cell for cell?"""
    column = 0
    for text, _highlighted in row:
        cell = line[column:column + len(text)]
        # A short slice means the line ended inside the keyboard -- a narrower
        # console, or a capture that truncated. That is not an intact row, and
        # padding it out with spaces to make it compare would invent one.
        if len(cell) != len(text) or face_of(cell) != face_of(text):
            return False
        column += len(text)
    return True


# --- what a repaint costs, and how often it happens (P33 B2, §5.34 D4) -------
#
# 🔴 MEASURED BEFORE IT WAS CHANGED, because §5.34 D4 says "rate is unmeasured
# -- measure before fixing". `deck-input-mapper.py`'s loop redraws ONCE PER READ
# BATCH from the pad fd (its own comment: "Redraw once per batch, not per event")
# and the pads run at 250 Hz, so one second of a thumb on the pad was:
#
#     write_at calls  250      erase-to-end-of-line  1250
#     stream writes   250      bytes                 116750
#     cursor moves    1250
#
# Five rows, each BLANKED (`\x1b[K`) and repainted, 250 times a second, on a
# framebuffer console with no double buffering and a 90 Hz panel -- about
# fourteen blank-then-paint cycles per displayed frame, of a keyboard that is
# usually IDENTICAL to the one already on screen. A thumb resting perfectly
# still cost exactly as much as one sweeping the pad. That is the flicker.
#
# ⚠️ IT WAS NEVER THE NUMBER OF `write()` CALLS. There is one per draw already,
# and coalescing draws would only make the cursor lag the thumb. What the panel
# sees is the ERASE: `\x1b[K` blanks a row, and the scanout catches the gap.
#
# So: paint only the CELLS whose text actually changed, and never blank a cell
# that is about to be overwritten with the same width of text. A cursor moving
# one cell changes two cells; a thumb resting changes none.
#
# ⚠️ AND THE PRICE, STATED PLAINLY: this module now remembers what it last put
# on a stream, so it can be WRONG about what is on the screen. Anything else
# drawing over the keyboard leaves damage that an identical frame will no longer
# repair. Three things bound that:
#
#   1. The policy in this module's header -- the keyboard and a full-screen TUI
#      are never up at the same time -- which is what made R-52 survivable in
#      the first place. This does not weaken it; it relies on it, and says so.
#   2. `FULL_REPAINT_EVERY`: every Nth draw repaints unconditionally, so damage
#      heals within a bounded number of draws instead of never.
#   3. The cache key carries the geometry and the row count, so a resized
#      console (R-49: `stty cols` RESIZES a Linux VT) or a moved keyboard is a
#      full repaint, not a diff against a screen that no longer exists.
#
# 60 is a quarter-second of pad motion at 250 Hz. Low enough that damage is
# transient at human timescales, high enough that the erase rate falls by more
# than an order of magnitude. It is a count and not a clock deliberately: a
# clock would make this untestable without one.
FULL_REPAINT_EVERY = 60

# stream -> (key, rows, draws-since-the-last-full-repaint). Weak, so a closed
# tty is not held alive by its own last frame, and keyed by the stream OBJECT so
# two consoles (the VM suite draws on tty2 and tty3) cannot read each other's.
_LAST_FRAME: "weakref.WeakKeyDictionary" = weakref.WeakKeyDictionary()


def _drawn(text: str, highlighted: bool, ansi: bool) -> str:
    """One segment exactly as it goes on the wire."""
    return f"{REVERSE}{text}{RESET}" if (ansi and highlighted) else text


def forget(stream) -> None:
    """Drop what this module thinks is on `stream`, so the next draw is full.

    Anything that puts something else in the keyboard's rows must call this --
    `clear_at` does. Not calling it is not a crash, it is a keyboard that does
    not come back for up to `FULL_REPAINT_EVERY` draws, which is the quiet kind
    of wrong this module exists to avoid.
    """
    try:
        _LAST_FRAME.pop(stream, None)
    except TypeError:
        pass  # a stream with no memory has nothing to forget; see `write_at`


def write_at(stream, rows: list[list[Segment]], top_row: int, *,
             ansi: bool = True, console_rows: int | None = None,
             console_cols: int | None = None, full: bool = False) -> None:
    """Draw the keyboard with its first line at `top_row` (1-based).

    ⚠️ THE INSTALLER'S TUI IS DRAWING ON THIS SAME CONSOLE, and the obvious way
    to keep them apart DOES NOT WORK. Measured in QEMU (R-49): on a Linux VT,
    `TIOCSWINSZ` does not merely change the size reported to applications --
    **it resizes the console itself**. `stty rows 45` on a 50-row console makes
    `/dev/vcs2` 45 rows long and rows 46-50 cease to exist.

    So "shrink the TUI's window and draw underneath it" is self-defeating: the
    rows you shrank the TUI out of are the same rows you just deleted. What
    happened instead was silent and much worse than an error -- the kernel
    clamped all five keyboard rows onto the last line, where they overwrote
    each other, leaving one garbled row that still greps as a keyboard.

    `console_rows` is the guard. Given it, a draw that would fall outside the
    console REFUSES and raises, rather than painting five rows onto one.

    🔴 `console_cols` IS THE SAME GUARD ON THE OTHER AXIS, and since §9g the
    keyboard needs every column the installed TTY has (see `KEY_CELL`). A row
    wider than the console does not get clipped -- the VT WRAPS it, so each
    keyboard row becomes two, the rows below are pushed down, and the bottom of
    the keyboard scrolls off exactly the way R-49's did. Same silent failure,
    same treatment: refuse loudly.

    ⚠️ BOTH GUARDS ARE OPT-IN, and a caller that reads neither geometry gets
    neither check. `docs/PROGRESS.md` §7 is explicit that the two consoles this
    ships to differ (50x160 live, 25x80 installed) and that geometry is to be
    READ AT RUNTIME, never assumed -- so a caller drawing on a real console
    should pass both.

    🔴 AND THE FONT MOVES BOTH OF THEM. Those two consoles are the SAME PANEL at
    two font sizes (160 * 8 == 1280 == 80 * 16), so pinning a bigger console font
    for legibility changes the column count under this guard. That is the whole
    argument for `render`'s `console_cols` (P33 B1): a caller that passes this
    guard the real width and then renders at a constant gets a keyboard the guard
    REFUSES to draw on the narrow console and a half-width one on the wide
    console. Pass the same number to both.

    ⚠️ THE GUARDS ARE NOT A CO-TENANCY MECHANISM, and nothing here is. They
    stop the keyboard drawing off the edge of the console; they cannot stop
    anything else drawing over it. What keeps the keyboard and a full-screen
    TUI apart is the policy in this module's header -- they are never up at the
    same time -- and R-52 in docs/findings/P18-osk-hardware-pass.md is the
    measurement of what happens when they are.

    A row that exactly fills the console's width is safe, which is what makes
    a zero-slack fit usable rather than merely arithmetic: the VT defers its
    wrap until the NEXT character is written, and the next thing written here is
    always an absolute cursor move (`\\x1b[row;col H`) or the restore below,
    both of which clear the pending wrap. Nothing is ever written past the last
    column. That argument holds cell by cell as well as row by row, which is why
    the incremental path below may end a write inside the last column.

    Cursor position is saved and restored around the draw, so the TUI's own
    cursor does not end up parked in the keyboard.

    🔴 ONLY THE CELLS THAT CHANGED ARE PAINTED (P33 B2). `full=True` forces the
    whole region, and the section header above has the measurement, the reason
    and the three things that bound the risk. A draw that changes nothing writes
    NOTHING -- including no flush -- which is the common case while a thumb rests
    on a pad that keeps reporting at 250 Hz.

    ⚠️ A CONSOLE THAT HAS STARTED REFUSING WRITES IS THEN NOTICED LATER, not
    never: `deck-input-mapper.py` learns about a dead tty from the `OSError` out
    of this function, and a draw that writes nothing cannot raise one. The
    unconditional repaint every `FULL_REPAINT_EVERY` draws is the bound on that
    too -- the mapper's fallback is delayed by at most that many draws, and it
    degrades either way rather than dying.
    """
    if console_rows is not None:
        last = top_row + len(rows) - 1
        if top_row < 1 or last > console_rows:
            raise ValueError(
                f"the keyboard needs rows {top_row}-{last} but the console has "
                f"{console_rows}; drawing would collapse them onto the last line"
            )
    if console_cols is not None:
        drawn = width(rows)
        if drawn > console_cols:
            raise ValueError(
                f"the keyboard is {drawn} columns wide but the console has "
                f"{console_cols}; every row would wrap and push the rest of the "
                f"keyboard off the bottom"
            )
    # Everything that decides WHERE a cell goes, so a change in any of it is a
    # full repaint rather than a diff against a screen that no longer exists.
    #
    # ⚠️ THE CELL WIDTHS THEMSELVES, not just how many there are. The incremental
    # path walks columns by summing the widths of the cells to its left, so a
    # frame with the same number of cells at different widths -- a layer with a
    # differently shaped row, or the same row re-rendered at a new cell size --
    # would paint at the wrong columns. Cheaper to make that a full repaint than
    # to reason about when it cannot happen.
    key = (top_row, ansi, console_rows, console_cols,
           tuple(tuple(len(text) for text, _ in row) for row in rows))
    try:
        previous = _LAST_FRAME.get(stream)
    except TypeError:
        # See the store below: a stream that cannot be weak-referenced gets no
        # memory, so every draw is a full one.
        previous = None
    repaint_all = (full or previous is None or previous[0] != key
                   or previous[2] >= FULL_REPAINT_EVERY)

    parts: list[str] = []
    if repaint_all:
        for offset, row in enumerate(rows):
            line = "".join(_drawn(text, hot, ansi) for text, hot in row)
            # `\x1b[K` ONLY HERE. A full repaint does not know what is under it
            # -- something else may have left a longer line in these rows -- so
            # it clears to the end first. The incremental path below does know:
            # it is overwriting its own cells, character for character, with the
            # same width of text, so there is nothing to erase and erasing would
            # be the blank-then-paint flash this whole change is about.
            parts.append(f"\x1b[{top_row + offset};1H\x1b[K{line}")
        since = 0
    else:
        for offset, (row, was) in enumerate(zip(rows, previous[1])):
            column = 0
            for cell, before in zip(row, was):
                if cell != before:
                    parts.append(f"\x1b[{top_row + offset};{column + 1}H"
                                 f"{_drawn(cell[0], cell[1], ansi)}")
                column += len(cell[0])
        since = previous[2] + 1

    # Remember what is on the screen BEFORE the write, so a stream that raises
    # mid-write does not leave this module believing a frame landed that did
    # not. The next draw after a failure is then a diff against something
    # possibly wrong -- which the periodic full repaint repairs -- rather than a
    # diff against a frame that was never attempted at all.
    try:
        _LAST_FRAME[stream] = (key, [tuple(row) for row in rows], since)
    except TypeError:
        # A stream that cannot be weak-referenced (some test doubles, some
        # C extensions) simply gets no memory, so every draw is a full one --
        # the behaviour this function had before P33 B2. Degrading to more
        # painting is safe; degrading to less would not be.
        pass

    if not parts:
        # Nothing moved. The screen already says this, so saying it again is
        # exactly the cost §5.34 D4 is about.
        return
    # Cursor saved and restored around the draw, and the restore is also what
    # clears any wrap left pending by a cell that ended in the last column.
    stream.write("".join(["\x1b[s", *parts, "\x1b[u"]))
    stream.flush()


def clear_at(stream, rows: list[list[Segment]], top_row: int) -> None:
    """Erase the region the keyboard occupies, for hiding it."""
    # ⚠️ AND FORGET THE FRAME. Without this the next `write_at` would diff
    # against a keyboard this call just wiped off the screen, find nothing
    # changed, write nothing, and leave the console blank where the keyboard is
    # supposed to be -- for up to `FULL_REPAINT_EVERY` draws. `deck-input-mapper`
    # clears then immediately redraws on the narrow-console path, so that is not
    # a hypothetical ordering.
    forget(stream)
    parts = ["\x1b[s"]
    for offset in range(len(rows)):
        parts.append(f"\x1b[{top_row + offset};1H\x1b[K")
    parts.append("\x1b[u")
    stream.write("".join(parts))
    stream.flush()
