#!/usr/bin/env bash
# Library: the pure/checkable half of T4's [V]-tier harness
# (docs/tasks/T4-screen-spec.md §6.2's primitives, §6.4's guards).
#
# Split the same way test/lib/vm-assertions.sh already is: everything here
# operates on already-captured files/strings (a /dev/vcs1 snapshot, a
# report.txt line, a jq-extracted value) so it can be unit-tested with
# hand-built fixtures — no QEMU, no root, no ISO. The half that actually
# reads a live console or drives a guest lives in
# test/vm/vm-installer-screens-test.sh, which sources this.
#
# ⚠️ EVERY function that reads text captured from a live console goes
# through `command grep`, LC_ALL=C, -a. Three separate, DIAGNOSED (not
# assumed) reasons, all found while building this harness (2026-08-11):
#
# 1. §6.4 lie #7, confirmed with real GNU grep (3.12) on a real capture:
#    `screens::nonblank_rows` counts non-blank rows with a character class
#    (`[^[:space:]]`), and docs/findings/T4-harness-feasibility.md §2.4
#    already documented that a UTF-8 locale under-counts this against the
#    Omarchy logo's CP437 block glyphs (13 rows -> 2). Reproduced here on a
#    REAL captured greeter screen with a line made entirely of CP437 bytes:
#    plain `grep -c '[^ ]'` said 2, `grep -ac '[^ ]'` (adding -a ALONE) STILL
#    said 2, and only `LC_ALL=C grep -c '[^ ]'` said the correct 3. **For
#    THIS bug, on THIS grep, -a alone does not fix it -- LC_ALL=C is the
#    load-bearing half.** -a is kept anyway as defense in depth against
#    GNU grep's separate NUL-byte-triggered "binary file matches" behaviour,
#    which is unrelated to locale and wasn't independently reproduced here
#    (no NUL bytes in a text-mode console capture) but costs nothing to guard.
#
# 2. `screens::marker_present` (fixed-string, -F) was NOT reproduced as
#    vulnerable on this grep build, even with CP437 bytes on the very same
#    line as the marker -- plain grep, `-a`, and `LC_ALL=C` all found it.
#    Kept anyway, deliberately: grep's binary/locale handling is a moving
#    target across versions and platforms (see point 3), and a fixed-string
#    search against console text is cheap to make locale-proof even where
#    it isn't currently observed to matter.
#
# 3. A confound worth recording so nobody repeats the mistake: on THIS dev
#    machine, an interactive `grep` invocation is shadowed by a shell
#    function this Claude Code session defines, which routes to `ugrep -I`
#    (ignore-binary) instead of real GNU grep -- and THAT wrapper genuinely
#    did return zero matches against a real CP437-laden report.txt where
#    `command grep` (real GNU grep) found all 17. That is a tooling artefact
#    of this interactive dev environment, not a property of grep in a UTF-8
#    locale -- it was initially mistaken for one. Every function below calls
#    `command grep` specifically so it is never subject to whatever grep a
#    caller's interactive shell happens to have redefined.
#
# Not meant to be run directly -- source it.

set -uo pipefail

# --- A6: environment geometry -----------------------------------------

# screens::geom_from_header <4-byte-file>
# Parses a /dev/vcsaN header (bytes: rows, cols, cursor-x, cursor-y) the
# way vm-iso-probe-feasibility.sh's vcs_geom() does, pulled out so the
# parsing itself is unit-testable without a real vcsa device. Prints
# "ROWS COLS". Never caches a result -- T4-harness-feasibility.md §2.3:
# this dev machine's own tty1 grew from 25x80 to 50x160 between
# multi-user.target and the wizard's first frame, and a width cached once
# folds every later capture at the wrong column, splitting centred text
# across two lines and making a phrase grep miss a screen that is
# genuinely present. Callers MUST call this fresh before every capture.
screens::geom_from_header() {
  local file=$1
  python3 - "$file" <<'PY' 2>/dev/null || printf '0 0\n'
import sys
try:
    with open(sys.argv[1], "rb") as fh:
        d = fh.read(4)
    print(d[0], d[1])
except Exception:
    print(0, 0)
PY
}

# --- A1: the console reader ---------------------------------------------

# screens::fold_at_width <raw-file> <cols>
# Folds raw console bytes at the geometry's own column count -- never a
# hardcoded width. cols<=0 (a geometry read that failed) passes the raw
# bytes through unfolded rather than guessing, so a caller can tell "the
# geometry read failed" apart from "the fold happened to be a no-op".
screens::fold_at_width() {
  local raw=$1 cols=$2
  if [[ $cols -gt 0 ]]; then
    fold -w "$cols" "$raw" 2>/dev/null
  else
    cat "$raw" 2>/dev/null
  fi
}

# screens::nonblank_rows <file>
# How many rows carry ANY non-space content, counted byte-safe (LC_ALL=C
# grep -a) so CP437 block glyphs are counted rather than silently refused
# by a UTF-8 locale (see file header). This is a COUNT, not a word search
# -- T2/T8's R-49 lesson (vm-osk-tty-test.sh header): a single surviving
# character punched through a repainted row still greps as present, so a
# "does the word X still appear" check can pass on a screen that is mostly
# gone. Counting rows is the check that catches that; this function is the
# row-counting primitive other checks build on.
screens::nonblank_rows() {
  local file=$1
  LC_ALL=C command grep -ac '[^[:space:]]' "$file" 2>/dev/null || echo 0
}

# screens::marker_present <file> <fixed-string>
# LC_ALL=C, fixed-string (-F) so a marker containing regex metacharacters
# (a passphrase, an SSID) can never be misread as a pattern -- and so this
# never falls into the plain-grep-on-CP437 trap described in the header.
screens::marker_present() {
  local file=$1 marker=$2
  LC_ALL=C command grep -qaF -- "$marker" "$file" 2>/dev/null
}

# --- A5 / guard 1: advance-and-vanish ------------------------------------

# screens::advance_and_vanish <before-file> <after-file> <appearing> <vanishing>
# T4 §6.2 A5 / §6.4 lie #1: a gate that only checks the NEXT screen's
# marker can pass on a screen that never changed at all, if that marker
# happened to already be visible (a wrapped fragment, a word appearing in
# help text on the PREVIOUS screen too). Real proof needs both halves:
# the outgoing marker was there and is now gone, AND the incoming marker
# was absent and is now present. Prints which of the four sub-checks
# failed, so a failure report says why rather than just "no".
screens::advance_and_vanish() {
  local before=$1 after=$2 appearing=$3 vanishing=$4
  local ok=1

  if ! screens::marker_present "$before" "$vanishing"; then
    echo "advance_and_vanish: vanishing marker '$vanishing' was not present in $before to begin with (it never proves anything vanished)" >&2
    ok=0
  fi
  if screens::marker_present "$after" "$vanishing"; then
    echo "advance_and_vanish: vanishing marker '$vanishing' is STILL present in $after -- the screen did not advance" >&2
    ok=0
  fi
  if screens::marker_present "$before" "$appearing"; then
    echo "advance_and_vanish: appearing marker '$appearing' was ALREADY present in $before -- it cannot prove the next screen appeared" >&2
    ok=0
  fi
  if ! screens::marker_present "$after" "$appearing"; then
    echo "advance_and_vanish: appearing marker '$appearing' is not present in $after -- the next screen never showed up" >&2
    ok=0
  fi

  [[ $ok -eq 1 ]]
}

# --- guard 2: the input path might be silently dead ----------------------

# screens::assert_input_path_live <bound-flag> <echoed-text> <expected-substring>
# §6.4 lie #2: the pad enumerates and the mapper starts, but binds a dead
# node and delivers nothing (P15 R-8 / PROGRESS.md §5.9's R-31 -- "an
# evdev node can be enumerated and permanently silent"). Two DIFFERENT
# failures, reported differently on purpose: never having bound at all is
# a different bug from binding to something that produces no input.
screens::assert_input_path_live() {
  local bound_flag=$1 echoed=$2 expect=$3
  if [[ $bound_flag != 1 ]]; then
    echo "assert_input_path_live: never confirmed bound (bound_flag='$bound_flag') -- the input channel may not exist at all" >&2
    return 1
  fi
  if [[ $echoed != *"$expect"* ]]; then
    echo "assert_input_path_live: bound, but '$expect' never arrived at the prompt (got '$echoed') -- SILENT INPUT PATH: the channel exists and delivers nothing" >&2
    return 1
  fi
  return 0
}

# --- guard 3: vacuous passes -------------------------------------------

# screens::require_report <report-file>
# §6.4 lie #3: the probe never ran, so every later check trivially has
# nothing to disagree with and the run "passes". A missing or empty report
# is a hard fail, never a 0/skip; and the report's OWN first fact must be
# that the injected unit ran at all (T4-harness-feasibility.md's own
# design: "the first assertion in the suite must be a trivial 'the
# injected unit ran at all' marker"). This function enforces both.
screens::require_report() {
  local report=$1
  if [[ ! -s $report ]]; then
    echo "require_report: $report is missing or empty -- the guest wrote NOTHING. This is a hard fail, not a vacuous pass." >&2
    return 1
  fi
  if ! screens::marker_present "$report" "unit.ran=1"; then
    echo "require_report: $report has content but never says 'unit.ran=1' -- the injected probe unit may never have executed; every other line in this report is meaningless until that is fixed" >&2
    return 1
  fi
  return 0
}

# screens::extract_section <report-file> <section-name> <out-file>
# Pulls a single named "--- screen.NAME ---" ... block out of an assembled
# report into its own file, so screens::advance_and_vanish (which needs two
# real FILES) can be run against a report retrieved from a real VM run, not
# just against hand-built fixtures. The contract is exact: a line that is
# BYTE-FOR-BYTE "--- screen.NAME ---" opens the section; the next line
# starting with "--- screen." (any name) or end of file closes it. Prints
# nothing and creates an empty file if the section is not found -- callers
# should check the file is non-empty, which screens::marker_present's own
# "not found" case already handles gracefully.
screens::extract_section() {
  local report=$1 name=$2 out=$3
  command awk -v want="--- screen.${name} ---" '
    $0 == want { grabbing = 1; next }
    /^--- screen\./ { grabbing = 0 }
    grabbing { print }
  ' "$report" >"$out"
}

# screens::field <report-file> <key>
# Same key=value extraction convention as vm-iso-probe-feasibility.sh's
# field() / vm-osk-tty-test.sh's field(), pulled out so it is directly
# unit-testable against a hand-built fixture instead of only ever being
# exercised inside a real VM run.
screens::field() {
  local report=$1 key=$2 line
  while IFS= read -r line; do
    if [[ $line == "${key}="* ]]; then
      printf '%s\n' "${line#*=}"
      return 0
    fi
  done <"$report"
  return 1
}

# screens::check <what> <got> <want>
# A counting, denominator-printing check -- §6.4 lie #3's other half: the
# report must always print how many checks it ran, not just which ones
# passed, so a report that silently ran 3 checks instead of 30 is visible
# as "3 checks" rather than looking identical to a full green run. Callers
# read SCREENS_CHECKS_TOTAL / SCREENS_CHECKS_PASSED after a batch.
SCREENS_CHECKS_TOTAL=0
SCREENS_CHECKS_PASSED=0
screens::check() {
  local what=$1 got=$2 want=$3
  SCREENS_CHECKS_TOTAL=$((SCREENS_CHECKS_TOTAL + 1))
  if [[ $got == "$want" ]]; then
    SCREENS_CHECKS_PASSED=$((SCREENS_CHECKS_PASSED + 1))
    printf 'ok   %s = %s\n' "$what" "$got"
    return 0
  else
    printf 'FAIL %s = %s (expected %s)\n' "$what" "$got" "$want" >&2
    return 1
  fi
}

# screens::denominator
# Always call this once at the end of a run and print its output. A run
# that checked 0/0 is indistinguishable from one that never ran its
# checks at all UNLESS the denominator is printed unconditionally --
# which is the whole point: it can't be skipped by an early exit that
# also skips every check.
screens::denominator() {
  printf '%d/%d checks passed\n' "$SCREENS_CHECKS_PASSED" "$SCREENS_CHECKS_TOTAL"
}

# --- guard 4: a guard nobody has seen fail --------------------------------

# screens::assert_blocking_held <screen-id-before> <screen-id-after-attempts>
# §6.4 lie #4 / T4 §4 S3's "the blocking assertion": a screen "blocks"
# only if something that tries to skip it demonstrably fails to. This
# compares a screen identifier captured before N submit attempts against
# one captured after -- equal means the block held, unequal means it
# didn't. The two IDs are caller-supplied (usually the sorted set of
# markers present) so this stays a pure string comparison, testable
# against fixtures that represent both a real block and a broken one.
screens::assert_blocking_held() {
  local before_id=$1 after_id=$2
  if [[ $before_id != "$after_id" ]]; then
    echo "assert_blocking_held: screen identity changed from '$before_id' to '$after_id' after the skip attempts -- the block did NOT hold" >&2
    return 1
  fi
  return 0
}

# --- A2/A3: artifact pairing ----------------------------------------------

# screens::assert_pair <field-name> <on-screen-value> <artifact-value>
# T4 §4 S5's warning: a screen that shows one thing and writes another to
# the JSON artefact is a bug invisible to a screenshot OR an artefact
# check taken alone. This asserts the PAIR agrees, naming the field on
# mismatch.
screens::assert_pair() {
  local field=$1 shown=$2 written=$3
  if [[ $shown != "$written" ]]; then
    echo "assert_pair: '$field' shown on screen ('$shown') does not match what was written to the artefact ('$written')" >&2
    return 1
  fi
  return 0
}

# --- guard 5: testing the wrong world -------------------------------------

# screens::capability_scope_label <mechanism>
# §6.4 lie #5: QEMU has no hid_steam and no Deck firmware, so a run driven
# this way only ever exercises the lizard-mode-equivalent input path (host
# keys / QMP send-key stand in for the buttons lizard mode itself
# produces: Enter, Esc, Tab, arrows). A run driven by the scripted uinput
# pad exercises the lizard_mode=N + mapper path instead. This is a fixed
# lookup so the label a report prints can be asserted in a unit test
# rather than typed by hand into every VM script that needs to say it.
screens::capability_scope_label() {
  case $1 in
    qmp-sendkey) echo "lizard-mode-equivalent (navigation only; [H]-only to prove the real thing)" ;;
    uinput-pad)  echo "lizard_mode=N + mapper (text-entry path; QEMU has no hid_steam, so this is still not the real Deck HID)" ;;
    *)           echo "unknown" ;;
  esac
}
