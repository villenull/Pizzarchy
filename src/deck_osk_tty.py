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

import deck_osk_layout as osk

# Characters per unit-span key.
#
# 🔴 5, AND THE GRID DECIDES IT -- NOT LEGIBILITY. Since T8 §9g the layout is
# ONE grid of `Layer.width` == 16 cells, and `docs/PROGRESS.md` §7 measured the
# two consoles this has to survive: the live ISO's is 50x160 and **the installed
# TTY's is 25x80, on the same panel**. 16 * 5 == 80 EXACTLY, with nothing spare.
# 6 would be 96 and 7 -- what this was before §9g, sized for the old two-half
# layout's 73 columns -- would be 112. Either wraps on the installed TTY, and a
# wrapped row pushes the rows below it down and off the end of the screen: R-49's
# defect arriving on the other axis.
#
# ⚠️ ZERO SLACK IS THE POINT AND ALSO THE HAZARD. Nothing may widen a cell, and
# `write_at`'s `console_cols` guard exists because 80 is a measurement of one
# console rather than a property of all of them -- READ THE GEOMETRY AT RUNTIME
# (`docs/PROGRESS.md` §7, and `_console_rows` in `deck-input-mapper.py` already
# does it for height).
#
# ⚠️ AND THE LABELS STILL FIT, which is why 5 is affordable now and was not
# before. A highlighted unit cell spends two columns on `[` and `]`, leaving
# THREE -- and §9g's legend rule made the widest single-cell label three
# characters ("1 !", "` ~", "< ^"), where the old layout's `enter` and `right`
# needed five. The wide labels all landed on wide keys: `Enter` is span 2 (budget
# 8, and "R2 Enter" is exactly 8), `Backspace`/`Shift`/`Caps`/`Move`/`Tab` are
# span 3 (budget 13). `test-deck-osk-tty.py` asserts NOTHING is ever truncated,
# at every span, in every shift/caps state -- so a longer label fails the suite
# rather than quietly cropping on the one keyboard the installer has.
KEY_CELL = 5

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


def display_label(kb: osk.OnScreenKeyboard, key: osk.Key) -> str:
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
    drawn at (`key.span * KEY_CELL - 2`, the highlighted one -- brackets always
    cost exactly 2 columns), and applying that decision unconditionally.
    """
    face = osk.ascii_face(kb.face(key))
    secondary = osk.ascii_face(kb.secondary_face(key))
    state = MODIFIER_TEXT.get(kb.modifier_state(key), "")

    if secondary:
        candidates = (f"{face} {secondary}", face)
    else:
        stem = f"{face} {state}" if state else face
        candidates = ((f"{key.hint} {stem}", stem, face) if key.hint
                      else (stem, face))

    budget = key.span * KEY_CELL - 2  # the highlighted width -- the tighter one
    for text in candidates:
        if len(text) <= budget:
            return text
    # Nothing fits, not even the bare face. Returning it anyway lets `cell_text`
    # truncate, which the suite's no-truncation invariant turns red on --
    # inventing a shorter label here would hide that instead.
    return candidates[-1]


def render(kb: osk.OnScreenKeyboard, cursors: osk.Cursors) -> list[list[Segment]]:
    """The keyboard as rows of (text, highlighted) segments.

    Pure: no escape sequences, no file descriptors, no terminal size. Both the
    ANSI writer below and the tests consume this, so what CI asserts on is the
    same structure a user sees.

    One continuous grid (T8 §9g): every row spans all `Layer.width` cells and
    each key's columns come from `Layer.cell_bounds`, so the drawn width cannot
    drift from the grid the hit test uses. `Layer.__post_init__` already refuses
    a layer whose rows disagree on width, which is why nothing here re-checks
    it -- the ragged-layer guard this function used to carry belonged to the old
    two-half model and is gone with it.
    """
    layer = kb.layer
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
                cell_text(display_label(kb, key), (end - start) * KEY_CELL, hot),
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
    keyboard is `Layer.width * KEY_CELL` columns wide (80 today) and does not
    own anything past that, which on the installed TTY is nothing at all.
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


def write_at(stream, rows: list[list[Segment]], top_row: int, *,
             ansi: bool = True, console_rows: int | None = None,
             console_cols: int | None = None) -> None:
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

    ⚠️ THE GUARDS ARE NOT A CO-TENANCY MECHANISM, and nothing here is. They
    stop the keyboard drawing off the edge of the console; they cannot stop
    anything else drawing over it. What keeps the keyboard and a full-screen
    TUI apart is the policy in this module's header -- they are never up at the
    same time -- and R-52 in docs/findings/P18-osk-hardware-pass.md is the
    measurement of what happens when they are.

    A row that exactly fills the console's width is safe, which is what makes
    80-in-80 usable rather than merely arithmetic: the VT defers its wrap until
    the NEXT character is written, and the next thing written here is always an
    absolute cursor move (`\\x1b[row;1H`) or the restore below, both of which
    clear the pending wrap. Nothing is ever written past the last column.

    Cursor position is saved and restored around the draw, so the TUI's own
    cursor does not end up parked in the keyboard.
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
    body = (to_ansi if ansi else to_plain)(rows)
    parts = ["\x1b[s"]  # save cursor
    for offset, line in enumerate(body.split("\n")):
        parts.append(f"\x1b[{top_row + offset};1H\x1b[K{line}")
    parts.append("\x1b[u")  # restore cursor
    stream.write("".join(parts))
    stream.flush()


def clear_at(stream, rows: list[list[Segment]], top_row: int) -> None:
    """Erase the region the keyboard occupies, for hiding it."""
    parts = ["\x1b[s"]
    for offset in range(len(rows)):
        parts.append(f"\x1b[{top_row + offset};1H\x1b[K")
    parts.append("\x1b[u")
    stream.write("".join(parts))
    stream.flush()
