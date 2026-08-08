# Project: Omarchy Deck — a Steam Deck–native Omarchy Quattro installer

## 1. One-paragraph pitch

A single bootable USB ISO that, when booted on a Steam Deck (LCD or OLED), installs
a fully hardware-optimized Arch Linux + Omarchy Quattro system entirely offline,
navigable start-to-finish with only the Deck's built-in buttons/trackpads (no
keyboard, no terminal). After install, the device behaves exactly like stock
SteamOS — boots to Gaming Mode, controller/trackpad/gyro/haptics/audio/Wi-Fi/
Bluetooth all work out of the box, a "Desktop Mode" button drops you into a full
Omarchy (Hyprland + Quickshell) desktop, and a return-to-Gaming-Mode affordance
brings you back. Target: ship shortly after Omarchy Quattro's stable release.

## 2. Grounding facts (as of this planning session, Aug 2026 — verify before build)

- **Omarchy Quattro (Omarchy 4)** moved from alpha to beta on/around Aug 6, 2026.
  It's a from-scratch shell rewrite (Quickshell-based bar/launcher/menus/OSD/
  notifications) — meaning any deep UI theming or shell-level hooks from Omarchy
  3.x are likely invalid and must be redone against Quattro's actual shell APIs.
  Stable release timing is unannounced; treat as "soon" but re-check
  basecamp/omarchy releases before committing to a launch date.
- Quattro's own ISO already ships an **offline pacman mirror** baked in, which is
  the key enabler for the "fully offline install" requirement — confirm this
  mirror includes (or can be extended to include) the Deck-specific packages
  (linux-neptune kernel, jupiter-staging/holo-staging firmware, gamescope-session
  packages) before relying on it.
- The **official ISO build system** is `omacom-io/omarchy-iso` (archiso-based,
  MIT licensed, ~200 stars). It wraps `archinstall` behind a TUI called the
  "Omarchy Configurator," then chain-launches the Omarchy installer
  (`basecamp/omarchy`) post-base-install. It supports pointing at a **forked**
  installer repo via `OMARCHY_INSTALLER_REPO` / `OMARCHY_INSTALLER_REF` env vars
  — this is the intended extension point and should be used rather than
  patching the upstream repo in place.
- **deckarchy** (`aorumbayev/deckarchy`) is the existing "Steam Deck hardware
  fixes for Omarchy" project. It is currently broken/incomplete in several ways
  we hit firsthand this session (see Section 8 — Known Bugs to Fix Upstream).
  It targets systemd-boot/GRUB only, has no Limine awareness, and its
  `curl | bash` usage pattern is broken without also fetching `common-script.sh`.
- **Prior art in the neighborhood — know it before investing weeks.**
  **Bazzite** and **ChimeraOS** already ship mature, well-tested
  boot-to-Gaming-Mode-with-a-desktop-mode experiences on Deck hardware, and
  they solved most of the same hardware problems years ago. This project's
  genuine differentiator is **Omarchy specifically as the desktop** — not
  "Linux on Deck with Gaming Mode," which is a solved problem. Verify the
  current state of both before starting; if either has moved closer to what
  you're building, the right move might be a Bazzite/Chimera layer rather
  than a from-scratch ISO. This is a cheap check and worth doing in week
  one, not month two.
- **Super-Shift-S-Omarchy-Deck-Mode** (`28allday/Super-Shift-S-Omarchy-Deck-Mode`)
  is a generic (non-Deck) Omarchy Gaming Mode session-switcher for AMD/NVIDIA
  desktops. It is a strong base for the Desktop↔Gaming session-switching
  mechanism but has **no Deck-specific hardware knowledge** and defaults to
  booting into the desktop, with keybind-only switching (no icon, no
  boot-to-Gaming-Mode default). Built and partly maintained by a contributor
  (`28allday`) who is also active on mainline Omarchy — worth reaching out to
  directly given the overlap.

## 3. Explicit goals / non-goals

**Goals**
1. One ISO, flashed to one USB, boots on Deck hardware.
2. Installer is 100% controller/trackpad-navigable — zero keyboard/terminal
   required for a standard install.
3. Installer works fully offline (no Wi-Fi needed) — all packages, the Neptune
   kernel, firmware, and Omarchy itself ship on the USB.
4. Post-install boot experience is indistinguishable from stock SteamOS:
   boots to Gaming Mode / Big Picture, controller and gyro work immediately,
   Wi-Fi/Bluetooth/audio/haptics/TDP control all function without user setup.
5. A "Desktop Mode" affordance (icon/menu item within Gaming Mode, matching
   where SteamOS puts it) switches to a full Omarchy Quattro desktop session.
6. From the Omarchy desktop, a return path (icon + keybind fallback) goes back
   to Gaming Mode.
7. Hardware optimization parity with SteamOS: CPU governor/TDP control, GPU
   (RDNA2 APU) tuning, Wi-Fi/Bluetooth firmware, speaker DSP/haptics, battery
   power profiles.
8. Ships close on the heels of Omarchy Quattro's stable release.

**Non-goals (v1)**
- Supporting non-Deck handhelds (ROG Ally, Legion Go, etc.) — architecture
  should not preclude it later, but don't spend v1 time on it.
- A from-scratch custom shell theme beyond what's needed for Gaming Mode
  parity — reuse Quattro's Quickshell defaults for the desktop side.
- Dual-boot-with-SteamOS support — this is a full wipe-and-replace, matching
  how Omarchy's own ISO already behaves.
- NVIDIA/Intel hardware paths (the Deck is AMD-only; keep the hardware
  detection code Deck-specific rather than trying to generalize prematurely).

### 3.1 Ship a v0 before the ISO — strongly recommended

The full ISO (goals 1–3) is the largest and riskiest part of this project.
Goals 4–7 — the part users actually feel — do not require it.

**v0 = a single post-install script**, run on a Deck that already has
Omarchy installed the normal way. It does the kernel/firmware/boot work
(T1) plus Gaming Mode and the two-way session switch (T3). No custom ISO,
no offline mirror, no controller-navigable installer.

That is roughly **T0 + T1 + T3**, and it delivers the entire "feels like a
Steam Deck, but Desktop Mode is Omarchy" experience. It's usable by anyone
willing to run one command, which is most of the early-adopter audience for
an Arch-based Deck project.

Why this ordering is worth taking seriously:

- **It ships weeks earlier** and validates that anyone else actually wants
  this, before investing in ISO build infrastructure and a bespoke
  controller UI.
- **It de-risks the hard part.** T4 and T5 both depend on assumptions not
  yet verified (`PLAN.md` §10.1, §10.4, and the T2 spike). v0 doesn't.
- **It's the natural upstream contribution.** A working post-install script
  is something `deckarchy` or the Omarchy community can absorb; a whole
  custom ISO is a parallel project.
- **v1 loses nothing.** The ISO wraps the v0 script rather than replacing
  it — the same automation runs either way.

Treat the ISO (T4, T5) as **v1**, gated on v0 being real and on the
research findings landing. If v0 gets no traction, that is extremely cheap
information to have bought.

## 4. Architecture overview

Three layers, each a separate repo/fork, composed at build time:

```
┌─────────────────────────────────────────────────────────┐
│ omarchy-deck-iso  (fork of omacom-io/omarchy-iso)        │
│  - archiso build scripts                                  │
│  - offline package cache incl. linux-neptune,             │
│    jupiter-staging/holo-staging firmware,                 │
│    gamescope-session-* packages                            │
│  - controller-navigable installer front-end (replaces/    │
│    wraps the Omarchy Configurator TUI)                    │
│  - points OMARCHY_INSTALLER_REPO at omarchy-deck-installer │
└─────────────────────────────────────────────────────────┘
                          │ chain-launches
                          ▼
┌─────────────────────────────────────────────────────────┐
│ omarchy-deck-installer  (fork of basecamp/omarchy,         │
│                           or a post-install hook layer)    │
│  - runs deckarchy-fixed logic during install, not after   │
│  - installs Limine (not systemd-boot) with a working       │
│    linux-neptune UKI entry generated automatically         │
│  - installs gamescope-session-deck (see below)             │
│  - sets default boot target = Gaming Mode                  │
└─────────────────────────────────────────────────────────┘
                          │ installs
                          ▼
┌─────────────────────────────────────────────────────────┐
│ gamescope-session-deck  (fork of                           │
│  28allday/Super-Shift-S-Omarchy-Deck-Mode, Deck-ized)      │
│  - Deck-specific perf tuning (APU governor, TDP, fan)       │
│  - controller/gyro passthrough config                      │
│  - boots-to-Gaming-Mode-by-default (flip the SDDM default) │
│  - desktop icon + Steam Quick Access Menu entry for         │
│    "Desktop Mode", not just a keybind                       │
└─────────────────────────────────────────────────────────┘
```

## 5. Repo plan

Create these repos under one GitHub org (e.g. `omarchy-deck`) so cross-repo CI
and issue tracking stay coherent:

1. `omarchy-deck/deckarchy` — fork of `aorumbayev/deckarchy`. Fix upstream bugs
   (Section 8), add Limine support, submit PRs upstream where reasonable, keep
   the fork as the source of truth for anything upstream is slow to merge.
2. `omarchy-deck/gamescope-session-deck` — fork of
   `28allday/Super-Shift-S-Omarchy-Deck-Mode`. Add Deck hardware detection
   (skip the generic AMD/NVIDIA GPU-detection path entirely — hardcode for
   Van Gogh/Sephiroth APU), desktop icon, boot-to-Gaming-Mode default,
   controller-button "Desktop Mode" trigger from within Gaming Mode.
3. `omarchy-deck/omarchy-deck-installer` — thin layer (likely a set of
   post-install hook scripts, not a full Omarchy fork) that:
   - Runs after Arch base install, before/alongside Omarchy's own installer
   - Calls into `deckarchy` for kernel/firmware
   - Calls into `gamescope-session-deck` for the session layer
   - Configures Limine + the second boot entry automatically (scripted version
     of everything done by hand in this session)
4. `omarchy-deck/omarchy-deck-iso` — fork of `omacom-io/omarchy-iso`. Swaps in
   a controller-navigable front-end, points `OMARCHY_INSTALLER_REPO`/`REF` (or
   equivalent hook mechanism) at the pieces above, bakes in the offline
   package cache.

## 6. Detailed workstreams

### 6.1 Offline, controller-only installer UI (highest-risk, highest-effort item)

This is the single hardest requirement and needs early spike work before
committing to an approach.

- Investigate whether `archinstall`'s TUI can be driven by a joystick/gamepad
  input layer (it's a `prompt_toolkit`-based curses UI — gamepad-to-keyboard
  event injection via something like `evtest`/`uinput` mapping Deck buttons to
  arrow keys + Enter + Esc may be sufficient without touching archinstall
  itself at all). **Spike this first** — if a generic "map gamepad to
  keyboard/mouse events at the kernel input layer" daemon works, it solves
  navigation for archinstall, the Omarchy installer's `gum`-based prompts
  (visible in this session's transcript — the retro pixel install screen is
  `gum`), and any custom screens, all at once, with far less UI work than
  building bespoke controller-native screens.
- Fallback if that's insufficient for some screens: a lightweight custom
  gamescope-hosted UI (Quickshell, matching Quattro's shell tech, or a minimal
  QML/GTK screen) for just the handful of choices that must be user-driven:
  disk confirmation (destructive, must not be silently defaulted), keyboard
  layout region (or infer from locale set at build time and skip asking),
  optional theme pick if desired. Everything else (bootloader=Limine,
  filesystem=btrfs, profile=minimal, network=NetworkManager, timezone/locale)
  should be **pre-baked defaults**, not prompts — every prompt is a chance for
  the flow to break without a keyboard, so minimize the prompt count
  aggressively rather than trying to controller-ify every archinstall screen.
- On-screen button glyphs (Steam Deck A/B/X/Y, trackpad, L4/R4 etc.) should
  match Valve's iconography so the flow visually reads as "a Deck menu," not
  "a Linux installer someone bolted a controller onto."

### 6.1a The actual guided-selection screens (button-only)

Modeled on SteamOS's own first-boot setup wizard, which every Deck owner has
already used — mirror its screen count and ordering where possible so the
flow feels familiar rather than novel. Everything not listed here is a
pre-baked default (Section 6.1) with **no prompt at all**. Each screen below
notes why it can't just be defaulted, and what the safe fallback is if the
user does nothing (screens should never hard-block on input forever).

1. **Language.** Determines UI text for every later screen — has to come
   first, and can't be defaulted since it varies by user. Present as a
   flag/name grid, not a text list, so it's legible before any locale is
   even set. A/B/X/Y or trackpad-scroll to navigate, A to confirm.
   *No safe default* — this is the one screen the flow must wait on.
2. **Region (drives both keyboard layout and timezone together).** Rather
   than separate "keyboard layout" and "timezone" screens (which is where
   this session's manual install lost real time — a mismatched layout
   silently corrupted commands like `-O` becoming `-0`), present a single
   **country/region picker**. Selecting a region sets keyboard layout,
   timezone, and locale formatting (date/number formats) together from a
   known-good mapping table, the same way SteamOS's own setup does it.
   This removes an entire class of the keyboard-mismatch bugs hit
   firsthand this session. Fallback default if skipped/timed out: US
   English / `us` layout / UTC — matches Omarchy's own installer default,
   so behavior is at least predictable.
   - *Edge case to design for:* a user whose keyboard-relevant region
     (e.g., wants a Latin American layout) differs from their
     display-language region. Add a lightweight "keyboard layout" override
     as a secondary, clearly-optional field on the same screen rather than
     a separate step — most users won't touch it, but this session is
     direct proof it matters for some.
3. **Agreements / consent.** Distinct from a *selection* screen — the user
   isn't picking an option, they're consenting to something, and each item
   below should default to the privacy-preserving / non-consenting state if
   skipped rather than silently opting the user in. Bundle into as few
   screens as legally/practically possible rather than one-agreement-per-
   screen (agreement fatigue is real; SteamOS itself keeps this to one or
   two screens):
   - **Open-source + proprietary component notice.** A single informational
     screen disclosing that the image includes proprietary binary firmware
     (AMD GPU/Wi-Fi/Bluetooth blobs, the Neptune audio DSP firmware) rather
     than pure open-source components, plus a link/QR code to full license
     texts. This is a "press A to acknowledge," not a real choice — Arch
     itself doesn't gate on this, but Deck hardware specifically needs
     these blobs to function, so disclosing it up front is the honest
     move. Not blocking beyond a single acknowledgment press.
   - **Diagnostic/install log upload consent.** This session's own Omarchy
     install run surfaced a real example of this — its installer offers
     "Upload log for support" via a QR code on failure. Any equivalent
     telemetry in *this* project's installer (crash reports, install
     success/failure pings to help the project improve) must be a clear,
     off-by-default opt-in, asked once, not assumed. If there's no
     telemetry at all in v1, skip this screen entirely rather than asking
     a question with only one possible honest answer.
   - **Steam's own EULA — explicitly NOT duplicated here.** Steam already
     shows its own license agreement on first launch; don't build a
     redundant "do you agree to Steam's terms" screen into the OS
     installer. This should surface naturally the first time Gaming Mode
     actually starts Steam, exactly as it does on stock SteamOS — the
     installer's job is just to get the user to that first Gaming Mode
     boot, not to pre-clear every downstream app's own consent flow.
4. **Disk confirmation.** This is destructive (wipes the target drive) and
   must never be silently defaulted or auto-confirmed, even though on a
   Deck there's realistically only one internal drive to pick. Show drive
   size/model, a clear "this erases everything" warning, and require an
   explicit confirm button press (not just "continue past this screen") —
   mirror how the current Omarchy ISO already gates this with its own
   Y/n-equivalent prompt. If an external/SD path is detected too, list
   both and require the user to pick, defaulting the cursor to internal
   storage.
5. **Account setup.** Username + password (or a SteamOS-style numeric PIN
   for the low-friction case) is unavoidably user-specific. Keep it to a
   single screen with an on-screen keyboard/PIN pad navigable by
   stick+A, matching how SteamOS's own on-screen keyboard already works
   for entering Wi-Fi passwords and account info — reuse that input
   pattern rather than inventing a new one. No safe default; block here.
6. **Encryption on/off.** Security-relevant and not safely assumable either
   way — some users want full-disk encryption, some explicitly don't
   (Omarchy's own ISO already exposes this as a toggle). Present as a
   simple two-option screen with a one-line explanation of the tradeoff
   (slightly slower boot / recovery implications vs. protection if the
   device is lost). Default cursor position: **off**, matching stock
   SteamOS's default and keeping first-boot time closer to parity.
7. **Optional: Wi-Fi network.** The install itself is fully offline per
   the project goals, so this is **not needed to complete installation** —
   but SteamOS's own setup wizard asks for Wi-Fi early because later
   steps (account sign-in, updates) want it. Include this as a clearly
   **skippable** screen ("Connect now" / "Skip — connect later") rather
   than a blocking one, since the core install must not depend on it.
   **Promoted per R1 §10.4 (confirmed):** Steam cannot sign in without
   network on first launch under any packaging strategy, so a user who
   skips this screen must be told plainly that Steam will need Wi-Fi before
   Gaming Mode is usable — otherwise first boot is an undismissable Steam
   error dialog with no keyboard attached. See §10.4's "Decision needed"
   item 3: T5 must detect "no network + no Steam client installed" before
   handing the display to Steam and show a controller-navigable Wi-Fi
   screen instead of letting Steam fail on its own.
8. **Final confirm-and-install summary.** One screen recapping the choices
   from 1–7 before anything destructive actually runs, with a single
   "Install" confirm button — matches the review screen pattern already
   visible in archinstall and in the Omarchy ISO's own flow.

**Explicitly NOT a user prompt (pre-baked, no screen at all):**
bootloader (always Limine), filesystem (always btrfs), install profile
(always the Deck-specific minimal-plus-gamescope-session set), network
backend (always NetworkManager), swap/zram configuration, hostname
(auto-generate or derive from device serial), theme/accent color (ship one
good-looking Omarchy default; theme-switching is trivially available
*after* first boot from within Omarchy itself, so it doesn't need to gate
installation).

**Screen count target: 6 blocking + 1 skippable + 1 summary = 8 total**
(language, region, agreements, disk, account, encryption, Wi-Fi, summary),
deliberately close to SteamOS's own first-run wizard length, so the
experience reads as "a normal Deck setup" rather than "a Linux installer."
If the project ships with no telemetry at all in v1, the agreements screen
collapses to just the firmware-notice acknowledgment, keeping total count
effectively unchanged from SteamOS's own flow.

### 6.2 Offline package payload

- Enumerate every package needed: base Arch, `linux-neptune`, Neptune firmware
  packages (`linux-firmware-neptune`, `steamdeck-dsp`, jupiter-staging/
  holo-staging repo contents), Limine, Omarchy Quattro's full package set,
  `gamescope-session-git`/`gamescope-session-steam-git` and their dependency
  tree, Steam itself.
- Build a local repo (`repo-add`) baked into the ISO's squashfs, matching how
  Quattro's own ISO already ships an offline mirror — extend that mirror
  rather than building a separate one, if its build tooling allows adding
  custom packages/repos.
- Verify total ISO size against a practical USB size target (16GB / 32GB) —
  Steam + a full desktop package set + kernel + firmware will be several GB;
  confirm early rather than discovering a size problem near ship date.

### 6.3 Kernel, firmware, and bootloader (build on this session's work directly)

This session already produced a validated, working manual procedure — turn it
into unattended automation:

- Automate the `linux-neptune.sh` fetch-both-files-first pattern (fixing
  deckarchy's broken `curl | bash` usage) — see Section 8.
- Automate the `default_uki` preset fix for `linux-neptune-611.preset`
  (currently ships commented out, and even when uncommented defaults to the
  wrong `/efi/...` path rather than the system's actual ESP path).
- Automate detecting the real ESP mount point (`findmnt /boot`) rather than
  assuming a path.
- Automate generating the second Limine boot entry (`/boot/EFI/BOOT/
  limine.conf`) for the neptune kernel, reusing the stock entry's PARTUUID/
  cmdline rather than hand-typing it — script this as a proper templating
  step (read the existing entry, substitute only the `path:` line) rather
  than a heredoc a human has to get byte-perfect.
- Automate the `/boot` mount permission fix (`fmask=0133,dmask=0022` instead
  of archinstall's default `fmask=0077,dmask=0077`) as part of base install,
  since Omarchy's own `limine-snapper.sh` (and likely other user-run scripts)
  need read access to `/boot` and silently fail otherwise. This should be a
  full `umount`/`mount` cycle in the installer, not a soft remount (confirmed
  in this session that `-o remount` does not re-apply `fmask`/`dmask`).
- Decide whether to default to Limine everywhere (matches what Omarchy Quattro
  natively wants and what its snapshot/rollback tooling expects) — yes,
  per this session's findings, Limine should be the only supported bootloader
  path for this project; drop systemd-boot support entirely rather than
  maintaining two.

### 6.4 Gaming Mode / Desktop Mode session switching

Fork and Deck-ize `Super-Shift-S-Omarchy-Deck-Mode`:

- Replace its generic AMD/NVIDIA GPU/monitor detection with hardcoded Deck
  APU/display parameters (known resolution, refresh rate, panel type per
  LCD/OLED model) — no detection needed on fixed hardware.
- Add Deck-specific performance tuning: TDP limit control (via
  `steamdeck-dsp`/`jupiter-staging` sysfs nodes the same way SteamOS's
  `steamos-polkit-helpers` do it), fan curve, and battery charge-limit
  parity with stock SteamOS Settings.
- Wire controller/gyro/haptics input passthrough correctly in both sessions —
  this needs real hands-on testing on hardware, not just config review.
- Add a **desktop icon** for "Return to Gaming Mode" inside the Omarchy
  desktop (a `.desktop` file calling the existing `switch-to-gaming` script,
  pinned in the app launcher/dock/taskbar per wherever Quattro's Quickshell
  shell puts pinned items).
- Add a **Gaming Mode → Desktop Mode** trigger reachable via controller alone
  from within Steam's Quick Access Menu or Power menu (their existing
  `os-session-select` hook for Steam's "Exit to Desktop" button is the right
  integration point — confirm it fires correctly under gamescope-session's
  Deck build).
- **Flip the default session** so first boot after install lands in Gaming
  Mode, not the Hyprland/Quickshell desktop — this is the opposite of
  upstream's default and is core to the "feels like stock SteamOS" goal.

### 6.5 Hardware parity checklist

Verified via tier T3 (in-place over SSH, Section 9.4) — not via reinstall.
Developed against OLED; model-divergent rows are flagged and must be gated on
model detection so LCD support is a table fill-in, not a refactor (Section 9.6).

| Subsystem | Stock SteamOS behavior to match | Notes |
|---|---|---|
| CPU/APU governor & TDP | Auto performance scaling + user TDP slider | via jupiter-staging sysfs, same as 6.4 |
| GPU | RDNA2 iGPU fully accelerated, VRS/FSR working in-game | Mesa RADV, confirm `gamescope` build flags |
| Wi-Fi | Auto-connect, works out of box | Confirm firmware from Neptune firmware package covers the Deck's specific Wi-Fi chip |
| Bluetooth | Controller/audio pairing works immediately | `bluedevil`/`bluez` present, no manual setup |
| Speakers/haptics | DSP-calibrated audio, working haptic trackpad feedback | `steamdeck-dsp` package; this session's install hit missing `cs35l41-dsp1-*` firmware files under `linux-firmware-neptune` — resolve and confirm audio actually works post-install, don't just suppress the warning |
| Trackpads/gyro | Full input passthrough in both Gaming and Desktop sessions | Test cursor + gyro-as-mouse in desktop mode specifically |
| Battery | Accurate percentage, charge-limit option | |
| Display | Correct refresh rate/HDR (OLED) | |
| Buttons (Steam/QAM/Power) | All function in both sessions | Confirm QAM opens Steam's overlay in Gaming Mode and does something sane (or is disabled cleanly) in Desktop Mode |

## 7. Timeline (aligned to Quattro's stable release)

Structure this as parallel-track work so most of it is done **before**
Quattro goes stable, leaving only a final integration/QA pass once it ships:

- **Track A (kernel/bootloader/firmware automation, Section 6.3)** — can
  start immediately; doesn't depend on Quattro at all. Target: fully scripted
  and idempotent within 1–2 weeks.
- **Track B (Gaming Mode fork/Deck-ization, Section 6.4)** — can start
  immediately against Omarchy 3.x or Quattro beta; Quickshell-specific
  integration points (icon placement, QAM hook) should be re-verified once
  Quattro stabilizes, since its shell is a full rewrite. Target: functional
  fork within 2–3 weeks, hardware-parity checklist (Section 6.5) running in
  parallel as items land.
- **Track C (controller-only installer UI, Section 6.1)** — start with the
  gamepad-to-input-events spike immediately (lowest dependency on anything
  else); if the spike works, the remaining UI work is mostly configuration
  (prompt reduction, defaults) rather than net-new UI code. Target: spike
  result within a few days, full flow within 2–3 weeks.
- **Track D (offline package payload + ISO build, Section 6.2)** —
  depends on A/B/C being far enough along to know the final package list;
  start the mirror/build tooling investigation early (especially the signing
  question, Section 10.1), do the actual full payload assembly last.
- **Track 0 (test infrastructure, Section 9)** — do this *first*, before or
  alongside Track A. Ventoy on the test USB, the script-override directory,
  the SSH iterate-in-place loop, and CI's automated QEMU install are each
  small tasks that pay for themselves within days by collapsing the edit-test
  cycle from ~30 minutes to seconds for most work. Treating this as setup
  overhead to skip is the single easiest way to lose a week.
- **Integration + hardware QA pass** — once Quattro ships stable, rebase all
  four tracks against it, do a full clean-install-to-gaming-mode-to-desktop-
  and-back cycle (tier T4) on OLED hardware, fix regressions. Budget this
  as its own dedicated week rather than assuming it's zero-effort — Quattro's
  shell rewrite means Track B's UI integration points are the most likely to
  need rework at this stage.

## 8. Known upstream bugs — with root-cause hypotheses

Each item below was hit firsthand during a real Deck install session. Each
carries a **hypothesis** about root cause so the first action is *verifying a
specific theory* rather than re-deriving the bug from scratch. Confirm or kill
each hypothesis before writing a fix — a wrong root cause here means a fix that
papers over the symptom and breaks again later.

### 8.1 `linux-neptune.sh` silently no-ops when run via `curl | bash`

**Symptom.** The README's `curl -sSL .../linux-neptune.sh | bash` prints
`bash: line 3: ./common-script.sh: No such file or directory`, then
`checkEnv: command not found`, then a cascade of `line NN: : command not found`
— yet still prints "Steam Deck detected", "Adding jupiter-staging…",
"Installing Neptune kernel…" and exits 0. Nothing is actually installed.

**Hypothesis (high confidence).** deckarchy's script layer is derived from
Chris Titus Tech's `linutil`, which uses exactly this
`common-script.sh` + per-tool-script structure and is designed to run from a
**git clone**, not a curl pipe. Supporting evidence: the helper names
(`checkEnv`, `checkEscalationTool`, `checkAURHelper`, `checkCurrentDirectoryWritable`)
and the `$ESCALATION_TOOL` / `$PACKAGER` / `$RC` variable conventions are
linutil's; and `checkPackageManager 'nala apt-get dnf pacman zypper apk
xbps-install eopkg'` enumerates eight package managers in a script that only
ever runs on a Steam Deck — nonsensical unless it's inherited boilerplate.
The README's curl one-liner was likely written for convenience and never
tested end-to-end.

**How to confirm.** Diff `common-script.sh` against linutil's file of the same
name. If they're near-identical, hypothesis confirmed.

**Implied fix.** Don't just fix the README. Vendor the ~6 functions actually
needed directly into a self-contained script, drop the multi-distro
abstraction entirely (this only ever runs on Arch-on-Deck), and add
`set -euo pipefail` so a missing dependency aborts loudly instead of
producing fake success. **This project should not depend on upstream's
curl-pipe pattern at all** — vendor the logic into `omarchy-deck-installer`.

### 8.2 No Limine support in bootloader detection

**Symptom.** `No supported bootloader detected (GRUB or systemd-boot).
Manually configure your bootloader to use linux-neptune.`

**Hypothesis (high confidence).** The script simply predates Limine's arrival
as a mainstream option — archinstall only gained Limine support relatively
recently (~3.0.3), and Omarchy's adoption of it as the preferred bootloader is
newer still. This is an unimplemented feature, not a broken one.

**How to confirm.** Check the script's git history for the bootloader-detection
block's date versus archinstall's Limine support landing.

**Implied fix.** Additive. Note that Limine's config location is *not* stable
across versions — this session found it at `/boot/EFI/BOOT/limine.conf`, while
Omarchy's own `limine-snapper.sh` probes five different paths
(`/boot/EFI/arch-limine/`, `/boot/EFI/BOOT/`, `/boot/EFI/limine/`,
`/boot/limine/`, `/boot/limine.conf`). Any detection code must probe the same
candidate list rather than hardcoding one path.

### 8.3 `linux-neptune-611.preset` ships `default_uki` commented out and pointing at the wrong ESP

**Symptom.** Even after the kernel installs correctly, no UKI is produced, so
no bootable entry exists. Uncommenting the line still fails with
`ERROR: Invalid option -U -- '/efi/EFI/Linux/…' must be writable`.

**Hypothesis (high confidence).** **This is not a deckarchy bug at all** — it's
inherited from Arch's own stock `linux.preset` template, which ships
`#default_uki="/efi/EFI/Linux/arch-linux.efi"` commented out by default. The
`/efi` path reflects the Arch wiki's convention of mounting the ESP at `/efi`
when `/boot` is a separate non-ESP partition. On an archinstall Limine+UKI
setup the ESP *is* `/boot`, so the inherited default path is simply wrong for
this configuration. Valve's `linux-neptune-611` package just carries the
template forward unmodified.

**How to confirm.** Compare against `/etc/mkinitcpio.d/linux.preset` on the
same machine — if the stock Arch preset has the identical commented `/efi`
line, confirmed.

**Implied fix.** Belongs in **this project's installer**, not upstream: detect
the real ESP with `findmnt`, then patch the preset. Do not hardcode `/boot` —
detect it, because the whole failure mode here is a hardcoded path assumption.

**Fragility warning worth designing around now:** the preset filename is
version-pinned (`linux-neptune-611.preset`). If Valve ships a
`linux-neptune-612` package, the preset name, the UKI filename, and the Limine
entry's `path:` all change, and a user's system silently stops booting the
Neptune kernel after a routine `pacman -Syu`. See Section 11.

### 8.4 `yay-bin` vs `yay` conflict breaks Omarchy's installer

**Symptom.** `yay-12.6.0-1 and yay-bin-13.0.1-1 are in conflict` →
`error: failed to prepare transaction` → Omarchy's `packaging/base.sh` aborts.

**Hypothesis (high confidence).** Same linutil inheritance as 8.1:
`checkAURHelper` installs an AUR helper as a side effect of an *environment
check*, and prefers `yay-bin` because it's a prebuilt binary (seconds to
install vs. compiling `yay` from source). Omarchy pins the source `yay`. Both
packages `provide` yay, so pacman refuses.

**How to confirm.** Read `checkAURHelper` in `common-script.sh` for its
preference order.

**Implied fix.** Drop the AUR-helper auto-install entirely from the vendored
version (8.1) — by the time this project's installer runs, Omarchy will have
installed the correct helper itself. **Ordering matters:** ensure the
Neptune/hardware layer never installs an AUR helper *before* Omarchy's own
package stage runs.

### 8.5 ESP mounted `fmask=0077,dmask=0077` breaks user-space `/boot` reads

**Symptom.** Omarchy's `limine-snapper.sh` reports `Error: Limine config not
found` even though the file exists at a path it explicitly checks — because
its `[[ -f … ]]` test runs as the normal user, who cannot traverse `/boot`.

**Hypothesis (medium-high confidence).** Not a bug in either project alone but
a **collision between two reasonable upstream defaults**: archinstall
deliberately hardens the ESP to 0077 on UKI setups (UKIs are bootable
executables; there's a defensible argument for not making them world-readable),
while Omarchy's script reasonably assumes it can stat a config file as the
invoking user.

**How to confirm.** Reproduce on a stock archinstall Limine+UKI system with no
Deck packages involved at all. If it reproduces, it's a generic
Omarchy-on-archinstall bug worth reporting upstream — not Deck-specific.

**Implied fix — and a real decision to make.** Loosening the ESP to
`fmask=0133,dmask=0022` (what this session did) works, but it is a
**security-relevant loosening applied globally to fix one script's
permission assumption**. The cleaner fix is upstream: have
`limine-snapper.sh` run its existence check with elevated privileges. Ship the
mount-option change if needed to unblock, but file the upstream issue too, and
document the choice rather than burying it. Also note: `mount -o remount` does
**not** re-apply `fmask`/`dmask` on vfat — a full `umount`/`mount` cycle (or a
reboot) is required, which cost real time to discover.

## 9. Testing strategy — optimized for loop time, not coverage theater

### 9.1 The core constraint

Naive testing here is: rebuild ISO → flash USB (~20 min with verify) → boot
Deck → install → find bug → repeat. That's a **~30 minute edit-test cycle**,
which is fatal to iteration speed. Almost all of that time is avoidable. The
guiding principle: **only test on physical hardware what physically cannot be
tested any other way.**

Realistically, the majority of the work in this plan — installer flow,
partitioning, Limine config generation, preset patching, package resolution,
account/encryption setup, and most of the session-switching logic — has
**nothing to do with Deck-specific hardware** and should never touch the Deck
during development.

### 9.2 Five test tiers, cheapest first

| Tier | What it covers | Loop time | Where |
|---|---|---|---|
| **T0** Static | `shellcheck`, `bash -n`, config linting, unit tests for path-detection/config-generation functions with fixture inputs | seconds | Dev machine + CI |
| **T1** Automated VM install | Full unattended install in QEMU with a scripted answer file; asserts partition layout, Limine entries, UKI presence, package set, services enabled | 3–8 min, unattended | CI on every push |
| **T2** Interactive VM | Installer UI flow, screen ordering, controller-nav mapping, on-screen keyboard, all 8 guided screens | 5 min | Dev machine (`./bin/omarchy-iso-boot`) |
| **T3** Deck, in-place iteration | Everything hardware-specific: kernel boot, gyro/haptics/trackpad, audio DSP, Wi-Fi/BT, TDP/fan, gamescope, session switching | **seconds to ~2 min** | Physical OLED Deck, over SSH |
| **T4** Deck, clean install | Full USB → offline install → first boot → parity checklist | ~10 min | Physical Deck, release candidates only |

**T3 is the key unlock and deserves the most engineering investment.** See 9.4.

### 9.3 Killing the 20-minute reflash

Three independent fixes, all worth doing:

1. **Use Ventoy on the test USB.** Install Ventoy once; thereafter "flashing"
   is *copying an .iso file* onto a normal exposed partition. A 4–8 GB copy
   over USB 3.0 is ~2–4 min versus a full `dd`/Etcher write-plus-verify. Also
   lets you keep several ISO builds side by side and pick at boot — invaluable
   for bisecting a regression. **Do this before anything else; it is the
   single highest-leverage change to the loop.**
2. **Stop rebuilding the ISO for script changes.** Structure the ISO so the
   installer scripts are read from a location that can be overridden at boot —
   e.g. a plain `omarchy-deck/` directory on the Ventoy data partition that
   the ISO prefers over its baked-in copy if present. Then iterating on
   installer logic means copying a few KB of shell, not a multi-GB image. Most
   iterations touch scripts, not the base image, so this converts the common
   case from minutes to seconds.
3. **Consider booting the installer from microSD.** The Deck can boot from
   microSD, and the card is writable from the running Deck itself — useful as
   a second, hot-swappable test channel so a broken boot on one medium doesn't
   block testing on the other. *Verify this works with your specific ISO's
   bootloader before relying on it.*

### 9.4 Never reinstall to test post-install work

Most Deck-specific work (Section 6.4, 6.5 — TDP, fan curves, gyro, haptics,
audio, session switching, the Desktop Mode icon) is **post-install
configuration**, not install-time logic. Testing it via full reinstall is
pure waste. Instead:

- **Install once, iterate forever.** Get one good install on the Deck, enable
  `sshd`, and develop from your desktop: `rsync` the changed scripts over, run
  them, read `journalctl` remotely. This is a **~30 second loop** for the
  majority of hardware work — a ~60× improvement over reinstalling. It also
  sidesteps typing on the Deck itself, which is exactly where the keyboard-layout
  corruption (`-O` → `-0`) cost time in this session.
- **Snapshot before each experiment.** The install is btrfs; take a snapshot of
  a known-good post-install state and roll back rather than reinstalling when
  an experiment corrupts the system. This makes "try something destructive" a
  ~1 minute operation. (Omarchy's Limine+snapper integration may give this to
  you nearly free — worth confirming it works before hand-rolling.)
- **Make every install stage independently re-runnable and idempotent.** Each
  stage should be safe to run twice and abort loudly on failure. This is
  required for the rsync loop above to work at all, *and* it's the direct
  antidote to the Section 8.1 silent-partial-success failure mode.
- **Keep a "known-good base" snapshot** representing a clean Arch+Neptune+Limine
  system before the Omarchy layer, so Track B work can be tested without
  re-running Track A.

### 9.5 What genuinely requires physical hardware

Be honest about this list and ruthlessly exclude everything else from the
Deck loop:

- Neptune kernel actually booting on the real APU
- Gyro, haptics, trackpads, and all physical buttons (Steam/QAM/L4-R5)
- Speaker output and the `cs35l41` DSP calibration firmware (OLED-specific)
- Wi-Fi and Bluetooth firmware on the real radios
- TDP/fan/thermal control and battery reporting
- Display refresh rate and HDR behavior (OLED-specific)
- gamescope on real RDNA2, and actual game performance
- The end-to-end offline install (T4, release candidates only)

Everything else belongs in T0–T2.

### 9.6 LCD vs. OLED

The plan assumes both models, but you have an **OLED only**. Rather than
letting that block progress:

- Develop entirely against OLED; treat LCD as a **pre-release validation gap**,
  explicitly documented as such.
- The known divergences are narrow and identifiable in advance: audio DSP
  firmware (`cs35l41-*` is OLED-specific), display panel/refresh/HDR, Wi-Fi
  chipset (OLED moved to a different radio), and battery capacity. Gate those
  code paths on model detection from the start rather than assuming parity, so
  LCD support is a matter of filling in a table rather than refactoring.
- Recruit an LCD tester from the Omarchy community for release-candidate
  validation, or ship v1 as **OLED-verified, LCD-untested** and say so plainly
  — far better than silently claiming support you haven't validated.

### 9.7 CI

- Every push: T0 + T1 (build the ISO, run an unattended QEMU install, assert on
  the resulting disk image). This catches the entire class of "installer script
  regression" without any human or hardware in the loop.
- Tag/RC builds: publish the ISO artifact so a Ventoy copy is the only manual
  step before a T4 run.
- Assert on *artifacts*, not log text: partition table, presence and count of
  `/boot/EFI/Linux/*.efi`, parsed Limine entries, `pacman -Q` package set,
  enabled systemd units. Log-scraping would have passed on the Section 8.1 bug;
  artifact assertions would have caught it immediately.

## 10. Open questions — with working hypotheses

Stated as hypotheses so each becomes a quick verification task rather than
open-ended research. Don't block Tracks A–C on these; resolve before Track D.

### 10.1 Can Quattro's offline mirror carry Deck packages?

**Hypothesis: yes, with a signing caveat.** `omarchy-iso` already assembles a
pacman repo from a package list at build time, so adding `linux-neptune-611`,
`linux-firmware-neptune`, `steamdeck-dsp`, and the `gamescope-session-*`
packages is likely a matter of extending that list plus adding Valve's
`jupiter-staging`/`holo-staging` repos to the build-time `pacman.conf`.
**The likely snag is package signing:** Valve's repos are consumed with
`SigLevel = Never` (visible in deckarchy's own repo-config block), so the
build will need either a local re-sign step or a matching SigLevel exception
carried into the ISO's `pacman.conf`. Verify by reading `omarchy-iso/builder/`.

**Result: CONFIRMED, signing caveat KILLED** (`FINDING-R1-10.1.md`). No
re-sign step needed at all — `omarchy-iso` already ships an out-of-tree
kernel (`linux-t2`) from an unsigned third-party repo (`[arch-mact2]`,
`SigLevel = Never`) into the offline mirror and boots it, and the entire
offline repo is `SigLevel = Never` by deliberate upstream design (signatures
are checked against the live keyring instead). Adding Valve's repos is a
structurally identical, already-exercised edit — copy the `[arch-mact2]`
block shape into the three `pacman-online-*.conf` files. Two new risks not
in the original hypothesis: the offline mirror is stored **uncompressed** in
the squashfs, so every byte of `linux-firmware-neptune`/`steam`/gamescope
adds ~1:1 to ISO size (budget this before locking the package set); and the
build has a hard package-count self-check (600–2000) that will need its
upper bound widened. See `FINDING-R1-10.1.md` for full file/line citations
and the recommended T5 architecture.

### 10.2 Is there a lighter integration point than forking `basecamp/omarchy`?

**Hypothesis: yes — use hooks, don't fork.** Two independent signals: (a)
`omarchy-iso` exposes `OMARCHY_INSTALLER_REPO` / `OMARCHY_INSTALLER_REF` as
first-class env vars, and (b) a recent Omarchy changelog entry adds
`~/.config/omarchy/hooks/post-update.d/` *directory-style* hooks, explicitly
described as "easier for extensions to drop files than munge a single config"
— i.e. the project is actively building extension points for exactly this use
case. A third signal cuts the same way: Quattro reportedly turns
`~/.local/share/omarchy` into a **pacman-owned symlink**, which breaks any
project that integrates by git-checkout — so the hook directory is the
sanctioned path and a fork would be swimming upstream. **Verify against
Quattro specifically, not 3.x**, since this is exactly the kind of thing the
rewrite changed.

**Result: PARTIAL — right conclusion, wrong mechanism** (`FINDING-R1-10.2.md`).
Signal (a), `OMARCHY_INSTALLER_REPO`/`OMARCHY_INSTALLER_REF`, was already
killed (see the "Foundational assumption" finding above). For (b) and (c):
the `hooks/<name>.d/` mechanism does exist and work in Quattro (six hook
types, not one), but `post-update.d/` is the wrong hook — it's unprivileged,
`$HOME`-scoped, never runs before first boot, and upstream's own hook runner
silently swallows failures (`omarchy-hook:19,26`), which conflicts with this
project's "never silently swallow a failure" rule. The `~/.local/share/omarchy`
pacman-owned-symlink claim is half wrong: it's not pacman-owned and doesn't
exist at all on fresh Quattro installs (it's purely a 3.x upgrade shim) — but
the practical conclusion (don't integrate by git checkout) still holds, since
`OMARCHY_PATH=/usr/share/omarchy` everywhere and there's no checkout to
integrate with.

**The real sanctioned extension point, not previously considered:** upstream
already solves this exact problem shape twice, in-tree, via
`install/hardware/` — `pacman.sh` (hardware-gated unsigned third-party repo,
verbatim the shape needed for Valve's repos) and `intel/ptl-kernel.sh`
(hardware-gated kernel swap + Limine boot-order drop-in — a working template
for T1). Recommended T5 architecture: fork `omarchy-iso` for build-time
changes (§10.1) + ship Deck logic as its own pacman package for install-time
work (mirrors `omarchy-dev`'s own PKGBUILD) + one `pre-refresh-pacman.d/`
hook for durability. That last hook is load-bearing: `omarchy-refresh-pacman`
**silently overwrites `/etc/pacman.conf` wholesale** on every channel
refresh, which would delete the Valve repo entries without it. Also found:
an ALPM pre-transaction guard aborts bare `pacman -Syu` unless
`OMARCHY_UPDATE_PACMAN=1` is set — affects T1 and T3.

### 10.3 Should the gamepad→input mapping layer ship permanently?

**Hypothesis: ship it, but scoped to Desktop Mode only.** In Gaming Mode,
Steam owns input entirely and a second mapper would conflict. In Desktop Mode,
stock SteamOS gives users trackpad-as-mouse and an on-screen keyboard —
because Steam is running and providing its desktop controller layout. So
there are two candidate designs worth testing head-to-head early: **(a)** run
Steam in the background during the Omarchy desktop session and inherit its
desktop layout for free, or **(b)** ship the custom mapper as a systemd user
service active only in the desktop session. (a) is less code and more
SteamOS-faithful; (b) is more predictable and doesn't require Steam running.
Test both on hardware in the same T3 session — this is a cheap experiment
with a large downstream design impact.

**Result: PARTIAL — both designs prepared, decision needs hardware**
(`FINDING-R1-10.3.md`). Design (a): add `steam -silent` to Hyprland autostart
to inherit Steam Input's built-in desktop controller layout + OSK for free;
open questions are whether this codepath initializes correctly outside
gamescope/Plasma, OSK focus detection on native Wayland vs XWayland apps
under Hyprland, and resource cost/singleton conflicts with Gaming Mode's own
Steam instance. Design (b): the T2 mapper as a systemd `--user` service
scoped by `WantedBy=hyprland-session.target` (draft unit written), needing a
`/dev/uinput` permission fix (udev rule + `SupplementaryGroups=input`) and
`wvkbd`/`squeekboard` via `wlr-input-method` for the OSK it doesn't get for
free. Both are prepared concretely enough for a single hardware session to
test head-to-head per the finding's test plan — not attempted here, per the
physical-Deck-only testing tier.

### 10.4 Will `steam` actually work offline on first boot?

**Hypothesis: no — and this is the most likely goal-threatening surprise in
the plan.** Arch's `steam` package is a bootstrap that downloads the real
client from Valve on first launch. A "fully offline install" can therefore
still produce a device that **boots to Gaming Mode and immediately needs
internet** before Steam is usable — undermining the headline promise. Steam's
redistribution terms may also constrain bundling a pre-populated client in a
public ISO.

**Verify very early** (this is cheap: install Arch's `steam` in a VM with no
network and launch it). If confirmed, the honest framing is "installs fully
offline; Steam signs in on first launch like any new Deck," and the Wi-Fi
screen (Section 6.1a, item 7) becomes more prominent — still skippable for
install, but clearly the path to a usable Gaming Mode. Decide this before
marketing copy is written.

**Result: CONFIRMED** (`FINDING-R1-10.4.md`) — tested for real in a
network-isolated QEMU VM, not reasoned about. Cold, no client, no network:
Steam fails fatally in under one second (`Steam needs to be online to
update.`) and exits; no client is ever installed. The obvious mitigation —
pre-populate the 2.5 GB client with network on, then relaunch offline — was
also tested and does **not** rescue the offline claim: Steam does start and
reach its login screen, but then sits in `LogonFailure No Connection`,
retrying on backoff. **Login itself requires network under any packaging
strategy** — this is over-determined, not a single fixable gap. Redistributing
a pre-populated client was also checked and found not clearly authorized by
Steam's Subscriber Agreement (no redistribution clause found; every Linux
distro ships only the 20 MB launcher, never the client) — a legal call, not
an engineering one, and the recommendation is not to attempt it.

**Operator decision (accepted):** reframe rather than treat as a blocker.
`CLAUDE.md`'s hard constraint is now worded as "fully offline install through
first boot into Gaming Mode; Steam signs in on first launch like a
factory-reset Deck." Marketing copy: *"Installs completely offline. Steam
signs in on first launch, exactly like a factory-reset Deck."* T5 gains a
required item: detect "no network + no Steam client installed" before
handing the display to Steam on first boot, and show a controller-navigable
Wi-Fi screen instead of letting Steam fail on its own with an undismissable
modal and no keyboard available. Still open: whether to bundle the 20 MB
`steam` launcher package itself in the offline mirror (recommended: yes, it's
a legitimate redistribution and removes one download) — see PROGRESS.md
"Blocked on human" for the pre-populated-client licensing question, which
remains unresolved pending operator/legal judgment.

### 10.5 Secure Boot / BIOS state

**Hypothesis: low risk but needs documenting.** Omarchy's own manual requires
Secure Boot off. The Deck ships with Secure Boot effectively disabled, so most
users likely need no BIOS change — but this cannot be automated from inside an
installer, so if any BIOS step *is* needed (entering setup via Vol+ + Power,
changing boot order), it must be documented with photos before first boot, not
discovered mid-install. Confirm on your own device and write it down.

**Result: CONFIRMED** (`FINDING-R1-10.5.md`, operator-verified on their own
Deck). No BIOS change needed before install. Boot order already defaults to
Limine (installer self-registers it). Secure Boot was never touched during
the operator's original Omarchy install and it worked — direct evidence of
the factory state — and the BIOS's `Security` tab exposes no Secure Boot
toggle at all, consistent with it not being user-enforced on this hardware.
No pre-install documentation step needed for either.

### 10.6 Collaboration with `28allday`

**Hypothesis: high receptivity.** They maintain the Gaming Mode script *and*
contribute to mainline Omarchy, and their repo currently has single-digit
stars with one fork — a serious collaborator is likely welcome, and there may
be appetite for Deck support closer to upstream, meaning less needs to live in
a permanent fork. Low-cost, high-upside: open the conversation early rather
than after forking silently.

**Result: PARTIAL, staged for operator review** (`FINDING-R1-10.6.md`).
Drafted, not sent — an outreach message to `28allday`
(`DRAFT-outreach-28allday.md`) referencing the pacman-package architecture
finding above, and five upstream bug reports against `aorumbayev/deckarchy`
covering the §8 hypotheses (`DRAFT-upstream-bugs-deckarchy.md`). One of the
five (ESP `fmask`/`dmask` blocking `limine-snapper.sh`) is flagged as
possibly belonging against `basecamp/omarchy` instead, pending a repro
re-check before filing. Nothing has been posted or sent anywhere; sending
is a separate, explicit operator-approved action outside this task's scope.

## 11. Long-term maintenance risks (design for these now, not after launch)

These aren't launch blockers but are cheap to design around now and expensive
to retrofit:

- **Kernel version churn breaks the boot entry.** Everything in Section 6.3 is
  pinned to `linux-neptune-611`: the preset filename, the UKI filename, and the
  Limine `path:`. A Valve bump to `linux-neptune-612` would leave users with a
  routine `pacman -Syu` that silently stops producing a bootable Neptune entry.
  **Mitigation:** ship a pacman hook that regenerates the UKI *and* reconciles
  the Limine entry on any `linux-neptune*` package change, keyed on a glob
  rather than a hardcoded version. Test it by forcing a reinstall of the kernel
  package (fast, T3-able) rather than waiting for a real version bump.
- **Omarchy update cadence.** Omarchy updates itself independently; a Quattro
  point release could change shell internals the Desktop Mode icon and QAM hook
  depend on. Keep those integration points as thin and well-isolated as
  possible, with a single test that verifies both directions of session
  switching after any Omarchy update.
- **Recovery path.** Document how a user gets back to stock SteamOS (Valve's
  official recovery image) prominently, ideally before they install. This is
  both an ethical baseline for a wipe-the-device project and the single best
  way to make people comfortable trying it.
- **Trademark and redistribution.** "Steam Deck," "Steam," and Valve's
  iconography are trademarks; the on-screen button glyphs (Section 6.1) and
  project naming need a quick sanity check for whether they can be used or
  need to be original artwork. Likewise confirm the ISO can legally
  redistribute Valve's kernel/firmware packages and any Steam components.
  Cheap to check early, potentially expensive to discover after launch.

## 12. Claude Code: model and effort allocation per task

General rule: **default to Sonnet for implementation, escalate to Opus for
anything where a wrong first guess is expensive to discover** — low-level
boot/filesystem/security logic, and any task whose root cause isn't yet
known (i.e., diagnosis, not implementation). Reach for Opus's plan mode
specifically when a task spans multiple files/repos or has real design
ambiguity; let it produce a plan you review before it writes code. Use
Haiku only for mechanical, low-risk, easily-verified work — its speed is
wasted if you have to double-check its output anyway. Don't over-manage this
— Claude Code tracks a session-local model choice, so switch at natural
boundaries (new task, `/clear`, `/compact`) rather than mid-task.

| Section / task | Model | Why |
|---|---|---|
| 6.1 Gamepad→input spike | **Opus, plan mode first** | Real design ambiguity (uinput vs. a hosted UI); a wrong early call here reshapes Track C's entire scope |
| 6.1a Installer screen flow/UI code | Sonnet | Well-specified once the spike answers the approach question |
| 6.2 Package enumeration & offline mirror build | Sonnet, **escalate to Opus for the signing question (10.1)** | Enumeration is mechanical; SigLevel/repo-signing correctness is exactly the "wrong guess is expensive" case |
| 6.3 Kernel/bootloader/firmware automation | **Opus** | This is precisely the class of bug this session hit repeatedly by hand (silent failures, wrong ESP paths, mount-option subtleties) — worth the upgrade to get it right the first time and avoid re-debugging in CI |
| 6.4 Gaming Mode fork / Deck-ization | Sonnet for the fork/rewrite mechanics; **Opus for the TDP/fan/sysfs tuning logic specifically** | Hardware control code is the other "wrong guess is expensive" case — bad TDP/fan logic risks the actual device |
| 6.5 Hardware parity checklist work | Sonnet, driven by you from hardware output (journalctl, etc.) | Mostly "make this log line say the right thing" — implementation, not design |
| 8.1–8.5 Bug fixes (once hypothesis confirmed) | Sonnet | The hard part (the hypothesis) is already written in this doc; this is implementation against a known root cause |
| 9.1–9.3 Test infra (Ventoy workflow docs, override-dir mechanism, CI YAML) | Sonnet, **Haiku for the CI YAML boilerplate itself** | Config-file generation from a clear spec is Haiku's sweet spot |
| 9.4 rsync/SSH iteration tooling | Sonnet | Small, well-defined script |
| 10.1–10.6 Open-question verification tasks | **Opus, plan mode** | These are research/investigation tasks by design — you want a documented finding, not a fast guess |
| 11 Pacman hook for kernel-version churn | **Opus** | Same class as 6.3 — boot-critical, silent-failure-prone if wrong |
| README / issue text / PR descriptions for upstream deckarchy bugs | Haiku or Sonnet | Low-risk, easily reviewed by eye before submitting |
| Trademark/recovery-path documentation | Sonnet (or do it yourself) | Judgment call more than a coding task — Claude Code isn't the right tool for the legal-risk read; use it to draft the doc *after* you've made the call |

**Session structure recommendation:** run Tracks A, B, C, D as **separate
Claude Code sessions/worktrees** rather than one long session, since they
touch different repos (Section 5) and mixing them risks context bleed
(e.g., Track C's UI concerns leaking into Track A's kernel-script Opus
session). Use subagents within a track for parallel, independent file edits
(e.g., writing several package-list fixtures at once) — not across tracks.
