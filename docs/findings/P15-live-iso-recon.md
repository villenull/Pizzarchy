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
