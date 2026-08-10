# Omarchy Deck — planning and build repo

A Steam Deck–native installer ISO for **Omarchy 4.0 (Quattro)**: one bootable
USB that installs a fully hardware-optimized Arch + Omarchy system, navigable
with only the Deck's buttons and trackpads. After install the device behaves
like stock SteamOS — boots to Gaming Mode, all hardware works — except
"Desktop Mode" drops into a full Omarchy desktop, with a button to return.

**Status: in development. Nothing is releasable yet.** OLED hardware only;
LCD is untested and not claimed.

## Layout

| Path | What lives there |
|---|---|
| `src/` | Shipped to the Deck — the kernel/boot automation, the session layer, the input mapper |
| `tools/` | Dev-machine tooling, never shipped — the SSH iterate-in-place loop |
| `test/lib/` | Sourced helpers (disk-image reading, assertions, cidata, script-override) |
| `test/unit/` | Fast suites needing no VM — run in CI on every push |
| `test/vm/` | QEMU suites: install harness, kernel/hook/idempotency/stage, default-entry, gamepad spike |
| `test/images/` | The substrate builder, and the built `.raw` (gitignored — reproducible) |
| `docs/` | `START-HERE`, `ROADMAP`, `PROGRESS`, `SESSIONS`, `PLAN` |
| `docs/tasks/` | Eight work specs: objective, steps, done-criteria, escalation |
| `docs/findings/` | Research outputs — the evidence behind each decision |
| `docs/drafts/` | Staged upstream report. Nothing sent. |

## For Claude Code

Your entire opening prompt:

```
Read docs/START-HERE.md and begin.
```

`docs/ROADMAP.md` has the three-phase plan; `docs/PROGRESS.md` is
authoritative for current state.

## Where this came from

A full manual Omarchy install on an OLED Steam Deck, including roughly a
dozen distinct failures: a silently no-op'ing upstream script, a bootloader
with no Neptune entry, a mkinitcpio preset pointing at a nonexistent ESP
path, an AUR helper conflict, ESP permissions blocking Omarchy's own
installer, and a keyboard layout mismatch that corrupted typed commands.
Each is diagnosed in `docs/PLAN.md` §8 with a root-cause hypothesis, so the build
doesn't rediscover them.

## Prior art

`28allday/deckshift`, `omarchy-deck-iso` and `omasteam` are the closest
neighbours, and **none of them target Steam Deck hardware** — they run
Deck-*style* gaming mode on generic PCs. Bazzite and ChimeraOS solve Deck
hardware but not Omarchy. See `docs/PROGRESS.md` §3.7.

## Recovery

This is a wipe-and-replace install. **Returning to stock SteamOS via Valve's
official recovery image will be documented before any release** — see
`docs/PROGRESS.md` §5.8.
