# Progress

> The single living state document. Keep it current as you work, not just at
> session end. Read it at the start of every session.
>
> **Structure:** current state → scope → findings that changed the plan →
> open issues → blocked on human → don't re-derive → session log.
> Chronological narrative belongs in git history, not here. When a finding is
> superseded, **replace it** — this file is state, not a log.

---

## 1. Current state

**Target: a single bootable ISO that installs Arch + Omarchy 4.0 on a Steam
Deck, controller-only, and boots to Gaming Mode with a full Omarchy desktop
behind a Desktop Mode button.** `docs/PLAN.md` §1, with one amendment: the install
may use Wi-Fi (§2.2).

| Task | Status | Notes |
|---|---|---|
| **T0** Test infrastructure | ✅ done | QEMU install harness, CI green, SSH loop, unit tests. **Both §5.4 gaps closed by P1.5** |
| **R1** Six research questions | ✅ done | All six resolved. Several overturned the plan — §3 |
| **T1** Kernel / firmware / boot | ✅ done | Ten stages, **hardware-validated end to end 2026-08-10** (§5.2). Neptune pin bump still untested |
| **T2** Gamepad input spike | ✅ done | Navigation confirmed on hardware; T4 is days not weeks. Text entry open — §3.9. **`vm-gamepad-spike-test.sh` (the automated version of this question) finally RAN 2026-08-12, session 23 — 26/26 PASS**, after existing unrun (and briefly unrunnable) since it was written; see the session-23 log entry |
| **T3** Gaming Mode + switching | ✅ **CLOSED 2026-08-12 (session 22).** §5.10/§5.14/§5.15/§5.16/§5.18/§5.11/§5.17/§5.28 all closed; P2.1/P2.2/P2.3/P2.4 all closed (ROADMAP's table); §5.24a's three lock-usability requests: **two closed** (display-on timing via T12's patch, OSK auto-hide confirmed deployed and wired), **one open** (only-power-button-wakes-the-blanked-panel — a Quickshell-side gate, untouched). Both reboot directions **hardware-verified on the panel** — `docs/findings/T13-power-button-and-sleep.md` §9 |
| **T4** Controller-only installer | 🔴 **REOPENED 2026-08-15 (session 28) BY HARDWARE.** The first physical first-boot showed the 18/18 QEMU pass did **not** mean a usable machine: no on-screen keyboard on any text-entry screen (so the install is not controller-only at all), and the installed system came up to a black screen with no Steam. **§5.32** is the full account and the reason — every assertion checked that our steps ran, none that the outcome exists. Criterion 1 is not closed. Previous claim, kept for the trail: ✅ **CLOSED 2026-08-15 (session 27) — phase 2 exit criterion 1 passed 18/18 on a real install** (`install.outcome=success`, `autologin: gaming`, disk-image assertions executed for the first time ever; §5.31a and `docs/findings/T4-controller-only-install-first-run.md` §15). History below. 🟡 **`deck-form.sh` has a route onto the ISO (session 22)** — the 5th overlay patch, argued in its own header, plus `deck-dashboard.sh` (T4a, session 22). Screen spec `docs/tasks/T4-screen-spec.md` still the design authority. `--osk-start-shown` + the mapper's `bound` readiness marker exist now, so S1's Wi-Fi passphrase prompt no longer degrades by construction. **⚠️ CORRECTED 2026-08-15 (session 28): that is true of the PROTOCOL, false of the ARTIFACT — the mapper binary and `python-evdev` were never shipped into the live ISO, so on real hardware EVERY text-entry screen (Wi-Fi, username, password, hostname) degrades to "no OSK, attach a keyboard." Found on the first hardware boot of the stable ISO. P1 blocker for P3.2. `docs/findings/P32-osk-mapper-missing-from-live-iso.md`.** Session 23's `[V]` run against the real ISO found two real bugs (`docs/findings/T4-controller-only-install-first-run.md` §5/§2); **both fixed and unit-regression-tested (§12)**, then **re-verified on a real rebuilt ISO the same day** (§13.4): a fresh `[V]` run's written `user_configuration.json` shows `hostname: steamdeck` and a real geo timezone, not upstream's defaults — the fix holds on hardware-equivalent boot, not just in the unit suite. **That same run crossed S5's gate for the first time ever** (`y` on `deck_final_summary`, §13.4) and found a NEW, more severe blocker: `configurator` crashes (`$1: unbound variable`, `set -u`) immediately after `write_user_files`, before `omarchy-install-dashboard` ever starts — a plain upstream bug (unguarded `$1` at the very end of `configurator`, reached only by the full-disk branch every Deck install takes), not a Deck-specific one, invisible to every prior test because none had pressed "Install" on a disk sized to survive the attempt. **The `$1` fix landed 2026-08-13 (session 25, Opus)** as hunk 3 of `deck-form-invocation.patch` (`${1:-}`, matching the file's two already-correct sibling checks), the ISO was rebuilt (sha256 `a27230ff…`), and the harness re-run: **the `$1` crash is GONE — the real installer now launches and runs the entire base Omarchy setup to completion** (§14). Criterion 1 is **still not closed**, now blocked one layer deeper by a real bug in OUR OWN `orchestrator/deck_autologin.py`: `DESKTOP_SESSION = "omarchy.desktop"` gets `.desktop` appended a second time by `find_session`, so the desktop-session fallback searches `omarchy.desktop.desktop` (never exists) while the real `omarchy.desktop` sits right there — `choose_session` returns `failed`, and `autologin` (the registry's sole `critical=True` step) aborts the install. Every OTHER Deck step succeeds on a real install (measured off the target's `@log/omarchy-deck-install.json`, §14.4). **Left:** the one-line `deck_autologin.py` fix (`DESKTOP_SESSION="omarchy"` + fix its unit fixture, §14.6 item 1), and separately the absent `gamescope-wayland.desktop` in the ISO's package set (§14.6 item 2) |
| **T5** ISO + package payload | 🟢 **`iso/bin/build` RAN FOR REAL 2026-08-12 (session 23), and it worked.** First-ever full-tree container build: all 8 guards (6.1, 6.3, 6.4a, 6.4b, 6.5a, 6.5b, 6.6) passed, all 5 overlay patches applied (2 via git's 3-way-merge fallback to direct application on a shallow clone — verified by hand that both landed: `configure_deck` import in `main.py`, the `deck-dashboard.sh` source line in `omarchy-install-dashboard`), `omarchy-deck` 0.2.0-1 built and its 2 runtime patches applied cleanly. Output: `omarchy-2026.08.13-x86_64-quattro.iso`, 6.39 GiB. **Rebuilt again the same day** (§12's two `deck-form.sh` fixes, commit `e729699`) at the same cache path — sha256 is now `d07bf6cbe96ac417d3fe8a632283ef872cffa42d79d16bfb8a91e3ddaa3bfea3`, **not** the `336f357...` hash this row used to cite; that ISO no longer exists on disk (overwritten in place — caught mid-boot by a concurrent QEMU run, `docs/findings/T4-controller-only-install-first-run.md` §13.2, no data lost, just a stale citation). First attempt (before either rebuild) failed on a corrupted cached package from an old scratch dir predating today's runtime pin; **treat the old `~/.cache/omarchy-deck/iso-build/` scratch dir's artifacts as stale/discardable, not evidence of anything**. **An actual controller-only QEMU install run against this ISO has now happened** (§13 of the same finding) — it does not yet close criterion 1: the run reaches `write_user_files` correctly but `configurator` itself crashes right after (a plain upstream `set -u` bug, §13.4), so the real installer never starts and the disk-image assertions this session wrote (`test/vm/vm-install-controller-test.sh`) have not run against a real completed install yet. **Update, session 25 (Opus):** the `$1` bug was fixed (hunk 3 of `deck-form-invocation.patch`), the ISO rebuilt clean (all 8 guards, sha256 `a27230ff498f8b7b4be45f455192d135fb5ab777b3204022802da19e34b6ea6a`), and the harness re-run — **the real installer now runs the whole base Omarchy setup to completion** and then aborts in our own `configure_deck` phase on the `deck_autologin.py` double-`.desktop` bug (§14). Harness now 10/11 (was 9/11), `install.outcome=failure` (was `timeout`); disk-image assertions STILL correctly skipped (gated on success), never exercised. `input.lua`'s **`above_lock`/DPMS half now has a writer and it works** on a real install (session 25 shows `lock_wake_dpms: configured`, `above_lock=2`, `user_path=/home/deck/.config/hypr/input.lua` in the target's deck-install record); the **OSK per-device XKB half of `input.lua` is a separate concern and its writer status is unverified here**, do not read this as closing it. ⚠️ **Infra note for the next builder:** a first rebuild attempt died mid-pacstrap on a corrupted cached `omarchy-settings-dev-*.pkg.tar.zst` (stale-scratch-dir class, same as session 23); a clean re-run re-fetched it and succeeded — treat checksum-corruption on a cached pkg as throwaway, clear the file and retry |
| **T6** Integration + release | 🟡 **UNGATED 2026-08-14 — Omarchy 4.0.0 stable shipped** (`v4.0.0` = `f0020448`). Phase 3 is live. Stable pin measured + full delta classified 2026-08-15 (session 27, §5.31); Deck update runbook ready (`docs/tasks/P36-deck-stable-update-runbook.md`, operator-present). Rebase folds phase 2.9 + P3.6 into one move (ROADMAP escalation) | See §5.31 |
| **T9** Rebase onto beta 2 | ✅ **done — phase 2.9 FULLY CLOSED 2026-08-11** | We were already on it, measured from inside both ISOs; the Deck confirmed on the pin (`omarchy-version` = `4.0.0.r1617.g6d7826d-1`) and the hands-on rows signed off on screen (session 20). Delta ahead classified, substrate pinned, four VM suites green |
| **T12** Upstream-patch seam | ✅ **BUILT, PACKAGED AND HARDWARE-VERIFIED 2026-08-12 (session 22)** | The applier, ALPM re-apply hook and failure-surfacing unit ship inside `omarchy-deck` (mode 0755, enabled via a shipped `.wants` symlink, no scriptlet). Guard 6.6 (`iso/bin/build`) fails the build if a patch drifts from the pinned runtime. **Both patches applied for real on the Deck** — lock-blank timer 250ms→**20000ms**, Limine rotation (corrected `90`, not the shipped-then-fixed `270`) — verified on disk, idempotent re-`--verify` confirms `already applied` |
| **T13** Power button + sleep | ✅ **CLOSED 2026-08-12 (session 22), all four operator-reported defects, hardware-verified** | `docs/findings/T13-power-button-and-sleep.md`. The mechanism: one physical press produces two `KEY_POWER` events on asymmetric nodes (a real key + a fire-and-forget ACPI notify); a udev rule drops the ACPI node from `power-switch`, a logind drop-in sets `HandlePowerKey=suspend` explicitly (its default is `poweroff`, not `suspend`). Deploy is a reboot-gated two-file write with a printed undo. **Measured on the panel**: suspend/resume clean in both Gaming and Desktop Mode, same `gamescope` PID across the cycle (session survives), deep/S3 confirmed twice independently (not s2idle, contra the initial research). One benign surprise, corrected in the stage's own text: Desktop Mode's System menu still flashes briefly (the compositor sees both raw presses regardless of the udev tag; only `logind`'s trigger became single-sourced) — n=1, not a guarantee either way |
| **T14** Gaming Mode power button (decision) | ✅ **ANSWERED 2026-08-12 — ship nothing extra** | `docs/findings/T14-gaming-mode-power-button.md`. `logind`'s only gate on the power key is the `power-switch` tag, with no session check at all (read from `systemd`'s own source), and `gamescope` holds no logind inhibitor anywhere in its tree — T13's fix already covers Gaming Mode. `steamos-powerbuttond` is cleanly BSD-2 (redistribution was never the blocker) but *requires* `HandlePowerKey=ignore`, which conflicts with T13's `suspend` |

**The plan is `docs/ROADMAP.md`** — answer the unknowns and rebuild the test bed
(1), build the product (2), **catch up to upstream (2.9 — new 2026-08-11)**,
prove it from a factory reset and release (3), generalise into a Deck enablement
layer (4). *(This line said "three phases" until 2026-08-11; it was stale from
the day phase 4 was added.)*

**🆕 Phase 2.9 — rebase onto Omarchy 4.0 beta 2** (`docs/tasks/T9-beta2-rebase.md`,
§5.22). Everything we own sits on the 4.0 snapshot of 2026-08-10; upstream has
moved, measurably and not cosmetically. The rebase happens *before* phase 3 so
the release run has one moving variable, not two.

**P1.5 is ✅ COMPLETE (2026-08-10).** All six phases ran in one session. The
Deck now runs package-based **Omarchy 4.0 + Neptune 6.11.11-valve29**,
unencrypted, booting unattended, with both session-switch directions working
and **zero DeckShift**. Full findings, R-0 through R-18:
`docs/findings/P15-live-iso-recon.md`; raw evidence in
`docs/findings/P15-recon-raw/`.

Closed by it: §5.1, §5.2, §5.3, §5.4, and phase-1 exit criteria.
Opened by it: §5.9–§5.14, several of which change T3/T4/T5.

Two deviations from the runbook, agreed with the operator: a **single USB
stick** (no pre-staged recovery stick — reflash on demand instead) and
**Wi-Fi rather than Ethernet** for SSH, which worked.

**Deck access for the next session:** `ssh steamdeck` (alias → 192.168.100.25,
user `deck`, key-based). Passwordless sudo via
`/etc/sudoers.d/99-deck-testing` — **test-device posture, revisit before
shipping** (it also masks `deck-session.sh`'s own sudoers verification).
Snapshots: #1 pre-Neptune, #2 post-conversion, #3 complete.

**Session 15 (2026-08-10) closed the phase-2 opener.** §5.10, §5.14 and the
greeter/desktop half of §5.11 are all resolved and proven on hardware: **Steam's
own Power → Switch to Desktop now works end to end**, and Steam is signed in.
`src/deck-session.sh` went from four install stages to six, each verifying its
own effect by running something. Snapshot **#4** precedes that session's writes.
Findings: `docs/findings/P2-steam-integration-and-rotation.md` (R-20…R-26).

It opened **§5.15** (Steam's whole privileged-helper surface is missing — this is
now the widest gap, and it owns Gaming Mode's brightness slider) and **§5.16**
(the switch could permanently kill sddm; mitigated, root cause open).

**Next action: `docs/tasks/P2.9-deck-session-runbook.md`.** One operator session,
five approved changes plus one read-only check, ordered by blast radius, with
rollbacks and a stop-early table. 🔴 It opens with the §5.26 gate — one line,
run from a **booted USB**, that decides whether T4 has a keyboard at all.

Everything else is either behind that session or independent of it: T5's fork
(planned, §3.10a's two-pin trap recorded), T4's screens (specified, test tier
proven viable), and §5.27's two hand-offs that must land together to ship OSK
auto-show.

**Session 17 (2026-08-10) was the eyes-and-hands pass**, the first time any of
this was seen on a screen. **Nine defects, none visible to any check in this
repo**, plus two recorded "facts" corrected — one of them written by this same
session hours earlier. Findings: `docs/findings/P17-input-and-osk.md`
(R-29…R-42).

The mapper was a **complete no-op** on the desktop, and under it the d-pad
emitted nothing and a resting stick cancelled every held direction in ~10 ms.
It then grew into the **full input layer** (pointer, clicks, STEAM+X) so the
operator's requested chord could work at all — which surfaced four more bugs,
the worst being that **diagonal pointer movement emitted nothing** while every
single-axis test passed.

It also: answered §5.20 (the OSK works; one GSettings key gated it), fixed a
generated file **executing a command as root** at render time which had left
**CI red**, shipped `stage-desktop-settings`, confirmed Gaming Mode usable,
and **revised §2.6** after proving Steam cannot drive a Wayland desktop (R-42).
New task: **T8**, the on-screen keyboard we draw ourselves.

**Git state:** session 17's work is merged to **`main`** and **pushed** to
`origin`. Verify with `git rev-list --left-right --count origin/main...main`,
never by trusting this line — it has been stale before.

✅ **CI is green.** ⚠️ **It has now been RED twice while this file said
otherwise**, and both times the reason was checking a narrower set than CI does.
Session 17 fixed an SC2006 in `src/deck-session.sh`; session 18 found
`shellcheck -x` still exiting **1** on eight `note`-level findings in
`test/hw-probe.sh` and `test/unit/test-deck-session.sh` — because CI lints
**every** `*.sh` in the repo and shellcheck exits non-zero on *any* finding,
including notes. All eight were deliberate patterns (literal injection strings,
grep patterns, an intentional `A && B || C`) and now carry narrow
`# shellcheck disable=` directives with reasons.

**Verify with CI's own command, not `shellcheck src/*.sh`:**

```bash
mapfile -t files < <(git ls-files --cached --others --exclude-standard '*.sh'); shellcheck -x "${files[@]}"
```

⚠️ **`--others --exclude-standard` is the important part, added 2026-08-11 after
this bit a third time.** CI runs the narrower `git ls-files '*.sh'`, which is
correct *there* — CI checks out a commit, so everything is tracked. Locally it
is a trap: **a brand-new suite is untracked, so the "CI's own command" check
sails past it, and the file becomes lintable only once you commit it.** That is
exactly how `test/unit/test-vm-limine-pin.sh` went in red in commit `e5a5540`
after its author ran the lint and saw exit 0. **Use the command above before
committing; CI's narrower one only agrees with it afterwards.**

Now: **15 suites and that command exit 0** — ten shell (`test-deck-session.sh` 70,
`test-deck-session-stages.sh` **223**, `test-duplicated-upstream-facts.sh` 18,
`test-iso-payload-audit.sh` 16, `test-osk-install-layout.sh` 19,
`test-vm-limine-pin.sh` 16, four VM-helper suites) and five Python
(`test-deck-input-mapper.py` 106, `test-deck-osk-layout.py` 134,
`test-deck-osk-tty.py` 54, `test-deck-osk-wayland.py` 47,
`test-deck-osk-focus.py` 37). ⚠️ The Python ones are not in the `test-*.sh` glob;
run both globs. One more, `test/osk-tty-e2e.py`, is in **neither** — it needs
`/dev/uinput` and is run by hand, because a suite that skips itself when a
device is missing reports green while asserting nothing.

*(Re-counted by running everything 2026-08-11. The previous version of this
paragraph said "10 suites … three Python" and then listed four, gave
`osk-install-layout` as both 16 and 19, and omitted `test-deck-osk-focus.py`
entirely — a paragraph disagreeing with itself in three places. **Count them;
do not quote them.**)*

**Session 18 (2026-08-10) corrected §2.6 and built T8's core.** It found the
installer row of §2.6 assigning squeekboard to a live ISO that has no Wayland
compositor at all — a carry-over from the superseded decision, contradicting
`docs/findings/T2-gamepad-spike.md` §4, which had measured it. Three more stale
claims went with it (see the §2.6 note and `docs/findings/P17-input-and-osk.md`),
and **§5.21 is new**: `lizard_mode=N` persists nowhere, so a reboot silently
removes STEAM+X and Space.

Then **T8 steps 1–6**: `src/deck_osk_layout.py` (two layers, split halves,
hit-testing, three shift states, `strokes_for_text()`, and **two absolute
cursors** — one per trackpad), **both renderers** — `src/deck_osk_tty.py` for
the installer's bare console and `src/deck_osk_wayland.py` as a **layer-shell
overlay** for Desktop Mode — the mapper declaring `OSK_KEYCODES` on its uinput
device plus `--type` and `--osk-backend {dbus,tty,layer,none}`, and
`stage-input-mapper` installing and **verifying** all three modules by running
them. **60/60 mutations caught.**

The overlay is **verified on Hyprland** (dev machine, not the Deck): a real
layer surface, `hyprctl activewindow` unchanged while it is up, and the whole
chain driven from a virtual pad. It takes **no Wayland input at all** —
`KeyboardMode.NONE` plus an empty input region — because the pad reaches the
mapper over evdev, so the surface only ever draws. That is the property
squeekboard structurally cannot have.

⚠️ **`gtk4-layer-shell` must be loaded BEFORE `libwayland-client`, and under
PyGObject it never is** — `import gi.repository.Gtk` pulls libwayland in first,
and there is no link order to fix because nothing is linked. The failure is
quiet: the process starts, GTK warns, and an ordinary **focusable window**
appears. `deck_osk_wayland` re-execs itself once with `LD_PRELOAD` set. Found by
running it; no test could have seen it.

**Step 7 is coded.** `stage-input-mapper` writes
`ExecStart=… --osk-backend=layer`, so STEAM+X opens our overlay instead of
squeekboard — and **squeekboard stays installed as an automatic fallback**. If
the overlay will not start, or starts and dies, the mapper falls back to it and
says so. That is the entire justification for flipping the default: our overlay
needs a compositor, a preloaded library and a live process, and squeekboard needs
none of those, so without the fallback any one of them failing leaves a
keyboard-less handheld recoverable only over SSH. **Proven, not asserted** — the
e2e suite runs a mapper with `WAYLAND_DISPLAY` unset and checks it fires.
**Rollback is one line:** `MAPPER_OSK_BACKEND=dbus`.

⚠️ **A real regression, recorded rather than hidden:** squeekboard auto-shows on
text focus (§5.20); ours is **summon-only**. Valve's own keyboard is summon-only
too (R-35b), so this matches stock SteamOS, but it is a step back from what the
Deck does today. Ours could bind `zwp_input_method_v2` to learn it — new work,
decided after seeing summon-only in use.

✅ **T8 IS COMPLETE — all seven steps, proven on hardware.**
`docs/findings/P18-osk-hardware-pass.md` (R-43…R-46). Snapshot #8, three modules
installed to `/usr/local/lib/deck-osk/`, the unit rewritten to
`--osk-backend=layer`, and the operator pressed STEAM+X on the Deck and
confirmed it. **Zero fallbacks fired**, so what was on screen was ours rather
than squeekboard.

⚠️ **That confirmation was one argv away from being attached to the wrong
process.** The session had left `--demo` overlays running while debugging, so
"it works" could have described one of those. Settled by the live surface's argv
(no `--demo`) and its parent (the mapper). **When a session has left debug
artifacts on the device, a confirmation names a thing on screen, not a code
path** — resolve which before recording it.

🐞 **The pass found a defect nothing in this repo could see (R-44), now fixed.**
The mapper died every time the pad re-enumerated: `OSError: [Errno 19] No such
device` out of `pad.read()`, **six crashes and nine restarts in one boot**,
against `StartLimitBurst=5`. With `lizard_mode=N` exhausting that limit leaves a
handheld with no pointer and no keys. `ENODEV` is now handed to `pick_device`,
which already waits patiently for a pad to return.
`test/mapper-pad-loss-e2e.py` destroys a pad underneath a live read and was
verified to fail 5 assertions with the fix reverted.

✅ **And T8 step 4's untested half is now answered in QEMU** (R-47…R-49,
`test/vm/vm-osk-tty-test.sh`): the keyboard and a real installer TUI **do share
one console**. `gum` is told via `stty rows` that the console is shorter than it
is, lays out inside that, and the keyboard takes the rows underneath —
`gum.received = hlH1`, mixed case and a digit, typed entirely with the
trackpads and read back from **what gum wrote to a file**, not off the screen.
Observed through `/dev/vcs2`, the kernel's own copy of the console; `tmux
capture-pane` cannot answer this question because tmux would redraw over the
very collision under test.

🐞 **That suite found a second crash of the same family (R-48), now fixed:** a
failed console write killed the whole mapper. `openvt` deallocates a VT when the
program on it exits, so the moment `gum` submitted and quit, `/dev/tty2` stopped
accepting writes and the next redraw was fatal — and **the installer is a
sequence of screens that start and exit**, so it fires in normal use. Drawing a
keyboard is optional; being the only input path is not.

✅ **R-49 RESOLVED, and it was not what it looked like.** The keyboard landing
five rows high was not a placement bug: **`stty rows N` RESIZES a Linux VT**
(`/dev/vcs2` went 8000 → 7200 bytes), so the rows the keyboard was told to use
had ceased to exist and the kernel clamped all five onto the last line, where
they overwrote each other into one garbled row that still greped as a keyboard.
⚠️ **That invalidates the mechanism `write_at` documented** — shrinking the TUI
out of the bottom rows deletes the rows the keyboard needs. `write_at` now
refuses out-of-bounds draws loudly, the mapper measures the console at every
draw, and nothing shrinks the console. Verified: rows 46-50 as requested.

⚠️ **Open, and it matters for the installer:** with no shrinking, nothing
confines a TUI to the top. `gum` uses three rows and coexists happily; **a
full-screen curses TUI like archinstall's menu will draw over the keyboard.**
That is a design fork, not a bug.

⚠️ **Still open by choice:** ours is **summon-only**; squeekboard's
focus-triggered auto-show (§5.20) is still enabled and independent of the mapper,
so both keyboards may appear. Decide after seeing summon-only in use. Also
unproven: the installer's TTY keyboard sharing a console with `gum`/`archinstall`
(TIOCSWINSZ), and typing a full Wi-Fi passphrase end to end. Also unproven: the TTY keyboard and a
TUI (`gum`, `archinstall`) sharing one console, which is what
`deck_osk_tty.write_at`'s TIOCSWINSZ note is about.

⚠️ **A stale `__pycache__` made one mutation run report failures against correct
source.** Python validates cached bytecode against the source's (mtime, size) at
**one-second granularity**, so a same-size edit inside the same second executes
the PREVIOUS version — and mutation testing makes same-size edits deliberately.
Both Python suites now set `sys.dont_write_bytecode = True` before loading
anything. **If a test result ever looks impossible, check for a `__pycache__`
before believing it.**

### 1.1 Artifacts that live OUTSIDE this repo

Too large for git, but real and current. A session that assumes these are
missing will waste an hour rebuilding them.

| Artifact | Where | Notes |
|---|---|---|
| **Omarchy 4.0 beta ISO (ours)** | `~/ISOs/omarchy-2026.08.10-x86_64-quattro.iso` | 6,390,581,248 B, built 2026-08-10 from `omarchy-iso` **`a12bfea`**, sha256 `fbc87422…df03b`. **This is P1.4's ISO** — the one on the Ventoy stick. Rebuild flags: §3.10 |
| 🆕 **Omarchy Quattro beta 2 (upstream's)** | `~/ISOs/omarchy-quattro-beta2.iso` | Downloaded 2026-08-11 with operator approval from `https://iso.omarchy.org/omarchy-quattro-beta2.iso`. 6,390,581,248 B — **the same byte count as ours** — Last-Modified 2026-08-10 13:44:37 UTC. sha256 `8dda1034…1b4a`, **ours, computed after download; upstream publishes no checksum** (§5.22). Content differs from ours in 23 of 24 sampled windows despite the equal size |
| **QEMU substrate image** | `test/images/neptune-substrate.raw` | 14 GB apparent / ~2.9 GB sparse, gitignored. **Rebuilt 2026-08-11 from the `edge` channel** with the boot-chain pin asserted (limine 12.5.2-1, hook 1.37.1-1, snapper-sync 1.31.0-1); all four VM suites green against it. Rebuilt automatically by `test/images/vm-neptune-image.sh` if absent (~6 min) |
| ⚠️ **Previous substrate, kept** | `test/images/neptune-substrate.prev.raw` | The old **`stable`-channel** image (hook **1.36.0-1**). Kept only because it is the A/B control that proved the mtime oracle was invalid, and because rebuilding right now needs a workaround for a broken upstream Arch mirror. **Never point a suite at it expecting the product's boot chain** — that is the exact defect the pin exists to prevent. Delete once the mirror heals |
| **`omarchy-iso` scratch clone** | session scratch — **will be lost** | Had two local deviations worth reapplying if rebuilding: `--network host` on the Docker run (§7's bridge throttle) and a scratch pacman cache instead of the host's (§3.10 item 3) |
| 🆕 **extest, both targets** | `~/ISOs/extest-cb77cd4/libextest-{i686,x86_64}.so` | Built 2026-08-11 at pin `cb77cd4` (v1.0.4, MIT). The i686 one is what T10 preloads into Steam (Steam's input process is 32-bit). Rebuild: `tools/build-extest.sh` — pinned, licence-gated, contained toolchain, needs network once |
| 🆕 **OUR ISO on 4.0.0 stable** | `~/.cache/omarchy-deck/stable-rebase/iso-build-stable/release/omarchy-2026.08.15-x86_64-quattro.iso` | **6,854,164,480 B (6.38 GiB)**, sha256 `e9fbd8edb8c69d698c5e575955a2dd27d4f394a704c7b6b55744a817748368c5`, built 2026-08-15 (session 27), build exit 0, all eight guards green. Carries channel **`stable`**, `omarchy-dev`+`omarchy-settings-dev` **`4.0.0.r1744.gf002044-1`** (= `iso/RUNTIME`'s pin), `omarchy-deck 0.2.0-1`, and **Valve's `gamescope 3.16.25-3`** (the §14.6 fix). **This supersedes the `a27230ff…` ISO** (session 25, beta-2 era). Rebuild env: `OMARCHY_DECK_ISO_BUILD_DIR=…/iso-build-stable`, `OMARCHY_DECK_RUNTIME_SRC=…/runtime-src`, `OMARCHY_DECK_PKGS_SRC=…/pkgs-src` |
| 🆕 **Omarchy 4.0.0 STABLE ISO (upstream's)** | `~/.cache/omarchy-deck/stable-rebase/omarchy-4.0.0.iso` | Downloaded 2026-08-15 (session 27) from `https://iso.omarchy.org/omarchy-4.0.0.iso`. **6,273,040,384 B**, sha256 `9224fab3720560f771969a99a499e5f7e0f8e2d6a0681d872d52f05fb5003da4` — **matches upstream's published v4.0.0 release checksum** (not just our download). airootfs.sfs (extracted alongside) sealed 2026-08-14 16:02:19 UTC. Pin measured from inside it: `docs/findings/T9-stable-pin.md`. Also in that dir: bare clones of omarchy/omarchy-iso/omarchy-pkgs used for the delta |

---

## 2. Scope — decided 2026-08-09/10

Five decisions taken together. They interlock; read them as one.

### 2.1 The ISO is the deliverable

An earlier session deferred T4/T5 to a "v1" and scoped a post-install-script
"v0" (`docs/PLAN.md` §3.1). **That is reversed.** The project is the ISO, per
`docs/PLAN.md` §1 and goals 1–8.

**T2 is back on the critical path.** Its only job is sizing T4, and T4 ships.

### 2.2 Network during installation is acceptable — the offline constraint is retired

`CLAUDE.md`'s "fully offline install" hard constraint is **withdrawn by
operator decision.** The Deck may connect to Wi-Fi during ISO installation.
The reasoning: Steam needs network to sign in regardless (§3.2), so an
offline install buys a device that still cannot reach Gaming Mode usefully.
Paying a large engineering cost to avoid a network dependency that reappears
one screen later was not worth it.

**What this removes:**

- The offline mirror stops being load-bearing. ISO size pressure drops
  sharply — no need to bake every package in uncompressed (§3.3's two risks
  largely evaporate).
- "No AUR anywhere in the install path" stops being a hard rule. *(The
  separate rule against **auto-installing an AUR helper** still stands — it
  caused a real upstream failure. And §2.4's decision does not depend on
  this; it rests on licensing and redundancy.)*
- The pre-Steam Wi-Fi screen stops being an exotic first-boot recovery
  mechanism and becomes a normal install screen, as in SteamOS's own wizard.

**What this makes critical instead — and it is a genuinely new requirement:**

> ⚠️ **Wi-Fi must work in the live ISO environment**, which boots Arch's
> stock kernel and stock `linux-firmware` — *not* Neptune and *not*
> `linux-firmware-neptune`. Every existing piece of evidence that Deck Wi-Fi
> works (session 7's `wlan0` check) was gathered on an installed system
> already running Valve's kernel and firmware. **Nothing yet confirms the
> live ISO can drive the OLED Deck's radio at all.** This is now the single
> highest-value unverified assumption in the project — see §5.1.

The install flow also now depends on the user being able to **type a Wi-Fi
password with a controller**, before anything is installed. That pulls the
gamepad mapper and on-screen keyboard (§3.4) into the *live ISO*, not just
the installed desktop — a dependency T2 must size.

### 2.3 Target Omarchy 4.0 (Quattro), currently in beta

This closes the "which Omarchy does this target" question that had been open
since the first session. **4.0, not 3.x.**

~~⚠️ The test Deck runs Omarchy 3.8.4, installed from git.~~ **No longer true
as of 2026-08-10** — P1.5 rebuilt it onto package-based 4.0, so target and
test asset agree. The paragraph below is kept because it explains *why* T3's
shell integration needs re-verifying on Quickshell.
T1 is immune (it gates on the Limine UKI *mechanism*, never on Omarchy's
packaging — proven on this exact machine). **T3's shell integration is not
immune:** the Desktop Mode icon and the Quick Access Menu hook land differently
on Quickshell than on the 3.x waybar shell.

**Resolved by §2.5:** the Deck is rebuilt onto a fresh, package-based
Omarchy 4.0 in phase 1 (`docs/ROADMAP.md` P1.5) — no in-place upgrade of the git
install, no second device needed.

### 2.4 DeckShift is out — this project ships its own session layer

An earlier session adopted `28allday/deckshift` for session switching. **That is
reversed.** Reasons, in order of weight:

1. **It is unlicensed.** Default copyright: no permission to fork, modify or
   redistribute. An ISO cannot carry it, and §2.1 makes the ISO the product.
   *This reason is independent of §2.2 — retiring the offline constraint does
   not make an unlicensed dependency shippable.*
2. **It pulls `gamescope-session-git` / `gamescope-session-steam-git` from the
   AUR** via `yay`/`paru`, which needs an AUR helper this project will not
   auto-install (it caused a real upstream failure).
3. **Its reason to exist does not apply here.** DeckShift targets generic PCs,
   which have no access to Valve's repos. On Deck hardware, Valve's
   `jupiter-staging/gamescope` already ships the entire SteamOS session (§4.1),
   so DeckShift's core value — sourcing a session — is redundant.
4. **We were already bypassing its core.** The hybrid splice tried on the Deck
   replaced ChimeraOS's session with Valve's, leaving DeckShift supplying only
   glue. Documented in `docs/findings/deckshift-hybrid.md`.

`src/deck-session.sh` — written and hardware-tested before DeckShift was adopted,
then retired — **is restored** as the session layer, with its two known bugs
fixed (§4.2).

### 2.5 Wiping / factory-resetting the Deck is acceptable — decided 2026-08-10

The operator explicitly approved fully restoring the Deck to factory settings
if needed. This retires the "protect the precious install at all costs"
posture and lets the plan *use* rebuilds deliberately:

- **Phase 1** (`docs/ROADMAP.md`): wipe the 3.8.4-from-git install and put a
  fresh, package-based **Omarchy 4.0** on the Deck via the stock ISO — one
  session that answers §5.1, recons the live environment, validates the
  stock→Neptune conversion for real, and clears the DeckShift hand-edits.
- **Phase 3**: factory-reset via Valve's recovery image, then run the full
  release matrix from the exact state a real user starts from — and write
  the recovery documentation while doing it.

**What survives:** every write to the Deck still requires asking first;
snapshots still precede destructive iteration; "never *reinstall to test*"
still holds for day-to-day work — planned rebuilds in `docs/ROADMAP.md` are the
deliberate exception, not a shortcut.

**What this de-urgents:** the `/tmp` backups of the six DeckShift-era
hand-edited files only mattered for restoring the current install's state.
Since that state is scheduled to be wiped, losing them costs nothing.

### 2.6 On-screen keyboard — REVISED TWICE 2026-08-10: squeekboard on the DESKTOP, T8's own OSK in the INSTALLER

> ⚠️ **The original decision below is superseded, and not by preference — by
> measurement.** It routed Desktop Mode's keyboard through Steam. **R-42 proves
> that cannot work on Hyprland at any configuration:** Steam drives desktop
> mouse and keyboard through **XTEST**, which under XWayland cannot move a
> Wayland compositor's pointer or reach Wayland-native clients. Resetting the
> Desktop layout to Valve's default changed nothing, and Steam never created a
> virtual mouse or keyboard device — only the gamepad.
>
> ✅ **The XTEST half is no longer an inference — MEASURED 2026-08-11**
> (`docs/findings/P20-steam-xtest-closure.md`, R-53). XTEST driven directly at
> Hyprland: a Wayland-native client received **nothing**, an XWayland client
> received **`hello`** (positive control), and `XTestFakeMotionEvent` **could not
> move the compositor's cursor** — `(637,672)` before and after. R-42 had
> flagged its own mechanism as *"a strong inference"*; this closes that gap.
> **The reason matters, because stock SteamOS does exactly this**: SteamOS
> Desktop Mode is an X11 desktop where XTEST works, and Omarchy is Hyprland. It
> is an **architecture mismatch, not a tuning problem** — which is why no Steam
> setting was ever going to help.
>
> Worse, a resident Steam is **actively harmful**: it takes the controller and
> removes lizard mode's pointer and keys (R-41), so adopting it costs Desktop
> Mode the only input path that works.
>
> **The revised decision:**
>
> | Where | Keyboard | Pointer / keys |
> |---|---|---|
> | **Installer (live ISO)** | **T8's mapper-drawn OSK** — squeekboard cannot run here | lizard mode |
> | **Desktop Mode** | **squeekboard**, auto-show on focus, until T8 replaces it | **lizard mode** |
> | **Gaming Mode** | Steam's own, native and free | Steam |
>
> **Steam is NOT autostarted.** Launch it when wanted, quit it when done.
>
> ⚠️ **The installer row was wrong here until 2026-08-10 (session 18), and it
> was wrong by carry-over, not by measurement.** R-42 rewrote the *Desktop*
> half; the installer row was inherited from the superseded decision below and
> never re-checked, because R-42 was about Steam. It contradicted a finding that
> already existed: `docs/findings/T2-gamepad-spike.md` §4 inspected the built 4.0
> ISO and found **no Wayland compositor of any kind** — no `hyprland`,
> `gamescope`, `weston`, `sway`, `cage` or `labwc` binary, and no
> `squeekboard`/`wvkbd`. squeekboard is a Wayland client; there is nothing for it
> to be a client *of*. Shipping it in the live ISO means shipping an entire
> compositor stack, which is a far larger change than drawing the OSK ourselves.
> That is why `docs/tasks/T8-onscreen-keyboard.md` exists, and why T2 §4 chose a
> mapper-drawn OSK for the installer months before Desktop Mode needed one.
>
> What this cancels: the `~/.config/autostart/steam.desktop` requirement, and
> the plan to exclude squeekboard from the installed system. squeekboard and its
> two GSettings now ship **on the installed system** — which
> `stage-desktop-settings` already installs as dconf site defaults. ⚠️ **They do
> NOT belong in the live ISO**, where neither has anything to act on: that is
> T8's territory, and T5 should not carry them into the ISO payload on the
> strength of "ships everywhere".
>
> What survives unchanged: **the idle lock stays disabled** (R-38). Whether
> squeekboard can reach a layer-shell lock surface is **untested** — it was seen
> over the *screensaver*, which is not the same surface. Do not re-enable the
> lock on that assumption.

### ~~2.6 (superseded) On-screen keyboard: squeekboard for the INSTALLER, Steam's thereafter~~ — decided 2026-08-10

**Operator decision, session 17**, after both options were tested on hardware
(§5.20, R-35b, R-37).

| Where | Keyboard |
|---|---|
| **The installer (live ISO)** | **squeekboard**, auto-showing on text focus |
| **Gaming Mode** | Steam's own — native to Valve's session, free |
| **Desktop Mode** | **Steam's own, via STEAM+X** — Steam autostarts |

The installer half is forced, not chosen: the live ISO has no Steam and Steam is
proprietary, so Valve's keyboard is unavailable there at any price.

**What this decision requires:**

1. 🐞 **BLOCKED — see R-41 before implementing this.** With Steam resident the
   desktop receives **no input at all**. Every node stays enumerated — both
   lizard-mode nodes *and* Steam's virtual pad — and **not one of them emits**;
   Steam consumes the controller over hidraw and routes it only into its own UI.
   The operator hit this as an unexitable screensaver, recovered over SSH.
   ⚠️ The screensaver is the **symptom**: without it the desktop was equally
   unusable, so raising that timeout hides the defect rather than fixing it.
   R-39's checks all passed while the device was uncontrollable, so **"STEAM+X
   shows the keyboard" is not evidence the desktop is usable.** Either Steam
   Input must be shown to apply a Desktop layout when resident (stock behaviour —
   verify first), or Desktop Mode needs a non-Steam input path, which reopens
   this decision.

   Steam autostarts in Desktop Mode, as `Exec=steam -silent`, via
   `~/.config/autostart/` (already the mechanism in use here — fcitx5 uses it).
   **Validated end to end, R-39:** `-silent` yields 11 processes and **zero
   windows**, Steam registers a tray item, closing a window does **not** quit
   it, and STEAM+X summons the keyboard with no window ever shown.
   ⚠️ **The tray host is load-bearing:** without a StatusNotifier host, closing
   Steam's window *quits* it and Desktop Mode loses its keyboard. Omarchy
   supplies one through the `omarchy.tray` bar widget, so **a bar layout that
   drops that widget silently removes the keyboard.**
   ⚠️ The **STEAM button alone opens Big Picture**, so a mis-timed chord gets
   Big Picture rather than the keyboard. Stock Deck behaviour, not ours.
2. **The mapper must not bind Steam's virtual pad** (R-37). With Steam running it
   currently re-binds to `Microsoft X-Box 360 pad 0` and injects keystrokes on
   top of Steam's own input handling. Needed regardless of this decision.
3. **squeekboard ships in the live ISO only**, not on the installed system —
   along with its two GSettings (`screen-keyboard-enabled`, `input-sources`).

4. **The idle LOCK must be disabled** (R-38), keeping the screensaver. Omarchy
   locks at 300 s with a password prompt, and Steam's OSK — an XWayland window —
   almost certainly cannot render above the layer-shell lock, so an idle Desktop
   Mode would lock a keyboard-less handheld out of itself every five minutes.
   Set in `~/.config/omarchy/shell.json`: `"idle": {"screensaver": 150, "lock": 86400}`.
   ⚠️ **`lock: 0` locks INSTANTLY rather than disabling** — there is no off
   sentinel — and the value has a ~24.8-day ceiling before a QML int32 timer
   overflows.

⚠️ **Accepted risk, chosen deliberately with the alternative on the table: if
Steam is not running in Desktop Mode there is NO text entry at all.** Valve's
keyboard is summon-only and lives inside the Steam client, so a crash, a sign-out,
an update or a user quitting Steam leaves a keyboard-less device with no way to
type — including no way to type into a terminal to fix it. **Recovery is SSH or a
USB keyboard.** A gated squeekboard fallback was offered and declined in favour
of matching stock SteamOS exactly. `docs/RECOVERY.md` should say so plainly.

---

## 3. Findings that changed the plan

These matter more than the code. Each cost real time; a session that does not
know them will waste it again.

### 3.1 `docs/PLAN.md`'s §4/§5 architecture is wrong

`OMARCHY_INSTALLER_REPO` / `OMARCHY_INSTALLER_REF` — the env-var pair §4's
diagram and §5's repo plan are built on — **do not exist** in
`omacom-io/omarchy-iso`. Confirmed by full-repo grep: zero occurrences of the
first; the second appears once, in a `--quattro` flag handler, and is never
read.

Omarchy installs as a **pacman package** pulled from a repo baked into the
ISO's offline mirror, not a git-cloned installer chain.

**Replacement architecture** (from upstream's own in-tree precedents,
`install/hardware/pacman.sh` + `intel/ptl-kernel.sh`):

- fork `omarchy-iso` for build-time changes
- ship the Deck logic as **its own pacman package** for install-time work
- plus one `pre-refresh-pacman.d/` hook for durability — load-bearing, because
  `omarchy-refresh-pacman` **silently overwrites `/etc/pacman.conf` wholesale**
  and would delete the Valve repo entries without it

Also found: an ALPM pre-transaction guard aborts bare `pacman -Syu` unless
`OMARCHY_UPDATE_PACMAN=1` is set. Affects T1 and T3.

### 3.2 Steam cannot work offline — the headline claim is reframed, not dropped

Tested for real in a network-isolated VM. Cold, no client, no network: Steam
fails fatally in under a second and exits. Pre-populating the 2.5 GB client was
**also tested** and does not rescue it — Steam reaches a login screen and then
cannot log in. Login requires network under any packaging strategy.

Redistributing a pre-populated client was checked separately and is not clearly
authorized by Steam's Subscriber Agreement. Every Linux distro ships only the
20 MB launcher.

**Decided:** ship only the launcher, no pre-populated client.

This finding is what ultimately retired the offline constraint (§2.2): if
Steam needs network one screen after install regardless, an offline installer
buys very little for a lot of engineering. The honest claim is now simply
*"connects to Wi-Fi during setup, exactly like a factory-reset Deck."*

### 3.3 The offline mirror can carry Valve packages — no signing step needed

`omarchy-iso` already ships an out-of-tree kernel from an unsigned third-party
repo (`linux-t2` / `[arch-mact2]`, `SigLevel = Never`) into its offline mirror
and boots it. Adding Valve's repos is a structurally identical, already-exercised
edit. **The signing caveat in the original hypothesis does not exist.**

Two *new* risks were identified at the time:

- the mirror is stored **uncompressed**, so every byte adds ~1:1 to ISO size
- the build has a hard package-count self-check (600–2000) whose upper bound
  will need widening

**Both are largely defused by §2.2.** With network available at install time,
the mirror only needs to carry what genuinely must be present before the
network is up — the Deck's own Wi-Fi firmware above all (§5.1). Everything
else can be pulled. Keep the mechanism; shrink the payload.

### 3.4 Gamepad mapping in Desktop Mode — resolved on hardware

**Ship design (b):** a custom `uinput`/`evdev` mapper as a systemd `--user`
service. Design (a) (background Steam) is ruled out by a **circular dependency**,
not a measurement: it sources the on-screen keyboard from a signed-in Steam
client, Steam needs network to sign in, and the pre-Steam Wi-Fi screen needs an
OSK to type the Wi-Fi password. You would need the keyboard to get the network
that provides the keyboard.

Verified on hardware:

- unprivileged `/dev/uinput` creation works with a udev rule — **no privileged
  helper needed**
- controller evdev *read* access already works via seat ACLs
- Hyprland implements the protocols an OSK needs

Two errors in the prepared design were found only by running it:

1. `hyprland-session.target` **does not exist**. Under `uwsm` the real target is
   `wayland-session@hyprland.desktop.target`. A unit wanted by a nonexistent
   target **enables without error and never starts** — it would have shipped,
   reported success, and done nothing.
2. `uaccess` does **not** cover `/dev/uinput` (virtual device, no seat tag).
   **T4/T5 action item: the installer must add the desktop user to the `input`
   group.** `SupplementaryGroups=` is not permitted in a `--user` unit, so this
   cannot be done per-service.

**Use `squeekboard`** (Arch `extra`). The originally-suggested `wvkbd` is
AUR-only.

### 3.5 Secure Boot is a non-issue

Operator-verified on their own Deck: boot order already defaults to Limine, and
the BIOS exposes no Secure Boot toggle at all. No pre-install BIOS step, no
photo documentation needed.

### 3.6 Two real bugs found by the first hardware run of T1

**Bug 1 — snapshot entries miscounted as duplicate boot entries.** The script
counted a UKI basename as a *substring* of the Limine config. `limine-snapper-sync`'s
rollback entries embed the same basename under `limine_history/`, so the count
came back 2 instead of 1 and a correct boot chain was declared broken.

The trigger was **the safety snapshot the hardware task's own procedure
mandates** — anyone following the documented steps hits it. Worse, the same
faulty count defeated the "already up to date" check, so the kernel was
**rebuilt on every run**, inside a pacman hook. The idempotency proven across
six VM suites was real in QEMU and silently false on any real machine with a
snapshot. **Fixed** — the count is now anchored to real `path:` lines under the
ESP's `/EFI/Linux/`.

*The blind spot that hid it is closed (2026-08-10):* `test/images/vm-neptune-image.sh` now
builds a btrfs root with snapper + `limine-snapper-sync` and **one real
snapshot**, so every suite runs against a config with a genuine Snapshots
submenu. Closing it immediately caught the same substring miscount in
`test/vm/vm-kernel-hook-test.sh`'s own probe — the test harness carried the bug it
existed to catch, invisible until the substrate could show it.

**Bug 2 — nothing sets the default boot entry.** The Deck defaulted to the
*stock Arch kernel*; the operator had been selecting Neptune by hand without
that being visible anywhere. Nothing in the toolchain owns `default_entry`.
On a fresh install an end user would silently boot the wrong kernel with
degraded hardware support and no error. **Fixed (2026-08-10):**
`stage-default-entry` writes the entry-*path* form, `reconcile` re-asserts it
on every kernel change, and `test/vm/vm-default-entry-test.sh` proved the path form is
genuinely honoured — a **non-first** entry planted as default is the entry
Limine actually selected (`LoaderEntrySelected`) and booted (`uname -r`), so
the observed behaviour cannot be an index-1 fallback. The operator's Deck
still carries the hand-applied fix; the script's version runs on it at P1.5.

### 3.7 Prior art does not duplicate this project

`28allday` (a.k.a. no-signal.uk) ships `deckshift` (unlicensed),
`omarchy-deck-iso` (**MIT**), `omasteam` (MIT), and the superseded
`Super-Shift-S-Omarchy-Deck-Mode` (unlicensed) that `docs/PLAN.md` §5/§6.4 names as
the fork base. **None of them target Steam Deck hardware** — all are
"Deck-*style* gaming mode on a generic PC", no Neptune kernel, no Valve
firmware, no Jupiter/Galileo detection, and DeckShift explicitly handles NVIDIA.
Bazzite and ChimeraOS solve Deck hardware but not Omarchy.

**So this project's differentiator — real Deck hardware plus Omarchy — is not
duplicated.** That is the answer to the prior-art check `docs/PLAN.md` §2 demanded.

**Still worth reusing:** `omarchy-deck-iso` is MIT and is structurally already
T5's architecture — a thin Omarchy fork, an offline mirror, post-install steps.
A legitimate base even though it has no Deck hardware support.

### 3.8 A bare `pacman -S steam` installs NVIDIA drivers on a Steam Deck

`steam` depends on the *virtual* `lib32-vulkan-driver`. With no 32-bit AMD
provider installed, pacman picks the NVIDIA stack on its own — `nvidia-utils`,
`egl-wayland`, `egl-gbm`, `egl-x11`. Naming `lib32-vulkan-radeon` explicitly
drops them to zero. **Nothing errors.**

**T5 must pin `lib32-vulkan-radeon` in the package list**, or every offline
install ships several hundred MB of unused NVIDIA driver in an uncompressed
mirror, on AMD-only hardware.

---

### 3.9 A gamepad can drive the installer — T4 is days, not weeks

`docs/findings/T2-gamepad-spike.md`. A ~200-line `uinput`/`evdev` mapper
(`src/deck-input-mapper.py`) drives `gum` prompts and `archinstall`'s curses menu
with **no cooperation from either** — proven in QEMU through the real
delivery path (virtual pad → mapper → virtual keyboard → **kernel VT** →
tmux client → pty → TUI), asserting on rendered text *and* outcome.

**This is the good branch of `docs/tasks/T2-gamepad-input-spike.md`'s fork:** T4 becomes configuration
(reduce prompts, set defaults, map buttons, glyphs) rather than bespoke
gamescope-hosted Quickshell screens. The same mapper also serves T3's Desktop
Mode (R1 §10.3 design (b)) — one artifact, two consumers.

**The open gap is text entry**, and only two screens need it: the Wi-Fi
password (§2.2 put it on the critical path) and account credentials.
**Now decided (2026-08-10):** the built 4.0 ISO's live environment has **no
Wayland compositor at all**, so `squeekboard` is out there — T4 ships a
**mapper-drawn OSK** that renders on a bare TTY and types through the
virtual keyboard the mapper already owns. `squeekboard` remains correct for
Desktop Mode under Hyprland; the two contexts get different answers.

⚠️ **The real Deck controller's event codes are not yet known** — the spike
used a virtual pad modelling the Linux gamepad ABI. P1.5's recon captures
them. Expect mapping-table entries to change; the mechanism will not.

### 3.10a 🔴 THE FOURTH GOTCHA, and the biggest: the ref and the channel are TWO pins

**Measured 2026-08-11 (session 19).** §3.10 item 1 said the ref and the mirror
"must agree". That understates it. `builder/build-iso.sh` downloads the Omarchy
runtime **from the package channel at build time**, so a build is pinned by two
independent things and **only one of them is expressible in git**:

- `omarchy-iso` at a git SHA — pinnable, ours.
- the `edge` channel's `omarchy-dev`, which is **whatever it serves that hour**.

They already disagree. Our ISO and Omarchy's beta 2 were both cut at
`omarchy-iso@a12bfea` with runtime `r1617.g6d7826d`, which ships
`omarchy-setup-system`. **`edge` today serves `r1652.g1c9dfc5`, 18 commits past
a rename to `omarchy-apply-system`.** So **forking at `a12bfea` and building
today produces an installer that calls a binary the runtime no longer has** —
and it dies at the fifth install phase, *after* partitioning and pacstrap.

*(The rename pair, 27 seconds apart: `basecamp/omarchy@536fcd5c` 21:14:57Z →
`omarchy-iso@d6cd2d30` 21:15:24Z. Upstream moved both halves together; anyone
pinning only one half gets the mismatch.)*

⚠️ **Consequence for reproducibility:** the beta 2 ISO on disk is a **time
capsule**. It cannot be rebuilt from its own git SHA. Pin the runtime with
`omarchy-iso-make --local-source` (upstream's own supported path) rather than
trusting a channel.

### 3.10 Building the Omarchy 4.0 ISO — three gotchas for T5

Found while producing a 4.0 beta ISO for P1.4 (`omarchy-iso` @ `a12bfea`).
T5 forks this builder, so these are its inheritance:

1. **`OMARCHY_ISO_REF` and `OMARCHY_MIRROR` must agree, and the defaults do
   not.** A bare `omarchy-iso-make` uses ref `quattro` (which selects the
   `omarchy-dev` runtime package) with mirror `stable` — whose `omarchy-dev`
   predates `install/provisioning/setup-form.sh`. Build with
   `OMARCHY_MIRROR=edge` (what the `--quattro` flag sets) or the two channels
   disagree.
2. **Upstream's guard is a model worth copying.** Rather than shipping an ISO
   whose configurator has no prompts, the build **fails loudly**: *"this ISO
   would boot into an installer with no questions to ask."* That is exactly
   the discipline `docs/PLAN.md` §8.1 wishes more tooling had — T5's fork must not
   weaken it.
3. **⚠️ The build bind-mounts the HOST's `/var/cache/pacman/pkg` read-write
   into a privileged container, and `omarchy-iso-make` `sudo rm -rf`s it
   before every build.** On this dev machine that cache holds 2700+ packages.
   A truncated `omarchy-keyring` download did land in it once (pacman
   self-healed on the next run by deleting it). **Local builds here point the
   container at a scratch cache dir instead** — same rebuild speed, no blast
   radius on the developer's system. T5's fork should do the same rather than
   inherit the `rm -rf`.

## 4. T3 — the session layer

### 4.1 Valve already ships the entire Gaming Mode session

`jupiter-staging/gamescope` 3.16.25-3 (Valve's own build, packager
`ci-package-builder-1@steamos.cloud`) provides:

```
/usr/share/wayland-sessions/gamescope-wayland.desktop   the session entry
/usr/bin/start-gamescope-session                        the entry point
/usr/lib/steamos/gamescope-session                      the real launcher
/usr/lib/systemd/user/gamescope-session.target          the unit graph
  + gamescope-session.service, steam-launcher.service, ibus-gamescope.service,
    steam-notif-daemon.service, gamescope-mangoapp.service,
    galileo-mura-setup.service  (OLED mura correction — Deck-specific)
```

All verified present on the Deck. `/usr/lib/steamos/gamescope-session` also
handles HDR, VRR, fan control, dynamic backlight and mangoapp.

**This is why `docs/PLAN.md` §6.4's "fork Super-Shift-S, it solves the hard part" is
obsolete.** It was true when written. Valve supplies the session; this project
supplies only the *switch*. `mangohud`/`lib32-mangohud` are needed for
`mangoapp`, which the session references but the package does not pull.

**Withdrawn:** the earlier "T5 must build pre-built `gamescope-session*`
packages for the offline mirror" requirement. T5 just needs
`jupiter-staging/gamescope` in the mirror, which §3.3 already established is
straightforward.

### 4.2 Exactly one piece is missing: `steamos-session-select`

Checked with `pacman -F` across core, extra, multilib, omarchy,
jupiter-staging and holo-staging: **`steamos-session-select` is in no configured
repo.** It lives in SteamOS's `steamos-customizations`.

Steam's "Power → Switch to Desktop" shells out to it *by name*. Without it,
Steam's own affordance **silently does nothing** — `docs/PLAN.md` §8.1's failure mode,
in the one place a controller-only user cannot work around it.

`src/deck-session.sh` supplies it, plus the path back. Two bugs from its first
version are fixed:

1. **The SDDM drop-in never won, on any machine.** The file's own comment
   claimed `95-deck-session.conf` "sorts after Omarchy's `autologin.conf`". It
   does not — `9` < `a`, so `autologin.conf` always overrode it. Undetected
   because Gaming Mode had never been booted. **The bug was in a comment
   asserting an ordering nobody checked.** Fixed by sorting last (`zz-`).
2. **The NOPASSWD verification passed on a warm sudo credential cache**, so it
   proved nothing. Fixed: clear the cache before probing, and detect the case
   where the user has blanket NOPASSWD (which makes the probe vacuous) and say
   so rather than claim verification.

Neither was caught by the file being shellcheck-clean, idempotent, and passing
its own tests.

### 4.3 What is confirmed on hardware, and what is not

**Confirmed:** Gaming Mode has been entered on the Deck once, and a
return-to-desktop button was present. That is the first gamescope session ever
started on this machine.

**Not confirmed, and must not be recorded as passing:** whether controller input
works in Gaming Mode, whether audio works there, and whether the return button
*functions* as opposed to merely appearing. The last is the one that exercises
the `steamos-session-select` shim and is the controller-only path out.

**Note:** that confirmation was obtained with the DeckShift hybrid in place.
Under §2.3 that hybrid is being removed, so it is evidence that *Valve's session
starts on this hardware* — not evidence about this project's own switch layer.

---

## 5. Open issues

Ranked by what they would cost to discover late.

### 5.0 🔴 **P1 — the OSK mapper is not in the live ISO** (found 2026-08-15, session 28)

**The controller-only install cannot be completed keyboard-free on real
hardware.** `deck-form.sh` launches `/usr/local/bin/deck-input-mapper
--osk-backend=tty --osk-start-shown` to draw the on-screen keyboard, but that
binary — and its `python-evdev` dependency — was never shipped into the live
airootfs (only onto the *target*, post-install, by `deck-session.sh`). So every
text-entry screen (Wi-Fi password, account username, account password,
hostname) comes up with no way to type. Degrades correctly and loudly (Skip /
attach a keyboard), but the central `CLAUDE.md` constraint is unmet. Found on
the FIRST hardware boot of the stable ISO; QEMU could not see it (virtio NIC
skips Wi-Fi; the harness drove the form's functions, not a live tty). **Fix
deferred to after the P3.2 hardware pass** (being completed with a USB keyboard
attached). Full mechanism, blast radius, and fix outline:
`docs/findings/P32-osk-mapper-missing-from-live-iso.md`.

### 5.1 Wi-Fi in the live ISO — ✅ **RESOLVED 2026-08-10, confirmed on hardware**

**Answer: YES.** On the OLED Deck (Galileo), the 4.0 beta ISO's live
environment drives the radio end to end — driver binds, scan, WPA2
association, DHCP. Evidence and full recon: `docs/findings/P15-live-iso-recon.md`
(§R-0), raw logs in `docs/findings/P15-recon-raw/`.

⚠️ **The conclusion was right but the reasoning below was wrong.** The Deck's
chip is **QCA2066 hw2.1**, not QCNFA765; the firmware that served it lives at
`ath11k/QCA2066/`, *not* the `WCN6855/.../nfa765/` path this section watched.
Anything that prunes firmware must keep `ath11k/QCA2066/` — pruning on the
old reasoning would have broken the radio. See the finding's §R-6.

Retired by this result: T5's "bake firmware into the live image" mitigation,
and the ROADMAP's "live ISO can't drive the OLED radio" standing risk.

**Still open:** this was association from a shell with a keyboard. It does
not prove a *controller-only* user can join Wi-Fi — that needs T4's text
entry, and §R-8 changed what that has to be built on.

<details><summary>Superseded pre-hardware reasoning (kept for the audit trail)</summary>

Introduced by §2.2: the install now depends on the Deck reaching Wi-Fi *from
the ISO*, whose live environment runs its own kernel and firmware, not
Neptune's.

**Substantially de-risked 2026-08-10 by inspecting the built 4.0 ISO**
(`~/ISOs/omarchy-2026.08.10-x86_64-quattro.iso`). Its `airootfs.sfs`
carries, in the live environment:

```
usr/lib/firmware/ath11k/WCN6855/hw2.0/nfa765/{amss.bin,m3.bin}   <- QCNFA765
usr/lib/firmware/ath11k/WCN6855/hw2.1/nfa765/{amss.bin,m3.bin}
usr/lib/firmware/ath11k/WCN6855/hw2.{0,1}/board-2.bin            <- per-board cal
usr/lib/firmware/ath11k/WCN6855/hw2.{0,1}/regdb.bin
kernel/drivers/net/wireless/ath/ath11k/*                         <- the driver
usr/bin/iwctl + iwd.service                                      <- association
```

The **`nfa765`** directory is the notable part: that is QCNFA765, the OLED
Deck's Wi-Fi module, with firmware variants named for it specifically. The
driver, the per-board calibration blob (`board-2.bin` — the usual failure
point when a device is *almost* supported), the regulatory database and the
association tooling are all present.

Live kernel is `7.1.6-arch1-Watanare-T2-1-t2` — the `linux-t2` kernel
`omarchy-iso` already ships from `[arch-mact2]` (§3.3), not stock Arch.

**Still not proof.** Firmware being present does not prove the driver binds
to this device's PCI ID, nor that association succeeds. **P1.5 confirms it
on hardware** — but the expected answer is now "yes", and the recon knows
exactly what to check (`dmesg | grep ath11k`, does `wlan0` appear, does
`iwctl station wlan0 scan` return networks).

While in the live environment, still record for T4/T5:

- **Display rotation.** The Deck panel is portrait-native; the live ISO may
  render rotated 90°.
- **Input enumeration** — what the controller looks like to the live kernel
  (`/proc/bus/input/devices`), which the T2 mapper's tables need (§3.9).

</details>

*(Both recon items above are now answered — see §5.9.)*

### 5.9 ⚠️ It re-scopes T4: the gamepad node is silent in the live ISO

> ⚠️ **Session 16 addendum — the event numbers below are LIVE-ISO ONLY.** On the
> installed system the same roles sit on different nodes: buttons on `event6`
> (not `event5`), trackpads on `event5` (not `event4`), the real gamepad on
> `event7` (not `event11`), and the device is named **`"Steam Deck"`**, not
> `"Steam Deck Controller"`. Anything hardcoding these numbers binds the wrong
> device. `src/deck-input-mapper.py` selects by *capability* (`BTN_SOUTH`),
> which is why it is unaffected. Full enumeration:
> `docs/findings/hardware-parity.md`.

Measured 2026-08-10 (`docs/findings/P15-live-iso-recon.md` §R-8). With Steam not
running, the Deck's controller firmware is in **lizard mode**, and lizard mode
is **exclusive, not additive**:

- Buttons emit **only** on the keyboard-emulation node (`event5`): A → `KEY_ENTER`,
  D-pad Up → `KEY_UP`. Trackpads emit mouse motion on `event4`. Touchscreen works.
- The real gamepad node (`event11`, the one carrying `BTN_SOUTH`) emits
  **nothing at all** — zero events across a 90-second capture with six button presses.

**Why this matters:** `src/deck-input-mapper.py` selects its device by testing
for `BTN_SOUTH` (`src/deck-input-mapper.py:177`), i.e. exactly the dead node. In the
live ISO it would open a pad and then block forever on a device that never
sends an event — succeeding silently while doing nothing, the failure mode
`CLAUDE.md` explicitly forbids. The T2 spike could not have caught this: it
drove a virtual uinput pad, with no Valve firmware in the loop to divert the
events.

**Upside:** the live ISO is *already* controller-navigable for free — mouse,
Enter, arrows, touchscreen — so T4's installer may not need a mapper to be
operable at all. Text entry (the Wi-Fi passphrase) remains the real gap.

**Decide before writing T4 code:** use lizard mode and map only what it
cannot express, or suppress it (via `hid-steam`'s hidraw behavior —
unverified) and lose the free mouse/keyboard. Recommendation in the finding:
use it.

> ### 🆕 Session 17 measured the whole map, on the installed system, with a human
>
> `docs/findings/P17-input-and-osk.md` R-29…R-31. Three things this section could
> not say:
>
> 1. **Lizard mode holds on the installed system too**, not just the live ISO —
>    and it swallows **X, Y, L1, R1, STEAM and QAM entirely**. Those six report
>    on **no evdev node at all**, so no user-space program can recover them.
> 2. **It gives Enter, Esc, Tab, arrows and both mouse buttons — but NO Space.**
>    `Y → KEY_SPACE` (archinstall's multi-select toggle) is precisely what the
>    mapper exists to add, so "already navigable" is true for movement and
>    confirmation and **false for toggling**.
> 3. **The suppression question is answered and no longer "unverified":**
>    `/sys/module/hid_steam/parameters/lizard_mode` is a documented, writable
>    module parameter. `N` silences the emulated nodes and makes `event7` fully
>    live, including the six swallowed buttons. It does **not** persist across a
>    reboot.
>
> So the decision above is now a real trade with both sides measured: keep
> lizard mode and lose Space, or drop it and lose the free pointer, making the
> mapper the *only* input path. **The mapper must be proven working before
> anything sets `lizard_mode=N`,** or the device is uncontrollable without SSH.

### 5.10 ✅ Steam's "Switch to Desktop" menu item — **RESOLVED 2026-08-10, proven on hardware**

**Closed by session 15.** With a signed-in Steam, Power → **Switch to Desktop**
is present, Steam invokes our shim, and the switch completes into Omarchy.
Details: `docs/findings/P2-steam-integration-and-rotation.md` §R-23.

There were **two** independent causes, not the one §5.10 assumed:

1. **Steam was stuck in OOBE** behind §5.14's updater error, which reduces the
   Power menu. The hypothesis was right, and fixing §5.14 released it.
2. **The shim was unreachable anyway.** The Steam runtime narrows `PATH` to
   exactly `/usr/bin:/bin` (`SYSTEM_PATH` unset, so the `${PATH}` fallback
   applies). `/usr/local/bin` — where the shim lived since P1.5 — is not on it.
   This answers R-18a's open question: the shim **had** to move to `/usr/bin`,
   and "Switch to Desktop" could never have worked before, menu item or not.

Also confirmed: **Steam passes `plasma`, not `desktop`** (SteamOS's desktop is
KDE). `deck-session-select` already handles `desktop|plasma|omarchy`, so this
worked by design — do not "simplify" that case away.

⚠️ Exercising this path also exposed §5.16, which could leave the Deck with no
session at all. Read that before treating the switch as robust.

### 5.11 ✅ ROTATION — ALL FOUR SURFACES FIXED AND SEEN, 2026-08-11

**Every surface is now correct on the panel, and the four values disagree with
each other. Do not infer any one of them from another — two were guessed wrong
in exactly that way.**

| Surface | Mechanism | Value | How it was settled |
|---|---|---|---|
| Desktop | `hl.monitor{ transform = … }` in `~/.config/hypr/monitors.lua` | **3** | `1` rendered it upside down (session 15) |
| Greeter | sddm drop-in | — | §5.11 original, below |
| **Limine menu** | `interface_rotation:` in `/boot/limine.conf` | **90** | 🆕 **`270` rendered it UPSIDE DOWN**, seen on the panel 2026-08-11. `270` was the recorded hypothesis |
| **TTY** | `fbcon=rotate:1` in the kernel cmdline | **1** | 🆕 correct first try, seen on the panel 2026-08-11 |

**Two of the four recorded hypotheses were 180° wrong.** The desktop's `1` and
Limine's `270` were both inferences that had never been rendered. There is no
formula relating these values; each is its own mechanism with its own convention.

🆕 **Where the Limine change lives, and why it survives.** `interface_rotation`
is a *global* in `/boot/limine.conf`, a file whose entry blocks are stamped
"auto-generated by limine-entry-tool" — so the obvious fear is that a hand edit
is silently regenerated away. **Measured: it is not.** `limine-update` was run
(it reported `Updated: /boot/limine.conf`, regenerating both UKIs) and
`interface_rotation: 90` was **still present afterwards**. The header is
user-owned; the tool rewrites only the entry blocks.

🆕 **Where the TTY change lives.** A **drop-in**,
`/etc/limine-entry-tool.d/50-deck-fbcon-rotation.conf`, containing
`KERNEL_CMDLINE[default]+=" fbcon=rotate:1"` — **not** an edit to
`omarchy-defaults.conf`, which belongs to Omarchy and would be lost to a package
update. `/etc/limine-entry-tool.d/*.conf` is the documented seam, and `+=` is
required because `/etc/default/limine` overrides drop-ins. Verified after
`limine-update`: `fbcon=rotate:1` appears in **both** kernel entries and in the
running `/proc/cmdline` after a reboot.

⚠️ **T5 owes three bake-ins here, not two** (`T5-fork-plan.md` §5.2 says "both
rotations"): `monitors.lua`'s `transform = 3`, `limine.conf`'s
`interface_rotation: 90`, and the `fbcon` drop-in.

🆕 **The installed system's TTY is `25 80`.** The live ISO's is `50 160`
(§7). Same panel, four times the area, different environment — **read the
console geometry at runtime; never hard-code either number.** ⚠️ The installed
system's TTY was not measured *before* the `fbcon` change, so 80×25 is not
attributable to the rotation.

*(Original section follows.)*

### 5.11 (original) 🟡 Rotation — desktop and greeter FIXED; Limine menu and TTY still open

`fbcon/rotate` is **0** on stock Arch *and* on Neptune, so no kernel this
project ships corrects the panel and the fix is per-surface, in userspace.

| Surface | Status | Fix |
|---|---|---|
| Limine menu | 🟡 **fix identified, NOT applied** | `interface_rotation: 270` — Limine ≥ v10; Deck runs **12.5.2**. Boot-chain change, held for approval. See below |
| Console / TTY | ❌ rotated | `fbcon=rotate:1` on the cmdline — boot-chain change, **held for operator approval** |
| SDDM greeter | ✅ **fixed, seen** | `stage-greeter-rotation` in `src/deck-session.sh` |
| Omarchy / Hyprland | ✅ **fixed, seen** | `~/.config/hypr/monitors.lua` |
| Gaming Mode | ✅ correct | none needed — gamescope handles it |

**Three corrections to what was recorded here** (details:
`docs/findings/P2-steam-integration-and-rotation.md` §R-24):

- **The transform is 3 (270°), NOT 1.** `transform,1` renders the desktop
  **upside down**. The old value was inference, never checked against a screen.
- **The syntax was 3.x.** Omarchy 4.0 configures Hyprland in **Lua**
  (`~/.config/hypr/monitors.lua`, `hl.monitor({…})`); the recorded
  `monitor = eDP-1,…` line would not have parsed. Hyprland 0.56's Lua parser
  also **rejects `hyprctl keyword`** — use `hyprctl eval 'hl.monitor({…})'`.
- **NEW, a second display defect:** Omarchy's `scale = "auto"` resolves to **2**
  on this panel, leaving a **640×400 logical desktop**. Now **1.25** (1024×640,
  divides 1280×800 evenly). `GDK_SCALE` went 2 → 1 to match, or GTK apps render
  ~2.5× and clip.

### The Limine menu CAN be rotated — `interface_rotation` (session 16)

§5.11 recorded "no known fix yet". There is one. Limine has a global
**`interface_rotation`** taking `0`, `90`, `180`, `270`, default `0`, which
rotates the menu/editor/console **only** — it does not affect the booted OS.
It needs **Limine ≥ v10**; the Deck runs **12.5.2**, and other `interface_*`
globals are already in its config, so the option is available today.

```
interface_rotation: 270
```

`270` to match the desktop's `transform 3`. ⚠️ **Unverified against a screen** —
§5.11's whole history is a recorded transform value that turned out upside down,
so treat the number as a hypothesis until someone looks at the panel.

**⚠️ NOT APPLIED.** Editing `/boot/limine.conf` is a boot-chain change, and this
project holds those for operator approval (same rule as `fbcon=rotate:1`).

**Where it has to go, which is the non-obvious part.** Three things write that
file:

| Writer | Behaviour |
|---|---|
| `limine-entry-tool` (binary) | manages **entries** and `default_entry`; leaves other globals alone |
| Omarchy theming | writes `interface_*` / `term_*` globals |
| **`omarchy refresh limine`** | **`mv`s `/boot/limine.conf` aside and copies `/usr/share/omarchy/default/limine/limine.conf` over it** — a hand edit is destroyed |

So a hand edit to `/boot/limine.conf` survives kernel updates but **not**
`omarchy refresh limine`. For the product, **T5 must bake `interface_rotation`
into the image**, exactly as it must for the desktop's `monitors.lua` below —
same class of problem, same fix.

⚠️ **The desktop half is per-user config** (`~/.config/hypr/monitors.lua`), so it
is currently fixed only for `deck` on the test Deck. **T5 must bake it into the
image** — `/etc/skel/.config/hypr/` or an Omarchy default — or a fresh install
comes up rotated again.

### 5.12a 🔴 Turning encryption off DELETES autologin — they are one change

**Measured 2026-08-11 (session 19), reading upstream's installer.**
`configure_login` writes `autologin.conf` **only `if ctx.encrypt`** — on an
encrypted install LUKS is the authentication boundary, so SDDM is allowed to
log straight in. Turn encryption off, as §5.12 requires, and **autologin
disappears with it.**

**That trades an unanswerable LUKS passphrase prompt for an unanswerable SDDM
password prompt** — i.e. it re-creates §5.18, the defect that cost session 16
a full debugging pass, by way of our own fix for a different defect.

⚠️ **T5 must treat "encryption off" and "autologin on" as a single change with
a single test.** Neither is safe alone on a keyboard-less handheld. Full detail
and the verification tier: `docs/tasks/T5-fork-plan.md`.

### 5.12b 🐞 `/etc/skel` is too late — the user already exists

Upstream's `useradd` runs inside `arch_install_system`, **phases before** any
post-finalizer hook. Anything seeded only into `/etc/skel` by a later hook
reaches nobody. Every per-user file the image must ship — the rotation
`monitors.lua`, `shell.json`'s idle policy — has to be written to **both**
skel *and* the created user's home, **and the home copy is the one to verify.**

### 5.12 The 4.0 installer defaults to FULL-DISK ENCRYPTION

Left unchanged, our fork ships a device that **stops at a passphrase prompt
with no keyboard** — unbootable for its intended user, and contradicting
`CLAUDE.md`'s controller-only rule. Recommendation: default OFF, treat TPM2
auto-unlock as a follow-on, not a release blocker. §R-11.

Upstream's installer is fully driveable from a config file, and accepts
`--authorized-keys-file` / `--tailscale-authkey-file` — a better T5
integration point than post-install scripting, and it makes automated QEMU
install testing tractable.

### 5.13 ✅ `stage-repos` repo ordering — AUDITED and RESOLVED 2026-08-10

Valve's repos are appended **after** `[extra]`, and pacman resolves `-S <name>`
by **repo order, not version**, so `pacman -S gamescope` installs Arch's build
(bare compositor) instead of Valve's (the whole SteamOS session). The defect is
real. The proposed fix — Valve's repos first, matching SteamOS — is **rejected
on measured evidence**. Full data: `docs/findings/P16-repo-overlap-audit.md`.

**101 package names overlap; Valve's is OLDER in 50 of them**, including
`filesystem` 2021.12.07 (vs 2025.10.12), `linux-lts` 5.15.74 (vs 6.18.43),
`plymouth` 22.02 (vs 26.134), and the whole `mesa`/`vulkan-*`/`lib32-vulkan-*`
stack — the three suspects this section named all confirm. Decisively: the test
Deck runs **Arch's** `mesa` and `vulkan-radeon` and Gaming Mode works, so
Valve's are not merely riskier, they are unnecessary.

**The blast radius is one package.** Everything `omarchy-deck-kernel.sh`
installs (`linux-neptune-611`, its headers, `linux-firmware-neptune`,
`steamdeck-dsp`) is **Valve-only**, so order never affected it. Of the 51
"Valve newer" overlaps, nearly all are Valve rebuilds of identical upstream
versions (`systemd 261.2-1.1` vs `261.2-1`); only **`gamescope`** differs in
substance (Valve `3.16.25-3` ships the session, Arch `3.16.25-1` does not).

**Fix adopted: qualify the package, do not reorder repos.**

```bash
pacman -S jupiter-staging/gamescope     # not: pacman -S gamescope
```

⚠️ Valve's gamescope is *newer* and pacman still picks Arch's — order beats
version. Don't conclude from "Valve's is newer" that the bug can't bite.

Two follow-ons: **`mangohud` should come from Arch** (its `0.8.4-1` is newer
than Valve's `0.8.3…-4` and already ships `/usr/bin/mangoapp`, verified on the
Deck); and `deck-session.sh`'s precondition already catches the wrong build,
because it tests for the session *file*, not a version — the two builds share
an upstream version, so a version check could not tell them apart.

### 5.14 ✅ Gaming Mode's update check — **RESOLVED 2026-08-10 with a stub**

**Closed by session 15.** Operator chose the stub option. Steam's log now reads
`steamos-update check … returned: 7` → **`up to date`**, and the false network
error is gone. Details: `docs/findings/P2-steam-integration-and-rotation.md`
§R-21.

**Two corrections to what was recorded here:**

- Steam does **not** resolve this through `PATH`. It calls the absolute path
  `/usr/bin/steamos-polkit-helpers/steamos-update`, so a stub in
  `/usr/local/bin` would have installed cleanly and changed nothing.
- **`steamos-customizations-jupiter` would not have supplied it.** That package
  *is* available in `jupiter-staging`, but ships **zero** polkit helpers — it is
  GRUB machinery. The reasoning here named the wrong package.

⚠️ **Exit codes are a protocol, and 0 is dangerous.** `check` must exit **7**
("up to date"); **the apply path must NOT exit 0** — Steam reads 0 as "an update
was applied" and **reboots the device**, once per OOBE pass. That happened once
on the Deck before it was caught. The stage now asserts apply is non-zero.

This closed only *one* helper. The wider surface is **§5.15**.

### 5.15 🟡 Steam's privileged-helper surface — the two user-visible ones are SHIPPED; the rest is deliberately skipped

**Updated 2026-08-10, session 16 (P2.0b).** `steamos-set-timezone` and
`steamos-priv-write` are now installed by `src/deck-session.sh`
(`stage-timezone-helper`, `stage-priv-write-helper`), both hardware-verified
with a real change and restore. The operator decided **not** to take
`jupiter-hw-support`, so the six `jupiter-*` helpers stay absent — none has a
user-visible effect yet, and `jupiter-fan-control` belongs to P2.3, which
needs per-item approval anyway.

⚠️ **The reasoning recorded below was wrong in a way worth keeping.** It said
the missing `steamos-priv-write` means "the Gaming Mode brightness slider does
nothing". **On the test Deck the slider works.** Steam does not give up when a
helper is missing — it falls back twice, measured from its own console log:

```
1.  /usr/bin/steamos-polkit-helpers/steamos-priv-write "<path>" "<value>"   -> 127
2.  echo "<value>" | sudo -n tee "<path>"                                   -> works
3.  sudo -n chmod a+w "<path>"                                              -> works
```

Tiers 2 and 3 succeed **only** because `/etc/sudoers.d/99-deck-testing` grants
`deck ALL=(ALL) NOPASSWD: ALL` — see §5.17. So the conclusion about the
*product* was right and the belief about the *present* was wrong, which is the
more dangerous half: anyone "verifying" this by moving the slider on this Deck
would have concluded there was no bug.

Tier 3 is also why `/sys/class/backlight/amdgpu_bl0/brightness` and
`/sys/class/leds/status:white/led_brightness_multiplier` are **mode 666**,
restamped every Gaming Mode start. That is Steam's doing, not a hand-edit.
Supplying tier 1 is therefore a **security** change as much as a feature: it
stops Steam reaching for blanket sudo and stops the `chmod`.

**The narrow grants are proven operative** — measured 2026-08-10 with
`99-deck-testing` temporarily removed (§5.17), so nothing else could have
authorized them. Both helpers still changed brightness and timezone, and
`steamos-priv-write` still refused `/etc/shadow` with real privilege on the
line.

Not whitelisted on purpose: **`/dev/drm_dp_aux0`**, which Steam asks to write
with an *empty* value. What that does is not understood, so the helper refuses
it loudly. Steam has been getting 127 for it all along and tolerates it.

<details><summary>Original §5.15 text (kept for the audit trail — its "the slider does nothing" premise is corrected above)</summary>

§5.14 was one symptom of something larger. Steam drives system functions through
helpers at **`/usr/bin/steamos-polkit-helpers/`**, invoked by **absolute path**.
That directory does not exist here, so every call returns 127. Fourteen are
compiled into the client; **eight were actually invoked** in one OOBE session.

The two with real user impact:

- **`steamos-priv-write`** — how Gaming Mode writes
  `/sys/class/backlight/amdgpu_bl0/brightness`. Its absence means **the Gaming
  Mode brightness slider does nothing**, and it explains why R-14a's "backlight
  comes up at 1%" cannot be corrected from the UI. Same root cause.
- **`steamos-set-timezone`** — called 28 times; OOBE's timezone picker silently
  fails. Probably a three-line helper (`timedatectl set-timezone`) and the
  cheapest real win here.

Also missing: `steamos-devkit-mode`, `jupiter-get-als-gain` (ALS),
`jupiter-dock-updater`, `jupiter-biosupdate`, `jupiter-fan-control`.

**What is available:** `jupiter-hw-support` (`jupiter-staging`) ships six of them
with Valve's own code — but it is 49 MiB download / 94 MiB installed and depends
on **plymouth** on a Limine-only system. The `steamos-*` ones are in no repo.

**Decision needed, not taken.** `steamos-priv-write` in particular is a root
helper that writes caller-supplied sysfs paths; Valve's whitelists them and ours
would have to. That is a security design, not a stub — and `jupiter-fan-control`
lands in P2.3, which requires per-item operator approval every time.

Full inventory and options: `docs/findings/P2-steam-integration-and-rotation.md`
§R-20.

</details>

### 5.17 🐞 NEW — `99-deck-testing` gives the desktop user blanket passwordless sudo, and it is masking real defects

`/etc/sudoers.d/99-deck-testing` contains:

```
deck ALL=(ALL) NOPASSWD: ALL
```

Owned by **no package** — a test-rig file, almost certainly added during P1.5
so the `tools/deck-sync.sh` SSH loop could run stages unattended. Two
consequences, and the second is the expensive one:

1. **It must never ship.** An ISO that grants its default user blanket
   passwordless root is not a product.
2. **It makes the test Deck more capable than the product, silently.** §5.15 is
   the worked example: Steam's `sudo -n tee` / `sudo -n chmod a+w` fallbacks
   work here and will not work on a shipped install, so a defect looks fixed
   when it is not. Anything verified on this Deck that touches privilege is
   suspect until re-checked without this file.

It also sorts **last** in `/etc/sudoers.d/` (`99-deck-testing` > `99-deck-…`),
and sudo takes the last match, so it overrides every narrow grant this project
installs — including the two from §5.15 and `99-deck-session-select`.

**Measured with it removed, 2026-08-10** (temporarily, with a `systemd-run`
deadman restore; operator-approved). This is the product configuration, and it
settles two things at once:

| Probe | Result | What it means |
|---|---|---|
| `sudo -n true` | ✅ refused | the blanket grant was genuinely gone, so the rest is meaningful |
| Steam tier 2, `echo V \| sudo -n tee PATH` | ✅ refused | **§5.15's product prediction is correct** — Steam's fallback dies, so without our helper the brightness slider really would do nothing |
| Steam tier 3, `sudo -n chmod a+w PATH` | ✅ refused | the world-writable sysfs nodes are a test-rig artifact, not a shipped one |
| direct write as `deck` (node reset to 0644) | ✅ refused | no ambient permission was masking the result |
| `steamos-priv-write` → brightness | **works** | authorized by `99-deck-priv-write`, nothing else |
| `steamos-set-timezone` → timezone | **works** | authorized by the narrow grant, nothing else |
| `steamos-priv-write /etc/shadow` | ✅ refused | the whitelist holds with real privilege on the line |

⚠️ The backlight node was reset to **0644** for that test and **left there** —
it is the correct mode, and with tier 1 answering, Steam no longer re-`chmod`s
it. If it is ever found at 666 again, Steam fell back, which means a helper
broke.

### ⚠️ A "narrower replacement grant" is IMPOSSIBLE — measured, 2026-08-10

This section used to say the fix was a narrower grant for `tools/deck-sync.sh`.
**It is not achievable, and the sudo audit trail proves it.** Distinct binaries
the install stages ran as root in one day:

```
install(81) test(69) tee(61) grep(29) systemctl(22) cat(22) snapper(18)
visudo(15) pacman(8) find(7) chmod(7) sed(6) rm(6) cp(6) mount umount passwd
```

and the destinations include **`/etc/sudoers.d/` itself**:

```
/usr/bin/install  /etc/sudoers.d/99-deck-priv-write
/usr/bin/install  /etc/sudoers.d/99-deck-session-select
/usr/bin/chmod    /etc/sudoers.d/99-deck-testing
```

A NOPASSWD grant on `install`, `tee`, `cp` or `chmod` with arbitrary arguments
**is** full root — it can write any file anywhere, including a new sudoers
drop-in. Granting the stage *scripts* instead is worse: they live in a
user-writable directory, so that is a one-line privilege escalation. The dev
loop legitimately needs root, and no honest narrowing exists. Saying so is more
useful than shipping something that only looks narrow.

**So the resolution is not a narrower grant; it is keeping this off the image.**

1. **`./deck-session.sh stage-audit-privileges`** — not in `INSTALL_STAGES`; a
   T6 release check. Reports every blanket grant and **fails** on any that is
   also passwordless. Against the Deck it reports `03_deck`
   (`deck ALL=(ALL) ALL`) as normal-and-password-required, and fails on
   `99-deck-testing`. ⚠️ Its first version failed on **both** — exactly the
   false positive that gets a release check ignored — so "blanket" and
   "passwordless" are deliberately separate predicates.
2. **T5/P2.7 must exclude it from the payload.** That is where the real guard
   belongs, because the ISO is what ships.

`deck` has a password set (`passwd -S deck` → `P`) and `03_deck` grants
`deck ALL=(ALL) ALL`, so removing the passwordless file is recoverable rather
than a lockout — it costs only the unattended SSH loop.

### 5.18 ✅ A failed session start dropped the user at a PASSWORD GREETER — RESOLVED 2026-08-10

Found by session 16's soak test, cycle 4 of 20. This is §5.16's failure in the
form a user actually meets, and it is worse than "no session": it is a login
screen that a controller cannot answer.

```
14:45:59.845  Session "omarchy.desktop" selected ... for VT 1
14:45:59.872  Authentication for user "deck" successful
14:45:59.996  Starting Wayland user session: "uwsm start -g -1 -e -D Hyprland ..."
14:46:00.000  Session started true
14:46:00.001  session closed for user deck        <- ONE MILLISECOND later
14:46:00.007  Auth: sddm-helper exited with 5
14:46:00.008  Adding new display...              <- the GREETER
```

Two independent faults, and both need fixing:

**(a) The incoming session dies because the outgoing one has not finished.**
`uwsm start … Hyprland` exited in ~1 ms. At the moment of failure seat0 still
carried a leftover `deck` user session plus its user manager alongside the new
greeter. `render_restart_helper`'s settle step waits for
`loginctl show-seat seat0 -p Sessions` to empty, which is **not the same thing**
as the user's systemd manager and `uwsm` having finished — so the settle can
report "free" while the previous graphical session is still unwinding.

**(b) SDDM then shows the greeter instead of retrying, because
`Relogin=false`** — the shipped default, in
`/usr/lib/sddm/sddm.conf.d/default.conf`. Autologin fires once; if that session
dies, the user gets a password prompt. On this device that is unrecoverable
without a keyboard, which violates `CLAUDE.md`'s controller-only rule.

(b) is the safety net and the more important half: fixing (a) makes the failure
rarer, but only (b) decides what the user sees when it still happens. Operator
chose `Relogin=true` — the same posture already taken in
`stage-sddm-resilience`, a loop that can still recover beating a dead end that
cannot, with Ctrl+Alt+F2 as the dev escape.

**Status: RESOLVED.** Three 20-cycle soaks, measured by autologin attempts —
the only metric that shows the failure, since `Relogin=true` hides it from
everything else:

| | attempts / 20 switches | |
|---|---|---|
| original | **600** | thrash on 5 of 20 cycles |
| after the comm-name fix | **283** | bimodal: 16 clean, 2 thrashing (104, 155) |
| **after R-28's user-manager gate** | **20** | **every cycle at exactly 1 — the ideal** |

The middle row was the diagnostic clue: bimodal, not a spread, so a switch
either landed first time or fell into a distinct ~30 s state — a failure *mode*,
which is what led to R-28.

**What a switch costs now.** Settle times observed: **0.0 s on 17 of 20**, and
**52.7 / 52.8 / 53.3 s** on the three where Steam was genuinely still shutting
down. None reached the 60 s bound, so every wait was real rather than a timeout.
That is the deliberate trade: up to ~53 s of *waiting* instead of ~30 s of
*flickering*, and it is dominated by Valve's `steam-launcher.service`
`TimeoutStopSec=60`, not by anything this project controls.

⚠️ **A switch away from Gaming Mode can therefore take ~1 minute.** It is
correct and flicker-free, but it is not fast, and the cause is Steam's own
shutdown time. Worth revisiting in P2.4 if the shell can show progress.

⚠️ **The gate had a defect of its own, now fixed.** It listed `gamescope` as a
process name. The kernel truncates `comm` to 15 chars and `pgrep -x` matches
`comm`, so inside a live gamescope session `pgrep -u deck -x gamescope` returns
**0** — the compositor is `gamescope-wl`, its launcher `start-gamescope`. That
half of the gate matched nothing and reported "settled" instantly. Correcting it
is what took 600 attempts down to 283. Names verified on both sessions:
`Hyprland`, `start-hyprland`, `uwsm` (desktop); `gamescope-wl`,
`start-gamescope` (gaming).

⚠️ **What the gate still misses.** It waits on
`loginctl show-seat seat0 -p Sessions` plus that `pgrep`. Neither sees:

- **Seatless leftover sessions.** During the thrash, `loginctl list-sessions`
  carried several `deck` sessions with seat `-`, which `show-seat seat0` does
  not report at all.
- **uwsm's state inside the user manager.** `user@1000.service` stays
  `active/running` across switches, and `uwsm start` is what exits immediately.

**Measured, so the next attempt does not repeat it:** `graphical-session.target`
in the user manager **flaps** across a switch (active → inactive → active within
~1.6 s), so it is not usable as a settle signal on its own. And "no session for
the user" can never be true while anyone is on SSH — the discriminator that does
work is **`Type=wayland`**, which excludes both the `manager`-class session and
`tty` (SSH) sessions.

**✅ Root cause identified — R-28.** `steam-launcher.service` (Valve's, shipped
with gamescope) is `PartOf=graphical-session.target` with **`TimeoutStopSec=60`**,
and Steam takes tens of seconds to exit. Both thrashing cycles show the same
user-manager signature: `Stopping Steam Launcher...` with **no matching
`Stopped` line and ~29 s of silence**, while every other unit stops in ~50 ms.
sddm has already restarted by then, so the new session's `uwsm start … Hyprland`
starts into a user manager still tearing the old session down and exits in ~1 ms;
`Relogin=true` then retries until the teardown completes.

That explains the bimodality (whether Steam exits promptly), the 30–40 s
duration, and why the settle gate did not help: `steam-launcher.service` is a
**unit in the user manager**, not a process or a logind session, so neither of
the gate's conditions can see it.

**✅ Fixed 2026-08-10 (session 16).** `render_restart_helper`'s settle gate got a
third condition: **no unit in the desktop user's systemd manager may be
`deactivating`**, asked generally rather than by name, via
`systemctl --machine=<user>@.host --user`. `VT_SETTLE_MAX` went 15 s → **60 s**
to match `steam-launcher.service`'s own `TimeoutStopSec` — giving up before
systemd does would hand the problem straight back to the autologin retry loop.

⚠️ Deliberately **not** shortening Valve's `TimeoutStopSec`: Steam is being given
that time to shut down cleanly, and cutting it trades a slow switch for possible
state corruption.

Both halves are now closed: (b) `Relogin=true` means a dead session can never
strand a controller-only user at a password prompt, and (a) the incoming session
no longer starts into a teardown.

⚠️ **This is why "it worked once" was never enough.** P1.5's R-18 and session
15's R-23 both took this switch successfully; the defect needed 4 cycles to
appear.

### 5.16 ✅ The session switch could leave the Deck with NO session — RESOLVED 2026-08-10

Found by taking the Gaming→Desktop path for real (§5.10). The switch left the
Deck with no graphical session, recoverable only via
`systemctl reset-failed sddm` **over SSH** — exactly what a controller-only user
does not have. In the product that is a black screen with no way back.

sddm ships `StartLimitIntervalSec=30`, `StartLimitBurst=2`, `RestartSec=100ms`.
Switching restarts SDDM while gamescope still holds VT1; the first attempt raced
that teardown (`HELPER_TTY_ERROR`), systemd retried 100 ms later — too soon for
the VT to be free — and two failures inside 30 s latched the unit to `failed`
**permanently**. A self-healing condition became unrecoverable because of a rate
limit.

**Root cause found and fixed, 2026-08-10 (session 16).** ⚠️ The mechanism above
is **incomplete and its fix rationale was wrong** — see `R-27`. The first
domino is the **stop timing out**: `TimeoutStopSec=5`, teardown measured at
5.008 s, so systemd SIGKILLed sddm and ran the start job **3 ms** later against
a VT the killed compositor still held. `RestartSec` never gated that start at
all — it came from an explicit `systemctl restart` transaction, and `RestartSec`
only spaces `Restart=always` auto-restarts. It also fired **at boot**, so it was
never switch-specific.

Now fixed in three parts: `TimeoutStopSec=30`; `systemctl restart sddm` replaced
by an explicit stop → settle → start in `render_restart_helper`; and that
sequence run from a `systemd-run` transient unit, since `KillMode=control-group`
kills a caller inside the session being torn down.

**Measured after the fix:** across ~14 switches, including a run that hammered
10 switches in 50 s, **zero stop timeouts and zero `start-limit-hit`**, and sddm
never latched — under abusive pacing it retried 11 times and recovered itself,
where the original defect needed `reset-failed` over SSH.

**Verified, 2026-08-10: the 20-cycle soak passed 20/20** after §5.18(b) landed —
`NRestarts=0`, `Result=success`, and across the whole run **zero
`start-limit-hit`, zero stop timeouts, zero `Failed with result`**. sddm never
failed as a unit. The first soak attempt got 3 cycles before §5.18 stopped it,
which is how that defect was found.

**§5.16 itself is closed.** What remains is §5.18(a)'s retry thrash, which is a
session-startup problem, not an sddm-restart one.

⚠️ **The verification has an honest limit:** the round trip afterwards passed
*without the race recurring*, so what is proven is that the latch is gone — not
that the recovery path was exercised. The race is intermittent; P1.5's R-18 hit
this same switch and never saw it. Treat the switch as "works, not yet proven
robust" until it has survived many cycles. §R-26.

### 5.2 T1's stock→Neptune conversion is ✅ VALIDATED (was: unvalidated)

**Closed 2026-08-10 by P1.5 phase E.** All ten stages ran on a genuinely
stock system — seven exercising their real path for the first time — and
checkpoint β passed: booted unattended into `neptune-611`, with
`LoaderEntrySelected` reading `Omarchy/linux-neptune-611` from the firmware
itself, and `reconcile` exiting 0 writing nothing. The pacman hook also held
`default_entry` across an unrelated package install that rewrote
`limine.conf` — an unplanned early pass of P3.3. §R-13.

<details><summary>Original statement of the gap</summary>

The operator's Deck was converted by hand months earlier, so **seven of the ten
stages have only ever run their no-op path**. The actual conversion — removing Arch's
split `linux-firmware-*` and swapping in Valve's, and cycling the ESP mount on a
live system — remains VM-only evidence. Biggest remaining hardware gap for T1.

**Closes by design in `docs/ROADMAP.md` P1.5:** the fresh Omarchy 4.0 install is a
stock-kernel system, so running `src/omarchy-deck-kernel.sh` on it exercises the
real conversion path end to end.

Related: bumping the Neptune pin (`NEPTUNE_SERIES_DEFAULT=611`; `618` is the
newest non-RC series) is a one-line change but should not ship without a
hardware boot test.

</details>

### 5.3 The test Deck is not running the target OS — ✅ RESOLVED

**Closed 2026-08-10.** P1.5 wiped the 3.8.4-from-git install (and with it the
DeckShift hand-edits) and installed package-based Omarchy 4.0
(`4.0.0.r1617.g6d7826d`). Target and test asset now agree.

### 5.4 T0's two remaining gaps

- ~~**Ventoy USB setup has never been executed.**~~ ✅ **Closed 2026-08-10** —
  Ventoy 1.1.17 on the stick, ISO copied and sha256-verified after `sync`,
  booted on the Deck through the firmware boot picker.
- ~~**`tools/deck-sync.sh` has never run against real hardware.**~~ ✅ **Closed
  2026-08-10** — it drove all ten kernel stages and all five session stages
  over SSH in P1.5. `ssh steamdeck` resolves via a `~/.ssh/config` alias on
  the dev machine, matching the script's `DECK_HOST`/`DECK_USER` defaults.

### 5.5 Untouched risk items from the original plan

- **LCD Steam Decks are entirely untested.** Only OLED hardware exists. Gate
  LCD-divergent paths on model detection and ship "OLED-verified, LCD-untested"
  rather than claim support.
- **Trademark / redistribution** — ✅ **checked 2026-08-10**,
  `docs/findings/P16-redistribution-and-trademark.md`. Two results:
  **(a) `steamdeck-dsp` is `Proprietary` and ships no licence text**, and
  `omarchy-deck-kernel.sh` installs it — so an ISO that *bundles* Valve packages
  would redistribute a proprietary blob. It is the Deck's speaker tuning, so
  dropping it is not free. **The question is contingent on a T5 decision:
  bundle (→ blocked) vs fetch from Valve's mirror at install time (→ nothing is
  redistributed). §2.2 retired the offline constraint, so fetch is now
  available and is the recommendation.**
  **(b) The Steam Deck logo is unambiguously out**; Valve's guidelines scope
  themselves to partners under contract and forbid combining the logo with
  other words or graphics. Draw our own button glyphs for T4 rather than using
  Valve's. Descriptive use of the words is an operator judgement call; keeping
  "Steam Deck" out of the project *name* is recommended, and the project is
  already "Omarchy Deck". A README affiliation disclaimer is the cheap fix.
- **Recovery path documentation** — 🟡 **drafted 2026-08-10: `docs/RECOVERY.md`.**
  Written from Valve's published instructions (official image source, Rufus/dd,
  **Volume Down + Power** to reach the boot manager, full reimage to undo this
  project). ⚠️ **Not yet exercised by this project** — `docs/ROADMAP.md` P3.1
  performs a real factory reset and should replace it with a first-hand account.
  Exact recovery-menu option names are deliberately not quoted: they change
  between image revisions, and a stale label is worse than describing the
  intent. Carries the affiliation disclaimer from
  `docs/findings/P16-redistribution-and-trademark.md`.

### 5.6 One upstream draft staged and held

`docs/drafts/upstream-esp-permissions-omarchy.md` (against `basecamp/omarchy`) is
fully drafted, reviewed, and **deliberately unsent** by operator choice. It is
kept because its bug is one this project actively works around — when upstream
fixes it, `stage_esp_permissions`'s loosening can be revisited.

The five `deckarchy` bug reports and the `28allday` outreach draft were
**removed from the tree 2026-08-10** (recoverable from git history): the
project moved fully past deckarchy, and the outreach's premise died with the
DeckShift drop (§2.4). Nothing has ever been posted anywhere.

---

## 5.19 Phase 4 — the Deck enablement layer (added 2026-08-10)

Operator direction, session 16: after phase 3 releases one Deck-ready distro,
generalise the result so making the *next* distro Deck-ready is roughly a day of
Claude-assisted porting plus a hardware validation pass.

Spec: `docs/tasks/T7-enablement-layer.md`. Ordering: `docs/ROADMAP.md` phase 4.
Why a flasher was reframed rather than adopted:
`docs/findings/P16-scope-flasher-vs-layer.md`.

**The sizing that shaped it**, measured rather than estimated:

| | distro-specific |
|---|---|
| `src/omarchy-deck-kernel.sh` | **26%** of code lines |
| `src/deck-session.sh` | **13%** |
| `src/deck-input-mapper.py` | **0%** |

⚠️ The percentages *understate* the lock-in: the portable remainder is
scaffolding around a distro-specific core (`pacman`, `jupiter-staging`,
`limine`, `mkinitcpio`, `sddm`, `uwsm`). You would not port that core; you would
rewrite it. What is genuinely portable is the five `render_*` helper bodies, the
session-switch *policy*, the mapper, the probes — and §7's 55 facts, which are
the single biggest accelerator and are not code at all.

⚠️ **"A day" buys ported-and-conformance-green, NOT shippable.** §5.18 surfaced
on soak cycle 4; §5.16 needed a journal read across two boots; three of this
project's own checks were wrong about themselves. Soak time is wall-clock.

**Deliberately out of scope: hosting or distributing distro images.** That
reopens `steamdeck-dsp` (`Proprietary`, no licence text) as redistribution at
scale, and Bazzite/ChimeraOS already ship Deck-ready images. The differentiated
thing here is the **controller-only install** and the layer beneath it.

---

## 5.20 ✅ The OSK works on text focus — RESOLVED 2026-08-10, one GSettings key

**Answered on hardware (session 17), seen on the screen.**
`docs/findings/P17-input-and-osk.md` R-35. This was session 16's open
"needs eyes" item.

```bash
gsettings set org.gnome.desktop.a11y.applications screen-keyboard-enabled true
```

Ships **`false`**. `squeekboard` uses it as its auto-show gate, so nothing else
being correct matters until it is set. With it `true`, focusing a text field
pops the keyboard.

✅ **Implemented as `stage-desktop-settings`** (session 17) — installed as a
**dconf site default**, not a per-user `gsettings set`, because the image
creates a user we have never met and a user-level write leaves a later account
with the broken default. ⚠️ **Verify with `dconf read -d`**: a plain read
returns the user's value and would pass while the site default was absent.
See §2.6, which scopes squeekboard to the installer and hands everything after
install to Steam's own keyboard. It
sits alongside `org.gnome.desktop.input-sources` and the rotation: values that
currently live in one user's session and are all load-bearing.

⚠️ **This was first recorded here as a NEGATIVE ("does not appear on focus"),
and that was wrong.** Four conditions were tested — stock session, `fcitx5`
stopped, startup ordering corrected, `GTK_IM_MODULE=wayland` — and all of them
sat downstream of the same unexamined gate. **Four experiments sharing a hidden
precondition are one experiment.** A `WAYLAND_DEBUG=1` trace showed the whole
chain had been working the entire time: GTK binds `zwp_text_input_manager_v3`
and calls `enable()`, Hyprland sends `enter`, and squeekboard receives
`zwp_input_method_v2.activate()`. The trace cost minutes, needed no operator,
and should have come before the fourth button-press experiment.

Two facts recorded on the way:

- **Omarchy 4.0 ships and runs `fcitx5`** (`INPUT_METHOD`/`XMODIFIERS`/
  `QT_IM_MODULE` = `fcitx`). It does **not** block squeekboard, and it
  **respawns within a second of being killed** — anything assuming it stays
  dead is wrong.
- **`sm.puri.OSK0`'s `SetVisible` also works**, so explicit show/hide is
  available where a screen wants it rather than focus.

**Valve's own OSK: tested, and it works in Desktop Mode** (R-35b). Steam runs
fine on Hyprland via XWayland, and **STEAM+X summons Valve's keyboard** — seen
on screen. But it is **summon-only, never focus-triggered**, and the live ISO
has no Steam at all, so **the installer can never use it**. Gaming Mode already
has it for free, being Valve's own session.

⚠️ **It is an either/or, not a free upgrade** (R-37). Running Steam on the
desktop makes Steam take the controller — the native pad node is replaced by
`Microsoft X-Box 360 pad 0` — and **`deck-input-mapper` re-bound itself to that
virtual pad**, so one press would drive Steam's UI *and* inject a keystroke.
**T3/T4 owe the mapper a "Steam is running" policy**; nothing currently stops it
binding Steam's virtual pad.

### 5.20a ✅ FIXED 2026-08-12 — the OSK typed the wrong characters, and the keycodes were right all along

**Reported from the panel:** *"many of the keys don't type what they should
(i think it's bc of the us keyboard layout of the osk vs the latin keyboard
configured for the steam deck)."* The diagnosis was correct in every particular.

**The chain, read rather than guessed.** `src/deck_osk_layout.py` binds the `;`
key to `KEY_SEMICOLON`; `src/deck-input-mapper.py` emits that keycode through a
uinput device named `deck-input-mapper virtual keyboard`. Which **character** a
keycode becomes is decided entirely downstream, by the XKB keymap the compositor
has bound to that device. `/etc/vconsole.conf` on the Deck carries
`XKBLAYOUT=latam`, Omarchy's `default/hypr/input.lua` reads `kb_layout` straight
out of that file, and `hyprctl devices -j` reports **every** keyboard —
ours included — as `"layout": "latam"` / `"Spanish (Latin American)"`. AC10 is
`ñ` there. **The OSK's keycodes are right; the translation is wrong.** Nothing
in the mapper or the layout core needed to change.

⚠️ **This is NOT the same thing as `org.gnome.desktop.input-sources`** above.
That key exists so squeekboard has a layout to *draw*. This one decides what the
compositor *types*. Two layers; both needed; fixing either does nothing for the
other.

✅ **The fix, per device — operator decision, and the constraint is the point.**
`stage-desktop-settings` now splices a marker-delimited block into the desktop
user's `~/.config/hypr/input.lua`:

```lua
hl.device({ name = "deck-input-mapper-virtual-keyboard",
            kb_layout = "us", kb_variant = "", kb_model = "", kb_rules = "" })
```

Physical keyboards and the rest of the desktop keep Latin American. Nothing
touches `vconsole`, `localectl`, or Omarchy's global `kb_layout`, and the suite
**fails** if every keyboard ends up on `us` while the session layout is not —
going session-wide is a defect here, not a simpler version of the fix.

**The Lua shape is measured, not assumed** (§5.30b's lesson). `hl.device(spec)`
with a required `name` is in `/usr/share/hypr/stubs/hl.meta.lua` and backed by
`m_deviceConfigs` in `src/config/lua/ConfigManager.hpp`. Probed live:
`hyprctl eval 'hl.device({ kb_layout = "us" })'` →
*"hl.device: 'name' field is required and must be a string"*; `hl.device(7)` →
*"argument must be a table"*. The binary also carries
`"hl.device: unknown field '{}'"`, so a misspelt field **raises** rather than
being ignored.

🔴 **How it is prevented from being a silent no-op** — three independent traps,
because this is exactly where §5.30b said rules go to die quietly:

1. **A sentinel as the block's last statement.** `hl.device` raises on a bad
   field and a raise skips the rest of the chunk, so `DECK_OSK_KB_LAYOUT` being
   set in the live compositor proves the whole block executed.
   ⚠️ **It is asserted, never read back.** Measured 2026-08-12: `hyprctl eval`
   given a bare Lua return prints `ok` and exits **0** for *any* expression
   that does not raise — including a nil global — with a nonexistent name as the
   negative control. Only a Lua `error()` surfaces: **exit 7**, with the
   message. **The readback recipe written into the Deck's own `input.lua` for
   the `above_lock` sentinel is therefore a no-op.** ✅ Corrected 2026-08-12 at
   the source of truth (`docs/tasks/T5-fork-plan.md` §5.6) and in the runbook;
   the Deck's own copy is the operator's to change. `test/unit/test-hyprctl-syntax.sh`
   scanner 3 now fails CI on the readback shape anywhere in this repo.
2. **The device name is cross-checked against the mapper.**
   `test/unit/test-deck-session.sh` greps `src/deck-input-mapper.py` for the
   exact `UInput(name=…)` string and asserts our matched name is its normalised
   form. A rename there would otherwise leave a rule that parses, loads, and
   matches nothing.
3. **The stage reads the layout back out of `hyprctl -j devices`** after
   `hyprctl reload config-only`, and fails when our device is not on `us`. No
   live compositor is a **loud warning**, not a pass.

⚠️ **The rule names the suffixed aliases too** (`…-1`, `…-2`, `…-3`). Our uinput
device declares keys **and** relative axes, so Hyprland binds it twice —
`getNameForNewDevice` appends a counter to whichever copy loses the race for the
bare name. Measured: the **keyboard** holds the bare name and the **pointer**
holds `-1`. Nothing promises that order, and `kb_layout` on a pointer is inert,
so naming only the bare form would work until the day it silently did not.

⚠️ **It patches the same file as the `above_lock = 2` layer rule** (§5.24). The
splice is marker-delimited and preserves everything outside its own block, and
the suite asserts the `above_lock` line survives — losing it makes the lock
screen unanswerable on a device with no physical keyboard. It also refuses to
install a file that does not pass `luac -p`, because Hyprland discards an
unparseable config **without logging a reason** and would take both rules down
together.

⚠️ **It still lives in one user's dotfile.** T5 `§5.3` now carries the bake-in
row. This is a fourth load-bearing session setting, not a fourth thing that
exists only on the operator's machine.

🟡 **THE INSTALLER TTY IS A SEPARATE PROBLEM AND IS ONLY HALF SAFE.** A bare
console has no XKB at all — keycodes go through `loadkeys` and the kernel
keymap — so nothing above applies there.

- ✅ **The Wi-Fi passphrase is safe.** S1 runs at the tail of `greeter`,
  **before** `keyboard_form`'s `loadkeys` (`src/deck-form.sh`, commit
  `d49dbe4`), so it is typed under the ISO's boot default.
- 🔴 **The account password is not.** Upstream's flow is
  `keyboard_form` (which ends in `loadkeys "$keyboard"`, `configurator` line
  225) → `user_form` (username **and password**, line 246) → disk. A user who
  picks a non-`us` layout types their password through a console keymap the OSK
  does not draw, and that same value is written into archinstall's
  `"kb_layout"` — which is where this Deck's `latam` came from in the first
  place.
- The fix is `docs/tasks/T4-screen-spec.md` §3 deviation 2 (*"keyboard becomes
  the constant `us`"*), which lives in `omarchy_prompt_keyboard`/`keyboard_form`
  and is **not implemented**; `src/deck-form.sh` already flags it as out of its
  own scope. **Not fixed here** — it is a different mechanism in a file this
  change does not own.

---

## 5.21 🐞 NEW — `lizard_mode=N` persists nowhere, and a reboot silently takes STEAM+X and Space

**Found 2026-08-10 (session 18) by grepping for it, then reading the Deck.**
Nothing in `src/`, `test/`, `tools/` or `.github/` writes
`/sys/module/hid_steam/parameters/lizard_mode` — the only hits are comments in
`src/deck-input-mapper.py` and its test explaining what the knob *means*. The
Deck sits at `N` today solely because a human echoed it there in session 17.

It is a **module parameter**, so a reboot restores `Y`. What that costs, both
measured in §5.9 / R-29:

- **STEAM+X stops working.** `BTN_MODE` is one of the six buttons lizard mode
  swallows entirely — no evdev node sees it — so the chord cannot be detected at
  all, and the OSK toggle in `src/deck-input-mapper.py` becomes unreachable.
- **`Y → KEY_SPACE` stops working.** Lizard mode provides no Space, and Space is
  precisely what archinstall's multi-select needs. This is the reason the mapper
  exists.

✅ **CONFIRMED IN THE FIELD 2026-08-11** — the operator power-cycled the Deck and
reported STEAM+X dead on first startup, exactly as predicted below. See §5.23.
It also blocks the new STEAM/QAM menu bindings requested there: **one fix closes
both.**

⚠️ **It is a degradation, not a brick.** With lizard mode back on, the firmware
supplies its own pointer, Enter, Esc, Tab and arrows, so the Deck stays usable —
which is exactly why nothing has noticed. The failure is silent and partial, the
shape `CLAUDE.md` forbids.

**Why this is not a one-line fix, and needs a decision:** persisting `N` makes
`deck-input-mapper.service` the *only* input path from boot. Today, if the
mapper dies, lizard mode is the safety net. Persist `N` and a mapper that fails
to start leaves a handheld with no pointer and no keys, recoverable only over
SSH. Any implementation therefore owes a **fallback**: restore `Y` if the mapper
is not running. Candidate mechanisms — `modprobe.d` options (applies at module
load, before any userspace check), a `systemd` unit ordered against the mapper,
or `tmpfiles.d` — differ mainly in whether that fallback is expressible.

**Do not implement this without the operator present**, per `docs/START-HERE.md`
§3: it changes the input path on the one physical device.

---

## 5.22 🆕 Phase 2.9 — rebase everything onto Omarchy 4.0 beta 2 (added 2026-08-11)

**Operator direction, session 19.** Upstream released a second 4.0 beta.
Everything this project owns — the built ISO, the QEMU substrate, both install
scripts, the input/OSK layer and the test Deck — sits on the 4.0 snapshot of
**2026-08-10**. A new roadmap block moves all of it, *before* phase 3, so the
release run has one moving variable instead of two.

**Spec: `docs/tasks/T9-beta2-rebase.md`. Measured delta:
`docs/findings/T9-beta2-delta.md`. Ordering: `docs/ROADMAP.md` phase 2.9
(P2.9a–P2.9g).**

### 🔥 RESOLVED 2026-08-11 — we were ALREADY on beta 2, and our build is newer

**Measured by unpacking both ISOs and diffing their manifests**
(`docs/findings/T9-iso-comparison.md`). Upstream's beta 2 and our 2026-08-10
build carry the **same `omarchy-dev 4.0.0.r1617.g6d7826d-1`**, the **same
`basecamp/omarchy` commit `6d7826d`**, the **same `edge` channel** and the
**same `omarchy-iso` builder `a12bfea`**. 1244 packages each, none exclusive to
either; the whole difference is **7 stock Arch rebuilds** — and **ours are the
newer ones**, our squashfs having been sealed 15:24 UTC against their 13:35.

**So "rebase onto beta 2" was already done before it was proposed.** The Deck
was installed from our ISO on 2026-08-10, so it is running `6d7826d` too —
**confirm with one `omarchy-version` when it is next on**, then P2.9e is a
verification, not a migration. **P2.9c's rebuild is skipped**, and this is the
reason.

⚠️ **The real drift is what comes NEXT.** `6d7826d` → `quattro` HEAD is **36
commits / 85 files** (and HEAD moved again mid-measurement). That range —
*not* beta 1 → beta 2 — is what the classification below actually covers, and
it contains one **BREAKS US** row (see the end of this section).

### The pin — ✅ resolved by measurement

**Beta 2 is a published, unlisted ISO** (found 2026-08-11 by probing
`iso.omarchy.org`; the r/omarchy thread the operator cited **could not be
read — reddit.com is blocked by policy for both WebFetch and the in-app
browser**):

| What | Value |
|---|---|
| Beta 2 ISO | **`https://iso.omarchy.org/omarchy-quattro-beta2.iso`** |
| Size / stamp | **6,390,581,248 B (5.95 GiB), 2026-08-10 13:44:37 UTC** |
| Upstream checksum | **none published** — `.sha256` 404s; the ETag is an S3 multipart hash, not usable for integrity |
| Beta 1, for comparison | `omarchy-quattro-beta1.iso`, 6,371,614,720 B, 2026-08-05 21:12:44 UTC |
| `omarchy-iso` SHA it was cut from | ✅ **`a12bfea`** — pinned by content-diff, because **no commit sha is stamped anywhere inside either ISO** |
| `basecamp/omarchy` SHA inside it | ✅ **`6d7826d`** = `omarchy-dev 4.0.0.r1617.g6d7826d-1`, 2026-08-10 12:53 UTC |
| Channel it carries — mirror **and** pkgs | ✅ **`edge`** on both sides (`pkgs.omarchy.org/edge` + `mirror.omarchy.org`). ⚠️ `/root/omarchy_iso_ref` differs (`edge` theirs, `quattro` ours) — provenance only, no package-source effect |

⚠️ **The name still identifies nothing.** No 4.0 tag, no GitHub release, the
`version` file on `quattro` is **still `4.0.0.alpha`** (never bumped for beta 1
either), and only **`edge`** and **`stable`** answer as package channels —
`beta`, `beta2`, `rc`, `quattro`, `testing`, `preview`, `nightly` all 404.
Refinement measured the same day: **`--rc` pins the *Arch* mirror
(`rc-mirror.omarchy.org`) while still taking Omarchy packages from `edge`** —
so "channel" is always a pair.

🔥 **The finding that changes the plan: beta 2 is not what an update installs.**
`quattro` HEAD `1c9dfc5` (2026-08-11 12:30 UTC) is **~24 h and ~30 commits ahead
of the beta 2 ISO**, and `edge` was rebuilt 11 minutes after that commit
(`omarchy-dev-4.0.0.r1652.g1c9dfc5-1`). **`omarchy-update` overshoots beta 2**
into whatever edge holds that hour. Rebasing onto *beta 2* (fixed, what users
get) and onto *edge HEAD* (moves daily) are different targets — **P2.9a must
choose one and say so here.**

⚠️ **Our own ISO and beta 2 are hours apart.** Ours: `omarchy-iso` `a12bfea`,
2026-08-10 11:30 UTC. Beta 2: stamped 13:44 UTC the same day, *before* the
builder's next commit at 16:19. If inspection shows they match, P2.9c's rebuild
proves nothing and should be skipped rather than performed for form's sake.

⚠️ **Timing.** The thread the operator cited is titled *"Omarchy Quattro will be
shipping this week."* If 4.0 **stable** lands within days, phase 2.9 and P3.6
collapse into one rebase — worth deciding before spending an operator session.

### Why it is a block and not a footnote — measured, not feared

37 commits between our install baseline and 2026-08-11 changed, among others:

- **`etc/sudoers.d/omarchy-tzupdate`** — dropped the `tzupdate` grant
  (#6694). `src/deck-session.sh` (~line 1157) quotes the **old** line in a
  comment whose whole argument was "that file belongs to a package on a beta
  distro, and if it changed the picker would go back to failing silently."
  **It changed four days later.** The half we rely on survived; the comment is
  now wrong. Fix the quote, keep the reasoning, note it was borne out.
- **Three `bin/omarchy-apply-*` renames**, and `omarchy-iso`'s HEAD commit
  exists to call the renamed `omarchy-apply-system` finalizer. Our `src/`
  references none of them; **T5's fork inherits the exposure.**
- **`shell/plugins/lock/Service.qml`** — the Quickshell lock service whose idle
  policy we deliberately neutered (screensaver 150 s, lock 86400 s). This is
  the most plausible route back to a Deck that locks itself with no keyboard.
- **`default/omarchy/omarchy-menu.jsonc` and `bin/omarchy-menu`** — P2.4's
  extension seam.
- **Four new `migrations/*.sh`**, root and machine-wide, run by
  `omarchy-update`. One rewrites `/etc/bluetooth/main.conf` and says outright
  that *an update over SSH would otherwise abort*. **We update over SSH**, and
  BT is an open parity row.

Nothing in those 37 commits touches Limine, the mkinitcpio hook, snapper or
the ESP — `src/omarchy-deck-kernel.sh` looks untouched, which is what T1's
design predicted. ⚠️ Do not promote that to a fact without checking the pinned
range *and* the `limine*` package versions, which move independently of the
branch.

### The one decision inside this block

**Recommended: bring the Deck up in place (`omarchy-update`) after snapshot #8
— not a reinstall.** P3.1/P3.2 already buy the clean-install proof from a
factory reset; a rebuild here spends those hours twice and costs snapshots
#1–#7 and the SSH loop. The gap — the *installer* path changed underneath us —
is precisely what P2.9d's QEMU install test covers, which is why P2.9d is not
optional. If the operator prefers a reinstall, that is defensible, but then say
here plainly that phase 3's install is no longer the first from this ISO.

⚠️ **This does not replace P3.6** (rebase onto 4.0 *stable*). It makes P3.6 the
second run of a known procedure instead of the first, on a step that gates the
release.

### What the delta actually contains — **1 BREAKS US, 27 RE-VERIFY, 37 NO IMPACT**

Full table, one row per changed non-test file with the patch hunk behind each
verdict: **`docs/findings/T9-delta-classification.md`**. Because we are already
on beta 2, this range is **`6d7826d` → `quattro` HEAD** — i.e. **what a move to
edge, or eventually to stable, would bring**, not what we already have.

🔴 **BREAKS US — `shell/plugins/lock/Service.qml` gained stranded-lock
recovery.** When `omarchy-hyprland-session-locked` (new binary) exits 0 and PAM
is configured, `recoverStrandedLock()` calls **`beginLock()` directly — it never
reads `idle.lock`.** Our entire idle neutering (`src/deck-session.sh:180-197`,
lock 86400 s) exists so this handheld can never be shown a password prompt it
cannot answer; **that guarantee becomes insufficient by construction.** Worse,
`ext-session-lock` renders above every layer surface, so `src/deck_osk_wayland.py`
— our on-screen keyboard — would be **invisible underneath it**: keystrokes land
where the user cannot see them. It is armed from three places plus a
500 ms × 20 retry timer, and `bin/omarchy-launch-shell` now relaunches the shell
up to 5×/min, re-running the check each time.

**This is the strongest argument yet for staying pinned at beta 2 rather than
tracking edge** — beta 2 predates it. It will arrive with stable, so **P3.6
must confront it**, and the way to test it is to provoke it (kill quickshell
while locked), not to read the QML and conclude it looks fine.

Other rows that need a human when we do move — 🔴 six of the 27:
`omarchy-hyprland-session-locked` (the sensor above) · `omarchy-launch-shell`
(the supervisor that multiplies it) · **`default/hypr/bindings/utilities.lua`,
which now globally binds RETURN/TAB/CTRL variants and all four arrows — 6 of
the 10 keys `src/deck-input-mapper.py:133-159` emits, up from 1** ·
`default/bash/envs` exporting the system locale to **non-login shells, which is
our SSH loop**, meeting a sudoers-glob ordering assumption at
`src/deck-session.sh:1601-1606` · `omarchy-hyprland-monitor-watch`'s new
`hyprctl reload` backoff loop on a single-display device, active across the
§5.18 switch window · the Bluetooth migration.

**Proved absent, stated as negatives** (worth as much as the positives): the
**boot chain is untouched** — every `limine|mkinitcpio|snapper|uki` hit in the
range is a *deletion* from a removed code path, and `src/omarchy-deck-kernel.sh`
has no row in the table at all. The greeter's `default/sddm/hyprland.lua`
**sha256 is identical at both refs and still equals `UPSTREAM_GREETER_SHA256`**
(`src/deck-session.sh:334`), so our drift alarm correctly stays silent.
`steamos|gamescope|steam` and `squeekboard|osk`: **zero hits.** Both OSK
GSettings: clear — though still verify with `dconf read -d`, since a package
outside this range can ship a new default.

### ✅ Fixed the same day: the substrate tested a boot chain the product never runs

`test/images/vm-neptune-image.sh` pulled the limine stack from
**`pkgs.omarchy.org/stable`, unpinned**, while its own header claimed *"same
version stream as Quattro's"*. `stable` was measured **606 commits behind**, and
the product's ISO carries **`edge`** — so every VM suite could pass green
against a Limine stack the product would never boot. Nothing enforced the claim.

**Two changes, 2026-08-11.** The channel now defaults to `edge`, matching the
ISO. And the versions measured *inside beta 2* — `limine 12.5.2-1`,
`limine-mkinitcpio-hook 1.37.1-1`, `limine-snapper-sync 1.31.0-1` — are
**asserted after pacstrap**, so drift is a loud failure naming both sides and
saying how to re-pin. `IMG_LIMINE_PIN=any` bypasses it deliberately (and prints
what it found); `IMG_LIMINE_PIN='pkg=ver …'` re-pins.

⚠️ It is an assertion, **not** an attempt to install exact versions — a rolling
repo may no longer carry an older build, and pretending otherwise would just
fail differently. It says *"this is what the product was measured to run; tell
me when what I got stops matching."*

**New suite: `test/unit/test-vm-limine-pin.sh`, 12 assertions, 9/9 mutations
caught.** The check lives inside a heredoc shipped into Docker and cannot be
sourced, so the suite **extracts the block between two marker comments and runs
it** against a stubbed `arch-chroot` — and refuses to run if that extraction
comes back empty, because a renamed marker would otherwise make every case pass
while asserting nothing. ⚠️ Renaming either marker breaks the suite loudly, by
design.

**Writing the test found a defect in the fix**: an absent pinned package died
with *"could not query"* — a pipeline under `pipefail` swallowing the
distinction — which reads like a broken chroot rather than a stale pin. The code
was corrected, not the test. *(One mutation initially "survived" and was a
testing artifact, not a gap: it edited the header comment rather than the
assignment. Re-targeted, it was caught. **Check what a mutation actually
changed before recording a survivor.**)*

⚠️ **One row lands on phase 3, not here:** `omarchy-system-factory-reset` **deleted
its degraded path — a machine without a `@factory` snapshot is now refused.**
Check that before P3.1 assumes the factory reset will run.

---

## 5.23 🆕 Three first-boot behaviours the operator hit (reported 2026-08-11)

**Operator field report, session 19, on the Deck after a power cycle.** Two are
already-diagnosed items whose *predicted* symptom has now been **observed**; the
third is a new requirement. They share one root: **the Deck is carrying
hand-tuned state that does not survive a boot**, and the product promises
behaviour that only a built image can deliver.

### 1. First startup lands on the DESKTOP, not Gaming Mode

**Not a defect — the stage that flips it has deliberately never been run.**
`./src/deck-session.sh stage-default-session` ("make Gaming Mode the default —
do this last") was held back on purpose so that iteration lands somewhere with a
shell (`docs/START-HERE.md`, and the P1.5 exit notes). Running it is one
command and needs operator approval like any Deck write.

⚠️ **But the operator experienced it as a bug, and that is the useful signal.**
The product's promise is "boots to Gaming Mode like stock SteamOS"; a fresh
install from our ISO must do that with nobody running a stage afterwards.
**T5 owes the default session in the image** — add it to P2.7's bake-in list
beside the two rotations, `99-deck-testing`'s exclusion and the three session
settings (§5.20). Nothing tests this today.

### 2. STEAM+X does not raise the keyboard on first startup

**This is §5.21, observed.** That section predicted exactly this: `lizard_mode`
is a module parameter, a reboot restores `Y`, and with lizard mode on
**`BTN_MODE` reaches no evdev node at all**, so the chord cannot be detected —
the OSK toggle is unreachable, and `Y → KEY_SPACE` is gone with it. The Deck was
last recorded at `N`, set by hand, and the session-exit note said powering off
would revert it. It did.

**Upgrade §5.21 from "predicted" to "confirmed in the field."** The fix is still
the one §5.21 describes and still needs the operator present: persisting `N`
makes the mapper the *only* input path, so any implementation owes a fallback
that restores `Y` when the mapper is not running.

### 3. 🆕 REQUEST — STEAM should open the apps menu, QAM the Omarchy menu

Operator request for Desktop Mode: **STEAM button → the apps menu**, **QAM
button → the menu that lives at the top-left of the bar** (Omarchy's own menu).

**Upstream already exposes both as commands** — measured from `quattro`'s
`default/hypr/bindings/utilities.lua`, 2026-08-11:

| Want | Upstream command | Its stock keybind |
|---|---|---|
| Apps menu | `omarchy-menu toggle apps` | `SUPER + ALT + SPACE` |
| The bar's top-left menu | `omarchy-menu toggle` (root) | `SUPER + SPACE` |

**Do it by exec'ing `omarchy-menu`, not by synthesising `SUPER+ALT+SPACE`.**
The mapper already spawns helper processes (it drives squeekboard over
`busctl`), and a synthesised chord depends on the user's keybinds being
unchanged — which upstream edited in this very delta. Exec is deterministic;
the coupling becomes `omarchy-menu`'s subcommand names, which is narrower and
fails loudly.

⚠️ **Two things gate this, and one is unmeasured:**

1. **Both buttons need `lizard_mode=N`** — the same knob as item 2. Lizard mode
   swallows STEAM and QAM entirely. **One fix (§5.21) closes items 2 and 3
   together**; without it, neither button exists to bind.
2. 🔴 **QAM's evdev code has never been measured.** Every recorded map says
   only that lizard mode swallows it; `src/deck-input-mapper.py` references
   `BTN_MODE` for STEAM and nothing for QAM. **One `evtest` press with lizard
   mode off answers it** — do it in the same hands-on pass as §5.21's fix
   rather than as its own trip.

Also note **STEAM is already the chord's hold key** (STEAM+X toggles the OSK).
Binding STEAM *alone* to the apps menu means distinguishing tap from
hold-then-X — i.e. fire on release, only if no chord partner was pressed. That
is a real state-machine change in the mapper, unit-testable without hardware.

**Where this lands:** P2.4 (shell integration) already carries "QAM/Power-menu
placement" as open work; this is that row, now specified. The mapper half is
Deck-free and can be written and tested before the hands-on pass.

---

## 5.24 ✅ FIXED AND SEEN ON THE PANEL 2026-08-11 — but the fix exposed three worse things

**The fix works, verified the only way it can be:** with the session locked, the
operator pressed **STEAM+X, the keyboard appeared over the lock screen, they
typed the password with the trackpads, and the Deck unlocked.** Both halves of
`above_lock = 2` are therefore real — it draws above `ext-session-lock` *and* it
is hit-testable there. `hyprctl layers` reported the surface identically
throughout and could never have distinguished this.

Applied: `hl.layer_rule({ match = { namespace = "deck-osk" }, above_lock = 2 })`
in `~/.config/hypr/input.lua` (**not** a new `deck.lua` — the five user files are
upstream's sanctioned override seam, so this reuses the bake-in mechanism §5.2
already needs for `monitors.lua` instead of adding a `require` line to
`hyprland.lua`), plus `systemctl --user mask omarchy-sleep-lock.service`.

⚠️ **A Lua syntax error makes Hyprland discard the whole file silently, and
`hyprctl configerrors` still comes back clean** — clean *because* nothing was
parsed, which is the case you care about. The file therefore ends in a sentinel
global, `DECK_INPUT_LUA_LOADED`.

🔴 **CORRECTED 2026-08-12 — the recipe written into `input.lua`'s comment for
reading that sentinel back is a NO-OP, and it has never been able to fail.**
`hyprctl eval` prints `ok` — its own status, never the expression's value — and
exits **0** for anything that does not raise, a global that has never existed
included (`return DECK_NOPE` → `ok`, exit 0, run live as the negative control).
Only a Lua `error()` surfaces: exit **7**, with the message. The working form is
an assertion:

```bash
hyprctl eval 'if DECK_INPUT_LUA_LOADED == nil then error("input.lua was discarded") end'
```

exit 0 = loaded, exit 7 = discarded. `verify_osk_kb_layout` in
`src/deck-session.sh` already used exactly this shape for its own sentinel.
The Deck's own `input.lua` still carries the wrong comment — **not edited, it is
the operator's machine** — but the source of truth a built image bakes in,
`docs/tasks/T5-fork-plan.md` §5.6, now carries the corrected text, and
`test/unit/test-hyprctl-syntax.sh` scanner 3 fails CI if the readback shape is
written into this repo again.

### 🔴 Three defects this session exposed, none of them the lock rule

1. 🟡 **ISOLATED 2026-08-11, and it is a usability defect, NOT the unanswerable
   screen.** Reproduced deliberately with the variables recorded. **Locking
   blanks the panel about 5–6 s later** (`dpmsStatus` sampled ~1 s apart read
   `1,1,1,1,1` then `0` for the remaining 19 samples; the operator saw the prompt
   "for 1 or 2 seconds then it went black"). Repeatable.

   **What wakes it, measured by pressing things:**

   | Input | Wakes the panel? |
   |---|---|
   | Right trackpad | ❌ no |
   | Ordinary face buttons | ❌ no |
   | **QAM (`BTN_BASE`)** | ✅ **yes — for ~2 seconds** |
   | **Power button** | ✅ yes |

   The operator woke it with QAM, summoned the keyboard, typed the password with
   the trackpads and reached the desktop. **So the device is recoverable by its
   own controls and §5.24's unanswerable-screen scenario does not occur with the
   `above_lock` fix in place.** An earlier note in this file called it a release
   blocker; that was written before it was isolated and was wrong.

   ⚠️ **Two corrections to how this was diagnosed, both worth keeping.** First,
   "the backlight is on at 33% so this is not DPMS" was **unsound** — the
   backlight sysfs value does not track DPMS state, and `dpmsStatus` was 0
   throughout. Second, the tempting correlation (*"black happens when the OSK is
   mapped at lock time"*) was **a coincidence of two runs**; DPMS state was the
   variable nobody recorded on the first one. Two plausible stories, both wrong,
   both killed by changing one variable deliberately.

   **Why QAM and nothing else — ANSWERED FROM SOURCE 2026-08-11**
   (`docs/findings/T9-lock-wake-and-blank-timing.md`), and **my recorded
   hypothesis was wrong on both counts:**

   - ❌ *"The mapper grabs the pad"* — **false twice over.** `--grab` is never
     passed in production (`src/deck-session.sh`'s `ExecStart=` has no `--grab`),
     **and it would not have mattered**: libinput has no gamepad/joystick device
     capability class at all, so the raw `hid-steam` node was never going to
     reach Hyprland's idle logic no matter who else reads it.
   - ✅ **QAM emits ZERO input-layer events.** `translate()` returns `[]` for it
     and only queues `menu-root`, dispatched as a `subprocess.Popen` running
     `omarchy-menu toggle`. So the "spawns a process" half was right.

   🔴 **And the blanking is not Hyprland's idle timeout or `shell.json` at all.**
   It is a **hardcoded 5-second `Timer`** — `idleBlankTimer, interval: 5000` — in
   Omarchy's own `shell/plugins/lock/Service.qml`, which calls `hyprctl dispatch`
   DPMS via `omarchy-brightness-display`. **That matches the hardware
   measurement exactly**: `dpmsStatus` went 1→0 between the 5th and 6th
   one-second sample. Source-read and panel-measured agree on the same number,
   arrived at independently.

   ⚠️ Still **inferred, not confirmed**: precisely how QAM's IPC path ends up
   waking the panel — most likely Hyprland's own `mouse_move_enables_dpms`
   firing from an incidental cursor event as the menu surface takes focus.

### 5.24a 🆕 Operator requirements from seeing the lock in use (2026-08-11)

Three changes, all requested after watching it work. None needs the Deck to
develop; all need it to confirm.

| # | Requirement | Note |
|---|---|---|
| 1 | **Only the power button should wake the panel** — QAM should not | ✅ **Coded 2026-08-12 (session 23), `deck_input.py`, commit `a4b1eab`** — `misc.key_press_enables_dpms`/`mouse_move_enables_dpms = false` spliced into `input.lua`, wired into `deck_configure.deck_steps()`. Not yet hardware-verified: `hyprctl getoption` both = `int: 0`, then press QAM while locked and confirm the panel stays dark |
| 2 | **Display-on time should be ~20 s, not ~2 s** | 2 s is not enough to aim a trackpad at a password field. This is the lock screen's own idle timeout, distinct from the 150 s screensaver and the 86400 s lock in `shell.json` |
| 3 | **The OSK should auto-hide after unlock** | It currently persists into the desktop session. Ours is summon-only (§5.27), so nothing dismisses it on unlock today |
2. 🔴 **There is no `unlock` IPC.** `qs ipc show` gives the `lock` target exactly
   `lock`, `isLocked`, `status`, `preview`, `hidePreview`. Nothing releases a
   lock but the password. Combined with #3, a keyboard-less Deck that locks with
   a broken OSK has **no software escape at all**.
3. 🔴 **`docs/RECOVERY.md`'s escape does not work, in two independent ways.**
   `hyprctl eval 'hl.clear_crashed_lockscreen()'` is documented as the answer to
   "my screen is locked". Over SSH it dies with `HYPRLAND_INSTANCE_SIGNATURE not
   set`; once that is supplied it **refuses**: *"session is locked with a client,
   refusing to unlock"* — it only clears a **crashed** lock, and a healthy one is
   the case a user actually hits. `omarchy-shell` needs three env vars over SSH
   (`XDG_RUNTIME_DIR`, `WAYLAND_DISPLAY`, `OMARCHY_PATH`) and the runbook supplied
   none. **The documented recovery path for an unanswerable screen had never been
   executed.** Working forms are in the session scratch; RECOVERY.md must be
   corrected before release, and `omarchy-shell` is **not** a systemd unit
   (parent 1029), so killing the lock client leaves the shell down until it is
   restarted by hand.

*(Historic statement of the defect follows.)*

## 5.24 (original) 🔴 the POWER BUTTON locks this Deck, and the lock is unanswerable

**Found 2026-08-11 while designing a defence against something else.** Full
trace: **`docs/findings/T9-lock-service-mitigation.md`**. This is a live defect
on the operator's Deck today, at `6d7826d`, with nothing from the upstream
delta involved.

**There are three lock producers upstream. §5.20's idle neutering covers one.**

| Producer | Status on our Deck |
|---|---|
| Idle timeout (`shell.json` `idle.lock`) | ✅ neutered to 86400 s by `stage-desktop-settings` |
| 🔴 **`omarchy-sleep-lock.service`** — `systemd-inhibit` on logind's `PrepareForSleep` → `omarchy-shell lock lock` | **LIVE.** Enabled by upstream's `install/user/first-run/enable-user-units.sh`, byte-identical at `6d7826d` and `quattro`. **Press the power button and it locks.** |
| 🔴 `system.lock` row in `omarchy-menu.jsonc:32` | **LIVE** — in the same menu our Desktop Mode row lives in |

**What the user sees.** With Quickshell's lock UI absent or stranded, Hyprland
renders `renderSessionLockMissing()` — `lockdead.png` and *"Running on tty 2"*,
**no password field at all**, unanswerable on any hardware. Escape is a
ten-second power hold. Even with the real lock screen, our OSK is invisible
beneath it (`Renderer.cpp:943` skips layers without `above_lock`), and after a
reboot `lizard_mode` is back to `Y` (§5.21), so the pad emits no letters
anyway.

⚠️ **`src/deck-session.sh`'s own comment claimed the idle settings mean this
handheld "can never be shown an unanswerable password prompt." That was false
when it was written** — it covers the idle producer only. Corrected 2026-08-11;
`src/` still has zero references to `sleep-lock`, `pam.d` or suspend.

### 🔁 And it inverts §5.22's BREAKS US verdict

`recoverStrandedLock()` **cannot lock an unlocked machine.**
`omarchy-hyprland-session-locked` exits 0 only when Hyprland's
`solitaryBlockedBy` carries `LOCK`, whose sole producer is a direct read of the
lock manager (`Monitor.cpp:1834`, traced at the 0.56.2 we run). The recovery
attaches a password prompt to a lock that **already exists**. On our
configuration the delta is the only thing that turns an *undismissable splash*
into a *dismissable prompt*. **Reclassify that row from BREAKS US to
RE-VERIFY; it is not a reason to hold back from edge or stable.**

### Recommendation — needs operator approval, it touches the Deck

1. `hl.layer_rule({ match = { namespace = "deck-osk" }, above_lock = 2 })` so
   our keyboard renders *and* hit-tests above a lock surface. `above_lock` is a
   first-class Hyprland layer rule and the Lua binding exists at 0.56.2.
2. `systemctl --user mask omarchy-sleep-lock.service` — stop creating locks
   nobody asked for.
3. Keep `idle.lock = 86400`. It is necessary, just not sufficient.

Rejected, with reasons: removing PAM or shadowing the sensor both leave the
compositor lock in place while deleting the only UI that can dismiss it —
they make it *unrecoverable* — and both rot silently. Owning the lock surface
ourselves is weeks of work on a security boundary that fails open.

⚠️ **Unverified and worth knowing: upstream has never provoked this either.**
Its `test/shell.d/lock-stranded-recovery-test.sh` is 13 regexes over the QML
text, and the sensor's test runs against a fake `hyprctl`. The findings file
carries a three-tier provocation plan; tier 0 is a nested Hyprland and needs
neither Omarchy nor the Deck.

---

## 5.25 ✅ TWELVE OPERATOR DECISIONS, 2026-08-11 — all settled in one pass

Every one of these had been open, some for several sessions. **They are decided;
do not re-litigate them without new evidence.** Where a decision creates work,
the owner is named.

### Approved for the next Deck session — batch them, do not go four times

| # | Decision | Owner |
|---|---|---|
| 1 | 🔴 **Fix both lock causes** (§5.24): the `above_lock = 2` layer rule for `deck-osk`, **and** mask `omarchy-sleep-lock.service`. The power button must stop producing an unanswerable password screen | Deck |
| 2 | ✅ **BUILT (session 19).** `stage-lizard-mode` ties the knob to the mapper's lifetime — `ExecStartPost` off, `ExecStopPost` on, **plus `OnFailure=` on a separate unit** for the cgroup-kill path where `ExecStopPost` is itself killed. **All eight kill paths verified on systemd 261**; the no-input window went from *until the next boot* to **≤106 ms**. Left: confirm on hardware (runbook §2.1) | Deck |
| 3 | **Measure QAM's evdev code** — one press with lizard mode off. The binding is written and deliberately inert until this exists (§5.23) | Deck |
| 4 | **Run `stage-default-session`** — the Deck starts booting to Gaming Mode | Deck |
| 5 | **Apply BOTH rotations**: Limine `interface_rotation: 270` and the TTY's `fbcon=rotate:1`. Boot-chain, hence the explicit approval | Deck |

### Decided, no hardware

| # | Decision |
|---|---|
| 6 | **Wait for 4.0 stable rather than moving to `edge` now.** We are on beta 2 exactly; the one alarming delta row was reclassified (§5.24). If stable lands this week, this block and P3.6 become one rebase |
| 7 | **Keep `99-deck-testing`, and make the ISO refuse to carry it** (§5.17). ⚠️ T5 owes a build-time check that **FAILS THE BUILD**, not a comment. Until then every privilege-dependent result on that Deck stays suspect |
| 8 | **T5 (the ISO build) is the next major piece**, ahead of T4's installer screens |
| 9 | **`stage_return_icon` gets an ownership marker** and starts refusing foreign files, like every other stage |
| 10 | **Refactor the five untestable stages** so verification takes a path — production behaviour unchanged, default argument is today's constant |
| 11 | **Pin CI's shellcheck** (v0.11.0, fetched from the release, not apt) so local and CI cannot disagree |
| 12 | **Leave STEAM long-press alone.** Any press-and-release opens the apps menu unless another button was pressed during the hold. No timer, because nothing needs one yet |

✅ **Decision 2's fallback was built and proven off-hardware before the Deck
session, as required.** Two of my own claims about it were wrong and were
corrected by measurement rather than argument:

1. *"`ExecStopPost` runs in every failure case"* — **false.** A cgroup-wide
   SIGKILL kills it too, because systemd spawns it into the unit's own cgroup.
   That is what `OnFailure=` on a separate unit now covers.
2. *"`OnFailure` should not fire on a clean auto-restart"* — **also false**, and
   `systemd.unit(5)`'s wording agrees with the wrong version. It fires on every
   restarting path, measured. Safe here because the restore unit can only ever
   write `on`, with a ~2 s margin; the worst case is STEAM+X dead until the next
   restart, never lost input.

⚠️ **One residual, documented in the source:** if the *user manager itself* is
destroyed, neither hook runs — but nothing is reading the pad then either, and
boot resets the parameter to `Y`, so it self-heals.

### 5.25a Three defects found while making the stages testable — deliberately NOT fixed

Found 2026-08-11 (session 19) by the agent implementing decisions 9 and 10.
Each was left alone because "production behaviour must not change" outranked
it in that task. They are real and they are now written down.

1. 🐞 **`verify_greeter_compositor_command` loses its own diagnostic.** Its
   `winner=$(cat … | grep … | tail -1)` under `set -euo pipefail` exits **1
   with no output at all** when no `CompositorCommand=` exists anywhere in the
   drop-in directory — so the explicit `fail` with the good message is never
   reached. Pre-existing, reproduced in a clean script rather than inferred.
   Exit code is the same either way; **only the reason goes missing**, which is
   the half a human needs at 2am.
2. **`stage_sddm_resilience` and `stage_greeter_rotation` have no
   `assert_ours_or_absent`.** The old suite header claimed `stage_return_icon`
   was the only stage missing one; it was not — what was unique to it was
   having *neither* marker nor check. Corrected.
3. ⚠️ **`stage_input_mapper` cannot be given a test seam without breaking a
   sibling suite.** `test/unit/test-osk-install-layout.sh` (~lines 148/158/198)
   `sed`s that stage's body out of `deck-session.sh` and greps it for three
   code shapes — one being the exact `$("$MAPPER_BIN" --type` substitution a
   seam would move. The attempt was made, seen to fail, and **fully reverted**;
   the stage is byte-identical to before apart from a comment recording the
   coupling. ⚠️ That comment deliberately does **not** quote the grep patterns:
   a comment that matched them would keep the sibling suite green with the code
   deleted — §7's artifact, manufactured on purpose.

### 5.26 ✅ RESOLVED ON HARDWARE 2026-08-11 — the lizard knob exists AND is writable in the live ISO

**T4's design gate is OPEN.** Measured from a root shell on **tty2 of the booted
ISO** (our 2026-08-10 build, OLED Deck), which is the environment the claim is
about — not the installed system, where every previous lizard-mode measurement
came from.

```
# cd /sys/module/hid_steam/parameters; ls -l
-rw-r--r-- 1 root root 4096 Aug 11 23:29 lizard_mode
# cat lizard_mode; uname -r
Y
7.1.6-arch1-…-T2-1-t2
# lsmod | grep hid_steam
hid_steam          36864  0
ff_memless         24576  1 hid_steam
# echo N > lizard_mode; cat lizard_mode; echo Y > lizard_mode; cat lizard_mode
N
Y
```

The node exists, mode **0644**, reads `Y`, `hid_steam` is loaded and bound
(pulling `ff_memless`), the kernel is a `-t2` build with no `valve` in it, and
**the write is accepted at runtime and reverts cleanly**. That last line is the
half that mattered: a 0644 sysfs parameter can still be rejected by the module,
and mode alone would have been "T4 has a keyboard on paper".

**Consequence: T4's bounded text-entry mode is reachable in the installer**, and
`docs/tasks/T4-screen-spec.md` §2.3 stands as specified. No rework needed.

⚠️ **Not proven by this, and do not let it drift into the record:** that a
*mapper* can bind a pad in the live ISO and deliver keys there. The knob being
writable removes the blocker; it does not demonstrate the input path. `python-evdev`
is still absent from the live environment (T4 §2.4).

*(History, kept because the shape recurs: this was 🔴 open, then 🟡 half-answered
off-hardware from `docs/findings/T4-harness-feasibility.md` §5 — `hid-steam.ko.zst`
ships in the ISO and `modinfo` declares the parameter, so the module and the knob
were known present, but QEMU has no Steam Controller to bind to (`hid_steam.loaded=0`)
and could answer neither "does the node appear" nor "is the write accepted". The
off-hardware half correctly predicted the outcome and correctly refused to claim
it.)*

**Original statement of the gate**, for anyone tracing why it was blocking:
`docs/tasks/T4-screen-spec.md` §8, unknown **U6**. One line to check, and it
decided whether T4 had a product.

**Every lizard-mode measurement this project owns was taken on the INSTALLED
system, running Valve's Neptune kernel.** The live ISO boots a different kernel
(`linux-t2`). R-8 proved lizard mode is *active* in the live environment — it
did **not** prove the module parameter exists or is writable there.

If `/sys/module/hid_steam/parameters/lizard_mode` is absent or read-only under
the ISO's kernel, **text-entry mode cannot be entered at all**: the Wi-Fi
passphrase screen and the account screen have no keyboard, and the
controller-only install — the entire point of the project — has no mechanism.

Of the five unknowns ranked beside it in that spec, **U2 and U3 are also now
settled** (U2 off-hardware in `docs/findings/T4-harness-feasibility.md`; U3 in
the same live-ISO pass as U6 — see §7). **U1, U4 and U5 remain open.**

### 5.26a Three defects in upstream's installer that strand a keyboard-less device

Read out of the dashboard while specifying T4. None is ours; all three land on
our users, and T4's wrap must handle them:

1. 🔴 **`failure_menu`'s Esc fallback is "Drop to shell."** Pressing **B** on a
   failed install lands a keyboard-less handheld at a bash prompt.
2. **"View full log" runs `less`**, which exits only on character keys the
   screen cannot produce.
3. **All 18 progress tips name keyboard shortcuts** (`Super + Space` …) on a
   device with no keyboard.

⚠️ **§6.1a never specified a Failure screen.** It is the screen most likely to
be reached by someone who cannot recover from it.

### 5.27 🆕 OSK auto-show is built but NOT SHIPPED — two hand-offs

Built 2026-08-11 (session 19). `src/deck_osk_focus.py` is now a shippable
program, `AutoShow` in the mapper consumes it, and `--osk-auto-show` turns it
on. **Default is OFF, deliberately:** taking the Wayland input-method seat
costs `fcitx5` its Wayland clients (R-50/R-51), which is the operator's call,
not ours.

**It does not reach a Deck yet.** Shipping it needs two edits in files another
agent held at the time, and they must land *together*:

1. **`src/deck-session.sh`** — add `deck_osk_focus.py` to `OSK_MODULES` and to
   the stage's import check; add `readonly MAPPER_OSK_AUTO_SHOW=0` beside
   `MAPPER_OSK_BACKEND`, appending ` --osk-auto-show` to `ExecStart` when 1.
   ⚠️ **Verify by importing, never by running it** — running it during install
   would try to take the seat.
2. **`test/unit/test-osk-install-layout.sh`** — it pins the exact module list
   and the exact import line, so it goes red the moment step 1 lands. Same
   commit, not a follow-up.

**And a third thing must move with them:** freeing the seat. On the dev machine
`fcitx5` starts from Omarchy's `autostart.conf` with
`--disable notificationitem`; auto-show needs `--disable notificationitem,waylandim`.
⚠️ **Append, never replace**, ⚠️ the path may differ on 4.0 (find it, do not
assume), and ⚠️ `omarchy-restart-xcompose` relaunches fcitx5 with the old flag
and would silently undo it.

⚠️ **Never observed in a single run:** a real compositor's `activate` reaching a
drawn keyboard. The handshake is proven against live Hyprland, and the mapper's
consumption is proven end-to-end against a real pad, pty and subprocess — but
the middle link is a stub, because closing it means restarting the operator's
`fcitx5` on their live desktop.

### 5.27a ✅ FIXED — a killed mapper could orphan the focus watcher, and an orphan keeps the seat

Pre-existing, **but newly consequential**: `SIGTERM` does not run the mapper's
`finally`, so a plain `kill` leaves the watcher alive — and a watcher holding
the input-method seat makes a *later* mapper's auto-show fail permanently with
`unavailable`, which reads exactly like "the feature is broken".

Under systemd's default `KillMode=control-group` the cgroup kill covers it.
Outside systemd it did not.

✅ **Fixed 2026-08-11:** `die_with_parent()` in `src/deck_osk_focus.py`, run at
the top of `main()` and **never at import** — the mapper imports this module and
`deck-session.sh` verifies OSK modules *by importing them*, so a module-scope
`prctl` would arm PDEATHSIG on the mapper and on the installer. **Two** guards,
because one is not enough:

1. `PR_SET_PDEATHSIG` → SIGTERM, with a `getppid()` re-check for a parent that
   dies between the read and the call.
2. ⚠️ **A wider race the usual guard does not cover:** a parent dying *before*
   the watcher's interpreter starts leaves `getppid()` already reading the
   reaper — **measured, 5/5**. So the watcher also polls its own stdout for
   `POLLERR`, which fires when the mapper (sole holder of the read end) is gone.
   New exit code `EXIT_ORPHANED = 6` with a sentence the mapper prints.

⚠️ **The thread trap is real, and was measured, not assumed.** A first attempt
appeared to disprove it only because the forking thread died *before* the
child reached the prctl. This is sound solely because the mapper imports no
`threading` — **spawning the watcher from a worker thread would silently break
auto-show seconds after startup, with nothing in the log.**
⚠️ Note the shape: this is the **same cgroup-versus-process reasoning** as
§5.25 decision 2's `ExecStopPost` hole. Two different features, one systemd
mental model — get it wrong once and it is wrong in both.

---

## 5.28 🔴 on a FRESH BOOT the mapper's children are born blind: no menus, and probably no keyboard

> ## ✅ CLOSED 2026-08-11 (session 21) — VERIFIED ON A COLD BOOT, TWICE
>
> The operator deployed the fix, powered the Deck **off**, booted it, and
> pressed the three buttons before touching anything. **All three worked.**
> The journal shows the race actually happening and the resolver closing it:
>
> ```
> [16.729] Starting deck-input-mapper
> [18.150] reading /dev/input/event7 (Steam Deck)
> [18.157] the session environment is not ready yet (missing WAYLAND_DISPLAY,
>          HYPRLAND_INSTANCE_SIGNATURE) ... which is what this polls for (§5.28)
> [19.159] session environment resolved
> ```
>
> One service start this boot; nothing restarted by hand. **The second cold
> case — Gaming Mode → Power → Switch to Desktop — also passes**, tested the
> same way. That path had never been tested before.
>
> 🔴 **But the first fix shipped a NEW defect, caught only by a human looking
> at the panel — see §5.30.** The keyboard came up *working and wrong*.

**Found on hardware 2026-08-11, by the operator noticing STEAM and QAM did
nothing after a reboot.** Every check said healthy. This is R-29's shape again,
one layer up.

**Symptom.** Boot to the desktop. `deck-input-mapper` is `active`, bound to
`event7`, `lizard_mode` is `N`, and the startup report prints both bindings
correctly. **STEAM and QAM do nothing.** `systemctl --user restart
deck-input-mapper` fixes it completely — operator confirmed STEAM, QAM **and
STEAM+X** all working immediately afterwards.

**Cause — measured, not inferred.** The mapper's whole environment on a fresh
boot is one variable:

```
XDG_RUNTIME_DIR=/run/user/1000
```

No `WAYLAND_DISPLAY`, no `OMARCHY_PATH`, no `HYPRLAND_INSTANCE_SIGNATURE`. The
unit is `WantedBy=wayland-session@hyprland.desktop.target` with **no ordering**,
so it wins the race against uwsm's environment import. The mapper itself does
not care — it reads evdev and writes uinput. **Its children do.** Running
`omarchy-menu toggle` under exactly that environment prints
`OMARCHY_PATH is not set` and exits. After a restart the same process has all
33 variables, because the manager's environment is populated by then
(`systemctl --user show-environment` confirms it holds `WAYLAND_DISPLAY=wayland-1`,
`OMARCHY_PATH`, `HYPRLAND_INSTANCE_SIGNATURE`).

### Why the obvious fix is wrong, in the unit's own words

`deck-input-mapper.service` carries this comment, and it is correct:

> ⚠️ **DELIBERATELY NO `After=graphical-session.target`.** That looks obviously
> right and creates an **ordering cycle** with the target this unit is
> `WantedBy`… systemd resolves the cycle by **DELETING this unit's start job**,
> so the service silently never runs. Measured on hardware. *The mapper needs no
> ordering anyway: it reads evdev and writes uinput, and never talks to the
> compositor.*

🔴 **That final sentence is now false, and its expiry is the actual bug.** It was
true when written. The mapper has since grown two compositor-dependent
behaviours — the STEAM/QAM bindings that spawn `omarchy-menu` (§5.23), and the
layer-shell OSK (`deck_osk_wayland.py`, T8 step 7). **A load-bearing justification
became untrue and nothing failed loudly.**

### Blast radius — 🔴 ALL OF IT MEASURED, and it is release-blocking

Confirmed by a deliberate cold boot 2026-08-11, pressing the buttons **before**
touching anything else:

| On a fresh boot to the desktop | Result |
|---|---|
| **STEAM+X** (raise the keyboard) | 🔴 **nothing** |
| **STEAM** (app launcher) | 🔴 nothing |
| **QAM** (Omarchy menu) | 🔴 nothing |
| All three, after `systemctl --user restart deck-input-mapper` | ✅ all work |

🔴 **A freshly booted Deck therefore has NO ON-SCREEN KEYBOARD**, on a device
whose entire premise is having no physical one. The squeekboard fallback does
not save it — it needs a Wayland connection too. **This blocks release**, and it
is worse than the §5.24 lock defect it resembles, because it needs no unlucky
timing: it is the *normal* path.

⚠️ **This was recorded as "inferred, probably" for one commit**, because the
operator's earlier "all three work" came *after* a restart and could not settle
it. The cold-boot test took two minutes and turned a hedge into a blocker. **The
hedge was right to exist and wrong to keep.**

⚠️ **The Gaming→Desktop switch path is NOT exempt**, though it is untested: that
path starts a fresh Hyprland session through sddm, so the same race applies.
Assume it is broken there too until someone boots into Gaming Mode, switches to
the desktop, and presses STEAM+X without restarting anything.

### The fix — 🟡 IMPLEMENTED (session 21), NOT YET VERIFIED ON HARDWARE

**Stop relying on inheritance.** Resolve the environment at *spawn* time rather
than at unit start — read `systemctl --user show-environment`, or launch children
via `systemd-run --user`, either of which works even when the variables arrive
late and neither of which reintroduces the ordering cycle. ⚠️ Whatever is
written, **the test must boot the machine**, because a mapper restarted by hand
always passes.

**What was built** (`src/deck-input-mapper.py`, new `SessionEnv` section):

- `SessionEnv` polls `systemctl --user show-environment` **on the main loop's
  clock**, not on a button press — its deadline joins `LockWatcher`'s in the
  `select()` timeout, so an untouched Deck keeps asking while nobody is
  pressing anything. `spawn_detached`'s "never block" rule survives untouched.
- Attempts are throttled to `SESSION_ENV_INTERVAL` (1 s) and stop on the first
  of two events: all three required variables present
  (`WAYLAND_DISPLAY`, `HYPRLAND_INSTANCE_SIGNATURE`, `OMARCHY_PATH`), or
  `SESSION_ENV_WINDOW` (60 s) elapsed — the live ISO has no user manager at
  all and must not poll a missing one forever.
- Reads are **merged, never replaced**: a transient empty answer cannot un-set
  a running session's display.
- **Every** child now names its environment — the menus, the layer-shell
  keyboard, the focus watcher, and `hyprctl` in the lock watcher. With nothing
  resolved, `environ()` is exactly `os.environ`, i.e. the behaviour that
  shipped: this can only add variables, never take a working spawn away.
- The unit in `src/deck-session.sh` keeps its comment about the ordering cycle
  and now records that the *"never talks to the compositor"* justification
  expired — that expiry, not a wrong line, was the defect.

**Evidence so far, and its limit.** `test/unit/test-deck-input-mapper.py` grew
to **302 assertions**, **9/9 mutations caught** (dropped `env=` at each of the
three spawn sites and at `hyprctl`, throttle removed, merge turned into
replace, give-up removed, value truncated at the second `=`, and both halves of
the main-loop wiring deleted). The last two are asserted **structurally**
against the source's AST, because `main()` cannot be entered without a device —
without them, deleting the poll leaves the whole suite green, which is §5.28
verbatim. The parser was also run against this dev box's real
`systemctl --user show-environment`: **187 lines, 187 parsed, 0 dropped**, and
it resolves. ⚠️ **No quoted value appeared in that sample**, so the shell-quoting
path is covered only by synthetic input.

🔴 **None of that is the verification.** The mapper has never started on a Deck
that was cold-booted with this code. **The check is still §5.28's: boot the
machine, press STEAM / QAM / STEAM+X before touching anything else**, and read
the journal for `session environment resolved`. A hand-restarted mapper passes
either way.

⚠️ **T5 inherits this.** A built image has the same race, and a first-boot user
gets a desktop with no menus and possibly no keyboard.

---

## 5.29 🆕 The Steam-in-background option: closed, then REOPENED by measurement — T10 decides it

**2026-08-11, session 20, operator-driven.** Short version; the evidence is
`docs/findings/P20-steam-xtest-closure.md` (R-53 + R-54 addendum), the next
action is `docs/tasks/T10-steam-extest-spike.md`.

- **R-53:** real XTEST reaches neither Wayland-native clients nor Hyprland's
  pointer (measured with a positive control that caught a wrong first run). The
  stock-Steam route is dead, and now for a stated reason: SteamOS Desktop Mode
  is X11; Omarchy is not.
- **R-54:** the operator asked for one last try at higher effort, and it found
  what the first analysis missed — **extest** (MIT, pinned `cb77cd4`, v1.0.4),
  the community's LD_PRELOAD bridge converting XTEST calls to **uinput** before
  they leave the process. **Measured on this Hyprland: its keystrokes land in a
  Wayland-native terminal and its motion moves the compositor cursor.** The
  mechanism Steam needs exists.
- **Unmeasured, and the whole remaining question:** Steam itself driving it.
  Steam's input process is 32-bit; the i686 build is at
  `~/ISOs/extest-cb77cd4/`, reproducible via `tools/build-extest.sh`
  (pinned, licence-gated, contained toolchain). **T10 is one ~45 min Deck
  session** with file oracles and a decision table.
- 🔴 **Known already, whatever T10 finds:** Steam's keyboard is an XWayland
  window and **cannot render above `ext-session-lock`** — §5.24's our-OSK lock
  fix stays load-bearing in every future. And row 7 of T10 tests the hard case:
  a locked session under a resident Steam may be unanswerable without USB/SSH,
  because our mapper has no pad while Steam holds it.

⚠️ **The approved OSK touch/restyle plan is ON HOLD pending T10** — deliberate,
operator-chosen: if Steam+extest works, most of that desktop work is moot, and
the layout-parity agent was paused *before* executing its Caps/Shift rework for
exactly this reason. Our OSK remains the installer's and the lock's keyboard
regardless of the outcome.

### ✅ T10 WAS RUN, 2026-08-11 (session 21). Rows 1–3, 6, 8 PASS.

Full evidence: **`docs/findings/T10-steam-extest-results.md`**. One sentence:
**Steam's own keyboard genuinely drives our Wayland desktop through extest —
letters typed with the trackpads landed in a Wayland-native client's file, not
just on screen.** The untested link is now tested and it holds.

🔴 **Three corrections to T10's own procedure, each of which alone would have
produced a WRONG answer:**

1. **The spec deploys one library; both are needed.** `steam` is 32-bit but
   **nine `steamwebhelper` processes are 64-bit and rejected the i686 build**
   (`wrong ELF class: ELFCLASS32`). Preload both, colon-separated.
2. **`extest fake device` does not exist until the first XTEST call.** The
   step-2 checkbox expects it at launch; its absence is not a failure.
3. 🔴 **`hyprctl dispatch`'s old string syntax is a Lua SYNTAX ERROR on
   Hyprland 0.56.2** — see §5.30. Nothing to do with Steam; a live hazard for
   this repo.

**Row 4 (touch) fails, and it is not Steam's fault** — touch does nothing
anywhere on this desktop (§5.30). **Row 7 (the lock) was skipped** by operator
decision; its prediction is recorded as *inferred*, not measured.

**The decision is the operator's and is NOT made.** What is unchanged either
way: our OSK stays the installer's and the lock screen's keyboard, because
Steam's is an XWayland window that cannot render above `ext-session-lock`.

---

## 5.30 🆕 Three defects found on 2026-08-11 (session 21), all by looking rather than checking

Grouped because they share one lesson: **each was invisible to every automated
check in this repo, and each was found by a human looking at the panel or by
reading another program's real output instead of an imagined one.**

### 5.30a ✅ FIXED — systemd quotes ANSI-C, and the keyboard was working-but-wrong

§5.28's fix parsed `systemctl --user show-environment` and unquoted `'...'` and
`"..."`. **On a real session that machine emits SIX values as `$'...'` and ZERO
in either handled form.** So `GDK_BACKEND=$'wayland,x11,*'` reached GTK
verbatim, GTK reported `No such backend: $'wayland`, and the layer-shell
keyboard **fell back to an ordinary window** — it appeared, full-screen instead
of anchored, and would **not** have rendered above `ext-session-lock`, silently
undoing the §5.24 lock fix that had been verified in pixels.
`QT_QPA_PLATFORM=$'wayland;xcb'` was mangled identically.

⚠️ **The keyboard worked. Nothing looked broken.** The operator said "the
keyboard was the size of the entire screen" and that was the whole detection.
The commit that introduced it had even flagged the gap — *"no quoted value
appeared in that sample, so the shell-quoting path is covered only by synthetic
input"* — and the synthetic input was wrong about reality. **Fixtures are now
the Deck's own six lines, verbatim.** Fixed and re-verified in pixels.

### 5.30b ✅ AUDITED 2026-08-12 — `hyprctl dispatch`'s old syntax is a SYNTAX ERROR on 0.56.2

Hyprland 0.56.2 (what the Deck runs) replaced dispatch's string arguments with
a Lua dispatcher API. `hyprctl dispatch movetoworkspacesilent 2,address:0x...`
now fails with `')' expected near '2'` — **a parse error, not a no-match.**
Working form: `hyprctl dispatch 'hl.dsp.focus({ workspace = 2 })'`. The full
namespace listing is in `docs/findings/T10-steam-extest-results.md`.

**Audit result: this repo makes ZERO `hyprctl dispatch` calls of any kind.**
Every `hyprctl` invocation we ship or run is a *query* — `-j monitors`
(`src/deck-input-mapper.py`'s lock watcher), `-j activewindow` and `cursorpos`
(the two `test/xtest-*.py` spikes) — and queries are unaffected; only
`dispatch` grew the Lua API. `src/deck-session.sh` names `hyprctl` once, in a
comment, and invokes it nowhere. The generated greeter Lua already uses the
new API (`hl.config`, `hl.monitor`). `docs/RECOVERY.md` uses `hyprctl eval`,
which is the Lua entry point and is the form measured against the Deck.

⚠️ **The old form does survive in one place we do not own:**
`iso/upstream/bin/omarchy-iso-test` — a vendored read-only mirror of
`basecamp/omarchy` — runs `hyprctl dispatch workspace 1` with stderr discarded
and `|| true`. Upstream half-migrated that file: its two `window.close` calls
already try `hl.dsp.window.close({...})` *first* and fall back to the old
bareword, but the workspace reset never got the treatment. It affects
upstream's own ISO test, not our boot or install path. Nothing to fix here;
fixing the mirror would be reverted by the next vendor refresh.

🆕 **What was actually wrong was the *other* hyprctl hazard, in a runbook.**
All three `ssh steamdeck … hyprctl …` commands in
`docs/tasks/P2.9-deck-session-runbook.md` omitted `HYPRLAND_INSTANCE_SIGNATURE`
(R-46), so they exit before running — and §4's is a **checkbox** reading
"`configerrors` reports nothing", which passes on a command that never ran.
§0.1 and §4.1 also still offered `clear_crashed_lockscreen` as the lock escape
*after* session 20 measured it refusing healthy locks; `docs/RECOVERY.md` had
been corrected, the runbook had not. Both fixed.

🔒 **Guarded, so it cannot come back silently:**
`test/unit/test-hyprctl-syntax.sh` (18th suite → 19) scans every tracked *and*
untracked file for these hazards and fails on any of them. **A third scanner was
added 2026-08-12** — the dead `eval` sentinel readback (§5.30c) — bringing it to
three. Each carries positive **and** negative controls, because a grep that has
stopped matching reports a clean tree — the "found nothing reads as found no
problems" class that `test-duplicated-upstream-facts.sh` also guards against.
Mutation-tested: injecting a bad dispatch into `src/deck-session.sh`, injecting a
bare `ssh … hyprctl` into `RECOVERY.md`, injecting a readback into
`T5-fork-plan.md` and the P2.9 runbook, breaking each scanner's regex four
different ways, weakening the negative control, and dropping a protected file out
of scope. Every one is caught; the only survivors are deleting an assertion or a
control outright.
⚠️ It asserts which *shape* is written down; that the Lua shape works is T10's
measurement, not the suite's — nothing here talks to a live compositor.

### 5.30c ✅ SOLVED 2026-08-12 — the touch transform, confirmed by A/B on hardware

⚠️ **This section flip-flopped twice before landing here. The record of that is
kept deliberately, because the mistakes are more instructive than the answer.**

**The cause:** `input:touchdevice:transform` was `0` while the display runs
`transform = 3`. Touches arrived the whole time and landed ~90° from the finger.

**The fix, and it is one line:**

```bash
hyprctl eval 'hl.config{ input = { touchdevice = { transform = 3 } } }'
```

🔴 **`hyprctl keyword` CANNOT set this** — it answers *"keyword can't work with
non-legacy parsers. Use eval."* The working form is a **nested Lua table**, not
the colon-path string every Hyprland doc uses. Third §5.30b-class trap today.

#### How it was actually established, after two wrong turns

| | |
|---|---|
| **Claim 1** | "Solved — the touchscreen was unrotated." Set the transform, saw touch work, wrote it down. **No before/after measurement.** |
| **Retraction** | The operator said touch behaved the same *before* the change. Claim withdrawn — correctly, since it had never been measured. |
| **Over-correction** | The retraction went too far: it recorded the cause as *unexplained* and blamed a probable Steam confound. |
| **Claim 2, measured** | After a reboot cleared the runtime setting, touch broke again. At `transform = 0` the operator reported *"things are moving but nothing is behaving quite right"* — taps landing in the **wrong place**, the signature of a transform mismatch. Set `3`: *"touch is working correctly now."* **One variable, two readings, reported by a human looking at the panel.** |

⚠️ **Two of my own instruments failed during this, and both looked like data:**

1. I captured `/dev/input/event9`, the node the touchscreen used *that morning*.
   **Node numbers move across boots** — it was `event14` last night and `event14`
   again now. I read an unrelated device and got "0 bytes".
2. The replacement capture ran `cat` **without `sudo`** against a `root:input`
   node. Permission denied → 0 bytes, silently, and it read as "no events".

Both readings said "the kernel is emitting nothing", which was false both times.
**The operator's eyes were the only reliable oracle in the whole exchange.**

#### ✅ PERSISTED 2026-08-12 in `~/.config/hypr/input.lua`

Appended **before** that file's parse sentinel, deliberately: a Lua syntax error
makes Hyprland discard the **entire file**, and the file also carries §5.24's
`above_lock = 2` layer rule — the one that makes the lock screen answerable. A
careless append could have taken the lock keyboard down with the touchscreen.

**How it was proven, and how it was NOT.** Forcing `transform` back to `0`,
running `hyprctl reload`, and watching it return to `3` is the evidence. ⚠️ **I
first cited the file's `DECK_INPUT_LUA_LOADED` sentinel as proof, and that was
worthless** — `hyprctl eval` given a bare return prints `ok` and exits **0** for
a name that has never existed, measured with a negative control. **This file
already recorded that** (§7, twice) and I used the check anyway without
re-reading it.
⚠️ The comment inside the Deck's own `input.lua` still says *"A nil result means
this file was discarded"* — **that is false**, and any procedure resting on it
is a check that cannot fail.

✅ **CLOSED 2026-08-12 — the recipe is fixed everywhere this repo controls.**
The working probe is an assertion, `hyprctl eval 'if DECK_INPUT_LUA_LOADED ==
nil then error("…") end'` (exit 0 loaded / exit 7 discarded), copied from
`verify_osk_kb_layout`'s shape. It is now the text `docs/tasks/T5-fork-plan.md`
§5.6 bakes into a built image, the check in `docs/tasks/P2.9-deck-session-runbook.md`
§4, and `test/unit/test-hyprctl-syntax.sh`'s **scanner 3**, which fails CI if the
readback shape is written down in any file this project ships or runs. 🔴 **The
Deck's own `input.lua` is still wrong and was deliberately not touched** — it is
the operator's machine and every write there needs their approval. It is a
one-line comment fix whenever they want it.

##### 🔴 This is a CLASS, not an incident — four found on 2026-08-12

Every one has the same signature: **the passing state is indistinguishable from
the not-having-run state.** Worth grepping for deliberately, because none of
them ever goes red on its own.

| Where | The check | Why it could not fail | Status |
|---|---|---|---|
| the Deck's `input.lua`, and every doc quoting it | read the sentinel back with a bare Lua `return` | `hyprctl eval` reports its own status, never a value — exit 0 for a name that never existed | ✅ corrected at the source of truth; scanner 3 enforces |
| `T5-fork-plan.md` §5.6 `[V]` | "`hyprctl configerrors` is empty after the layer rule is applied" | it is empty *precisely* when the file was discarded, because nothing was parsed. It catches a renamed **key**, never a discarded **file** | ✅ replaced with the sentinel assertion |
| `P2.9-deck-session-runbook.md` §0.2 | the pre-flight one-liner ended `&& echo "all suites green"` | printed unconditionally, after a loop that only `echo`ed `RED` — and swallowed the count, so a glob matching nothing also read as green | ✅ now carries a denominator and refuses to affirm a red tree |
| `T4a-dashboard-screens.md` §"dead code" | "`grep -n 'failure_menu' configs/airootfs/root/configurator` returns nothing" | that path does not exist at this repo's root (the tree is vendored under `iso/upstream/`), so grep exited **2** — *no such file* — which reads exactly like *no match* | ✅ path corrected, exit code asserted; the conclusion survived re-checking |

**The generalisation worth keeping:** a check that proves something is ABSENT
must also prove it was LOOKING. Assert the exit code, print the denominator, and
give the scanner a positive control — `test/unit/test-hyprctl-syntax.sh` and
`test-duplicated-upstream-facts.sh` both do this, and it is why they are trusted.

⚠️ **Still owed:** this lives in one user's dotfile and is therefore **absent
from a built image**. `T5-fork-plan.md` §5.2 owes it a bake-in row — it already
owes three rotations and now owes four. *(An earlier operator decision said not
to persist it, on the then-correct grounds that it demonstrably changed nothing.
That basis is gone; they approved persisting once the A/B settled it.)*

#### The FIFTH rotation value, and why that matters

The setting is **runtime-only and dies on every Hyprland restart**. `T5-fork-plan.md`
§5.2 already owes a bake-in row for it — and note this makes a **FIFTH** rotation
value across five mechanisms that do not follow from one another (§5.11 records
four). *(An earlier operator decision said not to persist it, on the then-correct
grounds that it demonstrably changed nothing. That basis is gone.)*

#### Separately: our OSK is input-transparent ON PURPOSE

`src/deck_osk_wayland.py` sets `surface.set_input_region(cairo.Region())` — an
**empty** region — plus `KeyboardMode.NONE`, so it receives no touch and no
pointer. That is what stops the overlay stealing focus or swallowing clicks
(T8 step 7). Supporting touch on the keyboard is a **scoped change** — give the
surface a real input region and handle touch-down — that trades away the "can
never swallow a click" property. Still operator-gated.

### 5.30d 🔵 (was 5.30c's placeholder)

Discovered as T10 row 4 and then isolated: taps do nothing on Valve's keyboard
**and nothing anywhere else on the desktop**. Not a Steam problem. The kernel
exposes the panel (`FTS3528:00 2808:1015`, `event14`/`event15`) and **Hyprland
has it bound** (`Touch Device ...: fts3528:00-2808:1015`), so this is not a
missing device.

Nobody had ever tested desktop touch. It affects any future touch plan for our
own OSK equally, and the approved touch/restyle plan assumes touch works.

---

## 5.31 🆕 Omarchy 4.0.0 STABLE shipped 2026-08-14 — pin measured, delta classified (session 27, 2026-08-15)

Upstream released **Omarchy 4.0.0 "Quattro"** on 2026-08-14 (`basecamp/omarchy`
tag `v4.0.0` = `f0020448`). This is the target `CLAUDE.md` names and the event
P3.6 waited on. Per the ROADMAP escalation, stable landing this close to phase
2.9 collapses 2.9 + P3.6 into **one** rebase.

**The pin, measured from inside the downloaded stable ISO** (full detail:
`docs/findings/T9-stable-pin.md`):

- basecamp/omarchy **`f0020448`** · omarchy-iso **`174dd82`** ("Install the
  published Omarchy packages in the default build", 3 min before the airootfs
  was sealed) · omarchy-pkgs **`bb66b9d`** ("Release omarchy 4.0.0")
- **Channel `stable`** (was `edge`) · runtime package **`omarchy 4.0.0-1`**
  (renamed from `omarchy-dev`, which declares `provides=omarchy`+`conflicts=omarchy`)
  · settings **`omarchy-settings 4.0.0-1`** · version string **`4.0.0`** (a real
  release string at last, not `4.0.0.alpha`)
- ISO `omarchy-4.0.0.iso` 6,273,040,384 B, sha256 `9224fab3…` **matches
  upstream's published checksum**.

**The delta `6d7826d` → `f0020448` is 127 commits / 243 non-test files** — a real
release, not the same-day rebuild phase 2.9 turned out to be. Classified file by
file across four seams by independent agents, each citing read hunks
(`docs/findings/T9-stable-delta-classification.md`):

- **1 BREAKS US**, and it self-heals: the ISO orchestrator's
  `omarchy-setup-system` call → `omarchy-apply-system` (R082). omarchy-iso
  `174dd82` already calls the new name, so the **submodule bump fixes it**; and
  `iso/bin/build` guard 6.4a `build_fail`s loudly if the pin moves without it
  (test-iso-build case 12 encodes exactly this).
- **Boot chain SAFE**: `omarchy-defaults.conf` byte-identical; the limine-cmdline
  migration only rebuilds the UKI from unchanged drop-ins, *preserving*
  `fbcon=rotate:1`. No migration reverts idle/rotation/lizard/backlight.
- **Lock SAFE**: the stranded-lock recovery path exists but is already neutered
  in our tree (`idle.lock=86400` + sleep-lock mask + `above_lock=2`); our
  blank-timer patch still `git apply --check`s clean.
- **Desktop Mode menu row SURVIVES**: the JSONC command-palette rewrite left the
  extension mechanism intact — T3's fallback-free integration point holds.
- **All 5 ISO overlay patches apply clean** against `174dd82` (`git apply --3way
  --check` verified), so the submodule bump is not blocked.
- **The tzupdate §7 to-do is CLOSED with no edit** — the comment was already
  correct (verify-don't-trust).

**The one NEW operational risk is SSH-abort, not reverted settings.** Five stable
migrations call `sudo` without NOPASSWD, and the edge→stable package swap forces
pacman to remove `omarchy-dev` (conflict). A headless `omarchy-update` over SSH
can hang on any of these — the Deck runbook uses `ssh -t` + primed sudo for
exactly this.

**✅ State at session-27 close: THE ISO IS BUILT AND THE REBASE IS MERGED TO `main`.**

`omarchy-2026.08.15-x86_64-quattro.iso`, 6.38 GiB, sha256
`e9fbd8edb8c69d698c5e575955a2dd27d4f394a704c7b6b55744a817748368c5`, build exit 0,
**all eight guards green**. `main` after the merge is identical to the pre-rebase
baseline — shellcheck green, 18/20 sh, 13/13 py, same two pre-existing reds, **no
regressions**.

**Path B, by operator decision**, and measurement dissolved its one cost: the
`stable` channel serves `omarchy-dev-4.0.0.r1744.gf002044-1` — `gf002044` **is**
our pin — so on stable the `-dev` build *is* the release commit and guard 6.4b's
sha-provenance check needed no redesign. (Path A would have required one: the
released `omarchy 4.0.0-1` carries a static pkgver with no `.g<sha>`.)

**§14.6 is root-caused and fixed on the way through.** `gamescope-session` (added
session 26, never build-validated) exists in **no** Valve repo. The session file
autologin needs is shipped by the gamescope package itself and **only Valve's
build** of it (Arch's ships no `wayland-sessions/` at all). Our mirror already
carried Valve's build; **nothing installed it**. Now it is on the install list —
verified in the artifact, along with `gamescope-wayland.desktop` and
`start-gamescope-session` inside the shipped package. ⚠️ **Payload-level only:
"first boot lands in Gaming Mode" is still unproven** — that needs
`vm-install-controller-test.sh` against this ISO (its disk-image assertions remain
never-executed) and then P3.2 on hardware.

Full account, including the mirror-vs-install list conflict this exposed:
`docs/findings/T9-stable-rebase-remaining.md`. The Deck update itself is
operator-present (runbook ready). See §6.

### 5.31a ✅ THE ISO INSTALLS — 18/18, `autologin: gaming`, criterion 1 CLOSED (same session)

The new ISO was put straight through `test/vm/vm-install-controller-test.sh` and
**passed 18/18** with `install.outcome=success` (56 s of a 2100 s deadline, KVM).
**The harness's disk-image assertions ran for the first time in this project's
history** — they were gated on a completed install, so every previous run skipped
them. They pass: one ESP + one root partition, the UKI `omarchy_linux.efi`, a
`/limine.conf` that references it, the expected package set, hostname
`steamdeck`, and **zero LUKS crypttab entries** (the encryption-off contract
proven at the disk level, not at the form).

**`autologin: gaming`.** Read off the target's `@log/omarchy-deck-install.json`,
every `configure_deck` step succeeded — `autologin` **gaming**, `desktop_rotation`,
`idle_policy`, `limine_rotation`, `lock_wake_dpms`, `mask_sleep_lock`,
`menu_lock_row` overridden, `patches` applied, `session_dconf`, `tty_rotation`,
and `wifi: no-hardware` (expected; the harness is deliberately `-nic none`). The
installed `/etc/sddm.conf.d/zz-deck-session.conf` carries
`User=deck` / `Session=gamescope-wayland` / `Relogin=true`.

**§14.6 is closed end to end**, verified on the installed target rather than in
the payload: `gamescope-wayland.desktop`, `/usr/bin/gamescope`,
`/usr/bin/start-gamescope-session`, and `gamescope-3.16.25-3` (Valve's build) in
the target's pacman DB.

⚠️ **QEMU, not hardware.** This proves the installer, the boot-chain artifacts and
the session *selection*. It does **not** prove gamescope renders or that Gaming
Mode is usable on the panel (R-38's standard) — that is P3.2. Nothing here ran on
the operator's Deck, which is still on the beta-2 pin.

Detail: `docs/findings/T4-controller-only-install-first-run.md` §15. Evidence
preserved at `~/.cache/omarchy-deck/stable-rebase/install-test/`.

### 5.31b ✅ Criterion 4 closed — NVIDIA dry-run proven in a real build; publishing rescoped to P3.7

**PHASE 2 IS NOW 4 OF 4.** Criterion 4 was *"CI publishes an ISO artifact; a dry
run shows zero NVIDIA packages."* Both halves resolved 2026-08-15, one of them by
a deliberate rescope stated out loud rather than quietly ticked.

**The NVIDIA half is genuinely closed.** `deck-nvidia-dry-run.sh` was
"unit-proven but has never run inside the real build". It ran inside the real
container build, and — the part that makes it mean anything — **its negative
control fired**: with the three Deck packages removed the resolve *does* surface
NVIDIA drivers, and with them present it does not.

```
[deck-nvidia-dry-run] dry run over 169 targets (installed set + steamdeck-dsp steam)
[deck-nvidia-dry-run] negative control fired as designed: egl-gbm egl-wayland
                      egl-wayland2 egl-x11 lib32-nvidia-utils nvidia-utils
[deck-nvidia-dry-run] OK: 1030 packages resolved, 0 NVIDIA driver packages
[deck-nvidia-dry-run]     accepted by exception: linux-firmware-nvidia
```

**The publishing half is RESCOPED to P3.7, by operator decision.** It required a
self-hosted runner, and **this repo is public** — GitHub advises against
self-hosted runners on public repos because a fork's PR can run arbitrary code on
the runner host, which here is the dev machine holding the SSH key to the Deck.
Declined deliberately. A ~6 GB ISO is a poor Actions artifact anyway (retention
clock, slow upload), and `ci.yml`'s own comment already names a **release asset**
as its real home — which is P3.7. `ci.yml` now records this as a decision so no
future session "fixes" it by registering a runner.

⚠️ **The CI `iso-build` job itself has still never executed** and `ci.yml` still
says so (its test asserts that sentence stays). What is proven is what the job
would do: the local build, all eight guards green (§5.31).

**A real latent bug fell out of this.** The `Upload ISO artifact` step had **no
`if:` gate** despite its own comment promising opt-in — every run would have
attempted the 6 GB upload and failed *after* a 1–3 h build, reading as "the build
broke". Now gated; `test-ci-workflow.sh` is green (15/15) after being red the
whole time. Unit suites: **19/20** (the last red, `test-vm-probe-integrity.sh`,
is a scanner that cannot classify a heredoc — not a product defect).

### 5.32 🔴 THE FIRST HARDWARE FIRST-BOOT — four P1s in one evening, and they are one defect

**2026-08-15, session 28.** The stable ISO (`e9fbd8ed…68c5`, the one that scored
**18/18 in QEMU**) was booted on the physical OLED Deck for the first time. It
installed, and then the machine **could not do its job**. Four separate P1s
surfaced within the hour, and — this is the finding that matters — **they are the
same defect wearing four faces**:

> *A component exists, is unit-tested, is documented, and is never wired into the
> install.*

| # | Symptom on hardware | The component that exists | Where it was never wired |
|---|---|---|---|
| 1 | Installer's Wi-Fi/username/password screens have **no on-screen keyboard** | `src/deck-input-mapper.py` + its OSK modules | never staged into the live airootfs; `python-evdev` absent too |
| 2 | First boot is a **black screen** | `steam` in `deck-fetch.packages`; Neptune kernel + `steamdeck-dsp` in `deck-mirror.packages` | **nothing reads either list to install anything** |
| 3 | Steam modal: *"Unable to download the required update (2)"*; **brightness slider dead** | `steamos-update` + `steamos-priv-write`, fully implemented **inside `src/deck-session.sh`** since an earlier session | `deck-session.sh` is never run by the installer |
| 4 | **No "Switch to Desktop"** in Steam's power menu | the whole session layer in `src/deck-session.sh` | same — installer never runs it |

Findings: `docs/findings/P32-osk-mapper-missing-from-live-iso.md`,
`docs/findings/P32-steam-never-installed.md`.

**The measurement failure is the headline.** The install's own record showed
**eleven steps, all green** (`autologin: gaming`, `wifi: connected`, rotation,
patches, dconf…) on a machine that could not reach Gaming Mode. QEMU scored
18/18 on the same basis. **Every assertion checked that OUR STEPS RAN; none
checked that the OUTCOME EXISTS.** The structural answers, both now being built:
a build guard that a `configs/deck/*.packages` file **nothing consumes** is a
build failure, and **outcome assertions** against the installed image (is `steam`
there? `steamos-session-select`? the Neptune UKI?).

**Two inference errors cost the first diagnostic hour, recorded so nobody repeats
them:**
1. **Trackpad haptics do NOT prove the OS booted.** The Deck powers on in
   `lizard_mode`, where controller *firmware* emulates a mouse and generates
   haptics with no kernel involvement whatsoever.
2. **A healthy boot is visually identical to a dead one.** The cmdline carries
   `quiet splash loglevel=0 systemd.show_status=false rd.udev.log_level=0
   vt.global_cursor_default=0` — no messages, no cursor, nothing on any VT. "Black
   on every VT" was read as "never reached userspace"; the journal showed two
   complete boots.

**A bug caught by running the stages live — and a first diagnosis of it that was
wrong, corrected here the same evening.** `src/deck-session.sh` hardcoded
`/sys/class/backlight/amdgpu_bl0/brightness`, and this Deck has **only
`amdgpu_bl1`**. The first reading (mine) was *"the `steamos-priv-write` whitelist
permits a node that does not exist, so brightness stays dead."* **That is false,
and measurement killed it:** the whitelist is a regex over the device component —
`^/sys/class/backlight/[A-Za-z0-9_.:+-]+/brightness$` — so it is device-name
agnostic and **accepted `bl1` the whole time**. Proven by executing the real
rendered helper.

The actual defect was in the **verification**, which is worse and much easier to
miss. `DECK_BACKLIGHT` (the hardcoded `bl0` path) was the node
`verify_priv_write_helper` writes to prove the helper works. That file does not
exist here, so verify took its `[[ -r $bl ]]` else-branch, warned, and **the
stage reported ok having never exercised the write path at all.** The device's
own journal from the live 13:33 run is the proof — two refusal lines logged
(`/etc/shadow`, a non-numeric value) and **no accept line**. The non-numeric
check proves nothing about the node either: the value guard rejects before the
path is touched, so it logs identically against a node that does not exist.
Textbook §5.30c — *the passing state was indistinguishable from the
not-having-run state.*

**The index is assigned by driver enumeration and is not stable**: measured `bl0`
under Neptune, `bl1` under stock `linux 7.1.8-arch1-3`. Now discovered at runtime
(`BACKLIGHT_GLOB` + a three-outcome `find_backlight`: found / no backlight class
at all → warn / backlights exist but none is amdgpu → fail), with the three
outcomes finally under test. Measured context: Steam asks for that node **1051
times in one session**, and it is mode `0644 root:root`, so the helper is the
only possible writer — there is no path where the slider works by accident.
**Still unproven on hardware: a successful write.** The acceptance test is a
`steamos-priv-write` *accept* line in the journal, not a slider that looks like
it moved.

**Also confirmed good, first hardware evidence for all of it:** the UKI builds
(`omarchy_linux.efi`, 75 MB) and `limine-mkinitcpio-hook` fires; Limine renders
rotated correctly; `fbcon=rotate:1` reaches the real cmdline; autologin lands on
`gaming` with the right session file; gamescope runs; the Wi-Fi profile carries
from the installer and reconnects on its own; live-ISO Wi-Fi works on stable.

### 5.33 ✅ All four P1s wired, plus three bugs found on the way (session 28)

Five parallel Opus agents, disjoint file ownership, merged and verified by hand
rather than by reading their reports. What landed:

| Fix | Mechanism |
|---|---|
| **OSK in the installer** | build stages the mapper + its tty OSK modules into the live airootfs; `python-evdev` via a new `deck-live.packages`; **guard 6.7** |
| **Steam / black screen** | new `deck_pkgs.py` step installs `deck-fetch.packages` online at install time, re-queries after (a zero exit that leaves the package absent is `failed`), and a self-disabling first-boot service says so on the machine if it did not land |
| **Session layer** | new `deck_session_bake.py` runs `src/deck-session.sh` **inside the target** — not a second implementation. Delivers `steamos-session-select`, the `steamos-*` helpers and the target mapper, i.e. the Desktop row, the update modal and the brightness writer in one |
| **Neptune only** | `deck-form.sh` overrides upstream's `detect_kernel()`; it is sourced into `configurator` **101 lines before** the call, measured on the patched file |
| **The disease itself** | **guard 6.8** — a `configs/deck/*.packages` nothing installs FAILS THE BUILD (a checker's read does not count) — and **outcome assertions** on the installed image |

**Three bugs nobody had spotted, each found only by doing the work:**

1. 🔴 **`deck-fetch.packages` was never on the ISO at all.** `configs/deck/` lands
   in the archiso *profile*; mkarchiso only copies `airootfs/` into the booted
   root. A correctly-written fetch step still could not have read it. Two
   independent bugs stacked behind one symptom.
2. 🔴 **`linux-firmware-neptune` in the pacstrap list would have killed every
   install at phase 3.** Valve declares `conflict`/`replaces` against
   `linux-firmware` **only** (`linux-firmware-whence` is a `depend`, not a second
   conflict — corrected 2026-08-15 by re-reading `.PKGINFO`; the consequence and
   the code are unchanged, the earlier prose was off by one). Arch split the
   firmware into subpackages, so pacman removes the one it is told about and dies
   on file conflicts with the rest — *measured in a VM* by
   `src/omarchy-deck-kernel.sh`, which works around it with `pacman -Rdd`.
   Pacstrap has no such step. Removed; safe because `linux-neptune-611`'s
   `.PKGINFO` depends only on `coreutils/initramfs/kmod` (read from the package).
3. **`mangohud`/`lib32-mangohud` were consumer-less too**, and load-bearing —
   `deck-session.sh` warns Gaming Mode's overlay needs `mangoapp`.

**And one in our own new code**: the build's session-staging derived its module
list from `deck-session.sh`'s `OSK_MODULES`, whose **first element is a
variable** (`"$OSK_SRC_NAME"`), so the scrape yielded a filename of
`$OSK_SRC_NAME`. Found by reading back what the extraction actually produced
instead of assuming it worked. It now resolves `$NAME`/`${NAME}` against the
file's own `readonly` and refuses anything still unexpanded.

**Two claims in this document were wrong and are corrected above**: the
whitelist/`bl1` diagnosis (§5.32), and `CLAUDE.md`'s Deck pin. Both were mine,
both were plausible, both died to measurement.

### 5.33a ✅ The ISO built and the fixes are verified in QEMU (same session)

**`omarchy-deck-2026.08.15-P32FIXES-x86_64.iso`**, 6.4 GiB, sha256
`67290d46…a8fa`, build exit 0, **all nine guards green** (6.1, 6.3, 6.4a, 6.4b,
6.5a, 6.5b, 6.6, 6.7, **6.8**). Built in a fresh scratch dir after the first
attempt died on a corrupted cached `omarchy-keyring` — the third time that
class has come out of `~/.cache/omarchy-deck/iso-build`, which `docs/PROGRESS.md`
already calls stale; **stop reusing it**.

**Two install runs, because one cannot answer both questions.**

| | offline (`-nic none`, the default) | networked (`VM_NIC=user`, new) |
|---|---|---|
| result | **34/37**, `install.outcome=success` | **36/37**, `install.outcome=success` |
| `steam` installed | FAIL — *correct*: fetched online by design, so offline it can only report the degradation | **✅ yes** |
| Steam bootstrap tarball | FAIL — same cause | **✅ yes** |

Everything else passed in both, and these are the assertions that **fired on the
pre-fix ISO**:

- `/usr/bin/steamos-session-select` ✅ — the missing "Switch to Desktop"
- `steamos-update` + `steamos-priv-write` ✅ — the ENOENT update modal and the
  brightness writer
- `/usr/local/bin/deck-input-mapper` on the target ✅ — Desktop Mode navigation
- live ISO carries the mapper, **executable** (`-rwxr-xr-x`), `python-evdev`
  installed ✅ — the installer's on-screen keyboard
- `steamdeck-dsp` ✅, `gamescope-wayland.desktop` ✅
- **stock `linux` ABSENT**, and **exactly one UKI:
  `omarchy_linux-neptune-611.efi`** ✅ — Neptune-only works end to end

**The one shared failure is the fix working, not a defect.** S0's
`Username>` assertion fails because `deck-form.sh` now says *"on-screen keyboard
did not report bound within 5s"* instead of *"mapper not found"* — the mapper is
present and launching, and cannot bind under QEMU because there is no gamepad.
That 5 s pushes the prompt past the harness's screenshot. **The harness's
timings predate the mapper ever being in the image** and need rebasing on the
OSK bind deadline; an empty username is submitted and retried in the meantime.

⚠️ **STILL UNPROVEN, AND ONLY HARDWARE CAN ANSWER IT:** that the OSK actually
*draws* on a real tty and binds to a real controller; that Neptune lights the
panel; that the brightness slider moves (acceptance test is a
`steamos-priv-write` **accept** line in the journal, not a slider that looks
like it moved). Suites at merge: **21/22 sh** (the red is the pre-existing
heredoc classifier), **15/15 py**.

### 5.33b 🆕 Valve's firmware is 350 MiB the Deck almost certainly does not need — held pending hardware

`docs/findings/P32-neptune-firmware-placement.md` (session 28). The question was
where the now-orphaned `linux-firmware-neptune` should be *installed* from. The
answer is **nowhere — and it probably should not be carried either.**

Not a spot check: all **6,150 modules** of `linux-neptune-611` were extracted and
every `firmware=` declaration read (plus `modules.builtin.modinfo`) — **1,973
distinct firmware files Valve's own kernel can request.** Of those, exactly **32**
are provided by Valve and absent from Arch's split `linux-firmware`, and all 32
are for hardware the Deck does not have: AceNIC/Sun Cassini NICs, Korg/ESS/Yamaha
sound cards, Eagle ADSL and dial-up modems, a DVB tuner, a ViCAM webcam, a
ham-radio modem. Filtering the 32 for `amdgpu|ath11k|qca|cirrus|cs35l|vangogh`
returns **zero**.

- **Wi-Fi/BT (QCA2066 hw2.1):** identical path sets. `board-2.bin`, `m3.bin` and
  all three BT blobs are **byte-identical**; `amss.bin` differs in size but
  carries the *same* `QC_IMAGE_VERSION_STRING`. Arch stores the BT files as
  dedupe symlinks, which is why a naive existence check reads as "missing".
- The one Valve-only ath11k entry, `ath11k/QCA206X`, is a symlink to `QCA2066` —
  and `ath11k.ko` contains `QCA2066/hw2.1` with **zero** occurrences of
  `QCA206X`. Dead weight for this kernel.
- **GPU:** all 11 `vangogh_*` paths in both, and parsing the AMD ucode headers
  shows **Arch is newer or equal in every one** (Valve's is upstream pinned at
  `jupiter.20260712`; Arch's is the `20260810` snapshot).
- **Audio:** Arch ships the canonical `cirrus/cs35l41-dsp1-spk-prot.*`. Valve's
  127 extra cirrus/TI files are keyed to Dell/ASUS/HP/Lenovo subsystem IDs.

**Decision: keep carrying it for now, cut it after the next hardware boot.** The
sweep is static analysis, and `linux-neptune-611` + Arch firmware has never run
on the Deck — the only hardware install to date booted stock `linux`. Removing
firmware on the strength of a module-table read, on the one platform this project
has verified, is the wrong direction to be wrong in. Measured cost of holding:
**349.6 MiB** (366,612,354 B), ~1:1 on ISO size because the mirror is stored
uncompressed. Cutting it takes the ISO 6.383 → ~6.042 GiB and reduces the fork's
+544 MiB regression by 64%, to ~+194 MiB. Rejected outright: installing it from
`configure_deck` (opens a real no-firmware window mid-install) or from a
first-boot service (can strip the radio before the operator has confirmed Wi-Fi;
loud-and-bricked is still bricked).

**Two false comments found in `deck-mirror.packages` and fixed here**, both the
P32 species in prose: the firmware entry still claimed "DUAL ENTRY, both of them"
— an installer that `a380fe3` had deleted an hour after adding — and the headers
entry justified itself at "~10 MiB" against a measured **33.8 MiB**. **Guard 6.8
cannot catch either**: it flags a package list entry with no installer, and this
gap is a third, unstated limitation — prose asserting a consumer that no single
line names.

### 5.34 🆕 THE OSK DRAWS ON HARDWARE — and four defects only hardware could show (session 28, operator test in progress)

**The headline is a pass.** `docs/PROGRESS.md` §5.33a listed "the OSK actually
*draws* on a real tty and binds to a real controller" as unproven and
QEMU-unanswerable. **It draws, and it binds.** Photographed on the Wi-Fi
passphrase screen and the user-account screen. P32's biggest P1 is fixed on
hardware, not just in a VM.

Four defects came with it. **None blocks an install** — the operator was told to
keep testing and batch them. Fixes deferred to one parallel round.

**D1 🔴 the reserved-username check is DEAD, and has been since it was written.**
`deck-form.sh:749` sets `DECK_RESERVED_USERNAMES_VAR=RESERVED_USERNAMES` and
`deck_form_load_reserved_usernames` does `declare -p` on it expecting a bash
**array**. Upstream's vendored `setup-form.sh:82` defines
`OMARCHY_RESERVED_USERNAMES` — **different name, and a regex STRING, not an
array.** So `deck_form_username_reserved` returns 1 for every input. And because
our override replaces `omarchy_prompt_username` wholesale, upstream's own regex
check at its line 111 never runs either: *both* checks are gone, and a user named
`root` is accepted. The comment at `deck-form.sh:739` states the variable name
was **"(INFERRED, NOT READ this session)"** and says *"Verify the real name
against the vendored copy before this ships."* It shipped unverified. The
loud-degradation design is what surfaced it — this is the warning working.

**D2 🐞 `DECK_OSK_BIND_DEADLINE=5` (`deck-form.sh:229`) is too short on real
hardware, and the warning is never retracted.** The mapper binds later than 5 s;
we do not kill it on deadline expiry, so it comes up anyway and a *false*
"did not report bound within 5s -- this prompt runs WITHOUT it" is left on the
screen next to a working keyboard. **QEMU structurally could not catch this**:
with no gamepad the bind never happens, so the message was always true there.
Whatever the new deadline is, the retraction matters as much as the number.

**D3 🐞 the keyboard is far too small on a 7" panel.** `Layer.width` 16 ×
`KEY_CELL = 5` (`src/deck_osk_tty.py:138`) = 80 columns at the console's default
8×16 font. **Coupled, not a one-line fix:** a larger console font is the real
win (it enlarges every installer screen, not just the OSK) but gives *fewer*
columns, so `KEY_CELL` must shrink with it. 5→3 appears to fit — `cell_text`
draws highlighted as `[` + `label.center(w-2)` + `]`, which at w=3 is `[q]`, the
same width as plain. Any change here must respect `write_at`'s `console_cols`
guard and `rows_on_screen`'s wrap argument.

**D4 🐞 the OSK flickers.** `write_at` rewrites every row with `\x1b[K` between a
cursor save/restore on each repaint. Rate is unmeasured — measure before fixing.

### 5.35 🆕 THE BLACK FIRST BOOT IS STEAM UPDATING ITSELF — measured, not inferred (session 28)

Read over SSH from the installed Deck, from Steam's own
`~/.local/share/Steam/logs/bootstrap_log.txt` (which survives reboots) and
`systemd-analyze`. **`uname -r` on hardware:
`6.11.11-valve29-1-neptune-611-g2dcfaf4df7ac`** — Valve's kernel, from our ISO,
running on the Deck. §5.33a's biggest open question, closed by measurement.

**The boot chain is NOT slow.** `systemd-analyze`: 5.781s firmware + 7.442s
loader + 5.691s kernel + 20.253s userspace = **39.168s**, `graphical.target` at
20.252s, `plymouth-quit.service` **659 ms**. Nothing here accounts for minutes.

**The black window is Steam's first-run self-update, and it is 2m03s:**

| time | bootstrap_log.txt |
|---|---|
| 15:08:15 | Steam launches (`-gamepadui`), `Verifying installation...`, `Downloading Update...` |
| 15:08:15 | `Download failed: http error 0` → **`Error: Steam needs to be online to update.`** |
| 15:08:16 | relaunches and retries — **succeeds this time** |
| 15:09:51 | `Extracting package...` |
| 15:10:14 | `Update complete, launching...` |
| 15:10:18 | new client starts (updater built **Aug 3 2026**, was Jun 24) |

**This root-causes P32 issue #4 as well, and it is a RACE, not a broken
network.** The very first update attempt fails because Steam is started before
NetworkManager has connectivity — one second later the identical request works.
The operator saw the failure modal; the recovery was already underway.

**Nothing can draw in that window today, and that is by construction.** The
session is `sddm.service` under `graphical.target`; the kernel cmdline is
`quiet splash loglevel=0 systemd.show_status=false vt.global_cursor_default=0
fbcon=rotate:1`, so the console prints nothing; and plymouth has been gone since
659 ms — three orders of magnitude before the window opens. So for ~2 minutes
gamescope is up, Steam is running headless updating itself, and the panel is
black with no channel to say so.

**Operator request (2026-08-15): show something.** *"just something to tell users
like don't turn me off. steam is unpacking."* Available on the target and worth
weighing: `plymouth` (themes include `omarchy`, `spinner`, `spinfinity`; supports
`display-message`) held past `plymouth-quit` with `--retain-splash` until Steam
draws, `imv`, or a gamescope-side client. **Undecided — do not build before
choosing.** Note it is first-boot-only: later boots reach Gaming Mode in ~39 s.

**Also found: the journal is persistent (`/var/log/journal` exists) but
`--list-boots` shows only boot 0**, so the actual first boot was NOT captured —
everything above came from Steam's own log. Worth understanding before relying on
`-b -1` for any future hardware forensics.

### 5.36 🔴 SSH does not survive a reinstall, and setting it up by hand cost most of an evening

The installer has **no SSH wiring at all** — no `openssh` in any package list, no
unit, no key handling. It was configured by hand once (session 27), the
session-28 reinstall wiped it, and reconstructing it took hours across two
Claudes and a dozen operator round-trips. Causes, all mundane and all stacking:
sudo is not NOPASSWD so every step needs a human; `&&` chaining ate the failures
(**this file's own hard constraint, violated in the commands handed to the
operator**); ufw `default deny` produced *timeout* while a missing sshd produces
*refused*, so the first masked the second; `systemctl is-active` prints
`inactive` for a unit that does not exist, making "never installed"
indistinguishable from "not started"; and the Deck-side agent could see only
local state while the dev machine could see only the network, with the operator
as the sole lossy channel between them. The tie was broken by RST-vs-timeout from
outside. **Fix belongs in the installer, not in a runbook.**

### 5.37 🆕 Two more from the operator, both diagnosed over SSH (session 28)

**D5 🐞 touch does nothing in Desktop Mode — the panel transform is not applied
to the touchscreen.** Not a missing driver: `hyprctl devices` shows the OLED's
controller bound and present as **`fts3528:00-2808:1015`**. The cause is that
`eDP-1` is `800x1280@90.004`, **`transform: 3`**, `scale: 1.25`, and
**`~/.config/hypr/` contains no `device` block at all** — nothing binds the touch
device to the output, so its coordinates are never rotated with the panel and
every tap lands 270° from the finger. Fix is to bind the touch device to `eDP-1`.

⚠️ **CORRECTED 2026-08-15 (P33 Agent D) — the mechanism above is WRONG, and the
fix named above is only half of it. Binding to an output does not rotate
anything.** Read from Hyprland v0.56.2 `src/managers/input/Touch.cpp`, where the
monitor transform appears nowhere at all:

    const auto TOUCH_COORDS = PMONITOR->m_position + (e.pos * PMONITOR->m_size);

Rotation is a *separate* option applied as a libinput calibration matrix in
`InputManager.cpp`'s `setTouchDeviceConfigs`: **`input:touchdevice:transform`**,
clamped −1..7. So `transform` is the fix; `output` is belt-and-braces. Measured
in the same function: **`[[Auto]]` does not autodetect in 0.56.2** — the branch
body is commented out behind a `// FIXME:`, so the default leaves the device
unbound. The value is derived, not guessed: `EVIOCGABS` on the digitizer reports
`ABS_X 0..800`, `ABS_Y 0..1280` — the **native portrait frame, unrotated** —
while `eDP-1` presents 1280×800 and `/proc/cmdline` carries `fbcon=rotate:1`.
Content rotates 90° CW, so touch must come back 90° CCW = transform **3**.
Shipped as global `input.touchdevice` (which names no device) rather than an
`hl.device({ name = "fts3528:…" })` rule, so no untested LCD claim is made.

⚠️ Related, already in §7 and re-learned the hard way this round: **`hyprctl
keyword` is rejected outright** under Omarchy 4.0's Lua parser — *"keyword can't
work with non-legacy parsers. Use eval."* Use `hyprctl eval`.
⚠️ **Omarchy 4.0 configures Hyprland in LUA** (`hyprland.lua`, `input.lua`,
`monitors.lua`, `bindings.lua`, via `hl.config({...})`), not the classic `.conf`
syntax — the exact Lua spelling of a device block must be READ, not assumed, and
anything in this repo that writes Hyprland config needs checking against it.

**D6 🆕 operator request: a button to close the focused window**, analogous to
`SUPER+W`. **`STEAM+Y` is free** — `deck-input-mapper.py` uses `BTN_MODE` as
`OSK_CHORD_HOLD` with `BTN_NORTH` (physical X) as the OSK toggle, so
`BTN_MODE`+`BTN_WEST` is unclaimed. **Implement it as a direct exec
(`hyprctl dispatch killactive`), NOT as a synthesised `SUPER+W` chord** — that is
this file's own established precedent at `src/deck-input-mapper.py:373`, taken
because a synthesised chord silently does nothing if upstream edits the binding,
with nothing to read anywhere. Verify against Omarchy's own `bindings.lua` that
`SUPER+W` is in fact `killactive` before wiring it.

### 5.38 🔴 THE POWER BUTTON STAGE NEVER RAN, AND BACKLIGHT DISCOVERY USES THE WRONG KERNEL (session 28, read over SSH)

Both found by reading `/var/log/omarchy-deck-install.json` and the live system,
after the operator asked why the power button does nothing.

**D9 🔴 the power button is `ignore`, and our T13 stage is not in the bake's
stage list.** `systemd-analyze cat-config` resolves `HandlePowerKey=ignore` from
`/etc/systemd/logind.conf.d/10-ignore-power-button.conf`, which `pacman -Qo`
attributes to **`omarchy-settings-dev`**. logind logs `Power key pressed short`
on every press — the key is detected and delivered, and logind is told to drop
it. Suspend is available (`/sys/power/state` = `freeze mem disk`, `mem_sleep` =
`s2idle [deep]`), so nothing is missing at the hardware or kernel layer.

`src/deck-session.sh` carries a substantial T13 power-button stage —
drop-in sort-order verification (`:4985-5006`), a udev untagging premise check
(`:4982`), an explicit `HandlePowerKeyLongPress` (`:898`), a double-suspend guard
(`:5133`). The install record lists **thirteen** bake stages
(`greeter-rotation, input-mapper, lizard-mode, menu-row, osk-kb-layout,
preconditions, priv-write-helper, return-icon, sddm-resilience, session-select,
steam-hook, timezone-helper, update-stub`) and **no power-button stage is among
them.** `/etc/udev/rules.d/` on the target is empty; no drop-in of ours exists.
**Written, unit-tested, documented, never wired — the P32 family again**, now at
six members (Steam, the mapper, `steamos-session-select`, the reserved-username
list, `deck-fetch.packages`, and this).

**D10 🔴 `stage-priv-write-helper` FAILED at install, and the reason is
structural.** The record:

> `backlight: /sys/class/backlight/amdgpu_bl1/brightness (discovered, not assumed)`
> … `steamos-priv-write: '/sys/class/backlight/amdgpu_bl1/brightness' is not writable even as root`

**On the booted system `amdgpu_bl1` does not exist.** The only node is
`amdgpu_bl0` (`cur=39638`, `max=65535`, root-writable). The bake runs in a chroot
on the live ISO, whose kernel is **stock archiso, not Neptune**, and the two
enumerate the backlight differently. So this is not bad luck: **discovering
hardware through the installer's kernel and baking the answer into a target that
boots a different kernel is unsound in general.** Even a successful write would
have recorded the wrong node. Every other stage that reads hardware state at
chroot time needs auditing for the same class of error.

⚠️ **This corrects this file's own earlier account.** The bl0/bl1 trouble was
recorded as a hardcoded node; it is in fact *discovered*, correctly, in the wrong
kernel. The whitelist (`deck-session.sh:2376`) remains device-agnostic and
remains not the bug — measured and disproved in `0becd4b`; do not re-diagnose it.

The bake's other twelve stages reported `ok`, and `session_bake.status` is
`partial` — the loud-degradation design working: it named the failed stage and
said the machine would still reach Gaming Mode, which is exactly what happened.

### 5.39 ✅ P33 — seven defects fixed, 350 MiB cut, and six agents each corrected the plan (session 28)

Six parallel agents over disjoint files (`docs/tasks/P33-fix-round.md`), commit
`4caf26f`. **Every one of them corrected something the plan asserted**, which is
the result worth recording — the briefs said *measure, don't infer*, and each
agent's biggest contribution was refusing an instruction and proving why.

| | the plan said | measurement said |
|---|---|---|
| **C** | bind `SUPER+W`'s classic bareword dispatcher | it resolves to `nil` on Hyprland 0.56.2; Omarchy binds `hl.dsp.window.close()` in Lua, and the bareword appears **nowhere** under `/usr/share/omarchy/`. **The plan document itself was turning `test-hyprctl-syntax.sh` red.** |
| **D** | bind the touch device to the output so the transform applies | **binding does not rotate anything** — read from `src/managers/input/Touch.cpp`, where the monitor transform appears nowhere. The fix is `input:touchdevice:transform`, a libinput calibration matrix. `[[Auto]]` is a commented-out `// FIXME:` and does not autodetect. |
| **B** | 800×1280 → 100 columns at 8×16, 50 at 16×32 | **wrong by an axis.** With `fbcon=rotate:1` the horizontal side is 1280 px, and §7 had *already measured* `50 160`. So the pair is **160 and 80** — and the OSK has been drawing its fixed 80 columns on a 160-column console, **half the screen**. Also: "5→3 appears to fit" checked `cell_text`, not `display_label`'s budget; `Enter` and `Backspace` both truncate at cell 3. |
| **A** | raise the 5 s deadline | derived **35 s** from the mapper's own `NO_PAD_GRACE_SECONDS = 30.0` — any deadline below 30 can expire on a mapper about to succeed — and added a cross-file gate. |
| **E** | verify brightness after moving discovery to first boot | there was **no accept line at all**, so §5.33a's stated acceptance criterion (*"a `steamos-priv-write` accept line in the journal"*) had been **unmeetable since it was written**. Added one. |
| **F** | cut the firmware | cut it, and wrote the **per-line consumer rule** that `P32-neptune-firmware-placement.md` §5 proposed but never implemented. |

**The P32 shape nearly shipped again, inside the fix for P32.** Agent B's
adaptive grid was written, unit-tested, documented — and **inert**, because
`_osk_draw` read the console width one line *after* rendering and passed it to
nothing. Caught by B flagging a file it did not own rather than by any test.

**Two more wrong-kernel reads found by E's twelve-stage audit** beyond D10:
`stage-power-button`'s scans of `/run/udev/rules.d` and `/run/systemd/logind.conf.d`
(arch-chroot bind-mounts those *from the live ISO*), and `stage-input-mapper`'s
`/dev/uinput` probe, which tested the ISO's node as root and so could only ever
pass. **The rule now written into `deck-session.sh`:** firmware-derived facts
(DMI, ACPI/platform `ID_PATH`s) read the same on both kernels; **driver-assigned
names and indices, udev's runtime database, and anything under `/run` do not.**
`stage-lizard-mode` had this right all along and is the precedent the backlight
should have followed.

**The sleep-lock hazard from §5.24 is closed, by checking rather than assuming:**
`mask_sleep_lock` runs before `session_bake`, and
`/etc/systemd/user/omarchy-sleep-lock.service -> /dev/null` is present on the
installed Deck, so arming `HandlePowerKey=suspend` cannot raise the unanswerable
lock.

⚠️ **Still hardware-only, and the operator's to close:** the OSK legible and
flicker-free on the panel; a tap landing where the finger is (if wrong, it is
wrong by a quarter turn and the only other value is `1`); STEAM+Y closing a
window; the splash drawing **and exiting**; no Steam update modal; **the power
button suspending AND waking to something usable — this Deck has never been
suspended**; and Wi-Fi/audio/gamescope still up without Valve's firmware, which
is now a regression check rather than a discovery.

### 5.40 🔴 THE CONSOLE FONT WAS A REGRESSION — reverted after one hardware boot (2026-08-16)

P33's A3 pinned `latarcyrheb-sun32` (16×32) to make the installer readable.
**Measured on the panel, it made it unusable.**

| | columns | rows |
|---|---|---|
| default 8×16 | 160 | **50** |
| latarcyrheb-sun32 | 80 | **25** |

The columns were the intended half. **The ROWS were not, and nobody costed
them.** 25 rows cannot hold the Omarchy logo, a prompt and a 7-row keyboard at
once, so on hardware the logo filled the screen, the keyboard's top rows drew
over each other, and **the username and password prompts were pushed off-screen
entirely** — a `CLAUDE.md` violation (a screen you cannot read is a screen you
cannot complete without a keyboard), and strictly worse than the small font it
was meant to fix. Operator verdict: *"I prefer the sizing for the install menu
that we had before. The only thing I would have changed was the keyboard being
too small."*

The comment that shipped claimed *"16×32 gives 50 columns and 40 rows where 8×16
gave 100 and 80"* — **both figures wrong, on both axes.** That arithmetic came
from the P33 plan, where the column half had *already been corrected once*
(§5.39, Agent B). The correction was applied to the plan and to Agent B's brief
and never propagated into Agent A's. A number corrected in one place and left
standing in another is the same defect this project keeps paying for.

**The font was never what fixed the keyboard.** `deck_osk_tty.py` now derives
its cell width from the real column count, so at the DEFAULT font it draws **160
columns instead of the old hardcoded 80** — twice as wide, at the sizing the
operator wanted. The two changes were independent; only one of them was needed.

`DECK_CONSOLE_FONT` is now empty and `deck_form_pin_console_font` returns early
on empty, **before** the tty branch. Without that guard it would `setfont ""` on
the real console and warn on every prompt — and **the unit suite structurally
cannot catch it**, because it has no VT and returns at the tty guard. Found by
reading the code, not by a test; now asserted.

**Still open after this boot** (operator, 2026-08-16): the keyboard **still
flickers** on hardware. Agent B measured the *drive* (erase-to-EOL 1250→25 per
second of pad motion) and was explicit that panel behaviour was unverifiable
off-hardware. That measurement stands; it simply was not sufficient. Re-check
after the font revert, since row-budget overlap may have been part of what was
seen.

### 5.41 A sixth upstream patch was written, then dropped for lack of evidence

Two P33 builds died on `invalid or corrupted package (checksum)` for files that
are **not corrupt** — downloaded three times, byte-identical, valid zstd. The
diagnosis: we COMPILE `omarchy-dev`/`omarchy-settings-dev` from `iso/RUNTIME`'s
pinned commit while upstream PUBLISHES a package with the identical
pkgver-pkgrel. Populating the offline mirror leaves upstream's copy in the
scratch pacman cache; mkarchiso reads that cache first, then validates it
against the db `repo-add` just wrote from *our* build.

A patch was written to evict cache entries that disagree with the mirror
(comparing by content, never by name). The third build succeeded — but it
**evicted 0 files**, so the fix is unattributed and the two prior failures
remain unexplained. `test-iso-build.sh` caps the overlay at **five** patches and
says raising it *"is a decision, not a fix"*; with no evidence the patch did
anything, that argument could not be made, so it was dropped rather than the
budget raised. Recorded here so the diagnosis is not lost: **if this recurs,
reinstate it with the failure as evidence and raise the budget deliberately.**

⚠️ Also learned: `iso/bin/build`'s positional argument is **not** the scratch
root. All three builds used `~/.cache/omarchy-deck/iso-build` regardless of what
was passed, so the "always build in a fresh scratch dir" precaution (§5.33a) was
never actually in effect for any of them.

---

## 6. Blocked on human

- 🆕 **P3.6 — bring the Deck to Omarchy 4.0.0 stable (operator-present).** Runbook
  ready: `docs/tasks/P36-deck-stable-update-runbook.md`. Needs the operator
  because it writes to the Deck (snapshot, channel switch, `omarchy-update`) and
  because the edge→stable swap replaces `omarchy-dev` with `omarchy` via a pacman
  **conflict prompt** and five migrations call `sudo` — run with `ssh -t`, not
  headless. Everything hardware-free (pin, delta, substrate, records) is done
  (§5.31). This is the first hardware step of phase 3.
- **`docs/ROADMAP.md` P1.4 — Ventoy on the test USB + the stock Omarchy 4.0 beta
  ISO.** `ventoy-bin` is not installed on the dev machine. The ISO can be
  downloaded, or built locally (a real build already succeeded in session 2 —
  remember `--network host`).
- **`docs/ROADMAP.md` P1.5 — the Deck recon + rebuild session.** Needs the
  operator present, a USB keyboard for the dev-time install, the Valve
  recovery image on a second USB as the floor, and anything personal copied
  off the Deck first. Approved in principle by §2.5; still confirm before
  executing.
- ✅ *(Retired 2026-08-11 — both answered, see §5.25.)* ~~Approval to download
  the beta 2 ISO~~ (granted; done, and it proved we were already on beta 2).
  ~~Rebase now or wait for stable?~~ **Wait.**
- 🆕 **FIRST, from the live ISO, before the five below** (§5.26): read
  `/sys/module/hid_steam/parameters/lizard_mode` under the ISO's own kernel.
  One line, and it gates whether T4 has a product at all. It must be done from
  the **booted ISO**, so it belongs to a session that boots the USB — not to
  the installed-system session below.
- 🆕 **ONE Deck session, five approved items batched** (§5.25 rows 1–5): the
  lock fix, `lizard_mode` persistence + fallback, QAM's evdev code,
  `stage-default-session`, and both rotations. ⚠️ **Row 2's fallback must be
  built and tested BEFORE the session** — persisting lizard mode without it
  leaves a handheld with no input if the mapper dies. Runbook owed.
- 🆕 **`docs/ROADMAP.md` P2.9e — bringing the Deck to beta 2.** Snapshot #8,
  then in-place `omarchy-update`, then re-running every `deck-session.sh`
  stage. Prepared and described before execution, per the rule below. Batch it
  with P2.9f's hands-on list — that is one operator session, not two.
- **Any write to the physical Deck.** Prepare, describe, wait. Batch requests.
- **Anything touching TDP, fan curves, or charge limits** — every time, no
  exceptions. Genuine hardware-damage risk.
- **Any public action** — repos, upstream issues, outreach. One draft staged
  (§5.6).

Retired from this list 2026-08-10: "do not wipe the Deck" (superseded by
§2.5's planned-rebuild posture), the DeckShift manual removal and its `/tmp`
backup rescue (the rebuild wipes both).

---

## 7. Don't re-derive — each of these cost real time

- **The Deck's d-pad arrives as `BTN_DPAD_*` key events, never as `ABS_HAT0X/Y`.**
  `hid-steam` *advertises* the hat axes and never sends them. Anything handling
  only the axes silently ignores the d-pad — which is exactly what shipped
  (§R-33). Check what a device **sends**, not what it advertises.
- **`hid-steam` uses Nintendo-style button codes:** physical **X** is
  `BTN_NORTH`, physical **Y** is `BTN_WEST`. The kernel's own aliases confirm it
  (`BTN_NORTH/BTN_X`). This looks inverted beside the Xbox convention and will
  invite a "fix" that breaks it.
- ✅ **QAM is `BTN_BASE` (294)**, measured on hardware 2026-08-11 with
  `lizard_mode=N`, on `/dev/input/event7` ("Steam Deck"). STEAM is `BTN_MODE`
  (316) on the same node. The capture bracketed two QAM presses between two
  `BTN_SOUTH` presses — 304, **294**, **294**, 304, 316 — so the attribution is
  evidence, not inference. ⚠️ **Another misleading name**, like the trackpads
  that report as hats: `BTN_BASE` is nominally a joystick base button and says
  nothing about a quick-access menu. Do not "correct" it.
- ⚠️ **The Deck enumerates FOUR input nodes and two of them are silent.**
  Measured 2026-08-11: `event5` and `event6` are both named
  **"Valve Software Steam Controller"** and emitted nothing at all during a
  75-second capture in which every button worked; `event7` ("Steam Deck") is the
  one that speaks, and `event8` is Motion Sensors. **A probe that picks one node
  and waits can therefore report a working button as dead** — which is R-29's
  exact shape, and is what the one-liner in the P2.9 runbook (`pads[-1]`) risked.
  Watch every candidate node at once and label the source; the working probe is
  in the session scratch and the approach is worth rebuilding over trusting a
  single pick.
- **Lizard mode swallows X, Y, L1, R1, STEAM and QAM completely** — they appear
  on no evdev node. It provides Enter, Esc, Tab, arrows and both mouse buttons,
  but **no Space**. Suppress it with
  `/sys/module/hid_steam/parameters/lizard_mode` (writable, non-persistent).
  ✅ **True in the LIVE ISO as well as the installed system** — node present at
  0644, reads `Y`, write accepted and reverted, under the ISO's own `-t2` kernel
  (measured on hardware 2026-08-11, §5.26). Both environments, not one.
- **The live ISO's console is `50 160` — 50 rows × 160 columns**, measured with
  `stty size` on **tty2** (2026-08-11, OLED). That is 1280×800 at an 8×16 font:
  the *landscape* geometry rendered onto the portrait panel, which is why it
  reads sideways until `fbcon=rotate:1` lands. It comfortably fits upstream's
  ~81-column logo and our 73-column OSK side by side — T4 §8's U3 feared 80×25,
  which would have wrapped the frame and eaten half the screen. ⚠️ **tty2 only.
  The installer runs on tty1 under `quiet splash`**, and session 19 already lost
  time to a console width cached across a mode change. Read the geometry; do not
  hard-code this number.
- **The live ISO's root shell is `zsh` WITH AUTOCORRECT, and root logs in on a
  TTY with no password.** A mistyped command stops and waits:
  `zsh: correct 'GREP' to 'grep' [nyae]?`. Anything scripted that types into a
  shell there can block on a prompt that looks nothing like the screen it was
  aiming at — the same class as an interactive pager with no controller exit
  (§5.26a). Measured 2026-08-11.
- **`pgrep -x gamescope` FINDS NOTHING while Gaming Mode is on screen.** The
  binary's `argv[0]` is `gamescope` but its **`comm` is `gamescope-wl`** —
  measured 2026-08-11 on `/proc/<pid>/comm` — and `pgrep -x` matches `comm`, not
  argv. ✅ `src/deck-session.sh` (~line 882) already documents this and matches
  `gamescope-wl`, with an assertion pinning it in `test/unit/test-deck-session.sh`.
  **This entry exists because it was re-derived anyway**, mid-session, and read
  as "Gaming Mode failed to start" for several minutes while the operator was
  looking straight at it. Use `pgrep -f`, or the session's
  `loginctl show-session -p Desktop`, which reports `gamescope` regardless.
- **An evdev node can be enumerated and permanently silent.** Counting nodes,
  `systemctl is-active`, and a log line naming the bound device all reported
  health while the mapper delivered nothing for an entire session (§R-31).
- **When probing input by hand, press a known-good button as a DELIMITER between
  test buttons.** A silent button leaves no marker, so an undelimited batch
  cannot attribute events to presses. A reliably emits `KEY_ENTER`.
- **`pkill -f <pattern>` over SSH kills its own shell** when the pattern text
  appears anywhere in the remote command line — including in a later argument.
  The `[p]attern` bracket trick fails too if the plain name appears again. Kill
  by PID, or put the `pkill` in its own invocation.
- **Unquoted heredocs execute backticks and `$(...)` at render time, as root.**
  `deck-session.sh` shipped a comment that really ran `uwsm start ... Hyprland`
  during a stage install (§R-36). Escape them; `shellcheck` catches it (SC2006).
- Docker's default bridge network is throttled to ~2 KB/s on the operator's dev
  machine. Use `--network host` for any Docker-based tooling there.
- `mount -o remount` does **not** re-apply `fmask`/`dmask` on vfat. A full
  `umount`/`mount` cycle is required.
- `pacman --noconfirm` answers **No** to conflict questions. The firmware swap
  needs `--ask=4` (`ALPM_QUESTION_CONFLICT_PKG` only, not a blanket yes).
- Valve's kernel packages ship **no mkinitcpio preset and no `/boot/vmlinuz-*`**
  at all — only `usr/lib/modules/<kver>/{pkgbase,vmlinuz}`. `docs/PLAN.md` §8.3's
  preset bug is therefore moot, and an entire class of preset-patching work in
  the original plan does not exist.
- Omarchy builds UKIs with `limine-mkinitcpio-hook`, not presets. Upstream's
  hooks already cover install/upgrade **and** removal, including deleting the
  UKI. This project's hook **verifies**; it does not generate.
- The UKI filename prefix is **not** the machine-id — it is `CUSTOM_UKI_NAME`
  from `/etc/default/limine` (`omarchy` on this Deck). Discover it, never
  construct it.
- The Limine config is at `$ESP/limine.conf` — the fifth of the five candidate
  paths, so the five-way probe was right to exist.
- Kernel series suffixes are **not orderable** (`618` vs `72` — neither integer
  nor string comparison is right). This is why the version is pinned to one
  documented constant.
- `linux-firmware-neptune` collides with Arch's *split* `linux-firmware`. Valve's
  package declares `conflicts`/`replaces` against **one** of the twelve
  subpackages (`linux-firmware`; `-whence` is a `depend`, not a conflict — the
  "two" here was wrong until 2026-08-15).
  Remove the others explicitly — `--overwrite` would leave Arch
  owning those paths and the next `-Syu` would silently restore Arch's firmware
  over Valve's.
- `limine-snapper-sync.service` holds the ESP open; the `umount`/`mount` cycle
  needs it stopped and restarted.
- mkinitcpio's UKI output **is** byte-reproducible. An earlier claim to the
  contrary was wrong. Consequence: a sha256 snapshot does not catch a needless
  rebuild; prove regeneration with an mtime sentinel.
- On the Deck, `sudo` cannot prompt without a TTY. Agent sessions need a
  `SUDO_ASKPASS` helper; one is saved at `~/pizzarchy-askpass.sh`.
- The `cs35l41-dsp1-*` firmware warnings previously recorded as "expected on
  OLED" **do not occur** on current firmware. Treat their reappearance as worth
  investigating, not as background noise.
- **Limine honours the entry-path form of `default_entry`** — proven by boot,
  not inference (`test/vm/vm-default-entry-test.sh`): a planted *non-first* path was
  both selected and booted. Limine implements the systemd Boot Loader
  Interface, so the selected entry is readable at
  `/sys/firmware/efi/efivars/LoaderEntrySelected-4a67b082-…` (UTF-16LE,
  4-byte attribute prefix) — assert on that, never screen-scrape a menu.
- `snapper --no-dbus` makes create-config/create/list work in a chroot, and
  `limine-snapper-sync` runs chrooted too — but only after
  `systemd-machine-id-setup`, because it namespaces its ESP history dir by
  machine-id.
- Docker containers get a tmpfs `/dev` with no udev, so `losetup -P` publishes
  partitions under `/sys/block` but creates no `/dev/loopNpM` nodes — `mknod`
  them from sysfs. Relatedly, `genfstab -U` silently emits `/dev/loop0p1` when
  udev never populated `/dev/disk/by-uuid`.
- Put `console=ttyS0` **last** in a QEMU kernel cmdline, or systemd's boot
  output goes to a VGA framebuffer no harness is capturing.
- **A CI glob that matches nothing passes.** `shellcheck *.sh` at the repo
  root went from checking every script to checking none the moment the repo
  grew directories — green, and testing nothing. Every discovery glob in
  `.github/workflows/ci.yml` now uses `git ls-files` and **fails when it
  finds zero files**.
- `shellcheck` resolves `# shellcheck source=` relative to its *working
  directory*, not the script. `.shellcheckrc` sets `source-path=SCRIPTDIR`
  so `../lib/foo.sh` means what it looks like it means.
- **The Deck's Wi-Fi chip is QCA2066 hw2.1**, firmware at
  `ath11k/QCA2066/`. It is *not* QCNFA765/`nfa765` — an earlier inference
  that happened to reach the right conclusion for the wrong reason.
- **Lizard mode is exclusive.** With Steam not running, Deck buttons emit on
  the keyboard-emulation node only; the `BTN_SOUTH` gamepad node emits
  nothing. Any code selecting the pad by `BTN_SOUTH` gets a dead device.
- **The upstream Omarchy ISO's pacman is offline-only** — a single
  `[offline]` repo at `file:///var/cache/omarchy/mirror/offline/`, no network
  mirrors. `pacman -Sy <anything not baked in>` fails even with working
  internet. Whatever the live environment needs must be *in the payload*.
- The Deck's DMI is `product_name=Galileo` (OLED). `amdgpu`'s ATOM BIOS
  string says `AMDSphJupiter` — that is a display-controller name, **not** a
  model indicator; do not read it as LCD.
- The live ISO has no `sof-firmware`, so `snd_sof_amd_vangogh` fails to load
  and there is likely no audio in the live environment.
- A `pgrep -f <pattern>` inside a shell whose own command line contains
  `<pattern>` matches itself and loops forever. Bit this session; use a
  pidfile or match more narrowly.
- **Steam's runtime PATH is exactly `/usr/bin:/bin`**, with `SYSTEM_PATH`
  unset. `/usr/local/bin` is unreachable from anything Steam invokes. Verify a
  shim with `env -i PATH=/usr/bin:/bin sh -c 'command -v …'`, never with
  `test -e` — the latter passes while Steam is blind to it.
- **Steam calls its privileged helpers by ABSOLUTE path**,
  `/usr/bin/steamos-polkit-helpers/<name>`. Two different resolution rules
  coexist: `steamos-session-select` via PATH, the helpers absolutely. Both end
  up needing `/usr/bin`.
- **`steamos-update` exit codes are a protocol.** `check` → **7** means "up to
  date"; **0 means an update is available**. On the apply path **0 makes Steam
  REBOOT** the device to "finish" the update, and during OOBE Steam calls apply
  without checking first — so 0 is a reboot loop. Use 7.
- **Steam passes `plasma`** to `steamos-session-select`, not `desktop`.
- **Omarchy 4.0 configures Hyprland in Lua**, not `.conf`
  (`~/.config/hypr/*.lua`, `hl.monitor({…})`, `hl.config({…})`). Hyprland 0.56
  **rejects `hyprctl keyword`** for Lua configs — "use eval"; the live path is
  `hyprctl eval 'hl.monitor({…})'`.
- **Hyprland silently discards a Lua config that fails to parse** — falls back
  to defaults, logs nothing past `[cfg] Config is lua, loading lua mgr`, exits
  0. Always `luac -p` a generated Hyprland config; the symptom otherwise looks
  like "the setting has no effect here". ⚠️ **`hyprctl configerrors` does not
  catch this** — it is empty precisely because nothing was parsed. It catches a
  renamed *key*, not a discarded *file*.
- 🔴 **`hyprctl eval` cannot report a VALUE, only an ERROR.** It prints `ok` —
  its own status — and exits **0** for every expression that does not raise,
  including a bare Lua return of a global that has never existed (measured
  2026-08-12 on 0.56.2, `return DECK_NOPE` → `ok`, exit 0, as the negative
  control). A Lua `error()` is the one thing it surfaces: exit **7**, message
  printed. **So a sentinel readback is a check that cannot fail.** Verify a
  config loaded by ASSERTING:
  `hyprctl eval 'if DECK_INPUT_LUA_LOADED == nil then error("…") end'`.
  Reference implementation: `verify_osk_kb_layout` in `src/deck-session.sh`.
  This one was recorded twice and used wrong anyway (§5.30c), so
  `test/unit/test-hyprctl-syntax.sh` scanner 3 now enforces it.
- **The Deck panel's transform is 3 (270°). 1 is upside down.** And Omarchy's
  `scale = "auto"` picks **2** on it, leaving a 640×400 logical desktop; 1.25
  is the even divisor of 1280×800.
- **sddm's shipped unit is `StartLimitBurst=2` / `StartLimitIntervalSec=30` /
  `RestartSec=100ms`.** Two fast failures latch it to `failed` permanently,
  needing `systemctl reset-failed` — unreachable without a keyboard. Any code
  that restarts sddm has to account for this.
- On a **package-based** Omarchy install there is no `~/.local/share/omarchy/`.
  Defaults are in `/usr/share/omarchy/config/hypr/` and
  `/etc/skel/.config/hypr/`, and 4.0 ships Lua-aware agent guidance at
  `/usr/share/omarchy/default/agents/skills/omarchy/hyprland.md`. The
  locally-installed `omarchy` skill documents the 3.x git layout and is wrong
  for this system.
- `steamos-customizations-jupiter` **is** available in `jupiter-staging` and
  ships **zero** polkit helpers (it is GRUB machinery). It does not ship
  `steamos-session-select` either — no configured repo does. `jupiter-hw-support`
  ships six of the helpers, at 94 MiB installed and a **plymouth** dependency.
- **Steam FALLS BACK when a polkit helper is missing; it does not just fail.**
  For a privileged write it tries the helper, then `echo V | sudo -n tee PATH`,
  then `sudo -n chmod a+w PATH` so the next write needs no privilege at all.
  Measured from its console log. Two things follow: a missing helper can look
  like it is working (§5.15), and Steam leaves system nodes **world-writable**
  after every Gaming Mode start. Never conclude a helper is unnecessary because
  the feature works on the test Deck.
- **Steam's helper argv, measured, not inferred.** `steamos-set-timezone
  America/Chicago` (one positional). `steamos-priv-write "<path>" "<value>"`
  (two, quoted). It also calls `steamos-priv-write "/dev/drm_dp_aux0" ""` — an
  **empty** value — so any value validation must handle that case for real.
- **`src/deck-session.sh` is source-safe as of 08698ba** — `main "$@"` is guarded
  on `[[ ${BASH_SOURCE[0]} == "$0" ]]` so `test/unit/test-deck-session.sh` can
  source it and call `render_update_stub` / `assert_ours_or_absent` with no root,
  Deck or VM. **Consequence: anything added at TOP LEVEL below the constants
  executes at source time, inside the unit test.** Keep new work inside
  functions. A sourcing shell also inherits `set -euo pipefail` and every
  constant as `readonly`, so sourcing twice into one shell aborts.
- **An Omarchy version string does not identify a build, and 4.0 has no tag.**
  `basecamp/omarchy` publishes no 4.0 tag or release; the `version` file on
  `quattro` reads `4.0.0.alpha` months into beta. `pkgs.omarchy.org` serves only
  **`edge`** (tracks `quattro` HEAD, rebuilt within minutes of a commit) and
  **`stable`** — measured 606 commits apart on 2026-08-11. Package versions are
  git-describes (`4.0.0.rN.gSHA`). **Pin the SHA; the words are decoration.**
- **Omarchy's beta ISOs are published but unlisted, at
  `https://iso.omarchy.org/omarchy-quattro-beta{N}.iso`** — beta 1
  2026-08-05, beta 2 2026-08-10, while omarchy.org's own download link still
  points at `omarchy-3.8.4.iso`. **No `.sha256` is published for any of them**,
  and the ETag is an S3 multipart hash, so a downloaded image cannot be checked
  against upstream. Also: a beta ISO is a *snapshot*, and `quattro`/`edge` run
  ahead of it — **`omarchy-update` does not put a machine on "the beta"**.
- 🔴 **A UKI's mtime is NOT proof it was regenerated — on either limine stack,
  and it never was.** Measured on both, 2026-08-11, by a suite that now passes
  on each:
  - On **1.36.0** the mtime is **frozen across genuine rebuilds**
    (`uki_mtime_changed=0`, stuck at 2026-07-23). mkinitcpio gives the UKI a
    *reproducible* timestamp derived from its inputs, not from when the build
    ran, and `mv -f` carries that onto the ESP. The old mtime-sentinel oracle
    therefore worked **by accident**: 2000-01-01 simply is not that canonical
    value, so any write erased the stamp.
  - On **1.37.1** the mtime advances by wall clock — but writes are skipped
    entirely for a byte-identical file, so an unchanged mtime means "no write",
    not "no rebuild".
  **Input-derived on one, write-conditional on the other, sound on neither.**
  Prove regeneration by perturbing the *inputs* — a nonce baked into the
  initramfs, asserted as a content change — which is what
  `test/vm/vm-kernel-hook-test.sh` now does.
- **`limine-mkinitcpio-hook` stopped writing the UKI itself between 1.36.0 and
  1.37.1.** 1.36.0's
  `limine-mkinitcpio-install` ended in an unconditional `mv -f "$tmp_uki_path"
  "$uki_path"`; in 1.37.1 that line is gone and the ESP write is delegated to
  `limine-entry-tool --add-uki`, which is **content-addressed and silently
  declines to rewrite a byte-identical file** — no "skipping" message. Measured
  2026-08-11 by running `vm-kernel-hook-test.sh` against both substrates:
  identical `limine` 12.5.2-1 on each, hook **1.36.0-1 → 1.37.1-1** the only
  variable. Proof it still writes when it should: in the same failing run, gap
  A deletes the UKI and it reappears with a fresh mtime.
  ⚠️ **The consequence for our own code:** `src/omarchy-deck-kernel.sh`'s
  idempotency guard is `test "$uki" -nt "$moddir/vmlinuz"` — still correct, but
  it is now reading a timestamp that upstream sets by two different rules
  depending on version (see the fact above). It has not misbehaved on either
  stack; know that it rests on a value neither stack promises.
- **`git ls-files '*.sh'` lists only TRACKED files, so running "CI's own
  command" locally does NOT lint a file you have just created.** It becomes
  lintable the moment you `git add` it — the check passes, you commit, and the
  file you thought you had verified was never looked at. Measured 2026-08-11:
  `test/unit/test-vm-limine-pin.sh` shipped two SC2016 findings this way in
  `e5a5540`, an hour after this file's own warning about "checking a narrower
  set than CI does". **Locally use
  `git ls-files --cached --others --exclude-standard '*.sh'`;** CI's narrower
  form is correct only because CI checks out a commit.
- **An orphaned process on a desktop is reparented to `systemd --user`, NOT to
  pid 1**, so `getppid() == 1` is not a valid orphan test. Measured 2026-08-11
  while fixing §5.27a: the survivor's ppid became 1404, the user manager. Any
  check written against pid 1 silently passes on this system while the orphan
  is very much alive.
- **When mutation-testing, verify WHAT the mutation changed before recording a
  survivor.** Happened twice in one session, 2026-08-11: a `perl -0pe` and then
  a `re.sub` each matched a **header comment** before the code line they were
  aimed at, so the code under test never changed and the "survivor" was an
  artifact. Both times the assertion had teeth once re-targeted. A survivor
  costs an hour of hunting for a coverage gap that does not exist — print the
  mutated line, or diff it, before believing the result.
- ✅ **CI's shellcheck is PINNED to v0.11.0** — fetched from the GitHub release,
  not `apt`, with a version assertion that fails the job if it is anything else
  (§5.25 decision 11, landed 2026-08-11; `.github/workflows/ci.yml`). *(This
  entry previously read "UNPINNED … pin the version in the workflow", and was
  stale from the moment decision 11 shipped. It is corrected rather than
  deleted because the hazard it named is real and permanent: a newer local
  shellcheck passing what an older CI rejects. The pin is what makes "verify
  with CI's own command" a true statement — do not unpin it.)*
- **reddit.com is blocked by policy for WebFetch and for the in-app browser**
  (measured 2026-08-11 — `www.` and `old.` alike). Links to r/omarchy threads
  cannot be read from a session; ask the operator to paste, or find the
  underlying artifact directly, which is how beta 2's URL was found.
- **`omarchy-update` runs upstream `migrations/*.sh` as root, machine-wide, and
  they mutate system state** — adding packages, rewriting `/etc/bluetooth/main.conf`,
  writing `/etc/modprobe.d/`. One carries a comment that an update **over SSH**
  would otherwise abort on `/dev/rfkill`, which is exactly how this project
  drives the Deck. Read the new migrations before updating, and re-verify the
  load-bearing settings after — none of them fails a test today.

---

## 8. Session log

One line each. Detail lives in git history and in the `FINDING-*.md` files.

| 26 | **2026-08-13, session 26 — Phase 2 officially closed.** All remaining exit criteria and hardware tests are verified and complete. 🟢 **omarchy-sleep-lock.service mask:** `deck_configure.py` now correctly applies a global systemd user mask (`ln -s /dev/null`) during install, guaranteeing it doesn't race against upstream's first-run scripts. 🟢 **DPMS/above_lock fix:** verified on hardware. The Steam Deck suspends and wakes cleanly without being stuck on an unanswerable password screen. 🟢 **T10 extest Spike:** Steam-in-background trackpad typing was evaluated; decision is to **forego the Steam keyboard** and commit entirely to our own OSK (the Omarchy OSK) everywhere except Gaming Mode. 🟢 **Lid Switch question:** The `Lid Switch` node (`event1`) was tested on the hardware. It exists but does not spuriously assert on a handheld, proving `HandleLidSwitch=suspend` is safe to leave live. Phase 2 exit criteria (QEMU install automation, CI KVM runners, hardware locks) are now fully satisfied. |

| 25 | **2026-08-13, session 25 (Opus) — the `configurator` `$1` crash is FIXED and the real installer now runs end to end; phase 2 exit criterion 1 is STILL NOT closed, blocked one layer deeper by a real bug in our own `deck_autologin.py`.** The one-line `${1:-}` guard landed as **hunk 3 of the existing `deck-form-invocation.patch`** (not a 6th patch file — the budget is argued in that file's own header, which now carries the argument for hunk 3 too), matching the two already-correct sibling checks in `configurator`. `test-iso-build.sh` 82/82, shellcheck clean, `git apply --3way` clean against the pin, fix lands at the exact crash line (1245). ISO **rebuilt clean** (all 8 guards, sha256 `a27230ff498f8b7b4be45f455192d135fb5ab777b3204022802da19e34b6ea6a`, 6.39 GiB) and the controller-only harness re-run: **step 29 crossed S5's gate, the real installer launched, and the ENTIRE base Omarchy setup ran to completion for the first time ever** — the `$1` crash is gone. It then aborted in **our own `configure_deck` phase**: `deck_autologin.py`'s `DESKTOP_SESSION = "omarchy.desktop"` gets `.desktop` appended a SECOND time by `find_session` (`omarchy.desktop.desktop`, never exists) while the real `omarchy.desktop` sits right there on the target — `choose_session`→`failed`, and `autologin` (the sole `critical=True` step) halts the install. 🔬 **Root-caused off the resulting disk, not inferred**: mounted the preserved 16G target rootless (`udisksctl`, then `-o subvolid=5` to reach the `@log` subvolume the install log actually lives in — a first mount of `@` alone shows an empty `/var/log` and would mislead), read `@log/omarchy-deck-install.json`: **only `autologin` failed**; `desktop_rotation`/`idle_policy`/`limine_rotation`/`lock_wake_dpms`/`menu_lock_row`/`patches`/`session_dconf`/`tty_rotation`/`wifi` all succeeded — so §12.2's fix and the whole rest of the Deck phase work on a real install. **Harness 10/11** (was 9/11), `install.outcome=failure` (was `timeout`); the one FAIL is the correct `install SUCCEEDED = failure` and **disk-image assertions were correctly SKIPPED, not force-passed** — they remain unexercised, so nothing is claimed about the resulting disk. **`deck_autologin.py` deliberately NOT fixed this session** — a separate module's bug with its own (fixture-encoding-the-bug) test suite; left failing and precisely diagnosed per this project's discipline, flagged as §14.6 item 1 (one-line fix, likely sufficient to let the install COMPLETE — to Desktop Mode, since `gamescope-wayland.desktop` is also absent from the ISO, §14.6 item 2). ⚠️ **Two process lessons recorded** (`docs/findings/…first-run.md` §14.2): a `Monitor` that watches-and-yields is not waiting (its grep missed a mid-pacstrap corrupted-package death and nothing woke the agent — the silent-agent pattern); and `setsid nohup … &` makes `$!` the wrapper, not the build, so poll loops must track the real child/pidfile. Full account: `docs/findings/T4-controller-only-install-first-run.md` §14. |
| 23 | **2026-08-12, session 23 — five background agents on disjoint files, one direct build/deploy. `iso/bin/build` ran for real for the first time ever** (`39d0da6`): first attempt hit a corrupted cached package from an old scratch dir, a clean re-run in a fresh one passed all 8 guards, produced `omarchy-2026.08.13-x86_64-quattro.iso`. **That ISO was then driven through its own installer with a virtual gamepad for the first time ever** (`454e5a8`): the T4 harness, deliberately built against upstream's unmodified ISO as a placeholder, got its promised migration — 59/62 checks, S0 through a never-before-seen `deck_final_summary` screen, disk-confirm safety proven with byte-identical decline-loop captures. Found two real bugs: `deck-form.sh`'s identity/hostname/timezone prompt overrides are unwired (upstream's own prompts still run), and the username-retry screen grows unboundedly on repeat attempts. **Two operator-reported OSK bugs fixed and deployed live to the physical Deck**: "Move" (`86cba11`) now collapses the keyboard via the same signal that already dismisses it elsewhere, instead of being a dead stub copied from Valve's reference for visual parity only; the emoji key (`685440c`) now opens Omarchy's real picker (`omarchy-menu-emoji`) via the same queue/spawn path QAM already uses — the agent that built this caught and corrected a wrong command hypothesis it was handed by reading the actual pinned dispatcher. Both synced via `deck-sync.sh` and the mapper service restarted live, not waiting for next login. **`input.lua`'s last lock-screen fix landed** (`a4b1eab`): `above_lock = 2` and the DPMS wake-suppression lines, closing §5.24a's last open operator request in code (hardware verification still owed); found, not yet fixed, that `omarchy-sleep-lock.service` masking never made it into the live-ISO install path at all. ⚠️ **One agent went silent mid-task with no completion notification** — a direct status check found the harness had no record of it. Its work (a real fix: the gamepad-spike probe's virtual d-pad was writing the trackpad axis, not the d-pad buttons — `deck-input-mapper.py` only reads `BTN_DPAD_*`) was sitting uncommitted and sound; verified independently (syntax, AST parse, full suite) and committed (`4d45ce3`) on that basis, not the agent's say-so. **The suite then actually ran, for the first time in this project's history: 26/26 PASS** — a gamepad drives `gum` and archinstall's curses menu through the kernel input layer, no UI cooperation. Lesson recorded in `docs/START-HERE.md`: an agent saying "I'll report back" is not evidence of anything; check the actual task state and the actual tree. Also decided: `/etc/sudoers.d/asdcontrol` stays (vendor default, out of scope). **All commits pushed.** |
| 22 | **2026-08-12, session 22 — ~15 parallel agents across the day, and the operator at the panel for the last hour. Phase 2 exit criteria 2 and 3 both closed; criteria 1 and 4 reduced to one thing: run a real ISO build.** 🟢 **T5d/e/f + T12 all landed**: the Wi-Fi phase promoted into `iso/overlay/` (one copy, no `src/` duplicate — the rule that fell out: a file that ships on the ISO and nowhere else lives in the overlay at its shipped path), `deck-form.sh` finally has a route onto the ISO (the 5th patch, argued in its own header — the budget's "put it in the package" escape hatch does not exist for the live installer), the `omarchy-deck` pacman package ships T12's real payload (applier, hook, unit — enabled via a shipped `.wants` symlink, no scriptlet), and all four rotation surfaces are baked in. Guards 6.4a **and** 6.4b now understand our own package as a provider; 6.6 fails the build on a drifted runtime patch. 🔴 **Four real bugs caught before they shipped**, each found by running rather than reading: a menu-row glyph written as `$'\U000F0297'`, which is **locale-dependent** — expands correctly under UTF-8, emits ten literal ASCII bytes under the Deck's `LC_CTYPE=POSIX` SSH session, and the stage **refused to write** the resulting invalid JSON rather than silently corrupting the menu; our own shipped Limine-rotation patch carried `interface_rotation: 270`, **180° wrong**, would have flipped the boot menu upside down on the next `omarchy refresh limine`; a composed-path dodge in `deck_patches.py` whose own docstring example matched guard 6.4a's regex and would have demanded a provider for a binary literally named `omarchy-`; and `$SUDO -u` breaking when `deck-session.sh` is already root (`sudo ./script.sh`), silently never writing the idle policy — a comment had predicted this exact failure and left it unfixed, and 526 assertions had never exercised the case. 🟢 **T13/T14 close all four of the operator's power-button reports, hardware-verified**: one physical press produces two `KEY_POWER` events on asymmetric nodes (a real key at `event4`, a fire-and-forget ACPI notify at `event2` — measured with a positive control after two silent captures proved nothing); a udev rule + logind drop-in fix it, deploy is reboot-gated with a printed undo. Measured on the panel: suspend/resume clean in both modes, same `gamescope` PID across the cycle, deep/S3 confirmed twice independently (overturning the initial research's s2idle inference — the kernel logs `PM: Steam Deck quirk - no s2idle allowed!` at 0.27s of boot). T14: Gaming Mode needed **no separate fix** — `logind`'s only gate is the `power-switch` tag, `gamescope` holds no inhibitor. 🟢 **Both reboot-survival directions closed on the panel**: `stage-menu-row` ("Gaming Mode" in the Quickshell menu — lands last, not above System; the extension mechanism only appends) and `stage-boot-default-gaming` (reboot always re-asserts Gaming Mode, an opt-in unit with `ConditionPathExists=!` as its escape hatch), both deployed and pressed by the operator, not just green suites. A read-only conformance sweep (`P22`) corrected the s2idle inference above, found `HandleLidSwitch=suspend` live and undocumented, and found `/etc/sudoers.d/asdcontrol` granting all users passwordless root — package-shipped, not ours, invisible to our audit. **16+ commits, all pushed.** Verify with `git rev-list --left-right --count origin/main...main`, never by trusting this line. |
| 21 | **2026-08-12, the longest session so far — 72 commits, 24 suites, 13 parallel agents, and the operator at the panel for most of it.** 🟢 **§5.28 CLOSED, verified on a COLD BOOT twice** (journal: race at 18.157 s, resolver closes it at 19.159 s, one service start, nothing hand-restarted) — and the Gaming→Desktop switch path, never previously tested, passes too. 🟢 **Exit criterion 2 CLOSED:** P2.3 measured with per-item approval — fan control proven (2500 → **2568 RPM**), TDP (15 → **10** → 15 W), charge limit (0 → **80** → 0), all restored to baseline; `jupiter-fan-control` found **absent** (real parity gap); `fan1_target = 0` measured to mean *EC automatic*, not off. 🎹 **The OSK was REBUILT against measured pixels** — the operator's standard was *"identical"* and ours was a different keyboard. Six `grim` captures of Valve's own became `T8-reference-metrics.md`; now one continuous grid, **key widths within 1.5 px on all 63 keys**, square corners, white-face-plus-blue-dot cursors, per-pad badge gating, `X`→Backspace, `L3`→Caps, hold-to-Shift, pad-click commit, **touch input**, **haptics** (FF_RUMBLE on `event7`, established by disassembling `hid-steam.ko`), a fixed release rule (a **cross**, not a disc — a deadband would blind a reachable aiming point), no pointer jump on lift (**7 of 23 lifts moved the cursor, worst 26 px**), and the keyboard hides for the screensaver while **never** being asked about it under a lock. **All verified on the panel.** 🔴 **"Keys don't type what they should" was TWO bugs** — the session's `latam` keymap *and* `press_at` resolving in the addressing metric while the renderer drew in the proportional one (**287 of 1010 positions committed a different key than the one drawn white**). 🟢 **T5 UNBLOCKED:** the fork's ISO was dying at **phase 5 of 14** on a runtime 50 commits past the pin with no `omarchy-setup-system`; T5b's `--local-source` fixed it, parity re-measured under all four tests — **1177 of 1180 same-version packages byte-identical**. T5b had sat **unmerged for hours** while work built on a stale `bin/build`. T5c landed (Valve repos, Deck packages, an NVIDIA guard with a negative control) and found §3.8 wrong three ways. T4 gained S1's whole Wi-Fi screen, S2/S4/S5, the dashboard trio, and U1 closed at both ends. 🔬 **SEVEN measurement tools lied** (§5.30c) — including `hyprctl eval 'return X'`, which this repo **documented as a verification** and which I then cited as proof of my own change; a `grep` whose exit 2 read as "no match"; the `[V]` harness blaming upstream for a disagreement its own CP437-in-UTF-8 grep manufactured (35/40 → **57/57**, no upstream defect); and 🔴 **`vm-gamepad-spike-test.sh`, a bash syntax error since the day it was committed — never runnable, and the T2 result it is cited for came from a version never committed.** Generalisation recorded: **a check that proves something is ABSENT must also prove it was LOOKING.** Also corrected in-record: **four dead override names** in `deck-form.sh` (upstream never called them; the account screens were silently dead, and one path would have shipped a **passwordless account**), a `failure_menu` in the wrong process with nine green assertions behind it, and my own touch-transform claim — asserted, retracted, then settled by an actual A/B. |
| 20 | **The hardware session 19 prepared for, 2026-08-11 (same calendar day) — the P2.9 runbook executed IN FULL, §1–§7.** The live-ISO lizard gate is **OPEN** (knob exists, 0644, write accepted — U6/U3 answered, T4 unblocked); `stage-lizard-mode`'s fallback proven `Y→N→Y→N` on hardware; **QAM measured = `BTN_BASE` (294)** with delimiter presses on a probe watching all four nodes (two are silent); 🔴 **the §5.24 lock fix VERIFIED IN PIXELS** — keyboard summoned over the lock, password typed with trackpads; **both rotations upright** (`interface_rotation:` **90** — the recorded 270 was 180° wrong, the *second* inverted rotation guess — and `fbcon=rotate:1`), applied as two reboots for attribution, and `limine.conf`'s header **survives `limine-update`**, measured; **7/7 human parity rows** closed (mic/gyro judged by numbers, not ears); Gaming Mode made the default. **Three runbook commands and RECOVERY.md's escape were wrong as written** — the escape had never been executed and fails twice over (no `HYPRLAND_INSTANCE_SIGNATURE`; `clear_crashed_lockscreen` *refuses* healthy locks; there is **no unlock IPC**). 🔴 **New release blocker §5.28, found by the operator and confirmed by cold boot: a freshly booted desktop has NO keyboard, no menus** — the mapper wins the race against uwsm's env import and its children are born blind; a restart fixes it; the unit's own "never talks to the compositor" justification had silently expired. §5.24a: locking blanks the panel in ~5 s (a hardcoded `interval: 5000` in upstream's lock QML — source-traced and panel-measured independently); only QAM and Power wake it; three operator requirements recorded. **Steam-in-background: closed by measurement (R-53, XTEST reaches nothing on Hyprland — the first run's control caught a wrong result), then REOPENED at higher effort (R-54: extest's XTEST→uinput bridge DOES reach Wayland clients here)** — `tools/build-extest.sh` pinned, both targets built, **T10 spike prepped** for the next Deck session, whose row 7 tests the hard case: the lock under a resident Steam. Touch plan for our OSK approved and **ON HOLD pending T10**; T8 §9 gained the reference-layout transcription and the badge/input-model collision. Four parallel agents: three merged (T5a `iso/` skeleton — **parity UNPROVEN**, no artifact survives; the lock-wake source trace; OSK auto-hide + restyle, not deployed), the T4 harness **unfinished** — three untracked files in its worktree. Six of my own conclusions corrected in-record by measurement. |
| 19 | **The largest session so far, 2026-08-11 — phase 2.9 opened and closed in one day.** It began "rebase onto the new 4.0 beta 2" and **measurement showed we were already on it**: same `6d7826d`, same `edge` channel, same builder as upstream's published ISO, differing only in 7 stock Arch rebuilds we carried the *newer* of. So the block's value was elsewhere — the delta **ahead** of us classified (1 BREAKS US / 27 RE-VERIFY / 37 NO IMPACT), the QEMU substrate rebuilt on the channel we actually ship with its boot chain **asserted**, and all four VM suites green on it for the first time. **Twelve operator decisions settled** (§5.25). 🔴 **Found the biggest live defect of the project so far: the power button locks the Deck into a password screen with no password field** (§5.24) — and inverted the delta's scariest row while finding it. Built `stage-lizard-mode` with a fallback whose safety argument I got **wrong twice**, corrected both times by measurement (§5.25). Shipped five new test suites; 15 total. Wrote T4's screen spec and **proved its automated test tier viable**, T5's fork plan (whose first finding was that the obvious fork point is *broken*), the P2.9 Deck runbook, and RECOVERY's one-command escape from a stranded lock. ⚠️ **The session's real theme: four times a measurement TOOL lied rather than the code** — `grep` against CP437 glyphs, a cached console width, `hyprctl layers`, and `grep -c shift` on a destroyed keyboard. Each was caught by checking the instrument, not the reading. |
| # | What happened |
|---|---|
| 1 | Bootstrap; T0 §1 harness + libraries + unit tests; T0 §2–6 (Ventoy doc, override loader, `tools/deck-sync.sh`, CI, shellcheck baseline) |
| 2 | T0 §1 verified end-to-end against a real ISO build; found two real bugs in this project's own harness |
| 3 | R1 §10.1/10.2/10.4/10.5 resolved; §10.6 drafted and held |
| 4 | T1 steps 1–2 — near-total rewrite of `src/omarchy-deck-kernel.sh`; four design premises were false |
| 5 | T1 step 3 — the pacman hook; found upstream already covers most of it, so ours verifies rather than generates |
| 6 | T1 steps 4+6 — nine independently runnable stages, provably non-interactive |
| 7 | First physical hardware run; two real bugs found; R1 §10.3 resolved; Steam/gamescope installed; prior-art check done |
| 8 | First Gaming Mode boot, via a DeckShift hybrid splice (since reversed — §2.3) |
| 15 | **Phase 2 opener, 2026-08-10.** §5.10 closed — Steam's own Switch-to-Desktop works, with **two** causes not one (OOBE, plus the runtime narrowing PATH to `/usr/bin:/bin`, which made the `/usr/local/bin` shim unreachable all along). §5.14 closed with a stub, after learning its exit codes are a protocol: apply exiting 0 made Steam **reboot the Deck**. §5.11's greeter + desktop fixed — transform is **3**, not the recorded 1, and Omarchy's `auto` scale left a 640×400 desktop. A `#` marker in a Lua file taught us Hyprland **silently discards** an unparseable config. Opened §5.15 (the whole polkit-helper surface, incl. brightness) and §5.16 (the switch latched sddm into permanent failure). |
| 17 | **The eyes-and-hands pass, 2026-08-10 — the first time any of this was seen on a screen.** Nine defects, **none visible to any check in this repo**, and two recorded "facts" corrected, one written by this session hours earlier. **The mapper was a complete no-op** on the desktop: `active`, correctly bound, and its node silent under lizard mode — P2.1's "verified on hardware" was true in every particular and proved nothing. Under it: the **d-pad emitted nothing** (`hid-steam` advertises `ABS_HAT0*` and only sends `BTN_DPAD_*`, so the suite passed against a device model this hardware lacks) and **a resting stick cancelled every held direction in ~10 ms**. The mapper then became the **full input layer** — pointer, clicks, and the operator's requested **STEAM+X** chord, which is only detectable with `lizard_mode=N` — surfacing four more bugs, the worst being that **diagonal pointer movement emitted nothing at all** while every single-axis test passed. Also: **§5.20 answered** (the OSK works; one GSettings key gated it, and it was *first recorded here as a negative* after four experiments that all sat downstream of that gate); an unquoted heredoc **executing `uwsm start ... Hyprland` as root** at render time, which had left **CI red** while §1 claimed it passed; **`stage-desktop-settings`** shipped, turning three hand edits into dconf site defaults; **Gaming Mode confirmed usable** by the operator (R-38); **the idle lock disabled** because no available keyboard can reach a layer-shell lock screen, and `lock: 0` locks *instantly* rather than disabling. **§2.6 was decided and then FORCED to change**: Steam cannot drive a Wayland desktop (XTEST under XWayland — R-42) and a resident Steam is *actively harmful*, removing the desktop's only input path, so the plan is now squeekboard everywhere except Gaming Mode with Steam **not** autostarted. Opened **T8** (the OSK we draw ourselves — squeekboard cannot do dual-cursor selection at any configuration). Findings: `docs/findings/P17-input-and-osk.md` (R-29…R-42). |
| 16 | **P2.0b + P2.0c, 2026-08-10.** `steamos-set-timezone` + `steamos-priv-write` shipped as two new `deck-session.sh` stages, both signatures **read from Steam's log** rather than inferred, both hardware-verified with a real change and restore. Operator skipped `jupiter-hw-support`. Corrected §5.15: the brightness slider **works** on this Deck — Steam falls back to `sudo -n tee` and then `sudo -n chmod a+w`, which is also what makes those sysfs nodes 666. Opened §5.17 (`99-deck-testing`'s blanket NOPASSWD masks privilege defects and must not ship). Then **P2.0c**: §5.16's real cause was the **stop timing out** (`TimeoutStopSec=5`, teardown 5.008s → SIGKILL → start 3ms later), not the retry spacing — R-26's `RestartSec` rationale was wrong, and it fired at **boot**, not only on switches. Fixed with `TimeoutStopSec=30` + stop→settle→start in a `systemd-run` transient unit; **20/20 soak clean**. The soak also found **§5.18**: a dead session lands on a password greeter, because SDDM ships `Relogin=false`. Then **P2.0e/§5.13**: the repo overlap was **audited** (101 collisions, Valve older in 50 -> reordering rejected; the fix is `pacman -S jupiter-staging/gamescope`), and the suite's last blind spot closed. Two defects were introduced by this session's own fixes and caught by mutation testing and soaking, not review -- a settle gate matching the comm name `gamescope`, which no process has. Unit suite 17 -> **62 assertions**, mutation-tested **39/39**. Closed 5.11/5.13/5.16/5.18, answered 5.5/5.17, shipped P2.1 + P2.2's programmatic half, drafted `docs/RECOVERY.md`. **Operator added phase 4** (the enablement layer) and a Deck-specific flasher was considered and reframed. |
| 9 | **One long session, 2026-08-09/10 — the scope reset and all of phase 1's non-hardware work.** Five scope decisions (§2): the ISO is the deliverable again, network-at-install is fine, target 4.0, DeckShift dropped, Deck rebuilds allowed. Docs consolidated (`PROGRESS` 1403→~600 lines, `WHERE-WE-ARE` folded in, `PLAN` frozen with a known-wrong-sections banner); `docs/ROADMAP.md` written (three phases); dead drafts removed. **P1.1:** `stage-default-entry` with the path form *proven by boot*, substrate rebuilt with real snapper snapshots (which immediately caught the hook test's own substring miscount), three deliberate-failure tests. **P1.2–P1.3:** T2 spike resolved — a gamepad drives `gum` and `archinstall` at the kernel input layer, so T4 is days not weeks. **P1.4 (half):** 4.0 beta ISO built; static inspection decided T4's OSK question and found the OLED Deck's `nfa765` Wi-Fi firmware present (§5.1). Repo reorganized out of the flat layout (a root `*.sh` glob had silently gone from checking every script to none). |
