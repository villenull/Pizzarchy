"""``configure_deck`` -- the Steam Deck orchestrator phase (T5 seam S3).

SHIPPED AS ``/usr/share/omarchy-iso/orchestrator/deck_configure.py``, i.e. a
module *inside* the upstream orchestrator package, which is why the imports
below are relative. It is not importable standalone and is not meant to be:
``test/unit/test-deck-configure-wifi.py`` builds the package shape around it,
which is also how that suite proves the relative imports are the right ones.

WHY THIS FILE EXISTS SEPARATELY FROM ITS STEPS
==============================================

``docs/tasks/T5-fork-plan.md`` §3 seam S3 puts exactly one new entry in
``main.py``'s ``build_phases``. Everything the installed system needs and
upstream does not do has to hang off that single entry: the Wi-Fi carry-over
(this slice), 5.1/5.5's autologin, 5.2's rotations, 5.6's lock producers, and
T12's ``omarchy-deck-apply-patches`` call
(``docs/findings/T12-upstream-patch-seam.md`` §3.4). Those are separate
sessions and separate agents, so the phase is a **registry of steps** rather
than one long function: a later slice appends a ``DeckStep`` and touches
nothing that already works.

THE TWO RULES THAT MAKE THE REGISTRY SAFE
=========================================

1. **``critical`` is never defaulted.** Every step states whether its failure
   should abort the install. §4.1 is explicit that the *degradation* is allowed
   and the *silence* is not -- an offline install must still finish -- so
   ``critical=False`` is the common answer and it must be a decision, not an
   omission. ``DeckStep`` therefore has no default for it.
2. **A non-critical failure is recorded, not swallowed.** It lands in
   ``/var/log/omarchy-deck-install.json`` under the step's key with
   ``status: "error"``, and it prints through the orchestrator's own ``error``
   so it reaches the install log (`CLAUDE.md`: never silently swallow a
   failure). ``configure_deck`` returning cleanly means "every step reported",
   never "every step worked".
"""

from __future__ import annotations

import json
import os
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from .ui import error, info

# Relative to the install target. §4.1 requirement (ii)'s file, and it is
# shared: every step writes its own top-level key into the one document, so a
# QEMU assertion can read one file and see the whole phase's outcome
# (`docs/tasks/T4-screen-spec.md` §4 S6's [V] row).
DECK_INSTALL_LOG_REL = "var/log/omarchy-deck-install.json"

# The document is world-readable on purpose -- it is a support artefact next to
# omarchy-install.log. NOTHING SECRET MAY BE PUT IN IT. The Wi-Fi step records
# the SSID and never the passphrase, and its suite asserts the passphrase does
# not appear anywhere in this file.
DECK_INSTALL_LOG_MODE = 0o644

# Cap on any attacker-influenced string that reaches this document, a log line
# or a systemd unit. An SSID is at most 32 bytes; the slack is for the
# occasional multi-byte UTF-8 name, and the cap exists so a pathological value
# cannot turn a log line into a page of noise.
SANITIZE_LIMIT = 96


@dataclass(frozen=True)
class DeckStep:
    """One unit of Deck configuration. ``fn`` takes the InstallContext."""

    name: str
    fn: Callable[[object], None]
    critical: bool  # no default, deliberately -- see this module's docstring


def deck_steps() -> list[DeckStep]:
    """The steps, in run order.

    Imported lazily so that a step module which fails to import names *itself*
    in the traceback, and so this module stays importable while later slices
    are mid-flight.
    """
    from . import deck_wifi

    return [
        DeckStep("wifi", deck_wifi.carry_wifi_step, critical=False),
        # T5e: 5.1 autologin + 5.5 encryption-off (coupled -- do not split).
        # T5f: 5.2 rotations, before finalize_limine_boot runs limine-update.
        # T12: omarchy-deck-apply-patches, after the runtime is in place.
    ]


def configure_deck(ctx) -> None:
    """The phase entry point named by seam S3.

    Runs every step even when an earlier one failed: the steps are independent
    and stopping at the first failure would hide the rest of the report. Raises
    only when a step that declared itself ``critical`` failed, which is what
    ``phases.py`` turns into a halted install.
    """
    critical_failures: list[str] = []

    for step in deck_steps():
        try:
            step.fn(ctx)
        except Exception as exc:  # noqa: BLE001 -- deliberate: see below
            # Deliberately broad. A step raising anything at all must still be
            # reported into the install log and the console; letting an
            # unexpected exception type escape unrecorded is the silent-failure
            # shape this project exists to remove.
            detail = sanitize_text(f"{type(exc).__name__}: {exc}")
            error(f"Deck configuration step '{step.name}' failed: {detail}")
            try:
                record_result(ctx.target, step.name, {"status": "error", "error": detail})
            except OSError as log_exc:
                error(f"could not record the '{step.name}' failure: {log_exc}")
            if step.critical:
                critical_failures.append(step.name)

    if critical_failures:
        raise RuntimeError(
            "required Deck configuration steps failed: " + ", ".join(critical_failures)
        )

    info("Deck configuration recorded to /" + DECK_INSTALL_LOG_REL)


def sanitize_text(value: str, limit: int = SANITIZE_LIMIT) -> str:
    """Make attacker-controlled text safe to put in a log line, a JSON value or
    a systemd unit.

    Same treatment as ``deck_form_sanitize_ssid`` in ``src/deck-form.sh``:
    control bytes and DEL are **deleted** (one of them is an ANSI escape that
    repaints a root console, a CR/LF that injects a line into a key=value file,
    or a tab that corrupts a delimiter), everything else is kept -- including
    non-ASCII, because a UTF-8 SSID is ordinary and mangling it would make the
    recorded value not match the network the user actually joined.

    Truncation is marked with a trailing '...' so a value that hit the cap is
    distinguishable from one that happened to be exactly that long.
    """
    cleaned = "".join(ch for ch in value if ch >= " " and ch != "\x7f")
    if len(cleaned) > limit:
        cleaned = cleaned[:limit] + "..."
    return cleaned


def record_result(target, key: str, value) -> Path:
    """Merge ``{key: value}`` into ``<target>/var/log/omarchy-deck-install.json``.

    Merge, not overwrite: several steps write into the same document and they
    run in one process but in no fixed relationship to whatever a re-run left
    behind. Written through a temp file and ``os.replace`` for the same reason
    ``phases.py`` does -- a reader must never see a truncated document.

    A pre-existing file that is not a JSON object is moved aside to
    ``.corrupt`` and reported, rather than being silently overwritten (the
    overwrite would destroy the evidence of whatever produced it) or crashing
    the step (which would trade a bad log file for a failed install).
    """
    path = Path(target) / DECK_INSTALL_LOG_REL
    path.parent.mkdir(parents=True, exist_ok=True)

    doc: dict = {}
    if path.exists():
        try:
            loaded = json.loads(path.read_text())
        except (OSError, ValueError) as exc:
            error(f"{path} is not readable JSON ({exc}); moving it aside")
            loaded = None
        if isinstance(loaded, dict):
            doc = loaded
        else:
            path.replace(path.with_name(path.name + ".corrupt"))

    doc[key] = value

    tmp = path.with_name(f".{path.name}.tmp")
    tmp.write_text(json.dumps(doc, indent=2, sort_keys=True, default=str) + "\n")
    os.chmod(tmp, DECK_INSTALL_LOG_MODE)
    tmp.replace(path)
    return path
