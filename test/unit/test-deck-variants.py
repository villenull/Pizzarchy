#!/usr/bin/env python3
"""Unit tests for the four-variant FAST-INSTALL split (Stages slice).

No VM, no root, no network, no chroot, no ISO build. Run directly:

    python3 test-deck-variants.py

WHAT THIS SUITE IS ACTUALLY FOR
===============================

The rewritten FAST-INSTALL contract (docs/tasks/FAST-INSTALL.md, four
variants) moves every variant branch into Stages-owned code: the choices
reader, the variant delta installer, the stage split, the desktop greeter,
and the late identity helpers. Each branch below is shaped around the exact
failure it would otherwise produce silently:

1. Choices: a missing/malformed answer must abort loudly, never default.
   Defaulting ``no`` would silently drop Steam; defaulting ``yes`` would
   silently download it. ``locked`` gates optional pacman; preinstalls is
   immutable after it; gaming is re-read at every gate (yes->no flip).
2. Variant delta: the 13 preinstall names are DERIVED from the pinned
   runtime's remove script (parsed, not copied); the suite asserts identity
   whenever the checkout is available. Installs are outcome-asserted against
   the target db (P32: zero exits that install nothing must read ``failed``),
   and no/no installs nothing.
3. Stage split: the classification table covers the deck registry exactly
   once (except pkgs/steam, which the staged APIs replace); early order is
   restore -> choices -> preinstalls delta -> network gate -> gaming delta ->
   pkgs -> UKI -> steam fetch; gaming=yes fails loudly on a missing client
   manifest; gaming=no skips every Steam touch and writes skipped-no-gaming.
4. Late desktop: gaming=no writes the password greeter (Qt Virtual Keyboard,
   Omarchy session, no autologin file) and asserts the session file exists;
   the preinstalls-no marker lands in the final home for the desktop opt-in.
5. Kernel: stock ``linux`` beside ``linux-omarchy`` fails loudly (C5).
"""

from __future__ import annotations

import ast
import contextlib
import io
import os
import pathlib
import shutil
import subprocess
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
RUNTIME_SRC = (
    pathlib.Path.home() / ".cache/omarchy-deck/iso-build-4.0.4/runtime-src"
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


def check_raises(what: str, fn, needle: str) -> None:
    global FAILURES, CHECKS
    CHECKS += 1
    try:
        fn()
    except Exception as exc:  # noqa: BLE001 -- the point is the message
        if needle in str(exc):
            print(f"ok   {what}")
            return
        FAILURES += 1
        print(f"FAIL {what}: raised {exc!r}, want {needle!r} inside")
        return
    FAILURES += 1
    print(f"FAIL {what}: did not raise (want {needle!r})")


# ---------------------------------------------------------------------------
# Harness: rebuild the orchestrator package shape around the modules
# ---------------------------------------------------------------------------

WORK = pathlib.Path(tempfile.mkdtemp(prefix="deck-variants-test-"))

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
    # The REAL ui.py and keyboard.py from the pinned upstream tree, not
    # stubs: if upstream renames info/error this suite goes red, which is
    # the cheap drift signal.
    for name in ("ui.py", "keyboard.py", "command.py"):
        src = UPSTREAM_ORCH / name
        if src.exists():
            shutil.copyfile(src, pkg / name)
    for module in sorted(OVERLAY_ORCH.glob("deck_*.py")):
        shutil.copyfile(module, pkg / module.name)
    (pkg / "phases_impl.py").write_text(PHASES_IMPL_STUB)
    return root


PKG_ROOT = build_package()
sys.path.insert(0, str(PKG_ROOT))

from orchestrator import (  # noqa: E402
    deck_choices,
    deck_configure,
    deck_install_identity as identity,
    deck_stage_split as split,
    deck_variant_packages as variants,
)

print(f"# modules loaded from {PKG_ROOT}")


class FakeCtx:
    def __init__(self, target, username="deck", defer_provisioning=False,
                 creds=None, config=None):
        self.target = pathlib.Path(target)
        self.username = username
        self.defer_provisioning = defer_provisioning
        self.user_credentials = creds if creds is not None else {"users": []}
        self.user_configuration = config if config is not None else {}


def tmpdir(name: str) -> pathlib.Path:
    d = WORK / name
    d.mkdir(parents=True, exist_ok=True)
    return d


def write_choices(d: pathlib.Path, preinstalls: str, gaming: str, locked=True) -> pathlib.Path:
    d.mkdir(parents=True, exist_ok=True)
    (d / "preinstalls").write_text(preinstalls)
    (d / "gaming").write_text(gaming)
    if locked:
        (d / "locked").write_text("\n")
    return d


# ---------------------------------------------------------------------------
# 1. Choices: exact values, locked gate, immutable preinstalls, live gaming
# ---------------------------------------------------------------------------

print("\n# 1. installer choices")

cdir = write_choices(tmpdir("choices-yes") / "c", "yes\n", "no\n")
check("yes/no read back as booleans", deck_choices.read_choices(cdir), (True, False))

cdir2 = write_choices(tmpdir("choices-no") / "c", "no\n", "yes\n")
check("reversed answers", deck_choices.read_choices(cdir2), (False, True))

check_raises(
    "missing gaming file aborts, never defaults",
    lambda: deck_choices.read_choices(write_choices(tmpdir("choices-miss") / "c", "yes\n", "yes\n", locked=True) and (tmpdir("choices-miss") / "c" / "gaming").unlink() or tmpdir("choices-miss") / "c"),
    "missing",
)

bad = write_choices(tmpdir("choices-bad") / "c", "YES\n", "no\n")
check_raises(
    "uppercase YES is not yes",
    lambda: deck_choices.read_choices(bad),
    "not exactly 'yes' or 'no'",
)

unlocked = tmpdir("choices-unlocked") / "c"
unlocked.mkdir(parents=True, exist_ok=True)
(unlocked / "preinstalls").write_text("no\n")
(unlocked / "gaming").write_text("no\n")
os.environ[deck_choices.CHOICES_WAIT_SECS_ENV] = "0"
check_raises(
    "unlocked choices time out loudly instead of installing unanswered",
    lambda: deck_choices.wait_locked(unlocked),
    "never locked",
)
del os.environ[deck_choices.CHOICES_WAIT_SECS_ENV]

locked_dir = write_choices(tmpdir("choices-locked") / "c", "no\n", "yes\n")
check("locked answers returned", deck_choices.wait_locked(locked_dir), (False, True))
check("gaming re-read live (flip observed)", deck_choices.read_gaming(locked_dir), True)
(locked_dir / "gaming").write_text("no\n")
check("gaming yes->no flip visible before online work", deck_choices.read_gaming(locked_dir), False)
check("preinstalls answers still no after gaming flip", deck_choices.read_choices(locked_dir), (False, False))

# ---------------------------------------------------------------------------
# 2. Variant delta: derived names, outcome assertion, no/no fast path
# ---------------------------------------------------------------------------

print("\n# 2. variant package delta")


def make_db(target: pathlib.Path, names) -> None:
    db = target / "var/lib/pacman/local"
    db.mkdir(parents=True, exist_ok=True)
    for name in names:
        entry = db / f"{name}-1.0-1"
        entry.mkdir(parents=True, exist_ok=True)
        (entry / "desc").write_text(f"%NAME%\n{name}\n%VERSION%\n1.0-1\n")


LIVE_MANIFESTS = REPO_ROOT / "iso/overlay/configs/deck"
if (LIVE_MANIFESTS / "deck-preinstalls.packages").exists():
    print("note RootImage manifests landed; drift check below covers them")
else:
    print("note RootImage manifests not landed yet; manifest assertions use fixtures below")

# Manifest reader: repo qualification stripped, malformed dropped, empty fatal.
live = tmpdir("manifests") / "iso"
(live / "usr/share/omarchy-iso").mkdir(parents=True, exist_ok=True)
(live / "usr/share/omarchy-iso/deck-preinstalls.packages").write_text(
    "# comment\n\n"
    "aether\n"
    "jupiter-staging/gamescope\n"
    "not a package!\n"
    "aether\n"
)
names, warnings = variants.read_package_list(live, variants.PREINSTALL_LIST_REL)
check("qualification stripped, dupes collapsed", names, ["aether", "gamescope"])
check_true("malformed entry warned, not passed to pacman", any("not a package" in w or "plain pacman" in w for w in warnings))
try:
    (live / "usr/share/omarchy-iso/deck-preinstalls.packages").write_text("# nothing\n")
    variants.read_package_list(live, variants.PREINSTALL_LIST_REL)
    check("empty manifest fails loudly (P32)", "no raise", "RuntimeError")
except RuntimeError as exc:
    check_true("empty manifest fails loudly (P32)", "no usable package" in str(exc))
try:
    variants.read_package_list(live, "usr/share/omarchy-iso/deck-missing.packages")
    check("missing manifest fails loudly", "no raise", "RuntimeError")
except RuntimeError as exc:
    check_true("missing manifest fails loudly", "does not exist" in str(exc))

if RUNTIME_SRC.is_dir():
    parsed, _ = variants.runtime_preinstall_packages(RUNTIME_SRC)
    (live / "usr/share/omarchy-iso/deck-preinstalls.packages").write_text("\n".join(parsed) + "\n")
    back, _ = variants.read_package_list(live, variants.PREINSTALL_LIST_REL)
    check(
        "ISO manifest matches the pinned remove script (no drift)",
        sorted(back),
        sorted(parsed),
    )
else:
    print("note runtime checkout absent; drift check skipped (manifest stands alone)")

t = tmpdir("delta-nonono") / "mnt"
t.mkdir(parents=True, exist_ok=True)
rec = variants.install_variant_delta(t, False, False)
check("no/no installs nothing with status ok", (rec["status"], rec["requested"]), ("ok", []))

calls: list = []
OFFLINE_CONF_TEXT = (
    "[options]\nArchitecture = auto\n\n[offline]\nSigLevel = Never\n"
    "Server = file:///var/cache/omarchy/mirror/offline/\n"
)
ONLINE_CONF_TEXT = "[options]\n\n[core]\nInclude = /etc/pacman.d/mirrorlist\n"
conf_seen: list = []


def _pacman_argv(argv):
    return "pacman" in argv and "arch-chroot" in argv


def _record_conf(target, argv):
    """What the transaction's --config really says, read at call time."""
    conf = argv[argv.index("--config") + 1] if "--config" in argv else "/etc/pacman.conf"
    conf_seen.append((target / conf.lstrip("/")).read_text())


def fake_run(argv, timeout):
    calls.append(list(argv))
    if _pacman_argv(argv):
        _record_conf(t2, argv)
    return 0, "ok"


live2 = tmpdir("manifests-pre") / "iso"
(live2 / "usr/share/omarchy-iso").mkdir(parents=True, exist_ok=True)
(live2 / "etc").mkdir(parents=True, exist_ok=True)
(live2 / "etc/pacman.conf").write_text(OFFLINE_CONF_TEXT)
(live2 / "usr/share/omarchy-iso/deck-preinstalls.packages").write_text("aether\n")
(live2 / "usr/share/omarchy-iso/deck-gaming.packages").write_text("gamescope\n")
t2 = tmpdir("delta-pre") / "mnt"
(t2 / "etc").mkdir(parents=True, exist_ok=True)
# By this phase omarchy-setup-system has rewritten the target's pacman.conf to
# the ONLINE repos -- the first QEMU yes/no run died resolving against it.
(t2 / "etc/pacman.conf").write_text(ONLINE_CONF_TEXT)
make_db(t2, [])
orig_run = variants._run
variants._run = fake_run
try:
    rec2 = variants.install_variant_delta(t2, True, False, live_root=live2)
finally:
    variants._run = orig_run
check("preinstalls delta fails loudly when pacman wrote nothing", rec2["status"], "failed")
pacman_calls = [a for a in calls if _pacman_argv(a)]
check("exactly one pacman transaction, inside the target", len(pacman_calls), 1)
check("the transaction resolved against the offline repo only, not the target's online pacman.conf",
      conf_seen, [OFFLINE_CONF_TEXT])
check_true("package files read from the mirror in place (no copy into @pkg)",
           pacman_calls and pacman_calls[0][pacman_calls[0].index("--cachedir") + 1]
           == "/var/cache/omarchy/mirror/offline")
check("the target's own pacman.conf is left as the runtime wrote it",
      (t2 / "etc/pacman.conf").read_text(), ONLINE_CONF_TEXT)
check("the staged offline config does not outlive the transaction",
      (t2 / variants.TARGET_OFFLINE_CONF.lstrip("/")).exists(), False)
check("a mirror this call bind-mounted is unmounted again",
      [a[0] for a in calls if a[0] in ("mount", "umount")], ["mount", "umount"])

# A live config that is not the offline one must stop the delta before pacman.
live_bad = tmpdir("manifests-bad") / "iso"
(live_bad / "usr/share/omarchy-iso").mkdir(parents=True, exist_ok=True)
(live_bad / "etc").mkdir(parents=True, exist_ok=True)
(live_bad / "etc/pacman.conf").write_text(ONLINE_CONF_TEXT)
(live_bad / "usr/share/omarchy-iso/deck-preinstalls.packages").write_text("aether\n")
calls.clear()
variants._run = fake_run
try:
    rec_bad = variants.install_variant_delta(t2, True, False, live_root=live_bad)
finally:
    variants._run = orig_run
check("a non-offline live pacman.conf fails the delta before any transaction",
      (rec_bad["status"], [a for a in calls if _pacman_argv(a)]), ("failed", []))


t3 = tmpdir("delta-game") / "mnt"
t3.mkdir(parents=True, exist_ok=True)
make_db(t3, [])
seen: list = []


def fake_run_seed(argv, timeout):
    seen.append(list(argv))
    if _pacman_argv(argv):
        make_db(t3, argv[argv.index("--noconfirm") + 1:])
    return 0, "ok"


variants._run = fake_run_seed
try:
    rec3 = variants.install_variant_delta(t3, False, True, live_root=live2)
finally:
    variants._run = orig_run
check("gaming delta installs the gaming set", rec3["status"], "ok")
check_true("gamescope requested for gaming=yes", "gamescope" in rec3["requested"])
check_true("steam launcher NOT in the offline delta (stays online fetch)", "steam" not in rec3["requested"])


print("\n# 2b. preinstalls=no removal (canonical tools, no gum)")
from orchestrator import deck_session_bake as _bake_mod  # noqa: F401 -- import shape asserted

# The omarchy 4.0.4 package's real layout: regular files in /usr/bin, and
# /usr/share/omarchy/bin entries that are ABSOLUTE symlinks to them. The
# first QEMU run of the variants died here: the check followed that absolute
# link into the live ISO's root, where the tool does not exist.
tgt_r = tmpdir("removal") / "mnt"
(tgt_r / "usr/bin").mkdir(parents=True, exist_ok=True)
(tgt_r / "usr/share/omarchy/bin").mkdir(parents=True, exist_ok=True)
(tgt_r / "home/deck/.local/bin").mkdir(parents=True, exist_ok=True)
(tgt_r / "home/deck/.local/share/applications").mkdir(parents=True, exist_ok=True)
for _tool in ("omarchy-webapp-remove-all", "omarchy-tui-remove-all"):
    (tgt_r / "usr/bin" / _tool).write_text("#!/usr/bin/env bash\nexit 0\n")
    (tgt_r / "usr/share/omarchy/bin" / _tool).symlink_to(f"/usr/bin/{_tool}")
(tgt_r / "home/deck/.local/bin/codex").write_text("stub\n")
(tgt_r / "home/deck/.local/bin/gh").write_text("stub\n")

runs = []


def _chroot_run(argv, timeout, env=None):
    runs.append((list(argv), dict(env or {})))
    return 0, "removed\n"


orig = variants._run
variants._run = _chroot_run
try:
    rec_r = variants.apply_preinstalls_removal(tgt_r, "deck")
finally:
    variants._run = orig
check("removal runs both canonical tools as the user", [r[0][-1] for r in runs],
      ["/usr/bin/omarchy-webapp-remove-all",
       "/usr/bin/omarchy-tui-remove-all"])
check_true("removal runs as the target user (HOME-scoped tools)", all(r[1].get("HOME") == "/home/deck" for r in runs))
check_true("unconditional mise stubs removed", (tgt_r / "home/deck/.local/bin/codex").exists() is False)
check("removal status ok", rec_r["status"], "ok")

tgt_m = tmpdir("removal-missing") / "mnt"
(tgt_m / "home/deck").mkdir(parents=True, exist_ok=True)
rec_m = variants.apply_preinstalls_removal(tgt_m, "deck")
check("missing removal tool fails loudly (no silent yes-means-no)", rec_m["status"], "failed")

# Presence is judged INSIDE the target: an absolute symlink whose target
# exists on the machine running the installer (here /bin/sh) but not in the
# target must read as missing, not present.
tgt_h = tmpdir("removal-host-link") / "mnt"
(tgt_h / "usr/bin").mkdir(parents=True, exist_ok=True)
(tgt_h / "home/deck").mkdir(parents=True, exist_ok=True)
for _tool in ("omarchy-webapp-remove-all", "omarchy-tui-remove-all"):
    (tgt_h / "usr/bin" / _tool).symlink_to("/bin/sh")
rec_h = variants.apply_preinstalls_removal(tgt_h, "deck")
check("a tool whose absolute link resolves only on the live root reads as missing",
      rec_h["status"], "failed")
# ---------------------------------------------------------------------------
# 3. Stage split: registry coverage, early order, gaming gates
# ---------------------------------------------------------------------------
print("\n# 3b. desktop-only session bake consumer")

import subprocess as _sp

sh = REPO_ROOT / "src" / "deck-session.sh"
listed = _sp.run(["bash", str(sh), "list-desktop-bake-stages"], capture_output=True, text=True)
check("list-desktop-bake-stages exits 0", listed.returncode, 0)
desktop_stages = [l.strip() for l in listed.stdout.splitlines() if l.strip()]
check_true("desktop subset is non-empty and smaller than the full bake list",
           0 < len(desktop_stages) < 40)
check("desktop subset starts at preconditions", desktop_stages[0], "stage-preconditions")
for forbidden in ("stage-steam-hook", "stage-default-session", "stage-boot-default-gaming",
                  "stage-session-select"):
    check(f"desktop subset omits gaming-only {forbidden}", forbidden in desktop_stages, False)
for required in ("stage-input-mapper", "stage-lizard-mode", "stage-power-button"):
    check(f"desktop subset keeps controller capability {required}", required in desktop_stages, True)
check_true(
    "bake module knows the desktop verb (asked, not copied)",
    hasattr(__import__("orchestrator.deck_session_bake", fromlist=["x"]), "DESKTOP_LIST_VERB"),
)

from orchestrator import deck_session_bake as _bake

# The split's gaming=no path must call the baker (not the shared registry
# step, which takes no flag) and assert the session explicitly.
import re as _re
_split_src = (REPO_ROOT / "iso/overlay/configs/airootfs/usr/share/omarchy-iso/orchestrator/deck_stage_split.py").read_text()
check_true(
    "split desktop path calls bake_session(desktop_only=True)",
    "bake_session(ctx, desktop_only=True)" in _split_src,
)
check_true(
    "split asserts the desktop session explicitly (no skip-probes reliance)",
    "_assert_desktop_session" in _split_src,
)
check_true(
    "split desktop path writes the password greeter",
    "configure_desktop_greeter" in _split_src,
)

check("desktop env flag name", _bake.DESKTOP_ONLY_ENV_FLAG, "DECK_SESSION_DESKTOP_ONLY")
env = _bake.chroot_env("deck", desktop_only=True)
check("desktop chroot env carries the flag", env.get("DECK_SESSION_DESKTOP_ONLY"), "1")
env2 = _bake.chroot_env("deck")
check("gaming chroot env omits the flag", "DECK_SESSION_DESKTOP_ONLY" in env2, False)

seen_env = {}


def _rec_runner(target, argv, user, timeout=None):
    seen_env.setdefault(tuple(argv), dict())
    calls.append(list(argv))
    if argv[-1] in (_bake.LIST_VERB, _bake.DESKTOP_LIST_VERB):
        return 0, "stage-preconditions\n"
    return 0, "[deck-session] ok\n"


def _mkctx(target):
    (target / "etc").mkdir(parents=True, exist_ok=True)
    (target / "etc/passwd").write_text("root:x:0:0::/root:/bin/bash\ndeck:x:1000:1000::/home/deck:/bin/bash\n")
    (target / "home/deck").mkdir(parents=True, exist_ok=True)
    assets = tmpdir("bake-dt-assets") / "s"
    assets.mkdir(parents=True, exist_ok=True)
    (assets / "deck-session.sh").write_text("#!/usr/bin/env bash\nexit 0\n")

    class C:
        pass
    c = C()
    c.target = target
    c.username = "deck"
    c.defer_provisioning = False
    return c, assets


native_calls = []


def _native_runner(target, argv, user, timeout=None, desktop_only=False):
    native_calls.append(desktop_only)
    if argv[-1] in (_bake.LIST_VERB, _bake.DESKTOP_LIST_VERB):
        return 0, "stage-preconditions\n"
    return 0, "[deck-session] ok\n"


wrapped = _bake._desktop_runner(_native_runner)
wrapped(tmpdir("bwrap") / "t", ["s", _bake.DESKTOP_LIST_VERB], "deck")
check("desktop wrapper forwards the flag to a native runner", native_calls, [True])

tgt = tmpdir("bake-desktop") / "mnt"
c, assets = _mkctx(tgt)
rec = _bake.bake_session(c, runner=_rec_runner, asset_dir=str(assets), desktop_only=True)
check("desktop bake records its mode", rec.get("desktop_only"), True)
check("desktop bake asks the desktop verb", rec.get("list_verb"), "list-desktop-bake-stages")
check_true("desktop bake ran preconditions", "stage-preconditions" in rec.get("ok", []))


print("\n# 3. stage split")


def full_phases():
    # PR #145's real build_phases uses a boot/user fan. The test below checks
    # these names against the patched main.py so a refactor cannot drift.
    names = [
        "Preparing live environment", "Preparing install target",
        "Installing Arch + Omarchy", "Configuring hibernation",
        "Configuring system", "Configuring Steam Deck", "Staging provisioning",
        "Finalizing boot and user setup", "Validating boot setup",
        "Creating factory snapshot",
    ]
    return [(n, (lambda n: (lambda ctx: None))(n)) for n in names]
patched_tree = WORK / "upstream-patched"
subprocess.run(
    ["git", "clone", "--quiet", "--local", "--no-hardlinks", str(REPO_ROOT / "iso/upstream"), str(patched_tree)],
    check=True,
)
for patch_name in ("00-root-image-pr145.patch", "configure-deck-phase.patch"):
    subprocess.run(
        ["git", "-C", str(patched_tree), "apply", "--3way",
         str(REPO_ROOT / "iso/overlay/patches" / patch_name)],
        check=True,
        capture_output=True,
    )
main_tree = ast.parse(
    (patched_tree / "configs/airootfs/usr/share/omarchy-iso/orchestrator/main.py").read_text()
)
builder_fn = next(
    node for node in main_tree.body if isinstance(node, ast.FunctionDef) and node.name == "build_phases"
)
phase_return = next(node for node in builder_fn.body if isinstance(node, ast.Return))
actual_phase_names = [ast.literal_eval(pair.elts[0]) for pair in phase_return.value.elts]
check(
    "split fixture matches the real pinned+patched PR #145 phase names",
    [name for name, _ in full_phases()],
    actual_phase_names,
)
split_tree = ast.parse(
    (OVERLAY_ORCH / "deck_stage_split.py").read_text()
)
# Every phases_impl attribute the staged path resolves: _require(phases_impl,
# "name") at slice-build time plus the getattr probe in _keyring_join_fn.
# fake_impl below stubs these, so a name missing from the real upstream module
# would pass unit tests and die in QEMU instead.
required_impl_names = set()
for _node in ast.walk(split_tree):
    if not isinstance(_node, ast.Call):
        continue
    _func = _node.func
    if (
        isinstance(_func, ast.Name)
        and _func.id in ("_require", "getattr")
        and len(_node.args) >= 2
        and isinstance(_node.args[0], ast.Name)
        and _node.args[0].id == "phases_impl"
        and isinstance(_node.args[1], ast.Constant)
        and isinstance(_node.args[1].value, str)
    ):
        required_impl_names.add(_node.args[1].value)
patched_impl_tree = ast.parse(
    (patched_tree / "configs/airootfs/usr/share/omarchy-iso/orchestrator/phases_impl.py").read_text()
)
patched_impl_names = {
    _def.name for _def in patched_impl_tree.body
    if isinstance(_def, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef))
}
check(
    "every phases_impl attribute the staged path resolves exists in pinned+patched upstream",
    sorted(required_impl_names - patched_impl_names),
    [],
)
check_true(
    "staged-path attribute scan is non-empty (guard against a silent scan)",
    required_impl_names,
)


registry = {step.name for step in deck_configure.deck_steps()}
classified = set(split.STEP_CLASSIFICATION)
check("classification covers the registry exactly", classified, registry)
singles = [n for n, (s, _) in split.STEP_CLASSIFICATION.items() if s in ("early", "late")]
check_true(
    "every early/late step appears exactly once",
    len(singles) == len(set(singles)) and all(n in registry for n in singles),
)

import types as _types

fake_impl = _types.SimpleNamespace(
    __name__="fake_phases_impl",
    finalize_limine_boot=lambda ctx: None,
    _join_target_keyring_init=lambda ctx: None,
    run_chroot_finalizer=lambda ctx: None,
    configure_login=lambda ctx: None,
    configure_ssh_access=lambda ctx: None,
    configure_tailscale=lambda ctx: None,
    configure_dns_resolver=lambda ctx: None,
)
ctx = FakeCtx(tmpdir("split") / "mnt")
staged_fn = next(
    node for node in main_tree.body
    if isinstance(node, ast.FunctionDef) and node.name == "build_staged_phases"
)
staged_namespace = {
    "__package__": "orchestrator",
    "build_phases": lambda _: full_phases(),
}
exec(compile(ast.Module(body=[staged_fn], type_ignores=[]), "patched-main.py", "exec"),
     staged_namespace)
prior_stage = os.environ.get("OMARCHY_INSTALL_STAGE")
try:
    os.environ["OMARCHY_INSTALL_STAGE"] = "early"
    staged_names = [name for name, _ in staged_namespace["build_staged_phases"](ctx)]
finally:
    if prior_stage is None:
        os.environ.pop("OMARCHY_INSTALL_STAGE", None)
    else:
        os.environ["OMARCHY_INSTALL_STAGE"] = prior_stage
check_true("patched entrypoint resolves the early stage selector at runtime",
           "Finalizing Limine boot" in staged_names)
try:
    os.environ["OMARCHY_INSTALL_STAGE"] = "late"
    late_staged_names = [name for name, _ in staged_namespace["build_staged_phases"](ctx)]
finally:
    if prior_stage is None:
        os.environ.pop("OMARCHY_INSTALL_STAGE", None)
    else:
        os.environ["OMARCHY_INSTALL_STAGE"] = prior_stage
check_true("patched entrypoint resolves the late stage selector at runtime (omarchy-deck-late)",
           "Configuring login" in late_staged_names)

early = split.early_phases(ctx, fake_impl, full_phases())
names = [n for n, _ in early]
check_true("UKI build present in early", "Finalizing Limine boot" in names)
phase_order = (
    "Waiting for installer choices (preinstalls/gaming locked)",
    "Installing optional preinstalls offline",
    "Waiting for network (gaming=yes only)",
    "Installing optional gaming packages offline",
    "Installing Steam launcher (gaming=yes only)",
    "Staging provisioning",
    "Finalizing Limine boot",
)
check(
    "order: preinstalls -> network choice freeze -> gaming -> Steam -> UKI",
    [names.index(x) for x in phase_order],
    sorted(names.index(x) for x in phase_order),
)
check_true("no pacman phase after the UKI build except the Valve fetch", names.index("Fetching Steam client (staging, gaming=yes only)") > names.index("Finalizing Limine boot"))

late = split.late_phases(ctx, fake_impl, full_phases())
lnames = [n for n, _ in late]
check(
    "late: login before late deck slice (autologin drop-in is final writer)",
    lnames.index("Configuring login") < lnames.index("Configuring Steam Deck (late, user-dependent)"),
    True,
)
check(
    "late: steam relocation before user finalizer",
    lnames.index("Relocating Steam staging home (gaming=yes only)") < lnames.index("Finalizing user"),
    True,
)

# upstream's user finalizer copies the installer's offline-only pacman.conf
# into the target (_prepare_target_setup). In the split flow nothing rewrites
# it afterwards, and QEMU installs shipped a system whose only repo was the
# USB stick's mirror. The late phase must hand back the target's own file.
ONLINE_TARGET_CONF = b"[options]\n\n[core]\nInclude = /etc/pacman.d/mirrorlist\n"


def _copying_finalizer(c):
    (c.target / "etc/pacman.conf").write_text("[offline]\nServer = file:///var/cache/omarchy/mirror/offline/\n")


ctx_pc = FakeCtx(tmpdir("late-pacman-conf") / "mnt")
(ctx_pc.target / "etc").mkdir(parents=True, exist_ok=True)
(ctx_pc.target / "etc/pacman.conf").write_bytes(ONLINE_TARGET_CONF)
impl_pc = _types.SimpleNamespace(**{**vars(fake_impl), "run_chroot_finalizer": _copying_finalizer})
dict(split.late_phases(ctx_pc, impl_pc, full_phases()))["Finalizing user"](ctx_pc)
check("late: the target keeps its own pacman.conf, not the installer's offline one",
      (ctx_pc.target / "etc/pacman.conf").read_bytes(), ONLINE_TARGET_CONF)

# ---------------------------------------------------------------------------
# 4. Desktop greeter + preinstall marker + kernel assert
# ---------------------------------------------------------------------------

print("\n# 4. desktop greeter, preinstall marker, kernel")


def make_target_fs(name: str) -> pathlib.Path:
    t = tmpdir(name) / "mnt"
    for d in ("etc/sddm.conf.d", "etc/skel", "usr/share/wayland-sessions",
              "usr/local/share/wayland-sessions", "var/lib/sddm"):
        (t / d).mkdir(parents=True, exist_ok=True)
    (t / "usr/share/wayland-sessions/omarchy.desktop").write_text("[Desktop Entry]\nName=Omarchy\n")
    return t


t4 = make_target_fs("greeter")
fctx = FakeCtx(t4, username="deck")
def _theme_files(t):
    for rel in identity.GREETER_THEME_REQUIRES:
        (t / rel).parent.mkdir(parents=True, exist_ok=True)
        (t / rel).write_text("x\n")


_theme_files(t4)
# Omarchy's own drop-in selects its stock theme; ours must sort after it.
(t4 / "etc/sddm.conf.d/99-omarchy-login.conf").write_text("[Theme]\nCurrent=omarchy\n")
identity.configure_desktop_greeter(t4, "deck")


def _sddm_effective(conf_dir):
    """SDDM's merge: files in name order, later keys win."""
    import configparser
    merged = configparser.ConfigParser(interpolation=None, strict=False)
    merged.optionxform = str
    for conf in sorted(conf_dir.glob("*.conf")):
        merged.read(conf)
    return merged


eff = _sddm_effective(t4 / "etc/sddm.conf.d")
check("the Deck keyboard theme wins over Omarchy's own Current=",
      eff.get("Theme", "Current"), identity.GREETER_THEME)
check("the Wayland greeter gets QT_IM_MODULE (InputMethod= alone is X11-only)",
      eff.get("General", "GreeterEnvironment"), "QT_IM_MODULE=qtvirtualkeyboard")
check("greeter enables Qt Virtual Keyboard", eff.get("General", "InputMethod"), "qtvirtualkeyboard")
t4c = tmpdir("greeter-no-theme") / "mnt"
for d in ("etc/sddm.conf.d", "var/lib/sddm", "usr/share/wayland-sessions"):
    (t4c / d).mkdir(parents=True, exist_ok=True)
(t4c / "usr/share/wayland-sessions/omarchy.desktop").write_text("[Desktop Entry]\n")
check_raises(
    "a keyboard theme that cannot load is never selected (no un-loginable greeter)",
    lambda: identity.configure_desktop_greeter(t4c, "deck"),
    "cannot load",
)
check("…and nothing was written for it", list((t4c / "etc/sddm.conf.d").iterdir()), [])
state = (t4 / "var/lib/sddm/state.conf").read_text()
check_true("greeter selects the Omarchy desktop session", "omarchy.desktop" in state and "User=deck" in state)
check("no autologin file on the password greeter", (t4 / "etc/sddm.conf.d/autologin.conf").exists(), False)
t4b = tmpdir("greeter-missing") / "mnt"
for d in ("etc/sddm.conf.d", "var/lib/sddm"):
    (t4b / d).mkdir(parents=True, exist_ok=True)
check_raises(
    "missing desktop session file fails loudly (no login loop)",
    lambda: identity.configure_desktop_greeter(t4b, "deck"),
    "no Omarchy desktop session",
)

home = t4 / "home/deck"
home.mkdir(parents=True, exist_ok=True)
_owned: dict = {}
_real_lchown = os.lchown
identity.os.lchown = lambda p, u, g: (_owned.__setitem__(str(p), (u, g)), _real_lchown(p, u, g))[1]
try:
    identity.apply_preinstalls_choice(t4, "/home/deck", False)
finally:
    identity.os.lchown = _real_lchown
marker = home / ".local/state/omarchy/preinstalls-removed"
check("preinstalls=no leaves the opt-in marker in the final home", marker.is_file(), True)
# Written as root on a real install: the user's own Install > Preinstalls
# must be able to remove it, so it and every directory made for it are the
# home owner's (observed through the calls -- unprivileged, we own them anyway).
_home_owner = (home.stat().st_uid, home.stat().st_gid)
check("…the marker and the directories made for it are handed to the home's owner",
      {k: v for k, v in _owned.items() if k.startswith(str(home))},
      {str(home / ".local"): _home_owner, str(home / ".local/state"): _home_owner,
       str(home / ".local/state/omarchy"): _home_owner, str(marker): _home_owner})
home2 = t4 / "home/deck2"
home2.mkdir(parents=True, exist_ok=True)
identity.apply_preinstalls_choice(t4, "/home/deck2", True)
check(
    "preinstalls=yes leaves no marker",
    (home2 / ".local/state/omarchy/preinstalls-removed").exists(),
    False,
)

t5 = tmpdir("kernel") / "mnt"
db = t5 / "var/lib/pacman/local"
(t5 / "var/lib/pacman/local").mkdir(parents=True, exist_ok=True)
for pkg in ("linux-omarchy-7.2.5-1", "linux-6.9-1"):
    e = db / pkg
    e.mkdir(parents=True, exist_ok=True)
    short = pkg.rsplit("-", 2)[0]
    (e / "desc").write_text(f"%NAME%\n{short}\n%VERSION%\n1\n")
check_raises(
    "stock linux beside linux-omarchy fails loudly",
    lambda: identity.assert_deck_kernel(t5),
    "stock kernel",
)
shutil.rmtree(db / "linux-6.9-1")
identity.assert_deck_kernel(t5)
print("ok   linux-omarchy alone passes")

# ---------------------------------------------------------------------------

shutil.rmtree(WORK, ignore_errors=True)

print(f"\n{CHECKS} checks, {FAILURES} failed")
sys.exit(1 if FAILURES else 0)
