# Session 17 — the input path, seen on a screen for the first time (R-29…R-42)

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

## R-35b — Valve's OSK DOES work in Desktop Mode, via STEAM+X. Tested.

Asked by the operator: can the SteamOS keyboard be used instead? Tested on
hardware rather than reasoned about, and the answer is yes — with a real cost.

**Steam runs fine in the Omarchy desktop session.** It came up on Hyprland
through XWayland: 10 `steamwebhelper` processes and three windows (`Steam`,
`Special Offers`, `Friends List`). With Steam up, **STEAM+X summoned Valve's own
on-screen keyboard — seen on screen.**

⚠️ **It is summon-only, not focus-triggered.** The operator's words: *"it showed
up when i pressed steam+x (not before then)"*. Tapping a text field does
nothing. That is the opposite of squeekboard's behaviour and changes which one
suits which screen.

| Context | Valve's OSK | squeekboard |
|---|---|---|
| **Gaming Mode** | ✅ native and free — Valve's own session | n/a |
| **Desktop Mode** | ✅ **works, STEAM+X, requires Steam running** | ✅ auto-shows on focus |
| **The installer (live ISO)** | ❌ **impossible** — no Steam, and it is proprietary so it cannot be carried | ✅ the only option |

So the installer's text entry — the Wi-Fi passphrase, the reason any of this
matters — can **never** use Valve's keyboard.

**Two startup traps, both of which cost time here:**

- **Steam needs `DISPLAY`, not just `WAYLAND_DISPLAY`.** The client is X11-only
  and runs under XWayland (`Xwayland :0`, and the session does set `DISPLAY=:0`).
  Launching it with only the Wayland variables exported produces **zenity error
  dialogs titled "Unable to open a connection to X"** and no Steam.
- **Steam takes over a minute to show a window**, and its `-silent` form shows
  none at all. A 25 s timeout looks exactly like a failure while the bootstrap
  is running normally — check `~/.steam/steam/logs/bootstrap_log.txt` before
  concluding anything.

⚠️ **Unrelated landmine noticed while reading Valve's launcher.**
`/usr/bin/steam-jupiter` (owned by `steam-jupiter-stable`, **not** this project)
contains `rm -rf --one-file-system "$STEAM_DIR" "$STEAM_LINKS"`, guarded by a
`# OOBE Inhibit` marker in `~/.local/share/Steam/Steam.cfg`. That file does not
exist on this Deck, so the branch is unreachable and the signed-in state was
verified intact. **Anything that creates that Steam.cfg wipes Steam's install**,
including the login this project spent a session establishing.

⚠️ If the goal is for our keyboard to *look* like Valve's, that runs into
`docs/findings/P16-redistribution-and-trademark.md`: draw our own, do not copy
Valve's artwork. A comparable layout is fine; a visual imitation is not.

## R-37 — running Steam on the desktop takes the controller, and the mapper follows it

The cost of R-35b's answer, measured immediately after. With Steam running in
the **desktop** session:

- The native `Steam Deck` and `Steam Deck Motion Sensors` nodes **disappear**,
  replaced by `Microsoft X-Box 360 pad 0` — the same hidraw takeover
  `docs/findings/hardware-parity.md` recorded for Gaming Mode, now confirmed to
  happen on the desktop too.
- **`deck-input-mapper` re-bound itself to Steam's virtual pad.** Its device
  vanished, the service restarted, and it now logs
  `reading /dev/input/event7 (Microsoft X-Box 360 pad 0)`. Selecting by
  `BTN_SOUTH` capability makes the virtual pad an equally valid match.

So with Steam running on the desktop, **Steam processes the controller for its
own UI while our mapper injects `KEY_ENTER`/`ESC`/`TAB`/`SPACE` on top of it** —
double input, from one press.

**This makes the Desktop Mode keyboard a real either/or**, not a free upgrade:

| | Steam running on the desktop | No Steam on the desktop |
|---|---|---|
| Keyboard | Valve's, via STEAM+X (summon-only) | squeekboard, auto on focus |
| Controller | Steam owns it; the mapper **should be disabled** | lizard mode; the mapper is a no-op unless `lizard_mode=N` |
| Cost | a permanently running Steam client | none |

**Open decision for T3/T4** — the mapper needs a policy for "Steam is running":
either refuse to bind a device named like Steam's virtual pad, or have the unit
stop when Steam is up. Binding it is almost certainly wrong, and nothing
currently prevents it.

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

## R-38 — Gaming Mode confirmed usable by a human, and the idle lock is a hole in §2.6

**Gaming Mode: the operator looked at it and confirmed it works** (session 17).
That closes P16 §5's standing caveat that *"the gamescope session was never
verified as usable — only that logind created an active user session."* It is an
eyeball confirmation, not a parity matrix: the ⏸ rows in
`docs/findings/hardware-parity.md` (audible sound, haptics, gyro, mic, BT
pairing) are still unverified in **both** sessions.

### The idle lock defeats §2.6's keyboard plan

Found because reverting session 16's display-always-on re-armed the idle cycle,
and the operator immediately saw squeekboard appear over the screensaver. That
part was **this session's own leftover** — a squeekboard started for the R-35
test and missed by cleanup — but chasing it exposed a real design hole.

Omarchy's idle service (`plugins/services/idle/Service.qml`) ships
**screensaver at 150 s and lock at 300 s**, and the lock is a quickshell
`TextField` password prompt. Autologin (`Relogin=true`) covers boot and session
switches; it does **not** cover the idle lock.

Under §2.6 the installed system carries no squeekboard, so Desktop Mode's only
keyboard is Steam's, via STEAM+X. **Steam's OSK is an XWayland window and the
lock is a Wayland layer-shell surface holding an exclusive input grab, so it
almost certainly cannot render above the lock** — meaning 5 minutes of idle
would lock a keyboard-less handheld out of itself, recoverable only by SSH or a
USB keyboard.

⚠️ **That inference is NOT measured.** Testing it means deliberately locking the
device and trying STEAM+X. It was not run, because the operator chose to remove
the lock instead, which makes the question moot rather than answered. Do not
record it as fact.

**Resolution (operator decision):** disable the idle **lock**, keep the
**screensaver**. Burn-in protection is unchanged and the device never demands a
password it has no way to accept — which is also stock behaviour, since neither
SteamOS session auto-locks a personal handheld.

### ⚠️ `lock: 0` does NOT disable it — it locks INSTANTLY

There is no "off" sentinel. `IdleModel.secondsFromConfig` returns the fallback
only for negative or non-finite values, so `0` is accepted, and then:

```qml
firstIdleTimeoutSeconds: Math.min(screensaverTimeoutSeconds, lockTimeoutSeconds)  // 0
lockDelaySeconds:        Math.max(0, lockTimeoutSeconds - firstIdleTimeoutSeconds) // 0
...
if (root.lockDelaySeconds === 0) lockSystem("lock-timeout-immediate")   // fires at once
```

So the mechanism is a **large timeout**, set in `~/.config/omarchy/shell.json`:

```json
"idle": { "screensaver": 150, "lock": 86400 }
```

⚠️ **And there is a ceiling.** `lockDelaySeconds * 1000` feeds a QML
`Timer.interval`, which is a 32-bit int, so a delay beyond ~2,147,483 s
(~24.8 days) overflows. Do not "disable" this with 999999999 — 86400 is a day,
which is effectively never for a handheld and is nowhere near the bound.

The shell picks the change up live: `shell.qml` reads the user config through a
`FileView` with `watchChanges: true`, so no restart is needed. **Confirmed by
watching two consecutive idle cycles rather than trusting the property:**

```
19:38:27  idle-cycle-start: screensaver=150 lock=300      # before
19:42:19  idle-cycle-start: screensaver=150 lock=86400    # after, no restart
```

**T5 owes the image this setting**, and it is not a GSettings — it is
`~/.config/omarchy/shell.json`, a per-user dotfile, so it has the same
"absent from a built image" problem as the rotation.

## R-39 — the SteamOS Desktop Mode model, validated end to end

**Operator direction:** *"steam is launched immediately when entering desktop
mode in steam os … it keeps operating in the bg even when you close the window.
we should do the exact same."* Tested rather than assumed, and it works.

| Claim | Result |
|---|---|
| Steam runs in the Omarchy desktop | ✅ via XWayland — 11 processes, three windows |
| A tray host exists to minimise into | ✅ quickshell provides **both** `org.kde.StatusNotifierWatcher` and a `StatusNotifierHost` |
| Steam registers a tray item | ✅ `:1.xxxx/org/ayatana/NotificationItem/steam` |
| Closing the window keeps Steam alive | ✅ window closed, **all processes survived**, tray item still registered |
| `steam -silent` gives a windowless, resident Steam | ✅ **11 processes, 0 windows**, tray item registered |
| STEAM+X summons the keyboard with no window ever shown | ✅ **confirmed on screen** |

**So the shipping form of §2.6's requirement 1 is `steam -silent`** in
`~/.config/autostart/`. It is the closest match to SteamOS: Steam resident from
the moment Desktop Mode starts, nothing on screen, keyboard one chord away.

⚠️ **The tray host is load-bearing and easy to lose.** On Linux, Steam only
minimises to tray when a StatusNotifier host accepts its item; without one,
closing the window **quits Steam** and takes the keyboard with it. Omarchy's bar
supplies it via the `omarchy.tray` widget in `shell.json`. **A bar layout that
drops `omarchy.tray` silently removes Desktop Mode's keyboard.** Worth a
conformance check.

⚠️ **The STEAM button alone opens Big Picture Mode**, so a mis-timed STEAM+X
gets Big Picture instead of the keyboard; exiting it returns to the main Steam
window, which reads as "the window I closed came back". This is stock Deck
behaviour, not something this project introduced — recorded because it looks
like a bug.

Also confirmed: Steam knows the hardware (`"IsSteamDeck_01" "1"` in
`config.vdf`).

## R-40 — the mapper's Steam-wait had a second door, found by running it

R-37's fix worked in the exact case it was written for: with Steam owning the
pad the service sat `active`, logging *"Steam owns the controller … waiting for
the native pad"*. But `NRestarts=4`.

**Steam's takeover has a window where NO pad exists at all** — the native node
is already gone and the virtual pad has not appeared. That hit the deliberately
loud "no gamepad at all" branch, and a single Steam start/stop cycle burned
**4 of the unit's 5 `StartLimitBurst` restarts**. One more and the mapper would
have been permanently dead — precisely the outcome the wait was written to
prevent, reached through a different door.

Fixed with a **bounded** grace window (`NO_PAD_GRACE_SECONDS = 30`): the
enumeration gap is absorbed, a pad that never arrives still exits loudly, and
the window re-arms rather than carrying a spent allowance into a later gap.
Verified against a fake clock — exits only after the grace, returns the pad the
moment it enumerates, never exits while Steam holds the controller — and on
hardware, where the counter now stays at **`NRestarts=0`**.

**The lesson is the one this session keeps repeating**: the fix was correct
about the case it modelled and wrong about the system. Only running it under a
real Steam start/stop showed the second path.

## R-41 — 🐞 A RESIDENT STEAM LEAVES THE DESKTOP WITH NO INPUT AT ALL

**Found by the operator being unable to dismiss the screensaver.** This is the
most serious defect this session found — a *lockout*, not a missing feature —
and it blocks §2.6's Desktop Mode half.

### ⚠️ This finding was first written with the WRONG mechanism

The first version claimed Steam *removes* lizard mode's mouse and keyboard
nodes. **It does not.** That came from misreading a device list filtered by
`grep`, and it would have sent a future session looking for missing nodes — and
worse, would have made "the nodes are present" look like a healthy check.

**What is actually true**, measured by listening on every relevant node while
the operator used the controller:

| Node | Present with Steam resident? | Emits? |
|---|---|---|
| `Valve Software Steam Controller` (mouse, `event5`) | **yes** | **NO** |
| `Valve Software Steam Controller` (kbd, `event6`) | **yes** | **NO** |
| `Microsoft X-Box 360 pad 0` (Steam's virtual pad, `event7`) | **yes** | **NO** |
| `Steam Deck` (native gamepad) | no — Steam replaced it | — |

**Every node is enumerated, Hyprland holds `event5`/`event6` open, and not one
of them produced a single event** across a trackpad swipe, an A press and a
STEAM press. The STEAM press *opened Steam*, proving the input reached Steam —
over **hidraw**, invisible to evdev, exactly as R-29 found for that button.

So Steam consumes the controller wholesale and routes it only into its own UI.
The desktop receives **nothing**: no pointer, no keys, no gamepad. Our mapper is
correctly inert (R-37), and would have nothing to read even if it were not.

This is the third appearance of R-31's pattern in one session, and the most
expensive: **presence proved nothing, three times over.** `lsof` showing
Hyprland with the nodes open is equally worthless — it reads them faithfully and
they say nothing.

### Why the operator got stuck

The screensaver appeared at 150 s and no input existed that could dismiss it.
Recovered over SSH: kill `foot --app-id=org.omarchy.screensaver`, then
`steam -shutdown`, after which every node resumed emitting immediately.

⚠️ **The screensaver is the symptom, not the cause.** Without it the desktop was
equally unusable — nothing could move a cursor or click. Raising or disabling
the screensaver timeout would hide this, not fix it. Disabling the idle lock
(R-38) removed the *password* trap and does nothing for this one.

### What it means for §2.6

Requirement 1 — "Steam autostarts with `-silent`" — is **unsafe as written**.
R-39's checks were all true and all insufficient: Steam resident ✅, tray item
✅, survives window close ✅, STEAM+X summons the keyboard ✅ — **every one
passing while the device was uncontrollable.**

On stock SteamOS this works because Steam Input applies a **Desktop layout**,
synthesising mouse and keyboard from the trackpads and buttons. Ours never did.
**Why is the open question**, and it is the next thing to establish:

1. The desktop layout may need a one-time assignment through Steam's UI, so it
   never activated on a Steam that has never been foregrounded.
2. It may require Steam to run non-`-silent` at least once.
3. It may depend on SteamOS-specific integration this project does not have.

Until one of those is settled, Desktop Mode needs a non-Steam input path, which
reopens §2.6's choice.

⚠️ **Never treat "STEAM+X shows the keyboard" as evidence the desktop is
usable.** It was true here while nothing could move a cursor.

## R-42 — R-41 RESOLVED: Steam cannot drive a Wayland desktop. §2.6's Desktop half is dead.

Investigated with the operator on hardware. **This is not a missing setting.**

### What was tested

| Step | Result |
|---|---|
| Steam started **foregrounded** (not `-silent`), fully loaded, window on screen | ✅ |
| Trackpad moves the desktop cursor? | ❌ **no** |
| Controller navigates Steam's **own desktop window**? | ❌ **no** |
| Steam's **Desktop Layout** exists in Settings → Controller? | ✅ yes, with Edit + gear |
| Any "enable/apply" toggle on it? | ❌ none — only *Reset to default* and *Cancel* |
| **Reset controller layout to default**, then re-check | ❌ **no change** |
| Steam holds `/dev/uinput`? | ✅ yes (pid, fd 150) |
| Virtual **mouse or keyboard** device created? | ❌ **never** — only `Microsoft X-Box 360 pad 0` |
| `libXtst.so.6.1.0` mapped into Steam? | ✅ **yes** |

### The mechanism

Steam uses **uinput for the virtual gamepad only**, and drives desktop mouse and
keyboard through **XTEST** — the X11 fake-input extension, whose client library
is mapped into the process. Under XWayland, XTEST cannot move a Wayland
compositor's pointer or reach Wayland-native clients, so the Desktop layout
produces nothing a Hyprland session can see.

That single mechanism explains every observation, including the one that looked
strangest: **Steam's own window is unnavigable**, because its X11 surface is
composited by Hyprland, which owns the pointer. Big Picture responds only
because it reads the controller directly rather than through the desktop layout.

⚠️ **Honest limit:** `libXtst` being mapped proves Steam *links* XTEST, not that
the desktop layout uses it exclusively. The behaviour is measured; the mechanism
is a strong inference. It does not change the conclusion — what matters is that
**no configuration made desktop input appear**.

### Consequence: §2.6's Desktop Mode half is not implementable here

"Steam autostarts and provides the keyboard in Desktop Mode" **cannot work on
Hyprland**, at any configuration. It is not blocked pending a setting; the
mechanism is absent. Worse than merely not helping, a resident Steam **takes the
controller away** (R-41), so adopting it costs the desktop its pointer.

**What works, and always did:**

| | Desktop Mode |
|---|---|
| Pointer + keys | **lizard mode** — trackpad→mouse, buttons→Enter/Esc/Tab/arrows, free and automatic |
| Text entry | **squeekboard**, auto-showing on focus (§5.20), installed by `stage-desktop-settings` |
| Steam | **not resident.** Launch it when wanted; quit it when done |

Gaming Mode is unaffected — Valve's session brings its own keyboard, and this
project does not build it.

### Two findings worth keeping independently

- **Steam's desktop window is not controller-navigable at all**, on any
  platform — only Big Picture is. A controller-only user cannot configure Steam
  from the desktop, which is worth knowing before designing any flow that
  expects them to.
- **A resident Steam is actively harmful to Desktop Mode here**, not neutral. It
  removes the only working input path and returns nothing usable.

## State on exit

| | |
|---|---|
| Deck | Omarchy desktop, `ssh steamdeck` working, nothing left running from this session |
| `lizard_mode` | restored to **`Y`** (the default) |
| fcitx5 | restored — stopped only for the R-35 experiment |
| squeekboard | stopped; it is not installed as an autostart |
| Mapper | fixed version deployed via `stage-input-mapper`, service **active** |
| Probe scripts/logs | removed from the Deck's `/tmp` |
| Steam | started for the R-35b test, then **shut down** — the state it was found in. Input devices verified back to native `Steam Deck` and the mapper re-bound to it |
| `screen-keyboard-enabled` | left **`true`** deliberately — it is a product requirement, not scaffolding |

✅ **Session 16's display-always-on is REVERTED** (operator instruction, end of
session 17). Verified: sleep/suspend/hibernate/hybrid-sleep targets back to
`static`, the logind drop-in removed, the `stay-awake` state file gone, and the
three remaining inhibitors are all `delay` mode (NetworkManager, UPower,
Omarchy's lock-before-suspend) rather than blocking. Omarchy 4.0's idle lives in
quickshell (`/usr/share/omarchy/shell/plugins/services/idle/Service.qml`), which
is running — there is no `hypridle`/`swayidle` on this system, so do not go
looking for one.

⚠️ **Two GSettings values were left SET deliberately**, because they are product
requirements rather than test scaffolding: `screen-keyboard-enabled=true` (R-35)
and `input-sources=[('xkb','us')]`. `docs/START-HERE.md` previously told the next
session to revert the second one, which would have silently broken the OSK
again. Both are now T5 constraints.

## What this session did not cover

The operator scoped this pass to input and the OSK. Untouched, and all still
needing a human: audible sound, headphone jack detect, mic capture, haptics,
gyro response, BT pairing (headphones are available), Gaming Mode's appearance
on screen, and every rotation surface. **Gaming Mode has still never been seen
running by a person** — logind creating a session is not the same claim.
