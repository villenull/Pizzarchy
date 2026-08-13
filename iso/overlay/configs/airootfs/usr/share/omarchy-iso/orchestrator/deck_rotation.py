"""The two rotation surfaces that live in the boot chain.

SHIPPED AS ``/usr/share/omarchy-iso/orchestrator/deck_rotation.py``. Two
``configure_deck`` steps -- ``limine_rotation`` and ``tty_rotation`` --
registered in ``deck_configure.deck_steps``. ``docs/tasks/T5-fork-plan.md``
§5.2, ``docs/PROGRESS.md`` §5.11.

🔴 THE FOUR VALUES, AND WHY TWO OF THEM LOOK LIKE A CONTRADICTION
=================================================================

The Deck's panel is mounted rotated and **every surface corrects it with its own
mechanism and its own sign convention**. Measured on the panel, not inferred
(``docs/findings/P22-deck-conformance-sweep.md`` §6):

===============  =====================  ====================================
surface          value                  owner
===============  =====================  ====================================
Limine menu      ``90``                 this module (+ T12's template patch)
TTY console      ``fbcon=rotate:1``     this module
SDDM greeter     ``transform = 3``      ``src/deck-session.sh``
Desktop          ``transform = 3``      ``deck_monitors.py`` (``desktop_rotation`` step)
===============  =====================  ====================================

⚠️ **Limine's ``interface_rotation`` and Hyprland's ``transform`` use OPPOSITE
sign conventions**, so ``90`` and ``3`` (=270°) describing one physical panel is
internally consistent. It looks like a bug at a glance and somebody will try to
"fix" it, which is why it is stated here as well as in the sweep.

🔴 **Two rotation values in this project have been written down confidently and
found to be 180° WRONG when somebody finally looked at the screen** -- the
desktop's ``1`` (session 15) and Limine's ``270`` (2026-08-11). Neither was a
typo; both were inferences from another surface's value. **Do not derive any of
these four from any other.** ``interface_rotation: 90`` and ``fbcon=rotate:1``
are here because they were rendered and looked at, and the constants below carry
that provenance so the next reader does not have to trust this paragraph.

⚠️ ``fbcon=rotate:1`` is the one of the four with **no** "looked at" annotation
against the TTY itself (``docs/findings/P22-deck-conformance-sweep.md`` §6,
closing note). It is on the Deck, it is in ``/proc/cmdline``, and nobody has
switched to a VT to see which way up it is. That is a T6 hardware row, not
something this module can settle.

WHAT THIS MODULE DELIBERATELY DOES NOT DO
=========================================

**The desktop's ``monitors.lua`` (``transform = 3``, ``scale = 1.25``).**
✅ Baked in as of 2026-08-12 by ``deck_monitors.py``'s ``desktop_rotation``
step -- deliberately its **own** module and not folded into whatever writes
``input.lua``, because ``monitors.lua`` and ``input.lua`` are separate files
with separate Hyprland ``require``s; there is no shared write to coordinate.
``test/unit/test-deck-monitors.py`` (146 checks) fails if this regresses, so
the second half of the old warning here -- "no test in this repo fails
because of it" -- is no longer true either.

**Still true, and still load-bearing:** ``~/.config/hypr/input.lua`` --
§5.3's OSK XKB per-device block and §5.6's ``above_lock = 2`` layer rule --
is **not** baked in anywhere yet. It is a *different* per-user Hyprland file
from ``monitors.lua``, and whatever eventually writes it must not clobber
``deck_monitors.py``'s marker-delimited block in the sibling file. That
guard already exists in this repo, in the other direction: see
``deck_monitors.snapshot_siblings`` / ``assert_siblings_preserved``, which
is the reference for what an ``input.lua`` writer owes ``monitors.lua`` in
return.

🔴 WHY ``/boot/limine.conf`` IS A STEP AT ALL, WHEN T12 ALREADY PATCHES A LIMINE CONFIG
======================================================================================

There are **two** Limine configs and they are destroyed by different events.

``/usr/share/omarchy/default/limine/limine.conf``
    the packaged **template**. Owned by ``omarchy-dev``; a package upgrade
    reverts an edit. T12's ``0020-limine-interface-rotation.patch`` plus the
    ``omarchy-deck`` ALPM hook own it. **Not this module's business.**

``<ESP>/limine.conf``
    the live config. **Not package-owned.** Upstream's ``_write_limine_defaults``
    copies the template to it during ``arch_install_system`` -- **phase 3, long
    before this phase** **(READ:** ``phases_impl.py``, the ``shutil.copy2`` at
    the end of that function**)**. So the copy on the ESP is a snapshot of the
    template *as it was at phase 3*, and T12's applier -- which runs LAST in
    this very registry -- patches the template afterwards and cannot reach back
    into a copy that was already taken. Nothing else installs the rotation
    there. That is this step.

``finalize_limine_boot`` then runs ``limine-update``, which regenerates the entry
blocks in that same file. 🔴 **Measured 2026-08-11: the header SURVIVES.**
``limine-update`` was run on the Deck (it reported ``Updated: /boot/limine.conf``
and rebuilt both UKIs) and ``interface_rotation: 90`` was still present
afterwards. The header is user-owned; the tool rewrites only the entry blocks.
That measurement is the only reason a header write is a viable strategy at all,
so this step **asserts the entry region it did not touch is byte-identical**
rather than trusting it.

⚠️ What the header does **not** survive is ``omarchy refresh limine``, which
``mv``s the file aside and copies the template over it **(READ:**
``bin/omarchy-refresh-limine``**)**. That is exactly why T12 patches the template
*as well*: the two mechanisms cover two different destruction events, and
neither one covers both. ``test/unit/test-deck-rotation.py`` models both events.

🔴 **NEVER COMPOSE ``/boot/limine.conf``.** The ESP is wherever the installer
mounted the EFI partition: ``_installer_esp_mount`` returns that mountpoint and
``_write_limine_defaults`` stamps it into ``/etc/default/limine`` as
``ESP_PATH=``, and both ``finalize_limine_boot`` and ``validate_boot`` resolve
the config through that setting rather than through a literal ``/boot``. So this
module resolves it the same way, by the same precedence, for exactly the reason
``deck_user`` reads ``/etc/passwd`` instead of composing ``/home/<name>``: this
project has already paid once for a check that read the place a file was
*supposed* to be.

``critical=False`` FOR BOTH, ARGUED
===================================

Both steps touch the boot chain, which is the one place this project's
constraints are strictest, so the argument is made rather than assumed.

*Against, and it is real:* a malformed ``limine.conf`` or a malformed
``KERNEL_CMDLINE[default]+=`` line does not degrade a Deck, it stops it booting.

*Why that argues for validation and not for ``critical=True``:* the danger is in
the **write**, not in the **skip**. A step that writes nothing leaves the boot
chain exactly as upstream produced it. So the safety here comes from refusing to
write something this module cannot re-read and re-parse -- which is what both
steps do, against upstream's own parser regexes -- and never from aborting the
install afterwards.

*And the failure is a genuine degradation.* ``interface_rotation`` rotates
"the menu/editor/console only -- it does not affect the booted OS"
(``docs/PROGRESS.md`` §5.11). A Deck whose Limine menu or TTY is sideways still
boots, still autologins, still reaches Gaming Mode by controller. Contrast
``deck_autologin``, which is ``critical=True`` because its failure leaves a
device with **no way in at all**; nothing here can produce that.

*Argument 5 of ``deck_patches.py`` applies unchanged:* aborting turns a sideways
boot menu into a machine with no operating system, at the most expensive
possible moment.

⚠️ **The honest weakness, stated rather than glossed.** ``deck_session_settings``
already records that these steps' only report is
``/var/log/omarchy-deck-install.json`` plus the install log -- there is no failed
unit on the installed system to speak up. For the TTY that stings slightly more
than usual: the console is one of the few surfaces a *stranded* user reaches,
which is the case where nobody can read a JSON file either. A first-boot unit is
owed; it is not here because this slice does not own the ISO's asset directory.
"""

from __future__ import annotations

import os
import re
from pathlib import Path

from .deck_configure import record_result, sanitize_text
from .ui import error, info

# ---------------------------------------------------------------------------
# The two measured values
# ---------------------------------------------------------------------------

# 🔴 90, and it was 270 in this repo until somebody looked at the panel on
# 2026-08-11: 270 rendered the menu UPSIDE DOWN. Limine accepts 0/90/180/270 and
# needs >= v10; the Deck runs 12.5.2.
#
# ⚠️ It disagrees with the desktop's `transform = 3` on purpose -- opposite sign
# conventions, same physical panel. Do not "reconcile" them.
INTERFACE_ROTATION = 90
VALID_INTERFACE_ROTATIONS = (0, 90, 180, 270)
ROTATION_KEY = "interface_rotation"

# `fbcon=rotate:1`, measured present in /proc/cmdline and in every entry of the
# Deck's limine.conf. fbcon/rotate takes 0-3 (quarter-turns counter-clockwise).
FBCON_ROTATE = 1
VALID_FBCON_ROTATIONS = (0, 1, 2, 3)
FBCON_TOKEN = f"fbcon=rotate:{FBCON_ROTATE}"

# ---------------------------------------------------------------------------
# Where upstream keeps the boot chain
#
# Every one of these five paths is copied from `phases_impl.py`. They are
# duplicated facts about upstream, in the sense docs/findings/T9-coupling-
# inventory.md §8.1 means, so test/unit/test-deck-rotation.py scrapes them back
# out of iso/upstream and fails if they have drifted.
# ---------------------------------------------------------------------------

LIMINE_DEFAULTS_REL = "etc/default/limine"
# Read in this order by `_limine_combined_config_text`; LAST WINS, and
# /etc/default/limine has the highest priority of all -- which is precisely why
# the fbcon drop-in below uses `+=` and not `=`.
LIMINE_CONFIG_SOURCES = (
    "usr/share/limine-entry-tool.d",  # glob *.conf, sorted
    "etc/limine-entry-tool.conf",  # a single legacy file
    "etc/limine-entry-tool.d",  # glob *.conf, sorted
)
LIMINE_ENTRY_TOOL_D_REL = "etc/limine-entry-tool.d"
ESP_PATH_SETTING = "ESP_PATH"
DEFAULT_ESP_PATH = "/boot"
LIMINE_CONF_NAME = "limine.conf"

# 🔴 Upstream's own two parsers, transcribed. `_limine_setting` takes the LAST
# match; `_limine_kernel_cmdline` collects EVERY `+=` and joins them, which is
# what makes a drop-in additive rather than a replacement.
KERNEL_CMDLINE_RE = re.compile(r"^\s*KERNEL_CMDLINE\[default\]\+=\s*(.*?)\s*$")

# The drop-in. `50-` sorts before upstream's own `99-omarchy-provisioning-
# unlock.conf` and after nothing that matters; the glob is sorted and every
# match accumulates, so the position is not load-bearing -- but the name is the
# one already on the operator's Deck, and two names for one file is how this
# project has been bitten before.
FBCON_DROPIN_REL = f"{LIMINE_ENTRY_TOOL_D_REL}/50-deck-fbcon-rotation.conf"
FBCON_DROPIN_MODE = 0o644

# A kernel cmdline token. Deliberately strict: this string is concatenated into
# the command line the machine boots with, and there is no second chance.
SAFE_CMDLINE_TOKEN_RE = re.compile(r"\A[A-Za-z0-9][A-Za-z0-9=:.,_/+-]*\Z")

# Marker-delimited, like `stage_menu_row`'s splice and `install_osk_kb_layout_
# rule`'s: everything outside the markers is preserved byte for byte, and a
# re-run replaces the block rather than appending a second one.
LIMINE_BEGIN = "# >>> omarchy-deck: Steam Deck panel rotation >>>"
LIMINE_END = "# <<< omarchy-deck: Steam Deck panel rotation <<<"

# A Limine config line that starts with '/' opens a menu entry ('//' opens a
# nested one); ':' is the pre-v4 sigil for the same thing. No GLOBAL starts with
# either, so the first such line is the header/entries boundary. That boundary
# is the whole safety story of the write below: everything from it onwards
# belongs to limine-entry-tool and is not ours to move.
ENTRY_SIGILS = ("/", ":")

MAX_LIMINE_CONF_BYTES = 4 * 1024 * 1024


class DeckRotationError(Exception):
    """A rotation could not be installed. Non-critical: see the docstring."""


# ---------------------------------------------------------------------------
# Resolving the ESP the way upstream resolves it
# ---------------------------------------------------------------------------


def strip_shell_quotes(value: str) -> str:
    """``_strip_shell_quotes`` from ``phases_impl.py``, transcribed."""
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
        return value[1:-1]
    return value


def combined_limine_config(target) -> str:
    """``_limine_combined_config_text``, transcribed.

    The concatenation limine-entry-tool actually sees. Its own function so
    "the drop-in reaches the cmdline" is assertable without a chroot, a
    bootloader or root -- the same seam ``deck_patches.chroot_command`` exists
    for, and for the same reason.
    """
    root = Path(target)
    chunks: list[str] = []
    for rel in LIMINE_CONFIG_SOURCES:
        path = root / rel
        if path.is_dir():
            for conf in sorted(path.glob("*.conf")):
                chunks.append(conf.read_text(errors="replace"))
        elif path.is_file():
            chunks.append(path.read_text(errors="replace"))

    defaults = root / LIMINE_DEFAULTS_REL
    if not defaults.is_file():
        raise DeckRotationError(
            f"/{LIMINE_DEFAULTS_REL} does not exist on the target. The installer writes it in "
            "phase 3 and finalize_limine_boot refuses to run without it, so this is not a "
            "situation this step can paper over -- and CLAUDE.md's 'Limine only' rule means "
            "there is no other bootloader to fall back to"
        )
    # Highest priority, and therefore last.
    chunks.append(defaults.read_text(errors="replace"))
    return "\n".join(chunks)


def limine_setting(config_text: str, name: str, fallback: str | None = None) -> str | None:
    """``_limine_setting``, transcribed. **Last match wins.**"""
    pattern = re.compile(rf"^\s*{re.escape(name)}\s*=\s*(.*?)\s*$")
    value = fallback
    for line in config_text.splitlines():
        match = pattern.match(line)
        if match:
            value = strip_shell_quotes(match.group(1))
    return value


def limine_kernel_cmdline(config_text: str) -> str:
    """``_limine_kernel_cmdline``, transcribed. Every ``+=``, joined."""
    parts: list[str] = []
    for line in config_text.splitlines():
        match = KERNEL_CMDLINE_RE.match(line)
        if match:
            parts.append(strip_shell_quotes(match.group(1)).strip())
    return " ".join(part for part in parts if part).strip()


def resolve_limine_conf(target) -> tuple[Path, str]:
    """``(<target>/<esp>/limine.conf, <esp>)``. Never composed as ``/boot``.

    Raises rather than guessing. A rotation written to the wrong file is the
    §3-trap-(a) shape: the file exists, the check passes, and the machine boots
    from a different one.
    """
    esp = limine_setting(combined_limine_config(target), ESP_PATH_SETTING, DEFAULT_ESP_PATH)
    esp = (esp or DEFAULT_ESP_PATH).strip()
    if not esp.startswith("/"):
        raise DeckRotationError(
            f"{ESP_PATH_SETTING} in /{LIMINE_DEFAULTS_REL} is '{sanitize_text(esp)}', which is not "
            "an absolute path. Refusing to guess where the ESP is"
        )
    esp_root = Path(target) / esp.lstrip("/")
    if not esp_root.is_dir():
        raise DeckRotationError(
            f"{ESP_PATH_SETTING} says the ESP is at {esp}, but that is not a directory on the "
            "target. finalize_limine_boot raises on the same condition a phase later"
        )
    return esp_root / LIMINE_CONF_NAME, esp


# ---------------------------------------------------------------------------
# The Limine menu rotation
# ---------------------------------------------------------------------------


def render_limine_block(rotation: int = INTERFACE_ROTATION) -> list[str]:
    """The marker-delimited header block, as lines.

    The comment is not decoration. The next person to read this file is doing it
    on a Deck at 3am with no repository to hand, and the one thing they must not
    do is "correct" 90 to match the desktop's 3.
    """
    return [
        LIMINE_BEGIN,
        "# Installed by configure_deck (omarchy-deck ISO). docs/PROGRESS.md 5.11.",
        "#",
        "# MEASURED 2026-08-11 on the panel: 270 renders this menu UPSIDE DOWN;",
        f"# {rotation} is correct. The desktop and the SDDM greeter use transform = 3,",
        "# which is 270 degrees -- Limine and Hyprland use OPPOSITE sign",
        "# conventions, so the two values disagree correctly. Do not reconcile them.",
        "#",
        "# This affects the boot menu, editor and console only; it does not touch",
        "# the booted OS. Everything outside these two markers is preserved.",
        f"{ROTATION_KEY}: {rotation}",
        LIMINE_END,
    ]


def split_header(lines: list[str]) -> int:
    """Index of the first entry line -- the header/entries boundary.

    ``len(lines)`` when the file is all header, which is exactly what
    ``_write_limine_defaults`` leaves behind: at our phase the ESP copy is a
    verbatim copy of the 20-line template and ``limine-update`` has not run yet,
    so there are usually no entries at all. The split still matters, because a
    re-run *after* ``finalize_limine_boot`` sees a file full of them.
    """
    for i, line in enumerate(lines):
        stripped = line.lstrip()
        if stripped[:1] in ENTRY_SIGILS:
            return i
    return len(lines)


def patch_limine_header(raw: str, rotation: int = INTERFACE_ROTATION) -> tuple[str, list[str]]:
    """``(new text, warnings)``. Pure, so the destruction test needs no ESP.

    Rules, in order:

    1. The entry region -- everything from the first entry line on -- is
       untouched. It belongs to ``limine-entry-tool``.
    2. A previous block of ours is removed and replaced, so a re-run is a
       rewrite rather than a second copy.
    3. Any *other* ``interface_rotation:`` in the header is removed and
       **reported**. That is not tidying: it is how a disagreement with the
       packaged template surfaces. If T12's patch ever writes a different value
       into the template, the ESP copy taken in phase 3 carries it, and this is
       the line that says so out loud instead of leaving two writers fighting.
    """
    warnings: list[str] = []
    lines = raw.splitlines()
    boundary = split_header(lines)
    header, entries = lines[:boundary], lines[boundary:]

    kept: list[str] = []
    skipping = False
    saw_block = False
    for line in header:
        bare = line.strip()
        if bare == LIMINE_BEGIN:
            skipping, saw_block = True, True
            continue
        if skipping:
            if bare == LIMINE_END:
                skipping = False
            continue
        match = re.match(rf"^\s*{ROTATION_KEY}\s*:\s*(\S*)", line)
        if match:
            found = match.group(1)
            if found != str(rotation):
                warnings.append(
                    f"the config on the ESP already carried '{ROTATION_KEY}: "
                    f"{sanitize_text(found)}', not {rotation}. It was a copy of "
                    "/usr/share/omarchy/default/limine/limine.conf taken in phase 3, so a value "
                    "here that is not ours means the PACKAGED TEMPLATE disagrees with this step "
                    "-- and the template is what wins after 'omarchy refresh limine'. One of the "
                    "two is 180 degrees wrong"
                )
            continue
        kept.append(line)

    if skipping:
        raise DeckRotationError(
            "the Limine config carries our start marker with no end marker. Refusing to guess "
            "where the old block ended -- this is the boot chain"
        )

    out = kept + render_limine_block(rotation) + entries
    text = "\n".join(out).rstrip("\n") + "\n"
    if saw_block:
        warnings.append("replaced an existing omarchy-deck rotation block (re-run)")
    return text, warnings


def read_rotation(raw: str) -> list[str]:
    """Every ``interface_rotation:`` value in the HEADER, in order.

    Header only, and that is the point of reading it back this way: a value that
    somehow landed inside an entry block is not a global and Limine would not
    apply it, so a check that counted it would pass while the menu stayed
    sideways.
    """
    lines = raw.splitlines()
    header = lines[: split_header(lines)]
    found: list[str] = []
    for line in header:
        match = re.match(rf"^\s*{ROTATION_KEY}\s*:\s*(\S*)", line)
        if match:
            found.append(match.group(1))
    return found


def entry_region(raw: str) -> str:
    lines = raw.splitlines()
    return "\n".join(lines[split_header(lines) :])


def assert_entries_preserved(before: str, after: str, label: str) -> None:
    """Refuse a write that disturbed an entry block.

    🔴 Its own function so the refusal is assertable with two strings, no ESP and
    no bootloader -- ``deck_autologin.find_session``'s reason. A guard that can
    only be exercised by first breaking the writer is a guard nothing tests: the
    writer and the check would then have to fail together to go red, which is
    exactly the pair of bugs a boot-chain assertion exists to catch.
    """
    if before == after:
        return
    raise DeckRotationError(
        f"{label}'s ENTRY blocks changed. This step writes globals in the header and must never "
        "touch an entry: those are limine-entry-tool's, they carry the UKI paths and their "
        "blake2b hashes, and a rewritten one is a machine that does not boot"
    )


def read_back(path: Path) -> str:
    """Read a file this module has just written.

    A named module function, not an inline ``path.read_text()``, and not a
    default argument -- ``deck_session_settings._runner``'s reason exactly. It is
    the seam ``test/unit/test-deck-rotation.py`` substitutes to prove the
    verification below consults the **file on disk** rather than the string that
    was handed to the writer. Those two are identical on a healthy filesystem and
    differ on the one this project actually ships to: a vfat ESP whose mount
    options this repo has already been bitten by (``CLAUDE.md``'s
    already-diagnosed item 5).
    """
    return path.read_text(errors="replace")


def write_atomically(path: Path, text: str, mode: int | None) -> None:
    """Temp file in the same directory, then ``os.replace``.

    Not ceremony. A torn write to ``limine.conf`` is a machine that does not
    boot, and ``deck_configure.record_result`` already establishes the pattern.

    ``mode=None`` skips the chmod, which is what the ESP gets: it is vfat, its
    permissions come from the mount's ``fmask``/``dmask`` (``CLAUDE.md``'s
    already-diagnosed item 5), and a chmod there either does nothing or fails
    for a reason that has nothing to do with the rotation.
    """
    tmp = path.with_name(f".{path.name}.deck-tmp")
    try:
        tmp.write_text(text)
        if mode is not None:
            os.chmod(tmp, mode)
        os.replace(tmp, path)
    finally:
        if tmp.exists():
            tmp.unlink(missing_ok=True)


def configure_limine_rotation(ctx) -> dict:
    """Write and verify ``interface_rotation`` on the ESP; return the record."""
    record: dict = {
        "status": None,
        "rotation": INTERFACE_ROTATION,
        "esp_path": None,
        "config": None,
        "entries_preserved": None,
        "error": None,
        "warnings": [],
    }
    warnings: list[str] = record["warnings"]

    try:
        if INTERFACE_ROTATION not in VALID_INTERFACE_ROTATIONS:
            raise DeckRotationError(
                f"{INTERFACE_ROTATION} is not one of Limine's {VALID_INTERFACE_ROTATIONS}"
            )

        path, esp = resolve_limine_conf(ctx.target)
        record["esp_path"] = esp
        record["config"] = f"{esp.rstrip('/')}/{LIMINE_CONF_NAME}"
        if not path.is_file():
            raise DeckRotationError(
                f"{record['config']} does not exist on the target. The installer copies the "
                "packaged template there in phase 3 (_write_limine_defaults), and "
                "finalize_limine_boot raises on its absence a phase later, so an absent file "
                "here is a broken install rather than a missing rotation"
            )
        data = path.read_bytes()
        if len(data) > MAX_LIMINE_CONF_BYTES:
            raise DeckRotationError(f"{record['config']} is {len(data)} bytes; refusing to parse it")
        raw = data.decode("utf-8", "replace")

        before = entry_region(raw)
        text, patch_warnings = patch_limine_header(raw)
        warnings.extend(patch_warnings)
        write_atomically(path, text, mode=None)

        # Read the file BACK OFF THE DISK, never the string we just built. The
        # ESP is vfat and mounted with masks this project has already been bitten
        # by; "the write happened" is a separate fact from "the write is what we
        # rendered".
        after_raw = read_back(path)
        found = read_rotation(after_raw)
        if found != [str(INTERFACE_ROTATION)]:
            raise DeckRotationError(
                f"{record['config']} reads back {ROTATION_KEY} as {found!r}, expected exactly "
                f"['{INTERFACE_ROTATION}']. Limine's behaviour on a duplicated global is not "
                "something this project has measured, so it is asserted against rather than "
                "reasoned about"
            )
        after = entry_region(after_raw)
        record["entries_preserved"] = after == before
        assert_entries_preserved(before, after, record["config"])
    except (DeckRotationError, OSError) as exc:
        record["status"] = "failed"
        record["error"] = sanitize_text(f"{type(exc).__name__}: {exc}", limit=400)
        error(f"Deck Limine rotation: {record['error']}")
        for warning in warnings:
            error(f"Deck Limine rotation: {warning}")
        return record

    record["status"] = "configured"
    info(
        f"Deck Limine rotation: {ROTATION_KEY}: {INTERFACE_ROTATION} in {record['config']} "
        "(entry blocks byte-identical). Survives limine-update; NOT 'omarchy refresh limine', "
        "which the packaged template covers"
    )
    for warning in warnings:
        error(f"Deck Limine rotation: {warning}")
    return record


def limine_rotation_step(ctx) -> None:
    """``DeckStep`` entry point. Records under ``limine_rotation``.

    No re-raise: ``critical=False``, and the record is the report.
    """
    record_result(ctx.target, "limine_rotation", configure_limine_rotation(ctx))


# ---------------------------------------------------------------------------
# The TTY rotation
# ---------------------------------------------------------------------------


def render_fbcon_dropin(token: str = FBCON_TOKEN) -> str:
    """The drop-in's exact text.

    🔴 ``+=``, NEVER ``=``. ``_limine_combined_config_text`` puts
    ``/etc/default/limine`` LAST and upstream's own comment calls it "highest
    priority", and ``_limine_kernel_cmdline`` only collects ``+=`` lines at all
    -- so a ``=`` here contributes nothing and a ``=`` there would drop the
    ``root=`` the machine boots with.
    """
    return (
        "# Installed by configure_deck (omarchy-deck ISO). docs/PROGRESS.md 5.11.\n"
        "#\n"
        "# The Steam Deck's panel is mounted rotated and the kernel console is not\n"
        "# corrected by any kernel this project ships (fbcon/rotate defaults to 0 on\n"
        "# stock Arch and on Neptune alike), so the TTY reads sideways without this.\n"
        "#\n"
        "# A DROP-IN, deliberately, and not an edit to /etc/default/limine or to\n"
        "# omarchy-defaults.conf: /etc/default/limine has the highest priority in\n"
        "# limine-entry-tool and would override drop-ins rather than add to them, and\n"
        "# omarchy-defaults.conf belongs to Omarchy and is lost to a package upgrade.\n"
        "# /etc/limine-entry-tool.d/*.conf is the documented seam -- upstream's own\n"
        "# hardware quirks (install/hardware/intel/fred.sh and four siblings) and the\n"
        "# installer's own provisioning unlock both use exactly this file and this\n"
        "# syntax.\n"
        "#\n"
        "# '+=' is required: every KERNEL_CMDLINE[default]+= line in the whole\n"
        "# concatenation is collected and joined. '=' contributes nothing.\n"
        f'KERNEL_CMDLINE[default]+=" {token}"\n'
    )


def configure_tty_rotation(ctx) -> dict:
    """Install and verify the fbcon drop-in; return the record."""
    target = Path(ctx.target)
    record: dict = {
        "status": None,
        "fbcon_rotate": FBCON_ROTATE,
        "dropin": None,
        "cmdline_token": None,
        "error": None,
        "warnings": [],
    }
    warnings: list[str] = record["warnings"]

    try:
        if FBCON_ROTATE not in VALID_FBCON_ROTATIONS:
            raise DeckRotationError(
                f"fbcon rotate {FBCON_ROTATE} is not one of {VALID_FBCON_ROTATIONS}"
            )
        if not SAFE_CMDLINE_TOKEN_RE.match(FBCON_TOKEN):
            # Cheap, and it guards the one string in this module that is
            # concatenated straight onto the kernel command line.
            raise DeckRotationError(
                f"'{sanitize_text(FBCON_TOKEN)}' is not a safe kernel cmdline token"
            )

        # Prove the seam exists before writing into it: /etc/default/limine must
        # be there or the whole drop-in mechanism is inert (and
        # finalize_limine_boot fails a phase later anyway).
        before = combined_limine_config(target)
        baseline = limine_kernel_cmdline(before)
        if "root=" not in baseline:
            warnings.append(
                "the cmdline assembled from /etc/default/limine and its drop-ins has no 'root=' "
                "before this step runs; something upstream of us is already wrong"
            )
        for other in re.findall(r"fbcon=rotate:(\d+)", before):
            if other != str(FBCON_ROTATE):
                warnings.append(
                    f"another Limine drop-in already sets fbcon=rotate:{sanitize_text(other)}; "
                    "the last one collected wins and two writers are fighting over the console"
                )

        path = target / FBCON_DROPIN_REL
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.is_symlink():
            path.unlink()
        write_atomically(path, render_fbcon_dropin(), mode=FBCON_DROPIN_MODE)
        record["dropin"] = "/" + FBCON_DROPIN_REL

        # 🔴 The verification that matters: re-assemble the concatenation the way
        # limine-entry-tool does and run UPSTREAM'S OWN collector over it. A
        # grep for the token in our own file would pass on a drop-in written
        # with '=' instead of '+=', which contributes nothing at all.
        after = limine_kernel_cmdline(combined_limine_config(target))
        record["cmdline_token"] = FBCON_TOKEN
        if FBCON_TOKEN not in after.split():
            raise DeckRotationError(
                f"'{FBCON_TOKEN}' does not appear in the cmdline assembled from "
                f"/{LIMINE_DEFAULTS_REL} and its drop-ins after writing /{FBCON_DROPIN_REL}. The "
                "file is on disk and limine-entry-tool would ignore it"
            )
        if "root=" in baseline and "root=" not in after:
            raise DeckRotationError(
                "writing the drop-in removed 'root=' from the assembled cmdline. That is a "
                "machine that does not boot; the drop-in must ADD to the cmdline, never replace it"
            )
    except (DeckRotationError, OSError) as exc:
        record["status"] = "failed"
        record["error"] = sanitize_text(f"{type(exc).__name__}: {exc}", limit=400)
        error(f"Deck TTY rotation: {record['error']}")
        for warning in warnings:
            error(f"Deck TTY rotation: {warning}")
        return record

    record["status"] = "configured"
    info(
        f"Deck TTY rotation: {FBCON_TOKEN} via /{FBCON_DROPIN_REL}, confirmed present in the "
        "cmdline limine-entry-tool will assemble"
    )
    for warning in warnings:
        error(f"Deck TTY rotation: {warning}")
    return record


def tty_rotation_step(ctx) -> None:
    """``DeckStep`` entry point. Records under ``tty_rotation``."""
    record_result(ctx.target, "tty_rotation", configure_tty_rotation(ctx))
