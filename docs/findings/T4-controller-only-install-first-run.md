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
7. ~~A follow-up `[V]` run should press one more `y` on `deck_final_summary`~~
   — **done, §13.** It does cross the gate; the run that crosses it hits a
   NEW, more severe blocker before `omarchy-install-dashboard` ever starts —
   see §13.4.

---

## 13. 2026-08-13 (same day, later session) — phase 2 exit criterion 1: NOT
    closed. A real, reproducible product bug blocks every interactive
    full-disk install, found by being the first run ever to press "Install"
    on a real, correctly-sized target disk

**Task:** close phase 2 exit criterion 1 — "a complete controller-only
install runs start to finish in QEMU from our ISO" — by extending past S5's
gate (§7's deliberate stop) with a disk-image-assertion model
(`test/vm/vm-install-test.sh`'s own pattern: assert on the resulting disk,
never on log text, `docs/PLAN.md` §8.1).

**Bottom line, upfront:** the criterion is **not closed**, and this session's
own new harness proves exactly why, precisely — not "it timed out, unclear
why." **Every interactive (human/controller-driven, non-`cidata`) full-disk
Omarchy install — Deck-forked or not — crashes immediately after
`write_user_files`, before the real installer (`omarchy-install-dashboard`)
is ever launched.** The cause is a pre-existing bug in **upstream's own**
`configurator` script, unrelated to any of `deck-form.sh`'s overrides, never
seen before this session because no prior run of this project's harnesses
had ever pressed "Install" past S5 on a disk sized to survive the attempt.
`vm-install-test.sh`'s own cidata-based install (T0, "verified end-to-end
against a real ISO build", `docs/PROGRESS.md`'s session-2 log entry) cannot
see this bug either — the cidata path in `.automated_script.sh` skips
`configurator` entirely.

### 13.1 The new harness: `test/vm/vm-install-controller-test.sh`

A new file (not an extension of `vm-installer-screens-test.sh`, which
explicitly documents in its own header why it can never safely be pointed at
a real-sized disk — see that file's "WHY THIS IS A NEW FILE" section for the
full argument, copied into the new file's own header too). Reuses the
S0→S5 key sequence **verbatim** from this doc's §3/§9 (same qcodes, same 6s
cadence — that portion is already proven, not re-litigated) via a duplicated
probe, then adds:

- **Step 29**: S5's own `y` ("Install") hotkey, crossing `deck_final_summary`'s
  gate into `write_user_files` — the point every previous run of this
  project's harnesses (§7, and `docs/findings/T4-harness-first-run.md`
  before this ISO existed) deliberately stopped short of.
- An **unbounded poll** (not a fixed sleep) for the real install's terminal
  state, since a real package install's duration is not knowable in advance
  the way a scripted `gum` redraw's is.
- **Step 30**: accepting `omarchy-install-dashboard`'s own upstream
  `reboot_prompt()` ("Reboot Now", plain `gum confirm --default`, READ from
  `iso/upstream/configs/airootfs/usr/local/bin/omarchy-install-dashboard`) —
  never reached this session, see §13.4.
- A **real, 16G, 1MiB-aligned target disk** (`vm-install-test.sh`'s own
  sizing), booted with **`-nic none`** — no network device of any kind, on
  purpose, so a pass could never be quietly explained by "well, it could
  reach the internet." This is provably safe: `phases_impl.py:190` hardcodes
  `arch.make_mirror_handler(offline=True)` for every install this
  orchestrator ever runs, and `_mount_offline_package_cache` bind-mounts the
  ISO's own bundled `/var/cache/omarchy/mirror/offline` — READ, not assumed,
  before this session trusted it enough to drop the NIC entirely.
- **No result-carrying block device.** The screens harness's report travels
  on a virtio-blk device that doubles as the (deliberately tiny/misaligned)
  install target — exactly the arrangement this new file cannot reuse, since
  its whole point is a target disk sized to survive a real install. Facts
  and screen captures stream over the serial line instead
  (`T4PROBE:FACT:...` / `T4PROBE:CAP:name:<base64>`, emitted as they happen,
  not batched at the end), and the host reconstructs a
  `screens::extract_section`-compatible report from `serial.log` after the
  guest is gone — deliberately robust to the guest disappearing mid-run
  (a real failure, a timeout, or the reboot this session's own fix, §13.3,
  makes possible), which a single end-of-run dump would not be.

### 13.2 A collision, not a defect: the ISO changed under a running VM

First attempt (`sha256 336f357...`, the session-23 ISO cited at the top of
this doc) stalled for ~10 minutes with zero probe output and QEMU's serial
log frozen mid-firmware ("`BdsDxe: starting Boot0002`"). Root cause: a
**parallel agent's own `iso/bin/build`** (working §12's two `deck-form.sh`
fixes, commit `e729699`) wrote a fresh ISO to the exact same path
(`~/.cache/omarchy-deck/iso-build-2/release/omarchy-2026.08.13-x86_64-quattro.iso`)
**while this session's QEMU process still had the old file open as its
cdrom backing store** — the classic shared-cache-path hazard, confirmed
by the file's mtime landing one second before the stall and the new sha256
(`d07bf6c...`) matching exactly what a clean rebuild from `e729699` would
produce. The stalled process (pid 2858231) was killed and the run restarted
clean against the verified new ISO — every result in §13.3 onward is
against `sha256 d07bf6cbe96ac417d3fe8a632283ef872cffa42d79d16bfb8a91e3ddaa3bfea3`,
**not** the session-23 hash this doc's header still cites (that ISO no
longer exists on disk; treat the header's hash as historical, not
reproducible, from this point in the doc onward). Verified, not assumed,
before trusting it: `git log -1 e729699` matches the commit message §12
describes, is on `main`, touches exactly `deck-form.sh`, and the ISO's mtime
is one second after that commit's timestamp.

Net effect, worth stating plainly: this session's run is against an ISO
that **already carries both of §12's fixes** — a strictly newer baseline
than any previous run of any harness in this project.

### 13.3 A real defect in THIS session's OWN harness, found and fixed:
     `After=multi-user.target` never fires with `-nic none`

Restarting clean against the verified ISO reproduced the **identical**
symptom — zero probe output, ever, despite the VM clearly being alive
(`query-status` returned `"running": true`; `info registers` showed a
kernel-space `RIP` inside a `hlt` idle loop, not a hung firmware — a live,
idle guest, not a frozen one). A QMP `screendump` proved the wizard was
fully up and interactive (the Deck greeter, on screen, waiting for input) —
manually sending `ret` via QMP advanced it to the keyboard list normally.
**So the wizard worked. Only this file's own injected probe never ran.**

Diagnosed live, no reinstall needed, via a root shell on **tty2**
(`archiso login: root`, no password — same access point
`docs/PROGRESS.md` line 2404 records using previously) reached by sending
`ctrl+alt+f2` over QMP, then typing diagnostic commands character-by-character
over QMP `send-key` (a throwaway helper script, not committed — every
character mapped to a qcode, `shift+letter` for uppercase, a small delay
between keys after an unpaced first attempt visibly garbled/dropped
keystrokes) and reading results back by `cat`-ing them to `/dev/ttyS0`,
which lands directly in the host's own `serial.log`:

```
○ t4-install-controller-probe.service - T4 install-controller probe
     Loaded: loaded (/run/systemd/generator.early/t4-install-controller-probe.service; generated)
     Active: inactive (dead)
        Job: 182
-- No entries --                    # journalctl -u ...: never ran, not "failed"

$ systemctl list-jobs
JOB UNIT                                TYPE  STATE
2   multi-user.target                   start waiting
67  systemd-time-wait-sync.service      start running
...
182 t4-install-controller-probe.service start waiting

$ systemd-analyze critical-chain t4-install-controller-probe.service
Bootup is not yet finished (org.freedesktop.systemd1.Manager.FinishTimestampMonotonic=0).
```

**The credential injection worked perfectly** — all three files
(`systemd.extra-unit....service`, `systemd.unit-dropin.multi-user.target`,
`t4installprobe.sh`) landed in `/run/credentials/@system/` byte-identical to
what was sent (verified against the running QEMU process's own `/proc/PID/cmdline`),
and systemd correctly generated the unit from it. **The bug was the ordering
this file copied from the sibling screens harness without re-deriving it**:
`After=multi-user.target`, pulled in via a `Wants=` drop-in on
`multi-user.target` itself — the exact same shape
`vm-installer-screens-test.sh` uses successfully. That harness boots with
`-nic user,model=virtio-net-pci`; this one boots `-nic none` (§13.1, on
purpose). With **no network device of any kind**, `systemd-time-wait-sync.service`
never completes (no NTP source ever answers, ever), so `multi-user.target`'s
own job sits `start waiting` for the life of the VM — it never reaches
`active`. A unit ordered `After=multi-user.target` in that state does not
start late; it **never starts at all**, for as long as the VM runs. The Deck
wizard on tty1 is unaffected (reached via `getty`, no such dependency), which
is exactly why the wizard worked throughout while the probe stayed silent.

**Fix**: `After=multi-user.target` → `After=basic.target`, and the `Wants=`
drop-in target credential key changed to match
(`systemd.unit-dropin.basic.target`). `basic.target` depends only on
`sysinit`/`paths`/`slices`/`sockets`/`timers` — no network, no time-sync —
and is reached early on every boot this project has ever measured. The
probe's own greeter-wait loop already tolerates starting "too early" (polls
up to 300s), so there was no matching risk on the other side. **Re-run
against the identical ISO, fixed harness: the probe ran, and reached S5's
gate (steps 1–29) on exactly the proven 6s cadence.**

### 13.4 The real result: `configurator` crashes on every interactive
     full-disk install, right after `write_user_files`, before the real
     installer ever starts

Step 29 (`y` on `deck_final_summary`'s "Ready to install?") **crossed the
gate** — confirmed by `advance_and_vanish` on the "Ready to install?" marker
and by `write_user_files`'s own artefacts landing on disk (verified directly
via the tty2 root shell, `ls -la /root/`):
`user_configuration.json` (4053 bytes), `user_credentials.json` (402 bytes),
`user_email_address.txt`, `user_encrypt_installation.txt`,
`user_full_name.txt` — all present, all timestamped together, all after the
gate-crossing keypress.

**Bonus, unplanned confirmation of §12.2's fix**: the written
`user_configuration.json` shows `"hostname": "steamdeck"` (not upstream's
`"omarchy"` default — `DECK_HOSTNAME`, correctly applied) and
`"timezone": "Europe/Amsterdam"` (not the stale default either), with
`"kb_layout": "uk"` matching this run's own down-arrow keyboard selection —
the identity/hostname/timezone override bug §12.2 fixed is confirmed working
**on a real, freshly-built ISO**, independent of that session's own unit
tests. No `disk_encryption` block, `user_encrypt_installation.txt` = `false`
— the encryption-off contract still holds at the real artefact level too.

**Then the probe's install-outcome poll ran the full 2100s (35 min) in-guest
deadline and found neither "Installed Omarchy in" nor "Omarchy installation
stopped" — `install.outcome=timeout`.** A live `screendump`, taken before the
host's own `RUN_TIMEOUT` reclaimed the VM, showed why: `deck_final_summary`'s
own table was still the last thing rendered on screen, and directly below
it, in plain terminal text (not a `gum` screen at all):

```
./configurator: line 1245: $1: unbound variable
~/.automated_script.sh  1.58s user 3.50s system 2% cpu 2:54.34 total
1 root@archiso ~ #
```

`.automated_script.sh` (`set -euo pipefail`) invokes `./configurator` with
**zero positional arguments** on the interactive path (only the `cidata`
branch, which never calls `configurator` at all, could supply one) — READ,
`iso/upstream/configs/airootfs/root/.automated_script.sh:101`. `configurator`
(deployed length confirmed 1247 lines via the tty2 shell, `wc -l ./configurator`)
ends with:

```sh
if [[ $1 == "dry" ]]; then
  print_dry_run_files
fi
```

**Bare `$1`, not `${1:-}`.** A few dozen lines earlier, the sibling check in
the `free_space` install branch (`iso/upstream/.../configurator:1030`, READ)
gets this right — `if [[ ${1:-} == "dry" ]]; then` — but this second,
identical-looking check at the true end of the file, reached by the
**`full_disk`** branch (the ONLY branch a Deck install can take —
`requires_full_disk_install` in `deck-form.sh` returns 0 unconditionally,
§4 S4), does not. Under `set -u`, referencing an unset `$1` is fatal. The
crash happens **after** `write_user_files` (line 1025, already run
successfully, artefacts on disk) and **before** anything that would invoke
`/usr/local/bin/omarchy-install-dashboard` — which lives entirely in
`.automated_script.sh`, `configurator`'s own *caller*, and is therefore never
reached once `configurator` itself dies non-zero under `.automated_script.sh`'s
own `set -e`.

**This is not a Deck-specific bug.** Nothing in T4's two patch hunks
(`source deck-form.sh`, `deck_final_summary || abort`) touches this code —
both hunks land near the top of the file, nowhere near its last four lines.
**Upstream's own unmodified installer has the identical defect**, on the
identical (and only) code path a controller-only, keyboard-less, non-`cidata`
human install can take. It has never been seen before because:

- `vm-install-test.sh`'s own cidata-based T0 run (`docs/PROGRESS.md`,
  session-2 log entry, "verified end-to-end against a real ISO build")
  never executes `configurator` at all — `.automated_script.sh`'s cidata
  branch (`if /usr/local/bin/omarchy-cidata-load; then ... skip the
  configurator`) is a hard `else`-exclusive fork.
- `vm-installer-screens-test.sh` (§7, this doc) has, until this session,
  never pressed past S5's gate — by design, on a disk too small/misaligned
  to survive a real attempt.
- No `[H]` hardware install of this fork has been attempted either (§10
  item 5, still open).

**Left failing, not weakened, per this project's own discipline** (CLAUDE.md,
`docs/tasks/T4-screen-spec.md` throughout): the new harness's
`install.outcome` check asserts `success`, gets `timeout`, and fails —
correctly. **9/11 checks passed**; the 2 failures are both this exact,
now-diagnosed fact (`install.outcome=timeout`, not `success`), and the
disk-image assertions are correctly *skipped*, not force-passed, since the
gate they depend on (a successful install) was never reached. See
`docs/PROGRESS.md`/`docs/ROADMAP.md` for how this changes the exit-criterion
1 record — **it is explicitly NOT marked closed**, and now has a precise,
fixable, one-line-diff reason instead of an open question.

### 13.5 What this session does and does not claim

**Proven, this session:**
- The Deck-forked wizard, on a freshly rebuilt ISO carrying §12's fixes,
  navigates S0 through S5's gate correctly, including the two now-fixed
  bugs' absence (no unbounded warning growth measured across four retries
  this run; identity/hostname/timezone correctly Deck-branded in both the
  on-screen table and the real written artefact).
- Crossing S5's gate genuinely starts the real install (`write_user_files`
  runs, artefacts land, byte-identical in shape to §6's proof but now
  against the REAL `deck_final_summary` values, closing §12.3 item 7/this
  doc's old §10 item 4).
- The install then crashes, deterministically, reproducibly (this is a pure
  bash `set -u` bug — no timing, no hardware, no randomness involved; it
  will reproduce on the very next attempt, in QEMU or on real hardware,
  every time) before the real installer ever starts.

**Not proven, and not claimed:**
- That a full install completes and produces a bootable disk. It has never
  gotten far enough to test.
- That fixing the `$1` bug is sufficient — once `omarchy-install-dashboard`
  actually launches, its own real partitioning/package/bootloader work is
  still entirely unmeasured against this project's Deck fork specifically.
- That this bug is exclusive to the Deck fork or this session's tree — it
  reads as a plain upstream defect, but confirming that against unpatched
  upstream's own ISO was out of this session's scope (this session only had
  the Deck-forked ISO on disk).

### 13.6 Follow-ups flagged (not fixed here — file-ownership/scope reasons)

1. **Fix `configurator`'s trailing `if [[ $1 == "dry" ]]` to `${1:-}`** —
   the actual unblock for phase 2 exit criterion 1. This is a one-line
   change, but it lands in `iso/upstream`'s vendored `configurator` (via
   whatever patch mechanism `iso/overlay/patches/` uses for upstream-file
   edits — this session did not open that directory, which is explicitly a
   parallel agent's territory this session, per this task's own scope
   fence). Owner: whoever owns the `iso/overlay/patches/` seam next.
2. **Re-run this harness once that fix lands** — steps 1–29 and the harness
   mechanics themselves need no further changes; only the product bug blocks
   a green run. If `install.outcome=success` next time, the (already-written,
   §13.1) disk-image assertions run for the first time and either close
   criterion 1 for real or surface the next real blocker.
3. `deck-input-mapper` payload-set question (§10 item 3) — still open,
   still not this file's territory.
4. `[H]` full hardware install — still entirely unattempted (§10 item 5).
5. **NEW: `DECK_RESERVED_USERNAMES_VAR` fix** (§12.3 item 6) — still open,
   `deck-form.sh` S3 territory, unrelated to this section.

### 13.7 Files

- `test/vm/vm-install-controller-test.sh` — new file, this session. Drives
  S0→S5 (reused key sequence), crosses S5's gate, polls for the real
  install's outcome, and (not yet exercised — gated on §13.6 item 1) asserts
  partition table / UKI presence / Limine config / package set / hostname /
  no-crypttab against the resulting disk image, reusing
  `test/lib/vm-disk-image.sh` and `test/lib/vm-assertions.sh` unmodified.
- Preserved work dir (`VM_KEEP_WORK=1`, the only surviving run — the first,
  ISO-collision run and the second, pre-`basic.target`-fix run were both
  discarded after diagnosis): `/var/tmp/t4-install-controller-run3/`
  (`serial.log`, the reconstructed `report.txt`, six streamed screen
  captures, `probe.sh`, and `live-check.png`/`.ppm` — the QMP screendump
  showing the `configurator` crash text directly).

---

## 14. 2026-08-13 (later session, Opus) — the `$1` crash is FIXED and the real
    installer now runs end to end; criterion 1 is STILL NOT closed, blocked
    one layer deeper by a real bug in our OWN `deck_autologin.py`

**Task:** land §13.6 item 1's one-line fix (`configurator`'s unguarded `$1`),
rebuild the ISO, and re-run `test/vm/vm-install-controller-test.sh` to finally
exercise its disk-image assertions (§13.1, "never exercised yet"). Same
discipline as every section above: if the fix reveals another real defect,
leave it failing and diagnose it, do not weaken an assertion to force a pass.

**Bottom line, upfront:** the `$1` fix is correct, necessary, and proven — it
moved the install from *crashing before the real installer starts* (§13.4,
`install.outcome=timeout`) to *the real installer running the entire base
Omarchy setup to completion and then aborting in OUR OWN Deck-configuration
phase*. Criterion 1 is **still not closed**, now blocked by a **second,
independent, precisely-diagnosed bug** — this one is ours, not upstream's:
`deck_autologin.py` searches for the desktop-session file under a
double-`.desktop` name it can never find, so the sole `critical=True` Deck
step fails and halts every install. The disk-image assertions still have not
run (correctly skipped, gated on `install.outcome=success`, not force-passed).

### 14.1 The fix (hunk 3 of `deck-form-invocation.patch`)

`configurator`'s trailing `if [[ $1 == "dry" ]]; then` → `if [[ ${1:-} == "dry"
]]; then`, matching the two already-correct sibling checks in the same file
(lines 670 and 1030, READ, both `${1:-}`). Landed as a **third hunk in the
existing `iso/overlay/patches/deck-form-invocation.patch`** (not a sixth patch
file — the patch-count budget is argued in that file's own header, and this
file already touches `configurator`; the header now carries the argument for
hunk 3 too). Verified: applies cleanly via `git apply --3way` against the
pinned `iso/upstream` tree, the fix lands at line 1245 of the patched file
(exactly the crash line §13.4 measured), `test/unit/test-iso-build.sh` passes
in full (82 checks incl. the patch-budget guard and guard 6.6), CI's own
shellcheck command clean.

### 14.2 The rebuild

`iso/bin/build` against `~/.cache/omarchy-deck/iso-build-2` (warm cache).
⚠️ **Two process-management lessons this session, recorded so the next agent
does not repeat them:**

1. **A `Monitor` that watches a log and then yields is NOT a substitute for
   waiting.** A first rebuild attempt died mid-`pacstrap` on a corrupted
   cached `omarchy-settings-dev-*.pkg.tar.zst` (the same infrastructure
   failure class §13/session 23 hit — a stale scratch-dir artifact, not a
   code problem) and the `Monitor`'s grep did not match `pacstrap`'s error
   wording, so nothing woke the agent — the exact silent-agent pattern
   `docs/START-HERE.md` warns about. **Fix for next time: block synchronously
   in a real poll loop** (`until grep -qE '<terminal markers>' log || ! kill
   -0 "$pid"; do sleep N; done` inside a `Bash` call with a large timeout,
   chained across calls), never arm-and-yield.
2. **`setsid nohup ./iso/bin/build &` makes `$!` the wrapper, not the build.**
   The wrapper exits immediately, so a poll loop keyed on `$!` sees "process
   gone" instantly and returns a false completion. Track the real child
   (`pgrep -f 'bash ./iso/bin/build'`) or, for QEMU, the pidfile the harness
   writes.

The corrupted package was already gone from the pacman-cache (the failed
transaction's own delete prompt removed it); the clean rebuild re-fetched it
and succeeded. Output:
`~/.cache/omarchy-deck/iso-build-2/release/omarchy-2026.08.13-x86_64-quattro.iso`,
6867582976 bytes (6.39 GiB), sha256
`a27230ff498f8b7b4be45f455192d135fb5ab777b3204022802da19e34b6ea6a`. All 8
guards passed; all 5 overlay patches applied; the built
`configurator`'s tail is `if [[ ${1:-} == "dry" ]]; then` (verified in the
build's own `src/` before the squash).

### 14.3 The real result: 10/11 checks, `install.outcome=failure` (was
     `timeout`), aborted in `configure_deck`'s `autologin` step

Run: `VM_KEEP_WORK=1 ./test/vm/vm-install-controller-test.sh <iso>
/var/tmp/t4-install-controller-run-opus` (preserved). Steps 1–29 drove S0
through S5's gate on the proven 6s cadence; **step 29 (`y` on
`deck_final_summary`) crossed the gate and the real installer launched** — the
`$1` crash is gone. The install then ran the **entire base Omarchy setup to
completion** (the failure screen's own "Last target log lines" show
`hardware/`, `login/sddm.sh`, `post-install/*` phases all `Completed`, then
`=== Omarchy Setup Completed: 2026-08-13 17:51:17 ===`), and then:

```
Omarchy installation stopped
Installer exited with status 1
last installer phase: Configuring Steam Deck
failed phase: Configuring Steam Deck: required Deck configuration steps failed: .
```

(The trailing `.` is the dashboard's own line-truncation glyph, the same one
that clips the log paths above it — not an empty message.) `install.outcome`
= **failure** (a genuine terminal state, reached in 48s), where §13.4 got
`timeout`. Harness verdict: **10/11 checks passed** (up from §13.4's 9/11 —
"the real install reached a terminal state" now passes too). The single FAIL
is the correct one — `the real install SUCCEEDED = failure (expected success)`
— **left failing, not weakened**. Disk-image assertions **correctly SKIPPED**
(`disk_checks_run=0`, gated on success), so they remain unexercised; this
session does NOT get to claim anything about the resulting disk's partition
table / UKI / Limine config / package set, because no completed install was
produced.

### 14.4 Root cause, MEASURED off the resulting disk, not inferred: a
     double-`.desktop` name bug in `deck_autologin.py`

The install target was preserved as a real 16G disk. It has a valid GPT (ESP +
x86-64 root, `sfdisk -d`), so archinstall's partitioning succeeded; the
failure is entirely in our post-install `configure_deck` phase. Mounted
rootless via the harness's own `disk_image::root_mount`, then remounted at the
btrfs top-level (`udisksctl mount -o subvolid=5`) to reach the `@log`
subvolume the install log lives in (a first mount of `@` alone shows an empty
`/var/log` — the logs are in `@log`, a separate subvolume; noting it here so
the next reader does not misread that emptiness as "nothing was written").

`@log/omarchy-deck-install.json` records every step's outcome. **Only
`autologin` failed** — `desktop_rotation: configured`, `idle_policy:
configured`, `limine_rotation: configured`, `lock_wake_dpms: configured`,
`menu_lock_row: overridden`, `patches: applied`, `session_dconf: configured`,
`tty_rotation: configured`, `wifi: no-hardware`. So §12.2's identity/hostname/
timezone fix and the whole rest of the Deck phase run correctly on a real
install; the sole blocker is autologin. Its recorded error (truncated to 96
chars by `configure_deck`'s summary-overwrite of `autologin_step`'s own
detailed record — see §14.6 item 3):

```
DeckAutologinError: neither gamescope-wayland.desktop nor omarchy.desktop exists in /usr/local/s...
```

**But `omarchy.desktop` IS on the target** —
`/usr/local/share/wayland-sessions/omarchy.desktop` (191-byte file, present).
The bug, confirmed by construction against the source (READ,
`deck_autologin.py`):

- `find_session()` builds the filename as `f"{session}.desktop"` (line 185).
- `GAMING_SESSION = "gamescope-wayland"` (line 136, a bare stem) → searches
  `gamescope-wayland.desktop` — the **correct** form, but that file is
  genuinely absent from this ISO's package set (only `hyprland.desktop`,
  `hyprland-uwsm.desktop`, and `omarchy.desktop` exist on the target).
- `DESKTOP_SESSION = "omarchy.desktop"` (line 137, **already carries
  `.desktop`**) → searches `omarchy.desktop.desktop` — a name that does not
  and will never exist. The two constants are **inconsistent**: one is a stem,
  one is a full filename, and `find_session` appends `.desktop` to both.

So `choose_session` finds neither, returns `status="failed"`,
`configure_autologin` raises `DeckAutologinError`, and because `autologin` is
the registry's **only `critical=True` step** (`deck_autologin.py`'s own
docstring argues that at length — a Deck that can't autologin is a
keyboard-less device with no way in), `configure_deck` re-raises and
`phases.py` halts the install.

**Two stacked defects, and the milder one matters for the fix:**

1. **The double-`.desktop` bug (the fatal one).** `DESKTOP_SESSION` should be
   the bare stem `"omarchy"` (so `find_session` yields `omarchy.desktop`), OR
   `find_session`/`choose_session` should stop appending `.desktop` to a name
   that already has it. Either way it is a one-line fix in `deck_autologin.py`.
2. **`gamescope-wayland.desktop` is genuinely absent from the ISO** (a
   separate, milder gap — the Gaming Mode session isn't in the package set).
   This is why fixing defect 1 does not automatically give a Gaming-Mode Deck:
   with defect 1 fixed, `choose_session` would resolve `omarchy.desktop`,
   return `status="desktop"` — a **non-critical degradation** ("boots to
   Desktop Mode, not Gaming Mode", explicitly a recorded-and-continue outcome,
   not an abort) — and **the install would complete**. So the one-line fix to
   defect 1 is very likely sufficient to let criterion 1's run finish and the
   disk-image assertions finally run — but it would prove a Deck that boots to
   *Desktop* Mode, and closing the "boots to Gaming Mode" half needs defect 2
   (the missing session package) resolved separately.

### 14.5 What this session does and does not claim

**Proven:**
- The `$1` fix is correct and load-bearing: with it, `configurator` no longer
  crashes under `set -u` after `write_user_files`, and the real installer
  (`omarchy-install-dashboard`) launches and runs the full base Omarchy setup
  to completion for the first time in this project's history on a
  controller-only, non-`cidata`, offline, real-disk install.
- Every Deck-configuration step except `autologin` succeeds on a real install
  (measured off the target's `@log/omarchy-deck-install.json`), including
  §12.2's identity/hostname/timezone fix at the real artefact level again.
- The remaining blocker is a single, one-line, pure-logic bug in our own
  `deck_autologin.py` (no timing, no hardware, no randomness — it will
  reproduce every run).

**NOT proven, NOT claimed:**
- That a full install completes and produces a bootable disk. It aborts in
  `configure_deck`; the disk-image assertions never ran.
- That fixing defect 1 is sufficient — it is *likely* (the analysis in §14.4),
  but "likely" is not "measured", and there may be a further defect past it
  (every layer of this harness has found one; §14 is itself the third such
  layer). The only way to know is to fix defect 1, rebuild, and re-run.
- Anything about Gaming-Mode autologin — the session package is absent (defect
  2), so even a completed install would land in Desktop Mode.

### 14.6 Follow-ups flagged

1. 🔴 **Fix the double-`.desktop` bug in `deck_autologin.py`** (§14.4 defect 1)
   — the actual unblock for criterion 1's completion. One line
   (`DESKTOP_SESSION = "omarchy"`, or stop double-appending). ⚠️ Its unit suite
   (`test/unit/test-deck-autologin*.py` if present) almost certainly encodes
   the wrong fixture name (`omarchy.desktop.desktop`) — it passed while the
   code was broken, this project's recurring "the test encodes the bug"
   failure — so the fix must correct the fixture too, not just the constant.
   Owner: whoever owns `orchestrator/deck_autologin.py` next.
2. **`gamescope-wayland.desktop` is not in the ISO's package set** (§14.4
   defect 2) — the Gaming Mode session file is absent from the target, so
   autologin can at best reach Desktop Mode. Decide whether the ISO must carry
   the Gaming session (payload-set question, `iso/bin/build`/`iso/PKGS`
   territory) before "first boot lands in Gaming Mode" (ROADMAP P3.2) can hold.
3. **`configure_deck` overwrites `autologin_step`'s own detailed record.**
   `autologin_step` writes a 400-char-capped detailed record then re-raises;
   `configure_deck`'s except handler then re-writes the same JSON key with a
   96-char summary (`sanitize_text` default limit), *losing* the detail the
   docstring at `deck_autologin.py:499` says it deliberately preserved. Minor
   (the summary still names the cause), but it defeats a stated design intent
   — either don't re-record a key the step already recorded, or raise the
   summary's limit. Owner: `orchestrator/deck_configure.py`.
4. Everything still-open from §13.6 (deck-input-mapper payload set, `[H]`
   hardware install, `DECK_RESERVED_USERNAMES_VAR`) remains open, unrelated.

### 14.7 Files

- `iso/overlay/patches/deck-form-invocation.patch` — hunk 3 added (the
  `${1:-}` fix), header updated to argue for the third hunk within the
  existing patch-count budget. **This is the only code file this session
  changed.** `deck_autologin.py` is deliberately NOT touched (§14.6 item 1 is
  a separate module's bug with its own test suite; leaving it failing and
  diagnosed is this project's discipline, not force-fixing past the assigned
  scope).
- Preserved work dir (`VM_KEEP_WORK=1`): `/var/tmp/t4-install-controller-run-opus/`
  — `serial.log`, reconstructed `report.txt`, the streamed captures
  (`x.00-greeter` … `x.29-post-install-start`, and the decoded
  `30-failure` in the serial log), `probe.sh`, plus this session's saved
  disk evidence `evidence-omarchy-deck-install.json` (the full per-step record
  read off the target's `@log`) and `evidence-sessions.txt` (the target's
  actual `wayland-sessions` listing proving `omarchy.desktop` is present while
  the code searched for `omarchy.desktop.desktop`). The 16G `target.qcow2` is
  kept; the intermediate `target.raw`/`root.raw` were deleted after the mount
  to reclaim space.

---

## 15. 2026-08-15 (session 27, Opus) — ✅ **IT PASSED. 18/18. Phase 2 exit criterion 1 is CLOSED.**

**The run every previous section was building toward.** A controller-only run
drove the Deck-forked ISO's real installer past S5's gate, through a **real**
16G full-disk install, to `install.outcome=success` — and **the harness's
disk-image assertions executed for the first time in this project's history.**
They had been gated on `install.outcome=success` since they were written
(§13/§14), so every prior run skipped them.

```
install.outcome=success   (waited 56s of a 2100s in-guest deadline)
18/18 checks passed
INSTALL TEST EXIT: 0
```

**The ISO under test:** `omarchy-2026.08.15-x86_64-quattro.iso`, sha256
`e9fbd8edb8c69d698c5e575955a2dd27d4f394a704c7b6b55744a817748368c5` — the first
ISO built against **Omarchy 4.0.0 stable** (`f0020448`), not a beta. Supersedes
`a27230ff…` (§14's ISO).

### What the disk-image assertions actually proved

Read off the resulting image, not from log text (`docs/PLAN.md` §8.1):

- partition table: exactly one ESP + one root partition
- **one UKI, `omarchy_linux.efi`**, under `/EFI/Linux` on the ESP
- **the Limine config at `/limine.conf` references that UKI** — the boot chain
  is internally consistent on a disk this project has never before produced
- installed package set includes base-devel / git / omarchy-keyring /
  omarchy-settings / omarchy
- `/etc/hostname` = `steamdeck` (§12's fix, now proven on a completed install)
- **zero LUKS crypttab entries** — the Deck's encryption-off contract, proven at
  the disk level rather than at the form

### Every `configure_deck` step succeeded — read off the target's `@log`

The record that aborted the install in §14 now reads (mounted rootless via
`udisksctl`, `@log/omarchy-deck-install.json`):

| step | status |
|---|---|
| **`autologin`** | **`gaming`** ← was `failed` in §14, and it halted the install |
| `desktop_rotation` | `configured` |
| `idle_policy` | `configured` |
| `limine_rotation` | `configured` |
| `lock_wake_dpms` | `configured` |
| `mask_sleep_lock` | `configured` |
| `menu_lock_row` | `overridden` |
| `patches` | `applied` |
| `session_dconf` | `configured` |
| `tty_rotation` | `configured` |
| `wifi` | `no-hardware` (expected — the harness runs `-nic none` on purpose) |

**`autologin: gaming` is the value §14 was chasing.** Both bugs that produced
`failed` are now dead on a real install: `deck_autologin.py`'s double-`.desktop`
name (fixed session 26, unit-proven only until now) and the gamescope gap below.

### §14.6's second item — the gamescope gap — is CLOSED, and it was a real bug

§14.6 flagged that `gamescope-wayland.desktop` was absent from the ISO payload,
so even a successful install would land in **Desktop Mode**. Session 26 tried to
fix it by adding `gamescope-session` to `deck-install.packages`. **That package
exists in no Valve repo** (all four DBs checked, 2026-08-15) and was never
build-validated — the first build that tried it died on `target not found`.

Root cause, measured: the session file is shipped by the **gamescope package
itself, and only Valve's build of it** (`jupiter-staging/gamescope 3.16.25-3`
ships `usr/share/wayland-sessions/gamescope-wayland.desktop`; Arch's
`extra/gamescope 3.16.25-1` ships no `wayland-sessions/` at all). Our mirror
already carried Valve's build — **nothing installed it**. Full account and the
mirror-list-vs-install-list conflict it exposed:
`docs/findings/T9-stable-rebase-remaining.md`.

Verified **on the installed target**, not in the payload:

```
/usr/share/wayland-sessions/gamescope-wayland.desktop   present
/usr/bin/gamescope                                      present
/usr/bin/start-gamescope-session                        present
/var/lib/pacman/local/gamescope-3.16.25-3               Valve's build
```

and the autologin config `configure_deck` wrote, which sorts last in
`/etc/sddm.conf.d` so its `Session=` wins:

```ini
[Autologin]
User=deck
Session=gamescope-wayland
Relogin=true
```

### ⚠️ What this still does NOT prove

- **This is QEMU, not a Deck.** It proves the installer, the boot-chain
  artifacts, and the session *selection*. It does **not** prove gamescope
  renders, that Gaming Mode is usable on the panel (R-38's standard), or
  anything about hardware. That is P3.2.
- `wifi: no-hardware` is correct here and untested by construction — the harness
  is deliberately offline.
- Nothing here was run on the operator's Deck. The Deck is still on the beta-2
  pin; `docs/tasks/P36-deck-stable-update-runbook.md` is the operator-present
  path to move it.

### Evidence

Work dir preserved (`VM_KEEP_WORK=1`):
`~/.cache/omarchy-deck/stable-rebase/install-test/` — `report.txt` (80 KB of
streamed guest captures), `qmp.log`, `probe.sh`, `limine.conf`, the extracted
UKI, and `target.qcow2` / `target.raw` / `root.raw`. Build log:
`~/.cache/omarchy-deck/stable-rebase/build.log`.
