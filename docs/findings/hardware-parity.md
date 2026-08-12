# Hardware parity — Gaming Mode vs Omarchy desktop (ROADMAP P2.2)

**Session 16, 2026-08-10.** OLED Deck (Valve Galileo), Omarchy 4.0 + Neptune
`6.11.11-valve29`. Both columns come from the **same probe script** run in each
session, so the comparison is like-for-like rather than two different
investigations.

> **What this is and is not.** Every row below is *programmatically* observable —
> a device enumerates, a service is active, a node exists. **None of it proves a
> human experience.** Audio being routed is not "sound comes out"; a gyro node
> existing is not "the gyro works". Rows needing a person are marked ⏸ and left
> for a session with someone holding the Deck.
>
> **P2.3's rows (TDP, fan curves, charge limits) are deliberately absent.**
> `CLAUDE.md` requires per-item operator approval for those every time. Nothing
> here reads or writes them beyond a battery percentage.

## Parity table

| Subsystem | Desktop (Hyprland) | Gaming Mode (gamescope) | Verdict |
|---|---|---|---|
| **Wi-Fi device** | `wlo1`, `ath11k_pci` | `wlo1`, `ath11k_pci` | ✅ identical |
| **Wi-Fi state** | connected | connected | ✅ identical |
| **Bluetooth service** | active | active | ✅ identical |
| **BT adapter** | `90:03:71:41:8E:68`, powered | same, powered | ✅ identical |
| **BT rfkill** | not blocked | not blocked | ✅ identical |
| **PipeWire / WirePlumber** | active / active | active / active | ✅ identical |
| **Audio sinks** | 2 | 2 | ✅ identical |
| **Default sink** | `…nau8821-max.HiFi__Speaker__sink` | same | ✅ identical |
| **Audio sources** | 3 | 3 | ✅ identical |
| **Audio cards** | 2 (HDMI + `nau8821-max`) | same 2 | ✅ identical |
| **Display** | `card0-eDP-1` connected | same | ✅ identical |
| **Backlight** | `59457/65535` readable | same | ✅ identical |
| **Kernel** | Neptune `6.11.11-valve29` | same | ✅ identical |
| **Input devices** | **17** | **16** | ⚠️ differs — see below |
| **Joystick nodes** | `js0`, `js1` | `js0` only | ⚠️ differs — see below |
| Speaker output audible | ✅ **2026-08-11** | ⏸ | 440 Hz sine, both channels, heard at 55% |
| Headphone jack detect | ✅ **2026-08-11** | ⏸ | Default sink moved **automatically** `43 Speaker → 56 Headphones` on insertion; 660 Hz heard in the headphones and **not** the speakers |
| Mic capture | ✅ **2026-08-11** | ⏸ | 11.7 s capture: **peak 4545/32767 (13.9% FS)**, per-second RMS varying **5.3×** (98→510). Played back and recognised by ear |
| Trackpad → pointer | ✅ moves + clicks (`event5`) | n/a — Steam owns it | verified session 17; **diagonal confirmed 2026-08-11** |
| Trackpad haptics | ✅ **2026-08-11** | ⏸ | `event7` advertises `FF_RUMBLE/PERIODIC/SQUARE/TRIANGLE/SINE`; strong, weak and combined effects uploaded and played — **all three felt** |
| Gyro actually responding | ✅ **2026-08-11** | ⏸ | 30 s of deliberate tilting: **32,552 `EV_ABS` events, 6 of 6 axes moved**, spans 4,481–47,598. No flat axis |
| Button mapping correctness | ✅ **verified session 17** | ⏸ | see below. **QAM measured 2026-08-11**: `BTN_BASE` (294) |
| Gaming Mode usable on screen | n/a | ✅ **operator confirmed, session 17** | closes P16 §5's caveat |
| BT pairing with a real device | ✅ **2026-08-11** | ⏸ | `soundcore Life Q30` (`98:47:44:D8:CF:14`): **Paired/Bonded/Trusted/Connected all yes**, `bluez_output` sink created at s16le 2ch 48 kHz, took default, 880 Hz **heard in the headphones** |
| **BT adapter state at boot** | ⚠️ **`Powered: no`** | ⏸ | 🆕 2026-08-11. Not rfkill-blocked (soft **and** hard both `no`), service active — the radio simply starts **down** and had to be powered on by hand. Unknown whether stock SteamOS does the same; recorded as an observation, **not** yet a defect. A user expecting their headphones to reconnect on boot would notice |
| Gaming Mode brightness slider | n/a | 🟡 **works, but see caveat** | 2026-08-11: operator saw the panel change; backlight moved **21627 → 24826** of 65535. ⚠️ **§5.17 makes this row untrustworthy as PRODUCT evidence** — the slider works here partly via `99-deck-testing`'s blanket NOPASSWD sudo, which must never ship, so this means "works on the test rig". ✅ **But the canary is intact:** the node is still **0644**, not 666, so Steam did *not* fall back to `chmod a+w`. START-HERE records 666 as the signal that a helper broke |
| **Session switch after today's changes** | n/a | ✅ **2026-08-11** | 🆕 `steamos-session-select gamescope` from the desktop landed in Gaming Mode with `gamescope` running, Steam under `-gamepadui`, session `Desktop=gamescope Active=yes`. Confirms switching survived the rotation and lizard-mode changes |
| **`lizard_mode` restored by the switch** | n/a | ✅ **2026-08-11** | 🆕 Incidental but valuable: the mapper went `inactive` and the knob returned to **`Y`** automatically during a *real session switch*. §2.1 of the runbook only proved this with a manual `systemctl stop` |

### How the human rows were judged, 2026-08-11

⚠️ **Three of these were measured, not just observed**, because "it seems fine"
is how this project has been fooled before (R-29: a correctly-bound evdev node,
permanently silent, while every check passed).

- **Mic** — a recording that is digital silence sounds exactly like one you
  forgot to speak into. Peak **and** per-second RMS variation were computed; a
  flat non-zero level (DC offset or noise floor) would have **failed**, and
  `peak > 0` alone would have passed it.
- **Gyro** — the probe reports each axis's min/max span and fails any axis that
  never moves, rather than reporting that `event8` exists.
- **QAM** — captured with two `BTN_SOUTH` delimiter presses either side, on a
  probe watching **every** candidate node at once. Two of the four enumerated
  nodes were completely silent throughout (`event5`, `event6`, both named "Valve
  Software Steam Controller"); a single-node probe could have called a working
  button dead.

**Haptics and the three audible rows are genuinely subjective** and are recorded
as the operator's report, which is the correct oracle for them.

**Everything that can be checked without hands is at parity except input**, and
the input difference is Steam behaving as designed rather than a defect.

## The input difference: Steam replaces the native nodes

Diffing the device name sets between sessions:

```
ONLY in desktop:     "Steam Deck"                  (event7 js0)
                     "Steam Deck Motion Sensors"   (event8 js1)
ONLY in gamescope:   "Microsoft X-Box 360 pad 0"
```

So when Steam runs it **takes the controller over via hidraw and re-presents it
as a virtual Xbox 360 pad**, and the native `Steam Deck` gamepad and motion
sensor nodes disappear. That is why the count drops 17 → 16 and `js1` goes away.

### Full enumeration, desktop session

| Device | Handlers | Role |
|---|---|---|
| `Valve Software Steam Controller` | `event5 mouse1` | trackpads → **mouse** (lizard mode) |
| `Valve Software Steam Controller` | `sysrq kbd event6` | buttons → **keyboard** (lizard mode) |
| `Steam Deck` | `event7 js0` | **the real gamepad node** |
| `Steam Deck Motion Sensors` | `event8 js1` | gyro / accelerometer |
| `FTS3528:00 2808:1015` | `event18 mouse2` | touchscreen |
| `FTS3528:00 … UNKNOWN` | `event19 mouse3` | touchscreen (second) |
| `AT Translated Set 2 keyboard` | `event4` | built-in keyboard |
| `Power Button` ×2, `Lid Switch`, `Video Bus`, `PC Speaker`, HDMI audio ×4, headset jack | — | platform |

## ⚠️ Two things this corrects or sharpens for T4 / P2.1

**1. Event node numbers are NOT stable between the live ISO and the installed
system.** §5.9 recorded, from the live ISO: buttons on the keyboard-emulation
node **`event5`**, trackpads on **`event4`**, real gamepad on **`event11`**. On
this installed system the same roles sit on **`event6`** (kbd), **`event5`**
(mouse) and **`event7`** (gamepad). Anything that hardcodes those numbers from
§5.9 will bind the wrong device. `src/deck-input-mapper.py` selects by
*capability* (`BTN_SOUTH`), not by number or name, which is the right design and
is reconfirmed by this.

**2. The device is named `"Steam Deck"`, not `"Steam Deck Controller"`.** A probe
searching for the latter returns zero in both sessions. Worth stating because
this session already lost time to a near-miss name (`gamescope` vs
`gamescope-wl`); anything matching input devices by name needs the exact string.

**Consequence for P2.1:** ~~the desktop input mapper has the native `Steam Deck`
node (`event7 js0`) available, because Steam is not running there. It does not
have to contend with the virtual Xbox pad, which only exists in Gaming Mode.~~

⚠️ **CORRECTED 2026-08-10 (session 17) — this was wrong, and it mattered.** The
node is **enumerated but silent**. With Steam not running the Deck is in *lizard
mode*, and Valve's firmware routes the buttons to the emulated keyboard/mouse
nodes (`event6`/`event5`) while `event7` emits nothing at all. The mapper was
bound to it, reported `active`, and was a **complete no-op**.

Enumerated and live are different claims. This table was built by counting
nodes, which cannot tell them apart — see `docs/findings/P17-input-and-osk.md`
R-29/R-31 for the measured timeline and the `hid_steam` `lizard_mode` knob that
makes the node live.

## Reproducing

`hw-probe.sh` (session 16 scratch) prints a stable `key=value` report; run it in
each session and `diff`. Two traps it hit, both worth avoiding:

- **Never `grep`/read `/dev/input/event*`** to test for liveness — reading an
  input node **blocks until an event arrives**, which hangs the probe. Count the
  nodes instead.
- **Time-box every external call.** Over SSH there is no terminal and no session
  bus, so `bluetoothctl` and `pactl` block indefinitely. Export
  `XDG_RUNTIME_DIR`/`DBUS_SESSION_BUS_ADDRESS` and wrap each call in `timeout`.
