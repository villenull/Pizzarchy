# Stable 4.0.0 pin — measured 2026-08-15 (session 27, autonomous)

All facts read from inside the downloaded stable ISO and the bare clones, not inferred.

## The ISO
- File: `omarchy-4.0.0.iso` (upstream, https://iso.omarchy.org/omarchy-4.0.0.iso)
- Size: **6,273,040,384 B**
- sha256: **9224fab3720560f771969a99a499e5f7e0f8e2d6a0681d872d52f05fb5003da4** — **MATCHES the upstream v4.0.0 release-notes checksum** (this attests to what we downloaded AND that it equals what upstream published, because upstream published this hash)
- Last-Modified: 2026-08-14 16:27:32 UTC
- airootfs.sfs: SquashFS 4.0 / zstd / created **2026-08-14 16:02:19 UTC**

## The three SHAs
| Repo | Old pin (ours) | **Stable pin** | Evidence |
|---|---|---|---|
| basecamp/omarchy (RUNTIME) | `6d7826d` | **`f0020448`** | git tag v4.0.0 → f0020448ca87…; release 2026-08-14 16:57 +02:00 |
| omacom-io/omarchy-iso (UPSTREAM) | `a12bfea` | **`174dd82`** | `174dd82 "Install the published Omarchy packages in the default build"` 2026-08-14 15:59:53 UTC — 3 min before airootfs sealed (16:02:19); prior commit `d6cd2d3 "Call the renamed omarchy-apply-system finalizer"` |
| omacom-io/omarchy-pkgs (PKGS) | `ae07234a` | **`bb66b9d`** | `bb66b9d "Release omarchy 4.0.0"` 2026-08-14 15:23 UTC (rc6 = 85551de just before; master HEAD 5575275 "Update aether" is AFTER the ISO build) |

## Channel + package identity — CHANGED SHAPE (this is the big one)
| What | Beta/edge (old) | **Stable (new)** |
|---|---|---|
| Package channel (`root/omarchy_mirror` in airootfs) | `edge` | **`stable`** |
| Runtime package | `omarchy-dev 4.0.0.r1617.g6d7826d-1` | **`omarchy 4.0.0-1`** |
| Settings package | `omarchy-settings-dev` | **`omarchy-settings 4.0.0-1`** |
| Version string (os-release BUILD_ID/VERSION_ID) | `4.0.0.alpha` | **`4.0.0`** (IMAGE_VERSION 2026.08.14) |
| offline mirror omarchy pkgs | omarchy-dev + settings-dev | **omarchy-4.0.0-1, omarchy-settings-4.0.0-1, omarchy-keyring-20251027-1, omarchy-nvim-2026.8.13-1** |

**The `-dev` → release rename is the load-bearing change.** The beta packages were
`omarchy-dev`/`omarchy-settings-dev` served from the `edge` channel; 4.0.0 stable
ships `omarchy`/`omarchy-settings` from the `stable` channel. omarchy-iso commit
`174dd82` is exactly the switch ("Install the published Omarchy packages in the
default build").

## Image-measured facts re-confirmed (T9 §3 / P2.9c)
- **No Wayland compositor in the live env** — 0 `libwayland*` in airootfs (was true on beta; stronger-or-equal now). T8's self-drawn OSK assumption holds.
- **Encryption path present** in the installer orchestrator (`phases_impl.py`: luks_uuid, crypttab `omarchy_root … luks,discard`, cryptdevice cmdline). §5.12 FDE-default posture unchanged at the code level.

## What this breaks in OUR build (found during pin measurement — pre-delta-agents)
1. `iso/bin/build:239` `RUNTIME_PACKAGE=omarchy-dev` → must become `omarchy` for stable.
2. `iso/bin/build` channel guard refuses `OMARCHY_MIRROR=stable` (~line 249) → the stable build IS `stable`; the guard is now inverted.
3. `iso/RUNTIME`, `iso/UPSTREAM`, `iso/PKGS` pins → bump to the three SHAs above.
4. `iso/upstream` submodule → move a12bfea → 174dd82 (brings the apply-system finalizer rename on the builder side too).
