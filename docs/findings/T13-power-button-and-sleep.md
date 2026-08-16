# T13 — the power button and sleep: what actually happens, and why

**Research output. The work spec is `docs/tasks/T13-power-button-and-sleep.md`;
this file is the evidence behind it.** Written 2026-08-12, session 22, against
the pinned runtime `basecamp/omarchy@6d7826d` checked out at
`~/.cache/omarchy-deck/iso-build/runtime-src` (= `iso/RUNTIME`), which is the
source of what runs on the operator's Deck today.

## 0. How to read this file

Every claim carries one of three tags, and the distinction is the point:

| Tag | Means |
|---|---|
| **READ** | I opened the file and quote it. Path and line given. Re-checkable in seconds. |
| **MEASURED** | Someone ran an instrument against real hardware and recorded the number. Cited to the recording. |
| **INFERRED** | I reasoned to it. **It may be wrong.** Where it matters, the discriminating measurement is named. |

⚠️ This project has written two inverted rotation values down as facts
(`docs/PROGRESS.md` §5.24a, session-20 notes). Nothing here that is tagged
INFERRED may be promoted to a fact without the measurement beside it.

## 1. The four defects, as reported

The operator, from using the device (2026-08-12):

1. Power button in **Desktop Mode** shows the System submenu, *and only for as
   long as the button is held*. It should suspend.
2. Power button in **Gaming Mode** does nothing at all.
3. After sleep, the power button should return to **where you were** — desktop
   to desktop, gaming to gaming — **with no password**.
4. That is how a stock Steam Deck behaves.

**Defect 3 is already half-true on this Deck and half-not**, and the two halves
have different causes. §5 separates them.

---

## 2. Defect 1 — what consumes the power key in Desktop Mode

### 2.1 The chain, end to end (all READ)

| # | Component | What it does | Citation |
|---|---|---|---|
| 1 | **The hardware** | Two `Power Button` evdev nodes, **both** advertising `KEY_POWER` (116) and `KEY_WAKEUP` (143), both with a `kbd` handler | `docs/findings/P15-recon-raw/input-devices.txt:1-9` (`PNP0C0C/button/input0`, `event0`) and `:21-29` (`LNXPWRBN/button/input0`, `event2`) — **MEASURED** on the Deck, P1.5 recon |
| 2 | **udev** | Both nodes get `TAG+="power-switch"` because both set `ID_INPUT_KEY=1` | `/usr/lib/udev/rules.d/70-power-switch.rules:13` (stock systemd) |
| 3 | **logind** | Does nothing. Omarchy ships a drop-in that disables the default | `etc/systemd/logind.conf.d/10-ignore-power-button.conf:2` → `HandlePowerKey=ignore` |
| 4 | **Hyprland** | Binds the key to the Omarchy menu | `default/hypr/bindings/utilities.lua:9` |
| 5 | **omarchy-menu** | `toggle` → `omarchy-shell shell toggle omarchy.menu '{"menu":"system"}'` | `bin/omarchy-menu:20-23` |
| 6 | **The shell** | `toggle()` = *if open, hide; else summon* | `shell/shell.qml:511-514` |

The one line that decides everything:

```lua
o.bind("XF86PowerOff", "Power menu", "omarchy-menu toggle system", { locked = true })
```
— `default/hypr/bindings/utilities.lua:9`. **(READ.)**

`o.bind` forwards its option table straight to Hyprland's Lua `hl.bind`
(`default/hypr/helpers.lua:81-95`, READ), and `release = true` is a real option
in this API — `default/hypr/bindings/voxtype.lua:4` uses it — so `locked = true`
is the "fires even when locked" flag and the bind is a **press** bind.

**So: the power button was never wired to sleep on this machine.** Omarchy
deliberately took the key away from logind (step 3) and gave it to a menu
(step 4). Nothing is broken; the product decision is simply wrong for a
handheld. **This is the whole of defect 1's first half, and it is READ, not
inferred.**

⚠️ Note what `HandlePowerKey=ignore` is hiding. `man logind.conf` (systemd 261,
the version the Deck runs — `docs/PROGRESS.md` §5.25 #2) says **(READ)**:

> `HandlePowerKey=` defaults to **`poweroff`**, … `HandlePowerKeyLongPress=`
> defaults to `ignore`.

Not `suspend`. **Deleting Omarchy's drop-in without replacing it would make the
power button hard-power-off the Deck**, which is worse than the current
behaviour. Any fix must set the value explicitly.

### 2.2 ✅ RESOLVED BY MEASUREMENT, 2026-08-12 — and the answer was none of the three hypotheses

**The capture below was run on the operator's Deck, with the operator pressing
the button. Everything in this subsection after the outcome is the reasoning
that preceded it, kept because the hypotheses were ranked wrong and that is
worth seeing.**

🔴 **First, two corrections to §2.1 and to the spec's step 1, both cheap and
both the kind that waste a hardware session:**

1. **`evtest` and `libinput` are NOT INSTALLED on the Deck.** The capture
   command this file and the task spec both specified **cannot run as written**.
   `python-evdev` is present (the mapper depends on it) and was used instead,
   grabbing nothing and watching all 18 nodes. *A runbook command nobody has
   executed is a hypothesis — §5.30c, again, in this file's own step 1.*
2. **`event0` is SILENT.** §2.1 row 1 names the two ACPI `Power Button` nodes,
   `event0` (`PNP0C0C`) and `event2` (`LNXPWRBN`), from the P15 recon. A capture
   aimed at only those two saw **zero events across 75 seconds** — the first run
   did exactly that and proved nothing. The second live node is **`event4`,
   `"AT Translated Set 2 keyboard"`**, which no prior document named.

**The trace. One physical press, held ~3 s** (`t` relative, seconds):

```
450.902  event4  KEY_POWER  PRESS      <- AT Translated Set 2 keyboard
451.100  event2  KEY_POWER  PRESS      <- ACPI LNXPWRBN, 198 ms later
451.100  event2  KEY_POWER  RELEASE    <- SAME MILLISECOND
453.820  event4  KEY_POWER  RELEASE    <- 2.92 s: tracks the physical hold
```

**Sample size 3, and all three are the same shape** — one tap and two holds, in
a 600 s window:

| press | `event4` PRESS → `event2` PRESS | `event4` press→release (the physical hold) |
|---|---|---|
| tap | **131 ms** | 133 ms |
| hold | **198 ms** | 2.92 s |
| hold | **198 ms** | 1.14 s |

So the ACPI notify lands ~130–200 ms after the press and is **uncorrelated with
hold length**, while `event4` tracks the hold exactly. `event0` emitted nothing
across all three. ⚠️ n=3 — enough to settle the *shape*, not enough to pin the
latency; do not write 198 ms into code as a constant.

**Positive
control:** in the same capture, `BTN_SOUTH` on `event7` appeared with the
mapper's translated `KEY_ENTER` on `event17` — so the capture was demonstrably
alive, which is what makes the two silent runs before it interpretable as "the
operator was not pressing" rather than "the key emits nothing".

**The answer:**

| Node | Behaviour | Can it express a hold? |
|---|---|---|
| **`event4`** ("AT Translated Set 2 keyboard") | A **real key**: down on press, up on release, 2.92 s apart | **Yes** |
| **`event2`** (ACPI `LNXPWRBN`) | A **fire-and-forget notify**: one instantaneous press+release ~198 ms after the press, **independent of hold duration** | **No, ever** |
| `event0` (ACPI `PNP0C0C`) | Silent | — |

**So hypothesis A is WRONG** — the two nodes do not split the press and release
edges; both fire near the press. **B is closest but under-described**, and **C
(autorepeat) is dead**: a 2.92 s hold produced no repeats at all.

**Two consequences that decide the fix:**

1. 🔴 **Both live nodes are tagged `power-switch`, so logind would see TWO
   presses per physical press.** Risk R1 is real, not theoretical:
   `HandlePowerKey=suspend` applied naively gets two suspend requests ~198 ms
   apart, the second landing at or just after resume.
2. **`HandlePowerKeyLongPress=` can only ever work through `event4`.** The ACPI
   node cannot hold a key down, so any long-press design that reaches logind
   through it is unbuildable — not slow, *unbuildable*.

**The "only while held" report is fully explained, and confirmed by the
operator's own eyes.** Two presses 198 ms apart hit a bind whose action is a
*toggle* (`shell.qml:513`), so the menu opens and closes 198 ms later —
**always**, regardless of hold length. Asked directly whether a deliberate 3 s
hold kept the menu up or flashed it, the operator answered **"just flash"**.
The original description was the 0.5 s case, where a 198 ms flash and the hold
are subjectively the same thing.

➡️ **The fix, and it independently reproduces Valve's.** Drop the ACPI node from
`power-switch` via a udev rule, leaving `event4` as the single source, and only
then set `HandlePowerKey=`. Valve blacklists the same ACPI node by name on
Jupiter and Galileo (`STEAMOS_POWER_BUTTON_IGNORE=1`, §4.1) — arrived at from
their own measurement, and now from ours. Two independent routes to one answer
is the strongest evidence this file contains.

---

*(Everything below is the pre-measurement reasoning, kept deliberately: it
ranked A first and A was wrong.)*

### 2.2a The "only while held" detail — the original INFERRED analysis

The operator's phrasing is specific: *"I press the power button 0.5 seconds, I
see that submenu for half a second."* The menu opens on press and closes on
release.

**What is certain (READ):** the shell's `toggle` is a true toggle —
`isPluginOpen(id) ? hide(id) : summon(id, payloadJson)`, `shell/shell.qml:513`.
So a second invocation closes what the first opened. The menu's own key handler
is `Keys.onPressed` only and has no release path
(`shell/plugins/menu/Menu.qml:1075-1116`, READ), and nothing in the menu closes
on focus loss. **Therefore something is invoking `omarchy-menu toggle` a second
time, at release.**

**What is not certain:** which edge produces the second event.

Only two things on this device run `omarchy-menu toggle`:

- Hyprland binds (`default/hypr/bindings/utilities.lua:1-9`) — READ.
- Our mapper, for QAM and STEAM (`src/deck-input-mapper.py:391`) — READ. It
  reads `/dev/input/event7` (the "Steam Deck" controller node), **not** `event0`
  or `event2`, so it cannot see `KEY_POWER`. Ruled out.

That leaves: **`XF86PowerOff` reaches Hyprland twice per physical press-and-
release cycle.** Ranked hypotheses:

| # | Hypothesis | Why it is plausible | How it dies |
|---|---|---|---|
| **A** | The two `Power Button` nodes fire on **different edges** — one at press, one at release | Both nodes exist and both carry `KEY_POWER` (**MEASURED**, §2.1 row 1). The ACPI fixed-feature button (`LNXPWRBN`) and the control-method button (`PNP0C0C`) are driven by different firmware paths on the same physical switch | `evtest` on both nodes across one long hold: if A holds, each node emits one `KEY_POWER value=1` and they are separated by the hold duration |
| **B** | **One** node emits a `KEY_POWER` press at each edge (the EC raises an ACPI notify on both press and release) | Same observable; needs only one device | Same command: two `value=1` events on the *same* node, separated by the hold duration |
| **C** | Key autorepeat | `repeat_rate = 40`, `repeat_delay = 250` (`default/hypr/input.lua:60-61`, READ) — a 500 ms hold would cross the delay | **Predicts a flicker storm, not a clean open/close**, and Hyprland only repeats binds carrying the `e` flag, which this bind does not. Ranked last |

**A and B are indistinguishable in effect and identical in consequence.** They
are also both INFERRED — I have not seen the Deck's power button traced.

🔴 **Why this matters more than it looks.** If two `KEY_POWER` presses arrive
per physical press, then a naive fix — hand the key back to logind with
`HandlePowerKey=suspend` — gets **two suspend requests per press**, the second
of them timed to land at or just after resume. On a device whose only other
escape is a ten-second hardware hold, an immediate re-suspend loop is
indistinguishable from a dead Deck. **Measure before you change the handler.**
This is risk R1 in the spec.

**The measurement, one command, read-only, no writes:**

```bash
ssh steamdeck 'sudo timeout 20 evtest --grab /dev/input/event0 & sudo timeout 20 evtest --grab /dev/input/event2; wait'
```
(or `libinput debug-events --show-keycodes` if `evtest` is absent). Press and
hold power for a deliberate 3 seconds, twice. Record **every** `KEY_POWER` line
with its timestamp and its node. That single capture answers A vs B vs C and
sizes R1.

⚠️ **`--grab` matters.** Without it the presses also reach Hyprland and open
menus mid-capture. With it, the compositor sees nothing — which is also the
safest way to press the power button while you are still working out what it
does.

---

## 3. Defect 2 — why Gaming Mode does nothing

### 3.1 The chain (READ, with one hole)

`etc/systemd/logind.conf.d/10-ignore-power-button.conf` is a **system-wide**
logind drop-in. It is not per-session, per-seat or per-compositor: logind reads
`/etc/systemd/logind.conf` plus its drop-ins once, for the whole machine. It is
shipped by the `omarchy` package into `/etc` — evidenced by
`bin/omarchy-upgrade-to-quattro:1211`, which passes
`--overwrite '/etc/systemd/logind.conf.d/10-ignore-power-button.conf'` to
`pacman -Syu`, i.e. the package owns that exact path **(READ)**.

So in Gaming Mode:

1. logind ignores `KEY_POWER` — same drop-in, same effect. **(READ.)**
2. The Hyprland bind does not exist: Gaming Mode is Valve's stock
   `gamescope-wayland` session (`start-gamescope-session` →
   `/usr/lib/steamos/gamescope-session`), not Hyprland
   (`src/deck-session.sh:11-21, 137`, READ). No Hyprland, no bind.
3. Nothing else claims the key.

**Result: the press reaches a compositor that does not bind it, on a machine
whose logind has been told to ignore it. Nothing happens.** That is a complete
explanation and it needs no hypothesis about Steam.

### 3.2 The hole, and why it changes the fix

**What I could not read:** whether the Steam client (or gamescope-session)
takes a logind **`handle-power-key` low-level inhibitor**. `man logind.conf`
(READ) is explicit that this matters:

> A different application may disable logind's handling of system power and
> sleep keys … by taking a low-level inhibitor lock (`handle-power-key`, …).
> … If a low-level inhibitor lock is taken, logind will not take any action
> when that key or switch is triggered and the `Handle*=` settings are
> irrelevant.

If Steam takes that inhibitor in Gaming Mode, then **setting
`HandlePowerKey=suspend` fixes Desktop Mode and leaves Gaming Mode exactly as
broken as it is now** — and the real cause of defect 2 would be that Steam is
grabbing the key and then failing to act on it, because the SteamOS-side
component that implements the action is not installed here.

**It is not installed here.** Our package lists carry Valve's `gamescope` from
`jupiter-staging`, `linux-neptune-611`, `linux-firmware-neptune`, `mangohud`,
`steamdeck-dsp` and `steam` — and **no `jupiter-hw-support`, no
`steamos-manager`, no `holo` packages at all**
(`iso/overlay/configs/deck/deck-mirror.packages`,
`deck-install.packages`, `deck-fetch.packages` — READ, all three, complete
lists). Stock SteamOS's Gaming-Mode power handling, whatever its mechanism,
is therefore **absent from this device by construction**.

**The measurement, read-only, in Gaming Mode:**

```bash
ssh steamdeck 'systemd-inhibit --list --no-pager'
ssh steamdeck 'journalctl -b -u systemd-logind --no-pager | tail -40'
```

An inhibitor row with `What=handle-power-key` (or `handle-suspend-key`) held by
a Steam process is the answer. If there is none, `HandlePowerKey=suspend` will
work in both modes and defect 2 collapses into defect 1's fix.

🆕 **§4.1 lowers the prior on that inhibitor sharply, without closing it.**
Valve's own design keeps logind out of the way with a **config value**
(`HandlePowerKey=ignore`) rather than with an inhibitor — that is exactly what
`steamos-powerbuttond` needs, and Jovian-NixOS says so in a comment on the same
setting: *"Conflicts with powerbuttond"* (READ). Nothing read in §4 shows Steam
or gamescope-session taking a `handle-power-key` lock. **Combined with the fact
that `steamos-powerbuttond` is in none of our three package lists, the simplest
reading of defect 2 is a MISSING COMPONENT, not a conflict** — and a missing
component is exactly what a system-wide `HandlePowerKey=suspend` replaces. Still
INFERRED; the one-command check above is cheap and stays step 1 of the hardware
batch (`docs/tasks/T13-power-button-and-sleep.md`).

---

## 4. Defect 4 — what SteamOS actually does

*(Web research, sanctioned by the operator. reddit.com is blocked by policy and
was not attempted — `docs/START-HERE.md`.)*

**✅ STATUS: FILLED IN 2026-08-12, from Valve's own source rather than from
reports.** §4.0 below was written before that research landed and is kept
because its reasoning still holds; **§4.1 supersedes its central assumption.**

### 4.1 🔴 SteamOS does NOT use logind for the power key. Steam decides.

This is the finding that changes the design, and it inverts §4.0's table.

| What | Where | Tag |
|---|---|---|
| Valve sets `HandlePowerKey=ignore` in a logind drop-in (`etc/systemd/logind.conf.d/suspendbutton.conf`, installed by `jupiter-legacy-support`) | The install line is **READ** in that package's `PKGBUILD`; the file body lives in a `saltfiles/` subtree that is **not mirrored publicly**, so its contents are **INFERRED** | READ + INFERRED |
| Every independent reimplementation agrees on that value | Bazzite `system_files/deck/shared/etc/systemd/logind.conf.d/deck.conf`, CachyOS-Handheld `steam-deckify.conf`, Jovian-NixOS — the last with the explanatory comment **"Conflicts with powerbuttond"** | READ |
| The key is actually handled by **`steamos-powerbuttond`**, a **user** service (`Requisite=gamescope-session.service`), which reads `KEY_POWER`, `KEY_F16` and `SW_LID` from evdev and forwards to the Steam client: `steam -ifrunning steam://shortpowerpress` / `steam://longpowerpress` / `steam://lidswitch` | `steamos-powerbuttond/powerbuttond.c` | READ |
| **The long-press threshold is 1 second**, and it is Valve's, not systemd's: press arms `alarm(1)`; a release before it fires sends `shortpowerpress`, the alarm firing sends `longpowerpress` | same file | READ |
| On Jupiter and Galileo the **ACPI "Power Button" node is deliberately ignored** (`STEAMOS_POWER_BUTTON_IGNORE=1` in `steamos-power-button.hwdb`), so powerbuttond binds the *real* hardware button instead | same package's hwdb | READ |
| ChimeraOS diverges — `HandlePowerKey=suspend` — **because it does not ship powerbuttond** | `chimeraos/rootfs/etc/systemd/logind.conf.d/power_off.conf` | READ |

⚠️ **Consequences for §4.0 and §2.2, both of which this outranks:**

1. §4.0's table maps the operator's description onto `HandlePowerKey=suspend` +
   `HandlePowerKeyLongPress=poweroff`. That produces *similar behaviour by a
   different mechanism*. It remains a legitimate design for **our** product —
   we have no Steam client mediating Desktop Mode — but it is **not** "what
   SteamOS does", and this file must not be cited as saying so.
2. §4.0 refuses to write a long-press number until one is read from source.
   **One now is** — but it is `alarm(1)` in *powerbuttond*, not systemd's
   `LONG_PRESS_DURATION`, which is still unread. Do not conflate them.
3. 🔴 **§2.2's hypothesis that an ACPI node fires an instantaneous
   press+release now has direct supporting evidence**: Valve found the ACPI
   button unsatisfactory on this exact hardware and blacklisted it by name.
   That does not prove which node our Deck's press arrives on — **the `evtest`
   capture is still owed** — but it raises the prior sharply, and it means the
   capture must enumerate *all* candidate nodes rather than the first match.

### 4.2 Suspend itself — s2idle, and the session is never torn down

🔴 **THE FIRST ROW OF THIS TABLE IS WRONG, AND IT WAS MEASURED WRONG ON
2026-08-12.** Read this before using anything below it.

On the operator's Deck, `/sys/power/mem_sleep` reports **`s2idle [deep]`** — the
brackets mark the *selected* mode, so this machine suspends to **deep / S3**,
not s2idle. The cause is in the Valve kernel itself, logged at 0.27 s of boot:

```
[    0.269733] PM: Steam Deck quirk - no s2idle allowed!
[    0.313295] ACPI: PM: (supports S0 S3 S4 S5)
```
*(`6.11.11-valve29-1-neptune-611`. MEASURED, twice, by two independent readers.)*

**The kernel forbids s2idle on this hardware.** So the reasoning below — which
inferred s2idle from the *absence* of any Valve config selecting a sleep mode —
reached the wrong answer from correct evidence: nothing configures it because
the kernel decides it, and it decides against s2idle.

⚠️ **What does and does not follow.** S3 preserves RAM, so processes, the
compositor and the session survive a suspend exactly as they would under s2idle;
"the session is never torn down" still holds and was READ from gamescope-session
directly, not derived from the sleep mode. What genuinely changes is **device
re-initialisation on resume** — Wi-Fi, GPU, audio — which is where S3's real
risk lives, and which nobody has exercised on this device. Do not over-correct
this row into "everything above is void".

⚠️ Also measured and **not** in the table: **`HandleLidSwitch=suspend` is live
and unoverridden**, so logind ends the lid path in a *suspend* while §5.2 row D
describes it ending in a *lock*. Two consumers, one of them undocumented.

*(The original, now-superseded row follows.)*

| Question | Answer | Tag |
|---|---|---|
| s2idle or deep (S3)? | ~~**s2idle.**~~ **WRONG — see above.** Nothing in Valve's shipped configs selects a sleep mode at all: no `mem_sleep_default` on the Deck's kernel cmdline (`jupiter-hw-support/etc/default/grub-steamos`, read in full), zero hits for `mem_sleep`/`s2idle`/`S0ix` across `owner:evlaV`, and no repo writes `/sys/power/mem_sleep`. The kernel config carries generic support plus `CONFIG_AMD_PMC=m` (the s2idle/LPS0 driver) | READ for the absence; **INFERRED** for the Deck specifically — no Valve file *names* s2idle. Corroborated on non-Deck SteamOS 3.8 by `ValveSoftware/SteamOS#2491`, where `/sys/power/mem_sleep` offers only `[s2idle]` |
| 🔴 Does the session survive suspend? | **Yes, untouched.** `gamescope-session` (268 lines) has **zero** matches for suspend/sleep/resume/inhibit/logind; its unit has no sleep-target dependencies; `ValveSoftware/gamescope` has no `PrepareForSleep` code; and `steamos-session-select` is invoked only for *mode switching*, **never on resume** | READ |
| Then how does "resume to where you were" work? | It is **plain suspend/resume**. There is no restoration logic to copy, because SteamOS does not restore anything — it never leaves | READ |
| Sleep hooks Valve ships | Two, in `steamos-customizations`: `modules-reload.sh`, which reloads the **ath11k** Wi-Fi driver across sleep but **only if `/home/deck/.force-ath11k-reload` exists** (opt-in; OLED-only, LCD is `rtw89`), and `hibernate-post.sh`, which is hibernate-only | READ |
| Suspend-then-hibernate | `AllowSuspendThenHibernate=yes`, **`HibernateDelaySec=20min`**, `HibernateOnACPower=no` — on `master` and on the shipping `jupiter-3.8.x` branch | READ |
| TDP / fan / audio / controller re-apply on resume? | **None exists.** No such hook in `system-sleep/`; `jupiter-fan-control.service` has no suspend dependencies and its `fancontrol.py` no resume code. A Bluetooth-restart-on-resume unit exists **only on an unmerged branch** | READ |
| `steamos-manager`'s role | **None.** Its 982-line interface XML exposes no suspend, sleep, hibernate, inhibit or power-key API — grepped in full. It owns TDP, fan, charge limit and mode switching | READ |

**The whole SteamOS chain, in one line:** power button → `powerbuttond` →
`steam://shortpowerpress` → **Steam** → logind `Suspend()` /
`SuspendThenHibernate()` → s2idle → two `systemd-sleep` hooks → resume, with the
compositor and session never touched.

⚠️ **What this means for us.** We deliberately do **not** autostart Steam on the
desktop (§2.6, revised: a resident Steam takes the controller and leaves the
desktop with no input at all — R-41). So **the entire mechanism SteamOS uses is
unavailable to us in Desktop Mode**, and the systemd-primitive design in §4.0 is
the right one *for our product* — not because it matches SteamOS, but because
the thing SteamOS relies on is a component we removed on measured evidence.
Gaming Mode is the opposite case: Steam **is** running there, which is a strong
lead for §3's hole and should be checked before anything is built.

**Not found, stated rather than guessed:** the body of Valve's
`suspendbutton.conf`; any Valve file naming s2idle or S3 for the Deck; any
`HandleLidSwitch` setting from Valve (the lid is handled in userspace by
powerbuttond, not logind). `wiki.archlinux.org/title/Steam_Deck` is behind
anti-bot and returned access-denied.

### 4.0 What is known without the web

The two behaviours the operator describes are consistent with the systemd
primitives that already exist, which means **the spec does not depend on the
web research being complete**:

| SteamOS behaviour (operator report) | systemd primitive that produces it | Tag |
|---|---|---|
| Short press → suspend | `HandlePowerKey=suspend` | READ (`man logind.conf`) |
| Long press → power menu / power off | `HandlePowerKeyLongPress=poweroff` | READ (`man logind.conf`); systemd's own default for this key is `ignore` |
| Hold ~10 s → hard power off | EC/PMIC, below the OS entirely | Documented in `docs/RECOVERY.md` (step 3 of "What actually gets you out") |

⚠️ **The long-press threshold is a number I do not have from an authoritative
source.** systemd's `LONG_PRESS_DURATION` is not in `man logind.conf` (checked
locally, READ — the man page names the setting and its default and gives no
duration). Do **not** write a number into code or docs until it is read out of
systemd's source or its NEWS file.

🔴 **And a caveat that outranks the number.** `HandlePowerKeyLongPress=` needs
the key to stay **held down** for the duration. If §2.2's hypothesis A or B is
true — the ACPI button synthesising an instantaneous press+release, or two
nodes firing on opposite edges — then **the key is never "held" from logind's
point of view and the long-press action can never fire.** The §2.2 `evtest`
capture answers this too. Until it is run, treat any long-press design as
unbuilt.

---

## 5. Defect 3 — resume to where you were, with no password

Two independent questions wearing one sentence.

### 5.1 "Where you were" — already true, and cheap to keep true

**Suspend and resume do not switch sessions.** There is no session-switching
code on the sleep path: `omarchy-system-sleep-monitor` watches
`PrepareForSleep` and does one thing — lock (`bin/omarchy-system-sleep-monitor:19-61`,
READ). Nothing in the Omarchy shell reacts to resume at all; the only reference
to resume in the entire `shell/` tree is a comment about a timer surviving it
(`shell/plugins/lock/Service.qml:380`, READ — grepped the whole tree).

So Desktop resumes into Desktop and Gaming resumes into Gaming **by default**,
and defect 3's first half needs no work. What it needs is *verification*, plus
two failure paths closed:

- **The panel must come back on.** Omarchy's own wake path is
  `omarchy-system-wake` — `omarchy-brightness-display on`, keyboard backlight
  restore, clamshell reconcile (`bin/omarchy-system-wake:8-10`, READ) — but it
  is called **only from the lock service's `finishUnlock()`/`runWake()`**
  (`shell/plugins/lock/Service.qml:132-144`, READ). With the lock producer
  masked, **nothing calls it.** Whether the panel wakes on its own from s2idle
  is **UNVERIFIED** and is a hardware row.
- **The compositor may not survive.** If Hyprland or gamescope dies across
  suspend, SDDM restarts — and SDDM is configured with `[Autologin]` carrying
  **both** `User=` and `Session=` (`src/deck-session.sh:807-812`, READ; the
  "both" is a hardware finding from P1.5 phase F). Autologin means no password
  prompt. ⚠️ But autologin restores the **configured default session**, not the
  one you were in — so a compositor death in Desktop Mode resumes into *Gaming
  Mode* on a Deck whose default is Gaming (`docs/START-HERE.md`: "boots to
  Gaming Mode"). That is a correctness gap in "where you were", not a lockout.

### 5.2 "No password" — the four producers, and where each stands

`docs/findings/T9-lock-service-mitigation.md` §1.4 enumerated the lock
producers by reading every caller of `beginLock()` in the whole tree. Restated
here **only** with what changed since, per the brief:

| Producer | Mechanism | State on the operator's Deck today |
|---|---|---|
| A — idle timeout | `shell/plugins/services/idle/Service.qml` → `omarchy-system-lock` | ✅ neutered: `idle.lock = 86400` (`src/deck-session.sh:380-381`, READ) |
| B — **suspend** | `omarchy-sleep-lock.service` → `omarchy-system-sleep-monitor` → `systemd-inhibit --what=sleep --mode=delay` → `omarchy-system-sleep-lock` → `omarchy-shell lock lock` | 🟡 **masked BY HAND.** `docs/START-HERE.md`, Deck state: *"`omarchy-sleep-lock` masked"*. **`src/` still contains no mask** — grepped: `src/deck-session.sh:371` mentions the unit only in a comment |
| C — the user asks | `system.lock` row (`default/omarchy/omarchy-menu.jsonc:32`), `SUPER+CTRL+L` (`utilities.lua:96`) | live, and deliberate |
| D — **lid close** | `o.bind("switch:on:Lid Switch", …, "omarchy-system-lid-close")` (`utilities.lua:33`) → `omarchy-system-lock` (`bin/omarchy-system-lid-close:16-18`) | 🆕 **live, and the Deck HAS a `Lid Switch` node** — `PNP0C0D/button/input0`, `event1` (`docs/findings/P15-recon-raw/input-devices.txt:11-19`, **MEASURED**). Gated behind `omarchy-hw-laptop-closed`, so it should never assert on a handheld — **INFERRED, not measured** |

**The interaction the brief asks about, stated precisely:**

`omarchy-sleep-lock.service` and `shell.json`'s idle policy are **independent
producers of the same artefact** and neither covers the other. The idle policy
(`idle.lock = 86400`) is a *timer* inside the Quickshell idle service; the sleep
lock is a *systemd unit* holding a `--mode=delay` inhibitor on logind's
`PrepareForSleep` signal, which calls the same `omarchy-shell lock lock` IPC
from outside the idle service entirely. Setting `idle.lock` to any value —
including `0`, which locks **instantly** — has no effect on the sleep path, and
masking the sleep unit has no effect on the idle path. **Requirement "no
password on resume" is satisfied by masking B and by nothing else.** That is why
`src/deck-session.sh`'s original claim that the idle settings meant the Deck
"can never be shown an unanswerable password prompt" was false when written
(corrected in-file 2026-08-11).

There is a second, subtler coupling worth recording: `20-inhibit-delay.conf`
raises `InhibitDelayMaxSec` to 15 s **for the benefit of B**
(`etc/systemd/logind.conf.d/20-inhibit-delay.conf:1-10`, READ). With B masked,
that 15 s window has no user — but it also costs nothing, because
`omarchy-system-sleep-lock` is the only thing that takes the delay inhibitor.
Leave it; removing it is a change with no benefit and a non-zero chance of
slowing suspend on some other path.

### 5.3 The security posture — say it out loud

**This project ships a handheld that resumes from sleep unlocked, on purpose.**

The reasoning, which belongs in the code comment and in `docs/RECOVERY.md` and
not only here:

- The device has **no keyboard**. The only text input is our on-screen keyboard
  (`deck-osk`), which reaches a lock surface only because of a Hyprland
  `above_lock = 2` layer rule that is a *user config file* one Lua syntax error
  away from being silently discarded (`docs/PROGRESS.md` §5.24).
- There is **no unlock IPC**. Omarchy's shell exposes `lock`, `isLocked`,
  `status`, `preview`, `hidePreview` and nothing that releases a lock
  (`docs/PROGRESS.md` §5.24, measured with `qs ipc show`).
- `docs/RECOVERY.md`'s documented escape **does not work against a healthy
  lock** — `clear_crashed_lockscreen` refuses one, measured against a real
  locked Deck on 2026-08-11.
- So the failure mode of "lock on resume" is not "the user types a password".
  It is "the user holds power for ten seconds and loses their work", every time
  the OSK path is even slightly wrong.

`docs/tasks/T5-fork-plan.md` §5.6 already carries this decision in one line —
*"a suspended Deck resumes unlocked, deliberately, because it has no keyboard"*
— and requires it be stated in the code and in RECOVERY. **T13 does not create
this posture; it inherits it and must make it explicit rather than incidental.**

⚠️ It is a real trade-off, not a free win: a lost or stolen Deck is an open
session. The mitigating facts are that (a) full-disk encryption is a separate
axis and `T5-fork-plan.md` §5.5 owns it, and (b) the user can still lock
deliberately from the System menu, which is producer C and stays.

---

## 6. Where each fix lands

**File archaeology, so the implementer does not repeat it.**

### 6.1 The seam that matters most: `~/.config/hypr/bindings.lua`

The power-key bind lives in an Omarchy-owned default
(`/usr/share/omarchy/default/hypr/bindings/utilities.lua`) — but **it does not
need an upstream patch**, because Omarchy ships a sanctioned override seam and
documents this exact idiom.

Load order **(READ, `config/hypr/hyprland.lua:13-23`)**:

```lua
require("default.hypr.omarchy")   -- Omarchy's defaults, including the bind
…
require("hypr.bindings")          -- ~/.config/hypr/bindings.lua, AFTER
```

and the shipped user file tells you what to do there **(READ,
`config/hypr/bindings.lua:18-21`)**:

> Change an existing binding by unbinding it first, then binding the key again.
> `hl.unbind("SUPER + SPACE")` / `o.bind("SUPER + SPACE", …)`

`hl.unbind` is real and in use upstream (`utilities.lua:61`). So
`hl.unbind("XF86PowerOff")` in `~/.config/hypr/bindings.lua` removes the menu
bind cleanly, at the user layer, with no patch and no drift risk against
upstream renames.

⚠️ **Same trap as `input.lua`.** A Lua syntax error makes Hyprland discard the
**entire file** silently, with `hyprctl configerrors` still clean
(`docs/PROGRESS.md` §5.24). Any block written here needs (a) `luac -p` at write
time, (b) a sentinel global as the last statement, and (c) a readback that is an
**assertion**, not `hyprctl eval 'return X'` — which prints `ok` and exits 0 for
names that never existed. `verify_osk_kb_layout` in `src/deck-session.sh`
already has the correct shape; copy it.

⚠️ **`omarchy-refresh-hyprland` overwrites this file** with the shipped default
(`bin/omarchy-refresh-hyprland:7` → `omarchy-refresh-config hypr/bindings.lua`;
the helper backs up to `<file>.bak.<epoch>` first —
`bin/omarchy-refresh-config:22,31-40`, READ). Same exposure `input.lua` already
has and the project already accepts. Worth a failure-mode row, not a redesign.

### 6.2 The mapping

| Defect | Fix | Lands in | Why not elsewhere |
|---|---|---|---|
| **1** Desktop shows a menu instead of sleeping | (a) `hl.unbind("XF86PowerOff")` in `~/.config/hypr/bindings.lua`; (b) hand the key to logind | (a) **`src/deck-session.sh`** — a new marker-delimited block in `bindings.lua`, mirroring `install_osk_kb_layout_rule`'s splice into `input.lua`. Plus a **T5 bake-in** (`/etc/skel` + the created user). (b) see row 3 | **Not T12.** The T12 patch seam is for files owned by `omarchy-dev` under `/usr/share/omarchy`. A user override file is the supported seam and carries no upgrade-drift risk, so patching upstream here would be strictly worse |
| **1 + 2** together | `HandlePowerKey=suspend` (explicitly — the systemd default is `poweroff`) | **A logind drop-in**, `/etc/systemd/logind.conf.d/99-deck-power-button.conf`, written by a new `src/deck-session.sh` stage and baked into T5. `99-` sorts after Omarchy's `10-ignore-power-button.conf`, so it wins without editing a package-owned file | **Do not edit or delete `10-ignore-power-button.conf`.** It is owned by the `omarchy` package (`bin/omarchy-upgrade-to-quattro:1211`) and would come back on every upgrade — and deleting it alone yields `poweroff`, not `suspend` |
| **2** Gaming Mode dead | Same logind drop-in — **if** nothing holds a `handle-power-key` inhibitor. If Steam does hold one, this row is unresolved and needs §3.2's measurement first | logind drop-in, else **open** | A Hyprland bind cannot reach Gaming Mode at all; the mapper does not run there either (it is `WantedBy=wayland-session@hyprland.desktop.target`, `src/deck-session.sh:423`) |
| **3/4** no password on resume | Ship the `omarchy-sleep-lock.service` mask instead of leaving it hand-applied | **`src/deck-session.sh`** (a `systemctl --global mask` under `/etc/systemd/user/`) **and** T5 `configure_deck` + `/etc/skel`. `docs/tasks/T5-fork-plan.md` §5.6 already specifies exactly this and calls out the race: upstream enables the unit at **first run**, after our phase, so a `--global` mask "is the version that cannot lose the race" | A per-user `systemctl --user mask` loses to first-run enabling on a fresh install. The hand-applied mask on the test Deck is *not* the shipped fix |
| **3** resume to the right session | Verification + a note that autologin restores the **default** session, not the last one | Nothing to build if the compositor survives; **`src/deck-session.sh`** if it does not and we decide to persist last-session | — |
| *(optional)* long press → power off / menu | `HandlePowerKeyLongPress=` in the same drop-in | Same logind drop-in | ⚠️ **Blocked on §2.2's capture** — if the button never reports a sustained hold, this setting is dead on arrival. ⚠️ And SteamOS's **1 s** is `powerbuttond`'s `alarm(1)` (§4.1), **not** systemd's `LONG_PRESS_DURATION`, which is still unread. Do not write either number into code as if it were the other. `docs/tasks/T13-power-button-and-sleep.md` D1 recommends shipping nothing here in v1 |
| *(unchanged)* the 5 s blank on the lock screen | Already owned by T12 patch `0010-lock-blank-timer-20s` (`src/omarchy-deck-patches/patches/`) | T12 | Not a T13 concern; listed so nobody re-opens it |

**No upstream QML change is needed for any of the four defects.** That is worth
saying plainly, because the T12 seam exists and is tempting. The one QML change
in flight (the 20 s blank timer) is `docs/PROGRESS.md` §5.24a row 2 and is
already built.

---

## 7. Blast radius — what could brick a controller-only device

Ranked. A "brick" here means: the operator cannot reach a shell, a desktop, or
Gaming Mode using only the device's own buttons.

**The floor, and it is real:** holding power for ~10 s forces a hardware power
off (`docs/RECOVERY.md`). It is EC-level and no software change in this spec can
take it away. So nothing below is *permanently* unrecoverable — but several are
unrecoverable *without losing state and repeating the boot*, which on a device
with no keyboard means the operator cannot get back in to undo the change.

| Rank | Change | What goes wrong | Recoverable by | SSH open? |
|---|---|---|---|---|
| **R1** 🔴 | `HandlePowerKey=suspend` while the button emits **two** `KEY_POWER` presses per cycle (§2.2 A/B) | Second press lands at/after resume → immediate re-suspend. Looks exactly like a Deck that will not wake. Every subsequent press repeats it | 10 s hold → cold boot; then the drop-in is still there and the next suspend does it again. **Only SSH can undo it** | 🔴 **MANDATORY.** Run §2.2's `evtest` capture *first* |
| **R2** 🔴 | Any change that lets a **lock** appear on resume — e.g. unmasking B, or shipping the logind drop-in without shipping the mask | Password prompt on a device with no keyboard. `RECOVERY.md`'s escape does not work against a healthy lock (measured) | OSK over the lock **if** `above_lock` survived and `lizard_mode=N`; else 10 s hold, which loses the session but does clear it | 🔴 **MANDATORY** |
| **R3** 🟠 | `HandlePowerKey=poweroff` reached by accident — i.e. removing Omarchy's `10-` drop-in without adding a `99-` one | Every power tap hard-powers-off mid-work. Not a lockout, but data loss on every press and an easy misread as "sleep is broken" | Cold boot; SSH to fix | 🟠 strongly advised |
| **R4** 🟠 | `hl.unbind("XF86PowerOff")` written into `bindings.lua` with a Lua syntax error | Hyprland **silently discards the whole file**. Today that file is stock, so the visible loss is small — but the failure is invisible and the same class of mistake in `input.lua` would take the OSK's `above_lock` rule with it | `luac -p` before install + sentinel assertion catches it at write time | 🟢 no, if the guards are in place |
| **R5** 🟡 | Shipping `HandlePowerKeyLongPress=poweroff` | Users reaching for SteamOS's long-press *menu* get an abrupt power off at the threshold instead. Also shadows the 10 s recovery gesture with a 5 s one, making `RECOVERY.md` step 3 wrong as written | Behavioural only | 🟢 no |
| **R6** 🟡 | Suspend works, panel never comes back (`omarchy-system-wake` is only called from the unlock path — §5.1) | Deck appears dead after every sleep | 10 s hold | 🟠 advised for the first test |
| **R7** 🟢 | Gaming Mode gains a power key that suspends while Steam is mid-something | Worst case a Steam-side hang; gamescope survives or SDDM restarts into autologin | Cold boot | 🟢 no |

**Batching rule for the operator's one device:** R1's capture is read-only and
must come first, in the same session, before any write. R1, R2, R3 and R6 all
want an SSH session already established and verified *before* the first power
press — not opened afterwards, because "afterwards" may not exist.

---

## 8. Open questions — the honest list

Every one of these is a place where the answer below is a **guess**.

1. 🔴 **Which edge(s) produce `KEY_POWER`, and from which node.** §2.2. The
   whole of defect 1's "only while held", and the size of risk R1, hang on it.
   One read-only `evtest` capture settles it.
2. 🔴 **Does anything hold a `handle-power-key` inhibitor in Gaming Mode?**
   §3.2. If yes, the logind fix does not reach Gaming Mode and defect 2 needs a
   different answer. One `systemd-inhibit --list`.
3. 🟠 **systemd's long-press duration**, and whether the Deck's button can ever
   satisfy it. §4.0. Blocks any long-press design; blocks nothing else.
4. ✅ **ANSWERED — moot.** Question presumed s2idle; the Deck cannot enter it
   (see §9 below). Nothing calls `omarchy-system-wake` and nothing needs to:
   deep/S3 resume is driven by the EC/power button at the hardware level, and
   §9's cycle woke on the second press with no such call anywhere in the chain.
5. ✅ **ANSWERED — deep (S3), not s2idle**, and gamescope survives it.
   `docs/findings/P22-deck-conformance-sweep.md` §9.6/9.7 read the cause
   (`PM: Steam Deck quirk - no s2idle allowed!`, kernel `6.11.11-valve29`); §9
   below is a live suspend/resume cycle measuring the same thing from the
   journal, with gamescope's PID unchanged across it.
6. 🟡 **Does the `Lid Switch` node ever assert on a handheld?** §5.2 row D. If
   it does, the Deck locks itself for no reason. `evtest /dev/input/event1`
   during the same capture as question 1 costs nothing extra. Still open.
7. ✅ **ANSWERED — what SteamOS itself does, from Valve's code.** §4.1/§4.2 are
   filled in. The headline is that it does **not** go through logind at all:
   Valve sets `HandlePowerKey=ignore` and hands the key to `steamos-powerbuttond`,
   which forwards `steam://shortpowerpress` to the Steam client, and **Steam**
   calls suspend. Long press is **1 s** (`alarm(1)`), Valve's number, not
   systemd's. Suspend is **s2idle** and **the session is never torn down** —
   "resume to where you were" is plain suspend/resume with no restoration logic
   anywhere. 🔴 Since we deliberately do not run Steam on the desktop, that
   mechanism is unavailable to us in Desktop Mode; the systemd-primitive design
   stands on its own merits, not on parity. **Gaming Mode is different — Steam
   IS running there**, which is the first thing to check against §3's hole.

---

## 9. 🟢 HARDWARE VERIFICATION, 2026-08-12 — the whole chain, on the operator's Deck

**Everything in this section was pressed, watched and read by the operator or
measured by SSH immediately before/after, not inferred.** `stage-power-button`
and `stage-boot-default-gaming` (both built earlier the same session — see
`docs/tasks/T13-power-button-and-sleep.md` and
`docs/RECOVERY.md`'s new section) were deployed via `deck-sync.sh` and run for
real, then the Deck was rebooted.

### 9.1 Deploy sequence actually run, in order

1. `stage-desktop-settings` — installed the **global** sleep-lock mask
   (`/etc/systemd/user/omarchy-sleep-lock.service -> /dev/null`, replacing the
   fragile per-user-only mask `docs/findings/P22-deck-conformance-sweep.md` §5
   found). **Verified on disk**, both before and after a bug fix (§9.2).
2. `stage-power-button` — installed the udev rule and the logind drop-in.
   **No live effect**, by design (§2.2's "nothing has changed yet" — removing a
   udev tag live cannot reliably un-register a device logind already
   enumerated). Confirmed dormant before reboot: files present,
   `HandlePowerKey` unchanged in the live logind state.
3. `stage-boot-default-gaming` — installed and enabled
   `deck-boot-default-gaming.service`. Confirmed dormant before reboot:
   `ActiveState=inactive`, `Session=omarchy` (Desktop) still the live default.
4. `sudo reboot`.

### 9.2 🐞 Found on the way: `$SUDO -u` breaks when the script is already root

Running `stage-desktop-settings` under `sudo ./deck-session.sh` (root from the
very start, so `stage_preconditions` sets `SUDO=""`) failed on the idle-policy
write with `-u: command not found` — exactly the failure a comment in the file
had predicted for these three call sites and explicitly left unfixed
("a separate change with its own tests"). Fixed by routing all three through
the already-written `run_as_desktop_user` helper (previously used nowhere and
itself untested). Two new regression assertions added to
`test/unit/test-deck-session.sh` — there were previously **zero**, because the
suite's fake-sudo harness always sets `SUDO` to a non-empty stub and never
exercises the empty-and-root case. Re-deployed; `shell.json`'s `idle` block was
then confirmed written (`{screensaver: 150, lock: 86400}`, 4 top-level keys
intact — the seed-then-patch path did not strip the rest of the file).

### 9.3 Reboot: landed in Gaming Mode

**MEASURED, read-only, immediately post-boot** (uptime "up 0 min"):

```
$ pgrep -a gamescope-wl-style-check   # (illustrative name only; real check below)
984 gamescope --generate-drm-mode fixed --xwayland-count 2 -w 1280 -h 800 \
    --default-touch-mode 4 --hide-cursor-delay 3000 --max-scale 2 \
    --fade-out-duration 200 --cursor-scale-height 720 -e \
    -R /run/user/1000/gamescope.La4FWrW/startup.socket \
    -T /run/user/1000/gamescope.La4FWrW/stats.pipe -O *,eDP-1

$ systemctl status deck-boot-default-gaming.service
Active: active (exited) ... Process: ExecStart=/usr/local/bin/deck-session-select gamescope --no-restart (code=exited, status=0/SUCCESS)

$ systemctl --failed
(empty)
```

`deck-boot-default-gaming.service` ran, exited 0, and the live session is
`gamescope`, not the desktop the Deck was left in before the reboot (`Session=
omarchy`). This is the first real boot with the unit installed; §7's `[H]`
verification row for the reboot direction is closed.

### 9.4 Power button: suspend, on the operator's own press — Gaming Mode

Operator report, verbatim intent: one short press suspended the Deck; a second
press resumed it, straight back into Gaming Mode, no password. **Corroborated
independently from the journal and process table, not taken on the operator's
word alone:**

```
$ journalctl -b | grep -iE "PM: suspend|PM: resume"
Aug 12 19:36:00 steamdeck kernel: PM: suspend entry (deep)
Aug 12 19:36:10 steamdeck kernel: PM: suspend exit

$ pgrep -a gamescope        # BEFORE and AFTER: same PID, 984
951 /bin/sh /usr/bin/start-gamescope-session
984 gamescope --generate-drm-mode fixed ... (identical argv to §9.3)
```

Three things settled by this, that were INFERRED or unmeasured before tonight:

1. 🟢 **§4.2 / open question 5**: suspend really is **deep (S3)**, matching
   `P22`'s `dmesg` reading (`PM: Steam Deck quirk - no s2idle allowed!`) from a
   *second, independent method* — a live suspend/resume cycle, not a sysfs read.
2. 🟢 **"The session is never torn down" is now MEASURED, not just read out of
   `gamescope-session`'s source.** Same PID before and after a real ~10 s
   suspend. Desktop Mode's equivalent claim (§4.2 table) has still only been
   read from source, not cycled — it is the natural next hardware check.
3. 🟢 **Open question 4 is moot**, and cleanly so: nothing in this chain calls
   `omarchy-system-wake`; the EC/power button woke the machine at the hardware
   level, exactly as §4.2's SteamOS reading predicted for a machine with no
   Steam mediating it.

**Three pre-existing, boot-time failed units were also observed**
(`galileo-mura-setup.service`, `ibus-gamescope.service`,
`steam-notif-daemon.service`; all `203/EXEC`, all timestamped **19:35:09** —
during the boot into Gaming Mode, a full minute before the suspend test began
at 19:36:00). **Not a regression from this work**: `jupiter-hw-support` was
skipped by an earlier operator decision (`docs/PROGRESS.md`), and these three
look like components that package would have shipped. Worth a follow-up row,
not a blocker for T13.

### 9.5 What is still open after tonight

- Desktop Mode's own suspend/resume cycle (only Gaming Mode was pressed
  tonight) — same-PID-across-suspend needs its own measurement there.
- Whether the System menu is left open after a Desktop Mode press, as §2's
  design note predicts (the duplicate press is gone, so nothing closes it).
- The `Lid Switch` question (§8 item 6).
- The three `203/EXEC` units, if the operator wants Gaming Mode's audio/IME/
  notification helpers working — separate from T13's scope.

### 9.6 Desktop Mode: also suspends and resumes clean — and the menu-flash prediction was too pessimistic

**Operator report, same session, immediately after §9.4:** switched to Desktop
Mode, pressed the power button — suspended, resumed straight back into Desktop
Mode, no password. One catch: right before sleeping, the System menu opened
for a **split second**, then the screen went dark.

That is a **better** outcome than the deploy-time warning predicted (§9.1's
stage output said Desktop Mode would leave the menu **open** behind the
suspend, not flash it), and the reason is a mechanism this file had not
worked through: **the udev `power-switch` tag change only affects what
`logind` watches. It does nothing to what the compositor sees.** Hyprland's
`XF86PowerOff` bind (§2.1) reads raw key events off its own input layer,
which still receives **both** `event2` and `event4`'s presses regardless of
either one's udev tags — udev tags are a `logind`-only concept, invisible to
libinput/Hyprland's device handling. So `omarchy-menu toggle system` still
fires **twice**, ~130–200 ms apart (§2.2's measured gap), toggling the menu
open then shut, exactly as before this fix. What changed is only the
**suspend** side: `logind` now sees a single tagged press (`event4` alone)
and can act on it immediately, and on this run it won the race — the screen
went dark before the menu's open animation, or the second toggle-closed call,
had time to be seen. **MEASURED once, n=1.** Under different compositor load
or animation settings the race could resolve the other way and the menu
could be visibly open for longer; this is not a guarantee, just what
happened this time.

`stage-power-button`'s printed guidance was corrected to describe this
mechanism rather than the untested prediction, and the `hl.unbind` line is
now offered as an **optional cosmetic** fix rather than "the supported fix"
for a problem that, so far, does not visibly occur.

> ⚠️ **SUPERSEDED 2026-08-16 — see §9.6a.** The mechanism above is right; the
> conclusion drawn from it was wrong twice over. The flash is not a race that
> suspend "wins" — it is the double toggle itself, measured at **114 ms of
> visible menu** with suspend blocked entirely — and it recurred on every
> build the operator ran. Printing the fix instead of installing it is what
> kept it in the product.

### 9.6a ✅ FIXED 2026-08-16 — the flash is the double toggle, and the unbind now ships

Reproduced on the operator's Deck without touching the power button, by
replaying §2.2's two sources through two uinput keyboards **165 ms apart**
with `systemd-inhibit --what=handle-power-key --mode=block` held, so `logind`
could not answer and only the compositor could:

```
17:00:18.379  openlayer>>omarchy-menu     # hyprland .socket2.sock
17:00:18.493  closelayer>>omarchy-menu
```

**114 ms of System menu on screen, with suspend taken out of the picture
entirely.** A single synthetic event through the same harness left the menu
**open** instead — the same mechanism seen from the other side, and the
`grim` capture of it is the "System…/Screensaver/Suspend/…/Gaming Mode"
sheet the operator described. So suspend is not what closes the menu and not
what makes the flash brief; the second `toggle` is. The race framing above is
wrong, and "n=1, might not recur" was wrong too — it is deterministic, and
the operator saw it on more than one build.

⚠️ The polkit detail, because it is what made this testable at all: an
`inhibit-handle-power-key` **block** lock is refused to an SSH session
(`Failed to inhibit: Access denied`). Taking it *through the compositor* —
`hyprctl eval 'hl.exec_cmd([[systemd-inhibit …]])'` — puts the child in
session 9 on seat0, which polkit does grant.

`stage-power-button` now installs `hl.unbind("XF86PowerOff")` into the
desktop user's `~/.config/hypr/bindings.lua`, as a marked, re-runnable block
beside the two files it already writes, and verifies it against the live
compositor (sentinel + `hyprctl -j binds`). Verified on hardware the same
day: `openlayer>>omarchy-menu` no longer appears for either the single- or
the double-source replay, and the user's own bindings in that file survive
the splice.

**Net effect: all four of the operator's original defects are now closed on
real hardware** — Desktop Mode suspends, Gaming Mode suspends, both resume to
where they were with no password, and a reboot always lands in Gaming Mode.
