# P33 — the post-hardware fix round

**Status:** planned, not started. Written 2026-08-15 (session 28) after the first
successful hardware install from our own ISO.

**Goal:** fix the seven defects the hardware run exposed, cut 350 MiB of dead
weight, rebuild the ISO, reflash, and reinstall.

**Every agent on this task runs Opus 4.8.** Operator requirement, not a
suggestion.

---

## 0. Read this first (all agents)

Source of truth for what was measured, and *why* a value is what it is:

- `docs/PROGRESS.md` **§5.32–§5.37** — the hardware findings this round fixes.
- `docs/PROGRESS.md` **§7** — 55+ hard-won facts. **Several were corrected by
  later measurement. Trust §7 over memory, and re-check before building on any
  recorded value.**
- `CLAUDE.md` — hard constraints. The ones that bite in this round:
  - **Never silently swallow a failure.** `set -euo pipefail` or equivalent.
    This project exists because upstream tooling fails silently. *This rule was
    violated during session 28 itself* — see §5.36 — so it is not theoretical.
  - **Idempotent, re-runnable scripts.**
  - **OLED is the only verified hardware.** Gate LCD paths on model detection;
    never claim LCD support anywhere.
  - **No keyboard or terminal for a standard install.**
  - Don't auto-install an AUR helper. Limine only.

### Rules of engagement

1. **Stay inside your file list.** Another agent owns every other file. If you
   believe you need a file you do not own, **stop and report it** rather than
   editing it.
2. **Never `git add -A` or bare `git commit`.** Parallel agents share one git
   index — a bare commit sweeps up other agents' staged work (`docs/PROGRESS.md`
   §7). Commit **only** as `git commit -- <your explicit paths>`.
3. **Do not edit `docs/PROGRESS.md`.** The coordinator owns it. Report your
   findings; they get written up centrally. This avoids six agents fighting over
   one file.
4. **Measure, don't infer.** Session 28 produced three wrong diagnoses from
   plausible inference (trackpad haptics "proving" the OS booted; a "missing
   UKI"; a bl0/bl1 whitelist bug). Each died on contact with a measurement. If
   you cannot measure it, say "unverified" in your report — that is a complete
   and acceptable answer.
5. **A verified-absent capability is a result.** If your defect turns out not to
   reproduce, report that with the evidence. `docs/findings/P32-tty-path-anomaly.md`
   is the precedent: an agent disproved its own suspect rather than guessing.

### Hardware access

The Deck is installed, running, and reachable: **`ssh steamdeck`**
(`deck@192.168.100.25`, key auth). It runs
`6.11.11-valve29-1-neptune-611-g2dcfaf4df7ac` with Arch firmware only.

- **Read freely.** Configs, `hyprctl`, journals, `pacman -Q` — all cheap and all
  ground truth.
- **`sudo` is NOT NOPASSWD.** You cannot run privileged commands; there is no
  human at that keyboard for you. Design around it.
- **ufw rate-limits port 22** (`limit 22/tcp`, ~6 connections/30s). **Batch your
  remote commands into one `ssh` invocation.** Repeated small connections get
  dropped and look like a network fault.
- ⚠️ **Omarchy 4.0 configures Hyprland in LUA** (`hyprland.lua`, `input.lua`,
  `monitors.lua`, `bindings.lua`, via `hl.config({...})`), **not** the classic
  `.conf` syntax. Read the real syntax off the Deck. Do not assume.

---

## 1. Decisions already made — do not relitigate

| decision | choice | why |
|---|---|---|
| OSK legibility | bigger console font **and** an OSK that adapts to whatever width it is given | the whole installer is unreadable at 8×16 on a 7" panel, not just the keyboard |
| splash location | **in the session, not the boot path** | a splash bug must degrade to today's black screen, never to a broken boot |
| SSH in the installer | **dropped from scope** | operator, 2026-08-15 |
| Valve firmware | **cut it** | the Deck runs Neptune on Arch firmware with Wi-Fi, panel, audio and gamescope all working — the exact test §5.33b named |

---

## 2. Agents

Six agents, disjoint file ownership, all parallel. **No agent depends on another
agent's output.**

---

### Agent A — installer form correctness

**Owns:** `iso/overlay/configs/airootfs/usr/share/omarchy-iso/deck-form.sh`,
`test/unit/test-deck-form.sh`, `test/vm/vm-install-controller-test.sh`

#### A1 🔴 the reserved-username check is dead (§5.34 D1)

`deck-form.sh:749` declares `DECK_RESERVED_USERNAMES_VAR=RESERVED_USERNAMES` and
`deck_form_load_reserved_usernames` calls `declare -p` on it expecting a bash
**array**. Upstream's vendored `setup-form.sh:82` defines
`OMARCHY_RESERVED_USERNAMES` — **different name, and a regex STRING**. So
`deck_form_username_reserved` returns 1 for every input.

Worse: our override replaces `omarchy_prompt_username` wholesale, so upstream's
own check (its line 111, `[[ "$username" =~ $OMARCHY_RESERVED_USERNAMES ]]`)
never runs either. **Both checks are gone and `root` is an accepted username.**

The comment at `deck-form.sh:739` says the name was
*"(INFERRED, NOT READ this session)"* and asks for verification before shipping.
It shipped unverified. **Read the vendored file, do not infer again:**
`~/.cache/omarchy-deck/p32-build/runtime-src/install/provisioning/setup-form.sh`

Requirements:
- Consume the **regex string**, not an array. Keep the command-substitution
  subshell — `deck-form.sh:783`'s comment documents a real, measured bug where
  sourcing upstream into the live shell silently reinstalled upstream's prompt
  bodies over our overrides. **Do not undo that.**
- Keep the loud-degradation path. If the variable is missing or renamed
  upstream, warn and continue — that behaviour is what surfaced this bug.
- Delete or rewrite the now-false "INFERRED" comment block. **A comment
  asserting something untrue is the same defect class as the code** (§5.33b
  found two more of these).

#### A2 🐞 the 5 s bind deadline, and a warning that is never retracted (§5.34 D2)

`DECK_OSK_BIND_DEADLINE=5` (`deck-form.sh:229`). On hardware the mapper binds
**later than 5 s**, and `deck_form_text_prompt` (`:420-430`) does not kill the
mapper when the deadline expires — so the OSK appears anyway and a **false**
*"did not report bound within 5s -- this prompt runs WITHOUT it"* sits on screen
beside a working keyboard. Photographed 2026-08-15.

**QEMU structurally cannot catch this**: with no gamepad the bind never happens,
so the message is always true there. Any test you add must not depend on a
gamepad existing.

Requirements:
- Raise the deadline. **Measure the real bind time on the Deck** rather than
  picking a number — the mapper's bound marker is
  `deck-input-mapper: bound` (`:203`).
- **The retraction matters as much as the number.** Decide and implement one of:
  keep waiting in the background and clear/replace the warning when the marker
  arrives, or kill the mapper on expiry so the warning stays true. Silently
  leaving a false statement on screen is not acceptable under this project's
  own rules.
- `DECK_FORM_OSK_UP` (`:447`) is the global that tells the prompt whether the OSK
  came up. Keep it accurate under whatever you choose.

#### A3 console font pinning

`deck_form_pin_console_keymap` (`deck-form.sh:414`) already pins the keymap at
the point of use, for reasons its own comment explains. **Pin the console font
in the same place, the same way.**

- **Check `kbd`'s bundled fonts first** — it is already in base and ships
  `latarcyrheb-sun32` (16×32) in `/usr/share/kbd/consolefonts/`. If that works,
  **no new package is needed.** Only if it does not, add one to
  `iso/upstream/builder/build-iso.sh`'s `arch_packages` — and **report that you
  are doing so**, because that file is shared.
- Never fatal. A prompt with a small font beats no prompt.
- ⚠️ **CORRECTED 2026-08-15 (P33/B): this arithmetic was wrong by an axis.**
  It read the framebuffer's 800 px side as the console's horizontal one. With
  `fbcon=rotate:1` the horizontal axis is the **1280 px** side, and
  `docs/PROGRESS.md` §7 *measured* the live ISO's console as **`50 160` — 50
  rows × 160 columns** (160 × 8 = 1280). So the real pair is **160 columns at
  8×16 and 80 at 16×32**, not 100 and 50.
  **This makes D3 worse than recorded and the fix better:** the OSK has been
  drawing its fixed 80 columns on a **160-column console — half the screen
  width** — which is most of "the keyboard is tiny", and the adaptive grid
  corrects it with no font change at all. At 16×32 the console is 80 columns and
  the grid renders cell 5 = exactly full width, so the font pin and the adaptive
  grid compose rather than fight.
- The Deck's console is `800x1280` with `fbcon=rotate:1`. **Agent B is making
  the OSK adapt to whatever
  column count exists, so you do not need to coordinate a number with them.**

#### A4 re-baseline the QEMU harness timings

`docs/PROGRESS.md` §5.33a: S0's `Username>` assertion fails because the OSK
warning now takes 5 s, pushing the prompt past the harness's screenshot. **The
harness timings predate the mapper ever being in the image.** Rebase them on
whatever deadline A2 lands on.

**Acceptance:** `test/unit/test-deck-form.sh` green; a test proving a reserved
name (`root`) is rejected; a test proving the bound-warning is retracted or the
mapper killed; `bash -n` and `shellcheck` clean; the controller VM suite reaching
its username assertion.

---

### Agent B — on-screen keyboard: size and flicker

**Owns:** `src/deck_osk_tty.py`, its unit tests, and the staged copy under
`iso/overlay/` if one exists (check `iso/bin/build` step 5c for how OSK modules
are staged — **do not edit `iso/bin/build`**, report if you need to).

#### B1 🐞 the keyboard is far too small (§5.34 D3)

`KEY_CELL = 5` (`:138`) × `Layer.width` 16 = a fixed **80 columns**. Agent A is
pinning a larger console font, which *reduces* the column count — so a hardcoded
80 will wrap, and `rows_on_screen`'s own comment (`:338`) explains why wrapping
destroys the layout.

**Make the grid adapt to the console width it is actually given.** Derive the
cell width from the real column count instead of the constant. Constraints you
must respect, all documented in the file:

- `cell_text` (`:151`) draws highlighted as `[` + `label.center(w-2)` + `]` and
  plain as `label.center(w)`. **Both must stay the same width** or keys shift as
  the cursor moves. At `w=3` that is `[q]` — which fits, but **verify against
  `display_label`'s budget check (`:247`) for every key, including the multi-cell
  ones** (`ONCE`/`LOCK` at `:182` are deliberately equal-length).
- `write_at`'s `console_cols` guard (`:379-440`) must keep working. It exists to
  refuse to draw a row that would wrap. Do not weaken it to make a wide grid fit.
- The 80-column figure is a **measurement of one console**, not a law
  (`:124`) — read that comment before treating any number as fixed.

#### B2 🐞 flicker (§5.34 D4)

`write_at` rewrites every row with `\x1b[K` between `\x1b[s`/`\x1b[u`
(`:444-447`) on each repaint. **Measure the repaint rate before changing
anything** — the file's `rows_on_screen` comment says a single pad sample
repaints the keyboard, so the trigger may be input-rate, not a timer.

Candidate directions (pick on evidence, not on this list's order): repaint only
changed cells; coalesce repaints triggered within one input burst; write the
whole frame in a single `write()` rather than per-row.

**Acceptance:** unit tests green including new cases at the narrower cell width;
a test proving no row exceeds `console_cols` at both 100 and 50 columns; a
measured before/after repaint count for the flicker fix. If flicker cannot be
reproduced off-hardware, **say so** and propose the on-Deck measurement instead
of guessing.

---

### Agent C — the close-window chord

**Owns:** `src/deck-input-mapper.py` and its unit tests.

#### C1 🆕 STEAM+Y closes the focused window (§5.37 D6)

Operator request: a controller equivalent of Omarchy's `SUPER+W`.

`BTN_MODE` (STEAM) is `OSK_CHORD_HOLD` (`:365`) with `BTN_NORTH` (physical X) as
`OSK_CHORD_PRESS` (`:366`). **`BTN_MODE`+`BTN_WEST` (Y) is unclaimed** — verify
that against the current `BUTTON_MAP` (`:190`) and the trackpad/QAM bindings
(`:358`, `:417`) before wiring it.

**Implement it as a direct exec of Hyprland's window-close dispatcher, NOT as a
synthesised `SUPER+W` chord.** This is the file's own established precedent at
`:373`, taken deliberately: a synthesised chord silently does nothing if upstream
edits the binding, with nothing to read anywhere. The apps-menu binding at `:381`
is the working template.

⚠️ **CORRECTION, 2026-08-15.** This section originally named the bareword
dispatcher from classic Hyprland. **That would have shipped a dead button**, and
the brief was wrong, not the agent that refused it. Measured on the Deck
(Hyprland 0.56.2 under `omarchy-dev 4.0.0.r1744.gf002044-1`): `hyprctl dispatch`
now evaluates a **Lua expression**, a bareword resolves to `nil`, and Hyprland's
own error names the expected form. Omarchy's real binding is one line of
`default/hypr/bindings/tiling.lua`:

    o.bind("SUPER + W", "Close window", hl.dsp.window.close())

and the old bareword appears **nowhere** under `/usr/share/omarchy/`. Use the
same dispatcher `SUPER+W` itself invokes. `test/unit/test-hyprctl-syntax.sh`
guards this repo-wide — it went red on *this document* while the wrong form was
in it. **Read `docs/PROGRESS.md` §5.30b and that guard before writing any
`hyprctl dispatch` anywhere.**
- Update the button-map docstring at the top of the file (`:17-35`). It is the
  only place a reader learns the bindings.
- The chord must not fire the OSK toggle, and releasing STEAM alone must still
  do what it does today (`:35`, the apps menu on a chord-less tap).

**Acceptance:** unit tests green, including one proving STEAM+Y does not trigger
the OSK and STEAM-alone still opens the apps menu.

---

### Agent D — touch input on the target

**Owns:** `iso/overlay/configs/airootfs/usr/share/omarchy-iso/orchestrator/deck_input.py`
and its unit tests.

#### D1 🐞 touch does nothing in Desktop Mode (§5.37 D5)

**Not a driver problem.** `hyprctl devices` on the Deck shows the OLED's
controller present and bound as **`fts3528:00-2808:1015`**.

The cause: `eDP-1` is `800x1280@90.004`, **`transform: 3`**, `scale: 1.25`, and
**`~/.config/hypr/` contains no `device` block at all**. Nothing binds the touch
device to the output, so its coordinates are never rotated with the panel and
every tap lands 270° from the finger.

Requirements:
- Bind the touch device to `eDP-1` so Hyprland applies the transform.
- ⚠️ **Read the Lua spelling of a device block off the Deck.** Omarchy 4.0 is
  Lua-configured. `~/.config/hypr/input.lua` is the local override file and is
  currently all commented-out defaults — read it, and read Omarchy's own
  defaults under `/usr/share/omarchy/default/hypr/`.
- ⚠️ **`fts3528:00-2808:1015` is the OLED's controller.** The LCD Deck has
  different touch hardware. `CLAUDE.md` forbids claiming untested LCD support:
  **gate on detection or match generically, and never assert the LCD works.**
- `deck_input.py` already writes Hyprland input config — follow its existing
  marker/preservation discipline. `deck_rotation.py` (`:216`, `:345`) documents
  the "everything outside the markers is preserved byte for byte" rule; do not
  invent a second convention.
- Idempotent: re-running must not append a second block.

**Acceptance:** unit tests green including an idempotency test and a
preserve-everything-outside-the-markers test. **Hardware verification is the real
acceptance and it is the operator's to run** — state plainly in your report that
it is unverified until a tap lands where the finger is.

---

### Agent E — the session layer (largest agent)

**Owns:** `src/deck-session.sh`,
`iso/overlay/configs/airootfs/usr/share/omarchy-iso/orchestrator/deck_session_bake.py`,
any new asset files, and their unit tests.

⚠️ **This agent owns four defects because they all live in one 5,000-line file.**
Parallel edits to `deck-session.sh` would conflict, so they are deliberately not
split. Work them in the order below; E3 and E4 are the higher-value pair.

#### E3 🔴 the power button does nothing — the T13 stage is never invoked (§5.38)

Measured on the Deck 2026-08-15. `systemd-analyze cat-config` resolves
`HandlePowerKey=ignore`, from `/etc/systemd/logind.conf.d/10-ignore-power-button.conf`,
which `pacman -Qo` says is owned by **`omarchy-settings-dev`**. logind logs
`Power key pressed short` on every press — **the key is detected and delivered,
and logind is told to ignore it.** Suspend is available (`/sys/power/state` =
`freeze mem disk`, `mem_sleep` = `s2idle [deep]`).

`src/deck-session.sh` contains an elaborate T13 power-button stage — drop-in
sort-order verification (`:4985-5006`), a udev untagging premise check
(`:4982`), `HandlePowerKeyLongPress` set explicitly (`:898`), a double-suspend
guard (`:5133`). **None of it ran.** The install record
(`/var/log/omarchy-deck-install.json`) lists thirteen bake stages —
`greeter-rotation, input-mapper, lizard-mode, menu-row, osk-kb-layout,
preconditions, priv-write-helper, return-icon, sddm-resilience, session-select,
steam-hook, timezone-helper, update-stub` — and **there is no power-button stage
among them.** `/etc/udev/rules.d/` on the target is empty and no drop-in of ours
exists in `/etc/systemd/logind.conf.d/`.

**This is the P32 defect family again: written, unit-tested, documented, never
wired.** Same shape as Steam, the mapper, `steamos-session-select` and the
reserved-username list.

Requirements:
- Add the power-button stage to the bake's stage registry so it actually runs.
- **Our drop-in must sort AFTER `10-ignore-power-button.conf`.** The file already
  verifies this (`:4996`) and explains why: systemd merges every
  `logind.conf.d` directory into one basename-sorted sequence and the last
  assignment wins. A `10-`-or-earlier name means the file is on disk, the
  setting reads correctly, and the button still does nothing.
- Read `docs/PROGRESS.md` §5.24 (the power button locking this Deck,
  unanswerably) and the T13/T14 findings **before** choosing a value.
  `HandlePowerKey` defaults to `poweroff`, not `suspend` (`:840`).
- `steamos-powerbuttond` requires `HandlePowerKey=ignore` and conflicts with
  T13's `suspend` (T14). T14's answer was **ship nothing extra** — do not
  reintroduce powerbuttond without re-deciding that explicitly.

#### E4 🔴 backlight discovery runs against the WRONG KERNEL (§5.38)

`stage-priv-write-helper` **failed during the install** and the record says why:

> `backlight: /sys/class/backlight/amdgpu_bl1/brightness (discovered, not assumed)`
> … `steamos-priv-write: '/sys/class/backlight/amdgpu_bl1/brightness' is not writable even as root`

**On the booted system that device does not exist.** The only node is
`amdgpu_bl0` (`cur=39638`, `max=65535`, and writable by root). The bake runs in a
chroot on the **live ISO**, whose kernel is stock archiso — **not Neptune** — and
the two kernels enumerate the backlight differently.

So the discovery is not merely unlucky: **discovering hardware in the
installer's kernel and baking the result into a target that boots a different
kernel is unsound in general.** Even had the write succeeded it would have
recorded the wrong node. Note this also **corrects an earlier diagnosis in this
project's own records** — the node is not hardcoded, it is discovered, in the
wrong place.

Requirements:
- Move backlight resolution to **first boot on the target**, or make it
  late-binding so the path is resolved when the real kernel is running. Do not
  simply retry the same chroot-time write.
- Keep `find_backlight()`'s three-outcome contract (`:2132`) and the
  device-agnostic whitelist (`:2376`). **The whitelist is not the bug** — that
  was measured and disproved in commit `0becd4b`; do not re-diagnose it.
- **Audit the other twelve stages for the same class of error.** Any stage that
  reads hardware state through the installer's kernel and writes a conclusion to
  the target has this bug. Report what you find even if you do not fix it.
- **Acceptance is a `steamos-priv-write` *accept* line in the journal on
  hardware**, not a slider that appears to move. §5.33a records that distinction
  because an apparent-motion check already fooled this project once.

#### E1 🆕 "don't power off" during Steam's 2m03s self-update (§5.35)

Measured from Steam's own `bootstrap_log.txt` on the Deck:

| time | event |
|---|---|
| 15:08:15 | Steam launches (`-gamepadui`), `Downloading Update...` |
| 15:08:15 | `Error: Steam needs to be online to update.` |
| 15:08:16 | relaunches, retries, **succeeds** |
| 15:09:51 | `Extracting package...` |
| 15:10:14 | `Update complete, launching...` |
| 15:10:18 | new client starts |

**The boot chain is not slow** — `systemd-analyze` says 39.168 s total with
`plymouth-quit` at **659 ms**. Nothing can paint in that window today: the
cmdline is `quiet splash loglevel=0 systemd.show_status=false
vt.global_cursor_default=0`, and Plymouth has been gone three orders of magnitude
before the window opens.

**Decision already made: the splash lives in the SESSION, not the boot path.** A
splash bug must degrade to today's black screen, never to a broken boot. Do not
propose holding `plymouth-quit`.

Requirements:
- Show a fullscreen message until Steam's first window maps, then exit. `imv` is
  already present on the target — **verify that before depending on it**, and
  check what else the session already has rather than adding a dependency.
- **Wording is the point.** The operator asked for *"something to tell users like
  don't turn me off. steam is unpacking."* Say that, in those terms.
- First-boot-only in effect: later boots reach Gaming Mode in ~39 s, so the
  splash must not add a delay to every subsequent boot.
- **It must not be able to outlive Steam.** A splash that fails to exit is a
  permanently black-with-text screen — strictly worse than the bug. Bound it.

#### E2 🐞 the update error is a race, not a broken network (§5.35)

The first update attempt fails because Steam starts before NetworkManager has
connectivity; the retry one second later succeeds. Order Steam's start after
connectivity so the error modal never appears.

⚠️ **Do not wait on `network-online.target` naively.** `deck_wifi.py`'s own
comment (its `Wants=network.target`, not `network-online.target`) explains the
trap: on a Deck with no network that delays boot by the timeout, on exactly the
machines least able to afford it. Bound the wait and proceed regardless.

**Acceptance:** unit tests green; a test proving the splash exits; a test proving
the network wait is bounded and non-fatal. Hardware verification is the
operator's.

---

### Agent F — cut Valve's firmware, and prove the size

**Owns:** `iso/overlay/configs/deck/deck-mirror.packages`, `test/unit/test-deck-pkgs.py`

#### F1 cut `linux-firmware-neptune` (§5.33b)

`docs/findings/P32-neptune-firmware-placement.md` swept all 6,150 modules of
`linux-neptune-611` for `firmware=` declarations (1,973 distinct files) and found
only 32 Valve-only files, every one for hardware the Deck does not have.
**§5.33b held the cut pending hardware. Hardware has now answered:** the Deck
runs Neptune with Arch's firmware alone (`linux-firmware*` 20260810, and
`pacman -Q linux-firmware-neptune` returns *not found*) with Wi-Fi, panel, audio
and gamescope all working.

- Remove the entry and its now-obsolete comment block from
  `deck-mirror.packages`.
- **Check whether `linux-neptune-611-headers` should go too.** Its comment says
  it is the first line to cut if space is needed and justifies itself against the
  firmware sitting beside it — that justification changes once the firmware is
  gone. **Report a recommendation; do not cut it unilaterally.**
- Verify guard **6.8** (consumer-less package list) still passes and still means
  what it claims. §5.33b found a third, unstated limitation: it cannot flag prose
  that asserts a consumer no line names.

**Acceptance:** `test/unit/test-deck-pkgs.py` green; guard 6.8 green; a stated
predicted ISO size (6.383 GiB → ~6.04 GiB expected) to check the build against.

---

## 3. After the agents — coordinator sequence

Strictly ordered. **Do not start a build before the cheap tiers are green** —
`CLAUDE.md`'s testing ladder exists because a build is ~40 min and a hardware
reinstall is far more.

1. **Review every diff personally.** Do not trust agent self-reports
   (`docs/PROGRESS.md` §7 and session 28's own record: an agent duplicated
   existing work, another collided on a global name, a third proposed restoring a
   package that kills installs). Re-check claims against the files.
2. **Full unit suites.** Baseline at merge was **21/22 sh** (the red is the
   pre-existing heredoc classifier) and **15/15 py**. A new red is a stop.
3. **`shellcheck` + `bash -n`** across changed shell.
4. **QEMU install suites, both:** offline (`-nic none`, default) and networked
   (`VM_NIC=user`). Baseline 34/37 and 36/37 with `install.outcome=success`.
   The 3 offline failures are Steam-fetched-online by design.
5. **Build the ISO** in a **fresh scratch dir** under `~/.cache/omarchy-deck/`.
   ⚠️ **Do not reuse `~/.cache/omarchy-deck/iso-build`** — three corrupted-cache
   build failures have come out of it (§5.33a). ⚠️ The scratchpad `/tmp` is a
   **16 GB tmpfs**; ISOs and squashfs extracts must live on `/home`.
6. **All build guards green**: 6.1, 6.3, 6.4a, 6.4b, 6.5a, 6.5b, 6.6, 6.7, 6.8.
7. **Check the size against Agent F's prediction.** A miss means something else
   changed and needs explaining before shipping.
8. **Flash to the Ventoy stick, then verify the checksum by reading it back off
   the stick** — not by trusting the write. Delete the previous ISO only after
   confirming its backup exists.
9. **Operator reinstalls.**

### What only the Deck can answer

State these as unverified in every report until the operator runs them:

- the OSK is legible **and** does not flicker on a real panel
- a tap lands where the finger is, in Desktop Mode
- STEAM+Y closes the focused window and does not fire the OSK
- the splash appears, says the right thing, and **goes away**
- no "Steam needs to be online to update" modal on first boot
- Wi-Fi, audio and gamescope still work **without** Valve's firmware — this is
  now a regression check, not a discovery

### Known-cosmetic, explicitly out of scope

- **Ventoy's menu is rotated 90°.** GRUB has no rotation support; recorded and
  dropped (§5.33a era). Not in this round.
