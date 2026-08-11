# T4 — the installer screen specification

**Design only. Written 2026-08-11 (session 21). No installer code exists yet.**
**Model: Opus for §1–§3 and §6; Sonnet for the per-screen prose in §4.**

This supersedes the screen list in `docs/tasks/T4-installer-ui.md` and in
`docs/PLAN.md` §6.1a. That task file stays as the objective and the "failure
modes to watch for"; **this file is the spec.**

## 0. How to read this

Everything marked **(READ)** was read this session from the actual source — via
`gh api` against `omacom-io/omarchy-iso@a12bfea7a86c` and
`basecamp/omarchy@6d7826d` (the pins T5 chose), or from a file in this repo,
named inline. Everything marked **(INFERRED)** is reasoning over those reads and
**has not been run**. Everything marked **(MEASURED)** is a hardware or QEMU
result already recorded in `docs/PROGRESS.md` / `docs/findings/`, cited.

The distinction is kept because this project's recurring failure is a plausible
inference recorded as a fact, and because §6's whole subject is checks that pass
for the wrong reason.

**Nothing in this document has been executed.** Every "verified by" row is a
specification, not a result.

---

## 1. The decision: **wrap the configurator. Do not replace it. Do not feed it.**

### 1.1 What upstream actually does

The live ISO's install path, end to end **(READ:
`configs/airootfs/root/.automated_script.sh`)**:

```
agetty tty1 -> .automated_script.sh
  ├─ omarchy-cidata-load        ── if a drive labelled `cidata` carries
  │                                user_configuration.json + user_credentials.json,
  │                                copy them to /root and SKIP the wizard entirely
  │                                (sets OMARCHY_UI_INTERACTIVE=no)
  └─ ./configurator             ── otherwise: the interactive wizard
                                   writes /root/user_configuration.json
                                          /root/user_credentials.json
                                          /root/user_{full_name,email_address}.txt
                                          /root/user_encrypt_installation.txt
then, always:
  omarchy-install-dashboard <log> <state> -- omarchy-iso-install --config … --creds …
    └─ orchestrator/main.py, 14 phases (READ: `build_phases`)
```

Three facts about `configurator` that decide this section, all **(READ)**:

1. **It is bash + `gum`, ~1200 lines, and it already produces a machine-readable
   artefact.** Every answer lands in `user_configuration.json` (archinstall's
   schema plus an `omarchy_install` block) and `user_credentials.json`. Nothing
   about a screen is implicit.
2. **Its prompts are not in it.** `configurator` sources
   `/usr/share/omarchy-iso/setup-form.sh` (lines 19–25) — a file
   `builder/build-iso.sh` *vendors out of the runtime package at build time*
   (line 187), so the ISO wizard and Omarchy's first-boot owner setup can never
   drift. The prompts are ordinary bash functions: `omarchy_prompt_keyboard`,
   `_username`, `_password`, `_identity`, `_hostname`, `_timezone`.
3. **Every prompt reports one of exactly three statuses** — `0` set, `1` Esc
   ("back"), `130` Ctrl+C (a per-caller side channel) — because "Esc and Ctrl+C
   are the only keys any gum widget exits on" **(READ: `setup-form.sh` header)**.

### 1.2 The decision

**Wrap.** Our ISO overlay ships one additional file,
`configs/airootfs/usr/share/omarchy-iso/deck-form.sh`, and one patch to
`configurator` with **two hunks**:

| Hunk | Where | What |
|---|---|---|
| 1 | immediately before `wait_for_stable_terminal` (line ~985), i.e. after every function in `configurator` *and* `setup-form.sh` is defined and before the flow runs | `source /usr/share/omarchy-iso/deck-form.sh` |
| 2 | immediately before `write_user_files` (line ~1025) | `deck_final_summary \|\| abort` |

`deck-form.sh` then **redefines** the prompt functions it needs to change. Bash
takes the last definition, so no upstream line is edited to change a screen —
the screens are ours, the control flow, the JSON schema and the artefacts stay
upstream's.

### 1.3 Why not the other two

**Replace** (write our own screens, emit the JSON ourselves) is rejected on
measured evidence about upstream's velocity. `docs/tasks/T5-fork-plan.md` §0
established that four commits landed on `quattro` in nine hours and one of them
was a breaking rename that would have failed an install two-thirds of the way
through. The JSON we would have to emit carries `"version": "3.0.9"`, a
hard-coded partition `obj_id` GUID that the encryption block references by
value, and an `omarchy_install` block whose shape the orchestrator reads
**(READ)**. Owning that schema means re-deriving it on every runtime bump, for
no user-visible gain — the schema is not a screen.

**Feed** (drive everything through `cidata`) is rejected as the *product* and
adopted as a *test tier*. `omarchy-cidata-load` **(READ)** exists precisely to
stand in for the wizard, and `.automated_script.sh` sets
`OMARCHY_UI_INTERACTIVE=no` when it fires, which suppresses every prompt the
dashboard owns. That is exactly what an unattended install regression test wants
— and it is exactly what a controller-only *product* must not be, because the
whole deliverable is the wizard. `test/vm/vm-install-test.sh` already uses it.

**The strongest argument for wrap is §6's**: because the wrap keeps upstream's
artefact files, every screen's correctness can be asserted from a JSON file
instead of from pixels. Replace would keep that property; feed would delete the
screens; wrap keeps both the property and upstream's maintenance.

### 1.4 Patch budget

T5's overlay discipline is **≤ 4 patch files, and a fifth must argue for itself**
(`docs/tasks/T5-fork-plan.md` §1). T4 spends **two**:

| # | File | Hunks | Why it cannot be an additive overlay file |
|---|---|---|---|
| P1 | `configs/airootfs/root/configurator` | 2 | The source line and the final-summary call must land inside upstream's flow |
| P2 | `builder/build-iso.sh` | 1 | `python-evdev` must be added to the **live environment's** `packages.x86_64` (line ~120, `arch_packages`). T5 already patches this file for S1; this is a shared hunk, not a new file |

Everything else is additive: `deck-form.sh`, the mapper, the three OSK modules,
`deck-installer-textmode`, and one systemd unit.

> ⚠️ **P1 hunk 2 is why the summary is not an override.** `write_user_files`
> could be renamed-and-wrapped with `declare -f | sed`, saving a hunk. Rejected:
> a rename that silently fails produces an installer that writes no config and
> whose failure surfaces four phases later. Two legible hunks beat one clever
> one.

---

## 2. The input contract — what a Steam Deck can physically express

Nothing in §4 is designable without this. All of it is **(MEASURED)**.

### 2.1 The two modes, and they are exclusive

| | **Lizard mode** (firmware default, no software) | **`lizard_mode=N` + our mapper** |
|---|---|---|
| Pointer | ✅ trackpads → one merged relative mouse | ✅ right pad → mapper's own uinput pointer |
| Enter | ✅ **A** | ✅ A |
| Esc | ✅ **B** and **☰ Menu** | ✅ B |
| Tab | ✅ **⧉ View** | ✅ X |
| Arrows | ✅ **d-pad** | ✅ d-pad **and** left stick, with auto-repeat |
| Mouse click | ✅ **R2 = left, L2 = right** | ✅ triggers |
| **Space** | ❌ **not produced at all** | ✅ `Y → KEY_SPACE` |
| PageUp / PageDown | ❌ (L1/R1 are swallowed) | ✅ L1 / R1 |
| X, Y, L1, R1, STEAM, QAM | ❌ **reach no evdev node whatsoever** | ✅ all live |
| Trackpads as **absolute** axes | ❌ (only a merged relative mouse) | ✅ `ABS_HAT0X/Y`, `ABS_HAT1X/Y` |
| **On-screen keyboard** | ❌ **impossible** — the OSK needs two absolute cursors | ✅ |
| If our software dies | nothing to die | ❌ **the device has no input at all** |

The lizard-mode column is a delimited, button-by-button measurement, not a
capability bitmap: `docs/findings/P17-input-and-osk.md` R-29 (an A press between
every test button, because **a silent button leaves no marker**). Also
`docs/PROGRESS.md` §5.9 + its session-17 addendum,
`docs/findings/P15-live-iso-recon.md` R-3/R-8, R-30, and `docs/PROGRESS.md` §5.21.

The knob is `/sys/module/hid_steam/parameters/lizard_mode`, a writable module
parameter that **does not persist across a reboot** (§5.21).

### 2.2 Four things a Deck cannot do, and every one of them changes a screen

1. **There is no Ctrl key.** Not in lizard mode (no modifier reaches an evdev
   node), not in `src/deck-input-mapper.py`'s table, and not in
   `src/deck_osk_layout.py` — its two layers are digits, letters, punctuation,
   shift, layer-switch, tab, backspace, enter, space, arrows, home/end/del and
   `close`. **(READ, this session, both files.)**
   → Upstream hides **both** the unencrypted-install toggle and the
   deferred-provisioning entry behind **Ctrl+C** **(READ: `configurator`
   `confirm_disk_overwrite` line 894, `run_partition_decide` line 601,
   `keyboard_form` line 189)**. On a Deck those are not choices; **the default is
   the only reachable value.** This kills §6.1a's encryption screen (§3, item 6).

2. **`less` cannot be quit.** The dashboard's failure menu offers "View full
   log", which runs `less` **(READ: `omarchy-install-dashboard`
   `view_failure_log`, line 575)**. `less` quits on `q`/`Q`/`ZZ` — character
   keys. Lizard mode produces none, and the mapper's *nav profile* deliberately
   emits none either (`docs/findings/T2-gamepad-spike.md` §2); the only source of
   a `q` on this device is the OSK, which needs `lizard_mode=N`, a live mapper
   and a text-entry mode that nothing on that screen enters. **A controller-only
   user who picks "View full log" is trapped.** (Bringing the OSK up there is a
   possible fix; §4's S8 prefers a pager that exits on Esc, because it removes
   the dependency instead of adding one.)

3. **`less`'s sibling is worse: "Drop to shell".** `failure_menu`'s `gum choose`
   offers it, and — this is the part that matters — **Esc selects it**: the
   `|| choice="Drop to shell"` fallback fires on a cancelled prompt **(READ,
   lines ~628 and ~638)**. So on a failed install, pressing B lands a
   keyboard-less handheld at a bash prompt. (§4.8)

4. **The OSK is US-layout by construction.** It emits *keycodes*; the console
   applies whatever keymap `loadkeys` last set. `deck_osk_layout.py`'s shifted
   faces are the US table (`sym(e.KEY_2, "2", "@")` …) and
   `test-deck-osk-layout.py` round-trips against a US table the test owns
   **(READ)**. Run `loadkeys de` — which `configurator` does at the end of
   `keyboard_form` **(READ)** — and the key drawn `y` types `z`. This kills the
   keyboard-layout half of §6.1a's region screen (§3, item 2).

### 2.3 The design that follows: **bounded text-entry mode**

Neither mode alone can run the installer. Lizard mode cannot type; `lizard_mode=N`
makes a single Python process the only input path on a device with no keyboard.

**So the installer runs in lizard mode, and drops into text-entry mode for the
duration of one prompt.**

```
deck_text_prompt <fn> [args…]        (a function in deck-form.sh)
  1. echo N > /sys/module/hid_steam/parameters/lizard_mode      (if the file exists)
  2. start:  deck-input-mapper --osk-backend=tty --osk-start-shown
             …wait for it to report a bound pad, with a deadline
     on failure -> step 5, and the prompt runs WITHOUT an OSK, which is a
                   degradation the screen must state, not swallow
  3. run the gum prompt; the user types with both trackpads
  4. prompt returns (Enter, or Esc after the OSK's `close` key)
  5. trap/always: kill the mapper, echo Y > …/lizard_mode
```

Why bounded rather than flipping once at boot:

- **The blast radius is one prompt.** §5.21's standing objection to persisting
  `N` is that a dead mapper leaves an uncontrollable handheld. Here the window is
  seconds long and `trap` closes it on every exit path including `set -e`.
- **`lizard_mode=Y` is the failure mode**, not a state anyone has to reach.
  A reboot also restores it, since the parameter does not persist.
- **It is the only arrangement where the un-instrumented screens need no software
  of ours at all.** Every navigation-only screen in §4 works on a stock Deck with
  the mapper absent, which is the cheapest possible dependency.

⚠️ **Two mapper flags do not exist yet** and are T4 work items, not T8's:
`--osk-start-shown` (come up with the keyboard visible — the STEAM+X chord that
normally summons it is one of the six buttons lizard mode swallows, so it cannot
be the entry point) and a machine-readable "pad bound" line on stderr that step 2
can wait on with a deadline. The mapper already places the keyboard at the bottom
of the console by default (`--osk-top-row 0`), so no placement flag is needed.

⚠️ **`hid_steam` may not be loaded in QEMU, and `lizard_mode` will not exist
there.** Step 1 must treat a missing file as "not applicable, continue", and that
branch must be unit-tested — otherwise every QEMU run silently exercises a
different code path from the Deck. **(INFERRED** that the file is absent under
QEMU; nobody has looked.**)**

### 2.4 What the ISO must carry for any of this — and one of them is missing today

| Needed in the **live** environment | State |
|---|---|
| `gum`, `jq`, `openssl`, `python3` | ✅ already there **(READ: `build-iso.sh` `arch_packages`)** |
| `iwd` / `iwctl` | ✅ present, **not started** — `systemctl start iwd` was required **(MEASURED: P15 R-0)** |
| `tzupdate` | ✅ already there **(READ)** |
| **`python-evdev`** | ❌ **absent, and unfetchable** — the live `pacman.conf` declares one offline repo and nothing else, so `pacman -Sy python-evdev` returns "target not found" with working internet **(MEASURED: P15 R-9/R-10)**. → patch P2 |
| `src/deck-input-mapper.py` + `deck_osk_layout.py` + `deck_osk_tty.py` | ❌ additive overlay files, `/usr/local/bin` + `/usr/local/lib/deck-osk/` (mirror `stage-input-mapper`'s layout so the shipped path is the tested path) |

⚠️ `docs/tasks/T5-iso-and-payload.md` lines 88 and 235 still say **squeekboard**
is the live ISO's keyboard. That is stale — `docs/findings/T2-gamepad-spike.md`
§4 and `docs/PROGRESS.md` §2.6 replaced it with T8's own OSK, because the live
environment has no compositor and **no `libwayland` at all**
(`docs/findings/T9-iso-comparison.md` §5a). Do not ship squeekboard in the ISO.

### 2.5 Console geometry and orientation

- **Orientation is correct for free, and it is load-bearing.** The live ISO boots
  `linux-t2`, whose DRM panel-orientation quirk sets
  `/sys/class/graphics/fbcon/rotate = 1` with no cmdline flag, and the "press
  return to install" screen was seen upright on the Deck **(MEASURED: P15 R-1a,
  R-4)**. The *installed* system's stock Arch kernel reports `0` and renders
  rotated (R-12) — so this is a property of the ISO's kernel, not of the
  hardware. **Do not add `fbcon=rotate:`** to the live cmdline; it would
  double-correct. **Assert it instead** (§6.2, A6): if a future ISO drops
  `linux-t2`, every screen turns sideways and nothing else would notice.
- **The Deck's live console size has never been recorded.** The OSK renders
  73 columns × 5 rows (`KEY_CELL=7`, `GUTTER=3` — READ, `deck_osk_tty.py`), and
  `configurator` waits up to 5 s for the console to reach the Omarchy logo's
  width (~81 columns) before drawing anything **(READ, `wait_for_stable_terminal`)**.
  If the Deck's console is narrower than 81, upstream's first frame is already
  wrapped and ours is too. **Open unknown U3.**
- ⚠️ **`stty rows` resizes a Linux VT rather than merely reporting a smaller
  size**, so "shrink the TUI out of the bottom rows" deletes the rows the
  keyboard needs, silently, by clamping five rows onto one **(MEASURED: R-49,
  `docs/findings/P18-osk-hardware-pass.md`)**. The keyboard takes the bottom of
  the **full** console and the TUI keeps all of it. `gum` uses three rows and
  never reaches the bottom, so they coexist — proven, `gum.received = hlH1`
  (`test/vm/vm-osk-tty-test.sh`).
- ⚠️ **`configurator` clears the whole screen on every step.** `clear_logo` is
  `printf "\033[H\033[2J"` **(READ)**, and `notice()` — the validation-failure
  path — calls it. So a rejected username erases the keyboard mid-typing. The
  mapper must repaint the OSK after each keystroke and on a timer while shown.
  **Open unknown U4**: whether it repaints today is unverified.

---

## 3. The screen list, and every deviation from `docs/PLAN.md` §6.1a

| §6.1a | This spec | Verdict |
|---|---|---|
| 1. Language | — | **CUT** |
| 2. Region (keyboard + timezone + locale) | S2 Region | **KEPT, narrowed to timezone** |
| 3. Agreements | folded into S0 | **KEPT, merged, zero extra screens** |
| 4. Disk confirmation | S4 Disk | **KEPT, simplified** |
| 5. Account | S3 Account | **KEPT, narrowed** |
| 6. Encryption on/off | — | **CUT — it is not a choice on this hardware** |
| 7. Wi-Fi | S1 Wi-Fi | **KEPT and promoted to first** |
| 8. Summary | S5 Summary | **KEPT, widened** |
| — | S0 Welcome + disclosure | new (upstream already has a greeter) |
| — | S6 Progress | new to the spec; upstream owns it; it needs one patch |
| — | S7 Completion / reboot | new to the spec; upstream owns it; it works as-is |
| — | **S8 Failure** | **new, and the biggest gap in §6.1a** |

**Count: 6 interactive screens + progress + completion + failure.** §6.1a's
target was 8. This is 6 the user answers, which is the direction §6.1a asked for.

### The six deviations, with their evidence

1. **Language: cut.** `configurator`, `setup-form.sh`, the dashboard and every
   `gum` string are English literals, and the emitted JSON hard-codes
   `"archinstall-language": "English"` and `"sys_lang": "en_US.UTF-8"`
   **(READ)**. A language picker would change nothing the user reads. Shipping
   one is the "don't claim support you haven't tested" rule (`CLAUDE.md`) applied
   to a screen. If translation ever happens, this screen comes back first.

2. **Region: no longer sets the keyboard layout.** Two independent reasons:
   §2.2 item 4 (the OSK is US-only, so `loadkeys` makes the drawn keys lie), and
   `docs/tasks/T5-fork-plan.md` §5.3, which already bakes
   `org.gnome.desktop.input-sources = [('xkb','us')]` into the installed
   desktop. Upstream's own reason for the screen — so the LUKS passphrase is
   typed under the right layout **(READ, `configurator` line ~1016 comment)** —
   evaporates when encryption is off. `keyboard` becomes the constant `us`, and
   **the console keymap is never changed in the live environment.**
   ⚠️ **This is a real reduction for non-US users. Say so in the release notes.**
   The follow-on that restores it is bounded and named: per-layout tables in
   `deck_osk_layout.py` plus ordering `loadkeys` after the OSK knows the layout.

3. **Region: the flat timezone list is replaced by a two-level pick.**
   `omarchy_prompt_timezone` feeds ~600 `timedatectl list-timezones` entries to
   `gum choose` (or `gum filter` when the geo guess fails) **(READ)**. Lizard mode
   produces **no PageUp/PageDown** — L1/R1 reach no evdev node (§2.1) — so that is
   up to ~600 d-pad presses. Area (`Africa`…`Pacific`, ~11) then city is two
   presses plus a short scroll. When Wi-Fi connected on S1, `tzupdate -p` gives a
   correct default and it is **one** press.

4. **Encryption: cut as a screen; it is a constant, `false`.** §2.2 item 1 — the
   toggle is Ctrl+C-only and there is no Ctrl. Beyond reachability, an encrypted
   Deck is a **brick for the intended user**: the LUKS passphrase is asked by the
   initramfs, which has no Python, no mapper and no OSK, so nobody can answer it
   (`docs/PROGRESS.md` §5.12). ⚠️ And it does not ship alone: `configure_login`
   writes `autologin.conf` **only `if ctx.encrypt`**, so turning encryption off
   deletes autologin and re-creates §5.18's unanswerable SDDM prompt
   (`docs/PROGRESS.md` §5.12a). **T4's constant and T5's §5.5 patch + unconditional
   autologin drop-in are one change with one test.** TPM2 stays a follow-on.

5. **Disk: the install-mode picker is suppressed.** `install_mode_form` offers
   "Free space install (alongside existing data)", whose decide-half runs
   BitLocker detection, Windows-ESP detection and a free-space analysis with three
   distinct failure screens **(READ, `run_partition_decide`, `not_enough_space`,
   `open_partition_tool` — the last one launches `cfdisk`, which is
   unnavigable with a controller)**. None of it has meaning on a Deck. Forcing
   `full_disk_only=true` uses upstream's own existing skip path.
   ⚠️ **The microSD must be excluded from the picker by `lsblk -dno RM`, not by
   name.** Excluding `mmcblk*` would also exclude the 64 GB LCD Deck's internal
   eMMC — and per `CLAUDE.md` LCD is unverified anyway, so the model gate belongs
   here too.

6. **No screen has a timeout, and §6.1a's "fallback if the user does nothing" is
   answered differently.** A screen that self-advances on a clock makes an
   unattended decision on a handheld somebody set down — the failure class this
   project exists to attack. Instead: **every non-blocking screen has a visible
   one-press default**, and the three blocking ones (Wi-Fi's consequence is
   stated, account, disk) block forever, visibly.

**Not reordered:** upstream runs account *before* disk; §6.1a implies the
reverse. With encryption off the order has no functional consequence, and
reordering costs three more patch hunks. Left alone deliberately.

**Still not prompted, ever** (unchanged from §6.1a): bootloader (Limine),
filesystem (btrfs), profile, network backend, swap/zram, theme. **Added to that
list by this spec:** language, keyboard layout, encryption, hostname, git
identity (full name / email), install mode.

---

## 4. The screens

Each screen states: **purpose · what is on the console · controls · text entry ·
failure states · verified by**. Verification tiers follow
`docs/tasks/T5-fork-plan.md` §5's convention: **[U]** unit (seconds, no VM) ·
**[V]** QEMU, against the real ISO · **[H]** hardware, T6 release gate.

### S0 — Welcome and disclosure

- **Purpose.** One frame that says the machine is about to be installed, and
  discloses the proprietary firmware the image relies on. §6.1a item 3's
  "agreements" screen, merged into the greeter upstream already draws so it costs
  no screen.
- **On the console.** Upstream's centred Omarchy logo and tagline **(READ:
  `greeter`)**, with the hint line replaced and three lines added:
  *"This installs Omarchy on your Steam Deck and erases the internal drive."* /
  *"It includes proprietary firmware from AMD and Valve (graphics, Wi-Fi,
  Bluetooth, audio DSP) — the Deck does not work without it."* / *"Steam and the
  audio DSP firmware are downloaded from Valve during setup."* Then
  **`Press A to begin`**.
- **Controls.** A (Enter) only. Upstream's `IFS= read -r _ </dev/tty` accepts it.
- **Text entry.** None.
- **Failure states.** ⚠️ Upstream runs a `tte` colour animation here and **leaves
  the tty in raw/no-echo mode when killed**, which silently kills the gum prompts
  that follow unless `stty sane` runs **(READ, the comment is upstream's own)**.
  Our override must keep that `stty sane`. Losing it is invisible until S1
  refuses input.
- **Verified by.**
  - **[U]** the rendered text contains the firmware sentence; asserted on the
    function's output, not on a screenshot.
  - **[V]** `/dev/vcs1` carries the disclosure line **and** the prompt marker,
    and a single A press advances (the S1 marker appears and the S0 marker is
    gone — *both halves*, per `docs/findings/T2-gamepad-spike.md` §5 bug 2).
  - **[V]** `stty -a </dev/tty1` reports `echo` after S0 returns.
  - **[H]** T6: the frame is upright and not wrapped.

### S1 — Wi-Fi  🔴 the hardest screen in the flow

- **Purpose.** Join a network. Needed for the timezone default (S2), for
  `configure_deck`'s fetch of `steamdeck-dsp` and `steam`
  (`docs/tasks/T5-fork-plan.md` §4.1), and for Steam to be usable at all
  (`docs/findings/R1-10.4.md`). **Upstream has no such screen** — `build-iso.sh`'s
  own comment is *"The install is entirely offline and the live environment needs
  no Wi-Fi driver"* **(READ)** — so this is the single largest piece of new UI T4
  builds.
- **On the console.**
  1. `Networks` header, a `gum choose` list of SSIDs with signal and a lock glyph,
     plus a literal final row **`Skip — set up Wi-Fi later`** and **`Rescan`**.
  2. On a locked network: `gum input --password` with the OSK drawn on the bottom
     five rows.
  3. `Connecting to <SSID>…` (`gum spin`), then either `Connected` + the IP, or
     the failure branch (§5).
- **Controls.** D-pad/stick = move, A = select, B = back to the list.
  Trackpads = the two OSK cursors, triggers = press the key under **their own**
  cursor. `close` on the OSK hides it and restores B→Esc.
- **Text entry.** ✅ **Yes — this is the one that made T8 exist.** Text-entry mode
  (§2.3) for the passphrase prompt only. Requirements the OSK already meets
  **(MEASURED, T8 + R-47)**: mixed case via one-shot/locked shift, digits on the
  top row of both halves, `!@#$%^&*()_+{}|:"<>?` via shift, the rest via the
  symbols layer, backspace and arrows for mid-passphrase repair.
- **Failure states.** Full decision tree in §5. Summarised: no `wlan0`; no
  networks found; wrong passphrase; associated but no DHCP; user skips.
- **Verified by.**
  - **[U]** the SSID list builder, given a recorded `iwctl station wlan0
    get-networks` fixture, produces the expected rows **including** the Skip and
    Rescan rows, and never lets an SSID containing a `|`, a space or an ANSI
    escape corrupt the list. (Hostile SSIDs are attacker-controlled text drawn on
    a root console; treat them as data.)
  - **[V]** ⭐ **the end-to-end one, and it is the acceptance test for T4:** in
    QEMU, a scripted virtual Deck pad types a mixed-case passphrase with digits
    and a symbol into the real S1 prompt, and the assertion is what the *prompt
    received* — read back from the file `gum` wrote — not from the screen. This is
    `test/vm/vm-osk-tty-test.sh`'s proven shape (`gum.received = hlH1`) pointed at
    the real ISO instead of the substrate.
  - **[V]** the skip path writes the "no network" marker and the summary (S5)
    shows it.
  - **[V]** lizard mode is restored: after the prompt returns,
    `/sys/module/hid_steam/parameters/lizard_mode` reads `Y` **(where the file
    exists)**, and `pgrep deck-input-mapper` finds nothing.
  - **[V]** the negative case: kill the mapper mid-prompt and assert the trap
    restored `Y` and the screen said so. **A guard nobody has seen fail is not a
    guard** (`docs/tasks/T5-fork-plan.md` §5.4).
  - **[H]** 🔴 T6, mandatory: a human joins their own WPA2 network on the Deck
    with no keyboard attached. `docs/PROGRESS.md` §5.1's association was driven
    from a shell with a keyboard; **the controller-only half has never been done.**

### S2 — Region (timezone)

- **Purpose.** Set the clock. §6.1a item 2, narrowed per §3 deviation 2.
- **On the console.** `Where are you?` → area list (`Africa`, `America`, `Asia`,
  `Atlantic`, `Australia`, `Europe`, `Indian`, `Pacific`, `UTC`) → city list for
  that area. When S1 connected, `tzupdate -p`'s guess is pre-selected and the
  header says `Detected: Europe/Copenhagen — press A to keep it`.
- **Controls.** D-pad/stick, A, B = back to the area list.
- **Text entry.** None. ⚠️ **This is why the two-level pick is not cosmetic:**
  upstream falls back to `gum filter` when the geo guess fails **(READ)**, and
  `gum filter` narrows by typing. Without a network and without an OSK on this
  screen, `gum filter` degrades to arrowing through ~600 rows.
- **Failure states.** No network → no guess → the area list opens on `Europe`
  with nothing pre-selected, which is a visible default, not a silent one.
  `timedatectl list-timezones` empty (should be impossible) → fall back to `UTC`
  and say so on screen.
- **Verified by.**
  - **[U]** area→city derivation from a fixture list: every area present, every
    city belongs to its area, `UTC` reachable, and the geo guess selects the right
    area *and* the right row within it.
  - **[U]** the guess is sanitised — `tzupdate` output is network-derived text and
    must match `^[A-Za-z_]+/[A-Za-z0-9_+-]+$` or be discarded.
  - **[V]** with the pad, pick a non-default timezone and assert
    `jq -r .timezone /root/user_configuration.json` equals it. **The artefact, not
    the screen.**
  - **[V]** with no network, the screen still completes with ≤ 6 presses.

### S3 — Account

- **Purpose.** Username and password. §6.1a item 5. No safe default; blocks.
- **On the console.** `Let's set up your user account…` (upstream's `step`
  frame), then `Username>` and `Password>`/`Confirm>` — upstream's own prompts,
  unmodified, with the OSK drawn beneath.
- **Controls.** Trackpads + triggers on the OSK; `enter` submits; `back`
  (backspace) corrects; OSK `close` then B = go back a field.
- **Text entry.** ✅ **Yes**, three fields, all in text-entry mode.
- **Deviations.** `omarchy_prompt_identity` (full name, email — "hit return to
  skip", used only for git config) and `omarchy_prompt_hostname` are **overridden
  to set constants and prompt for nothing**: two fewer text-entry fields, and
  §6.1a already lists hostname as never-prompted. Hostname constant: `steamdeck`.
- **Failure states.** All three are upstream's and all three re-prompt in a loop
  **(READ)**: username fails `^[a-z_][a-z0-9_-]*[$]?$`; username is reserved (a
  51-name list); password blank; passwords differ. ⚠️ Each failure calls
  `notice()`, which calls `clear_logo`, which **clears the whole screen including
  the OSK** (§2.5). The keyboard must come back without the user doing anything.
- **Verified by.**
  - **[U]** the reserved/pattern predicates, sourced from upstream's own
    `setup-form.sh` constants rather than copied — a copy would pass while
    upstream's list changed. (Same discipline as `iso-payload-audit.sh` sharing
    its predicate by sourcing, `docs/tasks/T5-fork-plan.md` §5.4.)
  - **[V]** ⭐ **the blocking assertion:** drive only A presses at an empty
    username and assert the screen is still S3 after N presses — i.e. it genuinely
    blocks. §6.1a's "blocking screens must block" is untestable any other way.
  - **[V]** type a username with a capital, assert the rejection notice appears
    **and the OSK is still on screen afterwards** (the `clear_logo` collision).
  - **[V]** the artefact: `jq -r '.users[0].username' /root/user_credentials.json`
    equals what was typed, and `enc_password` is a `$6$` SHA-512 crypt string.
  - **[V]** the *negative* artefact: `user_credentials.json` contains **no**
    `encryption_password` key (upstream emits it only when `encrypt_installation`
    is true — READ).
  - **[H]** T6: a human sets a password with symbols and it is accepted at `sudo`
    on the installed device.

> **Rejected: the SteamOS-style PIN pad** (`docs/PLAN.md` §6.1a item 5, T2 §4
> option 3). It cannot serve S1's passphrase, so it would be a *second* text
> input to build and test, and the password it produces is also the `sudo`
> password. One keyboard, used everywhere.

### S4 — Disk

- **Purpose.** The destructive step. Never defaulted, explicit confirm.
- **On the console.** When exactly one eligible disk exists — the expected Deck
  case — the picker is skipped and the screen is upstream's overwrite confirm
  with our text: `Everything on <model> (<size>) will be erased. There is no
  recovery.` / `This install is not encrypted, so the Deck can start without
  anyone typing a passphrase.` / affirmative **`Yes, erase and install`**,
  negative **`No, go back`**. When more than one is eligible, `disk_form` runs
  first with the cursor on internal storage.
- **Controls.** Left/right on the d-pad between the two buttons (⧉ View also
  sends Tab in lizard mode), A to confirm, B to go back. The cursor starts on
  **`No`**.
- **Text entry.** None.
- **Failure states.** No eligible disk (every candidate is removable or is the
  boot medium) → a dead-end screen offering Reboot / Power off, never a shell.
  Declining returns to the picker, or re-asks — upstream's loop **(READ,
  `select_installation`)**.
- **Verified by.**
  - **[U]** the eligibility filter over `lsblk` fixtures: the install medium is
    excluded (upstream's `get_root_disk` walk), removable devices are excluded by
    `RM`, an NVMe internal is kept, an eMMC internal is kept, and an empty result
    is an error rather than an empty list.
  - **[V]** ⭐ **the blocking assertion:** with the cursor defaulting to `No`, a
    scripted "press A immediately" sequence must **not** produce an install. Then
    an explicit left-then-A must. Both, or the screen is not proven.
  - **[V]** the artefact: `.disk_config.device_modifications[0].device` is the
    intended disk and `.wipe` is `true`; `.disk_config` carries **no**
    `disk_encryption` block, and `/root/user_encrypt_installation.txt` is `false`.
  - **[V]** `install_mode_form` never ran — no `Free space install` string ever
    appeared on `/dev/vcs1` during the whole session.
  - **[H]** T6: the model and size shown match the Deck's actual drive.

### S5 — Summary

- **Purpose.** One recap before anything destructive runs. §6.1a item 8.
- **On the console.** `gum table` (upstream's recap style) with: Username,
  Password (masked), Hostname, Timezone, Wi-Fi (SSID or **`Not connected`**),
  Disk (device, model, size), Encryption (**`Off`**), Desktop (`Omarchy`), Boot
  (`Gaming Mode`). Then `gum confirm --affirmative "Install" --negative "Go back"`.
- **Controls.** A / B. Cursor starts on `Install` (nothing here is destructive
  that S4 did not already confirm).
- **Text entry.** None.
- **Failure states.** `Go back` returns to S3, matching upstream's existing
  `user_step` recap loop **(READ)**.
- **Verified by.**
  - **[U]** the table body is built from the same variables the JSON writer reads
    — assert on the *pair*, so a screen that shows one thing and writes another
    fails. This is the only screen whose bug would be invisible in both a
    screenshot and an artefact taken alone.
  - **[V]** every row shown on `/dev/vcs1` matches the corresponding `jq` value in
    `user_configuration.json` / `user_credentials.json`, field by field.
  - **[V]** `Encryption: Off` is present **and** the installed target later has no
    `/etc/crypttab` LUKS entry and no `cryptdevice=` on the cmdline
    (`docs/tasks/T5-fork-plan.md` §5.5's [V] row — same run, one assertion each end).

### S6 — Progress

- **Purpose.** Show the install running. Upstream owns it entirely
  (`omarchy-install-dashboard`), and it is good: a per-mille bar driven by the
  count of directories under `<target>/var/lib/pacman/local` against
  `expected-packages`, phase names, and a tips carousel **(READ)**.
- **On the console.** Unchanged, except the tips: 18 of them and **every one
  names a keyboard shortcut** — `Super + Space`, `Super + K`, "Super is the
  Windows or command key on your keyboard" **(READ)**. On a device with no
  keyboard that is 18 pieces of wrong advice, shown during the longest screen in
  the flow. Replace the array with Deck-relevant tips.
- **Controls.** None; nothing is asked.
- **Text entry.** None.
- **Failure states.** → S8.
- **Verified by.**
  - **[U]** the tips array contains no `Super`, and every tip is ≤ the content
    width (they are centred; a long one wraps and breaks the frame).
  - **[V]** the bar reaches ≥ 990 per-mille before the finish screen, and the
    phase names observed on `/dev/vcs1` match `build_phases`' list **in order** —
    which catches an inserted `configure_deck` phase (T5's S3) that never ran.
  - **[V]** `configure_deck`'s network-fetch outcome is recorded in
    `/var/log/omarchy-deck-install.json` **whichever way it went**
    (`docs/tasks/T5-fork-plan.md` §4.1).

### S7 — Completion and reboot

- **Purpose.** Say it worked, reboot.
- **On the console.** Upstream's `render_finish` — logo, `Installed Omarchy in
  <duration>`, a `tte` laser-etch effect, and `gum confirm --affirmative "Reboot
  Now" --negative ""` **(READ)**. Add one line: `Your Deck will start in Gaming
  Mode.`
- **Controls.** A. Works as-is: a single-button `gum confirm` takes Enter.
- **Text entry.** None.
- **Failure states.** `render_finish` failing falls back to a plain banner
  upstream already handles **(READ)**.
- **Verified by.**
  - **[V]** with `OMARCHY_UI_AUTO_REBOOT=no` the run stops on this screen and
    `/dev/vcs1` carries `Installed Omarchy in`. That is also the hook
    `test/vm/vm-install-test.sh`'s "KNOWN GAP" note asks for — the harness can
    then power off deterministically instead of waiting out its timeout.
  - **[V]** the Gaming Mode line is present, and the installed target has
    `Session=gamescope-wayland` (`docs/tasks/T5-fork-plan.md` §5.1). Say it and
    prove it in the same run.

### S8 — Failure  🔴 the screen §6.1a never specified

- **Purpose.** An install that fails on a device with no keyboard must still end
  somewhere a user can act. Today it does not.
- **What is wrong with upstream's, all (READ)**:
  1. **`Drop to shell` is the Esc fallback.** `choice=$(gum choose …) || choice="Drop
     to shell"`. Pressing B — the natural "get me out of here" — drops a
     controller-only handheld to `bash`.
  2. **`View full log` runs `less`**, which quits only on `q`/`Q`/`ZZ`: character
     keys nothing available *on this screen* can produce (§2.2 item 2).
  3. **`Upload log for support`** sends the install log to a third party. It is a
     menu choice, so it is opt-in — but it is the only telemetry surface in the
     flow and it should say what it uploads before it does.
- **On the console.** Upstream's failure frame (red banner, exit status, the
  state summary, the last 6–14 log lines, the Discord line) with the menu
  replaced by: **`Retry install` · `Show the log` · `Reboot` · `Power off`**, and
  the Esc/cancel fallback bound to **re-drawing the menu**, never to an action.
- **Controls.** D-pad + A. `Show the log` uses a pager that exits on Esc — `gum
  pager` is the candidate because gum widgets exit on Esc by contract
  **(INFERRED**; gum's own key table has not been read, and §6 must assert it
  rather than assume it**)**.
- **Text entry.** None.
- **Failure states.** The menu itself must never exit into a shell. If the pager
  is unavailable, fall back to `tail -n 200` plus "press A to continue" —
  upstream's own `prompt_enter`, which A satisfies.
- **Verified by.**
  - **[U]** the menu array contains no `Drop to shell`, and the cancel fallback
    maps to the menu, not to an action. Mutation-test this one: it is a
    single-string change that a naive test would not notice.
  - **[V]** ⭐ **force a failure** (a cidata config naming a nonexistent disk is
    the cheapest lever) and then, with the pad only: open the log, **leave it**,
    and reach `Power off`. Assert the guest powers off. **If the pager cannot be
    left, this test hangs — which is the correct outcome and exactly what it is
    for.**
  - **[V]** `/dev/vcs1` never contains a bare shell prompt at any point in a
    failed run.

---

## 5. When Wi-Fi fails

The install must still succeed. What is banned is silence
(`docs/tasks/T5-fork-plan.md` §4.1: *"The offline install must still succeed; it
is the silence that is banned, not the degradation."*).

| Condition | Detection | What S1 does |
|---|---|---|
| No `wlan0` | `ip -br link` has no wireless device | Skip S1 entirely, state *"No Wi-Fi hardware found — continuing offline"*, set the no-network marker. ⚠️ Do **not** block: this is also every QEMU run |
| `iwd` will not start | `systemctl start iwd` non-zero | Same, with the unit's status line shown. Never swallow |
| Scan returns nothing | empty `get-networks` after two tries | `Rescan` and `Skip` only. Say *"No networks found. Move closer, or skip."* |
| Wrong passphrase | `iwctl … connect` non-zero | Back to the passphrase prompt with *"That didn't work — check the password"*, passphrase cleared. **Bounded at 3 tries**, then back to the network list, so nobody is stuck in a loop they cannot escape |
| Associated, no DHCP | `wlan0` has no address after 20 s | Treat as failure, offer Retry / Pick another / Skip. This is the case a naive "did `connect` exit 0" check calls success |
| Captive portal | HTTP probe returns a redirect | State plainly that this network needs a browser and cannot be used during install; offer another network or Skip. **Do not attempt to render a portal** |
| User skips | the Skip row | Continue, and S5 shows `Wi-Fi: Not connected` |

**And the consequences, stated once, on S1's skip and again on S5:**

> Without a network the install still completes, but the audio DSP firmware and
> Steam are not downloaded. Speakers will sound thin and Gaming Mode will have no
> Steam until the Deck is connected. Wi-Fi can be set up from Desktop Mode
> afterwards.

That text is not decoration — it is `docs/tasks/T5-fork-plan.md` §4.1's
requirement (i) rendered.

Two hard requirements that are easy to miss:

1. **Credentials must reach the target as a NetworkManager connection.** The
   emitted JSON says `"network_config": {"type": "iso"}` **(READ)**, i.e.
   archinstall copies the live environment's network configuration to the target
   — and the live environment associates with **`iwd`**, while `CLAUDE.md`
   requires NetworkManager on the installed system. **Whether `type: iso`
   carries an `iwd` PSK across into a NetworkManager system is UNVERIFIED
   (open unknown U1)**, and if it does not, a user who joined Wi-Fi in the
   installer boots into Gaming Mode with no network and an undismissable Steam
   error — precisely the outcome §6.1a item 7 was promoted to prevent. Assume it
   does not: `configure_deck` writes
   `/etc/NetworkManager/system-connections/<ssid>.nmconnection` (mode 0600)
   itself, and the QEMU run asserts the file exists with the right SSID.
2. **A skipped or failed network must not stop `configure_deck`.** It records the
   outcome and leaves a first-boot retry unit that *tells the user*
   (`docs/tasks/T5-fork-plan.md` §4.1 requirements ii and iii).

---

## 6. How a screen proves itself, with no human in the room

### 6.1 Four tiers

| Tier | What it runs | Cost | What it can prove |
|---|---|---|---|
| **[U]** `test/unit/test-deck-form.sh` (+ `.py`) | `deck-form.sh`'s pure functions and predicates, sourced directly | seconds | list building, validation, defaults, sanitisation, the summary/JSON pairing |
| **[U-pty]** the same, driven through a pty with a scripted byte stream | one prompt at a time, real `gum`, no VM | seconds | back-navigation, blocking, the 0/1/130 status vocabulary |
| **[V]** `test/vm/vm-installer-screens-test.sh` (**new**) | the **real built ISO** in QEMU, driven by a scripted virtual Deck pad | minutes | the whole flow: input path, rendering, artefacts |
| **[V-full]** `test/vm/vm-install-test.sh` (exists) | an unattended `cidata` install, then disk assertions | ~30 min | that the artefacts the screens wrote install a correct system |

**[U-pty] is the tier that does not exist yet and buys the most.** Because §1's
wrap keeps upstream's status vocabulary, each screen is a bash function that can
be run alone with a fake terminal and a scripted key stream, and its *variables*
inspected. That is where blocking, back-navigation and validation belong —
QEMU should be testing the input path and the rendering, not the branching.

### 6.2 The primitives, and why each one

| # | Primitive | Why it is the honest one |
|---|---|---|
| A1 | **`/dev/vcs1` — the kernel's own copy of tty1** | Not a terminal emulator, not an escape-sequence reconstruction, not `tmux`. `tmux capture-pane` cannot answer "did the OSK and the TUI collide" because tmux owns the screen; a session-18 prototype that reconstructed the screen from a pty byte stream **mis-read a correct render twice** (`test/vm/vm-osk-tty-test.sh` header). Proven at tier [V] against `/dev/vcs2` |
| A2 | **The artefact files** — `/root/user_configuration.json`, `user_credentials.json`, `user_encrypt_installation.txt` | Every screen's answer, machine-readable, written by upstream's own code. `jq` assertions here cannot be satisfied by anything merely drawn |
| A3 | **A golden JSON fixture** | For one fixed scripted input sequence, the emitted config must equal a checked-in fixture modulo disk size and UUIDs. Catches our regressions **and** upstream schema drift, in one assertion |
| A4 | **What the prompt received** | `gum input` writes to a file. Asserting on that file — not on the screen — is what made T8's OSK claim real (`gum.received = hlH1`). It is the only assertion the OSK cannot fake |
| A5 | **Advance-and-vanish pairs** | Every screen transition asserts the next marker appears **and** the previous one is gone. T2 bug 2: a readiness gate matched the *echoed command line* before the widget started, so keys went into a shell prompt |
| A6 | **Environment invariants** | `/sys/class/graphics/fbcon/rotate == 1` (§2.5), console rows/cols recorded in the report, `python-evdev` present, `iwd` present, the three OSK modules present. Each is a silent, total failure if wrong |

### 6.3 The harness

`test/vm/vm-installer-screens-test.sh`, modelled directly on
`test/vm/vm-osk-tty-test.sh` (which already boots a guest, injects a payload,
scripts a Deck-shaped virtual pad, reads `/dev/vcs2`, and writes a report to a
raw virtio device the host reads after poweroff).

Differences that matter:

1. **It boots the built ISO**, not the substrate — so the thing under test is the
   product.
2. **The probe is injected, not shipped.** Via QEMU SMBIOS type-11 systemd
   credentials (`io.systemd.credential.binary:systemd.extra-unit.…`), the exact
   mechanism `vm-osk-tty-test.sh` uses. ⚠️ **(INFERRED** for archiso — it has
   never been tried against this ISO. **The first assertion in the suite must be
   a trivial "the injected unit ran at all" marker**, so a credential mechanism
   that silently does nothing fails loudly instead of making every later
   assertion vacuous.**)** A probe baked into the ISO is rejected: it would ship
   in the release image, and `tools/iso-payload-audit.sh` should be taught to
   refuse it.
3. **Plymouth must be dealt with.** `plymouth` is in the live package set and
   `plymouthd.conf` ships **(READ)**, and `test/vm/vm-install-test.sh`'s own
   header records that tty1's text "can be hidden behind plymouth's splash for
   the guest's whole lifetime". The probe must `plymouth quit` (or the harness
   must boot with `plymouth.enable=0`) **and assert that tty1 is the active
   console** before reading `/dev/vcs1`. Open unknown U2.
4. **The pad is the P17-shaped one** — both trackpads as absolute axes, `BTN_MODE`,
   both triggers — already written in `vm-osk-tty-test.sh` and worth extracting to
   `test/lib/`.

### 6.4 Five ways this harness can lie, and the guard for each

Each of these has already happened once in this project.

| # | The lie | Guard |
|---|---|---|
| 1 | **Asserting on a screen that has not changed yet.** A gate matches text that was already there | A5: advance-and-vanish pairs, markers anchored at line start |
| 2 | **A silent input path.** The pad enumerates and emits nothing; the mapper binds a dead node (§5.9 / R-8 is exactly this) | Assert the mapper's "bound" line **and** that a known keystroke arrived at the prompt (A4) before any screen assertion runs |
| 3 | **Passing vacuously.** The probe never ran, so nothing was checked | The report always prints its denominator; a missing report is a hard fail; the "unit ran" marker is assertion #1 |
| 4 | **A guard nobody has seen fail.** The blocking screens "block" because nothing ever tried to skip them | Every blocking screen gets a *negative* test that drives the skip and asserts it did not work (S3, S4) |
| 5 | **Testing the wrong world.** QEMU has no `hid_steam` and no Valve firmware, so a virtual pad always emits on the gamepad node — **QEMU can only ever exercise the `lizard_mode=N` half of §2.1** | State it in the harness header. The lizard-mode half is **[H]**-only, and §4's screens are therefore designed so lizard mode is the path that needs *no software of ours* — the half that cannot be tested is also the half with nothing of ours to break |

### 6.5 Mutation testing

The OSK suites are mutation-tested (60/60 caught, `docs/tasks/T8-onscreen-keyboard.md`).
`deck-form.sh`'s [U] suite must be too — its highest-value assertions are
single-string changes (S8's menu array, S4's default cursor, the encryption
constant) which a shallow test cannot distinguish from correct.
⚠️ Two traps recorded there apply verbatim: a mutation reported "SURVIVED" when
its anchor did not match and nothing was mutated, and a stale `__pycache__`
invalidated a run.

---

## 7. Where every change lands

| Seam | Path | Kind |
|---|---|---|
| The two hunks | `overlay/patches/configurator.patch` | patch P1 |
| `python-evdev` into the live env | `overlay/patches/build-iso.patch` (shared with T5's S1) | patch P2 |
| The screens | `overlay/configs/airootfs/usr/share/omarchy-iso/deck-form.sh` | additive |
| Mapper + OSK | `overlay/configs/airootfs/usr/local/bin/deck-input-mapper`, `…/usr/local/lib/deck-osk/{deck_osk_layout,deck_osk_tty}.py` | additive |
| Text-entry mode | `overlay/configs/airootfs/usr/local/bin/deck-installer-textmode` | additive |
| Dashboard tips + failure menu | `deck-form.sh` cannot reach them — the dashboard is a separate process. **Overlay the two functions** via a small `overlay/configs/airootfs/usr/local/bin/omarchy-install-dashboard` replacement, or a third patch | ⚠️ decide in T4a |

⚠️ **`setup-form.sh` must not be overlaid.** `build-iso.sh` copies it out of the
runtime package at line 187, *after* `cp -r /configs/*` at line 65, so an overlay
file at that path is silently overwritten **(READ)**. Function redefinition in
`deck-form.sh` is the only seam that survives.

**Two new build-time guards**, in the shape of `docs/tasks/T5-fork-plan.md` §6:

- **G1.** After the overlay is applied, assert `configurator` contains the
  `source …/deck-form.sh` line **and** that `deck-form.sh` redefines every
  function name it intends to (grep the names out of `deck-form.sh`, assert each
  exists in `configurator` or the vendored `setup-form.sh`). An override that
  misspells a name is a screen that silently reverts to upstream's — the exact
  failure class this project keeps hitting.
- **G2.** Assert `python-evdev`, `gum`, `jq`, `iwd` and the three OSK modules are
  present in the assembled `airootfs`. `resolve_expected_packages`' existing
  "pacman -S --print aborts if any target is missing" check gives the package half
  for free **(READ, `build-iso.sh`)**.

---

## 8. Open unknowns, ranked by what they cost to discover late

| # | Unknown | Cost if wrong |
|---|---|---|
| **U1** 🔴 | **Does a Wi-Fi association made in the live ISO survive into the installed system?** `network_config: {"type": "iso"}` with `iwd` in the live env and NetworkManager on the target. Never tested | The user joins Wi-Fi during setup and the Deck boots offline — Gaming Mode's undismissable Steam error, on the exact path §6.1a item 7 exists to prevent. **Mitigate by writing the connection ourselves (§5), not by hoping** |
| **U2** | Does the SMBIOS-credential probe injection work against an **archiso** ISO, and does plymouth hide tty1 from `/dev/vcs1`? | The entire [V] tier is unavailable, and T4 falls back to hardware for things QEMU should catch. **Test this first, before writing any screen** |
| **U3** | The Deck's live console geometry. Never recorded, in three hardware sessions | The OSK is 73 columns and the logo ~81. If the console is 80×25, upstream's frame already wraps and the keyboard eats half the screen |
| **U4** | Does the mapper repaint the OSK after `clear_logo` wipes the screen (§2.5)? | Every validation failure in S1/S3 leaves the user typing blind |
| **U5** | Does `gum pager` (or any available pager) exit on Esc? | S8's "Show the log" is a trap with no exit |
| **U6** | Does `/sys/module/hid_steam/parameters/lizard_mode` exist in the **live ISO** (`linux-t2` kernel)? All lizard-mode measurements were on the installed Neptune system | Text-entry mode cannot be entered; S1 and S3 have no keyboard; T4 has no product |

**U6 is the one that most deserves suspicion.** Everything in §2.1 was measured
on the *installed* system with Valve's kernel. `docs/PROGRESS.md` §5.9's
live-ISO half (R-8) proved lizard mode is *active* there, but nobody has read the
module parameter under `linux-t2`. It is a one-line check on the next Deck
session and it gates the whole design.

---

## 9. Done when

- [ ] U2 and U6 answered — before any screen is written
- [ ] `deck-form.sh` exists with all six screens, ≤ 2 patch files total
- [ ] [U] and [U-pty] suites green and **mutation-tested**
- [ ] `vm-installer-screens-test.sh` drives S0→S5 with a virtual pad only,
      asserting `/dev/vcs1` **and** the artefact JSON at every step
- [ ] The two blocking screens each have a *negative* test that fails when the
      block is removed
- [ ] A Wi-Fi passphrase with mixed case, a digit and a symbol reaches `gum`
      through the trackpads, asserted from what `gum` wrote
- [ ] S8 reaches `Power off` from a forced failure, with the pad only, no shell
- [ ] `lizard_mode` is `Y` and no mapper is running at every point outside a
      text prompt — including after a killed mapper
- [ ] **[H]** a human joins their own Wi-Fi and creates an account on the Deck
      with no keyboard attached

---

## 10. What this session read, inferred, and did not do

**Read from source this session** (`gh api` at the T5 pins, or a file in this
repo): `configs/airootfs/root/configurator` (all 1196 lines),
`configs/airootfs/root/.automated_script.sh`,
`configs/airootfs/usr/local/bin/omarchy-install-dashboard`,
`…/omarchy-cidata-load`, `…/omarchy-iso-install`, `builder/build-iso.sh`,
`orchestrator/{main,ui,phases,context,keyboard}.py`,
`basecamp/omarchy@6d7826d install/provisioning/setup-form.sh`; and in this repo
`src/deck_osk_tty.py`, `src/deck_osk_layout.py` (layout tables),
`test/vm/vm-osk-tty-test.sh`, `test/vm/vm-install-test.sh`, plus the cited
sections of `PLAN.md`, `PROGRESS.md`, `ROADMAP.md`, `START-HERE.md`,
`T2-gamepad-spike.md`, `T5-fork-plan.md`, `T8-onscreen-keyboard.md`,
`P15-live-iso-recon.md`, `P17-input-and-osk.md`, `P18-osk-hardware-pass.md`.

**Inferred, not run:** that redefining upstream's prompt functions after
`source` takes effect (standard bash, not tested against this file); that
`hid_steam`'s parameter is absent under QEMU; that SMBIOS credential injection
works on archiso; that `gum pager` exits on Esc; that `network_config: iso` does
not carry an `iwd` PSK into NetworkManager; every "verified by" row in §4, all of
which are specifications.

**Not done, per this task's constraints:** no installer code written, no ISO
built, no Deck touched, no `ssh`, and no edits to `src/deck-session.sh`,
`test/unit/test-deck-session*.sh` or `docs/findings/T9-lock-service-mitigation.md`.
