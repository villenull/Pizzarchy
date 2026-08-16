#!/usr/bin/env python3
"""Unit tests for `configure_deck`'s `steam_prewarm` step (`deck_steam_prewarm.py`).

No VM, no root, no network, no chroot, no ISO build. Run directly:

    python3 test-deck-steam-prewarm.py

WHAT THIS SUITE IS ACTUALLY FOR
===============================

`docs/PROGRESS.md` §5.35 measured the black first boot: Steam spends ~2 minutes
downloading and extracting a client update the packaged bootstrap does not
carry. `deck_steam_prewarm.py` moves that download into the install. The
mechanism was measured against Valve's real updater (see that module's
docstring); this suite defends the parts of it that a "does it call urlopen?"
test would pass while the product stayed broken:

1. 🔴 **The manifest's own shape decides what is fetched, not a hard-coded
   list.** §1 and §2 feed the parser the real document's structure -- including
   the `kvsign2` / `kvsignatures` blocks that sit next to the packages and are
   NOT packages -- and the two entry shapes (`zipvz` present and absent) whose
   file name and hash field differ. Getting that rule backwards downloads ~490
   MiB of files Steam then ignores, and every step assertion still passes.

2. 🔴 **A file only becomes visible when it is complete AND correct.** §5 has
   the server return the right number of wrong bytes; the target must be left
   with no such file and no `.part` debris. Steam checks size only, so a
   same-length corruption we let through is a file it accepts and cannot use.

3. 🔴 **Nothing root-owned may be left in a user's home.** §6 makes `chown`
   fail and requires that no file survives it. This runs as an ordinary user
   against a `/etc/passwd` naming that user's own uid, so the REAL
   `deck_user.resolve_target_user` path is exercised rather than a mock of it.

4. 🔴 **A re-run must open zero connections.** §4 counts them.

⚠️ §3's registry check is a **MERGE GATE**. This agent does not own
`deck_configure.py`; the registry line is added when this work is merged. Until
then that one check is red ON PURPOSE, and its failure message says so. Do not
"fix" it by deleting it.
"""

from __future__ import annotations

import contextlib
import hashlib
import io
import json
import os
import pathlib
import shutil
import stat
import sys
import tempfile
import types

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


# ---------------------------------------------------------------------------
# Harness: rebuild the orchestrator package shape around the modules
# ---------------------------------------------------------------------------

WORK = pathlib.Path(tempfile.mkdtemp(prefix="deck-prewarm-test-"))

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

from orchestrator import deck_configure, deck_pkgs, deck_steam_prewarm  # noqa: E402

P = deck_steam_prewarm

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


def make_target(name: str, *, bootstrap: bool = True, user: bool = True) -> pathlib.Path:
    """A fake install target: /etc/passwd naming THIS process's own uid (so the
    real chown path can run unprivileged), a home directory, and optionally
    Steam's bootstrap tarball where the `steam` package puts it."""
    target = tmpdir(name) / "mnt"
    (target / "etc").mkdir(parents=True, exist_ok=True)
    passwd = "root:x:0:0::/root:/bin/bash\n"
    if user:
        passwd += f"deck:x:{os.getuid()}:{os.getgid()}::/home/deck:/bin/bash\n"
        (target / "home/deck").mkdir(parents=True, exist_ok=True)
    (target / "etc/passwd").write_text(passwd)
    if bootstrap:
        boot = target / P.STEAM_BOOTSTRAP_REL
        boot.parent.mkdir(parents=True, exist_ok=True)
        boot.write_text("not really a tarball")
    return target


def make_live(name: str, *, wifi: str | None = None) -> pathlib.Path:
    live = tmpdir(name) / "live"
    live.mkdir(parents=True, exist_ok=True)
    if wifi is not None:
        outcome = live / "root/deck-wifi-outcome"
        outcome.parent.mkdir(parents=True, exist_ok=True)
        outcome.write_text(wifi)
    return live


# --- a fake CDN -------------------------------------------------------------


class FakeCDN:
    """Serves a manifest and package bytes, and RECORDS EVERY URL OPENED.

    Recording is the point: "a re-run downloads nothing" is a statement about
    calls not made, and only a counting opener can prove it.
    """

    def __init__(self, files: dict[str, bytes], *, fail: set[str] = frozenset()):
        self.files = files
        self.fail = set(fail)
        self.opened: list[str] = []

    def __call__(self, url, timeout):
        self.opened.append(url)
        assert url.startswith("https://"), url
        name = url[len(P.UPDATE_HOST_BASE):]
        if name in self.fail:
            raise OSError(f"simulated transport failure for {name}")
        if name not in self.files:
            raise OSError(f"404 {name}")
        return io.BytesIO(self.files[name])

    @property
    def package_opens(self) -> list[str]:
        return [u for u in self.opened if not u.endswith(P.MANIFEST_NAME)]


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def synth_manifest(entries: list[tuple[str, bytes, bool]], version="1785799196") -> tuple[str, dict]:
    """Build a manifest plus the byte payloads it describes.

    ``entries`` is (key, payload, use_zipvz). The vz shape carries the payload
    length in its own file name, exactly as the real CDN's do.
    """
    files: dict[str, bytes] = {}
    body = [f'"{P.UPDATE_PLATFORM}"', "{", f'\t"version"\t\t"{version}"']
    for key, payload, use_vz in entries:
        plain = f"{key}.zip.{'a' * 40}"
        if use_vz:
            vz = f"{key}.zip.vz.{'b' * 40}_{len(payload)}"
            files[vz] = payload
            body += [
                f'\t"{key}"',
                "\t{",
                f'\t\t"file"\t\t"{plain}"',
                f'\t\t"size"\t\t"{len(payload) * 2}"',
                f'\t\t"sha2"\t\t"{"0" * 64}"',
                f'\t\t"zipvz"\t\t"{vz}"',
                f'\t\t"sha2vz"\t\t"{sha(payload)}"',
                "\t}",
            ]
        else:
            files[plain] = payload
            body += [
                f'\t"{key}"',
                "\t{",
                f'\t\t"file"\t\t"{plain}"',
                f'\t\t"size"\t\t"{len(payload)}"',
                f'\t\t"sha2"\t\t"{sha(payload)}"',
                "\t}",
            ]
    body += ["}", '"kvsign2"', "{", f'\t"{P.UPDATE_PLATFORM}"\t\t"{"c" * 128}"', "}"]
    text = "\n".join(body) + "\n"
    files[P.MANIFEST_NAME] = text.encode()
    return text, files


@contextlib.contextmanager
def opener(cdn):
    saved = P.open_url
    P.open_url = cdn
    try:
        yield cdn
    finally:
        P.open_url = saved


def run_step(ctx, cdn, live, budget=P.PREWARM_BUDGET_SECS) -> dict:
    buf = io.StringIO()
    with opener(cdn), contextlib.redirect_stdout(buf):
        return P.prewarm_steam(ctx, live, budget)


# ---------------------------------------------------------------------------
print("\n## 1. the REAL manifest's structure is parsed, and its signature blocks are not packages")
# ---------------------------------------------------------------------------

# Verbatim excerpt of https://client-update.steamstatic.com/steam_client_steamdeck_stable_ubuntu12
# fetched 2026-08-16 (full document: 9,866 bytes, 28 package entries, 22 with a
# zipvz). Three entries kept -- one of each shape plus a second vz -- with the
# real trailing kvsign blocks, because those blocks are the thing a naive
# "walk every top-level block" parser tries to download.
REAL_EXCERPT = '''"ubuntu12"
{
	"version"		"1785799196"
	"tenfoot_images_all"
	{
		"file"		"tenfoot_images_all.zip.86419c7a56c12dd107b5e0d46f50c8a9b121f3cc"
		"size"		"6582204"
		"sha2"		"990676bc29d01736477c6b571b5048258a6156284ef242503112fc68567cbf01"
		"zipvz"		"tenfoot_images_all.zip.vz.193cb8c4eb4446698ea2c0a9e8c4e6b6a623dac7_5572671"
		"sha2vz"		"e1fee3beffa9d08a415a35ddc7d3141af6c44269c67e67aa0a3eea6e56889bd7"
	}
	"strings_en_all"
	{
		"file"		"strings_en_all.zip.071a3f6839c3b8d574731101f2862d5ed72ab2e4"
		"size"		"114329"
		"sha2"		"fe73301f09a423c3114575b54b929c5cc0d1aacc80f1067259e551ffd1c82a07"
	}
	"sdl3_steamrt_ubuntu12"
	{
		"file"		"sdl3_steamrt_ubuntu12.zip.c79773f2ff09565c0c80308f270971156958648c"
		"size"		"690"
		"sha2"		"f5d6c6bb2decdd8041106f28a67e4e08867486112a54f6893c7bf3504036f944"
	}
}
"kvsign2"
{
	"ubuntu12"		"7827f5d5cf537de0de15a7f5619f2047285f3fd5ca39b013fb3ac79a14c36cc8"
}
"kvsignatures"
{
	"ubuntu12"		"d07c79a8e2a8753e1c4477c3114a808ee7403c4aeefab9425bc0b0448699f09a"
}
'''

packages, version, warns = P.manifest_packages(REAL_EXCERPT)
check("the manifest's client version is read", version, "1785799196")
check("only the package entries are returned (kvsign* are not packages)", len(packages), 3)
check("…and parsing the real document warns about nothing", warns, [])
by_key = {p["key"]: p for p in packages}

# 🔴 THE RULE MEASURED AGAINST VALVE'S UPDATER: zipvz wins, and its hash is
# sha2vz. A parser that took `file`+`sha2` here downloads a file the updater
# never looks for, and every step assertion still passes.
check(
    "a zipvz entry is fetched as the .vz name",
    by_key["tenfoot_images_all"]["file"],
    "tenfoot_images_all.zip.vz.193cb8c4eb4446698ea2c0a9e8c4e6b6a623dac7_5572671",
)
check(
    "…and verified against sha2vz, not sha2",
    by_key["tenfoot_images_all"]["sha256"],
    "e1fee3beffa9d08a415a35ddc7d3141af6c44269c67e67aa0a3eea6e56889bd7",
)
# 🔴 And the size that matters is the .vz name's trailing _<digits>, NOT the
# manifest's `size` (which is the uncompressed zip: 6,582,204 vs 5,572,671).
check("…and its expected size comes from the .vz name", by_key["tenfoot_images_all"]["size"], 5572671)

check(
    "an entry with no zipvz is fetched as `file`",
    by_key["strings_en_all"]["file"],
    "strings_en_all.zip.071a3f6839c3b8d574731101f2862d5ed72ab2e4",
)
check(
    "…and verified against sha2",
    by_key["strings_en_all"]["sha256"],
    "fe73301f09a423c3114575b54b929c5cc0d1aacc80f1067259e551ffd1c82a07",
)
check("…with the manifest's own size", by_key["strings_en_all"]["size"], 114329)

# The 690-byte sdl3 file is the one whose sha256 was checked by hand against a
# real download (module docstring); keeping it here ties the suite to that
# measurement.
check("…for the entry whose hash was verified by hand too", by_key["sdl3_steamrt_ubuntu12"]["size"], 690)


# ---------------------------------------------------------------------------
print("\n## 2. a hostile or broken manifest cannot become a path or a URL")
# ---------------------------------------------------------------------------

for bad in ("../../etc/passwd", "a/b", "..", ".hidden", "", "x" * 300, "name with space"):
    check(f"rejected as a package file name: {bad!r}", P.valid_package_name(bad), False)
check("accepted: a real package file name", P.valid_package_name("steam_ubuntu12.zip.vz.90b0_338"), True)

traversal = REAL_EXCERPT.replace(
    "strings_en_all.zip.071a3f6839c3b8d574731101f2862d5ed72ab2e4", "../../../../etc/shadow"
)
packages2, _, warns2 = P.manifest_packages(traversal)
check("a traversal name drops that entry…", len(packages2), 2)
check_true("…loudly", any("not a plain package file name" in w for w in warns2))

nohash = REAL_EXCERPT.replace(
    '"sha2"		"fe73301f09a423c3114575b54b929c5cc0d1aacc80f1067259e551ffd1c82a07"',
    '"sha2"		"nope"',
)
packages3, _, warns3 = P.manifest_packages(nohash)
check("an entry whose hash is not a sha256 is dropped…", len(packages3), 2)
check_true("…loudly", any("not a sha256" in w for w in warns3))

for broken, why in (
    ('"a"\n{\n"b" "c"\n', "unbalanced {"),
    ('"a" "b"\n}\n', "unbalanced }"),
    ('"a"\n{\n"b" "c"\n}\n"a"\n{\n', "value then block for one key"),
):
    try:
        P.manifest_packages(broken)
        check(f"a malformed manifest raises ({why})", "no exception", "DeckSteamPrewarmError")
    except P.DeckSteamPrewarmError:
        check(f"a malformed manifest raises ({why})", True, True)

try:
    P.manifest_packages('"ubuntu12"\n{\n"version" "1"\n}\n')
    check("a manifest with no packages raises", "no exception", "DeckSteamPrewarmError")
except P.DeckSteamPrewarmError:
    check("a manifest with no packages raises", True, True)


# ---------------------------------------------------------------------------
print("\n## 3. MERGE GATE — the registry must call this step")
# ---------------------------------------------------------------------------

registry = deck_configure.deck_steps()
entry = next((s for s in registry if s.name == "steam_prewarm"), None)
if entry is None:
    print(
        "FAIL configure_deck registers a 'steam_prewarm' step: NOT REGISTERED.\n"
        "     ⚠️ MERGE GATE — this agent does not own deck_configure.py. The\n"
        "     coordinator adds:\n"
        "         DeckStep(\"steam_prewarm\", deck_steam_prewarm.prewarm_steam_step, critical=False),\n"
        "     Red until then is expected. Do not delete this check."
    )
    FAILURES += 1
    CHECKS += 1
else:
    check("configure_deck registers a 'steam_prewarm' step", entry.name, "steam_prewarm")
    check("…pointing at prewarm_steam_step", entry.fn, P.prewarm_steam_step)
    # A slow ~490 MiB download must never be able to abort a finished install.
    check("…and it is NOT critical", entry.critical, False)


# ---------------------------------------------------------------------------
print("\n## 4. the happy path, and a re-run that opens nothing")
# ---------------------------------------------------------------------------

text, files = synth_manifest(
    [("alpha", b"A" * 4096, True), ("beta", b"B" * 700, False), ("gamma", b"C" * 33, True)]
)
target = make_target("happy")
live = make_live("happy", wifi="status=connected\n")
cdn = FakeCDN(files)
record = run_step(FakeCtx(target), cdn, live)

check("status", record["status"], P.STATUS_PREWARMED)
check("every manifest entry was expected", record["expected"], 3)
check("every one was downloaded", record["downloaded"], 3)
check("bytes recorded", record["downloaded_bytes"], 4096 + 700 + 33)
check("the client version is recorded for a support reader", record["client_version"], "1785799196")
check("the resolved user is recorded", record["user"], "deck")
check("no error", record["error"], None)
check("no warnings", record["warnings"], [])

pkgdir = target / "home/deck" / P.PACKAGE_DIR_REL
check("the package dir is where Steam's updater looks", record["package_dir"], str(pkgdir))
landed = sorted(p.name for p in pkgdir.iterdir())
check("exactly the three files landed", len(landed), 3)
check_true("…and nothing is a .part leftover", not any(n.endswith(P.PART_SUFFIX) for n in landed))
check("…with the right bytes", (pkgdir / f"beta.zip.{'a' * 40}").read_bytes(), b"B" * 700)
check("…world-readable, not executable", mode_of(pkgdir / f"beta.zip.{'a' * 40}"), "0644")

# The directory chain the updater unpacks into, created with the modes the real
# updater produced (Steam 0700, package/ 0755).
check("~/.local/share/Steam mode", mode_of(target / "home/deck" / P.STEAM_DIR_REL), "0700")
check("~/.local/share/Steam/package mode", mode_of(pkgdir), "0755")

# 🔴 IDEMPOTENCE. CLAUDE.md requires re-runnable scripts, and the SSH
# iterate-in-place loop depends on it. A second run must fetch the manifest and
# then stop.
cdn2 = FakeCDN(files)
record2 = run_step(FakeCtx(target), cdn2, live)
check("a re-run is still 'prewarmed'", record2["status"], P.STATUS_PREWARMED)
check("…finds every file already present", record2["already_present"], 3)
check("…downloads nothing", record2["downloaded"], 0)
check("…and opens ZERO package URLs", cdn2.package_opens, [])


# ---------------------------------------------------------------------------
print("\n## 5. a file that is not exactly right is replaced, and never half-visible")
# ---------------------------------------------------------------------------

# Same length, wrong bytes: what Steam's size-only check would accept.
corrupt = pkgdir / f"beta.zip.{'a' * 40}"
corrupt.write_bytes(b"X" * 700)
cdn3 = FakeCDN(files)
record3 = run_step(FakeCtx(target), cdn3, live)
check("a same-length corruption is detected", record3["downloaded"], 1)
check("…and repaired", corrupt.read_bytes(), b"B" * 700)
check("…leaving the status clean", record3["status"], P.STATUS_PREWARMED)

# Now a server that lies: right length, wrong content. Nothing may land.
lying = dict(files)
lying[f"gamma.zip.vz.{'b' * 40}_33"] = b"Z" * 33
target2 = make_target("liar")
cdn4 = FakeCDN(lying)
record4 = run_step(FakeCtx(target2), cdn4, make_live("liar", wifi="status=connected\n"))
pkgdir2 = target2 / "home/deck" / P.PACKAGE_DIR_REL
check("a hash mismatch is partial, not success", record4["status"], P.STATUS_PARTIAL)
check("…and names the file that failed", record4["missing_after"], [f"gamma.zip.vz.{'b' * 40}_33"])
check_true("…which is reported, not swallowed", any("sha256" in w for w in record4["warnings"]))
check("…the other two still landed (Steam fetches only what is missing)", record4["downloaded"], 2)
check_true("…the bad file is absent", not (pkgdir2 / f"gamma.zip.vz.{'b' * 40}_33").exists())
check("…and no .part debris is left in the user's home",
      [p.name for p in pkgdir2.iterdir() if p.name.endswith(P.PART_SUFFIX)], [])

# A transport failure has the same shape.
target3 = make_target("dead")
cdn5 = FakeCDN(files, fail={f"alpha.zip.vz.{'b' * 40}_4096"})
record5 = run_step(FakeCtx(target3), cdn5, make_live("dead", wifi="status=connected\n"))
check("a dead transfer is partial", record5["status"], P.STATUS_PARTIAL)
check("…and the rest still prewarm", record5["downloaded"], 2)


# ---------------------------------------------------------------------------
print("\n## 6. ownership — nothing root-owned may be left in a user's home")
# ---------------------------------------------------------------------------

# The happy path above ran the REAL os.chown against this process's own uid,
# resolved through the REAL deck_user.resolve_target_user from a real
# /etc/passwd. Assert it actually landed on the target user.
st = os.stat(pkgdir / f"beta.zip.{'a' * 40}")
check("downloaded files are owned by the target user", (st.st_uid, st.st_gid), (os.getuid(), os.getgid()))
st_dir = os.stat(target / "home/deck" / P.STEAM_DIR_REL)
check("…as are the directories this step created", (st_dir.st_uid, st_dir.st_gid), (os.getuid(), os.getgid()))

# 🔴 And when chown cannot be done, the bytes must not survive it.
target4 = make_target("nochown")
cdn6 = FakeCDN(files)
saved_chown = P.set_owner


def refuse(path, uid, gid):
    raise PermissionError("simulated: not root")


P.set_owner = refuse
try:
    record6 = run_step(FakeCtx(target4), cdn6, make_live("nochown", wifi="status=connected\n"))
finally:
    P.set_owner = saved_chown

check("a chown failure fails the step", record6["status"], P.STATUS_FAILED)
check_true("…and says so", "could not create" in (record6["error"] or ""))
steamdir4 = target4 / "home/deck" / P.STEAM_DIR_REL
check_true(
    "…before a single byte was downloaded (the dirs are checked first)",
    cdn6.package_opens == [],
)
if steamdir4.exists():
    check("…and nothing was left in the user's home", sorted(p.name for p in steamdir4.rglob("*")), [])
else:
    check("…and nothing was left in the user's home", True, True)


# ---------------------------------------------------------------------------
print("\n## 7. the four ways this step correctly does nothing")
# ---------------------------------------------------------------------------

# (a) defer_provisioning: the account does not exist yet, by design.
target5 = make_target("deferred", user=False)
cdn7 = FakeCDN(files)
record7 = run_step(FakeCtx(target5, username="", defer_provisioning=True), cdn7, make_live("deferred"))
check("a deferred install is skipped, not failed", record7["status"], P.STATUS_DEFERRED)
check("…and touches the network zero times", cdn7.opened, [])
check_true("…explaining why", "defer_provisioning" in (record7["error"] or ""))

# (b) no Steam on the target: nothing for these files to feed.
target6 = make_target("nosteam", bootstrap=False)
cdn8 = FakeCDN(files)
record8 = run_step(FakeCtx(target6), cdn8, make_live("nosteam"))
check("no Steam bootstrap tarball -> skipped", record8["status"], P.STATUS_NO_STEAM)
check("…and no download is attempted", cdn8.opened, [])
check_true("…pointing at the step that owns it", "'pkgs'" in (record8["error"] or ""))

# (c) the manifest cannot be fetched. deck_wifi's recorded status CLASSIFIES
#     it, exactly as deck_pkgs.py does -- and is never allowed to skip the try.
target7 = make_target("offline")
cdn9 = FakeCDN({}, fail={P.MANIFEST_NAME})
record9 = run_step(FakeCtx(target7), cdn9, make_live("offline", wifi="status=skipped\n"))
check("no network + wifi said 'skipped' -> skipped-no-network", record9["status"], P.STATUS_NO_NETWORK)
check("…and the attempt WAS made", len(cdn9.opened), 1)
check("…recording what the Wi-Fi screen said", record9["wifi_status"], "skipped")

target8 = make_target("weird")
cdn10 = FakeCDN({}, fail={P.MANIFEST_NAME})
record10 = run_step(FakeCtx(target8), cdn10, make_live("weird", wifi="status=connected\n"))
check("an unexplained fetch failure is the louder 'failed'", record10["status"], P.STATUS_FAILED)

# (d) not enough disk. Filling a target's root partition mid-install would be
#     far worse than a slow first boot.
target9 = make_target("full")
cdn11 = FakeCDN(files)
saved_shutil = P.shutil
P.shutil = types.SimpleNamespace(disk_usage=lambda path: types.SimpleNamespace(free=1024))
try:
    record11 = run_step(FakeCtx(target9), cdn11, make_live("full", wifi="status=connected\n"))
finally:
    P.shutil = saved_shutil
check("a nearly full target is skipped", record11["status"], P.STATUS_NO_SPACE)
check("…without downloading anything", cdn11.package_opens, [])
check("…naming what would have been fetched", len(record11["missing_after"]), 3)


# ---------------------------------------------------------------------------
print("\n## 8. the time budget stops, it does not hang or discard")
# ---------------------------------------------------------------------------

target10 = make_target("budget")
cdn12 = FakeCDN(files)
record12 = run_step(FakeCtx(target10), cdn12, make_live("budget", wifi="status=connected\n"), budget=-1)
check("an expired budget is partial", record12["status"], P.STATUS_PARTIAL)
check("…with everything left to Steam", len(record12["missing_after"]), 3)
check_true("…and says the budget was the cause", "budget expired" in (record12["error"] or ""))


# ---------------------------------------------------------------------------
print("\n## 9. constants that must not drift, and the step's install record")
# ---------------------------------------------------------------------------

# Deliberately duplicated rather than imported (see the module docstring); this
# is the check that stops the duplication being silent drift.
check(
    "the Steam bootstrap path agrees with deck_pkgs'",
    P.STEAM_BOOTSTRAP_REL,
    deck_pkgs.STEAM_BOOTSTRAP_REL,
)
# docs/PROGRESS.md §5.35 read this exact manifest name off the Deck.
check(
    "the manifest name is the branch the hardware asked for",
    P.MANIFEST_NAME,
    "steam_client_steamdeck_stable_ubuntu12",
)
check("the update host is the one baked into Valve's updater",
      P.UPDATE_HOST_BASE, "https://client-update.steamstatic.com/")
check("…and it is HTTPS, because the signed manifest's signature is not checked here",
      P.UPDATE_HOST_BASE.startswith("https://"), True)
try:
    P.open_url("http://client-update.steamstatic.com/x", 1)
    check("a non-HTTPS URL is refused", "no exception", "DeckSteamPrewarmError")
except P.DeckSteamPrewarmError:
    check("a non-HTTPS URL is refused", True, True)

target11 = make_target("record")
cdn13 = FakeCDN(files)
buf = io.StringIO()
saved_live = P.LIVE_ROOT
P.LIVE_ROOT = make_live("record", wifi="status=connected\n")
try:
    with opener(cdn13), contextlib.redirect_stdout(buf):
        P.prewarm_steam_step(FakeCtx(target11))
finally:
    P.LIVE_ROOT = saved_live

log_path = target11 / deck_configure.DECK_INSTALL_LOG_REL
check_true("the step wrote the shared install record", log_path.is_file())
doc = json.loads(log_path.read_text())
check_true("…under the 'steam_prewarm' key", "steam_prewarm" in doc)
check("…with a status an assertion can read", doc["steam_prewarm"]["status"], P.STATUS_PREWARMED)
check("…and the document stays world-readable", mode_of(log_path), "0644")


# ---------------------------------------------------------------------------
print(f"\n{CHECKS - FAILURES}/{CHECKS} checks passed")
if FAILURES:
    print(f"{FAILURES} FAILED")
shutil.rmtree(WORK, ignore_errors=True)
sys.exit(1 if FAILURES else 0)
