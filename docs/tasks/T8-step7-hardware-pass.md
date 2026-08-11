# T8 step 7 — the hardware pass that retires squeekboard

**Written session 18, 2026-08-10. Not yet run.**
**Needs: the Deck, and the operator in front of it.**

Everything in T8 is green on a dev machine, and the layer-shell overlay is
proven on Hyprland *there* — a real layer surface that never takes focus, driven
end to end from a virtual pad. **The Deck has never run any of it.** T8's own
gate says retire squeekboard "only once step 5 is proven on hardware", and this
is that proof.

## Why this is low risk, and where the risk actually is

`stage-input-mapper` now installs the unit with `--osk-backend=layer`. If our
overlay fails for any reason, the mapper **falls back to squeekboard
automatically** and says so in the journal, so the worst case is the behaviour
the Deck has today. That fallback is tested (`test/osk-tty-e2e.py`).

The real risk is different and worth naming: **`lizard_mode` is currently `N` on
that Deck and persists nowhere (§5.21)**, so the mapper is the only input path.
Anything that stops the mapper starting leaves a handheld with no pointer and no
keys, recoverable only over `ssh steamdeck`. Keep the SSH session open
throughout — that is the recovery path, and it has been the recovery path twice
already.

## Before touching anything

```bash
ssh steamdeck 'systemctl --user is-active deck-input-mapper.service; \
  cat /sys/module/hid_steam/parameters/lizard_mode; pgrep -c squeekboard'
```

Take a snapshot (this would be #8) before the first write, per the pattern every
prior Deck session used.

## The pass

1. **Sync and install.** `tools/deck-sync.sh`, then
   `./src/deck-session.sh stage-input-mapper` on the Deck. It now installs
   **three** modules into `/usr/local/lib/deck-osk/` and verifies them by
   running them — the stage fails loudly rather than leaving a half-install.
2. **Restart the unit**, then confirm the new ExecStart took:
   `systemctl --user cat deck-input-mapper.service | grep ExecStart`.
3. **Type with no keyboard attached.** Focus a text field, press **STEAM+X**,
   and check on the screen:
   - the overlay appears anchored to the bottom, split into two halves
   - the **left trackpad moves the left cursor and only the left cursor**, the
     right pad the right — the claim T8 exists for
   - each trigger types the key under **its own** cursor
   - shift capitalises, and the shift key shows `Shift` then `LOCK`
   - the text field **keeps focus** — characters land in it, not nowhere
   - STEAM+X again dismisses it
4. **Type a real Wi-Fi passphrase** — mixed case, a digit, a symbol — which is
   T8's second done-criterion and the screen this project exists for.
5. **Check the fallback did NOT fire**, because if it did, everything above was
   squeekboard: `journalctl --user -u deck-input-mapper -b | grep -i "falling back"`
   must print nothing.

## What would make this a failure rather than a defect

- The overlay comes up as an ordinary **focusable window** rather than an
  overlay → the `LD_PRELOAD` re-exec did not work on that system. Check
  `hyprctl layers | grep deck-osk`. This exact failure happened on the dev
  machine and is invisible except by looking.
- Typing goes nowhere → the text field lost focus, which would mean
  `KeyboardMode.NONE` or the empty input region did not take effect.

Either is a design-level finding, not a tweak. Record it in
`docs/findings/` and stop rather than patching around it.

## Rollback

One line: `MAPPER_OSK_BACKEND=dbus` in `src/deck-session.sh`, re-run
`stage-input-mapper`, restart the unit. squeekboard is still installed and its
two GSettings are still in place, so nothing else has to be undone.

## After it passes

- Update §2.6's Desktop Mode row: **our OSK**, with squeekboard as the automatic
  fallback rather than the primary.
- Close T8 step 7 in `docs/tasks/T8-onscreen-keyboard.md` and P2.4b in
  `docs/ROADMAP.md`.
- ⚠️ **Do not also delete squeekboard or its GSettings.** They are the fallback,
  and T5 should carry them into the image for the same reason.

## The known regression, to decide separately

squeekboard **auto-shows on text focus** (§5.20). Ours is **summon-only**.
Valve's own keyboard is summon-only too (R-35b), so this matches stock SteamOS —
but it is a step back from what the Deck does today. Ours could learn
focus-triggered show by binding `zwp_input_method_v2` the way squeekboard does.
That is new work; decide it after seeing the summon-only version in use.
