"""Late identity application for FAST-INSTALL (Stages slice, C3).

Runs inside the target after the early stage restored the root image:
hostname, timezone (+NTP flag), console keymap, root password, Wi-Fi profile
carry, user creation at uid/gid 1000, and authorized_keys/SSH staging data
the late ``configure_ssh_access`` phase consumes.

Why direct writes instead of archinstall's Installer object
-----------------------------------------------------------
Early already ran the full archinstall flow (partition, restore, delta,
Limina configure, genfstab) under the deferred config. Late must not re-run
it: re-running ``genfstab`` appends duplicates, and re-running Limine setup
needs the Installer object RootImage owns. Hostname/timezone/keymap are plain
files; user creation replicates ``create_users`` group semantics by reading
the same ``auth_config`` the full path feeds archinstall.

``create_user`` is idempotent: a re-run with the same name/uid is a no-op;
a conflicting name or uid fails loudly.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path


STAGING_UID = 1000
STAGING_GID = 1000


def _ctx_text(ctx, name: str) -> str:
    value = getattr(ctx, name, "")
    if value is None:
        return ""
    return str(value).strip()


def _credentials_username(ctx) -> str:
    users = (getattr(ctx, "user_credentials", None) or {}).get("users") or []
    if users and users[0].get("username"):
        return str(users[0]["username"])
    name = _ctx_text(ctx, "username")
    if name:
        return name
    raise RuntimeError(
        "late stage has no username: user_credentials.json names no users"
    )


def _credentials_password_hash(ctx) -> str:
    users = (getattr(ctx, "user_credentials", None) or {}).get("users") or []
    raw = users[0].get("enc_password") if users else None
    if not raw:
        raise RuntimeError(
            "late stage has no password hash: user_credentials.json names no users"
        )
    return _vet_password_hash("user", str(raw))


def _arch_timezone(ctx) -> str:
    cfg = getattr(ctx, "user_configuration", None) or {}
    zone = str(cfg.get("timezone") or "UTC").strip() or "UTC"
    return zone


def _arch_keymap(ctx) -> str:
    cfg = getattr(ctx, "user_configuration", None) or {}
    locale = cfg.get("locale_config") or {}
    return str(locale.get("kb_layout") or "us").strip() or "us"


def _arch_hostname(ctx) -> str:
    cfg = getattr(ctx, "user_configuration", None) or {}
    host = str(cfg.get("hostname") or "omarchy").strip() or "omarchy"
    return host


def apply_identity(ctx) -> None:
    """Write hostname, timezone, keymap, root password, Wi-Fi, SSH staging."""
    from .ui import info

    target = Path(ctx.target)
    _apply_hostname(target, _arch_hostname(ctx))
    _apply_timezone(target, _arch_timezone(ctx))
    _apply_keymap(target, _arch_keymap(ctx))
    _apply_root_password(ctx, target)
    _carry_wifi(ctx, target)
    info("Late identity applied (hostname, timezone, keymap, root password, Wi-Fi)")


def _apply_hostname(target: Path, hostname: str) -> None:
    (target / "etc/hostname").write_text(hostname + "\n")
    hosts = target / "etc/hosts"
    if hosts.is_file():
        text = hosts.read_text()
        lines = []
        replaced = False
        for line in text.splitlines():
            if line.startswith("127.0.1.1"):
                lines.append(f"127.0.1.1\t{hostname}")
                replaced = True
            else:
                lines.append(line)
        if not replaced:
            lines.append(f"127.0.1.1\t{hostname}")
        hosts.write_text("\n".join(lines) + "\n")


def _apply_timezone(target: Path, zone: str) -> None:
    zone = (zone or "").strip() or "UTC"
    zoneinfo = target / "usr/share/zoneinfo" / zone
    if not zoneinfo.is_file():
        raise RuntimeError(
            f"unknown timezone {zone!r}: no such file under usr/share/zoneinfo on the target"
        )
    localtime = target / "etc/localtime"
    try:
        if localtime.is_symlink() or localtime.is_file():
            localtime.unlink()
        localtime.symlink_to(f"/usr/share/zoneinfo/{zone}")
    except OSError as exc:
        raise RuntimeError(f"could not set target timezone to {zone}: {exc}") from exc
    (target / "etc/timezone").write_text(zone + "\n")
    adjtime = target / "etc/adjtime"
    if not adjtime.exists():
        adjtime.write_text("0.0 0 0.0\n0\nUTC\n")


def _apply_keymap(target: Path, keymap: str) -> None:
    from . import keyboard

    layout = (keymap or "").strip()
    if not layout:
        raise RuntimeError("keyboard layout is empty; refusing to write no keymap")
    if not keyboard.configure_keyboard(target, layout):
        raise RuntimeError(
            f"keyboard layout {layout!r} is unknown to localectl; refusing to continue "
            "with the wrong keymap on a controller-only Deck"
        )


def _apply_root_password(ctx, target: Path) -> None:
    raw = (getattr(ctx, "user_credentials", None) or {}).get("root_enc_password")
    if not raw:
        raise RuntimeError(
            "user_credentials.json carries no root_enc_password; refusing to leave "
            "root without a password hash"
        )
    root_hash = _vet_password_hash("root", str(raw))
    shadow = target / "etc/shadow"
    if not shadow.is_file():
        raise RuntimeError("target has no /etc/shadow; cannot set root password")
    lines = []
    replaced = False
    for line in shadow.read_text().splitlines():
        if line.startswith("root:"):
            parts = line.split(":")
            parts[1] = root_hash
            lines.append(":".join(parts))
            replaced = True
        else:
            lines.append(line)
    if not replaced:
        raise RuntimeError("target /etc/shadow has no root entry")
    shadow.write_text("\n".join(lines) + "\n")


def _carry_wifi(ctx, target: Path) -> None:
    from . import deck_wifi

    record = deck_wifi.carry_wifi(Path("/"), target)
    from . import deck_configure

    deck_configure.record_result(target, "wifi", record)
    _ = ctx


def _user_groups(ctx) -> list[str]:
    users = (getattr(ctx, "user_credentials", None) or {}).get("users") or []
    groups: list[str] = []
    if users:
        for group in users[0].get("groups") or []:
            name = str(group).strip()
            if name and name not in groups:
                groups.append(name)
    for fallback in ("wheel",):
        if fallback not in groups:
            groups.append(fallback)
    return groups


def create_user(ctx) -> None:
    """Create the owner account at uid/gid 1000 without touching the home.

    ``-M``: the staging home (owned 1000:1000 since early) is inherited, and
    ``late_steam`` renames it onto ``/home/<user>`` next. Groups mirror what
    the full path feeds archinstall's ``create_users`` (credentials groups
    plus wheel for sudo).
    """
    from .ui import info

    target = Path(ctx.target)
    username = _credentials_username(ctx)
    password_hash = _credentials_password_hash(ctx)
    _ensure_group(target, STAGING_GID, username)
    existing = _passwd_entry(target, username)
    if existing is not None:
        name, uid, gid, home = existing
        if uid != STAGING_UID or gid != STAGING_GID:
            raise RuntimeError(
                f"target account {name} exists with uid {uid}:gid {gid}, "
                f"not {STAGING_UID}:{STAGING_GID}; refusing to take it over"
            )
        _set_password(target, username, password_hash)
        _ensure_membership(target, username, _user_groups(ctx))
        _grant_wheel_sudo(target)
        info(f"Late user {username} already present (uid 1000); password refreshed")
        return
    if _uid_taken(target, STAGING_UID):
        raise RuntimeError(
            f"uid {STAGING_UID} is already taken on the target by another account; "
            "refusing to create a conflicting owner"
        )
    cmd = [
        "arch-chroot", str(target),
        "useradd",
        "-m" if not _staging_home_present(target) else "-M",
        "-u", str(STAGING_UID),
        "-g", str(STAGING_GID),
        "-G", ",".join(_user_groups(ctx)),
        "-s", "/bin/bash",
        username,
    ]
    result = subprocess.run(cmd, check=False, capture_output=True, text=True)
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "unknown useradd error").strip()
        raise RuntimeError(f"could not create target user {username}: {detail}")
    _set_password(target, username, password_hash)
    _grant_wheel_sudo(target)
    info(f"Late user {username} created (uid 1000)")


# The grant upstream's omarchy-provision-owner writes for deferred-provisioning
# installs, verbatim and under the same name: those installs skip archinstall's
# create_users, which is what normally enables %wheel, and the late stage
# replaces provision-owner's account creation. Without it the owner is in
# wheel and sudo still refuses them -- found by the first QEMU run of the
# in-place Gaming Mode opt-in ("not allowed to execute ... as root").
# Password-required, so the payload audit's NOPASSWD rule is not in play.
WHEEL_SUDOERS = "/etc/sudoers.d/00-omarchy-wheel"
WHEEL_SUDOERS_LINE = "%wheel ALL=(ALL:ALL) ALL"


def _grant_wheel_sudo(target: Path) -> None:
    """Install WHEEL_SUDOERS inside the target, validated by the target's own
    visudo BEFORE it is moved into place (a malformed drop-in breaks sudo for
    every user), then read back. Raises on any failure."""
    script = (
        "set -e; umask 0077; "
        f"t=$(mktemp /etc/sudoers.d/.00-omarchy-wheel.XXXXXX); trap 'rm -f \"$t\"' EXIT; "
        f"printf '%s\\n' '{WHEEL_SUDOERS_LINE}' >\"$t\"; "
        "visudo -cf \"$t\" >/dev/null; chmod 0440 \"$t\"; "
        f"mv -f \"$t\" {WHEEL_SUDOERS}"
    )
    result = subprocess.run(
        ["arch-chroot", str(target), "sh", "-c", script],
        check=False, capture_output=True, text=True,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "unknown error").strip()
        raise RuntimeError(f"could not install {WHEEL_SUDOERS} on the target: {detail}")
    written = target / WHEEL_SUDOERS.lstrip("/")
    try:
        lines = written.read_text().splitlines()
        mode = written.stat().st_mode & 0o777
    except OSError as exc:
        raise RuntimeError(f"{WHEEL_SUDOERS} is not readable back from the target: {exc}") from exc
    if lines != [WHEEL_SUDOERS_LINE] or mode != 0o440:
        raise RuntimeError(
            f"{WHEEL_SUDOERS} read back as {lines!r} mode {mode:04o}, "
            f"not [{WHEEL_SUDOERS_LINE!r}] mode 0440"
        )


def _staging_home_present(target: Path) -> bool:
    staging = target / "home/.omarchy-deck-staging"
    return staging.is_dir() and not staging.is_symlink()


def _passwd_entry(target: Path, username: str):
    passwd = target / "etc/passwd"
    if not passwd.is_file():
        return None
    for line in passwd.read_text().splitlines():
        parts = line.split(":")
        if len(parts) >= 7 and parts[0] == username:
            try:
                return (parts[0], int(parts[2]), int(parts[3]), parts[5])
            except ValueError:
                return None
    return None


def _uid_taken(target: Path, uid: int) -> bool:
    passwd = target / "etc/passwd"
    if not passwd.is_file():
        return False
    for line in passwd.read_text().splitlines():
        parts = line.split(":")
        if len(parts) >= 4 and parts[2] == str(uid):
            return True
    return False


def _ensure_group(target: Path, gid: int, name: str) -> None:
    group_file = target / "etc/group"
    if not group_file.is_file():
        raise RuntimeError("target has no /etc/group")
    for line in group_file.read_text().splitlines():
        parts = line.split(":")
        if len(parts) >= 3 and parts[2] == str(gid):
            return
    result = subprocess.run(
        ["arch-chroot", str(target), "groupadd", "-g", str(gid), name],
        check=False, capture_output=True, text=True,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "unknown groupadd error").strip()
        raise RuntimeError(f"could not create target group {name} (gid {gid}): {detail}")


def _set_password(target: Path, username: str, password_hash: str) -> None:
    shadow = target / "etc/shadow"
    if not shadow.is_file():
        raise RuntimeError("target has no /etc/shadow")
    lines = []
    replaced = False
    for line in shadow.read_text().splitlines():
        if line.startswith(username + ":"):
            parts = line.split(":")
            parts[1] = password_hash
            lines.append(":".join(parts))
            replaced = True
        else:
            lines.append(line)
    if not replaced:
        raise RuntimeError(f"target /etc/shadow has no entry for {username}")
    shadow.write_text("\n".join(lines) + "\n")
    os.chmod(shadow, 0o640)


# --- desktop-only greeter + preinstall opt-in (C4/C6) -------------------------
#
# Gaming=no is a password SDDM login: no autologin file may exist (upstream's
# configure_login already deleted autologin.conf; the gaming drop-in must
# also be absent so no stale User=/Session= survives), the last-session
# state must name the Omarchy desktop session for the created user, and the
# Qt Virtual Keyboard must be enabled so the Deck's trackpad/controller can
# type the password. The session file assertion is the enforcement: a
# greeter naming a missing .desktop is a login loop with no controller
# escape. Verified in QEMU (2026-09-24) that InputMethod= ALONE shows no
# keyboard: SDDM applies it only on its X11 path, the Wayland greeter logs
# "input method is not set", and Omarchy's theme has no InputPanel. So this
# drop-in also passes QT_IM_MODULE through GreeterEnvironment= and selects
# the omarchy-deck theme (the omarchy-deck package: Omarchy's own theme,
# loaded unchanged, plus an always-visible InputPanel). With both, pointer
# clicks alone typed a password and logged in.

DESKTOP_SESSION = "omarchy"
DESKTOP_SESSION_DIRS = ("usr/share/wayland-sessions", "usr/local/share/wayland-sessions")
# 'zx-' sorts after Omarchy's 99-omarchy-login.conf (Current=omarchy), so our
# Current= wins, and before zy-deck-greeter.conf / zz-deck-session.conf.
GREETER_KB_REL = "etc/sddm.conf.d/zx-deck-greeter-keyboard.conf"
GREETER_THEME = "omarchy-deck"
GREETER_KB_TEXT = (
    "[General]\n"
    "InputMethod=qtvirtualkeyboard\n"
    "GreeterEnvironment=QT_IM_MODULE=qtvirtualkeyboard\n"
    "\n"
    "[Theme]\n"
    f"Current={GREETER_THEME}\n"
)
GREETER_KB_MODE = 0o644
# Everything the selected theme loads. A theme that cannot load leaves SDDM
# with a greeter that cannot log in -- so each must exist before we point at it.
GREETER_THEME_REQUIRES = (
    f"usr/share/sddm/themes/{GREETER_THEME}/Main.qml",
    f"usr/share/sddm/themes/{GREETER_THEME}/metadata.desktop",
    "usr/share/sddm/themes/omarchy/Main.qml",
    "usr/lib/qt6/qml/QtQuick/VirtualKeyboard/qmldir",
)
SDDM_CONF_D_REL = "etc/sddm.conf.d"
# Basename shared with deck_autologin (same sort-last contract); imported
# lazily to avoid a hard cross-module constant that drifts silently.
SDDM_STATE_REL = "var/lib/sddm/state.conf"
PREINSTALLS_MARKER_REL = ".local/state/omarchy/preinstalls-removed"
VARIANT_DIR_REL = "var/lib/omarchy-deck"
VARIANT_FILE_REL = f"{VARIANT_DIR_REL}/variant"


def _find_desktop_session(target: Path) -> str | None:
    for rel in DESKTOP_SESSION_DIRS:
        candidate = target / rel / f"{DESKTOP_SESSION}.desktop"
        try:
            if candidate.is_file():
                return "/" + f"{rel}/{DESKTOP_SESSION}.desktop"
        except OSError:
            continue
    return None


def configure_desktop_greeter(target, username: str) -> dict:
    """Password greeter for gaming=no. Returns the record (never silent)."""
    from .ui import error as _error
    from .ui import info as _info

    target = Path(target)
    record: dict = {
        "status": None,
        "session_file": None,
        "keyboard_conf": None,
        "state_conf": None,
        "error": None,
        "warnings": [],
    }
    session_file = _find_desktop_session(target)
    if session_file is None:
        record["status"] = "failed"
        record["error"] = (
            "no Omarchy desktop session file "
            f"({DESKTOP_SESSION}.desktop in {' or '.join('/' + d for d in DESKTOP_SESSION_DIRS)}) "
            "on the target; the greeter would offer no session this Deck can log into"
        )
        _error(f"Desktop greeter: {record['error']}")
        raise RuntimeError(record["error"])
    record["session_file"] = session_file
    missing = [rel for rel in GREETER_THEME_REQUIRES if not (target / rel).is_file()]
    if missing:
        record["status"] = "failed"
        record["error"] = (
            f"the {GREETER_THEME} greeter theme cannot load on this target (missing: "
            + ", ".join("/" + rel for rel in missing)
            + "); selecting it would leave a login screen that cannot log in"
        )
        _error(f"Desktop greeter: {record['error']}")
        raise RuntimeError(record["error"])
    kb_path = target / GREETER_KB_REL
    try:
        kb_path.parent.mkdir(parents=True, exist_ok=True)
        if kb_path.is_symlink():
            kb_path.unlink()
        kb_path.write_text(GREETER_KB_TEXT)
        os.chmod(kb_path, GREETER_KB_MODE)
    except OSError as exc:
        record["status"] = "failed"
        record["error"] = f"could not write /{GREETER_KB_REL}: {exc}"
        _error(f"Desktop greeter: {record['error']}")
        raise RuntimeError(record["error"]) from exc
    record["keyboard_conf"] = "/" + GREETER_KB_REL
    # Any autologin file would bypass the password the contract requires --
    # and a stale gaming User=/Session= would point at a session that was
    # never installed. Remove every *.conf that carries an [Autologin]
    # section except the upstream theme/remember file, which has none.
    conf_dir = target / SDDM_CONF_D_REL
    removed: list[str] = []
    try:
        for entry in sorted(conf_dir.iterdir()) if conf_dir.is_dir() else []:
            if not entry.name.endswith(".conf") or not entry.is_file():
                continue
            text = entry.read_text()
            if "[Autologin]" in text:
                entry.unlink()
                removed.append(entry.name)
    except OSError as exc:
        record["status"] = "failed"
        record["error"] = f"could not sweep /{SDDM_CONF_D_REL} for autologin files: {exc}"
        _error(f"Desktop greeter: {record['error']}")
        raise RuntimeError(record["error"]) from exc
    if removed:
        record["warnings"].append(f"removed stale autologin file(s): {', '.join(removed)}")
    state_path = target / SDDM_STATE_REL
    try:
        state_path.parent.mkdir(parents=True, exist_ok=True)
        state_path.write_text(f"[Last]\nSession={DESKTOP_SESSION}.desktop\nUser={username}\n")
    except OSError as exc:
        record["status"] = "failed"
        record["error"] = f"could not write /{SDDM_STATE_REL}: {exc}"
        _error(f"Desktop greeter: {record['error']}")
        raise RuntimeError(record["error"]) from exc
    record["state_conf"] = "/" + SDDM_STATE_REL
    record["status"] = "ok"
    _info(
        f"Desktop greeter: password login for {username} into {DESKTOP_SESSION}.desktop "
        f"with Qt Virtual Keyboard (/{GREETER_KB_REL})"
    )
    for warning in record["warnings"]:
        _error(f"Desktop greeter: {warning}")
    return record


def apply_preinstalls_choice(target, final_home: str, preinstalls: bool) -> dict:
    """Seed or withhold the preinstall opt-in marker in the final home.

    preinstalls=no leaves ``~/.local/state/omarchy/preinstalls-removed`` so
    the desktop offers Install > Preinstalls (C6 opt-in, real action owned
    by the runtime). preinstalls=yes ensures it is absent (a stale marker
    would offer to restore what is already installed). The marker lives in
    the FINAL home (post-rename), never the staging dir.
    """
    target = Path(target)
    home = target / final_home.lstrip("/")
    record: dict = {
        "status": None,
        "marker": "/" + final_home.lstrip("/") + "/" + PREINSTALLS_MARKER_REL,
        "error": None,
    }
    marker = home / PREINSTALLS_MARKER_REL
    try:
        if preinstalls:
            if marker.is_file() or marker.is_symlink():
                marker.unlink()
            record["status"] = "installed"
        else:
            # Written as root from outside the target, into the user's home:
            # every directory created on the way and the marker itself get
            # the home's owner, because the runtime's Install > Preinstalls
            # runs AS the user and removes this file when it restores them.
            owner = home.stat()
            missing = []
            parent = marker.parent
            while parent != home and not parent.exists():
                missing.append(parent)
                parent = parent.parent
            for directory in reversed(missing):
                directory.mkdir()
                os.lchown(directory, owner.st_uid, owner.st_gid)
            marker.touch()
            os.lchown(marker, owner.st_uid, owner.st_gid)
            record["status"] = "opt-in-left"
    except OSError as exc:
        record["status"] = "failed"
        record["error"] = f"could not write preinstall marker {record['marker']}: {exc}"
        raise RuntimeError(record["error"]) from exc
    return record


def write_variant_marker(target, preinstalls: bool, gaming: bool) -> Path:
    """Target-side variant record for the desktop opt-in and QEMU asserts."""
    target = Path(target)
    path = target / VARIANT_FILE_REL
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        f"preinstalls={'yes' if preinstalls else 'no'}\n"
        f"gaming={'yes' if gaming else 'no'}\n"
    )
    os.chmod(path, 0o644)
    return path


def _ensure_membership(target: Path, username: str, groups: list[str]) -> None:
    if not groups:
        return
    result = subprocess.run(
        ["arch-chroot", str(target), "usermod", "-aG", ",".join(groups), username],
        check=False, capture_output=True, text=True,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "unknown usermod error").strip()
        raise RuntimeError(f"could not set groups for {username}: {detail}")
def assert_deck_kernel(target) -> None:
    """The restored image must boot linux-omarchy, never stock linux.

    RootImage bakes linux-omarchy into the image; a stock ``linux`` package
    surviving beside it means the per-machine delta added a second kernel
    (C5 violation) and leaves two UKIs fighting over the default. Checked
    from the target's pacman db (no archinstall import: plain glob).
    """
    target = Path(target)
    local_db = target / "var/lib/pacman/local"
    if not local_db.is_dir():
        raise RuntimeError(f"{local_db} is missing; cannot verify the installed kernel")
    omarchy = sorted(p.name for p in local_db.glob("linux-omarchy-[0-9]*") if (p / "desc").is_file())
    if not omarchy:
        raise RuntimeError("linux-omarchy is not installed on the target; nothing Deck-supported to boot")
    stock = sorted(
        p.name for p in local_db.glob("linux-[0-9]*") if (p / "desc").is_file()
    )
    if stock:
        raise RuntimeError(
            "stock kernel still installed on the target ("
            + ", ".join(stock)
            + "); the Deck boots linux-omarchy only -- "
            + ", ".join(omarchy)
        )


def _vet_password_hash(kind: str, password_hash: str) -> str:
    """Refuse an empty or malformed hash before it reaches /etc/shadow.

    crypt(3) hashes have the form ``$id$salt$hash``; an empty field would
    lock (``!``/``*``) or empty the password, and a truncated value fails
    closed at login. ``import crypt`` is unavailable on the 3.14 live ISO,
    so this vets the shape, not the algorithm.
    """
    value = (password_hash or "").strip()
    if not value or value in ("!", "*", "x"):
        raise RuntimeError(f"{kind} password hash is missing or locked; refusing to write it")
    if not value.startswith("$") or value.count("$") < 3 or len(value) < 20:
        raise RuntimeError(
            f"{kind} password hash is malformed ({value[:8]}...); refusing to write it"
        )
    return value
