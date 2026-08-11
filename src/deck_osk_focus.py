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

    ✅ **R-51 measured what it costs, and it is small.** Launching fcitx5 with
    one more addon disabled -- `--disable waylandim` -- frees the seat while
    leaving XIM (X11/XWayland), the IBus name, and `/virtualkeyboard` exactly as
    they were. The cost is precisely that fcitx5 stops serving **Wayland-native**
    clients. So this is a documented SETTING, never a silent default: the mapper
    runs this only under `--osk-auto-show`, and nothing spawns it otherwise.

THE LINE PROTOCOL, which is the other half of this file
    stdout carries one line per change, `focus 0` / `focus 1`, and the mapper
    parses it. Both ends of that pipe are defined HERE -- `format_focus_line`
    and `parse_focus_line` -- for the same reason `deck_osk_layout` owns
    `format_state_line`: a protocol written down twice is a protocol that
    drifts, and this one crosses a process boundary where drift is silent.

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

# The object ids we allocate. Wayland lets the client pick them; 1 is always
# wl_display, and clients own everything from 2 up.
#
# ⚠️ THEY MUST BE ALLOCATED DENSELY, IN THE ORDER THEY ARE SENT, AND A REAL
# COMPOSITOR IS THE ONLY THING THAT SAYS SO.
#
# libwayland's server keeps client objects in an array and refuses any id past
# one-past-the-end, so the next object must take the next free number. Measured
# against a live Hyprland 0.56 on 2026-08-11, with ids 1 and 2 in use:
#
#     sync -> id 3   OK
#     sync -> id 4   wl_display error 1: invalid arguments for wl_display#1.sync
#     sync -> id 10  the same error
#
# "invalid arguments" names the wrong thing -- the arguments are a well-formed
# u32 -- which is why this cost a round of guessing. Adding a round trip and
# giving its callback the next SPARE number (6, after the three ids bound
# later) broke the whole handshake this way, and the test's fake compositor
# accepted it happily. The suite now asserts the ids are dense; keep the
# ALLOCATION ORDER below matching the order the requests are sent.
DISPLAY_ID = 1
REGISTRY_ID = 2       # wl_display.get_registry, first
CALLBACK_ID = 3       # wl_display.sync, second
SEAT_ID = 4           # wl_registry.bind, third
MANAGER_ID = 5        # wl_registry.bind, fourth
INPUT_METHOD_ID = 6   # manager.get_input_method, last

# Opcodes, from the protocol definitions. Named rather than inlined because a
# bare `2` in a send call is unreviewable.
WL_DISPLAY_SYNC = 0
WL_DISPLAY_GET_REGISTRY = 1
WL_REGISTRY_BIND = 0
WL_DISPLAY_ERROR = 0
WL_REGISTRY_GLOBAL = 0
WL_CALLBACK_DONE = 0
IM_MANAGER_GET_INPUT_METHOD = 0
IM_ACTIVATE = 0
IM_DEACTIVATE = 1
IM_DONE = 5
IM_UNAVAILABLE = 6

SEAT_INTERFACE = "wl_seat"
MANAGER_INTERFACE = "zwp_input_method_manager_v2"

# How long the setup handshake may take before we give up on this compositor.
#
# ⚠️ THE HANDSHAKE IS THE ONLY PHASE THAT MAY TIME OUT. Silence afterwards is
# the normal state -- nobody is touching a text field for minutes at a time --
# so a timeout on the watch loop would report a healthy compositor as broken.
HANDSHAKE_TIMEOUT = 5.0

# Exit codes. The mapper turns these back into a sentence for the journal, so
# they are a shared vocabulary, not private detail.
EXIT_OK = 0
EXIT_NO_CONNECTION = 2
EXIT_NO_PROTOCOL = 3
EXIT_LOST = 4
EXIT_SEAT_TAKEN = 5

EXIT_REASONS = {
    EXIT_NO_CONNECTION:
        "there is no Wayland connection (the installer has none, and that is "
        "expected there)",
    EXIT_NO_PROTOCOL:
        f"this compositor does not offer {MANAGER_INTERFACE}",
    EXIT_LOST:
        "the Wayland connection was lost",
    EXIT_SEAT_TAKEN:
        "another input method owns the seat -- fcitx5, or squeekboard while it "
        "runs; free it with fcitx5's `--disable waylandim` (R-51)",
}


class WatcherError(RuntimeError):
    """A refusal that already knows which exit code it means."""

    def __init__(self, code: int, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


# --- the line protocol (the mapper's end of the pipe speaks this too) --------


def format_focus_line(focused: bool) -> str:
    """One state change, as it goes out on stdout. Includes the newline."""
    return f"focus {1 if focused else 0}\n"


def parse_focus_line(line: str) -> bool | None:
    """A focus line -> True/False. Anything else -> None.

    ⚠️ Returns None rather than raising. This parses bytes from ANOTHER
    PROCESS on the far side of a pipe, and with lizard_mode=N the reader is the
    only input path on the device: a parser that raised on a stray line would
    take the pointer and every key down with it. Same contract as
    `deck_osk_layout.parse_state_line`.
    """
    parts = line.split()
    if len(parts) != 2 or parts[0] != "focus":
        return None
    if parts[1] == "1":
        return True
    if parts[1] == "0":
        return False
    return None


def split_lines(buffer: bytes) -> tuple[list[str], bytes]:
    """Split a read buffer into whole lines, keeping any partial tail.

    ⚠️ A pipe read is not a line boundary, exactly as a socket read is not a
    message boundary (`parse_messages` below). Two lines arrive in one read
    whenever focus moves twice quickly, and a line can be split in half.
    """
    out = []
    while True:
        index = buffer.find(b"\n")
        if index < 0:
            break
        out.append(buffer[:index].decode(errors="replace"))
        buffer = buffer[index + 1:]
    return out, buffer


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
        self.synced = False
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

    def handshake(self, timeout: float = HANDSHAKE_TIMEOUT) -> None:
        """Learn the globals, then bind the input method. Raises WatcherError.

        ⚠️ THE ROUND TRIP IS `wl_display.sync`, NOT A READ COUNT. The registry
        streams every global and then stops; `sync` is the only thing that says
        "that was all of them". An earlier version read a fixed number of times
        instead, which on a compositor with no input-method protocol -- the one
        case it was written to report -- blocked forever on a read that would
        never come, and reported nothing at all.
        """
        assert self.sock is not None
        self.send(DISPLAY_ID, WL_DISPLAY_SYNC, struct.pack("I", CALLBACK_ID))
        self.sock.settimeout(timeout)
        try:
            while not self.synced:
                self.pump()
                if self.error:
                    raise WatcherError(EXIT_NO_CONNECTION, self.error)
        except socket.timeout as exc:
            raise WatcherError(
                EXIT_NO_CONNECTION,
                f"the compositor did not answer within {timeout}s ({exc})") from exc
        except (ConnectionError, OSError) as exc:
            raise WatcherError(EXIT_NO_CONNECTION,
                               f"the connection failed during setup ({exc})") from exc
        finally:
            # Back to blocking. Silence is normal once we are watching.
            self.sock.settimeout(None)

        for interface in (SEAT_INTERFACE, MANAGER_INTERFACE):
            if interface not in self.globals:
                raise WatcherError(EXIT_NO_PROTOCOL,
                                   f"this compositor does not offer {interface}")

        self.bind(SEAT_INTERFACE, SEAT_ID, version=1)
        self.bind(MANAGER_INTERFACE, MANAGER_ID)
        self.send(MANAGER_ID, IM_MANAGER_GET_INPUT_METHOD,
                  struct.pack("II", SEAT_ID, INPUT_METHOD_ID))

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
        if object_id == CALLBACK_ID and opcode == WL_CALLBACK_DONE:
            # `sync` has come back: every global has now been advertised.
            self.synced = True
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


def refuse(code: int, detail: str) -> int:
    """Say why auto-show is off, in one sentence, and hand back the code.

    ⚠️ Every exit from here is LOUD and names what still works. This process
    dying is not an emergency -- the STEAM+X chord does not go through it -- but
    a keyboard that silently stopped appearing on focus would be diagnosed as
    the whole OSK being broken.
    """
    print(f"deck-osk-focus: {detail}; auto-show is DISABLED, the STEAM+X chord "
          "still works", file=sys.stderr, flush=True)
    return code


def main(argv: list[str] | None = None) -> int:
    import argparse

    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--once", action="store_true",
                    help="print the first focus change and exit")
    ap.add_argument("--handshake-timeout", type=float, default=HANDSHAKE_TIMEOUT,
                    metavar="SECONDS",
                    help="how long the compositor may take to answer setup "
                         f"(default {HANDSHAKE_TIMEOUT})")
    args = ap.parse_args(argv)

    watcher = FocusWatcher()
    try:
        watcher.connect()
        watcher.handshake(args.handshake_timeout)
    except WatcherError as exc:
        return refuse(exc.code, exc.message)
    except (OSError, RuntimeError) as exc:
        return refuse(EXIT_NO_CONNECTION, f"no Wayland connection ({exc})")

    # ⚠️ `False`, not `None`. Starting from None makes the FIRST message of any
    # kind print a line -- and the first message is routinely `delete_id` for
    # the sync callback, nothing to do with focus. That spurious `focus 0` is
    # harmless to the mapper (it already believes nothing is focused) but it
    # made a real measurement ambiguous on 2026-08-11: a run against live
    # Hyprland printed `focus 0` and exited, which looks like "we hold the seat
    # and nothing is focused" and was in fact "some message arrived".
    # Nothing focused is what we already assume; only a change is news.
    last = False
    while True:
        try:
            watcher.pump()
        except (ConnectionError, OSError) as exc:
            return refuse(EXIT_LOST, f"connection lost ({exc})")
        if watcher.unavailable:
            # ⚠️ Deliberate, not a workaround: one input method per seat, and
            # squeekboard holds it whenever it runs. Taking it away is a
            # decision, not something to do silently.
            # ⚠️ Do not guess WHICH one. Measured 2026-08-10: on the dev
            # machine this fires with squeekboard not running at all -- Omarchy
            # ships and runs fcitx5 (§5.20), and that holds the seat too. An
            # error naming the wrong culprit sends the next reader after the
            # wrong process.
            return refuse(EXIT_SEAT_TAKEN,
                          "another input method already owns this seat. "
                          "Candidates: squeekboard, fcitx5 -- check with "
                          "`pgrep -a squeekboard fcitx5`, and free it with "
                          "fcitx5's `--disable waylandim` (R-51)")
        if watcher.error:
            return refuse(EXIT_NO_CONNECTION, watcher.error)
        if watcher.focused != last:
            last = watcher.focused
            # ⚠️ flush: the reader is a live process selecting on this pipe, not
            # something that reads our output after we exit. Without it Python
            # block-buffers a pipe and the keyboard appears when the buffer
            # fills -- which is to say, never.
            sys.stdout.write(format_focus_line(watcher.focused))
            sys.stdout.flush()
            if args.once:
                return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
