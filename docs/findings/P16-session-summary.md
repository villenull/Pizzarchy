# Session 16 summary — 2026-08-10 (P2.0b + P2.0c, and §5.13 audited)

> Companion to `docs/findings/P2-session-summary.md`. Evidence lives in
> `docs/findings/P2-steam-integration-and-rotation.md` (**R-27** is new) and
> `docs/findings/P16-repo-overlap-audit.md`; this is the orientation page.
>
> **The headline is uncomfortable and worth leading with: three recorded
> "facts" from session 15 were wrong, and two defects were introduced *by this
> session's own fixes* and caught only by mutation testing and soak runs.**
> Nothing here was found by reading code and concluding it looked right.

## 1. What was corrected — read this before trusting §5.15/§5.16

| Recorded | Actual |
|---|---|
| §5.15: "the missing `steamos-priv-write` means Gaming Mode's brightness slider does nothing" | **The slider works on the test Deck.** Steam *falls back*: helper → `sudo -n tee` → `sudo -n chmod a+w`. Right about the product, wrong about the present — and the wrong half is the dangerous one |
| §5.15: the 666 mode on the backlight sysfs node | **Steam sets it**, every Gaming Mode start, via that third fallback. Not a hand-edit |
| R-26: "`RestartSec=3` is the more important half" of §5.16's fix | **`RestartSec` never gated the fatal start.** It came from an explicit `systemctl restart` transaction; `RestartSec` only spaces `Restart=always` auto-restarts. The measured gap was **3 ms**, not 100 ms |
| R-26: §5.16 is a session-switch defect | It fired **at boot**. Any sddm restart whose teardown overruns 5 s can do it |

The unifying lesson, and the one to carry forward: **the test Deck is more
capable than the product**, because `/etc/sudoers.d/99-deck-testing` grants the
desktop user blanket NOPASSWD (§5.17). Anything privilege-dependent verified
here is suspect until re-checked without it.

## 2. Shipped

| Item | Verified by |
|---|---|
| **`steamos-set-timezone`** (`stage-timezone-helper`) | set the Deck to `Europe/Berlin`, confirmed, restored |
| **`steamos-priv-write`** (`stage-priv-write-helper`) | brightness → 45000, confirmed, restored |
| Both grants are **operative**, not just installed | re-run with `99-deck-testing` removed; Steam's own tier-2/tier-3 fallbacks refused, ours still worked |
| **§5.16's real fix** — `TimeoutStopSec=30`, stop→settle→start, `systemd-run` transient unit | 20/20 soak; zero `start-limit-hit`, zero stop timeouts, zero unit failures |
| **`Relogin=true`** (§5.18(b)) | greeter never blocked a switch again |
| **§5.13 answered with data** | 101 overlaps measured; reordering rejected; fix is one qualified package |
| Unit suite 17 → **53 assertions**, all four generated files covered | mutation-tested **34/34**, zero holes |

Later in the same session, working unattended:

| Item | Result |
|---|---|
| **§5.17 answered** | a narrower sudo grant is **impossible** — the stages write to `/etc/sudoers.d/` itself. Shipped `stage-audit-privileges` as a T6 release gate instead |
| **P2.2 programmatic half** | Wi-Fi, BT, audio, display, kernel **at parity**; input differs only because Steam replaces the native nodes with a virtual Xbox pad. `docs/findings/hardware-parity.md` |
| **§5.5 answered** | `steamdeck-dsp` is **`Proprietary`** with no licence text, so a *bundling* ISO is blocked; *fetching* redistributes nothing. Logo out, glyphs to be redrawn. `docs/findings/P16-redistribution-and-trademark.md` |
| **§5.18(a) root-caused and fixed** | `steam-launcher.service` `TimeoutStopSec=60`; retries went **600 → 283 → 20** |
| **P2.1 mapper shipped** | `stage-input-mapper` + `--user` unit; verified binding `event7 (Steam Deck)` on hardware. Two unit defects found by *running* it (ordering cycle, `StartLimit*` in the wrong section) |
| **P2.1 OSK probed** | `squeekboard` **runs on Hyprland 0.56.2**; needed an input source set via gsettings. Whether it appears on text focus is **unverified — needs eyes** |
| **§5.11 Limine menu** | **fix found** — `interface_rotation: 270` (Limine ≥v10; Deck has 12.5.2). Not applied: boot-chain. `omarchy refresh limine` would destroy a hand edit, so T5 must bake it in |
| **Recovery docs drafted** | `docs/RECOVERY.md` — the undo button, open since the original plan. Not yet exercised; P3.1 replaces it with first-hand |
| **P2.4 mechanism found** | Omarchy's Quickshell menu is extensible via `omarchy-menu.jsonc` and takes a **Nerd Font glyph** — no Valve artwork. Also fixed `Icon=steamicon`, which **resolved to nothing** |

`jupiter-hw-support` was **skipped** by operator decision — its six `jupiter-*`
helpers have no user-visible effect yet, and `jupiter-fan-control` belongs to
P2.3, which needs per-item approval anyway.

## 3. Opened

- **§5.17 — `99-deck-testing` grants blanket passwordless root**, is owned by no
  package, and **sorts last**, so it overrides every narrow grant this project
  installs. Must never ship. It is also what made §5.15 look healthy. Removing
  it permanently needs a narrower replacement first, because
  `tools/deck-sync.sh` runs whole install stages through `sudo -n`.
- ~~§5.18(a)~~ — **closed the same session.** Root cause was
  `steam-launcher.service` taking up to ~53 s to stop (R-28); the settle gate
  now waits on the user manager. Autologin attempts across 20 switches:
  **600 → 283 → 20 (ideal)**.

## 4. Two defects this session introduced, and how they were caught

Both would have shipped on a "the code looks right" review.

1. **A settle gate that matched nothing.** The §5.18(a) fix listed `gamescope`
   as a process name. The kernel truncates `comm` to 15 chars and `pgrep -x`
   matches `comm`, so inside a live gamescope session
   `pgrep -u deck -x gamescope` returns **0** — the compositor is
   `gamescope-wl`, its launcher `start-gamescope`. That half of the gate
   reported "settled" instantly and looked like it worked. Found by
   instrumenting the real settle window on hardware.
2. **Assertions that passed on comments.** Twice — first checking the helper
   did not call `fuser`, then checking the gate named `uwsm` — a whole-file
   `grep` matched the code's own explanatory prose while the code had stopped
   doing the thing. Both found by mutation testing, not review. The assertions
   now match the specific line.

**Methodology that earned its keep, and should be repeated:**

- **Mutation testing.** 34 introduced faults, 34 caught, and every hole it
  exposed was one review had already missed.
- **Assert *which* guard fired, not just the exit code.** Two guards sharing an
  exit code hide each other's deletion; three assertions had to be narrowed.
- **Soak, don't sample.** §5.18 needed 4 cycles to appear. P1.5's R-18 and
  session 15's R-23 both took this switch successfully and saw nothing.
- **A soak that passes too fast is broken.** The first one "passed" 9 cycles in
  45 s because it waited for *a* session rather than a *new* one — it never
  observed a real switch.

## 5. Honest limits

- **§5.18(a) is fixed** (R-28), but the residual cost is real: a switch *away
  from* Gaming Mode can take **~1 minute**, dominated by Valve's
  `steam-launcher.service` `TimeoutStopSec=60`. Correct and flicker-free, but
  not fast, and not something this project controls.
- **Two settle signals were measured and ruled out**, so the next attempt need
  not retry them: `graphical-session.target` **flaps** across a switch
  (active → inactive → active in ~1.6 s), and "no session for the user" can
  never be true while anyone is on SSH. The usable discriminator is
  `Type=wayland`, which excludes the `manager` session and `tty` sessions.
- **The narrow sudoers grants are proven; `99-deck-session-select`'s is not.**
  It was installed before that verification technique existed and still carries
  `verify_nopasswd`'s honest warning.
- **The gamescope session was never verified as *usable*** — only that logind
  created an active user session. Steam finishing startup is a different claim,
  and the operator could not see the screen during these runs.
- **Nothing here was seen on a screen.** Every result is from logs, `loginctl`,
  `systemctl` and `pacman`. Rotation, the greeter, and Gaming Mode's actual
  appearance remain visually unverified this session.

## 6. State on exit

| | |
|---|---|
| Deck | Omarchy desktop, Hyprland up, `ssh steamdeck` working |
| Snapshots | #1–#3 P1.5 · #4 pre-15 · #5 P2.0 · **#6** pre-polkit-helpers · **#7** pre-sddm-decouple |
| Branch | **merged into `main` and pushed** at the operator's instruction, end of session 16 |
| Backlight node | deliberately left **0644**, not the 666 found. If it is 666 again, Steam fell back, which means a helper broke |
| ⚠️ Temporary | **display always-on is ENABLED** for testing — idle/screensaver/lock off, sleep targets masked. Revert: `sudo /usr/local/sbin/deck-always-on-revert.sh`. This is an **OLED** panel; burn-in is the reason not to leave it |

## 7. A pattern worth naming: three checks that were wrong about themselves

Beyond the two defects in §4, this session produced three *checks* that
reported confidently and incorrectly. All three were caught by running them
against reality, none by review:

| Check | Failure |
|---|---|
| settle gate's `pgrep -x gamescope` | matched **nothing** — the comm is `gamescope-wl`. Reported "settled" instantly |
| target probe using `list-unit-files` | warned a target was missing while it was **active**; it is a runtime template instance with no file on disk |
| `stage-audit-privileges` v1 | failed on `03_deck`, the ordinary password-protected admin grant — the false positive that gets a release check ignored |

The shared shape: **a check that cannot distinguish "I looked and found
nothing" from "I looked in the wrong place."** Worth asking of any new
assertion, and worth a mutation test, which is what caught the equivalent
problem in the unit suite three times.

## 8. Where to go next

- **P2.0d (§5.17)** — the blanket sudo grant. Everything privilege-shaped is
  untrustworthy until it goes.
- **P2.5 / P2.6 — T4's installer screens in QEMU.** The largest remaining
  phase-2 chunk and fully autonomous; needs no Deck.
- **P2.7 / P2.8 — T5's ISO fork.** Now carries **five** recorded constraints:
  offline pacman, the encryption default (§5.12), repo precedence (§5.13),
  baking in rotation (desktop `monitors.lua` **and** Limine
  `interface_rotation`), and excluding `99-deck-testing` (§5.17).
- **P2.4** — add the menu row; mechanism is known
  (`omarchy-menu.jsonc`, Nerd Font glyph).
- **Anything needing eyes or hands** — OSK on focus, button mapping, audible
  sound, haptics, gyro, and every rotation surface. None of session 16 was seen
  on a screen.
- **P2.1 / P2.2** — input mapper as a `--user` service, hardware parity matrix.
