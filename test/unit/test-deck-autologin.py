#!/usr/bin/env python3
"""Unit tests for `configure_deck`'s `autologin` step — T5 §5.1, "boot to Gaming
Mode by default" (`deck_autologin.py`, and the account resolution in
`deck_user.py` that it and the idle-policy step share).

No VM, no root, no network, no chroot, no ISO build, nothing against the Deck:

    python3 test-deck-autologin.py

WHAT THIS SUITE IS ACTUALLY FOR
===============================

Every assertion below is made against a **scratch target filesystem this suite
builds**, by executing the step against it and reading the artefact back. None
of it greps the module's own source: a test that reads the code it is testing
agrees with it by construction.

The four facts it exists to defend, all of them things that have already shipped
broken once:

1. 🔴 **`[Autologin]` needs BOTH `User=` and `Session=`.** With `Session=` alone
   SDDM ignores the block and shows a greeter — found on hardware, P1.5 phase F,
   `docs/PROGRESS.md` R-16. On a Deck that greeter is a password prompt with no
   keyboard.

2. 🔴 **`Relogin=true`.** SDDM ships `Relogin=false`, so autologin fires once and
   a session that dies lands on the same unanswerable greeter (§5.18).

3. 🔴 **The drop-in must sort LAST in `/etc/sddm.conf.d`.** The bug that actually
   shipped was a `95-…` name carrying a *comment* claiming it sorted after
   `autologin.conf`. So the ordering is asserted against a directory containing
   the real neighbours upstream's `configure_login` writes, not against the
   prefix.

4. 🔴 **The account is read, not guessed.** It is created in phase 3 of 14, so by
   this phase it is a fact in the target's `/etc/passwd` — including its home
   directory, which is what §3 trap (a) turns on.

The harness uses the **real `ui.py` and the real `context.py`** from
`iso/upstream`, and drives the step through a genuine `InstallContext`. So an
upstream rename of `info`/`error`, or of the `username` property, goes red here
rather than at install time.
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import pathlib
import shutil
import stat
import sys
import tempfile

# ⚠️ Before importing anything under test. Python validates a cached .pyc against
# (mtime, size) at one-second granularity, so a same-size edit inside the same
# second silently runs the PREVIOUS version — exactly what mutation testing
# produces.
sys.dont_write_bytecode = True

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
OVERLAY_ORCH = (
    REPO_ROOT / "iso/overlay/configs/airootfs/usr/share/omarchy-iso/orchestrator"
)
UPSTREAM_ORCH = (
    REPO_ROOT / "iso/upstream/configs/airootfs/usr/share/omarchy-iso/orchestrator"
)
# The authority on what these settings ARE. Read, never copied: a handful of
# assertions below are derived from it so the image and the on-device tool
# cannot disagree about the session name or the drop-in's basename.
DECK_SESSION_SH = REPO_ROOT / "src/deck-session.sh"

FAILURES = 0
CHECKS = 0


def check(what: str, got, want) -> None:
    global FAILURES, CHECKS
    CHECKS += 1
    if got == want:
        print(f"ok   {what}")
    else:
        print(f"FAIL {what}: got {got!r}, want {want!r}")
        FAILURES += 1


def check_true(what: str, got) -> None:
    check(what, bool(got), True)


def check_raises(what: str, fn, exc_types) -> None:
    global FAILURES, CHECKS
    CHECKS += 1
    try:
        fn()
    except exc_types:
        print(f"ok   {what}")
        return
    except Exception as exc:  # noqa: BLE001
        print(f"FAIL {what}: raised {type(exc).__name__}: {exc}, wanted {exc_types}")
        FAILURES += 1
        return
    print(f"FAIL {what}: did not raise")
    FAILURES += 1


# ---------------------------------------------------------------------------
# Harness: rebuild the orchestrator package shape around the modules
# ---------------------------------------------------------------------------

WORK = pathlib.Path(tempfile.mkdtemp(prefix="deck-autologin-test-"))

PHASES_IMPL_STUB = '''
"""Stub."""


def __getattr__(name):
    def phase(ctx):
        raise AssertionError(f"stub phase {name} should not run")

    phase.__name__ = name
    return phase
'''


def build_package() -> pathlib.Path:
    root = pathlib.Path(tempfile.mkdtemp(prefix="orch-", dir=WORK))
    pkg = root / "orchestrator"
    pkg.mkdir()
    (pkg / "__init__.py").write_text("")
    # The REAL ui.py and context.py from the pinned upstream tree, not stubs.
    # ui.py so a renamed info/error goes red; context.py so `ctx.username` is
    # upstream's property rather than this suite's idea of it.
    for name in ("ui.py", "context.py"):
        shutil.copyfile(UPSTREAM_ORCH / name, pkg / name)
    for module in sorted(OVERLAY_ORCH.glob("deck_*.py")):
        shutil.copyfile(module, pkg / module.name)
    (pkg / "phases_impl.py").write_text(PHASES_IMPL_STUB)
    return root


PKG_ROOT = build_package()
sys.path.insert(0, str(PKG_ROOT))

from orchestrator import deck_autologin, deck_configure, deck_user  # noqa: E402
from orchestrator.context import InstallContext  # noqa: E402

print(f"# modules loaded from {PKG_ROOT}")

# The uid/gid the scratch homes are chowned to. os.getuid() rather than a
# literal 1000: chowning a file to yourself is permitted for a non-root process,
# so the REAL chown path runs here instead of being stubbed out.
TEST_UID = os.getuid()
TEST_GID = os.getgid()


def tmpdir(name: str) -> pathlib.Path:
    d = WORK / name
    d.mkdir(parents=True, exist_ok=True)
    return d


def mode_of(path: pathlib.Path) -> str:
    return f"{stat.S_IMODE(os.lstat(path).st_mode):04o}"


def make_ctx(target, username="deck", defer=False) -> InstallContext:
    """A genuine upstream InstallContext pointed at a scratch target."""
    users = [] if defer else [{"username": username}]
    return InstallContext(
        config_path=pathlib.Path("/dev/null"),
        creds_path=pathlib.Path("/dev/null"),
        full_name="Test User",
        email="t@example.invalid",
        encrypt=False,
        authorized_keys_path=None,
        tailscale_authkey_path=None,
        user_configuration={},
        user_credentials={"users": users},
        arch_config_path=pathlib.Path("/dev/null"),
        omarchy_install={},
        defer_provisioning=defer,
        target=pathlib.Path(target),
    )


def make_target(
    name: str,
    *,
    username: str = "deck",
    uid: int | None = None,
    home: str | None = None,
    make_home: bool = True,
    gaming_session: bool = True,
    desktop_session: bool = True,
    session_dir: str = "usr/share/wayland-sessions",
    neighbours: bool = True,
    sddm_account: bool = False,
    state_conf: bool = True,
) -> pathlib.Path:
    """A scratch target shaped like one this phase would really find.

    `neighbours` writes the two files upstream's `configure_login` leaves in
    /etc/sddm.conf.d a phase earlier. They are what makes the sort-last
    assertion mean anything: against a directory holding only our own file, any
    name sorts last.
    """
    target = tmpdir(name) / "mnt"
    uid = TEST_UID if uid is None else uid
    home = home if home is not None else f"/home/{username}"

    (target / "etc").mkdir(parents=True, exist_ok=True)
    passwd = ["root:x:0:0::/root:/bin/bash"]
    if sddm_account:
        passwd.append(f"sddm:x:{TEST_UID}:{TEST_GID}::/var/lib/sddm:/usr/bin/nologin")
    if username:
        passwd.append(f"{username}:x:{uid}:{TEST_GID}::{home}:/bin/bash")
    (target / "etc/passwd").write_text("\n".join(passwd) + "\n")
    if make_home and home.startswith("/"):
        (target / home.lstrip("/")).mkdir(parents=True, exist_ok=True)

    sessions = target / session_dir
    sessions.mkdir(parents=True, exist_ok=True)
    if gaming_session:
        (sessions / f"{deck_autologin.GAMING_SESSION}.desktop").write_text("[Desktop Entry]\n")
    if desktop_session:
        (sessions / f"{deck_autologin.DESKTOP_SESSION}.desktop").write_text("[Desktop Entry]\n")

    conf_d = target / deck_autologin.SDDM_CONF_D_REL
    conf_d.mkdir(parents=True, exist_ok=True)
    if neighbours:
        # Verbatim shapes from upstream's configure_login (READ).
        (conf_d / "99-omarchy-login.conf").write_text(
            "[Theme]\nCurrent=omarchy\n\n[Users]\nRememberLastUser=true\n"
        )
        (conf_d / "autologin.conf").write_text(
            f"[Autologin]\nUser={username}\nSession=omarchy\n"
        )
    if state_conf:
        state = target / deck_autologin.SDDM_STATE_REL
        state.parent.mkdir(parents=True, exist_ok=True)
        state.write_text("[Last]\nSession=omarchy\nUser=deck\n")
    return target


def run_step(ctx):
    """configure_autologin with the console captured, so 'loud' can be asserted."""
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        record = deck_autologin.configure_autologin(ctx)
    return record, buf.getvalue()


def dropin_text(target) -> str:
    return (target / deck_autologin.SDDM_DROPIN_REL).read_text()


print("\n## 1. the payload exists and compiles")

for f in (OVERLAY_ORCH / "deck_autologin.py", OVERLAY_ORCH / "deck_user.py", DECK_SESSION_SH):
    check_true(f"present: {f.relative_to(REPO_ROOT)}", f.is_file())
for name in ("deck_autologin.py", "deck_user.py"):
    check(f"{name} compiles", os.system(f"python3 -m py_compile {OVERLAY_ORCH / name} 2>/dev/null"), 0)

# guard 6.4a greps the whole orchestrator directory for /usr/bin/omarchy-* and
# fails the build unless every match is shipped by a known provider. Neither of
# these modules calls one, and a future edit that does must know it is signing
# up for that guard.
import re  # noqa: E402

for name in ("deck_autologin.py", "deck_user.py"):
    check(
        f"guard 6.4a: {name} references no /usr/bin/omarchy-* binary",
        re.findall(r"/usr/bin/omarchy-[A-Za-z0-9._-]+", (OVERLAY_ORCH / name).read_text()),
        [],
    )


print("\n## 2. the constants agree with src/deck-session.sh, the on-device authority")

session_sh = DECK_SESSION_SH.read_text()
gaming = re.search(r"^readonly GAMING_SESSION=(\S+)", session_sh, re.M)
dropin = re.search(r"^readonly SDDM_DROPIN=(\S+)", session_sh, re.M)
check_true("scraped GAMING_SESSION out of deck-session.sh (an empty scrape is not a pass)", gaming)
check_true("scraped SDDM_DROPIN out of deck-session.sh", dropin)
check(
    "🔴 the session this step writes is the one deck-session-select switches to",
    deck_autologin.GAMING_SESSION,
    gaming.group(1) if gaming else None,
)
check(
    "🔴 …and the drop-in is the same FILE, so the image and the on-device tool "
    "cannot disagree about where the session lives",
    "/" + deck_autologin.SDDM_DROPIN_REL,
    dropin.group(1) if dropin else None,
)
check("…which is a zz- name, i.e. one that can sort last", deck_autologin.SDDM_DROPIN_NAME.startswith("zz-"), True)

# 🔴 Both session constants MUST be bare basenames with NO .desktop extension:
# find_session() appends `.desktop` itself, and deck-session.sh's authority is
# explicit ("the basename ... without the extension"). A constant carrying the
# extension makes find_session look for `<name>.desktop.desktop`, which never
# exists -- the exact bug that shipped as DESKTOP_SESSION="omarchy.desktop" and
# aborted a real install after the base setup finished (T4 finding §14). This is
# NON-tautological on purpose: it checks the STRING, not a fixture the test itself
# named with the same expression the code uses.
check(
    "🔴 GAMING_SESSION is a bare basename, no .desktop suffix (find_session appends it)",
    deck_autologin.GAMING_SESSION.endswith(".desktop"),
    False,
)
check(
    "🔴 DESKTOP_SESSION is a bare basename, no .desktop suffix -- the omarchy.desktop.desktop bug",
    deck_autologin.DESKTOP_SESSION.endswith(".desktop"),
    False,
)
# And DESKTOP_SESSION is the desktop session deck-session.sh resolves FIRST
# (its `for cand in omarchy hyprland-uwsm hyprland` loop), same as GAMING_SESSION
# is pinned to deck-session.sh above -- so the image and the on-device tool name
# the same desktop session, not just the same gaming one.
desk = re.search(r"for cand in (\S+)", session_sh)
check_true("scraped the desktop-session candidate list out of deck-session.sh", desk)
check(
    "🔴 DESKTOP_SESSION matches deck-session.sh's first desktop candidate",
    deck_autologin.DESKTOP_SESSION,
    desk.group(1) if desk else None,
)


print("\n## 3. deck_user — the account is READ off the target, never guessed")

check(
    "a passwd line yields name, uid, gid and home",
    deck_user.parse_passwd("deck:x:1000:1001::/home/deck:/bin/bash\n"),
    {"deck": (1000, 1001, "/home/deck")},
)
check(
    "a truncated line is skipped rather than raising",
    deck_user.parse_passwd("broken:x:1000\ndeck:x:1000:1000::/home/deck:/bin/sh\n"),
    {"deck": (1000, 1000, "/home/deck")},
)
check(
    "a non-numeric uid is skipped, not believed",
    deck_user.parse_passwd("bad:x:notanumber:0::/h:/bin/sh\n"),
    {},
)
check(
    "a duplicated account resolves to the FIRST entry, as every getent-alike does",
    deck_user.parse_passwd("deck:x:1000:1000::/home/deck:/bin/sh\ndeck:x:1:1::/evil:/bin/sh\n")["deck"][2],
    "/home/deck",
)

target = make_target("user-ok", home="/var/lib/somewhere-else")
user, warnings = deck_user.resolve_target_user(make_ctx(target))
check("the resolved name is the installer's", user.name, "deck")
check("…the uid comes from the TARGET's passwd", user.uid, TEST_UID)
check(
    "🔴 …and so does the home: NEVER composed as /home/<name>. "
    "useradd honours -d, and a shell.json written to a guessed home is §3 trap (a)",
    user.home,
    "/var/lib/somewhere-else",
)
check("…which resolves through the target mount", user.home_on(target), target / "var/lib/somewhere-else")

target = make_target("user-nohome", make_home=False)
user, warnings = deck_user.resolve_target_user(make_ctx(target))
check_true("an absent home is a warning, not a failure", any("does not exist" in w for w in warnings))

target = make_target("user-missing", username="deck")
(target / "etc/passwd").write_text("root:x:0:0::/root:/bin/bash\n")
check_raises(
    "🔴 an account the installer named but archinstall never created is a REFUSAL — "
    "an autologin naming a nonexistent user fails at PAM and shows the greeter",
    lambda: deck_user.resolve_target_user(make_ctx(target)),
    deck_user.DeckUserError,
)

target = make_target("user-root", username="root")
check_raises(
    "root is refused as the desktop user",
    lambda: deck_user.resolve_target_user(make_ctx(target, username="root")),
    deck_user.DeckUserError,
)

target = make_target("user-uid0", username="deck", uid=0)
check_raises(
    "a uid-0 'deck' is refused too — the name is not the check, the uid is",
    lambda: deck_user.resolve_target_user(make_ctx(target)),
    deck_user.DeckUserError,
)

target = make_target("user-relhome", home="relative/home", make_home=False)
check_raises(
    "a non-absolute home is refused rather than joined onto the target",
    lambda: deck_user.resolve_target_user(make_ctx(target)),
    deck_user.DeckUserError,
)

target = make_target("user-nopasswd")
(target / "etc/passwd").unlink()
check_raises(
    "no /etc/passwd on the target at all is a refusal, not an empty dict",
    lambda: deck_user.resolve_target_user(make_ctx(target)),
    deck_user.DeckUserError,
)

target = make_target("user-defer")
check_raises(
    "🔴 defer_provisioning raises DeckUserDeferred, a DISTINCT fact from 'not found'",
    lambda: deck_user.resolve_target_user(make_ctx(target, defer=True)),
    deck_user.DeckUserDeferred,
)
check(
    "…and it is a subclass, so a caller that forgets to branch still fails safe",
    issubclass(deck_user.DeckUserDeferred, deck_user.DeckUserError),
    True,
)
check(
    "🔴 the deferred branch is checked BEFORE ctx.username, whose upstream property "
    "legitimately returns '' on that path",
    make_ctx(target, defer=True).username,
    "",
)


print("\n## 4. which session — refusing a Session= SDDM cannot resolve")

check(
    "gamescope-wayland is chosen when its .desktop is installed",
    deck_autologin.choose_session(make_target("sess-gaming"))[:2],
    (deck_autologin.GAMING_SESSION, "gaming"),
)
check(
    "…found under /usr/local/share/wayland-sessions too",
    deck_autologin.choose_session(make_target("sess-local", session_dir="usr/local/share/wayland-sessions"))[1],
    "gaming",
)
check(
    "🔴 with no Gaming Mode session installed it falls back to the desktop rather "
    "than writing an unresolvable Session= (which under autologin is a login loop "
    "with no session picker to escape with)",
    deck_autologin.choose_session(make_target("sess-desktop", gaming_session=False))[:2],
    (deck_autologin.DESKTOP_SESSION, "desktop"),
)
check(
    "…and with neither, it reports failure rather than inventing one",
    deck_autologin.choose_session(
        make_target("sess-none", gaming_session=False, desktop_session=False)
    ),
    ("", "failed", None),
)


print("\n## 5. 🔴 the drop-in — all three keys, INSIDE [Autologin]")

target = make_target("dropin")
record, console = run_step(make_ctx(target))
check("the step reports 'gaming'", record["status"], "gaming")
text = dropin_text(target)
found = deck_autologin.parse_autologin(text)

check("🔴 User= is present — with Session= alone SDDM ignores [Autologin] and "
      "shows a greeter (hardware, PROGRESS.md R-16)", found.get("User"), "deck")
check("🔴 Session= is present and names Gaming Mode", found.get("Session"), "gamescope-wayland")
check("🔴 Relogin=true is present — SDDM ships Relogin=false, so autologin fires "
      "ONCE and a dead session lands on the same unanswerable greeter (§5.18)",
      found.get("Relogin"), "true")
check("…and the section header is there for them to be under", deck_autologin.AUTOLOGIN_SECTION in text, True)

check(
    "🔴 a key under some OTHER section does not count as present — SDDM does not "
    "look there, and a 'is User= in the file' check would pass for it",
    deck_autologin.parse_autologin("[Autologin]\nSession=x\n[Users]\nUser=deck\n").get("User"),
    None,
)
check(
    "…nor does a commented-out one",
    deck_autologin.parse_autologin("[Autologin]\n#User=deck\nSession=x\n").get("User"),
    None,
)
check("the drop-in is 0644", mode_of(target / deck_autologin.SDDM_DROPIN_REL), "0644")
check_true("…and carries the reason Relogin= exists, for a reader with no repo", "5.18" in text)

# The readback is the assertion, not the write. Prove it can fail.
check_raises(
    "🔴 write_dropin RE-READS and refuses a drop-in whose User= did not land",
    lambda: deck_autologin.write_dropin(target, "", deck_autologin.GAMING_SESSION),
    deck_autologin.DeckAutologinError,
)

# Idempotence: the fixed name is truncated and rewritten, never accumulated.
before = sorted(p.name for p in (target / deck_autologin.SDDM_CONF_D_REL).iterdir())
run_step(make_ctx(target))
after = sorted(p.name for p in (target / deck_autologin.SDDM_CONF_D_REL).iterdir())
check("re-running adds no second autologin file for the two to fight over", after, before)
check("…and the content is unchanged", dropin_text(target), text)


print("\n## 6. 🔴 the drop-in sorts LAST among the neighbours upstream really writes")

entries = record["conf_d"]
check_true(
    "the assertion is not vacuous: upstream's own /etc/sddm.conf.d files are there",
    "99-omarchy-login.conf" in entries and "autologin.conf" in entries,
)
check(
    "🔴 ours is last, so SDDM's later-file-wins ordering makes our Session= the "
    "effective one. The bug that shipped was a 95- name with a COMMENT claiming this",
    entries[-1],
    deck_autologin.SDDM_DROPIN_NAME,
)
check("…and the step recorded that it checked", record["sorts_last"], True)

# The negative control: the same directory, with our file renamed to the name
# that actually shipped broken.
losing = make_target("sortlast-bad")
(losing / deck_autologin.SDDM_CONF_D_REL / "zz-deck-session.conf").write_text("[Autologin]\n")
os.rename(
    losing / deck_autologin.SDDM_CONF_D_REL / "zz-deck-session.conf",
    losing / deck_autologin.SDDM_CONF_D_REL / "95-deck-session.conf",
)
check_raises(
    "🔴 a name that does NOT sort last is caught — '9' < 'a', which is exactly how "
    "autologin.conf overrode 95-deck-session.conf on every machine",
    lambda: deck_autologin.assert_sorts_last(losing),
    deck_autologin.DeckAutologinError,
)
check_raises(
    "…and an empty /etc/sddm.conf.d after a write is a failure, not a pass",
    lambda: deck_autologin.assert_sorts_last(make_target("sortlast-empty", neighbours=False)),
    deck_autologin.DeckAutologinError,
)


print("\n## 7. /var/lib/sddm/state.conf")

target = make_target("state")
record, _ = run_step(make_ctx(target))
state = (target / deck_autologin.SDDM_STATE_REL).read_text()
check("state.conf names the same session as [Autologin]", "Session=gamescope-wayland" in state, True)
check("…and the same user", "User=deck" in state, True)
check("…and is reported by path", record["state_conf"], "/" + deck_autologin.SDDM_STATE_REL)
check("no warning when upstream had already created it", record["warnings"], [])

target = make_target("state-absent", state_conf=False, sddm_account=True)
record, _ = run_step(make_ctx(target))
check("a missing state.conf is created", (target / deck_autologin.SDDM_STATE_REL).is_file(), True)
check_true(
    "…and the fact that WE created it (so upstream's chown never ran) is recorded",
    any("did not exist" in w for w in record["warnings"]),
)
check(
    "…chowned to the target's own sddm account, looked up rather than assumed",
    os.stat(target / deck_autologin.SDDM_STATE_REL).st_uid,
    TEST_UID,
)
check("🔴 …and the step still succeeded: state.conf is not worth losing autologin over", record["status"], "gaming")

target = make_target("state-nosddm", state_conf=False, sddm_account=False)
record, _ = run_step(make_ctx(target))
check_true(
    "a target with no sddm account says so rather than chowning to nothing",
    any("no 'sddm' account" in w for w in record["warnings"]),
)


print("\n## 8. the degraded and refused outcomes")

target = make_target("deg-desktop", gaming_session=False)
record, console = run_step(make_ctx(target))
check("🔴 no Gaming Mode session on the target -> status 'desktop', not a crash", record["status"], "desktop")
check("…autologin is still complete", deck_autologin.parse_autologin(dropin_text(target)).get("User"), "deck")
check("…pointing at the desktop session", record["session"], deck_autologin.DESKTOP_SESSION)
check_true("…and it is LOUD: the record carries the consequence in English", record["error"])
check_true("…naming what the user will experience", "Desktop Mode, not Gaming Mode" in record["error"])
check_true("…on the console, i.e. in the install log", "Deck autologin" in console)

target = make_target("deg-none", gaming_session=False, desktop_session=False)
record, console = run_step(make_ctx(target))
check("🔴 no session at all -> failed", record["status"], "failed")
check("…and NOTHING was written: no Session= SDDM cannot resolve", (target / deck_autologin.SDDM_DROPIN_REL).exists(), False)
check_true("…the refusal explains the login loop it avoids", "login loop" in record["error"])

target = make_target("deg-defer")
record, console = run_step(make_ctx(target, defer=True))
check("a defer_provisioning install is 'deferred', not 'failed'", record["status"], "deferred")
check("…and writes no drop-in", (target / deck_autologin.SDDM_DROPIN_REL).exists(), False)
check_true(
    "🔴 …but is still loud: nobody has checked that omarchy-provision-owner picks a "
    "GAMESCOPE session, so this install is not known to reach Gaming Mode",
    "NOT baked in" in record["error"],
)

target = make_target("deg-nouser")
(target / "etc/passwd").write_text("root:x:0:0::/root:/bin/bash\n")
record, console = run_step(make_ctx(target))
check("an account the target does not have -> failed", record["status"], "failed")
check("…and no drop-in naming a user who does not exist", (target / deck_autologin.SDDM_DROPIN_REL).exists(), False)


print("\n## 9. the step entry point, the shared document, and critical=True")

target = make_target("step-ok")
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    deck_configure.record_result(target, "wifi", {"status": "skipped"})
    deck_autologin.autologin_step(make_ctx(target))
log_path = target / deck_configure.DECK_INSTALL_LOG_REL
doc = json.loads(log_path.read_text())
check("the outcome lands under the 'autologin' key", doc["autologin"]["status"], "gaming")
check("…without clobbering another step's key", doc["wifi"]["status"], "skipped")
check("…and the log stays 0644", mode_of(log_path), "0644")
check("…carrying the ordering it verified, for the [V] QEMU row to read", doc["autologin"]["conf_d"][-1], "zz-deck-session.conf")

target = make_target("step-fail", gaming_session=False, desktop_session=False)
check_raises(
    "🔴 an unguaranteeable autologin RAISES, which is what critical=True acts on",
    lambda: deck_autologin.autologin_step(make_ctx(target)),
    deck_autologin.DeckAutologinError,
)
doc = json.loads((target / deck_configure.DECK_INSTALL_LOG_REL).read_text())
check(
    "🔴 …and the detailed record was written FIRST. The registry's own handler would "
    "have replaced it with a one-line {'status': 'error'}",
    doc["autologin"]["status"],
    "failed",
)
check_true("…with the diagnosis intact", "login loop" in doc["autologin"]["error"])

target = make_target("step-desktop", gaming_session=False)
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    deck_autologin.autologin_step(make_ctx(target))
check("🔴 the DEGRADED outcome does not raise: a Deck that boots to the desktop is "
      "not a Deck to withhold from its owner", True, True)

# End to end through the registry: a failing autologin must halt the install,
# and a working one must not.
target = make_target("cd-halt", gaming_session=False, desktop_session=False)
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    check_raises(
        "🔴 configure_deck HALTS when autologin cannot be guaranteed",
        lambda: deck_configure.configure_deck(make_ctx(target)),
        RuntimeError,
    )
doc = json.loads((target / deck_configure.DECK_INSTALL_LOG_REL).read_text())
check("…after running the other steps anyway, so the report is complete", "wifi" in doc, True)

target = make_target("cd-ok")
buf = io.StringIO()
raised = None
try:
    with contextlib.redirect_stdout(buf):
        deck_configure.configure_deck(make_ctx(target))
except Exception as exc:  # noqa: BLE001
    raised = exc
check("a satisfied autologin does not halt anything", raised, None)
doc = json.loads((target / deck_configure.DECK_INSTALL_LOG_REL).read_text())
check("…and the whole registry reported", doc["autologin"]["status"], "gaming")


print("\n## 10. what reaches the world-readable install log")

target = make_target("hostile", username="deck\x1b[2J")
record, _ = run_step(make_ctx(target, username="deck\x1b[2J"))
check("control bytes are stripped from the recorded user name", "\x1b" in (record["user"] or ""), False)
check(
    "…and the record is JSON-serialisable, since it is merged into a shared document",
    isinstance(json.dumps(record, default=str), str),
    True,
)


print()
print(f"{CHECKS - FAILURES}/{CHECKS} checks passed")
if FAILURES:
    print(f"{FAILURES} FAILURES")
shutil.rmtree(WORK, ignore_errors=True)
sys.exit(1 if FAILURES else 0)
