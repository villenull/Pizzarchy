# P40 — Steam in Desktop Mode: the mechanism, and the full option space

> **Recon, 2026-08-16 (night).** Sibling agents are prototyping fixes in
> worktrees. This file is not a fix. It establishes the ground truth those
> prototypes get judged against, and maps every approach — including the ones
> nobody is building — so we do not commit to the first idea we had.
>
> **Companion:** `docs/findings/P39-steam-desktop-window-and-input.md` (Defect 2).
> P39's measurements are taken as given here and are **not** re-derived. Where I
> think P39 or any other repo document is wrong, I say so with evidence.

---

## 0. Provenance discipline, and what I could NOT do

Every claim below carries one of four tags. This is not decoration — three of
this project's worst hours came from an inference wearing a measurement's
clothes (`docs/PROGRESS.md` §5.30c, `docs/findings/P20-steam-xtest-closure.md`).

| tag | means |
|---|---|
| **MEASURED-HERE** | I ran the command tonight and the output is quoted below |
| **SOURCE** | I read the actual source or packaging and quote it |
| **MEASURED-PRIOR** | a previous session measured it; cited by file and section |
| **INFERRED** | reasoning over the above. Never stated as fact |

### 🔴 The Deck was unreachable. No hardware measurement was taken tonight.

```
$ ping -c 3 -W 3 192.168.100.25
From 192.168.100.14 icmp_seq=3 Destination Host Unreachable
3 packets transmitted, 0 received, +3 errors, 100% packet loss

$ ssh -o ConnectTimeout=20 deck@192.168.100.25 'echo ALIVE'
ssh: connect to host 192.168.100.25 port 22: No route to host
```

Retried three times over ~40 minutes. The operator powered the Deck down or it
left the network when they went to bed. **The read-only SSH recon budgeted for
this task did not happen**, and nothing in this file claims to be a fresh
hardware reading. Everything hardware-shaped here is MEASURED-PRIOR or is
written up as an experiment in §F.

The positive control on that conclusion: the same `ping` binary and the same
network interface reach other hosts; `Destination Host Unreachable` from
`192.168.100.14` (this machine's own gateway path) is an ARP failure for
`.25` specifically, not a dead link. **Not** a case of "the check was never
looking".

---

## A. The mechanism, precisely — and it is already proven

**Question:** how does Steam turn the controller into a cursor in Desktop Mode,
given P39 measured that Steam holds *no* `/dev/input/event*` fd and creates no
mouse device?

**Answer: Steam calls the X11 `XTestFake*` functions. This is MEASURED, not
inferred, and the proof is stronger than anyone in this repo has yet stated.**

### The proof, by interception

`docs/findings/T10-steam-extest-results.md` row 1 recorded:

> | 1 | Right trackpad moves the desktop pointer | ✅ **PASS** |

with `libextest-i686.so` and `libextest-x86_64.so` preloaded into Steam. Tonight
I read what those libraries actually are. **MEASURED-HERE**, against the exact
artifacts T10 used (`~/ISOs/extest-cb77cd4/`):

```
$ nm -D --defined-only libextest-i686.so | grep ' T '
0002a100 T XTestFakeButtonEvent
0002a430 T XTestFakeKeyEvent
0002a650 T XTestFakeMotionEvent
0002a890 T XTestFakeRelativeMotionEvent

$ nm -D --defined-only libextest-x86_64.so | grep ' T '
0000000000027110 T XTestFakeButtonEvent
0000000000027430 T XTestFakeKeyEvent
0000000000027640 T XTestFakeMotionEvent
0000000000027870 T XTestFakeRelativeMotionEvent
```

**Four symbols. That is the entire interception surface.** extest has exactly
one way to emit anything: one of those four functions being called.

So the argument closes:

1. extest emits *only* when `XTestFake{Motion,RelativeMotion,Button,Key}Event`
   is called. **SOURCE** (`src/lib.rs`, read below — there is no other code
   path, no thread, no poller).
2. The preload was applied to Steam's processes and to nothing else
   (MEASURED-PRIOR, T10's process table: `steam` 32-bit and nine
   `steamwebhelper` 64-bit, each holding the matching `.so`).
3. Moving the right trackpad moved the desktop pointer (MEASURED-PRIOR, T10
   row 1).
4. **Therefore Steam called `XTestFake*`.** There is no third party.

Corroborating detail, and it is a nice one: T10 recorded that
`extest fake device` did **not** appear until the operator first moved the
trackpad. **SOURCE** explains exactly why — the uinput device is behind a
`once_cell::sync::Lazy`, constructed on first use:

```rust
static DEVICE: Lazy<Mutex<VirtualDevice>> = Lazy::new(|| { ... });
```

The device's appearance *is* the timestamp of Steam's first XTEST call. Two
independent observations, one mechanism.

**This upgrades P17's R-42 caveat** — *"`libXtst` being mapped proves Steam
links XTEST, not that the desktop layout uses it"* — from strong inference to
measurement. It also retires the last hedge in `P20-steam-xtest-closure.md`
§"What this does NOT prove". Steam's desktop pointer is XTEST. Full stop.

### Why that produces exactly the symptom the operator sees

`docs/findings/P20-steam-xtest-closure.md` (R-53) measured, with a positive
control that caught a wrong first run:

| target | XTEST reaches it? |
|---|---|
| XWayland X11 client | ✅ yes |
| Wayland-native client | ❌ no |
| the compositor's own pointer | ❌ no |

Steam's windows are XWayland. **Careful about the provenance here, because it is
load-bearing:** T10 row 2 logged `Steam Input On-screen Keyboard` as XWayland
(MEASURED-PRIOR) — that is Steam's *keyboard* window, not the client window.
For the **main Steam window** I have no direct `xwayland: true` reading in any
of our findings; P39's only explicit `xwayland False` line belongs to the `foot`
control, not to Steam. So this is **INFERRED** from two things: the Steam client
has no Wayland backend and runs on X11, and Steam demonstrably holds an X
display connection (it calls `XTestFake*`, §A). It is a safe inference and it is
30 seconds to confirm (§F.8). So: 

> Steam synthesises pointer motion via XTEST → XWayland's X server moves **its
> own** X pointer → every X client under XWayland, *including all of Steam's own
> windows*, sees a moving cursor → the Wayland compositor sees nothing, so
> there is no desktop cursor and no Wayland-native client is touched.

**That is fact 5 in its entirety.** The operator driving Steam's UI with an
invisible pointer, highlighting elements, and successfully clicking Exit, is not
a mystery and not a crack in the diagnosis — it is precisely what R-53 predicted
would happen and the first time anyone has watched it happen. The pointer is
invisible because Hyprland draws the cursor and Hyprland does not know it moved;
it is confined to Steam because XWayland is the only surface it exists on.

⚠️ **The one thing fact 5 is NOT.** It is not evidence of a second, hidden input
path that could be "redirected to the desktop". The mechanism is a single X11
call into a nested X server. There is nothing to redirect — there is something
to **intercept**, which is what extest does, and which we have already measured
working on this exact hardware.

### 🟢 P39's 0-byte lizard measurement now has a source-level explanation

P39 measured that `lizard_mode=Y` restores the module parameter but not a
pointer (0 bytes on `event5` in 20 s under confirmed movement, against 49,320
bytes in 3 s with Steam closed). **`hid-steam.c` says exactly why, in two
independent ways** (SOURCE, via the research pass):

1. `steam_param_set_lizard_mode()` **skips any device with a client attached**:
   ```c
   list_for_each_entry(steam, &steam_devices, list) {
           if (!steam->client_opened)
                   steam_set_lizard_mode(steam, lizard_mode);
   }
   ```
   With Steam holding `hidraw2`, `client_opened != 0`, so writing `Y` to the
   parameter is a **no-op for that device**. The file changes; nothing else does.
2. Lizard mode is **firmware behaviour on other HID interfaces**.
   `steam_set_lizard_mode()` only sends `ID_SET_DEFAULT_DIGITAL_MAPPINGS` +
   `ID_LOAD_DEFAULT_SETTINGS` over the wire; the resulting mouse events arrive on
   interfaces 0 and 1, owned by `hid-generic`, not `hid-steam`.

And the driver's own header comment, written by its author in 2018, states the
whole design:

> *"There are a few user space applications (notably Steam Client) that use the
> hidraw interface directly to create input devices (**XTest**, uinput...). In
> order to avoid breaking them this driver creates a layered hidraw device, so it
> can detect when the client is running and then: … this input device will be
> removed, to avoid double input of the same user action."*

**The kernel names XTest explicitly.** Our diagnosis and the driver author's
intent are the same sentence. Introduced in commit `385a488677` (2018) because an
idle gamepad was confusing games into two-player mode.

🟢 **This belongs in `docs/PROGRESS.md` §7 as a "do not rediscover":** the device
removal is *documented kernel-source intent, not a bug*. There is **no** module
parameter, sysfs knob or compositor setting that changes it — `lizard_mode` is
the driver's only parameter and it does not gate the unregister. Nobody is going
to "fix" this upstream.

### What Steam is NOT using — bounded, not assumed

* **uinput.** Steam's only virtual device is `Microsoft X-Box 360 pad 0`
  (28de:11ff, `ABS=3003f`) — a *gamepad*, not a pointer. MEASURED-PRIOR, P39.
* **A Wayland virtual-pointer/virtual-keyboard protocol.** Steam holds no
  Wayland pointer-injection object; if it did, the desktop cursor would move,
  and it measurably does not (P39: 0 bytes, 20 s, confirmed movement).
* **evdev.** Steam holds no `/dev/input/event*` fd at all. MEASURED-PRIOR, P39's
  `/proc/*/fd` scan.
* **libei / XWayland's EI portal.** If XWayland were bridging XTEST to the
  compositor via libei, the desktop cursor *would* move without extest, and
  R-53 measured that it does not on this compositor. **INFERRED** that Hyprland
  0.56.2 implements no EIS server; see §F experiment 6 for the direct check.

---

## B. extest — the verdict, with the licence

**Verdict: extest is the only measured path from the Deck's trackpads to a real
Wayland desktop pointer while Steam is resident. It can ship. It is also
carrying three source-level panics that could turn "no pointer" into "Steam
crashes", and nobody has ever checked for them.**

### B.1 Licence — MIT, and our pin is upstream HEAD

**MEASURED-HERE.** Cloned `https://github.com/Supreeeme/extest` and checked out
the repo's pinned SHA:

```
$ git log -1 --format='%H %ad %s'
cb77cd4f80f83393a24bae17dd975e14fa6eb1b2 Mon May 25 16:52:33 2026 -0400 Bump version to 1.0.4

$ head -3 LICENSE
MIT License

Copyright (c) 2023 Supreeeme
```

Two things worth knowing that were not previously recorded:

1. **`cb77cd4` is the current upstream HEAD.** `git log --oneline origin/HEAD`
   puts our pin at the top. We are not shipping a stale fork — we are pinned to
   the tip of a project that has not moved since May 2026. That is both
   reassuring (no security drift to chase) and a mild concern (low upstream
   activity).
2. **`tools/build-extest.sh`'s licence gate is real and it works.** It greps
   `head -1 LICENSE` for `MIT License` and hard-`exit 1`s otherwise. That line
   passes today. **This satisfies CLAUDE.md's redistribution rule**: MIT, not
   AUR-only, built by us from source at a pinned SHA.

   🔴 **One shipping obligation is currently unmet.** MIT requires the copyright
   notice and permission text to travel with the binary. If the two `.so` files
   go onto the ISO, `LICENSE` must go with them. Nothing in `tools/build-extest.sh`
   copies it into `$OUT` — it installs the two libraries and nothing else. **One
   line to fix; it is a licence-compliance defect the moment we ship.**

### B.2 What it intercepts — the complete list

Four symbols (MEASURED-HERE via `nm -D`, §A). What is **not** intercepted
matters just as much, **SOURCE** (`src/lib.rs` has no other `#[no_mangle]`):

* `XQueryExtension` / `XTestQueryExtension` — **not hooked**. Steam's "is XTEST
  available?" probe therefore still goes to the real XWayland server, which does
  provide XTEST, so the probe passes and Steam proceeds to call the fake
  functions. **This is why the shim works at all**, and it is also a dependency:
  if Steam were ever launched with no X display, it would not call XTEST and
  extest would be inert.
* `XTestGrabControl` — not hooked, harmless.

### B.3 How it emits — and the ABS range is Deck-relevant

**SOURCE**, `src/lib.rs`:

```rust
VirtualDevice::builder()
    .name("extest fake device")
    .with_keys(...BTN_LEFT, BTN_RIGHT, BTN_MIDDLE, BTN_EXTRA, BTN_SIDE + KEYS...)
    .with_relative_axes(...REL_X, REL_Y, REL_WHEEL...)
    .with_absolute_axis(UinputAbsSetup::new(ABS_X, AbsInfo::new(0, 0, size.width,  0, 0, 1)))
    .with_absolute_axis(UinputAbsSetup::new(ABS_Y, AbsInfo::new(0, 0, size.height, 0, 0, 1)))
```

`size` comes from `src/wayland.rs::get_axes_range()`, which binds
`zxdg_output_manager_v1` and takes **the largest `LogicalSize` of any output**.

⚠️ **On this Deck the logical size is 1024x640, not 1280x800** (P39 §Defect 1:
`transform = 3`, `scale = 1.25`). extest will therefore declare `ABS_X 0..1024`,
`ABS_Y 0..640`. `XTestFakeMotionEvent` passes **X-root coordinates**, so this is
only correct if XWayland's root window is also 1024x640. T10 row 5 measured *"no
defect seen"* for pointer coordinate sanity under `transform = 3`, which says
they agreed on that day. **It is a coincidence we should stop relying on
silently**: anything that changes XWayland scaling (`xwayland:force_zero_scaling`,
a docked second display, a scale change) desynchronises the two and the pointer
lands in the wrong place with no error anywhere. §F experiment 3 measures it.

The key table (`src/steam_keys.rs`) declares **112 `KeyCode`s** — *"Every key
that Big Picture allows binding"*. This repo already knows the trap
(`src/deck_osk_layout.py:650`, `iso/bin/build:536`): **a uinput device emits only
the codes it declared.** A key Steam sends that is not in that list is dropped by
the kernel, silently, with no error and no log line. That is a real but minor
gap and it is the keyboard half, which we have already decided we do not need.

### B.4 🔴 Three source-level panics — the finding nobody has

**SOURCE.** extest is Rust built as a `cdylib` and it `.unwrap()`s in three
places on the initialisation path, *inside Steam's own process*:

| # | code | panics when |
|---|---|---|
| 1 | `VirtualDevice::builder().unwrap()` (`lib.rs:26`) | `/dev/uinput` cannot be opened for write |
| 2 | `Connection::connect_to_env().unwrap()` (`wayland.rs:27`) | `WAYLAND_DISPLAY` is absent from the process environment |
| 3 | `data.output_man.as_ref().unwrap()` (`wayland.rs:38`) | the compositor advertises no `zxdg_output_manager_v1` **at version ≥ 3** (the bind is gated `version >= 3`) — reached only if at least one `wl_output` exists |
| 4 | `dev.emit(&events).unwrap()` (`lib.rs:84,163,179,196`) | **every single event emission**, if the uinput write fails (device removed, `ENODEV`, compositor teardown) |

1–3 are reached from the same `Lazy` initialiser, i.e. **on the first trackpad
movement**, not at launch. **4 is on the hot path and fires forever after.** A
Rust panic unwinding out of a `cdylib` into a C caller is undefined behaviour;
in practice it aborts the process.

`grep -c unwrap` over the two files: **19 sites, zero `Result` handling, zero
`catch_unwind`.** This is a 416-line hobby shim, and it is written like one. That
is not a reason to reject it — it is a reason to wrap it.

**Why this is not academic for us, specifically:**

* Panic 2 is a direct hit on a hazard this repo has already been bitten by.
  `docs/PROGRESS.md` §5.28: *"a freshly booted desktop has NO keyboard... the
  mapper wins the race against uwsm's env import and its children are born
  blind."* A Steam launched from any context that has not yet received uwsm's
  environment import has no `WAYLAND_DISPLAY` — and with extest preloaded, that
  is no longer "Steam has no Wayland", it is **"Steam dies the first time you
  touch the trackpad."**
* Panic 1 is gated on a permission we have never verified on a machine built by
  our own ISO. See §B.5.

**This is the strongest single argument for caution on extest, and it is
entirely testable in five minutes** (§F experiment 2). It is also *fixable*: a
`catch_unwind` wrapper, or simply pre-flighting the three preconditions in the
launcher before setting `LD_PRELOAD`. The second is the better shape for us —
it fails to "today's behaviour" instead of "Steam crashes", and it is loud.

### B.5 /dev/uinput permission — probably already solved, and our own record disagrees with itself

extest's README is explicit:

> You will also need to add your user to the `input` group ... so that your user
> can be allowed to actually create fake devices

**But that is very likely unnecessary on our install, because Steam brings the
grant with it.** **MEASURED-HERE**, on this dev machine:

```
$ pacman -Qo /usr/lib/udev/rules.d/60-steam-input.rules
/usr/lib/udev/rules.d/60-steam-input.rules is owned by steam-devices 1.0.0.87-1

$ grep -n uinput /usr/lib/udev/rules.d/60-steam-input.rules
5:KERNEL=="uinput", SUBSYSTEM=="misc", TAG+="uaccess", OPTIONS+="static_node=uinput"

$ pacman -Qi steam | grep -o 'steam-devices'
steam-devices                     # a HARD dependency of `steam`, not optional
```

So any install carrying `steam` carries this rule. And the rule works:

```
$ getfacl -p /dev/uinput
# owner: root
# group: root
user::rw-
user:huyke:rw-        <-- the uaccess ACL
group::---

$ loginctl seat-status seat0 | grep -i uinput
(no uinput on seat0)
```

🔴 **This contradicts our own `docs/findings/R1-10.3.md`**, which states:

> **⚠️ `uaccess` alone is NOT sufficient — the installer must add the desktop
> user to the `input` group.** ... `/dev/uinput` *does* carry the `uaccess` tag
> but gets **no** user ACL, because systemd's `uaccess` builtin only grants ACLs
> to devices assigned to a seat.

The measurement above shows a user ACL on `/dev/uinput` **with no seat entry**.
Either systemd's behaviour changed between 2026-08-09 and now, or R1-10.3's
diagnosis of *why* it needed the group was wrong even though its conclusion
("add the group") was safe. Either way **R1-10.3 §1 is stale and should not be
cited as-is**, and `src/deck-session.sh:4193`'s comment (which says the ACL comes
from `60-steam-input.rules`) is the version that matches reality.

🔴 **And the group was never granted anyway.** R1-10.3 ends with
*"T4/T5 action item: add the user to `input` at install time."* **MEASURED-HERE:
that action item was never done.** Neither `usermod`, `gpasswd`, nor `groupadd`
appears anywhere in `iso/overlay/configs/airootfs/usr/share/omarchy-iso/` or
`src/*.sh` in a group-granting role, and the `99-deck-uinput.rules` file
R1-10.3 specifies is **not in the repo at all**.

The mapper nevertheless works on the operator's Deck — P39's State A lists
`deck-input-mapper virtual keyboard`, which cannot exist without a writable
`/dev/uinput`. **INFERRED:** the `steam-devices` uaccess rule is what is
carrying it, exactly as the dev-box measurement above suggests.

**Consequence for extest: it needs no new permission work.** It gets uinput
from the same grant the mapper is already living on. **Consequence for the
project generally: our uinput access is an undocumented side effect of having
installed Steam.** If Steam were ever removed, or `steam-devices` split out, the
mapper loses its keyboard. That is a latent single point of failure worth a
`99-deck-uinput.rules` of our own regardless of what happens to Steam.

### B.6 Delivery — upstream already wrote our install stage

**SOURCE.** The repo ships `override_steam_desktop_file.sh`, which does exactly
what we would have designed:

```bash
DATA_PATH="${XDG_DATA_HOME:-$HOME/.local/share}"
NEW_DESKTOP_FILE="$DATA_PATH"/applications/steam.desktop
cp $STEAM_DESKTOP_FILE $NEW_DESKTOP_FILE
sed -i "s,Exec=/usr/bin/steam,Exec=env LD_PRELOAD=$EXTEST /usr/bin/steam," $NEW_DESKTOP_FILE
```

A user-level `steam.desktop` shadows the package's `/usr/share/applications/steam.desktop`
by XDG precedence. **This is the right layer for us and it survives a Steam
package update**, for exactly the reason P39 gives for preferring a Hyprland
override to a patch: the package can rewrite its own file freely; ours still
wins.

**MEASURED-HERE**, Arch's shipped file is compatible with that `sed` — but with
a trap:

```
$ grep -c "Exec=/usr/bin/steam" /usr/share/applications/steam.desktop
10
$ grep -n "^\[" /usr/share/applications/steam.desktop
1:[Desktop Entry]   40:[Desktop Action Store]      70:[Desktop Action Community]
100:[Desktop Action Library]   130:[Desktop Action Servers]  160:[...Screenshots]
190:[Desktop Action News]      220:[...Settings]  250:[...BigPicture]  254:[...Friends]
```

⚠️ **There are TEN `Exec=` lines, not one** — the main entry plus nine
`Desktop Action`s (Library, Big Picture, Friends…). Upstream's `sed` rewrites all
ten because each is on its own line. **A hand-written override that only sets the
main `Exec=` would leave nine launch paths with no bridge**, and the user who
right-clicks Steam → *Library* would get the broken behaviour with no clue why.
That is exactly this repo's recurring silent-failure shape; it belongs in the
unit test as an assertion on the count.

Our version should differ in three ways:

1. **Write it into `/etc/skel/.local/share/applications/` as well as the created
   user's home** — the pattern `deck_monitors.py`, `deck_steam_seed.py` and
   `deck_session_settings.py` all already implement, with the marker splice and
   the "account may not exist yet" fallback they already have.
2. **Preload BOTH architectures**, colon-separated. T10 measured that the i686
   build alone leaves nine 64-bit `steamwebhelper` processes without the bridge
   and the spike *looks like a total failure*. `override_steam_desktop_file.sh`
   ships the one-library form and would reproduce that.
3. **Pre-flight the panics** (§B.4) in a tiny wrapper rather than bare `env`, so
   a missing `WAYLAND_DISPLAY` or an unwritable `/dev/uinput` means "launch Steam
   without the bridge, and log why" instead of "Steam aborts on first touch".

🔴 **And one unverified assumption underneath all of it: that Omarchy actually
launches Steam through the `.desktop` file.** If the Omarchy menu or Walker
execs the `steam` binary directly, a `.desktop` override is inert and the whole
delivery path is a no-op that tests green. **Not verified** — the Omarchy runtime
is not vendored in this repo in a greppable form. §F.9.

### B.7 Was the pointer path dropped by accident in session 26? — Yes, and it is provable

`docs/PROGRESS.md` session 26 records:

> 🟢 **T10 extest Spike:** Steam-in-background trackpad typing was evaluated;
> decision is to **forego the Steam keyboard** and commit entirely to our own
> OSK (the Omarchy OSK) everywhere except Gaming Mode.

**Read the decision the spike was actually feeding.** `T10-steam-extest-results.md`
§"What this means for the decision":

> What is newly open is only whether Steam's keyboard *also* serves ordinary
> Desktop Mode use

The question on the table was **keyboard, keyboard, keyboard**. T10's row 1 —
*"Right trackpad moves the desktop pointer ✅ PASS"* — was a precondition of the
keyboard test, not an item anyone was deciding about, and it was discarded with
the rest of the apparatus.

**And it was reasonable at the time, which is the part worth recording.** At
session 26 the working assumption was that Steam is not resident in Desktop
Mode. In that world the pointer path is worthless: no Steam, no XTEST, nothing
to bridge, and our mapper owns the pad. What changed is not the technology —
it is that the operator now wants **"steam app needs to be usable in desktop"**,
which makes Steam resident in Desktop Mode a supported state for the first time.

So: **the answer to "was the pointer silently dropped along with the keyboard"
is yes, and the decision that dropped it was not wrong — it was answered for a
requirement that has since changed.** It should be re-asked, not reversed on the
grounds that it was a mistake.

### B.8 Known failure modes, assembled

| failure | severity | evidence |
|---|---|---|
| 🔴 **SteamRT3 ("experimental Steam client") clears `LD_PRELOAD`** → extest silently never loads | **highest durability risk** | extest [#31](https://github.com/Supreeeme/extest/issues/31) (open), [#34](https://github.com/Supreeeme/extest/issues/34). Opt-in **today**; Valve's stated direction |
| Clicks fail while motion works (64-bit component) | medium | extest #35 (open), Artix + niri |
| Cursor de-syncs after resume from sleep | medium — **and we suspend Decks constantly** | extest #12 (open) |
| Wrong keycodes on non-US layouts | medium — the operator uses `latam` (§`PROGRESS` s21) | extest #9 (open) |
| One `.so` only → bridge half-loaded, looks like total failure | ⚠️ **disputed — see below** | MEASURED-PRIOR, T10 §1 |
| Panic on missing `WAYLAND_DISPLAY` / uinput / xdg-output v3 → **Steam aborts** | 🔴 highest | SOURCE, §B.4. **Never tested** |
| ABS range from logical size desynchronising from the XWayland root | medium, silent | SOURCE + T10 row 5 (agreed that day) |
| `println!` to Steam's stdout on every unknown button and at device creation | cosmetic | SOURCE, `lib.rs`/`wayland.rs` |
| Steam moves off XTEST (e.g. to libei) in a future update | medium, and it fails **safe** — back to today's behaviour | INFERRED |
| Steam sanitising `LD_PRELOAD` across its bootstrap re-exec | would have broken T10; it did not | MEASURED-PRIOR, T10 process table |
| Our chords (STEAM/QAM) and our OSK stay dead while Steam is resident | **unchanged by extest** — it does nothing for the mapper | MEASURED-PRIOR, P39 |
| Undeclared keycodes dropped silently by the kernel | low | SOURCE, `steam_keys.rs` = 112 codes |

#### ⚠️ I think T10's "both libraries are required" conclusion is wrong

T10's correction #1 is emphatic:

> The spec deploys ONE library. Both are required. … With the i686 build alone,
> **nine 64-bit `steamwebhelper` processes rejected the bridge** … The
> `extest fake device` never appeared and the spike looked like a failure.

**But upstream ships i686 only, and so does Bazzite, and so do nixpkgs, openSUSE
and the AUR** (§C.1, §C.5) — on real Steam Decks, in production, for years. The
maintainer states the `wrong ELF class: ELFCLASS32` spew from 64-bit children is
expected and harmless (extest #2). If the 64-bit half were required, every one
of those distros would be broken.

**The likelier explanation is that T10 conflated its own two corrections.**
Correction #2, in the same document, is that *"`extest fake device` does not
exist until the first XTEST call"* — the device appeared only once the operator
moved the trackpad. That alone explains "the device never appeared and the spike
looked like a failure" during the i686-only phase. T10 changed **two variables
between the failing and passing runs** (added the 64-bit library *and* started
moving the trackpad) and attributed the result to the first.

**Consequence:** shipping only `libextest-i686.so` is probably correct, matches
every other distro, and avoids extest #35's suspicion that the 64-bit path is
where clicks break. **Not resolved — this needs the A/B T10 never ran** (§F.10).
I am not confident enough to overturn a hardware measurement from a desk, but
the measurement has a confound and the whole world disagrees with it.

---

## C. What everyone else does — and one of them is already shipping our fix

**Headline: Bazzite ships extest on Steam Deck hardware, as a documented headline
feature, and has done so in production for years. This is a solved problem and
the solution is the one we already built and shelved.**

### C.0 First, a void result of my own, recorded because the rule matters

I tried to answer this with GitHub code search and got clean `0` counts for
`extest` in Bazzite, ChimeraOS, Jovian-NixOS and nixpkgs. **Those results were
false.** The positive control failed:

```
$ gh api -X GET search/code -f q="gamescope repo:ublue-os/bazzite" --jq '.total_count'
0          # gamescope is unquestionably in Bazzite -- the endpoint returns 0 for everything
```

The code-search endpoint returns zero for every query with this token. **A check
that proves something is ABSENT must also prove it was LOOKING** — it wasn't, so
I threw the results away and cloned the repository instead. Had I reported that
first pass, this document would have said "no distro ships extest", which is the
exact opposite of the truth.

### C.1 Bazzite — ships extest, on Decks, gated on session type — **SOURCE, verified by me**

Shallow-cloned `ublue-os/bazzite` and grepped it directly (positive control:
`gamescope` matches 30 files, so the grep works).
`system_files/desktop/shared/usr/bin/bazzite-steam`, verbatim:

```bash
if [[ "$XDG_SESSION_TYPE" == "wayland" ]]; then
  # https://github.com/Supreeeme/extest
  # Extest is a drop in replacement for the X11 XTEST extension.
  # It creates a virtual device with the uinput kernel module.
  # It's been primarily developed for allowing the desktop functionality
  # on the Steam Controller to work while Steam is open on Wayland.
  # Also supports Steam Input as a whole.
  env LD_PRELOAD=/usr/lib/extest/libextest.so /usr/bin/steam "$DECK_OPTION" ... "$@"
else
  /usr/bin/steam "$DECK_OPTION" ... "$@"
fi
```

It is the **only** `LD_PRELOAD` in the entire repository, and it is advertised to
users in the README in **thirteen languages**: *"Uses Wayland on the desktop with
[support for Steam input]"*.

Three details we should copy, and one we must not:

* ✅ **A wrapper binary, not `env` inline.** Gives somewhere to put pre-flight
  checks.
* ✅ **The `$XDG_SESSION_TYPE == "wayland"` guard.** This is the *same* hazard as
  my §B.4 panic 2, and Bazzite solved it years ago: **never preload extest into
  a Steam launched under gamescope / Gaming Mode**, where there is no Wayland
  display for extest to query and it would abort. Independent convergence on the
  same failure mode is the strongest signal in this whole document.
* ✅ They also rewrite the **autostart** entry
  (`/etc/skel/.config/autostart/steam.desktop`), not just the menu one.
* 🔴 **We must NOT copy their wiring.** `Containerfile:492`:
  ```
  sed -i 's@/usr/bin/steam@/usr/bin/bazzite-steam@g' /usr/share/applications/steam.desktop
  ```
  An **in-place patch of the packaged file at image build time.** That is safe
  for Bazzite because Bazzite is an immutable OSTree image where pacman cannot
  come along later. **On our mutable Arch system the next `steam` package update
  silently reverts it** — the failure reported in
  [steam-for-linux#13185](https://github.com/ValveSoftware/steam-for-linux/issues/13185).
  Use the user-level `~/.local/share/applications/steam.desktop` override
  (§B.6) instead, which shadows the package file rather than fighting it.

They fetch a single **i686-only** `.so` from their own
[`ublue-os/extest`](https://github.com/ublue-os/extest) fork
(`Containerfile:301-305`), and they mask InputPlumber on Valve hardware so
`hid-steam` + Steam Input + extest own the controller uncontested.

### C.2 SteamOS — X11 was the whole answer, and stopped being it in 2026

* **SteamOS 3.5–3.7 Desktop Mode is X11 by default.**
  [ValveSoftware/SteamOS#2081](https://github.com/ValveSoftware/SteamOS/issues/2081)
  — *"from gamescope you will be opening the X11 session with no choice"*.
  `steamos-session-select` offers `plasma`, `plasma-wayland`,
  `plasma-x11-persistent`, `plasma-wayland-persistent`. **DOCUMENTED (issue
  tracker).**
* **SteamOS 3.8+ switched the default to Wayland**, per the same issue's closing
  comment. **FORUM/ISSUE CLAIM** — Valve's own release notes are behind bot
  protection and were unfetchable, so treat the version boundary as approximate.
* Under Wayland, SteamOS relies on the **KDE** path: Xwayland-with-libei →
  `org.freedesktop.portal.RemoteDesktop` → KWin injects real input.
* **Valve ships no extest.** Not found in any reachable Valve or holo package
  list.

🟢 **This confirms `P20-steam-xtest-closure.md`'s structural claim, and it is
worth stating plainly: the reason SteamOS Desktop Mode "just worked" is that it
was an X11 desktop. Not integration packages, not `jupiter-hw-support`.** That
also closes R-41's third hypothesis (P20 §"What this does NOT prove"): the
SteamOS integration packages would not have helped, because they do not turn
Wayland into X11.

### C.3 The upstream-correct fix exists and is broken on Hyprland at two points

The modern chain is **Steam → XTEST → Xwayland → libei →
`portal.RemoteDesktop` → compositor**. Peter Hutterer (libei's author) describes
it directly, and Xwayland has supported it since 23.2.0
([who-t](http://who-t.blogspot.com/2026/07/libei-integrations-in-xdg-remotedesktop.html)).

**Why it cannot work for us today — three source-verified points:**

1. ✅ **Arch's Xwayland IS built with libei** — `xorg-xwayland`'s PKGBUILD carries
   `depends=(… 'libei' …)`. That half is fine.
2. 🔴 **No wlroots-compatible portal implements RemoteDesktop.**
   `xdg-desktop-portal-hyprland` advertises only
   `Screenshot;ScreenCast;GlobalShortcuts;InputCapture` — **no RemoteDesktop**.
   The PR adding it ([xdph#402](https://github.com/hyprwm/xdg-desktop-portal-hyprland))
   has been open since 2026-05; the equivalent for `xdg-desktop-portal-wlr` has
   been open since **March 2023**.
3. 🔴 **Hyprland does not even ask.** `src/xwayland/Server.cpp` hardcodes the
   Xwayland argv as `-rootless -core -listenfd … -displayfd … -wm …` with **no
   `-enable-ei-portal`**, and there is no config option to add it.

**The corroborating natural experiment is beautiful and it is Bazzite's:** they
briefly *removed* extest (commit `32b5c79d`, 2026-03) and users immediately hit
the portal fallback — a *"Remote control / An app is asking for special
permission / Control input device"* dialog
([bazzite#4487](https://github.com/ublue-os/bazzite/issues/4487)), and the Steam
OSK dying when it was dismissed (#4497). extest was restored 11 days later. That
is the same Steam code path landing on a compositor that *does* have the portal
— proving both that the portal path is what Steam now reaches for, and that
extest is what Bazzite deliberately uses instead.

**Conclusion: do not plan around the upstream fix.** Two independent PRs, one
open for three years, plus a third change Hyprland has not made.

### C.4 The others

* **ChimeraOS** — no extest anywhere. GNOME, with **both** Wayland and Xorg
  sessions selectable (`chimera-session`: `desktop` vs `desktop_xorg`). Their
  controller-as-pointer answer is **InputPlumber**. extest exists only as
  [open, unadopted issue #700](https://github.com/ChimeraOS/chimeraos/issues/700)
  from 2023.
* **HoloISO** — **archived**, EOL since early 2024. Plasma on `xorg-server`, i.e.
  X11, so it never needed a bridge. Not a source of ideas.
* **Jovian-NixOS** — no extest, no XTEST, no `hid-steam` patching. They ship only
  udev rules granting `uaccess` on `uinput` and `hidraw*` for vendor `28de` —
  *the same grant we get from `steam-devices`* (§B.5). Maintainer K900 closed a
  request to document extest in two minutes:
  > *"Steam will use the XDG remote control portal via Xwayland when that is set
  > up properly. Niri just doesn't support that, which is a Niri issue more than
  > anything"*
  ([Jovian-NixOS#506](https://github.com/Jovian-Experiments/Jovian-NixOS/issues/506))
  — i.e. they consider this the compositor's problem and decline to work around
  it. A defensible position for a distro; not one available to us, since we have
  a Deck in a user's hands and Hyprland is not going to grow a RemoteDesktop
  portal this quarter.
* **Omarchy upstream** — nothing. No extest, no `LD_PRELOAD`, no `hid-steam`.

### C.5 Packaging — the AUR question, answered

| distro | package | status |
|---|---|---|
| **Arch** | `lib32-extest` 1.0.3-1 | 🔴 **AUR only.** Nothing in core/extra/multilib |
| **openSUSE Tumbleweed** | `extest` 1.0.3 | ✅ **Official**, with a multilib `-32bit` subpackage |
| **nixpkgs** | `extest` + NixOS option `programs.steam.extest.enable` | ✅ **First-class** |
| **Fedora** | — | third-party (Terra) only |

**This is exactly the case `tools/build-extest.sh` was written for, and CLAUDE.md
permits it.** The rule forbids *depending* on AUR-only packages; it does not
forbid vendoring MIT source at a pinned SHA and building it ourselves, which is
what the script already does and what its own header says. Installing
`lib32-extest` from the AUR at install time would violate both the AUR rule
**and** the "don't auto-install an AUR helper" rule. **Build, don't depend.**

### C.6 Our exact bug has an upstream issue with six independent confirmations

[ValveSoftware/steam-for-linux#13185](https://github.com/ValveSoftware/steam-for-linux/issues/13185)
(open, 2026-05), describing our symptom on our driver:

> *"The trackpad works correctly as a system mouse in lizard mode before Steam
> launches. As soon as Steam launches, it grabs exclusive hidraw control … and
> the cursor stops working."*

Six independent reporters confirm **extest fixes it on Hyprland, niri, Arch,
CachyOS and Fedora.** No report anywhere of extest failing *because of* a
wlroots compositor — consistent with source, since extest binds only `wl_output`
and `zxdg_output_manager_v1` (both present in Hyprland) and emits plain uinput,
leaving the compositor out of the loop entirely.

**We are not pioneering. We are the last ones to the fix.**

---

## D. The full option space, ranked

Ranked on the operator's actual sentence — *"steam app needs to be usable in
desktop"* — plus the five criteria: real pointer / survives a Steam self-update /
shippable under our licensing rule / installable by a stage / failure mode /
keyboardless recovery.

### 🥇 1 — Verify the touchscreen. Zero code, and it may already be shipped.

**This is first because it is free, and because if it works the severity of the
whole defect collapses tonight.**

The Deck's digitizer is `FTS3528:00 2808:1015` — an **I²C HID device with no
relationship whatsoever to `hid-steam`**. Steam opening `/dev/hidraw2` cannot
destroy it, cannot grab it, and cannot claim it. **INFERRED but very strongly:
the touchscreen keeps working with Steam resident.** Nobody has ever checked,
which is remarkable given it is the one input device this entire bug does not
touch.

And the rotation defect that made touch useless is **already fixed and shipped**:
`iso/.../orchestrator/deck_input.py` renders
`hl.config({ input = { touchdevice = { output = "eDP-1", transform = 3 } } })`,
derived rather than guessed, and `transform = 3` was confirmed by an operator
A/B on hardware (`docs/PROGRESS.md` §5.30c: at `transform = 0`, *"things are
moving but nothing is behaving quite right"*; at `3`, *"touch is working
correctly now"*).

⚠️ But `deck_input.py`'s own comment says: **"The arithmetic is verified; the
FINGER is not."** No tap has been landed through the *shipped* config. So this
is one finger and thirty seconds away from being either the cheapest win of the
night or a known dead end.

| criterion | |
|---|---|
| real pointer | partial — taps and drags, no hover; enough to click Steam **and** the desktop |
| survives Steam update | ✅ totally — different subsystem |
| licensing | ✅ nothing to ship |
| installable by a stage | ✅ **already is** |
| failure mode | none — it either works or we are where we are now |
| keyboardless recovery | ✅ **this is the escape hatch** |

**Do this first regardless of which fix wins.** It is orthogonal to every other
option and it is the answer to "what does a trapped user do".

### 🥈 2 — extest (LD_PRELOAD XTEST→uinput bridge)

The only measured trackpad→desktop-pointer path with Steam resident. Full
analysis in §B.

| criterion | |
|---|---|
| real pointer | ✅ **MEASURED** (T10 row 1) — the only option that can say this |
| survives Steam update | ✅ likely (env inherited across the bootstrap re-exec, MEASURED-PRIOR); dies only if Steam abandons XTEST, and then fails safe |
| licensing | ✅ MIT, our pin = upstream HEAD. ⚠️ must ship `LICENSE` (§B.1) |
| installable by a stage | ✅ a `steam.desktop` override into `/etc/skel` + user home — machinery that already exists three times over |
| failure mode | 🔴 **currently unknown and possibly "Steam aborts"** (§B.4). Must be pre-flighted, and then it degrades to today's behaviour |
| keyboardless recovery | ✅ pointer works; ✅ plus option 1 |
| cost | small — the build script exists, the artifacts exist, the delivery pattern exists |

**Does not fix:** our mapper stays dead, so STEAM/QAM chords and our OSK remain
unavailable while Steam is up. extest gives a pointer, not our input layer back.

### 🥉 3 — Our mapper reads `/dev/hidraw2` alongside Steam (coexistence)

**Nobody is building this and it is the most architecturally correct answer.**

The blocking assumption everywhere in P39 is that Steam *taking* the controller
is terminal. It is not. **SOURCE**, `drivers/hid/hidraw.c` (read tonight via
upstream `torvalds/linux`):

* `hidraw_open()` has **no exclusivity check** — it increments `dev->open` and
  never refuses a second opener.
* `hidraw_report_event()` iterates **every** open descriptor and `kmemdup()`s
  the report to each:
  `list_for_each_entry(list, &dev->list, node) { ... kmemdup(data, len, GFP_ATOMIC) }`
* Each `open()` allocates its own ring buffer with independent head/tail.

**So our mapper can open `/dev/hidraw2` at the same time as Steam and receive
every input report Steam receives.** Permission is already granted: `60-steam-input.rules`
line 11, `SUBSYSTEM=="hidraw", KERNELS=="000[356]:28DE:*", MODE="0660", TAG+="uaccess"`
(MEASURED-HERE) — the same ACL Steam itself is using.

🔴 **CRITICAL CONSTRAINT, from `hid-steam.c` (SOURCE, via the research pass):**
opening that hidraw node is *itself* what destroys the native pad.
`steam_client_ll_open()` unconditionally does
`steam->client_opened++; schedule_work(&steam->unregister_work)`, and
`steam_work_unregister_cb()` then calls `steam_input_unregister()`.

**So this option is only safe as a SECOND opener.** If our mapper opened
`/dev/hidraw2` while Steam was *not* running, it would destroy its own native
pad and have to drive everything from raw reports permanently — replacing a
working path with an unproven one. The design must therefore be:

> the mapper keeps using the native evdev pad as it does today, and opens
> `/dev/hidraw2` **only while Steam is resident** — i.e. exactly in the
> `pick_device()` "Steam owns the controller" branch that P39 identified, which
> today just sleeps for five seconds and does nothing.

That is a pleasing fit: the wait loop that P39 called the bug becomes the place
the fix lives. It is also strictly additive — if hidraw reading fails, the
branch falls back to today's five-second poll.

We would decode the Deck's raw report format ourselves and emit pointer + keys
through the uinput device the mapper already owns. That gives us, with Steam
resident: **a real pointer, our trackpads, our STEAM/QAM chords, and our OSK** —
i.e. *everything*, and it makes Steam's hidraw ownership permanently irrelevant.

| criterion | |
|---|---|
| real pointer | ✅ in principle, ❌ never built or measured |
| survives Steam update | ✅ **completely** — Steam is not in the loop |
| licensing | ✅ our own code |
| installable by a stage | ✅ it *is* `stage-input-mapper`, already shipped |
| failure mode | mapper logs and keeps polling — the shape it already has |
| keyboardless recovery | ✅ everything ours keeps working |
| cost | 🔴 **highest** — a raw HID report decoder in Python, plus calibration |

**Risks, stated honestly:** we take on decoding a Valve report format (stable,
but ours to maintain); Steam is simultaneously interpreting the *same* reports
for its own UI, so the right trackpad would drive our desktop pointer **and**
Steam's internal cursor at once — survivable, since Steam's XTEST goes nowhere,
but confusing; and if Steam ever reconfigures the controller's report mode via
feature reports our decoder must follow.

**Worth a two-hour spike before committing to anything else**, because the spike
is cheap: open `/dev/hidraw2` while Steam is running and see whether bytes
arrive. That is a 30-second read (§F experiment 4) and it decides whether this
whole branch is alive.

### 4 — Stop Steam claiming the hidraw node (the sibling's prototype)

Deny Steam `open()` on `/dev/hidraw2` → `hid-steam` never runs its
unregister path → the native pad survives → our mapper keeps working → the
trackpads drive the desktop exactly as they do today with Steam closed.

The lever is identified and it is clean: `60-steam-input.rules` line 11 grants
the ACL, and a higher-numbered rule in `/etc/udev/rules.d/` can take it away.

🔴 **But I believe this one has a serious, possibly disqualifying problem, and
it is the thing I would most want the sibling to answer:**

**It breaks Gaming Mode, and udev cannot tell the two apart.** The *same* rule,
the *same* node, and the *same* user (`deck`) are what Gaming Mode's Steam uses
for Steam Input — gyro, back buttons, per-game layouts, haptics. CLAUDE.md's
first sentence about this project is that it *"preserves stock SteamOS Gaming
Mode"*. A static udev rule denying `hidraw2` is not session-aware and cannot be:
udev has no notion of which session is active.

That forces the fix to become a **runtime toggle** — chmod/setfacl the node on
Desktop Mode entry and restore it on exit — which needs root, needs a privileged
helper, and **fails in the worst direction**: if the restore is missed (crash,
power-off, ordering bug), the user boots into Gaming Mode with a controller
Steam cannot claim. That is P39's own bricking bug, one subsystem over, and this
project has now shipped that exact shape of defect twice.

**A second problem, softer:** with no hidraw, Steam has no controller at all.
Launching a game from Desktop Mode gets a raw evdev gamepad via SDL (fine for
most games) and **no Steam Input** — no gyro, no back buttons, no community
layouts. That is a visible feature regression inside the very app the operator
asked to make usable.

| criterion | |
|---|---|
| real pointer | ✅ — and it is *our* pointer, with chords and OSK intact |
| survives Steam update | ✅ totally — kernel/udev level |
| licensing | ✅ |
| installable by a stage | ✅ trivially, as a udev rule |
| failure mode | 🔴 **fails toward a broken Gaming Mode**, the one thing we promised not to break |
| keyboardless recovery | ✅ |

✅ **The mechanism is now SOURCE-CONFIRMED, which is good news for the sibling.**
`hid-steam.c` unregisters from `steam_client_ll_open()` — the *open* path, not
probe. So if `open()` fails at the VFS permission layer the callback is never
reached and the input devices survive. **The sibling's premise is sound.** My
objection is entirely about Gaming Mode, not about whether the trick works.

**And there is a known working implementation of it**, which the sibling should
read rather than reinvent: the accepted workaround in
[steam-for-linux#7786](https://github.com/ValveSoftware/steam-for-linux/issues/7786)
is `firejail --noprofile --blacklist=/sys/class/hidraw/ /usr/bin/steam-runtime`
— a **sandbox**, not a udev rule. That is a strictly better shape than a global
permission change, because it is **scoped to the one process** and therefore
cannot touch Gaming Mode at all. A `bwrap` equivalent would do the same, and
`bwrap` ships with `flatpak`/`bubblewrap` in Arch's repos.

🔴 **If the sibling is building the udev-rule form, this is the single change I
would push hardest for: make it a per-launch sandbox instead.** It converts the
disqualifying objection (breaks Gaming Mode, fails unsafe on a missed restore)
into a non-issue, and it removes the need for root at runtime entirely. The
report's own note that it *"completely overrides any Steam Input settings"* is
the honest cost, and it is the same cost the udev form pays.

⚠️ **Note for whoever picks the winner: options 2 and 4 are mutually
exclusive.** Deny Steam the hidraw node and Steam Input never runs, so it emits
no XTEST, so extest has nothing to convert. Only one of these can ship.

### 5 — Steam client settings / launch flags — 🔴 **CLOSED. There is no setting.**

I ranked this fifth expecting it might jump to first. It does not. The research
pass looked and found nothing, and the *absence* is itself well-evidenced:

* **No launch flag or env var stops Steam opening the hidraw node.**
  [steam-for-linux#11215](https://github.com/ValveSoftware/steam-for-linux/issues/11215)
  is a standing request for exactly this, **open since 2024 with zero comments**.
  #13217 asks for a "Raw HID/SDL3 pass-through" mode. A two-year-old unanswered
  feature request is strong evidence the feature does not exist.
* **`SDL_JOYSTICK_HIDAPI_STEAM` / `_STEAMDECK` are real SDL hints but govern
  SDL applications — i.e. games — not the Steam client**, whose controller stack
  is not SDL. **Do not assume these help.** This was my own leading candidate and
  it is wrong.
* **Disabling the desktop layout in Steam's UI** (Settings → Controller →
  Desktop Layout → *Disable Steam Input*) is a **FORUM CLAIM**, untested, and
  almost certainly **actively harmful here**: Steam still holds the hidraw node,
  so `hid-steam` still has no input devices — you would trade an invisible
  pointer for *no* pointer, and lose fact 5's escape hatch with it.
* `steam_dev.cfg` — no controller/hidraw key documented anywhere.

⚠️ **P20 said this already and was right:** *"that is also why no Steam setting
helped — there was no setting to find."* I re-ran the search at higher effort and
got the same answer.

**One Steam setting does matter, in the opposite direction:** Settings →
Interface → **"Use experimental SteamRT3 Steam Client" must stay OFF** or extest
silently stops working (§B.8). That is a setting to *watch*, not to set.

### 6 — A compositor-side solution (libei / EIS)

There *is* a real upstream design for exactly our problem, and it is worth
understanding because it is what makes extest obsolete one day.

**READ-SOURCED (documentation, not code):** XWayland has supported translating
**XTEST into libei events since XWayland 23.2.0**, so that emulated input from
X11 clients can reach a Wayland compositor through a `libeis` server rather than
dying inside the nested X server
([who-t on libei](http://who-t.blogspot.com/2020/08/libei-library-to-support-emulated-input.html),
[Phoronix](https://www.phoronix.com/news/LIBEI-Emulated-Input-Wayland)).
**That is precisely the gap R-53 measured.**

**Why it does not help us today, three reasons:**

1. **`xdg-desktop-portal-hyprland` implements no `RemoteDesktop` interface at
   all** — only `Screenshot`, `ScreenCast`, `GlobalShortcuts`, `InputCapture`.
   The PR adding it is open since 2026-05; `xdg-desktop-portal-wlr`'s equivalent
   has been open since **March 2023**. **SOURCE** (§C.3).
2. **Hyprland never passes `-enable-ei-portal`.** `src/xwayland/Server.cpp`
   hardcodes the Xwayland argv and there is no config option to change it.
   **SOURCE** (§C.3) — I had this as INFERRED; it is now verified.
3. **Empirically it does not work on this compositor**, which settles it
   regardless of the plumbing: R-53 measured `XTestFakeMotionEvent` accepted
   without error and reaching nothing, with a positive control that caught a
   wrong first run.

Even the permission model is against us: the portal path raises a *"An app is
asking for special permission / Control input device"* dialog, which Bazzite's
users hit the moment extest was removed (§C.3) — a modal dialog is not something
a controller-only handheld should be answering.

⚠️ **The forward-looking risk worth writing down:** if a future Omarchy pulls a
Hyprland + XWayland combination where XTEST *does* reach the compositor natively,
extest and the native path would both be live at once — two pointer sources from
one trackpad. Failing loudly there is on us. **Not actionable now. Listed
because it is the thing that eventually retires option 2.**

### 7 — Accept the limitation, document a controller-only escape

Fact 5 says Steam's own Exit is reachable from the trackpad. Option 1 says the
touchscreen probably is too. Together that is a real, on-device, keyboardless
way out of the trapped state — **for zero code**.

This is not a fix and should not be sold as one. But it is the **floor** the
other options are measured against, and it needs writing into `docs/RECOVERY.md`
and the first-boot help **whatever else ships**, because every other option has
a failure mode that lands the user here.

### 8 — Run Steam nested in gamescope for Desktop use

gamescope is an X11 compositor, so Steam's XTEST works fully inside it. But the
pointer stays confined to the gamescope window and Steam still holds the hidraw
node, so the desktop is no better off. **This is just Gaming Mode in a window.**
Rejected.

### 9 — External mouse / Bluetooth

Works, and is not a shipping answer for a handheld. Worth one line in
`RECOVERY.md`.

---

## E. The one I would bet on, and how I could be wrong

> **Ship option 1 tonight-equivalent (verify the touchscreen, it is already
> installed), then option 2 (extest) as the pointer fix, with the §B.4
> pre-flight — and spike option 3 before either becomes load-bearing.**

**Why extest and not the sibling's hidraw approach:** extest is the only
candidate on the table with a *measured pass on this exact hardware*, its
licence is clean, its delivery mechanism was written by upstream and matches a
pattern we already ship three times, its permission requirement is already
satisfied by a package Steam hard-depends on, and — decisively — **its failure
mode points away from the thing we promised not to break.** If extest fails,
Steam behaves exactly as it does tonight. If the hidraw denial fails, Gaming
Mode has no controller.

**And the research settles what was previously a judgement call: Bazzite ships
exactly this, on Steam Decks, as a headline feature, and has for years** (§C.1).
Six independent reporters on
[steam-for-linux#13185](https://github.com/ValveSoftware/steam-for-linux/issues/13185)
confirm extest fixes *our precise symptom* on Hyprland and niri specifically.
When a solved problem exists and the solution is one we already built, pinned,
licence-gated and measured on our own hardware, taking it is not a close call.

**Copy Bazzite's shape, not their wiring:** a wrapper binary gated on
`[[ "$XDG_SESSION_TYPE" == "wayland" ]]` — which also solves §B.4's panic 2 by
construction, and keeps the preload out of Gaming Mode where it *would* abort —
but wire it via a user-level `.desktop` override rather than Bazzite's in-place
`sed`, which only survives because their filesystem is immutable and ours is not.

### What would have to be true for me to be wrong

1. **The §B.4 panics fire on a real install.** If preloading extest makes Steam
   abort on first trackpad touch, extest drops below the hidraw option
   immediately — "no pointer" is much better than "the app crashes". This is the
   single most likely way I am wrong and it is **five minutes to check**
   (§F experiment 2).
2. **The operator's real requirement is our input layer, not a pointer.** If
   "usable in desktop" turns out to mean STEAM/QAM chords and our OSK working
   while Steam is up, extest does not deliver that and never will — options 3
   and 4 do. I have read the requirement as "the mouse moves". **Worth asking
   them directly in the morning; it is one question and it re-ranks everything.**
3. **The touchscreen already suffices.** If a tap drives Steam and the desktop
   with Steam resident, the operator may simply not need a trackpad pointer, and
   shipping extest would be complexity bought for nothing.
4. ~~**Steam has a setting** (option 5).~~ **Ruled out** — §C/option 5. A
   two-year-old unanswered feature request is as close to proof of absence as
   this kind of question gets.
5. **`hidraw` coexistence turns out to be trivial** — if the report format is
   easy and bytes arrive on a second reader, option 3 dominates everything,
   because it is the only one that makes Steam's ownership *irrelevant* rather
   than *worked around*. I ranked it third only on cost, and cost is the
   estimate I hold most weakly.
6. **SteamRT3 becomes the default before we ship.** extest silently dies under
   it (§B.8). It is opt-in today, but it is Valve's stated direction, and *"our
   pointer fix stops working after a Steam update, silently"* is a bad thing to
   discover in the field. **Whatever we ship must detect that extest failed to
   load and say so**, rather than presenting a dead pointer. That is a
   requirement on the wrapper, not an afterthought.

---

## F. Experiments for tomorrow — exact commands, all reversible

The Deck was off tonight. These are written so the operator or an agent can run
them without re-deriving anything. **Every one states its positive control.**

**Run them in this order.** The first three answer everything that matters and
take about fifteen minutes between them:

| order | # | question | risk |
|---|---|---|---|
| 1st | **1** | does the touchscreen work with Steam up? | none, read-only |
| 2nd | **2** | do extest's panics fire? | opens Steam; recovery is automatic |
| 3rd | **4** | can a second reader get bytes from `hidraw2`? | none, read-only |
| then | 9, 8, 3, 10, 11 | delivery + correctness details | low |
| last | **7** | the sibling's hidraw denial | 🔴 needs root, can break Gaming Mode |
| skip | ~~5~~, ~~6~~ | **already closed by §C** — run only to double-check | none |

Environment preamble for anything touching Hyprland:

```bash
export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr | head -1)
```

⚠️ Do **not** use `hyprctl cursorpos` as an oracle — P39 measured it returning a
frozen value through its own positive control. Read `/dev/input/event*` instead.

### Experiment 1 — does the touchscreen work with Steam resident? *(highest value, zero risk)*

**Read-only. No state change. Do this one first.**

```bash
# with Steam CLOSED (positive control)
timeout 5 cat /dev/input/event10 | wc -c        # operator taps the screen
timeout 5 cat /dev/input/event10 | wc -c        # nobody touches it (negative control)
# then with Steam OPEN, same two reads
```

* Node number must be re-read from `/proc/bus/input/devices` — `FTS3528` has
  moved between `event10`, `event13`, `event14`, `event15` and `event18` across
  sessions (P15/P22/T10/hardware-parity all disagree). **Grep for the name, do
  not hardcode the number.**
* **Expected:** nonzero both times. **Positive control** = the Steam-closed
  read; **negative control** = the untouched read.
* **If nonzero with Steam open:** the escape hatch is real and free. Then have
  the operator actually *tap a button in Steam and a button on the desktop* —
  bytes on a device are not the same as a click landing.
* **If zero with Steam open:** genuinely surprising, and it means something is
  claiming the digitizer too. Report it; it would change the diagnosis.

### Experiment 2 — 🔴 do extest's three panics fire? *(decides the bet)*

**Changes state: launches Steam. Undo = close Steam; P39 measured that recovery
is automatic and clean.**

```bash
# preconditions, all read-only
python3 -c 'import os; os.close(os.open("/dev/uinput", os.O_WRONLY|os.O_NONBLOCK))' \
  && echo "uinput OK" || echo "uinput DENIED -> extest panic 1 WILL fire"
id deck                                    # is `deck` in the input group?
getfacl -p /dev/uinput                     # is there a user:deck:rw- ACL?
wayland-info 2>/dev/null | grep -i xdg_output_manager   # need version >= 3
```

Then, with both libraries staged in `/tmp`:

```bash
LD_PRELOAD=/tmp/libextest-i686.so:/tmp/libextest-x86_64.so \
  nohup steam >/tmp/p40-steam.log 2>&1 &
# operator moves the RIGHT trackpad
grep -i "extest fake device" /proc/bus/input/devices     # positive control: bridge alive
pgrep -c steam                                            # did Steam survive?
grep -iE "panic|RUST_BACKTRACE|ld\.so" /tmp/p40-steam.log
```

* **Outcome A — device appears, Steam alive, pointer moves:** the bet is good.
  Proceed to build the install stage.
* **Outcome B — Steam dies on first trackpad motion, log shows a Rust panic:**
  extest is disqualified until wrapped. Promote option 3 or 4.
* **Outcome C — no device, no panic:** the preload did not take. Check the
  `ld.so` lines; T10 §1 is the guide.
* **Negative control:** launch Steam once *without* the preload first and
  confirm no `extest fake device` appears — otherwise a stale device from a
  previous run reads as a pass.

### Experiment 3 — ABS vs REL, and the coordinate-space question

With extest loaded and the device created:

```bash
DEV=$(grep -A5 'extest fake device' /proc/bus/input/devices | grep -o 'event[0-9]*')
timeout 10 evtest /dev/input/$DEV      # operator moves the right trackpad
```

* Tells us whether Steam sends `XTestFakeMotionEvent` (→ `ABS_X/ABS_Y`) or
  `XTestFakeRelativeMotionEvent` (→ `REL_X/REL_Y`). **Only the absolute path is
  exposed to the logical-size mismatch in §B.3.**
* Cross-check the declared range against XWayland's root:
  `xrandr --current` or `xdpyinfo | grep dimensions` under XWayland vs
  `hyprctl -j monitors` logical size. **They must agree.** If they do not,
  §B.3's silent-offset failure is live.

### Experiment 4 — can our mapper read hidraw alongside Steam? *(decides option 3)*

**Read-only. 30 seconds. This is the cheapest high-information test on the list.**

```bash
# Steam RUNNING, holding /dev/hidraw2
timeout 5 cat /dev/hidraw2 | wc -c     # operator moving the right trackpad
timeout 5 cat /dev/hidraw2 | wc -c     # nobody touching it (negative control)
```

* **Expected: nonzero, then zero.** Kernel source says every open fd gets a copy
  (§D option 3), so this should just work — but the whole option rests on it.
* **Positive control:** the same read with Steam *closed* and lizard off, where
  reports definitely flow.
* If nonzero, capture 200 bytes and we can start reverse-engineering the report
  layout against `hid-steam.c` offline, with no Deck needed.

### Experiment 5 — is there a Steam setting? *(decides option 5)*

Read-only, from the installed client:

```bash
ls ~/.steam/steam/config/ ~/.local/share/Steam/config/ 2>/dev/null
grep -rn "SteamController\|controller_blacklist\|EnableSteamInput" \
  ~/.local/share/Steam/config/*.vdf 2>/dev/null | head
cat ~/.local/share/Steam/steam_dev.cfg 2>/dev/null
```

Also worth a single manual look in the running client: **Settings → Controller**,
and note verbatim what toggles exist for the built-in Deck controller.

### Experiment 6 — does Hyprland offer an EIS/libei server? *(closes option 6)*

```bash
wayland-info | grep -iE "ei|libei|input_capture|virtual_pointer"
pacman -Q libei 2>/dev/null
Xwayland -version 2>&1 | head -2
```

**Expected: no EI portal.** If one exists, XTEST might reach the compositor
natively and extest becomes unnecessary — a result worth knowing before we ship
a preload.

### Experiment 8 — confirm Steam's main window is XWayland *(cheap, closes an inference)*

Read-only, Steam running:

```bash
hyprctl -j clients | python3 -c '
import json,sys
for c in json.load(sys.stdin):
    if c["class"].startswith("steam"):
        print(c["class"], repr(c["title"]), "xwayland=", c["xwayland"])'
```

* **Expected:** `xwayland= True` for the main `Steam` window.
* **Positive control:** the same command must print `xwayland= False` for a
  Wayland-native client (launch `foot` alongside) — otherwise the field is not
  being read correctly.
* If the main window is somehow **not** XWayland, §A's account of *why* the
  pointer is confined to Steam needs revisiting (the XTEST measurement itself
  would still stand).

### Experiment 9 — does the `.desktop` file actually launch Steam here? *(decides whether option 2 is deliverable at all)*

Read-only:

```bash
grep -rn "steam" /usr/share/omarchy/ ~/.config/walker/ 2>/dev/null | grep -i "exec\|launch" | head
# and, empirically — launch Steam the way a user would, then:
tr '\0' ' ' < /proc/$(pgrep -x steam | head -1)/cmdline; echo
tr '\0' '\n' < /proc/$(pgrep -x steam | head -1)/environ | grep -E "^(LD_PRELOAD|GIO_LAUNCHED_DESKTOP_FILE|WAYLAND_DISPLAY)="
```

* `GIO_LAUNCHED_DESKTOP_FILE` present ⇒ it came through a `.desktop` file, and
  the override path is viable. **This is the positive control**: if that variable
  is absent for *every* app launched from the menu, the test is not looking.
* `WAYLAND_DISPLAY` present ⇒ extest panic 2 will not fire for this launch path.
  Two answers from one command.

### Experiment 10 — is the 64-bit library actually needed? *(the A/B T10 never ran)*

Because §B.8 argues T10's "both are required" is a confounded result, and because
every other distro ships i686 alone.

```bash
# Run A: i686 ONLY, and MOVE THE TRACKPAD before concluding anything.
LD_PRELOAD=/tmp/libextest-i686.so nohup steam >/tmp/p40-a.log 2>&1 &
#   -> operator moves right trackpad for 5 s, THEN:
grep -c "extest fake device" /proc/bus/input/devices
# Run B: both, same procedure.
```

* **Change one variable.** T10 changed two. The trackpad must be moved in *both*
  runs before the device is looked for — that is the whole point.
* **If run A passes:** ship i686 only, matching upstream and every distro, and
  correct T10 in the record.
* **If run A fails and B passes:** T10 was right and this section is wrong. Say so.

### Experiment 11 — is SteamRT3 on? *(the durability check)*

```bash
grep -rn "SteamRT3\|steamrt3\|experimental" ~/.local/share/Steam/config/*.vdf 2>/dev/null | head
```

Plus a manual look at Settings → Interface. **It must be OFF** for extest to
work at all (§B.8). Record the value now so that when it flips we know when.

### Experiment 7 — does denying hidraw actually preserve the pad? *(validates the sibling)*

🔴 **Needs root and it can leave Gaming Mode broken. Do not run this
unsupervised, and write the restore command down before starting.**

```bash
# Steam CLOSED first.
sudo setfacl -m u:deck:--- /dev/hidraw2        # deny
# launch Steam, then:
ls /sys/bus/hid/devices/0003:28DE:1205.0003/input     # positive control: must EXIST
grep -c "Steam Deck" /proc/bus/input/devices          # native pad survived?
# UNDO, unconditionally, before rebooting into Gaming Mode:
sudo setfacl -b /dev/hidraw2 && sudo udevadm trigger --subsystem-match=hidraw
```

* **If `.0003/input` exists with Steam running:** the sibling's mechanism is
  confirmed, and the remaining question is entirely the Gaming Mode conflict.
* **If it does not:** `hid-steam` unregisters somewhere other than the open path
  and option 4 is void.
* **Then reboot into Gaming Mode and confirm the controller works**, because
  that is the failure this option risks and nothing else will surface it.

---

## G. Corrections to our own record, from this pass

1. **`docs/findings/R1-10.3.md` §1 is stale.** It asserts `uaccess` grants no ACL
   to `/dev/uinput`. Measured tonight on an equivalent Arch box: the ACL is
   present (`user:huyke:rw-`) with no seat entry. `src/deck-session.sh:4193`'s
   comment is the correct version. **Do not cite R1-10.3's mechanism.**
2. **R1-10.3's action item — "add the user to `input` at install time" — was
   never implemented**, and its `99-deck-uinput.rules` is not in the repo.
   `/dev/uinput` access on installed Decks is currently an undocumented side
   effect of `steam` hard-depending on `steam-devices`. That works today and is
   a latent single point of failure.
3. **`tools/build-extest.sh` does not copy `LICENSE` into its output.** MIT
   requires the notice to travel with the binary. A one-line defect that becomes
   a real licence violation the moment the `.so` files go on an ISO.
4. **P20's "What this does NOT prove" can be closed.** §A's interception
   argument proves Steam calls `XTestFake*` — the mechanism is measured now.
5. **P39's framing of fact 5 as "the crack in the problem" is, respectfully,
   wrong.** Steam's UI being drivable is not a second input path to redirect; it
   is the *predicted* consequence of XTEST-into-XWayland that R-53 measured a
   month ago. Its value is real but different: it is an **escape hatch**, not a
   mechanism.
6. **T10's "both libraries are required" is probably a confounded result**
   (§B.8). Two variables changed between the failing and passing runs. Every
   other distro on earth ships i686 alone. Flagged, not overturned — §F.10 is
   the A/B that settles it.
7. **`docs/PROGRESS.md` §7 wants a new entry**: the `hid-steam` input-device
   removal is *documented kernel-source intent*, the driver's header comment
   names XTest explicitly, `lizard_mode` is the driver's only parameter and does
   **not** gate it, and writing `lizard_mode=Y` is a **no-op by design** while a
   client holds the node (`steam_param_set_lizard_mode` skips
   `client_opened` devices). Nobody should ever re-investigate this.
8. **`P20-steam-xtest-closure.md`'s remaining open item can be closed.** It left
   R-41's third hypothesis untested — whether the SteamOS integration packages
   (`jupiter-hw-support` et al.) would have helped. **They would not**: SteamOS
   Desktop Mode worked because it was an **X11 session** (§C.2), and no package
   turns Wayland into X11. P20 predicted exactly this; it is now sourced.

---

## H. Open, and honestly not verified

* Whether the touchscreen works with Steam resident. **INFERRED yes. Never
  tested.** (§F.1)
* Whether extest's three panics fire on our install. **Never tested.** (§F.2)
* Whether a second reader gets bytes from `/dev/hidraw2` in practice.
  **SOURCE says yes. Never tested on the Deck.** (§F.4)
* ~~Whether denying hidraw preserves `hid-steam`'s input devices.~~ ✅ **SOURCE-
  CONFIRMED** — the unregister is on the `open()` path. Still worth running §F.7
  end to end, but the mechanism is not in doubt.
* ~~Whether any Steam setting disables controller claiming.~~ ✅ **Closed — there
  is none** (option 5).
* ~~Whether Hyprland exposes any EI/libei path.~~ ✅ **Closed — no RemoteDesktop
  portal, and Hyprland never passes `-enable-ei-portal`** (§C.3).
* Whether the 64-bit extest library is needed at all. **Disputed** (§B.8, §F.10).
* Whether SteamRT3 is enabled on the operator's client, and what we do when
  Valve makes it the default. **Open, and it is the long-term risk.**
* Which of the two motion functions Steam uses. **Unknown**, and it decides
  whether §B.3's coordinate hazard is live. (§F.3)
* The screensaver trap (P39): **untouched by any option here.** A pointer does
  not dismiss `ext-session-lock` if the lock is not listening. This remains
  open and is not addressed by anything in this file.
