# Stable 4.0.4 pin — measured 2026-09-16 (autonomous)

All facts read from inside the Ventoy-stick ISO and the clones, not inferred.
Checksum was verified against upstream's published 4.0.4 hash before measuring.

## The ISO

- File: `omarchy-4.0.4.iso` (upstream, https://iso.omarchy.org/omarchy-4.0.4.iso;
  measured copy at `/run/media/villenull/Ventoy/omarchy-4.0.4.iso`)
- Size: **6,185,304,064 B** (upstream `content-length` agrees exactly;
  upstream `last-modified: Tue, 15 Sep 2026 21:35:08 GMT`; stick mtime
  2026-09-16 18:48:11 -0600 is the copy-to-Ventoy time, not the seal)
- sha256: **ddeded2758c48318d201dfdac905ecb28f570441883f0c052ea3cd5d05acf92d** —
  **MATCHES the upstream v4.0.4 published checksum**
- `arch/version`: **2026.09.15**
- `arch/x86_64/airootfs.sfs`: SquashFS 4.0 / zstd (level 19) /
  created **2026-09-15 21:11:51 UTC** (superblock `mkfs_time` epoch 1789506711;
  5,871,894,528 B inside the ISO; sha512 sidecar present)

## The three SHAs

| Repo | Old pin (ours) | **Stable pin** | Evidence |
|---|---|---|---|
| omacom/omarchy (RUNTIME) | `f0020448` (as basecamp/omarchy) | **`c668141e`** | git tag v4.0.4 → c668141e9c42b… on BOTH github.com/omacom/omarchy and github.com/basecamp/omarchy (identical SHA); commit `Merge pull request #11901 … fix/v4-0-4-complete-kernel-headers` 2026-09-14 22:34:12 -0700; release published 2026-09-15T21:39:29Z |
| omacom/omarchy-iso (UPSTREAM) | `174dd82` (as omacom-io/omarchy-iso) | **`7cfb7111`** | `7cfb7111 "Merge pull request #184 … fix/iso-kernel-headers"` 2026-09-14 22:35:33 -0700 (= 2026-09-15 05:35 UTC, ~16 h before airootfs sealed 21:11 UTC); prior commit `1daf120 "Install and validate matching kernel headers in the ISO"`; no commits between HEAD and the seal — HEAD *is* the build tip |
| omacom/omarchy-pkgs (PKGS) | `bb66b9d` (as omacom-io/omarchy-pkgs) | **`5fe23673`** | `5fe23673 "Release omarchy 4.0.4"` on master 2026-09-15 17:07:20 -0400 (= 21:07 UTC, 5 min before the omarchy pkg builddate 21:04:52 UTC… see note); twin commit `4f4c27a` with identical message/content lives on the `rc` branch (17:04 -0400); prior commit `ea69034 "Merge pull request #462 … Ghostty for x86_64"` |

Note on PKGS timing: the shipped `omarchy-4.0.4-1` package `.PKGINFO`
`builddate` is 2026-09-15 21:04:52 UTC — 3 min *before* the master release
commit's author timestamp (21:07 UTC), so the package was built from the `rc`
twin (`4f4c27a`, same tree). Either SHA pins the same content; `5fe23673`
(master) is the canonical pin.

## Repo moves (do not use the old owners)

- Runtime moved **basecamp/omarchy → omacom/omarchy** (both remotes currently
  resolve tag v4.0.4 to the identical SHA `c668141e…`; pin the `omacom` owner).
- Builder/pkgs `omacom-io/*` and `omacom/*` resolve to the same repos
  (identical HEADs: `7cfb7111…`, `52cba6cd…`); canonical owner is now
  **`omacom`** (`basecamp/omarchy-iso` and `basecamp/omarchy-pkgs` do not exist).

## Channel + package identity — STABLE SHAPE (unchanged since 4.0.0)

| What | 4.0.0 stable (old) | **4.0.4 stable (new)** |
|---|---|---|
| Package channel (`root/omarchy_mirror` in airootfs) | `stable` | **`stable`** (unchanged) |
| Runtime package | `omarchy 4.0.0-1` | **`omarchy 4.0.4-1`** (offline mirror; *not* in the live-env pkglist — live env carries only settings+keyring) |
| Settings package | `omarchy-settings 4.0.0-1` | **`omarchy-settings 4.0.4-1`** (also in live-env `pkglist.x86_64.txt`) |
| Version string (os-release BUILD_ID/VERSION_ID) | `4.0.0` (IMAGE_VERSION 2026.08.14) | **`4.0.4`** (IMAGE_VERSION **2026.09.15**) |
| offline mirror omarchy pkgs | omarchy-4.0.0-1, omarchy-settings-4.0.0-1, omarchy-keyring-20251027-1, omarchy-nvim-2026.8.13-1 | **omarchy-4.0.4-1, omarchy-settings-4.0.4-1, omarchy-keyring-20251027-1 (unchanged), omarchy-nvim-2026.8.13-1 (unchanged)** |
| Kernel | linux-t2 live / no linux-omarchy pkg | **live env still boots `linux-t2 7.2.4.arch1-3`; offline mirror carries `linux-omarchy-7.2.5-3` + `linux-omarchy-headers-7.2.5-3`** (builder commits `b507a20 "Install linux-omarchy by default except on T2 Macs"` + `1daf120` kernel-headers validation are in this build) |

**The load-bearing change vs 4.0.0: `linux-omarchy 7.2.5-3` is now the
default installed kernel** (except T2 Macs). Its `.PKGINFO` builddate is
2026-09-14 19:55:01 UTC — the exact timestamp baked into the running
workstation kernel string (`linux 7.2.5-3-omarchy #1 SMP PREEMPT_DYNAMIC Mon,
14 Sep 2026 19:55:01 +0000`), confirming the mirror pkg is what upstream
ships. Per user decision we ADOPT this kernel and retire ours.

## Image-measured facts re-confirmed (T9 §"Image-measured facts")

- **No Wayland compositor in the live env** — 0 `libwayland*` in airootfs
  (unchanged from 4.0.0). The T8 self-drawn OSK assumption holds.
- **Encryption path present** in the installer orchestrator
  (`usr/share/omarchy-iso/orchestrator/phases_impl.py`: 21 hits for
  luks_uuid/crypttab/cryptdevice). FDE-default posture unchanged at code level.

## What this breaks in OUR build

1. `iso/RUNTIME` → `omacom/omarchy@c668141e9c42` (owner rename + SHA bump).
2. `iso/UPSTREAM` → `omacom/omarchy-iso@7cfb7111a068` (owner rename + SHA bump).
3. `iso/PKGS` → `omacom/omarchy-pkgs@5fe23673…` (owner rename + SHA bump;
   full: `5fe236736607`).
4. `iso/upstream` submodule → move 174dd82 → 7cfb7111 (brings the
   linux-omarchy-default + kernel-headers-validation builder changes).
5. `iso/bin/build` `RUNTIME_PACKAGE=omarchy` should still hold (no `-dev`
   rename this time), but the kernel selection logic must follow the builder's
   new `configurator`/`phases_impl.py` linux-omarchy-default behavior instead
   of our retired custom kernel path.
6. os-release/IMAGE_VERSION expectations (`4.0.0`/`2026.08.14`) → `4.0.4`/`2026.09.15`.

## Provenance (how each value was read)

- Size/mtime: `stat` on `/run/media/villenull/Ventoy/omarchy-4.0.4.iso`.
- sha256: `sha256sum` of the stick ISO; match confirmed against upstream's
  published 4.0.4 checksum before any extraction.
- Upstream headers: `curl -sIL https://iso.omarchy.org/omarchy-4.0.4.iso`
  (`content-length: 6185304064`, `last-modified: Tue, 15 Sep 2026 21:35:08 GMT`).
- airootfs seal: `bsdtar -x -O arch/x86_64/airootfs.sfs` off a copy at
  `/home/villenull/omarchy-4.0.4.iso` (never /tmp), then superblock
  `mkfs_time` + `unsquashfs -s` (SquashFS 4.0, zstd level 19, 101847 inodes).
- Channel/os-release/pkg files: `unsquashfs -cat` against the extracted
  `airootfs-4.0.4.sfs` (unsquashfs 4.7.5 binary fetched from the
  stable-mirror, run uninstalled from `/home/villenull/v404tools`).
- Offline mirror listing: `unsquashfs -l … | grep 'offline/(omarchy|linux-omarchy)'`.
- Package builddates: `.PKGINFO` streamed out of the cached `.pkg.tar.zst`
  files (`omarchy` 1789506292 = 21:04:52 UTC; `linux-omarchy` 1789415701 =
  2026-09-14 19:55:01 UTC).
- Live-env pkglist: `bsdtar -x -O arch/pkglist.x86_64.txt` (482 lines;
  `omarchy-settings 4.0.4-1`, `omarchy-keyring 20251027-1` present,
  bare `omarchy` absent; live kernel `linux-t2 7.2.4.arch1-3`).
- RUNTIME SHA: `git ls-remote` tag `v4.0.4` on both `omacom/omarchy` and
  `basecamp/omarchy` → identical `c668141e9c42…`; commit date via shallow
  fetch; release timestamp via GitHub releases API (`published_at
  2026-09-15T21:39:29Z`, ~28 min after the airootfs seal).
- UPSTREAM SHA: full clone of `omacom/omarchy-iso`; `git log --before`
  the seal shows HEAD (`7cfb7111`, full `7cfb7111a06873d61c45d37034577d4ba08d3f4f`)
  predates it with nothing after; post-seal commits (`f97a775`, `af8b436`,
  ARM/Limine work) are newer and excluded.
- PKGS SHA: full clone of `omacom/omarchy-pkgs`; `5fe23673`
  (full `5fe236736607b1a9f6df3c3a4b364515f70eed53`) on master contains
  `4f4c27a` (origin/rc); both `Release omarchy 4.0.4`, same tree.
- Scratch left in `/home/villenull` (NOT in the repo): `omarchy-4.0.4.iso`
  copy, `airootfs-4.0.4.sfs`, `v404-{version,pkglist,grubenv}.txt`,
  `v404tools/`, `v404-{iso,pkgs,rt}.git/`. Delete or keep per operator
  preference; nothing scratch was written under the repo except this file.
