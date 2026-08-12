"""Carry the installer's Wi-Fi credentials onto the installed system.

SHIPPED AS ``/usr/share/omarchy-iso/orchestrator/deck_wifi.py``. The
``configure_deck`` step registered in ``deck_configure.deck_steps``.

WHY THIS EXISTS -- MEASURED, NOT ASSUMED
========================================

Upstream carries nothing across. Against the pinned ``iso/upstream`` tree:
``root/configurator`` contains no ``iwd``/``iwctl``/``nmcli``/``NetworkManager``
reference at all -- its only network statement is the literal
``"network_config": {"type": "iso"}`` it writes at lines 770 and 1156 -- the
14-phase orchestrator has no network code, and the strings
``system-connections`` and ``nmconnection`` appear **zero** times anywhere in
the tree. So the whole hand-off is delegated to archinstall's ``type: iso``
handler, which copies ``/var/lib/iwd/*.psk`` and enables **iwd** on the target,
while Omarchy enables **NetworkManager** (``manifests/fresh-4.json``; a fresh
install's manifest contains no iwd package). Two managers claiming wlan0 is a
conflict, not a hand-off.

The user-visible consequence is ``docs/tasks/T4-screen-spec.md`` §8's U1: join
Wi-Fi in the installer, reboot into Gaming Mode with no network and no way to
type -- the exact outcome ``docs/PLAN.md`` §6.1a item 7 was promoted to
prevent.

THE CONTRACT WITH S1 (``src/deck-form.sh``, its own U1 block)
=============================================================

In the LIVE environment, S1 leaves:

``/root/deck-wifi.nmconnection``
    a complete NetworkManager keyfile, mode 0600, present **only** when a
    network was actually joined.

``/root/deck-wifi-outcome``
    ``key=value`` lines: ``status=`` one of connected|skipped|no-hardware|
    iwd-failed, and ``ssid=`` (sanitised).

    🔴 **PARSED, NEVER SOURCED.** The ssid value is attacker-controlled text.
    Python cannot ``source`` it, but the parser below still has to behave as if
    the file were hostile: see ``parse_outcome``'s first-wins rule, which is
    what stops an SSID carrying a newline from forging a second ``status=``
    line. S1 refuses hostile SSIDs rather than encoding them for exactly this
    reason; this end does not rely on that having happened.

🔴 THE FAILURE MODE THIS FILE IS SHAPED AROUND
==============================================

**NetworkManager silently refuses to load a group- or world-readable keyfile.**
A copy that widens the mode fails invisibly at first boot -- the install
succeeds, the file is there, its contents are right, and the Deck has no
network. That is the exact class ``CLAUDE.md`` forbids, so:

* the destination is created with an explicit 0600 and ``fchmod``-ed to 0600
  regardless of the process umask -- never ``shutil.copy`` (which applies the
  umask, typically 0644) and never ``shutil.copy2``/``copystat`` (which would
  propagate a wrong *source* mode instead of imposing a right one);
* the mode is then **read back from the destination inode** and a mismatch
  raises. A check that only asserts the file exists would pass while the
  product has no Wi-Fi.

WHY THE DESTINATION FILENAME IS FIXED, NOT THE SSID
===================================================

``docs/tasks/T4-screen-spec.md`` §5 writes it as ``<ssid>.nmconnection``. It is
``deck-wifi.nmconnection`` here instead: an SSID is attacker-controlled and a
filename is a path -- ``../`` and ``/`` in an SSID are a directory traversal
with root privileges into a target filesystem. NetworkManager does not require
the filename to match the connection id (the id lives inside the keyfile), so
nothing is lost, and the fixed name additionally makes a re-run idempotent
instead of accumulating one profile per attempt. The SSID assertion §5 asks for
is then made against the ``ssid=`` line *inside* the file, which is the value
NetworkManager actually uses -- a strictly stronger check than the filename.
"""

from __future__ import annotations

import os
import shutil
import stat
from pathlib import Path

from .deck_configure import record_result, sanitize_text
from .ui import error, info

# --- the live side (S1's output) -------------------------------------------

LIVE_ROOT = Path("/")
STAGED_PROFILE_REL = "root/deck-wifi.nmconnection"
STAGED_OUTCOME_REL = "root/deck-wifi-outcome"

# S1's vocabulary. A value outside this set is not treated as "probably fine":
# it is recorded as-is and flagged, because an unrecognised status means the two
# halves of the contract have drifted and that must be visible.
KNOWN_STATUSES = ("connected", "skipped", "no-hardware", "iwd-failed")

# Caps on hostile input. A keyfile is ~300 bytes and the outcome file is two
# lines; these exist so a huge or infinitely-long-lined file cannot be read into
# memory by a root process.
MAX_PROFILE_BYTES = 64 * 1024
MAX_OUTCOME_BYTES = 8 * 1024
MAX_OUTCOME_LINES = 64

# --- the target side --------------------------------------------------------

TARGET_PROFILE_REL = "etc/NetworkManager/system-connections/deck-wifi.nmconnection"
PROFILE_MODE = 0o600
# NetworkManager itself only checks the keyfile's mode, but the directory is
# 0700 on every distribution that ships it and a wider one would leak the
# filenames of every profile. Set it rather than inherit whatever created it.
PROFILE_DIR_MODE = 0o700

# Read by the first-boot unit. key=value, no secrets, world-readable.
CARRY_STATE_REL = "var/lib/omarchy-deck/wifi-carry"
CARRY_STATE_MODE = 0o644

# Assets the ISO carries, copied onto the target by this step. T5d owes the
# overlay entry that puts them here (see src/iso-patches/README.md).
ASSET_DIR = Path("/usr/share/omarchy-iso/deck")
FIRST_BOOT_UNIT = "omarchy-deck-wifi-first-boot.service"
FIRST_BOOT_SCRIPT_ASSET = "deck-wifi-first-boot.sh"
FIRST_BOOT_SCRIPT_REL = "usr/local/bin/omarchy-deck-wifi-first-boot"
FIRST_BOOT_UNIT_REL = f"etc/systemd/system/{FIRST_BOOT_UNIT}"
FIRST_BOOT_WANTS_REL = f"etc/systemd/system/multi-user.target.wants/{FIRST_BOOT_UNIT}"
FIRST_BOOT_SCRIPT_MODE = 0o755
FIRST_BOOT_UNIT_MODE = 0o644


class DeckWifiError(Exception):
    """A step-level failure. Non-critical: the install continues (§4.1), the
    outcome is recorded, and the first-boot unit tells the user."""


# ---------------------------------------------------------------------------
# Parsing S1's outcome file
# ---------------------------------------------------------------------------


def parse_outcome(text: str) -> dict[str, str]:
    """Parse ``key=value`` lines. Never evaluated, never sourced.

    🔴 **FIRST WINS.** If a key appears twice, the first occurrence is kept.
    That is the rule that makes an injected line harmless: S1 writes ``status=``
    before ``ssid=``, so an SSID smuggling ``\\nstatus=connected`` appends a
    line *after* the real one and a last-wins parser would believe it. First-
    wins means the genuine status stands and the forgery is dropped.

    Lines without ``=`` are ignored (a bare line is not a claim about
    anything), the value is taken after the FIRST ``=`` so a value containing
    ``=`` survives, and both the byte count and the line count are capped.
    """
    result: dict[str, str] = {}
    for index, raw in enumerate(text.splitlines()):
        if index >= MAX_OUTCOME_LINES:
            break
        line = raw.rstrip("\r")
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        if key and key not in result:
            result[key] = value
    return result


def read_outcome(live_root=LIVE_ROOT) -> tuple[dict[str, str], list[str]]:
    """Read and parse S1's outcome file. Returns (fields, warnings).

    A missing file is not an error: S1 only writes it once it has run, and a
    build/flow where it did not run at all must still install cleanly. It is
    reported, though -- 'the file was not there' and 'the file said skipped' are
    different facts and the log must be able to tell them apart.
    """
    warnings: list[str] = []
    path = Path(live_root) / STAGED_OUTCOME_REL
    try:
        with open(path, "rb") as handle:
            data = handle.read(MAX_OUTCOME_BYTES + 1)
    except FileNotFoundError:
        warnings.append(f"no {path} -- the installer's Wi-Fi screen left no outcome record")
        return {}, warnings
    except OSError as exc:
        warnings.append(f"could not read {path}: {exc}")
        return {}, warnings

    if len(data) > MAX_OUTCOME_BYTES:
        warnings.append(f"{path} is larger than {MAX_OUTCOME_BYTES} bytes; reading the head only")
        data = data[:MAX_OUTCOME_BYTES]

    fields = parse_outcome(data.decode("utf-8", "replace"))
    if "status" not in fields:
        warnings.append(f"{path} carries no status= line")
    elif fields["status"] not in KNOWN_STATUSES:
        warnings.append(
            "unrecognised status "
            f"'{sanitize_text(fields['status'])}' -- S1 and configure_deck have drifted"
        )
    return fields, warnings


# ---------------------------------------------------------------------------
# The copy, and the mode that is the whole point of it
# ---------------------------------------------------------------------------


def read_staged_profile(live_root=LIVE_ROOT) -> bytes | None:
    """Read the staged keyfile, or None when S1 staged nothing.

    ``O_NOFOLLOW``: the source sits in ``/root`` on a live ISO whose filesystem
    other processes share, and a symlink planted there would otherwise make
    this function read an arbitrary file and the next one write its contents
    into the target as a Wi-Fi profile.
    """
    path = Path(live_root) / STAGED_PROFILE_REL
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise DeckWifiError(f"cannot read {path}: {exc}") from exc

    try:
        info_stat = os.fstat(fd)
        if not stat.S_ISREG(info_stat.st_mode):
            raise DeckWifiError(f"{path} is not a regular file")
        if info_stat.st_size > MAX_PROFILE_BYTES:
            raise DeckWifiError(f"{path} is {info_stat.st_size} bytes; refusing to carry it")
        chunks = []
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            chunks.append(chunk)
    finally:
        os.close(fd)
    return b"".join(chunks)


def looks_like_keyfile(data: bytes) -> bool:
    """Cheap sanity check on the staged profile.

    NetworkManager's failure on a malformed keyfile is the same silence as its
    failure on a wrong mode, so an empty or truncated file must be caught here
    rather than discovered by a user with no network. Requires the two sections
    every wifi profile has and a non-empty ``ssid=``; deliberately does not try
    to be a keyfile parser.
    """
    if not data:
        return False
    text = data.decode("utf-8", "replace")
    if "[connection]" not in text or "[wifi]" not in text:
        return False
    for line in text.splitlines():
        if line.startswith("ssid=") and line[len("ssid=") :].strip():
            return True
    return False


def install_profile(data: bytes, dest: Path) -> None:
    """Write ``data`` to ``dest`` as a 0600 file, then prove it is 0600.

    Every line here is load-bearing:

    * the parent is created 0700 (and re-``chmod``-ed, because ``mkdir`` applies
      the umask and an existing directory keeps whatever mode it had);
    * an existing destination -- including a symlink -- is unlinked first, so a
      re-run cannot inherit a previous run's mode and a planted symlink cannot
      redirect the write;
    * ``O_EXCL|O_NOFOLLOW`` with mode 0600, then ``fchmod`` 0600 on the open
      descriptor. The ``O_CREAT`` mode is masked by the umask (which can only
      clear bits, so it can only be *too strict*); the ``fchmod`` makes the
      result exactly 0600 either way, and it happens before the secret is
      written rather than after -- the same ordering ``deck_form_stage_nmconnection``
      documents for the live side;
    * the mode is read back with ``lstat`` on the destination and a mismatch
      raises. That read-back is the assertion the whole task turns on.
    """
    dest.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(dest.parent, PROFILE_DIR_MODE)

    if dest.is_symlink() or dest.exists():
        dest.unlink()

    fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, PROFILE_MODE)
    try:
        os.fchmod(fd, PROFILE_MODE)
        written = 0
        while written < len(data):
            written += os.write(fd, data[written:])
    finally:
        os.close(fd)

    assert_mode(dest, PROFILE_MODE)


def assert_mode(path: Path, want: int) -> None:
    """Raise unless ``path``'s permission bits are exactly ``want``.

    Separate function because it is the product of this file. NetworkManager
    reads the mode and refuses a group- or world-readable keyfile without
    saying so anywhere the user will look, so the copy is only finished once
    the mode has been read back off the inode that was actually created.
    """
    got = stat.S_IMODE(os.lstat(path).st_mode)
    if got != want:
        raise DeckWifiError(
            f"{path} is mode {got:04o}, not {want:04o} -- NetworkManager silently "
            "ignores a group- or world-readable keyfile, so this would be a Deck "
            "with no Wi-Fi and no error message"
        )


# ---------------------------------------------------------------------------
# The first-boot unit -- §4.1 requirement (iii)
# ---------------------------------------------------------------------------


def write_carry_state(target, fields: dict[str, str]) -> Path:
    """The key=value file the first-boot script reads.

    Same discipline as the file this step consumes: written as key=value, read
    by a shell script that PARSES it and never sources it. Every value is
    sanitised here as well, so the script's parser is the second line of
    defence and not the only one.
    """
    path = Path(target) / CARRY_STATE_REL
    path.parent.mkdir(parents=True, exist_ok=True)
    body = "".join(f"{key}={sanitize_text(value)}\n" for key, value in fields.items())
    path.write_text(body)
    os.chmod(path, CARRY_STATE_MODE)
    return path


def install_first_boot_unit(target, asset_dir=ASSET_DIR) -> None:
    """Copy the retry/notify unit and its script onto the target, and enable it.

    🔴 **Installed unconditionally, not only when the carry failed.** The case
    worth catching is precisely the one that looks fine here: a profile copied
    correctly that NetworkManager then declines to use. Requirement (iii) asks
    for a unit that retries and tells the user; a unit installed only on the
    paths we already know about cannot report the path we do not. It disables
    itself the first time the machine has a network, so it is not a permanent
    nag.

    Enabled by writing the ``multi-user.target.wants`` symlink directly rather
    than by ``arch-chroot systemctl enable``: it is the same result, it is
    deterministic, and it is assertable from a unit test without a chroot.
    """
    target = Path(target)
    asset_dir = Path(asset_dir)

    script_src = asset_dir / FIRST_BOOT_SCRIPT_ASSET
    unit_src = asset_dir / FIRST_BOOT_UNIT
    for src in (script_src, unit_src):
        if not src.is_file():
            raise DeckWifiError(
                f"missing ISO asset {src} -- the first-boot Wi-Fi notice cannot be installed"
            )

    script_dst = target / FIRST_BOOT_SCRIPT_REL
    unit_dst = target / FIRST_BOOT_UNIT_REL
    for src, dst, mode in (
        (script_src, script_dst, FIRST_BOOT_SCRIPT_MODE),
        (unit_src, unit_dst, FIRST_BOOT_UNIT_MODE),
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


def carry_wifi(live_root=LIVE_ROOT, target=Path("/mnt"), asset_dir=ASSET_DIR) -> dict:
    """Do the carry-over and return the record for the install log.

    🔴 **A fault is a field in the record, not an exception.** §4.1's rule is
    that the offline install still succeeds and only the silence is banned --
    and the record IS the report, so throwing it away in order to signal a
    failure would destroy the thing requirement (ii) asks for. Everything that
    can go wrong lands in ``record["error"]`` plus ``record["warnings"]``, is
    printed through the orchestrator's ``error``, and leaves the first-boot
    unit behind to say so on the installed system. Nothing here halts an
    install.
    """
    live_root = Path(live_root)
    target = Path(target)

    fields, warnings = read_outcome(live_root)
    status = fields.get("status", "missing")
    ssid = sanitize_text(fields.get("ssid", ""))

    record = {
        "status": status,
        "ssid": ssid,
        "profile_installed": False,
        "profile_path": None,
        "profile_mode": None,
        "first_boot_unit": None,
        "error": None,
        "warnings": warnings,
    }

    try:
        data = read_staged_profile(live_root)

        # The two halves of S1's contract disagreeing is a real event, not a
        # tolerance: report it either way round, then act on the file, because
        # the file is what makes Wi-Fi work.
        if data is None and status == "connected":
            warnings.append(
                "status=connected but no staged keyfile -- the credentials did not survive S1"
            )
        if data is not None and status not in ("connected", "missing"):
            warnings.append(
                f"a keyfile was staged but status={sanitize_text(status)}; carrying it anyway"
            )

        if data is None:
            info(f"No Wi-Fi profile staged by the installer (status={status or 'missing'})")
        elif not looks_like_keyfile(data):
            raise DeckWifiError(
                f"the staged keyfile at /{STAGED_PROFILE_REL} is not a usable NetworkManager "
                "profile (no [connection]/[wifi] section, or an empty ssid=)"
            )
        else:
            dest = target / TARGET_PROFILE_REL
            install_profile(data, dest)
            record["profile_installed"] = True
            record["profile_path"] = "/" + TARGET_PROFILE_REL
            record["profile_mode"] = f"{PROFILE_MODE:04o}"
            info(f"Wi-Fi profile installed to /{TARGET_PROFILE_REL} (mode 0600)")
    except (DeckWifiError, OSError) as exc:
        record["error"] = sanitize_text(f"{type(exc).__name__}: {exc}", limit=400)

    # Whatever happened above, the target gets the state file and the unit: the
    # report and the retry are exactly what must survive a failure here.
    try:
        write_carry_state(
            target,
            {
                "carried": "yes" if record["profile_installed"] else "no",
                "status": status,
                "ssid": ssid,
            },
        )
        install_first_boot_unit(target, asset_dir)
        record["first_boot_unit"] = "/" + FIRST_BOOT_UNIT_REL
    except (OSError, DeckWifiError) as exc:
        warnings.append(f"could not install the first-boot Wi-Fi notice: {exc}")

    if record["error"]:
        error(f"Wi-Fi carry-over failed: {record['error']}")
    for warning in warnings:
        error(f"Wi-Fi carry-over: {warning}")

    return record


def carry_wifi_step(ctx) -> None:
    """``DeckStep`` entry point. Records under the ``wifi`` key whichever way it
    went -- ``docs/tasks/T4-screen-spec.md`` §4 S6's [V] row asserts exactly
    that."""
    record_result(ctx.target, "wifi", carry_wifi(LIVE_ROOT, ctx.target, ASSET_DIR))
