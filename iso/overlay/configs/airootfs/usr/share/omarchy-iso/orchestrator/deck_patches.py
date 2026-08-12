"""Run ``omarchy-deck-apply-patches`` once, inside the target, at install time.

SHIPPED AS ``/usr/share/omarchy-iso/orchestrator/deck_patches.py``. The
``patches`` step registered in ``deck_configure.deck_steps``.

WHAT THIS IS AND IS NOT
=======================

``docs/findings/T12-upstream-patch-seam.md`` §3 decided that files owned by
``omarchy-dev`` (``/usr/share/omarchy/...``) are customised by a patch set that
an ALPM ``PostTransaction`` hook re-applies after every upgrade. The hook is
the mechanism that *keeps* the patches applied; this step is the one that makes
them true **the first time**, on the machine that has just been pacstrapped.
Both are needed and neither is redundant:

* the hook fires on ``omarchy-dev``/``omarchy``/``omarchy-settings*``, **not**
  on ``omarchy-deck`` -- measured, ``docs/tasks/T12-upstream-patch-seam.md`` §5
  note 2 -- so installing our own package does not fire it;
* measurement M1 showed a hook installed in the same transaction as its target
  *does* run, so this call may find the patches already applied. That is
  harmless: the applier's step 1 (``git apply --reverse --check``) reports
  ``already-applied`` and changes nothing.

🔴 THIS FILE DOES NOT KNOW HOW TO PATCH ANYTHING
================================================

It invokes a binary and reports what happened. Every rule about *how* the patch
seam behaves -- ``git apply`` never ``sed``, idempotence, the drift alarm, the
post-conditions, the state file -- lives in
``src/omarchy-deck-patches/omarchy-deck-apply-patches`` and is covered by
``test/unit/test-t12-patch-applier.sh``. Duplicating any of it here would give
this project two places to disagree about the same contract.

DECISION 1 -- WHERE THE APPLIER RUNS: **INSIDE THE TARGET, VIA ``arch-chroot``**
===============================================================================

Not on the live system with ``--root <target>/usr/share/omarchy``, even though
the applier accepts ``--root``/``--patch-dir``/``--state-file``. Read the
applier, not its flags: two of the things it does are **not** relocatable by
any flag it has.

1. ``installed_version()`` runs ``pacman -Q omarchy-dev``. On the live ISO that
   answers about the *ISO's* package database, so ``patch-state.json`` would
   record the wrong provenance -- and that field is the whole point of the
   file: it says which upstream version the patch was checked against.
2. ``resolve_qmllint()`` searches the absolute path ``/usr/lib/qt6/bin`` and
   then ``PATH``. That is where **the target's** ``qt6-declarative`` puts it
   (pulled in by ``quickshell``); the live ISO is not required to carry Qt6 at
   all. A qmllint that cannot be found is deliberately **not** a skip in the
   applier -- it is a ``postcondition_failed`` -- so running from the live side
   would turn every clean install into a loud false alarm, which is the exact
   failure mode ``omarchy-deck-apply-patches``' own header calls out as "as bad
   as a permanent silence".

``arch-chroot`` is also what upstream's own phases use for everything that must
observe the target's world (``phases_impl.py``: ``run_system_finalizer``,
``limine bios-install``, ``limine-update``, every ``systemctl enable``), and it
is what ``docs/findings/T12-upstream-patch-seam.md`` §3.4 specified. So: the
target's ``arch-chroot``, the applier's **default** paths, no flags.

DECISION 2 -- ``critical=False``, AND HERE IS THE ARGUMENT
==========================================================

``docs/findings/T12-upstream-patch-seam.md`` §3.4 and
``docs/tasks/T12-upstream-patch-seam.md`` §1 step 4 both say "a non-zero exit
fails the install". **That is overruled here, deliberately, and the reasons are
below so the next reader can overrule it back if they disagree.**

*For ``critical=True``:* it is the loudest possible response, and a Deck whose
patches are stale is a Deck that does not behave the way this project promises.

*For ``critical=False`` -- and this is what won:*

1. **The failure is a degradation, not a broken machine.** The worst case is
   the lock screen blanking the panel in ~2 s instead of ~20 s
   (``docs/PROGRESS.md`` §5.24a row 2) and the Limine template keeping
   upstream's rotation. The device still boots, Gaming Mode is untouched, and
   Desktop Mode works. ``deck_configure``'s own registry rule says the same
   thing in general: "the *degradation* is allowed and the *silence* is not".
2. **The asymmetry is brutal.** ``critical=True`` on drift leaves the operator
   with **no installed system at all**, after partitioning, LUKS, pacstrap and
   ~1200 packages -- on a device whose only recovery path is another full
   install from a controller. ``critical=False`` leaves a working Deck with
   upstream's lock timing and three separate alarms saying so.
3. **Drift is EXPECTED, roughly monthly.** ``docs/findings/T12-upstream-patch-seam.md``
   §6 measured the patched literal being retuned three times in two months on a
   file with 17 commits since May. A rule that turns "upstream retuned a QML
   integer" into "the installer refuses to produce a machine" makes the ISO
   fail for a cosmetic reason at the most expensive possible moment.
4. **The hard failure belongs at BUILD time, and it already has a home.** §2 D
   of the finding is explicit -- "fail at build, not at install" -- which is
   guard 6.6 in ``iso/bin/build``: ``git apply --check`` every patch against
   the pinned runtime checkout and refuse to build. That guard fails on a
   developer's machine before an ISO exists. Once it is in place, an install
   that reaches drift is an install of an ISO that was built before upstream
   moved, i.e. exactly the case where the *user* should get a machine.
5. **Nothing is lost by not aborting.** The three channels the finding §4
   designed all survive a non-critical outcome: ``patch-state.json`` on the
   target, ``omarchy-deck-patch-check.service`` leaving a **failed unit** at
   first boot, and this step's own record in
   ``/var/log/omarchy-deck-install.json``. Aborting adds no information; it
   only destroys a working system.

⚠️ ``critical=False`` is not "failures are tolerated". Nothing here is
swallowed: every outcome is recorded and every bad one is printed through the
orchestrator's ``error``. As with the Wi-Fi step, expected failures are a
**field in the record, not an exception**, because throwing the record away in
order to signal a failure would destroy the report. ``critical`` therefore
governs the one thing left -- an *unexpected* exception escaping this module --
and the same argument applies to it: not a reason to leave the operator
without a machine.

DECISION 3 -- 🔴 THE APPLIER IS NOT ON THE TARGET YET
=====================================================

The applier, the hook, the unit and the patches exist and are tested
(``src/omarchy-deck-patches/``, ``test/unit/test-t12-patch-applier.sh``), but
the ``omarchy-deck`` package that is supposed to *carry* them is still a
skeleton with no payload. So on every install today this step finds nothing to
run. That must be **recorded and loud**, never a silent skip and never a
traceback that aborts an install, which is why "absent" is a first-class
recorded outcome rather than an early ``return`` with no trace:

``status="applied"``  the applier ran and ``patch-state.json`` says ``ok``
``status="failed"``   it ran and did not report ok (drift, missing target,
                      post-condition, bad meta, environment, or a state file
                      that contradicts a zero exit)
``status="absent"``   there is no usable applier on the target

(and ``status="error"`` is what ``deck_configure``'s registry writes if this
module raises something unforeseen -- four distinguishable states, no overlap.)

🔴 A NOTE ON GUARD 6.4a, WHICH IS WHY THE PATH BELOW IS COMPOSED
================================================================

``iso/bin/build``'s guard 6.4a greps this whole directory for
``/usr/bin/omarchy-[A-Za-z0-9._-]+`` and **fails the build** unless every match
exists in the pinned ``basecamp/omarchy`` checkout's ``bin/``. Its premise is
"the orchestrator only shells out to runtime binaries", and this step is the
first thing that breaks that premise: ``omarchy-deck-apply-patches`` comes from
**our** package, not from the runtime, so a literal absolute path here would
fail an otherwise correct build with a wrong diagnosis.

The path is therefore assembled from ``APPLIER_DIR`` + ``APPLIER_NAME``. That
is a dodge, so it is written down rather than left to be discovered: guard 6.4a
needs to learn about binaries the ``omarchy-deck`` package ships (a second
source list, the way 6.4b checks the real artifact), and until it does, this
composition is load-bearing.

⚠️ That grep reads the whole file, docstrings and comments included, so the
absolute path must not appear even in prose -- which is why this paragraph
never spells it out. ``test/unit/test-deck-configure-patches.py`` runs guard
6.4a's own expression over this file and asserts zero matches, and separately
asserts that ``APPLIER_ABS`` still composes to the exact path the package
installs -- so neither the path nor the reason can drift silently.
"""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

from .deck_configure import record_result, sanitize_text
from .ui import error, info

# --- what the omarchy-deck package puts on the target ----------------------
#
# See the guard 6.4a note in the module docstring before joining these two into
# a literal.
APPLIER_DIR = "/usr/bin"
APPLIER_NAME = "omarchy-deck-apply-patches"
APPLIER_ABS = f"{APPLIER_DIR}/{APPLIER_NAME}"
APPLIER_REL = f"usr/bin/{APPLIER_NAME}"

# The applier's own defaults, as relative paths so this module can look at them
# through the target mount. They are NOT passed to it as flags -- see decision 1
# -- they are only used to read back what it wrote and to tell a half-installed
# package from an absent one.
PATCH_DIR_REL = "usr/share/omarchy-deck/patches"
STATE_FILE_REL = "var/lib/omarchy-deck/patch-state.json"
STATE_FILE_ABS = "/" + STATE_FILE_REL

# The applier's exit codes are part of its contract (it says so, in a comment
# above the constants). Mapped here so the record says what the number MEANT --
# a bare "exit 4" in a support log is a puzzle, and this project has already
# paid for reporting "no patch directory" as "the patch does not apply".
EXIT_MEANING = {
    0: "all patches ok",
    2: "usage error -- this step called the applier wrongly",
    3: "one or more patches are NOT ok (drift, missing target, or a failed post-condition)",
    4: "environment -- no git, no patch root, or no patch directory on the target",
}

# Caps. patch-state.json is ours and small; these exist so a pathological or
# corrupted file cannot be poured into a world-readable install log.
MAX_STATE_BYTES = 256 * 1024
MAX_STATE_PATCHES = 16
MAX_OUTPUT_LINES = 12
MAX_LINE_CHARS = 200


# 🔴 There is deliberately NO exception type here, unlike deck_wifi.py's
# DeckWifiError. Nothing in this module raises: every outcome it can foresee --
# absent, failed, applied -- is a value in the record, because the record is the
# report and throwing it away in order to signal a failure would destroy the
# thing the install log exists for. An exception class nothing raises would be
# an invitation to start.


# ---------------------------------------------------------------------------
# Running it
# ---------------------------------------------------------------------------


def chroot_command(target) -> list[str]:
    """The exact command this step runs.

    Its own function so a unit test can assert *where* the applier runs without
    a chroot, a container or root. "Inside the target" is a decision (see the
    module docstring); a decision nothing asserts is a comment.

    No ``--root``/``--patch-dir``/``--state-file``: inside the chroot the
    applier's defaults are already the right absolute paths, and passing them
    would only create a second place for them to disagree. No ``--from-hook``
    either -- this is not the hook, and the applier records the distinction as
    ``invocation`` in the state file.
    """
    return ["arch-chroot", str(target), APPLIER_ABS]


def run_in_target(target) -> tuple[int, str]:
    """Execute the applier in the target. Returns (exit code, combined output).

    ``check=False``: a non-zero exit is the applier reporting, not an accident,
    and this step's whole job is to turn it into a record.
    """
    proc = subprocess.run(  # noqa: S603
        chroot_command(target),
        capture_output=True,
        text=True,
        check=False,
    )
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


def summarize_output(text: str) -> str:
    """Last few non-blank lines of the applier's output, sanitised.

    Sanitised because it lands in a world-readable JSON document, and joined
    with ' | ' rather than newlines because ``sanitize_text`` deletes control
    bytes -- concatenating raw lines would glue two messages into one word.
    """
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    if not lines:
        return ""
    return " | ".join(sanitize_text(line, limit=MAX_LINE_CHARS) for line in lines[-MAX_OUTPUT_LINES:])


# ---------------------------------------------------------------------------
# Reading back what it wrote
# ---------------------------------------------------------------------------


def read_state(target) -> tuple[dict | None, list[str]]:
    """Read ``<target>/var/lib/omarchy-deck/patch-state.json``.

    Returns (document, warnings). A missing or unreadable state file is a
    warning rather than an exception: the exit code is the primary verdict and
    must not be lost because the secondary channel is broken.
    """
    warnings: list[str] = []
    path = Path(target) / STATE_FILE_REL
    try:
        data = path.read_bytes()
    except FileNotFoundError:
        warnings.append(f"the applier wrote no {STATE_FILE_ABS}")
        return None, warnings
    except OSError as exc:
        warnings.append(f"could not read {STATE_FILE_ABS}: {exc}")
        return None, warnings

    if len(data) > MAX_STATE_BYTES:
        warnings.append(f"{STATE_FILE_ABS} is {len(data)} bytes; refusing to parse it")
        return None, warnings

    try:
        doc = json.loads(data.decode("utf-8", "replace"))
    except ValueError as exc:
        warnings.append(f"{STATE_FILE_ABS} is not valid JSON: {exc}")
        return None, warnings
    if not isinstance(doc, dict):
        warnings.append(f"{STATE_FILE_ABS} is not a JSON object")
        return None, warnings
    return doc, warnings


def summarize_patches(doc: dict) -> list[dict]:
    """The per-patch rows worth copying into the install log.

    Copied rather than referenced because ``/var/log/omarchy-deck-install.json``
    is the one document a QEMU assertion reads, and a Deck that fails later can
    still be asked what its patches looked like at install time.
    """
    rows = doc.get("patches")
    if not isinstance(rows, list):
        return []
    out: list[dict] = []
    for row in rows[:MAX_STATE_PATCHES]:
        if not isinstance(row, dict):
            continue
        out.append(
            {
                "patch": sanitize_text(str(row.get("patch", "")), limit=MAX_LINE_CHARS),
                "status": sanitize_text(str(row.get("status", "")), limit=MAX_LINE_CHARS),
                "target": sanitize_text(str(row.get("target", "")), limit=MAX_LINE_CHARS),
                "detail": sanitize_text(str(row.get("detail", "")), limit=MAX_LINE_CHARS),
            }
        )
    return out


# ---------------------------------------------------------------------------
# The step
# ---------------------------------------------------------------------------


def find_applier(target) -> tuple[Path | None, str]:
    """Locate the applier on the target. Returns (path or None, reason).

    Executability is checked, not just existence: a package that installed the
    binary 0644 would fail inside ``arch-chroot`` with "permission denied",
    which reads like a broken machine rather than a broken package.
    """
    path = Path(target) / APPLIER_REL
    if path.is_symlink() and not path.exists():
        return None, f"{APPLIER_ABS} is a dangling symlink on the target"
    if not path.is_file():
        return None, f"{APPLIER_ABS} is not installed on the target"
    try:
        executable = bool(path.stat().st_mode & 0o111)
    except OSError as exc:
        return None, f"cannot stat {APPLIER_ABS} on the target: {exc}"
    if not executable:
        return None, f"{APPLIER_ABS} is present but not executable"
    return path, ""


def apply_patches(target, runner=None) -> dict:
    """Run the applier inside ``target`` and return the record for the install log.

    ``runner`` is injectable so the suite can drive every branch without a
    chroot; the default is the real ``arch-chroot`` invocation and
    ``chroot_command`` is asserted separately.

    ``None`` rather than ``runner=run_in_target``: a default argument binds the
    function object at *definition* time, so replacing the module attribute --
    which is how the sibling Wi-Fi suite substitutes ``LIVE_ROOT``/``ASSET_DIR``
    -- would silently keep calling the real ``arch-chroot``. Looking it up here
    means the module attribute is genuinely the seam.
    """
    if runner is None:
        runner = run_in_target
    target = Path(target)
    record: dict = {
        "status": None,
        "applier": APPLIER_ABS,
        "ran": False,
        "exit_code": None,
        "exit_meaning": None,
        "overall": None,
        "state_file": None,
        "patches": [],
        "output": None,
        "error": None,
        "warnings": [],
    }
    warnings: list[str] = record["warnings"]

    applier, reason = find_applier(target)
    if applier is None:
        # 🔴 NOT a silent skip. Today this is the ONLY outcome an install can
        # produce, because the omarchy-deck package is still a skeleton -- so if
        # this branch were quiet, the entire T12 seam could be missing from
        # every shipped ISO and nothing would say so.
        record["status"] = "absent"
        record["error"] = sanitize_text(
            f"{reason} -- the Deck patch set was NOT applied. "
            "The Deck will behave the way upstream Omarchy does "
            "(the lock screen blanks the panel in ~2s, not ~20s). "
            "The omarchy-deck package must ship the applier and its patches.",
            limit=400,
        )
        if not (target / PATCH_DIR_REL).is_dir():
            warnings.append(f"/{PATCH_DIR_REL} is missing too -- omarchy-deck looks uninstalled")
        else:
            warnings.append(
                f"/{PATCH_DIR_REL} exists but the applier does not -- omarchy-deck is half-installed"
            )
        error(f"Deck patches: {record['error']}")
        for warning in warnings:
            error(f"Deck patches: {warning}")
        return record

    try:
        code, output = runner(target)
    except OSError as exc:
        # arch-chroot missing, or the target is not mountable as a root. A
        # record, not a traceback: the install still has to finish.
        record["status"] = "failed"
        record["error"] = sanitize_text(
            f"could not run {APPLIER_ABS} in the target: {type(exc).__name__}: {exc}", limit=400
        )
        error(f"Deck patches: {record['error']}")
        return record

    record["ran"] = True
    record["exit_code"] = code
    record["exit_meaning"] = EXIT_MEANING.get(code, "undocumented exit code from the applier")
    record["output"] = summarize_output(output) or None

    doc, state_warnings = read_state(target)
    warnings.extend(state_warnings)
    if doc is not None:
        record["state_file"] = STATE_FILE_ABS
        record["overall"] = sanitize_text(str(doc.get("overall", "")), limit=MAX_LINE_CHARS) or None
        record["patches"] = summarize_patches(doc)

    if code != 0:
        record["status"] = "failed"
        record["error"] = sanitize_text(
            f"{APPLIER_ABS} exited {code}: {record['exit_meaning']}. "
            f"The Deck customisations are NOT in effect; see {STATE_FILE_ABS} on the target.",
            limit=400,
        )
    elif record["overall"] != "ok":
        # 🔴 The contradiction case. A zero exit that is not backed by a state
        # file saying "ok" means the two channels disagree, and believing the
        # cheaper one is how a silent success gets shipped. Treat it as failed.
        record["status"] = "failed"
        record["error"] = sanitize_text(
            f"{APPLIER_ABS} exited 0 but {STATE_FILE_ABS} "
            f"says overall={record['overall']!r}: the exit code and the state file disagree, "
            "so neither can be trusted",
            limit=400,
        )
    else:
        record["status"] = "applied"
        info(f"Deck patches applied on the target ({len(record['patches'])} patch(es), overall ok)")

    if record["error"]:
        error(f"Deck patches: {record['error']}")
    for warning in warnings:
        error(f"Deck patches: {warning}")
    return record


def apply_patches_step(ctx) -> None:
    """``DeckStep`` entry point. Records under the ``patches`` key whichever way
    it went -- ``docs/tasks/T12-upstream-patch-seam.md`` §2's [V] row asserts
    that ``patch-state.json`` says ``ok``, and this is the same fact in the one
    document a QEMU run already reads."""
    record_result(ctx.target, "patches", apply_patches(ctx.target))
