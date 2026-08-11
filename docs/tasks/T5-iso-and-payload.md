# T5 — ISO build and package payload

**Model: Sonnet, Opus for the repo / `pacman.conf` plumbing.**

> ⚠️ **Fork the *pinned* `omarchy-iso`, not its HEAD** (added 2026-08-11,
> `docs/PROGRESS.md` §5.22). Phase 2.9 records one SHA for the upstream builder;
> this fork inherits it, and P2.9c rebuilds against it. Upstream moves several
> times a day and has already **renamed the `omarchy-apply-system` finalizer**
> its own installer calls — a fork taken at the wrong point calls a binary that
> no longer exists.
>
> 🔴 **And the git pin is only half of it — measured 2026-08-11 (session 19).**
> The `edge` channel has **already moved past our runtime pin**: it serves
> `omarchy-dev-4.0.0.r1652.g1c9dfc5-1` today, 35 commits past `6d7826d` and 18
> commits past the rename. `builder/build-iso.sh` downloads the runtime package
> from that channel at build time, so **forking at `a12bfea` and building today
> yields an installer that calls `omarchy-setup-system` against a runtime that
> ships only `omarchy-apply-system`** — and it dies at the fifth install phase,
> after partitioning and pacstrap. The git ref and the package channel are two
> independent pins and only one is expressible in git.
>
> ➡️ **Strategy, fork point, the seams, the six bake-ins with their checks, and
> a sliced work programme: `docs/tasks/T5-fork-plan.md`.** Read that before
> starting any step below.

## Objective

A single bootable ISO that installs Arch base + Neptune kernel and firmware +
Limine + Omarchy 4.0 + Valve's gamescope session + Steam on a Steam Deck.

> **This task got substantially smaller.** Three findings shrank it:
>
> 1. **The offline constraint is retired** (`docs/PROGRESS.md` §2.2). The install
>    may use Wi-Fi. The mirror only needs to carry what must exist *before*
>    the network is up. ISO size pressure and the package-count self-check
>    largely stop mattering.
> 2. **There is no signing problem** (`docs/PROGRESS.md` §3.3). `omarchy-iso`
>    already ships an unsigned third-party kernel repo (`linux-t2` /
>    `[arch-mact2]`, `SigLevel = Never`) into its mirror and boots it. Adding
>    Valve's repos is a structurally identical, already-exercised edit.
> 3. **No `gamescope-session*` packages need building.** Valve's
>    `jupiter-staging/gamescope` ships the whole session (`docs/PROGRESS.md` §4.1).
>    An earlier "T5 must build these" requirement is **withdrawn**.

## Prerequisites

- ⚠️ **`docs/PROGRESS.md` §5.1 — does Wi-Fi work in the live ISO?** This task's
  whole shape depends on the answer and it is unverified. Settle it first.
- T1, T3, T4 far enough along to know the final package list.

## Steps

### 1. Fork the ISO builder

Fork `omacom-io/omarchy-iso` (archiso-based, MIT).

⚠️ **`OMARCHY_INSTALLER_REPO` / `OMARCHY_INSTALLER_REF` do not exist.** The
original plan's architecture was built on them and they are not real
(`docs/PROGRESS.md` §3.1). The actual architecture, taken from upstream's own
in-tree precedents (`install/hardware/pacman.sh`, `intel/ptl-kernel.sh`):

- fork `omarchy-iso` for **build-time** changes
- ship the Deck logic as **its own pacman package** for install-time work
- plus one `pre-refresh-pacman.d/` hook — **load-bearing**, because
  `omarchy-refresh-pacman` silently overwrites `/etc/pacman.conf` wholesale
  and would delete the Valve repo entries without it

Also: an ALPM pre-transaction guard aborts a bare `pacman -Syu` unless
`OMARCHY_UPDATE_PACMAN=1` is set.

Three build-time gotchas are recorded in `docs/PROGRESS.md` §3.10 — channel/ref
agreement, the questionless-installer guard (keep it), and the host pacman
cache the build `rm -rf`s (don't inherit that).

Two `.automated_script.sh` patches from session 2 need porting into the fork:
the completion-detection poweroff, and the debug-log capture drive. The host
side of the latter is already permanent in `test/vm/vm-install-test.sh`.

### 2. The package payload

⚠️ **The live environment is the part that matters now.** With network
available at install time most packages can be pulled — but anything needed
*before* the network exists must be in the ISO itself:

- **The Deck's Wi-Fi firmware, in the live image's own filesystem.** Not just
  in the package mirror — a different and less obvious change. This is
  `docs/PROGRESS.md` §5.1 and it is the single largest risk in this task.
- ~~`squeekboard` and the input mapper, for the controller-driven Wi-Fi
  screen.~~ **SUPERSEDED 2026-08-11.** squeekboard **cannot run in the live
  ISO** — that environment has no Wayland compositor, and re-measured inside
  the beta 2 image, **no `libwayland-*.so` at all**
  (`docs/findings/T2-gamepad-spike.md` §4, `docs/findings/T9-iso-comparison.md`
  §5a). The live-ISO keyboard is **ours**, and it is already built and
  hardware-proven (`docs/tasks/T8-onscreen-keyboard.md`):

  | Ships in the live image | What it is |
  |---|---|
  | `src/deck_osk_tty.py` | T8's OSK drawn on the **bare console** — the installer's keyboard |
  | `src/deck-input-mapper.py` | pad → keys/pointer, and the chord that raises the OSK |
  | `src/deck_osk_layout.py` | the layout core both renderers share |
  | 🔴 **`python-evdev`** | **absent from the offline mirror today, and unfetchable** — the live `pacman.conf` declares only `[offline]` (R-9), so it cannot be pulled at install time (R-10). **Bake it into the payload, or rewrite the mapper against raw `struct`-parsed evdev**, which R-8's `evmon.py` proved practical |

  *(§2.6 is the decision this follows: **our OSK in the installer, squeekboard
  on the desktop.** It was revised twice on 2026-08-10 — an earlier version of
  this file had the two swapped.)*

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
> See `docs/PROGRESS.md` §3.8.

Copy the `[arch-mact2]` block shape into the `pacman-online-*.conf` files for
Valve's `jupiter-staging` / `holo-staging`. No re-sign step is needed.

### 3. Wire in the script-override loader

From T0 step 3 — the ISO should prefer installer scripts from an override
directory on the USB's data partition if present. This is what keeps the
iteration loop fast during T6. `test/lib/vm-script-loader.sh` already implements the
precedence logic; its override-root search path is a parameter precisely
because the ISO's mount layout was undecided when it was written. Decide it
here.

### 4. Size check

Much less pressing than it was — the mirror shrinks under §2.2 — but still
worth a number. Confirm the total fits a practical USB target and record it
in `docs/PROGRESS.md`.

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
- [ ] Size within target, recorded in `docs/PROGRESS.md`
- [ ] Script-override loader works from the data partition
- [ ] CI publishes the ISO artifact

## Failure modes to watch for

- **Assuming the live ISO can do what the installed system can.** All Deck
  Wi-Fi evidence so far comes from a system already running Valve's kernel
  and firmware. The live image runs neither.
  ⚠️ **This file committed that exact error against itself** — three passages
  specified squeekboard, and its two GSettings, for an environment with no
  compositor and no `libwayland`. Corrected 2026-08-11 and left visible in §2
  and §4. A warning in a "failure modes" list did not stop the file making the
  mistake elsewhere in the same document.
- **Silently shipping NVIDIA drivers.** See §2. Read a dry run; nothing errors.
- **Re-adding the offline requirement by habit.** It is retired. If a design
  decision only makes sense under "no network at install," re-check it.

## Escalate if

- Wi-Fi cannot be made to work in the live image — that partially reopens
  `docs/PROGRESS.md` §2.2 and is a scope conversation
- Size exceeds a 32GB USB

## Constraint added by session 16 (PROGRESS.md 5.17)

The build MUST fail if the payload contains any sudoers drop-in granting
blanket passwordless root. `/etc/sudoers.d/99-deck-testing` exists on the dev
Deck deliberately -- the iterate-in-place loop needs it, and no narrower grant
is possible because the install stages legitimately write to `/etc/sudoers.d/`
itself. It must never reach the ISO.

`src/deck-session.sh stage-audit-privileges` implements the predicate and can
be reused: it fails on blanket AND passwordless, while treating the ordinary
password-protected `deck ALL=(ALL) ALL` as normal.

## Constraint added by session 16 (PROGRESS.md 5.11)

**Bake BOTH rotation fixes into the image.** Neither survives a fresh install:

| Surface | Setting | Why it needs baking |
|---|---|---|
| Omarchy desktop | `transform 3`, `scale 1.25` in `monitors.lua` | per-USER config; a new user comes up sideways |
| Limine boot menu | `interface_rotation: 270` in `limine.conf` | `omarchy refresh limine` **moves the file aside and copies the template over it**, destroying a hand edit |

`interface_rotation` needs Limine >= v10 (the Deck has 12.5.2) and rotates the
menu only, not the booted OS. ⚠️ `270` matches the desktop's transform but has
NOT been seen on a screen -- 5.11's history is a recorded transform value that
turned out upside down, so verify before shipping it.

The TTY is a third surface (`fbcon=rotate:1` on the kernel cmdline) and is still
awaiting operator approval as a boot-chain change.

## The other four constraints, gathered here so this file is self-contained

T5 carries **six** constraints. Two are written above; these are the other four,
which until now lived only in `docs/PROGRESS.md` and the ROADMAP row.

### 1. Offline-only pacman during install (PROGRESS.md 3.10, 2.2)

The build needs the Deck package set reachable without a network at install
time *or* a deliberate decision that the install may use Wi-Fi. **2.2 retired the
fully-offline constraint**, so network-at-install is now permitted -- which is
also what makes "fetch, not bundle" viable below. Do not re-derive 2.2's
reversal; it was a scope decision, not an oversight.

### 2. The upstream installer defaults to FULL-DISK ENCRYPTION (PROGRESS.md 5.12)

Inherited unchanged, our fork ships a device that **stops at a passphrase prompt
with no keyboard** -- unbootable for its intended user, and a direct violation of
`CLAUDE.md`'s controller-only rule. **Default it OFF.** TPM2 auto-unlock is a
follow-on, not a release blocker.

Upstream's installer is driveable from a config file and accepts
`--authorized-keys-file` / `--tailscale-authkey-file`, which is a better
integration point than post-install scripting and makes automated QEMU install
testing tractable.

### 3. Repo precedence -- qualify the package, do NOT reorder (PROGRESS.md 5.13)

`pacman -S <name>` resolves by **repo order, not version**, and Arch's repos come
first by design. Session 16 measured the alternative and rejected it: 101 package
names overlap and **Valve's is older in 50**, including `filesystem`
2021.12.07 (vs 2025.10.12), `linux-lts` 5.15.74 (vs 6.18.43) and the whole
mesa/vulkan stack. The Deck runs **Arch's** mesa and Gaming Mode works.

The entire practical surface is one package:

```bash
pacman -S jupiter-staging/gamescope     # NOT: pacman -S gamescope
```

Arch's `gamescope` is the bare compositor; Valve's ships the SteamOS session.
Both are `3.16.25`, so no version check can tell them apart -- test for the
session *file*. Full data: `docs/findings/P16-repo-overlap-audit.md`.

### 4. Session settings that are load-bearing and live in ONE user's session

Added session 17, **scoped by §2.6's decision** — which splits these across two
different images rather than one.

> ⛔ **CORRECTED 2026-08-11.** This section used to open *"In the LIVE ISO (the
> installer), squeekboard is the keyboard"* and presented the two GSettings
> below as a **live-ISO** requirement. **Both halves were wrong**, and they
> survived here from the *first* version of §2.6, which was revised twice on
> 2026-08-10:
>
> - **squeekboard cannot run in the live ISO at all** — no Wayland compositor,
>   and no `libwayland-*.so` in the image (`docs/findings/T2-gamepad-spike.md`
>   §4, `docs/findings/T9-iso-comparison.md` §5a). The installer's keyboard is
>   **T8's own**, drawn on the bare console — see §2's payload table.
> - **The two GSettings therefore belong to the INSTALLED system only**, where
>   squeekboard actually runs. `docs/tasks/T5-fork-plan.md` §5.3 already scopes
>   them that way; this file now agrees with it.
>
> Left visible rather than deleted because the mistake is instructive: a
> keyboard was specified for an environment that cannot host it, and the error
> outlived two corrections to the decision it came from.

**On the INSTALLED system, squeekboard is the desktop's keyboard** (until T8's
layer-shell renderer replaces it), and it needs both of these or it silently
never appears:

| Setting | Why it is load-bearing | Ships as |
|---|---|---|
| `org.gnome.desktop.a11y.applications screen-keyboard-enabled` | **`false` by default.** squeekboard's auto-show gate — with it unset the keyboard never appears on text focus no matter what else is right (§5.20) | `true` |
| `org.gnome.desktop.input-sources sources` | empty by default; squeekboard warns `No system layout` and has no keys to draw | `[('xkb','us')]` |

Both are **GSettings in a dconf database**, so "install a file" is not enough —
they need a dconf default (`/etc/dconf/db/local.d/`) or a first-boot step, and
the choice must survive a *new* user account, not just the one on the test Deck.
⚠️ Verify them with `dconf read -d`, never `gsettings get`: a plain read returns
the *user's* value and passes while the site default is missing (§5.20).

⚠️ **And the live ISO needs neither of them.** Nothing in that environment reads
GSettings — there is no dconf-consuming keyboard there, because there is no
compositor. Shipping them into the live image is wasted work that reads like
coverage.

~~**On the INSTALLED system, squeekboard is NOT shipped at all** (§2.6).~~
**Also wrong, and the exact inverse of the truth** — the other half of the same
superseded §2.6-v1 text corrected above. squeekboard **ships on the installed
system** and is the desktop's keyboard today; it is the *live ISO* that cannot
have it. The rest of this table stands on its own evidence:

| Requirement | Why |
|---|---|
| ~~`~/.config/autostart/steam.desktop`~~ **CANCELLED by R-42** — Steam cannot drive a Wayland desktop (XTEST), and a resident Steam removes lizard mode's pointer. Desktop Mode uses squeekboard + lizard mode; **squeekboard ships on the installed system after all**. Kept for history: 🐞 R-41 — a resident Steam removes lizard mode's mouse/keyboard nodes, leaving no pointer. Resolve before shipping. R-39, validated end to end. Valve's keyboard lives inside the Steam client; no Steam, no keyboard. `-silent` starts it resident with **zero windows**. ⚠️ Also requires a **StatusNotifier tray host** (the `omarchy.tray` bar widget) — without one, closing Steam's window quits it and Desktop Mode loses its keyboard |
| `~/.config/omarchy/shell.json` → `"idle": {"screensaver": 150, "lock": 86400}` | R-38. Omarchy locks at 300 s with a password prompt no available keyboard can reach. ⚠️ **`lock: 0` locks INSTANTLY** — there is no off sentinel — and values past ~24.8 days overflow a QML int32 timer |
| `~/.config/hypr/monitors.lua` rotation | §5.11 — the desktop renders sideways without it. Baked, not per-user |

~~⚠️ **The accepted risk that follows** (§2.6): with no squeekboard fallback, a
Desktop Mode where Steam is not running has **no text entry at all**. Recovery is
SSH or a USB keyboard.~~ **Also superseded — third and last remnant of §2.6-v1
in this file.** That risk described a plan where Steam supplied the desktop's
keyboard; R-42 killed it (Steam drives XTEST, which reaches nothing under
Wayland, and a resident Steam takes the controller entirely). **Desktop Mode's
text entry today is T8's layer-shell OSK, hardware-proven at R-43, with
squeekboard installed as the automatic fallback** — two keyboards, not none.

⚠️ **The general trap:** all of these were discovered by something failing on
screen, not by anything failing a check. Nothing in the current test suite would
notice their absence, because every suite runs against the Deck where they are
already set. A conformance check for them belongs in T6's release gate.
