# START HERE — Omarchy Deck build session

**You are Claude Code. This is your entry point. Read it fully, then begin
work without waiting for further instruction.**

> ## Where things stand (updated 2026-08-10, end of session 15)
>
> ### ✅ PHASE 1 COMPLETE. Phase 2 is underway — the core promise now works.
>
> **T0, R1, T1, T2 done. T3 is close.** P1.5 rebuilt the Deck; **session 15
> closed the phase-2 opener**: Steam's own **Power → Switch to Desktop** works
> end to end, on hardware, through the affordance a user actually touches.
>
> **The Deck:** package-based **Omarchy 4.0 + Neptune 6.11.11-valve29**,
> unencrypted, booting unattended, **Steam signed in**, greeter and desktop
> rotated correctly, zero DeckShift. Reach it with **`ssh steamdeck`**
> (key-based, passwordless sudo). Snapshots #1–#3 from P1.5, **#4** before
> session 15's writes.
>
> Before doing anything else, read in this order:
> 1. `docs/PROGRESS.md` §1 (state) and §2 (the five scope decisions) — these
>    reversed several earlier ones, and a session that misses them will build
>    the wrong thing
> 2. `docs/PROGRESS.md` **§5.9–§5.16** — the open issues. §5.10/§5.14 are now
>    closed; **§5.15 and §5.16 are new and both matter**
> 3. `docs/ROADMAP.md` phase 2 — the work queue from here
> 4. `docs/PROGRESS.md` §7 — ~40 facts that each cost real time; do not
>    re-derive them
>
> Hardware evidence: `docs/findings/P15-live-iso-recon.md` (R-0…R-19, raw logs
> in `P15-recon-raw/`) and
> `docs/findings/P2-steam-integration-and-rotation.md` (R-20…R-26).
>
> ### ⚠️ Session 15 corrected four recorded "facts". Trust the findings, not memory.
>
> Each of these was written down confidently and was wrong:
> `transform,1` (it is **3**; 1 is upside down) · the rotation syntax (4.0 uses
> **Lua**, not `.conf`) · "Steam finds `steamos-update` via PATH" (**absolute
> path**) · "`steamos-customizations-jupiter` would supply it" (**ships zero
> polkit helpers**). Verify against hardware before building on a recorded value.
>
> ### The most important open item
>
> **§5.15 — Steam's entire privileged-helper surface is missing.**
> `/usr/bin/steamos-polkit-helpers/` does not exist, and Steam calls 14 helpers
> there by absolute path. **This owns Gaming Mode's brightness slider**
> (`steamos-priv-write`) and OOBE's timezone. `jupiter-hw-support` supplies six
> of them but costs 94 MiB and a plymouth dependency; the `steamos-*` ones are in
> no repo. **Scope decision needed before coding.**
>
> Also open: **§5.16** — a session switch latched sddm into permanent failure,
> leaving no graphical session and needing SSH to recover. Mitigated; the root
> cause (restart issued from inside the dying session) is not fixed, and the race
> is intermittent, so "it worked once" proves little.
>
> ### Two defects still deliberately unfixed — decide before coding
>
> - **§5.13 `stage-repos` lets Arch shadow Valve's packages.** `pacman -S
>   gamescope` installs the bare compositor, not the SteamOS session. The naive
>   fix (Valve's repos first) risks wide downgrades — **audit the overlap
>   first** (`mesa`, `vulkan-radeon`, `lib32-vulkan-radeon`).
> - **§5.12 the 4.0 installer defaults to full-disk encryption.** Inherit it and
>   the ISO produces a device its owner cannot boot without a keyboard.
>
> ### Good work available *without* the Deck
>
> §5.13's overlap audit · T4's installer screens and OSK (re-scoped by §5.9 —
> lizard mode already makes the installer navigable, so the real gap is **text
> entry**) · T5's ISO fork (`docs/tasks/T5-iso-and-payload.md`), which now has
> four constraints: offline-only pacman, the encryption default, repo precedence,
> and **baking in the desktop rotation** — it currently lives in one user's
> `~/.config/hypr/monitors.lua`, so a fresh install still comes up sideways.

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
| `docs/PROGRESS.md` | **Every session start. This is the authoritative state.** Scope, findings, open issues, and ~20 facts not to re-derive. |
| `docs/SESSIONS.md` | Usage-limit budgeting and the block schedule. |
| `docs/PLAN.md` | **Frozen and partly superseded.** Read the banner at the top first. Good for §6.1a (installer screens), §8 (bug hypotheses), §9 (test tiers), §11 (maintenance risks). |
| `docs/tasks/` | One file per work block. |
| `docs/findings/` | Research outputs. Evidence behind the decisions in `docs/PROGRESS.md`. |
| `docs/drafts/` | Staged upstream report. **Nothing sent. Do not send.** |
| `src/omarchy-deck-kernel.sh` | T1's deliverable. Ten idempotent stages, VM-tested and hardware-validated. |
| `src/deck-session.sh` | T3's session-switch layer. |
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

**The ordering lives in `docs/ROADMAP.md` — three phases.** Task-to-phase mapping:

| Task | File | Model | State |
|---|---|---|---|
| T0 | `docs/tasks/T0-test-infrastructure.md` | Sonnet | ✅ done — **both gaps closed by P1.5** |
| R1 | `docs/tasks/R1-research-questions.md` | Opus/Sonnet | ✅ done |
| T1 | `docs/tasks/T1-kernel-and-boot.md` | **Opus** | ✅ done — **hardware-validated 2026-08-10** |
| T2 | `docs/tasks/T2-gamepad-input-spike.md` | **Opus** | ✅ done |
| T3 | `docs/tasks/T3-gaming-mode.md` | Sonnet/Opus | 🟡 **the core promise works through Steam's own UI** (§5.10 ✅, §5.14 ✅, §5.11 greeter+desktop ✅). Left: §5.15, §5.16, P2.1–P2.4 |
| T4 | `docs/tasks/T4-installer-ui.md` | Sonnet | ⬜ **unblocked, re-scoped by §5.9** → P2.5–P2.6 |
| T5 | `docs/tasks/T5-iso-and-payload.md` | Sonnet/Opus | ⬜ P2.7–P2.8, now with §5.12/§5.13 constraints |
| T6 | `docs/tasks/T6-integration-release.md` | **Opus** | ⬜ phase 3 |

**Phase 1 is closed and P2.0 is done.** Sensible entry points:

- **With the Deck** (operator present): **P2.0b** — §5.15's polkit-helper scope
  decision, which is what stands between Gaming Mode and a working brightness
  slider. Then **P2.0c** (§5.16's root cause) and **P2.1/P2.2**.
- **Without the Deck:** **§5.13**'s repo-overlap audit, **P2.5** (T4's installer
  screens — text entry is the real gap) or **P2.7** (T5's `omarchy-iso` fork).

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
