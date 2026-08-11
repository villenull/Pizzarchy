# T9 — `shell/plugins/lock/Service.qml`: can it lock this Deck, and what do we do?

**Research and design only. No production code was written and nothing under
`src/` or `test/` was touched.** Measured 2026-08-11 on the dev machine, from
upstream source over `gh api` (no clone), from Hyprland's source at the version
the ISO carries, and from the protocol XML installed on this machine.

Every claim below is tagged. **READ** = I opened the file and it says this.
**INFERRED** = it follows from things I read but nobody has run it.
**UNVERIFIED** = an experiment nobody has done. There are no unlabelled claims.

## Provenance — the refs this was measured against

| Thing | Ref | How |
|---|---|---|
| Upstream head **at this reading** | **`05bb82b`**, 2026-08-11 **15:04:50 UTC**, *"Add checkout bin to sudoers path"* | `gh api repos/basecamp/omarchy/commits/quattro` |
| Head in `T9-delta-classification.md` | `5817feb`, 14:30 UTC | it moved again in ~35 min |
| **Our install baseline (beta 2)** | **`6d7826d`** | `docs/PROGRESS.md` §5.22 |
| Hyprland | **`v0.56.2`** — the version measured inside beta 2 (`docs/findings/T9-iso-comparison.md:231`, `hyprland-0.56.2-1`) | `gh api repos/hyprwm/Hyprland/contents/…?ref=v0.56.2` |
| `ext-session-lock-v1.xml` | `/usr/share/wayland-protocols/staging/ext-session-lock/ext-session-lock-v1.xml`, **`wayland-protocols 1.49-1`** | the dev machine's copy — **the same version the ISO ships** (`wayland-protocols-1.49-1`, same finding line) |

⚠️ Still not a pin. `quattro` moved three times in the four hours these two
findings took. Cite `docs/PROGRESS.md` §1.1's SHA, not "latest".

---

## 0. The short answer

1. **`recoverStrandedLock()` cannot lock an unlocked Deck.** It only fires when
   the compositor is **already** holding an `ext_session_lock_v1`. It does not
   create a lock; it attaches a password prompt to a lock that already exists.
   **(READ — §1.3.)**

2. **But we already have two live paths that create that lock, today, on beta
   2, with nothing from this delta.** `omarchy-sleep-lock.service` locks the
   session on every suspend, and the Omarchy menu's `system.lock` row locks on
   demand. Both are present and enabled at `6d7826d`. **(READ — §1.4.)**
   **The idle-policy neutering was never the whole guarantee. We have been one
   power-button press away from an unanswerable password prompt since install.**

3. So the delta row is real but **mis-scoped**: it is not the hole, it is the
   thing that would make the hole *visible* (a password prompt) instead of
   *fatal* (Hyprland's dead-lock screen, which cannot be authenticated at all).
   **`recoverStrandedLock()` is, on our configuration, strictly an
   improvement.** **(INFERRED from §1.3 + §2.1.)**

4. What the user sees today if it fires: **a `lockdead.png` splash with
   "Running on tty 2" and no password field** (stranded, pre-delta), or after
   the delta lands, **Omarchy's real lock screen with a password box the OSK is
   invisible underneath**. Escape in both cases is a 10-second power-button
   hold. **(READ for the render paths; UNVERIFIED on this hardware.)**

5. **Recommendation (§5): a one-line Hyprland layer rule —
   `above_lock = 2` on namespace `deck-osk` — plus masking
   `omarchy-sleep-lock.service`.** Make the lock answerable *and* stop creating
   it. Both are upstream-supported mechanisms, both fail loudly, neither
   silently rots.

---

## 1. What actually happens, read from the source

### 1.1 The exact path

`shell/plugins/lock/Service.qml` at `quattro` (548 lines; 471 at `6d7826d` —
the delta is +77 lines and nothing else changed in the file):

```qml
function checkStrandedLock() {
  if (strandedLockResolved || strandedLockCheckProc.running) return
  if (locked || lockRequested) { strandedLockResolved = true; return }
  strandedLockCheckProc.running = true          // runs omarchy-hyprland-session-locked
}

Process {
  id: strandedLockCheckProc
  command: ["bash", "-c", "omarchy-hyprland-session-locked"]
  onExited: function(exitCode) {
    if (exitCode === 2) return                  // undetermined: stay unresolved, retry
    root.strandedLockResolved = true
    root.strandedLock = exitCode === 0 && !root.locked && !root.lockRequested
    root.recoverStrandedLock()
  }
}

function recoverStrandedLock() {
  if (!strandedLock || locked || !passwordPamConfigured) return
  strandedLock = false
  logEvent("lock-stranded: recovering")
  beginLock()
}
```

Armed from four places **(READ)**: `Component.onCompleted`, `Connections
target: Quickshell → onScreensChanged`, `onPasswordPamConfiguredChanged` (which
also *resets* `strandedLockResolved`, so it re-asks), and `strandedLockRetryTimer`
— 500 ms, `repeat: true`, `budget: 20`, `running: !strandedLockResolved &&
remaining > 0`. That is a **10-second** budget per arming, re-armed on every
screens change.

`beginLock()` **(READ)** refuses if `!passwordPamConfigured` (logs
`lock-denied: missing-pam`), otherwise sets `lockRequested`, blanks after 5 s,
and `queueSessionLock()` → `sessionLock.locked = true` → `WlSessionLock` takes
the `ext_session_lock_v1`.

### 1.2 The five conditions, and which hold for us

| # | Condition | Source | True on our Deck? |
|---|---|---|---|
| 1 | The lock plugin is loaded and `keepLoaded` | `shell/plugins/lock/manifest.json` — `"keepLoaded": true` **(READ)** | **YES** |
| 2 | `passwordPamConfigured` — i.e. `/etc/pam.d/omarchy-lock-password` exists and is readable by `FileView` | written by `bin/omarchy-apply-lock`, called by `install/config/lockscreen-pam.sh`, which is line 3 of `install/config/all.sh` — **unconditional, every install** **(READ)** | **YES, almost certainly.** ⚠️ Never directly observed on our Deck — `test/hw-probe.sh` has no `/etc/pam.d` row. **UNVERIFIED**, and cheap to close: one `ls -l /etc/pam.d/omarchy-lock-*` |
| 3 | `omarchy-hyprland-session-locked` exists | **ABSENT at `6d7826d`, present at `quattro`** (checked by `gh api …/contents/…?ref=` at both refs) **(READ)** | **NO today; YES after any move to edge or stable** |
| 4 | It exits **0** — some monitor's `solitaryBlockedBy` contains `LOCK` | see §1.3 | **only while a lock is already held** |
| 5 | `!locked && !lockRequested` in this shell instance | fresh Quickshell holds no lock **(READ)** | **YES for any newly started shell** |

Condition 4 is the whole question, and it is the one the classification did not
open.

### 1.3 🔥 The prerequisite nobody wrote down: **a lock must already exist**

`bin/omarchy-hyprland-session-locked` **(READ, 29 lines)** reads
`hyprctl -j monitors` and asks whether any monitor lists `LOCK` in
`solitaryBlockedBy`. Tracing that into Hyprland `v0.56.2`:

- `src/debug/HyprCtl.cpp:149-166` — `getSolitaryBlockedReason()` calls
  `m->isSolitaryBlocked(true)`, i.e. the **full** reason set, and renders it as
  a JSON array of names from `SOLITARY_REASONS_JSON` (`…, "LOCK", "WORKSPACE",
  "WINDOWED", …`). With no blockers at all it returns the literal `null`.
  **(READ.)**
- `src/output/Monitor.cpp:1800-1838` — `isSolitaryBlocked()`. The only way
  `SC_LOCK` is set is:
  ```cpp
  if (g_pSessionLockManager->isSessionLocked()) { reasons |= SC_LOCK; … }
  ```
  **(READ.)** There is no other producer of that bit in the file.

**So `LOCK` in `solitaryBlockedBy` means exactly one thing: an
`ext_session_lock_v1` is currently held by the compositor.** The sensor is not a
heuristic that could misfire on a Deck-shaped configuration; it is a direct read
of the lock manager. **(READ.)**

Therefore `recoverStrandedLock()` **never locks an unlocked session.** It runs
only when the session is *already* locked and the client that locked it is gone.

#### A correction to `T9-delta-classification.md` §2

That table says of the sensor: *"On a single-display Deck there is no second
monitor to disambiguate, so exit 2 (undetermined) is the common early answer."*
**The monitor count is not what disambiguates.** Reading
`isSolitaryBlocked(bool full)` **(READ)**:

```cpp
const auto PWORKSPACE = m_activeWorkspace;
if (!PWORKSPACE) { reasons |= SC_WORKSPACE; return reasons; }   // returns even when full==true
```

That first branch returns **unconditionally**, so a monitor with no active
workspace yields exactly `["WORKSPACE"]` — which the helper's `readable`
predicate rejects → exit 2. Every later check accumulates because `full` is
`true`. So exit 2 is a **startup-transient** state on *any* machine, one monitor
or ten, and it stops as soon as the monitor has a workspace. The retry budget
(10 s) exists for exactly that window. The conclusion in the classification
("the retry timer keeps asking") is right; the reason given for it is not.

### 1.4 🔥 So where does the pre-existing lock come from? Three producers — **two are live on our Deck today**

Every route to `beginLock()`, found by reading the whole `quattro` tree
(`gh api git/trees/quattro?recursive=1`, 1476 blobs) for lock callers:

| # | Producer | Mechanism | At `6d7826d` (our Deck)? | Covered by our idle neutering? |
|---|---|---|---|---|
| A | **Idle timeout** | `shell/plugins/services/idle/Service.qml` → `lockSystem()` → `omarchy-system-lock` → `omarchy-shell lock lock` **(READ)** | yes | ✅ **YES** — `idle.lock = 86400` (`src/deck-session.sh:196-197`) |
| B | 🔥 **Suspend** | `default/systemd/user/omarchy-sleep-lock.service` → `omarchy-system-sleep-monitor` → `systemd-inhibit --what=sleep --mode=delay` around a `dbus-monitor` on logind's `PrepareForSleep` → `omarchy-system-sleep-lock` → `omarchy-shell lock lock`, polling until `.secure` **(READ, all four files)** | **YES — and enabled.** `install/user/first-run/enable-user-units.sh` does `systemctl --user enable --now … omarchy-sleep-lock.service …`, **byte-identical at `6d7826d` and `quattro`** **(READ both refs)** | ❌ **NO** |
| C | 🔥 **The user asks** | `default/omarchy/omarchy-menu.jsonc:32` — `"system.lock": {"icon":"","label":"Lock","action":"omarchy-system-lock"}`. Also `SUPER+CTRL+L` and `omarchy-system-lid-close` **(READ)** | yes | ❌ **NO** |
| D | *(post-delta)* | `recoverStrandedLock()` — requires A, B or C to have fired first | no | n/a, and see §0.3 |

**This is the finding that matters.** `src/deck-session.sh:180-195`'s comment
says the neutering exists *"so that a keyboard-less handheld can never be shown
an unanswerable password prompt."* Read against B and C, that comment has been
wrong since it was written. Producer B needs no user intent at all: **press the
power button on a Steam Deck and logind suspends; on resume the session is
locked.** `src/` contains **zero** references to `omarchy-system-lock`,
`sleep-lock`, `pam.d`, `suspend` or `session-lock` — grepped, no hits.

Of the two, **C is reachable but deliberate** (the user chose "Lock" from a
menu, and our own Desktop Mode row sits in the same menu — `src/deck-session.sh:2043-2047`).
**B is not deliberate and is the one to close.**

⚠️ Whether producer B has *already* locked this Deck in the field is
**UNVERIFIED**. `docs/PROGRESS.md` §5.23 records a power cycle on 2026-08-11 and
three observed behaviours; a lock screen is not among them. A power *cycle* is
not a suspend, so that report neither confirms nor refutes it. `journalctl
--user -t omarchy-shell -g "lock-"` on the Deck answers it in one command and
needs no writes.

### 1.5 The other new lock caller in the delta

`bin/omarchy-restart-shell` at `quattro` **(READ)** now: asks
`omarchy-hyprland-session-locked`; if the session is locked but no live locker
reports `.secure`/`.requested`, it sets `relock=1`, restarts the shell, and then
**polls `omarchy-shell lock lock` for 30 s until `.secure`**. That is a second,
*more determined* re-lock path than `recoverStrandedLock()`, and it is driven by
`bin/omarchy-launch-shell`'s new supervisor (relaunch up to 5× in 60 s) only
indirectly — the supervisor calls `omarchy-launch-shell`, not `restart-shell`.
Both funnel into the same `beginLock()`, and both still require a pre-existing
lock. **(READ.)**

`default/hypr/looknfeel.lua` has, in `misc`:

```lua
-- Let a fresh shell re-acquire the session lock after the lock client
-- died, so omarchy-restart-shell can recover the LOCK failsafe.
allow_session_lock_restore = true,
```

**Blob sha `345f9105a9c3744f705cefc31c85b3ad63af2eb1` — identical at `6d7826d`
and `quattro` (READ both).** So the compositor-side permission for a second
client to take over a stranded lock is **already on our Deck**. Hyprland
`src/managers/SessionLockManager.cpp:52-59` **(READ)** confirms it is the gate:
without it, `pLock->sendDenied()`.

---

## 2. What the lock looks like on this device

### 2.1 Before recovery — the stranded state (what we would get *without* the delta)

Hyprland `src/render/Renderer.cpp:1664-1699` **(READ)**:

```cpp
const bool RENDERLOCKMISSING = (PSLS.expired() || …clientDenied()) && …shallConsiderLockMissing();
if (RENDERLOCKMISSING) renderSessionLockMissing(pMonitor);
else if (PSLS) { renderSessionLockSurface(…); /* then abovelock layers */ }
```

`renderSessionLockMissing()` draws `lockdead.png` (or `lockdead2.png` if any
lock surface is still present) plus, when no surface is present, a rendered text
texture: `"Running on tty {N}"` (`Renderer.cpp:1639-1662`). **(READ.)**

**There is no password field in that state.** It is unanswerable by
construction, on any hardware, with any keyboard. The *only* recorded escapes
are a VT switch (`Ctrl+Alt+F<n>` — **our mapper emits no modifiers at all**, so
unreachable from the pad), SSH, or a power cycle.

### 2.2 After recovery — Omarchy's lock screen

`shell/plugins/lock/LockView.qml` **(READ, 218 lines)**: a QML `TextInput` with
`echoMode: TextInput.Password`, `activeFocusOnPress`, force-focused via
`forcePasswordFocus()`, placeholder `"Enter Password"`, `onAccepted →
submitPassword`. No virtual keyboard, no fingerprint on this hardware
(`fingerprintCheckProc` shells out to `fprintd-list`; the Deck has no reader).

So the recovery converts "a dead-lock splash nobody can answer" into "a password
box". **That is why the classification's BREAKS US verdict is, on our
configuration, backwards** — the delta does not add a lock, it adds the only UI
that could ever dismiss one. **(INFERRED, from §1.3 + §2.1 + §2.2.)**

### 2.3 Does a uinput keystroke reach the lock surface? — **almost certainly yes**

Three separate reads point the same way:

1. **Protocol.** `ext-session-lock-v1.xml` **(READ)**: while locked the
   compositor *"must stop rendering and providing input to normal clients"* —
   the lock surface is not a normal client, it is the input target.
2. **Hyprland.** `src/managers/input/InputManager.cpp:365-371` **(READ)**:
   ```cpp
   if (!foundSurface && g_pSessionLockManager->isSessionLocked()) {
       // set keyboard focus on session lock surface regardless of layers
       const auto PSESSIONLOCKSURFACE = …getSessionLockSurfaceForMonitor(PMONITOR->m_id);
       Desktop::focusState()->rawSurfaceFocus(foundLockSurface);
   ```
   **"regardless of layers"** — no layer surface can steal keyboard focus during
   a lock. Ours could not anyway (`KeyboardMode.NONE`,
   `src/deck_osk_wayland.py:274`).
3. **The delivery path.** `src/deck-input-mapper.py` creates a `UInput` device
   (`EMITTED_KEYS`, line 311). That is a **kernel evdev device**; libinput
   enumerates it and hands it to the compositor as a keyboard like any other.
   Nothing in the compositor can tell it apart. **(READ; and the same
   proposition is already proven end-to-end at the VT layer by
   `test/vm/vm-gamepad-spike-test.sh`.)**

**UNVERIFIED**: nobody has typed into an `ext-session-lock` surface from this
mapper. This is the single most valuable thing the provocation in §4 buys.

### 2.4 Can the user *see* what they type? — **no, today**

`renderLayer()` (`Renderer.cpp:935-945`) **(READ)**:

```cpp
if ((pLayer->m_ruleApplicator->aboveLock().valueOrDefault() && !lockscreen && …isSessionLocked()) ||
    (lockscreen && !pLayer->m_ruleApplicator->aboveLock().valueOrDefault()))
    return;
```

A layer surface **without** `above_lock` is skipped in the lockscreen pass; a
layer surface **with** it is skipped in the normal pass. Our OSK sets no such
rule, so while locked it is **mapped, alive, receiving state on stdin, and not
drawn**. Confirmed as the classification predicted — but the classification
stopped there, and there is a lever right next to it:

**`above_lock` is a first-class Hyprland layer rule, an integer 0..2.**

- `src/desktop/rule/layerRule/LayerRuleEffectContainer.cpp:22` — the rule's
  name string is **`above_lock`** **(READ)**.
- `src/config/lua/bindings/LuaBindingsConfigRules.cpp:191` — in the **Lua**
  config (which is what Omarchy 4.0 uses):
  `{"above_lock", … new CLuaConfigInt(0, 0, 2), … LAYER_RULE_EFFECT_ABOVE_LOCK}`
  **(READ)**.
- `src/desktop/state/ViewHitTester.cpp:346-350` **(READ)**: pointer hit-testing
  during a lock skips any layer whose `aboveLock() != 2`. So **2 = rendered and
  interactive, 1 = rendered only, 0 = not rendered.**
- The idiom, from upstream's own config (`default/hypr/apps/omarchy-shell.lua:5`,
  **READ**): `hl.layer_rule({ match = { namespace = "omarchy-bar" }, no_anim = true })`.

So the rule we would want is:

```lua
hl.layer_rule({ match = { namespace = "deck-osk" }, above_lock = 2 })
```

⚠️ Two things about that, both READ, both important:

- **It only helps once a *live* lock surface exists.** The `abovelock` layers
  are rendered inside `else if (PSLS)` (`Renderer.cpp:1684-1698`) — i.e. **not**
  during `renderSessionLockMissing()`. An `above_lock` OSK is invisible during
  the stranded dead-lock splash and visible during a real lock screen. Which is
  precisely the split in §2.1/§2.2: **the delta is what makes the mitigation
  work at all.**
- `above_lock = 2` grants *pointer* hit-testing, which our OSK will never take
  anyway: `ViewHitTester.cpp:355-356` skips a surface with an **empty input
  region**, and we set exactly that (`src/deck_osk_wayland.py:298`). So `2`
  costs us nothing over `1` and leaves the door open if the OSK ever grows a
  touch path. Keyboard focus stays on the lock surface regardless (§2.3).

### 2.5 What the user actually experiences today, end to end

**(INFERRED from the reads above; UNVERIFIED on hardware.)** Deck in Desktop
Mode, user taps the power button to "turn it off":

1. logind emits `PrepareForSleep true`; `omarchy-system-sleep-lock` locks and
   waits for `.secure`; the machine suspends. **(READ.)**
2. Resume: an `ext-session-lock` surface with a password box. Our OSK toggle
   (STEAM+X — `OSK_CHORD_HOLD = BTN_MODE`, `OSK_CHORD_PRESS = BTN_NORTH`,
   `src/deck-input-mapper.py:227-228`) still *works* — the mapper is a
   `/etc/systemd/user/deck-input-mapper.service` unit (`src/deck-session.sh:232`)
   reading evdev, entirely independent of the compositor.
3. The OSK draws nothing the user can see. Keystrokes land in the password
   field, echoed as dots. Blind typing with a 4-way cursor over an unseen
   layout.
4. And **STEAM+X requires `lizard_mode=N`**, which `docs/PROGRESS.md` §5.21 and
   §5.23 record as **not persisting across a boot** — so on a fresh boot the
   chord cannot even be detected, and the only keys the pad produces are
   `ENTER ESC SPACE TAB PAGEUP PAGEDOWN` + arrows (`BUTTON_MAP`/`HAT_MAP`,
   `src/deck-input-mapper.py:141-171`). **No letters. The prompt is
   unanswerable.**
5. Escape: hold power ~10 s. The lock does not survive the compositor, so the
   next boot comes up unlocked. **(INFERRED — the lock lives in
   `CSessionLockManager`, process state.)**

---

## 3. Candidate mitigations

| | Mitigation | What it costs | What breaks | Rots silently? |
|---|---|---|---|---|
| **A** | **Do nothing — "it cannot fire"** | nothing | **Wrong premise.** §1.4: producers B and C fire *without* the delta. Doing nothing leaves the *worse* variant (§2.1, no password box at all) | ☠️ **Yes — it already has.** The `src/deck-session.sh:180-195` comment has asserted a guarantee it never had |
| **B** | **Make PAM lock unconfigured** — remove/rename `/etc/pam.d/omarchy-lock-password` | one file | `beginLock()` returns false with `lock-denied: missing-pam` **(READ)**, so **no lock UI ever appears** — *but the compositor lock from producers B/C still happens*, and now nothing can ever dismiss it. Also breaks `omarchy-system-sleep-lock`, which calls `report_unsecured` and fires a **critical notification** on every suspend **(READ)** | ☠️ Yes. `install/config/lockscreen-pam.sh` runs on every install *and* `omarchy-upgrade-to-quattro`; the file comes back and nothing tells us |
| **C** | **Keep the sensor from reporting** — shadow/mask `omarchy-hyprland-session-locked` | one file in `/usr/local/bin` ahead of `/usr/bin` | Disables *recovery* while leaving the *lock*. Strictly makes §2.1 permanent. Also breaks `omarchy-restart-shell`'s recovery | ☠️ Yes — a PATH shadow of a `/usr/bin` script is invisible to every check we have, and a rename upstream turns it into a silent no-op |
| **D** | **A much larger `idle.lock`** | none — we already do it | **Nothing.** Producers B, C and D never read `idle.lock`. It is orthogonal, not insufficient-by-degree. Keep it; it closes producer A | No, but it also does nothing new |
| **E** | **Own the lock surface ourselves** — our own `ext-session-lock` client with a controller-native unlock | Weeks. A new Wayland client, a PAM conversation, a security-critical surface we would have to get right, and a fight with Quickshell over who locks | Everything about it is ours to maintain forever, on a security boundary, against a compositor and a shell that both move weekly | Very — a lock screen that fails *open* is the worst possible silent rot |
| **F** | **Close producer B: `systemctl --user mask omarchy-sleep-lock.service`** | one masked unit | Suspends no longer lock. **That is a deliberate security decision** and must be written down: a suspended Deck resumes straight into the desktop. Matches stock SteamOS Gaming Mode behaviour, which also does not demand a password on resume | 🟡 Some — `enable-user-units.sh` runs `enable --now` at *first run only* **(READ)**, so it will not re-enable on update; but a mask is invisible unless something asserts it. **Assertable**: `systemctl --user is-enabled` in a stage + a unit test |
| **G** | **Make the lock answerable: `above_lock = 2` on `deck-osk`** | one line of Lua in a file we already own (`~/.config/hypr/`, alongside `monitors.lua` — `src/deck-session.sh:2059` records that seam) | Nothing. The rule is inert when nothing is locked. Costs one extra render pass over a layer that is already mapped | 🟢 **Low, and detectably.** `hyprctl layers` shows the rule's effect; `hyprctl configerrors` shouts if the key is renamed (Hyprland validates the effect name — `LayerRuleEffectContainer.cpp` **READ**). ⚠️ It is a **Hyprland** coupling, not an Omarchy one, so it moves on Hyprland's schedule |

Two more, for completeness, both rejected:

- **Remove the `system.lock` menu row** (producer C). It is a user-initiated
  action; a Deck user who deliberately picks "Lock" should get a lock. With G in
  place it is answerable. Removing it also means maintaining a diff against
  `omarchy-menu.jsonc`, which the extension seam is explicitly designed to avoid.
- **`misc:allow_session_lock_restore = false`.** Reverting upstream's setting
  would *prevent* recovery and pin us to §2.1 forever. Exactly backwards.

---

## 4. How to PROVOKE it — a runnable procedure

The classification is right that this must be provoked, not read. What follows
is three tiers, cheapest first, per `CLAUDE.md`'s testing rule. **⚠️ Tiers 0 and
1 must not be run against the operator's own live desktop session — see the
warning in 4.1.**

### 4.0 What the existing harnesses can and cannot do — stated honestly

- `test/images/vm-neptune-image.sh` **(READ, header)** says it plainly: it is
  *"deliberately NOT a claim to be an Omarchy Quattro system."* It is Arch +
  limine + a Neptune kernel + a vfat ESP + btrfs/snapper. **No Hyprland, no
  Quickshell, no Omarchy, no PAM lock config, no `hyprctl`.** Every VM suite in
  `test/vm/` builds on it. **None of them can host this experiment as-is.**
- `test/vm/vm-install-test.sh` **(READ, header)** *does* produce a real installed
  Omarchy disk from a real ISO — but its own header records that it has **never
  been run end to end**, and that completion detection is a known gap. Making it
  produce a *booted graphical* Omarchy (not just an installed disk to inspect
  offline) is additional work nobody has done.
- **Upstream has not provoked this either.** `test/shell.d/lock-stranded-recovery-test.sh`
  is **13 regex assertions over the text of `Service.qml`** **(READ)** and
  `test/shell.d/hyprland-session-locked-test.sh` runs the helper against a
  **fake `hyprctl`** printing canned JSON **(READ)**. Nobody, anywhere, has run
  a real client into a real failsafe.

### 4.1 Tier 0 — nested Hyprland, no VM (minutes)

**This is the tier that answers the load-bearing questions**, and the dev
machine already has what it needs: `hyprland 0.56.0-2` is installed (the Deck
runs `0.56.2`; §6 records the gap).

⚠️ **Nested only. Never on the operator's own session.** Hyprland's backend
selection (`src/Compositor.cpp:308-320`, **READ**) requests
`AQ_BACKEND_HEADLESS` **mandatory**, `AQ_BACKEND_DRM` *if available*, and
`AQ_BACKEND_WAYLAND` as **fallback** — so launching Hyprland from inside a
Wayland session gives a nested compositor in a window. A session lock is per
`CSessionLockManager` instance **(READ)**, so locking the nested instance cannot
touch the outer one; closing the nested window ends it. *(`HYPRLAND_HEADLESS_ONLY=1`
is set by upstream's own `hyprtester/src/main.cpp:70` **(READ)**, but at
`v0.56.2` `Compositor.cpp:331` still carries a bare `// TODO: headless only` —
do not rely on that env var.)*

```
1. Nested compositor, its own config:
     Hyprland -c /tmp/lockprobe.lua          # minimal: misc.allow_session_lock_restore = true
   Note its HYPRLAND_INSTANCE_SIGNATURE; every hyprctl below uses -i / that sig.

2. Baseline the sensor:
     hyprctl -j monitors | jq '.[].solitaryBlockedBy'
     bash bin/omarchy-hyprland-session-locked; echo $?     # expect 1 (unlocked)
   ASSERT: exit 1, and no "LOCK" in the array.

3. Lock it with ANY ext-session-lock client (hyprlock/swaylock/a 60-line
   wl_client). Quickshell is NOT required for steps 3-6.
     hyprctl -j monitors | jq '.[].solitaryBlockedBy'
     bash bin/omarchy-hyprland-session-locked; echo $?     # expect 0
   ASSERT: "LOCK" present, exit 0.   <-- proves the sensor, on real Hyprland

4. STRAND IT — the actual provocation:
     kill -9 <lock client pid>
   ASSERT: the nested output shows lockdead.png + "Running on tty N" (§2.1),
           and `omarchy-hyprland-session-locked` STILL exits 0.
           <-- proves the failsafe outlives its client, i.e. condition 4

5. RECOVER: start a second lock client against the same instance.
   ASSERT: it is NOT denied (this is what allow_session_lock_restore buys;
           SessionLockManager.cpp:52-59). A password box comes back.
           <-- proves recoverStrandedLock()'s premise end to end

6. THE TWO QUESTIONS THAT DECIDE THE MITIGATION:
   6a. INPUT. Run src/deck-input-mapper.py against a scripted virtual pad
       (the pattern test/vm/vm-gamepad-spike-test.sh already uses), inside the
       nested session, and drive characters at the locked surface.
       ASSERT: the password field's dot count advances.
   6b. VISIBILITY. Run deck_osk_wayland.py --demo into the nested session,
       with and without:
         hl.layer_rule({ match = { namespace = "deck-osk" }, above_lock = 2 })
       ASSERT: hidden without the rule; drawn over the lock surface with it;
               `hyprctl layers` lists deck-osk in both cases.
       ASSERT (the sharp edge from §2.4): with the rule, the OSK is STILL
               hidden in the step-4 stranded state and appears only in step 5.
```

Steps 3-6 need **no Omarchy and no Quickshell**. They test Hyprland's half,
which is the half both mitigations depend on.

### 4.2 Tier 1 — QEMU, the full Omarchy path (hours, one-time build)

Needed only to test *Omarchy's* half: that `Service.qml` actually calls
`beginLock()` on our config, and that `omarchy-launch-shell`'s supervisor
multiplies it.

What it honestly requires, none of which exists today:

1. A real installed Omarchy disk — `test/vm/vm-install-test.sh` against a built
   4.0 ISO, with its known completion-detection gap closed first.
2. That guest booted **graphically** with virtio-gpu/virgl so Hyprland gets a
   DRM backend and a real render path (the neptune substrate is booted
   headless-serial by every current suite).
3. Autologin to the Deck's Desktop Mode, `src/deck-session.sh` stages applied,
   and a scripted way in — the existing suites drive the guest over serial +
   `tmux`, which is a VT path, not a Wayland one.
4. Then: `omarchy-shell lock lock` → `pkill -9 quickshell` → assert
   `omarchy-hyprland-session-locked` exits 0 → assert
   `journalctl --user -t omarchy-shell -g "lock-stranded: recovering"` appears
   → assert a password box renders.

**Do not build this to answer §2.3 and §2.4** — tier 0 answers those in minutes
against the same compositor version. Build it only if we decide we must observe
Quickshell's own decision, and note that step 4's log line is a *deliberate*
`logEvent("lock-stranded: recovering")` **(READ)**, so the assertion is a
one-line journal grep, not screen scraping.

### 4.3 Tier 2 — the Deck

Only two things genuinely need the hardware, and **both are reads, no writes**,
so they batch into the §5.23/P2.9f hands-on session:

```
ls -l /etc/pam.d/omarchy-lock-*                       # closes condition 2 (§1.2)
systemctl --user is-enabled omarchy-sleep-lock.service # closes producer B (§1.4)
journalctl --user -t omarchy-shell -g 'lock-' --no-pager | tail -40
                                                       # has it ALREADY locked?
```

Then, once, deliberately, with the operator present and SSH open as the escape
hatch: **suspend the Deck and resume it.** That is the whole experiment for
producer B, it takes 30 seconds, and it is the difference between §1.4 being a
source-read prediction and being a fact.

---

## 5. Recommendation — one option

> **Do G and F together, keep D, and treat the delta as a fix rather than a
> regression. Specifically:**
>
> 1. **`hl.layer_rule({ match = { namespace = "deck-osk" }, above_lock = 2 })`**,
>    written into the user's `~/.config/hypr/` alongside the rotation
>    (`src/deck-session.sh`'s `monitors.lua` seam, and baked into the image by
>    T5 the same way — `docs/PROGRESS.md` §5.11, §5.20).
> 2. **`systemctl --user mask omarchy-sleep-lock.service`** as a
>    `deck-session.sh` stage, asserted on re-run like every other stage, with
>    the security trade-off stated in the code comment *and* in
>    `docs/RECOVERY.md`: **a suspended Deck resumes unlocked, deliberately,
>    because it has no keyboard.**
> 3. **Keep `idle.lock = 86400`** and **fix the comment at
>    `src/deck-session.sh:180-195`**, which currently claims a guarantee it never
>    provided. Producers B and C were always outside it.
> 4. **Do not block moving to edge/stable on the lock row.** Reclassify it in
>    `T9-delta-classification.md` from **BREAKS US** to **RE-VERIFY (improves
>    us)**, with §1.3 as the reason.

**Why this one and not the others.**

The question the classification asked was *"prevent the lock, or make it
answerable?"* The honest answer from the source is **both, because they close
different producers and neither closes all of them.** F removes the only
*undeliberate* producer. G makes the two remaining producers — a user who chose
"Lock", and a recovery that only ever runs when the device is already locked —
survivable instead of terminal. Nothing else on the list has that shape:

- **A** is the status quo and the status quo is already broken (§1.4).
- **B and C** both leave the compositor lock intact and delete the only thing
  that could dismiss it. They convert a bad state into an unrecoverable one, and
  both are the exact class of change this project keeps getting burned by: a
  file deleted or shadowed under `/usr`, reinstated by an upstream script, with
  nothing asserting it.
- **E** is weeks of work on a security boundary to duplicate something upstream
  already ships and now actively repairs.
- **D** alone is what we have, and §1.4 is the proof it is not enough.

G's residual risk is that `above_lock` is a **Hyprland** name on Hyprland's
release schedule, not Omarchy's — and this delta already showed us upstream
renaming things under us (`omarchy-setup-*` → `omarchy-apply-*`). The mitigation
for that is the one this repo already uses for `UPSTREAM_GREETER_SHA256`
(`src/deck-session.sh:334`): **assert the rule took, don't assume it.**
`hyprctl configerrors` after applying it is a loud, cheap check, and one unit
test asserting the exact rule string is in the file we write closes the rest.

**Sequencing:** run §4.3's three read-only commands in the next hands-on pass
before writing any of this. If `/etc/pam.d/omarchy-lock-password` turns out to
be absent, condition 2 fails and the *recovery* half changes character — but F
and G stand regardless, because producers B and C do not depend on it for the
compositor lock, only for the UI.

---

## 6. What is UNVERIFIED — the honest list

Nothing in §1 or §2 was run. In descending order of what it would buy:

1. **Has this Deck ever actually locked?** (`journalctl --user -t omarchy-shell
   -g 'lock-'`). One command, no writes.
2. **Does `/etc/pam.d/omarchy-lock-password` exist on our Deck?** Inferred from
   `install/config/all.sh:3` being unconditional. Never observed.
3. **Does a mapper keystroke reach an `ext-session-lock` surface?** Three
   independent reads say yes (§2.3). No one has typed one.
4. **Does `above_lock = 2` actually draw `deck-osk` over the lock?** Read out of
   `Renderer.cpp` and `ViewHitTester.cpp`. Never rendered.
5. **Does `above_lock` parse in Omarchy 4.0's Lua config on the Deck?** The
   binding exists at Hyprland `v0.56.2` (`LuaBindingsConfigRules.cpp:191`,
   READ). Not tried.
6. **Version gap.** All Hyprland reads are at **`v0.56.2`** (what beta 2 ships).
   The dev machine has **`0.56.0-2`**. Patch-level differences in
   `Renderer.cpp` / `InputManager.cpp` between them are **unchecked** — a tier-0
   run on the dev machine proves 0.56.0, not 0.56.2. Cheap to close: diff the
   three files across the two tags before trusting a green tier-0 result.
7. **Whether `omarchy-sleep-lock.service` is enabled on *this* Deck**, as
   opposed to being enabled by a first-run script we read. §4.3.

## 7. Method — reproduce

```bash
gh api repos/basecamp/omarchy/commits/quattro -q '.sha'
gh api "repos/basecamp/omarchy/git/trees/quattro?recursive=1" -q '.tree[]|select(.type=="blob").path' > tree.txt
grep -i lock tree.txt                      # 1476 blobs; every lock producer in §1.4 came from here

# any file at either ref (contents API returns base64; -q .sha compares blobs)
for ref in 6d7826d quattro; do
  gh api "repos/basecamp/omarchy/contents/default/hypr/looknfeel.lua?ref=$ref" -q .sha
done                                        # -> identical: 345f9105a9c3744f705cefc31c85b3ad63af2eb1

# presence/absence at a ref, which is how condition 3 was settled
gh api "repos/basecamp/omarchy/contents/bin/omarchy-hyprland-session-locked?ref=6d7826d" -q .sha  # 404
gh api "repos/basecamp/omarchy/contents/bin/omarchy-hyprland-session-locked?ref=quattro"  -q .sha  # exists

# Hyprland at the version the ISO carries. NOTE: `-H Accept: …raw` 404s on this
# repo; decode the base64 from the JSON instead.
python3 -c "import json,base64,subprocess,sys;p=sys.argv[1];d=json.loads(subprocess.run(['gh','api',f'repos/hyprwm/Hyprland/contents/{p}?ref=v0.56.2'],capture_output=True,text=True).stdout);open('out','wb').write(base64.b64decode(d['content']))" src/render/Renderer.cpp

# the protocol, from this machine (wayland-protocols 1.49-1 == the ISO's)
less /usr/share/wayland-protocols/staging/ext-session-lock/ext-session-lock-v1.xml
```

Files read in full: `shell/plugins/lock/{Service.qml,LockView.qml,manifest.json}`
(both refs for `Service.qml`), `shell/plugins/services/idle/Service.qml`,
`bin/omarchy-{hyprland-session-locked,launch-shell,restart-shell,apply-lock,system-lock,system-sleep-lock,system-sleep-monitor,system-lid-close}`,
`install/config/{all.sh,lockscreen-pam.sh}`, `install/user/first-run/enable-user-units.sh`
(both refs), `default/systemd/user/omarchy-sleep-lock.service`,
`default/hypr/{looknfeel.lua,bindings/utilities.lua,apps/omarchy-shell.lua}`,
`default/omarchy/omarchy-menu.jsonc`, `test/shell.d/{lock-stranded-recovery,hyprland-session-locked,base}-test.sh`;
Hyprland `src/{render/Renderer.cpp,output/Monitor.cpp,output/Monitor.hpp,debug/HyprCtl.cpp,Compositor.cpp,managers/SessionLockManager.cpp,managers/input/InputManager.cpp,desktop/state/ViewHitTester.cpp,desktop/rule/layerRule/*}`;
ours: `src/deck-session.sh`, `src/deck-input-mapper.py`, `src/deck_osk_wayland.py`,
`src/deck_osk_focus.py`, `test/vm/*`, `test/images/vm-neptune-image.sh`.

⚠️ Line numbers cited into `src/deck-input-mapper.py` were read **2026-08-11
~09:20** while another agent was editing that file; symbol names
(`BUTTON_MAP`, `HAT_MAP`, `EMITTED_KEYS`, `OSK_CHORD_HOLD`) are the durable
reference. `T9-delta-classification.md`'s citation of `:133-159` had already
gone stale by this reading (`BUTTON_MAP` is at `:141`).
