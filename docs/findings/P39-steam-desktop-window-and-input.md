# P39 — Steam in Desktop Mode: the oversized window, and the dead controller

Two operator defects, both reported as one sentence: *"when i first open steam it
looks really wrong and the mouse doesnt move at all with the trackpad ... the fix
should be incorporated in the final iso"*.

They are unrelated. One is a window rule. The other is the worst class of bug
this project can ship: a controller-only handheld with **no input path at all**
and no on-device way back.

Everything below was measured on the operator's Deck (`192.168.100.25`,
fresh P38 install, Omarchy 4.0, Hyprland 0.56.2, kernel
`6.11.11-valve29-1-neptune-611-g2dcfaf4df7ac`) on 2026-08-16, as the
unprivileged `deck` user. Where something is *not* verified it says so.

---

## Defect 1 — the Steam window is bigger than the screen

### Root cause: Omarchy's own window rule, not Steam

`/usr/share/omarchy/default/hypr/apps/steam.lua`, read off the Deck verbatim:

```lua
o.window("steam", { float = true, idle_inhibit = "fullscreen" })
o.window({ class = "steam", title = "Steam" }, { center = true, size = { 1100, 700 } })
o.window("steam.*", { tag = "-default-opacity", opacity = "1 1" })
o.window({ class = "steam", title = "Friends List" }, { size = { 460, 800 } })
```

Omarchy **forces** 1100x700 and 460x800. Those are desktop-monitor numbers. This
panel is 800x1280 native, `transform = 3`, `scale = 1.25` → a **1024x640 logical
desktop**, of which Waybar reserves the top 26 px, leaving **1024x614 usable**.

1100x700 is wider *and* taller than the entire desktop, so `center = true`
resolves to a negative origin. Measured:

```
class 'steam' title 'Steam'        at [-38, -17] size [1100, 700]
class 'steam' title 'Friends List' at [400,   0] size [ 460, 800]
```

and the arithmetic lands exactly, twice:

* `(1024 - 1100) / 2` = **-38**
* `26 + (614 - 700) / 2` = **-17**

That is why the operator sees a store page with no title bar and no
Store/Library/Community tabs — both are off the top of the screen.

### The competing hypothesis is disproved, by control

It was proposed mid-investigation that *Steam sizes its windows against the
physical 1280x800 surface while Hyprland lays them out on the 1024x640 logical
one*. It is wrong, and 1100x700 looking plausible against 1280x800 is a
coincidence.

**Control:** a `foot` terminal, launched as

```
foot --app-id=steam --title=Steam -- sleep 45
```

— Wayland-native (`xwayland: false`), no relationship to Steam, requesting no
particular size — was measured at:

```
'steam' 'Steam' at [-38, -17] size [1100, 700] floating True xwayland False
```

Byte-identical to real Steam. Steam is not involved in its own geometry here at
all. The window rule is the whole cause.

⚠️ One nuance the control also settles: the third popup, **`Special Offers`**
(measured `at [230, 0] size [564, 664]`), has *no* Omarchy rule. Its 664 px
height is Steam's own request, and it overflows the 614 px usable height on its
own. So Defect 1 is *two* causes after all — a wrong rule for two windows, and
an honestly-too-big request for the third — which is why the fix carries a
catch-all clamp as well as two specific rules.

### Two measured traps in the fix syntax

| form | result |
| --- | --- |
| `size = { 960, 550 }` | works → measured 960x550 |
| `size = { "96%", "86%" }` | **silently ignored** → window kept its own 700x500, identical to the no-rule control |
| `size = { "monitor_w*0.96", "monitor_h*0.86" }` | works → measured **984x550** (= 1024·0.96, 640·0.86) |

* **Percent strings do not work here.** A no-rule control window produced the
  identical geometry, which is how the silence was caught.
* **`hyprctl eval` answers `ok` to the broken form.** It reports its own status,
  never the rule's — as `docs/PROGRESS.md` §5.30c already records. A deliberately
  bogus `size = { "totally-not-a-size", "nope" }` also returned `ok`; only a Lua
  *syntax* error surfaced. The only check that means anything is reading geometry
  back out of `hyprctl -j clients`.
* **`move` may not use `window_w` alongside `size`.** Measured: `move = {
  "(monitor_w-window_w)", ... }` placed a window at x=224 rather than 594,
  because `window_w` resolved to the 800 px the window *asked* for, not the
  430 px the `size` rule had just given it.

### The fix

Expressions over `monitor_w`/`monitor_h`, so the rules follow the panel instead
of restating it, plus an anchored catch-all clamp:

```lua
o.window("^steam$", { max_size = { "monitor_w", "monitor_h*0.95" } })

o.window({ class = "steam", title = "Steam" }, {
  center = true,
  size = { "monitor_w*0.97", "monitor_h*0.90" },
})

o.window({ class = "steam", title = "Friends List" }, {
  size = { "monitor_w*0.42", "monitor_h*0.85" },
  move = { "monitor_w*0.56", "monitor_h*0.06" },
})
```

`^steam$` is anchored deliberately: unanchored `steam` also matches
`steam_app_*` (a game running under Proton in Desktop Mode) and
`steamwebhelper`, and clamping a game is not this rule's business.

The catch-all is the part least likely to rot when Steam updates itself — it
names no title and no pixel count, and it is what covers `Special Offers` and
any window a future Steam invents.

**Why an override and not a patch to upstream's `steam.lua`:** Omarchy's own
`hyprland.lua` says the user files *"are loaded after Omarchy's defaults so
package updates can improve the defaults without rewriting your ~/.config/hypr
files"*. A later window rule wins for the same property. An override therefore
survives upstream editing `steam.lua`; a context diff in
`src/omarchy-deck-patches/` would not.

### Verified on hardware, from the shipped config alone

After splicing the **repo-rendered** block into `~/.config/hypr/monitors.lua`
and `hyprctl reload` — no `hyprctl eval` rules involved:

```
=== GEOMETRY FROM THE SHIPPED monitors.lua BLOCK ===
Friends List     at [ 573,  38] size [ 431x 544] right=1004 bottom= 582 ON-SCREEN=True
Special Offers   at [ 230,  29] size [ 564x 608] right= 794 bottom= 637 ON-SCREEN=True
Steam            at [  15,  45] size [ 994x 576] right=1009 bottom= 621 ON-SCREEN=True
```

`Special Offers` asked for 564x**664** and was clamped to 608 by the catch-all.
All three are fully on screen.

Sentinel asserted, with its negative control:

```
--- sentinel ---
ok
--- negative control (must fail) ---
error: [string "if DECK_NO_SUCH == nil then error("expected-f..."]:1: expected-failure
  exit=7 good
```

### Should the Friends List open at all?

**Recommendation: no, leave it opening — fix the geometry, not the behaviour.**

Suppressing it means writing Steam's own `localconfig.vdf`, which lives at
`~/.local/share/Steam/userdata/<steamID3>/config/localconfig.vdf`. That path
does not exist until the user has logged in with an account the installer cannot
know, so there is nothing for an install stage to seed; and Steam rewrites the
file on exit, so a seeded value is not durable. It is the wrong layer. Sized to
a right-hand column it is a reasonable friends panel on a 1024x640 desktop.

### ISO delivery path — Defect 1

Landed in
`iso/overlay/configs/airootfs/usr/share/omarchy-iso/orchestrator/deck_monitors.py`,
as a new `render_steam_window_rules()` emitted from the existing
`render_block()`.

That module is already registered as
`DeckStep("desktop_rotation", deck_monitors.desktop_rotation_step, critical=False)`
in `deck_configure.deck_steps()`, and already writes **both** surfaces —
`/etc/skel/.config/hypr/monitors.lua` *and* the created user's
`~/.config/hypr/monitors.lua` — through `install()`, with the marker splice,
`luac` syntax gate, outside-the-block preservation assertion and sentinel it
already has. **No new machinery, no new step, no new test harness.**

Why `monitors.lua` rather than a module of its own: these rules exist *because*
`scale = 1.25` makes this panel a 1024x640 desktop. Keeping them in the same
block as the `scale` line means the next person who "simplifies" the scale sees
the consequence in the same screenful.

`test/unit/test-deck-monitors.py`: **146/146 checks pass** with the change.
`render_block()` was rendered and `luac -p`'d with a positive control asserting
the window rules were actually present (an earlier run of that check produced an
empty render and a vacuous pass — recorded here because it is exactly the
failure mode this repo keeps hitting).

---

## Defect 2 — 🔴 opening Steam in Desktop Mode can leave the Deck with NO input

This is not "the trackpad stops working". Under the shipped configuration it is
a **total loss of controller input on a device with no keyboard**, from which
there is no on-device recovery short of a forced power-off.

### The facts, both states measured in one session

**State A — Steam not running** (mapper active, `lizard_mode=N`):

```
N: Name="Valve Software Steam Controller"      input7  -> event5 mouse0   EV=17 (SYN|KEY|REL)
N: Name="Valve Software Steam Controller"      input8  -> event6 kbd
N: Name="Steam Deck"                           input9  -> event7 js0      <- NATIVE PAD
N: Name="Steam Deck Motion Sensors"            input10
N: Name="deck-input-mapper virtual keyboard"
/sys/bus/hid/devices/0003:28DE:1205.0003/input   EXISTS
```

**State B — Steam running** (pid 31231):

```
N: Name="Valve Software Steam Controller"      input7  -> event5 mouse0
N: Name="Valve Software Steam Controller"      input8  -> event6 kbd
N: Name="Microsoft X-Box 360 pad 0"            input31 -> event7 js0
      Bus=0003 Vendor=28de Product=11ff, Sysfs=/devices/virtual/input/input31
      B: ABS=3003f   (X,Y,Z,RX,RY,RZ,HAT0X,HAT0Y — the xpad layout)
      B: FF=10000
"Steam Deck"                ABSENT
"Steam Deck Motion Sensors" ABSENT
/sys/bus/hid/devices/0003:28DE:1205.0003/input   No such file or directory
```

and the ownership scan across every `/proc/*/fd`:

```
24822 Hyprland -> /dev/input/event5
24822 Hyprland -> /dev/input/event6
31231 steam    -> /dev/hidraw2
```

### The native pad is DESTROYED, not grabbed

Steam holds **no `/dev/input/event*` descriptor at all** — its only relevant fd
is `/dev/hidraw2`. `hidraw2` maps to `0003:28DE:1205.0004`, the *client* HID
child that `hid-steam` creates on interface 2 precisely so userspace can talk to
the controller. When Steam opens it, `hid-steam` unregisters its own input
devices — which is why `.0003/input` exists in State A and does not exist in
State B.

This is upstream kernel behaviour, by design, and there is nothing to configure
away from userspace.

**Two consequences that kill the obvious fixes:**

1. **Teaching the mapper to accept `Microsoft X-Box 360 pad 0` would not restore
   the trackpads.** Its `ABS=3003f` bitmap has sticks, triggers and a hat and
   **no trackpad axes**. The Deck's trackpads are `ABS_HAT0X/Y` (left) and
   `ABS_HAT1X/Y` (right) on the *native* node only. Prior measurement (R-41,
   `docs/findings/P17-input-and-osk.md`) goes further: with Steam resident,
   `event5`, `event6` and the X360 pad were all present and **none emitting**.
2. **While Steam is resident, the only node that can carry trackpad motion is
   `event5`, and only with `lizard_mode=Y`** — where the firmware drives the
   trackpads as a merged relative mouse. Hyprland already holds `event5` open,
   so that pointer works the moment the firmware emits.

### The bricking bug: ordering, and an unbounded wait

`/etc/systemd/user/deck-input-mapper.service.d/50-deck-lizard-mode.conf`:

```
ExecStartPost=/usr/bin/sudo -n /usr/local/sbin/deck-lizard-mode off
ExecStopPost=/usr/bin/sudo -n /usr/local/sbin/deck-lizard-mode on
```

`ExecStartPost=` for `Type=simple` runs as soon as the mapper is **forked** —
unconditionally, before it holds any device. The drop-in's own comment
acknowledges this and calls the window *"short ... one process start"*.

**That comment is wrong, and its wrongness is the defect.** The window is not
one process start; it is **unbounded**. `pick_device()` in
`src/deck-input-mapper.py` does not exit when Steam owns the pad — deliberately,
and for good reason (exiting would burn `StartLimitBurst=5` in ~10 s and leave
the mapper permanently dead). It loops every `STEAM_RESCAN_INTERVAL = 5.0`
seconds, forever, and its own comment says *"this can last for hours"*. So
lizard mode is off, the mapper drives nothing, and the state is stable.

Observed on hardware:

```
deck-input-mapper: Steam owns the controller (Microsoft X-Box 360 pad 0); waiting for the native pad, rescanning every 5s
```

with `lizard_mode = N` and the operator reporting the buttons dead.

**Two triggering paths, and the second is the common one:**

* **(a)** the mapper starts or restarts while Steam already holds the pad —
  a login where Steam autostarts, any `Restart=on-failure` cycle, a
  hand-restart. This is the path reproduced during this session.
* **(b) 🔴 the mapper is running normally (`lizard_mode=N`) and the user simply
  opens Steam.** The kernel destroys the native pad, the mapper's descriptor
  dies, it re-enters the same wait loop — and lizard mode is *still* `N`.
  **No unit state transition happens at all**, so neither `ExecStopPost=` nor
  `OnFailure=` can fire. Path (b) needs no restart, no crash and no unusual
  timing. It is just "open Steam on the desktop", and it is the path that will
  reach users.

### Why `deck-lizard-restore.service` misses it

It is wired as `OnFailure=`. systemd triggers `OnFailure=` when a unit enters
`failed`. In both paths above the mapper is `active (running)` with a healthy
main process — it is polling, not failing. There is no failure to catch.

The net watches **process liveness**. The invariant that actually matters is
**device ownership**: *lizard mode may be off only while something is driving
the pad.* Nothing in the shipped system evaluates that invariant. This is
`docs/PROGRESS.md`'s own rule one level up — the net proves the mapper did not
crash; it never proves the mapper is driving anything.

### What a user with no keyboard does today

**Nothing. There is no on-device recovery.** With `lizard_mode=N` and the native
pad destroyed: no pointer (no node carries trackpad motion), no buttons reaching
the desktop, STEAM/QAM read by nobody, so no menu, no launcher, no terminal, and
no TTY switch (that needs a keyboard).

The only on-device control left is the **power button**: a ~10 s hold forces the
machine off. A reboot does recover, because `lizard_mode` is a module parameter
that resets to `Y` and does not persist (§5.21) — but only until the user opens
Steam on the desktop again, which reproduces it immediately. Off-device recovery
is SSH, which is not a shipping answer for a handheld.

**After the fix:** opening Steam in Desktop Mode leaves the **firmware** driving
the trackpads as a mouse. That is degraded — with lizard on, the firmware
swallows X, Y, L1, R1, STEAM and QAM entirely (§5.21), so our chords and the OSK
are unavailable while Steam is up — but it is a device a human can drive, and
the pointer moves, which is exactly what the operator asked for.

### The fix — one principle, three owners

> **Bind lizard mode's OFF state to "the mapper currently holds a native pad",
> not to "the mapper process exists".**

#### Part 1 — the mapper (SPEC ONLY — owned by another agent, not implemented here)

*File:* `src/deck-input-mapper.py`. **I did not edit it.**

1. **Move the disarm out of the unit and into the code, after the bind.**
   Remove `ExecStartPost=` (Part 2) and have the mapper invoke
   `sudo -n /usr/local/sbin/deck-lizard-mode off` **only once `pick_device()`
   has returned a real native pad** and the device is open — i.e. immediately
   before it emits `BOUND_MARKER`. Ordering is the entire fix: the fallback must
   not be disarmed until the replacement is holding the device.

2. **Re-arm whenever the pad is lost or not yet held.** In `pick_device()`, on
   entering the "Steam owns the controller" branch — and on the no-pad grace
   branch — call `deck-lizard-mode on` **before** the first `time.sleep()`. It
   must be idempotent and must not be limited to the first iteration: the
   announce-once flag (`announced_wait`) governs *logging*, not the re-arm. This
   is what closes path (b), and it is the single most important line in the
   spec.

3. **Re-arm on every exit path**, including the one where the read loop drops
   out because the device vanished mid-session, before re-entering
   `pick_device()`.

4. **Do not accept `Microsoft X-Box 360 pad 0`.** `is_steam_virtual_pad()` /
   `looks_like_gamepad()` should keep rejecting it. The measurements above show
   it carries no trackpad axes and (R-41) emits nothing to the desktop; binding
   to it would replace "no input" with "no input, and the fallback disarmed
   because we think we are bound". **The current rejection is correct — the bug
   is never that the mapper refuses the impostor, it is that the fallback was
   turned off before the refusal.**

5. **What could regress:** `deck-lizard-mode` is behind `sudo -n` with a
   NOPASSWD grant for exactly `on` and `off`; a call from inside the mapper adds
   a subprocess spawn on a hot-ish path, so it must be non-blocking-ish and must
   never raise into the read loop. Also, `src/deck-form.sh` waits ≤5 s for
   `BOUND_MARKER`; adding a subprocess before that marker eats into its budget —
   emit the marker first *or* keep the disarm well under the budget, and check
   `test/unit/test-deck-input-mapper.py`'s marker timing assertions.

6. **How to test:** unit-level, inject a fake lizard-mode invoker and assert the
   call sequence for three scripted device timelines — (i) native pad present at
   start → exactly one `off`, no `on`; (ii) X360 pad present at start → `on`
   before the first sleep, never `off`; (iii) native pad present, then replaced
   by the X360 pad mid-run → `off` then `on`, in that order. Assert the
   *negative* too (no stray `off` in timeline ii), and assert the fake was
   actually called at all, so an invoker that is never wired up fails the suite
   instead of passing it silently.

#### Part 2 — the helper and the unit (`src/deck-session.sh`) — DESIGNED, NOT LANDED

* Make `deck-lizard-mode off` **refuse** unless a native `Steam Deck` pad evdev
  node exists (scan `/proc/bus/input/devices`, or
  `/sys/bus/hid/devices/0003:28DE:1205.0003/input`). `off` is only ever safe
  when something can take over, and only the native node makes that possible.
  This is a hard interlock: it makes "disarmed fallback, nobody driving"
  unreachable no matter who calls the helper or in what order.
* Prefix the drop-in's `ExecStartPost=` with `-` **only if** it is kept at all,
  so a refusal degrades to "lizard stays on" instead of failing the unit into a
  restart loop. Once Part 1 lands, the line should be **deleted** rather than
  tolerated.
* **Failure mode of this choice:** if the node-detection is ever wrong (upstream
  renames the node), `off` refuses permanently and the mapper is degraded to
  lizard mode forever — the device still works, our chords and OSK do not. That
  is the correct direction to fail, and it is loud in the journal.

#### Part 3 — a net wired to the invariant, not to liveness

`deck-lizard-restore.service` should keep its `OnFailure=` role, and a second,
event-driven net should be added: a **udev rule** on the native pad's `remove`
uevent (`ACTION=="remove", SUBSYSTEM=="input"`, matched on the `Steam Deck`
node) that runs `deck-lizard-mode on`. udev runs as root, so no sudo grant is
needed, and `remove` is exactly the kernel event that path (b) generates. It can
only ever move lizard mode toward the safe value, so it cannot cost input; the
worst it can do is re-arm the firmware while the mapper still wants it off, and
Part 1's disarm-after-bind then puts it back.

### ISO delivery path — Defect 2

**Honest answer: none of Defect 2 ships yet.** Parts 1–3 are diagnosis and
design, not landed code.

* Part 1 is `src/deck-input-mapper.py`, owned by another agent this session.
* Parts 2 and 3 belong to `src/deck-session.sh` — `stage-lizard-mode` renders
  the helper and the drop-in, and `stage-input-mapper` the unit; a udev rule
  would be a new artifact rendered by the same stage and installed under
  `/etc/udev/rules.d/`. I did not write them because they cannot be verified on
  this Deck: `sudo` requires a password I do not have, so `/usr/local/sbin`,
  `/etc/systemd/user` and `/etc/udev/rules.d` are all unwritable, and this
  project's standard is not to ship input-path changes that have never run.

**Nothing in Defect 2 is fixed on the operator's Deck right now.** Opening Steam
in Desktop Mode with the mapper running still reproduces it.

---

## Live-Deck state left behind

* `~/.config/hypr/monitors.lua` carries the new block (backup at
  `monitors.lua.deck-bak`). Steam's windows now fit. This is a real fix, left in
  place deliberately.
* `~/.config/hypr/hyprland.lua` was used for an intermediate experiment and has
  been **restored to its original content**; its temporary block is gone
  (verified: 0 occurrences) and the backup removed.
* `lizard_mode` and `deck-input-mapper.service` were **not** touched by this
  investigation. State when last read: mapper `active`, `lizard_mode=N`, Steam
  not running, native pad present — i.e. healthy, and *not* the
  "mapper stopped, lizard=Y" state reported mid-session; something restarted it
  between then and now.

## Not verified

* **Whether `lizard_mode=Y` actually restores the firmware mouse while Steam is
  still resident.** This is the load-bearing assumption under Parts 1–3: Steam
  holds `/dev/hidraw2` and is known to disable lizard mode itself, so the
  firmware could re-disable it. It was not tested here because testing it means
  launching Steam on the operator's Deck while they are using it. **The
  experiment:** with Steam open and `lizard_mode=N`, run
  `sudo -n /usr/local/sbin/deck-lizard-mode on` and confirm the trackpad moves
  the pointer, then confirm it *stays* working for ≥60 s (Steam may re-disable
  it on its own heartbeat). If it fails, Parts 1–3 still prevent nothing worse
  than today, but the actual pointer answer becomes **extest** (below).
* **extest.** `docs/findings/T10-steam-extest-results.md` measured Steam's own
  XTEST output reaching the Wayland pointer through extest's XTEST→uinput
  bridge — *"right trackpad moved the desktop pointer (PASS)"* — with both
  `libextest-i686.so` and `libextest-x86_64.so` preloaded. It is **not installed
  on this Deck**: `pacman -Q extest` → not found, no `/usr/lib/libextest*`, and
  Steam's `/proc/31231/environ` carries **no `LD_PRELOAD`**. `tools/build-extest.sh`
  exists and is pinned and licence-gated, but nothing in `deck-session.sh` or the
  orchestrator installs the result. Session 26's decision to *"forego the Steam
  keyboard"* is about the keyboard; whether it was also meant to drop the
  **pointer** path is worth re-asking, because extest is the only measured way to
  get trackpad-driven pointer motion while Steam is resident.
