# P16 — Scoping: a Deck-specific USB flasher vs. an enablement layer

**Session 16, 2026-08-10. Operator question, answered, and the outcome is
`docs/ROADMAP.md` phase 4.**

Recorded because the flasher idea is intuitive and will be proposed again. This
is why it was reframed rather than adopted, with the measurements behind it.

## The question

> Turn this into a distro-agnostic, Steam Deck–specific USB flashing app — like
> Balena Etcher: open it, pick a distro from a list, flash a Deck-ready ISO.
> Ideally our script takes an ISO and makes it run on the Deck the way we are
> doing now with Omarchy.

## 1. The load-bearing premise does not hold

> *"our script takes an ISO and can apply it to run on the steam deck"*

**There is no generic transform, because the script *is* the distro-specific
part.** Measured against this repo:

| | code lines | touching distro-specific machinery |
|---|---|---|
| `src/omarchy-deck-kernel.sh` | 769 | **26%** |
| `src/deck-session.sh` | 852 | **13%** |
| `src/deck-input-mapper.py` | 204 | **0%** |

⚠️ **Those percentages understate the lock-in.** It is not "74% is portable" —
the portable remainder is *scaffolding around a distro-specific core*: `pacman`,
`jupiter-staging`/`holo-staging`, `limine`, `mkinitcpio`, `linux-neptune-611`,
`sddm`, `uwsm`, `wayland-session@hyprland.desktop.target`. On a Fedora-based
target that becomes `rpm-ostree`, GRUB, dracut, a kernel that exists as no
package, and different session wiring. You would not port that core. You would
rewrite it.

**What genuinely travels:** the five `render_*` helper bodies
(`steamos-priv-write`, `steamos-set-timezone`, the `steamos-update` stub,
Steam's shim, the sddm restart helper — all plain bash), the session-switch
*policy*, `deck-input-mapper.py`, `test/hw-probe.sh`, the soak script,
`sudoers_line_is_blanket`, `docs/RECOVERY.md` — and **`docs/PROGRESS.md` §7's 38
facts**, which are the single biggest accelerator and are not code at all.

## 2. Two products, wildly asymmetric cost

| | Cost | Notes |
|---|---|---|
| **The flasher** | Weeks | Electron/Tauri, device enumeration, raw write + verify. The fiddly parts (elevated raw-device access per OS, not writing the wrong disk) are solved. Etcher, Rufus and **Ventoy — which this project already uses** — got there first |
| **Per-distro Deck enablement** | **16 sessions and counting, for ONE distro** | Each additional distro is a large fraction again, then *keeps* costing: Valve moves `jupiter-staging`, the distro moves, and you own the intersection forever |

The flasher is the easy ~10%. The value and the cost both live in the other 90%,
and that 90% is **multiplicative, not incremental** — and a maintenance
treadmill rather than a build.

## 3. Three things that get materially worse at distribution scale

**Redistribution.** `docs/findings/P16-redistribution-and-trademark.md` found
`steamdeck-dsp` is `Proprietary` with **no licence text**, and the escape was
"fetch, don't bundle". **Hosting images destroys that escape** — distributing an
ISO redistributes everything inside it. The question goes from deferred to
blocking, once per distro.

**Support surface.** Today a failure is your own Deck, over SSH, with snapshots
and a `reset-failed` away. Ship a flasher and a failure is a stranger's bricked
handheld with no logs. `docs/RECOVERY.md` stops being courtesy and becomes
load-bearing — and it is still **unexercised** (P3.1).

**Prior art is strong and active.**
[Bazzite](https://docs.bazzite.gg/Handheld_and_HTPC_edition/Steam_Gaming_Mode/)
ships `bazzite-deck` / `bazzite-deck-gnome` images purpose-built for the Deck
that boot straight into Steam Gaming Mode, tracking Fedora 44; ChimeraOS covers
the console case. "Deck-ready distro image" is largely **solved for
gaming-focused distros**, by teams with more capacity than one person.

## 4. What is actually differentiated

Not the flashing, and not Deck-ready images generically. It is the
**controller-only install experience** — no keyboard at any point, *including
Wi-Fi passphrase entry*. Bazzite still hands you a conventional installer. That
is the gap §5.9 re-scoped and T4 exists to fill, and nobody else is filling it.

## 5. Outcome

**Adopted, reframed:** `docs/ROADMAP.md` **phase 4**, spec in
`docs/tasks/T7-enablement-layer.md` — a **Deck enablement layer** that distro
maintainers (or we) apply, rather than a flasher plus a catalog.

**Explicitly out of scope: hosting or distributing distro images.** The layer is
code. See §3.

**Sequencing: finish Omarchy first.** Phases 1–3 ship one distro end to end;
only then is there a finished example to abstract from. Every estimate above
rests on that number, and right now it is a guess.

⚠️ **If the flasher is revisited, the thing to re-test is §3's prior art, not
§1's premise.** §1 is a property of how Linux distributions differ and will not
change. §3 is a market position that might.
