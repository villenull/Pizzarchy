# Progress

> The single living state document. Keep it current as you work, not just at
> session end. Read it at the start of every session.
>
> **Structure:** current state → scope → findings that changed the plan →
> open issues → blocked on human → don't re-derive → session log.
> Chronological narrative belongs in git history, not here. When a finding is
> superseded, **replace it** — this file is state, not a log.

---

## 1. Current state

**Target: a single bootable ISO that installs Arch + Omarchy 4.0 on a Steam
Deck, controller-only, and boots to Gaming Mode with a full Omarchy desktop
behind a Desktop Mode button.** `PLAN.md` §1, with one amendment: the install
may use Wi-Fi (§2.2).

| Task | Status | Notes |
|---|---|---|
| **T0** Test infrastructure | ✅ done | QEMU install harness, CI green, SSH loop, unit tests. Two gaps — §5.7 |
| **R1** Six research questions | ✅ done | All six resolved. Several overturned the plan — §3 |
| **T1** Kernel / firmware / boot | ✅ done, hardware-validated | One real gap: `stage-default-entry` — §5.3 |
| **T2** Gamepad input spike | ⬜ **not started — next block** | Sizes T4. Back on the critical path |
| **T3** Gaming Mode + switching | 🟡 **in progress** | Gaming Mode boots. Session layer being rewritten in-repo — §4 |
| **T4** Controller-only installer | ⬜ not started | Blocked on T2 |
| **T5** ISO + package payload | ⬜ not started | Unblocked by R1 and simplified by §2.2; needs T2/T3/T4 for the package list |
| **T6** Integration + release | ⬜ not started | Gated on Omarchy 4.0 stable |

**The plan is `ROADMAP.md`** — three phases: answer the unknowns and rebuild
the test bed (1), build the product (2), prove it from a factory reset and
release (3).

**Next action:** Phase 1 — P1.1 (T1 loose ends in QEMU) and the T2 spike can
start immediately; the Deck recon/rebuild session (P1.4–P1.5) needs the
operator.

---

## 2. Scope — decided 2026-08-09/10

Five decisions taken together. They interlock; read them as one.

### 2.1 The ISO is the deliverable

An earlier session deferred T4/T5 to a "v1" and scoped a post-install-script
"v0" (`PLAN.md` §3.1). **That is reversed.** The project is the ISO, per
`PLAN.md` §1 and goals 1–8.

**T2 is back on the critical path.** Its only job is sizing T4, and T4 ships.

### 2.2 Network during installation is acceptable — the offline constraint is retired

`CLAUDE.md`'s "fully offline install" hard constraint is **withdrawn by
operator decision.** The Deck may connect to Wi-Fi during ISO installation.
The reasoning: Steam needs network to sign in regardless (§3.2), so an
offline install buys a device that still cannot reach Gaming Mode usefully.
Paying a large engineering cost to avoid a network dependency that reappears
one screen later was not worth it.

**What this removes:**

- The offline mirror stops being load-bearing. ISO size pressure drops
  sharply — no need to bake every package in uncompressed (§3.3's two risks
  largely evaporate).
- "No AUR anywhere in the install path" stops being a hard rule. *(The
  separate rule against **auto-installing an AUR helper** still stands — it
  caused a real upstream failure. And §2.4's decision does not depend on
  this; it rests on licensing and redundancy.)*
- The pre-Steam Wi-Fi screen stops being an exotic first-boot recovery
  mechanism and becomes a normal install screen, as in SteamOS's own wizard.

**What this makes critical instead — and it is a genuinely new requirement:**

> ⚠️ **Wi-Fi must work in the live ISO environment**, which boots Arch's
> stock kernel and stock `linux-firmware` — *not* Neptune and *not*
> `linux-firmware-neptune`. Every existing piece of evidence that Deck Wi-Fi
> works (session 7's `wlan0` check) was gathered on an installed system
> already running Valve's kernel and firmware. **Nothing yet confirms the
> live ISO can drive the OLED Deck's radio at all.** This is now the single
> highest-value unverified assumption in the project — see §5.1.

The install flow also now depends on the user being able to **type a Wi-Fi
password with a controller**, before anything is installed. That pulls the
gamepad mapper and on-screen keyboard (§3.4) into the *live ISO*, not just
the installed desktop — a dependency T2 must size.

### 2.3 Target Omarchy 4.0 (Quattro), currently in beta

This closes the "which Omarchy does this target" question that had been open
since the first session. **4.0, not 3.x.**

⚠️ **The test Deck runs Omarchy 3.8.4, installed from git** — no `omarchy`
pacman package at all. So the target and the only test asset now disagree.
T1 is immune (it gates on the Limine UKI *mechanism*, never on Omarchy's
packaging — proven on this exact machine). **T3's shell integration is not
immune:** the Desktop Mode icon and the Quick Access Menu hook land differently
on Quickshell than on the 3.x waybar shell.

**Resolved by §2.5:** the Deck is rebuilt onto a fresh, package-based
Omarchy 4.0 in phase 1 (`ROADMAP.md` P1.5) — no in-place upgrade of the git
install, no second device needed.

### 2.4 DeckShift is out — this project ships its own session layer

An earlier session adopted `28allday/deckshift` for session switching. **That is
reversed.** Reasons, in order of weight:

1. **It is unlicensed.** Default copyright: no permission to fork, modify or
   redistribute. An ISO cannot carry it, and §2.1 makes the ISO the product.
   *This reason is independent of §2.2 — retiring the offline constraint does
   not make an unlicensed dependency shippable.*
2. **It pulls `gamescope-session-git` / `gamescope-session-steam-git` from the
   AUR** via `yay`/`paru`, which needs an AUR helper this project will not
   auto-install (it caused a real upstream failure).
3. **Its reason to exist does not apply here.** DeckShift targets generic PCs,
   which have no access to Valve's repos. On Deck hardware, Valve's
   `jupiter-staging/gamescope` already ships the entire SteamOS session (§4.1),
   so DeckShift's core value — sourcing a session — is redundant.
4. **We were already bypassing its core.** The hybrid splice tried on the Deck
   replaced ChimeraOS's session with Valve's, leaving DeckShift supplying only
   glue. Documented in `FINDING-deckshift-hybrid.md`.

`deck-session.sh` — written and hardware-tested before DeckShift was adopted,
then retired — **is restored** as the session layer, with its two known bugs
fixed (§4.2).

### 2.5 Wiping / factory-resetting the Deck is acceptable — decided 2026-08-10

The operator explicitly approved fully restoring the Deck to factory settings
if needed. This retires the "protect the precious install at all costs"
posture and lets the plan *use* rebuilds deliberately:

- **Phase 1** (`ROADMAP.md`): wipe the 3.8.4-from-git install and put a
  fresh, package-based **Omarchy 4.0** on the Deck via the stock ISO — one
  session that answers §5.1, recons the live environment, validates the
  stock→Neptune conversion for real, and clears the DeckShift hand-edits.
- **Phase 3**: factory-reset via Valve's recovery image, then run the full
  release matrix from the exact state a real user starts from — and write
  the recovery documentation while doing it.

**What survives:** every write to the Deck still requires asking first;
snapshots still precede destructive iteration; "never *reinstall to test*"
still holds for day-to-day work — planned rebuilds in `ROADMAP.md` are the
deliberate exception, not a shortcut.

**What this de-urgents:** the `/tmp` backups of the six DeckShift-era
hand-edited files only mattered for restoring the current install's state.
Since that state is scheduled to be wiped, losing them costs nothing.

---

## 3. Findings that changed the plan

These matter more than the code. Each cost real time; a session that does not
know them will waste it again.

### 3.1 `PLAN.md`'s §4/§5 architecture is wrong

`OMARCHY_INSTALLER_REPO` / `OMARCHY_INSTALLER_REF` — the env-var pair §4's
diagram and §5's repo plan are built on — **do not exist** in
`omacom-io/omarchy-iso`. Confirmed by full-repo grep: zero occurrences of the
first; the second appears once, in a `--quattro` flag handler, and is never
read.

Omarchy installs as a **pacman package** pulled from a repo baked into the
ISO's offline mirror, not a git-cloned installer chain.

**Replacement architecture** (from upstream's own in-tree precedents,
`install/hardware/pacman.sh` + `intel/ptl-kernel.sh`):

- fork `omarchy-iso` for build-time changes
- ship the Deck logic as **its own pacman package** for install-time work
- plus one `pre-refresh-pacman.d/` hook for durability — load-bearing, because
  `omarchy-refresh-pacman` **silently overwrites `/etc/pacman.conf` wholesale**
  and would delete the Valve repo entries without it

Also found: an ALPM pre-transaction guard aborts bare `pacman -Syu` unless
`OMARCHY_UPDATE_PACMAN=1` is set. Affects T1 and T3.

### 3.2 Steam cannot work offline — the headline claim is reframed, not dropped

Tested for real in a network-isolated VM. Cold, no client, no network: Steam
fails fatally in under a second and exits. Pre-populating the 2.5 GB client was
**also tested** and does not rescue it — Steam reaches a login screen and then
cannot log in. Login requires network under any packaging strategy.

Redistributing a pre-populated client was checked separately and is not clearly
authorized by Steam's Subscriber Agreement. Every Linux distro ships only the
20 MB launcher.

**Decided:** ship only the launcher, no pre-populated client.

This finding is what ultimately retired the offline constraint (§2.2): if
Steam needs network one screen after install regardless, an offline installer
buys very little for a lot of engineering. The honest claim is now simply
*"connects to Wi-Fi during setup, exactly like a factory-reset Deck."*

### 3.3 The offline mirror can carry Valve packages — no signing step needed

`omarchy-iso` already ships an out-of-tree kernel from an unsigned third-party
repo (`linux-t2` / `[arch-mact2]`, `SigLevel = Never`) into its offline mirror
and boots it. Adding Valve's repos is a structurally identical, already-exercised
edit. **The signing caveat in the original hypothesis does not exist.**

Two *new* risks were identified at the time:

- the mirror is stored **uncompressed**, so every byte adds ~1:1 to ISO size
- the build has a hard package-count self-check (600–2000) whose upper bound
  will need widening

**Both are largely defused by §2.2.** With network available at install time,
the mirror only needs to carry what genuinely must be present before the
network is up — the Deck's own Wi-Fi firmware above all (§5.1). Everything
else can be pulled. Keep the mechanism; shrink the payload.

### 3.4 Gamepad mapping in Desktop Mode — resolved on hardware

**Ship design (b):** a custom `uinput`/`evdev` mapper as a systemd `--user`
service. Design (a) (background Steam) is ruled out by a **circular dependency**,
not a measurement: it sources the on-screen keyboard from a signed-in Steam
client, Steam needs network to sign in, and the pre-Steam Wi-Fi screen needs an
OSK to type the Wi-Fi password. You would need the keyboard to get the network
that provides the keyboard.

Verified on hardware:

- unprivileged `/dev/uinput` creation works with a udev rule — **no privileged
  helper needed**
- controller evdev *read* access already works via seat ACLs
- Hyprland implements the protocols an OSK needs

Two errors in the prepared design were found only by running it:

1. `hyprland-session.target` **does not exist**. Under `uwsm` the real target is
   `wayland-session@hyprland.desktop.target`. A unit wanted by a nonexistent
   target **enables without error and never starts** — it would have shipped,
   reported success, and done nothing.
2. `uaccess` does **not** cover `/dev/uinput` (virtual device, no seat tag).
   **T4/T5 action item: the installer must add the desktop user to the `input`
   group.** `SupplementaryGroups=` is not permitted in a `--user` unit, so this
   cannot be done per-service.

**Use `squeekboard`** (Arch `extra`). The originally-suggested `wvkbd` is
AUR-only.

### 3.5 Secure Boot is a non-issue

Operator-verified on their own Deck: boot order already defaults to Limine, and
the BIOS exposes no Secure Boot toggle at all. No pre-install BIOS step, no
photo documentation needed.

### 3.6 Two real bugs found by the first hardware run of T1

**Bug 1 — snapshot entries miscounted as duplicate boot entries.** The script
counted a UKI basename as a *substring* of the Limine config. `limine-snapper-sync`'s
rollback entries embed the same basename under `limine_history/`, so the count
came back 2 instead of 1 and a correct boot chain was declared broken.

The trigger was **the safety snapshot the hardware task's own procedure
mandates** — anyone following the documented steps hits it. Worse, the same
faulty count defeated the "already up to date" check, so the kernel was
**rebuilt on every run**, inside a pacman hook. The idempotency proven across
six VM suites was real in QEMU and silently false on any real machine with a
snapshot. **Fixed** — the count is now anchored to real `path:` lines under the
ESP's `/EFI/Linux/`.

**Bug 2 — nothing sets the default boot entry.** The Deck defaulted to the
*stock Arch kernel*; the operator had been selecting Neptune by hand without
that being visible anywhere. Nothing in the toolchain owns `default_entry`.
On a fresh install an end user would silently boot the wrong kernel with
degraded hardware support and no error. **Fixed by hand on the operator's Deck;
still not in the script** — §5.2.

### 3.7 Prior art does not duplicate this project

`28allday` (a.k.a. no-signal.uk) ships `deckshift` (unlicensed),
`omarchy-deck-iso` (**MIT**), `omasteam` (MIT), and the superseded
`Super-Shift-S-Omarchy-Deck-Mode` (unlicensed) that `PLAN.md` §5/§6.4 names as
the fork base. **None of them target Steam Deck hardware** — all are
"Deck-*style* gaming mode on a generic PC", no Neptune kernel, no Valve
firmware, no Jupiter/Galileo detection, and DeckShift explicitly handles NVIDIA.
Bazzite and ChimeraOS solve Deck hardware but not Omarchy.

**So this project's differentiator — real Deck hardware plus Omarchy — is not
duplicated.** That is the answer to the prior-art check `PLAN.md` §2 demanded.

**Still worth reusing:** `omarchy-deck-iso` is MIT and is structurally already
T5's architecture — a thin Omarchy fork, an offline mirror, post-install steps.
A legitimate base even though it has no Deck hardware support.

### 3.8 A bare `pacman -S steam` installs NVIDIA drivers on a Steam Deck

`steam` depends on the *virtual* `lib32-vulkan-driver`. With no 32-bit AMD
provider installed, pacman picks the NVIDIA stack on its own — `nvidia-utils`,
`egl-wayland`, `egl-gbm`, `egl-x11`. Naming `lib32-vulkan-radeon` explicitly
drops them to zero. **Nothing errors.**

**T5 must pin `lib32-vulkan-radeon` in the package list**, or every offline
install ships several hundred MB of unused NVIDIA driver in an uncompressed
mirror, on AMD-only hardware.

---

## 4. T3 — the session layer

### 4.1 Valve already ships the entire Gaming Mode session

`jupiter-staging/gamescope` 3.16.25-3 (Valve's own build, packager
`ci-package-builder-1@steamos.cloud`) provides:

```
/usr/share/wayland-sessions/gamescope-wayland.desktop   the session entry
/usr/bin/start-gamescope-session                        the entry point
/usr/lib/steamos/gamescope-session                      the real launcher
/usr/lib/systemd/user/gamescope-session.target          the unit graph
  + gamescope-session.service, steam-launcher.service, ibus-gamescope.service,
    steam-notif-daemon.service, gamescope-mangoapp.service,
    galileo-mura-setup.service  (OLED mura correction — Deck-specific)
```

All verified present on the Deck. `/usr/lib/steamos/gamescope-session` also
handles HDR, VRR, fan control, dynamic backlight and mangoapp.

**This is why `PLAN.md` §6.4's "fork Super-Shift-S, it solves the hard part" is
obsolete.** It was true when written. Valve supplies the session; this project
supplies only the *switch*. `mangohud`/`lib32-mangohud` are needed for
`mangoapp`, which the session references but the package does not pull.

**Withdrawn:** the earlier "T5 must build pre-built `gamescope-session*`
packages for the offline mirror" requirement. T5 just needs
`jupiter-staging/gamescope` in the mirror, which §3.3 already established is
straightforward.

### 4.2 Exactly one piece is missing: `steamos-session-select`

Checked with `pacman -F` across core, extra, multilib, omarchy,
jupiter-staging and holo-staging: **`steamos-session-select` is in no configured
repo.** It lives in SteamOS's `steamos-customizations`.

Steam's "Power → Switch to Desktop" shells out to it *by name*. Without it,
Steam's own affordance **silently does nothing** — `PLAN.md` §8.1's failure mode,
in the one place a controller-only user cannot work around it.

`deck-session.sh` supplies it, plus the path back. Two bugs from its first
version are fixed:

1. **The SDDM drop-in never won, on any machine.** The file's own comment
   claimed `95-deck-session.conf` "sorts after Omarchy's `autologin.conf`". It
   does not — `9` < `a`, so `autologin.conf` always overrode it. Undetected
   because Gaming Mode had never been booted. **The bug was in a comment
   asserting an ordering nobody checked.** Fixed by sorting last (`zz-`).
2. **The NOPASSWD verification passed on a warm sudo credential cache**, so it
   proved nothing. Fixed: clear the cache before probing, and detect the case
   where the user has blanket NOPASSWD (which makes the probe vacuous) and say
   so rather than claim verification.

Neither was caught by the file being shellcheck-clean, idempotent, and passing
its own tests.

### 4.3 What is confirmed on hardware, and what is not

**Confirmed:** Gaming Mode has been entered on the Deck once, and a
return-to-desktop button was present. That is the first gamescope session ever
started on this machine.

**Not confirmed, and must not be recorded as passing:** whether controller input
works in Gaming Mode, whether audio works there, and whether the return button
*functions* as opposed to merely appearing. The last is the one that exercises
the `steamos-session-select` shim and is the controller-only path out.

**Note:** that confirmation was obtained with the DeckShift hybrid in place.
Under §2.3 that hybrid is being removed, so it is evidence that *Valve's session
starts on this hardware* — not evidence about this project's own switch layer.

---

## 5. Open issues

Ranked by what they would cost to discover late.

### 5.1 ⚠️ Wi-Fi in the live ISO is unverified — highest priority

Introduced by §2.2. The install now depends on the Deck reaching Wi-Fi *from
the ISO*, and the ISO boots **Arch's stock kernel and stock `linux-firmware`**,
not Neptune and not `linux-firmware-neptune`.

All existing evidence that Deck Wi-Fi works comes from an installed system
already running Valve's kernel and firmware. That evidence says nothing about
the live environment. The OLED Deck also uses a **different radio from the
LCD model** (`PLAN.md` §9.6), so even generic "Steam Deck Wi-Fi works on Linux"
reports are not transferable without checking the model.

**Cheap to settle, and it should be settled before T4 designs a Wi-Fi screen
around an assumption:**

1. Boot the *stock, unmodified* Omarchy 4.0 ISO on the Deck from the Ventoy
   USB and see whether a wireless interface enumerates and can associate.
   This is `ROADMAP.md` P1.5's first act, before the wipe.
2. If it does not, the ISO fork must carry `linux-firmware-neptune` (or the
   specific firmware blob) **in the live environment's own filesystem**, not
   just in the package payload — a different and less obvious change than
   adding a package to the mirror.

While in the live environment, also record two more things T4/T5 need
(one boot answers all three):

- **Display rotation.** The Deck panel is portrait-native; the live ISO may
  render rotated 90°. T4's screens must know.
- **Input enumeration** — what the controller looks like to the live kernel.

If Wi-Fi fails and cannot be fixed in the live image, the offline mirror
becomes load-bearing again and §2.2 has to be partially reconsidered. That is
why it ranks first.

### 5.2 The VM test substrate has a blind spot

`vm-neptune-image.sh` creates **no snapper snapshot**, so `limine-snapper-sync`
never writes the Snapshots submenu, so the second UKI reference that caused
§3.6's Bug 1 never existed. Three test suites could not have caught it.

**Any future "idempotency proven" claim inherits this blind spot until the
substrate creates a snapshot.** Small fix, restores trust in every idempotency
claim the project makes. Do it before T3 adds more to test.

### 5.3 `stage-default-entry` does not exist

`default_entry` appears **zero times** in `omarchy-deck-kernel.sh`. The
operator's Deck is fixed by hand only.

Needs a stage that asserts the default resolves to the pinned Neptune kernel and
repairs it when it does not — writing the **entry path** (`Omarchy/linux-neptune-611`),
not a numeric index, since `limine-snapper-sync` inserts and removes a Snapshots
submenu and can renumber indices. Must also run inside `reconcile`, so the
pacman hook re-asserts it whenever kernels change.

**⚠️ Not yet proven that the entry-path form is what did the work.** The target
is also entry #1, so a silent fallback to index 1 would look identical. A fix
that works by accident is worse than none.

**Settle it in QEMU, not on hardware:** set `default_entry` to a *non-first*
entry on the `vm-neptune-image.sh` substrate, boot, and assert
`LoaderEntrySelected`. Limine implements the Boot Loader Interface, so
`bootctl status` reports the selected entry as a path from userspace — a
ready-made assertion target, no screen-scraping.

### 5.4 T1's stock→Neptune conversion is unvalidated on hardware

The operator's Deck was converted by hand months earlier, so **seven of nine
stages only ever ran their no-op path**. The actual conversion — removing Arch's
split `linux-firmware-*` and swapping in Valve's, and cycling the ESP mount on a
live system — remains VM-only evidence. Biggest remaining hardware gap for T1.

**Closes by design in `ROADMAP.md` P1.5:** the fresh Omarchy 4.0 install is a
stock-kernel system, so running `omarchy-deck-kernel.sh` on it exercises the
real conversion path end to end.

Related: bumping the Neptune pin (`NEPTUNE_SERIES_DEFAULT=611`; `618` is the
newest non-RC series) is a one-line change but should not ship without a
hardware boot test.

### 5.5 T1's deliberate-failure test was never run

`TASK-T1`'s done-criteria include "corrupt the Limine config, confirm the script
fails loudly rather than continuing." There is no evidence anywhere that this was
done. T1 is otherwise complete; this is an unticked box being carried as ticked.

### 5.6 The test Deck is not running the target OS

**Resolved by plan:** §2.5's phase-1 rebuild puts a fresh, package-based
Omarchy 4.0 on it (`ROADMAP.md` P1.5). Open only until that session runs.

### 5.7 T0's two remaining gaps

- **Ventoy USB setup has never been executed** (documented in
  `FINDING-testing-usb.md`, not done). Now on the critical path — it is
  `ROADMAP.md` P1.4.
- **`deck-sync.sh` has never run against real hardware.** Fold into P1.5's
  post-install setup: enable `sshd` on the fresh install and give the dev
  machine a resolvable host (the `steamdeck` hostname currently does not
  resolve; needs an IP or an `/etc/hosts` entry).

### 5.8 Untouched risk items from the original plan

- **LCD Steam Decks are entirely untested.** Only OLED hardware exists. Gate
  LCD-divergent paths on model detection and ship "OLED-verified, LCD-untested"
  rather than claim support.
- **Trademark / redistribution** — "Steam Deck" and Valve iconography usage
  (`PLAN.md` §6.1's button glyphs), and whether the ISO may redistribute Valve's
  kernel and firmware. Flagged as cheap-to-check-early; **not checked.**
- **Recovery path documentation** — how a user returns to stock SteamOS. An
  ethical baseline for a wipe-the-device project. **Not written — and now
  scheduled:** `ROADMAP.md` P3.1 produces it as a byproduct of the phase-3
  factory reset.

### 5.9 One upstream draft staged and held

`DRAFT-upstream-esp-permissions-omarchy.md` (against `basecamp/omarchy`) is
fully drafted, reviewed, and **deliberately unsent** by operator choice. It is
kept because its bug is one this project actively works around — when upstream
fixes it, `stage_esp_permissions`'s loosening can be revisited.

The five `deckarchy` bug reports and the `28allday` outreach draft were
**removed from the tree 2026-08-10** (recoverable from git history): the
project moved fully past deckarchy, and the outreach's premise died with the
DeckShift drop (§2.4). Nothing has ever been posted anywhere.

---

## 6. Blocked on human

- **`ROADMAP.md` P1.4 — Ventoy on the test USB + the stock Omarchy 4.0 beta
  ISO.** `ventoy-bin` is not installed on the dev machine. The ISO can be
  downloaded, or built locally (a real build already succeeded in session 2 —
  remember `--network host`).
- **`ROADMAP.md` P1.5 — the Deck recon + rebuild session.** Needs the
  operator present, a USB keyboard for the dev-time install, the Valve
  recovery image on a second USB as the floor, and anything personal copied
  off the Deck first. Approved in principle by §2.5; still confirm before
  executing.
- **Any write to the physical Deck.** Prepare, describe, wait. Batch requests.
- **Anything touching TDP, fan curves, or charge limits** — every time, no
  exceptions. Genuine hardware-damage risk.
- **Any public action** — repos, upstream issues, outreach. One draft staged
  (§5.9).

Retired from this list 2026-08-10: "do not wipe the Deck" (superseded by
§2.5's planned-rebuild posture), the DeckShift manual removal and its `/tmp`
backup rescue (the rebuild wipes both).

---

## 7. Don't re-derive — each of these cost real time

- Docker's default bridge network is throttled to ~2 KB/s on the operator's dev
  machine. Use `--network host` for any Docker-based tooling there.
- `mount -o remount` does **not** re-apply `fmask`/`dmask` on vfat. A full
  `umount`/`mount` cycle is required.
- `pacman --noconfirm` answers **No** to conflict questions. The firmware swap
  needs `--ask=4` (`ALPM_QUESTION_CONFLICT_PKG` only, not a blanket yes).
- Valve's kernel packages ship **no mkinitcpio preset and no `/boot/vmlinuz-*`**
  at all — only `usr/lib/modules/<kver>/{pkgbase,vmlinuz}`. `PLAN.md` §8.3's
  preset bug is therefore moot, and an entire class of preset-patching work in
  the original plan does not exist.
- Omarchy builds UKIs with `limine-mkinitcpio-hook`, not presets. Upstream's
  hooks already cover install/upgrade **and** removal, including deleting the
  UKI. This project's hook **verifies**; it does not generate.
- The UKI filename prefix is **not** the machine-id — it is `CUSTOM_UKI_NAME`
  from `/etc/default/limine` (`omarchy` on this Deck). Discover it, never
  construct it.
- The Limine config is at `$ESP/limine.conf` — the fifth of the five candidate
  paths, so the five-way probe was right to exist.
- Kernel series suffixes are **not orderable** (`618` vs `72` — neither integer
  nor string comparison is right). This is why the version is pinned to one
  documented constant.
- `linux-firmware-neptune` collides with Arch's *split* `linux-firmware`. Valve's
  package declares `conflicts`/`replaces` against only two of the twelve
  subpackages. Remove the other ten explicitly — `--overwrite` would leave Arch
  owning those paths and the next `-Syu` would silently restore Arch's firmware
  over Valve's.
- `limine-snapper-sync.service` holds the ESP open; the `umount`/`mount` cycle
  needs it stopped and restarted.
- mkinitcpio's UKI output **is** byte-reproducible. An earlier claim to the
  contrary was wrong. Consequence: a sha256 snapshot does not catch a needless
  rebuild; prove regeneration with an mtime sentinel.
- On the Deck, `sudo` cannot prompt without a TTY. Agent sessions need a
  `SUDO_ASKPASS` helper; one is saved at `~/pizzarchy-askpass.sh`.
- The `cs35l41-dsp1-*` firmware warnings previously recorded as "expected on
  OLED" **do not occur** on current firmware. Treat their reappearance as worth
  investigating, not as background noise.
- Docker containers get a tmpfs `/dev` with no udev, so `losetup -P` publishes
  partitions under `/sys/block` but creates no `/dev/loopNpM` nodes — `mknod`
  them from sysfs. Relatedly, `genfstab -U` silently emits `/dev/loop0p1` when
  udev never populated `/dev/disk/by-uuid`.
- Put `console=ttyS0` **last** in a QEMU kernel cmdline, or systemd's boot
  output goes to a VGA framebuffer no harness is capturing.

---

## 8. Session log

One line each. Detail lives in git history and in the `FINDING-*.md` files.

| # | What happened |
|---|---|
| 1 | Bootstrap; T0 §1 harness + libraries + unit tests; T0 §2–6 (Ventoy doc, override loader, `deck-sync.sh`, CI, shellcheck baseline) |
| 2 | T0 §1 verified end-to-end against a real ISO build; found two real bugs in this project's own harness |
| 3 | R1 §10.1/10.2/10.4/10.5 resolved; §10.6 drafted and held |
| 4 | T1 steps 1–2 — near-total rewrite of `omarchy-deck-kernel.sh`; four design premises were false |
| 5 | T1 step 3 — the pacman hook; found upstream already covers most of it, so ours verifies rather than generates |
| 6 | T1 steps 4+6 — nine independently runnable stages, provably non-interactive |
| 7 | First physical hardware run; two real bugs found; R1 §10.3 resolved; Steam/gamescope installed; prior-art check done |
| 8 | First Gaming Mode boot, via a DeckShift hybrid splice (since reversed — §2.3) |
| 9 | Scope reset: ISO is the deliverable, target Omarchy 4.0, DeckShift dropped. Docs consolidated; `ROADMAP.md` written (three phases); Deck rebuild + factory-reset strategy adopted; dead drafts removed |
