# T14 — the power button in GAMING MODE: does T13's fix already cover it?

**Research output. The work spec is `docs/tasks/T14-gaming-mode-power-button.md`;
this file is the evidence behind it.** Written 2026-08-12, session 22, alongside
T13 and deliberately narrow: T13 owns Desktop Mode, the udev untag, the logind
drop-in and the sleep-lock mask. **T14 owns exactly one question** — whether
Gaming Mode needs anything of its own, and specifically whether
`steamos-powerbuttond` has to be shipped.

## 0. How to read this file

Same three tags as `docs/findings/T13-power-button-and-sleep.md` §0, and for the
same reason:

| Tag | Means |
|---|---|
| **READ** | I opened the file or man page and quote it. Path or URL given. |
| **MEASURED** | An instrument was run against real hardware and the output recorded. Cited to the run. |
| **INFERRED** | I reasoned to it. **It may be wrong.** Where it matters, the discriminating measurement is named. |

Everything tagged MEASURED below was taken **read-only over `ssh steamdeck` on
2026-08-12**, with the Deck sitting in **Desktop Mode** (Hyprland running, Steam
not running), while the operator was busy. **Nothing was started, stopped,
masked, installed or written**, and no button was pressed. That constraint is
also this file's biggest limitation and §3 says exactly where it bites.

---

## 1. 🔴 THE ANSWER, first, because it decides the rest

> **Yes. T13's fix already covers Gaming Mode, and we should ship nothing
> extra.** `steamos-powerbuttond` is not needed, and shipping it would make
> Desktop Mode *worse*, not Gaming Mode better.

The argument in five steps, tags attached:

1. **logind is a system service with one config for the whole machine.** It is
   not per-seat, per-session or per-compositor. Its drop-in directory is read
   once, and the property is a *manager* property, not a session property —
   `busctl get-property org.freedesktop.login1 /org/freedesktop/login1
   org.freedesktop.login1.**Manager** HandlePowerKey`. **READ** + **MEASURED**
   (§2.1).
2. **logind's power-key watch is scoped by a udev tag and by nothing else —
   and this is now READ FROM SOURCE, not just from the man page.** logind opens
   the input device itself (`src/login/logind-button.c`, `button_open()` →
   `sd_event_add_io(…, button_dispatch, …)`), and the only gate is
   `sd_device_has_current_tag(d, "power-switch")` in
   `manager_process_button_device` (`src/login/logind-core.c:347`).
   `button_dispatch` → `manager_handle_action` performs **no session-activity
   check at all**; the `seat` argument is used only for
   `HandleSecureAttentionKey=`. **READ**, `github.com/systemd/systemd`. The man
   page says the same in one line: *"Only input devices with the `power-switch`
   udev tag will be watched for key/lid switch events."*
   ➡️ **Whether the active session is gamescope, Hyprland, a VT, or nothing at
   all is irrelevant to logind.** That is the answer to the headline question,
   from the implementation.
3. **The only way to suppress `Handle*=` is a low-level `handle-power-key`
   inhibitor,** it is **block-mode only** (`src/login/logind-dbus.c:3702-3705`
   rejects `delay` for anything but shutdown/sleep — READ), and **only a lock
   held by the *active* session counts** — `manager_handle_action` passes
   `MANAGER_IS_INHIBITED_IGNORE_INACTIVE` (`src/login/logind-action.c`, READ).
   ⚠️ With one exception that matters: a lock held by a **system service** has no
   session and is treated as globally active (`logind-inhibit.c:393-395`, READ).
4. 🔴 **Nothing in our Gaming Mode takes one, and this is now READ rather than
   assumed.** A full-tree grep of `ValveSoftware/gamescope` for
   `inhibit|logind|login1|PrepareForSleep|power.?key|sd_bus` finds **no
   `org.freedesktop.login1` string and no `Inhibit(` call anywhere** — its only
   session use is `wlr_session_*`, i.e. libseat device/DRM-master handover, which
   is a different thing entirely. Valve's `gamescope-session` scripts and units:
   **zero hits** for the same pattern. `powerbuttond` itself: no D-Bus, no
   inhibitor. All **READ** (§3.2). The Steam client remains unreadable — and
   §3.2's direct bug-report evidence covers it.
5. **The residual hole is one press wide, and T13 is already going to the
   hardware.** The check is `systemd-inhibit --list` in Gaming Mode plus one
   button press — two rows appended to a session that is happening anyway, for
   zero extra trips (§6).

🔴 **One correction to the shape of the risk, and it changes what to look for.**
The thing most likely to nullify `HandlePowerKey=suspend` in Gaming Mode is
**not** a `handle-power-key` lock. It is an ordinary **block-mode `sleep`**
inhibitor — see §6 step 2. That check is the one that matters, and it is the one
nobody had named.

**What this buys, stated plainly:** a package we do not have to redistribute, a
user unit we do not have to reason about, and a Desktop Mode design that stays
the single simple one T13 already built. That is a real outcome and it is the
recommendation.

⚠️ **Where this is still a guess.** Steps 1–4 are READ or MEASURED. What is
*not* covered by any of them is (a) whether the **Steam client** — the one
unreadable component — behaves in Gaming Mode the way §3.2a's bug report says it
does on somebody else's handheld, and (b) whether a **block-mode `sleep`** lock
is present during ordinary use. **Neither has been observed on this Deck**, and
`systemd-inhibit --list` has never been run in Gaming Mode at all. §6 step 1 and
step 2 close both; §7 lists what would overturn the recommendation.

---

## 2. What was measured on the Deck today

All read-only, all 2026-08-12, Deck in Desktop Mode.

### 2.1 logind's live state

```
$ busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
    org.freedesktop.login1.Manager \
    HandlePowerKey HandlePowerKeyLongPress HandleLidSwitch
s "ignore"
s "ignore"
s "suspend"
```
**MEASURED.** Three things follow:

- `HandlePowerKey=ignore` is live *as logind parsed it*, not merely present in a
  file. This is the T13 §2.1 chain confirmed at the far end.
- `HandlePowerKeyLongPress=ignore` is systemd's own default and nothing overrides
  it — so today there is no long-press path in either mode.
- 🔴 **`HandleLidSwitch=suspend` is live and unoverridden.** Already flagged in
  T13 §4.2 as "two consumers, one of them undocumented". Restated here only
  because it is the one logind action that *is* currently armed on this machine,
  which makes it the closest thing to a control we have for "does logind act at
  all here".

Also **MEASURED**, and worth recording because it removes a possible
verification instrument: `PowerKeyIgnoreInhibited` is **not exposed on the D-Bus
Manager interface** —

```
Failed to get property PowerKeyIgnoreInhibited on interface
org.freedesktop.login1.Manager: Unknown interface … or property …
```

so that one setting cannot be read back the way §2.1's three can. If it is ever
set, the readback has to be a file read plus a `systemd-analyze cat-config`, and
the project should say so rather than assume symmetry. *(The same run is the
negative control T13 step 2 asked for: an unknown property name fails loudly with
exit 1. It does.)*

`systemd 261 (261.2-1-arch)` on the Deck; `261.1-1-arch` on the dev workstation.
**MEASURED**, both. The man page quoted throughout is therefore the right one.

### 2.2 The inhibitor picture, in Desktop Mode

```
$ systemd-inhibit --list --no-pager
WHO            UID USER PID  COMM           WHAT  WHY                                        MODE
NetworkManager 0   root 736  NetworkManager sleep NetworkManager needs to turn off networks   delay
UPower         0   root 1134 upowerd        sleep Pause device polling                        delay
2 inhibitors listed.
```
**MEASURED.** Two facts, and the second is new:

1. **No `handle-power-key` lock is held** — in Desktop Mode, with Steam not
   running. This does not answer the Gaming Mode question; it establishes the
   baseline the Gaming Mode reading will be compared against.
2. Both existing locks are **`sleep` / `delay`**, and `delay` is harmless:
   logind waits out `InhibitDelayMaxSec` (raised to 15 s by Omarchy's
   `20-inhibit-delay.conf`, T13 §5.2) and then suspends anyway.

### 2.3 The session shape is identical in both modes — which is why (1) generalises

```
$ loginctl show-session 1 -p Id -p Seat -p Type -p Class -p Active -p State
Id=1  Seat=seat0  Type=wayland  Class=user  Active=yes  State=active
$ pgrep -a -u deck -x 'Hyprland|start-hyprland|gamescope-wl|start-gamescope|uwsm|steam'
1031 /usr/bin/start-hyprland
1036 Hyprland --watchdog-fd 4
```
**MEASURED.** Desktop Mode is a single active `wayland` session on `seat0`,
started by SDDM autologin on tty1. Gaming Mode is the **same shape** — SDDM
autologin, same seat, same class, a different `Session=` — because
`deck-session-select` switches SDDM's session and restarts it
(`src/deck-session.sh:1027-1053`, READ). **Only the compositor process differs.**

➡️ Since logind's power-key path is scoped by the udev tag and by nothing else
(§1 step 2, **READ from systemd's source**), and the tag is unchanged across the
switch, **the mechanism cannot tell the two modes apart.** This paragraph was
drafted as INFERRED and was **promoted to READ** when `logind-core.c` and
`logind-button.c` were actually opened: there is no session-activity check on the
button path. The session shape above is now corroboration, not the argument.

### 2.4 The udev tagging is stock and unconditional

```
# /usr/lib/udev/rules.d/70-power-switch.rules   (systemd, LGPL-2.1-or-later)
SUBSYSTEM=="input", KERNEL=="event*", ENV{ID_INPUT_SWITCH}=="1", TAG+="power-switch"
SUBSYSTEM=="input", KERNEL=="event*", ENV{ID_INPUT_KEY}=="1",    TAG+="power-switch"
```
**READ**, from the Deck. No session or seat condition anywhere in the file. This
is why T13's `zz-deck-power-button.rules` untag is the correct lever and why it
is a *system* lever: it changes what logind watches, in both modes at once, from
before either compositor starts.

⚠️ **And it is the lever's limit.** The `power-switch` tag steers **logind only**.
It does not hide a node from libinput, and therefore not from Hyprland or
gamescope. Untagging the ACPI node does **not** stop a compositor receiving the
second `XF86PowerOff`. §4.3 is where that bites.

---

## 3. `steamos-powerbuttond` — what it actually is, measured from the Deck's own package database

The T13 finding says it is "in none of our three package lists", which is true.
What nobody had checked is whether it is *reachable*. It is.

### 3.1 It is one `pacman -S` away, and the licence is clean

```
$ pacman -Si holo-staging/steamos-powerbuttond
Repository      : holo-staging
Name            : steamos-powerbuttond
Version         : 4.2-2
Description     : Power button daemon for SteamOS
URL             : https://gitlab.steamos.cloud/holo/powerbuttond
Licenses        : BSD
Provides        : powerbuttond
Depends On      : libevdev  udev  gamescope
Download Size   : 10.62 KiB
Installed Size  : 20.79 KiB
Build Date      : Fri Jul 31 02:21:35 2026
```
**MEASURED** (read-only `pacman -Si`, no sync, against the sync DB already on the
Deck, dated 2026-08-05).

```
$ pacman -Fl steamos-powerbuttond
usr/lib/hwsupport/steamos-powerbuttond
usr/lib/systemd/user/steamos-powerbuttond.service
usr/lib/systemd/user/gamescope-session.service.wants/steamos-powerbuttond.service
usr/lib/udev/hwdb.d/70-steamos-power-button.hwdb
usr/lib/udev/rules.d/70-steamos-power-button.rules
usr/share/licenses/steamos-powerbuttond/LICENSE
```
**MEASURED.** Six things this settles, four of them new:

| # | Fact | Why it matters |
|---|---|---|
| 1 | **`Licenses: BSD`, and it ships `/usr/share/licenses/…/LICENSE`** | 🔴 **The redistribution objection does not apply** — see §3.1a, where this is nailed down from Valve's source. This is the `gamescope` (MIT) posture, not the `steamdeck-dsp` (`Proprietary`, *no licence text at all*) posture that `docs/findings/P16-redistribution-and-trademark.md` §1 flagged as the one genuine blocker. `CLAUDE.md`'s "don't depend on anything unlicensed or AUR-only" is **satisfied** |
| 2 | It is in **`holo-staging`**, which `iso/overlay/patches/deck-valve-repos.patch:46-48` already configures on every target (READ) | No new repo needed. ⚠️ Note for anyone who does adopt it: `jupiter-main` **froze at 3.1-2** and every version from 3.2 to 4.2-2 lives in the **`holo-*`** component (READ, directory listings of both). Pulling from `jupiter-*` gets a three-year-old build |
| 3 | 10.6 KiB download, 20.8 KiB installed | The offline-mirror size gate (T5g) would not notice it |
| 4 | 🆕 It carries its **own** hwdb *and* udev rule | The `STEAMOS_POWER_BUTTON_IGNORE=1` blacklist T13 §4.1 read out of Valve's source **comes with the package** — it is not stranded in `jupiter-hw-support`, which we deliberately do not install. Confirmed by `pacman -Fx '70-steamos-power-button'`, which names this package and no other (**MEASURED**) |
| 5 | 🆕 It self-enables via a **package-shipped `.wants` symlink** under `gamescope-session.service.wants/` | No `systemctl enable` step. Installing it is sufficient to arm it — which cuts both ways: it is also sufficient to arm it *by accident* |
| 6 | `Depends On: … gamescope` | We already carry `jupiter-staging/gamescope`. No new dependency of consequence |

⚠️ `holo-staging` is configured `SigLevel = Never`
(`iso/overlay/patches/deck-valve-repos.patch:48`, READ). Already true for
`jupiter-staging/gamescope`, so this adds no new class of exposure — but it means
the pacman metadata above is not cryptographically verified. §3.1a is the
independent confirmation that removes the doubt.

### 3.1a The licence, nailed down from Valve's source — **BSD-2-Clause, four ways**

The pacman field says `BSD`, which is Arch's *legacy* spelling and ambiguous
between the 2-, 3- and 4-clause texts. It resolves cleanly:

| Evidence | Says | Tag |
|---|---|---|
| `powerbuttond.c`, first line: `// SPDX-License-Identifier: BSD-2-Clause`, `// Copyright (c) 2023-2025 Valve Software` | BSD-2-Clause | **READ** — `raw.githubusercontent.com/evlaV/steamos-powerbuttond/master/powerbuttond.c` |
| A `LICENSE` file exists at the repo root: *"Copyright (c) 2023, Valve Software"* + the standard two-clause text, **no** advertising clause and **no** endorsement clause | BSD-2-Clause | **READ** — same repo |
| Valve's own PKGBUILD: `license=('BSD')`, `url="https://gitlab.steamos.cloud/holo/powerbuttond"` | (the loose spelling) | **READ** — `gitlab.com/evlaV/holo-PKGBUILD/-/blob/master/steamos-powerbuttond/PKGBUILD` |
| Jovian-NixOS: `meta = { … license = licenses.bsd2; }` — and nixpkgs *requires* a licence field, so this is a third party who had to decide | BSD-2-Clause | **READ** — `Jovian-Experiments/Jovian-NixOS`, `pkgs/powerbuttond/default.nix` |

And the obligation is discharged automatically, which is worth recording because
it is the thing `steamdeck-dsp` fails: Valve's Makefile has **`install: all
LICENSE`** as a hard prerequisite and installs the file to
`/usr/share/licenses/steamos-powerbuttond/LICENSE` (**READ**) — which is exactly
the path our own `pacman -Fl` saw in the shipped package (§3.1). Both routes,
build-from-source and redistribute-Valve's-binary, satisfy BSD clause 2 with no
extra work.

**Canonical upstream is public**: `gitlab.steamos.cloud/holo/powerbuttond`
(`visibility: public`, tags to `v4.2` — **READ** via the GitLab API), mirrored at
`github.com/evlaV/steamos-powerbuttond` with a byte-identical 7-file tree. The
binary repo is anonymously fetchable over plain HTTP, no auth (**READ** — a
10,895-byte `HTTP 200`).

**It is also in the AUR** (`steamos-powerbuttond` 4.2-1, `license=('BSD-2-Clause')`
— **READ** via the AUR RPC). ⚠️ **This does not trip `CLAUDE.md`'s "no AUR-only"
rule**, which bars things available *only* via AUR; here the AUR entry is a
redundant third path behind Valve's own repo and Valve's own source. It should
still not be *used* — zero votes, zero popularity, single unaffiliated
maintainer.

➡️ **Conclusion: the redistribution question closes in powerbuttond's favour.**
If this decision turned on licensing, we would ship it. It does not — §4 is why.

### 3.1b Two things in the source that argue against it on their own merits

Both **READ**, from `powerbuttond.c` and its shipped unit:

1. 🔴 **It fails silently.** The one action function builds a hardcoded path,
   `snprintf(steam, …, "%s/.steam/root/ubuntu12_32/steam", getenv("HOME"))`, and
   spawns it — and on failure does exactly this:
   ```c
   if (posix_spawn(&pid, steam, NULL, NULL, args, environ) < 0) {
   		return;
   }
   ```
   No log, no error, no fallback. Every one of the five action paths in the
   program (`shortpowerpress`, `longpowerpress` ×3, `lidswitch`) terminates in
   that function and in nothing else — **no D-Bus, no logind call, no direct
   suspend, no configurable handler.** A wrong `HOME`, or a Steam that is not at
   that exact FHS path, yields a power button that does nothing and says nothing.
   ⚠️ That is precisely the behaviour `CLAUDE.md`'s "never silently swallow a
   failure" exists to keep out, and it is a *third-party* binary, so we could not
   fix it without carrying a patch. **Jovian-NixOS carries exactly such a patch**
   (`jovian.patch`, replacing the hardcoded path with a substituted handler —
   READ), which is the strongest possible confirmation that the path is a real
   problem in practice and not a theoretical one.
2. **`Requisite=gamescope-session.service`** in `steamos-powerbuttond.service`,
   confirmed by reading the unit itself rather than second-hand. `Requisite`, not
   `Requires` — it *fails immediately* if gamescope-session is not already
   active and will not pull it in. Structurally Gaming-Mode-only, enforced by
   systemd. §4.4.

### 3.1c 🆕 Valve's hwdb independently confirms our node choice

The hwdb sets `STEAMOS_POWER_BUTTON=1` broadly on lid / `KEY_POWER` / `KEY_F16`
devices, then adds (**READ**, `steamos-power-button.hwdb`):

```
evdev:name:Power Button:dmi:*svnValve:pnJupiter:*
evdev:name:Power Button:dmi:*svnValve:pnGalileo:*
 STEAMOS_POWER_BUTTON_IGNORE=1
```

and `find_devs()` skips any device carrying it (**READ**). Note the match key:
**the device *name* `Power Button`** — which on our Deck is `event0` and `event2`,
the two ACPI nodes, and **not** `event4` ("AT Translated Set 2 keyboard").

➡️ So Valve's daemon, on **Galileo** — the operator's exact model — binds the same
node T13's udev rule keeps, and ignores the same two T13's rule untags. **Three
independent routes to one answer now** (Valve's hwdb, Valve's design as read by
Jovian, and our own n=3 capture). Whatever else is uncertain here, *which node is
the real power button on this hardware* is not.

⚠️ **Still not read**: `steamos-power-button.rules`, the third file in that
package, which lands in `/usr/lib/udev/rules.d/` and therefore applies in
**Desktop Mode too**. It is presumably the `IMPORT{builtin}="hwdb"` glue for the
above, but presumably is not read. §6 step 4. **Only matters under Option B.**

### 3.2 Who takes a `handle-power-key` lock — answered by grepping, not by guessing

🔴 **Correction to an earlier draft of this file, recorded because it was nearly
load-bearing.** This section originally called ChimeraOS a clean natural
experiment: `HandlePowerKey=suspend`, Steam in gamescope, no powerbuttond. **The
last clause is false.** ChimeraOS's `manifest` also ships
`steam-powerbuttond-git` (ShadowBlip's fork) and enables it in `SERVICES=`
(**READ**). So ChimeraOS runs logind suspend **and** a Steam notification, and it
proves nothing about bare logind suspend. *That is exactly the shape of error
this project has paid for before — an argument built on an unchecked negative.*

**What the source actually says.** Every component in our Gaming Mode path was
grepped in full:

| Component | Result | Tag |
|---|---|---|
| **`ValveSoftware/gamescope`** | Full-tree grep for `inhibit\|logind\|login1\|PrepareForSleep\|power.?key\|KEY_POWER\|sd_bus`: **no `org.freedesktop.login1` string, no `Inhibit(` call anywhere.** Only an SDL screensaver hint (nested mode) and a scancode-table entry. Session use is `wlr_session_create/open_file/change_vt` — libseat device and DRM-master handover, not inhibitors. Its libinput path uses a plain `open()` with **no `EVIOCGRAB`**, so it cannot starve logind's own read of the device either | **READ** |
| **Valve's `gamescope-session`** (`evlaV/jupiter/gamescope/*`: the script, `start-gamescope-session`, the units, `PKGBUILD`, `.install`) | **zero hits** for `inhibit\|powerbutton\|handle-power\|logind\|login1` | **READ** |
| **`steamos-powerbuttond`** | Opens the device `O_RDONLY\|O_NONBLOCK`, watches `KEY_POWER`, `posix_spawn`s Steam. **No `EVIOCGRAB`, no D-Bus, no `Inhibit`.** Valve suppresses logind with a *config file*, not a lock | **READ** |
| **`ChimeraOS/gamescope-session-plus`** | 🆕 **Does** take one — `systemd-inhibit --what=handle-suspend-key:handle-power-key:handle-hibernate-key --who=gamescope-session … sleep infinity` in `device-quirks:141-169` — **but only inside `if command -v /usr/bin/powerbuttond` / `elif [ -f /usr/lib/hwsupport/power-button-handler.py ]`.** `inhibit_systemd` is called from nowhere else | **READ** |
| **The Steam client** | Not readable. §3.2a | — |

➡️ **Two conclusions.**

1. **Nothing we ship takes the lock.** We run *Valve's* gamescope-session, not
   ChimeraOS's, so the one real `handle-power-key` inhibitor in the ecosystem is
   not even on our machine — and it would be skipped anyway, because it is gated
   on a powerbuttond binary being installed, which by construction it is not.
2. **The Jovian row survives and is now the only downstream argument left
   standing.** Jovian-NixOS sets `HandlePowerKey=ignore` with the comment
   **"Conflicts with powerbuttond"** (**READ**, `modules/steam/steam.nix`). A
   conflict is only possible if logind's handler **does** fire in Gaming Mode.
   You cannot collide with something that is inhibited.

For completeness, the other two downstreams both implement **Valve's** design and
so say nothing about ours: **Bazzite** ships `HandlePowerKey=ignore` +
`KillUserProcesses=true` in `system_files/deck/shared/etc/systemd/logind.conf.d/deck.conf`
and installs Valve's daemon with `systemctl --global enable
steamos-powerbuttond.service` in its `Containerfile` (**READ**, both).

### 3.2a The Steam client — the one direct piece of evidence, and it is a good one

Steam is closed source and cannot be grepped. But somebody ran our exact
configuration and filed a bug about it:

> **`ValveSoftware/steam-for-linux#11629`** — *"Suspend/wake animations do not
> play when using physical power button via `HandlePowerKey=suspend`"*, opened
> 2025-01-04, **closed 2025-02-20 as completed**. Body: *"triggering suspend via
> the power button on other handhelds with `HandlePowerKey=suspend` results in no
> suspend or wake animation being played. Instead, the screen just fades to
> black on suspend"*. Its only comment, from a Bazzite maintainer: **"the Steam
> client does not monitor the power button"**. **READ.**

➡️ This is worth more than any amount of distro archaeology, and it settles two
things at once:

- **`HandlePowerKey=suspend` demonstrably works with Steam running** — the
  reporter's Deck *did* suspend. If Steam held a `handle-power-key` lock, there
  would have been no suspend to complain about and no animation question.
- 🔴 **The entire reported downside of doing it our way is cosmetic**: a missing
  suspend/wake *animation*. Not a lost download, not a broken save, not a hung
  client. That is the best available answer to "what is lost without Steam
  mediating" (§4.2a), and it is a first-hand report rather than an inference.

⚠️ **Still not a measurement of our machine**, and one report is one report.
§6 step 1 and step 3 are what close it, and they are cheap.

---

## 4. Why shipping powerbuttond would be a *downgrade*, not an addition

This is the part the redistribution check does not reach, and it is the actual
argument.

### 4.1 🔴 It is mutually exclusive with T13's Desktop Mode fix. One machine, one logind config.

- powerbuttond **requires** `HandlePowerKey=ignore`. That is Valve's own setting
  (T13 §4.1, READ) and Jovian says why in one word: *conflicts*. Leave
  `HandlePowerKey=suspend` on and every press in Gaming Mode does the action
  **twice** — logind suspends, and Steam is simultaneously asked to suspend.
- T13's Desktop Mode fix **requires** `HandlePowerKey=suspend`.
- `logind.conf.d` is read once for the machine (§1 step 1). **There is no
  per-session value.** You cannot have both.

So "add powerbuttond for Gaming Mode" is not additive. It forces a choice, and
choosing it means **rebuilding Desktop Mode on a different mechanism** — §4.3.

*(A third option — rewriting the drop-in and `systemctl reload systemd-logind` on
every session switch — is named only to reject it: a config race on the input
path of a device with no keyboard, in exchange for nothing. Do not build it.)*

### 4.2 What is actually lost without Steam mediating is **the long press**, and almost nothing else

This is the finding that shrinks the whole question, and it comes from reading
what powerbuttond sends rather than assuming what Steam does with it.

`powerbuttond.c`: a press arms `alarm(1)`; a **release before it fires** sends
`steam://shortpowerpress`; **the alarm firing** sends `steam://longpowerpress`
(**READ**, T13 §4.1). And the operator's own description of stock Deck behaviour
(T13 §1 defect 4, and §4.0's table) maps those to:

| Gesture | Stock SteamOS | Option A (logind) | Parity? |
|---|---|---|---|
| **Short press** | suspends | suspends | ✅ **exact** |
| **Long press (~1 s)** | Steam's power menu — Suspend / Shut Down / Restart, controller-navigable | nothing (`HandlePowerKeyLongPress=ignore`) | ❌ **the whole functional gap** |
| **Suspend / wake animation** | Steam plays it, because Steam initiated the suspend | screen fades to black | ❌ cosmetic, and it is the *only* reported downside — §3.2a, READ |
| **~10 s hold** | hard power off (EC, below the OS) | same | ✅ untouched |

⚠️ *What Steam does with each URL is* **INFERRED** *— from the operator's account
of their own device, not from Steam's source, which is not readable. The URLs
themselves are READ.*

➡️ **So the honest framing is: powerbuttond buys a menu, not a safer suspend.**
Both designs terminate in the *same* logind `Suspend()` call — Valve's chain is
`powerbuttond → Steam → logind Suspend()` (T13 §4.2, READ, and the last hop is
logind's either way). Everything downstream of that call — S3 entry, device
re-init, Wi-Fi and GPU resume, whether the panel comes back — is **identical**
between the two options. Nothing about the risky part of suspend is improved by
routing the request through Steam.

### 4.2a Does suspending out from under Steam actually hurt? The evidence, such as it is

The brief asks for evidence, not assumption. Here is what there is, honestly
graded, **strongest first**:

- 🔴 **A first-hand bug report from our exact configuration**, §3.2a. Somebody
  ran `HandlePowerKey=suspend` with Steam in gamescope on a handheld and filed
  the resulting defect. **The defect was a missing animation.** Valve closed it
  as completed. A Bazzite maintainer's one-line explanation — *"the Steam client
  does not monitor the power button"* — is also the mechanism: Steam is not
  watching, so there is nothing for it to be surprised by. **READ.**
- ⚠️ **ChimeraOS is NOT the natural experiment this file first claimed.** They
  ship ShadowBlip's `steam-powerbuttond` alongside `HandlePowerKey=suspend`, so
  their clean record is evidence for *logind suspend plus a Steam notification*,
  not for bare logind suspend (§3.2). **Their tracker's silence grants us
  nothing.** A targeted search for suspend-vs-download/cloud-sync breakage across
  ChimeraOS, Bazzite and `steam-for-linux` returned nothing — **but titles only
  were read, not bodies, and the search was not exhaustive.** Grade: *no
  clearance*, and do not upgrade it.
- **The session survives.** S3 preserves RAM; `gamescope-session` has no
  suspend/resume code and is never torn down (**READ**, T13 §4.2). Steam's
  process, its game and its download state are all still in memory on resume.
  The observable is the same as closing a laptop lid with Steam open.
- **What Steam loses is its TCP connections**, which it re-establishes — the same
  thing that happens on any network drop. **INFERRED**, and the honest ceiling on
  what I can claim without reading Steam.
- **Cloud sync runs at game exit / client exit**, not continuously, so a suspend
  mid-game delays a sync rather than losing one. **INFERRED** — plausible, widely
  believed, and not read out of anything. Do not promote it.

➡️ Net: **no evidence of harm, and a shipping counter-example.** But "no evidence
of harm" is not "evidence of no harm", and §6 step 3's five-cycle test with a
download running is what turns it into a measurement on *our* machine.

### 4.3 The hidden cost of the alternative: Desktop Mode loses its clean lever

If powerbuttond is adopted, `HandlePowerKey` goes back to `ignore` and Desktop
Mode must be driven by a Hyprland bind instead — `o.bind("XF86PowerOff", …,
"systemctl suspend")` in `~/.config/hypr/bindings.lua`, replacing T13's
`hl.unbind`. That path is **strictly worse**, on four counts:

1. 🔴 **The double press comes back, in the compositor.** One physical press
   emits two `KEY_POWER` presses, on `event4` and `event2` (**MEASURED**, T13
   §2.2, n=3). T13's udev untag removes `event2` from **logind's** view — and
   from nothing else (§2.4). Hyprland still receives both; the currently observed
   menu *flash* is the direct proof that it does. A bind to `systemctl suspend`
   would therefore fire **twice, ~198 ms apart** — which is T13's risk R1
   (immediate re-suspend on resume, indistinguishable from a dead Deck) relocated
   into a place T13's fix does not reach. **INFERRED that it fires twice; the
   menu flash is MEASURED and is what the inference rests on.**
2. Suppressing the second event for a *compositor* needs a different and blunter
   udev intervention (`LIBINPUT_IGNORE_DEVICE=1`, or clearing `ID_INPUT*`) that
   removes the node from every Wayland client, not just logind. Larger blast
   radius, and untested here.
3. It reintroduces the dependency on `~/.config/hypr/bindings.lua` **being
   parsed**, on a device where a single Lua syntax error makes Hyprland discard
   the entire file silently with `hyprctl configerrors` still clean
   (`docs/PROGRESS.md` §5.24, and T13 §6.1's whole warning). T13 already accepts
   that exposure for an `hl.unbind` whose failure mode is "the old menu comes
   back". Making *suspend itself* depend on it upgrades the failure from cosmetic
   to functional.
4. `omarchy-refresh-hyprland` overwrites that file (T13 §6.1, READ). Same
   upgrade: today that costs a menu, then it would cost the power button.

### 4.4 And it can never be the whole answer anyway

`steamos-powerbuttond.service` is a **user** unit with
`Requisite=gamescope-session.service` (READ, T13 §4.1), shipped with a
`.wants` symlink under `gamescope-session.service.wants/` (**MEASURED**, §3.1
row 5). It exists **only** inside Gaming Mode, by construction. And it works by
handing the press to `steam -ifrunning steam://…`, so it does nothing at all
where Steam is not running — which on this project is **Desktop Mode,
deliberately and on measured evidence** (a resident Steam takes the controller
and leaves the desktop with no input, R-41, `docs/START-HERE.md`).

➡️ So powerbuttond is at best *half* a solution that costs the other half. T13's
drop-in is one mechanism covering both modes.

### 4.5 One more unverified dependency, if anyone still wants it

We install Arch's **`steam`**, not Valve's `steam-jupiter-stable`
(`iso/overlay/configs/deck/deck-fetch.packages`, READ). Two things are unverified,
and §3.1b makes the first of them concrete:

1. **Does Arch's package put a binary at exactly
   `$HOME/.steam/root/ubuntu12_32/steam`?** powerbuttond hardcodes that path,
   `posix_spawn`s it, and on failure does a bare `return` — no log (**READ**).
   Jovian-NixOS patches this exact path out, which is direct evidence it is
   fragile in the field.
2. **Does that client register and act on `steam://shortpowerpress` /
   `longpowerpress`?** It plausibly does — the URL handler is client-side and the
   Gaming-Mode UI is selected by gamescope-session's environment, not by the
   package name — but **plausibly is not measured**.

➡️ Either being wrong ships a power button that does nothing **and says nothing**,
which is the exact failure class `CLAUDE.md` names first. Anyone choosing Option
B owes both measurements before, not after.

---

## 5. The options, laid out

| | Option A — **ship nothing extra** ✅ recommended | Option B — powerbuttond in Gaming Mode | Option C — both |
|---|---|---|---|
| logind | `HandlePowerKey=suspend` (T13's drop-in, unchanged) | `ignore` (Omarchy's existing `10-` drop-in; T13's logind step is **deleted**) | `suspend` |
| Desktop Mode | logind. `hl.unbind("XF86PowerOff")` only | Hyprland bind → `systemctl suspend` — and §4.3's four problems | logind |
| Gaming Mode | logind | powerbuttond → Steam | **both fire** |
| New packages | none | `steamos-powerbuttond` (BSD, 10.6 KiB, `holo-staging`) | same |
| Short press parity | ✅ exact | ✅ exact | ✗ doubled |
| Suspend/wake animation | ✗ (cosmetic, §3.2a) | ✅ | ✅ |
| Long-press power menu | ✗ | ✅ in Gaming Mode only | ✅ + a stray suspend |
| Files whose contents are unread | 0 | 1 (`steamos-power-button.rules`, §3.1c) | 1 |
| Silently-failing code on the input path | none | `posix_spawn` → bare `return` (§3.1b) | same |
| Verdict | **recommended** | fallback, only if §6 step 1 fails | 🔴 **reject** |

**Option C is named only to be rejected**: two suspend requests per press, one of
them Steam's, on a device where a re-suspend loop is T13's R1. It is what you get
by installing powerbuttond and forgetting the logind half.

---

## 6. What would settle this — and the whole of it fits in T13's existing session

**Nothing here needs its own trip to the Deck.** Rows 1–3 append to
`docs/tasks/T13-power-button-and-sleep.md` step 6. That is the entire hardware
cost of T14.

### Step 1 🔴 — the discriminator, read-only, in Gaming Mode (gates everything)

Boot to Gaming Mode, let Steam reach its home screen, then over SSH:

```bash
ssh steamdeck 'systemd-inhibit --list --no-pager'
ssh steamdeck 'loginctl list-sessions --no-legend; loginctl show-session <id> -p Type -p Class -p Active -p State'
```

| Reading | Meaning |
|---|---|
| No row whose `WHAT` contains **`handle-power-key`**, and no **`block`**-mode `sleep` row | ✅ §1 confirmed. Option A stands. Proceed |
| 🔴 A **`block`**-mode **`sleep`** row (from Steam or anything else) | **The likeliest failure, and the one nobody had named.** See step 2. Not a reason to ship powerbuttond |
| A `handle-power-key` row, any holder | 🔴 Option A is dead in Gaming Mode. Stop and escalate — §7. ⚠️ On the source reads in §3.2 this should be **impossible** for our stack; if it appears, something is installed that we did not put there |
| A `sleep` row in **`delay`** mode | ✅ harmless — logind waits `InhibitDelayMaxSec` and suspends anyway |

⚠️ **Compare against the two recorded baselines**, both Desktop Mode with Steam
**not** running: §2.2 above (2026-08-12, two rows, `sleep`/`delay`) and
`docs/findings/P17-input-and-osk.md:627` (three rows, *"all `delay` mode …
rather than blocking"*). ⚠️ That P17 line is sometimes read as covering this
question. **It does not** — the same file's "State on exit" records that Steam
had been shut down. **The Gaming-Mode-with-Steam-running case has never been
measured.**

### Step 2 🔴 — the inhibitor trap nobody had named, and it is the real risk

**READ, `man logind.conf` (systemd 261):**

> `PowerKeyIgnoreInhibited=` … **defaults to `no`** … This means that when
> systemd-logind is handling events by itself (no low level inhibitor locks are
> taken by another application), the lid switch does not respect suspend
> blockers by default, **but the power and sleep keys do**.

And in the implementation, `src/login/logind-action.c`, `handle_action_execute()`
(**READ**):

```c
if (inhibit_what_is_valid(inhibit_operation) &&
    !ignore_inhibited &&
    manager_is_inhibited(m, inhibit_operation, NULL, /* flags= */ 0, UID_INVALID, &offending)) {
        …
        log_full(is_edge ? LOG_ERR : LOG_DEBUG,
                 "Refusing %s operation, %s is inhibited by UID …", …);
```

🔴 **Note `flags = 0`.** Unlike the low-level `handle-power-key` check — which
passes `IGNORE_INACTIVE` and therefore only honours the *active* session's lock —
this one has no such flag. **A block-mode `sleep` inhibitor from *any* session,
active or not, defeats `HandlePowerKey=suspend`.**

➡️ **A `block`-mode `sleep` inhibitor makes the power button do nothing.** Not
"suspend later" — nothing, until the lock is released. The locks measured today
are all `delay` mode and are harmless (§2.2). But Gaming Mode is exactly where a
`block` lock would plausibly appear: during a download, a shader build, or a
running game.

✅ **And it is loud, which is the saving grace.** That `log_full(… LOG_ERR …
"Refusing %s operation, %s is inhibited by …")` fires at **error** level for an
edge event, so `journalctl -u systemd-logind` will name the offending UID and PID.
This failure cannot be silent, which is why step 3's journal capture is
mandatory.

So, in Gaming Mode, with **a download deliberately running**:

```bash
ssh steamdeck 'systemd-inhibit --list --no-pager'
```

Look at the **`MODE`** column, not just `WHAT`. `delay` is fine. `block` on
`sleep` is the failure.

**If a `block` lock appears**, the mitigation is `PowerKeyIgnoreInhibited=yes` in
the same drop-in — ⚠️ **which must not be shipped blind**: it makes the button
suspend regardless of what any application is doing, and §2.1 measured that it
**cannot be read back over D-Bus**, so it is the one setting in this area with no
verification instrument. Bring the reading to the operator; do not decide it in
the spec.

*(Note the asymmetry this explains: `LidSwitchIgnoreInhibited=` defaults to
**yes**, which is why the Deck's live `HandleLidSwitch=suspend` would fire
through a block lock while the power key would not.)*

### Step 3 [H] — the press, batched into T13 step 6

One tap in Gaming Mode. Expect: suspends; a second tap resumes; **Gaming Mode,
Steam still running, no password**. Then five consecutive cycles, at least one of
them with a download in flight, watching for T13's R1 (re-suspend on resume).

**And capture the negative control either way:**

```bash
ssh steamdeck 'journalctl -b -u systemd-logind --no-pager | tail -40'
```

This is what makes a *failure* interpretable rather than mute. logind logs when it
sees the key and when it refuses. Three distinguishable outcomes:

| journal shows | Diagnosis |
|---|---|
| the power key seen, then a suspend | ✅ working |
| 🔴 **`Refusing … operation, sleep is inhibited by UID …/…, PID …/…`** | **A block-mode `sleep` lock.** The message names the offender. Step 2 |
| the key seen, no action, and no "Refusing" line | a low-level `handle-power-key` lock — §7 row 1 |
| **nothing at all** | logind never saw the key: the udev untag took the wrong node, or `event4` lost its tag. T13's `POWER_KEEP_ID_PATH` guard (`src/deck-session.sh:784`) exists for exactly this |

### Step 4 — the one file in Valve's package still unread (no Deck required)

Of the six paths `pacman -Fl` listed (§3.1), the binary's source, the LICENSE,
the `.service` unit and the hwdb have all been read (§3.1a–§3.1c). What is left
is **`steamos-power-button.rules`**, which lands in `/usr/lib/udev/rules.d/` and
therefore applies in **Desktop Mode too**:

```
raw.githubusercontent.com/evlaV/steamos-powerbuttond/master/steamos-power-button.rules
# or, from Valve's mirror (10.6 KiB, anonymous HTTP, verified reachable):
https://steamdeck-packages.steamos.cloud/archlinux-mirror/holo-main/os/x86_64/
  steamos-powerbuttond-4.2-2-x86_64.pkg.tar.zst
```

⚠️ **Proposed, not done.** Fetching a file is the operator's call, so this is
written up rather than executed. It is only needed if step 1 sends us to Option B
— under Option A the package is never installed and its contents cannot affect
us.

### Step 5 ✅ — the long press: the number has now been READ, and it argues against using it

`HandlePowerKeyLongPress=` can only ever work through **`event4`**, because the
ACPI node emits an instantaneous press+release and cannot express a hold
(**MEASURED**, T13 §2.2). With T13's untag in place `event4` is the only node
logind watches, so the setting is *mechanically possible* for the first time — in
both modes.

**And the threshold is no longer unknown.** `src/login/logind-button.c:54`,
`github.com/systemd/systemd` (**READ**):

```c
#define LONG_PRESS_DURATION (5 * USEC_PER_SEC)
```

**Five seconds.** Used only at `logind-button.c:262`, in `start_long_press()`.
Verified byte-identical at tags **v255, v256, v257 and `main`**
(`meson.version = 262~devel`). ⚠️ **The Deck runs v261** (MEASURED, §2.1), which
is *bracketed* by v257 and `main` but was **not itself opened** — treat the value
as READ and the version match as INFERRED-by-bracketing. That is a five-minute
check for anyone who needs it exact.

➡️ **This closes T13 §8 open question 3 and T13 §4.0's refusal to write a
number.** Record it there. And do not confuse it with SteamOS's **1 s**, which is
`powerbuttond`'s `alarm(1)` — a different program, a different mechanism, and
five times shorter (T13 §4.1).

🔴 **The number is also the argument against shipping a long press.** 5 s sits
squarely inside the ~10 s hardware hold that `docs/RECOVERY.md` documents as the
escape of last resort. Anyone reaching for the documented gesture would trip a
software action at second five, every time — which is T13's risk R5, now with a
concrete collision rather than a suspected one. **Leave T13's explicit
`HandlePowerKeyLongPress=ignore` in place.**

⚠️ **And one behavioural detail that must be recorded before anyone changes it**
(**READ**, `logind-button.c:286-297`): the long-press timer is armed only when
`HandlePowerKeyLongPress` is neither `ignore` nor equal to `HandlePowerKey`. With
the default `ignore`, **the short action fires on key *down***. Arm a long press
and **the short action moves to key *release***. So setting
`HandlePowerKeyLongPress=` is not additive either — it silently changes when the
ordinary press takes effect. Also **READ**, `logind-button.c:195`: both the short
and the long path go through the *same* `INHIBIT_HANDLE_POWER_KEY` check, so one
lock suppresses both. There is no `handle-power-key-long-press` inhibitor; the
`InhibitWhat` enum has exactly eight values and no long-press variant.

---

## 7. What would change the recommendation

Ranked, each with the reading that triggers it:

1. 🔴 **A `handle-power-key` inhibitor in Gaming Mode** (§6 step 1). Option A
   cannot reach Gaming Mode; go to Option B and accept §4.3's Desktop Mode
   redesign, including a real answer to the double-press-in-the-compositor
   problem *before* anything is written.
   ⚠️ **On §3.2's source reads this should not be possible for our stack**, so
   treat it as "something is installed that we did not put there" before treating
   it as "the analysis was wrong". `systemd-inhibit --list` names the holder.
2. 🔴 **The press does nothing in Gaming Mode with no inhibitor and no journal
   line** (§6 step 3). That is a mechanism we have not found. Stop and bring the
   journal to the operator; do not start installing packages against an
   unexplained symptom — that is how T13's three ranked hypotheses all came to be
   wrong, and how this file's own ChimeraOS row came to be wrong (§3.2).
3. 🔴 **A `block`-mode `sleep` lock during ordinary Gaming Mode use** (§6 step 2)
   — promoted from 🟠 once the source read showed it needs no active session to
   bite. It does **not** overturn Option A and is **not** a reason to ship
   powerbuttond (Valve's daemon would hand the press to Steam, which would ask
   logind to suspend, which would refuse for the same reason). The operator
   chooses between "the button is dead while downloading" and
   `PowerKeyIgnoreInhibited=yes`.
4. 🟠 **The operator says Steam's long-press power menu is a requirement, not a
   nicety.** That is a product call, not an evidence call, and it is the one
   legitimate reason to pay §4.3's price. §4.2's table is the thing to show them:
   the short press is already exact parity, and the menu plus a missing animation
   is the entire gap.
5. 🟡 **Evidence that suspending without Steam's knowledge loses data**
   (§4.2a). ⚠️ The obvious source — ChimeraOS's clean record — **does not
   qualify**, because they ship a powerbuttond after all (§3.2). It would have to
   come from our own five-cycle download test, or from a `steam-for-linux` issue
   whose body somebody actually read.

---

## 8. Open questions — where this file is a guess

Every one of these is a place the answer above is INFERRED.

1. 🔴 **Does Steam take a `block`-mode `sleep` lock in Gaming Mode?** §6 step 2.
   **This is now the single biggest hole**, ahead of the `handle-power-key`
   question it displaced: it needs no active session to bite, it is the class of
   lock Steam is widely believed to take during downloads, and neither research
   pass could establish it. It changes the failure mode, not the design — but a
   power button that is dead while downloading is a defect the operator would
   notice on day one.
2. 🔴 **Does a power press in Gaming Mode suspend, once T13's drop-in is
   installed?** Never tested. §6 step 3. Everything else here is preparation for
   this one press.
3. 🟠 **Does anything hold a `handle-power-key` lock in Gaming Mode?**
   Downgraded from 🔴 by §3.2's source reads — gamescope, Valve's
   gamescope-session and powerbuttond all provably take none, and the one such
   lock in the ecosystem (ChimeraOS's) is in a session package we do not use and
   is gated off anyway. **Still never run in Gaming Mode.** §6 step 1.
4. 🟠 **`xdg-desktop-portal-gamescope` and `steamos-manager` were never
   examined.** The portal is the likeliest home for a Steam-initiated idle or
   sleep inhibit. Neither is installed here — `steamos-manager` is in none of our
   package lists (T13 §3.2, READ) — so this is a gap in the *reasoning*, not
   necessarily in the machine. Named so nobody assumes it was checked.
5. 🟠 **Contents of `steamos-power-button.rules` and
   `steamos-powerbuttond.service`.** The `.service`'s `Requisite=` line is now
   READ (§3.1b); the **udev rule is still unread** and lands system-wide.
   §6 step 4. Only matters under Option B.
6. 🟠 **Does Arch's `steam` handle `steam://shortpowerpress`?** §4.5 — and
   §3.1b makes it sharper: powerbuttond spawns a **hardcoded**
   `$HOME/.steam/root/ubuntu12_32/steam` and **silently returns** if that path is
   not there. Only matters under Option B, and it is a way to ship a silent
   no-op.
7. 🟡 **`LONG_PRESS_DURATION` at exactly v261.** ✅ Read as `5 * USEC_PER_SEC` at
   v255/v256/v257/`main` (§6 step 5). v261 is bracketed but was not opened. Five
   minutes to close; blocks nothing, since the recommendation is not to use it.
8. 🟡 **What the Steam client actually does with `shortpowerpress` vs
   `longpowerpress`.** §4.2's table is READ for the URLs and INFERRED for the
   behaviours, from the operator's account of their own Deck. Steam is not
   readable; this stays INFERRED unless someone measures it on a stock Deck.
9. 🟡 **Whether Steam registers a `PrepareForSleep` D-Bus match at all.** Could
   not be established. §3.2a's *"the Steam client does not monitor the power
   button"* is about the button, not about sleep signals, and the two are
   different claims. Do not merge them.
10. 🟡 **Hyprland's own inhibitor behaviour** was checked by file-tree listing
    only, not by grepping source. "Hyprland takes no logind inhibitor" is
    **INFERRED**. It matters only for Desktop Mode, which is T13's, and T13's
    Desktop Mode press test would expose it — but it is not read.
