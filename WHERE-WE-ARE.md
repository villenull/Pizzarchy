# WHERE WE ARE — Pizzarchy / Omarchy Deck

**Written 2026-08-09, after session 7.** Self-contained on purpose: you can
read this without access to the repo. Where it matters, the underlying
evidence lives in `PROGRESS.md` (1,200+ lines of findings) and `PLAN.md` (the
963-line original plan), but you should not need either to follow this.

---

## 1. What the project is

A **Steam Deck–native installer for Omarchy Quattro** (Omarchy 4.x, a
Hyprland-based Arch desktop). The goal: one bootable USB that installs a
fully hardware-optimized Arch + Omarchy system **entirely offline**,
navigable start-to-finish using only the Deck's buttons and trackpads — no
keyboard, no terminal.

After install, the Deck should behave like stock SteamOS: boots to **Gaming
Mode**, all hardware works, and a **Desktop Mode** button drops into a full
Omarchy desktop with a way back.

**Why it exists:** the operator did this install by hand once and hit roughly
a dozen distinct bugs — an upstream script that printed success while doing
nothing, a bootloader with no kernel entry, a mkinitcpio preset pointing at a
nonexistent path, an AUR helper conflict, ESP permissions silently breaking
Omarchy's own tooling. Each was root-caused. The project is turning that
validated manual process into automation.

**Repo:** `villenull/Pizzarchy` (private, GitHub). Everything is flat in one
directory — no subdirectories, by rule.

---

## 2. Status at a glance

The plan decomposes into 8 tasks across a ~20-block schedule. **Three tasks
are done. Five have not started.**

| Task | Status | Notes |
|---|---|---|
| **T0** Test infrastructure | ✅ **Done** | QEMU install harness, CI, SSH iterate loop, unit tests. Two gaps below. |
| **R1** Six research questions | ✅ **Done** | All six resolved. Several overturned the plan. |
| **T1** Kernel / firmware / boot chain | ✅ **Done** | Now hardware-validated. Two bugs found on real hardware. |
| **T2** Gamepad input spike | ⬜ **Not started** | **This is the next block.** Sizes T4. |
| **T3** Gaming Mode + session switching | ⬜ Not started | Largest task. Needs T1 (done) + T0 (done). |
| **T4** Controller-only installer UI | ⬜ Not started | Blocked on T2's finding. |
| **T5** ISO + offline payload | ⬜ Not started | Blocked on R1 (done) — now unblocked in principle. |
| **T6** Integration + release | ⬜ Not started | Blocked on Omarchy Quattro going stable. |

Roughly **blocks 1–7 of ~20** are complete, plus one unplanned hardware
validation session.

---

## 3. What actually exists and works

**`omarchy-deck-kernel.sh`** (~1,400 lines) — the core deliverable so far.
Installs Valve's Neptune kernel and firmware, builds a UKI, registers a
Limine boot entry, prunes stale entries, installs a pacman hook, and fixes
ESP mount permissions. Nine independently runnable stages, idempotent, fails
loudly, shellcheck-clean.

**Test harness** — a QEMU-based unattended install tester, a purpose-built
Neptune substrate image builder, and three VM suites (33, 45, and idempotency
assertions). Plus `deck-sync.sh` / `deck-snapshot.sh` / `deck-rollback.sh`
for the SSH iterate-in-place loop.

**CI** — GitHub Actions, shellcheck + unit tests, **verified green on a real
run** as of session 7 (it had never actually run before).

**As of session 7, all of this has run on the physical Deck.** Nine stages,
exit 0, plus a reboot that came back on the Neptune kernel with audio, Wi-Fi,
Bluetooth, trackpads, gyro and GPU all working.

---

## 4. The findings that changed the plan

These matter more than the code. Several invalidated parts of the original
plan, and a future session that doesn't know them will waste real time.

### 4.1 The architecture in the plan was wrong

`PLAN.md` §4/§5 assumed `omarchy-iso` exposes `OMARCHY_INSTALLER_REPO` /
`OMARCHY_INSTALLER_REF` env vars to point the build at a forked installer
repo. **Those don't exist.** Omarchy installs as a *pacman package*, not a
git-cloned installer.

**Replacement architecture** (found in upstream's own in-tree precedents):
fork `omarchy-iso` for build-time changes, ship the Deck logic as **its own
pacman package** for install-time work, plus one `pre-refresh-pacman.d/` hook
for durability. That last hook is load-bearing — `omarchy-refresh-pacman`
silently overwrites `/etc/pacman.conf` wholesale, which would delete the
Valve repo entries.

### 4.2 Steam cannot work offline — the headline claim was reframed

Tested for real in a network-isolated VM: Steam fails fatally in under a
second with no network. Pre-populating the 2.5 GB client was also tested and
**does not rescue it** — it reaches a login screen and then can't log in.
Login requires network under any packaging strategy.

**Operator decision:** accept and reframe. The claim is now *"installs
completely offline; Steam signs in on first launch, exactly like a
factory-reset Deck."* This makes a controller-navigable **Wi-Fi screen shown
before Steam ever gets the display** a required, load-bearing item — without
it, a user with no Wi-Fi gets an undismissable Steam error dialog and no
keyboard to dismiss it. **Decided: ship only the 20 MB launcher, no
pre-populated client.**

### 4.3 The offline mirror can carry Valve packages — signing worry killed

No re-sign step needed. `omarchy-iso` already ships an unsigned third-party
kernel repo into its offline mirror by design. Two *new* risks instead: the
mirror is stored **uncompressed**, so every byte of firmware/Steam adds ~1:1
to ISO size; and the build has a hard package-count self-check (600–2000)
whose upper bound will need widening.

### 4.4 Gamepad mapping — resolved on hardware (session 7)

**Decision: ship a custom `uinput`/`evdev` mapper as a systemd user service**,
not the alternative of running Steam in the background to inherit Steam
Input's desktop layout.

The alternative was ruled out by a **circular dependency**, not a
measurement: it sources the on-screen keyboard from a signed-in Steam client,
Steam needs network to sign in, and the pre-Steam Wi-Fi screen needs an OSK
to type the Wi-Fi password. You'd need the keyboard to get the network that
provides the keyboard.

Verified on hardware: unprivileged `/dev/uinput` device creation works with a
udev rule (no privileged helper needed), controller read access already works
via seat ACLs, and Hyprland supports the protocols an on-screen keyboard
needs. **Use `squeekboard`** (in Arch `extra`) — the originally-suggested
`wvkbd` is AUR-only, and the project forbids auto-installing an AUR helper.

**Two errors in the prepared design were found only by running it:** a
systemd target that doesn't exist (`hyprland-session.target` — the real one
is `wayland-session@hyprland.desktop.target`), and `uaccess` not covering
`/dev/uinput`, meaning **the installer must add the user to the `input`
group**.

### 4.5 Secure Boot is a non-issue

Operator verified on their own Deck: boot order already defaults to Limine,
and the BIOS exposes no Secure Boot toggle at all. No pre-install BIOS step.

### 4.6 Two real bugs found by the first hardware run (session 7)

**Bug 1 — snapshot entries miscounted as duplicate boot entries.** The script
counted a UKI filename as a *substring* of the Limine config. Snapshot
rollback entries embed the same filename, so the count came back 2 instead of
1 and a correct boot chain was declared broken.

The trigger was **the safety snapshot the task's own procedure mandates** —
anyone following the documented steps hits it. Worse, the same faulty count
defeated the "already up to date" check, so the kernel image was **rebuilt on
every run** — inside a pacman hook, meaning a pointless boot-chain write on
every kernel change. The idempotency "proven" in VM testing was real in QEMU
and silently false on any real machine with a snapshot. **Fixed.**

**Bug 2 — nothing set the default boot entry.** The Deck defaulted to the
*stock Arch kernel*, not Neptune. The operator had been selecting Neptune by
hand without that being visible anywhere. Nothing in the toolchain owns this
value. On a fresh install an end user would silently boot the wrong kernel
with degraded hardware support and no error. **Fixed on the operator's Deck**
(now boots Neptune unattended); **not yet fixed in the script.**

---

## 5. Open issues

Ordered by how much they'd cost to discover late.

### 5.1 The VM test substrate has a blind spot — highest priority

The QEMU substrate creates **no snapper snapshot**, so the bootloader never
generates the snapshot menu entries that caused Bug 1. Three test suites
could not have caught it. **Any future "idempotency proven" claim inherits
this blind spot until the substrate creates a snapshot.**

### 5.2 The default-boot-entry fix isn't in the script

The operator's Deck is fixed by hand. The script still doesn't manage the
default entry. Needs a new stage that asserts the default resolves to the
pinned Neptune kernel and repairs it — keyed on a glob, not a hardcoded
index, and re-asserted by the pacman hook.

**Sub-issue:** the fix was written using Limine's documented *entry-path*
syntax (`Omarchy/linux-neptune-611`) rather than a numeric index. It works,
but it's **not proven that the path form is what did the work** — the target
entry is also entry #1, so a silent fallback to index 1 would look identical.
**Testable in QEMU, no hardware needed.**

### 5.3 The stock→Neptune conversion is still unvalidated on hardware

The operator's Deck was already converted by hand months before, so seven of
the nine stages only ever ran their **no-op path**. The actual conversion —
removing Arch's firmware packages and swapping in Valve's, and cycling the
ESP mount on a live system — remains VM-only evidence. This is the single
biggest remaining hardware-validation gap for T1.

### 5.4 ⚠️ The test Deck is not running the target OS

**The Deck runs Omarchy 3.8.4, installed from git — not Quattro/4.x.** There
is no `omarchy` pacman package on it at all. The project targets Quattro,
whose shell is a **from-scratch Quickshell rewrite**, meaning any shell-level
integration (the Desktop Mode icon, the Quick Access Menu hook — both core to
T3) cannot be meaningfully developed or tested on this machine as configured.

T1 was unaffected because it gates on *mechanism* (the Limine UKI tooling),
not on Omarchy's packaging. **T3 will not be so lucky.**

### 5.5 ⚠️ The test Deck has no Gaming Mode at all

Neither `steam` nor `gamescope` is installed; the only session is Hyprland.
So "does Desktop Mode conflict with Gaming Mode's Steam instance" and "does
the session switch work in both directions" are **currently untestable on the
only hardware available**. T3 is the task that most needs this, and it needs
it set up first.

### 5.6 T0's two remaining gaps

- **Ventoy USB setup has never been executed** (documented, not done). Needed
  for any real ISO testing in T5/T6.
- **`deck-sync.sh` has never run against real hardware.** Note this is now
  much cheaper to fix than when it was written — the Deck is reachable.

### 5.7 Untouched risk items from the original plan

- **LCD Steam Decks are entirely untested.** Only OLED hardware exists. The
  plan's rule is to gate LCD-divergent paths on model detection and ship
  "OLED-verified, LCD-untested" rather than claim support.
- **Trademark / redistribution** — "Steam Deck" and Valve iconography usage,
  and whether the ISO may redistribute Valve's kernel/firmware, were flagged
  as cheap-to-check-early and **have not been checked**.
- **Recovery path documentation** — how a user gets back to stock SteamOS.
  Flagged as an ethical baseline for a wipe-the-device project. Not written.

### 5.8 Upstream collaboration is staged but frozen

An outreach message to a related project's maintainer and five upstream bug
reports are **fully drafted and reviewed but deliberately unsent** — the
operator chose to hold indefinitely. Nothing has been posted anywhere.

---

## 6. What remains of the original plan

Mapped to the plan's own workstreams.

| Plan area | State |
|---|---|
| §6.1 / §6.1a Controller-only installer UI (8 screens) | **Not started.** Spec is complete and detailed. Scope depends entirely on T2. |
| §6.2 Offline package payload | **Not started.** Research done (§4.3); size budgeting and package enumeration remain. |
| §6.3 Kernel / firmware / bootloader | **Done and hardware-validated**, minus the default-entry stage and the conversion-path gap. |
| §6.4 Gaming Mode ↔ Desktop Mode switching | **Not started.** Biggest single chunk of remaining work. |
| §6.5 Hardware parity checklist (9 subsystems) | **Partially evidenced.** Session 7 spot-checked audio, Wi-Fi, BT, trackpads, gyro, GPU as *working*, but not as a formal parity pass. TDP/fan/thermal — **untouched, and gated behind explicit operator approval every time.** |
| §10 Six open research questions | **All resolved.** |
| §11 Long-term maintenance risks | Kernel-churn risk **addressed** (glob-keyed pacman hook). Omarchy update cadence, recovery path, trademark — **not addressed.** |

### The scope decision nobody has made

The plan strongly recommends shipping a **v0 first**: T0 + T1 + T3 as a
*post-install script* for Decks that already have Omarchy, skipping the ISO,
the offline mirror, and the controller-navigable installer entirely. That
delivers the whole "feels like a Steam Deck, Desktop Mode is Omarchy"
experience weeks earlier, and the ISO (T4 + T5) becomes v1 that wraps it.

**The operator has never confirmed v0-vs-v1.** The project's own instructions
say to ask before starting T4. Given T1 is done, **T3 is the natural next
build and v0 is within reach** — this decision is now live, not theoretical.

---

## 7. Hard constraints (these override defaults)

- **Limine only.** No GRUB, no systemd-boot. Deliberate, after real breakage.
- **Fully offline through first boot into Gaming Mode.** Steam signing in on
  first launch is accepted and reframed, not a gap to engineer around.
- **No keyboard or terminal for a standard install.** Every screen must be
  reachable by Deck buttons/trackpads alone.
- **Never silently swallow a failure.** The project exists partly because
  upstream tooling printed success while doing nothing.
- **Idempotent, re-runnable scripts.**
- **OLED is the only verified hardware.** Never claim LCD support.
- **Don't auto-install an AUR helper.** Caused a real upstream failure.
- **Only test on physical hardware what cannot be tested otherwise.** Tiers:
  shellcheck/unit tests (seconds) → QEMU (minutes) → physical Deck (last).
- **Never propose reinstalling the Deck as a first resort.** It is the single
  most valuable test asset in the project.
- **Anything touching TDP, fan curves, or charge limits needs explicit
  approval every time** — genuine hardware-damage risk.

---

## 8. Suggested next steps

In rough priority order:

1. **Make the v0-vs-v1 scope call.** It determines whether the next months go
   into T3 (v0, ships sooner) or T4/T5 (the ISO). Everything downstream
   depends on it.
2. **Close the VM substrate blind spot** (§5.1). Small, and it restores trust
   in every idempotency claim the project makes.
3. **Implement the default-boot-entry stage** (§5.2), verifying the entry-path
   syntax in QEMU first.
4. **Set up Gaming Mode on the test Deck** (§5.5) — install Steam and
   gamescope. T3 cannot start without it, and it's a prerequisite nobody has
   scheduled.
5. **Decide how to handle the Quattro-vs-3.8.4 mismatch** (§5.4). Options:
   upgrade the Deck to Quattro beta, accept that T3's shell integration is
   developed blind, or wait for Quattro stable. This is a real fork in the
   road and it isn't in any task file.
6. **Run T2, the gamepad spike** — formally the next block, and it sizes T4.
   Note that session 7 already answered a good chunk of it incidentally
   (`/dev/uinput` works unprivileged, the correct systemd scoping target,
   which on-screen keyboard to use), so T2 may be smaller than its task file
   assumes. **Read the gamepad finding before starting it.**

---

## 9. Things not to re-derive

Each of these cost real time and is already settled:

- Docker's default bridge network is throttled to ~2 KB/s on the operator's
  dev machine — use `--network host` for any Docker-based tooling there.
- `mount -o remount` does **not** re-apply `fmask`/`dmask` on vfat. A full
  `umount`/`mount` cycle is required.
- `pacman --noconfirm` answers **No** to conflict questions; the firmware
  swap needs `--ask=4`.
- Valve's kernel packages ship no mkinitcpio preset at all, so an entire
  class of preset-patching work in the original plan is moot.
- Kernel series suffixes are **not orderable** (`618` vs `72` — neither
  integer nor string comparison is right), which is why the version is
  pinned to a single documented constant.
- On the Deck, `sudo` cannot prompt without a TTY. Agent sessions need a
  `SUDO_ASKPASS` helper; one is saved at `~/pizzarchy-askpass.sh`.
- The `cs35l41-dsp1-*` firmware warnings previously recorded as "expected on
  OLED" **do not actually occur** on the current firmware. Treat their
  reappearance as worth investigating, not as background noise.
