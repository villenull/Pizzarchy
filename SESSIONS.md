# Session plan — working within 5-hour usage windows

Operator is on **Claude Max 5x**. This file exists so usage limits are a
scheduling constraint, not a mid-task ambush.

## How the limits actually work

- A **5-hour rolling session window** opens with your first prompt and
  covers everything for the next five hours. It is **shared across
  claude.ai, Claude Desktop, and Claude Code** — chatting in the browser
  eats the same pool as the coding session.
- A **separate weekly cap** resets on a fixed day/time assigned to the
  account. **Waiting for a 5-hour reset does not restore weekly
  allowance.** For a multi-week project run at pace, the weekly cap is the
  real constraint, not the 5-hour one.
- Max 5x is defined as 5× Pro's per-session usage. Anthropic no longer
  publishes fixed token/message counts — treat any specific number you read
  online as unreliable and check the live figure instead.
- **Check actual usage with `/usage` inside Claude Code**, or Settings →
  Usage on the web. Both show current window consumption, time remaining,
  weekly usage, and the next weekly reset. Trust these over any estimate,
  including the block sizing below.

## What actually burns the budget

In rough order of impact for a project like this:

1. **Model choice.** Opus consumes the allowance far faster than Sonnet for
   the same work. This is the single biggest lever.
2. **Context size per request.** Every message re-sends the accumulated
   context. A session that has read `PLAN.md` (~13k tokens) plus a dozen
   files plus tool output is paying for all of it on *every* subsequent
   turn. This is why `/clear` between tasks matters more than it looks.
3. **Tool output volume.** Long build logs, `pacman` output, full-file
   reads. Prefer `grep`/targeted reads over `cat` on large files.
4. **`CLAUDE.md` size.** It loads into every session — fixed overhead on
   everything. Keep it tight; it's currently ~4.5KB, which is fine. Don't
   let it grow into a second plan document.
5. **Re-deriving things.** Every time a session re-discovers a finding
   because it wasn't written to `PROGRESS.md`, that's pure waste.

## The rules that matter most

1. **One task per block, then `/clear`.** Don't carry a finished task's
   context into the next one. This is the highest-leverage habit.
2. **Default Sonnet. Escalate deliberately.** Opus for: T1 (boot chain),
   T2 (spike), R1 (research), T3's hardware-control logic, T6 (release).
   Everything else Sonnet. Don't leave a long agentic loop on Opus.
3. **Never read `PLAN.md` whole after session 1.** It's the largest file
   here. Task files are written to be self-contained; when one cites a
   `PLAN.md` section, read *that section*, not the file.
4. **Use subagents for exploration.** A subagent has its own context window
   and returns only a summary — reading a large upstream repo via subagent
   costs the main session a paragraph instead of thousands of tokens. Ideal
   for T5's `omarchy-iso` investigation and R1's repo reading.
5. **Write findings down immediately.** `PROGRESS.md` is the only thing
   that survives `/clear`. A finding not written there will be re-derived
   at full cost.
6. **Front-load heavy work in the window.** If you open a window and the
   first thing is a big Opus planning pass, do it first — don't burn the
   window's headroom on setup and then hit the wall mid-plan.
7. **Do chat-based thinking in the same window deliberately.** Since
   claude.ai draws from the same pool, an unrelated long browser
   conversation mid-block costs you coding capacity.

## Block plan

Each block is scoped to comfortably fit one 5-hour window with headroom — if
a block finishes early, **stop and `/clear` rather than starting the next
one**, unless the window has real room left. Running two blocks in one window
is fine when they're both Sonnet; avoid it when either is Opus.

**Blocks 1–9 are done.** Nine sessions consumed; see `PROGRESS.md` §8.

| # | Block | Task | Model | Notes |
|---|---|---|---|---|
| 1–2 | ✅ Test infrastructure | T0 | Sonnet | QEMU harness, `deck-sync.sh`, CI, shellcheck |
| 3–4 | ✅ Research | R1 | Opus/Sonnet | All six questions resolved |
| 5–7 | ✅ Kernel + boot chain | T1 | **Opus** | Nine stages, VM + hardware validated |
| 8 | ✅ First hardware run | T1 | **Opus** | Two real bugs; R1 §10.3 decided |
| 9 | ✅ Scope reset + doc consolidation | — | **Opus** | ISO target, Omarchy 4.0, DeckShift dropped |

### Remaining

| # | Block | Task | Model | Notes |
|---|---|---|---|---|
| 10 | **Wi-Fi in the live ISO** | `PROGRESS.md` §5.1 | Sonnet | ⚠️ **Do first.** Cheap, and a "no" reshapes T5. **Hardware.** |
| 11 | Gamepad mapper + OSK spike | T2 §1–4 | **Opus** | Design-heavy. Must work in the *live ISO* |
| 12 | Write the T2 finding | T2 §5 | Sonnet | Decides T4's scope |
| 13 | Close the VM substrate gap + `stage-default-entry` | T1 §7–8 | **Opus** | Boot-critical. Both are QEMU-only |
| 14 | Remove DeckShift, prove both switch directions | T3 §2–3 | Sonnet | **Hardware. Ask first.** |
| 15 | Input mapper in the desktop session | T3 §4 | Sonnet | Shares T2's implementation |
| 16 | Hardware parity batch 1 | T3 §5 | Sonnet | Wi-Fi, BT, audio, input. **Hardware.** |
| 17 | Hardware parity batch 2 | T3 §5 | **Opus** | TDP/fan/thermal. **Hardware. Ask first.** |
| 18–19 | Installer screens | T4 | Sonnet | 8 screens; screen 7 needs controller text entry |
| 20 | Full flow in QEMU | T4 | Sonnet | No keyboard attached |
| 21–22 | Fork ISO builder + payload | T5 | Opus (repo plumbing), Sonnet (rest) | |
| 23 | Rebase onto Omarchy 4.0 stable | T6 §1 | **Opus** | T3's shell hooks most at risk |
| 24 | Hardware matrix + release | T6 §2–7 | **Opus** | **Hardware.** All nine steps in one run. |

Blocks 10–22 are 4.0-stable-independent — run them before stable lands.
Block 23 onward requires Omarchy 4.0 stable.

⚠️ **Two of these are ordering traps.** Block 10 is tiny and ranks first
because a bad answer changes T5's design. Block 13 is listed after T2 only
because T2 is on the critical path to the ISO — if a window is short, block
13 is the better fit, since both halves are QEMU-only and need no hardware.

## Session open / close ritual

**Open (2 minutes, saves far more):**
1. `/usage` — know your headroom before committing to a block
2. Read `PROGRESS.md`
3. Read the one task file for this block
4. `/model` to the block's recommended model
5. State the block goal in one line, then work

**Close (do this *before* you run low, not after):**
1. Update `PROGRESS.md`: status, findings, blocked-on-human, next step
2. Commit
3. `/clear`

If `/usage` shows you're near the window limit mid-block: **stop at the
next clean boundary, write `PROGRESS.md`, commit.** A half-finished block
with good notes resumes cheaply. A block that dies mid-edit with nothing
written costs the whole block again.

## If the weekly cap hits

Waiting for a 5-hour reset won't help. Options:
- Switch to the non-Claude parts: Ventoy setup, hardware testing on the
  Deck, reading upstream source, decisions the operator owes (trademark
  question, LCD tester recruitment).
- Move to API billing for overflow if the work is urgent.
- Otherwise: this is a multi-week project by design. The block plan above
  assumes pacing, not sprinting.
