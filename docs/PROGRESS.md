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
behind a Desktop Mode button.** `docs/PLAN.md` §1, with one amendment: the install
may use Wi-Fi (§2.2).

| Task | Status | Notes |
|---|---|---|
| **T0** Test infrastructure | ✅ done | QEMU install harness, CI green, SSH loop, unit tests. **Both §5.4 gaps closed by P1.5** |
| **R1** Six research questions | ✅ done | All six resolved. Several overturned the plan — §3 |
| **T1** Kernel / firmware / boot | ✅ done | Ten stages, **hardware-validated end to end 2026-08-10** (§5.2). Neptune pin bump still untested |
| **T2** Gamepad input spike | ✅ done | Navigation confirmed; T4 is days not weeks. Text entry open — §3.9 |
| **T3** Gaming Mode + switching | 🟡 **the core promise now works through Steam's own UI** (§5.10 closed, session 15). Rotation fixed on greeter + desktop (§5.11). Remaining: §5.15 (missing polkit helpers — brightness, timezone), §5.16 root cause, parity batches P2.2/P2.3, Quickshell pinning P2.4 |
| **T4** Controller-only installer | ⬜ not started | **Re-scoped by §5.9** — lizard mode already makes the installer navigable; the real gap is text entry |
| **T5** ISO + package payload | ⬜ not started | Unblocked by R1 and simplified by §2.2. **New constraints from P1.5:** offline-only pacman (§7), encryption default (§5.12), repo precedence (§5.13) |
| **T6** Integration + release | ⬜ not started | Gated on Omarchy 4.0 stable |

**The plan is `docs/ROADMAP.md`** — three phases: answer the unknowns and rebuild
the test bed (1), build the product (2), prove it from a factory reset and
release (3).

**P1.5 is ✅ COMPLETE (2026-08-10).** All six phases ran in one session. The
Deck now runs package-based **Omarchy 4.0 + Neptune 6.11.11-valve29**,
unencrypted, booting unattended, with both session-switch directions working
and **zero DeckShift**. Full findings, R-0 through R-18:
`docs/findings/P15-live-iso-recon.md`; raw evidence in
`docs/findings/P15-recon-raw/`.

Closed by it: §5.1, §5.2, §5.3, §5.4, and phase-1 exit criteria.
Opened by it: §5.9–§5.14, several of which change T3/T4/T5.

Two deviations from the runbook, agreed with the operator: a **single USB
stick** (no pre-staged recovery stick — reflash on demand instead) and
**Wi-Fi rather than Ethernet** for SSH, which worked.

**Deck access for the next session:** `ssh steamdeck` (alias → 192.168.100.25,
user `deck`, key-based). Passwordless sudo via
`/etc/sudoers.d/99-deck-testing` — **test-device posture, revisit before
shipping** (it also masks `deck-session.sh`'s own sudoers verification).
Snapshots: #1 pre-Neptune, #2 post-conversion, #3 complete.

**Session 15 (2026-08-10) closed the phase-2 opener.** §5.10, §5.14 and the
greeter/desktop half of §5.11 are all resolved and proven on hardware: **Steam's
own Power → Switch to Desktop now works end to end**, and Steam is signed in.
`src/deck-session.sh` went from four install stages to six, each verifying its
own effect by running something. Snapshot **#4** precedes that session's writes.
Findings: `docs/findings/P2-steam-integration-and-rotation.md` (R-20…R-26).

It opened **§5.15** (Steam's whole privileged-helper surface is missing — this is
now the widest gap, and it owns Gaming Mode's brightness slider) and **§5.16**
(the switch could permanently kill sddm; mitigated, root cause open).

**Next action:** either **§5.15** (decide the polkit-helper scope — `timedatectl`
for timezone is cheap; `steamos-priv-write` needs a security design) or the
Deck-free work: **§5.13**'s repo-precedence audit, **P2.5** (T4 installer
screens) or **P2.7** (T5 ISO fork). T5 also inherits a new obligation from
§5.11: the desktop rotation currently lives in one user's dotfile.

**Session 17 (2026-08-10) was the eyes-and-hands pass for input**, the first
time any of this was seen on a screen. It found the input mapper was a
**complete no-op** on the desktop (bound to a node lizard mode keeps silent),
and two defects beneath that: the d-pad emitted nothing at all, and a resting
analog stick cancelled every held direction within ~10 ms. Both are fixed,
deployed, and **verified on hardware by pressing the buttons**. It also answered
the OSK question (§5.20) and fixed a generated file that executed a command at
render time (§R-36). Findings: `docs/findings/P17-input-and-osk.md` (R-29…R-36).

**Git state:** `main` and `origin/main` were level at the start of session 17
(verify with `git rev-list --left-right --count origin/main...main`, never by
trusting this line). Session 17's work is on **`p17-input-and-osk`**.

⚠️ **CI was RED and this file said otherwise.** `shellcheck -x` exited 1 on
`src/deck-session.sh` (SC2006), and CI's shellcheck step has no `|| true`. The
old claim that "five bash suites and `shellcheck -x` over 21 scripts pass
locally" was stale. Fixed in session 17; shellcheck now exits 0 and all five
bash suites plus both Python suites pass.

### 1.1 Artifacts that live OUTSIDE this repo

Too large for git, but real and current. A session that assumes these are
missing will waste an hour rebuilding them.

| Artifact | Where | Notes |
|---|---|---|
| **Omarchy 4.0 beta ISO** | `~/ISOs/omarchy-2026.08.10-x86_64-quattro.iso` | 6.0 GB, built 2026-08-10, `.sha256` alongside. **This is P1.4's ISO** — copy to the Ventoy stick. Rebuild only if a newer 4.0 is wanted (§3.10 has the flags) |
| **QEMU substrate image** | `test/images/neptune-substrate.raw` | 14 GB apparent / ~2.9 GB sparse, gitignored. Every `test/vm/` suite uses it; rebuilt automatically by `test/images/vm-neptune-image.sh` if absent (~6 min) |
| **`omarchy-iso` scratch clone** | session scratch — **will be lost** | Had two local deviations worth reapplying if rebuilding: `--network host` on the Docker run (§7's bridge throttle) and a scratch pacman cache instead of the host's (§3.10 item 3) |

---

## 2. Scope — decided 2026-08-09/10

Five decisions taken together. They interlock; read them as one.

### 2.1 The ISO is the deliverable

An earlier session deferred T4/T5 to a "v1" and scoped a post-install-script
"v0" (`docs/PLAN.md` §3.1). **That is reversed.** The project is the ISO, per
`docs/PLAN.md` §1 and goals 1–8.

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

~~⚠️ The test Deck runs Omarchy 3.8.4, installed from git.~~ **No longer true
as of 2026-08-10** — P1.5 rebuilt it onto package-based 4.0, so target and
test asset agree. The paragraph below is kept because it explains *why* T3's
shell integration needs re-verifying on Quickshell.
T1 is immune (it gates on the Limine UKI *mechanism*, never on Omarchy's
packaging — proven on this exact machine). **T3's shell integration is not
immune:** the Desktop Mode icon and the Quick Access Menu hook land differently
on Quickshell than on the 3.x waybar shell.

**Resolved by §2.5:** the Deck is rebuilt onto a fresh, package-based
Omarchy 4.0 in phase 1 (`docs/ROADMAP.md` P1.5) — no in-place upgrade of the git
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
   glue. Documented in `docs/findings/deckshift-hybrid.md`.

`src/deck-session.sh` — written and hardware-tested before DeckShift was adopted,
then retired — **is restored** as the session layer, with its two known bugs
fixed (§4.2).

### 2.5 Wiping / factory-resetting the Deck is acceptable — decided 2026-08-10

The operator explicitly approved fully restoring the Deck to factory settings
if needed. This retires the "protect the precious install at all costs"
posture and lets the plan *use* rebuilds deliberately:

- **Phase 1** (`docs/ROADMAP.md`): wipe the 3.8.4-from-git install and put a
  fresh, package-based **Omarchy 4.0** on the Deck via the stock ISO — one
  session that answers §5.1, recons the live environment, validates the
  stock→Neptune conversion for real, and clears the DeckShift hand-edits.
- **Phase 3**: factory-reset via Valve's recovery image, then run the full
  release matrix from the exact state a real user starts from — and write
  the recovery documentation while doing it.

**What survives:** every write to the Deck still requires asking first;
snapshots still precede destructive iteration; "never *reinstall to test*"
still holds for day-to-day work — planned rebuilds in `docs/ROADMAP.md` are the
deliberate exception, not a shortcut.

**What this de-urgents:** the `/tmp` backups of the six DeckShift-era
hand-edited files only mattered for restoring the current install's state.
Since that state is scheduled to be wiped, losing them costs nothing.

---

## 3. Findings that changed the plan

These matter more than the code. Each cost real time; a session that does not
know them will waste it again.

### 3.1 `docs/PLAN.md`'s §4/§5 architecture is wrong

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

*The blind spot that hid it is closed (2026-08-10):* `test/images/vm-neptune-image.sh` now
builds a btrfs root with snapper + `limine-snapper-sync` and **one real
snapshot**, so every suite runs against a config with a genuine Snapshots
submenu. Closing it immediately caught the same substring miscount in
`test/vm/vm-kernel-hook-test.sh`'s own probe — the test harness carried the bug it
existed to catch, invisible until the substrate could show it.

**Bug 2 — nothing sets the default boot entry.** The Deck defaulted to the
*stock Arch kernel*; the operator had been selecting Neptune by hand without
that being visible anywhere. Nothing in the toolchain owns `default_entry`.
On a fresh install an end user would silently boot the wrong kernel with
degraded hardware support and no error. **Fixed (2026-08-10):**
`stage-default-entry` writes the entry-*path* form, `reconcile` re-asserts it
on every kernel change, and `test/vm/vm-default-entry-test.sh` proved the path form is
genuinely honoured — a **non-first** entry planted as default is the entry
Limine actually selected (`LoaderEntrySelected`) and booted (`uname -r`), so
the observed behaviour cannot be an index-1 fallback. The operator's Deck
still carries the hand-applied fix; the script's version runs on it at P1.5.

### 3.7 Prior art does not duplicate this project

`28allday` (a.k.a. no-signal.uk) ships `deckshift` (unlicensed),
`omarchy-deck-iso` (**MIT**), `omasteam` (MIT), and the superseded
`Super-Shift-S-Omarchy-Deck-Mode` (unlicensed) that `docs/PLAN.md` §5/§6.4 names as
the fork base. **None of them target Steam Deck hardware** — all are
"Deck-*style* gaming mode on a generic PC", no Neptune kernel, no Valve
firmware, no Jupiter/Galileo detection, and DeckShift explicitly handles NVIDIA.
Bazzite and ChimeraOS solve Deck hardware but not Omarchy.

**So this project's differentiator — real Deck hardware plus Omarchy — is not
duplicated.** That is the answer to the prior-art check `docs/PLAN.md` §2 demanded.

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

### 3.9 A gamepad can drive the installer — T4 is days, not weeks

`docs/findings/T2-gamepad-spike.md`. A ~200-line `uinput`/`evdev` mapper
(`src/deck-input-mapper.py`) drives `gum` prompts and `archinstall`'s curses menu
with **no cooperation from either** — proven in QEMU through the real
delivery path (virtual pad → mapper → virtual keyboard → **kernel VT** →
tmux client → pty → TUI), asserting on rendered text *and* outcome.

**This is the good branch of `docs/tasks/T2-gamepad-input-spike.md`'s fork:** T4 becomes configuration
(reduce prompts, set defaults, map buttons, glyphs) rather than bespoke
gamescope-hosted Quickshell screens. The same mapper also serves T3's Desktop
Mode (R1 §10.3 design (b)) — one artifact, two consumers.

**The open gap is text entry**, and only two screens need it: the Wi-Fi
password (§2.2 put it on the critical path) and account credentials.
**Now decided (2026-08-10):** the built 4.0 ISO's live environment has **no
Wayland compositor at all**, so `squeekboard` is out there — T4 ships a
**mapper-drawn OSK** that renders on a bare TTY and types through the
virtual keyboard the mapper already owns. `squeekboard` remains correct for
Desktop Mode under Hyprland; the two contexts get different answers.

⚠️ **The real Deck controller's event codes are not yet known** — the spike
used a virtual pad modelling the Linux gamepad ABI. P1.5's recon captures
them. Expect mapping-table entries to change; the mechanism will not.

### 3.10 Building the Omarchy 4.0 ISO — three gotchas for T5

Found while producing a 4.0 beta ISO for P1.4 (`omarchy-iso` @ `a12bfea`).
T5 forks this builder, so these are its inheritance:

1. **`OMARCHY_ISO_REF` and `OMARCHY_MIRROR` must agree, and the defaults do
   not.** A bare `omarchy-iso-make` uses ref `quattro` (which selects the
   `omarchy-dev` runtime package) with mirror `stable` — whose `omarchy-dev`
   predates `install/provisioning/setup-form.sh`. Build with
   `OMARCHY_MIRROR=edge` (what the `--quattro` flag sets) or the two channels
   disagree.
2. **Upstream's guard is a model worth copying.** Rather than shipping an ISO
   whose configurator has no prompts, the build **fails loudly**: *"this ISO
   would boot into an installer with no questions to ask."* That is exactly
   the discipline `docs/PLAN.md` §8.1 wishes more tooling had — T5's fork must not
   weaken it.
3. **⚠️ The build bind-mounts the HOST's `/var/cache/pacman/pkg` read-write
   into a privileged container, and `omarchy-iso-make` `sudo rm -rf`s it
   before every build.** On this dev machine that cache holds 2700+ packages.
   A truncated `omarchy-keyring` download did land in it once (pacman
   self-healed on the next run by deleting it). **Local builds here point the
   container at a scratch cache dir instead** — same rebuild speed, no blast
   radius on the developer's system. T5's fork should do the same rather than
   inherit the `rm -rf`.

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

**This is why `docs/PLAN.md` §6.4's "fork Super-Shift-S, it solves the hard part" is
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
Steam's own affordance **silently does nothing** — `docs/PLAN.md` §8.1's failure mode,
in the one place a controller-only user cannot work around it.

`src/deck-session.sh` supplies it, plus the path back. Two bugs from its first
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

### 5.1 Wi-Fi in the live ISO — ✅ **RESOLVED 2026-08-10, confirmed on hardware**

**Answer: YES.** On the OLED Deck (Galileo), the 4.0 beta ISO's live
environment drives the radio end to end — driver binds, scan, WPA2
association, DHCP. Evidence and full recon: `docs/findings/P15-live-iso-recon.md`
(§R-0), raw logs in `docs/findings/P15-recon-raw/`.

⚠️ **The conclusion was right but the reasoning below was wrong.** The Deck's
chip is **QCA2066 hw2.1**, not QCNFA765; the firmware that served it lives at
`ath11k/QCA2066/`, *not* the `WCN6855/.../nfa765/` path this section watched.
Anything that prunes firmware must keep `ath11k/QCA2066/` — pruning on the
old reasoning would have broken the radio. See the finding's §R-6.

Retired by this result: T5's "bake firmware into the live image" mitigation,
and the ROADMAP's "live ISO can't drive the OLED radio" standing risk.

**Still open:** this was association from a shell with a keyboard. It does
not prove a *controller-only* user can join Wi-Fi — that needs T4's text
entry, and §R-8 changed what that has to be built on.

<details><summary>Superseded pre-hardware reasoning (kept for the audit trail)</summary>

Introduced by §2.2: the install now depends on the Deck reaching Wi-Fi *from
the ISO*, whose live environment runs its own kernel and firmware, not
Neptune's.

**Substantially de-risked 2026-08-10 by inspecting the built 4.0 ISO**
(`~/ISOs/omarchy-2026.08.10-x86_64-quattro.iso`). Its `airootfs.sfs`
carries, in the live environment:

```
usr/lib/firmware/ath11k/WCN6855/hw2.0/nfa765/{amss.bin,m3.bin}   <- QCNFA765
usr/lib/firmware/ath11k/WCN6855/hw2.1/nfa765/{amss.bin,m3.bin}
usr/lib/firmware/ath11k/WCN6855/hw2.{0,1}/board-2.bin            <- per-board cal
usr/lib/firmware/ath11k/WCN6855/hw2.{0,1}/regdb.bin
kernel/drivers/net/wireless/ath/ath11k/*                         <- the driver
usr/bin/iwctl + iwd.service                                      <- association
```

The **`nfa765`** directory is the notable part: that is QCNFA765, the OLED
Deck's Wi-Fi module, with firmware variants named for it specifically. The
driver, the per-board calibration blob (`board-2.bin` — the usual failure
point when a device is *almost* supported), the regulatory database and the
association tooling are all present.

Live kernel is `7.1.6-arch1-Watanare-T2-1-t2` — the `linux-t2` kernel
`omarchy-iso` already ships from `[arch-mact2]` (§3.3), not stock Arch.

**Still not proof.** Firmware being present does not prove the driver binds
to this device's PCI ID, nor that association succeeds. **P1.5 confirms it
on hardware** — but the expected answer is now "yes", and the recon knows
exactly what to check (`dmesg | grep ath11k`, does `wlan0` appear, does
`iwctl station wlan0 scan` return networks).

While in the live environment, still record for T4/T5:

- **Display rotation.** The Deck panel is portrait-native; the live ISO may
  render rotated 90°.
- **Input enumeration** — what the controller looks like to the live kernel
  (`/proc/bus/input/devices`), which the T2 mapper's tables need (§3.9).

</details>

*(Both recon items above are now answered — see §5.9.)*

### 5.9 ⚠️ It re-scopes T4: the gamepad node is silent in the live ISO

> ⚠️ **Session 16 addendum — the event numbers below are LIVE-ISO ONLY.** On the
> installed system the same roles sit on different nodes: buttons on `event6`
> (not `event5`), trackpads on `event5` (not `event4`), the real gamepad on
> `event7` (not `event11`), and the device is named **`"Steam Deck"`**, not
> `"Steam Deck Controller"`. Anything hardcoding these numbers binds the wrong
> device. `src/deck-input-mapper.py` selects by *capability* (`BTN_SOUTH`),
> which is why it is unaffected. Full enumeration:
> `docs/findings/hardware-parity.md`.

Measured 2026-08-10 (`docs/findings/P15-live-iso-recon.md` §R-8). With Steam not
running, the Deck's controller firmware is in **lizard mode**, and lizard mode
is **exclusive, not additive**:

- Buttons emit **only** on the keyboard-emulation node (`event5`): A → `KEY_ENTER`,
  D-pad Up → `KEY_UP`. Trackpads emit mouse motion on `event4`. Touchscreen works.
- The real gamepad node (`event11`, the one carrying `BTN_SOUTH`) emits
  **nothing at all** — zero events across a 90-second capture with six button presses.

**Why this matters:** `src/deck-input-mapper.py` selects its device by testing
for `BTN_SOUTH` (`src/deck-input-mapper.py:177`), i.e. exactly the dead node. In the
live ISO it would open a pad and then block forever on a device that never
sends an event — succeeding silently while doing nothing, the failure mode
`CLAUDE.md` explicitly forbids. The T2 spike could not have caught this: it
drove a virtual uinput pad, with no Valve firmware in the loop to divert the
events.

**Upside:** the live ISO is *already* controller-navigable for free — mouse,
Enter, arrows, touchscreen — so T4's installer may not need a mapper to be
operable at all. Text entry (the Wi-Fi passphrase) remains the real gap.

**Decide before writing T4 code:** use lizard mode and map only what it
cannot express, or suppress it (via `hid-steam`'s hidraw behavior —
unverified) and lose the free mouse/keyboard. Recommendation in the finding:
use it.

> ### 🆕 Session 17 measured the whole map, on the installed system, with a human
>
> `docs/findings/P17-input-and-osk.md` R-29…R-31. Three things this section could
> not say:
>
> 1. **Lizard mode holds on the installed system too**, not just the live ISO —
>    and it swallows **X, Y, L1, R1, STEAM and QAM entirely**. Those six report
>    on **no evdev node at all**, so no user-space program can recover them.
> 2. **It gives Enter, Esc, Tab, arrows and both mouse buttons — but NO Space.**
>    `Y → KEY_SPACE` (archinstall's multi-select toggle) is precisely what the
>    mapper exists to add, so "already navigable" is true for movement and
>    confirmation and **false for toggling**.
> 3. **The suppression question is answered and no longer "unverified":**
>    `/sys/module/hid_steam/parameters/lizard_mode` is a documented, writable
>    module parameter. `N` silences the emulated nodes and makes `event7` fully
>    live, including the six swallowed buttons. It does **not** persist across a
>    reboot.
>
> So the decision above is now a real trade with both sides measured: keep
> lizard mode and lose Space, or drop it and lose the free pointer, making the
> mapper the *only* input path. **The mapper must be proven working before
> anything sets `lizard_mode=N`,** or the device is uncontrollable without SSH.

### 5.10 ✅ Steam's "Switch to Desktop" menu item — **RESOLVED 2026-08-10, proven on hardware**

**Closed by session 15.** With a signed-in Steam, Power → **Switch to Desktop**
is present, Steam invokes our shim, and the switch completes into Omarchy.
Details: `docs/findings/P2-steam-integration-and-rotation.md` §R-23.

There were **two** independent causes, not the one §5.10 assumed:

1. **Steam was stuck in OOBE** behind §5.14's updater error, which reduces the
   Power menu. The hypothesis was right, and fixing §5.14 released it.
2. **The shim was unreachable anyway.** The Steam runtime narrows `PATH` to
   exactly `/usr/bin:/bin` (`SYSTEM_PATH` unset, so the `${PATH}` fallback
   applies). `/usr/local/bin` — where the shim lived since P1.5 — is not on it.
   This answers R-18a's open question: the shim **had** to move to `/usr/bin`,
   and "Switch to Desktop" could never have worked before, menu item or not.

Also confirmed: **Steam passes `plasma`, not `desktop`** (SteamOS's desktop is
KDE). `deck-session-select` already handles `desktop|plasma|omarchy`, so this
worked by design — do not "simplify" that case away.

⚠️ Exercising this path also exposed §5.16, which could leave the Deck with no
session at all. Read that before treating the switch as robust.

### 5.11 🟡 Rotation — desktop and greeter FIXED; Limine menu and TTY still open

`fbcon/rotate` is **0** on stock Arch *and* on Neptune, so no kernel this
project ships corrects the panel and the fix is per-surface, in userspace.

| Surface | Status | Fix |
|---|---|---|
| Limine menu | 🟡 **fix identified, NOT applied** | `interface_rotation: 270` — Limine ≥ v10; Deck runs **12.5.2**. Boot-chain change, held for approval. See below |
| Console / TTY | ❌ rotated | `fbcon=rotate:1` on the cmdline — boot-chain change, **held for operator approval** |
| SDDM greeter | ✅ **fixed, seen** | `stage-greeter-rotation` in `src/deck-session.sh` |
| Omarchy / Hyprland | ✅ **fixed, seen** | `~/.config/hypr/monitors.lua` |
| Gaming Mode | ✅ correct | none needed — gamescope handles it |

**Three corrections to what was recorded here** (details:
`docs/findings/P2-steam-integration-and-rotation.md` §R-24):

- **The transform is 3 (270°), NOT 1.** `transform,1` renders the desktop
  **upside down**. The old value was inference, never checked against a screen.
- **The syntax was 3.x.** Omarchy 4.0 configures Hyprland in **Lua**
  (`~/.config/hypr/monitors.lua`, `hl.monitor({…})`); the recorded
  `monitor = eDP-1,…` line would not have parsed. Hyprland 0.56's Lua parser
  also **rejects `hyprctl keyword`** — use `hyprctl eval 'hl.monitor({…})'`.
- **NEW, a second display defect:** Omarchy's `scale = "auto"` resolves to **2**
  on this panel, leaving a **640×400 logical desktop**. Now **1.25** (1024×640,
  divides 1280×800 evenly). `GDK_SCALE` went 2 → 1 to match, or GTK apps render
  ~2.5× and clip.

### The Limine menu CAN be rotated — `interface_rotation` (session 16)

§5.11 recorded "no known fix yet". There is one. Limine has a global
**`interface_rotation`** taking `0`, `90`, `180`, `270`, default `0`, which
rotates the menu/editor/console **only** — it does not affect the booted OS.
It needs **Limine ≥ v10**; the Deck runs **12.5.2**, and other `interface_*`
globals are already in its config, so the option is available today.

```
interface_rotation: 270
```

`270` to match the desktop's `transform 3`. ⚠️ **Unverified against a screen** —
§5.11's whole history is a recorded transform value that turned out upside down,
so treat the number as a hypothesis until someone looks at the panel.

**⚠️ NOT APPLIED.** Editing `/boot/limine.conf` is a boot-chain change, and this
project holds those for operator approval (same rule as `fbcon=rotate:1`).

**Where it has to go, which is the non-obvious part.** Three things write that
file:

| Writer | Behaviour |
|---|---|
| `limine-entry-tool` (binary) | manages **entries** and `default_entry`; leaves other globals alone |
| Omarchy theming | writes `interface_*` / `term_*` globals |
| **`omarchy refresh limine`** | **`mv`s `/boot/limine.conf` aside and copies `/usr/share/omarchy/default/limine/limine.conf` over it** — a hand edit is destroyed |

So a hand edit to `/boot/limine.conf` survives kernel updates but **not**
`omarchy refresh limine`. For the product, **T5 must bake `interface_rotation`
into the image**, exactly as it must for the desktop's `monitors.lua` below —
same class of problem, same fix.

⚠️ **The desktop half is per-user config** (`~/.config/hypr/monitors.lua`), so it
is currently fixed only for `deck` on the test Deck. **T5 must bake it into the
image** — `/etc/skel/.config/hypr/` or an Omarchy default — or a fresh install
comes up rotated again.

### 5.12 The 4.0 installer defaults to FULL-DISK ENCRYPTION

Left unchanged, our fork ships a device that **stops at a passphrase prompt
with no keyboard** — unbootable for its intended user, and contradicting
`CLAUDE.md`'s controller-only rule. Recommendation: default OFF, treat TPM2
auto-unlock as a follow-on, not a release blocker. §R-11.

Upstream's installer is fully driveable from a config file, and accepts
`--authorized-keys-file` / `--tailscale-authkey-file` — a better T5
integration point than post-install scripting, and it makes automated QEMU
install testing tractable.

### 5.13 ✅ `stage-repos` repo ordering — AUDITED and RESOLVED 2026-08-10

Valve's repos are appended **after** `[extra]`, and pacman resolves `-S <name>`
by **repo order, not version**, so `pacman -S gamescope` installs Arch's build
(bare compositor) instead of Valve's (the whole SteamOS session). The defect is
real. The proposed fix — Valve's repos first, matching SteamOS — is **rejected
on measured evidence**. Full data: `docs/findings/P16-repo-overlap-audit.md`.

**101 package names overlap; Valve's is OLDER in 50 of them**, including
`filesystem` 2021.12.07 (vs 2025.10.12), `linux-lts` 5.15.74 (vs 6.18.43),
`plymouth` 22.02 (vs 26.134), and the whole `mesa`/`vulkan-*`/`lib32-vulkan-*`
stack — the three suspects this section named all confirm. Decisively: the test
Deck runs **Arch's** `mesa` and `vulkan-radeon` and Gaming Mode works, so
Valve's are not merely riskier, they are unnecessary.

**The blast radius is one package.** Everything `omarchy-deck-kernel.sh`
installs (`linux-neptune-611`, its headers, `linux-firmware-neptune`,
`steamdeck-dsp`) is **Valve-only**, so order never affected it. Of the 51
"Valve newer" overlaps, nearly all are Valve rebuilds of identical upstream
versions (`systemd 261.2-1.1` vs `261.2-1`); only **`gamescope`** differs in
substance (Valve `3.16.25-3` ships the session, Arch `3.16.25-1` does not).

**Fix adopted: qualify the package, do not reorder repos.**

```bash
pacman -S jupiter-staging/gamescope     # not: pacman -S gamescope
```

⚠️ Valve's gamescope is *newer* and pacman still picks Arch's — order beats
version. Don't conclude from "Valve's is newer" that the bug can't bite.

Two follow-ons: **`mangohud` should come from Arch** (its `0.8.4-1` is newer
than Valve's `0.8.3…-4` and already ships `/usr/bin/mangoapp`, verified on the
Deck); and `deck-session.sh`'s precondition already catches the wrong build,
because it tests for the session *file*, not a version — the two builds share
an upstream version, so a version check could not tell them apart.

### 5.14 ✅ Gaming Mode's update check — **RESOLVED 2026-08-10 with a stub**

**Closed by session 15.** Operator chose the stub option. Steam's log now reads
`steamos-update check … returned: 7` → **`up to date`**, and the false network
error is gone. Details: `docs/findings/P2-steam-integration-and-rotation.md`
§R-21.

**Two corrections to what was recorded here:**

- Steam does **not** resolve this through `PATH`. It calls the absolute path
  `/usr/bin/steamos-polkit-helpers/steamos-update`, so a stub in
  `/usr/local/bin` would have installed cleanly and changed nothing.
- **`steamos-customizations-jupiter` would not have supplied it.** That package
  *is* available in `jupiter-staging`, but ships **zero** polkit helpers — it is
  GRUB machinery. The reasoning here named the wrong package.

⚠️ **Exit codes are a protocol, and 0 is dangerous.** `check` must exit **7**
("up to date"); **the apply path must NOT exit 0** — Steam reads 0 as "an update
was applied" and **reboots the device**, once per OOBE pass. That happened once
on the Deck before it was caught. The stage now asserts apply is non-zero.

This closed only *one* helper. The wider surface is **§5.15**.

### 5.15 🟡 Steam's privileged-helper surface — the two user-visible ones are SHIPPED; the rest is deliberately skipped

**Updated 2026-08-10, session 16 (P2.0b).** `steamos-set-timezone` and
`steamos-priv-write` are now installed by `src/deck-session.sh`
(`stage-timezone-helper`, `stage-priv-write-helper`), both hardware-verified
with a real change and restore. The operator decided **not** to take
`jupiter-hw-support`, so the six `jupiter-*` helpers stay absent — none has a
user-visible effect yet, and `jupiter-fan-control` belongs to P2.3, which
needs per-item approval anyway.

⚠️ **The reasoning recorded below was wrong in a way worth keeping.** It said
the missing `steamos-priv-write` means "the Gaming Mode brightness slider does
nothing". **On the test Deck the slider works.** Steam does not give up when a
helper is missing — it falls back twice, measured from its own console log:

```
1.  /usr/bin/steamos-polkit-helpers/steamos-priv-write "<path>" "<value>"   -> 127
2.  echo "<value>" | sudo -n tee "<path>"                                   -> works
3.  sudo -n chmod a+w "<path>"                                              -> works
```

Tiers 2 and 3 succeed **only** because `/etc/sudoers.d/99-deck-testing` grants
`deck ALL=(ALL) NOPASSWD: ALL` — see §5.17. So the conclusion about the
*product* was right and the belief about the *present* was wrong, which is the
more dangerous half: anyone "verifying" this by moving the slider on this Deck
would have concluded there was no bug.

Tier 3 is also why `/sys/class/backlight/amdgpu_bl0/brightness` and
`/sys/class/leds/status:white/led_brightness_multiplier` are **mode 666**,
restamped every Gaming Mode start. That is Steam's doing, not a hand-edit.
Supplying tier 1 is therefore a **security** change as much as a feature: it
stops Steam reaching for blanket sudo and stops the `chmod`.

**The narrow grants are proven operative** — measured 2026-08-10 with
`99-deck-testing` temporarily removed (§5.17), so nothing else could have
authorized them. Both helpers still changed brightness and timezone, and
`steamos-priv-write` still refused `/etc/shadow` with real privilege on the
line.

Not whitelisted on purpose: **`/dev/drm_dp_aux0`**, which Steam asks to write
with an *empty* value. What that does is not understood, so the helper refuses
it loudly. Steam has been getting 127 for it all along and tolerates it.

<details><summary>Original §5.15 text (kept for the audit trail — its "the slider does nothing" premise is corrected above)</summary>

§5.14 was one symptom of something larger. Steam drives system functions through
helpers at **`/usr/bin/steamos-polkit-helpers/`**, invoked by **absolute path**.
That directory does not exist here, so every call returns 127. Fourteen are
compiled into the client; **eight were actually invoked** in one OOBE session.

The two with real user impact:

- **`steamos-priv-write`** — how Gaming Mode writes
  `/sys/class/backlight/amdgpu_bl0/brightness`. Its absence means **the Gaming
  Mode brightness slider does nothing**, and it explains why R-14a's "backlight
  comes up at 1%" cannot be corrected from the UI. Same root cause.
- **`steamos-set-timezone`** — called 28 times; OOBE's timezone picker silently
  fails. Probably a three-line helper (`timedatectl set-timezone`) and the
  cheapest real win here.

Also missing: `steamos-devkit-mode`, `jupiter-get-als-gain` (ALS),
`jupiter-dock-updater`, `jupiter-biosupdate`, `jupiter-fan-control`.

**What is available:** `jupiter-hw-support` (`jupiter-staging`) ships six of them
with Valve's own code — but it is 49 MiB download / 94 MiB installed and depends
on **plymouth** on a Limine-only system. The `steamos-*` ones are in no repo.

**Decision needed, not taken.** `steamos-priv-write` in particular is a root
helper that writes caller-supplied sysfs paths; Valve's whitelists them and ours
would have to. That is a security design, not a stub — and `jupiter-fan-control`
lands in P2.3, which requires per-item operator approval every time.

Full inventory and options: `docs/findings/P2-steam-integration-and-rotation.md`
§R-20.

</details>

### 5.17 🐞 NEW — `99-deck-testing` gives the desktop user blanket passwordless sudo, and it is masking real defects

`/etc/sudoers.d/99-deck-testing` contains:

```
deck ALL=(ALL) NOPASSWD: ALL
```

Owned by **no package** — a test-rig file, almost certainly added during P1.5
so the `tools/deck-sync.sh` SSH loop could run stages unattended. Two
consequences, and the second is the expensive one:

1. **It must never ship.** An ISO that grants its default user blanket
   passwordless root is not a product.
2. **It makes the test Deck more capable than the product, silently.** §5.15 is
   the worked example: Steam's `sudo -n tee` / `sudo -n chmod a+w` fallbacks
   work here and will not work on a shipped install, so a defect looks fixed
   when it is not. Anything verified on this Deck that touches privilege is
   suspect until re-checked without this file.

It also sorts **last** in `/etc/sudoers.d/` (`99-deck-testing` > `99-deck-…`),
and sudo takes the last match, so it overrides every narrow grant this project
installs — including the two from §5.15 and `99-deck-session-select`.

**Measured with it removed, 2026-08-10** (temporarily, with a `systemd-run`
deadman restore; operator-approved). This is the product configuration, and it
settles two things at once:

| Probe | Result | What it means |
|---|---|---|
| `sudo -n true` | ✅ refused | the blanket grant was genuinely gone, so the rest is meaningful |
| Steam tier 2, `echo V \| sudo -n tee PATH` | ✅ refused | **§5.15's product prediction is correct** — Steam's fallback dies, so without our helper the brightness slider really would do nothing |
| Steam tier 3, `sudo -n chmod a+w PATH` | ✅ refused | the world-writable sysfs nodes are a test-rig artifact, not a shipped one |
| direct write as `deck` (node reset to 0644) | ✅ refused | no ambient permission was masking the result |
| `steamos-priv-write` → brightness | **works** | authorized by `99-deck-priv-write`, nothing else |
| `steamos-set-timezone` → timezone | **works** | authorized by the narrow grant, nothing else |
| `steamos-priv-write /etc/shadow` | ✅ refused | the whitelist holds with real privilege on the line |

⚠️ The backlight node was reset to **0644** for that test and **left there** —
it is the correct mode, and with tier 1 answering, Steam no longer re-`chmod`s
it. If it is ever found at 666 again, Steam fell back, which means a helper
broke.

### ⚠️ A "narrower replacement grant" is IMPOSSIBLE — measured, 2026-08-10

This section used to say the fix was a narrower grant for `tools/deck-sync.sh`.
**It is not achievable, and the sudo audit trail proves it.** Distinct binaries
the install stages ran as root in one day:

```
install(81) test(69) tee(61) grep(29) systemctl(22) cat(22) snapper(18)
visudo(15) pacman(8) find(7) chmod(7) sed(6) rm(6) cp(6) mount umount passwd
```

and the destinations include **`/etc/sudoers.d/` itself**:

```
/usr/bin/install  /etc/sudoers.d/99-deck-priv-write
/usr/bin/install  /etc/sudoers.d/99-deck-session-select
/usr/bin/chmod    /etc/sudoers.d/99-deck-testing
```

A NOPASSWD grant on `install`, `tee`, `cp` or `chmod` with arbitrary arguments
**is** full root — it can write any file anywhere, including a new sudoers
drop-in. Granting the stage *scripts* instead is worse: they live in a
user-writable directory, so that is a one-line privilege escalation. The dev
loop legitimately needs root, and no honest narrowing exists. Saying so is more
useful than shipping something that only looks narrow.

**So the resolution is not a narrower grant; it is keeping this off the image.**

1. **`./deck-session.sh stage-audit-privileges`** — not in `INSTALL_STAGES`; a
   T6 release check. Reports every blanket grant and **fails** on any that is
   also passwordless. Against the Deck it reports `03_deck`
   (`deck ALL=(ALL) ALL`) as normal-and-password-required, and fails on
   `99-deck-testing`. ⚠️ Its first version failed on **both** — exactly the
   false positive that gets a release check ignored — so "blanket" and
   "passwordless" are deliberately separate predicates.
2. **T5/P2.7 must exclude it from the payload.** That is where the real guard
   belongs, because the ISO is what ships.

`deck` has a password set (`passwd -S deck` → `P`) and `03_deck` grants
`deck ALL=(ALL) ALL`, so removing the passwordless file is recoverable rather
than a lockout — it costs only the unattended SSH loop.

### 5.18 ✅ A failed session start dropped the user at a PASSWORD GREETER — RESOLVED 2026-08-10

Found by session 16's soak test, cycle 4 of 20. This is §5.16's failure in the
form a user actually meets, and it is worse than "no session": it is a login
screen that a controller cannot answer.

```
14:45:59.845  Session "omarchy.desktop" selected ... for VT 1
14:45:59.872  Authentication for user "deck" successful
14:45:59.996  Starting Wayland user session: "uwsm start -g -1 -e -D Hyprland ..."
14:46:00.000  Session started true
14:46:00.001  session closed for user deck        <- ONE MILLISECOND later
14:46:00.007  Auth: sddm-helper exited with 5
14:46:00.008  Adding new display...              <- the GREETER
```

Two independent faults, and both need fixing:

**(a) The incoming session dies because the outgoing one has not finished.**
`uwsm start … Hyprland` exited in ~1 ms. At the moment of failure seat0 still
carried a leftover `deck` user session plus its user manager alongside the new
greeter. `render_restart_helper`'s settle step waits for
`loginctl show-seat seat0 -p Sessions` to empty, which is **not the same thing**
as the user's systemd manager and `uwsm` having finished — so the settle can
report "free" while the previous graphical session is still unwinding.

**(b) SDDM then shows the greeter instead of retrying, because
`Relogin=false`** — the shipped default, in
`/usr/lib/sddm/sddm.conf.d/default.conf`. Autologin fires once; if that session
dies, the user gets a password prompt. On this device that is unrecoverable
without a keyboard, which violates `CLAUDE.md`'s controller-only rule.

(b) is the safety net and the more important half: fixing (a) makes the failure
rarer, but only (b) decides what the user sees when it still happens. Operator
chose `Relogin=true` — the same posture already taken in
`stage-sddm-resilience`, a loop that can still recover beating a dead end that
cannot, with Ctrl+Alt+F2 as the dev escape.

**Status: RESOLVED.** Three 20-cycle soaks, measured by autologin attempts —
the only metric that shows the failure, since `Relogin=true` hides it from
everything else:

| | attempts / 20 switches | |
|---|---|---|
| original | **600** | thrash on 5 of 20 cycles |
| after the comm-name fix | **283** | bimodal: 16 clean, 2 thrashing (104, 155) |
| **after R-28's user-manager gate** | **20** | **every cycle at exactly 1 — the ideal** |

The middle row was the diagnostic clue: bimodal, not a spread, so a switch
either landed first time or fell into a distinct ~30 s state — a failure *mode*,
which is what led to R-28.

**What a switch costs now.** Settle times observed: **0.0 s on 17 of 20**, and
**52.7 / 52.8 / 53.3 s** on the three where Steam was genuinely still shutting
down. None reached the 60 s bound, so every wait was real rather than a timeout.
That is the deliberate trade: up to ~53 s of *waiting* instead of ~30 s of
*flickering*, and it is dominated by Valve's `steam-launcher.service`
`TimeoutStopSec=60`, not by anything this project controls.

⚠️ **A switch away from Gaming Mode can therefore take ~1 minute.** It is
correct and flicker-free, but it is not fast, and the cause is Steam's own
shutdown time. Worth revisiting in P2.4 if the shell can show progress.

⚠️ **The gate had a defect of its own, now fixed.** It listed `gamescope` as a
process name. The kernel truncates `comm` to 15 chars and `pgrep -x` matches
`comm`, so inside a live gamescope session `pgrep -u deck -x gamescope` returns
**0** — the compositor is `gamescope-wl`, its launcher `start-gamescope`. That
half of the gate matched nothing and reported "settled" instantly. Correcting it
is what took 600 attempts down to 283. Names verified on both sessions:
`Hyprland`, `start-hyprland`, `uwsm` (desktop); `gamescope-wl`,
`start-gamescope` (gaming).

⚠️ **What the gate still misses.** It waits on
`loginctl show-seat seat0 -p Sessions` plus that `pgrep`. Neither sees:

- **Seatless leftover sessions.** During the thrash, `loginctl list-sessions`
  carried several `deck` sessions with seat `-`, which `show-seat seat0` does
  not report at all.
- **uwsm's state inside the user manager.** `user@1000.service` stays
  `active/running` across switches, and `uwsm start` is what exits immediately.

**Measured, so the next attempt does not repeat it:** `graphical-session.target`
in the user manager **flaps** across a switch (active → inactive → active within
~1.6 s), so it is not usable as a settle signal on its own. And "no session for
the user" can never be true while anyone is on SSH — the discriminator that does
work is **`Type=wayland`**, which excludes both the `manager`-class session and
`tty` (SSH) sessions.

**✅ Root cause identified — R-28.** `steam-launcher.service` (Valve's, shipped
with gamescope) is `PartOf=graphical-session.target` with **`TimeoutStopSec=60`**,
and Steam takes tens of seconds to exit. Both thrashing cycles show the same
user-manager signature: `Stopping Steam Launcher...` with **no matching
`Stopped` line and ~29 s of silence**, while every other unit stops in ~50 ms.
sddm has already restarted by then, so the new session's `uwsm start … Hyprland`
starts into a user manager still tearing the old session down and exits in ~1 ms;
`Relogin=true` then retries until the teardown completes.

That explains the bimodality (whether Steam exits promptly), the 30–40 s
duration, and why the settle gate did not help: `steam-launcher.service` is a
**unit in the user manager**, not a process or a logind session, so neither of
the gate's conditions can see it.

**✅ Fixed 2026-08-10 (session 16).** `render_restart_helper`'s settle gate got a
third condition: **no unit in the desktop user's systemd manager may be
`deactivating`**, asked generally rather than by name, via
`systemctl --machine=<user>@.host --user`. `VT_SETTLE_MAX` went 15 s → **60 s**
to match `steam-launcher.service`'s own `TimeoutStopSec` — giving up before
systemd does would hand the problem straight back to the autologin retry loop.

⚠️ Deliberately **not** shortening Valve's `TimeoutStopSec`: Steam is being given
that time to shut down cleanly, and cutting it trades a slow switch for possible
state corruption.

Both halves are now closed: (b) `Relogin=true` means a dead session can never
strand a controller-only user at a password prompt, and (a) the incoming session
no longer starts into a teardown.

⚠️ **This is why "it worked once" was never enough.** P1.5's R-18 and session
15's R-23 both took this switch successfully; the defect needed 4 cycles to
appear.

### 5.16 ✅ The session switch could leave the Deck with NO session — RESOLVED 2026-08-10

Found by taking the Gaming→Desktop path for real (§5.10). The switch left the
Deck with no graphical session, recoverable only via
`systemctl reset-failed sddm` **over SSH** — exactly what a controller-only user
does not have. In the product that is a black screen with no way back.

sddm ships `StartLimitIntervalSec=30`, `StartLimitBurst=2`, `RestartSec=100ms`.
Switching restarts SDDM while gamescope still holds VT1; the first attempt raced
that teardown (`HELPER_TTY_ERROR`), systemd retried 100 ms later — too soon for
the VT to be free — and two failures inside 30 s latched the unit to `failed`
**permanently**. A self-healing condition became unrecoverable because of a rate
limit.

**Root cause found and fixed, 2026-08-10 (session 16).** ⚠️ The mechanism above
is **incomplete and its fix rationale was wrong** — see `R-27`. The first
domino is the **stop timing out**: `TimeoutStopSec=5`, teardown measured at
5.008 s, so systemd SIGKILLed sddm and ran the start job **3 ms** later against
a VT the killed compositor still held. `RestartSec` never gated that start at
all — it came from an explicit `systemctl restart` transaction, and `RestartSec`
only spaces `Restart=always` auto-restarts. It also fired **at boot**, so it was
never switch-specific.

Now fixed in three parts: `TimeoutStopSec=30`; `systemctl restart sddm` replaced
by an explicit stop → settle → start in `render_restart_helper`; and that
sequence run from a `systemd-run` transient unit, since `KillMode=control-group`
kills a caller inside the session being torn down.

**Measured after the fix:** across ~14 switches, including a run that hammered
10 switches in 50 s, **zero stop timeouts and zero `start-limit-hit`**, and sddm
never latched — under abusive pacing it retried 11 times and recovered itself,
where the original defect needed `reset-failed` over SSH.

**Verified, 2026-08-10: the 20-cycle soak passed 20/20** after §5.18(b) landed —
`NRestarts=0`, `Result=success`, and across the whole run **zero
`start-limit-hit`, zero stop timeouts, zero `Failed with result`**. sddm never
failed as a unit. The first soak attempt got 3 cycles before §5.18 stopped it,
which is how that defect was found.

**§5.16 itself is closed.** What remains is §5.18(a)'s retry thrash, which is a
session-startup problem, not an sddm-restart one.

⚠️ **The verification has an honest limit:** the round trip afterwards passed
*without the race recurring*, so what is proven is that the latch is gone — not
that the recovery path was exercised. The race is intermittent; P1.5's R-18 hit
this same switch and never saw it. Treat the switch as "works, not yet proven
robust" until it has survived many cycles. §R-26.

### 5.2 T1's stock→Neptune conversion is ✅ VALIDATED (was: unvalidated)

**Closed 2026-08-10 by P1.5 phase E.** All ten stages ran on a genuinely
stock system — seven exercising their real path for the first time — and
checkpoint β passed: booted unattended into `neptune-611`, with
`LoaderEntrySelected` reading `Omarchy/linux-neptune-611` from the firmware
itself, and `reconcile` exiting 0 writing nothing. The pacman hook also held
`default_entry` across an unrelated package install that rewrote
`limine.conf` — an unplanned early pass of P3.3. §R-13.

<details><summary>Original statement of the gap</summary>

The operator's Deck was converted by hand months earlier, so **seven of the ten
stages have only ever run their no-op path**. The actual conversion — removing Arch's
split `linux-firmware-*` and swapping in Valve's, and cycling the ESP mount on a
live system — remains VM-only evidence. Biggest remaining hardware gap for T1.

**Closes by design in `docs/ROADMAP.md` P1.5:** the fresh Omarchy 4.0 install is a
stock-kernel system, so running `src/omarchy-deck-kernel.sh` on it exercises the
real conversion path end to end.

Related: bumping the Neptune pin (`NEPTUNE_SERIES_DEFAULT=611`; `618` is the
newest non-RC series) is a one-line change but should not ship without a
hardware boot test.

</details>

### 5.3 The test Deck is not running the target OS — ✅ RESOLVED

**Closed 2026-08-10.** P1.5 wiped the 3.8.4-from-git install (and with it the
DeckShift hand-edits) and installed package-based Omarchy 4.0
(`4.0.0.r1617.g6d7826d`). Target and test asset now agree.

### 5.4 T0's two remaining gaps

- ~~**Ventoy USB setup has never been executed.**~~ ✅ **Closed 2026-08-10** —
  Ventoy 1.1.17 on the stick, ISO copied and sha256-verified after `sync`,
  booted on the Deck through the firmware boot picker.
- ~~**`tools/deck-sync.sh` has never run against real hardware.**~~ ✅ **Closed
  2026-08-10** — it drove all ten kernel stages and all five session stages
  over SSH in P1.5. `ssh steamdeck` resolves via a `~/.ssh/config` alias on
  the dev machine, matching the script's `DECK_HOST`/`DECK_USER` defaults.

### 5.5 Untouched risk items from the original plan

- **LCD Steam Decks are entirely untested.** Only OLED hardware exists. Gate
  LCD-divergent paths on model detection and ship "OLED-verified, LCD-untested"
  rather than claim support.
- **Trademark / redistribution** — ✅ **checked 2026-08-10**,
  `docs/findings/P16-redistribution-and-trademark.md`. Two results:
  **(a) `steamdeck-dsp` is `Proprietary` and ships no licence text**, and
  `omarchy-deck-kernel.sh` installs it — so an ISO that *bundles* Valve packages
  would redistribute a proprietary blob. It is the Deck's speaker tuning, so
  dropping it is not free. **The question is contingent on a T5 decision:
  bundle (→ blocked) vs fetch from Valve's mirror at install time (→ nothing is
  redistributed). §2.2 retired the offline constraint, so fetch is now
  available and is the recommendation.**
  **(b) The Steam Deck logo is unambiguously out**; Valve's guidelines scope
  themselves to partners under contract and forbid combining the logo with
  other words or graphics. Draw our own button glyphs for T4 rather than using
  Valve's. Descriptive use of the words is an operator judgement call; keeping
  "Steam Deck" out of the project *name* is recommended, and the project is
  already "Omarchy Deck". A README affiliation disclaimer is the cheap fix.
- **Recovery path documentation** — 🟡 **drafted 2026-08-10: `docs/RECOVERY.md`.**
  Written from Valve's published instructions (official image source, Rufus/dd,
  **Volume Down + Power** to reach the boot manager, full reimage to undo this
  project). ⚠️ **Not yet exercised by this project** — `docs/ROADMAP.md` P3.1
  performs a real factory reset and should replace it with a first-hand account.
  Exact recovery-menu option names are deliberately not quoted: they change
  between image revisions, and a stale label is worse than describing the
  intent. Carries the affiliation disclaimer from
  `docs/findings/P16-redistribution-and-trademark.md`.

### 5.6 One upstream draft staged and held

`docs/drafts/upstream-esp-permissions-omarchy.md` (against `basecamp/omarchy`) is
fully drafted, reviewed, and **deliberately unsent** by operator choice. It is
kept because its bug is one this project actively works around — when upstream
fixes it, `stage_esp_permissions`'s loosening can be revisited.

The five `deckarchy` bug reports and the `28allday` outreach draft were
**removed from the tree 2026-08-10** (recoverable from git history): the
project moved fully past deckarchy, and the outreach's premise died with the
DeckShift drop (§2.4). Nothing has ever been posted anywhere.

---

## 5.19 Phase 4 — the Deck enablement layer (added 2026-08-10)

Operator direction, session 16: after phase 3 releases one Deck-ready distro,
generalise the result so making the *next* distro Deck-ready is roughly a day of
Claude-assisted porting plus a hardware validation pass.

Spec: `docs/tasks/T7-enablement-layer.md`. Ordering: `docs/ROADMAP.md` phase 4.
Why a flasher was reframed rather than adopted:
`docs/findings/P16-scope-flasher-vs-layer.md`.

**The sizing that shaped it**, measured rather than estimated:

| | distro-specific |
|---|---|
| `src/omarchy-deck-kernel.sh` | **26%** of code lines |
| `src/deck-session.sh` | **13%** |
| `src/deck-input-mapper.py` | **0%** |

⚠️ The percentages *understate* the lock-in: the portable remainder is
scaffolding around a distro-specific core (`pacman`, `jupiter-staging`,
`limine`, `mkinitcpio`, `sddm`, `uwsm`). You would not port that core; you would
rewrite it. What is genuinely portable is the five `render_*` helper bodies, the
session-switch *policy*, the mapper, the probes — and §7's 38 facts, which are
the single biggest accelerator and are not code at all.

⚠️ **"A day" buys ported-and-conformance-green, NOT shippable.** §5.18 surfaced
on soak cycle 4; §5.16 needed a journal read across two boots; three of this
project's own checks were wrong about themselves. Soak time is wall-clock.

**Deliberately out of scope: hosting or distributing distro images.** That
reopens `steamdeck-dsp` (`Proprietary`, no licence text) as redistribution at
scale, and Bazzite/ChimeraOS already ship Deck-ready images. The differentiated
thing here is the **controller-only install** and the layer beneath it.

---

## 5.20 ✅ The OSK works on text focus — RESOLVED 2026-08-10, one GSettings key

**Answered on hardware (session 17), seen on the screen.**
`docs/findings/P17-input-and-osk.md` R-35. This was session 16's open
"needs eyes" item.

```bash
gsettings set org.gnome.desktop.a11y.applications screen-keyboard-enabled true
```

Ships **`false`**. `squeekboard` uses it as its auto-show gate, so nothing else
being correct matters until it is set. With it `true`, focusing a text field
pops the keyboard.

**T5 must bake this into the image**, alongside the rotation and the
`org.gnome.desktop.input-sources` setting — three GSettings/dotfile values that
currently live in one user's session and are all load-bearing.

⚠️ **This was first recorded here as a NEGATIVE ("does not appear on focus"),
and that was wrong.** Four conditions were tested — stock session, `fcitx5`
stopped, startup ordering corrected, `GTK_IM_MODULE=wayland` — and all of them
sat downstream of the same unexamined gate. **Four experiments sharing a hidden
precondition are one experiment.** A `WAYLAND_DEBUG=1` trace showed the whole
chain had been working the entire time: GTK binds `zwp_text_input_manager_v3`
and calls `enable()`, Hyprland sends `enter`, and squeekboard receives
`zwp_input_method_v2.activate()`. The trace cost minutes, needed no operator,
and should have come before the fourth button-press experiment.

Two facts recorded on the way:

- **Omarchy 4.0 ships and runs `fcitx5`** (`INPUT_METHOD`/`XMODIFIERS`/
  `QT_IM_MODULE` = `fcitx`). It does **not** block squeekboard, and it
  **respawns within a second of being killed** — anything assuming it stays
  dead is wrong.
- **`sm.puri.OSK0`'s `SetVisible` also works**, so explicit show/hide is
  available where a screen wants it rather than focus.

**Valve's own OSK: tested, and it works in Desktop Mode** (R-35b). Steam runs
fine on Hyprland via XWayland, and **STEAM+X summons Valve's keyboard** — seen
on screen. But it is **summon-only, never focus-triggered**, and the live ISO
has no Steam at all, so **the installer can never use it**. Gaming Mode already
has it for free, being Valve's own session.

⚠️ **It is an either/or, not a free upgrade** (R-37). Running Steam on the
desktop makes Steam take the controller — the native pad node is replaced by
`Microsoft X-Box 360 pad 0` — and **`deck-input-mapper` re-bound itself to that
virtual pad**, so one press would drive Steam's UI *and* inject a keystroke.
**T3/T4 owe the mapper a "Steam is running" policy**; nothing currently stops it
binding Steam's virtual pad.

---

## 6. Blocked on human

- **`docs/ROADMAP.md` P1.4 — Ventoy on the test USB + the stock Omarchy 4.0 beta
  ISO.** `ventoy-bin` is not installed on the dev machine. The ISO can be
  downloaded, or built locally (a real build already succeeded in session 2 —
  remember `--network host`).
- **`docs/ROADMAP.md` P1.5 — the Deck recon + rebuild session.** Needs the
  operator present, a USB keyboard for the dev-time install, the Valve
  recovery image on a second USB as the floor, and anything personal copied
  off the Deck first. Approved in principle by §2.5; still confirm before
  executing.
- **Any write to the physical Deck.** Prepare, describe, wait. Batch requests.
- **Anything touching TDP, fan curves, or charge limits** — every time, no
  exceptions. Genuine hardware-damage risk.
- **Any public action** — repos, upstream issues, outreach. One draft staged
  (§5.6).

Retired from this list 2026-08-10: "do not wipe the Deck" (superseded by
§2.5's planned-rebuild posture), the DeckShift manual removal and its `/tmp`
backup rescue (the rebuild wipes both).

---

## 7. Don't re-derive — each of these cost real time

- **The Deck's d-pad arrives as `BTN_DPAD_*` key events, never as `ABS_HAT0X/Y`.**
  `hid-steam` *advertises* the hat axes and never sends them. Anything handling
  only the axes silently ignores the d-pad — which is exactly what shipped
  (§R-33). Check what a device **sends**, not what it advertises.
- **`hid-steam` uses Nintendo-style button codes:** physical **X** is
  `BTN_NORTH`, physical **Y** is `BTN_WEST`. The kernel's own aliases confirm it
  (`BTN_NORTH/BTN_X`). This looks inverted beside the Xbox convention and will
  invite a "fix" that breaks it.
- **Lizard mode swallows X, Y, L1, R1, STEAM and QAM completely** — they appear
  on no evdev node. It provides Enter, Esc, Tab, arrows and both mouse buttons,
  but **no Space**. Suppress it with
  `/sys/module/hid_steam/parameters/lizard_mode` (writable, non-persistent).
- **An evdev node can be enumerated and permanently silent.** Counting nodes,
  `systemctl is-active`, and a log line naming the bound device all reported
  health while the mapper delivered nothing for an entire session (§R-31).
- **When probing input by hand, press a known-good button as a DELIMITER between
  test buttons.** A silent button leaves no marker, so an undelimited batch
  cannot attribute events to presses. A reliably emits `KEY_ENTER`.
- **`pkill -f <pattern>` over SSH kills its own shell** when the pattern text
  appears anywhere in the remote command line — including in a later argument.
  The `[p]attern` bracket trick fails too if the plain name appears again. Kill
  by PID, or put the `pkill` in its own invocation.
- **Unquoted heredocs execute backticks and `$(...)` at render time, as root.**
  `deck-session.sh` shipped a comment that really ran `uwsm start ... Hyprland`
  during a stage install (§R-36). Escape them; `shellcheck` catches it (SC2006).
- Docker's default bridge network is throttled to ~2 KB/s on the operator's dev
  machine. Use `--network host` for any Docker-based tooling there.
- `mount -o remount` does **not** re-apply `fmask`/`dmask` on vfat. A full
  `umount`/`mount` cycle is required.
- `pacman --noconfirm` answers **No** to conflict questions. The firmware swap
  needs `--ask=4` (`ALPM_QUESTION_CONFLICT_PKG` only, not a blanket yes).
- Valve's kernel packages ship **no mkinitcpio preset and no `/boot/vmlinuz-*`**
  at all — only `usr/lib/modules/<kver>/{pkgbase,vmlinuz}`. `docs/PLAN.md` §8.3's
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
- **Limine honours the entry-path form of `default_entry`** — proven by boot,
  not inference (`test/vm/vm-default-entry-test.sh`): a planted *non-first* path was
  both selected and booted. Limine implements the systemd Boot Loader
  Interface, so the selected entry is readable at
  `/sys/firmware/efi/efivars/LoaderEntrySelected-4a67b082-…` (UTF-16LE,
  4-byte attribute prefix) — assert on that, never screen-scrape a menu.
- `snapper --no-dbus` makes create-config/create/list work in a chroot, and
  `limine-snapper-sync` runs chrooted too — but only after
  `systemd-machine-id-setup`, because it namespaces its ESP history dir by
  machine-id.
- Docker containers get a tmpfs `/dev` with no udev, so `losetup -P` publishes
  partitions under `/sys/block` but creates no `/dev/loopNpM` nodes — `mknod`
  them from sysfs. Relatedly, `genfstab -U` silently emits `/dev/loop0p1` when
  udev never populated `/dev/disk/by-uuid`.
- Put `console=ttyS0` **last** in a QEMU kernel cmdline, or systemd's boot
  output goes to a VGA framebuffer no harness is capturing.
- **A CI glob that matches nothing passes.** `shellcheck *.sh` at the repo
  root went from checking every script to checking none the moment the repo
  grew directories — green, and testing nothing. Every discovery glob in
  `.github/workflows/ci.yml` now uses `git ls-files` and **fails when it
  finds zero files**.
- `shellcheck` resolves `# shellcheck source=` relative to its *working
  directory*, not the script. `.shellcheckrc` sets `source-path=SCRIPTDIR`
  so `../lib/foo.sh` means what it looks like it means.
- **The Deck's Wi-Fi chip is QCA2066 hw2.1**, firmware at
  `ath11k/QCA2066/`. It is *not* QCNFA765/`nfa765` — an earlier inference
  that happened to reach the right conclusion for the wrong reason.
- **Lizard mode is exclusive.** With Steam not running, Deck buttons emit on
  the keyboard-emulation node only; the `BTN_SOUTH` gamepad node emits
  nothing. Any code selecting the pad by `BTN_SOUTH` gets a dead device.
- **The upstream Omarchy ISO's pacman is offline-only** — a single
  `[offline]` repo at `file:///var/cache/omarchy/mirror/offline/`, no network
  mirrors. `pacman -Sy <anything not baked in>` fails even with working
  internet. Whatever the live environment needs must be *in the payload*.
- The Deck's DMI is `product_name=Galileo` (OLED). `amdgpu`'s ATOM BIOS
  string says `AMDSphJupiter` — that is a display-controller name, **not** a
  model indicator; do not read it as LCD.
- The live ISO has no `sof-firmware`, so `snd_sof_amd_vangogh` fails to load
  and there is likely no audio in the live environment.
- A `pgrep -f <pattern>` inside a shell whose own command line contains
  `<pattern>` matches itself and loops forever. Bit this session; use a
  pidfile or match more narrowly.
- **Steam's runtime PATH is exactly `/usr/bin:/bin`**, with `SYSTEM_PATH`
  unset. `/usr/local/bin` is unreachable from anything Steam invokes. Verify a
  shim with `env -i PATH=/usr/bin:/bin sh -c 'command -v …'`, never with
  `test -e` — the latter passes while Steam is blind to it.
- **Steam calls its privileged helpers by ABSOLUTE path**,
  `/usr/bin/steamos-polkit-helpers/<name>`. Two different resolution rules
  coexist: `steamos-session-select` via PATH, the helpers absolutely. Both end
  up needing `/usr/bin`.
- **`steamos-update` exit codes are a protocol.** `check` → **7** means "up to
  date"; **0 means an update is available**. On the apply path **0 makes Steam
  REBOOT** the device to "finish" the update, and during OOBE Steam calls apply
  without checking first — so 0 is a reboot loop. Use 7.
- **Steam passes `plasma`** to `steamos-session-select`, not `desktop`.
- **Omarchy 4.0 configures Hyprland in Lua**, not `.conf`
  (`~/.config/hypr/*.lua`, `hl.monitor({…})`, `hl.config({…})`). Hyprland 0.56
  **rejects `hyprctl keyword`** for Lua configs — "use eval"; the live path is
  `hyprctl eval 'hl.monitor({…})'`.
- **Hyprland silently discards a Lua config that fails to parse** — falls back
  to defaults, logs nothing past `[cfg] Config is lua, loading lua mgr`, exits
  0. Always `luac -p` a generated Hyprland config; the symptom otherwise looks
  like "the setting has no effect here".
- **The Deck panel's transform is 3 (270°). 1 is upside down.** And Omarchy's
  `scale = "auto"` picks **2** on it, leaving a 640×400 logical desktop; 1.25
  is the even divisor of 1280×800.
- **sddm's shipped unit is `StartLimitBurst=2` / `StartLimitIntervalSec=30` /
  `RestartSec=100ms`.** Two fast failures latch it to `failed` permanently,
  needing `systemctl reset-failed` — unreachable without a keyboard. Any code
  that restarts sddm has to account for this.
- On a **package-based** Omarchy install there is no `~/.local/share/omarchy/`.
  Defaults are in `/usr/share/omarchy/config/hypr/` and
  `/etc/skel/.config/hypr/`, and 4.0 ships Lua-aware agent guidance at
  `/usr/share/omarchy/default/agents/skills/omarchy/hyprland.md`. The
  locally-installed `omarchy` skill documents the 3.x git layout and is wrong
  for this system.
- `steamos-customizations-jupiter` **is** available in `jupiter-staging` and
  ships **zero** polkit helpers (it is GRUB machinery). It does not ship
  `steamos-session-select` either — no configured repo does. `jupiter-hw-support`
  ships six of the helpers, at 94 MiB installed and a **plymouth** dependency.
- **Steam FALLS BACK when a polkit helper is missing; it does not just fail.**
  For a privileged write it tries the helper, then `echo V | sudo -n tee PATH`,
  then `sudo -n chmod a+w PATH` so the next write needs no privilege at all.
  Measured from its console log. Two things follow: a missing helper can look
  like it is working (§5.15), and Steam leaves system nodes **world-writable**
  after every Gaming Mode start. Never conclude a helper is unnecessary because
  the feature works on the test Deck.
- **Steam's helper argv, measured, not inferred.** `steamos-set-timezone
  America/Chicago` (one positional). `steamos-priv-write "<path>" "<value>"`
  (two, quoted). It also calls `steamos-priv-write "/dev/drm_dp_aux0" ""` — an
  **empty** value — so any value validation must handle that case for real.
- **`src/deck-session.sh` is source-safe as of 08698ba** — `main "$@"` is guarded
  on `[[ ${BASH_SOURCE[0]} == "$0" ]]` so `test/unit/test-deck-session.sh` can
  source it and call `render_update_stub` / `assert_ours_or_absent` with no root,
  Deck or VM. **Consequence: anything added at TOP LEVEL below the constants
  executes at source time, inside the unit test.** Keep new work inside
  functions. A sourcing shell also inherits `set -euo pipefail` and every
  constant as `readonly`, so sourcing twice into one shell aborts.

---

## 8. Session log

One line each. Detail lives in git history and in the `FINDING-*.md` files.

| # | What happened |
|---|---|
| 1 | Bootstrap; T0 §1 harness + libraries + unit tests; T0 §2–6 (Ventoy doc, override loader, `tools/deck-sync.sh`, CI, shellcheck baseline) |
| 2 | T0 §1 verified end-to-end against a real ISO build; found two real bugs in this project's own harness |
| 3 | R1 §10.1/10.2/10.4/10.5 resolved; §10.6 drafted and held |
| 4 | T1 steps 1–2 — near-total rewrite of `src/omarchy-deck-kernel.sh`; four design premises were false |
| 5 | T1 step 3 — the pacman hook; found upstream already covers most of it, so ours verifies rather than generates |
| 6 | T1 steps 4+6 — nine independently runnable stages, provably non-interactive |
| 7 | First physical hardware run; two real bugs found; R1 §10.3 resolved; Steam/gamescope installed; prior-art check done |
| 8 | First Gaming Mode boot, via a DeckShift hybrid splice (since reversed — §2.3) |
| 15 | **Phase 2 opener, 2026-08-10.** §5.10 closed — Steam's own Switch-to-Desktop works, with **two** causes not one (OOBE, plus the runtime narrowing PATH to `/usr/bin:/bin`, which made the `/usr/local/bin` shim unreachable all along). §5.14 closed with a stub, after learning its exit codes are a protocol: apply exiting 0 made Steam **reboot the Deck**. §5.11's greeter + desktop fixed — transform is **3**, not the recorded 1, and Omarchy's `auto` scale left a 640×400 desktop. A `#` marker in a Lua file taught us Hyprland **silently discards** an unparseable config. Opened §5.15 (the whole polkit-helper surface, incl. brightness) and §5.16 (the switch latched sddm into permanent failure). |
| 17 | **The eyes-and-hands pass for input, 2026-08-10 — the first time any of this was seen on a screen.** Found the input mapper was a **complete no-op** on the desktop: `active`, correctly bound to `event7` by capability, and that node is **silent** because lizard mode routes buttons to the emulated nodes. P2.1's "verified on hardware" was true in every particular and proved nothing (4th instance of P16 §7's pattern). Underneath it, two real defects, each found only by correlating a human's press against what the kernel emitted: the **d-pad emitted nothing** (`hid-steam` advertises `ABS_HAT0*` and only ever sends `BTN_DPAD_*`, so the suite passed against a device model this hardware never produces), and **a resting analog stick cancelled every held direction in ~10ms**, killing auto-repeat, because two input sources shared one state slot. Both fixed, deployed and **verified by pressing the buttons** — hold tracks the physical button across 3.4s and auto-repeat measures exactly `REPEAT_DELAY`/`REPEAT_INTERVAL`. Measured the **full lizard-mode map**: it swallows X/Y/L1/R1/STEAM/QAM entirely and provides **no Space**, which archinstall needs (§5.9). Found `hid_steam`'s `lizard_mode` knob, so §5.9's "unverified" suppression question is answered. **§5.20 closed:** the OSK works on focus — but was **first recorded here as a negative** after four experiments that all sat downstream of one unexamined GSettings gate; a `WAYLAND_DEBUG` trace showed the protocol chain had been working the whole time. Also fixed an unquoted heredoc that **executed `uwsm start ... Hyprland` as root** at render time and had left **CI red** while this file claimed shellcheck passed. Reverted session 16's display-always-on. |
| 16 | **P2.0b + P2.0c, 2026-08-10.** `steamos-set-timezone` + `steamos-priv-write` shipped as two new `deck-session.sh` stages, both signatures **read from Steam's log** rather than inferred, both hardware-verified with a real change and restore. Operator skipped `jupiter-hw-support`. Corrected §5.15: the brightness slider **works** on this Deck — Steam falls back to `sudo -n tee` and then `sudo -n chmod a+w`, which is also what makes those sysfs nodes 666. Opened §5.17 (`99-deck-testing`'s blanket NOPASSWD masks privilege defects and must not ship). Then **P2.0c**: §5.16's real cause was the **stop timing out** (`TimeoutStopSec=5`, teardown 5.008s → SIGKILL → start 3ms later), not the retry spacing — R-26's `RestartSec` rationale was wrong, and it fired at **boot**, not only on switches. Fixed with `TimeoutStopSec=30` + stop→settle→start in a `systemd-run` transient unit; **20/20 soak clean**. The soak also found **§5.18**: a dead session lands on a password greeter, because SDDM ships `Relogin=false`. Then **P2.0e/§5.13**: the repo overlap was **audited** (101 collisions, Valve older in 50 -> reordering rejected; the fix is `pacman -S jupiter-staging/gamescope`), and the suite's last blind spot closed. Two defects were introduced by this session's own fixes and caught by mutation testing and soaking, not review -- a settle gate matching the comm name `gamescope`, which no process has. Unit suite 17 -> **62 assertions**, mutation-tested **39/39**. Closed 5.11/5.13/5.16/5.18, answered 5.5/5.17, shipped P2.1 + P2.2's programmatic half, drafted `docs/RECOVERY.md`. **Operator added phase 4** (the enablement layer) and a Deck-specific flasher was considered and reframed. |
| 9 | **One long session, 2026-08-09/10 — the scope reset and all of phase 1's non-hardware work.** Five scope decisions (§2): the ISO is the deliverable again, network-at-install is fine, target 4.0, DeckShift dropped, Deck rebuilds allowed. Docs consolidated (`PROGRESS` 1403→~600 lines, `WHERE-WE-ARE` folded in, `PLAN` frozen with a known-wrong-sections banner); `docs/ROADMAP.md` written (three phases); dead drafts removed. **P1.1:** `stage-default-entry` with the path form *proven by boot*, substrate rebuilt with real snapper snapshots (which immediately caught the hook test's own substring miscount), three deliberate-failure tests. **P1.2–P1.3:** T2 spike resolved — a gamepad drives `gum` and `archinstall` at the kernel input layer, so T4 is days not weeks. **P1.4 (half):** 4.0 beta ISO built; static inspection decided T4's OSK question and found the OLED Deck's `nfa765` Wi-Fi firmware present (§5.1). Repo reorganized out of the flat layout (a root `*.sh` glob had silently gone from checking every script to none). |
