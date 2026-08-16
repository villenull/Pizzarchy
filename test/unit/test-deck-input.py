#!/usr/bin/env python3
"""Unit tests for `configure_deck`'s `lock_wake_dpms` step — §5.25 decision #1's
`above_lock = 2` layer rule, §5.24a requirement #1's two DPMS `misc` lines, and
§5.37 D5's `input.touchdevice` output/transform pair, spliced into the per-user
`~/.config/hypr/input.lua` (`deck_input.py`).

No VM, no root, no network, no chroot, no compositor, no ISO build, and nothing
against the Deck:

    python3 test-deck-input.py

WHAT THIS SUITE IS FOR
=======================

Everything is asserted against a **scratch target filesystem this suite
builds**, by running the step and reading the artefacts back — never by
grepping the module's own source. `deck_monitors.py`'s sibling suite
(`test-deck-monitors.py`) is the direct model; this file follows its shape and
its six traps, adapted to `input.lua`'s own extra hazard — it is a file with
TWO independent writers.

Eight traps:

1. 🔴 **A second writer eating the first one's block.** `input.lua` already
   carries `src/deck-session.sh`'s `OSK_KB_RULE_BEGIN`/`END` block. §5–§7
   build a target where that block is already present and require it byte-
   identical after this step runs, in both directions (ours after theirs,
   theirs after ours, theirs after a RE-RUN of ours).
2. 🔴 **A sibling clobbered.** `monitors.lua` sits in the same directory. §7
   snapshots it and requires it byte-identical across the write.
3. 🔴 **T9's whole-file proposal transcribed by accident.** §2 scrapes the
   REAL upstream `input.lua` out of the pinned fresh-4.0 manifest and requires
   it carry no `misc` table and no `read_vconsole` — the fact this module's
   docstring uses to justify NOT pasting T9 §5.1's fuller block in. If a
   future edit ever adds `kb_layout`/vconsole logic to this module's rendered
   block, §4's exact-byte check against the manifest's real seed content
   would start failing to explain the extra lines, and §9 already asserts our
   rendered block never mentions `kb_layout` at all.
4. 🔴 **A readback that reads a comment**, or an inactive/superseded call. §9
   drives the comment stripper against exactly that shape.
5. 🔴 **A Lua syntax error a naive check would miss.** §11 feeds a real
   `luac` a `# comment`-poisoned file (bracket-balanced, invalid Lua) and
   requires a refusal.
6. 🔴 **A sentinel that is not last.** §9 asserts the position, not just the
   presence.
7. 🔴 **A touchscreen fix that quietly claims LCD support**, or that is
   verified by a fake `hyprctl` too blunt to tell a string option from an
   integer one. §1 requires the rendered block to carry no `name =` device
   field and no `fts3528` outside its prose; §13's `getoption` fake answers
   per option name, in the exact output shape the Deck printed, so the
   `output` check cannot pass on an `int: 0` that was meant for `misc`.
   ⚠️ **Nothing in this file can prove a tap lands where the finger is.** The
   transform's derivation is asserted here; only the operator's finger closes
   §5.37 D5.
8. 🔴 **A live-compositor readback via a bare `return`.** §12 exercises
   `verify_live`'s three outcomes with a fake `hyprctl`, and separately
   `test-hyprctl-syntax.sh` (run by the full suite, not this file) fails the
   build if the broken readback form is written down anywhere in this file or
   in `deck_input.py`.
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

sys.dont_write_bytecode = True

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
OVERLAY_ORCH = (
    REPO_ROOT / "iso/overlay/configs/airootfs/usr/share/omarchy-iso/orchestrator"
)
UPSTREAM_ORCH = (
    REPO_ROOT / "iso/upstream/configs/airootfs/usr/share/omarchy-iso/orchestrator"
)
DECK_SESSION = REPO_ROOT / "src/deck-session.sh"
T5_PLAN = REPO_ROOT / "docs/tasks/T5-fork-plan.md"
T9_FINDING = REPO_ROOT / "docs/findings/T9-lock-wake-and-blank-timing.md"
MANIFEST = REPO_ROOT / "iso/upstream/manifests/fresh-4-semantic.json"

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
    import re

    text = path.read_text()
    m = re.search(pattern, text, re.M)
    if not m:
        note(f"could not scrape {what} out of {path} — skipping the checks that need it")
        return "<<scrape failed>>"
    return m.group(1)


# ---------------------------------------------------------------------------
# Harness — identical package-build shape to test-deck-monitors.py
# ---------------------------------------------------------------------------

WORK = pathlib.Path(tempfile.mkdtemp(prefix="deck-input-test-"))

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

from orchestrator import deck_configure, deck_input as di  # noqa: E402
from orchestrator import deck_menu_lock as dml  # noqa: E402
from orchestrator import deck_monitors as dm  # noqa: E402
from orchestrator.context import InstallContext  # noqa: E402

print(f"# modules loaded from {PKG_ROOT}")

LUAC_BIN = shutil.which("luac") or shutil.which("luac5.4") or shutil.which("luac5.3")


def luac_runner(target, argv):
    """Substituted for `run_in_target`: the DEV MACHINE's luac, target-relative path."""
    assert argv[0] == di.LUAC and argv[1] == "-p", argv
    path = pathlib.Path(target) / argv[2].lstrip("/")
    proc = subprocess.run(  # noqa: S603
        [LUAC_BIN, "-p", str(path)], capture_output=True, text=True, check=False
    )
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


def absent_luac_runner(target, argv):
    return 127, "FileNotFoundError: [Errno 2] No such file or directory: 'arch-chroot'"


def accepting_runner(target, argv):
    """A compiler that says yes to everything, for cases where the Lua itself
    is not under test."""
    return 0, ""


TEST_UID = os.getuid()
TEST_GID = os.getgid()

# Real upstream ~/.config/hypr/input.lua, VERBATIM from the fresh-4.0 install
# manifest — asserted byte-for-byte against it in §2. No misc table, no
# read_vconsole, no non-Latin-layout table: the fact this module's docstring
# leans on to justify NOT pasting T9 §5.1's fuller mirror in.
SHIPPED = '''\
-- Control your input devices.
-- See https://wiki.hypr.land/Configuring/Basics/Variables/#input
hl.config({
  input = {
    -- Use multiple keyboard layouts and switch between them with Left Alt + Right Alt.
    -- kb_layout = "us,dk,eu",

    -- Use a specific keyboard variant if needed (e.g. intl for international keyboards).
    -- kb_variant = "intl",

    kb_layout = "us",
    kb_options = "compose:caps", -- ,grp:alts_toggle

    -- Change speed of keyboard repeat.
    repeat_rate = 40,
    repeat_delay = 250,

    -- Start with numlock on by default.
    numlock_by_default = true,

    -- Increase sensitivity for mouse/trackpad (default: 0).
    -- sensitivity = 0.35,

    -- Turn off mouse acceleration (default: adaptive).
    -- accel_profile = "flat",

    touchpad = {
      -- Use natural (inverse) scrolling.
      -- natural_scroll = true,

      -- Use two-finger clicks for right-click instead of lower-right corner.
      clickfinger_behavior = true,

      -- Control the speed of your scrolling.
      scroll_factor = 0.4,

      -- Enable the touchpad while typing.
      -- disable_while_typing = false,

      -- Left-click-and-drag with three fingers.
      -- drag_3fg = 1,
    },
  },
})

-- Scroll nicely in the terminal.
o.window("(Alacritty|kitty|foot)", { scroll_touchpad = 1.5 })
o.window("com.mitchellh.ghostty", { scroll_touchpad = 0.2 })

-- Enable touchpad gestures for changing workspaces.
-- See https://wiki.hypr.land/Configuring/Advanced-and-Cool/Gestures/
-- hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })

-- Enable touchpad gestures for moving focus (helpful on scrolling layout).
-- hl.gesture({ fingers = 3, direction = "left", action = function() hl.dispatch(hl.dsp.focus({ direction = "l" })) end })
-- hl.gesture({ fingers = 3, direction = "right", action = function() hl.dispatch(hl.dsp.focus({ direction = "r" })) end })
'''

# What src/deck-session.sh's install_osk_kb_layout_rule splices into the SAME
# file. Only its shape matters here: it must come back byte-identical, in
# both directions, and this module must never open the file for anything but
# its own marker pair.
OSK_BLOCK = '''\
-- >>> deck-session.sh: on-screen keyboard XKB layout >>>
hl.device({
  name = "deck-input-mapper-virtual-keyboard",
  kb_layout = "us",
  kb_variant = "",
  kb_model = "",
  kb_rules = "",
})
DECK_OSK_KB_LAYOUT = "us"
-- <<< deck-session.sh: on-screen keyboard XKB layout <<<
'''

# What monitors.lua, the sibling file, looks like — only its byte-identity
# across the write matters here, not its content.
MONITORS_LUA = '''\
-- >>> omarchy-deck: Steam Deck panel rotation and scale >>>
hl.monitor({ output = "eDP-1", mode = "preferred", position = "auto", scale = 1.25, transform = 3 })
DECK_MONITORS_LUA_LOADED = true
-- <<< omarchy-deck: Steam Deck panel rotation and scale <<<
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
    skel: str | None = None,
    user_file: str | None = None,
    monitors_lua: str | None = MONITORS_LUA,
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
        path = target / di.INPUT_LUA_DEFAULTS_REL
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(seed)
    if skel is not None:
        path = target / di.INPUT_LUA_SKEL_REL
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(skel)
    if user_file is not None:
        path = target / home.lstrip("/") / di.INPUT_LUA_REL
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(user_file)
    if monitors_lua is not None:
        path = target / home.lstrip("/") / dm.HYPR_DIR_REL / "monitors.lua"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(monitors_lua)
    return target


def quiet(fn, *args, **kwargs):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        result = fn(*args, **kwargs)
    return result, buf.getvalue()


def user_lua(target, home="/home/deck") -> pathlib.Path:
    return target / home.lstrip("/") / di.INPUT_LUA_REL


# ---------------------------------------------------------------------------

print("\n## 1. the decided values, and the sentinel this repo standardised on")

check("above_lock is 2, hardware-verified 2026-08-11", di.ABOVE_LOCK, 2)
check("the OSK's layer namespace is deck-osk", di.DECK_OSK_LAYER_NAMESPACE, "deck-osk")

# docs/PROGRESS.md §5.37 D5.
check("the touch transform is 3 (libinput's 270 calibration matrix)", di.TOUCH_TRANSFORM, 3)
check_true(
    "…and it is one of Hyprland's eight, not an out-of-range value it would "
    "clamp (0.56.2 clamps to -1..7 and treats -1 as 'leave libinput alone', so "
    "a typo'd 8 would silently become 7 and rotate taps the wrong way)",
    di.TOUCH_TRANSFORM in di.VALID_TOUCH_TRANSFORMS,
)
check(
    "🔴 the touchdevice is bound to the SAME output monitors.lua bets the "
    "desktop's rotation and scale on — two names for one panel is how a "
    "touchscreen ends up stretched over a rectangle the desktop is not on",
    di.PANEL_OUTPUT,
    dm.PANEL_OUTPUT,
)
check(
    "…and it equals deck_monitors' panel transform. NOT the argument for the "
    "value (that is the digitizer's measured 800x1280 portrait ABS ranges plus "
    "fbcon=rotate:1) — asserted so that if one is ever re-measured, the "
    "coincidence breaking is visible rather than silent",
    di.TOUCH_TRANSFORM,
    dm.PANEL_TRANSFORM,
)
check_true(
    "🔴 the rendered block names NO touch device — CLAUDE.md forbids claiming "
    "LCD support anywhere, so this uses Hyprland's device-agnostic GLOBAL "
    "input:touchdevice options rather than an hl.device rule keyed on the "
    "OLED's fts3528 controller (the string may appear in prose about what was "
    "measured; it must never appear in a `name =` field)",
    not re.search(r"\bname\s*=", di.strip_lua_comments("\n".join(di.render_block())))
    and "fts3528" not in di.strip_lua_comments("\n".join(di.render_block())),
)
check_true(
    "…and the OLED controller IS named in the block's PROSE, so a reader on "
    "other hardware learns which digitizer this was measured against",
    "fts3528" in "\n".join(di.render_block()).lower(),
)

t5_sentinel_lines = [
    ln for ln in T5_PLAN.read_text().splitlines() if "DECK_INPUT_LUA_LOADED = true" in ln
]
check_true(
    "🔴 T5-fork-plan.md 5.6 names this EXACT sentinel identifier",
    len(t5_sentinel_lines) > 0,
)
check("…and deck_input.py uses the same one", di.SENTINEL, "DECK_INPUT_LUA_LOADED")

t5_readback_ban = "Do NOT transcribe the comment currently on the operator's Deck" in T5_PLAN.read_text()
check_true(
    "T5-fork-plan.md 5.6 carries the 'do not transcribe' warning this module's docstring cites",
    t5_readback_ban,
)

print("\n## 2. the REAL upstream input.lua, out of a REAL fresh 4.0 install — not T9's hand-edited mirror")

manifest = json.loads(MANIFEST.read_text())
shipped_input = manifest["files"]["user_config"]["~/" + di.INPUT_LUA_REL]["text"]
check(
    "🔴 the fixture above is Omarchy 4.0's shipped input.lua, byte for byte, "
    "against the pinned fresh-4.0 manifest",
    SHIPPED,
    shipped_input,
)
check_true(
    "🔴 …and it carries NO misc table — T9's compositor-default claim is about "
    "Hyprland's compiled-in default, not a line Omarchy's own file writes",
    "misc" not in shipped_input,
)
check_true(
    "🔴 …and NO read_vconsole()/non-Latin-layout table — the extra logic in "
    "T9 §5.1's 'full proposed content' was captured off the operator's "
    "HAND-EDITED physical Deck, not off upstream, and this module must not "
    "promote a site-specific customization into the baked-in seed "
    "(kb_variant DOES appear here, but only as upstream's own commented-out "
    "example -- that is fine and unrelated to T9's active vconsole logic)",
    "read_vconsole" not in shipped_input and "non_latin_layouts" not in shipped_input,
)
rendered = "\n".join(di.render_block())
check_true(
    "…and this module's own rendered block never ASSIGNS kb_layout either — "
    "that is install_osk_kb_layout_rule's job, not this module's ('kb_layout' "
    "appears only inside the word install_osk_kb_layout_rule in a comment)",
    "kb_layout =" not in rendered,
)

print("\n## 3. the seed path matches src/deck-session.sh's HYPR_INPUT_LUA_TEMPLATE")

deck_session_template = scrape(
    DECK_SESSION,
    r"^readonly HYPR_INPUT_LUA_TEMPLATE=(\S+)$",
    "deck-session.sh's template path",
)
check(
    "the seed this module reads from is the SAME file deck-session.sh seeds "
    "install_osk_kb_layout_rule from, not a second, drifting copy",
    "/" + di.INPUT_LUA_DEFAULTS_REL,
    deck_session_template,
)

print("\n## 4. our markers and sentinel do not collide with any neighbour")

osk_begin = scrape(
    DECK_SESSION, r'^readonly OSK_KB_RULE_BEGIN="(.*)"$', "deck-session.sh's OSK marker"
)
osk_sentinel = scrape(
    DECK_SESSION, r"^readonly OSK_KB_SENTINEL=(\S+)$", "deck-session.sh's OSK sentinel"
)
check_true(
    "🔴 our markers are NOT deck-session.sh's OSK markers — two writers of one "
    "file, one marker each",
    di.BEGIN != osk_begin and di.END != osk_begin,
)
check_true(
    "…nor is our sentinel deck-session.sh's OSK sentinel",
    di.SENTINEL != osk_sentinel,
)
check_true(
    "…nor deck_monitors.py's monitors.lua markers (different file, same "
    "naming convention)",
    di.BEGIN != dm.BEGIN and di.END != dm.END and di.SENTINEL != dm.SENTINEL,
)
check_true(
    "…nor deck_menu_lock.py's markers",
    di.BEGIN not in (dml.MENU_BEGIN, dml.MENU_END),
)

# ---------------------------------------------------------------------------

print("\n## 5. splice into an EMPTY file (no seed, no skel, no user file at all)")

target = make_target("empty", seed=None, skel=None, user_file=None, monitors_lua=None)
result, out = quiet(di.configure_lock_wake_dpms, make_ctx(target), runner=accepting_runner)
check("status is configured even with nothing to seed from", result["status"], "configured")
check("seeded_from is 'empty'", result["seeded_from"], "empty")
check_true("a loud warning was printed about the missing seed", "no file is worse than a partial one" in out)
skel_text = (target / di.INPUT_LUA_SKEL_REL).read_text()
check("skel's file is ONLY our block", skel_text.strip(), "\n".join(di.render_block()))
proof = di.verify(user_lua(target), "empty-seeded user file")
check("above_lock reads back 2", proof["above_lock"], "2")
check("both DPMS options read back false", (proof["key_press_enables_dpms"], proof["mouse_move_enables_dpms"]), ("false", "false"))

print("\n## 6. splice into a file SEEDED from the template (target absent, seed present)")

target = make_target("seeded", seed=SHIPPED, skel=None, user_file=None)
result, _ = quiet(di.configure_lock_wake_dpms, make_ctx(target), runner=accepting_runner)
check("seeded_from is 'defaults'", result["seeded_from"], "defaults")
text = user_lua(target).read_text()
check_true("upstream's kb_layout survives the seed", 'kb_layout = "us"' in text)
check_true("upstream's touchpad block survives the seed", "clickfinger_behavior" in text)
check_true("our block is appended, not merged into upstream's", di.BEGIN in text)

print("\n## 7. splice into an EXISTING file that already carries the OSK block AND a sibling")

target = make_target(
    "existing-with-osk",
    seed=SHIPPED,
    skel=SHIPPED,
    user_file=SHIPPED + "\n" + OSK_BLOCK,
    monitors_lua=MONITORS_LUA,
)
before_monitors = (target / "home/deck" / dm.HYPR_DIR_REL / "monitors.lua").read_bytes()
result, _ = quiet(di.configure_lock_wake_dpms, make_ctx(target), runner=accepting_runner)
check("status is configured", result["status"], "configured")
text = user_lua(target).read_text()
check_true("🔴 the OSK block survives our write, byte for byte", OSK_BLOCK.strip() in text)
check_true("upstream's own content survives too", 'kb_layout = "us"' in text)
after_monitors = (target / "home/deck" / dm.HYPR_DIR_REL / "monitors.lua").read_bytes()
check("🔴 the sibling monitors.lua is untouched, byte for byte", after_monitors, before_monitors)

print("\n## 8. and the REVERSE order — install_osk_kb_layout_rule's shape runs AFTER us")


def splice_osk_like(text: str) -> str:
    """A stand-in for install_osk_kb_layout_rule's own splice: same algorithm
    (marker removed if present, re-appended at the end), applied by hand here
    since that function lives in bash and this suite has no shell harness for
    it. Only the PRESERVATION property is under test — that OUR block survives
    a second writer's append the same way theirs survives ours."""
    begin, end = "-- >>> deck-session.sh: on-screen keyboard XKB layout >>>", "-- <<< deck-session.sh: on-screen keyboard XKB layout <<<"
    kept, skipping = [], False
    for line in text.splitlines():
        if line.strip() == begin:
            skipping = True
            continue
        if skipping:
            if line.strip() == end:
                skipping = False
            continue
        kept.append(line)
    head = "\n".join(kept).rstrip("\n")
    return (head + "\n\n" if head else "") + OSK_BLOCK


target = make_target("existing-reverse", seed=SHIPPED, skel=SHIPPED, user_file=SHIPPED)
result, _ = quiet(di.configure_lock_wake_dpms, make_ctx(target), runner=accepting_runner)
check("our step succeeds first", result["status"], "configured")
our_text = user_lua(target).read_text()
after_osk = splice_osk_like(our_text)
user_lua(target).write_text(after_osk)
check_true(
    "🔴 our block survives a SECOND writer's append after ours, byte for byte",
    di.our_block_text(after_osk) == di.our_block_text(our_text),
)
check_true(
    "…even though our sentinel is no longer the WHOLE FILE's last line "
    "(OSK's own sentinel now is) — this is an ORDERING fact about two "
    "independent tools, not damage to our block",
    di.last_statement(after_osk) != f"{di.SENTINEL} = true"
    and di.last_statement(after_osk) == 'DECK_OSK_KB_LAYOUT = "us"',
)
proof = di.verify(user_lua(target), "reverse-order user file")
check(
    "🔴 …and verify() STILL passes: it checks OUR sentinel is last WITHIN OUR "
    "OWN block, not last in the whole file — a whole-file check would give a "
    "false failure here with nothing actually wrong",
    proof["above_lock"],
    "2",
)

# ---------------------------------------------------------------------------

print("\n## 9. the disk readback — every one of verify()'s own refusals")

good = "\n".join(di.render_block())

vgood = tmpdir("verify-good") / "input.lua"
vgood.write_text(good)
proof = di.verify(vgood, "good file")
check("verify() on a clean render: above_lock", proof["above_lock"], "2")
check("verify() on a clean render: dpms both false", (proof["key_press_enables_dpms"], proof["mouse_move_enables_dpms"]), ("false", "false"))

vmissing = tmpdir("verify-missing")
check_raises(
    "verify() refuses a file that was never written",
    lambda: di.verify(vmissing / "input.lua", "missing file"),
    di.DeckInputError,
    "was not written",
)

v_no_dpms = tmpdir("verify-no-dpms") / "input.lua"
no_dpms_text = "\n".join(
    ln for ln in di.render_block() if "key_press_enables_dpms" not in ln and "mouse_move_enables_dpms" not in ln
    and "hl.config({" not in ln and ln.strip() not in ("misc = {", "},", "})")
)
v_no_dpms.write_text(no_dpms_text)
check_raises(
    "verify() refuses a file with no active DPMS block",
    lambda: di.verify(v_no_dpms, "no-dpms file"),
    di.DeckInputError,
    "no ACTIVE misc.key_press_enables_dpms",
)

v_true = tmpdir("verify-true") / "input.lua"
v_true.write_text(good.replace("key_press_enables_dpms = false", "key_press_enables_dpms = true"))
check_raises(
    "🔴 verify() refuses key_press_enables_dpms left true — the QAM-wake bug this stage exists to fix",
    lambda: di.verify(v_true, "regressed file"),
    di.DeckInputError,
    "expected both 'false'",
)

v_commented = tmpdir("verify-commented") / "input.lua"
commented = good.replace(
    'hl.layer_rule({ match = { namespace = "deck-osk" }, above_lock = 2 })',
    '-- hl.layer_rule({ match = { namespace = "deck-osk" }, above_lock = 2 })',
)
v_commented.write_text(commented)
check_raises(
    "🔴 verify() does not count a COMMENTED-OUT above_lock rule as active",
    lambda: di.verify(v_commented, "commented-out file"),
    di.DeckInputError,
    "no ACTIVE above_lock layer_rule",
)

v_wrong_ns = tmpdir("verify-wrong-ns") / "input.lua"
v_wrong_ns.write_text(good.replace('namespace = "deck-osk"', 'namespace = "something-else"'))
check_raises(
    "verify() refuses an above_lock rule for the WRONG namespace",
    lambda: di.verify(v_wrong_ns, "wrong-namespace file"),
    di.DeckInputError,
    "no ACTIVE above_lock layer_rule",
)

v_wrong_lock = tmpdir("verify-wrong-lock") / "input.lua"
v_wrong_lock.write_text(good.replace("above_lock = 2", "above_lock = 1"))
check_raises(
    "verify() refuses the wrong above_lock VALUE",
    lambda: di.verify(v_wrong_lock, "wrong-value file"),
    di.DeckInputError,
    "expected 2",
)

check(
    "verify() on a clean render: the touchdevice pair, §5.37 D5",
    (proof["touch_output"], proof["touch_transform"]),
    (di.PANEL_OUTPUT, str(di.TOUCH_TRANSFORM)),
)

v_no_touch = tmpdir("verify-no-touch") / "input.lua"
v_no_touch.write_text(
    good.replace(f'      output = "{di.PANEL_OUTPUT}",\n', "")
    .replace(f"      transform = {di.TOUCH_TRANSFORM},\n", "")
)
check_raises(
    "🔴 verify() refuses a file with no active input.touchdevice pair — the "
    "state §5.37 D5 was measured in, where every tap lands a quarter turn out",
    lambda: di.verify(v_no_touch, "no-touch file"),
    di.DeckInputError,
    "no ACTIVE input.touchdevice",
)

v_touch_commented = tmpdir("verify-touch-commented") / "input.lua"
v_touch_commented.write_text(
    good.replace(f"      transform = {di.TOUCH_TRANSFORM},", f"--      transform = {di.TOUCH_TRANSFORM},")
)
check_raises(
    "🔴 verify() does not count a COMMENTED-OUT touch transform as active",
    lambda: di.verify(v_touch_commented, "commented-out touch file"),
    di.DeckInputError,
    "no ACTIVE input.touchdevice",
)

v_touch_zero = tmpdir("verify-touch-zero") / "input.lua"
v_touch_zero.write_text(good.replace(f"transform = {di.TOUCH_TRANSFORM},", "transform = 0,"))
check_raises(
    "verify() refuses transform = 0 — Hyprland's shipped default, and exactly "
    "the value the broken Deck read back",
    lambda: di.verify(v_touch_zero, "unrotated touch file"),
    di.DeckInputError,
    "input.touchdevice.transform",
)

v_touch_wrong_out = tmpdir("verify-touch-wrong-out") / "input.lua"
v_touch_wrong_out.write_text(good.replace(f'output = "{di.PANEL_OUTPUT}"', 'output = "DP-2"'))
check_raises(
    "verify() refuses a touchdevice bound to some OTHER output",
    lambda: di.verify(v_touch_wrong_out, "wrong-output touch file"),
    di.DeckInputError,
    "input.touchdevice.output",
)

v_touch_auto = tmpdir("verify-touch-auto") / "input.lua"
v_touch_auto.write_text(good.replace(f'output = "{di.PANEL_OUTPUT}"', 'output = "[[Auto]]"'))
check_raises(
    "🔴 verify() refuses the shipped [[Auto]] default: its autodetect branch is "
    "commented out behind a // FIXME in Hyprland 0.56.2, so it leaves the "
    "device UNBOUND rather than binding it to the panel",
    lambda: di.verify(v_touch_auto, "auto-output touch file"),
    di.DeckInputError,
    "input.touchdevice.output",
)

v_not_last = tmpdir("verify-not-last") / "input.lua"
v_not_last.write_text(good.replace(
    f"{di.SENTINEL} = true\n-- <<<",
    f"{di.SENTINEL} = true\nlocal x = 1\n-- <<<",
))
check_raises(
    "🔴 verify() refuses a sentinel that is not the LAST statement",
    lambda: di.verify(v_not_last, "sentinel-not-last file"),
    di.DeckInputError,
    "not last",
)

# ---------------------------------------------------------------------------

print("\n## 10. marker idempotency — a re-run replaces ONLY our own block")

target = make_target("idempotent", seed=SHIPPED, skel=SHIPPED, user_file=SHIPPED)
di.configure_lock_wake_dpms(make_ctx(target), runner=accepting_runner)
first = user_lua(target).read_text()
# Hand-corrupt our own block's comment text (simulating an older version of
# this module having written slightly different prose) to prove a re-run
# REPLACES it rather than appending a second copy.
corrupted = first.replace("Installed by configure_deck", "OLD COMMENT FROM A PRIOR VERSION")
user_lua(target).write_text(corrupted)
result, _ = quiet(di.configure_lock_wake_dpms, make_ctx(target), runner=accepting_runner)
check("the re-run reports it replaced an existing block", result["replaced_existing_block"], True)
second = user_lua(target).read_text()
check("re-running produces EXACTLY the same output as the first run (not a growing file)", second, first)
check("only ONE copy of our start marker exists after two runs", second.count(di.BEGIN), 1)
check("only ONE copy of our end marker exists after two runs", second.count(di.END), 1)

# 🔴 §5.37 D5. The marker count alone would not have caught a statement
# appended INSIDE the block, and `verify()` refuses a second touchdevice call
# rather than picking one, so a duplicate is an outage rather than a wart.
check(
    "exactly ONE active input.touchdevice call after two runs",
    len(di.touchdevice_calls(second)),
    1,
)
check("…and exactly one misc DPMS pair", len(di.misc_dpms_calls(second)), 1)
check("…and exactly one above_lock rule", len(di.above_lock_calls(second)), 1)

# 🔴 The preserve-everything-outside-the-markers rule, stated as its own check
# rather than left implicit in §7/§8: a third run against a file carrying BOTH
# deck-session.sh's OSK block AND arbitrary user content must leave every byte
# that is not ours exactly where it was.
USER_CONTENT = (
    "-- the operator's own line, which nothing of ours may touch\n"
    'o.window("(Alacritty|kitty|foot)", { scroll_touchpad = 1.5 })\n'
    "hl.gesture({ fingers = 3, direction = \"horizontal\", action = \"workspace\" })\n"
)
target = make_target(
    "preserve-outside",
    seed=SHIPPED,
    skel=SHIPPED,
    user_file=SHIPPED + "\n" + USER_CONTENT + "\n" + OSK_BLOCK,
)
quiet(di.configure_lock_wake_dpms, make_ctx(target), runner=accepting_runner)
once = user_lua(target).read_text()
quiet(di.configure_lock_wake_dpms, make_ctx(target), runner=accepting_runner)
twice = user_lua(target).read_text()
check(
    "🔴 everything OUTSIDE our markers is byte-identical across a re-run",
    di.outside_our_block(twice),
    di.outside_our_block(once),
)
check_true(
    "…and that 'outside' really does still contain the OSK block, upstream's "
    "seed AND the user's own lines (a check that passed because both sides "
    "were empty would prove nothing)",
    OSK_BLOCK.strip() in di.outside_our_block(twice)
    and 'kb_layout = "us"' in di.outside_our_block(twice)
    and "the operator's own line" in di.outside_our_block(twice),
)
check("…and the whole file is unchanged by the second run", twice, once)

print("\n## 11. refusal on an unterminated own-marker block")

broken_target = make_target("broken-marker", seed=None, skel=SHIPPED, user_file=SHIPPED + "\n" + di.BEGIN + "\nhl.config({})\n")
check_raises(
    "🔴 an unterminated start marker is refused, not guessed past — mirrors "
    "install_osk_kb_layout_rule's exact refusal shape",
    lambda: di.install(broken_target, "home/deck/" + di.INPUT_LUA_REL, runner=accepting_runner),
    di.DeckInputError,
    "no end marker",
)

print("\n## 12. the luac -p gate")

if LUAC_BIN is None:
    note("no luac binary found on this dev machine — skipping the two real-compiler checks")
else:
    target = make_target("luac-good", seed=SHIPPED, skel=SHIPPED, user_file=SHIPPED)
    result, _ = quiet(di.configure_lock_wake_dpms, make_ctx(target), runner=luac_runner)
    check("a real luac accepts our own rendered block", result["status"], "configured")
    check("…and syntax_checked is True", result["syntax_checked"], True)

    poisoned_seed = SHIPPED + "\n# a bare-hash comment, bracket-balanced, invalid Lua\n"
    target = make_target("luac-poisoned", seed=poisoned_seed, skel=None, user_file=None)
    check_raises(
        "🔴 a real luac REFUSES a bracket-balanced-but-syntactically-invalid seed "
        "('# comment' is not Lua) rather than installing it silently",
        lambda: di.install(target, di.INPUT_LUA_SKEL_REL, runner=luac_runner),
        di.DeckInputError,
        "is not valid Lua",
    )

target = make_target("luac-absent", seed=SHIPPED, skel=SHIPPED, user_file=SHIPPED)
result, out = quiet(di.configure_lock_wake_dpms, make_ctx(target), runner=absent_luac_runner)
check("without luac, the step still succeeds (warn, not refuse)", result["status"], "configured")
check("…and records syntax_checked = False", result["syntax_checked"], False)
check_true("…with a loud warning about it", "was NOT syntax-checked" in out)

# ---------------------------------------------------------------------------

print("\n## 13. verify_live — the three-outcome shape, mirroring verify_osk_kb_layout")

target = make_target("live-none", seed=SHIPPED, skel=SHIPPED, user_file=SHIPPED)
di.configure_lock_wake_dpms(make_ctx(target), runner=accepting_runner)
result, out = quiet(di.verify_live, target, TEST_UID, runtime_dir_rel="run/user/999999", runner=accepting_runner)
check("no live instance -> status not-live, no raise", result["status"], "not-live")
check_true("…and it WARNS loudly rather than staying silent", "has NOT been observed working" in out)


def make_live(target, uid, sig="abc123"):
    d = pathlib.Path(target) / f"run/user/{uid}/hypr/{sig}"
    d.mkdir(parents=True, exist_ok=True)
    sock = d / ".socket.sock"
    import socket as _socket

    s = _socket.socket(_socket.AF_UNIX, _socket.SOCK_STREAM)
    try:
        s.bind(str(sock))
    finally:
        s.close()
    return sig


def getoption_replies(overrides=None):
    """A fake `hyprctl getoption` keyed on the option name, in the exact output
    shape the real one printed on the Deck 2026-08-15. A single flat "int: 0"
    for everything would have let the §5.37 D5 touchdevice checks pass by
    accident, since `output` is a STRING option."""
    replies = {
        "misc:key_press_enables_dpms": "int: 0\nset: true\n",
        "misc:mouse_move_enables_dpms": "int: 0\nset: true\n",
        "input:touchdevice:output": f"str: {di.PANEL_OUTPUT}\nset: true\n",
        "input:touchdevice:transform": f"int: {di.TOUCH_TRANSFORM}\nset: true\n",
    }
    replies.update(overrides or {})
    return replies


def make_hyprctl(overrides=None):
    replies = getoption_replies(overrides)

    def hyprctl(target, argv):
        assert argv[0] == "env"
        if argv[-2] == "reload":
            return 0, "ok"
        if argv[-2] == "eval":
            return 0, "ok"
        if "getoption" in argv:
            option = argv[-1]
            assert option in replies, f"unexpected getoption {option!r}"
            return 0, replies[option]
        raise AssertionError(argv)

    return hyprctl


hyprctl_ok = make_hyprctl()


def hyprctl_sentinel_gone(target, argv):
    if "reload" in argv:
        return 0, "ok"
    if "eval" in argv:
        return 7, 'error: [string "..."]: DECK_INPUT_LUA_LOADED is nil'
    raise AssertionError(argv)


hyprctl_wrong_option = make_hyprctl({"misc:key_press_enables_dpms": "int: 1\nset: true\n"})

# 🔴 §5.37 D5: the compositor never picked the touch transform up. The values
# below are the DEFAULTS the Deck printed before the block was applied --
# `[[Auto]]` and `0` -- which is exactly the state the defect was measured in.
hyprctl_touch_unbound = make_hyprctl({"input:touchdevice:output": "str: [[Auto]]\nset: false\n"})
hyprctl_touch_unrotated = make_hyprctl({"input:touchdevice:transform": "int: 0\nset: false\n"})


target = make_target("live-good", seed=SHIPPED, skel=SHIPPED, user_file=SHIPPED)
di.configure_lock_wake_dpms(make_ctx(target), runner=accepting_runner)
sig = make_live(target, TEST_UID)
result, out = quiet(
    di.verify_live, target, TEST_UID, runtime_dir_rel=f"run/user/{TEST_UID}", runner=hyprctl_ok
)
check("live + sentinel present + both options 0 -> verified", result["status"], "verified")
check("…and reports the instance signature", result["instance"], sig)

target = make_target("live-sentinel-gone", seed=SHIPPED, skel=SHIPPED, user_file=SHIPPED)
di.configure_lock_wake_dpms(make_ctx(target), runner=accepting_runner)
make_live(target, TEST_UID)
check_raises(
    "🔴 live + sentinel gone -> FAIL (the file was discarded)",
    lambda: di.verify_live(target, TEST_UID, runtime_dir_rel=f"run/user/{TEST_UID}", runner=hyprctl_sentinel_gone),
    di.DeckInputError,
    "discarded",
)

target = make_target("live-wrong-option", seed=SHIPPED, skel=SHIPPED, user_file=SHIPPED)
di.configure_lock_wake_dpms(make_ctx(target), runner=accepting_runner)
make_live(target, TEST_UID)
check_raises(
    "live + wrong option value -> FAIL, naming the option",
    lambda: di.verify_live(target, TEST_UID, runtime_dir_rel=f"run/user/{TEST_UID}", runner=hyprctl_wrong_option),
    di.DeckInputError,
    "misc:key_press_enables_dpms",
)

target = make_target("live-touch-unbound", seed=SHIPPED, skel=SHIPPED, user_file=SHIPPED)
di.configure_lock_wake_dpms(make_ctx(target), runner=accepting_runner)
make_live(target, TEST_UID)
check_raises(
    "🔴 live + touchdevice still on the [[Auto]] default -> FAIL, naming the option",
    lambda: di.verify_live(target, TEST_UID, runtime_dir_rel=f"run/user/{TEST_UID}", runner=hyprctl_touch_unbound),
    di.DeckInputError,
    "input:touchdevice:output",
)

target = make_target("live-touch-unrotated", seed=SHIPPED, skel=SHIPPED, user_file=SHIPPED)
di.configure_lock_wake_dpms(make_ctx(target), runner=accepting_runner)
make_live(target, TEST_UID)
check_raises(
    "🔴 live + touchdevice transform still 0 -> FAIL: the digitizer is still in "
    "the panel's native portrait frame and every tap is a quarter turn out",
    lambda: di.verify_live(target, TEST_UID, runtime_dir_rel=f"run/user/{TEST_UID}", runner=hyprctl_touch_unrotated),
    di.DeckInputError,
    "input:touchdevice:transform",
)

check_true(
    "🔴 render_block()'s own comment recipe uses the error-raising eval form, "
    "never a bare readback (test-hyprctl-syntax.sh scanner 3's exact ban)",
    "== nil then error(" in "\n".join(di.render_block()),
)
import inspect  # noqa: E402

verify_live_src = inspect.getsource(di.verify_live)
check_true(
    "…and the SOURCE of verify_live itself never issues 'eval' with a bare 'return'",
    "'eval', expr" in verify_live_src or "\"eval\", expr" in verify_live_src,
)
check_true(
    "…and that expr string is the error()-raising assertion form",
    "== nil then error(" in inspect.getsource(di.verify_live),
)

# ---------------------------------------------------------------------------

print("\n## 14. deferred provisioning, symlinks, and DeckUserError — the same edge cases deck_monitors.py covers")

target = make_target("deferred", seed=SHIPPED, skel=SHIPPED, user_file=None)
result, out = quiet(di.configure_lock_wake_dpms, make_ctx(target, defer=True), runner=accepting_runner)
check("a deferred install writes skel only", result["status"], "skel-only")
check("…and no user path is recorded (no account exists yet)", result["user_path"], None)

target = make_target("no-account", seed=SHIPPED, skel=SHIPPED, user_file=None, passwd="root:x:0:0::/root:/bin/bash\n")
result, out = quiet(di.configure_lock_wake_dpms, make_ctx(target), runner=accepting_runner)
check("a target whose named user does not exist fails cleanly, not raise", result["status"], "failed")
check_true("…and is reported loudly", "Deck lock-wake/above_lock" in out)

target = make_target("symlink", seed=SHIPPED, skel=SHIPPED, user_file=None)
real = tmpdir("symlink-elsewhere") / "elsewhere.lua"
real.write_text("-- not this user's file\n")
link = user_lua(target)
link.parent.mkdir(parents=True, exist_ok=True)
link.symlink_to(real)
result, _ = quiet(di.configure_lock_wake_dpms, make_ctx(target), runner=accepting_runner)
check("a symlinked input.lua is replaced with a regular file, not written through", result["status"], "configured")
check_true("…and the target file is a regular file afterwards", user_lua(target).is_file() and not user_lua(target).is_symlink())
check_true("…and real (the symlink's old target) is untouched", real.read_text() == "-- not this user's file\n")

# ---------------------------------------------------------------------------

print("\n## 15. the install log, and the registry")

target = make_target("full-record", seed=SHIPPED, skel=SHIPPED, user_file=SHIPPED)
di.lock_wake_dpms_step(make_ctx(target))
log_path = target / deck_configure.DECK_INSTALL_LOG_REL
doc = json.loads(log_path.read_text())
check("the step lands under 'lock_wake_dpms'", doc["lock_wake_dpms"]["status"], "configured")
check("…the log stays 0644", mode_of(log_path), "0644")
check("…and carries the sentinel a live compositor is asserted against", doc["lock_wake_dpms"]["sentinel"], di.SENTINEL)
check("…and the above_lock value", doc["lock_wake_dpms"]["above_lock"], di.ABOVE_LOCK)

target = make_target("steps-fail", seed=None, skel=None, user_file=None, passwd="root:x:0:0::/root:/bin/bash\n")
raised = None
buf = io.StringIO()
try:
    with contextlib.redirect_stdout(buf):
        di.lock_wake_dpms_step(make_ctx(target))
except Exception as exc:  # noqa: BLE001
    raised = exc
check("🔴 the step does not raise on failure: critical=False, and the record is the report", raised, None)
check(
    "…and the failure is recorded, never silently skipped",
    json.loads((target / deck_configure.DECK_INSTALL_LOG_REL).read_text())["lock_wake_dpms"]["status"],
    "failed",
)

names = [s.name for s in deck_configure.deck_steps()]
check("the lock_wake_dpms step is registered", "lock_wake_dpms" in names, True)
check(
    "…bound to the right entry point",
    [s.fn for s in deck_configure.deck_steps() if s.name == "lock_wake_dpms"],
    [di.lock_wake_dpms_step],
)
check(
    "…and non-critical: a degraded lock screen still leaves a booting, "
    "autologinning Deck reachable by controller",
    [s.critical for s in deck_configure.deck_steps() if s.name == "lock_wake_dpms"],
    [False],
)
check(
    "🔴 exactly one step in the whole registry is still critical, and it is not this one",
    [s.name for s in deck_configure.deck_steps() if s.critical],
    ["autologin"],
)
check(
    "…and it runs after the user exists and before the T12 applier",
    names.index("lock_wake_dpms") < names.index("patches"),
    True,
)
check("every step name is still distinct (they are the install log's keys)", len(set(names)), len(names))

# ---------------------------------------------------------------------------

print()
if NOTES:
    print(f"{NOTES} check(s) did not run — see the NOTE lines above")
print(f"{CHECKS - FAILURES}/{CHECKS} checks passed")
if FAILURES:
    print(f"{FAILURES} FAILURES")
shutil.rmtree(WORK, ignore_errors=True)
sys.exit(1 if FAILURES else 0)
