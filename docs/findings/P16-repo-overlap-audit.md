# P16 — §5.13 repo-overlap audit: the fix is one package, not repo precedence

**Session 16, 2026-08-10.** `docs/PROGRESS.md` §5.13 recorded a real defect and
a plausible fix, and told the next session to *enumerate the overlap first*.
This is that enumeration. It answers the question and **rejects the proposed
fix on the evidence.**

## Method

Fetched the actual repo databases rather than reasoning about them —
`jupiter-staging` and `holo-staging` from Valve's mirror, `core`/`extra`/`multilib`
from an Arch mirror — and compared every package name both sides ship, using
pacman's own `vercmp` rather than string ordering.

```
jupiter-staging   168      core       296
holo-staging      165      extra    14885
                           multilib   272
Valve total 333          Arch total 15453
```

⚠️ Valve's databases are **XZ**-compressed and Arch's are **gzip**. `tar tzf`
silently yields an empty listing on Valve's, which reads as "no overlap" — a
zero result here is a parsing bug, not an answer. Use auto-detecting `tar tf`.

## Result

| | count |
|---|---|
| Overlapping package names | **101** |
| Valve's version **older** than Arch's | **50** |
| Identical version | 0 |
| Valve's version newer | 51 |

### Putting Valve's repos first is unsafe — 50 downgrades

| package | Valve | Arch | Valve repo |
|---|---|---|---|
| `amd-ucode` | jupiter.20240813.1-1 | 20260622-1 | jupiter-staging |
| `casync` | 2.r227.g99559cd-4.6 | 2.r267.g0efa7ab-3 | holo-staging |
| `desync` | 1.0.3-1.1 | 1.0.4-1 | holo-staging |
| `discover` | 6.7.3-1.1 | 6.7.4-1 | holo-staging |
| `dkms` | 3.0.7-1.1 | 3.4.2-1 | holo-staging |
| `filesystem` | 2021.12.07-1.19 | 2025.10.12-1 | jupiter-staging |
| `ibus-anthy` | 1.5.14-4.5 | 1.5.18-1 | jupiter-staging |
| `kscreenlocker` | 6.7.3-1.1 | 6.7.4-1 | holo-staging |
| `kwin` | 6.7.3-1.2 | 6.7.4-3 | jupiter-staging |
| `lib32-mangohud` | 0.8.3.rc1.r24.g33c2c7dd-4 | 0.8.4-1 | jupiter-staging |
| `lib32-mesa` | 26.1.2.221562.radeonsi_26.1.2-2 | 1:26.1.6-1 | jupiter-staging |
| `lib32-opencl-mesa` | 23.3.0.179670.radeonsi_3.6.1-2 | 1:26.1.6-1 | jupiter-staging |
| `lib32-vulkan-intel` | 26.1.2.221562.radeonsi_26.1.2-2 | 1:26.1.6-1 | jupiter-staging |
| `lib32-vulkan-mesa-implicit-layers` | 26.1.2.221562.radeonsi_26.1.2-2 | 1:26.1.6-1 | jupiter-staging |
| `lib32-vulkan-mesa-layers` | 26.1.2.221562.radeonsi_26.1.2-2 | 1:26.1.6-1 | jupiter-staging |
| `lib32-vulkan-nouveau` | 26.1.2.221562.radeonsi_26.1.2-2 | 1:26.1.6-1 | jupiter-staging |
| `lib32-vulkan-radeon` | 26.2.0_devel.222118.steamos_26.05.14-2 | 1:26.1.6-1 | jupiter-staging |
| `lib32-vulkan-swrast` | 26.1.2.221562.radeonsi_26.1.2-2 | 1:26.1.6-1 | jupiter-staging |
| `lib32-vulkan-virtio` | 26.1.2.221562.radeonsi_26.1.2-2 | 1:26.1.6-1 | jupiter-staging |
| `libwireplumber` | 0.5.14-1.8 | 0.5.15-1 | jupiter-staging |
| `linux-firmware-liquidio` | jupiter.20240813.1-1 | 20260622-1 | jupiter-staging |
| `linux-firmware-marvell` | jupiter.20240813.1-1 | 20260622-1 | jupiter-staging |
| `linux-firmware-mellanox` | jupiter.20240813.1-1 | 20260622-1 | jupiter-staging |
| `linux-firmware-nfp` | jupiter.20240813.1-1 | 20260622-1 | jupiter-staging |
| `linux-firmware-qcom` | jupiter.20240813.1-1 | 20260622-1 | jupiter-staging |
| `linux-firmware-qlogic` | jupiter.20240813.1-1 | 20260622-1 | jupiter-staging |
| `linux-lts` | 5.15.74-1.1 | 6.18.43-1 | holo-staging |
| `linux-lts-headers` | 5.15.74-1.1 | 6.18.43-1 | holo-staging |
| `mangohud` | 0.8.3.rc1.r24.g33c2c7dd-4 | 0.8.4-1 | jupiter-staging |
| `mesa` | 26.1.2.221562.radeonsi_26.1.2-2 | 1:26.1.6-1 | jupiter-staging |
| `opencl-mesa` | 23.3.0.179670.radeonsi_3.6.1-2 | 1:26.1.6-1 | jupiter-staging |
| `orca` | 48.9-1.1 | 50.2-1 | holo-staging |
| `plasma-pa` | 6.7.3-1.1 | 6.7.4-1 | holo-staging |
| `plasma-workspace` | 6.7.3-2.1 | 6.7.4-1 | holo-staging |
| `plasma-x11-session` | 6.7.3-2.1 | 6.7.4-1 | holo-staging |
| `plymouth` | 22.02.122-7.6 | 26.134.222-2 | holo-staging |
| `podman` | 6.0.2-2.1 | 6.0.2-3 | holo-staging |
| `powerdevil` | 6.7.3-2.1 | 6.7.4-1 | jupiter-staging |
| `pyzy` | 1.1-2.6 | 1.1-3 | jupiter-staging |
| `upower` | 1.90.10-1.2 | 1.91.3-1 | jupiter-staging |
| `vulkan-intel` | 26.1.2.221562.radeonsi_26.1.2-2 | 1:26.1.6-1 | jupiter-staging |
| `vulkan-mesa-implicit-layers` | 26.1.2.221562.radeonsi_26.1.2-2 | 1:26.1.6-1 | jupiter-staging |
| `vulkan-mesa-layers` | 26.1.2.221562.radeonsi_26.1.2-2 | 1:26.1.6-1 | jupiter-staging |
| `vulkan-nouveau` | 26.1.2.221562.radeonsi_26.1.2-2 | 1:26.1.6-1 | jupiter-staging |
| `vulkan-radeon` | 26.2.0_devel.222118.steamos_26.05.14-2 | 1:26.1.6-1 | jupiter-staging |
| `vulkan-swrast` | 26.1.2.221562.radeonsi_26.1.2-2 | 1:26.1.6-1 | jupiter-staging |
| `vulkan-virtio` | 26.1.2.221562.radeonsi_26.1.2-2 | 1:26.1.6-1 | jupiter-staging |
| `wireplumber` | 0.5.14-1.8 | 0.5.15-1 | jupiter-staging |
| `wireplumber-docs` | 0.5.14-1.8 | 0.5.15-1 | jupiter-staging |
| `xdg-desktop-portal-kde` | 6.7.3-1.2 | 6.7.4-2 | holo-staging |

The severe ones are not marginal: **`filesystem` 2021.12.07 → 2025.10.12**,
**`linux-lts` 5.15.74 → 6.18.43**, **`plymouth` 22.02 → 26.134**, and the entire
`mesa` / `vulkan-*` / `lib32-vulkan-*` stack. §5.13 named `mesa`,
`vulkan-radeon` and `lib32-vulkan-radeon` as the suspects; all three confirm,
along with 47 others.

**Decisive counter-evidence:** the test Deck currently runs **Arch's**
`mesa 1:26.1.6-1` and `vulkan-radeon 1:26.1.6-1`, and Gaming Mode works. Valve's
mesa is not merely riskier — it is not needed.

### The 51 "Valve newer" are almost all rebuilds, not different software

`systemd 261.2-1.1` vs `261.2-1`. `bluez 5.87-2.1` vs `5.87-2`.
`pipewire 1:1.6.8-1.2` vs `1:1.6.8-1`. Same upstream version, bumped pkgrel —
Valve's patched builds. Only two differ meaningfully:

- **`gamescope` 3.16.25-3 (Valve) vs 3.16.25-1 (Arch)** — the one that matters.
  Valve's build ships the whole SteamOS session (`gamescope-wayland.desktop`,
  `start-gamescope-session`, the unit graph). Arch's is the bare compositor.
- `scx-scheds 1.1.2.linux.steamos-2` vs `1.1.2-1` — a SteamOS variant, unused here.

⚠️ **Note the trap:** Valve's gamescope is *newer* and pacman still picks
Arch's, because `pacman -S <name>` resolves by **repo order, not version**. Do
not conclude from "Valve's is newer" that the bug cannot bite.

## Conclusion — the blast radius is ONE package

Everything `src/omarchy-deck-kernel.sh` installs today is **Valve-only**, so repo
order never affected it:

| package | in Valve | in Arch | |
|---|---|---|---|
| `linux-neptune-611` | ✅ | — | unambiguous |
| `linux-neptune-611-headers` | ✅ | — | unambiguous |
| `linux-firmware-neptune` | ✅ | — | unambiguous |
| `steamdeck-dsp` | ✅ | — | unambiguous |

So the defect's entire practical surface is **`gamescope`**, which this project
does not install itself — it is a prerequisite `deck-session.sh` checks for.

**Recommendation, adopted: do NOT reorder repos. Qualify the one package.**

```bash
pacman -S jupiter-staging/gamescope     # not: pacman -S gamescope
```

Explicit `repo/name` qualification is surgical, needs no precedence change, and
cannot cause a downgrade elsewhere.

### Two follow-on findings

- **`mangohud`: prefer Arch's.** Valve's `0.8.3.rc1…-4` is *older* than Arch's
  `0.8.4-1`, and Arch's already ships `/usr/bin/mangoapp` — verified on the Deck.
  `deck-session.sh`'s mangoapp precondition is satisfied by Arch's package;
  nothing needs Valve's.
- **The existing precondition already catches the wrong build.**
  `stage_preconditions` requires the `gamescope-wayland.desktop` session file
  *and* `start-gamescope-session` on `PATH` — neither of which Arch's build
  ships. That is a behavioural check rather than a version check, which is the
  right shape. Only its guidance text needed correcting.

## Reproducing

```bash
for r in jupiter-staging holo-staging; do
  curl -sSfL "https://steamdeck-packages.steamos.cloud/archlinux-mirror/$r/os/x86_64/$r.db" -o "$r.db"
done
for r in core extra multilib; do
  curl -sSfL "https://geo.mirror.pkgbuild.com/$r/os/x86_64/$r.db" -o "$r.db"
done
# tar tf, NOT tar tzf -- Valve's are XZ, Arch's are gzip
tar tf "$r.db" | grep '/$' | sed 's:/$::'
# then compare with `vercmp`, not string ordering
```

Databases fetched 2026-08-10T21:17:07Z.
