#!/usr/bin/env python3
"""Unit tests for `configure_deck`'s `limine_rotation` and `tty_rotation` steps —
T5 §5.2's two boot-chain rotation surfaces (`deck_rotation.py`).

No VM, no root, no network, no chroot, no bootloader, no ISO build, and nothing
against the Deck:

    python3 test-deck-rotation.py

WHAT THIS SUITE IS ACTUALLY FOR
===============================

Everything is asserted against a **scratch target filesystem this suite builds**,
by running the steps and reading the artefacts back — never by grepping the
module's own source. The exceptions are the drift scrapes in §1, which read
`iso/upstream` on purpose: five facts about upstream's boot chain are written
down a second time in `deck_rotation.py`, and a second copy nothing compares is
how a test stays green after the product it describes has moved.

Five traps, and the first two have each cost this project a wrong answer already:

1. 🔴 **A rotation value written 180° out.** Two have been recorded confidently
   in this repo and found inverted on the panel — the desktop's `transform 1`
   and Limine's `interface_rotation: 270`. So `90` and `fbcon=rotate:1` are
   asserted as *values*, with the reason attached, and not merely "whatever the
   module says".

2. 🔴 **`/boot` composed instead of resolved.** The ESP is wherever the installer
   mounted the EFI partition; upstream stamps it into `/etc/default/limine` as
   `ESP_PATH=` and resolves the config through it in two later phases. A step
   that hardcoded `/boot` would pass every check on a machine that happens to
   use `/boot` and silently write nothing on one that does not.

3. 🔴 **Clobbering an entry block.** The entries carry the UKI paths and their
   blake2b hashes. A header write that disturbs them is a machine that does not
   boot, so the entry region is compared byte for byte across every write.

4. 🔴 **The destruction events, MODELLED rather than asserted in prose.** A
   hand-edited header survives `limine-update` (measured on the Deck
   2026-08-11) and does **not** survive `omarchy refresh limine`, which copies
   the packaged template over the file. §7 drives both events over a fixture,
   including the one where the rotation is *destroyed* — because a destruction
   test that could not show the destruction would prove nothing.

5. 🔴 **`=` where `+=` is required.** `_limine_kernel_cmdline` collects **only**
   `KERNEL_CMDLINE[default]+=` lines, so a drop-in written with `=` is on disk,
   looks right to a grep, and contributes nothing. §8 checks the drop-in against
   upstream's own regex, scraped out of upstream's own source, and includes the
   `=` case as a negative control.
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
# The authority on upstream's boot chain. Read, not copied.
PHASES_IMPL = UPSTREAM_ORCH / "phases_impl.py"
# The authority on the two measured values.
PROGRESS = REPO_ROOT / "docs/PROGRESS.md"
SWEEP = REPO_ROOT / "docs/findings/P22-deck-conformance-sweep.md"

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

WORK = pathlib.Path(tempfile.mkdtemp(prefix="deck-rotation-test-"))

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

from orchestrator import deck_configure, deck_rotation as dr  # noqa: E402
from orchestrator.context import InstallContext  # noqa: E402

print(f"# modules loaded from {PKG_ROOT}")

TEST_UID = os.getuid()
TEST_GID = os.getgid()

# Omarchy's shipped template, in the shape that matters: globals only, no entry
# blocks, and no interface_rotation. That is exactly what `_write_limine_defaults`
# copies onto the ESP in phase 3, so it is what this step usually finds.
TEMPLATE = """\
### Read more at config document: https://github.com/limine-bootloader/limine
#timeout: 3
default_entry: 2
interface_branding: Omarchy Bootloader
interface_branding_color: 9ece6a
hash_mismatch_panic: no

term_background: 1a1b26
backdrop: 1a1b26
"""

# What limine-entry-tool appends once `limine-update` has run. The hash and the
# UKI path are the reason §3's byte-comparison exists.
ENTRIES = """\
/+Omarchy
//Linux
    comment: auto-generated by limine-entry-tool
    protocol: efi
    path: boot():/EFI/Linux/omarchy_linux.efi#5f2b1c9a
    cmdline: root=UUID=dead-beef rw fbcon=rotate:1
//Linux (fallback)
    protocol: efi
    path: boot():/EFI/Linux/omarchy_linux-fallback.efi#77c0de11
"""

REGENERATED_ENTRIES = """\
/+Omarchy
//Linux
    comment: auto-generated by limine-entry-tool
    protocol: efi
    path: boot():/EFI/Linux/omarchy_linux.efi#0000feed
    cmdline: root=UUID=dead-beef rw fbcon=rotate:1
"""

DEFAULT_LIMINE = 'ESP_PATH="{esp}"\n\nKERNEL_CMDLINE[default]+="root=UUID=dead-beef rw quiet"\n'


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
    esp: str = "/boot",
    conf: str | None = TEMPLATE,
    defaults: str | None = None,
    dropins: dict[str, str] | None = None,
) -> pathlib.Path:
    """A target with a Limine boot chain on it, in whatever state the case needs."""
    target = tmpdir(name) / "mnt"
    (target / "etc/default").mkdir(parents=True, exist_ok=True)
    if defaults is None:
        defaults = DEFAULT_LIMINE.format(esp=esp)
    if defaults != "":
        (target / dr.LIMINE_DEFAULTS_REL).write_text(defaults)
    esp_root = target / esp.lstrip("/")
    esp_root.mkdir(parents=True, exist_ok=True)
    if conf is not None:
        (esp_root / dr.LIMINE_CONF_NAME).write_text(conf)
    for filename, text in (dropins or {}).items():
        path = target / dr.LIMINE_ENTRY_TOOL_D_REL / filename
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    return target


def quiet(fn, *args, **kwargs):
    """Run something that prints through `ui`, and hand back (result, output)."""
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        result = fn(*args, **kwargs)
    return result, buf.getvalue()


# ---------------------------------------------------------------------------

print("## 1. the five upstream facts this module writes down a second time")

# Each of these is duplicated from phases_impl.py into deck_rotation.py. The
# scrape guard above is what makes "upstream moved it" fail here instead of at
# install time on a machine that then boots sideways.
check_true(
    "upstream still reads usr/share/limine-entry-tool.d, the legacy conf and "
    "etc/limine-entry-tool.d, in that order",
    scrape(PHASES_IMPL, r'"usr" / "share" / "limine-entry-tool\.d"', "share drop-in dir")
    and scrape(PHASES_IMPL, r'"etc" / "limine-entry-tool\.conf"', "legacy conf")
    and scrape(PHASES_IMPL, r'"etc" / "limine-entry-tool\.d"', "etc drop-in dir"),
)
check(
    "…and deck_rotation lists the same three, in the same order",
    list(dr.LIMINE_CONFIG_SOURCES),
    ["usr/share/limine-entry-tool.d", "etc/limine-entry-tool.conf", "etc/limine-entry-tool.d"],
)
upstream_cmdline_re = scrape(
    PHASES_IMPL, r"re\.compile\(r'(\^\\s\*KERNEL_CMDLINE.*?)'\)", "the KERNEL_CMDLINE regex"
)
check(
    "🔴 deck_rotation's KERNEL_CMDLINE regex is upstream's, character for character",
    dr.KERNEL_CMDLINE_RE.pattern,
    upstream_cmdline_re,
)
check_true(
    "upstream still resolves the ESP through an ESP_PATH setting with a /boot fallback",
    scrape(PHASES_IMPL, r'_limine_setting\(config_text, "(ESP_PATH)", "/boot"\)', "ESP_PATH"),
)
check("…and deck_rotation names the same setting", dr.ESP_PATH_SETTING, "ESP_PATH")
check("…with the same fallback", dr.DEFAULT_ESP_PATH, "/boot")
check_true(
    "🔴 upstream still COPIES the template onto the ESP in phase 3 — the reason "
    "/boot/limine.conf needs its own step at all",
    scrape(PHASES_IMPL, r"shutil\.copy2\(_limine_template\(ctx, \"limine\.conf\"\), limine_conf\)",
           "the phase-3 template copy"),
)
check_true(
    "…and finalize_limine_boot still refuses to run without that file",
    scrape(PHASES_IMPL, r'raise RuntimeError\(f"\{limine_conf\} missing"\)', "the missing-conf guard"),
)


print("\n## 2. the two measured values, and the trap of deriving one from another")

check("🔴 the Limine menu rotation is 90", dr.INTERFACE_ROTATION, 90)
check(
    "🔴 …and specifically NOT 270, which was recorded as fact and rendered the "
    "menu UPSIDE DOWN on the panel 2026-08-11",
    dr.INTERFACE_ROTATION == 270,
    False,
)
check("🔴 the console rotation is fbcon=rotate:1", dr.FBCON_ROTATE, 1)
check("…and the token is spelled the way the kernel spells it", dr.FBCON_TOKEN, "fbcon=rotate:1")
check_true(
    "the record still says 90 — if PROGRESS §5.11 has been corrected, this "
    "constant has to move with it",
    re.search(r"interface_rotation.*\*\*90\*\*", PROGRESS.read_text()),
)
check_true(
    "…and the sweep measured 90 on disk on the live Deck",
    "interface_rotation: 90" in SWEEP.read_text(),
)
check_true(
    "🔴 the sweep also records that Limine and Hyprland use OPPOSITE sign "
    "conventions — 90 here and transform 3 on the desktop are consistent",
    "opposite sign" in SWEEP.read_text(),
)
check(
    "the rotation is one Limine accepts",
    dr.INTERFACE_ROTATION in dr.VALID_INTERFACE_ROTATIONS,
    True,
)
check_true("the cmdline token passes the module's own safety regex",
           dr.SAFE_CMDLINE_TOKEN_RE.match(dr.FBCON_TOKEN))
for hostile in ('fbcon=rotate:1"', "fbcon=rotate:1 init=/bin/sh", "fbcon=rotate:1\nroot=/dev/sda"):
    check(f"…and rejects {hostile!r}", bool(dr.SAFE_CMDLINE_TOKEN_RE.match(hostile)), False)


print("\n## 3. resolving the ESP — never composing /boot")

target = make_target("esp-boot")
path, esp = dr.resolve_limine_conf(target)
check("the default ESP resolves to /boot", esp, "/boot")
check("…and the config under it", path, target / "boot/limine.conf")

target = make_target("esp-efi", esp="/efi")
path, esp = dr.resolve_limine_conf(target)
check(
    "🔴 an ESP_PATH of /efi resolves THERE, not /boot — a hardcoded /boot would "
    "write a rotation nothing reads",
    esp,
    "/efi",
)
check("…and the config under it", path, target / "efi/limine.conf")
check("…and /boot is not even present on this target", (target / "boot").exists(), False)

# Quoted, and last-wins, exactly as _limine_setting does it.
target = make_target(
    "esp-quotes", esp="/efi", defaults="ESP_PATH='/wrong'\nESP_PATH=\"/efi\"\nKERNEL_CMDLINE[default]+=\"root=x\"\n"
)
check("shell quotes are stripped and the LAST setting wins", dr.resolve_limine_conf(target)[1], "/efi")

# A drop-in can carry settings too, and /etc/default/limine outranks it.
target = make_target(
    "esp-dropin",
    esp="/efi",
    dropins={"10-other.conf": 'ESP_PATH="/nope"\n'},
)
check(
    "…and /etc/default/limine outranks a drop-in, because it is concatenated last",
    dr.resolve_limine_conf(target)[1],
    "/efi",
)

target = make_target("esp-missing-dir", esp="/boot")
shutil.rmtree(target / "boot")
check_raises(
    "an ESP_PATH that is not a directory is refused, not guessed around",
    lambda: dr.resolve_limine_conf(target),
    dr.DeckRotationError,
)
target = make_target("esp-relative", defaults='ESP_PATH="boot"\nKERNEL_CMDLINE[default]+="root=x"\n')
check_raises(
    "a relative ESP_PATH is refused",
    lambda: dr.resolve_limine_conf(target),
    dr.DeckRotationError,
)
target = make_target("no-defaults", defaults="")
check_raises(
    "no /etc/default/limine at all is refused with a message about the boot chain",
    lambda: dr.resolve_limine_conf(target),
    dr.DeckRotationError,
)


print("\n## 4. the header write, over a config that already has entry blocks")

target = make_target("write-entries", conf=TEMPLATE + ENTRIES)
conf_path = target / "boot/limine.conf"
before = conf_path.read_text()
record, out = quiet(dr.configure_limine_rotation, make_ctx(target))
check("the step reports configured", record["status"], "configured")
check("…recording where it wrote", record["config"], "/boot/limine.conf")
after = conf_path.read_text()
check("interface_rotation is present exactly once, in the header", dr.read_rotation(after), ["90"])
check("🔴 …and the entry blocks are byte-identical", dr.entry_region(after), dr.entry_region(before))
check("…which the record states as a fact, not an assumption", record["entries_preserved"], True)
check_true(
    "the block carries the measurement that settled the value, for whoever reads "
    "this file on a Deck at 3am",
    "270 renders this menu UPSIDE DOWN" in after,
)
check_true("…and the marker pair", dr.LIMINE_BEGIN in after and dr.LIMINE_END in after)
check_true(
    "the rotation sits BEFORE the first entry line — a global inside an entry is "
    "not a global",
    after.index("interface_rotation") < after.index("/+Omarchy"),
)
check_true("nothing was announced as a warning on the happy path", not record["warnings"])

# Idempotent, which the SSH iterate-in-place loop requires (CLAUDE.md).
first = conf_path.read_text()
record2, _ = quiet(dr.configure_limine_rotation, make_ctx(target))
check("a second run is byte-identical", conf_path.read_text(), first)
check("…and still reports configured", record2["status"], "configured")
check_true(
    "…and says out loud that it replaced its own block rather than appending one",
    any("re-run" in w for w in record2["warnings"]),
)

# The all-header case: what phase 3 actually leaves behind.
target = make_target("write-no-entries")
record, _ = quiet(dr.configure_limine_rotation, make_ctx(target))
check("a config with no entries at all is handled", record["status"], "configured")
check("…the rotation lands", dr.read_rotation((target / "boot/limine.conf").read_text()), ["90"])
check("…and the (empty) entry region is still preserved", record["entries_preserved"], True)

target = make_target("write-absent", conf=None)
record, _ = quiet(dr.configure_limine_rotation, make_ctx(target))
check("an absent limine.conf is a recorded failure, not a created file", record["status"], "failed")
check("…and nothing was written", (target / "boot/limine.conf").exists(), False)
check_true("…with a message naming the phase that should have created it",
           "_write_limine_defaults" in record["error"])


print("\n## 5. disagreeing with the packaged template — the 90-vs-270 collision")

# 🔴 The ESP copy is taken from the template in phase 3, so a template carrying
# a DIFFERENT rotation hands that value to the copy, and this assertion is what
# makes the disagreement audible instead of leaving two writers fighting over
# one file.
#
# ⚠️ 270 is a FIXTURE here, not a description of our own patch any more.
# T12's 0020-limine-interface-rotation.patch really did ship 270 — the
# pre-measurement hypothesis from T5-fork-plan §5.2, written before anyone
# looked at the panel — and this row was originally written to model that.
# It was corrected to 90 on 2026-08-12 after reading /boot/limine.conf off the
# running Deck. The collision case is kept because ANY disagreeing template
# must be reported, not because ours still disagrees.
target = make_target("template-270", conf=TEMPLATE.replace(
    "hash_mismatch_panic: no", "interface_rotation: 270\nhash_mismatch_panic: no"
) + ENTRIES)
record, out = quiet(dr.configure_limine_rotation, make_ctx(target))
check("the write still succeeds", record["status"], "configured")
check("…and 90 is what ends up on disk", dr.read_rotation((target / "boot/limine.conf").read_text()), ["90"])
check_true(
    "🔴 …but the pre-existing 270 is REPORTED: one of the two is 180 degrees wrong",
    any("180 degrees wrong" in w for w in record["warnings"]),
)
check_true("…loudly, on the console the install log captures", "180 degrees wrong" in out)

target = make_target("marker-orphan", conf=TEMPLATE + dr.LIMINE_BEGIN + "\ninterface_rotation: 90\n" + ENTRIES)
record, _ = quiet(dr.configure_limine_rotation, make_ctx(target))
check(
    "a start marker with no end marker is refused rather than guessed at — this "
    "is the boot chain",
    record["status"],
    "failed",
)


print("\n## 6. the entry region is not ours to move")

# The mutation this guards: a patch_limine_header that appends its block at the
# END of the file, or that reflows the whole thing, instead of splitting at the
# first entry line.
raw = TEMPLATE + ENTRIES
text, _ = dr.patch_limine_header(raw)
check("the entry region is unchanged by the pure function too", dr.entry_region(text), dr.entry_region(raw))
check_true("…and the UKI hash is still in it", "#5f2b1c9a" in dr.entry_region(text))
check(
    "the boundary is the first line opening an entry",
    dr.split_header((TEMPLATE + ENTRIES).splitlines()),
    len(TEMPLATE.splitlines()),
)
check(
    "…and a pre-v4 ':' entry sigil counts as one too",
    dr.split_header(["default_entry: 2", ":Old style entry", "    PROTOCOL=linux"]),
    1,
)
check("a file that is all header has its boundary at the end", dr.split_header(TEMPLATE.splitlines()),
      len(TEMPLATE.splitlines()))
check(
    "🔴 an interface_rotation that somehow landed INSIDE an entry is not counted "
    "as installed — Limine would not apply it",
    dr.read_rotation(TEMPLATE + "/+Omarchy\n    interface_rotation: 90\n"),
    [],
)

# 🔴 The guard itself, driven directly. Reaching it only by first breaking the
# writer would mean the writer and the check had to fail together to go red,
# which is exactly the pair of bugs a boot-chain assertion exists to catch.
dr.assert_entries_preserved(ENTRIES, ENTRIES, "x")
print("ok   assert_entries_preserved accepts an unchanged entry region")
CHECKS += 1
check_raises(
    "🔴 …and REFUSES a changed one, with two strings and no ESP",
    lambda: dr.assert_entries_preserved(ENTRIES, REGENERATED_ENTRIES, "x"),
    dr.DeckRotationError,
)
check_raises(
    "…including a single edited UKI hash, which is what a rewritten entry costs",
    lambda: dr.assert_entries_preserved(ENTRIES, ENTRIES.replace("#5f2b1c9a", "#00000000"), "x"),
    dr.DeckRotationError,
)
check_raises(
    "…and entries dropped entirely",
    lambda: dr.assert_entries_preserved(ENTRIES, "", "x"),
    dr.DeckRotationError,
)

# 🔴 The verification must consult the FILE, not the string it just rendered.
# The two are identical on this filesystem and are not guaranteed to be on a
# vfat ESP mounted with the masks CLAUDE.md's item 5 is about, so the seam is
# substituted here to tell the two apart.
target = make_target("readback-seam", conf=TEMPLATE + ENTRIES)
saved_read_back = dr.read_back
dr.read_back = lambda path: TEMPLATE + ENTRIES  # the file "did not take" the write
try:
    record, _ = quiet(dr.configure_limine_rotation, make_ctx(target))
finally:
    dr.read_back = saved_read_back
check(
    "🔴 a write that did not reach the disk is caught — the module attribute really "
    "is the seam, so the check reads the file and not the string it rendered",
    record["status"],
    "failed",
)
check_true("…naming the rotation it could not find", "interface_rotation" in record["error"])
record, _ = quiet(dr.configure_limine_rotation, make_ctx(target))
check("…and with the seam restored the same target succeeds", record["status"], "configured")


print("\n## 7. 🔴 THE DESTRUCTION TESTS — both events, modelled")

# Event A: `limine-update`. It regenerates the ENTRY blocks and leaves the
# header alone. Measured on the Deck 2026-08-11: interface_rotation: 90 was
# still present after limine-update reported "Updated: /boot/limine.conf" and
# rebuilt both UKIs. This models that and asserts it, so the claim can fail.
target = make_target("destroy-update", conf=TEMPLATE + ENTRIES)
conf_path = target / "boot/limine.conf"
quiet(dr.configure_limine_rotation, make_ctx(target))
patched = conf_path.read_text()
lines = patched.splitlines()
header = "\n".join(lines[: dr.split_header(lines)])
conf_path.write_text(header + "\n" + REGENERATED_ENTRIES)  # <- limine-update
check(
    "🔴 the rotation SURVIVES limine-update regenerating the entries",
    dr.read_rotation(conf_path.read_text()),
    ["90"],
)
check_true("…and the entries really did change", "#0000feed" in conf_path.read_text())
check_true("…and the old UKI hash is gone", "#5f2b1c9a" not in conf_path.read_text())

# Event B: `omarchy refresh limine`. It `mv`s the file aside and copies the
# PACKAGED TEMPLATE over it. A header edit does not survive this — and the test
# has to be able to show that, or "the rotation is baked in" is unfalsifiable.
conf_path.write_text(TEMPLATE)  # <- cp $OMARCHY_PATH/default/limine/limine.conf
check(
    "🔴 the rotation is DESTROYED by 'omarchy refresh limine' copying an "
    "unpatched template over it — which is why T12 patches the template as well; "
    "neither mechanism covers both events",
    dr.read_rotation(conf_path.read_text()),
    [],
)
# …and a re-run puts it back, which is what makes the step safe to call from a
# pre-refresh hook or a second install pass.
record, _ = quiet(dr.configure_limine_rotation, make_ctx(target))
check("…and re-running the step restores it", dr.read_rotation(conf_path.read_text()), ["90"])
check("…reporting configured", record["status"], "configured")

# Event B, with the template T12 actually ships today.
conf_path.write_text(TEMPLATE.replace("hash_mismatch_panic: no", "interface_rotation: 270\nhash_mismatch_panic: no"))
check(
    "🔴 a refresh from the template T12 patches TODAY leaves 270 on the ESP — the "
    "value measured to render this menu upside down",
    dr.read_rotation(conf_path.read_text()),
    ["270"],
)


print("\n## 8. the fbcon drop-in, checked against upstream's own parser")

target = make_target("fbcon")
record, out = quiet(dr.configure_tty_rotation, make_ctx(target))
check("the step reports configured", record["status"], "configured")
check("…recording the drop-in it wrote", record["dropin"], "/" + dr.FBCON_DROPIN_REL)
dropin = target / dr.FBCON_DROPIN_REL
check("…which exists", dropin.is_file(), True)
check("…world-readable, root-owned config", mode_of(dropin), "0644")

# 🔴 Against upstream's regex, compiled from upstream's source at test time.
upstream_re = re.compile(upstream_cmdline_re)
matched = [upstream_re.match(line) for line in dropin.read_text().splitlines()]
matched = [m for m in matched if m]
check("upstream's own KERNEL_CMDLINE regex matches exactly one line of it", len(matched), 1)
check(
    "🔴 …and yields the token, unquoted",
    dr.strip_shell_quotes(matched[0].group(1)).strip(),
    "fbcon=rotate:1",
)

# The whole point: the token reaches the cmdline limine-entry-tool assembles.
assembled = dr.limine_kernel_cmdline(dr.combined_limine_config(target))
check("the token is in the ASSEMBLED cmdline", "fbcon=rotate:1" in assembled.split(), True)
check("…and root= was not displaced by it", "root=UUID=dead-beef" in assembled.split(), True)
check("…the step recorded the token", record["cmdline_token"], "fbcon=rotate:1")

# NEGATIVE CONTROL for the '=' vs '+=' trap. A drop-in written with '=' is on
# disk, greps clean, and contributes nothing at all.
bad = target / dr.LIMINE_ENTRY_TOOL_D_REL / "60-bad.conf"
bad.write_text('KERNEL_CMDLINE[default]="i915.enable_psr=0"\n')
check(
    "🔴 NEGATIVE CONTROL: a drop-in written with '=' rather than '+=' contributes "
    "NOTHING to the assembled cmdline — which is why the check above is against "
    "the assembly and not against a grep",
    "i915.enable_psr=0" in dr.limine_kernel_cmdline(dr.combined_limine_config(target)),
    False,
)
check_true(
    "POSITIVE CONTROL: the same file with '+=' does reach it",
    "i915.enable_psr=0"
    in dr.limine_kernel_cmdline(
        dr.combined_limine_config(target) + '\nKERNEL_CMDLINE[default]+=" i915.enable_psr=0"'
    ).split(),
)
bad.unlink()

# Idempotent.
first = dropin.read_text()
record2, _ = quiet(dr.configure_tty_rotation, make_ctx(target))
check("a second run is byte-identical", dropin.read_text(), first)
check("…and still configured", record2["status"], "configured")

# Somebody else rotating the console too.
target = make_target("fbcon-conflict", dropins={"40-someone-else.conf": 'KERNEL_CMDLINE[default]+=" fbcon=rotate:3"\n'})
record, _ = quiet(dr.configure_tty_rotation, make_ctx(target))
check("a competing fbcon=rotate still succeeds", record["status"], "configured")
check_true(
    "…but the conflict is reported: the last one collected wins and two writers "
    "are fighting over the console",
    any("fighting over the console" in w for w in record["warnings"]),
)

target = make_target("fbcon-no-defaults", defaults="")
record, _ = quiet(dr.configure_tty_rotation, make_ctx(target))
check("no /etc/default/limine is a recorded failure", record["status"], "failed")
check(
    "…and nothing was written into a boot chain we could not read",
    (target / dr.FBCON_DROPIN_REL).exists(),
    False,
)

target = make_target("fbcon-no-root", defaults='ESP_PATH="/boot"\nKERNEL_CMDLINE[default]+="quiet"\n')
record, _ = quiet(dr.configure_tty_rotation, make_ctx(target))
check("a cmdline with no root= before we run is still written", record["status"], "configured")
check_true(
    "…and reported: something upstream of us is already wrong",
    any("no 'root='" in w for w in record["warnings"]),
)


print("\n## 9. the step entry points, the shared document, and the registry")

target = make_target("steps", conf=TEMPLATE + ENTRIES)
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    deck_configure.record_result(target, "wifi", {"status": "skipped"})
    dr.limine_rotation_step(make_ctx(target))
    dr.tty_rotation_step(make_ctx(target))
log_path = target / deck_configure.DECK_INSTALL_LOG_REL
doc = json.loads(log_path.read_text())
check("the menu rotation lands under 'limine_rotation'", doc["limine_rotation"]["status"], "configured")
check("the console rotation lands under 'tty_rotation'", doc["tty_rotation"]["status"], "configured")
check("…neither clobbering another step's key", doc["wifi"]["status"], "skipped")
check("…and the log stays 0644", mode_of(log_path), "0644")
check(
    "🔴 the two outcomes are distinguishable — one document, two keys, two "
    "different mechanisms recorded",
    sorted(doc["limine_rotation"]) != sorted(doc["tty_rotation"]),
    True,
)

target = make_target("steps-fail", conf=None, defaults="")
raised = None
buf = io.StringIO()
try:
    with contextlib.redirect_stdout(buf):
        dr.limine_rotation_step(make_ctx(target))
        dr.tty_rotation_step(make_ctx(target))
except Exception as exc:  # noqa: BLE001
    raised = exc
check("🔴 neither step raises on failure: critical=False, and the record is the report", raised, None)
doc = json.loads((target / deck_configure.DECK_INSTALL_LOG_REL).read_text())
check(
    "…and both failures are recorded, never silently skipped",
    [doc["limine_rotation"]["status"], doc["tty_rotation"]["status"]],
    ["failed", "failed"],
)
check_true("…loudly, on the console the install log captures", "Deck TTY rotation" in buf.getvalue())

names = [s.name for s in deck_configure.deck_steps()]
check("the limine_rotation step is registered", "limine_rotation" in names, True)
check("the tty_rotation step is registered", "tty_rotation" in names, True)
check(
    "…bound to the right entry points",
    [s.fn for s in deck_configure.deck_steps() if s.name in ("limine_rotation", "tty_rotation")],
    [dr.limine_rotation_step, dr.tty_rotation_step],
)
check(
    "🔴 …both non-critical: the danger is in the write, not in the skip, and a "
    "sideways menu still boots and still autologins",
    sorted(s.critical for s in deck_configure.deck_steps() if s.name in ("limine_rotation", "tty_rotation")),
    [False, False],
)
check(
    "🔴 …and both run BEFORE the T12 applier, which runs last — but the ordering "
    "that actually matters is that the whole phase precedes finalize_limine_boot",
    names.index("limine_rotation") < names.index("patches")
    and names.index("tty_rotation") < names.index("patches"),
    True,
)


print()
print(f"{CHECKS - FAILURES}/{CHECKS} checks passed")
if FAILURES:
    print(f"{FAILURES} FAILURES")
shutil.rmtree(WORK, ignore_errors=True)
sys.exit(1 if FAILURES else 0)
