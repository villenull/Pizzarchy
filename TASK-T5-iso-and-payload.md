# T5 — ISO build and offline package payload

**Model: Sonnet. Opus for the package-signing question** — that's where the
non-obvious failure lives.

## Objective

A single bootable ISO carrying everything needed for a fully offline
install: Arch base, Neptune kernel and firmware, Limine, Omarchy Quattro,
gamescope-session packages, and Steam.

## Prerequisites

- **R1's 10.1 finding** — whether the offline mirror can carry Valve
  packages, and how signing is handled. This task's shape depends on it.
- **R1's 10.4 finding** — whether Steam works offline at all.
- T1, T3, T4 far enough along to know the final package list.

## Steps

### 1. Fork the ISO builder

Fork `omacom-io/omarchy-iso` (archiso-based, MIT). Use
`OMARCHY_INSTALLER_REPO` / `OMARCHY_INSTALLER_REF` or the hook mechanism
identified by R1's 10.2 finding — **prefer hooks over forking
`basecamp/omarchy` wholesale**, since Quattro reportedly makes
`~/.local/share/omarchy` a pacman-owned symlink, which breaks
git-checkout-based integrations.

### 2. Extend the offline mirror

Per R1's 10.1 finding, add to the baked-in pacman mirror:
- `linux-neptune-*` (version per T1's decision) + headers
- `linux-firmware-neptune`, `steamdeck-dsp`
- `gamescope-session-*` and full dependency tree
- Steam and its 32-bit dependency tree
- Everything Omarchy Quattro needs (should already be present upstream)

**The signing issue is the likely snag.** Valve's repos use
`SigLevel = Never`. Determine whether the build re-signs locally or carries
a SigLevel exception into the ISO's `pacman.conf`. Get this right or the
offline install fails at package-install time with confusing errors.

### 3. Wire in the script-override loader

From T0 step 3 — the ISO should prefer installer scripts from an override
directory on the USB's data partition if present. This is what keeps the
iteration loop fast during T6.

### 4. Size check ⚠️ do this early, not late

Steam + full desktop + kernel + firmware will be several GB. Confirm the
total fits a practical USB target (16GB, ideally with room to spare on
32GB) **before** the payload is fully assembled. Discovering a size problem
near ship date is avoidable.

### 5. Build reproducibly

- One command produces the ISO
- CI builds it on tag and publishes as an artifact
- Version stamped into the image so a booted ISO can identify itself

## Done when

- [ ] `./bin/build-iso` (or equivalent) produces a bootable ISO
- [ ] ISO boots in QEMU
- [ ] Full offline install completes in QEMU with **networking disabled at
      the hypervisor level** — not merely unconfigured
- [ ] All Deck packages present in the offline mirror and installable
- [ ] Signing resolved; no `SigLevel` errors during install
- [ ] Size within target, recorded in `PROGRESS.md`
- [ ] Script-override loader works from the data partition
- [ ] CI publishes the ISO artifact

## Failure modes to watch for

- **"Offline" that isn't.** Test with networking hard-disabled in QEMU.
  An install that quietly reaches out will pass a naive test and fail on
  the operator's Deck in a room with no Wi-Fi.
- **Signing errors surfacing as something else.** Package-signature
  failures produce confusing messages. If install fails mysteriously at the
  package stage, check signing first.

## Escalate if

- Size exceeds a 32GB USB
- Steam can't be legally redistributed in the payload (R1 10.4) — changes
  the offline story and needs an operator decision
