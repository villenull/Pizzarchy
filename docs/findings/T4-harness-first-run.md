# T4 `[V]`-tier harness — first real runs, and what the 5 failures were

**Date:** 2026-08-12 · **Task:** T4 · **Tier:** `[V]` (QEMU, real ISO)
**Subject:** `test/vm/vm-installer-screens-test.sh` driving upstream's
`configurator` wizard end to end on
`~/ISOs/omarchy-2026.08.10-x86_64-quattro.iso`.

---

## 0. Bottom line

**All five failures in the 35/40 were in the HARNESS, not the wizard.**
Nothing upstream is broken. Two were the measuring instrument lying (§6.4
lie #7, a locale-dependent grep); three were a wrong expectation about how
upstream repaints a rejected prompt. Both classes are fixed, and the fixes
are mutation-tested.

`docs/PROGRESS.md` §7 warned that four separate times a measurement TOOL lied
rather than the code. **This is the fifth.** Doubting the instrument first
was the correct call and it paid off immediately.

Two upstream facts were learned in the process (§4), and one latent library
bug was found by the new unit tests (§5.3).

---

## 1. Runs

| # | When | Work dir | Result |
|---|------|----------|--------|
| 1 | 2026-08-11 22:42 | `/var/tmp/vm-installer-screens.ykHTzJ` | 35/40 |
| 2 | 2026-08-12 (re-run for this investigation) | `/var/tmp/t4-rerun/work` | 35/40 |
| 3 | 2026-08-12 (after the fixes below) | `/var/tmp/t4-verify/work` | **57/57 PASS** |

Runs 1 and 2 are **bit-identical**: the same five checks failed, and the
SHA-256 of every screen capture involved matched across runs. That
determinism is itself a result — it is what makes this harness usable as a
gate at all (§7).

The host-side assertion half was also replayed offline against run 1's
preserved `report.txt`, reproducing 35/40 without booting anything. Useful
technique: the guest probe and the checking logic are cleanly split, so a
failed run can be re-analysed in seconds rather than 15 minutes.

That same replay is the strongest single piece of evidence that the fixes
are right. Re-running the **new** assertion block against **run 2's
unchanged report** — the exact bytes that produced 35/40 — gives:

```
57/57 checks passed
```

and a full third boot (run 3) against the live ISO independently confirms
the same 57/57, with all five previously-failing checks now green:

```
ok   empty-username attempt 1: screen did not advance; ONLY the intro line changed
ok   empty-username attempt 2 changed NOTHING (byte-for-byte)
ok   empty-username attempt 3 changed NOTHING -- the block genuinely holds
ok   summary table shows the typed username = deck
ok   username: SUMMARY SCREEN and ARTEFACT agree
```

Same captures, same artefacts, same wizard; only the checking logic changed.
Nothing about the guest was touched, so the 5 failures cannot have been
anything but harness-side. (57 rather than 40 because the fixes added 17
checks: §5.2's four blank-screen and six direct non-advance assertions, and
§4 fact 2's three extra summary fields with their three pairings.)

---

## 2. The username discrepancy — **the harness lied, not the screen**

### The reported failure

```
assert_pair: 'username' shown on screen ('') does not match what was written
             to the artefact ('deck')
FAIL username: SUMMARY SCREEN and ARTEFACT agree
ok   artefact username is 'deck'
```

### What the screen actually shows

Row 17 of the captured summary screen (`x.25-summary`), rendered with
`cat -v`:

```
 M-3 Username      M-3 deck                M-3
```

`M-3` is byte **0xB3** — CP437's box-drawing vertical bar, the table's
column separator. **The summary screen shows `Username │ deck` perfectly.**
So does every other row: Hostname `omarchy`, Timezone `America/Mexico_City`,
Keyboard `uk`, Password `****`, Full name / Email `[Skipped]`.

Upstream is not omitting the username, and the expectation was not wrong.

### The actual bug

`vm-installer-screens-test.sh` extracted the value with this line — the
**only** piece of checking logic in the whole suite that did not go through
the unit-tested library:

```bash
summary_username=$(command grep -aoE 'Username *. *[a-zA-Z0-9_-]+' ... )
```

No `LC_ALL=C`. In the dev machine's `en_US.UTF-8` locale, 0xB3 is an invalid
multibyte sequence, so the `.` never matches it and the whole extraction
returns the empty string. This is **§6.4 lie #7 exactly** — the same class of
bug the library's own file header documents at length for `nonblank_rows`,
reintroduced in the one place the library was bypassed.

Reproduced directly on the real capture:

```
$ command grep -aoE 'Username *. *[a-zA-Z0-9_-]+' x.25-summary
(nothing)

$ LC_ALL=C command grep -aoE 'Username *. *[a-zA-Z0-9_-]+' x.25-summary
Username      │ deck
```

GNU grep 3.12, `LANG=en_US.UTF-8`. One environment variable is the entire
difference between "the wizard disagrees with itself" and "everything is
fine."

`assert_pair` then did exactly its job: it compared `""` against the
artefact's `"deck"` and refused. **The pairing primitive is correct and
should not be touched.** It faithfully reported a disagreement between the
two things it was handed; one of them was simply garbage.

### Why this was worth the trouble to find

`assert_pair` is the check `T4-screen-spec.md` §4 S5 exists for — "neither
half alone would catch it." Its first ever firing was a false positive
caused by its own input. Had it been "fixed" by relaxing the assertion, the
harness would have kept the bug and lost the guard. The lesson is
**structural, not textual**: the extraction was inline in the VM script
where no unit test could ever reach it. That is the thing that got fixed.

---

## 3. The other four failures

Five failing checks, two root causes.

| # | Failing check | Verdict |
|---|---|---|
| 1 | `summary table shows the typed username` | **Broken check** — §2, locale-dependent extraction |
| 2 | `username: SUMMARY SCREEN and ARTEFACT agree` | **Broken check** — same root cause, downstream of #1 |
| 3 | `empty-username attempt 1 changed NOTHING` | **Wrong expectation** — §3.1 |
| 4 | `empty-username attempt 2 changed NOTHING` | **Wrong expectation** — same, cascaded |
| 5 | `empty-username attempt 3 changed NOTHING` | **Wrong expectation** — same, cascaded |

**No real defect in upstream's wizard was found by this run.**

### 3.1 The blocking negative test (failures 3–5)

Guard 4 asserted that three empty-username submits leave the screen
byte-identical, comparing SHA-256 of each raw capture against the state
*before* the first submit. Measured reality:

```
x.03-username-empty    raw=c79c7e30625b     (before any submit)
x.04-username-empty-2  raw=255f0e9f14db     (after submit 1)
x.05-username-empty-3  raw=255f0e9f14db     (after submit 2)
x.06-username-empty-4  raw=255f0e9f14db     (after submit 3)
```

Attempts 2 and 3 are byte-identical to attempt 1. Only the *first*
rejection changes anything, and the change is this:

```
before (x.03)                              after (x.04)
13| Let's setup your user account...       13| (blank)
14| (blank)                                14| Username> Alphanumeric without…
15| Username> Alphanumeric without…        15| (blank)
16| (blank)                                16| enter submit
17| enter submit
```

Upstream repaints the prompt block **one row higher and drops its own intro
line** on the first rejected submit. The wizard does not advance; the block
holds perfectly. But every byte below the logo moved, so a raw hash called
it a broken block — and because all three attempts were compared against the
*pre-submit* baseline, one repaint produced three failures.

Proof that the intro line is the *only* difference: delete exactly that line
from the before-capture and the content identities match to the hash.

```
x.03 minus the intro line   content=e607fc7b9c50
x.04-username-empty-2       content=e607fc7b9c50
x.05-username-empty-3       content=e607fc7b9c50
x.06-username-empty-4       content=e607fc7b9c50
```

**Verdict: wrong expectation in the harness.** The check was measuring
"no pixel moved" when the claim it needed to prove was "the wizard did not
advance."

---

## 4. Two facts about upstream worth keeping

1. **The rejected-prompt repaint loses its own heading.** After the first
   rejected submit, "Let's setup your user account..." is gone and does not
   come back. A Deck user who mis-submits loses the only context line on the
   screen. Relevant to `deck-form.sh` (T4 §4 S3): if our screens redraw a
   rejected field, the heading has to be part of the redraw, and the
   controller-only user has no scrollback to recover it.

2. **The summary screen carries five fields, all of which pair against the
   artefacts.** Username, Hostname, Timezone, Keyboard and Password(masked).
   The harness now pairs four of them rather than only the username (§5.2) —
   S5's warning applies to every row of that table, not just one.

Both facts were only visible because the harness captures whole screens
rather than grepping for expected strings.

---

## 5. Changes made

### 5.1 `screens::table_value <file> <label>` (new, in the library)

Reads one cell from a box-drawn table. `LC_ALL=C` throughout, and the parse
is **byte-based** rather than a regex over characters: a high byte
(`\200-\377`) is the cell separator, the value is the ASCII run between two
of them. Both the opening and closing separator are required, so a truncated
or half-repainted row yields nothing rather than a plausible-looking partial
value, and prose containing the label ("Username> Alphanumeric without
spaces") is never mistaken for a table row.

The point of moving this into the library is that it is now reachable by
unit tests. The inline version never was, which is why the bug lived.

### 5.2 `screens::content_digest <file>` (new, in the library)

A screen identity that is immune to a whole-screen vertical shift **and to
nothing else**: the ordered sequence of non-blank, right-trimmed rows,
hashed, prefixed with the row count. Guard 4 now asserts:

- **attempt 1** — the *only* difference from the pre-submit screen is the
  loss of the intro line, proven by removing exactly that line and requiring
  the identities to match. This is a **pin, not a tolerance**: if upstream
  ever stops dropping the line, or drops a different one, it fails loudly.
- **attempts 2 and 3** — full raw byte identity, unchanged and unweakened.
- **all three** — the guard's actual purpose asserted directly: `Username>`
  is still the live screen and `Password>` has not appeared.
- **all four captures** — non-blank, so "the block held" can never be
  satisfied by two empty screens (§6.4 lie #3 applied to guard 4).

The guard is stronger than before, not weaker. The previous version could
not distinguish "the screen legitimately repainted" from "the screen was
replaced by garbage"; this one can.

### 5.3 Latent bug found by the new tests: `screens::nonblank_rows`

```bash
LC_ALL=C command grep -ac '[^[:space:]]' "$file" 2>/dev/null || echo 0
```

`grep -c` on a file with zero matches prints `0` **and** exits 1 — so both
halves fired and the function returned the two-line string `"0\n0"`. Any
caller doing `[[ $(screens::nonblank_rows f) -gt 0 ]]` got a bash error
instead of an answer. Found by the blank-screen fixture written for
`content_digest`; fixed by capturing first and deciding after.

This one had never fired in a real run only because no capture had ever been
blank. It would have fired the first time one was — i.e. exactly when the
harness most needed to be trustworthy.

---

## 6. Mutation testing

Required by the task, and it earned its keep: the first battery had **six
survivors**, including two branches that turned out to be dead or wrong.

| Mutation | First pass | Final |
|---|---|---|
| `table_value`: drop opening-separator requirement | SURVIVOR | killed |
| `table_value`: drop closing-separator requirement | killed | killed |
| `table_value`: drop `LC_ALL=C` | killed | killed |
| `table_value`: take FIRST match not last | SURVIVOR | killed |
| `table_value`: accept an empty cell / prefer last non-empty | SURVIVOR | killed |
| `table_value`: drop leading-whitespace trim | SURVIVOR | *removed as dead code* |
| `table_value`: drop trailing trim | — | killed |
| `table_value`: drop the `index()` label guard | — | killed |
| `content_digest`: stop deleting blank rows | killed | killed |
| `content_digest`: stop right-trimming rows | SURVIVOR | killed |
| `content_digest`: left-trim as well | — | killed |
| `content_digest`: drop the row-count prefix | killed | killed |
| `content_digest`: drop `LC_ALL=C` from the sed | SURVIVOR | **SURVIVOR (documented)** |
| `nonblank_rows`: restore the `\|\| echo 0` bug | killed | killed |
| `nonblank_rows`: drop `LC_ALL=C` | killed | killed |

**Final: 14 mutations, 13 killed, 1 documented survivor.**

Two survivors were fixed by **deleting the branch**, not by adding a test:

- the leading-whitespace trim in `table_value` was unreachable (the
  separator match already consumes the following spaces);
- "prefer the last *non-empty* cell" was actively wrong. On a scrolled
  console a stale copy of the table can sit above the live one, and that
  rule would return the **stale** value whenever the live row was blank or
  still being drawn. It now returns the live row's empty cell, so the
  caller's check fails loudly instead of passing on history.

### The one surviving mutation, honestly labelled

`content_digest`: dropping `LC_ALL=C` from its `sed` does not fail any test,
because it does not change any answer. Checked directly against four real
CP437 captures from run 2 — greeter, summary, username prompt, failure menu
— the C and UTF-8 digests are byte-identical in all four. It is kept as
defense in depth for the same reason `marker_present` keeps it (see the
library header's point 2), and the library now says so in as many words.
**No test claims it matters.** Writing a test that passed for a reason
nobody could demonstrate would be exactly the "passes for the wrong reason"
failure the task warns about.

### A trap worth recording

The first battery re-run reported a clean 14/14 kill — **falsely**. An
apostrophe in a comment inside the single-quoted awk program had broken
`table_value` entirely, so the baseline suite was already red and every
mutation "killed" it for the wrong reason. A mutation harness must assert
its **baseline is green** before it reports anything; one was added. A clean
sweep is a suspicious result, not a satisfying one.

---

## 7. Is this harness trustworthy enough to gate phase 2's exit criterion?

Phase 2's headline exit criterion is *a complete controller-only install
runs start to finish in QEMU from our ISO, zero keyboard input.*

**Yes for what it measures; but it does not yet measure that criterion.**

What it has earned:

- It **found a real disagreement and reported it loudly** rather than
  passing. The most valuable property in a gate is that its first genuine
  run was not green.
- It is **deterministic** — two independent 15-minute boots produced
  bit-identical captures. A flaky screen-scraper could never gate anything.
- Its checking logic is **unit-tested and mutation-tested off the VM**, and
  the one gap in that coverage is precisely where the bug was. That gap is
  now closed.
- Its guards are **not decorative**: guard 4 fired, and the reason it fired
  turned out to be information (§4 fact 1) rather than noise.

What still stands between it and the criterion:

1. **It drives upstream's wizard, not ours.** `deck_form_present=0` is
   asserted in every report on purpose. S1 (Wi-Fi/OSK) and S8 (Deck-branded
   failure menu) are unproven and cannot be proven until the forked ISO
   exists.
2. **It proves navigation, not the Deck HID.** QEMU has no `hid_steam` and
   no Deck firmware (`hid_steam.loaded=0` in the report). `qmp-sendkey`
   exercises the lizard-mode-*equivalent* path only —
   `screens::capability_scope_label` prints this into the artefact so it
   cannot be skimmed past. "Zero keyboard input" in the exit criterion means
   *the Deck's own buttons*, and that remains `[H]`-tier.
3. **It stops at the failure menu by design**, so no install has ever run to
   completion under it. That is a deliberate safety decision, not a gap to
   close carelessly — see the script header's warning that the failure
   menu's default cursor is "Upload log for support", i.e. one more `ret`
   would make every CI run exfiltrate the install log to a third party.

**Recommendation:** adopt it now as the regression gate for installer-screen
behaviour, and treat it as *necessary but not sufficient* for phase 2's exit
criterion. The criterion additionally needs the forked ISO (item 1) and an
`[H]`-tier pass on real hardware (item 2). Do not let a green run here be
read as the criterion met — the report's own `deck_form_present` and
`hid_steam.loaded` lines exist to make that misreading hard, and they should
stay.

---

## 8. Files

- `test/lib/vm-installer-screens.sh` — `table_value`, `content_digest`,
  `nonblank_rows` fix
- `test/vm/vm-installer-screens-test.sh` — guard 4 rewritten, inline
  extraction removed, summary pairing widened to four fields
- `test/unit/test-installer-harness-primitives.sh` — new fixtures
- Preserved work dirs: `/var/tmp/vm-installer-screens.ykHTzJ` (run 1),
  `/var/tmp/t4-rerun/work` (run 2), `/var/tmp/t4-verify/work` (run 3)
