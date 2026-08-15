# Omarchy Deck — project constraints

Auto-loaded every session. Kept deliberately short — it costs context on
every request. The work program is `docs/START-HERE.md`; current state is
`docs/PROGRESS.md`; usage budgeting is `docs/SESSIONS.md`.

## Layout

```
src/     shipped to the Deck: omarchy-deck-kernel.sh, deck-session.sh,
         deck-input-mapper.py
tools/   dev-machine tooling, never shipped: deck-sync/snapshot/rollback
test/    lib/ (sourced helpers) · unit/ (no VM needed) · vm/ (QEMU suites)
         images/ (substrate builder + the built .raw, gitignored)
docs/    START-HERE · ROADMAP · PROGRESS · SESSIONS · PLAN
         tasks/ · findings/ · drafts/
```

New files go in the matching directory: research outputs in `docs/findings/`,
work specs in `docs/tasks/`. *(The repo was deliberately flat while the plan
was being written; that rule was retired 2026-08-10 once it had outgrown it.)*

## What this is

A Steam Deck–native, controller-only installer ISO for **Omarchy 4.0
(Quattro)** that preserves stock SteamOS Gaming Mode and adds a Desktop Mode
(Omarchy/Hyprland) reachable by button/icon, not just a keybind.

The plan and its ordering: `docs/ROADMAP.md` (four phases, plus a 2.9 wedged
between 2 and 3 — **2.9 is complete**). Current state and
every decision: `docs/PROGRESS.md`. Original spec: `docs/PLAN.md` — **frozen and
partly superseded**; read the banner at its top before trusting any section.

## Hard constraints — don't violate without asking

- **Limine only.** No GRUB, no systemd-boot paths. Deliberate, after real
  breakage with systemd-boot's UKI conventions (`docs/PLAN.md` §6.3).
- **Target Omarchy 4.0, not 3.x.** The test Deck runs
  `omarchy-dev 4.0.0.r1744.gf002044-1` — exactly `iso/RUNTIME`'s pin
  (`basecamp/omarchy@f0020448ca87`; `gf002044` is that commit), so target and
  test asset agree. Read off the device 2026-08-15 after it was **reinstalled
  from our own stable ISO** (session 28). Previously this line said
  `r1617.g6d7826d-1` / version file `4.0.0.alpha`, read 2026-08-12 — true of the
  *old* install, stale the moment the Deck was rebuilt. A "the Deck runs 3.8.4"
  claim also lived here for sessions after `docs/PROGRESS.md` had corrected it;
  don't reintroduce either.
- **No keyboard or terminal for a standard install.** Every screen in
  `docs/PLAN.md` §6.1a must be reachable by Deck buttons/trackpads alone. This
  now includes typing a Wi-Fi password.
- **Wi-Fi must work in the live ISO.** The install may use the network
  (`docs/PROGRESS.md` §2.2), which makes the Deck's radio working *from the ISO's
  stock kernel* a load-bearing requirement, and currently unverified
  (`docs/PROGRESS.md` §5.1).
- **Don't depend on anything unlicensed or AUR-only.** The ISO redistributes
  what it carries. This is why `28allday/deckshift` was dropped
  (`docs/PROGRESS.md` §2.4).
- **Never silently swallow a failure.** `set -euo pipefail` or equivalent;
  fail loudly. This project exists partly because upstream tooling fails
  silently (`docs/PLAN.md` §8.1). Don't reintroduce that anywhere.
- **Idempotent, re-runnable scripts.** Required for the SSH iterate-in-place
  loop (`docs/PLAN.md` §9.4) to work at all.
- **OLED is the only verified hardware.** Gate LCD paths on model detection
  (`docs/PLAN.md` §9.6). Don't claim LCD support anywhere — code comments, docs,
  or UI — that hasn't been tested.
- **Don't auto-install an AUR helper.** Caused a real installer failure
  upstream (`yay` vs `yay-bin`, `docs/PLAN.md` §8.4). Let Omarchy own that.

## Testing

Only test on physical hardware what cannot be tested otherwise. Default to:
shellcheck/unit tests (seconds) → automated QEMU install (minutes) →
physical Deck only for kernel boot, gyro/haptics/trackpads, audio DSP,
Wi-Fi/BT, TDP/fan, gamescope, session switching, and RC-only full installs.

Never propose reinstalling on the Deck as a first resort for *iteration* —
there is almost always a faster tier. The planned rebuild and factory reset
in `docs/ROADMAP.md` (P1.5, P3.1) are the deliberate exceptions, approved in
principle 2026-08-10; still confirm with the operator before executing
either. Ask if unsure.

## Model routing

Default **Sonnet**. Escalate to **Opus** for: boot-chain work (T1, and the
pacman hook in `docs/PLAN.md` §11), hardware control logic (TDP/fan/sysfs),
the gamepad spike (T2), research questions (R1), and release verification
(T6). Haiku for CI YAML, issue/PR text, README edits.

Switch models at task boundaries, then `/clear`. Not mid-task.

## Already diagnosed — don't rediscover

Original hypotheses in `docs/PLAN.md` §8; **confirmed outcomes and 55 other
hard-won facts in `docs/PROGRESS.md` §7 — read that, not §8.** Several were
corrected by later measurement, so trust §7 over memory and re-check before
building on any recorded value.

1. `linux-neptune.sh` silently no-ops via `curl | bash` (missing
   `common-script.sh`) — fixed in `src/omarchy-deck-kernel.sh`; use that, not
   upstream's script.
2. No Limine detection upstream — also fixed there.
3. ~~Shipped mkinitcpio preset points at a wrong `/efi/...` UKI path~~ —
   **obsolete.** Valve's kernel packages ship no preset at all; Omarchy
   builds UKIs via `limine-mkinitcpio-hook`. There is no preset to patch.
4. `yay-bin` vs `yay` conflict — avoid by not auto-installing an AUR helper.
5. ESP `fmask=0077,dmask=0077` blocks user-space reads of the Limine config
   — fixed there. Note: `mount -o remount` does **not** re-apply
   `fmask`/`dmask` on vfat; a full `umount`/`mount` cycle is required.
