# START HERE — Omarchy Deck build session

**You are Claude Code. This is your entry point. Read it fully, then begin
work without waiting for further instruction.**

All project files are in this one directory. There are no subfolders.

---

## 1. What you are building

A Steam Deck–native installer for Omarchy Quattro. One bootable USB, fully
offline install, navigable with only the Deck's physical buttons and
trackpads. After install the device behaves like stock SteamOS — boots to
Gaming Mode, all hardware works — except "Desktop Mode" drops into a full
Omarchy desktop, with a button/icon to return to Gaming Mode.

The operator owns one **OLED Steam Deck** and is on **Claude Max 5x**. They
have already done a full manual Omarchy install on that Deck by hand, hit
roughly a dozen distinct bugs doing it, and wrote the findings into
`PLAN.md`. **Your job is to turn that validated manual process into
automation** — not to rediscover it.

---

## 2. Files in this directory

| File | Read it when |
|---|---|
| `CLAUDE.md` | Auto-loaded every session. Hard constraints. |
| `SESSIONS.md` | **Before your first block.** Usage-limit budgeting and the 20-block schedule. |
| `PROGRESS.md` | Every session start. Current state. |
| `PLAN.md` | **Once, in session 1.** Large. After that, read only the specific sections task files cite. |
| `TASK-*.md` | One per work block. |
| `omarchy-deck-kernel.sh` | Draft implementation, starting point for T1. Never executed. |

Files you'll create follow the same flat pattern: `FINDING-*.md` for
research outputs, `deck-sync.sh` and similar for scripts. **Keep everything
flat — no subdirectories.**

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
- Update `PROGRESS.md` — continuously, not just at session end.

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
- Discovering a foundational assumption in `PLAN.md` is wrong — especially
  §10.4 (Steam needing network on first launch would undercut the headline
  "fully offline" claim). Surface it; don't quietly work around it.

### Never

- Never report a task complete when its done-criteria aren't met. This
  project exists partly because upstream tooling printed "success" while
  doing nothing (`PLAN.md` §8.1). Do not become that.
- Never propose "reinstall on the Deck to test this" for anything not on
  the physical-hardware-only list (`PLAN.md` §9.5). There is almost always
  a faster tier.

---

## 4. The work queue

Eight tasks, split across ~20 sessions. **`SESSIONS.md` has the block
schedule — follow that, not just the task order.**

| Task | File | Model | Notes |
|---|---|---|---|
| T0 | `TASK-T0-test-infrastructure.md` | Sonnet | **Do first.** Collapses a ~30 min loop to seconds. |
| R1 | `TASK-R1-research-questions.md` | Opus/Sonnet | Parallel-safe. 10.4 is highest stakes. |
| T1 | `TASK-T1-kernel-and-boot.md` | **Opus** | Highest bug density in the project. |
| T2 | `TASK-T2-gamepad-input-spike.md` | **Opus** | Determines T4's entire scope. |
| T3 | `TASK-T3-gaming-mode.md` | Sonnet/Opus | Largest task. Needs `deck-sync.sh` from T0. |
| T4 | `TASK-T4-installer-ui.md` | Sonnet | Blocked on T2's finding. |
| T5 | `TASK-T5-iso-and-payload.md` | Sonnet/Opus | Blocked on R1 10.1 and 10.4. |
| T6 | `TASK-T6-integration-release.md` | **Opus** | Blocked on Quattro stable. |

**Start with T0.** It is small and unglamorous and it collapses the
edit-test loop for everything after it. Skipping it to "get to the real
work faster" is the easiest way to lose a week.

### v0 vs v1 — check with the operator before starting T4

`PLAN.md` §3.1 recommends shipping a **v0** first: T0 + T1 + T3 only, as a
post-install script for Decks that already have Omarchy installed normally.
That delivers the whole "feels like a Steam Deck, Desktop Mode is Omarchy"
experience without the ISO, the offline mirror, or the controller-navigable
installer — weeks earlier, and without depending on findings that aren't in
yet.

If the operator hasn't explicitly chosen v1-first, **ask before starting
T4**. It's a scope decision, not an implementation detail.

---

## 5. How to work a block

Each task file has the same shape: **Objective → Why → Prerequisites →
Steps → Done when → Failure modes → Escalate if**.

1. `/usage` — confirm you have headroom for this block.
2. Read `PROGRESS.md`, then this block's task file.
3. `/model` to the block's recommended model.
4. Verify prerequisites are actually satisfied — don't trust `PROGRESS.md`
   blindly where a cheap check exists.
5. Work the steps. Commit in logical chunks.
6. Verify every "Done when" item **by running something**, not by reading
   your own code and concluding it looks right.
7. Update `PROGRESS.md`, commit, `/clear`.

If a block turns out much larger than its file suggests: split it, write
the new task file, note it in `PROGRESS.md`, continue. The decomposition is
a starting point, not gospel.

---

## 6. Token discipline (matters — read `SESSIONS.md`)

The operator's 5-hour window is shared across Claude Code and claude.ai,
and there's a separate weekly cap that a 5-hour reset does not restore.
Four habits carry most of the benefit:

- **One task per block, then `/clear`.** Don't carry finished context
  forward.
- **Default Sonnet**; escalate to Opus only where the table above says.
- **Never re-read `PLAN.md` whole** after session 1 — read cited sections.
- **Use subagents for repo exploration** — they return a summary instead of
  filling your context with source files.

---

## 7. First session: bootstrap

If `PROGRESS.md` still says "not yet started":

1. Read `PLAN.md` in full — this is the one time you should.
2. Read `SESSIONS.md`.
3. `git init` here if needed; commit the planning docs as a baseline.
4. **Do not create the multi-repo layout in `PLAN.md` §5 yet.** Start as one
   flat working directory. Splitting later is cheap; coordinating four empty
   repos is overhead.
5. Verify local toolchain: `qemu`, `archiso` deps, `shellcheck`, `git`.
   Note anything missing under "Blocked on human" in `PROGRESS.md` rather
   than installing system packages on the operator's machine unprompted.
6. Begin block 1 (T0 §1).

---

## 8. What "done" looks like for the whole project

A single ISO the operator copies onto a Ventoy USB, boots on their OLED
Deck with no network connected, clicks through using only the Deck's
buttons, and lands at a Gaming Mode home screen where controller, Wi-Fi,
Bluetooth, audio, and haptics all work — with a Desktop Mode button that
opens Omarchy and a way back.

Everything here exists to get there without reflashing a USB forty times.
