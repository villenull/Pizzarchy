# FINDING R1 §10.3 — Should the gamepad→input mapping layer ship permanently?

**Result: RESOLVED — ship design (b), the custom mapper as a systemd user
service.** Decided 2026-08-09 on the operator's physical Steam Deck OLED
(`Valve` / `Galileo`, Omarchy 3.8.4, Hyprland 0.56.0 under `uwsm` 0.26.6),
in the same session as the first hardware run of `omarchy-deck-kernel.sh`.

This file previously held two prepared-but-undecided designs. It is now the
decision plus the hardware evidence behind it. The design descriptions are
kept because the corrections to them are the useful part.

## The decision

**Design (b)** — the T2 `uinput`/`evdev` mapper as a systemd `--user`
service scoped to the desktop session. Every precondition the earlier draft
flagged as unverified has now been tested on hardware and works.

**Design (a)** — backgrounding Steam and inheriting Steam Input's desktop
layout — is **ruled out**, and not on a close call.

## Why design (a) is out

**It cannot serve the first-boot path, which is the path that matters most.**
This is a circular dependency between three already-confirmed project facts,
not a new test result:

- Design (a) sources both controller-as-mouse and the on-screen keyboard
  from a running, **signed-in** Steam client.
- `FINDING-R1-10.4.md` confirmed Steam requires network to sign in on first
  launch — over-determined, not a fixable gap.
- `PLAN.md` §6.1a item 7 requires a **controller-navigable Wi-Fi screen shown
  before Steam ever gets the display** on a first boot with no client.

Under design (a) that Wi-Fi screen would have no working controller input and
no on-screen keyboard: you would need the OSK to type the Wi-Fi password, but
the OSK only exists once the network is up and Steam is signed in. So the
first-boot path needs a non-Steam mapper **regardless of what the steady-state
desktop uses**. Design (a) could at best cover the steady-state session,
meaning shipping two input layers where one suffices. That is strictly worse.

**Secondary:** design (a) was also untestable on this hardware. The operator's
Deck has no Gaming Mode at all — neither `steam` nor `gamescope` is installed,
and the only sessions are `hyprland.desktop` and `hyprland-uwsm.desktop`. The
test plan's "confirm no conflict switching back to Gaming Mode's own Steam
instance" cannot be answered on this machine by any amount of setup. It would
need a SteamOS-derived install, which this Deck is not. Recorded so a future
session does not retry it here expecting a different outcome.

## Design (b) — hardware evidence

| Test plan item | Result |
|---|---|
| `/dev/uinput` access without root | ✅ **works** with one udev rule — verified functionally, not just by permissions |
| evdev *read* access without root | ✅ already works, via seat ACL — needs no change |
| Service starts only in the desktop session | ✅ works, but **the draft unit's target does not exist** — corrected below |
| OSK via `wlr-input-method` | ✅ protocol support confirmed; package available without AUR |

### 1. `/dev/uinput` — the doc's "first thing to validate"

Baseline confirmed the prediction: `crw------- root root`, module not even
loaded, and an unprivileged open fails with `EACCES`. After the udev rule
below, an unprivileged functional test passes end to end — opens the node,
sets `EV_KEY`/`KEY_A` capability bits, issues `UI_DEV_CREATE`, and the device
appears in `/proc/bus/input/devices` before being destroyed.

**So design (b) does not need a privileged helper.** That was the stated risk
that would have "undercut design (b)'s advantage"; it does not materialise.

**Ships as `/etc/udev/rules.d/99-deck-uinput.rules`:**

```
KERNEL=="uinput", SUBSYSTEM=="misc", TAG+="uaccess", GROUP="input", MODE="0660", OPTIONS+="static_node=uinput"
```

plus `/etc/modules-load.d/deck-uinput.conf` containing `uinput`, since the
module is not autoloaded.

**⚠️ `uaccess` alone is NOT sufficient — the installer must add the desktop
user to the `input` group.** This was tested rather than assumed, and the
result is counter-intuitive: `/dev/uinput` *does* carry the `uaccess` tag
(`CURRENT_TAGS=:uaccess:`) but gets **no** user ACL, because systemd's
`uaccess` builtin only grants ACLs to devices assigned to a seat. `uinput` is
a virtual device (`/devices/virtual/misc/uinput`) with no `seat` tag —
compare a real input device, which shows `CURRENT_TAGS=:uaccess:seat:` and
does receive a `user:<name>:rw-` ACL. `loginctl seat-status seat0` lists no
uinput entry. The `TAG+="uaccess"` above is kept as harmless
future-proofing; the `GROUP="input"` clause is what actually grants access
today. **T4/T5 action item: add the user to `input` at install time.**

By contrast the controller's own evdev nodes *do* get a seat ACL
(`user:<name>:rw-` on the `Valve Software Steam Controller` and `Steam Deck`
nodes), so the mapper's **read** side needs no group membership or rule at
all. Only the write side does.

### 2. The draft unit was wrong, and would have failed silently

The prepared unit used `WantedBy=hyprland-session.target`. **That target does
not exist** — `systemctl --user show -p LoadState hyprland-session.target`
returns `LoadState=not-found`. Under `uwsm` 0.26.6 the session targets are
compositor-instance templates:

```
wayland-session@hyprland.desktop.target            ← the one to use
wayland-session-pre@hyprland.desktop.target
wayland-session-envelope@hyprland.desktop.target
wayland-session-xdg-autostart@hyprland.desktop.target
```

A unit with `WantedBy=` a nonexistent target **enables without error and then
never starts** — exactly the silent-failure class `CLAUDE.md` forbids. Had
this shipped as drafted, the mapper would have been installed, reported
success, and simply never run.

**Corrected unit** (`~/.config/systemd/user/deck-input-mapper.service`),
verified live — `systemctl --user enable` places the symlink in
`wayland-session@hyprland.desktop.target.wants/` and the service activates:

```ini
[Unit]
Description=Deck gamepad-to-desktop input mapper (Desktop Mode only)
PartOf=graphical-session.target
After=graphical-session.target

[Service]
Type=simple
ExecStart=%h/.local/bin/deck-input-mapper
Restart=on-failure

[Install]
WantedBy=wayland-session@hyprland.desktop.target
```

Note there is **no `SupplementaryGroups=`** — that directive is not permitted
in a `--user` unit, which is the other reason the `input` group has to be
granted at install time rather than per-service.

The scoping argument also holds up structurally: the target is parameterised
by the compositor's `.desktop` name, so a gamescope Gaming Mode session
cannot reach `wayland-session@hyprland.desktop.target`. It would instantiate a
different unit instance, or not use `uwsm` at all. **Reasoned, not verified** —
there is no gamescope session on this machine to test against.

### 3. OSK — feasible, and the AUR constraint picks the package

Hyprland 0.56.0 implements **both** relevant protocol families, confirmed
from the binary's own symbols: `zwp_input_method_manager_v2` (what
`squeekboard` uses) and `zwp_virtual_keyboard_manager_v1` + `zwlr_layer_shell_v1`
(what `wvkbd` uses). So the doc's "biggest open question for design (b)" is
answered at the protocol level: focus-triggered popup is supported.

**Use `squeekboard`, not `wvkbd`.** `squeekboard` is in Arch `extra`
(1.43.1-5); `wvkbd` is AUR-only, and `CLAUDE.md` forbids auto-installing an
AUR helper. The doc's first suggestion was the one this project cannot ship.

## What is still unverified

Stated plainly rather than implied by omission:

- **The mapper itself does not exist.** T2 is not started — the repo has only
  `TASK-T2-gamepad-input-spike.md`. What is verified here is that every
  *precondition* design (b) depends on works on real hardware. Input latency
  and reliability, which the test plan lists as comparison criteria, cannot
  be measured until there is a mapper to measure.
- **OSK focus-triggered popup is protocol-confirmed, not demonstrated.**
  `squeekboard` was not installed. Confirming an actual popup on text-field
  focus in a native Wayland app and an XWayland app remains to be done.
- **Gaming Mode coexistence is untestable on this Deck** (no gamescope). It
  needs a machine with both sessions installed — realistically a T3/T5-era
  test, not a repeat of this one.
- Battery/RAM cost was not measured for either design; with (a) ruled out on
  structural grounds the comparison it was meant to inform is moot.
