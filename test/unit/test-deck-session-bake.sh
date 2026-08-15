#!/usr/bin/env bash
# test/unit/test-deck-session-bake.sh -- deck-session.sh's CHROOT MODE, the
# branches the ISO's installer runs, plus the backlight discovery that replaced
# a constant which was wrong on the operator's own Deck.
#
# No root, no VM, no Deck, no chroot and no network.
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS
# ---------------------------------------------------------------------------
#
# `src/deck-session.sh` was written for a RUNNING Deck reached over SSH, and it
# was proven there. It was also never run by the installer, so an ISO-installed
# Deck had no session-switching layer at all: no "Switch to Desktop" row in
# Steam's power menu, no way back, no target-side input mapper. The fix is
# `configure_deck`'s `session_bake` step running THIS script inside the target
# via arch-chroot, with DECK_SESSION_CHROOT=1.
#
# That mode is new code on a file whose value is that it was measured on
# hardware. This suite covers the new half, and the two existing suites
# (test-deck-session.sh, test-deck-session-stages.sh) keep covering the old one
# -- they run with DECK_SESSION_CHROOT unset, which is the point: the normal
# path must be untouched.
#
# ---------------------------------------------------------------------------
# THE PROPERTY THIS SUITE IS REALLY ABOUT
# ---------------------------------------------------------------------------
#
# 🔴 NOTHING IS SILENTLY SKIPPED. A chroot cannot start a service, ask systemd
# what it parsed, reach a D-Bus, or drive a compositor -- so an adapted stage
# either does its file-level work anyway, or says out loud that it did not. §2
# asserts that as a STRUCTURAL property of the source (every function with a
# chroot branch is one this suite knows about and has a deferral or a refusal in
# it), not just case by case, because the failure it guards against is the
# NEXT chroot branch somebody adds quietly.
#
# ---------------------------------------------------------------------------
# SAFETY
# ---------------------------------------------------------------------------
#
# Same shape as test-deck-session-stages.sh's, and for the same reason: these
# stage bodies write to absolute paths through $SUDO. Four gates:
#
#   1. refuse to run as root (chroot mode's own branches assume root, and this
#      suite proves the refusal instead of taking the branch);
#   2. SUDO must be empty after sourcing, so nothing can reach real sudo;
#   3. fake-sudo refuses to run unless FAKE_ROOT and SANDBOX are set, and
#      rewrites every absolute path under the fake root;
#   4. every path handed to a seam is inside the work directory.
#
# The one thing read from the host is /usr/share/zoneinfo's existence (§4 needs
# the rendered timezone helper to validate against a real tree, exactly as its
# sibling suite does).

set -euo pipefail

SUITE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SUITE_DIR/../.." && pwd)
SESSION_SH="$REPO_ROOT/src/deck-session.sh"
BAKE_PY="$REPO_ROOT/iso/overlay/configs/airootfs/usr/share/omarchy-iso/orchestrator/deck_session_bake.py"

assertions=0
pass()      { assertions=$((assertions + 1)); printf 'ok - %s\n' "$1"; }
fail_test() { printf 'not ok - %s\n' "$1"; [[ -n ${2:-} ]] && printf '%s\n' "$2" >&2; exit 1; }
note()      { printf 'note - %s\n' "$1"; }

[[ -f $SESSION_SH ]] || fail_test "src/deck-session.sh exists" "not found at $SESSION_SH"
[[ -f $BAKE_PY ]] || fail_test "the orchestrator module exists" "not found at $BAKE_PY"

# --- GATE 0 ----------------------------------------------------------------
[[ $EUID -ne 0 ]] ||
  fail_test "this suite must run unprivileged" \
    "chroot mode's branches assume root; as root this suite would take them instead of proving the refusals, and its writes would leave the fake root"
pass "running unprivileged"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
root="$work/root"
stub_bin="$work/bin"
calls="$work/calls.log"
mkdir -p "$stub_bin" "$work/tmp" "$root"
: >"$calls"

# --- the sudo shim ---------------------------------------------------------
cat >"$stub_bin/fake-sudo" <<'FAKE_SUDO'
#!/usr/bin/env bash
set -uo pipefail
refuse() { printf 'fake-sudo: %s\n' "$1" >&2; exit 99; }
[[ -n ${FAKE_ROOT:-} && -d ${FAKE_ROOT:-} ]] || refuse "no FAKE_ROOT"
[[ -n ${SANDBOX:-} ]] || refuse "no SANDBOX"
printf 'sudo %s\n' "$*" >>"$CALLS_LOG"
while [[ $# -gt 0 ]]; do
  case $1 in
    -u) shift 2 ;;
    -n|-k|-K|-v|-S|-H|-E|-i|-l) shift ;;
    --) shift; break ;;
    -*) shift ;;
    *)  break ;;
  esac
done
[[ $# -gt 0 ]] || exit 0
cmd=$1
argv=(); drop_next=0
for a in "$@"; do
  if [[ $drop_next -eq 1 ]]; then drop_next=0; continue; fi
  if [[ $cmd == install && ( $a == -o || $a == -g ) ]]; then drop_next=1; continue; fi
  if [[ $a == /dev/null ]]; then argv+=("$a"); continue; fi
  if [[ $a == /* ]]; then
    [[ $a == "$SANDBOX"/* ]] || a="${FAKE_ROOT}${a}"
    [[ $a == "$FAKE_ROOT"/* || $a == "$SANDBOX"/* ]] || refuse "'${a}' escapes the sandbox"
  fi
  argv+=("$a")
done
exec "${argv[@]}"
FAKE_SUDO
chmod +x "$stub_bin/fake-sudo"

# Stubs that must NEVER be reached from a chroot branch. Each one records the
# call, so "it did not talk to systemd" is asserted from evidence rather than
# from the absence of an error.
for tool in systemctl timedatectl hyprctl dconf; do
  cat >"$stub_bin/$tool" <<STUB
#!/usr/bin/env bash
printf '$tool %s\n' "\$*" >>"\$CALLS_LOG"
exit 0
STUB
  chmod +x "$stub_bin/$tool"
done

export FAKE_ROOT="$root" SANDBOX="$work" CALLS_LOG="$calls" TMPDIR="$work/tmp"

# Run a snippet with deck-session.sh sourced in CHROOT MODE, $SUDO pointed at
# the shim, and the stubs in front of PATH. stdout+stderr land in $work/out.
run_chroot() {   # run_chroot <bash snippet>
  : >"$calls"
  printf '%s\n' "$1" >"$work/snippet.sh"
  RC=0
  DECK_SESSION_CHROOT=1 PATH="$stub_bin:$PATH" \
    bash -c '
      source "$1"
      SUDO="$2"
      source "$3"
    ' _ "$SESSION_SH" "$stub_bin/fake-sudo" "$work/snippet.sh" \
    >"$work/out" 2>&1 || RC=$?
  OUT=$(cat "$work/out")
}

# Same, with chroot mode OFF -- used to prove a branch is genuinely selected by
# the flag rather than being the only behaviour there is.
run_normal() {   # run_normal <bash snippet>
  : >"$calls"
  printf '%s\n' "$1" >"$work/snippet.sh"
  RC=0
  PATH="$stub_bin:$PATH" \
    bash -c '
      source "$1"
      SUDO="$2"
      source "$3"
    ' _ "$SESSION_SH" "$stub_bin/fake-sudo" "$work/snippet.sh" \
    >"$work/out" 2>&1 || RC=$?
  OUT=$(cat "$work/out")
}

out_has()  { grep -qF -- "$1" "$work/out"; }
called()   { grep -qF -- "$1" "$calls"; }

# ===========================================================================
# 1. The flag, and that it changes nothing when it is unset
# ===========================================================================
echo "# 1. the flag"

# shellcheck source=../../src/deck-session.sh
source "$SESSION_SH"

[[ -z ${SUDO:-} ]] ||
  fail_test "SUDO is empty after sourcing" "got '${SUDO}'; no body in this suite could then be kept off real sudo"
pass "SUDO is empty after sourcing -- nothing here can reach real sudo"

[[ $CHROOT_MODE -eq 0 ]] ||
  fail_test "chroot mode is OFF unless DECK_SESSION_CHROOT=1" "CHROOT_MODE=${CHROOT_MODE} with the variable unset"
in_chroot && fail_test "in_chroot is false with the flag unset"
pass "chroot mode is off by default, so the two existing suites keep exercising the Deck path"

run_chroot 'in_chroot && echo YES-CHROOT'
if [[ $RC -ne 0 ]] || ! out_has "YES-CHROOT"; then
  fail_test "DECK_SESSION_CHROOT=1 turns chroot mode on" "rc=${RC}"$'\n'"$OUT"
fi
pass "DECK_SESSION_CHROOT=1 turns chroot mode on"

run_chroot 'DECK_SESSION_CHROOT=0 true'   # already sourced; the value is readonly by then
[[ $RC -eq 0 ]] || fail_test "CHROOT_MODE is fixed at source time" "$OUT"
pass "CHROOT_MODE is resolved once, at source time, and is readonly after"

# The desktop user. Inside a chroot there is no SUDO_USER and $USER is root, so
# this override is the only way a stage can know who to write files for.
user_out=$(DECK_SESSION_USER=installeduser SUDO_USER=sshuser bash -c 'source "$1"; desktop_user' _ "$SESSION_SH")
[[ $user_out == installeduser ]] ||
  fail_test "DECK_SESSION_USER wins when it is set" "got '${user_out}'"
pass "desktop_user prefers DECK_SESSION_USER -- the account the installer created and confirmed"

user_out=$(SUDO_USER=sshuser bash -c 'unset DECK_SESSION_USER; source "$1"; desktop_user' _ "$SESSION_SH")
[[ $user_out == sshuser ]] ||
  fail_test "SUDO_USER is still what an ordinary run uses" "got '${user_out}'"
pass "desktop_user falls back to SUDO_USER -- the Deck path is unchanged"

# ===========================================================================
# 2. STRUCTURAL: every chroot branch is one this suite knows about
# ===========================================================================
echo "# 2. no chroot branch is quiet, and none is unaccounted for"

# The functions that are ALLOWED to have a chroot branch, and what each must
# also contain. A new one that appears without being added here fails this
# section -- which is the point: the failure being guarded against is the next
# branch somebody adds without a deferral.
declare -A CHROOT_FUNCS=(
  [stage_preconditions]=refusal     # refuses a non-root run; warns on non-Deck DMI
  [run_as_desktop_user]=refusal     # drops privilege with setpriv, or fails loudly
  [stage_sddm_resilience]=defer
  [verify_timezone_helper]=defer
  [verify_lizard_helper]=defer
  [stage_lizard_mode]=defer
  [stage_input_mapper]=defer
  [stage_osk_kb_layout]=defer
)

mapfile -t all_funcs < <(bash -c 'source "$1"; declare -F | sed "s/^declare -f //"' _ "$SESSION_SH")
found_chroot=()
for fn in "${all_funcs[@]}"; do
  # in_chroot itself is the predicate, not a branch on it. `declare -f` prints
  # the function's own name, so without this it would match itself.
  [[ $fn != in_chroot ]] || continue
  body=$(bash -c 'source "$1"; declare -f "$2"' _ "$SESSION_SH" "$fn")
  [[ $body == *in_chroot* ]] || continue
  found_chroot+=("$fn")
  [[ -n ${CHROOT_FUNCS[$fn]:-} ]] ||
    fail_test "every function with a chroot branch is declared in this suite" \
      "${fn} branches on in_chroot and this suite does not know about it. Add it to CHROOT_FUNCS with what it must do -- an undeclared branch is how a silent skip gets in."
  case ${CHROOT_FUNCS[$fn]} in
    defer)
      [[ $body == *"defer "* ]] ||
        fail_test "${fn}'s chroot branch says out loud what it did not do" \
          "no defer() call in its body; a check that cannot run must be reported, never skipped"
      ;;
    refusal)
      [[ $body == *"fail "* || $body == *"warn "* ]] ||
        fail_test "${fn}'s chroot branch refuses or warns rather than proceeding quietly" "$body"
      ;;
  esac
done
[[ ${#found_chroot[@]} -eq ${#CHROOT_FUNCS[@]} ]] ||
  fail_test "every declared chroot function actually has a branch" \
    "declared ${#CHROOT_FUNCS[@]}, found ${#found_chroot[@]}: ${found_chroot[*]}"
pass "all ${#found_chroot[@]} chroot branches are declared, and each defers, warns or refuses -- none is quiet"

# The marker deck_session_bake.py greps for, checked from BOTH ends so they
# cannot drift apart.
defer_body=$(bash -c 'source "$1"; declare -f defer' _ "$SESSION_SH")
py_marker=$(grep -oP '^DEFER_MARKER = "\K[^"]+' "$BAKE_PY") ||
  fail_test "deck_session_bake.py declares DEFER_MARKER" "not found in $BAKE_PY"
[[ $defer_body == *"$py_marker"* ]] ||
  fail_test "defer() prints the marker the orchestrator greps for" \
    "the module looks for '${py_marker}' and defer() is:"$'\n'"${defer_body}"
pass "defer() prints '${py_marker}', which is what deck_session_bake.py extracts into the install record"

# One line per deferral: the module reads them line by line, and a multi-line
# message would be recorded as a fragment.
run_chroot 'defer "first thing" ; defer "second thing"'
[[ $(grep -c "$py_marker" "$work/out") -eq 2 ]] ||
  fail_test "each deferral is exactly one line" "$OUT"
pass "each deferral is one greppable line"

# setpriv, not sudo. Inside a chroot there is no PAM stack, no tty and no audit
# socket to lean on, and `sudo -u` failing there is a write that never happens.
rad_body=$(bash -c 'source "$1"; declare -f run_as_desktop_user' _ "$SESSION_SH")
[[ $rad_body == *setpriv* ]] ||
  fail_test "run_as_desktop_user drops privilege with setpriv in a chroot" "$rad_body"
pass "run_as_desktop_user uses setpriv in chroot mode, not sudo"

# The compositor seam is pinned to a path that cannot exist. arch-chroot
# bind-mounts /run, so the live /run/user/<uid> in there is the INSTALLER's.
osk_body=$(bash -c 'source "$1"; declare -f stage_osk_kb_layout' _ "$SESSION_SH")
[[ $osk_body == *CHROOT_NO_HYPR_RUNTIME* ]] ||
  fail_test "stage_osk_kb_layout points the compositor seam away from /run in chroot mode" "$osk_body"
[[ ! -e $CHROOT_NO_HYPR_RUNTIME ]] ||
  fail_test "the chroot runtime directory really cannot exist" "${CHROOT_NO_HYPR_RUNTIME} is on this machine"
pass "stage_osk_kb_layout cannot reload the installer's own compositor: its runtime seam is a path that does not exist"

# ===========================================================================
# 3. stage-preconditions
# ===========================================================================
echo "# 3. stage-preconditions"

run_chroot 'stage_preconditions'
if [[ $RC -eq 0 ]] || ! out_has "not root"; then
  fail_test "chroot mode refuses a non-root run" "rc=${RC}"$'\n'"$OUT"
fi
out_has "arch-chroot" ||
  fail_test "the refusal says where chroot mode is entered from" "$OUT"
pass "stage-preconditions refuses a non-root chroot run, naming arch-chroot"

# The display-manager probe is answered from the disk, because there is no
# manager to ask. Asserted through the refusal, which is the branch a target
# without SDDM takes -- and the message must not send anyone to `systemctl`.
sddm_body=$(bash -c 'source "$1"; declare -f stage_preconditions' _ "$SESSION_SH")
[[ $sddm_body == *"/usr/lib/systemd/system"* ]] ||
  fail_test "the chroot branch looks for sddm.service on disk" "$sddm_body"
pass "the sddm precondition is answered from the target's own unit files in chroot mode"

# ===========================================================================
# 4. stage-sddm-resilience: writes the drop-in, asks systemd nothing
# ===========================================================================
echo "# 4. stage-sddm-resilience"

run_chroot 'stage_sddm_resilience'
[[ $RC -eq 0 ]] || fail_test "stage-sddm-resilience completes in a chroot" "$OUT"
[[ -f "$root$SDDM_UNIT_DROPIN" ]] ||
  fail_test "it writes the drop-in anyway -- the artefact is what the target needs" "$OUT"
grep -qx "TimeoutStopSec=${SDDM_STOP_TIMEOUT}" "$root$SDDM_UNIT_DROPIN" ||
  fail_test "the drop-in carries the directive that stops the teardown being SIGKILLed" "$(cat "$root$SDDM_UNIT_DROPIN")"
called "systemctl" &&
  fail_test "it does not talk to systemd in a chroot" "$(cat "$calls")"
out_has "$py_marker" ||
  fail_test "it says the systemd-parse check was deferred" "$OUT"
out_has "systemctl show sddm" ||
  fail_test "the deferral names the command that re-runs the check" "$OUT"
pass "stage-sddm-resilience writes and re-reads its drop-in, calls no systemctl, and defers the parse check by name"

# The same stage OFF the chroot path must still reach systemd -- otherwise the
# assertion above would pass for a stage that had simply stopped checking.
run_normal 'stage_sddm_resilience || true'
called "systemctl daemon-reload" ||
  fail_test "the normal path still reloads systemd" "$(cat "$calls")"
pass "with the flag unset the stage still drives systemctl -- the chroot branch is genuinely a branch"

# ===========================================================================
# 5. the timezone helper: refusals exercised, round trip deferred
# ===========================================================================
echo "# 5. verify_timezone_helper"

[[ -d /usr/share/zoneinfo ]] ||
  fail_test "the host has a zoneinfo tree" "the rendered helper validates against it by design"

# shellcheck disable=SC2016  # expanded in the child shell, not here
run_chroot '
  helper="$SANDBOX/tz-helper"
  render_timezone_helper >"$helper"
  chmod +x "$helper"
  verify_timezone_helper "$helper"
'
[[ $RC -eq 0 ]] || fail_test "verify_timezone_helper completes in a chroot" "$OUT"
called "timedatectl" &&
  fail_test "it does not call timedatectl -- there is no timedated on a bus in a chroot" "$(cat "$calls")"
out_has "$py_marker" || fail_test "it defers the round trip" "$OUT"
out_has "refuses a traversal argument" ||
  fail_test "it still exercises the validation that runs BEFORE any elevation" "$OUT"
pass "verify_timezone_helper exercises the helper's refusals, calls no timedatectl, and defers the round trip"

# The refusals are real, not asserted from the outside: a helper that accepted
# a traversal must fail this stage.
# shellcheck disable=SC2016  # expanded in the child shell, not here
run_chroot '
  helper="$SANDBOX/tz-bad"
  printf "#!/usr/bin/env bash\nexit 0\n" >"$helper"
  chmod +x "$helper"
  verify_timezone_helper "$helper"
'
if [[ $RC -eq 0 ]] || ! out_has "path-traversal"; then
  fail_test "a helper that accepts a traversal fails the check" "rc=${RC}"$'\n'"$OUT"
fi
pass "a permissive helper is refused -- the chroot check can fail"

# ===========================================================================
# 6. lizard mode: the node is NOT touched
# ===========================================================================
echo "# 6. verify_lizard_helper"

# 🔴 The value is deliberately neither Y nor N. The Deck path reads the node
# first and refuses anything else, so this content proves the chroot path never
# read or wrote it -- rather than proving nothing, which "Y" would.
# shellcheck disable=SC2016  # expanded in the child shell, not here
run_chroot '
  node="$SANDBOX/lizard-node"
  printf "SENTINEL\n" >"$node"
  helper="$SANDBOX/lizard-helper"
  render_lizard_helper "$node" >"$helper"
  chmod +x "$helper"
  verify_lizard_helper "$helper" "$node"
'
[[ $RC -eq 0 ]] || fail_test "verify_lizard_helper completes in a chroot" "$OUT"
[[ $(cat "$work/lizard-node") == SENTINEL ]] ||
  fail_test "the sysfs node is not touched in a chroot" \
    "arch-chroot bind-mounts /sys, so that node is the INSTALLING machine's -- toggling it takes input away from the operator mid-install. Node now reads: $(cat "$work/lizard-node")"
out_has "$py_marker" || fail_test "it says the toggle was deferred" "$OUT"
out_has "exit 2" || fail_test "it exercises the helper's argv contract instead" "$OUT"
pass "verify_lizard_helper leaves the sysfs node alone, checks the helper's argv contract, and defers the toggle"

# The same call OFF the chroot path DOES read the node -- so the assertion above
# is about the branch, not about a check that quietly stopped existing.
# shellcheck disable=SC2016  # expanded in the child shell, not here
run_normal '
  node="$SANDBOX/lizard-node2"
  printf "SENTINEL\n" >"$node"
  helper="$SANDBOX/lizard-helper2"
  render_lizard_helper "$node" >"$helper"
  chmod +x "$helper"
  verify_lizard_helper "$helper" "$node" || true
'
out_has "neither Y nor N" ||
  fail_test "the normal path still reads the node" "$OUT"
pass "with the flag unset the same function reads the node -- the chroot branch is genuinely a branch"

# ===========================================================================
# 7. THE BACKLIGHT, discovered rather than assumed
# ===========================================================================
echo "# 7. find_backlight"

# 🔴 WHAT THIS SECTION IS ABOUT. `DECK_BACKLIGHT` was a readonly constant
# naming /sys/class/backlight/amdgpu_bl0/brightness. Measured on the operator's
# OLED Deck on stock linux 7.1.8-arch1-3, 2026-08-15: the panel is amdgpu_bl1
# and there is NO amdgpu_bl0. Earlier sessions measured bl0 on the Neptune
# kernel. Same panel, same machine -- the index is DRM enumeration order.
#
# What it cost was not "brightness broke": the rendered helper's whitelist is a
# PATTERN and accepted bl1 all along (verified on the device the same day). What
# broke is that verify_priv_write_helper took its "node not present" arm and
# WARNED, so the write path shipped unexercised on the only machine that has a
# panel -- a check passing for the wrong reason.

bl_root="$work/bl"
new_bl() {   # new_bl <case> <node names...>
  local case_dir="$bl_root/$1"; shift
  rm -rf "$case_dir"; mkdir -p "$case_dir"
  local n
  for n in "$@"; do mkdir -p "$case_dir/$n"; printf '1234\n' >"$case_dir/$n/brightness"; done
  printf '%s' "$case_dir"
}

find_bl() {   # find_bl <dir> -> sets RC, OUT(stdout), ERR(stderr)
  RC=0
  OUT=$(bash -c 'source "$1"; find_backlight "$2/amdgpu_bl*/brightness" "$2"' \
    _ "$SESSION_SH" "$1" 2>"$work/bl.err") || RC=$?
  ERR=$(cat "$work/bl.err")
}

d=$(new_bl one-bl1 amdgpu_bl1)
find_bl "$d"
[[ $RC -eq 0 && $OUT == "$d/amdgpu_bl1/brightness" ]] ||
  fail_test "the node is found when it is called amdgpu_bl1 (the stock-kernel measurement)" "rc=${RC} out='${OUT}' err='${ERR}'"
pass "amdgpu_bl1 is discovered -- the name the operator's Deck actually has"

d=$(new_bl one-bl0 amdgpu_bl0)
find_bl "$d"
[[ $RC -eq 0 && $OUT == "$d/amdgpu_bl0/brightness" ]] ||
  fail_test "the node is found when it is called amdgpu_bl0 (the Neptune measurement)" "rc=${RC} out='${OUT}' err='${ERR}'"
pass "amdgpu_bl0 is discovered too -- the new ISO is Neptune-only, so it may well be this one again"

d=$(new_bl two amdgpu_bl1 amdgpu_bl0)
find_bl "$d"
[[ $RC -eq 0 && $OUT == "$d/amdgpu_bl0/brightness" ]] ||
  fail_test "more than one candidate is resolved deterministically" "rc=${RC} out='${OUT}'"
[[ $ERR == *amdgpu_bl0* && $ERR == *amdgpu_bl1* ]] ||
  fail_test "and every candidate is named, rather than one being taken quietly" "$ERR"
pass "with two candidates it takes the first by version sort and says out loud that there was a choice"

d=$(new_bl foreign acpi_video0)
find_bl "$d"
[[ $RC -eq 2 ]] ||
  fail_test "a machine with backlights but no amdgpu one is a FINDING, not a shrug" "rc=${RC} out='${OUT}' err='${ERR}'"
[[ $ERR == *acpi_video0* ]] ||
  fail_test "the failure names what it did find" "$ERR"
[[ $ERR != *"WARNING"* ]] ||
  fail_test "it is reported as an error, not a warning" "$ERR"
pass "backlights present but none amdgpu: exit 2, naming them -- a panel under an unknown name is a real finding"

d=$(new_bl empty)
find_bl "$d"
[[ $RC -eq 1 && -z $OUT ]] ||
  fail_test "a machine with no backlight at all is distinguishable" "rc=${RC} out='${OUT}'"
[[ $ERR == *WARNING* ]] ||
  fail_test "and it still says so" "$ERR"
pass "no backlight anywhere: exit 1 with a warning -- ordinary off a Deck, and told apart from the case above"

RC=0
OUT=$(bash -c 'source "$1"; find_backlight "$2/amdgpu_bl*/brightness" "$2"' \
  _ "$SESSION_SH" "$work/definitely-absent" 2>/dev/null) || RC=$?
[[ $RC -eq 1 ]] ||
  fail_test "an absent class directory behaves like an empty one" "rc=${RC}"
pass "an absent /sys/class/backlight is the same 'no panel here' answer, not a crash"

# The constant is gone. A second answer to a question that now has a discovery
# is exactly what was wrong before.
! grep -qE '^readonly DECK_BACKLIGHT=' "$SESSION_SH" ||
  fail_test "the hardcoded backlight constant is gone" "a literal node path is a coin flip across kernels"
pass "no hardcoded backlight node remains in deck-session.sh"

# ---------------------------------------------------------------------------
# The whitelist inside the rendered helper is the security boundary, and
# widening discovery must not have widened it. Exercised by EXIT CODE, which
# distinguishes "refused as unlisted" (3) from "passed the whitelist and was
# refused for its value" (4) -- so the accept case proves the path was admitted
# without anything ever being written.
# ---------------------------------------------------------------------------
pw="$work/priv-write"
bash -c 'source "$1"; render_priv_write_helper' _ "$SESSION_SH" >"$pw"
chmod +x "$pw"

pw_rc() { RC=0; "$pw" "$1" "$2" >/dev/null 2>&1 || RC=$?; }

pw_rc /sys/class/backlight/amdgpu_bl1/brightness not-a-number
[[ $RC -eq 4 ]] ||
  fail_test "the helper admits an amdgpu_bl1 path (refusing it only for the value)" "exit ${RC}, expected 4"
pass "the rendered helper's whitelist admits amdgpu_bl1 -- it was never the thing that was wrong"

pw_rc /sys/class/backlight/amdgpu_bl0/brightness not-a-number
[[ $RC -eq 4 ]] || fail_test "and amdgpu_bl0" "exit ${RC}, expected 4"
pass "and amdgpu_bl0, so a kernel change cannot break it either way"

pw_rc /etc/shadow 1
[[ $RC -eq 3 ]] ||
  fail_test "a non-backlight path is still refused as unlisted" "exit ${RC}, expected 3"
pass "/etc/shadow is still refused -- the whitelist is unchanged and still bounds a root write"

pw_rc /sys/class/backlight/../../../etc/shadow 1
[[ $RC -eq 3 ]] ||
  fail_test "the traversal defence still holds" "exit ${RC}, expected 3"
pass "a '..' traversal out of the backlight subtree is still refused"

pw_rc /sys/class/leds/status:white/led_brightness_multiplier not-a-number
[[ $RC -eq 4 ]] || fail_test "the status LED is still admitted" "exit ${RC}, expected 4"
pass "the status LED node is still admitted -- discovery changed nothing about the boundary"

# ===========================================================================
# 8. The stage list the installer bakes
# ===========================================================================
echo "# 8. list-bake-stages"

mapfile -t baked < <(bash "$SESSION_SH" list-bake-stages)
[[ ${#baked[@]} -ge 10 ]] || fail_test "list-bake-stages names the stages" "got: ${baked[*]}"
[[ ${baked[0]} == stage-preconditions ]] ||
  fail_test "the probes run first" "got '${baked[0]}'"
printf '%s\n' "${baked[@]}" | grep -qx stage-desktop-settings &&
  fail_test "stage-desktop-settings is not baked" \
    "three registry steps already write its dconf, idle and sleep-lock halves, and the site file they write carries no marker of ours -- assert_ours_or_absent would refuse it"
printf '%s\n' "${baked[@]}" | grep -qx stage-osk-kb-layout ||
  fail_test "stage-osk-kb-layout IS baked" "it is the half of stage-desktop-settings nothing else writes"
pass "the baked list is the install stages minus desktop-settings, plus the XKB rule"

# The opt-in stages stay opt-in: each of them changes something a human has to
# have watched work first.
for opt in stage-default-session stage-boot-default-gaming stage-power-button stage-audit-privileges; do
  printf '%s\n' "${baked[@]}" | grep -qx "$opt" &&
    fail_test "${opt} is not baked by the installer" \
      "it is opt-in on its own argument (see BAKE_STAGES); baking it would arm it on a machine nobody has watched"
done
pass "the four opt-in stages are still opt-in -- the installer arms none of them"

# stage-osk-kb-layout is reachable by hand as well, since it is now a stage.
mapfile -t offered < <(bash "$SESSION_SH" list-stages)
printf '%s\n' "${offered[@]}" | grep -qx stage-osk-kb-layout ||
  fail_test "list-stages offers the new stage" "${offered[*]}"
pass "stage-osk-kb-layout is offered by list-stages too, so the SSH loop can run it alone"

# And stage-desktop-settings still runs it, so a full Deck-side run is unchanged.
ds_body=$(bash -c 'source "$1"; declare -f stage_desktop_settings' _ "$SESSION_SH")
[[ $ds_body == *stage_osk_kb_layout* ]] ||
  fail_test "stage-desktop-settings still installs the keyboard rule" \
    "the extraction must not have removed it from the stage a Deck-side run uses"
pass "stage-desktop-settings still calls it, so a full run on a Deck behaves as it did"

echo "all deck-session.sh chroot-mode and backlight-discovery tests passed (${assertions} assertions)"
