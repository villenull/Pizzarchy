#!/usr/bin/env python3
"""Unit tests for `configure_deck`'s `patches` step — T12's install-time call to
`omarchy-deck-apply-patches` (`deck_patches.py`).

No VM, no root, no network, no chroot, no ISO build. Run directly:

    python3 test-deck-configure-patches.py

WHAT THIS SUITE IS ACTUALLY FOR
===============================

The applier itself is already covered by `test/unit/test-t12-patch-applier.sh`
(38 assertions, mutation-tested). Nothing here re-tests `git apply`, drift
detection or post-conditions. This suite is about the *seam*: three things that
a "does it call the binary?" test passes while the product is broken.

1. 🔴 **The applier is not on the target today.** The `omarchy-deck` package is
   a skeleton with no payload, so `status="absent"` is currently the ONLY
   outcome a real install can produce. If that branch were a quiet `return`, the
   entire T12 seam could be missing from every shipped ISO and nothing —
   not the install log, not the console — would say so. So "absent" is asserted
   as a recorded, loud, non-fatal outcome, three separate facts.

2. 🔴 **Where it runs.** The applier's `pacman -Q` and its absolute
   `/usr/lib/qt6/bin/qmllint` search are not relocatable by any flag it has, so
   running it on the live side against `--root <target>/usr/share/omarchy`
   would record the wrong Omarchy version and fail every clean install on a
   qmllint it cannot find. `chroot_command` exists so that decision is
   assertable without a chroot.

3. 🔴 **A zero exit is not success.** The exit code and `patch-state.json` are
   two channels, and believing the cheaper one when they disagree is how a
   silent success ships. The contradiction case has its own tests.

Several assertions are DERIVED from `src/omarchy-deck-patches/omarchy-deck-apply-patches`
rather than hard-coded — its exit codes and its default paths are read out of
the script — so this suite goes red if the applier's contract moves under it,
which is the only cheap signal for that class of drift.
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

# ⚠️ Before importing anything under test. Python validates a cached .pyc
# against (mtime, size) at one-second granularity, so a same-size edit inside
# the same second silently runs the PREVIOUS version — which is exactly what
# mutation testing produces.
sys.dont_write_bytecode = True

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]

OVERLAY_ORCH = (
    REPO_ROOT
    / "iso"
    / "overlay"
    / "configs"
    / "airootfs"
    / "usr"
    / "share"
    / "omarchy-iso"
    / "orchestrator"
)
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
# The payload the omarchy-deck package is supposed to ship. Read, never copied:
# this suite asserts that deck_patches.py and the applier agree about paths and
# exit codes, which only means anything if it reads the real file.
APPLIER_SRC = REPO_ROOT / "src" / "omarchy-deck-patches" / "omarchy-deck-apply-patches"

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


# ---------------------------------------------------------------------------
# Harness: rebuild the orchestrator package shape around the modules
# ---------------------------------------------------------------------------

WORK = pathlib.Path(tempfile.mkdtemp(prefix="deck-patches-test-"))

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
    for name in ("deck_configure.py", "deck_wifi.py", "deck_patches.py"):
        shutil.copyfile(OVERLAY_ORCH / name, pkg / name)
    (pkg / "phases_impl.py").write_text(PHASES_IMPL_STUB)
    return root


PKG_ROOT = build_package()
sys.path.insert(0, str(PKG_ROOT))

from orchestrator import deck_configure, deck_patches  # noqa: E402

print(f"# modules loaded from {PKG_ROOT}")


class FakeCtx:
    def __init__(self, target):
        self.target = pathlib.Path(target)


def tmpdir(name: str) -> pathlib.Path:
    d = WORK / name
    d.mkdir(parents=True, exist_ok=True)
    return d


def mode_of(path: pathlib.Path) -> str:
    return f"{stat.S_IMODE(os.lstat(path).st_mode):04o}"


# A target with the omarchy-deck payload installed, to whatever degree.
def make_target(
    name: str,
    *,
    applier: bool = True,
    applier_mode: int = 0o755,
    patch_dir: bool = True,
    state: str | None = None,
) -> pathlib.Path:
    target = tmpdir(name) / "mnt"
    (target / "usr/bin").mkdir(parents=True, exist_ok=True)
    if applier:
        binary = target / deck_patches.APPLIER_REL
        binary.write_text("#!/bin/sh\nexit 0\n")
        os.chmod(binary, applier_mode)
    if patch_dir:
        (target / deck_patches.PATCH_DIR_REL).mkdir(parents=True, exist_ok=True)
    if state is not None:
        state_path = target / deck_patches.STATE_FILE_REL
        state_path.parent.mkdir(parents=True, exist_ok=True)
        state_path.write_text(state)
    return target


def state_doc(overall: str, patches: list[dict] | None = None) -> str:
    if patches is None:
        patches = [
            {
                "patch": "0010-lock-blank-timer-20s.patch",
                "status": "ok",
                "action": "applied",
                "target": "shell/plugins/lock/Service.qml",
                "detail": "applied; post-conditions hold",
            }
        ]
    return json.dumps({"schema": 1, "overall": overall, "patches": patches})


class Runner:
    """A stand-in for the arch-chroot call. Records that it was called."""

    def __init__(self, code=0, output="", raises: Exception | None = None):
        self.code = code
        self.output = output
        self.raises = raises
        self.calls: list[pathlib.Path] = []

    def __call__(self, target):
        self.calls.append(pathlib.Path(target))
        if self.raises is not None:
            raise self.raises
        return self.code, self.output


def run_step(target, runner):
    """apply_patches with the console captured, so 'loud' can be asserted."""
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        record = deck_patches.apply_patches(target, runner=runner)
    return record, buf.getvalue()


print("\n## 1. the payload exists")

for f in (OVERLAY_ORCH / "deck_patches.py", OVERLAY_ORCH / "deck_configure.py", APPLIER_SRC):
    check_true(f"present: {f.relative_to(REPO_ROOT)}", f.is_file())

proc = os.system(f"python3 -m py_compile {OVERLAY_ORCH / 'deck_patches.py'} 2>/dev/null")
check("deck_patches.py compiles", proc, 0)


print("\n## 2. 🔴 WHERE it runs — inside the target, via arch-chroot")

cmd = deck_patches.chroot_command("/mnt")
check("the command is an arch-chroot into the target", cmd[:2], ["arch-chroot", "/mnt"])
check("…invoking the applier by its absolute in-target path", cmd[2], "/usr/bin/omarchy-deck-apply-patches")
check("…and nothing else: no --root/--patch-dir/--state-file to disagree with", len(cmd), 3)
check(
    "🔴 it does NOT run on the live side against the target's /usr/share/omarchy "
    "(pacman -Q and the qt6 qmllint path are not relocatable)",
    any(arg.startswith("--root") for arg in cmd),
    False,
)
check("…nor claim to be the ALPM hook", "--from-hook" in cmd, False)
check("…nor pass --verify, which would report without applying anything", "--verify" in cmd, False)
check("the target is stringified, so a Path argument works", deck_patches.chroot_command(pathlib.Path("/mnt"))[1], "/mnt")


print("\n## 3. 🔴 guard 6.4a — the applier path is COMPOSED, not a literal")

# iso/bin/build's guard 6.4a greps this directory for /usr/bin/omarchy-* and
# fails the build unless every match exists in the pinned basecamp/omarchy
# checkout's bin/. Ours comes from the omarchy-deck package instead. The
# composition below is therefore load-bearing, and both halves are asserted so
# that neither the path nor the reason can drift silently.
patches_text = (OVERLAY_ORCH / "deck_patches.py").read_text()
# Guard 6.4a's own expression, over the WHOLE file — it greps, so a docstring
# or a comment mentioning the path trips it exactly as code would.
GUARD_64A_RE = r"/usr/bin/omarchy-[A-Za-z0-9._-]+"
check(
    "🔴 no bare /usr/bin/omarchy-* literal survives anywhere in deck_patches.py "
    "(guard 6.4a greps the whole file and would fail the build with a wrong diagnosis)",
    re.findall(GUARD_64A_RE, patches_text),
    [],
)
check(
    "…and the expression itself still finds one when there is one "
    "(a guard with an empty subject is not a passing guard)",
    bool(re.findall(GUARD_64A_RE, "x = '/usr/bin/omarchy-deck-apply-patches'")),
    True,
)
check(
    "…but the composed value is exactly the path the package installs",
    deck_patches.APPLIER_ABS,
    "/usr/bin/omarchy-deck-apply-patches",
)
check("…and its target-relative twin agrees", deck_patches.APPLIER_REL, "usr/bin/omarchy-deck-apply-patches")


print("\n## 4. the applier's contract, DERIVED from the applier itself")

applier_text = APPLIER_SRC.read_text()

declared_codes = {
    int(m.group(2))
    for m in re.finditer(r"^readonly (EXIT_[A-Z]+)=(\d+)", applier_text, re.M)
}
check_true("the applier declares its exit codes as readonly constants", declared_codes)
check(
    "🔴 every exit code the applier declares has a meaning in deck_patches.EXIT_MEANING",
    sorted(declared_codes - set(deck_patches.EXIT_MEANING)),
    [],
)

default_state = re.search(r"^readonly DEFAULT_STATE_FILE=(\S+)", applier_text, re.M)
default_patch_dir = re.search(r"^readonly DEFAULT_PATCH_DIR=(\S+)", applier_text, re.M)
check(
    "🔴 the state file this step reads back is the applier's own default",
    default_state.group(1) if default_state else None,
    deck_patches.STATE_FILE_ABS,
)
check(
    "…and the patch directory it probes is too",
    default_patch_dir.group(1) if default_patch_dir else None,
    "/" + deck_patches.PATCH_DIR_REL,
)
check(
    "the applier's name matches the file the package installs",
    APPLIER_SRC.name,
    deck_patches.APPLIER_NAME,
)


print("\n## 5. find_applier — present, absent, and the half-installed shapes")

target = make_target("fa-ok")
found, reason = deck_patches.find_applier(target)
check("an installed, executable applier is found", found is not None, True)
check("…with no complaint", reason, "")

target = make_target("fa-none", applier=False)
found, reason = deck_patches.find_applier(target)
check("a missing applier is not found", found, None)
check_true("…and the reason names the path", "/usr/bin/omarchy-deck-apply-patches" in reason)

target = make_target("fa-noexec", applier_mode=0o644)
found, reason = deck_patches.find_applier(target)
check("🔴 a present-but-0644 applier is refused here, not inside the chroot", found, None)
check_true("…and says so precisely", "not executable" in reason)

target = make_target("fa-dangling", applier=False)
(target / deck_patches.APPLIER_REL).symlink_to("/nowhere/omarchy-deck-apply-patches")
found, reason = deck_patches.find_applier(target)
check("a dangling symlink is not a usable applier", found, None)
check_true("…and it is named as a dangling symlink, not as 'not installed'", "dangling" in reason)


print("\n## 6. 🔴 OUTCOME ONE — absent: recorded, loud, non-fatal")

target = make_target("ab-none", applier=False, patch_dir=False)
runner = Runner()
record, console = run_step(target, runner)
check("status is 'absent', a first-class outcome", record["status"], "absent")
check("🔴 the runner was never called — nothing was executed", runner.calls, [])
check("…and nothing raised: an install must still finish", record["ran"], False)
check_true("🔴 the record carries an error, so this is not a silent skip", record["error"])
check_true(
    "…which says what the user will actually experience",
    "~2s" in record["error"] and "~20s" in record["error"],
)
check_true("🔴 …and it reached the console (the orchestrator's install log)", "Deck patches" in console)
check_true("…the warning distinguishes 'omarchy-deck uninstalled'", any("uninstalled" in w for w in record["warnings"]))
check("no exit code is invented", record["exit_code"], None)
check("no state file is claimed", record["state_file"], None)

target = make_target("ab-half", applier=False, patch_dir=True)
record, console = run_step(target, Runner())
check("a half-installed package is still 'absent'", record["status"], "absent")
check_true(
    "🔴 …but is diagnosed as HALF-installed, not as uninstalled",
    any("half-installed" in w for w in record["warnings"]),
)


print("\n## 7. 🔴 OUTCOME TWO — present but failed")

target = make_target("fail-drift", state=state_doc("failed", [
    {
        "patch": "0010-lock-blank-timer-20s.patch",
        "status": "drift",
        "action": "none",
        "target": "shell/plugins/lock/Service.qml",
        "detail": "upstream drifted under shell/plugins/lock/Service.qml",
    }
]))
runner = Runner(code=3, output="omarchy-deck-apply-patches: ERROR: [0010] drift: ...\n")
record, console = run_step(target, runner)
check("status is 'failed'", record["status"], "failed")
check("…the applier really was run", [str(p) for p in runner.calls], [str(target)])
check("…the exit code is recorded verbatim", record["exit_code"], 3)
check_true("🔴 …translated into English, not left as a bare number", "drift" in record["exit_meaning"])
check("…the state file's verdict is carried across", record["overall"], "failed")
check("…and the per-patch row with it", record["patches"][0]["status"], "drift")
check_true("…naming the patch", "0010" in record["patches"][0]["patch"])
check_true("…and the target file", "Service.qml" in record["patches"][0]["target"])
check_true("🔴 the failure is on the console", "Deck patches" in console and "exited 3" in console)
check_true("…the applier's own output is kept for support", record["output"] and "drift" in record["output"])

target = make_target("fail-env", state=None)
record, console = run_step(target, Runner(code=4, output="no *.patch files\n"))
check("exit 4 (environment) is a failure too", record["status"], "failed")
check_true("…diagnosed as environment, not as drift", "environment" in record["exit_meaning"])
check_true("…and the missing state file is a warning, not a crash", any("wrote no" in w for w in record["warnings"]))

record, console = run_step(make_target("fail-odd"), Runner(code=99))
check("an undocumented exit code is still a failure", record["status"], "failed")
check_true("…and is called out as undocumented", "undocumented" in record["exit_meaning"])

runner = Runner(raises=FileNotFoundError("arch-chroot"))
record, console = run_step(make_target("fail-nochroot"), runner)
check("🔴 no arch-chroot on the box is a record, not a traceback", record["status"], "failed")
check_true("…naming what could not be run", "arch-chroot" in record["error"])
check_true("…on the console", "Deck patches" in console)


print("\n## 8. 🔴 OUTCOME THREE — applied cleanly")

target = make_target("ok", state=state_doc("ok"))
runner = Runner(code=0, output="omarchy-deck-apply-patches: all 1 patch(es) ok\n")
record, console = run_step(target, runner)
check("status is 'applied'", record["status"], "applied")
check("…with no error", record["error"], None)
check("…no warnings", record["warnings"], [])
check("…exit 0", record["exit_code"], 0)
check("…the state file is quoted by path", record["state_file"], "/var/lib/omarchy-deck/patch-state.json")
check("…overall ok", record["overall"], "ok")
check("…and the patch rows are carried into the install log", len(record["patches"]), 1)
check("…which is what the [V] QEMU row asserts", record["patches"][0]["status"], "ok")
check_true("…and the console says so", "Deck patches applied" in console)


print("\n## 9. 🔴 a zero exit that the state file does not back up")

target = make_target("contradict", state=state_doc("failed"))
record, console = run_step(target, Runner(code=0))
check("🔴 exit 0 + overall=failed is NOT 'applied'", record["status"], "failed")
check_true("…and the disagreement is named as such", "disagree" in record["error"])

target = make_target("nostate")
record, console = run_step(target, Runner(code=0))
check("🔴 exit 0 with no state file at all is NOT 'applied'", record["status"], "failed")
check_true("…and the missing file is reported", any("wrote no" in w for w in record["warnings"]))

target = make_target("badstate", state="{ this is not json")
record, console = run_step(target, Runner(code=0))
check("a corrupt state file is not read as success", record["status"], "failed")
check_true("…and the parse failure is reported", any("not valid JSON" in w for w in record["warnings"]))

target = make_target("arraystate", state="[]")
record, console = run_step(target, Runner(code=0))
check("a state file that is not an object is refused", record["status"], "failed")

target = make_target("hugestate", state="{" + " " * (deck_patches.MAX_STATE_BYTES + 1) + "}")
record, console = run_step(target, Runner(code=0))
check("an oversized state file is not parsed", record["status"], "failed")
check_true("…and says why", any("refusing to parse" in w for w in record["warnings"]))


print("\n## 10. what reaches the world-readable install log")

target = make_target("hostile", state=state_doc("failed", [
    {
        "patch": "0010\x1b[2J.patch",
        "status": "drift",
        "target": "a\nb",
        "detail": "x" * 900,
    }
]))
record, console = run_step(target, Runner(code=3, output="line\x07one\nline\ntwo\n"))
row = record["patches"][0]
check("control bytes are stripped from the recorded patch name", "\x1b" in row["patch"], False)
check("…and newlines from the target", "\n" in row["target"], False)
check("a huge detail is truncated", len(row["detail"]) <= deck_patches.MAX_LINE_CHARS + 3, True)
check("…and the truncation is marked", row["detail"].endswith("..."), True)
check("the applier's output is folded onto one line", "\n" in record["output"], False)
check("…with the lines still separated", " | " in record["output"], True)
check("…and no BEL survives", "\x07" in record["output"], False)

many = state_doc("failed", [{"patch": f"{i}.patch", "status": "drift"} for i in range(50)])
record, _ = run_step(make_target("manypatches", state=many), Runner(code=3))
check("an absurd number of patch rows is capped", len(record["patches"]), deck_patches.MAX_STATE_PATCHES)


print("\n## 11. the step entry point and the shared document")

target = make_target("step", state=state_doc("ok"))
saved = deck_patches.run_in_target
deck_patches.run_in_target = Runner(code=0, output="ok\n")
try:
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        deck_configure.record_result(target, "wifi", {"status": "skipped"})
        deck_patches.apply_patches_step(FakeCtx(target))
finally:
    deck_patches.run_in_target = saved

log_path = target / deck_configure.DECK_INSTALL_LOG_REL
doc = json.loads(log_path.read_text())
check("the outcome lands under the 'patches' key", doc["patches"]["status"], "applied")
check("🔴 …without clobbering another step's key", doc["wifi"]["status"], "skipped")
check("…and the log stays 0644", mode_of(log_path), "0644")

# The absent case through the real entry point, because that is the one every
# install takes today and the one whose silence would be invisible.
target = make_target("step-absent", applier=False, patch_dir=False)
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    deck_patches.apply_patches_step(FakeCtx(target))
doc = json.loads((target / deck_configure.DECK_INSTALL_LOG_REL).read_text())
check("🔴 'absent' is recorded through the real step, not only the helper", doc["patches"]["status"], "absent")
check_true("…with its error text intact", "NOT applied" in doc["patches"]["error"])


print("\n## 12. the registry, from the configure_deck side")

names = [s.name for s in deck_configure.deck_steps()]
check("the patches step is registered", "patches" in names, True)
step = [s for s in deck_configure.deck_steps() if s.name == "patches"][0]
check("…bound to apply_patches_step", step.fn, deck_patches.apply_patches_step)
check(
    "🔴 …and non-critical: a stale patch degrades the Deck, it does not brick it",
    step.critical,
    False,
)


# configure_deck must survive the step end-to-end on a target with no applier —
# today's real case — and must NOT raise, because critical=False.
target = tmpdir("cd-real") / "mnt"
target.mkdir(parents=True, exist_ok=True)
buf = io.StringIO()
raised = None
try:
    with contextlib.redirect_stdout(buf):
        deck_configure.configure_deck(FakeCtx(target))
except Exception as exc:  # noqa: BLE001
    raised = exc
check("🔴 a whole configure_deck run against a bare target does not raise", raised, None)
doc = json.loads((target / deck_configure.DECK_INSTALL_LOG_REL).read_text())
check("…and it recorded the patches step", doc["patches"]["status"], "absent")
check("…alongside the wifi step, in the one document", "wifi" in doc, True)


print()
print(f"{CHECKS - FAILURES}/{CHECKS} checks passed")
if FAILURES:
    print(f"{FAILURES} FAILURES")
shutil.rmtree(WORK, ignore_errors=True)
sys.exit(1 if FAILURES else 0)
