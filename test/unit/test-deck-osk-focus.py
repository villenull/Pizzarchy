#!/usr/bin/env python3
"""Unit tests for the hand-rolled Wayland focus watcher (T8 step 8).

No compositor, no socket: the wire format and the event state machine are pure,
and they are where the bugs live. Run directly:

    python3 test-deck-osk-focus.py
"""

from __future__ import annotations

import importlib.util
import os
import pathlib
import select
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

sys.dont_write_bytecode = True

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "deck_osk_focus", REPO_ROOT / "src" / "deck_osk_focus.py")
fw = importlib.util.module_from_spec(spec)
sys.modules["deck_osk_focus"] = fw
spec.loader.exec_module(fw)

FAILURES = 0


def check(what: str, got, want) -> None:
    global FAILURES
    if got == want:
        print(f"ok   {what} = {got!r}")
    else:
        print(f"FAIL {what}: got {got!r}, want {want!r}")
        FAILURES += 1


# --- strings: the padding is the classic place to get this wrong -------------

check("a string carries its length INCLUDING the NUL",
      struct.unpack_from("I", fw.pack_string("wl_seat"))[0], 8)
check("and is padded to a 4-byte boundary", len(fw.pack_string("wl_seat")) % 4, 0)
# 7 chars + NUL = 8, already aligned: no padding. 4 length + 8 = 12.
check("an already-aligned string gets NO padding", len(fw.pack_string("wl_seat")), 12)
# 3 chars + NUL = 4, aligned. 11 chars + NUL = 12, aligned. 8 chars + NUL = 9 -> 12.
check("a string needing padding is rounded up", len(fw.pack_string("12345678")), 16)
check("the empty string is still length 1 (the NUL)",
      struct.unpack_from("I", fw.pack_string(""))[0], 1)

for text in ("", "a", "wl_seat", "zwp_input_method_manager_v2", "12345678"):
    encoded = fw.pack_string(text)
    value, offset = fw.unpack_string(encoded, 0)
    check(f"round trip {text!r}", (value, offset), (text, len(encoded)))

# --- message framing ----------------------------------------------------------

msg = fw.pack_message(1, 1, struct.pack("I", 2))
check("a message is header plus body", len(msg), 12)
object_id, second = struct.unpack_from("II", msg, 0)
check("the object id leads", object_id, 1)
check("the size counts the header", second >> 16, 12)
check("the opcode is in the low half", second & 0xFFFF, 1)

# ⚠️ A socket read is NOT a message boundary. Several messages arrive in one
# read and the last one is routinely cut in half; anything assuming otherwise
# works until the compositor is busy.
stream = fw.pack_message(2, 0, b"abcd") + fw.pack_message(1, 1, b"efgh")
messages, rest = fw.parse_messages(stream)
check("two messages in one read are both parsed", len(messages), 2)
check("and nothing is left over", rest, b"")

messages, rest = fw.parse_messages(stream[:-3])
check("a truncated tail yields only the whole messages", len(messages), 1)
check("and the partial one is kept for the next read", len(rest), len(stream) - 12 - 3)
messages2, rest2 = fw.parse_messages(rest + stream[-3:])
check("which completes once the rest arrives", len(messages2), 1)
check("with nothing left", rest2, b"")

check("a header alone is not a message", fw.parse_messages(b"\x01\x02\x03")[0], [])
check("a nonsense size is refused rather than looping",
      fw.parse_messages(struct.pack("II", 1, (2 << 16) | 0))[0], [])

# --- the registry -------------------------------------------------------------

w = fw.FocusWatcher()
body = struct.pack("I", 7) + fw.pack_string("wl_seat") + struct.pack("I", 5)
w.dispatch(fw.REGISTRY_ID, fw.WL_REGISTRY_GLOBAL, body)
check("a global is recorded with its name and version", w.globals["wl_seat"], (7, 5))

body = struct.pack("I", 9) + fw.pack_string(fw.MANAGER_INTERFACE) + struct.pack("I", 1)
w.dispatch(fw.REGISTRY_ID, fw.WL_REGISTRY_GLOBAL, body)
check("so is the input-method manager", w.globals[fw.MANAGER_INTERFACE], (9, 1))

# --- ⚠️ activate/deactivate mean nothing until `done` -------------------------
#
# The protocol batches a state change and COMMITS it with `done`. Acting on
# activate alone shows the keyboard for a change the compositor may still
# revise, which is a keyboard that flickers on every focus transition.

w = fw.FocusWatcher()
check("nothing is focused to begin with", w.focused, False)
w.dispatch(fw.INPUT_METHOD_ID, fw.IM_ACTIVATE, b"")
check("activate alone does NOT change the state", w.focused, False)
w.dispatch(fw.INPUT_METHOD_ID, fw.IM_DONE, b"")
check("done commits it", w.focused, True)

w.dispatch(fw.INPUT_METHOD_ID, fw.IM_DEACTIVATE, b"")
check("deactivate alone does not either", w.focused, True)
w.dispatch(fw.INPUT_METHOD_ID, fw.IM_DONE, b"")
check("and done commits that too", w.focused, False)

# A `done` with nothing pending is a no-op, not a toggle: the compositor sends
# `done` after other batched changes (surrounding text, content type) as well.
w.dispatch(fw.INPUT_METHOD_ID, fw.IM_DONE, b"")
check("a bare done does not toggle anything", w.focused, False)
w.dispatch(fw.INPUT_METHOD_ID, fw.IM_ACTIVATE, b"")
w.dispatch(fw.INPUT_METHOD_ID, fw.IM_DONE, b"")
w.dispatch(fw.INPUT_METHOD_ID, fw.IM_DONE, b"")
check("nor does a second one after a real change", w.focused, True)

# --- the seat is single-occupancy ---------------------------------------------

w = fw.FocusWatcher()
check("the seat starts available", w.unavailable, False)
w.dispatch(fw.INPUT_METHOD_ID, fw.IM_UNAVAILABLE, b"")
check("unavailable is recorded -- another input method owns the seat",
      w.unavailable, True)

# --- protocol errors are surfaced, not swallowed ------------------------------

w = fw.FocusWatcher()
err = struct.pack("II", 1, 42) + fw.pack_string("bad thing")
w.dispatch(fw.DISPLAY_ID, fw.WL_DISPLAY_ERROR, err)
check("a wl_display error is captured with its code and message",
      w.error, "wl_display error 42: bad thing")

# --- the socket path ----------------------------------------------------------

import os  # noqa: E402
saved = dict(os.environ)
try:
    os.environ["XDG_RUNTIME_DIR"] = "/run/user/1000"
    os.environ["WAYLAND_DISPLAY"] = "wayland-1"
    check("a relative display name joins the runtime dir",
          fw.FocusWatcher().socket_path(), "/run/user/1000/wayland-1")
    os.environ["WAYLAND_DISPLAY"] = "/tmp/custom.sock"
    check("an absolute one is used as-is",
          fw.FocusWatcher().socket_path(), "/tmp/custom.sock")
    os.environ.pop("XDG_RUNTIME_DIR")
    os.environ["WAYLAND_DISPLAY"] = "wayland-1"
    try:
        fw.FocusWatcher().socket_path()
        check("a missing XDG_RUNTIME_DIR is refused", False, True)
    except RuntimeError:
        check("a missing XDG_RUNTIME_DIR is refused loudly", True, True)
finally:
    os.environ.clear()
    os.environ.update(saved)

# --- the line protocol: the other end of this pipe is the mapper -------------
#
# Written down once, here, and imported by the mapper. A format defined twice
# drifts, and this one drifts silently -- the keyboard just stops appearing.

check("a focused field is one line", fw.format_focus_line(True), "focus 1\n")
check("an unfocused one is the other", fw.format_focus_line(False), "focus 0\n")
for state in (True, False):
    line = fw.format_focus_line(state)
    check(f"round trip {state}", fw.parse_focus_line(line.strip()), state)

check("a line with the newline still on it parses",
      fw.parse_focus_line("focus 1\n"), True)
# ⚠️ None, never an exception. This parses bytes from another process while
# holding the only input path on the device.
for junk in ("", "focus", "focus 2", "focus -1", "focus true", "focus 1 1",
             "unfocus 1", "deck-osk-focus: another input method owns the seat",
             "  ", "1", "FOCUS 1"):
    check(f"junk {junk!r} is not a focus line", fw.parse_focus_line(junk), None)

# --- ⚠️ A PIPE READ IS NOT A LINE BOUNDARY -----------------------------------

lines, rest = fw.split_lines(b"focus 1\nfocus 0\n")
check("two lines in one read are both returned", lines, ["focus 1", "focus 0"])
check("and nothing is left over", rest, b"")

lines, rest = fw.split_lines(b"focus 1\nfoc")
check("a partial tail is not returned as a line", lines, ["focus 1"])
check("it is kept for the next read", rest, b"foc")
lines, rest = fw.split_lines(rest + b"us 0\n")
check("and completes when the rest arrives", lines, ["focus 0"])
check("with nothing left", rest, b"")

check("no newline at all yields no lines", fw.split_lines(b"focus 1")[0], [])
check("and keeps every byte", fw.split_lines(b"focus 1")[1], b"focus 1")
check("an empty read is empty, not an error", fw.split_lines(b""), ([], b""))
check("a bare newline is an empty line, not a dropped one",
      fw.split_lines(b"\nfocus 1\n")[0], ["", "focus 1"])
# Undecodable bytes must not raise: this is a pipe, and the reader is the only
# input path on the device.
check("invalid utf-8 is replaced rather than thrown",
      len(fw.split_lines(b"\xff\xfe\n")[0]), 1)

# --- the exit vocabulary the mapper reads back --------------------------------

check("every failure exit has a sentence",
      sorted(fw.EXIT_REASONS), [fw.EXIT_NO_CONNECTION, fw.EXIT_NO_PROTOCOL,
                                fw.EXIT_LOST, fw.EXIT_SEAT_TAKEN,
                                fw.EXIT_ORPHANED])
check("success is NOT in the table (nothing to explain)",
      fw.EXIT_OK in fw.EXIT_REASONS, False)
check("the codes are distinct",
      len({fw.EXIT_OK, fw.EXIT_NO_CONNECTION, fw.EXIT_NO_PROTOCOL,
           fw.EXIT_LOST, fw.EXIT_SEAT_TAKEN, fw.EXIT_ORPHANED}), 6)
check("the seat sentence names the fix measured in R-51",
      "waylandim" in fw.EXIT_REASONS[fw.EXIT_SEAT_TAKEN], True)


# --- a FAKE COMPOSITOR, and it is named a fake on purpose ---------------------
#
# ⚠️ THIS PROVES NOTHING ABOUT HYPRLAND. It is a Unix socket that speaks the
# handful of messages the watcher exchanges, so the WATCHER can be driven end to
# end -- connect, round trip, bind, decode -- with no compositor, no seat
# contest, and no display. The real-compositor half is R-51: the same program,
# against a live Hyprland, emitted `focus 0` then `focus 1` off a real seat.
#
# What this catches that R-51 cannot: a regression, in CI, on a machine with no
# Wayland at all.
#
# The encoders below are the TEST'S OWN. Reusing the module's would let a
# mutation move both sides together and stay invisible.

def t_str(value: str) -> bytes:
    raw = value.encode() + b"\0"
    return struct.pack("I", len(raw)) + raw + b"\0" * ((-len(raw)) % 4)


def t_msg(object_id: int, opcode: int, body: bytes = b"") -> bytes:
    return struct.pack("II", object_id, ((8 + len(body)) << 16) | opcode) + body


def t_parse(buffer: bytes):
    """Requests out of a read buffer: (object_id, opcode, body), plus the tail."""
    out = []
    while len(buffer) >= 8:
        object_id, second = struct.unpack_from("II", buffer, 0)
        size, opcode = second >> 16, second & 0xFFFF
        if size < 8 or len(buffer) < size:
            break
        out.append((object_id, opcode, buffer[8:size]))
        buffer = buffer[size:]
    return out, buffer


class FakeCompositor:
    """Answers get_registry and sync, then runs a script once the input method
    is asked for. Each script entry is ONE write, so batching is under test."""

    def __init__(self, path: str, *, offer_manager: bool = True,
                 offer_seat: bool = True, answer_sync: bool = True,
                 script=()) -> None:
        self.path = path
        self.offer_manager = offer_manager
        self.offer_seat = offer_seat
        self.answer_sync = answer_sync
        self.script = list(script)
        self.im_id = None
        self.new_ids = []       # every object the client asked to create, in order
        self.bound = {}         # interface -> the id the client bound it to
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(path)
        self.server.listen(1)
        self.conn = None
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def _serve(self) -> None:
        try:
            self.conn, _ = self.server.accept()
        except OSError:
            return
        buffer = b""
        while True:
            try:
                chunk = self.conn.recv(65536)
            except OSError:
                return
            if not chunk:
                return
            buffer += chunk
            requests, buffer = t_parse(buffer)
            for object_id, opcode, body in requests:
                try:
                    self._handle(object_id, opcode, body)
                except OSError:
                    return

    def _handle(self, object_id: int, opcode: int, body: bytes) -> None:
        if object_id == 1 and opcode == 1:            # wl_display.get_registry
            registry = struct.unpack_from("I", body, 0)[0]
            self.new_ids.append(registry)
            self.registry_id = registry
            out = b""
            if self.offer_seat:
                out += t_msg(registry, 0, struct.pack("I", 1) + t_str("wl_seat")
                             + struct.pack("I", 9))
            if self.offer_manager:
                out += t_msg(registry, 0,
                             struct.pack("I", 2)
                             + t_str("zwp_input_method_manager_v2")
                             + struct.pack("I", 1))
            self.conn.sendall(out)
            return
        if object_id == 1 and opcode == 0:            # wl_display.sync
            callback = struct.unpack_from("I", body, 0)[0]
            self.new_ids.append(callback)
            if self.answer_sync:
                self.conn.sendall(t_msg(callback, 0, struct.pack("I", 0)))
                # A real server frees the callback straight after. This is the
                # message that used to make the watcher print a spurious
                # `focus 0` on connect.
                self.conn.sendall(t_msg(1, 1, struct.pack("I", callback)))
            return
        if object_id == getattr(self, "registry_id", None) and opcode == 0:
            # wl_registry.bind(name, interface, version, new_id). Which object
            # is which interface is learned HERE rather than read off the
            # module's constants, so a renumbering cannot move both sides at
            # once and stay invisible.
            interface, offset = fw.unpack_string(body, 4)
            new_id = struct.unpack_from("I", body, offset + 4)[0]
            self.new_ids.append(new_id)
            self.bound[interface] = new_id
            return
        if object_id == self.bound.get("zwp_input_method_manager_v2") and opcode == 0:
            self.im_id = struct.unpack_from("I", body, 4)[0]
            self.new_ids.append(self.im_id)
            self.play(self.script)
            return

    def play(self, script) -> None:
        """Send each batch of events TO THE ID THE CLIENT ASKED FOR.

        ⚠️ Not to a number this file remembers. The first version of this fake
        addressed a hard-coded 5, which was right until the client's ids were
        renumbered -- and then the fake went on talking to the manager while
        every assertion timed out.
        """
        for batch in script:
            self.conn.sendall(b"".join(t_msg(self.im_id, op) for op in batch))
            # Separate writes must land as separate reads, or the batching this
            # file asserts on would be decided by the kernel.
            time.sleep(0.1)

    def hangup(self) -> None:
        if self.conn is not None:
            try:
                self.conn.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            self.conn.close()

    def close(self) -> None:
        self.hangup()
        try:
            self.server.close()
        except OSError:
            pass


# zwp_input_method_v2's event opcodes, from the protocol XML and written down
# HERE rather than read from the module: a test that takes its opcodes from the
# code under test cannot notice the code using the wrong one.
ACTIVATE, DEACTIVATE, DONE, UNAVAILABLE = 0, 1, 5, 6

WATCHER = REPO_ROOT / "src" / "deck_osk_focus.py"


def run_watcher(sock_path: str, *args, timeout: float = 15.0):
    """The real program, as a real process. Returns (code, stdout, stderr)."""
    env = dict(os.environ)
    env["WAYLAND_DISPLAY"] = sock_path
    env["XDG_RUNTIME_DIR"] = os.path.dirname(sock_path)
    proc = subprocess.Popen([sys.executable, str(WATCHER), *args],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, env=env)
    try:
        out, err = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        proc.kill()
        out, err = proc.communicate()
        return None, out, err
    return proc.returncode, out, err


def read_lines(stream, count: int, timeout: float = 10.0) -> list[str]:
    """Read `count` whole lines from a LIVE process, or fewer if it goes quiet.

    Deliberately not `readline()`: this must not block past the deadline, and
    it must not use the module's own splitter -- pinning `flush` and `split`
    with the code under test would be circular.
    """
    fd = stream.fileno()
    buffer, lines = b"", []
    deadline = time.monotonic() + timeout
    while len(lines) < count and time.monotonic() < deadline:
        if not select.select([fd], [], [], deadline - time.monotonic())[0]:
            break
        chunk = os.read(fd, 4096)
        if not chunk:
            break
        buffer += chunk
        while b"\n" in buffer:
            line, buffer = buffer.split(b"\n", 1)
            lines.append(line.decode())
    return lines


tmp = tempfile.mkdtemp(prefix="deck-osk-focus-test.")

# --- 1. activate and done in ONE write: the state commits at once ------------

sock = os.path.join(tmp, "wayland-fake1")
fake = FakeCompositor(sock, script=[[ACTIVATE, DONE]])
code, out, err = run_watcher(sock, "--once")
fake.close()
check("a batched activate+done prints one line", out, "focus 1\n")
check("and --once exits cleanly", code, fw.EXIT_OK)
check("the input method was created on the id the module documents",
      fake.im_id, fw.INPUT_METHOD_ID)
check("the seat and manager were bound before it",
      (fake.bound.get("wl_seat"), fake.bound.get(fw.MANAGER_INTERFACE)),
      (fw.SEAT_ID, fw.MANAGER_ID))

# ⚠️ THE RULE A FAKE COMPOSITOR WILL NOT ENFORCE FOR YOU, AND THE REAL ONE
# ENFORCES ABSOLUTELY. libwayland's server keeps client objects in an array and
# rejects any id past one-past-the-end, so every new object must take the next
# free number IN THE ORDER IT IS SENT. Measured against live Hyprland 0.56 on
# 2026-08-11: a sync callback numbered 4 while ids 1-2 existed came back
# `invalid arguments for wl_display#1.sync` -- a message that names the wrong
# thing, and cost a round of guessing. An earlier version of this suite passed
# with exactly that bug, because a fake accepts any number you like.
check("every object id is allocated densely, in the order it is sent",
      fake.new_ids, [2, 3, 4, 5, 6])

# --- 2. separate writes: activate alone must NOT show the keyboard ------------
#
# The protocol batches and commits with `done`. Acting on activate alone shows a
# keyboard for a change the compositor may still revise. Asserted here against
# the real program, on a real pipe, while it is still running -- which is also
# the only assertion that can catch stdout losing its flush, because a process
# that exits flushes everything on the way out and looks identical.

sock = os.path.join(tmp, "wayland-fake2")
# The third write is a bare `done` with nothing pending -- the compositor sends
# one after surrounding-text and content-type changes too. It must print
# NOTHING: a line per event rather than a line per change would have the reader
# re-showing a keyboard that is already up.
fake = FakeCompositor(sock, script=[[ACTIVATE], [DONE], [DONE], [DEACTIVATE, DONE]])
env = dict(os.environ, WAYLAND_DISPLAY=sock, XDG_RUNTIME_DIR=tmp)
live = subprocess.Popen([sys.executable, str(WATCHER)],
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
lines = read_lines(live.stdout, 2)
check("`done` is what shows the keyboard -- and it says so while still running",
      lines[:1], ["focus 1"])
check("a batched deactivate+done hides it again", lines[1:2], ["focus 0"])
# Three writes preceded that: an uncommitted `activate`, the `done` that
# committed it, and a bare `done` changing nothing. Neither of the two silent
# ones may print, or the reader spends its time re-showing a keyboard that is
# already up.
check("and nothing else was printed at all",
      read_lines(live.stdout, 1, timeout=1.0), [])
fake.hangup()
try:
    check("a compositor that hangs up is a named exit, not a crash",
          live.wait(timeout=10), fw.EXIT_LOST)
except subprocess.TimeoutExpired:
    live.kill()
    check("a compositor that hangs up is a named exit, not a crash",
          "still running", fw.EXIT_LOST)
stderr_text = live.stderr.read().decode()
live.stderr.close()
live.stdout.close()
fake.close()
check("and it says the chord still works",
      "STEAM+X" in stderr_text, True)

# --- 3. the seat is already taken ---------------------------------------------

sock = os.path.join(tmp, "wayland-fake3")
fake = FakeCompositor(sock, script=[[UNAVAILABLE]])
code, out, err = run_watcher(sock)
fake.close()
check("an occupied seat exits with its own code", code, fw.EXIT_SEAT_TAKEN)
check("printing nothing on stdout -- there is no focus to report", out, "")
check("it names both candidates rather than guessing",
      ("squeekboard" in err and "fcitx5" in err), True)
check("and the one-command fix R-51 measured", "--disable waylandim" in err, True)

# --- 4. a compositor with no input-method protocol ----------------------------
#
# ⚠️ THE CASE THAT USED TO HANG. Reading a fixed number of times and hoping the
# globals arrive means that when the manager is absent -- the exact case the
# code was written to report -- the next read blocks forever and nothing is ever
# reported. `wl_display.sync` is what makes "that was all of them" knowable.

sock = os.path.join(tmp, "wayland-fake4")
fake = FakeCompositor(sock, offer_manager=False)
code, out, err = run_watcher(sock, timeout=15.0)
fake.close()
check("a compositor without the protocol is reported, not waited on",
      code, fw.EXIT_NO_PROTOCOL)
check("naming the interface it lacks",
      "zwp_input_method_manager_v2" in err, True)

# ...and the same for the seat. An unbound name here used to be a KeyError out
# of `bind` -- a traceback where a sentence belongs.
sock = os.path.join(tmp, "wayland-fake4b")
fake = FakeCompositor(sock, offer_seat=False)
code, out, err = run_watcher(sock)
fake.close()
check("a missing wl_seat is a sentence, not a traceback", code, fw.EXIT_NO_PROTOCOL)
check("naming that one too", "wl_seat" in err, True)
check("and no traceback escaped", "Traceback" in err, False)

# --- 5. a compositor that accepts and then says nothing -----------------------

sock = os.path.join(tmp, "wayland-fake5")
fake = FakeCompositor(sock, answer_sync=False)
code, out, err = run_watcher(sock, "--handshake-timeout", "0.4")
fake.close()
check("a silent compositor times out during setup", code, fw.EXIT_NO_CONNECTION)
check("saying so", "did not answer" in err, True)

# --- 6. no socket at all: the installer, and any non-Wayland console ----------

code, out, err = run_watcher(os.path.join(tmp, "no-such-socket"))
check("a missing socket is a clean refusal", code, fw.EXIT_NO_CONNECTION)
check("named as a missing Wayland connection", "no Wayland connection" in err, True)

# The handshake must not leave the socket on a timeout: silence is NORMAL once
# watching, and a timeout there would report a healthy compositor as broken.
sock = os.path.join(tmp, "wayland-fake7")
fake = FakeCompositor(sock, script=[])
env = dict(os.environ, WAYLAND_DISPLAY=sock, XDG_RUNTIME_DIR=tmp)
live = subprocess.Popen([sys.executable, str(WATCHER),
                         "--handshake-timeout", "0.4"],
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
time.sleep(1.5)   # comfortably past the handshake timeout
check("a bound watcher keeps waiting through silence", live.poll(), None)
fake.play([[ACTIVATE, DONE]])
check("and still reports the next focus change",
      read_lines(live.stdout, 1), ["focus 1"])
live.terminate()
live.wait(timeout=10)
live.stdout.close()
live.stderr.close()
fake.close()


# --- 8. §5.27a: AN ORPHANED WATCHER KEEPS THE SEAT, SO IT MUST NOT SURVIVE ----
#
# ⚠️ NOT A CHECK THAT PR_SET_PDEATHSIG WAS SET. That would be a test of a
# syscall. What is under test is the consequence: kill the process that started
# the watcher, and the watcher is GONE. An orphan here is not litter, it is a
# broken feature -- it goes on holding the single-occupancy input-method seat,
# so the next mapper's auto-show is answered `unavailable` forever and reads as
# "auto-show does not work" rather than "something is stuck".
#
# Measured before the fix, with exactly the parent below: the watcher survived
# its SIGTERMed parent and was reparented to `systemd --user`, NOT to pid 1 --
# which is why the code does not test `getppid() == 1`.


def proc_state(pid: int) -> str:
    """The kernel's own view: 'gone', 'Z' for a zombie, or the state letter.

    ⚠️ NOT `os.kill(pid, 0)`. The watcher is a GRANDCHILD here and nothing in
    this process waits on it, so when it dies under a parent that is still
    around not to reap it, it becomes a zombie -- and signal 0 to a zombie
    succeeds. That reports a dead process as running, which is the one wrong
    answer this test cannot afford.
    """
    try:
        with open(f"/proc/{pid}/stat", "rb") as fh:
            data = fh.read()
    except OSError:
        return "gone"
    # `comm` is parenthesised and may itself contain spaces and parens, so the
    # state is the field after the LAST ')', never the second field of a split.
    return data[data.rindex(b")") + 2:].split()[0].decode()


def running(pid: int) -> bool:
    return proc_state(pid) not in ("gone", "Z")


def wait_gone(pid: int, timeout: float = 10.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline and running(pid):
        time.sleep(0.05)
    return not running(pid)


# ⚠️ SPAWNED THE WAY `AutoShow.start()` SPAWNS IT, which is the whole point:
# `stdout=PIPE, bufsize=0`, the read end held for the parent's lifetime, no
# SIGTERM handler, and ONE THREAD -- PR_SET_PDEATHSIG fires on the death of the
# thread that forked, so a parent that spawned from a worker thread would be
# testing something else entirely. The mapper imports no `threading`.
PARENT_SRC = """
import os, subprocess, sys, time
proc = subprocess.Popen([sys.executable, sys.argv[1]], stdout=subprocess.PIPE,
                        bufsize=0)
sys.stdout.write("%d\\n" % proc.pid)
sys.stdout.flush()
if sys.argv[2] == "vanish":
    os._exit(0)
time.sleep(3600)
"""


def spawn_parent(sock_path: str, mode: str = "stay"):
    """A stand-in mapper. Returns (the parent, the watcher's pid)."""
    env = dict(os.environ, WAYLAND_DISPLAY=sock_path,
               XDG_RUNTIME_DIR=os.path.dirname(sock_path))
    # -B: this suite disables bytecode for itself, and a probe that imported
    # the module under test without it would leave a src/__pycache__ that
    # mutation testing then runs instead of the mutated file (§1's one-second
    # mtime granularity).
    parent = subprocess.Popen(
        [sys.executable, "-B", "-c", PARENT_SRC, str(WATCHER), mode],
        stdout=subprocess.PIPE, text=True, env=env)
    return parent, int(parent.stdout.readline())


def wait_for_seat(fake, timeout: float = 15.0) -> None:
    deadline = time.monotonic() + timeout
    while fake.im_id is None and time.monotonic() < deadline:
        time.sleep(0.02)


# 8a. the bug itself: a plain `kill` on a mapper started by hand.
sock = os.path.join(tmp, "wayland-fake8a")
fake = FakeCompositor(sock, script=[])
parent, watcher_pid = spawn_parent(sock)
wait_for_seat(fake)
check("the watcher is up and has taken the input-method seat",
      (fake.im_id, running(watcher_pid)), (fw.INPUT_METHOD_ID, True))

# ⚠️ THE CONTROL, and without it every assertion below passes vacuously: a
# watcher that simply exited at start-up is also "gone after the kill", so
# "gone" only means anything once "still here" has been shown first.
time.sleep(1.0)
check("and it stays up for as long as its parent does -- so `gone` below is news",
      running(watcher_pid), True)

parent.send_signal(signal.SIGTERM)
check("SIGTERM ends the parent outright, running no `finally` on the way",
      parent.wait(timeout=10), -signal.SIGTERM)
check("§5.27a: and the watcher goes with it, seat and all",
      wait_gone(watcher_pid), True)
fake.close()

# 8b. SIGKILL: nothing the parent could have done, and the case systemd's
# KillMode=control-group covers for a service and nothing covers for a mapper
# run from a terminal.
sock = os.path.join(tmp, "wayland-fake8b")
fake = FakeCompositor(sock, script=[])
parent, watcher_pid = spawn_parent(sock)
wait_for_seat(fake)
check("a second watcher takes the seat the same way", running(watcher_pid), True)
parent.kill()
parent.wait(timeout=10)
check("a SIGKILLed parent takes the watcher with it too",
      wait_gone(watcher_pid), True)
fake.close()

# 8c. ⚠️ THE WINDOW PR_SET_PDEATHSIG CANNOT COVER BY ITSELF. Between the fork
# and the prctl sits a whole Python interpreter start-up, so a parent that dies
# in there is already gone when the kernel would have signed the watcher up,
# and the signal never comes. Measured 5/5 survivors with PDEATHSIG alone.
# `getppid()` cannot see it either -- it already reads the reaper by the time
# the watcher looks. The closed stdout pipe is what remains true.
survivors = 0
for attempt in range(3):
    sock = os.path.join(tmp, f"wayland-fake8c{attempt}")
    fake = FakeCompositor(sock, script=[])
    parent, watcher_pid = spawn_parent(sock, mode="vanish")
    parent.wait(timeout=10)
    # 3s, deliberately under the 5s handshake timeout: a watcher that died
    # because its compositor went quiet would prove nothing about orphans.
    if not wait_gone(watcher_pid, 3.0):
        survivors += 1
        os.kill(watcher_pid, signal.SIGKILL)
    fake.close()
check("a parent that dies before the watcher is even up leaves no orphan either",
      survivors, 0)

# 8d. the same guard where its exit code can actually be read: a DIRECT child,
# whose stdout reader is closed while its parent (this process) lives on --
# which is what a dead mapper looks like from inside the watcher.
sock = os.path.join(tmp, "wayland-fake8d")
fake = FakeCompositor(sock, script=[])
read_fd, write_fd = os.pipe()
env = dict(os.environ, WAYLAND_DISPLAY=sock, XDG_RUNTIME_DIR=tmp)
orphan = subprocess.Popen([sys.executable, str(WATCHER)], stdout=write_fd,
                          stderr=subprocess.PIPE, env=env, text=True)
os.close(read_fd)      # nobody is reading it any more
os.close(write_fd)
# ⚠️ WAIT FIRST, READ SECOND. `stderr.read()` returns at EOF, i.e. when the
# watcher exits -- so reading before waiting turns "the guard is broken" into
# "the suite hangs forever", which is the one failure mode a test may not have.
# It cost a mutation run before it was written this way round.
try:
    orphan_code = orphan.wait(timeout=10)
except subprocess.TimeoutExpired:
    orphan.kill()
    orphan.wait(timeout=10)
    orphan_code = "still running"
orphan_err = orphan.stderr.read()
orphan.stderr.close()
check("a watcher with no reader left refuses under its own exit code",
      orphan_code, fw.EXIT_ORPHANED)
check("saying which process it lost", "nothing is reading" in orphan_err, True)
check("and that the chord is unaffected", "STEAM+X" in orphan_err, True)
fake.close()

# 8e. the microsecond window nothing else can see: the parent dying between the
# `getppid()` and the prctl. Two adjacent syscalls -- unreachable by black-box
# timing -- so the DECISION is pinned instead. Still not "was the flag set":
# the assertion is that the watcher refuses when its parent moved under it.
# In a subprocess so this suite never arms PDEATHSIG on itself.
PROBE = (
    "import importlib.util, os, sys;"
    f"spec = importlib.util.spec_from_file_location('f', {str(WATCHER)!r});"
    "m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m);"
    "print(m.die_with_parent(parent=os.getppid()));"
    "print(m.die_with_parent(parent=os.getppid() + 100000))"
)
probe = subprocess.run([sys.executable, "-B", "-c", PROBE],
                       capture_output=True, text=True, timeout=30)
probe_lines = probe.stdout.split("\n")
check("with its parent where it left it, the watcher carries on",
      probe_lines[0] if probe_lines else probe.stderr, "None")
check("with the parent moved out from under it, it refuses and says so",
      "died during start-up" in (probe_lines[1] if len(probe_lines) > 1 else ""),
      True)

try:
    for name in os.listdir(tmp):
        os.unlink(os.path.join(tmp, name))
    os.rmdir(tmp)
except OSError:
    pass

print()
print(f"{'PASS' if FAILURES == 0 else 'FAIL'} — {FAILURES} failure(s)")
sys.exit(1 if FAILURES else 0)
