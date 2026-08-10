# DRAFT — upstream bug report for basecamp/omarchy

**STATUS: DRAFT ONLY. Not filed. No `gh` commands run, no network calls
made. Requires explicit operator approval before posting anywhere** — per
project hard rule against publishing/posting without approval.

*Note (2026-08-10): this is the only draft still in the working tree. The
earlier `DRAFT-upstream-bugs-deckarchy.md` and `DRAFT-outreach-28allday.md`
were removed during repo cleanup (recoverable from git history) — the
project moved past deckarchy entirely, and the outreach's premise died with
the DeckShift drop. References to the deckarchy draft below are historical.*

This is a standalone writeup of the same bug `DRAFT-upstream-bugs-
deckarchy.md`'s "Bug 5 of 5" already describes from the `limine-snapper.sh`
angle (drafted against `aorumbayev/deckarchy`, before the isolation
reproduction had been run). That reproduction has since been run — see
below — and confirms the bug belongs against `basecamp/omarchy`, not
`deckarchy`. This file is the fuller, `omarchy`-targeted version of that
report, written for `PLAN.md` §8.5 / `TASK-T1-kernel-and-boot.md` step 5.
The two drafts describe the same root cause; this one should supersede
Bug 5 as the thing actually filed, if/when the operator approves filing
anything.

---

## Title

Default `fmask=0077,dmask=0077` ESP mount (archinstall + Limine + UKI)
breaks `limine-snapper.sh`'s user-space config detection — reproduces on
stock archinstall + Omarchy with no Steam Deck / third-party packages
involved

## Hypothesis / root cause

Not a bug in either project alone but a collision between two
independently reasonable defaults:

- **archinstall** deliberately hardens the ESP to `fmask=0077,dmask=0077`
  on Limine+UKI setups. There's a defensible security rationale: UKIs are
  bootable executables, and restricting the ESP to root is a reasonable
  default hardening choice.
- **Omarchy's `limine-snapper.sh`** does a plain `[[ -f <limine.conf> ]]`
  existence/read check as the invoking user, which implicitly assumes the
  ESP (and thus `/boot`) is traversable by that user. Under `0077` it is
  not — `/boot` itself is mode `0700` — so the stat fails for a normal
  user even though the file exists at a path the script explicitly probes.

The result is a misleading error: `limine-snapper.sh` reports `Error:
Limine config not found`, which reads as a missing-file bug, when the
actual problem is a permissions bug. The file is present; the script
running as an unprivileged user simply cannot see it.

## Reproduction steps

1. Fresh `archinstall` with Limine bootloader + UKI mode selected. This
   produces the default `fmask=0077,dmask=0077` `/boot` entry in
   `/etc/fstab` — confirm with:
   ```
   findmnt -n -o OPTIONS --mountpoint /boot
   grep '/boot' /etc/fstab
   ```
2. Install Omarchy on top of that base, no other customization.
3. As a normal (non-root) user, run `limine-snapper.sh` (or trigger it
   indirectly via a snapshot/rollback flow that shells out to it).
4. Observe `Error: Limine config not found`.
5. As root, confirm the file is actually present, e.g.
   `sudo ls -la /boot/EFI/BOOT/limine.conf` (or whichever of the script's
   candidate paths applies) — it exists.

**Isolation result (already run, not hypothetical):** this was reproduced
on a stock Omarchy Quattro install with **zero Steam Deck or
Pizzarchy-project packages installed** — `/etc/fstab` ships
`fmask=0077,dmask=0077` on `/boot` purely from archinstall's own Limine+UKI
defaults. See `PROGRESS.md` (Findings, the paragraph beginning "PLAN.md
§8.5 — REPRODUCED on a stock Omarchy Quattro install"). That's the
evidence this is a generic Omarchy-on-archinstall interaction, not
something specific to any Deck-oriented fork or tooling — hence filing
against `basecamp/omarchy` rather than a downstream project.

## Expected behavior

`limine-snapper.sh` finds and correctly reads its config regardless of the
ESP's `fmask`/`dmask`, by running its existence/read check with elevated
privileges (however Omarchy's own tooling typically escalates — e.g. the
same mechanism the rest of the script presumably already uses for any
privileged operations) rather than assuming the invoking user can traverse
the ESP unassisted.

## Actual behavior

Silently reports the config as missing when it is actually a permissions
problem. This is actively misleading for anyone debugging the symptom —
it points at the wrong class of bug (missing file) instead of the real one
(unreadable file), and nothing in the error message hints at a permissions
cause.

## Suggested scope for the report

- File against `basecamp/omarchy` (the isolation step above confirms this
  is not a `deckarchy`/Deck-specific issue).
- Propose the cleaner fix: elevate the specific existence/read check
  rather than asking users (or downstream installers) to loosen the ESP
  mount globally. A global `fmask`/`dmask` loosening to make one script's
  unprivileged check succeed makes the entire ESP world-readable,
  including the UKIs themselves — a real, if modest, security regression
  from archinstall's own default, applied just to satisfy one script's
  assumption. That tradeoff is documented in this project at
  `FINDING-esp-permissions.md`.
- Flag as a secondary, practical note for whoever fixes this: `mount -o
  remount` does **not** re-apply `fmask`/`dmask` on vfat — changing the
  ESP's mount options (if that route is ever taken instead) requires a
  full `umount`/`mount` cycle or a reboot. This is a non-obvious trap that
  cost real debugging time in this project and is worth mentioning even if
  the eventual fix is the elevated-check approach rather than a mount-option
  change.
- Do **not** propose that Omarchy adopt this project's own workaround (the
  `fmask=0133,dmask=0022` mount-option loosening in
  `omarchy-deck-kernel.sh`'s `stage_esp_permissions`) as the upstream fix.
  That's a stopgap this project applies to unblock its own installs; the
  ask here is narrower and more upstream-appropriate: fix the check itself.

## Relationship to `DRAFT-upstream-bugs-deckarchy.md`

That file's "Bug 5 of 5" is the same bug, drafted earlier and hedged on
which repo it belonged to pending the isolation reproduction (its own
"Notes for whoever reviews before filing" section flags this explicitly).
The reproduction is now done and points at `basecamp/omarchy`. If/when the
operator reviews these drafts, this file is the one to file (against
`omarchy`); Bug 5 in the `deckarchy` draft can be treated as superseded/
withdrawn rather than filed separately, to avoid a duplicate report split
across two repos for one root cause.

## Filing checklist (not yet done — for whoever files this, if approved)

- [ ] Operator approval obtained
- [ ] Confirm current `basecamp/omarchy` issue tracker doesn't already have
      this reported (search for "Limine config not found", "fmask",
      "limine-snapper")
- [ ] File against `basecamp/omarchy`
- [ ] Link back to `DRAFT-upstream-bugs-deckarchy.md` Bug 5 as prior art /
      mark that entry superseded once filed
