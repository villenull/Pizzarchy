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
#
# THE THIRD CATEGORY, added 2026-08-15 with the PROGRESS.md 5.38 work.
# `defer` and `refusal` between them cover "a check could not run" and "this
# machine is the wrong one". They do not cover a branch that does the SAME work
# BY A DIFFERENT ROUTE because the chroot has no manager to ask -- writing an
# enablement symlink instead of calling `systemctl enable`, say. Classifying
# that as `refusal` because its body happens to contain the word `fail` would
# be the classifier passing for the wrong reason, which is the exact failure
# this section exists to catch.
#
# So `adapted` is its own category with its own requirement: the branch must
# READ BACK what it did (a `fail` on the artefact it just wrote). "It took the
# other route" and "the other route worked" are different claims, and an
# adapted branch that only makes the first is how a silent skip gets in wearing
# a different hat.
declare -A CHROOT_FUNCS=(
  [stage_preconditions]=refusal     # refuses a non-root run; warns on non-Deck DMI
  [run_as_desktop_user]=refusal     # drops privilege with setpriv, or fails loudly
  [stage_sddm_resilience]=defer
  [verify_timezone_helper]=defer
  [verify_lizard_helper]=defer
  [stage_lizard_mode]=defer
  [stage_input_mapper]=defer
  [stage_osk_kb_layout]=defer
  # PROGRESS.md 5.38 D10 -- the backlight cannot be discovered in the
  # installer's kernel, so the discovery is not attempted and the write path is
  # handed to a unit that runs on the target's own kernel.
  [stage_priv_write_helper]=defer
  # 5.38 D9 -- the power button, now baked. Three branches, three jobs.
  [power_model_reject]=refusal      # wrong model: warn and skip rather than fail a bake
  [verify_power_button_ordering]=defer   # /run is the INSTALLER's, so it is not scanned
  [verify_power_button_premise]=defer    # udev's database is the installer's kernel's
  [stage_power_button]=adapted           # installs the deferred check's runner
  # 5.35 -- Steam's first run. Whether the splash DRAWS needs a compositor.
  [stage_steam_first_run]=defer
  # The WirePlumber drop-in that stops Steam's volume OSD labelling the Deck's
  # own speakers. The FILE is written in a chroot exactly as it is on a Deck --
  # it is user config, and run_as_desktop_user already handles that. What
  # cannot be done in here is asking a running PipeWire whether the rename took
  # effect: arch-chroot bind-mounts /run, so that question would be answered by
  # the INSTALLER's audio devices.
  [stage_onboard_audio_name]=defer
  # The Desktop-Mode Steam launcher. The FILES are installed in a chroot exactly
  # as they are on a Deck -- one root-owned script and two desktop entries, and
  # run_as_desktop_user already handles the user's copy. What cannot be answered
  # in here is the only question that matters: does the block actually deny
  # Steam the controller? arch-chroot bind-mounts /sys and /dev, so `--check`
  # would enumerate the INSTALLER's hardware and report it as the target's, and
  # no Steam has ever run on the target anyway.
  [stage_steam_desktop_launcher]=defer
  # The runner itself: no manager to `systemctl enable` with, so the symlink is
  # written directly and then read back.
  [install_first_boot_verify]=adapted
  # "A reboot always lands in Gaming Mode", baked as of 2026-08-17. TWO chroot
  # branches, and they are different jobs:
  #   * enabling -- no manager to `systemctl enable` with, so both wants
  #     symlinks are written directly and read back (the install_first_boot_
  #     verify move, for two units instead of one);
  #   * verify_boot_default_ordering -- `systemctl show` would be answered by
  #     the INSTALLER's manager about a unit the installer does not have, so
  #     the ordering proof is deferred to the target. It is the one thing about
  #     this stage a chroot genuinely cannot answer, and it is the thing the
  #     whole unit depends on.
  # 'defer' is the stricter of the two labels this suite can apply -- it also
  # requires the fail-on-readback that 'adapted' asks for, since both branches
  # are in the one body.
  [stage_boot_default_gaming]=defer
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
    adapted)
      # See the note above CHROOT_FUNCS: taking the other route is not the
      # same claim as the other route having worked.
      [[ $body == *"fail "* ]] ||
        fail_test "${fn}'s chroot branch reads back what it wrote" \
          "an 'adapted' branch does the work by a different route because the chroot has no manager; without a fail on the artefact it just wrote, 'exited 0' is the only evidence it has -- and that is what an installed-but-not-enabled unit looks like too. Body:"$'\n'"$body"
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
#
# ⚠️ stage-power-button LEFT THIS LIST on 2026-08-15 (PROGRESS.md 5.38 D9). It
# was here, and being here is what shipped a Deck whose power button does
# nothing: Omarchy's package-owned 10-ignore-power-button.conf resolves
# HandlePowerKey=ignore and nothing of ours ever contested it. The assertions
# below now check the opposite, plus the two properties that made the change
# safe. Do not "restore" this line without reading that section.
#
# ⚠️ stage-boot-default-gaming LEFT THIS LIST on 2026-08-17, for the same shape
# of reason and with the same shape of evidence. Read the assertions below it
# before "restoring" this line.
for opt in stage-default-session stage-audit-privileges; do
  printf '%s\n' "${baked[@]}" | grep -qx "$opt" &&
    fail_test "${opt} is not baked by the installer" \
      "it is opt-in on its own argument (see BAKE_STAGES); baking it would arm it on a machine nobody has watched"
done
pass "the two remaining opt-in stages are still opt-in -- the installer arms none of them"

# 🔴 THE SHIPPED BUG, ASSERTED. Without this stage the installer produces a Deck
# on which Steam's own Power -> "Switch to Desktop" is PERMANENT: a reboot
# returns to the last-used mode, not to Gaming Mode, so Desktop Mode is not the
# one-shot session stock SteamOS has and this product says it has. The unit, its
# ordering proof and its escape hatch were all already written and reached by no
# code path on any shipped Deck -- the P32 defect family again.
# docs/KNOWN-ISSUES.md 2026.08.17 #2.
printf '%s\n' "${baked[@]}" | grep -qx stage-boot-default-gaming ||
  fail_test "stage-boot-default-gaming IS baked" \
    "it was not, and the released ISO shipped a Deck that returns to whatever mode it was last in. Baking it is what makes 'a reboot always lands in Gaming Mode' true of the product rather than of a stage nobody runs."
pass "stage-boot-default-gaming is baked, so a reboot on an installed Deck lands in Gaming Mode"

# It refuses to run until ${SELECT_BIN} is executable -- both units it installs
# schedule that writer -- so its position relative to stage-session-select is a
# hard requirement, not a preference. Ordered wrong, the whole stage fails.
bdg_at=-1; sel_at=-1
for i in "${!baked[@]}"; do
  [[ ${baked[$i]} == stage-boot-default-gaming ]] && bdg_at=$i
  [[ ${baked[$i]} == stage-session-select ]]      && sel_at=$i
done
[[ $sel_at -ge 0 && $bdg_at -gt $sel_at ]] ||
  fail_test "stage-boot-default-gaming runs after stage-session-select" \
    "session-select at ${sel_at}, boot-default-gaming at ${bdg_at}. The stage gates on ${SELECT_BIN} being executable, so running it first is a guaranteed stage failure in every install."
pass "stage-boot-default-gaming runs after the stage that installs the writer it schedules"

# 🔴 THE P32 DEFECT FAMILY, ASSERTED. Written, unit-tested, documented and
# reached by no code path is this project's most expensive recurring bug (six
# members and counting). A stage that exists and is not run is worth nothing.
printf '%s\n' "${baked[@]}" | grep -qx stage-power-button ||
  fail_test "stage-power-button IS baked" \
    "it was not, and the result was an installed Deck whose power button does nothing at all -- the key is detected, delivered, and dropped by Omarchy's HandlePowerKey=ignore. PROGRESS.md 5.38 D9."
pass "stage-power-button is baked, so the T13 work reaches an installed Deck"

printf '%s\n' "${baked[@]}" | grep -qx stage-steam-first-run ||
  fail_test "stage-steam-first-run IS baked" "the first-run network race and the two silent minutes after it (PROGRESS.md 5.35) are install-time fixes or they are nothing"
pass "stage-steam-first-run is baked"

# It runs LAST, and after everything that could fail. The one stage that
# rewires a hardware button should not go first on a machine whose other
# stages have not yet had their chance to report.
[[ ${baked[-1]} == stage-power-button ]] ||
  fail_test "stage-power-button is the last baked stage" "got '${baked[-1]}'; ${baked[*]}"
pass "and it runs last, after every other stage has had its chance to fail"

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

# ===========================================================================
# 9. THE WRONG KERNEL -- PROGRESS.md 5.38 D10
# ===========================================================================
#
# The real install's stage-priv-write-helper was the one stage that FAILED, and
# the reason was structural rather than unlucky: arch-chroot bind-mounts /sys
# from the LIVE ISO, whose stock archiso kernel enumerated the panel as
# amdgpu_bl1, while the installed Deck's Neptune kernel offers only amdgpu_bl0.
# The discovery was correct; it was asked of the wrong machine.
#
# What must NOT be re-diagnosed (measured and disproved in 0becd4b, and re-
# measured on hardware 2026-08-15 -- the installed helper accepted
# /sys/class/backlight/amdgpu_bl0/brightness as user 'deck' and exited 0):
# the helper's whitelist is a pattern and was never wrong. §7 above still
# covers it and those assertions are unchanged.
echo "# 9. the wrong kernel: no hardware discovery inside the chroot"

pw_body=$(bash -c 'source "$1"; declare -f stage_priv_write_helper' _ "$SESSION_SH")

# The structural claim, checked on the source: the chroot arm must be reached
# BEFORE find_backlight, not after it.
[[ $pw_body == *"in_chroot"*"BACKLIGHT_CHROOT_SENTINEL"* ]] ||
  fail_test "stage_priv_write_helper's chroot arm comes before the discovery" \
    "find_backlight globs /sys, which inside arch-chroot is the INSTALLING machine's. Body:"$'\n'"$pw_body"
pass "stage_priv_write_helper takes the sentinel in chroot mode instead of globbing the installer's /sys"

# And behaviourally: run the resolution half in chroot mode with a fake /sys
# that carries a node the TARGET will not have, and prove nothing goes near it.
mkdir -p "$work/fakesys/amdgpu_bl9"
echo 1234 >"$work/fakesys/amdgpu_bl9/brightness"
# shellcheck disable=SC2016  # the body is sent to the CHROOT verbatim -- expanding it HERE, in the test's own shell, is precisely the bug this asserts against
run_chroot '
  if [[ -z "" ]] && in_chroot; then
    backlight=$BACKLIGHT_CHROOT_SENTINEL
    defer "the backlight node cannot be discovered at install time"
  fi
  printf "RESOLVED=%s\n" "$backlight"
'
out_has "RESOLVED=${BACKLIGHT_CHROOT_SENTINEL}" ||
  fail_test "the chroot arm resolves to the sentinel" "$OUT"
[[ ! -e $BACKLIGHT_CHROOT_SENTINEL ]] ||
  fail_test "the sentinel is a path that cannot exist" "${BACKLIGHT_CHROOT_SENTINEL} is on this machine"
pass "the chroot sentinel is whitelist-shaped and cannot exist, so the boundary checks still run and the write does not"

# The deferral has to name where the answer comes from instead. A deferred
# check whose message does not say who will answer it is a skip with a label.
# Matched on the LITERAL ${...} text, not on its value: `declare -f` prints the
# source of a double-quoted string, so the expansion never happens here.
# shellcheck disable=SC2016
[[ $pw_body == *'${FIRST_BOOT_VERIFY_NAME}'* ]] ||
  fail_test "the deferral names the unit that answers it" "$pw_body"
pass "the deferral names ${FIRST_BOOT_VERIFY_NAME} as what asks the question on the target"

# ---------------------------------------------------------------------------
# The late-binding verifier itself
# ---------------------------------------------------------------------------
fbv="$work/first-boot-verify"
bash -c 'source "$1"; render_first_boot_verify testuser' _ "$SESSION_SH" >"$fbv"
bash -n "$fbv" || fail_test "the rendered verifier is valid bash" "$(cat "$fbv")"
pass "render_first_boot_verify emits syntactically valid bash"

grep -qF -- "$INSTALL_MARKER_TEXT" "$fbv" ||
  fail_test "the verifier carries the install marker" "without it assert_ours_or_absent cannot recognise its own output on a re-run"
pass "the verifier carries '${INSTALL_MARKER_TEXT}', so a re-run recognises it"

# It must NOT contain a literal node. That is the constant this project already
# removed once; re-introducing it in a second file would be the same bug in a
# new place.
! grep -qE 'amdgpu_bl[0-9]' "$fbv" ||
  fail_test "the verifier hardcodes no backlight index" \
    "the index is DRM enumeration order and differs between kernels on ONE Deck. Found:"$'\n'"$(grep -nE 'amdgpu_bl[0-9]' "$fbv")"
pass "the verifier globs for the node rather than naming one -- no index survives into the target"

grep -qF -- "runuser -u testuser" "$fbv" ||
  fail_test "the verifier exercises the helper AS THE DESKTOP USER" \
    "as root it would take the helper's inner branch and prove nothing about the sudoers grant, which is half of what can break"
pass "the verifier goes through the desktop user, so sudo -n and the grant are exercised too"

grep -qF -- "rm -f ${POWER_LOGIND_DROPIN}" "$fbv" ||
  fail_test "the verifier DISARMS the power handler when the udev rule did not match" \
    "an armed HandlePowerKey with the ACPI duplicate still tagged is the re-suspend loop -- the one state the whole stage exists to avoid, on a device whose only escape is a ten-second hold"
pass "the verifier removes ${POWER_LOGIND_DROPIN} if the duplicate is still tagged -- it falls back, it does not just report"

# ...and only in that direction. Removing the udev rule instead would be the
# dangerous half (stage_power_button's own undo instructions say so).
! grep -qF -- "rm -f ${POWER_UDEV_RULE}" "$fbv" ||
  fail_test "the verifier never removes the udev rule" \
    "restoring the tags while the handler is armed is exactly the state the ordering of the writes is designed to make unreachable"
pass "and it never removes ${POWER_UDEV_RULE} -- the harmless half stays"

# Every check gates on its own artefact, so a machine that ran only one stage
# gets one verdict and 'note:' lines for the rest, not a false failure.
#
# ⚠️ THE THIRD CHECK'S GATE IS A DISJUNCTION, NOT A SINGLE FILE, and that is the
# point of it. stage-input-mapper writes three artefacts; the 2026-08-16 failure
# left TWO of them on disk and skipped the unit, so a gate on any one file would
# either miss the defect or cry wolf on a machine that never ran the stage. Any
# artefact present means the stage ran, and then the others' absence is a defect.
grep -qF -- "if [[ -x ${PRIV_WRITE_HELPER} ]]" "$fbv" ||
  fail_test "the brightness check gates on the helper existing" "$(cat "$fbv")"
grep -qF -- "if [[ -e ${POWER_LOGIND_DROPIN} ]]" "$fbv" ||
  fail_test "the power check gates on the drop-in existing" "$(cat "$fbv")"
grep -qF -- "if [[ ! -x ${MAPPER_BIN} && ! -e ${MAPPER_UNIT} && ! -d ${OSK_LIB_DIR} ]]" "$fbv" ||
  fail_test "the input-mapper check gates on ANY of stage-input-mapper's artefacts" "$(cat "$fbv")"
pass "each check gates on its own artefact, so an unrun stage is a 'note:' and not a failure"

# It runs the checks INDEPENDENTLY. `set -e` here would mean a machine with
# a brightness problem never gets its power-button verdict.
grep -qxF -- 'set -uo pipefail' "$fbv" ||
  fail_test "the verifier does not use set -e" \
    "the checks are independent and one failing must not hide the other; -u and pipefail are kept"
pass "the verifier is 'set -uo pipefail', so one failed check does not suppress the next"

# Behaviour: with no artefact present it says so, once per check, and exits 0.
chmod +x "$fbv"
fbv_rc=0
FBV_OUT=$(PATH="$stub_bin:$PATH" "$fbv" 2>&1) || fbv_rc=$?
[[ $fbv_rc -eq 0 ]] ||
  fail_test "with nothing installed the verifier passes" "rc=${fbv_rc}"$'\n'"$FBV_OUT"
[[ $(grep -c '^note:' <<<"$FBV_OUT") -eq 3 ]] ||
  fail_test "it says out loud that it had nothing to check, once per check" "$FBV_OUT"
pass "with no artefact installed it reports three 'note:' lines and exits 0 -- not silence"

# ---------------------------------------------------------------------------
# The power button, baked -- PROGRESS.md 5.38 D9
# ---------------------------------------------------------------------------
echo "# 9b. the power button, in a bake"

# On the wrong model a BAKE must SKIP, not fail: the installer runs every baked
# stage on whatever it is installing onto, including a QEMU VM, and a failed
# stage there is a false alarm in the install record. The refusal itself is
# unchanged -- nothing is written on any model but ${POWER_MODEL}.
run_chroot 'power_model_reject "not a Galileo" && echo REJECT-CONTINUED || echo REJECT-STOPPED'
out_has "REJECT-STOPPED" ||
  fail_test "power_model_reject stops the stage in chroot mode" "$OUT"
out_has "not a Galileo" ||
  fail_test "and says why" "$OUT"
pass "in a bake, an unsupported model warns and returns non-zero -- the stage skips instead of failing the install"

run_normal 'power_model_reject "not a Galileo"; echo SHOULD-NOT-REACH'
# shellcheck disable=SC2015  # `fail` exits, so this is a guard, not an if-then-else. shellcheck cannot know that
[[ $RC -ne 0 ]] && ! out_has "SHOULD-NOT-REACH" ||
  fail_test "outside a chroot the refusal is still fatal" "rc=${RC}"$'\n'"$OUT"
pass "outside a chroot it still exits non-zero -- a human on the wrong machine gets a refusal, as before"

# The stage's own skip path: it must say SKIPPED and it must not write.
pb_body=$(bash -c 'source "$1"; declare -f stage_power_button' _ "$SESSION_SH")
[[ $pb_body == *"stage-power-button: SKIPPED"* ]] ||
  fail_test "the stage names its skip" "a stage that returns 0 having done nothing must say so; the install record is the only place anyone will look"
pass "the skip path is named in the output, so 'ok' never silently means 'did nothing'"

# The sort-order assertion is the one thing that must survive every edit here:
# a drop-in that sorts at or before Omarchy's 10-ignore-power-button.conf is on
# disk, reads correctly, and does nothing.
ord_body=$(bash -c 'source "$1"; declare -f verify_power_button_ordering' _ "$SESSION_SH")
[[ $ord_body == *power_sorts_after* && $ord_body == *HandlePowerKey* ]] ||
  fail_test "the logind sort-order check is intact" "$ord_body"
pass "verify_power_button_ordering still proves ours sorts after every rival HandlePowerKey= assignment"

# ...and it still proves it against the PERSISTENT directories in a chroot.
# /run is the installer's, so it is excluded -- but excluding /etc or /usr/lib
# would remove the only place Omarchy's 10- file can be found.
[[ $ord_body == *'/run/'* ]] ||
  fail_test "the chroot arm names what it excluded" "$ord_body"
# It FILTERS, rather than emptying the list: dropping /etc or /usr/lib would
# remove the only place Omarchy's 10-ignore-power-button.conf can be found, and
# the sort-order proof would then pass by having nothing to compare against --
# a check passing for the wrong reason, which is the failure class this whole
# project keeps paying for.
[[ $ord_body == *'logind_dirs+='* && $ord_body == *'udev_dirs+='* ]] ||
  fail_test "the chroot arm filters rather than empties the directory list" "$ord_body"
# shellcheck disable=SC2016  # same as above: the chroot body must reach the guest unexpanded
run_chroot '
  ours=${POWER_LOGIND_DROPIN##*/}
  for d in "${POWER_LOGIND_DIRS[@]}"; do
    [[ $d == /run/* ]] && continue
    printf "KEPT %s\n" "$d"
  done
  power_sorts_after "$ours" 10-ignore-power-button.conf && echo SORTS-AFTER-OMARCHY
'
# shellcheck disable=SC2015  # `fail` exits; guard, not if-then-else
out_has "KEPT /etc/systemd/logind.conf.d" && out_has "SORTS-AFTER-OMARCHY" ||
  fail_test "the persistent directories survive the filter, and ours still wins there" "$OUT"
pass "the chroot arm drops only /run -- /etc and /usr/lib, where Omarchy's 10- drop-in lives, are still scanned, and zz- still beats 10-"

# The premise check defers rather than reading the installer's udev database...
prem_body=$(bash -c 'source "$1"; declare -f verify_power_button_premise' _ "$SESSION_SH")
[[ $prem_body == *"in_chroot"*"defer "*"return 0"* ]] ||
  fail_test "verify_power_button_premise defers in a chroot" "$prem_body"
pass "the premise check defers in a chroot instead of reading the installer kernel's udev database"

# ...but the CONSTANT self-check runs everywhere, because it is a statement
# about this file rather than about the machine.
prem_pre=$(sed -n '/^verify_power_button_premise/,/in_chroot/p' <<<"$prem_body")
[[ $prem_pre == *POWER_KEEP_ID_PATH* ]] ||
  fail_test "the self-consistency check runs before the chroot return" \
    "untagging the node the design keeps would leave logind watching nothing; that is a claim about the constants and must be checked everywhere. Body:"$'\n'"$prem_body"
pass "the 'never untag the keeper' self-check still runs in a chroot -- it is about the constants, not the machine"

echo "all deck-session.sh chroot-mode and backlight-discovery tests passed (${assertions} assertions)"
