# T3 — Gaming Mode, Desktop Mode, and hardware parity

**Model: Sonnet for fork/rewrite mechanics. Opus for TDP/fan/sysfs logic
specifically** — bad hardware-control code risks the operator's only device.

## Objective

A Deck that boots into Gaming Mode by default, with all hardware working as
it does on stock SteamOS, and a two-way switch to an Omarchy desktop that's
reachable by controller alone.

## Prerequisites

- T0 done — you need `deck-sync.sh`, because this task is where the SSH
  iterate-in-place loop pays for itself
- T1 done — Neptune kernel booting

## Starting point

Fork `28allday/Super-Shift-S-Omarchy-Deck-Mode`. It solves the hard part
(SDDM session switching, NetworkManager/iwd handoff, drive auto-mount,
performance tuning scaffolding) but is built for generic AMD/NVIDIA
desktops and knows nothing about Deck hardware. See `PLAN.md` §6.4.

## Steps

### 1. Fork and strip

- Remove the GPU/monitor detection entirely — the Deck is fixed hardware.
  Hardcode APU and display parameters, gated on LCD vs OLED model detection
  from the start (`PLAN.md` §9.6) so LCD support is a table fill-in later.
- Remove the NVIDIA code paths. All of them.
- Remove the Intel-detection bail-out.

### 2. Flip the default session ⚠️ core requirement

Upstream boots to the desktop and switches to Gaming Mode on a keybind.
**This project needs the opposite.** First boot after install lands in
Gaming Mode; the desktop is the thing you switch *to*. Change the SDDM
default session config accordingly.

### 3. Desktop Mode entry point (from Gaming Mode)

- Steam's own "Exit to Desktop" under Power is the SteamOS-native affordance.
  Upstream already hooks this via `/usr/lib/os-session-select`.
- Verify it fires correctly and lands in Omarchy, not a black screen.
- This must work with **controller only** — no keyboard fallback.

### 4. Return to Gaming Mode (from Omarchy)

- A `.desktop` file calling `switch-to-gaming`, pinned wherever Quattro's
  Quickshell shell puts pinned/launcher items. **Verify against Quattro
  specifically** — the shell is a full rewrite and 3.x guidance won't hold.
- Keep the `Super+Shift+S` keybind as a fallback, but the icon is the
  requirement.

### 5. Deck hardware tuning — Opus, and hardware-safety-sensitive

Work through `PLAN.md` §6.5's parity table. Per item, use `deck-sync.sh` to
iterate — **never reinstall to test these**:

| Item | Notes |
|---|---|
| TDP / CPU governor | Via jupiter-staging sysfs, as `steamos-polkit-helpers` does. **Ask before running on hardware.** |
| Fan curve | Same caution. A bad fan curve is a thermal risk. |
| GPU (RDNA2) | Confirm gamescope build flags, RADV working |
| Wi-Fi | Confirm Neptune firmware covers the OLED radio (it differs from LCD) |
| Bluetooth | Controller + audio pairing with no manual setup |
| Speakers / haptics | The `cs35l41-dsp1-*` firmware warnings seen during manual install are unresolved — confirm audio actually works, don't just suppress the warning |
| Trackpads / gyro | Both sessions. Test gyro-as-mouse in desktop specifically. |
| Battery | Accurate %, charge limit option |
| Display | Refresh rate, HDR (OLED) |
| Buttons | Steam/QAM/Power in both sessions |

For each: record pass/fail plus the fix in `FINDING-hardware-parity.md`. This
doc is the LCD-support roadmap later.

### 6. Resolve `PLAN.md` §10.3 on hardware

Test both candidate designs for Desktop Mode gamepad input head-to-head in
a single hardware session (Steam-in-background vs. custom mapper). Cheap
experiment, large design consequence.

## Done when

- [ ] Fresh boot lands in Gaming Mode without intervention
- [ ] Steam → Power → Exit to Desktop reaches Omarchy, controller only
- [ ] An icon in Omarchy returns to Gaming Mode, controller only
- [ ] Both directions survive a reboot in each state
- [ ] Every row in the parity table has a recorded result
- [ ] `FINDING-hardware-parity.md` complete for OLED, LCD rows marked untested
- [ ] §10.3 decided with evidence

## Failure modes to watch for

- **Testing by reinstalling.** All of this is post-install config. If you
  find yourself proposing a reinstall, re-read `PLAN.md` §9.4.
- **Claiming LCD support.** You have no LCD to test on. Say so.
- **Session-switch black screens.** Common failure; check
  `journalctl --user -u gamescope-session` first.

## Escalate if

- Anything requires writing to the Deck (most of this does — batch the
  requests rather than asking per-item, and describe exactly what will run)
- TDP/fan work is about to touch hardware — always ask, every time
