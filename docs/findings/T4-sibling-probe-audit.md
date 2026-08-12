# Auditing the sibling VM suites for T4's §6.4 lie #7 — and what else was in there

**Date:** 2026-08-12
**Scope:** `test/vm/*` (except `vm-installer-screens-test.sh`), `test/lib/*`
(except `vm-installer-screens.sh`), `test/unit/test-vm-*.sh`
**Trigger:** `docs/findings/T4-harness-first-run.md` — the installer-screens
harness reported a wizard defect for five months and the defect was its own
extraction. The question this audit answers: *do the sibling suites have the
same latent bug, and do they have other checks that cannot fail?*

**Answer: yes to both, and the worst thing found was neither.**

---

## 0. Headline

| # | Finding | Severity |
|---|---|---|
| 1 | `vm-gamepad-spike-test.sh`'s in-guest probe has been a **bash syntax error since the commit that introduced it** (861f922, 2026-08-10). The suite cannot run and has not run. | **fatal, real** |
| 2 | The premise that in-guest probes are "safe by the C-locale accident" is **false**. The substrate sets `LANG=en_US.UTF-8`; every probe greps non-UTF-8 console bytes in a UTF-8 locale. | **real (mechanism), latent (impact)** |
| 3 | `vm-osk-tty-test.sh` had 19 locale-unsafe greps over `/dev/vcsN` captures. Reproduced: one of them loses rows *today* if a high byte ever lands on screen. | latent |
| 4 | Five separate checks whose passing state was indistinguishable from their not-having-run state. | latent |
| 5 | `vm-default-entry-test.sh` transcoded an EFI variable with `iconv -t ASCII`, which truncates at the first non-ASCII byte with the error hidden. | latent |
| 6 | `vm-iso-probe-feasibility.sh` — **reported as also unsafe; it is not.** Every one of its console greps was already correct. | correction |

---

## 1. The fatal one: a suite that has never been able to run

`test/vm/vm-gamepad-spike-test.sh` ships its in-guest probe inside a quoted
heredoc. That heredoc carried a **stale second copy of sections 3 and 4** — the
pre-`fresh_window` versions — and the seam between the two copies left:

```
kill "$MAPPER_PID" "$PAD_PID" "$WITNESS_PID" 2>/dev/null   # never set
  emit "done=1"
  exit 0
fi                                                          # unmatched
```

`bash -n` on the extracted body:

```
line 230: syntax error near unexpected token `fi'
```

The stale copy also calls a `resync` function that no longer exists, and the
off-VM half checks three fields (`gum_single_menu_up`, `gum_multi_menu_up`,
`gum_stick_menu_up`) that **only the first copy emits** — which is how the two
copies were told apart.

Confirmed present in the original commit (`git show 861f922`), so the suite has
never been runnable in the repository. The T2 result it is cited for
(`docs/findings/T2-gamepad-spike.md`) came from a version that was never
committed.

### Why nothing caught it

`bash -n` on the *suite* cannot see inside a quoted heredoc — to bash it is an
opaque string. `shellcheck` does not follow it either. The only thing that would
have reported it is a ~15-minute VM boot, and nobody booted it for two days.
**This is a whole class**: eight VM suites ship an in-guest probe this way, and
none of them was ever syntax-checked.

**Fixed:** stale block deleted (80 lines), probe now parses.
**Class closed:** `test/unit/test-vm-probe-integrity.sh` §A extracts every
`<<'PROBE'` heredoc in `test/vm/` and `bash -n`s it, in under a second.

---

## 2. The locale premise is false, not merely undeclared

The brief for this audit said the sibling probes are *"safe only via an
undeclared C-locale assumption"*, and proposed asserting the locale is C/POSIX.

**That assertion would have failed immediately.** Measured:

- `test/images/vm-neptune-image.sh:278` writes `LANG=en_US.UTF-8` into the
  substrate's `/etc/locale.conf`.
- systemd reads `locale.conf` into the manager environment and every service
  inherits it. Verified on the dev machine, which has the same file:
  `systemctl show-environment` → `LANG=en_US.UTF-8`.
- Every in-guest probe runs as a systemd service on that substrate.

So there is no C-locale accident protecting these probes. They grep a byte
stream that is **not** UTF-8 (a `/dev/vcsN` snapshot is one byte per cell in the
console's own charmap) while sitting in a UTF-8 locale. The only thing that has
been saving them is that their captures happen to contain no high bytes yet.

### Reproduced, with the split that matters

Fixture: five rows, one carrying `0xB3` (CP437 vertical, the exact byte from
lie #7), one carrying `0xB0`/`0xB1` block glyphs plus the word `shift`. Pattern:
`vm-osk-tty-test.sh`'s own `diag.rows_with_keys` alternation.

| locale | flags | rows reported | stderr |
|---|---|---|---|
| C | `-n` | 1,2,3 ✅ | — |
| C | `-an` | 1,2,3 ✅ | — |
| **en_US.UTF-8** | **`-n`** | **1 only** ❌ | `binary file matches` |
| en_US.UTF-8 | `-an` | 1,2,3 ✅ | — |

Two things worth carrying forward:

1. **`-a` is the load-bearing half here.** In `screens::nonblank_rows`
   (`test/lib/vm-installer-screens.sh`) `LC_ALL=C` was the load-bearing half and
   `-a` alone did nothing. Neither flag fixes both cases. Always use both.
2. **The loss is silent.** The `binary file matches` warning goes to stderr,
   which every probe redirects into `probe.log` and nobody reads.

A fixed-string `grep -c` finds the high-byte row in *either* locale, which is
consistent with the reference library's honest note that `marker_present` was
never reproduced as vulnerable. **Only line-enumerating greps (`-n`, `-o`) and
character-class counts break.**

### The fix chosen over asserting the locale

Asserting `LANG=C` pins a *proxy*, and would still be wrong in some locale
nobody enumerated. `vm-osk-tty-test.sh` now writes a two-line fixture in the
guest and greps it as a **canary**, under whatever locale the guest really
booted with:

- `canary.ascii` — negative control: an ASCII row must still be found.
- `canary.highbyte` — the 0xB3 row must be counted.
- `canary.highbyte_rows` — **the real regression test**: `grep -n` must
  enumerate *both* rows (`1,2,`). Under en_US.UTF-8 with the flags stripped this
  reads `1,`, so it fails naming the cause instead of silently subtracting rows.

The locale is also recorded (`locale.lang`, `locale.lc_all`) as a diagnostic —
measured, not assumed.

---

## 3. Per-site table: real hazard vs latent

**REAL** = would misfire today. **LATENT** = the mechanism is present and
reproduced, and only the current absence of high bytes prevents it.

| Site | Subject | Verdict | Action |
|---|---|---|---|
| `vm-osk-tty-test.sh` ×19 (`osk.shown`, `gum.drew`, `row.gum`, `row.osk_last`, `diag.rows_with_keys`, `typed.prompt_line`, `tui_rows`, `curses.grep_shift_*`, mapper stderr) | `/dev/vcs2`, `/dev/vcs3`, guest logs | **LATENT** — `deck_osk_tty.render()` was checked and emits pure ASCII, and `gum input` draws no borders, so today's captures have no high bytes. `deck_osk_layout` already carries `◀ ▶ ▲ ▼ ☺` for the pixel renderer; the day the tty renderer borrows one, `row.osk_last` returns empty and the suite blames the mapper. | **fixed** — all 19 now `LC_ALL=C command grep -a…`, plus the canary |
| `vm-gamepad-spike-test.sh` — `tmux capture-pane` greps | tmux pane text | **NOT A HAZARD** — tmux emits well-formed UTF-8, unlike `/dev/vcsN`. Left alone, documented. | none |
| `vm-gamepad-spike-test.sh` — `diag.kb_handlers` | `/proc/bus/input/devices` | latent-trivial | hardened in passing |
| `vm-kernel-hook-test.sh` ×6, `vm-kernel-stage-test.sh` ×6, `vm-default-entry-test.sh` ×5, `vm-kernel-idempotency-test.sh` ×1 | pacman logs, `limine.conf`, `pacman.conf` | **LATENT** — pacman's output carries UTF-8 progress glyphs; these are valid UTF-8 so no misfire was reproduced. Hardened for uniformity, not because a defect was measured. | hardened |
| `vm-iso-probe-feasibility.sh` — all `$OUT/screen.*` greps | ISO console captures | **ALREADY CORRECT** | none needed |
| `vm-iso-probe-feasibility.sh` — host-side serial-log waits ×3 | `serial.log` | latent-trivial (a miss stalls the wait, which is loud) | hardened |
| `test/lib/vm-assertions.sh`, `vm-disk-image.sh` | `limine.conf`, `udisksctl` output | **NOT A HAZARD** — ASCII sources, and both already guard for file existence | none |

### Correcting one item in the brief

> `test/vm/vm-iso-probe-feasibility.sh` — its own header documents this exact
> bug, and the probe body then uses bare greps anyway.

**Not supported by the file.** Every grep in it whose subject is a
`$OUT/screen.*` capture already carries `LC_ALL=C … -a` (lines 307, 318–321,
335–339, 345–346). The remaining greps target `/proc/mounts`, an `ls` listing,
`modinfo`, and the host-side serial log — sources the brief itself scoped out as
ASCII-only. That file describes the trap **and stays out of it**; it is the
second-best reference in the tree after `test/lib/vm-installer-screens.sh`.

---

## 4. Checks that could not fail

> *A check that proves something is ABSENT must also prove it was LOOKING.*
> — `docs/PROGRESS.md` §5.30c

Five instances, none of them locale-related.

**4.1 `vm-kernel-idempotency-test.sh` — the whole suite's verdict was vacuous.**
The pass condition is `diff state.after1 state.after2 == 0`. `snapshot()`
deliberately folds stderr into the snapshot file, so a probe that could not read
`/boot` at all writes **two matching files full of error text** and the suite
reports "byte-identical end state, PASS". Two empty files diff clean.
*Fixed:* the report now carries each snapshot's line count and its count of
`.efi` paths — the positive control that says the snapshot really saw an ESP
with kernels on it — and both are asserted non-zero.

**4.2 `vm-default-entry-test.sh` — a check comparing two report fields to each
other.** `check "repair.reconcile_default" "$(field repair.reconcile_default)"
"$(field repair.expected)"`. If the probe never reached the reconcile, `field`
returns `""` twice, `"" == ""`, and the strongest claim in the section — that
the pacman hook's reconcile holds the `default_entry` it was given — reports
green having compared nothing. *Fixed:* the right-hand side is pinned non-empty
first.

**4.3 `vm-default-entry-test.sh` — F3's absence was never proven manufactured.**
F3 strips the Neptune `path:` line with an inverted grep, then asserts the stage
refuses to write a default. **An inverted grep that matches nothing is a copy** —
if the pattern ever drifts from limine.conf's syntax, F3 exercises the healthy
config. *Fixed:* line counts before and after the strip, asserted to differ.

**4.4 `vm-kernel-hook-test.sh` — two absence assertions with no proof of
looking.** `after_gapB.stale_refs` and `after_remove.entry_refs` are both
asserted `0`, and `grep -c` against a missing `/boot/limine.conf` exits 2 and
prints nothing — which the probe's `|| true` swallows. Likewise
`reinstall1.our_hook_rebuilt` is asserted `0` from a `grep -q` over a pacman log
that might not exist. *Fixed:* `limine_conf_present` / `limine_conf_lines` per
snapshot and `log_lines` per hook log, all asserted.

**4.5 `vm-kernel-stage-test.sh` — a strip with no control.**
`prereq.repos_stripped` reports 1 when the grep finds nothing; an awk that wrote
an *empty* `/etc/pacman.conf` reports a perfect strip, and section 4b then
measures a stage failing for the wrong reason. *Fixed:* a positive control
greps for `[core]`, which must **survive** the strip.

**Plus two vacuity bookends** added to `vm-osk-tty-test.sh` and
`vm-gamepad-spike-test.sh`: `unit.ran=1` as the report's first fact and
`probe.done=1` as its last. Both suites write their report from an `EXIT` trap,
so a probe that died mid-run still ships a well-formed report with later
sections simply absent. In the gamepad suite the early give-up path used to emit
the *same* completion marker as the happy path; it now emits
`probe.aborted_at=chain_sanity`.

---

## 5. `iconv -t ASCII` truncates and hides it

`vm-default-entry-test.sh`'s `loader_entry_selected()` read the bootloader's own
`LoaderEntrySelected` EFI variable through `iconv -f UTF-16LE -t ASCII
2>/dev/null`. `iconv` **fails at the first non-ASCII character** and stops; the
`2>/dev/null` hides the failure, leaving a truncated entry name which is then
compared against the full menu path from `limine.conf`. One em-dash or accented
character in a Limine menu title and the suite reports
`selected_matches_chosen=0` — blaming the bootloader for the transcoder. This is
the boot-proof assertion, the single most load-bearing check in that suite.
*Fixed:* `-t UTF-8`, which is the encoding `$chosen` is already in (it comes from
awk over `limine.conf`'s own bytes), and the error is no longer discarded.

---

## 6. What is now enforced, and what is not

`test/unit/test-vm-probe-integrity.sh` — 51 checks, static, sub-second, no VM.

- **§A** every in-guest probe extracts and parses (closes §1's class)
- **§B** no grep over a `$OUT/screen.*` or `/dev/vcs` subject lacking `LC_ALL=C`
  *and* `-a` (closes §2's class)
- **§C** every VM suite propagates its verdict as an exit status
- **§D** every anti-vacuity guard added here is wired at **both** ends — emitted
  by the probe *and* consumed by the host

Every scanner carries a positive and a negative control, and asserts it found a
non-zero number of subjects. The one hit outside this audit's ownership
(`vm-installer-screens-test.sh:336`, a `command grep -qa` with no `LC_ALL=C`) is
recorded as a **self-expiring deferral**: the entry is asserted to still match,
so the moment its owner fixes the line this file goes red demanding the entry be
deleted. An exemption list that rots into a list nobody looks at is the same
defect class this whole audit is about.

### Not enforced, and worth saying plainly

- **No VM was booted.** Everything here is static analysis plus host-side
  reproduction of the grep behaviour. The guards added *inside* the VM suites
  are proven to exist and to be wired at both ends; that they *fire correctly*
  needs a real run. `vm-gamepad-spike-test.sh` in particular has not executed
  since 2026-08-10 and its first real run should be treated as a first run.
- **`src/deck_osk_tty.py` has the same decode hazard and was not touched** (it
  is outside this audit's ownership). `osk_rows()` reads a console capture with
  `encoding="utf-8", errors="replace"`; a single `0xB3` becomes `U+FFFD` and can
  never equal the rendered character, so `rows_on_screen` would silently drop to
  0 the day the layout emits a non-ASCII glyph. Recorded, not fixed.

---

## 7. Mutation testing

23 mutations, **21 killed, 2 survivors**.

Killed: reintroducing the unmatched `fi`; renaming the `PROBE` delimiter;
stripping `LC_ALL=C` from a console grep; stripping `-a` from a console grep;
removing either end of five different anti-vacuity guards; removing `exit
$status`; neutering the console-grep regex, the heredoc extractor, the
delimiter stop, `probe::parses`, `suite_propagates`, the `-a` detector, the
`LC_ALL` detector, and the comment-skip; emptying the wiring table; widening the
deferral to swallow everything; breaking the suite glob.

**Two survivors, both documented and both structural:**

- `S10` lowering the `probes_found >= 8` floor to `>= 0`
- `S14` lowering the `console_grep_lines >= 20` floor to `>= 0`

These are mutations of the test's **own vacuity thresholds**. Lowering a floor
is not observable while the tree is healthy — by construction, an assertion
cannot catch a mutation of its own constant. Recorded rather than contrived
around.

**One mutation found a defect in the audit's own test.** `S7` (suite glob
matches nothing) initially **hung** rather than failed: with an empty array,
`scan_unsafe_console_greps "${suites[@]}"` calls awk with no file arguments and
awk reads stdin forever. A test that hangs in CI is worse than one that fails —
it burns the timeout and reports nothing. There is now a hard stop on zero
suites, and `S7` kills cleanly.
