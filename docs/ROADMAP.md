# ROADMAP — three phases to a released ISO

> **This is the authoritative ordering of the work.** `docs/PROGRESS.md` holds
> current state and findings; `TASK-*.md` hold the per-task detail; this file
> holds the plan. Written 2026-08-10, after the scope reset (`docs/PROGRESS.md` §2).

## The goal

One bootable USB. Boot it on a Steam Deck, click through with buttons and
trackpads only — including joining Wi-Fi — and land on a Gaming Mode home
screen where controller, Bluetooth, audio and haptics all work, with a
Desktop Mode button that opens **Omarchy 4.0** and a way back.

## The shape of the plan

| Phase | One line | Mostly runs on |
|---|---|---|
| **1 — Answer the unknowns, rebuild the test bed** | Every open question that can change a design gets answered; the Deck is rebuilt onto Omarchy 4.0 | QEMU + one big Deck session |
| **2 — Build the product** | Installer UI, session/parity completion, the ISO itself | Dev machine + QEMU, short Deck iterations |
| **3 — Prove it like a user, release** | Factory-reset the Deck, install from our ISO exactly as an end user would, release | Deck |

Two operator decisions shape this plan (`docs/PROGRESS.md` §2):
**wiping/rebuilding the Deck is acceptable** (2026-08-10), and the install
may use Wi-Fi. The first turns the old "protect the precious install"
posture into a plan that *uses* rebuilds deliberately — once in phase 1 to
modernize the test bed, once in phase 3 as the genuine release test.

---

## Phase 1 — Answer the unknowns, rebuild the test bed

### The key move: one Deck rebuild closes five open items at once

Boot the **stock Omarchy 4.0 beta ISO** on the Deck and install it fresh
(wipe approved). That single session:

1. **Answers §5.1 (top open issue):** does Wi-Fi work in the live ISO, which
   runs Arch's stock kernel and firmware — not Neptune?
2. **Recons the live environment** for T4/T5: display rotation (the Deck
   panel is portrait-native; expect the installer to render rotated), input
   enumeration, whether the stock installer even boots/completes on Deck
   hardware.
3. **Replaces the messy 3.8.4-from-git install** with a real, package-based
   Omarchy 4.0 — resolving the "target and test asset disagree" gap
   (`docs/PROGRESS.md` §2.3) without an in-place upgrade.
4. **Hardware-validates the stock→Neptune conversion** (`docs/PROGRESS.md` §5.4):
   on the fresh install, `src/omarchy-deck-kernel.sh` finally runs its real
   conversion path — the firmware swap, the ESP permission cycle, and (new)
   `stage-default-entry` — instead of the no-op path.
5. **Wipes the DeckShift hybrid hand-edits** — no careful manual unwind
   needed, and the `/tmp` backup rescue stops mattering.

Worst case at any point: Valve's recovery image → stock SteamOS (explicitly
acceptable). There is no unrecoverable state on this path.

### Work items, in order

| # | Item | Where | Task ref |
|---|---|---|---|
| P1.1 ✅ | Close the VM substrate blind spot (snapper snapshot), implement `stage-default-entry` + verify Limine's entry-path form via `LoaderEntrySelected`, run the deliberate-failure test | QEMU | T1 §7–8, `docs/PROGRESS.md` §5.2, §5.3, §5.5 |
| P1.2 ✅ | T2 spike: `uinput` mapper prototype; drive `archinstall` and `gum` with virtual gamepad only | QEMU | `docs/tasks/T2-gamepad-input-spike.md` |
| P1.3 ✅ | T2 spike: `squeekboard` OSK — does focus-triggered text entry work, and can it run in a live-ISO-like environment? Write `docs/findings/T2-gamepad-spike.md`; size T4 | QEMU | `docs/tasks/T2-gamepad-input-spike.md` §4–5 |
| P1.4 🟡 | **ISO ✅ built** (`~/ISOs/omarchy-2026.08.10-x86_64-quattro.iso`). Remaining, operator: Ventoy on the test USB; obtain or build the stock Omarchy 4.0 beta ISO; recovery USB; comms setup | Hardware prep | **`docs/tasks/P15-deck-rebuild-runbook.md`** §1–2 |
| P1.5 | **Deck session (ask first):** recon → wipe → 4.0 → Neptune conversion → session switching, driven over SSH with camera backup | Deck | **`docs/tasks/P15-deck-rebuild-runbook.md`** §3 |

P1.1–P1.3 need no hardware and can proceed immediately; P1.4–P1.5 need the
operator. P1.5 should run *after* P1.1 so the fresh install gets the complete
kernel script including `stage-default-entry`.

### Pre-wipe checklist (operator)

- Anything personal on the Deck you want? Copy it off — the wipe is total.
- Have the Valve recovery image on a second USB *before* starting, not after
  something goes wrong.
- A USB keyboard (or dock) for the dev-time install — the stock installer is
  not controller-navigable. (That's the product gap this project exists to
  fill; using a keyboard for our own dev install is fine.)

### Exit criteria

- [x] **T4's OSK question decided** — the live ISO has no Wayland compositor,
      so a mapper-drawn TTY OSK it is (`docs/findings/T2-gamepad-spike.md` §4)
- [ ] Wi-Fi in the live ISO: **expected yes** — the ISO ships `ath11k`
      `nfa765` firmware + `board-2.bin` + `iwd` (`docs/PROGRESS.md` §5.1).
      Confirm the driver binds on hardware; capture `dmesg | grep ath11k`
      either way
- [ ] Display rotation and input behavior in the live ISO: recorded
- [x] T4's scope known — `docs/findings/T2-gamepad-spike.md` written: **days,
      not weeks**
- [x] `stage-default-entry` shipped, path-form **proven by boot** in QEMU
- [ ] ...and validated on the fresh install (P1.5)
- [x] Deliberate-failure tests run and recorded (three of them)
- [ ] Deck runs Omarchy 4.0 + Neptune, boots it unattended, switches to
      Gaming Mode and back — with zero DeckShift and zero hand-edits

---

## Phase 2 — Build the product

Everything here builds on answered questions. Mostly dev-machine work with
short, targeted Deck iterations over `tools/deck-sync.sh`.

| # | Item | Where | Task ref |
|---|---|---|---|
| P2.1 | Desktop-mode input mapper as a `--user` service + `squeekboard`, on the Deck; verify against 4.0's `uwsm` targets | Deck (short) | `docs/tasks/T3-gaming-mode.md` §4 |
| P2.2 | Hardware parity batch 1: Wi-Fi, BT, audio, trackpads/gyro, buttons in both sessions → `docs/findings/hardware-parity.md` | Deck | `docs/tasks/T3-gaming-mode.md` §5 |
| P2.3 | Hardware parity batch 2: TDP, fan, battery — **operator approval per item, every time** | Deck | `docs/tasks/T3-gaming-mode.md` §5 |
| P2.4 | Shell integration on Quickshell (now testable): pin the return icon, QAM/Power-menu trigger placement | Deck (short) | `docs/tasks/T3-gaming-mode.md` §6 |
| P2.5 | T4: the 8 installer screens, per T2's finding; rotation handling per P1.5's recon | QEMU | `docs/tasks/T4-installer-ui.md` |
| P2.6 | T4: full install flow in QEMU with virtual gamepad only, no keyboard | QEMU | `docs/tasks/T4-installer-ui.md` |
| P2.7 | T5: fork `omarchy-iso`; Deck pacman package + `pre-refresh-pacman.d/` hook; Valve repos into the build; live-image firmware per §5.1's answer; `lib32-vulkan-radeon` pinned | Dev | `docs/tasks/T5-iso-and-payload.md` |
| P2.8 | T5: script-override loader wired; CI builds the ISO on tag; size recorded | Dev + CI | `docs/tasks/T5-iso-and-payload.md` |

### Exit criteria

- [ ] A complete controller-only install runs start to finish in QEMU from
      our ISO — zero keyboard input
- [ ] Every hardware-parity row has a recorded result on OLED (LCD rows
      marked untested)
- [ ] Both session-switch directions survive reboot, icon pinned on
      Quickshell
- [ ] CI publishes an ISO artifact; a dry run shows zero NVIDIA packages

---

## Phase 3 — Prove it like a user, release

The release test **starts from a factory reset** — deliberately. The
project's promise is "behaves like a factory-reset Deck"; the test should
begin where the user does. This also produces the recovery documentation as
a byproduct: we exercise Valve's recovery image ourselves and write down
exactly what we did.

| # | Item | Task ref |
|---|---|---|
| P3.1 | Factory-reset the Deck via Valve's recovery image; **document the recovery path while doing it** (this becomes the README section) | `docs/tasks/T6-integration-release.md` §4 |
| P3.2 | Full hardware matrix, one run, in order: Ventoy boot → controller-only install (no keyboard attached, Wi-Fi joined on-screen) → first boot lands in Gaming Mode → Steam signs in → hardware works → Desktop Mode → back → reboots persist | `docs/tasks/T6-integration-release.md` §2 |
| P3.3 | Kernel-update resilience: force a kernel reinstall, reboot, Neptune entry still default | `docs/tasks/T6-integration-release.md` §3 |
| P3.4 | Fix → re-run the affected portion; be honest about blast radius | `docs/tasks/T6-integration-release.md` §2 |
| P3.5 | Trademark/glyph check (Valve iconography), honest LCD statement, known-issues list | `docs/tasks/T6-integration-release.md` §5, `docs/PROGRESS.md` §5.8 |
| P3.6 | Rebase onto Omarchy 4.0 **stable** (whenever it lands — if it lands earlier, fold in during phase 2), re-verify the shell hooks | `docs/tasks/T6-integration-release.md` §1 |
| P3.7 | Tag, build, checksum, publish | `docs/tasks/T6-integration-release.md` §7 |

### Exit criteria

- [ ] The full matrix passes in a single run on OLED hardware
- [ ] Recovery path documented prominently in the README
- [ ] Release published with checksum; claims match what was actually tested

---

## Standing risks, by phase

| Risk | Phase | Mitigation |
|---|---|---|
| Live ISO can't drive the OLED radio | 1 | Firmware into the live image (`docs/tasks/T5-iso-and-payload.md` §2); worst case partially reopens the offline-mirror question |
| Live ISO renders rotated / unusable | 1 | Recon in P1.5; kernel cmdline rotation flags exist; gamescope handles it post-install |
| Stock Omarchy ISO won't boot/install on Deck at all | 1 | Itself a critical T5 finding; recovery image is the floor |
| T2 concludes custom UI needed for many screens | 1→2 | That's what the spike is *for*; scope conversation before phase 2 |
| Omarchy 4.0 beta churn breaks shell hooks | 2 | Keep integration points thin (`docs/PLAN.md` §11); re-verify at P3.6 |
| TDP/fan work damages hardware | 2 | Per-item operator approval, every time — unchanged hard rule |
| 4.0 stable lands late | 3 | Everything through P3.5 works on beta; only P3.6 gates on stable |
| LCD divergence | 3 | Ship "OLED-verified, LCD-untested," recruit a tester after release |
