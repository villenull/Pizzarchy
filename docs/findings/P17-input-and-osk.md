# Session 17 — the input path, seen on a screen for the first time (R-29…R-35)

**2026-08-10, OLED Deck, operator present and holding the device.** Session 16
closed with the honest admission that *"nothing here was seen on a screen"*.
This session was the eyes-and-hands pass for the input half.

> **Headline: the input mapper was a complete no-op on the desktop, and had two
> defects underneath that, one of which made the d-pad unusable even after the
> first was fixed.** All three were invisible to a passing unit suite and to
> `systemctl is-active`. Every one was found by correlating what a human pressed
> against what the kernel actually emitted.

## Method — and why the first two attempts were worthless

A probe listened on **every** input node at once and printed an interleaved
timeline, so the question was "where did this press go?" rather than "did the
node I already suspected see it?" That distinction is P16 §7's pattern, and it
mattered immediately: the first probe watched only the pad node and the mapper's
virtual keyboard, saw nothing, and could not tell a dead mapper from a dead
probe.

The second attempt failed differently. Fifteen buttons were pressed in one
batch; only four produced events, and **a silent button leaves no marker**, so
no event could be attributed to a specific press. The fix was to make the
operator press **A between every test button** as a delimiter. A reliably emits
`KEY_ENTER`, so each gap between two Enters is exactly one button and silence
inside a gap is unambiguous. Every mapping below comes from a delimited run and
was cross-checked against an earlier undelimited one.

## R-29 — lizard mode swallows six buttons entirely, and the pad node is silent

With Steam not running, the Deck sits in **lizard mode**: Valve's firmware
presents emulated keyboard and mouse nodes and the native gamepad node stays
quiet. Measured on the installed system (§5.9 recorded this from the *live ISO*;
it holds here too):

| Physical button | Emits | Node |
|---|---|---|
| A | `KEY_ENTER` | `event6` *Valve Software Steam Controller* (kbd) |
| B | `KEY_ESC` | `event6` |
| D-pad U/D/L/R | arrow keys | `event6` |
| ☰ Menu | `KEY_ESC` | `event6` |
| ⧉ View | `KEY_TAB` | `event6` |
| L2 | `BTN_RIGHT` | `event5` (mouse) |
| R2 | `BTN_LEFT` | `event5` |
| Trackpad | motion + click | `event5` |
| **X** | **nothing, on any node** | — |
| **Y** | **nothing** | — |
| **L1 / R1** | **nothing** | — |
| **STEAM / QAM** | **nothing** | — |

**Lizard mode gives Enter, Esc, Tab, arrows and both mouse buttons — but no
Space.** X, Y, L1, R1, STEAM and QAM are consumed by the firmware and reported
on *no* evdev node at all, so nothing in user space can recover them.

**Consequence for T4:** `Y → KEY_SPACE` is the mapper's reason to exist —
archinstall's multi-select toggle. With the mapper inert there is no way to
press Space with the controller. §5.9's "lizard mode already makes the installer
navigable" is true for movement and confirmation and **false for toggling**.

## R-30 — the fix is a documented kernel knob

```
/sys/module/hid_steam/parameters/lizard_mode        # writable, "Y" by default
parm: lizard_mode:Enable mouse and keyboard emulation (lizard mode) when the gamepad is not in use
```

Writing `N` silences `event5`/`event6` and brings the native `Steam Deck` pad
node (`event7`) fully alive, including the six swallowed buttons. It is a module
parameter, so it does **not** persist across a reboot — anything depending on it
must set it deliberately.

⚠️ **It is a trade, not a free win.** With lizard mode off there is no pointer
and no keyboard emulation, so the mapper becomes the *only* input path. If the
mapper is not working, the device is uncontrollable without SSH.

## R-31 — the mapper was bound to a silent node, and P2.1 could not tell

`deck-input-mapper.service` was `active`, its log said
`reading /dev/input/event7 (Steam Deck)`, and it emitted **nothing, ever**,
because lizard mode kept that node silent. P2.1's hardware verification —
"service active, bound `event7` by capability, virtual keyboard created" — is
true in every particular and proves nothing about whether a single key is
delivered.

⚠️ **This corrects `docs/findings/hardware-parity.md`,** which concluded: *"the
desktop input mapper has the native `Steam Deck` node (`event7 js0`) available,
because Steam is not running there."* The node is **enumerated but silent**.
Available and live are different claims, and only the second one matters.

This is the **fourth** instance of P16 §7's pattern in this project.

## R-32 — the mapper's docstring is right about X/Y; an early reading of it was wrong

`hid-steam` assigns the **Nintendo-style** codes, and the kernel's own aliases
confirm it: physical **X** reports `BTN_NORTH/BTN_X`, physical **Y** reports
`BTN_WEST/BTN_Y`. So `BTN_WEST → KEY_SPACE` and `BTN_NORTH → KEY_TAB` deliver
exactly the documented intent — physical X is "next field", physical Y is
"toggle". Recorded because the mapping looks inverted next to the Xbox
convention and will invite a "fix" that breaks it.

## R-33 — DEFECT: the d-pad emitted nothing, because the Deck sends buttons, not a hat

`hid-steam` **advertises `ABS_HAT0X/Y` and never sends them.** The d-pad arrives
as discrete `BTN_DPAD_UP/DOWN/LEFT/RIGHT` key events. The mapper's `HAT_MAP`
handled only the axes, `BUTTON_MAP` had no d-pad entries, so every d-pad press
fell through and emitted nothing.

The unit suite passed throughout — it drove `ABS_HAT0*` exclusively, a device
model this hardware never produces. **A suite can be green and still be testing
a machine that does not exist.**

Fixed with `DPAD_BUTTON_MAP`, routed through the existing hat state machine so a
d-pad press and a stick push still cannot double-hold one direction.

## R-34 — DEFECT: a resting stick cancelled every held direction ~10 ms in

With R-33 fixed the d-pad mapped correctly but would not **hold**:

```
19.16  down  BTN_DPAD_DOWN   <- event7      operator presses
19.16  down  KEY_DOWN        <- event9      mapper emits
19.17  up    KEY_DOWN        <- event9      released 10 ms later
21.80  up    BTN_DPAD_DOWN   <- event7      operator lets go, 2.6 s later
```

`_stick_direction` chose its hysteresis branch on `state.active_key is not
None` — *"is some key held"* — rather than on what the stick itself was doing.
Once the d-pad engaged a direction, the next resting-stick sample took that
branch, computed `frac ≈ 0`, reported neutral, and released the key. **The
analog sticks jitter continuously, so this fired within milliseconds, every
time**, and killed auto-repeat with it.

The two sources were sharing one slot. Fixed by giving each its own direction
(`hat_dir`, `stick_dir`, plus the d-pad's held set) and combining them with
digital input winning over the stick, so a resting stick can never cancel a
held d-pad.

**Verified on hardware after the fix** — press and release now track the
physical button exactly across a 3.4 s hold, and auto-repeat is measurably the
tuned feel: first repeat **0.40 s** after press (`REPEAT_DELAY`), then every
**0.15 s** (`REPEAT_INTERVAL`).

### What the suite had to learn

Six mutations were introduced; the first pass caught four.

- **An "autorepeat ignored" assertion passed for the wrong reason.** Repeating an
  already-held direction is a no-op through the hat state machine whether or not
  the guard exists. Pinned instead with a repeat for a button that is *not* held.
- **A regression test for R-34 passed with the hysteresis reverted**, because the
  new precedence rule alone already protects a held d-pad. Two changes fix R-34
  and only one was pinned; the sub-engage-stick case now pins the other.

Both are the same failure as the code's: **a check that cannot distinguish "I
looked and found nothing" from "I looked in the wrong place."** All six
mutations are caught now, including a reconstruction of the original defect.

## R-35 — the OSK DOES appear on text focus. One GSettings key gated it.

Session 16 left this open as *"needs eyes"*. **Answered: it works.**

```bash
gsettings set org.gnome.desktop.a11y.applications screen-keyboard-enabled true
```

It ships **`false`** on this Deck. squeekboard honours it as its auto-show gate,
so with it unset the keyboard never appears no matter what else is correct.
With it `true`, focusing a text field pops the keyboard — **seen on screen**.

### ⚠️ This finding was first recorded as a NEGATIVE, and that was wrong

Four conditions were tested and all "failed", producing a confident conclusion
that focus-triggered show was unavailable and T4 must drive the OSK explicitly:
stock session; `fcitx5` stopped and squeekboard restarted; a dialog launched
after squeekboard to rule out ordering; and `GTK_IM_MODULE=wayland`.

**Every one of those was downstream of the same unexamined gate.** Four
independent-looking experiments that share a hidden precondition are one
experiment. The error was concluding a mechanism was absent after testing only
the ways it might be *configured*, without once tracing whether the mechanism
itself ran.

The protocol trace is what broke it open, and it showed the chain was **already
working end to end**:

```
# client side (GTK/zenity)
-> zwp_text_input_manager_v3#83.get_text_input(new id zwp_text_input_v3#79, wl_seat#3)
   zwp_text_input_v3#79.enter(wl_surface#46)      <- compositor grants focus
-> zwp_text_input_v3#79.enable()
-> zwp_text_input_v3#79.set_content_type(0, 0)
-> zwp_text_input_v3#79.commit()

# input-method side (squeekboard)
-> zwp_input_method_manager_v2#37.get_input_method(wl_seat#36, new id zwp_input_method_v2#35)
   zwp_input_method_v2#35.activate()              <- IT WAS BEING ACTIVATED ALL ALONG
   zwp_input_method_v2#35.done()
```

Hyprland 0.56.2 advertises `zwp_text_input_manager_v3`,
`zwp_input_method_manager_v2` and `zwp_virtual_keyboard_manager_v1`, GTK binds
text-input-v3 and enables it, and squeekboard receives `activate()`. Nothing was
broken; the keyboard was being told to show and declining.

**Method note worth keeping:** the two traces cost minutes and needed no
operator at all — zenity focuses its entry automatically. They should have come
*before* the fourth button-press experiment, not after the negative was written
down.

Also recorded and still true: **Omarchy 4.0 ships and runs `fcitx5`**
(`INPUT_METHOD`, `XMODIFIERS`, `QT_IM_MODULE` all `fcitx`). It was a reasonable
suspect for holding the `zwp_input_method_v2` seat and is **not** the cause —
squeekboard binds it fine. It also **respawns on its own** within a second of
being killed, so anything assuming it stays dead is wrong.

### What T4 should do

Focus-triggered auto-show is **available and proven**, so T4 can rely on it —
but it must **set `screen-keyboard-enabled=true` as part of the image**, exactly
like the rotation and input-source settings. It is off by default.

`SetVisible` over `sm.puri.OSK0` also works and was seen on screen, so explicit
show/hide remains available where a screen needs it.

## R-35b — Steam's own OSK is available in Gaming Mode only

Asked by the operator: can the SteamOS keyboard be used instead?

**Steam is not running in the desktop session at all** — `pgrep steam` is empty
and `steamwebhelper` is 0 — and Steam's on-screen keyboard is rendered *by the
Steam client*, not by anything separable.

| Context | Steam's OSK |
|---|---|
| **Gaming Mode** | ✅ already there, for free — it is Valve's own session, which this project does not build |
| **Desktop Mode** | ⬜ only if Steam is started and kept running in the background. Untested here, and it costs a heavyweight always-on dependency |
| **The installer (live ISO)** | ❌ impossible — Steam is not present, and it is proprietary, so it cannot be carried |

So the installer's text entry (the Wi-Fi passphrase, the whole reason this
matters) can **never** use Valve's keyboard. squeekboard is the answer there and
is now proven to work.

⚠️ If the goal is for our keyboard to *look* like Valve's, that runs into
`docs/findings/P16-redistribution-and-trademark.md`: draw our own, do not copy
Valve's artwork. A comparable layout is fine; a visual imitation is not.

## R-36 — a generated file executed a command at render time

Unrelated to input; found by `shellcheck` while verifying the tree.

`render_restart_helper()` builds its output in an **unquoted** heredoc, so every
backtick in it is live command substitution *as root*. One comment shipped with
unescaped backticks and actually ran `uwsm start ... Hyprland` during a stage
install. The installed file on the Deck proves it:

```
# session's  exit in ~1ms.        <- the command ran; its empty stdout was substituted
```

No damage — the command produced nothing on stdout and the Deck was unaffected —
but a generator silently executing commands is exactly the class of failure this
project exists to avoid, and **it was making CI red**: `shellcheck -x` exits 1,
and the CI step has no `|| true`. `docs/PROGRESS.md` §1's claim that shellcheck
"passes locally" was stale.

Fixed by escaping. **All 15 unquoted heredocs in `deck-session.sh` were then
scanned and this was the only occurrence** — an isolated slip, not systemic. A
regression assertion now checks the literal text survives into the rendered
output, and it asserts on the text rather than on "no double space", which would
pass for any other command whose output happened to be non-empty.

## State on exit

| | |
|---|---|
| Deck | Omarchy desktop, `ssh steamdeck` working, nothing left running from this session |
| `lizard_mode` | restored to **`Y`** (the default) |
| fcitx5 | restored — stopped only for the R-35 experiment |
| squeekboard | stopped; it is not installed as an autostart |
| Mapper | fixed version deployed via `stage-input-mapper`, service **active** |
| Probe scripts/logs | removed from the Deck's `/tmp` |

⚠️ **Still in effect from session 16, and still not reverted:** the display
never sleeps (idle/screensaver/lock disabled, sleep targets masked). This is an
**OLED** panel. Revert with `sudo /usr/local/sbin/deck-always-on-revert.sh`.

## What this session did not cover

The operator scoped this pass to input and the OSK. Untouched, and all still
needing a human: audible sound, headphone jack detect, mic capture, haptics,
gyro response, BT pairing (headphones are available), Gaming Mode's appearance
on screen, and every rotation surface. **Gaming Mode has still never been seen
running by a person** — logind creating a session is not the same claim.
