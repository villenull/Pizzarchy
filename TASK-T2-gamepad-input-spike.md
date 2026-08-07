# T2 — Gamepad → input event spike

**Model: Opus, plan mode.** This is a design spike, not implementation.
Can run in parallel with T0/T1.

## Objective

Answer one question definitively: **can the entire installer flow be driven
by mapping Deck buttons/trackpads to keyboard and mouse events at the kernel
input layer, without writing any bespoke controller-native UI?**

## Why this is a spike, and why Opus

The answer determines T4's scope, and the two outcomes differ by weeks:

- **Yes** → T4 becomes mostly configuration: reduce the prompt count, set
  good defaults, map buttons, add on-screen glyphs. Days of work.
- **No** → T4 requires building custom gamescope-hosted UI screens
  (Quickshell/QML) for the guided flow. Weeks of work.

Deciding this wrong early means either building UI you didn't need, or
discovering late that the cheap path doesn't work. Genuine ambiguity plus
large downstream consequences is exactly the Opus case.

## Prerequisites

None, though T0's QEMU harness helps test without hardware.

## Steps

### 1. Establish what actually needs driving

The install flow touches at least three UI layers:
- `archinstall`'s TUI (prompt_toolkit / curses)
- Omarchy's installer prompts (`gum`-based — the retro pixel screens)
- Any custom screens this project adds (`PLAN.md` §6.1a)

A single input-mapping layer that works for all three is the win condition.

### 2. Build the mapping prototype

- Use `uinput` to create a virtual keyboard/mouse device.
- Read Deck controller events via `evdev` (`python-evdev` is already a
  dependency of the Gaming Mode work, so it's not new surface).
- Map: D-pad/stick → arrows, A → Enter, B → Esc, trackpad → mouse,
  triggers → click, plus something for text entry (see step 4).
- Ship it as a small standalone daemon that can be started before the
  installer and killed after.

### 3. Test against each UI layer

- Boot the stock Omarchy ISO in QEMU with a gamepad passed through (QEMU
  supports evdev passthrough; if the operator has a spare controller this
  works without the Deck itself).
- Drive `archinstall` end to end with only the virtual device. Note anything
  that can't be reached.
- Same for a `gum` prompt.
- **Record specifically what fails**, not just whether it works overall — a
  90% answer with one unreachable screen is still actionable.

### 4. Text entry

Username and password (`PLAN.md` §6.1a item 5) need real text input. Options:
- An on-screen keyboard driven by the mapper
- Reuse an existing OSK (`wvkbd`, `squeekboard`) if one runs this early
- A PIN-pad-only path for the low-friction case

Prototype one; note the others.

### 5. Write the recommendation

`FINDING-T2-gamepad-spike.md`:
- Does the mapping approach work? Fully, partially, or not?
- If partially: which specific screens need custom UI, and how many?
- Estimated T4 scope under each outcome
- Recommendation with reasoning

Also feed into `PLAN.md` §10.3 (should this layer ship permanently for
Desktop Mode, or is it installer-only?) — the two questions share an answer.

## Done when

- [ ] Prototype daemon exists and creates a working virtual input device
- [ ] Driven `archinstall` in a VM with only virtual input — result recorded
- [ ] Driven a `gum` prompt — result recorded
- [ ] Text entry path prototyped
- [ ] `FINDING-T2-gamepad-spike.md` written with a clear recommendation
- [ ] T4's task file updated to reflect the actual scope

## Failure modes to watch for

- **Declaring success from a partial test.** "The arrow keys worked" is not
  "the installer is navigable." Drive a complete install.
- **Scope creep into building the installer.** This is a spike. Answer the
  question, write it down, stop.

## Escalate if

- The approach works but needs elevated privileges in a way that's awkward
  inside the live ISO environment — that's a design constraint worth
  discussing before committing.
