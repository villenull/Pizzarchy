# Finding: Ventoy workflow for the physical test USB

**Status: human-executed setup step. Not attempted by Claude Code — this
is a write to physical media the operator owns, and per `CLAUDE.md`/
`START-HERE.md` that's the operator's call. Listed under "Blocked on
human" in `PROGRESS.md`.**

## Why

The naive test loop is `dd`/Etcher-flash a USB (~20 min with verify) →
boot the Deck → find a bug → repeat. `PLAN.md` §9.3 identifies Ventoy as
the single highest-leverage fix: install it once, and every subsequent
"flash" becomes copying an `.iso` file onto a normal exposed data
partition — no `dd`, no verify pass, no re-partitioning.

## One-time setup

1. Pick a USB drive (8GB+; the offline package mirror alone will likely
   be several GB once T5 lands — see `PLAN.md` §6.2).
2. Download the Ventoy release for Linux from ventoy.net (or install
   `ventoy-bin` from the AUR — currently missing locally, see
   `PROGRESS.md`'s toolchain table).
3. **This step is destructive to the USB drive — confirm the device node
   carefully before running it.**
   ```
   sudo ./Ventoy2Disk.sh -i /dev/sdX
   ```
   `-i` does a fresh install (partitions the drive: a small Ventoy boot
   partition + one large exFAT/NTFS data partition). Use `-u` instead for
   a version update that preserves the data partition's contents.
4. The drive now boots via Ventoy's own menu and exposes its data
   partition as a normal filesystem when mounted on any machine.

## Day-to-day loop

- Copy a built `.iso` onto the data partition: `cp omarchy-deck-*.iso
  /run/media/.../ventoy/`. ~2–4 min for a 4–8GB image over USB 3.0,
  versus a full flash-plus-verify.
- **Keep multiple ISO builds side by side** on the data partition —
  Ventoy's boot menu lists every `.iso` it finds. This is the cheap way
  to bisect a regression: boot yesterday's build, then today's, without
  re-flashing between them.
- Boot the Deck from the USB (hold Volume Down + Power at boot to reach
  the boot device picker), pick the ISO from Ventoy's menu.

## Interaction with the script-override mechanism (T0 §3)

Once the override loader (`vm-script-loader.sh` in this repo) lands in
the ISO, the same Ventoy data partition doubles as the override channel:
drop an `omarchy-deck/` directory containing edited scripts next to the
ISO files, and the booted ISO prefers those over its own baked-in copies.
That turns *most* iteration (script changes, not base-image changes) into
a few-KB copy instead of a multi-GB one — see `vm-script-loader.sh` for
the loader logic and its own tests for the precedence rules.

## Not yet verified

This finding is written from `PLAN.md` §9.3's reasoning and Ventoy's
documented behavior — it has not been executed against the operator's
actual test USB (no physical media access from this environment, and
`ventoy-bin` isn't installed locally either). Flag any deviation from
this doc once it's actually run once.
