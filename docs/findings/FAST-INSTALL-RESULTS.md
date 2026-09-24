# FAST-INSTALL — results of the four-variant installer (2026-09-24)

Spec: `docs/tasks/FAST-INSTALL.md`. Baseline it is measured against:
`docs/findings/INSTALL-SPEED.md` (252 s from form confirm to ready-to-reboot, Deck, 2026-09-23).

**Everything below is QEMU/KVM, not the Deck.** The harness emulates the OLED's DMI
(`Valve`/`Galileo`), an NVMe target, and the USB stick as `usb-storage` read-throttled to the
measured 82 MB/s. Not exercised: the physical controller, Wi-Fi radio, panel, gamescope
rendering, audio, and the real form (cidata answers the form; `form-delay-seconds` simulates
how long a human takes). A physical install wipes the Deck and needs the operator.

## v4 — 4315c95 on top of v3, two-variant re-check (same day, evening)

**Current ISO.** Supersedes v3 as the one to install.

| | |
|---|---|
| File | `pizzarchy-omarchy-4.0.4-fast-install-2026-09-24-v4-x86_64.iso` |
| Size / sha256 | 6,875,340,800 B · `92325610412ee751516c74f8da060493f04b192b3f307f6b6399542b04c7981c` |
| Source | commit `21d87fd` (branch `hw-feedback-1`), i.e. v3's `60cf667` + `4315c95` (docs-only `21d87fd` on top) |
| Where | `~/.cache/omarchy-deck/release-2026.09.24-v4/` (ISO + `SHA256SUMS`, verified); build logs `~/.cache/omarchy-deck/build-v4.log` (first attempt) and `~/.cache/omarchy-deck/build-v4b.log` (retry) |
| Build | `iso/bin/build` against scratch `~/.cache/omarchy-deck/iso-build-fast-variants`, all guards green (`6.1`, `6.3`, `6.4a`, `6.4b`, `6.5a`, `6.5b`, `6.6`, `6.7`, `6.8`), script's final size/sha lines present, staged artifact re-hashed to the logged sha |
| Pins | unchanged: `omacom/omarchy@c668141e9c42` · `omacom/omarchy-iso@7cfb7111a068` · `omacom/omarchy-pkgs@5fe236736607` |

What changed since v3 is exactly `4315c95` ("installer: close held-A wipe-confirm
hole, 5 review follow-ups"): the wipe confirm drains pending input until a 0.6 s
silence (`DECK_CONFIRM_QUIET_SECS`, capped) so typematic autorepeat from a held A
can no longer confirm the wipe, `s0_wait_key` also accepts raw-mode CR, the early
orchestrator propagates `render_early_config` failure so the precise 'too small'
error survives, plus smaller `deck-form.sh` robustness fixes — each with a
failing-first unit test.

Build note: the first attempt died silently right after `[timing] mkarchiso end`
— same shape as v3's first attempt (log ends there, no guards, no docker
container left, ISO present but unguarded). Captured in `build-v4.log`; the
retry (`build-v4b.log`) ran clean past that point on the first try. One
convention recorded for the next build: `iso/bin/build` itself prints no
`WRAPPER_EXIT` line (verified by grep — v3b's was the outer shell's echo), so a
build counts when the script reaches its final sha line with no `build_fail`
and the staged artifact re-hashes to the logged sha.

QEMU on this ISO (`test/vm/vm-fast-install-test.sh`, `VM_FAST_REBOOT_CHECK=1`,
form delay 90 s). Same odd-sized NVMe target as v3 (21,475,469,824 bytes, mod
1 MiB = 633,344); neither harness log nor either serial log mentions "misalign"
(the only matches anywhere are kernel/Rust strings inside the raw disk images).

| pre-installs / Gaming | target | network | early stage | post-confirm (A) | of which waiting for early | reboot check | result | wall |
|---|---|---|---|---|---|---|---|---|
| no / no | NVMe (odd) | none | 30 s | 5 s | 0 s | login after 30 s | PASS | ~6 min |
| no / yes | NVMe (odd) | user | 94 s | 11 s | 5 s | login after 35 s | PASS | ~4 min |

Reading it: identical shape to v3's no/no and no/yes rows (28→30 s, 5→5 s;
92→94 s, 11→11 s) — `4315c95` changes no timing path, as expected. The new wipe
confirm, like the rest of the form, runs only in unit tests here (QEMU answers
from cidata); it needs the Deck, as does everything else behind the v3 blocker.

## v3 — the hardware-blocker fix, odd-sized NVMe regression check (same day, evening)

**Current ISO.** Supersedes v2 as the one to install.

| | |
|---|---|
| File | `pizzarchy-omarchy-4.0.4-fast-install-2026-09-24-v3-x86_64.iso` |
| Size / sha256 | 6,868,631,552 B · `2de394918ff73507a5bf54d210aeae65086bf4beceaaf44c33e37202cc8ca725` |
| Source | commit `60cf667` (branch `hw-feedback-1`; note: `4315c95` landed mid-build and is NOT in this ISO) |
| Where | `~/.cache/omarchy-deck/release-2026.09.24-v3/` (ISO + `SHA256SUMS`, verified); build log `~/.cache/omarchy-deck/build-v3b.log` |
| Build | `iso/bin/build` against scratch `~/.cache/omarchy-deck/iso-build-fast-variants`, all guards green (`6.1`, `6.3`, `6.4a`, `6.4b`, `6.5a`, `6.5b`, `6.6`, `6.7`, `6.8`), exit 0 |
| Pins | unchanged: `omacom/omarchy@c668141e9c42` · `omacom/omarchy-iso@7cfb7111a068` · `omacom/omarchy-pkgs@5fe236736607` |

What changed since v2 (`docs/findings/HW-INSTALL-FEEDBACK-2026-09-24.md`): the
blocker — `deck_early_layout` rounds the disk down to a whole MiB before sizing
root, as upstream's `configurator` does, so archinstall 4.4 no longer fails with
"Partition is misaligned" on the Deck's not-a-whole-MiB NVMe. Plus the operator's
screen feedback: welcome cut to two lines with the logo on top, drive-screen
warning in the question's colour, a wipe confirmation (A wipes, B back to the
list, pending input drained first), `disk_form` reuses the chosen drive instead
of a second picker, the failure screen prints the early-log tail, pre-installs /
Install Steam? default to Yes, B on pre-installs no longer claims "the drive was
not touched" after the wipe, and B from keyboard layout walks the Deck answers
back read-only.

QEMU on this ISO (`test/vm/vm-fast-install-test.sh`, `VM_FAST_REBOOT_CHECK=1`,
form delay 90 s throughout). The NVMe target is deliberately NOT a whole MiB any
more — the harness adds a 1237-sector tail (`60cf667`), so these runs are the
regression check for the hardware blocker: every NVMe target below is
21,475,469,824 bytes (20 GiB + 633,344; mod 1 MiB = 633,344), and none of the
four install logs nor their serial logs mentions "misalign" once.

| pre-installs / Gaming | target | network | early stage | post-confirm (A) | of which waiting for early | reboot check | result | wall |
|---|---|---|---|---|---|---|---|---|
| no / no | NVMe (odd) | none | 28 s | 5 s | 0 s | login after 25 s | PASS | ~6 min |
| no / yes | NVMe (odd) | user | 92 s | 11 s | 5 s | login after 35 s | PASS | ~4 min |
| yes / yes | NVMe (odd) | user | 107 s | 26 s | 20 s | login after 35 s | PASS | ~4 min |
| no / no | microSD | none | 845 s | 788 s | 754 s | login after 60 s | PASS | ~18 min |
| in-place opt-in on the no/no NVMe disk | — | user | — | action 50 s, exit 0 | — | — | PASS (`test/vm/vm-enable-gaming-test.sh`) | ~3 min |

Reading it: the late work still lands in seconds on NVMe in every variant
(5–26 s post-confirm). The microSD run's 788 s is QEMU's emulated SD controller,
not the Deck's card reader — same caveat as v2. The failure screen's early-log
tail, the wipe confirm, and the drive picker run only in unit tests here (QEMU
answers the form from cidata); they need the Deck, as does everything behind the
old blocker (Wi-Fi, Steam download screen, OSK name/email entry, first boot).

## v2 — the operator's flow, microSD target, name/email (same day, later)

**Current ISO.** Supersedes the "Final ISO" below as the one to install.

| | |
|---|---|
| File | `pizzarchy-omarchy-4.0.4-fast-install-2026-09-24-v2-x86_64.iso` |
| Size / sha256 | 6,867,582,976 B · `29dc4a725ebcd44d0b3b5a600695d9e809a7db2e780dbff636e9e3f3a0aac6c5` |
| Source | commit `71b44cd` (later commits: `test/vm/` harness and docs only) |
| Where | GitHub prerelease `v2026.09.24-fast-install-v2` (four `.partN` + `SHA256SUMS`); operator's Ventoy stick, verified by `dd iflag=direct` readback |

Flow, in order: welcome + wipe warning → **choose the drive** (built-in NVMe and the microSD
card; USB and the boot medium never listed) → background install starts on it → pre-installs
Yes/No → **Install Steam?** Yes/No → Wi-Fi **only if Steam = Yes** → **Steam download screen**
(bar, MB done/total, rate, time left; failure menu: try again / continue without Steam /
reboot / power off) → username, password, **full name, email** (Enter skips), hostname,
timezone → summary → confirm.

QEMU on this ISO: No/No, Yes/No, No/Yes and Yes/Yes on NVMe all PASS with reboot to login; the
in-place Enable Gaming Mode PASS; **No/No on the microSD card** installs, passes every on-disk
check, and boots to login. Name and email land in `~/.config/git/config` (git writes the XDG
file when that directory exists; an earlier check looked for `~/.gitconfig` and was wrong).
The SD install took ~15 min in QEMU: that is QEMU's emulated SD controller, not a measurement
of the Deck's card reader, which is unmeasured.

**Not exercised anywhere yet:** the new screens themselves (drive picker, Steam download
screen) run only in unit tests, because QEMU installs answer the form from cidata. They need
the Deck.

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
