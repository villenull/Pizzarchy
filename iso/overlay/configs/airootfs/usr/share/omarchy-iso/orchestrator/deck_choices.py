"""Installer variant answers for FAST-INSTALL (Stages slice, C2/C5).

The form atomically writes ``preinstalls`` and ``gaming`` (each exactly
``yes`` or ``no`` + trailing newline, mktemp-in-dir + rename) into
``/run/omarchy-deck/choices/``, then writes ``locked`` last. The early
worker restores the common image first and only then waits for ``locked``;
``preinstalls`` is immutable after the lock, while ``gaming`` may still flip
yes→no (Wi-Fi B→gaming choice) until the network gate opens, so every
gaming-gated phase re-reads it. Once online work starts the answers are
frozen. Cidata carries the same filenames; the unattended branch installs
them into the same directory.

``DECK_CHOICES_DIR`` overrides the directory so unit tests never touch
``/run``. Every validation failure raises ``RuntimeError`` with the exact
path and value -- a missing or malformed answer must abort loudly, never
default (defaulting ``no`` would silently drop Steam; defaulting ``yes``
would silently download it).
"""

from __future__ import annotations

import os
import time
from pathlib import Path


CHOICES_DIR_ENV = "DECK_CHOICES_DIR"
CHOICES_DIR_DEFAULT = "/run/omarchy-deck/choices"
PREINSTALLS_NAME = "preinstalls"
GAMING_NAME = "gaming"
LOCKED_NAME = "locked"
CHOICES_WAIT_SECS_ENV = "OMARCHY_DECK_CHOICES_WAIT_SECS"
CHOICES_WAIT_DEFAULT_SECS = 1800
CHOICES_POLL_SECS = 5


def choices_dir() -> Path:
    return Path(os.environ.get(CHOICES_DIR_ENV, CHOICES_DIR_DEFAULT))


def _read_answer(directory: Path, name: str) -> bool:
    """``True`` for ``yes``, ``False`` for ``no``. Anything else raises."""
    path = directory / name
    try:
        raw = path.read_text()
    except FileNotFoundError as exc:
        raise RuntimeError(
            f"installer choice {path} is missing; the form never answered "
            f"{name} (or the cidata drive did not carry it)"
        ) from exc
    except OSError as exc:
        raise RuntimeError(f"could not read installer choice {path}: {exc}") from exc
    value = raw.strip()
    if value == "yes":
        return True
    if value == "no":
        return False
    raise RuntimeError(
        f"installer choice {path} is {value!r}, not exactly 'yes' or 'no'; "
        "refusing to guess which variant to install"
    )


def read_choices(directory=None) -> tuple[bool, bool]:
    """``(preinstalls, gaming)``. Requires both files; ``locked`` not needed.

    Used after the lock wait and anywhere the current (possibly flipped)
    gaming answer is needed. ``preinstalls`` is only ever read after
    ``wait_locked``, where it is immutable.
    """
    directory = Path(directory) if directory is not None else choices_dir()
    return (
        _read_answer(directory, PREINSTALLS_NAME),
        _read_answer(directory, GAMING_NAME),
    )


def read_gaming(directory=None) -> bool:
    """The current gaming answer (re-read at every gaming gate)."""
    directory = Path(directory) if directory is not None else choices_dir()
    return _read_answer(directory, GAMING_NAME)


def wait_locked(directory=None) -> tuple[bool, bool]:
    """Wait for ``locked`` + both valid answers; return ``(preinstalls, gaming)``.

    Bounded by ``OMARCHY_DECK_CHOICES_WAIT_SECS`` (default 30 min -- the form
    is human-driven). Expiry raises: proceeding without answers would install
    the wrong variant, and spinning forever would wedge the live session if
    the user aborted the form.
    """
    directory = Path(directory) if directory is not None else choices_dir()
    try:
        budget = int(os.environ.get(CHOICES_WAIT_SECS_ENV, str(CHOICES_WAIT_DEFAULT_SECS)))
    except ValueError as exc:
        raise RuntimeError(
            f"{CHOICES_WAIT_SECS_ENV} is not an integer; refusing to guess the choices wait"
        ) from exc
    waited = 0
    last_error: str = "not yet checked"
    while waited < budget:
        if (directory / LOCKED_NAME).exists():
            try:
                return read_choices(directory)
            except RuntimeError as exc:
                last_error = str(exc)
        else:
            last_error = f"{directory / LOCKED_NAME} not yet written by the form"
        time.sleep(CHOICES_POLL_SECS)
        waited += CHOICES_POLL_SECS
    raise RuntimeError(
        f"installer choices never locked after {budget}s ({last_error}); "
        "aborting rather than installing an unanswered variant"
    )
