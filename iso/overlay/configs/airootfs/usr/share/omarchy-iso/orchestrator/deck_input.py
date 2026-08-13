"""§5.25 decision #1's `above_lock = 2` layer rule, and §5.24a requirement #1's
two DPMS `misc` lines -- T5 §5.6, `docs/PROGRESS.md` §5.25, and
`docs/findings/T9-lock-wake-and-blank-timing.md` §5.1.

SHIPPED AS ``/usr/share/omarchy-iso/orchestrator/deck_input.py``. One
``configure_deck`` step -- ``lock_wake_dpms`` -- registered in
``deck_configure.deck_steps``.

WHAT THIS CLOSES, AND WHY THE TWO FIXES SHARE ONE STAGE
=========================================================

Both land in the same per-user file, ``~/.config/hypr/input.lua``, so they are
one stage rather than two:

1. **§5.25 decision #1** -- ``hl.layer_rule({ match = { namespace = "deck-osk" },
   above_lock = 2 })``. Draws the on-screen keyboard above a lock surface and
   makes it hit-testable there, which is what makes the menu's ``system.lock``
   row (``deck_menu_lock.py`` leaves it reachable, deliberately) answerable on a
   device with no physical keyboard. Hand-applied on the physical test Deck
   only until now; no code anywhere in this repo wrote it.
2. **§5.24a requirement #1** -- ``misc.key_press_enables_dpms`` and
   ``misc.mouse_move_enables_dpms``, both ``false``. Upstream ships both
   ``true``. ``docs/findings/T9-lock-wake-and-blank-timing.md`` (T9) found that
   the only two things that ever put the panel into DPMS-off on this Deck are
   the lock screen's own hardcoded 5s ``idleBlankTimer`` and the 86400s
   ``idle.lock`` -- so nothing else needs Hyprland's own generic "any key or
   mouse motion re-enables DPMS" to be listening, and disabling it stops the
   QAM menu popup's incidental pointer/focus event from waking a blanked panel
   while the Deck is locked. The lock screen's OWN wake path
   (``LockView.qml``'s ``MouseArea``/``Keys.onPressed`` -> ``wakeRequested()``
   -> ``omarchy-system-wake``) is untouched by this and still wakes the panel
   for real typing/clicking on the password field. T9 §5.1's own closing
   recommendation: "whoever implements §5.25 decision #1's ``above_lock``/mask
   stage should fold these two ``misc`` lines into the same ``input.lua``
   mirror" -- this module is that whoever.

WHY T9 §5.1'S "FULL PROPOSED CONTENT" IS NOT PASTED IN VERBATIM
==================================================================

T9 §5.1 proposes a *whole-file mirror* of ``input.lua``: upstream's
``kb_layout``/``kb_variant`` handling, a ``read_vconsole()`` helper, a
non-Latin-layout table, ``kb_options = "compose:caps,shift:both_capslock_cancel"``,
the touchpad block, the terminal ``scroll_touchpad`` overrides -- **and then**
the two ``misc`` lines and the ``above_lock`` rule. That is the right shape for
a *whole-file* stage (``stage_greeter_rotation``'s pattern, which T9 names as
the precedent it is following), but it is the WRONG shape for this codebase's
actual architecture, which ``deck_monitors.py`` established for exactly this
directory: **splice a marker-delimited block, preserve every byte outside it**.

Two things confirm the splice is not merely a stylistic swap:

* **`docs/tasks/T5-fork-plan.md` §5.24a's own warning**: "Do NOT transcribe the
  comment currently on the operator's Deck." Fetching the REAL upstream
  ``default/hypr/input.lua`` out of the pinned fresh-4.0 install manifest
  (``iso/upstream/manifests/fresh-4-semantic.json``,
  ``files.user_config["~/.config/hypr/input.lua"].text``) shows it carries
  **no `misc` table, no `read_vconsole()`, no non-Latin-layout table, and no
  `compose:caps,shift:both_capslock_cancel`** -- just `kb_layout = "us"`,
  `kb_options = "compose:caps"`, `numlock_by_default`, and the touchpad block.
  T9's "full proposed content" was captured from the **hand-edited state of
  the physical test Deck**, not from upstream, and pasting it in would ship a
  site-specific customization (the vconsole-driven, non-Latin-aware
  `kb_layout`) as though it were part of this fix, permanently overriding
  whatever `kb_layout` upstream or a future stage would otherwise seed.
* **It would duplicate another module's job.** Per-device on-screen-keyboard
  XKB pinning is `src/deck-session.sh`'s `install_osk_kb_layout_rule` (its own
  marker pair, `OSK_KB_RULE_BEGIN`/`END`) -- a NARROWER, per-device
  `hl.device()` rule, deliberately not a change to the file's global
  `input.kb_layout`. Re-deriving `kb_layout` here would be a second,
  divergent answer to a question that function already owns, in the one file
  they both have to share.

So this module's spliced block contains exactly the two NEW additions -- the
`misc` DPMS lines and the `above_lock` layer rule -- as two ordinary top-level
Lua statements, plus the parse sentinel. Nothing here reads `/etc/vconsole.conf`
or touches `kb_layout`.

⚠️ **A second `hl.config({ misc = {...} })` call after the seed/existing file's
own `hl.config({ input = {...} })` call is a JUDGMENT CALL, stated rather than
assumed.** Hyprland's Lua config is executed top-to-bottom as an imperative
script (`hyprland.lua`'s own `require` chain runs modules in sequence, and
`deck_monitors.py`'s own docstring already relies on this: its `hl.env`
override is INFERRED to win because it runs later). Setting a SCALAR option
(`misc.key_press_enables_dpms`) is a different kind of operation from matching
a RULE by pattern (`hl.monitor`'s per-output rules, where `deck_monitors.py`
explicitly declines to assume which of several matching rules wins) -- a
scalar assignment has no matching ambiguity, only an ordering one, and this
module's block is always spliced in **at the end of the file** (`splice()`,
copied from `deck_monitors.py`), so it always runs last and always wins. This
has NOT been measured against a live compositor by this module -- see
`verify_live` below, which is the check that would settle it were a live
Hyprland instance ever available.

MARKERS, AND WHY THEY ARE NOT THE OSK RULE'S OR THE MONITORS MODULE'S
=========================================================================

``~/.config/hypr/input.lua`` already has ONE writer:
``src/deck-session.sh``'s ``install_osk_kb_layout_rule``, whose block is
delimited by ``OSK_KB_RULE_BEGIN``/``END`` and whose sentinel is
``DECK_OSK_KB_LAYOUT``. This module is a SECOND writer of the SAME file, which
is exactly the shape `deck_monitors.py`'s own docstring warns about for its
neighbour: "Two writers sharing a marker is how each one comes to eat the
other." So:

1. **Never opens the file for anything but its own marker pair.** The whole of
   `install_osk_kb_layout_rule`'s block -- and anything else a user or another
   tool put in the file -- is preserved byte-for-byte outside this module's own
   markers.
2. **Its own markers and its own sentinel**, distinct from both
   `deck-session.sh`'s `OSK_KB_RULE_BEGIN`/`END`/`DECK_OSK_KB_LAYOUT` and from
   `deck_monitors.py`'s `monitors.lua` markers (a different file entirely, but
   the naming convention is shared on purpose so a reader can tell which
   module owns which block at a glance).
3. **Snapshots every OTHER file in `~/.config/hypr/` before writing and asserts
   they are byte-identical afterwards** (`deck_monitors.snapshot_siblings` /
   `assert_siblings_preserved`'s exact pattern, reimplemented here rather than
   imported -- this repo's convention, established by `deck_monitors.py`
   itself, is that each orchestrator module is self-contained and imports only
   from `deck_configure`/`deck_user`/`ui`/`context`, never from a sibling
   `deck_*` module).

A LUA SYNTAX ERROR DISCARDS THE WHOLE FILE, SILENTLY -- SAME TRAP, SAME FIX
=============================================================================

Hyprland answers a Lua parse error by discarding the ENTIRE file, without
logging a reason, with ``hyprctl configerrors`` staying clean
(``docs/PROGRESS.md`` §7, `deck_monitors.py`'s own §5.11 history). So:

* *At install time*, the staged file is handed to ``luac -p`` **inside the
  target** before it replaces the live one; a rejection is a refusal.
  ``warn-and-continue`` if ``luac`` is absent -- `deck_monitors.py`'s and
  `install_osk_kb_layout_rule`'s existing policy, not a stricter one invented
  here: refusing to fix a lock screen because a compiler happens to be missing
  trades a safer Deck for a tidier check.
* *At run time*, the block's LAST statement assigns a sentinel,
  ``DECK_INPUT_LUA_LOADED = true``, and the verification is an ASSERTION --
  ``hyprctl eval 'if DECK_INPUT_LUA_LOADED == nil then error("...") end'`` --
  **never a bare readback**. `docs/tasks/T5-fork-plan.md` §5.6 states this in
  the strongest terms this repo has: "Do NOT transcribe the comment currently
  on the operator's Deck" -- measured **false** 2026-08-12, `hyprctl eval`
  prints `ok` and exits 0 for a name that has never existed.
  `test/unit/test-hyprctl-syntax.sh` scanner 3 fails the build if the broken
  readback form is written down anywhere in this repo, this file included.

THE SLEEP-LOCK SERVICE -- INVESTIGATED, NOT FIXED HERE
=========================================================

`deck_menu_lock.py`'s docstring claims the second §5.6 lock producer,
`omarchy-sleep-lock.service`, is "masked; `src/`, another slice". Verified
this session, by reading rather than assuming: the masking logic
(`install_sleep_lock_mask`, `src/deck-session.sh` ~line 3402, invoked from
`stage_desktop_settings`) exists **only** in `src/deck-session.sh`, dispatched
by name (`deck-session.sh stage-desktop-settings`) -- it is not present
anywhere under `iso/overlay/` (confirmed: no `deck-session.sh` in the airootfs
tree at all) and no `deck_*.py` orchestrator module calls it.
`iso/bin/build`'s only reference to `deck-session.sh` sources it on the
**host**, for `tools/iso-payload-audit.sh`'s privilege audit, which is a
build-time check, not an install-time action. `deck_session_settings.py`'s own
docstring says as much directly: "The other two -- the sleep-lock unit and the
menu's `system.lock` -- are unaffected by anything here." **A real end-user
install from this ISO never runs `deck-session.sh` at all** -- it is a
dev-machine, SSH-iterate-in-place tool per `CLAUDE.md`'s `src/` vs `tools/`
description, not a first-boot or install-time mechanism. So: **the sleep-lock
mask is genuinely missing from the live-ISO install path.** This is a real gap
against `docs/tasks/T5-fork-plan.md` §5.6's own table, which says
`configure_deck` should write the mask. It is NOT fixed in this commit --
masking a systemd unit for every future user (`/etc/systemd/user/` global
mask, `install_sleep_lock_mask`'s own logic) is a different mechanism again
(no Lua, no splice, a symlink-must-not-already-exist refusal shape) and is
comfortably its own task, not a few-line addition to this one. Flagged in the
commit message and the final report instead.
"""

from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path

from .deck_configure import record_result, sanitize_text
from .deck_user import DeckUserDeferred, DeckUserError, resolve_target_user
from .ui import error, info

# ---------------------------------------------------------------------------
# What gets written, and the two measured/decided facts
# ---------------------------------------------------------------------------

# The on-screen keyboard's own layer-shell namespace. `src/deck_osk_focus.py`
# and `iso/overlay/.../deck-form.sh` are the other places this string has to
# stay in step with; it is not derived from either here because this module
# has no import relationship with them (see the docstring's "self-contained
# module" note) and the string is small enough that a drift would be caught by
# `verify_live`'s live-compositor check the day it is ever run.
DECK_OSK_LAYER_NAMESPACE = "deck-osk"

# docs/PROGRESS.md 5.25 decision #1 / T9-lock-service-mitigation.md T0.4,
# hardware-verified 2026-08-11. Hyprland's own layer-rule field name, on
# Hyprland's release schedule -- `verify` and `verify_live` both assert this
# took rather than assuming it, per T5-fork-plan.md 5.6's own warning.
ABOVE_LOCK = 2

# ---------------------------------------------------------------------------
# Where the file lives
# ---------------------------------------------------------------------------

# hyprland.lua's `require("hypr.input")` against package.path
# `$HOME/.config/?.lua;...` -- confirmed against the fresh-4.0 manifest's own
# copy of hyprland.lua. Home-relative, never composed: deck_user reads the
# home out of /etc/passwd.
INPUT_LUA_REL = ".config/hypr/input.lua"
INPUT_LUA_SKEL_REL = f"etc/skel/{INPUT_LUA_REL}"
# The SEED, same path src/deck-session.sh's HYPR_INPUT_LUA_TEMPLATE names.
# Under `config/`, which is NOT on package.path -- Omarchy copies this into a
# home at account creation and never loads it from here directly.
INPUT_LUA_DEFAULTS_REL = "usr/share/omarchy/config/hypr/input.lua"
INPUT_LUA_MODE = 0o644

# The directory this file shares with monitors.lua (deck_monitors.py) and with
# src/deck-session.sh's own OSK_KB_RULE block, written into this SAME file.
HYPR_DIR_REL = str(Path(INPUT_LUA_REL).parent)

# 🔴 OURS ALONE. Different from src/deck-session.sh's
# "-- >>> deck-session.sh: on-screen keyboard XKB layout >>>" pair (same file,
# different writer) and from deck_monitors.py's monitors.lua pair (different
# file). A shared marker is how one writer's re-run eats another's block.
BEGIN = "-- >>> omarchy-deck: lock wake suppression and above_lock >>>"
END = "-- <<< omarchy-deck: lock wake suppression and above_lock <<<"

# The parse sentinel. T5-fork-plan.md 5.6 names this EXACT identifier --
# distinct from deck-session.sh's DECK_OSK_KB_LAYOUT and from
# deck_monitors.py's DECK_MONITORS_LUA_LOADED.
SENTINEL = "DECK_INPUT_LUA_LOADED"

LUAC = "luac"

MAX_INPUT_LUA_BYTES = 1024 * 1024


class DeckInputError(Exception):
    """The lock-wake/above_lock rule could not be installed. Non-critical."""


# ---------------------------------------------------------------------------
# Talking to the target -- identical shape to deck_monitors.py's, reimplemented
# rather than imported (see the docstring's "self-contained module" note).
# ---------------------------------------------------------------------------


def chroot_command(target, argv) -> list[str]:
    """The exact command a target-side invocation runs. Its own function so
    "it runs inside the target" is assertable without a chroot or root."""
    return ["arch-chroot", str(target), *argv]


def run_in_target(target, argv) -> tuple[int, str]:
    """Run ``argv`` inside the target. Returns (exit code, combined output)."""
    try:
        proc = subprocess.run(  # noqa: S603
            chroot_command(target, argv),
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError as exc:
        return 127, f"{type(exc).__name__}: {exc}"
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


def _runner(runner):
    """``None`` means the module attribute, looked up now -- not a default
    argument, so a suite substituting the module attribute is not silently
    bypassed. Same reasoning as deck_monitors.py's `_runner`."""
    return run_in_target if runner is None else runner


# ---------------------------------------------------------------------------
# A Lua comment stripper -- copied from deck_monitors.py's `strip_lua_comments`.
# Duplicated rather than imported (self-contained-module convention above);
# this repo has no cross-`deck_*` import anywhere, and this function has no
# state and no target-filesystem dependency, so the duplication is inert.
# ---------------------------------------------------------------------------


def strip_lua_comments(text: str) -> str:
    """Blank out Lua comments, leaving strings and line structure intact."""
    out: list[str] = []
    i, n = 0, len(text)

    def long_bracket(start: int) -> tuple[int, int] | None:
        if start >= n or text[start] != "[":
            return None
        j = start + 1
        level = 0
        while j < n and text[j] == "=":
            level += 1
            j += 1
        if j < n and text[j] == "[":
            return level, j + 1
        return None

    while i < n:
        ch = text[i]

        if ch == "-" and text.startswith("--", i):
            opened = long_bracket(i + 2)
            if opened is not None:
                level, body = opened
                close = "]" + "=" * level + "]"
                end = text.find(close, body)
                end = n if end < 0 else end + len(close)
                out.append("".join("\n" if c == "\n" else " " for c in text[i:end]))
                i = end
                continue
            end = text.find("\n", i)
            end = n if end < 0 else end
            out.append(" " * (end - i))
            i = end
            continue

        opened = long_bracket(i)
        if opened is not None:
            level, body = opened
            close = "]" + "=" * level + "]"
            end = text.find(close, body)
            end = n if end < 0 else end + len(close)
            out.append(text[i:end])
            i = end
            continue

        if ch in ("'", '"'):
            j = i + 1
            while j < n:
                if text[j] == "\\":
                    j += 2
                    continue
                if text[j] == ch or text[j] == "\n":
                    j += 1
                    break
                j += 1
            out.append(text[i:j])
            i = j
            continue

        out.append(ch)
        i += 1

    return "".join(out)


def last_statement(text: str) -> str:
    """The last non-blank line of the comment-stripped text. Lua runs top to
    bottom, so an assignment that is not last proves only that the file
    parsed as far as itself -- deck_monitors.py's `last_statement`, same
    reasoning, reimplemented here for the same self-containment reason."""
    lines = [line.strip() for line in strip_lua_comments(text).splitlines()]
    for line in reversed(lines):
        if line:
            return line
    return ""


# ---------------------------------------------------------------------------
# Reading our own statements back out of a file
# ---------------------------------------------------------------------------

# Our two statements, rendered in a fixed shape (see render_block): the field
# order and exact spelling are ours to pick and ours alone to read back, since
# no other writer of this file emits either call. Whitespace is tolerant;
# field order and literal spelling are not -- the same trade `deck_monitors.py`
# makes for its own `hl.monitor` line.
_MISC_DPMS_RE = re.compile(
    r"hl\s*\.\s*config\s*\(\s*\{\s*misc\s*=\s*\{\s*"
    r"key_press_enables_dpms\s*=\s*(true|false)\s*,\s*"
    r"mouse_move_enables_dpms\s*=\s*(true|false)\s*,?\s*"
    r"\}\s*,?\s*\}\s*\)"
)

_ABOVE_LOCK_RE = re.compile(
    r"hl\s*\.\s*layer_rule\s*\(\s*\{\s*match\s*=\s*\{\s*"
    r'namespace\s*=\s*"([^"]*)"'
    r"\s*\}\s*,\s*above_lock\s*=\s*(-?\d+)\s*\}\s*\)"
)


def misc_dpms_calls(text: str) -> list[tuple[str, str]]:
    """Every active (comment-stripped) `key_press_enables_dpms`/
    `mouse_move_enables_dpms` pair written in our exact call shape, as
    `("true"|"false", "true"|"false")` tuples, in source order."""
    return _MISC_DPMS_RE.findall(strip_lua_comments(text))


def above_lock_calls(text: str) -> list[tuple[str, str]]:
    """Every active `hl.layer_rule({ match = { namespace = ... }, above_lock =
    ... })` call in our exact shape, as `(namespace, above_lock)` tuples."""
    return _ABOVE_LOCK_RE.findall(strip_lua_comments(text))


# ---------------------------------------------------------------------------
# What gets written
# ---------------------------------------------------------------------------


def render_block() -> list[str]:
    """The marker-delimited block, as lines.

    Two ordinary top-level statements plus the sentinel -- deliberately NOT a
    whole-file mirror. See the module docstring for why T9 §5.1's fuller
    proposal does not belong here verbatim.
    """
    return [
        BEGIN,
        "-- Installed by configure_deck (omarchy-deck ISO). docs/PROGRESS.md",
        "-- 5.25 decision #1, docs/findings/T9-lock-wake-and-blank-timing.md 5.1.",
        "--",
        "-- TWO FIXES, ONE FILE, because input.lua REPLACES upstream's shipped",
        "-- default WHOLESALE (Hyprland does not merge a user override with the",
        "-- shipped one) -- see monitors.lua's own module for the identical trap",
        "-- in the neighbouring file. This block owns exactly these two",
        "-- statements; it does NOT touch kb_layout (src/deck-session.sh's",
        "-- install_osk_kb_layout_rule owns the on-screen keyboard's per-device",
        "-- XKB pin, marked off with its OWN markers elsewhere in this file).",
        "--",
        "-- FIX 1 -- docs/PROGRESS.md 5.24a requirement #1. Upstream ships both",
        "-- of these true. The only two things that ever call DPMS off on this",
        "-- Deck are the lock screen's own hardcoded 5s idleBlankTimer and the",
        "-- 86400s idle.lock, so nothing else needs Hyprland's own generic",
        "-- wake-on-any-input to be listening. Disabling it stops the QAM menu",
        "-- popup's incidental pointer/focus event from waking a blanked panel",
        "-- while the Deck is locked. The lock's OWN wake path (LockView.qml's",
        "-- MouseArea/Keys.onPressed -> wakeRequested() -> omarchy-system-wake)",
        "-- is UNCHANGED by this -- real typing/clicking on the password field",
        "-- still wakes the panel.",
        "hl.config({",
        "  misc = {",
        "    key_press_enables_dpms = false,",
        "    mouse_move_enables_dpms = false,",
        "  },",
        "})",
        "",
        "-- FIX 2 -- docs/PROGRESS.md 5.25 decision #1. Draws deck-osk ABOVE a",
        "-- lock surface and makes it hit-testable there -- what makes the",
        "-- menu's system.lock row answerable on a device with no physical",
        "-- keyboard. Hardware-verified 2026-08-11",
        "-- (T9-lock-service-mitigation.md T0.4).",
        f'hl.layer_rule({{ match = {{ namespace = "{DECK_OSK_LAYER_NAMESPACE}" }}, '
        f"above_lock = {ABOVE_LOCK} }})",
        "",
        "-- Deliberately the LAST statement in this file. Hyprland answers a Lua",
        "-- syntax error ANYWHERE above by discarding the WHOLE file, without",
        "-- logging a reason, with 'hyprctl configerrors' still clean -- so the",
        "-- only way to tell is to ask whether this ran. ASSERT it; never read",
        "-- it back (T5-fork-plan.md 5.6: a bare `return` readback of this name",
        "-- passes whether or not the file loaded -- measured false 2026-08-12):",
        "--",
        f"--   hyprctl eval 'if {SENTINEL} == nil "
        'then error("input.lua was discarded") end\'',
        "--",
        "-- exit 0 = loaded, exit 7 = discarded (the message is printed). Over a",
        "-- remote shell, export HYPRLAND_INSTANCE_SIGNATURE first or the",
        "-- command never runs at all.",
        f"{SENTINEL} = true",
        END,
    ]


def splice(raw: str, block: list[str]) -> tuple[str, bool]:
    """``(new text, replaced an existing block)``. Identical algorithm to
    `deck_monitors.splice`: our block is removed if already present and
    re-appended at the end, so the sentinel stays the LAST statement across a
    re-run, and every byte outside our own markers is preserved."""
    kept: list[str] = []
    skipping = False
    replaced = False
    for line in raw.splitlines():
        bare = line.strip()
        if bare == BEGIN:
            skipping, replaced = True, True
            continue
        if skipping:
            if bare == END:
                skipping = False
            continue
        kept.append(line)
    if skipping:
        raise DeckInputError(
            "input.lua carries our start marker with no end marker. Refusing to guess where the "
            "old block ended -- remove it by hand and re-run"
        )

    head = "\n".join(kept).rstrip("\n")
    out = ([head, ""] if head else []) + block
    return "\n".join(out).rstrip("\n") + "\n", replaced


def outside_our_block(text: str) -> str:
    """Everything that is not our block, verbatim -- includes
    install_osk_kb_layout_rule's OSK_KB_RULE block, any user content, and
    anything else already in the file."""
    kept: list[str] = []
    skipping = False
    for line in text.splitlines():
        bare = line.strip()
        if bare == BEGIN:
            skipping = True
            continue
        if skipping:
            if bare == END:
                skipping = False
            continue
        kept.append(line)
    return "\n".join(kept).strip("\n")


def our_block_text(text: str) -> str | None:
    """Just the content between our OWN ``BEGIN``/``END`` markers (exclusive),
    or ``None`` if our block is not present at all.

    🔴 Why `verify`'s sentinel check reads THIS rather than the whole file's
    last line, unlike `deck_monitors.py`'s equivalent check: `monitors.lua`
    has exactly one writer (that module, by its own docstring's rule 1), so
    "our sentinel is the file's last statement" and "our block is intact" are
    the same fact there. `input.lua` does NOT have exactly one writer --
    `install_osk_kb_layout_rule` is a second, independent splicer of the SAME
    file, using the identical "remove if present, re-append at the end"
    algorithm this module uses. Whichever of the two runs SECOND ends up
    last in the file, and that is an ordering fact about two independent
    tools, not a defect in either one's own block. A textual "am I the very
    last line of the WHOLE file" check would therefore fail this module's own
    verification the moment `deck-session.sh stage-desktop-settings` is next
    run against a Deck this step already configured -- a false failure with
    nothing wrong. What actually matters for this module's own correctness is
    narrower and answerable without assuming anything about a second writer:
    is OUR block, as written, intact and does OUR sentinel sit where OUR
    render_block() always puts it -- last inside OUR OWN markers. Whether the
    file as a WHOLE still parses is `luac -p` (install time) and
    `verify_live`'s live `hyprctl eval` assertion (run time) to answer, not a
    static text scan that cannot see past a syntax error either way.
    """
    lines = text.splitlines()
    start = end = None
    for i, line in enumerate(lines):
        bare = line.strip()
        if bare == BEGIN:
            start = i
        elif bare == END and start is not None:
            end = i
            break
    if start is None or end is None:
        return None
    return "\n".join(lines[start + 1 : end])


def assert_outside_preserved(before: str, after: str, label: str) -> None:
    """Refuse a write that disturbed anything that is not ours -- most
    importantly src/deck-session.sh's OSK_KB_RULE block, which lives in this
    SAME file and which this module must never be able to eat."""
    if outside_our_block(before) == outside_our_block(after):
        return
    raise DeckInputError(
        f"the splice changed content OUTSIDE our own markers in {label}. This file also carries "
        "src/deck-session.sh's on-screen-keyboard XKB block (OSK_KB_RULE_BEGIN/END) and possibly "
        "the user's own overrides -- a rewrite would silently drop them. input.lua REPLACES the "
        "shipped default wholesale; nothing merges it back"
    )


# ---------------------------------------------------------------------------
# The sibling files in ~/.config/hypr -- monitors.lua chief among them
# ---------------------------------------------------------------------------


def snapshot_siblings(target, rel: str) -> dict[str, bytes]:
    """Every other regular file in the same directory, by name. monitors.lua
    (deck_monitors.py) is the one that matters most: losing it takes the
    desktop's rotation and scale down with it."""
    directory = (Path(target) / rel).parent
    if not directory.is_dir():
        return {}
    snap: dict[str, bytes] = {}
    for entry in sorted(directory.iterdir()):
        if entry.name == Path(rel).name or entry.is_symlink() or not entry.is_file():
            continue
        snap[entry.name] = entry.read_bytes()
    return snap


def assert_siblings_preserved(before: dict[str, bytes], after: dict[str, bytes], label: str) -> None:
    if before == after:
        return
    changed = sorted(set(before) | set(after))
    changed = [name for name in changed if before.get(name) != after.get(name)]
    raise DeckInputError(
        f"writing {label} changed {', '.join(changed)} in the same directory. This step writes ONE "
        "file. monitors.lua next to it carries the desktop's own rotation and scale (deck_monitors.py)"
    )


# ---------------------------------------------------------------------------
# The write
# ---------------------------------------------------------------------------


def read_seed(target) -> tuple[str, str, list[str]]:
    """``(text, where it came from, warnings)`` for a file that does not exist
    yet. Mirrors deck_monitors.py's `read_seed` exactly: `require("hypr.input")`
    ERRORS when the user has no input.lua, so writing a block-only file beats
    skipping it -- and this state is one a real install cannot reach, since
    both /etc/skel and /usr/share/omarchy/config ship the file."""
    warnings: list[str] = []
    seed = Path(target) / INPUT_LUA_DEFAULTS_REL
    if seed.is_file():
        data = seed.read_bytes()
        if len(data) > MAX_INPUT_LUA_BYTES:
            raise DeckInputError(f"/{INPUT_LUA_DEFAULTS_REL} is {len(data)} bytes; refusing to parse it")
        return data.decode("utf-8", "replace"), "defaults", warnings
    warnings.append(
        f"neither the file nor /{INPUT_LUA_DEFAULTS_REL} exists on the target, so the block below "
        "is the WHOLE file: Omarchy's kb_layout, numlock and touchpad settings are not in it. "
        "Written anyway rather than skipped -- require('hypr.input') ERRORS when the file is "
        "missing, and a raising require takes the whole Hyprland config with it, so no file is "
        "worse than a partial one"
    )
    return "", "empty", warnings


def lua_syntax_check(target, in_target_path: str, runner=None) -> tuple[bool, str]:
    """``(checked, detail)`` from ``luac -p`` inside the target. ``checked=False``
    is a warning, not a refusal -- deck_monitors.py's and
    install_osk_kb_layout_rule's existing policy."""
    code, output = _runner(runner)(target, [LUAC, "-p", in_target_path])
    if code == 0:
        return True, ""
    detail = sanitize_text(output.strip(), limit=300)
    if code == 127 or "FileNotFoundError" in output or "no such file" in output.lower():
        return False, detail
    raise DeckInputError(
        f"the patched {in_target_path} is not valid Lua ({detail}). Refusing to install it: "
        "Hyprland discards a config it cannot parse WITHOUT logging a reason and with "
        "'hyprctl configerrors' still clean, so this would silently take the on-screen keyboard's "
        "above_lock rule AND the DPMS suppression down with it, and the OSK XKB block beside them"
    )


def install(target, rel: str, owner=None, runner=None) -> dict:
    """Splice the block into one ``input.lua``. Returns facts for the record.
    Staged inside the target, syntax-checked THERE, and only then moved into
    place -- identical ordering to deck_monitors.py's `install`."""
    path = Path(target) / rel
    in_target = "/" + rel

    before = ""
    source = "existing"
    warnings: list[str] = []
    if path.is_symlink():
        warnings.append(f"/{rel} was a symlink; it has been replaced with a regular file")
        path.unlink()
        before, source, seed_warnings = read_seed(target)
        warnings.extend(seed_warnings)
    elif path.exists():
        data = path.read_bytes()
        if len(data) > MAX_INPUT_LUA_BYTES:
            raise DeckInputError(f"/{rel} is {len(data)} bytes; refusing to parse it")
        before = data.decode("utf-8", "replace")
    else:
        before, source, seed_warnings = read_seed(target)
        warnings.extend(seed_warnings)

    text, replaced = splice(before, render_block())

    assert_outside_preserved(before, text, f"/{rel}")

    siblings = snapshot_siblings(target, rel)

    created: list[Path] = []
    parent = path.parent
    while not parent.exists():
        created.append(parent)
        parent = parent.parent
    path.parent.mkdir(parents=True, exist_ok=True)

    tmp = path.with_name(f".{path.name}.deck-tmp")
    tmp_in_target = str(Path(in_target).parent / tmp.name)
    try:
        tmp.write_text(text)
        os.chmod(tmp, INPUT_LUA_MODE)
        checked, detail = lua_syntax_check(target, tmp_in_target, runner)
        if not checked:
            warnings.append(
                f"'{LUAC} -p' could not be run in the target ({detail or 'not found'}), so the "
                f"patched /{rel} was NOT syntax-checked. A Lua syntax error here is silent: "
                "Hyprland discards the whole file and reports nothing anywhere"
            )
        os.replace(tmp, path)
    finally:
        if tmp.exists():
            tmp.unlink(missing_ok=True)

    assert_siblings_preserved(siblings, snapshot_siblings(target, rel), f"/{rel}")

    if owner is not None:
        for directory in created:
            _chown(directory, owner)
        _chown(path, owner)

    return {
        "replaced_existing_block": replaced,
        "seeded_from": source,
        "syntax_checked": checked,
        "warnings": warnings,
    }


def _chown(path: Path, owner) -> None:
    try:
        os.chown(path, owner.uid, owner.gid)
    except OSError as exc:
        raise DeckInputError(f"could not chown {path} to uid {owner.uid}: {exc}") from exc


# ---------------------------------------------------------------------------
# The disk readback -- reads the file back and proves the values, never trusts
# the write. Comment-stripped, same reasoning as deck_monitors.py's `verify`.
# ---------------------------------------------------------------------------


def verify(path: Path, label: str) -> dict:
    """Read the file back off disk and prove three facts: our misc DPMS pair
    reads false/false, our above_lock rule reads 2 for deck-osk, and the
    sentinel is the LAST statement.

    🔴 Points at the CREATED USER's copy, not skel's -- `/etc/skel` is copied at
    `useradd` time, phase 3 of 14, long before this step runs.
    """
    if not path.is_file():
        raise DeckInputError(
            f"{label} was not written ({path} does not exist). /etc/skel alone is TOO LATE for "
            "the account this image already created"
        )
    raw = path.read_text(errors="replace")

    dpms = misc_dpms_calls(raw)
    if not dpms:
        raise DeckInputError(
            f"{label} carries no ACTIVE misc.key_press_enables_dpms/mouse_move_enables_dpms pair "
            "in our call shape -- Hyprland's own generic wake-on-any-input is still enabled, so "
            "the QAM menu popup will still wake a blanked panel while the Deck is locked"
        )
    if len(dpms) > 1:
        raise DeckInputError(
            f"{label} carries {len(dpms)} active misc DPMS blocks in our shape. Which one "
            "Hyprland applies last is not something this project has measured for this exact "
            "shape, so it is asserted against rather than reasoned about"
        )
    key_press, mouse_move = dpms[0]
    if key_press != "false" or mouse_move != "false":
        raise DeckInputError(
            f"{label} reads back key_press_enables_dpms={key_press!r}, "
            f"mouse_move_enables_dpms={mouse_move!r}, expected both 'false'. Upstream ships both "
            "true; leaving either true means Hyprland's own generic wake-on-any-input can still "
            "fire from the QAM menu popup while the Deck is locked"
        )

    rules = above_lock_calls(raw)
    ours = [r for r in rules if r[0] == DECK_OSK_LAYER_NAMESPACE]
    if not ours:
        raise DeckInputError(
            f"{label} carries no ACTIVE above_lock layer_rule for namespace "
            f"'{DECK_OSK_LAYER_NAMESPACE}'. Without it the on-screen keyboard draws BENEATH a lock "
            "surface, and system.lock becomes an unanswerable password prompt on a device with no "
            "physical keyboard"
        )
    if len(ours) > 1:
        raise DeckInputError(
            f"{label} carries {len(ours)} active above_lock rules for '{DECK_OSK_LAYER_NAMESPACE}'"
        )
    above_lock = ours[0][1]
    if above_lock != str(ABOVE_LOCK):
        raise DeckInputError(
            f"{label} reads back above_lock={above_lock!r} for '{DECK_OSK_LAYER_NAMESPACE}', "
            f"expected {ABOVE_LOCK}. {ABOVE_LOCK} is what was hardware-verified on this panel "
            "2026-08-11 -- do not 'simplify' it to a boolean or a different integer without "
            "re-verifying against a live compositor"
        )

    block_text = our_block_text(raw)
    if block_text is None:
        raise DeckInputError(f"{label} does not carry our marker block ('{BEGIN}' .. '{END}') at all")
    tail = last_statement(block_text)
    if tail != f"{SENTINEL} = true":
        raise DeckInputError(
            f"{label}'s OWN block's last statement is {tail!r}, not '{SENTINEL} = true'. The "
            "sentinel proves OUR block ran to its own end; an assignment that is not last within "
            "our own markers proves only that our block parsed as far as itself (see "
            "`our_block_text`'s docstring for why this is scoped to our own block rather than the "
            "whole file, which install_osk_kb_layout_rule may also append to)"
        )

    return {
        "key_press_enables_dpms": key_press,
        "mouse_move_enables_dpms": mouse_move,
        "above_lock": above_lock,
        "namespace": DECK_OSK_LAYER_NAMESPACE,
    }


# ---------------------------------------------------------------------------
# The live readback -- optional, and almost always a WARN in production: a
# chroot install target has no live compositor. Modelled on
# src/deck-session.sh's `verify_osk_kb_layout`, the reference implementation
# this task names for the shape.
# ---------------------------------------------------------------------------


def _live_instance_signature(target, runtime_dir_rel: str) -> str | None:
    """The signature of a live Hyprland instance under `<target>/<runtime_dir_rel>/hypr`,
    or ``None``. Mirrors `verify_osk_kb_layout`'s own scan: a directory counts
    only if it holds a `.socket.sock` socket file."""
    hypr_dir = Path(target) / runtime_dir_rel.lstrip("/") / "hypr"
    if not hypr_dir.is_dir():
        return None
    sig = None
    for entry in sorted(hypr_dir.iterdir()):
        if not entry.is_dir():
            continue
        try:
            if (entry / ".socket.sock").is_socket():
                sig = entry.name
        except OSError:
            continue
    return sig


def _hyprctl(target, sig: str, runtime_dir_rel: str, args: list[str], runner=None) -> tuple[int, str]:
    argv = [
        "env",
        f"XDG_RUNTIME_DIR=/{runtime_dir_rel.lstrip('/')}",
        f"HYPRLAND_INSTANCE_SIGNATURE={sig}",
        "hyprctl",
        *args,
    ]
    return _runner(runner)(target, argv)


def verify_live(target, uid: int, runtime_dir_rel: str | None = None, runner=None) -> dict:
    """Three outcomes, mirroring `verify_osk_kb_layout` exactly:

      - no live Hyprland instance under the runtime dir -> WARN (loudly, via
        `error`) and return a `not-live` record. The rule is on disk and
        applies to the next session; claiming it works would be the lie.
      - live, sentinel gone                             -> raise `DeckInputError`.
      - live, wrong DPMS option value                    -> raise `DeckInputError`,
        naming which option and what it actually read.

    🔴 THE RUNTIME DIR IS A PARAMETER, deliberately, not `/run/user/<uid>`
    baked in -- a safety property, not a testing convenience. With the
    constant hardcoded, running this suite on any developer machine that
    happens to have a live Hyprland session would reload THAT person's real
    desktop. Production passes `None` and gets `run/user/<uid>` (relative to
    `target`); a suite passes a path under its own fake root.
    """
    if runtime_dir_rel is None:
        runtime_dir_rel = f"run/user/{uid}"

    sig = _live_instance_signature(target, runtime_dir_rel)
    if sig is None:
        msg = (
            f"no live Hyprland instance under /{runtime_dir_rel}/hypr, so the lock-wake/above_lock "
            "rule is installed but has NOT been observed working. It applies to the next session. "
            f"Check later with: HYPRLAND_INSTANCE_SIGNATURE=<sig> hyprctl eval 'if {SENTINEL} == "
            'nil then error("input.lua was discarded") end\''
        )
        error(f"Deck lock-wake/above_lock: {msg}")
        return {"status": "not-live", "detail": msg}

    code, out = _hyprctl(target, sig, runtime_dir_rel, ["reload", "config-only"], runner)
    if code != 0:
        raise DeckInputError(
            f"'hyprctl reload config-only' failed against instance {sig} "
            f"({sanitize_text(out.strip(), limit=300)}). The rule is written to disk but the "
            "running session has not picked it up, and this check will not call that success"
        )

    expr = f'if {SENTINEL} == nil then error("{SENTINEL} is nil -- input.lua was discarded") end'
    code, out = _hyprctl(target, sig, runtime_dir_rel, ["eval", expr], runner)
    if code != 0:
        raise DeckInputError(
            f"the running compositor does not have {SENTINEL} set ({sanitize_text(out.strip(), limit=300)}). "
            "That global is the LAST line of the block this step installed, so its absence means "
            "Hyprland discarded the whole file -- taking the above_lock rule and the DPMS "
            "suppression down with it"
        )

    for option in ("misc:key_press_enables_dpms", "misc:mouse_move_enables_dpms"):
        code, out = _hyprctl(target, sig, runtime_dir_rel, ["getoption", option], runner)
        if code != 0:
            raise DeckInputError(
                f"could not read 'hyprctl getoption {option}' from instance {sig}: "
                f"{sanitize_text(out.strip(), limit=300)}"
            )
        if "int: 0" not in out:
            raise DeckInputError(
                f"{option} does not read 'int: 0' in the live compositor "
                f"({sanitize_text(out.strip(), limit=300)}). Hyprland's own generic "
                "wake-on-any-input is still enabled, so the QAM menu popup will still wake a "
                "blanked panel while the Deck is locked"
            )

    info(
        f"Deck lock-wake/above_lock: verified live against instance {sig} -- {SENTINEL} is set "
        "and both misc:*_enables_dpms options read 0"
    )
    return {"status": "verified", "instance": sig}


# ---------------------------------------------------------------------------
# The step
# ---------------------------------------------------------------------------


def configure_lock_wake_dpms(ctx, runner=None) -> dict:
    """Write and verify the above_lock rule and the DPMS suppression on both
    surfaces (skel + the created user); return the record."""
    target = Path(ctx.target)
    record: dict = {
        "status": None,
        "namespace": DECK_OSK_LAYER_NAMESPACE,
        "above_lock": ABOVE_LOCK,
        "sentinel": SENTINEL,
        "skel": None,
        "user": None,
        "user_path": None,
        "seeded_from": None,
        "syntax_checked": None,
        "replaced_existing_block": None,
        "error": None,
        "warnings": [],
    }
    warnings: list[str] = record["warnings"]

    owner = None
    deferred = False
    try:
        user, user_warnings = resolve_target_user(ctx)
        owner = user
        warnings.extend(user_warnings)
        record["user"] = sanitize_text(user.name)
    except DeckUserDeferred as exc:
        deferred = True
        warnings.append(f"{exc}; writing /etc/skel only, which is what a later useradd copies")
    except DeckUserError as exc:
        record["status"] = "failed"
        record["error"] = sanitize_text(f"{type(exc).__name__}: {exc}", limit=400)
        error(f"Deck lock-wake/above_lock: {record['error']}")
        return record

    try:
        facts = install(target, INPUT_LUA_SKEL_REL, runner=runner)
        warnings.extend(facts["warnings"])
        record["skel"] = "/" + INPUT_LUA_SKEL_REL
        verify(target / INPUT_LUA_SKEL_REL, f"/{INPUT_LUA_SKEL_REL}")

        if deferred:
            record["status"] = "skel-only"
            record["seeded_from"] = facts["seeded_from"]
            record["syntax_checked"] = facts["syntax_checked"]
            info(
                f"Deck lock-wake/above_lock: above_lock={ABOVE_LOCK} for '{DECK_OSK_LAYER_NAMESPACE}', "
                f"DPMS-on-any-input disabled, in /{INPUT_LUA_SKEL_REL} only (deferred provisioning "
                "creates the account at first boot)"
            )
            for warning in warnings:
                error(f"Deck lock-wake/above_lock: {warning}")
            return record

        user_rel = owner.home.lstrip("/") + "/" + INPUT_LUA_REL
        facts = install(target, user_rel, owner=owner, runner=runner)
        warnings.extend(facts["warnings"])
        record["user_path"] = "/" + user_rel
        record["seeded_from"] = facts["seeded_from"]
        record["syntax_checked"] = facts["syntax_checked"]
        record["replaced_existing_block"] = facts["replaced_existing_block"]
        verify(target / user_rel, f"{owner.name}'s /{user_rel}")
    except (DeckInputError, OSError) as exc:
        record["status"] = "failed"
        record["error"] = sanitize_text(f"{type(exc).__name__}: {exc}", limit=400)
        error(f"Deck lock-wake/above_lock: {record['error']}")
        for warning in warnings:
            error(f"Deck lock-wake/above_lock: {warning}")
        return record

    record["status"] = "configured"
    info(
        f"Deck lock-wake/above_lock: above_lock={ABOVE_LOCK} for '{DECK_OSK_LAYER_NAMESPACE}', "
        f"key_press_enables_dpms=false, mouse_move_enables_dpms=false, in {record['user_path']} "
        f"(and /etc/skel), {SENTINEL} last"
    )
    for warning in warnings:
        error(f"Deck lock-wake/above_lock: {warning}")
    return record


def lock_wake_dpms_step(ctx) -> None:
    """``DeckStep`` entry point. Records under ``lock_wake_dpms``. No re-raise:
    `critical=False` -- see `deck_configure.deck_steps`'s wiring comment for
    the argument."""
    record_result(ctx.target, "lock_wake_dpms", configure_lock_wake_dpms(ctx))
