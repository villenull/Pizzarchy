# INSTALL-SPEED — can a Pizzarchy install hit DHH territory?

Research only, 2026-09-23. No source, test, ISO or Deck state was changed. Every number
is labelled **measured** (with its source) or **[INFERENCE]** (with the reasoning).

## Verdicts

Three different clocks answer to "install time". Upstream's published figures are clock (A).

| Clock | Today (measured) | Sub-30 s? | Honest floor |
|---|---|---|---|
| **(A) install wall time**: last form confirm → "ready to reboot" (what upstream's dashboard prints, see §2.1) | **252 s** (4 m 12 s), Deck install of 2026-09-23 | **YES, conditionally.** It needs three things. (1) Steam's ~496 MB client download must overlap the form. (2) pacman (86 s, CPU-bound) must be replaced by an image restore, whose bytes are read off the stick *during the form*. (3) The UKI and finalisation must be prebuilt or run in parallel. Estimated 15–30 s after the confirm [INFERENCE]. Without staging during the form: **NO** on the operator's stick. | With staging: about 5–10 s of writes and identity after the confirm [INFERENCE]. Without staging: ≥ 42 s to read the image off an 82 MB/s stick, plus 113 s of Steam download at the measured link speed. |
| **(B) user-perceived total**: power on with the stick → Gaming Mode on the installed system | about 6–8 min including the form [part INFERENCE, §1.3] | **NO**, under any design | About 60–70 s with no human time at all. About 1.5–2 min with a quick controller user. |
| **Installed cold boot** → Steam's Gaming Mode UI | **~34 s** (first boot after install, journal). Gamescope plus our cover splash are up at **~27 s** | **Probably YES** after today's Limine fix (about −3 s, giving ~31 s) plus 1–3 s trimmed from the initrd or userspace. Needs a hardware measurement | About 20–22 s [INFERENCE, §4.3] |

In one line: **(A) can go sub-30 s, but only by doing what DHH does: installing while the
user types.** In our case that also means downloading Steam while the user types. **(B) can't:** firmware, the
live boot, a human with an on-screen keyboard, a reboot and Steam's own startup add up to more than 30 s
before any install work at all.

---

## 1. Baseline: where the 252 s go (measured)

Sources, all read-only and pulled on 2026-09-23 from the test Deck (Galileo/OLED), which
was freshly installed that day, 14:57:27–15:01:39 local, from a 4.0.4-pin Pizzarchy ISO:

* `/var/log/omarchy-install-timing.json`: upstream's per-phase `elapsed`, written by
  `phases.run` (`iso/upstream/configs/airootfs/usr/share/omarchy-iso/orchestrator/phases.py:76-78`)
* `/var/log/archinstall/install.log`: per-transaction timestamps
* `/var/log/pacman.log`: per-transaction timestamps, including the online `steam` install
* `/var/log/omarchy-install.log`: console log, including the Steam bootstrap's 20 s progress lines
* `/var/log/omarchy-deck-install.json`: our per-step record (`steam_bootstrap.seconds = 132`,
  `package_bytes = 509865729`)
* Copies in `/var/tmp/deck-install-2026-09-23/` and `/var/tmp/instspeed/`.

### 1.1 Per-phase time budget, clock (A)

| Phase (upstream name) | s | What it is | Source |
|---|---:|---|---|
| Preparing live environment | 1.9 | holders cleanup, configurator output | timing.json |
| Preparing install target | 0.0 | | timing.json |
| **Installing Arch + Omarchy** | **86.0** | archinstall: partition + pacstrap from the offline mirror | timing.json |
| ↳ wipe, partition, mkfs.fat, mkfs.btrfs, subvolumes, mounts | ~1 | 20:57:29 → 20:57:30 | archinstall.log |
| ↳ `base … linux-omarchy linux-firmware` (157 pkgs, 1086 MiB) | 16 | 20:57:30 → :46 | archinstall.log, install.log:263-289 |
| ↳ headers, zram, early Omarchy set, lua, nvim, sof, pipewire | 16 | 20:57:46 → 20:58:02 | archinstall.log |
| ↳ **main Omarchy set (719 pkgs, 6451 MiB)** | **53** | db sync 4 s (20:58:02 → :06) + extract 44 s (→ :50) + hooks ~5 s (→ :55) | pacman.log:532-1323, archinstall.log |
| Configuring hibernation | 0.3 | swapfile | timing.json |
| Configuring system | 3.1 | `omarchy-setup-system` scripts, 14:58:55 → :58 | timing.json, install.log:3141-3365 |
| **Configuring Steam Deck** (ours) | **142.1** | 14:58:58.9 → 15:01:21.0 | timing.json |
| ↳ `wifi` | <1 | NM profile copy | install.log:3369 |
| ↳ `pkgs`: online `pacman -Sy` + `-S steam` (+24 lib32 deps) | ~6 | 14:58:59 → 14:59:04 (+ hooks) | pacman.log:1334-1368 |
| ↳ **`steam_bootstrap`**: Valve's updater in the target | **132** | 496,397 KB download (20/43/65/88/97 % at 20/40/60/80/100 s, i.e. **~4.4 MB/s**, 110–115 s), then extract + install ~12–17 s | deck-install.json, install.log:3375-3391 |
| ↳ `steam_seed` … `session_bake` … `patches` (11 steps) | ~3–4 | 15:01:17 → 15:01:21 | [INFERENCE] from the bootstrap's last log line (15:01:16) and the phase end |
| Staging provisioning | 2.2 | Node tarball stash | timing.json |
| **Finalizing Limine boot** | **13.1** | mkinitcpio + UKI build (zstd), `limine-update` | timing.json, install.log:3425-3460 |
| Finalizing user | 3.0 | `omarchy` user scripts (mise etc.) | timing.json |
| login, SSH, Tailscale, DNS, validate, factory snapshot | 0.2 | | timing.json |
| **Total** | **251.9** | 1068 packages installed | timing.json |

**Throughput facts from the same install:**

* pacman consumed **3.13 GB of compressed packages in ~86 s ≈ 36 MB/s** and wrote about 9.0 GiB.
  This matches upstream's own comment, "pacman consumes it at only ~33MB/s"
  (`iso/upstream/configs/airootfs/root/.automated_script.sh:61-62`). It is **CPU-bound**, not
  stick-bound (§3.4).
* **Steam is 53 % of the install**, and its bound is the user's internet link, not anything on the Deck.
* LUKS is **not** in the Deck budget. The install is unencrypted by design (`iso/overlay/patches/deck-form-invocation.patch`,
  hunk 2), and `lsblk` on the Deck shows btrfs directly on `nvme0n1p2`.

### 1.2 Installed cold boot, first boot after the install (measured)

`systemd-analyze`: 5.185 s firmware + 7.707 s loader + 6.836 s kernel + 66.647 s userspace.
**The 66.6 s userspace figure is an accounting artefact.** `deck-session-alive.service` is a
`Type=oneshot` ordered `After=sddm.service` that sleeps about 60 s by design (its own unit comment says
"NOTHING MAY DEPEND ON THIS"). Its ExecMain ran from 13.39 s to 73.48 s monotonic, and it alone
delays `graphical.target` to 73.48 s. Nothing visible waits on it.

What the panel actually does, from `journalctl -b -o short-monotonic`. Monotonic counts from kernel start, so add
12.9 s of firmware + loader for time since power-on:

| Event | monotonic | since power-on |
|---|---:|---:|
| sddm selects `gamescope-wayland`, autologin | 13.43 s | 26.3 s |
| gamescope has the OLED panel (`steamdeck_oled_sdc`) | 13.99 s | 26.9 s |
| our cover splash drawn (`deck-steam-splash`) | 14.54 s | 27.4 s |
| Steam launched; `steam-wait-online` skipped (client present, §5.46) | 14.60 s | 27.5 s |
| Steam `Verification complete` | 17.65 s | 30.5 s |
| `steamwebhelper` exec, cover held +2 s | 19.44 s | 32.3 s → cover down ~34.3 s |

So Steam's UI arrives at **~33–35 s after power-on** [the first painted frame is INFERENCE; the
§5.45 hand-over is still unmeasured]. The plymouth → gamescope gap is 13.2 → 14.5 s. The
~10 s black gap in KNOWN-ISSUES #3 predates the §5.45 cover, and in today's journal the uncovered
stretch is about 1.3 s. That is from timestamps, not seen on the panel.

The loader's 7.7 s includes **Limine's 5 s default timeout**. The 2 s template value
(`0040-limine-boot-timeout`) had not reached the ESP on this install (reported by Main,
fixed today in `deck_rotation.py`), which saves about 3 s. `timeout: 0` is deliberately rejected: it strands
the fallback and snapshot entries on a keyboard-less device (`0040-limine-boot-timeout.meta:17-21`).
The initramfs is 57 MB ("Freeing initrd memory: 56972K").

### 1.3 Clock (B) pieces

| Piece | s | Status |
|---|---:|---|
| Deck firmware | 5.2 | measured (installed boot; the same firmware runs before the stick boots) |
| Ventoy menu + ISO select | ? | human; Ventoy waits for a choice unless its auto-boot timeout is set |
| Live ISO → first installer screen ("This installs Omarchy on your Steam Deck…") | **16–18** in QEMU/KVM with the stick throttled to 82 MB/s (3 runs); 14–21 unthrottled (3 runs) | measured in QEMU (§3.6); on the Deck **~25–30 s** [INFERENCE: the ~14 s CPU-bound part × ~2–2.5 per-core ratio, §3.3] |
| Form (Wi-Fi password on the OSK, user, password, timezone, disk, summary) | ? | human. The log shows this operator went back and retyped the user once. 60–180 s is an [INFERENCE] |
| Install | 252 | measured |
| "Reboot" confirm → firmware | ? | a `gum confirm` (`deck-dashboard.sh:200-202`). On 2026-09-23 the install finished 15:01:39 and the next kernel started ≈15:04:45, so there were 2 m 53 s of wall time including a human wait. Not attributable |
| Installed first boot → Steam UI | ~34 | measured (§1.2) |

---

## 2. Upstream state of the art (primary sources)

### 2.1 What the published numbers measure

The completion screen's "Installed Omarchy in Xm Ys" is `finished_at − started_at` from
`state.json` (`iso/upstream/configs/airootfs/usr/local/bin/omarchy-install-dashboard:469-514`).
`started_at` is set when `phases.run` begins, after the wizard. **So every DHH and leaderboard
figure is clock (A)**, measured on x86 laptops and workstations with encryption **on**.

| Claim | Source |
|---|---|
| "50 SECONDS" Quattro install record, HP ZBook Ultra G1a (Ryzen AI Max 395+), 2026-08-14 | <https://x.com/dhh/status/2088218786302136694> |
| "~45 second setup on fast hardware", "speeding installs by 40%" (TheStandup, 2026-08-23) | <https://daily.dev/posts/dhh-omarchy-quattro-announcement-thestandup-cwrsqqf0t> (summary of <https://www.youtube.com/watch?v=MWvH7BRgwL8>) |
| "Be up and running in as little as 35 seconds on the fastest machines"; "Under a minute from stick to desktop" | <https://omarchy.org/> (fetched 2026-09-23) |
| Leaderboard: 35 s (4.0.2, 2026-09-05) is the record. Its times are the installer's own completion line | <https://omarchy.racing/> |
| **"broken the insane 10 second mark"** in the lab, 2026-09-18, with "unreleased turbo accelerations". Asked "with disk encryption on?": "Yes. (That's actually the majority of the time)" | <https://x.com/dhh/status/2100916741429711312> |
| Quattro release notes: "Speed-up installation by +30% (sub-minute installs now possible!)" | <https://github.com/omacom/omarchy/pull/6231> |

I found no primary source for a "12 s" design under that number. The two nearest primary
sources are DHH's sub-10 s lab claim above and PR #145 below (13.87 s recorded, 14.5 ± 0.6 s).

### 2.2 The techniques, and whether our pin (`omacom/omarchy-iso@7cfb7111`) has them

Checked with `git merge-base --is-ancestor <sha> HEAD` in `iso/upstream`.

| Technique | Upstream ref | In our pin? | Does our overlay defeat it? |
|---|---|---|---|
| **"Install while typing", v1: warm the offline mirror into the page cache during the wizard** | `89245f44ece18f0cdc4b8a8c3edbc65c7b8c5136` (DHH, 2026-07-27); idea from PR #85 (closed): real USB A/B 5:36 → 4:31 | **Yes** (`.automated_script.sh:60-91`) | **No**, it runs unchanged. But it reads **largest first across the whole 4.64 GB mirror**, and 1.5 GB of that is never installed on a Deck (§3.1). On a short form the useful bytes wait behind NVIDIA and T2 packages |
| CPU governor → performance during install | `b3cf0c6f29cf8a5473fa1b8a8a446ebb41b2e5de` (#89) | Yes (`phases_impl.py:1883`); log: "CPU governor set to performance (8 CPUs)" | No |
| Offline mirror skips signature checks | `5e80c917ea8bd05c6bc4aa5a48803a0b416c6d3b` | Yes | No |
| Speed up offline ISO installs; defer boot hooks during pacstrap | `463f862b6c8daf047759cace078090cda7d92841`, `660edcb3afd109e3715eeb519ce8fec7111b5661` | Yes | No |
| Live root zstd instead of xz | `a8c3a671ead6eeaae64b2720cf771c1351209272` | Yes (the sfs is zstd-19, 1 MiB blocks: `unsquashfs -s`) | No |
| Keyboard config without a temporary boot | `17532793fdccea862b6c9a080b55b85c7a4b5321` (#93) | Yes | No |
| Deferred provisioning: install with no user; the LUKS key is re-keyed at first boot | `6b2f8a6ac7` (#98) | Yes | Not used. The Deck has no first-boot controller form |
| **Btrfs root image instead of pacstrap**: `btrfs send --compressed-data`, 43 s → 24 s in a VM, 53 → 36 s on a 9950X | PR #113, head `f684071aad08`, **open** | **No** | n/a |
| **"deterministic sub-30 install"**: zstd qcow2 root restored with `qemu-img convert -W`, a reused LUKS mapper, and Limine/UKI finalisation run concurrently with the user branch. **14.5 ± 0.6 s** unencrypted, 32.2 s encrypted interactive (8 vCPU VM) | PR #145, head `dbffaa6c6534`, **open**, stacked on #113 | **No** | n/a |
| Squashfs rootfs image + one unsquashfs (1 m 7 s → 43 s on an Intel 120U) | PR #108, **closed** 2026-09-07 | No | n/a |
| Skip the prefetch on autoinstall (it races the installer on the same stick) | PR #181, **closed** | No | n/a |

**Where our overlay adds serial time that upstream doesn't have.** `configure_deck` runs
its steps strictly in order (`deck_configure.py:293-308`) after pacstrap and before the UKI build.
Three consequences:

* **`deck_pkgs`** (6 s) and **`deck_steam_bootstrap`** (132 s) go online only after the confirm,
  although Wi-Fi is the *first* form screen. A previous overlap attempt (`deck_steam_prewarm.py`,
  removed in `ac93758`) was dropped because it hung an install past its budget, not because
  overlapping was wrong (`deck_steam_bootstrap.py:29-53`).
* **Finalizing Limine** (13.1 s, CPU) runs *after* the network-bound bootstrap, not beside it.
* **`deck_session_bake`** is not a meaningful cost (≈ 3–4 s for all 11 remaining steps together).

---

## 3. Measurements taken for this finding

All on 2026-09-23. On the Deck, only reads (see "Deck access" at the end). Everything else is in `/var/tmp/instspeed/`.

### 3.1 Payload on the stick (release ISO `pizzarchy-omarchy-4.0.4-2026-09-20`, sha256 `2fa7a020…5f814`)

```
$ bsdtar -tvf <iso> | awk '$5>10000000'
  257194324  arch/boot/x86_64/initramfs-linux-t2.img
   17641984  arch/boot/x86_64/vmlinuz-linux-t2
 5836193792  arch/x86_64/airootfs.sfs
$ unsquashfs -s airootfs.sfs  → zstd level 19, 1 MiB blocks, 102016 inodes
$ unsquashfs -lls airootfs.sfs | (sum by dir)
  4642.0 MB  var/cache/omarchy/mirror/offline   (1286 packages)
  1369.0 MB  usr/lib   558.7 MB usr/share   292.4 MB usr/bin …   7007.5 MB total
```

Mirror packages matched against `pacman -Q` on the installed Deck (1068 installed):

| | packages | compressed bytes |
|---|---:|---:|
| in the mirror | 1286 | 4639 MB |
| **installed from the mirror** | **1044** | **3133 MB** |
| **never installed on a Deck** | 242 | **1506 MB**: nvidia-utils 315, nvidia-580xx-utils 290, linux-t2 163, linux 156, lib32-nvidia-utils 118, nvidia-580xx-dkms 84, linux-firmware-marvell 82, lib32-nvidia-580xx 51, … |
| not in the mirror, installed online by `deck_pkgs` (`steam` and its dependencies, mostly lib32) | 24 | ~31 MB (the Deck's `/var/cache/pacman/pkg/*.pkg.tar.zst` is 31,262,826 B after the install) |

Installed package payload: **9498 MB** uncompressed (`pacman -Qi` sum on the Deck). Steam
client in `~/.local/share/Steam`: **2.5 GB** from a **487 MiB** `package/` cache.

### 3.2 Stick, NVMe

* **USB stick read: 82 MB/s.** The whole 6.15 GB ISO was re-read with `dd iflag=direct` in 75 s
  (docs/PROGRESS.md §5.47, the operator's Ventoy stick, measured on the dev box's port). The Deck's
  USB-C port has not been measured.
* **Deck NVMe read (btrfs, O_DIRECT): 510 MB in 0.325 s ≈ 1.57 GB/s**, over the Steam `package/` files.
  Write speed was not measured (writes are forbidden). ≥1 GB/s sequential into the SLC cache of this
  Phison `ESMP512GHV7C3-E21TS` is an [INFERENCE].

### 3.3 CPU: Deck (AMD Custom APU 0932, 4c/8t, 3.5 GHz, governor performance) vs dev box (Ryzen 7 9800X3D)

Same file on both (`/usr/lib/libLLVM.so.22.1`, 171,426,848 B, zstd 1.5.7, single thread):

| | Deck | dev | ratio |
|---|---:|---:|---:|
| `zstd -b3` compress | 345 MB/s | 885–900 MB/s | 2.6× |
| `zstd -b3` decompress | 937–943 MB/s | 1926–1935 MB/s | 2.1× |
| `zstd -b19` on a 16 MiB slice: compress | 2.43 MB/s | 6.06 MB/s | 2.5× |
| `zstd -b19` decompress (the sfs and package codec) | **637 MB/s** | 1588 MB/s | 2.5× |

### 3.4 pacman-equivalent extraction vs image restore (dev box, btrfs `compress=zstd:3` like the target)

The 1044 installed mirror packages were extracted serially, one `bsdtar -xf` per package, into one tree
(no hooks, no pacman db): **18.6 s wall** (8.7 s user, 11.2 s sys) → 9.45 GB, 291,346 entries.
On the Deck pacman needed 86 s for the same bytes: ~4.6× the dev box. That fits the 2.1–2.6× per-core
ratio plus pacman's per-transaction db, hook and scriptlet work.

Images built from that tree:

| Image | Size | Build | Restore (dev) |
|---|---:|---|---|
| squashfs, zstd-19, 1 MiB blocks (`mksquashfs … -comp zstd -Xcompression-level 19 -b 1M`) | **3,441 MB** | 4 m 9 s on 8 threads | `unsquashfs` + `sync` into btrfs zstd:3: **10.5 s** with `-p 8`, 10.5 s with `-p 4`, 10.6 s with `-p 1` (≈6.5 s user). **Not decompression-bound**: file creation and btrfs writeback dominate |
| raw btrfs, `mkfs.btrfs --rootdir … --compress zstd:3 --shrink` (unprivileged) | **7,538 MB** | 32.6 s | a sequential block write; the outer zstd layer is below |
| same + outer `zstd -19 --long=27 -T0` | **4,195 MB** | 4 m 4 s on 8 threads | `zstd -d -c --long=27 … > /dev/null`: **2.34 s** single thread for 7.54 GB out (~3.2 GB/s) |

Deck restore estimate for the squashfs route: **15–25 s** [INFERENCE: dev 10.5 s × 2.1–2.6; the
kworker compression at zstd:3 on 4 cores ≈ 1.4 GB/s → ~7 s for 9.45 GB; metadata for 291 k files].
PR #145's raw-block route restored a 3.67 GB qcow2 in 9.6 s in an 8-vCPU VM.

### 3.4a What the raw-image route costs on the Deck

Stream decompression is ~2.34 s on the dev box → **~5 s on the Deck** [INFERENCE, ×2.1 per §3.3], pipelined
with a **7.54 GB sequential write** (~5–8 s at ≥1 GB/s, the write speed itself an [INFERENCE]). No
per-file CPU is involved. **≈ 6–8 s once the 4.2 GB are in RAM.** A zstd:15 image (upstream #113's choice)
would shrink the raw write. This is why upstream's fastest PR (#145) restores blocks rather than files.

### 3.5 LUKS (for completeness; the Deck is unencrypted)

Upstream's KDF settings: `luksFormat --type luks2` via archinstall with `"iter_time": 2000`
(`iso/upstream/configs/airootfs/root/configurator:1123`). On a 64 MiB file on the dev box:

```
$ time (printf pw | cryptsetup luksFormat --type luks2 --batch-mode --iter-time 2000 luks.img -)
real 0m7.886s   (argon2id, time cost 17, memory 1 GiB, 4 threads)
$ time (printf pw | cryptsetup open --test-passphrase luks.img -)
real 0m2.057s
```

The KDF is time-calibrated, so every unlock costs about 2 s on any CPU. DHH says this is "the majority"
of his sub-10 s run. On an encrypted install the "pre-format, then `luksAddKey` or re-key" trick
(upstream's deferred-provisioning re-key, #98) would remove the format from the post-confirm window.
**On the Deck it is moot: 0 s of LUKS.**

### 3.6 Live ISO boot to the first installer screen (QEMU/KVM, own scratch VM)

`/var/tmp/instspeed/liveboot.py`: the release ISO attached as `usb-storage` behind `qemu-xhci`,
`throttling.bps-read=82000000` (so OVMF's kernel and initramfs load and every squashfs read pay the
stick's price), 4 vCPU host-passthrough, 8 GiB, OVMF, an NVMe target, user-mode net. A QMP
`screendump` is taken every 1 s and run through tesseract until the text "This installs Omarchy on your Steam Deck" appears.

| run | stick throttle | first screen |
|---|---|---:|
| 1 | 82 MB/s | 17 s |
| 2 | unthrottled | 21 s |
| 3 | 40 MB/s | 22 s |
| 4 | 82 MB/s | 18 s |
| 5 | unthrottled | 14 s |
| 6 | 82 MB/s | 16 s |
| 7 | unthrottled | 15 s |

Resolution is ±1 s, and the host was shared with 7 other agents (load avg ~6). The live boot is
**mostly CPU and fixed waits, not stick-bound**: about 2–3 s of the ~17 s is I/O.

---

## 4. Physical floors

### 4.1 Reading the payload off the stick

| Payload | Bytes | @82 MB/s (measured stick) | @200 MB/s | @400 MB/s |
|---|---:|---:|---:|---:|
| live kernel + initramfs | 275 MB | 3.4 s | 1.4 s | 0.7 s |
| whole offline mirror (what the prefetch reads today) | 4,642 MB | **56.6 s** | 23.2 s | 11.6 s |
| mirror pruned to what a Deck installs | 3,133 MB | 38.2 s | 15.7 s | 7.8 s |
| squashfs z19 root image | 3,441 MB | 42.0 s | 17.2 s | 8.6 s |
| raw btrfs zstd:3 image | 7,538 MB | 91.9 s | 37.7 s | 18.8 s |
| raw btrfs zstd:3 image + outer zstd-19 | 4,195 MB | 51.2 s | 21.0 s | 10.5 s |

Over the network (not the stick): Steam client, 496 MB. **113 s at the measured 4.4 MB/s**,
20 s at 25 MB/s, 5 s at 100 MB/s. This is the user's ISP, and no ISO design moves it.
It can only overlap it or defer it.

### 4.2 Floor for (A)

* **Nothing staged during the form (today's model):** the image alone is ≥ 42 s off this stick, plus
  the Steam download → **sub-30 is impossible**. On a ≥ 200 MB/s stick and a fast link it is borderline.
* **pacman is its own floor:** 86 s measured, CPU-bound, and the stick doesn't matter once
  prefetched. **No pacman-based design reaches sub-30 on this APU.**
* **Image bytes and Steam packages staged in RAM during the form** (the Deck has 15.2 GB of RAM; 3.4–4.2 GB of image
  plus 0.5 GB of Steam fits in the page cache or tmpfs):
  restore 15–25 s (squashfs, §3.4) or ~6–8 s (raw block, §3.4a) [INFERENCE] ∥ Steam extract ~12–17 s
  (measured at the end of `steam_bootstrap`; 17 s on the dev box "with the packages already present",
  `deck_steam_bootstrap.py:67-72`) ∥ prebuilt UKI with only the `.cmdline` patched, ~1 s vs 13.1 s
  [INFERENCE], then identity (user, password hash, hostname, timezone, Wi-Fi profile, autologin, Steam
  seed) ≈ 2–4 s + sync 1–2 s → **≈ 15–30 s**.
* **Consent at the first screen** (partition and restore begin right after "This installs Omarchy on your Steam Deck
  and erases the internal drive. Press A to begin", `omarchy-install.log:1-4`): the post-confirm
  window shrinks to identity + sync, **≈ 3–8 s** [INFERENCE]. This is the true "install while typing".

The staged designs hold only if the form lasts at least as long as the staging. That means ≥ 42 s for the image
off this stick (easy: the Wi-Fi passphrase alone is typed on a trackpad OSK) and ≥ the Steam download
(113 s on the operator's link, which is *not* guaranteed). Any shortfall lands in (A).

### 4.3 Floor for the installed cold boot

firmware 5.2 (fixed) + Limine timeout 2 (policy, §1.2) + UKI load ~1.5–2.7 + kernel/initrd ~3–4
+ userspace to gamescope ~4 + Steam client start ~6–7 (Valve's: 14.60 → 19.44 s + first frame)
≈ **22–25 s with the menu, ~20 s with `timeout: 0`** [INFERENCE on every trimmed term].

### 4.4 Floor for (B)

firmware 5.2 + live boot ≥ 17 (QEMU on a much faster CPU) + install floor ~5–30 + reboot (live shutdown
~3–5 + firmware 5.2 + loader ~4.7 + kernel 6.8 + userspace to Steam UI ~14) ≈ **60–70 s before
counting the human.** Therefore **no**. `kexec` into the installed kernel instead of a firmware reboot would take about 10 s out of the
reboot leg [INFERENCE; amdgpu re-init after kexec is a known risk class, hardware tier only].

---

## 5. Deck-specific levers (evaluated)

| Lever | Saves on (A) | Cost / risk | Constraint touched |
|---|---:|---|---|
| (a) Pre-built root image instead of pacstrap | 60–80 s (86 → 5–25) | Large. It forks upstream's install core unless #113/#145 merge. Machine-id, SSH host keys and keyring must be scrubbed; UUIDs must be fresh. **OLED-only helps**: no hardware conditionals | Licensing: same packages as today's mirror (incl. `steamdeck-dsp`, `Proprietary`, put in the mirror by operator decision 2026-08-15). **The Steam client must stay out.** Fail loudly on a checksum mismatch |
| (b) Pre-generated initramfs; patch only the UKI `.cmdline` (root PARTUUID, `resume_offset` are per-install) | ~12 s | Medium. A stale initramfs vs the kernel is a boot failure. It must be built from the same `linux-omarchy` in the ISO | Limine only (unchanged); verify with `validate_boot` |
| (c) Background work during the form | up to ~110 s (Steam) + 38–56 s (stick) | See §6. Partitioning *before* the summary confirm is an operator decision (data loss if the user backs out). **LUKS is moot on the Deck** | No keyboard: unchanged. Wi-Fi first: already so |
| (d) Steam client / session bake / `deck_pkgs` into the image at build time | Steam client: **not allowed** (§3.2 decision; `steam` is `LicenseRef-steam-subscriber-agreement`, and "every Linux distro ships only the launcher"). The launcher pkg (19 MiB) + lib32 deps could ride in the mirror, but the project chose to fetch it (`deck_pkgs.py:32-35`), saving ~6 s. Session bake and other deck steps: ~3–4 s, can be baked into an image | Low for the bake; a licence question for `steam` | No unlicensed redistribution |
| (e) Skip generic-hardware work | 1.5 GB less on the stick → ~18 s less stick time for the prefetch at 82 MB/s; ~0 s on (A) if the form is long. The `omarchy/install/hardware/*` scripts are ~1 s | Low: prune the mirror to the Deck closure. The existing NVIDIA dry-run guard already proves 0 NVIDIA packages | OLED-only (the ISO is Deck-only anyway) |
| (f) Physical floors | §4 | n/a | n/a |

---

## 6. Ranked plan (smallest change, biggest win first)

Estimates are for clock (A) on the measured link (4.4 MB/s) unless stated. "Guess" means [INFERENCE].

| # | Change | Saves | Effort | Risk | Constraint | Proven by |
|---|---|---:|---|---|---|---|
| 1 | **Run `steam_bootstrap` concurrently with the rest of the install.** Start it as a bounded background child right after `pkgs`. Run the remaining deck steps, Staging provisioning, **Finalizing Limine (13.1 s)** and Finalizing user beside it. Join before `steam_seed`, which must stay the last writer of `registry.vdf` (`deck_configure.py:123-127,159-163`). Upstream #145 does the same fan-out for Limine | **~20 s** (measured parts: 13.1 + 3.0 + 2.2 + ~3.5) | Small–medium | Low: the bootstrap already runs in its own `unshare` mount/pid namespace; mkinitcpio in the chroot does not touch `~deck` | Fail loudly: join results must be recorded per step | unit (ordering/join) → QEMU (with network) → Deck |
| 2 | **Download Steam's client packages during the form.** Start as soon as the Wi-Fi screen reports `connected` (the first screen). Fetch into live-ISO RAM, bounded, with the bootstrap's own no-progress watchdog. `steam_bootstrap` then seeds `package/` and only extracts. Valve serves the bytes to the user, so we redistribute nothing | **up to ~110 s** (132 → ~15 when the form ≥ the download). A guess tied to form length | Medium. The removed prewarm (`ac93758`) is the cautionary tale; reuse the bootstrap's bound/watchdog rather than its code | Medium: CDN stalls, the manifest format is Valve's and undocumented | No unlicensed redistribution: satisfied. Fail loudly | unit (bound, resume) → QEMU with network → Deck |
| 3 | **Deck-specific prefetch and a pruned mirror.** Drop the 242 never-installed packages (1.5 GB) from the Deck ISO. Warm in install order, not largest-first | 0 s if the form > 57 s; up to ~18 s of stick contention on short forms; ISO −1.5 GB (also −25 % Ventoy copy time) | Small (build list) | Low; the resolver must still close. The existing NVIDIA dry-run guard is the model | OLED-only | build guard → QEMU install |
| 4 | **Prebuilt initramfs, only the UKI `.cmdline` patched at install** | ~12 s (13.1 → ~1). A guess | Medium | Medium: kernel/initramfs skew. Keep `validate_boot` | Limine only | QEMU (`vm-kernel-hook-test.sh` class) → Deck boot |
| 5 | **Image-based root** (adopt upstream #113/#145 if they merge; else a Deck-only squashfs or raw image staged in RAM during the form) | ~60–80 s (86 → 5–25). A guess from §3.4 | Large | Medium–high: identity scrubbing, fresh UUIDs, image integrity check before touching the disk | Licensing as today's mirror; Steam client excluded | unit (scrub asserts) → QEMU full install → Deck RC install |
| 6 | **Consent at the first screen**: partition and restore while the user types, identity at the end | (A) → ~3–8 s | Medium on top of #5 | **Product/safety decision**: the disk is gone before the summary confirm | Operator decision required | QEMU (back-out path!) → Deck |
| 7 | Installed boot: Limine `timeout: 2` on the ESP (done today); then slim the 57 MB initramfs (unused `encrypt`, `keymap`, `consolefont` hooks on an unencrypted, keyboard-less Deck; check whether `systemd-tpm2-setup` at 2.6 s is on the path to sddm) | ~3 s (measured default vs policy) + 1–3 s (guess) → **sub-30 s to Steam UI** | Small | Low–medium: initramfs hooks are boot-chain work (Opus tier per CLAUDE.md) | Limine only | Deck cold boot with `systemd-analyze` + journal |

With #1–#4 alone and **no image work**: 252 − 20 − (up to) 110 − 12 ≈ **~110–125 s**, bounded by pacman's
86 s. **Sub-30 s for (A) needs #5, plus #2 finishing inside the form.**

---

## 7. Open questions

1. How long does a real controller-only form take? It decides how much of #2 and #5 can be
   hidden. A timestamped `deck-form.sh` screen log would answer it for free.
2. The Deck's own USB-C read throughput with this stick (the 82 MB/s was measured on the dev box's port).
3. The 2 m 53 s between "install finished" and the next firmware start on 2026-09-23: human wait,
   or a slow live-ISO shutdown flushing dirty pages? The live journal is gone. Next time, take one timestamp at
   the reboot press.
4. The installed UKI's size and the pure load time inside the 7.7 s loader (`/boot` is 0700 to `deck`).
5. The reboot warning in the dashboard ("first boot takes about a minute… BLACK") is stale since
   `steam_bootstrap` and the §5.45 cover. Not a speed item, but it tells users to expect a black minute that no longer happens.

## Deck access used (read-only)

The key-based SSH in `docs/DECK-SSH.md` failed at first: the install had changed the host key and removed
`authorized_keys`. Before Main installed a key, one session logged in with the install-default password
through an `SSH_ASKPASS` helper, using a scratch `known_hosts` (the operator's own was not modified). After that
Main's key was used. Commands run: `cat` of the `/var/log` install records, `journalctl -b`, `systemd-analyze`
(`blame`, `critical-chain`), `systemctl cat/show`, `pacman -Q/-Qi`, `lsblk`, `df`, `du`, `zstd -b`
(in-memory CPU benchmarks), and `dd iflag=direct … of=/dev/null` over the user's own Steam cache. One 16 MiB
benchmark slice was written to `/dev/shm` (RAM) and deleted. Nothing touched persistent storage, and no
service, package or reboot was involved.
