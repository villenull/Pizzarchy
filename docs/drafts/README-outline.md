# README outline — draft, not the README

Written 2026-08-16 for P35. **Nothing here ships until the first-boot fixes
land** (P34) and an ISO is rebuilt with the font revert (§5.40).

The current `README.md` is a *dev repo* doc: layout table, "For Claude Code",
prior art. All of that is useful and none of it belongs above the fold for
someone deciding whether to flash a USB stick. **The move is not to delete it —
it is to put a product in front of it and push the workshop below.**

---

## Structure

```
  1  Title + one-line description
  2  ► HERO SCREENSHOT
  3  Status + hardware support        ← honesty lives high, not in a footnote
  4  What you actually get            ← the pitch, 3 bullets
  5  ► GALLERY: desktop + gaming mode
  6  Install                          ← download, flash, boot, the flow
  7  ► GALLERY: the install itself
  8  Controls                         ← the chord reference
  9  What works / what doesn't        ← the honest table
 10  Building it yourself
 11  Reporting a bug (esp. LCD)
 12  How it works                     ← brief; links to docs/
 13  Prior art · Recovery · License
```

### 1. Title + one line

Repo description is already right: *"Steam Deck-native, fully offline,
controller-only installer for Omarchy Quattro."* Lead with what it does for the
reader, not what it is: **Omarchy on your Steam Deck, installed with the
controller. Gaming Mode stays exactly as it was.**

### 3. Status + hardware support — ABOVE the fold

Non-negotiable, per `CLAUDE.md` and the operator's release decision:

> **Verified on the OLED Steam Deck only.** LCD is untested and not claimed.
> If you have an LCD Deck, [tell us what happens](#reporting-a-bug) — that is
> how it gets supported.

Also state plainly: **this wipes the device.** It is not dual-boot. Link
`docs/RECOVERY.md` for returning to stock SteamOS, and **do not publish the
release until that document is real** (currently promised in `PROGRESS.md` §5.8).

### 4. What you actually get — three bullets, no more

* **Gaming Mode is untouched.** Boots straight to Steam, same as stock.
* **Desktop Mode is a full Omarchy/Hyprland desktop**, reachable from the Steam
  menu — not a keybind you have to know.
* **The whole install is controller-only.** Including typing the Wi-Fi password.

### 6. Install

Numbered, short, each step one line. Ventoy is how it is actually tested — say
so, and note the known cosmetic wart rather than letting it surprise anyone:

> Ventoy's own boot menu draws rotated 90° on the Deck's panel. That is Ventoy,
> not us, and it clears once our ISO boots.

### 8. Controls

A table, because it is the thing people will come back for:

| | |
|---|---|
| **STEAM + X** | on-screen keyboard |
| **STEAM + Y** | close the focused window |
| A / B | confirm / back |
| L2 / R2 | left / right trackpad click |

### 9. What works / what doesn't

**Keep this table honest and specific.** It is the most valuable thing on the
page and the cheapest to get wrong. Verified on hardware 2026-08-16: Neptune
kernel boots, Gaming Mode, touch, STEAM+Y, suspend/wake, brightness, audio,
Wi-Fi, Switch to Desktop. **Known rough edges get their own row, not silence** —
first-boot wait, Steam's own setup wizard, OSK flicker if still present.

### 11. Reporting a bug

Make LCD reports specifically easy: what to include, and the one command that
dumps the install record (`/var/log/omarchy-deck-install.json`) — it already
carries a per-stage status and is exactly what a maintainer needs.

---

## Screenshot manifest

**Do not photograph a screen where a real capture is possible.** Glare, moiré
and keystone make a project look amateur. Three sources, each right for a
different shot:

### A. QEMU screendump — the install screens (CLEAN PNG, no camera)

`test/vm/vm-installer-screens-test.sh` already runs the real ISO under QEMU with
a **QMP socket** (`-qmp unix:${qmp_sock}`, and a `qmp()` helper). QMP's
`screendump` writes a PPM of the guest display — so every installer screen can be
captured pixel-exact, reproducibly, from the harness that already walks the
flow. Convert PPM → PNG with ImageMagick.

⚠️ **The one thing QEMU cannot show is the on-screen keyboard.** There is no
gamepad, so the mapper never binds and the OSK never draws — the whole reason
the S0 assertion behaves differently there (§5.33a). **OSK screens must come off
the real Deck.**

Shots: greeter · Wi-Fi network list · keyboard layout · disk confirm ("Yes,
erase and install") · install progress · summary.

### B. Real Deck, real screenshot tools — desktop and Gaming Mode

* **Desktop Mode:** `grim` under Hyprland → clean PNG at native resolution.
* **Gaming Mode:** Steam's own screenshot key → clean PNG.

Shots: Omarchy desktop (hero candidate) · Steam menu showing **Switch to
Desktop** · Gaming Mode library.

### C. Camera — only where the device itself is the subject

Exactly two, and both deliberately staged (good light, no reflections, screen
brightness up, shoot slightly off-axis to kill moiré):

* **Hero:** the Deck in hand running the Omarchy desktop.
* **The OSK on the panel** — because it cannot be captured any other way, and
  because "you can type a Wi-Fi password with no keyboard" is the single most
  surprising claim on the page. A photo *proves* it in a way a clean render
  does not.

### Storage

`docs/images/` in-repo, referenced by relative path. **Do not hotlink** to
anything outside the repo — the README must render years from now.

---

## What moves down or out

* **"For Claude Code"** — this section is genuinely useful and genuinely
  confusing above the fold for a user. Move to `CONTRIBUTING.md` or the bottom.
* **Layout table** — keep, but below "How it works".
* **"Where this came from"** — strong material; compress to a short paragraph
  and link `docs/PLAN.md` §8 rather than listing every failure.
* **Prior art** — keep. It is short, honest, and answers "why not X?" before it
  is asked.

⚠️ **Do not delete `docs/`.** P35's own note: `CLAUDE.md` points every session at
`PROGRESS.md` §7, and that record repeatedly prevented re-deriving wrong
answers. The README's job is to stop a *user* landing in the lab notebook — not
to burn the notebook.

## Blockers on the README specifically

1. `RECOVERY.md` must be real before the README links it as a safety net.
2. The "what works" table cannot be written until P34 lands — half its rows are
   in flight.
3. No screenshots exist yet; the QEMU screendump path is **designed here, not
   built** (it needs a `screendump` call added to the harness).
4. The install screens in any capture must come from an ISO built **after** the
   font revert. Every image of the current build shows prompts pushed
   off-screen.
