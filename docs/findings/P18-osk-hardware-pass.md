# P18 — T8's on-screen keyboard, proven on hardware (R-43…R-46)

**Session 18, 2026-08-10. Operator in front of the Deck.**
Snapshot **#8** taken before the first write.

The second time anything in this project was watched on a screen. It confirmed
the thing it set out to confirm and found one defect that had been crashing the
input layer six times a boot without anyone noticing.

## R-43 — T8's layer-shell keyboard WORKS in Desktop Mode. Operator-confirmed.

`stage-input-mapper` installed three modules into `/usr/local/lib/deck-osk/`
and rewrote the unit as `ExecStart=/usr/local/bin/deck-input-mapper
--osk-backend=layer`. After a restart the operator pressed **STEAM+X** and
reported: **"it works"**.

**This was verified as the real path, not a debugging artifact**, because the
session had left `--demo` overlays running earlier and "it works" could
legitimately have described one of those. Two facts settle it:

```
overlay argv : /usr/bin/python3 /usr/local/lib/deck-osk/deck_osk_wayland.py
                 (no --demo)
overlay ppid : 236078 = python3 /usr/local/bin/deck-input-mapper --osk-backend=layer
```

The live surface was **a child of the mapper**, spawned by the chord, with no
`--demo` flag. Every `--demo` instance carried the flag.

⚠️ **This check was worth doing and nearly was not done.** An operator saying
"it works" is the strongest evidence this project has, and it was one argv away
from being attached to the wrong process. When a session has left debug
artifacts on the device, a confirmation names a *thing on screen*, not a
*code path* — resolve which before recording it.

Corroborating, from the mapper's own journal: **zero fallbacks**. Had the
overlay failed, the mapper would have fallen back to squeekboard and logged it,
and "it works" would have described squeekboard.

## R-44 — 🐞 DEFECT: the mapper died whenever the pad re-enumerated

Found by reading the journal during R-43, not by looking for it.

```
File "/usr/lib/python3.14/site-packages/evdev/eventio.py", line 71, in read
    events = _input.device_read_many(self.fd)
OSError: [Errno 19] No such device
deck-input-mapper.service: Main process exited, code=exited, status=1/FAILURE
```

**Six crashes and nine restarts in a single boot.** `pad.read()` raises `ENODEV`
when the node goes away underneath it — the controller re-enumerating — and
nothing caught it, so the process exited 1 every time.

⚠️ **Why this is worse than "systemd restarts it".** The unit carries
`StartLimitBurst=5` / `StartLimitIntervalSec=60`, deliberately (session 16 added
the bound so a genuinely missing device shows up in the journal instead of
spinning). Six crashes is past that. And **with `lizard_mode=N` the mapper is
the only input path on the device** (§5.9, §5.21), so exhausting the start limit
leaves a handheld with no pointer and no keys, recoverable only over SSH.

One restart is worth quoting, because it shows the state the device passes
through:

```
deck-input-mapper: no gamepad matched None. Devices: ...
  /dev/input/event5:Valve Software Steam Controller
  /dev/input/event6:Valve Software Steam Controller
```

Mid-re-enumeration there is **no node named "Steam Deck" at all** — the name the
device carries when settled. A mapper that restarts into that window finds
nothing and exits again.

**Fixed.** `ENODEV` out of the read loop is now caught and handed to
`pick_device`, which already knows how to wait patiently for a pad to come back
— that is what it does while Steam owns the controller. It re-grabs, re-registers
the fd, re-reads the axis ranges from the replacement, and says so on both
sides:

```
deck-input-mapper: the pad disappeared (...); waiting for it to come back
deck-input-mapper: re-bound to /dev/input/event7 (Steam Deck)
```

**Nothing in the repo could have caught this.** The unit suites drive
`Mapper.translate()`, which never opens a device; the OSK end-to-end suite uses
a pad that stays put. It needs the node to vanish underneath a live read.
`test/mapper-pad-loss-e2e.py` now does exactly that, and it was verified to
**fail 5 assertions with the fix reverted** — including `got 1` for the exit
code, the same status the Deck's journal recorded.

## R-45 — gtk4-layer-shell must be preloaded, or the overlay is an ordinary window

Found on the dev machine, and it would have reached the Deck.

`gtk4-layer-shell` works by interposing on `libwayland-client`, so it must load
first. Under PyGObject it never does: `import gi.repository.Gtk` pulls libwayland
in before any of our code runs, and there is no link order to fix because
nothing is linked.

The failure is quiet in the way that matters. The process starts, GTK prints
`Failed to initialize layer surface, GTK4 Layer Shell may have been linked after
libwayland` on stderr, and **a perfectly normal focusable window appears** —
which would take keyboard focus away from the field being typed into, destroying
the property the whole design rests on.

`deck_osk_wayland` now re-execs itself once with `LD_PRELOAD` set.
Confirmed on the dev machine: `hyprctl layers` shows `namespace: deck-osk` on
the overlay layer, zero warnings, and `hyprctl activewindow` **unchanged** while
it is up.

## R-46 — `hyprctl` is not usable over SSH, and it wasted time here

`hyprctl` needs `HYPRLAND_INSTANCE_SIGNATURE`; over SSH it is unset, the
instance directory under `/run/user/1000/hypr/` contains **stale signatures from
previous sessions**, and reading the live one out of `/proc/<pid>/environ` also
came back empty. Every remote attempt to observe the overlay returned "not
found" while the overlay was in fact running.

**Do not diagnose a Wayland surface over SSH.** Ask the operator, or check
process facts (`ps`, `pgrep -af`, parentage) which do not need the compositor.

⚠️ And a self-inflicted one worth writing down: `pkill -f deck_osk_wayland` run
over SSH **kills its own shell**, because the remote command line contains the
pattern. It looked exactly like the Deck dropping off the network. Use a
bracket: `pkill -f "deck_osk_[w]ayland"`.

## State on exit

| | |
|---|---|
| Snapshot | **#8**, taken before the first write |
| `/usr/local/lib/deck-osk/` | `deck_osk_layout.py`, `deck_osk_tty.py`, `deck_osk_wayland.py` |
| Unit | `ExecStart=… --osk-backend=layer` |
| Mapper | **active**, bound to `/dev/input/event7 (Steam Deck)`, ENODEV fix deployed |
| `lizard_mode` | **`N`** — still not persisted (§5.21) |
| squeekboard | installed and running; **the automatic fallback**, no longer the primary |
| Fallbacks fired | **0** |

## Not covered by this pass

- **Focus-triggered auto-show.** squeekboard has it (§5.20); ours is
  summon-only. Whether both keyboards appearing at once is a problem in practice
  was not observed.
- Typing a full **Wi-Fi passphrase** end to end — T8's second done-criterion —
  was not separately confirmed beyond "it works".
- The **installer's** TTY keyboard sharing a console with `gum`/`archinstall`
  (TIOCSWINSZ). Designed, untested, and not part of this pass.

---

# The installer half, answered in QEMU (R-47…R-49)

**Session 18, same day. `test/vm/vm-osk-tty-test.sh`.** T8 step 4 shipped with
one thing designed and never tested: the keyboard and an installer TUI sharing
a single console. This settles it.

## R-47 — ✅ they DO share one console, and the typing lands

The mechanism `deck_osk_tty.write_at` documents works. The TUI is told, via
`stty rows`, that the console is shorter than it is; it lays out inside that and
never draws below it; the keyboard takes the rows underneath.

Measured in the guest, with **gum** as the TUI:

```
console.rows = 50        gum drew at row 1        keyboard below it
osk.shown = 1            gum.survived = 1         (both on screen at once)
gum.received = hlH1      ← typed with the TRACKPADS, nothing else attached
```

**`gum.received` is the assertion that matters** and it is not read off the
screen — it is what gum itself wrote to a file on submit. Lower case, upper
case via the shift key, and a digit, entered by moving two trackpad cursors and
pulling triggers, delivered through `uinput` → the active VT → gum's stdin.
Nothing under the keyboard knew a controller existed.

⚠️ **Observed through `/dev/vcs2`, the kernel's own copy of the console.** The
T2 spike used `tmux capture-pane`, which *cannot* answer this question: tmux
would own the screen and redraw over anything the mapper painted, which is
precisely the collision under test. A prototype that reconstructed the screen
from a pty byte stream mis-read a correct render twice before being abandoned.
When the question is "what is on the console", ask the kernel.

## R-48 — 🐞 DEFECT: a failed console write killed the whole mapper

Found by this suite, on the first run that got far enough.

```
File "deck_osk_tty.py", line 163, in write_at
    stream.flush()
OSError: [Errno 5] Input/output error
```

**Why it happens is normal, not exotic.** `openvt` deallocates the VT when the
program on it exits, so the moment gum submitted and quit, `/dev/tty2` stopped
accepting writes and the next redraw killed the mapper. **The installer is a
sequence of screens that start and exit** — archinstall runs several — so this
would fire in ordinary use, not just in a test.

**Fixed.** `osk_draw`/`osk_erase` catch `OSError` and disable the tty keyboard
for the session, loudly, keeping navigation:

```
deck-input-mapper: the tty keyboard failed (could not draw on /dev/tty2:
[Errno 5] Input/output error); it is DISABLED for the rest of this session,
navigation still works
```

Same lesson as R-44's `ENODEV`, from a different direction: **drawing a keyboard
is optional; being the only input path is not.** `test/osk-tty-e2e.py` now
closes a pty's master end under a live keyboard to reproduce it, and was
verified to fail 4 assertions with the fix reverted.

## R-49 — ✅ RESOLVED: `stty rows` RESIZES a Linux VT, and the keyboard fell off it

**First recorded here as "the requested position is not honoured, cause
unexplained". That was wrong, and one measurement settled it.**

The keyboard was landing with its last row at 45 on what was believed to be a
50-row console. Diagnostics inside the guest:

```
stty_at_snap = 45x160     vcs2_bytes = 7200      (7200 / 160 = 45 rows)
rows carrying keyboard content: 45,              ← ONE row, not five
```

**`stty rows 45` did not merely change the size reported to applications — it
resized the console.** `/dev/vcs2` shrank from 8000 bytes to 7200. Rows 46-50
stopped existing, the kernel clamped all five keyboard rows onto the last line,
and they overwrote each other. `--osk-top-row` was honoured exactly; it pointed
off the end of a console that had shrunk underneath it.

⚠️ **This invalidates the mechanism `deck_osk_tty.write_at` documented.**
"Shrink the TUI's reported window with TIOCSWINSZ so it confines itself above
the keyboard" is self-defeating on a VT: the rows you shrink the TUI out of are
the same rows you delete. That docstring had been written from reasoning, never
run, and it was wrong.

⚠️ **And the failure was silent in the worst way.** Five rows collapsed onto one
garbled line that still contained the word `shift` — so `osk.shown=1` passed,
and a human glancing at a screenshot would have seen "a keyboard". Only counting
which rows carried keyboard content exposed it.

**Three changes:**

1. `write_at` takes `console_rows` and **refuses**, with a message naming both
   the rows it needs and the rows that exist, rather than painting five onto one.
2. The mapper measures the console height **at every draw** — `stty rows` can
   resize a VT at any moment, so a height read at startup is not trustworthy —
   and passes the guard. A refusal degrades to navigation-only like any other
   draw failure (R-48).
3. The VM probe **stops shrinking the console**. The keyboard takes the bottom
   rows of the full console and the TUI keeps all of it.

**Verified:** console stays 50 rows, `row.osk_last = 50` for a requested top of
46 — exactly the rows asked for — and `gum.received` is still `hlH1`.

⚠️ **What this leaves open for archinstall, and it is a real question.** With no
shrinking, nothing confines the TUI to the top. `gum` uses three rows and never
collides, so it coexists happily. **A full-screen curses TUI like archinstall's
menu will draw over the keyboard**, and the two will fight on redraw. That is a
design fork — a relay through a smaller pty, or a keyboard that hides while a
full-screen screen is up — and it needs deciding before the installer ships.

## R-50 — auto-show: Hyprland IPC and fcitx5 are BOTH ruled out. The seat contest is unavoidable.

Step 7 left our keyboard summon-only where squeekboard auto-shows on focus.
Fixing that needs a focus signal from somewhere. Three candidates; two are now
dead by enumeration rather than by argument.

**1. Hyprland IPC — no.** Its event vocabulary is about windows, not text
fields: `activewindow`, `activewindowv2`, `windowtitle`, `windowtitlev2`,
`focusedmon`, `focusedmonv2`, `activelayout`, `submap`, `openwindow`. Nothing
about a text field taking focus, which is a client-internal state surfaced only
through the text-input protocol. (`TextInputV1`/`TextInputV3` do appear in the
binary — they are the protocol *implementations*, not IPC events. Easy to
misread as a hit.)

**2. fcitx5 telling us — no, and it looks like a yes at first.** fcitx5 does
publish `org.fcitx.Fcitx.VirtualKeyboard1` at `/virtualkeyboard`, on this
machine **and on the Deck**, which reads like exactly the hook needed. It is
not:

```
.HideVirtualKeyboard    method
.ShowVirtualKeyboard    method
.ToggleVirtualKeyboard  method
```

**Three methods, no signals.** That is the INBOUND direction — a way to tell
fcitx5 to show a keyboard, not a way to be told that focus moved. Across every
object fcitx5 exports (`/controller`, `/virtualkeyboard`,
`/org/freedesktop/portal/inputmethod`) the only signals are
`InputMethodGroupsChanged` and the generic `PropertiesChanged`; neither is about
focus. There is no `VirtualKeyboardBackend` interface in the binary either — no
register-and-be-told seam to plug into.

**3. Bind the input method ourselves — the only path left**, and it means
displacing an occupant. R-50's measurement from the watcher stands: the seat is
held by **fcitx5**, always, and by **squeekboard** whenever it runs.

### What that costs, stated rather than assumed

fcitx5 is Omarchy's input method for every other language. Taking the Wayland
seat from it is a real trade and it is the operator's call, not a detail:

- ⚠️ **Unmeasured:** whether fcitx5 keeps serving XWayland clients through its
  XIM/IBus interfaces while the Wayland seat belongs to someone else. If it
  does, the cost is smaller than it looks. **Measure this before deciding** —
  it is the single fact that determines whether this is cheap or expensive.
- The fallback survives either way: squeekboard's `SetVisible` over DBus does
  not need the input-method seat, so R-48's safety net is unaffected.

**Recommendation: do not take the seat until that one measurement is in.**
Summon-only via STEAM+X works today and costs nothing.

## R-51 — ✅ MEASURED: taking the Wayland seat costs fcitx5 only its WAYLAND clients

R-50 left one fact unmeasured, and said it alone decided whether auto-show was
cheap or expensive: **does fcitx5 keep serving XWayland clients while the
Wayland input-method seat belongs to someone else?**

**It does.** fcitx5 takes `--disable <addon>` — its own running command line
already used it (`--disable notificationitem`) — so the Wayland addon can be
dropped without touching the rest.

| | fcitx5 as shipped | with `waylandim` disabled |
|---|---|---|
| `XIM_SERVERS` (X11/XWayland) | `@server=fcitx` | **`@server=fcitx`** — unchanged |
| `org.freedesktop.IBus` on the bus | present | **present** — unchanged |
| `/virtualkeyboard` interface | published | **published** — unchanged |
| Wayland input-method seat | **held by fcitx5** | **free — our watcher took it** |

And the watcher did not merely bind: it immediately emitted **real focus
events**, `focus 0` then `focus 1`, off a live compositor. That is the
hand-rolled protocol working end to end — registry, bind, `get_input_method`,
and `activate`/`done` decoded correctly — not just a successful handshake.

### What this means

Auto-show is **cheap**. The cost is precisely: fcitx5 no longer serves
**Wayland-native** clients. XWayland clients keep it through XIM, and the IBus
path is untouched. For a Deck running a Latin-script layout that cost is close
to zero; for a user who needs CJK in Wayland-native applications it is real, so
it should be a setting rather than a hard-coded default.

### Method note, worth keeping

The whole experiment is `pkill fcitx5` and relaunch with one more addon in
`--disable`, then read three things. It is reversible in one command and took
under a minute. ⚠️ **fcitx5 needs several seconds after start to reacquire the
Wayland seat** — a check run ~1 s after relaunch showed the seat still free and
looked like a failed restore. Wait and re-check before concluding anything about
fcitx5's state.

**Next increment, now unblocked:** ship `waylandim` disabled (a documented
setting, not a silent default), spawn the watcher from the mapper, and show the
overlay on `focus 1`. squeekboard's `SetVisible` fallback is unaffected either
way — it never needed the seat.
