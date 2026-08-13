#!/usr/bin/env python3
"""Unit tests for `configure_deck`'s `desktop_rotation` step — T5 §5.2's fourth
rotation surface, the desktop's own `~/.config/hypr/monitors.lua`
(`deck_monitors.py`).

No VM, no root, no network, no chroot, no compositor, no ISO build, and nothing
against the Deck:

    python3 test-deck-monitors.py

WHAT THIS SUITE IS ACTUALLY FOR
===============================

Everything is asserted against a **scratch target filesystem this suite builds**,
by running the step and reading the artefacts back — never by grepping the
module's own source. The exceptions are the scrapes in §1, which read
`docs/` and the pinned runtime's own install manifest on purpose: the measured
values and four facts about Omarchy are written down a second time in
`deck_monitors.py`, and a second copy nothing compares is how a test stays green
after the product it describes has moved.

Six traps, and the first three have each cost this project a wrong answer:

1. 🔴 **A rotation value written 180° out.** Three have been recorded
   confidently in this repo and found inverted — the desktop's `transform 1`
   (session 15), Limine's `interface_rotation: 270`, and a shipped patch
   corrected from `270` to `90` on 2026-08-12. So `3` and `1.25` are asserted as
   *values*, against the two documents that recorded them being looked at, and
   not merely "whatever the module says".

2. 🔴 **`/etc/skel` read instead of the created user's home.** `useradd` ran in
   phase 3 of 14. A check that reads only skel is the canonical
   passes-for-the-wrong-reason failure for this task, so §7 drives a target
   where skel is written and the user's copy is *not*, and requires it to fail.

3. 🔴 **A readback that reads a COMMENT.** Omarchy's shipped `monitors.lua`
   contains a commented-out `hl.monitor({ output = "DP-2", …, transform = 1 })`
   example. A verification that grepped raw text would be reading upstream's
   example — an inverted value, in a comment — rather than the compositor's
   input. §3 drives the stripper against that exact line and against strings
   that merely look like comments.

4. 🔴 **A sibling clobbered.** `input.lua` sits in the same directory and
   carries §5.3's OSK XKB block and §5.6's `above_lock = 2` layer rule, which is
   what makes a lock screen answerable on a handheld with no keyboard. §8
   asserts every other file in that directory is byte-identical across the write.

5. 🔴 **A Lua syntax error a naive check would miss.** Hyprland discards the
   WHOLE file, silently, with `hyprctl configerrors` still clean. `# a comment`
   in a Lua file is bracket-balanced, looks fine, and is a syntax error — so §9
   feeds exactly that to the step and requires a refusal, using a real `luac`.

6. 🔴 **A sentinel that is not last.** Lua runs top to bottom: an assignment
   that is not the final statement proves only that the file parsed as far as
   itself. §10 asserts the position, not just the presence.
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
import subprocess
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
# The authority on the two measured values.
PROGRESS = REPO_ROOT / "docs/PROGRESS.md"
SWEEP = REPO_ROOT / "docs/findings/P22-deck-conformance-sweep.md"
# The authority on what Omarchy 4.0 actually ships into a home: a semantic
# manifest of a REAL fresh 4.0 install, file texts and package versions included.
MANIFEST = REPO_ROOT / "iso/upstream/manifests/fresh-4-semantic.json"
# The greeter's copy of the same two values.
DECK_SESSION = REPO_ROOT / "src/deck-session.sh"

FAILURES = 0
CHECKS = 0
NOTES = 0


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


def check_raises(what: str, fn, exc_types, contains: str | None = None) -> None:
    """Requires the raise AND, when asked, the reason.

    The message is part of the contract here: several of these refusals exist to
    tell a human on a Deck at 3am what went wrong, and a refusal that raises the
    right type with the wrong explanation has lost most of its value.
    """
    global FAILURES, CHECKS
    CHECKS += 1
    try:
        fn()
    except exc_types as exc:
        if contains is not None and contains not in str(exc):
            print(f"FAIL {what}: raised, but the message lacks {contains!r}: {exc}")
            FAILURES += 1
            return
        print(f"ok   {what}")
        return
    except Exception as exc:  # noqa: BLE001
        print(f"FAIL {what}: raised {type(exc).__name__}: {exc}, wanted {exc_types}")
        FAILURES += 1
        return
    print(f"FAIL {what}: did not raise")
    FAILURES += 1


def note(what: str) -> None:
    global NOTES
    NOTES += 1
    print(f"NOTE {what}")


def scrape(path: pathlib.Path, pattern: str, what: str) -> str:
    """Pull one fact out of a file, and FAIL LOUDLY when the scrape finds nothing.

    ⚠️ The single most important function here, for
    `test-duplicated-upstream-facts.sh`'s reason: a renamed helper or a reflowed
    line makes a scrape return nothing, and comparing two empty strings passes.
    "Found nothing" reading as "found no problems" is the bug class these
    assertions exist to close.
    """
    global FAILURES, CHECKS
    CHECKS += 1
    text = path.read_text()
    match = re.search(pattern, text, re.M)
    if not match:
        print(f"FAIL scrape {what}: {pattern!r} matched nothing in {path.name}")
        FAILURES += 1
        return ""
    print(f"ok   scrape {what}")
    return match.group(1) if match.groups() else match.group(0)


# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------

WORK = pathlib.Path(tempfile.mkdtemp(prefix="deck-monitors-test-"))

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

from orchestrator import deck_configure, deck_monitors as dm  # noqa: E402
from orchestrator.context import InstallContext  # noqa: E402

print(f"# modules loaded from {PKG_ROOT}")

# ---------------------------------------------------------------------------
# The Lua compiler.
#
# ⚠️ Present on the dev machine and on the TARGET (`lua` is in the fresh-4.0
# package manifest, asserted in §1). NOT guaranteed on a CI runner, so its
# absence is a loud NOTE and a reduced check count rather than a silent skip --
# `test-deck-session-stages.sh` handles the same dependency the same way.
# ---------------------------------------------------------------------------
LUAC_BIN = shutil.which("luac") or shutil.which("luac5.4") or shutil.which("luac5.3")


def luac_runner(target, argv):
    """Substituted for `run_in_target`: the DEV MACHINE's luac, target-relative path.

    This is the seam's whole point. `deck_monitors.run_in_target` shells out to
    `arch-chroot`, which needs root and a real target; the module looks the
    runner up on the module object at call time precisely so a suite can put a
    real Lua parser behind it without one.
    """
    assert argv[0] == dm.LUAC and argv[1] == "-p", argv
    path = pathlib.Path(target) / argv[2].lstrip("/")
    proc = subprocess.run(  # noqa: S603
        [LUAC_BIN, "-p", str(path)], capture_output=True, text=True, check=False
    )
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


def absent_luac_runner(target, argv):
    """What `run_in_target` returns when the binary is not in the target."""
    return 127, "FileNotFoundError: [Errno 2] No such file or directory: 'arch-chroot'"


def accepting_runner(target, argv):
    """A compiler that says yes to everything. Used only where the Lua is not
    what is under test, so a missing luac cannot make an unrelated case skip."""
    return 0, ""


TEST_UID = os.getuid()
TEST_GID = os.getgid()

# 🔴 Omarchy 4.0's shipped ~/.config/hypr/monitors.lua, VERBATIM from the
# fresh-4.0 install manifest (asserted byte-for-byte against it in §1). Every
# feature that matters is in it: the two `local`s, the GDK_SCALE call, the
# catch-all `output = ""` rule, and -- the trap -- a COMMENTED-OUT rule carrying
# `transform = 1`, the very value this project once shipped upside down.
SHIPPED = '''\
-- See https://wiki.hypr.land/Configuring/Basics/Monitors/
-- List current monitors and resolutions possible: hyprctl monitors all

local omarchy_gdk_scale = 2
local omarchy_monitor_scale = "auto"

hl.env("GDK_SCALE", tostring(omarchy_gdk_scale))
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = omarchy_monitor_scale })

-- Portrait/rotated secondary monitor (transform: 1 = 90°, 3 = 270°)
-- hl.monitor({ output = "DP-2", mode = "preferred", position = "auto", scale = 1, transform = 1 })
'''

# What src/deck-session.sh splices into input.lua, in the same directory. Only
# its shape matters here: it must come back byte-identical.
INPUT_LUA = '''\
-- Control your input devices.
hl.config({ input = { kb_layout = "us" } })

-- >>> deck-session.sh: on-screen keyboard XKB layout >>>
hl.device({ name = "deck-input-mapper-virtual-keyboard", kb_layout = "us" })
DECK_OSK_KB_LAYOUT = "us"
-- <<< deck-session.sh: on-screen keyboard XKB layout <<<

hl.layer_rule({ match = { namespace = "deck-osk" }, above_lock = 2 })
DECK_INPUT_LUA_LOADED = true
'''


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
    home: str = "/home/deck",
    uid: int = 1000,
    seed: str | None = SHIPPED,
    skel: str | None = SHIPPED,
    user_file: str | None = SHIPPED,
    input_lua: str | None = INPUT_LUA,
    passwd: str | None = None,
) -> pathlib.Path:
    """A target with an Omarchy home on it, in whatever state the case needs."""
    target = tmpdir(name) / "mnt"
    (target / "etc").mkdir(parents=True, exist_ok=True)
    if passwd is None:
        passwd = (
            "root:x:0:0::/root:/bin/bash\n"
            f"{username}:x:{uid}:{uid}::{home}:/bin/bash\n"
        )
    (target / "etc/passwd").write_text(passwd)

    if seed is not None:
        path = target / dm.MONITORS_LUA_DEFAULTS_REL
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(seed)
    if skel is not None:
        path = target / dm.MONITORS_LUA_SKEL_REL
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(skel)
    if user_file is not None:
        path = target / home.lstrip("/") / dm.MONITORS_LUA_REL
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(user_file)
    if input_lua is not None:
        path = target / home.lstrip("/") / dm.HYPR_DIR_REL / "input.lua"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(input_lua)
    return target


def quiet(fn, *args, **kwargs):
    """Run something that prints through `ui`, and hand back (result, output)."""
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        result = fn(*args, **kwargs)
    return result, buf.getvalue()


def user_lua(target, home="/home/deck") -> pathlib.Path:
    return target / home.lstrip("/") / dm.MONITORS_LUA_REL


# ---------------------------------------------------------------------------

print("\n## 1. the measured values, and the four upstream facts written down twice")

# --- the two values, against the two documents that recorded them being seen ---

progress_transform = scrape(
    PROGRESS,
    r"\|\s*Desktop\s*\|[^|]*monitors\.lua`?\s*\|\s*\*\*(\d)\*\*\s*\|",
    "the desktop transform in PROGRESS.md 5.11's table",
)
check(
    "🔴 deck_monitors' transform is the one PROGRESS.md 5.11 recorded being LOOKED AT "
    "(1 rendered it upside down)",
    str(dm.PANEL_TRANSFORM),
    progress_transform,
)
sweep_transform = scrape(
    SWEEP,
    r"\|\s*4\s*\|\s*Desktop\s*\|\s*\*\*`transform = (\d)`\*\*",
    "the desktop transform in the P22 sweep's on-disk table",
)
check(
    "…and the same value the P22 sweep read off the Deck's own monitors.lua",
    str(dm.PANEL_TRANSFORM),
    sweep_transform,
)
sweep_scale = scrape(
    SWEEP,
    r"carry `scale = ([0-9.]+)` on `eDP-1`",
    "the panel scale in the P22 sweep",
)
check(
    "🔴 …and the scale is 1.25, not Omarchy's 'auto' (which resolves to 2 and "
    "leaves a 640x400 desktop)",
    str(dm.PANEL_SCALE),
    sweep_scale,
)
check(
    "…and 1.25 is what PROGRESS.md 5.11 recorded replacing 'auto' with",
    str(dm.PANEL_SCALE),
    scrape(PROGRESS, r"Now \*\*([0-9.]+)\*\* \(1024×640", "the scale in PROGRESS.md 5.11"),
)
check("…on the output the sweep names", dm.PANEL_OUTPUT, "eDP-1")

# 🔴 The disagreement with Limine, asserted rather than described. Two of these
# four values have been "corrected" into agreement and were wrong afterwards.
from orchestrator import deck_rotation as dr  # noqa: E402

check(
    "🔴 the desktop's transform and Limine's interface_rotation DISAGREE, on "
    "purpose — opposite sign conventions, one panel; a suite that required them "
    "to match would demand the bug this project has already shipped twice",
    (dm.PANEL_TRANSFORM, dr.INTERFACE_ROTATION),
    (3, 90),
)

# --- the greeter, which is the same panel through a different writer ----------

check(
    "the SDDM greeter in src/deck-session.sh carries the SAME transform "
    "(one panel, two compositor surfaces, one convention)",
    str(dm.PANEL_TRANSFORM),
    scrape(DECK_SESSION, r"^readonly PANEL_TRANSFORM=(\d)$", "the greeter transform"),
)
check(
    "…and the same scale",
    str(dm.PANEL_SCALE),
    scrape(DECK_SESSION, r"^readonly PANEL_SCALE=([0-9.]+)$", "the greeter scale"),
)
check(
    "…and the same output",
    dm.PANEL_OUTPUT,
    scrape(DECK_SESSION, r"^readonly PANEL_OUTPUT=(\S+)$", "the greeter output"),
)

# --- 🔴 the markers and the sentinel must not collide with the neighbours -----

osk_begin = scrape(
    DECK_SESSION, r'^readonly OSK_KB_RULE_BEGIN="(.*)"$', "deck-session.sh's OSK marker"
)
osk_sentinel = scrape(
    DECK_SESSION, r"^readonly OSK_KB_SENTINEL=(\S+)$", "deck-session.sh's OSK sentinel"
)
check_true(
    "🔴 our markers are NOT deck-session.sh's — several marker-delimited writers "
    "now edit one user's ~/.config/hypr, and a shared marker is how each one "
    "comes to eat the other",
    dm.BEGIN != osk_begin and dm.END != osk_begin,
)
check_true(
    "🔴 …and our parse sentinel is its own name: one file's sentinel must never "
    "vouch for another file that was discarded",
    dm.SENTINEL not in (osk_sentinel, "DECK_INPUT_LUA_LOADED"),
)
from orchestrator import deck_menu_lock as dml  # noqa: E402

check_true(
    "…nor deck_menu_lock's markers",
    dm.BEGIN not in (dml.MENU_BEGIN, dml.MENU_END),
)

# --- 🔴 the four facts about Omarchy, out of a REAL fresh 4.0 install ---------

manifest = json.loads(MANIFEST.read_text())
user_config = manifest["files"]["user_config"]
shipped_monitors = user_config["~/" + dm.MONITORS_LUA_REL]["text"]
shipped_hyprland = user_config["~/.config/hypr/hyprland.lua"]["text"]

check(
    "🔴 the fixture below is Omarchy 4.0's shipped monitors.lua, byte for byte "
    "— a fixture that has drifted from the product tests nothing",
    SHIPPED,
    shipped_monitors,
)
check_true(
    "🔴 FACT 1: hyprland.lua puts $HOME/.config FIRST on package.path, so a user "
    "monitors.lua REPLACES the shipped default wholesale — require returns the "
    "first match and nothing merges",
    re.search(
        r'package\.path\s*=\s*os\.getenv\("HOME"\)\s*\.\.\s*"/\.config/\?\.lua;"',
        shipped_hyprland,
    ),
)
check_true(
    "…FACT 2: and it is required as a module, not read as data",
    'require("hypr.monitors")' in shipped_hyprland,
)
check_true(
    "…FACT 3: Omarchy's own copy lives under config/, which is NOT on that "
    "package.path — it is a SEED, copied into the home, never loaded from there",
    dm.MONITORS_LUA_DEFAULTS_REL == "usr/share/omarchy/config/hypr/monitors.lua"
    and "/config/?.lua" not in shipped_hyprland.replace('"/.config/?.lua;"', ""),
)
check_true(
    "🔴 …FACT 4: the shipped file carries a COMMENTED-OUT rule with transform = 1 "
    "in it. Any readback that does not strip comments is reading upstream's "
    "example — an inverted value Hyprland never executes",
    re.search(r"^--\s*hl\.monitor\(\{ output = \"DP-2\".*transform = 1", SHIPPED, re.M),
)
check_true(
    "…and the catch-all rule this step deliberately leaves alone, so an external "
    "display keeps Omarchy's behaviour",
    'hl.monitor({ output = "", mode = "preferred"' in SHIPPED,
)
check_true(
    "🔴 'lua' is one of the packages a fresh Omarchy 4.0 install has, which is "
    "why 'luac -p' in the target is a gate and not a hope",
    "lua" in manifest["packages"]["versions"],
)


print("\n## 2. the Lua comment stripper — the readback's foundation")

check(
    "a line comment is blanked, and the line survives",
    dm.strip_lua_comments("a = 1 -- two\nb = 2").splitlines()[1],
    "b = 2",
)
check_true(
    "🔴 the shipped file's commented-out rule is GONE after stripping",
    "DP-2" not in dm.strip_lua_comments(SHIPPED),
)
check_true(
    "…while its ACTIVE catch-all rule survives",
    'output = ""' in dm.strip_lua_comments(SHIPPED),
)
check_true(
    "a long comment --[[ … ]] is blanked",
    "hidden" not in dm.strip_lua_comments("x = 1\n--[[ hidden\nstill hidden ]]\ny = 2"),
)
check_true(
    "…and a levelled one --[==[ … ]==]",
    "hidden" not in dm.strip_lua_comments("--[==[ hidden ]] still ]==]\ny = 2"),
)
check_true(
    "🔴 '--' INSIDE a string is not a comment: the string survives",
    '"-- not a comment"' in dm.strip_lua_comments('s = "-- not a comment"\n'),
)
check_true(
    "…and inside a long-bracket string",
    "-- also not" in dm.strip_lua_comments("s = [[ -- also not a comment ]]\n"),
)
check(
    "line geometry is preserved, so a 'which line' answer stays true",
    len(dm.strip_lua_comments(SHIPPED).splitlines()),
    len(SHIPPED.splitlines()),
)


print("\n## 3. reading hl.monitor rules back, and finding the last statement")

rules = dm.monitor_rules(SHIPPED)
check("the shipped file has exactly ONE active monitor rule", len(rules), 1)
check("…the catch-all", rules[0]["output"], "")
check(
    "🔴 …and its scale is reported as the IDENTIFIER it is, not as the string "
    "'auto' — resolving it here would be inventing a fact",
    rules[0]["scale"],
    "omarchy_monitor_scale",
)
check(
    "our own rendered rule parses back to the three values that matter",
    {k: dm.monitor_rules(dm.render_rule())[0][k] for k in ("output", "scale", "transform")},
    {"output": "eDP-1", "scale": "1.25", "transform": "3"},
)
check(
    "last_statement ignores trailing comments",
    dm.last_statement("x = 1\nDECK = true\n-- trailing\n\n"),
    "DECK = true",
)
check("…and an empty file has none", dm.last_statement("-- only a comment\n"), "")


print("\n## 4. the block that gets written")

block = "\n".join(dm.render_block())
check("it opens and closes with our own markers", (dm.BEGIN in block, dm.END in block), (True, True))
check("the rule it carries is the measured one", dm.render_rule() in block, True)
check_true("…and it says WHY 3 and not 1, in the file, for a reader with no repo", "UPSIDE DOWN" in block)
check_true("…and why 3 disagrees with Limine's 90", "OPPOSITE sign conventions" in block)
check_true("…and why not 'auto'", "640x400" in block)
check_true("the GDK_SCALE companion is there", f'hl.env("GDK_SCALE", "{dm.PANEL_GDK_SCALE}")' in block)
check_true("…flagged INFERRED rather than claimed", "INFERRED" in block)
check(
    "🔴 the sentinel is the LAST statement of the block",
    dm.last_statement(block),
    f"{dm.SENTINEL} = true",
)
check_true(
    "🔴 the probe written into the file is the ASSERTION form — eval reports its "
    "own status and never a value, so a readback passes either way",
    f"if {dm.SENTINEL} == nil" in block and "error(" in block,
)
check_true(
    "🔴 …and the broken readback form appears nowhere in it "
    "(test-hyprctl-syntax.sh scanner 3 fails the build on it)",
    not re.search(r"eval\s+['\"]\s*return\b", block),
)
if LUAC_BIN:
    staged = WORK / "block-only.lua"
    staged.write_text(block + "\n")
    check(
        "🔴 the block on its own is valid Lua (luac -p) — Hyprland discards a "
        "file it cannot parse WITHOUT logging a reason",
        subprocess.run(  # noqa: S603
            [LUAC_BIN, "-p", str(staged)], capture_output=True, check=False
        ).returncode,
        0,
    )
else:
    note("luac is not installed; the 'the block is valid Lua' assertion did not run")


print("\n## 5. the splice — everything outside our markers is preserved")

spliced, replaced = dm.splice(SHIPPED, dm.render_block())
check("a first run replaces nothing", replaced, False)
check_true("the shipped content is still there", 'hl.env("GDK_SCALE", tostring(' in spliced)
check(
    "🔴 …byte for byte outside our markers",
    dm.outside_our_block(spliced),
    dm.outside_our_block(SHIPPED),
)
again, replaced = dm.splice(spliced, dm.render_block())
check("🔴 a re-run REPLACES our block rather than appending a second copy", replaced, True)
check("…and is byte-identical: the step is idempotent", again, spliced)
check("…still exactly one of our blocks", again.count(dm.BEGIN), 1)

# A user who added their own rule after ours: our block moves back to the end so
# the sentinel stays last, and their rule survives.
theirs = spliced + '\nhl.monitor({ output = "DP-1", mode = "preferred", position = "auto" })\n'
moved, _ = dm.splice(theirs, dm.render_block())
check_true(
    "a user's own rule added after our block survives a re-run",
    'output = "DP-1"' in moved,
)
check(
    "🔴 …and our sentinel is moved back to LAST, because Lua runs top to bottom",
    dm.last_statement(moved),
    f"{dm.SENTINEL} = true",
)
# 🔴 ANOTHER writer's marker block, in the same file. Nothing splices into
# monitors.lua today except this step -- but three marker-delimited writers
# already operate on this user's dotfiles and one of them, `stage_menu_row`,
# shares a file with `deck_menu_lock`. The rule that makes that safe is that each
# writer touches only its own markers, and it is asserted here rather than
# assumed.
FOREIGN = (
    "-- >>> some-other-tool: a block that is not ours >>>\n"
    'hl.monitor({ output = "HDMI-A-1", mode = "preferred", position = "auto" })\n'
    "SOME_OTHER_SENTINEL = true\n"
    "-- <<< some-other-tool: a block that is not ours <<<\n"
)
with_foreign, _ = dm.splice(SHIPPED + FOREIGN, dm.render_block())
check_true(
    "🔴 a DIFFERENT writer's marker-delimited block in the same file survives ours "
    "whole — markers are per-writer, and a shared one is how each eats the other",
    FOREIGN.strip() in with_foreign,
)
rerun, _ = dm.splice(with_foreign, dm.render_block())
check_true("…and survives a re-run of ours", FOREIGN.strip() in rerun)
check("…which is still idempotent", rerun, with_foreign)

# 🔴 The preservation guard, exercised DIRECTLY with two strings. As an inline
# `if` inside `install` it could only be reached by first breaking `splice` --
# so the writer and the check would have had to fail together to go red, which
# is exactly the pair of bugs a preservation assertion exists to catch. A
# mutation run proved the inline form survived being deleted; this is the
# assertion that killed it.
check_raises(
    "🔴 the outside-our-markers guard REFUSES a write that dropped somebody "
    "else's content, and is assertable without a target",
    lambda: dm.assert_outside_preserved(SHIPPED, "\n".join(dm.render_block()), "/x/monitors.lua"),
    dm.DeckMonitorsError,
    contains="REPLACES the shipped default wholesale",
)
check(
    "CONTROL: …and accepts the splice the module actually performs, so it is not "
    "a guard that refuses everything",
    dm.assert_outside_preserved(SHIPPED, spliced, "/x/monitors.lua"),
    None,
)

check_raises(
    "🔴 a start marker with no end marker is REFUSED, not guessed at",
    lambda: dm.splice(SHIPPED + "\n" + dm.BEGIN + "\nstuff\n", dm.render_block()),
    dm.DeckMonitorsError,
    contains="no end marker",
)


print("\n## 6. the write: both surfaces, and the created user's is the one verified")

target = make_target("both")
record, out = quiet(dm.configure_desktop_rotation, make_ctx(target), runner=luac_runner if LUAC_BIN else accepting_runner)
check("the step reports configured", record["status"], "configured")
check("…for the account /etc/passwd actually carries", record["user"], "deck")
check("…at the home /etc/passwd carries, never a composed /home/<name>", record["user_path"], "/home/deck/.config/hypr/monitors.lua")
check("…and skel too", record["skel"], "/etc/skel/.config/hypr/monitors.lua")
check("…recording the transform it wrote", record["transform"], 3)
check("…and the scale", record["scale"], 1.25)
check("…and which sentinel to assert against on a live compositor", record["sentinel"], "DECK_MONITORS_LUA_LOADED")
# True either way: with luac it is a real parse, without it the accepting runner
# stands in. The case that matters -- a compiler that is NOT there -- is §9's,
# where this field must come back False rather than being quietly omitted.
check("…and that a compiler answered for the Lua", record["syntax_checked"], True)
check("…and no error", record["error"], None)

skel_path = target / dm.MONITORS_LUA_SKEL_REL
check("🔴 the created user's file exists", user_lua(target).is_file(), True)
check("…and skel's, for any account made later", skel_path.is_file(), True)
check("…both 0644", (mode_of(user_lua(target)), mode_of(skel_path)), ("0644", "0644"))
check("…owned by the created user", os.stat(user_lua(target)).st_uid, TEST_UID)
proof = dm.verify(user_lua(target), "the user's")
check("the user's file reads back transform 3", proof["transform"], "3")
check("…scale 1.25", proof["scale"], "1.25")
check(
    "🔴 …and Omarchy's catch-all rule is STILL THERE beside ours: a monitors.lua "
    "replaces the default wholesale, so dropping it would strip external-display "
    "handling and GDK_SCALE with it",
    proof["monitor_rules"],
    2,
)
check_true(
    "…including the GDK_SCALE line upstream shipped",
    'hl.env("GDK_SCALE", tostring(omarchy_gdk_scale))' in user_lua(target).read_text(),
)
check_true("the console says what it did", "Deck desktop rotation" in out and "transform=3" in out)
check_true(
    "…and repeats the disagreement with Limine there too, where a human reads it",
    "OPPOSITE sign conventions" in out or "opposite sign conventions" in out.lower(),
)

# Re-run: idempotent on a real target, not just as a string transform.
first = user_lua(target).read_bytes()
record2, _ = quiet(dm.configure_desktop_rotation, make_ctx(target), runner=accepting_runner)
check("🔴 a re-run is clean", record2["status"], "configured")
check("…and reports that it replaced its own block", record2["replaced_existing_block"], True)
check("…leaving the file byte-identical", user_lua(target).read_bytes(), first)


# 🔴 …and that `install` ACTUALLY CONSULTS it. The guard above can be perfect
# and unreachable: with a correct `splice` nothing outside the markers is ever
# dropped, so no end-to-end case can distinguish a called guard from a deleted
# one. Mutation proved exactly that — removing the call from `install` survived
# every other assertion in this file. So the call itself is asserted, at the
# seam, which is the only place the difference is visible.
calls: list[tuple[str, str, str]] = []
original_guard = dm.assert_outside_preserved
dm.assert_outside_preserved = lambda before, after, label: calls.append((before, after, label))
try:
    target = make_target("guard-called")
    dm.install(target, "home/deck/" + dm.MONITORS_LUA_REL, runner=accepting_runner)
finally:
    dm.assert_outside_preserved = original_guard
check("🔴 install() consults the preservation guard exactly once per file", len(calls), 1)
check(
    "…handing it the file as it was and the text about to replace it, not two "
    "copies of the same string",
    (calls[0][0] == SHIPPED, calls[0][1] != SHIPPED, calls[0][2]),
    (True, True, "/home/deck/.config/hypr/monitors.lua"),
)


print("\n## 7. 🔴 /etc/skel is TOO LATE for the account this image already created")

# The canonical passes-for-the-wrong-reason failure: skel written, the user's not.
target = make_target("skel-only-trap")
dm.install(target, dm.MONITORS_LUA_SKEL_REL, runner=accepting_runner)
check_true("skel is written…", (target / dm.MONITORS_LUA_SKEL_REL).read_text().count(dm.BEGIN) == 1)
(user_lua(target)).unlink()
check_raises(
    "🔴 …and verifying the CREATED USER's copy still fails, because useradd ran "
    "in phase 3 of 14 and skel is copied at account creation",
    lambda: dm.verify(user_lua(target), "deck's"),
    dm.DeckMonitorsError,
    contains="TOO LATE",
)

# The deferred install, where skel alone is exactly right.
target = make_target("deferred", user_file=None, input_lua=None)
record, out = quiet(dm.configure_desktop_rotation, make_ctx(target, defer=True), runner=accepting_runner)
check("a defer_provisioning install is 'skel-only', a DISTINCT status", record["status"], "skel-only")
check("…and does not claim a user path", record["user_path"], None)
check_true("…and says why, rather than looking like a failure", any("defer" in w for w in record["warnings"]))
check_true("skel was still written", (target / dm.MONITORS_LUA_SKEL_REL).is_file())

# An account the installer names but /etc/passwd does not carry.
target = make_target("ghost", passwd="root:x:0:0::/root:/bin/bash\n")
record, _ = quiet(dm.configure_desktop_rotation, make_ctx(target), runner=accepting_runner)
check("an account that was never created is a failure, not a guess", record["status"], "failed")
check_true("…named as such", "no such user" in (record["error"] or ""))

# A home that is not /home/<name>. deck_user reads it from /etc/passwd.
target = make_target("odd-home", home="/srv/decks/deck")
record, _ = quiet(dm.configure_desktop_rotation, make_ctx(target), runner=accepting_runner)
check(
    "🔴 the home comes from /etc/passwd, never composed — useradd honours -d",
    record["user_path"],
    "/srv/decks/deck/.config/hypr/monitors.lua",
)
check_true("…and the file is there", (target / "srv/decks/deck" / dm.MONITORS_LUA_REL).is_file())


print("\n## 8. 🔴 the siblings in ~/.config/hypr are not this step's to touch")

target = make_target("siblings")
before = (target / "home/deck" / dm.HYPR_DIR_REL / "input.lua").read_bytes()
record, _ = quiet(dm.configure_desktop_rotation, make_ctx(target), runner=accepting_runner)
after = (target / "home/deck" / dm.HYPR_DIR_REL / "input.lua").read_bytes()
check(
    "🔴 input.lua is byte-identical across the write. It carries 5.3's OSK XKB "
    "block and 5.6's above_lock = 2 rule, and losing above_lock makes a lock "
    "screen unanswerable on a handheld with no keyboard",
    after,
    before,
)
check_true("…and it still has the above_lock rule in it", b"above_lock = 2" in after)
check_true("…and the OSK block's own sentinel", b"DECK_OSK_KB_LAYOUT" in after)

# The guard itself, exercised directly — a guard that can only be reached by
# first breaking the writer is a guard nothing tests (deck_rotation's reason).
check_raises(
    "🔴 the sibling guard REFUSES a changed neighbour rather than reporting it",
    lambda: dm.assert_siblings_preserved(
        {"input.lua": b"a"}, {"input.lua": b"b"}, "/home/deck/.config/hypr/monitors.lua"
    ),
    dm.DeckMonitorsError,
    contains="above_lock",
)
check(
    "…and the snapshot it compares does not include the file we are writing",
    sorted(dm.snapshot_siblings(target, "home/deck/" + dm.MONITORS_LUA_REL)),
    ["input.lua"],
)


print("\n## 9. 🔴 the Lua syntax gate — the error a naive check cannot see")

check(
    "the syntax check runs INSIDE the target, against the target's own compiler",
    dm.chroot_command("/mnt", [dm.LUAC, "-p", "/x.lua"]),
    ["arch-chroot", "/mnt", "luac", "-p", "/x.lua"],
)

if LUAC_BIN:
    # 🔴 `#` opens no comment in Lua. The file is bracket-balanced, the quotes
    # match, and every naive structural check passes. Only a Lua parser refuses
    # it — and Hyprland's refusal is to discard the WHOLE file in silence.
    target = make_target("hash-comment", user_file=SHIPPED + "\n# this is not a Lua comment\n")
    record, out = quiet(dm.configure_desktop_rotation, make_ctx(target), runner=luac_runner)
    check(
        "🔴 a '#' comment in the pre-existing file is REFUSED, not installed",
        record["status"],
        "failed",
    )
    check_true("…and the reason names Lua", "not valid Lua" in (record["error"] or ""))
    check_true(
        "…and says the failure would have been SILENT",
        "WITHOUT logging" in (record["error"] or ""),
    )
    check_true(
        "🔴 …and the user's file is left as it was: the staged file never became "
        "the file Hyprland reads",
        dm.BEGIN not in user_lua(target).read_text(),
    )
    # The control that keeps the one above honest: the same fixture WITHOUT the
    # bad line must pass, so "refused" is attributable to the '#'.
    target = make_target("hash-control", user_file=SHIPPED + "\n-- this IS a Lua comment\n")
    record, _ = quiet(dm.configure_desktop_rotation, make_ctx(target), runner=luac_runner)
    check("CONTROL: the same file with a REAL Lua comment is accepted", record["status"], "configured")

    target = make_target("unterminated", user_file='s = "unterminated\n' + SHIPPED)
    record, _ = quiet(dm.configure_desktop_rotation, make_ctx(target), runner=luac_runner)
    check("an unterminated string is refused too", record["status"], "failed")
else:
    note("luac is not installed; the four Lua-syntax-gate assertions did not run")

# A target with no compiler: a loud warning, and the rotation still lands. The
# alternative — refusing to rotate a desktop because a compiler is missing —
# trades a working machine for a tidy check.
target = make_target("no-luac")
record, out = quiet(dm.configure_desktop_rotation, make_ctx(target), runner=absent_luac_runner)
check("no luac in the target is not a refusal", record["status"], "configured")
check("…but it is recorded as unchecked, never as checked", record["syntax_checked"], False)
check_true(
    "…and said out loud: 'NOT syntax-checked' rather than silence implying a pass",
    any("NOT syntax-checked" in w for w in record["warnings"]),
)


print("\n## 10. the readback's own refusals — each one is a mutation's landing site")

good = user_lua(make_target("readback"))
good.parent.mkdir(parents=True, exist_ok=True)
good.write_text(dm.splice(SHIPPED, dm.render_block())[0])
check("the good file verifies", dm.verify(good, "good")["transform"], "3")


def written(name: str, text: str) -> pathlib.Path:
    path = tmpdir(name) / "monitors.lua"
    path.write_text(text)
    return path


upside_down = dm.splice(SHIPPED, dm.render_block())[0].replace(
    "transform = 3 })", "transform = 1 })"
)
check_raises(
    "🔴 transform = 1 is REFUSED — it renders the desktop upside down, and it is "
    "the value this project recorded confidently and had to correct",
    lambda: dm.verify(written("upside-down", upside_down), "mutant"),
    dm.DeckMonitorsError,
    contains="UPSIDE DOWN",
)
auto = dm.splice(SHIPPED, dm.render_block())[0].replace("scale = 1.25,", 'scale = "auto",')
check_raises(
    "🔴 scale = \"auto\" is REFUSED — it resolves to 2 and leaves a 640x400 desktop",
    lambda: dm.verify(written("auto", auto), "mutant"),
    dm.DeckMonitorsError,
    contains="640x400",
)
check_raises(
    "🔴 a file whose ONLY eDP-1 rule is inside a comment is refused, and the "
    "message says so — this is what a naive grep would have passed",
    lambda: dm.verify(
        written("commented", SHIPPED + f'\n-- {dm.render_rule()}\n{dm.SENTINEL} = true\n'),
        "mutant",
    ),
    dm.DeckMonitorsError,
    contains="inside a comment",
)
check_raises(
    "two active rules for the same output are refused rather than reasoned about",
    lambda: dm.verify(
        written("double", dm.splice(SHIPPED, dm.render_block())[0] + f"\n{dm.render_rule()}\n"),
        "mutant",
    ),
    dm.DeckMonitorsError,
    contains="2 active hl.monitor rules",
)
not_last = dm.splice(SHIPPED, dm.render_block())[0] + '\nhl.monitor({ output = "DP-1" })\n'
check_raises(
    "🔴 a sentinel that is not the LAST statement is refused: Lua runs top to "
    "bottom, so it would prove only that the file parsed as far as itself",
    lambda: dm.verify(written("not-last", not_last), "mutant"),
    dm.DeckMonitorsError,
    contains="last statement",
)
check_raises(
    "a missing file is refused with the skel explanation attached",
    lambda: dm.verify(tmpdir("absent") / "nope.lua", "mutant"),
    dm.DeckMonitorsError,
    contains="TOO LATE",
)


print("\n## 11. seeding, symlinks, and the case where nothing is on the target")

# An absent user file with the packaged seed present: seeded, not synthesised.
target = make_target("seeded", user_file=None)
record, _ = quiet(dm.configure_desktop_rotation, make_ctx(target), runner=accepting_runner)
check("an absent monitors.lua is SEEDED from the packaged default", record["seeded_from"], "defaults")
check_true(
    "🔴 …so the GDK_SCALE call and the catch-all rule are carried over rather "
    "than silently dropped",
    'hl.monitor({ output = "", ' in user_lua(target).read_text(),
)

# Nothing at all: a block-only file, loudly. `require` ERRORS on a missing
# monitors.lua and takes the whole Hyprland config with it, so no file is worse.
target = make_target("bare", seed=None, skel=None, user_file=None, input_lua=None)
record, _ = quiet(dm.configure_desktop_rotation, make_ctx(target), runner=accepting_runner)
check("with no seed anywhere the rotation is still written", record["status"], "configured")
check("…and the record says the file is only our block", record["seeded_from"], "empty")
check_true(
    "…and the warning explains the trade rather than hiding it",
    any("require('hypr.monitors') ERRORS" in w for w in record["warnings"]),
)

# A symlink in the way. Writing through it would write somebody else's file.
target = make_target("symlink", user_file=None)
link = user_lua(target)
link.parent.mkdir(parents=True, exist_ok=True)
link.symlink_to("/etc/passwd")
record, _ = quiet(dm.configure_desktop_rotation, make_ctx(target), runner=accepting_runner)
check("a symlink is replaced with a regular file, not written through", record["status"], "configured")
check_true("…and reported", any("symlink" in w for w in record["warnings"]))
check("…and the file is now regular", link.is_symlink(), False)
check_true("…and /etc/passwd was not rewritten", "root:x:0:0" in (target / "etc/passwd").read_text())


print("\n## 12. the step entry point, the shared document, and the registry")

target = make_target("steps")
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    deck_configure.record_result(target, "wifi", {"status": "skipped"})
    dm.desktop_rotation_step(make_ctx(target))
log_path = target / deck_configure.DECK_INSTALL_LOG_REL
doc = json.loads(log_path.read_text())
check("the desktop rotation lands under 'desktop_rotation'", doc["desktop_rotation"]["status"], "configured")
check("…without clobbering another step's key", doc["wifi"]["status"], "skipped")
check("…and the log stays 0644", mode_of(log_path), "0644")
check(
    "🔴 its record is DISTINGUISHABLE from the boot-chain rotations' — three "
    "surfaces, three mechanisms, three sets of facts",
    sorted(doc["desktop_rotation"]) != sorted(["status", "rotation", "esp_path"]),
    True,
)
check_true("…and carries the sentinel a live compositor is asserted against", doc["desktop_rotation"]["sentinel"])

target = make_target("steps-fail", passwd="root:x:0:0::/root:/bin/bash\n")
raised = None
buf = io.StringIO()
try:
    with contextlib.redirect_stdout(buf):
        dm.desktop_rotation_step(make_ctx(target))
except Exception as exc:  # noqa: BLE001
    raised = exc
check("🔴 the step does not raise on failure: critical=False, and the record is the report", raised, None)
check(
    "…and the failure is recorded, never silently skipped",
    json.loads((target / deck_configure.DECK_INSTALL_LOG_REL).read_text())["desktop_rotation"]["status"],
    "failed",
)
check_true("…loudly, on the console the install log captures", "Deck desktop rotation" in buf.getvalue())

names = [s.name for s in deck_configure.deck_steps()]
check("the desktop_rotation step is registered", "desktop_rotation" in names, True)
check(
    "…bound to the right entry point",
    [s.fn for s in deck_configure.deck_steps() if s.name == "desktop_rotation"],
    [dm.desktop_rotation_step],
)
check(
    "🔴 …and non-critical: a sideways, wrongly-scaled DESKTOP is a degradation — "
    "the Deck still boots, still autologins and still reaches Gaming Mode, which "
    "gamescope rotates itself and which never reads this file",
    [s.critical for s in deck_configure.deck_steps() if s.name == "desktop_rotation"],
    [False],
)
check(
    "🔴 exactly one step in the whole registry is still critical, and it is not this one",
    [s.name for s in deck_configure.deck_steps() if s.critical],
    ["autologin"],
)
check(
    "…and it runs after the user exists and before the T12 applier",
    names.index("desktop_rotation") < names.index("patches"),
    True,
)
check("every step name is still distinct (they are the install log's keys)", len(set(names)), len(names))


print()
if NOTES:
    print(f"{NOTES} check(s) did not run — see the NOTE lines above")
print(f"{CHECKS - FAILURES}/{CHECKS} checks passed")
if FAILURES:
    print(f"{FAILURES} FAILURES")
shutil.rmtree(WORK, ignore_errors=True)
sys.exit(1 if FAILURES else 0)
