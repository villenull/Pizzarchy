"""Pre-fetch Steam's client update into the target's home, at install time.

SHIPPED AS ``/usr/share/omarchy-iso/orchestrator/deck_steam_prewarm.py``. The
``steam_prewarm`` step registered in ``deck_configure.deck_steps``.

🔴 WHY THIS FILE EXISTS: THE BLACK FIRST BOOT IS A DOWNLOAD
===========================================================

``docs/PROGRESS.md`` §5.35, read off the installed Deck's own
``~/.local/share/Steam/logs/bootstrap_log.txt``:

===========  ==========================================================
15:08:15     ``steam -gamepadui`` starts, ``Downloading Update...``
15:08:16     relaunch after the connectivity race, retry succeeds
15:09:51     ``Extracting package...``          <- 95 s of DOWNLOADING
15:10:14     ``Update complete, launching...``  <- 23 s of extracting
15:10:18     the new client starts (updater built Aug 3; the packaged
             bootstrap's is Jun 24)
===========  ==========================================================

Two minutes of black panel on a device that has just told the user it finished
installing. ``deck_pkgs.py`` put the ``steam`` **package** on the target and
``src/deck-session.sh`` fixed the connectivity race; neither removes the
**client update on top**, which is a separate ~490 MiB download from Valve that
the packaged bootstrap tarball deliberately does not contain.

This step moves that download into the install, where the installer already has
a screen and a progress indicator, so first boot has nothing left to fetch.

THE MECHANISM -- MEASURED, NOT INFERRED (2026-08-16, dev machine)
=================================================================

The updater in ``bootstraplinux_ubuntu12_32.tar.xz`` (``ubuntu12_32/steam``,
32-bit, closed source) was run twice against two throwaway ``$HOME``\\ s, from
Arch's ``steam 1.0.0.87``, and its own ``bootstrap_log.txt`` read back:

**Run 1 -- empty ``package/``.** It fetched
``https://client-update.steamstatic.com/steam_client_ubuntu12``, logged one
line per package::

    Package file tenfoot_images_all.zip.vz.193cb8c4...5572671 missing or incorrect size

then ``Downloading update (4,034 of 502,420 KB)...`` up to 502,420 KB, then
``Extracting package...``. **81 s wall clock** (10:31:32 -> 10:32:53).

**Run 2 -- the 28 package files from run 1 copied into a fresh
``~/.local/share/Steam/package/`` and NOTHING else.** Verbatim::

    [10:34:52] Verifying installation...
    [10:34:52] Unable to read and verify install manifest .../steam_client_ubuntu12.installed
    [10:34:52] Downloading manifest: https://client-update.steamstatic.com/steam_client_ubuntu12
    [10:34:53] Downloaded new manifest: /steam_client_ubuntu12 version 1785799196, installed version 0, existing pending version 0
    [10:34:53] Download Complete.
    [10:34:53] uninstalled manifest found in .../package/steam_client_ubuntu12 (1).
    [10:34:53] Extracting package...
    [10:35:07] Update complete, launching...

**Zero** ``missing or incorrect size`` lines, **zero** ``Downloading update``
lines, **15 s** instead of 81 s. The updater checks each package file that is
already in ``package/`` and downloads only what is absent or the wrong size.
That is the whole of this module's premise, and it is the measurement, not a
reading of documentation.

Three more facts fell out of the same two runs, and each one is load-bearing
below:

1. **Which file to fetch per manifest entry.** If the entry has a ``zipvz``
   key, the updater fetches *that* name (the LZMA-compressed form) and the
   matching hash is ``sha2vz``; if it does not, it fetches ``file`` and the
   hash is ``sha2``. Verified by ``sha256sum`` on three of the downloaded
   files against all three manifest fields -- see ``choose_download``.
2. **The expected byte size of a ``zipvz`` file is the trailing ``_<digits>``
   of its own name** (``..._3588568`` is 3,588,568 bytes on disk); the
   manifest's ``size`` field is the *uncompressed* zip's size and does not
   match what lands. Getting this backwards would make every prewarmed file
   look wrong.
3. **The manifest saved into ``package/`` is byte-identical to what the URL
   serves** (both sha256 ``8c85379c...``). We deliberately do **not** seed it:
   run 2 proves the packages alone are enough, the updater re-downloads the
   *signed* manifest on every start anyway (~1 s), and a manifest we placed
   would be a second, staler opinion about what the client should be.

DECISION 1 -- ``critical=False``
================================

Registry entry::

    DeckStep("steam_prewarm", deck_steam_prewarm.prewarm_steam_step, critical=False)

This step's failure costs the user **exactly today's behaviour**: a slower
first boot. There is no state it can leave behind that makes anything worse --
the updater independently size-checks every file it finds, so a half-populated
``package/`` is simply a smaller download, and a *wrong* file is re-fetched by
Steam. Aborting a finished install over a download that only saves time would
be indefensible.

⚠️ As in ``deck_pkgs.py``: ``critical=False`` is not "failures are tolerated".
Nothing is swallowed. Every outcome is a field in the install record and an
``error()`` line in the install log; ``critical`` governs only an *unexpected*
exception escaping this module.

DECISION 2 -- THE BRANCH IS PINNED TO ``steamdeck_stable``, AND NOT WRITTEN
==========================================================================

The Deck's own log (§5.35's source) names
``steam_client_steamdeck_stable_ubuntu12``; the dev-machine runs above, on
non-Deck hardware, named ``steam_client_ubuntu12``. ``steam.sh`` in the
bootstrap reads ``$STEAMROOT/package/beta`` and treats ``steamdeck_stable`` as
one of its *stable* names, and ``steamdeck_stable`` is a literal string inside
the updater binary -- so the branch is chosen by the updater from the hardware,
not by us.

So we fetch the branch the hardware measured, and we **do not write a ``beta``
file** to force it. Writing one would pin a user's client to a branch name for
the life of the machine on the strength of one 2026 measurement; not writing
one means that if the updater ever picks a different branch, the prewarmed
files are unused and first boot downloads -- today's behaviour, which is the
floor this whole step is allowed to fall back to.

⚠️ Recorded because it bounds the risk and because it will go stale: on
2026-08-16 the ``steamdeck_stable`` manifest and the default ``ubuntu12``
manifest were **byte-identical** (same sha256, both version 1785799196), so the
two branches wanted the same 28 files. Re-check before treating the pin as
free.

DECISION 3 -- SHA256 IS VERIFIED HERE, NOT LEFT TO STEAM
========================================================

Steam checks size. We check size **and** ``sha2``/``sha2vz`` from the manifest,
and we write through ``<name>.part`` + ``os.replace``, so a file only becomes
visible under its real name once it is complete and correct. A truncated
download that happened to land on the right length would otherwise be a file
Steam accepts and cannot use. The manifest itself is signed (``kvsign2`` /
``kvsignatures`` blocks) and we do **not** verify that signature -- we have no
key -- which is why it is fetched over HTTPS and why nothing from it is ever
executed, only used as a file name and a hash.

DECISION 4 -- OWNERSHIP IS ESTABLISHED BEFORE THE BYTES, NOT AFTER
==================================================================

These files land in the target user's home while this process is root. Every
directory this step creates is ``chown``\\ ed immediately, and every download is
``chown``\\ ed **while it is still ``<name>.part``**, before the rename. If the
``chown`` fails, the part file is removed and the step fails: it must not be
possible for this module to leave a root-owned file inside a user's
``~/.local/share/Steam``. The user is resolved through ``deck_user.py``, never
guessed -- and a ``defer_provisioning`` install has no account yet, which is
recorded as ``skipped-deferred`` rather than crashed on.

IDEMPOTENCE
===========

``CLAUDE.md`` requires re-runnable scripts. Each entry is checked against the
target first: right size **and** right sha256 means it is skipped, so a re-run
with an unchanged manifest opens zero connections beyond the 10 KB manifest
itself. The one honest gap: if the manifest *has* moved on between two runs,
the superseded files stay in ``package/`` costing disk until Steam's own
``Cleaning up...`` pass removes them. We do not delete files from a user's home
to save space.
"""

from __future__ import annotations

import hashlib
import os
import shutil
import time
import urllib.request
from pathlib import Path

from .deck_configure import record_result, sanitize_text
from .ui import error, info

# --- the live side ----------------------------------------------------------

LIVE_ROOT = Path("/")

# --- what we ask Valve for --------------------------------------------------

# The one host the updater has baked in (read out of the binary's strings and
# confirmed in every bootstrap_log.txt quoted above). Package files are served
# from the same origin at the root -- measured: a GET of
# `<base>/sdl3_steamrt_ubuntu12.zip.c79773f2...` returns 200 and 690 bytes,
# while `<base>/<branch>/<name>` returns 404.
UPDATE_HOST_BASE = "https://client-update.steamstatic.com/"

# `steam_client_<branch>_<platform>`, with the branch omitted on the default
# channel. Decision 2: `steamdeck_stable` is what the Deck's own first boot
# asked for, so it is what we prewarm.
UPDATE_PLATFORM = "ubuntu12"
UPDATE_BRANCH = "steamdeck_stable"
MANIFEST_NAME = f"steam_client_{UPDATE_BRANCH}_{UPDATE_PLATFORM}"

# A polite, honest identity. The CDN served 200 to curl's default UA during the
# measurement, so nothing depends on impersonating Steam -- and pretending to
# be Steam would make this project's traffic indistinguishable from the
# client's in Valve's logs, which is not a thing to do casually.
USER_AGENT = "omarchy-deck-installer/1.0 (+https://github.com/basecamp/omarchy)"

# --- the target side --------------------------------------------------------

# Where the bootstrap unpacks itself and where the updater looks for already
# present package files. Relative to the TARGET USER'S HOME, which is read out
# of the target's /etc/passwd by deck_user.py and never composed as
# /home/<name>.
STEAM_DIR_REL = ".local/share/Steam"
PACKAGE_DIR_REL = f"{STEAM_DIR_REL}/package"

# Modes matching what the updater itself produced in the measured runs:
# ~/.local/share/Steam is 0700, its package/ is 0755. Only applied to
# directories THIS step creates; an existing directory is the user's and is
# left exactly as it is.
DIR_MODES = {
    ".local": 0o755,
    ".local/share": 0o755,
    STEAM_DIR_REL: 0o700,
    PACKAGE_DIR_REL: 0o755,
}
FILE_MODE = 0o644

# 🔴 Deliberately duplicated from deck_pkgs.STEAM_BOOTSTRAP_REL rather than
# imported: neither module imports the other (the same rule deck_pkgs and
# deck_patches follow for `summarize_output`), and a step that reached into a
# sibling for a constant would make the registry's import order load-bearing.
# test/unit/test-deck-steam-prewarm.py asserts the two strings are equal, so
# the duplication cannot drift silently.
STEAM_BOOTSTRAP_REL = "usr/lib/steam/bootstraplinux_ubuntu12_32.tar.xz"

# --- bounds -----------------------------------------------------------------
#
# Bounds, not deadlines. They exist so a wedged CDN connection or a
# pathological manifest cannot hang an installer on a device with no terminal,
# and so nothing unbounded is written into a user's home by a root process.

# The real manifest is 9,866 bytes with 28 entries.
MAX_MANIFEST_BYTES = 512 * 1024
MAX_MANIFEST_ENTRIES = 128
# The largest real file measured is webkit_ubuntu12 at 89.7 MiB.
MAX_FILE_BYTES = 512 * 1024 * 1024
# The real total is 502,420 KiB (~491 MiB).
MAX_TOTAL_BYTES = 2 * 1024 * 1024 * 1024

# Per-connection socket timeout, and a whole-step budget. The budget is what
# stops a 200 kbit/s hotel connection from turning a 20 minute install into a
# 6 hour one: when it expires the step stops, keeps every file it has already
# verified, and records `partial`. A partially prewarmed package/ is strictly
# better than an empty one -- measured: the updater downloads only what is
# missing.
REQUEST_TIMEOUT_SECS = 60
PREWARM_BUDGET_SECS = 20 * 60
CHUNK_BYTES = 1024 * 1024

# Steam extracts the prewarmed packages into ~2.5 GiB of client on first run.
# Refusing to prewarm on a nearly full filesystem is the point: filling the
# target's root partition during an install would be a far worse outcome than
# a slow first boot.
MIN_FREE_HEADROOM_BYTES = 3 * 1024 * 1024 * 1024

# A package file name from the manifest. It becomes a URL path segment AND a
# path inside a user's home, so it is checked against the character set the
# real names actually use rather than trusted. No '/', so no traversal and no
# escape from package/; explicitly rejecting '..' as well because a name of
# exactly '..' passes the character check.
NAME_ALLOWED = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
MAX_NAME_CHARS = 200

# Suffix for a download in flight. Fixed rather than random so a re-run reuses
# and overwrites the same path instead of accumulating debris in a user's home.
PART_SUFFIX = ".omarchy-deck-part"

# deck_wifi's vocabulary (S1's, via src/deck-form.sh). Used ONLY to classify a
# failure -- never to skip the attempt, for the reason deck_pkgs.py states: a
# Deck on a dock's ethernet legitimately records `skipped`.
NO_NETWORK_WIFI_STATUSES = ("skipped", "no-hardware", "iwd-failed")

# The record's `status` vocabulary. No overlap, and every one of them is a
# thing an operator can act on:
#   prewarmed           every manifest entry is on the target and verified;
#                       first boot has nothing to download
#   partial             some entries landed, some did not (budget, disk, one
#                       bad transfer). First boot downloads the remainder
#   skipped-deferred    defer_provisioning: no account exists yet, so there is
#                       no home to prewarm into
#   skipped-no-steam    the target has no Steam bootstrap tarball, so there is
#                       no client for these files to feed
#   skipped-no-space    not enough free space on the target
#   skipped-no-network  the manifest fetch failed AND deck_wifi recorded that
#                       the installer's Wi-Fi screen produced no network
#   failed              anything else
#   error               written by deck_configure's registry if this module
#                       raises something unforeseen
STATUS_PREWARMED = "prewarmed"
STATUS_PARTIAL = "partial"
STATUS_DEFERRED = "skipped-deferred"
STATUS_NO_STEAM = "skipped-no-steam"
STATUS_NO_SPACE = "skipped-no-space"
STATUS_NO_NETWORK = "skipped-no-network"
STATUS_FAILED = "failed"


class DeckSteamPrewarmError(Exception):
    """A step-level failure. Non-critical: the install continues, the outcome
    is recorded, and the user pays only the first boot this step exists to
    shorten."""


class PrewarmBudgetExpired(DeckSteamPrewarmError):
    """The whole-step time budget ran out mid-transfer. Distinguished from a
    generic failure because everything already verified is still a win."""


# ---------------------------------------------------------------------------
# The manifest -- pure, so the suite can drive every shape of it
# ---------------------------------------------------------------------------


def tokenize_vdf(text: str) -> list[str]:
    """Split Valve KeyValues text into quoted strings, ``{`` and ``}``.

    A hand-rolled tokenizer rather than a dependency, because the installer's
    Python is whatever archiso ships and this step must not add a package to
    any list. Unquoted tokens are accepted too -- the real manifest does not
    use them, but a parser that silently dropped them would misread a file
    rather than complain about it.
    """
    tokens: list[str] = []
    i, n = 0, len(text)
    while i < n:
        ch = text[i]
        if ch.isspace():
            i += 1
            continue
        if ch == "/" and text.startswith("//", i):
            end = text.find("\n", i)
            i = n if end < 0 else end + 1
            continue
        if ch in "{}":
            tokens.append(ch)
            i += 1
            continue
        if ch == '"':
            i += 1
            out: list[str] = []
            while i < n and text[i] != '"':
                if text[i] == "\\" and i + 1 < n:
                    out.append(text[i + 1])
                    i += 2
                    continue
                out.append(text[i])
                i += 1
            if i >= n:
                raise DeckSteamPrewarmError("unterminated quoted string in the Steam manifest")
            i += 1
            tokens.append("".join(out))
            continue
        start = i
        while i < n and not text[i].isspace() and text[i] not in '{}"':
            i += 1
        tokens.append(text[start:i])
    return tokens


def parse_vdf(text: str) -> dict:
    """Parse Valve KeyValues into nested dicts. Later duplicate keys lose."""
    tokens = tokenize_vdf(text)
    root: dict = {}
    stack: list[dict] = [root]
    pos = 0
    while pos < len(tokens):
        token = tokens[pos]
        if token == "}":
            if len(stack) == 1:
                raise DeckSteamPrewarmError("unbalanced '}' in the Steam manifest")
            stack.pop()
            pos += 1
            continue
        if token == "{":
            raise DeckSteamPrewarmError("'{' without a key in the Steam manifest")
        if pos + 1 >= len(tokens):
            raise DeckSteamPrewarmError(f"key '{token}' with no value in the Steam manifest")
        nxt = tokens[pos + 1]
        if nxt == "{":
            existing = stack[-1].get(token)
            if isinstance(existing, dict):
                # A repeated block name merges rather than being dropped.
                stack.append(existing)
            elif existing is not None:
                # 🔴 Never quietly parse into a detached dict: that is how a
                # manifest with one odd key silently loses every package under
                # it. Refuse instead.
                raise DeckSteamPrewarmError(
                    f"key '{sanitize_text(token)}' in the Steam manifest is both a value and a block"
                )
            else:
                child: dict = {}
                stack[-1][token] = child
                stack.append(child)
            pos += 2
            continue
        stack[-1].setdefault(token, nxt)
        pos += 2
    if len(stack) != 1:
        raise DeckSteamPrewarmError("unbalanced '{' in the Steam manifest")
    return root


def valid_package_name(name: str) -> bool:
    """Is ``name`` safe to use as a URL segment and a filename in a home?"""
    if not name or len(name) > MAX_NAME_CHARS:
        return False
    if name in (".", ".."):
        return False
    if name.startswith("."):
        # Nothing real does, and a dotfile in package/ would be invisible to
        # anyone debugging this by eye.
        return False
    return not (set(name) - NAME_ALLOWED)


def expected_size_of(entry: dict, filename: str) -> int | None:
    """How many bytes ``filename`` should be on disk.

    🔴 The manifest's ``size`` is the size of the **uncompressed zip**. When
    the updater fetches the ``zipvz`` form, what lands is the compressed file,
    whose length is the trailing ``_<digits>`` of its own name -- measured:
    ``steam_steamrt_ubuntu12.zip.vz.828656b9..._3588568`` is 3,588,568 bytes.
    ``None`` means "unknown", which disables only the cheap size pre-check;
    the sha256 comparison is what actually decides.
    """
    if filename == entry.get("zipvz"):
        _, sep, tail = filename.rpartition("_")
        if sep and tail.isdigit():
            return int(tail)
        return None
    size = entry.get("size")
    if isinstance(size, str) and size.isdigit():
        return int(size)
    return None


def choose_download(entry: dict) -> tuple[str, str]:
    """(filename, sha256) for one manifest entry.

    MEASURED (see the module docstring): the updater fetches ``zipvz`` when the
    entry has one -- and then the hash that matches the bytes on disk is
    ``sha2vz``, not ``sha2``. Confirmed with ``sha256sum`` against three real
    downloads, one of each shape.
    """
    zipvz = entry.get("zipvz")
    if zipvz:
        sha = entry.get("sha2vz")
        if not sha:
            raise DeckSteamPrewarmError("manifest entry has a zipvz with no sha2vz")
        return zipvz, sha
    plain = entry.get("file")
    if not plain:
        raise DeckSteamPrewarmError("manifest entry has neither zipvz nor file")
    sha = entry.get("sha2")
    if not sha:
        raise DeckSteamPrewarmError("manifest entry has a file with no sha2")
    return plain, sha


def manifest_packages(text: str) -> tuple[list[dict], str | None, list[str]]:
    """(packages, version, warnings) from manifest text.

    Only the **first** top-level block is read. The real document ends with
    sibling ``kvsign2`` and ``kvsignatures`` blocks whose members are hex
    strings, not packages; a parser that walked every top-level block would try
    to download them.
    """
    warnings: list[str] = []
    doc = parse_vdf(text)
    blocks = [(key, val) for key, val in doc.items() if isinstance(val, dict)]
    if not blocks:
        raise DeckSteamPrewarmError("the Steam manifest has no package block")
    _, root = blocks[0]

    version = root.get("version") if isinstance(root.get("version"), str) else None

    packages: list[dict] = []
    for key, entry in root.items():
        if not isinstance(entry, dict) or "file" not in entry:
            continue
        if len(packages) >= MAX_MANIFEST_ENTRIES:
            warnings.append(
                f"the Steam manifest has more than {MAX_MANIFEST_ENTRIES} entries; ignoring the rest"
            )
            break
        try:
            filename, sha = choose_download(entry)
        except DeckSteamPrewarmError as exc:
            warnings.append(f"ignoring manifest entry '{sanitize_text(key)}': {exc}")
            continue
        if not valid_package_name(filename):
            warnings.append(
                f"ignoring manifest entry '{sanitize_text(key)}': "
                f"'{sanitize_text(filename)}' is not a plain package file name"
            )
            continue
        if len(sha) != 64 or set(sha.lower()) - set("0123456789abcdef"):
            warnings.append(
                f"ignoring manifest entry '{sanitize_text(key)}': its hash is not a sha256"
            )
            continue
        packages.append(
            {
                "key": key,
                "file": filename,
                "sha256": sha.lower(),
                "size": expected_size_of(entry, filename),
            }
        )
    if not packages:
        raise DeckSteamPrewarmError(
            "the Steam manifest carries no usable package entries -- nothing to prewarm"
        )
    return packages, version, warnings


# ---------------------------------------------------------------------------
# The network -- one seam, so the suite drives every branch with no sockets
# ---------------------------------------------------------------------------


def open_url(url: str, timeout: int):
    """GET ``url``. The single place this module touches the network.

    Looked up through the module globals at call time by every caller, so a
    test (or a future offline mode) replaces exactly one name. HTTPS is
    asserted rather than assumed: the manifest is signed and we cannot check
    that signature, so transport is the only integrity this step has for the
    hash list itself.
    """
    if not url.startswith("https://"):
        raise DeckSteamPrewarmError(f"refusing to fetch a non-HTTPS URL: {sanitize_text(url)}")
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})  # noqa: S310
    return urllib.request.urlopen(request, timeout=timeout)  # noqa: S310


def set_owner(path, uid: int, gid: int) -> None:
    """``chown``, as a named seam. Decision 4 turns its failure into a refusal
    to leave the file behind, so the suite has to be able to make it fail."""
    os.chown(path, uid, gid)


def fetch_manifest(timeout: int = REQUEST_TIMEOUT_SECS) -> str:
    url = UPDATE_HOST_BASE + MANIFEST_NAME
    try:
        with open_url(url, timeout) as response:
            data = response.read(MAX_MANIFEST_BYTES + 1)
    except DeckSteamPrewarmError:
        raise
    except Exception as exc:  # noqa: BLE001 -- urllib raises a zoo of types
        raise DeckSteamPrewarmError(
            f"could not fetch {url}: {type(exc).__name__}: {exc}"
        ) from exc
    if len(data) > MAX_MANIFEST_BYTES:
        raise DeckSteamPrewarmError(
            f"{url} returned more than {MAX_MANIFEST_BYTES} bytes; refusing to parse it"
        )
    if isinstance(data, bytes):
        return data.decode("utf-8", "replace")
    return data


def file_sha256(path, chunk: int = CHUNK_BYTES) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while True:
            block = handle.read(chunk)
            if not block:
                break
            digest.update(block)
    return digest.hexdigest()


def already_good(path: Path, package: dict) -> bool:
    """Is ``path`` already exactly the file the manifest describes?

    Size first because it is a stat and rejects the common case for free; sha
    second because it is the only check that catches a same-length corruption.
    This is what makes a re-run touch the network zero times.
    """
    if not path.is_file():
        return False
    if package["size"] is not None and path.stat().st_size != package["size"]:
        return False
    try:
        return file_sha256(path) == package["sha256"]
    except OSError:
        return False


def download_package(package: dict, dest: Path, uid: int, gid: int, deadline: float | None) -> int:
    """Fetch one package file into ``dest``. Returns bytes written.

    Written to ``dest.part``, verified, ``chown``ed, and only then renamed
    (decisions 3 and 4). Every early exit removes the part file, so a failure
    here leaves the target's ``package/`` exactly as it found it.
    """
    url = UPDATE_HOST_BASE + package["file"]
    part = dest.with_name(dest.name + PART_SUFFIX)
    digest = hashlib.sha256()
    written = 0
    try:
        with open_url(url, REQUEST_TIMEOUT_SECS) as response, open(part, "wb") as out:
            while True:
                if deadline is not None and time.monotonic() > deadline:
                    raise PrewarmBudgetExpired(
                        f"the {PREWARM_BUDGET_SECS}s prewarm budget expired while fetching "
                        f"{package['file']}"
                    )
                block = response.read(CHUNK_BYTES)
                if not block:
                    break
                written += len(block)
                if written > MAX_FILE_BYTES:
                    raise DeckSteamPrewarmError(
                        f"{url} is larger than {MAX_FILE_BYTES} bytes; aborting the transfer"
                    )
                digest.update(block)
                out.write(block)

        if package["size"] is not None and written != package["size"]:
            raise DeckSteamPrewarmError(
                f"{package['file']}: got {written} bytes, the manifest says {package['size']}"
            )
        actual = digest.hexdigest()
        if actual != package["sha256"]:
            raise DeckSteamPrewarmError(
                f"{package['file']}: sha256 {actual} does not match the manifest's "
                f"{package['sha256']}"
            )
        os.chmod(part, FILE_MODE)
        # 🔴 Before the rename, never after: this module must not be able to
        # leave a root-owned file inside a user's ~/.local/share/Steam.
        set_owner(part, uid, gid)
        os.replace(part, dest)
    except DeckSteamPrewarmError:
        part.unlink(missing_ok=True)
        raise
    except Exception as exc:  # noqa: BLE001 -- urllib, OSError, anything
        part.unlink(missing_ok=True)
        raise DeckSteamPrewarmError(
            f"{package['file']}: {type(exc).__name__}: {exc}"
        ) from exc
    return written


# ---------------------------------------------------------------------------
# The target's directories
# ---------------------------------------------------------------------------


def ensure_package_dir(home_on_target: Path, uid: int, gid: int) -> Path:
    """Create ``~/.local/share/Steam/package`` if absent, owned by the user.

    Fails the whole step if a directory it created cannot be chowned, BEFORE
    anything is downloaded -- the cheap ordering that makes decision 4 hold.
    An already-existing directory is left completely alone: it is the user's
    (or Steam's), and re-chmodding somebody else's home is not this step's
    business.
    """
    if not home_on_target.is_dir():
        raise DeckSteamPrewarmError(
            f"{home_on_target} does not exist on the target, so there is no home to prewarm into"
        )
    for rel, mode in DIR_MODES.items():
        path = home_on_target / rel
        if path.is_dir():
            continue
        if path.exists():
            raise DeckSteamPrewarmError(f"{path} exists on the target and is not a directory")
        try:
            path.mkdir(mode=mode)
            os.chmod(path, mode)  # mkdir's mode is masked by umask; this is not
            set_owner(path, uid, gid)
        except OSError as exc:
            raise DeckSteamPrewarmError(f"could not create {path} for the target user: {exc}") from exc
    return home_on_target / PACKAGE_DIR_REL


def read_wifi_status(live_root=LIVE_ROOT) -> str:
    """What the installer's Wi-Fi screen recorded. Classification only.

    Same shape and same defence as ``deck_pkgs.read_wifi_status``: this step
    must not be able to fail because the *reporting* half of a sibling module
    did, and "unknown" classifies a failure as the louder ``failed`` rather
    than the quieter ``skipped-no-network``.
    """
    try:
        from . import deck_wifi

        fields, _ = deck_wifi.read_outcome(live_root)
        return fields.get("status", "missing") or "missing"
    except Exception:  # noqa: BLE001 -- deliberate, see the docstring
        return "unknown"


# ---------------------------------------------------------------------------
# The step
# ---------------------------------------------------------------------------


def prewarm_steam(ctx, live_root=LIVE_ROOT, budget_secs: int = PREWARM_BUDGET_SECS) -> dict:
    """Prewarm the target's Steam package cache and return the record."""
    target = Path(ctx.target)
    record: dict = {
        "status": None,
        "manifest": MANIFEST_NAME,
        "manifest_url": UPDATE_HOST_BASE + MANIFEST_NAME,
        "client_version": None,
        "user": None,
        "package_dir": None,
        "expected": 0,
        "already_present": 0,
        "downloaded": 0,
        "downloaded_bytes": 0,
        "missing_after": [],
        "wifi_status": None,
        "error": None,
        "warnings": [],
    }
    warnings: list[str] = record["warnings"]
    deadline = time.monotonic() + budget_secs if budget_secs else None

    try:
        from . import deck_user

        try:
            user, user_warnings = deck_user.resolve_target_user(ctx)
        except deck_user.DeckUserDeferred as exc:
            # Not a failure. There is no account and no home yet; the first
            # boot's omarchy-provision-owner creates them, and prewarming into
            # /etc/skel would mean copying ~490 MiB at useradd time on a device
            # that is trying to get to a desktop.
            record["status"] = STATUS_DEFERRED
            record["error"] = sanitize_text(
                f"no Steam prewarm on a defer_provisioning install: {exc}", limit=400
            )
            return _finish(record, warnings)
        warnings.extend(user_warnings)
        record["user"] = user.name

        bootstrap = target / STEAM_BOOTSTRAP_REL
        if not bootstrap.is_file():
            # deck_pkgs fetches `steam` online and records its own outcome; if
            # that did not land there is no client for these files to feed, and
            # downloading ~490 MiB into a home that will never read it is worse
            # than doing nothing. deck_pkgs' first-boot notice already tells the
            # machine's owner about the real problem.
            record["status"] = STATUS_NO_STEAM
            record["error"] = sanitize_text(
                f"/{STEAM_BOOTSTRAP_REL} is not on the target, so Steam cannot bootstrap at "
                "all and there is nothing for a prewarmed client update to attach to. See "
                "the 'pkgs' section of this record.",
                limit=400,
            )
            return _finish(record, warnings)

        record["wifi_status"] = read_wifi_status(live_root)

        info(
            "Steam prewarm: fetching Valve's client manifest "
            f"({MANIFEST_NAME}); this step needs the internet and downloads the "
            "Steam client update that would otherwise run on first boot"
        )
        try:
            manifest_text = fetch_manifest()
        except DeckSteamPrewarmError as exc:
            if record["wifi_status"] in NO_NETWORK_WIFI_STATUSES:
                record["status"] = STATUS_NO_NETWORK
                record["error"] = sanitize_text(
                    f"{exc} -- and the installer's Wi-Fi screen recorded status="
                    f"{record['wifi_status']}, so this machine had no network. Steam will "
                    "download its client update on first boot instead, which takes about "
                    "two minutes on a black screen.",
                    limit=400,
                )
            else:
                record["status"] = STATUS_FAILED
                record["error"] = sanitize_text(
                    f"{exc} (the installer's Wi-Fi screen recorded status="
                    f"{record['wifi_status']}). Steam will download its client update on "
                    "first boot instead.",
                    limit=400,
                )
            return _finish(record, warnings)

        packages, version, parse_warnings = manifest_packages(manifest_text)
        warnings.extend(parse_warnings)
        record["client_version"] = version
        record["expected"] = len(packages)

        package_dir = ensure_package_dir(user.home_on(target), user.uid, user.gid)
        record["package_dir"] = str(package_dir)

        todo = []
        for package in packages:
            if already_good(package_dir / package["file"], package):
                record["already_present"] += 1
            else:
                todo.append(package)

        if not todo:
            record["status"] = STATUS_PREWARMED
            info(
                f"Steam prewarm: all {len(packages)} client packages "
                f"(version {version}) are already on the target"
            )
            return _finish(record, warnings)

        needed = sum(p["size"] for p in todo if p["size"] is not None)
        if needed > MAX_TOTAL_BYTES:
            raise DeckSteamPrewarmError(
                f"the Steam manifest asks for {needed} bytes, more than this step's "
                f"{MAX_TOTAL_BYTES} byte cap; refusing to fill the target's disk"
            )
        try:
            free = shutil.disk_usage(package_dir).free
        except OSError as exc:
            free = None
            warnings.append(f"could not measure free space on the target: {exc}")
        if free is not None and free < needed + MIN_FREE_HEADROOM_BYTES:
            record["status"] = STATUS_NO_SPACE
            record["missing_after"] = [p["file"] for p in todo]
            record["error"] = sanitize_text(
                f"the target has {free} bytes free; prewarming needs {needed} plus "
                f"{MIN_FREE_HEADROOM_BYTES} of headroom for Steam to unpack into. Skipped; "
                "Steam will download on first boot.",
                limit=400,
            )
            return _finish(record, warnings)

        info(
            f"Steam prewarm: downloading {len(todo)} Steam client package(s), "
            f"about {needed // (1024 * 1024)} MiB, into {user.name}'s home so the first "
            "boot does not have to"
        )

        expired = False
        for package in todo:
            if deadline is not None and time.monotonic() > deadline:
                expired = True
                record["missing_after"].append(package["file"])
                continue
            try:
                record["downloaded_bytes"] += download_package(
                    package, package_dir / package["file"], user.uid, user.gid, deadline
                )
                record["downloaded"] += 1
            except PrewarmBudgetExpired as exc:
                expired = True
                record["missing_after"].append(package["file"])
                warnings.append(str(exc))
            except DeckSteamPrewarmError as exc:
                record["missing_after"].append(package["file"])
                warnings.append(f"could not prewarm {sanitize_text(package['file'])}: {exc}")

        if record["missing_after"]:
            record["status"] = STATUS_PARTIAL
            record["error"] = sanitize_text(
                f"{len(record['missing_after'])} of {len(packages)} Steam client packages "
                + ("were not prewarmed (the time budget expired)" if expired else "failed to download")
                + ". Steam downloads only what is missing, so first boot is shorter than it "
                "would have been but not instant.",
                limit=400,
            )
        else:
            record["status"] = STATUS_PREWARMED
            info(
                f"Steam prewarm: {record['downloaded']} package(s), "
                f"{record['downloaded_bytes']} bytes, staged in {package_dir}"
            )
    except (DeckSteamPrewarmError, OSError) as exc:
        record["status"] = STATUS_FAILED
        record["error"] = sanitize_text(f"{type(exc).__name__}: {exc}", limit=400)
    return _finish(record, warnings)


def _finish(record: dict, warnings: list[str]) -> dict:
    """Report through the install log. Never silently swallow a failure."""
    if record["error"]:
        error(f"Steam prewarm: {record['error']}")
    for warning in warnings:
        error(f"Steam prewarm: {warning}")
    return record


def prewarm_steam_step(ctx) -> None:
    """``DeckStep`` entry point. Records under the ``steam_prewarm`` key
    whichever way it went, so an assertion over
    ``/var/log/omarchy-deck-install.json`` can ask whether the first boot this
    install produced still has ~490 MiB to fetch."""
    record_result(ctx.target, "steam_prewarm", prewarm_steam(ctx, LIVE_ROOT))
