# T10 — Steam + extest on the Omarchy desktop: RESULTS

**Run 2026-08-11 (session 21), operator at the panel, ~45 minutes.** Spec:
`docs/tasks/T10-steam-extest-spike.md`. Background: `docs/PROGRESS.md` §5.29 and
`docs/findings/P20-steam-xtest-closure.md` (R-53, R-54).

## Verdict in one line

🔴 **Rows 1–3, 6 and 8 PASS. The option is open: Steam's own keyboard CAN drive
our Wayland desktop through the extest bridge — measured, not inferred.** Row 4
fails for a reason that has nothing to do with Steam, row 5 shows no defect, and
row 7 was skipped by operator decision with its prediction recorded as inferred.

## The measurements

| # | Test | Result | Oracle |
|---|---|---|---|
| 1 | Right trackpad moves the desktop pointer | ✅ **PASS** | operator's eyes; cursor drove window clicks |
| 2 | STEAM+X raises Valve's keyboard | ✅ **PASS** | eyes, plus `Steam Input On-screen Keyboard` in `hyprctl clients`, XWayland, floating |
| 3 | Dual-cursor trackpad typing into a **Wayland-native** client | ✅ **PASS** | `/tmp/t10-typed.txt` contained `hello\n` — the file, not the screen |
| 4 | Touchscreen taps on Valve's keyboard | ❌ fails — **but desktop-wide, see below** | operator |
| 5 | Pointer sanity under `transform = 3` | 🟡 **no defect seen** | `cursorpos (6,218)` inside a 1024×640 logical space; no rotation or offset error |
| 6 | Typing lands in the field, focus behaviour | ✅ **PASS** | `abc` landed with Valve's keyboard on screen; focus ended on the Wayland client |
| 7 | 🔴 THE LOCK | ⏭️ **SKIPPED — operator decision** | prediction below, **INFERRED** |
| 8 | Quit Steam → the pad returns | ✅ **PASS** | `re-bound to /dev/input/event7 (Steam Deck)`; extest device gone |

## 🔴 Three corrections to T10's own procedure — each would have produced a wrong answer

### 1. The spec deploys ONE library. Both are required.

Step 1 copies `libextest-i686.so` only, on §5.29's premise that "Steam's input
process is 32-bit". Measured: it is *both*.

```
ERROR: ld.so: object '/tmp/libextest.so' from LD_PRELOAD cannot be
preloaded (wrong ELF class: ELFCLASS32): ignored.
```

With the i686 build alone, **nine 64-bit `steamwebhelper` processes rejected
the bridge** while only the 32-bit `steam` loaded it. The `extest fake device`
never appeared and the spike looked like a failure. The correct invocation
preloads both, colon-separated; each process loads the one matching its class
and ignores the other (the ignore is noisy — ~295 log lines — and harmless):

```
LD_PRELOAD=/tmp/libextest-i686.so:/tmp/libextest-x86_64.so
```

After which every process holding `libXtst` also holds extest:

| Process | Class | `libXtst` | extest |
|---|---|---|---|
| `steam` | 32-bit | ✅ | `libextest-i686.so` |
| `steamwebhelper` ×9 | 64-bit | ✅ | `libextest-x86_64.so` |

⚠️ **A run that checked only `pgrep steam` and the device node would have
concluded "extest does not work with Steam".** It does; it was half-loaded.

### 2. The step-2 checkbox fires too early

The spec expects `extest fake device` in `/proc/bus/input/devices` immediately
after launching Steam. **It is not there.** extest creates its uinput device on
the **first XTEST call**, so the device appeared only once the operator moved
the trackpad (row 1). Once created: `input33`, `Handlers=sysrq kbd event8
mouse4 js1`. The absence of the device before any input is **not** evidence the
bridge failed.

### 3. 🔴 `hyprctl dispatch` is a Lua API now — the old syntax is a SYNTAX ERROR

Hyprland **0.56.2** (what the Deck runs) replaced dispatch's string arguments
with a Lua dispatcher API:

```
$ hyprctl dispatch movetoworkspacesilent 2,address:0x...
error: [string "return hl.dispatch(movetoworkspacesilent 2,ad..."]:1: ')' expected near '2'
 → Note: dispatch in lua is a shorthand for hl.dispatch(...)
```

The working forms are `hl.dsp.<namespace>.<action>(<table>)`:

```bash
hyprctl dispatch 'hl.dsp.focus({ workspace = 2 })'
hyprctl dispatch 'hl.dsp.exec_cmd("[workspace 2] foot -T NAME sh -c \"cat\"")'
```

The namespaces, enumerated from the live instance (by raising the table keys as
a Lua error, since there is no introspection command):

- **`hl.dsp`** — `cursor dpms event exec_cmd exec_raw exit focus force_idle
  force_renderer_reload global group layout no_op pass release_input_capture
  send_key_state send_shortcut submap window workspace`
- **`hl.dsp.window`** — `alter_zorder bring_to_top center clear_tags close
  cycle_next deny_from_group drag float fullscreen fullscreen_state kill move
  pin pseudo resize set_prop signal swap tag toggle_swallow`
- **`hl.dsp.workspace`** — `change_id move rename swap_monitors toggle_special`

`hl.dsp.focus` and `hl.dsp.window.move` take a table: *"expected a table, e.g.
{ direction = "left" }"*.

⚠️ **This is a live hazard for this repo, not a note.** Anything shelling out to
`hyprctl dispatch` with the old syntax fails *silently* if its stderr is
discarded — which is exactly how it wasted time here. **`docs/RECOVERY.md` and
`src/deck-session.sh` need auditing for it.** Same shape as §5.28: a call that
looks like it works and does nothing.

## Row 4 — touch fails, and it is NOT Steam's fault

Taps on Valve's keyboard did nothing. **Neither did taps anywhere else on the
desktop**, tested deliberately as the discriminator. Hyprland *does* have the
panel bound — `Touch Device at ...: fts3528:00-2808:1015` — and the kernel
exposes it (`FTS3528:00 2808:1015`, `event14`/`event15`).

So this is a **desktop-wide touch gap that exists with or without Steam**, and
it must not be counted against the Steam option. 🆕 It is a new open issue in
its own right, and it touches any future touch plan for *our* OSK equally.
Nobody had tested desktop touch before today.

## Row 7 — skipped, prediction recorded as INFERRED

The operator chose not to run it rather than risk a locked Deck at the end of a
long session; the escape path has never been executed. **The prediction stands
unmeasured:**

- Steam's keyboard is an **XWayland window** and cannot render above
  `ext-session-lock` — the same constraint §5.29 already recorded.
- Our OSK cannot be summoned while Steam holds the pad: the mapper has no
  device (proven this run — see row 8's journal).
- Session 20 measured that there is **no unlock IPC at all**, and that
  `clear_crashed_lockscreen` refuses a healthy lock.

Together those say a locked Deck with Steam resident is **unanswerable from the
panel**. ⚠️ That is an inference from three measured facts, not a measurement.
Whoever runs it should de-risk first by proving the SSH escape against a lock
taken *without* Steam resident, where our OSK still provides a second route.

## What this means for the decision (`T10` §"The decision this feeds")

The spec's table says: *rows 1–6 pass, row 7 unacceptable → operator chooses
hybrid complexity vs. our-OSK plan; honest default: our OSK.*

Rows 1–3 and 6 passed. Row 7 is unresolved but its prediction is unfavourable,
and it does not change one thing that was already true: **our OSK remains the
installer's and the lock screen's keyboard in every outcome.** What is newly
open is only whether Steam's keyboard *also* serves ordinary Desktop Mode use,
which would buy a familiar keyboard at the cost of: preload wiring as a
`deck-session.sh` stage, the tray-host constraint returning (retired §2.6), an
autostart policy, and a resident Steam that takes the controller away from our
mapper whenever it runs.

🔴 **This is an operator decision and it is not made here.**

## Deck state at teardown

No stray windows, workspace 1, `deck-input-mapper` active and re-bound to
`event7`, `lizard_mode=N`, snapshot **#12** (`post-T11`) predates the spike.
Left in `/tmp` for a resumed run (cleared on reboot): `libextest-i686.so`,
`libextest-x86_64.so`, `t10-typed.txt`.
