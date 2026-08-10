# FINDING T2 — Can a gamepad drive the installer at the kernel input layer?

**Result: YES for navigation — CONFIRMED by driving real TUIs, not reasoned
about.** A ~200-line `uinput`/`evdev` mapper drives `gum` prompts and
`archinstall`'s curses menu with no cooperation from either. Neither knows a
controller exists.

**Text entry is the one genuine gap**, and it is narrow: two screens need it
(Wi-Fi password, account credentials). That is `docs/PLAN.md` §6.1a items 5 and 7 —
not a general UI problem.

Decided 2026-08-10, in QEMU (`test/vm/vm-gamepad-spike-test.sh`), against the
snapshot-bearing Neptune substrate.

---

## 1. What T4's scope is, now that this is answered

`docs/tasks/T2-gamepad-input-spike.md` framed the two outcomes as differing by weeks:

- **Yes** → T4 is mostly configuration: reduce prompts, set defaults, map
  buttons, add glyphs. **Days.**
- **No** → T4 needs bespoke gamescope-hosted Quickshell/QML screens. **Weeks.**

**The answer is Yes, with a text-entry caveat.** T4 is the days-shaped task,
plus one focused piece of work for text entry (§4). No custom UI framework,
no reimplementation of any installer screen, no fork of `archinstall`.

That also means the **same mapper serves T3's Desktop Mode** (R1 §10.3 design
(b)) — one artifact, two consumers, which was the hoped-for outcome in
`docs/PLAN.md` §6.1's "if a generic mapper works, it solves navigation for
archinstall, gum, and any custom screens all at once."

---

## 2. The artifact

`src/deck-input-mapper.py` — reads a pad's evdev node, emits keyboard events
through a `uinput` virtual keyboard. The kernel routes those to whatever owns
the active VT (console) or compositor focus (desktop).

| Input | Key | Why |
|---|---|---|
| d-pad / left stick | arrows | navigation, with auto-repeat while held |
| A | Enter | confirm |
| B | Esc | back / cancel |
| Y | Space | toggle — `archinstall` and `gum --no-limit` multi-select |
| X | Tab | next field |
| L1 / R1 | PageUp / PageDown | long lists (mirror lists, timezones) |
| Start / Select | Enter / Esc | controller-menu convention |

Design notes that matter:

- **Nav-only by design.** No character keys. Every key here is safe to hold
  down, and the profile carries no assumption about what is on screen.
- **Stick hysteresis** (engage 0.5, release 0.35 of half-range) so a stick
  resting near the threshold cannot machine-gun key events.
- **Stick and d-pad share one direction state**, so both cannot hold the same
  direction simultaneously.
- **Auto-repeat is the mapper's own** (400 ms delay, 150 ms interval), emitted
  as evdev value 2 — the same thing a held physical key produces. The pad's
  own repeats are ignored.

`test/unit/test-deck-input-mapper.py` — 26 assertions on the pure translation core. No
device, no `uinput`, no root; runs in CI with the other unit suites.

---

## 3. Evidence

`test/vm/vm-gamepad-spike-test.sh` boots the substrate and, **inside the guest**,
builds the real delivery path:

```
scripted virtual pad (uinput)
      -> deck-input-mapper.py          <- the artifact under test
      -> virtual keyboard (uinput)
      -> kernel VT input               <- the part that makes this honest
      -> tmux client attached on VT2
      -> pty -> gum / archinstall
```

The VT hop is the point. Synthetic key events go to the **active virtual
terminal**, not to a pty — so this exercises the same path a live-ISO
installer session uses. `tmux capture-pane` then reads what a user would
actually see, and every step asserts on **both** rendered text and outcome
(exit status, the file the prompt wrote), per `docs/PLAN.md` §9.7's
assert-on-artifacts rule.

| Assertion | Result |
|---|---|
| `gum choose` — d-pad down ×2, A to confirm | picks `Gamma` ✅ |
| `gum choose --no-limit` — down, Y toggle, down, Y toggle, A | returns `Two,Three` ✅ |
| `gum choose` — **stick** held once | advances several rows: engage **plus auto-repeat** ✅ |
| `archinstall` main menu renders under the chain | ✅ |
| A (Enter) opens a submenu — screen changes | ✅ |
| B (Esc) returns — screen changes again | ✅ |
| d-pad down moves the highlighted row (SGR attributes differ) | ✅ |

Environment: root, no compositor, console only — i.e. live-ISO-shaped.

### What this does not prove

- **The real Deck controller's event codes.** The virtual pad models the
  Linux gamepad ABI subset (`BTN_SOUTH/EAST/NORTH/WEST`, `TL/TR`,
  `START/SELECT`, `HAT0`, `ABS_X/Y`). The Deck's controller is captured in
  P1.5's recon (`/proc/bus/input/devices`) — expect extra nodes (trackpads,
  IMU, back paddles) and possibly different button codes. **Mapping tables
  may need a Deck-specific entry; the mechanism will not change.**
- **Omarchy's own ISO screens.** Upstream's installer wraps `gum`, so the
  primitive is proven — but the actual screen flow gets driven once the 4.0
  beta ISO is in hand.
- **Compositor delivery.** Desktop Mode routes through Wayland focus, not the
  VT. R1 §10.3 already verified the permissions half on hardware.

---

## 4. The text-entry gap — the honest part of this finding

The mapper deliberately emits no character keys, so two screens are unsolved
by it alone:

- **Wi-Fi password** (`docs/PLAN.md` §6.1a item 7) — on the critical path since
  `docs/PROGRESS.md` §2.2 made the install use the network
- **Account username + password** (item 5)

> **✅ DECIDED 2026-08-10, by inspecting the built 4.0 ISO.** The live
> environment contains **no Wayland compositor of any kind** — no
> `hyprland`, `gamescope`, `weston`, `sway`, `cage` or `labwc` binary in
> `/usr/bin`, and no `squeekboard`/`wvkbd`. (Searches do hit `hyprland`, but
> only as `/etc/skel/.config/hypr/` skeleton files and archinstall's
> *profile definitions* — descriptions of what it can install, not something
> that runs.) It is a pure console/TTY environment carrying `archinstall`,
> `gum`, `python3`, `iwctl`.
>
> **So option 1 is out for the installer**, unless T5 adds an entire
> compositor stack to the ISO — a far larger change than the alternative.
> **Option 2 is the answer: a mapper-drawn OSK that renders on a bare TTY
> and types through the same `uinput` keyboard the mapper already owns.**
>
> `squeekboard` remains correct for **Desktop Mode** (T3), which does run
> under Hyprland. The two contexts get different answers, and that is fine —
> the mapper is shared, the OSK is not.

Three options, as evaluated:

1. ~~**`squeekboard` in the live ISO.**~~ **Ruled out** — needs a Wayland
   compositor; the live environment has none (above).
2. ✅ **A mapper-drawn OSK** — an on-screen grid the mapper itself renders
   and types from, no compositor needed. Works on a bare VT, fully under
   this project's control, immune to the compositor question. **This is the
   choice.** Bounded work: the mapper already owns the input path and the
   virtual keyboard; what is missing is a grid renderer and a character-key
   emission path (the nav profile deliberately has none).
3. **PIN-pad only** for the account screen (SteamOS-style). Still a useful
   supplement — but it **cannot serve a Wi-Fi password**, so it is never the
   answer on its own.

---

## 5. Bugs this spike found in its own harness

Recorded because each is the same failure class the project exists to attack —
something looked broken while working, or looked fine while proving nothing.

1. **A tmux client with no `TERM` silently exits.** The probe runs from a
   systemd unit with no `TERM` in its environment; `tmux attach` refused the
   terminal and died, leaving VT2 switched but **clientless**. Symptom:
   every key vanished, indistinguishable from "the mapper does not work."
   Fixed with `env TERM=linux`, and a `tmux_client_attached` assertion now
   makes the difference visible.
2. **Readiness gated on text that appears too early.** Waiting for `Gamma`
   matched the *echoed command line* before `gum` had even started, so keys
   were sent into a shell prompt. Gates now match rendered menu markers
   anchored at line start (`^> …`).
3. **`archinstall` draws its TUI on stderr.** `2>/root/archinstall.err`
   redirected the entire interface into a file — the escape stream, title bar
   and all, was sitting in that file while the pane looked empty. Never
   redirect a TUI's stderr.
4. **`gum`'s list wraps, and a 4-item list ate exactly one full cycle.**
   Engage + 3 auto-repeats = 4 moves = back to the first item, which the
   assertion read as "the stick did nothing" while the mapper was working
   perfectly. The list is now 8 items and the assertion measures **distance
   moved** (≥ 2 rows), which additionally proves auto-repeat fired rather
   than just the initial press.
5. **Shared shell state let one failure corrupt later tests' meaning.** Each
   test now runs in a fresh tmux window.

---

## 6. What T4 should do with this

- Build the screens on `gum`/`archinstall` primitives. Do **not** write custom
  TUI widgets — the mapper makes the existing ones controller-navigable.
- Keep `docs/PLAN.md` §6.1a's aggressive prompt reduction. Every prompt is a
  chance to break without a keyboard, and that argument is unchanged.
- Budget the **text-entry** piece explicitly (§4) — it is the only part of T4
  this spike does not de-risk.
- Ship the mapper as a systemd unit in the live ISO, started before the
  installer. On the installed system the same binary runs as a `--user`
  service (R1 §10.3), needing the `input` group and the `/dev/uinput` udev
  rule — **both already hardware-verified**.
- Glyphs (`docs/PLAN.md` §6.1 A/B/X/Y iconography) remain open and are a
  trademark question, not an engineering one (`docs/PROGRESS.md` §5.5).
