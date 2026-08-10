# T2 — Gamepad → input event spike

**Model: Opus, plan mode.** This is a design spike, not implementation.

> **✅ RESOLVED 2026-08-10 — see `docs/findings/T2-gamepad-spike.md`.**
> Navigation works: a `uinput`/`evdev` mapper drives `gum` and `archinstall`
> with no UI-side cooperation, proven in QEMU through the real kernel-VT
> delivery path. **T4 is the days-shaped task, not the weeks-shaped one.**
>
> One gap remains and it is narrow: **text entry** (Wi-Fi password, account
> credentials). Options and a recommendation are in the finding §4; settle it
> against the real 4.0 ISO before writing any OSK code.
>
> Artifacts: `src/deck-input-mapper.py`, `test/unit/test-deck-input-mapper.py` (26
> assertions, in CI), `test/vm/vm-gamepad-spike-test.sh` (QEMU).
>
> **Scope grew:** the install may now use Wi-Fi (`docs/PROGRESS.md` §2.2), so the
> user must **type a Wi-Fi password with a controller, in the live ISO,
> before anything is installed.** The mapper and an on-screen keyboard
> therefore have to work in the live environment — not just in the installed
> desktop. Treat that as a first-class requirement of this spike, not a
> footnote: it is a harsher environment than a running Omarchy session
> (no user session, no `uwsm`, possibly no seat ACLs yet).
>
> **Head start from R1 §10.3, all hardware-verified** (`docs/findings/R1-10.3.md`) —
> do not re-derive:
> - unprivileged `/dev/uinput` works with a udev rule; **no privileged helper
>   needed**. The rule needs `GROUP="input"`, because `uaccess` does *not*
>   cover `/dev/uinput` (virtual device, no seat tag).
> - the module is not autoloaded — needs `/etc/modules-load.d/`
> - controller evdev **read** access already works via seat ACLs
> - use **`squeekboard`** (Arch `extra`). `wvkbd` is AUR-only.
> - in a user session the systemd target is
>   `wayland-session@hyprland.desktop.target`; `hyprland-session.target` does
>   not exist and a unit wanting it enables without error and never starts.

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
- Any custom screens this project adds (`docs/PLAN.md` §6.1a)

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

### 4. Text entry ⚠️ now load-bearing, not a nice-to-have

Two screens need real text input, and one of them gates the install:

- **Wi-Fi password** (`docs/PLAN.md` §6.1a item 7). Under `docs/PROGRESS.md` §2.2 the
  install uses the network, so this is on the critical path.
- **Username and password** (`docs/PLAN.md` §6.1a item 5).

Use `squeekboard` — already chosen, and the AUR rules out `wvkbd`. The open
question is not *which* OSK but **whether it runs in the live ISO at all**:
focus-triggered popup was confirmed at the *protocol* level on an installed
Hyprland session, never demonstrated, and never in a live environment.

A PIN-pad-only path is still worth noting as a fallback for the account
screen — but it cannot serve a Wi-Fi password.

### 5. Write the recommendation

`docs/findings/T2-gamepad-spike.md`:
- Does the mapping approach work? Fully, partially, or not?
- If partially: which specific screens need custom UI, and how many?
- Estimated T4 scope under each outcome
- Recommendation with reasoning

Also feed into `docs/PLAN.md` §10.3 (should this layer ship permanently for
Desktop Mode, or is it installer-only?) — the two questions share an answer.

## Done when

- [ ] Prototype daemon exists and creates a working virtual input device
- [ ] Driven `archinstall` in a VM with only virtual input — result recorded
- [ ] Driven a `gum` prompt — result recorded
- [ ] Text entry path prototyped
- [ ] `docs/findings/T2-gamepad-spike.md` written with a clear recommendation
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
