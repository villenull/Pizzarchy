# P39 defect 3 — the ~10 s black panel between the Omarchy logo and Gaming Mode

Bug: `docs/KNOWN-ISSUES.md` §3. Operator's words, on a full install from the
released ISO: *"booting into gaming mode still shows a black screen for ~10
seconds (this is period time after seeing the omarchy logo where the screen is
black)"*.

**Status: NOT DETERMINED. No owner is named here, because no measurement was
taken.** The Deck was off the network for the whole of this session and every
decisive instrument lives on it. What follows is (a) what the existing record
already proves, (b) a correction to that record that changes the shape of the
problem, (c) a ranked hypothesis list with the structural evidence for each, and
(d) a single probe run plus a reboot plan that settles all of it.

Every claim below carries a label. Read them.

---

## 0. Why there is no measurement — and the exact instrument that is missing

**MEASURED (dev machine, 2026-08-17):** `deck@192.168.100.25` was unreachable
for the entire session. Not firewalled — absent.

```
$ ping -c 3 192.168.100.25
From 192.168.100.14 icmp_seq=1 Destination Host Unreachable

$ ip neigh | grep '\.25 '
192.168.100.25 dev enp8s0 FAILED
192.168.100.25 dev wlan0  FAILED

$ ssh -o BatchMode=yes -o ConnectTimeout=8 deck@192.168.100.25 'echo OK'
ssh: connect to host 192.168.100.25 port 22: No route to host
```

**Positive control for that "absent" claim** — the sweep was demonstrably
looking, and found other hosts on the same broadcast domain from the same
shell:

```
$ for i in $(seq 2 254); do ping -c1 -W1 192.168.100.$i ... ; done
up: 192.168.100.2   up: 192.168.100.3   up: 192.168.100.5
up: 192.168.100.6   up: 192.168.100.8   up: 192.168.100.9
up: 192.168.100.14  up: 192.168.100.22  up: 192.168.100.27
```

`FAILED` in `ip neigh` is an ARP-level negative: no host on the LAN answered for
that address. That is stronger than "SSH is closed" and rules out both the ufw
`default deny` and the missing-sshd states that `src/pizza-ssh`'s header warns
are indistinguishable from outside. Port 22 was also closed on every host that
*did* answer, so the Deck is not merely sitting on a new DHCP lease with SSH up.

Two candidate explanations, neither checked: the Deck is asleep/off, or it
rebooted and `sshd` is not enabled (`docs/PROGRESS.md` §5.36 — SSH does not
survive a reinstall and is off by default).

A read-only capture script is staged at
`~/.cache/omarchy-deck/blackgap/probe.sh` on the dev machine, with a poller that
fires it the moment the host answers (output lands in
`~/.cache/omarchy-deck/blackgap/capture.txt`). It uses no `sudo`, starts and
stops nothing, and does not go near Steam, `deck-input-mapper.service` or
`lizard_mode`.

---

## 1. 🔴 The record's "plymouth has been gone since 659 ms" is probably a misread,
and the operator's own report is the evidence against it

This matters more than it looks, because that sentence is the reason nobody has
considered a boot-path cover, and it has been copied into three files.

**READ-SOMEWHERE — `docs/PROGRESS.md` §5.35 (session 28, from hardware):**

> `systemd-analyze`: 5.781s firmware + 7.442s loader + 5.691s kernel + 20.253s
> userspace = **39.168s**, `graphical.target` at 20.252s,
> `plymouth-quit.service` **659 ms**.

and then, one paragraph later, the interpretation:

> plymouth has been gone since 659 ms — three orders of magnitude before the
> window opens.

**INFERRED — that interpretation reads a `systemd-analyze blame` *duration* as a
timestamp.** `blame` prints `659ms plymouth-quit.service` (how long the unit took
to run); `critical-chain` prints `plymouth-quit.service @20.100s +659ms` (when it
activated, and then how long). The quoted form has no `@`, sits in a list next to
a value that IS explicitly a timestamp ("`graphical.target` at 20.252s"), and 659
ms is exactly what `ExecStart=-/usr/bin/plymouth quit` costs. A *timestamp* of
659 ms is also structurally hard: `plymouth-quit.service` is ordered around the
display manager, and the display manager is what `graphical.target` waits on at
20.252 s.

**The operator's observation is independent evidence for the same correction.**
Take the timestamp reading at face value and do the arithmetic:

| phase | MEASURED (§5.35) | what the panel shows under the timestamp reading |
|---|---|---|
| firmware | 5.781 s | Valve/Steam Deck firmware screen |
| loader (Limine) | 7.442 s | `interface_branding: Omarchy Bootloader` on `1a1b26` |
| kernel + initrd | 5.691 s | plymouth `omarchy` theme — **the logo** |
| userspace to `graphical.target` | 20.253 s | logo for 0.66 s, then **~19.6 s black** |

That predicts a black stretch of roughly **20–30 s**, and a logo visible for
under a second. The operator reports seeing the logo, and then **~10 s** black.
Both halves of the report contradict the prediction.

The reading that fits is the ordinary SDDM + plymouth one: plymouth holds the
Omarchy logo from the initrd until the display manager takes the VT at
~20 s, *then* quits — so the logo is up for ~7 s of visible time, and the black
window runs from the handover to gamescope's first frame.

**⚠️ NOT PROVEN. It is an inference from an arithmetic contradiction, and it
needs one command to settle** (§4, probe line `plymouth`). If it holds, three
files are carrying a wrong premise and one of them is shipped:

* `docs/PROGRESS.md:3391` and `:3413`
* `docs/tasks/P33-fix-round.md:410`
* `iso/overlay/configs/airootfs/usr/share/omarchy-iso/orchestrator/deck_steam_bootstrap.py:21`
  — *"so none of that window is ours to shorten"*

I did not edit any of them (`iso/overlay/**` and `docs/KNOWN-ISSUES.md` are out
of my ownership; `docs/PROGRESS.md` is not mine to rewrite on an inference).

---

## 2. What the window is made of — and why "one owner" is the wrong question

**READ (`src/deck-session.sh:8-21`, `iso/.../deck_autologin.py:149`):** Gaming
Mode is `sddm.service` autologging into `gamescope-wayland.desktop`, which execs
`start-gamescope-session`, which brings up `gamescope-session.target` and with it
`steam-launcher.service` (Valve's unit) running `steam -gamepadui`.

So between the logo vanishing and the first frame there are, in order:

1. **SDDM handover.** plymouth is torn down, SDDM takes the VT, `sddm-helper`
   execs `start-gamescope-session`.
2. **gamescope start + modeset.** gamescope is up and compositing, with no
   client. It clears to black.
3. **`ExecStartPre=/usr/local/lib/deck-session/steam-wait-online`** — ours.
   `nm-online -q -s -t 5` then `nm-online -q -x -t 20`
   (`src/deck-session.sh:1030-1046`, `:3581`). **This runs at every Gaming Mode
   start, not only the first** — the file says so itself at `:1038`.
4. **Steam launch to first drawn frame.** Verification, then `steamwebhelper`
   (CEF), then the gamepad UI commits a surface.

**Nothing in 1–4 can paint.** MEASURED (§5.35) the installed cmdline is
`quiet splash loglevel=0 systemd.show_status=false vt.global_cursor_default=0
fbcon=rotate:1` — no kernel messages, no systemd status, not even a cursor. Once
plymouth is down and before gamescope's first client, there is no channel on the
panel at all. That is by construction, and it is the same construction that
produced the first-boot black screen §5.35 fixed.

**INFERRED: the ~10 s is a chain, not a unit.** A plausible split is ~1 s
handover + ~2 s gamescope + 0–n s `nm-online` + ~4–6 s Steam-to-first-frame. Only
one term in that chain is ours and only one is measurable without a stopwatch —
which is lucky, because it is the same one.

### 2a. The one term that is ours, and the file that has already recorded it

**READ (`src/deck-session.sh:3556-3597`):** every branch of `steam-wait-online`
appends a timestamped line to `~/.local/state/deck-session/first-boot.log`,
including the seconds it waited:

```
say "connectivity confirmed after ${waited}s; starting Steam"
```

That file survives reboots (it exists precisely because the first boot's journal
did not — §5.35), it is in the user's home so it needs no `sudo`, and because
the helper runs at **every** Gaming Mode start it already holds **one line per
boot since install**.

🔴 **This is the highest-value read on the device and it needs no reboot:**

```
cat ~/.local/state/deck-session/first-boot.log
```

If those lines say `after 0s` or `after 1s`, our wait is not the gap and the
remaining time is Steam's and gamescope's — *genuinely required*, and the answer
is a splash. If they say `after 8s`, `after 10s`, we shipped the defect on
2026-08-16/17 and most of it is *recoverable*. Either answer is a full diagnosis;
neither requires a reboot.

**⚠️ Note the timeline coincidence that makes this worth checking first.** The
2-minute first-boot window was removed by doing Steam's bootstrap at install time
(`iso/.../deck_steam_bootstrap.py`; a bootstrapped client reached
`Verification complete` in **1.5 s** — MEASURED, dev machine, 2026-08-16). The
`nm-online` `ExecStartPre` was added in the same round. The ~10 s complaint is
against the release that carries both. That is not evidence, but it is a reason
to look here before anywhere else.

---

## 3. Ranked hypotheses

| # | Hypothesis | Evidence for | Evidence against | Settled by |
|---|---|---|---|---|
| H1 | **Steam launch → first frame** owns most of it | CEF/`steamwebhelper` cold start is seconds; nothing else in the chain is that slow | none gathered | `journalctl --user -b -o short-monotonic -u steam-launcher.service` vs. gamescope's first commit |
| H2 | **Our `nm-online -x -t 20` wait** owns a large slice | runs every boot by design (`:1042`); Wi-Fi association at ~20 s into boot is exactly when it is still "connecting", which is the state `-x` does *not* bail on | §5.35 measured the failing request succeeding **1 s** later, which suggests ~1 s not ~10 s — but that is one boot | `cat ~/.local/state/deck-session/first-boot.log` |
| H3 | **gamescope start + modeset** | it is unavoidably in the chain | typically 1–3 s, not 10 | kernel `drm`/`amdgpu` lines in `journalctl -b -k -o short-monotonic` |
| H4 | **SDDM handover / VT race** | `stage_sddm_resilience` (`:4104`) documents a real VT race here | that race produces a *failed session*, not a slow one | `systemd-analyze critical-chain display-manager.service` |
| H5 | **plymouth handing off** | would explain the boundary the operator describes | plymouth-quit is 659 ms of work whichever way §1 resolves | probe line `plymouth` |
| H6 | **Steam first-run work** | the classic cause of exactly this symptom | should be *gone*: the bootstrap runs at install time now | does the gap shrink on the 2nd, 3rd boot? (§5, T-A) |

**H6 is the one candidate the record actively argues against**, and it is worth
saying plainly because it is the candidate everyone reaches for first.

---

## 4. The probe — one run, no reboot, no `sudo`, settles §1 and §2a

Staged at `~/.cache/omarchy-deck/blackgap/probe.sh`. Run from the dev machine:

```
ssh deck@192.168.100.25 "bash -s" < ~/.cache/omarchy-deck/blackgap/probe.sh \
  > ~/.cache/omarchy-deck/blackgap/capture.txt
```

The lines that matter, and what each one decides:

```sh
# --- settles §1: duration or timestamp? -----------------------------------
systemd-analyze blame | grep -i plymouth          # a DURATION
systemctl show plymouth-quit.service -p ActiveEnterTimestampMonotonic
systemctl show sddm.service           -p ActiveEnterTimestampMonotonic
# subtract. If plymouth-quit activates near sddm (~20 s), §1's correction holds.

# --- settles §2a: how much of the gap is ours? ----------------------------
cat ~/.local/state/deck-session/first-boot.log
cat /etc/systemd/user/steam-launcher.service.d/50-deck-wait-online.conf
/usr/bin/nm-online -x -t 1; echo "rc=$?"    # is -x even supported here?

# --- brackets the gap -----------------------------------------------------
systemd-analyze
systemd-analyze critical-chain graphical.target
journalctl -b -o short-monotonic | grep -Ei 'plymouth|sddm|gamescope|steam|drm|amdgpu|backlight'
journalctl --user -b -o short-monotonic
```

> ⚠️ **A gap in the journal is not proof that nothing ran.** Every claim this
> report will eventually make about *who owns* the gap must come from a unit's
> own `ActiveEnterTimestampMonotonic` / `ExecMainStartTimestampMonotonic`, or
> from `first-boot.log`'s explicit `waited` figure — not from "unit X started
> before the silence and finished after it". The probe collects the timestamps
> for exactly this reason.

### 4a. Black because nothing draws, because the backlight is off, or because of DPMS?

**This Deck is OLED (`CLAUDE.md`), so the three are visually identical** — an
OLED showing black and an OLED with the panel off look the same to a camera and
to the eye. Do not try to settle this by looking. Settle it in sysfs and the
journal:

* `for b in /sys/class/backlight/*; do cat $b/bl_power $b/brightness; done` —
  `bl_power=0` is on. If something is blanking, there is a
  `backlight`/`amdgpu_bl` write in the journal with a timestamp inside the gap.
* `cat /sys/class/drm/card*-*/dpms` and the `drm`/`amdgpu` modeset lines — a
  modeset in progress leaves kernel messages with timestamps.
* **INFERRED, weak:** the operator describes Gaming Mode simply *appearing*,
  with no wake flash or fade. A DPMS-off panel coming back has a visible turn-on.
  This points at "nothing is drawing", which is also what §2 predicts from the
  cmdline. Do not rely on it; it is one sentence of recollection.

---

## 5. Reboot test plan — for the operator to run, not for an agent

I did not run any of these: the operator is using the Deck and it must not be
rebooted from under them. Each is cheap and each isolates one term.

**Before any reboot, capture the current state** — `first-boot.log` already holds
one line per boot since install, and that history is the control:

```
cat ~/.local/state/deck-session/first-boot.log        # KEEP THIS OUTPUT
systemd-analyze; systemd-analyze blame | head -30
```

**T-A — is anything still first-run-shaped?**
Reboot into Gaming Mode twice, timing the black stretch each time with a phone
stopwatch (or better, a video — see T-C). *Expected: no difference*, because the
Steam bootstrap now happens at install time. **A shrinking gap on boot 2 would
overturn that and re-open H6.**

**T-B — the discriminator for our `nm-online` wait (H2).**
Put the Deck in airplane mode / turn Wi-Fi off, reboot, time the gap. Then turn
Wi-Fi back on, reboot, time it again.
*Reasoning:* with the radio off, NetworkManager is neither running-a-connection
nor connecting, so `nm-online -x` returns **immediately** by its own documented
behaviour. With Wi-Fi on and associating during boot, it waits.
**If the gap is materially shorter with Wi-Fi off, H2 is confirmed and the time
is ours and recoverable. If it is unchanged, H2 is dead.**
Afterwards, `cat ~/.local/state/deck-session/first-boot.log` — the last two lines
are the two boots, with the `waited` seconds stated outright.

**T-C — measure the gap instead of estimating it.**
Video the panel from power-on at 60 fps and count frames between the logo
disappearing and the first Gaming Mode frame. This is the only measurement of the
*user-visible* window that does not depend on any assumption about which unit
corresponds to which pixel, and it also timestamps the *start* of the gap, which
no unit does.

**T-D — after any of the above**, run the §4 probe. `systemd-analyze` and the
journal describe the boot you just did.

**T-E — does the existing splash even work in a 10 s window?**
`rm ~/.local/state/deck-session/steam-first-boot-shown`, then reboot. That is the
one-line escape hatch the splash was built with (`src/deck-session.sh:1091`,
`:3638`). It re-arms `deck-steam-splash.service` for exactly one attempt.
Then read `~/.local/state/deck-session/first-boot.log` — every branch of the
splash logs, and a line beginning `FAILED:` names the cause.
**This is the cheapest possible test of the recommended fix, and it needs no code
change at all.** ⚠️ It is also the test most likely to fail informatively: see
§6b.

---

## 6. Recommendation — splash, not speed-up. And it is already built.

**Which case are we in?** Pending T-B, most likely: *the time is genuinely
required*. Steam's client start and gamescope's modeset are not ours to shorten,
and the record explicitly argues the remaining first-run work was already moved
to install time. The recoverable exception is H2, which T-B settles.

So the fix is to **put something on the panel**, and the correct place for it is
already decided and already implemented:

**READ (`src/deck-session.sh:1063-1123`, `:3616-3760`, `:3799-3960`):**
`deck-steam-splash.service` exists, is installed by `stage-steam-first-run`,
which **is** in `INSTALL_STAGES` (`:1589`) and `BAKE_STAGES` — so it is on every
released install. It draws a PNG through `imv` on gamescope's nested display,
lives in the session and not the boot path (a deliberate decision — a splash bug
must degrade to today's black screen, never to a broken boot), and is bounded
three independent ways: its own deadline, `RuntimeMaxSec=`, and
`PartOf=gamescope-session.target`.

**It is gated to run once, ever, and that gate is the entire defect.**
`src/deck-session.sh:1091` — `SPLASH_MARKER_REL` — with the comment at `:1089`:

> Shown ONCE: later boots reach Gaming Mode in ~39 s and the splash must not
> appear in front of a client that is about to draw.

That comment is the assumption the operator's bug report falsifies. "~39 s" is
`systemd-analyze`'s total to `graphical.target` — it is *not* time-to-first-frame,
and the ~10 s after it is exactly the window the splash was built to cover.

### 6a. Implementation spec — for the owner of `src/deck-session.sh`

🔴 **I did not edit `src/deck-session.sh`.** A sibling agent owns it and its four
test suites and is changing boot-related units in them right now. This is a spec,
not a patch. It is also **gated on T-B**: if T-B shows the gap is our
`nm-online` wait, do this *and* fix the wait; if T-B shows it is not, do only
this.

1. **`render_steam_splash()` (`:3616`) — retire the once-ever gate.**
   Delete the `marker` read/write block (`:3638`–`:3668`). Keep `SPLASH_ATTEMPT_ID`
   in the log line so a boot can still be attributed to an implementation.
   *Why the safety argument the gate encodes does not survive the change:* the
   gate protects against "a splash that crashes gets a second attempt at every
   boot for ever". With the gate gone, that becomes "a splash that crashes logs a
   `FAILED:` line at every boot" — because the script cannot fail *closed*: every
   error path is `say ...; exit 0`, and the three bounds are untouched. The state
   it protects against — a permanently black-with-text panel — is prevented by
   `RuntimeMaxSec=` and `PartOf=`, not by the marker.

2. **`render_steam_splash()` — make it win the race it now has to win.**
   Today, a missing `GAMESCOPE_WAYLAND_DISPLAY` is a hard `exit 0` (`:3690`).
   That was right for a 2-minute window and is wrong for a 10 s one: the unit is
   `After=gamescope-session.service`, and `After=` orders *starts*, not
   *readiness* — the env file may not be written when the splash execs. Poll for
   it, ~5 s at 100 ms, then fall through to the existing `FAILED:` message
   unchanged. **A splash that takes 4 s to appear in a 10 s gap is barely worth
   having; one that loses the race silently is worth nothing.**

3. **`render_steam_splash()` — tighten the handover.**
   The wait loop polls every 2 s and then sleeps 2 s after `steamwebhelper`
   appears (`:3705`–`:3734`). Worst case that is ~4 s of splash sitting on top of
   a drawn Gaming Mode. Poll at 250 ms and cut the settle to ~0.5 s. The settle
   exists so the handover does not read as a flicker; in a 10 s window, 2 s reads
   as the splash being *stuck*.

4. **`SPLASH_MAX_SECONDS` (`:1113`).** 300 s was sized for the 2m03s update. It
   is a ceiling, not a duration, so it is not wrong — but with the splash now
   running every boot, a wedged `steamwebhelper` detection means 5 minutes of
   splash over a live Gaming Mode. 60 s is ample for a 10 s gap. Keep
   `RuntimeMaxSec=` at `SPLASH_MAX_SECONDS + 30`.

5. **The wording (`render_steam_splash_image`, `:3758`).** *"Don't turn me off.
   Steam is unpacking."* is correct for a first boot and false on every later
   one — Steam is not unpacking, it is starting. Shipping a message that is
   literally untrue on 99% of boots is worse than the black screen. New copy
   needed; the operator owns the wording, as they did the original.
   **⚠️ This is a hard blocker on shipping items 1–4.** Do not ship the every-boot
   splash carrying the first-boot text.

6. **`SPLASH_ATTEMPT_ID` (`:1109`) — bump it.** Its own comment requires this
   when the splash changes in a way that deserves another attempt. Even with the
   marker gone, the id is what attributes a `first-boot.log` line to a build.

**What could regress**, stated so the owner can test for it rather than discover
it:

* **A splash in front of a client that is about to draw** — the exact thing the
  once-ever gate was protecting. Items 2 and 3 are the mitigation; T-E is the
  test.
* **Focus.** `imv -f` is a fullscreen client on gamescope's nested display, and
  Gaming Mode's focus handling is Valve's. If gamescope keeps focus on `imv`
  after Steam maps, Gaming Mode is up and does not respond to the pad — which on
  this device is indistinguishable from a hang and is *worse than the bug*.
  🔴 **This must be tested on hardware before it ships, and it is the one risk
  that can turn a cosmetic defect into an unusable Deck.** The splash exiting
  ~0.5 s after `steamwebhelper` (item 3) shortens the exposure but does not
  remove it.
* **Every boot now depends on `imv` and the PNG.** Both are checked at install
  time (`:3852`, `:3873`) and both degrade to `say ...; exit 0`. Unchanged by
  this spec, but now exercised at every boot instead of once.

**Test where the sibling's suites already are:** the marker logic, the
`GAMESCOPE_WAYLAND_DISPLAY` poll and the loop timings are all in
`render_steam_splash`'s emitted text and are unit-testable by rendering the
script and asserting on it, which is how the rest of that file is tested. Only
focus (bullet 2) and "does it draw at all in 10 s" need the Deck — T-E.

### 6b. Do T-E before writing any of §6a

T-E costs one `rm` and one reboot and answers the question that decides whether
§6a is worth doing: **does `imv` get a frame up inside the gap at all?** If the
splash comes up at second 8 of a 10 s window, or logs
`FAILED: GAMESCOPE_WAYLAND_DISPLAY is not set`, then item 2 is the whole job and
items 1/3/4 are polish. If it draws promptly, §6a is a small, well-bounded
change to an already-tested mechanism.

### 6c. A separate, unrelated 13 s that nobody has looked at

**MEASURED (§5.35):** firmware 5.781 s + loader 7.442 s = **13.2 s before the
kernel starts**. That is a third of the whole boot and it is *not* the operator's
complaint — it is before the logo, and the Limine screen is at least something on
the panel. But 7.4 s in the loader is a lot, and the Omarchy limine config
captured at `iso/upstream/manifests/fresh-4-semantic.json:133` carries
`#timeout: 3` **commented out**, which means Limine's default menu timeout
applies. Worth its own look; explicitly out of scope here, and it must not be
folded into this bug's fix.

---

## 7. What I could not determine

Stated plainly, because a confident guess here would be worth less than the list.

1. **Who owns the gap.** No timestamp from the affected boot was read. Every
   candidate in §3 is standing on structure and on prior sessions' numbers, not
   on a measurement of this defect.
2. **Whether `plymouth-quit`'s 659 ms is a duration or a timestamp** (§1). The
   arithmetic argues for duration and the operator's report agrees, but neither
   is the command that settles it.
3. **How much of the gap is our `nm-online` wait** (H2). One `cat` answers this
   and it was not possible to run it. This is the single largest known unknown
   and it is also the cheapest to close.
4. **Whether the panel is black because nothing draws, or dark because it is
   off.** On OLED these are not visually separable (§4a) and the sysfs/journal
   reads were not possible.
5. **Whether the duration differs cold vs. warm, first-boot vs. later** (T-A).
   The record predicts no difference; that prediction is untested.
6. **Whether the existing splash can draw inside a 10 s window at all** (T-E) —
   and in particular whether it loses the `GAMESCOPE_WAYLAND_DISPLAY` race, which
   it was never under time pressure to win before.
7. **Whether `imv` releases focus cleanly to Steam** (§6a, second regression).
   This is the risk that could make a fix worse than the bug, and it cannot be
   answered off hardware.

**The one thing to do first, and it needs no reboot:**

```
ssh deck@192.168.100.25 'cat ~/.local/state/deck-session/first-boot.log'
```
