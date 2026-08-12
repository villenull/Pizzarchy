#!/usr/bin/env bash
# Unit tests for src/deck-form.sh -- T4's installer screens (P2.5/P2.6).
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

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; [[ -n ${2:-} ]] && printf '%s\n' "$2" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# deck-form.sh does not `set -euo pipefail` itself (source-safety -- see its
# own header). Source it under THIS suite's stricter mode so a real bug
# (an unset variable, a broken pipe inside a function) still surfaces here,
# the same way test-installer-harness-primitives.sh sources
# vm-installer-screens.sh (which makes the identical -uo-only choice) under
# its own `set -euo pipefail`.
# shellcheck source=../../src/deck-form.sh
source "$REPO_ROOT/src/deck-form.sh"

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
source "$REPO_ROOT/src/deck-form.sh"
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
source "$REPO_ROOT/src/deck-form.sh"
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
out=$(STTY_MARKER="$work/stty.marker" PATH="$work/bin:$PATH" DECK_S0_TTY="$work/fake-tty-input" greeter)
[[ -f "$work/stty.marker" ]] ||
  fail "greeter must call 'stty sane' -- losing it silently kills every gum prompt after S0 (T4-screen-spec.md §4 S0)"
LC_ALL=C grep -qF "proprietary firmware" <<<"$out" ||
  fail "greeter's own output must include the S0 text, not just stty side effects"
pass "greeter calls 'stty sane' and prints the S0 disclosure text"

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

overrides=$(grep -oE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' "$REPO_ROOT/src/deck-form.sh" |
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
    LC_ALL=C grep -qE "^\s*${bad}=" "$REPO_ROOT/src/deck-form.sh" &&
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
# Stubs for upstream `configurator` helpers this file's screen OVERRIDES
# call but does not itself define -- clear_logo/say/step/abort/
# get_root_disk/get_disk_info are all real functions in the real
# `configurator` (READ this session), not in deck-form.sh, so sourcing
# deck-form.sh ALONE (this suite's whole point -- no VM, no real
# configurator) leaves them undefined. Minimal stand-ins, not
# reimplementations of upstream's real behaviour: just enough for
# confirm_disk_overwrite/disk_form/deck_final_summary to run to completion
# so THIS file's own logic (which is what this suite is actually proving)
# can be exercised. `abort` is deliberately non-fatal here (`return 1`, not
# upstream's real `exit 1`) so a path that reaches it fails an assertion
# instead of killing the whole test process.
# ===========================================================================

clear_logo() { :; }
say() { printf '%s\n' "$*" >>"${DECK_TEST_SAY_LOG:-/dev/null}"; }
step() { printf '%s\n' "$*" >>"${DECK_TEST_SAY_LOG:-/dev/null}"; }
abort() { printf 'ABORT: %s\n' "$*" >&2; return 1; }
get_root_disk() { printf '%s\n' "${DECK_TEST_ROOT_DISK:-}"; }
get_disk_info() { printf '%s\n' "$1"; }

# A dispatching fake `gum` -- confirm/choose/table only, everything else
# no-ops. Every real gum-driving function this suite exercises below
# (confirm_disk_overwrite, disk_form's picker branch, deck_final_summary's
# affirmative path) calls gum EXACTLY ONCE per test, never in a loop this
# fake could spin forever in -- the looping paths (deck_final_summary's
# decline branch, omarchy_prompt_timezone's interactive area/city picker,
# deck_form_disk_dead_end) are [V]-tier by this file's own design (same
# precedent as S8's failure_menu, which this suite also does not drive
# live) and are NOT exercised here.
mkdir -p "$work/bin-fakegum"
cat >"$work/bin-fakegum/gum" <<'FAKEGUM'
#!/usr/bin/env bash
sub=${1:-}
printf '%s\n' "$*" >>"${FAKE_GUM_LOG:-/dev/null}"
case "$sub" in
  confirm) exit "${FAKE_GUM_CONFIRM_RC:-0}" ;;
  choose)
    [[ -n ${FAKE_GUM_CHOOSE_RC:-} && ${FAKE_GUM_CHOOSE_RC} != 0 ]] && exit "$FAKE_GUM_CHOOSE_RC"
    printf '%s\n' "${FAKE_GUM_CHOOSE_OUTPUT:-}"
    exit 0
    ;;
  table) cat; exit 0 ;;
  *) exit 0 ;;
esac
FAKEGUM
chmod +x "$work/bin-fakegum/gum"

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

echo "========================================================================"
echo "ALL deck-form.sh TESTS PASSED"
