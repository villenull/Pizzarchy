#!/usr/bin/env python3
"""deck_osk_focus -- "a text field was focused", straight off the Wayland socket.

T8 step 8 (the auto-show regression from step 7). Prints one line per change:

    focus 1     a text field took focus   -> show the keyboard
    focus 0     it lost focus             -> hide it

    deck_osk_focus.py            # watch, print, keep going
    deck_osk_focus.py --once     # print the first event and exit (for probes)

WHY THE PROTOCOL IS HAND-ROLLED
    This needs `zwp_input_method_v2`, which is how squeekboard learns that a
    text field has focus. Reaching it from Python otherwise means
    `python-pywayland` PLUS `wlr-protocols` for the XML -- two packages on the
    Deck and in T5's payload, one of them a build-time XML package that would
    be strange to ship at runtime, for one feature.

    The slice of protocol actually needed is small: connect, get a registry,
    bind two globals, ask for an input method, then read two event opcodes.
    That is cheaper than the dependency, and it keeps working in the live ISO,
    which carries no Python packages beyond the standard library and evdev.

⚠️ ONLY ONE INPUT METHOD MAY BIND A SEAT, and something already holds it.
    Measured 2026-08-10 against a real Hyprland session: this reaches the
    input-method object and is answered with `unavailable`. **squeekboard was
    not even running** -- Omarchy ships and runs `fcitx5` (§5.20) and that holds
    the seat too, so there are TWO occupants to displace, not one.

    This reports it and exits non-zero rather than fighting for the seat.
    Deciding who gives it up is a product decision with real consequences --
    fcitx5 is Omarchy's input method for every other language -- and it is not
    something this should do behind anyone's back.

THE WIRE FORMAT, since there is no library here to hide it
    Every message: object id (u32), then (size << 16 | opcode) (u32), then
    arguments. `size` counts the header. Integers are host-endian -- Wayland is
    a local-socket protocol and does not byte-swap. Strings are a u32 length
    INCLUDING the trailing NUL, the bytes, the NUL, then padding to the next
    4-byte boundary. That padding is the classic place to get this wrong, so it
    has its own tests.
"""

from __future__ import annotations

import os
import socket
import struct
import sys

# The three object ids we allocate. Wayland lets the client pick them; 1 is
# always wl_display, and clients own everything from 2 up.
DISPLAY_ID = 1
REGISTRY_ID = 2
SEAT_ID = 3
MANAGER_ID = 4
INPUT_METHOD_ID = 5

# Opcodes, from the protocol definitions. Named rather than inlined because a
# bare `2` in a send call is unreviewable.
WL_DISPLAY_GET_REGISTRY = 1
WL_REGISTRY_BIND = 0
WL_DISPLAY_ERROR = 0
WL_REGISTRY_GLOBAL = 0
IM_MANAGER_GET_INPUT_METHOD = 0
IM_ACTIVATE = 0
IM_DEACTIVATE = 1
IM_DONE = 5
IM_UNAVAILABLE = 6

SEAT_INTERFACE = "wl_seat"
MANAGER_INTERFACE = "zwp_input_method_manager_v2"


# --- the wire format (pure: no socket, no compositor) ------------------------


def pack_string(value: str) -> bytes:
    """A Wayland string: length INCLUDING the NUL, bytes, NUL, then padding."""
    raw = value.encode() + b"\0"
    padding = (-len(raw)) % 4
    return struct.pack("I", len(raw)) + raw + b"\0" * padding


def unpack_string(body: bytes, offset: int) -> tuple[str, int]:
    """Read a string at `offset`. Returns the value and the next offset."""
    (length,) = struct.unpack_from("I", body, offset)
    offset += 4
    value = body[offset:offset + length - 1].decode(errors="replace")
    offset += length + ((-length) % 4)
    return value, offset


def pack_message(object_id: int, opcode: int, body: bytes = b"") -> bytes:
    """One message. `size` in the header counts the header itself."""
    size = 8 + len(body)
    return struct.pack("II", object_id, (size << 16) | opcode) + body


def parse_messages(buffer: bytes) -> tuple[list[tuple[int, int, bytes]], bytes]:
    """Split a read buffer into whole messages, keeping any partial tail.

    ⚠️ A socket read is not a message boundary. Wayland packs several messages
    into one read and will happily split the last one, so anything that assumes
    "one read, one message" works until the compositor is busy.
    """
    out = []
    while len(buffer) >= 8:
        object_id, second = struct.unpack_from("II", buffer, 0)
        size = second >> 16
        opcode = second & 0xFFFF
        if size < 8 or len(buffer) < size:
            break
        out.append((object_id, opcode, buffer[8:size]))
        buffer = buffer[size:]
    return out, buffer


# --- the client --------------------------------------------------------------


class FocusWatcher:
    """Binds zwp_input_method_v2 and reports activate/deactivate."""

    def __init__(self) -> None:
        self.sock: socket.socket | None = None
        self.buffer = b""
        self.globals: dict[str, tuple[int, int]] = {}   # interface -> (name, version)
        self.focused = False
        self.unavailable = False
        self.error: str | None = None
        # activate/deactivate are only meaningful once `done` arrives: the
        # protocol batches a state change and commits it with `done`.
        self._pending: bool | None = None

    # -- connection ------------------------------------------------------------

    def socket_path(self) -> str:
        display = os.environ.get("WAYLAND_DISPLAY", "wayland-0")
        if display.startswith("/"):
            return display
        runtime = os.environ.get("XDG_RUNTIME_DIR")
        if not runtime:
            raise RuntimeError("XDG_RUNTIME_DIR is unset; there is no Wayland socket to find")
        return os.path.join(runtime, display)

    def connect(self) -> None:
        path = self.socket_path()
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(path)
        self.send(DISPLAY_ID, WL_DISPLAY_GET_REGISTRY, struct.pack("I", REGISTRY_ID))

    def send(self, object_id: int, opcode: int, body: bytes = b"") -> None:
        assert self.sock is not None
        self.sock.sendall(pack_message(object_id, opcode, body))

    def bind(self, interface: str, new_id: int, version: int | None = None) -> None:
        """wl_registry.bind. The version is capped at what the server offers."""
        name, offered = self.globals[interface]
        use = offered if version is None else min(version, offered)
        body = (struct.pack("I", name) + pack_string(interface)
                + struct.pack("II", use, new_id))
        self.send(REGISTRY_ID, WL_REGISTRY_BIND, body)

    # -- events ----------------------------------------------------------------

    def dispatch(self, object_id: int, opcode: int, body: bytes) -> None:
        if object_id == DISPLAY_ID and opcode == WL_DISPLAY_ERROR:
            _, offset = struct.unpack_from("I", body, 0)[0], 4
            code = struct.unpack_from("I", body, offset)[0]
            message, _ = unpack_string(body, offset + 4)
            self.error = f"wl_display error {code}: {message}"
            return
        if object_id == REGISTRY_ID and opcode == WL_REGISTRY_GLOBAL:
            name = struct.unpack_from("I", body, 0)[0]
            interface, offset = unpack_string(body, 4)
            version = struct.unpack_from("I", body, offset)[0]
            self.globals[interface] = (name, version)
            return
        if object_id == INPUT_METHOD_ID:
            if opcode == IM_ACTIVATE:
                self._pending = True
            elif opcode == IM_DEACTIVATE:
                self._pending = False
            elif opcode == IM_UNAVAILABLE:
                # Another input method already owns the seat: fcitx5 always,
                # squeekboard whenever it runs. Measured, not assumed.
                self.unavailable = True
            elif opcode == IM_DONE and self._pending is not None:
                self.focused = self._pending
                self._pending = None
                return
        return

    def pump(self) -> list[tuple[int, int, bytes]]:
        """Read whatever is available and dispatch it. Returns the messages."""
        assert self.sock is not None
        chunk = self.sock.recv(65536)
        if not chunk:
            raise ConnectionError("the compositor closed the connection")
        self.buffer += chunk
        messages, self.buffer = parse_messages(self.buffer)
        for message in messages:
            self.dispatch(*message)
        return messages


def main() -> int:
    import argparse

    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--once", action="store_true",
                    help="print the first focus change and exit")
    args = ap.parse_args()

    watcher = FocusWatcher()
    try:
        watcher.connect()
    except (OSError, RuntimeError) as exc:
        print(f"deck-osk-focus: no Wayland connection ({exc}); auto-show is "
              "DISABLED, the STEAM+X chord still works",
              file=sys.stderr, flush=True)
        return 2

    # Round trip: read until the registry has advertised what we need. The
    # server sends every global immediately after get_registry.
    deadline_reads = 50
    while (MANAGER_INTERFACE not in watcher.globals
           or SEAT_INTERFACE not in watcher.globals) and deadline_reads:
        watcher.pump()
        deadline_reads -= 1
        if watcher.error:
            print(f"deck-osk-focus: {watcher.error}", file=sys.stderr, flush=True)
            return 2

    if MANAGER_INTERFACE not in watcher.globals:
        print(f"deck-osk-focus: this compositor does not offer "
              f"{MANAGER_INTERFACE}; auto-show is DISABLED, the STEAM+X chord "
              "still works", file=sys.stderr, flush=True)
        return 3

    watcher.bind(SEAT_INTERFACE, SEAT_ID, version=1)
    watcher.bind(MANAGER_INTERFACE, MANAGER_ID)
    watcher.send(MANAGER_ID, IM_MANAGER_GET_INPUT_METHOD,
                 struct.pack("II", SEAT_ID, INPUT_METHOD_ID))

    last = None
    while True:
        try:
            watcher.pump()
        except (ConnectionError, OSError) as exc:
            print(f"deck-osk-focus: connection lost ({exc})", file=sys.stderr, flush=True)
            return 4
        if watcher.unavailable:
            # ⚠️ Deliberate, not a workaround: one input method per seat, and
            # squeekboard holds it whenever it runs. Taking it away is a
            # decision, not something to do silently.
            # ⚠️ Do not guess WHICH one. Measured 2026-08-10: on the dev
            # machine this fires with squeekboard not running at all -- Omarchy
            # ships and runs fcitx5 (§5.20), and that holds the seat too. An
            # error naming the wrong culprit sends the next reader after the
            # wrong process.
            print("deck-osk-focus: another input method already owns this seat; "
                  "auto-show is DISABLED, the STEAM+X chord still works. "
                  "Candidates: squeekboard, fcitx5 -- check with "
                  "`pgrep -a squeekboard fcitx5`",
                  file=sys.stderr, flush=True)
            return 5
        if watcher.error:
            print(f"deck-osk-focus: {watcher.error}", file=sys.stderr, flush=True)
            return 2
        if watcher.focused != last:
            last = watcher.focused
            print(f"focus {1 if watcher.focused else 0}", flush=True)
            if args.once:
                return 0


if __name__ == "__main__":
    sys.exit(main())
