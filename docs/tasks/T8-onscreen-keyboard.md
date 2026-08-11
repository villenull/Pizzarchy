# T8 — the on-screen keyboard we draw ourselves

**Model: Sonnet for the renderers, Opus for the input/layout core.**
**Status: specified 2026-08-10 (session 17), not started.**

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
| **Character keys** (letters, digits, symbols, shift) | ❌ **missing — the nav profile deliberately has none** |
| **A renderer** | ❌ missing |

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

1. Layout core + hit-testing + shift layers, with unit tests. No device.
2. Character emission in the mapper (keycodes + modifiers), unit-tested.
3. Absolute dual-cursor mapping from both pads, unit-tested against the
   measured ranges.
4. TTY renderer; drive `iwctl`/`gum` in QEMU with a virtual pad only.
5. Layer-shell renderer for Desktop Mode; STEAM+X opens **this**, not
   squeekboard.
6. Decide and implement pointer suppression while the OSK is visible.
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
