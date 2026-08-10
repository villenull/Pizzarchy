# Omarchy Deck — project constraints

Auto-loaded every session. Kept deliberately short — it costs context on
every request. The work program is `START-HERE.md`; current state is
`PROGRESS.md`; usage budgeting is `SESSIONS.md`.

All files are flat in this directory. **Do not create subdirectories.**
New files: `FINDING-*.md` for research outputs, `TASK-*.md` for new tasks.

## What this is

A Steam Deck–native, controller-only installer ISO for **Omarchy 4.0
(Quattro)** that preserves stock SteamOS Gaming Mode and adds a Desktop Mode
(Omarchy/Hyprland) reachable by button/icon, not just a keybind.

Full spec: `PLAN.md`. **It is frozen and partly superseded** — read the
banner at its top before trusting any section. Current state and every
decision that overrode it: `PROGRESS.md`.

## Hard constraints — don't violate without asking

- **Limine only.** No GRUB, no systemd-boot paths. Deliberate, after real
  breakage with systemd-boot's UKI conventions (`PLAN.md` §6.3).
- **Target Omarchy 4.0, not 3.x.** The test Deck runs 3.8.4, so target and
  test asset disagree — see `PROGRESS.md` §2.3 before doing shell-integration
  work.
- **No keyboard or terminal for a standard install.** Every screen in
  `PLAN.md` §6.1a must be reachable by Deck buttons/trackpads alone. This
  now includes typing a Wi-Fi password.
- **Wi-Fi must work in the live ISO.** The install may use the network
  (`PROGRESS.md` §2.2), which makes the Deck's radio working *from the ISO's
  stock kernel* a load-bearing requirement, and currently unverified
  (`PROGRESS.md` §5.1).
- **Don't depend on anything unlicensed or AUR-only.** The ISO redistributes
  what it carries. This is why `28allday/deckshift` was dropped
  (`PROGRESS.md` §2.4).
- **Never silently swallow a failure.** `set -euo pipefail` or equivalent;
  fail loudly. This project exists partly because upstream tooling fails
  silently (`PLAN.md` §8.1). Don't reintroduce that anywhere.
- **Idempotent, re-runnable scripts.** Required for the SSH iterate-in-place
  loop (`PLAN.md` §9.4) to work at all.
- **OLED is the only verified hardware.** Gate LCD paths on model detection
  (`PLAN.md` §9.6). Don't claim LCD support anywhere — code comments, docs,
  or UI — that hasn't been tested.
- **Don't auto-install an AUR helper.** Caused a real installer failure
  upstream (`yay` vs `yay-bin`, `PLAN.md` §8.4). Let Omarchy own that.

## Testing

Only test on physical hardware what cannot be tested otherwise. Default to:
shellcheck/unit tests (seconds) → automated QEMU install (minutes) →
physical Deck only for kernel boot, gyro/haptics/trackpads, audio DSP,
Wi-Fi/BT, TDP/fan, gamescope, session switching, and RC-only full installs.

Never propose reinstalling on the Deck as a first resort. Ask if unsure.

## Model routing

Default **Sonnet**. Escalate to **Opus** for: boot-chain work (T1, and the
pacman hook in `PLAN.md` §11), hardware control logic (TDP/fan/sysfs),
the gamepad spike (T2), research questions (R1), and release verification
(T6). Haiku for CI YAML, issue/PR text, README edits.

Switch models at task boundaries, then `/clear`. Not mid-task.

## Already diagnosed — don't rediscover

Original hypotheses in `PLAN.md` §8; **confirmed outcomes and ~20 other
hard-won facts in `PROGRESS.md` §7 — read that, not §8.**

1. `linux-neptune.sh` silently no-ops via `curl | bash` (missing
   `common-script.sh`) — fixed in `omarchy-deck-kernel.sh`; use that, not
   upstream's script.
2. No Limine detection upstream — also fixed there.
3. ~~Shipped mkinitcpio preset points at a wrong `/efi/...` UKI path~~ —
   **obsolete.** Valve's kernel packages ship no preset at all; Omarchy
   builds UKIs via `limine-mkinitcpio-hook`. There is no preset to patch.
4. `yay-bin` vs `yay` conflict — avoid by not auto-installing an AUR helper.
5. ESP `fmask=0077,dmask=0077` blocks user-space reads of the Limine config
   — fixed there. Note: `mount -o remount` does **not** re-apply
   `fmask`/`dmask` on vfat; a full `umount`/`mount` cycle is required.
