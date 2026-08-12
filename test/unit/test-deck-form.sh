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

for fn in _identity omarchy_prompt_identity; do
  declare -f "$fn" >/dev/null || fail "$fn must be defined (the spec's own two names disagree; both are covered)"
done
for fn in _hostname omarchy_prompt_hostname; do
  declare -f "$fn" >/dev/null || fail "$fn must be defined (the spec's own two names disagree; both are covered)"
done
pass "both name variants of the identity/hostname overrides are defined"

out=$(_hostname)
[[ $out == steamdeck ]] || fail "_hostname must output the constant hostname" "got: $out"
pass "_hostname outputs 'steamdeck' and prompts for nothing (no read, no blocking)"

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
# S8: Failure
# ===========================================================================

echo "--- S8 failure menu -------------------------------------------------------"

menu=$(deck_form_failure_menu_items)
if LC_ALL=C grep -qF "Drop to shell" <<<"$menu"; then
  fail "the failure menu must NEVER contain 'Drop to shell' (T4-screen-spec.md §4 S8 item 1)"
fi
LC_ALL=C grep -qF "Retry install" <<<"$menu" || fail "failure menu must offer Retry install"
LC_ALL=C grep -qF "Power off" <<<"$menu" || fail "failure menu must offer Power off"
pass "the failure menu has no shell escape and offers Retry/Power off"

got=$(deck_form_failure_action_for "")
[[ $got == redraw ]] || fail "a cancelled choose (empty) must map to 'redraw', never an action" "got: $got"
pass "cancel (Esc/B) maps to redraw, never to an action -- the exact fallback upstream gets wrong"

got=$(deck_form_failure_action_for "Retry install")
[[ $got == retry ]] || fail "'Retry install' must map to 'retry'" "got: $got"
pass "'Retry install' resolves to retry"

got=$(deck_form_failure_action_for "Power off")
[[ $got == poweroff ]] || fail "'Power off' must map to 'poweroff'" "got: $got"
pass "'Power off' resolves to poweroff"

got=$(deck_form_failure_action_for "something nobody put in the menu")
[[ $got == redraw ]] || fail "an unrecognised choice must map to 'redraw', never a guessed action" "got: $got"
pass "an unmapped choice redraws rather than being guessed at"

echo "--- S8 log fallback (no gum available) -------------------------------------"

printf 'line one\nline two\nline three\n' >"$work/install.log"
printf '\n' >"$work/fake-tty-input2"

# Build a PATH that genuinely has NO gum on it -- this dev machine has a
# real /usr/bin/gum, so merely listing /usr/bin would silently exercise the
# real `gum pager` instead of the fallback (and `gum pager` reading a file
# with no real terminal attached is not a thing this test wants to risk
# hanging on). Only what show_log's fallback actually needs (`tail`) is
# made reachable.
mkdir -p "$work/bin-nogum"
ln -sf "$(command -v tail)" "$work/bin-nogum/tail"
out=$(PATH="$work/bin-nogum" DECK_S0_TTY="$work/fake-tty-input2" deck_form_show_log "$work/install.log" 2>/dev/null)
LC_ALL=C grep -qF "line one" <<<"$out" || fail "show_log's fallback must actually show the log content" "$out"
LC_ALL=C grep -qF "Press A to continue" <<<"$out" || fail "show_log's fallback must show the 'press A to continue' prompt"
pass "show_log falls back to tail + 'press A to continue' when gum is unavailable"

echo "========================================================================"
echo "ALL deck-form.sh TESTS PASSED"
