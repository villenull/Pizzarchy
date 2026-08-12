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
# Closed in session 16: stage_steam_hook's shim used to be an inline heredoc
# and was this suite's last blind spot -- mutation testing confirmed deleting
# its INSTALL_MARKER was the one fault nothing here could see. It is now
# render_steam_shim and is covered in section 6.

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

# ===========================================================================
# 3. steamos-set-timezone -- argument validation
# ===========================================================================
#
# The privilege boundary, not a nicety. The sudoers drop-in this helper relies
# on grants NOPASSWD on '/usr/bin/timedatectl set-timezone *' -- a wildcard --
# so whatever survives the checks below is what runs as root. Steam only ever
# sends names out of its own list (measured: 28 calls in one OOBE pass, always
# one positional argument like 'America/Chicago'), but a helper sitting behind
# a sudo grant has to be correct for arguments Steam would never send.
#
# Everything here stops BEFORE the sudo line, so no case in this section can
# change the timezone of the machine running the suite.

tz_helper="$work/steamos-set-timezone"
render_timezone_helper >"$tz_helper"
chmod +x "$tz_helper"

bash -n "$tz_helper" 2>"$work/stderr" ||
  fail_test "render_timezone_helper emits syntactically valid bash" "$(cat "$work/stderr")"
pass "render_timezone_helper emits syntactically valid bash (checked nowhere else -- it is generated)"

grep -qF -- "$INSTALL_MARKER" "$tz_helper" ||
  fail_test "the rendered timezone helper carries the '#'-commented marker" "expected: $INSTALL_MARKER"
pass "the rendered timezone helper carries '${INSTALL_MARKER}' -- so a re-run may replace its own output"

tz_rc=0
run_tz() {
  tz_rc=0
  PATH="$fake_bin:$PATH" "$tz_helper" "$@" >"$work/stdout" 2>"$work/stderr" || tz_rc=$?
}

# --- the shapes that must be refused before anything is elevated ----------
#
# Each is checked for a non-zero exit AND a message. A helper that refused
# quietly would leave the picker looking broken for no discoverable reason,
# which is the same silent failure as not being installed at all.

run_tz
[[ $tz_rc -eq 2 ]] ||
  fail_test "no argument exits 2" "got ${tz_rc}"
[[ -s $work/stderr ]] ||
  fail_test "a missing argument is not refused silently" "stderr was empty"
pass "no argument exits 2 and says so"

# The message is asserted, not just the exit code, and that is the whole point
# of these cases. The zoneinfo check further down refuses most of these too,
# with the SAME exit 3 -- so an exit-code-only assertion passes with the '..'
# guard deleted (confirmed by mutation). Requiring the word 'containing' pins
# which guard fired.
for bad in "../../etc/shadow" "Europe/../../../etc/shadow" ".." "America/.."; do
  run_tz "$bad"
  [[ $tz_rc -eq 3 ]] ||
    fail_test "a '..' timezone is refused with exit 3" "got ${tz_rc} for '${bad}'"
  grep -q "containing" "$work/stderr" ||
    fail_test "the '..' guard is what refused it, not a later check" "got: $(cat "$work/stderr") for '${bad}'; an exit-code-only assertion here would still pass with the guard deleted"
done
pass "traversal arguments are refused BY THE '..' GUARD (message asserted, so deleting the guard fails this)"

# The case that only the '..' guard can catch. '../zoneinfo/UTC' passes the
# character class, and /usr/share/zoneinfo/../zoneinfo/UTC RESOLVES TO A REAL
# FILE -- so the zoneinfo test accepts it and it would reach the sudo wildcard
# as-is. Without the guard this is the one that gets through.
run_tz "../zoneinfo/UTC"
[[ $tz_rc -eq 3 ]] ||
  fail_test "'../zoneinfo/UTC' is refused" "got ${tz_rc}; it passes the character class AND resolves to a real zoneinfo file, so ONLY the '..' guard stands between it and the sudo wildcard"
pass "'../zoneinfo/UTC' is refused -- it resolves to a real file, so the '..' guard is load-bearing here, not decorative"

run_tz "/etc/shadow"
[[ $tz_rc -eq 3 ]] ||
  fail_test "an absolute path is refused with exit 3" "got ${tz_rc}"
pass "an absolute path is refused rather than passed through as a zone name"

# Shell metacharacters. These would be inert anyway -- the helper always quotes
# "$tz" -- but the check documents that the helper does not depend on that
# quoting alone for its safety.
# Again the message, not just the code. The zoneinfo check refuses all of
# these too (none of them names a real file), so an exit-code-only assertion
# passes with the character class deleted -- confirmed by mutation. Requiring
# 'unexpected characters' pins the early guard, and also pins the DIAGNOSTIC:
# telling a user their timezone is malformed is not the same as telling them
# it does not exist on this system.
# shellcheck disable=SC2016  # NOT expanding is the point: these are the literal
# injection strings the guard must reject. Double quotes would run `id` here.
for bad in 'Foo$(id)' 'Foo;id' 'Foo`id`' 'Foo id' 'Foo|id' $'Foo\nBar'; do
  run_tz "$bad"
  [[ $tz_rc -eq 3 ]] ||
    fail_test "a timezone with shell metacharacters is refused with exit 3" "got ${tz_rc} for '${bad}'"
  grep -q "unexpected characters" "$work/stderr" ||
    fail_test "the character-class check is what refused it, not the later zoneinfo test" "got: $(cat "$work/stderr") for '${bad}'"
done
pass "shell metacharacters are refused BY THE CHARACTER CLASS (message asserted), so the guard cannot be deleted silently"

# A well-formed name that this system does not have. Distinct from the cases
# above: it passes every syntactic check and is caught only by the zoneinfo
# test, which is the one that decides whether timedatectl gets called.
run_tz "Not/AZone"
[[ $tz_rc -eq 3 ]] ||
  fail_test "a well-formed but nonexistent zone is refused with exit 3" "got ${tz_rc}"
grep -q "Not/AZone" "$work/stderr" ||
  fail_test "the refusal names the zone that does not exist" "got: $(cat "$work/stderr")"
pass "a well-formed but nonexistent zone is refused by the /usr/share/zoneinfo check"

# --- and the shape that must be ACCEPTED ---------------------------------
#
# Proven without running sudo: a real zone gets past every check above and
# reaches the elevation line, where a stub sudo records what it was asked to
# do. Without this, every assertion in this section would still pass if the
# helper rejected everything.
cat >"$fake_bin/sudo" <<'FAKE_SUDO'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SUDO_CAPTURE"
exit 0
FAKE_SUDO
chmod +x "$fake_bin/sudo"
export SUDO_CAPTURE="$work/sudo.log"
: >"$SUDO_CAPTURE"

real_tz=UTC
[[ -f /usr/share/zoneinfo/$real_tz ]] ||
  fail_test "the suite's own fixture zone exists" "/usr/share/zoneinfo/${real_tz} is missing, so the accept case cannot be tested here"

run_tz "$real_tz"
[[ $tz_rc -eq 0 ]] ||
  fail_test "a real timezone is accepted" "got ${tz_rc}; stderr: $(cat "$work/stderr")"
grep -q "set-timezone ${real_tz}" "$SUDO_CAPTURE" ||
  fail_test "an accepted timezone reaches the elevation line" "sudo was called with: $(cat "$SUDO_CAPTURE")"
grep -q -- "-n" "$SUDO_CAPTURE" ||
  fail_test "the helper elevates with 'sudo -n'" "without -n a refused grant would BLOCK on a password prompt Steam cannot render; got: $(cat "$SUDO_CAPTURE")"
pass "a real timezone reaches 'sudo -n ... set-timezone ${real_tz}' -- the accept path works, and cannot block on a prompt"

# ===========================================================================
# 4. steamos-priv-write -- the path whitelist
# ===========================================================================
#
# This one carries the most risk in the file. The sudoers grant behind it
# covers the binary with ANY arguments, so the whitelist below is the entire
# boundary between an unprivileged caller and a root write. Every case here is
# about what must NOT get through.
#
# All of these stop before the sudo line, so nothing in this section writes to
# any real system node.

pw_helper="$work/steamos-priv-write"
render_priv_write_helper >"$pw_helper"
chmod +x "$pw_helper"

bash -n "$pw_helper" 2>"$work/stderr" ||
  fail_test "render_priv_write_helper emits syntactically valid bash" "$(cat "$work/stderr")"
pass "render_priv_write_helper emits syntactically valid bash (checked nowhere else -- it is generated)"

grep -qF -- "$INSTALL_MARKER" "$pw_helper" ||
  fail_test "the rendered priv-write helper carries the '#'-commented marker" "expected: $INSTALL_MARKER"
pass "the rendered priv-write helper carries '${INSTALL_MARKER}'"

pw_rc=0
run_pw() {
  pw_rc=0
  PATH="$fake_bin:$PATH" "$pw_helper" "$@" >"$work/stdout" 2>"$work/stderr" || pw_rc=$?
}

run_pw
[[ $pw_rc -eq 2 ]] ||
  fail_test "no path exits 2" "got ${pw_rc}"
pass "no path argument exits 2"

# --- paths that must be refused ------------------------------------------
#
# The traversal cases matter more than they look. bash's case globs let '*'
# span '/', so a pattern like /sys/class/backlight/*/brightness would happily
# match /sys/class/backlight/../../../etc/passwd/brightness. The helper
# rejects '..' outright for exactly that reason; if that guard is ever removed
# these are what catch it.
for bad_path in \
  /etc/shadow \
  /etc/passwd \
  /sys/class/backlight/../../../etc/passwd/brightness \
  /sys/class/backlight/amdgpu_bl0/bl_power \
  /sys/class/leds/status:white/brightness \
  /sys/power/state \
  /dev/drm_dp_aux0 \
  /sys/class/backlight/amdgpu_bl0/brightness/../../../../etc/x
do
  run_pw "$bad_path" 100
  [[ $pw_rc -eq 3 ]] ||
    fail_test "a non-whitelisted path is refused with exit 3" "got ${pw_rc} for '${bad_path}'"
  [[ -s $work/stderr ]] ||
    fail_test "a refused path is not refused silently" "stderr empty for '${bad_path}'"
  grep -qF -- "$bad_path" "$work/stderr" ||
    fail_test "the refusal names the path it refused" "got: $(cat "$work/stderr") for '${bad_path}'"
  grep -q steamos-priv-write "$LOGGER_CAPTURE" ||
    fail_test "the refusal also reaches the journal" "logger was not called; Steam discards stderr, so the journal is the only place a human sees this"
done
pass "eight non-whitelisted paths are all refused with exit 3, each naming the path on stderr and in the journal"

# The two cases only the '..' guard catches. Both MATCH the whitelist regex:
# '..' satisfies the [A-Za-z0-9_.:+-]+ component class, so
# /sys/class/backlight/../brightness is a well-formed whitelisted shape as far
# as the pattern is concerned. Deleting the guard lets these through to the
# root write -- confirmed by mutation, which the multi-segment cases above did
# NOT catch because they fail the pattern anyway.
for traversal in \
  /sys/class/backlight/../brightness \
  /sys/class/leds/../led_brightness_multiplier
do
  run_pw "$traversal" 100
  [[ $pw_rc -eq 3 ]] ||
    fail_test "a single-component '..' path is refused" "got ${pw_rc} for '${traversal}'; '..' matches the whitelist's component class, so ONLY the '..' guard refuses this"
  grep -q "containing" "$work/stderr" ||
    fail_test "the '..' guard is what refused it, not the whitelist pattern" "got: $(cat "$work/stderr") for '${traversal}'"
done
pass "single-component '..' paths are refused BY THE '..' GUARD -- they match the whitelist pattern, so the guard is the only thing stopping them"

# /sys/class/leds/*/brightness is in that list deliberately, and is the case
# most likely to be 'fixed' by someone widening the pattern. Steam asks for
# led_brightness_multiplier, which is what the whitelist allows; the plain
# brightness node of an arbitrary LED is not the same permission.
pass "note: /sys/class/leds/*/brightness stays refused -- only led_brightness_multiplier is whitelisted, which is what Steam actually asks for"

# --- values that must be refused ------------------------------------------
#
# Every whitelisted node takes an unsigned integer. The empty case is real,
# not theoretical: Steam sends an empty value for /dev/drm_dp_aux0.
# shellcheck disable=SC2016  # '$(id)' must stay literal -- it is the payload
# the value guard has to reject, not something to evaluate here.
for bad_value in "" "abc" "-1" "1.5" "12 34" '$(id)' "0x10" " 5"; do
  run_pw /sys/class/backlight/amdgpu_bl0/brightness "$bad_value"
  [[ $pw_rc -eq 4 ]] ||
    fail_test "a non-integer value is refused with exit 4" "got ${pw_rc} for value '${bad_value}'"
done
pass "eight non-integer values (empty, negative, float, hex, spaced, substitution) are refused with exit 4"

# --- the shapes that must be ACCEPTED -------------------------------------
#
# Same reasoning as the timezone accept case: without this, a helper that
# refused everything would pass every assertion above. The fake sudo proves
# the call reaches elevation with the arguments intact.
: >"$SUDO_CAPTURE"
run_pw /sys/class/backlight/amdgpu_bl0/brightness 39638
[[ $pw_rc -eq 0 ]] ||
  fail_test "a whitelisted backlight path with an integer value is accepted" "got ${pw_rc}; stderr: $(cat "$work/stderr")"
grep -q "/sys/class/backlight/amdgpu_bl0/brightness 39638" "$SUDO_CAPTURE" ||
  fail_test "the accepted write reaches the elevation line with its arguments intact" "sudo got: $(cat "$SUDO_CAPTURE")"
grep -q -- "-n" "$SUDO_CAPTURE" ||
  fail_test "the helper elevates with 'sudo -n'" "without -n a refused grant would BLOCK, and Steam calls this on every slider movement; got: $(cat "$SUDO_CAPTURE")"
pass "the measured backlight call (path + 39638) is accepted and reaches 'sudo -n' with arguments intact"

# The colon in 'status:white' is why the whitelist's character class carries
# one. A class of [A-Za-z0-9_.-] would refuse the real LED node.
: >"$SUDO_CAPTURE"
run_pw /sys/class/leds/status:white/led_brightness_multiplier 100
[[ $pw_rc -eq 0 ]] ||
  fail_test "the measured LED call is accepted" "got ${pw_rc}; the real node name contains a colon ('status:white'), so the whitelist's character class must allow one"
pass "the measured LED call (status:white/led_brightness_multiplier + 100) is accepted -- the colon in the node name is handled"

# Zero is a legitimate brightness and must not be mistaken for an empty value.
: >"$SUDO_CAPTURE"
run_pw /sys/class/backlight/amdgpu_bl0/brightness 0
[[ $pw_rc -eq 0 ]] ||
  fail_test "a zero value is accepted" "got ${pw_rc}; 0 is a legal brightness and must not be conflated with the empty string"
pass "a zero value is accepted -- not conflated with the empty string that Steam sends for other paths"

# ===========================================================================
# 5. restart-sddm -- the transient unit's body (PROGRESS.md 5.16)
# ===========================================================================
#
# This one cannot be run for real here: it stops and starts a display manager.
# What IS checkable without hardware is its shape, and the shape is where the
# recorded bug lived -- the original code said `systemctl restart sddm`, which
# issues the start as soon as the stop job completes, 3ms after a SIGKILL in
# the failure that was measured. So: stop and start must be SEPARATE commands,
# in that order, with a bounded wait between them.

rs_helper="$work/restart-sddm"
# Explicit user argument: the default exists only so this call cannot blow up
# under `set -u`, and passing one proves it is threaded into the body rather
# than silently dropped.
render_restart_helper soaktestuser >"$rs_helper"
chmod +x "$rs_helper"

bash -n "$rs_helper" 2>"$work/stderr" ||
  fail_test "render_restart_helper emits syntactically valid bash" "$(cat "$work/stderr")"
pass "render_restart_helper emits syntactically valid bash (checked nowhere else -- it is generated)"

grep -qF -- "$INSTALL_MARKER" "$rs_helper" ||
  fail_test "the rendered restart helper carries the '#'-commented marker" "expected: $INSTALL_MARKER"
pass "the rendered restart helper carries '${INSTALL_MARKER}'"

# This body is an UNQUOTED heredoc, so every backtick and $( in it is live
# command substitution at render time, running as root during a stage install.
# One comment shipped with unescaped backticks and actually executed
# `uwsm start ... Hyprland` on the Deck; the installed file carried the empty
# result ("# session's  exit in ~1ms."). Found 2026-08-10 by shellcheck SC2006,
# confirmed against the generated file on hardware.
#
# Assert on the literal text rather than on "no double space": the latter would
# pass for any other command whose output happened to be non-empty.
grep -qF -- 'uwsm start ... Hyprland' "$rs_helper" ||
  fail_test "the helper's comments must survive the heredoc literally" \
    "the backticks in that comment were substituted at render time instead of being escaped -- the unquoted heredoc executed them"
pass "comment backticks are escaped, so nothing in the rendered body executes at render time"

# The regression this file exists to prevent. `systemctl restart sddm` is
# exactly what left the Deck with no session.
grep -qE '^\s*(if !\s*)?systemctl restart sddm' "$rs_helper" &&
  fail_test "the helper must NOT use 'systemctl restart sddm'" "that issues the start as soon as the stop job finishes -- 3ms after a SIGKILL when the teardown times out, which is the measured failure in PROGRESS.md 5.16"
pass "the helper does not use 'systemctl restart sddm' -- the exact call that latched sddm into permanent failure"

grep -q "systemctl stop sddm" "$rs_helper" ||
  fail_test "the helper stops sddm explicitly"
grep -q "systemctl start sddm" "$rs_helper" ||
  fail_test "the helper starts sddm explicitly"
stop_ln=$(grep -n "systemctl stop sddm"  "$rs_helper" | head -1 | cut -d: -f1)
start_ln=$(grep -n "systemctl start sddm" "$rs_helper" | head -1 | cut -d: -f1)
[[ $stop_ln -lt $start_ln ]] ||
  fail_test "the stop must precede the start" "stop at line ${stop_ln}, start at line ${start_ln}"
pass "stop and start are separate commands in that order, so a settle step can sit between them"

# The settle wait has to be BETWEEN them to do anything, and it has to key on
# logind rather than fuser: systemd-logind holds /dev/tty1 permanently, so a
# fuser-based check would report the VT busy forever and the loop would always
# run to its bound.
seat_ln=$(grep -n "loginctl show-seat seat0" "$rs_helper" | head -1 | cut -d: -f1)
[[ -n $seat_ln ]] ||
  fail_test "the helper waits on logind's view of seat0" "without a wait between stop and start this is just a slower 'restart'"
[[ $stop_ln -lt $seat_ln && $seat_ln -lt $start_ln ]] ||
  fail_test "the settle wait sits between the stop and the start" "stop ${stop_ln}, seat check ${seat_ln}, start ${start_ln}"
pass "the seat0 settle wait sits between the stop and the start, where it can actually delay the start"

# Comment lines stripped first: the helper's own comment names fuser to explain
# why it is not used, and matching that would fail on the documentation rather
# than the code.
grep -vE '^\s*#' "$rs_helper" | grep -q "fuser" &&
  fail_test "the helper must not CALL fuser to decide the VT is free" "systemd-logind holds /dev/tty1 permanently, so fuser always reports it busy -- measured on hardware"
pass "no fuser call in the code -- logind holds /dev/tty1 permanently, so fuser can never report the VT free"

# Bounded, always. An unbounded wait for a stuck seat means sddm is never
# started again, which is the same black screen by a different route.
grep -qE "while \[\[ \\\$i -lt [0-9]+ \]\]" "$rs_helper" ||
  fail_test "the settle loop is bounded by a numeric limit" "an unbounded wait on a stuck seat never starts sddm again -- the same black screen this file exists to prevent"
pass "the settle loop is bounded by a literal count, so a stuck seat cannot mean sddm is never restarted"

# And the bound must not be a silent give-up: reaching it still starts sddm,
# and says so.
awk -v s="$start_ln" 'NR<s && /settled -eq 1/{f=1} END{exit !f}' "$rs_helper" ||
  fail_test "the helper distinguishes 'settled' from 'gave up waiting'" "both paths must reach the start, but only one of them is normal"
pass "the helper reports whether the seat settled or the bound was hit, and starts sddm either way"

# --- PROGRESS.md 5.18(a): an empty seat list is NOT 'the session is gone' ----
#
# On soak cycle 4 the seat list was already empty while the previous session's
# uwsm/Hyprland was still exiting; sddm started the next session into that and
# it died one millisecond later. So the gate has to check BOTH.

grep -q "pgrep" "$rs_helper" ||
  fail_test "the settle gate checks for surviving compositor processes" "an empty logind seat list is not the same as the outgoing session being finished -- that is exactly what made soak cycle 4 fail"
# Matched against the pgrep line itself, not the whole file: these names also
# appear in the helper's comments, and a whole-file grep passes on the prose
# while the code has stopped checking for them. (Found by mutation -- dropping
# uwsm from the pattern was not caught until this was narrowed.)
pgrep_line=$(grep -E '^\s*pgrep ' "$rs_helper")
[[ -n $pgrep_line ]] ||
  fail_test "the settle gate has a pgrep line to check"

# comm NAMES, measured on hardware -- not binary names. The kernel truncates
# comm to 15 chars and `pgrep -x` matches comm, so 'gamescope' (the binary)
# matches NOTHING: the compositor's comm is 'gamescope-wl' and its launcher is
# 'start-gamescope'. The first version of this gate listed 'gamescope' and was
# a silent no-op for the entire Gaming Mode direction.
for proc in Hyprland start-hyprland gamescope-wl start-gamescope uwsm; do
  grep -qF -- "$proc" <<<"$pgrep_line" ||
    fail_test "the settle gate's pgrep pattern includes '${proc}'" "measured comm name; without it the gate silently matches nothing for that session type. pgrep line: ${pgrep_line}"
done

# The specific regression: bare 'gamescope' as a standalone alternative matches
# no real process. Catching it needs a word-boundary check, since the correct
# names contain 'gamescope' as a substring.
grep -qE "[|']gamescope[|']" <<<"$pgrep_line" &&
  fail_test "the gate must not match on bare 'gamescope'" "no process has that comm -- the compositor is 'gamescope-wl'. A bare 'gamescope' alternative is the no-op that shipped and had to be corrected. pgrep line: ${pgrep_line}"
pass "the pgrep pattern uses measured comm names for BOTH sessions, and not the bare binary name 'gamescope' which matches no process"

# shellcheck disable=SC2016  # a grep PATTERN: the \$ matches a literal dollar
# in the generated helper's source, which is exactly what is being pinned.
grep -qE 'pgrep -u "\$session_user" -x' "$rs_helper" ||
  fail_test "the process check is scoped to the desktop user AND exact-matched" "-u keeps it from matching another user's processes; -x keeps 'gamescope' from matching a window title or wrapper script"
pass "the process check is both user-scoped (-u) and exact (-x), so it cannot match a wrapper or another user"

# The rendered user must be the one that was passed in, not whatever the
# rendering shell happened to be running as.
grep -q "^session_user=soaktestuser$" "$rs_helper" ||
  fail_test "render_restart_helper threads its user argument into the body" "got: $(grep '^session_user=' "$rs_helper")"
pass "render_restart_helper bakes in the user it was given, not the rendering shell's own user"

# Both conditions must be able to fail the check independently -- an 'or' here
# would make the seat test pointless the moment no compositor was running.
grep -q "return 1" "$rs_helper" ||
  fail_test "the settle predicate can reject on either condition"
[[ $(grep -c "return 1" "$rs_helper") -ge 2 ]] ||
  fail_test "each settle condition rejects independently" "only one 'return 1' found; an or-style check would let an empty seat list alone satisfy the gate, which is the 5.18 defect"
pass "the seat-list and process conditions each reject independently, so neither alone can satisfy the gate"

# --- the third condition: 5.18(a)'s actual root cause (R-28) --------------
#
# steam-launcher.service is PartOf=graphical-session.target with
# TimeoutStopSec=60, and Steam takes ~29s to exit. It owns no logind session and
# its processes are not named after a compositor, so BOTH conditions above are
# blind to it -- which is why the first two versions of this gate did not stop
# the thrash.

# WIRED IN, not merely defined. Grepping the whole file for the function name
# passes while the gate never calls it -- caught by mutation, and it is the same
# presence-vs-wiring trap as the earlier comment-matching assertions.
outgoing_body=$(awk '/^outgoing_gone\(\) \{/,/^\}/' "$rs_helper")
[[ -n $outgoing_body ]] ||
  fail_test "outgoing_gone() is present in the rendered helper"
grep -q "user_manager_busy" <<<"$outgoing_body" ||
  fail_test "outgoing_gone() actually CALLS user_manager_busy" "steam-launcher.service is a UNIT, invisible to a process check and to logind's seat list. Defining the function without calling it leaves the 5.18(a) thrash exactly as it was. Body: ${outgoing_body}"
grep -q -- "--state=deactivating" "$rs_helper" ||
  fail_test "the user-manager condition asks for deactivating units" "a unit mid-teardown is exactly the window that kills the incoming session"
grep -qE -- '--machine="\$\{session_user\}@\.host"' "$rs_helper" ||
  fail_test "the user-manager query targets the desktop user's manager" "the helper runs as root in a transient unit, so it must reach the user bus explicitly"
pass "the gate waits for the user manager to have no deactivating units -- R-28's steam-launcher teardown, invisible to the other two conditions"

# All three must reject independently.
[[ $(grep -c "return 1" "$rs_helper") -ge 3 ]] ||
  fail_test "each of the three settle conditions rejects independently" "found fewer than three 'return 1' paths"
pass "all three settle conditions reject independently"

# A failed query must be reported, not silently treated as 'nothing to wait
# for'. That would restore the pre-R-28 behaviour with no trace.
# Specifically the FAILURE branch. The flag name appears in several places, so
# a whole-file grep passes even when the failing path stops recording it.
umb_body=$(awk '/^user_manager_busy\(\) \{/,/^\}/' "$rs_helper")
grep -q "USER_MANAGER_QUERY_OK=0" <<<"$umb_body" ||
  fail_test "a FAILED user-manager query records itself as failed" "without it the query silently degrades to 'nothing deactivating' and the thrash returns with no trace. Body: ${umb_body}"
grep -q "USER_MANAGER_QUERY_OK=1" <<<"$umb_body" ||
  fail_test "a successful user-manager query records itself as succeeded" "otherwise the note cannot distinguish 'ran and found nothing' from 'never ran'"
grep -q "did NOT run" "$rs_helper" ||
  fail_test "a failed user-manager query is reported to the journal" "CLAUDE.md: never silently swallow a failure"
pass "a failed user-manager query is journalled rather than silently passing the gate"

# The bound must cover steam-launcher's own TimeoutStopSec, or the gate gives
# up while systemd is still waiting and hands the thrash straight back.
bound=$(grep -oE 'i -lt [0-9]+' "$rs_helper" | grep -oE '[0-9]+')
[[ -n $bound && $bound -ge 600 ]] ||
  fail_test "the settle bound covers steam-launcher's TimeoutStopSec=60s" "got ${bound} tenths of a second; giving up before systemd does returns the problem to the autologin retry loop"
pass "the settle bound (${bound} tenths = $((bound / 10))s) covers steam-launcher.service's own TimeoutStopSec=60"

# ===========================================================================
# 6. render_steam_shim -- the file Steam actually invokes
# ===========================================================================
#
# Small, but it is the entire call path from Steam's Power menu to
# deck-session-select, and two of its four lines are load-bearing in ways that
# are invisible from a shell.

shim="$work/steamos-session-select"
render_steam_shim >"$shim"
chmod +x "$shim"

bash -n "$shim" 2>"$work/stderr" ||
  fail_test "render_steam_shim emits syntactically valid bash" "$(cat "$work/stderr")"
pass "render_steam_shim emits syntactically valid bash (checked nowhere else -- it is generated)"

# The blind spot this section exists to close.
grep -qF -- "$INSTALL_MARKER_TEXT" "$shim" ||
  fail_test "the shim carries the install marker" "without it a re-run of stage-steam-hook refuses to proceed, reporting that something else owns /usr/bin/steamos-session-select"
grep -qF -- "$INSTALL_MARKER" "$shim" ||
  fail_test "the shim's marker is '#'-commented, as a shell file needs" "expected: $INSTALL_MARKER"
( assert_ours_or_absent "$shim" "DeckShift or SteamOS customizations" ) ||
  fail_test "assert_ours_or_absent accepts the shim render_steam_shim actually produces"
pass "the shim carries the marker and is re-accepted by assert_ours_or_absent -- the gap mutation testing found in session 16"

# -n is what keeps a missing sudo grant from HANGING Steam rather than failing
# it. Steam cannot render a password prompt, so a blocking sudo is a hung
# Power menu with no feedback at all.
grep -qE '^exec sudo -n ' "$shim" ||
  fail_test "the shim elevates with 'exec sudo -n'" "without -n, a missing or broken sudoers grant makes this BLOCK on a password prompt Steam cannot display; got: $(grep sudo "$shim")"
pass "the shim uses 'exec sudo -n' -- it can fail, but it can never hang waiting for a password Steam cannot show"

# It must invoke the absolute path, not a bare name. Steam's runtime PATH is
# only /usr/bin:/bin, and SELECT_BIN lives in /usr/local/bin -- so a bare name
# here would resolve for a human testing by hand and fail for Steam. That is
# the exact defect PROGRESS.md 5.10 spent a session finding.
grep -qF -- "$SELECT_BIN" "$shim" ||
  fail_test "the shim calls SELECT_BIN by absolute path" "Steam's runtime PATH is ${STEAM_RUNTIME_PATH}, which does not contain $(dirname "$SELECT_BIN") -- a bare name would work by hand and silently fail for Steam"
pass "the shim calls ${SELECT_BIN} by absolute path -- ${STEAM_RUNTIME_PATH} would never resolve a bare name there"

# Arguments must reach deck-session-select intact: Steam passes the target
# session as $1 ('plasma', per PROGRESS.md 5.10), so dropping "$@" would make
# every switch a no-argument call.
grep -qE 'exec sudo -n .* "\$@"' "$shim" ||
  fail_test "the shim forwards its arguments" "Steam passes the target session as an argument; without \"\$@\" deck-session-select is called with none and dies on 'no session specified'"
pass "the shim forwards \"\$@\" -- Steam passes the target session ('plasma') as an argument"

# ===========================================================================
# 7. sudoers_line_is_blanket -- the release check's predicate (PROGRESS.md 5.17)
# ===========================================================================
#
# The whole point of this predicate is that it flags ONLY the honest case, a
# command spec of ALL. It deliberately does not try to judge whether a named
# command is dangerous, because that judgement is hopeless: this project's own
# sudo audit trail shows the install stages running `install` against
# /etc/sudoers.d/ itself, so a NOPASSWD grant on install/tee/cp/chmod is full
# root by a longer route. A predicate that pretended otherwise would give false
# assurance, which is worse than none.

blanket_yes=(
  "deck ALL=(ALL) NOPASSWD: ALL"
  "deck ALL=(ALL) ALL"
  "%wheel ALL=(ALL:ALL) ALL"
  "  deck   ALL=(root)   NOPASSWD:   ALL   "
  "deck ALL=(ALL) NOPASSWD: ALL # trailing comment"
)
for line in "${blanket_yes[@]}"; do
  sudoers_line_is_blanket "$line" ||
    fail_test "recognises a blanket grant" "missed: ${line}"
done
pass "recognises blanket grants, including extra whitespace, runas lists and trailing comments"

blanket_no=(
  "deck ALL=(root) NOPASSWD: /usr/local/bin/deck-session-select"
  "deck ALL=(root) NOPASSWD: /usr/bin/timedatectl set-timezone *"
  "%wheel ALL=(root) NOPASSWD: /usr/bin/tzupdate, /usr/bin/timedatectl set-timezone *"
  "Defaults passwd_tries=10"
  "Defaults env_reset"
  "# deck ALL=(ALL) NOPASSWD: ALL"
  ""
  "   "
)
for line in "${blanket_no[@]}"; do
  ! sudoers_line_is_blanket "$line" ||
    fail_test "does not flag a scoped grant, a Defaults line, a comment or a blank" "wrongly flagged: '${line}'"
done
pass "does not flag scoped grants, Defaults lines, commented-out grants or blank lines"

# The four grants this project actually installs must all read as scoped --
# if any of them tripped the release check, the check would be unusable.
for line in \
  "deck ALL=(root) NOPASSWD: /usr/local/bin/deck-session-select" \
  "deck ALL=(root) NOPASSWD: /usr/bin/steamos-polkit-helpers/steamos-priv-write" \
  "deck ALL=(root) NOPASSWD: /usr/bin/timedatectl set-timezone *"
do
  ! sudoers_line_is_blanket "$line" ||
    fail_test "this project's own grants read as scoped" "flagged its own grant: ${line}"
done
pass "the grants this project installs all read as scoped, so the release check is usable as-is"

# The two predicates combine, and getting the combination wrong is what makes a
# release check get ignored. `deck ALL=(ALL) ALL` is blanket but
# password-protected -- the ordinary admin grant every Arch/Omarchy install
# ships. Failing a release on that is a false positive; only blanket AND
# passwordless is the hazard. Found by running the real check against the Deck,
# which flagged 03_deck on the first attempt.
sudoers_line_is_nopasswd "deck ALL=(ALL) NOPASSWD: ALL" ||
  fail_test "recognises NOPASSWD"
! sudoers_line_is_nopasswd "deck ALL=(ALL) ALL" ||
  fail_test "does not treat a password-required grant as NOPASSWD" "this is the ordinary admin grant; flagging it is the false positive that gets the check ignored"
! sudoers_line_is_nopasswd "# deck ALL=(ALL) NOPASSWD: ALL" ||
  fail_test "a commented-out NOPASSWD grant is not a grant"
pass "NOPASSWD is detected separately from blanket, so the ordinary password-protected admin grant is not a release failure"

# The exact pair seen on the real Deck: one of each.
# shellcheck disable=SC2015  # "C runs when A is true" is the INTENT: fail_test
# must fire whenever either classifier disagrees, not only when the first does.
sudoers_line_is_blanket   "deck ALL=(ALL) ALL"           &&
! sudoers_line_is_nopasswd "deck ALL=(ALL) ALL"          ||
  fail_test "03_deck's real line classifies as blanket-but-password-required"
# shellcheck disable=SC2015  # same shape, same intent as the pair above.
sudoers_line_is_blanket   "deck ALL=(ALL) NOPASSWD: ALL" &&
  sudoers_line_is_nopasswd "deck ALL=(ALL) NOPASSWD: ALL" ||
  fail_test "99-deck-testing's real line classifies as blanket AND passwordless"
pass "the two real drop-ins on the Deck (03_deck, 99-deck-testing) classify as intended -- only the second is a release failure"

# ---------------------------------------------------------------------------
# 6. stage-desktop-settings -- the dconf site defaults (PROGRESS.md 5.20, R-38)
#
# These three values decide whether the on-screen keyboard works at all and
# whether an idle Deck can lock itself out, and every one of them was found by
# something failing on a screen rather than by a check failing. They are also
# the reason the stage exists: until it did, they were hand edits that a built
# image would simply not have.

dconf_file="$work/50-deck-desktop"
render_dconf_site_file >"$dconf_file"

grep -qF -- "$INSTALL_MARKER" "$dconf_file" ||
  fail_test "the rendered dconf defaults carry the '#'-commented marker" "expected: $INSTALL_MARKER"
pass "the rendered dconf defaults carry '${INSTALL_MARKER}'"

# The gate. squeekboard ships with auto-show off, and PROGRESS.md 5.20 was
# first recorded as "focus-triggered show does not work" purely because of it.
grep -qx "screen-keyboard-enabled=true" "$dconf_file" ||
  fail_test "the OSK auto-show gate must be enabled" "without screen-keyboard-enabled=true the keyboard never appears on text focus, and nothing logs a reason"
pass "the dconf defaults enable screen-keyboard-enabled -- the gate that hid 5.20"

grep -q "^\[org/gnome/desktop/a11y/applications\]" "$dconf_file" ||
  fail_test "screen-keyboard-enabled must sit under its own dconf group" "a key outside its [group] is silently ignored by dconf compile"
pass "screen-keyboard-enabled is under [org/gnome/desktop/a11y/applications]"

# Without a layout squeekboard runs, warns 'No system layout', and draws
# nothing -- which looks exactly like the keyboard being broken.
grep -q "^sources=\[('xkb','us')\]" "$dconf_file" ||
  fail_test "an input source must be set" "squeekboard warns 'No system layout' and has no keys to draw without one"
grep -q "^\[org/gnome/desktop/input-sources\]" "$dconf_file" ||
  fail_test "sources must sit under its own dconf group" "a key outside its [group] is silently ignored"
pass "the dconf defaults set an xkb input source under [org/gnome/desktop/input-sources]"

# ---------------------------------------------------------------------------
# 6a. the idle policy constants -- lock: 0 is a TRAP
#
# IdleModel.secondsFromConfig only rejects negative and non-finite values, so 0
# is accepted, and lockDelaySeconds === 0 is the fire-IMMEDIATELY branch.
# Disabling the lock means a LARGE timeout, not zero.

[[ $IDLE_LOCK_SECONDS -gt 0 ]] ||
  fail_test "IDLE_LOCK_SECONDS must not be 0" "lock:0 does not disable the lock -- secondsFromConfig accepts it and lockDelaySeconds===0 is the fire-immediately branch, so the Deck would lock the instant it idled"
pass "IDLE_LOCK_SECONDS is not 0 -- the value that would lock instantly rather than never"

# lockDelaySeconds*1000 feeds a QML Timer.interval, a 32-bit int. Past that the
# multiplication overflows and the timer can fire at once -- so "disable it with
# a huge number" is its own trap.
[[ $IDLE_LOCK_SECONDS -lt 2147483 ]] ||
  fail_test "IDLE_LOCK_SECONDS must stay under the QML int32 timer ceiling" "lockDelaySeconds*1000 feeds a 32-bit Timer.interval; beyond ~2147483s it overflows and may fire immediately"
pass "IDLE_LOCK_SECONDS is under the ~24.8-day QML int32 timer ceiling"

# The screensaver must still fire: it is the OLED burn-in protection, and
# R-41's lockout made it tempting to disable the wrong one.
[[ $IDLE_SCREENSAVER_SECONDS -gt 0 && $IDLE_SCREENSAVER_SECONDS -lt $IDLE_LOCK_SECONDS ]] ||
  fail_test "the screensaver must still fire, and before the lock" "it is the OLED burn-in protection; only the LOCK is the thing no on-screen keyboard can reach"
pass "the screensaver still fires (${IDLE_SCREENSAVER_SECONDS}s) and precedes the lock (${IDLE_LOCK_SECONDS}s)"

# ---------------------------------------------------------------------------
# 6b. the on-screen keyboard's XKB layout -- what it TYPES, not what it draws
#
# Reported from the panel 2026-08-12: "many of the keys don't type what they
# should". The OSK emits raw KEYCODES through the mapper's uinput device and the
# compositor decides which character each one means; on a latam session
# KEY_SEMICOLON is 'n-tilde'. The rule pins OUR device, and only ours, to `us`.
#
# 🔴 EVERY assertion here is about a way this rule could do NOTHING and say
# nothing -- match a device name that does not exist, get discarded as bad Lua,
# or quietly become session-wide.

osk_lua="$work/osk-kb-layout.lua"
render_osk_kb_layout_lua >"$osk_lua"

grep -qF -- "$INSTALL_MARKER_LUA" "$osk_lua" ||
  fail_test "the rendered layout rule carries the '--'-commented marker" "expected: $INSTALL_MARKER_LUA"
pass "the rendered layout rule carries '${INSTALL_MARKER_LUA}'"

# Both delimiters go into a file a HUMAN edits -- the same one that carries the
# OSK's above_lock rule. A marker that does not say who wrote it is an
# unexplained line in somebody's dotfile, and a generic one ("-- end") is a line
# their own content could plausibly contain.
for osk_marker in "$OSK_KB_RULE_BEGIN" "$OSK_KB_RULE_END"; do
  [[ $osk_marker == *deck-session.sh* && $osk_marker == *"on-screen keyboard"* ]] ||
    fail_test "the block delimiter '${osk_marker}' identifies itself" \
      "it is spliced into a user's own input.lua; a delimiter that does not name its writer is an unexplained line, and a generic one could collide with the user's own content"
  grep -qxF -- "$osk_marker" "$osk_lua" ||
    fail_test "the rendered block contains the delimiter line '${osk_marker}'" "without both, a re-run cannot replace its own work"
done
pass "both delimiters name deck-session.sh and appear verbatim in the rendered block"

# THE cross-file guard. The rule matches a NAME. If deck-input-mapper.py ever
# renames its uinput device, the rule keeps parsing, keeps loading, and matches
# nothing -- the exact silent no-op PROGRESS.md 5.30b is about. Nothing else in
# this repo connects the two strings.
mapper_py="$REPO_ROOT/src/deck-input-mapper.py"
[[ -f $mapper_py ]] ||
  fail_test "src/deck-input-mapper.py exists" "the layout rule is keyed on the device name that file declares; without it this check is vacuous"
grep -qF -- "\"${OSK_UINPUT_NAME}\"" "$mapper_py" ||
  fail_test "deck-input-mapper.py still declares the uinput device name the rule matches" \
    "OSK_UINPUT_NAME is '${OSK_UINPUT_NAME}' and src/deck-input-mapper.py does not contain it. A renamed device leaves the Hyprland rule matching nothing: it parses, it loads, and the keyboard keeps typing the session layout with no error anywhere."
pass "src/deck-input-mapper.py declares '${OSK_UINPUT_NAME}', the name the rule is keyed on"

# Hyprland matches the NORMALISED name (lowercase, spaces to dashes). Measured
# on the Deck with `hyprctl devices -j`; asserted here so the two constants
# cannot drift apart in a commit that only touches one of them.
osk_derived=${OSK_UINPUT_NAME,,}
osk_derived=${osk_derived// /-}
[[ $osk_derived == "$OSK_HYPR_DEVICE" ]] ||
  fail_test "OSK_HYPR_DEVICE is the Hyprland-normalised form of OSK_UINPUT_NAME" \
    "'${OSK_UINPUT_NAME}' normalises to '${osk_derived}', but the rule matches '${OSK_HYPR_DEVICE}'"
pass "OSK_HYPR_DEVICE ('${OSK_HYPR_DEVICE}') is the normalised form of the mapper's device name"

grep -q "name = deck_osk_device" "$osk_lua" ||
  fail_test "the rule sets hl.device's required 'name' field" "hl.device raises \"'name' field is required and must be a string\" without it, and a raise discards the rest of the file"
grep -q "kb_layout = \"${OSK_KB_LAYOUT}\"" "$osk_lua" ||
  fail_test "the rule sets kb_layout to '${OSK_KB_LAYOUT}'" "that is the whole fix"
pass "the rule calls hl.device with a name and kb_layout=${OSK_KB_LAYOUT}"

# The dedup hazard. Our uinput device declares keys AND relative axes, so
# Hyprland binds it twice and appends -1/-2/... to whichever copy loses the race
# for the bare name. Measured on the Deck: keyboard bare, pointer -1. Nothing
# promises that order, and kb_layout on a pointer is inert -- so a rule naming
# only the bare form works until the day it does not.
grep -q "\"${OSK_HYPR_DEVICE}\"" "$osk_lua" ||
  fail_test "the rule names the bare device name" "that is the name the keyboard holds today"
grep -q "\"${OSK_HYPR_DEVICE}-1\"" "$osk_lua" ||
  fail_test "the rule also names the -1 suffixed device" \
    "Hyprland appends -1 to whichever of the keyboard/pointer pair loses the race for the bare name. Naming only the bare form leaves the fix dependent on device-enumeration order, and it fails silently when it flips."
pass "the rule names the bare device AND its suffixed aliases, so enumeration order cannot silently defeat it"

# Explicit, not inherited: an unset device field falls back to the GLOBAL
# option, and a variant chosen for latam combined with layout 'us' is a keymap
# that may not compile at all.
for osk_field in kb_variant kb_model kb_rules; do
  grep -q "${osk_field} = \"\"" "$osk_lua" ||
    fail_test "the rule pins ${osk_field} explicitly" \
      "an unset device field inherits the global value (getDeviceString's fallback), so '${OSK_KB_LAYOUT}' would be combined with whatever variant the installer picked for the session layout"
done
pass "kb_variant, kb_model and kb_rules are pinned explicitly rather than inherited from the session"

# 🔴 The rule must NEVER become session-wide. `input = { kb_layout = ... }` is
# one careless simplification away and would change every physical keyboard on
# the machine -- the operator asked for the opposite, explicitly.
! grep -qE '^[^-]*\binput[[:space:]]*=' "$osk_lua" ||
  fail_test "the rule must not write a session-wide input block" \
    "hl.config{ input = { kb_layout = ... } } changes EVERY keyboard. The operator's requirement is per-device: physical keyboards keep Latin American."
pass "the rule touches no session-wide input config -- it is hl.device only"

# The sentinel has to be the LAST statement. That is what makes the whole thing
# falsifiable: hl.device raises on an unknown field, a raise skips everything
# after it, so a sentinel BEFORE the calls would be set by a block that failed.
osk_last=$(grep -vE '^[[:space:]]*(--|$)' "$osk_lua" | tail -1)
[[ $osk_last == "${OSK_KB_SENTINEL} = \"${OSK_KB_LAYOUT}\"" ]] ||
  fail_test "${OSK_KB_SENTINEL} is the last statement in the rendered block" \
    "got '${osk_last}'. hl.device RAISES on a bad field and a raise skips the rest of the chunk, so a sentinel set before the hl.device calls would be present in a compositor where the rule did nothing -- a check that passes for the wrong reason."
pass "${OSK_KB_SENTINEL} is the block's last statement, so its presence proves the hl.device calls ran"

# And the sentinel must be checked by ASSERTION, not by reading it back.
# Measured on the Deck 2026-08-12: `hyprctl eval` given a bare Lua return prints
# "ok" -- its own status, not the value -- and exits 0 for every expression that
# does not raise, including a nil global. Only a Lua error surfaces (exit 7,
# with the message). test/unit/test-hyprctl-syntax.sh scanner 3 guards the shape
# repo-wide; this pair of checks guards THIS function's implementation.
osk_verify_body=$(declare -f verify_osk_kb_layout)
grep -q "error(" <<<"$osk_verify_body" ||
  fail_test "verify_osk_kb_layout asserts the sentinel with a Lua error()" \
    "hyprctl eval cannot RETURN a value on 0.56.2: 'return <nil>' prints ok and exits 0, so a readback would pass whether the rule loaded or not. The probe has to raise."
! grep -qE "eval \"return " <<<"$osk_verify_body" ||
  fail_test "verify_osk_kb_layout does not try to read the sentinel back with 'eval return'" \
    "that form exits 0 for a nil global, which is a check that cannot fail"
pass "the sentinel is asserted with error(), not read back -- 'eval return' exits 0 for a nil global"

# It must reload before reading. Without it the readback describes the config
# that was loaded BEFORE this stage wrote the file -- including, on a re-run, a
# previous run's rule, which would make a broken new one look fine.
grep -q "reload config-only" <<<"$osk_verify_body" ||
  fail_test "verify_osk_kb_layout reloads the compositor config before reading it back" \
    "without a reload it reads whatever was loaded before this stage wrote the file, so a re-run would confirm the PREVIOUS run's rule"
pass "verify_osk_kb_layout reloads config-only before reading the device list back"

# R-46, and PROGRESS.md 5.30b's other half: hyprctl exits before doing anything
# when HYPRLAND_INSTANCE_SIGNATURE is unset, and a command that never ran reads
# exactly like a check that passed.
grep -q "HYPRLAND_INSTANCE_SIGNATURE=" <<<"$osk_verify_body" ||
  fail_test "verify_osk_kb_layout sets HYPRLAND_INSTANCE_SIGNATURE for every hyprctl call" \
    "R-46: without it hyprctl exits before running, and a check that never ran is indistinguishable from one that passed"
pass "verify_osk_kb_layout sets HYPRLAND_INSTANCE_SIGNATURE (R-46) rather than inheriting one that may not exist"

# PROGRESS.md 5.30b: `hyprctl dispatch`'s string form is a SYNTAX ERROR on
# 0.56.2 and `hyprctl keyword` refuses to work with the non-legacy parser. This
# rule is config, and the only two supported ways to apply config are a Lua file
# and `eval`.
! grep -qE 'hyprctl[^|]*(dispatch|keyword)' <<<"$osk_verify_body" ||
  fail_test "verify_osk_kb_layout uses neither 'hyprctl dispatch' nor 'hyprctl keyword'" \
    "5.30b: dispatch's old syntax is a parse error on 0.56.2 and keyword answers \"keyword can't work with non-legacy parsers. Use eval.\""
pass "the live check uses queries and eval only -- not dispatch, not keyword (5.30b)"

# ===========================================================================
# 8. deck-lizard-mode -- the helper that can cost the operator their input
# ===========================================================================
#
# PROGRESS.md 5.21, and operator decision 2 in 5.25. lizard_mode is a MODULE
# PARAMETER on the Deck's controller firmware driver:
#
#   Y  the firmware emits pointer/Enter/Esc/Tab/arrows and SWALLOWS X, Y, L1,
#      R1, STEAM and QAM -- they reach no evdev node, so deck-input-mapper.py
#      is a complete no-op. Degraded, always usable.
#   N  those six appear and the firmware's pointer disappears, so the mapper is
#      the ONLY input path on the device.
#
# Which means every assertion below is about a handheld that either works or
# cannot be driven at all. Three properties carry that weight:
#
#   the ARGUMENT NAMES LIZARD MODE      'off' must write N, not Y. Inverting the
#                                       two produces a helper that runs, exits
#                                       0, logs success, and does the opposite.
#   the READ-BACK                       a successful write to a module parameter
#                                       is not proof the kernel took the value.
#   the STRICT argv                     this file sits behind a sudo grant.
#
# ⚠️ NOTHING HERE TOUCHES /sys. render_lizard_helper takes the node as an
# argument, defaulting to the real constant, and every case below passes a path
# under $work -- which is also why the write path can be exercised at all
# without root.

lz_node="$work/lizard_mode"
lz_helper="$work/deck-lizard-mode"
render_lizard_helper "$lz_node" >"$lz_helper"
chmod +x "$lz_helper"

bash -n "$lz_helper" 2>"$work/stderr" ||
  fail_test "render_lizard_helper emits syntactically valid bash" "$(cat "$work/stderr")"
pass "render_lizard_helper emits syntactically valid bash (checked nowhere else -- it is generated)"

grep -qF -- "$INSTALL_MARKER" "$lz_helper" ||
  fail_test "the rendered lizard helper carries the '#'-commented marker" "expected: $INSTALL_MARKER"
pass "the rendered lizard helper carries '${INSTALL_MARKER}' -- so a re-run may replace its own output"

# The node is BAKED IN, and that is a security property rather than a style
# choice: the sudoers grant covers this file, so a node taken from argv would
# turn that grant into "write Y or N to any file, as root".
grep -qx "NODE=${lz_node}" "$lz_helper" ||
  fail_test "the rendered helper hardcodes the sysfs node it writes" "expected a line 'NODE=${lz_node}'; without it the node is coming from somewhere a caller controls"
pass "the sysfs node is baked into the helper at render time, not taken from its argv"

# And the default really is the real node, so a production render is not
# quietly pointed somewhere harmless.
render_lizard_helper >"$work/lizard-default"
grep -qx "NODE=${LIZARD_SYSFS}" "$work/lizard-default" ||
  fail_test "render_lizard_helper defaults to the real sysfs node" "a render with no argument must bake in ${LIZARD_SYSFS}; the parameter is a test seam, not configuration"
pass "render_lizard_helper with no argument bakes in ${LIZARD_SYSFS}"

lz_rc=0
run_lz() {
  lz_rc=0
  PATH="$fake_bin:$PATH" "$lz_helper" "$@" >"$work/stdout" 2>"$work/stderr" || lz_rc=$?
}

# --- the direction. 'off' means lizard mode off, i.e. N -------------------
#
# The single assertion an inverted helper cannot survive. Both values are
# checked from the node itself rather than from the helper's own output,
# because its output is one of the things that would be lying.

printf 'Y\n' >"$lz_node"
run_lz off
[[ $lz_rc -eq 0 ]] || fail_test "'off' succeeds" "exited ${lz_rc}: $(cat "$work/stderr")"
[[ $(cat "$lz_node") == N ]] ||
  fail_test "'off' writes N -- lizard mode OFF, mapper in charge" \
    "node reads '$(cat "$lz_node")'. The argument names LIZARD MODE, not the mapper: 'off' must disable the firmware's emulation, and an inverted helper exits 0 while doing the opposite"
pass "'off' writes N -- the firmware's emulation is disabled and the mapper becomes the input path"

run_lz on
[[ $lz_rc -eq 0 ]] || fail_test "'on' succeeds" "exited ${lz_rc}: $(cat "$work/stderr")"
[[ $(cat "$lz_node") == Y ]] ||
  fail_test "'on' writes Y -- the firmware provides input again" \
    "node reads '$(cat "$lz_node")'; this is the value every failure path has to land on"
pass "'on' writes Y -- the safe value, the one ExecStopPost= restores"

# --- strict argv ----------------------------------------------------------
#
# Exit 2 AND a message, for every shape. A helper behind a sudo grant that
# accepted an argument it then ignored would be the wrong thing to have there,
# and one that refused silently would leave the operator with no way to tell a
# rejected call from a call that never happened.

printf 'Y\n' >"$lz_node"
run_lz
[[ $lz_rc -eq 2 ]] || fail_test "no argument exits 2" "got ${lz_rc}"
[[ -s $work/stderr ]] || fail_test "a missing argument is not refused silently" "stderr was empty"
[[ $(cat "$lz_node") == Y ]] || fail_test "a refused call writes nothing" "the node moved to '$(cat "$lz_node")'"
pass "no argument exits 2, says so, and leaves the node alone"

for bad in lizard Y N '' 0 1 ON OFF --off on=1; do
  run_lz "$bad"
  [[ $lz_rc -eq 2 ]] ||
    fail_test "an unrecognised verb exits 2" "got ${lz_rc} for '${bad}'"
  grep -q "unknown argument" "$work/stderr" ||
    fail_test "the unrecognised-verb branch is what refused it" "got: $(cat "$work/stderr") for '${bad}'"
  [[ $(cat "$lz_node") == Y ]] ||
    fail_test "an unrecognised verb writes nothing" "'${bad}' moved the node to '$(cat "$lz_node")'"
done
pass "every unrecognised verb (including 'Y', 'N', 'ON' and '1') exits 2 by name and writes nothing"

# EXTRA arguments, checked separately from unrecognised ones: a helper that
# validated only $1 would pass every case above.
lz_stray="$work/stray-target"
rm -f "$lz_stray"
for extra in "on off" "off on" "off ${lz_stray}" "on --force" "off off"; do
  # shellcheck disable=SC2086  # deliberately splitting: these ARE two argv words.
  run_lz $extra
  [[ $lz_rc -eq 2 ]] ||
    fail_test "extra arguments exit 2" "got ${lz_rc} for '${extra}'"
  grep -q "exactly one argument" "$work/stderr" ||
    fail_test "the arity check is what refused it, not the verb check" "got: $(cat "$work/stderr") for '${extra}'"
  [[ $(cat "$lz_node") == Y ]] ||
    fail_test "a call with extra arguments writes nothing" "'${extra}' moved the node to '$(cat "$lz_node")'"
done
[[ ! -e $lz_stray ]] ||
  fail_test "a second argument is never treated as a path to write" "${lz_stray} was created; the node must not be reachable from argv, or the sudo grant becomes a root write primitive"
pass "extra arguments exit 2 by arity, write nothing, and a second argument is never used as a path"

# --- the node is missing --------------------------------------------------
#
# On the Deck this means hid_steam is not loaded. Reporting success here would
# make everything downstream believe input had moved when it had not.

render_lizard_helper "$work/no-such-node" >"$work/lizard-missing"
chmod +x "$work/lizard-missing"
lz_rc=0
PATH="$fake_bin:$PATH" "$work/lizard-missing" off >"$work/stdout" 2>"$work/stderr" || lz_rc=$?
[[ $lz_rc -eq 3 ]] ||
  fail_test "a missing sysfs node exits 3" "got ${lz_rc}; a helper that answered 0 here would report lizard mode off with the firmware still in charge"
grep -q "does not exist" "$work/stderr" ||
  fail_test "the missing-node failure names the node" "got: $(cat "$work/stderr")"
pass "a missing sysfs node exits 3 and names it -- no success reported for a write that never happened"

# --- the READ-BACK --------------------------------------------------------
#
# The check that separates "the write call returned 0" from "the kernel took
# the value". A module parameter's setter can decline a value and leave the
# node reading what it read before, with the write still succeeding.
#
# /dev/null stands in for exactly that: writable, and it reads back nothing.
if [[ -w /dev/null ]]; then
  ln -sf /dev/null "$work/sink"
  render_lizard_helper "$work/sink" >"$work/lizard-sink"
  chmod +x "$work/lizard-sink"
  lz_rc=0
  PATH="$fake_bin:$PATH" "$work/lizard-sink" off >"$work/stdout" 2>"$work/stderr" || lz_rc=$?
  [[ $lz_rc -eq 5 ]] ||
    fail_test "a write that does not read back exits 5" "got ${lz_rc}; without the read-back this helper reports success for a value the kernel never took"
  grep -q "reads back" "$work/stderr" ||
    fail_test "the read-back failure says what it read instead" "got: $(cat "$work/stderr")"
  pass "a value that does not read back exits 5 and reports what the node actually says"
else
  printf 'note - skipping the read-back case: /dev/null is not writable here\n'
fi

# A write that fails outright is a different exit code from one that fails to
# stick, so the journal line distinguishes "not root" from "the kernel said no".
if [[ -w /dev/full ]]; then
  ln -sf /dev/full "$work/full"
  render_lizard_helper "$work/full" >"$work/lizard-full"
  chmod +x "$work/lizard-full"
  lz_rc=0
  PATH="$fake_bin:$PATH" "$work/lizard-full" off >"$work/stdout" 2>"$work/stderr" || lz_rc=$?
  [[ $lz_rc -eq 4 ]] ||
    fail_test "a failed write exits 4, distinct from a failed read-back" "got ${lz_rc}"
  grep -q "could not write" "$work/stderr" ||
    fail_test "the failed write says so" "got: $(cat "$work/stderr")"
  pass "a write that fails exits 4 -- a different code from a write that does not stick"
else
  printf 'note - skipping the failed-write case: /dev/full is not available here\n'
fi

# ---------------------------------------------------------------------------
# 8a. the systemd drop-in -- the half that makes the invariant true
#
# The design is "lizard mode is off IF AND ONLY IF the mapper is running", and
# these two lines are the entire mechanism. ExecStopPost= is the fallback:
# systemd.service(5) runs it on a clean stop, on an unexpected exit (crash or
# SIGKILL), and when the service failed to start and is being shut down again.

lz_dropin="$work/50-deck-lizard-mode.conf"
render_lizard_dropin >"$lz_dropin"

grep -qF -- "$INSTALL_MARKER" "$lz_dropin" ||
  fail_test "the rendered drop-in carries the '#'-commented marker" "expected: $INSTALL_MARKER"
pass "the rendered drop-in carries '${INSTALL_MARKER}'"

grep -qx '\[Service\]' "$lz_dropin" ||
  fail_test "the drop-in declares [Service]" "ExecStartPost=/ExecStopPost= outside a section are ignored, and systemd logs nothing useful"
pass "the drop-in puts its Exec lines under [Service]"

# EXACT lines. A substring match would pass with a '-' prefix in front of the
# path, which is the one edit that turns a loud failure into a silent one.
grep -qx "ExecStartPost=${SUDO_BIN} -n ${LIZARD_HELPER} off" "$lz_dropin" ||
  fail_test "ExecStartPost= turns lizard mode OFF when the mapper starts" \
    "expected exactly 'ExecStartPost=${SUDO_BIN} -n ${LIZARD_HELPER} off'; file:"$'\n'"$(cat "$lz_dropin")"
pass "ExecStartPost= runs '${LIZARD_HELPER} off' -- the mapper takes over only once it is started"

grep -qx "ExecStopPost=${SUDO_BIN} -n ${LIZARD_HELPER} on" "$lz_dropin" ||
  fail_test "ExecStopPost= turns lizard mode back ON when the mapper stops" \
    "expected exactly 'ExecStopPost=${SUDO_BIN} -n ${LIZARD_HELPER} on'. THIS IS THE FALLBACK: without it a mapper that crashes leaves a handheld with no pointer and no keys, recoverable only over SSH. (It does not cover a cgroup-wide SIGKILL -- measured; see the table above render_lizard_dropin.) File:"$'\n'"$(cat "$lz_dropin")"
pass "ExecStopPost= runs '${LIZARD_HELPER} on' -- the path back for a stop, a crash, a SIGKILLed main process and a failed start alike"

# The '-' prefix, asserted as its own property rather than left to the exact
# matches above. systemd's '-' means "ignore a failure from this command", and
# on ExecStopPost= that is the fallback silently not happening.
! grep -qE '^Exec(Start|Stop)Post=-' "$lz_dropin" ||
  fail_test "neither Exec line is prefixed with '-'" \
    "a '-' makes systemd ignore the failure. If lizard mode cannot be turned off the mapper is a no-op anyway, and if it cannot be turned back on the device has no input -- both must be loud. File:"$'\n'"$(cat "$lz_dropin")"
pass "neither ExecStartPost= nor ExecStopPost= is prefixed with '-' -- a failure in either is loud"

# --- OnFailure=, the half ExecStopPost= cannot cover -----------------------
#
# MEASURED, systemd 261, with a probe unit mirroring the real one: a SIGKILL of
# the whole cgroup (`systemctl kill -s SIGKILL`, whose default --kill-whom is
# NOT main, or systemd-oomd's cgroup.kill) starts ExecStopPost= and then kills
# it, because systemd spawns it INTO the unit's own cgroup:
#
#   Killed unit cgroup '...' with SIGKILL on client request
#   Control process exited, code=killed, status=9/KILL      <- the ExecStopPost
#
# OnFailure= starts a SEPARATE unit, which gets its own cgroup and survives.
# Verified on every cgroup-kill path, and it fires LAST when the start limit is
# reached -- so a dead mapper leaves lizard mode ON.
grep -qx '\[Unit\]' "$lz_dropin" ||
  fail_test "the drop-in declares [Unit]" \
    "OnFailure= is a [Unit] setting; under [Service] systemd logs 'Unknown key' and carries on without it"
pass "the drop-in declares [Unit], the section OnFailure= belongs to"

grep -qx "OnFailure=${LIZARD_RESTORE_UNIT##*/}" "$lz_dropin" ||
  fail_test "the drop-in names the OnFailure unit" \
    "expected exactly 'OnFailure=${LIZARD_RESTORE_UNIT##*/}'. WITHOUT IT a 'systemctl kill -s SIGKILL' -- the command a human types while debugging -- leaves lizard mode off with nothing reading the pad, because it kills ExecStopPost= along with the cgroup. File:"$'\n'"$(cat "$lz_dropin")"
pass "OnFailure= names ${LIZARD_RESTORE_UNIT##*/} -- the separate cgroup that survives a cgroup-wide kill"

# The two must be one fact, not two that agree today.
[[ $(grep -oP '^OnFailure=\K.*' "$lz_dropin") == "${LIZARD_RESTORE_UNIT##*/}" ]] ||
  fail_test "OnFailure= is derived from LIZARD_RESTORE_UNIT" \
    "the drop-in says '$(grep -oP '^OnFailure=\K.*' "$lz_dropin")' and the unit installed is '${LIZARD_RESTORE_UNIT##*/}'; systemd reports a dangling OnFailure= only when it tries to trigger it, i.e. in the failure"
pass "the OnFailure= target and the unit that gets installed are the same string, by derivation"

# The drop-in has to land in the mapper unit's own .d directory. A drop-in
# anywhere else is inert: installed, valid, and doing nothing.
[[ $LIZARD_DROPIN == "${MAPPER_UNIT}.d/"* ]] ||
  fail_test "the drop-in path is derived from MAPPER_UNIT" \
    "LIZARD_DROPIN is '${LIZARD_DROPIN}', which is not under '${MAPPER_UNIT}.d/' -- systemd would never read it and nothing would report that"
pass "LIZARD_DROPIN sits in ${MAPPER_UNIT}.d, the only directory systemd reads it from"

# ---------------------------------------------------------------------------
# 8b. where the stage sits in the run
#
# A stage that is not in INSTALL_STAGES never runs in a full install: the fault
# is invisible, because every single-stage invocation still works. And a stage
# that runs BEFORE stage-input-mapper installs a drop-in for a unit that does
# not exist yet -- which its own precondition would refuse, so the whole install
# would stop at a stage ordering error rather than at anything real.

lz_stage_at=-1
lz_mapper_at=-1
for i in "${!INSTALL_STAGES[@]}"; do
  [[ ${INSTALL_STAGES[$i]} == stage-lizard-mode ]] && lz_stage_at=$i
  [[ ${INSTALL_STAGES[$i]} == stage-input-mapper ]] && lz_mapper_at=$i
done

[[ $lz_stage_at -ge 0 ]] ||
  fail_test "stage-lizard-mode is registered in INSTALL_STAGES" \
    "a full install would silently skip it, and every single-stage run would still work -- so nothing would notice. Stages: ${INSTALL_STAGES[*]}"
pass "stage-lizard-mode is in INSTALL_STAGES, so a full install actually runs it"

[[ $lz_mapper_at -ge 0 && $lz_stage_at -gt $lz_mapper_at ]] ||
  fail_test "stage-lizard-mode runs AFTER stage-input-mapper" \
    "mapper at index ${lz_mapper_at}, lizard at ${lz_stage_at}. The drop-in extends the mapper's unit; installed first it would refuse, because a drop-in for a unit that does not exist is inert"

pass "stage-lizard-mode runs after stage-input-mapper -- the unit it extends exists by then"

declare -F stage_lizard_mode >/dev/null ||
  fail_test "the INSTALL_STAGES entry resolves to a function" "run_stage maps 'stage-lizard-mode' to stage_lizard_mode, which does not exist"
pass "stage-lizard-mode resolves to stage_lizard_mode(), the name run_stage derives"

# ---------------------------------------------------------------------------
# 8c. the OnFailure unit -- a separate unit purely to get a separate CGROUP
#
# It exists for one measured reason: ExecStopPost= is spawned INTO the mapper's
# cgroup and dies with it under a cgroup-wide SIGKILL. A unit reached by
# OnFailure= is started by the manager as its own job, in its own cgroup, and
# survives the same kill -- confirmed on all three cgroup-kill paths.

lz_restore="$work/deck-lizard-restore.service"
render_lizard_restore_unit >"$lz_restore"

grep -qF -- "$INSTALL_MARKER" "$lz_restore" ||
  fail_test "the rendered restore unit carries the '#'-commented marker" "expected: $INSTALL_MARKER"
pass "the rendered restore unit carries '${INSTALL_MARKER}'"

for section in '[Unit]' '[Service]'; do
  grep -qxF -- "$section" "$lz_restore" ||
    fail_test "the restore unit declares ${section}" \
      "a setting outside its section is 'Unknown key ... ignoring' and the unit still loads. File:"$'\n'"$(cat "$lz_restore")"
done
pass "the restore unit declares both [Unit] and [Service]"

grep -qx 'Type=oneshot' "$lz_restore" ||
  fail_test "the restore unit is Type=oneshot" \
    "it runs one command and exits; without RemainAfterExit= it returns to inactive, which is what lets OnFailure= trigger it again (measured: six consecutive triggers, six runs)"
pass "the restore unit is Type=oneshot, so repeated failures each get a restore"

# The direction. This unit may ONLY ever turn lizard mode on: that is what makes
# it safe to fire while a mapper is restarting.
grep -qx "ExecStart=${SUDO_BIN} -n ${LIZARD_HELPER} on" "$lz_restore" ||
  fail_test "the restore unit runs the helper with 'on'" \
    "expected exactly 'ExecStart=${SUDO_BIN} -n ${LIZARD_HELPER} on'. File:"$'\n'"$(cat "$lz_restore")"
pass "the restore unit runs '${LIZARD_HELPER} on' -- towards the safe value, always"

! grep -qE '^ExecStart=.* off$' "$lz_restore" ||
  fail_test "the restore unit can never turn lizard mode OFF" \
    "a restore that could write N would be able to take input away from a device with no mapper running -- the exact failure the whole fallback exists to prevent. File:"$'\n'"$(cat "$lz_restore")"
pass "nothing in the restore unit can turn lizard mode off -- its worst case is costing STEAM+X, never input"

! grep -qE '^ExecStart=-' "$lz_restore" ||
  fail_test "the restore unit's ExecStart= is not prefixed with '-'" \
    "this is the last line of defence; it must not be the one that fails quietly"
pass "the restore unit's ExecStart= is not prefixed with '-'"

# ⚠️ No [Install]. Enabling it would run it at every session start -- turning
# lizard mode ON exactly as the mapper's ExecStartPost= was turning it off,
# which is a race against the one thing that has to win.
! grep -q '^\[Install\]' "$lz_restore" ||
  fail_test "the restore unit has no [Install] section" \
    "it is reached by OnFailure= and nothing else. Enabled, it would fire at every session start and race the mapper's own ExecStartPost=. File:"$'\n'"$(cat "$lz_restore")"
pass "the restore unit has no [Install] section -- it is never enabled, only triggered"

# Same directory as the mapper unit: this is installed by an installer for a
# user it has never met, so it cannot live in anyone's ~/.config.
[[ $(dirname "$LIZARD_RESTORE_UNIT") == "$(dirname "$MAPPER_UNIT")" ]] ||
  fail_test "the restore unit sits beside the mapper unit" \
    "LIZARD_RESTORE_UNIT is ${LIZARD_RESTORE_UNIT} but MAPPER_UNIT is ${MAPPER_UNIT}; a user unit in the wrong search path is simply not found"
pass "the restore unit is installed in $(dirname "$MAPPER_UNIT"), the same search path as the mapper unit"

# Nothing may PERSIST the value. The whole safety argument is that boot leaves
# Y, so a mapper that never starts leaves a usable device -- a modprobe.d option
# applying N at module load would remove exactly that guarantee, before any
# userspace check could run.
#
# Checked on the PATH rather than the word: `/etc/modprobe.d` is what an install
# needs, and deck-session.sh's own comment rejecting the idea says "modprobe.d"
# in prose. A word match would fire on the comment that exists to forbid it.
! grep -rq '/etc/modprobe\.d' "$REPO_ROOT/src" ||
  fail_test "nothing in src/ installs into /etc/modprobe.d" \
    "modprobe.d applies at MODULE LOAD, before any userspace check can run: a boot where the mapper cannot start would present a handheld with no input at all. Found:"$'\n'"$(grep -rn '/etc/modprobe\.d' "$REPO_ROOT/src")"
pass "nothing in src/ writes /etc/modprobe.d -- boot always leaves lizard mode on, which is the fallback's whole basis"

# The same property from the other side: this script installs no file whose
# content sets the parameter at load time.
! grep -rq 'options[[:space:]]\+hid_steam' "$REPO_ROOT/src" ||
  fail_test "nothing in src/ emits a modprobe 'options hid_steam' line" \
    "that is the boot-time form of the same hazard, and it does not need a /etc/modprobe.d path in this repo to end up in one. Found:"$'\n'"$(grep -rn 'options[[:space:]]\+hid_steam' "$REPO_ROOT/src")"
pass "no 'options hid_steam ...' line is generated anywhere in src/"

echo "all deck-session.sh tests passed"
