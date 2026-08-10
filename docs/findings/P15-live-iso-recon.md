# P1.5 recon findings — captured live, 2026-08-10

## R-0. §5.1 WI-FI IN THE LIVE ISO — **CONFIRMED WORKING** ✅

**The top open issue in the project, closed.** On the OLED Deck, booting the
Omarchy 4.0 beta ISO (`omarchy-2026.08.10-x86_64-quattro.iso`):

1. `ip -br link` → **`wlan0` present** (state DOWN, i.e. pre-association).
   This is the load-bearing half: the interface existing proves the
   `ath11k` driver bound to the radio and created a netdev. The feared
   failure — firmware blobs present but no driver binding / wrong PCI ID —
   did **not** happen. *(The chip is QCA2066, not the QCNFA765 §5.1
   assumed — see R-6. The outcome holds; the reasoning behind it does not.)*
2. `systemctl start iwd` → `iwctl station wlan0 scan` / `get-networks` →
   target SSID visible.
3. `iwctl station wlan0 connect` → associated, and DHCP issued
   **192.168.100.25**.

So the live environment drives the OLED Deck's radio end to end: driver
binds, scan works, WPA association works, DHCP works.

**Consequences:**

- `docs/PROGRESS.md` §2.2's network-during-install decision is safe. The
  install may use Wi-Fi, as designed.
- **T5 does not need to bake extra firmware into the live image.** The
  `ROADMAP.md` standing risk "live ISO can't drive the OLED radio" and its
  mitigation (firmware into the live image, partially reopening the
  offline-mirror question) are both **retired**.
- The pre-Steam Wi-Fi installer screen is a normal screen, not a recovery
  mechanism — confirming the §2.2 reasoning.

**Caveat worth keeping:** this was association driven from a shell with a
keyboard. It does **not** yet prove a controller-only user can join Wi-Fi —
that needs T4's OSK over this same stack. The radio question is closed; the
input question is not.

## R-1. Display rotation — CONFIRMED ROTATED (bootloader stage)

**Observed:** Ventoy's own menu renders rotated. Held in normal landscape
orientation, the image **would need a 90° clockwise rotation to read
correctly** — i.e. the content is currently 90° counter-clockwise from
upright.

**Critically: this is at the *bootloader* stage, before the ISO's kernel
boots.** Ventoy's menu is GRUB-based, drawing to the EFI framebuffer with no
Deck-specific quirk handling. So the rotation is the panel's native
portrait mounting showing through, not something the Omarchy live
environment introduces.

### R-1a. The live environment renders CORRECTLY — the split is real

**Observed immediately after:** once the ISO's kernel boots, the Omarchy
installer screen ("press return to install") is **correctly oriented**.

So the two stages genuinely disagree:

| Stage | Orientation |
|---|---|
| Ventoy / GRUB (EFI framebuffer, pre-kernel) | **rotated** 90° CCW from upright |
| Omarchy live environment (post-kernel, DRM) | **correct** |

**Why:** the Linux DRM subsystem carries panel-orientation quirks for Valve's
Deck hardware (`drm_panel_orientation_quirks`), so once the kernel is driving
the panel it compensates automatically. The bootloader has no such knowledge
and draws to the raw framebuffer as-is.

**Consequences — this is materially better news than the ROADMAP assumed:**

- **T4's installer UI needs no rotation handling.** Anything running after
  the kernel — the installer, the mapper-drawn OSK, gamescope — inherits the
  corrected orientation for free. The `ROADMAP.md` standing risk "live ISO
  renders rotated / unusable" is **retired for the installer**.
- **T5 still has a real, narrower problem: the bootloader menu.** Our
  shipped ISO's Limine menu will render rotated exactly as Ventoy's did.
  That is a cosmetic-but-visible flaw on a controller-only product where the
  boot menu may be the first thing a user sees.
  - `fbcon=rotate:1` does **not** help here — it applies to the kernel's
    framebuffer console, which is downstream of the bootloader.
  - Limine's own config is where this must be solved, if at all. Worth
    checking whether Limine has a rotation/resolution option, and whether
    simply timing the menu out fast enough makes it a non-issue.
- No `video=eDP-1:panel_orientation=` cmdline flag is needed — the kernel
  quirk already covers it. **Do not add one**; it would double-correct.

## R-2. Boot media — works

Boot picker (Vol− + Power) lists the Ventoy stick; Ventoy's menu loads and
offers the ISO. Ventoy 1.1.17 on exFAT + a 6.4 GB ISO is a working
combination on Deck firmware.

## R-3. Input enumeration — the Deck presents FOUR devices, two of them free input

Captured from the live ISO (`/proc/bus/input/devices`, saved at
`recon/input-devices.txt`). All four share Vendor=28de Product=1205 (Valve),
on `usb-0000:04:00.4-3`:

| Device | Node | EV bits | What it is |
|---|---|---|---|
| `Valve Software Steam Controller` | `event4` + `mouse1` | `EV=17` (SYN/KEY/REL/MSC), `REL=1943`, `KEY=30000` | **Trackpads emulating a MOUSE** |
| `Valve Software Steam Controller` | `event5` + `kbd` | `EV=100013`, `KEY=e080ffdf01cfffff fffffffffffffffe` | **Buttons emulating a full KEYBOARD** |
| `Steam Deck` | `event11` + `js0` | `EV=20000b` (SYN/KEY/ABS/**FF**), `ABS=3f001b`, `FF=107030000` | The real gamepad — buttons, axes, **force feedback** |
| `Steam Deck Motion Sensors` | `event12` + `js1` | `EV=19`, `ABS=3f`, `PROP=40` (ACCELEROMETER) | IMU — 6 axes (accel + gyro) |

Plus, not part of the controller:

- `FTS3528:00 2808:1015` → `event13` + `mouse2`, `EV=1b` — **the touchscreen**
  (FocalTech), which also emulates a mouse.
- `AT Translated Set 2 keyboard` → `event3` — the Deck's internal button
  block (power/volume), not a real keyboard.

### R-3a. **Lizard mode is active in the live ISO — this changes T4**

The first two rows above are the Steam Controller firmware's *lizard mode*:
its fallback behavior when Steam is not running. Consequence, verified by
enumeration rather than inference:

> **In the live ISO, with no software of ours running at all, the trackpads
> already drive a mouse cursor and the face/dpad buttons already send
> keystrokes.**

**Why this matters, in both directions:**

- **Opportunity:** a graphical installer is *already* navigable out of the
  box — trackpad as mouse, buttons as keys. T4's "8 installer screens" may
  not need a custom input layer merely to be *operable*. This is a floor
  that did not previously exist in the plan.
- ~~**Hazard:** if lizard mode *also* emits keystrokes from the same physical
  button that `src/deck-input-mapper.py` maps, every press fires twice.~~
  **DISPROVEN — see R-8.** This was the hypothesis going in; measurement
  showed lizard mode is *exclusive*, not additive. The gamepad node is
  silent while it is active, so there is no double-input. The real problem
  turned out to be the opposite and worse: the mapper's input node is dead.

**The mapper must still reckon with lizard mode explicitly**, but for the
reason in R-8, not this one. **Read R-8 before doing any T4 work.**

### R-3b. Haptics are reachable

`event11` advertises `EV_FF` with `FF=107030000` — force feedback is
exposed on the gamepad node, so rumble is drivable from userspace without
Steam. Relevant to the P2.2 hardware-parity row.

## R-4. Rotation, mechanism confirmed

`/sys/class/graphics/fbcon/rotate` = **1** (90° clockwise), and the kernel
cmdline is:

```
BOOT_IMAGE=/arch/boot/x86_64/vmlinuz-linux-t2 archisobasedir=arch
archisosearchuuid=... quiet splash xe.enable_panel_replay=0 initramfs_async=0
```

**There is no rotation flag on that cmdline.** The kernel set `rotate=1` on
its own, from its built-in panel-orientation quirk for this hardware. This
is direct evidence for R-1a's conclusion: **T5 must not add
`fbcon=rotate:` or `video=eDP-1:panel_orientation=` — doing so would
double-correct an already-correct display.**

## R-5. Hardware model — OLED confirmed

`sys_vendor=Valve`, `product_name=Galileo`, `board_name=Galileo`,
`product_family=Sephiroth`, `bios_version=F7G0114`. Galileo is the OLED
model, so this session's results are OLED-valid and say nothing about LCD —
consistent with the project's standing OLED-only posture.

*(Note: `amdgpu` logs `ATOM BIOS: 113-AMDSphJupiter-002`. That string says
"Jupiter" but is a shared display-controller BIOS name, **not** a model
indicator. Do not read it as LCD.)*

## R-6. Wi-Fi chip is QCA2066, **not** QCNFA765 — corrects §5.1's reasoning

`docs/PROGRESS.md` §5.1 concluded Wi-Fi would likely work because the ISO
ships `ath11k/WCN6855/hw2.{0,1}/nfa765/`, identifying `nfa765` as "QCNFA765,
the OLED Deck's Wi-Fi module."

**The hardware disagrees.** dmesg:

```
ath11k_pci 0000:03:00.0: qca2066 hw2.1
ath11k_pci 0000:03:00.0: chip_id 0x12 chip_family 0xb board_id 0x309 soc_id 0x400c1211
ath11k_pci 0000:03:00.0: fw_version 0x11087fff ... WLAN.HSP.1.1-03926.13-QCAHSPSWPL_V2_SILICONZ_CE-2.52297.9
```

The device is **QCA2066 hw2.1**, and the ISO carries a dedicated
`/usr/lib/firmware/ath11k/QCA2066/hw2.1/` directory (`amss.bin.zst`,
`board-2.bin.zst`, `m3.bin.zst`) — a *different* path from the `nfa765` one
§5.1 was watching.

**The conclusion (\"Wi-Fi works\") was right; the reasoning was wrong.** This
matters for T5: if the payload is ever slimmed by pruning firmware, the
directory that must survive is **`ath11k/QCA2066/`**, not
`ath11k/WCN6855/.../nfa765/`. Pruning on §5.1's original reasoning would
have removed the wrong files and broken the radio.

## R-7. Audio DSP firmware is MISSING in the live ISO

```
snd_sof_amd_vangogh 0000:04:00.5: SOF firmware and/or topology file not found.
snd_sof_amd_vangogh 0000:04:00.5:  Firmware file: amd/sof/sof-vangogh.ri
snd_sof_amd_vangogh 0000:04:00.5: Check if you have 'sof-firmware' package installed.
```

The live environment has no `sof-firmware`, so the Vangogh SOF DSP does not
initialize — **there is probably no working audio in the live ISO.**

Impact is limited (the installer needs no sound) but it is a real gap for
T5 if any install-time audio feedback is ever wanted, and it is worth
confirming that the *installed* system gets `sof-firmware`/`steamdeck-dsp`,
since that path is what actually matters. Untested so far.

## R-8. ⚠️ THE BIG ONE — in lizard mode the GAMEPAD NODE IS SILENT

**Measured, not inferred.** A 90-second raw-evdev capture on all four input
nodes simultaneously (`/tmp/evmon.py`, pure `struct`-parsing — no `evdev`
module needed), while the operator pressed **A ×3**, **D-pad Up ×3**, swiped
the right trackpad, and tapped the touchscreen:

| Node | What arrived |
|---|---|
| `event5` btn-as-KBD | `KEY code=28` ×6, `KEY code=103` ×6 |
| `event4` pad-as-MOUSE | `REL code=0` ×1184, `REL code=1` ×1077 |
| `event13` TOUCHSCREEN | multitouch ABS slots + `KEY code=330` (BTN_TOUCH) ×2 |
| **`event11` GAMEPAD** | **NOTHING. Zero events.** |

Decoding `event5`: code 28 = `KEY_ENTER`, code 103 = `KEY_UP`; ×6 each = 3
presses × (press + release). So **A → Enter** and **D-pad Up → Up arrow**.

All four nodes opened successfully (no skip lines), so `event11`'s silence is
a real measurement, not a failed open.

### What this overturns

**R-3a's double-input hazard does not exist.** The firmware does not send a
button press to both the gamepad node *and* the keyboard emulation — it sends
it **only** to the keyboard emulation. Lizard mode is an *exclusive* mode, not
an additive one. Good news, and the opposite of what was feared.

### What it breaks instead — and this is worse

`src/deck-input-mapper.py:177` picks its device with:

```python
def looks_like_gamepad(dev): return e.BTN_SOUTH in caps.get(e.EV_KEY, [])
```

`BTN_SOUTH` lives on the **"Steam Deck" gamepad node (`event11`)** — the one
node that emits nothing while lizard mode is active. So in the live ISO the
mapper will happily *find* a pad, open it, and then **block forever on a
device that never sends an event**. It fails silently and looks like a hang.

> This is precisely the failure class `CLAUDE.md` forbids — a component that
> reports success while doing nothing. The T2 spike could not have caught it:
> it drove a *virtual* uinput pad, which of course emits on the gamepad node
> because there is no Valve firmware in the loop to route it elsewhere.

**Status: strongly evidenced, not yet executed.** The mapper itself was not
run (no `python-evdev` in the live ISO — see R-9). Confirming it is one
command once evdev is available; the prediction is "starts, finds 'Steam
Deck', reports nothing thereafter."

### What it hands us for free

The live ISO is **already navigable without any software of ours**:
trackpad → mouse, A → Enter, D-pad → arrows, plus a working touchscreen.
A graphical installer is operable out of the box.

**This materially re-scopes T4.** Its premise — "build a gamepad→keyboard
mapper so the installer is controller-navigable" — is substantially already
satisfied *by the controller firmware itself*. The open questions become:

1. Is lizard mode's **fixed default mapping** sufficient for all 8 installer
   screens, or are there actions it cannot express? (It gives Enter, arrows,
   mouse, Esc/Tab per the large `KEY=` bitmap — likely most of what a TUI or
   GUI installer needs.)
2. **Text entry** — the Wi-Fi passphrase. Lizard mode has no on-screen
   keyboard; the mapper-drawn TTY OSK from `T2-gamepad-spike.md` §4 is still
   needed, *and* it must read a node that actually emits. Given R-8, it
   cannot be `event11` unless lizard mode is first disabled.
3. If we ever **do** want the gamepad node live, lizard mode must be
   suppressed (kernel `hid-steam` disables it while a userspace client holds
   the hidraw node — mechanism unverified). Doing so **would remove the free
   mouse/keyboard**, which is a real cost, not a free win.

**Recommendation to carry into T4:** default to *using* lizard mode rather
than fighting it, and confine custom input handling to what lizard mode
genuinely cannot do (principally text entry). Decide before writing T4 code.

## R-9. The ISO's pacman is OFFLINE-ONLY

`/etc/pacman.conf` on the live ISO declares exactly one repository:

```
[options]
[offline]
Server = file:///var/cache/omarchy/mirror/offline/
```

No `[core]`, no `[extra]`, no network mirror — `pacman -Sy python-evdev`
returns `offline downloading...` then `target not found`, despite the machine
having working internet.

**This is why the ISO is 6.4 GB:** upstream `omarchy-iso` bakes a complete
package mirror and installs from it, entirely offline, by design.

**Consequences for T5 (P2.7 — "Valve repos into the build"):**

- Adding Valve's `jupiter-staging`/`holo` repos is **not** a matter of
  dropping in a `Server =` line. The build either bakes Valve's packages into
  the same offline mirror, or the installed system must add network repos
  post-install (which `src/omarchy-deck-kernel.sh stage-repos` already does).
- The offline-mirror design is *upstream's*, and it survives `docs/PROGRESS.md`
  §2.2 retiring **our** offline constraint. §2.2 said we may *use* the network;
  it did not make upstream's ISO use it.
- Anything the live environment needs at runtime (e.g. `python-evdev` for a
  mapper/OSK) must be **in the payload**. It cannot be fetched at install
  time under the current pacman config.

## R-10. What the offline mirror actually contains — T5 payload scoping

`/var/cache/omarchy/mirror/offline` on the live ISO: **2483 packages, 4.6 GB**
(i.e. most of the 6.4 GB ISO). Probed for the packages this project needs:

| Package | In mirror? | Consequence |
|---|---|---|
| `limine` | ✅ | Consistent with the Limine-only hard constraint — upstream already uses it |
| `sof-firmware` | ✅ | Present in the *mirror* though absent from the live image (R-7), so the **installed** system can have audio |
| `python` | ✅ | Base interpreter available |
| `python-evdev` | ❌ | **Our mapper/OSK dependency is not in the ISO** |
| `linux-neptune` | ❌ | Expected — Valve's kernel is not upstream Omarchy's concern |
| `linux-firmware-neptune` | ❌ | Same |
| `steam` | ❌ | Same |
| `gamescope` | ❌ | Same |
| `squeekboard` | ❌ | Moot anyway — the TTY-OSK decision (`T2-gamepad-spike.md` §4) already dropped it |

**T5 (P2.7) scope, now concrete.** Every Deck-specific package is absent, and
R-9 established pacman cannot reach the network from the live environment. So
the fork must either bake Valve's packages into this offline mirror, or have
the *installed* system pull them post-install over the network — which is
what `src/omarchy-deck-kernel.sh stage-repos` already does, and is the cheaper
path given §2.2 permits network during install.

**The one that bites soonest is `python-evdev`:** anything of ours that runs
*in the live environment* (a text-entry OSK for the Wi-Fi passphrase) needs
it present in the payload, because it cannot be fetched at install time.
Alternatively, write that component against raw `struct`-parsed evdev with no
third-party dependency — which is exactly what this session's `evmon.py`
proved is practical (R-8).

## R-11. ⚠️ The 4.0 installer enables FULL-DISK ENCRYPTION by default

Discovered by inspecting the first (discarded) install before rebooting it.

`/root/user_encrypt_installation.txt` came out of the TUI as `true`, and the
resulting disk was:

```
nvme0n1p1     2G  vfat          <- ESP
nvme0n1p2 474.9G  crypto_LUKS   <- LUKS2
  └─root  474.9G  btrfs
```

with `cryptdevice=PARTUUID=…:root` on the Limine cmdline, **no TPM2 token
enrolled** (`luksDump` → `Tokens:` empty), and an empty
`/etc/crypttab.initramfs`.

**Consequence: the machine stops at a passphrase prompt on every boot and
cannot proceed without a physical keyboard.**

### Why this is a project-level finding, not an install mishap

It directly contradicts the product's central promise — *"behaves like stock
SteamOS: boots to Gaming Mode"*, controller-only, no keyboard (`CLAUDE.md`).
If the fork inherits upstream's default, **the shipped ISO produces a device
its own user cannot boot.** Nothing in `docs/PLAN.md` §6.1a's screen list
covers a pre-boot passphrase, because until now nobody knew one would exist.

It also breaks P1.5's own **checkpoint β**, which is specifically a *hands-off*
reboot test.

### The options, for T4/T5 to decide

1. **Default encryption OFF in our ISO.** Simplest, matches stock SteamOS
   behavior (which is also unencrypted). Costs at-rest security.
2. **Keep encryption, enroll TPM2 auto-unlock** via `systemd-cryptenroll`
   (the Deck has an fTPM; the live image already carries `tpm2-tss`). This is
   probably the *right* answer for a shipped product — encrypted at rest,
   unattended at boot — but it is unproven on this hardware and needs its own
   spike.
3. **Controller-driven passphrase entry in the initramfs.** Rejected on sight:
   pre-boot, pre-userspace, no compositor, and R-8 shows the gamepad node is
   silent without help. Enormous effort for a worse UX.

**Recommendation:** ship option 1 by default, and treat option 2 as a
follow-on feature rather than a release blocker.

### How the test bed was corrected

Rather than re-drive the TUI, the installer was re-run **non-interactively**
against its own saved config with `user_encrypt_installation.txt` flipped to
`false` and `encryption_password` dropped from `user_credentials.json`:

```
/usr/local/bin/omarchy-iso-install --config /root/user_configuration.json \
  --creds /root/user_credentials.json --encrypt-file /root/user_encrypt_installation.txt \
  --authorized-keys-file /root/authorized_keys ...
```

**This is a reusable capability worth keeping:** upstream's installer is fully
driveable from a config file with no TUI at all, and it accepts
`--authorized-keys-file` (SSH keys injected at install time) and
`--tailscale-authkey-file`. For T5, that is a far cleaner integration point
than post-install scripting — and it makes automated install testing in QEMU
straightforward.

Teardown needed before re-running: `swapoff -a` (the installer creates a
hibernation swapfile at `/mnt/swap/swapfile` that holds the mount), then
`umount -R /mnt`, then `cryptsetup close root`.

## R-12. Rotation, part 3 — the INSTALLED system's greeter IS rotated

R-1a concluded "post-kernel is correct, only the bootloader is rotated."
**That was too broad.** On the installed system:

| Environment | Kernel | `fbcon/rotate` | Result |
|---|---|---|---|
| Live ISO | `7.1.6-arch1-Watanare-T2-1-t2` (`linux-t2`) | **1** | correct |
| Installed | `7.1.6-arch1-1` (stock Arch) | **0** | **SDDM greeter rotated 90° CCW** |

Same hardware, same upstream kernel version, different builds — and no
`panel_orientation` sysfs property exposed on `card1-eDP-1` in the installed
system. The kernel cmdline carries no rotation flag in either case.

So the rotation correction seen in the live ISO came from **the `linux-t2`
kernel's patches**, not from a universal upstream quirk. Stock Arch does not
apply it, and **SDDM** (the display manager Omarchy 4.0 installs — confirmed
`display-manager.service → sddm.service`) renders sideways as a result.

**Deliberately not chased yet.** Phase E replaces this kernel with Valve's
`linux-neptune`, which carries Deck hardware support and plausibly the panel
quirk too. Diagnosing against a kernel we are about to remove would be wasted
work. **Re-check `fbcon/rotate` and the greeter immediately after the Neptune
conversion**, and only then decide whether T3/T5 must ship a fix.

If it does still need fixing, the lever is SDDM's compositor (Omarchy 4.0 uses
SDDM, so `sddm.conf`'s Wayland compositor settings), *not* `fbcon=rotate:`
— fbcon governs the text console, which is not what the greeter draws on.

## R-13. ✅ Phase E — the stock→Neptune conversion, validated on hardware

`docs/PROGRESS.md` §5.2's last T1 gap, closed 2026-08-10. All ten stages run over
SSH via `tools/deck-sync.sh`, one at a time, **every one exit 0**:

```
stage-preconditions  ok   hardware: Valve Galileo
stage-repos          ok   jupiter-staging + holo-staging ADDED (2 added, 0 present)
stage-esp-detect     ok   ESP /boot (nvme0n1p1), config /boot/limine.conf
stage-firmware-swap  ok   REMOVED 11 Arch firmware packages
stage-kernel         ok   linux-neptune-611 6.11.11-valve29-1 + firmware-neptune
stage-uki            ok   /boot/EFI/Linux/omarchy_linux-neptune-611.efi
stage-prune          ok   nothing stale
stage-default-entry  ok   '2' -> 'Omarchy/linux-neptune-611'   <- real path, first time
stage-hook           ok   95-omarchy-deck-kernel.hook installed
stage-esp-permissions ok  fmask=0133,dmask=0022 via full umount/mount cycle
```

**Seven of the ten ran their REAL path for the first time**, not the no-op path
the old hand-converted Deck could only exercise. In particular the firmware
swap genuinely removed Arch's split packages (`linux-firmware` + 10
subpackages — exactly the count §7 predicted Valve's `conflicts`/`replaces`
would miss), and the ESP permission stage completed a real umount/mount cycle
on a live system.

### Checkpoint β — unattended boot, proven

Rebooted with **no key pressed**, menu allowed to time out:

| Assertion | Result |
|---|---|
| `uname -r` | `6.11.11-valve29-1-neptune-611-g2dcfaf4df7ac` ✅ |
| `LoaderEntrySelected` efivar | `Omarchy/linux-neptune-611` ✅ |
| `reconcile` exit code / writes | `0`, wrote nothing — all "up to date" ✅ |
| Wi-Fi / Bluetooth / audio on Neptune | `wl*` present, `hci0` present, 2 audio cards ✅ |
| ESP mount options after reboot | `fmask=0133,dmask=0022` persisted ✅ |

The `LoaderEntrySelected` read is the load-bearing one: it is the firmware's
own record of what it booted, so the **path form** of `default_entry` is
confirmed honored on real hardware, not merely in QEMU.

Snapshots for the abort ladder: **#1** `pre-Neptune`, **#2** `neptune converted`.

### R-13a. Rotation is NOT fixed by the Neptune kernel

The open question from R-12 is answered, and the answer is no:

```
fbcon/rotate = 0        (Neptune, same as stock Arch; the live ISO's t2 kernel had 1)
panel_orientation       absent on card1-eDP-1
```

So **no kernel available to this project auto-corrects the panel** — only the
live ISO's `linux-t2` build did. Consequences:

- The rotation correction must come from **userspace**, per surface:
  - **Console/TTY** → `fbcon=rotate:1` on the kernel cmdline.
  - **SDDM greeter and Hyprland** → compositor-level transform
    (Hyprland `monitor = eDP-1,…,transform,1`), *not* `fbcon=`.
  - **Gaming Mode** → gamescope handles rotation natively; expected fine.
- **R-4's advice is now reversed.** It said "do not add a rotation flag, the
  kernel already corrects it" — true only of the live ISO's t2 kernel. On the
  shipped configuration a flag (or compositor transform) **is** required.
  This is a T3/P2.4 item, and a visible one: it affects the login screen.

### R-13b. Minor: a symlink loop from a Valve package

Recurring in the journal, harmless so far but worth knowing:

```
Failed to chase '/usr/lib/systemd/system/multi-user.target.wants/cec-sysconf.service':
Too many levels of symbolic links
```

Appears after `stage-kernel`, i.e. from a `jupiter-staging`/`holo-staging`
package, not from anything this project writes. Nothing has failed because of
it. Note it before blaming our own code for a boot oddity later.
