"""The desktop's panel rotation and scale -- T5 §5.2's fourth surface.

SHIPPED AS ``/usr/share/omarchy-iso/orchestrator/deck_monitors.py``. One
``configure_deck`` step -- ``desktop_rotation`` -- registered in
``deck_configure.deck_steps``. ``docs/tasks/T5-fork-plan.md`` §5.2,
``docs/PROGRESS.md`` §5.11, ``docs/findings/P22-deck-conformance-sweep.md`` §6.

🔴 THE FOUR SURFACES, AND WHY THE VALUES DISAGREE CORRECTLY
===========================================================

The Deck's panel is mounted rotated and **every surface corrects it with its own
mechanism and its own sign convention**. Measured on the panel, not inferred:

===============  =====================  ====================================
surface          value                  owner
===============  =====================  ====================================
Limine menu      ``90``                 ``deck_rotation.limine_rotation``
TTY console      ``fbcon=rotate:1``     ``deck_rotation.tty_rotation``
SDDM greeter     ``transform = 3``      ``src/deck-session.sh``
**Desktop**      ``transform = 3``      **this module**
===============  =====================  ====================================

⚠️ **Limine's ``interface_rotation`` and Hyprland's ``transform`` use OPPOSITE
sign conventions**, so ``90`` and ``3`` (=270°) describing one physical panel is
internally consistent. It looks like a bug at a glance and somebody will try to
"fix" it. ``deck_rotation.py`` says the same thing from the other side.

🔴 **Three rotation values in this project have been written down confidently and
found INVERTED when somebody finally looked at the screen** -- the desktop's
``1`` (session 15), Limine's ``270`` (2026-08-11), and the shipped patch that was
corrected from ``270`` to ``90`` on 2026-08-12. None was a typo; every one was an
inference from another surface's value. **Do not derive any of these from any
other.** The constants below carry their provenance for exactly that reason.

WHAT THIS STEP WRITES, AND WHY IT IS NOT SIMPLY A NEW FILE
==========================================================

🔴 **A user ``monitors.lua`` REPLACES the shipped default wholesale. There is no
merge.** Established from the pinned runtime, not assumed:

* ``~/.config/hypr/hyprland.lua`` sets
  ``package.path = $HOME/.config/?.lua;$OMARCHY_PATH/?.lua;…`` and then calls
  ``require("hypr.monitors")`` **(READ,** the fresh-install manifest's copy of
  that file**)**. Lua's ``require`` returns the **first** match on
  ``package.path``, so the home copy wins and nothing else is consulted.
* Omarchy's own copy is at ``/usr/share/omarchy/config/hypr/monitors.lua`` --
  under ``config/``, which is **not** on ``package.path``. It is a *seed*,
  copied into ``/etc/skel`` and into the home at account creation; it is never
  loaded from where the package put it. The loadable defaults are a different
  module, ``default.hypr.omarchy``, required separately.

This is the same relationship ``docs/tasks/T5-fork-plan.md`` §5.6 records for
``input.lua``, and it has the same consequence: **a file carrying only a monitor
line silently drops everything upstream put there** -- the ``hl.env("GDK_SCALE",
…)`` call and the ``output = ""`` catch-all rule that governs any external
display. So this step **splices a marker-delimited block into the existing
file** and preserves every byte outside its own markers, rather than writing a
file of its own.

⚠️ The rule names ``eDP-1`` and leaves the shipped ``output = ""`` catch-all
alone, so an external monitor keeps Omarchy's behaviour. Hyprland resolves a
monitor rule by preferring an exact output match over the empty-name catch-all,
and **upstream's own shipped file demonstrates the pattern**: it ships a
commented-out ``hl.monitor({ output = "DP-2", …, transform = 1 })`` example
directly beneath the catch-all, for precisely this purpose **(READ,** the
manifest's copy**)**. ``bin/omarchy-hyprland-monitor-clamshell`` parses this file
with the same model -- "per-output rules, catch-all ``output = \"\"``"
(``docs/findings/T9-delta-classification.md``).

🔴 IT SHARES A DIRECTORY WITH TWO OTHER PER-USER HYPRLAND FACTS
===============================================================

``~/.config/hypr/`` also holds ``input.lua``, which carries **§5.3's OSK XKB
per-device block** and **§5.6's ``above_lock = 2`` layer rule**. Neither is baked
in by this ISO yet, and the one that matters most is ``above_lock``: it is what
makes an on-screen keyboard visible over a lock surface on a device with no
physical keyboard.

So this module:

1. **Never opens ``input.lua``.** It writes one file.
2. Uses **its own markers**, distinct from ``src/deck-session.sh``'s
   ``OSK_KB_RULE_BEGIN``/``END`` pair and from ``deck_menu_lock``'s. Two writers
   sharing a marker is how each one comes to eat the other.
3. **Snapshots every other file in that directory before the write and asserts
   they are byte-identical afterwards** (``snapshot_siblings`` /
   ``assert_siblings_preserved``). A rule nothing asserts is a comment, and this
   one guards the affordance ``CLAUDE.md``'s controller-only constraint rests on.

🔴 A LUA SYNTAX ERROR DISCARDS THE WHOLE FILE, SILENTLY
=======================================================

Hyprland answers an unparseable Lua config by **discarding the entire file**,
without logging a reason, with ``hyprctl configerrors`` still clean
(``docs/PROGRESS.md`` §5.24, and §5.11's own history: a ``#`` marker in a Lua
file is what taught this project the behaviour). So:

*At install time* the staged file is handed to **``luac -p`` inside the target**
before it is installed, and a rejection is a refusal rather than a warning. The
target has it: ``lua`` is one of the 941 packages in the fresh-4.0 install
manifest **(READ)**. If it is somehow absent the step **warns loudly and
continues** -- exactly what ``install_osk_kb_layout_rule`` in
``src/deck-session.sh`` does, and for the same reason: the alternative is
refusing to rotate a desktop because a compiler is missing.

⚠️ A bracket-balance check is **not** a substitute and this module does not
pretend to offer one. ``# a comment`` in a Lua file is balanced, looks fine, and
is a syntax error. Only a Lua parser catches it.

*At run time* the block's last statement assigns a sentinel, and the recipe
written into the file is an **assertion**, never a readback::

    hyprctl eval 'if DECK_MONITORS_LUA_LOADED == nil then error("…") end'

exit 0 = loaded, exit 7 = discarded, with the message. ⚠️ ``hyprctl eval`` prints
``ok`` -- its own status, never the value -- and exits 0 for every expression
that does not raise, a name that has never existed included (measured on the Deck
2026-08-12). A readback therefore passes whether the file loaded or not, which is
the exact opposite of what a sentinel is for. ``verify_osk_kb_layout`` in
``src/deck-session.sh`` is the reference implementation of the working shape, and
``test/unit/test-hyprctl-syntax.sh`` scanner 3 fails the build if the broken form
is written down anywhere.

The sentinel is the **last statement in the file**, and that placement is
asserted after every write. Lua executes top to bottom: an error anywhere above
skips it, so its presence in a live compositor proves the whole file ran.

🔴 ``/etc/skel`` IS TOO LATE FOR THE USER THIS IMAGE CREATES
============================================================

``docs/tasks/T5-fork-plan.md`` §3 trap (a). ``useradd`` runs inside
``arch_install_system``, **phase 3 of 14**, long before this phase, and
``/etc/skel`` is copied at account creation. A ``monitors.lua`` written only to
skel produces a Deck whose *first and only* user comes up sideways -- and a check
that reads skel passes while the product is broken. Both surfaces are written;
**the created user's copy is the one verified.**

⚠️ WHY AN ABSENT SEED IS NOT A REFUSAL HERE, THOUGH IT IS FOR ``shell.json``
============================================================================

``deck_session_settings.patch_shell_json`` raises when the file is absent and the
packaged defaults are missing, because writing an idle-only ``shell.json`` would
strip the bar and an absent ``shell.json`` is harmless. **The trade is the other
way round for this file.** ``require("hypr.monitors")`` *errors* when the user has
no ``monitors.lua``, and a raising ``require`` takes ``hyprland.lua`` with it --
so "no file" is the worse outcome, not the safer one. This step therefore writes
a block-only file in that case and **says so loudly**. It is a state a real
install cannot reach: both ``/etc/skel`` and ``/usr/share/omarchy/config`` ship
the file.

``critical=False``, AND THE COUNTER-ARGUMENT FIRST
==================================================

*Against, and it is not a weak argument:* Desktop Mode is half of what this
project exists to deliver, and a Desktop Mode that comes up rotated 90° **and**
at a 640×400 logical resolution is not a cosmetic blemish -- it is close to
unusable, and the ``scale = "auto"`` half was found by using the machine rather
than by any check.

*For ``critical=False``, and this is what won:*

1. **It is a degradation, and the machine is still reachable.** The Deck boots,
   autologins and comes up in **Gaming Mode**, which is unaffected -- gamescope
   applies its own transform and never reads this file. Desktop Mode is still
   reachable by controller and, sideways, still usable enough to open a terminal
   and edit the file. Contrast ``deck_autologin``, the registry's one
   ``critical=True`` step, whose failure leaves a device with **no way in at
   all**; nothing here can produce that.
2. **Every input is upstream-owned and drifting.** The seed path, ``hl.monitor``'s
   signature, ``package.path``'s ordering, the presence of ``lua`` -- all
   Omarchy's or Hyprland's, read out of a *pinned* runtime that has already moved
   under this project once. ``deck_patches.py``'s argument 3 applies unchanged: a
   rule that turns "upstream moved a config file" into "the installer refuses to
   produce a machine" fails the ISO at the most expensive possible moment.
3. **Argument 5 of ``deck_patches.py``:** aborting turns a sideways desktop into a
   machine with no operating system.

⚠️ 🔴 **The honest weakness, stated rather than glossed.** A sideways *boot menu*
is on screen for three seconds; a sideways *desktop* is the whole of Desktop
Mode. And this step has no channel on the installed system that speaks: its only
report is ``/var/log/omarchy-deck-install.json`` plus the install log, which is
the same gap ``deck_rotation`` and ``deck_session_settings`` both record. A
first-boot unit is owed; it is not here because this slice does not own the ISO's
asset directory.

⚠️ **NOTHING IN THIS MODULE HAS BEEN THROUGH AN INSTALL.** The two values have
been seen on the panel, on a **hand-edited** file. That a spliced block reaches
the same place, is loaded by the same compositor, and survives
``bin/omarchy-hyprland-monitor-watch``'s reload loop and
``bin/omarchy-hyprland-monitor-clamshell``'s rewrite is INFERRED. The sentinel
assertion above is the check that settles it, and it needs a live compositor --
a [V] QEMU row and a T6 hardware row, neither of which this slice can run.
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
# The measured values
# ---------------------------------------------------------------------------

# The Deck's internal panel. Hyprland's own output name; the SDDM greeter's
# mirror in src/deck-session.sh uses the same one (PANEL_OUTPUT there).
PANEL_OUTPUT = "eDP-1"

# 🔴 3 (=270°), and it was 1 in this repo until somebody looked at the panel in
# session 15: 1 renders the desktop UPSIDE DOWN. Both were applied on this
# hardware and looked at (docs/PROGRESS.md §5.11).
#
# ⚠️ It disagrees with the Limine menu's `interface_rotation: 90` on purpose --
# opposite sign conventions, same physical panel. Do not "reconcile" them.
PANEL_TRANSFORM = 3
# Hyprland's transforms: 0-3 are 0/90/180/270, 4-7 the same with a flip.
VALID_TRANSFORMS = (0, 1, 2, 3, 4, 5, 6, 7)

# 🔴 NOT Omarchy's "auto". `auto` resolves to 2 on this panel and leaves a
# 640×400 logical desktop -- correct, and unusable. 1.25 divides 1280×800 evenly
# → 1024×640, with no fractional softness. Confirmed comfortable by the operator
# (docs/PROGRESS.md §5.11, docs/findings/P2-steam-integration-and-rotation.md
# R-24).
PANEL_SCALE = 1.25

# Omarchy ships GDK_SCALE=2, which suits a panel driven at scale 2. Against 1.25
# it renders GTK apps at roughly 2.5× and clips them, so the two go together
# (same R-24 measurement, same session, same screen).
#
# ⚠️ INFERRED, and deliberately the least load-bearing thing here: that a second
# `hl.env` for the same variable wins over the shipped one has NOT been measured.
# If it does not, GDK_SCALE stays 2 and only GTK apps are wrong -- the rotation
# and the scale above are unaffected either way. That bounded downside is the
# whole reason it is included rather than left for a later slice.
PANEL_GDK_SCALE = 1

# ---------------------------------------------------------------------------
# Where the file lives
# ---------------------------------------------------------------------------

# hyprland.lua's `require("hypr.monitors")` against a package.path of
# `$HOME/.config/?.lua`. Home-relative, never composed: deck_user reads the home
# out of /etc/passwd.
MONITORS_LUA_REL = ".config/hypr/monitors.lua"
MONITORS_LUA_SKEL_REL = f"etc/skel/{MONITORS_LUA_REL}"
# The SEED. Under `config/`, which is NOT on package.path -- Omarchy copies this
# into a home at account creation and never loads it from here.
MONITORS_LUA_DEFAULTS_REL = "usr/share/omarchy/config/hypr/monitors.lua"
MONITORS_LUA_MODE = 0o644

# The directory this file shares with input.lua, which carries §5.3's OSK XKB
# block and §5.6's `above_lock = 2` rule. Derived, not spelled out: the two must
# not be able to drift apart.
HYPR_DIR_REL = str(Path(MONITORS_LUA_REL).parent)

# 🔴 OURS ALONE. Different from src/deck-session.sh's
# "-- >>> deck-session.sh: on-screen keyboard XKB layout >>>" pair and from
# deck_menu_lock's, deliberately: several marker-delimited writers now operate on
# one user's dotfiles, every one of them preserves everything outside its own
# markers, and a shared marker is how each one comes to eat the other.
BEGIN = "-- >>> omarchy-deck: Steam Deck panel rotation and scale >>>"
END = "-- <<< omarchy-deck: Steam Deck panel rotation and scale <<<"

# The parse sentinel. Distinct from src/deck-session.sh's DECK_OSK_KB_LAYOUT and
# from §5.6's DECK_INPUT_LUA_LOADED: each file needs its own, or one file's
# sentinel vouches for another file that was discarded.
SENTINEL = "DECK_MONITORS_LUA_LOADED"

# The Lua compiler, run INSIDE the target. `-p` parses and writes nothing.
LUAC = "luac"

MAX_MONITORS_LUA_BYTES = 1024 * 1024


class DeckMonitorsError(Exception):
    """The desktop rotation could not be installed. Non-critical: see above."""


# ---------------------------------------------------------------------------
# Talking to the target
# ---------------------------------------------------------------------------


def chroot_command(target, argv) -> list[str]:
    """The exact command a target-side invocation runs.

    Its own function so "it runs inside the target" is assertable without a
    chroot, root, or a container -- ``deck_patches.chroot_command`` and
    ``deck_session_settings.chroot_command`` exist for the same reason. The
    compiler that checks the file must be the **target's**: a live-side ``luac``
    is the ISO's, and the ISO is not what boots.
    """
    return ["arch-chroot", str(target), *argv]


def run_in_target(target, argv) -> tuple[int, str]:
    """Run ``argv`` inside the target. Returns (exit code, combined output).

    ``check=False``: a non-zero exit is information this module turns into a
    record or a refusal, not an accident to raise on. A missing binary comes back
    as ``FileNotFoundError`` from ``arch-chroot`` itself and is caught by the
    caller, which is the "luac is not installed" branch.
    """
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
    """``None`` means the module attribute, looked up now.

    Not a default argument: a default binds the function object at *definition*
    time, so replacing the module attribute -- which is how the suite substitutes
    a real ``luac`` for ``arch-chroot luac`` -- would silently keep calling the
    real ``arch-chroot``. ``deck_session_settings._runner``'s reason exactly.
    """
    return run_in_target if runner is None else runner


# ---------------------------------------------------------------------------
# A Lua comment stripper, because a NAIVE READBACK PASSES ON A COMMENT
#
# 🔴 This is not tidiness. The file this step edits ships with a commented-out
#
#     -- hl.monitor({ output = "DP-2", …, scale = 1, transform = 1 })
#
# directly in it. A verification that grepped the raw text for `transform` would
# find upstream's EXAMPLE -- an inverted value, in a comment, that Hyprland never
# executes -- and either pass on it or fail on it, and both are wrong. Every
# assertion below runs against comment-stripped text.
# ---------------------------------------------------------------------------


def strip_lua_comments(text: str) -> str:
    """Blank out Lua comments, leaving strings and line structure intact.

    Handles ``--`` line comments, ``--[[ … ]]`` / ``--[=[ … ]=]`` long comments,
    short strings (with backslash escapes) and long-bracket strings. Newlines are
    preserved so positions in the result still line up with the original.

    Deliberately a blanker rather than a deleter: ``"a" .. --[[x]] "b"`` must not
    become ``"a" .."b"`` for a later scan, and keeping the geometry means a
    "which line" answer stays true.
    """
    out: list[str] = []
    i, n = 0, len(text)

    def long_bracket(start: int) -> tuple[int, int] | None:
        """``(level, index after the opening bracket)`` for ``[==[`` at *start*."""
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

        # A comment: `--`, then optionally a long bracket.
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

        # A long-bracket STRING. Not a comment: kept verbatim.
        opened = long_bracket(i)
        if opened is not None:
            level, body = opened
            close = "]" + "=" * level + "]"
            end = text.find(close, body)
            end = n if end < 0 else end + len(close)
            out.append(text[i:end])
            i = end
            continue

        # A short string. `--` inside one is not a comment.
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


# ---------------------------------------------------------------------------
# Reading `hl.monitor` rules back out of a file
# ---------------------------------------------------------------------------

_MONITOR_CALL_RE = re.compile(r"hl\s*\.\s*monitor\s*\(\s*\{")
# `key = value`, where a value is a quoted string, or anything up to the next
# comma or closing brace. An identifier is left as an identifier on purpose:
# upstream's catch-all writes `scale = omarchy_monitor_scale`, and reporting that
# as the literal string "auto" would be inventing a fact.
_FIELD_RE = re.compile(
    r"""(\w+)\s*=\s*(   "(?:[^"\\]|\\.)*"
                      | '(?:[^'\\]|\\.)*'
                      | [^,}]+ )""",
    re.X,
)


def _table_body(text: str, open_brace: int) -> tuple[str, int] | None:
    """The text between a ``{`` and its match, plus the index after the ``}``."""
    depth = 0
    for i in range(open_brace, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[open_brace + 1 : i], i + 1
    return None


def _unquote(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
        return value[1:-1]
    return value


def monitor_rules(text: str) -> list[dict[str, str]]:
    """Every ``hl.monitor({…})`` call in *text*, as ``{field: value}`` dicts.

    Comments are stripped first, so a commented-out rule -- which is what
    upstream ships -- is not reported. Values are returned as their source text
    with any quotes removed: ``"1.25"`` and ``omarchy_monitor_scale`` are both
    strings here, and the caller decides which it required.
    """
    stripped = strip_lua_comments(text)
    rules: list[dict[str, str]] = []
    pos = 0
    while True:
        match = _MONITOR_CALL_RE.search(stripped, pos)
        if not match:
            return rules
        body = _table_body(stripped, match.end() - 1)
        if body is None:
            # An unterminated table. Nothing to report, and luac -p is what
            # refuses it; walking past the call keeps this from looping.
            pos = match.end()
            continue
        fields, pos = body
        rules.append({k: _unquote(v) for k, v in _FIELD_RE.findall(fields)})


def last_statement(text: str) -> str:
    """The last non-blank line of the comment-stripped text.

    Its own function because "the sentinel is LAST" is the whole of the parse
    sentinel's meaning: Lua runs top to bottom, so an assignment that is not last
    proves only that the file parsed as far as itself.
    """
    lines = [line.strip() for line in strip_lua_comments(text).splitlines()]
    for line in reversed(lines):
        if line:
            return line
    return ""


# ---------------------------------------------------------------------------
# What gets written
# ---------------------------------------------------------------------------


def render_rule(
    output: str = PANEL_OUTPUT,
    scale: float = PANEL_SCALE,
    transform: int = PANEL_TRANSFORM,
) -> str:
    """The one line that rotates the desktop.

    Field order and spelling copied from ``src/deck-session.sh``'s greeter mirror
    and from ``docs/findings/P2-steam-integration-and-rotation.md`` R-24 -- the
    exact line that was applied on this hardware and looked at.
    """
    return (
        f'hl.monitor({{ output = "{output}", mode = "preferred", position = "auto", '
        f"scale = {scale}, transform = {transform} }})"
    )


def render_steam_window_rules() -> list[str]:
    """Steam's windows, re-sized to the logical desktop the lines above create.

    🔴 THESE LIVE HERE BECAUSE THEY ARE A CONSEQUENCE OF ``scale = 1.25``.
    ``scale`` and ``transform`` above are what make this panel a **1024x640**
    logical desktop, and 1024x640 is the entire reason these rules exist. Split
    them into a module of their own and the next person to "simplify" the scale
    breaks Steam's window with no line of code in between to warn them.

    WHAT IS BROKEN WITHOUT THEM
    ===========================
    Omarchy's own ``/usr/share/omarchy/default/hypr/apps/steam.lua`` ships::

        o.window({class="steam", title="Steam"},        {center=true, size={1100, 700}})
        o.window({class="steam", title="Friends List"}, {size={460, 800}})

    Those are desktop-monitor numbers. Against 1024x640 -- with 26 px reserved
    for Waybar, so 1024x614 usable -- ``1100x700`` is wider **and** taller than
    the whole desktop, and ``center`` therefore resolves to a NEGATIVE origin.
    Measured on the Deck 2026-08-16, Steam open in Desktop Mode::

        class 'steam' title 'Steam'        at [-38, -17] size [1100, 700]
        class 'steam' title 'Friends List' at [400,   0] size [ 460, 800]

    which is exactly ``(1024-1100)/2 = -38`` and ``26+(614-700)/2 = -17``. The
    operator sees a store page with no title bar and no Store/Library/Community
    tabs, because both are off the top of the screen.

    🔴 IT IS NOT STEAM MIS-SIZING ITSELF, AND THE CONTROL PROVES IT.
    The obvious theory -- "Steam sizes against the 1280x800 PHYSICAL surface" --
    is wrong, and 1100x700 looking plausible against 1280x800 is a coincidence.
    A ``foot`` terminal launched as ``foot --app-id=steam --title=Steam``, which
    is Wayland-native (not XWayland), has nothing to do with Steam and requests
    no such size, was measured at the IDENTICAL ``at [-38,-17] size [1100,700]``.
    The window rule is the whole cause. Steam is not involved.

    TWO MEASURED TRAPS IN THE SYNTAX
    ================================
    * **Percent strings do not work.** ``size = {"96%", "86%"}`` is silently
      ignored and the window keeps the size it asked for -- measured against a
      no-rule control that produced the identical geometry. Numbers work, and
      arithmetic expressions over ``monitor_w``/``monitor_h`` work. Expressions
      are used here so the rules follow the panel instead of restating it.
    * ``hyprctl eval`` answers ``ok`` to the broken form. It reports its own
      status, never the rule's. The only check that means anything is reading
      the resulting geometry back out of ``hyprctl -j clients``.
    """
    return [
        "-- Steam's windows, sized against the 1024x640 the two rules above",
        "-- create. Omarchy's default/hypr/apps/steam.lua forces 1100x700 and",
        "-- 460x800 -- both LARGER than this whole desktop, so `center` resolves",
        "-- to a negative origin and Steam's title bar and Store/Library tabs",
        "-- land off the top of the panel. Measured: at [-38,-17] size",
        "-- [1100x700], i.e. (1024-1100)/2 and 26+(614-700)/2 exactly.",
        "--",
        "-- NOT Steam mis-sizing itself: a `foot` terminal run as",
        "-- `foot --app-id=steam --title=Steam` -- Wayland-native, asking for no",
        "-- such size -- measures the IDENTICAL [-38,-17] 1100x700.",
        "--",
        "-- This file is required AFTER default.hypr.apps, and a later window",
        "-- rule wins for the same property, so these override Omarchy's",
        "-- without patching an upstream file.",
        "--",
        '-- 🔴 PERCENT STRINGS ("96%") DO NOT WORK -- measured: silently ignored,',
        "-- window keeps its requested size. Numbers and monitor_w/monitor_h",
        "-- expressions both work. `hyprctl eval` answers `ok` to the broken",
        "-- form, so only the geometry in `hyprctl -j clients` can tell you.",
        "",
        "-- Catch-all for the CLIENT. Anchored ^steam$ deliberately: unanchored",
        '-- "steam" also matches steam_app_* (a game under Proton in Desktop',
        "-- Mode) and steamwebhelper, and clamping a game is not this rule's",
        "-- business. This is what covers windows Omarchy has no rule for --",
        '-- the "Special Offers" popup asks for 564x664 against 614 px of usable',
        "-- height -- and any window a future Steam update invents. It is the",
        "-- part of this block least likely to rot: it names no title, no pixels.",
        'o.window("^steam$", { max_size = { "monitor_w", "monitor_h*0.95" } })',
        "",
        "-- The client window itself.",
        'o.window({ class = "steam", title = "Steam" }, {',
        "  center = true,",
        '  size = { "monitor_w*0.97", "monitor_h*0.90" },',
        "})",
        "",
        "-- The friends list opens on login and Omarchy sizes it 460x800 -- 160 px",
        "-- taller than the desktop. Give it a right-hand column instead of",
        "-- dropping it on top of the client.",
        "-- ⚠️ `move` may NOT use window_w here: measured, window_w resolves to",
        "-- the size the window ASKED for, not the size this rule then gives it,",
        "-- which puts the window in the wrong place by that difference.",
        'o.window({ class = "steam", title = "Friends List" }, {',
        '  size = { "monitor_w*0.42", "monitor_h*0.85" },',
        '  move = { "monitor_w*0.56", "monitor_h*0.06" },',
        "})",
    ]


def render_block() -> list[str]:
    """The marker-delimited block, as lines.

    The comments are not decoration. The next person to read this file is doing
    it on a Deck with no repository to hand, and the two things they must not do
    are "correct" 3 to match Limine's 90 and "simplify" 1.25 back to ``auto``.
    """
    return [
        BEGIN,
        "-- Installed by configure_deck (omarchy-deck ISO). docs/PROGRESS.md 5.11.",
        "--",
        "-- MEASURED on this panel, not inferred: transform = 3 (270 deg), NOT 1.",
        "-- Both were applied on this hardware and looked at, and 1 renders the",
        "-- desktop UPSIDE DOWN.",
        "--",
        "-- The Limine boot menu carries interface_rotation: 90 for this SAME",
        "-- panel. Limine and Hyprland use OPPOSITE sign conventions, so 90 and 3",
        "-- disagree correctly. Do NOT reconcile them.",
        "--",
        "-- scale = 1.25, NOT Omarchy's \"auto\": auto resolves to 2 here and leaves",
        "-- a 640x400 logical desktop -- correct, and unusable. 1.25 divides",
        "-- 1280x800 evenly -> 1024x640.",
        "--",
        "-- This rule names one output, so the catch-all rule above (output = \"\")",
        "-- still governs any external display. Gaming Mode is unaffected either",
        "-- way: gamescope applies its own transform and never reads this file.",
        render_rule(),
        "",
        "-- GDK_SCALE 2 -- what Omarchy ships, for a panel driven at scale 2 --",
        "-- renders GTK apps at roughly 2.5x against scale 1.25 and clips them.",
        "-- INFERRED: that this later call wins over the shipped one has not been",
        "-- measured. If it does not, GDK_SCALE stays 2 and only GTK apps are",
        "-- wrong; the two values above are unaffected.",
        f'hl.env("GDK_SCALE", "{PANEL_GDK_SCALE}")',
        "",
        *render_steam_window_rules(),
        "",
        "-- Deliberately the LAST statement in this file. Hyprland answers a Lua",
        "-- syntax error ANYWHERE above by discarding the WHOLE file, without",
        "-- logging a reason, with 'hyprctl configerrors' still clean -- so the",
        "-- only way to tell is to ask whether this ran. ASSERT it; never read it",
        "-- back:",
        "--",
        f"--   hyprctl eval 'if {SENTINEL} == nil "
        'then error("monitors.lua was discarded") end\'',
        "--",
        "-- exit 0 = loaded, exit 7 = discarded (the message is printed). eval",
        "-- reports its own status and NEVER a value, so a bare readback passes",
        "-- whether the file loaded or not. Over a remote shell, export",
        "-- HYPRLAND_INSTANCE_SIGNATURE first or the command never runs at all.",
        f"{SENTINEL} = true",
        END,
    ]


def splice(raw: str, block: list[str]) -> tuple[str, bool]:
    """``(new text, replaced an existing block)``. A splice, not a rewrite.

    Our block is removed if it is already there and **re-appended at the end**,
    which is what keeps the sentinel the last statement across a re-run. Every
    byte outside our own markers is preserved: this file belongs to the user, it
    carries upstream's ``hl.env`` and catch-all rule, and it may carry the user's
    own rules for external displays.

    Refuses a start marker with no end marker rather than guessing where the old
    block ended -- ``install_osk_kb_layout_rule`` and
    ``deck_rotation.patch_limine_header`` refuse the same shape.
    """
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
        raise DeckMonitorsError(
            "the monitors config carries our start marker with no end marker. Refusing to guess "
            "where the old block ended -- remove it by hand and re-run"
        )

    head = "\n".join(kept).rstrip("\n")
    out = ([head, ""] if head else []) + block
    return "\n".join(out).rstrip("\n") + "\n", replaced


def outside_our_block(text: str) -> str:
    """Everything that is not our block, verbatim.

    The comparison ``install`` makes before and after a write. "Nothing outside
    the markers changed" is the promise this module makes to ``input.lua``'s
    neighbours and to the user's own rules; comparing two strings is how it stops
    being a promise and becomes a check.
    """
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


def assert_outside_preserved(before: str, after: str, label: str) -> None:
    """Refuse a write that disturbed anything that is not ours.

    🔴 Its own function so the refusal is assertable with two strings and no
    target -- ``deck_rotation.assert_entries_preserved``'s reason, and it was
    earned here the same way: as an inline ``if`` inside ``install`` this guard
    could only be reached by first breaking ``splice``, so the writer and the
    check would have had to fail together to go red. That is precisely the pair
    of bugs a preservation assertion exists to catch, and a mutation run proved
    the inline form survived being deleted.
    """
    if outside_our_block(before) == outside_our_block(after):
        return
    raise DeckMonitorsError(
        f"the splice changed content OUTSIDE our own markers in {label}. Everything else in this "
        "file belongs to the user and to Omarchy -- the GDK_SCALE call, the catch-all monitor "
        "rule that governs external displays, another tool's marker-delimited block -- and a "
        "rewrite silently drops it. A user monitors.lua REPLACES the shipped default wholesale; "
        "nothing merges it back"
    )


# ---------------------------------------------------------------------------
# The sibling files in ~/.config/hypr
# ---------------------------------------------------------------------------


def snapshot_siblings(target, rel: str) -> dict[str, bytes]:
    """Every other regular file in the same directory, by name.

    🔴 ``input.lua`` is the one that matters: §5.3's OSK XKB block and §5.6's
    ``above_lock = 2`` rule live in it, and ``above_lock`` is what makes a lock
    screen answerable on a handheld with no keyboard. This module does not open
    that file -- and this snapshot is what turns "does not" into something a test
    can fail on.
    """
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
    raise DeckMonitorsError(
        f"writing {label} changed {', '.join(changed)} in the same directory. This step writes ONE "
        "file. input.lua next to it carries the on-screen keyboard's XKB block and the "
        "'above_lock = 2' layer rule, and losing that rule makes a lock screen unanswerable on a "
        "device with no physical keyboard"
    )


# ---------------------------------------------------------------------------
# The write
# ---------------------------------------------------------------------------


def read_seed(target) -> tuple[str, str, list[str]]:
    """``(text, where it came from, warnings)`` for a file that does not exist yet."""
    warnings: list[str] = []
    seed = Path(target) / MONITORS_LUA_DEFAULTS_REL
    if seed.is_file():
        data = seed.read_bytes()
        if len(data) > MAX_MONITORS_LUA_BYTES:
            raise DeckMonitorsError(
                f"/{MONITORS_LUA_DEFAULTS_REL} is {len(data)} bytes; refusing to parse it"
            )
        return data.decode("utf-8", "replace"), "defaults", warnings
    warnings.append(
        f"neither the file nor /{MONITORS_LUA_DEFAULTS_REL} exists on the target, so the block "
        "below is the WHOLE file: Omarchy's GDK_SCALE call and its catch-all monitor rule for "
        "external displays are not in it. Written anyway rather than skipped -- "
        "require('hypr.monitors') ERRORS when the file is missing, and a raising require takes "
        "the whole Hyprland config with it, so no file is worse than a partial one"
    )
    return "", "empty", warnings


def lua_syntax_check(target, in_target_path: str, runner=None) -> tuple[bool, str]:
    """``(checked, detail)`` from ``luac -p`` **inside the target**.

    ``checked=False`` means no compiler was available, which is a warning and not
    a refusal -- ``install_osk_kb_layout_rule``'s behaviour, and the same
    argument: refusing to rotate a desktop because a compiler is missing trades a
    working machine for a tidy check. A non-zero exit from a compiler that DID
    run is a refusal, and the caller makes it one.
    """
    code, output = _runner(runner)(target, [LUAC, "-p", in_target_path])
    if code == 0:
        return True, ""
    detail = sanitize_text(output.strip(), limit=300)
    if code == 127 or "FileNotFoundError" in output or "no such file" in output.lower():
        return False, detail
    raise DeckMonitorsError(
        f"the patched {in_target_path} is not valid Lua ({detail}). Refusing to install it: "
        "Hyprland discards a config it cannot parse WITHOUT logging a reason and with "
        "'hyprctl configerrors' still clean, so this would silently leave the desktop sideways -- "
        "and it would take the rest of this file with it"
    )


def install(target, rel: str, owner=None, runner=None) -> dict:
    """Splice the block into one ``monitors.lua``. Returns facts for the record.

    Staged inside the target, syntax-checked **there**, and only then moved into
    place with ``os.replace``. Staging first is not ceremony: it is the only
    ordering in which a file that fails ``luac -p`` never becomes the file
    Hyprland reads.
    """
    path = Path(target) / rel
    in_target = "/" + rel

    before = ""
    source = "existing"
    warnings: list[str] = []
    if path.is_symlink():
        # A symlink here would make us write through to whatever it names, which
        # is not this user's file. Replaced, and reported.
        warnings.append(f"/{rel} was a symlink; it has been replaced with a regular file")
        path.unlink()
        before, source, seed_warnings = read_seed(target)
        warnings.extend(seed_warnings)
    elif path.exists():
        data = path.read_bytes()
        if len(data) > MAX_MONITORS_LUA_BYTES:
            raise DeckMonitorsError(f"/{rel} is {len(data)} bytes; refusing to parse it")
        before = data.decode("utf-8", "replace")
    else:
        before, source, seed_warnings = read_seed(target)
        warnings.extend(seed_warnings)

    text, replaced = splice(before, render_block())

    # 🔴 The promise, checked rather than asserted in prose.
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
        os.chmod(tmp, MONITORS_LUA_MODE)
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
        # Every directory this step created, plus the file. A root-owned
        # ~/.config/hypr is a home the desktop cannot write to -- and it is the
        # directory input.lua has to be writable in too.
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
    """A failure raises rather than being swallowed: a file the desktop user
    cannot read is the same outcome as no file."""
    try:
        os.chown(path, owner.uid, owner.gid)
    except OSError as exc:
        raise DeckMonitorsError(f"could not chown {path} to uid {owner.uid}: {exc}") from exc


# ---------------------------------------------------------------------------
# The readback
# ---------------------------------------------------------------------------


def verify(path: Path, label: str) -> dict:
    """Read the file back off the disk and prove all four facts.

    🔴 The caller points this at the **created user's** copy, not at skel's. §3
    trap (a): a check that reads only ``/etc/skel`` is the canonical
    passes-for-the-wrong-reason failure for this task.

    Everything here runs against **comment-stripped** text. The shipped file
    contains a commented-out rule with ``transform = 1`` in it, so a raw scan
    would be reading upstream's example rather than the compositor's input.
    """
    if not path.is_file():
        raise DeckMonitorsError(
            f"{label} was not written ({path} does not exist). /etc/skel alone is TOO LATE for "
            "the account this image already created -- it is copied at useradd time, which was "
            "phase 3 of 14"
        )
    raw = path.read_text(errors="replace")

    ours = [r for r in monitor_rules(raw) if r.get("output") == PANEL_OUTPUT]
    if not ours:
        commented = PANEL_OUTPUT in raw
        raise DeckMonitorsError(
            f"{label} carries no ACTIVE hl.monitor rule for {PANEL_OUTPUT}"
            + (
                " -- the only mention of it is inside a comment, which Hyprland never executes"
                if commented
                else ""
            )
        )
    if len(ours) > 1:
        raise DeckMonitorsError(
            f"{label} carries {len(ours)} active hl.monitor rules for {PANEL_OUTPUT}. Which one "
            "Hyprland applies is not something this project has measured, so it is asserted "
            "against rather than reasoned about"
        )
    rule = ours[0]

    transform = rule.get("transform")
    if transform != str(PANEL_TRANSFORM):
        raise DeckMonitorsError(
            f"{label} reads back transform={transform!r}, expected {PANEL_TRANSFORM}. "
            f"{PANEL_TRANSFORM} is 270 degrees and was seen upright on this panel; 1 renders the "
            "desktop UPSIDE DOWN, and it is the value this project recorded confidently and had "
            "to correct. It disagrees with Limine's interface_rotation: 90 CORRECTLY -- opposite "
            "sign conventions"
        )

    scale = rule.get("scale")
    if scale != str(PANEL_SCALE):
        extra = (
            " 'auto' resolves to 2 on this panel and leaves a 640x400 logical desktop."
            if scale in ("auto", "omarchy_monitor_scale")
            else ""
        )
        raise DeckMonitorsError(
            f"{label} reads back scale={scale!r}, expected {PANEL_SCALE}.{extra}"
        )

    tail = last_statement(raw)
    if tail != f"{SENTINEL} = true":
        raise DeckMonitorsError(
            f"{label}'s last statement is {tail!r}, not '{SENTINEL} = true'. The sentinel proves "
            "the file RAN, and Lua runs top to bottom -- an assignment that is not last proves "
            "only that the file parsed as far as itself"
        )

    return {
        "output": rule.get("output"),
        "transform": transform,
        "scale": scale,
        "monitor_rules": len(monitor_rules(raw)),
    }


# ---------------------------------------------------------------------------
# The step
# ---------------------------------------------------------------------------


def configure_desktop_rotation(ctx, runner=None) -> dict:
    """Write and verify the desktop rotation on both surfaces; return the record."""
    target = Path(ctx.target)
    record: dict = {
        "status": None,
        "output": PANEL_OUTPUT,
        "transform": PANEL_TRANSFORM,
        "scale": PANEL_SCALE,
        "gdk_scale": PANEL_GDK_SCALE,
        "sentinel": SENTINEL,
        "skel": None,
        "user": None,
        "user_path": None,
        "seeded_from": None,
        "syntax_checked": None,
        "monitor_rules": None,
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
        # The one case where skel alone is right rather than too late: no account
        # exists yet, and omarchy-provision-owner's useradd copies skel when it
        # creates one at first boot.
        deferred = True
        warnings.append(f"{exc}; writing /etc/skel only, which is what a later useradd copies")
    except DeckUserError as exc:
        record["status"] = "failed"
        record["error"] = sanitize_text(f"{type(exc).__name__}: {exc}", limit=400)
        error(f"Deck desktop rotation: {record['error']}")
        return record

    try:
        if PANEL_TRANSFORM not in VALID_TRANSFORMS:
            raise DeckMonitorsError(
                f"transform {PANEL_TRANSFORM} is not one of Hyprland's {VALID_TRANSFORMS}"
            )
        if PANEL_SCALE <= 0:
            raise DeckMonitorsError(f"scale {PANEL_SCALE} is not a usable monitor scale")

        # Skel first: it is the cheap one and it needs no account, so a missing
        # seed or a broken splice fails before anything touches a home.
        facts = install(target, MONITORS_LUA_SKEL_REL, runner=runner)
        warnings.extend(facts["warnings"])
        record["skel"] = "/" + MONITORS_LUA_SKEL_REL
        verify(target / MONITORS_LUA_SKEL_REL, f"/{MONITORS_LUA_SKEL_REL}")

        if deferred:
            record["status"] = "skel-only"
            record["seeded_from"] = facts["seeded_from"]
            record["syntax_checked"] = facts["syntax_checked"]
            info(
                f"Deck desktop rotation: {PANEL_OUTPUT} transform={PANEL_TRANSFORM} "
                f"scale={PANEL_SCALE} in /{MONITORS_LUA_SKEL_REL} only (deferred provisioning "
                "creates the account at first boot)"
            )
            for warning in warnings:
                error(f"Deck desktop rotation: {warning}")
            return record

        user_rel = owner.home.lstrip("/") + "/" + MONITORS_LUA_REL
        facts = install(target, user_rel, owner=owner, runner=runner)
        warnings.extend(facts["warnings"])
        record["user_path"] = "/" + user_rel
        record["seeded_from"] = facts["seeded_from"]
        record["syntax_checked"] = facts["syntax_checked"]
        record["replaced_existing_block"] = facts["replaced_existing_block"]
        proof = verify(target / user_rel, f"{owner.name}'s /{user_rel}")
        record["monitor_rules"] = proof["monitor_rules"]
    except (DeckMonitorsError, OSError) as exc:
        record["status"] = "failed"
        record["error"] = sanitize_text(f"{type(exc).__name__}: {exc}", limit=400)
        error(f"Deck desktop rotation: {record['error']}")
        for warning in warnings:
            error(f"Deck desktop rotation: {warning}")
        return record

    record["status"] = "configured"
    info(
        f"Deck desktop rotation: {PANEL_OUTPUT} transform={PANEL_TRANSFORM} scale={PANEL_SCALE} "
        f"in {record['user_path']} (and /etc/skel), {record['monitor_rules']} monitor rule(s) kept, "
        f"{SENTINEL} last. transform 3 disagrees with Limine's 90 CORRECTLY -- opposite sign "
        "conventions, same panel"
    )
    for warning in warnings:
        error(f"Deck desktop rotation: {warning}")
    return record


def desktop_rotation_step(ctx) -> None:
    """``DeckStep`` entry point. Records under ``desktop_rotation``.

    No re-raise: ``critical=False``, and the record is the report -- throwing it
    away in order to signal a failure would destroy the thing the install log
    exists for.
    """
    record_result(ctx.target, "desktop_rotation", configure_desktop_rotation(ctx))
