#!/usr/bin/env python3
"""Unit tests for `configure_deck`'s `steam_bootstrap` step.

No VM, no root, no network, no chroot, no ISO build, no 491 MiB. Run directly:

    python3 test-deck-steam-bootstrap.py

WHAT THIS SUITE IS ACTUALLY FOR
===============================

`deck_steam_bootstrap.py` replaces a step that was removed for hanging an
install (`deck_steam_prewarm`, commit `ac93758`). Its budget existed, was
documented, and did not stop anything. So this suite is deliberately shaped
around the ways a bounded-looking thing is not bounded, and around the ways an
install step makes things *worse* rather than merely failing:

1. 🔴 **The bound must fire, and it must fire on the group.** §4 drives a child
   that never exits and never makes progress and requires the stall watchdog to
   stop it; §5 does the same for the whole-step budget; §6 requires that every
   exit path calls `killpg` — not `kill` — because a measured run left
   `srt-logger` behind when only the direct child was killed.

2. 🔴 **A zero exit is not success.** §3 drives a child that exits 0 having
   installed nothing (which is exactly what Valve's updater does when the
   network is down — measured, see the module docstring) and requires
   `status="incomplete"`, never `installed`.

3. 🔴 **The floor.** §7 requires that every refusal path leaves the target's
   filesystem untouched and says so, and that the record explains what first
   boot will now do.

4. 🔴 **The environment is built, not inherited.** §2 puts junk in `os.environ`
   and requires it not to reach the child: one measured run leaked
   `XDG_DATA_HOME` and Valve's launcher bootstrapped a completely different
   Steam directory.

5. 🔴 **It must not be able to kill the machine it is running on.** §6 requires
   `processes_rooted_in` to refuse a target of `/`, which would otherwise match
   every process on the installer.

6. 🔴 **It must not be a chroot, and the failure must arrive explained.** Added
   2026-08-16 after the first hardware install ran this step and it *failed*
   with a bare `exit_code: 71` and one line of output. Measured cause: the
   kernel refuses `unshare(CLONE_NEWUSER)` to any chrooted process, Valve's
   launcher hard-gates on a working user namespace, and `arch-chroot` is a
   chroot. §2 now requires the entry to pivot rather than chroot; §10 requires
   the reason a launcher refused to start to reach the record and the console,
   because on that install it reached neither.

⚠️ §9's registry check is a **MERGE GATE**. This agent does not own
`deck_configure.py`; the registry line is added when this work is merged. Until
then that one check is red ON PURPOSE and its failure message says so. Do not
"fix" it by deleting it.
"""

from __future__ import annotations

import contextlib
import io
import os
import pathlib
import shutil
import sys
import tempfile

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
        print(f"FAIL {what}: got {got!r}, want {want!r}")
        FAILURES += 1


def check_true(what: str, got) -> None:
    check(what, bool(got), True)


def check_in(what: str, needle, haystack) -> None:
    global FAILURES, CHECKS
    CHECKS += 1
    if needle in haystack:
        print(f"ok   {what}")
    else:
        print(f"FAIL {what}: {needle!r} not in {haystack!r}")
        FAILURES += 1


# ---------------------------------------------------------------------------
# Harness: rebuild the orchestrator package shape around the modules
# ---------------------------------------------------------------------------

WORK = pathlib.Path(tempfile.mkdtemp(prefix="deck-steam-bootstrap-test-"))

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
    # The REAL ui.py from the pinned upstream tree, not a stub: if upstream
    # renames info/error this suite goes red, which is the cheap drift signal.
    shutil.copyfile(UPSTREAM_ORCH / "ui.py", pkg / "ui.py")
    # Every deck_* module, DERIVED rather than listed, for the same reason the
    # sibling suites derive it: deck_steps() imports each registered module
    # lazily and a new slice must not break this harness.
    for module in sorted(OVERLAY_ORCH.glob("deck_*.py")):
        shutil.copyfile(module, pkg / module.name)
    (pkg / "phases_impl.py").write_text(PHASES_IMPL_STUB)
    return root


PKG_ROOT = build_package()
sys.path.insert(0, str(PKG_ROOT))

from orchestrator import deck_configure, deck_pkgs, deck_steam_bootstrap as dsb  # noqa: E402

print(f"# modules loaded from {PKG_ROOT}")


class FakeCtx:
    def __init__(self, target, username="deck", defer_provisioning=False):
        self.target = pathlib.Path(target)
        self.username = username
        self.defer_provisioning = defer_provisioning


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
    user: str = "deck",
    uid: int = 1000,
    home: str | None = None,
    make_home: bool = True,
) -> pathlib.Path:
    """A fake install target: a passwd file, a home, and the four files the
    step checks for before it is willing to execute a 32-bit binary."""
    target = tmpdir(name) / "mnt"
    target.mkdir(parents=True, exist_ok=True)
    home = home or f"/home/{user}"

    passwd = target / "etc/passwd"
    passwd.parent.mkdir(parents=True, exist_ok=True)
    passwd.write_text(
        "root:x:0:0::/root:/bin/bash\n"
        f"{user}:x:{uid}:{uid}::{home}:/bin/bash\n"
    )
    if make_home:
        (target / home.lstrip("/")).mkdir(parents=True, exist_ok=True)

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


def make_live(name: str = "live", *, tools: bool = True) -> pathlib.Path:
    """A fake live (installer) root.

    🔴 It carries `unshare` and `pivot_root` because the step now enters the
    target with those instead of `arch-chroot` -- a chroot cannot run Valve's
    launcher at all (see the module docstring). Pass `tools=False` for the
    target-less-installer case.
    """
    live = tmpdir(name)
    for rel in dsb.LIVE_TOOL_RELS:
        path = live / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        if tools:
            path.write_text("x")
        elif path.exists():
            path.unlink()
    return live


def run_step(ctx, runner, live=None, budget=dsb.BUDGET_SECS):
    """bootstrap_steam with the console captured, so 'loud' is assertable."""
    live = live or make_live()
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        record = dsb.bootstrap_steam(ctx, live, runner=runner, budget_secs=budget)
    return record, buf.getvalue()


class RecordingRunner:
    """A stand-in for `run_bootstrap`. Records the argv and simulates what the
    child left behind, so every branch of the step is drivable with no
    subprocess and no network."""

    def __init__(
        self,
        *,
        marker=None,
        exit_code=0,
        reason=dsb.STOP_EXITED,
        cached=0,
        launcher_log=None,
    ):
        self.marker = marker
        self.exit_code = exit_code
        self.reason = reason
        self.cached = cached
        # What `steam.sh` wrote to console-linux.txt before it gave up. On the
        # 2026-08-16 hardware failure this file held the entire diagnosis and
        # nothing read it.
        self.launcher_log = launcher_log
        self.calls: list[list[str]] = []

    def __call__(self, argv, home_on_target, record, *, budget_secs=dsb.BUDGET_SECS, output_path=None):
        self.calls.append(list(argv))
        if self.launcher_log is not None:
            log = home_on_target / dsb.LAUNCHER_LOG_REL
            log.parent.mkdir(parents=True, exist_ok=True)
            log.write_text(self.launcher_log)
        pkg = home_on_target / dsb.PACKAGE_DIR_REL
        pkg.mkdir(parents=True, exist_ok=True)
        if self.cached:
            (pkg / "bins_ubuntu12.zip.vz.deadbeef_1").write_bytes(b"x" * self.cached)
        if self.marker:
            (pkg / self.marker).write_text("manifest")
        record["exit_code"] = self.exit_code
        record["stopped_because"] = self.reason
        record["seconds"] = 42
        return self.reason


# ===========================================================================
print("\n== 1. what the step refuses to run, and why ==")
# ===========================================================================

for label, kwargs, want_status, want_phrase in (
    ("no Steam bootstrap tarball", {"bootstrap": False}, dsb.STATUS_NO_STEAM, "pkgs"),
    ("no 32-bit loader", {"loader": False}, dsb.STATUS_NO_MULTILIB, "32-bit"),
    ("no setpriv", {"setpriv": False}, dsb.STATUS_NO_MULTILIB, "setpriv"),
    ("no /usr/bin/steam", {"launcher": False}, dsb.STATUS_NO_MULTILIB, "steam"),
):
    target = make_target(f"refuse-{want_status}-{label.replace(' ', '-')}", **kwargs)
    runner = RecordingRunner()
    record, out = run_step(FakeCtx(target), runner)
    check(f"{label}: status", record["status"], want_status)
    check(f"{label}: nothing was executed", runner.calls, [])
    check_true(f"{label}: the record explains it", record["error"])
    check_in(f"{label}: the error names {want_phrase}", want_phrase, record["error"])
    check_true(f"{label}: it is printed, not swallowed", "Steam client bootstrap:" in out)
    check_true(
        f"{label}: the target's home was not touched",
        not (target / "home/deck/.local").exists(),
    )

# 🔴 deferred provisioning is not a failure: there is no account yet.
target = make_target("deferred")
runner = RecordingRunner()
record, out = run_step(FakeCtx(target, username="", defer_provisioning=True), runner)
check("deferred: status", record["status"], dsb.STATUS_DEFERRED)
check("deferred: nothing was executed", runner.calls, [])
check_in("deferred: the error says what first boot does", "First boot", record["error"])

# 🔴 The live side has to be able to enter the target WITHOUT a chroot. If it
# cannot, the honest answer is to skip: running the command anyway is running a
# command measured to exit 71.
target = make_target("no-container")
runner = RecordingRunner()
record, out = run_step(FakeCtx(target), runner, live=make_live("live-bare", tools=False))
check("no unshare/pivot_root on the live system: status", record["status"], dsb.STATUS_NO_CONTAINER)
check("no unshare/pivot_root: nothing was executed", runner.calls, [])
check_in("...and the error names the user namespace", "user namespace", record["error"])
check_in("...and says what first boot does", "First boot", record["error"])
check_true("...and it is printed", "Steam client bootstrap:" in out)

# A home the installer never made is a failure, not a crash.
target = make_target("no-home", make_home=False)
runner = RecordingRunner()
record, _ = run_step(FakeCtx(target), runner)
check("absent home: status", record["status"], dsb.STATUS_FAILED)
check("absent home: nothing was executed", runner.calls, [])


# ===========================================================================
print("\n== 2. the command and the environment ==")
# ===========================================================================

argv = dsb.bootstrap_command("/mnt", 1000, 1000, "/home/deck", "deck")

# 🔴 THE HARDWARE DEFECT, AS A TEST. 2026-08-16: this step ran on the Deck and
# exited 71. 71 is `steam.sh`:511 -- `steam-runtime-check-requirements` -- and
# the reason it failed was reproduced off hardware: the kernel refuses
# `unshare(CLONE_NEWUSER)` to any chrooted process (`current_chrooted()`), so
# `bwrap` cannot run, so Valve's launcher refuses to start. That is true on
# every kernel with every sysctl, so this is not a regression guard, it is a
# structural one: if `arch-chroot` ever comes back, the step is dead again.
check("it is NOT a chroot -- a chroot cannot run Valve's launcher", "arch-chroot" in argv, False)
check("it enters the target with unshare", argv[0], "unshare")
for flag in ("--mount", "--pid", "--fork", "--propagation", "private"):
    check_in(f"the namespace carries {flag}", flag, argv[: argv.index("/bin/sh")])
# 🔴 pid 1 in a pid namespace ignores an unhandled SIGTERM even from an
# ancestor, so without this the first of stop_process_group's two signals is a
# no-op. Not decoration: it is what makes the polite stop mean anything.
check_in("the namespace's init dies with unshare", "--kill-child", argv)
_script_at = argv.index("-c") + 1
check("it runs this module's own entry script", argv[_script_at], dsb.ENTER_SCRIPT)
check("the target is the script's argument", argv[_script_at + 2], "/mnt")
check_in("the entry pivots into the target", "pivot_root . .", dsb.ENTER_SCRIPT)
# Comments stripped: the word appears in them, explaining why it is not used.
ENTER_CODE = "\n".join(
    line for line in dsb.ENTER_SCRIPT.splitlines() if not line.lstrip().startswith("#")
)
check("the entry script never chroots", "chroot" in ENTER_CODE, False)
# arch-chroot bound these; they are ours now, so they are asserted here.
# 🔴 Measured 2026-08-16: pivot_root onto an INHERITED mount fails with
# "Invalid argument"; onto the same path after a self-rbind it succeeds. The
# installer's target is an inherited mount, so this line is the fix working.
check_in('the entry binds the target onto itself first', 'mount --rbind "$t" "$t"', dsb.ENTER_SCRIPT)
for needed in ("mount -t proc", "/etc/resolv.conf", "$t/dev", "$t/tmp", "set -eu"):
    check_in(f"the entry provides {needed}", needed, dsb.ENTER_SCRIPT)
check(
    "becomes the user with setpriv, not sudo, once inside",
    argv[argv.index("setpriv") - 1],
    "/mnt",
)
check_in("passes the uid", "--reuid=1000", argv)
check_in("passes the gid", "--regid=1000", argv)
check_in("clears supplementary groups", "--clear-groups", argv)
check("scrubs the environment inside the chroot", argv[argv.index("env") + 1], "-i")
check("runs Valve's own launcher", argv[-len(dsb.BOOTSTRAP_ARGS) - 1], dsb.STEAM_LAUNCHER_ABS)
check("passes the measured argv", tuple(argv[-len(dsb.BOOTSTRAP_ARGS):]), dsb.BOOTSTRAP_ARGS)
# 🔴 measurement 4: the update BRANCH is chosen by this flag, so first boot's
# manifest and the one this step installs are the same one.
check_in("pins the branch with -steamdeck", "-steamdeck", dsb.BOOTSTRAP_ARGS)

# 🔴 measurement 6: a leaked XDG_DATA_HOME sent one measured run at a different
# Steam installation entirely.
os.environ["XDG_DATA_HOME"] = "/somewhere/else"
os.environ["DISPLAY"] = ":0"
try:
    env = dsb.child_env("/home/deck", "deck")
    check("env is built, not inherited: no XDG_DATA_HOME", "XDG_DATA_HOME" in env, False)
    check("env is built, not inherited: no DISPLAY", "DISPLAY" in env, False)
    check("env sets HOME to the target user's home", env["HOME"], "/home/deck")
    check("env sets USER", env["USER"], "deck")
    # Valve's own headless escape hatch (bin_steam.sh:49 / steam.sh:121).
    check("env suppresses zenity/xterm dialogs", env["XDG_CURRENT_DESKTOP"], "gamescope")
    rendered = dsb.bootstrap_command("/mnt", 1000, 1000, "/home/deck", "deck")
    check(
        "the rendered argv carries no inherited variable",
        [a for a in rendered if a.startswith(("XDG_DATA_HOME=", "DISPLAY="))],
        [],
    )
finally:
    del os.environ["XDG_DATA_HOME"]
    del os.environ["DISPLAY"]


# ===========================================================================
print("\n== 3. a zero exit is NOT success (measurement 3) ==")
# ===========================================================================

# Valve's updater exits 0 after printing 'Error: Steam needs to be online to
# update.' -- measured. So the outcome, not the exit code, decides.
target = make_target("exit-zero-no-marker")
runner = RecordingRunner(marker=None, exit_code=0, cached=1024)
record, out = run_step(FakeCtx(target), runner)
check("exit 0 with no manifest: status", record["status"], dsb.STATUS_INCOMPLETE)
check("exit 0 with no manifest: exit code recorded anyway", record["exit_code"], 0)
check("exit 0 with no manifest: no manifest claimed", record["installed_manifest"], None)
check_in("the error says first boot finishes the job", "first boot", record["error"].lower())
check_true("it is printed", "Steam client bootstrap:" in out)

# The success path is the presence of the marker, and it is recorded by name.
target = make_target("installs")
runner = RecordingRunner(marker="steam_client_steamdeck_stable_ubuntu12.installed", cached=4096)
record, out = run_step(FakeCtx(target), runner)
check("installed: status", record["status"], dsb.STATUS_INSTALLED)
check(
    "installed: the manifest is named in the record",
    record["installed_manifest"],
    "steam_client_steamdeck_stable_ubuntu12.installed",
)
# >= rather than ==: package/ holds the manifest file as well as the cache.
check("installed: the cached bytes are recorded", record["package_bytes"] >= 4096, True)
check_true("installed: it says so on the console", "Gaming Mode" in out)

# Idempotence: a second run must not open a socket or spawn anything.
runner2 = RecordingRunner()
record2, out2 = run_step(FakeCtx(target), runner2)
check("re-run: status", record2["status"], dsb.STATUS_ALREADY)
check("re-run: nothing was executed", runner2.calls, [])
check(
    "re-run: the manifest already there is reported",
    record2["installed_manifest"],
    "steam_client_steamdeck_stable_ubuntu12.installed",
)


# ===========================================================================
print("\n== 4. the no-progress watchdog (a stall, not a budget) ==")
# ===========================================================================


class FakeProc:
    """A child that never exits unless told to."""

    def __init__(self, pid=4242, exits_after=None):
        self.pid = pid
        self.returncode = None
        self._exits_after = exits_after
        self._polls = 0
        self.waited = False

    def poll(self):
        self._polls += 1
        if self._exits_after is not None and self._polls > self._exits_after:
            self.returncode = 0
        return self.returncode

    def wait(self, timeout=None):
        self.waited = True
        self.returncode = self.returncode if self.returncode is not None else -9
        return self.returncode


class FakeClock:
    def __init__(self, step=1.0):
        self.now = 0.0
        self.step = step

    def __call__(self):
        return self.now

    def sleep(self, seconds):
        self.now += max(seconds, self.step)


def drive(home, *, exits_after=None, stall=dsb.STALL_SECS, budget=dsb.BUDGET_SECS, killed=None):
    """Run the real run_bootstrap loop against a fake child and a fake clock."""
    proc = FakeProc(exits_after=exits_after)
    clock = FakeClock()
    record: dict = {}
    calls: list[tuple[int, int]] = []
    real_killpg = dsb.os.killpg

    def fake_killpg(pgid, sig):
        calls.append((pgid, sig))
        if killed is not None:
            killed.append((pgid, sig))

    dsb.os.killpg = fake_killpg
    try:
        reason = dsb.run_bootstrap(
            ["true"],
            home,
            record,
            budget_secs=budget,
            stall_secs=stall,
            spawner=lambda argv, out=None: proc,
            clock=clock,
            sleeper=clock.sleep,
            emit=lambda text: None,
        )
    finally:
        dsb.os.killpg = real_killpg
    return reason, record, calls, proc, clock


home = tmpdir("stall") / "home"
home.mkdir(parents=True, exist_ok=True)
reason, record, calls, proc, clock = drive(home, stall=30, budget=100000)
check("a child that never progresses is stopped", reason, dsb.STOP_STALLED)
check_true("it stops on the stall, long before the budget", clock.now < 100000)
check_true("the group was signalled", calls)
check(
    "the group gets both SIGTERM and SIGKILL, not just a poke",
    {dsb.signal.SIGTERM, dsb.signal.SIGKILL}.issubset({sig for _, sig in calls}),
    True,
)
check("it signals the process-group id", {pgid for pgid, _ in calls}, {proc.pid})
check("the reason is recorded", record["stopped_because"], dsb.STOP_STALLED)

# Progress must actually reset the watchdog, or the previous check is vacuous:
# a child that keeps writing to the log survives past the stall window and is
# stopped by the budget instead.
home2 = tmpdir("progress") / "home"
(home2 / dsb.LOG_REL).parent.mkdir(parents=True, exist_ok=True)
log_path = home2 / dsb.LOG_REL
log_path.write_text("")


class GrowingClock(FakeClock):
    """A child that keeps writing to the log. Deliberately NOT a download
    progress line: this case is about the stall watchdog, and a download
    counter would hand the throughput projection something to act on."""

    def sleep(self, seconds):
        super().sleep(seconds)
        with open(log_path, "a") as fh:
            fh.write(f"[{self.now}] Installing update...\n")


proc = FakeProc()
record = {}
calls = []
real_killpg = dsb.os.killpg
dsb.os.killpg = lambda pgid, sig: calls.append((pgid, sig))
clock = GrowingClock()
try:
    reason = dsb.run_bootstrap(
        ["true"], home2, record, budget_secs=200, stall_secs=30,
        spawner=lambda argv, out=None: proc, clock=clock, sleeper=clock.sleep, emit=lambda t: None,
    )
finally:
    dsb.os.killpg = real_killpg
check("progress resets the stall watchdog (non-vacuity)", reason, dsb.STOP_BUDGET)


# ===========================================================================
print("\n== 5. the whole-step budget ==")
# ===========================================================================

home3 = tmpdir("budget") / "home"
home3.mkdir(parents=True, exist_ok=True)
reason, record, calls, proc, clock = drive(home3, stall=100000, budget=60)
check("the budget stops a child that will not finish", reason, dsb.STOP_BUDGET)
check_true("it stops at the budget, not later", clock.now < 60 + dsb.POLL_SECS * 2)
check_true("the group was killed", calls)

# A child that exits on its own is not killed pointlessly, and its code is kept.
home4 = tmpdir("exits") / "home"
home4.mkdir(parents=True, exist_ok=True)
reason, record, calls, proc, clock = drive(home4, exits_after=1)
check("a child that exits is reported as such", reason, dsb.STOP_EXITED)
check("its exit code is recorded", record["exit_code"], 0)

# Success stop: once the manifest is on disk we do not wait for Valve.
home5 = tmpdir("marker") / "home"
(home5 / dsb.PACKAGE_DIR_REL).mkdir(parents=True, exist_ok=True)
(home5 / dsb.PACKAGE_DIR_REL / "steam_client_ubuntu12.installed").write_text("m")
reason, record, calls, proc, clock = drive(home5, stall=100000, budget=100000)
check("a present manifest ends the run", reason, dsb.STOP_MARKER)
check_true("without waiting for the budget", clock.now < 100000)
check_true("and the group is still stopped", calls)


print("\n-- 5b. the throughput projection --")

# 🔴 The throughput projection: a connection that cannot finish must cost two
# minutes of evidence, not the whole budget. This is the pre-warm's actual
# failure (a progress bar at 70% for twenty minutes) as a test.
check("no projection without a progress line", dsb.projected_download_secs("", 60), None)
check(
    "a download that has not started cannot be extrapolated",
    dsb.projected_download_secs("Downloading update (0 of 502,420 KB)", 60),
    None,
)
check(
    "a finished download projects nothing",
    dsb.projected_download_secs("Downloading update (502,420 of 502,420 KB)", 60),
    None,
)
# 50,242 of 502,420 KB in 120 s is 10% in two minutes -> 1080 s still to go.
check(
    "the projection uses the whole run, not a window",
    int(dsb.projected_download_secs("Downloading update (50,242 of 502,420 KB)", 120)),
    1080,
)

home6 = tmpdir("tooslow") / "home"
(home6 / dsb.LOG_REL).parent.mkdir(parents=True, exist_ok=True)
slow_log = home6 / dsb.LOG_REL
slow_log.write_text("")


class SlowClock(FakeClock):
    """A connection doing 1% of the download every poll -- always making
    progress, so the stall watchdog never fires, and far too slow to finish."""

    def sleep(self, seconds):
        super().sleep(seconds)
        done = int(self.now * 40)
        with open(slow_log, "a") as fh:
            fh.write(f"Downloading update ({done:,} of 502,420 KB)...\n")


proc = FakeProc()
record = {}
calls = []
real_killpg = dsb.os.killpg
dsb.os.killpg = lambda pgid, sig: calls.append((pgid, sig))
clock = SlowClock()
emitted: list[str] = []
try:
    reason = dsb.run_bootstrap(
        ["true"], home6, record, budget_secs=dsb.BUDGET_SECS, stall_secs=dsb.STALL_SECS,
        spawner=lambda argv, out=None: proc, clock=clock, sleeper=clock.sleep,
        emit=emitted.append,
    )
finally:
    dsb.os.killpg = real_killpg
check("a hopeless connection is stopped early", reason, dsb.STOP_TOO_SLOW)
check_true(
    "and it is stopped at the projection point, not at the budget",
    clock.now < dsb.THROUGHPUT_CHECK_SECS + 4 * dsb.POLL_SECS,
)
check_true("the projection is recorded", record["projected_download_secs"] > dsb.BUDGET_SECS)
check_true("and the installer says so", any("cannot finish" in line for line in emitted))
check_true("the group is still killed", calls)

# The projection must not fire on a connection that WILL finish -- otherwise
# the check above is just "stop after two minutes".
home7 = tmpdir("fastenough") / "home"
(home7 / dsb.LOG_REL).parent.mkdir(parents=True, exist_ok=True)
fast_log = home7 / dsb.LOG_REL
fast_log.write_text("")


class FastClock(FakeClock):
    def sleep(self, seconds):
        super().sleep(seconds)
        done = min(502420, int(self.now * 3000))
        with open(fast_log, "a") as fh:
            fh.write(f"Downloading update ({done:,} of 502,420 KB)...\n")


proc = FakeProc()
record = {}
real_killpg = dsb.os.killpg
dsb.os.killpg = lambda pgid, sig: None
clock = FastClock()
try:
    reason = dsb.run_bootstrap(
        ["true"], home7, record, budget_secs=dsb.BUDGET_SECS, stall_secs=dsb.STALL_SECS,
        spawner=lambda argv, out=None: proc, clock=clock, sleeper=clock.sleep,
        emit=lambda t: None,
    )
finally:
    dsb.os.killpg = real_killpg
check("a connection that will finish is not cut off (non-vacuity)", reason, dsb.STOP_BUDGET)
check_true("it ran well past the projection point", clock.now > dsb.THROUGHPUT_CHECK_SECS * 2)

target = make_target("tooslow-record")
runner = RecordingRunner(marker=None, reason=dsb.STOP_TOO_SLOW, cached=1)
record, _ = run_step(FakeCtx(target), runner)
check_in("too-slow: the record explains it in minutes", "more minutes", record["error"])


# ===========================================================================
print("\n== 6. stopping it cannot leave anything behind, or kill the installer ==")
# ===========================================================================

# 🔴 A target of "/" would match every process on the installing machine.
check("a target of / matches nothing", dsb.processes_rooted_in("/"), [])
check("a target of // matches nothing", dsb.processes_rooted_in("//"), [])

fake_proc_fs = tmpdir("procfs") / "proc"
for pid, root in ((1, "/"), (2, "/mnt"), (3, "/mnt/var/tmp"), (4, "/other"), (5, "/mnt-not-really")):
    d = fake_proc_fs / str(pid)
    d.mkdir(parents=True, exist_ok=True)
    os.symlink(root, d / "root")
(fake_proc_fs / "notapid").mkdir(exist_ok=True)

found = dsb.processes_rooted_in("/mnt", proc_root=fake_proc_fs)
check("processes inside the target are found", found, [2, 3])
check_true("pid 1 is never a victim", 1 not in found)
check_true("a prefix that is not a path component is not matched", 5 not in found)

# Our own pid is excluded even if it looks rooted in the target.
d = fake_proc_fs / str(os.getpid())
d.mkdir(parents=True, exist_ok=True)
if not (d / "root").exists():
    os.symlink("/mnt", d / "root")
check("our own pid is never a victim", os.getpid() in dsb.processes_rooted_in("/mnt", proc_root=fake_proc_fs), False)

# The sweep runs on every path, including the ones that failed.
target = make_target("sweep")
swept: list = []
real_sweep = dsb.sweep_target
dsb.sweep_target = lambda t: swept.append(str(t)) or [777]
try:
    runner = RecordingRunner(marker=None, exit_code=1, reason=dsb.STOP_STALLED)
    record, out = run_step(FakeCtx(target), runner)
finally:
    dsb.sweep_target = real_sweep
check("the target is swept even when the run failed", swept, [str(target)])
check("survivors are recorded", record["stragglers"], [777])
check_in("and reported loudly", "held the target's mounts open", out)


# ===========================================================================
print("\n== 7. the floor: nothing is ever made worse ==")
# ===========================================================================

# Killed with bytes cached but no manifest: the record must say the partial
# cache is a saving, not a loss. Measured: a run killed mid-download left
# 11 MiB, and the next run fetched 491,232 KB instead of 502,420 KB.
target = make_target("partial")
runner = RecordingRunner(marker=None, reason=dsb.STOP_BUDGET, cached=11 * 1024 * 1024)
record, out = run_step(FakeCtx(target), runner, budget=60)
check("partial: status", record["status"], dsb.STATUS_INCOMPLETE)
check("partial: the bytes that landed are recorded", record["package_bytes"], 11 * 1024 * 1024)
check_in("partial: the record says nothing was made worse", "Nothing was made worse", record["error"])
check_in("partial: it names the reason it stopped", "budget", record["error"])

target = make_target("stalled")
runner = RecordingRunner(marker=None, reason=dsb.STOP_STALLED, cached=1)
record, _ = run_step(FakeCtx(target), runner)
check_in("stalled: the record says so", "stopped making progress", record["error"])

# Disk: refusing is the point. A target with no room must not be filled.
target = make_target("nospace")
real_usage = dsb.shutil.disk_usage
dsb.shutil.disk_usage = lambda p: os.terminal_size((0, 0)) and _Usage()


class _Usage:
    total = 100
    used = 99
    free = 1


try:
    runner = RecordingRunner()
    record, _ = run_step(FakeCtx(target), runner)
finally:
    dsb.shutil.disk_usage = real_usage
check("no space: status", record["status"], dsb.STATUS_NO_SPACE)
check("no space: nothing was executed", runner.calls, [])
check_in("no space: the record says first boot is unchanged", "as it does today", record["error"])


# ===========================================================================
print("\n== 8. ownership is asserted, not assumed ==")
# ===========================================================================

owned_root = tmpdir("ownership") / "Steam"
(owned_root / "package").mkdir(parents=True, exist_ok=True)
(owned_root / "package" / "a").write_text("x")
(owned_root / "b").write_text("x")
found, seen, warning = dsb.root_owned_under(owned_root)
check("a tree written by us is not root-owned", found, [])
check("the walk saw the files", seen >= 3, True)
check("no warning on a clean tree", warning, None)
check("a missing tree does not raise", dsb.root_owned_under(owned_root / "nope")[0], [])

# The bound exists so the check cannot become a hang of its own.
real_cap = dsb.MAX_OWNERSHIP_ENTRIES
dsb.MAX_OWNERSHIP_ENTRIES = 2
try:
    _, _, warning = dsb.root_owned_under(owned_root)
finally:
    dsb.MAX_OWNERSHIP_ENTRIES = real_cap
check_true("the ownership walk is bounded", warning and "stopped the ownership check" in warning)


# ===========================================================================
print("\n== 9. wiring, constants and the registry ==")
# ===========================================================================

# 🔴 The duplicated constant cannot drift silently -- the module says so in a
# comment and this is the check that comment promises.
check(
    "the bootstrap tarball path matches deck_pkgs'",
    dsb.STEAM_BOOTSTRAP_REL,
    deck_pkgs.STEAM_BOOTSTRAP_REL,
)
check("the launcher path is absolute inside the target", dsb.STEAM_LAUNCHER_ABS, "/usr/bin/steam")
check("the marker glob is the installed manifest", dsb.INSTALLED_MARKER_GLOB, "steam_client_*.installed")
check_true("the stall window is far shorter than the budget", dsb.STALL_SECS * 2 < dsb.BUDGET_SECS)
check_true("the budget is shorter than the pre-warm's 20 minutes", dsb.BUDGET_SECS < 20 * 60)

# Valve's own progress line, parsed for the installer's progress report.
sample = (
    "[2026-08-16 13:10:11] Downloading update (29,328 of 502,420 KB)...\n"
    "[2026-08-16 13:10:16] Downloading update (72,551 of 502,420 KB)...\n"
)
line = dsb.progress_line(sample)
check_in("progress uses Valve's own numbers", "72,551 of 502,420 KB", line)
check_in("progress reports a percentage", "14%", line)
check("progress on an empty log is None", dsb.progress_line(""), None)
check_in(
    "the extract phase is reported",
    "Extracting package...",
    dsb.progress_line(sample + "[..] Extracting package...\n"),
)

# The log is read from both places Valve puts it.
h = tmpdir("logs") / "home"
(h / dsb.FALLBACK_LOG_REL).parent.mkdir(parents=True, exist_ok=True)
(h / dsb.FALLBACK_LOG_REL).write_text("fallback")
check("the fallback log path is read", dsb.read_log_tail(h), "fallback")
(h / dsb.LOG_REL).parent.mkdir(parents=True, exist_ok=True)
(h / dsb.LOG_REL).write_text("canonical")
check("the canonical log path wins", dsb.read_log_tail(h), "canonical")
check("a home with no log reads empty", dsb.read_log_tail(tmpdir("nolog")), "")

# 🔴 The watchdog's signal is the FILE's size, not the capped tail's length --
# otherwise it goes blind once the log passes the cap, which on a real download
# happens in seconds.
big = tmpdir("biglog") / "home"
(big / dsb.LOG_REL).parent.mkdir(parents=True, exist_ok=True)
(big / dsb.LOG_REL).write_text("x" * (256 * 1024))
check("the log signature is the whole file", dsb.log_size(big), 256 * 1024)
check_true(
    "and it is bigger than the tail the module reads (non-vacuity)",
    dsb.log_size(big) > len(dsb.read_log_tail(big)),
)
(big / dsb.LOG_REL).write_text("x" * (512 * 1024))
check("it moves when the log grows past the cap", dsb.log_size(big), 512 * 1024)
check("a home with no log has size 0", dsb.log_size(tmpdir("nolog2")), 0)

# ⚠️ MERGE GATE -- see this file's docstring. Red until the coordinator adds
# the DeckStep line to deck_configure.py.
names = [s.name for s in deck_configure.deck_steps()]
CHECKS += 1
if "steam_bootstrap" in names:
    print("ok   the step is registered in deck_configure.deck_steps")
    order = {name: i for i, name in enumerate(names)}
    check("it runs after pkgs", order["steam_bootstrap"] > order["pkgs"], True)
    # 🔴 Measured: the bootstrap WRITES ~/.steam/registry.vdf. It merges rather
    # than clobbers, but running first makes steam_seed the last writer, which
    # is what repairs a registry torn by a killed bootstrap.
    check("it runs before steam_seed", order["steam_bootstrap"] < order["steam_seed"], True)
    step = next(s for s in deck_configure.deck_steps() if s.name == "steam_bootstrap")
    check("it is not critical", step.critical, False)
    check("it is wired to this module's entry point", step.fn, dsb.steam_bootstrap_step)
else:
    FAILURES += 1
    print(
        "FAIL the step is not registered in deck_configure.deck_steps -- "
        "MERGE GATE: add\n"
        '     DeckStep("steam_bootstrap", deck_steam_bootstrap.steam_bootstrap_step, '
        "critical=False)\n"
        "     between the 'pkgs' and 'steam_seed' entries. This check is red on "
        "purpose until then."
    )


# ===========================================================================
print("\n== 10. the failure has to arrive explained (the 2026-08-16 defect) ==")
# ===========================================================================

# 🔴 VERBATIM from the failing install's `/var/log/omarchy-deck-install.json`:
#
#     "exit_code": 71
#     "output": "bin_steam.sh[1]: Setting up Steam content in /home/deck/..."
#
# One line, and it was the line printed BEFORE the failure. `steam.sh` opens
# srt-logger over its own stderr before it runs any check, so from that point
# everything it says lands in console-linux.txt -- including the one sentence
# that named the cause. This suite now requires that sentence to reach both the
# record and the console.
REAL_LAUNCHER_LOG = (
    "[2026-08-16 15:02:01] steam.sh[1]: Running Steam on arch rolling 64-bit\n"
    "[2026-08-16 15:02:01] steam.sh[1]: STEAM_RUNTIME is enabled automatically\n"
    "[2026-08-16 15:02:02] setup.sh[9]: Updating Steam runtime environment...\n"
    "[2026-08-16 15:02:03] steam.sh[1]: Error: Steam now requires user namespaces "
    "to be enabled.\n"
)

target = make_target("launcher-log")
runner = RecordingRunner(marker=None, exit_code=71, launcher_log=REAL_LAUNCHER_LOG)
record, out = run_step(FakeCtx(target), runner)
check("exit 71 with no manifest: status", record["status"], dsb.STATUS_INCOMPLETE)
check("exit 71: the exit code is kept", record["exit_code"], 71)
check_true("the launcher's own log reaches the record", record["launcher_log"])
check_in(
    "and the record names the reason Valve gave",
    "user namespaces",
    " | ".join(record["launcher_errors"]),
)
check_true(
    "and it is PRINTED, not just filed",
    "Valve's launcher said:" in out and "user namespaces" in out,
)
# ⚠️ The degradation promise must survive the new detail: it is the sentence
# that tells a support reader nothing was broken.
check_in("the error still promises the floor", "Nothing was made worse", record["error"])
check_in("...and still says first boot finishes", "first boot", record["error"].lower())

# A run that worked still records the log, because "it worked" and "it did not"
# are read out of the same field and an empty one would be ambiguous.
target = make_target("launcher-log-ok")
runner = RecordingRunner(
    marker="steam_client_steamdeck_stable_ubuntu12.installed",
    cached=4096,
    launcher_log="[..] steam.sh[1]: Steam client's requirements are satisfied\n",
)
record, out = run_step(FakeCtx(target), runner)
check("installed: status", record["status"], dsb.STATUS_INSTALLED)
# The record has to stay readable: the entry script is 2 KB of shell.
check_in("the recorded command elides the script body", "<ENTER_SCRIPT>", record["command"])
check("...and is one line", "\n" in record["command"], False)
check_in("...while still naming the target and the user", "--reuid=1000", record["command"])
check_true("installed: the launcher log is recorded too", record["launcher_log"])
check_true(
    "installed: nothing is reported as a warning",
    "Valve's launcher said:" not in out,
)

# The pure readers, driven directly.
lh = tmpdir("launcher-logs") / "home"
(lh / dsb.FALLBACK_LAUNCHER_LOG_REL).parent.mkdir(parents=True, exist_ok=True)
(lh / dsb.FALLBACK_LAUNCHER_LOG_REL).write_text("fallback")
check("the fallback launcher log path is read", dsb.read_launcher_log_tail(lh), "fallback")
(lh / dsb.LAUNCHER_LOG_REL).parent.mkdir(parents=True, exist_ok=True)
(lh / dsb.LAUNCHER_LOG_REL).write_text("canonical")
check("the canonical launcher log wins", dsb.read_launcher_log_tail(lh), "canonical")
check("a home with no launcher log reads empty", dsb.read_launcher_log_tail(tmpdir("nolog3")), "")
check("...and sizes 0", dsb.launcher_log_size(tmpdir("nolog3")), 0)
check("the launcher log size is the whole file", dsb.launcher_log_size(lh), len("canonical"))

# 🔴 The filter keeps the sentence that matters and drops 4 000 lines of
# progress, which is the difference between a record you can act on and one you
# have to be at the machine to use.
picked = dsb.notable_lines(
    "Downloading update (1 of 2 KB)...\n" * 50
    + "Error: Steam now requires user namespaces to be enabled.\n"
)
check("the filter drops progress noise", len(picked), 1)
check_in("the filter keeps the error", "user namespaces", picked[0])
check("the filter is bounded", len(dsb.notable_lines("Error: x\n" * 100)), dsb.MAX_NOTABLE_LINES)
check("an empty log yields nothing", dsb.notable_lines(""), [])

# 🔴 The stall watchdog has to be able to see a run that is working but has not
# reached the updater yet: `steam.sh` writes console-linux.txt for seconds
# before `package/` or bootstrap_log.txt exist at all.
sig_home = tmpdir("sig") / "home"
(sig_home / dsb.LAUNCHER_LOG_REL).parent.mkdir(parents=True, exist_ok=True)
(sig_home / dsb.LAUNCHER_LOG_REL).write_text("x" * 4096)
check("progress is visible before the updater starts", dsb.launcher_log_size(sig_home), 4096)
check("...while the updater's own log is still absent", dsb.log_size(sig_home), 0)


# ===========================================================================
print(f"\n{CHECKS - FAILURES}/{CHECKS} checks passed")
shutil.rmtree(WORK, ignore_errors=True)
sys.exit(1 if FAILURES else 0)
