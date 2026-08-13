"""Who the installed system's one human account actually is.

SHIPPED AS ``/usr/share/omarchy-iso/orchestrator/deck_user.py``. **Not a step.**
A shared helper for the ``configure_deck`` steps that have to write something
into a specific account -- 5.1's autologin ``User=`` and 5.3's per-user
``shell.json`` -- because both of them get it wrong in the same way if they
guess.

WHY THIS IS A FILE AND NOT ONE LINE OF ``ctx.username``
=======================================================

``docs/tasks/T5-fork-plan.md`` §3 trap (a) is the reason this whole module
exists in the shape it does: **the user is created in phase 3 of 14**
(``arch_install_system``), long before ``configure_deck`` runs, so by our phase
the account is a fact on the target's filesystem rather than an intention. Two
different things can therefore be asked, and only one of them is worth
believing:

``ctx.username``
    what the *installer was told* to create. It reads
    ``user_credentials["users"][0]["username"]``, and on a
    ``defer_provisioning`` install it is deliberately the empty string
    **(READ:** upstream ``context.py``'s ``username`` property**)**.

``<target>/etc/passwd``
    what archinstall *actually created*, with the uid, gid and home directory
    that go with it.

This module reads the first and then **confirms it against the second**, and
refuses to hand back a user it could not confirm. The failure it exists to stop
is not exotic: an autologin drop-in naming an account that does not exist is
accepted by SDDM, fails at PAM, and leaves a Deck sitting at a greeter -- the
same unanswerable password prompt ``docs/PROGRESS.md`` §5.18 is about, reached
by a different route. And a ``shell.json`` written to a *guessed* home is
`docs/tasks/T5-fork-plan.md` §3 trap (a) in its purest form: the file exists,
the check passes, and the user who boots the machine never sees it.

🔴 **The home directory is read from ``/etc/passwd``, never composed as
``/home/<name>``.** Same rule, same reason. ``useradd`` honours ``-d``, and this
project has already paid once for a verification that read the place a file was
supposed to be instead of the place the product reads.

WHY NOT ``getent`` / ``arch-chroot getent``
===========================================

``/etc/passwd`` on the target is a flat text file that is complete by our phase,
and parsing it needs no chroot, no root and no subprocess -- so the unit suite
exercises the *real* resolution path rather than a mock of it. NSS modules that
would make ``getent`` see more than the file (LDAP, systemd-homed) are not in
play on a freshly pacstrapped Deck, and if they ever were, an account this
installer created would still be in the file.

⚠️ ``DeckUserDeferred`` is a **subclass** of ``DeckUserError`` on purpose: a
caller that forgets to branch on the deferred case gets the safe behaviour
(treated as a failure to resolve) rather than a ``None`` that silently writes
``User=``. Callers that *do* care must catch it first.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

# The target-relative account database. Relative so every path in this module is
# composed through the target mount and none of them can accidentally read or
# describe the LIVE ISO's accounts.
PASSWD_REL = "etc/passwd"

# A pathological /etc/passwd is not a thing a correct install produces, but this
# is a root process reading a file into memory and the cap costs nothing.
MAX_PASSWD_BYTES = 4 * 1024 * 1024

# Below this, an account is a system account. Not fatal -- an installer is
# allowed to create whatever it likes -- but recorded, because an autologin into
# a system account is a strong sign the wrong field was read.
FIRST_ORDINARY_UID = 1000


class DeckUserError(Exception):
    """The installed system's human account could not be established."""


class DeckUserDeferred(DeckUserError):
    """There is no account yet, by design.

    ``defer_provisioning`` installs create no user at all: upstream's
    ``configure_login`` deletes ``autologin.conf`` and leaves the account, the
    autologin and the SDDM state to ``omarchy-provision-owner`` at first boot
    **(READ:** ``phases_impl.py``'s ``configure_login``**)**. That is a
    different fact from "we could not find the user", and a step that conflated
    them would either abort every deferred install or write ``User=`` with an
    empty value.
    """


@dataclass(frozen=True)
class TargetUser:
    """A confirmed account on the target.

    ``home`` is the path **inside the installed system** (``/home/deck``), not
    inside the target mount. ``home_on(target)`` is the only supported way to
    turn it into a path this process can open, so no caller has to remember to
    strip the leading slash.
    """

    name: str
    uid: int
    gid: int
    home: str

    def home_on(self, target) -> Path:
        return Path(target) / self.home.lstrip("/")


def parse_passwd(text: str) -> dict[str, tuple[int, int, str]]:
    """``{name: (uid, gid, home)}`` from ``/etc/passwd`` text.

    Malformed lines are skipped rather than raising: one unparsable line in a
    file we did not write must not cost us the account we came for. A line with
    a non-numeric uid is skipped for the same reason -- and because believing it
    would be worse than not seeing it.
    """
    users: dict[str, tuple[int, int, str]] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split(":")
        if len(fields) < 7:
            continue
        name, _, uid, gid, _, home, _ = fields[:7]
        if not name:
            continue
        try:
            uid_n, gid_n = int(uid), int(gid)
        except ValueError:
            continue
        # First wins: a duplicated account name is a broken passwd file, and the
        # first entry is the one every getent-alike resolves to.
        users.setdefault(name, (uid_n, gid_n, home))
    return users


def read_passwd(target) -> dict[str, tuple[int, int, str]]:
    path = Path(target) / PASSWD_REL
    try:
        data = path.read_bytes()
    except OSError as exc:
        raise DeckUserError(
            f"cannot read /{PASSWD_REL} on the target: {exc} -- "
            "without it the installed system's account cannot be confirmed"
        ) from exc
    if len(data) > MAX_PASSWD_BYTES:
        raise DeckUserError(f"/{PASSWD_REL} on the target is {len(data)} bytes; refusing to parse it")
    return parse_passwd(data.decode("utf-8", "replace"))


def resolve_target_user(ctx) -> tuple[TargetUser, list[str]]:
    """The confirmed account, plus warnings. Raises rather than guessing.

    Order matters. The deferred case is checked **first**, because on a deferred
    install ``ctx.username`` is legitimately empty and every check after this
    one would report that emptiness as a fault.
    """
    warnings: list[str] = []

    if getattr(ctx, "defer_provisioning", False):
        raise DeckUserDeferred(
            "this is a defer_provisioning install: no account exists yet, and "
            "omarchy-provision-owner creates it -- with its autologin and SDDM state -- at first boot"
        )

    try:
        name = ctx.username
    except Exception as exc:  # noqa: BLE001 -- upstream raises RuntimeError; do not depend on the type
        raise DeckUserError(
            f"the installer's credentials name no user ({type(exc).__name__}: {exc})"
        ) from exc

    if not name:
        raise DeckUserError(
            "the installer's credentials name an empty user, and this is not a "
            "defer_provisioning install -- there is nothing to log in as"
        )
    if name == "root":
        raise DeckUserError(
            "the installer names 'root' as the account. Refusing: a root graphical "
            "autologin is not what a Deck should boot into, and src/deck-session.sh's "
            "stage_session_select refuses the same value for the same reason"
        )

    users = read_passwd(ctx.target)
    if name not in users:
        raise DeckUserError(
            f"the installer says the account is '{name}', but the target's /{PASSWD_REL} "
            f"has no such user ({len(users)} account(s) present). The account was never "
            "created, so anything written for it would be written for nobody"
        )

    uid, gid, home = users[name]
    if uid == 0:
        raise DeckUserError(
            f"'{name}' is uid 0 on the target. Refusing to treat a uid-0 account as the "
            "desktop user"
        )
    if uid < FIRST_ORDINARY_UID:
        warnings.append(
            f"'{name}' is uid {uid} on the target, below the first ordinary uid "
            f"({FIRST_ORDINARY_UID}) -- this looks like a system account"
        )
    if not home or not home.startswith("/"):
        raise DeckUserError(
            f"'{name}' has home '{home}' in the target's /{PASSWD_REL}, which is not an "
            "absolute path. A per-user file cannot be placed from that"
        )

    user = TargetUser(name=name, uid=uid, gid=gid, home=home)
    if not user.home_on(ctx.target).is_dir():
        # Not fatal: the caller creates what it needs and chowns it. Recorded
        # because an absent home means archinstall's user creation did something
        # other than what this phase assumes.
        warnings.append(f"'{name}'s home {home} does not exist on the target yet")
    return user, warnings
