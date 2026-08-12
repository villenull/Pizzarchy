# `src/iso-patches/` — patches against the ISO *builder*, staged until their slice lands

Patches here modify files in `omacom-io/omarchy-iso` (the ISO builder tree),
as distinct from `src/omarchy-deck-patches/`, which patches the **installed
runtime** at pacman time (T12).

**One patch is staged here now**, `omarchy-install-dashboard.patch`, and it is
waiting on T4a, not on anything about parity or the pipeline.

## What "staged" means, and why it is not about parity any more

`iso/bin/build` applies **every** `overlay/patches/*.patch` it finds. Dropping
one there takes effect on the very next build — which is why T5a's rule was
that nothing could go into the overlay until the pipeline had been shown to
reproduce the known-good ISO. Otherwise a later parity check could not tell
whether a difference came from our overlay or from the pipeline itself.

**That is settled.** `docs/tasks/T5-fork-plan.md` §7's "🟢 Outcome,
2026-08-12 — T5a is CLOSED" records the four-test re-measurement against T5b's
pinned build; `docs/findings/T5a-parity.md` Appendix A has **P1, P2, P3 and P4
all pass**, every difference from the reference ISO temporal, none attributable
to the overlay. T5c and T5d then added overlay content of their own.

So a patch sits here for exactly one reason now: **the code it depends on is
not in the overlay yet.** A patch is not a unit of work; a patch plus the files
it references is.

## Moving one into place

When a staged patch's slice is ready, `git mv` it into `iso/overlay/patches/`
**in the same commit as every file it depends on**. `test/unit/test-iso-build.sh`
enforces the mechanical half (in the sections that replaced T5a's
empty-overlay rule — **numbered 18 and 19 now**; older notes, this file
included, called it "section 11" long after it had moved, which is its own
small lesson about citing a number instead of a name): the overlay must stay
non-empty
(counted, so it cannot regress to a vacuous pass), the **patch budget is ≤ 4**
overlay patches, no patch may be simultaneously staged here and promoted
there, every promoted patch must apply cleanly to the pinned upstream
(`git apply --3way` against `iso/UPSTREAM`, checked in seconds instead of 40
minutes into a Docker build), and — added by T5d — **every relative import a
promoted patch introduces must have a matching module in the overlay's
orchestrator directory.** That last one exists because of the failure described
below, which was documented here for a day and enforced by nothing.

⚠️ **The budget is 4/4 and promoting does not change it.** Count it:
`iso/overlay/patches/` holds `deck-valve-repos.patch` and `deck-packages.patch`
(T5c) and `configure-deck-phase.patch` (T5d, promoted 2026-08-12); this
directory holds `omarchy-install-dashboard.patch`. That is 4 patch files
against the ISO builder tree, staged or promoted, already spoken for.
Promoting the one below moves an already-counted file; it does not add one.
What the budget blocks is a **fifth**: it has to argue for itself
(`docs/tasks/T5-fork-plan.md` §1 point 3), or the change belongs in the
`omarchy-deck` package rather than the ISO overlay. Note that "add a hunk to an
existing patch" is the cheap way to stay inside the budget, and it is the right
one when the new hunk edits a file that patch already edits.

| Patch | Applies to | Owner |
|---|---|---|
| `omarchy-install-dashboard.patch` | `configs/airootfs/usr/local/bin/omarchy-install-dashboard` | T4a — sources `deck-dashboard.sh` so S6/S7/S8 exist at all |

⚠️ **This one has the same shape as the hazard below.** It adds
`source /usr/share/omarchy-iso/deck-dashboard.sh` to a script that runs on
every install, and `deck-dashboard.sh` is currently `src/deck-dashboard.sh` —
i.e. nowhere on the ISO. Promoting the patch alone makes the install dashboard
fail on a missing file. When T4a lands, the file goes into the overlay
alongside the patch, at the path it occupies on the ISO.

## 🔴 The failure this directory exists to prevent — and what T5d did about it

`configure-deck-phase.patch` (now promoted) adds
`from .deck_configure import configure_deck` to `main.py`'s `build_phases`.
An ImportError there aborts the install **before any phase runs**
(`build_phases(ctx)` is evaluated as an argument to `run()`). That is the loud,
early failure we want — but it means promoting the patch **without** its
additive files turns every install into an immediate traceback, before
partitioning.

**T5d promoted the patch and its four files in one commit**, and they now live
in the overlay at the paths they occupy inside the ISO:

| In the repo | On the ISO |
|---|---|
| `iso/overlay/configs/airootfs/usr/share/omarchy-iso/orchestrator/deck_configure.py` | same path, minus the overlay prefix |
| `…/orchestrator/deck_wifi.py` | same |
| `…/usr/share/omarchy-iso/deck/deck-wifi-first-boot.sh` | same |
| `…/usr/share/omarchy-iso/deck/omarchy-deck-wifi-first-boot.service` | same |

**There is exactly one copy of each**, and it is the overlay's. They used to
live under `src/`; keeping a second copy there would have been the drift this
project keeps getting bitten by, and it would have hidden them from
`tools/iso-payload-audit.sh`, which walks the overlay tree. The rule that falls
out of it: **a file that ships on the ISO and nowhere else lives in the overlay,
at its shipped path.** (`src/` keeps what ships to the *installed* Deck, and
what ships to both — `deck-input-mapper.py`, the OSK modules — still needs a
staging answer, which T5 does not owe yet.)

The last two are *assets copied onto the target* by the phase, not files the
live ISO runs; `deck_wifi.ASSET_DIR` is the one place that path is written
down. A missing asset is reported into `/var/log/omarchy-deck-install.json` and
does not stop the install — `test/unit/test-deck-configure-wifi.py` asserts
both halves of that.
