#!/usr/bin/env bash
# Integration tests for deck-session.sh's INSTALL STAGES -- the code that
# actually writes the system -- with no root, no VM, no Deck and no network.
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS
# ---------------------------------------------------------------------------
#
# docs/findings/T9-coupling-inventory.md §0 row 1: "deck-session.sh has NO
# integration test at all". Its sibling suite (test/unit/test-deck-session.sh)
# sources the file and exercises only the render_* string generators and two
# pure predicates; its own header states the cost plainly -- "this exercises
# the stub's body and the marker predicate, NOT the install steps wrapped
# around them". Those install steps self-verify at runtime, but only when a
# human runs them on the Deck, which is the definition of a check nobody runs.
#
# This suite runs the stage bodies themselves.
#
# ---------------------------------------------------------------------------
# THE SEAM -- why this is possible without touching src/
# ---------------------------------------------------------------------------
#
# Every privileged write in deck-session.sh goes through `$SUDO`:
#
#   $SUDO install -m 0755 -o root -g root "$tmp" "$SELECT_BIN"
#
# and deck-session.sh:382 sets SUDO="" at file scope, with only
# stage_preconditions ever setting it to `sudo`. So a test that points SUDO at
# a shim can intercept essentially every filesystem effect the stages have.
# The shim (fake-sudo, below) rewrites absolute destination paths to land under
# a temp fake root and appends its full argv to a call log, so a case can assert
# on BOTH halves of what a stage did: the files it produced, and the privileged
# commands it ran to produce them.
#
# Nothing in src/ was changed to make this work. Where a stage cannot be
# reached as it ships, it is left uncovered and said so -- see the next block.
#
# ---------------------------------------------------------------------------
# WHAT IS COVERED, AND WHAT IS NOT (and exactly why not)
# ---------------------------------------------------------------------------
#
# COVERED  stage-preconditions      partial: the required-tool gate only (§1)
#          stage-session-select     full (§2)
#          stage-steam-hook         full (§3)
#          stage-sddm-resilience    full (§4)
#          stage-return-icon        full (§5)
#          stage-desktop-settings   full (§6)
#
# NOT COVERED, and the line that blocks each. None of these can be reached
# without editing src/, which this suite deliberately does not do:
#
#   stage-update-stub        :993  `"$UPDATE_STUB" check` executes the readonly
#                            ABSOLUTE path /usr/bin/steamos-polkit-helpers/
#                            steamos-update. $SUDO is not in that call, so no
#                            shim intercepts it. On the dev machine this file
#                            already exists (gamescope-session-steam-git ships
#                            it) and it `exec pkexec`s -- a unit suite must not
#                            run that. See the FINDINGS block below.
#   stage-timezone-helper    :1139 `command -v /usr/bin/timedatectl` and :1203
#                            `"$TIMEZONE_HELPER" ...` -- same absolute-path
#                            problem, plus a host-dependent precondition.
#   stage-priv-write-helper  :1373 `"$PRIV_WRITE_HELPER" ...`, and :1370 reads
#                            /sys/class/backlight/amdgpu_bl0/brightness, which
#                            exists on any AMD laptop and would change the
#                            stage's path depending on who ran the suite.
#   stage-greeter-rotation   :1522 `[[ -f /usr/share/sddm/hyprland.lua ]]` and
#                            :1613 `cat /etc/sddm.conf.d/*.conf` read the real
#                            filesystem directly. The stage's outcome is a
#                            property of the machine running the suite.
#   stage-input-mapper       :1775 `"$MAPPER_BIN" --type` -- absolute path
#                            again. Its static shape is already covered by
#                            test/unit/test-osk-install-layout.sh.
#
# The install halves of the three polkit-helper stages are structurally
# identical to stage-session-select's, which IS covered here end to end
# (install -m 0755, install -d, visudo -c gating, install -m 0440), so the
# marginal loss is the sudoers TEXT of two grants, named in the report.
#
# ---------------------------------------------------------------------------
# SAFETY -- a test that could touch the real system is worse than no test
# ---------------------------------------------------------------------------
#
# Four gates, all of which must hold before any stage body runs:
#
#   1. SUDO must be empty after sourcing deck-session.sh (copied from
#      test/unit/test-deck-session.sh -- if that initialisation ever changes,
#      refuse to run rather than find out by prompting for a password in CI).
#   2. `sudo`, `systemctl`, `visudo`, `dconf` and `env` must all resolve to
#      this suite's stubs, not to the real binaries.
#   3. fake-sudo refuses to run at all unless FAKE_ROOT and SANDBOX are set,
#      and refuses any argument that would resolve outside them.
#   4. Every path fake-sudo actually executed against is re-checked at the end
#      of the run (§7) and must be inside $work.
#
# TMPDIR is also pointed inside $work, so the `mktemp` calls inside the stages
# stage their content there rather than in the system temp directory.
#
# ---------------------------------------------------------------------------
# FINDINGS THIS SUITE PINS, AND ONE IT DELIBERATELY DOES NOT
# ---------------------------------------------------------------------------
#
# stage_return_icon is the ONE install stage that never calls
# assert_ours_or_absent, and the .desktop file it writes carries no install
# marker (deck-session.sh:2063-2073). A re-run therefore clobbers whatever is
# at that path, which every other stage refuses to do. This suite asserts what
# the stage does today and does NOT assert "there is no marker" -- pinning the
# absence would enshrine it. It is reported instead.

set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

# Sourcing, not running. Exactly once and at top level, for the reasons the
# sibling suite documents: every constant is readonly, so a second source in
# the same shell aborts, and deck-session.sh's own `set -euo pipefail` leaks
# into this shell.
# shellcheck source=../../src/deck-session.sh
source "$REPO_ROOT/src/deck-session.sh"

# NOTE the names: deck-session.sh exports its own `fail`, `log` and `warn`, and
# the stage bodies under test call all three. Shadowing any of them would
# rewrite the behaviour being tested, so this suite uses suffixed names -- the
# same deviation test/unit/test-deck-session.sh makes, for the same reason.
assertions=0
pass()      { assertions=$((assertions + 1)); printf 'ok - %s\n' "$1"; }
fail_test() { printf 'not ok - %s\n' "$1"; [[ -n ${2:-} ]] && printf '%s\n' "$2" >&2; exit 1; }
note()      { printf 'note - %s\n' "$1"; }

# --- GATE 0 ----------------------------------------------------------------
# Root changes the behaviour under test rather than merely the permissions:
# verify_nopasswd returns immediately for EUID 0 (deck-session.sh:501) and
# stage_preconditions takes its root branch. Several assertions below would
# then fail for a reason that has nothing to do with the code. Refuse loudly
# instead of producing a confusing red.
[[ $EUID -ne 0 ]] ||
  fail_test "this suite must run as an unprivileged user" \
    "running as root changes which branches the stages take (verify_nopasswd returns early, stage_preconditions sets SUDO=''), so a root run tests something other than what ships"
pass "running unprivileged, which is the branch the stages take on a real install (sudo, not root)"

# --- GATE 1 ----------------------------------------------------------------
# deck-session.sh leaves SUDO empty until stage_preconditions sets it, and this
# suite never calls that stage past its tool gate. If that ever changes, every
# `$SUDO install` below would run REAL sudo against REAL absolute paths.
[[ -z ${SUDO:-} ]] ||
  fail_test "SUDO is '${SUDO}' after sourcing deck-session.sh; this suite must never invoke sudo"
pass "SUDO is empty after sourcing -- no stage body can reach real sudo by accident"

# ===========================================================================
# HARNESS
# ===========================================================================

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

root="$work/root"           # the fake filesystem root every absolute path lands in
stub_bin="$work/bin"        # stubs, prepended to PATH
calls="$work/calls.log"     # every stub's argv, as the stage passed it
resolved="$work/resolved.log"   # fake-sudo's argv AFTER path rewriting
breach="$work/breach.log"   # anything fake-sudo refused; must stay empty

mkdir -p "$stub_bin" "$work/tmp"
: >"$calls"; : >"$resolved"; : >"$breach"

export TMPDIR="$work/tmp"   # so the stages' own `mktemp` stays inside $work
export SANDBOX="$work"
export FAKE_ROOT="$root"
export CALLS_LOG="$calls"
export RESOLVED_LOG="$resolved"
export BREACH_LOG="$breach"
export FAKE_DCONF_COMPILED="$work/dconf-compiled"

# The autologin/desktop user, fixed so the generated files are deterministic.
# stage_session_select reads SUDO_USER first, exactly as it would under
# `sudo ./deck-session.sh`.
export SUDO_USER=decktester
export FAKE_HOME="$work/home/decktester"

# Directories a stock Arch/Omarchy install already has. They are fixture, not
# something a stage creates -- which is the point: a stage that installs into a
# directory NOT on this list must create it itself (`install -d`), and if it
# stops doing so the install fails here rather than on the Deck.
readonly -a STOCK_DIRS=(
  /usr/bin /bin /usr/local/bin /usr/local/lib /usr/share/applications
  /usr/share/wayland-sessions /etc /etc/sudoers.d /etc/sddm.conf.d
  /etc/systemd/system /etc/systemd/user /var/lib
)

reset_root() {
  # ${work:?} rather than $work: an empty variable here would make this
  # `rm -rf /home`, which is precisely the accident the whole suite is built to
  # be incapable of.
  rm -rf "${root:?}" "${work:?}/home"
  local d
  for d in "${STOCK_DIRS[@]}"; do mkdir -p "$root$d"; done
  # A real /bin has a shell in it. The `env -i PATH=/usr/bin:/bin sh -c ...`
  # reachability probe in stage_steam_hook needs to find one.
  ln -sf "$(command -v sh)" "$root/bin/sh"
  mkdir -p "$FAKE_HOME"
  rm -f "$FAKE_DCONF_COMPILED"
  : >"$calls"; : >"$resolved"
}

# --- the shim that stands in for $SUDO, and for the literal `sudo` ----------
#
# Three jobs: log the argv a stage passed (that is where the "which privileged
# command ran with which arguments" coverage comes from), rewrite absolute
# destinations under the fake root, and refuse anything that would escape.
#
# It also drops `-o root -g root` from `install`, because a non-root test
# cannot chown to root. The dropped flags are still visible in the call log, so
# a stage that stopped asking for root ownership is still detectable.
cat >"$stub_bin/fake-sudo" <<'FAKE_SUDO'
#!/usr/bin/env bash
# Test double for sudo. See test/unit/test-deck-session-stages.sh.
set -uo pipefail

refuse() {
  printf 'fake-sudo: %s\n' "$1" >>"${BREACH_LOG:-/dev/stderr}"
  printf 'fake-sudo: %s\n' "$1" >&2
  exit 99
}

[[ -n ${FAKE_ROOT:-} && -d ${FAKE_ROOT:-} ]] ||
  refuse "FAKE_ROOT is not a directory ('${FAKE_ROOT:-<unset>}') -- refusing to run anything"
[[ -n ${SANDBOX:-} ]] || refuse "SANDBOX is unset -- refusing to run anything"

printf 'sudo %s\n' "$*" >>"$CALLS_LOG"

# sudo's own options, consumed before the command begins.
listing=0
while [[ $# -gt 0 ]]; do
  case $1 in
    -u) shift 2 ;;                    # run-as user: irrelevant, nothing is switched
    -l) listing=1; shift ;;
    -n|-k|-K|-v|-S|-H|-E|-i) shift ;;
    --) shift; break ;;
    -*) shift ;;
    *)  break ;;
  esac
done

# `sudo -l <cmd>` asks whether a grant exists. It must not RUN anything --
# verify_nopasswd relies on exactly that.
if [[ $listing -eq 1 ]]; then
  if [[ -n ${FAKE_SUDO_LIST_DENY:-} && "$*" == *"${FAKE_SUDO_LIST_DENY}"* ]]; then
    exit 1
  fi
  exit "${FAKE_SUDO_LIST_RC:-0}"
fi

# `sudo -K` / `sudo -v` carry no command.
[[ $# -gt 0 ]] || exit 0

cmd=$1
argv=()
drop_next=0
for a in "$@"; do
  if [[ $drop_next -eq 1 ]]; then drop_next=0; continue; fi
  if [[ $cmd == install && ( $a == -o || $a == -g ) ]]; then drop_next=1; continue; fi
  if [[ $a == /* ]]; then
    if [[ $a != "$SANDBOX"/* ]]; then
      a="${FAKE_ROOT}${a}"
    fi
    [[ $a == "$FAKE_ROOT"/* || $a == "$SANDBOX"/* ]] ||
      refuse "argument '${a}' resolves outside the sandbox"
  fi
  argv+=("$a")
done

printf '%s\n' "${argv[*]}" >>"$RESOLVED_LOG"
exec "${argv[@]}"
FAKE_SUDO
chmod +x "$stub_bin/fake-sudo"
cp "$stub_bin/fake-sudo" "$stub_bin/sudo"   # verify_nopasswd calls `sudo` by name
FAKE_SUDO_BIN="$stub_bin/fake-sudo"

# --- systemctl -------------------------------------------------------------
#
# `systemctl show <unit> -p <Prop> --value` answers from the environment, so a
# case can make systemd report the values it would report if a drop-in had NOT
# applied -- which is the whole thing stage_sddm_resilience is checking.
cat >"$stub_bin/systemctl" <<'STUB_SYSTEMCTL'
#!/usr/bin/env bash
set -uo pipefail
printf 'systemctl %s\n' "$*" >>"$CALLS_LOG"
if [[ -n ${FAKE_SYSTEMCTL_FAIL:-} && "$*" == *"${FAKE_SYSTEMCTL_FAIL}"* ]]; then
  printf 'systemctl: injected failure: %s\n' "$*" >&2
  exit 1
fi
if [[ ${1-} == show ]]; then
  prop="" want=0
  for a in "$@"; do
    if [[ $want -eq 1 ]]; then prop=$a; want=0; continue; fi
    [[ $a == -p || $a == --property ]] && want=1
  done
  var="FAKE_SYSTEMCTL_SHOW_${prop}"
  printf '%s\n' "${!var-}"
fi
exit 0
STUB_SYSTEMCTL

# --- visudo ----------------------------------------------------------------
#
# A real `visudo -c -f FILE` parses FILE, so a missing candidate is an error
# here too: the stages hand it a mktemp path that must still exist.
cat >"$stub_bin/visudo" <<'STUB_VISUDO'
#!/usr/bin/env bash
set -uo pipefail
printf 'visudo %s\n' "$*" >>"$CALLS_LOG"
file="" want=0
for a in "$@"; do
  if [[ $want -eq 1 ]]; then file=$a; want=0; continue; fi
  [[ $a == -f ]] && want=1
done
if [[ -n $file && ! -f $file ]]; then
  printf 'visudo: %s: No such file or directory\n' "$file" >&2
  exit 1
fi
exit "${FAKE_VISUDO_RC:-0}"
STUB_VISUDO

# --- dconf -----------------------------------------------------------------
#
# Deliberately NOT a constant oracle. `dconf read -d` resolves the key out of
# the keyfile the stage actually installed, and only once `dconf update` has
# run and a profile naming the site database exists -- because that is what
# real dconf does, and it is what makes the stage's own verification able to
# fail. A stub that just echoed "true" would let every mutation of
# render_dconf_site_file through.
cat >"$stub_bin/dconf" <<'STUB_DCONF'
#!/usr/bin/env bash
set -uo pipefail
printf 'dconf %s\n' "$*" >>"$CALLS_LOG"

case ${1-} in
  update)
    [[ ${FAKE_DCONF_UPDATE_RC:-0} -eq 0 ]] || exit "${FAKE_DCONF_UPDATE_RC}"
    : >"$FAKE_DCONF_COMPILED"
    exit 0
    ;;
  read) shift ;;
  *) exit 0 ;;
esac

default_only=0
if [[ ${1-} == -d ]]; then default_only=1; shift; fi
key=${1-}

# The effective value: a user-level value shadows the site default.
if [[ $default_only -eq 0 && -n ${FAKE_DCONF_USER_VALUE:-} &&
      $key == "${FAKE_DCONF_USER_KEY:-}" ]]; then
  printf '%s\n' "$FAKE_DCONF_USER_VALUE"
  exit 0
fi

# Uncompiled keyfiles are invisible, and so is a site database no profile names.
[[ -f $FAKE_DCONF_COMPILED ]] || exit 0
if [[ ${FAKE_DCONF_HOST_PROFILE_OK:-0} -ne 1 ]]; then
  grep -qx 'system-db:local' "${FAKE_ROOT}/etc/dconf/profile/user" 2>/dev/null || exit 0
fi

# A compiled database that never picked the keyfile up still ANSWERS -- with
# whatever was in it before. That is the shape of the failure the stage's own
# `dconf read -d` verification exists to catch, and it is not the same as
# reading nothing: an "is it non-empty" check would pass here.
if [[ -n ${FAKE_DCONF_STALE_VALUE:-} ]]; then
  printf '%s\n' "$FAKE_DCONF_STALE_VALUE"
  exit 0
fi

group=${key%/*}; group=${group#/}
name=${key##*/}
for f in "${FAKE_ROOT}"/etc/dconf/db/local.d/*; do
  [[ -f $f ]] || continue
  awk -v g="[${group}]" -v k="$name" '
    $0 == g       { ing = 1; next }
    /^\[/         { ing = 0 }
    ing && index($0, k "=") == 1 {
      sub(/^[^=]*=/, ""); print; found = 1; exit
    }
    END { exit !found }
  ' "$f" && exit 0
done
exit 0
STUB_DCONF

# --- getent ----------------------------------------------------------------
cat >"$stub_bin/getent" <<'STUB_GETENT'
#!/usr/bin/env bash
set -uo pipefail
printf 'getent %s\n' "$*" >>"$CALLS_LOG"
[[ ${FAKE_GETENT_RC:-0} -eq 0 ]] || exit "${FAKE_GETENT_RC}"
if [[ ${1-} == passwd && -n ${2-} ]]; then
  printf '%s:x:1000:1000:Deck test user:%s:/bin/bash\n' "$2" "${FAKE_HOME}"
  exit 0
fi
exit 2
STUB_GETENT

# --- env -------------------------------------------------------------------
#
# stage_steam_hook proves the shim is REACHABLE, not merely present:
#
#   env -i PATH=/usr/bin:/bin sh -c 'command -v steamos-session-select'
#
# with a scrubbed environment, so an operator's /usr/local/bin on PATH cannot
# make it pass. This stub keeps that property and only relocates the search
# under the fake root -- the same rewrite fake-sudo does, applied to a PATH
# rather than to an argument. FAKE_ENV_BREAK_PATH points it at a directory the
# shim was NOT installed in, which is the /usr/local/bin defect PROGRESS.md
# 5.10 spent a session finding, reproduced without a Deck.
#
# The shebang uses the absolute /usr/bin/env, so this cannot recurse into
# itself via PATH.
cat >"$stub_bin/env" <<'STUB_ENV'
#!/usr/bin/env bash
set -uo pipefail
printf 'env %s\n' "$*" >>"$CALLS_LOG"

args=()
for a in "$@"; do
  case $a in
    PATH=*)
      newpath=""
      IFS=':' read -r -a dirs <<<"${a#PATH=}"
      for d in "${dirs[@]}"; do
        [[ $d == /* ]] && d="${FAKE_ROOT}${d}"
        [[ ${FAKE_ENV_BREAK_PATH:-0} -eq 1 ]] && d="${FAKE_ROOT}/nonexistent${d}"
        newpath="${newpath:+${newpath}:}${d}"
      done
      args+=("PATH=${newpath}")
      ;;
    *) args+=("$a") ;;
  esac
done
exec /usr/bin/env "${args[@]}"
STUB_ENV

# --- commands the stages only probe for, or only log through ---------------
for stub in systemd-run findmnt timedatectl loginctl logger; do
  cat >"$stub_bin/$stub" <<STUB_GENERIC
#!/usr/bin/env bash
set -uo pipefail
printf '${stub} %s\n' "\$*" >>"\$CALLS_LOG"
exit 0
STUB_GENERIC
done

chmod +x "$stub_bin"/*
export PATH="$stub_bin:$PATH"

# Defaults: the values systemd reports when the drop-in DID apply. Cases that
# want the "it silently did not apply" behaviour override these.
export FAKE_SYSTEMCTL_SHOW_StartLimitIntervalUSec=0
export FAKE_SYSTEMCTL_SHOW_TimeoutStopUSec="${SDDM_STOP_TIMEOUT}s"
export FAKE_SYSTEMCTL_SHOW_RestartUSec=3s

# --- GATE 2 ----------------------------------------------------------------
for tool in sudo systemctl visudo dconf env getent; do
  [[ $(command -v "$tool") == "$stub_bin/$tool" ]] ||
    fail_test "'${tool}' resolves to this suite's stub" \
      "got $(command -v "$tool"); the stub PATH is not in front, so this suite would drive the real system"
done
pass "sudo, systemctl, visudo, dconf, env and getent all resolve to stubs, not to the real binaries"

# --- GATE 3 ----------------------------------------------------------------
rc=0
# BREACH_LOG is redirected in both probes: these two refusals are expected, and
# §7 asserts the real breach log stayed empty for the run.
( unset FAKE_ROOT; BREACH_LOG=/dev/null "$FAKE_SUDO_BIN" true ) >/dev/null 2>&1 || rc=$?
[[ $rc -eq 99 ]] ||
  fail_test "fake-sudo refuses to run with no FAKE_ROOT" \
    "got ${rc}; the shim must never fall through to running a command against real paths"
rc=0
( BREACH_LOG=/dev/null FAKE_ROOT=/ "$FAKE_SUDO_BIN" install -d /etc/evil ) >/dev/null 2>&1 || rc=$?
[[ $rc -ne 0 ]] ||
  fail_test "fake-sudo refuses a path that resolves outside the sandbox" \
    "a FAKE_ROOT of '/' would put every rewritten path back on the real filesystem"
pass "fake-sudo refuses to run without a fake root, and refuses paths that resolve outside it"

# ===========================================================================
# THE STAGE RUNNER
# ===========================================================================
#
# Each stage runs in a SUBSHELL: deck-session.sh's `fail` exits rather than
# returning, so calling a stage directly would kill this suite mid-run with
# only deck-session's own error text and no 'not ok' line. The subshell is also
# what keeps SUDO empty in this shell (gate 1's invariant) while the stage sees
# the shim.
#
# DESKTOP_SESSION is normally resolved by discovery in stage_preconditions,
# which this suite does not run past its tool gate; it is not readonly for
# exactly that reason ("resolved at runtime", deck-session.sh:138).
stage_rc=0
run_stage_body() {
  local fn=$1
  stage_rc=0
  : >"$calls"
  (
    # shellcheck disable=SC2030  # SUDO must be local to this subshell: that is
    # the whole safety design. It stays empty in the suite's own shell, which
    # §1 then asserts.
    SUDO="$FAKE_SUDO_BIN"
    DESKTOP_SESSION=omarchy
    "$fn"
  ) >"$work/stage.out" 2>"$work/stage.err" || stage_rc=$?
}

out()      { cat "$work/stage.out"; }
err()      { cat "$work/stage.err"; }
mode_of()  { stat -c '%a' "$1"; }

# Assertion helpers. Each prints its own ok- line so the count in the summary
# is the number of properties actually checked.
ok_rc() {         # ok_rc <expected> <desc>
  [[ $stage_rc -eq $1 ]] ||
    fail_test "$2" "stage exited ${stage_rc}, expected ${1}"$'\n'"stdout: $(out)"$'\n'"stderr: $(err)"
  pass "$2"
}
ok_failed() {     # ok_failed <desc>
  [[ $stage_rc -ne 0 ]] ||
    fail_test "$1" "the stage exited 0; it must fail loudly instead"$'\n'"stdout: $(out)"
  pass "$1"
}
ok_file() {       # ok_file <path-under-fake-root> <desc>
  [[ -f "$root$1" ]] || fail_test "$2" "missing: ${root}${1}"$'\n'"stderr: $(err)"
  pass "$2"
}
ok_absent() {
  [[ ! -e "$root$1" ]] || fail_test "$2" "unexpectedly present: ${root}${1}"
  pass "$2"
}
ok_mode() {       # ok_mode <path> <mode> <desc>
  local got; got=$(mode_of "$root$1") ||
    fail_test "$3" "cannot stat ${root}${1}"
  [[ $got == "$2" ]] || fail_test "$3" "mode is ${got}, expected ${2}"
  pass "$3"
}
ok_in_file() {    # ok_in_file <path> <fixed string> <desc>
  grep -qF -- "$2" "$root$1" ||
    fail_test "$3" "not found in ${1}: ${2}"$'\n'"file:"$'\n'"$(cat "$root$1")"
  pass "$3"
}
# For anything that is a CONFIG LINE rather than prose. Every file these stages
# generate documents itself heavily, and several of them re-read their own
# output to verify it -- so `User=decktester` appears in the heredoc that writes
# the drop-in, in the grep that checks it landed, and in that grep's error
# message. A substring match therefore passes with the value that actually ships
# changed. (Mutation-tested: both `User=` and `Relogin=` survived a substring
# match before this existed.)
ok_line() {       # ok_line <path> <exact line> <desc>
  grep -qxF -- "$2" "$root$1" ||
    fail_test "$3" "no line in ${1} is exactly: ${2}"$'\n'"file:"$'\n'"$(cat "$root$1")"
  pass "$3"
}
ok_called() {     # ok_called <fixed string> <desc>
  grep -qF -- "$1" "$calls" ||
    fail_test "$2" "no logged call matched: ${1}"$'\n'"calls:"$'\n'"$(cat "$calls")"
  pass "$2"
}
ok_in_out() {
  grep -qF -- "$1" "$work/stage.out" ||
    fail_test "$2" "not on stdout: ${1}"$'\n'"stdout: $(out)"
  pass "$2"
}
ok_in_err() {
  grep -qF -- "$1" "$work/stage.err" ||
    fail_test "$2" "not on stderr: ${1}"$'\n'"stderr: $(err)"
  pass "$2"
}
# Ordering matters in several places (validate before installing, install
# before reloading), and a call log that merely CONTAINS both proves nothing.
call_line() { grep -nF -- "$1" "$calls" | head -1 | cut -d: -f1; }
ok_before() {     # ok_before <first> <second> <desc>
  local a b
  a=$(call_line "$1"); b=$(call_line "$2")
  [[ -n $a && -n $b ]] ||
    fail_test "$3" "one of the calls never happened (${1} -> ${a:-none}, ${2} -> ${b:-none})"$'\n'"$(cat "$calls")"
  [[ $a -lt $b ]] ||
    fail_test "$3" "'${1}' was call ${a}, '${2}' was call ${b} -- wrong order"$'\n'"$(cat "$calls")"
  pass "$3"
}

# ===========================================================================
# 1. stage-preconditions -- the required-tool gate
# ===========================================================================
#
# PARTIAL, deliberately. Everything past the tool loop is a property of the
# machine running the suite -- /sys/class/dmi/id/product_name, the presence of
# a gamescope-wayland.desktop, /usr/local/bin/switch-to-gaming -- and none of
# it is reachable through $SUDO, so it cannot be redirected into the fake root.
# Asserting on it would be asserting on the operator's laptop.
#
# The tool gate IS host-independent, because PATH is ours. It is also the one
# part of the stage that runs BEFORE `SUDO="sudo"` is assigned, so these cases
# cannot leave a live sudo behind.

bare_bin="$work/bare"
mkdir -p "$bare_bin"
for t in systemctl install findmnt; do
  cp "$stub_bin/systemctl" "$bare_bin/$t" 2>/dev/null || :
done
chmod +x "$bare_bin"/*

for missing in systemctl install findmnt; do
  rc=0
  # Removed and restored from THIS shell: the subshell's PATH is the bare
  # directory, which deliberately has no `rm` in it either. That bare PATH is
  # also a second wall -- it carries no sudo, so even if the tool gate were
  # deleted the stage could not escalate from here.
  rm -f "$bare_bin/$missing"
  ( PATH="$bare_bin"; stage_preconditions ) \
    >"$work/stage.out" 2>"$work/stage.err" || rc=$?
  cp "$stub_bin/systemctl" "$bare_bin/$missing"; chmod +x "$bare_bin/$missing"
  [[ $rc -eq 1 ]] ||
    fail_test "stage-preconditions fails when '${missing}' is missing" "exited ${rc}"
  grep -qF -- "required tool '${missing}' not found" "$work/stage.err" ||
    fail_test "the failure names the missing tool '${missing}'" "stderr: $(err)"
  pass "stage-preconditions fails loudly, naming '${missing}', when it is not on PATH"
done

# shellcheck disable=SC2031  # "SUDO was modified in a subshell" is exactly
# what this asserts did NOT leak out of one. Reading the outer value is the point.
[[ -z ${SUDO:-} ]] ||
  fail_test "stage-preconditions left SUDO set in this shell" "got '${SUDO:-}'"
pass "the tool gate runs before SUDO is assigned, so a failed precondition leaves no live sudo"

# ===========================================================================
# 2. stage-session-select -- two generated programs and a privilege grant
# ===========================================================================
#
# The stage that matters most: it writes the binary Steam's Power menu
# ultimately reaches, the transient-unit body that restarts sddm, and a
# sudoers drop-in. Nothing off-Deck has ever executed it before this suite.

reset_root
run_stage_body stage_session_select
ok_rc 0 "stage-session-select completes against a fake root"

# --- the switcher itself ---
ok_file /usr/local/bin/deck-session-select "it installs ${SELECT_BIN}"
ok_mode /usr/local/bin/deck-session-select 755 "${SELECT_BIN} is mode 0755 -- Steam's shim execs it"
ok_called "install -m 0755 -o root -g root" "it asks for root ownership on the switcher (install -o root -g root)"

# The generated file matches no CI glob and is parsed nowhere else, so a
# heredoc typo would first be discovered by a Deck with no way to switch back.
bash -n "$root/usr/local/bin/deck-session-select" 2>"$work/err" ||
  fail_test "the installed switcher is syntactically valid bash" "$(cat "$work/err")"
pass "the installed switcher parses (bash -n) -- it is generated, so nothing else ever checks it"

ok_line /usr/local/bin/deck-session-select "DESKTOP_SESSION=omarchy" \
  "the desktop session resolved by discovery is baked in, not hardcoded at switch time"
ok_line /usr/local/bin/deck-session-select "GAMING_SESSION=gamescope-wayland" \
  "the gaming session name is baked in"
ok_line /usr/local/bin/deck-session-select "SDDM_DROPIN=/etc/sddm.conf.d/zz-deck-session.conf" \
  "it writes the 'zz-' drop-in, which sorts after Omarchy's autologin.conf"
ok_in_file /usr/local/bin/deck-session-select "systemd-run --collect" \
  "the sddm restart is handed to a transient unit, not run inline"
ok_in_file /usr/local/bin/deck-session-select "desktop|plasma|omarchy" \
  "the dispatch still accepts 'plasma' -- the target Steam actually passes"

# --- the [Autologin] block the switcher WRITES ---------------------------
#
# Extracted from the INNER heredoc rather than matched against the whole file,
# and matched by WHOLE LINE. Both precautions are load-bearing here and were
# added because mutation testing walked straight through their absence:
# `Relogin=true` also appears in a comment three lines above the directive, and
# both keys appear again in the switcher's own re-read verification.
awk '/<<INNER$/ { inblock = 1; next } /^INNER$/ { inblock = 0 } inblock' \
  "$root/usr/local/bin/deck-session-select" >"$work/autologin-block"
[[ -s $work/autologin-block ]] ||
  fail_test "the [Autologin] heredoc is findable in the installed switcher" \
    "the INNER heredoc has been renamed or removed; every assertion below it would be vacuous"
pass "the [Autologin] block the switcher writes is findable, so the assertions below are about the drop-in and not about its documentation"

# SDDM applies [Autologin] only when BOTH User= and Session= are present; an
# earlier version wrote Session= alone and every switch landed on the greeter.
# shellcheck disable=SC2016  # NOT expanding is the point: the switcher writes
# `Session=${target}` as a literal shell reference to be resolved at switch time,
# so that is the text this must match.
for autologin_key in "[Autologin]" "User=decktester" 'Session=${target}' "Relogin=true"; do
  grep -qxF -- "$autologin_key" "$work/autologin-block" ||
    fail_test "the [Autologin] block contains '${autologin_key}'" \
      "block was:"$'\n'"$(cat "$work/autologin-block")"
done
pass "the drop-in it writes carries [Autologin], User=decktester, Session=\${target} and Relogin=true -- SDDM ignores the block without all of User/Session, and without Relogin a dead session strands the user at a password greeter"

# --- the restart helper ---
ok_file /usr/local/lib/deck-session/restart-sddm "it installs ${RESTART_HELPER}"
ok_mode /usr/local/lib/deck-session/restart-sddm 755 "${RESTART_HELPER} is mode 0755 -- the transient unit execs it"
ok_called "install -d -m 0755 -o root -g root /usr/local/lib/deck-session" \
  "it creates ${RESTART_HELPER}'s directory rather than assuming it exists"
ok_line /usr/local/lib/deck-session/restart-sddm "session_user=decktester" \
  "the desktop user is threaded into the restart helper's settle gate"
ok_in_file /usr/local/lib/deck-session/restart-sddm "$INSTALL_MARKER" \
  "the restart helper carries the install marker, so a re-run may replace its own output"

# Both binaries are re-checked for executability after installation. This is an
# assertion about the STAGE re-checking, not about the mode (which the two
# ok_mode assertions above cover): `install` reporting success is not the same
# as the file being runnable, and on the Deck those two checks are the only
# thing between a failed install and a Power menu that does nothing.
ok_called "test -x /usr/local/bin/deck-session-select" "the stage re-checks the switcher is executable after installing it"
ok_called "test -x /usr/local/lib/deck-session/restart-sddm" "the stage re-checks the restart helper is executable after installing it"

# --- the privilege grant, and the gate in front of it ---
ok_file /etc/sudoers.d/99-deck-session-select "it installs ${SUDOERS_FILE}"
ok_mode /etc/sudoers.d/99-deck-session-select 440 \
  "${SUDOERS_FILE} is mode 0440 -- sudo ignores a drop-in with any other mode"
ok_line /etc/sudoers.d/99-deck-session-select \
  "decktester ALL=(root) NOPASSWD: /usr/local/bin/deck-session-select" \
  "the grant names one absolute binary for one user, and nothing else"
ok_called "visudo -c -f" "the sudoers candidate is validated with 'visudo -c -f'"
ok_before "visudo -c -f" "install -m 0440" \
  "validation happens BEFORE the drop-in is installed -- a malformed sudoers file breaks sudo for every user"

# The release check's own predicate, applied to what the stage really wrote.
# If this stage ever widened its grant, stage-audit-privileges would fail on
# the Deck; here it fails in a second.
grant_line=$(grep -v '^#' "$root/etc/sudoers.d/99-deck-session-select" | grep -v '^[[:space:]]*$' | head -1)
! sudoers_line_is_blanket "$grant_line" ||
  fail_test "the installed grant is scoped, not blanket" "sudoers_line_is_blanket flagged: ${grant_line}"
sudoers_line_is_nopasswd "$grant_line" ||
  fail_test "the installed grant is passwordless" "Steam cannot answer a password prompt; got: ${grant_line}"
pass "the drop-in this stage really installs reads as scoped-and-passwordless to the release check's own predicate"

# --- verify_nopasswd: the probe must not run on a warm credential cache ----
ok_called "sudo -K" "the grant probe clears the sudo credential cache first"
ok_before "-K" "-l /usr/local/bin/deck-session-select" \
  "the cache is cleared BEFORE the probe -- a warm cache made the old check pass whether or not the rule parsed"
ok_in_err "already has broad passwordless sudo" \
  "when the user already has blanket NOPASSWD, the stage says the grant is UNVERIFIED rather than claiming success"

# The other arm of that honesty check: deny the blanket probe only.
export FAKE_SUDO_LIST_DENY=/usr/bin/true
reset_root
run_stage_body stage_session_select
ok_rc 0 "stage-session-select completes when the user has no blanket sudo"
ok_in_out "verified: decktester can invoke it without a password" \
  "with no blanket grant in the way, the stage reports the narrow grant as verified"
unset FAKE_SUDO_LIST_DENY

# --- failure injection: visudo rejects the candidate ----------------------
#
# The single most important negative case in the file. A sudoers drop-in that
# does not parse breaks sudo for every user on the machine.
export FAKE_VISUDO_RC=1
reset_root
run_stage_body stage_session_select
ok_failed "a sudoers candidate that fails validation stops the stage"
ok_in_err "failed validation" "the refusal says the snippet failed validation"
ok_absent /etc/sudoers.d/99-deck-session-select \
  "NOTHING is written to /etc/sudoers.d when visudo rejects the candidate"
unset FAKE_VISUDO_RC

# --- failure injection: the grant does not actually work -----------------
export FAKE_SUDO_LIST_RC=1
reset_root
run_stage_body stage_session_select
ok_failed "the stage fails when sudo will not confirm the grant it just installed"
ok_in_err "still not invokable passwordless" \
  "the failure says the grant could not be confirmed, and names the file to inspect"
unset FAKE_SUDO_LIST_RC

# --- idempotency: the re-run requirement (CLAUDE.md) ---------------------
reset_root
run_stage_body stage_session_select
ok_rc 0 "first run of stage-session-select"
run_stage_body stage_session_select
ok_rc 0 "a second run succeeds -- assert_ours_or_absent recognises the restart helper as ours"

# And a file at that path which is NOT ours must stop the stage dead.
reset_root
mkdir -p "$root/usr/local/lib/deck-session"
printf '#!/bin/sh\n# somebody else\n' >"$root/usr/local/lib/deck-session/restart-sddm"
run_stage_body stage_session_select
ok_failed "a foreign file at ${RESTART_HELPER} stops the stage"
ok_in_err "was not written by deck-session.sh" "the refusal explains whose file is in the way"

# ===========================================================================
# 3. stage-steam-hook -- the file Steam's Power menu actually resolves
# ===========================================================================

reset_root
run_stage_body stage_steam_hook
ok_rc 0 "stage-steam-hook completes against a fake root"
ok_file /usr/bin/steamos-session-select "it installs the shim in /usr/bin, where Steam can see it"
ok_mode /usr/bin/steamos-session-select 755 "the shim is mode 0755"
ok_in_file /usr/bin/steamos-session-select "exec sudo -n /usr/local/bin/deck-session-select" \
  "the shim elevates with 'sudo -n' to the absolute path of the switcher"
ok_in_file /usr/bin/steamos-session-select "$INSTALL_MARKER" "the installed shim carries the install marker"
# The call log is reset per stage, so within stage-steam-hook this is the shim's
# own install and no other.
ok_called "install -m 0755 -o root -g root" "the shim is installed root-owned -- a user-writable file on Steam's PATH runs as whatever it says"

# Reachability, not existence. This is the check that would have caught the
# session lost to installing into /usr/local/bin, which Steam's runtime PATH
# does not contain.
ok_called "env -i PATH=/usr/bin:/bin sh -c command -v steamos-session-select" \
  "the stage resolves the shim against Steam's own PATH with a scrubbed environment"
ok_in_out "verified: Steam can resolve it" "the stage reports the shim as resolvable, having actually resolved it"

# --- the shim installed where Steam cannot reach it ----------------------
export FAKE_ENV_BREAK_PATH=1
reset_root
run_stage_body stage_steam_hook
ok_failed "a shim Steam's PATH cannot resolve fails the stage even though the file was written"
ok_in_err "does not resolve on Steam's runtime PATH" \
  "the failure is about reachability, and says Switch to Desktop would silently do nothing"
ok_file /usr/bin/steamos-session-select "the file itself was still written -- 'present' and 'reachable' are different questions"
unset FAKE_ENV_BREAK_PATH

# --- a file at /usr/bin/steamos-session-select that is not ours ----------
#
# If SteamOS's own customizations, or a future jupiter-* package, ever land
# this path for real, THEIR version is the authoritative one. Overwriting it
# would be the wrong outcome in a place nobody would think to look.
reset_root
printf '#!/bin/sh\n# steamos-customizations, hypothetically\n' >"$root/usr/bin/steamos-session-select"
run_stage_body stage_steam_hook
ok_failed "a foreign file at ${STEAM_SHIM} stops the stage rather than being overwritten"
ok_in_err "was not written by deck-session.sh" "the refusal explains that something else owns the path"

# --- migration: our own legacy copy is removed --------------------------
reset_root
printf '#!/usr/bin/env bash\n%s\nexit 0\n' "$INSTALL_MARKER" >"$root/usr/local/bin/steamos-session-select"
run_stage_body stage_steam_hook
ok_rc 0 "stage-steam-hook completes with a legacy copy present"
ok_absent /usr/local/bin/steamos-session-select \
  "our own Steam-unreachable /usr/local/bin copy is removed, so exactly one shim exists"
ok_called "rm -f /usr/local/bin/steamos-session-select" "the removal goes through sudo, against the legacy path"

# --- migration: somebody else's file is left alone ----------------------
reset_root
printf '#!/bin/sh\n# DeckShift maybe\n' >"$root/usr/local/bin/steamos-session-select"
run_stage_body stage_steam_hook
ok_rc 0 "a foreign /usr/local/bin copy does not stop the stage"
ok_file /usr/local/bin/steamos-session-select "a foreign legacy file is NOT deleted"
ok_in_err "is left alone" "the stage warns about the foreign file instead of removing it"

# ===========================================================================
# 4. stage-sddm-resilience -- the drop-in, and the check that it APPLIED
# ===========================================================================
#
# PROGRESS.md 5.16: without this the Deck ends up with no graphical session and
# needs `systemctl reset-failed sddm` from a shell, which a controller-only
# user does not have. The stage's verification reads back what systemd
# RESOLVED, not what was written -- a drop-in with a typo'd directive is
# silently ignored -- so the three cases below drive systemd's answers.

reset_root
run_stage_body stage_sddm_resilience
ok_rc 0 "stage-sddm-resilience completes"
ok_called "install -d -m 0755 -o root -g root /etc/systemd/system/sddm.service.d" \
  "it creates the drop-in directory (systemd ships no sddm.service.d)"
ok_file /etc/systemd/system/sddm.service.d/50-deck-switch-resilience.conf "it installs ${SDDM_UNIT_DROPIN}"
ok_mode /etc/systemd/system/sddm.service.d/50-deck-switch-resilience.conf 644 "the drop-in is mode 0644"
ok_line /etc/systemd/system/sddm.service.d/50-deck-switch-resilience.conf "TimeoutStopSec=30" \
  "TimeoutStopSec=30 -- the directive that stops a Gaming Mode teardown being SIGKILLed at 5s"
ok_line /etc/systemd/system/sddm.service.d/50-deck-switch-resilience.conf "StartLimitIntervalSec=0" \
  "StartLimitIntervalSec=0, in [Unit], so a retry loop cannot latch the unit into permanent failure"
ok_line /etc/systemd/system/sddm.service.d/50-deck-switch-resilience.conf "RestartSec=3" \
  "RestartSec=3 on the Restart=always retry path"
ok_in_file /etc/systemd/system/sddm.service.d/50-deck-switch-resilience.conf "$INSTALL_MARKER" \
  "the drop-in carries the install marker"
ok_called "systemctl daemon-reload" "the stage reloads systemd after writing the drop-in"
ok_before "install -m 0644" "daemon-reload" "the reload happens AFTER the write, so it can pick it up"
ok_called "systemctl show sddm -p StartLimitIntervalUSec --value" "it reads back the RESOLVED StartLimitIntervalUSec"
ok_called "systemctl show sddm -p TimeoutStopUSec --value" "it reads back the RESOLVED TimeoutStopUSec"
ok_called "systemctl show sddm -p RestartUSec --value" "it reads back the RESOLVED RestartUSec"

export FAKE_SYSTEMCTL_FAIL=daemon-reload
reset_root
run_stage_body stage_sddm_resilience
ok_failed "a failed daemon-reload stops the stage"
ok_in_err "systemctl daemon-reload failed" "the failure names the reload"
unset FAKE_SYSTEMCTL_FAIL

# systemd reporting upstream's values means the drop-in did not apply, whatever
# is on disk. Both of these must be failures, not warnings.
export FAKE_SYSTEMCTL_SHOW_StartLimitIntervalUSec=30s
reset_root
run_stage_body stage_sddm_resilience
ok_failed "a StartLimitIntervalUSec systemd never applied fails the stage"
ok_in_err "The drop-in was not applied" "the failure says the drop-in did not take, not that the file is missing"
export FAKE_SYSTEMCTL_SHOW_StartLimitIntervalUSec=0

export FAKE_SYSTEMCTL_SHOW_TimeoutStopUSec=5s
reset_root
run_stage_body stage_sddm_resilience
ok_failed "TimeoutStopSec still resolving to upstream's 5s fails the stage -- it is the cause, not a symptom"
ok_in_err "which is what puts the VT race back" "the failure explains what a 5s stop timeout does"
export FAKE_SYSTEMCTL_SHOW_TimeoutStopUSec="${SDDM_STOP_TIMEOUT}s"

# RestartSec is the one that is deliberately only a warning: the rate limit is
# already lifted, so a switch can still recover. Pinning this stops someone
# "tidying" the asymmetry away in either direction.
export FAKE_SYSTEMCTL_SHOW_RestartUSec=100ms
reset_root
run_stage_body stage_sddm_resilience
ok_rc 0 "a RestartSec that did not apply WARNS rather than failing -- the rate limit is what recovers a switch"
ok_in_err "RestartSec resolved to '100ms'" "the warning names the value systemd actually resolved"
export FAKE_SYSTEMCTL_SHOW_RestartUSec=3s

# ===========================================================================
# 5. stage-return-icon -- the shell-agnostic way back to Gaming Mode
# ===========================================================================

reset_root
run_stage_body stage_return_icon
ok_rc 0 "stage-return-icon completes"
ok_file /usr/share/applications/deck-return-to-gaming.desktop "it installs ${RETURN_DESKTOP_FILE}"
ok_mode /usr/share/applications/deck-return-to-gaming.desktop 644 "the .desktop entry is mode 0644"
ok_line /usr/share/applications/deck-return-to-gaming.desktop "Exec=/usr/bin/steamos-session-select gamescope" \
  "Exec= points at the Steam-reachable shim in /usr/bin, not at ${SELECT_BIN} (which needs root)"
ok_line /usr/share/applications/deck-return-to-gaming.desktop "Icon=input-gaming" \
  "Icon=input-gaming -- a freedesktop name that resolves, and not Valve artwork this project may not ship"
ok_line /usr/share/applications/deck-return-to-gaming.desktop "Type=Application" "it is a valid Desktop Entry type"

# ===========================================================================
# 6. stage-desktop-settings -- the three values that decide whether the
#    keyboard works and whether an idle Deck can lock itself out
# ===========================================================================
#
# PROGRESS.md 5.20 / R-38. Every one was found by something failing on a
# screen; until this stage existed they were hand edits a built image would
# simply not have.
#
# ONE HOST DEPENDENCY, handled rather than ignored: deck-session.sh:1906 tests
# `[[ -e /etc/dconf/profile/user ]]` on the REAL filesystem, not through $SUDO,
# so which branch the stage takes is a property of the machine running this
# suite. All three branches are real contracts, so all three are asserted.
host_profile=absent
if [[ -e /etc/dconf/profile/user ]]; then
  if grep -qx 'system-db:local' /etc/dconf/profile/user; then
    host_profile=ok
  else
    host_profile=foreign
  fi
fi

seed_shell_json() {
  mkdir -p "$FAKE_HOME/.config/omarchy"
  cat >"$FAKE_HOME/$OMARCHY_SHELL_JSON_REL" <<'JSON'
{
  "version": 1,
  "bar": { "modules": ["workspaces", "clock"] },
  "idle": { "screensaver": 150, "lock": 300 }
}
JSON
}

case $host_profile in
  foreign)
    # The host has a dconf profile that does not name the site database. The
    # stage refuses to guess at merge order, which is the correct behaviour --
    # assert that, and skip the rest of this section.
    reset_root; seed_shell_json
    run_stage_body stage_desktop_settings
    ok_failed "stage-desktop-settings refuses a dconf profile that does not list system-db:local"
    ok_in_err "merge it by hand" "the refusal says profile order is precedence and it will not guess"
    note "the rest of §6 needs a host without /etc/dconf/profile/user, or one that already lists system-db:local"
    ;;
  *)
    [[ $host_profile != ok ]] || export FAKE_DCONF_HOST_PROFILE_OK=1
    reset_root; seed_shell_json
    run_stage_body stage_desktop_settings
    ok_rc 0 "stage-desktop-settings completes against a fake root"

    if [[ $host_profile == absent ]]; then
      ok_file /etc/dconf/profile/user "it creates ${DCONF_PROFILE}, without which every site default is inert"
      ok_mode /etc/dconf/profile/user 644 "the dconf profile is mode 0644"
      ok_line /etc/dconf/profile/user "system-db:local" "the profile names the site database"
      [[ $(head -1 "$root/etc/dconf/profile/user") == "user-db:user" ]] ||
        fail_test "user-db:user comes first in the profile" \
          "profile order is precedence: a site db ahead of the user db would override the user"
      pass "user-db:user is listed before system-db:local -- profile order is precedence"
      ok_called "install -D -m 0644 -o root -g root" "the profile is installed with -D, since /etc/dconf/profile does not exist"
    else
      ok_in_out "dconf profile already reads the site database" \
        "an existing profile that already names the site database is left alone"
    fi

    ok_file /etc/dconf/db/local.d/50-deck-desktop "it installs ${DCONF_SITE_FILE}"
    ok_mode /etc/dconf/db/local.d/50-deck-desktop 644 "the site defaults file is mode 0644"
    ok_line /etc/dconf/db/local.d/50-deck-desktop "screen-keyboard-enabled=true" \
      "squeekboard's auto-show gate is enabled -- with it unset the OSK never appears on text focus"
    ok_line /etc/dconf/db/local.d/50-deck-desktop "sources=[('xkb','us')]" \
      "an input source is set -- without one squeekboard warns 'No system layout' and draws nothing"
    ok_in_file /etc/dconf/db/local.d/50-deck-desktop "$INSTALL_MARKER" "the site defaults carry the install marker"

    ok_called "dconf update" "the keyfile is compiled -- a dconf keyfile does nothing until it is"
    ok_before "install -D -m 0644" "dconf update" "the compile happens after the keyfile is written"
    ok_in_out "verified: both on-screen-keyboard defaults are set in the SITE database" \
      "the stage verifies the SITE default (dconf read -d), not the effective value a hand-set user value would satisfy"

    # The idle policy. `lock: 0` does NOT disable the lock, so this is a large
    # timeout -- and on a keyboard-less handheld a lock is unrecoverable.
    idle=$(python3 -c "
import json,sys
cfg=json.load(open(sys.argv[1]))
print(cfg['idle']['screensaver'], cfg['idle']['lock'], sorted(cfg))
" "$FAKE_HOME/$OMARCHY_SHELL_JSON_REL")
    [[ $idle == "150 86400 ['bar', 'idle', 'version']" ]] ||
      fail_test "the idle policy is patched into shell.json in place" \
        "got: ${idle}; expected screensaver=150 lock=86400 with 'bar' and 'version' untouched"
    pass "shell.json gets screensaver=150s and lock=86400s"
    pass "the rest of shell.json survives the patch -- a rewrite would silently strip the bar"

    # A user-level value shadows the site default. Warn only when it DISAGREES.
    export FAKE_DCONF_USER_KEY="$OSK_KEY"
    export FAKE_DCONF_USER_VALUE=false
    reset_root; seed_shell_json
    run_stage_body stage_desktop_settings
    ok_rc 0 "a user value shadowing the site default is a warning, not a failure"
    ok_in_err "is shadowing it" "the warning says a user-level value is shadowing the default, and how to reset it"
    unset FAKE_DCONF_USER_KEY FAKE_DCONF_USER_VALUE

    export FAKE_DCONF_UPDATE_RC=1
    reset_root; seed_shell_json
    run_stage_body stage_desktop_settings
    ok_failed "a failed 'dconf update' stops the stage"
    ok_in_err "on disk but not compiled" "the failure distinguishes 'written' from 'compiled', which is the state that does nothing"
    unset FAKE_DCONF_UPDATE_RC

    # `dconf update` exiting 0 having compiled the wrong thing is the failure
    # the read-back exists for: the database answers, with the value that was
    # there before. An "is it non-empty" check would pass; only comparing
    # against the expected value catches it.
    export FAKE_DCONF_STALE_VALUE=false
    reset_root; seed_shell_json
    run_stage_body stage_desktop_settings
    ok_failed "a site database that answers with the OLD value fails the stage"
    ok_in_err "the OSK would never auto-show for a new user" \
      "the read-back compares against the expected value, not merely 'did dconf answer'"
    unset FAKE_DCONF_STALE_VALUE

    # An unparseable shell.json must not be rewritten from scratch.
    reset_root; seed_shell_json
    printf 'not json at all\n' >"$FAKE_HOME/$OMARCHY_SHELL_JSON_REL"
    run_stage_body stage_desktop_settings
    ok_failed "a shell.json that is not JSON stops the stage rather than being replaced"
    ok_in_err "could not patch the idle policy" "the failure names the file it would not overwrite"
    ;;
esac

# ===========================================================================
# 7. The harness's own safety invariant
# ===========================================================================
#
# Everything above is only trustworthy if none of it touched the real system.
# fake-sudo logs the argv it actually executed, after rewriting; every absolute
# path in that log must be inside $work.

[[ ! -s $breach ]] ||
  fail_test "fake-sudo refused nothing during this run" "breaches:"$'\n'"$(cat "$breach")"
pass "fake-sudo never had to refuse a path -- every absolute destination rewrote cleanly"

escaped=$(awk -v w="$work/" '{for (i = 1; i <= NF; i++)
  if (substr($i, 1, 1) == "/" && index($i, w) != 1) print $i}' "$resolved" | sort -u)
[[ -z $escaped ]] ||
  fail_test "every path the stages wrote to is inside the temp work directory" \
    "these resolved outside ${work}:"$'\n'"${escaped}"
pass "every absolute path the stage bodies actually operated on resolved inside ${work}"

printf '\nall deck-session stage tests passed (%d assertions)\n' "$assertions"
