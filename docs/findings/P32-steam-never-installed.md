# P3.2 — Steam is never installed: `deck-fetch.packages` has no consumer (P1)

> **Found 2026-08-15 (session 28) on the first hardware first-boot ever produced
> by this project**, from `omarchy-2026.08.15-x86_64-quattro.iso` (sha256
> `e9fbd8ed…68c5`) on the OLED Deck. Symptom was a black screen after install.
> Root-caused over SSH from the live ISO, repaired in place, and **confirmed
> fixed on hardware** — Steam came up and Gaming Mode rendered.

## One-line statement

`steam` and `steamdeck-dsp` live in `iso/overlay/configs/deck/deck-fetch.packages`,
and **nothing in the repo ever reads that list to install anything**. The
installed system therefore has no Steam; gamescope starts, finds nothing to
display, and the panel stays black.

## The symptom, and why it read as a boot failure

After a successful install the Deck showed nothing on any VT, survived a hard
power cycle unchanged, and gave no console text. Trackpad haptics still worked.

Two things made this look far worse than it was:

1. **Haptics prove nothing.** The Deck powers on in `lizard_mode`, where the
   controller *firmware* emulates a mouse and generates trackpad haptics with no
   kernel involvement at all. "It rumbles, so it's alive" is not a valid
   inference — it is alive in the same sense a powered-off laptop's charging LED
   is. (This misled the first hour of diagnosis.)
2. **The cmdline silences the console completely.** Limine passes
   `quiet splash loglevel=0 systemd.show_status=false rd.udev.log_level=0
   vt.global_cursor_default=0`. A perfectly healthy boot is therefore visually
   identical to a dead one — black, no messages, not even a cursor. "Black on
   every VT" was read as "never reached userspace"; it was not.

What actually settled it: the installed system's own journal showed **two
complete boots** (17:26:21→17:28:51 and 17:29:51→17:33:03), i.e. the kernel ran
for minutes each time.

## Root cause

The journal's error tail:

```
tar: /usr/lib/steam/bootstraplinux_ubuntu12_32.tar.xz: Cannot open: No such file or directory
steam-short-session-tracker: Steam failed to start 3 times within 60 seconds
steam-launcher.service: Failed with result 'start-limit-hit'
```

`/usr/lib/steam/` did not exist, and the target's pacman DB carried no `steam`.
Present and correct: `gamescope 3.16.25-3` (Valve's), `mesa`, `vulkan-radeon`,
`omarchy-deck 0.2.0-1`, `linux 7.1.8.arch1-3`, the `linux-firmware-*` set.

**Why it is absent.** `docs/tasks/T5-fork-plan.md` §4.1 decided `steamdeck-dsp`
and `steam` would be *fetched at install time, not bundled* — the installer's
own S0 disclosure says so on screen ("Steam and the audio DSP firmware are
downloaded from Valve during setup"). They were therefore put in a third list,
`deck-fetch.packages`, deliberately kept out of both `deck-install.packages`
(pacstrapped onto the target) and `deck-mirror.packages` (carried in the offline
mirror).

The fetch step itself was **never implemented**. Grepping the whole repo, the
only consumer of `deck-fetch.packages` is `deck-nvidia-dry-run.sh`, which reads
it to *check* it (so the NVIDIA question is asked about the right package set).
No code installs from it. The list is, functionally, a comment.

⚠️ **`deck-mirror.packages` has the same shape of problem.** Its own header says
"carried in the offline mirror, **installed later**" — and nothing installs it
later either. That is why the installed system runs stock `linux 7.1.8-arch1-3`
rather than `linux-neptune-611`, and has no `linux-firmware-neptune` and no
`steamdeck-dsp`. Confirmed against the target's pacman DB. **This is a separate
open gap**, not fixed by this finding.

## The measurement failure — the part that matters most

The install's own record (`@log/omarchy-deck-install.json`) reports **eleven
steps, all green**:

```
autologin  status='gaming'      desktop_rotation configured   idle_policy configured
limine_rotation configured      lock_wake_dpms   configured   mask_sleep_lock configured
menu_lock_row  overridden       patches applied              session_dconf configured
tty_rotation   configured       wifi     status='connected'
```

Every one passed on a machine that could not reach Gaming Mode. The QEMU install
test scored **18/18** on the same basis. Nothing in either tier asks *"is Steam
installed?"* — they verify the steps we wrote, never the outcome those steps
exist to produce.

This is the second instance of that exact failure mode found on the same day;
the first is `docs/findings/P32-osk-mapper-missing-from-live-iso.md`. Both were
invisible to every automated tier and both surfaced within minutes of real
hardware.

## What was PROVEN GOOD by this boot (first hardware evidence)

Worth recording, because it is all first-time-on-hardware confirmation:

- The **UKI is built** at install: `/EFI/Linux/omarchy_linux.efi`, 74,987,520 B.
  `limine-mkinitcpio-hook` fires correctly.
- **Limine works**, renders its menu on the panel, and `interface_rotation: 90`
  is right (the config's own measured note holds).
- **`fbcon=rotate:1`** is present on the real cmdline.
- **Autologin lands on `gaming`** — `session: gamescope-wayland`,
  `session_desktop: /usr/share/wayland-sessions/gamescope-wayland.desktop`,
  user `deck`, uid 1000. The `deck_autologin.py` fix and the gamescope
  session-file fix (§14.6) both hold on hardware.
- **gamescope 3.16.25-3 starts and runs.**
- **The Wi-Fi profile carried** from the installer: `wifi status='connected'`,
  and the installed system joined the LAN on its own at first boot.
- **Live-ISO Wi-Fi works on the stable build** (association, DHCP, routing,
  internet) — the `CLAUDE.md` load-bearing requirement, re-confirmed.

## Repair applied on the device (operator-approved, minimal option)

From the live ISO, over SSH, with the target mounted:

```bash
mount /dev/nvme0n1p1 /mnt3/boot
arch-chroot /mnt3 pacman -Sy
arch-chroot /mnt3 pacman -S --noconfirm --needed steam     # 34 pkgs, steam 1.0.0.87-1
```

34 packages, all `lib32` runtime deps plus `steam`. No kernel, bootloader or UKI
involvement. **Result: Steam bootstrapped on the next boot and Gaming Mode
rendered.** Diagnosis confirmed by repair.

Deliberately NOT done (operator chose the minimal repair): Valve repos were not
added to the target, so `steamdeck-dsp` (audio DSP firmware) and
`linux-neptune` are still absent. Any audio oddity in the rest of the P3.2 pass
is expected, not a new bug.

Left in place: ~40 zero-byte `dot-steam.bak.<epoch>` dirs in `/home/deck`,
created by `steam-short-session-tracker`'s retry loop. Harmless; a recursive
delete in a user's home was not worth the risk.

## The fix (deferred — needs design, then a rebuild)

1. **Implement the fetch step.** Something in `configure_deck` must install
   `deck-fetch.packages` onto the target, online, at install time — and must
   fail loudly if it cannot (`CLAUDE.md`: never silently swallow a failure). Note
   the install is already allowed to require the network (`docs/PROGRESS.md`
   §2.2), which is what made "fetch, don't bundle" legitimate in the first place.
2. **Decide `deck-mirror.packages`'s fate too** — same "installed later" gap,
   affecting the Neptune kernel and `linux-firmware-neptune`. These are *in* the
   offline mirror, so they need installing from it, not fetching.
3. **A guard that a list with no consumer is an error.** The general defect is
   that a package list can exist, be maintained, be unit-tested, and install
   nothing. Every deck `*.packages` file should have to name its consumer.
4. **An outcome assertion, not a step assertion.** The install harness must
   check the *target* for the things Gaming Mode needs — at minimum that `steam`
   is installed and `/usr/lib/steam/bootstraplinux_ubuntu12_32.tar.xz` exists.
   Eleven green steps and 18/18 in QEMU did not catch a machine with no Steam.

## Evidence

Both boot journals, the install record and the timing record are saved at
`~/.cache/omarchy-deck/p32-firstboot/` (`boot0.txt`, `boot-1.txt`,
`install.json`) on the dev machine — **not in git** (they contain a hostname and
network details).

## Status

- [x] Root-caused on hardware
- [x] Repaired in place; **repair confirmed working — Steam runs, Gaming Mode renders**
- [x] Positive hardware confirmations recorded
- [ ] **P1 fix in the ISO** — implement the fetch step, resolve the mirror-list
      gap, guard consumer-less lists, add outcome assertions. Needs a rebuild.
