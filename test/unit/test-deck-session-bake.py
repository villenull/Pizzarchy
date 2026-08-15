#!/usr/bin/env python3
"""Unit tests for `configure_deck`'s `session_bake` step (`deck_session_bake.py`)
— the install-time bake of `src/deck-session.sh`'s stages onto the target.

No VM, no root, no network, no chroot, no ISO build. Run directly:

    python3 test-deck-session-bake.py

WHAT THIS SUITE IS FOR, AND WHAT IT DELIBERATELY IS NOT
=======================================================

The stages themselves are covered by `test/unit/test-deck-session-stages.sh`
(526 assertions) and their chroot-mode branches by
`test/unit/test-deck-session-bake.sh`. Nothing here re-tests a stage. This suite
is about the *seam*, which is where this class of defect actually lives — the
whole reason the step exists is that a fully tested component was wired into
nothing:

1. 🔴 **Where it runs.** The stages ask the machine questions (is
   `gamescope-wayland.desktop` installed, is there an `sddm.service`, does
   `python3` import `evdev`) and write to absolute paths. Run on the live side
   they would inspect and configure the ISO. `chroot_command` exists so that
   decision is assertable without a chroot.

2. 🔴 **That the stage list is ASKED FOR, not written down here.** A copy of it
   in Python is a second source of truth for what an install bakes, and it is
   the copy that goes stale. The suite proves the module runs `list-bake-stages`
   and refuses to invent a list when that fails — and, separately, that the list
   `src/deck-session.sh` actually answers with is internally coherent.

3. 🔴 **That a deferred check reaches the record.** `deck-session.sh` prints one
   `DEFERRED (chroot):` line per check it could not run. Those lines are printed
   in the MIDDLE of a stage and the output summary keeps only the tail, so if
   they were not extracted separately they would be lost — and a deferral nobody
   can read is indistinguishable from a check that silently did not happen.

4. 🔴 **That nothing is swallowed.** Every branch — absent payload, deferred
   provisioning, an unresolvable user, a failing stage, a failing precondition —
   must produce a record with a status, print through the orchestrator's
   `error`, and leave the install standing (`critical=False`).

The `DEFERRED (chroot):` marker and the `list-bake-stages` verb are DERIVED from
`src/deck-session.sh` rather than restated, so the two files cannot drift apart
quietly. That is the same move `test-deck-configure-patches.py` makes with the
applier's exit codes.
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import pathlib
import shutil
import stat
import subprocess
import sys
import tempfile

# ⚠️ Before importing anything under test. Python validates a cached .pyc
# against (mtime, size) at one-second granularity, so a same-size edit inside
# the same second silently runs the PREVIOUS version — which is exactly what
# mutation testing produces.
sys.dont_write_bytecode = True

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]

OVERLAY_ORCH = (
    REPO_ROOT
    / "iso/overlay/configs/airootfs/usr/share/omarchy-iso/orchestrator"
)
UPSTREAM_ORCH = (
    REPO_ROOT
    / "iso/upstream/configs/airootfs/usr/share/omarchy-iso/orchestrator"
)
DECK_SESSION_SH = REPO_ROOT / "src" / "deck-session.sh"

FAILURES = 0
CHECKS = 0
NOTES: list[str] = []


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


def note(what: str) -> None:
    NOTES.append(what)
    print(f"note {what}")


# ---------------------------------------------------------------------------
# Harness: rebuild the orchestrator package shape around the modules
# ---------------------------------------------------------------------------

WORK = pathlib.Path(tempfile.mkdtemp(prefix="deck-session-bake-test-"))

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
    for module in sorted(OVERLAY_ORCH.glob("deck_*.py")):
        shutil.copyfile(module, pkg / module.name)
    (pkg / "phases_impl.py").write_text(PHASES_IMPL_STUB)
    return root


PKG_ROOT = build_package()
sys.path.insert(0, str(PKG_ROOT))

from orchestrator import deck_configure, deck_session_bake  # noqa: E402

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


def make_target(name: str, *, user="deck", uid=1000, home="/home/deck") -> pathlib.Path:
    """A target with just enough of an account database to resolve a user.

    /etc/passwd and the home directory, because `deck_user.resolve_target_user`
    confirms the installer's claim against the target's own file rather than
    trusting it — the trap `docs/tasks/T5-fork-plan.md` §3 (a) is about.
    """
    target = tmpdir(name) / "mnt"
    (target / "etc").mkdir(parents=True, exist_ok=True)
    (target / "etc/passwd").write_text(
        "root:x:0:0::/root:/bin/bash\n"
        f"{user}:x:{uid}:{uid}::{home}:/bin/bash\n"
    )
    (target / home.lstrip("/")).mkdir(parents=True, exist_ok=True)
    return target


def make_assets(name: str, *, script=True, extra=("deck-input-mapper.py",)) -> pathlib.Path:
    """A stand-in for the ISO's /usr/share/omarchy-iso/deck/session directory."""
    d = tmpdir(name) / "session"
    d.mkdir(parents=True, exist_ok=True)
    if script:
        (d / deck_session_bake.SCRIPT_NAME).write_text("#!/usr/bin/env bash\nexit 0\n")
    for name_ in extra:
        (d / name_).write_text("# payload\n")
    return d


class Runner:
    """A stand-in for the arch-chroot invocation.

    Records every argv it was handed and the environment flags it was told
    about, so "which stages ran, in which order, with what" is assertable
    without a chroot.
    """

    def __init__(self, stages=("stage-preconditions", "stage-steam-hook"), outputs=None, codes=None):
        self.stage_list = list(stages)
        self.outputs = outputs or {}
        self.codes = codes or {}
        self.calls: list[list[str]] = []
        self.users: list[str] = []

    def __call__(self, target, argv, user, timeout=None):
        self.calls.append(list(argv))
        self.users.append(user)
        verb = argv[-1]
        if verb == deck_session_bake.LIST_VERB:
            return 0, "\n".join(self.stage_list) + "\n"
        return self.codes.get(verb, 0), self.outputs.get(verb, f"[deck-session] {verb}: ok\n")


def run_step(ctx, runner, asset_dir):
    """bake_session with the console captured, so 'loud' can be asserted."""
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        record = deck_session_bake.bake_session(ctx, runner=runner, asset_dir=str(asset_dir))
    return record, buf.getvalue()


# ---------------------------------------------------------------------------
# 1. The contract with src/deck-session.sh, derived from the script itself
# ---------------------------------------------------------------------------

print("\n# 1. the contract with src/deck-session.sh")

SCRIPT_TEXT = DECK_SESSION_SH.read_text()

# The marker the module greps for is the one defer() prints. Read out of the
# FUNCTION, not out of the file: a mention in a comment would keep a naive
# check green with the prefix changed, which would silently empty every
# record's "deferred" list.
defer_body = subprocess.run(
    ["bash", "-c", f'source "{DECK_SESSION_SH}"; declare -f defer'],
    capture_output=True,
    text=True,
    check=False,
).stdout
check_true(
    "deck-session.sh's defer() prints the exact marker deck_session_bake.py greps for",
    deck_session_bake.DEFER_MARKER in defer_body,
)
check_true(
    "deck-session.sh answers the verb the module asks it for",
    f"{deck_session_bake.LIST_VERB})" in SCRIPT_TEXT,
)
check_true(
    "deck-session.sh reads the two environment flags the module sets",
    deck_session_bake.CHROOT_ENV_FLAG in SCRIPT_TEXT
    and deck_session_bake.USER_ENV_FLAG in SCRIPT_TEXT,
)

# The stage list, as the script itself answers it. Executed, not parsed: the
# verb is the interface and running it is the only thing that proves it works.
listed = subprocess.run(
    ["bash", str(DECK_SESSION_SH), deck_session_bake.LIST_VERB],
    capture_output=True,
    text=True,
    check=False,
)
bake_stages = [line.strip() for line in listed.stdout.splitlines() if line.strip()]
check("`deck-session.sh list-bake-stages` exits 0", listed.returncode, 0)
check_true("it names stages", len(bake_stages) >= 10)
check("stage-preconditions runs first", bake_stages[0], "stage-preconditions")

# 🔴 The two deliberate differences from INSTALL_STAGES, asserted because both
# are decisions rather than accidents (see BAKE_STAGES in deck-session.sh).
check(
    "stage-desktop-settings is NOT baked -- three registry steps already own its "
    "dconf, idle and sleep-lock halves, and its site file carries no marker of ours",
    "stage-desktop-settings" in bake_stages,
    False,
)
check_true(
    "stage-osk-kb-layout IS baked -- the half of that stage nothing else writes",
    "stage-osk-kb-layout" in bake_stages,
)

# Every baked name has to be a stage the script can actually dispatch. A typo
# here is a stage that fails on every install with 'unknown stage'.
dispatchable = subprocess.run(
    ["bash", "-c", f'source "{DECK_SESSION_SH}"; declare -F | sed "s/^declare -f //"'],
    capture_output=True,
    text=True,
    check=False,
)
functions = set(dispatchable.stdout.split())
missing = [s for s in bake_stages if s.replace("-", "_") not in functions]
check("every baked stage name resolves to a function in deck-session.sh", missing, [])

# The others are still reachable by hand; the bake list is a subset decision,
# not a rewrite of what the script offers.
all_stages = subprocess.run(
    ["bash", str(DECK_SESSION_SH), "list-stages"],
    capture_output=True,
    text=True,
    check=False,
)
listed_all = {line.strip() for line in all_stages.stdout.splitlines() if line.strip()}
check_true("stage-desktop-settings is still offered by list-stages", "stage-desktop-settings" in listed_all)
check_true("stage-osk-kb-layout is offered by list-stages", "stage-osk-kb-layout" in listed_all)

# ---------------------------------------------------------------------------
# 2. Where it runs
# ---------------------------------------------------------------------------

print("\n# 2. where it runs")

cmd = deck_session_bake.chroot_command("/mnt", ["/x/deck-session.sh", "stage-steam-hook"])
check(
    "the stages run INSIDE the target via arch-chroot",
    cmd,
    ["arch-chroot", "/mnt", "/x/deck-session.sh", "stage-steam-hook"],
)
check_true(
    "the script's in-chroot path is absolute and target-relative",
    deck_session_bake.script_path_in_target().startswith("/")
    and deck_session_bake.STAGE_DIR_REL in deck_session_bake.script_path_in_target(),
)

env = deck_session_bake.chroot_env("deck")
check("chroot mode is selected by the flag deck-session.sh reads", env[deck_session_bake.CHROOT_ENV_FLAG], "1")
check("the desktop user is passed in -- there is no SUDO_USER in a chroot", env[deck_session_bake.USER_ENV_FLAG], "deck")
check_true("the environment is inherited, not replaced (arch-chroot needs PATH)", "PATH" in env)

# ---------------------------------------------------------------------------
# 3. Staging the payload
# ---------------------------------------------------------------------------

print("\n# 3. staging the payload")

target = make_target("stage-ok")
assets = make_assets("stage-ok", extra=("deck-input-mapper.py", "deck_osk_layout.py"))
staged, names = deck_session_bake.stage_payload(target, assets)
check("every file in the ISO's payload directory is staged", sorted(names),
      ["deck-input-mapper.py", "deck-session.sh", "deck_osk_layout.py"])
check_true("the staging directory is inside the target", str(staged).startswith(str(target)))
check(
    "the script is made executable AFTER the copy -- archiso discards modes, so "
    "an inherited one would be 0644 and 'permission denied' inside arch-chroot",
    f"{stat.S_IMODE(os.lstat(staged / 'deck-session.sh').st_mode):04o}",
    "0755",
)
check(
    "its payload files are 0644 -- they are installed by the stages, not run here",
    f"{stat.S_IMODE(os.lstat(staged / 'deck_osk_layout.py').st_mode):04o}",
    "0644",
)

# A re-run must not inherit a file an earlier one left behind: the stages read
# whatever is beside the script, so a stale module is a silently wrong install.
(staged / "left-over.py").write_text("stale\n")
staged, names = deck_session_bake.stage_payload(target, assets)
check("a re-stage clears the directory first", (staged / "left-over.py").exists(), False)

raised = ""
try:
    deck_session_bake.stage_payload(make_target("no-assets"), tmpdir("nowhere") / "absent")
except deck_session_bake.DeckSessionBakeError as exc:
    raised = str(exc)
check_true("an ISO with no session payload is refused, loudly", "no session layer to bake" in raised)

raised = ""
try:
    deck_session_bake.stage_payload(make_target("no-script"), make_assets("no-script", script=False))
except deck_session_bake.DeckSessionBakeError as exc:
    raised = str(exc)
check_true("a payload without the script itself is refused, naming it", "deck-session.sh" in raised)

# ---------------------------------------------------------------------------
# 4. The happy path
# ---------------------------------------------------------------------------

print("\n# 4. the happy path")

target = make_target("happy")
assets = make_assets("happy")
runner = Runner(stages=["stage-preconditions", "stage-steam-hook", "stage-menu-row"])
record, out = run_step(FakeCtx(target), runner, assets)

check("status is 'baked' when every stage exits 0", record["status"], "baked")
check("every stage is recorded", sorted(record["stages"]), ["stage-menu-row", "stage-preconditions", "stage-steam-hook"])
check("the ok list names them all", len(record["ok"]), 3)
check("no error is recorded", record["error"], None)
check("the resolved user is recorded", record["user"], "deck")
check_true("the payload is recorded", "deck-session.sh" in record["payload"])

# The list is ASKED FOR. Without this, a module that hardcoded the stages would
# pass every other assertion in this file.
check("the first call asks the script for its stage list", runner.calls[0][-1], deck_session_bake.LIST_VERB)
check(
    "then one call per stage, in the order the script named them",
    [c[-1] for c in runner.calls[1:]],
    ["stage-preconditions", "stage-steam-hook", "stage-menu-row"],
)
check("every call runs the staged script", {c[0] for c in runner.calls}, {deck_session_bake.script_path_in_target()})
check("every call is told who the desktop user is", set(runner.users), {"deck"})

# The scaffolding is not part of the installed system.
check(
    "the staging directory is removed when the step finishes",
    (target / deck_session_bake.STAGE_DIR_REL).exists(),
    False,
)

# ---------------------------------------------------------------------------
# 5. Deferrals reach the record
# ---------------------------------------------------------------------------

print("\n# 5. deferrals reach the record")

deferred_output = (
    "[deck-session] installing the lizard-mode helper\n"
    "[deck-session] DEFERRED (chroot): lizard mode is NOT toggled at install time\n"
    "[deck-session] verified: the helper refuses an unknown verb\n"
    "[deck-session] stage-lizard-mode: ok\n"
)
target = make_target("deferrals")
assets = make_assets("deferrals")
runner = Runner(stages=["stage-lizard-mode"], outputs={"stage-lizard-mode": deferred_output})
record, out = run_step(FakeCtx(target), runner, assets)

check("a deferred check is extracted from the stage's output", record["stages"]["stage-lizard-mode"]["deferred"],
      ["lizard mode is NOT toggled at install time"])
check("and lifted to the record's top level, tagged with its stage", record["deferred"],
      ["stage-lizard-mode: lizard mode is NOT toggled at install time"])
check("a stage that defers still counts as ok", record["status"], "baked")

# 🔴 The reason deferrals are extracted rather than left in the output tail:
# they are printed in the MIDDLE of a stage, and the tail keeps the end.
long_output = deferred_output + "".join(f"[deck-session] line {i}\n" for i in range(60))
runner = Runner(stages=["stage-lizard-mode"], outputs={"stage-lizard-mode": long_output})
record, out = run_step(FakeCtx(make_target("deferrals-long")), runner, assets)
check_true(
    "a deferral is kept even when the output tail has scrolled past it",
    record["deferred"] == ["stage-lizard-mode: lizard mode is NOT toggled at install time"]
    and "DEFERRED" not in (record["stages"]["stage-lizard-mode"]["output"] or ""),
)

# ---------------------------------------------------------------------------
# 6. Failures: recorded, loud, and not fatal
# ---------------------------------------------------------------------------

print("\n# 6. failures are recorded, loud and not fatal")

target = make_target("one-failed")
assets = make_assets("one-failed")
runner = Runner(
    stages=["stage-preconditions", "stage-input-mapper", "stage-menu-row"],
    codes={"stage-input-mapper": 1},
    outputs={"stage-input-mapper": "[deck-session] ERROR: python-evdev is not importable.\n"},
)
record, out = run_step(FakeCtx(target), runner, assets)

check("one failing stage makes the step 'partial', not 'failed'", record["status"], "partial")
check("the failing stage is named", record["failed"], ["stage-input-mapper"])
check("the others still ran and are recorded ok", record["ok"], ["stage-preconditions", "stage-menu-row"])
check_true("the failure reaches the console", "python-evdev is not importable" in out)
check_true("the record says what a user has lost", "Desktop Mode" in (record["error"] or ""))
check("its exit code is kept", record["stages"]["stage-input-mapper"]["exit_code"], 1)

# 🔴 A failing stage must NOT stop the others. This is the whole argument for
# one arch-chroot per stage rather than one for the script.
check_true(
    "a stage after the failing one still ran",
    ["stage-menu-row"] == [c[-1] for c in runner.calls if c[-1] == "stage-menu-row"],
)

# The precondition case, which is the one exception -- and it is an explicit
# recorded outcome, never a quiet skip.
target = make_target("preconditions")
runner = Runner(
    stages=["stage-preconditions", "stage-steam-hook", "stage-menu-row"],
    codes={"stage-preconditions": 1},
    outputs={"stage-preconditions": "[deck-session] ERROR: no gamescope-wayland.desktop\n"},
)
record, out = run_step(FakeCtx(target), runner, assets)
check("a failed stage-preconditions makes the step 'failed'", record["status"], "failed")
check("the rest are recorded as skipped, not silently absent", record["skipped"], ["stage-steam-hook", "stage-menu-row"])
check_true(
    "each skipped stage carries the reason it was skipped",
    "stage-preconditions failed" in record["stages"]["stage-menu-row"]["reason"],
)
check(
    "and they were genuinely not run -- twelve copies of one message is not a report",
    [c[-1] for c in runner.calls],
    [deck_session_bake.LIST_VERB, "stage-preconditions"],
)

# A stage list that cannot be obtained is a failure, not a fallback.
class DeadRunner(Runner):
    def __call__(self, target, argv, user, timeout=None):
        self.calls.append(list(argv))
        return 127, "arch-chroot: command not found\n"


runner = DeadRunner()
record, out = run_step(FakeCtx(make_target("no-list")), runner, assets)
check("no stage list means the step failed", record["status"], "failed")
check("nothing was run", len(runner.calls), 1)
check_true("the record says why", "named no stages" in (record["error"] or ""))
check_true("and it is loud", "named no stages" in out)

# ---------------------------------------------------------------------------
# 7. The user, and the two ways there is not one
# ---------------------------------------------------------------------------

print("\n# 7. the user")

record, out = run_step(FakeCtx(make_target("deferred-prov"), defer_provisioning=True), Runner(), assets)
check("a defer_provisioning install records 'deferred'", record["status"], "deferred")
check_true("it says the Deck has no way to the desktop", "no way to the desktop" in (record["error"] or ""))
check_true("and it is loud", "session-switching layer was NOT baked" in out)

record, out = run_step(FakeCtx(make_target("no-user"), username="ghost"), Runner(), assets)
check("an account the target does not have is a failure", record["status"], "failed")
check_true("naming it", "ghost" in (record["error"] or ""))

# ---------------------------------------------------------------------------
# 8. The record is a JSON document the install log can hold
# ---------------------------------------------------------------------------

print("\n# 8. the record round-trips through the install log")

target = make_target("record")
runner = Runner(stages=["stage-preconditions"], outputs={"stage-preconditions": deferred_output})
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    deck_configure.record_result(
        target, "session_bake", deck_session_bake.bake_session(FakeCtx(target), runner=runner, asset_dir=str(assets))
    )
doc = json.loads((target / deck_configure.DECK_INSTALL_LOG_REL).read_text())
check_true("it lands under its own key", "session_bake" in doc)
check("with a status", doc["session_bake"]["status"], "baked")
check_true("and the deferrals", doc["session_bake"]["deferred"])
check(
    "the install log stays world-readable, as the support artefact it is",
    f"{stat.S_IMODE(os.lstat(target / deck_configure.DECK_INSTALL_LOG_REL).st_mode):04o}",
    "0644",
)

# ---------------------------------------------------------------------------
# 9. The registry entry
# ---------------------------------------------------------------------------

print("\n# 9. the registry")

names = [s.name for s in deck_configure.deck_steps()]
if "session_bake" in names:
    step = [s for s in deck_configure.deck_steps() if s.name == "session_bake"][0]
    check("the registry points at this module's entry point", step.fn, deck_session_bake.session_bake_step)
    check(
        "critical=False -- a Deck with no desktop switch still boots, logs in and plays; "
        "aborting would discard a finished install over a missing luac",
        step.critical,
        False,
    )
    check(
        "autologin is still the only critical step in the registry",
        [s.name for s in deck_configure.deck_steps() if s.critical],
        ["autologin"],
    )
else:
    # ⚠️ DELIBERATE, AND NOT A SKIP THAT CAN HIDE ANYTHING. deck_configure.py is
    # owned by whoever merges this slice, so at the moment this suite was
    # written the entry is not in it yet. What CANNOT happen quietly is a wrong
    # entry: the moment one exists, the three assertions above run.
    note(
        "session_bake is not registered in deck_configure.deck_steps() yet -- the entry "
        "line belongs to deck_configure.py, which this slice does not own. Wiring it "
        "turns the three assertions in §9 on."
    )
check_true("the step entry point exists and is callable", callable(deck_session_bake.session_bake_step))

# ---------------------------------------------------------------------------

shutil.rmtree(WORK, ignore_errors=True)

print(f"\n{CHECKS} checks, {FAILURES} failed, {len(NOTES)} note(s)")
sys.exit(1 if FAILURES else 0)
