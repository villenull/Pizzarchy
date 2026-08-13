#!/usr/bin/env bash
# Unit tests for iso/overlay/configs/airootfs/usr/share/omarchy-iso/deck-form.sh
#
# No VM, no gum, no real mapper, no Deck: every collaborator deck-form.sh
# would normally reach for on the real ISO (the lizard sysfs knob,
# deck-input-mapper, setup-form.sh's reserved-username list, a controlling
# tty, `gum`) is pointed at a fixture or a fake script here, via the
# override variables deck-form.sh's own functions expose for exactly this
# purpose (DECK_TEXT_PROMPT_LIZARD_SYSFS, _MAPPER_BIN, _DEADLINE,
# DECK_S0_TTY, DECK_SETUP_FORM_SH_OVERRIDE). Same split
# test-installer-harness-primitives.sh already uses for the [V]-tier
# harness's own pure half: this suite is the checking logic worth trusting,
# proven without a VM; the interactive gum flow itself is [V]/[H] territory
# and is explicitly NOT re-proven here (see deck-form.sh's own header for
# what is and is not built).

set -euo pipefail

# ⚠️ SUITE-LEVEL WATCHDOG -- this suite tests a WAIT LOOP, so its regressions
# hang rather than return wrong. `deck_form_wait_for_marker` polls until a
# marker appears or a deadline passes; break the deadline and every assertion
# that reaches it (directly, and indirectly through deck_form_text_prompt)
# blocks forever. In CI that is not a red test, it is a stuck job that
# reports NOTHING -- strictly worse than a failure, and the same class of
# problem as a check that passes while asserting nothing.
#
# Proven, not assumed: disabling the deadline branch in deck-form.sh hangs
# this suite past 120s. With this line it exits 124 instead, which is a
# failure CI already knows how to read. Re-exec rather than backgrounding a
# killer process, so there is nothing to leak if the suite exits early.
if [[ -z ${DECK_FORM_TEST_WATCHDOG:-} ]]; then
  export DECK_FORM_TEST_WATCHDOG=1
  exec timeout --signal=KILL 120 "$0" "$@"
fi

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

# The file under test, named ONCE. Moved 2026-08-12 (T5e) from src/deck-form.sh
# to its shipped path inside the ISO overlay -- iso/bin/build rsyncs
# overlay/configs/ over the scratch upstream tree, so this path IS
# /usr/share/omarchy-iso/deck-form.sh on the built ISO, which is exactly the
# path iso/overlay/patches/deck-form-invocation.patch sources. One copy, no
# src/ duplicate. Asserted below rather than assumed, because a suite that
# silently sources a stale second copy is worse than one that cannot find it.
DECK_FORM_SH="$REPO_ROOT/iso/overlay/configs/airootfs/usr/share/omarchy-iso/deck-form.sh"
[[ -f $DECK_FORM_SH ]] || {
  printf 'not ok - the file under test exists at its shipped overlay path\n'
  printf '%s\n' "expected $DECK_FORM_SH" >&2
  exit 1
}
[[ ! -e "$REPO_ROOT/src/deck-form.sh" ]] || {
  printf 'not ok - deck-form.sh exists in BOTH src/ and the overlay\n'
  printf '%s\n' "The promotion is a git mv, not a copy: two divergent copies of a 107KB file is worse than either location alone (test-iso-build.sh applies the same rule to patches)." >&2
  exit 1
}

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; [[ -n ${2:-} ]] && printf '%s\n' "$2" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# 🔴 SUITE-LEVEL SAFETY, not a convenience. deck_form_pin_console_keymap runs
# `loadkeys` whenever `tty` reports a Linux virtual console (§5.20a), and
# `deck_form_text_prompt` calls it on EVERY prompt. Run this suite from a real
# VT (Ctrl+Alt+F2) with no override and it would re-key the developer's own
# console. Pointing the tty probe at a pts name -- the "not a virtual console"
# branch -- makes the default for every test in this file "loadkeys is never
# executed". The tests that mean to exercise the pin set the override to a
# /dev/tty* name themselves AND put a fake `loadkeys` on PATH; nothing here
# ever reaches the real binary.
export DECK_FORM_TTY_OVERRIDE=/dev/pts/deck-form-test

# deck-form.sh does not `set -euo pipefail` itself (source-safety -- see its
# own header). Source it under THIS suite's stricter mode so a real bug
# (an unset variable, a broken pipe inside a function) still surfaces here,
# the same way test-installer-harness-primitives.sh sources
# vm-installer-screens.sh (which makes the identical -uo-only choice) under
# its own `set -euo pipefail`.
# shellcheck source=../../iso/overlay/configs/airootfs/usr/share/omarchy-iso/deck-form.sh
source "$DECK_FORM_SH"

# ===========================================================================
# Stubs for upstream `configurator` helpers this file's screen OVERRIDES
# call but does not itself define -- clear_logo/say/step/abort/
# get_root_disk/get_disk_info are all real functions in the real
# `configurator` (READ), not in deck-form.sh, so sourcing deck-form.sh
# ALONE (this suite's whole point -- no VM, no real configurator) leaves
# them undefined. Minimal stand-ins, not reimplementations of upstream's
# real behaviour: just enough for the screen functions to run to completion
# so THIS file's own logic (which is what this suite is actually proving)
# can be exercised. `abort` is deliberately non-fatal here (`return 1`, not
# upstream's real `exit 1`) so a path that reaches it fails an assertion
# instead of killing the whole test process.
#
# ⚠️ MOVED TO THE TOP 2026-08-12, and the move is load-bearing: `greeter`
# now runs S1 at the end of it (deck-form.sh's own "WHERE THIS SCREEN IS
# CALLED FROM" comment), and S1 calls `step`/`say`. With the stubs defined
# further down the file, the S0 test would have died on "step: command not
# found" -- which under this suite's `set -e` is an abort, not a legible
# failure.
# ===========================================================================

clear_logo() { :; }
say() { printf '%s\n' "$*" >>"${DECK_TEST_SAY_LOG:-/dev/null}"; }
step() { printf '%s\n' "$*" >>"${DECK_TEST_SAY_LOG:-/dev/null}"; }
abort() { printf 'ABORT: %s\n' "$*" >&2; return 1; }
get_root_disk() { printf '%s\n' "${DECK_TEST_ROOT_DISK:-}"; }
get_disk_info() { printf '%s\n' "$1"; }

# A dispatching fake `gum` -- confirm/choose/input/table, everything else
# no-ops.
#
# ⚠️ THE QUEUE, AND WHY A HANG IS THE FAILURE MODE THIS GUARDS AGAINST.
# S1's screen is a LOOP: a cancelled menu redraws (deliberately -- see
# deck_form_net_choice_action's own comment on S8's Esc-drops-to-shell
# bug), so a fake that returns the same answer forever spins forever, and
# a spinning CI job reports nothing. FAKE_GUM_CHOOSE_QUEUE consumes one
# scripted line per call; when it runs dry the fake answers with
# FAKE_GUM_CHOOSE_EXHAUSTED (the tests set this to the Skip row, which
# terminates the screen) and writes CHOOSE-QUEUE-EXHAUSTED to the log, so
# a test that relied on the queue can assert it was never reached. That
# turns "hangs until the watchdog kills the suite" into "answers wrong,
# visibly" -- the same reasoning as the suite-level watchdog above.
# `<CANCEL>` is the sentinel for gum exiting nonzero (B/Esc).
#
# With no queue set the old single-answer behaviour is unchanged, so every
# pre-existing test in this file is untouched by the addition.
mkdir -p "$work/bin-fakegum"
cat >"$work/bin-fakegum/gum" <<'FAKEGUM'
#!/usr/bin/env bash
sub=${1:-}
printf '%s\n' "$*" >>"${FAKE_GUM_LOG:-/dev/null}"

pop_queue() {   # <queue-file> -> prints the popped line, status 1 if dry
  local q=$1 line
  line=$(head -1 "$q" 2>/dev/null)
  [[ -z $line ]] && return 1
  tail -n +2 "$q" >"$q.tmp" 2>/dev/null && mv "$q.tmp" "$q"
  printf '%s\n' "$line"
  return 0
}

case "$sub" in
  confirm) exit "${FAKE_GUM_CONFIRM_RC:-0}" ;;
  choose)
    if [[ -n ${FAKE_GUM_CHOOSE_QUEUE:-} ]]; then
      if line=$(pop_queue "$FAKE_GUM_CHOOSE_QUEUE"); then
        [[ $line == '<CANCEL>' ]] && exit 1
        printf '%s\n' "$line"
        exit 0
      fi
      printf 'CHOOSE-QUEUE-EXHAUSTED\n' >>"${FAKE_GUM_LOG:-/dev/null}"
      printf '%s\n' "${FAKE_GUM_CHOOSE_EXHAUSTED:-}"
      exit 0
    fi
    [[ -n ${FAKE_GUM_CHOOSE_RC:-} && ${FAKE_GUM_CHOOSE_RC} != 0 ]] && exit "$FAKE_GUM_CHOOSE_RC"
    printf '%s\n' "${FAKE_GUM_CHOOSE_OUTPUT:-}"
    exit 0
    ;;
  input)
    if [[ -n ${FAKE_GUM_INPUT_QUEUE:-} ]]; then
      if line=$(pop_queue "$FAKE_GUM_INPUT_QUEUE"); then
        [[ $line == '<CANCEL>' ]] && exit 1
        [[ $line == '<EMPTY>' ]] && exit 0
        printf '%s\n' "$line"
        exit 0
      fi
      printf 'INPUT-QUEUE-EXHAUSTED\n' >>"${FAKE_GUM_LOG:-/dev/null}"
      exit 0
    fi
    printf '%s\n' "${FAKE_GUM_INPUT_OUTPUT:-}"
    exit 0
    ;;
  table) cat; exit 0 ;;
  *) exit 0 ;;
esac
FAKEGUM
chmod +x "$work/bin-fakegum/gum"

# ===========================================================================
# §2.3: the bounded text-entry mode
# ===========================================================================

echo "--- deck_form_lizard_write -------------------------------------------"

printf 'Y\n' >"$work/lizard.knob"
deck_form_lizard_write "$work/lizard.knob" N ||
  fail "lizard_write succeeds against an existing, writable file"
[[ $(cat "$work/lizard.knob") == N ]] ||
  fail "lizard_write actually wrote the new value"
pass "lizard_write writes to an existing file"

# §2.3's explicit QEMU branch: a MISSING file is "not applicable, continue"
# -- must return 0 (not a failure), not attempt a write, and must say so.
out=$(deck_form_lizard_write "$work/no-such-knob" N 2>&1) ||
  fail "lizard_write on a MISSING path must return 0 (§2.3: not a failure, just not applicable)"
[[ $out == *"not applicable"* ]] ||
  fail "lizard_write on a missing path must say so, not go silent" "got: $out"
[[ ! -e "$work/no-such-knob" ]] ||
  fail "lizard_write must not CREATE the path when it was absent"
pass "lizard_write on a missing knob degrades (returns 0, warns, creates nothing) -- the §2.3 QEMU branch"

echo "--- deck_form_wait_for_marker ------------------------------------------"

# --- the cross-file contract: this marker is the MAPPER'S line -------------
#
# Same discipline as DECK_CONSOLE_KEYMAP above, and the same failure if it is
# skipped. DECK_OSK_BOUND_MARKER is not a string this file invented: it is
# what src/deck-input-mapper.py prints when it is ready to deliver keystrokes
# (its `BOUND_MARKER`). Two files, two languages, one string, and if they ever
# drift NOTHING here goes red on its own -- every prompt just waits out its
# five seconds and degrades, on a real ISO, silently as far as this suite is
# concerned. Both suites check it, so whichever one the next editor runs fails.
mapper_marker=$(sed -n 's/^BOUND_MARKER = "\(.*\)"$/\1/p' "$REPO_ROOT/src/deck-input-mapper.py")
[[ -n $mapper_marker ]] ||
  fail "could not find 'BOUND_MARKER = ' in src/deck-input-mapper.py -- this cross-check is broken, not the code"
[[ $mapper_marker == "$DECK_OSK_BOUND_MARKER" ]] ||
  fail "DECK_OSK_BOUND_MARKER ('$DECK_OSK_BOUND_MARKER') and the mapper's BOUND_MARKER ('$mapper_marker') disagree -- every text prompt would wait out its deadline and degrade, with nothing on either side saying why"
pass "DECK_OSK_BOUND_MARKER is exactly the mapper's BOUND_MARKER ('$mapper_marker')"

# ...and the argv this file spawns it with is argv the mapper accepts. A flag
# renamed on that side makes argparse exit 2 before a single line is printed,
# which arrives here as the same silent five-second degrade.
for flag in "${DECK_MAPPER_ARGS[@]}"; do
  LC_ALL=C grep -qF -- "\"${flag%%=*}\"" "$REPO_ROOT/src/deck-input-mapper.py" ||
    fail "deck-form.sh spawns the mapper with '${flag}', but src/deck-input-mapper.py declares no '${flag%%=*}' -- argparse would reject the whole command line"
done
pass "every flag in DECK_MAPPER_ARGS (${DECK_MAPPER_ARGS[*]}) is one src/deck-input-mapper.py declares"

printf 'deck-input-mapper: bound\n' >"$work/mapper.out"
deck_form_wait_for_marker "$work/mapper.out" "deck-input-mapper: bound" 1 0.05 ||
  fail "wait_for_marker finds a marker that is already there"
pass "wait_for_marker returns immediately when the marker is already present"

: >"$work/mapper-empty.out"
start=$(date +%s%N)
if deck_form_wait_for_marker "$work/mapper-empty.out" "deck-input-mapper: bound" 0.2 0.05; then
  fail "wait_for_marker must time out (return 1) when the marker never appears"
fi
end=$(date +%s%N)
elapsed_ms=$(( (end - start) / 1000000 ))
[[ $elapsed_ms -ge 150 ]] ||
  fail "wait_for_marker returned too fast to have actually waited out the deadline" "elapsed=${elapsed_ms}ms"
pass "wait_for_marker times out (never blocks past the deadline) after ~${elapsed_ms}ms"

echo "--- deck_form_text_prompt ----------------------------------------------"

# A fake mapper: prints the bound marker immediately, then sleeps so it is
# still alive for the pid/kill assertions below.
cat >"$work/fake-mapper-bound" <<'EOF'
#!/usr/bin/env bash
echo "deck-input-mapper: bound"
sleep 30
EOF
chmod +x "$work/fake-mapper-bound"

cat >"$work/fake-mapper-silent" <<'EOF'
#!/usr/bin/env bash
sleep 30
EOF
chmod +x "$work/fake-mapper-silent"

fake_prompt_ok()   { printf 'osk_up=%s\n' "${DECK_FORM_OSK_UP:-unset}"; return 0; }
fake_prompt_fail() { return 7; }

# --- case 1: mapper binds within the deadline ---
# (stderr silenced here: THIS suite's own top-level `trap ... EXIT` means
# text_prompt correctly detects an already-owned EXIT trap and warns that
# its safety net is not armed -- expected and benign for every in-process
# call in this file; the dedicated safety-net cases further down run in a
# separate bash process specifically so that collision does not apply.)
printf 'Y\n' >"$work/lizard1"
DECK_TEXT_PROMPT_LIZARD_SYSFS="$work/lizard1" \
DECK_TEXT_PROMPT_MAPPER_BIN="$work/fake-mapper-bound" \
DECK_TEXT_PROMPT_DEADLINE=2 \
  out=$(deck_form_text_prompt fake_prompt_ok 2>/dev/null) ||
  fail "text_prompt propagates the prompt fn's own success"
[[ $out == "osk_up=1" ]] ||
  fail "text_prompt sets DECK_FORM_OSK_UP=1 when the mapper reports bound" "got: $out"
[[ $(cat "$work/lizard1") == Y ]] ||
  fail "text_prompt restores lizard mode to Y after a normal return"
pass "text_prompt: mapper binds -> OSK up, prompt runs, lizard mode restored to Y"

# the mapper process itself must be gone afterward -- not just "cleanup ran"
# but "the thing cleanup was supposed to kill is actually dead".
sleep 0.2
if pgrep -f "$work/fake-mapper-bound" >/dev/null 2>&1; then
  fail "text_prompt must have killed the mapper process on the way out"
fi
pass "text_prompt kills the mapper process it started"

# --- case 2: mapper never reports bound (degrade path) ---
printf 'Y\n' >"$work/lizard2"
out=$(DECK_TEXT_PROMPT_LIZARD_SYSFS="$work/lizard2" \
      DECK_TEXT_PROMPT_MAPPER_BIN="$work/fake-mapper-silent" \
      DECK_TEXT_PROMPT_DEADLINE=0.2 \
      deck_form_text_prompt fake_prompt_ok 2>"$work/warnings2")
[[ $out == "osk_up=0" ]] ||
  fail "text_prompt sets DECK_FORM_OSK_UP=0 when the mapper never reports bound" "got: $out"
LC_ALL=C grep -qF "did not report bound" "$work/warnings2" ||
  fail "text_prompt must WARN (not silently degrade) when the OSK never comes up"
[[ $(cat "$work/lizard2") == Y ]] ||
  fail "text_prompt still restores Y even when the mapper never bound"
pass "text_prompt: mapper never binds -> degrades LOUDLY, prompt still runs, lizard mode still restored"

# --- case 3: mapper binary missing entirely ---
printf 'Y\n' >"$work/lizard3"
out=$(DECK_TEXT_PROMPT_LIZARD_SYSFS="$work/lizard3" \
      DECK_TEXT_PROMPT_MAPPER_BIN="$work/no-such-mapper-binary" \
      deck_form_text_prompt fake_prompt_ok 2>"$work/warnings3")
[[ $out == "osk_up=0" ]] ||
  fail "text_prompt handles a missing mapper binary as osk_up=0, not a crash"
LC_ALL=C grep -qF "mapper not found" "$work/warnings3" ||
  fail "text_prompt must say the mapper binary was not found"
[[ $(cat "$work/lizard3") == Y ]] ||
  fail "text_prompt still restores Y with no mapper at all"
pass "text_prompt: no mapper binary -> degrades cleanly, still restores lizard mode"

# --- case 4: the lizard sysfs knob itself is absent (§2.3's QEMU branch,
# exercised through the WHOLE function, not just lizard_write in isolation) ---
out=$(DECK_TEXT_PROMPT_LIZARD_SYSFS="$work/no-such-lizard-knob" \
      DECK_TEXT_PROMPT_MAPPER_BIN="$work/fake-mapper-bound" \
      DECK_TEXT_PROMPT_DEADLINE=2 \
      deck_form_text_prompt fake_prompt_ok 2>"$work/warnings4")
[[ $out == "osk_up=1" ]] ||
  fail "text_prompt still runs the OSK path when the lizard knob is absent (QEMU) -- the mapper itself doesn't need the knob to start"
[[ ! -e "$work/no-such-lizard-knob" ]] ||
  fail "text_prompt must not have CREATED the lizard knob path"
pass "text_prompt: absent lizard knob (§2.3 QEMU branch) -- degrades, creates nothing, still runs the prompt"

# --- case 5: the prompt fn itself fails -- its exit code must propagate,
# AND cleanup must still have happened ---
printf 'Y\n' >"$work/lizard5"
set +e
DECK_TEXT_PROMPT_LIZARD_SYSFS="$work/lizard5" \
DECK_TEXT_PROMPT_MAPPER_BIN="$work/fake-mapper-bound" \
DECK_TEXT_PROMPT_DEADLINE=2 \
  deck_form_text_prompt fake_prompt_fail 2>/dev/null
rc=$?
set -e
[[ $rc -eq 7 ]] ||
  fail "text_prompt must propagate the prompt fn's own nonzero exit status" "got rc=$rc"
[[ $(cat "$work/lizard5") == Y ]] ||
  fail "text_prompt must still restore lizard mode to Y even when the prompt fn fails"
pass "text_prompt propagates a failing prompt fn's exit code AND still restores lizard mode"

echo "--- text_prompt's EXIT-trap safety net (the 'including set -e' half) --"

# Simulate an abort INSIDE prompt_fn that this file's ordinary
# post-return cleanup line can never reach (an unguarded `exit`, standing
# in for an uncaught `set -e` abort in whatever shell this file happens to
# be sourced into). Run the whole thing in a SEPARATE bash process so the
# `exit` cannot take this test suite down with it.
printf 'Y\n' >"$work/lizard-exit"
cat >"$work/exit-abort-test.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
source "$DECK_FORM_SH"
aborts() { exit 42; }
DECK_TEXT_PROMPT_LIZARD_SYSFS="$work/lizard-exit" \
DECK_TEXT_PROMPT_MAPPER_BIN="$work/fake-mapper-bound" \
DECK_TEXT_PROMPT_DEADLINE=2 \
  deck_form_text_prompt aborts
EOF
chmod +x "$work/exit-abort-test.sh"
set +e
"$work/exit-abort-test.sh"
subrc=$?
set -e
[[ $subrc -eq 42 ]] ||
  fail "sanity: the abort subshell should exit 42" "got $subrc"
sleep 0.2
[[ $(cat "$work/lizard-exit") == Y ]] ||
  fail "the EXIT-trap safety net must restore lizard mode to Y even when prompt_fn calls exit directly" "got: $(cat "$work/lizard-exit")"
if pgrep -f "$work/fake-mapper-bound" >/dev/null 2>&1; then
  # a leftover process from an EARLIER case would also match this pattern;
  # only fail if one is still alive AFTER this specific abort case, which
  # cleanup should have caught via the EXIT trap.
  fail "the EXIT-trap safety net must have killed the mapper too"
fi
pass "text_prompt's EXIT-trap safety net restores lizard mode AND kills the mapper on an abort inside prompt_fn"

# --- case 6: an EXIT trap already owned by someone else must NOT be
# clobbered -- text_prompt must warn and skip arming its own safety net. ---
cat >"$work/exit-owned-test.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
source "$DECK_FORM_SH"
: >"$work/someone-elses-trap-fired"
trap 'echo fired >"$work/someone-elses-trap-fired"' EXIT
ok() { return 0; }
DECK_TEXT_PROMPT_LIZARD_SYSFS="$work/lizard-owned" \
DECK_TEXT_PROMPT_MAPPER_BIN="$work/fake-mapper-bound" \
DECK_TEXT_PROMPT_DEADLINE=2 \
  deck_form_text_prompt ok 2>"$work/owned-warnings"
EOF
chmod +x "$work/exit-owned-test.sh"
printf 'Y\n' >"$work/lizard-owned"
"$work/exit-owned-test.sh"
LC_ALL=C grep -qF "already installed" "$work/owned-warnings" ||
  fail "text_prompt must warn when it will not arm its safety net because EXIT is already owned"
[[ $(cat "$work/someone-elses-trap-fired") == fired ]] ||
  fail "text_prompt must NOT have clobbered a pre-existing EXIT trap -- it should still have fired"
pass "text_prompt does not clobber a pre-existing EXIT trap; it warns and skips its own safety net instead"

# ===========================================================================
# S0: Welcome and disclosure
# ===========================================================================

echo "--- S0 (deck_form_s0_text / greeter) ------------------------------------"

s0=$(deck_form_s0_text)
LC_ALL=C grep -qF "proprietary firmware" <<<"$s0" ||
  fail "S0 text must contain the firmware disclosure sentence"
LC_ALL=C grep -qF "erases the internal drive" <<<"$s0" ||
  fail "S0 text must contain the erasure warning"
LC_ALL=C grep -qF "Press A to begin" <<<"$s0" ||
  fail "S0 text must contain the prompt line"
pass "deck_form_s0_text contains the firmware disclosure, the erasure warning, and the prompt line"

# a fake `stty` on PATH that just records it was invoked with 'sane'.
mkdir -p "$work/bin"
cat >"$work/bin/stty" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == sane ]] && printf 'sane-called\n' >>"$STTY_MARKER"
exit 0
EOF
chmod +x "$work/bin/stty"

printf '\n' >"$work/fake-tty-input"   # one blank line, standing in for an Enter
# ⚠️ STTY_MARKER must be a genuine environment-prefix on the COMMAND itself
# (inside the command substitution), not a plain shell-variable assignment
# ahead of `out=$(...)` -- the latter never reaches the fake `stty`, since
# that runs as a separate execve'd process and only reads its real
# environment, not this shell's unexported variables. Found by running this
# exact test: the first draft put the assignments before `out=$(greeter)`
# and the marker file was silently never created.
#
# ⚠️ greeter now runs S1 at the end of it, so its collaborators must be
# pointed at fixtures here or this test reaches the REAL /sys/class/net and
# behaves differently on a laptop (which has a wireless interface) than in
# CI (which may not) -- a test whose result depends on the machine it runs
# on is not a test. An EMPTY sysfs root is the "no Wi-Fi hardware" branch,
# which §5 requires to be non-blocking, so S0 still completes.
mkdir -p "$work/net-empty" "$work/s0-state"
out=$(STTY_MARKER="$work/stty.marker" PATH="$work/bin:$work/bin-fakegum:$PATH" \
      DECK_S0_TTY="$work/fake-tty-input" \
      DECK_NET_SYSFS="$work/net-empty" \
      DECK_NET_STATE_DIR="$work/s0-state" \
      DECK_TEST_SAY_LOG="$work/s0-say.log" \
      greeter)
[[ -f "$work/stty.marker" ]] ||
  fail "greeter must call 'stty sane' -- losing it silently kills every gum prompt after S0 (T4-screen-spec.md §4 S0)"
LC_ALL=C grep -qF "proprietary firmware" <<<"$out" ||
  fail "greeter's own output must include the S0 text, not just stty side effects"
pass "greeter calls 'stty sane' and prints the S0 disclosure text"

# 🔴 THE WIRING ASSERTION. §3 promotes Wi-Fi to first and upstream has no
# Wi-Fi screen to override, so S1's ONLY route onto a real ISO is the tail
# of `greeter`. Without this, S1 could be perfectly built, perfectly unit
# tested, and never appear -- the exact failure the override-name contract
# below exists to prevent, in the one shape that contract cannot see
# (deck_form_wifi_screen is `deck_form_`-prefixed, so the scanner skips it).
[[ -f "$work/s0-state/$DECK_NET_OUTCOME_FILE" ]] ||
  fail "greeter must run the S1 Wi-Fi screen -- no outcome file was written, so S1 never ran at all"
LC_ALL=C grep -qF "status=no-hardware" "$work/s0-state/$DECK_NET_OUTCOME_FILE" ||
  fail "S1, reached through greeter with an empty sysfs net root, must record the no-hardware outcome" \
       "$(cat "$work/s0-state/$DECK_NET_OUTCOME_FILE")"
pass "greeter actually runs S1 (the outcome artefact proves the screen ran, not just that it is defined)"

# ===========================================================================
# §5.20a -- S2b: the keyboard layout.
#
# 🔴 WHAT THIS SECTION IS ACTUALLY FOR. Upstream's `keyboard_form` ends with
# `loadkeys "$keyboard"` (configurator:225) and `user_form` then prompts for
# the ACCOUNT PASSWORD (configurator:246, :253). Our OSK emits US keycodes,
# so under a non-`us` console keymap the password becomes different
# characters -- and the field is MASKED, so nobody sees it happen.
#
# An assertion that `keyboard_form` merely EXISTS would pass with the defect
# fully intact. So the assertions below are about ORDER AND EFFECT: what
# keymap was in force at the instant the password body was asked, and what
# `$keyboard` still held afterwards. The fake `loadkeys` therefore maintains
# a "current console keymap" state file, and the prompt bodies read it.
# ===========================================================================

echo "--- §5.20a the console keymap: pin, truth table, and the ORDER --------"

# A fake `loadkeys`: logs every layout it was asked for, and -- only on
# success -- updates the state file standing in for the console's keymap.
mkdir -p "$work/bin-fakekeys"
cat >"$work/bin-fakekeys/loadkeys" <<'FAKEKEYS'
#!/usr/bin/env bash
printf '%s\n' "${1:-}" >>"${FAKE_LOADKEYS_LOG:-/dev/null}"
if [[ -n ${FAKE_LOADKEYS_FAIL:-} ]]; then
  printf 'loadkeys: unable to open file %s\n' "${1:-}" >&2
  exit "$FAKE_LOADKEYS_FAIL"
fi
[[ -n ${FAKE_CONSOLE_KEYMAP_FILE:-} ]] && printf '%s\n' "${1:-}" >"$FAKE_CONSOLE_KEYMAP_FILE"
exit 0
FAKEKEYS
chmod +x "$work/bin-fakekeys/loadkeys"
KEYS_PATH="$work/bin-fakekeys:$PATH"

# --- the pin primitive -----------------------------------------------------

: >"$work/lk.log"
out=$(DECK_FORM_TTY_OVERRIDE=/dev/pts/9 FAKE_LOADKEYS_LOG="$work/lk.log" \
      PATH="$KEYS_PATH" deck_form_pin_console_keymap 2>&1) ||
  fail "pin must return 0 off a virtual console -- there is nothing to fix there" "$out"
[[ ! -s "$work/lk.log" ]] ||
  fail "pin must NOT run loadkeys when tty is not a virtual console" "$(cat "$work/lk.log")"
LC_ALL=C grep -qF "not on a Linux virtual console" <<<"$out" ||
  fail "pin must say why it did nothing, not go silent" "got: $out"
pass "deck_form_pin_console_keymap is a stated no-op off a virtual console (upstream's own loadkeys guard)"

: >"$work/lk.log"
DECK_FORM_TTY_OVERRIDE=/dev/tty1 FAKE_LOADKEYS_LOG="$work/lk.log" \
  PATH="$KEYS_PATH" deck_form_pin_console_keymap ||
  fail "pin must succeed on a virtual console with a working loadkeys"
[[ $(cat "$work/lk.log") == "$DECK_CONSOLE_KEYMAP" ]] ||
  fail "pin must load exactly DECK_CONSOLE_KEYMAP" "got: $(cat "$work/lk.log")"
pass "deck_form_pin_console_keymap loads DECK_CONSOLE_KEYMAP ('$DECK_CONSOLE_KEYMAP') on a virtual console"

out=$(DECK_FORM_TTY_OVERRIDE=/dev/tty1 FAKE_LOADKEYS_FAIL=3 \
      PATH="$KEYS_PATH" deck_form_pin_console_keymap 2>&1) &&
  fail "pin must return NONZERO when loadkeys fails -- the console is then typing something nobody verified"
LC_ALL=C grep -qF "ACCOUNT PASSWORD" <<<"$out" ||
  fail "a failed pin must name the consequence (the masked password), not just log an errno" "got: $out"
# Upstream discards this with `2>/dev/null`. Keeping it is the CLAUDE.md rule.
LC_ALL=C grep -qF "unable to open file" <<<"$out" ||
  fail "a failed pin must surface loadkeys' OWN message -- upstream's 2>/dev/null discard must not come back" "got: $out"
pass "a failed pin returns nonzero, names the masked-password consequence, and forwards loadkeys' own stderr"

# --- the cross-file constant: 'us' here is not a coincidence ---------------
#
# DECK_CONSOLE_KEYMAP means "the layout the OSK draws". src/deck-session.sh
# pins OUR Wayland device to that same layout with OSK_KB_LAYOUT (e8c3698).
# If one is ever changed alone, the console and the desktop disagree about
# what the same keycode means, which is the whole §5.20/§5.20a defect again.
osk_layout=$(sed -n 's/^readonly OSK_KB_LAYOUT=\(.*\)$/\1/p' "$REPO_ROOT/src/deck-session.sh")
[[ -n $osk_layout ]] ||
  fail "could not find 'readonly OSK_KB_LAYOUT=' in src/deck-session.sh -- this cross-check is broken, not the code"
[[ $osk_layout == "$DECK_CONSOLE_KEYMAP" ]] ||
  fail "DECK_CONSOLE_KEYMAP ('$DECK_CONSOLE_KEYMAP') and deck-session.sh's OSK_KB_LAYOUT ('$osk_layout') disagree -- the console and the desktop would type different characters for the same OSK key"
pass "DECK_CONSOLE_KEYMAP agrees with src/deck-session.sh's OSK_KB_LAYOUT ('$osk_layout') -- one layout, both layers"

# --- the status truth table ------------------------------------------------

[[ $(deck_form_keyboard_status_action 0 10 11 true) == accept ]] ||
  fail "status 0 must be 'accept'"
[[ $(deck_form_keyboard_status_action 10 10 11 true) == reask ]] ||
  fail "OMARCHY_FORM_BACK (Esc) must re-ask -- nothing precedes the first screen (configurator:210)"
[[ $(deck_form_keyboard_status_action 11 10 11 true) == defer-offer ]] ||
  fail "OMARCHY_FORM_SIGNAL with defer allowed must offer deferred provisioning"
[[ $(deck_form_keyboard_status_action 11 10 11 false) == abort ]] ||
  fail "OMARCHY_FORM_SIGNAL with defer NOT allowed must abort -- configurator:193's own reason (a re-edit must not flip a user install into deferred provisioning)"
[[ $(deck_form_keyboard_status_action 7 10 11 true) == abort ]] ||
  fail "an unrecognised nonzero status must abort, not be guessed at"
pass "deck_form_keyboard_status_action reproduces upstream's four outcomes"

out=$(deck_form_keyboard_status_action 7 "" "" true 2>&1)
[[ ${out##*$'\n'} == abort ]] ||
  fail "with OMARCHY_FORM_* unset the answer must be 'abort', never a guess" "got: $out"
LC_ALL=C grep -qF "setup-form.sh was not sourced" <<<"$out" ||
  fail "unset OMARCHY_FORM_* must be reported, not silently defaulted" "got: $out"
out=$(deck_form_keyboard_status_action 7 abc 11 true 2>&1)
[[ ${out##*$'\n'} == abort ]] ||
  fail "a non-numeric OMARCHY_FORM_BACK must abort rather than reach an arithmetic evaluation" "got: $out"
out=$(deck_form_keyboard_status_action "" 10 11 true 2>&1)
[[ ${out##*$'\n'} == abort ]] ||
  fail "a non-numeric STATUS must abort rather than reach an arithmetic evaluation" "got: $out"
LC_ALL=C grep -qF "non-numeric status" <<<"$out" ||
  fail "a non-numeric status must be reported" "got: $out"
pass "unset/non-numeric OMARCHY_FORM_* and statuses abort LOUDLY instead of being guessed at"

echo "--- §5.20a keyboard_form: the preference is kept, the console is not ---"

# The picker, queue-driven: one "<layout>:<status>" line consumed per call,
# so the re-ask loop can be driven without a real gum.
: >"$work/kb.queue"
omarchy_prompt_keyboard() {
  local line
  line=$(head -1 "$FAKE_KB_QUEUE" 2>/dev/null)
  [[ -z $line ]] && return 99
  tail -n +2 "$FAKE_KB_QUEUE" >"$FAKE_KB_QUEUE.tmp" && mv "$FAKE_KB_QUEUE.tmp" "$FAKE_KB_QUEUE"
  keyboard=${line%%:*}
  return "${line##*:}"
}
confirm_prepare_for_another_owner() { return "${FAKE_DEFER_CONFIRM_RC:-0}"; }
OMARCHY_FORM_BACK=10
OMARCHY_FORM_SIGNAL=11

# 🔴 THE CENTRAL ASSERTION OF THIS SECTION.
printf 'latam:0\n' >"$work/kb.queue"
: >"$work/lk.log"
printf 'latam\n' >"$work/console-keymap"   # the console starts on the user's pick
keyboard=
FAKE_KB_QUEUE="$work/kb.queue" DECK_FORM_TTY_OVERRIDE=/dev/tty1 \
FAKE_LOADKEYS_LOG="$work/lk.log" FAKE_CONSOLE_KEYMAP_FILE="$work/console-keymap" \
PATH="$KEYS_PATH" keyboard_form true ||
  fail "keyboard_form must return 0 when the picker succeeds"
[[ $keyboard == latam ]] ||
  fail "the user's layout PREFERENCE must survive keyboard_form untouched -- it is what reaches archinstall's kb_layout" "keyboard='$keyboard'"
if LC_ALL=C grep -qx latam "$work/lk.log"; then
  fail "keyboard_form must NEVER loadkeys the user's chosen layout -- that is the §5.20a defect itself" "$(cat "$work/lk.log")"
fi
[[ $(cat "$work/console-keymap") == "$DECK_CONSOLE_KEYMAP" ]] ||
  fail "after keyboard_form the console must be on the layout the OSK draws" "got: $(cat "$work/console-keymap")"
pass "keyboard_form keeps \$keyboard='latam' for archinstall AND leaves the live console on '$DECK_CONSOLE_KEYMAP'"

# 🔴 THE ORDERING PROPERTY, END TO END: replay configurator's own sequence
# (keyboard_form:989 -> user_form's omarchy_prompt_password:253) and record
# the keymap that was in force AT THE MOMENT each password field was asked.
# A `loadkeys "$keyboard"` restored to keyboard_form's tail turns this red;
# a test that only checked "keyboard_form is defined" would not.
#
# The real prompt bodies are swapped for recording ones and swapped BACK via
# `declare -f`, rather than the obvious `( ... )` subshell: a subshell that
# exports PATH makes shellcheck (correctly) flag every later `PATH=... cmd`
# in this file as possibly-lost, and CI fails on info-level findings.
printf 'latam:0\n' >"$work/kb.queue"
printf 'latam\n' >"$work/console-keymap"
: >"$work/typed-under.log"
orig_password_body=$(declare -f deck_form_password_body)
orig_confirm_body=$(declare -f deck_form_confirm_body)
# shellcheck disable=SC2329  # invoked indirectly, by name, from deck_form_text_prompt
deck_form_password_body() { cat "$FAKE_CONSOLE_KEYMAP_FILE" >>"$work/typed-under.log"; printf 'hunter22\n'; }
# shellcheck disable=SC2329  # same: deck_form_text_prompt "$prompt_fn"
deck_form_confirm_body()  { cat "$FAKE_CONSOLE_KEYMAP_FILE" >>"$work/typed-under.log"; printf 'hunter22\n'; }
FAKE_KB_QUEUE="$work/kb.queue" FAKE_CONSOLE_KEYMAP_FILE="$work/console-keymap" \
DECK_FORM_TTY_OVERRIDE=/dev/tty1 PATH="$KEYS_PATH" \
  keyboard_form true 2>/dev/null ||
  fail "the replayed configurator sequence must reach the password step (keyboard_form failed)"
FAKE_CONSOLE_KEYMAP_FILE="$work/console-keymap" \
DECK_FORM_TTY_OVERRIDE=/dev/tty1 PATH="$KEYS_PATH" \
DECK_TEXT_PROMPT_LIZARD_SYSFS="$work/no-such-knob" \
DECK_TEXT_PROMPT_MAPPER_BIN="$work/no-such-mapper" \
  omarchy_prompt_password 2>/dev/null ||
  fail "the replayed configurator sequence (keyboard_form -> omarchy_prompt_password) must complete"
eval "$orig_password_body"
eval "$orig_confirm_body"
mapfile -t typed_under <"$work/typed-under.log"
[[ ${#typed_under[@]} -eq 2 ]] ||
  fail "both password fields must have been asked -- this assertion is worthless if the body never ran" "${typed_under[*]:-none}"
for seen in "${typed_under[@]}"; do
  [[ $seen == "$DECK_CONSOLE_KEYMAP" ]] ||
    fail "🔴 the account password was typed under console keymap '$seen', not the layout the OSK draws ('$DECK_CONSOLE_KEYMAP') -- §5.20a" "$(cat "$work/typed-under.log")"
done
pass "🔴 the account password is typed under the keymap the OSK draws, with \$keyboard still on the user's non-us pick"

# The same property for the bounded text-entry primitive itself, so it holds
# for EVERY text screen regardless of what ran before it (upstream re-enters
# keyboard_form from user_step at :273 and :292 -- there is no ordering that
# survives that).
printf 'latam\n' >"$work/console-keymap"
: >"$work/prompt-under.log"
deck_form_test_recording_body() { cat "$FAKE_CONSOLE_KEYMAP_FILE" >>"$work/prompt-under.log"; printf 'typed\n'; }
out=$(FAKE_CONSOLE_KEYMAP_FILE="$work/console-keymap" DECK_FORM_TTY_OVERRIDE=/dev/tty1 \
      PATH="$KEYS_PATH" DECK_TEXT_PROMPT_LIZARD_SYSFS="$work/no-such-knob" \
      DECK_TEXT_PROMPT_MAPPER_BIN="$work/no-such-mapper" \
      deck_form_text_prompt deck_form_test_recording_body 2>/dev/null)
[[ $out == typed ]] || fail "the recording body must have run" "got: $out"
[[ $(cat "$work/prompt-under.log") == "$DECK_CONSOLE_KEYMAP" ]] ||
  fail "deck_form_text_prompt must pin the console keymap BEFORE running its body -- otherwise every text screen inherits whatever loadkeys last set" "got: $(cat "$work/prompt-under.log")"
pass "deck_form_text_prompt pins the console keymap before the body runs (ordering-independent, not ordering-dependent)"

# A failed pin must degrade, not block: a prompt with a doubtful keymap still
# beats no prompt, and it must say so.
printf 'latam\n' >"$work/console-keymap"
: >"$work/prompt-under.log"
out=$(FAKE_CONSOLE_KEYMAP_FILE="$work/console-keymap" FAKE_LOADKEYS_FAIL=1 \
      DECK_FORM_TTY_OVERRIDE=/dev/tty1 PATH="$KEYS_PATH" \
      DECK_TEXT_PROMPT_LIZARD_SYSFS="$work/no-such-knob" \
      DECK_TEXT_PROMPT_MAPPER_BIN="$work/no-such-mapper" \
      deck_form_text_prompt deck_form_test_recording_body 2>"$work/prompt.err")
[[ $out == typed ]] ||
  fail "a failed pin must NOT block the prompt -- §2.3's degrade-loudly rule" "got: $out"
LC_ALL=C grep -qF "UNVERIFIED console keymap" "$work/prompt.err" ||
  fail "a failed pin inside a text prompt must be stated, not swallowed" "$(cat "$work/prompt.err")"
pass "a failed pin degrades the prompt loudly (body still runs, the doubt is stated)"

# --- the rest of upstream's loop, kept rather than quietly dropped ---------

printf 'us:10\nlatam:0\n' >"$work/kb.queue"
: >"$work/lk.log"
keyboard=
FAKE_KB_QUEUE="$work/kb.queue" DECK_FORM_TTY_OVERRIDE=/dev/tty1 \
FAKE_LOADKEYS_LOG="$work/lk.log" PATH="$KEYS_PATH" keyboard_form true ||
  fail "Esc (OMARCHY_FORM_BACK) must re-ask the picker, then accept the second answer"
[[ $keyboard == latam ]] ||
  fail "the SECOND pick must be the one that survives the re-ask loop" "keyboard='$keyboard'"
[[ ! -s "$work/kb.queue" ]] ||
  fail "the picker must have been called twice (the queue should be drained)" "$(cat "$work/kb.queue")"
pass "keyboard_form re-asks on Esc and keeps the answer from the successful pass"

printf 'us:11\n' >"$work/kb.queue"
: >"$work/lk.log"
defer_provisioning=false
FAKE_KB_QUEUE="$work/kb.queue" FAKE_DEFER_CONFIRM_RC=0 DECK_FORM_TTY_OVERRIDE=/dev/tty1 \
FAKE_LOADKEYS_LOG="$work/lk.log" PATH="$KEYS_PATH" keyboard_form true ||
  fail "the deferred-provisioning path must return 0"
[[ $defer_provisioning == true ]] ||
  fail "Ctrl+C + confirm must set defer_provisioning=true (configurator:991 reads it)"
[[ ! -s "$work/lk.log" ]] ||
  fail "the defer path must not touch the console keymap -- upstream returns before its own loadkeys, and nothing on that path types anything" "$(cat "$work/lk.log")"
pass "the deferred-provisioning path is preserved (sets defer_provisioning, pins nothing) -- parity with upstream, not a silent feature removal"

printf 'us:11\nus:0\n' >"$work/kb.queue"
defer_provisioning=false
FAKE_KB_QUEUE="$work/kb.queue" FAKE_DEFER_CONFIRM_RC=1 DECK_FORM_TTY_OVERRIDE=/dev/tty1 \
FAKE_LOADKEYS_LOG="$work/lk.log" PATH="$KEYS_PATH" keyboard_form true ||
  fail "declining the defer offer must return to the picker, not abort"
[[ $defer_provisioning == false ]] ||
  fail "a DECLINED defer offer must leave defer_provisioning false (configurator:217)"
pass "declining the deferred-provisioning offer returns to the picker"

printf 'us:11\n' >"$work/kb.queue"
out=$(FAKE_KB_QUEUE="$work/kb.queue" DECK_FORM_TTY_OVERRIDE=/dev/tty1 \
      PATH="$KEYS_PATH" keyboard_form false 2>&1) &&
  fail "Ctrl+C on a RE-EDIT (allow-defer false) must not flip the install into deferred provisioning"
LC_ALL=C grep -qF "ABORT" <<<"$out" ||
  fail "an unusable status must reach upstream's abort, not fall through" "got: $out"
printf 'us:127\n' >"$work/kb.queue"
out=$(FAKE_KB_QUEUE="$work/kb.queue" DECK_FORM_TTY_OVERRIDE=/dev/tty1 \
      PATH="$KEYS_PATH" keyboard_form true 2>&1) &&
  fail "a missing omarchy_prompt_keyboard (status 127) must abort, not continue with an unknown layout"
LC_ALL=C grep -qF "status 127" <<<"$out" ||
  fail "the abort must name the status it saw" "got: $out"
pass "unusable picker statuses abort loudly instead of installing with an unknown layout"

echo "--- §5.20a the PREMISE, re-derived from upstream's own source ---------"

# Every assertion above is only worth something if upstream still does the
# thing being fixed. These four pin that premise, so an upstream rebase that
# moves the defect says "re-derive" instead of leaving a green suite behind.
CONFIGURATOR="$REPO_ROOT/iso/upstream/configs/airootfs/root/configurator"
[[ -r $CONFIGURATOR ]] ||
  fail "iso/upstream is not checked out, so §5.20a's premise was NOT verified. Run: git submodule update --init iso/upstream"

kf_start=$(LC_ALL=C grep -n '^keyboard_form() {' "$CONFIGURATOR" | head -1 | cut -d: -f1)
[[ -n $kf_start ]] || fail "upstream no longer defines keyboard_form -- re-derive §5.20a"
kf_end=$(awk -v s="$kf_start" 'NR>s && /^}/ { print NR; exit }' "$CONFIGURATOR")
# shellcheck disable=SC2016  # the literal upstream text is the point -- it must NOT expand
LC_ALL=C sed -n "${kf_start},${kf_end}p" "$CONFIGURATOR" | LC_ALL=C grep -qF 'loadkeys "$keyboard"' ||
  fail "upstream's keyboard_form no longer runs loadkeys \"\$keyboard\" -- the defect this override exists for may be gone or may have MOVED. Re-derive before trusting anything above."
pass "premise: upstream's keyboard_form really does loadkeys the user's chosen layout (configurator:${kf_start}-${kf_end})"

# shellcheck disable=SC2016  # the literal upstream text is the point -- it must NOT expand
LC_ALL=C grep -qF '"kb_layout": "$keyboard"' "$CONFIGURATOR" ||
  fail "upstream no longer writes \$keyboard into the archinstall JSON as kb_layout -- the reason this override PRESERVES the preference no longer holds; re-derive"
pass "premise: \$keyboard is what reaches archinstall's kb_layout, so keeping it is what keeps the preference"

kf_call=$(LC_ALL=C grep -n '^keyboard_form true$' "$CONFIGURATOR" | head -1 | cut -d: -f1)
pw_call=$(LC_ALL=C grep -n 'omarchy_prompt_password' "$CONFIGURATOR" | head -1 | cut -d: -f1)
[[ -n $kf_call && -n $pw_call ]] ||
  fail "could not locate upstream's keyboard_form/omarchy_prompt_password call sites -- this premise check is broken"
[[ $kf_start -lt $pw_call ]] ||
  fail "upstream's password prompt no longer follows the keyboard step -- re-derive §5.20a's ordering claim"
pass "premise: upstream prompts for the password (configurator:${pw_call}) after the keyboard step, and re-enters it from user_step"

# And the fix itself, at the source level: this file must never load the
# user's chosen layout, under any spelling.
# Comment lines are stripped first -- the S2b block QUOTES upstream's
# offending line verbatim, and a scanner that cannot tell a quotation from
# code would either fire on the documentation or be weakened until it fired
# on nothing.
strip_comments() { LC_ALL=C grep -vE '^[[:space:]]*#' "$1"; }
if strip_comments "$DECK_FORM_SH" | LC_ALL=C grep -qE 'loadkeys[^#]*\$\{?keyboard\b'; then
  fail "deck-form.sh loads \$keyboard into the console keymap -- §5.20a is back"
fi
# Positive control: an absence assertion is worthless if the pattern could
# never match anything. Upstream's own file is the known positive.
strip_comments "$CONFIGURATOR" | LC_ALL=C grep -qE 'loadkeys[^#]*\$\{?keyboard\b' ||
  fail "the loadkeys scanner cannot see upstream's own loadkeys \"\$keyboard\" -- it is broken, not clean"
# The picker itself is deliberately NOT overridden (see the S2b block's
# 'WHAT IS NOT DONE HERE'). Asserted so a future session that adds one does
# it on purpose, having read why it was left alone.
if LC_ALL=C grep -qE '^omarchy_prompt_keyboard\(\)' "$DECK_FORM_SH"; then
  fail "deck-form.sh now overrides omarchy_prompt_keyboard -- upstream's picker was left alone deliberately (its body is not vendored here, so a replacement would be designed blind). Update the S2b block's reasoning if that changed."
fi
pass "deck-form.sh never loadkeys \$keyboard, and leaves upstream's picker in place"

# ===========================================================================
# S3: Account
# ===========================================================================

echo "--- S3 username/password predicates -------------------------------------"

deck_form_username_valid deck || fail "'deck' must be a valid username"
deck_form_username_valid a || fail "single-letter username must be valid"
deck_form_username_valid _svc || fail "leading underscore must be valid"
deck_form_username_valid 'container$' || fail "trailing \$ must be valid (the pattern's own \$? clause)"

if deck_form_username_valid Deck; then
  fail "an uppercase username must be REJECTED"
fi
if deck_form_username_valid "9deck"; then
  fail "a username starting with a digit must be REJECTED"
fi
if deck_form_username_valid "de ck"; then
  fail "a username containing a space must be REJECTED"
fi
if deck_form_username_valid ""; then
  fail "an empty username must be REJECTED"
fi
pass "deck_form_username_valid accepts upstream's own pattern and rejects uppercase/leading-digit/space/empty"

deck_form_password_nonblank "hunter2" || fail "a nonblank password must pass"
if deck_form_password_nonblank ""; then fail "a blank password must be rejected"; fi
pass "deck_form_password_nonblank"

deck_form_passwords_match "hunter2" "hunter2" || fail "identical passwords must match"
if deck_form_passwords_match "hunter2" "hunter3"; then fail "different passwords must NOT match"; fi
pass "deck_form_passwords_match"

echo "--- S3 reserved-username list: sourced, never copied ---------------------"

cat >"$work/setup-form-fixture.sh" <<'EOF'
RESERVED_USERNAMES=(root bin daemon deck-reserved-example)
EOF
out=$(DECK_SETUP_FORM_SH_OVERRIDE="$work/setup-form-fixture.sh" deck_form_load_reserved_usernames 2>&1)
rc=$?
[[ $rc -eq 0 ]] || fail "load_reserved_usernames must succeed against a real fixture" "$out"
DECK_SETUP_FORM_SH_OVERRIDE="$work/setup-form-fixture.sh" deck_form_load_reserved_usernames
deck_form_username_reserved root ||
  fail "a name present in the sourced fixture must be reported reserved"
if deck_form_username_reserved definitely-not-reserved; then
  fail "a name absent from the fixture must NOT be reported reserved"
fi
pass "load_reserved_usernames sources a real fixture and reserved-name membership works"

out=$(DECK_SETUP_FORM_SH_OVERRIDE="$work/does-not-exist.sh" deck_form_load_reserved_usernames 2>&1) && \
  fail "load_reserved_usernames must return nonzero when the file is missing"
LC_ALL=C grep -qF "UNAVAILABLE" <<<"$out" ||
  fail "load_reserved_usernames must say the list is unavailable, not go silent" "got: $out"
DECK_SETUP_FORM_SH_OVERRIDE="$work/does-not-exist.sh" deck_form_load_reserved_usernames 2>/dev/null || true
if deck_form_username_reserved root; then
  fail "with no list loaded, nothing should be reported reserved (fail toward 'pattern check only', not toward false positives)"
fi
pass "load_reserved_usernames degrades loudly (nonzero, says UNAVAILABLE) when the file is missing, and the reserved-check fails open"

cat >"$work/setup-form-no-array.sh" <<'EOF'
SOME_OTHER_CONSTANT=1
EOF
out=$(DECK_SETUP_FORM_SH_OVERRIDE="$work/setup-form-no-array.sh" deck_form_load_reserved_usernames 2>&1) && \
  fail "load_reserved_usernames must fail when the sourced file defines no RESERVED_USERNAMES array"
LC_ALL=C grep -qF "defines no" <<<"$out" ||
  fail "load_reserved_usernames must explain WHY it failed when the array is missing" "got: $out"
pass "load_reserved_usernames fails loudly (not silently-empty) when the vendored file exists but has the wrong shape"

echo "--- S3 hostname/identity constants and overrides --------------------------"

[[ $DECK_HOSTNAME == steamdeck ]] || fail "DECK_HOSTNAME must be the constant 'steamdeck'"
pass "DECK_HOSTNAME is the constant 'steamdeck'"

# ⚠️ THE NAMES ARE THE WHOLE MECHANISM, so they are asserted against what
# upstream actually calls, not against what the spec's prose looked like.
# `configurator` lines 258-259 in the pinned iso/upstream tree call
# `omarchy_prompt_identity` and `omarchy_prompt_hostname`; T4-screen-spec.md
# §1.1's `_identity` / `_hostname` is that list with the prefix ELIDED after
# its first entry, not a second naming convention. A definition under a name
# upstream never calls is a screen that silently never appears -- the exact
# failure mode T4 §6.4 exists to catch -- so the wrong names must NOT be
# defined, and that is asserted here too.
for fn in omarchy_prompt_identity omarchy_prompt_hostname; do
  declare -f "$fn" >/dev/null || fail "$fn must be defined -- it is the name upstream's configurator actually calls"
done
pass "the identity/hostname overrides use the names upstream's configurator calls"

for fn in _identity _hostname; do
  declare -f "$fn" >/dev/null &&
    fail "$fn must NOT be defined -- upstream never calls it, so it overrides nothing and only looks like it works"
done
pass "the elided-prefix names are NOT defined (they would override nothing)"

out=$(omarchy_prompt_hostname)
[[ $out == steamdeck ]] || fail "omarchy_prompt_hostname must output the constant hostname" "got: $out"
pass "omarchy_prompt_hostname outputs 'steamdeck' and prompts for nothing (no read, no blocking)"

echo "--- the OVERRIDE-NAME contract, checked against upstream's own source ---"

# 🔴 THE MOST IMPORTANT ASSERTION IN THIS FILE. The wrap decision (§1) works by
# defining a function with the SAME NAME as an upstream one, after configurator
# has sourced setup-form.sh. A name upstream never calls is therefore not a
# broken screen -- it is NO screen, silently, while every unit test on that
# screen's pure helpers stays green.
#
# This file shipped that defect FOUR times before this check existed:
#   _identity, _hostname   -> really omarchy_prompt_identity / _hostname
#   _username, _password   -> really omarchy_prompt_username / _password
# all four from reading §1.1's `omarchy_prompt_keyboard, _username, _password,
# _identity, ...` as four names rather than one name and three elisions. And:
#   failure_menu           -> lives in omarchy-install-dashboard, a SEPARATE
#                             PROCESS; renaming cannot fix it (see T4a)
#
# So every function this file defines that is NOT prefixed `deck_form_` is
# claimed to be an upstream override, and must appear in configurator. The
# allowlist below is for names that arrive through OUR OWN patch instead.
CONFIGURATOR="$REPO_ROOT/iso/upstream/configs/airootfs/root/configurator"
DASHBOARD="$REPO_ROOT/iso/upstream/configs/airootfs/usr/local/bin/omarchy-install-dashboard"
# Never a silent skip -- this assertion is the only thing standing between an
# elided name and a screen that never appears.
[[ -r $CONFIGURATOR ]] ||
  fail "iso/upstream is not checked out, so the override-name contract was NOT verified. Run: git submodule update --init iso/upstream"
# deck_final_summary is called by T4's patch P1 hunk 2, not by stock upstream.
OVERRIDE_ALLOWLIST=" deck_final_summary "

overrides=$(grep -oE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' "$DECK_FORM_SH" |
              tr -d '()' | grep -v '^deck_form_' | sort -u)
[[ -n $overrides ]] ||
  fail "found NO override functions in deck-form.sh -- this scanner is broken, not the file"

while read -r fn; do
  [[ -z $fn ]] && continue
  case $OVERRIDE_ALLOWLIST in *" $fn "*) continue ;; esac
  if LC_ALL=C grep -qE "(^|[^a-zA-Z0-9_])${fn}([^a-zA-Z0-9_]|\$)" "$CONFIGURATOR"; then
    continue
  fi
  if [[ -r $DASHBOARD ]] &&
     LC_ALL=C grep -qE "(^|[^a-zA-Z0-9_])${fn}([^a-zA-Z0-9_]|\$)" "$DASHBOARD"; then
    fail "deck-form.sh defines '${fn}', which lives in omarchy-install-dashboard -- a SEPARATE PROCESS this file is never sourced into. It would never run. See docs/tasks/T4a-dashboard-screens.md"
  fi
  fail "deck-form.sh defines '${fn}', a name upstream's configurator never calls. That is not a broken screen, it is NO screen, and it fails SILENTLY"
done <<<"$overrides"
pass "every override deck-form.sh defines is a name upstream actually calls"

# Negative control: a scanner that stopped matching would report a clean tree.
LC_ALL=C grep -qE '(^|[^a-zA-Z0-9_])omarchy_prompt_username([^a-zA-Z0-9_]|$)' "$CONFIGURATOR" ||
  fail "the override scanner cannot see a name that is definitely there -- it is broken"
pass "override scanner positive control: it really does find a known-live name"

echo "--- the variable-name contract, checked against UPSTREAM'S OWN SOURCE ---"

# 🔴 WHY THIS SECTION EXISTS. An override's return value is not its output --
# what it actually delivers is the GLOBAL it sets, which `configurator` reads
# later. Those names were INFERRED for one session and two of four were wrong:
# `user_password` for `password`, `hostname_value` for `hostname`.
#
# `configurator` has no `set -u`, so nothing would have failed. `openssl
# passwd -6` would have hashed the EMPTY STRING into a perfectly valid hash,
# the JSON would have carried `"hostname": ""`, and the install would have
# finished GREEN with a passwordless account nobody discovers until first
# login. On the encrypted path the same empty string reaches
# `cryptsetup luksFormat`.
#
# So the names are asserted against upstream's own file rather than against a
# list written here -- a list here would just be the same inference again.
CONFIGURATOR="$REPO_ROOT/iso/upstream/configs/airootfs/root/configurator"
if [[ -r $CONFIGURATOR ]]; then
  for v in password hostname full_name email_address; do
    LC_ALL=C grep -qE "\\\$\{?${v}\b" "$CONFIGURATOR" ||
      fail "upstream's configurator never reads \$${v} -- the name deck-form.sh sets is wrong, and would fail SILENTLY"
  done
  pass "every global the S3 overrides set is one upstream's configurator actually reads"

  # The specific wrong names, pinned as wrong. If a future edit reintroduces
  # one, this says so instead of leaving it to an installed device.
  for bad in user_password hostname_value; do
    if LC_ALL=C grep -qE "\\\$\{?${bad}\b" "$CONFIGURATOR"; then
      fail "upstream DOES read \$${bad} -- this suite's premise is wrong, re-derive the contract"
    fi
    LC_ALL=C grep -qE "^\s*${bad}=" "$DECK_FORM_SH" &&
      fail "deck-form.sh sets \$${bad}, which upstream never reads -- the silent-empty bug is back"
  done
  pass "the two names that were silently wrong are pinned as wrong"
else
  # Never a silent skip: the submodule not being checked out must be visible,
  # because this assertion is the only thing standing between an inferred
  # name and a passwordless installed device.
  printf 'not ok - iso/upstream is not checked out, so the variable-name contract was NOT verified\n'
  printf 'run: git submodule update --init iso/upstream\n' >&2
  exit 1
fi

# Functional, not just textual: call the overrides and read the globals back.
( omarchy_prompt_hostname >/dev/null 2>&1; [[ ${hostname:-} == steamdeck ]] ) ||
  fail "omarchy_prompt_hostname must set \$hostname (the name configurator reads), not some other name"
pass "omarchy_prompt_hostname really sets \$hostname"

( omarchy_prompt_identity >/dev/null 2>&1
  [[ ${full_name+set} == set && ${email_address+set} == set ]] ) ||
  fail "omarchy_prompt_identity must set \$full_name and \$email_address"
pass "omarchy_prompt_identity really sets \$full_name and \$email_address"

# ===========================================================================
# S1: Wi-Fi (SSID list builder only)
# ===========================================================================

echo "--- S1 SSID sanitisation --------------------------------------------------"

got=$(deck_form_sanitize_ssid 'Evil|Network')
[[ $got == 'Evil?Network' ]] || fail "sanitize_ssid must replace a literal '|'" "got: $got"
pass "sanitize_ssid neutralises an embedded '|'"

got=$(deck_form_sanitize_ssid "My Home Network")
[[ $got == "My Home Network" ]] || fail "sanitize_ssid must NOT touch an ordinary space" "got: $got"
pass "sanitize_ssid preserves ordinary spaces (a real, common SSID shape)"

got=$(deck_form_sanitize_ssid $'Evil\x1b[31mRed')
[[ $got != *$'\x1b'* ]] || fail "sanitize_ssid must strip a raw ESC byte (ANSI injection)" "got bytes: $(printf '%s' "$got" | od -An -tx1)"
pass "sanitize_ssid strips a raw ANSI escape byte"

got=$(deck_form_sanitize_ssid $'inject\tTAB')
[[ $got != *$'\t'* ]] || fail "sanitize_ssid must strip a literal TAB (this file's own internal field separator)"
pass "sanitize_ssid strips an embedded TAB, protecting the internal TSV encoding"

echo "--- S1 iwctl parsing (INFERRED format -- see deck-form.sh's own note) ----"

# A hand-built fixture matching this file's own documented column-layout
# assumption: a header row naming Network name / Security / Signal, a
# dashed rule, then data rows. ANSI colour on the signal column (a real
# iwd behaviour) and a leading '>' marking the connected network are both
# included, because a parser that only works on the UNCOLOURED case is not
# proven against what iwctl actually prints.
esc=$'\x1b'
cat >"$work/iwctl.raw" <<EOF
                                        Available networks
---------------------------------------------------------------------------------------------------
    Network name                    Security             Signal
---------------------------------------------------------------------------------------------------
    My Home Network                 psk                  ${esc}[32m****${esc}[0m
    OpenGuest                       open                 ${esc}[33m**  ${esc}[0m
>   ConnectedNet                    psk                  ${esc}[32m****${esc}[0m
    Evil|Bar                        open                 ${esc}[31m*   ${esc}[0m
EOF

deck_form_parse_iwctl_networks "$work/iwctl.raw" >"$work/parsed.tsv" ||
  fail "parse_iwctl_networks must succeed on a well-formed fixture"

nrows=$(wc -l <"$work/parsed.tsv")
[[ $nrows -eq 4 ]] || fail "parse_iwctl_networks must find exactly 4 networks" "got $nrows lines: $(cat "$work/parsed.tsv")"
pass "parse_iwctl_networks finds all 4 rows, including the connected one and the hostile-SSID one"

LC_ALL=C grep -qF $'My Home Network\tpsk' "$work/parsed.tsv" ||
  fail "parse_iwctl_networks must preserve a space-containing SSID intact (offset-based, not whitespace-split)" "$(cat "$work/parsed.tsv")"
pass "parse_iwctl_networks keeps a space-containing SSID intact"

LC_ALL=C grep -qF $'OpenGuest\topen' "$work/parsed.tsv" ||
  fail "parse_iwctl_networks must classify the open network correctly" "$(cat "$work/parsed.tsv")"
pass "parse_iwctl_networks correctly reads the 'open' security column"

LC_ALL=C grep -qF $'ConnectedNet\tpsk' "$work/parsed.tsv" ||
  fail "parse_iwctl_networks must strip the leading '>' connected-marker from the SSID" "$(cat "$work/parsed.tsv")"
pass "parse_iwctl_networks strips the connected-network '>' marker"

# not sanitised yet at THIS layer -- sanitisation is build_network_rows's
# job, proven next. This layer must still preserve the raw bytes faithfully
# so the sanitiser downstream has something real to work on.
LC_ALL=C grep -qF 'Evil|Bar' "$work/parsed.tsv" ||
  fail "parse_iwctl_networks must pass the RAW ssid through (sanitisation is a separate, later layer)"
pass "parse_iwctl_networks passes raw SSID bytes through unsanitised (that's build_network_rows's job)"

out=$(deck_form_parse_iwctl_networks "$work/iwctl.raw" 2>/dev/null | LC_ALL=C command grep -c $'\x1b' || true)
[[ ${out:-0} -eq 0 ]] || fail "parse_iwctl_networks must strip ANSI colour codes from every field"
pass "parse_iwctl_networks strips ANSI colour codes"

# 🔴 A HOSTILE SSID CAN IMPERSONATE THE HEADER. The parser finds its column
# boundaries by locating the line containing "Network name" -- and an
# attacker may simply NAME THEIR NETWORK "Network name", putting that string
# on a DATA row too. Anchoring on anything but the FIRST occurrence makes
# the parser treat that data row as the header and silently drop every
# network above it, which is a way to disappear the user's real network from
# the list and leave only the attacker's. Found while mutation-testing: this
# is the one input for which first-vs-last is not an equivalent change.
cat >"$work/iwctl-impersonate.raw" <<EOF
                                        Available networks
-------------------------------------------------------------------------
    Network name                    Security             Signal
-------------------------------------------------------------------------
    HomeNet                         psk                  ****
    Network name                    open                 **
    OtherNet                        psk                  *
EOF
deck_form_parse_iwctl_networks "$work/iwctl-impersonate.raw" >"$work/impersonate.tsv" ||
  fail "the parser must survive an SSID that impersonates the header"
[[ $(wc -l <"$work/impersonate.tsv") -eq 3 ]] ||
  fail "an SSID named 'Network name' must not make the parser drop the networks above it" \
       "$(cat "$work/impersonate.tsv")"
LC_ALL=C grep -qF $'HomeNet\tpsk' "$work/impersonate.tsv" ||
  fail "the real network listed above a header-impersonating SSID must still be present"
pass "an SSID that impersonates the 'Network name' header cannot hide the networks above it"

echo "--- S1 network row building -------------------------------------------"

deck_form_build_network_rows "$work/parsed.tsv" >"$work/rows.txt"

LC_ALL=C grep -qF "$DECK_NET_SKIP_ROW" "$work/rows.txt" ||
  fail "build_network_rows must include the Skip row"
LC_ALL=C grep -qF "$DECK_NET_RESCAN_ROW" "$work/rows.txt" ||
  fail "build_network_rows must include the Rescan row"
pass "build_network_rows always includes Skip and Rescan"

LC_ALL=C grep -qF 'Evil?Bar' "$work/rows.txt" ||
  fail "build_network_rows must sanitise the hostile SSID ('|' -> '?') before it reaches the row list"
if LC_ALL=C command grep -qF '|' "$work/rows.txt"; then
  fail "build_network_rows must never let a raw '|' reach the rendered row list"
fi
pass "build_network_rows sanitises the hostile SSID and never leaks a raw '|' into the list"

nrows_out=$(wc -l <"$work/rows.txt")
[[ $nrows_out -eq 6 ]] ||   # 4 networks + Skip + Rescan
  fail "build_network_rows must produce exactly 6 rows (4 networks + Skip + Rescan)" "got $nrows_out: $(cat "$work/rows.txt")"
pass "build_network_rows produces exactly one row per network plus Skip and Rescan (6 total)"

# ⚠️ MUTATION-FOUND GAP, closed: an earlier draft of this suite never
# checked the lock glyph itself -- only that parsing correctly classified
# 'open' vs 'psk' upstream of it. Hardcoding glyph="" in build_network_rows
# (dropping the security distinction entirely) left every earlier assertion
# in this block green. A secured network's row must carry the glyph and an
# open network's row must not, or "security" from get-networks never
# reaches what the user actually sees.
secured_row=$(LC_ALL=C command grep -F "My Home Network" "$work/rows.txt")
open_row=$(LC_ALL=C command grep -F "OpenGuest" "$work/rows.txt")
[[ $secured_row == *$'\360\237\224\222'* ]] ||
  fail "a secured (psk) network's row must carry the lock glyph" "got: $secured_row"
[[ $open_row != *$'\360\237\224\222'* ]] ||
  fail "an open network's row must NOT carry the lock glyph" "got: $open_row"
pass "the lock glyph is present for secured networks and absent for open ones"

echo "--- S1 row -> real network: the sanitisation round-trip trap -------------"

# 🔴 The one that would have shipped a permanently-unjoinable network.
# gum choose hands back the DISPLAYED row, which is the SANITISED SSID.
# Recovering the SSID from that string would try to join "Evil?Bar", a
# network that does not exist, forever. The mapping is positional, and
# these two assertions are what prove it.
idx=$(deck_form_row_index "$work/rows.txt" "$(LC_ALL=C command grep -F 'Evil?Bar' "$work/rows.txt")")
[[ $idx -eq 4 ]] || fail "row_index must find the hostile row at its own position" "got: $idx"
line=$(deck_form_network_at "$work/parsed.tsv" "$idx")
[[ ${line%%$'\t'*} == 'Evil|Bar' ]] ||
  fail "the chosen row must map back to the RAW SSID (with its '|'), not the sanitised display text" "got: $line"
pass "a sanitised row maps back to the raw SSID -- 'Evil?Bar' on screen joins 'Evil|Bar' on the air"

# The glyph must not shift the mapping either: the secured row at position
# 1 carries a multi-byte lock glyph, and index arithmetic that counted
# bytes rather than rows would land somewhere else.
idx=$(deck_form_row_index "$work/rows.txt" "$(LC_ALL=C command grep -F 'My Home Network' "$work/rows.txt")")
line=$(deck_form_network_at "$work/parsed.tsv" "$idx")
[[ ${line%%$'\t'*} == 'My Home Network' ]] ||
  fail "a lock-glyph row must still map back to its own network" "got: $line"
pass "the lock glyph does not shift the row->network mapping"

deck_form_row_index "$work/rows.txt" "A Network Nobody Drew" >/dev/null 2>&1 &&
  fail "row_index must REFUSE a row that was never in the drawn list, not guess"
pass "row_index refuses a row that is not in the list it was given (never guesses a network)"

# 🔴 MUTATION-FOUND GAP, closed. The fixture above has no two rows that
# render the same, so `head -1` and `tail -1` were indistinguishable -- the
# documented "first match wins" rule was asserted by nothing. It matters:
# two SSIDs that sanitise to the same display string are the collision an
# attacker gets for free, and deck_form_build_network_rows keeps iwctl's
# own signal ordering, so "first" means "the stronger signal".
printf 'Real|Net\tpsk\t****\nReal?Net\tpsk\t*\n' >"$work/collide.tsv"
deck_form_build_network_rows "$work/collide.tsv" >"$work/collide.rows"
collided_row=$(head -1 "$work/collide.rows")
collided=$(LC_ALL=C command grep -c -xF -- "$collided_row" "$work/collide.rows")
[[ $collided -eq 2 ]] ||
  fail "this fixture is supposed to produce two rows that render identically -- it does not, so the assertion below proves nothing" \
       "$(cat "$work/collide.rows")"
idx=$(deck_form_row_index "$work/collide.rows" "$collided_row")
[[ $idx -eq 1 ]] ||
  fail "when two rows render identically, the FIRST (strongest-signal) one must win, not the last" "got: $idx"
pass "colliding sanitised rows resolve to the FIRST one, which is iwctl's strongest-signal network"

deck_form_network_at "$work/parsed.tsv" 99 >/dev/null 2>&1 &&
  fail "network_at must fail for an index past the end of the scan"
deck_form_network_at "$work/parsed.tsv" 0 >/dev/null 2>&1 &&
  fail "network_at must reject a zero index (rows are 1-based)"
deck_form_network_at "$work/parsed.tsv" "; rm -rf /" >/dev/null 2>&1 &&
  fail "network_at must reject a non-numeric index rather than interpolate it into sed"
# 🔴 MUTATION-FOUND GAP, closed. The three cases above all survive WITHOUT
# the numeric guard, because a broken `sed -n "<junk>p"` prints nothing and
# the empty-line check catches it -- so they proved the wrong thing. `$` is
# the input that separates them: it is not a positive integer, but
# `sed -n "$p"` is VALID sed for "print the last line", so without the
# guard this returns the last network in the scan for an index that means
# nothing. Silently joining a different network than the one on the row the
# user selected is precisely the class of bug this function exists to stop.
deck_form_network_at "$work/parsed.tsv" '$' >/dev/null 2>&1 &&
  fail "network_at must reject '\$' -- it is not an index, but sed reads it as 'the last line', so the guard is what stops a wrong network being joined"
pass "network_at rejects out-of-range, zero, non-numeric and sed-metacharacter indices"

echo "--- S1 the cancel-fallback and menu decisions (mutation targets) ---------"

# S8's bug, pre-empted: upstream's failure menu made Esc SELECT "Drop to
# shell" via `|| choice=...`. Here an empty choice must REDRAW.
[[ $(deck_form_net_choice_action "") == redraw ]] ||
  fail "an empty (cancelled) choice must REDRAW the network list, never act -- this is S8's Drop-to-shell bug in a new place"
[[ $(deck_form_net_choice_action "$DECK_NET_SKIP_ROW") == skip ]] ||
  fail "the Skip row must map to skip"
[[ $(deck_form_net_choice_action "$DECK_NET_RESCAN_ROW") == rescan ]] ||
  fail "the Rescan row must map to rescan"
[[ $(deck_form_net_choice_action $'\360\237\224\222 My Home Network') == connect ]] ||
  fail "an ordinary network row must map to connect"
pass "network-list choice mapping: cancel redraws (never acts), Skip/Rescan/network map correctly"

[[ $(deck_form_net_failure_action_for "") == redraw ]] ||
  fail "a cancelled post-association failure menu must REDRAW, never act"
[[ $(deck_form_net_failure_action_for "Try again") == retry ]] || fail "'Try again' must map to retry"
[[ $(deck_form_net_failure_action_for "Pick another network") == another ]] || fail "'Pick another network' must map to another"
[[ $(deck_form_net_failure_action_for "$DECK_NET_SKIP_ROW") == skip ]] || fail "the Skip row must map to skip in the failure menu too"
[[ $(deck_form_net_failure_action_for "Drop to shell") == redraw ]] ||
  fail "an unrecognised choice must redraw, never be guessed at"
pass "post-association failure menu mapping: cancel and unrecognised both redraw; retry/another/skip map correctly"

items=$(deck_form_net_failure_items)
[[ $(LC_ALL=C command grep -c . <<<"$items") -eq 3 ]] ||
  fail "the failure menu must offer exactly Retry / Pick another / Skip (§5's DHCP row)" "$items"
LC_ALL=C command grep -qiF "shell" <<<"$items" &&
  fail "the failure menu must never offer a shell -- there is no keyboard"
pass "the failure menu offers exactly Retry / Pick another / Skip and never a shell"

echo "--- S1 security classification -------------------------------------------"

[[ $(deck_form_net_security_class open) == none ]] || fail "'open' must need no passphrase"
[[ $(deck_form_net_security_class psk) == passphrase ]] || fail "'psk' must need a passphrase"
[[ $(deck_form_net_security_class wep) == passphrase ]] || fail "'wep' must need a passphrase"
[[ $(deck_form_net_security_class 8021x) == unsupported ]] ||
  fail "'8021x' must be UNSUPPORTED -- a passphrase prompt for an enterprise network is three guaranteed failures and a user who thinks they mistyped"
[[ $(deck_form_net_security_class "something-iwd-grows-later") == unsupported ]] ||
  fail "an unknown security type must default to unsupported, not to 'try a passphrase'"
pass "security classification: open/psk/wep/8021x, and an unknown type defaults to unsupported"

echo "--- S1 DHCP detection: the link-local trap -------------------------------"

deck_form_has_ipv4 "wlan0            UP             192.168.1.50/24" ||
  fail "a routable address must count as DHCP success"
# 🔴 169.254.0.0/16 is what you get when DHCP FAILED. Counting it would
# make §5's "associated, no DHCP" row report success on the exact case it
# was written to detect.
deck_form_has_ipv4 "wlan0            UP             169.254.12.7/16" &&
  fail "a 169.254 link-local address must NOT count as DHCP success -- it is the signature of DHCP failing"
deck_form_has_ipv4 "lo               UNKNOWN        127.0.0.1/8" &&
  fail "a loopback address must not count as a wireless link being configured"
deck_form_has_ipv4 "wlan0            DOWN" &&
  fail "an interface with no address at all must not count as configured"
deck_form_has_ipv4 "" &&
  fail "empty ip output must not count as configured"
deck_form_has_ipv4 "wlan0  UP  169.254.12.7/16 10.0.0.9/24" ||
  fail "a real address alongside a link-local one must still count"
pass "DHCP detection accepts a routable v4 address and rejects link-local, loopback, and no address"

echo "--- S1 connect verdict: belt AND braces ----------------------------------"

[[ $(deck_form_connect_verdict 0 "") == ok ]] || fail "exit 0 with clean output must be ok"
[[ $(deck_form_connect_verdict 1 "") == failed ]] || fail "a nonzero exit must be failed"
# ⚠️ The reason the output is inspected at all: iwctl has been observed to
# print a failure and still exit 0.
[[ $(deck_form_connect_verdict 0 "Operation failed") == failed ]] ||
  fail "a failure printed alongside exit 0 must still be failed -- otherwise a wrong passphrase reads as connected"
[[ $(deck_form_connect_verdict 0 "Network not found") == failed ]] || fail "'Network not found' must be failed"
[[ $(deck_form_connect_verdict 0 "Connected to MyNet") == ok ]] ||
  fail "an ordinary success line must not be misread as a failure"
pass "connect verdict combines the exit status AND the output, so an exit-0 failure is not reported as connected"

echo "--- S1 captive-portal verdict --------------------------------------------"

[[ $(deck_form_portal_verdict 0 "$DECK_NET_PORTAL_EXPECT") == online ]] ||
  fail "the expected probe body must read as online"
[[ $(deck_form_portal_verdict 0 "<html>Please sign in to HotelWiFi</html>") == portal ]] ||
  fail "a body that is not the expected one must read as a captive portal"
[[ $(deck_form_portal_verdict 0 "") == portal ]] ||
  fail "an empty body with exit 0 (a bare redirect, curl without -L) must read as a captive portal"
[[ $(deck_form_portal_verdict 7 "") == unreachable ]] ||
  fail "a failed probe must read as unreachable, which is NOT the same sentence as a portal"
pass "portal verdict distinguishes online / portal / unreachable (three outcomes, three different sentences)"

echo "--- S1 offline consequence text (§5, stated on skip AND on S5) ----------"

offline=$(deck_form_wifi_offline_text)
LC_ALL=C grep -qF "audio DSP firmware and Steam are not downloaded" <<<"$offline" ||
  fail "§5's consequence text must name what is not downloaded"
LC_ALL=C grep -qF "Gaming Mode will have no Steam" <<<"$offline" ||
  fail "§5's consequence text must name the Gaming Mode consequence"
LC_ALL=C grep -qF "Desktop Mode afterwards" <<<"$offline" ||
  fail "§5's consequence text must say Wi-Fi can be set up later"
pass "the offline consequence text carries all three of §5's clauses"

echo "--- S1 wireless-interface detection (sysfs, not a name pattern) ----------"

mkdir -p "$work/net-a/eth0" "$work/net-a/wlan0/wireless" "$work/net-a/lo"
[[ $(DECK_NET_SYSFS="$work/net-a" deck_form_wifi_iface) == wlan0 ]] ||
  fail "wifi_iface must find the interface with a 'wireless' subdirectory"
# The name is NOT the test: an interface called wlp2s0, or a renamed one,
# must be found, and an interface called wlan0 with no wireless dir must
# not be.
mkdir -p "$work/net-b/wlan0" "$work/net-b/wlp2s0/wireless"
[[ $(DECK_NET_SYSFS="$work/net-b" deck_form_wifi_iface) == wlp2s0 ]] ||
  fail "wifi_iface must key off the sysfs 'wireless' directory, NOT off the interface name"
mkdir -p "$work/net-none/eth0"
DECK_NET_SYSFS="$work/net-none" deck_form_wifi_iface >/dev/null 2>&1 &&
  fail "wifi_iface must report failure when no interface is wireless"
mkdir -p "$work/net-truly-empty"
DECK_NET_SYSFS="$work/net-truly-empty" deck_form_wifi_iface >/dev/null 2>&1 &&
  fail "wifi_iface must report failure on an empty sysfs root (the unmatched-glob case)"
pass "wireless detection is by sysfs 'wireless' dir, not by name, and reports absence rather than guessing"

echo "--- U1: the NetworkManager keyfile ---------------------------------------"

printf '11111111-2222-3333-4444-555555555555\n' >"$work/uuid"

nm=$(deck_form_nmconnection "MyNet" "s3cret!" "11111111-2222-3333-4444-555555555555")
LC_ALL=C grep -qxF 'ssid=MyNet' <<<"$nm" || fail "the keyfile must carry the SSID" "$nm"
LC_ALL=C grep -qxF 'psk=s3cret!' <<<"$nm" || fail "the keyfile must carry the passphrase" "$nm"
LC_ALL=C grep -qxF 'key-mgmt=wpa-psk' <<<"$nm" || fail "a secured network's keyfile must set key-mgmt" "$nm"
LC_ALL=C grep -qxF 'type=wifi' <<<"$nm" || fail "the keyfile must declare type=wifi" "$nm"
LC_ALL=C grep -qxF 'method=auto' <<<"$nm" || fail "the keyfile must ask for DHCP" "$nm"
pass "the staged keyfile is a complete NetworkManager wifi profile with the PSK"

# An open network must NOT get a [wifi-security] section: NetworkManager
# reads the presence of that section as "this network is secured", so an
# empty psk= makes an open network unjoinable.
nm_open=$(deck_form_nmconnection "OpenGuest" "" "11111111-2222-3333-4444-555555555555")
LC_ALL=C grep -qF 'wifi-security' <<<"$nm_open" &&
  fail "an OPEN network's keyfile must have no [wifi-security] section at all"
LC_ALL=C grep -qxF 'ssid=OpenGuest' <<<"$nm_open" || fail "the open-network keyfile must still carry the SSID"
pass "an open network's keyfile omits [wifi-security] entirely"

# 🔴 ini injection. A newline in an SSID would otherwise write a whole new
# key -- or a whole new [section] -- into a root-owned credential file.
deck_form_nmconnection $'Evil\nautoconnect=false' "pw" "11111111-2222-3333-4444-555555555555" >/dev/null 2>&1 &&
  fail "an SSID containing a newline must be REFUSED, not written into the keyfile"
deck_form_nmconnection $'Evil\n[connection]\nid=hijack' "pw" "11111111-2222-3333-4444-555555555555" >/dev/null 2>&1 &&
  fail "an SSID that would inject a whole ini section must be refused"
deck_form_nmconnection "MyNet" $'pw\npsk-flags=0' "11111111-2222-3333-4444-555555555555" >/dev/null 2>&1 &&
  fail "a passphrase containing a newline must be refused"
pass "the keyfile writer refuses newline injection in both the SSID and the passphrase"

# GKeyFile strips surrounding whitespace on read, so a value written with
# it would come back out DIFFERENT -- a silently wrong SSID, which is worse
# than a refusal.
deck_form_nmconnection " LeadingSpace" "pw" "11111111-2222-3333-4444-555555555555" >/dev/null 2>&1 &&
  fail "an SSID with a leading space must be refused (GKeyFile would strip it and join the wrong network)"
deck_form_nmconnection "TrailingSpace " "pw" "11111111-2222-3333-4444-555555555555" >/dev/null 2>&1 &&
  fail "an SSID with a trailing space must be refused"
deck_form_nmconnection "" "pw" "11111111-2222-3333-4444-555555555555" >/dev/null 2>&1 &&
  fail "an empty SSID must be refused -- 'ssid=' is a profile for nothing"
pass "the keyfile writer refuses values GKeyFile would silently alter (leading/trailing space, empty)"

# An SSID with an interior space is a real, common shape and must WORK.
nm_sp=$(deck_form_nmconnection "My Home Network" "pw" "11111111-2222-3333-4444-555555555555")
LC_ALL=C grep -qxF 'ssid=My Home Network' <<<"$nm_sp" ||
  fail "an ordinary space-containing SSID must be written, not refused" "$nm_sp"
pass "an interior space in an SSID is written through unharmed"

echo "--- U1: the staged file is 0600 BEFORE the secret is in it ---------------"

DECK_UUID_SOURCE="$work/uuid" deck_form_stage_nmconnection "$work/staged.nmconnection" "MyNet" "s3cret!" ||
  fail "staging a keyfile for a well-formed SSID must succeed"
mode=$(stat -c '%a' "$work/staged.nmconnection")
[[ $mode == 600 ]] ||
  fail "the staged keyfile must be mode 0600 -- NetworkManager REFUSES a group/world-readable keyfile, and it holds a passphrase" "got: $mode"
LC_ALL=C grep -qxF 'psk=s3cret!' "$work/staged.nmconnection" || fail "the staged keyfile must actually contain the PSK"
LC_ALL=C grep -qxF 'uuid=11111111-2222-3333-4444-555555555555' "$work/staged.nmconnection" ||
  fail "the staged keyfile must carry the uuid from the uuid source"
pass "the staged keyfile is written 0600 and carries the PSK and a uuid"

# A refused SSID must leave NO file behind -- a half-written credential
# file that NetworkManager later half-reads is worse than none.
DECK_UUID_SOURCE="$work/uuid" \
  deck_form_stage_nmconnection "$work/staged-bad.nmconnection" $'Evil\nautoconnect=false' "pw" >/dev/null 2>&1 &&
  fail "staging must fail for an unsafe SSID"
[[ ! -e "$work/staged-bad.nmconnection" ]] ||
  fail "a refused staging must leave no file behind" "$(cat "$work/staged-bad.nmconnection")"
pass "a refused staging leaves no partial credential file on disk"

echo "--- U1: the outcome record is parsed, never sourced ----------------------"

mkdir -p "$work/state"
deck_form_wifi_record_outcome "$work/state" connected $'Evil\nstatus=hijacked' ||
  fail "recording an outcome must succeed"
[[ $(LC_ALL=C command grep -c . "$work/state/$DECK_NET_OUTCOME_FILE") -eq 2 ]] ||
  fail "a hostile SSID must not be able to add lines to the outcome record" \
       "$(cat "$work/state/$DECK_NET_OUTCOME_FILE")"
LC_ALL=C grep -qxF 'status=connected' "$work/state/$DECK_NET_OUTCOME_FILE" ||
  fail "the outcome record must carry the status it was given, not the injected one"
pass "the outcome record sanitises the SSID, so a hostile network name cannot forge a status line"

echo "--- S1 the passphrase prompt: --password, and a sanitised prompt string --"

# 🔴 MEASURED on the real wizard (T4 §4 S1's flow trace): passwords never
# echo. The OSK is how the user types and the field shows dots.
: >"$work/gum-pass.log"
got=$(FAKE_GUM_LOG="$work/gum-pass.log" FAKE_GUM_INPUT_OUTPUT="hunter2" \
      DECK_FORM_OSK_UP=1 PATH="$work/bin-fakegum:$PATH" \
      deck_form_wifi_passphrase_body "MyNet" 2>/dev/null)
[[ $got == hunter2 ]] || fail "the passphrase body must return what was typed" "got: $got"
LC_ALL=C grep -qF -- "--password" "$work/gum-pass.log" ||
  fail "the passphrase prompt MUST pass --password -- a Wi-Fi passphrase must never echo on a screen someone else can see" \
       "$(cat "$work/gum-pass.log")"
pass "the passphrase prompt uses gum input --password (never echoes) and returns what was typed"

# The SSID reaches a --prompt string that is written straight to the
# console. An ANSI escape there repaints the screen the user is typing a
# password into.
: >"$work/gum-hostile.log"
FAKE_GUM_LOG="$work/gum-hostile.log" FAKE_GUM_INPUT_OUTPUT="x" \
  DECK_FORM_OSK_UP=1 PATH="$work/bin-fakegum:$PATH" \
  deck_form_wifi_passphrase_body $'Evil\x1b[2JNet' >/dev/null 2>&1
LC_ALL=C command grep -q $'\x1b' "$work/gum-hostile.log" &&
  fail "a hostile SSID must be sanitised BEFORE it reaches the gum --prompt string" \
       "$(od -c "$work/gum-hostile.log" | head -5)"
pass "the passphrase prompt sanitises the SSID before drawing it (the prompt is an ANSI sink too)"

# §2.3: an OSK that did not come up is "a degradation the screen must
# state, not swallow" -- and on THIS screen it means there is no way to
# type at all, so it must also say what to do instead.
warn=$(FAKE_GUM_INPUT_OUTPUT="x" DECK_FORM_OSK_UP=0 PATH="$work/bin-fakegum:$PATH" \
       deck_form_wifi_passphrase_body "MyNet" 2>&1 >/dev/null)
LC_ALL=C grep -qF "on-screen keyboard did not start" <<<"$warn" ||
  fail "a missing OSK must be STATED on the passphrase screen, not swallowed" "$warn"
LC_ALL=C grep -qF "$DECK_NET_SKIP_ROW" <<<"$warn" ||
  fail "with no keyboard the screen must name the way out (the Skip row), or the user is stuck"
pass "a missing OSK is stated loudly on the passphrase screen, together with the way out"

echo "--- S1 end-to-end through deck_form_wifi_screen (§5's whole tree) --------"

# A fake iwctl driven entirely by files, so every §5 branch is reachable
# without a radio. It logs every invocation, so "did the passphrase reach
# iwctl" is asserted on what the command RECEIVED, not on the screen --
# T4-screen-spec.md §6.2's A4 primitive applied at the [U] tier.
mkdir -p "$work/bin-net"
cat >"$work/bin-net/iwctl" <<'IWCTL'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$IWCTL_LOG"
case "$*" in
  *get-networks*) cat "$IWCTL_NETWORKS" ; exit 0 ;;
  *scan*)         exit "${IWCTL_SCAN_RC:-0}" ;;
  *connect*)
    printf '%s\n' "${IWCTL_CONNECT_OUTPUT:-}"
    exit "${IWCTL_CONNECT_RC:-0}"
    ;;
esac
exit 0
IWCTL
chmod +x "$work/bin-net/iwctl"

cat >"$work/bin-net/ip" <<'IPBIN'
#!/usr/bin/env bash
cat "${IP_ADDR_OUTPUT:-/dev/null}"
exit 0
IPBIN
chmod +x "$work/bin-net/ip"

cat >"$work/bin-net/systemctl" <<'SYSTEMCTL'
#!/usr/bin/env bash
[[ -n ${SYSTEMCTL_FAIL:-} ]] && { printf 'Job for iwd.service failed.\n'; exit 1; }
exit 0
SYSTEMCTL
chmod +x "$work/bin-net/systemctl"

mkdir -p "$work/net-live/wlan0/wireless"
cp "$work/iwctl.raw" "$work/networks.raw"

# A no-op mapper stand-in that reports bound instantly, so the passphrase
# path exercises deck_form_text_prompt for real rather than being stubbed
# past it.
cat >"$work/fake-mapper-fast" <<'EOF'
#!/usr/bin/env bash
echo "deck-input-mapper: bound"
sleep 5
EOF
chmod +x "$work/fake-mapper-fast"

# Every S1 run shares this environment; only the queues and the fake
# command outcomes change per case.
s1_env=(
  DECK_NET_SYSFS="$work/net-live"
  DECK_IWCTL_BIN="$work/bin-net/iwctl"
  DECK_IP_BIN="$work/bin-net/ip"
  DECK_SYSTEMCTL_BIN="$work/bin-net/systemctl"
  DECK_CURL_BIN="$work/bin-net/curl-missing"
  DECK_NET_SCAN_SETTLE_OVERRIDE=0
  DECK_NET_DHCP_DEADLINE_OVERRIDE=0
  DECK_NET_DHCP_POLL_OVERRIDE=0
  DECK_TEXT_PROMPT_LIZARD_SYSFS="$work/s1-lizard"
  DECK_TEXT_PROMPT_MAPPER_BIN="$work/fake-mapper-fast"
  DECK_TEXT_PROMPT_DEADLINE=3
  DECK_UUID_SOURCE="$work/uuid"
  IWCTL_NETWORKS="$work/networks.raw"
  FAKE_GUM_CHOOSE_EXHAUSTED="$DECK_NET_SKIP_ROW"
  PATH="$work/bin-fakegum:$work/bin-net:$PATH"
)

# ⚠️ EACH S1 CASE RUNS IN A FRESH `bash`, NOT IN THIS SHELL. Three reasons,
# all of them things that bit earlier drafts:
#   - S1 loops. A case that misbehaves would spin THIS process, and the
#     suite watchdog would kill everything with no per-case attribution;
#     each case gets its own `timeout` instead.
#   - S1 sets globals (DECK_WIFI_SSID) and `readonly` constants are already
#     bound here, so re-sourcing in-process to reset state is impossible.
#   - deck-form.sh must be provably runnable when sourced into a shell that
#     is NOT this suite -- which is its actual deployment (upstream's
#     `configurator`). A fresh bash with only the three upstream helpers
#     defined is much closer to that than this suite's environment.
# The wrapper carries the same minimal upstream stubs, and nothing else.
cat >"$work/s1-boot.sh" <<'BOOT'
clear_logo() { :; }
say() { printf '%s\n' "$*" >>"${DECK_TEST_SAY_LOG:-/dev/null}"; }
step() { printf '%s\n' "$*" >>"${DECK_TEST_SAY_LOG:-/dev/null}"; }
source "$DECK_FORM_PATH"
deck_form_wifi_screen
rc=$?
# DECK_WIFI_SSID is the ONLY thing S1 hands to S5 (deck_form_summary_rows
# reads it directly), and it dies with this subshell -- so dump it, or the
# one value that crosses the screen boundary is untested.
printf '%s' "${DECK_WIFI_SSID:-}" >"${DECK_TEST_SSID_OUT:-/dev/null}"
exit $rc
BOOT

s1_run() {
  local name=$1; shift
  rm -rf "$work/s1-$name"; mkdir -p "$work/s1-$name"
  printf 'Y\n' >"$work/s1-lizard"
  : >"$work/s1-$name/choose.q"
  local l
  for l in "$@"; do printf '%s\n' "$l" >>"$work/s1-$name/choose.q"; done
  : >"$work/s1-$name/iwctl.log"
  : >"$work/s1-$name/gum.log"
  s1_rc=0
  env "${s1_env[@]}" \
      DECK_FORM_PATH="$DECK_FORM_SH" \
      DECK_NET_STATE_DIR="$work/s1-$name" \
      DECK_TEST_SAY_LOG="$work/s1-$name/say.log" \
      DECK_TEST_SSID_OUT="$work/s1-$name/wifi-ssid" \
      IWCTL_LOG="$work/s1-$name/iwctl.log" \
      FAKE_GUM_LOG="$work/s1-$name/gum.log" \
      FAKE_GUM_CHOOSE_QUEUE="$work/s1-$name/choose.q" \
      FAKE_GUM_INPUT_QUEUE="${S1_INPUT_QUEUE:-}" \
      IWCTL_CONNECT_RC="${S1_CONNECT_RC:-0}" \
      IWCTL_CONNECT_OUTPUT="${S1_CONNECT_OUTPUT:-}" \
      IP_ADDR_OUTPUT="${S1_IP_OUTPUT:-/dev/null}" \
      SYSTEMCTL_FAIL="${S1_SYSTEMCTL_FAIL:-}" \
      timeout 40 bash "$work/s1-boot.sh" \
      >"$work/s1-$name/stdout" 2>"$work/s1-$name/stderr" || s1_rc=$?
}

s1_say()   { cat "$work/s1-$1/say.log"; }
s1_out()   { cat "$work/s1-$1/${DECK_NET_OUTCOME_FILE}" 2>/dev/null; }

# --- §5 row 1: no wlan0 -> skip S1 entirely, never block ---
mkdir -p "$work/s1-nohw"
env "${s1_env[@]}" DECK_NET_SYSFS="$work/net-none" \
    DECK_FORM_PATH="$DECK_FORM_SH" \
    DECK_NET_STATE_DIR="$work/s1-nohw" DECK_TEST_SAY_LOG="$work/s1-nohw/say2.log" \
    IWCTL_LOG="$work/s1-nohw/iwctl.log" FAKE_GUM_LOG="$work/s1-nohw/gum.log" \
    timeout 20 bash "$work/s1-boot.sh" >/dev/null 2>&1 || fail "S1 must return 0 with no Wi-Fi hardware -- it must never block the install (this is also every QEMU run)"
LC_ALL=C grep -qF "No Wi-Fi hardware found" "$work/s1-nohw/say2.log" ||
  fail "S1 must SAY that no Wi-Fi hardware was found" "$(cat "$work/s1-nohw/say2.log")"
LC_ALL=C grep -qF "audio DSP firmware and Steam are not downloaded" "$work/s1-nohw/say2.log" ||
  fail "the no-hardware path must state §5's offline consequence, not just skip silently"
LC_ALL=C grep -qxF "status=no-hardware" "$work/s1-nohw/$DECK_NET_OUTCOME_FILE" ||
  fail "the no-hardware path must record its outcome" "$(cat "$work/s1-nohw/$DECK_NET_OUTCOME_FILE")"
pass "§5: no Wi-Fi hardware -> S1 returns 0, says so, states the consequence, records no-hardware"

# --- §5 row 2: iwd will not start ---
S1_SYSTEMCTL_FAIL=1 s1_run iwddead "$DECK_NET_SKIP_ROW"
[[ $s1_rc -eq 0 ]] || fail "a dead iwd must not block the install" "rc=$s1_rc"
LC_ALL=C grep -qF "would not start" "$(printf '%s' "$work/s1-iwddead/say.log")" ||
  fail "S1 must say iwd would not start"
LC_ALL=C grep -qF "Job for iwd.service failed" "$work/s1-iwddead/say.log" ||
  fail "§5: the unit's own status line must be SHOWN, never swallowed" "$(s1_say iwddead)"
LC_ALL=C grep -qxF "status=iwd-failed" "$work/s1-iwddead/$DECK_NET_OUTCOME_FILE" ||
  fail "the dead-iwd path must record its outcome"
unset S1_SYSTEMCTL_FAIL
pass "§5: iwd will not start -> continues offline, SHOWS the unit's status line, records iwd-failed"

# --- §5 row 7: the user picks Skip ---
s1_run skip "$DECK_NET_SKIP_ROW"
[[ $s1_rc -eq 0 ]] || fail "the Skip row must complete the screen" "rc=$s1_rc"
LC_ALL=C grep -qxF "status=skipped" "$work/s1-skip/$DECK_NET_OUTCOME_FILE" ||
  fail "Skip must record the skipped outcome" "$(s1_out skip)"
LC_ALL=C grep -qF "audio DSP firmware and Steam are not downloaded" "$work/s1-skip/say.log" ||
  fail "§5: the consequence must be stated on S1's skip"
[[ ! -e "$work/s1-skip/$DECK_NET_STAGED_NMCONNECTION" ]] ||
  fail "Skip must not stage a NetworkManager profile"
pass "§5: Skip -> completes, states the consequence, records skipped, stages nothing"

# --- the cancel fallback, driven for real: B on the list REDRAWS ---
s1_run cancel "<CANCEL>" "<CANCEL>" "$DECK_NET_RESCAN_ROW" "$DECK_NET_SKIP_ROW"
[[ $s1_rc -eq 0 ]] || fail "a cancelled list must redraw and the screen still complete" "rc=$s1_rc"
LC_ALL=C grep -qF "CHOOSE-QUEUE-EXHAUSTED" "$work/s1-cancel/gum.log" &&
  fail "the cancel/rescan case ran off the end of its scripted answers -- the loop is not doing what this test claims"
[[ $(LC_ALL=C command grep -c '^choose' "$work/s1-cancel/gum.log") -eq 4 ]] ||
  fail "two cancels and a rescan must each redraw the list (4 menus in total)" "$(cat "$work/s1-cancel/gum.log")"
pass "B/Esc on the network list REDRAWS (never acts), and Rescan redraws too"

# --- §5 row 4: wrong passphrase, bounded at 3 tries ---
printf 'wrong1\nwrong2\nwrong3\nwrong4\n' >"$work/pass.q"
S1_INPUT_QUEUE="$work/pass.q" S1_CONNECT_RC=1 \
  s1_run wrongpw $'\360\237\224\222 My Home Network' "$DECK_NET_SKIP_ROW"
[[ $s1_rc -eq 0 ]] || fail "three wrong passphrases must end back at the list, not stuck" "rc=$s1_rc"
LC_ALL=C grep -qF "That didn't work -- check the password" "$work/s1-wrongpw/say.log" ||
  fail "§5's exact retry sentence must be shown" "$(s1_say wrongpw)"
tries=$(LC_ALL=C command grep -c 'connect' "$work/s1-wrongpw/iwctl.log")
[[ $tries -eq 3 ]] ||
  fail "§5: the passphrase loop must be BOUNDED AT 3 tries -- nobody stuck in a loop they cannot escape" "iwctl connect attempts: $tries"
LC_ALL=C grep -qF "Back to the network list" "$work/s1-wrongpw/say.log" ||
  fail "after the bound is reached the screen must say it is going back to the list"
[[ $(LC_ALL=C command grep -c . "$work/pass.q") -eq 1 ]] ||
  fail "exactly three passphrases must have been consumed (a 4th prompt means the bound leaked)" "$(cat "$work/pass.q")"
unset S1_INPUT_QUEUE S1_CONNECT_RC
pass "§5: a wrong passphrase re-prompts with the right sentence and is bounded at exactly 3 tries"

# --- the happy path, and what iwctl RECEIVED ---
printf 'C0rrect horse!\n' >"$work/pass-ok.q"
printf 'wlan0 UP 192.168.1.50/24\n' >"$work/ip-ok"
S1_INPUT_QUEUE="$work/pass-ok.q" S1_IP_OUTPUT="$work/ip-ok" \
  s1_run happy $'\360\237\224\222 My Home Network'
[[ $s1_rc -eq 0 ]] || fail "a successful join must return 0" "rc=$s1_rc; $(cat "$work/s1-happy/stderr")"
# A4: assert on what the command RECEIVED, not on the screen.
LC_ALL=C grep -qF -- "--passphrase C0rrect horse! station wlan0 connect My Home Network" "$work/s1-happy/iwctl.log" ||
  fail "the typed passphrase and the RAW SSID must reach iwctl exactly" "$(cat "$work/s1-happy/iwctl.log")"
LC_ALL=C grep -qxF "status=connected" "$work/s1-happy/$DECK_NET_OUTCOME_FILE" ||
  fail "a successful join must record connected"
[[ -f "$work/s1-happy/$DECK_NET_STAGED_NMCONNECTION" ]] ||
  fail "🔴 U1: a successful join must STAGE a NetworkManager keyfile -- without it the Deck boots with no Wi-Fi and no way to type"
LC_ALL=C grep -qxF 'psk=C0rrect horse!' "$work/s1-happy/$DECK_NET_STAGED_NMCONNECTION" ||
  fail "the staged keyfile must carry the passphrase the user actually typed" "$(cat "$work/s1-happy/$DECK_NET_STAGED_NMCONNECTION")"
[[ $(stat -c '%a' "$work/s1-happy/$DECK_NET_STAGED_NMCONNECTION") == 600 ]] ||
  fail "the staged keyfile must be 0600 on the real path, not only in the unit test of the writer"
unset S1_INPUT_QUEUE S1_IP_OUTPUT
pass "the happy path joins, records connected, and stages a 0600 NetworkManager keyfile with the real PSK (U1)"

# --- an OPEN network needs no passphrase prompt at all ---
printf 'wlan0 UP 192.168.1.51/24\n' >"$work/ip-ok2"
: >"$work/pass-none.q"
S1_INPUT_QUEUE="$work/pass-none.q" S1_IP_OUTPUT="$work/ip-ok2" \
  s1_run open "OpenGuest"
[[ $s1_rc -eq 0 ]] || fail "joining an open network must succeed" "rc=$s1_rc"
LC_ALL=C grep -qF -- "--passphrase" "$work/s1-open/iwctl.log" &&
  fail "an OPEN network must be joined with no --passphrase at all"
LC_ALL=C grep -qF "input" "$work/s1-open/gum.log" &&
  fail "an OPEN network must never raise the passphrase prompt"
LC_ALL=C grep -qF 'wifi-security' "$work/s1-open/$DECK_NET_STAGED_NMCONNECTION" &&
  fail "an open network's staged keyfile must have no [wifi-security] section"
unset S1_INPUT_QUEUE S1_IP_OUTPUT
pass "an open network joins with no passphrase prompt and stages an unsecured keyfile"

# --- §5 row 5: associated, no DHCP -- the case a naive check calls success ---
printf 'C0rrect horse!\n' >"$work/pass-dhcp.q"
printf 'wlan0 UP 169.254.9.9/16\n' >"$work/ip-linklocal"
S1_INPUT_QUEUE="$work/pass-dhcp.q" S1_IP_OUTPUT="$work/ip-linklocal" \
  s1_run nodhcp $'\360\237\224\222 My Home Network' "$DECK_NET_SKIP_ROW"
[[ $s1_rc -eq 0 ]] || fail "a DHCP failure must be recoverable, not fatal" "rc=$s1_rc"
LC_ALL=C grep -qF "never handed out an address" "$work/s1-nodhcp/say.log" ||
  fail "§5: an association with no DHCP must be reported as a failure, not as success" "$(s1_say nodhcp)"
LC_ALL=C grep -qxF "status=connected" "$work/s1-nodhcp/$DECK_NET_OUTCOME_FILE" &&
  fail "🔴 a link-local address must NOT be recorded as connected -- that is the exact false success §5 row 5 exists to catch"
[[ ! -e "$work/s1-nodhcp/$DECK_NET_STAGED_NMCONNECTION" ]] ||
  fail "a network that never gave out an address must not be staged for the installed system"
# 🔴 MUTATION-FOUND GAP, closed. Skip inside the DHCP menu must end the
# WHOLE screen, not bounce back to the network list. Both spellings reach
# "skipped" in the end (the list would be redrawn and Skip picked again),
# so only the SHAPE of the run distinguishes them: exactly two menus (the
# list, then the failure menu) and no fallback onto the fake's exhausted
# answer. Without this the join function's 1-vs-2 status vocabulary was
# untested.
LC_ALL=C grep -qF "CHOOSE-QUEUE-EXHAUSTED" "$work/s1-nodhcp/gum.log" &&
  fail "Skip inside the DHCP failure menu must END the screen -- this run fell through to an extra menu"
[[ $(LC_ALL=C command grep -c '^choose' "$work/s1-nodhcp/gum.log") -eq 2 ]] ||
  fail "the no-DHCP run must draw exactly two menus: the network list, then the failure menu" \
       "$(cat "$work/s1-nodhcp/gum.log")"
LC_ALL=C grep -qxF "status=skipped" "$work/s1-nodhcp/$DECK_NET_OUTCOME_FILE" ||
  fail "Skip inside the DHCP menu must record the skipped outcome"
unset S1_INPUT_QUEUE S1_IP_OUTPUT
pass "§5: associated-but-no-DHCP is a failure with a recovery menu, never a recorded success"

# --- the DHCP menu's own three answers, driven for real ---
printf 'pw1\npw2\n' >"$work/pass-retry.q"
S1_INPUT_QUEUE="$work/pass-retry.q" S1_IP_OUTPUT="$work/ip-linklocal" \
  s1_run dhcpretry $'\360\237\224\222 My Home Network' "Try again" "Pick another network" "$DECK_NET_SKIP_ROW"
[[ $s1_rc -eq 0 ]] || fail "the DHCP menu must always end somewhere reachable" "rc=$s1_rc"
retries=$(LC_ALL=C command grep -c 'connect' "$work/s1-dhcpretry/iwctl.log")
[[ $retries -eq 2 ]] ||
  fail "'Try again' must re-run the join for the SAME network (2 connects), then 'Pick another' must go back to the list" "connects: $retries"
unset S1_INPUT_QUEUE S1_IP_OUTPUT
pass "the DHCP failure menu's Try again re-joins the same network, and Pick another returns to the list"

# --- §5 row 6: captive portal ---
mkdir -p "$work/bin-portal"
cat >"$work/bin-portal/curl" <<'CURL'
#!/usr/bin/env bash
printf '%s' "${CURL_BODY:-}"
exit "${CURL_RC:-0}"
CURL
chmod +x "$work/bin-portal/curl"
printf 'C0rrect horse!\n' >"$work/pass-portal.q"
printf 'wlan0 UP 10.0.0.9/24\n' >"$work/ip-portal"
rm -rf "$work/s1-portal"; mkdir -p "$work/s1-portal"
printf 'Y\n' >"$work/s1-lizard"
printf '%s\n%s\n' $'\360\237\224\222 My Home Network' "$DECK_NET_SKIP_ROW" >"$work/s1-portal/choose.q"
: >"$work/s1-portal/iwctl.log"; : >"$work/s1-portal/gum.log"
env "${s1_env[@]}" \
    DECK_CURL_BIN="$work/bin-portal/curl" \
    DECK_FORM_PATH="$DECK_FORM_SH" \
    DECK_NET_STATE_DIR="$work/s1-portal" \
    DECK_TEST_SAY_LOG="$work/s1-portal/say.log" \
    IWCTL_LOG="$work/s1-portal/iwctl.log" \
    FAKE_GUM_LOG="$work/s1-portal/gum.log" \
    FAKE_GUM_CHOOSE_QUEUE="$work/s1-portal/choose.q" \
    FAKE_GUM_INPUT_QUEUE="$work/pass-portal.q" \
    IP_ADDR_OUTPUT="$work/ip-portal" \
    CURL_BODY='<html>Hotel sign-in</html>' \
    PATH="$work/bin-portal:$work/bin-fakegum:$work/bin-net:$PATH" \
    timeout 40 bash "$work/s1-boot.sh" >/dev/null 2>&1 ||
  fail "a captive portal must be recoverable from the controller, not fatal"
LC_ALL=C grep -qF "needs a web sign-in page" "$work/s1-portal/say.log" ||
  fail "§5: a captive portal must be stated plainly" "$(cat "$work/s1-portal/say.log")"
LC_ALL=C grep -qxF "status=connected" "$work/s1-portal/$DECK_NET_OUTCOME_FILE" &&
  fail "a captive-portal network must NOT be recorded as usable"
[[ ! -e "$work/s1-portal/$DECK_NET_STAGED_NMCONNECTION" ]] ||
  fail "a captive-portal network must not be staged for the installed system"
pass "§5: a captive portal is stated plainly, never rendered, never recorded as connected, and is recoverable"

# --- §5 row 3: scan returns nothing ---
: >"$work/networks-empty.raw"
rm -rf "$work/s1-noscan"; mkdir -p "$work/s1-noscan"
printf 'Y\n' >"$work/s1-lizard"
printf '%s\n' "$DECK_NET_SKIP_ROW" >"$work/s1-noscan/choose.q"
: >"$work/s1-noscan/iwctl.log"; : >"$work/s1-noscan/gum.log"
env "${s1_env[@]}" \
    IWCTL_NETWORKS="$work/networks-empty.raw" \
    DECK_FORM_PATH="$DECK_FORM_SH" \
    DECK_NET_STATE_DIR="$work/s1-noscan" \
    DECK_TEST_SAY_LOG="$work/s1-noscan/say.log" \
    IWCTL_LOG="$work/s1-noscan/iwctl.log" \
    FAKE_GUM_LOG="$work/s1-noscan/gum.log" \
    FAKE_GUM_CHOOSE_QUEUE="$work/s1-noscan/choose.q" \
    timeout 40 bash "$work/s1-boot.sh" >/dev/null 2>&1 ||
  fail "an empty scan must not block the screen"
LC_ALL=C grep -qF "No networks found. Move closer, or skip." "$work/s1-noscan/say.log" ||
  fail "§5's exact empty-scan sentence must be shown" "$(cat "$work/s1-noscan/say.log")"
# 🔴 MUTATION-FOUND GAP, closed. This used to read `-eq $DECK_NET_SCAN_TRIES`
# -- a tautology: mutating the constant to 1 moved the expectation with the
# behaviour and the test stayed green. §5's number is TWO ("empty
# get-networks after two tries"), so two is what is asserted, literally,
# in both places.
scans=$(LC_ALL=C command grep -c 'scan' "$work/s1-noscan/iwctl.log")
[[ $scans -eq 2 ]] ||
  fail "§5: an empty result must be retried exactly twice before giving up" "scans: $scans"
[[ $DECK_NET_SCAN_TRIES -eq 2 ]] ||
  fail "§5's scan-retry count is two" "DECK_NET_SCAN_TRIES=$DECK_NET_SCAN_TRIES"
LC_ALL=C grep -qxF "status=skipped" "$work/s1-noscan/$DECK_NET_OUTCOME_FILE" ||
  fail "the empty-scan screen must still reach Skip"
pass "§5: an empty scan retries twice, says exactly what §5 asks, and still offers Skip"

# --- an enterprise network must not open a passphrase prompt it cannot use ---
cat >"$work/networks-8021x.raw" <<EOF
                                        Available networks
------------------------------------------------------------------------
    Network name                    Security             Signal
------------------------------------------------------------------------
    CorpNet                         8021x                ****
EOF
rm -rf "$work/s1-corp"; mkdir -p "$work/s1-corp"
printf 'Y\n' >"$work/s1-lizard"
printf '%s\n%s\n' $'\360\237\224\222 CorpNet' "$DECK_NET_SKIP_ROW" >"$work/s1-corp/choose.q"
: >"$work/s1-corp/iwctl.log"; : >"$work/s1-corp/gum.log"
env "${s1_env[@]}" \
    IWCTL_NETWORKS="$work/networks-8021x.raw" \
    DECK_FORM_PATH="$DECK_FORM_SH" \
    DECK_NET_STATE_DIR="$work/s1-corp" \
    DECK_TEST_SAY_LOG="$work/s1-corp/say.log" \
    IWCTL_LOG="$work/s1-corp/iwctl.log" \
    FAKE_GUM_LOG="$work/s1-corp/gum.log" \
    FAKE_GUM_CHOOSE_QUEUE="$work/s1-corp/choose.q" \
    timeout 40 bash "$work/s1-boot.sh" >/dev/null 2>&1 ||
  fail "an enterprise network must not break the screen"
LC_ALL=C grep -qF "enterprise security" "$work/s1-corp/say.log" ||
  fail "an 802.1x network must SAY why it cannot be joined here" "$(cat "$work/s1-corp/say.log")"
LC_ALL=C grep -qF 'connect' "$work/s1-corp/iwctl.log" &&
  fail "an 802.1x network must never be handed to iwctl connect with a passphrase"
LC_ALL=C grep -qF "input" "$work/s1-corp/gum.log" &&
  fail "an 802.1x network must never raise a passphrase prompt that cannot possibly work"
pass "an enterprise (802.1x) network is explained and skipped, never given a doomed passphrase prompt"

# --- the hostile SSID, end to end: what iwctl gets vs what the screen shows ---
printf 'pw\n' >"$work/pass-hostile.q"
printf 'wlan0 UP 10.0.0.5/24\n' >"$work/ip-hostile"
S1_INPUT_QUEUE="$work/pass-hostile.q" S1_IP_OUTPUT="$work/ip-hostile" \
  s1_run hostile "Evil?Bar"
[[ $s1_rc -eq 0 ]] || fail "a hostile-named open network must still be joinable" "rc=$s1_rc"
LC_ALL=C grep -qF 'connect Evil|Bar' "$work/s1-hostile/iwctl.log" ||
  fail "🔴 the RAW SSID must reach iwctl -- joining the sanitised display text would fail forever with no clue why" \
       "$(cat "$work/s1-hostile/iwctl.log")"
LC_ALL=C grep -qF 'Evil|Bar' "$work/s1-hostile/say.log" &&
  fail "the raw '|' must never reach the screen"
LC_ALL=C grep -qxF "ssid=Evil?Bar" "$work/s1-hostile/$DECK_NET_OUTCOME_FILE" ||
  fail "the outcome record must carry the sanitised SSID" "$(s1_out hostile)"
# 🔴 MUTATION-FOUND GAP, closed. DECK_WIFI_SSID is the ONE value S1 hands
# to S5, and deck_form_summary_rows prints it straight into a gum table --
# so a raw SSID here is an ANSI-injection sink two screens later, on the
# screen nobody would think to look at. Setting it to $ssid instead of
# $safe_ssid survived every other assertion in this file.
[[ $(cat "$work/s1-hostile/wifi-ssid") == 'Evil?Bar' ]] ||
  fail "DECK_WIFI_SSID (the only value S1 hands to S5) must be the SANITISED SSID" \
       "got: $(cat "$work/s1-hostile/wifi-ssid")"
# ...and that value must survive into the summary table itself.
DECK_WIFI_SSID=$(cat "$work/s1-hostile/wifi-ssid")
username=deck; password=hunter22; hostname=steamdeck
timezone=Europe/Copenhagen; disk=/dev/nvme0n1; encrypt_installation=false
LC_ALL=C grep -qF "Wi-Fi,Evil?Bar" <<<"$(DECK_LSBLK_BIN=true deck_form_summary_rows)" ||
  fail "the sanitised SSID must reach S5's summary row"
unset DECK_WIFI_SSID
unset S1_INPUT_QUEUE S1_IP_OUTPUT
pass "a hostile SSID reaches iwctl raw, the screen sanitised, and S5 sanitised -- all three, in one run"

# --- an empty passphrase must never be submitted as an open-network join ---
# Without the empty check, gum returning nothing (the OSK closed with
# nothing typed) falls through to `iwctl station … connect` with NO
# --passphrase, i.e. a secured network joined as if it were open: a
# guaranteed failure reported as "wrong password".
printf '<EMPTY>\nC0rrect horse!\n' >"$work/pass-empty.q"
printf 'wlan0 UP 10.0.0.7/24\n' >"$work/ip-empty"
S1_INPUT_QUEUE="$work/pass-empty.q" S1_IP_OUTPUT="$work/ip-empty" \
  s1_run emptypw $'\360\237\224\222 My Home Network'
[[ $s1_rc -eq 0 ]] || fail "an empty passphrase must re-prompt, then succeed on the real one" "rc=$s1_rc"
LC_ALL=C grep -qF "No password entered" "$work/s1-emptypw/say.log" ||
  fail "an empty passphrase must be reported and re-prompted, not submitted" "$(s1_say emptypw)"
connects=$(LC_ALL=C command grep -c 'connect' "$work/s1-emptypw/iwctl.log")
[[ $connects -eq 1 ]] ||
  fail "an empty passphrase must produce NO iwctl connect at all -- a secured network joined without --passphrase is a guaranteed failure blamed on the user" \
       "$(cat "$work/s1-emptypw/iwctl.log")"
unset S1_INPUT_QUEUE S1_IP_OUTPUT
pass "an empty passphrase re-prompts instead of being submitted as an open-network join"
# ===========================================================================
# S8: Failure -- ITS ASSERTIONS WERE DELETED WITH THE CODE, ON PURPOSE
# ===========================================================================
#
# This suite used to prove a failure menu that could never run: upstream's
# `failure_menu` is defined at `omarchy-install-dashboard:609` and called at
# `:735`, in a process that never sources deck-form.sh. Worse, the rows were
# wrong -- ours offered "Retry install", which the dashboard cannot perform,
# and omitted upstream's "Upload log for support".
#
# ⚠️ **Nine assertions passed against it, including a mutation-tested
# cancel-fallback check.** They were rigorous about the wrong thing, which is
# the failure mode T4-screen-spec.md §6.4 names: a test that is green while
# asserting nothing a user could reach. The override-name contract above now
# makes this class of mistake impossible to reintroduce silently -- it fails
# if this file defines a name upstream's configurator never calls.
#
# S8 now lives in `src/deck-dashboard.sh` and is proven by
# `test/unit/test-deck-dashboard.sh`, against upstream's real menu.
# ===========================================================================
# The upstream-helper stubs and the fake `gum` USED to be defined here.
# They moved to the top of this file (right after the `source`) on
# 2026-08-12, because `greeter` now runs S1 and S1 calls `step`/`say`, so
# the S0 test -- which is ABOVE this point -- needs them. Nothing else about
# them changed; see their comment block up there.
# ===========================================================================

# ===========================================================================
# S2: Region (timezone)
# ===========================================================================

echo "--- S2 area/city derivation ------------------------------------------------"

cat >"$work/tz.list" <<'EOF'
Africa/Abidjan
America/New_York
America/Argentina/Buenos_Aires
Asia/Tokyo
Atlantic/Reykjavik
Australia/Sydney
Europe/Copenhagen
Europe/London
Indian/Maldives
Pacific/Auckland
UTC
EOF

areas=$(deck_form_tz_areas "$work/tz.list")
for a in Africa America Asia Atlantic Australia Europe Indian Pacific UTC; do
  LC_ALL=C grep -qxF "$a" <<<"$areas" || fail "tz_areas must include area '$a'" "$areas"
done
n_areas=$(printf '%s\n' "$areas" | LC_ALL=C command grep -c .)
[[ $n_areas -eq 9 ]] || fail "tz_areas must derive EXACTLY the areas present in the fixture, no more" "got $n_areas: $areas"
pass "tz_areas derives every area present in the fixture, and nothing else"

cities_europe=$(deck_form_tz_cities_for_area "$work/tz.list" Europe)
LC_ALL=C grep -qxF "Copenhagen" <<<"$cities_europe" || fail "Copenhagen must belong to Europe" "$cities_europe"
LC_ALL=C grep -qxF "London" <<<"$cities_europe" || fail "London must belong to Europe" "$cities_europe"
if LC_ALL=C grep -qxF "Tokyo" <<<"$cities_europe"; then
  fail "Tokyo must NOT belong to Europe -- a city from another area leaked in"
fi
pass "tz_cities_for_area returns exactly the cities that belong to the given area"

cities_america=$(deck_form_tz_cities_for_area "$work/tz.list" America)
LC_ALL=C grep -qxF "Argentina/Buenos_Aires" <<<"$cities_america" ||
  fail "a three-level zone's remainder (Argentina/Buenos_Aires) must survive as one 'city' entry" "$cities_america"
pass "tz_cities_for_area keeps a three-level zone's remainder intact as a single city entry"

cities_utc=$(deck_form_tz_cities_for_area "$work/tz.list" UTC)
[[ $cities_utc == UTC ]] || fail "UTC must be reachable as its own single-entry pseudo-area" "got: $cities_utc"
pass "UTC is reachable as its own area with a single 'UTC' city entry"

[[ $(deck_form_tz_full Europe Copenhagen) == Europe/Copenhagen ]] || fail "tz_full must rejoin area/city"
[[ $(deck_form_tz_full UTC UTC) == UTC ]] || fail "tz_full must collapse UTC/UTC back to the bare zone name 'UTC'"
pass "tz_full rejoins area/city, and collapses UTC/UTC to the bare 'UTC' zone name"

[[ $(deck_form_tz_default_area) == Europe ]] || fail "tz_default_area must be the spec's stated fallback, Europe"
pass "tz_default_area is 'Europe' -- the visible, stated no-guess default"

echo "--- S2 geo-guess sanitisation ------------------------------------------------"

got=$(deck_form_tz_sanitize_guess "Europe/Copenhagen") || fail "a well-formed guess must be accepted"
[[ $got == Europe/Copenhagen ]] || fail "sanitize_guess must return the guess unchanged when valid" "got: $got"
pass "a well-formed Area/City guess is accepted unchanged"

got=$(deck_form_tz_sanitize_guess "  Europe/Copenhagen  ") || fail "a guess with surrounding whitespace must still be accepted (trimmed)"
[[ $got == Europe/Copenhagen ]] || fail "sanitize_guess must trim surrounding whitespace" "got: $got"
pass "sanitize_guess trims surrounding whitespace before validating"

if deck_form_tz_sanitize_guess "not a real place" >/dev/null; then
  fail "sanitize_guess must reject text with no Area/City shape at all"
fi
pass "sanitize_guess rejects text with no Area/City shape"

if deck_form_tz_sanitize_guess $'Europe/Copenhagen\x1b[31m' >/dev/null; then
  fail "sanitize_guess must reject a guess carrying a raw ANSI escape byte (network-derived text, §4 S1's own hostile-input reasoning)"
fi
pass "sanitize_guess rejects a guess with an embedded ANSI escape"

# The spec's own pattern (copied verbatim -- see this file's own comment)
# has no allowance for a second slash, so a real three-level IANA zone is
# REJECTED as a guess -- a known, spec-inherited limitation, asserted here
# so a future change to the pattern is a deliberate, visible decision.
if deck_form_tz_sanitize_guess "America/Argentina/Buenos_Aires" >/dev/null; then
  fail "sanitize_guess must reject a three-level zone per the spec's own two-segment-only pattern (known limitation, asserted not assumed)"
fi
pass "sanitize_guess rejects a three-level zone, per the spec's own literal pattern (a documented, not accidental, limitation)"

[[ $(deck_form_tz_guess_area "Europe/Copenhagen") == Europe ]] || fail "guess_area must return the first segment"
[[ $(deck_form_tz_guess_city "Europe/Copenhagen") == Copenhagen ]] || fail "guess_city must return everything after the first slash"
pass "tz_guess_area / tz_guess_city split a valid guess correctly"

echo "--- S2 omarchy_prompt_timezone: the real override name, and its no-network fallback ---"

declare -f omarchy_prompt_timezone >/dev/null ||
  fail "omarchy_prompt_timezone must be defined -- it is the name upstream's user_form actually calls (configurator line 260, read this session)"
pass "the timezone override uses the name upstream's configurator calls"

# The empty-list fallback returns BEFORE any gum call, so it is safely
# exercisable at [U] without a live terminal -- point DECK_TZ_LIST_CMD_OVERRIDE
# at a command that produces no output, standing in for `timedatectl
# list-timezones` returning nothing (§4 S2: "should be impossible ... fall
# back to UTC and say so").
unset timezone 2>/dev/null || true
# NOT run inside $(...): a command substitution forks a subshell, and the
# whole point of this assertion is that `timezone` (a GLOBAL upstream reads
# back later) survives in THIS shell -- a subshell's assignment would vanish
# on return and this test would falsely pass against its own stale/unset
# value instead of what the function actually did.
DECK_TZ_LIST_CMD_OVERRIDE=true omarchy_prompt_timezone 2>"$work/tz-warnings"
rc=$?
[[ $rc -eq 0 ]] || fail "omarchy_prompt_timezone must succeed (return 0) on the empty-list fallback" "rc=$rc"
[[ $timezone == UTC ]] || fail "omarchy_prompt_timezone must set timezone=UTC when the timezone list is empty" "got: ${timezone:-unset}"
LC_ALL=C grep -qF "falling back to" "$work/tz-warnings" ||
  fail "omarchy_prompt_timezone must SAY it fell back to UTC, not go silent"
pass "omarchy_prompt_timezone falls back to UTC and says so, when the timezone list comes back empty -- no gum call needed to prove it"

# ===========================================================================
# S4: Disk
# ===========================================================================

echo "--- S4 disk eligibility filter (lsblk fixtures) -----------------------------"

cat >"$work/lsblk.disks" <<'EOF'
/dev/nvme0n1 disk 0
/dev/sda disk 1
/dev/mmcblk0 disk 0
/dev/loop0 loop 0
EOF

got=$(deck_form_disk_list "$work/lsblk.disks") || fail "disk_list must succeed when eligible disks exist"
LC_ALL=C grep -qxF "/dev/nvme0n1" <<<"$got" || fail "an internal NVMe disk must be kept" "$got"
LC_ALL=C grep -qxF "/dev/mmcblk0" <<<"$got" || fail "an internal eMMC disk must be kept (excluded by RM, never by the mmcblk* NAME pattern -- §3 deviation 5)" "$got"
if LC_ALL=C grep -qxF "/dev/sda" <<<"$got"; then
  fail "a removable disk (RM=1) must be excluded"
fi
if LC_ALL=C grep -qxF "/dev/loop0" <<<"$got"; then
  fail "a non-disk TYPE (loop) must be excluded"
fi
pass "disk_list keeps internal NVMe and eMMC, excludes removable (by RM, not name) and non-disk types"

got=$(deck_form_disk_list "$work/lsblk.disks" "/dev/nvme0n1") || fail "disk_list must still succeed with one disk excluded and one remaining"
[[ $got == /dev/mmcblk0 ]] || fail "the boot/install medium must be excluded by exact NAME match" "got: $got"
pass "disk_list excludes the boot/install medium by exact device-name match"

cat >"$work/lsblk.none.disks" <<'EOF'
/dev/sda disk 1
/dev/mmcblk1 disk 1
EOF
out=$(deck_form_disk_list "$work/lsblk.none.disks" 2>&1) && fail "disk_list must return nonzero when nothing is eligible"
LC_ALL=C grep -qF "no eligible install disk" <<<"$out" || fail "disk_list must SAY why it found nothing, not go silent" "got: $out"
pass "disk_list fails loudly (nonzero, says why) rather than returning a silently empty list -- §4 S4's own verified-by row"

echo "--- S4 picker auto-skip with exactly one eligible disk -----------------------"

got=$(deck_form_disk_autoselect $'/dev/nvme0n1') || fail "autoselect must succeed with exactly one device"
[[ $got == /dev/nvme0n1 ]] || fail "autoselect must print the sole device" "got: $got"
pass "autoselect succeeds and prints the device when exactly one is eligible"

if deck_form_disk_autoselect $'/dev/nvme0n1\n/dev/mmcblk0' >/dev/null; then
  fail "autoselect must NOT auto-pick when more than one disk is eligible -- a picker is required"
fi
pass "autoselect declines (a picker is needed) when more than one disk is eligible"

if deck_form_disk_autoselect "" >/dev/null; then
  fail "autoselect must not succeed on an empty list"
fi
pass "autoselect declines on an empty list"

echo "--- S4 disk label formatting -------------------------------------------------"

mkdir -p "$work/bin-fakelsblk"
cat >"$work/bin-fakelsblk/lsblk" <<'EOF'
#!/usr/bin/env bash
# args: -dno FIELD DEVICE
field=$2
case "$field" in
  SIZE)   echo "512G" ;;
  VENDOR) echo "Sandisk  " ;;
  MODEL)  echo "SND512G  " ;;
esac
EOF
chmod +x "$work/bin-fakelsblk/lsblk"

got=$(DECK_LSBLK_BIN="$work/bin-fakelsblk/lsblk" deck_form_disk_label /dev/nvme0n1)
[[ $got == "Sandisk SND512G (512G)" ]] || fail "disk_label must combine vendor+model+size" "got: $got"
pass "disk_label combines vendor, model and size"

cat >"$work/bin-fakelsblk/lsblk" <<'EOF'
#!/usr/bin/env bash
field=$2
case "$field" in
  SIZE) echo "256G" ;;
  *) : ;;
esac
EOF
got=$(DECK_LSBLK_BIN="$work/bin-fakelsblk/lsblk" deck_form_disk_label /dev/sda)
[[ $got == "/dev/sda (256G)" ]] || fail "disk_label must fall back to the bare device path when lsblk has no vendor/model" "got: $got"
pass "disk_label falls back to the device path when vendor/model are both empty"

# ⚠️ MUTATION-FOUND GAP, closed: the two cases above (vendor+model both
# present, and both absent) never exercise the MODEL-ONLY or VENDOR-ONLY
# branches individually -- a mutation that swapped which of $model/$vendor
# each branch assigns left every earlier assertion here green. Real disks
# regularly report only one of the two (a no-name/generic vendor field is
# common on internal eMMC).
cat >"$work/bin-fakelsblk/lsblk" <<'EOF'
#!/usr/bin/env bash
field=$2
case "$field" in
  SIZE)  echo "64G" ;;
  MODEL) echo "eMMC-Card" ;;
  *) : ;;
esac
EOF
got=$(DECK_LSBLK_BIN="$work/bin-fakelsblk/lsblk" deck_form_disk_label /dev/mmcblk0)
[[ $got == "eMMC-Card (64G)" ]] || fail "disk_label must use MODEL when VENDOR is empty" "got: $got"
pass "disk_label uses the model alone when vendor is empty"

cat >"$work/bin-fakelsblk/lsblk" <<'EOF'
#!/usr/bin/env bash
field=$2
case "$field" in
  SIZE)   echo "1T" ;;
  VENDOR) echo "Acme" ;;
  *) : ;;
esac
EOF
got=$(DECK_LSBLK_BIN="$work/bin-fakelsblk/lsblk" deck_form_disk_label /dev/nvme1n1)
[[ $got == "Acme (1T)" ]] || fail "disk_label must use VENDOR when MODEL is empty" "got: $got"
pass "disk_label uses the vendor alone when model is empty"

echo "--- S4 the mutation-named targets: default cursor and encryption constant ----"

[[ $(deck_form_disk_encryption_mode) == false ]] ||
  fail "deck_form_disk_encryption_mode must always print 'false' -- T4-screen-spec.md §6.5's own named mutation target"
pass "deck_form_disk_encryption_mode is unconditionally 'false'"

[[ $DECK_DISK_CONFIRM_DEFAULT == false ]] ||
  fail "DECK_DISK_CONFIRM_DEFAULT must be 'false' -- the cursor must default to No (§6.5's other named mutation target)"
pass "DECK_DISK_CONFIRM_DEFAULT is 'false' -- the confirm screen's cursor defaults to No"

body=$(declare -f confirm_disk_overwrite)
LC_ALL=C grep -qF 'DECK_DISK_CONFIRM_DEFAULT' <<<"$body" ||
  fail "confirm_disk_overwrite must use the named DECK_DISK_CONFIRM_DEFAULT constant, not a hardcoded --default value"
LC_ALL=C grep -qF 'deck_form_disk_encryption_mode' <<<"$body" ||
  fail "confirm_disk_overwrite must set encryption via the named deck_form_disk_encryption_mode function, not inline"
if LC_ALL=C grep -qF '130' <<<"$body"; then
  fail "confirm_disk_overwrite must NOT contain a Ctrl+C (130) branch -- there is no encryption toggle on this hardware, ever (§2.2 item 1)"
fi
pass "confirm_disk_overwrite is wired to the named constant/function (not hardcoded) and carries no Ctrl+C toggle branch"

echo "--- S4 confirm_disk_overwrite: full behaviour, with a faked gum --------------"

disk=/dev/nvme0n1
PATH="$work/bin-fakelsblk:$work/bin-fakegum:$PATH" \
DECK_LSBLK_BIN="$work/bin-fakelsblk/lsblk" \
FAKE_GUM_CONFIRM_RC=0 \
  confirm_disk_overwrite >/dev/null
rc=$?
[[ $rc -eq 0 ]] || fail "confirm_disk_overwrite must return 0 when gum confirm reports the affirmative" "rc=$rc"
[[ $encrypt_installation == false ]] || fail "encrypt_installation must be false after an AFFIRMATIVE confirm" "got: $encrypt_installation"
pass "confirm_disk_overwrite: affirmative -> returns 0, encrypt_installation is false"

# ⚠️ MUTATION-FOUND GAP, closed: `encrypt_installation` is a GLOBAL that
# the previous (affirmative) case already set to "false" -- if this test
# left it alone, a mutation that only sets it inside the affirmative branch
# (never on decline) would still see "false" here, left over from the prior
# case, and PASS for the wrong reason. Poisoned to a value the correct
# behaviour can never produce ("unset") before the call, so only the
# function itself setting it, on THIS call, on THIS path, can make the
# assertion below true.
encrypt_installation=poisoned-by-test-do-not-trust
set +e
PATH="$work/bin-fakelsblk:$work/bin-fakegum:$PATH" \
DECK_LSBLK_BIN="$work/bin-fakelsblk/lsblk" \
FAKE_GUM_CONFIRM_RC=1 \
  confirm_disk_overwrite >/dev/null
rc=$?
set -e
[[ $rc -eq 1 ]] || fail "confirm_disk_overwrite must return nonzero when gum confirm reports the negative (declined)" "rc=$rc"
[[ $encrypt_installation == false ]] || fail "encrypt_installation must STILL be false even on the decline path -- it is a constant, not something only set on the happy path" "got: $encrypt_installation"
pass "confirm_disk_overwrite: declined -> returns nonzero, and encrypt_installation is STILL unconditionally false"

echo "--- S4 requires_full_disk_install: always suppresses the free-space picker ---"

requires_full_disk_install
rc=$?
[[ $rc -eq 0 ]] || fail "requires_full_disk_install must always return 0 (true) -- the free-space install mode is suppressed unconditionally (§3 deviation 5)" "rc=$rc"
pass "requires_full_disk_install unconditionally reports 'full disk only', suppressing upstream's install_mode_form"

echo "--- S4 dead-end menu (no eligible disk) ---------------------------------------"

menu=$(deck_form_disk_dead_end_items)
LC_ALL=C grep -qF "Reboot" <<<"$menu" || fail "dead-end menu must offer Reboot"
LC_ALL=C grep -qF "Power off" <<<"$menu" || fail "dead-end menu must offer Power off"
if LC_ALL=C grep -qiF "shell" <<<"$menu"; then
  fail "dead-end menu must never offer a shell"
fi
pass "the dead-end menu offers only Reboot and Power off, never a shell"

[[ $(deck_form_disk_dead_end_action_for "") == redraw ]] || fail "a cancelled dead-end choose must redraw, never act"
[[ $(deck_form_disk_dead_end_action_for "Reboot") == reboot ]] || fail "'Reboot' must map to reboot"
[[ $(deck_form_disk_dead_end_action_for "Power off") == poweroff ]] || fail "'Power off' must map to poweroff"
[[ $(deck_form_disk_dead_end_action_for "anything else") == redraw ]] || fail "an unrecognised choice must redraw, never guess"
pass "dead-end action mapping: cancel/unrecognised redraw, never act; Reboot/Power off map correctly"

echo "--- S4 disk_form: auto-skips the picker with exactly one eligible disk -------"

unset disk 2>/dev/null || true
# This fake lsblk answers BOTH the `-dpno NAME,TYPE,RM` query disk_form
# itself makes (one eligible disk, one removable) AND the `-dno SIZE`-style
# query deck_form_disk_label makes internally (via get_disk_info, not
# exercised on the auto-select path, but kept consistent).
cat >"$work/bin-fakelsblk/lsblk" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "-dpno" && "$2" == "NAME,TYPE,RM" ]]; then
  printf '/dev/nvme0n1 disk 0\n/dev/sda disk 1\n'
  exit 0
fi
field=$3
case "$field" in
  SIZE) echo "512G" ;;
  *) : ;;
esac
EOF
: >"$work/gum.log"
DECK_TEST_ROOT_DISK="" \
DECK_LSBLK_BIN="$work/bin-fakelsblk/lsblk" \
FAKE_GUM_LOG="$work/gum.log" \
PATH="$work/bin-fakelsblk:$work/bin-fakegum:$PATH" \
  disk_form
[[ $disk == /dev/nvme0n1 ]] || fail "disk_form must auto-select the sole eligible disk without showing a picker" "got: ${disk:-unset}"
if LC_ALL=C grep -qF "choose" "$work/gum.log"; then
  fail "disk_form must not have invoked the picker (gum choose) when only one disk was eligible" "$(cat "$work/gum.log")"
fi
pass "disk_form auto-selects the sole eligible disk, skipping the picker entirely"

echo "--- S4 disk_form: shows a picker with more than one eligible disk ------------"

cat >"$work/bin-fakelsblk/lsblk" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "-dpno" && "$2" == "NAME,TYPE,RM" ]]; then
  printf '/dev/nvme0n1 disk 0\n/dev/mmcblk0 disk 0\n'
  exit 0
fi
field=$3
case "$field" in
  SIZE) echo "512G" ;;
  *) : ;;
esac
EOF
unset disk 2>/dev/null || true
: >"$work/gum.log"
DECK_TEST_ROOT_DISK="" \
DECK_LSBLK_BIN="$work/bin-fakelsblk/lsblk" \
FAKE_GUM_LOG="$work/gum.log" \
FAKE_GUM_CHOOSE_OUTPUT="/dev/mmcblk0" \
PATH="$work/bin-fakelsblk:$work/bin-fakegum:$PATH" \
  disk_form
[[ $disk == /dev/mmcblk0 ]] || fail "disk_form must set 'disk' to whatever the (faked) picker returned" "got: ${disk:-unset}"
LC_ALL=C grep -qF "choose" "$work/gum.log" || fail "disk_form must have actually invoked a picker when two disks were eligible" "$(cat "$work/gum.log")"
pass "disk_form shows a picker (and honours its answer) when more than one disk is eligible"

echo "--- S4 disk_form: zero eligible disks -> dead-end, NEVER falls through to a picker ---"

# ⚠️ MUTATION-FOUND GAP, closed: neither test above ever drives disk_form
# with ZERO eligible disks. A mutation that drops the
# `if ! eligible=$(deck_form_disk_list ...); then ... fi` guard entirely
# (falling through with eligible="" instead of routing to the dead-end
# screen) survived every earlier assertion, because none of them exercise
# this path at all -- it would silently show an EMPTY gum choose picker
# instead of the "Reboot / Power off, never a shell" screen §4 S4 requires.
#
# The real dead-end screen (deck_form_disk_dead_end) is a `while true`
# loop -- same [V]-only precedent as S8's failure_menu, not driven live
# here. Shadowed with a logging stub so THIS test proves disk_form CALLS
# it, without needing to survive dead_end's own infinite loop.
: >"$work/dead-end.log"
deck_form_disk_dead_end() { printf 'DEAD_END_CALLED\n' >>"$work/dead-end.log"; return 0; }

cat >"$work/bin-fakelsblk/lsblk" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "-dpno" && "$2" == "NAME,TYPE,RM" ]]; then
  printf '/dev/sda disk 1\n'   # removable only -- nothing eligible
  exit 0
fi
exit 0
EOF
unset disk 2>/dev/null || true
: >"$work/gum.log"
DECK_TEST_ROOT_DISK="" \
DECK_LSBLK_BIN="$work/bin-fakelsblk/lsblk" \
FAKE_GUM_LOG="$work/gum.log" \
PATH="$work/bin-fakelsblk:$work/bin-fakegum:$PATH" \
  disk_form || true
LC_ALL=C grep -qF "DEAD_END_CALLED" "$work/dead-end.log" ||
  fail "disk_form must call the dead-end screen when no disk is eligible"
if LC_ALL=C grep -qF "choose" "$work/gum.log"; then
  fail "disk_form must NEVER show the picker when no disk is eligible -- it must reach the dead end, not silently fall through to an empty gum choose"
fi
[[ -z ${disk:-} ]] || fail "disk_form must not set 'disk' to anything when no disk was eligible" "got: $disk"
pass "disk_form calls the dead-end screen (never falls through to an empty picker) when no disk is eligible"

echo "--- S4 disk_form: the boot/install medium is actually excluded end-to-end ----"

# ⚠️ MUTATION-FOUND GAP, closed: every earlier disk_form test above uses
# DECK_TEST_ROOT_DISK="" (the get_root_disk stub returns nothing), so a
# mutation that stopped wiring exclude_disk into deck_form_disk_list at all
# (e.g. `exclude_disk=""` hardcoded, ignoring get_root_disk's answer)
# survived every one of them -- they never gave it a real value to drop.
# Two disks are eligible by RM alone; get_root_disk is stubbed to name ONE
# of them as the boot medium, so only exclusion (not the RM filter, already
# proven above) can be what narrows it down to a single auto-select.
cat >"$work/bin-fakelsblk/lsblk" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "-dpno" && "$2" == "NAME,TYPE,RM" ]]; then
  printf '/dev/nvme0n1 disk 0\n/dev/mmcblk0 disk 0\n'
  exit 0
fi
field=$3
case "$field" in
  SIZE) echo "512G" ;;
  *) : ;;
esac
EOF
unset disk 2>/dev/null || true
: >"$work/gum.log"
DECK_TEST_ROOT_DISK="/dev/nvme0n1" \
DECK_LSBLK_BIN="$work/bin-fakelsblk/lsblk" \
FAKE_GUM_LOG="$work/gum.log" \
PATH="$work/bin-fakelsblk:$work/bin-fakegum:$PATH" \
  disk_form
[[ $disk == /dev/mmcblk0 ]] || fail "disk_form must exclude the boot/install medium (get_root_disk's answer), leaving only the other disk to auto-select" "got: ${disk:-unset}"
if LC_ALL=C grep -qF "choose" "$work/gum.log"; then
  fail "with the boot medium excluded, only ONE disk should remain -- the picker must not have been shown"
fi
pass "disk_form actually excludes the boot/install medium (not just deck_form_disk_list in isolation) -- both eligible disks pass RM, only exclusion narrows it to one"

# ===========================================================================
# S5: Summary
# ===========================================================================

echo "--- S5 summary rows are built from the SAME globals the artefact writers read"

username=deck
password=hunter22
hostname=steamdeck
timezone=Europe/Copenhagen
disk=/dev/nvme0n1
encrypt_installation=false
keyboard=latam
unset DECK_WIFI_SSID 2>/dev/null || true

rows=$(DECK_LSBLK_BIN="$work/bin-fakelsblk/lsblk" deck_form_summary_rows)
LC_ALL=C grep -qF "Username,deck" <<<"$rows" || fail "summary must show the real username" "$rows"
LC_ALL=C grep -qF "Password,********" <<<"$rows" || fail "summary must mask the password to its own length in asterisks" "$rows"
LC_ALL=C grep -qF "Hostname,steamdeck" <<<"$rows" || fail "summary must show the real hostname" "$rows"
LC_ALL=C grep -qF "Timezone,Europe/Copenhagen" <<<"$rows" || fail "summary must show the real timezone" "$rows"
LC_ALL=C grep -qF "Wi-Fi,Not connected" <<<"$rows" || fail "summary must show 'Not connected' when DECK_WIFI_SSID is unset" "$rows"
LC_ALL=C grep -qF "Encryption,Off" <<<"$rows" || fail "summary must show Encryption: Off when encrypt_installation is false" "$rows"
LC_ALL=C grep -qF "Desktop,Omarchy" <<<"$rows" || fail "summary must show Desktop: Omarchy"
LC_ALL=C grep -qF "Boot,Gaming Mode" <<<"$rows" || fail "summary must show Boot: Gaming Mode"
pass "summary rows reflect username/password-mask/hostname/timezone/Wi-Fi/encryption/desktop/boot"

# §5.20a. The layout is a user preference again (it is no longer forced to a
# constant), so S5 -- "one recap before anything destructive runs" -- must
# show the value that will actually be installed. §4 S5's stated property is
# that every row is built from the same global the artefact writer reads;
# `keyboard` is exactly what upstream interpolates into `"kb_layout"`, so it
# is asserted here as a PAIR (change the global, the row must follow) rather
# than against a literal that could drift into a hardcoded string.
LC_ALL=C grep -qF "Keyboard,latam" <<<"$rows" ||
  fail "summary must show the keyboard layout that will be installed (§5.20a: it is the user's pick, not a constant)" "$rows"
keyboard=us
rows=$(DECK_LSBLK_BIN="$work/bin-fakelsblk/lsblk" deck_form_summary_rows)
LC_ALL=C grep -qF "Keyboard,us" <<<"$rows" ||
  fail "the Keyboard row must track \$keyboard -- the same global write_user_files reads -- not a hardcoded value" "$rows"
keyboard=latam
pass "S5 shows the keyboard layout, tracking the same \$keyboard upstream writes into kb_layout"

DECK_WIFI_SSID="MyHomeNetwork"
rows=$(DECK_LSBLK_BIN="$work/bin-fakelsblk/lsblk" deck_form_summary_rows)
LC_ALL=C grep -qF "Wi-Fi,MyHomeNetwork" <<<"$rows" || fail "summary must show the connected SSID when DECK_WIFI_SSID is set" "$rows"
unset DECK_WIFI_SSID

encrypt_installation=true
rows=$(DECK_LSBLK_BIN="$work/bin-fakelsblk/lsblk" deck_form_summary_rows)
LC_ALL=C grep -qF "Encryption,On" <<<"$rows" || fail "summary must show Encryption: On if encrypt_installation is ever true (defense in depth, even though S4 forces it false)" "$rows"
encrypt_installation=false
pass "summary reflects DECK_WIFI_SSID when set, and the real encrypt_installation value either way (not a hardcoded 'Off' string)"

echo "--- S5 deck_final_summary: the exact name patch P1 hunk 2 calls --------------"

declare -f deck_final_summary >/dev/null ||
  fail "deck_final_summary must be defined -- it is the exact new name T4-screen-spec.md §1.2 patch P1 hunk 2 calls directly"
pass "deck_final_summary is defined under the exact name the spec's own patch calls"

: >"$work/gum.log"
FAKE_GUM_LOG="$work/gum.log" \
FAKE_GUM_CONFIRM_RC=0 \
DECK_LSBLK_BIN="$work/bin-fakelsblk/lsblk" \
PATH="$work/bin-fakegum:$PATH" \
  deck_final_summary >/dev/null
rc=$?
[[ $rc -eq 0 ]] || fail "deck_final_summary must return 0 when the final confirm is affirmative" "rc=$rc"
LC_ALL=C grep -qF "table" "$work/gum.log" || fail "deck_final_summary must render the summary via gum table" "$(cat "$work/gum.log")"
LC_ALL=C grep -qF "confirm" "$work/gum.log" || fail "deck_final_summary must ask for a final confirm"
pass "deck_final_summary renders the table and returns 0 on an affirmative confirm"

# §5: "the consequences, stated once, on S1's skip AND AGAIN ON S5." The
# S1 half is asserted in the S1 block; this is the S5 half, and it must be
# keyed on the same global the Wi-Fi row is built from, or the table and
# the sentence can disagree.
unset DECK_WIFI_SSID 2>/dev/null || true
: >"$work/s5-say.log"
FAKE_GUM_CONFIRM_RC=0 DECK_TEST_SAY_LOG="$work/s5-say.log" \
DECK_LSBLK_BIN="$work/bin-fakelsblk/lsblk" PATH="$work/bin-fakegum:$PATH" \
  deck_final_summary >/dev/null
LC_ALL=C grep -qF "audio DSP firmware and Steam are not downloaded" "$work/s5-say.log" ||
  fail "§5: S5 must restate the offline consequence when no network was joined" "$(cat "$work/s5-say.log")"

DECK_WIFI_SSID="MyHomeNetwork"
: >"$work/s5-say2.log"
FAKE_GUM_CONFIRM_RC=0 DECK_TEST_SAY_LOG="$work/s5-say2.log" \
DECK_LSBLK_BIN="$work/bin-fakelsblk/lsblk" PATH="$work/bin-fakegum:$PATH" \
  deck_final_summary >/dev/null
LC_ALL=C grep -qF "audio DSP firmware and Steam are not downloaded" "$work/s5-say2.log" &&
  fail "S5 must NOT show the offline consequence when a network WAS joined -- a warning that always fires is noise, not information"
unset DECK_WIFI_SSID
pass "S5 restates §5's offline consequence exactly when no network was joined, and not otherwise"

echo "========================================================================"
echo "ALL deck-form.sh TESTS PASSED"
