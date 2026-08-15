# P3.6 — Deck stable-update runbook: bring the Deck to Omarchy 4.0.0 stable

> **Operator-present. Read fully before touching the Deck.** Prepared
> 2026-08-15 (session 27, autonomous) from the measured stable pin
> (`docs/findings/T9-stable-pin.md`) and the full delta classification
> (`docs/findings/T9-stable-delta-classification.md`). Every command is meant to
> be run as written; fill the blanks (snapshot number) in place.
>
> **Model for the operator's session: Opus** — this is boot-chain + the one
> physical device, and its job is noticing what silently changed (`CLAUDE.md`).

## What this does, in one line

The Deck currently runs `omarchy-dev 4.0.0.r1617.g6d7826d-1` on the **edge**
channel. This moves it to **`omarchy 4.0.0-1` on the stable channel** in place,
re-runs every `deck-session.sh` stage against the moved substrate, and verifies
nothing load-bearing reverted.

## Why in-place update, not reinstall

Phase 3's P3.1/P3.2 already buy the clean-install proof from a factory reset, so
burning a Deck rebuild here spends the same hours twice. In-place keeps snapshots
and the SSH loop intact. **If you reinstall instead**, say plainly in
`docs/PROGRESS.md` that phase 3's install is no longer the first from this ISO.

---

## 0. Before you touch the Deck

### 0.1 The floor — what always gets you out
- **SSH unreachable and screen unusable:** hold **Power ~10 s**. A reboot leaves
  `lizard_mode=Y`, so the firmware supplies pointer + arrows again.
- **A bad update:** `snapper` snapshot #? taken in 0.3 below is the rollback. The
  stable ISO's Limine carries the Snapshots submenu.
- Valve recovery image → stock SteamOS remains the ultimate floor (acceptable).

### 0.2 Pre-flight, on the dev machine
```bash
cd ~/Pizzarchy
git rev-list --left-right --count origin/main...main   # expect 0  0
ssh steamdeck 'omarchy-version; omarchy-version-channel; uname -r'
```
Record what it prints — that is the *before* state for §7's write-up. Expect
`4.0.0.r1617.g6d7826d-1`, an `edge`-flavoured channel, and the Neptune kernel.

### 0.3 Snapshot first, always
```bash
ssh steamdeck 'sudo snapper -c root create -d "pre-P3.6: edge->stable, omarchy-dev->omarchy 4.0.0"'
ssh steamdeck 'sudo snapper -c root list | tail -5'
```
Write the new snapshot number here: **#____**. Confirm it appears before going on.

---

## 1. ⚠️ The package swap is the risky part — understand it before running

The edge→stable move is **not** a plain update. `omarchy-dev` declares
`provides=('omarchy')` **and** `conflicts=('omarchy')` (measured in
omarchy-pkgs@bb66b9d). Installing stable's `omarchy` therefore forces pacman to
**remove `omarchy-dev`** in the same transaction. That is a package removal and a
conflict prompt — **do it interactively, never fire-and-forget over a plain
pipe.**

**Always use `ssh -t`** for §2–§3 so every sudo/pacman prompt is answerable. A
headless `omarchy-update` can hang or abort on:
- the `omarchy-dev` → `omarchy` conflict prompt;
- five stable migrations that call `sudo` **without** NOPASSWD (bluetooth
  `1786380259`, limine rebuilds `1786482992` / `1786605598`, wpa_supplicant
  unmask `1786567036`, copy-url repair `1786643346`). Detail:
  `docs/findings/T9-stable-delta-classification.md` (§"SSH-abort").

Prime sudo right before the update so the ~15-min timestamp covers the run:
```bash
ssh -t steamdeck 'sudo -v && echo primed'
```

---

## 2. Set the channel, update, and read what the migrations did

```bash
# Interactive shell on the Deck for the whole update:
ssh -t steamdeck
```
Then, on the Deck:
```bash
sudo -v                                  # re-prime if §1 was a while ago
omarchy-version-channel                  # confirm current (edge-ish)
omarchy-channel-set stable               # move the channel to stable
omarchy-version-channel                  # confirm it now reads stable
omarchy-update                           # answer the omarchy-dev->omarchy conflict: YES
```

⚠️ **The stable channel is a fixed target — this is the good news.** Unlike
`edge` (which moves several times a day), `stable`'s HEAD is the **4.0.0
release**, so `omarchy-update` lands on `omarchy 4.0.0-1`, not a moving snapshot.
Confirm you actually landed there:
```bash
omarchy-version                          # expect 4.0.0 (NOT 4.0.0.rN.gSHA)
pacman -Q omarchy omarchy-settings       # expect omarchy 4.0.0-1, omarchy-settings 4.0.0-1
pacman -Q omarchy-dev 2>&1               # expect "was not found" — it was replaced
```

Then read what ran as root (the migrations mutate machine state):
```bash
ls -1 /var/lib/omarchy/migrations/ | tail -20
cat /proc/cmdline                        # for the limine check in §5
```

---

## 3. Re-run every deck-session.sh stage — the idempotence test

This is the first real test of the idempotence claim against a moved substrate
(`CLAUDE.md`). Deploy our current tree and re-run the stages:
```bash
# dev machine:
cd ~/Pizzarchy && ./tools/deck-sync.sh deck-session.sh src
# then on the Deck (ssh -t):
sudo -v
./src/deck-session.sh            # full run, or per-stage if you prefer
./src/deck-session.sh stage-audit-privileges   # §5.17's gate — must pass
```
Any stage that now **fails** is a genuine finding — capture it, don't paper over
it. Expected: all stages idempotent (they were designed for this SSH loop).

---

## 4. Verify the load-bearing settings — the RIGHT way

Do **not** trust `gsettings get` (returns the user value; passes while the site
default is missing). Use `dconf read -d` and read `shell.json` directly.
```bash
# OSK site defaults (§5.20):
dconf read -d /org/gnome/desktop/a11y/applications/screen-keyboard-enabled
dconf read -d /org/gnome/desktop/input-sources/sources
# idle policy — screensaver 150 s, lock 86400 s (NOT 0; lock:0 locks instantly):
grep -A3 '"idle"' ~/.config/omarchy/shell.json 2>/dev/null || \
  cat /usr/share/omarchy/default/shell/shell.json | grep -A3 idle
```
Expect the OSK defaults present and `idle.lock` still **86400** (our neutering).
Delta note: stable's `shell.json` schema is unchanged, but `shell.qml
putBarWidget` can rewrite `shell.json` (config.bar only) on update — **re-read
`idle` after the update** to confirm it wasn't disturbed.

---

## 5. Boot + power settings that a migration could have touched

```bash
# lizard_mode resets to Y on reboot by design; the mapper should drive it to N:
cat /sys/module/hid_steam/parameters/lizard_mode
# backlight node must stay 0644 — if it is 666, Steam fell back = a helper broke:
ls -l /sys/class/backlight/*/brightness
```

**The limine-cmdline migration (`1786482992`) — confirm it was a no-op.** It runs
`sudo limine-mkinitcpio` only if `/proc/cmdline` is missing a default param.
`omarchy-defaults.conf` is byte-identical stable-vs-our-pin, so on an up-to-date
Deck it should no-op. Confirm:
```bash
grep -o 'fbcon=rotate:1' /proc/cmdline    # our rotation must still be on the line
# if the migration DID fire, confirm the rebuilt UKI still boots rotated (visual)
```

---

## 6. Session-switch soak — ≥5 cycles

§5.18 first appeared on cycle 4, so one cycle is not enough.
```bash
# From the desktop side and back, ≥5 times, watching for the sddm start-limit latch:
ssh steamdeck 'systemctl status sddm --no-pager | grep -i "start-limit\|failed"'
```
Zero `start-limit-hit`. If sddm latches to `failed`, `systemctl reset-failed
sddm` — but that latch is itself a finding.

---

## 7. Hands-on pass — what a script cannot see (the delta's RE-VERIFY rows)

Eyes on the screen, controller in hand:
- **OSK on STEAM+X** — characters land; the layer surface never steals focus.
  ⚠️ delta watch-item: stable's `KeyboardLayout` rewrite now treats our
  `deck-input-mapper-virtual-keyboard` as a *typed* keyboard — confirm no OSK
  desync (inert on today's single-layout Deck, but look).
- **Both trackpad cursors, diagonals included** (session 17's worst bug was
  invisible to single-axis tests).
- **Steam Power → Switch to Desktop, and the way back** — both directions.
- **The Desktop Mode row is still in the Omarchy menu** after the menu became a
  JSONC command palette (delta says the mechanism survives — confirm on screen).
- **Gaming Mode is usable** — R-38's standard, not "the session exists".
- **Bluetooth** — migration `1786380259` toggled `/etc/bluetooth/main.conf`
  AutoEnable + rfkill; re-check the unfinished BT parity row.
- **The stranded-lock guard** — power-button-lock still dismissable (our
  `idle.lock=86400` + sleep-lock mask + `above_lock=2` mitigation; the recovery
  path exists in stable but is neutered — confirm in pixels).

---

## 8. Close out
```bash
ssh steamdeck 'sudo snapper -c root create -d "post-P3.6: on omarchy 4.0.0 stable"'
```
Then update the record (§7 of T9 / P3.6): `docs/PROGRESS.md` pin + a §5.26
outcome, `docs/ROADMAP.md` P3.6 tick, `docs/START-HERE.md` state block. **Do not
write "the Deck is on 4.0.0 stable" unless `omarchy-version` printed `4.0.0` and
`pacman -Q omarchy` succeeded** — that is the silent-inaccuracy failure `CLAUDE.md`
exists to prevent.

## Done when
- [ ] `omarchy-version` = `4.0.0`, `pacman -Q omarchy omarchy-settings` both `4.0.0-1`, `omarchy-dev` gone
- [ ] Every `deck-session.sh` stage re-ran clean; `stage-audit-privileges` passed
- [ ] OSK defaults present via `dconf read -d`; `idle.lock` still 86400
- [ ] `fbcon=rotate:1` still on `/proc/cmdline`; backlight node 0644
- [ ] Switch soaked ≥5 cycles, zero start-limit-hit
- [ ] Hands-on list signed off on screen
- [ ] Snapshot taken before and after
