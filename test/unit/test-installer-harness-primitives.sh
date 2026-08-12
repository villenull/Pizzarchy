#!/usr/bin/env bash
# Unit tests for test/lib/vm-installer-screens.sh -- the pure/checkable half
# of T4's [V]-tier harness (docs/tasks/T4-screen-spec.md §6.2, §6.4).
#
# No VM, no root, no ISO: every fixture below is a hand-built file standing
# in for a /dev/vcs1 capture or a report.txt line. This is deliberately the
# SAME split test-vm-assertions.sh already uses (extraction needs a real
# image; checking is pure logic over already-extracted text) -- these
# functions are all on the checking side.

set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

# shellcheck source=../lib/vm-installer-screens.sh
source "$REPO_ROOT/test/lib/vm-installer-screens.sh"

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; [[ -n ${2:-} ]] && printf '%s\n' "$2" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# ===========================================================================
# A6: console geometry -- pure parsing of a vcsa-style 4-byte header
# ===========================================================================

# vcsa header bytes: rows, cols, cursor-x, cursor-y
printf '\x32\xa0\x05\x03' >"$work/geom25x160"   # 50 rows, 160 cols
read -r rows cols <<<"$(screens::geom_from_header "$work/geom25x160")"
[[ $rows == 50 && $cols == 160 ]] || fail "geom_from_header parses a real 4-byte header" "got rows=$rows cols=$cols"
pass "geom_from_header parses a real 4-byte header (50x160)"

# a missing file must not crash the caller -- it must report 0 0, distinctly
# non-viable, rather than raising or hanging.
read -r rows cols <<<"$(screens::geom_from_header "$work/does-not-exist")"
[[ $rows == 0 && $cols == 0 ]] || fail "geom_from_header on a missing file returns 0 0" "got rows=$rows cols=$cols"
pass "geom_from_header on a missing file returns 0 0 (never crashes the caller)"

# ===========================================================================
# A1: console reading -- fold width, and never caching geometry
# ===========================================================================

printf 'ABCDEFGHIJ' >"$work/raw10"
screens::fold_at_width "$work/raw10" 4 >"$work/folded4"
want=$'ABCD\nEFGH\nIJ'
got=$(cat "$work/folded4")
[[ $got == "$want" ]] || fail "fold_at_width folds at the given column count" "got: $got"
pass "fold_at_width folds at the given column count"

# T4-harness-feasibility.md §2.3's exact bug: caching a width and folding a
# WIDER screen at the cached value splits what would otherwise be one
# centred line into two, and a phrase grep can miss it entirely. Prove the
# two widths produce genuinely different row counts for the same content --
# i.e. that this function is width-sensitive, which is the property a caller
# depends on to avoid caching.
printf 'the quick brown fox jumps over the lazy dog' >"$work/raw44"
screens::fold_at_width "$work/raw44" 80 >"$work/folded80"
screens::fold_at_width "$work/raw44" 20 >"$work/folded20"
lines80=$(wc -l <"$work/folded80")
lines20=$(wc -l <"$work/folded20")
[[ $lines80 -lt $lines20 ]] || fail "folding at a narrower width produces MORE lines (proves width sensitivity)" "80cols=$lines80 lines, 20cols=$lines20 lines"
pass "folding at a narrower width produces more lines -- caching the wrong width would misread a real screen"

# cols<=0 (a failed geometry read) passes raw bytes through rather than
# guessing a width -- so a caller can tell "geometry read failed" apart
# from "the fold happened to be a no-op".
screens::fold_at_width "$work/raw10" 0 >"$work/foldedzero"
[[ $(cat "$work/foldedzero") == "ABCDEFGHIJ" ]] || fail "fold_at_width with cols<=0 passes raw bytes through"
pass "fold_at_width with cols<=0 passes raw bytes through unfolded"

# ===========================================================================
# guard for §6.4 lie #7: CP437 bytes silently defeat character-class grep
# ===========================================================================

# Build a fixture matching what actually reproduces the bug, diagnosed
# during this session (see the library's file header for the full story):
# a line made ENTIRELY of raw CP437 high bytes (0xDB, the Omarchy logo's
# solid block -- no ASCII interspersed, matching a real logo row), plus two
# ordinary ASCII lines. A toy fixture with just a few CP437 bytes followed
# by ASCII text on the SAME line does NOT reproduce the bug (grep still
# finds a valid character later on the line) -- this one does, confirmed
# against real GNU grep (3.12) via `command grep` outside this suite while
# building it: plain `grep -c '[^ ]'` and even `grep -ac '[^ ]'` both
# undercounted this exact 3-line fixture as 2; only `LC_ALL=C grep -c '[^ ]'`
# (and this library's nonblank_rows, which uses it) correctly say 3.
printf '\xdb\xdb\xdb\xdb\xdb\xdb\xdb\xdb\xdb\xdb\xdb\xdb\xdb\xdb\xdb\xdb\xdb\xdb\xdb\xdb\n' >"$work/cp437.screen"
printf 'Username> deck\n' >>"$work/cp437.screen"
printf 'more text\n' >>"$work/cp437.screen"

screens::marker_present "$work/cp437.screen" "Username>" ||
  fail "marker_present finds an ASCII marker in a file that also contains a pure-CP437 row"
pass "marker_present (command grep, LC_ALL=C, -aF) finds the marker despite a pure-CP437 row elsewhere in the file"

nb=$(screens::nonblank_rows "$work/cp437.screen")
[[ $nb -eq 3 ]] || fail "nonblank_rows counts all 3 non-blank rows, including the pure-CP437 one" "got $nb (a plain 'grep -c [^ ]' on this exact fixture undercounts this as 2 -- reproduced while building this suite)"
pass "nonblank_rows counts the pure-CP437 row too (LC_ALL=C is the load-bearing half here, not -a alone)"

# ===========================================================================
# table_value -- the function that replaced THE bug this harness's first
# real run actually found (docs/findings/T4-harness-first-run.md)
# ===========================================================================
#
# The fixture is a byte-accurate reconstruction of the real captured summary
# screen: CP437 0xB3 (box-drawing vertical) as the column separator, values
# padded out to the column width. The bug being regression-tested is that a
# character-class/`.` regex over these bytes matches NOTHING in a UTF-8
# locale, so the old inline extraction silently produced "" and the pairing
# check blamed the wizard for a disagreement that did not exist.
{
  printf ' \263 Field         \263 Value               \263\n'
  printf ' \263 Username      \263 deck                \263\n'
  printf ' \263 Password      \263 ****                \263\n'
  printf ' \263 Full name     \263 [Skipped]           \263\n'
  printf ' \263 Hostname      \263 omarchy             \263\n'
  printf ' \263 Timezone      \263 America/Mexico_City \263\n'
  printf ' \263 Keyboard      \263 uk                  \263\n'
} >"$work/summary.cp437"

got=$(screens::table_value "$work/summary.cp437" "Username")
[[ $got == "deck" ]] || fail "table_value reads a CP437-separated table cell" "got '$got'"
pass "table_value reads 'deck' out of a CP437 box-drawn table (the exact bug run 1 hit)"

# Prove the OLD approach really does fail on this same fixture, so the
# regression test is anchored to a demonstrated failure rather than to a
# story about one. If a future grep/locale makes the old form work, this
# assertion tells us the fixture stopped reproducing the bug.
# (|| true: under `set -o pipefail` the leading grep finding nothing -- which
# is the whole point of this fixture -- would otherwise abort the suite.)
old=$(command grep -aoE 'Username *. *[a-zA-Z0-9_-]+' "$work/summary.cp437" 2>/dev/null |
  command grep -aoE '[a-zA-Z0-9_-]+$' | tail -1 || true)
[[ -z $old ]] || printf 'note - the pre-fix locale-dependent extraction no longer fails here (got %s); check LC_* in this environment\n' "$old"

# A value containing '/' and one containing '[' ']' both survive: the parse
# is byte-delimited, not a character class of "allowed" value characters,
# which is what made the old regex fragile in the first place.
got=$(screens::table_value "$work/summary.cp437" "Timezone")
[[ $got == "America/Mexico_City" ]] || fail "table_value keeps '/' in a value" "got '$got'"
got=$(screens::table_value "$work/summary.cp437" "Full name")
[[ $got == "[Skipped]" ]] || fail "table_value keeps bracket characters in a value" "got '$got'"
pass "table_value preserves '/' and '[]' in cell values (byte-delimited, not character-classed)"

got=$(screens::table_value "$work/summary.cp437" "Nonexistent")
[[ -z $got ]] || fail "table_value returns nothing for a label with no row" "got '$got'"
pass "table_value returns empty (not a plausible wrong value) for a missing label"

# ⚠️ The false-positive case, and the reason both separators are REQUIRED.
# "Username" also appears in ordinary prose on the username PROMPT screen
# ("Username> Alphanumeric without spaces (like dhh)"). If table_value
# accepted a row without separators it would happily return
# "> Alphanumeric without spaces (like dhh)" and the pairing check would
# report a mismatch against a screen that is not a table at all.
printf "Let's setup your user account...\nUsername> Alphanumeric without spaces (like dhh)\nenter submit\n" >"$work/prompt.notable"
got=$(screens::table_value "$work/prompt.notable" "Username")
[[ -z $got ]] || fail "table_value must not read prose as a table row" "got '$got'"
pass "table_value refuses a prose line with no cell separators (no false positive)"

# A truncated/half-repainted row -- opening separator but no closing one --
# must yield nothing rather than a partial value that looks fine.
printf ' \263 Username      \263 dec\n' >"$work/summary.truncated"
got=$(screens::table_value "$work/summary.truncated" "Username")
[[ -z $got ]] || fail "table_value must reject a cell with no closing separator" "got '$got'"
pass "table_value rejects a truncated cell rather than returning a partial value"

# ⚠️ Added after mutation testing: deleting the OPENING-separator
# requirement survived the fixtures above, because the prose case is caught
# by the CLOSING check instead. This is the shape that isolates it -- the
# label appearing inside ANOTHER row's value cell, on a line that does have
# a closing separator. Without the opening requirement this returns
# "missing" for the label "Username", which is a confidently wrong answer.
printf ' \263 Warning       \263 Username missing    \263\n' >"$work/summary.labelinvalue"
got=$(screens::table_value "$work/summary.labelinvalue" "Username")
[[ -z $got ]] || fail "table_value must not read a label occurring inside another row's VALUE" "got '$got'"
pass "table_value ignores its label when it appears inside another row's value cell"

# ⚠️ Also added after mutation testing: taking the FIRST match instead of
# the last survived everything above. A scrolled console can show a stale
# copy of the same table above the live one -- the bottom-most row is the
# current screen, the one above it is history.
{
  printf ' \263 Username      \263 dec                 \263\n'
  printf ' -- (screen scrolled; the table was redrawn below) --\n'
  printf ' \263 Username      \263 deck                \263\n'
} >"$work/summary.scrolled"
got=$(screens::table_value "$work/summary.scrolled" "Username")
[[ $got == "deck" ]] || fail "table_value must return the LAST (live) row, not a stale one above it" "got '$got'"
pass "table_value returns the live bottom-most row, not a stale scrolled-off copy"

# ...and the deliberate consequence of that rule: if the LIVE row's cell is
# empty (still being drawn, or genuinely blank), the answer is empty. It
# must NOT fall back to the stale value above, which would be a confident
# lie exactly where the caller most needs a loud failure.
{
  printf ' \263 Username      \263 deck                \263\n'
  printf ' -- (redrawn) --\n'
  printf ' \263 Username      \263                     \263\n'
} >"$work/summary.staleabove"
got=$(screens::table_value "$work/summary.staleabove" "Username")
[[ -z $got ]] || fail "table_value must not fall back to a stale value when the live cell is empty" "got '$got'"
pass "table_value reports the live row's EMPTY cell rather than falling back to a stale value"

# ===========================================================================
# content_digest -- a screen identity immune to vertical shift and nothing else
# ===========================================================================
#
# The measured case: upstream's first rejection of an empty username drops
# its intro line and moves everything below up one row. The wizard did not
# advance, but a raw byte hash called that "the block did not hold".
printf "Let's setup your user account...\n\nUsername> Alphanumeric without spaces (like dhh)\n\nenter submit\n" >"$work/block.before"
printf "\n\nUsername> Alphanumeric without spaces (like dhh)\n\nenter submit\n\n" >"$work/block.after"

[[ $(sha256sum <"$work/block.before" | cut -d' ' -f1) != $(sha256sum <"$work/block.after" | cut -d' ' -f1) ]] ||
  fail "the shift fixture must genuinely differ at the byte level, or it proves nothing"

command grep -av -- "Let's setup your user account" "$work/block.before" >"$work/block.before.less-intro"
[[ $(screens::content_digest "$work/block.before.less-intro") == "$(screens::content_digest "$work/block.after")" ]] ||
  fail "content_digest must see a pure vertical shift plus the pinned intro-line loss as the same screen"
pass "content_digest ignores a whole-screen vertical shift (the measured upstream repaint)"

# ...and NOTHING else. One character different anywhere must still differ.
printf "\n\nUsername> Alphanumeric without spaces (like dhX)\n\nenter submit\n\n" >"$work/block.tampered"
[[ $(screens::content_digest "$work/block.after") != $(screens::content_digest "$work/block.tampered") ]] ||
  fail "content_digest must still catch a single changed character -- otherwise the guard is worthless"
pass "content_digest still catches a single changed character (the guard keeps its strength)"

# ⚠️ Added after mutation testing: deleting the right-trim survived the
# fixtures above (none of them had trailing padding). A real /dev/vcs1
# capture is a space-padded fixed grid, so trailing whitespace is an
# artefact of the grid, never content -- the same screen must digest
# identically however much padding it carries.
printf 'Username> deck\nenter submit\n' >"$work/pad.none"
printf 'Username> deck                    \nenter submit          \n' >"$work/pad.trailing"
[[ $(screens::content_digest "$work/pad.none") == "$(screens::content_digest "$work/pad.trailing")" ]] ||
  fail "content_digest must ignore trailing grid padding"
pass "content_digest ignores trailing grid padding (it is grid, not content)"

# LEADING whitespace is the opposite: indentation is real screen content,
# and a prompt that jumped 20 columns left is a changed screen.
printf '                    Username> deck\nenter submit\n' >"$work/pad.leading"
[[ $(screens::content_digest "$work/pad.none") != $(screens::content_digest "$work/pad.leading") ]] ||
  fail "content_digest must NOT ignore leading indentation -- horizontal position is content"
pass "content_digest treats leading indentation as content (a shifted prompt is a changed screen)"

# A row appearing or disappearing must differ too: this is the half-broken
# repaint the guard exists to catch.
printf "\n\nUsername> Alphanumeric without spaces (like dhh)\n\n" >"$work/block.lostrow"
[[ $(screens::content_digest "$work/block.after") != $(screens::content_digest "$work/block.lostrow") ]] ||
  fail "content_digest must catch a lost row"
pass "content_digest catches a row that vanished from the repaint"

# The blank-screen trap, stated in the function's own docstring: two blank
# captures DO share a digest, so a caller must assert content separately.
# Prove the row-count prefix makes that visible rather than hidden.
printf '\n\n\n' >"$work/block.blank"
# ⚠️ Regression test for a latent bug this fixture exposed: nonblank_rows
# used to print "0\n0" on a file with no matches (grep -c prints 0 AND exits
# 1, so the `|| echo 0` fallback fired as well). A caller doing
# `[[ $(screens::nonblank_rows f) -gt 0 ]]` got a bash error, not an answer.
got=$(screens::nonblank_rows "$work/block.blank")
[[ $got == "0" ]] || fail "nonblank_rows returns exactly '0' (one line) for a blank file" "got '$got'"
[[ $(screens::nonblank_rows "$work/no-such-file-at-all") == "0" ]] ||
  fail "nonblank_rows returns exactly '0' for a missing file"
pass "nonblank_rows returns a single clean '0' for blank and missing files (not '0\\n0')"
[[ $(screens::content_digest "$work/block.blank") == 0:* ]] ||
  fail "content_digest must expose a blank screen as row count 0" "got '$(screens::content_digest "$work/block.blank")'"
pass "content_digest exposes a blank screen as '0:...' so a vacuous block is visible"

# ===========================================================================
# guard 1 / A5: advance-and-vanish
# ===========================================================================

printf 'Beautiful, Modern & Opinionated Linux by DHH\nPress Return to Start Install\n' >"$work/before.greeter"
printf "Let's setup your machine...\nSelect keyboard layout\n> English (US)\n" >"$work/after.keyboard"

screens::advance_and_vanish "$work/before.greeter" "$work/after.keyboard" \
  "Select keyboard layout" "Press Return to Start Install" ||
  fail "advance_and_vanish accepts a real transition (greeter -> keyboard step)"
pass "advance_and_vanish accepts a real transition (both halves proven)"

# lie #1, reproduced on purpose: a screen that never changed. Both markers
# happen to already coexist on one screen (a status line that mentions both
# words) -- a NAIVE check (just "is the next marker present") would pass
# here. advance_and_vanish must not.
printf 'Select keyboard layout\nPress Return to Start Install (fallback help text)\n' >"$work/naive.same"
if screens::advance_and_vanish "$work/naive.same" "$work/naive.same" \
     "Select keyboard layout" "Press Return to Start Install" 2>/dev/null; then
  fail "advance_and_vanish must reject a 'transition' where nothing actually changed"
fi
pass "advance_and_vanish rejects a screen asserted against itself (lie #1, reproduced and caught)"

# the outgoing marker never having been there in the first place is also a
# failure -- it means "vanishing" proves nothing.
printf 'some other screen entirely\n' >"$work/before.wrong"
if screens::advance_and_vanish "$work/before.wrong" "$work/after.keyboard" \
     "Select keyboard layout" "Press Return to Start Install" 2>/dev/null; then
  fail "advance_and_vanish must reject when the vanishing marker was never present in 'before'"
fi
pass "advance_and_vanish rejects when the outgoing marker was never there to vanish"

# ⚠️ THE FOURTH SUB-CHECK NEEDED ITS OWN NEGATIVE CASE, and did not have one.
# Found by mutation while salvaging this file: deleting the "appearing marker
# is not present in `after`" branch entirely left every assertion above green,
# because each of the other three fixtures happens to trip a different branch.
# The case it misses is a screen that DID change and then showed nothing we
# recognise -- a wizard that crashed, blanked, or scrolled its prompt off --
# which the harness would read as "advanced" and march straight past.
printf 'a screen that is neither of the two\n' >"$work/after.blank"
if screens::advance_and_vanish "$work/before.greeter" "$work/after.blank" \
     "Select keyboard layout" "Press Return to Start Install" 2>/dev/null; then
  fail "advance_and_vanish must reject when the incoming marker never appeared"
fi
pass "advance_and_vanish rejects a screen that changed but never showed the next marker"

# The remaining two sub-checks were masked the same way, and each has a shape
# a real console actually produces -- so each gets a fixture that trips ONLY
# that branch. Together with the two above, all four are now individually
# proven (mutation-checked, one branch disabled at a time).
#
# (a) The console SCROLLED instead of clearing: the next prompt appeared, but
#     the previous one is still on screen above it. Only "the vanishing marker
#     is still there" can catch this, and on a 25-row tty it is the likely
#     case, not the exotic one.
printf "Press Return to Start Install\nSelect keyboard layout\n> English (US)\n" >"$work/after.scrolled"
if screens::advance_and_vanish "$work/before.greeter" "$work/after.scrolled" \
     "Select keyboard layout" "Press Return to Start Install" 2>/dev/null; then
  fail "advance_and_vanish must reject when the outgoing marker is still on screen"
fi
pass "advance_and_vanish rejects a scrolled console still showing the old prompt"

# (b) Lie #1 in its exact spec form: the INCOMING marker was already visible
#     on the previous screen (help text, a menu heading, a wrapped fragment),
#     so its presence afterwards proves nothing. Distinct from naive.same
#     above, where nothing changed at all -- here the screen really did
#     advance, and the marker is still worthless as evidence.
printf 'Press Return to Start Install\nNext: Select keyboard layout\n' >"$work/before.foreshadow"
if screens::advance_and_vanish "$work/before.foreshadow" "$work/after.keyboard" \
     "Select keyboard layout" "Press Return to Start Install" 2>/dev/null; then
  fail "advance_and_vanish must reject an incoming marker that was already visible before"
fi
pass "advance_and_vanish rejects an incoming marker that was already on the previous screen"

# ===========================================================================
# guard 2: the input path might be silently dead
# ===========================================================================

screens::assert_input_path_live 1 "Username> deck" "deck" ||
  fail "assert_input_path_live accepts a genuinely live, bound, delivering channel"
pass "assert_input_path_live accepts a real, live input path"

if screens::assert_input_path_live 0 "Username> deck" "deck" 2>/dev/null; then
  fail "assert_input_path_live must reject when the channel never confirmed bound"
fi
pass "assert_input_path_live rejects an unbound channel, distinctly"

# the R-8/R-31 case: bound, but silent -- an enumerated, live-looking node
# that never actually delivers the keystroke.
if screens::assert_input_path_live 1 "Username> " "deck" 2>/dev/null; then
  fail "assert_input_path_live must reject 'bound but nothing arrived' (the R-8/R-31 silent-node case)"
fi
pass "assert_input_path_live rejects a bound-but-silent channel (R-8/R-31 shape)"

# ===========================================================================
# guard 3: vacuous passes
# ===========================================================================

: >"$work/empty.report"
if screens::require_report "$work/empty.report" 2>/dev/null; then
  fail "require_report must hard-fail on an empty report (never a silent skip)"
fi
pass "require_report hard-fails on an empty report"

if screens::require_report "$work/no-such-report" 2>/dev/null; then
  fail "require_report must hard-fail on a missing report"
fi
pass "require_report hard-fails on a missing report"

printf 'greeter.wait_s=4\ngreeter.found=1\n' >"$work/no-liveness.report"
if screens::require_report "$work/no-liveness.report" 2>/dev/null; then
  fail "require_report must hard-fail when unit.ran=1 is absent, even with other content present"
fi
pass "require_report hard-fails when the probe's own liveness marker never arrived"

printf 'unit.ran=1\ngreeter.wait_s=4\ngreeter.found=1\n' >"$work/good.report"
screens::require_report "$work/good.report" ||
  fail "require_report accepts a real report with unit.ran=1 present"
pass "require_report accepts a real report"

got=$(screens::field "$work/good.report" greeter.wait_s)
[[ $got == "4" ]] || fail "field extracts the right value" "got '$got'"
pass "field extracts a key's value from a report fixture"

if screens::field "$work/good.report" no.such.key >/dev/null 2>&1; then
  fail "field must fail (not print empty) when the key is absent"
fi
pass "field fails, rather than silently printing empty, for an absent key"

# extract_section: pulling one named screen capture out of an assembled
# report, the step that lets advance_and_vanish run against a REAL VM run's
# report instead of only against hand-built fixtures.
cat >"$work/multi.report" <<'EOF'
unit.ran=1
--- screen.00-greeter ---
Beautiful, Modern & Opinionated Linux by DHH
Press Return to Start Install
--- screen.01-keyboard ---
Let's setup your machine...
Select keyboard layout
> English (US)
--- screen.02-username ---
Username> Alphanumeric without spaces (like dhh)
EOF
screens::extract_section "$work/multi.report" "01-keyboard" "$work/extracted"
want=$'Let\x27s setup your machine...\nSelect keyboard layout\n> English (US)'
got=$(cat "$work/extracted")
[[ $got == "$want" ]] || fail "extract_section pulls exactly one named section, no more no less" "got: $got"
pass "extract_section pulls exactly the named section (middle of three, bounded both sides)"

screens::extract_section "$work/multi.report" "00-greeter" "$work/extracted-first"
screens::marker_present "$work/extracted-first" "Press Return to Start Install" ||
  fail "extract_section handles the FIRST section correctly"
screens::marker_present "$work/extracted-first" "Select keyboard layout" &&
  fail "extract_section must not leak the NEXT section's content into this one"
pass "extract_section handles the first section and does not leak the next one in"

screens::extract_section "$work/multi.report" "no-such-section" "$work/extracted-missing"
[[ ! -s "$work/extracted-missing" ]] || fail "extract_section produces an empty file for a section that doesn't exist"
pass "extract_section produces an empty (not garbage) file for a missing section name"

# the denominator: always printed, reflects exactly what ran
SCREENS_CHECKS_TOTAL=0
SCREENS_CHECKS_PASSED=0
screens::check "one" "x" "x" >/dev/null
screens::check "two" "x" "y" >/dev/null 2>&1 || true
denom=$(screens::denominator)
[[ $denom == "1/2 checks passed" ]] || fail "denominator reflects exactly what ran" "got '$denom'"
pass "denominator always reflects exactly how many checks ran and how many passed (1/2)"

# ===========================================================================
# guard 4: a guard nobody has seen fail
# ===========================================================================

screens::assert_blocking_held "Username>" "Username>" ||
  fail "assert_blocking_held accepts a real block (screen identity unchanged after skip attempts)"
pass "assert_blocking_held accepts a genuine block"

if screens::assert_blocking_held "Username>" "Password>" 2>/dev/null; then
  fail "assert_blocking_held must reject when the screen identity changed -- the block did not hold"
fi
pass "assert_blocking_held reproduces and catches a block that did NOT hold (the guard's own negative case)"

# ===========================================================================
# A2/A3: artefact pairing
# ===========================================================================

screens::assert_pair "username" "deck" "deck" ||
  fail "assert_pair accepts a screen/artefact match"
pass "assert_pair accepts a matching pair"

if screens::assert_pair "username" "deck" "dock" 2>/dev/null; then
  fail "assert_pair must reject a screen/artefact MISMATCH -- this is the bug invisible to either check alone"
fi
pass "assert_pair rejects a mismatch (the pairing bug neither half alone would catch)"

# ===========================================================================
# guard 5: testing the wrong world
# ===========================================================================

got=$(screens::capability_scope_label qmp-sendkey)
[[ $got == *"lizard-mode-equivalent"* ]] || fail "capability_scope_label labels qmp-sendkey correctly" "got '$got'"
pass "capability_scope_label correctly scopes qmp-sendkey as lizard-mode-equivalent"

got=$(screens::capability_scope_label uinput-pad)
[[ $got == *"lizard_mode=N"* ]] || fail "capability_scope_label labels uinput-pad correctly" "got '$got'"
pass "capability_scope_label correctly scopes uinput-pad as the lizard_mode=N path"

echo "ALL PRIMITIVE TESTS PASSED"
