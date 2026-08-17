# T13 — Steam usable in Desktop Mode: two finished prototypes, one decision

> ## ✅ RESOLVED 2026-08-17 — **B (the hidraw sandbox) won and is merged.**
>
> Tested on the operator's Deck through the real apps launcher. Every decisive
> observable passed, the operator confirmed pointer + chords + OSK + brightness
> by hand with Steam open, and **Balatro launched and was playable with the
> mouse** — the one real unknown, since Steam's pressure-vessel builds its own
> nested namespace inside ours.
>
> | test | result |
> |---|---|
> | Pad survives Steam launch | ✅ `input25` still present (it vanished before) |
> | Steam holds no hidraw fd | ✅ `0` |
> | Steam is in *our* namespace | ✅ `mnt:[4026532598]` vs host `mnt:[4026531841]` |
> | Mapper keeps its pad | ✅ still holding `event7`, never entered its wait loop |
> | Pointer / chords / OSK / brightness | ✅ operator confirmed |
> | Steam itself drivable | ✅ operator confirmed |
> | **A game launches and plays** | ✅ **Balatro, mouse works in-game** |
> | Touchscreen unaffected | ✅ `hidraw3` is `hid-multitouch`, never covered |
>
> The negative control came for free: the operator launched Steam from the menu
> *before* the desktop entry was wired up, got yesterday's broken behaviour, and
> the pad node came back as **`input25` where it had been `input10`** — destroyed
> and re-created, exactly as predicted.
>
> **A (extest) was not merged.** It stays on its worktree branch. It remains the
> fallback if the sandbox ever breaks, and its licence fix to
> `tools/build-extest.sh` is worth salvaging independently — see the bottom of
> this document.
>
> Everything below is the decision as it stood before the test, kept for the record.

**Status:** both approaches are BUILT, unit-green, and unmerged, each in its own
worktree. Neither has a single minute of hardware time — the Deck was powered
off all night. **They cannot both ship.** This document is the fork and the
order to test it in.

Background and the proof of mechanism: `docs/findings/P40-steam-desktop-input.md`.
The defect itself: `docs/findings/P39-steam-desktop-window-and-input.md` §Defect 2.

---

## The one-line version

Steam draws its Desktop-Mode cursor with X11 `XTestFake*`, and XTEST under
XWayland reaches X clients **only** — never the compositor. So Steam's pointer
exists inside Steam and nowhere else. Either we **intercept** that (extest), or
we stop Steam taking the controller at all so **our own** pointer keeps working
(sandbox). Intercept or prevent. Not both — if Steam cannot claim the pad, Steam
Input emits no XTEST, and extest has nothing to convert.

---

## The fork

| | **A — extest bridge** | **B — hidraw sandbox** |
|---|---|---|
| What it does | Converts Steam's XTEST calls to real uinput events | Denies Steam the controller's hidraw node, in one process's mount namespace |
| What you get back | **The pointer, and only the pointer** | **Everything** — trackpads, mapper, our chords, the OSK, STEAM/QAM |
| What it costs | Nothing inside Steam | **No Steam Input in Desktop Mode**; a game launched from the desktop gets no gamepad from the built-in pad |
| Hardware evidence | ✅ **Measured PASS on this Deck** (T10 row 1) | ❌ **None.** Rests on one GitHub comment about someone else's machine |
| Ships under our licence rule | ✅ MIT throughout, zero copyleft, no runtime deps | ✅ No new package at all — no bubblewrap, no firejail, no setuid |
| Gaming Mode risk | None (Steam behaves as today if it fails) | None (no global state; block dies with the process) |
| Worst case | Steam **aborts** mid-session on an extest panic | Games may not launch from the desktop at all |
| Expiry risk | 🔴 SteamRT3 containerisation would silently kill it — Valve's stated direction | Low |

Both worst cases at *launch* are "no better than today, loudly". The asymmetry
is later: A can kill Steam mid-session (19 `.unwrap()`s, no error handling, and
a wrapper cannot guard a panic an hour in); B can fail to launch games at all.

---

## Recommended order — cheapest and most decisive first

### 0. The free one. Does the touchscreen work with Steam open?
Zero code, possibly already shipped. The digitizer (`FTS3528:00 2808:1015`) is
an I²C HID device with **no relationship to `hid-steam`** — Steam opening the
controller's hidraw node cannot touch it. Nobody has ever checked.

If it works, the operator already has a keyboardless escape hatch today, and the
severity of the whole defect drops before either prototype is merged.

    # Steam CLOSED (positive control), then Steam OPEN — same two reads.
    # Touch the screen during each.
    timeout 5 cat /dev/input/event10 | wc -c

Non-zero in **both** states = the escape hatch exists.

### 1. Test B first, because its single unknown is binary and fast
B dominates A **if** games still launch: it restores everything rather than the
pointer alone. Its whole risk is one question — does Steam's pressure-vessel,
which creates its own nested user namespace, work inside ours? Nested userns is
permitted and B sets no `no_new_privs` (deliberately, unlike bwrap), so it
*should* — but that is INFERRED, not measured.

The decisive observable is not "the cursor moved":

    ls /sys/bus/hid/devices/0003:28DE:1205.0003/input   # MUST STILL EXIST with Steam open
    readlink /proc/$(pgrep -x steam)/ns/mnt             # MUST DIFFER from /proc/self/ns/mnt

The second line is what separates "the block worked" from "we got lucky".
Then the control that makes it mean anything: relaunch with
`DECK_STEAM_DESKTOP_BLOCK=off` and confirm `.0003/input` **disappears**.

**Then launch one small game.** That is the go/no-go.

### 2. If B fails, A is ready and already measured working
Full plan in the agent report; the pass criterion is a real `/dev/input` read on
extest's virtual node — non-zero bytes under confirmed movement, against a
0-byte idle control. "The cursor seemed to move" does not count.

---

## The question only the operator can answer

If **both** pass tomorrow, this stops being a technical question and becomes a
product one:

> **A real desktop pointer *plus* our chords and the OSK, at the cost of Steam
> Input in Desktop Mode (B) — or Steam's own pointer with Steam Input fully
> preserved (A)?**

Nobody but the operator can price that. Note B's cost is narrower than it
sounds: it covers only the built-in controller (`28de:1205`), so a plugged-in
Xbox or DualSense keeps full Steam Input in Desktop Mode, and **Gaming Mode is
untouched either way**.

---

## Fixed along the way, independent of which wins

* 🔴 `tools/build-extest.sh` gated on the licence and then **never copied it**.
  A compiled `.so` is a copy under MIT and the ISO is a redistribution — we were
  in violation. It now ships `LICENSE` + generated `THIRD-PARTY-LICENSES`, and
  the build refuses to proceed without them.
* The extest pin `cb77cd4` was recorded twice as "v1.0.4". It is untagged `main`
  HEAD; tag `1.0.3` dereferences to its **parent**. Corrected in `PROGRESS.md`.
* Our recorded R1-10.3 ("add the user to the `input` group" for uinput) is
  **wrong and was never implemented**: `steam` hard-depends on `steam-devices`,
  whose `60-steam-input.rules` tags `/dev/uinput` `uaccess`.
* `hid-steam.c`'s `steam_param_set_lizard_mode()` **skips any device with a
  client attached** — so P39's 0-byte lizard result is documented kernel intent,
  not a quirk. Worth a `PROGRESS.md` §7 line so nobody re-investigates.
