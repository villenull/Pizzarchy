# T1 — Kernel, firmware, and boot chain

**Model: Opus.** This is the highest-density bug area in the project and the
one that cost the most time to debug by hand. Worth the upgrade.

> **Status: steps 1–8 done. One item remains open:** the stock→Neptune
> conversion path is hardware-unvalidated — seven of ten stages have only ever
> run their no-op path on the real Deck (`PROGRESS.md` §5.2). Closes by design
> in `ROADMAP.md` P1.5.
>
> Steps 7–8 were completed 2026-08-10 (`vm-default-entry-test.sh`, all four
> suites green against the snapshot-bearing substrate).
>
> Also note **step 6's five stage names are not the ones that shipped.** The
> script has ten, and `stage-bootloader` / `stage-permissions` were
> deliberately rejected as aliases because both would be lies (this script does
> not write boot entries — `limine-entry-tool` does — and it is specifically the
> ESP's *mount options*). Use `./omarchy-deck-kernel.sh list-stages`.

## Objective

Fully automated, idempotent, version-resilient Neptune kernel + Limine boot
setup. Given a fresh Arch base install on a Deck, one script produces a
system that boots the Neptune kernel with no human intervention and stays
working across kernel updates.

## Why Opus

Every bug in `PLAN.md` §8 lives here. Silent failures, wrong ESP paths,
mount-option subtleties that don't behave as documented, and a boot chain
where a wrong guess means a device that doesn't boot. A fast wrong answer is
expensive; the debugging loop is the slowest one in the project.

## Prerequisites

- T0 done (you'll want the QEMU harness to test this without hardware)
- Read `PLAN.md` §6.3, §8 (all), §11

## Starting point

`omarchy-deck-kernel.sh` already exists in this repo. It was written
directly from a validated manual install and encodes fixes for §8.1–8.5.
**It has never been executed anywhere.** Treat it as a well-informed draft,
not working code.

## Steps

### 1. Review and harden the existing script

- `shellcheck` it; fix everything.
- Trace every code path by hand. Pay particular attention to:
  - The ESP detection logic (the `findmnt` chain is convoluted — simplify it
    while keeping the "never assume a path" property)
  - The Limine cmdline extraction `awk` — it depends on the stock entry's
    exact format and will break if archinstall's output changes
  - The idempotency claims — actually verify by running twice in a VM

### 2. Generalize away the hardcoded kernel version

Currently pinned to `linux-neptune-611` throughout: package name, preset
filename, UKI filename, Limine entry path. Per `PLAN.md` §11 this is a real
fragility — a Valve bump to `-612` leaves users with a routine `pacman -Syu`
that silently stops producing a bootable entry.

- Detect the available Neptune kernel dynamically.
- Decide: pin to a known-good version (safer, needs manual bumps) or track
  latest (more fragile, less maintenance)? **Recommend pinning with an
  explicit, easily-updated version constant**, and document the reasoning.
- Whatever you choose, the *entry regeneration* must be glob-keyed, not
  version-keyed.

### 3. The pacman hook (`PLAN.md` §11)

- Write a pacman hook that regenerates the UKI **and** reconciles the Limine
  entry on any `linux-neptune*` package change.
- Must be idempotent and must not duplicate entries on repeat runs.
- Test by forcing a reinstall of the kernel package (fast, doesn't require
  waiting for a real version bump).

### 4. Make it CI-testable

- Add non-interactive flags so it runs inside T0's QEMU harness.
- Assertable exit codes; no interactive prompts in automated mode.

### 5. Verify the §8.5 permission decision

The script currently loosens the ESP to `fmask=0133,dmask=0022`. Per
`PLAN.md` §8.5 this is a **security-relevant global loosening applied to fix
one script's permission assumption**.

- Reproduce the underlying issue on a stock archinstall Limine+UKI system
  with no Deck packages, to confirm it's a generic
  Omarchy-on-archinstall bug rather than Deck-specific.
- If confirmed, draft an upstream issue for Omarchy proposing the cleaner
  fix (elevate the existence check rather than loosen the mount).
- Keep the workaround for now, but **document the tradeoff visibly** in the
  script and in `FINDING-esp-permissions.md` — don't bury it.

### 6. Split into stages

For T0's `deck-sync.sh` loop to be useful, each stage must be independently
runnable:
- `stage-repos` — add Valve repos
- `stage-kernel` — install kernel/firmware
- `stage-uki` — patch preset, generate UKI
- `stage-bootloader` — Limine entry
- `stage-permissions` — ESP mount options

Each idempotent, each with its own exit code, each callable individually.

### 7. `stage-default-entry` — the last real gap

Nothing in the toolchain owns Limine's `default_entry`. On a fresh install
following this project's flow, an end user boots the **stock Arch kernel** on
Deck hardware, gets degraded hardware support, and has no way to know why.
The controller-only constraint makes it worse: "just pick the right entry"
assumes a user who knows to interrupt a boot menu.

- Write the **entry path** (`Omarchy/linux-neptune-611`), not a numeric index.
  `limine-snapper-sync` inserts and removes a Snapshots submenu and can
  renumber indices out from under a static integer.
- Key on the `linux-neptune-*` glob, like every other reconcile path.
- Put it in `reconcile` too, so the pacman hook re-asserts it on kernel change.

**⚠️ First, prove the entry-path form actually works.** It was applied to the
operator's Deck and the machine booted Neptune unattended — but the target is
*also* entry #1, so a silent fallback to index 1 looks identical. A fix that
works by accident is worse than none.

Settle it on the `vm-neptune-image.sh` substrate, not on hardware: set
`default_entry` to a **non-first** entry, boot, and assert `LoaderEntrySelected`.
Limine implements the Boot Loader Interface, so `bootctl status` reports the
selected entry as a path from userspace — no screen-scraping.

### 8. The deliberate-failure test

Never run. Corrupt the Limine config and confirm the script fails loudly
rather than continuing. This is the one done-criterion that directly tests
the property the whole project exists to preserve.

## Done when

- [x] `shellcheck` clean
- [x] Runs twice in a row in a VM with identical end state (idempotency
      proven, not asserted)
- [x] Kernel version is a single, documented constant — not scattered
- [x] Pacman hook regenerates UKI + Limine entry on kernel reinstall,
      verified in VM
- [x] Runs unattended in T0's QEMU harness with meaningful exit codes
- [x] Each stage runnable independently
- [x] **Deliberate-failure test** — three of them, in `vm-default-entry-test.sh`:
      missing config, duplicate UKI, missing menu entry — each exits 1 with the
      right message, config restored byte-identical after
- [x] §8.5 reproduction attempted and documented either way
- [x] **`stage-default-entry` exists, path-form proven in QEMU** — a non-first
      entry planted as default was the entry Limine actually booted
      (`LoaderEntrySelected` + `uname -r` as independent witnesses)
- [ ] **Stock→Neptune conversion validated on hardware** (`PROGRESS.md` §5.2,
      `ROADMAP.md` P1.5)

## Failure modes to watch for

- **Recreating the §8.1 bug.** Any code path that can print progress while
  having done nothing is a defect. `set -euo pipefail` is necessary but not
  sufficient — verify state after each stage, don't trust that commands ran.
- **Assuming `mount -o remount` re-applies `fmask`/`dmask`.** It does not on
  vfat. Full `umount`/`mount` cycle or reboot. This cost real time to learn.
- **Hardcoding the Limine config path.** Five candidate locations exist;
  probe all of them.

## Escalate if

- Testing requires writing to the physical Deck (it shouldn't for most of
  this — QEMU covers the boot chain). Prepare, describe, wait.
- The Neptune kernel can't be installed in a VM at all, forcing hardware
  testing earlier than planned.
