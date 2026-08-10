# T6 — Integration, hardware QA, and release

> **Status: not started, gated on Omarchy 4.0 stable.** Note §6's "submit the
> `28allday` outreach" is now optional — this project no longer depends on
> DeckShift (`PROGRESS.md` §2.4). §4's recovery documentation is still
> required and still unwritten (`PROGRESS.md` §5.8).

**Model: Opus.** Final verification; a miss here ships broken.

## Objective

Rebase everything onto Omarchy Quattro stable, run full end-to-end hardware
validation, and ship.

## Prerequisites

- T1, T3, T4, T5 complete
- **Omarchy Quattro stable released.** Until then, do the rebase-prep work
  against beta but hold final validation.

## Steps

### 1. Rebase onto Quattro stable

Quattro is a full shell rewrite (Quickshell-based bar/launcher/menus/OSD).
The most likely breakage is **T3's UI integration points** — the Desktop
Mode icon placement and the return-to-Gaming-Mode affordance. Re-verify
both against stable rather than assuming beta behavior carried over.

Budget this as real work, not a formality.

### 2. Full end-to-end hardware run (tier T4 in `PLAN.md` §9.2)

The complete matrix, on the operator's OLED Deck, with **no network
available at all**:

1. Fresh ISO copied to Ventoy USB
2. Boot from USB
3. Complete install using only Deck buttons — no keyboard connected
4. First boot lands in Gaming Mode
5. Controller, Wi-Fi, Bluetooth, audio, haptics all work with no user setup
6. Desktop Mode reachable by controller
7. Omarchy desktop fully functional
8. Return to Gaming Mode works
9. Reboot from each state persists correctly

Every step pass/fail recorded. Any fail → fix → rerun the affected portion
(not necessarily the whole matrix, but be honest about blast radius).

### 3. Kernel update resilience

Verify T1's pacman hook survives a real kernel package change: force a
reinstall, reboot, confirm the Neptune entry still boots. This is the
failure mode most likely to hit users weeks after install, when the
operator isn't watching.

### 4. Recovery documentation

Document prominently how a user returns to stock SteamOS via Valve's
official recovery image. This is both an ethical baseline for a
wipe-the-device project and the best way to make people comfortable trying
it. Put it in the README, not buried.

### 5. Honest support claims

- OLED: verified
- LCD: **untested** — say so plainly in the README. Do not claim support
  that hasn't been validated. Consider recruiting an LCD tester from the
  Omarchy community for a follow-up release.

### 6. Upstream contributions

With operator approval, submit the `PLAN.md` §8 bug reports to
`aorumbayev/deckarchy` and open the `28allday` conversation drafted in R1.
These benefit the ecosystem regardless of this project's trajectory.

### 7. Release

- Tag, build, sign, publish the ISO with a checksum
- README: what it is, what works, what's untested, how to recover
- Known issues list — accurate, not aspirational

## Done when

- [ ] Rebased onto Quattro stable; both session-switch directions re-verified
- [ ] Full hardware matrix passed on OLED, every step recorded
- [ ] Offline install verified with no network present
- [ ] Kernel update resilience verified
- [ ] Recovery path documented prominently
- [ ] LCD status stated honestly
- [ ] Release published with checksum
- [ ] Upstream reports submitted (with approval)

## Failure modes to watch for

- **Declaring victory on a partial matrix.** All nine steps, in order, in
  one run. A pass assembled from separate partial runs isn't a pass.
- **Quietly dropping a broken feature.** If something doesn't work, it goes
  in known issues, not out of the README.

## Escalate if

- Quattro stable breaks something structurally (e.g. the session-switch
  mechanism no longer works) — that's a scope conversation, not a fix
- Any hardware step fails in a way suggesting a firmware or kernel issue
  outside this project's control
