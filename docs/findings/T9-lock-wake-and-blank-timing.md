# T9 — the lock screen's wake/blank mechanism: why QAM wakes the panel, and where the 5s timer lives

**Research and one proposed (unapplied) patch per requirement. No production
code was written; nothing under `src/` or `test/` was touched.** Answers
`docs/PROGRESS.md` §5.24a rows 1 and 2, using the method §T4-screen-spec.md
used: `gh api` against pinned SHAs, no clone. **No hardware was touched or
tested against** — the operator asked for a proposed, evidenced change; every
claim below is tagged **(READ)** (a file was opened and it says this),
**(INFERRED)** (follows from what was read but nobody ran it), or
**(VERIFIED)** (an actual command was run this session — `luac`, a Python
diff, `gh api`).

## Provenance

| Thing | Ref | How |
|---|---|---|
| `basecamp/omarchy` pin | **`6d7826d`** | `docs/PROGRESS.md` §5.22, confirmed our install baseline |
| Hyprland | **`v0.56.2`** | `docs/findings/T9-iso-comparison.md:231`, matches `T9-lock-service-mitigation.md`'s provenance table |
| Aquamarine (Hyprland's input backend) | `main` at time of reading (2026-08-11) | No pin recorded anywhere in this repo for Aquamarine specifically; the capability-dispatch logic read here (§2) has been structurally the same across Aquamarine's 0.3–0.9 tag range in my experience reading it, but that is not itself verified against 0.56.2's exact vendored copy. Flagged as the one weak link in the chain — see §4 |
| `src/deck-input-mapper.py`, `src/deck-session.sh` | this repo, current worktree | `Read` |

---

## 0. The short answer

1. **QAM's own button press emits nothing on the input layer at all** — no
   key, no motion, nothing a compositor could ever treat as "activity."
   **(READ,** §1**)** The operator's own hypothesis on record — "QAM wakes it
   via the shell reacting rather than the input path" — is **correct**, and
   the corollary hypothesis on the same line — "the mapper grabs the pad, so
   the trackpad's raw events never reach the compositor's idle notifier" — is
   **wrong on two independent counts** (§2): the mapper does not run with
   `--grab` in production, and it would not matter if it did, because the raw
   pad was never going to reach Hyprland's idle/DPMS logic either way.

2. **The panel is not blanked by Hyprland's idle/DPMS timeout, or by
   `shell.json`'s 150s/86400s values, at all.** It is blanked by a **5-second,
   hardcoded `Timer` inside Omarchy's own lock-screen QML**,
   `shell/plugins/lock/Service.qml`'s `idleBlankTimer` (`interval: 5000`),
   which runs `omarchy-brightness-display off` → `hyprctl dispatch
   'hl.dsp.dpms({ action = "disable" })'` five seconds after the lock screen
   arms it. **(READ,** §3**)** This is the file and the exact line requirement
   #2 needs changed.

3. **What actually turns the panel back on, mechanically, is `hyprctl dispatch
   'hl.dsp.dpms({ action = "enable" })'`**, run by
   `omarchy-brightness-display on` from `omarchy-system-wake`. Two independent
   callers exist:
   - **The lock screen's own QML input detector** (`LockView.qml`'s
     `MouseArea.onPositionChanged`/`onClicked` and `Keys.onPressed` on the
     password field) → `wakeRequested()` → `Service.qml`'s `runWake()`. This
     only fires for real Wayland pointer-motion/click and keyboard-key events
     that reach the lock's own client surface.
   - **Hyprland's own generic auto-wake**, gated by
     `misc:key_press_enables_dpms` / `misc:mouse_move_enables_dpms` (both
     `true` in upstream's `default/hypr/input.lua`, confirmed **(READ)**),
     which re-enables DPMS from *any* keyboard-key or pointer-motion event
     Hyprland itself processes, independent of which client has focus.
     **(READ,** Hyprland `PointerManager.cpp`/`InputManager.cpp` at v0.56.2,
     §3**)**

4. **Neither of those two paths is reached by the QAM press itself** — QAM's
   action (`omarchy-menu toggle` → an IPC call to the **`omarchy.menu`**
   plugin) does not touch the **`lock`** plugin's IPC handler, and an
   exhaustive source-string search across `basecamp/omarchy@6d7826d` for
   `dpms`, `omarchy-system-wake`, and `brightness-display` turns up **zero**
   hits in `omarchy-menu`, `omarchy-shell`, `shell.qml`'s dispatcher, or
   `Menu.qml`. **(READ,** §1**)** So the wake QAM produces is not explained by
   any *deliberate* code path in Omarchy's menu stack. The best-supported
   remaining explanation is Hyprland's own generic `mouse_move_enables_dpms`
   firing as a side effect of Hyprland moving/warping the pointer when a new
   layer-shell popup takes focus — **this specific link is INFERRED, not
   confirmed by reading the exact Hyprland code path that would do it**, and
   is flagged honestly as such in §4 rather than guessed past.

5. **Both requirements have a fix that does not touch the input path or the
   mapper, and both compose with the already-recorded `above_lock` fix.**
   §5 gives the exact diffs and where each lands for T5.

---

## 1. QAM: read from `src/deck-input-mapper.py`, confirms zero input-layer events

`translate()`'s handling of the QAM button:

```python
# QAM opens Omarchy's own menu. INERT while QAM_BUTTON is unset,
# which is its shipped state -- see the constant. No chord to
# disambiguate here, so it fires on the press.
if QAM_BUTTON is not None and code == QAM_BUTTON:
    if value == 1:
        self.pending_actions.append("menu-root")
    return []
```
(`src/deck-input-mapper.py:566-569`) — **returns `[]`**. Nothing is ever
written to the mapper's own `uinput` device for this button. The only thing
that happens is `pending_actions` gets `"menu-root"` appended, which the main
loop later hands to `spawn_detached`:

```python
argv = MENU_ACTIONS.get(action)
...
spawn_detached(argv, f"run `{' '.join(argv)}`")
```
(`src/deck-input-mapper.py:683-693`), where `MENU_ACTIONS["menu-root"] =
["omarchy-menu", "toggle"]` (`src/deck-input-mapper.py:257-262`). This is a
plain `subprocess.Popen`, not an emitted key or motion event — **confirmed,
not inferred**: the code path that would emit something (`emit()`, called from
`for key, value in mapper.translate(...): emit(key, value)` at
`src/deck-input-mapper.py:1512-1513`) never runs for this button, because
`translate()` returned before any key/motion tuple could be produced.

Following `omarchy-menu toggle` upstream (`bin/omarchy-menu` at `6d7826d`,
**READ**):

```bash
toggle)
  exec omarchy-shell shell toggle omarchy.menu "$(menu_payload "$route")"
  ;;
```
→ `omarchy-shell` (**READ**) resolves to `qs ipc -n -p "$OMARCHY_PATH/shell"
call -- shell toggle omarchy.menu '{"menu":"root"}'` — an IPC call over
Quickshell's own socket, landing in `shell/shell.qml`'s `toggle(pluginId,
payloadJson)` (**READ**, `shell/shell.qml:510`), which opens/closes the
`omarchy.menu` plugin's panel. Grepped `shell.qml`, `Menu.qml`, `omarchy-menu`,
and `omarchy-shell` for `dpms`, `brightness`, and `wake`: **no hits**. This
plugin has no code path to a display-power call.

---

## 2. The recorded "mapper grabs the pad" hypothesis: wrong on two counts

**Count 1 — it isn't grabbed in production.** `--grab` is an opt-in CLI flag
(`src/deck-input-mapper.py:1056`, `pad.grab()` only runs `if args.grab`). The
unit that actually starts the mapper does not pass it:

```
ExecStart=${MAPPER_BIN} --osk-backend=${MAPPER_OSK_BACKEND}
```
(`src/deck-session.sh:2039`) — no `--grab`. So on the shipped configuration,
the raw pad device is read non-exclusively; nothing about `EVIOCGRAB` is in
play at all today.

**Count 2 — it would not have mattered.** libinput has no "gamepad" or
"joystick" input-device capability class (`LIBINPUT_DEVICE_CAP_{KEYBOARD,
POINTER, TOUCH, TABLET_TOOL, TABLET_PAD, SWITCH}` is the exhaustive set —
**READ,** Aquamarine `src/backend/Session.cpp:958-988`, the file that turns a
libinput device into an `IKeyboard`/`IPointer`/etc.). The Deck's raw
`hid-steam` gamepad node is never classified into any of those, grabbed or
not, so its `BTN_BASE`/`ABS_HAT1X`/`ABS_HAT1Y`/face-button events were never
going to reach Hyprland's idle or DPMS logic through that node regardless of
who else is also reading it.

**What actually reaches Hyprland is the mapper's own synthetic `uinput`
device** — `UInput({e.EV_KEY: EMITTED_KEYS, e.EV_REL: EMITTED_RELS}, name="deck-input-mapper virtual keyboard")`
(`src/deck-input-mapper.py:1107-1109`), which declares a full keyboard keyset
**and** `REL_X`/`REL_Y` **and** `BTN_LEFT`/`BTN_RIGHT` (from
`TRIGGER_BUTTON_MAP`, `src/deck-input-mapper.py:226-227`, folded into
`EMITTED_KEYS`) on one combined device. Aquamarine does not pick one role per
device — `CLibinputDevice::init()` checks each capability independently and
fires `newKeyboard` **and** `newPointer` for the same device when both
capabilities are present (**READ,** Aquamarine `Session.cpp:958-967**). So
this virtual device, ungrabbed pad or not, is structurally eligible to be seen
as both a keyboard and a pointer by Hyprland — **this is the part I could not
fully close the loop on**: I could not, in the time available, find the exact
udev/libinput classification step that decides whether *this specific*
`uinput`-created device (no physical bus ID, combined keyboard+pointer
capability set) gets tagged `ID_INPUT_MOUSE`/`ID_INPUT_KEYBOARD` the way a
real device would, which is the thing that would explain why the operator
observed **neither** ordinary face-button presses (real `EV_KEY` through this
same device) **nor** trackpad motion (real `EV_REL` through the same device)
wake the panel, while both should, on paper, reach `setupKeyboard`'s
`onKeyboardKey` and `attachPointer`'s `motion` listener the same way a real
keyboard/mouse would. **Flagging this as genuinely undetermined** rather than
asserting a mechanism I have not read to the end. What I can say with
confidence is narrower than the original grab hypothesis, but true: **the
`EVIOCGRAB` explanation on record does not hold**, because grab was never
engaged and would not have been the relevant gate even if it had been.

---

## 3. Where the panel actually blanks and wakes, read from `shell/plugins/lock/Service.qml`

The file (`shell/plugins/lock/Service.qml` at `6d7826d`, 471 lines — same
file `docs/findings/T9-lock-service-mitigation.md` already reads for the
`recoverStrandedLock()` question; this is new territory in it, the blank timer
was not examined in that pass):

```qml
function armBlankTimer() {
  idleBlankTimer.armedAt = Date.now()
  idleBlankTimer.restart()
}

function runWake() {
  if (!wakeProcess.running) wakeProcess.running = true
  if (lockRequested) armBlankTimer()
}

function runBlank() {
  if (!blankProcess.running) blankProcess.running = true
}
...
Process {
  id: wakeProcess
  command: ["bash", "-c", "omarchy-system-wake"]
}

Process {
  id: blankProcess
  command: ["bash", "-c", "omarchy-brightness-keyboard off; omarchy-brightness-display off"]
}

Timer {
  id: idleBlankTimer
  interval: 5000
  repeat: false
  property double armedAt: 0
  onTriggered: {
    // A countdown frozen by suspend fires right after resume, which would
    // blank the freshly woken unlock screen under the user. Wall-clock time
    // exposes the gap: take a fresh run-up instead of blanking.
    if (Date.now() - armedAt > interval + 2000) {
      root.armBlankTimer()
      return
    }
    if (root.lockRequested && !root.authenticating) root.runBlank()
  }
}
```

`beginLock()` calls `armBlankTimer()` the moment a lock is requested
(`Service.qml:113-121`), so the countdown starts at lock time, not at some
separate idle threshold — **this is exactly the "distinct from the 150s
screensaver and 86400s lock" timeout the operator described**, matches the
observed ~5-6s blank (`docs/PROGRESS.md` §5.24: `dpmsStatus` sampled `1,1,1,1,1`
then `0`, roughly one-second samples), and is not read from `shell.json` or
any other config at all — `interval: 5000` is a literal in the QML, not a
property bound to `shellConfig.idle` the way `screensaverTimeoutSeconds` and
`lockTimeoutSeconds` are (compare `shell/plugins/services/idle/Service.qml`,
**READ**, which *does* read `shell.shellConfig.idle`). There is no GSettings
key here, no `dconf read -d` question applies — this section's constraint
about verifying against site defaults instead of a user's live value is not
applicable to this fix; there is no config layer to verify against at all,
because there is no config knob today.

`runBlank()` → `omarchy-brightness-display off` → (**READ**, `bin/omarchy-brightness-display`):
```bash
if [[ $step == "off" ]]; then
  hyprctl dispatch 'hl.dsp.dpms({ action = "disable" })' >/dev/null 2>&1
  exit 0
```
`runWake()` → `omarchy-system-wake` → `omarchy-brightness-display on`:
```bash
elif [[ $step == "on" ]]; then
  hyprctl monitors -j 2>/dev/null | jq -e '...' >/dev/null 2>&1 && exit 0
  hyprctl dispatch 'hl.dsp.dpms({ action = "enable" })' >/dev/null 2>&1
  exit 0
```
Both are genuine Hyprland dispatches, not backlight-only — this matches the
already-recorded correction in `docs/PROGRESS.md` §5.24 that "the backlight
sysfs value does not track DPMS state" and `dpmsStatus` really was `0`.

`runWake()` is called from `LockView.qml`'s own input detector
(**READ**, `shell/plugins/lock/LockView.qml`):
```qml
MouseArea {
  ...
  onClicked: { root.wakeRequested(); root.forcePasswordFocus() }
  onPositionChanged: root.wakeRequested()
}
...
Keys.onPressed: function(event) {
  root.wakeRequested()
  ...
}
```
— a QML-level listener scoped to the lock's own surface, entirely separate
from (in addition to) Hyprland's compositor-wide
`key_press_enables_dpms`/`mouse_move_enables_dpms` (`default/hypr/input.lua`,
**READ**, both `true` upstream). Two independent "wake" paths exist; only one
of them is under this repo's control without a QML patch (§5.1), and it is
untouched by the fix in §5.2.

---

## 4. What is confirmed vs. reasoned, stated plainly per the task's instruction

**Confirmed from source, high confidence:**
- QAM's own button press emits zero uinput/kernel input events (§1).
- The mapper does not grab the pad in production, and libinput has no
  gamepad-class device capability, so the raw pad was never seen by Hyprland
  either way (§2).
- The 5-second blank timer is `shell/plugins/lock/Service.qml`'s
  `idleBlankTimer`, unconditional, not read from any config (§3).
- Blanking/waking during lock is a real Hyprland DPMS dispatch
  (`hl.dsp.dpms`), run from Omarchy's own scripts, not from Hyprland's
  generic auto-wake config directly (§3).
- `omarchy-menu`/`Menu.qml`/`shell.qml`'s dispatcher have no code path to any
  display-power call (§1, confirmed by exhaustive `gh api search/code` across
  `basecamp/omarchy@6d7826d` for `dpms`, `omarchy-system-wake`,
  `brightness-display`).

**Reasoned, not confirmed — flagged rather than guessed past:**
- *Why* QAM's press wakes the panel at all, given (a) and (e) above. The
  best-supported candidate is Hyprland's own `mouse_move_enables_dpms` firing
  from a compositor-issued cursor warp/motion when the new menu layer surface
  takes focus, which would explain a *process-spawn* action producing a real
  pointer-motion event without `omarchy-menu` ever calling a wake script
  directly. I did not find the specific Hyprland code that performs such a
  warp on layer-surface focus in the time available for this task, so this
  is inference, not a read fact.
- Why real face-button key events and real trackpad motion — both emitted
  through the mapper's own combined `uinput` device — do not also wake the
  panel via the same `misc:*_enables_dpms` mechanism or via `LockView.qml`'s
  own listeners. I could not close the loop on whether Aquamarine/libinput
  actually classifies that specific synthetic device as a live
  keyboard+pointer for udev/seat purposes; this is the one genuinely open
  question and would need either a `WAYLAND_DEBUG=1`/`libinput debug-events`
  trace on the physical Deck, or reading Aquamarine's udev-tag handling in
  more depth than this session had budget for.

Neither open item changes the recommendation in §5: both proposed fixes work
regardless of which exact path explains the asymmetry, because they act on the
two mechanisms that are confirmed (Hyprland's generic auto-wake config, and
the hardcoded blank-timer constant) rather than on the unconfirmed one.

---

## 5. Proposed fixes

### 5.1 Requirement #1 — stop the generic auto-wake, leave the lock's own wake path alone

**Where it lands:** `~/.config/hypr/input.lua` — the same file
`docs/PROGRESS.md` §5.24 already used for the `above_lock = 2` layer rule, one
of "the five user files [that] are upstream's sanctioned override seam"
(§5.24). **Not** a new file.

⚠️ **This file REPLACES upstream's `default/hypr/input.lua` wholesale — Hyprland
does not merge a user override with the shipped default.** The same trap
`docs/tasks/T5-fork-plan.md` §5.3 documents for `shell.json` applies here: a
Deck `input.lua` containing only the DPMS lines would silently drop
`kb_layout`, the non-Latin-layout handling, `numlock_by_default`, the touchpad
block, and the terminal scroll-factor overrides. **Any stage that writes this
file must mirror the whole upstream file**, the same way
`stage_greeter_rotation` mirrors `${UPSTREAM_GREETER_LUA}` with a recorded
`UPSTREAM_GREETER_SHA256` drift check (`src/deck-session.sh:1700-1707`) — this
is the existing precedent in this repo for exactly this problem, applied to a
different Lua file.

**The full proposed content** (upstream's file, verbatim, plus the two new
`misc` lines plus the already-recorded `above_lock` rule — **(VERIFIED)
`luac -p` reports no syntax errors** on this exact text):

```lua
-- https://wiki.hypr.land/Configuring/Basics/Variables/#input
--
-- MIRROR of Omarchy's default/hypr/input.lua (basecamp/omarchy@6d7826d) plus
-- the Deck's own additions. This file REPLACES the default wholesale --
-- Hyprland does not merge a user override with the shipped one -- so every
-- upstream setting has to be carried down here by hand, the same trap
-- documented for shell.json (docs/tasks/T5-fork-plan.md §5.3).

local function read_vconsole()
  local values = {}
  local file = io.open("/etc/vconsole.conf", "r")
  if not file then
    return values
  end

  for line in file:lines() do
    local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
    if key and value then
      value = value:gsub("%s+#.*$", "")
      value = value:gsub('^"(.*)"$', "%1")
      value = value:gsub("^'(.*)'$", "%1")
      values[key] = value
    end
  end

  file:close()
  return values
end

local non_latin_layouts =
  " af am ara bd bg by et ge gr il in iq ir kg kh kz la lk mk mm mn mv np rs ru sy th tj ua "

local vconsole = read_vconsole()

local kb_layout = vconsole.XKBLAYOUT or "us"
local kb_variant = vconsole.XKBVARIANT or ""
local kb_options = "compose:caps,shift:both_capslock_cancel"

if non_latin_layouts:find(" " .. kb_layout:match("^[^,]*") .. " ", 1, true) then
  kb_layout = "us," .. kb_layout
  kb_variant = "," .. kb_variant
  kb_options = kb_options .. ",grp:alts_toggle"
end

hl.config({
  input = {
    kb_layout = kb_layout,
    kb_variant = kb_variant,
    kb_model = "",
    kb_options = kb_options,
    kb_rules = "",
    follow_mouse = 1,
    sensitivity = 0,

    repeat_rate = 40,
    repeat_delay = 250,
    numlock_by_default = true,

    touchpad = {
      natural_scroll = false,
      clickfinger_behavior = true,
      scroll_factor = 0.4,
    },
  },

  misc = {
    -- DECK ADDITION (docs/PROGRESS.md §5.24a row 1). Upstream ships both of
    -- these `true`. On this hardware the only two things that ever call
    -- DPMS off are the lock screen's own idleBlankTimer
    -- (shell/plugins/lock/Service.qml) and the 86400s idle.lock in
    -- shell.json -- nothing else in Omarchy's own architecture puts a
    -- monitor into DPMS-off, so nothing else needs these to wake it back up.
    -- Disabling them stops Hyprland's OWN generic "any key/mouse motion
    -- re-enables DPMS" behaviour, which is the thing an incidental pointer
    -- event from opening the QAM menu rides on (docs/findings/T9-lock-wake-and-blank-timing.md
    -- §1, §4). The lock screen's own wake path (LockView.qml's
    -- MouseArea/Keys.onPressed -> wakeRequested() -> omarchy-system-wake) is
    -- UNCHANGED by this and still wakes the panel for real typing/clicking
    -- on the password field.
    key_press_enables_dpms = false,
    mouse_move_enables_dpms = false,
  },
})

-- Scroll nicely in the terminal.
o.window("(Alacritty|kitty|foot)", { scroll_touchpad = 1.5 })
o.window("com.mitchellh.ghostty", { scroll_touchpad = 0.2 })

-- docs/PROGRESS.md §5.24: draws deck-osk above a lock surface AND makes it
-- hit-testable there. Hardware-verified 2026-08-11
-- (T9-lock-service-mitigation.md T0.4). Kept here, not a separate deck.lua --
-- see that section for why.
hl.layer_rule({ match = { namespace = "deck-osk" }, above_lock = 2 })
```

**How T5 bakes it in:** as a new stage in `src/deck-session.sh`, modelled
exactly on `stage_greeter_rotation` (mirror upstream, hash-check for drift,
`luac -p` before install, install to `~/.config/hypr/input.lua` for both
`/etc/skel` and the created user per the `/etc/skel`-is-too-late trap
`docs/tasks/T5-fork-plan.md` §3's trap (a) already names). **I did not write
this stage.** Two reasons: (1) the `above_lock` half of this file's content is
`docs/PROGRESS.md` §5.25 decision #1, already approved with **owner: Deck**,
not yet coded as a stage anywhere in this repo — it is currently hand-applied
only, on the physical Deck. Writing a stage that ships only my two `misc`
lines without the `above_lock` rule would either (a) silently drop the
already-approved fix if a future stage overwrites this file without knowing
about it, or (b) require me to also implement the `above_lock`/service-mask
stage, which reaches into `deck-osk` namespace territory the other agent
working this session owns. (2) `input.lua` replaces-wholesale, so a partial
stage is actively dangerous per the box above — the two fixes belong in **one**
stage, written once, not two competing writers of the same file.
**Recommendation: whoever implements §5.25 decision #1's `above_lock`/mask
stage should fold these two `misc` lines into the same `input.lua` mirror**,
using the full content above as the starting point.

**Verification, once implemented:**
- **[B]** `luac -p` on the generated file before install (same gate
  `stage_greeter_rotation` already uses).
- **[V]** `hyprctl getoption misc:key_press_enables_dpms` and `hyprctl
  getoption misc:mouse_move_enables_dpms` both read `int: 0` after the file is
  installed and Hyprland reloaded.
- **[H]** press QAM while locked: the panel stays dark. Then type a password
  character with the pad-driven OSK: the panel wakes (proves `LockView.qml`'s
  own wake path is untouched). This is the one item this session could not
  run — no hardware access.

### 5.2 Requirement #2 — `idleBlankTimer.interval`: 5000 → 20000

**Where it lives:** `shell/plugins/lock/Service.qml`, upstream
`basecamp/omarchy` source (the **RUNTIME** pin, `6d7826d` — see
`docs/tasks/T9-beta2-rebase.md`/`docs/PROGRESS.md` §5.22), **not** a file this
repo owns and **not** a config value — it is a literal in shipped QML,
compiled into the `omarchy-dev`/shell package. There is no `shell.json` key,
no GSettings key, no `dconf` question to apply here — confirmed by reading the
whole file: `screensaverTimeoutSeconds`/`lockTimeoutSeconds` are the only two
`idle`-config-driven timers in this plugin pair, and `idleBlankTimer` is not
one of them.

**Exact proposed patch** (**(VERIFIED)** — this is a real unified diff,
produced by patching the fetched upstream file and diffing against the
original; it was not applied to any running Hyprland/Quickshell, since none is
available in this environment):

```diff
--- a/shell/plugins/lock/Service.qml
+++ b/shell/plugins/lock/Service.qml
@@ -373,7 +373,7 @@

   Timer {
     id: idleBlankTimer
-    interval: 5000
+    interval: 20000
     repeat: false
     property double armedAt: 0
     onTriggered: {
```

One line. The "frozen by suspend" grace check three lines below
(`Date.now() - armedAt > interval + 2000`) reads `interval` as a property, so
it scales automatically — no second edit needed, and this was checked by
reading the surrounding function, not assumed.

**How T5 bakes it in:** this is where `docs/tasks/T5-fork-plan.md`'s existing
seam list (S1–S6, §3 of that file) has a gap. All six of those seams patch or
configure `omacom-io/omarchy-iso` (the **UPSTREAM** pin) or write to the
installed target (`/etc/skel`, S4's package, S6's hook) — none of them is "a
patch applied to the `basecamp/omarchy` **RUNTIME** checkout before
`omarchy-iso-make --local-source <omarchy-checkout> ...` builds
`omarchy-dev`/the shell package from it" (T5 §2's "Pin A" mechanism, which is
already how this project plans to build the shell package from a pinned git
checkout rather than a channel). That checkout is exactly where this patch
belongs — a new **S7** seam: `iso/overlay-runtime/patches/*.patch`, `git apply
--3way`'d against the pinned `basecamp/omarchy` checkout, same discipline as
`overlay/patches/` for the `UPSTREAM` pin (§1's "why this and not a hard
fork" — a hard-coded patch that fails loudly on conflict rather than a silent
fork drift). Flagging this as a genuinely new finding for whoever picks up T5
next — it is not covered by the six seams as currently written, and I did not
modify `docs/tasks/T5-fork-plan.md` to add it myself, since that file is
outside what this task asked me to own.

**Verification, once implemented:**
- **[B]** the patch applies cleanly against the pinned RUNTIME checkout
  (`git apply --check`) — the failure-loudly gate `docs/tasks/T5-fork-plan.md`
  §1 already commits to for every patch in this scheme.
- **[H]** lock the Deck, wait, confirm the panel stays lit for ~20s before
  blanking (a stopwatch against `dpmsStatus`, the same method
  `docs/PROGRESS.md` §5.24 used to measure the original ~5-6s).

---

## 6. What this session verified by running something, vs. reasoned about

**Ran:**
- `gh api` against `basecamp/omarchy@6d7826d`, `hyprwm/Hyprland@v0.56.2`, and
  `hyprwm/aquamarine@main` — every quoted file in this document was fetched
  this way, not recalled from training data.
- `gh api search/code` across `basecamp/omarchy` for `dpms`,
  `omarchy-system-wake`, `brightness-display`, `mouse_move_enables_dpms`,
  `key_press_enables_dpms` — the "no code path" claims in §1/§4 are exhaustive
  over what GitHub's code search indexes for that repo, not a partial grep.
- `luac -p` against the full proposed `input.lua` (§5.1) — syntactically valid
  Lua, the same gate `stage_greeter_rotation` uses.
- A Python find/replace + `diff -u` producing the exact unified diff in §5.2
  against the real fetched upstream file.

**Did not run, because no hardware and no Hyprland/Quickshell environment
were available this session:**
- Anything on the physical Deck (explicitly out of scope for this task).
- `hyprctl getoption`/`hyprctl layers` against a live Hyprland instance.
- A nested-Hyprland provocation of the sort
  `docs/findings/T9-lock-service-mitigation.md` §4 already designed for the
  `above_lock` question — the same tier-0 approach (a nested compositor, no
  Omarchy, no Deck) would resolve §4's one open question (does the mapper's
  synthetic device actually get classified as a live keyboard+pointer) and is
  the natural next step before either fix ships.
