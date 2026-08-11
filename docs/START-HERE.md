# START HERE — Omarchy Deck build session

**You are Claude Code. This is your entry point. Read it fully, then begin
work without waiting for further instruction.**

> ## Where things stand (updated 2026-08-10, end of session 17)
>
> ### 🆕 SESSION 17 WAS THE FIRST TIME ANY OF THIS WAS SEEN ON A SCREEN — read this first
>
> Session 16 ended admitting *"nothing here was seen on a screen."* Session 17
> put the operator in front of the Deck for the **input** half. What a passing
> unit suite and `systemctl is-active` had been hiding:
>
> - **The input mapper was a COMPLETE NO-OP on the desktop.** It was `active`
>   and correctly bound to `event7`, and that node is **silent** — lizard mode
>   routes the buttons to the emulated nodes instead. P2.1's "verified on
>   hardware" was true in every particular and proved nothing.
> - **The d-pad emitted nothing**, because the Deck sends `BTN_DPAD_*` buttons
>   and the mapper only handled `ABS_HAT0*` axes — which `hid-steam`
>   *advertises and never sends*. The suite passed because it drove a device
>   model this hardware does not use.
> - **A resting analog stick cancelled every held direction in ~10 ms**, killing
>   auto-repeat, because two input sources shared one state slot.
> - Both are **fixed, deployed, and verified by pressing the buttons.** Hold and
>   auto-repeat now measure exactly `REPEAT_DELAY`/`REPEAT_INTERVAL`.
> - **CI was RED** — `shellcheck` exit 1 — while `docs/PROGRESS.md` claimed it
>   passed. Cause: an unquoted heredoc that **executed `uwsm start ... Hyprland`
>   as root** at file-generation time. Fixed.
> - **The OSK works on text focus** (§5.20), gated by one GSettings key that
>   ships `false`: `org.gnome.desktop.a11y.applications screen-keyboard-enabled`.
>   It was first recorded here as a *negative* after four failing experiments —
>   all of which sat downstream of that one gate. **Four experiments sharing a
>   hidden precondition are one experiment**; a `WAYLAND_DEBUG=1` trace found it
>   in minutes and needed no operator.
> - **Gaming Mode was confirmed usable by the operator** (R-38), closing P16's
>   caveat that the session was only ever known to *exist*.
> - 🆕 **§2.6 decides the keyboard: squeekboard for the INSTALLER, Steam's own
>   thereafter** — but its Desktop Mode half is 🐞 **BLOCKED by R-41**. With
>   Steam resident the desktop gets **no input at all**: every node stays
>   enumerated and **none emits**, because Steam takes the controller over
>   hidraw and feeds only its own UI. The operator hit it as an unexitable
>   screensaver — which is the *symptom*; the desktop was equally unusable
>   without one. **R-39's checks all passed while the device was
>   uncontrollable** — "STEAM+X shows the keyboard" is not evidence the desktop
>   is usable.
>
> Full evidence: **`docs/findings/P17-input-and-osk.md`** (R-29…R-36).
>
> ⚠️ **Three things are load-bearing and silently break the product if lost:**
> the **`omarchy.tray` bar widget** (without a StatusNotifier host, closing
> Steam's window *quits* it and Desktop Mode loses its keyboard), the **idle
> lock staying off** (`shell.json`, and `lock: 0` locks INSTANTLY rather than
> disabling), and the **installer's two GSettings**. None of them fails a test
> today.
>
> ⚠️ **Lizard mode is the load-bearing fact for T4.** It swallows **X, Y, L1,
> R1, STEAM and QAM entirely** — no evdev node sees them — and provides no
> **Space**, which archinstall's multi-select needs. The knob that frees them,
> `/sys/module/hid_steam/parameters/lizard_mode`, also removes the free pointer,
> making the mapper the *only* input path. Do not set it to `N` anywhere until
> the mapper is proven working, or the Deck is uncontrollable without SSH.
>
> ### ✅ PHASE 1 COMPLETE. Phase 2 is underway — the core promise now works.
>
> **T0, R1, T1, T2 done. T3 is close.** Steam's own **Power → Switch to
> Desktop** works end to end on hardware — the affordance a user actually
> touches — and session 16 **soak-proved it, 20/20 cycles clean**. Session 16
> shipped P2.0b, P2.0c, P2.0e, P2.1 and the programmatic half of P2.2.
>
> **The Deck:** package-based **Omarchy 4.0 + Neptune 6.11.11-valve29**,
> Hyprland 0.56.2, unencrypted, booting unattended, **Steam signed in and past
> OOBE**, greeter and desktop rotated correctly, zero DeckShift. Reach it with
> **`ssh steamdeck`** (key-based, passwordless sudo). **7 snapshots** — #1–#3
> P1.5, #4 pre-15, #5 `P2.0 complete`, #6/#7 session 16. Left **on the desktop**;
> `stage-default-session` (boot straight to Gaming Mode) is deliberately not run.
>
> Installed by session 16 and not in any earlier notes: three helpers in
> `/usr/bin/steamos-polkit-helpers/`, the input mapper as a `--user` service
> (`deck-input-mapper.service`, active), plus `python-evdev` and `squeekboard`
> from Arch `[extra]`.
>
> ⚠️ **ONE TEMPORARY CHANGE IS STILL IN EFFECT on the Deck**, operator-requested
> for testing:
>
> 1. **The display never sleeps** — idle/screensaver/lock disabled, sleep
>    targets masked. This is an **OLED** panel, so burn-in is the reason not to
>    leave it. Revert: `sudo /usr/local/sbin/deck-always-on-revert.sh`.
>
> 🆕 **Two GSettings values are set on the Deck and are NOT temporary** — they
> are requirements of **the installer image**, and session 17 corrected an
> earlier note telling you to revert one of them:
>
> - `org.gnome.desktop.input-sources sources` = `[('xkb','us')]` — squeekboard
>   has no keys to draw without it. *(Previously listed here as a temporary hack
>   to undo. It is not.)*
> - `org.gnome.desktop.a11y.applications screen-keyboard-enabled` = `true` —
>   ships `false`, and **the OSK never auto-shows without it** (§5.20).
>
> ⚠️ **They belong to the LIVE ISO, not the installed system** (§2.6): the
> installer uses squeekboard, and everything after install uses **Steam's own
> keyboard**. On the test Deck they are therefore a **known divergence from the
> product** — harmless, since squeekboard is not autostarted, but do not read
> the Deck as evidence of what the installed image should contain.
>
> They are T5 constraints: GSettings in one user's dconf, **absent from a built
> image**. No test would notice — every suite runs on the Deck where they are
> already set.
>
> Also: the backlight sysfs node is deliberately left **0644**, not the 666
> found. If it is 666 again, Steam fell back — which means a helper broke.
>
> **Git:** everything through **session 16** is merged into **`main`** and
> **pushed** to `origin`. Check state with
> `git rev-list --left-right --count origin/main...main` rather than trusting a
> number written here — this block has been stale twice before.
>
> ⚠️ **And treat the rest of this file the same way.** At the end of session 16
> it was re-read as a new session would, and **six claims were stale** — five
> numbers and a set of entry points describing work already finished. Numbers
> here (assertion counts, fact counts, mutation totals, constraint counts) are
> cheap to re-verify against the tree and have been wrong before. Verify, then
> trust.
>
> **Start with the session summaries, newest first** —
> `docs/findings/P16-session-summary.md`, then
> `docs/findings/P2-session-summary.md` and
> `docs/findings/P15-session-summary.md`. They are the orientation pages; the
> R-numbered findings files hold the evidence.
>
> ⚠️ **P16's opening section lists four recorded "facts" it had to correct, two
> of them from session 15.** Read it before trusting §5.15 or §5.16.
>
> Then read, in this order:
> 1. `docs/PROGRESS.md` §1 (state) and §2 (the five scope decisions) — these
>    reversed several earlier ones, and a session that misses them will build
>    the wrong thing
> 2. `docs/PROGRESS.md` **§5.9–§5.20** — the open issues. §5.10/§5.13/§5.14/
>    §5.16/§5.18/**§5.20** are now closed; **§5.17 is the live one**, and
>    **§5.9 gained session 17's measured lizard-mode map**
> 3. `docs/ROADMAP.md` — **four** phases now; phase 2 is the live work queue and
>    **phase 4 is new** (the enablement layer)
> 4. `docs/PROGRESS.md` §7 — 45 facts that each cost real time; do not
>    re-derive them
>
> Hardware evidence: `docs/findings/P15-live-iso-recon.md` (R-0…R-19, raw logs
> in `P15-recon-raw/`), `docs/findings/P2-steam-integration-and-rotation.md`
> (R-20…**R-28**), and **`docs/findings/P17-input-and-osk.md` (R-29…R-36)** —
> the only one so far where a human watched the screen.
>
> ### There are now unit tests. Run them before and after touching `src/`.
>
> ```bash
> for f in test/unit/test-*.sh; do ./"$f"; done   # 5 suites, seconds, no VM
> ```
>
> (That glob is the 5 shell suites; `test/unit/test-deck-input-mapper.py` is a
> sixth and is **not** in it — run it separately.)
>
> `test/unit/test-deck-session.sh` is now **63 assertions** covering all five
> generated files — the `steamos-update` stub's exit-code protocol, the
> install-marker contract, both polkit helpers' argument validation, the sddm
> restart helper's shape, and Steam's shim. It has teeth: **mutation-tested,
> 15/15 then 39/39 faults caught**, including the apply-path drift that rebooted
> the Deck. See `docs/findings/P2-session-summary.md` §6a and
> `docs/findings/P16-session-summary.md` §4 for what it does and does not cover.
>
> ⚠️ Session 16's lesson for writing these: three assertions there pin **which
> guard fired**, via the error message, not just the exit code. Two guards that
> share an exit code make an exit-code-only assertion pass with either one
> deleted — all three cases were caught by mutation testing, not by review.
>
> ⚠️ **`src/deck-session.sh` is source-safe, and the test sources
> it** — so anything you add at TOP LEVEL below the constants runs at source time
> inside the test. Keep new work in functions.
>
> ### ⚠️ Sessions 15 AND 16 each corrected four recorded "facts". Trust the findings, not memory.
>
> Session 15: `transform,1` (it is **3**; 1 is upside down) · the rotation syntax
> (4.0 uses **Lua**, not `.conf`) · "Steam finds `steamos-update` via PATH"
> (**absolute path**) · "`steamos-customizations-jupiter` would supply it"
> (**ships zero polkit helpers**).
>
> Session 16: "the brightness slider does nothing" (**it works** — Steam falls
> back to blanket sudo) · the 666 backlight mode (**Steam sets it**, not a
> human) · "`RestartSec` is the important half" of §5.16 (**it never gated the
> fatal start**) · "§5.16 is a switch defect" (**it fired at boot**).
>
> Two more were defects session 16 introduced *in its own fixes* and caught only
> by mutation testing and soaking — see P16 §4. Verify against hardware before
> building on a recorded value, and **never conclude a check works because it
> passes.**
>
> ### The most important open item
>
> **§5.17 — the test Deck is more privileged than the product will be.**
> `/etc/sudoers.d/99-deck-testing` grants `deck ALL=(ALL) NOPASSWD: ALL`, is
> owned by no package, and **sorts last**, so it overrides every narrow sudoers
> grant this project installs. It must never ship, and until it goes, anything
> privilege-dependent verified on this Deck is suspect.
>
> Session 16 found this the hard way: §5.15 recorded that the missing
> `steamos-priv-write` meant "the brightness slider does nothing", but the
> slider **works here** — Steam falls back to `sudo -n tee`, then
> `sudo -n chmod a+w`, both of which need exactly that blanket grant. Right
> conclusion about the product, wrong belief about the present. **Assume any
> "it works on the Deck" claim about privilege is wrong until re-checked
> without `99-deck-testing`.**
>
> §5.15 itself is now 🟡: its two user-visible helpers ship
> (`stage-timezone-helper`, `stage-priv-write-helper`), and
> `jupiter-hw-support` is skipped by operator decision.
>
> *(**§5.16 and §5.18 are both closed.** §5.16's cause was sddm's stop timing
> out; §5.18's was `steam-launcher.service` taking up to ~53 s to stop, so the
> incoming session started into a teardown. Autologin attempts across 20
> switches went **600 → 283 → 20**, the ideal. Residual: a switch away from
> Gaming Mode can take **~1 minute**, dominated by Valve's `TimeoutStopSec=60` —
> correct and flicker-free, but not fast.)*
>
> ### 🆕 There is now a PHASE 4 — read this before proposing a pivot
>
> **Operator direction, end of session 16.** Phases 1–3 ship *one* Deck-ready
> distro. **Phase 4 generalises it into a Deck enablement layer** so the next
> distro costs ~a day of Claude-assisted porting instead of sixteen sessions.
> Spec: `docs/tasks/T7-enablement-layer.md`. Ordering: `docs/ROADMAP.md` phase 4.
> Decision record: `docs/PROGRESS.md` §5.19.
>
> ⚠️ **"A day" buys ported-and-conformance-green. NOT shippable.** §5.18 first
> appeared on soak cycle 4, §5.16 needed a journal read across two boots, and
> three of this project's own *checks* were wrong about themselves. Soak time is
> wall-clock and no abstraction compresses it. Do not quote "a day to ship".
>
> **Phase 4 comes AFTER phase 3, deliberately.** Abstracting from one *finished,
> soak-proven* example is engineering; from an unfinished one it is guessing.
> P4.2 proves the extraction by making Omarchy consume the core with the
> existing **63 assertions and the soak unchanged** — if those need editing, the
> seam is wrong.
>
> ### ⛔ A Deck-specific USB flasher was considered and REFRAMED — don't re-propose it cold
>
> Full reasoning: **`docs/findings/P16-scope-flasher-vs-layer.md`**. The short
> version, because this idea is intuitive and will come back:
>
> - **"Take any ISO and apply our script" does not work.** The script *is* the
>   distro-specific part — 26% of `omarchy-deck-kernel.sh`, 13% of
>   `deck-session.sh`, and the portable remainder is scaffolding around a core of
>   `pacman`/`limine`/`mkinitcpio`/`sddm`/`uwsm` you would rewrite, not port.
> - **The flasher is the easy ~10%**; Ventoy (which this project already uses),
>   Etcher and Rufus got there first. The cost is per-distro enablement, which is
>   multiplicative and a maintenance treadmill.
> - **Hosting images reopens `steamdeck-dsp`** (`Proprietary`, no licence text)
>   as redistribution at scale, and puts a stranger's bricked handheld on the
>   support surface with `docs/RECOVERY.md` still unexercised.
> - **Bazzite already ships `bazzite-deck` images**; ChimeraOS covers the console
>   case. Deck-ready images are largely solved for gaming distros.
> - **What IS differentiated: the controller-only install**, including Wi-Fi
>   passphrase entry. That is T4, and nobody else is doing it.
>
> If revisited, re-test the **prior art** (a market position that can change),
> not the premise — how distributions differ will not change.
>
> ### One defect still deliberately unfixed — decide before coding
>
> - **§5.12 the 4.0 installer defaults to full-disk encryption.** Inherit it and
>   the ISO produces a device its owner cannot boot without a keyboard.
>
> *(§5.13 is **closed** — session 16 audited the overlap. 101 package names
> collide and Valve's is older in 50, so reordering repos is rejected; the real
> surface is one package and the fix is `pacman -S jupiter-staging/gamescope`.
> See `docs/findings/P16-repo-overlap-audit.md`.)*
>
> ### Good work available *without* the Deck
>
**These two are the bulk of what is left in phase 2**, and neither needs the
> Deck:
>
> - **T4's installer screens (P2.5/P2.6)**, re-scoped by §5.9 — lizard mode
>   already makes the installer navigable, so the real gap is **text entry**.
>   Draw our own button glyphs; do not use Valve's artwork
>   (`docs/findings/P16-redistribution-and-trademark.md`).
> - **T5's ISO fork (P2.7/P2.8)**, `docs/tasks/T5-iso-and-payload.md`, which now
>   carries **six** recorded constraints: offline-only pacman · the encryption
>   default (§5.12) · repo precedence (§5.13) · **baking in BOTH rotations**
>   (desktop `monitors.lua` *and* Limine `interface_rotation`) · **excluding
>   `99-deck-testing`** (§5.17) · 🆕 **the three load-bearing session settings**
>   (§5.20 — `screen-keyboard-enabled`, `input-sources`, rotation), which are
>   GSettings in one user's dconf today and would be simply absent from a built
>   image. Also decide **bundle vs fetch** — `steamdeck-dsp` is `Proprietary`,
>   so bundling redistributes it and fetching does not.

Layout is in `CLAUDE.md`. Paths below are repo-root-relative.

---

## 1. What you are building

A **single bootable ISO** that installs Arch + **Omarchy 4.0 (Quattro)** on a
Steam Deck, navigable start to finish with only the Deck's buttons and
trackpads — no keyboard, no terminal. After install the device behaves like
stock SteamOS: boots to Gaming Mode, all hardware works, and a **Desktop Mode**
button drops into a full Omarchy desktop with a way back.

The install **may use Wi-Fi** — see `docs/PROGRESS.md` §2.2. That is a deliberate
reversal of an earlier "fully offline" constraint, not an oversight.

The operator owns one **OLED Steam Deck** and is on **Claude Max 5x**. They
already did a full manual Omarchy install on that Deck by hand, hit roughly a
dozen distinct bugs doing it, and wrote the findings into `docs/PLAN.md`. **Your job
is to turn that validated manual process into automation** — not to rediscover
it.

---

## 2. Files in this directory

| File | Read it when |
|---|---|
| `CLAUDE.md` | Auto-loaded every session. Hard constraints. |
| `docs/ROADMAP.md` | **The plan — three phases.** Where the current block fits and what gates what. |
| `docs/PROGRESS.md` | **Every session start. This is the authoritative state.** Scope, findings, open issues, and 36 facts not to re-derive. |
| `docs/SESSIONS.md` | Usage-limit budgeting and the block schedule. |
| `docs/PLAN.md` | **Frozen and partly superseded.** Read the banner at the top first. Good for §6.1a (installer screens), §8 (bug hypotheses), §9 (test tiers), §11 (maintenance risks). |
| `docs/tasks/` | One file per work block. |
| `docs/findings/` | Research outputs. Evidence behind the decisions in `docs/PROGRESS.md`. |
| `docs/drafts/` | Staged upstream report. **Nothing sent. Do not send.** |
| `src/omarchy-deck-kernel.sh` | T1's deliverable. Ten idempotent stages, VM-tested and hardware-validated. |
| `src/deck-session.sh` | T3's session-switch layer — **nine** install stages, each self-verifying. Also owns the three `steamos-polkit-helpers` (update stub, timezone, priv-write), the greeter rotation and the SDDM restart drop-in. |
| `test/unit/test-deck-session.sh` | Pins that script's protocol contracts and both new helpers' argument validation — 36 assertions, mutation-tested. No Deck, no VM, no root. |
| `src/deck-input-mapper.py` | T2/T3's gamepad→keyboard mapper. |

New files go in the matching directory — `docs/findings/` for research
outputs, `docs/tasks/` for work specs, `test/unit/` for suites that need no
VM.

---

## 3. Operating rules — how autonomous to be

### Do these without asking

- Read anything, search the web, inspect any repo.
- Create/modify/delete files in this project.
- Run builds, tests, linters, QEMU VMs, `git` operations (including commits
  and pushes to **your own** branches).
- Install packages inside VMs/containers you control.
- Choose implementation details, file layout, naming, libraries.
- Move to the next block when the current one's done-criteria are met.
- Update `docs/PROGRESS.md` — continuously, not just at session end.

### Stop and ask the operator first

- **Anything that writes to the physical Steam Deck** — flashing a USB,
  installing, or modifying its filesystem. They have one device; a bricked
  Deck costs hours. Prepare the change, describe exactly what will happen,
  wait. **Batch these requests** rather than asking per-item.
- Anything touching TDP, fan curves, charge limits, or thermal control on
  real hardware — every time, no exceptions. Genuine hardware-damage risk.
- Publishing anything public: creating public repos, opening upstream
  issues/PRs, posting to forums or Discord.
- Spending real money.
- Any decision contradicting a hard constraint in `CLAUDE.md`.
- Discovering a foundational assumption is wrong. Surface it; don't quietly
  work around it. This has already happened four times and each time it
  changed the plan for the better.

### Never

- Never report a task complete when its done-criteria aren't met. This
  project exists partly because upstream tooling printed "success" while
  doing nothing (`docs/PLAN.md` §8.1). Do not become that.
- Never propose "reinstall on the Deck to test this" for anything not on
  the physical-hardware-only list (`docs/PLAN.md` §9.5). There is almost always
  a faster tier.
- Never depend on something unlicensed or AUR-only. The ISO redistributes
  what it carries.

---

## 4. The work queue

**The ordering lives in `docs/ROADMAP.md` — four phases.** Task-to-phase mapping:

| Task | File | Model | State |
|---|---|---|---|
| T0 | `docs/tasks/T0-test-infrastructure.md` | Sonnet | ✅ done — **both gaps closed by P1.5** |
| R1 | `docs/tasks/R1-research-questions.md` | Opus/Sonnet | ✅ done |
| T1 | `docs/tasks/T1-kernel-and-boot.md` | **Opus** | ✅ done — **hardware-validated 2026-08-10** |
| T2 | `docs/tasks/T2-gamepad-input-spike.md` | **Opus** | ✅ done |
| T3 | `docs/tasks/T3-gaming-mode.md` | Sonnet/Opus | 🟡 **the core promise works, and the switch is now soak-proven** (§5.10 ✅, §5.14 ✅, §5.11 ✅, §5.15 ✅, §5.16 ✅, §5.18 ✅). Left: §5.17, P2.1–P2.4 |
| T4 | `docs/tasks/T4-installer-ui.md` | Sonnet | ⬜ **unblocked, re-scoped by §5.9** → P2.5–P2.6 |
| T5 | `docs/tasks/T5-iso-and-payload.md` | Sonnet/Opus | ⬜ P2.7–P2.8, now with §5.12/§5.13 constraints |
| T6 | `docs/tasks/T6-integration-release.md` | **Opus** | ⬜ phase 3 |
| T7 | `docs/tasks/T7-enablement-layer.md` | **Opus** | ⬜ **phase 4 — NEW.** Generalise into a Deck enablement layer so the next distro is ~a day. Deliberately after phase 3: abstracting from one *finished* example is engineering, from one unfinished example is guessing |

**Phase 1 is closed. P2.0, P2.0b, P2.0c and P2.0e are done**, and P2.1/P2.2/P2.4
are done as far as a script can verify them. Sensible entry points:

- **Without the Deck — this is where the remaining bulk is.** **P2.5/P2.6**
  (T4's installer screens; text entry is the real gap) or **P2.7/P2.8** (T5's
  `omarchy-iso` fork, which now carries six recorded constraints — see above).
  Either is days of work and needs no hardware.
- **With the Deck, needing a HUMAN present:** everything left on P2.1/P2.2/P2.4
  is a thing a script cannot check — does the OSK appear on text focus, are the
  buttons mapped correctly, does sound actually come out, do haptics and gyro
  respond, and every rotation surface. Batch these into one hands-on pass.
- **A decision, not a task: §5.17.** It is *answered* — a narrower sudo grant is
  impossible, because the install stages write to `/etc/sudoers.d/` itself.
  What remains is choosing whether to drop `99-deck-testing` (and lose the
  unattended SSH loop) or keep it and rely on T5 excluding it from the image.
  `./src/deck-session.sh stage-audit-privileges` is the gate either way.
- **Held for operator approval, both boot-chain:** Limine's
  `interface_rotation: 270` and the TTY's `fbcon=rotate:1`.

⚠️ **P2.3 (TDP, fan curves, battery) still requires per-item operator approval
every single time.** That rule has not moved.

---

## 5. How to work a block

Each task file has the same shape: **Objective → Why → Prerequisites →
Steps → Done when → Failure modes → Escalate if**.

1. `/usage` — confirm you have headroom for this block.
2. Read `docs/PROGRESS.md`, then this block's task file.
3. `/model` to the block's recommended model.
4. Verify prerequisites are actually satisfied — don't trust `docs/PROGRESS.md`
   blindly where a cheap check exists.
5. Work the steps. Commit in logical chunks.
6. Verify every "Done when" item **by running something**, not by reading
   your own code and concluding it looks right.
7. Update `docs/PROGRESS.md`, commit, `/clear`.

If a block turns out much larger than its file suggests: split it, write
the new task file, note it in `docs/PROGRESS.md`, continue. The decomposition is
a starting point, not gospel.

---

## 6. Token discipline (matters — read `docs/SESSIONS.md`)

The operator's 5-hour window is shared across Claude Code and claude.ai,
and there's a separate weekly cap that a 5-hour reset does not restore.
Four habits carry most of the benefit:

- **One task per block, then `/clear`.** Don't carry finished context
  forward.
- **Default Sonnet**; escalate to Opus only where the table above says.
- **Never read `docs/PLAN.md` whole.** It is frozen and partly wrong; read the
  banner and the specific sections a task cites.
- **Use subagents for repo exploration** — they return a summary instead of
  filling your context with source files.

---

## 7. What "done" looks like for the whole project

A single ISO the operator copies onto a Ventoy USB, boots on their OLED
Deck, clicks through using only the Deck's buttons — including joining
Wi-Fi — and lands at a Gaming Mode home screen where controller, Bluetooth,
audio, and haptics all work, with a Desktop Mode button that opens Omarchy
4.0 and a way back.

Everything here exists to get there without reflashing a USB forty times.
