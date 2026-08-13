# T4 controller-only install — first run against the real Deck-forked ISO

**Date:** 2026-08-13 · **Task:** phase 2 exit criterion 1 (P2.5/P2.6,
"Controller-only QEMU install from our ISO") · **Tier:** `[V]` (QEMU, the
real built ISO, gamepad-equivalent input via QMP send-key)

**Subject under test:**
`~/.cache/omarchy-deck/iso-build-2/release/omarchy-2026.08.13-x86_64-quattro.iso`
(6.39 GiB, sha256 `336f35715086604e75940d6baebc767d10b59c8714f845ca6640ae51f413f782`),
the first ISO ever built from this repo's full patched tree — carries all 5
overlay patches, `deck-form.sh`, `deck-dashboard.sh`, the `omarchy-deck`
package. `test/vm/vm-installer-screens-test.sh` was migrated to drive it
(this session) and run three times. Repo HEAD at the start of this session:
`39d0da6`.

This is a genuine first: nobody has driven a Deck-forked ISO through the
installer wizard before, on hardware or in QEMU. The tags below follow this
project's convention: **READ** (source), **MEASURED** (this session's runs,
with the exact capture cited), **INFERRED** (reasoning, not run).

---

## 0. Bottom line

- **The migration described in `vm-installer-screens-test.sh`'s own header
  ("swap the marker strings ... the whole migration") was NOT sufficient.**
  Running the pre-migration harness against the real ISO first (as this
  session's instructions required) surfaced a structural fact the spec did
  not predict: **most of `deck-form.sh`'s advertised screen overrides are not
  wired up on this build.** Only `greeter` (S0), `omarchy_prompt_username` /
  `omarchy_prompt_password` (S3's credentials half), `disk_form` and
  `confirm_disk_overwrite` (S4) are confirmed active. `omarchy_prompt_identity`,
  `omarchy_prompt_hostname` and `omarchy_prompt_timezone` are **not** —
  upstream's own unmodified "Full name>", "Hostname>" and flat scrollable
  "Timezone" list run verbatim. See §2.
- **After fixing the harness to match that reality**, a controller-equivalent
  (QMP send-key) run navigates **cleanly and safely** from the Deck's own S0
  disclosure screen all the way through S4's disk-overwrite confirm and into
  a previously-unproven screen, **S5's `deck_final_summary`** — the LAST gate
  before `write_user_files` runs. **59/62 checks pass** (§4). This is further
  than any run of this harness has ever gone, against real Deck-branded UI
  that did not exist before this session.
- **The 3 failing checks are a real, reproducible, measured defect**, not a
  broken harness expectation: the username field's on-screen `[deck-form]
  WARNING: ...` diagnostics are never cleared between retries, so the
  console grows without bound on repeated invalid input (§5). Left failing
  on purpose, per this project's "diagnose it, don't force the test to
  pass" instruction.
- **The Deck-side disk-encryption default flip (T4-screen-spec.md §2.2 item
  1) is PROVEN, not inferred**, for the first time: pressing Enter on the
  disk-confirm screen does not start the install (three byte-identical
  captures across a decline-and-redraw loop, §6), and gum's own advertised
  `y` hotkey is what's needed to proceed.
- **The run stops at S5's "Ready to install?" gate, deliberately** (§7) —
  one gate short of `write_user_files` and a real (deliberately tiny,
  misaligned) partition attempt. This is the "screens navigate cleanly
  through to the point of commit" partial result the task explicitly allows
  for, not a forced or incomplete pass.
- One more real defect found in passing: `/usr/local/bin/deck-input-mapper`
  **does not exist on this build** (§8), so every text-entry screen degrades
  to "no on-screen keyboard" — exactly the degradation path §2.3 of the spec
  designed for, now confirmed to actually engage.

---

## 1. What was done, in the order the task asked for

1. Read `test/vm/vm-installer-screens-test.sh`, `test/lib/vm-installer-screens.sh`,
   `docs/tasks/T4-screen-spec.md` (all of §4), and `test/vm/vm-install-test.sh`
   in full before touching anything.
2. Ran the **pre-migration** harness, unmodified, against the real ISO
   (`VM_KEEP_WORK=1 ./test/vm/vm-installer-screens-test.sh <iso> <workdir>`,
   run 1, work dir preserved). This was expected to diverge — the script's
   own header says its absent-`deck-form.sh` assertion alone guarantees it —
   and it did: `deck_form_present=1` (report), and the guest's own
   greeter-detection loop spun for the full 300s because the upstream marker
   `"Press Return to Start Install"` never appears on this ISO. The blind,
   unmigrated 28-key sequence was then sent anyway (by design — the probe
   doesn't gate on `found`) and produced **35/47** checks passed, diverging
   first at "summary confirmed -> disk picker" and cascading from there.
   This run is what actually taught the real screen text and flow order
   used to write the migration below — reading `deck-form.sh`'s source
   alone had produced a WRONG model of the flow (§2).
3. Migrated the harness: S0 marker swap, `deck_form_present` assertion
   flipped to expect 1, S0 disclosure-text assertions added, the disk-confirm
   tail (steps 26–28) rewritten around the measured reality, the encryption
   assertion inverted (Deck's default is OFF, not upstream's ON), a new
   `user_encrypt_installation.txt` artefact check added, and the file's own
   header rewritten to document the migration and the identity/hostname/
   timezone finding (so a future reader isn't misled by the spec's
   prediction of a two-level timezone picker that doesn't run).
4. Ran the migrated harness twice more (runs 2 and 3) — run 2 to find that
   the disk-confirm tail's hypothesis about what `y` would do was itself
   wrong (§6), run 3 (after correcting that) to get a clean final count.
   Runs 2 and 3 are used as the primary evidence below; run 1 (preserved at
   `/tmp/.../scratchpad/run1`) is the "as originally written, against our
   ISO" baseline the task asked for.

All three work dirs were preserved (`VM_KEEP_WORK=1`) for this report and are
still on disk at the time of writing:
`/tmp/claude-1000/-home-huyke-Pizzarchy/69fa8f47-480f-4724-b93e-9fdecaf99299/scratchpad/{run1,run2,run3}`.

---

## 2. The screen-override finding: most of `deck-form.sh` is not wired up

**MEASURED**, run 1, captures `x.21-fullname`, `x.23-hostname`, `x.24-timezone-list`.

`deck-form.sh`'s own header claims `omarchy_prompt_identity`,
`omarchy_prompt_hostname` and `omarchy_prompt_timezone` are overridden
(items 3, 6, 10 in its changelog). On the real ISO, `/dev/vcs1` shows
upstream's own, completely unmodified prompts instead:

```
--- x.21-fullname (captured right after the account password was confirmed) ---
Let's setup your user account...
[deck-form] WARNING: ... (four rounds of blocking-test warnings, see §5)
deck
Full name> Used for git authentication (hit return to skip)
enter submit
```

```
--- x.24-timezone-list ---
Timezone
  America/Merida
  America/Metlakatla
> America/Mexico_City
  America/Miquelon
  ...
  navigate  enter submit
```

Upstream's own field name (`"Full name>"`, upstream's exact placeholder
text) and upstream's own flat, single-level, geo-guessed `gum choose`
timezone list — not `deck-form.sh`'s two-level Area/City picker
(`omarchy_prompt_timezone`, `T4-screen-spec.md §3` deviation 3) — are what
actually ran.

**What IS confirmed overridden**, by direct on-screen evidence the upstream
code cannot produce:

- **`greeter` (S0)** — the Deck disclosure text and "Press A to begin" are
  on screen; upstream's own greeter has no such lines at all (READ,
  `configurator`'s `greeter`).
- **`omarchy_prompt_username` / `omarchy_prompt_password` (S3, credentials
  half)** — `[deck-form] WARNING: mapper not found at
  /usr/local/bin/deck-input-mapper -- this prompt runs WITHOUT the
  on-screen keyboard` is printed directly to the console. That exact string
  only exists in `deck_form_text_prompt` in `deck-form.sh`; upstream's own
  `_username`/`_password` cannot produce it.
- **`disk_form` / `confirm_disk_overwrite` (S4)** — `"Everything on ... will
  be erased. There is no recovery."` / `"This install is not encrypted, so
  the Deck can start without anyone typing a passphrase."` / `"Yes, erase
  and install"` / `"No, go back"` are `deck-form.sh`'s own text, verbatim
  (§6).
- **`deck_final_summary` (S5)** — a NEW function name, not an override
  (§1.2 patch P1 hunk 2), confirmed present and reachable (§7).

**Why this matters, and what it does not mean.** This is precisely the
failure mode `T4-screen-spec.md` §7's own guard G1 exists to catch: *"An
override that misspells a name is a screen that silently reverts to
upstream's — the exact failure class this project keeps hitting."* Whether
the root cause is a real name mismatch (e.g. upstream's actual function
names on this build being `_identity`/`_hostname`/`_timezone` rather than
`omarchy_prompt_identity`/`_hostname`/`_timezone` — `deck-form.sh`'s own
header records this as a point of internal uncertainty resolved by reading
rather than by testing), a build/patch-application gap specific to those
three overrides, or version drift in upstream's `quattro` branch since the
spec's own reads, was **not** determined this session — diagnosing it means
reading `configurator`/`setup-form.sh` as actually vendored into *this*
built ISO, which is `deck-form.sh`/T5 territory, not this harness's. It is
recorded here as a confirmed, reproducible (both runs 2 and 3 show the same
thing — see the bit-identical `x.06-username-empty-4` hash in §9) fact for
whoever owns `deck-form.sh` next, and flagged as a spawned follow-up (§10).

**Consequence for this file:** the harness's marker strings for the
identity/hostname/timezone portion of the flow were **deliberately left as
upstream's own text**, not migrated to Deck-branded strings the spec
predicted — migrating them would make the suite pass while asserting
something false about the real ISO.

---

## 3. The re-measured flow

```
greeter (Deck disclosure text, "Press A to begin")
  --ret--> [S1 Wi-Fi runs HERE, inline, before any capture: no wlan0 in
            QEMU, resolves to "No Wi-Fi hardware found -- continuing
            offline" with no keypress needed -- inferred from timing, not
            directly captured (see §8, the transient-screen caveat)]
  keyboard list (cursor: US, upstream's own, unoverridden)
  --down--> keyboard list (cursor: UK)
  --ret--> username (empty) -- deck-form.sh's OWN prompt, degraded (no OSK,
           mapper absent, see §8)
  --ret x3 (BLOCKING NEGATIVE TEST: does not advance, but see §5's real bug)
  --d,e,c,k--> "deck" (LIVE ECHO, guard 2)
  --ret--> password (empty, masked) -- also deck-form.sh's
  --p,a,s,s--> (masked)
  --ret--> confirm (empty, masked)
  --p,a,s,s--> (masked)
  --ret--> full name (empty; "hit return to skip") -- UPSTREAM'S OWN (§2)
  --ret--> email address (skip) -- upstream's own
  --ret--> hostname (skip -> default "omarchy") -- upstream's own
  --ret--> timezone list (flat, geo-guessed default pre-selected) -- upstream's own
  --ret--> SUMMARY TABLE (upstream's own `user_step` recap, default "Yes")
  --ret--> disk_form auto-skips the picker (one eligible disk, the result
           device) straight into confirm_disk_overwrite -- deck-form.sh's OWN
  --ret--> DOES NOT ADVANCE (§6: the Deck safety flip, PROVEN)
  --y--> deck_final_summary (S5) -- deck-form.sh's OWN, NEW (§7)
  STOP. No further key sent.
```

Compare against the pre-fork flow this same file drove before today (upstream
unmodified, `docs/findings/T4-harness-first-run.md`): identical through the
recap table, then diverges completely — the pre-fork run's disk picker,
"Yes, install" default, and immediate failure menu do not describe this ISO
at all.

---

## 4. Final result

Run 3 (`/tmp/.../scratchpad/run3`), against the corrected harness:

```
59/62 checks passed
```

The 3 failures are all in §5 (the same real defect, not 3 different bugs).
Every other check — environment invariants, S0's disclosure text, guard 1
(advance-and-vanish) at every transition, guard 2 (live echo), the masked
password/confirm fields, the summary-vs-artefact table pairing for the
fields that did run through upstream's own path, the disk-confirm's
Deck-branded text and safety-flip guard, and S5's full field/value table —
passed.

Run 2 (before the step-28 hypothesis was corrected) got 50/59; the extra 3
failures there were the harness's own wrong guess about what `y` would do,
not the product — see §6 for exactly what changed and why.

---

## 5. Real defect found: the username retry screen never clears

**MEASURED**, runs 2 and 3, bit-identical.

Guard 4 (S3's blocking negative test — three empty-username submits must
leave the screen provably unchanged, `T4-screen-spec.md §6.4` lie #4)
failed, and unlike the two previous times this guard has fired in this
project's history (`docs/findings/T4-harness-first-run.md` §3.1, a wrong
harness expectation about a one-row repaint), **this one is real**:

```
rows=16  (03-username-empty, before any submit)
rows=22  (04-username-empty-2, after submit 1)
rows=28  (05-username-empty-3, after submit 2)
rows=34  (06-username-empty-4, after submit 3)
```

Growing by exactly 6 rows on every attempt, not settling. The cause,
visible directly in the captures: `omarchy_prompt_username`'s
`deck_form_text_prompt` call prints three `[deck-form] WARNING: ...` lines
to the console on every invocation (lizard-mode-absent, mapper-not-found,
the validation message) and — unlike upstream's own `notice()` /
`clear_logo` repaint path, which the pre-fork measurement showed drops one
line and holds — **never clears them**. By the fourth capture the screen
carries 20+ warning lines above the live prompt.

**This was left failing, not weakened.** Relaxing the assertion (e.g. back
to "Username> is still present") would hide a real, reproducible UX defect:
on real hardware, with the OSK actually drawn (unlike this QEMU run, see
§8), a user who mistypes a username a few times would watch the keyboard
and prompt get pushed further down the console on every attempt, and
eventually off it. This is exactly the class of bug `T4-screen-spec.md`
§6.4's guard 4 exists to catch, and it caught a real one this time.

The three still-passing assertions after this ("username prompt is still
the live screen", "did NOT reach the password step") confirm the *blocking*
property itself holds — the wizard genuinely does not advance past the
empty field. What fails is the *stronger* "the screen state is stable"
claim, which is the correct thing to fail on.

---

## 6. The disk-confirm safety flip: PROVEN, and a wrong first hypothesis corrected

**MEASURED**, runs 2 and 3.

`T4-screen-spec.md §2.2` item 1 argues the Deck must default the
disk-overwrite confirm to declining, because there is no Ctrl key to invoke
upstream's own encryption-off toggle and an accidental affirmative Enter on
a device with no keyboard would be unrecoverable. `deck-form.sh`'s
`DECK_DISK_CONFIRM_DEFAULT=false` is that flip. This run proves it, not just
reads it:

```
$ sha256sum x.26-disk-confirm x.27-disk-confirm-holds
a59a4aa60af257aaf94b5aa8c30807de7b8016eb37fd51b211998e89517d38d3  x.26-disk-confirm
a59a4aa60af257aaf94b5aa8c30807de7b8016eb37fd51b211998e89517d38d3  x.27-disk-confirm-holds
```

Two captures, one Enter press apart, byte-for-byte identical — pressing
Enter on this screen does **not** start the install; it redraws the same
confirm screen (`disk_form`'s single-eligible-disk autoselect re-running).
This is the S4 analogue of guard 4's "a guard nobody has seen fail" —
before this run, the flip was a source-read claim; now it is a measured one.

**What crosses the gate:** the widget's own on-screen hint,
`toggle  enter submit  y Yes, erase and install  n No, go back` — `y` is
gum's advertised hotkey for the affirmative choice, not a guessed arrow
direction (`/dev/vcs1` carries no color/highlight attributes, so which
button has *focus* is not otherwise determinable from a text capture; this
project's other harnesses have hit this same limitation before).

**The wrong first hypothesis, and how it was found and fixed within this
session:** run 2's version of this harness assumed `y` would cross straight
to `write_user_files` and the failure menu (the pre-fork flow's shape). It
did not — `x.28-failure` from run 2 (preserved, sha256
`7be1474aae547d3a357437d8e1df6e6c12efb6dc676d86ff7c4af1cb8ded1356`) turned
out to be `deck-form.sh`'s own `deck_final_summary` screen (§7), not the
failure menu. The assertions were rewritten against that real capture
(not against a fresh guess) and re-run as run 3, which confirms the fix:
the same capture bytes, now correctly identified and asserted on.

---

## 7. New screen proven: S5 `deck_final_summary`

**MEASURED**, run 3, `x.28-deck-summary`:

```
+------------------------------------+
| Field      | Value                |
+------------------------------------+
| Username   | deck                 |
| Password   | ****                 |
| Hostname   | omarchy              |
| Timezone   | America/Mexico_City  |
| Keyboard   | uk                   |
| Wi-Fi      | Not connected        |
| Disk       | 0x1af4 (  64M)       |
| Encryption | Off                  |
| Desktop    | Omarchy              |
| Boot       | Gaming Mode          |
+------------------------------------+
Without a network the install still completes, but the audio DSP firmware
and Steam are not downloaded. Speakers will sound thin and Gaming Mode will
have no Steam until the Deck is connected. Wi-Fi can be set up from Desktop
Mode afterwards.
 Ready to install?
    Install        Go back
 toggle  enter submit  y Install  n Go back
```

This is `deck-form.sh`'s own new function (`deck_final_summary`, T4-screen-spec.md
§1.2 patch P1 hunk 2: `deck_final_summary || abort`, placed immediately
before `write_user_files`) — **confirmed present, reachable, and correctly
populated** (all ten rows match what was actually typed/selected earlier in
the run — username, hostname, timezone and keyboard visibly agree with the
values from the earlier, upstream-driven recap table). The Wi-Fi-offline
consequence sentence from `T4-screen-spec.md §5` is present verbatim. This
had never been observed before this session — it postdates the disk
confirm, not upstream's own recap, exactly as the spec's patch-hunk
placement describes and exactly opposite to where the ORIGINAL (unmigrated)
version of this test file assumed a summary screen would be (before the
disk picker, matching upstream's own `user_step` recap position).

This is where the run deliberately stops (§0, §1). One more `y` here would
cross into `write_user_files` and a real (tiny, misaligned, fails-fast)
partition attempt — a legitimate next step for a follow-up run, not
attempted this session due to the same host-side caution this file's own
header already documents (see below).

---

## 8. `deck-input-mapper` is absent from this build

**MEASURED**, every text-entry screen's capture, e.g. `x.03-username-empty`:

```
[deck-form] WARNING: lizard-mode knob not present at
/sys/module/hid_steam/parameters/lizard_mode -- not applicable here
(expected under QEMU, T4-screen-spec.md §2.3), continuing without touching it
[deck-form] WARNING: mapper not found at /usr/local/bin/deck-input-mapper
-- this prompt runs WITHOUT the on-screen keyboard
```

`/usr/local/bin/deck-input-mapper` does not exist on this ISO build. This
means every text field this run drove ran in the **fully degraded** path
`T4-screen-spec.md §2.3` designed for (no OSK, plain console input) — which
did engage correctly (username/password typing still worked via the
QMP-sendkey path directly into the console, same mechanism the pre-fork
harness always used) — but it also means **this run never exercised the
on-screen-keyboard half of S1/S3 at all**, only its absence-handling.
Whether the mapper's exclusion from this particular build is expected (a
staging/packaging gap in `iso/bin/build`'s payload set, out of this
session's scope — `iso/` and the mapper itself are explicitly owned by a
concurrent agent this session) or a real regression was not determined here
and is flagged for follow-up (§10).

The lizard-mode sysfs knob being absent (`hid_steam.loaded=0` in every
report) is expected and already documented — QEMU has no `hid_steam`
(guard 5, `T4-screen-spec.md §6.4`).

**Caveat on the S1 Wi-Fi transition:** the "no wlan0 -> continue offline"
branch is inferred from timing (the flow reaches the keyboard list within
one 6-second step window with no extra keypress needed) and from the S5
summary's own `Wi-Fi | Not connected` row, not from a direct capture of the
transient "No Wi-Fi hardware found" text — that screen is drawn and cleared
between two capture points and this harness does not currently capture it.
A follow-up run could add a dedicated capture step for it if proving that
specific line is ever needed.

---

## 9. Determinism

Every capture common to runs 2 and 3 is byte-for-byte identical, including
across the corrected assertions:

```
x.00-greeter              174ca70f...  (both runs)
x.26-disk-confirm         a59a4aa6...  (both runs)
x.27-disk-confirm-holds   a59a4aa6...  (both runs, and equal to x.26 -- §6)
x.06-username-empty-4     85aaf39f...  (both runs -- the growth bug, §5, reproduces exactly)
x.28 (deck_final_summary) 7be1474a...  (both runs, under its old and corrected names)
```

Two independent boots, same bytes throughout. This is what makes the guard-4
failure in §5 trustworthy as a real defect rather than a flaky capture.

---

## 10. Follow-ups flagged (not fixed here — out of this session's file scope)

1. **Diagnose why `omarchy_prompt_identity`/`_hostname`/`_timezone` don't
   override** (§2) — likely a name mismatch against this build's actual
   `configurator`/`setup-form.sh`, or a build-time gap. Owner: whoever next
   touches `iso/overlay/.../deck-form.sh`.
2. **Fix the username-retry screen growth** (§5) — clear or cap the
   `[deck-form] WARNING:` output between retries, matching upstream's own
   `notice()`/`clear_logo` behaviour. Real, reproduced, not cosmetic.
3. **Confirm whether `deck-input-mapper` should be present on this build**
   (§8) and if so, why it isn't — a payload/packaging question for `iso/bin/build`'s
   guards (`tools/iso-payload-audit.sh`), not this test harness.
4. **A follow-up `[V]` run should press one more `y` on `deck_final_summary`**
   to reach `write_user_files` and the real (tiny, deliberately-misaligned)
   partition attempt, proving the pairing between S5's shown values and the
   actual `user_configuration.json`/`user_credentials.json` artefacts on
   this ISO specifically (the pre-fork run already proved this mechanism
   works against upstream's own recap; it has not yet been proven against
   `deck_final_summary`'s values). This session stopped short of that
   deliberately (§7), for the same class of reason (a real, tiny but
   destructive-in-QEMU action) the pre-fork harness already stops before
   the failure menu's default "Upload log for support".
5. **`[H]` full hardware install is still entirely unattempted** — this
   session's result is `[V]`-tier only, QMP send-key (lizard-mode-equivalent
   navigation, guard 5), never the real Deck HID. Phase 2's exit criterion
   needs both this tier (now materially closer) and an `[H]` pass.

---

## 11. Files

- `test/vm/vm-installer-screens-test.sh` — migrated: S0 marker, `deck_form_present`
  assertion flip, S0 disclosure assertions, disk-confirm tail rewritten
  around the measured S5 discovery, encryption assertion inverted,
  `user_encrypt_installation.txt` artefact check added, guard-4 finding
  documented in place rather than weakened.
- Preserved work dirs (`VM_KEEP_WORK=1`): run 1 (pre-migration baseline,
  35/47), run 2 (migrated but with the wrong step-28 hypothesis, 50/59),
  run 3 (corrected, 59/62) — all under
  `/tmp/claude-1000/-home-huyke-Pizzarchy/69fa8f47-480f-4724-b93e-9fdecaf99299/scratchpad/`.

---

## 12. 2026-08-13 (later session) — both §10 bugs root-caused and fixed

Owner of this section: whoever next touches `deck-form.sh` (per §10 items 1
and 2's own routing). Both fixes are in
`iso/overlay/configs/airootfs/usr/share/omarchy-iso/deck-form.sh`; the
regression tests are in `test/unit/test-deck-form.sh`.

### 12.1 Bug 2 (§5): the username-retry screen growth — FIXED

**Cause, confirmed exactly as §5 already named it**: `omarchy_prompt_username`'s
retry loop called bare `deck_form_warn` on an invalid/reserved candidate,
stacked on top of `deck_form_text_prompt`'s own per-call warnings
(mapper-not-found, the console-keymap notice) — and nothing ever cleared the
console between attempts, unlike upstream's own retry loop (`setup-form.sh`'s
`omarchy_prompt_username`/`_password`, READ), whose every invalid attempt goes
through `configurator`'s `notice()`, whose FIRST line is `clear_logo`
(READ, `iso/upstream/.../configurator:180-185`).

**Fix**: a new `deck_form_account_notice() { clear_logo; deck_form_warn "$1"; }`
helper, used in place of the bare `deck_form_warn` calls in both
`omarchy_prompt_username` and `omarchy_prompt_password` (the latter had the
identical defect, just not yet measured — same `deck_form_text_prompt`
mechanism, same missing repaint). `clear_logo` is already a hard dependency
of this file (`keyboard_form` already calls it, unconditionally, on every
loop iteration), so this does not add a new collaborator.

**Proof, MEASURED, not inferred**: `test/unit/test-deck-form.sh`'s new
"T4 bug 2 regression" section drives `omarchy_prompt_username` end-to-end
through four invalid (empty) submissions then a valid one, with `clear_logo`
temporarily replaced by a marker-printing stand-in (the suite's normal stub
is a silent no-op, `:;`, which can't prove a clear happened). The assertion
is on the SIZE of the console output between consecutive clears, not just
that a clear happened: against the pre-fix code the suite crashes the moment
it checks `clear_logo` was called zero times (`not ok - expected a screen
clear on every one of the 4 invalid attempts -- clear_logo ran 0 times`,
confirmed by temporarily reverting just this fix and re-running); against
the fix, all four segments are the same size (7 lines each, this run),
never the growing 16/22/28/34 §5 measured on the real ISO.

### 12.2 Bug 1 (§2): the identity/hostname/timezone overrides — ROOT-CAUSED and FIXED

**This session ruled nothing back in from §2's "already ruled out" list —
all five of those still hold.** The actual mechanism, found by literal
instrumentation of the real post-build files (not a VM boot — the bug
turned out to be a pure bash name-resolution question, answerable more
precisely without hardware/timing noise in the way):

1. `builder/build-iso.sh` (`iso/upstream`, READ, around its `setup_form`
   handling) vendors upstream's `setup-form.sh` onto the LIVE ISO at
   `/usr/share/omarchy-iso/setup-form.sh` — `cp "$setup_form"
   "$build_cache_dir/airootfs/usr/share/omarchy-iso/setup-form.sh"`. This is
   a BUILD-TIME step, invisible from reading the `iso/upstream` repo tree at
   rest (which is exactly what §2's "not a wrong-upstream-name bug" item
   read) — the file does not exist in any checked-out repo, only on a real
   built ISO. `DECK_SETUP_FORM_SH` in `deck-form.sh` already pointed at this
   exact path by default, correctly, for a different reason (loading the
   reserved-username list) — nobody had connected the two.
2. `deck_form_load_reserved_usernames` (called from inside
   `omarchy_prompt_username`'s own retry loop, once a PATTERN-VALID
   candidate is submitted) used to `source "$setup_form"` **directly into
   the calling shell** — and on the real ISO, the calling shell is
   `configurator`'s own process, the SAME process `deck-form.sh` itself was
   sourced into. `source` redefines a function in whatever shell actually
   runs it, no matter how deep the call stack. The file it sources
   (`/usr/share/omarchy-iso/setup-form.sh`) already defines
   `omarchy_prompt_identity`/`_hostname`/`_timezone`/`_username`/`_password`/
   `_keyboard` — the exact names `deck-form.sh` overrides. So the instant a
   user typed one syntactically-valid username, this call silently
   reinstalled upstream's own prompt bodies over every one of deck-form.sh's
   overrides, for the rest of the install. `omarchy_prompt_username` and
   `omarchy_prompt_password` were unaffected because their OWN
   already-running invocations don't change when the function table changes
   underneath them (a running bash function body is a fixed snapshot) — but
   every subsequent call (identity, hostname, timezone, and a second run of
   the keyboard picker on any "go back") resolved to upstream's freshly
   re-sourced versions instead. The mapper-not-found warning §2 observed
   during the "password" portion of the capture is consistent with this:
   `deck_form_text_prompt`'s output for the LAST username attempt is what
   bug 2 (§5, same session) left permanently on screen, uncleared, under
   the password prompt drawn after it — not independent evidence that
   `omarchy_prompt_password` itself was still deck-form.sh's version by
   that point, which it might not have been depending on exactly when the
   candidate passed validation. Bug 2's fix (§12.1) removes that ambiguity
   for any future capture, since the screen is repainted each retry.

**MEASURED directly** (no VM): the real post-build `configurator`
(`~/.cache/omarchy-deck/iso-build-2/src/configs/airootfs/root/configurator`,
confirmed byte-identical in its patched region to this repo's
`iso/overlay/patches/deck-form-invocation.patch` applied) was truncated to
just its preamble (everything through the `source
/usr/share/omarchy-iso/deck-form.sh` line, before any screen runs), sourced
in a plain bash process with `OMARCHY_PATH` pointed at the cached runtime
checkout (for `setup-form.sh`'s real fallback path and `logo.txt`), and
`declare -f omarchy_prompt_identity` was checked immediately after. Result:
correctly `deck_form_identity_body` at that point — sourcing order alone was
never the bug, confirming §2's own "not a sourcing timing/order bug"
reasoning. Then `deck_form_load_reserved_usernames` was called directly
(pointed at the REAL vendored `setup-form.sh` via
`DECK_SETUP_FORM_SH_OVERRIDE`, from
`~/.cache/omarchy-deck/iso-build/runtime-src/install/provisioning/setup-form.sh`)
in that same shell: `declare -f omarchy_prompt_identity` flipped from
`deck_form_identity_body` to upstream's own `gum input --prompt "Full
name> "` body, in one call — the exact placeholder text §2's capture shows
on screen.

**Fix**: `deck_form_load_reserved_usernames` now runs `source "$setup_form"`
inside a `$( ... )` command substitution (a genuine forked subshell) instead
of the calling shell directly. The subshell starts with every function this
file already defined (fork, not exec), but any redefinition IT makes is
discarded the instant it exits; only the `RESERVED_USERNAMES` array crosses
back out, as plain newline-delimited text on stdout, via `mapfile`. No
`eval`, and no function name from `setup-form.sh` is ever defined in the
real process again.

**Also found in passing, NOT fixed here (separate, already-flagged gap,
out of this session's two-bug scope)**: the real vendored `setup-form.sh`
does not define a `RESERVED_USERNAMES` array at all — its actual reserved-
name mechanism is `OMARCHY_RESERVED_USERNAMES`, an anchored regex STRING,
not an array (`~/.cache/omarchy-deck/iso-build/runtime-src/install/
provisioning/setup-form.sh:82`). `deck-form.sh`'s own header already flags
`DECK_RESERVED_USERNAMES_VAR`'s value as "(INFERRED, NOT READ)" — this
confirms the inference was wrong, and the reserved-username check has
therefore always degraded (warns, validates nothing) on a real ISO, never
silently, per that same block's own design. Left as its own follow-up
(§10 gains item 6, below) rather than folded into this fix, since it is
independent of the clobbering mechanism and was not part of either
assigned bug.

**Proof, MEASURED**: `test/unit/test-deck-form.sh`'s new "T4 bug 1
regression" section sources a fixture that defines BOTH
`RESERVED_USERNAMES` and (deliberately, to prove the fix under the exact
collision that caused the bug) its own `omarchy_prompt_identity`/
`_hostname`. Against the pre-fix code this fails
(`not ok - T4 bug 1: deck_form_load_reserved_usernames let the sourced
setup-form.sh redefine omarchy_prompt_identity in THIS shell`, confirmed by
isolating the bug-1 fix out of a hybrid build — the bug-2 fix alone applied,
bug-1's fix reverted — and re-running); against the fix,
`declare -f omarchy_prompt_identity`/`_hostname` are byte-identical before
and after the call, and the array still loads correctly.

**Not done this session, and why**: a fresh `[V]`/`[H]` run against a
REBUILT ISO, showing the Deck-branded S3 identity/hostname/timezone screens
on a real QEMU boot, per this task's own preference. `unsquashfs`/
`mksquashfs`/`xorriso` are not installed in this environment and there is no
passwordless `sudo` to add them, which rules out patching the already-built
session-23 ISO's squashfs directly as a shortcut. A full `iso/bin/build`
was started in the background against the session-23 cache
(`OMARCHY_DECK_ISO_BUILD_DIR=~/.cache/omarchy-deck/iso-build-2`, chosen so
package downloads and the docker layer cache are reused rather than a cold
build) to attempt this; see the session's own final report for whether it
finished in time and what it showed. If it did not, this is the direct
continuation of §10 item 1's follow-up, now with a known, fixed root cause
instead of an open question — the remaining step is purely "prove it on a
rebuilt ISO", not "find out why".

### 12.3 §10 follow-up tracking, updated

1. ~~Diagnose why `omarchy_prompt_identity`/`_hostname`/`_timezone` don't
   override~~ — **root-caused and fixed, §12.2.** Re-open only if a rebuilt-ISO
   `[V]`/`[H]` run still shows upstream's prompts.
2. ~~Fix the username-retry screen growth~~ — **fixed, §12.1.**
3. **Confirm whether `deck-input-mapper` should be present on this build**
   (§8) — still open, still `iso/bin/build`'s payload-set territory, not
   `deck-form.sh`'s.
4. **A follow-up `[V]` run should press one more `y` on `deck_final_summary`**
   — still open, unrelated to either fix in this section.
5. **`[H]` full hardware install is still entirely unattempted** — still open.
6. **NEW: `DECK_RESERVED_USERNAMES_VAR=RESERVED_USERNAMES` is confirmed
   wrong** (§12.2) — the real vendored `setup-form.sh` calls it
   `OMARCHY_RESERVED_USERNAMES` and it is a regex string, not an array.
   `deck_form_load_reserved_usernames`/`deck_form_username_reserved` need a
   rewrite to match (parse or reuse the regex, not `declare -p` an array
   that is never there) before the reserved-username check does anything on
   a real ISO. Owner: whoever next touches `deck-form.sh`'s S3 block.
