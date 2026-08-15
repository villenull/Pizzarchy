# P32 — `linux-firmware-neptune`: does the Deck need it, and where should it go?

**Date:** 2026-08-15 · **Status:** investigation complete, no code changed
**Tree state:** clean at `5cb4c26` when this started; nothing modified, nothing committed.

**Verdict up front: the Deck does NOT need Valve's firmware. Drop
`linux-firmware-neptune` from `deck-mirror.packages` and reclaim 349.6 MiB.**
Every firmware file the Deck's hardware uses is already in Arch's split
`linux-firmware-*` set, at the same path; where the two differ on Deck-relevant
hardware, **Arch's is the newer build**. This recommendation is against keeping
a payload, so it is not the convenient answer — it is what the file lists say.

---

## 0. Premise check — the operator's brief was stale, and the correction holds

`linux-firmware-neptune` is **not** in
`iso/overlay/configs/deck/deck-install.packages`. It was removed in `a380fe3`
("Neptune only: override detect_kernel…", 2026-08-15 14:13), for exactly the
file-conflict reason the brief asked about. Verified with
`git show a380fe3 -- iso/overlay/configs/deck/deck-install.packages`. It has not
been restored and its absence is correct, not a bug.

It **is** still in `iso/overlay/configs/deck/deck-mirror.packages` line 63 —
downloaded into the offline mirror, installed by nothing. That is the real
subject of this document.

### One correction to the recorded diagnosis

`docs/PROGRESS.md` §7 and the `deck-install.packages` comment both say Valve
declares "`conflicts`/`replaces` against only `linux-firmware` and
`linux-firmware-whence`". Read off the package's own `.PKGINFO`:

```
replaces = linux-firmware
conflict = linux-firmware
provides = linux-firmware
depend   = linux-firmware-whence
```

`linux-firmware-whence` is a **dependency**, not a second conflict. The
consequence is unchanged (pacman removes the one metapackage it was told about
and then dies on file conflicts with the ten subpackages), and
`colliding_arch_firmware` in `src/omarchy-deck-kernel.sh` already excludes
`whence` from removal, so the code is right. Only the prose is off by one.

Arch's `linux-firmware` metapackage hard-depends on exactly ten subpackages —
`amdgpu atheros broadcom cirrus intel mediatek nvidia other radeon realtek`.
`marvell`, `qcom`, `liquidio`, `mellanox`, `nfp`, `qlogic` are **optdepends**
and are therefore *not* on the target. All comparisons below use the ten that
actually get installed, so this models the real installed system rather than
"everything Arch publishes".

---

## 1. Does the Deck need Valve's firmware? **No.**

### 1a. The whole-kernel sweep — the strongest evidence

Rather than checking the four things I happened to think of, I extracted all
**6,150 modules** from `linux-neptune-611-6.11.11.valve29-1` and read every
`firmware=` declaration out of them (`modinfo -F firmware`, plus
`modules.builtin.modinfo` for built-ins). That is **1,973 distinct firmware
files Valve's own kernel can ever request.** Then:

| | count |
|---|---|
| Requested by Valve's kernel | **1973** |
| …provided by Arch's installed ten | 1431 |
| …provided by `linux-firmware-neptune` | 1455 |
| **Requested, in Valve's, ABSENT from Arch's — the gap that matters** | **32** |
| Requested, in Arch's, absent from Valve's | 1415 |

**All 32 files in that gap, in full:**

```
acenic/tg1.bin              acenic/tg2.bin
emi62/bitstream.fw          emi62/loader.fw          emi62/spdif.fw
ess/maestro3_assp_kernel.fw ess/maestro3_assp_minisrc.fw
korg/k1212.dsp              lgs8g75.fw
mts_mt9234mu.fw             mts_mt9234zba.fw
sun/cassini.bin             ttusb-budget/dspbootcode.bin
ueagle-atm/{930-fpga,adi930,eagleI,eagleII,eagleIII}.fw
ueagle-atm/{CMV9i,CMV9p,CMVei,CMVep,DSP9i,DSP9p,DSPei,DSPep}.bin
vicam/firmware.fw           yam/1200.bin             yam/9600.bin
yamaha/ds1_ctrl.fw          yamaha/ds1_dsp.fw        yamaha/ds1e_ctrl.fw
```

AceNIC and Sun Cassini gigabit NICs, Emagic and Korg and ESS Maestro3 and
Yamaha DS-1 sound cards, Eagle-chipset ADSL USB modems, Multi-Tech dial-up
modems, a DVB-S tuner, an LG DTV demodulator, a ViCAM webcam, and a ham-radio
packet modem. **All of it 1990s–2000s hardware Arch dropped from packaging.
None of it is on, or attachable to, a Steam Deck.** Filtering the gap for
`amdgpu|ath11k|qca|cirrus|cs35l|nau88|vangogh` returns **zero** matches.

The 1,415 in the other direction are mostly newer AMD/NVIDIA/Intel parts Valve's
July fork predates — irrelevant to the Deck but a reminder that Arch's set is
the broader and fresher one.

*(The `comm`-based first pass warned about sort order on these paths; the table
above is the independent Python set-arithmetic re-run, which agreed on 32.)*

### 1b. Wi-Fi — QCA2066 hw2.1, the load-bearing case

`docs/PROGRESS.md` §5.1 says anything pruning firmware must keep
`ath11k/QCA2066/`. Path sets are **identical**:

```
usr/lib/firmware/ath11k/QCA2066/hw2.1/{amss.bin,board-2.bin,m3.bin,Notice.txt}
usr/lib/firmware/qca/QCA2066/{rampatch_usb_00130201.bin,nvm_usb_00130201_030a.bin,nvm_usb_00130201_gf_030a.bin}
```

Contents, decompressed and hashed:

| file | Valve | Arch | |
|---|---|---|---|
| `ath11k/QCA2066/hw2.1/board-2.bin` | 745,440 | 745,440 | **byte-identical** |
| `ath11k/QCA2066/hw2.1/m3.bin` | 266,684 | 266,684 | **byte-identical** |
| `ath11k/QCA2066/hw2.1/amss.bin` | 5,160,960 | 5,349,376 | differs in size… |
| BT `rampatch_usb_00130201.bin` | 160,124 | 160,124 | **byte-identical** |
| BT `nvm_usb_00130201_030a.bin` | 6,917 | 6,917 | **byte-identical** |
| BT `nvm_usb_00130201_gf_030a.bin` | 6,749 | 6,749 | **byte-identical** |

…but `amss.bin` carries the **same Qualcomm release** in both:

```
QC_IMAGE_VERSION_STRING=WLAN.HSP.1.1-03926.13-QCAHSPSWPL_V2_SILICONZ_CE-2.52297.9
```

Same firmware version, Arch's blob merely larger (extra trailing segments).
Bluetooth is bit-for-bit the same firmware — Arch just stores it deduplicated as
symlinks into `qca/hpbtfw21.tlv` / `hpnv21.30a` / `hpnv21g.30a`, which is why a
naive path-existence check appears to show them missing. They are present.

**The one genuinely Valve-only ath11k entry is `ath11k/QCA206X`, a symlink to
`QCA2066`.** It is a compatibility alias for older SteamOS kernels. I checked
whether Valve's own 6.11 kernel needs it: `ath11k.ko` contains the firmware
directory strings `QCA2066/hw2.1`, `QCA6390/hw2.0`, `WCN6855/hw2.1` … and
**zero occurrences of the string `QCA206X`**. The alias is dead weight for this
kernel.

### 1c. GPU — Van Gogh / Sephiroth

All 11 `amdgpu/vangogh_*` paths exist in both. Three are byte-identical
(`rlc`, `sdma`, `toc`). Eight differ — and parsing the ucode version out of the
AMD common firmware header (offset 16) shows **Arch is newer or equal in every
single case**:

| file | Valve ucode | Arch ucode |
|---|---|---|
| `vangogh_asd.bin` | `0x210000eb` | **`0x21000115`** |
| `vangogh_dmcub.bin` | `0x300000a` | **`0x3000010`** |
| `vangogh_vcn.bin` | `0x211b000` | **`0x4121015`** |
| `vangogh_mec.bin` | `0x7a` | **`0x86`** |
| `vangogh_pfp.bin` | `0x68` | **`0x6d`** |
| `vangogh_ce.bin` | `0x25` | `0x25` (equal) |
| `vangogh_me.bin` | `0x40` | `0x40` (equal) |

This is the expected result: Valve's package is a **fork of upstream
linux-firmware pinned at `jupiter.20260712`**, and Arch's is the `20260810`
snapshot — a month newer. Valve's package is not a set of Deck-exclusive blobs;
it is a stale copy of the same upstream tree.

### 1d. Audio

`cs35l41-dsp1-spk-prot.{bin,wmfw}` — Valve ships these at **both**
`cirrus/…` and the firmware root. Arch ships the `cirrus/…` pair, which is the
path the driver requests; the root-level copies are a legacy duplicate. Arch
carries **1,008** `cs35l41` files in total.

The 127 Valve-only `cirrus/` + `ti/tas2781` + `ti/tas2563` entries are all
tuning blobs keyed by *other vendors'* subsystem IDs — `1028` (Dell), `1043`
(ASUS), `103c` (HP), `17aa` (Lenovo). Not Valve, not the Deck.

Separately, `docs/PROGRESS.md` §7 already records that the `cs35l41-dsp1-*`
firmware warnings once thought "expected on OLED" **do not occur on current
firmware**. The Deck's DSP support comes from `steamdeck-dsp`, which is a
different package and is correctly installed.

### 1e. Hardware evidence that already exists

`linux-firmware-neptune` has **never been installed by anything** in this
project's ISO path. So every hardware run to date already ran on Arch's
firmware. `docs/PROGRESS.md` §5.32 records, as first hardware evidence:
*"the Wi-Fi profile carries from the installer and reconnects on its own;
live-ISO Wi-Fi works on stable"*, plus gamescope running and the panel lit.

⚠️ **Scope this honestly:** that run booted `omarchy_linux.efi` — **stock
`linux`**, not Neptune. So what hardware has proven is *Arch firmware + Arch
kernel*. The pairing this question is actually about, *Arch firmware +
`linux-neptune-611`*, has passed **QEMU only** (both P32 install runs). The
bridge between them is §1a: Neptune's own modules request 1,973 firmware paths
and Arch supplies every one that isn't 1990s hardware.

---

## 2. Where should the displacement live? **Nowhere — remove the package.**

Since §1 says nothing needs displacing, the placement question mostly dissolves.
Recording the evaluation anyway, because the option ranking is the useful part.

### (d) Drop it from the mirror — ✅ RECOMMENDED

Delete the `linux-firmware-neptune` line from `deck-mirror.packages`.

- **Works?** Yes, and it is the only option with no runtime failure mode at
  all — there is no step to half-fail, no window with no firmware, no
  `pacman -Rdd` on a user's machine.
- **What breaks if it half-fails?** Nothing; it is a build-time list edit,
  and guard 6.8 plus `test/unit/test-deck-pkgs.py` cover the list's shape.
- **Loud?** Not applicable — nothing runs.
- **Cost:** a Deck that later wants Valve's exact firmware must fetch it
  online via `src/omarchy-deck-kernel.sh`, which already does the whole
  `-Rdd` dance correctly and already requires the Valve repos. That path is
  unaffected by this change.

### (c) Leave it to the user's later `omarchy-deck-kernel.sh` run — ✅ this is what already happens

This is the current de-facto state and it is correct. `stage_firmware_swap`
handles the collision properly, checks `require_valve_repos` *before* removing
anything, and shouts if it leaves the system bare. **The only defect is that
carrying the package in the mirror buys that path nothing**: `omarchy-deck-kernel.sh`
runs against the *online* Valve repos on a booted system, not against the ISO's
offline mirror, which no longer exists by then. The mirror copy is unreachable
by its only plausible consumer.

### (a) A step inside `configure_deck` — ❌ works, but should not be built

Mechanically feasible: it runs inside the target via `arch-chroot` after
pacstrap and could reuse the `-Rdd` logic. But:

- It would open a real **no-firmware window** inside an install the user cannot
  see into. `stage_firmware_swap`'s own comments call this out as the one stage
  that leaves a system worse than it found it, and it survives that only because
  `stage_kernel` runs immediately after in the same script.
- The orchestrator's registry has exactly **one** `critical=True` step
  (`autologin`). A firmware swap would have to be critical — a Deck with no
  Wi-Fi firmware cannot be recovered by a controller — which means adding a
  second way for a finished 1,200-package install to abort.
- Failure would be loud (the step registry records outcomes and prints the
  phase), so it does not violate the no-silent-swallow rule. It is still
  **risk with no benefit**, since §1 shows there is nothing to gain.

### (b) A first-boot service — ❌ worst option

The `deck-wifi-first-boot.sh` / `deck-steam-first-boot.sh` pattern is right for
things that need the network on a booted machine. It is wrong here: a service
that removes the running system's firmware and installs a replacement, on first
boot, **before the user has confirmed Wi-Fi works**, can leave a Deck with no
radio and no way to fetch the fix. It would be loud (`systemctl --failed`, the
established pattern) — but loud-and-bricked is still bricked.

---

## 3. The size question

| | bytes | |
|---|---|---|
| `linux-firmware-neptune-jupiter.20260712.1-2-any.pkg.tar.zst` | 366,612,354 | **349.6 MiB** |
| Current ISO (`p32-build/release/omarchy-2026.08.15-x86_64-quattro.iso`) | 6,854,164,480 | **6.383 GiB** |
| ISO after dropping it | ≈ 6,487,552,126 | **≈ 6.042 GiB** |

**Saving ≈ 349.6 MiB, ≈ 5.3 % of the image.** The mirror is stored
**uncompressed** inside the squashfs (`configs/profiledef.sh`'s
`uncompressed@subpathname(...)`), and the file is already zstd-compressed, so
the ratio is ~1:1 — this is the one payload item where the arithmetic is
straightforward.

**Against T5g's gate:** `docs/tasks/T5-fork-plan.md` §"Measured numbers" is the
baseline T5g starts from — the Deck fork took the mirror from 1,244 to 1,283
package files, **+544 MiB compressed**, and states *"`linux-firmware-neptune`
alone is 350 MiB of that 544."* Dropping it therefore **cuts the fork's entire
measured size regression by 64 %**, from +544 MiB to ~+194 MiB. I could not find
a numeric pass/fail threshold for T5g anywhere; the task row (line 651) scopes it
as "size number (step 4), CI job (step 5)" — the gate appears to be **unwritten
as yet**, so this is a saving against a baseline, not against a limit.

---

## 4. Two stale comments this turned up (NOT fixed — investigation only)

1. **`deck-mirror.packages` lines ~56-63 are now wrong.** The block says
   *"DUAL ENTRY, **both of them**: the bare names are in deck-install.packages
   as of 2026-08-15, so pacstrap installs them from this mirror"* — covering
   `linux-neptune-611` **and** `linux-firmware-neptune`. `a380fe3` removed the
   latter from `deck-install.packages` an hour later and did not update this
   file. As written, the comment asserts a consumer that does not exist. This is
   the same species of defect as `docs/findings/P32-steam-never-installed.md`,
   caught in prose rather than in code.

2. **`deck-mirror.packages` line ~79** justifies keeping
   `linux-neptune-611-headers` because *"the cost is ~10 MiB against a 350 MiB
   firmware package sitting beside it."* The headers package is actually
   **35,403,648 B = 33.8 MiB**, and if the recommendation here is taken, the
   350 MiB package is no longer sitting beside it — so both halves of that
   justification expire together.

---

## 5. What guard 6.8 does and does not catch

Guard 6.8 (`iso/bin/build` ~1238) passes on the current tree, **correctly by its
own definition**. `deck-mirror.packages` genuinely has a consumer: the patched
`build-iso.sh` adds it to `all_packages` and `pacman -Syw` downloads it.

Its comment block admits one limitation — *"this guard CANNOT tell an installer
from a checker: it matches the file's NAME, not what is done with it."* That is
**not** the limitation in play here. The gap here is a third one, unstated: a
list can have a consumer that **installs into the mirror rather than onto any
target**. `deck-mirror.packages` is legitimately a staging list, so the guard
cannot flag the file — but it also cannot notice that one *line* in it now
reaches nothing.

The build already has the right shape for this: the patched `build-iso.sh`
(`deck-packages.patch` ~401-427) documents the **dual-entry pattern** — a
mirror entry that must also be installed appears a second time, bare, in
`deck-install.packages`. `linux-neptune-611-headers` is explicitly marked
`🔴 READER: NOBODY, ON PURPOSE` with its reasoning written out. **A
per-line rule — "every `deck-mirror.packages` entry either has a matching
`deck-install.packages` entry or an explicit no-reader annotation" — would be
mechanically checkable and would have flagged `linux-firmware-neptune` the
moment `a380fe3` landed.** Offered as an observation; no code was written.

---

## 6. What I could NOT determine without a build or hardware

Stated plainly, because this project's record punishes reconstructed confidence.

1. **That Arch's *newer* Van Gogh ucode is not a regression on the Deck.** I
   proved Arch's versions are higher and that no path is missing. Higher is
   normally better, but "newer AMD ucode never regresses on Sephiroth" is an
   assumption, not a measurement. Only a boot on the OLED Deck settles it.
2. **`linux-neptune-611` + Arch firmware on real hardware.** Proven in QEMU
   twice; on hardware, only *stock `linux`* + Arch firmware has ever run
   (§1e). QEMU exercises no ath11k radio, no amdgpu, no DSP.
3. **The exact rebuilt ISO size.** 6.042 GiB is arithmetic (current size minus
   package size at the documented ~1:1 mirror ratio), not a measured build.
   Squashfs block alignment will move it slightly.
4. **Whether `ath11k/QCA206X` matters to anything else on the system.** I
   proved `ath11k.ko` from `linux-neptune-611` never requests it. I did not
   audit userspace (`steamos-*` tooling, Valve's own scripts) for a hardcoded
   reference to that path. Low risk — it is a firmware directory, and firmware
   directories are read by drivers — but not zero, and not checked.
5. **T5g's actual pass/fail size threshold.** It does not appear to be written
   down yet; if one exists outside `docs/tasks/T5-fork-plan.md` I did not find it.
6. **Whether removing the mirror entry perturbs the offline resolver.** The
   package is Valve-only with no name overlap (P16's audit) and nothing depends
   on it, so removal should be inert — but the mirror prune keep-set and
   `resolve_expected_packages` were not re-run.

---

## 7. Recommendation

1. **Remove `linux-firmware-neptune` from `deck-mirror.packages`.** Reclaim
   349.6 MiB. Leave `deck-install.packages` exactly as `a380fe3` left it.
2. **Update the two stale comment blocks in §4** in the same change, so the
   file stops asserting a consumer that does not exist.
3. **Leave `src/omarchy-deck-kernel.sh` completely alone.** Its
   `colliding_arch_firmware` / `stage_firmware_swap` remain correct and remain
   the right home for anyone who deliberately wants Valve's firmware later. Fix
   only the "two conflicts" prose noted in §0.
4. **Do not build a `configure_deck` step or a first-boot service for this.**
5. Consider the per-line mirror/install cross-check in §5 as a T5g or guard
   follow-up.

**Scratch/evidence:** `~/.cache/omarchy-deck/agent-fw/` — `neptune.rel`,
`arch.rel`, `fw-requested.txt` (the 1,973), `GAP.s` (the 32), `only-valve.paths`
(the 180 raw path-level diff), extracted comparison trees under `ex2/`.
