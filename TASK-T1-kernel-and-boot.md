# T1 — Kernel, firmware, and boot chain

**Model: Opus.** This is the highest-density bug area in the project and the
one that cost the most time to debug by hand. Worth the upgrade.

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

## Done when

- [ ] `shellcheck` clean
- [ ] Runs twice in a row in a VM with identical end state (idempotency
      proven, not asserted)
- [ ] Kernel version is a single, documented constant — not scattered
- [ ] Pacman hook regenerates UKI + Limine entry on kernel reinstall,
      verified in VM
- [ ] Runs unattended in T0's QEMU harness with meaningful exit codes
- [ ] Each stage runnable independently
- [ ] Deliberate-failure test: corrupt the Limine config, confirm the script
      fails loudly rather than continuing
- [ ] §8.5 reproduction attempted and documented either way

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
