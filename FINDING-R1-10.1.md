# FINDING R1 §10.1 — Can Quattro's offline mirror carry Deck packages?

**Result: CONFIRMED — and stronger than hypothesized. The signing caveat does
not exist.** No re-sign step is needed, and the exact pattern we need (an
out-of-tree kernel from an unsigned third-party repo, consumed with
`SigLevel = Never`, baked into the offline mirror, *and booted by the live
ISO itself*) is already shipping in `omarchy-iso` today as `linux-t2` /
`[arch-mact2]`.

## Hypothesis (PLAN.md §10.1)

> Yes, with a signing caveat. `omarchy-iso` already assembles a pacman repo
> from a package list at build time, so adding `linux-neptune-611`,
> `linux-firmware-neptune`, `steamdeck-dsp`, and `gamescope-session-*` is
> likely a matter of extending that list plus adding Valve's
> `jupiter-staging`/`holo-staging` repos to the build-time `pacman.conf`.
> The likely snag is package signing: … the build will need either a local
> re-sign step or a matching SigLevel exception carried into the ISO's
> `pacman.conf`.

## What I did

Cloned `omacom-io/omarchy-iso` (branch `quattro`, HEAD `6004e80`) and
`omacom-io/omarchy-pkgs` to `/tmp/pizzarchy-r1-scratch/`, outside this
worktree. Read `builder/` end to end, all four `configs/pacman-*.conf`,
`configs/profiledef.sh`, and the orchestrator phases that consume the mirror
at install time. Grepped `SigLevel` repo-wide. No guessing — every claim
below is a file/line citation.

Paths below are relative to the `omarchy-iso` checkout unless noted.

## How the offline mirror is actually assembled

Single script: `builder/build-iso.sh`, run inside an `archlinux:latest`
container by `bin/omarchy-iso-make` (`bin/omarchy-iso-make:117-152`).

1. **Mirror directory** — `builder/build-iso.sh:52`
   `offline_mirror_dir=/var/cache/airootfs/var/cache/omarchy/mirror/offline`,
   i.e. it is literally a directory inside the airootfs that mkarchiso packs.
2. **Package list is assembled from four sources** — `build-iso.sh:163-174`:
   - `packages.x86_64` (releng's list + `arch_packages` appended at
     `build-iso.sh:120-121`) — packages for the **live ISO env**;
   - `omarchy-base.packages` + `omarchy-other.packages`, extracted from the
     downloaded `omarchy-dev` package itself (`build-iso.sh:143-157`) or read
     from `/omarchy-source/install/` under `--local-source`
     (`build-iso.sh:140-141`);
   - `builder/archinstall.packages` (15 lines: `base`, `linux`, `limine`,
     `linux-firmware`, `amd-ucode`, …);
   - the three `omarchy*` package names (`build-iso.sh:172`).
3. **Download** — `build-iso.sh:190-202`: one
   `pacman --config /configs/pacman-online-${OMARCHY_MIRROR}.conf -Syw
   "${all_packages[@]}" --cachedir "$offline_mirror_dir/"`. So **the
   build-time `pacman-online-*.conf` is the only thing that decides which
   repos packages may come from.**
4. **Prune** — `build-iso.sh:208-243` re-resolves the exact filenames with
   `-S --print --print-format '%f'` and pipes them to
   `builder/prune-offline-mirror.sh`, which deletes anything not selected.
5. **Index** — `build-iso.sh:247-248`:
   ```
   rm -f "$offline_mirror_dir"/offline.db* "$offline_mirror_dir"/offline.files*
   repo-add "$offline_mirror_dir/offline.db.tar.gz" "$offline_mirror_dir/"*.pkg.tar.zst
   ```
6. **The ISO's `pacman.conf` is `configs/pacman-offline.conf`** —
   `configs/profiledef.sh:13` (`pacman_conf="pacman-offline.conf"`) and
   `build-iso.sh:319-320` copies it to `airootfs/etc/pacman.conf`. At install
   time it is copied again into the target
   (`orchestrator/phases_impl.py:1016`) and the mirror is bind-mounted into
   `/mnt` (`phases_impl.py:640-658`, `1019`) so `pacstrap` and the chroot
   `omarchy-setup-system` run entirely offline.

There is **no separate "package list" file to edit** — it is the union above.
Two of those inputs are ours to control cheaply.

## The signing question — settled, with evidence

**Valve's `SigLevel = Never` can be carried straight through. Nothing breaks
and nothing needs re-signing.** Three independent pieces of evidence:

### 1. The build-time config already contains an unsigned third-party repo

`configs/pacman-online-stable.conf:32-35` (identical in `-rc.conf` and
`-edge.conf`, same line numbers):

```
[arch-mact2]
Server = https://mirror.funami.tech/arch-mact2/os/x86_64
Server = https://github.com/NoaHimesaka1873/arch-mact2-mirror/releases/download/release
SigLevel = Never
```

This is a community GitHub-releases repo for Apple T2 Macs, consumed with
`SigLevel = Never`, and `pacman -Syw` at `build-iso.sh:191` pulls from it into
the offline mirror like any other repo. Adding `[jupiter-staging]` and
`[holo-staging]` to these three files is a **structurally identical, already-
exercised change** — not a new capability.

### 2. The ISO's own repo is `SigLevel = Never` by deliberate design

`configs/pacman-offline.conf:16-25`:

```
# No signature checks for the offline mirror: it ships inside the ISO, whose
# integrity is already covered by the airootfs sha512 and the ISO signature.
# "Optional TrustAll" is NOT a bypass — Optional verifies whenever a .sig file
# exists (they all do), and pacstrap verifies against the LIVE keyring (pacman
# -r relocates the root but not GpgDir). That made installs depend on archiso's
# slow boot-time pacman-init.service having finished, which stalled or failed
# pacstrap on real hardware with "required key missing from keyring".
[offline]
SigLevel = Never
Server = file:///var/cache/omarchy/mirror/offline/
```

Restated at `orchestrator/phases_impl.py:163-172` as the reason the installer
deliberately does **not** wait on the live keyring. So the moment a package
lands in the offline mirror, its provenance signature is irrelevant — the
mirror is a single `SigLevel = Never` repo whose integrity is inherited from
the ISO's own signature (`bin/omarchy-iso-sign`). **A re-sign step would be
pointless work: nothing would ever verify it.**

### 3. The build already puts *deliberately unsigned* packages in the mirror

Under `--local-source`, `builder/build-omarchy-packages.sh:64-69` builds with
`makepkg --noconfirm --skippgpcheck --skipchecksums --nodeps -f`, and lines
73-81 explicitly delete any stale signature next to the new artifact:

```
# A cached signature belongs to the previously downloaded or locally built
# package. Keeping it beside a newly built package makes pacman reject the
# otherwise valid local-source build.
rm -f "$destination" "$destination.sig"
```

`prune-offline-mirror.sh:60-67` then garbage-collects orphan `.sig` files, and
`repo-add` at `build-iso.sh:248` is called with **no `--sign` and no
`--verify`**. Unsigned packages in the offline mirror are a supported,
routine state.

**Verdict on the caveat: KILLED.** PLAN.md's "either a local re-sign step or a
matching SigLevel exception" is a false dichotomy — the exception is already
the norm at both ends of the pipeline.

## Can the specific Deck packages be added? Yes — and there is a kernel precedent

`linux-t2` is the exact analogue of `linux-neptune-611`:

- It is **not** in Arch's repos; it comes only from unsigned `[arch-mact2]`.
- It is appended to the live-ISO package set at `build-iso.sh:120`:
  `arch_packages=(linux-t2 git gum jq openssl plymouth … )`, which feeds
  `all_packages` at `build-iso.sh:167`, so it lands in the offline mirror.
- **The live ISO boots it**: `configs/efiboot/loader/entries/01-archiso-x86_64-linux.conf:3-4`,
  `configs/syslinux/archiso_sys-linux.cfg:7-8`, `configs/grub/loopback.cfg:33`
  all name `vmlinuz-linux-t2` / `initramfs-linux-t2.img`, with
  `configs/airootfs/etc/mkinitcpio.d/linux-t2.preset` as the preset.
- `build-iso.sh:123-134` even goes out of its way to `sed` stock `linux` and
  `broadcom-wl` *out* of `packages.x86_64` because the ISO boots T2 and the
  second kernel was wasting ~147 MB.

So a Deck ISO booting `linux-neptune-611` in the **live environment** is not a
research question — it's the same four-file edit upstream already made.

Where each package class goes:

| Package | Add to | Mechanism |
|---|---|---|
| `linux-neptune-611` (live ISO boot kernel) | `build-iso.sh:120` `arch_packages` + boot configs + a `.preset` | exactly the `linux-t2` path |
| `linux-neptune-611`, `linux-firmware-neptune`, `steamdeck-dsp`, `gamescope-session-*`, `steam` (target system) | `builder/archinstall.packages`, or better — a Deck-specific `omarchy-*.packages` list | pulled into the mirror by `build-iso.sh:169` |
| Valve repos | `configs/pacman-online-{stable,rc,edge}.conf` | copy the `[arch-mact2]` block shape verbatim, `SigLevel = Never` |

**Note the asymmetry the mirror creates:** `builder/archinstall.packages:8`
installs stock `linux` into the target. Upstream's own answer for a machine
that needs a different kernel is *not* to change that list — it is to swap the
kernel during hardware setup. See `basecamp/omarchy` at
`install/hardware/intel/ptl-kernel.sh` (whole file, 25 lines): detect hardware,
`omarchy-pkg-add linux-ptl linux-ptl-headers`, `pacman -Rdd linux
linux-headers`, then drop
`/etc/limine-entry-tool.d/zz-dell-xps-panther-lake.conf` with
`BOOT_ORDER="linux-ptl*, *fallback, Snapshots"`. That is a working, upstream,
Limine-native template for T1's entire kernel-swap-and-boot-order job — worth
reading before writing any of it (`FINDING-R1-10.2.md` covers where our copy
of that script would live).

## Risks found that PLAN.md §10.1 did not anticipate

1. **ISO size, and it is a hard gate.** The offline mirror is stored
   **uncompressed** inside the squashfs on purpose —
   `configs/profiledef.sh:25-30`:
   `-action 'uncompressed@subpathname(var/cache/omarchy/mirror/offline)'`
   (packages are already zstd; double-compressing costs install-time CPU).
   So every byte of `linux-firmware-neptune`, `steam`, and the gamescope stack
   adds ~1:1 to the ISO. Budget this in T5 before committing to a package set;
   consider whether `linux-firmware` (stock) can be dropped in favour of the
   neptune variant rather than shipping both.
2. **The mirror's package-count self-check will fail loudly if a Deck package
   is unresolvable** — `build-iso.sh:265-308` resolves the whole target set
   against the just-built offline repo and `exit 1`s with an explicit "pacstrap
   would fail the same way at install time" message. This is a *good* thing:
   it means a missing Valve package is a build failure, not a silent
   install-time break. It also warns if the resolved count leaves the 600–2000
   band (`build-iso.sh:309-313`) — a Deck build will push toward the top of
   that range and may need the bound widened.
3. **The target's final `/etc/pacman.conf` is not omarchy-iso's.** The
   installer copies the offline conf in (`phases_impl.py:1016`), but
   `basecamp/omarchy`'s `omarchy-refresh-pacman:19-20` later overwrites it
   wholesale from `$OMARCHY_PATH/default/pacman/pacman-$channel.conf`. Getting
   Valve's repos into the *installed* system, durably, is a different problem
   from getting them into the build — see `FINDING-R1-10.2.md`, which found
   upstream's sanctioned answer (`install/hardware/pacman.sh` +
   `pre-refresh-pacman.d/` hook).

## What this changes about T5's plan

- **Drop the "signing" work item entirely.** No local re-sign step, no keyring
  work, no `omarchy-keyring` analogue for Valve. Copy the `[arch-mact2]` block
  shape with `SigLevel = Never` into the three `pacman-online-*.conf` files and
  that is the whole of it. This removes what PLAN.md called the likely snag.
- **T5's real work is a small, well-shaped fork of `omarchy-iso`**, roughly:
  three `pacman-online-*.conf` files (add Valve repos), `build-iso.sh:120`
  (`arch_packages`), a Deck package list, three boot configs + one mkinitcpio
  preset (if the live ISO boots the neptune kernel), and `profiledef.sh` for
  branding. No architectural invention required.
- **Open the ISO-size question now, not at T5.** It is the only remaining
  blocker on this line and it is measurable before any code is written
  (`pacman -Sw --print-format '%s'` against Valve's repos).
- **Combine with `--local-source`**: `bin/omarchy-iso-make --local-source
  <omarchy-checkout> <pkgs-checkout>` (`bin/omarchy-iso-make:27-35`,
  `build-iso.sh:101-104`) mounts local checkouts and builds `omarchy*` from
  them into the mirror. That is the intended path for iterating on Deck-specific
  `omarchy` package content without publishing to a repo server first.
- **Live-ISO kernel decision needs an explicit call.** Does the *installer
  environment* need `linux-neptune-611` (for Deck trackpads/gyro/Wi-Fi during
  the controller-only install — a real §6.1a concern), or only the installed
  target? If the former, budget the `linux-t2`-shaped boot-config work; if the
  latter, T5 shrinks considerably. This is a T2/T4 input, not a T5 one.

## Reproduction

```
git clone --depth 50 https://github.com/omacom-io/omarchy-iso.git   # HEAD 6004e80, branch quattro
git clone --depth 30 https://github.com/omacom-io/omarchy-pkgs.git
```
Scratch checkouts used for this finding live at `/tmp/pizzarchy-r1-scratch/`
(outside the repo, disposable).
