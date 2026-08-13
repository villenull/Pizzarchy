# T14 — the power button in Gaming Mode: work spec

**Evidence and every citation: `docs/findings/T14-gaming-mode-power-button.md`.
Read it first — this file is the build order, not the argument.**

**Status:** specified 2026-08-12 (session 22). Nothing built, **and the
recommendation is that nothing gets built.**
**Model:** Opus. Same class as T13 — hardware control logic on a device with no
keyboard, where the wrong answer is a suspend loop.
**Depends on:** `docs/tasks/T13-power-button-and-sleep.md` steps 1 and 2. T14 has
no fix of its own; it *verifies* that T13's fix reaches the second session.
**Blocks:** nothing.
**Size:** **XS** if step 1 confirms the finding — two rows appended to T13's
hardware batch and one docs line. **M** if it does not, and then it is a redesign
of T13's Desktop Mode half, not an addition to it.

---

## Objective

Settle one question and record the answer:

> **Does T13's system-wide `HandlePowerKey=suspend` already make the power button
> suspend in Gaming Mode, or does Gaming Mode need `steamos-powerbuttond`?**

and, if it does already work, **ship nothing** and say so in the places that
currently imply otherwise.

---

## Why this shape and no other

**Because the answer is "it already works", and it is read out of systemd's
implementation rather than hoped for.** logind opens the input device itself and
the only gate on the button path is `sd_device_has_current_tag(d,
"power-switch")` (`src/login/logind-core.c:347`); `button_dispatch` →
`manager_handle_action` performs **no session-activity check at all** (READ,
`github.com/systemd/systemd`). Whether the active session is gamescope, Hyprland
or a bare VT is irrelevant to logind. The seat and session shape are identical
across the switch anyway — both are SDDM autologin on `seat0`, MEASURED today.

**Because the one component that could break that is named and was grepped.** A
low-level `handle-power-key` inhibitor makes every `Handle*=` setting irrelevant
(`man logind.conf`, READ); it is **block-mode only** and **only the active
session's counts** (READ, `logind-dbus.c:3702`, `logind-action.c`). Full-tree
greps: `ValveSoftware/gamescope` has **no `org.freedesktop.login1` string and no
`Inhibit(` call anywhere**; Valve's `gamescope-session` has zero hits;
`powerbuttond` itself takes no lock. All **READ**. And the Steam client, which
nobody can grep, has a first-hand bug report from our exact configuration —
`ValveSoftware/steam-for-linux#11629`, `HandlePowerKey=suspend` on a handheld,
**closed as completed**, where the reported defect is a **missing suspend/wake
animation** and a Valve-adjacent maintainer states *"the Steam client does not
monitor the power button"*. It suspended. **READ.**

⚠️ **One earlier argument for this was wrong and is retracted in the finding.**
ChimeraOS was called a clean natural experiment — `HandlePowerKey=suspend`, no
powerbuttond. They ship ShadowBlip's `steam-powerbuttond` after all. Finding
§3.2. Do not reintroduce it.

**Because `steamos-powerbuttond` is not blocked by licence — it is blocked by
arithmetic.** It is **BSD-2-Clause** — SPDX header in `powerbuttond.c`, a
`LICENSE` file, `licenses.bsd2` in Jovian-NixOS, and a Makefile with `install:
all LICENSE` as a hard prerequisite so the notice ships automatically (all READ).
It sits in `holo-staging`, which our repo patch already configures, and costs
10.6 KiB (MEASURED from the Deck's own package DB). It is in the AUR too, but is
not AUR-*only*, so `CLAUDE.md`'s constraint is satisfied. **The redistribution
objection does not apply.** What does apply:
it **requires** `HandlePowerKey=ignore`, T13's Desktop Mode fix **requires**
`suspend`, and there is **one logind config per machine**. Adopting it therefore
deletes T13's logind step and pushes Desktop Mode back onto a Hyprland bind —
where the two-`KEY_POWER`-presses-per-press problem (MEASURED, T13 §2.2) returns,
because the `power-switch` tag steers logind and **not** libinput. It is a
downgrade wearing the shape of an addition.

**Because the parity gap is smaller than it looks.** `powerbuttond.c` sends
`shortpowerpress` on release-before-1 s and `longpowerpress` on the alarm (READ).
The short press — the one the operator described — is **exact parity** under
T13's fix. The gap is the long-press power *menu* plus a suspend/wake animation,
and both designs end in the same logind `Suspend()` call, so nothing about the
risky part of suspend is improved by routing through Steam.

**And because the daemon fails silently, which this project forbids.** Its one
action function spawns a hardcoded `$HOME/.steam/root/ubuntu12_32/steam` and, on
`posix_spawn` failure, does a bare `return` — no log, no error, no fallback
(READ, `powerbuttond.c`). Jovian-NixOS carries a patch precisely to replace that
path, which is how we know it bites in practice. `CLAUDE.md`: *"Never silently
swallow a failure."* We would be importing exactly that, in a third-party binary
we could not fix without carrying a patch of our own.

**Because this costs zero extra hardware time.** Every measurement below appends
to T13 step 6. The operator has one Deck and is busy.

---

## Prerequisites

- 🔴 **T13 steps 1 and 2 done**, i.e. the udev untag and
  `/etc/systemd/logind.conf.d/zz-deck-power-button.conf` are installed and
  `busctl … HandlePowerKey` reads `s "suspend"`. **T14 measures nothing before
  that** — a press in Gaming Mode today does nothing, and would do nothing under
  either option, so it discriminates between nothing.
- 🔴 **An SSH session open and proven working before the first power press.**
  T13's prerequisite, inherited verbatim, for the same reason: "afterwards" may
  not exist.
- The Deck **in Gaming Mode**, Steam signed in and at its home screen. Every
  reading in step 1 is meaningless taken in Desktop Mode — that baseline already
  exists (finding §2.2) and is what these are compared against.
- Read finding §4.1 before proposing anything involving `steamos-powerbuttond`.
  It is the reason "just add the package" is not available.

---

## Steps

### 1. 🔴 THE DISCRIMINATOR — read-only, in Gaming Mode, and it gates the rest

Two commands. They write nothing and need no button press.

```bash
ssh steamdeck 'systemd-inhibit --list --no-pager'
ssh steamdeck 'loginctl list-sessions --no-legend'
# then, for the graphical session id that returns:
ssh steamdeck 'loginctl show-session <id> -p Id -p Seat -p Type -p Class -p Active -p State'
```

**Read the `WHAT` column and the `MODE` column. Both.**

| Reading | Meaning | Next |
|---|---|---|
| No `handle-power-key` row **and** no `block`-mode `sleep` row | ✅ Option A confirmed. T13's fix is the Gaming Mode fix | step 3 |
| 🔴 A **`sleep`** row in **`block`** mode | **The likeliest failure.** It defeats `HandlePowerKey=suspend` from *any* session, active or not | step 2, then step 3 |
| A **`handle-power-key`** row, any holder | 🔴 Option A is dead in Gaming Mode. ⚠️ Per finding §3.2 this should be impossible for our stack — suspect an unexpected package before suspecting the analysis | **stop** — "Escalate if" row 1 |
| A `sleep` row in **`delay`** mode | ✅ harmless | step 3 |
| `Active=no` on the gamescope session | 🟠 does not affect the power key (logind needs no active session — READ), but it *does* decide whether a low-level lock counts. Record it | note and continue |

⚠️ **Two baselines exist, both Desktop Mode with Steam not running.** Finding
§2.2 (2026-08-12: two rows, `NetworkManager` + `UPower`, `sleep`/`delay`) and
`docs/findings/P17-input-and-osk.md:627` (three rows, all `delay`). ⚠️ **P17 does
not answer this question** — the same file records Steam as shut down at that
point. Do not cite it as coverage.

⚠️ **`delay` is not `block`.** A `delay` lock costs logind up to
`InhibitDelayMaxSec` (15 s here, Omarchy's `20-inhibit-delay.conf`) and then it
suspends anyway. A `block` lock stops it dead. Do not report "there were sleep
inhibitors" without the mode.

### 2. 🔴 The inhibitor trap — run this whether or not step 1 found a lock

`man logind.conf` (systemd 261, READ):

> `PowerKeyIgnoreInhibited=` … defaults to **`no`** … the lid switch does not
> respect suspend blockers by default, **but the power and sleep keys do**.

and `src/login/logind-action.c`, `handle_action_execute()` (READ) passes
**`flags = 0`** to `manager_is_inhibited` — no `IGNORE_INACTIVE`. So **a
block-mode `sleep` lock from any session, active or not, silently defeats the
power key**, and logs at `LOG_ERR`:
`Refusing … operation, sleep is inhibited by UID …/…, PID …/…`.

So repeat step 1's first command **with a Steam download deliberately running**,
and record the `MODE` column.

⚠️ **This is not an argument for powerbuttond.** Valve's daemon hands the press
to Steam, which asks logind to suspend — and logind would refuse for exactly the
same reason. The lock is upstream of both designs.

**Do not ship a mitigation from this step.** The available one is
`PowerKeyIgnoreInhibited=yes` in T13's existing drop-in, and it has two
properties that make it the operator's call and not the implementer's: it makes
the button suspend regardless of what any application is doing, and it is the one
setting in this area that **cannot be read back over D-Bus** (MEASURED — the
property does not exist on `org.freedesktop.login1.Manager`), so it has no
verification instrument in this project's style. Bring the reading; propose;
stop. See "Decisions the operator owns", D2.

### 3. [H] The press — batched into T13 step 6, not a separate trip

In Gaming Mode, with SSH already up:

1. One tap on power. **Expect: suspend.**
2. One tap. **Expect: resume into Gaming Mode, Steam still running, no password
   prompt.**
3. Repeat for **five consecutive cycles**, at least one with a download in
   flight, leaving each resume untouched for 30 s. This is T13's R1 rehearsal in
   the second session: what it is looking for is a *re-suspend on resume*.
4. Whatever happened, capture the journal:

```bash
ssh steamdeck 'journalctl -b -u systemd-logind --no-pager | tail -60'
```

🔴 **Step 4 is not optional and it is not a formality.** It is what makes a
failure interpretable instead of mute:

| journal shows | Diagnosis |
|---|---|
| power key seen, then a suspend | ✅ working |
| 🔴 `Refusing … operation, sleep is inhibited by UID …, PID …` | a **block**-mode `sleep` lock; the line names the offender. Step 2 |
| power key seen, no action, **no** "Refusing" line | a low-level `handle-power-key` lock — "Escalate if" row 1 |
| **nothing at all** | logind never saw the key. The udev untag hit the wrong node, or `event4` lost its tag. T13's `POWER_KEEP_ID_PATH` guard (`src/deck-session.sh:784`) exists for exactly this |

⚠️ **An empty capture is not evidence until you can show the instrument was
alive.** Seven measurement tools have lied on this project
(`docs/PROGRESS.md` §5.30c) and T13 step 1 burned two runs on a silent node. The
journal tail is this step's positive control: it should show *something* about
the session even on a boot where the key was never pressed.

### 4. Record the outcome — the only thing T14 actually ships

**If step 3 passes, there is no code change. The deliverable is that the
documents stop implying otherwise.**

| Where | What changes | Tier |
|---|---|---|
| `docs/findings/T13-power-button-and-sleep.md` §3.2 and §8 row 2 | Mark the "does anything hold a `handle-power-key` inhibitor" hole **CLOSED**, with the Gaming Mode `systemd-inhibit --list` output pasted in as MEASURED | **[B]** |
| `docs/findings/T13-power-button-and-sleep.md` §6.2, the "**2** Gaming Mode dead" row | Replace "**if** nothing holds a `handle-power-key` inhibitor … else **open**" with the measured answer | **[B]** |
| `src/deck-session.sh:703` and `:4671` | The comment "Valve's own handler (steamos-powerbuttond) is in none of this project's package lists" is true but reads as a *gap*. Add one clause: it is deliberate, it is BSD and available in `holo-staging`, and it is **not** shipped because it requires `HandlePowerKey=ignore`, which is incompatible with the drop-in this very stage writes | **[B]** |
| `docs/findings/T13-power-button-and-sleep.md` §4.0 and §8 row 3 | ✅ **`LONG_PRESS_DURATION` is 5 s**, `src/login/logind-button.c:54`, READ. §4.0's "do not write a number until it is read out of systemd's source" is satisfied — write it, with the file and line, and keep the warning that SteamOS's 1 s is a different program's | **[B]** |
| `docs/PROGRESS.md` §7 | Two facts: (a) Gaming Mode needs no power-button component of its own — one logind drop-in covers both sessions, because logind's button path has no session-activity check; (b) `steamos-powerbuttond` is BSD-2-Clause and available in `holo-*`, and is deliberately **not** shipped for design reasons, not licence ones | **[B]** |

⚠️ **`src/deck-session.sh` is T13's file, not T14's.** Hand the wording over;
do not edit it from this task while T13 is in flight.

### 5. Only if step 1 or step 3 fails — Option B, and it is a redesign

**Do not start this without the operator.** It deletes T13's logind step. The
shape, recorded so nobody has to rediscover it:

1. Revert T13's `zz-deck-power-button.conf` to leave `HandlePowerKey=ignore`
   (Omarchy's `10-` drop-in already provides it — nothing to write).
2. `steamos-powerbuttond` into `iso/overlay/configs/deck/deck-mirror.packages`
   (repo-qualified: `holo-staging/steamos-powerbuttond`) and into the
   `omarchy-deck` package's depends, T5 seam S4. ⚠️ `deck-mirror.packages`'
   header note that *"holo-staging carries no package this build names"*
   (`iso/overlay/patches/deck-valve-repos.patch:41`) stops being true and must be
   corrected in the same commit.
3. Read `/usr/lib/udev/rules.d/steamos-power-button.rules` first — it lands
   **system-wide** and therefore also applies in Desktop Mode, and it is the one
   file in the package still unread (finding §3.1c). It is at
   `raw.githubusercontent.com/evlaV/steamos-powerbuttond/master/steamos-power-button.rules`,
   or inside
   `https://steamdeck-packages.steamos.cloud/archlinux-mirror/holo-main/os/x86_64/steamos-powerbuttond-4.2-2-x86_64.pkg.tar.zst`
   (10.6 KiB). ⚠️ Pull from **`holo-*`**, not `jupiter-*`: `jupiter-main` froze at
   3.1-2 and everything from 3.2 to 4.2-2 is in `holo-*` (READ).
4. 🔴 Verify Arch's `steam` puts a binary at **`$HOME/.steam/root/ubuntu12_32/steam`**
   and acts on `steam://shortpowerpress`. We install Arch's `steam`, not
   `steam-jupiter-stable` (finding §4.5), and powerbuttond hardcodes that path
   and **silently returns** if `posix_spawn` fails (finding §3.1b, READ). If it
   is wrong, this option ships a power button that does nothing and says nothing
   — the failure class `CLAUDE.md` names first. Jovian-NixOS patches exactly this
   path; budget for carrying the same patch.
5. **Then** solve Desktop Mode again: a Hyprland bind to `systemctl suspend`
   receives **both** `KEY_POWER` presses (MEASURED, T13 §2.2), because the
   `power-switch` untag steers logind and not libinput. Suppressing the second
   for a compositor needs `LIBINPUT_IGNORE_DEVICE=1` or clearing `ID_INPUT*` —
   which removes the node from every Wayland client. **Larger blast radius,
   untested here, and it must be designed before it is written.**

🔴 **Never Option A and Option B together.** `HandlePowerKey=suspend` *plus*
powerbuttond means every Gaming Mode press suspends twice — logind's suspend and
Steam's — which is T13's risk R1 with an extra actor. Finding §5 names it Option
C and rejects it.

### 6. ✅ The long press — the number is now read, and it says don't

Unblocked by T13's untag for the first time: with the ACPI node gone from
`power-switch`, `event4` is the only node logind watches and it **does** track a
hold (MEASURED, T13 §2.2, 2.92 s). So `HandlePowerKeyLongPress=` is mechanically
possible in both modes.

**`src/login/logind-button.c:54` (READ, `github.com/systemd/systemd`):**

```c
#define LONG_PRESS_DURATION (5 * USEC_PER_SEC)
```

**5 seconds.** Byte-identical at v255, v256, v257 and `main` (262~devel). ⚠️ The
Deck runs **v261**, bracketed but not itself opened — a five-minute check for
anyone who needs it exact. **This closes T13 §8 open question 3 and T13 §4.0's
"do not write a number"; record it in T13 too.** Do **not** conflate it with
SteamOS's 1 s, which is `powerbuttond`'s `alarm(1)`.

🔴 **And 5 s is the reason not to use it.** It sits inside the ~10 s hardware hold
`docs/RECOVERY.md` documents as the last escape, so every use of the documented
recovery gesture would trip a software action at second five. T13's R5, now a
concrete collision.

⚠️ **Setting it is not additive.** `logind-button.c:286-297` (READ): the
long-press timer arms only when `HandlePowerKeyLongPress` is neither `ignore` nor
equal to `HandlePowerKey`. With the default `ignore`, the short action fires on
key **down**; arm a long press and it moves to key **release**. Anyone touching
this changes when an ordinary press takes effect.

Leave T13's explicit `HandlePowerKeyLongPress=ignore` in place until the operator
decides otherwise — D3.

---

## Done when

Every row carries its tier. **[H] rows are the two appended to T13 step 6 — T14
adds no separate trip to the Deck.**

| # | Assertion | Tier |
|---|---|---|
| 1 | Gaming Mode `systemd-inhibit --list` output is recorded in `docs/findings/T14-gaming-mode-power-button.md`, tagged MEASURED, with both the `WHAT` and `MODE` columns intact | **[H]** |
| 2 | That output is compared explicitly against the Desktop Mode baseline in finding §2.2, and the delta is stated in words | **[B]** |
| 3 | Gaming Mode: a power tap suspends; a tap resumes; Steam is still running; the session is Gaming Mode | **[H]** |
| 4 | 🔴 Five consecutive Gaming Mode cycles, **no password prompt** and **no re-suspend on resume**, each resume left untouched 30 s | **[H]** |
| 5 | At least one of those cycles ran with a Steam download in flight, and the download's state after resume is recorded — resumed, restarted, or broken | **[H]** |
| 6 | `journalctl -u systemd-logind` from that boot is captured **whatever the outcome**, and the three-way table in step 3 is applied to it in writing | **[H]** |
| 7 | T13 finding §3.2 and §8 row 2 no longer describe the inhibitor question as open | **[B]** |
| 8 | T13 finding §6.2's Gaming Mode row no longer says "else **open**" | **[B]** |
| 9 | `src/deck-session.sh`'s two powerbuttond comments say *why* it is not shipped, not merely that it is absent | **[B]** |
| 10 | `docs/PROGRESS.md` §7 carries the one-line fact | **[B]** |
| 11 | **No new package appears in any of the three package lists**, and `deck-nvidia-dry-run.sh` is unaffected — i.e. the recommended outcome is verifiable by a diff that adds nothing to `iso/overlay/configs/deck/` | **[B]** |
| 12 | T13 finding §4.0 and §8 row 3 carry `LONG_PRESS_DURATION = 5 * USEC_PER_SEC`, with `src/login/logind-button.c:54` beside it, and still warn that SteamOS's 1 s is a different program's number | **[B]** |
| 13 | The retracted ChimeraOS argument is recorded as retracted in `docs/findings/T14-gaming-mode-power-button.md` §3.2 and appears nowhere as live evidence | **[B]** |

⚠️ Rows 1 and 3–6 are the only ones needing hardware, and they are already inside
T13's session. Rows 2 and 7–11 are documentation and must be done **after** the
readings, not in anticipation of them.

---

## Failure modes

- **A `handle-power-key` inhibitor is held in Gaming Mode.** Option A cannot
  reach Gaming Mode. Stop; do not install anything; go to "Escalate if" row 1.
  ⚠️ Note the asymmetry before panicking: even then, T13's Desktop Mode fix is
  unaffected, because Steam is not running there.
- **The press does nothing, no inhibitor, and the journal shows the key.** logind
  saw it and declined. Look for a `block`-mode `sleep` lock (step 2) before
  anything else.
- **The press does nothing and the journal shows nothing.** logind never saw the
  key. This is a T13 udev problem, not a T14 one: the untag caught `event4`, or
  the rule sorted before `70-power-switch.rules` and removed nothing.
  `udevadm info /dev/input/event4 | grep TAGS` and compare against
  `POWER_KEEP_ID_PATH`.
- **It suspends twice per press.** Someone installed `steamos-powerbuttond` while
  `HandlePowerKey=suspend` is live — finding §5's Option C. `pacman -Q
  steamos-powerbuttond`; if it is there, that is the cause and the fix is to pick
  one mechanism.
- **Resume lands in the wrong mode.** gamescope died across the suspend and SDDM
  restarted into autologin's **configured default** session. On this Deck the
  default *is* Gaming Mode (`docs/START-HERE.md`), so Gaming Mode is the mode this
  hides in — a Desktop Mode press that resumes into Gaming Mode is the same bug
  and is T13's §5.1 concern, not a new one.
- **The Deck suspends and never wakes.** T13's recovery verbatim: hold power ~10 s
  (EC-level), cold boot, then over SSH remove T13's logind drop-in and
  `daemon-reload`. **Know the exact command before the session starts.**
- **A download is broken by the suspend.** Record precisely what "broken" means —
  paused, restarted from zero, or corrupt. This is the one place T14 could
  discover a real reason to want Steam mediating, and a vague report wastes it.

---

## Escalate if

- 🔴 **Step 1 finds a `handle-power-key` inhibitor.** The whole recommendation
  inverts. Bring the operator the inhibitor row, finding §4.1 (why powerbuttond
  forces a Desktop Mode redesign) and finding §4.3 (the double press in the
  compositor), and let them choose. **Do not install the package first and design
  Desktop Mode afterwards** — that ordering is how you end up with Option C.
- 🔴 **The Gaming Mode press does nothing that steps 1–3 explain.** An
  unidentified mechanism on the input path. Stop. T13's three ranked hypotheses
  were all wrong and the measurement is what settled it; do the same here rather
  than ranking a fourth.
- 🔴 **A `block`-mode `sleep` lock appears in ordinary use.** Operator decision
  between a button that is dead during downloads and `PowerKeyIgnoreInhibited=yes`
  — D2. ⚠️ **Do not let this be argued into "so we need powerbuttond".** Valve's
  daemon asks Steam, which asks logind, which refuses for the same reason. The
  lock is upstream of both designs.
- 🟠 **Anything proposes installing `steamos-powerbuttond` alongside
  `HandlePowerKey=suspend`.** Reject it and cite finding §5 Option C. It is the
  single most likely wrong turn in this task, because it looks additive.
- **Anyone wants a long-press action.** Not before `LONG_PRESS_DURATION` is read
  from systemd's source with file and line (step 6), and not without D3.

---

## Decisions the operator owns

Recommendation first, plain language. **None of these blocks step 1.**

**D1 — Ship `steamos-powerbuttond`, or nothing?**
**Recommendation: nothing.** The power button will suspend in Gaming Mode from
the same one-line logind setting that fixes Desktop Mode, and adding Valve's
daemon would force us to switch that setting *off* and rebuild the desktop half
on a shakier mechanism. What you give up is the **long-press power menu** —
Suspend / Shut Down / Restart on a controller — and **Steam's suspend/wake
animation**, so the screen will fade to black instead. The short press itself
behaves exactly as your stock Deck does either way. Somebody else already ran our
setup and filed a bug about it; the bug was the missing animation, and Valve
closed it. *Say so if the menu matters to you; it is the only honest reason to
change this.*

⚠️ Licence is **not** the reason we are saying no — Valve's daemon is BSD and we
could ship it freely. The reasons are that one machine gets one logind setting,
and that the daemon does nothing at all, silently, if it cannot find Steam where
it expects it.

**D2 — If the button is dead while a game is downloading, force it anyway?**
**Recommendation: bring me the measurement first, then almost certainly no.** A
setting exists (`PowerKeyIgnoreInhibited=yes`) that makes the button suspend
regardless of what Steam is doing. It also means the Deck sleeps in the middle of
whatever it was told not to interrupt, and unlike everything else in this area we
cannot read the setting back to prove it took. If this turns out to happen in
practice, it deserves its own look, not a pre-emptive switch.

**D3 — A long press that powers off?**
**Recommendation: no — and we now know why, rather than just suspecting it.**
systemd's "long press" is **5 seconds** (read out of its source today). Holding
the button for about 10 seconds is the last-resort way to force the Deck off when
everything else has failed, documented in `docs/RECOVERY.md` — so a software
action at second five sits directly inside the gesture you would be reaching for
in an emergency. There is also a side effect nobody would expect: turning the
long press on moves the *ordinary* press from firing when you push the button to
firing when you let go.

**D4 — Reading the one remaining unread file in Valve's package?**
**Recommendation: only if D1 goes the other way.** Under the recommended option
we never install it, so what is inside it cannot affect us. Its source, licence,
service unit and hardware blacklist have all been read already; what is left is a
single udev rules file, and it is a one-minute fetch from Valve's own mirror if
you want it closed out anyway.
