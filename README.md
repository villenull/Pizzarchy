# Omarchy Deck — planning and handoff package

Everything needed to build a Steam Deck–native Omarchy Quattro installer.
**All files are flat in one directory. No subfolders needed.**

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
| `SESSIONS.md` | Usage-limit budgeting and a 20-block schedule for Max 5x. |
| `PLAN.md` | Full plan: architecture, diagnosed bugs, test strategy, timeline. |
| `PROGRESS.md` | Living state. Updated continuously by each session. |
| `TASK-*.md` | Eight work specs: objective, steps, done-criteria, escalation. |
| `omarchy-deck-kernel.sh` | Draft kernel/boot automation encoding five real bug fixes. **Never executed — review before trusting.** |

## Where this came from

A full manual Omarchy install on an OLED Steam Deck, including roughly a
dozen distinct failures: a silently no-op'ing upstream script, a bootloader
with no Neptune entry, a mkinitcpio preset pointing at a nonexistent ESP
path, an AUR helper conflict, ESP permissions blocking Omarchy's own
installer, and a keyboard layout mismatch that corrupted typed commands.
Each is diagnosed in `PLAN.md` §8 with a root-cause hypothesis, so the build
doesn't rediscover them.

## Order

1. `T0` — test infrastructure (collapses a ~30 min loop to seconds)
2. `R1` + `T1` in parallel — research and the boot chain
3. `T2` — the gamepad spike that sizes `T4`
4. `T3`, `T4`, `T5`
5. `T6` — after Omarchy Quattro goes stable

See `SESSIONS.md` for how this maps onto 5-hour usage windows.
