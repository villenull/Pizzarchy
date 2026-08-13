#!/usr/bin/env python3
"""Unit tests for `configure_deck`'s `session_dconf` and `idle_policy` steps —
T5 §5.3, the three load-bearing session settings (`deck_session_settings.py`).

No VM, no root, no network, no chroot, no ISO build, nothing against the Deck:

    python3 test-deck-session-settings.py

WHAT THIS SUITE IS ACTUALLY FOR
===============================

Everything is asserted against a **scratch target filesystem this suite builds**,
by executing the steps and reading the artefacts back — never by grepping the
module's own source.

Four traps, and §5.3 names three of them as the ones most likely to be
copy-pasted wrong:

1. 🔴 **`dconf read -d`, never a plain read.** A plain `dconf read` (or
   `gsettings get`) resolves through the whole profile and returns the *user's*
   value, so it passes while the site default is missing. `docs/PROGRESS.md`
   records exactly that: a check that passed while the thing it checked was
   absent. The fake `dconf` below models the distinction — its plain read
   answers from a user database that the site default is deliberately absent
   from — so the assertion can fail for the real reason.

2. 🔴 **`/etc/skel` is TOO LATE** for the user this image creates (§3 trap (a)):
   `useradd` runs in phase 3 of 14, before this phase, so skel is never copied
   for that account. Both surfaces are written and **the user's copy is the one
   verified**.

3. 🔴 **`lock: 0` locks INSTANTLY**, it does not disable. There is no off
   sentinel, so `0` gets an assertion of its own rather than being covered by
   "equals 86400".

4. 🔴 **A user `shell.json` REPLACES Omarchy's defaults** rather than merging,
   so an idle-only file silently strips the bar. The file is seeded from the
   shipped defaults and patched as JSON, and the top-level key count is asserted.

The harness uses the **real `ui.py` and `context.py`** from `iso/upstream`, so an
upstream rename goes red here rather than at install time.
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import pathlib
import re
import shutil
import stat
import sys
import tempfile

# ⚠️ Before importing anything under test — see the note in the sibling suites.
sys.dont_write_bytecode = True

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
OVERLAY_ORCH = (
    REPO_ROOT / "iso/overlay/configs/airootfs/usr/share/omarchy-iso/orchestrator"
)
UPSTREAM_ORCH = (
    REPO_ROOT / "iso/upstream/configs/airootfs/usr/share/omarchy-iso/orchestrator"
)
# The authority on what these three settings are. Read, not copied.
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
# Harness
# ---------------------------------------------------------------------------

WORK = pathlib.Path(tempfile.mkdtemp(prefix="deck-settings-test-"))

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
    for name in ("ui.py", "context.py"):
        shutil.copyfile(UPSTREAM_ORCH / name, pkg / name)
    for module in sorted(OVERLAY_ORCH.glob("deck_*.py")):
        shutil.copyfile(module, pkg / module.name)
    (pkg / "phases_impl.py").write_text(PHASES_IMPL_STUB)
    return root


PKG_ROOT = build_package()
sys.path.insert(0, str(PKG_ROOT))

from orchestrator import deck_configure, deck_session_settings as dss  # noqa: E402
from orchestrator.context import InstallContext  # noqa: E402

print(f"# modules loaded from {PKG_ROOT}")

TEST_UID = os.getuid()
TEST_GID = os.getgid()

# Omarchy's shipped shell.json, in the shape that matters here: more than one
# top-level key (so "the bar was not stripped" can fail) and an idle block
# carrying upstream's five-minute lock.
SHIPPED_SHELL_JSON = json.dumps(
    {
        "version": 1,
        "bar": {"modules": ["clock", "battery"]},
        "idle": {"screensaver": 150, "lock": 300},
    },
    indent=2,
)


def tmpdir(name: str) -> pathlib.Path:
    d = WORK / name
    d.mkdir(parents=True, exist_ok=True)
    return d


def mode_of(path: pathlib.Path) -> str:
    return f"{stat.S_IMODE(os.lstat(path).st_mode):04o}"


def make_ctx(target, username="deck", defer=False) -> InstallContext:
    return InstallContext(
        config_path=pathlib.Path("/dev/null"),
        creds_path=pathlib.Path("/dev/null"),
        full_name="Test User",
        email="t@example.invalid",
        encrypt=False,
        authorized_keys_path=None,
        tailscale_authkey_path=None,
        user_configuration={},
        user_credentials={"users": [] if defer else [{"username": username}]},
        arch_config_path=pathlib.Path("/dev/null"),
        omarchy_install={},
        defer_provisioning=defer,
        target=pathlib.Path(target),
    )


def make_target(
    name: str,
    *,
    username: str = "deck",
    home: str | None = None,
    make_home: bool = True,
    shipped_defaults: str | None = SHIPPED_SHELL_JSON,
    profile: str | None = None,
) -> pathlib.Path:
    target = tmpdir(name) / "mnt"
    home = home if home is not None else f"/home/{username}"
    (target / "etc").mkdir(parents=True, exist_ok=True)
    (target / "etc/passwd").write_text(
        "root:x:0:0::/root:/bin/bash\n"
        f"{username}:x:{TEST_UID}:{TEST_GID}::{home}:/bin/bash\n"
    )
    if make_home:
        (target / home.lstrip("/")).mkdir(parents=True, exist_ok=True)
    if shipped_defaults is not None:
        defaults = target / dss.SHELL_JSON_DEFAULTS_REL
        defaults.parent.mkdir(parents=True, exist_ok=True)
        defaults.write_text(shipped_defaults)
    if profile is not None:
        path = target / dss.DCONF_PROFILE_REL
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(profile)
    return target


# ---------------------------------------------------------------------------
# A fake `dconf`, faithful about the ONE thing this task turns on
# ---------------------------------------------------------------------------


class FakeDconf:
    """Stands in for `arch-chroot <target> dconf …`.

    It is not a dconf implementation; it models exactly the three behaviours the
    step depends on, and it models them so they can FAIL:

    * `dconf update` compiles `db/local.d/*` into the binary db at `db/local`.
      If it is never called, the binary db never appears — which is the real
      failure a skipped `dconf update` produces.
    * `dconf read -d KEY` answers from the **compiled site db only**.
    * 🔴 `dconf read KEY` (no `-d`) answers from a **user database** that this
      fake seeds with the right-looking values and that the site db plays no
      part in. That is the trap: a plain read passes while the site default is
      absent, so a step that used one would go green here for the wrong reason
      and the `-d` assertions below would be meaningless.
    """

    USER_DB = {
        dss.OSK_KEY: "true",
        dss.INPUT_SOURCES_KEY: "[('xkb', 'us')]",
    }

    def __init__(self, *, update_code: int = 0, compile_db: bool = True, read_code: int = 0):
        self.update_code = update_code
        self.compile_db = compile_db
        self.read_code = read_code
        self.calls: list[list[str]] = []

    # -- the compiler ------------------------------------------------------
    @staticmethod
    def _compile(target: pathlib.Path) -> dict[str, str]:
        values: dict[str, str] = {}
        keyfile_dir = target / dss.DCONF_SITE_FILE_REL
        keyfile_dir = keyfile_dir.parent
        for keyfile in sorted(keyfile_dir.glob("*")):
            if not keyfile.is_file():
                continue
            section = ""
            for raw in keyfile.read_text().splitlines():
                line = raw.strip()
                if not line or line.startswith("#"):
                    continue
                if line.startswith("[") and line.endswith("]"):
                    section = line[1:-1]
                    continue
                if "=" not in line:
                    continue
                key, _, value = line.partition("=")
                values[f"/{section}/{key.strip()}"] = value.strip()
        return values

    def _site(self, target: pathlib.Path) -> dict[str, str]:
        db = target / dss.DCONF_COMPILED_DB_REL
        if not db.is_file():
            return {}
        try:
            return json.loads(db.read_text())
        except ValueError:
            return {}

    def __call__(self, target, argv):
        target = pathlib.Path(target)
        self.calls.append(list(argv))
        if argv[:2] == ["dconf", "update"]:
            if self.update_code == 0 and self.compile_db:
                db = target / dss.DCONF_COMPILED_DB_REL
                db.parent.mkdir(parents=True, exist_ok=True)
                db.write_text(json.dumps(self._compile(target)))
            return self.update_code, "" if self.update_code == 0 else "dconf: cannot write\n"
        if argv[:3] == ["dconf", "read", "-d"]:
            if self.read_code != 0:
                return self.read_code, "dconf: no such key\n"
            return 0, self._site(target).get(argv[3], "") + "\n"
        if argv[:2] == ["dconf", "read"]:
            # 🔴 The trap, faithfully: the USER's value, site db not consulted.
            return 0, self.USER_DB.get(argv[2], "") + "\n"
        raise AssertionError(f"unexpected command in the target: {argv!r}")


def run_dconf(ctx, runner):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        record = dss.configure_dconf(ctx, runner=runner)
    return record, buf.getvalue()


def load_json(path: pathlib.Path):
    """Read a JSON file, or `{}` if it is missing or unparsable.

    Never `read_text()` directly in an assertion: a mutation that stops a file
    being written would crash the suite at that line, and every assertion after
    it would never run. A suite that stops early reports one fault where it
    should report the several that are aimed at it.
    """
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


def run_idle(ctx):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        record = dss.configure_idle_policy(ctx)
    return record, buf.getvalue()


print("\n## 1. the payload exists and compiles")

check_true("present: deck_session_settings.py", (OVERLAY_ORCH / "deck_session_settings.py").is_file())
check(
    "deck_session_settings.py compiles",
    os.system(f"python3 -m py_compile {OVERLAY_ORCH / 'deck_session_settings.py'} 2>/dev/null"),
    0,
)
check(
    "guard 6.4a: it references no /usr/bin/omarchy-* binary",
    re.findall(r"/usr/bin/omarchy-[A-Za-z0-9._-]+", (OVERLAY_ORCH / "deck_session_settings.py").read_text()),
    [],
)


print("\n## 2. the constants agree with src/deck-session.sh, the on-device authority")

session_sh = DECK_SESSION_SH.read_text()
scraped = {
    name: re.search(rf"^readonly {name}=(\S+)", session_sh, re.M)
    for name in (
        "OSK_KEY",
        "INPUT_SOURCES_KEY",
        "DCONF_PROFILE",
        "DCONF_SITE_FILE",
        "IDLE_SCREENSAVER_SECONDS",
        "IDLE_LOCK_SECONDS",
        "OMARCHY_SHELL_JSON_REL",
        "OMARCHY_SHELL_JSON_DEFAULTS",
    )
}
check_true(
    "every constant was actually scraped out of deck-session.sh "
    "(comparing two empty strings passes, so this guard comes first)",
    all(m is not None for m in scraped.values()),
)
check("the a11y key is the same key", dss.OSK_KEY, scraped["OSK_KEY"].group(1))
check("the input-sources key is the same key", dss.INPUT_SOURCES_KEY, scraped["INPUT_SOURCES_KEY"].group(1))
check("the dconf profile is the same path", "/" + dss.DCONF_PROFILE_REL, scraped["DCONF_PROFILE"].group(1))
check("the site keyfile is the same path", "/" + dss.DCONF_SITE_FILE_REL, scraped["DCONF_SITE_FILE"].group(1))
check("the screensaver timeout matches", str(dss.IDLE_SCREENSAVER_SECONDS), scraped["IDLE_SCREENSAVER_SECONDS"].group(1))
check(
    "🔴 the lock timeout matches, and it is the large value that means 'never' "
    "(there is no off sentinel)",
    str(dss.IDLE_LOCK_SECONDS),
    scraped["IDLE_LOCK_SECONDS"].group(1),
)
check("shell.json's per-user path matches", dss.SHELL_JSON_REL, scraped["OMARCHY_SHELL_JSON_REL"].group(1))
check(
    "…and the shipped defaults it is seeded from",
    "/" + dss.SHELL_JSON_DEFAULTS_REL,
    scraped["OMARCHY_SHELL_JSON_DEFAULTS"].group(1),
)


print("\n## 3. where it runs — inside the target")

cmd = dss.chroot_command("/mnt", ["dconf", "update"])
check("dconf is invoked through arch-chroot into the target", cmd, ["arch-chroot", "/mnt", "dconf", "update"])
check("…with the target stringified, so a Path works", dss.chroot_command(pathlib.Path("/mnt"), [])[1], "/mnt")


print("\n## 4. the dconf site defaults — installed, compiled, verified with -d")

target = make_target("dconf-ok")
runner = FakeDconf()
record, console = run_dconf(make_ctx(target), runner)

check("status is 'configured'", record["status"], "configured")
check("…with no error", record["error"], None)
profile = (target / dss.DCONF_PROFILE_REL).read_text().splitlines()
check(
    "🔴 the profile names the SITE database — without it dconf reads only the "
    "user db and every default here is inert",
    "system-db:local" in profile,
    True,
)
check("…and the user database, so a user can still override", "user-db:user" in profile, True)
keyfile = (target / dss.DCONF_SITE_FILE_REL).read_text()
check("the a11y section is in the keyfile", "[org/gnome/desktop/a11y/applications]" in keyfile, True)
check("…with squeekboard's auto-show gate on", "screen-keyboard-enabled=true" in keyfile, True)
check("the input-sources section is there", "[org/gnome/desktop/input-sources]" in keyfile, True)
check("…with a layout for squeekboard to draw", "sources=[('xkb','us')]" in keyfile, True)
check("the keyfile is 0644", mode_of(target / dss.DCONF_SITE_FILE_REL), "0644")

check(
    "🔴 'dconf update' was run INSIDE the target — a keyfile does nothing until it "
    "is compiled into the binary database",
    ["dconf", "update"] in runner.calls,
    True,
)
check(
    "🔴 …and the compiled database really exists afterwards, which is the fact a "
    "skipped or failed update destroys",
    (target / dss.DCONF_COMPILED_DB_REL).is_file(),
    True,
)
check("…and is reported by path", record["compiled_db"], "/" + dss.DCONF_COMPILED_DB_REL)

read_calls = [c for c in runner.calls if c[:2] == ["dconf", "read"]]
check(
    "🔴 EVERY readback used 'dconf read -d'. A plain read returns the USER's value "
    "and passes while the site default is missing — PROGRESS.md records a check "
    "that passed while the thing it checked was absent",
    all(c[2] == "-d" for c in read_calls),
    True,
)
check("…for both keys", sorted(c[3] for c in read_calls), sorted([dss.INPUT_SOURCES_KEY, dss.OSK_KEY]))
check("the a11y default reads back true", record["defaults"][dss.OSK_KEY], "true")
check_true("…and the input source reads back an xkb/us pair", "'xkb'" in record["defaults"][dss.INPUT_SOURCES_KEY])
check_true("the console says the verification used -d", "dconf read -d" in console)

# Idempotence
record2, _ = run_dconf(make_ctx(target), FakeDconf())
check("a re-run is clean", record2["status"], "configured")
check("…and does not duplicate the profile", (target / dss.DCONF_PROFILE_REL).read_text().count("system-db:local"), 1)


print("\n## 5. 🔴 the -d assertion can FAIL — the negative controls")

# The trap made concrete: the site db is empty (nothing compiled), but the
# fake's plain `dconf read` still answers 'true' from the user database. A step
# that used a plain read would pass right here.
target = make_target("dconf-nocompile")
runner = FakeDconf(compile_db=False)
record, console = run_dconf(make_ctx(target), runner)
check("🔴 'dconf update' that compiles nothing is a FAILURE, not a pass", record["status"], "failed")
check_true("…named as the uncompiled database", "never compiled" in record["error"] or "missing or empty" in record["error"])
check(
    "🔴 …while a PLAIN read of the same target still answers 'true' from the user "
    "database. This is the whole reason -d is not optional",
    runner(target, ["dconf", "read", dss.OSK_KEY])[1].strip(),
    "true",
)

target = make_target("dconf-updatefail")
record, _ = run_dconf(make_ctx(target), FakeDconf(update_code=1))
check("a non-zero 'dconf update' is a failure", record["status"], "failed")
check_true("…quoting the exit code", "exited 1" in record["error"])

target = make_target("dconf-readfail")
record, _ = run_dconf(make_ctx(target), FakeDconf(read_code=1))
check("a 'dconf read -d' that errors is a failure", record["status"], "failed")

# A site db that compiled the WRONG value.
target = make_target("dconf-wrong")
runner = FakeDconf()
run_dconf(make_ctx(target), runner)
(target / dss.DCONF_COMPILED_DB_REL).write_text(json.dumps({dss.OSK_KEY: "false", dss.INPUT_SOURCES_KEY: "[('xkb', 'us')]"}))
record, _ = run_dconf(make_ctx(target), FakeDconf(compile_db=False))
check("🔴 a site default of 'false' is caught", record["status"], "failed")
check_true("…and says what it costs: the OSK would never auto-show", "auto-show" in record["error"])

(target / dss.DCONF_COMPILED_DB_REL).write_text(json.dumps({dss.OSK_KEY: "true", dss.INPUT_SOURCES_KEY: "@a(ss) []"}))
record, _ = run_dconf(make_ctx(target), FakeDconf(compile_db=False))
check("an empty input-sources list is caught", record["status"], "failed")
check_true("…and says what it costs: no layout to draw", "no layout to draw" in record["error"])


print("\n## 6. a pre-existing dconf profile is never blindly appended to")

target = make_target("dconf-foreign", profile="user-db:user\nsystem-db:site\n")
record, _ = run_dconf(make_ctx(target), FakeDconf())
check(
    "🔴 a profile that does not read our site db is a REFUSAL, not an append: "
    "profile order is precedence and reordering someone else's is a guess",
    record["status"],
    "failed",
)
check("…and the profile is left exactly as it was", (target / dss.DCONF_PROFILE_REL).read_text(), "user-db:user\nsystem-db:site\n")

target = make_target("dconf-alreadyok", profile="user-db:user\nsystem-db:local\n")
record, _ = run_dconf(make_ctx(target), FakeDconf())
check("a profile that already reads it is accepted unchanged", record["status"], "configured")

target = make_target("dconf-nouserdb", profile="system-db:local\n")
record, _ = run_dconf(make_ctx(target), FakeDconf())
check("a profile with no user-db still works…", record["status"], "configured")
check_true("…but says so", any("user-db:user" in w for w in record["warnings"]))


print("\n## 7. 🔴 the idle policy — lock: 0 locks INSTANTLY")

check_raises(
    "🔴 an idle lock of 0 is REFUSED before anything is written: there is no off "
    "sentinel, and lockDelaySeconds === 0 is the fire-immediately branch",
    lambda: dss.validate_idle(lock=0),
    dss.DeckSettingsError,
)
check_raises("a negative lock is refused", lambda: dss.validate_idle(lock=-1), dss.DeckSettingsError)
check_raises(
    "…and so is one past the 32-bit QML Timer.interval ceiling (~24.8 days)",
    lambda: dss.validate_idle(lock=dss.IDLE_LOCK_MAX_SECONDS + 1),
    dss.DeckSettingsError,
)
check_raises("a screensaver of 0 would blank the panel at once", lambda: dss.validate_idle(screensaver=0), dss.DeckSettingsError)
try:
    dss.validate_idle()
    ok = True
except Exception:  # noqa: BLE001
    ok = False
check("🔴 the SHIPPED constants pass their own validator", ok, True)


print("\n## 8. 🔴 both surfaces — and the USER's copy is the one verified")

target = make_target("idle-ok")
record, console = run_idle(make_ctx(target))
check("status is 'configured'", record["status"], "configured")
check("…with no error", record["error"], None)

skel = target / dss.SHELL_JSON_SKEL_REL
user_json = target / "home/deck/.config/omarchy/shell.json"
check("/etc/skel got a copy, for accounts made LATER", skel.is_file(), True)
check(
    "🔴 and so did the created user's home. /etc/skel alone is TOO LATE — useradd "
    "ran in phase 3 of 14, so skel is never copied for THIS account (§3 trap (a))",
    user_json.is_file(),
    True,
)
check("…and the record points at the user's copy, not skel's", record["user_path"], "/home/deck/.config/omarchy/shell.json")

doc = load_json(user_json)
check("the user's screensaver is 150s", doc.get("idle", {}).get("screensaver"), 150)
check("the user's lock is the large 'never' value", doc.get("idle", {}).get("lock"), 86400)
check(
    "🔴 …and it is NOT 0, as its own case: 0 locks instantly rather than disabling",
    doc.get("idle", {}).get("lock") not in (0, None),
    True,
)
check(
    "🔴 the rest of Omarchy's config survived — a user shell.json REPLACES the "
    "defaults, so an idle-only file would silently strip the bar",
    sorted(doc.keys()),
    ["bar", "idle", "version"],
)
check("…which the record carries for the [V] row", record["top_level_keys"], 3)
check("the user's copy is owned by the user, not by root", os.stat(user_json).st_uid if user_json.exists() else None, TEST_UID)
check("…and so is the .config directory this step created", os.stat(user_json.parent.parent).st_uid if user_json.parent.parent.exists() else None, TEST_UID)
check("the file is 0644", mode_of(user_json) if user_json.exists() else None, "0644")
check("skel's copy carries the same policy", load_json(skel).get("idle", {}).get("lock"), 86400)

# Idempotence
record2, _ = run_idle(make_ctx(target))
check("a re-run is clean", record2["status"], "configured")
check("…and does not accumulate keys", sorted(load_json(user_json).keys()), ["bar", "idle", "version"])

# An EXISTING user file is patched, not replaced.
target = make_target("idle-existing")
existing = target / "home/deck/.config/omarchy/shell.json"
existing.parent.mkdir(parents=True, exist_ok=True)
existing.write_text(json.dumps({"bar": {"mine": True}, "theme": "x", "idle": {"lock": 300}}))
record, _ = run_idle(make_ctx(target))
doc = load_json(existing)
check("an existing user file keeps its own keys", doc.get("theme"), "x")
check("…and its own bar", doc.get("bar"), {"mine": True})
check("…while the idle block is corrected", doc.get("idle", {}).get("lock"), 86400)

stripped = tmpdir("stripped") / "shell.json"
stripped.write_text(json.dumps({"idle": {"screensaver": 150, "lock": 86400}}))
check_raises(
    "🔴 verify_shell_json refuses a file that has only the idle block — that is the "
    "stripped bar, and it must not read as success",
    lambda: dss.verify_shell_json(stripped, "stripped"),
    dss.DeckSettingsError,
)
missing = tmpdir("missing") / "shell.json"
check_raises(
    "🔴 …and refuses an ABSENT user copy, which is what a skel-only write leaves",
    lambda: dss.verify_shell_json(missing, "the user's copy"),
    dss.DeckSettingsError,
)


def zero_lock_message() -> str:
    zeroed = tmpdir("zeroed") / "shell.json"
    zeroed.write_text(json.dumps({"bar": {}, "idle": {"screensaver": 150, "lock": 0}}))
    try:
        dss.verify_shell_json(zeroed, "zeroed")
    except dss.DeckSettingsError as exc:
        return str(exc)
    return ""


message = zero_lock_message()
check_true(
    "🔴 lock=0 is refused on re-read with its OWN message — not folded into "
    "'expected 86400', because 0 is the edit that looks like disabling the lock",
    "INSTANTLY" in message,
)


print("\n## 9. the idle policy's refusals")

target = make_target("idle-nodefaults", shipped_defaults=None)
record, console = run_idle(make_ctx(target))
check(
    "🔴 no shipped shell.json to seed from -> failed, rather than writing an "
    "idle-only file that strips the bar",
    record["status"],
    "failed",
)
check_true("…and it says exactly that", "strip the bar" in record["error"])
check("…and nothing was written to the user's home", (target / "home/deck/.config").exists(), False)

target = make_target("idle-badjson")
(target / dss.SHELL_JSON_DEFAULTS_REL).write_text("{ not json")
record, _ = run_idle(make_ctx(target))
check("an unparsable shipped default is a failure, not a silent overwrite", record["status"], "failed")
check_true("…naming the parse error", "not valid JSON" in record["error"])

target = make_target("idle-nouser")
(target / "etc/passwd").write_text("root:x:0:0::/root:/bin/bash\n")
record, _ = run_idle(make_ctx(target))
check("an account the target does not have -> failed", record["status"], "failed")

target = make_target("idle-nohome", make_home=False)
record, _ = run_idle(make_ctx(target))
check("a home that does not exist yet is created, not refused", record["status"], "configured")
check_true("…and the fact is recorded", any("does not exist" in w for w in record["warnings"]))
check("…owned by the user", os.stat(target / "home/deck").st_uid, TEST_UID)

if TEST_UID != 0:
    target = make_target("idle-badchown")
    (target / "etc/passwd").write_text(
        "root:x:0:0::/root:/bin/bash\ndeck:x:65533:65533::/home/deck:/bin/bash\n"
    )
    (target / "home/deck").mkdir(parents=True, exist_ok=True)
    record, _ = run_idle(make_ctx(target))
    check(
        "🔴 a chown that cannot be done is a recorded FAILURE — a file the desktop "
        "user cannot read is the same outcome as no file",
        record["status"],
        "failed",
    )
    check_true("…naming the chown", "chown" in record["error"])


print("\n## 10. defer_provisioning — the ONE case where skel alone is right")

target = make_target("idle-defer")
record, console = run_idle(make_ctx(target, defer=True))
check("status is 'skel-only', a distinct outcome", record["status"], "skel-only")
check("…skel was written", (target / dss.SHELL_JSON_SKEL_REL).is_file(), True)
check(
    "🔴 …and that is CORRECT here, not trap (a): the account does not exist yet, "
    "so a later useradd copies skel for it",
    load_json(target / dss.SHELL_JSON_SKEL_REL).get("idle", {}).get("lock"),
    86400,
)
check_true("…and the reason is recorded", any("skel" in w for w in record["warnings"]))

record, _ = run_dconf(make_ctx(make_target("dconf-defer"), defer=True), FakeDconf())
check(
    "🔴 the dconf site defaults are UNAFFECTED by defer_provisioning — 'a user we "
    "have never met' is the case they exist for",
    record["status"],
    "configured",
)


print("\n## 11. the step entry points and the shared document")

target = make_target("steps")
buf = io.StringIO()
saved = dss.run_in_target
dss.run_in_target = FakeDconf()
try:
    with contextlib.redirect_stdout(buf):
        deck_configure.record_result(target, "wifi", {"status": "skipped"})
        dss.session_dconf_step(make_ctx(target))
        dss.idle_policy_step(make_ctx(target))
finally:
    dss.run_in_target = saved

log_path = target / deck_configure.DECK_INSTALL_LOG_REL
doc = json.loads(log_path.read_text())
check("the dconf outcome lands under 'session_dconf'", doc["session_dconf"]["status"], "configured")
check("the idle outcome lands under 'idle_policy'", doc["idle_policy"]["status"], "configured")
check("…neither clobbering another step's key", doc["wifi"]["status"], "skipped")
check("…and the log stays 0644", mode_of(log_path), "0644")
check(
    "🔴 the module attribute really is the seam — the real arch-chroot was never "
    "called (a default argument would have bound it at definition time)",
    doc["session_dconf"]["compiled_db"],
    "/" + dss.DCONF_COMPILED_DB_REL,
)

# Neither step may raise: critical=False, and the record IS the report.
target = make_target("steps-fail", shipped_defaults=None)
buf = io.StringIO()
raised = None
dss.run_in_target = FakeDconf(update_code=1)
try:
    with contextlib.redirect_stdout(buf):
        dss.session_dconf_step(make_ctx(target))
        dss.idle_policy_step(make_ctx(target))
except Exception as exc:  # noqa: BLE001
    raised = exc
finally:
    dss.run_in_target = saved
check("🔴 neither step raises on failure: the record is the report", raised, None)
doc = json.loads((target / deck_configure.DECK_INSTALL_LOG_REL).read_text())
check("…and both failures are recorded, not swallowed",
      [doc["session_dconf"]["status"], doc["idle_policy"]["status"]], ["failed", "failed"])
check_true("…loudly, on the console the install log captures", "Deck idle policy" in buf.getvalue())


print()
print(f"{CHECKS - FAILURES}/{CHECKS} checks passed")
if FAILURES:
    print(f"{FAILURES} FAILURES")
shutil.rmtree(WORK, ignore_errors=True)
sys.exit(1 if FAILURES else 0)
