# `src/iso-patches/` — patches against the ISO *builder*, staged until T5 wires them

Patches here modify files in `omacom-io/omarchy-iso` (the ISO builder tree),
as distinct from `src/omarchy-deck-patches/`, which patches the **installed
runtime** at pacman time (T12).

## 🔴 Why they are staged here and not in `iso/overlay/patches/`

`iso/bin/build` applies **every** `overlay/patches/*.patch` it finds. Dropping
one there takes effect on the very next build — and `docs/tasks/T5-fork-plan.md`
§7 is explicit:

> **Do not start T5c before T5a proves parity.** An overlay whose base build was
> never shown to reproduce the known-good ISO cannot attribute any later failure.

**Parity is not proven yet.** `docs/findings/T5a-parity.md` found the pipeline
reproduces the reference almost exactly but the artifact is broken (it bundles a
runtime missing `omarchy-setup-system`, so it dies at phase 5 of 14), and the
`--local-source` build that should fix it has not reported. Adding overlay
content now would mean the next parity measurement compares a *patched* build
against the reference and cannot attribute a difference to either cause.

`test/unit/test-iso-build.sh` enforces the empty overlay, and it caught this
within minutes of the first patch landing.

## Moving one into place

When T5's slice is ready **and parity is proven**, `git mv` the patch into
`iso/overlay/patches/` and update `test-iso-build.sh`'s empty-overlay assertion
in the same commit — the assertion is the record of *why* the overlay was empty,
so retiring it deliberately is the point at which that reason expires.

| Patch | Applies to | Owner |
|---|---|---|
| `omarchy-install-dashboard.patch` | `configs/airootfs/usr/local/bin/omarchy-install-dashboard` | T4a — sources `deck-dashboard.sh` so S6/S7/S8 exist at all |
| `configure-deck-phase.patch` | `configs/airootfs/usr/share/omarchy-iso/orchestrator/main.py` | T5 seam S3 — inserts `("Configuring Steam Deck", configure_deck)` into `build_phases` |

## 🔴 `configure-deck-phase.patch` does not stand alone

The patch adds `from .deck_configure import configure_deck`, and an ImportError
there aborts the install **before any phase runs** (`build_phases(ctx)` is
evaluated as an argument to `run()`). That is the loud, early failure we want —
but it means promoting this patch **without** the additive files below turns
every install into an immediate traceback. Promote them in one commit:

| Repo file | Lands in the overlay at | Then on the ISO at |
|---|---|---|
| `src/deck_configure.py` | `overlay/configs/airootfs/usr/share/omarchy-iso/orchestrator/deck_configure.py` | same |
| `src/deck_wifi.py` | `…/orchestrator/deck_wifi.py` | same |
| `src/deck-wifi-first-boot.sh` | `…/usr/share/omarchy-iso/deck/deck-wifi-first-boot.sh` | same |
| `src/omarchy-deck-wifi-first-boot.service` | `…/usr/share/omarchy-iso/deck/omarchy-deck-wifi-first-boot.service` | same |

The last two are *assets copied onto the target* by the phase, not files the
live ISO runs; `deck_wifi.ASSET_DIR` is the one place that path is written
down. A missing asset is reported into
`/var/log/omarchy-deck-install.json` and does not stop the install —
`test/unit/test-deck-configure-wifi.py` asserts both halves of that.
