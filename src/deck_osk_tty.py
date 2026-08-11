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
    not guaranteed to carry box-drawing glyphs. Everything here is ASCII.

TWO CURSORS, WITHOUT A POINTER
    Each cursor highlights the key it is over rather than floating between
    them. For a keyboard that is not a compromise: the question a user is
    asking is "which key am I on", and snapping answers it exactly. It is also
    what makes two cursors possible at all -- there is no pointer to own.

    The highlight is **brackets as well as reverse video**. Reverse video alone
    is invisible to `tmux capture-pane` without `-e`, unreadable on some console
    fonts, and gone entirely in a plain log. `[ q ]` survives all three.

WHAT THIS MODULE DOES NOT DO
    It does not own the screen. `render()` returns lines; the caller decides
    where they go. The installer's TUI is drawing on the same console, so
    something has to keep them apart -- see `write_at()` and the note there.

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
# ⚠️ 7, not 5, and the two brackets are why. A highlighted cell spends two
# columns on `[` and `]`, so a width of 5 leaves three for the label and the
# longest single-span faces -- `enter`, `right` -- render as `[ent]` and
# `[rig]`. A user cannot read a truncated key, and the truncation only appears
# on the key the cursor is ON, which is the one moment it has to be legible.
#
# 7 leaves five columns highlighted, which is exactly the longest single-span
# label in either layer. `test-deck-osk-tty.py` asserts nothing is ever
# truncated, at every span, in both states -- so adding a longer label fails
# the suite rather than quietly cropping on screen.
#
# Two halves of 5 unit cells is 5*7*2 + GUTTER = 73 columns, inside an 80-column
# console with room to spare.
KEY_CELL = 7

# Blank columns between the two halves. This is the only thing telling a user
# which cursor belongs to which thumb, so it is not decoration.
GUTTER = 3

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


def render(kb: osk.OnScreenKeyboard, cursors: osk.Cursors) -> list[list[Segment]]:
    """The keyboard as rows of (text, highlighted) segments.

    Pure: no escape sequences, no file descriptors, no terminal size. Both the
    ANSI writer below and the tests consume this, so what CI asserts on is the
    same structure a user sees.
    """
    layer = kb.layer
    highlights = {
        half: kb.locate(half, *cursors.position(half)) for half in ("left", "right")
    }

    left_rows, right_rows = layer.left, layer.right
    if len(left_rows) != len(right_rows):
        # Both halves of one layer must have the same row count or they cannot
        # line up on screen. A layout that breaks this is a layout bug, and
        # silently rendering a ragged keyboard would hide it.
        raise ValueError(
            f"layer {layer.name!r} has {len(left_rows)} left rows and "
            f"{len(right_rows)} right rows; they must match"
        )

    out: list[list[Segment]] = []
    for row_index in range(len(left_rows)):
        segments: list[Segment] = []
        for half, rows in (("left", left_rows), ("right", right_rows)):
            if half == "right":
                segments.append((" " * GUTTER, False))
            for key_index, key in enumerate(rows[row_index]):
                segments.append((
                    cell_text(kb.face(key), key.span * KEY_CELL,
                              highlights[half] == (row_index, key_index)),
                    highlights[half] == (row_index, key_index),
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

    ⚠️ Geometry, not string surgery, and the symbols layer is why: `[` and `]`
    are KEYS there. A plain one draws as `   [   `, whose first column is a
    space, so it is read as the face `[` and not as an empty highlight. A
    highlighted one draws as `[  [  ]` and unwraps to the same face.
    """
    if len(cell) >= 2 and cell[0] == "[" and cell[-1] == "]":
        return cell[1:-1].strip()
    return cell.strip()


def rows_on_screen(screen: str, rows: list[list[Segment]]) -> list[int]:
    """Which 1-based lines of `screen` carry a WHOLE rendered keyboard row.

    ⚠️ COUNT THE ROWS. DO NOT GREP FOR A WORD. R-49's defect was five keyboard
    rows clamped onto one line by a console that had shrunk underneath them:
    garbled, unusable, and still carrying the word `shift` -- so `osk.shown=1`
    passed and a human glancing at a screenshot saw "a keyboard". R-52 then
    reproduced the same lie from the opposite direction: a full-screen TUI
    repainting every line but the last leaves exactly the function row alive,
    which is the row `shift` is on. Only the count separates those from a
    keyboard that is actually on screen.

    `screen` is the console as text, one line per console row. `/dev/vcsN`
    folded to the console's width is exactly that, and is the kernel's own copy
    of the screen rather than a reconstruction of it (R-47).

    A line counts only if EVERY cell of some rendered row is on it, at the
    column that row puts it. Partial credit is the thing being guarded against:
    half a keyboard row is not a keyboard row, and a user typing on it has no
    way to tell. Columns to the right of the keyboard are not inspected -- the
    keyboard is 73 columns wide and does not own the rest of the line.
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
             ansi: bool = True, console_rows: int | None = None) -> None:
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

    ⚠️ THE GUARD IS NOT A CO-TENANCY MECHANISM, and nothing here is. It stops
    the keyboard drawing off the end of the console; it cannot stop anything
    else drawing over it. What keeps the keyboard and a full-screen TUI apart
    is the policy in this module's header -- they are never up at the same
    time -- and R-52 in docs/findings/P18-osk-hardware-pass.md is the
    measurement of what happens when they are.

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
