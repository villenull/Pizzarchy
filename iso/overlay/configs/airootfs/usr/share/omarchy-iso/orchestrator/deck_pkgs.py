"""Install ``deck-fetch.packages`` onto the target, over the network, at install
time.

SHIPPED AS ``/usr/share/omarchy-iso/orchestrator/deck_pkgs.py``. The ``pkgs``
step registered in ``deck_configure.deck_steps``.

🔴 WHY THIS FILE EXISTS: IT IS THE MISSING CONSUMER
====================================================

``docs/findings/P32-steam-never-installed.md``, found on the first hardware
first-boot this project ever produced. ``steam`` and ``steamdeck-dsp`` were put
in a third package list, ``configs/deck/deck-fetch.packages``, deliberately kept
out of both the pacstrap list and the offline mirror because
``docs/tasks/T5-fork-plan.md`` §4.1 decided they would be **fetched at install
time, not bundled** -- and the fetch step was never written. Grepping the whole
repo, the only reader was ``deck-nvidia-dry-run.sh``, which *asks about* the
list at build time and installs nothing. The list was, functionally, a comment.

The result on hardware: no ``/usr/lib/steam``, ``steam-launcher.service``
hitting its start limit, gamescope running with nothing to display, and a black
panel through two complete boots -- while the install's own record reported
**eleven steps, all green** and the QEMU install test scored 18/18. Nothing in
either tier asked "is Steam installed?". This module is that question's answer,
and the verification at the end of ``fetch_packages`` is deliberately an
**outcome** assertion (is the package on the target now?) rather than a step
assertion (did pacman exit 0?), because a step assertion is exactly what was
already green on a Deck that could not reach Gaming Mode.

WHAT IS STILL FETCHED, AND WHAT STOPPED BEING FETCHED
=====================================================

Only ``steam``. ``steamdeck-dsp`` moved into the offline mirror on 2026-08-15
(operator decision): it is firmware, a first boot with tinny speakers is not a
degradation anyone can act on, and it now has the same redistribution posture
``linux-firmware-neptune`` always had. ``steam`` stays online because bundling
the client raises a Steam Subscriber Agreement question this project has not
taken on, and because the installer's S0 screen already discloses that it is
downloaded from Valve during setup.

**The list is still parsed, not hard-coded.** A module that installed a literal
``steam`` would re-create the original defect the other way round -- the file
would once again be a comment -- and ``deck-fetch.packages`` carries the
build-time NVIDIA guard's question as well, so the two must not drift.

DECISION 1 -- ``critical=False``
================================

Registry entry: ``DeckStep("pkgs", deck_pkgs.fetch_packages_step, critical=False)``.

*For ``critical=True``:* this is the step whose failure looks worst. No Steam is
a black screen on a handheld, which reads to a user as a dead device, and it is
the P1 that produced this file.

*For ``critical=False`` -- and this is what won:*

1. **§4.1 explicitly allows the degradation and bans only the silence.** "The
   offline install must still succeed; it is the silence that is banned, not
   the degradation." An install that reached this step has partitioned, LUKS'd,
   pacstrapped ~1200 packages and written a bootloader. Aborting it because a
   network download failed leaves the operator with **no machine at all**, on a
   device whose only recovery path is another full install from a controller.
2. **The failure is recoverable in place and the fix is one command.** Measured
   on hardware: ``pacman -S --needed steam`` inside the target, 34 packages, no
   kernel or bootloader involvement, and Gaming Mode rendered on the next boot.
   A Deck that boots into Desktop Mode with no Steam can install Steam. A Deck
   that was never installed cannot.
3. **The silence is closed by three channels, not by aborting.** The record in
   ``/var/log/omarchy-deck-install.json`` (with the pacman error tail), the
   ``error()`` lines in the install log, and
   ``omarchy-deck-steam-first-boot.service`` -- which says so on the installed
   machine and **exits non-zero so ``systemctl --failed`` carries the state**.
   Aborting adds no information; it only destroys a working system.

⚠️ ``critical=False`` is not "failures are tolerated". Nothing here is
swallowed. As in ``deck_wifi.py`` and ``deck_patches.py``, an expected failure
is a **field in the record, not an exception** -- throwing the record away in
order to signal a failure would destroy the report that §4.1 requirement (ii)
asks for. ``critical`` governs only an *unexpected* exception escaping this
module, and the same argument applies to it.

DECISION 2 -- THE NETWORK IS NOT PROBED HERE
============================================

``deck_wifi.carry_wifi_step`` runs earlier in the same registry and has already
recorded what happened on the installer's Wi-Fi screen, in the vocabulary S1
defined (``connected|skipped|no-hardware|iwd-failed``). This module **reads that
record** rather than pinging anything: a second, differently-shaped network
probe would be a second thing to disagree with, and a probe that says "up" while
pacman cannot reach a mirror is worse than no probe.

But the record is used to *classify*, never to *decide*. The install is still
attempted whatever it says, because a Deck on a dock's ethernet legitimately
has ``status=skipped``, and a step that refused to try would silently deny that
machine its Steam on the strength of an answer about the radio.

DECISION 3 -- ``pacman -Sy`` AND ``pacman -S``, AS TWO CALLS
============================================================

Not ``pacman -Sy <names>`` in one transaction. Two calls, because they fail for
completely different reasons and the record has to be able to tell a support
reader which one happened: a failed sync is "this machine had no network", a
failed install is "the network was there and the transaction did not work".
Collapsing them makes both look like the same opaque non-zero exit.

⚠️ **This is a partial upgrade, and that is deliberate and bounded.** ``-Sy``
followed by ``-S`` installs against a database newer than the offline mirror the
target was pacstrapped from. The alternative -- ``-Syu`` -- would download and
replace an unbounded part of a system that has not booted yet, kernel included,
in the middle of an install. The bounded risk was measured on hardware:
``pacman -Sy`` then ``pacman -S --needed steam`` inside the target pulled 34
packages and produced a working Gaming Mode. If the mirror pin and the ISO ever
drift far enough for this to break, it breaks loudly here, with pacman's own
message in the record.

IDEMPOTENCE
===========

``CLAUDE.md`` requires re-runnable scripts. Every package is queried on the
target with ``pacman -Qq`` **first**: if nothing is missing, this step runs no
sync, no transaction, and no network at all, and records
``already_present: true``. ``--needed`` is passed as well, so even the path that
does run a transaction cannot reinstall something.
"""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

from .deck_configure import record_result, sanitize_text
from .ui import error, info

# --- the live side ----------------------------------------------------------

LIVE_ROOT = Path("/")

# 🔴 Put here by builder/build-iso.sh (iso/overlay/patches/deck-packages.patch),
# which COPIES configs/deck/deck-fetch.packages into
# airootfs/usr/share/omarchy-iso/. That copy is half of the P3.2 fix: without it
# the list exists only inside the build container -- `configs/deck/` lands in
# the archiso PROFILE, and mkarchiso only puts `airootfs/` into the booted root
# -- so this module would have had nothing to read even if it had existed.
# Changing this name means changing the `cp` in that patch.
FETCH_LIST_REL = "usr/share/omarchy-iso/deck-fetch.packages"
FETCH_LIST_ABS = "/" + FETCH_LIST_REL

# Caps on the list. It is ours and it is tiny; these exist so a corrupted or
# pathological file cannot be turned into a package transaction by a root
# process, and so nothing unbounded reaches a world-readable log.
MAX_LIST_BYTES = 64 * 1024
MAX_LIST_ENTRIES = 32

# A package name pacman will accept. Deliberately strict: this text becomes
# argv for a root `pacman -S` inside the target, so anything outside the
# character set Arch package names actually use is refused rather than passed
# on. `/` is excluded too -- a repo-qualified name here would resolve against
# whichever repo happened to be configured on the TARGET, which is not a
# decision this file gets to make (deck-mirror.packages is where qualification
# belongs, and it is resolved at build time against known repos).
NAME_ALLOWED = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@._+-")

# --- the target side --------------------------------------------------------

# Bounds, not deadlines. They exist so a wedged mirror connection cannot hang
# an installer on a device with no terminal; both are far longer than the
# measured real numbers (the hardware repair's 34-package steam transaction
# took well under a minute on a LAN).
SYNC_TIMEOUT_SECS = 300
INSTALL_TIMEOUT_SECS = 3600
QUERY_TIMEOUT_SECS = 120

# 🔴 The outcome assertion docs/findings/P32-steam-never-installed.md asks for
# by name: "at minimum that `steam` is installed and
# /usr/lib/steam/bootstraplinux_ubuntu12_32.tar.xz exists". That tarball is what
# steam-launcher unpacks on first run; its absence is the exact line the
# hardware journal carried ("tar: ...: Cannot open: No such file or directory")
# before three restarts hit the unit's start limit. Checked, recorded, and
# checked again by the first-boot unit on the installed system.
STEAM_PACKAGE = "steam"
STEAM_BOOTSTRAP_REL = "usr/lib/steam/bootstraplinux_ubuntu12_32.tar.xz"

# Read by the first-boot unit. key=value, no secrets, world-readable -- the same
# discipline as deck_wifi.py's wifi-carry file, and it is PARSED by the script,
# never sourced.
STATE_REL = "var/lib/omarchy-deck/fetch-packages"
STATE_MODE = 0o644

# Assets the ISO carries, copied onto the target by this step.
# 🔴 NOT named plain "ASSET_DIR", and the reason is a build guard rather than
# taste. test/unit/test-iso-build.sh derives the on-ISO asset directory by
# grepping the overlay orchestrator for a single line-anchored definition of
# that exact name, and FAILS when it finds two -- "more than one means it was
# duplicated, which is the drift the single definition exists to prevent".
# deck_wifi.py holds the name. This is the same directory with a different
# pair of assets in it, and this name says which pair.
#
# ⚠️ The cost: that guard checks deck_wifi's two assets ship in the overlay
# and does NOT check these two. §7 of test/unit/test-deck-pkgs.py stages them
# from the real overlay directory, so their absence is red there instead --
# but generalising the guard to every module that names an asset directory
# would be strictly better, and it is not this file's to change.
FIRST_BOOT_ASSET_DIR = Path("/usr/share/omarchy-iso/deck")
FIRST_BOOT_UNIT = "omarchy-deck-steam-first-boot.service"
FIRST_BOOT_SCRIPT_ASSET = "deck-steam-first-boot.sh"
FIRST_BOOT_SCRIPT_REL = "usr/local/bin/omarchy-deck-steam-first-boot"
FIRST_BOOT_UNIT_REL = f"etc/systemd/system/{FIRST_BOOT_UNIT}"
FIRST_BOOT_WANTS_REL = f"etc/systemd/system/multi-user.target.wants/{FIRST_BOOT_UNIT}"
FIRST_BOOT_SCRIPT_MODE = 0o755
FIRST_BOOT_UNIT_MODE = 0o644

# deck_wifi's vocabulary (S1's, via src/deck-form.sh). These three mean the
# installer's Wi-Fi screen ended with no network; `connected` means it had one,
# and anything else -- including a missing record -- means we do not know.
# Used ONLY to classify a failure, never to skip the attempt (decision 2).
NO_NETWORK_WIFI_STATUSES = ("skipped", "no-hardware", "iwd-failed")

# Caps on pacman's output before it lands in the world-readable install log.
MAX_OUTPUT_LINES = 12
MAX_LINE_CHARS = 200

# The record's `status` vocabulary. Four values, no overlap:
#   installed             every entry is on the target (this includes the
#                         re-run case, with already_present: true)
#   skipped-no-network    the sync failed AND deck_wifi recorded that the
#                         installer's Wi-Fi screen produced no network
#   failed                anything else went wrong: sync failed with a network
#                         we believed in, the transaction failed, or pacman
#                         exited 0 and the package is still not there
#   error                 written by deck_configure's registry if this module
#                         raises something unforeseen
STATUS_INSTALLED = "installed"
STATUS_NO_NETWORK = "skipped-no-network"
STATUS_FAILED = "failed"


class DeckPkgsError(Exception):
    """A step-level failure. Non-critical: the install continues (§4.1), the
    outcome is recorded, and the first-boot unit tells the user."""


# ---------------------------------------------------------------------------
# Reading the list -- pure, so the suite can drive every shape of it
# ---------------------------------------------------------------------------


def parse_package_list(text: str) -> tuple[list[str], list[str]]:
    """Parse a ``*.packages`` file. Returns (names, warnings).

    Same comment/blank convention as every consumer in ``builder/build-iso.sh``
    (``grep -hv '^#\\|^$'``), so one file cannot mean two different sets of
    packages depending on who read it.

    A malformed name is **dropped with a warning, not tolerated silently and
    not fatal**: this text becomes argv for a root ``pacman -S``, and a single
    bad entry must not be able to take the whole (correct) rest of the list
    down with it -- pacman aborts an entire transaction on one unresolvable
    target, so passing it through would cost the user Steam because someone
    left a stray character in a comment-adjacent line.
    """
    names: list[str] = []
    warnings: list[str] = []
    for raw in text.splitlines():
        entry = raw.strip()
        if not entry or entry.startswith("#"):
            continue
        if len(names) >= MAX_LIST_ENTRIES:
            warnings.append(
                f"{FETCH_LIST_ABS} has more than {MAX_LIST_ENTRIES} entries; ignoring the rest"
            )
            break
        if entry in names:
            warnings.append(f"duplicate entry '{sanitize_text(entry)}' in {FETCH_LIST_ABS}")
            continue
        bad = set(entry) - NAME_ALLOWED
        if bad:
            warnings.append(
                f"ignoring '{sanitize_text(entry)}' in {FETCH_LIST_ABS}: "
                "not a plain pacman package name"
            )
            continue
        names.append(entry)
    return names, warnings


def read_fetch_list(live_root=LIVE_ROOT) -> tuple[list[str], list[str]]:
    """Read the fetch list off the live ISO. Returns (names, warnings).

    🔴 A missing or empty list is **not** "nothing to do". It is the P3.2 defect
    wearing a different hat -- a list that installs nothing, quietly -- so it
    raises, is recorded as ``failed``, and leaves the first-boot unit behind.
    ``builder/build-iso.sh`` refuses to build an empty one, so reaching this
    branch means the ISO was assembled without the guard or the copy.
    """
    warnings: list[str] = []
    path = Path(live_root) / FETCH_LIST_REL
    try:
        with open(path, "rb") as handle:
            data = handle.read(MAX_LIST_BYTES + 1)
    except FileNotFoundError as exc:
        raise DeckPkgsError(
            f"{path} does not exist on the live ISO -- nothing tells this install "
            "which packages to fetch, so none were installed. builder/build-iso.sh "
            "is supposed to copy configs/deck/deck-fetch.packages here."
        ) from exc
    except OSError as exc:
        raise DeckPkgsError(f"cannot read {path}: {exc}") from exc

    if len(data) > MAX_LIST_BYTES:
        warnings.append(f"{path} is larger than {MAX_LIST_BYTES} bytes; reading the head only")
        data = data[:MAX_LIST_BYTES]

    names, parse_warnings = parse_package_list(data.decode("utf-8", "replace"))
    warnings.extend(parse_warnings)
    if not names:
        raise DeckPkgsError(
            f"{path} carries no usable package entries. A fetch list that names "
            "nothing installs nothing, which is exactly the defect this step was "
            "written to remove (docs/findings/P32-steam-never-installed.md)."
        )
    return names, warnings


# ---------------------------------------------------------------------------
# The commands -- their own functions, so a unit test can assert WHERE and HOW
# this runs without a chroot, a container or root
# ---------------------------------------------------------------------------


def query_command(target, name: str) -> list[str]:
    """Is ``name`` installed on the target? ``pacman -Qq`` inside the chroot.

    Inside ``arch-chroot`` rather than ``pacman --root``: ``--root`` needs
    ``--dbpath`` kept in step with it and answers about a database this process
    assembled, whereas the chroot answers about the machine that will boot.
    Same decision, same reasons, as ``deck_patches.chroot_command``.
    """
    return ["arch-chroot", str(target), "pacman", "-Qq", name]


def sync_command(target) -> list[str]:
    """Refresh the target's package databases from its ONLINE repos.

    No ``-u``: see decision 3. ``--noconfirm`` because there is no keyboard on
    this device and a prompt would hang the install forever.
    """
    return ["arch-chroot", str(target), "pacman", "-Sy", "--noconfirm"]


def install_command(target, names: list[str]) -> list[str]:
    """The transaction. ``--needed`` is the idempotence guarantee pacman itself
    makes; the query pass above is what makes a re-run touch the network zero
    times rather than once."""
    return ["arch-chroot", str(target), "pacman", "-S", "--needed", "--noconfirm", *names]


def run_command(argv: list[str], timeout: int) -> tuple[int, str]:
    """Execute ``argv``. Returns (exit code, combined output).

    ``check=False``: a non-zero exit is pacman reporting, not an accident, and
    this step's whole job is to turn it into a record. A timeout is turned into
    a distinguishable non-zero result rather than an exception, so a wedged
    mirror reads as "the sync failed, here is why" instead of a traceback.
    """
    try:
        proc = subprocess.run(  # noqa: S603
            argv,
            capture_output=True,
            text=True,
            check=False,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return 124, f"timed out after {timeout}s: {' '.join(argv)}"
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


def summarize_output(text: str) -> str:
    """Last few non-blank lines of pacman's output, sanitised.

    Sanitised because it lands in a world-readable JSON document, and joined
    with ' | ' rather than newlines because ``sanitize_text`` deletes control
    bytes -- concatenating raw lines would glue two messages into one word.
    Identical treatment to ``deck_patches.summarize_output``; the two are
    separate because neither module imports the other.
    """
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    if not lines:
        return ""
    return " | ".join(
        sanitize_text(line, limit=MAX_LINE_CHARS) for line in lines[-MAX_OUTPUT_LINES:]
    )


def missing_on_target(target, names: list[str], runner) -> tuple[list[str], list[str]]:
    """Which of ``names`` are NOT installed on the target. Returns (missing, warnings).

    One query per name rather than one query for all of them: ``pacman -Qq a b``
    exits non-zero if *any* is absent and does not tell you which, and "which"
    is the whole answer -- it decides what the transaction asks for and what the
    verification at the end re-checks.

    A query that fails for a reason other than "not installed" (no arch-chroot,
    an unreadable database) is reported as missing AND warned about, because the
    safe direction is to attempt an install that ``--needed`` will no-op, not to
    assume a package is present on the strength of a broken check.
    """
    missing: list[str] = []
    warnings: list[str] = []
    for name in names:
        code, output = runner(query_command(target, name), QUERY_TIMEOUT_SECS)
        if code == 0:
            continue
        missing.append(name)
        if code not in (1,):
            warnings.append(
                f"querying '{name}' on the target exited {code}: {summarize_output(output)}"
            )
    return missing, warnings


def read_wifi_status(live_root=LIVE_ROOT) -> str:
    """What the installer's Wi-Fi screen recorded. Classification only.

    Imported lazily and defended with a broad ``except``: this step must not be
    able to fail because the *reporting* half of a sibling module did. If the
    answer cannot be had, it is ``"unknown"``, which classifies a failed sync as
    ``failed`` rather than as ``skipped-no-network`` -- the louder of the two,
    which is the right default when we do not know.
    """
    try:
        from . import deck_wifi

        fields, _ = deck_wifi.read_outcome(live_root)
        return fields.get("status", "missing") or "missing"
    except Exception:  # noqa: BLE001 -- deliberate, see the docstring
        return "unknown"


# ---------------------------------------------------------------------------
# The first-boot report -- §4.1 requirement (iii)
# ---------------------------------------------------------------------------


def write_state(target, fields: dict[str, str]) -> Path:
    """The key=value file the first-boot script reads.

    Written as key=value and PARSED by that script, never sourced -- the same
    rule ``deck_wifi.write_carry_state`` follows. Nothing here is
    attacker-controlled today (the package names came from our own list and
    were character-checked), but pacman's error tail is not ours, so every
    value is sanitised on the way in and re-stripped by the reader.
    """
    path = Path(target) / STATE_REL
    path.parent.mkdir(parents=True, exist_ok=True)
    body = "".join(f"{key}={sanitize_text(str(value))}\n" for key, value in fields.items())
    path.write_text(body)
    os.chmod(path, STATE_MODE)
    return path


def install_first_boot_unit(target, asset_dir=FIRST_BOOT_ASSET_DIR) -> None:
    """Copy the steam-absent notice and its unit onto the target, and enable it.

    🔴 **Installed unconditionally, not only when this step failed.** The case
    worth catching is the one that looks fine here: a transaction that exits 0
    while ``/usr/lib/steam`` never appears, or a Steam that is removed later.
    A unit installed only on the paths we already know about cannot report the
    path we do not. It disables itself the first time Steam is genuinely there,
    so it is not a permanent nag.

    Enabled by writing the ``multi-user.target.wants`` symlink directly rather
    than by ``arch-chroot systemctl enable``: same result, deterministic, and
    assertable from a unit test without a chroot. Modes are set explicitly --
    mkarchiso copies the ISO's airootfs with ``--no-preserve=mode``, so the
    asset arrives 0644 and the executable bit has to be put back here.
    """
    target = Path(target)
    asset_dir = Path(asset_dir)

    script_src = asset_dir / FIRST_BOOT_SCRIPT_ASSET
    unit_src = asset_dir / FIRST_BOOT_UNIT
    for src in (script_src, unit_src):
        if not src.is_file():
            raise DeckPkgsError(
                f"missing ISO asset {src} -- the first-boot Steam notice cannot be installed"
            )

    for src, dst, mode in (
        (script_src, target / FIRST_BOOT_SCRIPT_REL, FIRST_BOOT_SCRIPT_MODE),
        (unit_src, target / FIRST_BOOT_UNIT_REL, FIRST_BOOT_UNIT_MODE),
    ):
        dst.parent.mkdir(parents=True, exist_ok=True)
        if dst.is_symlink() or dst.exists():
            dst.unlink()
        shutil.copyfile(src, dst)
        os.chmod(dst, mode)

    wants = target / FIRST_BOOT_WANTS_REL
    wants.parent.mkdir(parents=True, exist_ok=True)
    if wants.is_symlink() or wants.exists():
        wants.unlink()
    # Absolute path INSIDE the installed system, not inside /mnt: this symlink
    # is read after a reboot, when the target is /.
    wants.symlink_to("/" + FIRST_BOOT_UNIT_REL)


# ---------------------------------------------------------------------------
# The step
# ---------------------------------------------------------------------------


def fetch_packages(target, live_root=LIVE_ROOT, asset_dir=FIRST_BOOT_ASSET_DIR, runner=None) -> dict:
    """Install the fetch list into ``target`` and return the record for the log.

    ``runner`` is injectable so the suite can drive every branch without a
    chroot. ``None`` rather than ``runner=run_command``: a default argument
    binds the function object at *definition* time, so replacing the module
    attribute would silently keep calling the real ``arch-chroot``. Looking it
    up here means the module attribute is genuinely the seam -- the same trap
    ``deck_patches.apply_patches`` documents.
    """
    if runner is None:
        runner = run_command
    target = Path(target)

    record: dict = {
        "status": None,
        "list": FETCH_LIST_ABS,
        "requested": [],
        "missing_before": [],
        "installed": [],
        "already_present": False,
        "synced": False,
        "wifi_status": None,
        "steam_bootstrap": None,
        "exit_code": None,
        "output": None,
        "first_boot_unit": None,
        "error": None,
        "warnings": [],
    }
    warnings: list[str] = record["warnings"]

    try:
        names, list_warnings = read_fetch_list(live_root)
        warnings.extend(list_warnings)
        record["requested"] = names

        wifi_status = read_wifi_status(live_root)
        record["wifi_status"] = wifi_status

        missing, query_warnings = missing_on_target(target, names, runner)
        warnings.extend(query_warnings)
        record["missing_before"] = missing

        if not missing:
            # The idempotent path. No sync, no transaction, no network: a
            # re-run of configure_deck is a genuine no-op, which CLAUDE.md
            # requires and which the SSH iterate-in-place loop depends on.
            record["already_present"] = True
            record["status"] = STATUS_INSTALLED
            info(f"Deck packages: already installed on the target ({', '.join(names)})")
        else:
            # §4.1 requirement (i): say on screen that this needs the network,
            # BEFORE the wait, so a user watching an installer with no terminal
            # knows what it is waiting for.
            info(
                "Deck packages: downloading "
                + ", ".join(missing)
                + " from the network (this step needs the internet; "
                + f"the installer's Wi-Fi screen recorded status={wifi_status})"
            )

            code, output = runner(sync_command(target), SYNC_TIMEOUT_SECS)
            record["exit_code"] = code
            record["output"] = summarize_output(output) or None
            if code != 0:
                # 🔴 The classification, and the ONLY place deck_wifi's record
                # is used. `skipped-no-network` is not "we chose not to try" --
                # the sync was attempted and failed, and this says we already
                # know why. Anything we cannot explain is `failed`, the louder
                # of the two.
                if wifi_status in NO_NETWORK_WIFI_STATUSES:
                    record["status"] = STATUS_NO_NETWORK
                    record["error"] = sanitize_text(
                        f"could not refresh the target's package databases (pacman -Sy exited "
                        f"{code}) and the installer's Wi-Fi screen recorded status="
                        f"{wifi_status}: this machine had no network. "
                        f"{', '.join(missing)} were NOT installed. "
                        "Connect this Deck to a network and run "
                        "`sudo pacman -S --needed " + " ".join(missing) + "`.",
                        limit=400,
                    )
                else:
                    record["status"] = STATUS_FAILED
                    record["error"] = sanitize_text(
                        f"pacman -Sy exited {code} inside the target while the installer's "
                        f"Wi-Fi screen recorded status={wifi_status}. "
                        f"{', '.join(missing)} were NOT installed.",
                        limit=400,
                    )
            else:
                record["synced"] = True
                code, output = runner(install_command(target, missing), INSTALL_TIMEOUT_SECS)
                record["exit_code"] = code
                record["output"] = summarize_output(output) or None
                if code != 0:
                    record["status"] = STATUS_FAILED
                    record["error"] = sanitize_text(
                        f"pacman -S --needed {' '.join(missing)} exited {code} inside the "
                        "target. Gaming Mode will not start without steam; see the output "
                        "field and /var/log/omarchy-deck-install.json.",
                        limit=400,
                    )
                else:
                    # 🔴 THE OUTCOME ASSERTION. Eleven green steps and 18/18 in
                    # QEMU already passed on a machine with no Steam; a zero
                    # exit is a step assertion and this is not going to be one.
                    still_missing, verify_warnings = missing_on_target(target, missing, runner)
                    warnings.extend(verify_warnings)
                    if still_missing:
                        record["status"] = STATUS_FAILED
                        record["error"] = sanitize_text(
                            "pacman exited 0 but "
                            + ", ".join(still_missing)
                            + " is still not installed on the target -- the exit code and the "
                            "package database disagree, so neither can be trusted.",
                            limit=400,
                        )
                    else:
                        record["installed"] = missing
                        record["status"] = STATUS_INSTALLED
                        info(f"Deck packages installed on the target: {', '.join(missing)}")

        # The finding's named check, recorded whatever the status is: it is the
        # one fact that distinguishes "steam's package is present" from "steam
        # can actually start".
        if STEAM_PACKAGE in record["requested"]:
            record["steam_bootstrap"] = (target / STEAM_BOOTSTRAP_REL).is_file()
            if record["status"] == STATUS_INSTALLED and not record["steam_bootstrap"]:
                warnings.append(
                    f"steam is installed but /{STEAM_BOOTSTRAP_REL} is absent -- "
                    "steam-launcher unpacks that tarball at first run and hits its "
                    "start limit without it"
                )
    except (DeckPkgsError, OSError) as exc:
        record["status"] = STATUS_FAILED
        record["error"] = sanitize_text(f"{type(exc).__name__}: {exc}", limit=400)

    # Whatever happened above, the target gets the state file and the unit: the
    # report and the retry are exactly what must survive a failure here.
    try:
        write_state(
            target,
            {
                "status": record["status"] or STATUS_FAILED,
                "expected": " ".join(record["requested"]),
                "installed": " ".join(record["installed"]),
                "wifi_status": record["wifi_status"] or "unknown",
                "error": record["error"] or "",
            },
        )
        install_first_boot_unit(target, asset_dir)
        record["first_boot_unit"] = "/" + FIRST_BOOT_UNIT_REL
    except (OSError, DeckPkgsError) as exc:
        warnings.append(f"could not install the first-boot Steam notice: {exc}")

    if record["error"]:
        error(f"Deck packages: {record['error']}")
    for warning in warnings:
        error(f"Deck packages: {warning}")
    return record


def fetch_packages_step(ctx) -> None:
    """``DeckStep`` entry point. Records under the ``pkgs`` key whichever way it
    went, so one QEMU assertion over
    ``/var/log/omarchy-deck-install.json`` can ask the question the eleven green
    steps never did: is Steam actually on this machine?"""
    record_result(ctx.target, "pkgs", fetch_packages(ctx.target, LIVE_ROOT, FIRST_BOOT_ASSET_DIR))
