# T8 — the on-screen keyboard we draw ourselves

**Model: Sonnet for the renderers, Opus for the input/layout core.**
**Status: ✅ ALL SEVEN STEPS DONE — proven on hardware, session 18, 2026-08-10.**

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
> | 7. Retire squeekboard from Desktop Mode | ✅ **done, operator-confirmed on the Deck** |
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
> ### Step 7 — squeekboard is retired as the DEFAULT, not removed
>
> `stage-input-mapper` now writes `ExecStart=… --osk-backend=layer`, so STEAM+X
> opens our overlay instead of squeekboard. **squeekboard stays installed on
> purpose**, because the mapper falls back to it automatically:
>
> ```
> overlay will not start        -> fall back, and show squeekboard now
> overlay exits after starting  -> fall back, and show squeekboard now
> ```
>
> ⚠️ **That fallback is the entire justification for flipping the default.** Our
> overlay needs a compositor, a library that must be preloaded, and a live
> process; squeekboard needs none of those. Without the fallback, any one of them
> failing on a device with no keyboard attached leaves it unable to type — and
> with `lizard_mode=N`, unrecoverable except over SSH. With it, the worst case is
> the behaviour that shipped before this step. **It is proven, not asserted:**
> `test/osk-tty-e2e.py` runs a mapper with `WAYLAND_DISPLAY` unset and checks the
> fallback fires, names its reason, and leaves the mapper alive.
>
> **Rollback is one line:** `MAPPER_OSK_BACKEND=dbus` in `src/deck-session.sh`,
> then re-run the stage.
>
> ⚠️ **A real regression to weigh, not hidden:** squeekboard **auto-shows on text
> focus** (§5.20, proven on hardware). Ours is **summon-only** — STEAM+X. Valve's
> own keyboard is summon-only too (R-35b), so this matches stock SteamOS, but it
> is a step back from what the Deck does today. Ours could learn focus-triggered
> show by binding `zwp_input_method_v2` the way squeekboard does; that is new
> work, not part of step 7.
>
> ### ✅ The hardware pass ran, and the operator confirmed it
>
> **`docs/findings/P18-osk-hardware-pass.md` (R-43…R-46).** Snapshot #8, three
> modules installed, unit rewritten to `--osk-backend=layer`, STEAM+X pressed,
> **"it works"** — with **zero fallbacks**, so what was on screen was ours and
> not squeekboard.
>
> ⚠️ **That confirmation was one argv away from being attached to the wrong
> process.** The session had left `--demo` overlays running while debugging, so
> "it works" could have described one of those. Settled by checking the live
> surface's argv (no `--demo`) and its parent (the mapper). When a session has
> left debug artifacts on the device, a confirmation names a *thing on screen*,
> not a *code path*.
>
> 🐞 **And the pass found a defect nothing in this repo could see: the mapper
> died every time the pad re-enumerated** — `OSError: [Errno 19] No such device`
> out of `pad.read()`, **six crashes and nine restarts in one boot**, against a
> `StartLimitBurst` of 5. With `lizard_mode=N` exhausting that limit is a
> handheld with no input. Fixed by handing `ENODEV` to `pick_device`, which
> already waits patiently for a pad to return. `test/mapper-pad-loss-e2e.py`
> destroys a pad underneath a live read; verified to fail 5 assertions with the
> fix reverted.
>
> **Still open, deliberately:** ours is **summon-only**; squeekboard's
> focus-triggered auto-show is still enabled and independent of the mapper. Both
> may appear. Decide after seeing summon-only in use.

> **Totals: 134 + 106 + 49 + 47 + 19 unit assertions, plus 22 end-to-end.
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
4. ✅ TTY renderer, driven end to end by a virtual pad (`test/osk-tty-e2e.py`)
   **and by `gum` in QEMU** (`test/vm/vm-osk-tty-test.sh`, R-47): they share one
   console, and `gum.received = hlH1` — typed with the trackpads, read back from
   what gum wrote to a file. ✅ **R-49 resolved:** `stty rows` resizes a Linux
   VT, so the keyboard was falling off the end and being clamped onto one line.
   ⚠️ Open: a full-screen curses TUI (archinstall) will still overdraw it.
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

---

## 9. 🆕 Follow-on: visual parity with SteamOS's keyboard (operator request, 2026-08-11)

**Requested after using ours on hardware.** The operator supplied a screenshot of
Valve's Desktop-Mode keyboard as the reference. Ours works; it does not *look*
like the thing a Deck owner recognises.

### The constraint, stated first because it bounds the whole task

⛔ **Do not copy Valve's artwork, icons, glyph images or theme assets.**
`docs/findings/P16-redistribution-and-trademark.md` already settled this: the ISO
redistributes whatever it carries, so lifted assets are a licensing problem at
release rather than a styling question now. **Draw our own glyphs in the same
visual language.** The affordance is what matters and the affordance is not
copyrightable; the artwork is.

### What to match — structural, all reimplementable from scratch

| Element | Reference behaviour | Notes |
|---|---|---|
| Symbol row | Digits `1`–`0` with their shifted symbols shown **above** the digit on the same key | Ours has the digits; the second legend is the visible difference |
| Key treatment | Dark rounded keys, light glyphs, one clearly highlighted key under each cursor | We already track two cursors — the highlight is the part users read |
| Split halves | Left/right halves visually separated, matching the two-trackpad model | Ours is already split logically; make the split *visible* |
| **Controller-glyph hints** | Modifier keys carry the button that fires them — Backspace, Enter and Shift each show their button | **The highest-value item.** It is what makes the keyboard self-teaching, and it is pure information, no artwork needed |
| Bottom utility row | Arrows, a paste affordance, a "move the keyboard" affordance | Decide which we actually support before drawing them — a dead key is worse than a missing one |

⚠️ **Match the affordances, not the pixels.** A user who has used a Deck should
recognise the *shape* of the thing and know which button does what without
hunting. Pixel-identity is neither required nor wanted.

### Where it lands

`src/deck_osk_layout.py` owns the layout tables and hit-testing;
`src/deck_osk_wayland.py` and `src/deck_osk_tty.py` render. The legends and glyph
hints are layout data, so most of this is one file — **and the TTY renderer must
degrade honestly**, since a bare console cannot draw rounded keys. Do not let a
styling change break the installer's keyboard, which is the one with no fallback.

### Done when

- [ ] Shifted symbols visible on the digit row, both renderers
- [ ] Modifier keys show their controller button, using **our** glyphs
- [ ] The split between halves is visible, not just logical
- [ ] `test-deck-osk-layout.py` still green, extended to cover the new legends
- [ ] The TTY renderer still passes `test/osk-tty-e2e.py` by hand
- [ ] **[H]** the operator looks at it on the Deck and says it reads as familiar

### 9a. 🔴 The badges cannot copy Valve's without copying Valve's INPUT MODEL

**Found 2026-08-11 when the restyle was first seen on the panel.** The `hint`
field means two incompatible things, and the suites caught the collision before
it shipped.

**Ours:** `hint` = *which trigger presses keys in this half* (`L2` left, `R2`
right). `test-deck-osk-layout.py` enforces it: *"every hinted key's glyph names
the trigger for the half it is drawn in."*

**Valve's:** the badge = *which face button is a shortcut for this key.*

Checked against the mapper's real table, only one of Valve's four is true here:

| Valve's badge | True in our mapper? |
|---|---|
| `Y` = Space | ✅ `BTN_WEST → KEY_SPACE` |
| `X` = Backspace | ❌ X is **Tab**, and is the STEAM+X chord key |
| `L2` = Shift | ❌ L2 **selects** whatever the left cursor is on |
| `R2` = Enter | ❌ R2 selects in the right half; **A** sends Enter |

🔴 **Exact parity would mean abandoning the dual-cursor design.** Valve drives
**one** cursor with face-button shortcuts; T8 chose **two** cursors with the
triggers as select, one per thumb — and the operator confirmed on hardware that
this is right ("that's exactly as it should be"). The badges are downstream of
that choice. **Copying them faithfully means copying the interaction model.**

⚠️ **And the reference is not static.** The operator reports (2026-08-11, from
video) that **the badges appear and disappear** during use. That explains why
two reference screenshots disagreed and why reading a mapping off either one
kept contradicting the code. **Whatever this is, it is contextual behaviour, not
a label set** — and it must be understood before any mapping is copied.

**Operator's stated intent so far:** X = Backspace · Y = Space · **no button for
Enter** · L2 = Shift. Y is already true; the rest are not.

### 9b. What the next session needs before touching this

1. **Reference frames**, since video cannot be read from a session: the keyboard
   **at rest**, with **shift held**, and at the moment **a badge appears or
   disappears**. Without the third, the contextual rule is unknowable.
2. **A decision on the collision above** — truthful subset, or full parity with
   the input-model change it implies.
3. ⚠️ **Exact layout placement** (space, tab, the bottom row) is also requested
   and is *not* blocked by any of this — it is independent of the badges.

⛔ **Unchanged and non-negotiable:** our own glyphs, never Valve's artwork
(`docs/findings/P16-redistribution-and-trademark.md`). Matching *placement and
behaviour* is fine; shipping their assets is not.

### 9c. ✅ Landed already

- **Divider removed** between the halves — drawn, seen, rejected, and the
  suite's assertion **inverted** so it cannot creep back.
- Glyph badges, shifted-symbol legends and the digit dual-legend **shipped and
  deployed**; `shift=once` correctly gives `q→Q` and `1→!` **in the logic**,
  verified by driving `face()` directly. ⚠️ **Whether that reaches the screen on
  a shift press is UNVERIFIED** — the operator reported it not visibly changing,
  and the redraw path was traced but not disproved.

### 9d. 📐 Reference layout, transcribed from video frames (2026-08-11)

Two frames supplied by the operator (a 2022 Steam Deck desktop-mode video,
timestamps 3:15 and 3:29). **Transcribed rather than copied** — this is key
placement, which we reimplement with our own glyphs (§9's constraint stands).

⚠️ **A webcam overlay covers the bottom-right of both frames.** Anything in that
region is marked `[obscured]` and must be confirmed before it is built.

```
row 1   ~`   !1  @2  #3  $4  %5  ^6  &7  *8  (9  )0  _-  +=   [Ⓧ] Backspace
row 2   Tab      q  w  e  r  t  y  u  i  o  p        {[  }]   |\
row 3   Caps⇪    a  s  d  f  g  h  j  k  l     :;  "'   [R2] Enter
row 4   Shift    z  x  c  v  b  n  m     <,  >.  ?/     [obscured: right Shift]
row 5   ☺        [Ⓨ] ————— space (wide) —————     ◀  ▶   [obscured: Paste, Move]
```

**Established by these frames:**

- **Dual legends on every number and punctuation key** — shifted face **above**
  the base face, both always visible. We match this.
- **`Caps` carries a lock icon**; `Shift` does not.
- **Space is one wide key** with the `Ⓨ` badge at its **left edge** — not a
  separate Y key beside it. ⚠️ Our bottom row currently renders `☺`, then a
  distinct `Y`, then space. **That is the clearest layout divergence.**
- **`◀ ▶` only** on the bottom row in these frames — no up/down arrows visible,
  where ours draws four.
- Row 4's right `Shift` and row 5's `Paste`/`Move` are `[obscured]`. An earlier
  still showed all three, so they exist; their exact spans do not.

### 9g. 🎯 THE DEFINITIVE REFERENCE — six states captured at native resolution

**Captured 2026-08-12 on the Deck itself** with `grim`, driving Valve's own
keyboard through the extest bridge: idle, Shift held, Caps latched, left pad
touched, right pad touched, plus cursor states. Full-resolution and uncropped,
so **every `[obscured]` item in §9d and every "unresolved" item in §9f is now
settled**. This section supersedes both where they disagree.

⚠️ **The images are NOT vendored into this repo** — `docs/findings/
P16-redistribution-and-trademark.md`. Transcribed only, and we draw our own
glyphs.

#### The layout — ONE CONTINUOUS GRID, full width, no split

```
row 1  [~`] [!1] [@2] [#3] [$4] [%5] [^6] [&7] [*8] [(9] [)0] [_-] [+=]  (Ⓧ) Backspace
row 2  [Tab]  q  w  e  r  t  y  u  i  o  p  [{[] [}]] [|\]
row 3  [Caps + L3 icon]  a  s  d  f  g  h  j  k  l  [:;] ["']      [R2] Enter
row 4  [Shift  L2]  z  x  c  v  b  n  m  [<,] [>.] [?/]           [L2  Shift]
row 5  [☺]  (Ⓨ) ———— space, wide ————  [▲/◀] [▼/▶]  [Paste]  [Move + icon]
```

🔴 **There is NO GAP between a left and right half.** One continuous keyboard
spanning the full width. Ours renders two half-grids with a gap — the operator
called this out first, and it is the single most visible difference.

**Resolved unknowns:** `` ~` `` exists · `Tab` exists · the `R2` key reads
**`Enter`** · the arrow cluster is **two keys with dual legends**, not four
keys · there **is** an `☺` emoji key at the far left of row 5 (ours has none) ·
a **`Move`** key with a keyboard icon sits right of `Paste`.

#### 🔴 The legend rule — ours is WRONG, and it is wrong on every screen

Ours draws both faces permanently. Valve swaps them:

| State | Number/punctuation/arrow keys | Letters |
|---|---|---|
| **Unshifted** | **dual legend** — shifted small ABOVE, base large below | lowercase |
| **Shift active** | **ONLY the shifted face**, larger, centred (`~ ! @ #`, `{ } \|`, `▲ ▼`) | UPPERCASE |
| **Caps active** | **unchanged — dual legends stay** | UPPERCASE |

⚠️ **Caps ≠ Shift, and that is the subtle part.** Caps changes *letter case
only*; Shift changes symbols, case **and the arrow keys**. Note the
consequence: **`▲`/`▼` are the SHIFTED faces of `◀`/`▶`** — Shift is how a
user reaches up/down. Any layout that gives the arrows their own keys makes
Shift's arrow behaviour unreachable.

#### Active-modifier styling, and the cursor

- **An active modifier turns BLUE** — both `Shift` keys under Shift, the `Caps`
  key when latched. Nothing else changes colour.
- **The cursor is a WHITE (inverted) key face PLUS a small BLUE DOT** drawn at
  the thumb's precise position on that key. Two cursors, one per pad, both
  visible at once. Ours has no equivalent of the dot.
- Action keys (`Tab`, `Caps`, `Shift`, `Backspace`, `Enter`, `Move`) are drawn
  **black**; letter keys are dark grey.

#### ✅ Badge gating — confirmed, symmetric, and per-pad

| Pad touched | Hidden | Still shown |
|---|---|---|
| left | **both** `L2` badges (both Shift keys) | `R2`, `Ⓧ`, `Ⓨ`, `L3` |
| right | the `R2` badge | `L2` ×2, `Ⓧ`, `Ⓨ`, `L3` |
| neither | — | everything |

**Only the trigger badges gate.** `Ⓧ`, `Ⓨ` and `L3` are always visible, which
fits §9e's semantics exactly: face buttons and the stick click are unconditional
shortcuts, triggers are contextual.

✅ **And it is implementable** — see §9e: a lift reports exactly `0,0`,
measured on hardware, so "untouched" is a real state and not a timeout.

### 9f. 📸 REFERENCE SCREENSHOT, idle state — supersedes the video transcription

**Operator-supplied 2026-08-12, captured with NO trackpad touched**, i.e. the
state in which *every* badge is displayed. This is the frame §9d and §9e both
lacked. **Transcribed, not copied** — §9's constraint stands, and the image is
deliberately not vendored into this repo.

```
row 1   [!1] [@2] [#3] [$4] [%5] [^6] [&7] [*8] [(9] [)0] [_-] [+=]   (Ⓧ) Back…
row 2    q  w  e  r  t  y  u  i  o  p   [{[]  [}]]
row 3   [L3 + icon]  a  s  d  f  g  h  j  k  l  [:;]  ["']        [R2]
row 4   [L2]  z  x  c  v  b  n  m  [<,] [>.] [?/]                 [L2]
row 5   (Ⓨ) ————————— space (wide) —————————   [▲][▼]/[◀][▶]  [Paste]  [M…]
```

#### 🔴 Corrections to §9d, which was transcribed from two video frames

| §9d claimed | The screenshot shows |
|---|---|
| *"`◀ ▶` only … no up/down arrows visible, where ours draws four"* | **All four arrows are present.** Ours was right and §9d was wrong — a webcam overlay had hidden them. **Do not "fix" our four arrows.** |
| row 3 left is `Caps⇪` | the key carries an **`L3`** badge and an icon — Caps is bound to the **left stick click**, not a trigger |
| row 4 right Shift `[obscured]` | it exists, and **both** Shift keys carry an **`L2`** badge |

#### What the screenshot establishes, and it is a lot

- ✅ **Space is ONE wide key with `Ⓨ` at its left edge.**
  🔴 **But §9d's "clearest divergence" DOES NOT EXIST, and §9f repeated it
  without checking the source.** `SPACE_KEY` in `deck_osk_layout.py` has been
  `act("", "space", span=3, …)` — one wide key — since the layout core landed,
  and **there is no `☺` key anywhere in this repo** (grepped). §9d described
  our bottom row from memory and was wrong; I carried it forward as
  "confirmed". The real gap was only the missing badge, now added.
  **Check the code, not the note about the code.**
- ✅ **Dual legends** — shifted face above, base below — on **numbers and
  punctuation alike**, both always visible. We match this.
### ✅ OPERATOR DECISION 2026-08-12 — MATCH VALVE EXACTLY, INCLUDING THE BINDINGS

> *"i dont care about the x is supposed to be tab functionality. i want the
> functionality of the buttons as they appear in the deck images to be matched
> exactly with our OSK"* — and, on the look: *"its still way off the mark …
> i still see a gap between the left half and the right half"*.

**This settles the open question below and reverses it.** The target is not
"our model, badged honestly" — it is **Valve's model, reproduced**. Concretely:

| Button | Was | **Now must be** |
|---|---|---|
| `X` (`BTN_NORTH`) | `KEY_TAB` | **Backspace** |
| `Y` (`BTN_WEST`) | `KEY_SPACE` | Space *(already correct)* |
| `L2` | commit left cursor | commit left cursor **+ Shift while the left pad is untouched** |
| `R2` | commit right cursor | commit right cursor **+ Enter while the right pad is untouched** |
| `L3` (`BTN_THUMBL`) | unbound | **Caps** |

⚠️ **Tab is deliberately given up.** §2.3 wanted it for archinstall's "next
field"; the operator has weighed that and chosen parity. **Do not reintroduce
it as a badge or a binding without asking.**

🔴 **The visual gap between the halves must go.** Ours renders two half-grids
with a gap; Valve's is one continuous keyboard. The two-cursor model does not
require a visual split — each cursor addresses its own half of a *continuous*
grid — so this is a rendering change, not an input-model change.

✅ **And the badge gating is now implementable** — see §9e: a lift reports
exactly `0,0`, measured on hardware 2026-08-12, so "untouched" is a real state
rather than a timeout.

- ⚠️ **`Ⓧ` on Backspace — was true for Valve and a lie for us; the decision
  above makes it TRUE for us too, by changing the binding.**
  Measured against our own mapper: `BTN_WEST` (Y) → `KEY_SPACE`, so the `Ⓨ`
  badge on space is truthful; but `BTN_NORTH` (X) → **`KEY_TAB`**, not
  Backspace (`deck-input-mapper.py:160-161`). Painting `Ⓧ` on our Backspace
  would be *confidently wrong*, which §9a establishes is worse than absent, so
  it is deliberately not drawn.
  🔴 **Closing this divergence is an OPERATOR decision, not a code one:** it
  means rebinding X from Tab to Backspace, and Tab is "next field", which
  archinstall's forms need. Matching Valve's badge costs a real input
  affordance. **Do not change it without asking.**
- 🆕 **Two badge SHAPES, and the distinction is semantic:** face buttons are
  drawn in a **white circle** (`Ⓧ`, `Ⓨ`); triggers and stick clicks are drawn
  in a **white rounded rectangle** (`L2`, `R2`, `L3`). That is a convention we
  can reproduce with our own glyphs without touching Valve's artwork.
- 🆕 **Modifier and action keys are visibly DARKER than letter keys** — a
  black key face against the letters' dark grey. Ours does not differentiate.
- 🆕 **`Paste` is a real labelled key** on the bottom row, right of the arrows.

#### ⚠️ Still unresolved — the capture is cropped, do not invent these

- The **left edge is cut**: whether row 1 has a `` ~` `` key and whether row 2
  opens with `Tab` cannot be read from this image.
- The **right edge is cut**: the `R2` key's text (§9d read it as `Enter`) and
  the key after `Paste` (§9d read `Move`, here only `M…` is visible).
- The arrow cluster reads as either a **2×2 block of four keys** or **two keys
  carrying dual legends** (`▲` over `◀`, `▼` over `▶`) in the same
  shifted-above-base style as the number row. **The second reading fits this
  keyboard's own convention and is therefore the likelier one — but it is a
  reading, not a measurement.** One uncropped capture settles it.

### 9e. 🔬 The badges are CONTEXTUAL — evidence, and the rule is not yet known

| Badge | Frame 1 (3:15) | Frame 2 (3:29) |
|---|---|---|
| `Ⓧ` Backspace | present | present |
| `Ⓨ` Space | present | present |
| **`L2` Shift** | **absent** | **present** |
| **`R2` Enter** | **present** | `[obscured]` |

**So `Ⓧ`/`Ⓨ` are persistent and `L2`/`R2` are not.** That fits the semantics:
`Ⓧ`/`Ⓨ` are true face-button shortcuts, while `L2`/`R2` describe *the triggers*,
whose relevance depends on state.

~~**Suspect: cursor position.**~~ ⚠️ **WRONG, and the warning below is why it was
hedged.** The cursor is on `b` in frame 1 and on `Backspace` in frame 2, which
looked like a rule and was a coincidence of those two frames.

### ✅ THE RULE, from the operator using the real keyboard (2026-08-11, session 21)

> *"L2 for shift … comes on if no trackpad is touched. As soon as you touch it
> it disappears and L2 is now serving the function of clicking letters selected
> by the left trackpad."*

**The trigger badges are gated on TRACKPAD TOUCH, not cursor position:**

| State | What `L2` means | Badge |
|---|---|---|
| No trackpad being touched | **Shift** | `L2` Shift shown |
| Left trackpad touched | **commit the letter under the left cursor** | Shift badge hidden |

This explains both video frames without the cursor-position rule: on `b` the pad
was in use, on `Backspace` it was not.

🔴 **This DISSOLVES §9a's "badges cannot copy Valve's without copying Valve's
input model".** §9a recorded `L2 = Shift` as flatly contradicting ours
(*"L2 **selects** whatever the left cursor is on"*) — but that is Valve's
touched-state meaning, i.e. **the same as ours**. It is not a different input
model; it is our model plus a *second, idle-state* meaning we simply do not
have. Re-read §9a before acting on it.

⚠️ **UNKNOWN, and both matter before anyone implements this:**

✅ **BOTH ANSWERED by the operator, 2026-08-12: the gate is PER-PAD.** The left
trackpad hides the `L2` badge only; the right trackpad hides the `R2` badge
only. So `R2` mirrors `L2` exactly, and each trigger's badge is gated on *its
own side's* pad. The idle screenshot in §9f is the all-badges-visible state
this predicts.

⚠️ **AND ONE HARD IMPLEMENTATION CAVEAT.** Copying this needs a real
*touch/no-touch* signal, and §7's measured fact is that **a lifted pad reports
`0` (centre)** — which is indistinguishable from a thumb resting at the centre.
So "is the pad being touched" is **not** derivable from the axis values we
already read. Before designing anything on top of this rule, measure whether the
pads emit a separate touch bit (`BTN_TOOL_FINGER`, `BTN_TOUCH`, or similar) on
this hardware. **If they do not, the rule cannot be reproduced faithfully.**

➡️ **The layout work in §9d is NOT blocked by this** and can proceed alone.
