# FAST-INSTALL — results of the four-variant installer (2026-09-24)

Spec: `docs/tasks/FAST-INSTALL.md`. Baseline it is measured against:
`docs/findings/INSTALL-SPEED.md` (252 s from form confirm to ready-to-reboot, Deck, 2026-09-23).

**Everything below is QEMU/KVM, not the Deck.** The harness emulates the OLED's DMI
(`Valve`/`Galileo`), an NVMe target, and the USB stick as `usb-storage` read-throttled to the
measured 82 MB/s. Not exercised: the physical controller, Wi-Fi radio, panel, gamescope
rendering, audio, and the real form (cidata answers the form; `form-delay-seconds` simulates
how long a human takes). A physical install wipes the Deck and needs the operator.

## Final ISO

| | |
|---|---|
| File | `pizzarchy-omarchy-4.0.4-fast-install-2026-09-24-x86_64.iso` |
| Size / sha256 | 6,874,292,224 B · `8835528647421697f786e4b70ff9af7813c834520d80c9e2bfc56389911f94e1` |
| Source | commit `892f3f5`; later commits change only `test/vm/` harnesses and docs |
| Build | `iso/bin/build`, all guards green; offline mirror ships 485 of 1,291 packages, the root image provides the rest |
| Pins | unchanged: `omacom/omarchy@c668141e9c42` · `omacom/omarchy-iso@7cfb7111a068` · `omacom/omarchy-pkgs@5fe236736607` |

## Measured, final ISO (`test/vm/vm-fast-install-test.sh`, reboot check on)

Clock A is `late_post_confirm_s`: form confirm → ready to reboot. It includes waiting for the
early stage (`early_join_wait_s`) when the form was shorter than the background work.

| pre-installs / Gaming | network | form | early stage | post-confirm (A) | of which waiting for early | late work alone | result |
|---|---|---|---|---|---|---|---|
| no / no | none | 0 s | 30 s | 40 s | 35 s | ~5 s | PASS, reboots to greeter |
| yes / no | none | 90 s | 41 s | **4 s** | 0 s | 4 s | PASS |
| no / yes | user | 90 s | 98 s (Steam client 40 s) | 17 s | 10 s | ~7 s | PASS, autologin → `gamescope-wayland` |
| yes / yes | user | 90 s | 111 s (Steam client 42 s) | 26 s | 20 s | ~6 s | PASS |
| in-place opt-in on the no/no disk | user | — | — | action 50 s, exit 0 | — | — | PASS (`test/vm/vm-enable-gaming-test.sh`) |

Reading it:

* **The 3–8 s target holds for the late work itself (4–7 s) in every variant.** Past that,
  clock A is exactly how much longer the background work took than the human. A 90 s form
  hides all of a no-Gaming install. With Gaming it leaves 10–20 s, because the early stage
  runs 98–111 s in QEMU.
* Against the 252 s baseline, the worst measured case (yes/yes, 90 s form) is 26 s.
* The Gaming early stage is dominated by the online Steam client fetch (40–42 s here, on the
  dev box's link) plus the offline Gaming package transaction. On the Deck the fetch is
  bounded by its Wi-Fi.
* Every run asserts outcomes on the installed disk, not log text: variant packages present or
  absent, Steam client manifest, SDDM autologin or password greeter, the effective greeter
  theme and IM environment, the pre-install marker, and an installed `pacman.conf` with
  `[core]` and no `[offline]`. Then it boots the installed disk to the login prompt.

## The Gaming=No login screen

Verified in QEMU with pointer clicks only: the greeter shows Omarchy's own theme with an
always-visible on-screen keyboard. Clicking keys typed the password, the on-screen Enter
logged in, and SDDM reported `Authentication for user "tester" successful` and started the
session. On the Deck the pointer is the right trackpad with R2 to click, which the firmware
provides at the greeter (lizard mode). **Not yet seen on the panel.**

How it works (see `deck_install_identity.configure_desktop_greeter`):
`InputMethod=qtvirtualkeyboard` alone shows **no keyboard** on SDDM's Wayland greeter, which
logs `input method is not set`. It takes both of:
1. `GreeterEnvironment=QT_IM_MODULE=qtvirtualkeyboard`
2. the `omarchy-deck` theme (shipped by the `omarchy-deck` package), which loads Omarchy's
   `Main.qml` unchanged by path and adds an `InputPanel`.

The installer refuses to select the theme unless every file it loads is on the target.

## Defects found by running it (fixed, each with a regression test that failed before the fix)

| # | Symptom in QEMU | Cause | Fix |
|---|---|---|---|
| 1 | `NameError: select_phases` at the first staged run | import inside `build_phases`, used in `build_staged_phases` | import where used (`configure-deck-phase.patch`); the suite now executes the patched entrypoint for early and late |
| 2 | late stage: "stock kernel still installed" | root image baked stock `linux` beside `linux-omarchy` | bake `linux-omarchy` instead (`deck-packages.patch`) |
| 3 | pre-installs=no: removal tool "not on the target" | `/usr/share/omarchy/bin/*` are absolute symlinks; `is_file()` followed them into the live ISO | call the real `/usr/bin` paths; check presence inside the target root |
| 4 | pre-installs=yes: "target not found: cliamp …" | delta resolved against the target's pacman.conf, which `omarchy-setup-system` had switched to online repos | pass the live offline config with `--config`/`--cachedir` |
| 5 | same, next run: "config file /tmp/… could not be read" | arch-chroot mounts a fresh tmpfs on `/tmp` | stage it in `/var/tmp` |
| 6 | Gaming=Yes: "target not found: lib32-vulkan-radeon" | the offline mirror never read `deck-gaming.packages` | add it to the mirror set (repo-qualified names skipped) |
| 7 | Gaming=Yes: provision-user "Permission denied" on `~/.config` | Steam relocation re-seeded `/etc/skel` as root | re-seeded entries get the home's owner; the pre-install marker too |
| 8 | 25 root-owned symlinks in a Gaming=Yes home | relocation recreated Valve's links as root | retarget keeping the replaced link's owner |
| 9 | installed system's only repo was the USB stick's mirror | upstream's user finalizer copies the live offline `pacman.conf`; in the split flow nothing rewrote it | the late "Finalizing user" phase restores the target's own file |
| 10 | opt-in: "tester is not allowed to execute … as root" | deferred installs skip archinstall's `%wheel` grant | late user creation installs `/etc/sudoers.d/00-omarchy-wheel` (upstream's own line, password required, `visudo`-checked) |
| 11 | opt-in: offline.db missing | = #9 | = #9 |
| 12 | opt-in: died at `stage-steam-desktop-launcher` | package didn't ship `deck-steam-desktop.py` beside `deck-session.sh` | shipped; the suite derives the full payload from the same constants the build scrapes |
| 13 | opt-in: died at `stage-pizza` | package didn't ship the pizza command and art | shipped (`iso/bin/build` step 4b + PKGBUILD) |
| 14 | Gaming=No greeter had no usable keyboard | see the login screen section above | the `omarchy-deck` theme + greeter IM env |
| 15 | CI: steam-staging suite failed on the runner | fixture chowned to a literal uid 1000 (runner is 1001) | `os.getuid()`, same class as PROGRESS §5.49 |

Harness defects fixed along the way: the Steam CDN probe hit a URL that answers 403 by
design; OCR cannot read the installed system's rotated TTYs (the opt-in test logs in over a
serial getty); QEMU's ACPI power button *suspends* a Deck install (T13's
`HandlePowerKey=suspend`), so the harness powers off with `systemctl poweroff`; and a
failed install now dumps the guest's logs to serial instead of idling to the timeout.

## Still unverified

* Anything on the physical Deck. The next step is one clean install per variant on the
  OLED, operator present (it wipes the drive).
* The on-screen greeter keyboard driven by the real trackpad (QEMU used an absolute tablet).
* Gaming=Yes first boot into Steam's UI: QEMU has no Deck GPU, so the reboot check stops at
  the login prompt with autologin configured.
* Wi-Fi during the form (QEMU uses a wired virtio NIC).
</content>
