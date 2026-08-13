# START HERE — Omarchy Deck build session

**You are Claude Code. This is your entry point. Read it fully, then begin
work without waiting for further instruction.**

> ## Where things stand (updated 2026-08-12, session 23 — READ THIS FIRST)
>
> *(This supersedes session 22's block below, which is kept for its own
> evidence but is stale wherever it disagrees with this one. Verify every
> "done" claim against the tree — `git log`, run the suite — before trusting
> it; this project has been burned by stale ✅/🔴 marks in this exact file
> more than once. Session 22's block already carries some inline session-23
> edits made before this header existed — both are consistent, this one is
> just the complete, organized version.)*
>
> ### Session 23 in one paragraph
>
> `iso/bin/build` ran for real for the first time ever and produced a working
> ISO. That ISO was then actually driven through its own installer with a
> virtual gamepad for the first time ever, reaching a screen nobody had seen
> before and finding two real bugs. Two operator-reported on-screen-keyboard
> defects (Move, emoji) were root-caused and fixed, deployed to the physical
> Deck, and are live now. `input.lua`'s last missing lock-screen fix landed.
> A never-run VM suite (`vm-gamepad-spike-test.sh`) got a real probe bug fixed
> and its first-ever run is in progress. Six subagents ran across the session,
> five on fully disjoint files with no collisions; the sixth (the gamepad
> probe fix) went silent mid-task with no completion notification and its
> real, sound work was recovered from the uncommitted tree rather than lost —
> see "A subagent went silent" below, it is worth reading before trusting any
> background-agent report in a future session at face value.
>
> ### Phase 2 exit criteria: 2 of 4 closed, criterion 1 much closer
>
> | # | Criterion | State |
> |---|---|---|
> | 1 | Controller-only QEMU install from our ISO | 🟡 **the harness now drives our real ISO and proves S0→S5** (59/62 checks, commit `454e5a8`) — 3 failures are a real reproduced product bug (see below), not harness noise. Not fully closed: S5 is a summary screen, not a completed disk install; the harness stops there |
> | 2 | Hardware parity on OLED | ✅ closed session 21 |
> | 3 | Both switch directions survive reboot | ✅ closed session 22, on the panel |
> | 4 | CI publishes an ISO; dry run shows zero NVIDIA | 🟡 the dev-machine build is proven end to end; CI itself still has no `/dev/kvm` on a hosted runner, untouched by anything this session did |
>
> ### 🟢 `iso/bin/build` ran for real and produced a working ISO — commit `39d0da6`
>
> First attempt failed on a corrupted cached package left over in an old
> scratch dir from earlier (pre-pin-fix) build attempts — not a code bug. A
> fresh scratch dir (`~/.cache/omarchy-deck/iso-build-2`) built clean: all 8
> guards passed (6.1, 6.3, 6.4a, 6.4b, 6.5a, 6.5b, 6.6), all 5 overlay patches
> applied (2 via git's 3-way-fallback path on a shallow clone — hand-verified
> both landed anyway: `configure_deck` import in `main.py`, the
> `deck-dashboard.sh` source line in `omarchy-install-dashboard`),
> `omarchy-deck` 0.2.0-1 built with its 2 runtime patches applied cleanly.
> Output: `omarchy-2026.08.13-x86_64-quattro.iso`, 6.39 GiB, sha256
> `336f35715086604e75940d6baebc767d10b59c8714f845ca6640ae51f413f782`, sitting
> in scratch only (`~/.cache/omarchy-deck/iso-build-2/release/`) — **not
> shipped, not in git, not on the Deck.** Detail: `docs/PROGRESS.md`'s T5 row.
> **The old `~/.cache/omarchy-deck/iso-build/` scratch dir (and the ISOs in
> its `release/`) are stale — from before today's commits — ignore them.**
>
> ### 🟡 The controller-only install harness now drives our real ISO, first time ever — commit `454e5a8`
>
> `test/vm/vm-installer-screens-test.sh` was deliberately built against an
> *unmodified* upstream ISO (asserting our `deck-form.sh` is ABSENT) as a
> stand-in for exactly this moment, per its own header comment. That migration
> — point it at our real ISO, swap the marker strings for Deck-branded text —
> had never been done. It's done now: ran the pre-migration harness against
> the real ISO first to see the raw divergence (35/47), migrated the markers
> and assertions, then **three QEMU boots, the last two bit-identical: 59/62
> checks pass**, navigating S0's disclosure screen through the disk-confirm
> safety flip (proven safe with three byte-identical decline-loop captures,
> not inferred) into `deck_final_summary` (S5), a screen nobody had proven
> before. Full record with exact commands and capture excerpts:
> `docs/findings/T4-controller-only-install-first-run.md`.
>
> 🔴 **Two real product bugs found, left failing on purpose rather than
> papered over:**
> 1. `deck-form.sh`'s `omarchy_prompt_identity`/`_hostname`/`_timezone`
>    overrides are **not wired up** on the real build — upstream's own
>    unmodified prompts still run there, while `greeter`/username/password/
>    `disk_form`/`confirm_disk_overwrite` are correctly overridden. Whoever
>    owns `deck-form.sh` next should look at this.
> 2. The username-retry screen **grows unboundedly** (16→22→28→34 rows across
>    four measured attempts) because a WARNING line never clears between
>    attempts.
>
> Criterion 1 is not closed: S5 is a summary screen, not a completed disk
> install to a bootable target. The next step is pushing the same harness (or
> `vm-install-test.sh`'s disk-image-assertion model) through to an actual
> installed, bootable disk.
>
> ### 🟢 Two operator-reported OSK bugs, root-caused, fixed, and LIVE ON THE DECK
>
> Both keys were copied onto our on-screen keyboard from Valve's reference for
> visual parity (T8) but were left as inert stubs — `src/deck_osk_layout.py`'s
> own comments said so plainly ("TWO KEYS THAT NO RENDERER IMPLEMENTS YET").
> Operator feedback after using the physical keyboard named exactly those two:
>
> - **"Move" now collapses the keyboard** (commit `86cba11`) — repurposed to
>   set `self.closed = True`, the exact same signal `deck-input-mapper.py`
>   already consumes to dismiss the overlay elsewhere. The dead `self.request`
>   state for Move was removed, not left dangling. Mutation-tested (3 checks
>   correctly fail when reverted).
> - **The emoji key now opens Omarchy's real emoji picker** (commit
>   `685440c`) — wired through the same `MENU_ACTIONS`/`pending_actions`/
>   `run_pending`/`spawn_detached` path the QAM button already uses, calling
>   `omarchy-menu-emoji`. ⚠️ The agent that built this **caught and corrected
>   a wrong hypothesis it was given** (`["omarchy-menu", "emoji"]` — not a
>   real verb) by reading the pinned upstream dispatcher itself rather than
>   trusting the brief. Mutation-tested (breaking either wiring point, or
>   reintroducing the wrong argv, each caught by a distinct new test).
>
> Both independently re-verified (full suite green, specific test files
> re-run) before being **synced to the physical Deck and deployed live**:
> `DECK_STAGE_ARGS=stage-input-mapper ./tools/deck-sync.sh deck-session.sh
> src` installed the OSK modules + mapper + unit (all self-verified — dry-run
> type test, OSK render test), then `systemctl --user restart
> deck-input-mapper.service` picked up the new code immediately rather than
> waiting for the next login. **Both are testable on the panel right now.**
>
> ### ⚠️ A subagent went silent mid-task — real work recovered, read this before trusting a background report
>
> The agent dispatched to actually *run* `vm-gamepad-spike-test.sh` for the
> first time ever (fixed for a bash syntax error in `b96eaac`, never
> executed) reported mid-session that it found and was fixing a **second, real
> bug**: the scripted virtual gamepad wrote d-pad presses as `ABS_HAT0X/Y`,
> but `deck-input-mapper.py` treats `ABS_HAT0X/Y` as the **left trackpad**
> (measured on hardware, session 17) and only `BTN_DPAD_*` as the d-pad — a
> probe using the wrong axis would let this suite pass while testing nothing
> about d-pad navigation, precisely the "measurement tool lied" class
> `docs/PROGRESS.md` §5.30c catalogues. Then **no completion notification ever
> arrived**, and a direct status check later found the harness had no record
> of the task at all — not running, not failed, just gone.
>
> Its fix was still sitting **uncommitted** in the working tree, and it was
> sound: syntax-clean (`bash -n`, a direct AST parse of the embedded probe),
> consistent with an already-established hardware fact, and the full 33-file
> unit suite passed with it in place. Committed as `4d45ce3` after that
> independent verification — **not** on the agent's say-so, which never came.
>
> ✅ **The suite's actual first run then happened, run directly rather than
> through another agent, and it PASSED — 26/26 checks, ~60s guest runtime.**
> A gamepad drives `gum` (single-select, multi-select, and the stick with
> auto-repeat — one held direction advanced 4 rows) and archinstall's curses
> menu (render, Enter, Esc, Down) through the kernel input layer, with no
> UI-side cooperation. This is `docs/PROGRESS.md` §5.30c/T2's central question,
> answered on real evidence for the first time — the suite existed and claimed
> to answer it for sessions before this one, but had never actually run.
>
> **The lesson, stated plainly for whoever reads this next**: an agent
> reporting "I'm waiting on X, I'll report back" is not evidence anything
> completed — verify by checking the actual task state (a completion
> notification, or a direct status query) and the actual tree (`git status`,
> `git diff`) before either trusting or discarding what it claims to have
> done. This session did both — recovered real work that would otherwise have
> been lost, and did not credit a report that never actually arrived.
>
> ### ✅ `input.lua`'s last lock-screen fix landed — commit `a4b1eab`
>
> New module `deck_input.py`, modelled on `deck_monitors.py`'s exact
> splice/seed/luac-gate/sibling-preservation pattern with its own markers,
> wired into `deck_configure.deck_steps()` as `lock_wake_dpms`. Splices
> §5.25 decision #1's `above_lock = 2` layer rule and §5.24a requirement #1's
> `misc.key_press_enables_dpms`/`mouse_move_enables_dpms = false` into
> `~/.config/hypr/input.lua`. 80/80 unit checks, 7/7 introduced faults caught
> by mutation testing, independently re-run and confirmed green.
>
> 🔴 **Found by the same agent, not yet fixed**: `omarchy-sleep-lock.service`
> masking (§5.6's OTHER lock producer) exists only as a dev-machine `stage-*`
> action in `src/deck-session.sh` — confirmed NOT wired into the live-ISO
> install path at all, so a fresh end-user install still ships this lock
> producer unmasked. Its own task, not folded into this one.
>
> ✅ Also clarified: the OSK's per-device XKB block already had a writer
> (`src/deck-session.sh`'s `install_osk_kb_layout_rule`) — pre-existing,
> unrelated to `above_lock`'s gap. An earlier note in this file conflated the
> two as though they were the same missing piece; they never were.
>
> ### ✅ `/etc/sudoers.d/asdcontrol` — decided: leave it
>
> Vendor-shipped (the `asdcontrol` package, not ours). Consistent with this
> project's stance of not overriding upstream/vendor packaging decisions (same
> reasoning as not auto-installing an AUR helper). Recorded in
> `docs/findings/P22-deck-conformance-sweep.md` §4 as a deliberate non-action.
>
> ### What's left in phase 2 — concretely, after today
>
> - Push the install harness from S5 (a summary screen) through to an actual
>   completed, bootable disk install — closes criterion 1 for real.
> - `omarchy-sleep-lock.service` masking is missing from the live-ISO install
>   path (found today, not yet fixed — see above).
> - The two real bugs the install-migration found (unwired identity/hostname/
>   timezone prompts; unbounded-growth username-retry screen).
> - ✅ `vm-gamepad-spike-test.sh` ran and PASSED (26/26, see above) — done.
> - Hardware-verify the DPMS/`above_lock` fix on the panel (code is deployed
>   only to the Deck's mapper/OSK path via this session's sync; the Lua/Hyprland
>   half installs at the NEXT full install or via its own ISO-orchestrator
>   step, not by `deck-sync.sh` — don't conflate the two deploy paths).
> - T10's extest spike — ~45 min Deck decision, unrelated to everything above,
>   queued since session 20.
> - The `Lid Switch` node question (T13 §8) — needs a physical trigger nobody
>   has found a way to produce on a handheld with no lid. Likely stuck.
>
> ### T13/T14: all four power-button reports closed, hardware-verified
>
> `docs/findings/T13-power-button-and-sleep.md` §9 is the full record. One
> physical press produces **two** `KEY_POWER` events, on asymmetric nodes (a
> real key at `event4`, a fire-and-forget ACPI notify at `event2` — found only
> after two silent captures with no positive control proved nothing). Fix: a
> udev rule drops the ACPI node from `power-switch`, a logind drop-in sets
> `HandlePowerKey=suspend` explicitly (its **default is `poweroff`**, not
> `suspend`). Deploy is reboot-gated (`stage-power-button`, opt-in, prints its
> own undo). **Measured on the panel**: suspend/resume clean in Gaming AND
> Desktop Mode, same `gamescope` PID across the cycle (the session survives),
> deep/S3 confirmed **twice independently** — overturning the initial
> research's s2idle guess; the kernel logs `PM: Steam Deck quirk - no s2idle
> allowed!` at 0.27 s of boot. T14 (`docs/findings/T14-gaming-mode-power-button.md`):
> Gaming Mode needed **no separate fix** — `logind`'s only gate on the key is
> the `power-switch` tag, with no session check at all, and `gamescope` holds
> no logind inhibitor anywhere in its tree.
>
> ### Four real bugs caught before they shipped, each only by RUNNING something
>
> 1. A menu-row glyph written as bash's `$'\U000F0297'` — **locale-dependent**:
>    expands to the real character under UTF-8, emits **ten literal ASCII
>    bytes** under the Deck's `LC_CTYPE=POSIX` SSH session. 28 green suites on
>    a UTF-8 dev machine never caught it; the Deck did, and the stage **refused
>    to write** the resulting invalid JSON rather than silently corrupting the
>    menu. Fixed as a pure-ASCII JSON escape pair; new suite renders the block
>    under both locales and requires byte-identical output.
> 2. Our own shipped `0020-limine-interface-rotation.patch` carried
>    `interface_rotation: 270` — **180° wrong** — and its own post-condition
>    asserted 270, so it was internally consistent and externally upside down.
>    Would have flipped the Limine menu on the next `omarchy refresh limine`.
> 3. `deck_patches.py`'s composed-path dodge (hiding the applier's path from
>    guard 6.4a's regex) had a docstring **example** that itself matched the
>    regex, and would have demanded a provider for a binary literally named
>    `omarchy-` on the very first real build.
> 4. `$SUDO -u` breaking when `deck-session.sh` runs already-root
>    (`sudo ./deck-session.sh`) — a comment had predicted this *exact* failure
>    and left three call sites unfixed "a separate change with its own
>    tests"; nobody had written that change, and 526 assertions never
>    exercised the case. Found deploying `stage-desktop-settings` for real.
>
> **The generalisation, consistent with every prior session's version of it:**
> a green suite on the dev machine is evidence, not proof. This session's four
> catches all came from actually running the deploy, not from a better test.
>
> ### What's left in phase 2 — concretely
>
> - ✅ **`iso/bin/build` ran, supervised, 2026-08-12 (session 23) — see above.**
>   🔴 **Next: the controller-only QEMU install run itself**, against the ISO
>   this produced — this is what actually closes criterion 1, not the build.
> - ✅ **`input.lua`'s `above_lock = 2` rule and the DPMS wake-suppression fix
>   both landed 2026-08-12 (session 23), commit `a4b1eab`.** New module
>   `deck_input.py`, modelled on `deck_monitors.py`'s splice/sibling-guard
>   pattern with its own markers, wired into `deck_configure.deck_steps()`.
>   80/80 unit checks, 7/7 introduced faults caught by mutation testing,
>   independently re-run and confirmed green. §5.24a's requirement #1 (only
>   the power button wakes the blanked panel, not QAM) is now **code, not just
>   research** — `misc.key_press_enables_dpms`/`mouse_move_enables_dpms =
>   false` are in the spliced block. 🔴 **Still open, found by the same
>   agent**: `omarchy-sleep-lock.service` masking (§5.6's OTHER lock producer)
>   exists only as a dev-machine `stage-*` action in `src/deck-session.sh` —
>   confirmed NOT wired into the live-ISO install path at all, so a fresh
>   end-user install still ships this lock producer unmasked. Its own task,
>   not folded into this one — same shape as `above_lock` was before today,
>   don't let it go stale the same way.
> - ✅ **The OSK's per-device XKB block already had a writer** — that was
>   `src/deck-session.sh`'s `install_osk_kb_layout_rule`/`OSK_KB_RULE_BEGIN`/
>   `END`, pre-existing and untouched by the above. (An earlier version of
>   this bullet conflated it with `above_lock`'s gap; they were never the same
>   gap — corrected here after actually reading the code.)
> - §5.24a's one remaining item — only the power button should wake the
>   *blanked lock panel* — **is now closed in code** (see above); what's left
>   is hardware verification: `hyprctl getoption misc:key_press_enables_dpms`/
>   `mouse_move_enables_dpms` both read `int: 0`, then press QAM while locked
>   and confirm the panel stays dark. A Quickshell/Hyprland-config fix,
>   unrelated to T13's systemd suspend work — do not conflate the two.
> - The `Lid Switch` node question (T13 §8) — needs a physical trigger nobody
>   has found a way to produce on a handheld with no lid. Likely stuck until
>   someone thinks of one.
> - T10's extest spike — a ~45 min Deck decision, unrelated to everything
>   above, queued since session 20.
> - ✅ `/etc/sudoers.d/asdcontrol` — **decided 2026-08-12 (session 23): leave
>   it.** Package-shipped (not ours), and this project doesn't override vendor
>   packaging decisions (same reasoning as not auto-installing an AUR helper).
>   Recorded in `docs/findings/P22-deck-conformance-sweep.md` §4.
>
> **Git: everything through session 22 pushed to `main`.** Verify with
> `git rev-list --left-right --count origin/main...main`, never by trusting
> this line — every session says this and every session has been right to say
> it.
>
> ---
>
> ## How to segment the rest of this across subagents
>
> *(Written 2026-08-12 for whoever picks this up with a fresh token budget.
> Session 22 ran ~15 agents across one day with no lost work and no silent
> corruption — this is what actually worked, not theory.)*
>
> **The shape that works: disjoint file ownership, verify independently, batch
> commits by logical concern.** Concretely:
>
> 1. **Before dispatching, read the current state yourself** — `git log
>    --oneline -20`, `git status`, and the relevant section of
>    `docs/PROGRESS.md` §1's table (now current as of session 22). Do not
>    dispatch an agent to redo something already done; three separate times
>    this session an agent's brief cited a stale doc claim ("not started",
>    "270 is correct") that a five-second `grep` would have caught.
> 2. **One agent, one file set, stated explicitly in the prompt** — name every
>    file it owns and every file it must NOT touch, including which other
>    concurrent agents hold which files. The git index is shared across all
>    of them; a bare `git add -A` in one sweeps up everyone's unstaged work.
>    **Never let an agent run `git add`, `git commit`, `git stash`, or
>    `git checkout --` as a mutation-restore** when a concurrent writer might
>    be touching the same file — `git checkout --` restores to HEAD, which
>    discards *anyone's* uncommitted work, not just the mutator's own. Back up
>    to the scratchpad and restore with `cp` + `cmp` instead; this bit twice
>    tonight and both times the agent caught itself and reported it rather
>    than silently losing work.
> 3. **Give every agent the full context it needs to make judgment calls**,
>    not a narrow instruction — cite the exact measured values, the exact file
>    paths, the exact prior findings, and the decisions already made (so it
>    doesn't re-litigate them). The agents that produced the sharpest,
>    hardest-to-see catches this session (the locale bug, the 270→90 patch
>    error, the composed-path dodge, the `$SUDO -u` bug) were all given real
>    evidence to reason from, not just a task title.
> 4. **Require mutation-testing on every new assertion**, and require the
>    report to say "N/N caught" with the specific faults named — not "tests
>    pass". `docs/PROGRESS.md` §7's §5.30c catalogue exists because this
>    project has repeatedly shipped checks that could not fail; the discipline
>    that fixed it is asking for the negative proof every time.
> 5. **Verify agent claims yourself before committing them** — re-run the
>    suite it claims is green, spot-check the one or two most load-bearing
>    assertions, and for anything touching the physical Deck, re-verify the
>    live state with a read-only SSH check before trusting a report. This
>    session found stale/wrong claims in agent reports at least twice by doing
>    exactly this, and both times the correction was cheap because it was
>    caught immediately rather than compounded.
> 6. **Commit in scoped batches once suites are green**, `git add` naming
>    exact files (never `-A` while other agents may be mid-flight), with a
>    commit message that states what was found and why it matters, not just
>    what changed — that is what makes `git log -S` and `git log --oneline`
>    useful to the next session instead of noise.
> 7. **Never run Docker, QEMU, makepkg, or a real ISO build on this machine**
>    — every agent prompt this session said so explicitly, and every agent
>    respected it. The one thing phase 2 still needs (`iso/bin/build`) is a
>    supervised, deliberate exception, not something to slip into a routine
>    dispatch.
> 8. **Anything that writes to the physical Deck needs the operator's
>    explicit go-ahead, batched and ordered by blast radius**, with the exact
>    command sequence and an undo for each step stated up front. Read-only
>    `ssh` checks (state probes, `journalctl`, `udevadm info`) do not need
>    this and are cheap — use them liberally to convert INFERRED claims to
>    MEASURED ones before proposing a write.
>
> **A concrete starting split for the next session**, following this shape:
> one agent for `input.lua`'s bake-in (needs `deck_monitors.py`'s sibling
> guard, cite it), one agent for the §5.24a #1 lock-wake-gate investigation
> (read-only Quickshell/QML tracing, likely no Deck needed to *diagnose*), and
> — separately, when the operator is available for a supervised session — the
> `iso/bin/build` run itself, which is not an agent task at all.
>
> ---
>
> ### ✅ THE RELEASE BLOCKER IS CLOSED, AND SO IS ONE PHASE-2 EXIT CRITERION
>
> **§5.28 is done** — verified on a cold boot, twice, by pressing the buttons
> before touching anything. The journal shows the race happen at 18.157 s and
> the resolver close it at 19.159 s, one service start, nothing restarted by
> hand. **The Gaming→Desktop switch path passes too**; it had never been tested.
>
> **Exit criterion 2 (hardware parity on OLED) is CLOSED.** Batch 1 was 7/7;
> batch 2 (P2.3) was measured on hardware with the operator present — fan
> control proven (commanded 2500 → **2568 RPM**), TDP proven (15 W → **10 W** →
> 15 W), charge limit proven (0 → **80** → 0), every value restored to its
> recorded baseline. `docs/findings/hardware-parity.md`.
>
> ### 🎹 The on-screen keyboard was rebuilt against MEASURED pixels
>
> The operator's standard was *"identical"*, and ours was a **different
> keyboard** — 10 number keys vs 13, no `Tab`/`Caps`/arrows/`Paste`/`Move`, a
> visible gap between halves, shifted glyphs in the corner rather than stacked.
> Six `grim` captures of Valve's own keyboard (idle, Shift, Caps, each pad
> touched) became **`docs/findings/T8-reference-metrics.md`** — hex palette,
> row heights, key spans, badge diameters — and §9g/§9f of
> `docs/tasks/T8-onscreen-keyboard.md`.
>
> Now, **all confirmed on the panel**: one continuous grid, **key widths within
> 1.5 px of the reference on all 63 keys**, square corners, white-face-plus-blue-dot
> cursors, per-pad badge gating, `X`→Backspace, `L3`→Caps, hold-to-Shift, pad-click
> commit, and **touch input**.
>
> 🔴 **Two bugs hid under one symptom.** "Keys don't type what they should" was
> *both* the session's `latam` keymap **and** `press_at` resolving in the
> addressing metric while the renderer drew in the proportional one — **287 of
> 1010 sampled positions committed a different key than the one drawn white.**
> Fixing either alone would have left the other.
>
> ### 🔬 SEVEN measurement tools lied today. Read this before trusting a check.
>
> `docs/PROGRESS.md` §5.30c tabulates the class. **The passing state was
> indistinguishable from the not-having-run state** in every case:
>
> - `hyprctl eval 'return X'` prints `ok` and exits **0** for names that never
>   existed — and it was **documented as a verification procedure**
> - A `grep` citing a path that does not exist: exit **2** reads exactly like
>   "no match". The conclusion survived re-checking; the evidence never existed
> - The P2.9 runbook's pre-flight gate printed "all suites green" **regardless**
> - `test-iso-build.sh`'s `configerrors` check was empty *precisely when* the
>   file had been discarded
> - `vm-kernel-idempotency-test.sh`'s entire verdict was vacuous — two empty
>   snapshots diff clean
> - The `[V]` harness blamed upstream's wizard for a disagreement **its own
>   CP437-in-UTF-8 grep had manufactured** (35/40 → **57/57**, no upstream defect)
> - 🔴 **`vm-gamepad-spike-test.sh`'s in-guest probe was a bash syntax error from
>   the day it was committed.** `bash -n` cannot see inside a quoted heredoc.
>   ✅ **FIXED in `b96eaac` — the same commit that found it. Verified 2026-08-12
>   by extracting the probe at four refs**: broken at `861f922` and at
>   `b96eaac^` (line 230, `syntax error near unexpected token 'fi'`), parses at
>   `b96eaac` and at HEAD. *(This bullet said "has never been runnable" for a
>   session after it had been repaired — a stale 🔴 is as misleading as a stale
>   ✅.)* ⚠️ **Still true and still the point: the suite has never been RUN.**
>   The T2 result it is cited for came from a version never committed, so its
>   next run is a first run and its assertions are unverified.
>   🆕 The scanner that was supposed to catch this only ever checked **8 of 19**
>   guest payloads — it matched the literal delimiter `<<'PROBE'`, so every
>   `<<'PAD'`, `<<'PY'`, `<<'TUI'` and `<<'UD'` block was invisible, **including
>   this suite's own virtual gamepad**. Now every quoted heredoc in `test/vm/`
>   and `test/lib/` is extracted and syntax-checked in its own language, with a
>   positive control under a delimiter that appears nowhere in the repo.
>
> ➡️ **The generalisation, now recorded: a check that proves something is ABSENT
> must also prove it was LOOKING.** New scanners carry positive *and* negative
> controls.
>
> ### 🟢 T5 IS UNBLOCKED — parity proven, and T5b/T5c landed
>
> `docs/findings/T5a-parity.md`: the fork's build **was** producing a broken
> ISO — a runtime 50 commits past the pin, missing `omarchy-setup-system`, dying
> at **phase 5 of 14**. T5b's `--local-source` fixed it; the pinned build carries
> `4.0.0.r1617.g6d7826d-1`, **exactly the reference's**. Parity re-measured under
> §7's four tests: **all pass**, every difference temporal. Of 1180 same-version
> packages, **1177 are byte-identical** — the 3 exceptions are our own builds.
>
> ⚠️ **T5b sat unmerged for hours** while work was built on a stale `bin/build`.
> Merged now (282 → **731 lines**). **Check `git log` before assuming a slice
> landed.**
>
> **T5c landed**: Valve's repos, the Deck's packages, and an NVIDIA guard with a
> negative control. It found §3.8 wrong three ways — `lib32-vulkan-radeon` alone
> does **not** drop NVIDIA to zero, and `linux-firmware-nvidia` ships in every
> install, so "zero NVIDIA" was never literally achievable.
>
> ### ✅ EVERYTHING BELOW WAS VERIFIED ON THE PANEL, 2026-08-12
>
> The operator tested each of these on hardware and confirmed it. Do not
> re-litigate them; if one regresses, it regressed.
>
> Keys type what they draw · the highlighted key matches what appears · pad-click
> commits · **hold L2, aim left, click** works one-handed · finger touch types ·
> a lifted pad's click stays silent · the aiming circle vanishes on release ·
> haptics fire on pad click · the pointer does not jump on lift · the keyboard
> hides for the screensaver · **and it does NOT hide under a lock**.
>
> ### The next actions

>
> 1. ✅ **T5d — DONE 2026-08-12.** The phase patch and its four files are
>    promoted into `iso/overlay/` (one copy each, at their shipped paths), the
>    payload audit is wired into `bin/build` as guard 6.5, and the
>    `omarchy-deck` package skeleton builds through four wiring points that all
>    read one derived list. The coupling is now **mechanical**, not a README
>    warning: `test-iso-build.sh` derives every relative import *and* every
>    `source`d absolute path a promoted patch introduces and demands a file
>    behind it.
> 2. **T5e/T5f/T5g** — bake-ins (now **four** rotations, not three), then CI.
> 3. ✅ **T4's two missing mapper features EXIST** — `--osk-start-shown` and the
>    `deck-input-mapper: bound` readiness marker, which means *the keyboard is
>    drawn*, not merely requested. S1's passphrase prompt no longer degrades by
>    construction. ⚠️ **Still open, and the same trap one file over:**
>    `src/deck-form.sh` has **no route onto the ISO at all** — no overlay copy,
>    no `configurator` patch — so the form it implements cannot run yet.
> 4. **Deck-only:** P2.1's Gaming-Mode button mapping, §5.24a #1 (its #2 and
>    #3 closed 2026-08-12 — see below, don't re-open).
>
> ⚠️ **Two things have never actually run:** a real build with T5c's overlay
> (its patches apply and its guard fired against live repos, but the container
> run is inferred), and `vm-gamepad-spike-test.sh`.
>
> **Phase 2 has the parts and lacks the assembly.** Criteria 1, 3 and 4 all
> converge on one thing: build our ISO, boot it, install with a controller.
> That has still never happened.
>
> **Git: 56 commits on 2026-08-12, all pushed. 24 suites.** Verify with
> `git rev-list --left-right --count origin/main...main`, never by trusting this
> line. Deck snapshots to **#13** (`pre-OSK-parity`).
>
> ### ✅ The P2.9 Deck session is COMPLETE — all seven sections
>
> | § | Result |
> |---|---|
> | 1 | Live-ISO lizard knob **exists, 0644, write accepted** → **T4's design gate is OPEN** |
> | 2 | Fallback `Y→N→Y→N` on hardware; Deck runs **systemd 261**, same as the verification bed; 22 ms recovery from cgroup SIGKILL |
> | 3 | **QAM = `BTN_BASE` (294)**, measured with delimiters, wired, deployed |
> | 3.1 | All four button behaviours, diagonals included |
> | 4 | **Lock fix verified IN PIXELS** — keyboard summoned over the lock, password typed with trackpads, unlocked |
> | 5 | **Both rotations upright**: Limine `interface_rotation: 90`, TTY `fbcon=rotate:1` |
> | 6 | Boots to Gaming Mode (`Session=gamescope-wayland`) |
> | 7 | **7/7 parity rows** — P2.2's human rows are closed |
>
> **Deck state:** snapshot **#10** (`post-P2.9`), boots to Gaming Mode, lizard
> `N`, mapper active, `omarchy-sleep-lock` masked, both rotations live.
>
> ### Facts worth more than the checkboxes
>
> - **`interface_rotation: 270` was 180° WRONG.** `90` is correct. That is the
>   **second** rotation value in this project inferred, written down, and found
>   inverted (the desktop's was recorded `1`, is `3`). **Four surfaces, four
>   mechanisms, four values that do not follow from one another.**
> - **`limine.conf`'s header SURVIVES `limine-update`** — measured by running it
>   and re-reading the file. Hand-edited globals persist; only entry blocks are
>   regenerated. T5 therefore owes **three** rotation bake-ins, not two.
> - **Live ISO console is `50 160`; the installed TTY is `25 80`.** Same panel.
>   **Read console geometry at runtime.** 80×25 is the case T4 §8's U3 feared.
> - **`pgrep -x gamescope` finds nothing while Gaming Mode is running** —
>   `comm` is `gamescope-wl`. `deck-session.sh` already guards this; it caught me
>   anyway.
> - **The live ISO's root shell is zsh WITH AUTOCORRECT** (it blocks on
>   `correct 'GREP' to 'grep' [nyae]?`) and root logs in with **no password**.
> - **Steam's Switch-to-Desktop REWRITES the default session** to `omarchy`,
>   undoing `stage-default-session`. ⚠️ **Open question for the operator:** does
>   stock SteamOS return to Gaming Mode after a reboot from Desktop Mode? That
>   decides whether this is a parity defect or a mis-worded checklist item.
>
> ### 🔴 `docs/RECOVERY.md` was WRONG and is now corrected
>
> Its escape had **never been executed against a real lock**. Over SSH `hyprctl`
> has no `HYPRLAND_INSTANCE_SIGNATURE`; once supplied,
> `clear_crashed_lockscreen` **refuses** — it clears a *crashed* lock, not a
> healthy one, and healthy is what the power button produces. **There is no
> unlock IPC at all.** Fixed against a real locked Deck.
>
> ⚠️ **Three runbook commands also failed as written** (`deck-sync.sh` missing
> its `src` argument, the QAM probe's `pads[-1]`, the snapshot number). **A
> procedure nobody has run is a hypothesis.**
>
> ### Landed from THREE of five parallel agents; two did not finish
>
> *(An earlier version of this section said "four agents, all merged". Wrong —
> corrected at close-out after checking the worktrees rather than memory.)*
>
> **Merged, 16 suites green:**
>
> - **T5a**: `iso/` skeleton — pins, submodule at `a12bfea`, `bin/build`, guards
>   6.1/6.3, `test-iso-build.sh`. 🔴 **The parity build's outcome is UNKNOWN** —
>   verified at close-out: no container, no ISO, no log survives. Treat parity as
>   **not run**. `T5-fork-plan.md` §7: do not start T5c before parity is proven.
> - The **lock-wake source trace**
>   (`docs/findings/T9-lock-wake-and-blank-timing.md`) — the 5 s blank is a
>   **hardcoded `interval: 5000`** in Omarchy's `lock/Service.qml`, matching the
>   hardware measurement exactly, from two independent directions.
> - **OSK auto-hide + SteamOS visual parity** (T8 §9) — `LockWatcher`, glyph
>   hints, shifted legends, divider since removed on the operator's eyes.
>   **Merged and deployed to the Deck; the restyle was seen on the panel.**
>
> **Not finished, work parked:**
>
> - ~~**The T4 installer-screens harness**: its agent never committed. Three
>   untracked files sit in a worktree; do not assume they work.~~
>   🟢 **CORRECTED 2026-08-12 — this is stale, and was already stale when it was
>   written down here.** All three files are **tracked on `main`**: salvaged in
>   `cca6ce5`, then actually run in `e476601`. `docs/findings/T4-harness-first-run.md`
>   records three runs — 35/40, 35/40 again, then **57/57 PASS** once the five
>   failures were fixed, **all five of which were the harness, not upstream's
>   wizard**. `test/unit/test-installer-harness-primitives.sh` is green in the
>   current baseline. Verify with `git ls-files`, not by re-reading this page.
> - **The T8 §9d layout-parity agent**: paused deliberately, plan-ready, zero
>   commits (see the T10 section below for why). The operator's two decisions it
>   was waiting on — **wire Y through then badge it; Caps/Shift option C** — are
>   recorded in `~/.claude/plans/proud-finding-wreath.md` and in T8 §9. If T10
>   says "our OSK", relaunch that work from those documents.
>
> **Git: everything through session 20 is on `main` and pushed.** Verify with
> `git rev-list --left-right --count origin/main...main`, never by trusting this
> line. Suites: **16** (run BOTH globs — `test/unit/test-*.sh` and `test-*.py`),
> plus `test/osk-tty-e2e.py` and `test/xtest-*.py` by hand.
>
> ### The three operator requests (§5.24a) — two closed 2026-08-12, one still open
>
> 1. 🔴 **STILL OPEN.** Only the power button should wake the *blanked lock
>    panel* (QAM currently does) — a Quickshell/Hyprland-side wake gate, not
>    the systemd suspend work below. Untouched this session.
> 2. ✅ **CLOSED.** Display-on ~20 s, not ~2 s. The overlay-patch seam this row
>    said "does not exist yet" is T12's, and it now does:
>    `0010-lock-blank-timer-20s.patch` was applied for real on the Deck and
>    verified on disk — `idleBlankTimer.interval` reads `20000`, not `250`.
> 3. ✅ **CLOSED.** OSK auto-hide after unlock — confirmed deployed and wired,
>    not just present in the file: the installed mapper's checksum matches the
>    source carrying `LockWatcher`, and all five of its call sites
>    (`start`/`tick`/`stop`) are live in the main loop, not dead code.
>
> ⚠️ Do not conflate 2/3 (systemd-level suspend/resume, this session's main
> event) with 1 (a lock-screen blank/wake timer inside Quickshell) — different
> mechanisms, different files, only 1 remains.
>
> ### 🆕 LATE IN SESSION 20: the Steam option was closed, then REOPENED — T10 decides it
>
> Full story: §5.29 and `docs/findings/P20-steam-xtest-closure.md` (R-53, R-54).
> One sentence: real XTEST reaches nothing on Hyprland (measured), but
> **extest** — the community's MIT LD_PRELOAD bridge converting Steam's XTEST
> calls to uinput — **does reach Wayland-native clients here (measured)**, so
> whether **Valve's own keyboard** can serve Desktop Mode now hangs on one
> untested link: Steam driving the bridge. **`docs/tasks/T10-steam-extest-spike.md`
> is a ~45 min Deck session that settles it**, artifacts prebuilt at
> `~/ISOs/extest-cb77cd4/`, rebuildable via `tools/build-extest.sh`.
>
> ⚠️ **Consequences for the queue:** the approved OSK touch/restyle plan
> (`~/.claude/plans/proud-finding-wreath.md`) is **ON HOLD pending T10** — do
> not resume the layout-parity work before T10 answers. Our OSK stays the
> installer's and the lock's keyboard in every outcome (Steam's is an XWayland
> window and cannot render above `ext-session-lock`). **Next Deck session
> opens with the §5.28 cold-boot check (now written up as
> `docs/tasks/T11-cold-boot-verification.md`, and it deploys the session-21 fix
> first), then T10, in that order** — §5.28 is the release blocker; T10 is a
> decision.
>
> ---
>
> ## Where things stood at the END of session 19 (kept; superseded above where they disagree)
>
> ### 🚩 READ THIS FIRST — session 19 was large, and it closed a phase
>
> **Phase 2.9 is DONE.** It began as "rebase onto the new 4.0 beta 2" and
> measurement showed **we were already on it** — same commit, same channel,
> same builder as upstream's published ISO. What the block actually bought was
> everything below.
>
> **The single most important thing on this page:** 🔴 **the power button locks
> the Deck into a password screen with no password field** (§5.24). Live today,
> nothing to do with the upstream delta, and the fix is approved and waiting for
> a Deck session (`docs/tasks/P2.9-deck-session-runbook.md`).
>
> **The next action is that runbook.** Five approved changes plus one read-only
> check, ordered by blast radius, with rollbacks. Everything else is queued
> behind it or independent of it.
>
> #### What landed in session 19
>
> | | |
> |---|---|
> | **Phase 2.9** | complete — pin measured from inside both ISOs, delta ahead of us classified (1 BREAKS US / 27 RE-VERIFY / 37 NO IMPACT), substrate rebuilt on the channel we ship, **all four VM suites green** |
> | **Twelve operator decisions** | §5.25 — all settled, do not re-litigate |
> | **Five new test suites** | stage integration (300 assertions), duplicated-facts, limine pin, ISO payload audit, plus auto-show. **15 suites total** |
> | **`stage-lizard-mode`** | ✅ the knob now follows the mapper's lifetime, **and the cgroup-kill hole is closed** — `OnFailure=` on a separate unit, all **eight** kill paths verified on systemd 261. No-input window: *until the next boot* → **106 ms** |
> | **OSK auto-show** | built and mutation-proven, **not shipped** — §5.27 names two hand-offs that must land together |
> | **The orphan bug** | ✅ fixed — a killed mapper could leave a watcher holding the Wayland seat, breaking a *later* mapper's auto-show permanently |
> | **T4** | screen spec written (**wrap** the configurator, 6 screens + a Failure screen §6.1a never had) **and its automated test tier proven viable** against a real ISO |
> | **T5** | fork plan written — and its first finding was that **the obvious fork point is broken** |
> | **The keyboard overdraw fork** | ✅ resolved, and it was **free**: T4's wrap means a curses TUI and the keyboard never coexist |
> | **`docs/RECOVERY.md`** | now answers "my screen is locked" with one command instead of a full reimage |
>
> #### Four findings that will bite whoever ignores them
>
> 1. 🔴 **Nobody has read the lizard-mode knob in the LIVE ISO** (§5.26). Every
>    such measurement came from the installed system on Valve's kernel. 🟡
>    Half-answered off-hardware since: the module ships in the ISO and `modinfo`
>    declares the parameter — so it is *likely* fine, but writability still needs
>    the Deck. **One line, from a booted USB. Step 1 of the runbook.**
> 2. 🔴 **`hyprctl layers` cannot verify the lock fix.** It reports the surface
>    identically whether the rule works or not; only pixels distinguish them.
>    Same shape as R-29, where every check passed while the mapper was a no-op.
> 3. 🔴 **The git ref and the package channel are two independent pins** and only
>    one is expressible in git (§3.10a). Forking `omarchy-iso` at the commit our
>    own ISO came from, and building today, yields an installer that calls a
>    binary the runtime no longer has.
> 4. ⚠️ **Session 19's real theme: four times a measurement TOOL lied, not the
>    code** — `grep` in a UTF-8 locale against CP437 glyphs, a console width
>    cached across a mode change, `hyprctl layers`, and `grep -c shift` on a
>    keyboard that had been destroyed. Each was caught by checking the
>    instrument rather than the reading. **When a result looks impossible, doubt
>    the tool first.**
>
> #### Where to start, concretely
>
> 1. Read `docs/PROGRESS.md` §1 (state), **§5.24** (the live lock defect),
>    **§5.25** (twelve settled decisions — do not re-litigate), §5.26/§5.27.
> 2. Then `docs/tasks/P2.9-deck-session-runbook.md` — that is the next action and
>    it needs the operator.
> 3. Deck-free work if the operator is unavailable: T5's fork (`T5-fork-plan.md`,
>    start at its slice 1) or T4's screens (`T4-screen-spec.md`, whose test tier
>    is now proven). ⚠️ T4's §8 lists five ranked unknowns; **U4 got sharper**,
>    not closed — `clear_logo` wipes the keyboard mid-typing and the mapper only
>    repaints on a pad sample, so a user who stops moving their thumb types blind.
>
> ### 🆕 UPSTREAM MOVED — there was a PHASE 2.9, and it is now COMPLETE
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
> 4. `docs/PROGRESS.md` §7 — **55** facts that each cost real time; do not
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
> **15 suites — 10 shell, 5 Python — seconds, no VM.** ⚠️ That is *two* globs:
> the shell one alone misses every Python suite, which is where the whole input
> layer's coverage lives.
>
> ⚠️ **Per-suite assertion counts are deliberately NOT listed here any more.**
> They have been wrong in this file four separate times — the numbers move every
> session, and a stale count reads as authority. Count them when you need them:
>
> ```bash
> for f in test/unit/test-*.sh; do printf '%-40s %s\n' "$f" "$(./"$f" | grep -c '^ok')"; done
> for f in test/unit/test-*.py; do printf '%-40s %s\n' "$f" "$(python3 "$f" | grep -c '^ok')"; done
> ```
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
| `docs/PROGRESS.md` | **Every session start. This is the authoritative state.** Scope, findings, open issues, and **55** facts not to re-derive. |
| `docs/SESSIONS.md` | Usage-limit budgeting and the block schedule. |
| `docs/PLAN.md` | **Frozen and partly superseded.** Read the banner at the top first. Good for §6.1a (installer screens), §8 (bug hypotheses), §9 (test tiers), §11 (maintenance risks). |
| `docs/tasks/` | One file per work block. **Start with `T11-cold-boot-verification.md`** — it is the next action, and it needs the Deck. Then `T10-steam-extest-spike.md`. |
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
| T9 | `docs/tasks/T9-beta2-rebase.md` | **Opus** | ✅ **phase 2.9 DONE (session 19).** We were already on beta 2 — measured from inside both ISOs. The block's value was the delta *ahead* of us, the substrate now pinned to the shipped channel, and four VM suites green on it. **Left:** P2.9e/f, folded into `docs/tasks/P2.9-deck-session-runbook.md` |
| T8 | `docs/tasks/T8-onscreen-keyboard.md` | Sonnet/**Opus** | ✅ **DONE (session 18) — all seven steps, hardware-proven (R-43) and console-sharing proven in QEMU (R-47).** Was P2.4b. Input half was already done in the mapper, chord included |
| T7 | `docs/tasks/T7-enablement-layer.md` | **Opus** | ⬜ **phase 4 — NEW.** Generalise into a Deck enablement layer so the next distro is ~a day. Deliberately after phase 3: abstracting from one *finished* example is engineering, from one unfinished example is guessing |

**Phase 1 is closed. P2.0, P2.0b, P2.0c and P2.0e are done**, and P2.1/P2.2/P2.4
are done as far as a script can verify them. Sensible entry points:

- **Without the Deck — this is where the remaining bulk is.** **P2.5/P2.6**
  (T4's installer screens; text entry is the real gap) or **P2.7/P2.8** (T5's
  `omarchy-iso` fork, which now carries six recorded constraints — see above).
  Either is days of work and needs no hardware.
- ✅ *(Retired — P2.9a–P2.9d are done, session 19.)* The Deck-free half of
  phase 2.9 is complete: pin measured, delta classified, substrate rebuilt on
  the `edge` channel with the boot chain asserted, all four VM suites green.

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
