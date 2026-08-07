# T0 — Test infrastructure

**Model: Sonnet** (Haiku for the CI YAML itself)
**Do this first. Everything else is slower without it.**

## Objective

Collapse the edit-test loop from ~30 minutes to seconds for the majority of
work, and make regressions catchable without human involvement.

## Why this is task #1

The naive loop is: change code → rebuild ISO → flash USB (~20 min) → boot
Deck → install → find bug → repeat. Nearly all of that is avoidable, and
the project has enough surface area that paying the loop tax on every
iteration would dominate total build time. See `PLAN.md` §9 for the full
reasoning and the five-tier model.

## Prerequisites

None. This is the entry point.

## Steps

### 1. Automated QEMU install harness (highest value)

- The upstream `omacom-io/omarchy-iso` repo has `./bin/omarchy-iso-boot`
  for QEMU testing. Read that script; reuse rather than reinvent.
- Build a harness that: boots a built ISO in QEMU with a virtual disk,
  drives the installer non-interactively (answer file / preseed), and exits
  with a meaningful code.
- **Assert on artifacts, not log text.** Log-scraping would have passed on
  the `PLAN.md` §8.1 bug (script printed success while doing nothing).
  Mount the resulting disk image and assert:
  - Partition table matches expectations (ESP + btrfs root)
  - `/boot/EFI/Linux/*.efi` — correct count and names
  - Limine config parses and contains exactly the expected entries
  - `pacman -Q` package set includes the required packages
  - Expected systemd units are enabled
- Make it runnable as one command, e.g. `./test/vm-install-test.sh <iso>`.

### 2. Ventoy workflow for the physical USB

- Write `FINDING-testing-usb.md` documenting: install Ventoy once on the test
  USB; thereafter "flashing" is copying an `.iso` onto the exposed data
  partition (~2–4 min vs ~20), and multiple builds can live side by side
  for bisecting a regression.
- This is a human-executed setup step. Document it clearly, list it under
  "Blocked on human" in `PROGRESS.md`, and do not attempt it yourself.

### 3. Script-override mechanism (avoid rebuilding the ISO for script edits)

- Design the ISO so installer scripts are loaded from an override location
  if present — e.g. an `omarchy-deck/` directory on the Ventoy data
  partition takes precedence over the ISO's baked-in copy.
- Most iterations change scripts, not the base image. This turns the common
  case from a multi-GB rebuild+copy into a few-KB file copy.
- Implement the loader logic now even though the ISO doesn't exist yet
  (T5); write it as a small, testable function with fixtures.

### 4. SSH iterate-in-place loop for the Deck

- Write `deck-sync.sh`: rsync changed scripts to the Deck over SSH,
  run a named stage, stream back `journalctl` output.
- Assume the Deck has `sshd` enabled and a known hostname/IP; make both
  configurable via env vars with sane defaults.
- Target: a ~30 second loop for post-install hardware work, versus a full
  reinstall. This is the single biggest win for T3.
- Also write `deck-snapshot.sh` / `deck-rollback.sh` wrapping btrfs
  snapshots, so a destructive experiment is a ~1 minute recovery rather than
  a reinstall. Check whether Omarchy's Limine+snapper integration already
  provides this before hand-rolling it.

### 5. CI

- GitHub Actions workflow: on every push run `shellcheck` + `bash -n` on all
  shell, plus unit tests.
- On tag/RC: build the ISO, run the QEMU install test from step 1, publish
  the ISO as an artifact so a Ventoy copy is the only manual step before a
  hardware test.

### 6. Static analysis baseline

- `shellcheck` across all shell in the repo, including
  `omarchy-deck-kernel.sh`. Fix what it flags there — it was written
  from a validated manual process but has never been executed anywhere.

## Done when

- [ ] `./test/vm-install-test.sh` runs unattended and exits non-zero on a
      deliberately broken build (verify by breaking something on purpose)
- [ ] Artifact assertions cover: partitions, UKI files, Limine entries,
      package set, enabled units
- [ ] `FINDING-testing-usb.md` exists and is specific enough to follow without
      further explanation
- [ ] Script-override loader implemented and unit-tested with fixtures
- [ ] `deck-sync.sh` written (untested against real hardware is OK
      here — flag it for the operator)
- [ ] CI green on a trivial push
- [ ] `shellcheck` clean across the repo

## Failure modes to watch for

- **Building a test harness that only passes.** Always verify a test can
  fail: break something deliberately and confirm it's caught.
- **Over-engineering the answer-file format.** The installer doesn't exist
  yet (T4). Keep the interface minimal and expect to revise it.

## Escalate if

- QEMU can't boot the upstream Omarchy ISO at all on the operator's machine
  (may indicate a missing virtualization dependency — that's a
  "Blocked on human" item, not something to work around).
