# `src/iso-patches/` — patches against the ISO *builder*, staged until T5 wires them

Patches here modify files in `omacom-io/omarchy-iso` (the ISO builder tree),
as distinct from `src/omarchy-deck-patches/`, which patches the **installed
runtime** at pacman time (T12).

## 🔴 Why they are staged here and not in `iso/overlay/patches/`

`iso/bin/build` applies **every** `overlay/patches/*.patch` it finds. Dropping
one there takes effect on the very next build — and `docs/tasks/T5-fork-plan.md`
§7 was explicit that T5c (the slice that first adds overlay content) could not
start until T5a proved the pipeline reproduces the known-good ISO. Otherwise a
later parity check couldn't tell whether a difference came from our overlay or
from the pipeline itself.

**Parity was proven, and T5c has already landed.** §7's
"🟢 Outcome, 2026-08-12 — T5a is CLOSED" records the four-test re-measurement
against T5b's pinned build; `docs/findings/T5a-parity.md` Appendix A has
**P1, P2, P3 and P4 all pass**, every difference from the reference ISO
temporal, none attributable to the overlay. T5c then added its own overlay
content — `deck-valve-repos.patch` and `deck-packages.patch`, now sitting in
`iso/overlay/patches/` — which is why that directory is no longer empty.

So the reason these two patches are *still* staged here isn't parity — that's
settled. It's the patch budget below, and (for `configure-deck-phase.patch`)
the seam it depends on not being ready.

## Moving one into place

When a staged patch's slice is ready, `git mv` it into `iso/overlay/patches/`.
There is no empty-overlay assertion to retire anymore — `test/unit/test-iso-build.sh`
section 11 replaced it (in the same T5c commit that added the first overlay
content) with checks that apply directly to whatever promotion you do next:
the overlay must stay non-empty (counted, so it can't regress to a vacuous
pass), the **patch budget is ≤ 4** overlay patches, no patch may be
simultaneously staged here and promoted there, and every promoted patch must
apply cleanly to the pinned upstream (`git apply --3way` against `iso/UPSTREAM`,
checked in seconds instead of 40 minutes into a Docker build).

⚠️ **The budget is already at 4/4** (`docs/tasks/T5-fork-plan.md` §1 point 3:
"≤ 4 patch files, and a fifth should have to argue for itself"). Count it:
`iso/overlay/patches/` holds two promoted patches from T5c
(`deck-valve-repos.patch`, `deck-packages.patch`), and the two patches below
are still staged. That's 4 patches against the ISO builder tree, staged or
promoted, already spoken for — T5-fork-plan.md's own "Patch budget now 4/4"
line (§7, the T5c outcome) says so directly. Promoting one of the two below
doesn't add a new patch — it just moves an already-counted one from this
directory into `iso/overlay/patches/`, and the suite's mechanical check
(promoted count ≤ 4) still has headroom for that. What the budget actually
blocks is introducing any **additional** patch beyond these four: that has to
**argue for a fifth**, or the change belongs in the `omarchy-deck` package
instead of the ISO overlay.

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
