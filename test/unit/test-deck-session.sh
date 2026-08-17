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
# Used by the branches that skip a case for want of an optional tool. It was
# called before it existed (the ImageMagick-absent branch in section 10), which
# nothing noticed because this dev box has ImageMagick -- a skip path that
# aborts the suite on the machines it exists for.
note()      { printf '# %s\n' "$1"; }

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

# 🔴 THERE MUST BE NO ExecStartPost= AT ALL (docs/findings/P39 Defect 2).
#
# It used to disarm lizard mode here, and that is what bricked the Deck: for
# Type=simple, ExecStartPost= runs as soon as the mapper is FORKED, before it
# holds any device, and pick_device() then waits for the native pad
# indefinitely. Open Steam in Desktop Mode -- the KERNEL destroys the native pad
# -- and the result was lizard off, nothing driving, no unit transition to
# notice, and no on-device recovery but a ~10 s power-button hold.
#
# The disarm now belongs to the mapper, which is the only thing that knows
# whether it is holding a pad. This file must never put it back.
if grep -qE '^ExecStartPost=' "$lz_dropin"; then
  fail_test "the drop-in must NOT disarm lizard mode at start" \
    "found an ExecStartPost= in the drop-in. That line runs before the mapper holds any device, and with Steam resident the native pad never arrives -- lizard off with nothing driving is a handheld with NO INPUT. The disarm lives in src/deck-input-mapper.py's pick_device(), after the bind. File:"$'\n'"$(cat "$lz_dropin")"
fi
pass "🔴 no ExecStartPost= -- the mapper disarms lizard mode itself, after it has a pad"

# The positive control for that absence: this file really does contain Exec
# lines, so the check above is reading a rendered drop-in and not an empty file.
grep -qE '^Exec[A-Za-z]+=' "$lz_dropin" ||
  fail_test "the drop-in contains Exec lines at all" \
    "the ExecStartPost= absence check above would pass vacuously against an empty or unrendered file. File:"$'\n'"$(cat "$lz_dropin")"
pass "...and the drop-in does carry Exec lines, so that absence check is not vacuous"

grep -qx "ExecStopPost=${SUDO_BIN} -n ${LIZARD_HELPER} on" "$lz_dropin" ||
  fail_test "ExecStopPost= turns lizard mode back ON when the mapper stops" \
    "expected exactly 'ExecStopPost=${SUDO_BIN} -n ${LIZARD_HELPER} on'. THIS IS THE FALLBACK: without it a mapper that crashes leaves a handheld with no pointer and no keys, recoverable only over SSH. (It does not cover a cgroup-wide SIGKILL -- measured; see the table above render_lizard_dropin.) File:"$'\n'"$(cat "$lz_dropin")"
pass "ExecStopPost= runs '${LIZARD_HELPER} on' -- the path back for a stop, a crash, a SIGKILLed main process and a failed start alike"

# The '-' prefix, asserted as its own property rather than left to the exact
# matches above. systemd's '-' means "ignore a failure from this command", and
# on ExecStopPost= that is the fallback silently not happening.
! grep -qE '^Exec(Start|Stop)Post=-' "$lz_dropin" ||
  fail_test "the Exec line is not prefixed with '-'" \
    "a '-' makes systemd ignore the failure. On ExecStopPost= that is the fallback silently not happening, and the device has no input. It must be loud. File:"$'\n'"$(cat "$lz_dropin")"
pass "ExecStopPost= is not prefixed with '-' -- a failure in the fallback is loud"

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

# ---------------------------------------------------------------------------
# 9. The two ways back to Gaming Mode must run the SAME command
#
# There are two of them -- a .desktop entry every shell reads, and a Quickshell
# menu row -- and the failure they invite is not that one breaks. It is that one
# is renamed and the other is not, leaving a pressable affordance that does
# nothing, reports nothing, and looks exactly like the working one.
#
# So: one constant, both renderers derive from it, and the check compares what
# is RENDERED rather than what the constants say.

# --- the static half: neither renderer may carry its own copy of the string --
#
# assert_return_action_agrees compares the two outputs at install time, which
# catches a drift only once they already disagree in value. This catches the
# shape that ALLOWS them to disagree: a literal path typed into either heredoc.
# Both halves are needed -- a second literal that happens to be identical today
# passes the runtime check and is one rename away from failing silently.
#
# The two renderers name DIFFERENT constants since 2026-08-16: the .desktop
# entry's Exec= is the bare command, while the menu row runs it wrapped in
# Omarchy's OSD sequence. The chain that has to hold is
# RETURN_ACTION -> MENU_ROW_SWITCH -> MENU_ROW_ACTION, and each link is checked
# rather than assumed -- see the derivation checks below this loop.
declare -A renderer_const=(
  [render_return_desktop]=RETURN_ACTION
  [render_menu_row_block]=MENU_ROW_ACTION
)
for renderer in render_return_desktop render_menu_row_block; do
  const=${renderer_const[$renderer]}
  body=$(declare -f "$renderer")
  grep -q "$const" <<<"$body" ||
    fail_test "${renderer} emits the shared \$${const}" \
      "it does not name the constant at all, so the .desktop entry and the menu row can drift apart with nothing to notice:"$'\n'"${body}"
  ! grep -qF -- "${STEAM_SHIM} gamescope" <<<"$body" ||
    fail_test "${renderer} carries no second literal copy of the command" \
      "a literal '${STEAM_SHIM} gamescope' beside the constant is a copy that survives a rename of the constant:"$'\n'"${body}"
  pass "${renderer} derives the command from \$${const} and carries no literal copy of it"
done

# --- the chain the menu row's constant hangs off --------------------------
#
# Values, not text: these constants are expanded at definition, so there is no
# '${RETURN_ACTION}' left in them to grep for. What matters is the property --
# the row's command must still contain the shared command, and must still start
# by scheduling it.
[[ $MENU_ROW_SWITCH == *"$RETURN_ACTION"* ]] ||
  fail_test "\$MENU_ROW_SWITCH schedules the shared \$RETURN_ACTION" \
    "got '${MENU_ROW_SWITCH}', which does not contain '${RETURN_ACTION}'"
pass "\$MENU_ROW_SWITCH schedules '${RETURN_ACTION}'"

# 🔴 THE ORDERING PROPERTY, AND IT IS THE ONE THAT KEEPS THE DEVICE USABLE.
# The switch is backgrounded BEFORE the on-screen notice is drawn, so a notice
# that fails cannot stop it. Anchored at the START deliberately: an inversion
# that drew the notice first and switched afterwards would still "contain" the
# command and would still look right in a diff.
[[ $MENU_ROW_ACTION == "$MENU_ROW_SWITCH"* ]] ||
  fail_test "\$MENU_ROW_ACTION schedules the switch before anything that can fail" \
    "it does not begin with \$MENU_ROW_SWITCH:"$'\n'"  action: ${MENU_ROW_ACTION}"$'\n'"  switch: ${MENU_ROW_SWITCH}"
pass "\$MENU_ROW_ACTION schedules the session switch first, before the notice"

# --- the runtime half, against the real renderers -------------------------
desktop_exec=$(render_return_desktop | grep '^Exec=' || true)
[[ ${desktop_exec#Exec=} == "$RETURN_ACTION" ]] ||
  fail_test "the rendered .desktop entry's Exec= is exactly \$RETURN_ACTION" \
    "got '${desktop_exec}', expected 'Exec=${RETURN_ACTION}'"
pass "the rendered .desktop entry runs '${RETURN_ACTION}'"

# assert_return_action_agrees is what the stage runs. It calls `fail` (exit 1),
# so it goes in a subshell like every other such check in this suite.
( assert_return_action_agrees ) >"$work/agree.out" 2>"$work/agree.err" ||
  fail_test "assert_return_action_agrees passes on the shipped renderers" \
    "$(cat "$work/agree.err")"
pass "assert_return_action_agrees passes on the shipped renderers"

# --- 🔴 A BROKEN NOTICE MUST NOT COST THE SESSION SWITCH ------------------
#
# The checks above are static: they prove the switch is written first. This one
# RUNS the shipped action with the OSD deliberately sabotaged and watches for
# the switch to happen anyway. It is the assertion that matters most in this
# section, because the failure it guards against is losing the only
# controller-reachable way out of the desktop over a cosmetic toast.
#
# The action is taken from the real renderer and ONE substitution is made: the
# absolute ${RETURN_ACTION} becomes a stub that records that it ran. Nothing
# else is rewritten, so the ordering, the nohup, the backgrounding and the
# `|| logger` are all the shipped ones.
osd_work="$work/osd"; mkdir -p "$osd_work/bin"
shipped_action=$(rendered_menu_action) ||
  fail_test "the shipped menu action can be read back for the sabotage test" "rendered_menu_action failed"

printf '#!/usr/bin/env bash\nprintf switched >%q\n' "$osd_work/switched" >"$osd_work/bin/fake-select"
chmod +x "$osd_work/bin/fake-select"

# bash -c, not -lc as Menu.qml uses: -l sources the login profile, which would
# reset the PATH this test depends on. The property under test is the ordering
# inside the action string, which -l does not affect.
for sabotage in absent failing; do
  rm -f "$osd_work/switched"
  rm -f "$osd_work/bin/omarchy-osd"
  if [[ $sabotage == failing ]]; then
    printf '#!/usr/bin/env bash\necho "omarchy-osd: broken" >&2\nexit 1\n' >"$osd_work/bin/omarchy-osd"
    chmod +x "$osd_work/bin/omarchy-osd"
  fi

  # PATH deliberately holds ONLY the stub dir plus the essentials, so an
  # omarchy-osd installed on the dev machine cannot rescue the 'absent' case.
  env -i PATH="$osd_work/bin:/usr/bin:/bin" HOME="$osd_work" \
    bash -c "${shipped_action//"$RETURN_ACTION"/$osd_work/bin/fake-select}" \
    >"$osd_work/out" 2>"$osd_work/err" || true

  # Poll rather than sleep a fixed span: the action schedules the switch behind
  # a lead-in, and this must not encode how long that lead-in is.
  waited=0
  while [[ ! -e "$osd_work/switched" && $waited -lt 100 ]]; do
    sleep 0.1; waited=$((waited + 1))
  done

  [[ -e "$osd_work/switched" ]] ||
    fail_test "the session switch still runs when the on-screen notice is ${sabotage}" \
      "the stub was never invoked, so a failing notice would strand the user in the desktop with no way back to Gaming Mode"$'\n'"stderr: $(cat "$osd_work/err")"
  pass "the session switch still runs when omarchy-osd is ${sabotage}"
done

# ---------------------------------------------------------------------------
# 9a. The menu row block -- the file Quickshell silently discards when wrong
#
# 🔴 MenuModel.js:parseMenuJsonc does `try { JSON.parse(stripped) } catch (e) {
# return [] }` and Menu.qml sets printErrors: false on the user file's FileView.
# A malformed extension file therefore drops EVERY user row with no error
# anywhere. These assertions exist because nothing on the device would report
# any of these faults.

menu_block="$work/menu-row.jsonc"
render_menu_row_block >"$menu_block"

grep -qxF -- "$MENU_ROW_BEGIN" "$menu_block" ||
  fail_test "the block opens with the begin marker" "expected: ${MENU_ROW_BEGIN}"
grep -qxF -- "$MENU_ROW_END" "$menu_block" ||
  fail_test "the block closes with the end marker" \
    "without it the splice cannot find its own previous copy, and a re-run would append a second row"
pass "the rendered menu row is delimited by both whole-line markers"

grep -qF -- "$INSTALL_MARKER_TEXT" "$menu_block" ||
  fail_test "the block carries the install marker text" "expected: ${INSTALL_MARKER_TEXT}"
grep -qxF -- "$INSTALL_MARKER_JSONC" "$menu_block" ||
  fail_test "the marker uses the '//' JSONC prefix" \
    "'#' is not a comment in JSONC and Quickshell reports nothing when the parse fails -- the whole file's rows would vanish. Expected the line: ${INSTALL_MARKER_JSONC}"
pass "the block carries '${INSTALL_MARKER_JSONC}' -- the marker text with the one prefix this format accepts"

# ⚠️ EVERY comment must occupy a WHOLE line. stripJsonc only removes
# /^\s*\/\/[^\n]*(\n|$)/gm, so a comment placed after a value on the same line
# survives stripping and breaks JSON.parse -- silently.
while IFS= read -r line; do
  [[ $line == *"//"* ]] || continue
  [[ ${line#"${line%%[![:space:]]*}"} == //* ]] ||
    fail_test "every '//' in the block is a whole-line comment" \
      "this line has one after content, which stripJsonc does NOT remove: ${line}"
done <"$menu_block"
pass "every '//' in the block starts its line -- the only comment form stripJsonc removes"

# The row itself must be strict JSON, checked by a parser rather than by eye.
#
# The action is checked BY STRUCTURE, not by equality with a literal: it must
# schedule the switch first and it must contain the shared command. The notice
# text, its icon and its duration are Omarchy's business and deliberately go
# unasserted -- pinning them here would make this suite fail on a wording change
# that broke nothing.
python3 - "$menu_block" "$MENU_ROW_ID" "$RETURN_ACTION" "$RETURN_LABEL" "$MENU_ROW_SWITCH" <<'PY' ||
import json, re, sys
raw = open(sys.argv[1]).read()
row_id, action, label, switch = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
stripped = re.sub(r"^\s*//[^\n]*(\n|$)", "", raw, flags=re.M)
stripped = re.sub(r",(\s*$)", r"\1", stripped)
menu = json.loads("{" + stripped + "}")
assert list(menu) == [row_id], list(menu)
got = menu[row_id]["action"]
assert got.startswith(switch), \
    "the row must schedule the switch before the notice, got: %r" % got
assert action in got, "the row must run %r, got: %r" % (action, got)
assert menu[row_id]["label"] == label, menu[row_id]["label"]
# `action` is what makes this a row rather than a submenu: MenuModel.js
# normalizeItem reads kind = value.action ? "action" : (value.target ? ...).
assert "target" not in menu[row_id], "a target would make it a link, not an action"
PY
  fail_test "the rendered row is strict JSON with the right id, label and action" \
    "$(cat "$menu_block")"
pass "the rendered row parses as strict JSON: one id ('${MENU_ROW_ID}'), the switch scheduled ahead of the notice, no 'target' that would make it a link"

# The trailing comma is what lets the block be spliced in at one fixed position
# whether the rest of the object is empty or full. stripJsonc removes it in the
# empty case; it separates entries in the full one.
grep -q '^"'"$MENU_ROW_ID"'":.*},$' "$menu_block" ||
  fail_test "the row line ends with a comma" \
    "without it, splicing our block above an existing entry produces '}\"personal\"' and the whole file stops parsing"
pass "the row line ends with a trailing comma, so the same block splices into an empty file and a full one"

# --- the glyph ------------------------------------------------------------
#
# docs/findings/P16-redistribution-and-trademark.md: ship a codepoint, not
# Valve's artwork. And ONE codepoint -- Nerd Font glyphs live in a plane where
# it is easy to paste a surrogate pair and get two tofu boxes instead.
# 🔴 The icon is a JSON \\uXXXX ESCAPE PAIR in src/, not a character and not
# bash's $'\\U...'. Found on the Deck 2026-08-12 while this suite was green:
# $'\\U...' is LOCALE-DEPENDENT -- a UTF-8 locale expands it, C/POSIX emits the
# literal ten ASCII bytes. The dev machine is UTF-8; an ssh session to the Deck
# is LC_CTYPE=POSIX, so the rendered row carried an invalid JSON escape and the
# stage refused to install it. This asserts the DECODED value; the
# locale-independence check below is the one that would actually have caught it.
python3 - "$MENU_ROW_ICON" <<'ICONPY' ||
import sys, unicodedata, json
raw = sys.argv[1]
assert all(ord(c) < 128 for c in raw), (
    "the icon constant must be pure ASCII so no locale can alter it: %r" % raw)
icon = json.loads('"' + raw + '"')
assert len(icon) == 1, "the icon decodes to %d characters, not one glyph: %r" % (len(icon), icon)
cp = ord(icon)
assert unicodedata.category(icon) == "Co", "the icon is not a private-use codepoint"
assert 0xF0000 <= cp <= 0xFFFFD, "U+%X is outside the Nerd Font private-use plane" % cp
ICONPY
  fail_test "the menu row's icon is an ASCII escape decoding to one private-use codepoint" \
    "got $(printf '%q' "$MENU_ROW_ICON")"
pass "the menu row's icon is pure ASCII in src/ and decodes to a single Nerd Font codepoint"

# 🔴 THE ASSERTION THAT WOULD HAVE CAUGHT THE DECK FAILURE. Render the block
# under a UTF-8 locale and under C/POSIX; the bytes must be identical. Any
# locale-sensitive escape makes them diverge, and the Deck runs the POSIX one.
_loc_utf8=$(LC_ALL=C.UTF-8 bash -c 'source "$1"; render_menu_row_block' _ "$REPO_ROOT/src/deck-session.sh" | od -An -c)
_loc_posix=$(LC_ALL=C bash -c 'source "$1"; render_menu_row_block' _ "$REPO_ROOT/src/deck-session.sh" | od -An -c)
[[ -n $_loc_posix ]] ||
  fail_test "the C/POSIX render produced nothing at all" \
    "an empty render would make the comparison below pass for the wrong reason"
[[ $_loc_utf8 == "$_loc_posix" ]] ||
  fail_test "the menu row renders identically under C.UTF-8 and C/POSIX" \
    "they differ, so the row that reaches the Deck is not the row this suite tested"
pass "the menu row renders byte-identically under C.UTF-8 and C/POSIX -- no locale-dependent escape survives"

# Nothing in src/ may name Valve's or a console vendor's glyph. Checked on the
# rendered block rather than on the constant, so a future second row is covered
# too.
for banned in $'' $'' $'' $'\U000F04D3' $'\U000F05BA'; do
  ! grep -qF -- "$banned" "$menu_block" ||
    fail_test "the block ships no vendor-branded glyph" \
      "it carries U+$(printf '%X' "'$banned"), a Steam or Xbox glyph -- P16 says ship a neutral one"
done
pass "the block carries none of the Steam or Xbox glyphs the same font offers"

# ---------------------------------------------------------------------------
# 9b. Where the two new stages sit in the run
#
# stage-menu-row belongs IN the full install: it writes per-user config, adds a
# row, and changes no default. stage-boot-default-gaming must NOT be, for the
# same reason stage-default-session is not -- with it enabled a broken Gaming
# Mode is re-asserted at every boot, on a device with one screen and no session
# picker. Both properties are invisible at runtime: a stage missing from
# INSTALL_STAGES still works when invoked by hand, and a stage wrongly added to
# it still works too.

menu_at=-1
icon_at=-1
for i in "${!INSTALL_STAGES[@]}"; do
  [[ ${INSTALL_STAGES[$i]} == stage-menu-row ]]    && menu_at=$i
  [[ ${INSTALL_STAGES[$i]} == stage-return-icon ]] && icon_at=$i
done
[[ $menu_at -ge 0 ]] ||
  fail_test "stage-menu-row is registered in INSTALL_STAGES" \
    "a full install would skip it and every single-stage run would still work, so nothing would notice. Stages: ${INSTALL_STAGES[*]}"
pass "stage-menu-row is in INSTALL_STAGES, so a full install actually installs the row"

[[ $icon_at -ge 0 && $menu_at -gt $icon_at ]] ||
  fail_test "stage-menu-row runs after stage-return-icon" \
    "return-icon at ${icon_at}, menu-row at ${menu_at}; the menu stage asserts the two agree, and it should be the one that runs second"
pass "stage-menu-row runs after stage-return-icon, so the agreement check runs with both halves rendered"

for banned_stage in stage-boot-default-gaming stage-default-session stage-power-button; do
  for s in "${INSTALL_STAGES[@]}"; do
    [[ $s != "$banned_stage" ]] ||
      fail_test "${banned_stage} is NOT in INSTALL_STAGES" \
        "a bare './deck-session.sh' would flip the default session on a machine whose Gaming Mode has never been proven to start; with stage-boot-default-gaming it would do so at every boot; and with stage-power-button it would rewire a HARDWARE BUTTON on a device whose only other escape is a ten-second hold. All three are opt-in on purpose."
  done
  pass "${banned_stage} is not in INSTALL_STAGES -- a bare run cannot leave a Deck with no graphical way back"
done

for fn in stage_menu_row stage_boot_default_gaming; do
  declare -F "$fn" >/dev/null ||
    fail_test "the stage name resolves to a function" "run_stage maps to ${fn}, which does not exist"
done
pass "stage-menu-row and stage-boot-default-gaming both resolve to the functions run_stage derives"

# `list-stages` is the CI-facing inventory, and a stage missing from it is a
# stage nobody outside this file can discover. Run the real dispatcher: the
# list-stages arm prints and exits without touching the system.
bash "$REPO_ROOT/src/deck-session.sh" list-stages >"$work/list-stages" 2>"$work/list-stages.err" ||
  fail_test "'deck-session.sh list-stages' exits 0" "$(cat "$work/list-stages.err")"
for s in stage-menu-row stage-boot-default-gaming stage-default-session stage-audit-privileges stage-power-button; do
  grep -qx -- "$s" "$work/list-stages" ||
    fail_test "list-stages names ${s}" \
      "it is invocable and undiscoverable, which is how the opt-in stages get forgotten. Got:"$'\n'"$(cat "$work/list-stages")"
done
pass "list-stages names both new stages alongside the two that were already opt-in"

# Every name it prints must dispatch. run_stage turns dashes into underscores.
while IFS= read -r s; do
  [[ -n $s ]] || continue
  declare -F "${s//-/_}" >/dev/null ||
    fail_test "every name list-stages prints resolves to a function" \
      "'${s}' maps to ${s//-/_}, which does not exist -- CI would invoke it and get a usage error"
done <"$work/list-stages"
pass "every stage list-stages prints dispatches to a real function"

# The help text is the only place the escape hatch is discoverable before you
# need it. On a Deck, "need it" means no graphical session.
bash "$REPO_ROOT/src/deck-session.sh" --help >"$work/help" 2>&1 ||
  fail_test "'deck-session.sh --help' exits 0" "$(cat "$work/help")"
for needle in stage-boot-default-gaming stage-menu-row "$BOOT_DEFAULT_OVERRIDE" "systemctl disable ${BOOT_DEFAULT_UNIT_NAME}"; do
  grep -qF -- "$needle" "$work/help" ||
    fail_test "--help mentions '${needle}'" \
      "the boot-time re-assert has to be undoable by someone who cannot reach a desktop, and this is where they would look. Got:"$'\n'"$(cat "$work/help")"
done
pass "--help documents both new stages and both forms of the escape hatch"

# stage-power-button's undo is the same class of thing and lives in the same
# place: someone whose Deck now suspends when they did not want it to has to be
# able to find both files, and the ORDER, without this repository in front of
# them. The handler must come off first -- removing only the udev rule puts the
# duplicate press back underneath a live HandlePowerKey=suspend.
for needle in stage-power-button "rm -f ${POWER_LOGIND_DROPIN}" "rm -f ${POWER_UDEV_RULE}"; do
  grep -qF -- "$needle" "$work/help" ||
    fail_test "--help mentions '${needle}'" \
      "the power-button stage rewires a hardware button on a device with no keyboard; its undo has to be discoverable here. Got:"$'\n'"$(cat "$work/help")"
done
help_conf_line=$(grep -nF -- "rm -f ${POWER_LOGIND_DROPIN}" "$work/help" | head -1 | cut -d: -f1)
help_rule_line=$(grep -nF -- "rm -f ${POWER_UDEV_RULE}" "$work/help" | head -1 | cut -d: -f1)
[[ $help_conf_line -lt $help_rule_line ]] ||
  fail_test "--help lists the logind drop-in's removal BEFORE the udev rule's" \
    "the order is the safety property: removing the udev rule first restores the duplicate KEY_POWER press underneath a handler that is still set to suspend, which is the re-suspend loop. Got the drop-in at line ${help_conf_line} and the rule at ${help_rule_line}."
pass "--help documents stage-power-button's undo, with the handler removed before the tags are restored"

grep -qF -- "$POWER_MODEL" "$work/help" ||
  fail_test "--help says which hardware stage-power-button supports" \
    "every device path it uses was measured on a ${POWER_MODEL}; CLAUDE.md forbids claiming support for a model nobody has tested, and the help text is where that claim is most visible. Got:"$'\n'"$(cat "$work/help")"
pass "--help names ${POWER_MODEL} as the only model stage-power-button runs on"

# ---------------------------------------------------------------------------
# 9c. The boot unit -- ordering is the entire point of it
#
# 🔴 A unit ordered AFTER the display manager parses cleanly, starts cleanly,
# writes the config successfully, logs success, and does nothing at all: sddm
# has already read /etc/sddm.conf.d by then. That is the exact class of silent
# no-op this project exists to eliminate, and it is invisible from everywhere
# except the ordering directives.
#
# The ordering was determined from the units on this machine, not from habit:
#   /usr/lib/systemd/system/sddm.service  ->  [Install] Alias=display-manager.service
#   graphical.target                      ->  Wants= and After= display-manager.service

boot_unit="$work/deck-boot-default-gaming.service"
render_boot_default_unit >"$boot_unit"

grep -qF -- "$INSTALL_MARKER" "$boot_unit" ||
  fail_test "the boot unit carries the '#'-commented marker" "expected: ${INSTALL_MARKER}"
pass "the boot unit carries '${INSTALL_MARKER}', so a re-run recognises its own file"

for section in '[Unit]' '[Service]' '[Install]'; do
  grep -qxF -- "$section" "$boot_unit" ||
    fail_test "the boot unit declares ${section}" \
      "a setting outside its section is 'Unknown key ... ignoring' and the unit still loads. File:"$'\n'"$(cat "$boot_unit")"
done
pass "the boot unit declares [Unit], [Service] and [Install]"

grep -qx "Before=${BOOT_DEFAULT_BEFORE_ALIAS}" "$boot_unit" ||
  fail_test "the boot unit is ordered Before=${BOOT_DEFAULT_BEFORE_ALIAS}" \
    "without it the re-assert lands after sddm has read its config: the write succeeds, nothing complains, and the Deck boots to whatever the desktop left behind. File:"$'\n'"$(cat "$boot_unit")"
grep -qx "Before=${BOOT_DEFAULT_BEFORE_REAL}" "$boot_unit" ||
  fail_test "the boot unit is ordered Before=${BOOT_DEFAULT_BEFORE_REAL} as well" \
    "display-manager.service is only an ALIAS, created by 'systemctl enable sddm'. Ordering against a unit name that does not exist is a silent no-op in systemd, so both names are named."
pass "the boot unit is ordered before the display manager under both of its names"

! grep -qE '^After=.*(display-manager|sddm)' "$boot_unit" ||
  fail_test "the boot unit is never ordered AFTER the display manager" \
    "that is the silent no-op: sddm reads /etc/sddm.conf.d at start, so a write that lands afterwards changes nothing until the boot after next. File:"$'\n'"$(cat "$boot_unit")"
pass "no After= in the boot unit names the display manager"

grep -qx "ExecStart=${SELECT_BIN} gamescope --no-restart" "$boot_unit" ||
  fail_test "the boot unit re-runs the EXISTING writer" \
    "expected exactly 'ExecStart=${SELECT_BIN} gamescope --no-restart'. A second implementation of that write is the drift this project keeps paying for; --no-restart is required because sddm has not started yet. File:"$'\n'"$(cat "$boot_unit")"
pass "the boot unit runs '${SELECT_BIN} gamescope --no-restart' -- the writer stage-session-select already installed"

! grep -qE '^ExecStart=-' "$boot_unit" ||
  fail_test "the boot unit's ExecStart= is not prefixed with '-'" \
    "a '-' tells systemd to ignore a non-zero exit; the unit would go active on a re-assert that failed, and a failed unit is this project's only no-terminal signal"
pass "the boot unit's ExecStart= carries no '-' prefix, so a failed re-assert shows up in 'systemctl --failed'"

# 🔴 Loud, but never fatal. Nothing may make the graphical boot DEPEND on this
# unit: a Requires= would turn a failed re-assert into a Deck that does not
# reach a display manager at all.
! grep -qE '^(Requires|RequiredBy|BindsTo|Requisite)=' "$boot_unit" ||
  fail_test "nothing in the boot unit creates a hard dependency" \
    "failure must leave the machine booting normally into whatever the default was. Only ordering and Wants= are allowed here. File:"$'\n'"$(cat "$boot_unit")"
grep -qx 'WantedBy=graphical.target' "$boot_unit" ||
  fail_test "the boot unit is WantedBy=graphical.target" \
    "graphical.target is what pulls the display manager in, so being wanted by it is what puts this unit in the same transaction the Before= orders. WantedBy=sddm.service would drag it into every session SWITCH instead. File:"$'\n'"$(cat "$boot_unit")"
pass "the boot unit is Wanted by graphical.target and required by nothing -- a failure cannot stop the Deck booting"

grep -qx "ConditionPathExists=!${BOOT_DEFAULT_OVERRIDE}" "$boot_unit" ||
  fail_test "the boot unit carries the escape-hatch condition" \
    "with this unit enabled a broken Gaming Mode is re-asserted at EVERY boot, and the operator has one device. 'touch ${BOOT_DEFAULT_OVERRIDE}' has to be enough to stop it. File:"$'\n'"$(cat "$boot_unit")"
pass "a single 'touch ${BOOT_DEFAULT_OVERRIDE}' skips the unit -- no editor, no unit file, no systemctl"

grep -qx 'Type=oneshot' "$boot_unit" ||
  fail_test "the boot unit is Type=oneshot" "it runs one command and exits"
grep -qx 'RemainAfterExit=yes' "$boot_unit" ||
  fail_test "the boot unit is RemainAfterExit=yes" \
    "without it the unit returns to inactive and could be re-triggered mid-boot; with it, the re-assert happens once per boot, which is what makes Desktop Mode a one-shot session"
pass "the boot unit is a Type=oneshot with RemainAfterExit=yes -- one re-assert per boot"

# ---------------------------------------------------------------------------
# 9d. stage-power-button -- the two files, and the two traps they are shaped by
#
# The stage BODY (its verifiers, its write order, its refusals) is covered in
# test/unit/test-deck-session-stages.sh §14. What is here is what this suite is
# for: the generated text, and the pure name comparison that decides whether
# either file will be read at all.
#
# 🔴 BOTH TRAPS ARE INVISIBLE IN A PASSING INSTALL, which is why they are
# pinned here rather than left to a hardware session:
#
#   1. HandlePowerKey= defaults to `poweroff`, not `suspend` (man logind.conf,
#      systemd 261). A drop-in that overrides Omarchy's `ignore` without
#      naming a value installs cleanly and hard-powers-off the Deck on every
#      tap. So the value is asserted as an exact line, not as a substring.
#   2. One physical press produces TWO KEY_POWER presses on this hardware
#      (MEASURED, T13 §2.2). If the udev rule fails to remove the duplicate --
#      because it names TAG+= instead of TAG-=, or because it is read before
#      the rule that adds the tag -- then a correct-looking logind drop-in
#      produces two suspend requests ~198 ms apart, the second landing at or
#      just after resume. On a device whose only other escape is a ten-second
#      hold, that is indistinguishable from a Deck that will not wake.

power_rule="$work/zz-deck-power-button.rules"
power_conf="$work/zz-deck-power-button.conf"
render_power_udev_rule >"$power_rule"
render_power_logind_dropin >"$power_conf"

grep -qF -- "$INSTALL_MARKER" "$power_rule" ||
  fail_test "the udev rule carries the '#'-commented marker" "expected: ${INSTALL_MARKER}"
grep -qF -- "$INSTALL_MARKER" "$power_conf" ||
  fail_test "the logind drop-in carries the '#'-commented marker" "expected: ${INSTALL_MARKER}"
pass "both power-button files carry '${INSTALL_MARKER}', so a re-run recognises its own output"

# --- the udev rule ---------------------------------------------------------

# The RULE lines, as distinct from the (large) comment block: anything that is
# not blank and does not start with '#'. Every assertion below that talks about
# what udev will DO reads this list, so a device path mentioned only in prose
# cannot satisfy one of them.
mapfile -t power_rule_lines < <(grep -v '^[[:space:]]*#' "$power_rule" | grep -v '^[[:space:]]*$')

for p in "${POWER_ACPI_ID_PATHS[@]}"; do
  grep -qxF -- "ENV{ID_PATH}==\"${p}\", TAG-=\"${POWER_UDEV_TAG}\"" "$power_rule" ||
    fail_test "the udev rule untags ID_PATH=${p}" \
      "expected exactly 'ENV{ID_PATH}==\"${p}\", TAG-=\"${POWER_UDEV_TAG}\"'. A rule that names the node but not the tag removal is a no-op, and the duplicate KEY_POWER press survives into a machine whose handler is armed. File:"$'\n'"$(cat "$power_rule")"
done
pass "the udev rule untags every ACPI power-button node in POWER_ACPI_ID_PATHS (${POWER_ACPI_ID_PATHS[*]})"

power_untag_count=$(printf '%s\n' "${power_rule_lines[@]}" | grep -c -- "TAG-=\"${POWER_UDEV_TAG}\"" || true)
[[ $power_untag_count -eq ${#POWER_ACPI_ID_PATHS[@]} ]] ||
  fail_test "the udev rule untags exactly ${#POWER_ACPI_ID_PATHS[@]} node(s)" \
    "found ${power_untag_count} untag lines. Every extra one is a device logind stops watching, and the whole design depends on exactly one surviving."
pass "the udev rule has exactly ${#POWER_ACPI_ID_PATHS[@]} untag lines -- no more devices are silently dropped than the ones measured"

# 🔴 The mutation this pins: TAG+= where TAG-= belongs. It parses, it applies,
# and it ADDS a tag that was already there -- so nothing changes, the duplicate
# press survives, and the only symptom is a Deck that suspends twice.
! printf '%s\n' "${power_rule_lines[@]}" | grep -qF -- 'TAG+=' ||
  fail_test "no rule line ADDS a tag" \
    "'TAG+=' in this file would leave both KEY_POWER sources tagged while the logind drop-in installed alongside it suspends on each of them. Only '-=' removes (udev(7)). File:"$'\n'"$(cat "$power_rule")"
pass "no rule line uses TAG+= -- this file only ever removes the tag"

! printf '%s\n' "${power_rule_lines[@]}" | grep -qF -- "$POWER_KEEP_ID_PATH" ||
  fail_test "no rule line touches ${POWER_KEEP_ID_PATH}" \
    "that node is the single source this design KEEPS -- the real key, the only one that tracks a hold. Untagging it would leave systemd-logind watching no power switch at all and the button would go from flashing a menu to doing nothing. File:"$'\n'"$(cat "$power_rule")"
pass "no rule line touches ${POWER_KEEP_ID_PATH}, the one node that survives as logind's single source"

for p in "${POWER_ACPI_ID_PATHS[@]}"; do
  [[ $p != "$POWER_KEEP_ID_PATH" ]] ||
    fail_test "POWER_KEEP_ID_PATH is not also in POWER_ACPI_ID_PATHS" \
      "the constants contradict each other: the node the design keeps is also on the list it untags"
done
pass "the constants agree -- POWER_KEEP_ID_PATH is not on the untag list"

# The lid switch carries the same tag from the same upstream rule and was never
# measured. Touching it would change HandleLidSwitch= behaviour as a side
# effect of a power-button fix.
! printf '%s\n' "${power_rule_lines[@]}" | grep -qF -- 'PNP0C0D' ||
  fail_test "the udev rule leaves the Lid Switch alone" \
    "acpi-PNP0C0D:00 is tagged by the same upstream rule, but nothing about the lid was measured and HandleLidSwitch= is a separate question. File:"$'\n'"$(cat "$power_rule")"
pass "the udev rule does not touch the Lid Switch -- only the power key changes"

# udev refuses to load a rules FILE whose GOTO has no matching LABEL, so a
# mismatch here silently drops every rule in it, including the untag lines.
while IFS= read -r goto_target; do
  grep -qxF -- "LABEL=\"${goto_target}\"" "$power_rule" ||
    fail_test "every GOTO in the udev rule has a matching LABEL" \
      "GOTO=\"${goto_target}\" has no LABEL. udev drops the whole FILE, so the untag lines never run and the duplicate press survives. File:"$'\n'"$(cat "$power_rule")"
done < <(grep -o 'GOTO="[^"]*"' "$power_rule" | sed 's/GOTO="//; s/"$//' | sort -u)
pass "every GOTO target in the udev rule has a matching LABEL, so udev will load the file"

grep -qF -- 'SUBSYSTEM!="input"' "$power_rule" ||
  fail_test "the udev rule leaves non-input devices immediately" \
    "without the guard every uevent on the machine is compared against these rules. File:"$'\n'"$(cat "$power_rule")"
pass "the udev rule guards on SUBSYSTEM and KERNEL before it matches anything"

# --- the logind drop-in ----------------------------------------------------

mapfile -t power_conf_lines < <(grep -v '^[[:space:]]*#' "$power_conf" | grep -v '^[[:space:]]*$')

grep -qxF -- '[Login]' "$power_conf" ||
  fail_test "the logind drop-in declares [Login]" \
    "a setting outside its section is 'Unknown section, ignoring' -- the file loads, nothing complains, and the power button keeps doing what Omarchy's 10-ignore-power-button.conf says. File:"$'\n'"$(cat "$power_conf")"
pass "the logind drop-in declares [Login], so its settings are not silently discarded"

# 🔴 TRAP 1, pinned as an EXACT line and counted. A substring match would pass
# with `HandlePowerKey=poweroff`; an absent line would pass anything that
# merely mentions the setting in a comment.
grep -qxF -- "HandlePowerKey=${POWER_KEY_ACTION}" "$power_conf" ||
  fail_test "the logind drop-in sets HandlePowerKey=${POWER_KEY_ACTION} EXPLICITLY" \
    "HandlePowerKey= DEFAULTS TO poweroff (man logind.conf, systemd 261 -- the version the Deck runs). A drop-in that overrides Omarchy's 'ignore' without naming a value hard-powers-off the Deck on every tap: data loss on every press, and an easy misread as 'sleep is broken'. File:"$'\n'"$(cat "$power_conf")"
power_key_assignments=$(printf '%s\n' "${power_conf_lines[@]}" | grep -c '^HandlePowerKey=' || true)
[[ $power_key_assignments -eq 1 ]] ||
  fail_test "HandlePowerKey= is assigned exactly once" \
    "found ${power_key_assignments} assignments; within one file the last wins, so a second one decides the behaviour and the first is decoration"
pass "the logind drop-in sets HandlePowerKey=${POWER_KEY_ACTION} exactly once, as an explicit value"

[[ $POWER_KEY_ACTION == suspend ]] ||
  fail_test "POWER_KEY_ACTION is 'suspend'" \
    "got '${POWER_KEY_ACTION}'. This is the whole defect being fixed: a short press must suspend, not power off and not ignore."
pass "POWER_KEY_ACTION is 'suspend' -- what one short press does"

grep -qxF -- "HandlePowerKeyLongPress=${POWER_KEY_LONG_PRESS_ACTION}" "$power_conf" ||
  fail_test "the logind drop-in pins HandlePowerKeyLongPress=${POWER_KEY_LONG_PRESS_ACTION}" \
    "systemd's own default is 'ignore', but it is restated here so the file says what the Deck does rather than inheriting it from whatever else lands in logind.conf.d. File:"$'\n'"$(cat "$power_conf")"
[[ $POWER_KEY_LONG_PRESS_ACTION == ignore ]] ||
  fail_test "POWER_KEY_LONG_PRESS_ACTION is 'ignore'" \
    "got '${POWER_KEY_LONG_PRESS_ACTION}'. A long-press action would fire at a threshold NOBODY HAS READ -- systemd's LONG_PRESS_DURATION is unread, and SteamOS's 1 s belongs to powerbuttond's alarm(1), a different program (T13 §4.0/§4.1) -- and it would shadow the ten-second hardware hold docs/RECOVERY.md documents as the escape of last resort."
pass "long press is explicitly 'ignore': no threshold this project has not read is relied on, and the ten-second hold keeps its meaning"

! printf '%s\n' "${power_conf_lines[@]}" | grep -q '=poweroff' ||
  fail_test "nothing in the logind drop-in assigns 'poweroff'" \
    "the power button must never hard-power-off the Deck from a short OR a long press. File:"$'\n'"$(cat "$power_conf")"
pass "no setting in the logind drop-in assigns 'poweroff'"

# 🔴 The whole file, line by line. This is what keeps a duration -- or a
# HandleLidSwitch=, or a HandleSuspendKey= -- from arriving unnoticed in a file
# whose comment block is forty lines long. Anything logind acts on has to be
# one of exactly these three lines.
power_expected_conf=$'[Login]\nHandlePowerKey='"${POWER_KEY_ACTION}"$'\nHandlePowerKeyLongPress='"${POWER_KEY_LONG_PRESS_ACTION}"
[[ $(printf '%s\n' "${power_conf_lines[@]}") == "$power_expected_conf" ]] ||
  fail_test "the logind drop-in's settings are EXACTLY the three expected lines" \
    "this drop-in is system-wide and changes what a hardware button does; every setting in it has to be one somebody argued for. Expected:"$'\n'"${power_expected_conf}"$'\n'"got:"$'\n'"$(printf '%s\n' "${power_conf_lines[@]}")"
pass "the logind drop-in contains exactly three settings and no fourth -- no duration, no lid, no suspend key"

# --- the names, which decide whether either file is read at all ------------
#
# 🔴 This is the check the SDDM drop-in did not have. Its comment claimed
# '95-deck-session.conf' sorted after 'autologin.conf'; '9' < 'a', so it never
# did, on any machine, and Gaming Mode had simply never been booted. The last
# case below pins that exact historical mistake so the comparator itself cannot
# regress into agreeing with the comment that was wrong.
power_sorts_after "${POWER_UDEV_RULE##*/}" "$POWER_UDEV_TAGGER" ||
  fail_test "${POWER_UDEV_RULE##*/} is read AFTER ${POWER_UDEV_TAGGER}" \
    "udev merges every rules directory into one filename-sorted sequence. Read first, our file removes a tag that has not been added yet: it parses, it applies, and it does nothing -- leaving the duplicate KEY_POWER press underneath a handler that suspends on it."
pass "${POWER_UDEV_RULE##*/} sorts after ${POWER_UDEV_TAGGER}, so the tag exists by the time it is removed"

power_sorts_after "${POWER_LOGIND_DROPIN##*/}" 10-ignore-power-button.conf ||
  fail_test "${POWER_LOGIND_DROPIN##*/} is read AFTER Omarchy's 10-ignore-power-button.conf" \
    "systemd merges logind.conf.d from /etc, /run and /usr/lib into one basename-sorted sequence, and the LAST assignment wins. Sorted first, our file is overridden: it is on disk, it reads correctly, and HandlePowerKey is still 'ignore'. That package-owned file cannot simply be deleted -- pacman --overwrite restores it on the next Omarchy upgrade."
pass "${POWER_LOGIND_DROPIN##*/} sorts after Omarchy's package-owned 10-ignore-power-button.conf, so it wins without editing a file we do not own"

power_sorts_after zz-deck-power-button.conf zz-deck-power-button.conf &&
  fail_test "power_sorts_after is strict -- a name does not sort after itself" \
    "a comparator that answers 'yes' for equal names would bless a rival with our own basename in another directory"
pass "power_sorts_after is strict: equal names do not satisfy it"

power_sorts_after 95-deck-session.conf autologin.conf &&
  fail_test "power_sorts_after reproduces the 95-/autologin bug rather than hiding it" \
    "'9' < 'a', so 95-deck-session.conf sorted BEFORE autologin.conf and the SDDM drop-in silently never applied. A comparator that says otherwise agrees with the comment that was wrong."
pass "power_sorts_after answers the historical 95-/autologin case correctly ('9' < 'a'), so it would have caught that bug"

# ===========================================================================
# run_as_desktop_user -- the SUDO="" regression, found on real hardware
# ===========================================================================
#
# 2026-08-12: `sudo ./deck-session.sh stage-desktop-settings` on the Deck --
# root from the start, so stage_preconditions sets SUDO="" -- failed with
# `-u: command not found` and never wrote the idle policy. Three call sites in
# stage_desktop_settings did `$SUDO -u "$invoking_user" ...` directly; with
# SUDO="" that expands to `-u "$invoking_user" ...`, which bash tries to run as
# a command named '-u'. A comment beside run_as_desktop_user had predicted this
# exact failure and left those three sites unfixed "deliberately... a separate
# change with its own tests" -- and no test ever existed for either half.
# Fixed by routing all three through run_as_desktop_user, which is itself
# untested until now.

# Branch 1: SUDO is set (the ordinary `./deck-session.sh` invocation, not yet
# root). Must invoke exactly `$SUDO -u <user> <cmd...>` -- captured via a stub
# standing in for $SUDO, so this is the argv actually built, not an inference.
rasdu_stub_out=$(mktemp)
rasdu_stub=$(mktemp)
cat >"$rasdu_stub" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$RASDU_CAPTURE"
STUB
chmod +x "$rasdu_stub"
RASDU_CAPTURE="$rasdu_stub_out" SUDO="$rasdu_stub" bash -c '
  . "$1"
  SUDO="$2"
  run_as_desktop_user someuser echo hello
' _ "$REPO_ROOT/src/deck-session.sh" "$rasdu_stub" || true
[[ $(cat "$rasdu_stub_out") == "-u someuser echo hello" ]] ||
  fail_test "run_as_desktop_user invokes '\$SUDO -u <user> <cmd...>' when SUDO is set" \
    "captured: '$(cat "$rasdu_stub_out")'"
pass "run_as_desktop_user, SUDO set: invokes '\$SUDO -u <user> <cmd...>' -- the ordinary case"
rm -f "$rasdu_stub_out" "$rasdu_stub"

# Branch 2: SUDO="" and not root (this test process). Historically this was
# EXACTLY the state that silently ran '-u' as a command -- a write that never
# happened, with no error surfaced to the stage's caller in a form a human
# would read as "the idle policy was not set". run_as_desktop_user must fail
# LOUDLY here instead, naming why, rather than doing nothing.
rasdu_err=$(mktemp)
rasdu_rc=0
bash -c '
  . "$1"
  SUDO=""
  run_as_desktop_user someuser echo hello
' _ "$REPO_ROOT/src/deck-session.sh" >/dev/null 2>"$rasdu_err" || rasdu_rc=$?
[[ $rasdu_rc -ne 0 ]] ||
  fail_test "run_as_desktop_user fails when SUDO is empty and this process is not root" \
    "exited 0 -- meaning it either ran 'echo hello' as OUR uid (wrong user, silently) or ran '-u' as a command and swallowed the failure. Either way nothing readable reached the caller."
grep -qF -- 'someuser' "$rasdu_err" ||
  fail_test "the failure names the user it could not become" "$(cat "$rasdu_err")"
grep -qiE -- '-u:? command not found' "$rasdu_err" &&
  fail_test "the OLD bug reproduced: '-u' was executed as a command" \
    "$(cat "$rasdu_err") -- run_as_desktop_user regressed to the unguarded \$SUDO -u form"
pass "run_as_desktop_user, SUDO empty + not root: fails loudly naming the user, not '-u: command not found'"
rm -f "$rasdu_err"

# The three sites this bug actually lived in must route through the guarded
# helper, not the raw form -- grepped on the SOURCE, so a future edit that
# reintroduces '$SUDO -u' anywhere in the file is caught before it ships,
# without needing root to exercise it.
# shellcheck disable=SC2016  # the single quotes are intentional: this is a
# grep pattern that must match the LITERAL text `$SUDO -u` in the source, not
# expand it. Expanding it would defeat the whole point of the guard.
raw_sudo_u_sites=$(grep -n '\$SUDO -u ' "$REPO_ROOT/src/deck-session.sh" | grep -v '^[0-9]*:#' || true)
[[ -z $raw_sudo_u_sites ]] ||
  fail_test "no call site uses the unguarded '\$SUDO -u' form -- every one must go through run_as_desktop_user" \
    "$raw_sudo_u_sites"
pass "no call site in src/deck-session.sh uses the unguarded '\$SUDO -u <user>' form"

# ===========================================================================
# 10. Steam's first run -- the race, and the two silent minutes (PROGRESS.md 5.35)
# ===========================================================================
#
# Two artefacts, and BOTH are tested by RUNNING them rather than by reading
# them, because both are load-bearing in the same way: they are allowed to fail
# at what they do, and they are not allowed to take Gaming Mode down with them.
# That is a behavioural claim and a grep cannot make it.
#
#   E2  the bounded wait -- an ExecStartPre= on Valve's steam-launcher.service.
#       A non-zero exit there means Steam does not start, i.e. a Wi-Fi problem
#       becomes an unusable Deck. It must exit 0 on every path there is.
#   E1  the splash -- a fullscreen "don't turn me off, Steam is unpacking"
#       notice. A splash that cannot exit is a permanently black-with-text
#       panel, which is strictly worse than the two minutes of black it
#       replaces. It must come down: when Steam appears, when its viewer dies,
#       and when neither happens.
echo "# 10. Steam's first run"

sfr_work=$(mktemp -d)
sfr_bin="$sfr_work/bin"
mkdir -p "$sfr_bin"

# --- E2: the wait always exits 0 -------------------------------------------
wait_sh="$sfr_work/steam-wait-online"
bash -c 'source "$1"; render_steam_wait_online' _ "$REPO_ROOT/src/deck-session.sh" >"$wait_sh"
bash -n "$wait_sh" || fail_test "the rendered wait script is valid bash" "$(cat "$wait_sh")"
chmod +x "$wait_sh"
pass "render_steam_wait_online emits syntactically valid bash"

# 🔴 IT MUST NOT WAIT ON network-online.target. deck_wifi.py's first-boot unit
# takes Wants=network.target deliberately, because on a Deck with no network
# that target is reached only by TIMEOUT -- the cost landing on exactly the
# machines least able to afford it. On this hardware it is worse than that:
# NetworkManager-wait-online.service is MASKED (read off the Deck 2026-08-15),
# so the target is never reached at all.
# Code only: the file EXPLAINS the trap in a comment, which is the opposite of
# falling into it.
wait_code=$(grep -v '^[[:space:]]*#' "$wait_sh")
! grep -q 'network-online' <<<"$wait_code" ||
  fail_test "the wait does not depend on network-online.target" \
    "on a networkless Deck that is a timeout, and here it is a target nothing ever reaches. Found:"$'\n'"$(grep -n 'network-online' <<<"$wait_code")"
pass "the wait never mentions network-online.target -- the trap deck_wifi.py documents"

# BOUNDED, and the bound is an argument to the tool rather than a sleep.
grep -qE -- "-t ${STEAM_WAIT_SECONDS}\b" "$wait_sh" ||
  fail_test "the wait passes its own ceiling to nm-online" "$(cat "$wait_sh")"
[[ $STEAM_WAIT_SECONDS -gt 0 && $STEAM_WAIT_SECONDS -le 60 ]] ||
  fail_test "the ceiling is a bound a handheld can afford" \
    "STEAM_WAIT_SECONDS=${STEAM_WAIT_SECONDS}; the retry that succeeded was ONE second after the failure, so the number's job is to be small and finite"
pass "the wait is bounded at ${STEAM_WAIT_SECONDS}s, passed to nm-online as its own timeout"

# Now run it, in each of the three states the target can be in. nm-online is
# reached by ABSOLUTE path (the constant), so each state is set up by pointing
# that path somewhere rather than by PATH order -- which also means this suite
# behaves the same on a dev machine that happens to have NetworkManager.
wait_missing="$sfr_work/steam-wait-online-missing"
sed "s|${NM_ONLINE_BIN}|${sfr_work}/definitely-not-installed|g" "$wait_sh" >"$wait_missing"
chmod +x "$wait_missing"

# (a) nm-online missing entirely.
SFR_RC=0
SFR_OUT=$("$wait_missing" 2>&1) || SFR_RC=$?
[[ $SFR_RC -eq 0 ]] ||
  fail_test "with no nm-online at all the wait still exits 0" "rc=${SFR_RC}"$'\n'"$SFR_OUT"
grep -q 'not installed' <<<"$SFR_OUT" ||
  fail_test "and says why, rather than passing silently" "$SFR_OUT"
pass "no nm-online: exits 0 and says so -- a missing tool cannot stop Gaming Mode starting"

# (b) nm-online present and FAILING -- the networkless Deck, the case the bound
#     exists for. This is the one that would strand a user if it propagated.
nm_stub="$sfr_work/nm-online"
cat >"$nm_stub" <<'NMSTUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$NM_ARGS"
exit 1
NMSTUB
chmod +x "$nm_stub"
nm_args="$sfr_work/nm.args"
: >"$nm_args"
# The script calls nm-online by ABSOLUTE path (the constant), so the stub is
# injected by pointing that path at it rather than by PATH order.
wait_stubbed="$sfr_work/steam-wait-online-stubbed"
sed "s|${NM_ONLINE_BIN}|${nm_stub}|g" "$wait_sh" >"$wait_stubbed"
chmod +x "$wait_stubbed"
SFR_RC=0
SFR_OUT=$(NM_ARGS="$nm_args" "$wait_stubbed" 2>&1) || SFR_RC=$?
[[ $SFR_RC -eq 0 ]] ||
  fail_test "a FAILED connectivity wait still exits 0" \
    "rc=${SFR_RC}. This runs as ExecStartPre= on steam-launcher.service: a non-zero exit here turns 'no Wi-Fi' into 'Gaming Mode does not start', which is a far worse defect than the modal this removes."$'\n'"$SFR_OUT"
grep -q 'Starting Steam ANYWAY' <<<"$SFR_OUT" ||
  fail_test "and it says it is proceeding regardless" "$SFR_OUT"
grep -qE -- "-t ${STEAM_WAIT_SECONDS}" "$nm_args" ||
  fail_test "the bound really reached nm-online" "captured: $(cat "$nm_args")"
# 🔴 THE DEFECT P33 SHIPPED, ASSERTED AS A BEHAVIOUR AND NOT AS A STRING.
#
# P33 waited with `nm-online -s` ALONE. From nm-online(1): "After startup has
# completed, nm-online -s will just return immediately, regardless of the current
# network state." NetworkManager reaches startup-complete early in boot and
# graphical.target on this Deck is at 20.25 s, so the condition was always
# already true and the wait was a no-op -- which is what the 2026-08-16 hardware
# boot showed: the drop-in was installed and Steam still hit "Steam needs to be
# online to update."
#
# So the requirement is: at least one nm-online invocation that does NOT pass -s,
# because that is the only kind that can wait for connectivity. The -s call may
# stay (it is phase 1, and it is what makes phase 2's answer meaningful) but it
# may not be the only one.
mapfile -t nm_calls <"$nm_args"
[[ ${#nm_calls[@]} -ge 2 ]] ||
  fail_test "the wait makes more than one nm-online call" \
    "captured ${#nm_calls[@]}: $(cat "$nm_args"). One call can only answer one of 'has NM finished trying' and 'is this machine online', and P33 answered the wrong one."
connectivity_calls=0
for call in "${nm_calls[@]}"; do
  [[ " $call " == *" -s "* ]] && continue
  connectivity_calls=$((connectivity_calls + 1))
done
[[ $connectivity_calls -ge 1 ]] ||
  fail_test "🔴 at least one nm-online call waits for CONNECTIVITY, not just for NM's startup" \
    "every call passed -s, and nm-online(1) says -s returns immediately once startup has completed 'regardless of the current network state'. That is P33's defect: an installed drop-in that waits for nothing. captured:"$'\n'"$(cat "$nm_args")"
grep -qE -- '(^| )-x( |$)' "$nm_args" ||
  fail_test "and the connectivity wait has the networkless escape hatch" \
    "without -x ('Exit immediately if NetworkManager is not running or connecting') a Deck with no network burns the whole ${STEAM_WAIT_SECONDS}s at EVERY Gaming Mode start -- the trap -s was standing in for. captured:"$'\n'"$(cat "$nm_args")"
grep -qE -- '-s' "$nm_args" ||
  fail_test "phase 1 still asks whether NM finished trying" \
    "without it, a Deck whose Wi-Fi has not yet begun activating reads as 'not connecting' and -x returns at once -- the race reopens. captured: $(cat "$nm_args")"
pass "🔴 nm-online failing: exits 0, says it is proceeding, and made ${#nm_calls[@]} calls of which ${connectivity_calls} waits for connectivity rather than only for startup"

# (c) the happy path.
cat >"$nm_stub" <<'NMSTUB'
#!/usr/bin/env bash
exit 0
NMSTUB
SFR_RC=0
SFR_OUT=$(NM_ARGS="$nm_args" "$wait_stubbed" 2>&1) || SFR_RC=$?
# shellcheck disable=SC2015  # `fail` exits; guard, not if-then-else
[[ $SFR_RC -eq 0 ]] && grep -q 'connectivity confirmed' <<<"$SFR_OUT" ||
  fail_test "the connected case reports the connection" "rc=${SFR_RC}"$'\n'"$SFR_OUT"
pass "nm-online succeeding: exits 0 and reports the connection"

# (d) nm-online present but rejecting an option -- exit 2, which is what it
#     returns for "unknown or unspecified error" AND for an option it does not
#     understand. -x is not verified on the target's NetworkManager, so the one
#     state that would tell us must not be reported as "you are offline".
cat >"$nm_stub" <<'NMSTUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$NM_ARGS"
exit 2
NMSTUB
SFR_RC=0
SFR_OUT=$(NM_ARGS="$nm_args" "$wait_stubbed" 2>&1) || SFR_RC=$?
[[ $SFR_RC -eq 0 ]] ||
  fail_test "an nm-online ERROR still exits 0" "rc=${SFR_RC}"$'\n'"$SFR_OUT"
grep -q 'an error, not an answer' <<<"$SFR_OUT" ||
  fail_test "and is reported as an error rather than as 'offline'" \
    "the two want different fixes, and this script is the only thing that will ever have seen the difference:"$'\n'"$SFR_OUT"
pass "nm-online exiting 2: exits 0 and names it an error, not an offline machine"

# The wait writes where the first boot can still be read from. §5.35 measured
# that this Deck's persistent journal held only boot 0, so a first-run script
# that reports only to the journal reports to nobody.
grep -q "$FIRST_BOOT_LOG_REL" "$wait_sh" ||
  fail_test "the wait leaves a record that outlives the boot" \
    "it does not mention ~/${FIRST_BOOT_LOG_REL}, so its outcome is journal-only -- and the one boot it runs on is the one whose journal was not retained"
pass "the wait also appends to ~/${FIRST_BOOT_LOG_REL}, which survives the boot"

# --- E1: the splash comes down ---------------------------------------------
splash_sh="$sfr_work/splash"
bash -c 'source "$1"; render_steam_splash' _ "$REPO_ROOT/src/deck-session.sh" >"$splash_sh"
bash -n "$splash_sh" || fail_test "the rendered splash is valid bash" "$(cat "$splash_sh")"
pass "render_steam_splash emits syntactically valid bash"

# A fake viewer that never exits on its own -- the whole question is whether
# something else takes it down.
viewer_stub="$sfr_work/fake-imv"
cat >"$viewer_stub" <<'VSTUB'
#!/usr/bin/env bash
printf 'started\n' >"$VIEWER_MARK"
while true; do sleep 0.2; done
VSTUB
chmod +x "$viewer_stub"

splash_image="$sfr_work/splash.png"
: >"$splash_image"

# splash_variant <deadline-seconds> -> a runnable copy with the real viewer and
# image paths redirected at the stubs. The deadline is shrunk so the timeout
# case is testable in seconds rather than in minutes; everything else about the
# script is the shipped text.
splash_variant() {
  local deadline=$1 out="$sfr_work/splash-run"
  sed -e "s|${SPLASH_VIEWER}|${viewer_stub}|g" \
      -e "s|${SPLASH_IMAGE}|${splash_image}|g" \
      -e "s|+ ${SPLASH_MAX_SECONDS} ))|+ ${deadline} ))|" \
      "$splash_sh" >"$out"
  chmod +x "$out"
  printf '%s' "$out"
}

# pgrep stub: says "Steam is up" only when READY is set.
cat >"$sfr_bin/pgrep" <<'PSTUB'
#!/usr/bin/env bash
[[ -n ${READY:-} ]] && exit 0
exit 1
PSTUB
chmod +x "$sfr_bin/pgrep"

splash_home="$sfr_work/home"
viewer_mark="$sfr_work/viewer.mark"

# GAMESCOPE_WAYLAND_DISPLAY is set for every run that is meant to DRAW, because
# the script now refuses to draw without it -- see the (e) case below, which is
# the one that checks the refusal.
run_splash() {   # run_splash <deadline> [READY=1]
  local script; script=$(splash_variant "$1")
  rm -rf "$splash_home"; mkdir -p "$splash_home"
  : >"$viewer_mark"
  SPLASH_RC=0
  SPLASH_SECONDS=$SECONDS
  SPLASH_OUT=$(HOME="$splash_home" VIEWER_MARK="$viewer_mark" READY="${2:-}" \
    GAMESCOPE_WAYLAND_DISPLAY=gamescope-0 \
    PATH="$sfr_bin:$PATH" timeout 60 "$script" 2>&1) || SPLASH_RC=$?
  SPLASH_ELAPSED=$((SECONDS - SPLASH_SECONDS))
}

# (a) Steam appears -- the NORMAL exit. It must come down promptly and the
#     viewer must not survive it.
run_splash 120 1
[[ $SPLASH_RC -eq 0 ]] ||
  fail_test "the splash exits 0 when Steam appears" "rc=${SPLASH_RC}"$'\n'"$SPLASH_OUT"
grep -q 'splash down' <<<"$SPLASH_OUT" ||
  fail_test "and says it came down" "$SPLASH_OUT"
[[ $SPLASH_ELAPSED -lt 30 ]] ||
  fail_test "it comes down promptly once Steam is up" "took ${SPLASH_ELAPSED}s"
pgrep -f "$viewer_stub" >/dev/null 2>&1 &&
  fail_test "no viewer process survives the splash" "one is still running -- a splash that leaves its viewer up IS the permanently black-with-text panel"
pass "🔴 THE SPLASH EXITS: Steam appearing brings it down in ${SPLASH_ELAPSED}s, and no viewer survives"

# (b) Steam NEVER appears -- the deadline. This is the case that decides whether
#     a splash bug is a message you miss or a Deck you cannot use.
run_splash 4
[[ $SPLASH_RC -eq 0 ]] ||
  fail_test "the splash exits 0 on its deadline too" "rc=${SPLASH_RC}"$'\n'"$SPLASH_OUT"
grep -q 'splash down (deadline)' <<<"$SPLASH_OUT" ||
  fail_test "the deadline path names itself" "$SPLASH_OUT"
[[ $SPLASH_ELAPSED -lt 30 ]] ||
  fail_test "the deadline is honoured" "took ${SPLASH_ELAPSED}s against a 4s deadline"
pgrep -f "$viewer_stub" >/dev/null 2>&1 &&
  fail_test "the deadline path kills the viewer too" "the viewer outlived its own script"
pass "🔴 AND IT EXITS WITHOUT STEAM: the deadline fires, the viewer is killed, nothing is left drawing"

# (c) Shown ONCE. Later boots reach Gaming Mode in ~39 s and a splash in front
#     of a client that is about to draw would be a defect of its own.
marker="$splash_home/$SPLASH_MARKER_REL"
[[ -e $marker ]] ||
  fail_test "the splash leaves a marker" "expected ${marker}"
script=$(splash_variant 120)
SPLASH_RC=0
SPLASH_OUT=$(HOME="$splash_home" VIEWER_MARK="$sfr_work/second.mark" \
  PATH="$sfr_bin:$PATH" timeout 30 "$script" 2>&1) || SPLASH_RC=$?
[[ $SPLASH_RC -eq 0 && -z $SPLASH_OUT ]] ||
  fail_test "a second run does nothing at all" "rc=${SPLASH_RC}"$'\n'"$SPLASH_OUT"
[[ ! -s $sfr_work/second.mark ]] ||
  fail_test "and starts no viewer" "the second boot would cover a Gaming Mode that is about to draw"
pass "shown once: the marker makes every later boot a no-op, so ~39 s boots are untouched"

# (d) A missing image or viewer is today's black screen, not a failure. This is
#     the degradation the whole placement decision is about.
rm -f "$splash_image"
script=$(splash_variant 120)
SPLASH_RC=0
rm -rf "$splash_home"; mkdir -p "$splash_home"
SPLASH_OUT=$(HOME="$splash_home" VIEWER_MARK="$sfr_work/third.mark" \
  PATH="$sfr_bin:$PATH" timeout 30 "$script" 2>&1) || SPLASH_RC=$?
[[ $SPLASH_RC -eq 0 ]] ||
  fail_test "a missing image is not a failure" "rc=${SPLASH_RC}"$'\n'"$SPLASH_OUT"
grep -q 'showing nothing' <<<"$SPLASH_OUT" ||
  fail_test "and it says so" "$SPLASH_OUT"
pass "a missing image degrades to today's black screen, loudly, with exit 0"

# (e) 🔴 NO COMPOSITOR TO DRAW ON. P33 fell through this branch in SILENCE: the
#     `if [[ -n ${GAMESCOPE_WAYLAND_DISPLAY:-} ]]` had no else, so a session
#     environment that did not load meant /usr/bin/imv (a wrapper that picks
#     Wayland only when WAYLAND_DISPLAY is set) execing imv-x11 against a DISPLAY
#     a user unit does not have, dying instantly, and leaving a black panel and
#     no explanation. That is one of the shapes the 2026-08-16 boot could have
#     had, and it was indistinguishable from every other one.
: >"$splash_image"
script=$(splash_variant 120)
rm -rf "$splash_home"; mkdir -p "$splash_home"
SPLASH_RC=0
SPLASH_OUT=$(HOME="$splash_home" VIEWER_MARK="$sfr_work/fourth.mark" \
  PATH="$sfr_bin:$PATH" timeout 30 "$script" 2>&1) || SPLASH_RC=$?
[[ $SPLASH_RC -eq 0 ]] ||
  fail_test "no compositor is not a failed unit" "rc=${SPLASH_RC}"$'\n'"$SPLASH_OUT"
grep -q 'GAMESCOPE_WAYLAND_DISPLAY is not set' <<<"$SPLASH_OUT" ||
  fail_test "🔴 a missing session environment is NAMED, not fallen through" \
    "P33 was silent here and the failure was unattributable. got:"$'\n'"$SPLASH_OUT"
[[ ! -s $sfr_work/fourth.mark ]] ||
  fail_test "and no viewer is started at all" \
    "starting one against the OUTER session puts it behind gamescope's fullscreen surface, where it is invisible AND still has to be killed"
pass "🔴 no GAMESCOPE_WAYLAND_DISPLAY: says so by name, starts no viewer, exits 0"

# (f) 🔴 THE VIEWER DIES IMMEDIATELY -- the shape a real "nothing was drawn"
#     takes, and the one P33 reported as the neutral "the viewer exited".
dying_viewer="$sfr_work/dying-imv"
cat >"$dying_viewer" <<'DSTUB'
#!/usr/bin/env bash
printf 'started\n' >"$VIEWER_MARK"
printf 'Failed to connect to Wayland display\n' >&2
exit 1
DSTUB
chmod +x "$dying_viewer"
script="$sfr_work/splash-dying"
sed -e "s|${SPLASH_VIEWER}|${dying_viewer}|g" \
    -e "s|${SPLASH_IMAGE}|${splash_image}|g" \
    "$splash_sh" >"$script"
chmod +x "$script"
rm -rf "$splash_home"; mkdir -p "$splash_home"
SPLASH_RC=0
SPLASH_OUT=$(HOME="$splash_home" VIEWER_MARK="$sfr_work/fifth.mark" \
  GAMESCOPE_WAYLAND_DISPLAY=gamescope-0 \
  PATH="$sfr_bin:$PATH" timeout 60 "$script" 2>&1) || SPLASH_RC=$?
[[ $SPLASH_RC -eq 0 ]] ||
  fail_test "a viewer that dies instantly is not a failed unit" "rc=${SPLASH_RC}"$'\n'"$SPLASH_OUT"
grep -q 'FAILED: the viewer exited' <<<"$SPLASH_OUT" ||
  fail_test "🔴 a viewer that never drew a frame is reported as a FAILURE" \
    "a viewer that ran for two minutes handed over to Steam; one that was gone in a second drew nothing. P33 called both 'the viewer exited'. got:"$'\n'"$SPLASH_OUT"

# 🔴 AND THE VIEWER'S OWN REASON IS IN THE FILE. This is the single most useful
# sentence when nothing appears, and P33 sent it to a journal that was not kept.
splash_log="$splash_home/$FIRST_BOOT_LOG_REL"
[[ -s $splash_log ]] ||
  fail_test "the splash leaves a record that outlives the boot" "expected ${splash_log}"
grep -q 'Failed to connect to Wayland display' "$splash_log" ||
  fail_test "🔴 and the VIEWER's own stderr is in it" \
    "without it the file says the viewer died and not why. got:"$'\n'"$(cat "$splash_log")"
grep -q 'FAILED' "$splash_log" ||
  fail_test "and the failure is greppable in the file, not only on stderr" "$(cat "$splash_log")"
pass "🔴 A VIEWER THAT NEVER DREW IS A NAMED FAILURE, and its own stderr is in ~/${FIRST_BOOT_LOG_REL}"

# (g) 🔴 A MARKER FROM A DIFFERENT IMPLEMENTATION DOES NOT SILENCE THIS ONE.
#     P33's marker held only a date and was written before the attempt, so the
#     boot that drew nothing disabled the feature on that Deck for ever -- any
#     fix would have been untestable without a human deleting a dotfile by hand,
#     on a device with no keyboard.
marker="$splash_home/$SPLASH_MARKER_REL"
[[ -s $marker ]] || fail_test "the marker is written" "expected ${marker}"
read -r marker_id _ <"$marker"
[[ $marker_id == "$SPLASH_ATTEMPT_ID" ]] ||
  fail_test "the marker records WHICH implementation ran" \
    "first field is '${marker_id}', expected '${SPLASH_ATTEMPT_ID}'. Without it, 'has this splash run' cannot be distinguished from 'has A splash run'."
# A P33-shaped marker: a bare date, exactly what is on the operator's Deck now.
date -Iseconds >"$marker"
SPLASH_RC=0
SPLASH_OUT=$(HOME="$splash_home" VIEWER_MARK="$sfr_work/sixth.mark" \
  GAMESCOPE_WAYLAND_DISPLAY=gamescope-0 \
  PATH="$sfr_bin:$PATH" timeout 60 "$script" 2>&1) || SPLASH_RC=$?
grep -q 'gets its own single attempt' <<<"$SPLASH_OUT" ||
  fail_test "🔴 a P33 marker (a bare date) does not suppress this splash" \
    "this is the state the operator's Deck is in RIGHT NOW: a marker written by a splash that drew nothing. If it suppresses the fix, the fix cannot be tested. got:"$'\n'"$SPLASH_OUT"
[[ -s $sfr_work/sixth.mark ]] ||
  fail_test "and it really attempted to draw" "no viewer was started"
# ...and having attempted, it must not attempt again.
SPLASH_RC=0
SPLASH_OUT=$(HOME="$splash_home" VIEWER_MARK="$sfr_work/seventh.mark" \
  GAMESCOPE_WAYLAND_DISPLAY=gamescope-0 \
  PATH="$sfr_bin:$PATH" timeout 30 "$script" 2>&1) || SPLASH_RC=$?
[[ $SPLASH_RC -eq 0 && -z $SPLASH_OUT ]] ||
  fail_test "one attempt per implementation, not one per boot" "rc=${SPLASH_RC}"$'\n'"$SPLASH_OUT"
[[ ! -s $sfr_work/seventh.mark ]] ||
  fail_test "and the second boot starts no viewer" "the ~39 s boots would be covered again"
pass "🔴 ONE ATTEMPT PER IMPLEMENTATION: a P33-era marker yields exactly one retry, and then none"

# An unreadable marker is treated as "already shown", because the bias of this
# whole design is to miss a message rather than to cover a Gaming Mode.
: >"$marker"
SPLASH_RC=0
SPLASH_OUT=$(HOME="$splash_home" VIEWER_MARK="$sfr_work/eighth.mark" \
  GAMESCOPE_WAYLAND_DISPLAY=gamescope-0 \
  PATH="$sfr_bin:$PATH" timeout 30 "$script" 2>&1) || SPLASH_RC=$?
[[ $SPLASH_RC -eq 0 && ! -s $sfr_work/eighth.mark ]] ||
  fail_test "an empty marker does not become a splash at every boot" \
    "rc=${SPLASH_RC}"$'\n'"$SPLASH_OUT"
pass "an unreadable marker reads as 'already shown' -- the safe direction"

# --- the wording is the requirement ----------------------------------------
#
# The operator asked for "something to tell users like don't turn me off. steam
# is unpacking." Not paraphrased -- that IS the specification.
#
# 🔴 RENDERED TO A PATH WITH NO EXTENSION, ON PURPOSE. That is what the stage
# does (it renders into a mktemp file and then `install`s it), and ImageMagick
# picks its output codec from the extension: an earlier version of this called
# it with a name ending in .png, passed, and would have shipped a stage that
# failed with "no encode delegate" on every real install -- installing no splash
# at all, quietly, because the stage's gate treats a failed render as "no
# ImageMagick here". A test that is easier on the code than production is worse
# than no test.
splash_png="$sfr_work/message-no-extension"
if bash -c 'source "$1"; render_steam_splash_image "$2"' _ "$REPO_ROOT/src/deck-session.sh" "$splash_png" 2>/dev/null && [[ -s $splash_png ]]; then
  size=$(bash -c 'source "$1"; printf "%s" "$SPLASH_IMAGE_SIZE"' _ "$REPO_ROOT/src/deck-session.sh")
  if command -v identify >/dev/null 2>&1 || command -v magick >/dev/null 2>&1; then
    got=$( { command -v magick >/dev/null 2>&1 && magick identify -format '%wx%h' "$splash_png"; } || identify -format '%wx%h' "$splash_png" )
    [[ $got == "$size" ]] ||
      fail_test "the message is drawn at gamescope's logical size" \
        "got ${got}, expected ${size}. The panel is 800x1280 PORTRAIT and gamescope applies its own transform, so a portrait image here would be the one thing on the Deck rotated the wrong way."
    pass "the message renders at ${got} -- gamescope's landscape logical output, not the panel's portrait scanout"
  fi
else
  note "ImageMagick is not on this machine, so the message image was not rendered here (the stage warns and installs no splash in that case, which is today's behaviour)"
fi

# The words themselves, checked on the source so they survive a machine with no
# ImageMagick.
img_body=$(bash -c 'source "$1"; declare -f render_steam_splash_image' _ "$REPO_ROOT/src/deck-session.sh")
for phrase in "Don't turn me off." "Steam is unpacking."; do
  [[ $img_body == *"$phrase"* ]] ||
    fail_test "the splash says what the operator asked for" \
      "missing: '${phrase}'. The wording is the requirement, not a placeholder."
done
pass "the message says \"Don't turn me off.\" and \"Steam is unpacking.\" -- the operator's own words"

rm -rf "$sfr_work"

# ===========================================================================
# 11. stage-input-mapper's own checks -- RUN, not read (PROGRESS.md 5.28 shape)
# ===========================================================================
#
# 🔴 WHY THIS SECTION EXISTS. On 2026-08-16 an ISO shipped in which
# stage-input-mapper failed on every install, and the desktop came up with
# STEAM, QAM, STEAM+X and STEAM+Y all dead. The stage's own words, from
# /var/log/omarchy-deck-install.json on the Deck:
#
#   line 3783: target_python: unbound variable
#   ERROR: the installed OSK renderer drew 10 rows for the letters layer,
#          expected <could not derive>. Output: 10
#
# Two defects in one added line: an interpreter variable that exists nowhere in
# deck-session.sh, and `.layer()` called on what is a property. The render had
# returned the CORRECT answer. Every suite in test/unit was green, because every
# check on that stage was STATIC -- test-osk-install-layout.sh greps the stage
# body for code SHAPES, and a shape can be present and wrong.
#
# So this section EXECUTES what the stage executes, against the real modules,
# in the installed directory shape. A python snippet that raises, or a shell
# variable that does not exist, fails here in a second instead of on hardware
# after a reinstall.

ims_work="$work/input-mapper-stage"
mkdir -p "$ims_work/lib"
cp "$REPO_ROOT/src/deck_osk_layout.py" "$REPO_ROOT/src/deck_osk_tty.py" \
   "$REPO_ROOT/src/deck_osk_wayland.py" "$ims_work/lib/"

ims_body=$(sed -n '/^stage_input_mapper()/,/^}/p' "$REPO_ROOT/src/deck-session.sh")
[[ -n $ims_body ]] ||
  fail_test "stage_input_mapper() is findable in deck-session.sh" \
    "the function name changed; everything below is now vacuous"

# --- 11a. every variable the stage expands actually exists -----------------
#
# This is the check that would have caught `$target_python` with no knowledge of
# what the stage is for. shellcheck's SC2154 found it on the first run, which
# means the coordinator sequence's "shellcheck across changed shell" step was
# the one that was skipped. Asserting it here puts it in the suite that runs
# every time rather than in a step a human can forget.
if command -v shellcheck >/dev/null 2>&1; then
  sc_out=$(shellcheck -f gcc "$REPO_ROOT/src/deck-session.sh" 2>&1 || true)
  if grep -q 'SC2154' <<<"$sc_out"; then
    fail_test "deck-session.sh expands no variable that is never assigned (SC2154)" \
      "$(grep 'SC2154' <<<"$sc_out")
An unassigned variable inside \$(...) is not a syntax error and not a test
failure -- under 'set -u' it empties the substitution, and the caller reads that
as the CHECK failing. That is exactly how stage-input-mapper came to fail on a
correct render and leave a Deck with no input mapper."
  fi
  pass "deck-session.sh references no unassigned variable (shellcheck SC2154 clean)"
else
  note "shellcheck is not on this machine, so SC2154 was not asserted here -- it is the check that caught the 2026-08-16 defect, so CI must keep running it"
fi

# --- 11b. the stage's OSK verification actually runs ------------------------
#
# Extracted from the stage body and executed verbatim against the real modules.
# Nothing is retyped: a snippet edited in deck-session.sh is the snippet run
# here, so this cannot drift into testing a copy that works.
ims_snippet=$(awk '
  /^  osk_import=\$\(LC_ALL=C python3 -c "$/ { grab = 1; next }
  grab && /^" 2>&1\) \|\|$/                   { exit }
  grab                                        { print }
' <<<"$ims_body")
[[ -n $ims_snippet ]] ||
  fail_test "the OSK verification snippet is extractable from stage_input_mapper" \
    "the assignment's shape changed; this case would silently test nothing"

# The stage interpolates OSK_LIB_DIR into the snippet at run time; the extracted
# text still carries the literal '${OSK_LIB_DIR}', and here it is pointed at the
# temp copy -- the same directory shape the stage installs.
# shellcheck disable=SC2016  # the LITERAL '${OSK_LIB_DIR}' is the search text;
# expanding it here would look for this shell's value instead of the marker.
ims_needle='${OSK_LIB_DIR}'
[[ $ims_snippet == *"$ims_needle"* ]] ||
  fail_test "the snippet imports from OSK_LIB_DIR rather than from wherever python happens to look" \
    "$ims_snippet"
ims_ready=${ims_snippet//"$ims_needle"/$ims_work/lib}
ims_out=$(LC_ALL=C python3 -c "$ims_ready" 2>&1) || {
  fail_test "the OSK verification the stage runs at install time SUCCEEDS on the real modules" \
    "python said: ${ims_out}
This is the install-time check itself, not a copy of it. It failing here means
it would fail on the Deck -- and a failing check in this stage is what shipped a
desktop with no STEAM button, no QAM menu and no keyboard."
}
[[ $ims_out =~ ^[0-9]+\ rows\ x\ [0-9]+\ columns$ ]] ||
  fail_test "the stage's OSK check reports a row and column count" "got: ${ims_out}"
pass "the stage's own OSK verification runs against the real modules and reports '${ims_out}'"

# It has to be able to FAIL, or the case above proves nothing. A ragged grid is
# the shape that wraps the VT and pushes the keyboard off the bottom, and it is
# what the renderer's own "every row is the same width by construction" is
# about. The fault is injected into a COPY of the installed directory, by
# appending to the module rather than editing the snippet -- so the snippet
# under test stays the one the stage runs.
cp -r "$ims_work/lib" "$ims_work/lib-ragged"
cat >>"$ims_work/lib-ragged/deck_osk_tty.py" <<'PY'

_test_real_render = render


def render(*a, **k):  # noqa: F811  -- deliberate fault injection
    rows = _test_real_render(*a, **k)
    rows[0] = rows[0][:-1]
    return rows
PY
ims_neg=$(LC_ALL=C python3 -c "${ims_snippet//"$ims_needle"/$ims_work/lib-ragged}" 2>&1) &&
  ims_neg_rc=0 || ims_neg_rc=$?
[[ ${ims_neg_rc} -ne 0 ]] ||
  fail_test "the stage's OSK check REJECTS a ragged grid" \
    "it accepted one and printed: ${ims_neg}. A check that cannot fail is not a check."
grep -q 'differing or zero width' <<<"$ims_neg" ||
  fail_test "the ragged-grid rejection says what is wrong" "got: ${ims_neg}"
pass "the stage's OSK check rejects a ragged grid and names the fault"

# --- 11c. the unit is installed BEFORE anything that can fail after it ------
#
# The ordering IS the fix. With the check above the unit install, a keyboard
# problem deletes the whole input path; below it, the stage still fails loudly
# and the Deck still has working buttons. Asserted on line order in the stage
# body, because that is the only place the ordering exists.
# shellcheck disable=SC2016  # grep PATTERNS matching the stage's own literal
# '${MAPPER_UNIT}' and '$(...)' text; these must not expand here.
ims_unit_line=$(grep -n 'could not install \${MAPPER_UNIT}' <<<"$ims_body" | head -n1 | cut -d: -f1)
# shellcheck disable=SC2016
ims_check_line=$(grep -n 'osk_import=\$(LC_ALL=C python3' <<<"$ims_body" | head -n1 | cut -d: -f1)
[[ -n $ims_unit_line && -n $ims_check_line ]] ||
  fail_test "both the unit install and the OSK check are findable in the stage" \
    "unit line: '${ims_unit_line}', check line: '${ims_check_line}'"
[[ $ims_unit_line -lt $ims_check_line ]] ||
  fail_test "the mapper unit is installed BEFORE the OSK renderer is verified" \
    "unit install at body line ${ims_unit_line}, OSK check at ${ims_check_line}.
With the check first, an OSK fault exits the stage before the unit exists and
takes STEAM, QAM, STEAM+X and STEAM+Y with it -- measured on hardware
2026-08-16. A keyboard check may refuse to certify the keyboard; it may not cost
the machine its input path."
pass "the mapper unit is installed and enabled before the OSK renderer is verified"

# The enable read-back and the every-boot verifier must agree about WHERE the
# symlink is. Two independently-typed copies of that path is how an
# enabled-looking unit that never starts gets shipped.
[[ $MAPPER_GLOBAL_WANTS == "$(dirname "$MAPPER_UNIT")/${MAPPER_WANTED_BY}.wants/$(basename "$MAPPER_UNIT")" ]] ||
  fail_test "MAPPER_GLOBAL_WANTS is the path 'systemctl --global enable' writes" \
    "got: ${MAPPER_GLOBAL_WANTS}"
grep -q 'MAPPER_GLOBAL_WANTS' <<<"$ims_body" ||
  fail_test "the stage's enable read-back uses MAPPER_GLOBAL_WANTS rather than recomputing it" "$ims_body"
pass "the enable read-back and the verifier share one derivation of ${MAPPER_GLOBAL_WANTS}"

# ===========================================================================
# 12. first-boot-verify's third check -- is the mapper actually there?
# ===========================================================================
#
# The install record held the answer to the 2026-08-16 failure the whole time,
# and nothing on the machine read it. This check reads it, on the target, every
# boot -- and its verdict now also lands in ~/.local/state/deck-session/
# first-boot.log, which opens in a text editor on a device with no terminal.
#
# Run rather than read: the script is rendered, its absolute paths redirected
# into a temp tree, and each of the three states exercised.

fbv_work="$work/first-boot-verify"
mkdir -p "$fbv_work/root" "$fbv_work/home"

# A fake logger, so this suite never touches the real journal.
mkdir -p "$fbv_work/bin"
printf '#!/bin/sh\nexit 0\n' >"$fbv_work/bin/logger"
chmod +x "$fbv_work/bin/logger"

render_first_boot_verify testuser >"$fbv_work/verify.raw"

# Redirect the three mapper paths into the temp root, and make the user log
# writable without root: `runuser` needs privileges this suite must not have, so
# the WRAPPER is asserted structurally below and the APPEND is exercised here.
grep -q "runuser -u testuser -- bash -c" "$fbv_work/verify.raw" ||
  fail_test "the verifier appends to the user's log AS the user, not as root" \
    "a root-owned ${FIRST_BOOT_LOG_REL} would make every later write by the Steam first-run scripts fail, and they discard the error"
grep -qF "$FIRST_BOOT_LOG_REL" "$fbv_work/verify.raw" ||
  fail_test "the verifier writes to ~/${FIRST_BOOT_LOG_REL}" \
    "the journal alone is unreadable on a Deck with no terminal and no SSH (PROGRESS.md 5.36)"
pass "every verdict is written to ~/${FIRST_BOOT_LOG_REL} as the desktop user, not only to the journal"

sed -e "s#user_home=\$(getent passwd testuser 2>/dev/null | cut -d: -f6)#user_home=${fbv_work}/home#" \
    -e "s#runuser -u testuser -- bash -c#bash -c#" \
    -e "s#${MAPPER_BIN}#${fbv_work}/root${MAPPER_BIN}#g" \
    -e "s#${MAPPER_UNIT}#${fbv_work}/root${MAPPER_UNIT}#g" \
    -e "s#${MAPPER_GLOBAL_WANTS}#${fbv_work}/root${MAPPER_GLOBAL_WANTS}#g" \
    -e "s#${OSK_LIB_DIR}#${fbv_work}/root${OSK_LIB_DIR}#g" \
    "$fbv_work/verify.raw" >"$fbv_work/verify"
chmod +x "$fbv_work/verify"
bash -n "$fbv_work/verify" ||
  fail_test "the redirected verifier is still valid bash"

fbv_run() { PATH="$fbv_work/bin:$PATH" bash "$fbv_work/verify" 2>&1; }

# State 0: the stage was never run here at all. A note, not a failure -- the
# same contract the brightness and power-button checks keep, and the reason is
# the same: this script is also installed by stages that can run alone, and a
# check that fails on a machine the stage never touched is a check failing for
# the wrong reason.
fbv_out=$(fbv_run) && fbv_rc=0 || fbv_rc=$?
[[ $fbv_rc -eq 0 ]] ||
  fail_test "a machine where stage-input-mapper never ran is a 'note', not a failure" "$fbv_out"
grep -q 'no part of stage-input-mapper is installed here' <<<"$fbv_out" ||
  fail_test "the note says which stage has nothing to verify" "$fbv_out"
pass "nothing from stage-input-mapper installed -> a note, and the unit still passes"

# State 1: the stage started and did not finish -- its OSK modules are on disk
# and the binary is not. This is the gate opening: one artefact present is
# enough to make the others' absence a defect rather than an opt-out.
mkdir -p "$fbv_work/root$OSK_LIB_DIR"
fbv_out=$(fbv_run) && fbv_rc=0 || fbv_rc=$?
[[ $fbv_rc -ne 0 ]] ||
  fail_test "a half-run stage-input-mapper FAILS the verification" "$fbv_out"
grep -q 'no controller support at all' <<<"$fbv_out" ||
  fail_test "the verdict names what the user will actually experience" "$fbv_out"
pass "OSK modules present, mapper binary missing -> fails and says the desktop has no controller support"

# State 2: the exact shape the broken ISO left behind -- binary installed, unit
# never written, because the stage exited between the two.
mkdir -p "$fbv_work/root$(dirname "$MAPPER_BIN")"
printf '#!/bin/sh\nexit 0\n' >"$fbv_work/root$MAPPER_BIN"
chmod +x "$fbv_work/root$MAPPER_BIN"
fbv_out=$(fbv_run) && fbv_rc=0 || fbv_rc=$?
[[ $fbv_rc -ne 0 ]] ||
  fail_test "the half-installed shape the 2026-08-16 ISO shipped FAILS the verification" "$fbv_out"
grep -q 'nothing ever starts it' <<<"$fbv_out" ||
  fail_test "the half-install verdict says nothing starts the mapper" "$fbv_out"
grep -q 'omarchy-deck-install.json' <<<"$fbv_out" ||
  fail_test "the verdict points at the install record, which held the answer" "$fbv_out"
pass "binary present, unit missing -> fails, names the four dead buttons, points at the install record"

# State 3: installed but NOT enabled -- the silent one. The unit exists, every
# 'is it installed' check passes, and it never starts.
mkdir -p "$fbv_work/root$(dirname "$MAPPER_UNIT")"
printf '[Unit]\n' >"$fbv_work/root$MAPPER_UNIT"
fbv_out=$(fbv_run) && fbv_rc=0 || fbv_rc=$?
[[ $fbv_rc -ne 0 ]] ||
  fail_test "an installed-but-not-enabled mapper FAILS the verification" "$fbv_out"
grep -q 'installed and NOT enabled' <<<"$fbv_out" ||
  fail_test "the not-enabled verdict says so" "$fbv_out"
pass "unit present but not enabled -> fails, rather than passing on the file's existence"

# State 4: correct.
mkdir -p "$fbv_work/root$(dirname "$MAPPER_GLOBAL_WANTS")"
ln -sf "$fbv_work/root$MAPPER_UNIT" "$fbv_work/root$MAPPER_GLOBAL_WANTS"
fbv_out=$(fbv_run) && fbv_rc=0 || fbv_rc=$?
[[ $fbv_rc -eq 0 ]] ||
  fail_test "a correctly installed mapper PASSES the verification" "$fbv_out"
grep -q 'ok: input mapper' <<<"$fbv_out" ||
  fail_test "the passing verdict names the mapper" "$fbv_out"
pass "binary, unit and enable symlink all present -> passes"

# And every one of those verdicts reached the file a person can open.
[[ -s "$fbv_work/home/$FIRST_BOOT_LOG_REL" ]] ||
  fail_test "the verdicts reached ~/${FIRST_BOOT_LOG_REL}" \
    "the file is empty or missing; the journal would be the only copy"
grep -q 'ok: input mapper' "$fbv_work/home/$FIRST_BOOT_LOG_REL" ||
  fail_test "the log carries the mapper verdict" "$(cat "$fbv_work/home/$FIRST_BOOT_LOG_REL")"
grep -q 'FAIL: ' "$fbv_work/home/$FIRST_BOOT_LOG_REL" ||
  fail_test "the log carries the FAILING verdicts too, not just the passing one" \
    "$(cat "$fbv_work/home/$FIRST_BOOT_LOG_REL")"
pass "all four runs' verdicts are in ~/${FIRST_BOOT_LOG_REL}, failures included"

# ===========================================================================
# 13. first-boot-verify's power-button check -- TAGS is not CURRENT_TAGS
# ===========================================================================
#
# 🔴 THIS SECTION EXISTS BECAUSE THE CHECK WAS UNFALSIFIABLE AND NOTHING SAW IT.
#
# udev keeps two tag lists. TAGS is CUMULATIVE -- every tag the device has ever
# carried, and `TAG-=` never takes anything out of it. CURRENT_TAGS is what the
# latest uevent left in place, and it is what systemd-logind's tag filter
# matches on. The verifier read TAGS, so 70-power-switch.rules adding the tag
# was enough to make it conclude "the rule did NOT untag" on a machine where the
# rule had worked perfectly -- and its response to that verdict is to DELETE the
# logind drop-in.
#
# Observed on the operator's Deck 2026-08-16, on an install from our own ISO:
#
#   first-boot-verify[804]: FAIL: the power-button udev rule did NOT untag:
#     acpi-PNP0C0C:00 acpi-LNXPWRBN:00 ... has been REMOVED
#
# while `udevadm info -q property` on the same machine showed the two ACPI nodes
# with TAGS=:power-switch: and NO CURRENT_TAGS line at all, the surviving i8042
# node with both, and logind logging exactly ONE 'Power key pressed short' per
# press. The rule had worked. Every boot deleted the drop-in anyway, so the
# power button was one reboot away from doing nothing at all.
#
# Run, not read: the same render-and-redirect harness as §12, plus a udevadm
# stub answering from a fixture directory.

fbv_pb="$work/first-boot-verify-power"
mkdir -p "$fbv_pb/bin" "$fbv_pb/home" "$fbv_pb/dev/input" "$fbv_pb/udev-db" \
         "$fbv_pb/root$(dirname "$POWER_LOGIND_DROPIN")"

printf '#!/bin/sh\nexit 0\n' >"$fbv_pb/bin/logger"
chmod +x "$fbv_pb/bin/logger"

# Read-only `info --query=property --name <node>` and nothing else. Every other
# udevadm verb MUTATES the running system's device state, and on this developer
# machine it would mutate the developer's.
cat >"$fbv_pb/bin/udevadm" <<'STUB_UDEVADM'
#!/usr/bin/env bash
set -uo pipefail
[[ ${1-} == info ]] || {
  printf 'udevadm stub: refusing verb "%s" -- only read-only `info` is allowed here\n' "${1-}" >&2
  exit 97
}
name="" want=0
for a in "$@"; do
  if [[ $want -eq 1 ]]; then name=$a; want=0; continue; fi
  [[ $a == --name ]] && want=1
done
[[ -n $name ]] || { printf 'udevadm stub: no --name given\n' >&2; exit 1; }
f="${FAKE_UDEV_DB:?the suite must set a udev property fixture directory}/${name##*/}"
[[ -f $f ]] || exit 1
cat "$f"
STUB_UDEVADM
chmod +x "$fbv_pb/bin/udevadm"

# pb_node <node> <id-path> <sticky yes|no> <current yes|no>
#
# The two lists are independent on purpose: "sticky yes, current no" is the
# state a WORKING `TAG-=` leaves behind, and it is the one the old check called
# a failure.
pb_node() {
  local n=$1 id=$2 sticky=$3 current=$4
  : >"$fbv_pb/dev/input/$n"
  {
    printf 'DEVNAME=/dev/input/%s\n' "$n"
    printf 'ID_PATH=%s\n' "$id"
    printf 'ID_INPUT_KEY=1\n'
    [[ $sticky != yes ]]  || printf 'TAGS=:%s:seat:\n' "$POWER_UDEV_TAG"
    [[ $current != yes ]] || printf 'CURRENT_TAGS=:%s:seat:\n' "$POWER_UDEV_TAG"
  } >"$fbv_pb/udev-db/$n"
}

sed -e "s#user_home=\$(getent passwd testuser 2>/dev/null | cut -d: -f6)#user_home=${fbv_pb}/home#" \
    -e "s#runuser -u testuser -- bash -c#bash -c#" \
    -e "s#${MAPPER_BIN}#${fbv_pb}/root${MAPPER_BIN}#g" \
    -e "s#${MAPPER_UNIT}#${fbv_pb}/root${MAPPER_UNIT}#g" \
    -e "s#${MAPPER_GLOBAL_WANTS}#${fbv_pb}/root${MAPPER_GLOBAL_WANTS}#g" \
    -e "s#${OSK_LIB_DIR}#${fbv_pb}/root${OSK_LIB_DIR}#g" \
    -e "s#${PRIV_WRITE_HELPER}#${fbv_pb}/root${PRIV_WRITE_HELPER}#g" \
    -e "s#${POWER_LOGIND_DROPIN}#${fbv_pb}/root${POWER_LOGIND_DROPIN}#g" \
    -e 's#/dev/input/event\*#'"${fbv_pb}"'/dev/input/event*#' \
    "$fbv_work/verify.raw" >"$fbv_pb/verify"
chmod +x "$fbv_pb/verify"
bash -n "$fbv_pb/verify" ||
  fail_test "the redirected power-button verifier is still valid bash"

pb_dropin="$fbv_pb/root$POWER_LOGIND_DROPIN"
pb_arm() { printf '[Login]\nHandlePowerKey=%s\n' "$POWER_KEY_ACTION" >"$pb_dropin"; }
pb_run() {
  FAKE_UDEV_DB="$fbv_pb/udev-db" PATH="$fbv_pb/bin:$PATH" bash "$fbv_pb/verify" 2>&1
}

# State A: no drop-in. The stage never ran here, so there is nothing to check
# and nothing to fail -- the same contract every other check in this script
# keeps.
rm -f "$pb_dropin"
pb_out=$(pb_run) && pb_rc=0 || pb_rc=$?
grep -q 'no power-button rule to verify' <<<"$pb_out" ||
  fail_test "a machine where stage-power-button never ran is a 'note', not a failure" "$pb_out"
pass "no logind drop-in -> a note, and the power-button check draws no conclusion"

# 🔴 State B: THE REGRESSION. The rule worked -- the ACPI nodes keep the sticky
# TAGS they can never lose and carry no CURRENT_TAGS -- and the keeper is
# currently tagged. This MUST pass, and the drop-in MUST survive.
pb_arm
pb_node event0 acpi-PNP0C0C:00        yes no
pb_node event1 acpi-PNP0C0D:00        yes yes    # the Lid Switch, untouched
pb_node event2 acpi-LNXPWRBN:00       yes no
pb_node event4 platform-i8042-serio-0 yes yes    # the real key -- KEPT
pb_out=$(pb_run) && pb_rc=0 || pb_rc=$?
[[ $pb_rc -eq 0 ]] ||
  fail_test "a Deck whose udev rule WORKED passes the power-button check" \
    "the ACPI nodes carry the cumulative TAGS every tagged device keeps forever and no CURRENT_TAGS."$'\n'"Reading TAGS here makes the check unfalsifiable -- and its answer to a failure is to delete the"$'\n'"drop-in, so it disarmed the power button on every boot of the operator's Deck. Output:"$'\n'"$pb_out"
[[ -f $pb_dropin ]] ||
  fail_test "the drop-in survives a machine where the rule worked" \
    "${pb_dropin} was deleted; the next boot has HandlePowerKey=ignore and the power button does nothing"
grep -q 'ok: power button' <<<"$pb_out" ||
  fail_test "the passing verdict names the power button" "$pb_out"
pass "🔴 sticky TAGS with no CURRENT_TAGS -- the state a WORKING 'TAG-=' leaves -- passes, and the drop-in is not deleted"

# State C: the rule genuinely did not apply. CURRENT_TAGS still lists the tag on
# an ACPI node, so logind really is watching two sources and the next press
# really would suspend twice. Fail, and disarm.
pb_arm
pb_node event2 acpi-LNXPWRBN:00 yes yes
pb_out=$(pb_run) && pb_rc=0 || pb_rc=$?
[[ $pb_rc -ne 0 ]] ||
  fail_test "an ACPI node still in CURRENT_TAGS FAILS the power-button check" "$pb_out"
grep -q 'did NOT untag' <<<"$pb_out" ||
  fail_test "the failure says the rule did not untag" "$pb_out"
grep -q 'acpi-LNXPWRBN:00' <<<"$pb_out" ||
  fail_test "the failure names which node is still tagged" "$pb_out"
[[ ! -f $pb_dropin ]] ||
  fail_test "the drop-in is REMOVED when the duplicate is genuinely live" \
    "leaving it armed is the re-suspend loop this whole design exists to avoid"
pass "an ACPI node still in CURRENT_TAGS fails, names the node, and disarms the handler"

grep -q "${HYPR_BINDINGS_LUA_REL}" <<<"$pb_out" ||
  fail_test "the disarm verdict says the Desktop Mode menu bind is still removed" \
    "with the handler gone AND Omarchy's ${POWER_MENU_BIND_KEY} bind unbound, the power button does"$'\n'"nothing at all in Desktop Mode -- the operator has to be told where to undo the second half. Output:"$'\n'"$pb_out"
pass "and points at ~/${HYPR_BINDINGS_LUA_REL}, because disarming alone now leaves the button inert in Desktop Mode"

# State D: the keeper lost its current tag. logind is watching nothing, so the
# button is dead -- a defect, but deleting the drop-in cannot improve it and
# would only hide which change caused it.
pb_arm
pb_node event2 acpi-LNXPWRBN:00       yes no
pb_node event4 platform-i8042-serio-0 yes no
pb_out=$(pb_run) && pb_rc=0 || pb_rc=$?
[[ $pb_rc -ne 0 ]] ||
  fail_test "a machine with no surviving tagged KEY_POWER source FAILS the check" "$pb_out"
grep -q "no device carries ID_PATH=${POWER_KEEP_ID_PATH}" <<<"$pb_out" ||
  fail_test "the failure names the node that should have survived" "$pb_out"
[[ -f $pb_dropin ]] ||
  fail_test "the drop-in is LEFT in place when the keeper is missing" \
    "removing it cannot make a dead button work and would hide the cause"
pass "a missing keeper fails loudly and leaves the drop-in alone, so the cause stays visible"

# ===========================================================================
# render_menu_hibernate_block -- the override that removes the Hibernate row
# ===========================================================================
#
# ⚠️ THE LABEL IS DELIBERATELY NOT ASSERTED. Rewording it is not a regression.
# The mechanism is the absence of an "action", and that is what is checked.

hib_block=$(render_menu_hibernate_block)

grep -qxF -- "$MENU_HIBERNATE_BEGIN" <<<"$hib_block" ||
  fail_test "the Hibernate block opens with its own begin marker" "expected: ${MENU_HIBERNATE_BEGIN}"
grep -qxF -- "$MENU_HIBERNATE_END" <<<"$hib_block" ||
  fail_test "the Hibernate block closes with its own end marker" "expected: ${MENU_HIBERNATE_END}"
# 🔴 DISTINCT FROM THE GAMING MODE PAIR. Both blocks live in the one file and
# each splice preserves everything outside its own markers; a shared marker
# would make each block delete the other.
[[ $MENU_HIBERNATE_BEGIN != "$MENU_ROW_BEGIN" && $MENU_HIBERNATE_END != "$MENU_ROW_END" ]] ||
  fail_test "the Hibernate block's markers differ from the Gaming Mode row's" \
    "sharing a marker pair would make each splice eat the other's block"
pass "the Hibernate block has its own marker pair, distinct from the Gaming Mode row's"

printf '%s\n' "$hib_block" >"$work/hibernate-block.jsonc"
# The block goes in as a PATH, not on stdin: `python3 -` is already reading the
# script from stdin, so a redirect would replace the program rather than feed it.
python3 - "$MENU_HIBERNATE_ROW_ID" "$work/hibernate-block.jsonc" <<'PY' || fail_test "the rendered Hibernate row is inert" "see the message above"
import json, pathlib, re, sys
row_id = sys.argv[1]
raw = pathlib.Path(sys.argv[2]).read_text()
raw = re.sub(r"^\s*//[^\n]*(\n|$)", "", raw, flags=re.M)
raw = re.sub(r",(\s*$)", r"\1", raw)
try:
    menu = json.loads("{" + raw + "}")
except ValueError as exc:
    sys.exit(f"the rendered Hibernate block is not valid JSON: {exc}")
if list(menu) != [row_id]:
    sys.exit(f"the block declares {list(menu)}, not exactly ['{row_id}']")
row = menu[row_id]
# 🔴 The three keys whose ABSENCE is the mechanism. normalizeItem derives
# kind = action ? "action" : (target ? "link" : "menu"), so an "action" or a
# "target" here would leave the row visible and pressable; a "when" would make
# it a guarded row, which Menu.qml's own comment says SHOWS when unanswered.
for key in ("action", "target", "when"):
    if row.get(key):
        sys.exit(f"the row carries {key!r}={row[key]!r}; that keeps it live in the merged model")
if not row.get("label"):
    sys.exit("the row carries no label, so the merged model would fall back to showing its id")
PY
pass "the rendered Hibernate row is exactly one id, with a label and NO action, target or when -- a childless submenu isVisible() hides in the model"

# The block must say why it is there and how to get the row back: an option
# that vanished with no explanation anywhere is the failure this project keeps
# correcting.
grep -q 'hibernation exit' <<<"$hib_block" ||
  fail_test "the block records the measurement that justifies the removal" \
    "the journal line proving hibernation aborts rather than powering off is the evidence; without it this is a superstition"
grep -qi 'TO GET Hibernate BACK' <<<"$hib_block" ||
  fail_test "the block says how to get the row back" "a user who wants it must not have to read this repository"
pass "the block carries both the measurement that justifies it and the instructions for undoing it"

# ===========================================================================
# render_onboard_audio_name_conf -- the WirePlumber drop-in that stops Steam's
# volume OSD printing a device label over the Deck's own speakers
# ===========================================================================
#
# ⚠️ WHAT THIS SUITE DELIBERATELY DOES NOT ASSERT: the literal string
# "ACP/ACP3X/ACP6x Audio Coprocessor". That value belongs to Steam -- it is a
# constant compiled into Steam's UI bundle, and Valve may change it in any
# client update. Pinning it here would turn somebody else's release into our
# red suite. What IS asserted is the MECHANISM: that whatever
# ${AUDIO_ONBOARD_NAME} holds reaches the file, that the rule is keyed on a
# property that exists when the device is created, and that the match cannot
# reach Bluetooth.

audio_conf=$(render_onboard_audio_name_conf)

grep -qF -- "$INSTALL_MARKER_TEXT" <<<"$audio_conf" ||
  fail_test "the drop-in carries the ownership marker" \
    "without it assert_ours_or_absent cannot tell our file from a package's, and a re-run would refuse its own output"
pass "the drop-in carries the ownership marker, so re-running the stage recognises its own file"

# The constant must actually reach the rendered text. A drop-in that renames
# the card to anything else is a rule that runs and leaves the defect in place.
[[ $(grep -cF -- "$AUDIO_ONBOARD_NAME" <<<"$audio_conf") -ge 2 ]] ||
  fail_test "the onboard-audio name reaches BOTH properties the rule sets" \
    "device.description and device.product.name must both carry it; Steam compares one of them and this file does not get to guess which"
pass "the name Steam tests for reaches both device.description and device.product.name"

# 🔴 THE NEGATIVE CONTROL FOR THE BUG THAT COST A RESTART TO FIND. A device
# match keyed on alsa.card_name parses, loads, matches nothing and reports
# success -- PLAN.md 8.1's failure mode, in a file whose whole job is one match.
grep -qF "${AUDIO_CARD_MATCH_KEY} = \"${AUDIO_CARD_NICK}\"" <<<"$audio_conf" ||
  fail_test "the rule matches the card on ${AUDIO_CARD_MATCH_KEY}" \
    "measured on the operator's Deck: alsa.card_name is not set on the device object when a monitor.alsa.rules device match is evaluated, so a rule keyed on it is inert"
! grep -qE '^\s*alsa\.card_name\s*=' <<<"$audio_conf" ||
  fail_test "the rule does NOT key its device match on alsa.card_name" \
    "that property is absent at device-creation time; the rule would match no device and do nothing, silently"
pass "the device match is keyed on ${AUDIO_CARD_MATCH_KEY}, not on the property that is not set yet"

# 🔴 THE BLUETOOTH NON-REGRESSION, asserted structurally rather than by hoping.
# Over Bluetooth the OSD label is WANTED -- it names the headphones, and the
# operator asked for that to be left exactly as it is. The only thing standing
# between this file and that behaviour is the scope of its match.
grep -qF 'device.name = "~alsa_card.*"' <<<"$audio_conf" ||
  fail_test "the rule is scoped to ALSA cards" \
    "an unscoped monitor rule could rename a Bluetooth device and take its name out of the OSD -- the one behaviour that must not change"
# DIRECTIVES only. The file's own header explains what it deliberately leaves
# alone, and that explanation names bluez; checking the whole file would refuse
# our own documentation. Same distinction install_sleep_lock_override draws.
! grep -v '^#' <<<"$audio_conf" | grep -qi 'bluez' ||
  fail_test "the drop-in names no Bluetooth device or rule in a directive" \
    "Bluetooth output must keep naming itself in Steam's volume OSD"
pass "the rule is scoped to alsa_card and names no bluez rule, so Bluetooth keeps naming itself in the OSD"

# A user with no terminal cannot undo something the file does not explain.
grep -q 'systemctl --user restart wireplumber' <<<"$audio_conf" ||
  fail_test "the drop-in says how to undo itself" \
    "deleting the file alone changes nothing until WirePlumber restarts, and nothing else on the machine says so"
pass "the drop-in carries its own undo, including the restart that makes the undo take effect"

echo "all deck-session.sh tests passed"
