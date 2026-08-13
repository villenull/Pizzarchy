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
    from . import (
        deck_autologin,
        deck_input,
        deck_menu_lock,
        deck_monitors,
        deck_patches,
        deck_rotation,
        deck_session_settings,
        deck_wifi,
    )

    return [
        DeckStep("wifi", deck_wifi.carry_wifi_step, critical=False),
        # T5e, 5.1. 🔴 THE ONLY critical=True STEP IN THE REGISTRY, and
        # deck_autologin.py argues it at length: its failure is not a
        # degradation but a Deck that cannot be logged into with a controller,
        # and every channel this project normally relies on to report a
        # degradation lives on the installed system, i.e. behind the login that
        # failed. A visibly failed phase is the only report that reaches a human.
        DeckStep("autologin", deck_autologin.autologin_step, critical=True),
        # T5e, 5.3. Two steps, not one: site defaults and a per-user dotfile
        # fail differently and are verified differently, and a single step would
        # let one missing file take the other down with it. Both non-critical --
        # both depend on upstream-owned files that drift, and both leave a Deck
        # that boots and logs in. deck_session_settings.py states the
        # counter-argument (the idle lock is not cosmetic) rather than hiding it.
        DeckStep("session_dconf", deck_session_settings.session_dconf_step, critical=False),
        DeckStep("idle_policy", deck_session_settings.idle_policy_step, critical=False),
        # T5f, 5.2. Two steps, not one: the boot menu and the kernel console are
        # different surfaces, written through different mechanisms, destroyed by
        # different events, and verified against different parsers. Both
        # non-critical -- deck_rotation.py argues it, and the short form is that
        # the danger is in the WRITE, not in the skip: a step that writes nothing
        # leaves the boot chain exactly as upstream produced it, while a sideways
        # menu still boots, autologins and reaches Gaming Mode by controller.
        #
        # 🔴 Before `finalize_limine_boot`, which is what makes the placement
        # load-bearing rather than tidy: that phase runs `limine-update`, which
        # regenerates the entry blocks in the very file limine_rotation writes a
        # global into. The header survives it (measured 2026-08-11); the step
        # asserts the entry region it did not touch is byte-identical.
        DeckStep("limine_rotation", deck_rotation.limine_rotation_step, critical=False),
        DeckStep("tty_rotation", deck_rotation.tty_rotation_step, critical=False),
        # T5f, 5.2's FOURTH surface -- the desktop's own `hl.monitor` transform
        # and scale, in the per-user ~/.config/hypr/monitors.lua. A third step
        # rather than a branch of the two above, because it is a different
        # mechanism again: not a boot-chain file at all but a Lua dotfile that
        # REPLACES Omarchy's shipped default wholesale, that has to be written
        # into both /etc/skel and the created user's home (§3 trap (a)), and
        # that Hyprland discards ENTIRELY on a syntax error while
        # `hyprctl configerrors` stays clean.
        #
        # `critical=False`, argued in deck_monitors.py: the failure is a
        # sideways, wrongly-scaled DESKTOP, and the Deck still boots, still
        # autologins and still reaches Gaming Mode -- which gamescope rotates
        # itself and which never reads this file. That is a degradation, not
        # deck_autologin's no-way-in-at-all. The module states the honest
        # weakness too: a sideways boot menu is on screen for three seconds and
        # a sideways desktop is the whole of Desktop Mode.
        #
        # ⚠️ transform = 3 here and interface_rotation: 90 in the step above
        # describe ONE physical panel. Limine and Hyprland use OPPOSITE sign
        # conventions. Both were seen on the screen; do not reconcile them.
        DeckStep("desktop_rotation", deck_monitors.desktop_rotation_step, critical=False),
        # T5f, 5.6's other two lock-producer fixes, and §5.25 decision #1 --
        # ~/.config/hypr/input.lua's `above_lock = 2` layer rule (makes the
        # on-screen keyboard answerable over a lock surface) and §5.24a
        # requirement #1's two `misc` DPMS lines (stops the QAM menu popup
        # from waking a blanked, locked panel via Hyprland's own generic
        # wake-on-any-input). Splices into the SAME per-user input.lua
        # src/deck-session.sh's install_osk_kb_layout_rule already writes
        # into, with its own distinct markers -- see deck_input.py's
        # docstring for why the two writers cannot share one.
        #
        # `critical=False`, same argument as `desktop_rotation`: the failure
        # is a degradation (the lock screen is answerable but the panel wakes
        # for QAM while locked, or the OSK draws beneath the lock surface),
        # and the Deck still boots, still autologins and still reaches
        # Gaming Mode. It does NOT mask omarchy-sleep-lock.service -- that is
        # §5.6's other producer, and it is not wired into this registry at
        # all yet (deck_input.py's docstring records the gap).
        DeckStep("lock_wake_dpms", deck_input.lock_wake_dpms_step, critical=False),
        # T5f, 5.6's third lock producer -- the `system.lock` row in Omarchy's
        # own menu. `critical=False` is argued at length in deck_menu_lock.py,
        # and it is the closest call in this registry: its failure leaves a
        # handheld that can be put behind a password prompt it cannot answer.
        # What keeps it non-critical is that the escape exists -- a ten-second
        # power hold reboots into the autologin `deck_autologin` guarantees --
        # whereas the greeter that step defends against has no escape at all.
        DeckStep("menu_lock_row", deck_menu_lock.menu_lock_row_step, critical=False),
        #
        # T12. `critical=False` is argued at length in deck_patches.py's
        # docstring (decision 2) -- it deliberately overrules
        # `docs/findings/T12-upstream-patch-seam.md` §3.4's "a non-zero exit
        # fails the install", because the failure is a degradation (~2s instead
        # of ~20s of panel-on after lock) while the abort is a Deck with no
        # operating system, and the hard failure belongs at build time in guard
        # 6.6 instead.
        #
        # Last on purpose, in two senses. It runs inside the target via
        # arch-chroot, so it is the slowest step and the one most likely to be
        # interfered with by anything else that touches /usr/share/omarchy;
        # and it patches the packaged Limine template, so it must land before
        # the LATER PHASE `finalize_limine_boot` regenerates /boot from it.
        DeckStep("patches", deck_patches.apply_patches_step, critical=False),
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
