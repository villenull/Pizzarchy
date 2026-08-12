# T13 — the power button and sleep: work spec

**Evidence and every citation: `docs/findings/T13-power-button-and-sleep.md`.
Read it first — this file is the build order, not the argument.**

**Status:** specified 2026-08-12 (session 22). Nothing built.
**Model:** Opus. This is hardware control logic on a device with no keyboard,
and one of the changes can produce a suspend loop (R1). Same class as
`docs/PLAN.md` §11.
**Depends on:** nothing to *start* — step 1 is read-only. Shipping depends on
T5d (the `omarchy-deck` package + the `configure_deck` phase) for the bake-ins.
**Blocks:** nothing. This is a defect fix, not a phase gate.
**Size:** M. One read-only hardware capture, three small stages in
`src/deck-session.sh`, three bake-in rows in T5, one docs correction.

---

## Objective

Make the Steam Deck's power button behave the way its owner expects:

1. **Desktop Mode:** a press suspends. It must stop opening the System menu.
2. **Gaming Mode:** a press suspends. It must stop doing nothing.
3. **Resume:** returns to the session you left — desktop to desktop, gaming to
   gaming — **with no password prompt**, deliberately and permanently.
4. Match stock Steam Deck behaviour where we can, and **say plainly where we
   cannot**, rather than implying parity we do not have.

---

## Why this shape and no other

**Because three of the four defects have one cause, and it is already read.**

`etc/systemd/logind.conf.d/10-ignore-power-button.conf:2` sets
`HandlePowerKey=ignore` **system-wide**, and
`default/hypr/bindings/utilities.lua:9` gives the key to `omarchy-menu toggle
system` **in Hyprland only**. Desktop Mode therefore gets a menu; Gaming Mode,
which is Valve's `gamescope-wayland` session and has no Hyprland, gets nothing.
Neither mode gets sleep, because the only component that would have provided it
was switched off. (`docs/findings/T13-power-button-and-sleep.md` §2.1, §3.1 —
READ, both.)

**Because SteamOS's own mechanism is one we deliberately removed.** SteamOS does
not use logind either: `steamos-powerbuttond` reads the button from evdev and
forwards `steam://shortpowerpress` to the **Steam client**, which calls suspend
(finding §4.1, READ from `powerbuttond.c`). We do not autostart Steam on the
desktop — §2.6, revised on measured evidence, because a resident Steam takes the
controller and leaves the desktop with no input at all (R-41). **So parity is
not available in Desktop Mode and the systemd-primitive design has to stand on
its own merits.** It does; but the spec must not claim it is "what SteamOS
does".

**Because "resume to where you were" is nearly free and we should not build
it.** SteamOS ships no restoration logic — `gamescope-session` has zero
suspend/resume/inhibit code and `steamos-session-select` is never invoked on
resume (finding §4.2, READ). Our stack is the same shape: nothing on the
Omarchy sleep path switches sessions either. Requirement 3's first half is
already true and needs **verification, not code**.

**Because the one thing that is not free is the lock**, and the lock is the
thing that can strand this device. `omarchy-sleep-lock.service` is masked on the
test Deck **by hand**; `src/` carries no mask at all. A fresh install from our
ISO would suspend and then present a password screen on a device with no
keyboard, no unlock IPC, and a documented recovery procedure that was measured
not to work against a healthy lock. That gap must close in the same change that
makes the power button suspend, **not after it.**

**Because one hypothesis is load-bearing and unmeasured.** The menu appearing
"only while held" means `XF86PowerOff` reaches Hyprland **twice** per press
cycle (finding §2.2 — the toggle semantics are READ; the double event is
INFERRED). Valve blacklisted the Deck's ACPI power-button node by name
(`STEAMOS_POWER_BUTTON_IGNORE=1`, finding §4.1, READ), which raises the prior
sharply without settling it. If two `KEY_POWER` presses arrive per press, handing
the key to logind yields two suspend requests — the second landing at or after
resume. **That is a suspend loop on a device whose only other escape is a
ten-second hardware hold.** Step 1 exists to kill that hypothesis before any
write happens, and everything after it is conditional on what step 1 says.

---

## Prerequisites

- 🔴 **An SSH session to the Deck, open and proven working, before the first
  power press.** Not opened afterwards — "afterwards" may not exist. Prove it
  with a command that returns output, not by seeing a prompt.
- A Deck snapshot (`tools/deck-snapshot.sh`) before any write in steps 2–4
  reaches hardware. Current is **#13** (`pre-OSK-parity`).
- The Deck's current state, from `docs/START-HERE.md`: boots to Gaming Mode,
  `lizard_mode` N, mapper active, **`omarchy-sleep-lock` masked by hand**, both
  rotations live. ⚠️ That mask is the reason the operator sees a *menu* rather
  than the §5.24 lock screen. **Do not unmask it to "reproduce the original
  bug".**
- `evtest` (package `evtest`) or `libinput debug-events` on the Deck. Confirm
  which exists **before** the session; installing packages mid-capture pollutes
  it.
- Read `docs/findings/T13-power-button-and-sleep.md` §2.2 and §7. §7's ranking
  decides the order of everything below.

---

## Steps

### 1. 🔴 THE CAPTURE — read-only, on hardware, and it gates the rest

**Nothing in steps 2–4 may be written to the Deck before this runs.** It answers
four open questions at once, writes nothing, and takes about ten minutes.

⚠️ **Enumerate every candidate node, not the first match.** The Deck has **two**
`Power Button` evdev nodes — `PNP0C0C/…/event0` and `LNXPWRBN/…/event2` — plus a
`Lid Switch` at `event1`, all MEASURED in
`docs/findings/P15-recon-raw/input-devices.txt`. Valve's own hwdb blacklists an
ACPI power-button node **by name** on this hardware, so "the obvious one" is
exactly the one that may be wrong. Re-derive the list on the day; do not trust
the 2026-08-10 recon for node numbering.

```bash
# 1a. Re-enumerate. Node numbers are not stable across boots.
ssh steamdeck 'grep -B4 -A6 -i "power button\|lid switch" /proc/bus/input/devices'

# 1b. Capture BOTH power nodes and the lid, with --grab so the presses reach
#     nothing else. Substitute the node numbers 1a printed.
ssh steamdeck 'for n in 0 1 2; do sudo timeout 25 evtest --grab /dev/input/event$n \
  > /tmp/t13-event$n.log 2>&1 & done; wait'
```

While that runs, on the Deck: **two deliberate 3-second holds**, then **two
quick taps**, with a few seconds of stillness between each so the log is
readable. Do it once in **Desktop Mode** and once in **Gaming Mode**.

```bash
# 1c. Read it back.
ssh steamdeck 'for n in 0 1 2; do echo "=== event$n ==="; grep -E "KEY_POWER|SW_LID|KEY_WAKEUP" /tmp/t13-event$n.log; done'
```

⚠️ **Negative control, mandatory.** An empty log is ambiguous between "this node
is silent" and "evtest never attached". Prove the instrument was looking: every
log must contain the header block `Input device name:` before you may read a
missing `KEY_POWER` as evidence of anything (`docs/PROGRESS.md` §5.30c — a check
that proves something ABSENT must also prove it was LOOKING).

**Also capture, in the same session, all read-only:**

```bash
ssh steamdeck 'systemd-inhibit --list --no-pager'                    # in GAMING mode
ssh steamdeck 'cat /sys/power/mem_sleep'                             # s2idle or deep
ssh steamdeck 'busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
                 org.freedesktop.login1.Manager HandlePowerKey'
ssh steamdeck 'pacman -Qq | grep -iE "powerbuttond|jupiter|steamos-manager" || echo NONE'
```

**What each answer changes:**

| Reading | Consequence |
|---|---|
| **Exactly one `KEY_POWER value=1` per physical press**, and `value=0` at release, separated by the hold duration | Best case. §2.2 hypothesis C. `HandlePowerKey=suspend` is safe **and** `HandlePowerKeyLongPress=` is viable. R1 drops to 🟢 |
| **Two `value=1` events per press cycle**, on one node or two, separated by the hold duration | §2.2 A or B confirmed. **R1 is live.** Do not ship the logind drop-in until step 2's debounce question is answered (see step 2's ⚠️). Long-press is **dead** — logind never sees a held key |
| **`value=1` immediately followed by `value=0`**, regardless of hold length | ACPI synthesis. Long-press via logind is **dead**; short-press suspend is fine and R1 is 🟢 |
| A `handle-power-key` inhibitor held by a Steam process in Gaming Mode | The logind fix will not reach Gaming Mode. **Escalate** — see "Escalate if" |
| `steamos-powerbuttond` **not installed** (expected — it is in none of our three package lists) | Confirms the finding §3.1 explanation for defect 2, and makes it a *missing component*, not a conflict |
| `SW_LID` events on `event1` during ordinary handling | 🔴 The Deck can lock and suspend itself for no reason. Separate defect; record it and stop |

**Record the raw logs into `docs/findings/T13-power-button-and-sleep.md` §2.2 as
MEASURED, replacing the hypothesis table.** That table is written to be deleted.

---

### 2. `stage-power-button` — the logind drop-in (`src/deck-session.sh`)

Writes `/etc/systemd/logind.conf.d/99-deck-power-button.conf`:

```ini
[Login]
HandlePowerKey=suspend
```

**Why `99-` and why a new file.** `10-ignore-power-button.conf` is owned by the
`omarchy` package — `bin/omarchy-upgrade-to-quattro:1211` passes
`--overwrite` for that exact path, so editing or deleting it loses to the next
upgrade. Drop-ins are read in lexical order and later wins, so `99-` overrides
`10-` without touching a package file. **(READ.)**

🔴 **Set the value explicitly. Do not "just remove Omarchy's drop-in".**
`man logind.conf`: `HandlePowerKey=` **defaults to `poweroff`**, not `suspend`.
Removing the override alone makes every power tap hard-power-off the Deck. This
is risk R3 and it is a one-word mistake.

**`HandlePowerKeyLongPress=` is deliberately NOT set in v1.** Reasons, all in
the finding: systemd's threshold is unread (§4.0); SteamOS's 1 s is
*powerbuttond's* number and not transferable (§4.1); a software long-press
shadows the 10 s hardware hold that `docs/RECOVERY.md` documents as the last
escape (R5); and if step 1 shows an instantaneous press+release, logind can
never fire it at all. **See "Decisions the operator owns", D1.**

⚠️ **If step 1 shows two `KEY_POWER` presses per cycle**, this step does not
ship as written. The question to answer first is whether logind coalesces two
`Suspend()` requests arriving milliseconds apart, or queues the second across
the resume. That is testable in QEMU (step 5) *before* it is testable on the
Deck, and it must be.

**Verification lives in the stage**, in this project's style: write, then read
back **from logind, not from the file**.

```bash
busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
  org.freedesktop.login1.Manager HandlePowerKey
```

Expect `s "suspend"`. This proves logind **parsed** the drop-in, which reading
the file back does not. ✅ **The instrument was checked on the dev workstation
2026-08-12: the call returns `s "ignore"` there, and a nonexistent property name
fails loudly with exit 1 and an explicit message** — so it has a working
negative control and cannot pass by being silent.

---

### 3. `stage-power-button` part 2 — the Hyprland unbind (`src/deck-session.sh`)

Splices a marker-delimited block into the created user's
`~/.config/hypr/bindings.lua`:

```lua
-- >>> deck-session.sh: power button >>>
-- docs/tasks/T13-power-button-and-sleep.md. The power key belongs to logind
-- (/etc/systemd/logind.conf.d/99-deck-power-button.conf, HandlePowerKey=suspend)
-- on this handheld. Without this unbind, upstream's
-- default/hypr/bindings/utilities.lua:9 ALSO opens the System menu on the same
-- press, so the user watches a menu flash as the device suspends.
hl.unbind("XF86PowerOff")

-- Deliberately the LAST statement. A Lua syntax error ANYWHERE above makes
-- Hyprland discard this entire file without logging a reason. Verify with an
-- ASSERTION, never a sentinel READBACK through `hyprctl eval` (which prints ok
-- and exits 0 for names that never existed -- docs/PROGRESS.md §5.24). The
-- literal broken shape is deliberately not written here: test/unit/
-- test-hyprctl-syntax.sh scans every doc outside findings/ for it, and this
-- file is in that scan set.
--   hyprctl eval 'if DECK_POWER_BIND == nil then error("bindings.lua discarded") end'
DECK_POWER_BIND = "unbound"
-- <<< deck-session.sh: power button <<<
```

**Why this seam and not the T12 patch seam.** `~/.config/hypr/bindings.lua` is
loaded **after** Omarchy's defaults (`config/hypr/hyprland.lua:14-21`, READ) and
the shipped file documents unbind-then-rebind as the supported idiom
(`config/hypr/bindings.lua:18-21`, READ). `hl.unbind` is real and upstream uses
it (`utilities.lua:61`). **A user override carries no upgrade-drift risk, so
patching an `omarchy-dev`-owned file here would be strictly worse.** T12 is for
files we cannot override; this is not one of them.

**Reuse, do not reinvent.** `install_osk_kb_layout_rule` /
`verify_osk_kb_layout` in `src/deck-session.sh` already implement exactly this
pattern for `input.lua`: marker-delimited splice, refuse a half-deleted block,
`luac -p` before install, sentinel global, assertion readback. Copy the shape.

⚠️ **Different file from `input.lua` — do not merge them.** `input.lua` carries
the OSK's `above_lock = 2` rule and the per-device XKB layout; `bindings.lua`
carries this. Two files, two blocks, and whatever bakes one in must not clobber
the other (`docs/tasks/T5-fork-plan.md` §5.3's warning, now applying to a third
block).

⚠️ **`omarchy-refresh-hyprland` overwrites this file** with the shipped default
(`bin/omarchy-refresh-hyprland:7`; the helper backs up to `<file>.bak.<epoch>`
first). Same exposure `input.lua` already has and the project already accepts —
a failure-mode row, not a redesign.

---

### 4. Ship the `omarchy-sleep-lock` mask (`src/deck-session.sh` + T5)

Today the mask exists **only as a hand-applied change on the test Deck**.
`src/` mentions the unit in one comment and masks nothing
(`src/deck-session.sh:371`, grepped).

```bash
systemctl --global mask omarchy-sleep-lock.service
```

**`--global`, under `/etc/systemd/user/`, not `--user`.**
`docs/tasks/T5-fork-plan.md` §5.6 already settled this and gave the reason:
upstream enables the unit at **first run**, in the live session, *after* our
configure phase — so a per-user mask loses the race and a `--global` mask
"is the version that cannot lose the race". T5 §5.6 also requires it in
`/etc/skel`.

**This step is what actually delivers requirement 3's "no password".** Masking
is the *only* thing that closes it: `shell.json`'s `idle.lock` and the sleep
unit are independent producers of the same lock, and neither covers the other
(finding §5.2). Keep `idle.lock = 86400`; it is necessary and not sufficient.

**State the trade-off in the code comment**, not only in a doc:

> A suspended Deck resumes **unlocked, deliberately**, because it has no
> keyboard. There is no unlock IPC, our on-screen keyboard reaches a lock
> surface only via a Hyprland layer rule one Lua syntax error away from being
> discarded, and `RECOVERY.md`'s escape was measured not to work against a
> healthy lock. The user can still lock on purpose from the System menu.

---

### 5. Automated verification (`[B]` and `[V]`)

**`[B]` — a new `test/unit/test-deck-power-button.sh`:**

- the drop-in is written to `/etc/systemd/logind.conf.d/99-deck-power-button.conf`
  and its `[Login]` section contains `HandlePowerKey=suspend`;
- 🔴 a **scanner that fails the build** if `HandlePowerKey=poweroff` or a bare
  deletion of `10-ignore-power-button.conf` appears anywhere in `src/` — R3 is a
  one-word mistake and deserves a guard, in the same spirit as
  `test/unit/test-hyprctl-syntax.sh` scanner 3;
- the `bindings.lua` block round-trips: splice into a fixture, re-splice, assert
  idempotence and that content outside the markers survives;
- the block is `luac -p`-clean, **and a deliberately broken variant is rejected**
  (the negative control — without it the check passes when `luac` is missing);
- the sentinel is the last statement in the block;
- the `--global` mask symlink path is asserted, and `/etc/skel` too.

**`[V]` — QEMU:**

- after an install, the target carries all three artefacts (drop-in, spliced
  `bindings.lua`, mask symlink) and `bindings.lua` still parses;
- boot the guest and assert `busctl get-property … HandlePowerKey` returns
  `s "suspend"` — **logind's parsed value**, which is the whole point;
- 🔴 **the R1 rehearsal.** Send the guest two ACPI power-button events a few
  hundred milliseconds apart (`system_powerdown` twice on the QEMU monitor) and
  record whether the guest suspends once or twice. This is the cheapest possible
  answer to "does logind coalesce?" and it costs no Deck time. ⚠️ It is a
  *model*, not the Deck: QEMU's ACPI button is not the Deck's EC. Treat a clean
  result as permission to test on hardware with SSH open, **not** as proof.

---

### 6. 🔴 The single hardware session — batch these, the operator has one device

Ordered by blast radius (finding §7). **SSH open and proven before row 1.**

| # | Row | Mode | Risk |
|---|---|---|---|
| 1 | Step 1's capture, in full, **both modes** | both | 🟢 read-only |
| 2 | Deploy steps 2–4; confirm `busctl` reads `suspend` and `hyprctl eval` asserts the sentinel | desktop | 🟠 R3/R4 |
| 3 | **Tap power. Does it suspend?** Then **tap power. Does it resume?** | desktop | 🔴 R1/R6 |
| 4 | On resume: same session, same workspace, **no password prompt** | desktop | 🔴 R2 |
| 5 | Repeat rows 3–4 in Gaming Mode | gaming | 🔴 R1 |
| 6 | Press power **five times in a row**, waking fully between each | both | 🔴 R1 — a loop shows up on repetition, not on one press |
| 7 | Confirm the System menu no longer opens on a power press | desktop | 🟢 |
| 8 | Kill the compositor while suspended (SSH), then resume — does SDDM autologin land somewhere usable? | desktop | 🟠 |

⚠️ **Row 3 is the first irreversible-feeling moment.** If the Deck suspends and
does not come back, hold power ~10 s (EC-level, always works), cold boot, and
undo over SSH. The drop-in is a single file; `rm` it and `systemctl
daemon-reload`. Know that command *before* row 3, not after.

---

### 7. Docs and bake-ins

- **`docs/tasks/T5-fork-plan.md` §5** gains two bake-in rows — the logind
  drop-in and the `bindings.lua` block — and §5.6's mask row moves from
  "planned" to "specified here". ⚠️ **Owner is whoever owns T5**, not this task.
- **`docs/RECOVERY.md`** — its "Why it happens" paragraph says *"Omarchy locks
  the session when the device sleeps, so pressing the power button can lock
  it."* After step 4 that is **false on our image and true on stock Omarchy**.
  Correct it, and add the deliberate-no-lock-on-resume statement.
- **`docs/PROGRESS.md`** gains the §2.2 measurement as MEASURED, and §5.24a's
  three-requirement table gains a cross-reference: requirement 1 ("only the
  power button should wake the panel") is *adjacent* to this work and is **not**
  in scope here — it is about the lock screen's wake surface, which this change
  removes from the resume path entirely.

---

## Which file each defect lands in

| Defect | Fix | File |
|---|---|---|
| **1** Desktop shows the System menu instead of sleeping | `HandlePowerKey=suspend` **and** `hl.unbind("XF86PowerOff")` — both, or the menu flashes as it suspends | **`src/deck-session.sh`** (new `stage-power-button`, writing a **logind drop-in** `/etc/systemd/logind.conf.d/99-deck-power-button.conf` and a marker block in `~/.config/hypr/bindings.lua`) + **T5 bake-in** |
| **1** the "only while held" half | Determined by step 1. If two events per cycle, a debounce may be needed — **do not design it before the capture** | TBD; `src/deck-session.sh` if config-only, **escalate** if it needs a daemon |
| **2** Gaming Mode does nothing | The same logind drop-in — it is system-wide and Gaming Mode has no compositor-level binding to conflict with | **the same logind drop-in.** No Gaming-Mode-specific file. ⚠️ Conditional on step 1's inhibitor check |
| **3** resume to the same session | Nothing to build — neither our stack nor SteamOS switches sessions on resume | **no file.** Verification rows 4/5/8 only |
| **3** no password on resume | Ship the `omarchy-sleep-lock.service` mask that is currently hand-applied | **`src/deck-session.sh`** (`systemctl --global mask`, `/etc/systemd/user/`) + **T5 `configure_deck` and `/etc/skel`** (`T5-fork-plan.md` §5.6) |
| **4** parity with SteamOS | Match the *behaviour*, document that the *mechanism* differs | **`docs/RECOVERY.md`** + the finding. No code |
| *(explicitly not this task)* the 5 s lock blank | already owned by `src/omarchy-deck-patches/patches/0010-lock-blank-timer-20s` | **T12** |

**No upstream QML patch is required for any of the four defects.** The T12 seam
exists and is tempting; it is the wrong tool here.

---

## Done when

Every row carries its tier. **[H] rows are batched into the one session in step
6 — do not go to the Deck more than once for this task.**

| # | Assertion | Tier |
|---|---|---|
| 1 | `test/unit/test-deck-power-button.sh` passes, including its **negative controls** — the deliberately-broken Lua is rejected and the `HandlePowerKey=poweroff` scanner fires on a planted string | **[B]** |
| 2 | `shellcheck` clean on `src/deck-session.sh`; the new stage is in `STAGES` and is re-runnable (run it twice, second run changes nothing) | **[B]** |
| 3 | After a QEMU install the target has all three artefacts and `bindings.lua` is `luac -p`-clean | **[V]** |
| 4 | In the QEMU guest, `busctl get-property … HandlePowerKey` returns `s "suspend"` — **and the same command against a guest without the drop-in returns something else**, proving the check discriminates | **[V]** |
| 5 | The R1 rehearsal: two ACPI power events 300 ms apart produce **one** suspend in the guest, recorded either way | **[V]** |
| 6 | Step 1's capture exists, names every node it watched, and each log carries evtest's `Input device name:` header — so a missing `KEY_POWER` is evidence and not silence | **[H]** |
| 7 | Desktop Mode: a power tap suspends. A power tap resumes. Same session, same workspace | **[H]** |
| 8 | Gaming Mode: a power tap suspends. A power tap resumes. Steam is still running | **[H]** |
| 9 | 🔴 No password prompt on resume, in **either** mode, on **five** consecutive sleep/wake cycles | **[H]** |
| 10 | Five consecutive cycles show **no suspend loop** — every resume reaches a usable screen and stays there for at least 30 s untouched | **[H]** |
| 11 | The System menu does **not** open on a power press in Desktop Mode, and `hyprctl eval 'if DECK_POWER_BIND == nil then error("discarded") end'` exits 0 | **[H]** |
| 12 | `docs/RECOVERY.md`'s "pressing the power button can lock it" paragraph is corrected, and the deliberate no-lock-on-resume posture is stated there in the user's language | **[B]** |
| 13 | The finding's §2.2 hypothesis table is **replaced** by the measurement, tagged MEASURED | **[B]** |

⚠️ Rows 7–11 are the only ones that can be true on hardware alone. Rows 1–5 and
12–13 must all be green **before** the operator's session starts, or the session
spends its budget on things a laptop could have caught.

---

## Failure modes

- **The Deck suspends and never wakes.** Hold power ~10 s (EC-level, below the
  OS). Cold boot. Over SSH: `sudo rm /etc/systemd/logind.conf.d/99-deck-power-button.conf
  && sudo systemctl daemon-reload`. **Know this command before step 6 row 3.**
- **The Deck re-suspends immediately on every resume (R1).** Same recovery.
  Cause is almost certainly §2.2's double event; go back to step 1's log and do
  not attempt a fix on hardware.
- **Every power tap powers the Deck off instead of suspending.** You removed
  `10-ignore-power-button.conf` instead of overriding it, or wrote
  `HandlePowerKey=poweroff`. Systemd's default is `poweroff`. Step 5's scanner
  exists to prevent exactly this.
- **A password screen appears on resume.** The mask did not take, or upstream's
  first-run enabling won the race. `systemctl --user is-enabled
  omarchy-sleep-lock.service` should say `masked`. Escape: the OSK over the lock
  (STEAM+X) if `lizard_mode=N`; otherwise a 10 s hold, which loses the session
  but does clear the lock (the lock does not survive the compositor — INFERRED,
  `docs/findings/T9-lock-service-mitigation.md` §2.5 step 5).
- **The Deck locks or suspends on its own, with nobody touching it.** Look at
  the `Lid Switch` node. `utilities.lua:33` binds `switch:on:Lid Switch` to
  `omarchy-system-lid-close`, which locks; logind's `HandleLidSwitch` defaults
  to `suspend`. The Deck **has** such a node (MEASURED). Step 1 row 1c captures
  it; this is a separate defect if it fires.
- **Desktop Mode still opens the menu.** Either `bindings.lua` was discarded
  (assert the sentinel — with `error()`, never `return`) or
  `omarchy-refresh-hyprland` overwrote the file (look for
  `bindings.lua.bak.<epoch>` beside it).
- **Gaming Mode still does nothing.** Check step 1's `systemd-inhibit --list`
  output taken *in Gaming Mode*. A `handle-power-key` inhibitor makes every
  `Handle*=` setting irrelevant (`man logind.conf`, READ). See "Escalate if".
- **Nothing appears in an evtest log.** Do not conclude the node is silent until
  the log shows evtest's `Input device name:` header. Seven measurement tools
  have lied on this project (`docs/PROGRESS.md` §5.30c); an empty capture is the
  eighth waiting to happen.

---

## Escalate if

- 🔴 **Step 1 shows two `KEY_POWER value=1` events per press cycle.** Stop.
  Steps 2–4 do not ship as written. Bring the log to the operator with two
  options — a debounce, or keeping the key in the compositor for Desktop Mode
  and finding a separate answer for Gaming Mode — and let them choose. **Do not
  build a debouncing daemon without approval**; it is a new always-on component
  on the input path, which is the class of thing this project has repeatedly
  found expensive.
- 🔴 **A `handle-power-key` inhibitor is held in Gaming Mode.** The logind fix
  cannot reach Gaming Mode and defect 2 needs a different answer. The likeliest
  one is `steamos-powerbuttond` — Valve's, and the component our package lists
  omit — but it is a **redistribution and licence question** first
  (`docs/findings/P16-redistribution-and-trademark.md`), and it only works where
  Steam is running, i.e. never in Desktop Mode. Operator decision.
- **`/sys/power/mem_sleep` does not offer `s2idle`,** or the Deck resumes with a
  dead panel every time. That is a kernel/firmware question, not a config one,
  and it belongs with T1's boot-chain work.
- **Anything wants to touch `10-ignore-power-button.conf` itself.** It is
  package-owned. If overriding it turns out not to work, say so and stop; do not
  start deleting files that pacman will restore.

---

## Decisions the operator owns

Recommendation first, in plain language. None of these blocks step 1.

**D1 — long press.** SteamOS uses **1 second** (Valve's own `alarm(1)`) to open
Steam's power menu. We have no Steam in Desktop Mode and cannot reproduce that
menu.
  - **(a) Recommended: do nothing.** Leave `HandlePowerKeyLongPress=ignore`
    (systemd's default). The 10 s hardware hold stays the only long-press
    behaviour, and `docs/RECOVERY.md` stays true as written.
  - (b) `HandlePowerKeyLongPress=poweroff` — a clean shutdown on a long hold,
    but it shadows the 10 s recovery gesture with a shorter one, so RECOVERY.md
    must be rewritten. **And it may be impossible**: if step 1 shows an
    instantaneous press+release, logind never sees a held key.
  - (c) Defer entirely until step 1's data exists.

**D2 — Gaming Mode, if an inhibitor is in the way.** Ship
`steamos-powerbuttond` for parity (licence question first, and it needs Steam),
or accept that Gaming Mode's power button stays dead and document it.
**Recommend: decide only if step 1 says the inhibitor exists.**

**D3 — resume after a compositor death.** SDDM autologin restores the
**configured default** session (Gaming Mode), not the one you left. Accept that,
or persist last-session across the boot. **Recommend: accept it.** It is a rare
path, it always lands somewhere usable, and persisting session state is a new
mechanism for a case the operator has never hit.
