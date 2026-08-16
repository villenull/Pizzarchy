#!/usr/bin/env bash
# Unit tests for the T12 upstream-patch seam: omarchy-deck-apply-patches, its
# ALPM hook, its boot-time verify unit, and the two shipped patches.
#
# WHY THIS SUITE EXISTS
#
# The seam's product is not the patch. It is the ALARM. `omarchy-dev` owns
# /usr/share/omarchy/**, ships no backup=(), and reverts a local edit on
# upgrade with no .pacnew and exit 0 (docs/findings/T12-upstream-patch-seam.md,
# M2). The whole mechanism is worth nothing unless it goes loud when upstream
# moves -- and a guard nobody has seen fail is not a guard
# (docs/tasks/T5-fork-plan.md §5.4). So the negatives here are the point, and
# each of them asserts THREE things, not one:
#
#   1. the process exited non-zero WITH THE RIGHT CODE (3 = a patch is not ok,
#      4 = this machine is not set up, 2 = usage). "Non-zero" alone cannot tell
#      a refusal from a crash;
#   2. the machine-readable status is the ACCURATE diagnosis -- a renamed-away
#      file must report `missing_target`, never `drift`, because those two call
#      for completely different repairs;
#   3. the run actually STOPPED: the target file is byte-identical to what it
#      was before. A run that logged a complaint and patched anyway would
#      satisfy (1) and (2) and still be broken.
#
# ⚠️ Point (3) is here because the T5b agent's first round of assertions had
# nine survivors, all of the "logged the complaint and carried on" shape:
# they matched (exit non-zero + message present), which a hook that merely
# prints also satisfies.
#
# HERMETIC. No pacman, no Docker, no VM, no root, no network. The end-to-end
# proof that a real pacman upgrade re-applies the patches lives in
# test/t12-patch-seam-container-e2e.sh, which needs Docker and is not part of
# this suite.
#
# qmllint: this suite never depends on qt6-declarative being installed. It puts
# a qmllint SHIM on PATH which delegates to a real qmllint when one exists and
# otherwise emulates it. One test pins the emulation to the real tool as an
# oracle whenever the real tool is present, so the shim cannot drift into
# agreeing with itself.

set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
PKG_DIR="$REPO_ROOT/src/omarchy-deck-patches"
APPLIER="$PKG_DIR/omarchy-deck-apply-patches"
PATCH_DIR="$PKG_DIR/patches"
HOOK="$PKG_DIR/50-omarchy-deck-reapply-patches.hook"
UNIT="$PKG_DIR/omarchy-deck-patch-check.service"
FIXTURE="$REPO_ROOT/test/fixtures/t12-omarchy-f0020448ca87"
QML_REL="shell/plugins/lock/Service.qml"
LIMINE_REL="default/limine/limine.conf"
FOOT_REL="default/foot/screensaver.ini"
BROKEN_SENTINEL='@@T12-DELIBERATELY-BROKEN-QML@@'

pass() { printf 'ok - %s\n' "$1"; }
fail() {
  printf 'not ok - %s\n' "$1"
  [[ -n ${2:-} ]] && printf '%s\n' "$2" >&2
  exit 1
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

for f in "$APPLIER" "$HOOK" "$UNIT" "$FIXTURE/$QML_REL" "$FIXTURE/$LIMINE_REL"; do
  [[ -f $f ]] || fail "the payload exists" "missing: $f"
done
[[ -x $APPLIER ]] || fail "the applier is executable" "$APPLIER is not +x"
command -v jq >/dev/null 2>&1 || fail "jq is available" "this suite parses patch-state.json with jq"
pass "the omarchy-deck patch payload is present and the applier is executable"

# --- the qmllint shim -------------------------------------------------------
#
# Delegates to the real qmllint when there is one, so on a dev machine the QML
# post-condition is checked by the actual tool. Falls back to a sentinel-based
# emulation, so CI (ubuntu-latest, no qt6-declarative) exercises the same code
# paths deterministically instead of skipping them.

shim_bin="$work/bin"
mkdir -p "$shim_bin"

# ⚠️ qt6-declarative puts qmllint at /usr/lib/qt6/bin/qmllint, NOT on PATH; a
# /usr/bin/qmllint, where one exists, is usually qt5-declarative's -- a
# different parser for a different Qt. Prefer the Qt6 tool, because Qt6 is the
# engine Quickshell loads the file with. (Measured 2026-08-12 in a clean
# archlinux container; docs/findings/T12-upstream-patch-seam.md §7 said only
# "qmllint is present", which is not the same claim.)
real_qmllint=""
for cand in /usr/lib/qt6/bin/qmllint /usr/lib/qt6/bin/qmllint6; do
  if [[ -x $cand ]]; then
    real_qmllint=$cand
    break
  fi
done
if [[ -z $real_qmllint ]]; then real_qmllint=$(command -v qmllint 2>/dev/null || true); fi

cat >"$shim_bin/qmllint" <<SHIM
#!/usr/bin/env bash
set -uo pipefail
real='$real_qmllint'
if [[ -n \$real && -x \$real ]]; then exec "\$real" "\$@"; fi
for f in "\$@"; do
  [[ -f \$f ]] || { printf 'shim: no such file: %s\n' "\$f" >&2; exit 255; }
  if grep -qF '$BROKEN_SENTINEL' "\$f"; then
    printf '%s: syntax error (shim)\n' "\$f" >&2
    exit 255
  fi
done
exit 0
SHIM
chmod +x "$shim_bin/qmllint"
export PATH="$shim_bin:$PATH"
# Drive the applier's linter resolution through the shim explicitly. Without
# this the resolver would prefer an absolute /usr/lib/qt6/bin/qmllint on
# machines that have one and PATH's shim on machines that do not, and the
# negative cases below would mean different things on different machines.
export OMARCHY_DECK_QMLLINT="$shim_bin/qmllint"

# --- helpers ----------------------------------------------------------------

# ⚠️ These run inside $( ), i.e. in a SUBSHELL, so a counter incremented here
# would be lost to the parent and every call would return the same directory --
# quietly making later tests run against a tree an earlier test had already
# modified. mktemp -d is the fix precisely because it needs no shared state.
new_root() {
  local dst
  dst=$(mktemp -d "$work/root.XXXXXX")
  cp -a "$FIXTURE/shell" "$FIXTURE/default" "$dst/"
  printf '%s' "$dst"
}

# Globals set by run_applier, deliberately: every assertion below reads them.
rc=0
out=""
state=""
run_applier() {
  local root=$1 pdir=$2
  shift 2
  state="$root.state.json"
  rc=0
  out=$("$APPLIER" --root "$root" --patch-dir "$pdir" --state-file "$state" "$@" 2>&1) || rc=$?
}

status_of() { jq -r --arg p "$1" '.patches[] | select(.patch==$p) | .status' "$state"; }
action_of() { jq -r --arg p "$1" '.patches[] | select(.patch==$p) | .action' "$state"; }
overall_of() { jq -r '.overall' "$state"; }
sha_of() { sha256sum -- "$1" | cut -d' ' -f1; }

# Build a scratch patch directory seeded from the shipped one, so the negative
# fixtures differ from production in exactly one way each.
new_patch_dir() {
  local dst
  dst=$(mktemp -d "$work/pd.XXXXXX")
  cp "$PATCH_DIR"/* "$dst/"
  printf '%s' "$dst"
}

# --- 0. the fixture is the real pinned upstream, and is kept honest ---------

runtime_pin=$(cat "$REPO_ROOT/iso/RUNTIME")
pin_sha=${runtime_pin##*@}
[[ -n $pin_sha ]] || fail "iso/RUNTIME names a ref" "got: $runtime_pin"
[[ "$(basename -- "$FIXTURE")" == "t12-omarchy-$pin_sha" ]] ||
  fail "the fixture tree matches the RUNTIME pin" \
    "iso/RUNTIME says $pin_sha but the fixture directory is $(basename -- "$FIXTURE"); refetch the fixture at the new ref (see its PROVENANCE) and re-run"
pass "the upstream fixture is pinned to iso/RUNTIME's ref ($pin_sha)"

# The fixture must be UNPATCHED upstream. A fixture that already carried our
# values would make the clean-apply test vacuous.
grep -qE '^    interval: 5000$' "$FIXTURE/$QML_REL" ||
  fail "the fixture is unpatched upstream QML" "no 'interval: 5000' in $FIXTURE/$QML_REL"
if grep -qE '^interface_rotation:' "$FIXTURE/$LIMINE_REL"; then
  fail "the fixture is unpatched upstream limine.conf" "it already carries interface_rotation"
fi
grep -qE '^font=.*:size=18$' "$FIXTURE/$FOOT_REL" ||
  fail "the fixture is unpatched upstream screensaver.ini" "no 'size=18' in $FIXTURE/$FOOT_REL"
pass "the fixture is upstream's content, not a pre-patched copy"

# --- 1. clean apply ---------------------------------------------------------

root=$(new_root)
run_applier "$root" "$PATCH_DIR"
[[ $rc -eq 0 ]] || fail "a clean apply exits 0" "rc=$rc
$out"
[[ $(overall_of) == ok ]] || fail "a clean apply records overall=ok" "$(cat "$state")"
[[ $(status_of 0010-lock-blank-timer-20s.patch) == ok ]] || fail "0010 is ok" "$(cat "$state")"
[[ $(status_of 0020-limine-interface-rotation.patch) == ok ]] || fail "0020 is ok" "$(cat "$state")"
[[ $(action_of 0010-lock-blank-timer-20s.patch) == applied ]] ||
  fail "0010 records action=applied on the first run" "$(cat "$state")"
[[ $(grep -cE '^    interval: 20000$' "$root/$QML_REL") -eq 1 ]] ||
  fail "the lock blank timer is 20000 exactly once" "$(grep -n 'interval:' "$root/$QML_REL")"
if grep -qE '^    interval: 5000$' "$root/$QML_REL"; then
  fail "the old 5000 literal is gone" "still present"
fi
[[ $(grep -cE '^interface_rotation: 90$' "$root/$LIMINE_REL") -eq 1 ]] ||
  fail "the limine template carries interface_rotation: 90 exactly once" "$(cat "$root/$LIMINE_REL")"
[[ $(status_of 0030-screensaver-font-fits-panel.patch) == ok ]] || fail "0030 is ok" "$(cat "$state")"
# 🔴 READ FROM THE PATCH, NOT RESTATED. This asserted a literal `size=14` and
# went red the moment the operator asked for a smaller logo -- a test that pins
# a value it does not own turns every retune into a false failure, and (worse,
# and seen twice today) can keep a wrong value alive by making the fix look
# like a break. The patch is the source of truth for what the patch installs.
foot_size=$(sed -n 's/^+font=JetBrainsMono Nerd Font:size=\([0-9][0-9]*\)$/\1/p' \
  "$REPO_ROOT/src/omarchy-deck-patches/patches/0030-screensaver-font-fits-panel.patch" | head -1)
[[ -n $foot_size ]] ||
  fail "could not read the font size out of 0030's patch -- the assertion below would be vacuous"
[[ $(grep -cE "^font=JetBrainsMono Nerd Font:size=${foot_size}\$" "$root/$FOOT_REL") -eq 1 ]] ||
  fail "the screensaver terminal font is size=${foot_size} exactly once" "$(cat "$root/$FOOT_REL")"
if grep -qE '^font=.*:size=18$' "$root/$FOOT_REL"; then
  fail "the old size=18 is gone" "still present"
fi
pass "all three shipped patches apply cleanly to the real pinned upstream tree"

# The patch must be surgical. 1 line changed in a 471-line file, 1 added in a
# 20-line one: a patch that rewrote the file wholesale would still satisfy the
# assertions above.
qml_changed=$(diff -U0 "$FIXTURE/$QML_REL" "$root/$QML_REL" | grep -cE '^[+-][^+-]' || true)
[[ $qml_changed -eq 2 ]] ||
  fail "0010 changes exactly one line" "$qml_changed +/- lines"
limine_changed=$(diff -U0 "$FIXTURE/$LIMINE_REL" "$root/$LIMINE_REL" | grep -cE '^[+-][^+-]' || true)
[[ $limine_changed -eq 1 ]] ||
  fail "0020 adds exactly one line" "$limine_changed +/- lines"
foot_changed=$(diff -U0 "$FIXTURE/$FOOT_REL" "$root/$FOOT_REL" | grep -cE '^[+-][^+-]' || true)
[[ $foot_changed -eq 2 ]] ||
  fail "0030 changes exactly one line" "$foot_changed +/- lines"
pass "the patches are surgical: 1 line changed in Service.qml, 1 added in limine.conf, 1 changed in screensaver.ini"

# --- 2. idempotence ---------------------------------------------------------

qml_sha_after_first=$(sha_of "$root/$QML_REL")
limine_sha_after_first=$(sha_of "$root/$LIMINE_REL")
foot_sha_after_first=$(sha_of "$root/$FOOT_REL")
run_applier "$root" "$PATCH_DIR"
[[ $rc -eq 0 ]] || fail "a second run exits 0" "rc=$rc
$out"
[[ $(action_of 0010-lock-blank-timer-20s.patch) == already-applied ]] ||
  fail "the second run recognises the patch as already applied" "$(cat "$state")"
[[ $(sha_of "$root/$QML_REL") == "$qml_sha_after_first" ]] ||
  fail "the second run changes nothing in Service.qml" "sha moved"
[[ $(sha_of "$root/$LIMINE_REL") == "$limine_sha_after_first" ]] ||
  fail "the second run changes nothing in limine.conf" "sha moved"
[[ $(sha_of "$root/$FOOT_REL") == "$foot_sha_after_first" ]] ||
  fail "the second run changes nothing in screensaver.ini" "sha moved"
run_applier "$root" "$PATCH_DIR"
[[ $rc -eq 0 && $(sha_of "$root/$QML_REL") == "$qml_sha_after_first" ]] ||
  fail "a third run is still a no-op" "rc=$rc"
pass "re-running is a no-op: exit 0, action=already-applied, files byte-identical"

# --- 2b. --verify on an already-patched tree --------------------------------

run_applier "$root" "$PATCH_DIR" --verify
[[ $rc -eq 0 ]] || fail "--verify on a patched tree exits 0" "rc=$rc
$out"
[[ $(overall_of) == ok ]] || fail "--verify on a patched tree records ok" "$(cat "$state")"
pass "--verify reports ok against a correctly patched tree"

# --- 3. DRIFT: upstream retuned the literal (real commit 35a6940) -----------
#
# 30000 -> 3000 -> 5000 in two months. This fixture is upstream's own 3000.
# This is the case a `sed -i` would silently no-op on.

root=$(new_root)
sed -i 's/^    interval: 5000$/    interval: 3000/' "$root/$QML_REL"
before=$(sha_of "$root/$QML_REL")
run_applier "$root" "$PATCH_DIR"
[[ $rc -eq 3 ]] || fail "drift exits 3 (a patch is not ok)" "rc=$rc
$out"
[[ $(status_of 0010-lock-blank-timer-20s.patch) == drift ]] ||
  fail "drift is diagnosed as drift" "status=$(status_of 0010-lock-blank-timer-20s.patch)
$out"
[[ $(status_of 0010-lock-blank-timer-20s.patch) != missing_target ]] ||
  fail "drift is not misreported as a missing file" "$(cat "$state")"
grep -q "$QML_REL" <<<"$out" || fail "the drift message names the file" "$out"
[[ $(sha_of "$root/$QML_REL") == "$before" ]] ||
  fail "🔴 drift leaves the target file UNTOUCHED" \
    "the applier modified Service.qml despite reporting drift -- it complained and carried on"
grep -qE '^    interval: 3000$' "$root/$QML_REL" ||
  fail "the upstream value survives a drift" "the file no longer carries upstream's 3000"
[[ $(overall_of) == failed ]] || fail "drift records overall=failed" "$(cat "$state")"
pass "upstream's real 3000 retune is caught: exit 3, status=drift, file untouched"

# One failed patch must not silence the others: 0020 is unaffected here and
# must still have been applied. A loop that bailed on the first failure would
# leave the Limine template unpatched with no separate signal.
[[ $(status_of 0020-limine-interface-rotation.patch) == ok ]] ||
  fail "an unrelated patch still runs after a drift" "$(cat "$state")"
grep -qE '^interface_rotation: 90$' "$root/$LIMINE_REL" ||
  fail "the unrelated patch actually landed" "$(cat "$root/$LIMINE_REL")"
pass "a drifted patch does not stop the remaining patches from being applied"

# --- 4. MISSING TARGET: upstream renamed the file away ----------------------
#
# The case Type=Path would have missed entirely (T12 finding M3). Here the hook
# still fires, so the applier is the thing that has to notice -- and it must say
# "the file is gone", not "the patch does not apply".

root=$(new_root)
mv "$root/$QML_REL" "$root/shell/plugins/lock/LockService.qml"
run_applier "$root" "$PATCH_DIR"
[[ $rc -eq 3 ]] || fail "a renamed-away target exits 3" "rc=$rc
$out"
[[ $(status_of 0010-lock-blank-timer-20s.patch) == missing_target ]] ||
  fail "🔴 a renamed-away target is diagnosed as missing_target" \
    "status=$(status_of 0010-lock-blank-timer-20s.patch) -- a missing file must never be reported as a failed patch
$out"
grep -q "$QML_REL" <<<"$out" || fail "the missing_target message names the path" "$out"
grep -qi 'renamed or removed' <<<"$out" ||
  fail "the missing_target message explains what happened" "$out"
[[ ! -f $root/$QML_REL ]] ||
  fail "the applier did not resurrect the file" "it created $QML_REL"
pass "a renamed-away target is reported as missing_target, not as drift"

# --- 5. POST-CONDITION: the patch applies but breaks the QML ----------------

pd=$(new_patch_dir)
rm -f "$pd"/0010-* "$pd"/0020-*
brk="$work/brk"
mkdir -p "$brk/a/shell/plugins/lock" "$brk/b/shell/plugins/lock"
cp "$FIXTURE/$QML_REL" "$brk/a/$QML_REL"
sed "s|^    repeat: false$|    repeat: false ((( $BROKEN_SENTINEL|" "$FIXTURE/$QML_REL" >"$brk/b/$QML_REL"
[[ "$(sha_of "$brk/a/$QML_REL")" != "$(sha_of "$brk/b/$QML_REL")" ]] ||
  fail "the broken-QML fixture actually differs" "the sed matched nothing"
(cd "$brk" && diff -u --label "a/$QML_REL" --label "b/$QML_REL" "a/$QML_REL" "b/$QML_REL" >"$pd/0099-break-qml.patch") || true
[[ -s $pd/0099-break-qml.patch ]] || fail "the broken-QML patch was generated" "empty patch"
cat >"$pd/0099-break-qml.meta" <<META
requirement: test fixture only
description: deliberately produces QML the linter must reject
target: $QML_REL
qmllint: $QML_REL
META

root=$(new_root)
run_applier "$root" "$pd"
[[ $rc -eq 3 ]] || fail "a patch that breaks the QML exits 3" "rc=$rc
$out"
[[ $(status_of 0099-break-qml.patch) == postcondition_failed ]] ||
  fail "a broken-QML result is diagnosed as postcondition_failed" \
    "status=$(status_of 0099-break-qml.patch)
$out"
[[ $(action_of 0099-break-qml.patch) == applied ]] ||
  fail "the state records that the patch DID apply before the post-condition failed" "$(cat "$state")"
grep -qiE 'qmllint \(.*\) rejected' <<<"$out" ||
  fail "the message says which qmllint binary rejected the file" "$out"
pass "a patch that applies but breaks the QML fails on qmllint (exit 3)"

# --- 5b. the qmllint shim agrees with the real tool, when there is one ------

if [[ -n $real_qmllint ]]; then
  if "$real_qmllint" "$root/$QML_REL" >/dev/null 2>&1; then
    fail "the real qmllint rejects the deliberately broken file" "it exited 0"
  fi
  good=$(new_root)
  run_applier "$good" "$PATCH_DIR"
  [[ $rc -eq 0 ]] || fail "the real qmllint accepts the correctly patched file" "rc=$rc
$out"
  pass "the real qmllint agrees with the shim: 0 on the patched file, non-zero on the broken one"
else
  pass "qmllint is not installed here; the shim emulated it (no oracle available on this machine)"
fi

# --- 6. POST-CONDITION: assert_count is wrong -------------------------------

pd=$(new_patch_dir)
# Rewrite the .meta outright rather than sed-ing the shipped one: a sed that
# stopped matching after a future edit would leave the ORIGINAL, correct
# assertion in place and this negative test would pass while testing nothing.
{
  printf 'requirement: test fixture only\n'
  printf 'description: expects the new literal TWICE, which it never is\n'
  printf 'target: %s\n' "$QML_REL"
  printf 'assert_count: %s|^    interval: 20000$|2\n' "$QML_REL"
} >"$pd/0010-lock-blank-timer-20s.meta"
rm -f "$pd"/0020-*
root=$(new_root)
run_applier "$root" "$pd"
[[ $rc -eq 3 ]] || fail "a failed assert_count exits 3" "rc=$rc
$out"
[[ $(status_of 0010-lock-blank-timer-20s.patch) == postcondition_failed ]] ||
  fail "a wrong occurrence count is diagnosed as postcondition_failed" "$(cat "$state")"
grep -q 'expected 2 occurrence' <<<"$out" ||
  fail "the message reports expected vs found" "$out"
pass "an occurrence-count post-condition that does not hold fails the run (exit 3)"

# --- 6b. an assert_count regex containing alternation is not truncated ------
#
# The separator is `|`, and so is ERE alternation. Splitting on every `|` would
# truncate `(90|0)` to `(90`, which grep rejects -- and if that error were
# swallowed the assertion would silently evaluate to "0 matches" and the check
# would pass for the wrong reason.

pd=$(new_patch_dir)
rm -f "$pd"/0010-*
{
  printf 'requirement: test fixture only\n'
  printf 'description: alternation in the expected pattern\n'
  printf 'target: %s\n' "$LIMINE_REL"
  printf 'assert_count: %s|^interface_rotation: (90|0)$|1\n' "$LIMINE_REL"
} >"$pd/0020-limine-interface-rotation.meta"
root=$(new_root)
run_applier "$root" "$pd"
[[ $rc -eq 0 ]] || fail "an assert_count regex may contain alternation" "rc=$rc
$out"
pass "assert_count splits on the first and last '|' only, so ERE alternation survives"

# --- 6c. an assert_count regex that grep cannot evaluate is LOUD ------------

pd=$(new_patch_dir)
rm -f "$pd"/0010-*
{
  printf 'requirement: test fixture only\n'
  printf 'description: an expression grep cannot compile\n'
  printf 'target: %s\n' "$LIMINE_REL"
  printf 'assert_count: %s|interface_rotation: (270|0\n' "$LIMINE_REL"
} >"$pd/0020-limine-interface-rotation.meta"
root=$(new_root)
run_applier "$root" "$pd"
[[ $rc -eq 3 ]] || fail "an uncompilable assert_count expression exits 3" "rc=$rc
$out"
grep -qi 'did NOT run' <<<"$out" ||
  fail "an assertion that could not be evaluated says so" \
    "it must not be reported as '0 occurrences found' -- that is the check passing for the wrong reason
$out"
pass "an assert_count expression grep cannot compile is reported as un-run, not as zero matches"

# --- 7. bad_meta, four shapes, none of which may patch anything -------------

assert_bad_meta() {
  local label=$1 pd=$2 patch=$3 expect_msg=$4
  local r before_qml before_limine
  r=$(new_root)
  before_qml=$(sha_of "$r/$QML_REL")
  before_limine=$(sha_of "$r/$LIMINE_REL")
  run_applier "$r" "$pd"
  [[ $rc -eq 3 ]] || fail "$label exits 3" "rc=$rc
$out"
  [[ $(status_of "$patch") == bad_meta ]] ||
    fail "$label is diagnosed as bad_meta" "status=$(status_of "$patch")
$out"
  grep -qi "$expect_msg" <<<"$out" || fail "$label explains itself" "wanted /$expect_msg/ in:
$out"
  [[ $(sha_of "$r/$QML_REL") == "$before_qml" && $(sha_of "$r/$LIMINE_REL") == "$before_limine" ]] ||
    fail "🔴 $label patches NOTHING" "a malformed .meta must refuse, not apply and then complain"
  pass "$label: exit 3, status=bad_meta, no file touched"
}

pd=$(new_patch_dir)
rm -f "$pd"/0020-*
printf 'target: %s\nqmlint: %s\n' "$QML_REL" "$QML_REL" >"$pd/0010-lock-blank-timer-20s.meta"
assert_bad_meta "a typo'd post-condition key ('qmlint')" "$pd" 0010-lock-blank-timer-20s.patch "unknown key"

pd=$(new_patch_dir)
rm -f "$pd"/0020-*
printf 'target: %s\ndescription: no post-conditions at all\n' "$QML_REL" >"$pd/0010-lock-blank-timer-20s.meta"
assert_bad_meta "a .meta with no post-conditions" "$pd" 0010-lock-blank-timer-20s.patch "no post-conditions"

pd=$(new_patch_dir)
rm -f "$pd"/0020-* "$pd/0010-lock-blank-timer-20s.meta"
assert_bad_meta "a patch with no .meta sibling" "$pd" 0010-lock-blank-timer-20s.patch "no .meta sibling"

pd=$(new_patch_dir)
rm -f "$pd"/0020-*
{
  printf 'target: %s\n' "$LIMINE_REL"
  printf 'assert_count: %s|^interface_rotation: 270$|1\n' "$LIMINE_REL"
} >"$pd/0010-lock-blank-timer-20s.meta"
assert_bad_meta "a .meta whose target disagrees with the patch" "$pd" 0010-lock-blank-timer-20s.patch "but the patch touches"

# --- 8. --verify never writes ----------------------------------------------

root=$(new_root)
before_qml=$(sha_of "$root/$QML_REL")
before_limine=$(sha_of "$root/$LIMINE_REL")
run_applier "$root" "$PATCH_DIR" --verify
[[ $rc -eq 3 ]] || fail "--verify on an unpatched tree exits 3" "rc=$rc
$out"
[[ $(status_of 0010-lock-blank-timer-20s.patch) == pending ]] ||
  fail "an unapplied patch is diagnosed as pending under --verify" "$(cat "$state")"
[[ $(sha_of "$root/$QML_REL") == "$before_qml" && $(sha_of "$root/$LIMINE_REL") == "$before_limine" ]] ||
  fail "🔴 --verify modifies nothing" "the boot-time check repaired the tree instead of reporting it"
pass "--verify reports pending and leaves every target file untouched (exit 3)"

# --- 9. environment failures are exit 4, and each names its own cause -------

root=$(new_root)
rc=0
out=$("$APPLIER" --root "$root" --patch-dir "$work/nope" --state-file "$work/s.json" 2>&1) || rc=$?
[[ $rc -eq 4 ]] || fail "a missing patch directory exits 4, not 3" "rc=$rc
$out"
grep -qi 'patch directory does not exist' <<<"$out" ||
  fail "a missing patch directory says so" "it must not be reported as a failed patch
$out"
pass "a missing patch directory is an environment error (exit 4), not a patch failure"

rc=0
out=$("$APPLIER" --root "$work/no-such-root" --patch-dir "$PATCH_DIR" --state-file "$work/s.json" 2>&1) || rc=$?
[[ $rc -eq 4 ]] || fail "a missing patch root exits 4" "rc=$rc
$out"
grep -qi 'patch root does not exist' <<<"$out" || fail "a missing root says so" "$out"
pass "a missing patch root is an environment error (exit 4)"

mkdir -p "$work/emptypd"
rc=0
out=$("$APPLIER" --root "$root" --patch-dir "$work/emptypd" --state-file "$work/s.json" 2>&1) || rc=$?
[[ $rc -eq 4 ]] || fail "🔴 an EMPTY patch directory exits 4" \
  "rc=$rc -- 'no patches, nothing to do, exit 0' is the silent-success bug in miniature
$out"
grep -qi 'payload is incomplete' <<<"$out" || fail "an empty patch directory says so" "$out"
pass "an empty patch directory fails loudly instead of reporting success"

rc=0
out=$("$APPLIER" --root "$root" --patch-dir "$PATCH_DIR" --frobnicate 2>&1) || rc=$?
[[ $rc -eq 2 ]] || fail "an unknown argument exits 2" "rc=$rc
$out"
pass "an unknown argument is a usage error (exit 2)"

# --- 10. an unrunnable qmllint is a failure, not a skip ---------------------
#
# If a missing or unusable linter silently counted as a passed post-condition,
# every machine without qt6-declarative would report ok while shipping QML
# nothing had validated.

pd=$(new_patch_dir)
rm -f "$pd"/0020-*
root=$(new_root)
rc=0
out=$(OMARCHY_DECK_QMLLINT="$work/there-is-no-qmllint-here" \
  "$APPLIER" --root "$root" --patch-dir "$pd" --state-file "$root.state.json" 2>&1) || rc=$?
state="$root.state.json"
[[ $rc -eq 3 ]] || fail "🔴 an unusable qmllint fails the run" \
  "rc=$rc -- an unrunnable post-condition must never count as a passed one
$out"
[[ $(status_of 0010-lock-blank-timer-20s.patch) == postcondition_failed ]] ||
  fail "an unusable qmllint is diagnosed as postcondition_failed" "$(cat "$state")"
grep -qi 'could NOT be checked' <<<"$out" ||
  fail "the message says the check did not run" "$out"
grep -qi 'refusing to silently lint with some other binary' <<<"$out" ||
  fail "🔴 a named-but-unusable linter is not silently replaced by another" \
    "falling back to whatever is on PATH would lint with a different Qt than the one that loads the file
$out"
pass "a named qmllint that cannot be run fails the run and is never silently swapped out"

# The resolver must search qt6-declarative's install DIRECTORY, and that
# directory must beat PATH. Proven functionally, not by grepping the source: a
# grep cannot tell code that searches /usr/lib/qt6/bin from a comment that
# mentions it, and the pre-correction bug was exactly a bare `command -v`.
fakeqt="$work/fakeqt"
mkdir -p "$fakeqt"
cat >"$fakeqt/qmllint" <<FAKE
#!/usr/bin/env bash
printf 'used-the-directory-search\n' >>"$work/qmllint-marker"
exit 0
FAKE
chmod +x "$fakeqt/qmllint"
rm -f "$work/qmllint-marker"
pd=$(new_patch_dir)
rm -f "$pd"/0020-*
root=$(new_root)
rc=0
out=$(env -u OMARCHY_DECK_QMLLINT OMARCHY_DECK_QMLLINT_DIRS="$fakeqt" \
  "$APPLIER" --root "$root" --patch-dir "$pd" --state-file "$root.state.json" 2>&1) || rc=$?
[[ $rc -eq 0 ]] || fail "the directory-searched qmllint was used" "rc=$rc
$out"
[[ -f $work/qmllint-marker ]] ||
  fail "🔴 the resolver searches qt6-declarative's install DIRECTORY before PATH" \
    "the linter in the searched directory never ran, so PATH won -- qt6-declarative installs /usr/lib/qt6/bin/qmllint and puts NOTHING on PATH, and a /usr/bin/qmllint (where one exists) is qt5-declarative's, a different parser for a different Qt"
pass "the qmllint resolver searches its directory list first, and that beats PATH"

# ...and the default of that list is the real Qt6 location.
grep -qE '^readonly QMLLINT_DIRS=\$\{OMARCHY_DECK_QMLLINT_DIRS:-/usr/lib/qt6/bin\}$' "$APPLIER" ||
  fail "the default search directory is qt6-declarative's" \
    "the override exists for the test above; the DEFAULT is what ships to the Deck"
pass "the default qmllint search directory is /usr/lib/qt6/bin"

# The no-linter-anywhere case, exercised through the real resolver rather than
# the override. Only meaningful on a machine with no absolute Qt6 candidate;
# say so out loud rather than pretending otherwise.
if [[ ! -x /usr/lib/qt6/bin/qmllint && ! -x /usr/lib/qt6/bin/qmllint6 ]]; then
  nolint="$work/nolint"
  mkdir -p "$nolint"
  for t in bash sh env git sha256sum cut grep wc tr date mktemp mkdir mv chmod basename dirname awk sort cat sed diff; do
    t_path=$(command -v "$t" 2>/dev/null || true)
    if [[ -n $t_path ]]; then ln -sf "$t_path" "$nolint/$t"; fi
  done
  [[ -x $nolint/git ]] || fail "the reduced PATH still has git" "cannot build the no-qmllint environment"
  [[ ! -e $nolint/qmllint ]] || fail "the reduced PATH has no qmllint" "the case under test is not set up"
  pd=$(new_patch_dir)
  rm -f "$pd"/0020-*
  root=$(new_root)
  rc=0
  out=$(env -i PATH="$nolint" "$APPLIER" --root "$root" --patch-dir "$pd" --state-file "$root.state.json" 2>&1) || rc=$?
  state="$root.state.json"
  [[ $rc -eq 3 ]] || fail "🔴 no qmllint anywhere fails the run" "rc=$rc
$out"
  grep -qi 'qmllint is not installed' <<<"$out" || fail "the resolver says what it looked for" "$out"
  grep -q 'qt6-declarative' <<<"$out" || fail "the message names the package to install" "$out"
  pass "with no qmllint anywhere the run fails and names qt6-declarative"
else
  pass "this machine has /usr/lib/qt6/bin/qmllint, so the no-linter-anywhere path is covered by the override case above"
fi

# --- 11. --from-hook says what the failure MEANS ----------------------------

root=$(new_root)
sed -i 's/^    interval: 5000$/    interval: 3000/' "$root/$QML_REL"
run_applier "$root" "$PATCH_DIR" --from-hook
[[ $rc -eq 3 ]] || fail "--from-hook still exits non-zero on drift" "rc=$rc"
[[ $(jq -r '.invocation' "$state") == hook ]] || fail "--from-hook is recorded in the state file" "$(cat "$state")"
grep -qi 'are NOT in effect' <<<"$out" ||
  fail "the hook path explains the consequence, not just the error" \
    "a pacman transcript reader must learn that the Deck customisations are off
$out"
pass "--from-hook records invocation=hook and spells out the consequence"

# --- 12. the state file is valid JSON and its overall matches its rows ------

root=$(new_root)
run_applier "$root" "$PATCH_DIR"
jq -e . "$state" >/dev/null || fail "patch-state.json is valid JSON" "$(cat "$state")"
[[ $(jq -r '.schema' "$state") == 1 ]] || fail "the state file declares its schema" "$(cat "$state")"
# Derived from the shipped set, not a literal: the point is "a row per patch",
# and a hard-coded 2 turned that into "exactly two patches exist" the first time
# a third one shipped.
shipped_patches=$(find "$PATCH_DIR" -name '*.patch' | wc -l)
[[ $(jq -r '.patches | length' "$state") -eq "$shipped_patches" ]] ||
  fail "the state file has a row per patch ($shipped_patches shipped)" "$(cat "$state")"
if jq -e '.patches[] | select(.requirement == "" or .requirement == null)' "$state" >/dev/null; then
  fail "every patch row names its owning requirement" "a stale-Deck reader must learn WHICH requirement is off"
fi
[[ $(jq -r '.generated' "$state") =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] ||
  fail "the state file is timestamped" "$(cat "$state")"
pass "patch-state.json is valid JSON, one row per patch, each naming its requirement"

# A detail string containing quotes and newlines must not produce invalid JSON:
# the drift path embeds git's own multi-line reject text verbatim.
root=$(new_root)
sed -i 's/^    interval: 5000$/    interval: 3000/' "$root/$QML_REL"
run_applier "$root" "$PATCH_DIR"
jq -e . "$state" >/dev/null ||
  fail "a multi-line git reject does not corrupt the state file" "$(cat "$state")"
[[ $(jq -r '.overall' "$state") == failed ]] || fail "overall is failed when a row failed" "$(cat "$state")"
pass "git's multi-line reject text is JSON-escaped into the state file intact"

# Quotes and backslashes too, not just newlines. A detail string is built from
# text the applier does not control (a .meta key, git's own output), and an
# unescaped " turns patch-state.json into a file nothing downstream can read --
# silently, because nothing downstream would be looking.
pd=$(new_patch_dir)
rm -f "$pd"/0020-*
printf 'target: %s\nqm"lint\\back: %s\n' "$QML_REL" "$QML_REL" >"$pd/0010-lock-blank-timer-20s.meta"
root=$(new_root)
run_applier "$root" "$pd"
[[ $rc -eq 3 ]] || fail "a .meta key containing a quote is rejected" "rc=$rc
$out"
jq -e . "$state" >/dev/null ||
  fail "🔴 a quote or backslash in a detail string does not corrupt patch-state.json" \
    "the state file is not valid JSON:
$(cat "$state")"
[[ $(jq -r '.patches[0].detail' "$state") == *'qm"lint\back'* ]] ||
  fail "the offending key survives escaping intact" "$(jq -r '.patches[0].detail' "$state")"
pass "quotes and backslashes in a detail string are escaped, and round-trip through jq"

# --- 13. the applier must not touch the shell ------------------------------
#
# Relaunching Quickshell from a pacman hook re-runs checkStrandedLock(), the one
# code path docs/findings/T9-delta-classification.md classifies BREAKS US --
# possibly while the device is locked (T12 finding §3.3, last paragraph).

code=$(grep -vE '^[[:space:]]*#' "$APPLIER")
if grep -nEi '(^|[^-[:alnum:]])(quickshell|hyprctl|pkill|killall|loginctl)([^-[:alnum:]]|$)|systemctl[[:space:]]+(restart|start|stop|reload)|omarchy-(restart|launch-shell|shell)([^-]|$)' <<<"$code"; then
  fail "🔴 the applier never restarts or signals the shell" \
    "the line(s) above start, stop, restart or signal a session -- see T12 finding §3.3"
fi
pass "the applier starts, stops, restarts and signals nothing (no shell relaunch path)"

# --- 14. the ALPM hook ------------------------------------------------------

[[ $(basename -- "$HOOK") == 50-* ]] ||
  fail "the hook sorts after upstream's 10- pause and before its 90- resume" "$(basename -- "$HOOK")"
grep -qE '^Type = Package$' "$HOOK" || fail "the hook triggers on the PACKAGE" "$(cat "$HOOK")"
if grep -vE '^[[:space:]]*#' "$HOOK" | grep -qE '^Type = Path$'; then
  fail "🔴 the hook must not use Type = Path" \
    "measured (T12 finding M3): a Path trigger silently stops firing when upstream renames the file"
fi
for target in omarchy-dev omarchy omarchy-settings-dev omarchy-settings; do
  grep -qE "^Target = $target\$" "$HOOK" ||
    fail "the hook targets $target" "a trigger that names only the -dev packages becomes a silent no-op at the 4.0-stable rename"
done
grep -qE '^When = PostTransaction$' "$HOOK" || fail "the hook runs PostTransaction" "$(cat "$HOOK")"
grep -qE '^Depends = omarchy-deck$' "$HOOK" || fail "the hook declares its Depends" "$(cat "$HOOK")"
for op in Install Upgrade; do
  grep -qE "^Operation = $op\$" "$HOOK" || fail "the hook fires on $op" "$(cat "$HOOK")"
done
hook_exec=$(grep -oP '^Exec = \K\S+' "$HOOK") || fail "the hook declares an Exec" "$(cat "$HOOK")"
[[ $(basename -- "$hook_exec") == "$(basename -- "$APPLIER")" ]] ||
  fail "the hook execs the applier this repo ships" "hook runs $hook_exec, the payload is $APPLIER"
grep -qE '^Exec = .*--from-hook' "$HOOK" || fail "the hook passes --from-hook" "$(cat "$HOOK")"
pass "the ALPM hook: Type=Package, all four package names, PostTransaction, and it execs this applier"

# --- 15. the boot-time verify unit ------------------------------------------

grep -qE '^Type=oneshot$' "$UNIT" || fail "the verify unit is a oneshot" "$(cat "$UNIT")"
unit_exec=$(grep -oP '^ExecStart=\K.*' "$UNIT") || fail "the unit declares ExecStart" "$(cat "$UNIT")"
[[ $unit_exec != -* ]] ||
  fail "🔴 ExecStart has no leading '-'" \
    "a '-' tells systemd to ignore the exit status; the unit would go active on a drifted patch and this file would be an elaborate way of pretending everything is fine"
grep -q -- '--verify' <<<"$unit_exec" ||
  fail "the boot unit runs --verify, not a repair" \
    "a unit that silently re-applied at every boot would hide the hook not doing its job"
[[ $(basename -- "$(awk '{print $1}' <<<"$unit_exec")") == "$(basename -- "$APPLIER")" ]] ||
  fail "the unit execs the applier this repo ships" "$unit_exec"
if grep -qE '^(Restart|SuccessExitStatus)=' "$UNIT"; then
  fail "🔴 the unit has no Restart= or SuccessExitStatus=" \
    "either one would stop a drifted patch from leaving a FAILED unit, which is the only terminal-free channel"
fi
grep -qE '^WantedBy=multi-user.target$' "$UNIT" || fail "the unit is installable at boot" "$(cat "$UNIT")"
pass "the verify unit leaves a failed unit on drift: oneshot, --verify, no '-', no Restart=, no SuccessExitStatus="

# --- 16. the shipped .meta files are themselves well formed ----------------
#
# The applier rejects a bad .meta at runtime, on the device. Catch it here.

for meta in "$PATCH_DIR"/*.meta; do
  name=$(basename -- "$meta")
  grep -qE '^target: ' "$meta" || fail "$name declares a target" "$meta"
  grep -qE '^requirement: ' "$meta" || fail "$name names its owning requirement" "$meta"
  grep -qE '^(assert_count|qmllint): ' "$meta" || fail "$name carries a post-condition" "$meta"
  [[ -f ${meta%.meta}.patch ]] || fail "$name has a .patch sibling" "$meta"
done
for patch in "$PATCH_DIR"/*.patch; do
  [[ -f ${patch%.patch}.meta ]] || fail "$(basename -- "$patch") has a .meta sibling" "$patch"
done
# 0010 must assert both directions, and this is not decoration: `interval:`
# occurs four times in Service.qml, so a patch that landed on the wrong Timer
# would still put a `20000` in the file. Only "and the 5000 is gone" catches it.
m10="$PATCH_DIR/0010-lock-blank-timer-20s.meta"
grep -qF 'assert_count: shell/plugins/lock/Service.qml|^    interval: 20000$|1' "$m10" ||
  fail "0010 asserts the NEW value appears exactly once" "$(cat "$m10")"
grep -qF 'assert_count: shell/plugins/lock/Service.qml|^    interval: 5000$|0' "$m10" ||
  fail "🔴 0010 asserts the OLD value is GONE" \
    "without this a patch that applied to the wrong one of the four 'interval:' hunks would still pass"
grep -qF 'qmllint: shell/plugins/lock/Service.qml' "$m10" ||
  fail "0010 lints the QML it edits" "$(cat "$m10")"
pass "0010 asserts both directions of the literal and lints the result"

# --- 16b. the runtime patch budget -----------------------------------------
#
# `docs/findings/T12-upstream-patch-seam.md` §3.5 set this at **≤ 2 runtime
# patches, and a third has to argue for itself**. Every patch here is a standing
# rebase liability against a repo that moves several times a day, and
# `pacman -Qkk omarchy-dev` reports each patched file as altered.
#
# 🔴 RAISED TO 3 ON 2026-08-16, and here is the third patch's argument, because
# §3.5 asks for one rather than forbidding one:
#
#   0030-screensaver-font-fits-panel sizes the screensaver terminal's font so
#   Omarchy's own 81-column logo fits the Deck's 1024-logical-px-wide panel. At
#   upstream's size=18 the terminal is 71 columns and the O and the Y are cut
#   off (operator, from hardware, 2026-08-16).
#
#   THERE IS NO NON-PATCH SEAM FOR IT. `omarchy-launch-screensaver` runs
#   `foot --config="$OMARCHY_PATH/default/foot/screensaver.ini"`, and foot's
#   --config REPLACES the user config rather than layering over it -- so
#   ~/.config/foot/foot.ini is never consulted and an orchestrator module
#   writing under $HOME cannot reach this setting at all. $OMARCHY_PATH is
#   /usr/share/omarchy (default/bash/env-bootstrap:14), which omarchy-dev owns
#   and reverts silently on upgrade with no .pacnew -- measurement M2, the exact
#   reason this seam exists. A hand-edit would be the silent-revert failure
#   CLAUDE.md forbids; this applier is the only mechanism that makes it loud.
#
#   ITS REBASE LIABILITY IS THE SMALLEST OF THE THREE: a 7-line INI whose only
#   moving part is one integer, versus a 551-line QML file that has already
#   moved under 0010 twice.
#
# ⚠️ 4 IS NOT AUTOMATICALLY NEXT. The budget is a pressure valve, not a
# ratchet: a fourth patch argues from ≤ 3 exactly as this one argued from ≤ 2,
# and "the last one got in" is not an argument.
n_patches=$(find "$PATCH_DIR" -name '*.patch' | wc -l)
[[ $n_patches -le 3 ]] ||
  fail "the runtime patch budget is 3 (T12 finding §3.5, raised from 2 on 2026-08-16)" \
    "$n_patches patches -- a fourth has to argue for itself in the task file first; each one is a standing rebase liability against a repo that moves several times a day"
pass "$n_patches shipped patches, each with a well-formed .meta, within the budget of 3"

# --- 17. the container e2e exists and is wired to the same payload ----------

E2E="$REPO_ROOT/test/t12-patch-seam-container-e2e.sh"
[[ -x $E2E ]] || fail "the pacman destruction test exists and is executable" "missing: $E2E"
grep -q 'omarchy-deck-patches' "$E2E" ||
  fail "the destruction test uses this payload" "it must install the same files, not a copy"
pass "the pacman destruction test is present (test/t12-patch-seam-container-e2e.sh)"

printf '\nall t12 patch-applier tests passed\n'
