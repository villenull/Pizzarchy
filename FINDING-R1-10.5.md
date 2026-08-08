# FINDING R1 §10.5 — Secure Boot / BIOS state on Deck

**Result: CONFIRMED (session 3, operator-verified).** Hypothesis holds: no
BIOS change is needed before installing. Resolved by the operator directly
on their own Deck, since this cannot be resolved from inside a worktree or
by any automated tooling.

## Evidence

- **Boot order** — operator entered the Deck's Boot Manager (Vol+ + Power)
  and confirmed Limine is already the selected/default EFI boot entry, with
  the same EFI hard drive listed as fallback. No reordering needed. (Caveat:
  this reflects the state *after* Limine's installer self-registered as the
  default boot entry — normal UEFI installer behavior on virtually any
  system, not evidence about the Deck's true factory state on its own.)
- **Secure Boot — the load-bearing evidence.** The operator's Deck already
  has Omarchy + Neptune + Limine installed from a prior session (the same
  install `PROGRESS.md` flags as the project's most valuable test asset —
  never wipe it). Critically, **the operator never touched Secure Boot at
  any point during that original install** — it was never toggled, and the
  install worked. Because that was the *first-ever* BIOS interaction with
  this Deck, this is direct evidence of the actual factory state, not just
  the current post-install state.
- The operator also opened the full Setup Utility (reachable via the same
  Vol+ + Power boot menu, not just the Boot Manager device-chooser) and
  checked the `Boot` tab (Quick Boot/Quiet Boot/Network Stack: Enabled, PXE
  Boot capability: Auto — nothing concerning) and the `Security` tab, which
  **does not expose any Secure Boot toggle at all** — no line item for it
  under Security on this BIOS. Combined with the above, the most consistent
  read is that Secure Boot enforcement is not a user-facing setting on this
  hardware/BIOS build at all, rather than a hidden toggle the operator
  needs to find and flip — reinforcing, not weakening, "no BIOS change
  needed."

## What this changes

No pre-install documentation step is needed for Secure Boot. The install
flow does not need to instruct users to enter BIOS and disable anything.
Boot order also needs no attention — Limine's own installer handles it.

No photos were retained (operator declined to commit personal device photos
to the repo; deleted locally after review). This finding's text evidence
above is the record.

---

*Original hypothesis and "why this needs the operator" rationale below,
kept for context.*

## Hypothesis (PLAN.md §10.5)

Low risk but needs documenting. Omarchy's own manual requires Secure Boot
off. The Deck ships with Secure Boot effectively disabled, so most users
likely need no BIOS change before installing — but since this can't be
verified or changed from inside an installer, if a BIOS step *is* needed it
must be documented (with photos) **before** first boot, not discovered
mid-install when there's no controller-friendly way to recover from a
Secure-Boot-blocked boot failure.

## Why this needs the operator, not an agent

- BIOS/UEFI setup on the Deck is entered by holding **Volume Up + Power**
  at boot — a physical hardware action with no software equivalent.
- Secure Boot state and boot order live in UEFI NVRAM, not anything
  queryable or settable from within a running OS session in a way that's
  meaningful to verify ahead of time (and this project's hard constraint is
  never to write to or test on the physical Deck as a shortcut).
- There is no emulator/VM equivalent that reproduces the Deck's actual
  factory UEFI/Secure Boot configuration — a QEMU OVMF Secure Boot state
  says nothing about what Valve ships on real hardware.

## Exact questions the operator needs to answer

Enter BIOS (Vol+ + Power at boot) on your own Deck and check:

1. **Secure Boot state** — is it shown as Enabled or Disabled? (Hypothesis:
   disabled/not enforced out of the box, but confirm the actual toggle
   state, not just "it worked last time.")
2. **Boot order** — does it currently list anything that would need
   reordering for a Limine-based install to boot by default (e.g. is the
   internal drive first, or does something else take priority)?
3. **Any other UEFI setting Omarchy's manual specifically calls out** as a
   Secure-Boot-adjacent requirement (worth a quick check against Omarchy's
   install docs at the same time, since the manual's stated requirement is
   what defines "done" here, not just Secure Boot's toggle in isolation).

## Reminder for whoever does this

- **Take photos of the BIOS screens before changing anything**, even if no
  change turns out to be needed — this is the artifact that lets a future
  session (or another user going through the install) confirm the state
  without re-entering BIOS themselves.
- If a BIOS change *is* required, it must be written into the pre-install
  documentation as an explicit step with photos, not left as something a
  user discovers mid-install when the controller-only, no-keyboard install
  flow (CLAUDE.md hard constraint) has no path to fix a Secure-Boot block.
- This is a one-time, low-effort check (a few minutes in BIOS) — flagging it
  as blocked here, not attempting a workaround.
