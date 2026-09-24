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
