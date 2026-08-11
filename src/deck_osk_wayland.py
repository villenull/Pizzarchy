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

# Blank pixels between the halves. Wide on purpose: it is the only thing
# telling a user which cursor belongs to which thumb.
DEFAULT_GUTTER = 48


def half_bounds(width: float, gutter: float) -> dict[str, tuple[float, float]]:
    """(x origin, width) for each half."""
    half = (width - gutter) / 2.0
    return {"left": (0.0, half), "right": (half + gutter, half)}


def key_rects(layer: osk.Layer, width: float, height: float,
              gutter: float = DEFAULT_GUTTER) -> list[tuple]:
    """Every key's pixel rectangle: (half, row, col, x, y, w, h)."""
    bounds = half_bounds(width, gutter)
    out = []
    for half in ("left", "right"):
        x0, half_w = bounds[half]
        rows = layer.half(half)
        row_h = height / len(rows)
        for row_index, row in enumerate(rows):
            cells = sum(key.span for key in row)
            cell_w = half_w / cells
            seen = 0
            for key_index, key in enumerate(row):
                out.append((half, row_index, key_index,
                            x0 + seen * cell_w, row_index * row_h,
                            key.span * cell_w, row_h))
                seen += key.span
    return out


def cursor_pixel(half: str, position: tuple[float, float], width: float,
                 height: float, gutter: float = DEFAULT_GUTTER) -> tuple[float, float]:
    """A cursor's 0..1 position within its half, in pixels."""
    x0, half_w = half_bounds(width, gutter)[half]
    return (x0 + position[0] * half_w, position[1] * height)


# --- appearance ---------------------------------------------------------------
#
# Deliberately not themed. This has to be legible over an unknown wallpaper on
# a handheld held at arm's length, and a theme that follows the desktop can
# make it invisible. Drawn with Cairo's own font API rather than Pango: one
# fewer dependency, and no fontconfig behaviour to differ between the ISO and
# an installed system.
BACKDROP = (0.07, 0.07, 0.09, 0.94)
KEY_FACE = (0.17, 0.17, 0.21, 1.0)
KEY_EDGE = (0.30, 0.30, 0.36, 1.0)
KEY_TEXT = (0.92, 0.92, 0.95, 1.0)
HOT_TEXT = (0.05, 0.05, 0.07, 1.0)
# One accent per half, so which cursor is which is answerable at a glance.
ACCENT = {"left": (0.38, 0.78, 0.92, 1.0), "right": (0.98, 0.72, 0.30, 1.0)}
KEY_PAD = 3.0
CORNER = 6.0


def draw(cr, keyboard: osk.OnScreenKeyboard, cursors: osk.Cursors,
         width: float, height: float, gutter: float = DEFAULT_GUTTER) -> None:
    """Paint the keyboard. `cr` is a Cairo context; nothing else is needed."""
    cr.set_source_rgba(*BACKDROP)
    cr.rectangle(0, 0, width, height)
    cr.fill()

    highlights = {
        half: keyboard.locate(half, *cursors.position(half))
        for half in ("left", "right")
    }
    rows_by_half = {half: keyboard.layer.half(half) for half in ("left", "right")}

    cr.select_font_face("monospace")
    for half, row_index, key_index, x, y, w, h in key_rects(
            keyboard.layer, width, height, gutter):
        key = rows_by_half[half][row_index][key_index]
        hot = highlights[half] == (row_index, key_index)
        _rounded(cr, x + KEY_PAD, y + KEY_PAD, w - 2 * KEY_PAD, h - 2 * KEY_PAD, CORNER)
        cr.set_source_rgba(*(ACCENT[half] if hot else KEY_FACE))
        cr.fill_preserve()
        cr.set_source_rgba(*KEY_EDGE)
        cr.set_line_width(1.0)
        cr.stroke()

        label = keyboard.face(key)
        cr.set_font_size(_fit(cr, label, w - 2 * KEY_PAD, h - 2 * KEY_PAD))
        extents = cr.text_extents(label)
        cr.move_to(x + (w - extents.width) / 2 - extents.x_bearing,
                   y + (h - extents.height) / 2 - extents.y_bearing)
        cr.set_source_rgba(*(HOT_TEXT if hot else KEY_TEXT))
        cr.show_text(label)

    # The exact cursor point, on top of the snapped highlight. The highlight
    # answers "which key"; the dot answers "where within it", which is what
    # tells a user which way to move when they are between two keys.
    for half in ("left", "right"):
        cx, cy = cursor_pixel(half, cursors.position(half), width, height, gutter)
        cr.set_source_rgba(*ACCENT[half])
        cr.arc(cx, cy, 6.0, 0, 6.283185307179586)
        cr.fill()
        cr.set_source_rgba(0.05, 0.05, 0.07, 1.0)
        cr.arc(cx, cy, 6.0, 0, 6.283185307179586)
        cr.set_line_width(1.5)
        cr.stroke()


def _rounded(cr, x, y, w, h, r) -> None:
    from math import pi
    r = min(r, w / 2, h / 2)
    cr.new_sub_path()
    cr.arc(x + w - r, y + r, r, -pi / 2, 0)
    cr.arc(x + w - r, y + h - r, r, 0, pi / 2)
    cr.arc(x + r, y + h - r, r, pi / 2, pi)
    cr.arc(x + r, y + r, r, pi, 3 * pi / 2)
    cr.close_path()


def _fit(cr, label: str, w: float, h: float) -> float:
    """Largest font size at which `label` fits its key.

    Word labels ("space", "enter") are much longer than "q", and a single size
    either overflows them or wastes the letters. The TTY renderer hit the same
    thing and answered it with a wider cell; here the size can just shrink.
    """
    size = h * 0.5
    for _ in range(8):
        cr.set_font_size(size)
        if cr.text_extents(label).width <= w * 0.82:
            break
        size *= 0.85
    return size


# --- the overlay --------------------------------------------------------------


def main() -> int:
    import argparse

    ap = argparse.ArgumentParser(description="Desktop Mode's on-screen keyboard")
    ap.add_argument("--demo", action="store_true",
                    help="draw a fixed pose and stay up, instead of reading stdin")
    ap.add_argument("--height", type=int, default=0, metavar="PX",
                    help="overlay height in pixels (default: 42%% of the output)")
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
            height = int((geometry.height if geometry else 800) * 0.42)
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
