# ROADMAP — four phases: a released ISO, then a reusable layer

> **This is the authoritative ordering of the work.** Phases 1–3 ship one
> Deck-ready distro; **phase 4 (added 2026-08-10)** turns that into a layer so
> the next one costs ~a day.
>
> **🆕 Phase 2.9 (added 2026-08-11)** sits between building the product and
> proving it: upstream shipped a second 4.0 beta, and everything this project
> owns gets moved onto it *before* the release run starts. Rebasing inside
> phase 3 would mean two moving variables and one matrix.
>
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
| **2.9 — Catch up to upstream** 🆕 | Started as "rebase onto **4.0 beta 2**". **Measurement showed we were already there** (same `6d7826d`, same channel, same builder), so it became: pin it, classify what a *future* move would bring, and fix what the classification exposed | Dev machine + QEMU, one Deck pass |
| **3 — Prove it like a user, release** | Factory-reset the Deck, install from our ISO exactly as an end user would, release | Deck |
| **4 — Generalise: the Deck enablement layer** | Turn one distro's hard-won result into a layer, so the next distro is ~a day of porting instead of sixteen sessions | Dev machine + one validation pass per distro |

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
| P1.4 ✅ | Ventoy 1.1.17 on the stick + ISO sha256-verified on it; Valve recovery image downloaded (not flashed — single-stick deviation) | Hardware prep | **`docs/tasks/P15-deck-rebuild-runbook.md`** §1–2 |
| P1.5 ✅ | **Done 2026-08-10, all six phases in one session:** recon → wipe → 4.0 → Neptune conversion → session switching, driven over SSH (Wi-Fi, no camera needed) | Deck | `docs/findings/P15-live-iso-recon.md` |

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

### Exit criteria — ✅ ALL MET (2026-08-10). **Phase 1 is complete.**

- [x] **T4's OSK question decided** — mapper-drawn TTY OSK
      (`docs/findings/T2-gamepad-spike.md` §4)
- [x] **Wi-Fi in the live ISO: YES**, confirmed on hardware — driver binds,
      scan, WPA2, DHCP. Chip is **QCA2066**, not the QCNFA765 assumed; the
      firmware that matters is `ath11k/QCA2066/` (R-0, R-6)
- [x] Display rotation and input behavior recorded — and richer than expected:
      **lizard mode leaves the gamepad node silent** (R-8), which re-scopes T4
- [x] T4's scope known — **days, not weeks**
- [x] `stage-default-entry` shipped, path-form proven by boot in QEMU
- [x] ...and validated on the fresh install — `LoaderEntrySelected` read from
      firmware after an unattended boot (R-13)
- [x] Deliberate-failure tests run and recorded
- [x] Deck runs Omarchy 4.0 + Neptune, boots unattended, switches to Gaming
      Mode and back — **zero DeckShift, zero hand-edits** (R-18)

**Caveat carried into phase 2:** the Gaming→Desktop direction was proven via
our shim, **not** via Steam's own Power-menu item, which never appeared
(`docs/PROGRESS.md` §5.10). That is the half a user actually touches.

---

## Phase 2 — Build the product

Everything here builds on answered questions. Mostly dev-machine work with
short, targeted Deck iterations over `tools/deck-sync.sh`.

| # | Item | Where | Task ref |
|---|---|---|---|
| P2.0 ✅ | **Done 2026-08-10 (session 15).** §5.10 Steam's own Switch-to-Desktop proven end to end; §5.14 updater stub; §5.11 greeter + desktop rotation. Opened §5.15, §5.16 | Deck | `docs/findings/P2-steam-integration-and-rotation.md` |
| P2.0b ✅ | **Done 2026-08-10 (session 16).** §5.15's two user-visible helpers shipped as `deck-session.sh` stages: `steamos-set-timezone` and `steamos-priv-write`, signatures measured from Steam's log, both hardware-verified. `jupiter-hw-support` **skipped** by operator decision. Opened §5.17 | Deck + Dev | `docs/PROGRESS.md` §5.15 |
| P2.0d 🟡 | **§5.17** — *answered, not closed.* A narrower grant is **impossible** (the stages write to `/etc/sudoers.d/` itself), so the fix is to keep it off the image. `stage-audit-privileges` now gates it; **P2.7 must exclude it from the payload** | Deck + Dev | `docs/PROGRESS.md` §5.17 |
| P2.0c ✅ | **Done 2026-08-10 (session 16).** §5.16's real cause found (the STOP times out) and fixed; **20/20 soak cycles clean**, zero start-limit-hit. Found and half-fixed §5.18 on the way | Deck | `docs/PROGRESS.md` §5.16, R-27 |
| P2.0e ✅ | **Done 2026-08-10 (session 16).** §5.18 resolved — cause was `steam-launcher.service`'s 60s teardown (R-28). Autologin attempts across 20 switches: 600 → 283 → **20 (ideal)** | Deck | `docs/PROGRESS.md` §5.18, R-28 |
| P2.1 🟡 | **Session 17 corrected this row.** Session 16's "verified on hardware" meant *service active and bound* — the mapper was in fact a **no-op**, because lizard mode keeps `event7` silent, and it hid two defects (d-pad emitted nothing; a resting stick cancelled held directions in ~10 ms). Both **fixed, deployed and verified by pressing buttons** (R-29…R-34). **OSK ✅ works on focus** — gated by one GSettings key that ships `false` (§5.20); T5 must bake it in. **Left:** decide lizard-mode policy for T4, and Gaming-Mode-side button mapping | Deck (short) | `docs/tasks/T3-gaming-mode.md` §4 |
| P2.2 🟡 | Hardware parity batch 1 → `docs/findings/hardware-parity.md`. **Programmatic half done (session 16):** Wi-Fi, BT, audio, display, kernel all at parity. **Session 17 closed two human rows** — button-mapping correctness and trackpad→pointer, both verified on the desktop side — and **corrected the doc's claim that `event7` was available to the mapper** (enumerated, but silent). **Gaming Mode confirmed usable on screen by the operator** (R-38), closing P16's "never verified as usable" caveat. **Remaining rows still need a human:** audible sound, headphone jack, mic, haptics, gyro, BT pairing — in both sessions | Deck | `docs/tasks/T3-gaming-mode.md` §5 |
| P2.3 | Hardware parity batch 2: TDP, fan, battery — **operator approval per item, every time** | Deck | `docs/tasks/T3-gaming-mode.md` §5 |
| P2.4 🟡 | Shell integration on Quickshell. **Mechanism found (session 16):** the Omarchy menu is extensible via `~/.config/omarchy/extensions/omarchy-menu.jsonc`, taking a **Nerd Font glyph** (no Valve artwork needed). Also fixed a broken `Icon=steamicon` in the launcher entry. **Left:** add the row, and QAM/Power-menu placement | Deck (short) | `docs/tasks/T3-gaming-mode.md` §6 |
| P2.4b ✅ | **T8: the on-screen keyboard we draw ourselves** — split layout, **two cursors** (one per trackpad), one core with a TTY renderer for the installer and a layer-shell renderer for Desktop Mode. squeekboard cannot do dual-cursor selection in any configuration, and the live ISO has no compositor at all (T2 §4). **Steps 1–6 done (session 18):** the layout core with two absolute cursors, the mapper declaring every character keycode, **both renderers** — `deck_osk_tty.py` for the installer's bare console and `deck_osk_wayland.py` as a layer-shell overlay for Desktop Mode — and `--osk-backend {dbus,tty,layer,none}`. 352 unit assertions plus a 19-assertion end-to-end drive, **60/60 mutations caught**. The overlay is **verified on Hyprland**: a real layer surface that never takes focus, driven from a virtual pad. **Step 7 done and PROVEN ON HARDWARE** (R-43): unit rewritten to `--osk-backend=layer`, STEAM+X confirmed by the operator on the Deck, zero fallbacks. squeekboard stays installed as the automatic fallback. The pass also found and fixed a defect nothing here could see — the mapper died on every pad re-enumeration, 6 crashes a boot against a StartLimitBurst of 5 (R-44). Still owed: the TTY keyboard and `gum` sharing one console in QEMU, and focus-triggered auto-show | Dev + Deck | `docs/tasks/T8-onscreen-keyboard.md` |
| P2.5 | T4: the 8 installer screens, per T2's finding; rotation handling per P1.5's recon | QEMU | `docs/tasks/T4-installer-ui.md` |
| P2.6 | T4: full install flow in QEMU with virtual gamepad only, no keyboard | QEMU | `docs/tasks/T4-installer-ui.md` |
| P2.7 | T5: fork `omarchy-iso`; Deck pacman package + `pre-refresh-pacman.d/` hook; Valve repos into the build; live-image firmware per §5.1's answer; `lib32-vulkan-radeon` pinned. **Also now: bake the desktop rotation into the image** (§5.11 — it currently lives in one user's `~/.config/hypr/monitors.lua`) | Dev | `docs/tasks/T5-iso-and-payload.md` |
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

## Phase 2.9 — Catch up to upstream: rebase onto 4.0 beta 2

**Added 2026-08-11 by operator direction.** Full detail:
`docs/tasks/T9-beta2-rebase.md`. Seeded delta measurement:
`docs/findings/T9-beta2-delta.md`.

Everything this project owns currently sits on the 4.0 snapshot of
**2026-08-10**: the built ISO, the QEMU substrate, both install scripts, the
input/OSK layer, and the test Deck. This block moves all of it onto beta 2 and
**re-establishes by measurement** every recorded fact that names upstream
behavior.

🔥 **RESOLVED 2026-08-11, and the premise was wrong in our favour: we were
already on beta 2.** Both ISOs were unpacked and their manifests diffed
(`docs/findings/T9-iso-comparison.md`). Upstream's
`https://iso.omarchy.org/omarchy-quattro-beta2.iso` and our 2026-08-10 build
carry the **same `omarchy-dev 4.0.0.r1617.g6d7826d-1`**, the same
`basecamp/omarchy` commit **`6d7826d`**, the same **`edge`** channel and the
same `omarchy-iso` builder **`a12bfea`** — 1244 packages each, none exclusive to
either, differing only in **7 stock Arch rebuilds that ours carries the newer
of**. **P2.9a is done and P2.9c's rebuild is skipped.**

**So the block's remaining value is forward-looking.** The drift that matters is
`6d7826d` → `quattro` HEAD — **36 commits, 1 BREAKS US, 27 RE-VERIFY** — which
is what moving to edge, or eventually to stable, would bring. The BREAKS US row
(a stranded-lock recovery path that calls `beginLock()` without reading
`idle.lock`, under a session lock that renders above our OSK's layer surface) is
**the strongest argument for staying pinned at beta 2**, where we already are.

⚠️ **Timing.** The thread that surfaced beta 2 is titled *"Omarchy Quattro will
be shipping this week."* If 4.0 stable lands within days, this block and P3.6
are one rebase, not two — decide before spending an operator session.

**Why it is a block and not a footnote:** the drift is already measured and it
is not cosmetic. In 37 commits upstream changed a sudoers file this repo quotes
verbatim, renamed three `omarchy-apply-*` binaries the ISO builder calls, edited
the Quickshell **lock service** whose idle policy we deliberately neutered,
edited the menu file our Desktop Mode row extends, and added four migrations
that run as root on update — one of which rewrites `/etc/bluetooth/main.conf`
and notes that an update over SSH would otherwise abort. We update over SSH.

| # | Item | Where | Task ref |
|---|---|---|---|
| P2.9a ✅ | **DONE 2026-08-11.** Pin measured from inside both images: `6d7826d` / `edge` / builder `a12bfea` — identical in ours and upstream's. Was: **choose the target, then pin it** — beta 2 the artifact, or edge HEAD? Then the `omarchy-iso` SHA it was cut from, the `basecamp/omarchy` SHA inside it, and the channel (mirror *and* pkgs, which can disagree). Every later item cites it; none says "latest" | Dev | T9 §1 |
| P2.9b ✅ | **DONE 2026-08-11** — `docs/findings/T9-delta-classification.md`, 65 rows, every verdict citing a patch read: **1 BREAKS US, 27 RE-VERIFY, 37 NO IMPACT**. Plus `T9-coupling-inventory.md`: 154 dependencies on Omarchy, **66 of them (43%) would break with nothing noticing**. Was: **measure the delta against our seams before touching anything** — finish `docs/findings/T9-beta2-delta.md`, every row marked *no impact · re-verify · breaks us*. ⚠️ Includes reading the new `migrations/*.sh`, which run as root on update | Dev | T9 §2 |
| P2.9c 🟡 | **Download + inspection DONE; the rebuild is SKIPPED with cause** — our image already carries beta 2's exact inputs, so rebuilding reproduces a file we have. Both image-measured facts re-confirmed: no Wayland compositor in the live environment (stronger — **no `libwayland-*.so` at all**) and the LUKS2 default (§5.12). Was: **download upstream's beta 2 ISO and read what it contains** (operator approval — 6.0 GB, no published checksum), *then* rebuild ours from the pinned `omarchy-iso` with §3.10's three gotchas intact — **unless inspection shows the two images match**, which is plausible: ours was cut 2h14m earlier from what looks like the same builder commit. Re-inspect for the two facts measured *from the image*: no Wayland compositor in the live environment (T2 §4) and the encryption default (§5.12) | Dev | T9 §3 |
| P2.9d ✅ | **Substrate rebuilt from `edge` and the pin proven live by a deliberate-failure build** (wrong pin → the build dies naming both versions). 3 of 4 VM suites pass against it — `vm-default-entry` again proving the path form *by booting it*. **The 4th, `vm-kernel-hook-test`, failed for the right reason:** `limine-mkinitcpio-hook` 1.36.0→1.37.1 stopped writing the UKI itself and delegates to a content-addressed `limine-entry-tool`, so the suite's **mtime sentinel is no longer a valid regeneration oracle** (§7). Our hook is not at fault — proven by gap A rebuilding correctly in the same run. **Oracle replaced with a build nonce** (perturb the inputs, assert the content changed) — it now passes on **both** substrates, and a mutation that stubs the installer so nothing regenerates is caught while every exit code stays 0. The `edge` substrate is swapped in; the `stable` one is kept as `neptune-substrate.prev.raw` for A/B work. **All four VM suites green.** Was: **rebuild the QEMU substrate from that ISO** and re-run everything hardware-free: shellcheck's own command, both unit globs, the VM suites, and `osk-tty-e2e.py` by hand. ⚠️ A substrate that mimics the *old* Quattro passes while testing a system that no longer exists | Dev + QEMU | T9 §4 |
| P2.9e | **Bring the Deck to the pinned target** — snapshot #8 first, then **in-place `omarchy-update`** (recommended over a reinstall: phase 3 already buys the clean-install proof). ⚠️ **An unpinned update lands on edge, not beta 2** — honour the P2.9a choice or record honestly which one the Deck ended up on. Re-run every `deck-session.sh` stage — the first real test of the idempotence claim against a moved substrate — plus `stage-audit-privileges`, `dconf read -d`, `lizard_mode`, and a switch soak of ≥5 cycles | Deck | T9 §5 |
| P2.9f | **The hands-on pass** — OSK on STEAM+X, both cursors including diagonals, both switch directions, the Desktop Mode menu row, and every P2.9b row marked *re-verify*. Batch into one operator session | Deck | T9 §6 |
| P2.9g | **Update the record** — the pin in `docs/PROGRESS.md` §1.1, a §5.22 outcome, and every §7 fact that names upstream behavior. A stale entry under "don't re-derive" is worse than no entry | Dev | T9 §7 |

**Ordering.** P2.9a–P2.9d need no hardware and can run at any point. P2.9e is
better *after* T5's ISO fork exists (the fork inherits the pin, and rebuilding
twice is waste) — but waiting is not required, and a test bed running an old
beta silently invalidates every hardware fact recorded against it.

**This does not replace P3.6.** That one rebases onto 4.0 **stable** and still
gates the release. What phase 2.9 buys is that P3.6 will be the *second* time
this procedure runs, not the first.

### Exit criteria

- [ ] The pin is three SHAs + a version string + a channel, written down
- [ ] The delta document classifies **every** changed upstream file that
      touches a listed seam — no "probably fine" rows
- [ ] A new ISO exists from the pinned builder, sha256 recorded, re-inspected
      rather than assumed
- [ ] Substrate rebuilt; all 11 unit suites, the VM suites and the e2e drive pass
- [ ] The Deck runs beta 2, every install stage re-ran clean, load-bearing
      settings verified with `dconf read -d`, switch soaked ≥5 cycles
- [ ] The hands-on list is signed off **on screen**, not inferred from logs
- [ ] Every §7 fact naming upstream behavior is re-checked or deleted

---

## Phase 3 — Prove it like a user, release

The release test **starts from a factory reset** — deliberately. The
project's promise is "behaves like a factory-reset Deck"; the test should
begin where the user does. This also produces the recovery documentation as
a byproduct: we exercise Valve's recovery image ourselves and write down
exactly what we did.

| # | Item | Task ref |
|---|---|---|
| P3.1 | Factory-reset the Deck via Valve's recovery image. **`docs/RECOVERY.md` is already drafted (session 16) from Valve's published process** — P3.1's job is now to *exercise* it and replace the draft with a first-hand account, including the real recovery-menu option names | `docs/tasks/T6-integration-release.md` §4 |
| P3.2 | Full hardware matrix, one run, in order: Ventoy boot → controller-only install (no keyboard attached, Wi-Fi joined on-screen) → first boot lands in Gaming Mode → Steam signs in → hardware works → Desktop Mode → back → reboots persist | `docs/tasks/T6-integration-release.md` §2 |
| P3.3 | Kernel-update resilience: force a kernel reinstall, reboot, Neptune entry still default | `docs/tasks/T6-integration-release.md` §3 |
| P3.4 | Fix → re-run the affected portion; be honest about blast radius | `docs/tasks/T6-integration-release.md` §2 |
| P3.5 | Trademark/glyph check (Valve iconography), honest LCD statement, known-issues list | `docs/tasks/T6-integration-release.md` §5, `docs/PROGRESS.md` §5.8 |
| P3.6 | Rebase onto Omarchy 4.0 **stable** (whenever it lands — if it lands earlier, fold in during phase 2), re-verify the shell hooks. **Run phase 2.9's procedure** (`docs/tasks/T9-beta2-rebase.md`) rather than improvising: by then it has been executed once, on a step that does not gate the release | `docs/tasks/T6-integration-release.md` §1 |
| P3.7 | Tag, build, checksum, publish | `docs/tasks/T6-integration-release.md` §7 |

### Exit criteria

- [ ] The full matrix passes in a single run on OLED hardware
- [ ] Recovery path documented prominently in the README
- [ ] Release published with checksum; claims match what was actually tested

---

## Phase 4 — Generalise: the Deck enablement layer

**Full detail: `docs/tasks/T7-enablement-layer.md`.**
**Why a flasher was reframed into this: `docs/findings/P16-scope-flasher-vs-layer.md`.**

Phase 3 ships *one* Deck-ready distro. Phase 4 makes the second one cheap.

**Why after phase 3, not during.** Extracting an abstraction from one example is
guessing; extracting it from one finished, released, soak-proven example is
engineering. The interface must be derived from what actually turned out to be
distro-specific — measured at **26%** of `omarchy-deck-kernel.sh` and **13%** of
`deck-session.sh`, with `deck-input-mapper.py` at **0%** — rather than from what
looks like it ought to be.

⚠️ **What "a day" buys, stated up front:** ported and conformance-green. **Not
shippable.** §5.18 first appeared on soak cycle 4, §5.16 needed a journal read
across two boots, and three of this project's own checks were wrong about
themselves. Soak time is wall-clock and no abstraction compresses it.

| # | Item | Where |
|---|---|---|
| P4.1 | Write the **"Deck-ready" contract** — a capability checklist where every row names its oracle *and* whether a machine or a human decides it | Dev |
| P4.2 | **Extract the portable core** (the five `render_*` helpers, the session-switch policy, the mapper, the probes). Prove it by making Omarchy consume it with the existing 70 assertions and the soak **unchanged** | Dev |
| P4.3 | **Define the profile interface**, derived empirically from the measured distro-specific surface — package names, kernel, boot chain, initramfs, display manager, session target | Dev |
| P4.4 | **Generalise the conformance suite** into one `deck-conformance` runner. Every check must distinguish "found nothing" from "looked in the wrong place" — **mutation-test it** | Dev |
| P4.5 | **Porting guide + traps document.** The traps are the higher-value half: `comm` truncation, `After=` ordering cycles, `StartLimit*` placement, Steam's fallbacks, blocking reads on input nodes, `uaccess` vs groups | Dev |
| P4.6 | **Port a second, NON-Arch distro** and record the real elapsed time. The only real test of the claim | Dev + Deck |
| P4.7 | Consider **upstreaming** the `steamos-*` helpers — ⚠️ public action, needs operator approval | — |

### Exit criteria

- [ ] Omarchy runs on the extracted core with the existing suite **unchanged**
- [ ] A distro profile is under ~250 lines against a documented interface
- [ ] `deck-conformance` prints the capability matrix and is mutation-tested
- [ ] **A second, non-Arch distro is ported, with its real elapsed time written
      down** — including where the interface leaked
- [ ] The guide states plainly that a day buys *green*, not *shippable*

### Deliberately out of scope

**Hosting or distributing distro images.** This layer is code. Shipping images
reopens `steamdeck-dsp` (`Proprietary`, no licence text) as a redistribution
problem at scale, and puts a stranger's bricked handheld on the support surface
— see `docs/findings/P16-redistribution-and-trademark.md`. [Bazzite](https://docs.bazzite.gg/Handheld_and_HTPC_edition/Steam_Gaming_Mode/)
and ChimeraOS already ship Deck-ready images; the differentiated thing here is
the **controller-only install** and the enablement layer beneath it, not the
flashing.

---

## Standing risks, by phase

| Risk | Phase | Mitigation |
|---|---|---|
| ~~Live ISO can't drive the OLED radio~~ | 1 | **RETIRED** — works on hardware (R-0). No firmware needs baking into the live image |
| ~~Live ISO renders rotated / unusable~~ | 1 | **NARROWED TWICE.** Greeter and desktop are fixed and seen (§5.11, transform **3**). What remains is the **Limine menu** — **fix found** (`interface_rotation: 270`, Limine ≥v10; Deck has 12.5.2) but not applied, boot-chain — plus the TTY (`fbcon=rotate:1`, same). Both await approval, and **T5 must bake both into the image** |
| Steam's system integration is absent, not just its updater | 2 | **NARROWED** — §5.15's two user-visible helpers (brightness, timezone) now ship; the six `jupiter-*` are skipped by decision. Residual: Steam **falls back** to blanket `sudo` when a helper is missing, so absence looks like health on a test rig |
| The test Deck is more privileged than the product, hiding defects | 2 | §5.17 — `99-deck-testing` grants the desktop user blanket NOPASSWD and sorts last, overriding every narrow grant. Anything privilege-dependent verified here is suspect until re-checked without it |
| ~~A session switch bricks the display manager~~ | 2 | **RETIRED** — §5.16 resolved: cause was sddm's stop timing out, now `TimeoutStopSec=30` + stop→settle→start in a transient unit. 20/20 soak clean |
| ~~A switch visibly thrashes before it lands~~ | 2 | **RETIRED** — §5.18 resolved (R-28). Residual: a switch *away from* Gaming Mode can take ~1 min, dominated by Valve's `steam-launcher` `TimeoutStopSec=60`. Correct and flicker-free, but not fast |
| ~~Stock Omarchy ISO won't boot/install on Deck~~ | 1 | **RETIRED** — boots and installs; the surprise was its **encryption default** (§5.12) |
| Our fork inherits upstream's encryption default | 2 | Ship it off by default; TPM2 auto-unlock as follow-on (§5.12) |
| ~~Valve's packages shadowed by Arch's~~ | 2 | **RETIRED** — audit done (P16). 101 overlaps, Valve older in 50, so reordering is rejected; the real surface is one package and the fix is `pacman -S jupiter-staging/gamescope` (§5.13) |
| T2 concludes custom UI needed for many screens | 1→2 | That's what the spike is *for*; scope conversation before phase 2 |
| Omarchy 4.0 beta churn breaks shell hooks | 2 → **2.9** | **No longer hypothetical.** In 37 commits upstream changed a sudoers file this repo quotes, renamed three `omarchy-apply-*` binaries, and edited both the menu file and the lock service we hook. Keep integration points thin (`docs/PLAN.md` §11); **absorb the churn deliberately at phase 2.9**, re-verify again at P3.6 |
| An upstream **migration** reverts a load-bearing setting on update | 2.9 | Migrations run as root, machine-wide, during `omarchy-update`; one already rewrites `/etc/bluetooth/main.conf` and can abort over SSH. **Read them before updating** (P2.9b), then re-verify with `dconf read -d` and `shell.json` after (P2.9e) — the idle lock and the two OSK GSettings fail no test today |
| "Beta 2" is pinned by name and the name means nothing | 2.9 | `edge` tracks `quattro` HEAD, rebuilt within minutes of a commit, versioned `4.0.0.rN.gSHA`. Two installs can both say `4.0.0` and be 600 commits apart. **Pin the SHA** (P2.9a) |
| TDP/fan work damages hardware | 2 | Per-item operator approval, every time — unchanged hard rule |
| 4.0 stable lands late | 3 | Everything through P3.5 works on beta; only P3.6 gates on stable |
| LCD divergence | 3 | Ship "OLED-verified, LCD-untested," recruit a tester after release |
| The abstraction is extracted from one example and fits only it | 4 | P4.2 proves it by making Omarchy consume the core with the suite **unchanged**; P4.6 tests it on a deliberately non-Arch distro |
| A conformance suite goes green for the wrong reason | 4 | Three of this project's own checks already did. Every check must distinguish "found nothing" from "looked in the wrong place"; mutation-test the suite |
| "~A day" gets quoted as "a day to ship" | 4 | The guide and the ROADMAP both state it buys ported-and-green. Soak time is wall-clock |
