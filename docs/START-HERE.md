# START HERE — Omarchy Deck build session

**You are Claude Code. This is your entry point. Read it fully, then begin
work without waiting for further instruction.**

> ## Where things stand (updated 2026-08-11, session 19; body below is sessions 17–18)
>
> ### 🆕 UPSTREAM MOVED — there is now a PHASE 2.9, before phase 3
>
> **Operator direction, 2026-08-11: Omarchy shipped a 4.0 beta 2, and
> everything we own gets rebased onto it before the release run.** Spec:
> `docs/tasks/T9-beta2-rebase.md`. Measured delta:
> `docs/findings/T9-beta2-delta.md`. Ordering: `docs/ROADMAP.md` phase 2.9
> (P2.9a–P2.9g). Decision record: `docs/PROGRESS.md` §5.22.
>
> 🔥 **RESOLVED THE SAME DAY, AND THE PREMISE WAS WRONG IN OUR FAVOUR: WE WERE
> ALREADY ON BETA 2.** Both ISOs were unpacked and their manifests diffed
> (`docs/findings/T9-iso-comparison.md`). Upstream's
> `https://iso.omarchy.org/omarchy-quattro-beta2.iso` (unlisted, **no published
> checksum**) and our 2026-08-10 build carry the **same
> `omarchy-dev 4.0.0.r1617.g6d7826d-1`**, the same `basecamp/omarchy` commit
> **`6d7826d`**, the same **`edge`** channel, the same builder **`a12bfea`** —
> 1244 packages each, **none exclusive to either**, differing only in 7 stock
> Arch rebuilds **that ours carries the newer of**. The Deck was installed from
> our ISO, so it is on `6d7826d` too — **confirm with one `omarchy-version`**
> when it is next powered on.
>
> **P2.9a ✅ P2.9b ✅ P2.9c 🟡 (rebuild skipped, with cause).** Both facts that
> were measured *from an image* survived re-confirmation: no Wayland compositor
> in the live environment (stronger — **no `libwayland-*.so` at all**) and the
> LUKS2 installer default (§5.12).
>
> 🔴 **What the block actually bought: the delta AHEAD of us.** `6d7826d` →
> `quattro` HEAD is 36 commits, classified in
> `docs/findings/T9-delta-classification.md` — **1 BREAKS US, 27 RE-VERIFY, 37
> NO IMPACT.** The BREAKS US is `shell/plugins/lock/Service.qml`: a new
> stranded-lock recovery path calls `beginLock()` **without reading
> `idle.lock`**, so our idle neutering stops guaranteeing this handheld can
> never face an unanswerable password prompt — and `ext-session-lock` renders
> **above** our OSK's layer surface, so keystrokes would land where nobody can
> see them. **That is the argument for staying pinned at beta 2 and not
> tracking edge.** It arrives with stable, so P3.6 must confront it.
>
> ⚠️ Also ahead of us: `default/hypr/bindings/utilities.lua` now globally binds
> RETURN, TAB and **all four arrows** — 6 of the 10 keys the mapper emits, up
> from 1. And `omarchy-system-factory-reset` **deleted its degraded path**: a
> machine with no `@factory` snapshot is now refused, which P3.1 assumes it can
> do.
>
> ⚠️ **Quattro may ship stable THIS WEEK** (the thread that surfaced beta 2 says
> so). If it does, phase 2.9 and P3.6 are one rebase, not two. Decide before
> spending an operator session.
>
> ⛔ **reddit.com is blocked by policy** — for WebFetch *and* the in-app browser.
> The r/omarchy thread was never read; everything above came from probing
> `iso.omarchy.org` directly. Don't burn time retrying Reddit.
>
> **The drift is already measured and is not cosmetic.** In 37 commits upstream
> changed a sudoers file `src/deck-session.sh` quotes verbatim (~line 1157 —
> now stale), renamed three `omarchy-apply-*` binaries the ISO builder calls,
> edited the Quickshell **lock service** whose idle policy we deliberately
> neutered, edited the menu file P2.4's Desktop Mode row extends, and added
> **four migrations that run as root on `omarchy-update`** — one of which
> rewrites `/etc/bluetooth/main.conf` and notes that an update **over SSH**
> would otherwise abort. We update over SSH.
>
> Nothing in the delta touches Limine, the mkinitcpio hook, snapper or the ESP,
> so `src/omarchy-deck-kernel.sh` looks untouched — **do not promote that to a
> fact** without checking the pinned range and the `limine*` package versions.
>
> ### 🆕 SESSION 17 WAS THE FIRST TIME ANY OF THIS WAS SEEN ON A SCREEN — read this first
>
> Session 16 ended admitting *"nothing here was seen on a screen."* Session 17
> put the operator in front of the Deck. **Nine defects, none of which any check
> in this repo could see**, and two recorded "facts" corrected — including one
> this session wrote itself, hours earlier.
>
> **Full evidence: `docs/findings/P17-input-and-osk.md` (R-29…R-42).**
>
> **The input mapper was a COMPLETE NO-OP on the desktop.** `active`, correctly
> bound to `event7`, and that node is **silent** — lizard mode routes buttons to
> the emulated nodes. P2.1's "verified on hardware" was true in every particular
> and proved nothing. Under it, two more:
>
> - **The d-pad emitted nothing.** The Deck sends `BTN_DPAD_*`; the mapper only
>   handled `ABS_HAT0*`, which `hid-steam` *advertises and never sends*.
> - **A resting stick cancelled every held direction in ~10 ms**, killing
>   auto-repeat, because two input sources shared one state slot.
>
> **Then the mapper became the full input layer** — pointer from the right
> trackpad, clicks from the triggers, and **STEAM+X toggling the OSK**. Four
> more bugs, all found by the operator moving the cursor and saying how it felt:
>
> - **Diagonal movement emitted NOTHING.** Re-baselining replaced the whole
>   baseline dict, so X and Y wiped each other every report; the pointer worked
>   only for pure-horizontal or pure-vertical strokes. **Every pointer test drove
>   one axis, which is exactly why the suite stayed green while the cursor was
>   unusable.**
> - Floor division made leftward movement ~2× faster than rightward.
> - The sub-pixel remainder was discarded each step, so slow motion stuttered.
> - `REL_X`/`REL_Y` were emitted as separate syn'd events, staircasing the cursor.
>
> **CI was RED and `docs/PROGRESS.md` said it passed.** An unquoted heredoc was
> **executing `uwsm start ... Hyprland` as root** at file-generation time. Fixed;
> `shellcheck` exits 0 now.
>
> **The OSK works on text focus** (§5.20) — gated by one GSettings key shipping
> `false`. It was first recorded *here* as a negative after four failing
> experiments that **all sat downstream of that one gate**. Four experiments
> sharing a hidden precondition are one experiment; a `WAYLAND_DEBUG=1` trace
> settled it in minutes and needed no operator.
>
> **Gaming Mode was confirmed usable by the operator** (R-38), closing P16's
> caveat that the session was only ever known to *exist*.
>
> ### ⚠️ §2.6 was decided and then FORCED to change — read before touching the keyboard
>
> The operator chose "squeekboard for the installer, Steam's own keyboard
> thereafter". **R-42 killed the Desktop Mode half**, by measurement:
>
> - **Steam cannot drive a Wayland desktop.** It uses **XTEST** (`libXtst` is
>   mapped into the process), which under XWayland reaches neither the
>   compositor's pointer nor Wayland clients. Steam holds `/dev/uinput` but
>   creates **only** the virtual gamepad — never a mouse or keyboard. Resetting
>   the Desktop layout to Valve's default changed nothing.
> - **A resident Steam is actively HARMFUL**, not neutral: it takes the
>   controller and leaves the desktop with **no input at all** (R-41). The
>   operator hit it as an unexitable screensaver. Every R-39 check passed while
>   the device was uncontrollable — **"STEAM+X shows the keyboard" is not
>   evidence the desktop is usable.**
> - Steam's desktop window is **not controller-navigable** on any platform; only
>   Big Picture is.
>
> **Current decision: squeekboard everywhere except Gaming Mode. Steam is NOT
> autostarted.** T8 (below) replaces squeekboard eventually.
>
> ### 🆕 The mapper is now the whole input path — and it needs `lizard_mode=N`
>
> `src/deck-input-mapper.py` emits pointer, clicks, keys and the STEAM+X chord.
> **`BTN_MODE` (STEAM) is only visible with `lizard_mode=N`**, so the chord costs
> you lizard mode — which is why the mapper had to grow a pointer at all.
>
> ⚠️ **`/sys/module/hid_steam/parameters/lizard_mode` is a MODULE PARAMETER: a
> reboot resets it to `Y`**, and nothing persists it yet. On the test Deck it is
> currently **`N`**. If the Deck reboots, STEAM+X and Space stop working until
> something sets it again. **Never set it to `N` where the mapper is not proven
> working** — the pointer and every key come from the mapper alone at that point.
>
> ### Measured hardware facts — do not re-derive, and do not trust the names
>
> | Control | Reports as |
> |---|---|
> | **Left trackpad** | `ABS_HAT0X/Y` — **called a hat, is a trackpad** |
> | **Right trackpad** | `ABS_HAT1X/Y` (drives the pointer) |
> | Triggers | `ABS_HAT2X`=R2, `ABS_HAT2Y`=L2, plus `BTN_TR2`/`BTN_TL2` |
> | D-pad | `BTN_DPAD_*` — **never** the hat axes |
> | STEAM | `BTN_MODE`, lizard-off only |
> | Rear paddles | `BTN_TRIGGER_HAPPY1..4` — unused, available |
> | Pad sample rate | **250 Hz** steady; lift reports **0 (centre)** |
>
> Lizard mode swallows **X, Y, L1, R1, STEAM and QAM entirely** — no evdev node
> sees them — and provides **no Space**, which archinstall's multi-select needs.
>
> ⚠️ **Two things are load-bearing and silently break the product if lost:** the
> **idle lock staying off** (`shell.json`, and `lock: 0` locks INSTANTLY rather
> than disabling) and the **desktop's two GSettings**
> (`screen-keyboard-enabled`, `input-sources`). Neither fails a test today.
>
> *(A third used to be listed here — the `omarchy.tray` bar widget, because
> without a StatusNotifier host closing Steam's window quits it and Desktop Mode
> loses its keyboard. **Session 18 retired it:** the revised §2.6 does not
> autostart Steam and does not use Steam's keyboard on the desktop, so the tray
> host no longer holds the keyboard up. Dropping the widget is now a bar-layout
> choice, not a silent product break.)*
>
> ⚠️ **Lizard mode is the load-bearing fact for T4.** It swallows **X, Y, L1,
> R1, STEAM and QAM entirely** — no evdev node sees them — and provides no
> **Space**, which archinstall's multi-select needs. The knob that frees them,
> `/sys/module/hid_steam/parameters/lizard_mode`, also removes the free pointer,
> making the mapper the *only* input path. Do not set it to `N` anywhere until
> the mapper is proven working, or the Deck is uncontrollable without SSH.
>
> ### ✅ PHASE 1 COMPLETE. Phase 2 is underway — the core promise now works.
>
> **T0, R1, T1, T2 done. T3 is close.** Steam's own **Power → Switch to
> Desktop** works end to end on hardware — the affordance a user actually
> touches — and session 16 **soak-proved it, 20/20 cycles clean**. Session 16
> shipped P2.0b, P2.0c, P2.0e, P2.1 and the programmatic half of P2.2.
>
> **The Deck:** package-based **Omarchy 4.0 + Neptune 6.11.11-valve29**,
> Hyprland 0.56.2, unencrypted, booting unattended, **Steam signed in and past
> OOBE**, greeter and desktop rotated correctly, zero DeckShift. Reach it with
> **`ssh steamdeck`** (key-based, passwordless sudo). **7 snapshots** — #1–#3
> P1.5, #4 pre-15, #5 `P2.0 complete`, #6/#7 session 16. Left **on the desktop**;
> `stage-default-session` (boot straight to Gaming Mode) is deliberately not run.
>
> **State at the end of session 17:** `lizard_mode=`**`N`** (non-persistent —
> see above), mapper **active** with the full input layer, **squeekboard
> running**, **Steam not running**, screensaver 150 s, **idle lock effectively
> off** (86400 s), and session 16's display-always-on **reverted**. The two OSK
> GSettings are installed as **dconf site defaults** by
> `stage-desktop-settings`, and the Deck's user-level overrides were reset, so
> the site default is what actually takes effect.
>
> Installed by session 16 and not in any earlier notes: three helpers in
> `/usr/bin/steamos-polkit-helpers/`, the input mapper as a `--user` service
> (`deck-input-mapper.service`, active), plus `python-evdev` and `squeekboard`
> from Arch `[extra]`.
>
> ⚠️ **ONE TEMPORARY CHANGE IS STILL IN EFFECT on the Deck**, operator-requested
> for testing:
>
> 1. **The display never sleeps** — idle/screensaver/lock disabled, sleep
>    targets masked. This is an **OLED** panel, so burn-in is the reason not to
>    leave it. Revert: `sudo /usr/local/sbin/deck-always-on-revert.sh`.
>
> ✅ **`stage-desktop-settings` now installs these — they are no longer hand
> edits**, and the Deck's user-level overrides were reset so the site default is
> what is actually in effect:
>
> - `org.gnome.desktop.input-sources sources` = `[('xkb','us')]` — squeekboard
>   has no keys to draw without it. *(An earlier note here told you to revert
>   this. It was wrong.)*
> - `org.gnome.desktop.a11y.applications screen-keyboard-enabled` = `true` —
>   ships `false`, and **the OSK never auto-shows without it** (§5.20).
> - Omarchy's idle policy in `shell.json` — screensaver 150s, **lock 86400s**
>   (R-38). ⚠️ `lock: 0` locks **instantly** rather than disabling.
>
> They install as **dconf site defaults** (`/etc/dconf/db/local.d/50-deck-desktop`),
> not per-user `gsettings set`, because the image creates a user we have never
> met. ⚠️ **Verify them with `dconf read -d`**, never `gsettings get`: a plain
> read returns the *user's* value and passes while the site default is missing.
>
> ⚠️ Still a T5 item: **`shell.json` is a per-user dotfile.**
> `stage-desktop-settings` *does* seed it from `/usr/share/omarchy/config/` for
> the invoking user, so the gap is narrower than "absent" — what T5 owes is
> running the stage for an account that does not exist at image-build time.
>
> ⚠️ **The line that used to sit here said squeekboard belongs to the live ISO,
> not the installed system. That is backwards** — it survived from the
> *superseded* §2.6. Corrected in session 18: **squeekboard is for Desktop Mode**
> (until T8 replaces it) and **cannot run in the live ISO at all**, which has no
> Wayland compositor (`docs/findings/T2-gamepad-spike.md` §4, measured on the
> built 4.0 ISO). The installer's keyboard is **T8's**, and always was.
>
> They are T5 constraints: GSettings in one user's dconf, **absent from a built
> image**. No test would notice — every suite runs on the Deck where they are
> already set.
>
> Also: the backlight sysfs node is deliberately left **0644**, not the 666
> found. If it is 666 again, Steam fell back — which means a helper broke.
>
> **Git:** everything through **session 16** is merged into **`main`** and
> **pushed** to `origin`. Check state with
> `git rev-list --left-right --count origin/main...main` rather than trusting a
> number written here — this block has been stale twice before.
>
> ⚠️ **And treat the rest of this file the same way.** At the end of session 16
> it was re-read as a new session would, and **six claims were stale** — five
> numbers and a set of entry points describing work already finished. Numbers
> here (assertion counts, fact counts, mutation totals, constraint counts) are
> cheap to re-verify against the tree and have been wrong before. Verify, then
> trust.
>
> **Start with the session summaries, newest first** —
> `docs/findings/P16-session-summary.md`, then
> `docs/findings/P2-session-summary.md` and
> `docs/findings/P15-session-summary.md`. They are the orientation pages; the
> R-numbered findings files hold the evidence.
>
> ⚠️ **P16's opening section lists four recorded "facts" it had to correct, two
> of them from session 15.** Read it before trusting §5.15 or §5.16.
>
> Then read, in this order:
> 1. `docs/PROGRESS.md` §1 (state) and §2 (the scope decisions) — **§2.6 is new
>    and was already revised once by measurement**; a session that misses it will
>    build the wrong keyboard
> 2. `docs/PROGRESS.md` **§5.9–§5.20** — the open issues. §5.10/§5.13/§5.14/
>    §5.16/§5.18/**§5.20** are now closed; **§5.17 is the live one**, and
>    **§5.9 gained session 17's measured lizard-mode map**
> 3. `docs/ROADMAP.md` — phase 2 is the live work queue, **phase 2.9 is new**
>    (the beta 2 rebase, before phase 3) and phase 4 is the enablement layer
> 4. `docs/PROGRESS.md` §7 — **53** facts that each cost real time; do not
>    re-derive them
>
> Hardware evidence: `docs/findings/P15-live-iso-recon.md` (R-0…R-19, raw logs
> in `P15-recon-raw/`), `docs/findings/P2-steam-integration-and-rotation.md`
> (R-20…**R-28**), and **`docs/findings/P17-input-and-osk.md` (R-29…R-42)** —
> the only one so far where a human watched the screen.
>
> ### There are now unit tests. Run them before and after touching `src/`.
>
> ```bash
> for f in test/unit/test-*.sh; do ./"$f"; done; for f in test/unit/test-*.py; do python3 "$f"; done
> ```
>
> **12 suites, seconds, no VM.** ⚠️ That is *two* globs — the shell one alone
> misses all five Python suites, which is where the input layer's coverage
> lives. Seven shell (`test-deck-session.sh` **70**, `test-osk-install-layout.sh`
> **19**, `test-vm-limine-pin.sh` **12**, four VM-helper suites) and five Python (`test-deck-input-mapper.py`
> **106**, `test-deck-osk-layout.py` **134**, `test-deck-osk-tty.py` **54**,
> `test-deck-osk-wayland.py` **47**, `test-deck-osk-focus.py` **37**).
>
> *(Every number in that sentence was **re-counted by running the suites**
> 2026-08-11. Four were wrong: the suite total, `osk-install-layout` (16→19),
> `osk-tty` (49→54), and `test-deck-osk-focus.py` was missing entirely — it
> arrived with the focus watcher in `44e8f66`. Count them; don't quote them.)*
>
> ⚠️ **This is the failure this file keeps warning about, found again by
> running one glob.** The paragraph above is the *documentation* of the test
> suite, and it was wrong about the test suite.
>
> ⚠️ **One more suite is NOT in either glob, on purpose.**
> `test/osk-tty-e2e.py` drives the on-screen keyboard end to end — virtual pad →
> mapper → cursors → rendered console → keystrokes — and needs a writable
> `/dev/uinput`. It is excluded from CI because a test that skips itself when a
> device is missing reports green while asserting nothing. Run it by hand:
>
> ```bash
> python3 test/osk-tty-e2e.py
> ```
>
> Session 17 rewrote a chunk of the mapper suite (the old d-pad tests asserted a
> device model this hardware does not have). Session 18 added T8's three suites,
> **46/46 mutations caught** — **three of which survived a first attempt** and
> were real coverage gaps, not test-writing noise.
>
> `test/unit/test-deck-session.sh` is now **70 assertions** covering all five
> generated files — the `steamos-update` stub's exit-code protocol, the
> install-marker contract, both polkit helpers' argument validation, the sddm
> restart helper's shape, and Steam's shim. It has teeth: **mutation-tested,
> 15/15 then 39/39 faults caught**, including the apply-path drift that rebooted
> the Deck. See `docs/findings/P2-session-summary.md` §6a and
> `docs/findings/P16-session-summary.md` §4 for what it does and does not cover.
>
> ⚠️ Session 16's lesson for writing these: three assertions there pin **which
> guard fired**, via the error message, not just the exit code. Two guards that
> share an exit code make an exit-code-only assertion pass with either one
> deleted — all three cases were caught by mutation testing, not by review.
>
> ⚠️ **`src/deck-session.sh` is source-safe, and the test sources
> it** — so anything you add at TOP LEVEL below the constants runs at source time
> inside the test. Keep new work in functions.
>
> ### ⚠️ Sessions 15 AND 16 each corrected four recorded "facts". Trust the findings, not memory.
>
> Session 15: `transform,1` (it is **3**; 1 is upside down) · the rotation syntax
> (4.0 uses **Lua**, not `.conf`) · "Steam finds `steamos-update` via PATH"
> (**absolute path**) · "`steamos-customizations-jupiter` would supply it"
> (**ships zero polkit helpers**).
>
> Session 16: "the brightness slider does nothing" (**it works** — Steam falls
> back to blanket sudo) · the 666 backlight mode (**Steam sets it**, not a
> human) · "`RestartSec` is the important half" of §5.16 (**it never gated the
> fatal start**) · "§5.16 is a switch defect" (**it fired at boot**).
>
> Two more were defects session 16 introduced *in its own fixes* and caught only
> by mutation testing and soaking — see P16 §4. Verify against hardware before
> building on a recorded value, and **never conclude a check works because it
> passes.**
>
> ### The most important open item
>
> **§5.17 — the test Deck is more privileged than the product will be.**
> `/etc/sudoers.d/99-deck-testing` grants `deck ALL=(ALL) NOPASSWD: ALL`, is
> owned by no package, and **sorts last**, so it overrides every narrow sudoers
> grant this project installs. It must never ship, and until it goes, anything
> privilege-dependent verified on this Deck is suspect.
>
> Session 16 found this the hard way: §5.15 recorded that the missing
> `steamos-priv-write` meant "the brightness slider does nothing", but the
> slider **works here** — Steam falls back to `sudo -n tee`, then
> `sudo -n chmod a+w`, both of which need exactly that blanket grant. Right
> conclusion about the product, wrong belief about the present. **Assume any
> "it works on the Deck" claim about privilege is wrong until re-checked
> without `99-deck-testing`.**
>
> §5.15 itself is now 🟡: its two user-visible helpers ship
> (`stage-timezone-helper`, `stage-priv-write-helper`), and
> `jupiter-hw-support` is skipped by operator decision.
>
> *(**§5.16 and §5.18 are both closed.** §5.16's cause was sddm's stop timing
> out; §5.18's was `steam-launcher.service` taking up to ~53 s to stop, so the
> incoming session started into a teardown. Autologin attempts across 20
> switches went **600 → 283 → 20**, the ideal. Residual: a switch away from
> Gaming Mode can take **~1 minute**, dominated by Valve's `TimeoutStopSec=60` —
> correct and flicker-free, but not fast.)*
>
> ### 🆕 There is now a PHASE 4 — read this before proposing a pivot
>
> **Operator direction, end of session 16.** Phases 1–3 ship *one* Deck-ready
> distro. **Phase 4 generalises it into a Deck enablement layer** so the next
> distro costs ~a day of Claude-assisted porting instead of sixteen sessions.
> Spec: `docs/tasks/T7-enablement-layer.md`. Ordering: `docs/ROADMAP.md` phase 4.
> Decision record: `docs/PROGRESS.md` §5.19.
>
> ⚠️ **"A day" buys ported-and-conformance-green. NOT shippable.** §5.18 first
> appeared on soak cycle 4, §5.16 needed a journal read across two boots, and
> three of this project's own *checks* were wrong about themselves. Soak time is
> wall-clock and no abstraction compresses it. Do not quote "a day to ship".
>
> **Phase 4 comes AFTER phase 3, deliberately.** Abstracting from one *finished,
> soak-proven* example is engineering; from an unfinished one it is guessing.
> P4.2 proves the extraction by making Omarchy consume the core with the
> existing **70 assertions and the soak unchanged** — if those need editing, the
> seam is wrong.
>
> ### ⛔ A Deck-specific USB flasher was considered and REFRAMED — don't re-propose it cold
>
> Full reasoning: **`docs/findings/P16-scope-flasher-vs-layer.md`**. The short
> version, because this idea is intuitive and will come back:
>
> - **"Take any ISO and apply our script" does not work.** The script *is* the
>   distro-specific part — 26% of `omarchy-deck-kernel.sh`, 13% of
>   `deck-session.sh`, and the portable remainder is scaffolding around a core of
>   `pacman`/`limine`/`mkinitcpio`/`sddm`/`uwsm` you would rewrite, not port.
> - **The flasher is the easy ~10%**; Ventoy (which this project already uses),
>   Etcher and Rufus got there first. The cost is per-distro enablement, which is
>   multiplicative and a maintenance treadmill.
> - **Hosting images reopens `steamdeck-dsp`** (`Proprietary`, no licence text)
>   as redistribution at scale, and puts a stranger's bricked handheld on the
>   support surface with `docs/RECOVERY.md` still unexercised.
> - **Bazzite already ships `bazzite-deck` images**; ChimeraOS covers the console
>   case. Deck-ready images are largely solved for gaming distros.
> - **What IS differentiated: the controller-only install**, including Wi-Fi
>   passphrase entry. That is T4, and nobody else is doing it.
>
> If revisited, re-test the **prior art** (a market position that can change),
> not the premise — how distributions differ will not change.
>
> ### One defect still deliberately unfixed — decide before coding
>
> - **§5.12 the 4.0 installer defaults to full-disk encryption.** Inherit it and
>   the ISO produces a device its owner cannot boot without a keyboard.
>
> *(§5.13 is **closed** — session 16 audited the overlap. 101 package names
> collide and Valve's is older in 50, so reordering repos is rejected; the real
> surface is one package and the fix is `pacman -S jupiter-staging/gamescope`.
> See `docs/findings/P16-repo-overlap-audit.md`.)*
>
> ### Good work available *without* the Deck
>
> ⚠️ **T8 (the on-screen keyboard) is now the largest remaining phase-2 piece**,
> specified in full: `docs/tasks/T8-onscreen-keyboard.md`. squeekboard **cannot**
> do dual-trackpad letter selection at any configuration — Valve's keyboard runs
> two cursors and Wayland gives one pointer per seat — and the live ISO has no
> compositor at all, so T2 §4 had already chosen a mapper-drawn OSK for the
> installer. **The input half already exists**, chord included.
>
> **These two also remain, and neither needs the Deck:**
>
> - **T4's installer screens (P2.5/P2.6)**, re-scoped by §5.9 — lizard mode
>   already makes the installer navigable, so the real gap is **text entry**.
>   Draw our own button glyphs; do not use Valve's artwork
>   (`docs/findings/P16-redistribution-and-trademark.md`).
> - **T5's ISO fork (P2.7/P2.8)**, `docs/tasks/T5-iso-and-payload.md`, which now
>   carries **six** recorded constraints: offline-only pacman · the encryption
>   default (§5.12) · repo precedence (§5.13) · **baking in BOTH rotations**
>   (desktop `monitors.lua` *and* Limine `interface_rotation`) · **excluding
>   `99-deck-testing`** (§5.17) · 🆕 **the three load-bearing session settings**
>   (§5.20 — `screen-keyboard-enabled`, `input-sources`, rotation), which are
>   GSettings in one user's dconf today and would be simply absent from a built
>   image. Also decide **bundle vs fetch** — `steamdeck-dsp` is `Proprietary`,
>   so bundling redistributes it and fetching does not.

Layout is in `CLAUDE.md`. Paths below are repo-root-relative.

---

## 1. What you are building

A **single bootable ISO** that installs Arch + **Omarchy 4.0 (Quattro)** on a
Steam Deck, navigable start to finish with only the Deck's buttons and
trackpads — no keyboard, no terminal. After install the device behaves like
stock SteamOS: boots to Gaming Mode, all hardware works, and a **Desktop Mode**
button drops into a full Omarchy desktop with a way back.

The install **may use Wi-Fi** — see `docs/PROGRESS.md` §2.2. That is a deliberate
reversal of an earlier "fully offline" constraint, not an oversight.

The operator owns one **OLED Steam Deck** and is on **Claude Max 5x**. They
already did a full manual Omarchy install on that Deck by hand, hit roughly a
dozen distinct bugs doing it, and wrote the findings into `docs/PLAN.md`. **Your job
is to turn that validated manual process into automation** — not to rediscover
it.

---

## 2. Files in this directory

| File | Read it when |
|---|---|
| `CLAUDE.md` | Auto-loaded every session. Hard constraints. |
| `docs/ROADMAP.md` | **The plan — three phases.** Where the current block fits and what gates what. |
| `docs/PROGRESS.md` | **Every session start. This is the authoritative state.** Scope, findings, open issues, and **53** facts not to re-derive. |
| `docs/SESSIONS.md` | Usage-limit budgeting and the block schedule. |
| `docs/PLAN.md` | **Frozen and partly superseded.** Read the banner at the top first. Good for §6.1a (installer screens), §8 (bug hypotheses), §9 (test tiers), §11 (maintenance risks). |
| `docs/tasks/` | One file per work block. |
| `docs/findings/` | Research outputs. Evidence behind the decisions in `docs/PROGRESS.md`. |
| `docs/drafts/` | Staged upstream report. **Nothing sent. Do not send.** |
| `src/omarchy-deck-kernel.sh` | T1's deliverable. Ten idempotent stages, VM-tested and hardware-validated. |
| `src/deck-session.sh` | T3's session-switch layer — **nine** install stages, each self-verifying. Also owns the three `steamos-polkit-helpers` (update stub, timezone, priv-write), the greeter rotation and the SDDM restart drop-in. |
| `test/unit/test-deck-session.sh` | Pins that script's protocol contracts and both new helpers' argument validation — 36 assertions, mutation-tested. No Deck, no VM, no root. |
| `src/deck-input-mapper.py` | T2/T3's gamepad→keyboard mapper. |

New files go in the matching directory — `docs/findings/` for research
outputs, `docs/tasks/` for work specs, `test/unit/` for suites that need no
VM.

---

## 3. Operating rules — how autonomous to be

### Do these without asking

- Read anything, search the web, inspect any repo.
- Create/modify/delete files in this project.
- Run builds, tests, linters, QEMU VMs, `git` operations (including commits
  and pushes to **your own** branches).
- Install packages inside VMs/containers you control.
- Choose implementation details, file layout, naming, libraries.
- Move to the next block when the current one's done-criteria are met.
- Update `docs/PROGRESS.md` — continuously, not just at session end.

### Stop and ask the operator first

- **Anything that writes to the physical Steam Deck** — flashing a USB,
  installing, or modifying its filesystem. They have one device; a bricked
  Deck costs hours. Prepare the change, describe exactly what will happen,
  wait. **Batch these requests** rather than asking per-item.
- Anything touching TDP, fan curves, charge limits, or thermal control on
  real hardware — every time, no exceptions. Genuine hardware-damage risk.
- Publishing anything public: creating public repos, opening upstream
  issues/PRs, posting to forums or Discord.
- Spending real money.
- Any decision contradicting a hard constraint in `CLAUDE.md`.
- Discovering a foundational assumption is wrong. Surface it; don't quietly
  work around it. This has already happened four times and each time it
  changed the plan for the better.

### Never

- Never report a task complete when its done-criteria aren't met. This
  project exists partly because upstream tooling printed "success" while
  doing nothing (`docs/PLAN.md` §8.1). Do not become that.
- Never propose "reinstall on the Deck to test this" for anything not on
  the physical-hardware-only list (`docs/PLAN.md` §9.5). There is almost always
  a faster tier.
- Never depend on something unlicensed or AUR-only. The ISO redistributes
  what it carries.

---

## 4. The work queue

**The ordering lives in `docs/ROADMAP.md` — four phases, plus 2.9 wedged
between 2 and 3.** Task-to-phase mapping:

| Task | File | Model | State |
|---|---|---|---|
| T0 | `docs/tasks/T0-test-infrastructure.md` | Sonnet | ✅ done — **both gaps closed by P1.5** |
| R1 | `docs/tasks/R1-research-questions.md` | Opus/Sonnet | ✅ done |
| T1 | `docs/tasks/T1-kernel-and-boot.md` | **Opus** | ✅ done — **hardware-validated 2026-08-10** |
| T2 | `docs/tasks/T2-gamepad-input-spike.md` | **Opus** | ✅ done |
| T3 | `docs/tasks/T3-gaming-mode.md` | Sonnet/Opus | 🟡 **the core promise works, and the switch is now soak-proven** (§5.10 ✅, §5.14 ✅, §5.11 ✅, §5.15 ✅, §5.16 ✅, §5.18 ✅). Left: §5.17, P2.1–P2.4 |
| T4 | `docs/tasks/T4-installer-ui.md` | Sonnet | ⬜ **unblocked, re-scoped by §5.9** → P2.5–P2.6 |
| T5 | `docs/tasks/T5-iso-and-payload.md` | Sonnet/Opus | ⬜ P2.7–P2.8, now with §5.12/§5.13 constraints |
| T6 | `docs/tasks/T6-integration-release.md` | **Opus** | ⬜ phase 3 |
| T9 | `docs/tasks/T9-beta2-rebase.md` | **Opus** | ⬜ **phase 2.9 — NEW (2026-08-11).** Rebase every artifact onto Omarchy 4.0 **beta 2** and re-establish by measurement each fact that names upstream behavior. P2.9a–P2.9d need no hardware. **Two operator calls open:** approval to download the 6 GB beta 2 ISO (no upstream checksum exists), and whether to rebase now or wait for stable, which may ship this week. Makes P3.6 (rebase onto *stable*) the second run of the procedure, not the first |
| T8 | `docs/tasks/T8-onscreen-keyboard.md` | Sonnet/**Opus** | ✅ **DONE (session 18) — all seven steps, hardware-proven (R-43) and console-sharing proven in QEMU (R-47).** Was P2.4b. Input half was already done in the mapper, chord included |
| T7 | `docs/tasks/T7-enablement-layer.md` | **Opus** | ⬜ **phase 4 — NEW.** Generalise into a Deck enablement layer so the next distro is ~a day. Deliberately after phase 3: abstracting from one *finished* example is engineering, from one unfinished example is guessing |

**Phase 1 is closed. P2.0, P2.0b, P2.0c and P2.0e are done**, and P2.1/P2.2/P2.4
are done as far as a script can verify them. Sensible entry points:

- **Without the Deck — this is where the remaining bulk is.** **P2.5/P2.6**
  (T4's installer screens; text entry is the real gap) or **P2.7/P2.8** (T5's
  `omarchy-iso` fork, which now carries six recorded constraints — see above).
  Either is days of work and needs no hardware.
- 🆕 **Also without the Deck, and cheap: P2.9a–P2.9d** — pin beta 2, finish the
  delta document, rebuild the ISO, rebuild the substrate and re-run every
  suite. ⚠️ **P2.9a needs one answer from the operator first** (where beta 2
  was announced); P2.9b can start immediately from the seed in
  `docs/findings/T9-beta2-delta.md`. Do **not** rebuild the substrate from the
  old ISO — a substrate mimicking the previous Quattro passes while testing a
  system that no longer exists.
- **With the Deck, needing a HUMAN present:** everything left on P2.1/P2.2/P2.4
  is a thing a script cannot check — does the OSK appear on text focus, are the
  buttons mapped correctly, does sound actually come out, do haptics and gyro
  respond, and every rotation surface. Batch these into one hands-on pass.
- **A decision, not a task: §5.17.** It is *answered* — a narrower sudo grant is
  impossible, because the install stages write to `/etc/sudoers.d/` itself.
  What remains is choosing whether to drop `99-deck-testing` (and lose the
  unattended SSH loop) or keep it and rely on T5 excluding it from the image.
  `./src/deck-session.sh stage-audit-privileges` is the gate either way.
- **Held for operator approval, both boot-chain:** Limine's
  `interface_rotation: 270` and the TTY's `fbcon=rotate:1`.

⚠️ **P2.3 (TDP, fan curves, battery) still requires per-item operator approval
every single time.** That rule has not moved.

---

## 5. How to work a block

Each task file has the same shape: **Objective → Why → Prerequisites →
Steps → Done when → Failure modes → Escalate if**.

1. `/usage` — confirm you have headroom for this block.
2. Read `docs/PROGRESS.md`, then this block's task file.
3. `/model` to the block's recommended model.
4. Verify prerequisites are actually satisfied — don't trust `docs/PROGRESS.md`
   blindly where a cheap check exists.
5. Work the steps. Commit in logical chunks.
6. Verify every "Done when" item **by running something**, not by reading
   your own code and concluding it looks right.
7. Update `docs/PROGRESS.md`, commit, `/clear`.

If a block turns out much larger than its file suggests: split it, write
the new task file, note it in `docs/PROGRESS.md`, continue. The decomposition is
a starting point, not gospel.

---

## 6. Token discipline (matters — read `docs/SESSIONS.md`)

The operator's 5-hour window is shared across Claude Code and claude.ai,
and there's a separate weekly cap that a 5-hour reset does not restore.
Four habits carry most of the benefit:

- **One task per block, then `/clear`.** Don't carry finished context
  forward.
- **Default Sonnet**; escalate to Opus only where the table above says.
- **Never read `docs/PLAN.md` whole.** It is frozen and partly wrong; read the
  banner and the specific sections a task cites.
- **Use subagents for repo exploration** — they return a summary instead of
  filling your context with source files.

---

## 7. What "done" looks like for the whole project

A single ISO the operator copies onto a Ventoy USB, boots on their OLED
Deck, clicks through using only the Deck's buttons — including joining
Wi-Fi — and lands at a Gaming Mode home screen where controller, Bluetooth,
audio, and haptics all work, with a Desktop Mode button that opens Omarchy
4.0 and a way back.

Everything here exists to get there without reflashing a USB forty times.
