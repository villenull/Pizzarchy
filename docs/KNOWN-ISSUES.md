# Known issues

Bugs the operator hit on a real install and chose to ship with. Recorded here
so they live somewhere other than a chat log. Newest release first.

Nothing here blocks installing or using the Deck. If something *does*, it
belongs in `docs/PROGRESS.md` and on the roadmap, not in this file.

---

## 2026.08.17 (P39)

Found by the operator on a full install from the released ISO, 2026-08-17.
All three were known-and-accepted at release time.

### 1. The Ventoy splash screen is rotated

**Impact:** cosmetic, and it happens before our code runs at all.

**Cause:** Ventoy's own boot menu draws in landscape on a panel the firmware
reports as portrait. It is Ventoy's splash, not ours — the Deck's rotation is
fixed by the time our installer draws anything.

**Status:** not ours to fix, and `README.md`'s install step already warns about
it ("the Ventoy splash screen is rotated (no fix)"). Recorded for completeness.

---

### 2. 🔴 A reboot returns to the LAST-USED mode instead of always Gaming Mode

**Impact:** real, and it contradicts a stated product promise. Switch to
Desktop Mode, reboot, and you land back in Desktop Mode. Stock SteamOS — and
this project's own design — says Desktop Mode is a one-shot session and any
reboot returns to Gaming Mode.

**Root cause: the mechanism exists, is written, is tested, and is never
installed.** `src/deck-session.sh` has all of it:

* `deck-boot-default-gaming.service`, which re-asserts Gaming Mode as the
  default session on every boot, ordered before `display-manager.service`;
* `stage_boot_default_gaming()`, which renders it, enables it, and verifies its
  ordering;
* `/etc/deck-session/no-boot-default-gaming`, a one-`touch` escape hatch whose
  directory the stage creates in advance.

But **the stage was in no stage list at all.** It sat in the opt-in group with
`stage-power-button`, `stage-default-session`, `stage-osk-kb-layout` and
`stage-audit-privileges`, reachable only by naming it explicitly. So a normal
install never ran it, and Steam's own Power → "Switch to Desktop" rewrote the
default session with nothing to undo it at the next boot.

⚠️ **Correction, 2026-08-17.** This section first said the fix was to add it to
`INSTALL_STAGES`. That was wrong and it matters: `INSTALL_STAGES` is the
**bare-dev-run** list, while the released ISO installs via **`BAKE_STAGES`**
under `arch-chroot`. Adding it to `INSTALL_STAGES` would have fixed the bug on
a developer's manual run and shipped nothing. `stage-power-button` sets the
precedent — "the installer is not a bare run".

**Why it was opt-in** — and this is the decision to revisit, not an oversight
to sweep away. The stage's own comment states it: with that unit enabled, a
*broken* Gaming Mode is re-asserted on **every** boot, and the operator has one
device. Keeping it opt-in was deliberate while Gaming Mode was still unproven.

**What to decide:** Gaming Mode has now installed and booted correctly across
several releases, so the risk that argument was protecting against is much
smaller than it was. Moving `stage-boot-default-gaming` into `INSTALL_STAGES`
is a one-line change plus its ordering rationale, and the escape hatch already
exists for the case it was guarding.

⚠️ Before making that change, confirm the escape hatch is reachable **without a
keyboard**. It is a `touch` at a TTY today. On a controller-only device, an
escape hatch that needs a keyboard is not an escape hatch — and a boot loop
into a broken Gaming Mode is exactly the unrecoverable class of failure this
project treats as the worst kind.

---

### 3. Gaming Mode shows a black screen for ~10 s after the Omarchy logo

**Impact:** cosmetic but alarming — the panel is fully black with no spinner
and no text, so a first-time user cannot tell a slow boot from a hung one.

**Cause:** not diagnosed. The gap sits between the Omarchy boot logo and
gamescope putting up its first frame. Candidates, none confirmed: Steam's
first-run work, gamescope's startup, or the session switch itself.

**Related and already measured:** the installer's own reboot warning was
re-measured at 2026-08-16 and says the screen is black for part of a ~1 minute
reboot, so the *existence* of a black stretch is known and disclosed. What is
new here is that it also happens on an ordinary boot into Gaming Mode, ~10 s,
after the install is long finished.

**Cheapest next step:** it is a boot-timing question, so
`systemd-analyze critical-chain` and `journalctl -b` across that window should
name the unit that owns the gap before anyone guesses at it. If the time turns
out to be genuinely required, the fix is a splash rather than a speed-up.
