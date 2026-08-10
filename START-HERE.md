# START HERE — Omarchy Deck build session

**You are Claude Code. This is your entry point. Read it fully, then begin
work without waiting for further instruction.**

All project files are in this one directory. There are no subfolders.

---

## 1. What you are building

A **single bootable ISO** that installs Arch + **Omarchy 4.0 (Quattro)** on a
Steam Deck, navigable start to finish with only the Deck's buttons and
trackpads — no keyboard, no terminal. After install the device behaves like
stock SteamOS: boots to Gaming Mode, all hardware works, and a **Desktop Mode**
button drops into a full Omarchy desktop with a way back.

The install **may use Wi-Fi** — see `PROGRESS.md` §2.2. That is a deliberate
reversal of an earlier "fully offline" constraint, not an oversight.

The operator owns one **OLED Steam Deck** and is on **Claude Max 5x**. They
already did a full manual Omarchy install on that Deck by hand, hit roughly a
dozen distinct bugs doing it, and wrote the findings into `PLAN.md`. **Your job
is to turn that validated manual process into automation** — not to rediscover
it.

---

## 2. Files in this directory

| File | Read it when |
|---|---|
| `CLAUDE.md` | Auto-loaded every session. Hard constraints. |
| `PROGRESS.md` | **Every session start. This is the authoritative state.** Scope, findings, open issues, and ~20 facts not to re-derive. |
| `SESSIONS.md` | Usage-limit budgeting and the block schedule. |
| `PLAN.md` | **Frozen and partly superseded.** Read the banner at the top first. Good for §6.1a (installer screens), §8 (bug hypotheses), §9 (test tiers), §11 (maintenance risks). |
| `TASK-*.md` | One per work block. |
| `FINDING-*.md` | Research outputs. Evidence behind the decisions in `PROGRESS.md`. |
| `DRAFT-*.md` | Staged upstream reports/outreach. **Nothing sent. Do not send.** |
| `omarchy-deck-kernel.sh` | T1's deliverable. Nine idempotent stages, VM-tested and hardware-validated. |
| `deck-session.sh` | T3's session-switch layer. |

New files follow the same flat pattern. **Keep everything flat — no
subdirectories.**

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
- Discovering a foundational assumption is wrong. Surface it; don't quietly
  work around it. This has already happened four times and each time it
  changed the plan for the better.

### Never

- Never report a task complete when its done-criteria aren't met. This
  project exists partly because upstream tooling printed "success" while
  doing nothing (`PLAN.md` §8.1). Do not become that.
- Never propose "reinstall on the Deck to test this" for anything not on
  the physical-hardware-only list (`PLAN.md` §9.5). There is almost always
  a faster tier.
- Never depend on something unlicensed or AUR-only. The ISO redistributes
  what it carries.

---

## 4. The work queue

| Task | File | Model | State |
|---|---|---|---|
| T0 | `TASK-T0-test-infrastructure.md` | Sonnet | ✅ done |
| R1 | `TASK-R1-research-questions.md` | Opus/Sonnet | ✅ done |
| T1 | `TASK-T1-kernel-and-boot.md` | **Opus** | ✅ done, one gap open |
| T2 | `TASK-T2-gamepad-input-spike.md` | **Opus** | ⬜ **next** — sizes T4 |
| T3 | `TASK-T3-gaming-mode.md` | Sonnet/Opus | 🟡 in progress |
| T4 | `TASK-T4-installer-ui.md` | Sonnet | ⬜ blocked on T2 |
| T5 | `TASK-T5-iso-and-payload.md` | Sonnet/Opus | ⬜ not started |
| T6 | `TASK-T6-integration-release.md` | **Opus** | ⬜ gated on Omarchy 4.0 stable |

**Start with T2.** It is the only thing standing between here and knowing
whether T4 is days or weeks of work, and T4 is on the critical path to the
ISO. Its scope grew slightly: the mapper and on-screen keyboard now have to
work **in the live ISO**, because the user types a Wi-Fi password before
anything is installed (`PROGRESS.md` §2.2).

⚠️ **`PROGRESS.md` §5.1 is cheaper than T2 and ranks above it** if the
operator is willing to boot the stock ISO on the Deck: does Wi-Fi work at all
from the live environment? A no there reshapes T5.

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
- **Never read `PLAN.md` whole.** It is frozen and partly wrong; read the
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
