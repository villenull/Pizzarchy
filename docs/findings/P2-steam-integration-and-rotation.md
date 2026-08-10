# P2 — Steam integration and rotation, measured on hardware

Session 15, 2026-08-10. Continues the R-numbering from
`docs/findings/P15-live-iso-recon.md` (which ended at R-19).

**What this block set out to do:** resolve §5.10 (Steam's own "Switch to
Desktop" item, never proven), §5.14 (the false first-run update error) and
§5.11 (rotation). All three are resolved. Getting there **corrected four
recorded facts** and uncovered **two defects that would have shipped**, one of
which rebooted the Deck.

Deck state throughout: Omarchy 4.0 `4.0.0.r1617.g6d7826d`, Neptune
`6.11.11-valve29`, Hyprland 0.56.2, reached over `ssh steamdeck`. Snapshot #4
(`pre-P2.0: rotation + steamos-update stub`) precedes every write here.

---

## R-20. ⚠️ NEW OPEN ISSUE — Steam's privileged-helper surface is absolute-path, and mostly missing

This is the finding with the widest consequences, and it reframes §5.14 from
"one missing binary" to "an entire missing integration surface".

Steam drives system functions through helpers it invokes by **absolute path**,
never through `PATH`:

```
PATH="${SYSTEM_PATH-${PATH}}"  /usr/bin/steamos-polkit-helpers/steamos-update check
```

**`/usr/bin/steamos-polkit-helpers/` does not exist on this device.** Every
call returns 127.

Helpers Steam actually invoked, counted from its own logs:

| Helper | Calls | What breaks without it |
|---|---:|---|
| `steamos-set-timezone` | 28 | OOBE's timezone picker silently does nothing |
| `steamos-update` | 22 | The false "check your network" error (§5.14) |
| `steamos-priv-write` | 4 | **Gaming Mode's brightness slider** — it writes `/sys/class/backlight/amdgpu_bl0/brightness` |
| `steamos-devkit-mode` | 4 | Developer mode toggle |
| `jupiter-get-als-gain` | 4 | Ambient light sensor |
| `jupiter-dock-updater` | 3 | Dock firmware updates |
| `jupiter-biosupdate` | 3 | BIOS update check |
| `jupiter-fan-control` | 2 | **Fan control** — P2.3, operator approval per item |

Fourteen are compiled into the Steam client (also `jupiter-check-support`,
`steamos-factory-reset-config`, `steamos-format-device`,
`steamos-format-sdcard`, `steamos-reboot-other`, `steamos-set-hostname`,
`steamos-trim-devices`).

**`steamos-priv-write` connects to an existing finding.** R-14a recorded
"backlight comes up at 1% on the Neptune kernel" as its own oddity. The same
absence explains why Gaming Mode cannot then *fix* it: the helper that writes
the brightness sysfs node is not there.

### Two corrections to R-17

1. ~~"`steamos-update`… provided by no configured repo"~~ — the *binary* is
   indeed unobtainable, but the reasoning named the wrong package.
   **`steamos-customizations-jupiter` is available** in `jupiter-staging`
   (20260721.1-2) and ships **zero** polkit helpers — it is GRUB machinery
   (`etc/grub.d/`, `usr/bin/update-grub`, `holo-grub-*`), which the Limine-only
   constraint forbids anyway. Installing it would never have supplied this.
2. **`jupiter-hw-support` (also `jupiter-staging`) ships six of them** —
   `jupiter-amp-control`, `jupiter-biosupdate`, `jupiter-check-support`,
   `jupiter-dock-updater`, `jupiter-fan-control`, `jupiter-get-als-gain`. It is
   49 MiB / 94 MiB installed and depends on **plymouth** plus a pinned
   `python>=3.14 <3.15`. It carries one inert `etc/default/grub-steamos` file,
   not active GRUB machinery.

The genuinely unobtainable ones are the `steamos-*` helpers:
`steamos-update`, `steamos-priv-write`, `steamos-set-timezone`, and the rest.

### Decision needed (not taken here)

Only `steamos-update` was addressed this session, because it blocked §5.10.
The rest is a scope question for T3/T6, not a detail:

- **`jupiter-hw-support`** would supply six helpers with Valve's own code, at
  the cost of 94 MiB and a plymouth dependency on a Limine-only system.
- **`steamos-priv-write`** has no upstream source available and is the one with
  real user impact (brightness). Writing our own means a root helper that
  writes caller-supplied sysfs paths — Valve's version whitelists paths, and
  ours would have to as well. That is a security design, not a stub.
- **`steamos-set-timezone`** is a genuine three-line helper (`timedatectl
  set-timezone`) and probably the cheapest real win.

---

## R-21. `steamos-update`'s exit-code protocol — and the reboot it caused

Measured, then verified from Steam's own log. Steam calls it three ways:

| Invocation | Correct answer | Why |
|---|---|---|
| `check` | **exit 7** | 7 is "already up to date". **0 means an update IS available**, and Steam calls back to apply it |
| `--supports-duplicate-detection` | **non-zero** | A capability probe. We download nothing, so claiming it invites Steam to rely on absent behaviour |
| (no argument) — apply | **exit 7** | "nothing to apply" |

### ⚠️ The apply path must NOT exit 0 — it reboots the device

The first version of the stub exited 0 on apply, reasoning that it had
"succeeded at doing nothing". Steam read that as a successfully applied OS
update and **rebooted the Deck**:

```
[13:05:50] YieldingApplyUpdateOS: applying OS update
[13:05:50] steamos-update returned: 0
[13:05:50] YieldingApplyUpdateOS: OS update result: 1
[13:05:51] systemd[1]: … systemd-reboot.service has 'start' job queued …
```

Worse than a one-off: **during first-run setup Steam calls apply directly,
without checking first** (seen at 12:17, 12:18, 12:25 with no preceding
`check`). So exit 0 reboots once per OOBE pass — a loop, produced by a stub
whose only job was to silence a cosmetic message.

`src/deck-session.sh` now asserts the apply path is non-zero, so this exact
mistake cannot return quietly.

### Confirmed working

```
[13:08:34] YieldingCheckForUpdateOS: … steamos-update check … returned: 7
[13:08:34] YieldingCheckForUpdateOS: up to date
```

§5.14's false network error is gone, and no reboot followed.

---

## R-22. ✅ R-18a's open question answered: the Steam runtime DOES narrow PATH

R-18a left this open: "worth checking when the menu item is next testable; if
it does, the shim must move to `/usr/bin`." It does.

Read from the running Steam processes' own `environ`:

```
PATH=/usr/bin:/bin
```

`SYSTEM_PATH` is **unset**, so Steam's `${SYSTEM_PATH-${PATH}}` template falls
through to that value. **`/usr/local/bin` is not on it.**

So `steamos-session-select` — which had lived in `/usr/local/bin` since P1.5,
where a local shim conventionally belongs — was invisible to the only caller
that matters. Steam's "Switch to Desktop" could never have worked, regardless
of whether the menu item appeared. §5.10 had one hypothesis (Steam stuck in
OOBE); this was a **second, independent cause**.

The shim now installs to `/usr/bin`, and the stage resolves the *name* against
`PATH=/usr/bin:/bin` in a scrubbed environment rather than testing that a file
exists — the old check passed happily while Steam was blind to it.

---

## R-23. ✅ §5.10 RESOLVED — Steam's own "Switch to Desktop" works

The product's core promise, end to end, through the affordance a user actually
touches.

1. **The item appears once Steam is past OOBE.** §5.10's hypothesis was right:
   it was missing because Steam was stuck in first-run behind §5.14's updater
   error. With the stub in place and the operator signed in, Power →
   **Switch to Desktop** is present.
2. **Steam invokes our shim** — the sudo audit trail, from a Steam working
   directory:
   ```
   sudo: deck : PWD=/home/deck/.local/share/Steam ; USER=root ;
         COMMAND=/usr/local/bin/deck-session-select plasma
   ```
3. **Steam passes `plasma`, not `desktop`** — SteamOS's desktop is KDE. This
   was already handled deliberately (`desktop|plasma|omarchy`), so it worked by
   design rather than luck. Worth knowing before anyone "simplifies" that case.
4. **The switch completes.** gamescope gone, Hyprland up on tty1, rotation
   intact.

Round trip re-verified afterwards using `plasma` explicitly: desktop → gaming →
desktop, sddm active at each end, zero failures.

---

## R-24. Rotation — three corrections, and a second display defect

### transform is 3, not 1

§5.11 and R-19 recorded the fix as `monitor = eDP-1,…,transform,1`. Applied on
hardware, **transform 1 renders the desktop upside down**; **3 (270°) is
correct**. The recorded value was inference that had never been checked against
a screen. Both were tried and looked at.

### The syntax was 3.x — Omarchy 4.0 configures Hyprland in Lua

Not `monitors.conf` but `~/.config/hypr/monitors.lua`:

```lua
hl.monitor({ output = "eDP-1", mode = "preferred", position = "auto", scale = 1.25, transform = 3 })
```

The recorded 3.x line would not have parsed. Note also that Hyprland 0.56's Lua
parser **rejects `hyprctl keyword`** outright — *"keyword can't work with
non-legacy parsers. Use eval."* Live changes go through
`hyprctl eval 'hl.monitor({…})'`, which is how the transform was tested without
writing a file.

The locally-installed `omarchy` agent skill documents the 3.x `.conf` layout
and a `~/.local/share/omarchy/` git tree. Neither matches a **package-based**
4.0 install: defaults live in `/usr/share/omarchy/config/hypr/` and
`/etc/skel/.config/hypr/`, and 4.0 ships its own Lua-aware guidance at
`/usr/share/omarchy/default/agents/skills/omarchy/hyprland.md`. Prefer that.

### NEW: `scale = "auto"` picks 2, leaving a 640×400 desktop

Omarchy's default `omarchy_monitor_scale = "auto"` resolves to **2** on this
panel. Rotated, that is a **640×400 logical desktop** — correct, and
unusable. **1.25** divides 1280×800 evenly → 1024×640 with no fractional
softness. Confirmed comfortable by the operator.

`GDK_SCALE` went **2 → 1** to match: Omarchy ships 2, which suits a panel
driven at scale 2, but against 1.25 it renders GTK apps at roughly 2.5× and
clips them.

### The greeter is a Hyprland instance, so it takes the same fix

```
CompositorCommand=start-hyprland -- --config /usr/share/sddm/hyprland.lua
```

That file is **package-owned by `omarchy-settings-dev`**, so editing it would be
reverted on upgrade. A `zy-` drop-in in `/etc/sddm.conf.d/` repoints
`CompositorCommand` at our own mirror instead. `zy-` sorts after Omarchy's
`10-wayland.conf` (so it wins the key) and before `zz-deck-session.conf`, which
`deck-session-select` rewrites on every switch — a `CompositorCommand` placed
there would vanish at the first session change.

**Verified upright on hardware.** Autologin normally skips the greeter, so
testing it needs the `[Autologin]` section disabled and `sddm` restarted; SSH is
the recovery path, and no password typing is needed to simply look at it.

### Rotation status now

| Surface | Before | Now |
|---|---|---|
| Limine boot menu | ❌ rotated | ❌ **still rotated — no known fix.** First thing a user sees. T5 |
| Console / TTY | ❌ rotated | ❌ unchanged — needs `fbcon=rotate:1`, a boot-chain change held for operator approval |
| SDDM greeter | ❌ rotated | ✅ **fixed and seen** |
| Omarchy / Hyprland | ❌ rotated | ✅ **fixed and seen** |
| Gaming Mode | ✅ correct | ✅ correct (gamescope rotates natively) |

---

## R-25. ⚠️ Hyprland discards an unparseable Lua config SILENTLY

Worth its own entry, because it is `docs/PLAN.md` §8.1's failure mode arriving
from a dependency — and it cost a full debug cycle.

The greeter still rendered rotated after the config was installed. Its
compositor reported `transform: 0, scale: 2` while demonstrably running our
file. Cause: the marker line every generated file carries was
`# installed-by: deck-session.sh` — a **shell** comment — and in Lua `#` is
legal only on line 1 (shebang). Line 2 made the file a syntax error.

**What Hyprland does with a Lua config that fails to parse:** discards the
entire file, falls back to built-in defaults, and logs nothing beyond
`[cfg] Config is lua, loading lua mgr`. No error, no journal entry, exit 0. So
`hl.config()`'s settings were dropped too, and the symptom looked exactly like
"`hl.monitor` has no effect in a greeter context".

Mitigations now in `src/deck-session.sh`: the marker is matched on bare text
with a per-syntax comment prefix (`--` for Lua, `#` for shell/ini), and the
stage runs **`luac -p`** on the generated config and refuses to install it if it
does not parse. `luac` is present on the Deck.

---

## R-26. 🐞 The session switch could permanently kill the display manager

Found by taking the Gaming → Desktop path for real. The switch left the Deck
with **no graphical session at all**, recoverable only via
`systemctl reset-failed sddm` over SSH — exactly what a controller-only user
does not have. In the product this is a black screen with no way back.

> ⚠️ **Session 16 corrected the mechanism below and the fix rationale with it.**
> The first domino is **the stop timing out**, which this section missed, and
> `RestartSec` turns out not to gate the fatal start at all. Read §R-27 before
> relying on anything in the rest of this section.

Mechanism, from sddm's shipped unit:

```
StartLimitIntervalSec=30    StartLimitBurst=2    RestartSec=100ms
```

1. `deck-session-select` restarts SDDM while gamescope still holds VT1.
2. SDDM's first display attempt raced that teardown → `HELPER_TTY_ERROR`,
   greeter crashed (`sddm-helper exited with 5`, then `crashed (exit code 1)`).
3. systemd retried **100 ms** later — far too soon for the VT to be free — so
   that failed too.
4. Two failures inside 30 s exhausted the burst:
   `Start request repeated too quickly` → `start-limit-hit` → unit `failed`,
   permanently.

A transient, self-healing condition was converted into an unrecoverable one by
a rate limit.

**Fix** (`stage-sddm-resilience`): a systemd drop-in with
`StartLimitIntervalSec=0` and `RestartSec=3`. RestartSec is the more important
half — at 100 ms every retry is guaranteed to land before the VT is free, so the
burst is spent on attempts that could never have succeeded.

**Tradeoff, deliberate:** with no rate limit, a genuinely broken SDDM config
retries forever instead of stopping. On a keyboard-less device, a loop that can
still recover beats a black screen that cannot, and a broken config is a
dev-time failure visible in the journal either way.

**Honest limit on the verification:** the round trip afterwards completed
cleanly *without the race recurring*. So what is proven is that the latch is
gone — systemd reports `StartLimitIntervalUSec=0`, `RestartUSec=3s` — not that
the recovery path was exercised. The race is intermittent; P1.5's R-18 hit the
same switch successfully and never saw it.

**Root cause not addressed:** the restart is still issued from inside the
session being torn down. Decoupling it (a transient `systemd-run` unit, so the
caller is not killed mid-restart) would reduce the chance of the race rather
than only surviving it. Left as follow-up. **→ done in §R-27.**

---

## R-27. §5.16's real mechanism — the stop times out, and `RestartSec` never applied

Session 16, from the journal of the boot on which R-26's failure occurred.
R-26 reasoned from sddm's restart policy without reading the stop:

```
13:11:02.815  sddm: Signal received: SIGTERM
13:11:07.822  sddm: sddm-helper (start-gamescope-session) crashed (exit code 1)
13:11:07.823  systemd: sddm.service: State 'stop-sigterm' timed out. Killing.
13:11:07.823  systemd: Killing process 939 (sddm) with signal SIGKILL
13:11:07.826  systemd: sddm.service: Failed with result 'timeout'
13:11:07.830  systemd: Started Simple Desktop Display Manager        <- +3 ms
13:11:11      systemd: Start request repeated too quickly -> start-limit-hit
```

`TimeoutStopUSec=5s`; the teardown took **5.008 s**. So the first domino is not
the retry spacing, it is that **a Gaming Mode teardown does not fit in sddm's
stop timeout** — Steam is slow to exit — and systemd SIGKILLs sddm mid-teardown.
The start job then runs **3 ms** later against a VT the killed compositor was
still holding.

**Two corrections to R-26:**

1. **`RestartSec` does not gate the fatal start.** R-26 called `RestartSec=3`
   "the more important half", reasoning that at 100 ms every retry lands before
   the VT is free. But that start came from an explicit `systemctl restart`
   transaction, and `RestartSec` only spaces `Restart=always` auto-restarts —
   which is why the measured gap was 3 ms, not 100 ms. The shipped drop-in
   helped the *retry* path and never touched the cause.
2. **It is not switch-specific.** This occurrence was at **boot**, not during a
   session switch. Any sddm restart whose teardown overruns 5 s can do it.

**Fix, three parts** (`src/deck-session.sh`):

| Part | What | Why |
|---|---|---|
| `TimeoutStopSec=30` | in the sddm drop-in | lets the teardown finish instead of being killed — this is the cause |
| stop → settle → start | `render_restart_helper`, replacing `systemctl restart sddm` | a start can never be issued 3 ms after a kill |
| `systemd-run --collect` transient unit | `deck-session-select` | sddm's `KillMode=control-group` kills a caller inside the session being torn down |

The settle step waits on **`loginctl show-seat seat0 -p Sessions`**, not
`fuser /dev/tty1`: `systemd-logind` holds `/dev/tty1` permanently, so a
fuser-based check reports the VT busy forever and would always run to its
bound. The loop is bounded (5 s) and, on hitting the bound, says so and starts
sddm anyway — a stuck seat must not mean the display manager is never started
again, which is the same black screen by another route.

`stage-sddm-resilience` now **fails** rather than warns if `TimeoutStopSec` did
not resolve to 30 s, since that is the directive doing the real work.

---

## What this block changed in the code

All in `src/deck-session.sh`, which grew from four install stages to six. Every
stage verifies its own effect by running something:

| Stage | Verifies |
|---|---|
| `stage-steam-hook` | the name resolves on `PATH=/usr/bin:/bin`, in a scrubbed env |
| `stage-update-stub` | `check` → 7, capability probe declines, **apply is non-zero** |
| `stage-greeter-rotation` | generated config parses (`luac -p`); ours is the *last* `CompositorCommand` in the drop-in dir |
| `stage-sddm-resilience` | the values **systemd resolved**, not the file contents |

Shared `assert_ours_or_absent()` refuses to clobber a file this project did not
write; deliberate-failure tested with a planted foreign `steamos-update`, which
failed the stage loudly and survived untouched.

Full script re-run end to end on the configured Deck: all six stages
idempotent, no errors.
</content>
