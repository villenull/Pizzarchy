"""Bake ``src/deck-session.sh``'s stages onto the target, at install time.

SHIPPED AS ``/usr/share/omarchy-iso/orchestrator/deck_session_bake.py``. The
``session_bake`` step registered in ``deck_configure.deck_steps``.

THE DEFECT THIS CLOSES
======================

An ISO-installed Deck had **no session-switching layer at all**: no "Switch to
Desktop" row in Steam's power menu, no way back from the desktop to Gaming
Mode, and no target-side ``deck-input-mapper`` to drive the desktop with the
controller. Confirmed on hardware -- Steam's power menu simply had no desktop
row.

Not one line of that was missing from the repository. ``src/deck-session.sh``
implements all of it, ran on the previous Deck install for weeks, and every
capability in it was watched working on hardware. It was **wired into
nothing**: it was written for the post-install SSH loop, and the installer never
called it. That is the same shape as
``docs/findings/P32-steam-never-installed.md`` -- a component that exists, is
tested, and no code path reaches.

🔴 DECISION 1 -- RUN THE SCRIPT, DO NOT REIMPLEMENT IT
======================================================

``deck-session.sh`` is the single source of truth for the session layer, and
this module contains **no** copy of its logic: not a path, not a unit body, not
a sudoers line, not the list of stages. It stages the script into the target,
runs it there one stage at a time, and turns what it printed into a record.

The alternative -- porting the stages to Python, the way ``deck_autologin.py``
and ``deck_session_settings.py`` deliberately did for *their* three settings --
was rejected here for a reason those two do not share: they carry three
constants and one file format each, all of them re-derivable, and their
docstrings carry the reasoning across. The session layer is ~1500 lines of
hardware-measured behaviour (Steam's PATH being ``/usr/bin:/bin`` only, the
``zz-`` sort order, the sddm stop→settle→start sequence, the lizard-mode
cgroup-kill hole, the UTF-16 escape for the menu glyph). A second implementation
of that is not a port, it is a fork -- and this project already knows what
happens when one fact lives in two files.

🔴 DECISION 2 -- INSIDE THE TARGET, VIA ``arch-chroot``
=======================================================

Same call shape and the same reasoning as ``deck_patches.py`` decision 1, and
here it is not even a close call: the stages ask the machine questions that only
the target can answer (is ``gamescope-wayland.desktop`` installed, is there an
``sddm.service``, what is in ``/etc/sddm.conf.d``, does ``python3`` import
``evdev``), and they write to absolute paths. Run from the live side they would
inspect and configure **the ISO**.

The script is run with ``DECK_SESSION_CHROOT=1``, which is a mode it grew for
this step -- read the CHROOT MODE block at the top of ``src/deck-session.sh``
before changing anything here. Its contract, in one line: every stage does its
**file-level work** and prints a ``DEFERRED (chroot):`` line for each check that
needs a running system. Nothing is silently skipped, and nothing an installed
Deck *needs* is left to first boot.

🔴 DECISION 3 -- ONE ``arch-chroot`` PER STAGE, NOT ONE FOR THE WHOLE SCRIPT
============================================================================

``deck-session.sh`` with no arguments runs every stage and stops at the first
failure (``set -e``). That is right for a human at a terminal and wrong here,
twice over:

* **The report.** A step that stops at the first failure records one failure and
  nothing about the eleven stages after it. Per-stage invocation gives
  ``/var/log/omarchy-deck-install.json`` a status for every stage, which is what
  makes this diagnosable from a QEMU run or from a support log.
* **The blast radius.** The stages are independent artefacts. A missing
  ``luac``, an absent ``python-evdev`` or a greeter config upstream moved should
  cost exactly the stage that needs it, not the "Switch to Desktop" row.

It costs re-running ``stage-preconditions`` once per stage, because
``run_stage`` does that deliberately (a single-stage run must not skip the
probes). The probes install nothing and write nothing, and the one thing they
*would* cost -- a confusing repeat in the log -- is worth per-stage truth.

⚠️ **One exception, and it is an explicit outcome rather than a skip.** If
``stage-preconditions`` itself fails, every stage after it would fail with the
same message for the same reason -- twelve identical failures that bury the one
fact. So the remaining stages are recorded ``status="skipped"`` naming the
precondition failure, which says more, not less.

``critical=False``, AND HERE IS THE ARGUMENT
============================================

*Against:* this is the whole reason the project exists. A Deck with no way to
reach Desktop Mode is not the product, and ``deck_autologin.py`` is
``critical=True`` for a comparable-sounding reason.

*For ``critical=False`` -- and this is what won:*

1. **The failure is a degradation, and the device is fully usable.** Autologin
   is ``critical=True`` because its failure is a Deck **nobody can log into**:
   an SDDM password prompt with no keyboard, no escape. This step's failure is a
   Deck that boots into Gaming Mode, plays games, and cannot reach the desktop
   by controller -- annoying, recoverable (an external keyboard, a TTY, or a
   re-run over SSH), and not a device with no way in.
2. **The asymmetry is brutal, exactly as ``deck_patches.py`` argues.**
   ``critical=True`` here would discard a partitioned, LUKS'd, ~1200-package
   install because ``luac`` was missing or upstream renamed a greeter config --
   on a device whose only recovery is another full install from a controller.
3. **The inputs are upstream-owned and they drift.** The stages read Omarchy's
   greeter Lua (hashed, and it warns when it moves), Valve's session file,
   ``python-evdev``, ``dconf``, ``timedatectl``. ``deck_patches.py``'s argument 3
   applies unchanged.
4. **Every channel survives.** Unlike autologin's case, the person affected can
   read all of them: the machine boots and logs in, so
   ``/var/log/omarchy-deck-install.json``, the install log and the journal are
   all reachable.

⚠️ ``critical=False`` is not "failures are tolerated". Every stage's outcome is
recorded, every failure is printed through the orchestrator's ``error``, and
every deferred check is copied into the record verbatim. ``critical`` governs
only whether an *unexpected* exception escaping this module aborts the install.

WHAT THE ISO HAS TO CARRY, AND WHY IT IS A DIRECTORY
====================================================

``iso/bin/build`` stages the payload into
``/usr/share/omarchy-iso/deck/session/`` (see ``SESSION_ASSET_DIR``). This module copies
**every regular file** it finds there into the target and requires only that
``deck-session.sh`` is among them.

That is deliberate: the *set* of files is decided by ``deck-session.sh`` itself
(``MAPPER_SRC_NAME`` and ``OSK_MODULES``, which ``stage-input-mapper`` demands
beside the script), so the build derives the list from that declaration exactly
as its step 5b derives the live mapper's destination from ``deck-form.sh``. A
list written down again here would be a third copy of it. If a file the script
needs is missing, the script says so itself, by name, and the stage that needs
it fails -- which is a better error than anything this module could invent.

⚠️ **Modes are set here, not on the ISO.** archiso copies ``airootfs`` with
``--no-preserve=mode``, so everything in the image lands 0644 no matter how the
build wrote it. The script is chmod'd 0755 **after** the copy into the target,
which makes the ISO-side mode irrelevant and needs no ``file_permissions``
entry.

WHY THE PAYLOAD IS STAGED AND THEN REMOVED
==========================================

It goes to a temporary directory under the target and is deleted afterwards. It
is not part of the installed system: the ``omarchy-deck`` package owns what
ships, and leaving an unowned copy of a 5000-line script in ``/usr/local`` would
be a second, unversioned source of truth on every Deck -- the exact thing
decision 1 exists to prevent. What the stages *install* stays, of course; the
scaffolding does not.
"""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

from .deck_configure import record_result, sanitize_text
from .deck_user import DeckUserDeferred, DeckUserError, resolve_target_user
from .ui import error, info

# --- what the ISO carries ---------------------------------------------------
#
# On the LIVE root, beside deck-wifi-first-boot.sh's directory. Staged by
# iso/bin/build out of src/, for the reason its step 5b gives for the live
# mapper: src/ is the single source of truth and a tracked second copy in the
# overlay drifts silently from the one every test reads.
SESSION_ASSET_DIR = Path("/usr/share/omarchy-iso/deck/session")
SCRIPT_NAME = "deck-session.sh"

# --- where it goes on the target, briefly -----------------------------------
#
# Under the target's own /var/tmp so the chroot can execute it at a path that
# exists inside the chroot. Removed when the step finishes -- see the docstring.
STAGE_DIR_REL = "var/tmp/omarchy-deck-session-bake"
SCRIPT_MODE = 0o755
PAYLOAD_MODE = 0o644

# The env the script is run with. DECK_SESSION_CHROOT selects the adapted
# branches; DECK_SESSION_USER answers "who is the desktop user", which inside a
# chroot nothing else can (there is no SUDO_USER, and $USER is root).
CHROOT_ENV_FLAG = "DECK_SESSION_CHROOT"
USER_ENV_FLAG = "DECK_SESSION_USER"

# The verb that prints the stage list. Asked of the script rather than written
# down here -- decision 1.
LIST_VERB = "list-bake-stages"

# The prefix deck-session.sh's defer() prints. Every line carrying it is copied
# into the record, because a deferred check that is only in the install log is a
# deferred check nobody will read.
DEFER_MARKER = "DEFERRED (chroot):"

# Bounds. A stage that hangs must not hang the install: the stages start no
# services and wait on nothing, so a stage past this is wedged rather than slow.
STAGE_TIMEOUT_SECONDS = 300
LIST_TIMEOUT_SECONDS = 60

# Caps, for the same reason deck_patches.py has them: this lands in a
# world-readable JSON document next to the install log.
MAX_OUTPUT_LINES = 20
MAX_LINE_CHARS = 300
MAX_DEFERRALS = 40
MAX_STAGES = 40


class DeckSessionBakeError(Exception):
    """The session layer could not be baked at all.

    Raised only for the cases where there is nothing to run or no target user
    to run it for -- and even then it is caught in ``bake_session`` and turned
    into a record. Nothing here propagates: ``critical=False`` means the record
    IS the report, and throwing it away to signal a failure would destroy it.
    """


# ---------------------------------------------------------------------------
# Getting the payload into the target
# ---------------------------------------------------------------------------


def stage_payload(target, asset_dir=None) -> tuple[Path, list[str]]:
    """Copy the ISO's session payload into the target. Returns (dir, files).

    Every regular file in ``asset_dir``, flat -- see the docstring for why the
    set is not enumerated here. Raises ``DeckSessionBakeError`` when the
    directory or the script is missing, which is the "the ISO does not carry the
    session layer" case and has to be loud: it means a build regression, and it
    would otherwise look exactly like a Deck whose stages all happened to fail.
    """
    source = Path(asset_dir or SESSION_ASSET_DIR)
    if not source.is_dir():
        raise DeckSessionBakeError(
            f"{source} is not on this ISO, so there is no session layer to bake. "
            "The build stages it out of src/; an image without it produces a Deck with no "
            "way to switch between Gaming Mode and the desktop."
        )

    names = sorted(p.name for p in source.iterdir() if p.is_file())
    if SCRIPT_NAME not in names:
        raise DeckSessionBakeError(
            f"{source} carries {names or 'nothing'} but not {SCRIPT_NAME}, which is the "
            "script this step runs. Nothing was staged."
        )

    dest = Path(target) / STAGE_DIR_REL
    # Removed first rather than merged into: a re-run must not inherit a file an
    # earlier one left behind, and the stages read whatever is beside the script.
    shutil.rmtree(dest, ignore_errors=True)
    dest.mkdir(parents=True, exist_ok=True)
    os.chmod(dest, 0o755)

    for name in names:
        shutil.copyfile(source / name, dest / name)
        # 🔴 Set here, not inherited. archiso copies airootfs with
        # --no-preserve=mode, so everything on the ISO is 0644 and the script
        # would arrive non-executable -- which inside arch-chroot is "permission
        # denied", i.e. reads as a broken machine rather than a broken build.
        os.chmod(dest / name, SCRIPT_MODE if name == SCRIPT_NAME else PAYLOAD_MODE)

    return dest, names


def script_path_in_target(stage_dir=None) -> str:
    """The script's path *as the chroot sees it* -- absolute, target-relative.

    Its own function because the two views of the same file (``<target>/var/tmp/
    .../deck-session.sh`` out here, ``/var/tmp/.../deck-session.sh`` in there)
    are the kind of thing that gets confused once and then works by accident.
    """
    return "/" + (stage_dir or STAGE_DIR_REL).strip("/") + "/" + SCRIPT_NAME


def chroot_command(target, argv) -> list[str]:
    """The exact command this step runs.

    Its own function so "it runs inside the target" is assertable without a
    chroot, a container or root -- the same seam ``deck_patches.chroot_command``
    and ``deck_session_settings.chroot_command`` are.
    """
    return ["arch-chroot", str(target), *argv]


def chroot_env(user: str) -> dict:
    """The environment the script sees inside the chroot.

    Built from this process's, not from scratch: ``arch-chroot`` needs PATH and
    the script shells out to ordinary tools. The two flags are what select the
    adapted branches -- see the CHROOT MODE block in ``src/deck-session.sh``.
    """
    env = dict(os.environ)
    env[CHROOT_ENV_FLAG] = "1"
    env[USER_ENV_FLAG] = user
    return env


def run_in_target(target, argv, user: str, timeout: int = STAGE_TIMEOUT_SECONDS) -> tuple[int, str]:
    """Run the script in the target. Returns (exit code, combined output).

    ``check=False``: a non-zero exit is a stage reporting, not an accident, and
    turning it into a record is this module's whole job.
    """
    try:
        proc = subprocess.run(  # noqa: S603
            chroot_command(target, argv),
            capture_output=True,
            text=True,
            check=False,
            timeout=timeout,
            env=chroot_env(user),
        )
    except subprocess.TimeoutExpired as exc:
        captured = (exc.stdout or "") + (exc.stderr or "")
        if isinstance(captured, bytes):
            captured = captured.decode("utf-8", "replace")
        return 124, captured + f"\nTIMED OUT after {timeout}s\n"
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


# ---------------------------------------------------------------------------
# Reading what it said
# ---------------------------------------------------------------------------


def summarize_output(text: str) -> str:
    """The last few non-blank lines, sanitised and joined with ' | '.

    Joined rather than newline-separated because ``sanitize_text`` deletes
    control bytes, and concatenating raw lines would glue two messages into one
    word. Copied from ``deck_patches.summarize_output`` on purpose: two support
    logs that read differently for no reason are two things to learn.
    """
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    if not lines:
        return ""
    return " | ".join(sanitize_text(line, limit=MAX_LINE_CHARS) for line in lines[-MAX_OUTPUT_LINES:])


def deferrals(text: str) -> list[str]:
    """Every ``DEFERRED (chroot):`` line the script printed, in order.

    🔴 THE POINT OF THE WHOLE MARKER. A check that could not run at install time
    is a fact about the shipped machine, and burying it in an output tail that
    only keeps the last few lines would lose exactly the ones that matter: they
    are printed in the MIDDLE of a stage, and the tail keeps the end.
    """
    found: list[str] = []
    for line in text.splitlines():
        marker = line.find(DEFER_MARKER)
        if marker == -1:
            continue
        found.append(sanitize_text(line[marker + len(DEFER_MARKER):].strip(), limit=MAX_LINE_CHARS))
        if len(found) >= MAX_DEFERRALS:
            break
    return found


def parse_stage_list(text: str) -> list[str]:
    """The stage names ``list-bake-stages`` printed.

    Filtered to the shape a stage name has, because this is the one place a
    corrupted or half-written script could hand us an arbitrary string that
    then gets *executed* in the chroot. Nothing here invents a name when the
    list is empty -- the caller treats that as a failure.
    """
    stages: list[str] = []
    for raw in text.splitlines():
        name = raw.strip()
        if not name.startswith("stage-"):
            continue
        if not all(ch.isalnum() or ch == "-" for ch in name):
            continue
        if name not in stages:
            stages.append(name)
        if len(stages) >= MAX_STAGES:
            break
    return stages


# ---------------------------------------------------------------------------
# The step
# ---------------------------------------------------------------------------


def bake_session(ctx, runner=None, asset_dir=None) -> dict:
    """Bake the session layer onto ``ctx.target`` and return the record.

    ``runner`` is injectable so the suite can drive every branch without a
    chroot; the default is the real ``arch-chroot`` invocation, and
    ``chroot_command`` is asserted separately. ``None`` rather than
    ``runner=run_in_target`` for ``deck_patches.apply_patches``'s reason: a
    default argument binds the function object at *definition* time, so
    replacing the module attribute would silently keep calling the real one.
    """
    if runner is None:
        runner = run_in_target
    target = Path(ctx.target)

    record: dict = {
        "status": None,
        "script": None,
        "user": None,
        "payload": [],
        "stages": {},
        "ok": [],
        "failed": [],
        "skipped": [],
        "deferred": [],
        "error": None,
        "warnings": [],
    }
    warnings: list[str] = record["warnings"]

    # --- who it is for ------------------------------------------------------
    #
    # The same resolution deck_autologin.py uses, and it is confirmed against
    # the target's own /etc/passwd rather than taken from what archinstall was
    # told (docs/tasks/T5-fork-plan.md §3 trap (a)). Every stage that writes a
    # per-user file -- the menu row, the keyboard layout rule -- needs the real
    # home directory, and a guessed /home/<name> is that trap in its purest form.
    try:
        user, user_warnings = resolve_target_user(ctx)
    except DeckUserDeferred as exc:
        # No account exists yet by design. The per-user halves (the Quickshell
        # menu row, the XKB rule) have nobody to be written for, and the
        # system-wide halves would install a shim whose sudoers grant names a
        # user that does not exist -- worse than absent, because it looks done.
        record["status"] = "deferred"
        record["error"] = sanitize_text(
            f"{exc}. The session-switching layer was NOT baked: with no account there is no "
            "home to write the menu row into and no user to grant the switch to. A Deck "
            "installed this way reaches Gaming Mode and has no way to the desktop until "
            "deck-session.sh is run on it.",
            limit=400,
        )
        error(f"Deck session bake: {record['error']}")
        return record
    except DeckUserError as exc:
        record["status"] = "failed"
        record["error"] = sanitize_text(f"{type(exc).__name__}: {exc}", limit=400)
        error(f"Deck session bake: {record['error']}")
        return record

    warnings.extend(user_warnings)
    record["user"] = sanitize_text(user.name)

    # --- get the payload into the target ------------------------------------
    try:
        stage_dir, names = stage_payload(target, asset_dir)
    except (DeckSessionBakeError, OSError) as exc:
        record["status"] = "absent" if isinstance(exc, DeckSessionBakeError) else "failed"
        record["error"] = sanitize_text(f"{type(exc).__name__}: {exc}", limit=400)
        error(f"Deck session bake: {record['error']}")
        return record

    record["payload"] = [sanitize_text(n) for n in names]
    script = script_path_in_target()
    record["script"] = script

    try:
        _run_stages(record, target, script, user.name, runner)
    finally:
        # Always, and on every path: the scaffolding is not part of the
        # installed system. A failure to clean it up is a warning rather than a
        # failure -- a leftover directory under /var/tmp is untidy, and losing
        # the record of a successful bake over it would be worse.
        try:
            shutil.rmtree(stage_dir)
        except OSError as exc:
            warnings.append(f"could not remove the staging directory /{STAGE_DIR_REL}: {exc}")

    for warning in warnings:
        error(f"Deck session bake: {warning}")
    return record


def _run_stages(record: dict, target: Path, script: str, user: str, runner) -> None:
    """Ask the script for its stage list, run each one, fill in the record."""
    code, output = runner(target, [script, LIST_VERB], user, LIST_TIMEOUT_SECONDS)
    stages = parse_stage_list(output) if code == 0 else []
    if not stages:
        # 🔴 NOT recoverable with a hardcoded list, deliberately. A list written
        # down here would be a second source of truth for which stages an
        # install bakes -- decision 1 -- and it would be the copy that is wrong
        # the day someone adds a stage.
        record["status"] = "failed"
        record["error"] = sanitize_text(
            f"'{SCRIPT_NAME} {LIST_VERB}' exited {code} and named no stages, so nothing was "
            "run. The script could not be executed inside the target (no arch-chroot? no "
            "bash? not executable?), or it is a version that predates that verb. "
            f"Output: {summarize_output(output) or '<none>'}",
            limit=400,
        )
        error(f"Deck session bake: {record['error']}")
        return

    precondition_failure = ""
    for stage in stages:
        if precondition_failure:
            # Every stage re-runs stage-preconditions (deck-session.sh's
            # run_stage does that on purpose), so with the probes failing these
            # would all fail identically. Recorded as skipped WITH the reason --
            # which says more than twelve copies of one message, and is not a
            # silent skip: it is in the record, in the log, and named.
            entry = {
                "status": "skipped",
                "exit_code": None,
                "reason": precondition_failure,
                "output": None,
                "deferred": [],
            }
            record["stages"][stage] = entry
            record["skipped"].append(stage)
            continue

        code, output = runner(target, [script, stage], user)
        stage_deferrals = deferrals(output)
        entry = {
            "status": "ok" if code == 0 else "failed",
            "exit_code": code,
            "output": summarize_output(output) or None,
            "deferred": stage_deferrals,
        }
        record["stages"][stage] = entry
        record["deferred"].extend(f"{stage}: {line}" for line in stage_deferrals)

        if code == 0:
            record["ok"].append(stage)
            continue

        record["failed"].append(stage)
        error(
            f"Deck session bake: stage '{stage}' exited {code}: "
            f"{entry['output'] or '<no output>'}"
        )
        if stage == "stage-preconditions":
            precondition_failure = sanitize_text(
                f"stage-preconditions failed ({entry['output'] or 'no output'}), and every "
                "stage re-runs it, so the rest would fail the same way",
                limit=400,
            )

    if not record["failed"]:
        record["status"] = "baked"
        info(
            f"Session layer baked onto the target: {len(record['ok'])} stage(s) ok, "
            f"{len(record['deferred'])} check(s) deferred to first boot"
        )
        return

    record["status"] = "partial" if record["ok"] else "failed"
    record["error"] = sanitize_text(
        f"{len(record['failed'])} session stage(s) failed ({', '.join(record['failed'])})"
        + (f" and {len(record['skipped'])} were skipped" if record["skipped"] else "")
        + ". The Deck boots and reaches Gaming Mode; what it may be missing is the way to "
        "Desktop Mode and back. Re-runnable on the installed machine: every stage is "
        "idempotent.",
        limit=400,
    )
    error(f"Deck session bake: {record['error']}")


def session_bake_step(ctx) -> None:
    """``DeckStep`` entry point. Records under the ``session_bake`` key.

    No re-raise, unlike ``deck_autologin.autologin_step``: this step is
    ``critical=False`` (see the module docstring), so the record is the whole
    report and there is nothing an exception would add to it.
    """
    record_result(ctx.target, "session_bake", bake_session(ctx))
