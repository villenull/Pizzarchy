# Omarchy Deck — project constraints

Auto-loaded every session. Kept deliberately short — it costs context on
every request. The work program is `START-HERE.md`; current state is
`PROGRESS.md`; usage budgeting is `SESSIONS.md`.

All files are flat in this directory. **Do not create subdirectories.**
New files: `FINDING-*.md` for research outputs, `TASK-*.md` for new tasks.

## What this is

A Steam Deck–native, fully offline, controller-only installer for Omarchy
Quattro that preserves stock SteamOS Gaming Mode and adds a Desktop Mode
(Omarchy/Hyprland) reachable by button/icon, not just a keybind.

Full spec: `PLAN.md`. **Read it whole only once**, in the first session —
it's the largest file here and re-reading it burns budget. After that, read
only the sections task files cite.

## Hard constraints — don't violate without asking

- **Limine only.** No GRUB, no systemd-boot paths. Deliberate, after real
  breakage with systemd-boot's UKI conventions (`PLAN.md` §6.3).
- **Fully offline install through first boot into Gaming Mode.** The
  installer, first boot, and reaching the Gaming Mode session all require no
  network — confirmed true end-to-end (`PROGRESS.md` Findings, T0 §1). Steam
  itself then needs network to sign in on first launch, exactly like a
  factory-reset Deck — confirmed unavoidable under any packaging strategy
  (`R1` §10.4, `FINDING-R1-10.4.md`), not a gap to engineer around. Framing:
  "installs completely offline; Steam signs in on first launch." The install
  flow must make this obvious before it happens (a controller-navigable
  Wi-Fi screen shown before Steam ever gets the display on first boot without
  a client — required T5 item, see `PLAN.md` §6.1a item 7 and §10.4). If
  something else seems to need network at install time, flag it.
- **No keyboard or terminal for a standard install.** Every screen in
  `PLAN.md` §6.1a must be reachable by Deck buttons/trackpads alone.
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

Full hypotheses in `PLAN.md` §8:
1. `linux-neptune.sh` silently no-ops via `curl | bash` (missing
   `common-script.sh`) — fixed in `omarchy-deck-kernel.sh`; use that, not
   upstream's script.
2. No Limine detection upstream — also fixed there.
3. Shipped mkinitcpio preset points at a wrong, commented-out `/efi/...`
   UKI path regardless of the real ESP — also fixed there.
4. `yay-bin` vs `yay` conflict — avoid by not auto-installing an AUR helper.
5. ESP `fmask=0077,dmask=0077` blocks user-space reads of the Limine config
   — fixed there. Note: `mount -o remount` does **not** re-apply
   `fmask`/`dmask` on vfat; a full `umount`/`mount` cycle is required.
