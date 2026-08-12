# T10 — the Steam+extest spike: does Valve's own keyboard work on our desktop?

> **One Deck session, ~45 min, operator present throughout.** Decides whether
> Desktop Mode's keyboard is Steam's own (via the extest bridge) or ours (the
> approved touch/restyle plan, currently ON HOLD pending this result).
>
> Evidence chain: R-41/R-42 (`P17-input-and-osk.md`) measured that a resident
> Steam takes the pad and its input reaches nothing. R-53
> (`P20-steam-xtest-closure.md`) measured why: XTEST reaches neither Wayland
> clients nor the compositor pointer on Hyprland. **R-54 (same file, addendum)
> measured the bridge:** extest's XTEST→uinput translation DOES reach
> Wayland-native clients on Hyprland. What has never been measured anywhere:
> **Steam itself driving that bridge.** That is this spike.

## Objective

Preload the 32-bit extest into a resident Steam on the Deck and measure, on the
panel and with file oracles, whether Steam Input delivers: trackpad→pointer,
STEAM+X→Valve's keyboard, dual-cursor trackpad typing, touchscreen typing — into
**Wayland-native** applications.

## Why

If it works, Desktop Mode gets Valve's actual keyboard — exact layout, real
badges, dual cursors, touch — for the cost of wiring a preload, and most of the
OSK desktop feature work (restyle, touch, auto-hide) becomes unnecessary. If it
fails, the option is closed at the last untested link, on hardware, and the OSK
plan resumes with nothing wasted.

## Prerequisites

- [ ] `~/ISOs/extest-cb77cd4/libextest-i686.so` exists (else run
      `tools/build-extest.sh` — pinned, contained toolchain, ~3 min)
- [ ] Deck reachable (`ssh steamdeck true`), snapshot taken
      (`./tools/deck-snapshot.sh 'pre-T10 extest spike'` — **read the number
      snapper prints; do not assume**)
- [ ] Steam signed in on the Deck (it is, since P1.5)
- [ ] ⚠️ Know the state you are entering: **while Steam holds the pad, our
      mapper has no device** — STEAM-tap/QAM menus and our OSK will be dead
      *by design* for the duration. That is expected, not a finding. SSH is the
      escape at every step; it is proven.

## Steps

### 1. Deploy the library and stage the oracle

```bash
scp ~/ISOs/extest-cb77cd4/libextest-i686.so steamdeck:/tmp/libextest.so
```

On the Deck (SSH), stage a typing oracle — a Wayland terminal running
`cat > /tmp/t10-typed.txt`, confirmed `xwayland=False` via
`hyprctl -j activewindow`. What lands in that file is the measurement; the
screen is corroboration.

### 2. Launch Steam resident, preloaded, WINDOWED

```bash
ssh steamdeck 'LD_PRELOAD=/tmp/libextest.so nohup steam >/tmp/t10-steam.log 2>&1 &'
```

Windowed, **not** `-silent`, deliberately: state must be visible for the first
run. Wait for the window (can take ~30 s).

- [ ] `grep -i extest /proc/bus/input/devices` on the Deck shows
      **`extest fake device`** — the bridge is alive inside Steam
- [ ] Our mapper's journal shows it lost the pad and is waiting (R-44
      machinery) — **expected**
- [ ] `lizard_mode` reads irrelevant while Steam owns the pad; note its value
      anyway

### 3. The measurements, in order of importance

| # | Test | Oracle | Result |
|---|---|---|---|
| 1 | Right trackpad moves the desktop pointer | eyes + `hyprctl cursorpos` changing | |
| 2 | **STEAM+X raises Valve's keyboard** | eyes: is it Valve's, on the desktop, windowed correctly? | |
| 3 | **Dual-cursor trackpad typing** into the oracle terminal | `hello` + Enter → read `/tmp/t10-typed.txt` | |
| 4 | **Touchscreen taps** on Valve's keyboard | more text → the file | |
| 5 | Pointer coordinate sanity under `transform = 3` | does the cursor land where the pad gesture says? extest sizes its ABS device from the **X root** — on this panel that is rotated/scaled territory; watch for offset or 90° error | |
| 6 | Steam's keyboard focus behaviour | typing lands in the field, focus does not jump to the keyboard window | |
| 7 | 🔴 **THE LOCK.** `loginctl lock-session` (or power button) while Steam is resident | **Prediction: unanswerable without USB/SSH.** Steam's keyboard is an XWayland window — it *cannot* render above `ext-session-lock` — and our OSK has no pad while Steam holds it. If confirmed, this is the Steam route's hardest product problem | |
| 8 | Quit Steam → the pad returns | mapper journal shows rebind; STEAM-tap/QAM menus work again; our OSK summonable | |

### 4. Tear down

Quit Steam, confirm row 8, remove `/tmp/libextest.so`, keep the logs.

## Done when

Every row above has a recorded result, `docs/findings/` carries a
`T10-steam-extest-spike.md` findings file with the oracle file contents quoted,
and `docs/PROGRESS.md` §5.29 records the decision this enables.

## Failure modes

- **Steam starts but no `extest fake device`:** the preload did not take (32-bit
  loader path, or Steam's bootstrap re-execs stripping `LD_PRELOAD`). Check
  `/tmp/t10-steam.log` for `ERROR: ld.so` lines. extest's repo ships
  `override_steam_desktop_file.sh` for the persistent-wiring case; for the spike,
  try `LD_PRELOAD` on the inner binary via Steam's `STEAM_RUNTIME` env instead.
- **Device exists but nothing types:** the R-54 dev-machine result says the
  translation works, so suspect Steam-side: desktop layout not active, or Steam
  never saw the pad. `steam://` desktop layout settings; check Steam sees the
  controller at all.
- **Typing lands but coordinates are wrong (row 5):** same class as the
  rotations — record the exact error; do not guess a fix on the Deck.
- **The Deck becomes uncontrollable:** SSH `pkill -TERM steam` (by PID if the
  pattern trap bites — §7), pad returns, mapper rebinds. Worst case: power hold,
  reboot lands in Gaming Mode (§6 default), which always works.

## Escalate if

- Row 7 confirms the lock is unanswerable under a resident Steam **and** the
  operator still wants the Steam route — that needs a design (pause/kill Steam
  on lock? our OSK as the lock keyboard with a pad handoff?) with real
  complexity, and it should be priced before committing.
- extest requires patching to work with current Steam — we would then own a
  fork of a preload shim against a proprietary moving target, which is exactly
  the maintenance shape this project has avoided elsewhere.

## The decision this feeds

| Outcome | Consequence |
|---|---|
| Rows 1–6 pass, row 7 has an acceptable answer | Steam+extest becomes the Desktop Mode keyboard; OSK plan narrows to installer+lock (both already done); new work: preload wiring as a `deck-session.sh` stage, tray host (the retired §2.6 constraint returns), autostart policy |
| Rows 1–6 pass, row 7 unacceptable | Operator chooses: hybrid complexity vs. our-OSK plan. Honest default: our OSK |
| Any of rows 1–4 fail | Option closed **on hardware, at the last link** — resume the approved touch/restyle plan immediately, nothing further owed to this question |
