# P20 — R-53: the Steam-in-background option, closed by measurement

> **2026-08-11, session 20.** The operator asked whether the "keep Steam resident
> in Desktop Mode to reuse Steam's keyboard" option could be put to bed properly,
> suggesting a QEMU rig. It did not need one. The whole question reduced to a
> single unmeasured link, and that link is testable on the dev machine in twenty
> minutes with no Steam, no VM and no controller.

## Why this needed doing at all

R-42 (session 17) concluded Steam cannot drive an Omarchy desktop, and the
conclusion has held. But R-42 was explicit that its *mechanism* was not measured
(`docs/findings/P17-input-and-osk.md:566-570`):

> **Honest limit:** `libXtst` being mapped proves Steam *links* XTEST, not that
> the desktop layout uses it exclusively. The behaviour is measured; the
> mechanism is a strong inference.

Two summaries then restated XTEST **flatly**, dropping that caveat
(`docs/START-HERE.md`, `docs/PROGRESS.md` §2.6). So the project was carrying an
inference as though it were a fact — which is the failure mode this repo has been
bitten by repeatedly.

**And it mattered, because the option is not absurd: stock SteamOS does exactly
this.** Steam resident in Desktop Mode, trackpads as mouse, STEAM+X for the
keyboard. So "it cannot work" needed a reason, not just a result.

## The reduction

On SteamOS, Steam owning the controller is **not a failure mode — it is the
mechanism**: Steam takes the pad and *synthesizes* mouse and keyboard from it.
So R-41's "a resident Steam takes the controller" only kills the option **if the
synthesized input cannot reach a Wayland desktop.**

Everything therefore collapses onto one question: **can XTEST drive a Wayland
compositor?** That is generic X11 — no Steam required to answer it.

## Method

Dev machine, Hyprland + Xwayland (the same shape as the Deck). XTEST driven
directly through `ctypes` against `libXtst.so.6` — the same facility Steam links.
Scripts: `xtest-pointer.py`, `xtest-keyboard.py` (session scratch).

**The oracle is what a program actually received**, never a screenshot: each case
runs a terminal whose only job is `cat > FILE`, and the file is read back.

## Results

### Pointer

| | |
|---|---|
| XTEST extension present | ✅ yes, version 2.2 |
| Compositor cursor before | `(637, 672)` |
| `XTestFakeMotionEvent` → | `(400, 400)` |
| Compositor cursor after | **`(637, 672)` — unmoved** |

The call was accepted without error and went nowhere.

### Keyboard, with a positive control

| Client | `hyprctl` says | Received `hello` |
|---|---|---|
| Wayland-native alacritty | `xwayland=False` | ❌ **nothing** |
| XWayland alacritty | `xwayland=True` | ✅ **`'hello\n'`** |

## 🐞 The first run of this test was WRONG, and said so

Both cases initially read back `''`, which looks exactly like "XTEST reaches
nothing" — a *stronger* result, and a false one. Two faults:

1. **The terminal line discipline is canonical**, so `cat` receives nothing until
   a newline is submitted. The test typed `hello` with no Return, so the oracle
   never had a chance to see anything.
2. The XWayland case was never *verified* to be XWayland.

**The control caught it.** Because the script demanded that the positive control
pass before drawing any conclusion, it reported *"THE CONTROL FAILED — this run
proves nothing"* instead of the confident, wrong answer. Both faults were fixed
(send Return; assert `xwayland=True` from `hyprctl -j activewindow`) and the
result changed.

⚠️ **A test with no positive control would have produced a wrong finding here,
and it would have agreed with what we already believed** — which is the hardest
kind of error to catch.

## Verdict

**R-42's mechanism is now MEASURED, not inferred.** XTEST reaches X11 clients
under XWayland; it reaches **neither Wayland-native clients nor the compositor's
pointer**. Combined with R-42's measured device table — Steam creates **no**
virtual keyboard or mouse, only `Microsoft X-Box 360 pad 0` — Steam's desktop
input has **no path** to an Omarchy desktop.

**The Steam-in-background option is closed**, and closed for a stated reason:
**an architecture mismatch, not a tuning problem.** SteamOS's Desktop Mode is an
X11 desktop where XTEST works. Omarchy is Hyprland. That is also why no Steam
setting helped — there was no setting to find.

## What this does NOT prove

- It does not prove Steam uses *only* XTEST. It bounds the alternatives: Steam
  reaches the desktop through neither uinput (measured, R-42) nor XTEST
  (measured, here). The remaining path would be a Wayland virtual-keyboard
  protocol, which Steam does not implement.
- ⚠️ **R-41's third hypothesis remains untested** — that Steam needs the full
  SteamOS integration packages (`jupiter-hw-support` et al., skipped by operator
  decision, §5.15). The X11 story predicts they would not help, since they do not
  turn Wayland into X11, but nobody has run it. ~1h if certainty is ever wanted.
- Nothing here concerns **Gaming Mode**, where Valve's session brings its own
  keyboard and reads the controller directly. That is untouched and works.
