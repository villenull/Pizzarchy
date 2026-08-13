"""Make the installed Deck boot into Gaming Mode without anyone typing.

SHIPPED AS ``/usr/share/omarchy-iso/orchestrator/deck_autologin.py``. The
``autologin`` step registered in ``deck_configure.deck_steps``.
``docs/tasks/T5-fork-plan.md`` §5.1.

WHAT THIS IS
============

On a running Deck the same state is produced by ``deck-session-select gamescope
--no-restart`` (``src/deck-session.sh``, ``stage_session_select`` /
``stage_default_session``). A freshly installed image has no such helper --
nothing in the ``omarchy-deck`` package ships it yet -- so this step writes the
equivalent state directly onto the target. **The reasoning below is carried
across from that script, not re-derived**; where it says "measured" or "found on
hardware", that is where it was found.

🔴 THE THREE PROPERTIES, EACH LEARNED THE HARD WAY
==================================================

1. **``[Autologin]`` needs BOTH ``User=`` and ``Session=``.** With ``Session=``
   alone SDDM ignores the block entirely and shows the greeter -- found on
   hardware, P1.5 phase F, ``docs/PROGRESS.md`` R-16. An earlier
   ``deck-session-select`` wrote ``Session=`` alone on the assumption that
   Omarchy supplied ``User=`` from its own ``autologin.conf``; Omarchy 4.0 ships
   no such file, so autologin never fired and every switch landed on the
   greeter. On a Deck that greeter is a password prompt with no keyboard.

2. **``Relogin=true``, and it is a SAFETY property** (``docs/PROGRESS.md``
   §5.18). SDDM ships ``Relogin=false`` in
   ``/usr/lib/sddm/sddm.conf.d/default.conf``, which means autologin fires
   **once**: if that session dies, SDDM shows the greeter. Measured on hardware,
   soak cycle 4 -- session started, "session closed for user deck" one
   millisecond later, then "Adding new display..." i.e. the greeter. Retrying
   autologin is a loop that can still recover; the alternative is a dead end
   that cannot.

3. **The drop-in must sort LAST in ``/etc/sddm.conf.d``.** SDDM reads
   ``*.conf`` there in lexical order and later files win. The name is not
   cosmetic: an earlier ``95-deck-session.conf`` carried a comment claiming it
   sorted after ``autologin.conf`` -- it does not, ``'9' < 'a'`` -- so
   ``autologin.conf`` overrode it on every machine, and the bug was in a comment
   asserting an ordering nobody checked. ``zz-`` sorts after any plausible
   neighbour, confirmed empirically on this hardware. **This step asserts the
   ordering against the directory as it actually is**, rather than trusting the
   prefix.

THE COUPLING WITH 5.5, WHICH IS WHY THIS STEP IS UNCONDITIONAL
==============================================================

Upstream writes ``autologin.conf`` **only** ``if ctx.encrypt and not
ctx.defer_provisioning`` **(READ:** ``phases_impl.py``'s ``configure_login``**)**
-- encrypted installs get autologin because the LUKS prompt is treated as the
auth boundary. So turning encryption off (§5.5, a separate slice) *deletes*
autologin and lands a keyboard-less Deck on an SDDM password prompt. This step
therefore writes its drop-in **regardless of ``ctx.encrypt``**: it is the thing
that makes §5.5 safe to do, and it must not grow a condition that reintroduces
the coupling.

``critical=True``, AND HERE IS THE ARGUMENT
===========================================

``deck_configure``'s registry rule is that ``critical=False`` is the common
answer, and ``deck_patches.py`` argues at length for it. This step is the
exception, on three counts that do not apply there.

1. **The failure is not a degradation.** A Deck that boots to an SDDM password
   prompt cannot be logged into with a controller at all. That is not "the lock
   screen blanks in 2 s instead of 20 s"; it is a device with no way in, which
   is precisely what ``CLAUDE.md``'s controller-only rule forbids.

2. **🔴 Every other channel is unreadable by the person affected.**
   ``deck_patches.py``'s argument 5 -- "nothing is lost by not aborting", because
   the state file, the failed unit and the install log all survive -- inverts
   here. All three of those channels live *on the installed system*, and the
   user of a machine that cannot log in cannot read any of them. Nor does
   ``ui.py``'s ``error`` help: its own docstring says those lines "land in the
   install log, not on a screen" **(READ)**. The one channel that reaches a human
   is ``phases.py`` turning an exception into a visible failed phase, while the
   operator is still holding the ISO that could re-run.

3. **Nothing upstream-owned is being depended on.** ``deck_patches.py``'s
   argument 3 is that drift is expected monthly, so a hard failure would fire for
   a cosmetic reason. The inputs here are the account the *installer itself*
   created and a directory the *installer itself* wrote to a phase earlier.
   There is no third party to drift.

⚠️ ``critical=True`` is not a licence to abort on anything unusual. The step
aborts only when it cannot guarantee an autologin **at all**; every outcome it
can foresee and still leave a usable machine is a recorded status:

``status="gaming"``    the drop-in names ``gamescope-wayland`` and it exists
``status="desktop"``   no Gaming Mode session on the target, so the drop-in
                       names the desktop session instead -- autologin is intact
                       and the Deck boots to Desktop Mode. Loud, not fatal
``status="deferred"``  ``defer_provisioning``: no account exists yet and
                       ``omarchy-provision-owner`` owns this at first boot
``status="failed"``    no autologin could be guaranteed. Recorded first, then
                       re-raised so ``critical=True`` takes effect

🔴 WHY IT REFUSES TO WRITE A ``Session=`` IT CANNOT RESOLVE
===========================================================

``deck-session-select`` checks the target session's ``.desktop`` exists before
committing, and says why: "Writing a ``Session=`` that SDDM cannot resolve
produces a login loop with no desktop and, under autologin, no session picker to
escape with." The same check is here, and it is the reason ``status="desktop"``
exists -- today's ``iso/PKGS`` is not guaranteed to carry a
``gamescope-wayland.desktop``, and silently writing one anyway would turn a
missing package into an unbootable device.

WHAT THIS STEP DELIBERATELY DOES NOT WRITE
==========================================

``/var/lib/deck-session/next-session``, ``deck-session-select``'s own state
file. That file belongs to a program the target does not have yet; inventing
state for an absent owner would be a second source of truth for the session,
which is the drift this project keeps paying for.
"""

from __future__ import annotations

import os
from pathlib import Path

from .deck_configure import record_result, sanitize_text
from .deck_user import DeckUserDeferred, DeckUserError, read_passwd, resolve_target_user
from .ui import error, info

# --- the sessions, by the names their .desktop files carry -------------------
#
# Same constants as src/deck-session.sh's GAMING_SESSION and the Session= that
# upstream's configure_login writes. Two sources of one string is how this
# project has been bitten before, so if a third appears it belongs in a
# test/unit/test-duplicated-upstream-facts.sh row rather than in another module.
# 🔴 BOTH are BARE basenames, WITHOUT the .desktop extension -- exactly what
# src/deck-session.sh's own constants are ("the basename of the .desktop in a
# wayland-sessions directory, without the extension", its lines 134-137), and
# the format find_session() below requires because it appends `.desktop` itself.
# DESKTOP_SESSION was briefly written as "omarchy.desktop" (WITH the extension),
# which made find_session look for `omarchy.desktop.desktop` -- a file that never
# exists -- so on a real target the desktop fallback resolved to "failed" and,
# because autologin is critical=True, aborted the whole install right after the
# base setup finished. The unit fixture hid it by building its own file from the
# same `{DESKTOP_SESSION}.desktop` expression, so it tested a lookup against a
# file it had named with the bug's own convention. Found by an actual install
# (T4 finding §14); the bare form is asserted against deck-session.sh in
# test-deck-autologin.py §2.
GAMING_SESSION = "gamescope-wayland"
DESKTOP_SESSION = "omarchy"

# Where a .desktop has to exist for SDDM to resolve a Session=. Order and
# contents mirror deck-session-select's own loop.
SESSION_DIRS = ("usr/local/share/wayland-sessions", "usr/share/wayland-sessions")

# --- what gets written -------------------------------------------------------

SDDM_CONF_D_REL = "etc/sddm.conf.d"
# 'zz-' so it sorts last, and the same basename deck-session-select rewrites on
# every switch -- so the image and the on-device tool cannot disagree about
# which file is the session's home. See property 3 in the module docstring.
SDDM_DROPIN_NAME = "zz-deck-session.conf"
SDDM_DROPIN_REL = f"{SDDM_CONF_D_REL}/{SDDM_DROPIN_NAME}"
SDDM_DROPIN_MODE = 0o644

# SDDM's own record of the last session/user. Not the switch -- [Autologin] is
# the switch -- but the greeter pre-selects from it, so leaving it saying
# 'omarchy' while [Autologin] says gamescope would make the two disagree
# the moment anything did show a greeter.
SDDM_STATE_REL = "var/lib/sddm/state.conf"
SDDM_STATE_MODE = 0o600
SDDM_USER = "sddm"

# The keys whose presence is re-read off the disk after writing. All three, and
# the list is the point: Session= alone is R-16's silent failure and Relogin=
# missing is §5.18's.
REQUIRED_KEYS = ("User", "Session", "Relogin")

AUTOLOGIN_SECTION = "[Autologin]"


class DeckAutologinError(Exception):
    """No autologin could be guaranteed. See ``critical=True`` above."""


# ---------------------------------------------------------------------------
# Which session
# ---------------------------------------------------------------------------


def find_session(target, session: str) -> str | None:
    """The in-target path of ``session``'s ``.desktop``, or None.

    Its own function so the refusal in the module docstring is assertable
    without a target that has a display manager on it.
    """
    for rel in SESSION_DIRS:
        candidate = Path(target) / rel / f"{session}.desktop"
        if candidate.is_file():
            return "/" + rel + f"/{session}.desktop"
    return None


def choose_session(target) -> tuple[str, str, str | None]:
    """(session, status, path). Gaming Mode if it is installed, else the desktop.

    ``status`` is the record's status, so the caller never has to re-derive
    "which of the two did we settle for" from the session name.
    """
    path = find_session(target, GAMING_SESSION)
    if path is not None:
        return GAMING_SESSION, "gaming", path
    path = find_session(target, DESKTOP_SESSION)
    if path is not None:
        return DESKTOP_SESSION, "desktop", path
    return "", "failed", None


# ---------------------------------------------------------------------------
# The drop-in
# ---------------------------------------------------------------------------


def render_dropin(user: str, session: str) -> str:
    """The file's exact text.

    The comment is part of the artefact, not decoration: the next person to read
    this file on a Deck has no repository to hand, and the ``Relogin=`` line is
    the one that looks most like it could be deleted for tidiness.
    """
    return (
        "# Written by configure_deck (omarchy-deck ISO) at install time, and\n"
        "# rewritten by deck-session-select on every session switch. Named to\n"
        "# sort LAST in /etc/sddm.conf.d so this Session= wins.\n"
        f"{AUTOLOGIN_SECTION}\n"
        "# User= is required, not optional: SDDM applies [Autologin] only when\n"
        "# BOTH User= and Session= are present (found on hardware, PROGRESS.md\n"
        "# R-16 -- with Session= alone it silently shows the greeter instead).\n"
        f"User={user}\n"
        f"Session={session}\n"
        "# Relogin=true is a SAFETY property, not a convenience (PROGRESS.md\n"
        "# 5.18). SDDM ships Relogin=false, so autologin fires ONCE: if that\n"
        "# session dies, SDDM shows a password greeter that no controller can\n"
        "# answer. Retrying is a loop that can recover; the default is a dead end.\n"
        "Relogin=true\n"
    )


def parse_autologin(text: str) -> dict[str, str]:
    """The key=value pairs that are inside ``[Autologin]`` -- and only those.

    🔴 A plain "is ``User=`` in the file" check would pass for a ``User=`` that
    landed under some other section header, where SDDM does not look. The
    section is tracked so the assertion means what it says.
    """
    section = ""
    found: dict[str, str] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line
            continue
        if section != AUTOLOGIN_SECTION or "=" not in line:
            continue
        key, _, value = line.partition("=")
        found.setdefault(key.strip(), value.strip())
    return found


def write_dropin(target, user: str, session: str) -> Path:
    """Write the drop-in, then read it back and prove all three keys are there.

    Idempotent: a fixed filename that is truncated and rewritten, so a re-run
    replaces its own work instead of accumulating a second autologin file for
    the two to fight over.
    """
    dest = Path(target) / SDDM_DROPIN_REL
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.is_symlink():
        # A symlink here would redirect a root write out of the target.
        dest.unlink()
    dest.write_text(render_dropin(user, session))
    os.chmod(dest, SDDM_DROPIN_MODE)

    found = parse_autologin(dest.read_text())
    # An EMPTY value is a missing value here. `User=` with nothing after it is
    # still a line SDDM cannot resolve, and a readback that only asked "is the
    # key there?" would report the file as correct.
    missing = [key for key in REQUIRED_KEYS if not found.get(key)]
    if missing:
        raise DeckAutologinError(
            f"wrote /{SDDM_DROPIN_REL} but {', '.join(missing)} is not in its "
            f"{AUTOLOGIN_SECTION} section on re-read"
        )
    if found["User"] != user:
        raise DeckAutologinError(
            f"/{SDDM_DROPIN_REL} reads back User={found['User']!r}, not {user!r} -- "
            "SDDM ignores [Autologin] without a User= that resolves"
        )
    if found["Session"] != session:
        raise DeckAutologinError(
            f"/{SDDM_DROPIN_REL} reads back Session={found['Session']!r}, not {session!r}"
        )
    if found["Relogin"] != "true":
        raise DeckAutologinError(
            f"/{SDDM_DROPIN_REL} reads back Relogin={found['Relogin']!r}, not 'true' -- "
            "without it a session that dies leaves a password greeter no controller can answer"
        )
    return dest


def conf_d_entries(target) -> list[str]:
    """Every ``*.conf`` SDDM will read from the drop-in directory, sorted."""
    directory = Path(target) / SDDM_CONF_D_REL
    try:
        names = [p.name for p in directory.iterdir() if p.name.endswith(".conf") and p.is_file()]
    except OSError:
        return []
    return sorted(names)


def assert_sorts_last(target) -> list[str]:
    """Raise unless our drop-in is the last ``*.conf`` in the directory.

    🔴 Asserted against the directory as it *is*, not against the prefix. The
    defect that actually shipped was a name assumed to sort after
    ``autologin.conf`` on the strength of a comment; only reading the real
    neighbours can catch its successor.
    """
    entries = conf_d_entries(target)
    if not entries:
        raise DeckAutologinError(
            f"/{SDDM_CONF_D_REL} lists no *.conf at all after writing one -- "
            "the write did not land where SDDM reads"
        )
    if entries[-1] != SDDM_DROPIN_NAME:
        raise DeckAutologinError(
            f"{SDDM_DROPIN_NAME} does not sort last in /{SDDM_CONF_D_REL} "
            f"(order: {', '.join(entries)}). SDDM reads *.conf in lexical order and LATER "
            f"files win, so {entries[-1]} would override our Session= and the Deck would "
            "not boot to Gaming Mode"
        )
    return entries


# ---------------------------------------------------------------------------
# SDDM's own state file
# ---------------------------------------------------------------------------


def write_state_conf(target, user: str, session: str) -> tuple[str | None, list[str]]:
    """Point ``/var/lib/sddm/state.conf`` at the same session. Never fatal.

    Upstream's ``configure_login`` writes this file and then ``chown``s it
    ``sddm:sddm`` **(READ)**, so by our phase it normally exists with the right
    owner -- which is why it is **truncated in place** rather than unlinked and
    recreated: truncating keeps the inode and therefore keeps the ownership. If
    it is absent (a deferred install, or upstream changing its mind) it is
    created and chowned to the target's own ``sddm`` uid, read out of the
    target's ``/etc/passwd`` rather than assumed.

    Returns (path or None, warnings). A failure here is a warning: the greeter's
    pre-selection is cosmetic next to ``[Autologin]``, and losing the whole step
    over it would be a worse trade.
    """
    warnings: list[str] = []
    dest = Path(target) / SDDM_STATE_REL
    existed = dest.is_file() and not dest.is_symlink()
    try:
        dest.parent.mkdir(parents=True, exist_ok=True)
        if dest.is_symlink():
            dest.unlink()
            existed = False
        dest.write_text(f"[Last]\nSession={session}\nUser={user}\n")
    except OSError as exc:
        warnings.append(f"could not write /{SDDM_STATE_REL}: {exc}")
        return None, warnings

    if not existed:
        warnings.append(
            f"/{SDDM_STATE_REL} did not exist; it was created here rather than by "
            "the installer's own configure_login"
        )
        try:
            accounts = read_passwd(target)
        except DeckUserError as exc:
            accounts = {}
            warnings.append(f"could not look up the {SDDM_USER} account on the target: {exc}")
        if SDDM_USER in accounts:
            uid, gid, _ = accounts[SDDM_USER]
            try:
                os.chown(dest, uid, gid)
                os.chmod(dest, SDDM_STATE_MODE)
            except OSError as exc:
                warnings.append(
                    f"/{SDDM_STATE_REL} could not be chowned to {SDDM_USER}: {exc} -- "
                    "SDDM will not be able to update its own state file"
                )
        elif accounts:
            warnings.append(
                f"the target has no '{SDDM_USER}' account, so /{SDDM_STATE_REL} stays root-owned"
            )
    return "/" + SDDM_STATE_REL, warnings


# ---------------------------------------------------------------------------
# The step
# ---------------------------------------------------------------------------


def configure_autologin(ctx) -> dict:
    """Produce the autologin state on ``ctx.target`` and return the record."""
    target = Path(ctx.target)
    record: dict = {
        "status": None,
        "user": None,
        "uid": None,
        "session": None,
        "session_desktop": None,
        "dropin": None,
        "sorts_last": None,
        "conf_d": [],
        "state_conf": None,
        "error": None,
        "warnings": [],
    }
    warnings: list[str] = record["warnings"]

    try:
        user, user_warnings = resolve_target_user(ctx)
    except DeckUserDeferred as exc:
        # Not a failure: upstream deletes autologin.conf on this path on purpose
        # and omarchy-provision-owner writes it at first boot. Loud anyway --
        # nobody has checked that omarchy-provision-owner writes a *gamescope*
        # session, so a deferred install is NOT known to reach Gaming Mode.
        record["status"] = "deferred"
        record["error"] = sanitize_text(
            f"{exc}. Gaming Mode was NOT baked in as the default session: the "
            "first-boot provisioner decides, and it has never been checked against this "
            "requirement.",
            limit=400,
        )
        error(f"Deck autologin: {record['error']}")
        return record
    except DeckUserError as exc:
        record["status"] = "failed"
        record["error"] = sanitize_text(f"{type(exc).__name__}: {exc}", limit=400)
        error(f"Deck autologin: {record['error']}")
        return record

    warnings.extend(user_warnings)
    record["user"] = sanitize_text(user.name)
    record["uid"] = user.uid

    session, status, session_path = choose_session(target)
    record["session_desktop"] = session_path
    if status == "failed":
        record["status"] = "failed"
        record["error"] = sanitize_text(
            f"neither {GAMING_SESSION}.desktop nor {DESKTOP_SESSION}.desktop exists in "
            f"{' or '.join('/' + d for d in SESSION_DIRS)} on the target, so there is no "
            "session to log in to. Refusing to write a Session= SDDM cannot resolve: under "
            "autologin that is a login loop with no session picker to escape with.",
            limit=400,
        )
        error(f"Deck autologin: {record['error']}")
        return record

    record["session"] = session

    try:
        write_dropin(target, user.name, session)
        record["dropin"] = "/" + SDDM_DROPIN_REL
        record["conf_d"] = assert_sorts_last(target)
        record["sorts_last"] = True
    except (DeckAutologinError, OSError) as exc:
        record["status"] = "failed"
        record["sorts_last"] = False if record["dropin"] else None
        record["conf_d"] = conf_d_entries(target)
        record["error"] = sanitize_text(f"{type(exc).__name__}: {exc}", limit=400)
        error(f"Deck autologin: {record['error']}")
        return record

    state_path, state_warnings = write_state_conf(target, user.name, session)
    record["state_conf"] = state_path
    warnings.extend(state_warnings)

    record["status"] = status
    if status == "desktop":
        # A degradation, and one the operator must not have to infer from a
        # session name: the machine boots and logs in, just not into Gaming Mode.
        record["error"] = sanitize_text(
            f"{GAMING_SESSION}.desktop is not installed on the target, so autologin was "
            f"pointed at {DESKTOP_SESSION}.desktop instead. The Deck boots to Desktop Mode, not "
            "Gaming Mode. The ISO's package set is missing the Gaming Mode session.",
            limit=400,
        )
        error(f"Deck autologin: {record['error']}")
    else:
        info(f"Autologin set: {user.name} -> {session} (/{SDDM_DROPIN_REL}, sorts last)")

    for warning in warnings:
        error(f"Deck autologin: {warning}")
    return record


def autologin_step(ctx) -> None:
    """``DeckStep`` entry point.

    🔴 **Records first, then raises.** ``deck_configure``'s registry catches an
    exception and writes ``{"status": "error"}`` under the step's key -- which
    would replace this step's detailed record with a one-line summary of the
    exception. Writing the record before re-raising keeps the diagnosis *and*
    lets ``critical=True`` halt the install. Nothing else in the registry needs
    this because nothing else in it is critical.
    """
    record = configure_autologin(ctx)
    record_result(ctx.target, "autologin", record)
    if record["status"] == "failed":
        raise DeckAutologinError(
            record["error"] or "no autologin could be guaranteed on the target"
        )
