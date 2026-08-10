# T4 — Guided installer UI

**Model: Sonnet.** Scope depends entirely on T2's outcome — read that
finding before planning this task.

## Objective

An 8-screen guided install flow, navigable with only Deck buttons and
trackpads, that produces a correctly configured Omarchy 4.0 system.

> **Two changes since this was written:** the install may use Wi-Fi
> (`docs/PROGRESS.md` §2.2), which promotes screen 7 and makes controller text
> entry load-bearing; and the target is **Omarchy 4.0**, not 3.x.

## Prerequisites

- **T2 complete ✅** — `docs/findings/T2-gamepad-spike.md`. **The answer is "days,
  not weeks":** build on `gum`/`archinstall` primitives, which the mapper
  makes controller-navigable; write no custom TUI widgets. Budget the
  **text-entry** piece explicitly (finding §4) — it is the only part of this
  task the spike does not de-risk.
- T0 done (QEMU interactive testing — tier T2 in `docs/PLAN.md` §9.2)

## The screens

Full specification in `docs/PLAN.md` §6.1a. Summary — 6 blocking, 1 skippable,
1 summary:

1. **Language** — flag/name grid, legible before locale is set. No default;
   must block.
2. **Region** — sets keyboard layout + timezone + locale formatting
   together from one pick. Includes an optional keyboard-layout override on
   the same screen. *This screen exists in this form specifically because a
   mismatched layout silently corrupted commands during the manual install
   (`-O` typed as `-0`). Do not split it back into separate screens.*
3. **Agreements** — firmware/proprietary-blob notice (acknowledge only) +
   telemetry opt-in (off by default; omit the screen entirely if v1 ships
   no telemetry). Do **not** duplicate Steam's EULA — that surfaces on
   first Steam launch, as on stock SteamOS.
4. **Disk confirmation** — destructive, never defaulted, explicit confirm.
5. **Account** — username + password or PIN. On-screen keyboard per T2's
   text-entry finding.
6. **Encryption** — two options, one-line tradeoff explanation, cursor
   defaults to off (matches stock SteamOS).
7. **Wi-Fi** — ⚠️ **no longer skippable-by-default.** `docs/PROGRESS.md` §2.2
   retired the offline constraint: the install may use the network, and Steam
   needs it regardless (`docs/findings/R1-10.4.md`). This is now a normal, expected
   setup screen, as in SteamOS's own wizard.
   - It needs **text entry with a controller** — the Wi-Fi password. That is
     the hardest input problem in the flow and it happens in the *live ISO*,
     before anything is installed. T2 sizes it.
   - Still allow "skip" for a user on a wired/tethered setup or one who
     genuinely wants a bare install, but tell them plainly that Steam will
     need network before Gaming Mode is usable.
8. **Summary** — recap 1–7, single Install confirm.

### Not prompted, ever

Bootloader (always Limine), filesystem (always btrfs), profile, network
backend (always NetworkManager), swap/zram, hostname, theme. Every prompt
is a chance for the flow to break without a keyboard — minimize
aggressively rather than controller-ifying every archinstall screen.

## Steps

1. Generate the archinstall answer-file from the collected choices; the
   pre-baked defaults above are constants in that generator, not questions.
2. Implement the screens per T2's recommended approach.
3. Deck button glyphs (A/B/X/Y, trackpad, bumpers) so it reads as a Deck
   menu, not a Linux installer with a controller bolted on. **Check
   `docs/PLAN.md` §11 on trademark before shipping Valve-style iconography** —
   original artwork may be required.
4. Every screen needs a defined fallback if the user does nothing, except
   the three that must block (language, disk, account).
5. Test the full flow in QEMU with only virtual gamepad input.

## Done when

- [ ] All screens implemented and reachable with virtual gamepad only
- [ ] A complete install runs start to finish with zero keyboard input
- [ ] Answer-file generator unit-tested with fixtures
- [ ] Blocking screens genuinely block; non-blocking ones have defaults
- [ ] Runs offline with no network available
- [ ] Glyph/trademark question resolved or flagged

## Failure modes to watch for

- **Adding prompts.** Every added screen is added risk. If tempted, ask
  whether it can be a constant instead.
- **Testing with a keyboard attached.** Disable it; test the real path.

## Escalate if

- T2 concluded custom UI is needed for more than 2–3 screens — that's a
  material scope increase worth discussing before building
- The trademark question on button glyphs needs a real decision
