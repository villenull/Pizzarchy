# Pizzarchy: Omarchy on your Steam Deck

**Hot and ready in about twenty minutes — one bootable USB, no keyboard, and
Gaming Mode stays exactly as it was.**

One bootable USB installs a full Arch + [Omarchy](https://omarchy.org) system on
a Steam Deck — hardware-optimized, driven entirely by the Deck's buttons and
trackpads. No keyboard. No terminal. Not once.

Afterwards the Deck behaves like it always did: hold the power button, land in
Gaming Mode, play. The difference is **Desktop Mode**, which now drops you into a
real Omarchy/Hyprland desktop — with a button to come straight back.

> _**[ IMAGE — hero: the Deck in hand, running the Omarchy desktop ]**_
> `docs/images/hero-desktop.jpg`

---

## What you get

**Gaming Mode, untouched.** Same gamescope session, same library, same
controller behaviour. Nothing about playing games changes.

**A real desktop, one button away.** Not a stripped shell — full Omarchy:
Hyprland, Waybar, the whole environment, tuned for the Deck's panel and
gamepad.

**An install you can do on the couch.** Every screen is A / B / D-pad /
trackpads, including typing your Wi-Fi password on an on-screen keyboard drawn
right on the console.

**Offline by default.** The ISO carries a complete package mirror, so the
install itself never needs a network. Wi-Fi is there to fetch Steam and save you
doing it afterwards.

> _**[ IMAGE — Omarchy desktop, full screenshot ]**_ `docs/images/desktop.png`
>
> _**[ IMAGE — Steam menu showing "Switch to Desktop" ]**_ `docs/images/switch-to-desktop.png`
>
> _**[ IMAGE — Gaming Mode library, to show it is stock ]**_ `docs/images/gaming-mode.png`

---

## Before you start

**Verified on the OLED Steam Deck.** LCD Decks are untested and not claimed. If
you have one and try this, [tell us what happens](#reporting-a-bug) — that is how
it gets supported.

⚠️ **This wipes the device.** It is not dual-boot. Back up anything you care
about, including saves that are not on Steam Cloud. Returning to stock SteamOS
means Valve's official recovery image — see [Recovery](#recovery).

---

## Install

1. **Get the image.**

   > _**[ LINK — Internet Archive download + sha256 ]**_

2. **Write it to a USB stick.** [Ventoy](https://www.ventoy.net) is the tested
   path — copy the `.iso` onto the Ventoy partition and you are done.

3. **Boot it.** Hold **Volume Down + Power** until the boot menu appears, then
   pick the USB stick.

4. **Follow the screens.** Language, Wi-Fi, account, disk. Then it installs.

> Ventoy's own menu draws rotated 90° on the Deck's panel. That is Ventoy, not
> this project, and it clears the moment our ISO starts.

> _**[ IMAGE — greeter / "press A to begin" ]**_ `docs/images/install-01-greeter.png`
>
> _**[ IMAGE — Wi-Fi network list ]**_ `docs/images/install-02-wifi.png`
>
> _**[ IMAGE — the on-screen keyboard, photographed on the panel ]**_ `docs/images/install-03-osk.jpg`
>
> _**[ IMAGE — disk confirmation, "Yes, erase and install" ]**_ `docs/images/install-04-confirm.png`
>
> _**[ IMAGE — install progress ]**_ `docs/images/install-05-progress.png`

---

## Controls

| | |
|---|---|
| **STEAM + X** | on-screen keyboard |
| **STEAM + Y** | close the focused window |
| **A** / **B** | confirm / back |
| **L2** / **R2** | left / right trackpad click |
| **STEAM** (tap) | apps menu |

---

## What's supported

| | |
|---|---|
| Kernel | Valve's Neptune kernel, the same one SteamOS runs |
| Boot | Limine, with a Gaming Mode default |
| Gaming Mode | gamescope, stock behaviour, Steam preinstalled |
| Desktop Mode | Omarchy / Hyprland, reachable from the Steam menu |
| Touchscreen | works in Desktop Mode |
| Suspend / wake | power button |
| Display | brightness control, correct panel rotation |
| Audio | speakers and headphones, Valve's DSP |
| Wi-Fi | in the installer and on the installed system |
| Controller | full navigation, plus an on-screen keyboard for text |

---

## Building it yourself

Needs Docker and about 40 minutes. The build is fully scripted.

```bash
git clone --recursive https://github.com/villenull/Pizzarchy
cd Pizzarchy
iso/bin/build
```

The finished `.iso` lands in the build's `release/` directory with its sha256.

The build refuses to proceed if any of its nine guards fail. Those check things
like *"the on-screen keyboard is actually executable in the live image"* and
*"no package list is carried without something that installs it"* — both real
bugs that shipped once, and are not allowed to ship again.

---

## Reporting a bug

Open an issue. The most useful thing you can attach is the install record, which
already carries a per-step status:

```bash
cat /var/log/omarchy-deck-install.json
```

**If you have an LCD Deck**, say so explicitly and include that file plus
`uname -r`. LCD support is not claimed today, and real reports are what would
change that.

---

## Recovery

This install replaces SteamOS. To go back, use **Valve's official Steam Deck
Recovery Image** — see `docs/RECOVERY.md` for the exact steps, including
restoring the stock partition layout.

---

## How it works

A fork of Omarchy's own installer with a Steam Deck overlay: a controller-driven
form layer over the install screens, an input mapper that turns the gamepad into
keyboard events (including an on-screen keyboard drawn on the console), Valve's
Neptune kernel and audio DSP, and a session layer that preserves gamescope while
adding a route to the Omarchy desktop.

| Path | What lives there |
|---|---|
| `src/` | Shipped to the Deck — kernel/boot automation, session layer, input mapper |
| `iso/` | The ISO build: upstream submodule, our overlay, the build entrypoint |
| `tools/` | Dev-machine tooling, never shipped |
| `test/unit/` | Fast suites, no VM needed — run in CI on every push |
| `test/vm/` | QEMU suites: install harness, kernel/hook/idempotency, gamepad |
| `docs/` | Design docs, research findings, and the full engineering record |

`docs/PROGRESS.md` is the working notebook. It records every measurement — and
every wrong diagnosis that a later measurement corrected. It is deliberately
public.

---

## Prior art

`28allday/deckshift`, `omarchy-deck-iso` and `omasteam` are the closest
neighbours, and **none of them target Steam Deck hardware** — they run
Deck-*style* gaming mode on generic PCs. Bazzite and ChimeraOS solve Deck
hardware, but not Omarchy.

---

## Contributing

`docs/START-HERE.md` is the entry point, and `docs/ROADMAP.md` has the plan. If
you are using Claude Code, the whole opening prompt is:

```
Read docs/START-HERE.md and begin.
```

---

## License and affiliation

**An independent project. Not affiliated with, endorsed by, or supported by
Basecamp or Valve.** "Omarchy" and "Steam Deck" are used descriptively, to say
what this installs and what it runs on.

MIT — see [LICENSE](LICENSE). Omarchy, SteamOS, gamescope, and Valve's kernel
and firmware packages are covered by their own licenses.
