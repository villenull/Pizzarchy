# T5 — ISO build and package payload

**Model: Sonnet, Opus for the repo / `pacman.conf` plumbing.**

## Objective

A single bootable ISO that installs Arch base + Neptune kernel and firmware +
Limine + Omarchy 4.0 + Valve's gamescope session + Steam on a Steam Deck.

> **This task got substantially smaller.** Three findings shrank it:
>
> 1. **The offline constraint is retired** (`PROGRESS.md` §2.2). The install
>    may use Wi-Fi. The mirror only needs to carry what must exist *before*
>    the network is up. ISO size pressure and the package-count self-check
>    largely stop mattering.
> 2. **There is no signing problem** (`PROGRESS.md` §3.3). `omarchy-iso`
>    already ships an unsigned third-party kernel repo (`linux-t2` /
>    `[arch-mact2]`, `SigLevel = Never`) into its mirror and boots it. Adding
>    Valve's repos is a structurally identical, already-exercised edit.
> 3. **No `gamescope-session*` packages need building.** Valve's
>    `jupiter-staging/gamescope` ships the whole session (`PROGRESS.md` §4.1).
>    An earlier "T5 must build these" requirement is **withdrawn**.

## Prerequisites

- ⚠️ **`PROGRESS.md` §5.1 — does Wi-Fi work in the live ISO?** This task's
  whole shape depends on the answer and it is unverified. Settle it first.
- T1, T3, T4 far enough along to know the final package list.

## Steps

### 1. Fork the ISO builder

Fork `omacom-io/omarchy-iso` (archiso-based, MIT).

⚠️ **`OMARCHY_INSTALLER_REPO` / `OMARCHY_INSTALLER_REF` do not exist.** The
original plan's architecture was built on them and they are not real
(`PROGRESS.md` §3.1). The actual architecture, taken from upstream's own
in-tree precedents (`install/hardware/pacman.sh`, `intel/ptl-kernel.sh`):

- fork `omarchy-iso` for **build-time** changes
- ship the Deck logic as **its own pacman package** for install-time work
- plus one `pre-refresh-pacman.d/` hook — **load-bearing**, because
  `omarchy-refresh-pacman` silently overwrites `/etc/pacman.conf` wholesale
  and would delete the Valve repo entries without it

Also: an ALPM pre-transaction guard aborts a bare `pacman -Syu` unless
`OMARCHY_UPDATE_PACMAN=1` is set.

Three build-time gotchas are recorded in `PROGRESS.md` §3.10 — channel/ref
agreement, the questionless-installer guard (keep it), and the host pacman
cache the build `rm -rf`s (don't inherit that).

Two `.automated_script.sh` patches from session 2 need porting into the fork:
the completion-detection poweroff, and the debug-log capture drive. The host
side of the latter is already permanent in `vm-install-test.sh`.

### 2. The package payload

⚠️ **The live environment is the part that matters now.** With network
available at install time most packages can be pulled — but anything needed
*before* the network exists must be in the ISO itself:

- **The Deck's Wi-Fi firmware, in the live image's own filesystem.** Not just
  in the package mirror — a different and less obvious change. This is
  `PROGRESS.md` §5.1 and it is the single largest risk in this task.
- `squeekboard` and the input mapper, for the controller-driven Wi-Fi screen.

Then, for the installed system:

- `linux-neptune-*` (version per T1's pin) + headers
- `linux-firmware-neptune`, `steamdeck-dsp`
- `jupiter-staging/gamescope` (Valve's build — **not** Arch's), plus
  `mangohud` / `lib32-mangohud` for `mangoapp`
- Steam, with **`lib32-vulkan-radeon` pinned explicitly**
- Everything Omarchy 4.0 needs (already present upstream)

> ⚠️ **A bare `pacman -S steam` installs NVIDIA drivers on a Steam Deck.**
> `steam` depends on the *virtual* `lib32-vulkan-driver`; with no 32-bit AMD
> provider present, pacman picks the NVIDIA stack on its own. **Nothing
> errors.** Naming `lib32-vulkan-radeon` explicitly drops it to zero.
> See `PROGRESS.md` §3.8.

Copy the `[arch-mact2]` block shape into the `pacman-online-*.conf` files for
Valve's `jupiter-staging` / `holo-staging`. No re-sign step is needed.

### 3. Wire in the script-override loader

From T0 step 3 — the ISO should prefer installer scripts from an override
directory on the USB's data partition if present. This is what keeps the
iteration loop fast during T6. `vm-script-loader.sh` already implements the
precedence logic; its override-root search path is a parameter precisely
because the ISO's mount layout was undecided when it was written. Decide it
here.

### 4. Size check

Much less pressing than it was — the mirror shrinks under §2.2 — but still
worth a number. Confirm the total fits a practical USB target and record it
in `PROGRESS.md`.

### 5. Build reproducibly

- One command produces the ISO
- CI builds it on tag and publishes as an artifact (the workflow already has
  the job stubbed with a `TODO(T5)` placeholder that currently `exit 1`s)
- Version stamped into the image so a booted ISO can identify itself

## Done when

- [ ] `./bin/build-iso` (or equivalent) produces a bootable ISO
- [ ] ISO boots in QEMU
- [ ] ISO boots on the physical Deck and **a wireless interface enumerates
      and can associate** (§5.1 — the load-bearing one)
- [ ] Full install completes in QEMU
- [ ] All Deck packages present and installable; no `SigLevel` errors
- [ ] `lib32-vulkan-radeon` pinned; a dry run shows **zero** NVIDIA packages
- [ ] Size within target, recorded in `PROGRESS.md`
- [ ] Script-override loader works from the data partition
- [ ] CI publishes the ISO artifact

## Failure modes to watch for

- **Assuming the live ISO can do what the installed system can.** All Deck
  Wi-Fi evidence so far comes from a system already running Valve's kernel
  and firmware. The live image runs neither.
- **Silently shipping NVIDIA drivers.** See §2. Read a dry run; nothing errors.
- **Re-adding the offline requirement by habit.** It is retired. If a design
  decision only makes sense under "no network at install," re-check it.

## Escalate if

- Wi-Fi cannot be made to work in the live image — that partially reopens
  `PROGRESS.md` §2.2 and is a scope conversation
- Size exceeds a 32GB USB
