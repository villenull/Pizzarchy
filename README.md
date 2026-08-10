# Omarchy Deck — planning and build repo

A Steam Deck–native installer ISO for **Omarchy 4.0 (Quattro)**: one bootable
USB that installs a fully hardware-optimized Arch + Omarchy system, navigable
with only the Deck's buttons and trackpads. After install the device behaves
like stock SteamOS — boots to Gaming Mode, all hardware works — except
"Desktop Mode" drops into a full Omarchy desktop, with a button to return.

**Status: in development. Nothing is releasable yet.** OLED hardware only;
LCD is untested and not claimed.

**All files are flat in one directory. No subfolders.**

## For Claude Code

Point it at `START-HERE.md`. Your entire opening prompt:

```
Read START-HERE.md and begin.
```

## Files

| File | What it is |
|---|---|
| `START-HERE.md` | **Entry point.** Work queue, autonomy rules, model routing. |
| `CLAUDE.md` | Hard constraints. Auto-loaded every session. |
| `PROGRESS.md` | **Authoritative state.** Scope decisions, findings, open issues, and the facts not to re-derive. |
| `SESSIONS.md` | Usage-limit budgeting and the block schedule. |
| `PLAN.md` | The original plan. **Frozen and partly superseded** — read its banner first. |
| `TASK-*.md` | Eight work specs: objective, steps, done-criteria, escalation. |
| `FINDING-*.md` | Research outputs — the evidence behind each decision. |
| `DRAFT-*.md` | Staged upstream reports and outreach. Nothing sent. |
| `omarchy-deck-kernel.sh` | Kernel/boot automation. Nine idempotent stages, shellcheck-clean, VM-tested and **validated on physical hardware**. |
| `deck-session.sh` | Gaming Mode ↔ Desktop Mode session switching. |
| `vm-*.sh`, `test-vm-*.sh` | QEMU test harness and unit suites. |
| `deck-sync.sh`, `deck-snapshot.sh`, `deck-rollback.sh` | SSH iterate-in-place loop for the physical Deck. |

## Where this came from

A full manual Omarchy install on an OLED Steam Deck, including roughly a
dozen distinct failures: a silently no-op'ing upstream script, a bootloader
with no Neptune entry, a mkinitcpio preset pointing at a nonexistent ESP
path, an AUR helper conflict, ESP permissions blocking Omarchy's own
installer, and a keyboard layout mismatch that corrupted typed commands.
Each is diagnosed in `PLAN.md` §8 with a root-cause hypothesis, so the build
doesn't rediscover them.

## Prior art

`28allday/deckshift`, `omarchy-deck-iso` and `omasteam` are the closest
neighbours, and **none of them target Steam Deck hardware** — they run
Deck-*style* gaming mode on generic PCs. Bazzite and ChimeraOS solve Deck
hardware but not Omarchy. See `PROGRESS.md` §3.7.

## Recovery

This is a wipe-and-replace install. **Returning to stock SteamOS via Valve's
official recovery image will be documented before any release** — see
`PROGRESS.md` §5.8.
