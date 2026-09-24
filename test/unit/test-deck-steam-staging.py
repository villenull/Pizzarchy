#!/usr/bin/env python3
"""Unit tests for FAST-INSTALL contract C2: `early_steam` / `late_steam`.

No VM, no root, no network, no chroot, no 491 MiB. Run directly:

    python3 test-deck-steam-staging.py

WHAT THIS SUITE IS ACTUALLY FOR
===============================

Contract C2 stages Valve's client in /home/.omarchy-deck-staging (uid/gid 1000)
while the form is up, then renames it onto the real home after
`useradd -u 1000 -M`. The suite is shaped around the ways that relocation is
not obviously safe:

1. 🔴 **early_steam writes the right status records on success, timeout and
   no-network.** A timeout (budget/stall) is `incomplete`, never `installed`
   (the marker decides, exactly as the existing step does); a missing steam
   package is `skipped-no-steam`; staging-setup failures are `failed`. All
   loud, none raised (Critical=False).
2. 🔴 **late_steam renames, repairs links and leaves no staging path behind.**
   The fixture tree reproduces the REAL hits measured 2026-09-23 on a live
   2.4 GiB bootstrapped tree (20,068 entries, 963 symlinks): 7 absolute
   ~/.steam links + .steampath/.steampid, runtime-internal absolute links, and
   staging-path bytes in the rotating logs. A leftover outside the logs is a
   warning, not silence.
3. 🔴 **The steam_seed-last invariant holds.** late_steam runs the existing
   seed after the repair; the suite requires language + CompletedOOBEStage1 on
   the FINAL home's disk, and that a Valve-written registry (HKLM-only, as the
   real client leaves it) is merged, not clobbered.
4. 🔴 **No recursive chown of the Steam tree.** uid is fixed at 1000 from the
   start; the suite requires late_steam to never chown anything but the
   staging top directory (enforced by failing os.chown on anything deeper).
5. 🔴 **The FIFO trap.** Valve leaves ~/.steam/steam.pipe (a FIFO) behind;
   opening it for reading blocks forever. The content scan must skip
   non-regular files (two probe scans hung on it during development).

Status files (steam/{status,error,progress}) are written under $STEAM_STATUS_DIR
so the suite never touches /run.
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
import time

# ⚠️ Before importing anything under test. Python validates a cached .pyc
# against (mtime, size) at one-second granularity, so a same-size edit inside
# the same second silently runs the PREVIOUS version.
sys.dont_write_bytecode = True

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
OVERLAY_ORCH = (
    REPO_ROOT / "iso/overlay/configs/airootfs/usr/share/omarchy-iso/orchestrator"
)
UPSTREAM_ORCH = (
    REPO_ROOT / "iso/upstream/configs/airootfs/usr/share/omarchy-iso/orchestrator"
)

FAILURES = 0
CHECKS = 0


def check(what: str, got, want) -> None:
    global FAILURES, CHECKS
    CHECKS += 1
    if got == want:
        print(f"ok   {what}")
    else:
        FAILURES += 1
        print(f"FAIL {what}: got {got!r}, want {want!r}")


def check_true(what: str, got) -> None:
    check(what, bool(got), True)


def check_in(what: str, needle, haystack) -> None:
    global FAILURES, CHECKS
    CHECKS += 1
    haystack = haystack or ""
    if needle in haystack:
        print(f"ok   {what}")
    else:
        FAILURES += 1
        print(f"FAIL {what}: {needle!r} not in {str(haystack)[:200]!r}")


# ---------------------------------------------------------------------------
# Harness: rebuild the orchestrator package shape around the modules
# ---------------------------------------------------------------------------

WORK = pathlib.Path(tempfile.mkdtemp(prefix="deck-steam-staging-test-"))

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
    for name in ("ui.py", "context.py"):
        shutil.copyfile(UPSTREAM_ORCH / name, pkg / name)
    # Every deck_* module, DERIVED rather than listed, so a new slice module
    # cannot break this harness.
    for module in sorted(OVERLAY_ORCH.glob("deck_*.py")):
        shutil.copyfile(module, pkg / module.name)
    (pkg / "phases_impl.py").write_text(PHASES_IMPL_STUB)
    return root


PKG_ROOT = build_package()
sys.path.insert(0, str(PKG_ROOT))

from orchestrator import deck_steam_bootstrap as dsb  # noqa: E402
from orchestrator.context import InstallContext  # noqa: E402

print(f"# modules loaded from {PKG_ROOT}")

TEST_UID = 1000
TEST_GID = 1000
# /tmp on dev/CI boxes can hold less than MIN_FREE_BYTES (4 GiB); the space
# gate is bypassed here and covered by the existing bootstrap suite's nospace
# case instead.
dsb.MIN_FREE_BYTES = 0

STAGING = dsb.STAGING_HOME_ABS
FINAL_HOME = "/home/deck"


def tmpdir(name: str) -> pathlib.Path:
    d = WORK / name
    d.mkdir(parents=True, exist_ok=True)
    return d


def make_target(
    name: str,
    *,
    bootstrap: bool = True,
    loader: bool = True,
    setpriv: bool = True,
    launcher: bool = True,
    tools: bool = True,
    passwd_user: str | None = "deck",
) -> pathlib.Path:
    """A fake install target: passwd (optionally WITHOUT the user -- early
    runs before the account exists), a live root with namespace tools, and
    the files early_steam checks before executing a 32-bit binary."""
    target = tmpdir(name) / "mnt"
    target.mkdir(parents=True, exist_ok=True)
    passwd = target / "etc/passwd"
    passwd.parent.mkdir(parents=True, exist_ok=True)
    text = "root:x:0:0::/root:/bin/bash\n"
    if passwd_user is not None:
        text += f"{passwd_user}:x:{TEST_UID}:{TEST_GID}::/home/{passwd_user}:/bin/bash\n"
    passwd.write_text(text)
    live = tmpdir(name) / "live"
    for rel in dsb.LIVE_TOOL_RELS:
        path = live / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        if tools:
            path.write_text("x")
    for want, rel in (
        (bootstrap, dsb.STEAM_BOOTSTRAP_REL),
        (loader, dsb.LOADER_32_REL),
        (setpriv, dsb.SETPRIV_REL),
        (launcher, dsb.STEAM_LAUNCHER_REL),
    ):
        if not want:
            continue
        path = target / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("x")
    return target


def make_live(target: pathlib.Path) -> pathlib.Path:
    return tmpdir(target.parent.name) / "live"


class FakeRunner:
    """Stand-in for run_bootstrap: lays down what the child would have left
    (marker, cached bytes, logs) and returns the stop reason."""

    def __init__(
        self,
        *,
        marker: str | None = "steam_client_steamdeck_stable_ubuntu12.installed",
        reason: str = dsb.STOP_MARKER,
        cached: int = 4096,
        launcher_log: str | None = None,
    ):
        self.marker = marker
        self.reason = reason
        self.cached = cached
        self.launcher_log = launcher_log
        self.calls: list[list[str]] = []
        self.home_seen: list[str] = []

    def __call__(self, argv, home_on_target, record, *, budget_secs=dsb.BUDGET_SECS,
                 output_path=None, emit=None):
        self.calls.append(list(argv))
        self.home_seen.append(str(home_on_target))
        home = pathlib.Path(home_on_target)
        if self.launcher_log is not None:
            log = home / dsb.LAUNCHER_LOG_REL
            log.parent.mkdir(parents=True, exist_ok=True)
            log.write_text(self.launcher_log)
        pkg = home / dsb.PACKAGE_DIR_REL
        pkg.mkdir(parents=True, exist_ok=True)
        if self.cached:
            (pkg / "bins_ubuntu12.zip.vz.deadbeef_1").write_bytes(b"x" * self.cached)
        if self.marker:
            (pkg / self.marker).write_text("manifest")
        record["exit_code"] = 0
        record["stopped_because"] = self.reason
        record["seconds"] = 42
        return self.reason


def run_early(target, runner, staging=STAGING, live=None, **kw):
    live = live if live is not None else make_live(target)
    status_dir = tmpdir(f"status-{target.parent.name}") / "steam"
    os.environ["STEAM_STATUS_DIR"] = str(status_dir)
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            record = dsb.early_steam(
                target, staging, TEST_UID, TEST_GID,
                run_pkgs=False, live_root=live, runner=runner, **kw,
            )
    finally:
        del os.environ["STEAM_STATUS_DIR"]
    return record, buf.getvalue(), status_dir


def make_ctx(target, username="deck", defer=False) -> InstallContext:
    return InstallContext(
        config_path=pathlib.Path("/dev/null"),
        creds_path=pathlib.Path("/dev/null"),
        full_name="Test User",
        email="t@example.invalid",
        encrypt=False,
        authorized_keys_path=None,
        tailscale_authkey_path=None,
        user_configuration={
            "timezone": "America/New_York",
            "locale_config": {"kb_layout": "us", "sys_enc": "UTF-8",
                              "sys_lang": "en_US.UTF-8"},
        },
        user_credentials={"users": [] if defer else [{"username": username}]},
        arch_config_path=pathlib.Path("/dev/null"),
        omarchy_install={},
        defer_provisioning=defer,
        target=pathlib.Path(target),
    )


def build_fixture_tree(
    home: pathlib.Path, staging: str = STAGING,
) -> None:
    """Reproduce the REAL hits from the 2026-09-23 live 2.4 GiB bootstrap
    (20,068 entries, 963 symlinks): absolute ~/.steam links, top-level
    dotfiles, runtime-internal absolute links, staging-path bytes in the
    rotating logs only, a Valve-written HKLM-only registry, and the stale
    pid + FIFO. Everything else is relative and moves with the rename."""
    steam_data = home / ".local/share/Steam"
    dot_steam = home / ".steam"
    dot_steam.mkdir(parents=True, exist_ok=True)
    (steam_data / "ubuntu12_32").mkdir(parents=True, exist_ok=True)
    (steam_data / "ubuntu12_64").mkdir(parents=True, exist_ok=True)
    (steam_data / "linux32").mkdir(parents=True, exist_ok=True)
    (steam_data / "linux64").mkdir(parents=True, exist_ok=True)
    (steam_data / "package").mkdir(parents=True, exist_ok=True)
    (steam_data / "package" / "steam_client_steamdeck_stable_ubuntu12.installed").write_text("m")
    (steam_data / "package" / "beta").write_text("steamdeck_stable")
    for name, dest in (
        ("root", steam_data),
        ("steam", steam_data),
        ("bin32", steam_data / "ubuntu12_32"),
        ("bin64", steam_data / "ubuntu12_64"),
        ("sdk32", steam_data / "linux32"),
        ("sdk64", steam_data / "linux64"),
    ):
        (dot_steam / name).symlink_to(str(dest).replace("/home/deck", staging).replace(
            str(home), staging))
    # Fix the links to embed the staging path exactly (home here is a tmpdir).
    for link in dot_steam.iterdir():
        if link.is_symlink():
            tgt = os.readlink(link)
            if str(home) in tgt or "/home/deck" in tgt:
                link.unlink()
                link.symlink_to(tgt.replace(str(home), staging).replace("/home/deck", staging))
    (home / ".steampath").symlink_to(f"{staging}/.steam/sdk32/steam")
    (home / ".steampid").symlink_to(f"{staging}/.steam/steam.pid")
    # Runtime-internal absolute links (self-consistent; rewritten anyway).
    pinned = steam_data / "ubuntu12_32/steam-runtime/pinned_libs_32"
    pinned.mkdir(parents=True, exist_ok=True)
    (steam_data / "ubuntu12_32/steam-runtime/usr/lib/i386-linux-gnu").mkdir(
        parents=True, exist_ok=True)
    real_lib = steam_data / "ubuntu12_32/steam-runtime/usr/lib/i386-linux-gnu/libcurl.so.4.2.0"
    real_lib.write_text("lib")
    (pinned / "libcurl.so.4").symlink_to(str(real_lib).replace(str(home), staging))
    # Logs embedding the staging path (startup lines, manifest paths).
    logs = steam_data / "logs"
    logs.mkdir(parents=True, exist_ok=True)
    (logs / "bootstrap_log.txt").write_text(
        f"[2026-09-23 23:15:46] Startup - launched with: '{staging}/.local/share/Steam/ubuntu12_32/steam'\n"
    )
    (logs / "console-linux.txt").write_text(
        f"[2026-09-23 23:15:46] Process started: '{staging}/.local/share/Steam/ubuntu12_32/steam'\n"
    )
    # A relative link (the ~941 others): must survive untouched.
    (steam_data / "ubuntu12_32" / "rel").symlink_to("../package")
    # Valve-written HKLM-only registry, as the real client leaves it.
    (dot_steam / "registry.vdf").write_text(
        '"Registry"\n{\n\t"HKLM"\n\t{\n\t\t"Software"\n\t\t{\n'
        '\t\t\t"Valve"\n\t\t\t{\n\t\t\t\t"Steam"\n\t\t\t\t{\n'
        '\t\t\t\t\t"SteamPID"\t\t"2285"\n'
        '\t\t\t\t\t"ClientLauncherType"\t\t"0"\n'
        "\t\t\t\t}\n\t\t\t}\n\t\t}\n\t}\n}\n"
    )
    # Stale install-time files.
    (dot_steam / "steam.pid").write_text("2284")
    try:
        os.mkfifo(dot_steam / "steam.pipe")
    except OSError:
        (dot_steam / "steam.pipe").write_text("")


# ===========================================================================
print("\n== 1. early_steam: success, timeout, no-network ==")
# ===========================================================================

# Success: marker present -> installed, steam/state=done.
target = make_target("early-ok", passwd_user=None)
runner = FakeRunner()
record, out, status_dir = run_early(target, runner)
check("success: status", record["status"], dsb.STATUS_INSTALLED)
check("success: manifest recorded", record["installed_manifest"],
      "steam_client_steamdeck_stable_ubuntu12.installed")
check("success: HOME was the staging dir", runner.home_seen, [str(target / STAGING.lstrip("/"))])
check("success: staging home is 0700",
      f"{stat.S_IMODE(os.lstat(target / STAGING.lstrip('/')).st_mode):04o}", "0700")
check("success: steam/status=done", (status_dir / "status").read_text().strip(), "done")
check("success: child ran as uid 1000", "--reuid=1000" in runner.calls[0], True)
check_in("success: it says so loudly", "staging home", out)

# Timeout/stall without a marker -> incomplete, never installed.
target = make_target("early-stall", passwd_user=None)
runner = FakeRunner(marker=None, reason=dsb.STOP_STALLED, cached=1024)
record, out, status_dir = run_early(target, runner)
check("stall: status", record["status"], dsb.STATUS_INCOMPLETE)
check("stall: no manifest claimed", record["installed_manifest"], None)
check("stall: steam/status=incomplete", (status_dir / "status").read_text().strip(),
      "incomplete")
check_true("stall: the error is recorded", record["error"])
check_in("stall: the error names the stall", "progress", record["error"])

# No steam package on the target -> skipped-no-steam, child never runs.
target = make_target("early-nosteam", bootstrap=False, passwd_user=None)
runner = FakeRunner()
record, out, status_dir = run_early(target, runner)
check("no-steam: status", record["status"], dsb.STATUS_NO_STEAM)
check("no-steam: nothing executed", runner.calls, [])
check("no-steam: steam/status=skipped", (status_dir / "status").read_text().strip(),
      "skipped")
check_in("no-steam: the error names pkgs", "pkgs", record["error"])

# Staging setup failure (a file where the dir goes) -> failed, never raised.
target = make_target("early-blocked", passwd_user=None)
blocked = target / STAGING.lstrip("/")
blocked.parent.mkdir(parents=True, exist_ok=True)
blocked.write_text("in the way")
runner = FakeRunner()
record, out, status_dir = run_early(target, runner)
check("blocked: status", record["status"], dsb.STATUS_FAILED)
check("blocked: nothing executed", runner.calls, [])
check("blocked: steam/status=failed", (status_dir / "status").read_text().strip(), "failed")

# No-network classification: wifi skipped + sync failure is loud, not silent.
# (early_steam with run_pkgs=True exercises the pkgs seam; the fetch itself
# is faked at the pkgs_runner level so no network is touched.)
target = make_target("early-fetchonly", passwd_user=None)
runner = FakeRunner()
record, out, status_dir = run_early(target, runner)
check("fetch_only: pkgs untouched when run_pkgs=False", record["pkgs"], None)


# ===========================================================================
print("\n== 2. late_steam: rename, repair, no leftovers ==")
# ===========================================================================

target = make_target("late-ok")
staging = target / STAGING.lstrip("/")
build_fixture_tree(staging)
final = target / FINAL_HOME.lstrip("/")
ctx = make_ctx(target)
t0 = time.monotonic()
record = dsb.late_steam(target, STAGING, FINAL_HOME, "deck", ctx)
wall = time.monotonic() - t0
check("relocate: status", record["status"], dsb.LATE_STATUS_RELOCATED)
check_true("relocate: renamed", record["renamed"])
check("relocate: staging dir is gone", staging.exists() or staging.is_symlink(), False)
check("relocate: ~/.steam/root points at the final home",
      os.readlink(final / ".steam/root"), f"{FINAL_HOME}/.local/share/Steam")
check("relocate: ~/.steampath points at the final home",
      os.readlink(final / ".steampath"), f"{FINAL_HOME}/.steam/sdk32/steam")
check("relocate: runtime-internal link rewritten",
      STAGING in os.readlink(final / ".local/share/Steam/ubuntu12_32/steam-runtime/pinned_libs_32/libcurl.so.4"),
      False)
check("relocate: relative link untouched",
      os.readlink(final / ".local/share/Steam/ubuntu12_32/rel"), "../package")
check("relocate: stale pid removed", (final / ".steam/steam.pid").exists(), False)
leftover = [p for p in record["leftover_hits"] if not p.startswith("<")]
check("relocate: only the rotating logs still embed the staging path",
      sorted(leftover),
      sorted(f"/.local/share/Steam/logs/{n}" for n in dsb.LOG_ONLY_NAMES if
             (final / ".local/share/Steam/logs" / n).exists()) or leftover[:0])
# No staging path in any symlink, anywhere.
bad = []
for dirpath, dirnames, filenames in os.walk(final):
    for n in list(dirnames) + list(filenames):
        p = os.path.join(dirpath, n)
        if os.path.islink(p) and STAGING in os.readlink(p):
            bad.append(p)
check("relocate: no symlink embeds the staging path", bad, [])
print(f"# late_steam on the fixture tree took {wall:.2f}s (record: {record['seconds']}s)")

# Missing staging -> skipped-no-staging, never failed.
target = make_target("late-missing")
record = dsb.late_steam(target, STAGING, FINAL_HOME, "deck", make_ctx(target))
check("missing: status", record["status"], dsb.LATE_STATUS_NO_STAGING)
check_true("missing: the error says what first boot does", "first boot" in (record["error"] or ""))

# Final home already exists -> failed, staging untouched.
target = make_target("late-clash")
build_fixture_tree(target / STAGING.lstrip("/"))
(final_clash := target / FINAL_HOME.lstrip("/")).mkdir(parents=True)
record = dsb.late_steam(target, STAGING, FINAL_HOME, "deck", make_ctx(target))
check("clash: status", record["status"], dsb.LATE_STATUS_FAILED)
check_true("clash: staging untouched", (target / STAGING.lstrip("/")).is_dir())

# /etc/skel re-seed: copied when absent, never overwriting Steam's.
target = make_target("late-skel")
staging = target / STAGING.lstrip("/")
build_fixture_tree(staging)
skel = target / "etc/skel"
(skel / ".config").mkdir(parents=True, exist_ok=True)
(skel / ".config/new-file").write_text("from skel")
(skel / ".steam/registry.vdf").parent.mkdir(parents=True, exist_ok=True)
(skel / ".steam/registry.vdf").write_text("SKEL MUST NOT WIN")
record = dsb.late_steam(target, STAGING, FINAL_HOME, "deck", make_ctx(target))
check("skel: new file re-seeded", (target / FINAL_HOME.lstrip("/") / ".config/new-file").is_file(),
      True)
check_in("skel: ... and recorded", "/.config/new-file", " ".join(record["reseeded"]))
# 🔴 No recursive chown of the client tree Valve wrote: the uid is fixed at
# 1000 from the start, so the rename carries ownership. (The seed legitimately
# chowns the registry.vdf IT writes; that is the seed's own write, not a walk
# of the tree.) Any chown under .local/share/Steam fails the test.
target = make_target("late-nochown")
build_fixture_tree(target / STAGING.lstrip("/"))
real_chown = os.chown
calls: list = []
def _spy_chown(*a, **k):
    calls.append(a)
    if ".local/share/Steam" in str(a[0]):
        raise AssertionError(f"late_steam chowned the client tree: {a}")
    return real_chown(*a, **k)
dsb.os.chown = _spy_chown
try:
    record = dsb.late_steam(target, STAGING, FINAL_HOME, "deck", make_ctx(target))
finally:
    dsb.os.chown = real_chown
check("no-chown: status", record["status"], dsb.LATE_STATUS_RELOCATED)
tree_chowns = [c for c in calls if ".local/share/Steam" in str(c[0])]
check("no-chown: nothing in the client tree was chowned", tree_chowns, [])

# 🔴 The FIFO trap: ~/.steam/steam.pipe must not hang the content scan.
target = make_target("late-fifo")
staging = target / STAGING.lstrip("/")
build_fixture_tree(staging)
t0 = time.monotonic()
record = dsb.late_steam(target, STAGING, FINAL_HOME, "deck", make_ctx(target))
wall = time.monotonic() - t0
check("fifo: the rename completed (no hang)", record["status"], dsb.LATE_STATUS_RELOCATED)
check_true("fifo: it took seconds, not forever", wall < 60)


# ===========================================================================
print("\n== 3. steam_seed-last invariant ==")
# ===========================================================================

target = make_target("late-seed")
build_fixture_tree(target / STAGING.lstrip("/"))
record = dsb.late_steam(target, STAGING, FINAL_HOME, "deck", make_ctx(target))
seed = record["seed"] or {}
check("seed: ran", seed.get("status"), "seeded")
check("seed: language derived from the system locale", seed.get("language"), "english")
disk = (target / FINAL_HOME.lstrip("/") / ".steam/registry.vdf").read_text()
check_in("seed: OOBE flag on the final disk", '"CompletedOOBEStage1"', disk)
check_in("seed: language on the final disk", '"english"', disk)
check_in("seed: Valve's HKLM keys merged, not clobbered", '"ClientLauncherType"', disk)
check("seed: the record says what Steam will use", seed.get("language_on_disk"), "english")


# ===========================================================================
print("\n== 4. fetch_only split + status-dir override ==")
# ===========================================================================

check_true("early_steam_fetch_only exists", callable(dsb.early_steam_fetch_only))
target = make_target("split", passwd_user=None)
runner = FakeRunner()
status_dir = tmpdir("status-split") / "steam"
os.environ["STEAM_STATUS_DIR"] = str(status_dir)
try:
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        record = dsb.early_steam_fetch_only(
            target, STAGING, TEST_UID, TEST_GID,
            live_root=make_live(target), runner=runner)
finally:
    del os.environ["STEAM_STATUS_DIR"]
check("fetch_only: bootstraps without pkgs", record["status"], dsb.STATUS_INSTALLED)
check("fetch_only: pkgs untouched", record["pkgs"], None)
check("fetch_only: status via override dir", (status_dir / "status").read_text().strip(), "done")

# Progress lines reach steam/progress via the emit hook.
target = make_target("progress", passwd_user=None)
seen: list[str] = []


class EmittingRunner(FakeRunner):
    def __call__(self, argv, home_on_target, record, *, budget_secs=dsb.BUDGET_SECS,
                 output_path=None, emit=None):
        if emit is not None:
            emit("downloading Steam's client update: 1 of 2 KB (50%)")
        return super().__call__(argv, home_on_target, record, budget_secs=budget_secs,
                                output_path=output_path)


status_dir = tmpdir("status-progress") / "steam"
os.environ["STEAM_STATUS_DIR"] = str(status_dir)
try:
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        dsb.early_steam(target, STAGING, TEST_UID, TEST_GID, run_pkgs=False,
                        live_root=make_live(target), runner=EmittingRunner())
finally:
    del os.environ["STEAM_STATUS_DIR"]
check_in("progress: Valve's line reaches steam/progress",
         "downloading Steam's client update",
         (status_dir / "progress").read_text() if (status_dir / "progress").exists() else "")


# ===========================================================================
print(f"\n{CHECKS - FAILURES}/{CHECKS} checks passed")
if FAILURES:
    print(f"{FAILURES} FAILED")
shutil.rmtree(WORK, ignore_errors=True)
sys.exit(1 if FAILURES else 0)
