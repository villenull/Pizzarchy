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
# THE TWO SEAMS
# ---------------------------------------------------------------------------
#
# 1. $SUDO, which needed nothing from src/.
#
# Every privileged write in deck-session.sh goes through `$SUDO`:
#
#   $SUDO install -m 0755 -o root -g root "$tmp" "$SELECT_BIN"
#
# and deck-session.sh sets SUDO="" at file scope, with only stage_preconditions
# ever setting it to `sudo`. So a test that points SUDO at a shim can intercept
# essentially every filesystem effect the stages have. The shim (fake-sudo,
# below) rewrites absolute destination paths to land under a temp fake root and
# appends its full argv to a call log, so a case can assert on BOTH halves of
# what a stage did: the files it produced, and the privileged commands it ran to
# produce them.
#
# 2. verify_*(), which is new in src/ and is why five sections below exist.
#
# The stages that could NOT be reached through $SUDO were the ones that verify
# their work by EXECUTING what they installed, at a readonly absolute path, or
# by reading a hardcoded system path -- neither of which goes through $SUDO. On
# this dev machine /usr/bin/steamos-polkit-helpers/steamos-update exists
# (gamescope-session-steam-git ships it) and `exec pkexec`s, so a unit suite
# running the stage as it shipped would have driven a polkit prompt.
#
# deck-session.sh now factors each of those checks into a verify_* function that
# TAKES the path to exercise, defaulting to the absolute constant -- the same
# move render_update_stub made for generated text. Production passes nothing and
# behaves exactly as before; this suite passes a copy under the fake root, or a
# deliberately broken stub, and gets the identical checks run against it. There
# is no "skip the check for a non-default path" branch in src/, and GATE 4 below
# refuses to run if one appears.
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
#          stage-update-stub        full (§7)
#          stage-timezone-helper    full (§8)
#          stage-priv-write-helper  §9: the whole stage, plus every branch of
#                                   its verifier. The ONE thing not exercised
#                                   end to end is the real rendered helper's
#                                   own WRITE, because the whitelist that
#                                   guards it is anchored on a literal
#                                   /sys/class/... prefix and refuses anything
#                                   under a fake root -- correctly. The
#                                   verifier's read/write/compare arm is
#                                   covered against a stub helper instead, and
#                                   the real helper's REFUSALS are covered
#                                   against the real helper.
#          stage-greeter-rotation   §10: everything except the "upstream's hash
#                                   still matches" arm, which cannot be reached
#                                   without a file that sha256s to
#                                   UPSTREAM_GREETER_SHA256. The drift WARNING
#                                   is covered; the silent arm is not.
#          stage-lizard-mode        full (§11), including the restore, both
#                                   trap paths and the sudoers grant. It has a
#                                   SIXTH gate of its own: the real
#                                   ${LIZARD_SYSFS} is read before and after
#                                   the section and must not have moved.
#
# NOT COVERED, and why:
#
#   stage-input-mapper       Blocked from OUTSIDE this file.
#                            test/unit/test-osk-install-layout.sh sed's
#                            stage_input_mapper's body out of deck-session.sh
#                            and greps it for three code shapes, one of which
#                            is the very command substitution that would move
#                            into a verify_input_mapper(). Splitting this stage
#                            makes that suite fail, so the two have to be
#                            changed in one go. Its static shape and the
#                            mapper's own behaviour are already covered there.
#
# ---------------------------------------------------------------------------
# SAFETY -- a test that could touch the real system is worse than no test
# ---------------------------------------------------------------------------
#
# Five gates, all of which must hold before any stage body runs:
#
#   1. SUDO must be empty after sourcing deck-session.sh (copied from
#      test/unit/test-deck-session.sh -- if that initialisation ever changes,
#      refuse to run rather than find out by prompting for a password in CI).
#   2. `sudo`, `systemctl`, `visudo`, `dconf` and `env` must all resolve to
#      this suite's stubs, not to the real binaries.
#   3. fake-sudo refuses to run at all unless FAKE_ROOT and SANDBOX are set,
#      and refuses any argument that would resolve outside them.
#   4. Every verify_* seam must take its path from $1 and must not name the
#      absolute constant in an executed position. This gate is STATIC and it
#      runs BEFORE any of §7-§10, deliberately: the failure it guards against
#      is a seam silently reverting to the constant, and the cost of finding
#      that out at runtime is executing the real pkexec'ing helper.
#      `sandboxed` then refuses, per call, to hand a seam any path that is not
#      inside $work.
#   5. Every path fake-sudo actually executed against is re-checked at the end
#      of the run (§11) and must be inside $work.
#
# TMPDIR is also pointed inside $work, so the `mktemp` calls inside the stages
# stage their content there rather than in the system temp directory.
#
# THE HOST IS READ IN FOUR PLACES, all of them reads and all of them declared:
# /etc/dconf/profile/user (§6, branched on), /usr/share/zoneinfo/<zone> (§8 --
# the rendered helper validates against the real zoneinfo tree, by design),
# /usr/bin/timedatectl's existence (§8's stage precondition), and `luac`'s
# (§10). Sections that need one they cannot find say so and skip.
#
# ---------------------------------------------------------------------------
# FINDINGS THIS SUITE PINS
# ---------------------------------------------------------------------------
#
# stage_return_icon used to be the one install stage that wrote a file with no
# ownership marker AND no assert_ours_or_absent in front of it, so a re-run
# clobbered whatever was at that path. Fixed in src/; §5 now pins the marker,
# the refusal and the re-run. Two other stages (stage-sddm-resilience,
# stage-greeter-rotation) also have no assert_ours_or_absent, but the files they
# write DO carry the marker, so the "would silently clobber" property was
# unique to this one.

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

# What the udevadm stub answers `info --query=property` from: one file per
# input node, named for the node, holding the KEY=value lines udev would
# export. §14 writes it; nothing else reads it.
export FAKE_UDEV_DB="$work/udev-db"

# The timezone the fake timedatectl reports, held in a FILE rather than an
# environment variable so `set-timezone` can actually change it. That matters:
# verify_timezone_helper reads the zone, runs the helper, and re-reads -- a
# constant oracle would make its "the helper changed the timezone" guard
# unfalsifiable, which is the same defect the dconf stub above was written to
# avoid.
export FAKE_TZ_FILE="$work/timezone"

# A whitelisted-SHAPED backlight node that does not exist, anywhere, on any
# machine. §9 hands this to the priv-write helper so the stage takes its "no
# backlight here" branch deterministically -- on a real AMD laptop the constant
# WOULD exist and the stage would try to write it. It still matches the helper's
# whitelist regex, so the helper's non-numeric refusal is exercised for the
# right reason rather than being refused earlier as an unlisted path.
readonly ABSENT_BACKLIGHT=/sys/class/backlight/deck-session-suite-absent/brightness

# The zone §8 round-trips. It has to be one the REAL /usr/share/zoneinfo has,
# because the rendered helper's last and most important validation is
# `[[ -f /usr/share/zoneinfo/$tz ]]` -- reading the host's zoneinfo tree is the
# point of that check, so faking it would be testing something else. UTC is on
# every Linux with tzdata; §8 gates on it rather than assuming.
readonly SUITE_TIMEZONE=UTC

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

  # The rendered timezone helper elevates with `sudo -n /usr/bin/timedatectl`,
  # by ABSOLUTE path, because that is the form omarchy-settings-dev's sudoers
  # rule matches. fake-sudo rewrites that under the fake root, so the stub has
  # to exist there as well as on PATH -- and it is the same stub, so both views
  # of "the system timezone" are the one file.
  cp "$stub_bin/timedatectl" "$root/usr/bin/timedatectl"
  printf '%s\n' "$SUITE_TIMEZONE" >"$FAKE_TZ_FILE"

  : >"$calls"; : >"$resolved"
}

# Write an executable test double. Body on stdin; the path must be inside $work,
# which `sandboxed` enforces at every call site.
write_program() {   # write_program <path>  <<'SH' ... SH
  local p=$1
  mkdir -p -- "$(dirname -- "$p")"
  cat >"$p"
  chmod +x "$p"
  printf '%s' "$p"
}

# Refuse to hand a seam any path outside the work directory. Every path this
# suite passes to a stage or a verify_* function goes through here, so a typo
# that would point one of them at a REAL absolute path stops the run instead of
# driving it. (GATE 4's static half stops the other direction: a seam that
# ignores its argument and uses the constant.)
sandboxed() {
  local p=$1
  [[ $p == "$work"/* ]] ||
    fail_test "the suite only ever hands a seam a path inside its work directory" \
      "refusing to pass '${p}', which is outside ${work}"
  printf '%s' "$p"
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
  # /dev/null is the ONE absolute path that is not a destination: it is the null
  # device, and `ln -sfn /dev/null <unit>` is how systemd masks a unit. Rewriting
  # it to ${FAKE_ROOT}/dev/null would produce a dangling symlink whose target is
  # not /dev/null -- i.e. NOT a mask -- so the mask assertions would be checking
  # a shape the Deck never gets. Passed through verbatim, and nothing writes to
  # it: the only thing any stage does with this path is point a symlink at it.
  if [[ $a == /dev/null ]]; then argv+=("$a"); continue; fi
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
# The VERB, not $1: stage_lizard_mode asks a USER manager
# (`systemctl --user show ...`), so the verb is not always the first word. An
# earlier version tested $1 and answered nothing for every --user query, which
# made that stage's check look like "no user manager here" on a machine that
# had one -- a stub passing for the wrong reason.
verb=""
for a in "$@"; do
  case $a in -*) continue ;; *) verb=$a; break ;; esac
done

if [[ $verb == show ]]; then
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
  # The uid is dialable because stage-desktop-settings derives the compositor's
  # runtime directory from it. A junk uid must stop the stage rather than be
  # pasted into a path.
  printf '%s:x:%s:1000:Deck test user:%s:/bin/bash\n' "$2" "${FAKE_GETENT_UID:-1000}" "${FAKE_HOME}"
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

# --- timedatectl -----------------------------------------------------------
#
# Stateful, for the reason given at FAKE_TZ_FILE: `set-timezone` writes and
# `show -p Timezone --value` reads the same file, so verify_timezone_helper's
# before/after comparison is a real round trip. A stub that always echoed the
# same zone would let a helper that changes the timezone it was not asked to
# change walk straight through.
#
# Two callers reach this, by two different routes: the STAGE runs `timedatectl`
# through PATH, and the rendered HELPER runs /usr/bin/timedatectl through
# fake-sudo, which rewrites it to the copy reset_root drops in the fake root.
cat >"$stub_bin/timedatectl" <<'STUB_TIMEDATECTL'
#!/usr/bin/env bash
set -uo pipefail
printf 'timedatectl %s\n' "$*" >>"$CALLS_LOG"
case ${1-} in
  show)         cat "$FAKE_TZ_FILE" ;;
  set-timezone) [[ -n ${2-} ]] || exit 2; printf '%s\n' "$2" >"$FAKE_TZ_FILE" ;;
esac
exit "${FAKE_TIMEDATECTL_RC:-0}"
STUB_TIMEDATECTL

# --- hyprctl ---------------------------------------------------------------
#
# 🔴 THE MOST DANGEROUS STUB IN THIS FILE, and the reason
# verify_osk_kb_layout's runtime directory is a parameter rather than a
# constant: the real hyprctl on this developer's machine would find a LIVE
# compositor and `reload` it from a unit test. §6b never lets the stage near
# /run/user, and this stub is the second line of defence -- it refuses to run
# without the suite's own environment.
#
# Every answer is dialable, because each of the four failure shapes the
# verifier distinguishes has to be reachable one at a time:
#   FAKE_HYPRCTL_RELOAD_RC   the reload itself failing
#   FAKE_HYPR_SENTINEL       the block not having run to its last line
#   FAKE_HYPR_DEVICES        the device list, i.e. which keyboard reads what
#   FAKE_HYPR_GLOBAL_LAYOUT  the session's own layout, which is what makes
#                            "did this leak session-wide?" answerable at all
#   FAKE_HYPR_POWER_SENTINEL the same as FAKE_HYPR_SENTINEL, for the OTHER
#                            block -- bindings.lua's power-key unbind
#   FAKE_HYPR_BINDS          the keybinding list, i.e. whether anything still
#                            answers XF86PowerOff after the unbind
cat >"$stub_bin/hyprctl" <<'STUB_HYPRCTL'
#!/usr/bin/env bash
set -uo pipefail
[[ -n ${CALLS_LOG:-} ]] || { printf 'hyprctl stub: no CALLS_LOG, refusing to run\n' >&2; exit 99; }
printf 'hyprctl %s\n' "$*" >>"$CALLS_LOG"

# R-46, reproduced faithfully: the real hyprctl exits before doing anything
# when the signature is unset. A stub that answered anyway would let a verifier
# that forgot it pass.
[[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] || {
  printf 'HYPRLAND_INSTANCE_SIGNATURE not set! (is hyprland running?)\n' >&2
  exit 1
}

args=()
for a in "$@"; do [[ $a == -j ]] && continue; args+=("$a"); done

case ${args[0]-} in
  reload)
    exit "${FAKE_HYPRCTL_RELOAD_RC:-0}"
    ;;
  eval)
    # Not a Lua interpreter. It asserts the PROBE is the shape that can fail --
    # a probe that stopped naming a sentinel, or stopped raising, would be a
    # check that cannot fail, and this stub refuses to bless one.
    #
    # TWO sentinels reach here, from two different blocks in two different user
    # dotfiles, so the stub dispatches on which one the probe names rather than
    # accepting "any DECK_ global": a probe that named the WRONG sentinel would
    # otherwise pass while asserting nothing about its own block.
    code=${args[1]-}
    [[ $code == *error\(* ]] || {
      printf 'hyprctl stub: eval probe does not raise, so it cannot fail: %s\n' "$code" >&2
      exit 98
    }
    case $code in
      *DECK_OSK_KB_LAYOUT*)
        if [[ ${FAKE_HYPR_SENTINEL:-us} != us ]]; then
          # The real shape, measured on the Deck: 'error: ...' on stderr, exit 7.
          printf 'error: [string "..."]:1: DECK_OSK_KB_LAYOUT is not "us"\n' >&2
          exit 7
        fi
        ;;
      *DECK_POWER_MENU_UNBOUND*)
        if [[ ${FAKE_HYPR_POWER_SENTINEL:-set} != set ]]; then
          printf 'error: [string "..."]:1: DECK_POWER_MENU_UNBOUND is not set\n' >&2
          exit 7
        fi
        ;;
      *)
        printf 'hyprctl stub: eval probe names no known sentinel: %s\n' "$code" >&2
        exit 98
        ;;
    esac
    printf 'ok\n'
    exit 0
    ;;
  binds)
    printf '%s\n' "${FAKE_HYPR_BINDS?the suite must set a keybinding list}"
    exit 0
    ;;
  devices)
    printf '%s\n' "${FAKE_HYPR_DEVICES?the suite must set a device list}"
    exit 0
    ;;
  getoption)
    printf '{"option": "input:kb_layout", "str": "%s", "set": true }\n' \
      "${FAKE_HYPR_GLOBAL_LAYOUT:-latam}"
    exit 0
    ;;
esac
exit 0
STUB_HYPRCTL

# --- udevadm ---------------------------------------------------------------
#
# stage_power_button asks udev what it currently knows about each input node,
# so that a rule naming an ID_PATH nothing matches is caught BEFORE it is
# written rather than by a Deck that suspends twice per press.
#
# Only `info --query=property --name <node>` is answered, and the answer comes
# from a fixture directory keyed by the node's basename. Two properties matter:
# ID_PATH (what the rule matches on) and TAGS (what logind filters on).
#
# 🔴 THE STUB REFUSES ANY OTHER VERB, on purpose. `udevadm control
# --reload-rules`, `udevadm trigger` and `udevadm settle` all MUTATE the
# running system's device state, and on this developer's machine they would
# mutate the developer's. The stage is designed to run none of them -- it
# writes files and requires a reboot -- and §14 asserts that the call log
# contains no such call. This refusal is the second line of defence: if the
# stage ever grows one, the run dies here rather than reloading real udev.
cat >"$stub_bin/udevadm" <<'STUB_UDEVADM'
#!/usr/bin/env bash
set -uo pipefail
[[ -n ${CALLS_LOG:-} ]] || { printf 'udevadm stub: no CALLS_LOG, refusing to run\n' >&2; exit 99; }
printf 'udevadm %s\n' "$*" >>"$CALLS_LOG"

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

# --- commands the stages only probe for, or only log through ---------------
for stub in systemd-run findmnt loginctl logger; do
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
for tool in sudo systemctl visudo dconf env getent timedatectl hyprctl udevadm; do
  [[ $(command -v "$tool") == "$stub_bin/$tool" ]] ||
    fail_test "'${tool}' resolves to this suite's stub" \
      "got $(command -v "$tool"); the stub PATH is not in front, so this suite would drive the real system"
done
pass "sudo, systemctl, visudo, dconf, env, getent, timedatectl, hyprctl and udevadm all resolve to stubs, not to the real binaries"

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

# --- GATE 4 ----------------------------------------------------------------
#
# The seams §7-§10 depend on, checked STATICALLY and checked FIRST.
#
# This is the one gate that cannot be a runtime probe, and the reason is the
# whole reason those sections did not exist before. If verify_update_stub ever
# stopped honouring its argument and went back to the constant, a runtime probe
# would discover that BY RUNNING /usr/bin/steamos-polkit-helpers/steamos-update
# -- which exists on this dev machine and is
#
#   exec pkexec --disable-internal-agent "$0" "$@"
#
# i.e. an authentication prompt, from a unit test. So: read the function bodies
# instead, and refuse to proceed unless each one takes its path from $1 and
# names no constant in a position where it would be executed. Only then do the
# sections below hand these functions anything.
#
# Both halves are load-bearing. `${1:-` alone would still pass a function that
# accepted the argument and ignored it; forbidding an executed "$CONSTANT" is
# what makes ignoring it detectable here rather than in the process table.
seam_check() {   # seam_check <function> <forbidden constant name>
  local fn=$1 const=$2 body
  declare -F "$fn" >/dev/null ||
    fail_test "${fn} exists in deck-session.sh" \
      "the verification seam is gone; without it this suite would run the REAL absolute path"
  body=$(declare -f "$fn")
  # shellcheck disable=SC2016  # a grep PATTERN matching a literal ${1:-...} in
  # the function's own text; expanding it would search for this shell's $1.
  grep -q '\${1:-' <<<"$body" ||
    fail_test "${fn} takes the path to exercise as \$1" \
      "no '\${1:-...}' in its body, so passing a path would have no effect and the real constant would run"
  ! grep -qE "\"\\\$${const}\"" <<<"$body" ||
    fail_test "${fn} does not execute \$${const} directly" \
      "it names the absolute constant in an executed position, so the argument is not what gets run:"$'\n'"${body}"
  pass "${fn} takes its path from \$1 and never executes \$${const} directly"
}
seam_check verify_update_stub               UPDATE_STUB
seam_check verify_timezone_helper           TIMEZONE_HELPER
seam_check verify_priv_write_helper         PRIV_WRITE_HELPER
seam_check verify_greeter_compositor_command SDDM_GREETER_DROPIN
seam_check verify_lizard_helper             LIZARD_HELPER
seam_check verify_lizard_grant              LIZARD_HELPER
# The mask carries less execution risk than the others -- nothing here RUNS the
# installed artefact -- but the same seam, for a different reason: it reads its
# symlink back at an absolute path, and off-Deck that path is the developer's
# own /etc/systemd/user. Without the seam §6c would be asserting against a
# machine's real systemd configuration rather than the fake root.
seam_check install_sleep_lock_mask          SLEEP_LOCK_GLOBAL_MASK

# --- GATE 4b ---------------------------------------------------------------
#
# The SECOND seam argument, which only stage-lizard-mode has, and which carries
# more risk than any other path in this suite: it is a /sys node. If
# verify_lizard_helper or stage_lizard_mode ignored $2 and used ${LIZARD_SYSFS},
# a run of §11 on a machine with hid_steam loaded -- any dev box with a Steam
# Controller plugged in, not just a Deck -- would WRITE REAL SYSFS and change
# where that machine's input comes from. Static, and first, for exactly the
# reason GATE 4 is.
node_seam_check() {   # node_seam_check <function> <positional number>
  local fn=$1 pos=$2 body
  declare -F "$fn" >/dev/null ||
    fail_test "${fn} exists in deck-session.sh" "the sysfs seam is gone"
  body=$(declare -f "$fn")
  grep -q "\${${pos}:-" <<<"$body" ||
    fail_test "${fn} takes the sysfs node to write as \$${pos}" \
      "no '\${${pos}:-...}' in its body, so §11 could not keep it off real /sys"
  # shellcheck disable=SC2016  # a grep PATTERN matching the literal text
  # "$LIZARD_SYSFS" in the function's own source; expanding it would search for
  # this shell's value of that constant instead.
  ! grep -qE '"\$LIZARD_SYSFS"' <<<"$body" ||
    fail_test "${fn} does not use \$LIZARD_SYSFS directly" \
      "it names the real /sys node in a position the argument cannot override:"$'\n'"${body}"
  pass "${fn} takes the sysfs node from \$${pos} and never names \$LIZARD_SYSFS directly"
}
node_seam_check verify_lizard_helper  2
node_seam_check stage_lizard_mode     2
node_seam_check render_lizard_helper  1

# --- GATE 4c ---------------------------------------------------------------
#
# The compositor seam, and it carries the same class of risk GATE 4b does, in
# the other direction: verify_osk_kb_layout RELOADS a live Hyprland. With
# /run/user/<uid> baked in, running this suite on any machine whose owner is
# sitting in a Hyprland session -- which describes this project's own developer
# machine -- would reload THEIR desktop from a unit test. Static, and first.
osk_seam_body=$(declare -f verify_osk_kb_layout) ||
  fail_test "verify_osk_kb_layout exists in deck-session.sh" \
    "without it the layout rule ships unverified, and §6b cannot keep the check off a real compositor"
# shellcheck disable=SC2016  # a grep PATTERN matching a literal ${3:-...} in
# the function's own text; expanding it would search for this shell's $3.
grep -q '\${3:-' <<<"$osk_seam_body" ||
  fail_test "verify_osk_kb_layout takes the compositor runtime directory as \$3" \
    "no '\${3:-...}' in its body, so this suite could not keep 'hyprctl reload' away from a real session"
[[ $(grep -c '/run/user' <<<"$osk_seam_body") -eq 1 ]] ||
  fail_test "verify_osk_kb_layout names /run/user exactly once, as \$3's default" \
    "a second mention means some path ignores the argument:"$'\n'"${osk_seam_body}"
pass "verify_osk_kb_layout takes the compositor runtime directory from \$3 and names /run/user only as its default"

osk_stage_body=$(declare -f stage_desktop_settings)
# shellcheck disable=SC2016  # same: the literal text, not this shell's $1.
grep -q '\${1:-' <<<"$osk_stage_body" ||
  fail_test "stage_desktop_settings passes a runtime-directory seam through" \
    "without it §6 would drive the real compositor no matter what verify_osk_kb_layout accepts"
! grep -q '/run/user' <<<"$osk_stage_body" ||
  fail_test "stage_desktop_settings does not name /run/user itself" \
    "the default belongs to the verifier; a copy here is a second path the argument cannot override"
pass "stage_desktop_settings forwards a runtime-directory seam and names no /run/user path of its own"

# The SECOND compositor verifier, added with the power-key unbind, and it
# reloads a live session exactly the same way. The developer machine this suite
# runs on has a live Hyprland socket under /run/user/1000, so a stage that baked
# the path in would reload the operator's own desktop from a unit test -- which
# is not hypothetical: it is what §9d did before this gate existed.
power_seam_body=$(declare -f verify_power_menu_unbind) ||
  fail_test "verify_power_menu_unbind exists in deck-session.sh" \
    "without it the power-key unbind ships unverified, and §9d cannot keep the check off a real compositor"
# shellcheck disable=SC2016  # a grep PATTERN matching a literal ${3:-...}.
grep -q '\${3:-' <<<"$power_seam_body" ||
  fail_test "verify_power_menu_unbind takes the compositor runtime directory as \$3" \
    "no '\${3:-...}' in its body, so this suite could not keep 'hyprctl reload' away from a real session"
[[ $(grep -c '/run/user' <<<"$power_seam_body") -eq 1 ]] ||
  fail_test "verify_power_menu_unbind names /run/user exactly once, as \$3's default" \
    "a second mention means some path ignores the argument:"$'\n'"${power_seam_body}"
pass "verify_power_menu_unbind takes the compositor runtime directory from \$3 and names /run/user only as its default"

power_stage_body=$(declare -f stage_power_button)
# shellcheck disable=SC2016  # same: the literal text, not this shell's $1.
grep -q '\${1:-' <<<"$power_stage_body" ||
  fail_test "stage_power_button passes a runtime-directory seam through" \
    "without it §9d would drive the real compositor no matter what verify_power_menu_unbind accepts"
! grep -q '/run/user' <<<"$power_stage_body" ||
  fail_test "stage_power_button does not name /run/user itself" \
    "the default belongs to the verifier; a copy here is a second path the argument cannot override"
pass "stage_power_button forwards a runtime-directory seam and names no /run/user path of its own"

# The stage's SECOND seam, the sleep-lock mask. Same two halves: it has to
# accept $2, and it must not name /etc/systemd/user itself -- that default
# belongs to the constant, and a copy here would be a path §6 could not steer.
# shellcheck disable=SC2016  # the literal text ${2:-, not this shell's $2.
grep -q '\${2:-' <<<"$osk_stage_body" ||
  fail_test "stage_desktop_settings takes the sleep-lock mask path as \$2" \
    "without it §6 would read back the developer's own /etc/systemd/user"
# The FULL mask path, not the directory: the stage's shadow warning explains
# that ~/.config/systemd/user is searched before /etc/systemd/user, and naming
# the directory in a message is documentation, not a second code path. What
# would be a second code path is the mask FILE, or the constant itself used
# somewhere $2 cannot reach -- both of which are checked, and neither of which
# any prose in this stage has a reason to contain.
! grep -qF "/etc/systemd/user/${SLEEP_LOCK_UNIT}" <<<"$osk_stage_body" ||
  fail_test "stage_desktop_settings does not spell out the mask path itself" \
    "the default belongs to SLEEP_LOCK_GLOBAL_MASK; a literal copy here is a path the argument cannot override"
# shellcheck disable=SC2016  # the literal text "$SLEEP_LOCK_GLOBAL_MASK" in the
# function's source, not this shell's value of it.
! grep -qE '"\$SLEEP_LOCK_GLOBAL_MASK"' <<<"$osk_stage_body" ||
  fail_test "stage_desktop_settings does not use \$SLEEP_LOCK_GLOBAL_MASK directly" \
    "it would install to the real path regardless of what \$2 says"
pass "stage_desktop_settings forwards a sleep-lock-mask seam and spells out no mask path of its own"

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
# Trailing arguments are passed through to the function. That is how §7-§10
# reach the seams: the stages take their destination as an optional argument
# whose default is the absolute constant, so a call with no arguments here is
# byte-for-byte what a Deck runs.
stage_rc=0
run_stage_body() {
  local fn=$1; shift
  stage_rc=0
  : >"$calls"
  (
    # shellcheck disable=SC2030  # SUDO must be local to this subshell: that is
    # the whole safety design. It stays empty in the suite's own shell, which
    # §1 then asserts.
    SUDO="$FAKE_SUDO_BIN"
    DESKTOP_SESSION=omarchy
    "$fn" "$@"
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
#
# ⚠️ THE ASSERTIONS BELOW CHANGED. Until this session this stage wrote its
# .desktop with no install marker and no assert_ours_or_absent in front of it,
# and this section pinned that -- deliberately asserting what the stage DID
# rather than what it should do, and reporting the gap instead of enshrining it.
# The gap is now closed in src/, so the marker, the refusal and the re-run are
# asserted here like every other stage's.

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

# --- the ownership marker, and the refusal it makes possible ---------------
ok_line /usr/share/applications/deck-return-to-gaming.desktop "$INSTALL_MARKER" \
  "the entry carries the install marker, which is what lets a re-run tell its own file from somebody else's"

# The marker is a '#' comment ahead of the group header. That is legal -- the
# Desktop Entry spec ignores comment lines and does not require [Desktop Entry]
# on line 1 -- but "legal" is exactly the kind of claim that turns out to be
# wrong in front of a real parser, so ask one. Two, where both are available.
desktop_file="$root/usr/share/applications/deck-return-to-gaming.desktop"
python3 - "$desktop_file" <<'PY' || fail_test "the installed .desktop parses as a key file with the marker in front of the group header"
import configparser, sys
c = configparser.ConfigParser(interpolation=None, comment_prefixes=('#',))
c.read(sys.argv[1])
assert c.sections() == ["Desktop Entry"], c.sections()
assert c["Desktop Entry"]["Type"] == "Application"
PY
pass "the installed .desktop still parses as a key file -- the marker comment did not displace [Desktop Entry]"

if command -v desktop-file-validate >/dev/null 2>&1; then
  desktop-file-validate "$desktop_file" >"$work/dfv.out" 2>&1 ||
    fail_test "desktop-file-validate accepts the installed entry" "$(cat "$work/dfv.out")"
  pass "desktop-file-validate accepts the entry with the marker comment on line 1"
else
  note "desktop-file-validate not installed; the freedesktop validator did not see this entry"
fi

# The idempotency requirement (CLAUDE.md): a re-run must recognise its own file.
run_stage_body stage_return_icon
ok_rc 0 "a second run succeeds -- assert_ours_or_absent recognises the entry as ours"

# And the whole point of the marker: somebody else's file at that path is now
# refused rather than overwritten. Before this change the stage replaced it
# without a word.
reset_root
printf '[Desktop Entry]\nType=Application\nName=Somebody else\n' \
  >"$root/usr/share/applications/deck-return-to-gaming.desktop"
run_stage_body stage_return_icon
ok_failed "a foreign .desktop at ${RETURN_DESKTOP_FILE} stops the stage instead of being clobbered"
ok_in_err "was not written by deck-session.sh" "the refusal explains that something else owns the path"
grep -qF "Somebody else" "$root/usr/share/applications/deck-return-to-gaming.desktop" ||
  fail_test "the foreign entry is left exactly as it was" \
    "it was overwritten anyway, which is the defect this case exists to prevent"
pass "the foreign entry is left byte-for-byte alone, not merely 'the stage failed'"

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

# The compositor runtime directory §6 hands the stage: it exists, it holds no
# Hyprland socket, and it is inside $work. That pins every §6 run to the "no
# live compositor" branch, so §6 stays about dconf and shell.json and never
# touches a session. §6b drives the live branch on purpose, against the stub.
hypr_dead="$work/hypr-runtime-empty"
mkdir -p "$hypr_dead"

# The stage's other seam: where the omarchy-sleep-lock mask lands. EVERY call
# to stage_desktop_settings below passes it, and that is not optional tidiness
# -- a call that omitted it would install the symlink under the fake root (that
# much fake-sudo guarantees) and then read the result back from the developer's
# REAL /etc/systemd/user, where it is absent, failing the stage for a reason
# that has nothing to do with the case under test. §6c drives the mask's own
# contracts; here it is pinned so the rest of §6 stays about dconf and
# shell.json. /etc/systemd/user is a STOCK_DIR, so its existence is fixture.
sleep_mask=$(sandboxed "$root/etc/systemd/user/$SLEEP_LOCK_UNIT")

# A Deck-shaped device list: one physical keyboard on the session layout, our
# virtual one, and the POINTER half of our uinput device holding the -1 name --
# which is the arrangement measured on the Deck 2026-08-12 and the reason the
# rule names the suffixed aliases at all.
read -r -d '' HYPR_DEVICES_GOOD <<'JSON' || true
{"mice":[{"name":"valve-software-steam-controller"},
         {"name":"deck-input-mapper-virtual-keyboard-1"}],
 "keyboards":[{"name":"at-translated-set-2-keyboard","layout":"latam"},
              {"name":"deck-input-mapper-virtual-keyboard","layout":"us"}]}
JSON
export FAKE_HYPR_DEVICES="$HYPR_DEVICES_GOOD"

# A keybinding list with our unbind already applied: Omarchy's other binds are
# still there and nothing names XF86PowerOff. §9d flips it to the "still bound"
# shape to prove the check can fail. The `key`/`modmask` field names are the
# ones the real hyprctl emits -- read off the Deck 2026-08-16.
read -r -d '' HYPR_BINDS_GOOD <<'JSON' || true
[{"modmask":64,"key":"SPACE","dispatcher":"__lua"},
 {"modmask":0,"key":"XF86AudioLowerVolume","dispatcher":"__lua"},
 {"modmask":64,"key":"ESCAPE","dispatcher":"__lua"}]
JSON
export FAKE_HYPR_BINDS="$HYPR_BINDS_GOOD"

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
    run_stage_body stage_desktop_settings "$hypr_dead" "$sleep_mask"
    ok_failed "stage-desktop-settings refuses a dconf profile that does not list system-db:local"
    ok_in_err "merge it by hand" "the refusal says profile order is precedence and it will not guess"
    note "the rest of §6 needs a host without /etc/dconf/profile/user, or one that already lists system-db:local"
    ;;
  *)
    [[ $host_profile != ok ]] || export FAKE_DCONF_HOST_PROFILE_OK=1
    reset_root; seed_shell_json
    run_stage_body stage_desktop_settings "$hypr_dead" "$sleep_mask"
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

    # --- the OTHER lock producer, wired into the same stage --------------
    #
    # T13 §5.2 / P22 §3.1. The idle policy above and this mask are independent
    # producers of the same artefact -- a password prompt on a device with no
    # keyboard -- and neither covers the other. §6c drives the mask's own
    # contracts; these three assertions are about the WIRING, i.e. that a plain
    # run of this stage installs it at all. Without them the mask could be
    # perfect and never called.
    [[ -L $sleep_mask ]] ||
      fail_test "stage-desktop-settings installs the ${SLEEP_LOCK_UNIT} mask" \
        "no symlink at ${sleep_mask}; the idle producer would be neutered and the SUSPEND producer left live"$'\n'"stderr: $(err)"
    [[ $(readlink -- "$sleep_mask") == /dev/null ]] ||
      fail_test "the installed mask points at /dev/null" \
        "it points at '$(readlink -- "$sleep_mask")'; systemd masks a unit ONLY via a symlink to /dev/null"
    pass "stage-desktop-settings masks ${SLEEP_LOCK_UNIT} at ${SLEEP_LOCK_GLOBAL_MASK}, so a suspended Deck resumes unlocked"
    ok_called "ln -sfn /dev/null" "the mask is created as a symlink, through \$SUDO"

    # A per-user unit file SHADOWS /etc/systemd/user. The operator's own Deck
    # carries a hand-made mask at exactly this path, so agreeing files must NOT
    # warn -- a warning that fires on every run is one nobody reads.
    reset_root; seed_shell_json
    mkdir -p "$(dirname "${FAKE_HOME}/${SLEEP_LOCK_USER_UNIT_REL}")"
    ln -sfn /dev/null "${FAKE_HOME}/${SLEEP_LOCK_USER_UNIT_REL}"
    run_stage_body stage_desktop_settings "$hypr_dead" "$sleep_mask"
    ok_rc 0 "a per-user mask that agrees with ours is not an error"
    ok_in_out "it agrees with ours and is now redundant" \
      "an agreeing per-user mask is reported, not warned about -- this is the state the operator's Deck is in today"
    ! grep -qF "shadows the mask" "$work/stage.err" ||
      fail_test "an agreeing per-user mask produces no shadow warning" \
        "it warned anyway, which trains the operator to ignore the message"$'\n'"stderr: $(err)"
    pass "no shadow warning is emitted for a per-user file that is itself a mask"

    reset_root; seed_shell_json
    mkdir -p "$(dirname "${FAKE_HOME}/${SLEEP_LOCK_USER_UNIT_REL}")"
    printf '[Unit]\nDescription=someone re-enabled this by hand\n' \
      >"${FAKE_HOME}/${SLEEP_LOCK_USER_UNIT_REL}"
    run_stage_body stage_desktop_settings "$hypr_dead" "$sleep_mask"
    ok_rc 0 "a per-user unit file shadowing the mask is a warning, not a failure"
    ok_in_err "shadows the mask this stage just installed" \
      "the warning says WHY it matters -- ~/.config/systemd/user comes before /etc/systemd/user, so the Deck could still lock on resume"
    rm -rf "${FAKE_HOME:?}/.config/systemd"

    # A user-level value shadows the site default. Warn only when it DISAGREES.
    export FAKE_DCONF_USER_KEY="$OSK_KEY"
    export FAKE_DCONF_USER_VALUE=false
    reset_root; seed_shell_json
    run_stage_body stage_desktop_settings "$hypr_dead" "$sleep_mask"
    ok_rc 0 "a user value shadowing the site default is a warning, not a failure"
    ok_in_err "is shadowing it" "the warning says a user-level value is shadowing the default, and how to reset it"
    unset FAKE_DCONF_USER_KEY FAKE_DCONF_USER_VALUE

    export FAKE_DCONF_UPDATE_RC=1
    reset_root; seed_shell_json
    run_stage_body stage_desktop_settings "$hypr_dead" "$sleep_mask"
    ok_failed "a failed 'dconf update' stops the stage"
    ok_in_err "on disk but not compiled" "the failure distinguishes 'written' from 'compiled', which is the state that does nothing"
    unset FAKE_DCONF_UPDATE_RC

    # `dconf update` exiting 0 having compiled the wrong thing is the failure
    # the read-back exists for: the database answers, with the value that was
    # there before. An "is it non-empty" check would pass; only comparing
    # against the expected value catches it.
    export FAKE_DCONF_STALE_VALUE=false
    reset_root; seed_shell_json
    run_stage_body stage_desktop_settings "$hypr_dead" "$sleep_mask"
    ok_failed "a site database that answers with the OLD value fails the stage"
    ok_in_err "the OSK would never auto-show for a new user" \
      "the read-back compares against the expected value, not merely 'did dconf answer'"
    unset FAKE_DCONF_STALE_VALUE

    # An unparseable shell.json must not be rewritten from scratch.
    reset_root; seed_shell_json
    printf 'not json at all\n' >"$FAKE_HOME/$OMARCHY_SHELL_JSON_REL"
    run_stage_body stage_desktop_settings "$hypr_dead" "$sleep_mask"
    ok_failed "a shell.json that is not JSON stops the stage rather than being replaced"
    ok_in_err "could not patch the idle policy" "the failure names the file it would not overwrite"

    # --- the on-screen keyboard's XKB layout -----------------------------
    #
    # The defect: the OSK draws US and emits raw keycodes, the session is
    # Latin American, so ';' types 'n-tilde'. Every assertion below is about a
    # way the rule could be installed and do NOTHING.
    reset_root; seed_shell_json
    run_stage_body stage_desktop_settings "$hypr_dead" "$sleep_mask"
    ok_rc 0 "the stage still completes with the keyboard-layout rule in it"
    osk_lua="${FAKE_HOME}/${HYPR_INPUT_LUA_REL}"
    [[ -f $osk_lua ]] ||
      fail_test "the stage writes ${HYPR_INPUT_LUA_REL}" "missing: ${osk_lua}"$'\n'"stderr: $(err)"
    pass "the stage installs the layout rule into the desktop user's ${HYPR_INPUT_LUA_REL}"
    for osk_marker in "$OSK_KB_RULE_BEGIN" "$OSK_KB_RULE_END"; do
      grep -qxF -- "$osk_marker" "$osk_lua" ||
        fail_test "the installed file carries the marker line '${osk_marker}'" \
          "an unpaired marker is what makes a re-run refuse rather than splice"$'\n'"$(cat "$osk_lua")"
    done
    pass "the installed file carries both delimiters, which is what makes the block replaceable"
    grep -qxF "${OSK_KB_SENTINEL} = \"${OSK_KB_LAYOUT}\"" "$osk_lua" ||
      fail_test "the installed block ends with the sentinel assignment" \
        "without it the live check has nothing that can fail"$'\n'"$(cat "$osk_lua")"
    pass "the installed block sets ${OSK_KB_SENTINEL}, the global the live check asserts on"
    ok_called "sudo -u ${SUDO_USER} install -D -m 0644" \
      "the rule is written AS the desktop user. Written as root it would land in their ~/.config owned by root, where Omarchy's own tooling could no longer edit it -- and \$SUDO is empty exactly when this script is already root, so 'it happens to work here' is not evidence."

    # 🔴 The whole point of a stage rather than a hand edit: it is re-runnable.
    # An append-only implementation would grow a second block on every run and
    # eventually be two rules disagreeing with each other.
    run_stage_body stage_desktop_settings "$hypr_dead" "$sleep_mask"
    ok_rc 0 "the stage is re-runnable with the rule already installed"
    [[ $(grep -cxF -- "$OSK_KB_RULE_BEGIN" "$osk_lua") -eq 1 ]] ||
      fail_test "a second run replaces the block instead of appending another" \
        "found $(grep -cxF -- "$OSK_KB_RULE_BEGIN" "$osk_lua") start markers"
    pass "re-running replaces the block in place -- exactly one copy, however many times it runs"

    # ⚠️ The file it patches is the SAME file that carries the OSK's
    # `above_lock = 2` layer rule on the test Deck. Losing that makes the lock
    # screen unanswerable on a device with no physical keyboard (5.24). A
    # rewrite-from-scratch implementation would pass every assertion above.
    reset_root; seed_shell_json
    mkdir -p "$(dirname "$osk_lua")"
    printf -- '-- the user'"'"'s own file\nhl.layer_rule({ match = { namespace = "deck-osk" }, above_lock = 2 })\n' >"$osk_lua"
    run_stage_body stage_desktop_settings "$hypr_dead" "$sleep_mask"
    ok_rc 0 "the stage completes against an input.lua that already has user content"
    grep -qF 'above_lock = 2' "$osk_lua" ||
      fail_test "the user's existing input.lua content survives the patch" \
        "the above_lock rule is what lets the on-screen keyboard render over the session lock; a device with no physical keyboard cannot answer a lock without it"$'\n'"$(cat "$osk_lua")"
    pass "the user's own rules survive -- including the above_lock rule the lock screen depends on"

    # A half-removed previous block cannot be spliced safely, and guessing
    # would eat whatever followed it.
    reset_root; seed_shell_json
    mkdir -p "$(dirname "$osk_lua")"
    printf '%s\nhl.device({ name = "x" })\n' "$OSK_KB_RULE_BEGIN" >"$osk_lua"
    run_stage_body stage_desktop_settings "$hypr_dead" "$sleep_mask"
    ok_failed "a start marker with no end marker stops the stage"
    ok_in_err "could not splice" "the failure names the splice rather than reporting a generic write error"

    # No compositor: the rule is on disk and NOT observed working. Saying so is
    # the requirement -- 5.30b's lesson is that a rule nobody has seen work is
    # not a rule that works.
    reset_root; seed_shell_json
    run_stage_body stage_desktop_settings "$hypr_dead" "$sleep_mask"
    ok_in_err "has NOT been observed working" \
      "with no live compositor the stage says the rule is unverified instead of reporting success"
    ok_in_err "$OSK_HYPR_DEVICE" "the warning names the device to look for, so the operator can check it by hand"

    # --- the live branch, against the stub compositor --------------------
    #
    # A directory with a real unix socket in it, which is how the stage
    # decides a compositor is there at all.
    hypr_live="$work/hypr-runtime-live"
    rm -rf "$hypr_live"; mkdir -p "$hypr_live/hypr/deadbeef_1"
    python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' \
      "$hypr_live/hypr/deadbeef_1/.socket.sock" ||
      fail_test "the suite can create a fake compositor socket" "python3 could not bind an AF_UNIX socket"

    reset_root; seed_shell_json
    run_stage_body stage_desktop_settings "$hypr_live" "$sleep_mask"
    ok_rc 0 "with a live compositor and a device on '${OSK_KB_LAYOUT}', the stage completes"
    ok_in_out "the whole rule block executed" "the sentinel assertion is reported as a verification, not assumed"
    ok_in_out "kept the session layout" "the check also confirms the OTHER keyboards did not change -- per-device, not session-wide"
    ok_called "hyprctl reload config-only" "it reloads the config before reading it back, so the readback is not describing the previous run"
    ok_before "hyprctl reload config-only" "hyprctl -j devices" "the reload happens BEFORE the device list is read"

    # The sentinel is the block's last line, so its absence means the block did
    # not run to the end -- hl.device raising on an unknown field looks exactly
    # like this. It must be a failure, not a warning.
    export FAKE_HYPR_SENTINEL=absent
    reset_root; seed_shell_json
    run_stage_body stage_desktop_settings "$hypr_live" "$sleep_mask"
    ok_failed "a compositor without the sentinel fails the stage"
    ok_in_err "did not run to the end" "the failure says the BLOCK did not complete, which is what a raised hl.device looks like"
    unset FAKE_HYPR_SENTINEL

    # The sentinel present and the layout still wrong: the block loaded and did
    # not attach to the device. That is the rename hazard, and it is the one
    # failure a sentinel alone cannot see.
    export FAKE_HYPR_DEVICES='{"mice":[],"keyboards":[{"name":"at-translated-set-2-keyboard","layout":"latam"},{"name":"deck-input-mapper-virtual-keyboard","layout":"latam"}]}'
    reset_root; seed_shell_json
    run_stage_body stage_desktop_settings "$hypr_live" "$sleep_mask"
    ok_failed "a device that loaded the rule and still reads the session layout fails the stage"
    ok_in_err "reads layout 'latam'" "the failure reports what the device ACTUALLY says, not merely that it disagreed"
    export FAKE_HYPR_DEVICES="$HYPR_DEVICES_GOOD"

    # 🔴 The opposite failure, and the one the operator asked for by name: the
    # rule must not become session-wide. Every keyboard reading 'us' while the
    # session's own layout is not 'us' means the physical keyboards changed too.
    export FAKE_HYPR_DEVICES='{"mice":[],"keyboards":[{"name":"at-translated-set-2-keyboard","layout":"us"},{"name":"deck-input-mapper-virtual-keyboard","layout":"us"}]}'
    reset_root; seed_shell_json
    run_stage_body stage_desktop_settings "$hypr_live" "$sleep_mask"
    ok_failed "a rule that changed every keyboard's layout fails the stage"
    ok_in_err "went SESSION-WIDE" "the failure names the per-device requirement rather than reporting a generic mismatch"
    export FAKE_HYPR_DEVICES="$HYPR_DEVICES_GOOD"

    # 🔴 THE ORDERING HAZARD, driven end to end. Our uinput device declares
    # keys AND relative axes, so Hyprland binds it twice and appends -1 to
    # whichever copy loses the race for the bare name. Measured on the Deck the
    # keyboard won -- but nothing promises that, and here the POINTER has the
    # bare name while the keyboard carries -1. A rule that named only the bare
    # form would be attached to a pointer, where kb_layout is inert, and this
    # would read as "no such keyboard" rather than as a failure.
    export FAKE_HYPR_DEVICES='{"mice":[{"name":"deck-input-mapper-virtual-keyboard"}],"keyboards":[{"name":"at-translated-set-2-keyboard","layout":"latam"},{"name":"deck-input-mapper-virtual-keyboard-1","layout":"us"}]}'
    reset_root; seed_shell_json
    run_stage_body stage_desktop_settings "$hypr_live" "$sleep_mask"
    ok_rc 0 "the rule still verifies when the keyboard holds the -1 name and the pointer holds the bare one"
    ok_in_out "kept the session layout" \
      "the check follows the suffixed aliases too; matching only the bare name would report the keyboard as simply not present"
    export FAKE_HYPR_DEVICES="$HYPR_DEVICES_GOOD"

    # No keyboards at all is not "our device is missing" -- it is a device list
    # worth drawing no conclusion from. Reporting absence there would turn a
    # broken query into a reassuring warning.
    export FAKE_HYPR_DEVICES='{"mice":[],"keyboards":[]}'
    reset_root; seed_shell_json
    run_stage_body stage_desktop_settings "$hypr_live" "$sleep_mask"
    ok_failed "a compositor reporting no keyboards at all fails the stage"
    ok_in_err "could not read the keyboard layouts back" \
      "an empty device list is a check that could not run, not a device that is absent"
    export FAKE_HYPR_DEVICES="$HYPR_DEVICES_GOOD"

    # A crashed compositor leaves its instance DIRECTORY behind with no socket
    # in it. Treating that as a live session means talking to nothing and
    # believing the answer.
    rm -rf "$work/hypr-runtime-stale"; mkdir -p "$work/hypr-runtime-stale/hypr/deadbeef_1"
    reset_root; seed_shell_json
    run_stage_body stage_desktop_settings "$work/hypr-runtime-stale" "$sleep_mask"
    ok_rc 0 "a stale instance directory with no socket is not treated as a live compositor"
    ok_in_err "no live Hyprland instance" \
      "the socket is what makes an instance live; a leftover directory would otherwise be 'verified' against a compositor that is not there"

    # The mapper not running is NOT the rule being wrong: the device simply is
    # not bound. Warn, do not fail -- and do not claim success either.
    export FAKE_HYPR_DEVICES='{"mice":[],"keyboards":[{"name":"at-translated-set-2-keyboard","layout":"latam"}]}'
    reset_root; seed_shell_json
    run_stage_body stage_desktop_settings "$hypr_live" "$sleep_mask"
    ok_rc 0 "a stopped input mapper is a warning, not a failure -- the rule is correct and inert"
    ok_in_err "could not be observed taking effect" "the warning distinguishes 'not bound' from 'not working'"
    export FAKE_HYPR_DEVICES="$HYPR_DEVICES_GOOD"

    # A reload that fails leaves the running session on the old config. The
    # file is on disk and the session is not using it, which is the one state
    # that must never be reported as success.
    export FAKE_HYPRCTL_RELOAD_RC=1
    reset_root; seed_shell_json
    run_stage_body stage_desktop_settings "$hypr_live" "$sleep_mask"
    ok_failed "a failed 'hyprctl reload' stops the stage"
    ok_in_err "has not picked it up" "the failure distinguishes 'written to disk' from 'loaded by the session'"
    unset FAKE_HYPRCTL_RELOAD_RC

    # A junk uid must not be pasted into a path. /run/user/<junk> simply would
    # not exist, which is indistinguishable from "no compositor running" -- a
    # verification that quietly downgrades itself to a warning.
    export FAKE_GETENT_UID=not-a-number
    reset_root; seed_shell_json
    run_stage_body stage_desktop_settings "$hypr_dead" "$sleep_mask"
    ok_failed "a non-numeric uid stops the stage"
    ok_in_err "non-numeric uid" "the failure names the uid rather than building a runtime path out of it"
    unset FAKE_GETENT_UID

    # A Lua syntax error is SILENT: Hyprland discards the file and falls back,
    # taking the OSK's above_lock rule with it. Installing a file already known
    # to be unparseable is the one thing this must never do.
    if command -v luac >/dev/null 2>&1; then
      reset_root; seed_shell_json
      mkdir -p "$(dirname "$osk_lua")"
      printf 'this is not lua at all ((\n' >"$osk_lua"
      run_stage_body stage_desktop_settings "$hypr_dead" "$sleep_mask"
      ok_failed "an input.lua that does not parse as Lua stops the stage"
      ok_in_err "not valid Lua" \
        "Hyprland discards an unparseable config WITHOUT logging a reason, so installing one would silently drop the above_lock rule too"
    else
      note "luac is not installed, so the 'refuses to install unparseable Lua' assertion is skipped"
    fi

    # An `install` that exits 0 having written nothing. Not hypothetical: this
    # whole stage exists because settings that were 'applied' turned out not to
    # be there, and an exit code is not a file.
    reset_root; seed_shell_json
    cat >"$stub_bin/install" <<'STUB_INSTALL'
#!/usr/bin/env bash
printf 'install %s\n' "$*" >>"$CALLS_LOG"
exit 0
STUB_INSTALL
    chmod +x "$stub_bin/install"
    run_stage_body install_osk_kb_layout_rule "$SUDO_USER" "${FAKE_HOME}/.config/hypr/never-written.lua"
    rm -f "$stub_bin/install"
    ok_failed "an install that exits 0 without writing the file fails the stage"
    ok_in_err "reported success and the file does not have the rule in it" \
      "the stage re-reads what it wrote instead of trusting install's exit code"

    # The device name is the ONLY thing tying this rule to the mapper's uinput
    # device, and it is spelled twice: once as the mapper declares it, once
    # normalised the way Hyprland matches it. Drifting one without the other
    # produces a rule that parses, loads, and matches nothing.
    osk_drift="$work/deck-session-drifted.sh"
    sed 's/^readonly OSK_UINPUT_NAME=.*/readonly OSK_UINPUT_NAME="renamed virtual keyboard"/' \
      "$REPO_ROOT/src/deck-session.sh" >"$osk_drift"
    grep -q 'renamed virtual keyboard' "$osk_drift" ||
      fail_test "the drift fixture actually changed OSK_UINPUT_NAME" "sed matched nothing; this case would pass vacuously"
    # A separate bash PROCESS, not a subshell: every constant in this file is
    # readonly and a subshell inherits them, so the drifted copy would be
    # rejected line by line and never reach the check under test.
    osk_drift_rc=0
    bash -c 'set +e; . "$1"; SUDO="$4"; install_osk_kb_layout_rule "$2" "$3"' \
      _ "$osk_drift" "$SUDO_USER" "${FAKE_HOME}/.config/hypr/drift.lua" "$FAKE_SUDO_BIN" \
      >/dev/null 2>"$work/stage.err" || osk_drift_rc=$?
    [[ $osk_drift_rc -ne 0 ]] ||
      fail_test "a device name that no longer normalises to the matched name stops the stage" \
        "it exited 0, so a mapper rename would ship a rule matching no device at all"
    ok_in_err "matches no device and does nothing at all" \
      "the refusal explains that the rule would be inert rather than wrong"
    pass "a drifted OSK_UINPUT_NAME stops the stage instead of shipping a rule matched to nothing"
    ;;
esac

# ===========================================================================
# 6c. install_sleep_lock_mask -- the artefact that makes a suspended Deck
#     resume unlocked, and survive a wiped home
# ===========================================================================
#
# docs/findings/T13-power-button-and-sleep.md §5.2 row B and
# docs/findings/P22-deck-conformance-sweep.md §3.1. The defect this closes is
# not a missing feature, it is state in the wrong place: the operator's Deck
# was masked BY HAND at ~/.config/systemd/user, dated Aug 11 17:54, with the
# unit's preset still `enabled` and its enablement symlink still sitting
# underneath. A fresh install, a second user or a wiped home re-arms it, and
# what it re-arms is a password prompt on a device with no keyboard and no
# unlock IPC -- which is not "type your password", it is "hold power for ten
# seconds and lose your work" (T13 §5.3).
#
# OUTSIDE the host_profile case above, deliberately: none of this depends on
# the developer's dconf profile, and the mask is the load-bearing half of the
# stage. §6 covers the WIRING (that a plain stage run installs it); this
# covers the artefact's own contracts, through the seam GATE 4 already
# verified, so nothing here touches the real /etc/systemd/user.
#
# THE SHAPE IS THE WHOLE POINT and is why every assertion reads the symlink
# rather than the path: systemd masks a unit only via a symlink to /dev/null.
# A regular empty file at the same path loads as a unit with no directives --
# not masked, starting nothing, indistinguishable in `ls` -- so an
# implementation that produced one would be a silent no-op that ships a Deck
# locking itself out on the first suspend.
mask_probe=$(sandboxed "$root/etc/systemd/user/$SLEEP_LOCK_UNIT")

reset_root
run_stage_body install_sleep_lock_mask "$mask_probe"
ok_rc 0 "install_sleep_lock_mask completes against a fake root"
[[ -L $mask_probe ]] ||
  fail_test "it creates a symlink at ${SLEEP_LOCK_GLOBAL_MASK}" \
    "nothing at ${mask_probe}"$'\n'"stderr: $(err)"
[[ ! -f $mask_probe || -L $mask_probe ]] ||
  fail_test "the artefact is a symlink, not a regular file" \
    "a regular file there is a unit with no directives, which is not a mask"
pass "the mask is a SYMLINK -- the only shape systemd treats as masked"
[[ $(readlink -- "$mask_probe") == /dev/null ]] ||
  fail_test "the symlink points at /dev/null" \
    "it points at '$(readlink -- "$mask_probe")'"
pass "the symlink points at /dev/null, which is byte-for-byte what 'systemctl --global mask' writes"
ok_called "ln -sfn /dev/null" "the symlink is created through \$SUDO, so an unprivileged install fails loudly rather than half-working"
ok_called "install -d -m 0755 -o root -g root" "the unit directory is created rather than assumed"

# /etc, not $HOME. This is the entire durability claim: a home directory can be
# wiped and a second user has none of the first user's state.
[[ $mask_probe == "$root"/etc/systemd/user/* ]] ||
  fail_test "the mask lands under /etc/systemd/user" "got ${mask_probe}"
! grep -qF "$FAKE_HOME" "$calls" ||
  fail_test "installing the mask writes nothing into a home directory" \
    "a per-user path appeared in the call log, which is the fragility this replaces:"$'\n'"$(cat "$calls")"
pass "the mask is image-level state under /etc/systemd/user and touches no home directory"

# --- idempotent, which the SSH iterate loop and every image rebuild need ---
run_stage_body install_sleep_lock_mask "$mask_probe"
ok_rc 0 "a second run against an existing mask succeeds"
ok_in_out "is already masked" "the re-run reports the existing mask rather than silently redoing the work"
[[ $(readlink -- "$mask_probe") == /dev/null ]] ||
  fail_test "the mask is unchanged after a re-run" "it now points at '$(readlink -- "$mask_probe")'"
pass "a re-run leaves the same symlink to /dev/null"
! grep -qF 'ln -sfn' "$calls" ||
  fail_test "the re-run does not re-create the symlink" \
    "it called ln again; the 'already masked' branch is not the one that ran, so the check above passed for the wrong reason"$'\n'"$(cat "$calls")"
pass "the re-run takes the 'already masked' branch -- no ln call at all"

# --- it refuses to clobber something that is not ours ----------------------
#
# A symlink at this path pointing somewhere else is an ALIAS or a drop-in
# somebody installed on purpose. 'ln -sfn' alone would replace it without a
# word, which is the silent-overwrite class this project forbids.
reset_root
ln -sfn /usr/lib/systemd/user/somebody-elses.service "$mask_probe"
run_stage_body install_sleep_lock_mask "$mask_probe"
ok_failed "a symlink pointing somewhere other than /dev/null stops the stage"
ok_in_err "Refusing to replace it" "the refusal says it will not guess, and names what it found"
[[ $(readlink -- "$mask_probe") == /usr/lib/systemd/user/somebody-elses.service ]] ||
  fail_test "the foreign symlink is left exactly as it was" \
    "it now points at '$(readlink -- "$mask_probe")' -- it was replaced before failing"
pass "the foreign symlink is untouched"

reset_root
printf '[Unit]\nDescription=a real override, not a mask\n' >"$mask_probe"
run_stage_body install_sleep_lock_mask "$mask_probe"
ok_failed "a regular unit file at the mask path stops the stage"
ok_in_err "is not a symlink" "the refusal distinguishes a real unit override from a mask"
grep -qF 'a real override, not a mask' "$mask_probe" ||
  fail_test "the existing unit file is left byte-for-byte alone" "its contents changed before the stage failed"
pass "an existing unit file is not overwritten"

# --- an `ln` that exits 0 having created nothing ---------------------------
#
# The read-back's whole reason for existing, and the same mutation §6 runs
# against `install`: an exit code is not a symlink. Without the read-back this
# ships a Deck that locks on resume with every log line claiming success.
reset_root
cat >"$stub_bin/ln" <<'STUB_LN'
#!/usr/bin/env bash
printf 'ln %s\n' "$*" >>"$CALLS_LOG"
exit 0
STUB_LN
chmod +x "$stub_bin/ln"
run_stage_body install_sleep_lock_mask "$mask_probe"
rm -f "$stub_bin/ln"
ok_failed "an ln that exits 0 without creating the symlink fails the stage"
ok_in_err "is not a symlink after installing it" \
  "the stage reads the symlink back instead of trusting ln's exit code"

# --- and the shape that is a mask-looking no-op ---------------------------
#
# The most dangerous near-miss: a regular EMPTY file where the symlink should
# be. It is what a `touch`-shaped implementation produces, it passes any
# 'does the path exist' check, and it does not mask anything.
reset_root
cat >"$stub_bin/ln" <<'STUB_LN'
#!/usr/bin/env bash
printf 'ln %s\n' "$*" >>"$CALLS_LOG"
: >"${@: -1}"
exit 0
STUB_LN
chmod +x "$stub_bin/ln"
run_stage_body install_sleep_lock_mask "$mask_probe"
rm -f "$stub_bin/ln"
ok_failed "an ln that leaves a regular empty file instead of a symlink fails the stage"
ok_in_err "is not a symlink after installing it" \
  "an empty regular unit file loads with no directives and masks NOTHING; the check rejects it by shape"

reset_root

# ===========================================================================
# 7. stage-update-stub -- the exit codes Steam's first run depends on
# ===========================================================================
#
# NEW COVERAGE. This stage was unreachable until deck-session.sh grew
# verify_update_stub: it proves its work by RUNNING the file it installed, at
# /usr/bin/steamos-polkit-helpers/steamos-update, and that file exists on this
# dev machine and `exec pkexec`s. GATE 4 has already refused to continue unless
# the seam is real, and `sandboxed` refuses to hand it anything outside $work.
#
# PROGRESS.md 5.14: exit 0 on the apply path made Steam reboot the Deck once per
# OOBE pass. The three checks below the install are the only thing standing
# between that and a boot loop, and until now nothing ran them off a Deck.

# A steamos-update with dialable exit codes, so each of the verifier's three
# checks can be failed one at a time while the other two stay correct.
fake_update_stub() {   # fake_update_stub <path> <check-rc> <dup-rc> <apply-rc>
  write_program "$1" >/dev/null <<SH
#!/usr/bin/env bash
case \${1-} in
  check)                          exit $2 ;;
  --supports-duplicate-detection) exit $3 ;;
  *)                              exit $4 ;;
esac
SH
}

reset_root
update_dest=$(sandboxed "${root}${UPDATE_STUB}")
run_stage_body stage_update_stub "$update_dest"
ok_rc 0 "stage-update-stub completes against a fake root"
ok_file "$UPDATE_STUB" "it installs ${UPDATE_STUB}"
ok_mode "$UPDATE_STUB" 755 "the stub is mode 0755 -- Steam execs it"
ok_called "install -d -m 0755 -o root -g root ${root}${POLKIT_HELPER_DIR}" \
  "it creates ${POLKIT_HELPER_DIR} rather than assuming it: on a non-SteamOS machine that whole tree is absent, which is the defect"
ok_called "install -m 0755 -o root -g root" "the stub is installed root-owned -- Steam runs it through pkexec's tree"
ok_before "install -d" "install -m 0755" "the directory is created before the file goes into it"
ok_in_file "$UPDATE_STUB" "$INSTALL_MARKER" "the installed stub carries the install marker"
ok_in_out "verified: 'check' exits 7 (up to date)" \
  "the stage verifies by RUNNING the stub it installed, and says so"

# The installed artefact itself, exercised directly. This is the protocol
# test/unit/test-deck-session.sh checks against render_update_stub's TEXT; here
# it is the file that really landed on disk, at the mode it landed with.
rc=0; "$root$UPDATE_STUB" check >/dev/null 2>&1 || rc=$?
[[ $rc -eq 7 ]] || fail_test "the INSTALLED stub answers 'check' with 7" "exited ${rc}"
pass "the installed stub -- not the rendered text -- answers 'check' with 7"
rc=0; "$root$UPDATE_STUB" >/dev/null 2>&1 || rc=$?
[[ $rc -ne 0 ]] ||
  fail_test "the INSTALLED stub does not exit 0 on the apply path" \
    "0 means 'an update was applied' and Steam reboots to finish it, every OOBE pass"
pass "the installed stub's apply path is non-zero, so Steam has nothing to reboot for"

run_stage_body stage_update_stub "$update_dest"
ok_rc 0 "a second run succeeds -- the marker makes the stage recognise its own stub"

reset_root
# The helper directory is NOT in STOCK_DIRS -- on a non-SteamOS machine it does
# not exist, which is the whole defect -- so a foreign file needs it created.
mkdir -p "$root$POLKIT_HELPER_DIR"
printf '#!/bin/sh\n# a real SteamOS updater, hypothetically\n' >"$root$UPDATE_STUB"
run_stage_body stage_update_stub "$update_dest"
ok_failed "a foreign file at ${UPDATE_STUB} stops the stage rather than being overwritten"
ok_in_err "was not written by deck-session.sh" "the refusal explains whose file is in the way"

# --- the verifier's three guards, one broken at a time ---------------------
#
# The positive control comes first on purpose: it proves the fake stub is
# otherwise correct, so each failure below is caused by the one code that was
# changed and not by the double being wrong in some other way.
probe_stub=$(sandboxed "$work/fake-steamos-update")

fake_update_stub "$probe_stub" 7 1 7
run_stage_body verify_update_stub "$probe_stub"
ok_rc 0 "verify-update-stub passes a stub that answers 7 / non-zero / non-zero"

fake_update_stub "$probe_stub" 0 1 7
run_stage_body verify_update_stub "$probe_stub"
ok_failed "a 'check' that exits 0 fails verification"
ok_in_err "not 7" "the failure says Steam reads 7 as 'up to date' and anything else restores the first-run dialog"

fake_update_stub "$probe_stub" 7 0 7
run_stage_body verify_update_stub "$probe_stub"
ok_failed "claiming duplicate-detection support fails verification"
ok_in_err "claims duplicate-detection support" "the failure names the capability the stub does not implement"

fake_update_stub "$probe_stub" 7 1 0
run_stage_body verify_update_stub "$probe_stub"
ok_failed "an apply path that exits 0 fails verification -- the boot loop of PROGRESS.md 5.14"
ok_in_err "REBOOTS the device" "the failure says what exit 0 makes Steam do, not merely that it was wrong"

# ===========================================================================
# 8. stage-timezone-helper -- OOBE's picker, and the grant behind it
# ===========================================================================
#
# NEW COVERAGE, same seam. Steam's timezone picker called an absolute path that
# did not exist, got 127 every time, and silently changed nothing.
#
# The round trip below is real rather than mimed: the stage reads the zone
# through `timedatectl`, the rendered helper writes it through
# `sudo -n /usr/bin/timedatectl set-timezone`, and both resolve to the same
# stateful stub over the same file. So "the helper changed a timezone it was
# asked to leave alone" is a state this suite can actually produce.

if [[ ! -x $TIMEDATECTL_BIN ]]; then
  note "skipping §8: ${TIMEDATECTL_BIN} is absent, and the stage's own precondition refuses to install a helper that would fail at runtime"
elif [[ ! -f /usr/share/zoneinfo/$SUITE_TIMEZONE ]]; then
  note "skipping §8: /usr/share/zoneinfo/${SUITE_TIMEZONE} is absent, and the rendered helper validates against the real zoneinfo tree by design"
else

reset_root
tz_dest=$(sandboxed "${root}${TIMEZONE_HELPER}")
run_stage_body stage_timezone_helper "$tz_dest"
ok_rc 0 "stage-timezone-helper completes against a fake root"
ok_file "$TIMEZONE_HELPER" "it installs ${TIMEZONE_HELPER}"
ok_mode "$TIMEZONE_HELPER" 755 "the helper is mode 0755"
ok_in_file "$TIMEZONE_HELPER" "$INSTALL_MARKER" "the installed helper carries the install marker"

ok_file "$TIMEZONE_SUDOERS" "it installs ${TIMEZONE_SUDOERS}"
ok_mode "$TIMEZONE_SUDOERS" 440 "${TIMEZONE_SUDOERS} is mode 0440 -- sudo ignores a drop-in with any other mode"
ok_line "$TIMEZONE_SUDOERS" "decktester ALL=(root) NOPASSWD: ${TIMEDATECTL_BIN} set-timezone *" \
  "the grant is one SUBCOMMAND of one absolute path -- not the whole of timedatectl, whose set-ntp and set-time are not needed"
ok_called "visudo -c -f" "the sudoers candidate is validated with 'visudo -c -f'"
ok_before "visudo -c -f" "install -m 0440" \
  "validation happens BEFORE the drop-in is installed -- a malformed sudoers file breaks sudo for every user"

tz_grant=$(grep -v '^#' "$root$TIMEZONE_SUDOERS" | grep -v '^[[:space:]]*$' | head -1)
! sudoers_line_is_blanket "$tz_grant" ||
  fail_test "the timezone grant is scoped, not blanket" "sudoers_line_is_blanket flagged: ${tz_grant}"
sudoers_line_is_nopasswd "$tz_grant" ||
  fail_test "the timezone grant is passwordless" "Gaming Mode cannot answer a password prompt; got: ${tz_grant}"
pass "the timezone drop-in reads as scoped-and-passwordless to the release check's own predicate"

# The verification really drove the helper, and the helper really reached
# timedatectl through the grant -- both halves are in the call log.
ok_in_out "verified: helper set the timezone to its existing value (${SUITE_TIMEZONE})" \
  "the stage verifies by RUNNING the helper against the zone the machine is already on, so a passing check changes nothing"
ok_called "timedatectl set-timezone ${SUITE_TIMEZONE}" \
  "the helper reached timedatectl by absolute path through sudo -- the form the sudoers rule matches"

# The installed artefact's own security property. The grant covers
# 'set-timezone <anything>', so this validation is the only thing between a
# caller-supplied string and a privileged command.
rc=0; "$root$TIMEZONE_HELPER" ../../etc/shadow >/dev/null 2>&1 || rc=$?
[[ $rc -ne 0 ]] ||
  fail_test "the INSTALLED helper refuses a path-traversal timezone" "it exited 0"
pass "the installed helper -- not the rendered text -- refuses a traversal before elevating"

run_stage_body stage_timezone_helper "$tz_dest"
ok_rc 0 "a second run of stage-timezone-helper succeeds"

reset_root
mkdir -p "$root$POLKIT_HELPER_DIR"
printf '#!/bin/sh\n# a real SteamOS helper, hypothetically\n' >"$root$TIMEZONE_HELPER"
run_stage_body stage_timezone_helper "$tz_dest"
ok_failed "a foreign file at ${TIMEZONE_HELPER} stops the stage"
ok_in_err "was not written by deck-session.sh" "the refusal explains whose file is in the way"

# --- the verifier's guards, against helpers that misbehave one way each ----
reset_root
tz_probe=$(sandboxed "$work/fake-set-timezone")

write_program "$tz_probe" >/dev/null <<'SH'
#!/usr/bin/env bash
# Correct: sets exactly what it was asked for, refuses a traversal.
case ${1-} in ..|../*|*/..|*/../*) exit 3 ;; esac
printf '%s\n' "$1" >"$FAKE_TZ_FILE"
SH
run_stage_body verify_timezone_helper "$tz_probe"
ok_rc 0 "verify-timezone-helper passes a helper that round-trips the zone and refuses a traversal"

write_program "$tz_probe" >/dev/null <<'SH'
#!/usr/bin/env bash
exit 3
SH
run_stage_body verify_timezone_helper "$tz_probe"
ok_failed "a helper that fails on the machine's CURRENT zone fails verification"
ok_in_err "failed setting the timezone to its current value" \
  "the failure says the helper installed but does not work, so the picker would still fail silently"

write_program "$tz_probe" >/dev/null <<'SH'
#!/usr/bin/env bash
# Sets a DIFFERENT zone from the one it was handed.
printf 'Antarctica/Troll\n' >"$FAKE_TZ_FILE"
SH
run_stage_body verify_timezone_helper "$tz_probe"
ok_failed "a helper that changes the timezone it was asked to leave alone fails verification"
ok_in_err "changed the timezone from" "the failure names both zones, so the read-back is a comparison and not a liveness check"

write_program "$tz_probe" >/dev/null <<'SH'
#!/usr/bin/env bash
# Writes whatever it is handed, traversal included.
printf '%s\n' "$1" >"$FAKE_TZ_FILE"
SH
printf '%s\n' "$SUITE_TIMEZONE" >"$FAKE_TZ_FILE"
run_stage_body verify_timezone_helper "$tz_probe"
ok_failed "a helper that accepts a path-traversal timezone fails verification"
ok_in_err "accepted a path-traversal timezone" \
  "the failure says it must validate against /usr/share/zoneinfo before elevating"

fi   # §8 host gate

# ===========================================================================
# 9. stage-priv-write-helper -- the whitelist that bounds a root write
# ===========================================================================
#
# NEW COVERAGE. Tier 1 of the three-tier fallback in deck-session.sh's header:
# without this helper Steam reaches for `sudo -n tee` and then `sudo -n chmod
# a+w`, which needs blanket NOPASSWD and leaves sysfs nodes world-writable after
# every Gaming Mode start. The sudoers grant covers the helper with ANY
# arguments, so the whitelist INSIDE it is the actual security boundary.
#
# ⚠️ THE SECOND SEAM ARGUMENT IS NOT SANDBOXED, and that is deliberate. It is
# ${ABSENT_BACKLIGHT}: a path that MATCHES the helper's whitelist regex but
# exists nowhere, so the stage takes its "no backlight here" branch on every
# machine. Using the real constant instead would take the write branch on any
# AMD laptop. It is only ever stat'd and handed to a helper that refuses it, but
# gate it anyway -- an existing file there would mean writing to real sysfs.
[[ ! -e $ABSENT_BACKLIGHT ]] ||
  fail_test "the stand-in backlight node does not exist on this machine" \
    "${ABSENT_BACKLIGHT} exists; §9 would hand a REAL sysfs path to a helper that writes"
pass "the stand-in backlight node is absent, so §9 cannot reach a real sysfs write"

reset_root
pw_dest=$(sandboxed "${root}${PRIV_WRITE_HELPER}")
run_stage_body stage_priv_write_helper "$pw_dest" "$ABSENT_BACKLIGHT"
ok_rc 0 "stage-priv-write-helper completes against a fake root"
ok_file "$PRIV_WRITE_HELPER" "it installs ${PRIV_WRITE_HELPER}"
ok_mode "$PRIV_WRITE_HELPER" 755 "the helper is mode 0755"
ok_in_file "$PRIV_WRITE_HELPER" "$INSTALL_MARKER" "the installed helper carries the install marker"

ok_file "$PRIV_WRITE_SUDOERS" "it installs ${PRIV_WRITE_SUDOERS}"
ok_mode "$PRIV_WRITE_SUDOERS" 440 "${PRIV_WRITE_SUDOERS} is mode 0440"
ok_line "$PRIV_WRITE_SUDOERS" "decktester ALL=(root) NOPASSWD: ${PRIV_WRITE_HELPER}" \
  "the grant names the helper's PRODUCTION absolute path and nothing else -- it is not repointed by the test seam"
ok_called "visudo -c -f" "the sudoers candidate is validated with 'visudo -c -f'"
ok_before "visudo -c -f" "install -m 0440" "validation happens before the drop-in is installed"

pw_grant=$(grep -v '^#' "$root$PRIV_WRITE_SUDOERS" | grep -v '^[[:space:]]*$' | head -1)
! sudoers_line_is_blanket "$pw_grant" ||
  fail_test "the priv-write grant is scoped, not blanket" "sudoers_line_is_blanket flagged: ${pw_grant}"
sudoers_line_is_nopasswd "$pw_grant" ||
  fail_test "the priv-write grant is passwordless" "Steam cannot answer a password prompt; got: ${pw_grant}"
pass "the priv-write drop-in reads as scoped-and-passwordless to the release check's own predicate"

ok_in_err "not present, so the helper's write path was NOT exercised" \
  "with no backlight node the stage SAYS the write path went unchecked rather than reporting a pass it did not earn"
ok_in_out "verified: refuses a non-whitelisted path and a non-numeric value" \
  "the refusals are still checked when the write path is not -- they are the security boundary, not a bonus"

# The installed artefact's own refusals, including the one Steam actually asks
# for and this project deliberately does not answer.
rc=0; "$root$PRIV_WRITE_HELPER" /etc/shadow 1 >/dev/null 2>&1 || rc=$?
[[ $rc -ne 0 ]] || fail_test "the INSTALLED helper refuses /etc/shadow" "it exited 0"
pass "the installed helper refuses a path outside its whitelist"
rc=0; "$root$PRIV_WRITE_HELPER" /dev/drm_dp_aux0 '' >/dev/null 2>&1 || rc=$?
[[ $rc -ne 0 ]] ||
  fail_test "the INSTALLED helper refuses /dev/drm_dp_aux0, which Steam does ask for" \
    "it is deliberately NOT whitelisted -- an empty write to a DP AUX side band is not understood here"
pass "the installed helper refuses /dev/drm_dp_aux0 with the empty value Steam sends for it"

run_stage_body stage_priv_write_helper "$pw_dest" "$ABSENT_BACKLIGHT"
ok_rc 0 "a second run of stage-priv-write-helper succeeds"

reset_root
mkdir -p "$root$POLKIT_HELPER_DIR"
printf '#!/bin/sh\n# a real SteamOS helper, hypothetically\n' >"$root$PRIV_WRITE_HELPER"
run_stage_body stage_priv_write_helper "$pw_dest" "$ABSENT_BACKLIGHT"
ok_failed "a foreign file at ${PRIV_WRITE_HELPER} stops the stage"
ok_in_err "was not written by deck-session.sh" "the refusal explains whose file is in the way"

# --- the WRITE arm, which the stage above cannot reach --------------------
#
# The real helper's whitelist is anchored on a literal /sys/class/... prefix, so
# it correctly refuses anything under a fake root -- there is no way to exercise
# the real write off a Deck without weakening that anchor, which would be the
# test seam introducing the hazard. So the verifier's read/write/compare arm is
# covered against a helper double instead, one misbehaviour at a time.
reset_root
pw_probe=$(sandboxed "$work/fake-priv-write")
fake_backlight=$(sandboxed "$work/fake-backlight")
write_program "$pw_probe" >/dev/null <<'SH'
#!/usr/bin/env bash
[[ ${1-} == /etc/shadow ]] && exit "${FAKE_PW_SHADOW_RC:-3}"
[[ ${2-} =~ ^[0-9]+$ ]] || exit "${FAKE_PW_NONNUMERIC_RC:-4}"
[[ ${FAKE_PW_WRITE_RC:-0} -eq 0 ]] || exit "${FAKE_PW_WRITE_RC}"
printf '%s\n' "${FAKE_PW_WRITE_VALUE:-$2}" >"$1"
SH

printf '412\n' >"$fake_backlight"
run_stage_body verify_priv_write_helper "$pw_probe" "$fake_backlight"
ok_rc 0 "verify-priv-write-helper passes a helper that writes back the value it was given"
ok_in_out "verified: wrote ${fake_backlight} its existing value (412)" \
  "the write arm ran: it read the node, wrote that same value through the helper, and re-read it"

export FAKE_PW_WRITE_RC=5
printf '412\n' >"$fake_backlight"
run_stage_body verify_priv_write_helper "$pw_probe" "$fake_backlight"
ok_failed "a helper that cannot write the node fails verification"
ok_in_err "would fall through to the sudo tee/chmod path" \
  "the failure names the consequence -- blanket sudo and world-writable sysfs -- not just a bad exit code"
unset FAKE_PW_WRITE_RC

export FAKE_PW_WRITE_VALUE=999
printf '412\n' >"$fake_backlight"
run_stage_body verify_priv_write_helper "$pw_probe" "$fake_backlight"
ok_failed "a helper that writes a DIFFERENT value than it was asked for fails verification"
ok_in_err "while being asked for 412" "the re-read is compared against the value sent, not merely checked for being non-empty"
unset FAKE_PW_WRITE_VALUE

export FAKE_PW_SHADOW_RC=0
printf '412\n' >"$fake_backlight"
run_stage_body verify_priv_write_helper "$pw_probe" "$fake_backlight"
ok_failed "a helper that accepts /etc/shadow fails verification"
ok_in_err "only thing bounding a root write" "the failure says the whitelist IS the boundary and it is not working"
unset FAKE_PW_SHADOW_RC

export FAKE_PW_NONNUMERIC_RC=0
printf '412\n' >"$fake_backlight"
run_stage_body verify_priv_write_helper "$pw_probe" "$fake_backlight"
ok_failed "a helper that accepts a non-numeric brightness value fails verification"
ok_in_err "accepted a non-numeric brightness value" "the value check is asserted separately from the path check"
unset FAKE_PW_NONNUMERIC_RC

# ===========================================================================
# 10. stage-greeter-rotation -- the panel transform, and whose value WINS
# ===========================================================================
#
# NEW COVERAGE. Two hardcoded system reads used to make this stage's outcome a
# property of whichever laptop ran the suite: /usr/share/sddm/hyprland.lua, and
# `cat /etc/sddm.conf.d/*.conf` for the winning CompositorCommand. Both are
# parameters now.
#
# PROGRESS.md 5.11 and the INSTALL_MARKER comment in deck-session.sh: a '#' on
# line 2 of a Lua config is a syntax error, Hyprland discards the whole file
# without logging, and the greeter comes up rotated looking like the transform
# simply did not work. Hence the marker prefix split, and hence the luac gate.

reset_root
upstream_fixture=$(sandboxed "$work/upstream-hyprland.lua")
printf 'hl.config({ misc = { disable_hyprland_logo = true } })\n' >"$upstream_fixture"
greeter_dropin=$(sandboxed "${root}${SDDM_GREETER_DROPIN}")

# A drop-in that sorts BEFORE ours, exactly as Omarchy's 10-wayland.conf does.
# Our 'zy-' name has to beat it, and this is the case that says so.
printf '[Wayland]\nCompositorCommand=start-hyprland -- --config /usr/share/sddm/hyprland.lua\n' \
  >"$root/etc/sddm.conf.d/10-wayland.conf"

run_stage_body stage_greeter_rotation "$upstream_fixture" "$greeter_dropin"
ok_rc 0 "stage-greeter-rotation completes against a fake root"

ok_file "$GREETER_LUA" "it installs ${GREETER_LUA}"
ok_mode "$GREETER_LUA" 644 "the greeter config is mode 0644 -- sddm reads it as another user"
# The argv as the STAGE passed it, before fake-sudo rewrote it: GREETER_LUA is
# not part of this stage's seam, so the destination it asks for is the real
# production path -- which is what should be asserted here.
ok_called "install -d -m 0755 -o root -g root $(dirname "$GREETER_LUA")" \
  "it creates its own directory beside upstream's rather than editing the package-owned file"
ok_line "$GREETER_LUA" "$INSTALL_MARKER_LUA" \
  "the greeter config carries the LUA-prefixed marker -- a '#' on line 2 is a syntax error Hyprland discards silently"
ok_line "$GREETER_LUA" \
  "hl.monitor({ output = \"${PANEL_OUTPUT}\", mode = \"preferred\", position = \"auto\", scale = ${PANEL_SCALE}, transform = ${PANEL_TRANSFORM} })" \
  "the transform line is exact: transform 3 (270deg), not 1 -- 1 was applied on this hardware and renders upside down"

ok_file "$SDDM_GREETER_DROPIN" "it installs ${SDDM_GREETER_DROPIN}"
ok_mode "$SDDM_GREETER_DROPIN" 644 "the sddm drop-in is mode 0644"
ok_line "$SDDM_GREETER_DROPIN" "$INSTALL_MARKER" "the sddm drop-in carries the install marker"
ok_line "$SDDM_GREETER_DROPIN" "CompositorCommand=start-hyprland -- --config ${GREETER_LUA}" \
  "the drop-in repoints the greeter compositor at OUR config, not at upstream's"
ok_line "$SDDM_GREETER_DROPIN" "DisplayServer=wayland" "it also pins the greeter to Wayland, where hl.monitor applies"

ok_in_out "verified: ours is the winning CompositorCommand" \
  "the stage checks which value WINS across the drop-in directory, not merely that its own file exists"
ok_in_err "has changed since" \
  "an upstream greeter config that no longer matches UPSTREAM_GREETER_SHA256 warns about drift rather than passing quietly"

if command -v luac >/dev/null 2>&1; then
  ok_in_out "verified: generated greeter config is valid Lua" "the stage syntax-checks the config before installing it"
  luac -p "$root$GREETER_LUA" 2>"$work/luaerr" ||
    fail_test "the INSTALLED greeter config parses as Lua" "$(cat "$work/luaerr")"
  pass "the installed greeter config parses (luac -p) -- Hyprland would discard it silently otherwise"
else
  ok_in_err "was NOT syntax-checked" "with no luac the stage says the Lua check did not run rather than implying it passed"
  note "luac is not installed, so neither the stage nor this suite parsed the generated Lua"
fi

run_stage_body stage_greeter_rotation "$upstream_fixture" "$greeter_dropin"
ok_rc 0 "a second run of stage-greeter-rotation succeeds"

# --- upstream's config is gone: mirroring it would be guesswork -----------
reset_root
run_stage_body stage_greeter_rotation "$(sandboxed "$work/no-such-upstream.lua")" "$greeter_dropin"
ok_failed "an absent upstream greeter config stops the stage"
ok_in_err "Omarchy's greeter config has moved" \
  "the refusal says mirroring a file it cannot read would be guesswork, rather than shipping a stale mirror"
ok_absent "$SDDM_GREETER_DROPIN" "nothing is written when the mirror source cannot be found"

# --- something sorts after 'zy-' and takes the key ------------------------
#
# The whole reason the stage reads back a WINNER instead of its own file. This
# is also the exact bug class SDDM_DROPIN's comment records: a name that sorted
# before autologin.conf, and a comment asserting an ordering nobody checked.
reset_root
printf '[Wayland]\nCompositorCommand=start-hyprland -- --config /somebody/elses.lua\n' \
  >"$root/etc/sddm.conf.d/zz-later.conf"
run_stage_body stage_greeter_rotation "$upstream_fixture" "$greeter_dropin"
ok_failed "a drop-in sorting after 'zy-' that overrides CompositorCommand fails the stage"
ok_in_err "Something sorts after 'zy-'" \
  "the failure says the greeter would still render rotated, and names the value that won"
ok_file "$SDDM_GREETER_DROPIN" "our drop-in was still written -- 'installed' and 'winning' are different questions"

# ===========================================================================
# 11. stage-lizard-mode -- the stage that can cost the operator their input
# ===========================================================================
#
# PROGRESS.md 5.21, operator decision 2 in 5.25. lizard_mode is a MODULE
# PARAMETER: Y at every boot, and with Y the controller firmware swallows X, Y,
# L1, R1, STEAM and QAM entirely, so deck-input-mapper.py is a complete no-op.
# With N those six appear and the firmware's own pointer disappears -- the
# mapper is then the ONLY input path on the device.
#
# The design under test is "lizard mode is off IF AND ONLY IF the mapper is
# running": a helper, a narrow sudo grant, and the mapper unit's own
# ExecStartPost=/ExecStopPost=. Three properties are load-bearing and each has
# its own case below:
#
#   the DIRECTION      'off' must write N. Inverted, the helper exits 0, logs
#                      success, and leaves the device in the opposite state.
#   the FALLBACK       ExecStopPost= is what makes a crashed mapper survivable.
#                      Delete it and a mapper that dies leaves a handheld with
#                      no pointer and no keys, recoverable only over SSH.
#   the RESTORE        the stage exercises the helper BOTH ways, so it passes
#                      through "lizard mode off, no mapper running" on purpose.
#                      A stage that returned 0 having left it there would be
#                      the hazard the whole design exists to remove.
#
# --- GATE 6, this section's own ---------------------------------------------
#
# GATE 4b proved statically that the seams take the node from an argument.
# This proves it dynamically, and it is cheap: read the REAL node before and
# after, and require it not to have moved. On this dev machine it is absent and
# stays absent; on a machine with hid_steam loaded (a Steam Controller is
# enough) a regression that reached real sysfs would show up here as a changed
# value rather than as a mysteriously repointed input stack.
lz_real_before="<absent>"
[[ ! -e $LIZARD_SYSFS ]] || lz_real_before=$(cat "$LIZARD_SYSFS" 2>/dev/null || printf '<unreadable>')
note "the real ${LIZARD_SYSFS} reads '${lz_real_before}' before §11; it must read the same after"

lz_node=$(sandboxed "$work/lizard_mode")
lz_dest=$(sandboxed "${root}${LIZARD_HELPER}")

# reset_root plus the two things this stage needs that no other does: the mapper
# unit it hangs a drop-in on, and a node with a known value in it.
lz_setup() {   # lz_setup <Y|N>
  reset_root
  mkdir -p "$root$(dirname "$MAPPER_UNIT")"
  printf '%s\n[Unit]\nDescription=stand-in for the mapper unit\n' "$INSTALL_MARKER" \
    >"$root$MAPPER_UNIT"
  printf '%s\n' "$1" >"$lz_node"
}

# What a systemd manager that parsed BOTH halves correctly would report. The
# stage asks four questions and they are one property, so the fake answers them
# as a set: a manager that knows ExecStopPost= but not OnFailure= is not a state
# any real system is in, and a suite that mimed it would be testing a fiction.
lz_exec_line="{ path=${SUDO_BIN} ; argv[]=${SUDO_BIN} -n ${LIZARD_HELPER} on ; ignore_errors=no }"
lz_systemd_agrees() {
  export FAKE_SYSTEMCTL_SHOW_ExecStopPost="$lz_exec_line"
  export FAKE_SYSTEMCTL_SHOW_OnFailure="${LIZARD_RESTORE_UNIT##*/}"
  export FAKE_SYSTEMCTL_SHOW_LoadState=loaded
  export FAKE_SYSTEMCTL_SHOW_ExecStart="$lz_exec_line"
}
lz_systemd_silent() {
  unset FAKE_SYSTEMCTL_SHOW_ExecStopPost FAKE_SYSTEMCTL_SHOW_OnFailure \
        FAKE_SYSTEMCTL_SHOW_LoadState FAKE_SYSTEMCTL_SHOW_ExecStart
}

lz_setup Y
run_stage_body stage_lizard_mode "$lz_dest" "$lz_node"
ok_rc 0 "stage-lizard-mode completes against a fake root"

# --- 1. the helper ---
ok_file "$LIZARD_HELPER" "it installs ${LIZARD_HELPER}"
ok_mode "$LIZARD_HELPER" 755 "the helper is mode 0755"
ok_in_file "$LIZARD_HELPER" "$INSTALL_MARKER" "the installed helper carries the install marker"
[[ -d "$root/usr/local/sbin" ]] ||
  fail_test "the stage creates /usr/local/sbin itself" \
    "it is NOT in STOCK_DIRS on purpose: a stage that stopped calling 'install -d' would fail here rather than on the Deck"
pass "the stage creates /usr/local/sbin itself rather than assuming a stock install has it"

# --- 2. the sudoers grant ---
ok_file "$LIZARD_SUDOERS" "it installs ${LIZARD_SUDOERS}"
ok_mode "$LIZARD_SUDOERS" 440 "${LIZARD_SUDOERS} is mode 0440 -- sudo ignores a drop-in with any other mode"
ok_line "$LIZARD_SUDOERS" "decktester ALL=(root) NOPASSWD: ${LIZARD_HELPER} on, ${LIZARD_HELPER} off" \
  "the grant names the helper's PRODUCTION absolute path and its two legal arguments, and nothing else -- it is not repointed by the test seam"
ok_called "visudo -c -f" "the sudoers candidate is validated with 'visudo -c -f'"
ok_before "visudo -c -f" "install -m 0440" \
  "validation happens BEFORE the drop-in is installed -- a malformed sudoers file breaks sudo for every user"

lz_grant=$(grep -v '^#' "$root$LIZARD_SUDOERS" | grep -v '^[[:space:]]*$' | head -1)
! sudoers_line_is_blanket "$lz_grant" ||
  fail_test "the lizard grant is scoped, not blanket" "sudoers_line_is_blanket flagged: ${lz_grant}"
sudoers_line_is_nopasswd "$lz_grant" ||
  fail_test "the lizard grant is passwordless" \
    "ExecStartPost=/ExecStopPost= have no terminal to answer a password prompt on; got: ${lz_grant}"
pass "the lizard drop-in reads as scoped-and-passwordless to the release check's own predicate"

# The grant must not name a path under the test's fake root. That would mean the
# seam had leaked into the thing that ships.
! grep -qF -- "$work" "$root$LIZARD_SUDOERS" ||
  fail_test "no test path leaked into the sudoers grant" \
    "the grant mentions ${work}; the seam repoints where the helper is INSTALLED, never what the grant permits"
pass "the sudoers grant carries no test path -- the seam does not leak into the shipped grant"

# --- 3. the OnFailure unit: a separate unit, purely to get a separate CGROUP -
#
# MEASURED, systemd 261: a cgroup-wide SIGKILL starts ExecStopPost= and then
# kills it, because systemd spawns it INTO the mapper's cgroup
# ("Control process exited, code=killed, status=9/KILL"). A unit reached by
# OnFailure= is a separate job in its own cgroup and survives the same kill --
# confirmed on `systemctl kill -s SIGKILL`, `--kill-whom=all` and cgroup.kill.
ok_file "$LIZARD_RESTORE_UNIT" "it installs ${LIZARD_RESTORE_UNIT}"
ok_mode "$LIZARD_RESTORE_UNIT" 644 "the restore unit is mode 0644"
ok_in_file "$LIZARD_RESTORE_UNIT" "$INSTALL_MARKER" "the restore unit carries the install marker"
ok_line "$LIZARD_RESTORE_UNIT" "Type=oneshot" \
  "it is Type=oneshot with no RemainAfterExit=, so it returns to inactive and OnFailure= can trigger it again -- measured at six consecutive triggers, six runs"
ok_line "$LIZARD_RESTORE_UNIT" "ExecStart=${SUDO_BIN} -n ${LIZARD_HELPER} on" \
  "it runs '${LIZARD_HELPER} on' -- towards the safe value, which is what makes it harmless when it races a restarting mapper"
! grep -qE '^ExecStart=.* off$' "$root$LIZARD_RESTORE_UNIT" ||
  fail_test "the installed restore unit can never turn lizard mode OFF" \
    "a restore able to write N could take input away from a device with no mapper running -- the failure the whole fallback exists to prevent"
pass "the installed restore unit cannot turn lizard mode off; its worst case costs STEAM+X, never input"
! grep -q '^\[Install\]' "$root$LIZARD_RESTORE_UNIT" ||
  fail_test "the installed restore unit has no [Install] section" \
    "it is reached by OnFailure= and nothing else. Enabled, it would fire at every session start and race the mapper's own ExecStartPost="
pass "the installed restore unit has no [Install] -- it is triggered, never enabled"
! grep -qE 'systemctl .*(enable|start) .*deck-lizard-restore' "$calls" ||
  fail_test "the stage never enables or starts the restore unit" \
    "calls:"$'\n'"$(cat "$calls")"
pass "the stage neither enables nor starts the restore unit"

# It has to be installed BEFORE the drop-in that names it, so OnFailure= never
# points at a unit that is not there yet.
#
# NOT ok_before: that matches the FIRST log line carrying each path, and both
# paths appear earlier in their own `test -e` ownership checks. The question is
# about the two INSTALLS, so match those.
install_line_for() {   # install_line_for <path>
  grep -nF -- 'install -m 0644' "$calls" | grep -F -- "$1" | head -1 | cut -d: -f1
}
lz_restore_at=$(install_line_for "$LIZARD_RESTORE_UNIT")
lz_dropin_at=$(install_line_for "$LIZARD_DROPIN")
[[ -n $lz_restore_at && -n $lz_dropin_at && $lz_restore_at -lt $lz_dropin_at ]] ||
  fail_test "the restore unit is installed BEFORE the drop-in that names it" \
    "restore at ${lz_restore_at:-none}, drop-in at ${lz_dropin_at:-none}. Installed the other way round there is a window where OnFailure= resolves to nothing. calls:"$'\n'"$(cat "$calls")"
pass "the restore unit is installed before the drop-in whose OnFailure= names it"

# --- 4. the drop-in ---
ok_file "$LIZARD_DROPIN" "it installs ${LIZARD_DROPIN}"
ok_mode "$LIZARD_DROPIN" 644 "the drop-in is mode 0644"
ok_in_file "$LIZARD_DROPIN" "$INSTALL_MARKER" "the drop-in carries the install marker"
ok_line "$LIZARD_DROPIN" "[Service]" "the drop-in declares [Service] -- Exec lines outside a section are ignored"
ok_line "$LIZARD_DROPIN" "ExecStartPost=${SUDO_BIN} -n ${LIZARD_HELPER} off" \
  "ExecStartPost= turns lizard mode OFF, and only once the mapper has been started"
ok_line "$LIZARD_DROPIN" "ExecStopPost=${SUDO_BIN} -n ${LIZARD_HELPER} on" \
  "ExecStopPost= turns it back ON -- THE FALLBACK. Measured, systemd 261: it runs on a clean stop, on a non-zero exit, on a SIGKILLed main process, on a missing ExecStart= and on a failed ExecStartPost=. NOT on a cgroup-wide SIGKILL, which is recorded above render_lizard_dropin"
ok_line "$LIZARD_DROPIN" "[Unit]" "the drop-in declares [Unit] -- OnFailure= is a [Unit] setting and is 'Unknown key' under [Service]"
ok_line "$LIZARD_DROPIN" "OnFailure=${LIZARD_RESTORE_UNIT##*/}" \
  "OnFailure= names the restore unit -- the half that survives 'systemctl kill -s SIGKILL', which is the command a human types while debugging and which kills ExecStopPost= with the cgroup"
! grep -qE '^Exec(Start|Stop)Post=-' "$root$LIZARD_DROPIN" ||
  fail_test "neither Exec line is prefixed with '-'" \
    "'-' makes systemd ignore the failure: on ExecStartPost= that is a mapper reading a device the firmware still owns, and on ExecStopPost= it is the fallback silently not happening"
pass "neither Exec line is prefixed with '-' -- a failure in either is loud, which is the whole point"

# --- the stage's own verification ran, both ways, and put the node back ---
ok_in_out "verified: '${root}${LIZARD_HELPER} off' left ${lz_node} at N" \
  "the stage proved the OFF direction by running the helper and re-reading the node itself"
ok_in_out "verified: '${root}${LIZARD_HELPER} on' left ${lz_node} at Y" \
  "and the ON direction, which is the one every failure path depends on"
[[ $(cat "$lz_node") == Y ]] ||
  fail_test "the stage leaves the node at the value it found (Y)" \
    "it reads '$(cat "$lz_node")'. A stage that returns 0 having left lizard mode off, with no mapper running, IS the hazard this design exists to remove"
pass "the stage restored the node to Y -- the value it found before it started"

# The stage must not START anything. Turning lizard mode off for real is the
# operator's call, in front of the Deck, and this stage installs a fallback
# rather than exercising it on a live session.
! grep -qE 'systemctl .*(--user |--global )?(start|restart|enable) .*deck-input-mapper' "$calls" ||
  fail_test "the stage starts, restarts or enables nothing" \
    "it would turn lizard mode off on a live machine on the strength of a service nobody has watched work. calls:"$'\n'"$(cat "$calls")"
pass "the stage starts nothing -- the drop-in applies when the mapper next starts, not now"

# --- the restore is not hardcoded to Y ------------------------------------
#
# The mutation this kills: a restore that always writes Y. On a Deck where the
# mapper is already running (lizard mode N), that silently turns the device's
# real input path off while the mapper keeps reading a node that has gone quiet.
lz_setup N
run_stage_body stage_lizard_mode "$lz_dest" "$lz_node"
ok_rc 0 "stage-lizard-mode completes when the node starts at N"
[[ $(cat "$lz_node") == N ]] ||
  fail_test "the stage restores N when it found N" \
    "it reads '$(cat "$lz_node")' -- a restore hardcoded to Y would pass the Y case above and break every machine where the mapper is already running"
pass "the stage restores N when it found N -- the restore reads the pre-run value rather than assuming one"
ok_in_out "restored lizard mode to N" "and it says which value it put back"

# --- idempotent re-run -----------------------------------------------------
run_stage_body stage_lizard_mode "$lz_dest" "$lz_node"
ok_rc 0 "a second run of stage-lizard-mode succeeds"
ok_line "$LIZARD_DROPIN" "ExecStopPost=${SUDO_BIN} -n ${LIZARD_HELPER} on" \
  "the fallback survives a re-run rather than being replaced by something weaker"

# --- what systemd says it parsed ------------------------------------------
#
# The only check that can see the '-' question in the form that matters: a file
# on disk is not a file systemd has read, and `ignore_errors` is systemd's own
# report of whether a failure here would be swallowed.
lz_setup Y
lz_systemd_agrees
run_stage_body stage_lizard_mode "$lz_dest" "$lz_node"
ok_rc 0 "the stage accepts a drop-in and a restore unit that systemd parsed as expected"
ok_in_out "neither ignoring errors" "it says it checked what systemd parsed, not merely what was written"
ok_in_out "OnFailure=${LIZARD_RESTORE_UNIT##*/}" \
  "and that the check covered BOTH halves -- ExecStopPost= for the ordinary deaths, OnFailure= for the cgroup kill that takes ExecStopPost= with it"

lz_setup Y
lz_systemd_agrees
export FAKE_SYSTEMCTL_SHOW_ExecStopPost="{ path=${SUDO_BIN} ; argv[]=${SUDO_BIN} -n ${LIZARD_HELPER} on ; ignore_errors=yes }"
run_stage_body stage_lizard_mode "$lz_dest" "$lz_node"
ok_failed "an ExecStopPost= systemd parsed with ignore_errors=yes fails the stage"
ok_in_err "prefixed it with '-'" "the failure names the cause, not just the symptom"
[[ $(cat "$lz_node") == Y ]] ||
  fail_test "even that failure leaves the node where it was" "it reads '$(cat "$lz_node")'"
pass "a stage that fails on the parsed drop-in still leaves lizard mode as it found it"

# --- the OnFailure half, asked of systemd rather than of the file ----------
#
# Each of these is a state where the drop-in on disk is perfect and the manager
# has something else. Without OnFailure= the cgroup-kill path is uncovered, and
# nothing on disk would show it.
lz_setup Y
lz_systemd_agrees
export FAKE_SYSTEMCTL_SHOW_OnFailure=""
run_stage_body stage_lizard_mode "$lz_dest" "$lz_node"
ok_failed "an empty OnFailure= fails the stage"
ok_in_err "does NOT survive a cgroup-wide SIGKILL" \
  "the failure explains the gap it leaves rather than just naming a missing directive"

lz_setup Y
lz_systemd_agrees
export FAKE_SYSTEMCTL_SHOW_OnFailure=some-other-unit.service
run_stage_body stage_lizard_mode "$lz_dest" "$lz_node"
ok_failed "an OnFailure= naming a different unit fails the stage"
ok_in_err "which does not name ${LIZARD_RESTORE_UNIT##*/}" "the failure prints what systemd actually has"

lz_setup Y
lz_systemd_agrees
export FAKE_SYSTEMCTL_SHOW_LoadState=not-found
run_stage_body stage_lizard_mode "$lz_dest" "$lz_node"
ok_failed "an OnFailure target systemd cannot load fails the stage"
ok_in_err "would then resolve to nothing" \
  "a dangling OnFailure= is reported by systemd only when it tries to trigger it -- i.e. in the failure, which is the worst time to learn it"

lz_setup Y
lz_systemd_agrees
export FAKE_SYSTEMCTL_SHOW_ExecStart="{ path=/bin/true ; argv[]=/bin/true ; ignore_errors=no }"
run_stage_body stage_lizard_mode "$lz_dest" "$lz_node"
ok_failed "a restore unit that does not run the helper fails the stage"
ok_in_err "The unit exists and does not restore anything" "the failure names the emptiest kind of pass"

lz_setup Y
lz_systemd_agrees
export FAKE_SYSTEMCTL_SHOW_ExecStart="{ path=${SUDO_BIN} ; argv[]=${SUDO_BIN} -n ${LIZARD_HELPER} on ; ignore_errors=yes }"
run_stage_body stage_lizard_mode "$lz_dest" "$lz_node"
ok_failed "a restore unit whose ExecStart= ignores errors fails the stage"
ok_in_err "last line of defence" "the '-' prefix is refused on the restore unit too, not only on the drop-in"

lz_setup Y
lz_systemd_agrees
export FAKE_SYSTEMCTL_SHOW_ExecStopPost="{ path=/bin/true ; argv[]=/bin/true ; ignore_errors=no }"
run_stage_body stage_lizard_mode "$lz_dest" "$lz_node"
ok_failed "an ExecStopPost= that does not run the helper fails the stage"
ok_in_err "leaves lizard mode off, and the device with no input" \
  "the failure says what the missing fallback costs"

lz_systemd_silent
lz_setup Y
run_stage_body stage_lizard_mode "$lz_dest" "$lz_node"
ok_rc 0 "with no user manager to ask, the stage still completes"
ok_in_err "verified as FILE CONTENT only" \
  "it SAYS the parsed-drop-in check did not run rather than reporting a pass it did not earn"

# --- the preconditions it refuses on --------------------------------------
lz_setup Y
rm -f "$root$MAPPER_UNIT"
run_stage_body stage_lizard_mode "$lz_dest" "$lz_node"
ok_failed "no mapper unit means no drop-in -- the stage refuses"
ok_in_err "would never apply" \
  "a drop-in for a unit that does not exist is inert: installed, valid, and doing nothing"

lz_setup Y
# mkdir first: /usr/local/sbin is deliberately absent from STOCK_DIRS (the stage
# creates it), so the redirect below would fail before the case could run.
mkdir -p "$root$(dirname "$LIZARD_HELPER")"
printf '#!/bin/sh\n# somebody else owns this\n' >"$root$LIZARD_HELPER"
run_stage_body stage_lizard_mode "$lz_dest" "$lz_node"
ok_failed "a foreign file at ${LIZARD_HELPER} stops the stage"
ok_in_err "was not written by deck-session.sh" "the refusal explains whose file is in the way"

lz_setup Y
mkdir -p "$root$(dirname "$LIZARD_DROPIN")"
printf '[Service]\nExecStopPost=/bin/true\n' >"$root$LIZARD_DROPIN"
run_stage_body stage_lizard_mode "$lz_dest" "$lz_node"
ok_failed "a foreign drop-in at ${LIZARD_DROPIN} stops the stage"
ok_absent "$LIZARD_HELPER" "and it refuses BEFORE installing the helper, so a foreign fallback is never half-replaced"

lz_setup Y
printf '[Unit]\nDescription=somebody else owns this\n' >"$root$LIZARD_RESTORE_UNIT"
run_stage_body stage_lizard_mode "$lz_dest" "$lz_node"
ok_failed "a foreign unit at ${LIZARD_RESTORE_UNIT} stops the stage"
ok_in_err "was not written by deck-session.sh" \
  "the OnFailure target is checked for ownership like every other file this stage writes -- silently replacing somebody's unit is how a fallback becomes a surprise"
ok_absent "$LIZARD_HELPER" "and again it refuses before installing anything"

lz_setup Y
printf '%s ALL=(ALL) NOPASSWD: ALL\n' decktester >"$root$LIZARD_SUDOERS"
run_stage_body stage_lizard_mode "$lz_dest" "$lz_node"
ok_failed "a foreign sudoers file at ${LIZARD_SUDOERS} stops the stage"
ok_in_err "was not written by deck-session.sh" "the refusal names the file rather than overwriting a grant we did not write"

# --- the node itself is missing -------------------------------------------
lz_setup Y
rm -f "$lz_node"
run_stage_body stage_lizard_mode "$lz_dest" "$lz_node"
ok_failed "an absent sysfs node fails the stage"
ok_in_err "Refusing to install a fallback that has never been run" \
  "the files may be on disk, but a fallback nobody has exercised is not one this project ships"

# --- the sudo grant, proved rather than assumed ---------------------------
lz_setup Y
export FAKE_SUDO_LIST_DENY=deck-lizard-mode
run_stage_body stage_lizard_mode "$lz_dest" "$lz_node"
ok_failed "a grant sudo will not honour fails the stage"
ok_in_err "is a USER unit" \
  "the failure explains why it matters: ExecStartPost=/ExecStopPost= run as the desktop user, with no terminal to answer a prompt"

lz_setup Y
export FAKE_SUDO_LIST_DENY=/usr/bin/true
run_stage_body stage_lizard_mode "$lz_dest" "$lz_node"
ok_rc 0 "with no blanket grant in the way, the stage completes"
ok_in_out "may run the helper 'on' and 'off' with no password" \
  "and claims the grant is verified only when it is not standing on somebody else's blanket NOPASSWD"

unset FAKE_SUDO_LIST_DENY
lz_setup Y
run_stage_body stage_lizard_mode "$lz_dest" "$lz_node"
ok_in_err "already has broad passwordless sudo" \
  "under a blanket grant it says the check proves nothing -- the honesty check PROGRESS.md 5.17 exists for"

# --- verify_lizard_helper, against helpers that misbehave one way each -----
#
# The stage above ran the REAL helper. These drive the verifier itself, which is
# where the restore and its trap live.
reset_root
lz_probe=$(sandboxed "$work/fake-lizard-mode")

write_program "$lz_probe" >/dev/null <<'SH'
#!/usr/bin/env bash
# Correct: writes exactly what the verb means.
case ${1-} in
  on)  v=Y ;;
  off) v=N ;;
  *)   exit 2 ;;
esac
[[ ${FAKE_LZ_FAIL_ON:-} != "${1-}" ]] || exit "${FAKE_LZ_FAIL_RC:-1}"
printf '%s\n' "${FAKE_LZ_FORCE_VALUE:-$v}" >"$FAKE_LZ_NODE"
SH
export FAKE_LZ_NODE="$lz_node"

printf 'Y\n' >"$lz_node"
run_stage_body verify_lizard_helper "$lz_probe" "$lz_node"
ok_rc 0 "verify-lizard-helper passes a helper that drives the node both ways"
[[ $(cat "$lz_node") == Y ]] || fail_test "and leaves it at Y" "it reads '$(cat "$lz_node")'"
pass "verify-lizard-helper leaves the node at the value it found"

printf 'N\n' >"$lz_node"
run_stage_body verify_lizard_helper "$lz_probe" "$lz_node"
ok_rc 0 "it passes with the node starting at N too"
[[ $(cat "$lz_node") == N ]] ||
  fail_test "and restores N, not Y" "it reads '$(cat "$lz_node")'"
pass "the restore puts N back when N is what it found -- the mapper's own running state is not disturbed"

# A helper that lies: exits 0, changes nothing. This is the one the read-back
# exists for, and an exit-code-only verifier would pass it.
printf 'Y\n' >"$lz_node"
write_program "$work/fake-lizard-liar" >/dev/null <<'SH'
#!/usr/bin/env bash
exit 0
SH
run_stage_body verify_lizard_helper "$(sandboxed "$work/fake-lizard-liar")" "$lz_node"
ok_failed "a helper that exits 0 without moving the node fails verification"
ok_in_err "reported success but" \
  "the verifier re-reads the node itself rather than trusting the helper's exit code"

# A helper that writes the wrong value for the verb -- the inversion, caught
# from outside the helper.
printf 'Y\n' >"$lz_node"
export FAKE_LZ_FORCE_VALUE=Y
run_stage_body verify_lizard_helper "$lz_probe" "$lz_node"
ok_failed "a helper whose 'off' leaves the node at Y fails verification"
ok_in_err "expected 'N'" "the failure names the value it wanted, so an inverted helper cannot pass"
unset FAKE_LZ_FORCE_VALUE

# --- the trap: what happens when the check itself dies halfway -------------
#
# Between 'off' and 'on' the node is at N with no mapper running. Every `fail`
# in there is an exit, so the restore has to be a trap rather than a line at the
# bottom -- these two cases are what that trap is for.

# (a) it can restore: the node started at N, so putting it back needs 'off',
#     which this helper still does.
printf 'N\n' >"$lz_node"
export FAKE_LZ_FAIL_ON=on
run_stage_body verify_lizard_helper "$lz_probe" "$lz_node"
ok_failed "a helper that cannot turn lizard mode back on fails verification"
ok_in_out "restored lizard mode to N" \
  "and the TRAP still ran the restore -- without it the check would exit leaving a value nobody chose"
[[ $(cat "$lz_node") == N ]] ||
  fail_test "the trap left the node at the value the stage found" "it reads '$(cat "$lz_node")'"
pass "a mid-check failure still leaves the node where the stage found it"

# (b) it cannot restore: the node started at Y, restoring needs 'on', and 'on'
#     is exactly what is broken. The device is left at N with no mapper -- the
#     genuinely bad state -- so the message has to be unmissable and has to name
#     the command that fixes it.
printf 'Y\n' >"$lz_node"
run_stage_body verify_lizard_helper "$lz_probe" "$lz_node"
ok_failed "a helper broken in the ON direction fails verification"
ok_in_err "COULD NOT RESTORE" \
  "when the restore itself cannot work, that is said loudly rather than swallowed"
ok_in_err "sudo ${LIZARD_HELPER} on" \
  "and the message carries the exact command that gets input back, because by then nothing on the device can type it"

# A helper broken in the OFF direction never leaves the safe value at all.
printf 'Y\n' >"$lz_node"
export FAKE_LZ_FAIL_ON=off
run_stage_body verify_lizard_helper "$lz_probe" "$lz_node"
ok_failed "a helper broken in the OFF direction fails verification"
[[ $(cat "$lz_node") == Y ]] ||
  fail_test "and the node never left Y" "it reads '$(cat "$lz_node")'"
pass "a helper that cannot turn lizard mode off never moves the device off its safe value"
unset FAKE_LZ_FAIL_ON

# A node reading something that is neither Y nor N: stop rather than guess what
# to put back.
printf 'maybe\n' >"$lz_node"
run_stage_body verify_lizard_helper "$lz_probe" "$lz_node"
ok_failed "a node reading neither Y nor N fails before anything is written"
ok_in_err "neither Y nor N" "the refusal says why it will not guess a value to restore"
[[ $(cat "$lz_node") == maybe ]] ||
  fail_test "and nothing was written to it" "it reads '$(cat "$lz_node")'"
pass "an unrecognised current value stops the check before it changes anything"

unset FAKE_LZ_NODE

# --- GATE 6, the other half ------------------------------------------------
lz_real_after="<absent>"
[[ ! -e $LIZARD_SYSFS ]] || lz_real_after=$(cat "$LIZARD_SYSFS" 2>/dev/null || printf '<unreadable>')
[[ $lz_real_after == "$lz_real_before" ]] ||
  fail_test "§11 did not touch the real ${LIZARD_SYSFS}" \
    "it read '${lz_real_before}' before and '${lz_real_after}' after -- a seam reverted to the constant and this run changed where this machine's input comes from"
pass "the real ${LIZARD_SYSFS} is unchanged by §11 (still '${lz_real_after}')"

# ===========================================================================
# 12. stage-menu-row -- the Quickshell half of "return to Gaming Mode"
# ===========================================================================
#
# 🔴 WHY EVERY ASSERTION HERE IS ABOUT SOMETHING NOBODY WOULD SEE FAIL.
#
# Read out of the pinned runtime (git 6d7826d):
#
#   shell/plugins/menu/MenuModel.js  parseMenuJsonc:
#       try { JSON.parse(stripped) } catch (e) { return [] }
#   shell/plugins/menu/Menu.qml      the user file's FileView:
#       printErrors: false
#
# So a malformed extension file drops EVERY user row and logs nothing, in either
# place. "The row is not in the menu" and "the file has a typo in it" are the
# same observable, and there is no third one. That is docs/PROGRESS.md §5.30c.
#
# The stage therefore parses what it wrote and reads the row back out; this
# section drives that check with files that are wrong in one way each.
#
# TWO DESTINATIONS. docs/tasks/T5-fork-plan.md §3 trap (a): the ISO's `useradd`
# runs in phase 3 of 14, before configure_deck, so /etc/skel is TOO LATE for the
# only user a shipped Deck ever has. A stage that writes just skel is invisible
# to every check that reads skel. The assertions below read the USER's copy.

user_ext="$FAKE_HOME/$MENU_EXT_REL"
skel_ext=/etc/skel/$MENU_EXT_REL

# Parse a file the way Quickshell does and print one row's action, or nothing.
menu_action_in() {   # menu_action_in <path> [row-id]
  python3 - "$1" "${2:-$MENU_ROW_ID}" <<'PY'
import json, pathlib, re, sys
path = pathlib.Path(sys.argv[1])
if not path.exists():
    sys.exit(1)
stripped = re.sub(r"^\s*//[^\n]*(\n|$)", "", path.read_text(), flags=re.M)
stripped = re.sub(r",(\s*[}\]])", r"\1", stripped)
menu = json.loads(stripped)
row = menu.get(sys.argv[2])
sys.stdout.write("" if row is None else row.get("action", ""))
PY
}

reset_root
run_stage_body stage_menu_row
ok_rc 0 "stage-menu-row completes against a fake root"

# --- both destinations, and the one that is verified ----------------------
[[ -f $user_ext ]] ||
  fail_test "the row is written to the INVOKING USER's home" \
    "missing: ${user_ext}. /etc/skel is too late for the user the ISO creates (T5 §3 trap a), so a skel-only stage ships a Deck whose only user has no way back to Gaming Mode."$'\n'"stderr: $(err)"
pass "the row is written to ${MENU_EXT_REL} in the invoking user's home"

ok_file "$skel_ext" "the row is ALSO written to /etc/skel, for users created later"
ok_mode "$skel_ext" 644 "skel's copy is mode 0644"
[[ $(mode_of "$user_ext") == 644 ]] ||
  fail_test "the user's copy is mode 0644" "it is $(mode_of "$user_ext")"
pass "the user's copy is mode 0644"

# install -D has to create .config/omarchy/extensions itself: none of it is in
# STOCK_DIRS, and neither is /etc/skel.
ok_called "install -D -m 0644" "the write uses 'install -D', which creates the extensions directory it lands in"

# 🔴 THE TRAP-(a) ASSERTION. The stage prints the path it verified; it must be
# the user's file. A stage that verified skel's copy would pass every other
# assertion in this section while shipping a broken Deck.
ok_in_out "verified: ${user_ext}" \
  "the stage's own verification reads the USER's copy, not /etc/skel's -- T5 §3 trap (a)"

# --- what the file actually says, parsed rather than grepped --------------
got=$(menu_action_in "$user_ext") ||
  fail_test "the user's copy parses as Quickshell parses it" \
    "it did not parse at all, which on the device means every row in it silently disappears"$'\n'"$(cat "$user_ext")"
[[ $got == "$RETURN_ACTION" ]] ||
  fail_test "the '${MENU_ROW_ID}' row runs the same command as the .desktop entry" \
    "it runs '${got}', expected '${RETURN_ACTION}'"$'\n'"$(cat "$user_ext")"
pass "the user's copy parses and its '${MENU_ROW_ID}' row runs '${RETURN_ACTION}'"

got=$(menu_action_in "$root$skel_ext") ||
  fail_test "skel's copy parses too" "$(cat "$root$skel_ext")"
[[ $got == "$RETURN_ACTION" ]] ||
  fail_test "skel's copy carries the same row" "it runs '${got}'"
pass "skel's copy parses and carries the same row"

# --- the real parser, when it is available --------------------------------
#
# Everything above uses this suite's own mirror of MenuModel.js:stripJsonc. That
# mirror could be wrong in the same direction as the code under test. When the
# pinned runtime checkout and a JS engine are both present, ask the ACTUAL
# parser instead -- MenuModel.js has a CommonJS export at its foot.
runtime_src=${OMARCHY_DECK_RUNTIME_SRC:-$HOME/.cache/omarchy-deck/iso-build/runtime-src}
menu_model="$runtime_src/shell/plugins/menu/MenuModel.js"
if command -v node >/dev/null 2>&1 && [[ -f $menu_model ]]; then
  node -e '
    const fs = require("fs");
    const M = require(process.argv[1]);
    const user = M.parseMenuJsonc(fs.readFileSync(process.argv[2], "utf8"));
    const def  = M.parseMenuJsonc(fs.readFileSync(process.argv[3], "utf8"));
    const merged = M.mergeMenuSources(def, user);
    const row = merged.items[process.argv[4]];
    if (!row) { console.error("the real parser found no row; user rows parsed: " + user.length); process.exit(1); }
    if (row.action !== process.argv[5]) { console.error("action is " + JSON.stringify(row.action)); process.exit(1); }
    // 🔴 THE PARENT IS DERIVED FROM THE DOTTED ID, NOT RESTATED. MENU_ROW_ID
    // moved from `gaming` (root) to `system.gaming` on 2026-08-16, because a
    // root row shows up in BOTH the apps menu and the Omarchy menu and the
    // operator saw "Gaming Mode" in both. Asserting a hardcoded "root" here
    // would have to be edited by hand every time the row moves -- and a test
    // that must be edited to follow a decision is a test that will one day be
    // edited to follow a mistake.
    const dotted = process.argv[4];
    const wantParent = dotted.includes(".") ? dotted.slice(0, dotted.lastIndexOf(".")) : "root";
    if (row.parent !== wantParent) { console.error("parent is " + JSON.stringify(row.parent) + ", expected " + JSON.stringify(wantParent)); process.exit(1); }
    if (row.kind !== "action") { console.error("kind is " + JSON.stringify(row.kind)); process.exit(1); }
    // The parent must be one Omarchy actually declares, or the row is orphaned
    // and never drawn -- which would look exactly like "the stage did nothing".
    if (wantParent !== "root" && !def.some(r => r.id === wantParent)) {
      console.error("no such parent in Omarchy\u0027s own menu: " + wantParent); process.exit(1);
    }
    const siblings = merged.itemOrder.filter(id => merged.items[id].parent === wantParent);
    if (siblings[siblings.length - 1] !== dotted) { console.error("sibling order: " + siblings.join(" ")); process.exit(1); }
  ' "$menu_model" "$user_ext" "$runtime_src/default/omarchy/omarchy-menu.jsonc" \
    "$MENU_ROW_ID" "$RETURN_ACTION" 2>"$work/node.err" ||
    fail_test "Omarchy's OWN MenuModel.js parses the installed file and finds the row under its declared parent" \
      "$(cat "$work/node.err")"$'\n'"$(cat "$user_ext")"
  pass "Omarchy's own MenuModel.js parses the installed file: '${MENU_ROW_ID}' is an ACTION row under a parent Omarchy declares, last in that parent's order"
else
  note "node and/or the pinned runtime checkout are absent, so the row was checked against this suite's mirror of stripJsonc and not against Omarchy's real parser (set OMARCHY_DECK_RUNTIME_SRC to enable it)"
fi

# --- idempotency (CLAUDE.md): a re-run must not duplicate or corrupt -------
cp "$user_ext" "$work/menu-first-run"
run_stage_body stage_menu_row
ok_rc 0 "a second run succeeds"
diff -q "$work/menu-first-run" "$user_ext" >/dev/null ||
  fail_test "a re-run leaves the file byte-for-byte identical" \
    "$(diff "$work/menu-first-run" "$user_ext" || true)"
pass "a re-run rewrites the marked block in place -- the file is byte-for-byte identical"
[[ $(grep -cxF -- "$MENU_ROW_BEGIN" "$user_ext") -eq 1 ]] ||
  fail_test "there is exactly one copy of our block after two runs" \
    "found $(grep -cxF -- "$MENU_ROW_BEGIN" "$user_ext")"
pass "two runs leave exactly one copy of the block, not two rows with the same id"

# --- a user who already has their own rows --------------------------------
#
# This file is a DOCUMENTED extension point, so it usually exists before we get
# there -- on a stock Omarchy it is the shipped template, all comments. Nothing
# outside our two markers may change, comments included: assert_ours_or_absent
# cannot be used here (it would refuse on every stock install), so the guarantee
# has to be that the splice is non-destructive.
reset_root
mkdir -p "$(dirname "$user_ext")"
cat >"$user_ext" <<'JSONC'
{
  // My own rows. This comment must survive.
  "personal": {"icon":"x","label":"Personal"},
  "personal.notes": {"label":"Notes","action":"true"},
}
JSONC
cp "$user_ext" "$work/menu-user-before"
run_stage_body stage_menu_row
ok_rc 0 "the stage runs against a file the user already owns"

while IFS= read -r line; do
  grep -qxF -- "$line" "$user_ext" ||
    fail_test "every line of the user's own file survives the splice" \
      "this line is gone: ${line}"$'\n'"$(cat "$user_ext")"
done <"$work/menu-user-before"
pass "every line the user wrote -- their comment included -- survives the splice"

got=$(menu_action_in "$user_ext" personal.notes)
[[ $got == "true" ]] ||
  fail_test "the user's own rows still parse after ours is spliced in" \
    "personal.notes runs '${got}'"$'\n'"$(cat "$user_ext")"
pass "the user's own rows still parse alongside ours (personal.notes kept its action)"
got=$(menu_action_in "$user_ext")
[[ $got == "$RETURN_ACTION" ]] ||
  fail_test "and our row is there too" "it runs '${got}'"
pass "and our row is in the same file, with the right action"

# --- a file that was ALREADY broken ---------------------------------------
#
# Quickshell is silently discarding every row in it before we arrive. The stage
# must say so, and must not write over it.
reset_root
mkdir -p "$(dirname "$user_ext")"
printf '{ "broken": }\n' >"$user_ext"
run_stage_body stage_menu_row
ok_failed "a user extension file that does not parse stops the stage"
ok_in_err "not valid JSONC" "the refusal names the parse failure"
ok_in_err "silently discarded" \
  "and explains that Quickshell is already dropping every row in that file, which is the thing nobody would otherwise find out"
[[ $(cat "$user_ext") == '{ "broken": }' ]] ||
  fail_test "the broken file is left exactly as it was" \
    "it now reads: $(cat "$user_ext")"
pass "the broken file is left byte-for-byte alone rather than being repaired by guesswork"

# --- our own block, half-removed by hand ----------------------------------
reset_root
mkdir -p "$(dirname "$user_ext")"
{ printf '{\n'; printf '%s\n' "$MENU_ROW_BEGIN"; printf '"%s": {"action":"x"},\n}\n' "$MENU_ROW_ID"; } >"$user_ext"
run_stage_body stage_menu_row
ok_failed "our start marker with no end marker stops the stage"
ok_in_err "no end marker" "the refusal says it will not guess where the old block ended"

# --- verify_menu_row: the guards, one broken at a time --------------------
#
# These drive the verifier directly, because the faults they represent cannot be
# produced by the stage: they are what a FUTURE change to the writer would
# produce. Exit codes alone would not distinguish them, so each pins its message.
bad="$work/menu-bad.jsonc"

printf '{"%s": {"label":"x","action":"/usr/bin/steamos-session-select desktop"}}\n' \
  "$MENU_ROW_ID" >"$bad"
run_stage_body verify_menu_row "$(sandboxed "$bad")"
ok_failed "a file that PARSES but whose row runs the wrong command fails verification"
ok_in_err "not '${RETURN_ACTION}'" \
  "the failure names the command it wanted -- a row that switches to the desktop is the worst outcome here: it is in the menu, it is pressable, and it does not return to Gaming Mode"

printf '{"apps": {"label":"x","action":"true"}}\n' >"$bad"
run_stage_body verify_menu_row "$(sandboxed "$bad")"
ok_failed "a file that parses with no '${MENU_ROW_ID}' row at all fails verification"
ok_in_err "carries no '${MENU_ROW_ID}' row" "the failure says which id was missing"

printf '{"%s": {"action": }}\n' "$MENU_ROW_ID" >"$bad"
run_stage_body verify_menu_row "$(sandboxed "$bad")"
ok_failed "a file that does not parse fails verification"
ok_in_err "does not parse as JSONC" "the failure says the file is unparseable rather than reporting a missing row"

rm -f "$bad"
run_stage_body verify_menu_row "$(sandboxed "$bad")"
ok_failed "a file that is not there at all fails verification"
ok_in_err "does not exist" "an absent file is reported as absent, not as a parse error"

# ===========================================================================
# 13. stage-boot-default-gaming -- a reboot always lands in Gaming Mode
# ===========================================================================
#
# 🔴 ORDERING IS THE ENTIRE UNIT. sddm reads /etc/sddm.conf.d when it starts, so
# a re-assert that runs afterwards writes the file, succeeds, logs success, and
# changes nothing until the boot after next. There is no error, no failed unit
# and no journal entry that distinguishes it from working. Determined from the
# units on this machine rather than from habit:
#
#   /usr/lib/systemd/system/sddm.service  [Install] Alias=display-manager.service
#   /etc/systemd/system/display-manager.service -> ...sddm.service
#   graphical.target                      Wants=/After= display-manager.service
#
# so graphical.target pulls the display manager in, and being WantedBy that
# target plus Before= the display manager puts the re-assert first inside the
# one transaction.

# systemd's answers, DERIVED FROM THE RENDERED UNIT rather than hardcoded. That
# is what makes the ordering assertions mutation-sensitive: flip Before= to
# After= in src/ and this oracle reports it, exactly as systemd would.
boot_oracle_from_render() {
  local before="" after="" line
  while IFS= read -r line; do
    case $line in
      Before=*) before="${before:+${before} }${line#Before=}" ;;
      After=*)  after="${after:+${after} }${line#After=}" ;;
    esac
  done < <(render_boot_default_unit)
  # The two systemd adds itself to any unit with default dependencies, so the
  # oracle is not accidentally "only what we wrote".
  export FAKE_SYSTEMCTL_SHOW_Before="${before:+${before} }shutdown.target"
  export FAKE_SYSTEMCTL_SHOW_After="${after:+${after} }basic.target sysinit.target"
}

# --- the gate: the writer this unit schedules must already exist ----------
reset_root
boot_oracle_from_render
run_stage_body stage_boot_default_gaming
ok_failed "the stage refuses to run before stage-session-select has installed ${SELECT_BIN}"
ok_in_err "stage-session-select" \
  "the refusal names the stage to run first -- the unit would otherwise fail at every boot with a 203/EXEC nothing connects to this"
ok_absent /etc/systemd/system/deck-boot-default-gaming.service \
  "and nothing is installed when the gate refuses"

# --- the happy path -------------------------------------------------------
reset_root
printf '#!/bin/sh\nexit 0\n' >"$root$SELECT_BIN"; chmod +x "$root$SELECT_BIN"
boot_oracle_from_render
run_stage_body stage_boot_default_gaming
ok_rc 0 "stage-boot-default-gaming completes"
ok_file /etc/systemd/system/deck-boot-default-gaming.service "it installs ${BOOT_DEFAULT_UNIT}"
ok_mode /etc/systemd/system/deck-boot-default-gaming.service 644 "the unit is mode 0644"
ok_line /etc/systemd/system/deck-boot-default-gaming.service "$INSTALL_MARKER" \
  "the unit carries the install marker, so a re-run recognises its own file"

ok_line /etc/systemd/system/deck-boot-default-gaming.service \
  "Before=${BOOT_DEFAULT_BEFORE_ALIAS}" \
  "it is ordered before display-manager.service"
ok_line /etc/systemd/system/deck-boot-default-gaming.service \
  "Before=${BOOT_DEFAULT_BEFORE_REAL}" \
  "and before sddm.service under its real name -- the alias only exists once sddm has been enabled"
ok_line /etc/systemd/system/deck-boot-default-gaming.service \
  "ExecStart=${SELECT_BIN} gamescope --no-restart" \
  "it re-runs the EXISTING writer rather than reimplementing the drop-in write"
ok_line /etc/systemd/system/deck-boot-default-gaming.service \
  "ConditionPathExists=!${BOOT_DEFAULT_OVERRIDE}" \
  "the escape hatch is one 'touch' away, with no editor and no unit file"
ok_line /etc/systemd/system/deck-boot-default-gaming.service \
  "WantedBy=graphical.target" \
  "it is wanted by the target that pulls the display manager in, not by sddm.service (which a session SWITCH restarts)"

# --- the escape hatch has to be usable from a TTY -------------------------
[[ -d "$root$(dirname "$BOOT_DEFAULT_OVERRIDE")" ]] ||
  fail_test "the stage creates $(dirname "$BOOT_DEFAULT_OVERRIDE")" \
    "the escape hatch is 'sudo touch ${BOOT_DEFAULT_OVERRIDE}' at a TTY on a device with no desktop; touch does not create directories"
pass "the stage creates $(dirname "$BOOT_DEFAULT_OVERRIDE") so the escape hatch is a single 'touch'"
ok_absent "$BOOT_DEFAULT_OVERRIDE" \
  "creating that directory does NOT arm the override -- the unit checks for the file"

ok_in_out "sudo touch ${BOOT_DEFAULT_OVERRIDE}" \
  "the stage PRINTS the escape hatch, because the operator has one device and this unit re-asserts at every boot"
ok_in_out "systemctl disable ${BOOT_DEFAULT_UNIT_NAME}" \
  "and the permanent form of it"
ok_in_out "Ctrl+Alt+F2" "and how to reach a terminal to type either"

# --- the unit is loaded and enabled, in that order ------------------------
ok_called "systemctl daemon-reload" "systemd is told to re-read the unit"
ok_called "systemctl enable ${BOOT_DEFAULT_UNIT_NAME}" \
  "and the unit is ENABLED -- an installed-but-not-enabled unit never runs and nothing reports that"
ok_before "daemon-reload" "enable ${BOOT_DEFAULT_UNIT_NAME}" \
  "the reload happens before the enable, so systemd enables the unit it just read"
ok_before "install -D -m 0644" "daemon-reload" \
  "and the unit is on disk before the reload"

# --- idempotency ----------------------------------------------------------
run_stage_body stage_boot_default_gaming
ok_rc 0 "a second run succeeds -- assert_ours_or_absent recognises the unit as ours"

# --- somebody else's unit at that path ------------------------------------
reset_root
printf '#!/bin/sh\nexit 0\n' >"$root$SELECT_BIN"; chmod +x "$root$SELECT_BIN"
printf '[Unit]\nDescription=Somebody else\n' \
  >"$root/etc/systemd/system/deck-boot-default-gaming.service"
run_stage_body stage_boot_default_gaming
ok_failed "a foreign unit at ${BOOT_DEFAULT_UNIT} stops the stage"
grep -qF "Somebody else" "$root/etc/systemd/system/deck-boot-default-gaming.service" ||
  fail_test "the foreign unit is left exactly as it was" "it was overwritten anyway"
pass "the foreign unit is left byte-for-byte alone"

# --- verify_boot_default_ordering: the answers that must FAIL -------------
#
# 🔴 These are the section's reason for existing. Every one of them describes a
# unit that installs cleanly, starts cleanly and does nothing -- so an
# exit-code-only assertion on the stage would pass with any of them shipped.
# Each pins the message, because they all share exit 1.

export FAKE_SYSTEMCTL_SHOW_Before="shutdown.target"
export FAKE_SYSTEMCTL_SHOW_After="basic.target sysinit.target"
run_stage_body verify_boot_default_ordering "$BOOT_DEFAULT_UNIT_NAME"
ok_failed "a unit systemd orders before nothing relevant fails verification"
ok_in_err "names neither" \
  "the failure says the ordering does not reach the display manager at all"

# The mutation this whole section exists to catch: Before= written as After=.
export FAKE_SYSTEMCTL_SHOW_Before="shutdown.target"
export FAKE_SYSTEMCTL_SHOW_After="basic.target ${BOOT_DEFAULT_BEFORE_ALIAS}"
run_stage_body verify_boot_default_ordering "$BOOT_DEFAULT_UNIT_NAME"
ok_failed "a unit ordered AFTER the display manager fails verification"
ok_in_err "ordered AFTER the display manager" \
  "and says so in those words -- it would write the config successfully, log success, and change nothing until the boot after next"

# Ordered after sddm under its real name rather than the alias: the same fault
# wearing the other name.
export FAKE_SYSTEMCTL_SHOW_Before="shutdown.target ${BOOT_DEFAULT_BEFORE_ALIAS}"
export FAKE_SYSTEMCTL_SHOW_After="basic.target ${BOOT_DEFAULT_BEFORE_REAL}"
run_stage_body verify_boot_default_ordering "$BOOT_DEFAULT_UNIT_NAME"
ok_failed "ordering after sddm.service fails even when the alias is named in Before="
ok_in_err "ordered AFTER the display manager" \
  "both names are checked, because display-manager.service and sddm.service are the same unit"

export FAKE_SYSTEMCTL_SHOW_Before=""
export FAKE_SYSTEMCTL_SHOW_After=""
run_stage_body verify_boot_default_ordering "$BOOT_DEFAULT_UNIT_NAME"
ok_failed "systemd reporting NO ordering at all fails verification"
ok_in_err "NO Before= ordering" \
  "an empty answer means the unit did not load or its directives were dropped -- not that everything is fine"

# And the shipped unit's own ordering passes, against an oracle derived from it.
boot_oracle_from_render
run_stage_body verify_boot_default_ordering "$BOOT_DEFAULT_UNIT_NAME"
ok_rc 0 "the ordering the shipped unit actually declares passes verification"
ok_in_out "orders ${BOOT_DEFAULT_UNIT_NAME} before the display manager" \
  "and says which ordering it verified, rather than only that it passed"

unset FAKE_SYSTEMCTL_SHOW_Before FAKE_SYSTEMCTL_SHOW_After

# ===========================================================================
# 14. stage-power-button -- one press suspends, and the ways that go wrong
# ===========================================================================
#
# The stage writes two files: a udev rule that drops the ACPI power-button
# nodes from the `power-switch` tag, and a logind drop-in that sets
# HandlePowerKey=suspend. The generated TEXT of both is pinned in
# test/unit/test-deck-session.sh §9d. This section runs the stage body: its
# three verifiers, the order it writes in, its refusals, and what it prints.
#
# 🔴 EVERY FAILURE THIS SECTION PINS IS SILENT ON THE DEVICE. There is no
# error message on a Deck for "the rule matched nothing", "the drop-in was
# overridden", or "the handler was armed before the duplicate was removed" --
# there is only a power button that suspends twice, or not at all, on a
# handheld whose other escape is a ten-second hold. Exit codes alone do not
# distinguish them, so every negative case below pins its message too.
#
# The whole stage is reachable through $SUDO and nothing else -- including its
# READS, which is deliberate in src/ (see the section header there). That is
# what lets this run with no seams, no root, no Deck, and no udev.

# --- the fixture -----------------------------------------------------------

# One input node, as udev would describe it.
power_node() {   # power_node <node> <id-path> [tagged|untagged]
  local n=$1 id=$2 tag=${3:-tagged}
  : >"$root/dev/input/$n"
  {
    printf 'DEVNAME=/dev/input/%s\n' "$n"
    printf 'ID_PATH=%s\n' "$id"
    printf 'ID_INPUT_KEY=1\n'
    if [[ $tag == tagged ]]; then
      printf 'TAGS=:%s:seat:\n' "$POWER_UDEV_TAG"
    else
      printf 'TAGS=:seat:\n'
    fi
  } >"$FAKE_UDEV_DB/$n"
}

# The Deck as measured on 2026-08-12, reproduced under the fake root:
# five tagged input nodes, upstream's tagger rule, Omarchy's package-owned
# drop-in, a Galileo DMI, and omarchy-sleep-lock masked.
#
# NOTE what is deliberately NOT created: /etc/udev/rules.d. It is not in
# STOCK_DIRS either, so the stage has to create it itself -- and if it ever
# stops doing so, the install fails here rather than on the Deck.
power_reset() {
  reset_root
  rm -rf "$FAKE_UDEV_DB"
  mkdir -p "$FAKE_UDEV_DB" "$root/dev/input" "$root/sys/class/dmi/id" \
           "$root/usr/lib/udev/rules.d" "$root/etc/systemd/logind.conf.d" \
           "$root/usr/lib/systemd/user"

  # Upstream's rule -- the one that ADDS the tag, and the one ours must be
  # read after. Quoted from stock systemd's 70-power-switch.rules.
  printf '%s\n' \
    'SUBSYSTEM=="input", KERNEL=="event*", ENV{ID_INPUT_KEY}=="1", TAG+="power-switch"' \
    >"$root/usr/lib/udev/rules.d/${POWER_UDEV_TAGGER}"

  # Omarchy's, which ours must beat without editing: the omarchy package owns
  # this path and pacman --overwrite restores it on every upgrade.
  printf '[Login]\nHandlePowerKey=ignore\n' \
    >"$root/etc/systemd/logind.conf.d/10-ignore-power-button.conf"

  printf '%s\n' "$POWER_MODEL" >"$root/sys/class/dmi/id/product_name"

  printf '[Unit]\nDescription=lock on sleep\n' >"$root/usr/lib/systemd/user/${SLEEP_LOCK_UNIT}"
  ln -sfn /dev/null "$root$SLEEP_LOCK_GLOBAL_MASK"

  power_node event0 acpi-PNP0C0C:00                # ACPI, silent, tagged
  power_node event1 acpi-PNP0C0D:00                # the Lid Switch
  power_node event2 acpi-LNXPWRBN:00               # the measured duplicate
  power_node event4 platform-i8042-serio-0         # the real key -- KEPT
  power_node event7 'usb-0000:04:00.3-3/input0'    # the controller
}

# `sudo install` of a particular destination, by line number in the call log.
# The bare path is not enough: assert_ours_or_absent probes BOTH destinations
# before either is written, in the same order, so an ok_before on the paths
# alone would pass even with the two writes swapped -- which is the mutation
# that matters most here.
power_install_line() {   # power_install_line <destination>
  grep -n '^sudo install ' "$calls" | grep -F -- "$1" | head -1 | cut -d: -f1
}

# --- the happy path --------------------------------------------------------

power_reset
run_stage_body stage_power_button "$hypr_dead"
ok_rc 0 "stage-power-button installs cleanly on a Deck that enumerates its power button the way the measurement recorded"

ok_file "$POWER_UDEV_RULE" "the udev rule is installed"
ok_mode "$POWER_UDEV_RULE" 644 "the udev rule is 0644 -- udev must be able to read it"
ok_file "$POWER_LOGIND_DROPIN" "the logind drop-in is installed"
ok_mode "$POWER_LOGIND_DROPIN" 644 "the logind drop-in is 0644"
pass "/etc/udev/rules.d did not exist in the fixture, so the stage created it itself"

ok_line "$POWER_UDEV_RULE" 'ENV{ID_PATH}=="acpi-LNXPWRBN:00", TAG-="power-switch"' \
  "the installed rule untags the ACPI node that was MEASURED firing 131-198 ms after every press"
ok_line "$POWER_UDEV_RULE" 'ENV{ID_PATH}=="acpi-PNP0C0C:00", TAG-="power-switch"' \
  "and the silent one too -- it advertises KEY_POWER and carries the tag, so it is a second source waiting for a firmware change"
ok_line "$POWER_LOGIND_DROPIN" "HandlePowerKey=suspend" \
  "the installed drop-in sets HandlePowerKey=suspend as an exact line -- the setting DEFAULTS to poweroff, so it can never be left implicit"
ok_line "$POWER_LOGIND_DROPIN" "HandlePowerKeyLongPress=ignore" \
  "and pins the long press to 'ignore', because no threshold in this project has been read from source"

# 🔴 THE ORDERING MUTATION. The udev rule (remove the duplicate) must be on
# disk before the logind drop-in (arm the handler). A run that dies between
# them then leaves a machine with one fewer redundant tag and today's
# behaviour otherwise. The reverse order leaves the handler armed with the
# duplicate live -- two suspend requests ~198 ms apart, the second landing at
# or just after resume, on a device whose only other escape is a ten-second
# hold.
power_rule_at=$(power_install_line "$POWER_UDEV_RULE")
power_conf_at=$(power_install_line "$POWER_LOGIND_DROPIN")
[[ -n $power_rule_at && -n $power_conf_at ]] ||
  fail_test "both files are installed with 'install'" \
    "rule at ${power_rule_at:-none}, drop-in at ${power_conf_at:-none}"$'\n'"$(cat "$calls")"
[[ $power_rule_at -lt $power_conf_at ]] ||
  fail_test "the udev rule is written BEFORE the logind drop-in" \
    "rule was install call ${power_rule_at}, drop-in was ${power_conf_at}. Arming HandlePowerKey=suspend while the duplicate KEY_POWER source is still tagged is the re-suspend loop this whole stage is shaped to avoid, and a run that dies between the two writes would leave exactly that."$'\n'"$(cat "$calls")"
pass "the duplicate is removed BEFORE the handler is armed -- a half-finished run cannot leave a Deck that re-suspends on resume"

# --- it changes nothing until a reboot, and must not try to ---------------
#
# Removing a udev tag does not reliably un-register a device logind has
# already enumerated: the monitor is filtered ON that tag, so the change event
# announcing the removal is the very event the filter drops. A live reload
# could therefore arm the handler with the duplicate still inside logind.
! grep -qE 'udevadm (control|trigger|settle)' "$calls" ||
  fail_test "the stage reloads no udev rules and triggers no uevents" \
    "a live reload can leave logind holding a device whose tag was removed, which is the one state this stage is built to avoid."$'\n'"$(cat "$calls")"
pass "the stage runs no 'udevadm control', 'udevadm trigger' or 'udevadm settle' -- only read-only 'udevadm info'"

! grep -q '^systemctl ' "$calls" ||
  fail_test "the stage runs no systemctl at all" \
    "restarting systemd-logind to apply this would end the operator's session from a stage they ran over SSH; the reboot is the applied step, and it is theirs to choose."$'\n'"$(cat "$calls")"
pass "the stage runs no systemctl -- it writes two files and nothing else"

ok_in_out "NOTHING HAS CHANGED YET" \
  "the stage says out loud that its files are inert until a reboot, rather than letting the operator test a change that has not been applied"
ok_in_out "sudo reboot" "and gives the command that applies them"

# --- the undo, and its order ----------------------------------------------
ok_in_out "sudo rm -f ${POWER_LOGIND_DROPIN}" "the stage prints how to undo the handler"
ok_in_out "sudo rm -f ${POWER_UDEV_RULE}" "and how to undo the udev rule"
power_undo_conf=$(grep -nF -- "rm -f ${POWER_LOGIND_DROPIN}" "$work/stage.out" | head -1 | cut -d: -f1)
power_undo_rule=$(grep -nF -- "rm -f ${POWER_UDEV_RULE}" "$work/stage.out" | head -1 | cut -d: -f1)
[[ $power_undo_conf -lt $power_undo_rule ]] ||
  fail_test "the printed undo removes the handler BEFORE it restores the tags" \
    "the reverse order puts the duplicate KEY_POWER press back underneath a live HandlePowerKey=suspend. Got the drop-in at output line ${power_undo_conf} and the rule at ${power_undo_rule}."$'\n'"$(out)"
pass "the printed undo is ordered handler-first, which is the only order that is safe at every point in between"

# --- the THIRD artefact: Omarchy's own power-key bind ----------------------
#
# 🔴 THE DEFECT THIS SECTION EXISTS FOR, and its history is a warning about
# assertions that pin the wrong thing.
#
# Omarchy binds XF86PowerOff to `omarchy-menu toggle system`. Removing the udev
# power-switch tag does NOT touch that: the tag is what LOGIND filters on, and
# libinput hands the compositor every device on the seat regardless. So one
# physical press stays TWO XF86PowerOff events at the compositor -- the real key
# on platform-i8042-serio-0, then the ACPI notify -- and `toggle` opens the menu
# and closes it again.
#
# MEASURED on the operator's Deck 2026-08-16 by replaying both sources through
# uinput 165 ms apart with logind's handle-power-key blocked, so only the
# compositor could answer: openlayer>>omarchy-menu at 17:00:18.379,
# closelayer>>omarchy-menu at 17:00:18.493. 114 ms of System menu per press.
# A single synthetic event in the same harness left the menu OPEN instead,
# which is the same mechanism seen from the other side.
#
# This block used to assert the stage PRINTED `hl.unbind("XF86PowerOff")` as an
# optional cosmetic fix. The advice was right and printing it was not the fix:
# the flash shipped in every image for as long as it stayed a suggestion. The
# stage now installs it, so the assertion asserts the file.
power_bindings_lua="${FAKE_HOME}/${HYPR_BINDINGS_LUA_REL}"
[[ -f $power_bindings_lua ]] ||
  fail_test "the stage writes ${HYPR_BINDINGS_LUA_REL}" \
    "missing: ${power_bindings_lua}"$'\n'"stderr: $(err)"
pass "the stage installs the unbind into the desktop user's ${HYPR_BINDINGS_LUA_REL}"

grep -qxF -- "hl.unbind(\"${POWER_MENU_BIND_KEY}\")" "$power_bindings_lua" ||
  fail_test "the installed block calls hl.unbind on ${POWER_MENU_BIND_KEY}" \
    "a block that names the key without unbinding it is a comment. File:"$'\n'"$(cat "$power_bindings_lua")"
pass "the installed block unbinds ${POWER_MENU_BIND_KEY}, the key Omarchy binds to its System menu"

for power_marker in "$POWER_BIND_RULE_BEGIN" "$POWER_BIND_RULE_END"; do
  grep -qxF -- "$power_marker" "$power_bindings_lua" ||
    fail_test "the installed file carries the marker line '${power_marker}'" \
      "without both markers a re-run appends a second copy instead of replacing its own. File:"$'\n'"$(cat "$power_bindings_lua")"
done
pass "the block is delimited at both ends, so a re-run replaces it instead of appending"

grep -qxF "${POWER_BIND_SENTINEL} = true" "$power_bindings_lua" ||
  fail_test "the installed block sets ${POWER_BIND_SENTINEL}, the global the live check asserts on" \
    "without it a discarded bindings.lua is indistinguishable from a loaded one. File:"$'\n'"$(cat "$power_bindings_lua")"
pass "the block's last line sets ${POWER_BIND_SENTINEL}, so a compositor that discarded the file can be told apart from one that loaded it"

# 🔴 A rival bind is NOT an acceptable substitute for the unbind: two binds on
# one key both fire, so binding it to something inert would replace one handler
# with two. Only removal removes the flash.
! grep -qE '^[[:space:]]*(hl\.bind|o\.bind)\(' "$power_bindings_lua" ||
  fail_test "the block binds nothing of its own to ${POWER_MENU_BIND_KEY}" \
    "Hyprland fires every bind on a key; a rival bind adds a handler instead of removing one. File:"$'\n'"$(cat "$power_bindings_lua")"
pass "the block only unbinds -- it does not add a rival bind, which would leave two handlers on one key"

ok_in_out "NO LONGER FLASHES THE SYSTEM MENU" \
  "the stage reports the flash as fixed, and says by what mechanism, instead of offering the fix as advice"

# The user's own bindings survive. This file is where Omarchy tells people to
# put personal keybindings, so a rewrite rather than a splice would silently
# delete them.
power_reset
mkdir -p "$(dirname "$power_bindings_lua")"
printf '%s\n' 'o.bind("SUPER + SHIFT + R", "SSH", "alacritty -e ssh your-server")' \
  >"$power_bindings_lua"
run_stage_body stage_power_button "$hypr_dead"
ok_rc 0 "the stage completes against a bindings.lua that already has the user's own bindings in it"
grep -qF 'alacritty -e ssh your-server' "$power_bindings_lua" ||
  fail_test "the user's own bindings survive the splice" \
    "this is the file Omarchy hands users for personal keybindings; losing them is the worst outcome here. File:"$'\n'"$(cat "$power_bindings_lua")"
pass "the user's own bindings in ${HYPR_BINDINGS_LUA_REL} survive byte-for-byte"

# A half-removed previous block cannot be spliced safely -- guessing where it
# ended would eat whatever followed.
power_reset
mkdir -p "$(dirname "$power_bindings_lua")"
printf '%s\nhl.unbind("X")\n' "$POWER_BIND_RULE_BEGIN" >"$power_bindings_lua"
run_stage_body stage_power_button "$hypr_dead"
ok_failed "a start marker with no end marker stops the stage"
ok_in_err "could not splice" "the failure names the splice rather than reporting a generic write error"

# No compositor: the unbind is on disk and NOT observed working. Saying so is
# the requirement -- a rule nobody has seen work is not a rule that works.
power_reset
run_stage_body stage_power_button "$hypr_dead"
ok_in_err "has NOT been observed working" \
  "with no live compositor the stage says the unbind is unverified instead of reporting success"

# --- the live branch, against the stub compositor --------------------------
power_hypr_live="$work/hypr-runtime-live-power"
rm -rf "$power_hypr_live"; mkdir -p "$power_hypr_live/hypr/deadbeef_1"
python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' \
  "$power_hypr_live/hypr/deadbeef_1/.socket.sock" ||
  fail_test "the suite can create a fake compositor socket" "python3 could not bind an AF_UNIX socket"

power_reset
run_stage_body stage_power_button "$power_hypr_live"
ok_rc 0 "with a live compositor and nothing bound to ${POWER_MENU_BIND_KEY}, the stage completes"
ok_in_out "the whole unbind block executed" "the sentinel assertion is reported as a verification, not assumed"
ok_in_out "binds ${POWER_MENU_BIND_KEY}" "and the keybinding list is read back, which is the observable the flash comes from"
ok_called "hyprctl reload config-only" "it reloads the config before reading the bindings back"
ok_before "hyprctl reload config-only" "hyprctl -j binds" "the reload happens BEFORE the keybinding list is read"

# The sentinel gone: Hyprland discarded bindings.lua. A failure, not a warning.
export FAKE_HYPR_POWER_SENTINEL=absent
power_reset
run_stage_body stage_power_button "$power_hypr_live"
ok_failed "a compositor without the sentinel fails the stage"
ok_in_err "did not run to the end" "the failure says the BLOCK did not complete, which is what a discarded bindings.lua looks like"
unset FAKE_HYPR_POWER_SENTINEL

# 🔴 The sentinel set and the key still bound. This is the failure a sentinel
# alone cannot see -- our block ran and something still answers the key -- and
# it is exactly the state the operator reported, so it must fail loudly.
export FAKE_HYPR_BINDS='[{"modmask":0,"key":"XF86PowerOff","dispatcher":"__lua"}]'
power_reset
run_stage_body stage_power_button "$power_hypr_live"
ok_failed "a compositor that still binds ${POWER_MENU_BIND_KEY} fails the stage"
ok_in_err "still name ${POWER_MENU_BIND_KEY}" \
  "the failure reports that the key is STILL bound, rather than trusting the sentinel and calling it done"
ok_in_err "will still flash" "and names the symptom the operator would see"
export FAKE_HYPR_BINDS="$HYPR_BINDS_GOOD"

# An empty bind list is a list worth drawing no conclusion from -- "no binds at
# all" must not read as "our key is gone".
export FAKE_HYPR_BINDS='[]'
power_reset
run_stage_body stage_power_button "$power_hypr_live"
ok_failed "an empty keybinding list fails rather than passing as 'nothing binds our key'"
ok_in_err "no keybindings at all" "and says the list was empty, rather than reporting the unbind as verified"
export FAKE_HYPR_BINDS="$HYPR_BINDS_GOOD"

# --- idempotency -----------------------------------------------------------
power_reset
run_stage_body stage_power_button "$hypr_dead"
ok_rc 0 "a first run on a clean fixture succeeds"
run_stage_body stage_power_button "$hypr_dead"
run_stage_body stage_power_button "$hypr_dead"
ok_rc 0 "a second run succeeds -- assert_ours_or_absent recognises both files as ours"
ok_line "$POWER_LOGIND_DROPIN" "HandlePowerKey=suspend" "and the drop-in still reads correctly after the re-run"

# --- somebody else's files ------------------------------------------------
power_reset
mkdir -p "$root/etc/udev/rules.d"
printf 'ACTION=="add", TAG+="somebody-else"\n' >"$root$POWER_UDEV_RULE"
run_stage_body stage_power_button "$hypr_dead"
ok_failed "a foreign udev rule at ${POWER_UDEV_RULE} stops the stage"
grep -qF "somebody-else" "$root$POWER_UDEV_RULE" ||
  fail_test "the foreign udev rule is left exactly as it was" "it was overwritten anyway"
pass "the foreign udev rule is left byte-for-byte alone"
ok_absent "$POWER_LOGIND_DROPIN" "and nothing else was written -- the refusal happens before any write"

power_reset
printf '[Login]\nHandlePowerKey=poweroff\n' >"$root$POWER_LOGIND_DROPIN"
run_stage_body stage_power_button "$hypr_dead"
ok_failed "a foreign logind drop-in at ${POWER_LOGIND_DROPIN} stops the stage"
ok_absent "$POWER_UDEV_RULE" \
  "and the udev rule is NOT written first -- both ownership checks run before either write, so a refusal leaves no half-configured machine"

# --- the model gate --------------------------------------------------------
#
# 🔴 Every ID_PATH in this stage was measured on ONE model. On an LCD Deck
# (Jupiter) they may differ, and the two ways that fails are a rule that
# matches nothing (the duplicate survives -> the suspend loop) or one that
# matches too much (logind watches nothing -> a dead button). Today's
# behaviour on an unmeasured model is a menu flash: annoying, and working
# software. CLAUDE.md forbids claiming support for hardware nobody tested.
power_reset
printf 'Jupiter\n' >"$root/sys/class/dmi/id/product_name"
run_stage_body stage_power_button "$hypr_dead"
ok_failed "stage-power-button refuses to run on a Jupiter (LCD) Deck"
ok_in_err "Jupiter" "the refusal names the model it found"
ok_in_err "$POWER_MODEL" "and the model every measurement behind the stage was taken on"
ok_in_err "no override flag" \
  "and says there is no flag -- a flag is how 'unverified' quietly becomes 'supported'"
ok_absent "$POWER_UDEV_RULE" "nothing is written on a model that was never measured"
ok_absent "$POWER_LOGIND_DROPIN" "neither file, on a model that was never measured"

power_reset
rm -f "$root/sys/class/dmi/id/product_name"
run_stage_body stage_power_button "$hypr_dead"
ok_failed "an unreadable product_name stops the stage rather than being treated as a match"
ok_in_err "model is unknown" "and says the model could not be determined, instead of guessing"

# --- the premise: what the rule will actually match ------------------------
#
# 🔴 These two fail in OPPOSITE directions and are the reason the check exists
# at all. Neither shows up in an install log.
power_reset
rm -f "$root/dev/input/event4" "$FAKE_UDEV_DB/event4"
run_stage_body stage_power_button "$hypr_dead"
ok_failed "a machine with no ${POWER_KEEP_ID_PATH} node stops the stage"
ok_in_err "SINGLE SOURCE" \
  "the refusal explains that untagging the ACPI buttons without it leaves logind watching no power switch at all"
ok_in_err "doing nothing whatsoever" \
  "and names the resulting failure -- a DEAD button, introduced by the fix for a button that flashed a menu"
ok_absent "$POWER_UDEV_RULE" "and nothing is written"

power_reset
power_node event4 platform-i8042-serio-0 untagged
run_stage_body stage_power_button "$hypr_dead"
ok_failed "a ${POWER_KEEP_ID_PATH} node that is present but NOT tagged stops the stage too"
ok_in_err "SINGLE SOURCE" \
  "presence is not the property that matters -- logind only watches what carries the tag"

# 🔴 THE TYPO CASE. A udev rule keying on an ID_PATH that matches nothing
# installs cleanly, applies cleanly and does nothing: the duplicate KEY_POWER
# press survives, and the drop-in written next suspends on both of them.
power_reset
rm -f "$root/dev/input/event2" "$FAKE_UDEV_DB/event2"
run_stage_body stage_power_button "$hypr_dead"
ok_failed "an ID_PATH the rule untags that matches NO device on this machine stops the stage"
ok_in_err "acpi-LNXPWRBN:00" "the refusal names the ID_PATH that matched nothing"
ok_in_err "suspends twice" \
  "and names the consequence -- a rule that matches nothing is a silent no-op, and the handler installed after it is not"
ok_absent "$POWER_LOGIND_DROPIN" "and the handler is never armed on a machine whose duplicate would survive"

power_reset
rm -f "$root/dev/input"/event* "$FAKE_UDEV_DB"/event*
run_stage_body stage_power_button "$hypr_dead"
ok_failed "a machine where udev reports no power-switch device at all stops the stage"
ok_in_err "TAGS=:${POWER_UDEV_TAG}: at all" "and says the tag is absent everywhere, not that one node is missing"

# --- the ordering: whether either file is READ ----------------------------
#
# 🔴 This is the check the SDDM drop-in did not have. Its comment asserted an
# ordering that was false on every machine ('9' < 'a'), and nothing noticed
# because the code path had never been exercised. Both directions below
# produce a file that is on disk, parses correctly, and does nothing.
power_reset
printf '[Login]\nHandlePowerKey=ignore\n' \
  >"$root/etc/systemd/logind.conf.d/zzzz-somebody-else.conf"
run_stage_body stage_power_button "$hypr_dead"
ok_failed "a logind drop-in that sorts AFTER ours stops the stage"
ok_in_err "zzzz-somebody-else.conf" "the refusal names the file that would override us"
ok_in_err "sorts BEFORE" \
  "and says ours loses -- the drop-in would be on disk, read correctly, and the button would still do whatever the other file says"
ok_absent "$POWER_UDEV_RULE" "and nothing is written when the drop-in could not win"

power_reset
printf '%s\n' 'SUBSYSTEM=="input", TAG+="power-switch"' \
  >"$root/usr/lib/udev/rules.d/zzzz-somebody-else.rules"
run_stage_body stage_power_button "$hypr_dead"
ok_failed "a udev rule that ADDS the tag and sorts after ours stops the stage"
ok_in_err "remove a tag that has not been added yet" \
  "and explains the no-op: '-=' removes from a list, so read first it removes nothing"

power_reset
rm -f "$root/usr/lib/udev/rules.d/${POWER_UDEV_TAGGER}"
run_stage_body stage_power_button "$hypr_dead"
ok_failed "a machine with nothing adding TAG+=\"${POWER_UDEV_TAG}\" stops the stage"
ok_in_err "found no udev rule" \
  "the premise is that upstream tags these devices and we untag two of them; with nothing tagging, HandlePowerKey= would be dead on arrival"

# --- the lock that no keyboard can answer ---------------------------------
#
# 🔴 Blast radius R2. This Deck resumes from sleep UNLOCKED on purpose,
# because it has no keyboard; that holds only while omarchy-sleep-lock stays
# masked. A power button that suspends while that unit is live turns every
# press into an unanswerable password prompt. The stage cannot see a per-user
# mask from root, so it WARNS with the exact command that settles it rather
# than failing on half an answer.
power_reset
rm -f "$root$SLEEP_LOCK_GLOBAL_MASK"
run_stage_body stage_power_button "$hypr_dead"
ok_rc 0 "an unmasked ${SLEEP_LOCK_UNIT} does not stop the stage -- the other half of the answer is per-user and unreadable from here"
ok_in_err "$SLEEP_LOCK_UNIT" "but it warns, naming the unit"
ok_in_err "no keyboard" "and says why it matters on this device specifically"
ok_in_err "systemctl --user is-enabled" "and prints the one command that settles it, to run before the first press"

power_reset
rm -f "$root$SLEEP_LOCK_GLOBAL_MASK" "$root/usr/lib/systemd/user/${SLEEP_LOCK_UNIT}"
run_stage_body stage_power_button "$hypr_dead"
ok_rc 0 "a machine with no ${SLEEP_LOCK_UNIT} at all installs cleanly"
ok_in_out "is not installed on this machine" "and says so, rather than warning about a unit that does not exist"

power_reset
run_stage_body stage_power_button "$hypr_dead"
ok_rc 0 "and the masked case is the one the fixture ships"
ok_in_out "masked for every user" \
  "the stage reports the mask it verified, so 'resumes unlocked' is a checked property rather than an assumption"

# ===========================================================================
# 15. The harness's own safety invariant
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
