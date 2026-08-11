# P20 — Deck session runbook: the five approved changes, in order

> **Operator + Claude, one session, ~90 minutes.** Everything here was approved
> in `docs/PROGRESS.md` §5.25 (decisions 1–5) plus §5.26's one-line gate.
> Nothing in this file may be done without the operator present.
>
> **Read §0 before powering anything on.** Two items can leave the Deck unable
> to boot or unable to accept input; both have a rollback, and both rollbacks
> need SSH, which is why §0 makes you prove SSH works *first*.

---

## 0. Before you touch the Deck

### 0.1 The floor — what always gets you out

| Situation | Escape |
|---|---|
| Screen locked, nothing to type into | `ssh steamdeck` → `hyprctl eval 'hl.clear_crashed_lockscreen()'` (`docs/RECOVERY.md`) |
| No input at all — no pointer, no keys | `ssh steamdeck` → `systemctl --user restart deck-input-mapper` |
| SSH unreachable and screen unusable | **Hold Power ~10 s.** Boot leaves `lizard_mode=Y`, so the firmware supplies a pointer and arrows again |
| Will not boot at all | Volume Down + Power → boot manager → previous Limine entry, or Valve recovery (`docs/RECOVERY.md`) |

⚠️ **The 10-second hold is the real floor**, because the module parameter resets
on boot by design. Nothing in this session persists `lizard_mode` independently
of the mapper — that is the whole point of the fallback.

### 0.2 Pre-flight, on the dev machine

```bash
cd ~/Pizzarchy && git status --short && for f in test/unit/test-*.sh; do ./"$f" >/dev/null || echo "RED $f"; done && for f in test/unit/test-*.py; do python3 "$f" >/dev/null || echo "RED $f"; done && echo "all suites green"
```

- [ ] Working tree clean, every suite green. **Do not deploy a red tree.**
- [ ] `ssh steamdeck true` succeeds — prove the rollback path *before* you need it.
- [ ] Deck on mains power, not battery.
- [ ] A USB keyboard within reach. Not required by any step; it turns a bad
      surprise from a reboot into an annoyance.
- [ ] The Ventoy USB with the 4.0 ISO, for §1 only.

### 0.3 Snapshot first, always

```bash
ssh steamdeck 'sudo snapper list | tail -5'
cd ~/Pizzarchy && ./tools/deck-snapshot.sh 'pre-P20: lock fix, lizard fallback, QAM, default session, rotations'
```

- [ ] Snapshot **#8** exists and its number is written down here: `#____`

Rollback for anything in §3–§5 is `./tools/deck-rollback.sh 8`.

---

## 1. 🔴 FIRST, and from the USB: does the live ISO have the lizard knob?

**Why first:** it is read-only, it changes nothing, and it gates whether T4 has
a product at all (§5.26). If it fails, the rest of this session still stands but
T4's design needs rework — better to know at the start.

⚠️ **This must run from the BOOTED ISO, not the installed system.** Every
lizard-mode measurement this project owns came from the installed system running
Valve's Neptune kernel; the ISO boots a different kernel entirely.

1. Deck off. Insert the Ventoy USB.
2. Hold **Volume Down**, press **Power**, release on the chime. Choose the USB,
   then the Omarchy ISO.
3. At the installer's first screen, reach a shell (the ISO's own console).
4. Run, and **write the output into `docs/PROGRESS.md` §5.26**:

```bash
ls -l /sys/module/hid_steam/parameters/lizard_mode; cat /sys/module/hid_steam/parameters/lizard_mode; uname -r
```

| Result | Meaning |
|---|---|
| File exists, prints `Y`, `uname -r` is not a Neptune kernel | ✅ The gate is open. T4's text-entry design stands |
| File missing | 🔴 **Stop and report.** T4 has no keyboard in the installer; the design needs rework before any screen is written |
| Exists but not writable | 🟡 Report the exact mode; the design may still work via `modprobe` at ISO build time |

5. **Do not install anything.** Power off, remove the USB.

---

## 2. Deploy, and prove the fallback on hardware

Boot the Deck normally (it currently lands on the desktop — §5.25 row 4 changes
that in §6, deliberately last).

⚠️ **`deck-sync.sh` rsyncs `src/` to `~/omarchy-deck-sync/` on the Deck and
RUNS the named script there.** It does not install to `/usr/local/bin`, and
with no arguments `deck-session.sh` runs *every* install stage. Name the stage
explicitly via `DECK_STAGE_ARGS`, or you will re-run all of them:

```bash
cd ~/Pizzarchy
DECK_STAGE_ARGS=stage-lizard-mode ./tools/deck-sync.sh deck-session.sh
```

That syncs the mapper too (it rsyncs the whole of `src/`), then runs one stage
and streams back the journal for just that run.

- [ ] It exits 0 and its own verification passed (it exercises the helper both
      ways and restores the value it found).

### 2.1 The proof that matters — the fallback, on real hardware

This is the step the whole design exists for. **Do it before relying on
`lizard_mode=N` for anything else.**

```bash
ssh steamdeck 'cat /sys/module/hid_steam/parameters/lizard_mode'          # expect Y
ssh steamdeck 'systemctl --user restart deck-input-mapper'
ssh steamdeck 'cat /sys/module/hid_steam/parameters/lizard_mode'          # expect N
ssh steamdeck 'systemctl --user stop deck-input-mapper'
ssh steamdeck 'cat /sys/module/hid_steam/parameters/lizard_mode'          # expect Y  <-- the fallback
ssh steamdeck 'systemctl --user start deck-input-mapper'
```

- [ ] `Y → N → Y → N` exactly. **If the third read is not `Y`, stop** — the
      fallback is not working and every later step assumes it is.

Then the harder case, which a clean stop does not exercise:

```bash
ssh steamdeck 'systemctl --user kill --signal=SIGKILL deck-input-mapper; sleep 3; cat /sys/module/hid_steam/parameters/lizard_mode'
```

- [ ] Reads `Y`. ⚠️ If it reads `N`, that is the **cgroup-kill hole** — recorded
      in `docs/PROGRESS.md` §5.25 — and the Deck is now without input until you
      `systemctl --user start deck-input-mapper` over SSH. Do that, note the
      result, and treat the hole as open.

---

## 3. Measure QAM, then wire it up

The QAM button's evdev code **has never been measured**. The binding ships
inert and says so at startup, precisely so this can be filled in from one press.

```bash
ssh steamdeck 'systemctl --user start deck-input-mapper'   # lizard mode now N, so STEAM and QAM are visible
ssh -t steamdeck "sudo python3 -c \"
from evdev import InputDevice, ecodes as e, list_devices
cands = [InputDevice(p) for p in list_devices()]
pads  = [d for d in cands if e.EV_KEY in d.capabilities() and e.BTN_SOUTH in d.capabilities()[e.EV_KEY]]
if not pads:
    raise SystemExit('no gamepad node found -- is lizard_mode N and the mapper running?')
print('candidates:', [(d.path, d.name) for d in pads])
d = pads[-1]
print('watching', d.path, d.name, '-- press QAM now, Ctrl-C to stop')
for ev in d.read_loop():
    if ev.type == e.EV_KEY and ev.value == 1:
        print(ev.code, e.bytype[e.EV_KEY].get(ev.code))
\""
`````

- [ ] QAM's code recorded here: `______` (name: `____________`)

Then set `QAM_BUTTON` in `src/deck-input-mapper.py`, **on the dev machine**, run
its suite, and redeploy:

```bash
cd ~/Pizzarchy && python3 test/unit/test-deck-input-mapper.py &&
  DECK_STAGE_ARGS=stage-input-mapper ./tools/deck-sync.sh deck-session.sh &&
  ssh steamdeck 'systemctl --user restart deck-input-mapper'
```

### 3.1 Eyes on the screen — the three button behaviours

- [ ] **STEAM tapped** → the apps menu opens
- [ ] **STEAM held + X** → the on-screen keyboard toggles, and **no menu opens**
- [ ] **QAM** → the Omarchy menu (the one at the bar's top-left) opens
- [ ] Both trackpads still move the cursor, **including diagonally**

---

## 4. The lock fix — and it can only be judged by looking

Two changes (§5.24). Apply, then verify by **looking at the panel**.

```bash
ssh steamdeck 'systemctl --user mask omarchy-sleep-lock.service'
```

Then add the layer rule to the Deck's Hyprland config and reload. ⚠️ **Which
file is a choice, and it matters for T5:** put it beside the rotation in
`~/.config/hypr/monitors.lua` (already a per-user dotfile this project owns) or
in a dedicated `~/.config/hypr/deck.lua` sourced from the main config. Either
way **T5 must bake it into the image** — a rule that lives only in one user's
dotfile is absent from a fresh install (§5.12b: `/etc/skel` alone is too late,
the user already exists by then):

```
hl.layer_rule({ match = { namespace = "deck-osk" }, above_lock = 2 })
```

```bash
ssh steamdeck 'hyprctl reload && hyprctl configerrors'
```

- [ ] `configerrors` reports nothing. ⚠️ A **renamed key** shows up here; a Lua
      **syntax error silently discards the whole file**, so a clean reload is
      not proof the file parsed — check a keybinding still works.

### 4.1 The verification, and why the obvious one is worthless

⚠️ **`hyprctl layers` reports the surface identically whether the rule works or
not** — measured in the Tier 0 run. It cannot answer this question. **Only the
screen can.**

1. Raise the keyboard (STEAM+X).
2. Lock the session deliberately: `ssh steamdeck 'omarchy-shell lock lock'`
3. **Look at the Deck.**

- [ ] The keyboard is **visible on top of the lock screen**
- [ ] Typing on it puts characters in the password field
- [ ] Unlock works

**If you end up stranded** (artwork, no password field):
`ssh steamdeck "hyprctl eval 'hl.clear_crashed_lockscreen()'"`

- [ ] Power button no longer locks the device (press it, let it sleep, wake it)

---

## 5. Rotations — boot-chain, so this is the risky one

Two one-line changes: Limine's `interface_rotation: 270` and the kernel cmdline's
`fbcon=rotate:1`.

⚠️ **Neither has ever been seen rendered.** The predecessor value for the
desktop turned out upside down, so treat `270` as a hypothesis with a 50/50
chance of being wrong by 180°. Being wrong is cosmetic; being wrong in the
*config syntax* is not.

- [ ] Before editing, capture the current file: `ssh steamdeck 'sudo cp /boot/limine.conf /boot/limine.conf.p20-backup'`
- [ ] Apply both, then `ssh steamdeck 'sudo limine-entry-tool --tree'` to confirm the config still parses
- [ ] **Reboot and watch the physical screen**

| What you see | Do |
|---|---|
| Boot menu upright | ✅ Record the value that worked |
| Rotated 180° | Try `interface_rotation: 90`, same procedure |
| No menu / no boot | Volume Down + Power → previous entry; restore `limine.conf.p20-backup` over SSH |

- [ ] The TTY is upright. ⚠️ **You cannot get there with the controller** — the
      mapper emits no modifiers, so Ctrl-Alt-F2 is unreachable by design. Use
      `ssh steamdeck 'sudo chvt 2'` and look, then `sudo chvt 1` to return

---

## 6. LAST — make Gaming Mode the default

Deliberately last: after this the Deck boots into Steam, and the desktop is
reached through Steam's Power menu rather than directly.

```bash
cd ~/Pizzarchy && DECK_STAGE_ARGS=stage-default-session ./tools/deck-sync.sh deck-session.sh
ssh steamdeck 'sudo reboot'
```

- [ ] Boots into Gaming Mode unattended
- [ ] **Steam → Power → Switch to Desktop** works
- [ ] From the desktop, the return-to-Gaming-Mode path works
- [ ] Reboot once more: it still lands in Gaming Mode

---

## 7. While the operator is present — the human-only parity rows

These need eyes and ears and nothing else (P2.2). Batch them here rather than
booking a second session:

- [ ] Sound audible from the speakers
- [ ] Headphone jack switches output
- [ ] Microphone records
- [ ] Haptics fire
- [ ] Gyro responds
- [ ] Bluetooth pairs a device
- [ ] Gaming Mode's brightness slider moves the panel

Record each in `docs/findings/hardware-parity.md` as pass/fail **with what you
actually observed**, not "looks fine".

---

## 8. Close out

```bash
cd ~/Pizzarchy && ./tools/deck-snapshot.sh 'post-P20'
ssh steamdeck 'cat /sys/module/hid_steam/parameters/lizard_mode; systemctl --user is-active deck-input-mapper; systemctl --user is-enabled omarchy-sleep-lock.service'
```

Then update, in this order:

1. `docs/PROGRESS.md` §5.26 — the live-ISO answer from §1
2. `docs/PROGRESS.md` §5.21 — closed, or the cgroup hole if §2.1 found it
3. `docs/PROGRESS.md` §5.23 — QAM's code, and the three button behaviours
4. `docs/PROGRESS.md` §5.24 — whether `above_lock` rendered **on the panel**
5. `docs/findings/hardware-parity.md` — §7's rows
6. `docs/ROADMAP.md` — P2.1, P2.2, P2.4 status

⚠️ **Record what was observed, not what was expected.** Three of this project's
own checks have been wrong about themselves, and session 17 corrected two
"facts" written hours earlier the same day.

---

## 9. If you have to stop early

Stopping is safe at every step boundary. The state each leaves behind:

| Stopped after | Deck state |
|---|---|
| §1 | Untouched — nothing was written |
| §2 | Lizard mode follows the mapper. Boot leaves `Y`; device usable either way |
| §3 | As §2, plus working STEAM/QAM buttons |
| §4 | Power button no longer locks; keyboard draws above a lock |
| §5 | Boot chain changed — **do not stop here without confirming it boots** |
| §6 | Boots to Gaming Mode |

⚠️ **§5 is the only step that must not be left half-applied.** Finish it or
restore the backup.
