# Progress

> Claude Code: keep this current as you work, not just at session end.
> This is the first thing the next session reads.

## Status summary

Project not yet started. This folder contains planning artifacts only:
a full plan (`PLAN.md`), hard constraints (`CLAUDE.md`), eight task
specifications (`TASK-*.md`), and one draft implementation script
(`omarchy-deck-kernel.sh`, never executed).

Next action: read `START-HERE.md`, then `SESSIONS.md`, then begin block 1 (T0 §1).

## Task status

| Task | Status | Notes |
|---|---|---|
| T0 Test infrastructure | not started | Do first — collapses the edit-test loop |
| R1 Research questions | not started | Can run parallel; 10.4 is highest stakes |
| T1 Kernel and boot | not started | Opus. Draft script exists, unexecuted |
| T2 Gamepad input spike | not started | Opus. Determines T4's entire scope |
| T3 Gaming Mode | not started | Needs T0's deck-sync.sh to be efficient |
| T4 Installer UI | not started | Blocked on T2's finding |
| T5 ISO and payload | not started | Blocked on R1 10.1 and 10.4 |
| T6 Integration and release | not started | Blocked on Quattro stable |

## Findings

Nothing confirmed yet. `PLAN.md` §8 and §10 contain **hypotheses**, not
findings — as each is confirmed or killed, record it here with evidence.

Carried over from the operator's manual install session (already validated
on real hardware, treat as fact):

- Neptune kernel installs and boots on OLED Deck via jupiter-staging /
  holo-staging repos
- Limine + UKI works; the neptune kernel needs a manually added boot entry
- `mount -o remount` does NOT re-apply fmask/dmask on vfat
- Omarchy's installer aborts on a `yay` / `yay-bin` conflict
- Omarchy's `limine-snapper.sh` fails when `/boot` is mounted 0077
- `cs35l41-dsp1-*` firmware warnings appear on OLED; audio impact unverified

## Blocked on human

- Ventoy setup on the test USB (T0 step 2)
- Any write to the physical Deck
- Any public action (repos, upstream issues, outreach)
- **Scope decision: v0 vs v1 first** (see `PLAN.md` §3.1). Recommended is
  v0 = T0+T1+T3 as a post-install script, ISO deferred to v1.
- **Do not wipe the operator's existing Deck install.** It is a working
  Omarchy + Neptune + Limine system and is the single most valuable test
  asset in the project — it's the known-good baseline for T3's
  iterate-in-place loop. Snapshot it before any destructive test.

## Open questions

See `PLAN.md` §10 — six documented questions with hypotheses, worked in R1.

## Next session should start with

Read `START-HERE.md` in full, then `SESSIONS.md`, then `PLAN.md` (the one
time you should read it whole). Begin block 1: `TASK-T0-test-infrastructure.md` §1.
