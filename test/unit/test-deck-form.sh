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
  confirm)
    # A queue, for exactly the reason the choose queue below has one: P33 L1
    # puts a confirm INSIDE S1's loop, so a fake that answers "no" forever
    # spins the screen forever and the failure mode is a killed suite that
    # reports nothing. One scripted exit status per call; when it runs dry the
    # answer falls back to FAKE_GUM_CONFIRM_RC and a marker is logged, so a
    # test that relied on the queue can assert it was never over-run.
    if [[ -n ${FAKE_GUM_CONFIRM_QUEUE:-} ]]; then
      if line=$(pop_queue "$FAKE_GUM_CONFIRM_QUEUE"); then
        exit "$line"
      fi
      printf 'CONFIRM-QUEUE-EXHAUSTED\n' >>"${FAKE_GUM_LOG:-/dev/null}"
    fi
    exit "${FAKE_GUM_CONFIRM_RC:-0}"
    ;;
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
# drift NOTHING here goes red on its own -- every prompt just waits out
# DECK_OSK_BIND_DEADLINE and degrades, on a real ISO, silently as far as this
# suite is concerned. Both suites check it, so whichever one the next editor
# runs fails.
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

echo "--- P33 A2: the bind deadline, and a warning that must not be false ----"

# --- the cross-file gate on the NUMBER --------------------------------------
#
# Same discipline as DECK_OSK_BOUND_MARKER above, and for a sharper reason.
# docs/PROGRESS.md §5.34 D2: the deadline was 5, chosen by nobody's
# measurement, while the mapper's own `pick_device` will sit for up to
# NO_PAD_GRACE_SECONDS with no pad present before giving up. Any deadline
# below that can expire on a mapper that is still deliberately waiting and is
# about to succeed. Read the mapper's number rather than restating it here, so
# a change on that side turns this red instead of silently re-arming D2.
mapper_grace=$(sed -n 's/^NO_PAD_GRACE_SECONDS = \([0-9.]*\)$/\1/p' "$REPO_ROOT/src/deck-input-mapper.py")
[[ -n $mapper_grace ]] ||
  fail "could not find 'NO_PAD_GRACE_SECONDS = ' in src/deck-input-mapper.py -- this cross-check is broken, not the code"
awk -v d="$DECK_OSK_BIND_DEADLINE" -v g="$mapper_grace" 'BEGIN { exit !(d >= g) }' ||
  fail "DECK_OSK_BIND_DEADLINE ($DECK_OSK_BIND_DEADLINE s) is shorter than the mapper's own NO_PAD_GRACE_SECONDS ($mapper_grace s). deck-form.sh would abandon a mapper that is still, by its own design, waiting for a pad to enumerate -- which is docs/PROGRESS.md §5.34 D2 exactly."
pass "DECK_OSK_BIND_DEADLINE ($DECK_OSK_BIND_DEADLINE s) is at least the mapper's own NO_PAD_GRACE_SECONDS ($mapper_grace s)"

[[ $DECK_OSK_BIND_DEADLINE != 5 ]] ||
  fail "DECK_OSK_BIND_DEADLINE is back to 5 -- that is the shipped value docs/PROGRESS.md §5.34 D2 measured as too short on hardware"
pass "the 5 s deadline that shipped is gone"

# --- wait_for_marker's watch-pid: the exit answer, and the race -------------
#
# The mapper EXITS on its own when no gamepad exists at all (that same
# NO_PAD_GRACE_SECONDS path), which is precisely the QEMU case. Detecting the
# exit is what keeps a deadline sized for hardware from being dead waiting in
# every VM run.
: >"$work/mapper-dies.out"
(sleep 0.05) & dead_pid=$!
wait "$dead_pid" 2>/dev/null || true
start=$(date +%s%N)
set +e
deck_form_wait_for_marker "$work/mapper-dies.out" "deck-input-mapper: bound" 30 0.05 "$dead_pid"
rc=$?
set -e
end=$(date +%s%N)
elapsed_ms=$(( (end - start) / 1000000 ))
[[ $rc -eq 2 ]] ||
  fail "wait_for_marker must answer 2 ('the process is gone'), distinctly from 1 ('the deadline elapsed')" "got rc=$rc"
[[ $elapsed_ms -lt 5000 ]] ||
  fail "wait_for_marker must return as soon as the watched process is gone, not wait out a 30s deadline" "elapsed=${elapsed_ms}ms"
pass "wait_for_marker returns 2 in ~${elapsed_ms}ms when the watched process has exited, instead of waiting out the deadline"

# 🔴 THE RACE. A mapper can write the marker and exit in the same instant.
# Answering "it exited" without one more look would report a bind that
# happened as a bind that did not -- the mirror image of D2's false warning.
printf 'deck-input-mapper: bound\n' >"$work/mapper-bound-then-dead.out"
deck_form_wait_for_marker "$work/mapper-bound-then-dead.out" "deck-input-mapper: bound" 5 0.05 "$dead_pid" ||
  fail "a process that printed the marker and then exited must still be reported BOUND (0), not gone (2)"
pass "wait_for_marker re-checks the file after the watched process dies, so marker-then-exit is still a bind"

# a still-running process must not short-circuit the deadline answer
: >"$work/mapper-alive.out"
(sleep 5) & alive_pid=$!
set +e
deck_form_wait_for_marker "$work/mapper-alive.out" "deck-input-mapper: bound" 0.2 0.05 "$alive_pid"
rc=$?
set -e
kill "$alive_pid" 2>/dev/null; wait "$alive_pid" 2>/dev/null || true
[[ $rc -eq 1 ]] ||
  fail "with the watched process still alive and no marker, the answer must be 1 (deadline elapsed)" "got rc=$rc"
pass "a live process with no marker still answers 1 at the deadline (the two outcomes stay distinguishable)"

# --- THE RETRACTION: the warning is made true, not merely rarer ------------
#
# docs/PROGRESS.md §5.34 D2's second half. On hardware the deadline expired,
# the code said "this prompt runs WITHOUT it", and then left the mapper
# running -- so the keyboard drew a second later underneath a sentence denying
# it. This is the test that fails if that comes back. It needs no gamepad and
# no hardware, which is the point: QEMU structurally cannot reproduce D2, so
# the regression test must not depend on a bind ever happening.
printf 'Y\n' >"$work/lizard-abandon"
cat >"$work/fake-mapper-slow" <<'EOF'
#!/usr/bin/env bash
# Never binds within any deadline this suite uses, and stays alive afterwards
# -- exactly the shape that produced the false warning on hardware.
echo "deck-input-mapper: no gamepad present; waiting up to 30s for one to enumerate" >&2
sleep 60
EOF
chmod +x "$work/fake-mapper-slow"
out=$(DECK_TEXT_PROMPT_LIZARD_SYSFS="$work/lizard-abandon" \
      DECK_TEXT_PROMPT_MAPPER_BIN="$work/fake-mapper-slow" \
      DECK_TEXT_PROMPT_DEADLINE=0.3 \
      deck_form_text_prompt fake_prompt_ok 2>"$work/warnings-abandon")
[[ $out == "osk_up=0" ]] ||
  fail "an abandoned mapper must leave DECK_FORM_OSK_UP=0" "got: $out"
sleep 0.3
if pgrep -f "$work/fake-mapper-slow" >/dev/null 2>&1; then
  fail "🔴 §5.34 D2: text_prompt warned that the prompt runs WITHOUT the on-screen keyboard and then LEFT THE MAPPER RUNNING. The keyboard comes up anyway, underneath a false statement." "$(cat "$work/warnings-abandon")"
fi
pass "text_prompt KILLS the mapper when the deadline expires, so 'this prompt runs WITHOUT it' is true by construction (§5.34 D2)"

LC_ALL=C grep -qF "the mapper has been stopped so that stays true" "$work/warnings-abandon" ||
  fail "the degradation message must say the mapper was stopped -- otherwise the screen states a consequence without its cause" "$(cat "$work/warnings-abandon")"
[[ $(cat "$work/lizard-abandon") == Y ]] ||
  fail "🔴 abandoning the mapper MUST restore lizard mode to Y first. Without it the device has no firmware pointer AND no mapper -- no input at all, on a screen the user then cannot leave. That is the state §2.3 exists to prevent."
pass "abandoning the mapper restores lizard mode to Y immediately, so the device is never left with no input at all"

# The mapper's own last words are the ONLY record of WHY it never bound.
# deck_form_text_prompt_cleanup deletes the capture file; reporting it first
# is the difference between a stated degradation and a swallowed one.
LC_ALL=C grep -qF "no gamepad present" "$work/warnings-abandon" ||
  fail "the mapper's own output must be reported before the capture file is deleted -- it is the only place the REASON exists" "$(cat "$work/warnings-abandon")"
pass "the mapper's captured output is reported, not deleted unread, when it is abandoned"

# --- the mapper that exits on its own (the QEMU shape) ----------------------
printf 'Y\n' >"$work/lizard-exits"
cat >"$work/fake-mapper-exits" <<'EOF'
#!/usr/bin/env bash
echo "deck-input-mapper: no gamepad matched None. Devices: none" >&2
exit 1
EOF
chmod +x "$work/fake-mapper-exits"
start=$(date +%s%N)
out=$(DECK_TEXT_PROMPT_LIZARD_SYSFS="$work/lizard-exits" \
      DECK_TEXT_PROMPT_MAPPER_BIN="$work/fake-mapper-exits" \
      DECK_TEXT_PROMPT_DEADLINE=30 \
      deck_form_text_prompt fake_prompt_ok 2>"$work/warnings-exits")
end=$(date +%s%N)
elapsed_ms=$(( (end - start) / 1000000 ))
[[ $out == "osk_up=0" ]] ||
  fail "a mapper that exits without binding must leave DECK_FORM_OSK_UP=0" "got: $out"
[[ $elapsed_ms -lt 5000 ]] ||
  fail "text_prompt must not wait out a 30s deadline for a mapper that has already exited" "elapsed=${elapsed_ms}ms"
LC_ALL=C grep -qF "exited without ever reporting bound" "$work/warnings-exits" ||
  fail "'it exited' and 'it is taking too long' are different facts and must be said differently" "$(cat "$work/warnings-exits")"
[[ $(cat "$work/lizard-exits") == Y ]] ||
  fail "a mapper that exited on its own must still leave lizard mode restored to Y"
pass "text_prompt notices a mapper that exited (~${elapsed_ms}ms, not the 30s deadline), says so distinctly, and restores lizard mode"

echo "--- P33 A3: the console font ------------------------------------------"

# 🔴 THE POINT OF PINNING A FONT AT ALL (docs/PROGRESS.md §5.34 D3, and the
# P33 decision table's "the whole installer is unreadable at 8x16 on a 7 inch
# panel, not just the keyboard"). The Deck's framebuffer is 800x1280 -- READ
# off the hardware, /sys/class/graphics/fb0/virtual_size -- so the console
# default of 8x16 puts 100 columns of 8-pixel glyphs on a handheld.
#
# A fake `setfont`, same shape and same reasoning as the fake `loadkeys`
# above: this suite must never re-font the dev machine's own console.
mkdir -p "$work/bin-fakefont"
cat >"$work/bin-fakefont/setfont" <<'FAKEFONT'
#!/usr/bin/env bash
printf '%s\n' "${1:-}" >>"${FAKE_SETFONT_LOG:-/dev/null}"
if [[ -n ${FAKE_SETFONT_FAIL:-} ]]; then
  printf 'setfont: ERROR reading font file %s\n' "${1:-}" >&2
  exit "$FAKE_SETFONT_FAIL"
fi
exit 0
FAKEFONT
chmod +x "$work/bin-fakefont/setfont"
FONT_PATH="$work/bin-fakefont:$PATH"

: >"$work/sf.log"
DECK_FORM_TTY_OVERRIDE=/dev/pts/9 FAKE_SETFONT_LOG="$work/sf.log" \
  PATH="$FONT_PATH" deck_form_pin_console_font ||
  fail "the font pin must return 0 off a virtual console"
[[ ! -s "$work/sf.log" ]] ||
  fail "the font pin must NOT run setfont when tty is not a virtual console" "$(cat "$work/sf.log")"
pass "deck_form_pin_console_font is a no-op off a virtual console (same guard as the keymap pin)"

: >"$work/sf.log"
DECK_FORM_TTY_OVERRIDE=/dev/tty1 FAKE_SETFONT_LOG="$work/sf.log" \
  PATH="$FONT_PATH" deck_form_pin_console_font ter-probe-font ||
  fail "the font pin must succeed on a virtual console with a working setfont"
[[ $(cat "$work/sf.log") == "ter-probe-font" ]] ||
  fail "the font pin must load exactly the font it was given" "got: $(cat "$work/sf.log")"
pass "deck_form_pin_console_font loads the font it is given on a virtual console"

# 🔴 AND THE SHIPPING DEFAULT PINS NOTHING. DECK_CONSOLE_FONT is empty (see its
# own comment: 16x32 halved the Deck's rows from 50 to 25 and pushed the
# username/password prompts off-screen). Without the empty-guard this would run
# `setfont ""` on the real console and warn on EVERY prompt.
: >"$work/sf.log"
out=$(DECK_FORM_TTY_OVERRIDE=/dev/tty1 FAKE_SETFONT_LOG="$work/sf.log" \
      PATH="$FONT_PATH" deck_form_pin_console_font 2>&1) ||
  fail "the default (empty) font pin must return 0"
[[ ! -s "$work/sf.log" ]] ||
  fail "an empty DECK_CONSOLE_FONT must not exec setfont at all" "$(cat "$work/sf.log")"
[[ -z $out ]] ||
  fail "an empty DECK_CONSOLE_FONT must be SILENT -- a warning on every prompt is noise on the screens that matter" "got: $out"
pass "the shipping default (DECK_CONSOLE_FONT empty) execs no setfont and says nothing"

# 🔴 NEVER FATAL -- and this is the rule that DIFFERS from the keymap's. A
# wrong keymap silently substitutes characters in a masked password field; a
# missing font only means the screen stays small. "A prompt with a small font
# beats no prompt."
out=$(DECK_FORM_TTY_OVERRIDE=/dev/tty1 FAKE_SETFONT_FAIL=71 \
      PATH="$FONT_PATH" deck_form_pin_console_font ter-probe-font 2>&1) ||
  fail "a failed setfont must NOT be fatal -- the screen still has to be drawn"
LC_ALL=C grep -qF "ERROR reading font file" <<<"$out" ||
  fail "a failed font pin must forward setfont's OWN message rather than swallowing it" "got: $out"
LC_ALL=C grep -qF "every screen still works" <<<"$out" ||
  fail "a failed font pin must say what it means for the user, not just log an errno" "got: $out"
pass "a failed font pin returns 0, warns loudly, and forwards setfont's own stderr"

# The font must be one that actually exists in the image. `kbd` is already in
# base (it is what provides loadkeys) and ships this file, so A3 needs no new
# package -- but only if the NAME is right. Checked against this machine's own
# kbd when it has one; loudly not-run otherwise, never silently skipped.
if [[ -z $DECK_CONSOLE_FONT ]]; then
  # 🔴 EMPTY IS THE SHIPPING VALUE as of 2026-08-16, and this branch asserts
  # that rather than skipping. Pinning latarcyrheb-sun32 took the Deck's
  # console from 160x50 to 80x25 -- it halved the ROWS as well as the columns,
  # and 25 rows cannot hold the logo, a prompt and a 7-row keyboard at once, so
  # the username and password prompts went off-screen on real hardware. The
  # keyboard's size was fixed instead by deck_osk_tty.py deriving its cell
  # width from the real column count, which needs no font change at all.
  #
  # If someone sets this again, the OTHER branch runs and checks the name --
  # but the thing that actually has to be checked is the ROW budget on the
  # tallest screen, and no unit test here can see that. Measure it on a panel.
  deck_form_pin_console_font >/dev/null 2>&1 ||
    fail "an empty DECK_CONSOLE_FONT must still return 0 -- the font pin is never fatal"
  pass "DECK_CONSOLE_FONT is empty (shipping default): no font is pinned and the console keeps 8x16 / 160x50"
elif [[ -d /usr/share/kbd/consolefonts ]]; then
  font_hits=$(find /usr/share/kbd/consolefonts -maxdepth 1 -name "${DECK_CONSOLE_FONT}.*" | wc -l)
  [[ $font_hits -gt 0 ]] ||
    fail "DECK_CONSOLE_FONT='$DECK_CONSOLE_FONT' is not in /usr/share/kbd/consolefonts on this machine -- if kbd does not ship it, the ISO needs a package it does not currently install"
  pass "DECK_CONSOLE_FONT ('$DECK_CONSOLE_FONT') is a font kbd itself ships -- no new ISO package needed"
else
  echo "    [gate NOT RUN] /usr/share/kbd/consolefonts does not exist here, so the font's existence was not checked."
fi

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
# ⚠️ AND `ip` MUST BE PINNED TOO, for the identical reason, since 2026-08-16.
# S1 now asks "does this machine have a network?" BEFORE it asks "is there a
# radio?", and it asks it of the real `ip` unless told otherwise -- so on a dev
# machine with an address this would take the already-connected path and record
# `skipped`, while in an offline CI it would record `no-hardware`. `/bin/false`
# is the whole fixture: deck_form_addr_present treats a failing `ip` as no
# output, i.e. no address, and the probe is then never run at all (no curl, no
# real network traffic out of the unit suite).
out=$(STTY_MARKER="$work/stty.marker" PATH="$work/bin:$work/bin-fakegum:$PATH" \
      DECK_S0_TTY="$work/fake-tty-input" \
      DECK_NET_SYSFS="$work/net-empty" \
      DECK_IP_BIN=/bin/false \
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

# --- P33 A3: the same ordering property, for the FONT ----------------------
#
# The font is pinned beside the keymap and BEFORE the mapper starts, so the
# on-screen keyboard reads the console geometry this sets rather than the one
# it replaced. A font pinned after the mapper drew would resize the console
# under a keyboard already laid out for the old width.
: >"$work/sf.log"
deck_form_test_font_body() { printf '%s\n' "$(cat "$work/sf.log")" >"$work/font-at-body.log"; printf 'typed\n'; }
out=$(DECK_FORM_TTY_OVERRIDE=/dev/tty1 FAKE_SETFONT_LOG="$work/sf.log" \
      PATH="$work/bin-fakefont:$work/bin-fakekeys:$PATH" \
      DECK_TEXT_PROMPT_LIZARD_SYSFS="$work/no-such-knob" \
      DECK_TEXT_PROMPT_MAPPER_BIN="$work/no-such-mapper" \
      deck_form_text_prompt deck_form_test_font_body 2>/dev/null)
[[ $out == typed ]] || fail "the font-recording body must have run" "got: $out"
[[ $(cat "$work/font-at-body.log") == "$DECK_CONSOLE_FONT" ]] ||
  fail "deck_form_text_prompt must pin the console font BEFORE running its body" "got: $(cat "$work/font-at-body.log")"
pass "deck_form_text_prompt pins the console font before the body runs, at the point of use"

# greeter() is the earliest point in upstream's flow this file owns, so
# pinning there is what makes S0's disclosure and S1's network list bigger
# too -- text_prompt's copy only ever reaches the text screens.
: >"$work/sf.log"
: >"$work/greeter-tty"
deck_form_wifi_screen_saved=$(declare -f deck_form_wifi_screen)
deck_form_wifi_screen() { return 0; }
DECK_S0_TTY="$work/greeter-tty" DECK_FORM_TTY_OVERRIDE=/dev/tty1 \
  FAKE_SETFONT_LOG="$work/sf.log" PATH="$FONT_PATH" \
  greeter >/dev/null 2>&1 || true
eval "$deck_form_wifi_screen_saved"
[[ $(cat "$work/sf.log") == "$DECK_CONSOLE_FONT" ]] ||
  fail "greeter must pin the console font -- S0 and S1 run before any text prompt, and they are unreadable at 8x16 too" "got: '$(cat "$work/sf.log")'"
pass "greeter pins the console font, so S0 and S1 are drawn at the bigger size as well"

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

# The call site, matched loosely on purpose. Upstream dropped the argument at
# 4.0.0 stable (`keyboard_form true` -> `keyboard_form`, omarchy-iso 174dd82)
# and calls it both indented and at top level, so pin the CALL, not its spelling.
# The `() {` definition line cannot match this pattern.
#
# ⚠️ `|| true` is load-bearing, not laziness. Under this file's `set -euo
# pipefail` a grep that matches nothing kills the suite inside the command
# substitution -- before the `|| fail` below can say why. That is exactly how
# this check failed when the pin moved: 33 passes, exit 1, and NOT ONE WORD
# about the cause. Let the assertion do the reporting.
kf_call=$(LC_ALL=C grep -nE '^[[:space:]]*keyboard_form([[:space:]]+true)?[[:space:]]*$' "$CONFIGURATOR" | head -1 | cut -d: -f1 || true)
pw_call=$(LC_ALL=C grep -n 'omarchy_prompt_password' "$CONFIGURATOR" | head -1 | cut -d: -f1 || true)
[[ -n $kf_call && -n $pw_call ]] ||
  fail "could not locate upstream's keyboard_form/omarchy_prompt_password call sites -- this premise check is broken" \
    "keyboard_form call: '${kf_call:-<none>}', omarchy_prompt_password: '${pw_call:-<none>}' in $CONFIGURATOR"
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

echo "--- T4 bug 2 regression: the username retry screen must not grow unboundedly ---"

# docs/findings/T4-controller-only-install-first-run.md §5, MEASURED (twice,
# bit-identical): rows=16/22/28/34 across four failed username submits --
# growing by exactly 6 every attempt, never settling. Cause: every retry in
# omarchy_prompt_username warned with a bare `deck_form_warn` on top of
# `deck_form_text_prompt`'s OWN per-call warnings (mapper-not-found, the
# console-keymap notice), and NOTHING ever cleared the screen between
# attempts -- unlike upstream's own retry loop, whose every `notice()` call
# starts with `clear_logo` (READ, configurator:180-185) before printing the
# new message, so upstream's screen is always "logo + this attempt's one
# message", never every attempt's messages stacked on top of each other.
#
# Reproduced here without a real console: this suite's `clear_logo` stub is
# a silent no-op everywhere else (`:;`, line 104) -- here it needs to be
# OBSERVABLE, so it is temporarily replaced with one that prints a marker.
# The assertion is not "clear_logo gets called" alone (that would pass even
# if warnings kept accumulating around it) -- it is that the chunk of output
# BETWEEN two consecutive clears stays the SAME SIZE across repeated invalid
# attempts. The bug printed a bounded amount too, on every single attempt;
# what made it unbounded is that each attempt's output landed on top of
# every prior one instead of replacing it.
work_growth="$work/username-growth"
mkdir -p "$work_growth"
printf '<EMPTY>\n<EMPTY>\n<EMPTY>\n<EMPTY>\ndeck\n' >"$work_growth/queue"

orig_clear_logo=$(declare -f clear_logo)
# shellcheck disable=SC2329  # invoked indirectly, by name, from omarchy_prompt_username's retry loop
clear_logo() { printf '\n===DECK-FORM-TEST-CLEAR===\n' >&2; }

out=$(PATH="$work/bin-fakegum:$PATH" \
      DECK_TEXT_PROMPT_LIZARD_SYSFS="$work_growth/no-lizard" \
      DECK_TEXT_PROMPT_MAPPER_BIN="$work_growth/no-mapper" \
      DECK_SETUP_FORM_SH_OVERRIDE="$work_growth/does-not-exist.sh" \
      FAKE_GUM_INPUT_QUEUE="$work_growth/queue" \
      omarchy_prompt_username 2>"$work_growth/err.log")
eval "$orig_clear_logo"

[[ $out == deck ]] ||
  fail "the bug-2 regression harness is broken -- omarchy_prompt_username did not reach the valid 'deck' submission" "got: $out; log: $(cat "$work_growth/err.log")"

# ⚠️ `grep -c` exits 1 (not just "prints 0") when the count is zero -- against
# the PRE-FIX code (no clear_logo call at all) that would abort this suite's
# own `set -e` right here, before the assertion below ever got to say why.
# `|| true` keeps that a reported failure, not a crashed suite.
clears=$(LC_ALL=C grep -c '===DECK-FORM-TEST-CLEAR===' "$work_growth/err.log" || true)
((clears >= 4)) ||
  fail "expected a screen clear on every one of the 4 invalid attempts -- clear_logo ran $clears times" "$(cat "$work_growth/err.log")"

# Line counts of the segments BETWEEN consecutive clears -- what actually
# stays on screen during each retry after that retry's own repaint. The bug
# made these grow (16/22/28/34); the fix must make them equal.
declare -a segment_sizes=()
seg_count=0
saw_first_clear=0
while IFS= read -r line; do
  if [[ $line == *"===DECK-FORM-TEST-CLEAR==="* ]]; then
    # ⚠️ `((cond)) && stmt` as a bare statement (not an if/while condition,
    # not guarded by `||`) trips this suite's own `set -e` the moment cond
    # is false -- `&&`'s overall exit status is then the FALSE left side's,
    # not 0. Plain `if` avoids it; found by running this exact loop, which
    # silently killed the suite on the very first marker line.
    if [[ $saw_first_clear -eq 1 ]]; then
      segment_sizes+=("$seg_count")
    fi
    saw_first_clear=1
    seg_count=0
    continue
  fi
  if [[ $saw_first_clear -eq 1 ]]; then
    seg_count=$((seg_count + 1))
  fi
done <"$work_growth/err.log"
segment_sizes+=("$seg_count")

[[ ${#segment_sizes[@]} -ge 3 ]] ||
  fail "not enough clear-delimited segments to prove boundedness (need at least 3, got ${#segment_sizes[@]})" "${segment_sizes[*]:-none}"

first_size=${segment_sizes[0]}
for size in "${segment_sizes[@]}"; do
  [[ $size -eq $first_size ]] ||
    fail "T4 bug 2: the on-screen output between retries is NOT bounded -- segment sizes were ${segment_sizes[*]} (all should equal $first_size, the way upstream's own clear_logo-per-notice repaint keeps every retry the same size)" \
         "$(cat "$work_growth/err.log")"
done
pass "four consecutive invalid username submissions produce a constant-size screen each time (${segment_sizes[*]} lines), not the growing 16/22/28/34 the real ISO measured"

echo "--- S3 reserved-username list: sourced, never copied ---------------------"

# 🔴 THIS SECTION WAS GREEN WHILE THE PRODUCTION PATH WAS DEAD, and that is
# the most important thing about it (docs/PROGRESS.md §5.34 D1). Every fixture
# here used to define a bash ARRAY named `RESERVED_USERNAMES` -- the same
# inference deck-form.sh itself had made and flagged "(INFERRED, NOT READ)".
# The tests and the code agreed with each other and both disagreed with
# upstream, so the suite proved only that two guesses matched. A shipped ISO
# accepted `root` as a username with this section passing.
#
# The fixtures below are now shaped like the REAL vendored file, READ
# 2026-08-15 (session 29) at
# ~/.cache/omarchy-deck/p32-build/runtime-src/install/provisioning/setup-form.sh
# line 82: a variable named OMARCHY_RESERVED_USERNAMES whose value is an
# anchored alternation REGEX STRING, used upstream as
# `[[ "$username" =~ $OMARCHY_RESERVED_USERNAMES ]]` at that file's line 111.
# The value below is that line, verbatim.
readonly REAL_RESERVED_RE='^(root|bin|daemon|mail|ftp|http|nobody|dbus|systemd-coredump|systemd-network|systemd-oom|systemd-journal-remote|systemd-resolve|systemd-timesync|tss|uuidd|alpm|git|avahi|cups|lp|_talkd|polkitd|rtkit|qemu|brltty|gluster|rpc|libvirt-qemu|pcscd|nvidia-persistenced|sddm)$'

cat >"$work/setup-form-fixture.sh" <<EOF
OMARCHY_RESERVED_USERNAMES='$REAL_RESERVED_RE'
EOF
out=$(DECK_SETUP_FORM_SH_OVERRIDE="$work/setup-form-fixture.sh" deck_form_load_reserved_usernames 2>&1)
rc=$?
[[ $rc -eq 0 ]] || fail "load_reserved_usernames must succeed against a real-shaped fixture" "$out"
DECK_SETUP_FORM_SH_OVERRIDE="$work/setup-form-fixture.sh" deck_form_load_reserved_usernames
[[ $DECK_LOADED_RESERVED_PATTERN == "$REAL_RESERVED_RE" ]] ||
  fail "the loaded value must be the regex STRING itself, byte for byte -- anything else means it was reshaped on the way out of the subshell" "got: $DECK_LOADED_RESERVED_PATTERN"
pass "load_reserved_usernames loads upstream's regex string unchanged"

# 🔴 THE HEADLINE ASSERTION OF P33 A1. `root` reaching a real ISO as an
# accepted username is the defect; this is the test that would have caught it.
deck_form_username_reserved root ||
  fail "'root' MUST be rejected as a username -- this is docs/PROGRESS.md §5.34 D1 itself, and it shipped"
pass "'root' is reported reserved (the D1 regression test)"

# Spread across the list rather than one name: a check that only ever asks
# about the first alternative would pass against a truncated or mis-anchored
# pattern.
for reserved_name in root bin daemon http nobody polkitd qemu git sddm; do
  deck_form_username_reserved "$reserved_name" ||
    fail "'$reserved_name' is in upstream's own reserved list and must be rejected"
done
pass "every sampled name from upstream's list (root bin daemon http nobody polkitd qemu git sddm) is rejected"

for ok_name in deck definitely-not-reserved rooted roo _deck deck2; do
  if deck_form_username_reserved "$ok_name"; then
    fail "'$ok_name' is NOT in upstream's list and must be accepted -- rejecting it would strand a user on a screen with no way forward"
  fi
done
# `rooted` and `roo` are the anchor test: an unanchored or substring match
# would reject both, and upstream's pattern is anchored `^(...)$`.
pass "names outside the list are accepted, including the anchor cases 'rooted' and 'roo'"

out=$(DECK_SETUP_FORM_SH_OVERRIDE="$work/does-not-exist.sh" deck_form_load_reserved_usernames 2>&1) && \
  fail "load_reserved_usernames must return nonzero when the file is missing"
LC_ALL=C grep -qF "UNAVAILABLE" <<<"$out" ||
  fail "load_reserved_usernames must say the list is unavailable, not go silent" "got: $out"
DECK_SETUP_FORM_SH_OVERRIDE="$work/does-not-exist.sh" deck_form_load_reserved_usernames 2>/dev/null || true
if deck_form_username_reserved root; then
  fail "with no list loaded, nothing should be reported reserved (fail toward 'pattern check only', not toward false positives)"
fi
pass "load_reserved_usernames degrades loudly (nonzero, says UNAVAILABLE) when the file is missing, and the reserved-check fails open"

cat >"$work/setup-form-no-var.sh" <<'EOF'
SOME_OTHER_CONSTANT=1
EOF
out=$(DECK_SETUP_FORM_SH_OVERRIDE="$work/setup-form-no-var.sh" deck_form_load_reserved_usernames 2>&1) && \
  fail "load_reserved_usernames must fail when the sourced file defines no OMARCHY_RESERVED_USERNAMES"
LC_ALL=C grep -qF "defines no" <<<"$out" ||
  fail "load_reserved_usernames must explain WHY it failed when the variable is missing" "got: $out"
pass "load_reserved_usernames fails loudly (not silently-empty) when the vendored file exists but has the wrong shape"

# The renamed-upstream path, spelled out: this is EXACTLY what D1 was, and
# what the loud degradation is for. The old name must not quietly work again.
cat >"$work/setup-form-old-name.sh" <<'EOF'
RESERVED_USERNAMES=(root bin daemon)
EOF
out=$(DECK_SETUP_FORM_SH_OVERRIDE="$work/setup-form-old-name.sh" deck_form_load_reserved_usernames 2>&1) && \
  fail "a file defining only the OLD (inferred, wrong) array name must be a LOUD failure, not a silent success"
LC_ALL=C grep -qF "OMARCHY_RESERVED_USERNAMES" <<<"$out" ||
  fail "the warning must name the variable it looked for, so a future rename is diagnosable from the console alone" "got: $out"
pass "the old inferred name 'RESERVED_USERNAMES' no longer satisfies the load, and the warning names what was looked for"

# 🔴 An EMPTY regex matches EVERY string. Loading one and using it would
# reject every username a user could type, on a screen with no way past.
cat >"$work/setup-form-empty.sh" <<'EOF'
OMARCHY_RESERVED_USERNAMES=''
EOF
out=$(DECK_SETUP_FORM_SH_OVERRIDE="$work/setup-form-empty.sh" deck_form_load_reserved_usernames 2>&1) && \
  fail "an EMPTY OMARCHY_RESERVED_USERNAMES must be treated as a failed load -- an empty regex matches everything"
LC_ALL=C grep -qF "EMPTY" <<<"$out" ||
  fail "the empty-pattern warning must say so" "got: $out"
if deck_form_username_reserved deck; then
  fail "after an empty pattern was refused, an ordinary name must still be accepted (the empty regex must never reach the match)"
fi
pass "an empty reserved-username pattern is refused loudly and never used to reject every name"

# --- the gate against the REAL vendored file, when one is reachable --------
#
# This repo does not vendor setup-form.sh (build-iso.sh copies it out of the
# omarchy source at build time), so this gate cannot be unconditional. It is
# NOT skipped silently: it says out loud which file it checked, or that it
# found none -- the difference between "verified against upstream" and
# "verified against our own fixture" is the entire subject of this section.
real_setup_form=''
for candidate in \
  "${DECK_REAL_SETUP_FORM_SH:-}" \
  "$HOME/.cache/omarchy-deck/p32-build/runtime-src/install/provisioning/setup-form.sh" \
  /usr/share/omarchy/install/provisioning/setup-form.sh; do
  [[ -n $candidate && -r $candidate ]] && { real_setup_form=$candidate; break; }
done
if [[ -n $real_setup_form ]]; then
  DECK_SETUP_FORM_SH_OVERRIDE="$real_setup_form" deck_form_load_reserved_usernames ||
    fail "the REAL vendored setup-form.sh at $real_setup_form does not yield '$DECK_RESERVED_USERNAMES_VAR' -- upstream renamed it, and this file's override is dead again exactly the way §5.34 D1 was"
  deck_form_username_reserved root ||
    fail "the REAL vendored setup-form.sh at $real_setup_form loaded, but does not reject 'root'" "pattern: $DECK_LOADED_RESERVED_PATTERN"
  if deck_form_username_reserved deck; then
    fail "the REAL vendored setup-form.sh rejects 'deck', which is the username this project's own VM harness installs with" "pattern: $DECK_LOADED_RESERVED_PATTERN"
  fi
  pass "the REAL vendored setup-form.sh ($real_setup_form) still defines $DECK_RESERVED_USERNAMES_VAR, still rejects 'root', still allows 'deck'"
else
  echo "    [gate NOT RUN] no real setup-form.sh found -- the assertions above ran against this suite's own fixture only."
  echo "                   Set DECK_REAL_SETUP_FORM_SH=<path> to run it. Searched:"
  echo "                     \$HOME/.cache/omarchy-deck/p32-build/runtime-src/install/provisioning/setup-form.sh"
  echo "                     /usr/share/omarchy/install/provisioning/setup-form.sh"
fi

echo "--- T4 bug 1 regression: loading the reserved list must not clobber the overrides ---"

# docs/findings/T4-controller-only-install-first-run.md §2/§12: the real ISO
# ran UPSTREAM's own unmodified omarchy_prompt_identity/_hostname/_timezone
# (gum's literal "Full name>" placeholder on screen) even though deck-form.sh
# defines all three under the exact names upstream calls, sourced in the
# right order. Root cause, found by instrumenting the actual post-build
# `configurator` + this file outside a VM (bash's own name resolution, not a
# hardware or timing question): `deck_form_load_reserved_usernames` used to
# `source "$setup_form"` DIRECTLY -- and $setup_form's default,
# /usr/share/omarchy-iso/setup-form.sh, is the EXACT file build-iso.sh
# vendors upstream's own setup-form.sh to (READ,
# iso/upstream/builder/build-iso.sh: `cp "$setup_form"
# ".../usr/share/omarchy-iso/setup-form.sh"`) -- the same file that already
# defines omarchy_prompt_identity/_hostname/_timezone/_username/_password.
# `source` redefines a function in whatever shell actually runs it, so the
# instant a user typed one PATTERN-VALID username (calling this function
# from inside omarchy_prompt_username's own loop), that source silently
# reinstalled upstream's own prompt bodies over deck-form.sh's, for the rest
# of the install -- proven directly: sourcing the real vendored
# setup-form.sh flipped `declare -f omarchy_prompt_identity` from
# `deck_form_identity_body` to upstream's body, in one call, in a plain bash
# process replaying the real configurator's own source order.
#
# So this fixture does what the REAL setup-form.sh does: define
# OMARCHY_RESERVED_USERNAMES *and* one of the override names, to prove the fix
# (sourcing in a subshell, only the pattern text crosses back out) actually
# holds even when the sourced file collides on a name -- not just when it
# happens not to.
cat >"$work/setup-form-hostile.sh" <<EOF
OMARCHY_RESERVED_USERNAMES='$REAL_RESERVED_RE'
omarchy_prompt_identity() { printf 'UPSTREAM-IDENTITY-RAN\n'; }
omarchy_prompt_hostname() { printf 'UPSTREAM-HOSTNAME-RAN\n'; }
EOF
before_identity=$(declare -f omarchy_prompt_identity)
before_hostname=$(declare -f omarchy_prompt_hostname)
DECK_SETUP_FORM_SH_OVERRIDE="$work/setup-form-hostile.sh" deck_form_load_reserved_usernames ||
  fail "load_reserved_usernames must still succeed (and load the pattern) against a fixture that ALSO defines an override name"
after_identity=$(declare -f omarchy_prompt_identity)
after_hostname=$(declare -f omarchy_prompt_hostname)
[[ $before_identity == "$after_identity" ]] ||
  fail "T4 bug 1: deck_form_load_reserved_usernames let the sourced setup-form.sh redefine omarchy_prompt_identity in THIS shell" "$after_identity"
[[ $before_hostname == "$after_hostname" ]] ||
  fail "T4 bug 1: deck_form_load_reserved_usernames let the sourced setup-form.sh redefine omarchy_prompt_hostname in THIS shell" "$after_hostname"
deck_form_username_reserved root ||
  fail "the pattern must still load correctly even though the fixture ALSO redefines a function -- the two are not supposed to trade off"
pass "loading the reserved-username list never lets the sourced setup-form.sh redefine an override function in this shell (T4 bug 1's exact mechanism)"

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

LC_ALL=C grep -qF "$DECK_NET_RESCAN_ROW" "$work/rows.txt" ||
  fail "build_network_rows must include the Rescan row"
LC_ALL=C grep -qF "$DECK_NET_STOP_ROW" "$work/rows.txt" ||
  fail "build_network_rows must include the Stop row -- with no Skip, the dead end is the only way off this screen without a network, and a list with no way off it is a trap"
# 🔴 THE OPERATOR'S DECISION, ASSERTED ON THE ROWS THEMSELVES (2026-08-16):
# "There should be no 'Skip -- set up Wi-Fi later' option at all." An install
# with no network reaches a Deck that boots black
# (docs/findings/P32-steam-never-installed.md), so a row offering it is a row
# offering that. Case-insensitive and substring-wide on purpose: this must fail
# for "Skip", "skip Wi-Fi", or any re-spelling of the same escape hatch.
if LC_ALL=C command grep -qi 'skip' "$work/rows.txt"; then
  fail "the network list must not offer ANY skip row" "$(cat "$work/rows.txt")"
fi
pass "build_network_rows offers Rescan and Stop, and no skip row of any spelling"

LC_ALL=C grep -qF 'Evil?Bar' "$work/rows.txt" ||
  fail "build_network_rows must sanitise the hostile SSID ('|' -> '?') before it reaches the row list"
if LC_ALL=C command grep -qF '|' "$work/rows.txt"; then
  fail "build_network_rows must never let a raw '|' reach the rendered row list"
fi
pass "build_network_rows sanitises the hostile SSID and never leaks a raw '|' into the list"

nrows_out=$(wc -l <"$work/rows.txt")
[[ $nrows_out -eq 6 ]] ||   # 4 networks + Rescan + Stop
  fail "build_network_rows must produce exactly 6 rows (4 networks + Rescan + Stop)" "got $nrows_out: $(cat "$work/rows.txt")"
pass "build_network_rows produces exactly one row per network plus Rescan and Stop (6 total)"

# The order is asserted, not just the membership: Rescan is the row directly
# under the networks because it is the one that leads somewhere, and Stop is
# last because it is the only row that does not continue the install.
[[ $(tail -2 "$work/rows.txt" | head -1) == "$DECK_NET_RESCAN_ROW" ]] ||
  fail "Rescan must be the second-to-last row" "$(cat "$work/rows.txt")"
[[ $(tail -1 "$work/rows.txt") == "$DECK_NET_STOP_ROW" ]] ||
  fail "Stop must be the LAST row -- a cancel or a fat thumb must not land on it before Rescan" "$(cat "$work/rows.txt")"
pass "the tail of the list is Rescan then Stop, in that order"

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
[[ $(deck_form_net_choice_action "$DECK_NET_STOP_ROW") == stop ]] ||
  fail "the Stop row must map to stop"
[[ $(deck_form_net_choice_action "Skip -- set up Wi-Fi later") == connect ]] ||
  fail "the OLD Skip row's text must have no special meaning left anywhere -- a half-removed row that still maps to an action is worse than one that was never removed"
[[ $(deck_form_net_choice_action "$DECK_NET_RESCAN_ROW") == rescan ]] ||
  fail "the Rescan row must map to rescan"
[[ $(deck_form_net_choice_action $'\360\237\224\222 My Home Network') == connect ]] ||
  fail "an ordinary network row must map to connect"
pass "network-list choice mapping: cancel redraws (never acts), Stop/Rescan/network map correctly"

[[ $(deck_form_net_failure_action_for "") == redraw ]] ||
  fail "a cancelled post-association failure menu must REDRAW, never act"
[[ $(deck_form_net_failure_action_for "Try again") == retry ]] || fail "'Try again' must map to retry"
[[ $(deck_form_net_failure_action_for "Pick another network") == another ]] || fail "'Pick another network' must map to another"
[[ $(deck_form_net_failure_action_for "Skip -- set up Wi-Fi later") == redraw ]] ||
  fail "the failure menu's Skip entry is gone too -- if this maps to anything but redraw, the second door out of S1 without a network is still open"
[[ $(deck_form_net_failure_action_for "Drop to shell") == redraw ]] ||
  fail "an unrecognised choice must redraw, never be guessed at"
pass "post-association failure menu mapping: cancel, the old Skip text and anything unrecognised all redraw; retry/another map correctly"

items=$(deck_form_net_failure_items)
[[ $(LC_ALL=C command grep -c . <<<"$items") -eq 2 ]] ||
  fail "the failure menu must offer exactly Try again / Pick another network -- the Skip entry was the OTHER way out of S1 without a network (2026-08-16)" "$items"
LC_ALL=C command grep -qiF "shell" <<<"$items" &&
  fail "the failure menu must never offer a shell -- there is no keyboard"
LC_ALL=C command grep -qi "skip" <<<"$items" &&
  fail "the failure menu must not offer a skip of any spelling -- a rule enforced on one of two doors is not a rule"
pass "the failure menu offers exactly Try again / Pick another network, never a shell and never a skip"

echo "--- S1 the dead end: what a Deck with no network can actually do ---------"

# 🔴 THE REPLACEMENT FOR THE SKIP ROW IS A SCREEN, NOT A LOOP. Removing the row
# without this would leave a list that silently refuses to advance, which is a
# worse bug than the one being fixed: the user cannot tell "you may not" from
# "it is broken".
dead_items=$(deck_form_net_dead_end_items)
[[ $(LC_ALL=C command grep -c . <<<"$dead_items") -eq 3 ]] ||
  fail "the dead end must offer exactly Back / Reboot / Power off" "$dead_items"
LC_ALL=C command grep -qiF "shell" <<<"$dead_items" &&
  fail "the dead end must never offer a shell -- there is no keyboard (S4's deck_form_disk_dead_end precedent)"
[[ $(deck_form_net_dead_end_action_for "Back to the network list") == back ]] ||
  fail "the dead end must offer a way BACK -- unlike the disk dead end, this state is fixable by plugging in a dock or walking closer"
[[ $(deck_form_net_dead_end_action_for "Reboot") == reboot ]] || fail "Reboot must map to reboot"
[[ $(deck_form_net_dead_end_action_for "Power off") == poweroff ]] || fail "Power off must map to poweroff"
[[ $(deck_form_net_dead_end_action_for "") == redraw ]] ||
  fail "a cancelled dead-end menu must REDRAW -- B must never pick 'Power off' by accident (S8's Drop-to-shell bug)"
[[ $(deck_form_net_dead_end_action_for "Install anyway") == redraw ]] ||
  fail "an unrecognised dead-end choice must redraw, never be guessed at"
pass "the dead end offers Back / Reboot / Power off, maps each exactly, and redraws on cancel or anything unrecognised"

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
LC_ALL=C grep -qF "Steam is downloaded during setup" <<<"$offline" ||
  fail "§5's consequence text must name what is not downloaded"
# 🔴 P33 L1. "Gaming Mode will have no Steam" used to be the whole
# consequence, and it is not what the machine does: with no Steam, gamescope
# starts with nothing to display and the panel stays black --
# docs/findings/P32-steam-never-installed.md, on hardware, "identical to a
# dead one -- black, no messages, not even a cursor". A user who reads
# "Gaming Mode will have no Steam" pictures a missing icon; they get a device
# that looks bricked. The words BLACK SCREEN are the assertion.
LC_ALL=C grep -qF "BLACK SCREEN" <<<"$offline" ||
  fail "the consequence text must say the Deck boots to a BLACK SCREEN -- 'Gaming Mode will have no Steam' understates a device that looks dead"
LC_ALL=C grep -qF "Desktop Mode afterwards" <<<"$offline" ||
  fail "§5's consequence text must say Wi-Fi can be set up later"
# ⚠️ The DSP claim is GONE and must stay gone. `steamdeck-dsp` moved out of
# deck-fetch.packages into deck-mirror.packages + deck-install.packages on
# 2026-08-15, so it rides in the OFFLINE MIRROR: an offline install gets it,
# and telling the user their speakers will sound thin is now a false
# statement on a screen. Asserted against the real package lists rather than
# against a memory of the decision, so re-introducing either one goes red.
fetch_list="$REPO_ROOT/iso/overlay/configs/deck/deck-fetch.packages"
[[ -f $fetch_list ]] || fail "cannot find deck-fetch.packages -- this cross-check is broken, not the code"
if LC_ALL=C command grep -qx 'steamdeck-dsp' "$fetch_list"; then
  fail "steamdeck-dsp is back in deck-fetch.packages -- the offline consequence text must name the audio DSP again"
fi
LC_ALL=C grep -qiF "DSP" <<<"$offline" &&
  fail "the offline text claims the audio DSP is not downloaded, but steamdeck-dsp is in the OFFLINE MIRROR (deck-mirror.packages + deck-install.packages) -- an offline install gets it" "$offline"
LC_ALL=C grep -qiF "sound thin" <<<"$offline" &&
  fail "the offline text still promises thin speakers; steamdeck-dsp ships in the offline mirror"
pass "the offline consequence text names the BLACK SCREEN, names the recovery, and no longer makes the (now false) DSP claim"

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
# The way out it names had to change with the Skip row: naming a row that no
# longer exists is worse than naming nothing, and there is still a real way out
# -- B cancels the prompt, and an open network or a dock needs nothing typed.
LC_ALL=C grep -qF "Press B" <<<"$warn" ||
  fail "with no keyboard the screen must name the way out (B, back to the list), or the user is stuck" "$warn"
LC_ALL=C grep -qi "skip" <<<"$warn" &&
  fail "this warning must not send the user to a Skip row that no longer exists" "$warn"
pass "a missing OSK is stated loudly on the passphrase screen, together with a way out that still exists"

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
# 🔴 TWO DIFFERENT QUESTIONS, AND THE FAKE HAS TO TELL THEM APART (2026-08-16).
# S1 now asks `ip -4 -br addr show` with NO device -- "does this machine have a
# network by ANY route?" -- before it draws anything, and
# deck_form_wifi_wait_dhcp asks `... show dev wlan0` -- "did the join get a
# lease?" -- after. A fake that answered both from one file made every join
# fixture look like a machine that was already online before it joined, which
# is not a state a live ISO can be in (iwd has not been started yet).
case "$*" in
  *" dev "*) cat "${IP_ADDR_OUTPUT:-/dev/null}" ;;
  *)         cat "${IP_ADDR_ALL:-/dev/null}" ;;
esac
exit 0
IPBIN
chmod +x "$work/bin-net/ip"

cat >"$work/bin-net/systemctl" <<'SYSTEMCTL'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${SYSTEMCTL_LOG:-/dev/null}"
# 🔴 A REAL `systemctl poweroff` ENDS THE MACHINE, and the fake has to as well.
# One that returned 0 would drop deck_form_net_dead_end straight back into its
# own redraw loop, so every case that ends there would spin until the timeout
# and report nothing useful -- the "a stuck job that reports nothing is
# strictly worse than a failure" trap this suite already names elsewhere.
# Killing the parent is also the FAITHFUL simulation: the screen genuinely has
# no answer that means "carry on installing". A run that reached the dead end
# and powered off therefore exits 143 (SIGTERM), and that is asserted, not
# tolerated.
case "$*" in
  # SIGTERM, and MEASURED rather than picked. Two earlier spellings were
  # wrong, both instructively:
  #   * SIGINT is IGNORED by a non-interactive bash that has a foreground
  #     child, so the run sailed on and hit the 40 s timeout (rc 124).
  #   * a SIGTERM that actually KILLS the process makes `timeout` re-raise the
  #     same signal, and that took the whole suite with it (measured: the suite
  #     itself exited 143 mid-run). So s1-boot.sh traps TERM and exits 143
  #     ITSELF -- a normal exit with a signal-shaped status, which `timeout`
  #     passes through untouched and bash never announces.
  poweroff|reboot) kill -TERM "$PPID" 2>/dev/null; sleep 1; exit 0 ;;
esac
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
  # The backstop when a case under-scripts its answers. "Power off" ends the
  # run from the dead end (see the fake systemctl above) instead of spinning to
  # the timeout; every case that means to stop still queues Stop + Power off
  # explicitly, and asserts CHOOSE-QUEUE-EXHAUSTED is ABSENT, so this value can
  # never quietly become part of what a case proves.
  FAKE_GUM_CHOOSE_EXHAUSTED="Power off"
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
# The machine going away, simulated: the fake systemctl signals this process
# when the dead end asks it to power off or reboot. Exiting from the trap keeps
# it a NORMAL exit (status 143) rather than a death by signal, which is what
# stops `timeout` from re-raising the signal into the suite's own process group.
trap 'exit 143' TERM
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
# 🔴 AND THE VERDICT, for the same reason: DECK_NET_VERDICT is the OTHER value
# that crosses a screen boundary (deck_final_summary recaps it on S5), and it
# is set by a function that used to be called in a command substitution -- i.e.
# in a subshell, where the assignment died with the subshell and S5 always fell
# back to "offline". Dumping it from the real process is what proves it
# survives; asserting it inside deck-form.sh's own call would not.
printf '%s' "${DECK_NET_VERDICT:-}" >"${DECK_TEST_VERDICT_OUT:-/dev/null}"
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
  : >"$work/s1-$name/systemctl.log"
  s1_rc=0
  env "${s1_env[@]}" \
      DECK_FORM_PATH="$DECK_FORM_SH" \
      DECK_NET_STATE_DIR="$work/s1-$name" \
      DECK_TEST_SAY_LOG="$work/s1-$name/say.log" \
      DECK_TEST_SSID_OUT="$work/s1-$name/wifi-ssid" \
      DECK_TEST_VERDICT_OUT="$work/s1-$name/verdict" \
      SYSTEMCTL_LOG="$work/s1-$name/systemctl.log" \
      IWCTL_LOG="$work/s1-$name/iwctl.log" \
      FAKE_GUM_LOG="$work/s1-$name/gum.log" \
      FAKE_GUM_CHOOSE_QUEUE="$work/s1-$name/choose.q" \
      FAKE_GUM_INPUT_QUEUE="${S1_INPUT_QUEUE:-}" \
      IWCTL_CONNECT_RC="${S1_CONNECT_RC:-0}" \
      IWCTL_CONNECT_OUTPUT="${S1_CONNECT_OUTPUT:-}" \
      IP_ADDR_OUTPUT="${S1_IP_OUTPUT:-/dev/null}" \
      IP_ADDR_ALL="${S1_IP_ALL:-/dev/null}" \
      SYSTEMCTL_FAIL="${S1_SYSTEMCTL_FAIL:-}" \
      timeout 40 bash "$work/s1-boot.sh" \
      >"$work/s1-$name/stdout" 2>"$work/s1-$name/stderr" || s1_rc=$?
}

s1_say()   { cat "$work/s1-$1/say.log"; }
s1_out()   { cat "$work/s1-$1/${DECK_NET_OUTCOME_FILE}" 2>/dev/null; }

# --- §5 row 1: no wlan0 -> skip S1 entirely, never block ---
mkdir -p "$work/s1-nohw"
: >"$work/s1-nohw/gum.log"
env "${s1_env[@]}" DECK_NET_SYSFS="$work/net-none" \
    DECK_FORM_PATH="$DECK_FORM_SH" \
    DECK_NET_STATE_DIR="$work/s1-nohw" DECK_TEST_SAY_LOG="$work/s1-nohw/say2.log" \
    DECK_TEST_VERDICT_OUT="$work/s1-nohw/verdict" \
    IWCTL_LOG="$work/s1-nohw/iwctl.log" FAKE_GUM_LOG="$work/s1-nohw/gum.log" \
    timeout 20 bash "$work/s1-boot.sh" >/dev/null 2>&1 || fail "S1 must return 0 with no Wi-Fi hardware -- it must never block the install (this is also every QEMU run)"
LC_ALL=C grep -qF "No Wi-Fi hardware found" "$work/s1-nohw/say2.log" ||
  fail "S1 must SAY that no Wi-Fi hardware was found" "$(cat "$work/s1-nohw/say2.log")"
LC_ALL=C grep -qF "with no network it is NOT installed" "$work/s1-nohw/say2.log" ||
  fail "the no-hardware path must state §5's offline consequence, not just skip silently"
# 🔴 P33 L1: AND IT MUST NOT ASK ANYTHING HERE. The user chose nothing on this
# path, there is no network list to go back to -- and this is the path EVERY
# QEMU run takes (no wlan0 in a VM). Both VM harnesses cross the greeter with
# a single `ret` that must land on "Select keyboard layout"
# (test/vm/vm-installer-screens-test.sh's own advance_and_vanish), so a screen
# inserted here turns the cheap tier red, or hangs it: `gum confirm
# --default=false` was measured NOT to accept Enter as the affirmative, so a
# bare Enter would answer "go back" and loop forever. The acknowledgement for
# this machine happens on S5, which is a gate the user has to cross anyway.
LC_ALL=C grep -qF "confirm" "$work/s1-nohw/gum.log" &&
  fail "the no-hardware path must NOT add a confirm -- every QEMU run takes it, and both VM harnesses expect one keypress from the greeter to land on the keyboard screen" "$(cat "$work/s1-nohw/gum.log")"
# 🔴 AND NO LIST EITHER (2026-08-16). A MACHINE WITH NO WI-FI HARDWARE IS NOT A
# USER DECLINING WI-FI: there is no radio, so there is nothing to list, nothing
# to rescan and no answer a screen could collect. The connection requirement is
# real for this machine too -- S5 states it on a gate the user must answer --
# but enforcing it HERE would put a mandatory, unanswerable screen in front of
# every QEMU run, which is exactly what the previous round tried and reverted.
LC_ALL=C grep -qF "choose" "$work/s1-nohw/gum.log" &&
  fail "the no-hardware path must draw NO menu at all -- it is keypress-free by design and both VM tiers depend on that" "$(cat "$work/s1-nohw/gum.log")"
LC_ALL=C grep -qxF "status=no-hardware" "$work/s1-nohw/$DECK_NET_OUTCOME_FILE" ||
  fail "the no-hardware path must record its outcome" "$(cat "$work/s1-nohw/$DECK_NET_OUTCOME_FILE")"
pass "§5: no Wi-Fi hardware -> S1 returns 0, says so, states the consequence, records no-hardware"

# --- §5 row 2: iwd will not start ---
S1_SYSTEMCTL_FAIL=1 s1_run iwddead
[[ $s1_rc -eq 0 ]] || fail "a dead iwd must not block the install" "rc=$s1_rc"
LC_ALL=C grep -qF "would not start" "$(printf '%s' "$work/s1-iwddead/say.log")" ||
  fail "S1 must say iwd would not start"
LC_ALL=C grep -qF "Job for iwd.service failed" "$work/s1-iwddead/say.log" ||
  fail "§5: the unit's own status line must be SHOWN, never swallowed" "$(s1_say iwddead)"
LC_ALL=C grep -qxF "status=iwd-failed" "$work/s1-iwddead/$DECK_NET_OUTCOME_FILE" ||
  fail "the dead-iwd path must record its outcome"
unset S1_SYSTEMCTL_FAIL
pass "§5: iwd will not start -> continues offline, SHOWS the unit's status line, records iwd-failed"

# ===========================================================================
# 🔴 THE OPERATOR'S DECISION, 2026-08-16, DRIVEN END TO END
# ===========================================================================
#
# "There should be no 'Skip -- set up Wi-Fi later' option at all." The row is
# gone, and with it the confirm that used to stand behind it -- so the cases
# below prove the three things that have to be true INSTEAD, none of which are
# "the row is missing":
#
#   1. a Deck that already has a connection is not stopped here at all
#   2. a Deck that has none is TOLD so, on a screen with somewhere to go
#   3. neither the list nor the failure menu has any other way out

# --- the dead end: Stop -> the screen that explains -> Power off ---
s1_run stop "$DECK_NET_STOP_ROW" "Power off"
[[ $s1_rc -eq 143 ]] ||
  fail "'Power off' on the dead end must END the run (the fake systemctl kills the parent, as a real one ends the machine) -- any other status means the screen fell through and kept installing" "rc=$s1_rc"
LC_ALL=C grep -qF "CHOOSE-QUEUE-EXHAUSTED" "$work/s1-stop/gum.log" &&
  fail "the stop case ran off the end of its scripted answers -- it is not doing what this test claims" "$(cat "$work/s1-stop/gum.log")"
LC_ALL=C grep -qxF "poweroff" "$work/s1-stop/systemctl.log" ||
  fail "'Power off' must actually call systemctl poweroff" "$(cat "$work/s1-stop/systemctl.log")"
LC_ALL=C grep -qF "cannot be installed without an internet connection" "$work/s1-stop/say.log" ||
  fail "the dead end must SAY why there is no way forward -- a list that will not advance, with no sentence, is indistinguishable from a broken installer" "$(s1_say stop)"
LC_ALL=C grep -qF "An internet connection is required during install" "$work/s1-stop/say.log" ||
  fail "the dead end must repeat the requirement itself, not just refer to it"
# 🔴 AND IT MUST NOT RECORD ANYTHING. `skipped` is the vocabulary for "this
# screen configured no Wi-Fi and the install went on"; a machine that stopped
# here never got there, and a record saying otherwise would be a lie in the
# only artefact deck_pkgs.py can read.
[[ ! -e "$work/s1-stop/$DECK_NET_OUTCOME_FILE" ]] ||
  fail "stopping the install must not record a Wi-Fi outcome -- there was no install to record one for" "$(s1_out stop)"
pass "Stop -> a dead-end screen that explains, offers Power off, actually powers off, and records nothing"

# --- and the way BACK, which is what makes it a decision rather than a trap ---
s1_run deadback "$DECK_NET_STOP_ROW" "Back to the network list" "$DECK_NET_STOP_ROW" "Power off"
[[ $s1_rc -eq 143 ]] || fail "the dead-end back-and-forth case must still end at the power-off" "rc=$s1_rc"
LC_ALL=C grep -qF "CHOOSE-QUEUE-EXHAUSTED" "$work/s1-deadback/gum.log" &&
  fail "the dead-end back case over-ran its answers" "$(cat "$work/s1-deadback/gum.log")"
[[ $(LC_ALL=C command grep -c 'header Networks' "$work/s1-deadback/gum.log") -eq 2 ]] ||
  fail "'Back to the network list' must redraw the LIST -- exactly two list draws in this run" "$(cat "$work/s1-deadback/gum.log")"
pass "'Back to the network list' returns to the list, and the list can be re-entered from the dead end"

# --- (1) a Deck that is ALREADY connected is never stopped here at all ---
#
# 🔴 THE ONE THAT KEEPS THE REQUIREMENT HONEST. orchestrator/deck_pkgs.py
# DECISION 2: a Deck on a dock's ethernet legitimately records `status=skipped`,
# and refusing it "would silently deny that machine its Steam on the strength of
# an answer about the radio". A mandatory Wi-Fi screen is that same refusal in
# the new rule's clothing, so this case asserts the screen draws NO LIST AT ALL
# -- not "the list has a way past it".
mkdir -p "$work/bin-online"
cat >"$work/bin-online/curl" <<CURLOK
#!/usr/bin/env bash
printf '%s\n' "$DECK_NET_PORTAL_EXPECT"
exit 0
CURLOK
chmod +x "$work/bin-online/curl"
printf 'lo  UNKNOWN 127.0.0.1/8\nenp0s20u1 UP 192.168.7.31/24\n' >"$work/ip-eth"
rm -rf "$work/s1-ethernet"; mkdir -p "$work/s1-ethernet"
printf 'Y\n' >"$work/s1-lizard"
: >"$work/s1-ethernet/choose.q"
: >"$work/s1-ethernet/iwctl.log"; : >"$work/s1-ethernet/gum.log"
eth_rc=0
env "${s1_env[@]}" \
    DECK_CURL_BIN="$work/bin-online/curl" \
    DECK_FORM_PATH="$DECK_FORM_SH" \
    DECK_NET_STATE_DIR="$work/s1-ethernet" \
    DECK_TEST_SAY_LOG="$work/s1-ethernet/say.log" \
    DECK_TEST_VERDICT_OUT="$work/s1-ethernet/verdict" \
    IWCTL_LOG="$work/s1-ethernet/iwctl.log" \
    FAKE_GUM_LOG="$work/s1-ethernet/gum.log" \
    FAKE_GUM_CHOOSE_QUEUE="$work/s1-ethernet/choose.q" \
    IP_ADDR_ALL="$work/ip-eth" \
    timeout 40 bash "$work/s1-boot.sh" >/dev/null 2>&1 || eth_rc=$?
[[ $eth_rc -eq 0 ]] || fail "an already-connected Deck must complete S1" "rc=$eth_rc"
[[ ! -s "$work/s1-ethernet/gum.log" ]] ||
  fail "🔴 an already-connected Deck was shown a screen it had to answer. It HAS a network; the requirement is already met, and interrogating it is deck_pkgs.py DECISION 2's mistake in the new rule's clothing" "$(cat "$work/s1-ethernet/gum.log")"
[[ ! -s "$work/s1-ethernet/iwctl.log" ]] ||
  fail "an already-connected Deck must not start scanning for access points either" "$(cat "$work/s1-ethernet/iwctl.log")"
LC_ALL=C grep -qF "with no network it is NOT installed" "$work/s1-ethernet/say.log" &&
  fail "an already-connected Deck must not be told its Deck will boot black -- that is a false statement about that machine" "$(cat "$work/s1-ethernet/say.log")"
LC_ALL=C grep -qF "already has a network connection" "$work/s1-ethernet/say.log" ||
  fail "the already-connected case must SAY why it is not stopping -- silence is indistinguishable from the detection never running, and the user pressed A expecting a Wi-Fi screen" "$(cat "$work/s1-ethernet/say.log")"
LC_ALL=C grep -qxF "status=skipped" "$work/s1-ethernet/$DECK_NET_OUTCOME_FILE" ||
  fail "the already-connected case still records status=skipped -- deck_wifi.py KNOWN_STATUSES and deck_pkgs.py NO_NETWORK_WIFI_STATUSES read that vocabulary and neither is this file's to change"
pass "an already-connected Deck crosses S1 with no list, no confirm, no scan, no false warning, and the same status=skipped record"

# --- (2) the middle case: an address, but the internet could not be confirmed.
#         Still not stopped -- the ADDRESS decides that, and a probe we could
#         not complete must not deny a machine with a working link its install.
rm -rf "$work/s1-unproven"; mkdir -p "$work/s1-unproven"
printf 'Y\n' >"$work/s1-lizard"
: >"$work/s1-unproven/choose.q"
: >"$work/s1-unproven/iwctl.log"; : >"$work/s1-unproven/gum.log"
unp_rc=0
env "${s1_env[@]}" \
    DECK_FORM_PATH="$DECK_FORM_SH" \
    DECK_NET_STATE_DIR="$work/s1-unproven" \
    DECK_TEST_SAY_LOG="$work/s1-unproven/say.log" \
    DECK_TEST_VERDICT_OUT="$work/s1-unproven/verdict" \
    IWCTL_LOG="$work/s1-unproven/iwctl.log" \
    FAKE_GUM_LOG="$work/s1-unproven/gum.log" \
    FAKE_GUM_CHOOSE_QUEUE="$work/s1-unproven/choose.q" \
    IP_ADDR_ALL="$work/ip-eth" \
    timeout 40 bash "$work/s1-boot.sh" >/dev/null 2>&1 || unp_rc=$?
[[ $unp_rc -eq 0 ]] || fail "the unproven-network case must complete S1" "rc=$unp_rc"
LC_ALL=C grep -qF "internet could not be confirmed" "$work/s1-unproven/say.log" ||
  fail "an unconfirmed probe must be described as unconfirmed, not as 'no network' -- there IS a link" "$(cat "$work/s1-unproven/say.log")"
LC_ALL=C grep -qF "with no network it is NOT installed" "$work/s1-unproven/say.log" ||
  fail "the unproven case must still state the consequence in full -- it may well be the offline case"
[[ ! -s "$work/s1-unproven/gum.log" ]] ||
  fail "a machine with an address must not be stopped by a probe we could not complete -- that is deck_pkgs.py DECISION 2 wearing a different hat" "$(cat "$work/s1-unproven/gum.log")"
pass "an address with no confirmable internet states exactly what was and was not established, and is still not stopped"

# --- (3) the verdict global has to SURVIVE into the caller's shell ---
#
# 🔴 THE BUG THIS CATCHES SHIPPED. deck_form_offline_detect sets
# DECK_NET_VERDICT, and every caller invoked it as `v=$(deck_form_offline_detect)`
# -- a command substitution, i.e. a subshell -- so the global was set in a
# process that exited immediately and S5 always read its `offline` default. The
# visible effect was the exact false statement the detection exists to prevent:
# an ethernet Deck told, on the last screen before the install, that it would
# boot to a black screen. Asserted from the REAL process, via the dump in
# s1-boot.sh, because an in-function assertion could not have seen it.
[[ $(cat "$work/s1-ethernet/verdict") == online ]] ||
  fail "DECK_NET_VERDICT must survive into the shell S5 runs in -- an already-connected Deck must reach S5 as 'online', or S5 warns it about a black screen it will never see" "got: $(cat "$work/s1-ethernet/verdict")"
[[ $(cat "$work/s1-unproven/verdict") == unproven ]] ||
  fail "the unproven verdict must reach S5 as 'unproven'" "got: $(cat "$work/s1-unproven/verdict")"
[[ $(cat "$work/s1-nohw/verdict") == offline ]] ||
  fail "a machine with no radio and no address must reach S5 as 'offline'" "got: $(cat "$work/s1-nohw/verdict")"
# And in-process, where the fix actually lives: call it as a command, read the
# global afterwards.
unset DECK_NET_VERDICT
DECK_IP_BIN=/bin/false deck_form_offline_detect >/dev/null
[[ ${DECK_NET_VERDICT:-unset} == offline ]] ||
  fail "deck_form_offline_detect must set DECK_NET_VERDICT in ITS CALLER's shell, not in a subshell" "got: ${DECK_NET_VERDICT:-unset}"
unset DECK_NET_VERDICT
pass "the network verdict crosses the screen boundary into S5 -- from the real process, not from a subshell that threw it away"

echo "--- P33 L1: the network verdict, as a truth table ------------------------"

# 🔴 THE ADDRESS DECIDES WHETHER THE USER IS STOPPED. The probe only decides
# what the screen says. Driving this as a table is the point: the failure this
# whole change exists to prevent is a machine being classified wrongly, and a
# classification bug is invisible in every end-to-end assertion above.
[[ $(deck_form_network_verdict_for 0 online)      == offline  ]] ||
  fail "no routable address is 'offline' whatever the probe claims -- a probe cannot be online on a machine with no address, so believing it would be believing a broken fake over the kernel"
[[ $(deck_form_network_verdict_for 0 unreachable) == offline  ]] || fail "no address + unreachable probe is offline"
[[ $(deck_form_network_verdict_for 0 skipped)     == offline  ]] || fail "no address, probe not run at all, is offline"
[[ $(deck_form_network_verdict_for 1 online)      == online   ]] || fail "an address plus a confirmed probe is online"
[[ $(deck_form_network_verdict_for 1 portal)      == unproven ]] ||
  fail "a captive portal is 'unproven', NOT 'online' -- pacman cannot fetch steam through a sign-in page"
[[ $(deck_form_network_verdict_for 1 unreachable) == unproven ]] || fail "an address with an unreachable probe is unproven"
[[ $(deck_form_network_verdict_for 1 unchecked)   == unproven ]] ||
  fail "an address with NO probe available must be 'unproven' -- claiming online on a check that never ran is the silent-success class CLAUDE.md forbids"
pass "the network verdict is a 3-value table keyed on the ADDRESS, with the probe refining only the wording"

# The address side, against deck_form_has_ipv4's own two traps.
cat >"$work/bin-net/ip-eth" <<'IPETH'
#!/usr/bin/env bash
cat "${IP_ADDR_OUTPUT:-/dev/null}"
IPETH
chmod +x "$work/bin-net/ip-eth"
printf 'lo UNKNOWN 127.0.0.1/8\nwlan0 UP 169.254.7.9/16\n' >"$work/ip-linklocal"
IP_ADDR_OUTPUT="$work/ip-linklocal" DECK_IP_BIN="$work/bin-net/ip-eth" deck_form_addr_present &&
  fail "a 169.254/16 link-local address is what the kernel hands out when DHCP FAILED -- counting it as a network is the exact false success deck_form_has_ipv4 exists to refuse"
printf 'lo UNKNOWN 127.0.0.1/8\n' >"$work/ip-loonly"
IP_ADDR_OUTPUT="$work/ip-loonly" DECK_IP_BIN="$work/bin-net/ip-eth" deck_form_addr_present &&
  fail "loopback alone is not a network"
IP_ADDR_OUTPUT="$work/ip-eth" DECK_IP_BIN="$work/bin-net/ip-eth" deck_form_addr_present ||
  fail "a routable address on a wired interface must read as a network -- this is the dock case"
pass "address detection ignores loopback and link-local, and finds a wired address on ANY interface (not just wlan0)"

# The probe must distinguish "could not look" from "looked and found nothing".
probe=$(DECK_CURL_BIN="$work/bin-net/curl-missing" deck_form_net_probe 2>/dev/null)
[[ $probe == unchecked ]] ||
  fail "a missing curl must report 'unchecked', not 'unreachable' -- 'we could not look' and 'we looked and there was nothing' must not produce the same screen" "got: $probe"
warn=$(DECK_CURL_BIN="$work/bin-net/curl-missing" deck_form_net_probe 2>&1 >/dev/null)
[[ -n $warn ]] || fail "a check that did not happen must SAY so (CLAUDE.md: never silently swallow a failure)"
[[ $(DECK_CURL_BIN="$work/bin-online/curl" deck_form_net_probe) == online ]] ||
  fail "a curl that returns NetworkManager's expected body must read as online"
pass "the probe reports 'unchecked' loudly when it could not run, and 'online' when it did"

# ===========================================================================
# P33 L1 + L2 -- THE ROW BUDGET. docs/PROGRESS.md §5.40 is why this exists.
# ===========================================================================
#
# 🔴 A change that ate rows pushed the username and password prompts OFF THE
# SCREEN and shipped to hardware. Nobody costed the rows. This section costs
# them, for both screens this round adds.
#
# The console is 50 rows x 160 columns -- MEASURED on the live ISO
# (docs/PROGRESS.md §7). Do NOT re-derive it from the framebuffer; that
# arithmetic has been wrong twice, once on each axis.
DECK_CONSOLE_ROWS=50
DECK_CONSOLE_COLS=160
# The logo: 10 lines, widest line 81 columns. Measured 2026-08-16 with `wc -l`
# and an awk max-length pass over the real
# ~/.cache/omarchy-deck/p32-build/runtime-src/logo.txt (the file `clear_logo`
# reads as $OMARCHY_PATH/logo.txt). clear_logo draws it through
# `gum style --padding "1 0 0 $PADDING_LEFT"`, so it costs its 10 lines plus
# one row of top padding.
LOGO_LINES=10
LOGO_COLS=81
LOGO_ROWS=$((LOGO_LINES + 1))
# `say` is `gum style --padding "0 0 0 $PADDING_LEFT"`, and configurator's own
# measure_terminal sets PADDING_LEFT=(TERM_WIDTH - LOGO_WIDTH)/2. So the text
# column budget is what is left of the console after that indent -- a line
# longer than this WRAPS, and a wrapped line silently costs an extra row.
PADDING_LEFT=$(( (DECK_CONSOLE_COLS - LOGO_COLS) / 2 ))
SAY_WIDTH=$(( DECK_CONSOLE_COLS - PADDING_LEFT ))
[[ $SAY_WIDTH -eq 121 ]] ||
  fail "the say() text budget arithmetic moved: expected 160-((160-81)/2)=121 columns" "got $SAY_WIDTH"

check_width() {   # <label> <text-producing-command...>
  local label=$1; shift
  local line n
  while IFS= read -r line; do
    n=${#line}
    [[ $n -le $SAY_WIDTH ]] ||
      fail "$label: a line is $n columns, over the ${SAY_WIDTH}-column say() budget -- it WRAPS and costs an extra row (docs/PROGRESS.md §5.40)" "$line"
  done < <("$@")
}
check_width "the offline consequence text" deck_form_wifi_offline_text
check_width "the Wi-Fi requirement text" deck_form_wifi_required_text
check_width "the pre-reboot notice" deck_form_reboot_notice_text
for v in online unproven offline; do
  check_width "the offline headline ($v)" deck_form_offline_headline "$v"
done
pass "every line of all three screens fits the ${SAY_WIDTH}-column say() budget -- none of them wrap"

offline_lines=$(deck_form_wifi_offline_text | LC_ALL=C command grep -c .)
[[ $offline_lines -ge 3 ]] || fail "the offline consequence text lost lines -- is it still saying what it must?"
GUM_CONFIRM_ROWS=3

# --- S1's NETWORK LIST, which is the screen this round actually grew ---------
#
# 🔴 THE ROW COST OF THE REQUIREMENT TEXT IS PAID ON THE SCREEN THAT ALSO HAS
# TO DRAW A LIST OF NETWORKS, and §5.40 is what happens when nobody counts:
# a change that ate rows pushed the username and password prompts off the panel
# and shipped. `step` is clear_logo + a blank + one line + a blank
# (configurator:185, READ), and `gum choose` draws its --header plus one row
# per item.
STEP_ROWS=$(( LOGO_ROWS + 1 + 1 + 1 ))
required_lines=$(deck_form_wifi_required_text | LC_ALL=C command grep -c .)
[[ $required_lines -ge 3 ]] ||
  fail "the requirement text must still say what is required, why, and what counts -- it is down to $required_lines lines"
GUM_CHOOSE_HEADER_ROWS=1
# The two rows every list carries whatever the scan found, plus the
# "No networks found..." line, which is the WORST case (it appears exactly when
# the list is shortest, so it never adds to a long list).
LIST_FIXED_ROWS=$(( STEP_ROWS + required_lines + 1 + GUM_CHOOSE_HEADER_ROWS + 2 ))
NETWORKS_VISIBLE=$(( DECK_CONSOLE_ROWS - LIST_FIXED_ROWS ))
# 10 is not a wish: iwctl orders get-networks by signal, and a user who cannot
# see their own access point in the ten strongest has a different problem. If
# this budget ever drops below it, the text above the list has grown too far.
[[ $NETWORKS_VISIBLE -ge 10 ]] ||
  fail "S1's network list has room for only $NETWORKS_VISIBLE networks on a ${DECK_CONSOLE_ROWS}-row console -- the text above it has eaten the list (docs/PROGRESS.md §5.40)" \
       "step=$STEP_ROWS required=$required_lines header=$GUM_CHOOSE_HEADER_ROWS fixed rows (Rescan+Stop)=2"

# --- and the dead end, which draws the same requirement text plus a menu ---
# clear_logo + echo + headline + the requirement + echo + choose header + 3 rows
dead_end_rows=$(( LOGO_ROWS + 1 + 1 + required_lines + 1 + GUM_CHOOSE_HEADER_ROWS + 3 ))
[[ $dead_end_rows -le $DECK_CONSOLE_ROWS ]] ||
  fail "S1's dead end needs $dead_end_rows rows on a ${DECK_CONSOLE_ROWS}-row console" \
       "logo=$LOGO_ROWS required=$required_lines menu=4"

# --- S5, the worst case: the table, the offline recap AND the reboot notice ---
# gum table -p borders a 10-row table as: top rule, header, header rule, 10
# data rows, bottom rule.
# DECK_LSBLK_BIN=/bin/true: this counts ROWS, and deck_form_disk_label emits
# exactly one line whether or not lsblk told it a size, so no fake disk table
# is needed here.
summary_rows=$(username=u password=p hostname=h timezone=t keyboard=us \
               disk=/dev/nvme0n1 encrypt_installation=false \
               DECK_LSBLK_BIN=/bin/true deck_form_summary_rows |
               LC_ALL=C command grep -c .)
TABLE_ROWS=$(( summary_rows + 3 ))   # header rule x2 + top/bottom, minus the header line already counted
reboot_lines=$(deck_form_reboot_notice_text | LC_ALL=C command grep -c .)
s5_rows=$(( LOGO_ROWS + 1 + TABLE_ROWS + 1 + 1 + offline_lines + 1 + reboot_lines + 1 + GUM_CONFIRM_ROWS ))
[[ $s5_rows -le $DECK_CONSOLE_ROWS ]] ||
  fail "S5 needs $s5_rows rows on a ${DECK_CONSOLE_ROWS}-row console -- §5.40 is what happens when a screen overruns: the prompts go off the panel and ship" \
       "logo=$LOGO_ROWS table=$TABLE_ROWS offline=$offline_lines reboot=$reboot_lines confirm=$GUM_CONFIRM_ROWS"
pass "row budget: S1's list leaves room for $NETWORKS_VISIBLE networks, its dead end = $dead_end_rows rows, S5 at its fullest = $s5_rows rows -- all inside the measured ${DECK_CONSOLE_ROWS}-row console"

echo "--- the Wi-Fi screen's own words: the requirement, and why ---------------"

# The operator's shape, 2026-08-16: the screen is titled `Wi-Fi` and says,
# directly beneath it, that an internet connection is required during install.
required_text=$(deck_form_wifi_required_text)
LC_ALL=C grep -qF "An internet connection is required during install" <<<"$required_text" ||
  fail "the operator asked for this sentence, in these words, where the installer says 'Wi-Fi'" "$required_text"
LC_ALL=C grep -qF "cannot continue without one" <<<"$required_text" ||
  fail "the screen must say the install cannot continue without a connection -- with no Skip row, a user who is not told that reads a list that will not advance as a broken installer"
LC_ALL=C grep -qF "Steam is downloaded from Valve during setup" <<<"$required_text" ||
  fail "the REASON must be on the screen too: a requirement with no reason reads as a wall, and this one has a very good reason"
LC_ALL=C grep -qF "BLACK SCREEN" <<<"$required_text" ||
  fail "the screen must say what a Steam-less Deck actually looks like -- docs/findings/P32-steam-never-installed.md: 'identical to a dead one'. 'Gaming Mode will have no Steam' is the understatement that cost the operator an evening"
LC_ALL=C grep -qiF "ethernet" <<<"$required_text" ||
  fail "the screen must say that a dock or a USB adapter counts -- the requirement is a NETWORK, never an answer about the radio (deck_pkgs.py DECISION 2)"
LC_ALL=C grep -qF "Rescan" <<<"$required_text" ||
  fail "the screen must name the row that acts on what it just told the user to do"
[[ $(LC_ALL=C command grep -ci "skip" <<<"$required_text") -eq 0 ]] ||
  fail "the requirement text must not mention skipping" "$required_text"
pass "the Wi-Fi screen states the requirement in the operator's words, the reason, the consequence, and what counts as a connection"

echo "--- P33 L2: the pre-reboot notice ---------------------------------------"

reboot_text=$(deck_form_reboot_notice_text)
LC_ALL=C grep -qF "reboots on its own" <<<"$reboot_text" ||
  fail "L2: the notice must say the Deck reboots by itself"
LC_ALL=C grep -qiE "about a minute|[0-9]+ (seconds|minutes)" <<<"$reboot_text" ||
  fail "L2: the notice must give the MEASURED duration. Re-measured 2026-08-16 on the P37 install: kernel 16:01:33.99 -> steamwebhelper 16:02:21.94, plus 12.0s of firmware+loader, is ~60s. The old assertion pinned the literal words 'two minutes' from the P36-era 2m03s and would have failed this correct fix."
LC_ALL=C grep -qF "BLACK" <<<"$reboot_text" ||
  fail "L2: the notice must say part of the wait is black -- 'the Deck looks switched off' is the whole reason this screen exists. It is no longer the WHOLE wait: the splash covers ~39s of the ~60s, so this asserts BLACK, not 'BLACK SCREEN'."
LC_ALL=C grep -qF "Don't turn me off" <<<"$reboot_text" ||
  fail "L2: the operator asked for this in these words ('something to tell users like don't turn me off. steam is unpacking'), and the splash elsewhere already uses them"
pass "L2: the pre-reboot notice says it reboots, says the panel goes black for the measured two minutes, and says don't turn me off"

# --- the cancel fallback, driven for real: B on the list REDRAWS ---
s1_run cancel "<CANCEL>" "<CANCEL>" "$DECK_NET_RESCAN_ROW" "$DECK_NET_STOP_ROW" "Power off"
[[ $s1_rc -eq 143 ]] || fail "a cancelled list must redraw, and the run must end where it was told to" "rc=$s1_rc"
LC_ALL=C grep -qF "CHOOSE-QUEUE-EXHAUSTED" "$work/s1-cancel/gum.log" &&
  fail "the cancel/rescan case ran off the end of its scripted answers -- the loop is not doing what this test claims"
[[ $(LC_ALL=C command grep -c 'header Networks' "$work/s1-cancel/gum.log") -eq 4 ]] ||
  fail "two cancels and a rescan must each redraw the LIST (4 list draws in total)" "$(cat "$work/s1-cancel/gum.log")"
pass "B/Esc on the network list REDRAWS (never acts, and never falls into Stop), and Rescan redraws too"

# --- §5 row 4: wrong passphrase, bounded at 3 tries ---
printf 'wrong1\nwrong2\nwrong3\nwrong4\n' >"$work/pass.q"
S1_INPUT_QUEUE="$work/pass.q" S1_CONNECT_RC=1 \
  s1_run wrongpw $'\360\237\224\222 My Home Network' "$DECK_NET_STOP_ROW" "Power off"
[[ $s1_rc -eq 143 ]] || fail "three wrong passphrases must end back at the list, not stuck" "rc=$s1_rc"
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
  s1_run nodhcp $'\360\237\224\222 My Home Network' "Pick another network" "$DECK_NET_STOP_ROW" "Power off"
[[ $s1_rc -eq 143 ]] || fail "a DHCP failure must be recoverable, not fatal" "rc=$s1_rc"
LC_ALL=C grep -qF "never handed out an address" "$work/s1-nodhcp/say.log" ||
  fail "§5: an association with no DHCP must be reported as a failure, not as success" "$(s1_say nodhcp)"
LC_ALL=C grep -qxF "status=connected" "$work/s1-nodhcp/$DECK_NET_OUTCOME_FILE" 2>/dev/null &&
  fail "🔴 a link-local address must NOT be recorded as connected -- that is the exact false success §5 row 5 exists to catch"
[[ ! -e "$work/s1-nodhcp/$DECK_NET_STAGED_NMCONNECTION" ]] ||
  fail "a network that never gave out an address must not be staged for the installed system"
# 🔴 THE FAILURE MENU HAS NO WAY OUT OF S1 ANY MORE, and this is where that is
# proven on the real screen rather than on the mapping function. It used to
# carry a Skip entry -- "the OTHER way a user leaves S1 without Wi-Fi", in the
# deleted gate's own words -- so removing the row from the list alone would
# have left the rule enforced on one of two doors. Both of the menu's remaining
# answers lead back to a screen that can still succeed; here "Pick another
# network" must return to the LIST.
LC_ALL=C grep -qF "CHOOSE-QUEUE-EXHAUSTED" "$work/s1-nodhcp/gum.log" &&
  fail "the no-DHCP run over-ran its scripted answers -- the loop is not doing what this test claims" "$(cat "$work/s1-nodhcp/gum.log")"
[[ $(LC_ALL=C command grep -c 'header Networks' "$work/s1-nodhcp/gum.log") -eq 2 ]] ||
  fail "'Pick another network' must return to the network list (2 list draws in this run)" \
       "$(cat "$work/s1-nodhcp/gum.log")"
[[ ! -e "$work/s1-nodhcp/$DECK_NET_OUTCOME_FILE" ]] ||
  fail "a run that never got a network and stopped must record no outcome at all" "$(s1_out nodhcp)"
unset S1_INPUT_QUEUE S1_IP_OUTPUT
pass "§5: associated-but-no-DHCP is a failure with a recovery menu, never a recorded success"

# --- the DHCP menu's own three answers, driven for real ---
printf 'pw1\npw2\n' >"$work/pass-retry.q"
S1_INPUT_QUEUE="$work/pass-retry.q" S1_IP_OUTPUT="$work/ip-linklocal" \
  s1_run dhcpretry $'\360\237\224\222 My Home Network' "Try again" "Pick another network" "$DECK_NET_STOP_ROW" "Power off"
[[ $s1_rc -eq 143 ]] || fail "the DHCP menu must always end somewhere reachable" "rc=$s1_rc"
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
printf '%s\n%s\n%s\n%s\n' $'\360\237\224\222 My Home Network' "Pick another network" "$DECK_NET_STOP_ROW" "Power off" >"$work/s1-portal/choose.q"
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
    timeout 40 bash "$work/s1-boot.sh" >/dev/null 2>&1 || portal_rc=$?
# 143 == the run reached the dead end and powered off, which is now the only
# way a screen with no usable network ends. Anything else means it either fell
# through (0) or hung until the timeout (124).
[[ ${portal_rc:-0} -eq 143 ]] ||
  fail "a captive portal must be recoverable from the controller (pick another), and the run must end where it was told to" "rc=${portal_rc:-0}"
LC_ALL=C grep -qF "needs a web sign-in page" "$work/s1-portal/say.log" ||
  fail "§5: a captive portal must be stated plainly" "$(cat "$work/s1-portal/say.log")"
LC_ALL=C grep -qi "skip wi-fi" "$work/s1-portal/say.log" &&
  fail "the captive-portal screen must not send the user to a skip that no longer exists" "$(cat "$work/s1-portal/say.log")"
LC_ALL=C grep -qxF "status=connected" "$work/s1-portal/$DECK_NET_OUTCOME_FILE" 2>/dev/null &&
  fail "a captive-portal network must NOT be recorded as usable"
[[ ! -e "$work/s1-portal/$DECK_NET_STAGED_NMCONNECTION" ]] ||
  fail "a captive-portal network must not be staged for the installed system"
pass "§5: a captive portal is stated plainly, never rendered, never recorded as connected, and is recoverable"

# --- §5 row 3: scan returns nothing ---
: >"$work/networks-empty.raw"
rm -rf "$work/s1-noscan"; mkdir -p "$work/s1-noscan"
printf 'Y\n' >"$work/s1-lizard"
printf '%s\n%s\n' "$DECK_NET_STOP_ROW" "Power off" >"$work/s1-noscan/choose.q"
: >"$work/s1-noscan/iwctl.log"; : >"$work/s1-noscan/gum.log"
env "${s1_env[@]}" \
    IWCTL_NETWORKS="$work/networks-empty.raw" \
    DECK_FORM_PATH="$DECK_FORM_SH" \
    DECK_NET_STATE_DIR="$work/s1-noscan" \
    DECK_TEST_SAY_LOG="$work/s1-noscan/say.log" \
    IWCTL_LOG="$work/s1-noscan/iwctl.log" \
    FAKE_GUM_LOG="$work/s1-noscan/gum.log" \
    FAKE_GUM_CHOOSE_QUEUE="$work/s1-noscan/choose.q" \
    timeout 40 bash "$work/s1-boot.sh" >/dev/null 2>&1 || noscan_rc=$?
[[ ${noscan_rc:-0} -eq 143 ]] ||
  fail "an empty scan must still reach the dead end and end there" "rc=${noscan_rc:-0}"
# §5's sentence was "No networks found. Move closer, or skip." Its second half
# named a row that no longer exists, so it names the two things that DO exist.
LC_ALL=C grep -qF "No networks found. Move closer, plug in a dock, or choose Rescan." "$work/s1-noscan/say.log" ||
  fail "the empty-scan sentence must name what the user can actually do now" "$(cat "$work/s1-noscan/say.log")"
LC_ALL=C grep -qF "An internet connection is required during install" "$work/s1-noscan/say.log" ||
  fail "the requirement must be on screen even when the list is empty -- that is the case where a user most needs to know it is not a bug" "$(cat "$work/s1-noscan/say.log")"
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
[[ ! -e "$work/s1-noscan/$DECK_NET_OUTCOME_FILE" ]] ||
  fail "an empty scan that ended at the dead end must record no outcome" "$(cat "$work/s1-noscan/$DECK_NET_OUTCOME_FILE")"
pass "§5: an empty scan retries twice, says what the user can do about it, and still reaches the dead end"

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
printf '%s\n%s\n%s\n' $'\360\237\224\222 CorpNet' "$DECK_NET_STOP_ROW" "Power off" >"$work/s1-corp/choose.q"
: >"$work/s1-corp/iwctl.log"; : >"$work/s1-corp/gum.log"
env "${s1_env[@]}" \
    IWCTL_NETWORKS="$work/networks-8021x.raw" \
    DECK_FORM_PATH="$DECK_FORM_SH" \
    DECK_NET_STATE_DIR="$work/s1-corp" \
    DECK_TEST_SAY_LOG="$work/s1-corp/say.log" \
    IWCTL_LOG="$work/s1-corp/iwctl.log" \
    FAKE_GUM_LOG="$work/s1-corp/gum.log" \
    FAKE_GUM_CHOOSE_QUEUE="$work/s1-corp/choose.q" \
    timeout 40 bash "$work/s1-boot.sh" >/dev/null 2>&1 || corp_rc=$?
[[ ${corp_rc:-0} -eq 143 ]] ||
  fail "an enterprise network must not break the screen -- the run must reach the dead end and end there" "rc=${corp_rc:-0}"
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
LC_ALL=C grep -qF "with no network it is NOT installed" "$work/s5-say.log" ||
  fail "§5: S5 must restate the offline consequence when no network was joined" "$(cat "$work/s5-say.log")"
LC_ALL=C grep -qF "No network was found" "$work/s5-say.log" ||
  fail "with DECK_NET_VERDICT unset (S1 never ran) S5 must take the SAFE reading -- 'we do not know' is the warning, not the reassurance" "$(cat "$work/s5-say.log")"

DECK_WIFI_SSID="MyHomeNetwork"
: >"$work/s5-say2.log"
FAKE_GUM_CONFIRM_RC=0 DECK_TEST_SAY_LOG="$work/s5-say2.log" \
DECK_LSBLK_BIN="$work/bin-fakelsblk/lsblk" PATH="$work/bin-fakegum:$PATH" \
  deck_final_summary >/dev/null
LC_ALL=C grep -qF "with no network it is NOT installed" "$work/s5-say2.log" &&
  fail "S5 must NOT show the offline consequence when a network WAS joined -- a warning that always fires is noise, not information"
unset DECK_WIFI_SSID
pass "S5 restates §5's offline consequence exactly when no network was joined, and not otherwise"

# 🔴 P33 L1, the S5 half of the ethernet case. "No SSID" is NOT "no network",
# and this is the LAST screen before the install -- telling a dock user their
# Deck will boot to a black panel would be a false statement at the worst
# possible moment.
: >"$work/s5-say3.log"
DECK_NET_VERDICT=online
FAKE_GUM_CONFIRM_RC=0 DECK_TEST_SAY_LOG="$work/s5-say3.log" \
DECK_LSBLK_BIN="$work/bin-fakelsblk/lsblk" PATH="$work/bin-fakegum:$PATH" \
  deck_final_summary >/dev/null
LC_ALL=C grep -qF "with no network it is NOT installed" "$work/s5-say3.log" &&
  fail "S5 must not warn about a black screen on a machine S1 detected as online (no SSID, but a working wired network)" "$(cat "$work/s5-say3.log")"
LC_ALL=C grep -qF "already has a network connection" "$work/s5-say3.log" ||
  fail "S5 must still say WHY it is not warning, so 'detected online' and 'the check never ran' are distinguishable on screen" "$(cat "$work/s5-say3.log")"
unset DECK_NET_VERDICT
pass "P33 L1: S5 recaps the DETECTED network state, so an ethernet Deck is not warned about a black screen it will not have"

echo "--- P33 L2: S5 carries the pre-reboot warning on every path --------------"

# Unconditional: every install reboots, and the first-boot wait is not
# conditional on anything the screens above decided. Asserted on BOTH the
# offline and the connected run's logs, because "shown only when offline" is
# exactly the kind of accidental coupling a single-case test would miss.
for log in "$work/s5-say.log" "$work/s5-say2.log" "$work/s5-say3.log"; do
  LC_ALL=C grep -qF "Don't turn me off" "$log" ||
    fail "S5 must carry the pre-reboot warning on every path, including $log" "$(cat "$log")"
  LC_ALL=C grep -qiE "about a minute|[0-9]+ (seconds|minutes)" "$log" ||
    fail "S5's pre-reboot warning must give the measured duration on every path ($log)"
done
pass "L2: the pre-reboot warning is on the last screen deck-form.sh owns, on every path through it"

# ===========================================================================
# S6: the kernel -- linux-neptune-611 ONLY, and the ordering that makes it work
# ===========================================================================
#
# 🔴 THE ORDERING IS THE WHOLE TEST. A function override only takes effect if
# the `source` runs before the CALL. If upstream ever hoists
# `kernel_choice=$(detect_kernel)` above deck-form-invocation.patch's insertion
# point, our detect_kernel is dead code, `kernel_choice` becomes stock `linux`,
# the target gets two kernels and two UKIs, and EVERY OTHER ASSERTION IN THIS
# SECTION STILL PASSES -- the passing state would be indistinguishable from
# the not-having-run state (docs/PROGRESS.md §5.30c). So this is asserted
# against the REAL PATCHED FILE, not against a remembered line number: the
# patch is applied to a scratch copy of the pinned configurator and the
# resulting line numbers are compared. Same technique test-deck-dashboard.sh
# already uses to prove its own patch applies.

echo "--- S6 the source lands BEFORE the call (the override is not dead code) --"

CONFIGURATOR="$REPO_ROOT/iso/upstream/configs/airootfs/root/configurator"
FORM_PATCH="$REPO_ROOT/iso/overlay/patches/deck-form-invocation.patch"
[[ -r $CONFIGURATOR ]] ||
  fail "iso/upstream is not checked out, so the source-before-call ordering was NOT verified. Run: git submodule update --init iso/upstream"
[[ -r $FORM_PATCH ]] ||
  fail "iso/overlay/patches/deck-form-invocation.patch is missing -- without it deck-form.sh is never sourced and NONE of its overrides run"
command -v patch >/dev/null 2>&1 ||
  fail "no 'patch' binary available to verify the ordering -- cannot verify, not skipping silently"

kernel_scratch="$work/kernel-patch-scratch"
mkdir -p "$kernel_scratch/configs/airootfs/root"
cp "$CONFIGURATOR" "$kernel_scratch/configs/airootfs/root/configurator"
if ! ( cd "$kernel_scratch" && patch -p1 --batch --fuzz=0 <"$FORM_PATCH" >"$work/kernel-patch.log" 2>&1 ); then
  fail "deck-form-invocation.patch does NOT apply cleanly against the pinned configurator -- the ordering cannot be verified" "$(cat "$work/kernel-patch.log")"
fi
patched_conf="$kernel_scratch/configs/airootfs/root/configurator"
pass "deck-form-invocation.patch applies cleanly against the pinned iso/upstream configurator"

# awk, not grep: an awk program that matches nothing still exits 0, where a
# `$(grep ...)` under this suite's `set -euo pipefail` would kill the run
# before any `|| fail` could report which assertion died.
src_line=$(awk '$0 == "source /usr/share/omarchy-iso/deck-form.sh" { print NR; exit }' "$patched_conf")
[[ -n $src_line ]] ||
  fail "the patched configurator has no top-level 'source /usr/share/omarchy-iso/deck-form.sh' line -- deck-form.sh is never sourced, so every override in it is dead"

# Column 0 == top level. The other call site is indented inside
# run_partition_decide(), and a function body resolves names at CALL time, so
# only a TOP-LEVEL call executed before the source could defeat the override.
top_calls=$(awk '$0 == "kernel_choice=$(detect_kernel)" { n++ } END { print n+0 }' "$patched_conf")
[[ $top_calls -eq 1 ]] ||
  fail "expected exactly ONE top-level 'kernel_choice=\$(detect_kernel)' in the patched configurator, found $top_calls -- re-derive the ordering by hand before trusting this suite"
call_line=$(awk '$0 == "kernel_choice=$(detect_kernel)" { print NR; exit }' "$patched_conf")

[[ $call_line -gt $src_line ]] ||
  fail "🔴 THE OVERRIDE IS DEAD CODE: the top-level kernel_choice=\$(detect_kernel) (line $call_line) runs BEFORE deck-form.sh is sourced (line $src_line). detect_kernel below would never apply and the target would silently get stock 'linux' plus a second kernel. Do not 'fix' this here -- the source line's placement is owned by iso/overlay/patches/deck-form-invocation.patch."
pass "the source (line $src_line) precedes the top-level detect_kernel call (line $call_line) -- the override actually applies"

# The in-function call site, pinned as in-function. If upstream ever moves it
# to column 0 above the anchor, the count assertion above catches it; this
# asserts the premise that it is a body, not top level.
body_calls=$(awk '/kernel_choice=\$\(detect_kernel\)/ && $0 != "kernel_choice=$(detect_kernel)" { n++ } END { print n+0 }' "$patched_conf")
[[ $body_calls -ge 1 ]] ||
  fail "upstream's second detect_kernel call site (inside run_partition_decide) has vanished -- re-read the configurator and re-derive the ordering argument in deck-form.sh's S6 block"
pass "upstream's other detect_kernel call site is inside a function body (resolved at call time, after the source)"

# Negative control: the measurement above is only meaningful if these awk
# programs can see a line that is definitely there.
sanity=$(awk '$0 == "write_user_files" { print NR; exit }' "$patched_conf")
[[ -n $sanity ]] ||
  fail "the line-number scanner cannot find a line that is definitely in the patched configurator -- it is broken, and the ordering result above means nothing"
pass "line-number scanner positive control: it really does find a known-live top-level line"

echo "--- S6 the override NAME, checked against upstream's own definition -----"

# 🔴 A rename upstream must fail LOUDLY here. If upstream renames detect_kernel,
# our definition stops overriding anything: `kernel_choice` silently reverts to
# stock `linux` and the installed Deck gets two kernels. Nothing else in this
# suite would notice -- detect_kernel would still return the Neptune name when
# called directly by the tests below.
LC_ALL=C grep -qE '^detect_kernel\(\) \{' "$CONFIGURATOR" ||
  fail "upstream's configurator no longer DEFINES 'detect_kernel()' at column 0 -- deck-form.sh's override now overrides nothing, and the target would silently get stock 'linux'. Find upstream's new name and rename the override to match."
pass "upstream still defines detect_kernel() under exactly that name"

LC_ALL=C grep -qE '^detect_kernel\(\) \{' "$DECK_FORM_SH" ||
  fail "deck-form.sh must define detect_kernel() at column 0 under upstream's exact name -- any other spelling is NO override, silently"
pass "deck-form.sh defines detect_kernel() under upstream's exact name"

# The contract the override actually delivers on: upstream must still route
# detect_kernel's answer into the archinstall JSON's "kernels" array, which is
# what archinstall_adapter.py:139 hands to Installer(kernels=...). If upstream
# stops doing that, overriding detect_kernel no longer decides anything.
LC_ALL=C grep -qE '^\s*kernel_choice=\$\(detect_kernel\)' "$CONFIGURATOR" ||
  fail "upstream no longer assigns kernel_choice from detect_kernel -- the override no longer decides the installed kernel"
# shellcheck disable=SC2016  # the literal string "$kernel_choice" is the thing being searched for
LC_ALL=C grep -qF '"kernels": [ "$kernel_choice" ]' "$CONFIGURATOR" ||
  fail "upstream's configurator no longer writes \"kernels\": [ \"\$kernel_choice\" ] into user_configuration.json -- detect_kernel no longer reaches archinstall, re-derive the mechanism"
pass "upstream still routes detect_kernel -> kernel_choice -> user_configuration.json's \"kernels\" array"

echo "--- S6 Deck hardware gets Neptune, and nothing else does ----------------"

mk_dmi() {
  local dir=$1
  mkdir -p "$dir"
  printf '%s\n' "$2" >"$dir/product_name"
  printf '%s\n' "$3" >"$dir/sys_vendor"
}

# Two fake lspci binaries: one that reports an Apple T2 bridge, one that does
# not. Every non-Deck assertion below pins DECK_LSPCI_BIN to one of them, so
# the result can never depend on the developer's own hardware.
mkdir -p "$work/bin-lspci"
cat >"$work/bin-lspci/lspci-t2" <<'EOF'
#!/usr/bin/env bash
printf '02:00.0 System peripheral [0880]: Apple Inc. Device [106b:1801]\n'
EOF
cat >"$work/bin-lspci/lspci-plain" <<'EOF'
#!/usr/bin/env bash
printf '00:02.0 VGA compatible controller [0300]: Red Hat, Inc. Virtio GPU [1af4:1050]\n'
EOF
chmod +x "$work/bin-lspci/lspci-t2" "$work/bin-lspci/lspci-plain"

expected_kernel="linux-neptune-611"
[[ $DECK_KERNEL_PKG == "$expected_kernel" ]] ||
  fail "DECK_KERNEL_PKG must be the operator-decided kernel package" "expected $expected_kernel, got $DECK_KERNEL_PKG"
pass "DECK_KERNEL_PKG is the pinned Neptune package name ($expected_kernel)"

# OLED. The only VERIFIED hardware in this project (CLAUDE.md), and the model
# every QEMU suite fakes via -smbios product=Galileo.
mk_dmi "$work/dmi-galileo" Galileo Valve
got=$(DECK_DMI_PRODUCT="$work/dmi-galileo/product_name" \
      DECK_DMI_VENDOR="$work/dmi-galileo/sys_vendor" \
      DECK_LSPCI_BIN="$work/bin-lspci/lspci-plain" detect_kernel)
[[ $got == "$DECK_KERNEL_PKG" ]] ||
  fail "an OLED Deck (Galileo/Valve) must install $DECK_KERNEL_PKG and nothing else" "got: $got"
pass "OLED Deck (Galileo) -> $DECK_KERNEL_PKG"

# LCD. Deliberate, documented, and UNVERIFIED -- see deck-form.sh's S6 block.
# It gets Neptune because the else branch would give a Steam Deck stock
# `linux`, which is worse. This assertion exists so that decision cannot be
# reversed by accident, only on purpose.
mk_dmi "$work/dmi-jupiter" Jupiter Valve
got=$(DECK_DMI_PRODUCT="$work/dmi-jupiter/product_name" \
      DECK_DMI_VENDOR="$work/dmi-jupiter/sys_vendor" \
      DECK_LSPCI_BIN="$work/bin-lspci/lspci-t2" detect_kernel)
[[ $got == "$DECK_KERNEL_PKG" ]] ||
  fail "an LCD Deck (Jupiter/Valve) must also install $DECK_KERNEL_PKG -- the alternative is stock 'linux' on a Steam Deck. LCD remains UNVERIFIED hardware; this is a reasoned default, not a support claim." "got: $got"
pass "LCD Deck (Jupiter) -> $DECK_KERNEL_PKG (deliberate; LCD is unverified either way)"

# The T2 fake above is deliberately in play on the Jupiter case: Deck detection
# must win over the T2 branch, not race it.
pass "Deck detection takes precedence over the T2 probe (the Jupiter case ran with the T2-reporting lspci)"

# Valve vendor with a product string this repo has never seen. The predicate is
# an OR, exactly as src/omarchy-deck-kernel.sh's gate is.
mk_dmi "$work/dmi-valve-unknown" "Some Future Thing" "Valve Corporation"
got=$(DECK_DMI_PRODUCT="$work/dmi-valve-unknown/product_name" \
      DECK_DMI_VENDOR="$work/dmi-valve-unknown/sys_vendor" \
      DECK_LSPCI_BIN="$work/bin-lspci/lspci-plain" detect_kernel)
[[ $got == "$DECK_KERNEL_PKG" ]] ||
  fail "sys_vendor containing 'Valve' must be enough on its own -- this mirrors src/omarchy-deck-kernel.sh's own gate" "got: $got"
pass "sys_vendor 'Valve Corporation' alone -> $DECK_KERNEL_PKG (matches the sibling gate's OR)"

# The literal product string, case-folded, as the sibling gate accepts it.
mk_dmi "$work/dmi-steamdeck" "Steam Deck" "SomeOEM"
got=$(DECK_DMI_PRODUCT="$work/dmi-steamdeck/product_name" \
      DECK_DMI_VENDOR="$work/dmi-steamdeck/sys_vendor" \
      DECK_LSPCI_BIN="$work/bin-lspci/lspci-plain" detect_kernel)
[[ $got == "$DECK_KERNEL_PKG" ]] ||
  fail "product_name 'Steam Deck' must match (case-folded), as src/omarchy-deck-kernel.sh accepts it" "got: $got"
pass "product_name 'Steam Deck' -> $DECK_KERNEL_PKG"

echo "--- S6 non-Deck hardware gets UPSTREAM'S EXACT answer, unchanged --------"

# 🔴 This file is a WRAP. On anything that is not a Deck the answer must be
# byte-identical to what stock omarchy-iso would have produced, or the override
# has changed behaviour it was never asked to change -- including in this
# project's own QEMU installs, which are not Decks.
mk_dmi "$work/dmi-generic" "20BES07600" "LENOVO"

got=$(DECK_DMI_PRODUCT="$work/dmi-generic/product_name" \
      DECK_DMI_VENDOR="$work/dmi-generic/sys_vendor" \
      DECK_LSPCI_BIN="$work/bin-lspci/lspci-plain" detect_kernel)
[[ $got == "linux" ]] ||
  fail "non-Deck, non-T2 hardware must get upstream's exact answer: the string 'linux'" "got: $got"
pass "non-Deck, non-T2 -> 'linux' (upstream's exact string, unchanged)"

got=$(DECK_DMI_PRODUCT="$work/dmi-generic/product_name" \
      DECK_DMI_VENDOR="$work/dmi-generic/sys_vendor" \
      DECK_LSPCI_BIN="$work/bin-lspci/lspci-t2" detect_kernel)
[[ $got == "linux-t2" ]] ||
  fail "a non-Deck Apple T2 Mac (PCI 106b:1801) must still get upstream's exact answer: 'linux-t2'. Upstream's comment: T2 Macs need their own kernel for keyboard/wifi drivers." "got: $got"
pass "non-Deck Apple T2 (106b:1801) -> 'linux-t2' (upstream's exact string, unchanged)"

# The other half of upstream's own PCI ID range.
cat >"$work/bin-lspci/lspci-t2b" <<'EOF'
#!/usr/bin/env bash
printf '02:00.0 System peripheral [0880]: Apple Inc. Device [106b:1802]\n'
EOF
chmod +x "$work/bin-lspci/lspci-t2b"
got=$(DECK_DMI_PRODUCT="$work/dmi-generic/product_name" \
      DECK_DMI_VENDOR="$work/dmi-generic/sys_vendor" \
      DECK_LSPCI_BIN="$work/bin-lspci/lspci-t2b" detect_kernel)
[[ $got == "linux-t2" ]] ||
  fail "upstream's pattern is 106b:180[12] -- the :1802 half must match too" "got: $got"
pass "non-Deck Apple T2 (106b:1802) -> 'linux-t2' (both halves of upstream's pattern)"

echo "--- S6 the detection reads ONLY seams a temp dir can fake ---------------"

# Absent DMI nodes are a legitimate "not a Deck" answer (a container, a VM
# without SMBIOS), never an error and never a crash under `set -u`.
got=$(DECK_DMI_PRODUCT="$work/does-not-exist/product_name" \
      DECK_DMI_VENDOR="$work/does-not-exist/sys_vendor" \
      DECK_LSPCI_BIN="$work/bin-lspci/lspci-plain" detect_kernel)
[[ $got == "linux" ]] ||
  fail "unreadable DMI nodes must fall through to upstream's branch, not crash and not guess Deck" "got: $got"
pass "absent/unreadable DMI nodes -> not a Deck -> upstream's branch"

# An unreadable node must not be silently treated as matching. Empty file =
# empty string = no match.
mk_dmi "$work/dmi-empty" "" ""
got=$(DECK_DMI_PRODUCT="$work/dmi-empty/product_name" \
      DECK_DMI_VENDOR="$work/dmi-empty/sys_vendor" \
      DECK_LSPCI_BIN="$work/bin-lspci/lspci-plain" detect_kernel)
[[ $got == "linux" ]] ||
  fail "empty DMI values must not match the Deck predicate" "got: $got"
pass "empty DMI values -> not a Deck"

# The predicate is asserted directly too, not only through the kernel name it
# produces -- T4-screen-spec.md §6.5's "a single-string mutation a shallow test
# would miss" applies to the Deck gate exactly as it does to the encryption
# constant.
DECK_DMI_PRODUCT="$work/dmi-galileo/product_name" \
DECK_DMI_VENDOR="$work/dmi-galileo/sys_vendor" \
  deck_form_is_steam_deck ||
  fail "deck_form_is_steam_deck must return 0 on Galileo/Valve"
if DECK_DMI_PRODUCT="$work/dmi-generic/product_name" \
   DECK_DMI_VENDOR="$work/dmi-generic/sys_vendor" \
     deck_form_is_steam_deck; then
  fail "deck_form_is_steam_deck must return non-zero on non-Deck hardware"
fi
pass "deck_form_is_steam_deck is directly assertable and answers both ways"

# The DMI paths this ships with must be the real sysfs ones -- a test that only
# ever exercises the overrides would stay green if the defaults were wrong.
[[ $DECK_DMI_PRODUCT_DEFAULT == /sys/class/dmi/id/product_name ]] ||
  fail "DECK_DMI_PRODUCT_DEFAULT must be the real sysfs path (the overrides exist for tests, not for production)" "got: $DECK_DMI_PRODUCT_DEFAULT"
[[ $DECK_DMI_VENDOR_DEFAULT == /sys/class/dmi/id/sys_vendor ]] ||
  fail "DECK_DMI_VENDOR_DEFAULT must be the real sysfs path" "got: $DECK_DMI_VENDOR_DEFAULT"
pass "the DMI defaults are the real sysfs paths src/omarchy-deck-kernel.sh reads"

echo "--- S6 the kernel name agrees across every file that names it ----------"

# 🔴 THE DESYNC GATE. deck-form.sh deliberately does NOT derive this name at
# runtime -- it cannot report a derivation failure from inside `$(...)` (see its
# own S6 block). The four copies are held in agreement HERE instead, where
# failing is free and loud.
MIRROR_PKGS="$REPO_ROOT/iso/overlay/configs/deck/deck-mirror.packages"
INSTALL_PKGS="$REPO_ROOT/iso/overlay/configs/deck/deck-install.packages"
KERNEL_SH="$REPO_ROOT/src/omarchy-deck-kernel.sh"
for f in "$MIRROR_PKGS" "$INSTALL_PKGS" "$KERNEL_SH"; do
  [[ -r $f ]] || fail "$f is missing -- the kernel-name desync gate cannot run, and is not being skipped silently"
done

[[ $DECK_KERNEL_PKG =~ ^linux-neptune-[0-9]+$ ]] ||
  fail "DECK_KERNEL_PKG must look like a Valve Neptune package name" "got: $DECK_KERNEL_PKG"

# Exact whole-line matches: deck-mirror.packages also carries
# 'linux-neptune-611-headers', which a substring grep would happily accept.
n=$(awk -v pkg="$DECK_KERNEL_PKG" '$0 == pkg { n++ } END { print n+0 }' "$INSTALL_PKGS")
[[ $n -eq 1 ]] ||
  fail "deck-install.packages must contain exactly one bare '$DECK_KERNEL_PKG' line -- that list is what makes pacstrap install it on the target, offline" "found $n"
pass "deck-install.packages names exactly $DECK_KERNEL_PKG (the target install list)"

n=$(awk -v pkg="$DECK_KERNEL_PKG" '$0 == pkg { n++ } END { print n+0 }' "$MIRROR_PKGS")
[[ $n -eq 1 ]] ||
  fail "deck-mirror.packages must contain exactly one bare '$DECK_KERNEL_PKG' line -- without it the package is not in the offline mirror and archinstall's minimal_installation cannot resolve it, killing the install at phase 3" "found $n"
pass "deck-mirror.packages carries exactly $DECK_KERNEL_PKG (the offline mirror)"

LC_ALL=C grep -qE "^readonly NEPTUNE_SERIES_DEFAULT=${DECK_NEPTUNE_SERIES}$" "$KERNEL_SH" ||
  fail "src/omarchy-deck-kernel.sh's NEPTUNE_SERIES_DEFAULT disagrees with deck-form.sh's DECK_NEPTUNE_SERIES=$DECK_NEPTUNE_SERIES. The ISO would install one Neptune series and the installed system's own kernel manager would maintain another."
pass "src/omarchy-deck-kernel.sh pins the same Neptune series ($DECK_NEPTUNE_SERIES)"

# ONE kernel. The operator decision is not "add Neptune", it is "Neptune only".
n=$(awk '$0 == "linux" { n++ } END { print n+0 }' "$INSTALL_PKGS")
[[ $n -eq 0 ]] ||
  fail "deck-install.packages names stock 'linux' as a bare entry -- the installed Deck must carry exactly ONE kernel, and two UKIs means Limine's ordering decides what boots instead of us"
n=$(awk '/^linux-neptune-[0-9]+$/ { n++ } END { print n+0 }' "$INSTALL_PKGS")
[[ $n -eq 1 ]] ||
  fail "deck-install.packages must name exactly ONE linux-neptune-* kernel" "found $n"
pass "the target install list names exactly one kernel, and it is not stock 'linux'"

echo "========================================================================"
echo "ALL deck-form.sh TESTS PASSED"
