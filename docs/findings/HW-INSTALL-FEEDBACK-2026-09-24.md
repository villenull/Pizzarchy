# First hardware install of the v2 ISO — operator feedback (2026-09-24)

ISO: `v2026.09.24-fast-install-v2` (sha256 `29dc4a72…c6c5`), Deck OLED, operator
driving live with the controller. First time any FAST-INSTALL ISO met hardware
(`docs/PROGRESS.md` §5.50 said so).

## 🔴 Blocker — every install fails on real hardware

**Symptom.** No pre-installs / no Steam / internal NVMe, twice: *"The background
install failed before it finished. The early orchestrator run failed."* Reboot /
Power off only.

**Evidence.** Operator plugged a keyboard, `Ctrl+Alt+F2`, root, and
`tail -60 /var/log/omarchy-deck-early.log`:

```
> loading configurator output
Partition is misaligned
[omarchy-deck-early] ERROR: the early orchestrator run failed; see /var/log/omarchy-deck-early.log
```

**Cause.** archinstall 4.4 `lib/models/device.py:214` rejects any created
partition whose start or *length* is not a whole MiB. `omarchy-deck-early`'s
`render_early_config` sized root as `disk_bytes - 2 GiB - 2 MiB`. The Deck's NVMe
is not a whole number of MiB, so root's length was not either. Upstream's
`configurator` rounds first (`disk_size_in_mib=$((disk_size / mib * mib))`); the
early config copied the layout but not the rounding.

**Why QEMU never saw it.** Every test disk is a round size (`qemu-img create …
64G`), so the subtraction always landed on a MiB boundary. The fake hardware was
tidier than the real thing — the same shape as §5.32.

**Also:** the failure screen showed only "see /var/log/…", a file in the live
ISO's RAM that no controller user can open, and powering off destroys it.

## Screen feedback, in the order the operator met it

| # | Screen | Feedback |
|---|---|---|
| 1 | Welcome | Big Omarchy logo centred on top, as every other screen. Text cut to "This will install Omarchy on your Steam Deck." + "Press A to install, B to cancel". |
| 2 | Drive | The "wiped immediately / B goes back" line is faint gray (colour 8); make it the question's colour. After picking a drive, ask again — "Are you sure? This will wipe …", A wipes, B returns to the list. The wipe starts only on that A. |
| 3 | Later "Select where to install Omarchy" | Asked again after the account screens, although #2 already chose it. Reuse the choice. (Cause: the `disk_form` override autoselects only with exactly one eligible disk; with NVMe + microSD it draws a second picker. QEMU had one disk.) |
| 4 | Background install | See blocker above. |
| 5 | Pre-installs? / Install Steam? | Cursor starts on **Yes** for both. |
| 6 | Back navigation | B always returns to the previous screen, **except** it can never return to the wipe confirmation. From keyboard layout, B must reach the Deck questions. Operator chose: those answers are **shown read-only** when revisited (the background install is already acting on them), not re-editable. |

Found while fixing #6: B on the pre-installs screen — the first screen *after*
the wipe starts — opened the cancel menu, which says "The drive was not touched."
That was false once the wipe had begun.

## Not yet exercised on hardware

Wi-Fi from the live ISO (load-bearing, `CLAUDE.md`), the Steam download screen,
name/email entry with the OSK, the summary, the Gaming=No greeter, first boot.
All sit behind the blocker or behind Steam=Yes.

## Second pass — v4 ISO on the Deck (same day)

| # | Screen | Feedback |
|---|---|---|
| 7 | Summary / network note | With Install Steam? = **No**, don't show "No network was found": nothing on that path needs the network. Keep it only for Steam = Yes. |
| 8 | Pre-reboot notice (`DECK_S5_REBOOT_LINES`) | With Steam = **No**, show only "When the install finishes the Deck reboots on its own." Drop the Steam/black-screen/Gaming Mode lines. Steam = Yes keeps the full block. |
| 9 | Steam download screen, before the download starts | Bar draws as `[?????…]` while the size is unknown (base install still running). Looks broken; say "Waiting for the base install to finish" instead of a bar of `?`. |
| 10 | Steam download screen | The whole screen flashes (clears and redraws) every ~3 s. Update the changing lines in place. |
| 11 | Steam download screen | Speed is stuck at `0.00 MB/s` the entire download while MB done climbs (e.g. 203.9 of 484.7 MB). Find and fix the rate calculation (test with real progress numbers); show time left. |
| 12 | Steam download screen | ~~Logo off-center~~ — not a bug: the logo is centred; the photo angle made it look shifted (operator). |
| 13 | Flow design | **Decided (operator):** the Steam download screen keeps holding the form until the download finishes. No change. |

✅ **Hardware milestone:** Wi-Fi from the live ISO works on the Deck OLED — joined with a controller-typed passphrase on the Wi-Fi screen and downloaded Steam from Valve (42%, 203.9/484.7 MB observed). First hardware confirmation of the `CLAUDE.md` "Wi-Fi must work in the live ISO" requirement.

✅ **Operator-confirmed on hardware (v4):** account screens (username, password, full name, email) usable with the on-screen keyboard; the summary screen reads correctly; with a microSD card inserted the drive screen lists both drives and the wipe confirm names the chosen one. The full Steam=Yes form path (Wi-Fi → Steam download → keyboard layout) completed.
| 14 | Welcome screen | Both lines ("This will install Omarchy on your Steam Deck." / "Press A to install, B to cancel") must start at the left edge of the Omarchy logo, like every other installer screen — not at column 0, not centred. (Likely cause: `deck_form_s0_text` prints with bare `printf`, while other screens use `say`, which applies the logo's left padding.) |
| 15 | Wipe confirm | Prompt line becomes exactly `Press A to wipe and install NOW, B to go back` ("NOW" in caps on purpose). |
| 16 | Keyboard layout, B | **Reverses item 6's read-only walk:** B on keyboard layout does NOTHING — no jump to the read-only pre-installs/Steam screens (remove that walk), and no visible full-screen redraw/flash either (in v2 B re-drew the whole screen; the operator wants B to be a true no-op). |
| 16a | B map (operator, supersedes item 6's B rules) | Welcome: B = cancel menu. Drive list: B = Welcome. Wipe confirm: B = drive list. Pre-installs?: B = nothing. **Install Steam?: B = back to Install pre-installs?** (operator correction) **Wi-Fi list: B = back to Install Steam?** (same effect as its "Back" row). **Steam download: B = nothing** (no flash). **Keyboard layout: B = nothing** (read-only walk removed, no flash). Account screens and summary: unchanged. |
| 17 | Wi-Fi → Install Steam? | Steam=Yes → Wi-Fi → B → Install Steam? again → choosing **No** must continue the install normally as Steam=No (keyboard layout next; the background install must drop Steam and never wait for network). Choosing Yes returns to Wi-Fi. Test the whole round trip, including that pre-installs can never be reopened once locked. |
| 18 | Choice lock timing (orchestrator, to make 16a/17 safe) | Because B now moves freely between pre-installs ⇄ Install Steam? ⇄ Wi-Fi, the pre-installs + gaming answers are written and `locked` only when the user LEAVES that group: Steam=No answered, or Wi-Fi connected with Steam=Yes (network-ready). Before that nothing is committed, so any back-and-forth is safe. Once locked, nothing can reopen pre-installs. |
