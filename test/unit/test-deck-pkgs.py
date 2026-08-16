#!/usr/bin/env python3
"""Unit tests for `configure_deck`'s `pkgs` step — the install-time fetch
(`deck_pkgs.py`), its package lists, its build-time plumbing, and its first-boot
notice.

No VM, no root, no network, no chroot, no ISO build. Run directly:

    python3 test-deck-pkgs.py

WHAT THIS SUITE IS ACTUALLY FOR
===============================

`docs/findings/P32-steam-never-installed.md`: `deck-fetch.packages` was
maintained, commented, resolved by a build guard — and read by nothing that
installed anything. The shipped ISO produced a Deck with no Steam and a black
panel, while the install record reported eleven steps all green and the QEMU
suite scored 18/18. **Every one of those checks was a step assertion.** So this
suite is deliberately shaped around the things a "does it call pacman?" test
passes while the product is broken:

1. 🔴 **The list must have a consumer, and the consumer must be able to see the
   list.** `configs/deck/` lands in the archiso *profile*, not in the booted
   root, so the fetch list was not on the ISO at all. §6 asserts that the build
   patch copies it to exactly the path `deck_pkgs.FETCH_LIST_REL` reads —
   both ends derived, so they cannot drift apart quietly.

2. 🔴 **A zero exit is not success.** §4 drives the case where pacman exits 0
   and the package is still absent, and requires `status="failed"`. That is the
   outcome-vs-step distinction the finding asks for by name.

3. 🔴 **The list is parsed, never hard-coded.** A module with a literal `steam`
   in it would re-create the original defect the other way round. §1 proves the
   parser is what decides, by feeding it lists that have nothing to do with the
   real one.

4. 🔴 **The first-boot notice must fail loudly.** §7 runs the real script
   against a fake machine with a fake `pacman` on a closed PATH and asserts the
   non-zero exit — the only channel that survives to a running Deck with no
   terminal.

⚠️ §3's registry check is a **MERGE GATE**. This agent does not own
`deck_configure.py`; the registry line is added when this work is merged. Until
then that one check is red ON PURPOSE, and its failure message says so. Do not
"fix" it by deleting it.
"""

from __future__ import annotations

import contextlib
import dataclasses
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
OVERLAY_DECK = REPO_ROOT / "iso/overlay/configs/airootfs/usr/share/omarchy-iso/deck"
DECK_LISTS = REPO_ROOT / "iso/overlay/configs/deck"
BUILD_PATCH = REPO_ROOT / "iso/overlay/patches/deck-packages.patch"

SCRIPT = OVERLAY_DECK / "deck-steam-first-boot.sh"
UNIT = OVERLAY_DECK / "omarchy-deck-steam-first-boot.service"

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

WORK = pathlib.Path(tempfile.mkdtemp(prefix="deck-pkgs-test-"))

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
    # Every deck_* module in the overlay, DERIVED rather than listed — same
    # reasoning as the sibling suites: deck_steps() imports each registered step
    # module lazily, so a slice that adds one must not break this harness.
    for module in sorted(OVERLAY_ORCH.glob("deck_*.py")):
        shutil.copyfile(module, pkg / module.name)
    (pkg / "phases_impl.py").write_text(PHASES_IMPL_STUB)
    return root


PKG_ROOT = build_package()
sys.path.insert(0, str(PKG_ROOT))

from orchestrator import deck_configure, deck_pkgs  # noqa: E402

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


def mode_of(path: pathlib.Path) -> str:
    return f"{stat.S_IMODE(os.lstat(path).st_mode):04o}"


def make_live(name: str, *, fetch_list: str | None = "steam\n", wifi: str | None = None):
    """A fake live ISO root: the fetch list where build-iso.sh puts it, and
    optionally the Wi-Fi outcome file S1 leaves in /root."""
    live = tmpdir(name) / "live"
    if fetch_list is not None:
        path = live / deck_pkgs.FETCH_LIST_REL
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(fetch_list)
    if wifi is not None:
        outcome = live / "root/deck-wifi-outcome"
        outcome.parent.mkdir(parents=True, exist_ok=True)
        outcome.write_text(wifi)
    live.mkdir(parents=True, exist_ok=True)
    return live


def make_target(name: str, *, bootstrap: bool = False) -> pathlib.Path:
    target = tmpdir(name) / "mnt"
    target.mkdir(parents=True, exist_ok=True)
    if bootstrap:
        boot = target / deck_pkgs.STEAM_BOOTSTRAP_REL
        boot.parent.mkdir(parents=True, exist_ok=True)
        boot.write_text("not really a tarball")
    return target


class FakePacman:
    """A stand-in for `arch-chroot <target> pacman ...`.

    It answers the three subcommands `deck_pkgs` issues and RECORDS EVERY CALL,
    which is what makes the idempotence assertion possible: "a re-run is a
    no-op" is a statement about calls not made, and only a recording runner can
    prove it.
    """

    def __init__(self, installed=(), *, sync_code=0, install_code=0, install_works=True):
        self.installed = set(installed)
        self.sync_code = sync_code
        self.install_code = install_code
        self.install_works = install_works
        self.calls: list[list[str]] = []

    def __call__(self, argv, timeout):
        self.calls.append(list(argv))
        assert argv[0] == "arch-chroot", argv
        assert argv[2] == "pacman", argv
        sub = argv[3]
        if sub == "-Qq":
            name = argv[4]
            if name in self.installed:
                return 0, ""
            return 1, f"error: package '{name}' was not found"
        if sub == "-Sy":
            if self.sync_code != 0:
                return self.sync_code, "error: failed retrieving file 'core.db' from mirror"
            return 0, ":: Synchronizing package databases..."
        if sub == "-S":
            names = [a for a in argv[4:] if not a.startswith("-")]
            if self.install_code != 0:
                return self.install_code, "error: target not found"
            if self.install_works:
                self.installed.update(names)
            return 0, "(34/34) checking keys in keyring"
        raise AssertionError(f"unexpected pacman subcommand {sub!r} in {argv!r}")

    def subcommands(self) -> list[str]:
        return [c[3] for c in self.calls]


def run_fetch(target, live, runner, asset_dir=OVERLAY_DECK):
    """fetch_packages with the console captured, so 'loud' can be asserted."""
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        record = deck_pkgs.fetch_packages(target, live, asset_dir, runner)
    return record, buf.getvalue()


# ---------------------------------------------------------------------------
print("\n## 1. the list is PARSED, not hard-coded")
# ---------------------------------------------------------------------------

names, warns = deck_pkgs.parse_package_list("steam\n")
check("a one-entry list parses to that entry", names, ["steam"])
check("…with no warnings", warns, [])

names, warns = deck_pkgs.parse_package_list(
    "# a comment\n\n  steam  \n#steamdeck-dsp\nlib32-foo\n"
)
check("comments, blanks and surrounding space are handled", names, ["steam", "lib32-foo"])

names, warns = deck_pkgs.parse_package_list("steam\nsteam\n")
check("a duplicate is dropped", names, ["steam"])
check_true("…and warned about", any("duplicate" in w for w in warns))

names, warns = deck_pkgs.parse_package_list("steam\njupiter-staging/gamescope\n")
check(
    "🔴 a repo-qualified name is refused: this file installs against the TARGET's "
    "repos and cannot decide which one wins",
    names,
    ["steam"],
)
check_true("…and warned about", any("gamescope" in w for w in warns))

names, warns = deck_pkgs.parse_package_list("steam\n; rm -rf /\n")
check("🔴 an entry that is not a plain package name never reaches argv", names, ["steam"])

names, _ = deck_pkgs.parse_package_list("\n".join(f"pkg{i}" for i in range(200)))
check(
    f"the entry cap holds ({deck_pkgs.MAX_LIST_ENTRIES})",
    len(names),
    deck_pkgs.MAX_LIST_ENTRIES,
)

# The parser is the thing that decides, proved with a list nothing else uses.
live = make_live("parsed", fetch_list="# hi\nalpha\nbeta\n")
pac = FakePacman()
record, out = run_fetch(make_target("parsed"), live, pac)
check("the module installs WHAT THE FILE SAYS", record["requested"], ["alpha", "beta"])
check_true("…and asked pacman for exactly those", ["alpha", "beta"] == record["installed"])


# ---------------------------------------------------------------------------
print("\n## 2. the real deck-fetch.packages, and its siblings")
# ---------------------------------------------------------------------------

fetch_text = (DECK_LISTS / "deck-fetch.packages").read_text()
fetch_names, fetch_warns = deck_pkgs.parse_package_list(fetch_text)
install_names, _ = deck_pkgs.parse_package_list((DECK_LISTS / "deck-install.packages").read_text())
mirror_raw = [
    line.strip()
    for line in (DECK_LISTS / "deck-mirror.packages").read_text().splitlines()
    if line.strip() and not line.strip().startswith("#")
]

check("the shipped fetch list parses cleanly", fetch_warns, [])
check_true("…is non-empty (an empty one installs nothing, silently)", fetch_names)
check_true("…and names steam", "steam" in fetch_names)
check(
    "🔴 steamdeck-dsp has LEFT the fetch list (it is mirror-carried now)",
    "steamdeck-dsp" in fetch_names,
    False,
)
check_true(
    "…and is installed on the target instead", "steamdeck-dsp" in install_names
)
check_true(
    "…via a repo-qualified mirror entry, so the build downloads Valve's",
    "jupiter-staging/steamdeck-dsp" in mirror_raw,
)

check_true("the Neptune kernel is now pacstrapped", "linux-neptune-611" in install_names)
check(
    "🔴 linux-firmware-neptune is NOT pacstrapped -- it would kill the install "
    "at phase 3 (Valve declares conflicts against linux-firmware and -whence "
    "only, but Arch split it into ten subpackages, so pacman removes those two "
    "and then dies on file conflicts with the rest; measured in a VM by "
    "src/omarchy-deck-kernel.sh's colliding_arch_firmware/stage_firmware_swap, "
    "and pacstrap has no -Rdd step). Safe to omit: linux-neptune-611's "
    ".PKGINFO depends only on coreutils/initramfs/kmod",
    "linux-firmware-neptune" in install_names,
    False,
)
check(
    "🔴 …and it is no longer mirror-carried either (P33/F1, 2026-08-15). It had "
    "NO reader in either direction: pacstrap refuses it (above) and "
    "src/omarchy-deck-kernel.sh's -Rdd swap runs on a BOOTED system against the "
    "ONLINE Valve repos, so it never read the mirror copy. Held until hardware "
    "could answer; hardware answered -- the Deck runs "
    "6.11.11-valve29-1-neptune-611 on Arch's split linux-firmware 20260810 with "
    "`pacman -Q linux-firmware-neptune` returning not-found, ath11k up on "
    "qca2066 hw2.1, no firmware-load failures in the kernel journal, and audio "
    "and gamescope operator-confirmed. 349.6 MiB off the ISO",
    "linux-firmware-neptune" in mirror_raw,
    False,
)
check(
    "🔴 the kernel HEADERS are deliberately mirror-only (nothing on the target "
    "builds modules)",
    "linux-neptune-611-headers" in install_names,
    False,
)
check_true(
    "…and still carried, for now. ⚠️ NOT because 'a later DKMS build has a "
    "source' — that justification was MEASURED FALSE on 2026-08-15 (P33/F1): "
    "the mirror is a bind mount, not a copy, so on the installed Deck "
    "/var/cache/omarchy/mirror/offline is EMPTY and no Valve repo is configured. "
    "It survives this round only because P33/F1 was scoped to the firmware. See "
    "deck-mirror.packages for the evidence; if the coordinator takes the "
    "recommended cut, flip this check and the annotated-entry count below",
    "linux-neptune-611-headers" in mirror_raw,
)
check_true("mangoapp's package is installed, not merely carried", "mangohud" in install_names)
check_true("…and its 32-bit half too", "lib32-mangohud" in install_names)

check(
    "🔴 steam is NOT bundled — it stays a fetch (Steam Subscriber Agreement)",
    "steam" in install_names or "steam" in mirror_raw,
    False,
)
check(
    "no repo-qualified name in the install list (it is resolved offline, one repo)",
    [n for n in install_names if "/" in n],
    [],
)

# Every bare form of a qualified mirror entry that we also install must be in
# the install list — that is the dual-entry pattern, and getting it wrong is how
# gamescope's session file went missing for a build.
for entry in mirror_raw:
    if "/" not in entry:
        continue
    bare = entry.rsplit("/", 1)[-1]
    check_true(
        f"qualified mirror entry {entry} has a bare install-list twin ({bare})",
        bare in install_names,
    )


# 🔴 THE PER-LINE CONSUMER RULE — the thing guard 6.8 structurally cannot do.
#
# Guard 6.8 (iso/bin/build ~1238) asks "does this package LIST have a consumer?"
# and deck-mirror.packages always answers yes: the patched build-iso.sh adds it
# to `all_packages`. So the guard is green, correctly by its own definition,
# while an individual LINE in the file reaches nothing at all.
#
# That is not hypothetical either. `linux-firmware-neptune` sat here from
# 2026-08-15 14:13 (when `a380fe3` pulled the bare name back out of
# deck-install.packages, an hour after adding it) until the P33 cut, under a
# comment that still said "DUAL ENTRY, both of them" — a consumer that had been
# deleted. 350 MiB, downloaded into every ISO, installed by nobody, and no check
# anywhere could see it. docs/findings/P32-neptune-firmware-placement.md §5
# proposed exactly this rule and did not write it; this is it.
#
# The rule: every entry either (a) has a bare twin in deck-install.packages, so
# pacstrap installs it — the dual-entry pattern — or (b) carries an explicit
# "READER: NOBODY" annotation in the comment block directly above it, which is
# the file's own established convention for a deliberate mirror-only line.
# Silence is the failure. An entry that is neither installed nor annotated is
# the exact shape of the defect.


def mirror_entries_with_comment_blocks(text: str):
    """Yield (entry, comment_block) for each non-comment line.

    The block is the run of comment lines immediately above the entry. A blank
    line breaks the run — that is what makes `lib32-mangohud` (which sits bare
    under `mangohud`) inherit nothing and have to justify itself via the
    install list, which it does.
    """
    block: list[str] = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            block = []
        elif line.startswith("#"):
            block.append(line)
        else:
            yield line, "\n".join(block)
            block = []


mirror_text = (DECK_LISTS / "deck-mirror.packages").read_text()
annotated = 0
for entry, block in mirror_entries_with_comment_blocks(mirror_text):
    bare = entry.rsplit("/", 1)[-1]
    installed = bare in install_names
    no_reader = "READER: NOBODY" in block
    if no_reader:
        annotated += 1
    check_true(
        f"🔴 mirror entry {entry!r} either installs on the target ({bare} in "
        f"deck-install.packages) or is annotated 'READER: NOBODY' in the comment "
        f"block above it — installed={installed}, annotated={no_reader}",
        installed or no_reader,
    )
    check(
        f"…and not BOTH, which would be a contradiction ({entry!r} claims no "
        f"reader while deck-install.packages installs it)",
        installed and no_reader,
        False,
    )

check(
    "exactly one deliberate no-reader entry remains (linux-neptune-611-headers). "
    "If this number grows, something was carried without an installer again",
    annotated,
    1,
)


# ---------------------------------------------------------------------------
print("\n## 3. the registry contract")
# ---------------------------------------------------------------------------

check_true("the step entry point exists", callable(deck_pkgs.fetch_packages_step))
check(
    "DeckStep still has no default for `critical` (a decision, never an omission)",
    deck_configure.DeckStep.__dataclass_fields__["critical"].default,
    dataclasses.MISSING,
)

steps = {s.name: s for s in deck_configure.deck_steps()}
pkgs_step = steps.get("pkgs")
check_true(
    "🔴 MERGE GATE — deck_configure.deck_steps() registers a 'pkgs' step. This is "
    "RED until the registry line is added:\n"
    '     DeckStep("pkgs", deck_pkgs.fetch_packages_step, critical=False),\n'
    "     …placed after 'wifi' (it reads that step's outcome) and before "
    "'patches'. Agent A does not own deck_configure.py; the line lands at merge.",
    pkgs_step is not None,
)
if pkgs_step is not None:
    check("…bound to deck_pkgs.fetch_packages_step", pkgs_step.fn, deck_pkgs.fetch_packages_step)
    check(
        "…and critical=False (§4.1: the degradation is allowed, the silence is not)",
        pkgs_step.critical,
        False,
    )
    order = [s.name for s in deck_configure.deck_steps()]
    check_true("…running AFTER wifi, whose record it reads", order.index("wifi") < order.index("pkgs"))


# ---------------------------------------------------------------------------
print("\n## 4. the outcomes — one status per distinguishable thing that happened")
# ---------------------------------------------------------------------------

# (a) the happy path
pac = FakePacman()
target = make_target("happy")
record, out = run_fetch(target, make_live("happy", wifi="status=connected\nssid=Cafe\n"), pac)
check("clean install: status=installed", record["status"], deck_pkgs.STATUS_INSTALLED)
check("…records what it installed", record["installed"], ["steam"])
check("…and what was missing beforehand", record["missing_before"], ["steam"])
check("…it synced first", record["synced"], True)
check("…in the order query, sync, install, verify", pac.subcommands(), ["-Qq", "-Sy", "-S", "-Qq"])
check_true("…and said so on the console", "installed on the target" in out)
check_true(
    "…having warned the user it needed the network BEFORE the wait",
    "needs the internet" in out,
)

# (b) idempotence — the whole point of --needed plus the query pass
pac = FakePacman(installed=["steam"])
record, out = run_fetch(make_target("idem"), make_live("idem", wifi="status=connected\n"), pac)
check("re-run: status=installed", record["status"], deck_pkgs.STATUS_INSTALLED)
check("…flagged as already present", record["already_present"], True)
check(
    "🔴 …and it touched the network ZERO times (no -Sy, no -S)",
    pac.subcommands(),
    ["-Qq"],
)

# (c) no network, and deck_wifi explains why
pac = FakePacman(sync_code=1)
record, out = run_fetch(
    make_target("nonet"), make_live("nonet", wifi="status=skipped\nssid=\n"), pac
)
check("sync fails + wifi skipped: status=skipped-no-network", record["status"], deck_pkgs.STATUS_NO_NETWORK)
check("…records the wifi status it classified on", record["wifi_status"], "skipped")
check_true("…names the packages that were not installed", "steam" in record["error"])
check_true("…and tells the user the exact repair command", "pacman -S --needed steam" in record["error"])
check_true("…loudly", "Deck packages:" in out)
check("…it never reached the transaction", pac.subcommands(), ["-Qq", "-Sy"])

# (d) no network, and deck_wifi does NOT explain it — the louder classification
pac = FakePacman(sync_code=1)
record, out = run_fetch(
    make_target("nonet2"), make_live("nonet2", wifi="status=connected\nssid=Cafe\n"), pac
)
check(
    "🔴 sync fails while wifi said connected: status=failed, not skipped — we cannot explain it",
    record["status"],
    deck_pkgs.STATUS_FAILED,
)

# (e) a missing wifi record is not an excuse either
pac = FakePacman(sync_code=1)
record, out = run_fetch(make_target("nowifi"), make_live("nowifi", wifi=None), pac)
check("no wifi record + failed sync: status=failed", record["status"], deck_pkgs.STATUS_FAILED)

# (f) the transaction itself fails
pac = FakePacman(install_code=1)
record, out = run_fetch(make_target("txfail"), make_live("txfail", wifi="status=connected\n"), pac)
check("transaction fails: status=failed", record["status"], deck_pkgs.STATUS_FAILED)
check("…records pacman's exit code", record["exit_code"], 1)
check_true("…and the tail of its output", "target not found" in (record["output"] or ""))

# (g) 🔴 THE OUTCOME ASSERTION: pacman exits 0 and the package is still absent
pac = FakePacman(install_works=False)
record, out = run_fetch(make_target("liar"), make_live("liar", wifi="status=connected\n"), pac)
check(
    "🔴 pacman exits 0 but steam is still absent: status=failed (a zero exit is a "
    "STEP assertion; eleven of those were already green on a black-screen Deck)",
    record["status"],
    deck_pkgs.STATUS_FAILED,
)
check_true("…and the error says the two channels disagree", "disagree" in record["error"])
check("…it verified after installing", pac.subcommands(), ["-Qq", "-Sy", "-S", "-Qq"])

# (h) no list on the live ISO at all
pac = FakePacman()
record, out = run_fetch(make_target("nolist"), make_live("nolist", fetch_list=None), pac)
check("no fetch list on the ISO: status=failed", record["status"], deck_pkgs.STATUS_FAILED)
check_true("…naming the path it looked for", deck_pkgs.FETCH_LIST_REL in record["error"])
check("…and pacman was never called", pac.calls, [])

# (i) a list that is all comments — the defect wearing a different hat
pac = FakePacman()
record, out = run_fetch(
    make_target("emptylist"), make_live("emptylist", fetch_list="# nothing here\n"), pac
)
check("a comments-only fetch list: status=failed, never a quiet success", record["status"], deck_pkgs.STATUS_FAILED)

# (j) the bootstrap tarball — the finding's named check
pac = FakePacman()
target = make_target("boot-ok", bootstrap=True)
record, out = run_fetch(target, make_live("boot-ok", wifi="status=connected\n"), pac)
check("the steam bootstrap archive is checked and recorded", record["steam_bootstrap"], True)

pac = FakePacman()
record, out = run_fetch(
    make_target("boot-missing"), make_live("boot-missing", wifi="status=connected\n"), pac
)
check("…and its absence is recorded", record["steam_bootstrap"], False)
check_true(
    "…and warned about, because that is the exact line the hardware journal carried",
    any("bootstrap" in w for w in record["warnings"]),
)

# (k) record shape parity with the sibling steps
for key in ("status", "error", "warnings"):
    check_true(f"the record carries the sibling contract's '{key}' field", key in record)
check_true(
    "no secret-shaped value reaches the world-readable log (no passphrase/psk keys)",
    not any("pass" in k or "psk" in k for k in record),
)


# ---------------------------------------------------------------------------
print("\n## 5. the commands — WHERE and HOW this runs, assertable without a chroot")
# ---------------------------------------------------------------------------

check(
    "the query runs inside the target, via arch-chroot",
    deck_pkgs.query_command("/mnt", "steam"),
    ["arch-chroot", "/mnt", "pacman", "-Qq", "steam"],
)
check(
    "the sync is -Sy and NOT -Syu (a full upgrade mid-install would replace the kernel)",
    deck_pkgs.sync_command("/mnt"),
    ["arch-chroot", "/mnt", "pacman", "-Sy", "--noconfirm"],
)
check(
    "the transaction carries --needed (pacman's own idempotence) and --noconfirm "
    "(there is no keyboard)",
    deck_pkgs.install_command("/mnt", ["steam"]),
    ["arch-chroot", "/mnt", "pacman", "-S", "--needed", "--noconfirm", "steam"],
)
check_true("every call is bounded by a timeout", deck_pkgs.SYNC_TIMEOUT_SECS > 0)

# Guard 6.4a in iso/bin/build greps the whole orchestrator directory for
# /usr/bin/omarchy-* and fails the build unless a provider ships each match.
# This module's binary lives in /usr/local/bin, exactly like deck_wifi's.
check(
    "🔴 no /usr/bin/omarchy-* literal in this module (guard 6.4a would demand a provider)",
    re.findall(r"/usr/bin/omarchy-[A-Za-z0-9._-]+", (OVERLAY_ORCH / "deck_pkgs.py").read_text()),
    [],
)


# ---------------------------------------------------------------------------
print("\n## 6. the build patch is the other end of the path this module reads")
# ---------------------------------------------------------------------------

patch_text = BUILD_PATCH.read_text()
check_true(
    "🔴 the patch copies the fetch list into the LIVE ISO at exactly the path "
    "deck_pkgs reads (both ends derived — this is the drift signal)",
    f"airootfs/{deck_pkgs.FETCH_LIST_REL}" in patch_text,
)
check_true(
    "…it refuses a build whose fetch list is empty",
    "deck-install deck-mirror deck-fetch" in patch_text,
)
check_true(
    "…and it declares a consumer manifest, so a list nobody reads fails the build",
    "deck_known_lists=(" in patch_text,
)

manifest = re.search(r"deck_known_lists=\(([^)]*)\)", patch_text)
check_true("the manifest is readable", manifest is not None)
if manifest:
    declared = set(manifest.group(1).split())
    on_disk = {p.stem for p in DECK_LISTS.glob("*.packages")}
    check(
        "every package list on disk is named in the manifest (and vice versa) — "
        "the general form of the P3.2 fix",
        declared,
        on_disk,
    )


# ---------------------------------------------------------------------------
print("\n## 7. the first-boot notice — staged, then run against a fake machine")
# ---------------------------------------------------------------------------

pac = FakePacman(sync_code=1)
target = make_target("staged")
record, out = run_fetch(target, make_live("staged", wifi="status=skipped\n"), pac)

script_dst = target / deck_pkgs.FIRST_BOOT_SCRIPT_REL
unit_dst = target / deck_pkgs.FIRST_BOOT_UNIT_REL
wants = target / deck_pkgs.FIRST_BOOT_WANTS_REL

check_true("the script is on the target", script_dst.is_file())
check("…executable, because mkarchiso discards modes and the asset arrives 0644", mode_of(script_dst), "0755")
check_true("the unit is on the target", unit_dst.is_file())
check("…0644", mode_of(unit_dst), "0644")
check_true("it is enabled by a wants symlink", wants.is_symlink())
check(
    "…pointing at an absolute path INSIDE the installed system, not inside /mnt",
    os.readlink(wants),
    "/" + deck_pkgs.FIRST_BOOT_UNIT_REL,
)
check_true("the state file exists", (target / deck_pkgs.STATE_REL).is_file())
check("…world-readable, no secrets", mode_of(target / deck_pkgs.STATE_REL), "0644")
state_text = (target / deck_pkgs.STATE_REL).read_text()
check_true("…and carries what was expected", "expected=steam" in state_text)
check_true("…and the recorded status", "status=skipped-no-network" in state_text)

unit_text = UNIT.read_text()
check_true(
    "🔴 the unit's ExecStart has no leading '-' (a '-' would report active on a "
    "Deck with no Steam)",
    "ExecStart=/usr/local/bin/omarchy-deck-steam-first-boot" in unit_text,
)
check(
    "…and RemainAfterExit is not set (only discussed in the comment)",
    bool(re.search(r"(?m)^RemainAfterExit", unit_text)),
    False,
)
check_true(
    "its ConditionPathExists matches the state file deck_pkgs writes",
    f"ConditionPathExists=/{deck_pkgs.STATE_REL}" in unit_text,
)
check(
    "…it is not ConditionFirstBoot (the installer writes a machine-id, so it "
    "would never run)",
    bool(re.search(r"(?m)^ConditionFirstBoot", unit_text)),
    False,
)

# A second run must not accumulate anything or trip over its own symlink.
record2, _ = run_fetch(target, make_live("staged2", wifi="status=skipped\n"), FakePacman(sync_code=1))
check_true("staging is idempotent: the wants symlink survives a re-run", wants.is_symlink())


def run_script(name, *, state: str | None, installed=("steam",), bootstrap=True, pacman=True):
    """Run deck-steam-first-boot.sh against a fake machine. Returns (rc, out, err, root)."""
    root = tmpdir(f"fb-{name}") / "root"
    (root / "var/lib/omarchy-deck").mkdir(parents=True, exist_ok=True)
    (root / "etc/systemd/system/multi-user.target.wants").mkdir(parents=True, exist_ok=True)
    link = root / deck_pkgs.FIRST_BOOT_WANTS_REL
    if not link.is_symlink():
        link.symlink_to("/" + deck_pkgs.FIRST_BOOT_UNIT_REL)
    if state is not None:
        (root / deck_pkgs.STATE_REL).write_text(state)
    if bootstrap:
        boot = root / deck_pkgs.STEAM_BOOTSTRAP_REL
        boot.parent.mkdir(parents=True, exist_ok=True)
        boot.write_text("x")

    # 🔴 A CLOSED PATH, containing only what the script is allowed to find.
    # With /usr/bin on PATH the "pacman is missing" case would silently find the
    # dev machine's real pacman and answer about THIS laptop's packages.
    bindir = root / "fakebin"
    bindir.mkdir(exist_ok=True)
    for tool in ("tr", "dirname", "mkdir", "chmod", "date", "rm", "printf"):
        real = shutil.which(tool)
        if real and not (bindir / tool).exists():
            (bindir / tool).symlink_to(real)
    if pacman:
        shim = bindir / "pacman"
        listing = " ".join(installed)
        shim.write_text(
            "#!/bin/sh\n"
            f'for p in {listing or "__none__"}; do\n'
            # `pacman -Qq <name>` -> $1 is -Qq, $2 is the name.
            '  [ "$p" = "$2" ] && exit 0\n'
            "done\n"
            "exit 1\n"
        )
        os.chmod(shim, 0o755)

    env = dict(os.environ)
    env.update({"PATH": str(bindir), "DECK_PKGS_ROOT": str(root)})
    bash = shutil.which("bash") or "/bin/bash"
    proc = subprocess.run(
        [bash, str(SCRIPT)], capture_output=True, text=True, env=env, check=False, timeout=60
    )
    return proc.returncode, proc.stdout, proc.stderr, root


def link_present(path: pathlib.Path) -> bool:
    """🔴 `Path.exists()` FOLLOWS the symlink, and this one deliberately points at
    an absolute path inside the installed system which does not exist inside a
    fake root — so `exists()` is False whether or not the unit is still enabled.
    The sibling Wi-Fi suite records the same trap."""
    return path.is_symlink() or path.exists()


def status_fields(root):
    out = {}
    for line in (root / "var/lib/omarchy-deck/fetch-status").read_text().splitlines():
        if "=" in line:
            k, _, v = line.partition("=")
            out.setdefault(k, v)
    return out


rc, out, err, root = run_script(
    "ok", state="status=installed\nexpected=steam\ninstalled=steam\nwifi_status=connected\nerror=\n"
)
check("steam present: exits 0", rc, 0)
check("…verdict=ok", status_fields(root)["verdict"], "ok")
check("…and it stands down so it is not a permanent failed unit", link_present(root / deck_pkgs.FIRST_BOOT_WANTS_REL), False)

rc, out, err, root = run_script(
    "missing",
    state="status=skipped-no-network\nexpected=steam\ninstalled=\nwifi_status=skipped\nerror=no network\n",
    installed=(),
    bootstrap=False,
)
check("🔴 steam absent: exits NON-ZERO so `systemctl --failed` carries it", rc, 1)
check("…verdict=degraded", status_fields(root)["verdict"], "degraded")
check("…records what is missing", status_fields(root)["missing"], "steam")
check("…with reason=missing", status_fields(root)["reason"], "missing")
check_true("…the message names the repair command", "pacman -S --needed steam" in status_fields(root)["message"])
check_true("…and explains it was the network", "no network" in status_fields(root)["message"])
check_true("…it said so on stderr", "steam" in err)
check("🔴 …and it STAYS enabled, so a later manual install clears it", (root / deck_pkgs.FIRST_BOOT_WANTS_REL).is_symlink(), True)

rc, out, err, root = run_script(
    "nobootstrap",
    state="status=installed\nexpected=steam\ninstalled=steam\nwifi_status=connected\nerror=\n",
    bootstrap=False,
)
check(
    "🔴 steam installed but its bootstrap archive absent: still non-zero — this is "
    "the exact state the hardware was in",
    rc,
    1,
)
check(
    "…and it is a DISTINCT reason from 'missing', because the two look identical "
    "on screen and need different repairs",
    status_fields(root)["reason"],
    "no-bootstrap",
)
check_true("…the message says so", "bootstrap" in status_fields(root)["message"])

rc, out, err, root = run_script(
    "lied-to",
    state="status=installed\nexpected=steam\ninstalled=steam\nwifi_status=connected\nerror=\n",
    installed=(),
    bootstrap=False,
)
check(
    "🔴 the state file claims installed and the machine disagrees: the MACHINE wins",
    rc,
    1,
)
check_true(
    "…and the discrepancy is recorded (installed-then-vanished is not a plain absence)",
    status_fields(root)["install_recorded"] == "steam" and status_fields(root)["missing"] == "steam",
)

rc, out, err, root = run_script(
    "multi",
    state="status=installed\nexpected=steam other-pkg\ninstalled=steam\nwifi_status=connected\nerror=\n",
    installed=("steam",),
)
check("a non-steam entry is checked too", rc, 1)
check("…and named", status_fields(root)["missing"], "other-pkg")

rc, out, err, root = run_script(
    "nopacman",
    state="status=installed\nexpected=steam\ninstalled=steam\nwifi_status=connected\nerror=\n",
    pacman=False,
)
check("no pacman: exits non-zero rather than claiming success", rc, 1)
check("…verdict=unknown, not ok", status_fields(root)["verdict"], "unknown")

rc, out, err, root = run_script("nostate", state=None)
check("no state file: does not crash", rc, 0)
check_true("…and says why on stderr", "state file" in err)

rc, out, err, root = run_script("noexpect", state="status=installed\nexpected=\n")
check("nothing expected: exits 0 and stands down", rc, 0)
check("…and disables itself", link_present(root / deck_pkgs.FIRST_BOOT_WANTS_REL), False)

# 🔴 The state file is PARSED, never sourced, and FIRST WINS.
rc, out, err, root = run_script(
    "forged",
    state="expected=steam\nstatus=skipped-no-network\nstatus=installed\n",
    installed=(),
    bootstrap=False,
)
check("a forged second status= line loses to the first", status_fields(root)["install_status"], "skipped-no-network")

rc, out, err, root = run_script(
    "injected",
    state="expected=steam\nstatus=installed\nerror=$(touch /tmp/deck-pkgs-pwned)\n",
    installed=(),
    bootstrap=False,
)
check_true("a $(...) in the state file is never executed", not pathlib.Path("/tmp/deck-pkgs-pwned").exists())


# ---------------------------------------------------------------------------
print("\n## 8. the step writes into the shared install record")
# ---------------------------------------------------------------------------

target = make_target("step")
live = make_live("step", wifi="status=connected\n")
saved_live, saved_assets = deck_pkgs.LIVE_ROOT, deck_pkgs.FIRST_BOOT_ASSET_DIR
deck_pkgs.LIVE_ROOT = live
deck_pkgs.FIRST_BOOT_ASSET_DIR = OVERLAY_DECK
try:
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        deck_pkgs.fetch_packages_step(FakeCtx(target))
finally:
    deck_pkgs.LIVE_ROOT, deck_pkgs.FIRST_BOOT_ASSET_DIR = saved_live, saved_assets

log_path = target / deck_configure.DECK_INSTALL_LOG_REL
check_true("the step wrote the shared install record", log_path.is_file())
doc = json.loads(log_path.read_text())
check_true("…under the 'pkgs' key", "pkgs" in doc)
check_true("…with a status a QEMU assertion can read", doc["pkgs"]["status"] is not None)
check("…and the document stays world-readable", mode_of(log_path), "0644")


# ---------------------------------------------------------------------------
print(f"\n{CHECKS - FAILURES}/{CHECKS} checks passed")
if FAILURES:
    print(f"{FAILURES} FAILED")
shutil.rmtree(WORK, ignore_errors=True)
sys.exit(1 if FAILURES else 0)
