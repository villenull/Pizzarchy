#!/usr/bin/env bash
# Unit tests for iso/overlay/patches/deck-install-invocation.patch -- the
# FAST-INSTALL cidata early-start block in .automated_script.sh.
#
# 2026-09-24 hardware feedback: on a real INTERACTIVE install (pre-installs=No,
# Steam=No) pressing Install on the summary failed immediately with
# "ERROR: cidata drive carries no 'preinstalls' file (want yes/no); refusing
# an unanswered variant" (and the same for 'gaming'). Cause: the block was
# guarded only by `[[ -f /root/user_configuration.json ]]`, and the
# interactive configurator's own write_user_files ALSO writes that file -- so
# the cidata-only block ran on the interactive path, found no
# /root/preinstalls, and exited 1. QEMU always takes the cidata branch, which
# is why no VM run ever hit it.
#
# Contract pinned here: the block runs ONLY when the cidata branch was
# actually taken (a variable set inside the `if omarchy-cidata-load` branch),
# never on the file's presence. On the interactive path the form already
# started the early stage and wrote/locked choices itself -- the block must do
# nothing there: no error, and no second `omarchy-deck-early start`.
#
# No VM, no Deck, no Docker: the patch is applied to a scratch copy of the
# pinned upstream .automated_script.sh, the block is extracted between its own
# markers, its absolute paths are rewritten into a temp dir, and both paths
# are executed with a stubbed early-stage binary.

set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
PATCH="$REPO_ROOT/iso/overlay/patches/deck-install-invocation.patch"
UPSTREAM_SCRIPT="$REPO_ROOT/iso/upstream/configs/airootfs/root/.automated_script.sh"

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; [[ -n ${2:-} ]] && printf '%s\n' "$2" >&2; exit 1; }

[[ -f $PATCH ]] || fail "deck-install-invocation.patch exists"
[[ -f $UPSTREAM_SCRIPT ]] || fail "pinned upstream .automated_script.sh exists (git submodule update --init iso/upstream)"
command -v patch >/dev/null 2>&1 || fail "no 'patch' binary available -- cannot verify the patch, not skipping silently"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "--- the patch applies cleanly to the pinned upstream -------------------"
mkdir -p "$work/tree/configs/airootfs/root" "$work/tree/configs"
cp "$UPSTREAM_SCRIPT" "$work/tree/configs/airootfs/root/.automated_script.sh"
# The patch touches three more files; stage those too so the apply is whole.
for f in airootfs/usr/local/bin/omarchy-cidata-load airootfs/usr/local/bin/omarchy-install-dashboard profiledef.sh; do
  src="$REPO_ROOT/iso/upstream/configs/$f"
  [[ -f $src ]] || fail "pinned upstream file configs/$f exists"
  mkdir -p "$work/tree/configs/$(dirname "$f")"
  cp "$src" "$work/tree/configs/$f"
done
if ! ( cd "$work/tree" && patch -p1 --batch --fuzz=0 <"$PATCH" >"$work/patch.log" 2>&1 ); then
  fail "deck-install-invocation.patch does NOT apply cleanly against the pinned iso/upstream" "$(cat "$work/patch.log")"
fi
patched="$work/tree/configs/airootfs/root/.automated_script.sh"
pass "deck-install-invocation.patch applies cleanly against the pinned iso/upstream"

echo "--- the block is gated on the cidata branch, not on the file -----------"
# The cidata branch must record that it was taken. awk, not grep-in-$():
# under set -euo pipefail a $(grep) with no match kills the run before fail.
taken_set=$(awk '/if \/usr\/local\/bin\/omarchy-cidata-load; then/,/^[[:space:]]*else$/ { print }' "$patched" | grep -c 'deck_cidata_taken=yes' || true)
[[ $taken_set -ge 1 ]] ||
  fail "the cidata branch must set a taken-marker (deck_cidata_taken=yes) -- otherwise NOTHING distinguishes it from the interactive path, which writes user_configuration.json too"
else_clears=$(awk '/^[[:space:]]*else$/,/^[[:space:]]*\.\/configurator$/ { print }' "$patched" | grep -c 'deck_cidata_taken=no' || true)
[[ $else_clears -ge 1 ]] ||
  fail "the interactive (else/configurator) branch must clear the taken-marker (deck_cidata_taken=no)"
gate_uses_marker=$(grep -c 'deck_cidata_taken' "$patched" || true)
[[ $gate_uses_marker -ge 3 ]] ||
  fail "the early-start block's gate must test the taken-marker (want the two assignments plus a gate use)" "found $gate_uses_marker mentions"
if grep -q 'OMARCHY_DECK_CIDATA_EARLY:-} != 0 ]] && \[\[ -f /root/user_configuration.json' "$patched"; then
  fail "the block is still gated ONLY on the file's presence -- the interactive configurator writes that file too, so this gate fires on the interactive path"
fi
pass "the cidata branch sets deck_cidata_taken=yes, the interactive branch clears it, and the block gates on it"

echo "--- block extraction ----------------------------------------------------"
# The block carries its own markers so this suite extracts exactly what ships.
awk '/BEGIN deck-cidata-early-block/,/END deck-cidata-early-block/' "$patched" >"$work/block.sh"
[[ -s $work/block.sh ]] ||
  fail "cannot find the deck-cidata-early-block markers in the patched file -- the behavioural tests below would assert nothing"
grep -q 'deck_cidata_taken' "$work/block.sh" ||
  fail "the extracted block does not test the taken-marker -- it would run on the interactive path"
pass "the shipped block extracts between its markers and tests the taken-marker"

# run_block <taken> <early-env> -- executes the shipped block with /root,
# /run choices, and the early-stage binary rewritten into temp dirs.
# Prints the block's exit code on stdout; the stub logs its calls.
run_block() {
  local taken=$1 early_env=${2:-} troot="$work/troot" cdir="$work/choices" sbin="$work/stubbin"
  mkdir -p "$troot" "$cdir" "$sbin"
  cat >"$sbin/omarchy-deck-early" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$DECK_TEST_EARLY_CALLS"
exit "${DECK_TEST_EARLY_RC:-0}"
EOF
  chmod +x "$sbin/omarchy-deck-early"
  rm -f "$work/early-calls.log"
  sed -e "s|/usr/local/bin/omarchy-deck-early|$sbin/omarchy-deck-early|g" \
      -e "s|/run/omarchy-deck/choices|$cdir|g" \
      -e "s|/root/|$troot/|g" \
      "$work/block.sh" >"$work/scenario.sh"
  local rc=0
  # The block calls `exit` -- run it in a child so this suite survives, with
  # `set +e` so a nonzero exit is a value, not a suite abort.
  set +e
  (
    export deck_cidata_taken="$taken"
    if [[ -n $early_env ]]; then
      export OMARCHY_DECK_CIDATA_EARLY="$early_env"
    else
      unset OMARCHY_DECK_CIDATA_EARLY
    fi
    export DECK_TEST_EARLY_CALLS="$work/early-calls.log" PATH="$sbin:/usr/bin:/bin"
    unset DECK_TEST_EARLY_RC
    bash "$work/scenario.sh" >"$work/scenario.out" 2>"$work/scenario.err"
  )
  rc=$?
  set -e
  printf '%s\n' "$rc"
}

write_cidata_json() {
  cat >"$work/troot/user_configuration.json" <<'EOF'
{"disk_config": {"device_modifications": [{"device": "/dev/nvme0n1"}]}}
EOF
}

echo "--- interactive path: configurator wrote the JSON, no choice files -----"
# The exact Deck failure: interactive install, configurator wrote
# user_configuration.json, no /root/preinstalls, no /root/gaming.
mkdir -p "$work/troot"
write_cidata_json
rc=$(run_block no)
[[ $rc -eq 0 ]] ||
  fail "interactive path (taken=no, JSON present, no choice files) must exit 0 -- the Deck failure was exit 1 here" "$(cat "$work/scenario.err")"
[[ ! -f $work/early-calls.log ]] ||
  fail "interactive path must NOT call omarchy-deck-early start again -- the form already started it" "$(cat "$work/early-calls.log")"
[[ ! -f $work/choices/locked ]] ||
  fail "interactive path must not write choices/locked -- the form owns choices/ there"
pass "interactive path: no error, no second early start, choices untouched (the Deck failure, fixed)"

echo "--- cidata path, happy: choice files land, early stage starts ----------"
mkdir -p "$work/troot"
write_cidata_json
printf 'no\n' >"$work/troot/preinstalls"
printf 'no\n' >"$work/troot/gaming"
rm -rf "$work/choices"
rc=$(run_block yes)
[[ $rc -eq 0 ]] || fail "cidata happy path must exit 0" "$(cat "$work/scenario.err")"
[[ -f $work/early-calls.log ]] || fail "cidata happy path must start the early stage"
grep -q '^start /dev/nvme0n1$' "$work/early-calls.log" ||
  fail "cidata happy path must 'start' the disk from the JSON" "$(cat "$work/early-calls.log")"
[[ $(cat "$work/choices/preinstalls") == "no" && $(cat "$work/choices/gaming") == "no" ]] ||
  fail "cidata happy path must copy the choice files into choices/"
[[ -f $work/choices/locked ]] || fail "cidata happy path must write choices/locked"
pass "cidata path unchanged: choices copied, locked, early stage started on the JSON's disk"

echo "--- cidata path, gaming=yes: network-ready fires ------------------------"
rm -rf "$work/choices"
printf 'no\n' >"$work/troot/preinstalls"
printf 'yes\n' >"$work/troot/gaming"
rc=$(run_block yes)
[[ $rc -eq 0 ]] || fail "cidata gaming=yes path must exit 0" "$(cat "$work/scenario.err")"
grep -q '^network-ready$' "$work/early-calls.log" ||
  fail "cidata gaming=yes must fire network-ready after start" "$(cat "$work/early-calls.log")"
pass "cidata gaming=yes still fires network-ready"

echo "--- cidata path, missing choice file: loud refusal (unchanged) ---------"
rm -rf "$work/choices"
rm -f "$work/troot/preinstalls" "$work/troot/gaming"
rc=$(run_block yes)
[[ $rc -ne 0 ]] || fail "cidata path with NO choice files must still refuse -- an unanswered variant is never a default"
grep -q "carries no 'preinstalls' file" "$work/scenario.err" ||
  fail "the refusal must name the missing file" "$(cat "$work/scenario.err")"
pass "cidata path with missing choice files still fails loudly (no silent default)"

echo "--- cidata path, invalid choice file: loud refusal (unchanged) ---------"
rm -rf "$work/choices"
printf 'maybe\n' >"$work/troot/preinstalls"
printf 'no\n' >"$work/troot/gaming"
rc=$(run_block yes)
[[ $rc -ne 0 ]] || fail "cidata path with an invalid choice must still refuse"
grep -q "is not exactly 'yes' or 'no'" "$work/scenario.err" ||
  fail "the refusal must quote the bad value" "$(cat "$work/scenario.err")"
pass "cidata path with an invalid choice still fails loudly"

echo "--- OMARCHY_DECK_CIDATA_EARLY=0 disables the block ----------------------"
rm -rf "$work/choices"
printf 'no\n' >"$work/troot/preinstalls"
printf 'no\n' >"$work/troot/gaming"
rc=$(run_block yes 0)
[[ $rc -eq 0 ]] || fail "CIDATA_EARLY=0 must skip the block with exit 0" "$(cat "$work/scenario.err")"
[[ ! -f $work/early-calls.log ]] || fail "CIDATA_EARLY=0 must not start the early stage"
pass "OMARCHY_DECK_CIDATA_EARLY=0 still disables the block"

echo "--- no user_configuration.json on the interactive path: still quiet -----"
rm -rf "$work/choices" "$work/troot/user_configuration.json"
rc=$(run_block no)
[[ $rc -eq 0 ]] || fail "interactive path without the JSON must exit 0"
[[ ! -f $work/early-calls.log ]] || fail "interactive path without the JSON must not start anything"
pass "interactive path without the JSON is quiet too"
