#!/usr/bin/env python3
"""Unit tests for the hand-rolled Wayland focus watcher (T8 step 8).

No compositor, no socket: the wire format and the event state machine are pure,
and they are where the bugs live. Run directly:

    python3 test-deck-osk-focus.py
"""

from __future__ import annotations

import importlib.util
import pathlib
import struct
import sys

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

print()
print(f"{'PASS' if FAILURES == 0 else 'FAIL'} — {FAILURES} failure(s)")
sys.exit(1 if FAILURES else 0)
