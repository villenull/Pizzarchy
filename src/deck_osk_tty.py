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


def write_at(stream, rows: list[list[Segment]], top_row: int, *, ansi: bool = True) -> None:
    """Draw the keyboard with its first line at `top_row` (1-based).

    ⚠️ THE INSTALLER'S TUI IS DRAWING ON THIS SAME CONSOLE. Nothing here stops
    it painting over the keyboard; keeping them apart is the caller's job, and
    the intended mechanism is to shrink the TUI's reported window (TIOCSWINSZ)
    so it confines itself to the rows above `top_row`. A TUI that believes the
    terminal is 18 rows tall does not scroll a 25-row console, and the bottom
    seven rows stay ours.

    Cursor position is saved and restored around the draw, so the TUI's own
    cursor does not end up parked in the keyboard.
    """
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
