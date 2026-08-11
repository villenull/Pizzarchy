# T8 — the on-screen keyboard we draw ourselves

**Model: Sonnet for the renderers, Opus for the input/layout core.**
**Status: specified session 17. STEPS 1–6 DONE (session 18, 2026-08-10).**

> ## Where this stands
>
> | Step | State |
> |---|---|
> | 1. Layout core + hit-testing + shift layers | ✅ `src/deck_osk_layout.py` |
> | 2. Character emission in the mapper | ✅ keycodes declared, `--type` types |
> | 3. Absolute dual-cursor mapping from both pads | ✅ `Cursors`, same module |
> | 4. TTY renderer (installer) | ✅ `src/deck_osk_tty.py` + `--osk-backend=tty` |
> | 5. Layer-shell renderer (Desktop Mode) | ✅ `src/deck_osk_wayland.py` |
> | 6. Pointer suppression while the OSK is up | ✅ both backends |
> | 7. Retire squeekboard from Desktop Mode | ⬜ **next**, and it needs the Deck |
>
> **`src/deck_osk_layout.py`** — two layers (letters, symbols), split into two
> halves, hit-testing in normalised 0..1 coordinates within a half, three shift
> states, and `strokes_for_text()`. Every printable ASCII character is reachable
> and round-trips, asserted against a US-layout table the test owns rather than
> the module's own. **134 assertions** (with step 3's cursors).
>
> **The mapper** now folds `OSK_KEYCODES` into `EMITTED_KEYS`. That is the
> load-bearing half of step 2: a uinput device emits only the codes it declared
> at creation, so every character key had to be declared before any renderer
> draws it or they would all be silently dead. Its suite is **106 assertions**.
>
> **`deck-input-mapper --type TEXT`** types a string through the layout with no
> pad, no cursor and no renderer. It exists so a human can point the emission
> path at a text field and see whether text appears — steps 4–5 are the only
> way to test it otherwise, and this project has been burned three times by
> paths that were present, enumerated and silent.
>
> **`Cursors`** (step 3) maps both pads to two independent positions in 0..1
> within each half, with the device's own absinfo where available. Two decisions
> worth not re-deriving:
>
> - **Y is inverted.** The pad's Y grows upward, every screen coordinate grows
>   downward. `deck-input-mapper.py` negates the same axis for the same reason —
>   if one is ever wrong, they are wrong together.
> - **A reading of exactly 0 is treated as NO reading, and that axis holds.**
>   The pads report 0 (centre) on lift, which under an absolute mapping would
>   snap the cursor to the middle of its half on every release and put the next
>   trigger click on whatever key sits there. The cost is the pad's dead centre,
>   which is half a key from any hit-test boundary, and one 4 ms sample when a
>   stroke crosses the centre line. **This deliberately does not depend on both
>   zeros arriving in the same report** — whether `hid-steam` sends them together
>   is unmeasured, and a rule needing them together would fail differently
>   depending on the answer.
>
> **`test/unit/test-osk-install-layout.sh`** (16 assertions) pins the thing
> nothing else could see: the install directory is derived **twice**, literally
> in `deck-session.sh` and computed in the mapper, and nothing makes them agree.
>
> **`src/deck_osk_tty.py`** (step 4) draws the keyboard in **text**, not on the
> framebuffer. A framebuffer OSK would be a true overlay and also invisible to
> every tool that can observe a console — `tmux capture-pane`, a serial log,
> `test/vm/vm-gamepad-spike-test.sh`. Text costs polish and buys a keyboard that
> can be **asserted on, in CI, with no screen and no human**. It also removes
> font rendering, and a console font is not guaranteed to carry box-drawing
> glyphs, so everything is ASCII.
>
> Each cursor **highlights the key it is over** rather than floating between
> them — for a keyboard, "which key am I on" is the question, and snapping
> answers it exactly. The highlight is **brackets as well as reverse video**:
> reverse video alone is invisible to `capture-pane` without `-e`, unreadable on
> some console fonts, and gone in a plain log.
>
> ⚠️ **`KEY_CELL` is 7 and a test found out why.** At 5 the two brackets left
> three columns, so `enter` drew as `[ent]` and `right` as `[rig]` — *only while
> the cursor was on them*, which is the one moment the label has to be legible.
> There is now an invariant asserting no label is ever truncated, at any span,
> in any shift state.
>
> **Mapper wiring:** `--osk-backend {dbus,tty,none}`, defaulting to `dbus` so the
> Deck's user service keeps toggling squeekboard exactly as today. With the tty
> backend up: both pads become cursors, each trigger presses the key under its
> **own** cursor, and everything else is swallowed (A must not also send Enter).
> The chord is checked **before** that branch — it is how a user dismisses a
> keyboard opened by accident.
>
> **Step 6 is half-answered.** The right pad is no longer fed to the pointer
> while the keyboard is up, so for the tty backend there is no system pointer to
> suppress — the motion is never generated. The layer-shell renderer will have
> to answer it again, under a compositor that has its own pointer.
>
> **`test/osk-tty-e2e.py`** drives the whole chain — virtual pad → mapper →
> cursors → rendered console → keystrokes — through the real script with nothing
> stubbed. 19 assertions. ⚠️ **Not in CI and not in the `test/unit/` glob, on
> purpose:** it needs a writable `/dev/uinput`, and a test that skips itself
> when a device is missing reports green while asserting nothing.
>
> **`src/deck_osk_wayland.py`** (step 5) is the same core drawn on a
> `zwlr_layer_shell_v1` surface via GTK4 + gtk4-layer-shell — **both already
> installed on the Deck, both in Arch `extra`, neither in the AUR.**
>
> ✅ **T8's "escalate if" is designed away, not solved.** The concern was that
> the overlay could not take input without stealing focus from the field being
> typed into. It never takes input: the pad reaches the *mapper*, over evdev, so
> the surface only ever draws. It asks the compositor for nothing —
> `KeyboardMode.NONE` and an **empty input region**, so it cannot be focused and
> cannot be clicked. **Verified on Hyprland:** with the overlay on screen,
> `hyprctl activewindow` was unchanged. That is the property squeekboard
> structurally cannot have — it *is* a surface being pointed at.
>
> ⚠️ **A separate process, deliberately.** The mapper spawns it and feeds state
> on stdin. With `lizard_mode=N` the mapper is the only input path on the device,
> so a GTK crash or a compositor restart must not be able to take it down.
>
> ⚠️ **THE LINKING TRAP — found by running it, invisible to every test.**
> `gtk4-layer-shell` interposes on `libwayland-client` and must load first. Under
> PyGObject it never does: `import gi.repository.Gtk` pulls libwayland in before
> anything of ours runs, and there is no link order to fix because nothing here
> is linked. The failure is quiet in the way that matters — the process starts,
> GTK warns on stderr, and a **perfectly normal focusable window** appears,
> destroying every property above. `deck_osk_wayland` now re-execs itself once
> with `LD_PRELOAD` set. Confirmed fixed: `hyprctl layers` shows
> `namespace: deck-osk` on the overlay layer, zero warnings.
>
> **Step 6 is closed.** Neither backend fights a system pointer: the right pad
> stops feeding `pointer_delta` while the keyboard is up, so the motion is never
> generated. The layer surface adds nothing to suppress, having no input region.
>
> **Totals: 134 + 106 + 49 + 47 + 16 unit assertions, plus 19 end-to-end.
> 60/60 mutations caught.** ⚠️ One "SURVIVED" was spurious — the mutation's
> anchor did not match, so nothing was mutated. A mutation that reports survival
> without applying is a false negative; check the patch applied before believing
> the result.
>
> ⚠️ **A stale `__pycache__` invalidated one mutation run.** Python validates
> cached bytecode against the source's (mtime, size) at one-second granularity,
> so a same-size edit landing in the same second runs the PREVIOUS version —
> and mutation testing makes same-size edits on purpose. Both Python suites now
> set `sys.dont_write_bytecode = True` before loading anything. If a mutation
> result ever looks impossible, check for a `__pycache__` first.
>
> ⚠️ **NOT YET RUN ON THE DECK.** `stage-input-mapper` now installs **two extra
> modules** and verifies both by running them. That has never executed on
> hardware. Until it does, the claim is "green on a dev machine".

## Objective

A controller-driven on-screen keyboard that **we render**, with a split layout
and **two independent cursors** — left trackpad over the left half, right
trackpad over the right half, each trigger clicking its own side — usable in
**both** the installer (bare TTY, no compositor) and Desktop Mode (Hyprland).

## Why this exists, and why squeekboard cannot be it

Two independent reasons, arrived at from opposite directions:

1. **The installer has no compositor at all.** `docs/findings/T2-gamepad-spike.md`
   §4 measured the live ISO: no Wayland, no `squeekboard`, no `wvkbd` — a pure
   console environment with `archinstall`, `gum`, `python3`, `iwctl`. Putting
   squeekboard there means adding an entire compositor stack to the ISO. That
   finding already chose **a mapper-drawn OSK** as the answer.
2. **squeekboard cannot do dual-cursor selection, in any configuration.** Valve's
   keyboard runs *two* cursors. A Wayland compositor gives one pointer per seat,
   and squeekboard is an ordinary surface being pointed at — there is nowhere to
   put a second cursor. Session 17 confirmed on hardware that STEAM+X *shows*
   squeekboard but it neither looks nor behaves like the Deck's keyboard.

So the installer needed this anyway; session 17 only extended it to Desktop
Mode. **squeekboard stays** as the working fallback until T8 replaces it — it
auto-shows on focus today (`docs/PROGRESS.md` §5.20) and is installed by
`stage-desktop-settings`.

## What already exists, and must be reused rather than rebuilt

`src/deck-input-mapper.py` is already the whole input half:

| Piece | State |
|---|---|
| Reads the pad, selects by capability, refuses Steam's virtual pad | ✅ done |
| Owns a `uinput` virtual keyboard **and pointer** | ✅ done |
| Buttons → keys, d-pad/stick → arrows with auto-repeat | ✅ done |
| Right trackpad → pointer, triggers → mouse buttons | ✅ done |
| STEAM+X chord, queued as an action | ✅ done — currently toggles squeekboard |
| **Character keys** (letters, digits, symbols, shift) | ✅ done — session 18, `src/deck_osk_layout.py` |
| **A renderer** | ❌ missing — steps 4 and 5, the remaining bulk |

**The chord already lands.** T8 changes what it opens, not how it is detected.

## Hardware facts this task depends on — all measured, do not re-derive

From `docs/findings/P17-input-and-osk.md` (R-29…R-42):

| Fact | Value |
|---|---|
| Left trackpad | `ABS_HAT0X/Y`, ±32767 — **not a d-pad**, despite the name |
| Right trackpad | `ABS_HAT1X/Y`, ±32767 |
| Triggers | `ABS_HAT2X` = **R2**, `ABS_HAT2Y` = **L2**, 0..32767; also `BTN_TR2`/`BTN_TL2` |
| STEAM button | `BTN_MODE` — **only visible with `lizard_mode=N`** |
| Rear paddles | `BTN_TRIGGER_HAPPY1..4` (R4 measured as `HAPPY2`) — unused, available |
| Pad sample rate | **250 Hz**, steady (p50 4.0 ms, p90 4.3 ms) |
| Typical per-sample movement | ~150 units (p90 547) |
| Lift behaviour | reports **0 (centre)** on release — looks like a huge swipe |

⚠️ **Both trackpads are already available as absolute-position axes**, which is
exactly what two cursors need: absolute pads map to absolute cursor positions
within each half, with no delta accumulation at all. That is *simpler* than the
relative-pointer code the mapper has today, not harder.

## Design

### The layout core (shared, pure, unit-testable)

A grid: rows of keys, each with a label, an emitted keycode, and a
half-assignment (left/right). No rendering, no device access — the same
discipline as `Mapper.translate()`, so it is testable without a screen.

- `key_at(half, x, y) -> Key | None` — hit-testing in normalised 0..1 coords
- Shift/symbol layers, since a Wi-Fi passphrase needs both
- The emission path the nav profile lacks: **character keycodes plus the
  modifier state**, which is where `KEY_LEFTSHIFT` handling belongs

### Two cursors

Each trackpad's absolute position maps to a normalised position **within its own
half**. No pointer, no compositor cursor — we draw both. This is why the design
works in a TTY as well: nothing outside the process needs to know.

⚠️ **The system pointer must be suppressed while the OSK is up**, or the mapper
is emitting `REL_X/REL_Y` into the desktop at the same time as it drives its own
cursors. Decide it explicitly.

### Two renderers over one core

| Context | Surface |
|---|---|
| **Installer** | bare TTY drawing (T2 §4's original choice) |
| **Desktop Mode** | Wayland **layer-shell** overlay |

Keep the core free of both. P4.2 will want exactly this seam.

### Typing

Emit through the `uinput` device the mapper already owns, so nothing under the
keyboard knows a controller exists — the property that makes one layer drive
`archinstall`, `gum`, and GTK alike.

## Steps

1. ✅ Layout core + hit-testing + shift layers, with unit tests. No device.
2. ✅ Character emission in the mapper (keycodes + modifiers), unit-tested.
3. ✅ Absolute dual-cursor mapping from both pads, unit-tested against the
   measured ranges — including diagonals, which is where T8's first failure
   mode bites.
4. ✅ TTY renderer, driven end to end by a virtual pad (`test/osk-tty-e2e.py`).
   ⚠️ **Still owed: `iwctl`/`gum` in QEMU.** The keyboard is proven to draw and
   to type; what is NOT proven is the two of them sharing one console. The
   intended mechanism is shrinking the TUI's reported window (TIOCSWINSZ) so it
   stays above the keyboard — see `deck_osk_tty.write_at`. Nothing has tested it.
5. ✅ Layer-shell renderer for Desktop Mode; `--osk-backend=layer` opens
   **this**, not squeekboard. Verified on Hyprland: real layer surface, focus
   never moves, driven end to end from a virtual pad.
6. ✅ Pointer suppression: the right pad stops feeding the pointer while the
   keyboard is up, so there is no motion to suppress in either backend.
7. Retire squeekboard from Desktop Mode **only once step 5 is proven on
   hardware** — it is the working fallback until then.

## Done when

- [ ] Both cursors move independently, one per trackpad, each trigger clicking
      its own half — **seen on screen by the operator**
- [ ] A Wi-Fi passphrase (mixed case, digits, symbols) is typed end to end with
      no keyboard attached
- [ ] The same layout core drives both renderers, unchanged
- [ ] Unit tests cover hit-testing, shift layers, and dual-cursor mapping, and
      are **mutation-tested**
- [ ] The system pointer does not fight the OSK's own cursors

## Failure modes to watch for

- **Testing one axis at a time.** Session 17's pointer emitted nothing on
  diagonal movement while every single-axis test passed. Any two-dimensional
  input must be tested with **both axes moving together**.
- **Trusting presence over behaviour.** Three separate times this session, a
  node was enumerated and silent. A cursor that exists is not a cursor that
  moves.
- **Assuming an axis by its name.** `ABS_HAT0X/Y` is called a hat and is a
  trackpad. Measure.
- **Building the renderer first.** The core is where the correctness is, and it
  is the half that can be tested without a screen or a human.

## Escalate if

- The layer-shell overlay cannot take input without stealing focus from the
  field being typed into — that is a design fork, not a bug
- Suppressing the system pointer turns out to need compositor cooperation
