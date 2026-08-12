#!/usr/bin/env python3
"""Unit tests for the target side of the Wi-Fi carry-over: `configure_deck`'s
`wifi` step (`src/deck_configure.py`, `src/deck_wifi.py`), its first-boot unit
script (`src/deck-wifi-first-boot.sh`) and the staged `build_phases` patch
(`src/iso-patches/configure-deck-phase.patch`).

No VM, no root, no network, no ISO build. Run directly:

    python3 test-deck-configure-wifi.py

WHAT THIS SUITE IS ACTUALLY FOR
===============================

Two failures, both of which a naive "does the file exist?" test passes:

1. 🔴 **The mode.** NetworkManager silently ignores a group- or world-readable
   keyfile. A copy that widens 0600 to 0644 produces an install that succeeds,
   a file that is present, contents that are correct — and a Deck with no
   network and no error message anywhere. So every assertion about the copy is
   an assertion about the MODE, made under a permissive umask (0o000) so that a
   `shutil.copy` mutant actually shows its 0666/0644 rather than being rescued
   by whatever umask the test runner happened to have.

2. 🔴 **The parse.** `/root/deck-wifi-outcome` carries an attacker-controlled
   SSID, and both consumers (Python here, bash in the first-boot script) must
   PARSE it, never `source` it. The hostile cases below therefore assert two
   separate things — that no side effect happened (a canary file is not
   created), and that the injected `status=`/`carried=` line did not win.
   First-wins is the rule that makes the second one true, and it has its own
   tests because a last-wins parser passes every other test in this file.

THE PACKAGE HARNESS
===================

`deck_configure.py` and `deck_wifi.py` ship *inside* upstream's orchestrator
package (`/usr/share/omarchy-iso/orchestrator/`), so their imports are
relative. The harness below rebuilds that package shape in a temp dir and —
deliberately — uses the **real** `ui.py` out of `iso/upstream`, not a stub: if
upstream renames `info`/`error`, this suite goes red, which is the only cheap
signal we have for that class of drift.
"""

from __future__ import annotations

import json
import os
import pathlib
import shutil
import stat
import subprocess
import sys
import tempfile
import textwrap

# ⚠️ Before importing anything under test. Python validates a cached .pyc
# against (mtime, size) at one-second granularity, so a same-size edit inside
# the same second silently runs the PREVIOUS version — which is exactly what
# mutation testing produces. (Recorded in test-deck-osk-layout.py's header
# after it bit during session 18.)
sys.dont_write_bytecode = True

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SRC = REPO_ROOT / "src"
UPSTREAM_ORCH = (
    REPO_ROOT
    / "iso"
    / "upstream"
    / "configs"
    / "airootfs"
    / "usr"
    / "share"
    / "omarchy-iso"
    / "orchestrator"
)
PATCH = REPO_ROOT / "src" / "iso-patches" / "configure-deck-phase.patch"
SCRIPT = SRC / "deck-wifi-first-boot.sh"
UNIT = SRC / "omarchy-deck-wifi-first-boot.service"

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
    except exc_types as exc:
        print(f"ok   {what} (raised {type(exc).__name__})")
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

WORK = pathlib.Path(tempfile.mkdtemp(prefix="deck-wifi-test-"))

PHASES_IMPL_STUB = '''
"""Stub. Only the phase ORDER is under test here."""


def __getattr__(name):
    def phase(ctx):
        raise AssertionError(f"stub phase {name} should not run")

    phase.__name__ = name
    return phase
'''

CONTEXT_STUB = '''
class InstallContext:
    pass
'''

PHASES_STUB = '''
class PhaseError(Exception):
    pass


def run(ctx, phases):
    raise AssertionError("run() should not be called by this suite")
'''


def build_package(main_py: pathlib.Path | None = None) -> pathlib.Path:
    """Assemble orchestrator/ in a temp dir and return the dir to put on sys.path."""
    root = pathlib.Path(tempfile.mkdtemp(prefix="orch-", dir=WORK))
    pkg = root / "orchestrator"
    pkg.mkdir()
    (pkg / "__init__.py").write_text("")
    shutil.copyfile(UPSTREAM_ORCH / "ui.py", pkg / "ui.py")
    shutil.copyfile(SRC / "deck_configure.py", pkg / "deck_configure.py")
    shutil.copyfile(SRC / "deck_wifi.py", pkg / "deck_wifi.py")
    (pkg / "phases_impl.py").write_text(PHASES_IMPL_STUB)
    (pkg / "context.py").write_text(CONTEXT_STUB)
    (pkg / "phases.py").write_text(PHASES_STUB)
    if main_py is not None:
        shutil.copyfile(main_py, pkg / "main.py")
    return root


PKG_ROOT = build_package()
sys.path.insert(0, str(PKG_ROOT))

from orchestrator import deck_configure, deck_wifi  # noqa: E402

print(f"# modules loaded from {PKG_ROOT}")


class FakeCtx:
    def __init__(self, target):
        self.target = pathlib.Path(target)


def tmpdir(name: str) -> pathlib.Path:
    d = WORK / name
    d.mkdir(parents=True, exist_ok=True)
    return d


# A keyfile in exactly the shape deck_form_nmconnection emits (src/deck-form.sh
# lines 1133-1151), written out longhand rather than generated, so this suite
# cannot agree with a broken producer.
PSK = "correct-horse-battery-staple"
KEYFILE = textwrap.dedent(
    f"""\
    [connection]
    id=Cafe WiFi
    uuid=3f2504e0-4f89-11d3-9a0c-0305e82c3301
    type=wifi
    autoconnect=true

    [wifi]
    mode=infrastructure
    ssid=Cafe WiFi

    [wifi-security]
    key-mgmt=wpa-psk
    psk={PSK}

    [ipv4]
    method=auto

    [ipv6]
    addr-gen-mode=default
    method=auto
    """
).encode()


def stage_live(dirname: str, outcome: str | None, profile: bytes | None) -> pathlib.Path:
    live = tmpdir(dirname) / "live"
    (live / "root").mkdir(parents=True, exist_ok=True)
    if outcome is not None:
        (live / "root" / "deck-wifi-outcome").write_text(outcome)
    if profile is not None:
        path = live / "root" / "deck-wifi.nmconnection"
        path.write_bytes(profile)
        os.chmod(path, 0o600)
    return live


def asset_dir() -> pathlib.Path:
    """The ISO's /usr/share/omarchy-iso/deck, as the overlay will assemble it."""
    d = WORK / "assets"
    if not d.exists():
        d.mkdir(parents=True)
        shutil.copyfile(SCRIPT, d / "deck-wifi-first-boot.sh")
        shutil.copyfile(UNIT, d / "omarchy-deck-wifi-first-boot.service")
    return d


def mode_of(path: pathlib.Path) -> str:
    return f"{stat.S_IMODE(os.lstat(path).st_mode):04o}"


print("\n## 1. the payload exists and is shellcheck-clean")

for f in (SRC / "deck_configure.py", SRC / "deck_wifi.py", SCRIPT, UNIT, PATCH):
    check_true(f"payload present: {f.relative_to(REPO_ROOT)}", f.is_file())

check("the first-boot script is executable in the repo", os.access(SCRIPT, os.X_OK), True)

if shutil.which("shellcheck"):
    proc = subprocess.run(
        ["shellcheck", "-x", str(SCRIPT)], capture_output=True, text=True, check=False
    )
    check(f"shellcheck -x {SCRIPT.name}", (proc.returncode, proc.stdout.strip()), (0, ""))
else:
    print("SKIP shellcheck is not installed (CI runs it; this box does not have it)")


print("\n## 2. parse_outcome — key=value, parsed and never sourced")

check(
    "the ordinary two-line file S1 writes",
    deck_wifi.parse_outcome("status=connected\nssid=Cafe WiFi\n"),
    {"status": "connected", "ssid": "Cafe WiFi"},
)
check(
    "a value containing '=' survives (split on the FIRST separator)",
    deck_wifi.parse_outcome("ssid=a=b=c\n")["ssid"],
    "a=b=c",
)
check(
    "an empty value is kept, not dropped",
    deck_wifi.parse_outcome("status=skipped\nssid=\n"),
    {"status": "skipped", "ssid": ""},
)
check(
    "lines with no '=', blank lines and comments are ignored",
    deck_wifi.parse_outcome("\nnonsense\n# comment=1\nstatus=skipped\n"),
    {"status": "skipped"},
)
check(
    "CRLF line endings do not end up inside the value",
    deck_wifi.parse_outcome("status=connected\r\nssid=Home\r\n"),
    {"status": "connected", "ssid": "Home"},
)
check(
    "FIRST WINS: a duplicated key keeps the first occurrence",
    deck_wifi.parse_outcome("status=skipped\nstatus=connected\n")["status"],
    "skipped",
)
check(
    "🔴 an SSID that forges a later status= line does not win",
    deck_wifi.parse_outcome("status=skipped\nssid=evil\nstatus=connected\n")["status"],
    "skipped",
)
check(
    "the line cap is enforced",
    "k63" in deck_wifi.parse_outcome("".join(f"k{i}=v\n" for i in range(200)))
    and "k64" not in deck_wifi.parse_outcome("".join(f"k{i}=v\n" for i in range(200))),
    True,
)

canary = WORK / "canary-parse"
hostile = f"status=skipped\nssid=$(touch {canary}); `touch {canary}`; ${{IFS}}\n"
parsed = deck_wifi.parse_outcome(hostile)
check("a shell-metacharacter SSID comes back as literal text", parsed["ssid"].startswith("$(touch"), True)
check("…and nothing was executed while parsing it", canary.exists(), False)


print("\n## 3. read_outcome — the file, and what it says when there isn't one")

live = stage_live("ro-missing", None, None)
fields, warnings = deck_wifi.read_outcome(live)
check("a missing outcome file is not an error", fields, {})
check_true("…but it is reported, naming the path", any("deck-wifi-outcome" in w for w in warnings))

live = stage_live("ro-ok", "status=connected\nssid=Cafe WiFi\n", None)
fields, warnings = deck_wifi.read_outcome(live)
check("a well-formed file parses", (fields["status"], fields["ssid"]), ("connected", "Cafe WiFi"))
check("…with no warnings", warnings, [])

live = stage_live("ro-nostatus", "ssid=Cafe\n", None)
_, warnings = deck_wifi.read_outcome(live)
check_true("a file with no status= line is reported", any("no status=" in w for w in warnings))

live = stage_live("ro-drift", "status=totally-new-state\n", None)
_, warnings = deck_wifi.read_outcome(live)
check_true(
    "an unrecognised status is called drift, not tolerated",
    any("drifted" in w for w in warnings),
)

live = stage_live("ro-huge", "status=connected\n" + "x" * (deck_wifi.MAX_OUTCOME_BYTES + 10), None)
fields, warnings = deck_wifi.read_outcome(live)
check("an oversized outcome file still yields the status", fields.get("status"), "connected")
check_true("…and says it truncated", any("larger than" in w for w in warnings))


print("\n## 4. read_staged_profile — the source side")

live = stage_live("sp-none", "status=skipped\n", None)
check("no staged profile reads as None, not as an error", deck_wifi.read_staged_profile(live), None)

live = stage_live("sp-ok", "status=connected\n", KEYFILE)
check("a staged profile is read byte-for-byte", deck_wifi.read_staged_profile(live), KEYFILE)

live = stage_live("sp-link", "status=connected\n", None)
secret = tmpdir("sp-link") / "elsewhere"
secret.write_text("root password file")
(live / "root" / "deck-wifi.nmconnection").symlink_to(secret)
check_raises(
    "🔴 a SYMLINK at the staged path is refused (O_NOFOLLOW), not followed",
    lambda: deck_wifi.read_staged_profile(live),
    deck_wifi.DeckWifiError,
)

live = stage_live("sp-dir", "status=connected\n", None)
(live / "root" / "deck-wifi.nmconnection").mkdir()
check_raises(
    "a directory at the staged path is refused",
    lambda: deck_wifi.read_staged_profile(live),
    deck_wifi.DeckWifiError,
)

live = stage_live("sp-huge", "status=connected\n", b"x" * (deck_wifi.MAX_PROFILE_BYTES + 1))
check_raises(
    "an oversized staged profile is refused",
    lambda: deck_wifi.read_staged_profile(live),
    deck_wifi.DeckWifiError,
)


print("\n## 5. looks_like_keyfile — catch the malformed profile here, not at first boot")

check("the real keyfile passes", deck_wifi.looks_like_keyfile(KEYFILE), True)
check("an empty file fails", deck_wifi.looks_like_keyfile(b""), False)
check(
    "a file with no [wifi] section fails",
    deck_wifi.looks_like_keyfile(b"[connection]\nid=x\nssid=x\n"),
    False,
)
check(
    "a file with no [connection] section fails",
    deck_wifi.looks_like_keyfile(b"[wifi]\nssid=x\n"),
    False,
)
check(
    "🔴 a profile with an EMPTY ssid= fails (a profile for nothing)",
    deck_wifi.looks_like_keyfile(b"[connection]\nid=x\n\n[wifi]\nssid=\n"),
    False,
)


print("\n## 6. install_profile — the 0600 that the whole task turns on")

# umask 0 for every mode assertion below: a permissive umask is what makes a
# mode-widening mutant visible. Under the runner's usual 0o022 a shutil.copy
# mutant yields 0644 (still a failure) but a 0666-producing one would be
# rescued to 0644 and could look 'nearly right'; under 0 there is nowhere to
# hide.
old_umask = os.umask(0)
try:
    dest = tmpdir("ip-basic") / "etc/NetworkManager/system-connections/deck-wifi.nmconnection"
    deck_wifi.install_profile(KEYFILE, dest)
    check("🔴 the installed keyfile is mode 0600 under umask 000", mode_of(dest), "0600")
    check("…and its contents are byte-identical to the staged file", dest.read_bytes(), KEYFILE)
    check("the containing directory is 0700", mode_of(dest.parent), "0700")

    # A directory that already exists with a wide mode must be tightened, not
    # left alone: mkdir(exist_ok=True) is a no-op on mode.
    dest2 = tmpdir("ip-widedir") / "etc/NetworkManager/system-connections/deck-wifi.nmconnection"
    dest2.parent.mkdir(parents=True)
    os.chmod(dest2.parent, 0o755)
    deck_wifi.install_profile(KEYFILE, dest2)
    check("a pre-existing wide directory is tightened to 0700", mode_of(dest2.parent), "0700")

    # Idempotency (CLAUDE.md: re-runnable scripts) — and the re-run must not
    # inherit the previous run's mode.
    os.chmod(dest, 0o644)
    deck_wifi.install_profile(KEYFILE, dest)
    check("🔴 re-running over a 0644 leftover ends at 0600", mode_of(dest), "0600")
    check("…and leaves exactly one file in the directory", len(list(dest.parent.iterdir())), 1)

    # A planted symlink must not turn the write into an overwrite of its victim.
    victim = tmpdir("ip-link") / "victim"
    victim.write_text("do not clobber me")
    dest3 = tmpdir("ip-link") / "etc/NetworkManager/system-connections/deck-wifi.nmconnection"
    dest3.parent.mkdir(parents=True)
    dest3.symlink_to(victim)
    deck_wifi.install_profile(KEYFILE, dest3)
    check("a symlink at the destination is replaced by a real file", dest3.is_symlink(), False)
    check("…its victim is untouched", victim.read_text(), "do not clobber me")
    check("…and the replacement is 0600", mode_of(dest3), "0600")
finally:
    os.umask(old_umask)

# A restrictive umask must not make the file *stricter* than 0600 either: the
# fchmod pins it exactly, and assert_mode demands exactly. 0o277 clears the
# owner-write bit from O_CREAT's 0600, so without the fchmod the file lands at
# 0400 — NetworkManager would accept it, but the next install could not rewrite
# it and nothing would say why.
for mask in (0o077, 0o277):
    # The scratch dir is made BEFORE the umask changes: under 0277 a directory
    # created by the test itself would be unwritable and the failure would be
    # the harness's, not the code's.
    dest4 = tmpdir(f"ip-umask{mask:03o}") / "sc/deck-wifi.nmconnection"
    old_umask = os.umask(mask)
    try:
        deck_wifi.install_profile(KEYFILE, dest4)
        check(f"under umask {mask:03o} the keyfile is still exactly 0600", mode_of(dest4), "0600")
    finally:
        os.umask(old_umask)


class ModeWideningOS:
    """`os`, with the two calls that pin the mode sabotaged.

    Fault injection, not a mutation: it proves that install_profile's read-back
    is what catches a widened mode, independently of *how* the widening
    happened. Without it, deleting either the fchmod or the assert_mode call
    leaves every other assertion in this section still passing, because they
    measure the same fact the deleted line was defending.
    """

    def __init__(self):
        self._os = os

    def __getattr__(self, name):
        return getattr(self._os, name)

    def open(self, path, flags, mode=0o777):  # noqa: A003
        return self._os.open(path, flags, 0o666)

    def fchmod(self, fd, mode):
        return None


old_umask = os.umask(0)
saved_os = deck_wifi.os
deck_wifi.os = ModeWideningOS()
try:
    dest5 = tmpdir("ip-injected") / "sc/deck-wifi.nmconnection"
    check_raises(
        "🔴 a mode widened by ANY route is caught by the read-back, not shipped",
        lambda: deck_wifi.install_profile(KEYFILE, dest5),
        deck_wifi.DeckWifiError,
    )
finally:
    deck_wifi.os = saved_os
    os.umask(old_umask)

print("\n## 6b. assert_mode — the read-back that proves the mode")

probe = tmpdir("am") / "probe"
probe.write_text("x")
os.chmod(probe, 0o600)
deck_wifi.assert_mode(probe, 0o600)
print("ok   assert_mode accepts 0600")
CHECKS += 1
os.chmod(probe, 0o644)
check_raises(
    "🔴 assert_mode REJECTS a world-readable keyfile",
    lambda: deck_wifi.assert_mode(probe, 0o600),
    deck_wifi.DeckWifiError,
)
os.chmod(probe, 0o640)
check_raises(
    "🔴 assert_mode rejects a merely GROUP-readable keyfile too",
    lambda: deck_wifi.assert_mode(probe, 0o600),
    deck_wifi.DeckWifiError,
)
os.chmod(probe, 0o600)
link = tmpdir("am") / "link"
link.symlink_to(probe)
check_raises(
    "assert_mode stats the link itself (lstat), not what it points at",
    lambda: deck_wifi.assert_mode(link, 0o600),
    deck_wifi.DeckWifiError,
)


print("\n## 7. carry_wifi — end to end, every branch")


def run_carry(name: str, outcome, profile, assets=None):
    live = stage_live(name, outcome, profile)
    target = tmpdir(name) / "mnt"
    target.mkdir(exist_ok=True)
    record = deck_wifi.carry_wifi(live, target, assets if assets is not None else asset_dir())
    return record, target


record, target = run_carry("cw-connected", "status=connected\nssid=Cafe WiFi\n", KEYFILE)
installed = target / deck_wifi.TARGET_PROFILE_REL
check("connected: the profile lands at the NetworkManager path", installed.is_file(), True)
check("🔴 connected: and it is 0600", mode_of(installed), "0600")
check("connected: the record says so", record["profile_installed"], True)
check("connected: the record carries the status and ssid", (record["status"], record["ssid"]), ("connected", "Cafe WiFi"))
check("connected: the recorded mode is 0600", record["profile_mode"], "0600")
check("connected: no error", record["error"], None)
check("connected: no warnings", record["warnings"], [])
check(
    "connected: the SSID is inside the keyfile, which is what NM actually reads",
    "ssid=Cafe WiFi" in installed.read_text(),
    True,
)

state_file = target / deck_wifi.CARRY_STATE_REL
check("the carry-state file exists for the first-boot unit", state_file.is_file(), True)
check("…and says carried=yes", "carried=yes" in state_file.read_text(), True)
check("…and is 0644 (no secrets in it)", mode_of(state_file), "0644")
check("🔴 the passphrase is NOT in the carry-state file", PSK in state_file.read_text(), False)

unit_dst = target / deck_wifi.FIRST_BOOT_UNIT_REL
script_dst = target / deck_wifi.FIRST_BOOT_SCRIPT_REL
wants = target / deck_wifi.FIRST_BOOT_WANTS_REL
check("the first-boot unit is installed even on the success path", unit_dst.is_file(), True)
check("…its script too, mode 0755", (script_dst.is_file(), mode_of(script_dst)), (True, "0755"))
check("…the unit file is 0644", mode_of(unit_dst), "0644")
check("…and it is enabled by a multi-user.target.wants symlink", wants.is_symlink(), True)
check(
    "🔴 the symlink points at the path INSIDE the installed system, not at /mnt",
    os.readlink(wants),
    "/" + deck_wifi.FIRST_BOOT_UNIT_REL,
)

# The JSON log, via the step entry point. carry_wifi_step reads the LIVE root
# and the ISO asset dir from module constants — point them at the fixtures, and
# in doing so assert that those constants are what the step actually uses.
saved = (deck_wifi.LIVE_ROOT, deck_wifi.ASSET_DIR)
deck_wifi.LIVE_ROOT = WORK / "cw-connected" / "live"
deck_wifi.ASSET_DIR = asset_dir()
try:
    deck_wifi.carry_wifi_step(FakeCtx(target))
finally:
    deck_wifi.LIVE_ROOT, deck_wifi.ASSET_DIR = saved
log_path = target / deck_configure.DECK_INSTALL_LOG_REL
doc = json.loads(log_path.read_text())
check("the outcome is recorded in /var/log/omarchy-deck-install.json", "wifi" in doc, True)
check("…under a key with the real status", doc["wifi"]["status"], "connected")
check("…and the log file is 0644", mode_of(log_path), "0644")
check("🔴 the passphrase is NOT in the install log", PSK in log_path.read_text(), False)

record, target = run_carry("cw-skipped", "status=skipped\nssid=\n", None)
check("skipped: nothing is written to system-connections", (target / deck_wifi.TARGET_PROFILE_REL).exists(), False)
check("skipped: the record says no profile", record["profile_installed"], False)
check("skipped: the status is carried through", record["status"], "skipped")
check("skipped: no error was invented", record["error"], None)
check(
    "🔴 skipped: the first-boot notice is STILL installed",
    (target / deck_wifi.FIRST_BOOT_UNIT_REL).is_file(),
    True,
)
check("skipped: the state file says carried=no", "carried=no" in (target / deck_wifi.CARRY_STATE_REL).read_text(), True)

record, _ = run_carry("cw-nohw", "status=no-hardware\n", None)
check("no-hardware: recorded verbatim", record["status"], "no-hardware")
check("no-hardware: no warnings invented", record["warnings"], [])

record, target = run_carry("cw-lying", "status=connected\nssid=Cafe\n", None)
check("🔴 status=connected with no staged keyfile is reported", any("did not survive" in w for w in record["warnings"]), True)
check("…and nothing is installed", (target / deck_wifi.TARGET_PROFILE_REL).exists(), False)

record, target = run_carry("cw-orphan", "status=skipped\nssid=Cafe\n", KEYFILE)
check("a keyfile staged against status=skipped is carried anyway", record["profile_installed"], True)
check("…and the disagreement is reported", any("carrying it anyway" in w for w in record["warnings"]), True)

record, target = run_carry("cw-malformed", "status=connected\nssid=Cafe\n", b"not a keyfile at all\n")
check("a malformed keyfile is refused", (target / deck_wifi.TARGET_PROFILE_REL).exists(), False)
check_true("…the record carries the error", record["error"] and "not a usable" in record["error"])
check(
    "…and the first-boot notice is still installed so the user hears about it",
    (target / deck_wifi.FIRST_BOOT_UNIT_REL).is_file(),
    True,
)

record, target = run_carry("cw-noassets", "status=skipped\n", None, assets=WORK / "no-such-assets")
check("a missing ISO asset does not raise", record["first_boot_unit"], None)
check_true("…it is reported as a warning", any("first-boot" in w for w in record["warnings"]))
check("…and the state file was still written", (target / deck_wifi.CARRY_STATE_REL).is_file(), True)

# A HALF-populated asset dir. The pre-flight check exists so that a broken
# overlay leaves NOTHING behind rather than a script with no unit to run it --
# an inert file in /usr/local/bin that nothing will ever execute is the quiet
# half-failure this project keeps having to remove.
partial = WORK / "assets-partial"
partial.mkdir(exist_ok=True)
shutil.copyfile(SCRIPT, partial / "deck-wifi-first-boot.sh")
record, target = run_carry("cw-halfassets", "status=skipped\n", None, assets=partial)
check("🔴 a half-populated asset dir installs NEITHER file, not one of them", (target / deck_wifi.FIRST_BOOT_SCRIPT_REL).exists(), False)
check("…and the unit is absent too", (target / deck_wifi.FIRST_BOOT_UNIT_REL).exists(), False)
check_true("…and the missing asset is named in the warning", any("missing ISO asset" in w for w in record["warnings"]))

record, target = run_carry("cw-nooutcome", None, None)
check("no outcome file at all: status is 'missing', not a crash", record["status"], "missing")
check("…and the unit is installed", (target / deck_wifi.FIRST_BOOT_UNIT_REL).is_file(), True)


print("\n## 8. hostile SSIDs reaching the target's files")

HOSTILE = "evil\x1b[2Jnet\nstatus=connected\x07"
record, target = run_carry("cw-hostile", f"status=skipped\nssid={HOSTILE}\n", None)
check("the injected status= line did not win", record["status"], "skipped")
check("the recorded ssid has no ESC", "\x1b" in record["ssid"], False)
check("…no newline", "\n" in record["ssid"], False)
check("…no BEL", "\x07" in record["ssid"], False)
# The newline split the forged `status=connected` onto its own line, where
# first-wins dropped it; what is left of the SSID is its own printable text.
check("…and keeps the printable text", record["ssid"], "evil[2Jnet")
state_text = (target / deck_wifi.CARRY_STATE_REL).read_text()
check("the carry-state file stays exactly three lines", len(state_text.strip().splitlines()), 3)
check("…and carries no control bytes", any(c < " " and c != "\n" for c in state_text), False)

long_ssid = "A" * 500
record, _ = run_carry("cw-long", f"status=skipped\nssid={long_ssid}\n", None)
check("an absurdly long SSID is truncated", len(record["ssid"]) <= deck_configure.SANITIZE_LIMIT + 3, True)
check("…and the truncation is marked", record["ssid"].endswith("..."), True)

check("sanitize_text keeps non-ASCII (a UTF-8 SSID is ordinary)", deck_configure.sanitize_text("Café ☕"), "Café ☕")
check("sanitize_text deletes a tab", deck_configure.sanitize_text("a\tb"), "ab")

# write_carry_state is documented as the SECOND line of defence, so it is tested
# directly rather than only through carry_wifi -- through carry_wifi its own
# sanitising is masked by the caller's, and a mutant that removed it survived
# every other assertion in this suite.
direct = tmpdir("wcs") / "mnt"
direct.mkdir(exist_ok=True)
state_path = deck_wifi.write_carry_state(direct, {"carried": "no", "ssid": "a\nssid=b\x1b[2J"})
text = state_path.read_text()
check("🔴 write_carry_state sanitises on its own, not only via its caller", len(text.strip().splitlines()), 2)
check("…dropping the ESC", "\x1b" in text, False)
check("…and the forged line is folded into the value it came from", "ssid=assid=b[2J" in text, True)


print("\n## 9. record_result — one shared document, merged not clobbered")

target = tmpdir("rr") / "mnt"
target.mkdir(exist_ok=True)
deck_configure.record_result(target, "wifi", {"status": "skipped"})
deck_configure.record_result(target, "dsp", {"status": "fetched"})
doc = json.loads((target / deck_configure.DECK_INSTALL_LOG_REL).read_text())
check("a second step's key does not clobber the first", sorted(doc), ["dsp", "wifi"])
deck_configure.record_result(target, "wifi", {"status": "connected"})
doc = json.loads((target / deck_configure.DECK_INSTALL_LOG_REL).read_text())
check("re-recording the same key replaces that key only", (doc["wifi"]["status"], doc["dsp"]["status"]), ("connected", "fetched"))

log_path = target / deck_configure.DECK_INSTALL_LOG_REL
check("no temp file is left behind", [p.name for p in log_path.parent.iterdir()], ["omarchy-deck-install.json"])

log_path.write_text("[not an object]")
deck_configure.record_result(target, "wifi", {"status": "connected"})
check("a corrupt existing document is moved aside, not silently destroyed", (log_path.parent / "omarchy-deck-install.json.corrupt").is_file(), True)
check("…and the new document is valid", json.loads(log_path.read_text())["wifi"]["status"], "connected")


print("\n## 10. configure_deck — the step registry")

check("`critical` has no default; a step must decide", "critical" in deck_configure.DeckStep.__dataclass_fields__, True)
check_raises(
    "🔴 constructing a DeckStep without `critical` is a TypeError",
    lambda: deck_configure.DeckStep("x", lambda ctx: None),
    TypeError,
)
check("the wifi step is registered", [s.name for s in deck_configure.deck_steps()], ["wifi"])
check("…and is non-critical: an offline install must still finish", deck_configure.deck_steps()[0].critical, False)
check("…and points at carry_wifi_step", deck_configure.deck_steps()[0].fn, deck_wifi.carry_wifi_step)


def with_steps(steps):
    original = deck_configure.deck_steps
    deck_configure.deck_steps = lambda: steps
    try:
        return original
    finally:
        pass


target = tmpdir("cd") / "mnt"
target.mkdir(exist_ok=True)


def boom(ctx):
    raise ValueError("step exploded")


original_steps = deck_configure.deck_steps
deck_configure.deck_steps = lambda: [deck_configure.DeckStep("wifi", boom, critical=False)]
try:
    deck_configure.configure_deck(FakeCtx(target))
    print("ok   a non-critical step's failure does not halt the install")
    CHECKS += 1
except Exception as exc:  # noqa: BLE001
    print(f"FAIL a non-critical step's failure must not halt the install: {exc}")
    FAILURES += 1
doc = json.loads((target / deck_configure.DECK_INSTALL_LOG_REL).read_text())
check("…and the failure is recorded, not swallowed", doc["wifi"]["status"], "error")
check_true("…with the exception type named", "ValueError" in doc["wifi"]["error"])

deck_configure.deck_steps = lambda: [deck_configure.DeckStep("boot", boom, critical=True)]
check_raises(
    "a CRITICAL step's failure halts the install",
    lambda: deck_configure.configure_deck(FakeCtx(target)),
    RuntimeError,
)

ran = []
deck_configure.deck_steps = lambda: [
    deck_configure.DeckStep("a", boom, critical=False),
    deck_configure.DeckStep("b", lambda ctx: ran.append("b"), critical=False),
]
deck_configure.configure_deck(FakeCtx(target))
check("a failed step does not stop the steps after it", ran, ["b"])
deck_configure.deck_steps = original_steps


print("\n## 11. the staged patch — where the phase actually lands")

patch_work = WORK / "patchwork"
shutil.copytree(REPO_ROOT / "iso" / "upstream", patch_work, symlinks=True, ignore=shutil.ignore_patterns(".git"))
subprocess.run(["git", "init", "-q", str(patch_work)], check=True)
subprocess.run(["git", "-C", str(patch_work), "add", "-A"], check=True, capture_output=True)
subprocess.run(
    ["git", "-C", str(patch_work), "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "base"],
    check=True,
    capture_output=True,
)
proc = subprocess.run(
    ["git", "-C", str(patch_work), "apply", "--3way", str(PATCH)],
    capture_output=True,
    text=True,
    check=False,
)
check("the patch applies to the pinned upstream tree", proc.returncode, 0)

patched_main = patch_work / "configs/airootfs/usr/share/omarchy-iso/orchestrator/main.py"
pkg_root = build_package(main_py=patched_main)
sys.path.insert(0, str(pkg_root))
for name in [m for m in sys.modules if m == "orchestrator" or m.startswith("orchestrator.")]:
    del sys.modules[name]
import orchestrator.main as patched  # noqa: E402
from orchestrator import deck_configure as patched_deck_configure  # noqa: E402

names = [name for name, _ in patched.build_phases(None)]
check("the patched phase list has the new phase", "Configuring Steam Deck" in names, True)
check(
    "🔴 it sits AFTER 'Configuring system' (run_system_finalizer)",
    names.index("Configuring Steam Deck") > names.index("Configuring system"),
    True,
)
check(
    "🔴 and BEFORE 'Finalizing Limine boot'",
    names.index("Configuring Steam Deck") < names.index("Finalizing Limine boot"),
    True,
)
check(
    "it is bound to our configure_deck, not to a same-named upstream function",
    dict(patched.build_phases(None))["Configuring Steam Deck"],
    patched_deck_configure.configure_deck,
)
check("exactly one phase was added", len(names), 15)
check(
    "every upstream phase name survives, in its original order",
    [n for n in names if n != "Configuring Steam Deck"],
    [
        "Preparing live environment",
        "Preparing install target",
        "Installing Arch + Omarchy",
        "Configuring hibernation",
        "Configuring system",
        "Staging provisioning",
        "Finalizing Limine boot",
        "Finalizing user",
        "Configuring login",
        "Configuring SSH access",
        "Configuring Tailscale",
        "Configuring DNS resolver",
        "Validating boot setup",
        "Creating factory snapshot",
    ],
)


print("\n## 12. the systemd unit")

# ⚠️ Directives only. The unit's header comments discuss RemainAfterExit,
# network-online.target and ConditionFirstBoot at length in order to say why
# they are NOT used, so a naive substring search over the whole file finds all
# three and asserts the opposite of the truth.
unit_text = "\n".join(
    line for line in UNIT.read_text().splitlines() if not line.lstrip().startswith("#")
)
check("ExecStart has no leading '-' (a failed check must FAIL the unit)", "ExecStart=-" in unit_text, False)
check("it does not RemainAfterExit (which would mask the exit status)", "RemainAfterExit" in unit_text, False)
check("it is wanted by multi-user.target", "WantedBy=multi-user.target" in unit_text, True)
check("it runs after NetworkManager", "After=NetworkManager.service" in unit_text, True)
check(
    "🔴 it does not wait on network-online.target (would delay boot on exactly the broken case)",
    "network-online.target" in unit_text,
    False,
)
check(
    "🔴 it does not use ConditionFirstBoot (machine-id is already set — it would never run)",
    "ConditionFirstBoot" in unit_text,
    False,
)
check(
    "ExecStart matches the path configure_deck installs the script to",
    f"ExecStart=/{deck_wifi.FIRST_BOOT_SCRIPT_REL}" in unit_text,
    True,
)
check(
    "its ConditionPathExists matches the state file configure_deck writes",
    f"ConditionPathExists=/{deck_wifi.CARRY_STATE_REL}" in unit_text,
    True,
)


print("\n## 13. the first-boot script — parsed, never sourced")


def run_script(name, *, state: str | None, wireless: bool, nmcli: str | None, wait="0"):
    """Run deck-wifi-first-boot.sh against a fake root. Returns (rc, out, err, root)."""
    root = tmpdir(f"fb-{name}")
    (root / "var/lib/omarchy-deck").mkdir(parents=True, exist_ok=True)
    (root / "etc/systemd/system/multi-user.target.wants").mkdir(parents=True, exist_ok=True)
    wants = root / "etc/systemd/system/multi-user.target.wants" / deck_wifi.FIRST_BOOT_UNIT
    if not wants.exists():
        wants.symlink_to("/" + deck_wifi.FIRST_BOOT_UNIT_REL)
    if state is not None:
        (root / deck_wifi.CARRY_STATE_REL).write_text(state)

    netdir = root / "sys/class/net"
    (netdir / "lo").mkdir(parents=True, exist_ok=True)
    if wireless:
        (netdir / "wlan0" / "wireless").mkdir(parents=True, exist_ok=True)

    # 🔴 A CLOSED PATH, containing only what the script is allowed to find.
    # With /usr/bin on PATH the "nmcli is not installed" case silently found
    # the dev machine's real nmcli and tested nothing. Everything the script
    # legitimately calls is symlinked in explicitly; anything it grows a
    # dependency on later will fail loudly here rather than be borrowed from
    # the host.
    bindir = root / "fakebin"
    bindir.mkdir(exist_ok=True)
    for tool in ("tr", "dirname", "mkdir", "chmod", "date", "rm", "sleep"):
        real = shutil.which(tool)
        assert real, f"the test host has no {tool}"
        link = bindir / tool
        if not link.exists():
            link.symlink_to(real)
    if nmcli is not None:
        shim = bindir / "nmcli"
        shim.write_text(f"#!/bin/sh\nprintf '%s\\n' '{nmcli}'\n")
        os.chmod(shim, 0o755)

    env = dict(os.environ)
    env.update(
        {
            "PATH": str(bindir),
            "DECK_WIFI_ROOT": str(root),
            "DECK_WIFI_WAIT_SECS": wait,
            "DECK_WIFI_POLL_SECS": "0",
        }
    )
    bash = shutil.which("bash") or "/bin/bash"
    proc = subprocess.run(
        [bash, str(SCRIPT)], capture_output=True, text=True, env=env, check=False, timeout=60
    )
    return proc.returncode, proc.stdout, proc.stderr, root


def link_present(path: pathlib.Path) -> bool:
    """Is the .wants entry there at all?

    🔴 `Path.exists()` FOLLOWS the symlink, and this symlink deliberately points
    at an absolute path inside the installed system (`/etc/systemd/system/…`)
    which does not exist inside a fake root. So `exists()` returned False
    whether or not the unit was still enabled, and the "it disabled itself"
    assertions passed for the wrong reason — caught by mutation S7 (remove
    self_disable from the success path), which survived until this helper
    existed.
    """
    return path.is_symlink() or path.exists()


def status_fields(root):
    text = (root / "var/lib/omarchy-deck/wifi-status").read_text()
    out = {}
    for line in text.splitlines():
        if "=" in line:
            k, _, v = line.partition("=")
            out.setdefault(k, v)
    return out


rc, out, err, root = run_script("nohw", state="carried=no\nstatus=skipped\nssid=\n", wireless=False, nmcli="disconnected")
check("no wireless hardware: exits 0 (nothing to retry — this is every QEMU run)", rc, 0)
check("…records verdict=ok", status_fields(root)["verdict"], "ok")
check("…and stands down so it is not a permanent failed unit", link_present(root / deck_wifi.FIRST_BOOT_WANTS_REL), False)

rc, out, err, root = run_script("connected", state="carried=yes\nstatus=connected\nssid=Cafe WiFi\n", wireless=True, nmcli="connected")
check("connected: exits 0", rc, 0)
check("…verdict=ok", status_fields(root)["verdict"], "ok")
check("…and disables itself for future boots", link_present(root / deck_wifi.FIRST_BOOT_WANTS_REL), False)

rc, out, err, root = run_script("siteonly", state="carried=yes\nstatus=connected\nssid=Cafe\n", wireless=True, nmcli="connected (site only)")
check("'connected (site only)' counts as connected", rc, 0)

rc, out, err, root = run_script("degraded", state="carried=yes\nstatus=connected\nssid=Cafe WiFi\n", wireless=True, nmcli="disconnected")
check("🔴 carried but not connected: exits NON-ZERO so systemctl --failed shows it", rc, 1)
check("…verdict=degraded", status_fields(root)["verdict"], "degraded")
check("…the message names the network", "Cafe WiFi" in status_fields(root)["message"], True)
check("🔴 …and it stays enabled, so it retries next boot", (root / deck_wifi.FIRST_BOOT_WANTS_REL).is_symlink(), True)
check("…and it said so on stderr", "not connected" in err, True)

rc, out, err, root = run_script("nocreds", state="carried=no\nstatus=skipped\nssid=\n", wireless=True, nmcli="disconnected")
check("no credentials carried: exits non-zero", rc, 1)
check("…and the message tells the user where to go", "Desktop Mode" in status_fields(root)["message"], True)
check("…naming why there is no network", "skipped" in status_fields(root)["message"], True)

rc, out, err, root = run_script("nonmcli", state="carried=yes\nstatus=connected\nssid=x\n", wireless=True, nmcli=None)
check("no nmcli: exits non-zero rather than claiming success", rc, 1)
check("…verdict=unknown, not ok", status_fields(root)["verdict"], "unknown")

rc, out, err, root = run_script("nostate", state=None, wireless=True, nmcli="disconnected")
check("no state file: says configure_deck did not finish", "did not run" in err, True)
check("…and still reports rather than exiting 0", rc, 1)

canary = WORK / "canary-shell"
hostile_state = f'carried=no\nstatus=skipped\nssid=$(touch {canary})`touch {canary}`\n'
rc, out, err, root = run_script("hostile", state=hostile_state, wireless=True, nmcli="disconnected")
check("🔴 a shell-metacharacter SSID is not executed by the script", canary.exists(), False)
check("…it is echoed back literally", "$(touch" in status_fields(root)["ssid"], True)

rc, out, err, root = run_script(
    "forged", state="carried=no\nstatus=skipped\nssid=x\ncarried=yes\n", wireless=True, nmcli="disconnected"
)
check("🔴 a forged second carried= line does not win (first-wins)", status_fields(root)["carried"], "no")
check("…so the message is still the no-credentials one", "No Wi-Fi was set up" in status_fields(root)["message"], True)

rc, out, err, root = run_script(
    "controls", state="carried=no\nstatus=skipped\nssid=ev\x01il\n", wireless=True, nmcli="disconnected"
)
check("control bytes are stripped before the SSID is written back out", status_fields(root)["ssid"], "evil")
check("the status file is 0644", mode_of(root / "var/lib/omarchy-deck/wifi-status"), "0644")


print()
print(f"{CHECKS - FAILURES}/{CHECKS} checks passed")
if FAILURES:
    print(f"{FAILURES} FAILURES")
shutil.rmtree(WORK, ignore_errors=True)
sys.exit(1 if FAILURES else 0)
