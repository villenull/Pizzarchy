# Progress

> Claude Code: keep this current as you work, not just at session end.
> This is the first thing the next session reads.

## Status summary

Bootstrapped. `PLAN.md` and `SESSIONS.md` read in full (session 1). Git
repo initialized, planning docs committed as baseline (`3c44891`). Local
toolchain checked (see below). Working block 1: T0 §1 (QEMU install
harness).

### Local toolchain check (2026-08-07)

| Tool | Status |
|---|---|
| `qemu-system-x86_64` | present, 11.0.2 |
| `edk2-ovmf` (UEFI firmware for QEMU) | present, 202605-1 |
| `git` | present, 2.55.0 |
| `archiso` (`mkarchiso`) | **missing** |
| `shellcheck` | **missing** |
| `ventoy-bin` | **missing** |

`archiso` and `shellcheck` are needed for T0 §1/§6; `ventoy-bin` is needed
for the human-executed USB setup (T0 §2, already slated for
"Blocked on human"). Not installed per `CLAUDE.md` — added to "Blocked on
human" below instead.

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
- Missing local packages needed for full T0 work: `archiso` (mkarchiso,
  for ISO builds later) and `shellcheck` (static analysis, T0 §5–6).
  Not installed automatically per `CLAUDE.md` — install with
  `sudo pacman -S archiso shellcheck`, plus `ventoy-bin` from the AUR for
  the USB workflow, when convenient.
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
