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

~20 blocks. Each is scoped to comfortably fit one 5-hour window with
headroom — if a block finishes early, **stop and `/clear` rather than
starting the next one**, unless the window has real room left. Running two
blocks in one window is fine when they're both Sonnet; avoid it when either
is Opus.

| # | Block | Task | Model | Notes |
|---|---|---|---|---|
| 1 | QEMU install harness | T0 §1 | Sonnet | Artifact assertions, not log scraping |
| 2 | Iteration tooling + CI | T0 §2–6 | Sonnet | `deck-sync.sh`, override loader, shellcheck |
| 3 | **Steam-offline + mirror signing** | R1 10.4, 10.1 | Sonnet (10.4), Opus (10.1) | Highest-stakes findings. Do early. |
| 4 | Remaining research | R1 10.2, 10.3, 10.5, 10.6 | Sonnet | Use subagents for repo reading |
| 5 | Harden + generalize kernel script | T1 §1–2 | **Opus** | Version constant, ESP logic |
| 6 | Pacman hook + stage split | T1 §3, §6 | **Opus** | Boot-critical |
| 7 | VM validation | T1 §4–5 | Sonnet | Idempotency proof, failure test |
| 8 | Build input mapper | T2 §2 | **Opus** | Design-heavy |
| 9 | Test mapper + write finding | T2 §3–5 | Sonnet | Decides T4's scope |
| 10 | Fork + strip + flip default | T3 §1–2 | Sonnet | |
| 11 | Session switching, both ways | T3 §3–4 | Sonnet | Verify against Quattro |
| 12 | Hardware parity batch 1 | T3 §5 | Sonnet | Wi-Fi, BT, audio, input. **Hardware.** |
| 13 | Hardware parity batch 2 | T3 §5–6 | **Opus** | TDP/fan/thermal. **Hardware. Ask first.** |
| 14 | Installer screens 1–4 | T4 | Sonnet | |
| 15 | Installer screens 5–8 | T4 | Sonnet | |
| 16 | Full offline flow in QEMU | T4 | Sonnet | No keyboard, no network |
| 17 | Fork ISO builder + mirror | T5 §1–2 | Opus (signing), Sonnet (rest) | |
| 18 | Offline verify + size check | T5 §3–5 | Sonnet | Hypervisor-level network off |
| 19 | Rebase onto Quattro stable | T6 §1 | **Opus** | T3's UI hooks most at risk |
| 20 | Hardware matrix + release | T6 §2–7 | **Opus** | **Hardware.** All nine steps in one run. |

Blocks 1–9 are Quattro-independent — run them before stable lands.
Block 19 onward requires Quattro stable.

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
