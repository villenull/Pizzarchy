"""The three load-bearing session settings, baked onto the target.

SHIPPED AS ``/usr/share/omarchy-iso/orchestrator/deck_session_settings.py``.
Two ``configure_deck`` steps -- ``session_dconf`` and ``idle_policy`` --
registered in ``deck_configure.deck_steps``.
``docs/tasks/T5-fork-plan.md`` §5.3.

WHAT THE THREE ARE, AND WHY EACH ONE IS HERE
============================================

Every one of them was discovered by something failing on a screen, never by a
check failing. The constants and the reasoning are ``src/deck-session.sh``'s
(``stage_desktop_settings`` and the block of ``readonly``s above it); this
module carries them onto a machine that has no ``deck-session.sh``.

1. ``org.gnome.desktop.a11y.applications screen-keyboard-enabled = true``.
   squeekboard's auto-show gate. It ships ``false``, and with it unset the
   on-screen keyboard **never** appears on text focus no matter what else is
   correct -- which is how ``docs/PROGRESS.md`` §5.20 was first mis-recorded as
   "focus-triggered show does not work".

2. ``org.gnome.desktop.input-sources sources = [('xkb','us')]``. squeekboard
   warns ``No system layout`` and draws **no keys at all** without an input
   source. Empty by default.

3. Omarchy's idle policy, ``{"screensaver": 150, "lock": 86400}`` in
   ``.config/omarchy/shell.json``. Omarchy ships ``lock = 300``: five idle
   minutes put a keyboard-less handheld behind a password prompt that no
   available on-screen keyboard can reach, because the lock is a layer-shell
   surface.

🔴 TWO MECHANISMS, NOT ONE, AND THAT IS WHY THERE ARE TWO STEPS
===============================================================

Settings 1 and 2 are **dconf site defaults**; setting 3 is a **per-user
dotfile**. They fail differently, they are verified differently, and a single
step would let one missing file take the other down with it. Splitting them also
lets each argue its own record.

⚠️ **Never ``gsettings set``.** The image creates a user we have never met, so a
``gsettings set`` at install time writes one account's database and any later
account gets the broken default back. Site defaults are the only form that
survives the account not existing yet.

⚠️ ``/etc/dconf/db/local.d`` is inert without ``/etc/dconf/profile/user``. With
no profile naming a ``system-db``, dconf reads **only** the user database and
every default here is ignored (``src/deck-session.sh``). The profile is written
first, and a pre-existing profile that does not list the site db is a **refusal**
rather than a blind append: profile order is precedence, and reordering someone
else's profile to make our line fit is a guess with no way to check itself.

⚠️ ``dconf update`` must run **against the target**, in a chroot. A keyfile in
``db/local.d`` does nothing until it is compiled into the binary database at
``/etc/dconf/db/local``; the compiler that has to do it is the target's, for
``deck_patches.py`` decision 1's reason -- a live-side run would compile the
ISO's databases.

🔴 THE VERIFICATION TRAP, WHICH IS THE MOST COPY-PASTEABLE MISTAKE IN §5.3
==========================================================================

``dconf read -d``, **never a plain read**. ``gsettings get`` and a bare ``dconf
read`` resolve through the whole profile and return the *user's* value when one
exists -- so on any machine where someone once set the key by hand the check
passes while the site default is missing or wrong. ``docs/PROGRESS.md`` records
exactly that: a check that passed while the thing it checked was absent. ``-d``
ignores the user database, which is the only reason the check can fail.

🔴 ``/etc/skel`` IS TOO LATE FOR THE USER THIS IMAGE CREATES
============================================================

``docs/tasks/T5-fork-plan.md`` §3 trap (a). ``useradd`` runs inside
``arch_install_system``, **phase 3 of 14**, before this phase. ``/etc/skel`` is
copied at account creation, so a ``shell.json`` written only to skel produces a
Deck whose *first and only* user never gets it -- and a check that reads skel
passes while the product is broken. So the idle policy is written to **both**
skel (for any account made later) **and** the created user's home, and the
**user's copy is the one that is verified**.

⚠️ **A user ``shell.json`` REPLACES Omarchy's defaults rather than merging with
them.** Writing a file containing only an idle block silently strips the bar. An
absent file is therefore *seeded* from
``/usr/share/omarchy/config/omarchy/shell.json`` and then patched as JSON; an
existing one is patched in place. Never regex, never a template.

⚠️ ``lock: 0`` does **not** disable the lock -- it locks **instantly**.
``IdleModel.secondsFromConfig`` rejects only negative and non-finite values, so
0 is accepted and ``lockDelaySeconds === 0`` is the fire-immediately branch.
Disabling means a LARGE timeout, and that timeout has a ceiling:
``lockDelaySeconds * 1000`` feeds a QML ``Timer.interval``, a 32-bit int, so
anything past ~2147483 s (~24.8 days) overflows. ``validate_idle()`` refuses
both ends, because "simplify it to 0" is the obvious-looking edit.

``critical=False`` FOR BOTH, AND THE COUNTER-ARGUMENT STATED HONESTLY
=====================================================================

*Against:* the idle lock is not cosmetic. A Deck that keeps ``lock = 300``
locks itself behind an unanswerable prompt after five idle minutes, which is the
same class of unrecoverable as ``deck_autologin``'s greeter -- and that step is
``critical=True``.

*For ``critical=False``, and this is what won:*

1. **The inputs are upstream-owned and they drift.** Both steps depend on files
   ``omarchy``/``omarchy-dev`` own -- the shipped ``shell.json`` defaults, the
   ``dconf`` binary, the dconf key names. ``deck_patches.py``'s argument 3
   applies unchanged: a rule that turns "upstream moved a config file" into "the
   installer refuses to produce a machine" fails the ISO for a cosmetic reason at
   the most expensive possible moment. ``deck_autologin`` can be ``critical=True``
   precisely because it depends on nothing but the installer's own output.

2. **The lock is not this row's to guarantee.** §5.6 owns "a fresh install must
   not be lockable into a password prompt nobody can answer", and the idle
   timeout is one of *three* producers it lists. The other two -- the sleep-lock
   unit and the menu's ``system.lock`` -- are unaffected by anything here, so
   this step succeeding never made the Deck safe and this step failing never
   made it unsafe on its own.

3. **The machine still boots and still logs in.** Both failures leave a working
   Desktop Mode reachable by controller, which is the line ``deck_configure``'s
   registry rule draws: the degradation is allowed and the silence is not.

⚠️ 🔴 **The honest weakness in point 3, written down rather than glossed.**
``deck_wifi`` and the T12 patch check both leave a channel that speaks on the
*installed* system (a failed unit). Neither step here does: their only report is
``/var/log/omarchy-deck-install.json`` plus the install log, and the [V] QEMU
assertions that read them. That is enough for an automated run and thin for a
user. A first-boot unit for these settings is **owed**, and it is not here
because this slice does not own the ISO asset directory those units are shipped
from.

⚠️ These belong to the **installed system only** (§2.6). They do not go in the
live ISO, where squeekboard does not exist and there is no ``libwayland`` at
all; the installer's keyboard is T8's, drawn by us.
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

from .deck_configure import record_result, sanitize_text
from .deck_user import DeckUserDeferred, DeckUserError, resolve_target_user
from .ui import error, info

# ---------------------------------------------------------------------------
# 1 + 2: the dconf site defaults
# ---------------------------------------------------------------------------

DCONF_PROFILE_REL = "etc/dconf/profile/user"
DCONF_PROFILE_LINES = ("user-db:user", "system-db:local")
# The system database the profile names, and the keyfile directory that feeds
# it. `local` is the db name; `local.d` is where the keyfiles go; `local` (no
# suffix) is the compiled binary `dconf update` produces.
DCONF_SITE_FILE_REL = "etc/dconf/db/local.d/50-deck-desktop"
DCONF_COMPILED_DB_REL = "etc/dconf/db/local"
DCONF_FILE_MODE = 0o644

OSK_KEY = "/org/gnome/desktop/a11y/applications/screen-keyboard-enabled"
INPUT_SOURCES_KEY = "/org/gnome/desktop/input-sources/sources"

# What `dconf read -d` must answer. The input-sources value is checked by
# fragments rather than by string equality because dconf normalises its own
# printing (`[('xkb','us')]` reads back as `[('xkb', 'us')]`), and asserting a
# formatting detail would go red on a dconf release for no reason.
OSK_EXPECTED = "true"
INPUT_SOURCES_FRAGMENTS = ("'xkb'", "'us'")

# ---------------------------------------------------------------------------
# 3: Omarchy's idle policy
# ---------------------------------------------------------------------------

SHELL_JSON_REL = ".config/omarchy/shell.json"
SHELL_JSON_SKEL_REL = f"etc/skel/{SHELL_JSON_REL}"
SHELL_JSON_DEFAULTS_REL = "usr/share/omarchy/config/omarchy/shell.json"
SHELL_JSON_MODE = 0o644

IDLE_SCREENSAVER_SECONDS = 150
IDLE_LOCK_SECONDS = 86400

# lockDelaySeconds * 1000 goes into a QML Timer.interval, a signed 32-bit int.
IDLE_LOCK_MAX_SECONDS = 2147483

MAX_SHELL_JSON_BYTES = 1024 * 1024


class DeckSettingsError(Exception):
    """A step-level failure. Non-critical: see the module docstring."""


# ---------------------------------------------------------------------------
# Talking to the target
# ---------------------------------------------------------------------------


def chroot_command(target, argv) -> list[str]:
    """The exact command a target-side invocation runs.

    Its own function so "it runs inside the target" is assertable without a
    chroot, root, or a container -- the same seam ``deck_patches.chroot_command``
    exists for, and for the same reason: a decision nothing asserts is a comment.
    """
    return ["arch-chroot", str(target), *argv]


def run_in_target(target, argv) -> tuple[int, str]:
    """Run ``argv`` inside the target. Returns (exit code, combined output).

    ``check=False``: a non-zero exit is information this module turns into a
    record, not an accident to raise on.
    """
    proc = subprocess.run(  # noqa: S603
        chroot_command(target, argv),
        capture_output=True,
        text=True,
        check=False,
    )
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


def _runner(runner):
    """``None`` means the module attribute, looked up now.

    Not a default argument: a default binds the function object at *definition*
    time, so replacing the module attribute -- which is how the suites substitute
    it -- would silently keep calling the real ``arch-chroot``.
    """
    return run_in_target if runner is None else runner


# ---------------------------------------------------------------------------
# The dconf step
# ---------------------------------------------------------------------------


def render_site_file() -> str:
    """The keyfile's exact text. Comments included: the next person to read this
    on a Deck has no repository to hand."""
    return (
        "# Installed by configure_deck (omarchy-deck ISO).\n"
        "#\n"
        "# Site DEFAULTS for the Deck, not locks: a user may still change them,\n"
        "# and a user-level value shadows everything here.\n"
        "\n"
        "[org/gnome/desktop/a11y/applications]\n"
        "# squeekboard's auto-show gate. Ships false; without it the on-screen\n"
        "# keyboard never appears on text focus, and nothing logs a reason.\n"
        "screen-keyboard-enabled=true\n"
        "\n"
        "[org/gnome/desktop/input-sources]\n"
        "# squeekboard warns 'No system layout' and has no keys to draw without this.\n"
        "sources=[('xkb','us')]\n"
    )


def install_dconf_profile(target) -> list[str]:
    """Create ``/etc/dconf/profile/user``, or prove an existing one is usable.

    Returns warnings. Raises when the profile exists and does not read the site
    database: appending blind could reorder somebody else's profile, and profile
    order **is** precedence.
    """
    warnings: list[str] = []
    path = Path(target) / DCONF_PROFILE_REL
    if path.exists():
        existing = [line.strip() for line in path.read_text().splitlines()]
        if "system-db:local" not in existing:
            raise DeckSettingsError(
                f"/{DCONF_PROFILE_REL} exists on the target but does not list "
                "'system-db:local', so the site defaults below would never be read. "
                "Refusing to append: profile order is precedence and this step will not guess"
            )
        if "user-db:user" not in existing:
            warnings.append(
                f"/{DCONF_PROFILE_REL} names the site database but no 'user-db:user'; "
                "a user's own settings will not be read"
            )
        return warnings

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(f"{line}\n" for line in DCONF_PROFILE_LINES))
    os.chmod(path, DCONF_FILE_MODE)
    return warnings


def install_site_file(target) -> Path:
    """Write the keyfile. Idempotent -- a fixed name, truncated and rewritten."""
    path = Path(target) / DCONF_SITE_FILE_REL
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink():
        path.unlink()
    path.write_text(render_site_file())
    os.chmod(path, DCONF_FILE_MODE)
    return path


def read_default(target, key: str, runner=None) -> tuple[int, str]:
    """``dconf read -d <key>`` inside the target.

    🔴 ``-d`` is the whole point. See the verification trap in the module
    docstring: without it this reads the *user's* value and passes while the site
    default is absent.
    """
    return _runner(runner)(target, ["dconf", "read", "-d", key])


def configure_dconf(ctx, runner=None) -> dict:
    """Install and compile the site defaults; return the record."""
    target = Path(ctx.target)
    record: dict = {
        "status": None,
        "profile": None,
        "site_file": None,
        "compiled_db": None,
        "defaults": {},
        "error": None,
        "warnings": [],
    }
    warnings: list[str] = record["warnings"]

    try:
        warnings.extend(install_dconf_profile(target))
        record["profile"] = "/" + DCONF_PROFILE_REL
        install_site_file(target)
        record["site_file"] = "/" + DCONF_SITE_FILE_REL

        # A keyfile does nothing until it is compiled. Inside the target: the
        # compiler must be the target's (deck_patches.py decision 1).
        code, output = _runner(runner)(target, ["dconf", "update"])
        if code != 0:
            raise DeckSettingsError(
                f"'dconf update' exited {code} in the target: {sanitize_text(output, limit=200)}. "
                "The site defaults are on disk but not compiled, so nothing reads them"
            )

        compiled = target / DCONF_COMPILED_DB_REL
        if not compiled.is_file() or compiled.stat().st_size == 0:
            raise DeckSettingsError(
                f"'dconf update' reported success but /{DCONF_COMPILED_DB_REL} is missing or "
                "empty. The keyfile was never compiled into the binary database, which is the "
                "only form anything reads"
            )
        record["compiled_db"] = "/" + DCONF_COMPILED_DB_REL

        for key, expected in ((OSK_KEY, OSK_EXPECTED), (INPUT_SOURCES_KEY, None)):
            code, output = read_default(target, key, runner)
            value = output.strip()
            record["defaults"][key] = sanitize_text(value, limit=200)
            if code != 0:
                raise DeckSettingsError(
                    f"'dconf read -d {key}' exited {code} in the target: "
                    f"{sanitize_text(output, limit=200)}"
                )
            if expected is not None:
                if value != expected:
                    raise DeckSettingsError(
                        f"the SITE default for {key} reads '{value or '<empty>'}', not "
                        f"'{expected}' -- the on-screen keyboard would never auto-show for a "
                        "new user"
                    )
            elif not all(fragment in value for fragment in INPUT_SOURCES_FRAGMENTS):
                raise DeckSettingsError(
                    f"the SITE default for {key} reads '{value or '<empty>'}' -- squeekboard "
                    "would have no layout to draw"
                )
    except (DeckSettingsError, OSError) as exc:
        record["status"] = "failed"
        record["error"] = sanitize_text(f"{type(exc).__name__}: {exc}", limit=400)
        error(f"Deck session defaults: {record['error']}")
        for warning in warnings:
            error(f"Deck session defaults: {warning}")
        return record

    record["status"] = "configured"
    info(
        "Deck session defaults compiled into the target's site dconf database "
        f"(verified with 'dconf read -d', not a plain read)"
    )
    for warning in warnings:
        error(f"Deck session defaults: {warning}")
    return record


def session_dconf_step(ctx) -> None:
    """``DeckStep`` entry point. Records under ``session_dconf``.

    No re-raise: ``critical=False``, and the record is the report -- throwing it
    away in order to signal a failure would destroy the thing the install log
    exists for (``deck_wifi``/``deck_patches``, same rule).
    """
    record_result(ctx.target, "session_dconf", configure_dconf(ctx))


# ---------------------------------------------------------------------------
# The idle-policy step
# ---------------------------------------------------------------------------


def validate_idle(screensaver: int = IDLE_SCREENSAVER_SECONDS, lock: int = IDLE_LOCK_SECONDS) -> None:
    """Refuse an idle policy that would lock the Deck out of itself.

    🔴 Its own function, and called before anything is written, because ``lock:
    0`` is the edit that *looks* like disabling the lock and is in fact
    "lock immediately". There is no off sentinel.
    """
    if lock == 0:
        raise DeckSettingsError(
            "idle lock of 0 does NOT disable the lock, it locks INSTANTLY -- "
            "lockDelaySeconds === 0 is the fire-immediately branch. Disabling means a "
            f"LARGE timeout; {IDLE_LOCK_SECONDS} is the chosen constant"
        )
    if lock < 0:
        raise DeckSettingsError(f"idle lock of {lock} is negative; secondsFromConfig rejects it")
    if lock > IDLE_LOCK_MAX_SECONDS:
        raise DeckSettingsError(
            f"idle lock of {lock}s exceeds {IDLE_LOCK_MAX_SECONDS}s: lockDelaySeconds*1000 "
            "overflows the 32-bit QML Timer.interval it feeds"
        )
    if screensaver <= 0:
        raise DeckSettingsError(f"idle screensaver of {screensaver}s would blank the panel at once")


def read_json_file(path: Path) -> dict:
    data = path.read_bytes()
    if len(data) > MAX_SHELL_JSON_BYTES:
        raise DeckSettingsError(f"{path} is {len(data)} bytes; refusing to parse it")
    try:
        doc = json.loads(data.decode("utf-8", "replace"))
    except ValueError as exc:
        raise DeckSettingsError(f"{path} is not valid JSON: {exc}") from exc
    if not isinstance(doc, dict):
        raise DeckSettingsError(f"{path} is not a JSON object")
    return doc


def patch_shell_json(target, rel: str, owner=None) -> dict:
    """Seed-if-absent then patch the idle block of one ``shell.json``.

    ⚠️ **Seeded, never synthesised.** A user ``shell.json`` replaces Omarchy's
    defaults rather than merging with them, so a file containing only an idle
    block strips the bar. If the file is absent and the shipped defaults are not
    on the target either, this raises rather than writing an idle-only file --
    "no idle policy" is a worse Deck than "no bar", but "no bar" is a Deck whose
    breakage nobody can explain.

    Only the ``idle`` block is touched. Everything else -- bar layout, plugins,
    version -- belongs to the file's owner and a rewrite would silently drop it.
    """
    path = Path(target) / rel
    if path.exists() and not path.is_symlink():
        doc = read_json_file(path)
    else:
        defaults = Path(target) / SHELL_JSON_DEFAULTS_REL
        if not defaults.is_file():
            raise DeckSettingsError(
                f"/{rel} is absent and /{SHELL_JSON_DEFAULTS_REL} does not exist on the "
                "target to seed from; writing an idle-only file would strip the bar"
            )
        doc = read_json_file(defaults)
        if path.is_symlink():
            path.unlink()

    idle = doc.get("idle")
    if not isinstance(idle, dict):
        idle = {}
    idle["screensaver"] = IDLE_SCREENSAVER_SECONDS
    idle["lock"] = IDLE_LOCK_SECONDS
    doc["idle"] = idle

    created_dirs: list[Path] = []
    parent = path.parent
    while not parent.exists():
        created_dirs.append(parent)
        parent = parent.parent
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(doc, indent=2) + "\n")
    os.chmod(path, SHELL_JSON_MODE)

    if owner is not None:
        # Every directory this step created, plus the file. A root-owned
        # ~/.config would be a home the desktop cannot write to.
        for directory in created_dirs:
            _chown(directory, owner)
        _chown(path, owner)
    return doc


def _chown(path: Path, owner) -> None:
    """Best-effort chown to the created user. A failure is not silent: it raises,
    because a file the desktop user cannot read is the same outcome as no file."""
    try:
        os.chown(path, owner.uid, owner.gid)
    except PermissionError as exc:
        # Only reachable off-target (a unit suite is not root). Recorded by the
        # caller rather than swallowed here.
        raise DeckSettingsError(f"could not chown {path} to uid {owner.uid}: {exc}") from exc
    except OSError as exc:
        raise DeckSettingsError(f"could not chown {path} to uid {owner.uid}: {exc}") from exc


def verify_shell_json(path: Path, label: str) -> dict:
    """Read the file back the way the shell will, and prove all four facts.

    🔴 The caller points this at the **created user's** copy, not at skel's.
    §3 trap (a): a check that reads only ``/etc/skel`` is the canonical
    passes-for-the-wrong-reason failure for this task.
    """
    if not path.is_file():
        raise DeckSettingsError(
            f"{label} was not written ({path} does not exist). /etc/skel alone is TOO LATE "
            "for the account this image already created -- it is copied at useradd time, "
            "which was phase 3 of 14"
        )
    doc = read_json_file(path)
    idle = doc.get("idle")
    if not isinstance(idle, dict):
        raise DeckSettingsError(f"{label} has no 'idle' object after writing one")

    lock = idle.get("lock")
    screensaver = idle.get("screensaver")
    if lock == 0:
        raise DeckSettingsError(
            f"{label} reads back lock=0, which locks INSTANTLY rather than disabling the "
            "lock -- there is no off sentinel"
        )
    if lock != IDLE_LOCK_SECONDS:
        raise DeckSettingsError(f"{label} reads back lock={lock!r}, expected {IDLE_LOCK_SECONDS}")
    if screensaver != IDLE_SCREENSAVER_SECONDS:
        raise DeckSettingsError(
            f"{label} reads back screensaver={screensaver!r}, expected {IDLE_SCREENSAVER_SECONDS}"
        )
    if len(doc) <= 1:
        raise DeckSettingsError(
            f"{label} now has only {len(doc)} top-level key(s); the rest of Omarchy's config "
            "was lost, which strips the bar"
        )
    return doc


def configure_idle_policy(ctx) -> dict:
    """Write and verify the idle policy on both surfaces; return the record."""
    target = Path(ctx.target)
    record: dict = {
        "status": None,
        "screensaver": IDLE_SCREENSAVER_SECONDS,
        "lock": IDLE_LOCK_SECONDS,
        "skel": None,
        "user": None,
        "user_path": None,
        "top_level_keys": None,
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
        # Skel is not "too late" here, it is exactly right: the account has not
        # been created yet, so it will be copied from skel when it is. This is
        # the ONE case where the skel-only outcome is correct, which is why it
        # is a distinct status rather than a failure.
        deferred = True
        warnings.append(f"{exc}; writing /etc/skel only, which is what a later useradd copies")
    except DeckUserError as exc:
        record["status"] = "failed"
        record["error"] = sanitize_text(f"{type(exc).__name__}: {exc}", limit=400)
        error(f"Deck idle policy: {record['error']}")
        return record

    try:
        validate_idle()

        # Both surfaces. Skel first: it is the cheap one, and if the shipped
        # defaults are missing it fails here before anything touches a home.
        patch_shell_json(target, SHELL_JSON_SKEL_REL)
        record["skel"] = "/" + SHELL_JSON_SKEL_REL
        verify_shell_json(target / SHELL_JSON_SKEL_REL, f"/{SHELL_JSON_SKEL_REL}")

        if deferred:
            record["status"] = "skel-only"
            for warning in warnings:
                error(f"Deck idle policy: {warning}")
            return record

        user_rel = owner.home.lstrip("/") + "/" + SHELL_JSON_REL
        patch_shell_json(target, user_rel, owner=owner)
        user_path = target / user_rel
        record["user_path"] = "/" + user_rel
        doc = verify_shell_json(user_path, f"{owner.name}'s /{user_rel}")
        record["top_level_keys"] = len(doc)
    except (DeckSettingsError, OSError) as exc:
        record["status"] = "failed"
        record["error"] = sanitize_text(f"{type(exc).__name__}: {exc}", limit=400)
        error(f"Deck idle policy: {record['error']}")
        for warning in warnings:
            error(f"Deck idle policy: {warning}")
        return record

    record["status"] = "configured"
    info(
        f"Deck idle policy: screensaver={IDLE_SCREENSAVER_SECONDS}s lock={IDLE_LOCK_SECONDS}s "
        f"in {record['user_path']} (and /etc/skel), {record['top_level_keys']} top-level keys kept"
    )
    for warning in warnings:
        error(f"Deck idle policy: {warning}")
    return record


def idle_policy_step(ctx) -> None:
    """``DeckStep`` entry point. Records under ``idle_policy``."""
    record_result(ctx.target, "idle_policy", configure_idle_policy(ctx))

def configure_sleep_lock_mask(ctx) -> dict:
    target = Path(ctx.target)
    record = {"status": "configured", "error": None}
    mask_path = target / "etc" / "systemd" / "user" / "omarchy-sleep-lock.service"
    try:
        mask_path.parent.mkdir(parents=True, exist_ok=True)
        if mask_path.exists() or mask_path.is_symlink():
            mask_path.unlink()
        mask_path.symlink_to("/dev/null")
        info("Masked omarchy-sleep-lock.service globally.")
    except OSError as exc:
        record["status"] = "failed"
        record["error"] = str(exc)
        error(f"Deck sleep lock mask: {exc}")
    return record

def mask_sleep_lock_step(ctx) -> None:
    record_result(ctx.target, "mask_sleep_lock", configure_sleep_lock_mask(ctx))

