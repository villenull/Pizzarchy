#!/usr/bin/env bash
# Unit tests for src/deck-session.sh -- the two contracts in it that are pure
# logic, and so need no Deck, no root and no VM.
#
#   1. The steamos-update stub's exit codes (stage_update_stub /
#      render_update_stub). They are a protocol Steam depends on: `check` and
#      the apply path must both exit 7, the capability probe must exit
#      non-zero, and an unrecognised verb must exit 7 *and* say so somewhere a
#      human can find. Two distinct failures sit behind these:
#
#        check drifting off 7   -> Steam's false "unable to download the
#                                  required updates -- check your network
#                                  connection" dialog, on the first screen a
#                                  new user ever sees (PROGRESS.md 5.14).
#        apply drifting to 0    -> Steam reads 0 as "an OS update was applied"
#                                  and REBOOTS to finish it. During OOBE it
#                                  calls apply directly without checking
#                                  first, so 0 is one reboot per pass -- a
#                                  boot loop caused by the stub that exists to
#                                  quiet a cosmetic error.
#
#      The evidence behind those two is asymmetric, and the assertions below
#      are only as strong as it is. That apply must not be 0 is direct
#      hardware evidence: Steam logged `steamos-update returned: 0` ->
#      `OS update result: 1` -> systemd-reboot, and the Deck rebooted. That 7
#      is the right replacement is a reasoned choice (SteamOS's "no update
#      available"), confirmed only on the `check` path, where Steam answers 7
#      with "up to date". Steam's reaction to 7 on the *apply* path has not
#      been observed -- after the fix, Steam only ever called check. So 7 is
#      settled as a decision, not as a measurement; that is the residual
#      unknown, and it is why these assert exactly 7 rather than merely
#      non-zero. Anything else non-zero would satisfy the hardware evidence
#      while silently drifting from the stage's own assertion.
#
#   2. assert_ours_or_absent's marker contract: a file carrying the install
#      marker may be overwritten on a re-run (the idempotency requirement),
#      and one without it must fail loudly rather than be silently clobbered.
#
#      These key on INSTALL_MARKER_TEXT -- the bare "installed-by:
#      deck-session.sh" with no comment prefix -- because that is what
#      assert_ours_or_absent greps, deliberately. The prefixed forms
#      (INSTALL_MARKER for shell/ini, INSTALL_MARKER_LUA for Hyprland's Lua)
#      are derived from it, and the split is load-bearing rather than
#      stylistic: a '#' on line 2 makes a Lua file a syntax error, and
#      Hyprland silently discards an unparseable config -- falls back to
#      defaults, logs nothing, exits 0. Both prefixes are exercised below.
#
# ---------------------------------------------------------------------------
# HOW THE ABSOLUTE PATHS ARE HANDLED -- the obstacle, and the tradeoff taken
# ---------------------------------------------------------------------------
#
# deck-session.sh's install paths are readonly absolutes
# (/usr/bin/steamos-polkit-helpers/steamos-update and friends), so a test
# cannot redirect them into a temp tree as they stand. Two ways out were
# available: make them env-overridable with an absolute default, or factor the
# generated body into a render function a test can call. This suite took the
# second, and deck-session.sh grew render_update_stub for it.
#
# The reason is that those paths are not configuration. Steam resolves
# steamos-polkit-helpers/* by ABSOLUTE path but steamos-session-select through
# PATH -- measured from Steam's own logs, see deck-session.sh's header -- so an
# env override pointed anywhere else would install a working-looking file where
# Steam never looks. That is precisely the silent-failure class this project
# exists to prevent, and it would be introduced *by the test seam*. Keeping the
# paths readonly forecloses it: render_update_stub needs no path at all, and
# assert_ours_or_absent already takes its path as an argument.
#
# The cost of that choice, stated plainly: this exercises the stub's body and
# the marker predicate, NOT the install steps wrapped around them
# (`install -o root`, the mkdir of POLKIT_HELPER_DIR, and stage_update_stub's
# own post-install re-run of the stub). Those need root and a real Deck path,
# and remain covered only by the stage's own check at install time.
#
# Also not covered: the steamos-session-select shim written by
# stage_steam_hook is still an inline heredoc, so its INSTALL_MARKER line is
# unverified here. Worth folding in if that stage is ever refactored the same
# way -- it carries the same clobber risk as the stub.

set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

# Sourcing, not running: deck-session.sh guards `main "$@"` on being executed
# directly, so this defines its functions and installs nothing.
#
# Exactly once, and at top level. Two properties of that file make a second
# source in the same shell fatal rather than idempotent: every constant is
# `readonly`, so re-assigning throws, and its own `set -euo pipefail` leaks
# into this shell, so the throw aborts the suite instead of being ignored.
# If a case below ever needs a fresh copy of its globals, run it in a subshell.
# shellcheck source=../../src/deck-session.sh
source "$REPO_ROOT/src/deck-session.sh"

# NOTE the name: the suites under test/unit/ call this helper `fail`, but
# deck-session.sh exports its own `fail` (print + exit 1) and
# assert_ours_or_absent calls it. Shadowing it would silently rewrite the
# behaviour under test, so this one suite deviates from the convention.
pass()      { printf 'ok - %s\n' "$1"; }
fail_test() { printf 'not ok - %s\n' "$1"; [[ -n ${2:-} ]] && printf '%s\n' "$2" >&2; exit 1; }

# Hard gate, not a courtesy: assert_ours_or_absent runs `$SUDO test`/`$SUDO
# grep`. deck-session.sh leaves SUDO empty until stage_preconditions sets it,
# and this suite never calls that -- but if that initialisation ever changes,
# this file would start invoking real sudo and could block on a password
# prompt in CI. Refuse to run rather than find out that way.
[[ -z ${SUDO:-} ]] ||
  fail_test "SUDO is '${SUDO}' after sourcing deck-session.sh; this suite must never invoke sudo"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# ===========================================================================
# 1. The steamos-update stub
# ===========================================================================

stub="$work/steamos-update"
render_update_stub >"$stub"
chmod +x "$stub"

# CI syntax-checks every *.sh tracked in git; this file is generated at
# install time and matches no glob, so nothing else ever parses it.
bash -n "$stub" 2>"$work/stderr" ||
  fail_test "render_update_stub emits syntactically valid bash" "$(cat "$work/stderr")"
pass "render_update_stub emits syntactically valid bash (checked nowhere else -- it is generated)"

# The stub is one of the files assert_ours_or_absent guards. If the marker
# ever fell out of the body, a second run of stage-update-stub would refuse to
# proceed, reporting that a real SteamOS updater owns the path.
#
# Both halves are checked: the bare text is what assert_ours_or_absent greps,
# and the '#' prefix is what keeps the stub valid bash. A marker carrying the
# right text with the wrong prefix is exactly the Lua defect in the other
# direction.
grep -qF -- "$INSTALL_MARKER_TEXT" "$stub" ||
  fail_test "the rendered stub carries the marker text" "expected: $INSTALL_MARKER_TEXT"
grep -qF -- "$INSTALL_MARKER" "$stub" ||
  fail_test "the stub's marker is '#'-commented, as a shell file needs" "expected: $INSTALL_MARKER"
pass "the rendered stub carries '${INSTALL_MARKER}' -- right text, right prefix for its language"

# A fake `logger` on PATH: keeps this suite out of the real journal, and makes
# the journal half of the not-silent contract observable. The stub's own
# comment is explicit that Steam discards its stderr, so the journal line is
# the only place a human can actually find the message.
fake_bin="$work/bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/logger" <<'FAKE_LOGGER'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$LOGGER_CAPTURE"
FAKE_LOGGER
chmod +x "$fake_bin/logger"
export LOGGER_CAPTURE="$work/logger.log"
: >"$LOGGER_CAPTURE"

stub_rc=0
run_stub() {
  stub_rc=0
  PATH="$fake_bin:$PATH" "$stub" "$@" >"$work/stdout" 2>"$work/stderr" || stub_rc=$?
}

# --- check: exit 7, the one code Steam's first-run flow depends on --------

run_stub check
[[ $stub_rc -eq 7 ]] ||
  fail_test "'check' exits 7 (already up to date)" "got ${stub_rc}; exit 0 would tell Steam an update IS available and it would immediately try to apply it"
pass "'check' exits 7 -- Steam's 'already up to date', the code the first-run dialog hinges on"

# --- the capability probe must decline ------------------------------------

run_stub --supports-duplicate-detection
[[ $stub_rc -ne 0 ]] ||
  fail_test "'--supports-duplicate-detection' exits non-zero (not supported)" "got 0, which claims a capability the stub does not implement"
pass "'--supports-duplicate-detection' declines with a non-zero exit rather than claiming a capability it lacks"

# --- apply and no-arg: exit 7, and emphatically NOT 0 ---------------------
#
# Exactly 7, not merely non-zero. The hardware evidence only rules out 0, but
# stage_update_stub's own post-install assertion and this suite must agree on
# the same number, or the stub could drift to some other non-zero value and
# still pass both. See the evidence note in the header.

run_stub
[[ $stub_rc -eq 7 ]] ||
  fail_test "no argument exits 7 (nothing to apply)" "got ${stub_rc}; 0 in particular means Steam reads it as 'update applied' and reboots the Deck, once per OOBE pass"
pass "no argument exits 7 -- 'nothing to apply', so Steam has nothing to finish and no reason to reboot"

run_stub apply
[[ $stub_rc -eq 7 ]] ||
  fail_test "'apply' exits 7 (nothing to apply)" "got ${stub_rc}; during OOBE Steam calls apply DIRECTLY without checking first, so 0 here is a boot loop"
pass "'apply' exits 7, not 0 -- the boot-loop defect measured on hardware (steamos-update returned: 0 -> systemd-reboot)"

# --- an unrecognised verb: exit 7, and NOT silently -----------------------

: >"$LOGGER_CAPTURE"
run_stub frobnicate
[[ $stub_rc -eq 7 ]] ||
  fail_test "an unrecognised verb exits 7" "got ${stub_rc}; an unanticipated verb from a future Steam client must not resurrect the first-run dialog"
pass "an unrecognised verb answers 'up to date' (exit 7) rather than erroring"

[[ -s $work/stderr ]] ||
  fail_test "an unrecognised verb is not answered silently" "stderr was empty -- CLAUDE.md's 'never silently swallow a failure'"
grep -q frobnicate "$work/stderr" ||
  fail_test "the note on stderr names the verb it did not recognise" "got: $(cat "$work/stderr")"
pass "an unrecognised verb writes a note to stderr naming the verb, instead of passing silently"

grep -q steamos-update-stub "$LOGGER_CAPTURE" ||
  fail_test "the unrecognised-verb note also reaches the journal" "logger was not called with -t steamos-update-stub; Steam discards stderr, so the journal is the only place a human sees this"
pass "the note also goes to the journal via logger -- the only place a human can find it, since Steam discards stderr"

# The note() helper ends in `return 0` precisely so a missing logger cannot
# change the exit code. Without it, `command -v logger` failing would be the
# function's status, `set -e` would fire, and the stub would exit 1 instead of
# 7 -- putting the first-run dialog back on any machine without util-linux's
# logger. Prove the codes survive its absence.
nologger="$work/nologger"
mkdir -p "$nologger"
ln -s "$(command -v bash)" "$nologger/bash"   # the #!/usr/bin/env shebang still needs to find bash
rc=0
PATH="$nologger" "$stub" frobnicate >/dev/null 2>/dev/null || rc=$?
[[ $rc -eq 7 ]] ||
  fail_test "an unrecognised verb still exits 7 when logger is absent" "got ${rc}; note() must not let a missing logger become the exit status"
pass "exit codes survive a missing logger -- note()'s 'return 0' is load-bearing under set -e"

# --- --help: exits 0 and does not drift from the real update command ------

run_stub --help
[[ $stub_rc -eq 0 ]] ||
  fail_test "'--help' exits 0" "got ${stub_rc}"
grep -qF -- "$REAL_UPDATE_HINT" "$work/stdout" ||
  fail_test "'--help' names the real way to update this system" "expected '${REAL_UPDATE_HINT}'; it is defined once so the stub, its --help and the installer cannot tell a user three different things"
pass "'--help' exits 0 and quotes '${REAL_UPDATE_HINT}' -- no drift from the one place the real update command is defined"

# ===========================================================================
# 2. assert_ours_or_absent -- the install-marker contract
# ===========================================================================

# --- absent: nothing to clobber, so proceed -------------------------------

# Subshells throughout: assert_ours_or_absent signals refusal through
# deck-session.sh's `fail`, which exits rather than returning. Called directly,
# an unexpected refusal would kill this suite mid-run with only deck-session's
# own error text and no 'not ok' line saying which contract broke.
( assert_ours_or_absent "$work/no-such-file" "a real SteamOS updater" ) ||
  fail_test "assert_ours_or_absent accepts a path that does not exist yet"
pass "assert_ours_or_absent accepts an absent path -- the first-install case"

# --- ours: carries the marker, so overwriting is the idempotent re-run ----

ours="$work/ours"
printf '#!/usr/bin/env bash\n%s\nexit 0\n' "$INSTALL_MARKER" >"$ours"
( assert_ours_or_absent "$ours" "a real SteamOS updater" ) ||
  fail_test "assert_ours_or_absent accepts a file carrying the install marker"
pass "assert_ours_or_absent accepts a '#'-commented marker -- re-runs may overwrite their own output"

# The prefix-agnostic half, and the reason the marker was split at all. A '#'
# in a Lua file is a syntax error, and Hyprland answers an unparseable config
# by silently falling back to defaults -- no log, exit 0. So the greeter's
# copy is commented '--', and the same predicate has to recognise it as ours.
ours_lua="$work/ours.lua"
printf '%s\nmonitor = { "eDP-1,preferred,auto,1" }\n' "$INSTALL_MARKER_LUA" >"$ours_lua"
( assert_ours_or_absent "$ours_lua" "omarchy-settings-dev" ) ||
  fail_test "assert_ours_or_absent accepts a '--'-commented Lua marker" "it greps INSTALL_MARKER_TEXT precisely so both comment styles count as ours"
pass "assert_ours_or_absent accepts a '--'-commented Lua marker too -- the split is why the greeter config stays parseable"

# End-to-end version of the same thing, with no hand-written fixture: what
# stage_update_stub actually installs must be re-accepted on the next run.
# This is the pair of contracts meeting, and the one a marker-string typo in
# either half would break.
( assert_ours_or_absent "$stub" "a real SteamOS updater" ) ||
  fail_test "assert_ours_or_absent accepts the stub that render_update_stub actually produces"
pass "assert_ours_or_absent accepts render_update_stub's real output -- the two halves agree on the marker string"

# --- theirs: no marker, so fail loudly rather than clobber ----------------

theirs="$work/theirs"
printf '#!/usr/bin/env bash\n# a real SteamOS updater\nexit 0\n' >"$theirs"
rc=0
( assert_ours_or_absent "$theirs" "a real SteamOS updater" ) 2>"$work/stderr" || rc=$?
[[ $rc -ne 0 ]] ||
  fail_test "assert_ours_or_absent rejects a file it did not write" "it returned 0 -- the caller would go on to silently clobber a file another package owns"
[[ -s $work/stderr ]] ||
  fail_test "assert_ours_or_absent fails LOUDLY on a foreign file" "it exited non-zero but said nothing"
grep -qF -- "$theirs" "$work/stderr" ||
  fail_test "the failure names the path that is in the way" "got: $(cat "$work/stderr")"
pass "assert_ours_or_absent refuses a file without the marker, and names it on stderr -- never a silent clobber"

# A file whose marker is close but not exact must still be refused. The match
# is prefix-agnostic, not fuzzy: grep -qF on the whole of INSTALL_MARKER_TEXT,
# so dropping the '.sh' makes it somebody else's file again.
nearly="$work/nearly"
printf '#!/usr/bin/env bash\n# installed-by: deck-session\nexit 0\n' >"$nearly"
rc=0
( assert_ours_or_absent "$nearly" "a real SteamOS updater" ) 2>/dev/null || rc=$?
[[ $rc -ne 0 ]] ||
  fail_test "assert_ours_or_absent rejects a near-miss marker" "'# installed-by: deck-session' (no .sh) was accepted as ours"
pass "assert_ours_or_absent rejects a near-miss marker rather than guessing it is ours"

echo "all deck-session.sh tests passed"
