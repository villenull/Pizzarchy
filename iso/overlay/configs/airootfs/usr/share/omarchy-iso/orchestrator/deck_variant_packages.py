"""Optional variant package delta for FAST-INSTALL (Stages slice, C2).

Installs the requested offline package set into the already-restored target
with ``arch-chroot pacman -S --needed``, from the bundled offline mirror
(``SigLevel = Never`` + ``file://`` server, same as the pacstrap path -- no
network, no keyring). Every transaction here runs before the Limine/UKI
finalizer by phase order.

Package names come from the live ISO manifests, never from copies kept here:

* ``usr/share/omarchy-iso/deck-preinstalls.packages`` -- the 13 optional
  apps; RootImage mirrors the pinned runtime's ``bin/omarchy-remove-preinstalls``
  ``omarchy-pkg-drop`` argv into this file at the pin, and
  ``test-deck-variants.py`` asserts the two identical whenever both
  checkouts are available. No second hand-kept copy may drift.
* ``usr/share/omarchy-iso/deck-gaming.packages`` -- the gaming-only set
  (RootImage owns names + mirror; this module only consumes).

Entries may be repo-qualified (``jupiter-staging/gamescope`` decides WHICH
build the mirror kept); the qualification is stripped (``${entry##*/}``)
before installing offline, where exactly one repo exists. ``steam`` itself
is NEVER here -- it stays an online fetch (deck_pkgs) because Valve's client
is not redistributable. ``steamdeck-dsp`` is COMMON (in the minimal image),
not gaming.

``apply_preinstalls_removal`` is the preinstalls=no counterpart: the image
never carries the 13 packages, but ``omarchy-provision-user --first-install``
generates web-app/TUI launchers and mise stubs unconditionally, so late
removes them with the runtime's own canonical tools
(``omarchy-webapp-remove-all``, ``omarchy-tui-remove-all`` -- file deletions,
offline-safe) plus the stub list from the remove script, without gum. The
``preinstalls-removed`` marker itself is seeded by deck_install_identity in
the final home, which is also what surfaces Install > Preinstalls.
"""

from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path

from .ui import error, info

# Live-ISO manifests (RootImage ships them; the build refuses an ISO without
# them the same way it refuses one without deck-fetch.packages). Overridable
# via live_root so unit tests never touch /.
LIVE_ROOT = Path("/")
PREINSTALL_LIST_REL = "usr/share/omarchy-iso/deck-preinstalls.packages"
GAMING_LIST_REL = "usr/share/omarchy-iso/deck-gaming.packages"

# Caps on the lists: ours and tiny; these exist so a corrupted file cannot be
# turned into an unbounded root pacman transaction.
MAX_LIST_BYTES = 64 * 1024
MAX_LIST_ENTRIES = 64

# A bare Arch package name. Repo qualification (``jupiter-staging/``) is
# stripped BEFORE this check -- ``/`` never reaches pacman here.
NAME_ALLOWED = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@._+-")

# Pinned-runtime authority for the preinstall set, parsed (not copied) by the
# suite whenever the checkout is available. The INSTALL path reads the ISO
# manifest; this path exists so a manifest that drifted from the pin fails
# the suite instead of shipping the wrong 13.
RUNTIME_SRC_CANDIDATES = (
    Path.home() / ".cache/omarchy-deck/iso-build-4.0.4/runtime-src",
    Path("/root/omarchy-runtime"),
)
REMOVE_SCRIPT_REL = "bin/omarchy-remove-preinstalls"

# Bounds: a wedged local transaction must not hang the install. Generous --
# the mirror is local, so anything past this is wedged rather than slow.
DELTA_TIMEOUT_SECS = 1800

# Caps on pacman output before it lands in the world-readable install log.
MAX_OUTPUT_LINES = 12
MAX_LINE_CHARS = 200

# Canonical removal tools (runtime-owned, on the target). File deletions only:
# offline-safe by construction. Full paths: the chroot PATH is not ours to
# assume. The omarchy 4.0.4 package ships the real files in /usr/bin; its
# /usr/share/omarchy/bin entries are ABSOLUTE symlinks to them, which a
# check from outside the chroot resolves against the live ISO's root -- so
# presence is always judged inside the target (_target_has_file).
WEBAPP_REMOVE = "/usr/bin/omarchy-webapp-remove-all"
TUI_REMOVE = "/usr/bin/omarchy-tui-remove-all"

# Mise stubs the remove script deletes unconditionally (the cursor-agent /
# muse / hermes guards need a live home to evaluate, so late keeps exactly
# these plus the marker; a user-owned file at a guarded path is the user's).
MISE_STUBS = (
    "codex", "claude", "gemini", "copilot", "gh", "opencode",
    "playwright", "playwright-cli", "pi", "omp", "grok", "crush",
    "ghui", "hunk",
)


def _target_has_file(target: Path, abs_path: str) -> bool:
    """True when ``abs_path`` is a regular file INSIDE the target root.

    Symlinks are followed with absolute targets re-rooted at ``target``:
    Path.is_file() would follow them into the live ISO (or a dev box) and
    answer for the wrong machine."""
    path = target / abs_path.lstrip("/")
    for _ in range(40):
        if not path.is_symlink():
            return path.is_file()
        link = os.readlink(path)
        path = target / link.lstrip("/") if link.startswith("/") else path.parent / link
    return False


def read_package_list(live_root, rel: str) -> list[str]:
    """Bare package names from a live-ISO manifest. Missing/empty is fatal.

    A list that installs nothing, quietly, is the P32 defect -- so (like
    deck_pkgs.read_fetch_list) this raises instead of returning an empty
    list, and the caller records ``failed``. Repo qualification is stripped;
    a name still malformed afterwards is dropped with a warning, never passed
    to a root pacman (one bad entry must not abort the correct rest).
    """
    from .deck_configure import sanitize_text

    path = Path(live_root) / rel
    try:
        data = path.read_bytes()[: MAX_LIST_BYTES + 1]
    except FileNotFoundError as exc:
        raise RuntimeError(
            f"{path} does not exist on the live ISO -- nothing tells this install "
            "which optional packages to add, so none were installed. The build is "
            "supposed to ship it (RootImage manifests)."
        ) from exc
    except OSError as exc:
        raise RuntimeError(f"cannot read {path}: {exc}") from exc
    if len(data) > MAX_LIST_BYTES:
        raise RuntimeError(f"{path} is larger than {MAX_LIST_BYTES} bytes; refusing a pathological list")
    names: list[str] = []
    warnings: list[str] = []
    for raw in data.decode("utf-8", "replace").splitlines():
        entry = raw.strip()
        if not entry or entry.startswith("#"):
            continue
        bare = entry.split("/")[-1].strip()
        if not bare or (bad := set(bare) - NAME_ALLOWED):
            warnings.append(
                f"ignoring {sanitize_text(entry)!r} in /{rel}: not a plain pacman package name"
            )
            continue
        if bare in names:
            warnings.append(f"duplicate entry {bare!r} in /{rel}")
            continue
        if len(names) >= MAX_LIST_ENTRIES:
            warnings.append(f"/{rel} has more than {MAX_LIST_ENTRIES} entries; ignoring the rest")
            break
        names.append(bare)
    if not names:
        raise RuntimeError(
            f"/{rel} carries no usable package entries. A list that names "
            "nothing installs nothing, which is exactly the P32 defect."
        )
    return names, warnings


def runtime_preinstall_packages(runtime_src=None) -> tuple[list[str], list[str]]:
    """Parse the remove script's ``omarchy-pkg-drop`` argv. Returns (names, warnings).

    Test/cross-check seam only -- the INSTALL path reads the ISO manifest.
    ``runtime_src`` overrides the checkout search (tests).
    """
    warnings: list[str] = []
    roots: list[Path] = []
    if runtime_src is not None:
        roots = [Path(runtime_src)]
    else:
        roots = [p for p in RUNTIME_SRC_CANDIDATES if p.is_dir()]
    if not roots:
        return None, ["pinned runtime checkout not available; manifest stands alone"]
    script = roots[0] / REMOVE_SCRIPT_REL
    try:
        text = script.read_text()
    except OSError as exc:
        raise RuntimeError(f"cannot read {script}: {exc}") from exc
    match = re.search(r"omarchy-pkg-drop\s*\\\s*((?:[ \t]*[A-Za-z0-9@._+-]+\s*\\\s*)+[ \t]*[A-Za-z0-9@._+-]+)", text)
    if not match:
        raise RuntimeError(
            f"{script} names no omarchy-pkg-drop package list; refusing to guess the preinstall set"
        )
    names = re.findall(r"[A-Za-z0-9@._+-]+", match.group(1))
    if not names:
        raise RuntimeError(f"{script} has an empty omarchy-pkg-drop list")
    return names, warnings


def _run(argv: list[str], timeout: int, env=None) -> tuple[int, str]:
    try:
        proc = subprocess.run(  # noqa: S603
            argv, capture_output=True, text=True, check=False, timeout=timeout, env=env,
        )
    except subprocess.TimeoutExpired as exc:
        out = exc.stdout or ""
        err = exc.stderr or ""
        if isinstance(out, bytes):
            out = out.decode("utf-8", "replace")
        if isinstance(err, bytes):
            err = err.decode("utf-8", "replace")
        return 124, (out + err + f"\nTIMED OUT after {timeout}s\n").strip()
    return proc.returncode, ((proc.stdout or "") + (proc.stderr or "")).strip()


def _summarize(text: str) -> str | None:
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    if not lines:
        return None
    return " | ".join(line[:MAX_LINE_CHARS] for line in lines[-MAX_OUTPUT_LINES:])


def _installed_names(target: Path) -> set[str]:
    """Exact installed package names from the target's pacman db."""
    names: set[str] = set()
    local_db = target / "var/lib/pacman/local"
    if not local_db.is_dir():
        return names
    for entry in local_db.iterdir():
        desc = entry / "desc"
        if not desc.is_file():
            continue
        try:
            lines = desc.read_text(errors="ignore").splitlines()
        except OSError:
            continue
        for i, line in enumerate(lines):
            if line.strip() == "%NAME%" and i + 1 < len(lines):
                names.add(lines[i + 1].strip())
                break
    return names


def install_variant_delta(target, preinstalls: bool, gaming: bool, live_root=LIVE_ROOT) -> dict:
    """Install the requested offline delta. Returns the install record.

    no/no installs nothing (fast path). Sources are the live-ISO manifests;
    a missing/empty manifest fails loudly (P32), never silently skips.
    Outcome-asserted: every requested name must be in the target db
    afterwards, or the status is ``failed`` -- gaming=yes callers turn that
    into a failed install.
    """
    from .deck_configure import sanitize_text

    target = Path(target)
    record: dict = {
        "status": None,
        "preinstalls": "yes" if preinstalls else "no",
        "gaming": "yes" if gaming else "no",
        "requested": [],
        "installed": [],
        "already_present": False,
        "exit_code": None,
        "output": None,
        "error": None,
        "warnings": [],
    }
    warnings: list[str] = record["warnings"]

    ordered: list[str] = []
    try:
        if preinstalls:
            names, parse_warnings = read_package_list(live_root, PREINSTALL_LIST_REL)
            warnings.extend(parse_warnings)
            ordered.extend(names)
        if gaming:
            names, parse_warnings = read_package_list(live_root, GAMING_LIST_REL)
            warnings.extend(parse_warnings)
            ordered.extend(names)
    except RuntimeError as exc:
        record["status"] = "failed"
        record["error"] = sanitize_text(f"{type(exc).__name__}: {exc}", limit=400)
        error(f"Variant delta: {record['error']}")
        return record
    # De-duplicate, order-stable: the record must read deterministically.
    seen: set[str] = set()
    deduped: list[str] = []
    for name in ordered:
        if name not in seen:
            seen.add(name)
            deduped.append(name)
    ordered = deduped
    record["requested"] = ordered

    if not ordered:
        record["status"] = "ok"
        record["already_present"] = True
        info("Variant delta: no/no -- nothing to install (fast path)")
        return record

    installed = _installed_names(target)
    missing = [name for name in ordered if name not in installed]
    if not missing:
        record["status"] = "ok"
        record["already_present"] = True
        record["installed"] = ordered
        info(f"Variant delta: already present ({', '.join(ordered)})")
        return record

    info(f"Variant delta: installing {' '.join(missing)} from the offline mirror")
    code, output = _run(
        ["arch-chroot", str(target), "pacman", "-S", "--needed", "--noconfirm", *missing],
        DELTA_TIMEOUT_SECS,
    )
    record["exit_code"] = code
    record["output"] = _summarize(output)
    if code != 0:
        record["status"] = "failed"
        record["error"] = sanitize_text(
            f"pacman -S --needed {' '.join(missing)} exited {code} inside the target. "
            f"Output: {record['output'] or '<none>'}",
            limit=400,
        )
        error(f"Variant delta: {record['error']}")
        return record

    # THE OUTCOME ASSERTION: a zero exit is a step assertion, and P32 proved
    # those green while the product is broken. Re-read the db.
    have = _installed_names(target)
    still_missing = [name for name in missing if name not in have]
    if still_missing:
        record["status"] = "failed"
        record["error"] = sanitize_text(
            "pacman exited 0 but "
            + ", ".join(still_missing)
            + " is still not installed on the target -- the exit code and the "
            "package database disagree, so neither can be trusted.",
            limit=400,
        )
        error(f"Variant delta: {record['error']}")
        return record

    record["status"] = "ok"
    record["installed"] = [name for name in ordered if name in have]
    info(f"Variant delta installed: {', '.join(record['installed'])}")
    for warning in warnings:
        error(f"Variant delta: {warning}")
    return record


def apply_preinstalls_removal(target, username: str) -> dict:
    """Remove generated preinstall wrappers for preinstalls=no. Returns a record.

    Runs AFTER provision-user generated them: the runtime's own canonical
    removal tools (web-app + TUI scans -- pure file deletions, offline-safe)
    plus the unconditional mise-stub list from the remove script, as the
    target user with HOME set (the tools default their scan roots to $HOME).
    No gum: the canonical script's confirm prompt cannot be answered in a
    chroot, so this calls the tools it calls. A missing tool fails loudly --
    leftover wrappers would silently make "no" mean "yes".
    """
    from .deck_configure import sanitize_text

    target = Path(target)
    home = f"/home/{username}"
    record: dict = {"status": None, "removed": [], "error": None, "warnings": []}
    env = {"HOME": home, "PATH": "/usr/local/sbin:/usr/local/bin:/usr/bin:/bin"}
    for tool in (WEBAPP_REMOVE, TUI_REMOVE):
        if not _target_has_file(target, tool):
            record["status"] = "failed"
            record["error"] = sanitize_text(
                f"/{tool.lstrip('/')} is not on the target; cannot remove preinstall "
                "wrappers without the runtime's own removal tool",
                limit=400,
            )
            error(f"Preinstalls removal: {record['error']}")
            return record
        code, output = _run(
            ["arch-chroot", "-u", username, str(target), tool],
            DELTA_TIMEOUT_SECS, env=env,
        )
        if code != 0:
            record["status"] = "failed"
            record["error"] = sanitize_text(
                f"{tool} exited {code} inside the target. Output: {_summarize(output) or '<none>'}",
                limit=400,
            )
            error(f"Preinstalls removal: {record['error']}")
            return record
    removed: list[str] = []
    for stub in MISE_STUBS:
        path = target / home.lstrip("/") / ".local/bin" / stub
        try:
            if path.is_file() and not path.is_symlink():
                path.unlink()
                removed.append(stub)
        except OSError as exc:
            record["warnings"].append(f"could not remove {stub}: {exc}")
    record["removed"] = removed
    record["status"] = "ok"
    info(f"Preinstalls removal: wrappers gone ({len(removed)} mise stubs removed)")
    for warning in record["warnings"]:
        error(f"Preinstalls removal: {warning}")
    return record
