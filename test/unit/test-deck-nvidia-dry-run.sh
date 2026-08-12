#!/usr/bin/env bash
# Unit tests for iso/overlay/configs/deck/deck-nvidia-dry-run.sh -- the T5c
# build-time guard that refuses an ISO whose target package set resolves the
# NVIDIA driver stack (docs/PROGRESS.md §3.8, docs/tasks/T5-fork-plan.md §7).
#
# No Docker, no network, no root: the guard's only external dependency is
# `pacman`, so every case below runs the REAL script against a stub pacman on a
# fixture PATH. The stub answers `-S --print --print-format '%n'` from canned
# closure files, which is exactly the seam where a resolution the guard cannot
# see becomes one it can.
#
# ---------------------------------------------------------------------------
# 🔴 Why this suite is mostly negative cases
# ---------------------------------------------------------------------------
#
# docs/PROGRESS.md §5.30c: this project produced four checks in one day whose
# passing state was indistinguishable from their not-having-run state -- a
# grep citing a path that did not exist (exit 2 reads exactly like "no match"),
# a `hyprctl eval` readback that returns ok for a name that never existed, an
# `echo "all suites green"` printed unconditionally. The NVIDIA assertion is
# the highest-value guard in T5c and it is exactly the shape that rots that
# way, so what is pinned here is not "it passes on good input" (case 1) but
# **every distinct way it must refuse to pass**:
#
#   * a missing input file                     (cases 3-5)
#   * a resolve that FAILED                    (case 6)
#   * a resolve that came back nearly empty    (case 7)
#   * a resolve missing a package we named     (case 8)
#   * the accepted exception disappearing      (case 9)
#   * the negative control not firing          (case 10)
#   * an install list that desyncs from the
#     shipped omarchy-base.packages            (case 11)
#   * a repo-qualified name in the install list(case 12)
#   * the matcher's own shape                  (cases 13-14)
#   * every way T5d's seam-S4 exclusion could
#     silently widen the hole it opens         (case 15)
#
# Cases 6-10 are the ones that matter: each is a state in which a naive
# implementation exits 0 and reports "no NVIDIA packages". Case 15 is the same
# question asked of the one thing T5d added that CAN legitimately be absent
# from the resolved set.

set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$REPO_ROOT/iso/overlay/configs/deck/deck-nvidia-dry-run.sh"
LIST_DIR="$REPO_ROOT/iso/overlay/configs/deck"

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; [[ -n ${2:-} ]] && printf '%s\n' "$2" >&2; exit 1; }

[[ -f $GUARD ]] || fail "the guard exists" "not found at $GUARD"
[[ -x $GUARD ]] || fail "the guard is executable"
bash -n "$GUARD" || fail "the guard is valid bash"
pass "deck-nvidia-dry-run.sh exists, is executable, and parses"

# The guard has no .sh-less sibling problem, but CI's shellcheck step selects
# by `git ls-files '*.sh'`, and this file IS matched by that -- so this is
# belt-and-braces rather than sole coverage. Skip loudly if shellcheck is
# absent locally.
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x "$GUARD" || fail "shellcheck -x on the guard is clean"
  pass "shellcheck -x deck-nvidia-dry-run.sh is clean"
else
  printf 'skip - shellcheck not on PATH locally; CI installs a pinned build\n'
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# ---------------------------------------------------------------------------
# The stub pacman.
#
# It answers three shapes:
#   -Sy                      -> exit $STUB_SY_STATUS (default 0)
#   -S --print ... <targets> -> print $STUB_WITH_PINS if every name in
#                               $STUB_PIN_NAMES is among the targets, else
#                               $STUB_WITHOUT_PINS; exit $STUB_RESOLVE_STATUS.
# That "else" branch is what makes the guard's negative control testable: the
# control re-runs the same resolve with the pins removed, and the stub answers
# it differently, exactly as the real repositories do.
#
# It also records every invocation, so a case can assert the guard actually
# asked -- not merely that it exited 0.
# ---------------------------------------------------------------------------

STUB_BIN="$work/bin"
mkdir -p "$STUB_BIN"
cat >"$STUB_BIN/pacman" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >>"$STUB_CALLS"
for a in "$@"; do
  if [[ $a == -Sy ]]; then exit "${STUB_SY_STATUS:-0}"; fi
done
have_all=1
for want in ${STUB_PIN_NAMES:-}; do
  found=0
  for a in "$@"; do [[ $a == "$want" ]] && found=1; done
  (( found )) || have_all=0
done
if (( have_all )); then cat "$STUB_WITH_PINS"; else cat "$STUB_WITHOUT_PINS"; fi
exit "${STUB_RESOLVE_STATUS:-0}"
STUB
chmod +x "$STUB_BIN/pacman"

# A PATH with the stub first and the real tools after it.
STUB_PATH="$STUB_BIN:$PATH"

# ---------------------------------------------------------------------------
# Fixtures. A clean run needs: a pacman.conf (contents irrelevant -- the stub
# never reads it, only its existence is asserted), an archinstall list, a
# shipped base list already carrying the pins (the seam-S1 merge having run),
# and a deck list dir.
# ---------------------------------------------------------------------------

make_fixture() {
  local root=$1
  rm -rf "$root"
  mkdir -p "$root/deck"
  printf '[options]\n' >"$root/pacman.conf"
  printf 'base\nlinux\nlinux-firmware\n' >"$root/archinstall.packages"
  # The shipped omarchy-base.packages AFTER build-iso.sh's seam-S1 merge.
  { printf 'hyprland\nsddm\n\n# --- Steam Deck ---\n'
    printf 'vulkan-radeon\nlib32-vulkan-radeon\n'; } >"$root/base.packages"
  printf '# a comment\nvulkan-radeon\nlib32-vulkan-radeon\n' >"$root/deck/deck-install.packages"
  printf '# another comment\nsteamdeck-dsp\nsteam\n' >"$root/deck/deck-fetch.packages"

  # A clean closure: >= MIN_CLOSURE lines, containing every probed name, the
  # accepted exception, and nothing else NVIDIA.
  { printf 'filler-%04d\n' $(seq 1 700)
    printf '%s\n' hyprland sddm base linux linux-firmware steam steamdeck-dsp \
      vulkan-radeon lib32-vulkan-radeon mesa linux-firmware-nvidia
  } >"$root/closure-clean"
  # The same closure as it looks when the pins were NOT among the targets.
  { cat "$root/closure-clean"
    printf '%s\n' nvidia-utils lib32-nvidia-utils egl-gbm egl-wayland egl-wayland2 egl-x11
  } >"$root/closure-nvidia"
}

# Run the guard. $1 = fixture root; any further args become extra environment.
run_guard() {
  local root=$1; shift
  GUARD_OUT=""
  GUARD_STATUS=0
  GUARD_OUT=$(
    env PATH="$STUB_PATH" \
      STUB_CALLS="$root/calls" \
      STUB_PIN_NAMES="vulkan-radeon lib32-vulkan-radeon" \
      STUB_WITH_PINS="$root/closure-clean" \
      STUB_WITHOUT_PINS="$root/closure-nvidia" \
      DECK_NVIDIA_DRYRUN_ROOT="$root/dryroot" \
      "$@" \
      "$GUARD" "$root/pacman.conf" "$root/base.packages" \
      "$root/archinstall.packages" "$root/deck" \
      omarchy-dev omarchy-settings-dev omarchy-nvim 2>&1
  ) || GUARD_STATUS=$?
  return 0
}

# --- 1. the happy path passes, and PROVES it asked -------------------------

f="$work/f1"; make_fixture "$f"
run_guard "$f"
[[ $GUARD_STATUS -eq 0 ]] || fail "a clean fixture passes" "status=$GUARD_STATUS
$GUARD_OUT"
[[ $GUARD_OUT == *"0 NVIDIA driver packages"* ]] || fail "the pass is reported" "$GUARD_OUT"
[[ $GUARD_OUT == *"negative control fired as designed"* ]] ||
  fail "the pass reports that the negative control fired" "$GUARD_OUT"
# It is not enough that it exited 0: it must have run a resolve carrying the
# packages the assertion is about. This is the difference between "passed" and
# "was never wired up".
grep -q -- '--print-format %n.*steam' "$f/calls" ||
  fail "the guard actually ran a resolve including steam" "$(cat "$f/calls")"
[[ $(grep -c -- '--print-format' "$f/calls") -eq 2 ]] ||
  fail "the guard ran exactly two resolves (assertion + negative control)" "$(cat "$f/calls")"
pass "a clean package set passes, and the run log proves both resolves happened"

# --- 2. an NVIDIA package in the closure fails the build, by name ----------

f="$work/f2"; make_fixture "$f"
# Make the WITH-pins closure dirty: the pins are present but NVIDIA came in
# anyway (a new dependency, a changed provider). This is the case the guard
# exists for.
cp "$f/closure-nvidia" "$f/closure-clean"
run_guard "$f"
[[ $GUARD_STATUS -ne 0 ]] || fail "an NVIDIA package in the resolved set must fail the build" "$GUARD_OUT"
[[ $GUARD_OUT == *"resolves NVIDIA driver packages"* ]] || fail "the failure names the problem" "$GUARD_OUT"
for p in nvidia-utils lib32-nvidia-utils egl-gbm egl-wayland egl-wayland2 egl-x11; do
  [[ $GUARD_OUT == *"$p"* ]] || fail "the failure lists $p" "$GUARD_OUT"
done
[[ $GUARD_OUT != *"linux-firmware-nvidia"$'\n'* ]] || true
pass "NVIDIA driver packages in the resolved set fail the build and are all named"

# --- 3-5. a missing input is an ERROR, never a quiet 'nothing found' -------

for missing in pacman.conf base.packages archinstall.packages; do
  f="$work/f-miss-$missing"; make_fixture "$f"
  rm -f "$f/$missing"
  run_guard "$f"
  [[ $GUARD_STATUS -ne 0 ]] || fail "a missing $missing must fail" "$GUARD_OUT"
  [[ $GUARD_OUT == *"input not found"* ]] || fail "the failure says the input was missing ($missing)" "$GUARD_OUT"
done
pass "a missing pacman.conf / base list / archinstall list is refused, not treated as 'no NVIDIA'"

f="$work/f-miss-list"; make_fixture "$f"
rm -f "$f/deck/deck-install.packages"
run_guard "$f"
[[ $GUARD_STATUS -ne 0 && $GUARD_OUT == *"input not found"* ]] ||
  fail "a missing deck-install.packages must fail" "$GUARD_OUT"
f="$work/f-miss-dir"; make_fixture "$f"
rm -rf "$f/deck"
run_guard "$f"
[[ $GUARD_STATUS -ne 0 && $GUARD_OUT == *"list directory not found"* ]] ||
  fail "a missing deck list directory must fail" "$GUARD_OUT"
pass "a missing deck list file or directory is refused with a distinct message"

# --- 6. a FAILED resolve must not read as a clean one ----------------------

f="$work/f6"; make_fixture "$f"
: >"$f/closure-clean"      # pacman printed nothing...
: >"$f/closure-nvidia"
run_guard "$f" STUB_RESOLVE_STATUS=1   # ...and said so
[[ $GUARD_STATUS -ne 0 ]] || fail "a resolve that FAILED must fail the build" "$GUARD_OUT"
[[ $GUARD_OUT == *"NOT 'no NVIDIA packages found'"* || $GUARD_OUT == *"control's resolve failed"* ]] ||
  fail "the failure distinguishes 'could not resolve' from 'nothing found'" "$GUARD_OUT"
pass "a non-zero pacman resolve fails the build (empty output must never read as a clean answer)"

# --- 7. a resolve that came back nearly empty is refused -------------------

f="$work/f7"; make_fixture "$f"
{ printf '%s\n' steam steamdeck-dsp vulkan-radeon lib32-vulkan-radeon linux-firmware-nvidia; } >"$f/closure-clean"
run_guard "$f"
[[ $GUARD_STATUS -ne 0 ]] || fail "a 5-package 'closure' must fail" "$GUARD_OUT"
[[ $GUARD_OUT == *"resolved only 5 packages"* ]] || fail "the failure gives the denominator" "$GUARD_OUT"
pass "an implausibly small resolved set is refused (the denominator is checked, not assumed)"

# --- 8. POSITIVE CONTROL: a probed package missing from the answer ---------

f="$work/f8"; make_fixture "$f"
grep -vx 'steam' "$f/closure-clean" >"$f/tmp" && mv "$f/tmp" "$f/closure-clean"
run_guard "$f"
[[ $GUARD_STATUS -ne 0 ]] || fail "a resolve without steam must fail" "$GUARD_OUT"
[[ $GUARD_OUT == *"'steam' was a target but is not in the"* ]] ||
  fail "the failure says which probe was absent" "$GUARD_OUT"
pass "a package the guard asked about by name being absent from the answer fails the build"

# --- 9. the accepted exception disappearing is a failure, not a silent widen -

f="$work/f9"; make_fixture "$f"
grep -vx 'linux-firmware-nvidia' "$f/closure-clean" >"$f/tmp" && mv "$f/tmp" "$f/closure-clean"
run_guard "$f"
[[ $GUARD_STATUS -ne 0 ]] || fail "a stale NVIDIA_EXCEPTIONS entry must fail" "$GUARD_OUT"
[[ $GUARD_OUT == *"no longer in the resolved set"* ]] ||
  fail "the failure tells the reader to delete the exception" "$GUARD_OUT"
pass "an exception that no longer matches anything fails the build instead of rotting in place"

# --- 10. 🔴 the NEGATIVE CONTROL not firing is a failure --------------------
#
# This is the case that separates this guard from every check §5.30c
# catalogued. With the pins removed the resolve is SUPPOSED to produce NVIDIA
# packages; if it does not, the clean result is worthless and must not pass.

f="$work/f10"; make_fixture "$f"
cp "$f/closure-clean" "$f/closure-nvidia"   # removing the pins changes nothing
run_guard "$f"
[[ $GUARD_STATUS -ne 0 ]] || fail "a negative control that does not fire must fail the build" "$GUARD_OUT"
[[ $GUARD_OUT == *"NEGATIVE CONTROL did not fire"* ]] || fail "the failure names the control" "$GUARD_OUT"
[[ $GUARD_OUT == *"guard that cannot fail"* ]] || fail "the failure explains why green would be meaningless" "$GUARD_OUT"
pass "🔴 the negative control not firing fails the build -- the guard refuses to pass when it cannot fail"

# --- 11. install list desynced from the shipped base list ------------------

f="$work/f11"; make_fixture "$f"
grep -vx 'lib32-vulkan-radeon' "$f/base.packages" >"$f/tmp" && mv "$f/tmp" "$f/base.packages"
run_guard "$f"
[[ $GUARD_STATUS -ne 0 ]] || fail "a pin absent from the shipped base list must fail" "$GUARD_OUT"
[[ $GUARD_OUT == *"but not in the shipped"* ]] || fail "the failure names the desync" "$GUARD_OUT"
pass "a pin missing from the shipped omarchy-base.packages fails (seam S1's merge is verified, not assumed)"

# --- 12. a repo-qualified name in the install list -------------------------

f="$work/f12"; make_fixture "$f"
sed -i 's|^vulkan-radeon$|extra/vulkan-radeon|' "$f/deck/deck-install.packages"
run_guard "$f"
[[ $GUARD_STATUS -ne 0 ]] || fail "a repo-qualified install-list entry must fail" "$GUARD_OUT"
[[ $GUARD_OUT == *"is repo-qualified"* ]] || fail "the failure explains the offline-resolve problem" "$GUARD_OUT"
pass "a repo-qualified name in deck-install.packages is refused (it would abort the offline resolve and pacstrap)"

# --- 13. an empty (or all-comment) list is refused -------------------------

f="$work/f13"; make_fixture "$f"
printf '# only comments\n\n' >"$f/deck/deck-install.packages"
run_guard "$f"
[[ $GUARD_STATUS -ne 0 && $GUARD_OUT == *"contains no package entries"* ]] ||
  fail "an all-comment install list must fail" "$GUARD_OUT"
f="$work/f13b"; make_fixture "$f"
: >"$f/deck/deck-fetch.packages"
run_guard "$f"
[[ $GUARD_STATUS -ne 0 && $GUARD_OUT == *"contains no package entries"* ]] ||
  fail "an empty fetch list must fail" "$GUARD_OUT"
pass "an empty or all-comment package list is refused, so the question can never become vacuous"

# --- 14. the matcher's shape -----------------------------------------------
#
# Driven through the real script rather than by re-implementing the regex
# here: a test that carries its own copy of the pattern passes when the
# script's copy is wrong.

matcher_case() {
  # $1 = package name to inject, $2 = "caught"|"ignored", $3 = description
  local pkg=$1 expect=$2 desc=$3
  local root="$work/m-$pkg"
  make_fixture "$root"
  printf '%s\n' "$pkg" >>"$root/closure-clean"
  run_guard "$root"
  case $expect in
    caught)
      [[ $GUARD_STATUS -ne 0 && $GUARD_OUT == *"resolves NVIDIA driver packages"* ]] ||
        fail "the matcher catches '$pkg' ($desc)" "status=$GUARD_STATUS
$GUARD_OUT" ;;
    ignored)
      [[ $GUARD_STATUS -eq 0 ]] ||
        fail "the matcher does NOT catch '$pkg' ($desc)" "status=$GUARD_STATUS
$GUARD_OUT" ;;
  esac
}

matcher_case nvidia-utils           caught  "prefix"
matcher_case lib32-nvidia-utils     caught  "infix -- a prefix-only pattern would miss this"
matcher_case libva-nvidia-driver    caught  "infix, and upstream ships it in omarchy-other.packages"
matcher_case nvidia-open-dkms       caught  "prefix, the DKMS variant"
matcher_case nvidia                 caught  "the bare name"
matcher_case egl-gbm                caught  "NVIDIA's EGL userspace, no 'nvidia' in the name"
matcher_case egl-wayland2           caught  "the one §3.8's own list omitted"
matcher_case egl-x11                caught  "NVIDIA's EGL userspace"
matcher_case vulkan-nouveau         ignored "mesa's open NVIDIA driver -- not the proprietary stack"
matcher_case libnvidia-container    ignored "no '-' before 'nvidia', so not the driver stack"
matcher_case egl-wayland-utils      ignored "anchored: only the exact NVIDIA EGL package names"
pass "the matcher catches every NVIDIA driver package shape and none of the look-alikes (11 cases)"

# --- 15. 🔴 DECK_LOCAL_PACKAGES: the seam-S4 exclusion ---------------------
#
# T5d adds `omarchy-deck` -- a package this build produces ITSELF, which exists
# in no online repository. This script resolves against the ONLINE repos, and
# `pacman -S --print` aborts the whole transaction on one unresolvable target,
# so the name has to come out of the target set. That is a HOLE in the guard's
# question, and the cases below are what stop it widening:
#
#   * the exclusion actually happens, PROVEN from the resolve's argument list
#     rather than from the guard's own log line (15a);
#   * the rest of the question is unchanged -- steam is still asked about, the
#     negative control still fires, the positive control still runs (15a);
#   * excluding a name that is in no install list is refused, so the list
#     cannot accumulate names that excuse nothing (15b);
#   * a locally built name missing from the shipped omarchy-base.packages is
#     refused -- that is the seam-S1 desync, and it is the failure that ends
#     with the ISO carrying a package nothing installs (15c);
#   * a locally built name that DOES resolve online is refused: the positive
#     control cannot cover these names, so they get the mirror-image
#     assertion rather than an exemption (15d);
#   * an install list consisting only of locally built names is refused,
#     because the negative control would then have nothing to remove (15e).

make_local_fixture() {
  local root=$1
  make_fixture "$root"
  printf '# a comment\nvulkan-radeon\nlib32-vulkan-radeon\nomarchy-deck\n' \
    >"$root/deck/deck-install.packages"
  # The seam-S1 merge put it in the shipped base list too; it is installed at
  # pacstrap time from the OFFLINE mirror, which is why it belongs there.
  printf 'omarchy-deck\n' >>"$root/base.packages"
  # Deliberately NOT added to either closure file: it cannot resolve online.
}

# 15a. the happy path, with the exclusion actually observed
f="$work/f15a"; make_local_fixture "$f"
run_guard "$f" DECK_LOCAL_PACKAGES=omarchy-deck
[[ $GUARD_STATUS -eq 0 ]] || fail "a locally built package must not break the dry run" "status=$GUARD_STATUS
$GUARD_OUT"
[[ $GUARD_OUT == *"excluded 1 locally built package"* ]] ||
  fail "the guard reports the exclusion it made" "$GUARD_OUT"
# The log line is the guard's own account of itself. The argument list is not:
# every recorded pacman invocation must be free of the excluded name, or the
# resolve would have aborted in the real container no matter what was logged.
grep -q 'omarchy-deck' "$f/calls" &&
  fail "the excluded package still reached a pacman resolve" "$(cat "$f/calls")"
# ...and the question the guard claims to ask is otherwise intact.
grep -q -- '--print-format %n.*steam' "$f/calls" ||
  fail "the resolve still carries steam after the exclusion" "$(cat "$f/calls")"
[[ $(grep -c -- '--print-format' "$f/calls") -eq 2 ]] ||
  fail "both resolves still run with an exclusion in play" "$(cat "$f/calls")"
[[ $GUARD_OUT == *"negative control fired as designed"* ]] ||
  fail "the negative control still fires with an exclusion in play" "$GUARD_OUT"
pass "🔴 a locally built package is excluded from the ONLINE resolve, proven from pacman's own argument list, with every other control intact"

# 15b. excluding a name nothing installs
f="$work/f15b"; make_fixture "$f"
run_guard "$f" DECK_LOCAL_PACKAGES=omarchy-deck
[[ $GUARD_STATUS -ne 0 ]] || fail "excluding a name absent from the install list must fail" "$GUARD_OUT"
[[ $GUARD_OUT == *"is not in"*"deck-install.packages"* ]] ||
  fail "the failure says the excluded name is in no install list" "$GUARD_OUT"
pass "an exclusion for a package the ISO does not install is refused (an exclusion that excuses nothing is a hole)"

# 15c. the seam-S1 desync, for a locally built name
f="$work/f15c"; make_local_fixture "$f"
grep -vx 'omarchy-deck' "$f/base.packages" >"$f/tmp" && mv "$f/tmp" "$f/base.packages"
run_guard "$f" DECK_LOCAL_PACKAGES=omarchy-deck
[[ $GUARD_STATUS -ne 0 ]] || fail "a locally built package missing from the shipped base list must fail" "$GUARD_OUT"
[[ $GUARD_OUT == *"but not in the shipped"* ]] ||
  fail "the failure names the seam-S1 desync" "$GUARD_OUT"
pass "a locally built package absent from the shipped omarchy-base.packages fails -- the exclusion never hides a package nothing installs"

# 15d. a name collision with a real online package
f="$work/f15d"; make_local_fixture "$f"
printf 'omarchy-deck\n' >>"$f/closure-clean"
printf 'omarchy-deck\n' >>"$f/closure-nvidia"
run_guard "$f" DECK_LOCAL_PACKAGES=omarchy-deck
[[ $GUARD_STATUS -ne 0 ]] || fail "a locally built name that resolves online must fail" "$GUARD_OUT"
[[ $GUARD_OUT == *"RESOLVES ONLINE"* ]] || fail "the failure names the collision" "$GUARD_OUT"
pass "a package we build ourselves that ALSO resolves from an online repo fails (the positive control's mirror image, not an exemption)"

# 15e. nothing left for the negative control to remove
f="$work/f15e"; make_fixture "$f"
printf 'omarchy-deck\n' >"$f/deck/deck-install.packages"
printf 'omarchy-deck\n' >>"$f/base.packages"
run_guard "$f" DECK_LOCAL_PACKAGES=omarchy-deck
[[ $GUARD_STATUS -ne 0 ]] || fail "an all-local install list must fail" "$GUARD_OUT"
[[ $GUARD_OUT == *"every entry in"*"is a locally built package"* ]] ||
  fail "the failure explains that the negative control would be vacuous" "$GUARD_OUT"
pass "an install list of nothing but locally built packages is refused -- the negative control must keep something to remove"

# --- 16. the real overlay lists are self-consistent ------------------------
#
# Runs against the files this repo actually ships rather than a fixture, so a
# later edit to them is covered.

install_list="$LIST_DIR/deck-install.packages"
mirror_list="$LIST_DIR/deck-mirror.packages"
fetch_list="$LIST_DIR/deck-fetch.packages"
for f in "$install_list" "$mirror_list" "$fetch_list"; do
  [[ -f $f ]] || fail "$(basename "$f") exists in iso/overlay/configs/deck/"
done
read_entries() { awk '!/^[[:space:]]*(#|$)/' "$1"; }

install_entries=$(read_entries "$install_list")
[[ -n $install_entries ]] || fail "deck-install.packages has entries"
while IFS= read -r entry; do
  [[ $entry != */* ]] ||
    fail "deck-install.packages must contain no repo-qualified names" "found: $entry"
done <<<"$install_entries"
pass "the shipped deck-install.packages has entries and none is repo-qualified"

# §3.8's pin, stated as a requirement on the file rather than on a fixture.
for required in vulkan-radeon lib32-vulkan-radeon; do
  grep -qx -- "$required" <<<"$install_entries" ||
    fail "deck-install.packages pins '$required' (docs/PROGRESS.md §3.8)"
done
pass "deck-install.packages pins both vulkan-radeon and lib32-vulkan-radeon"

# The fetch list must stay OUT of the mirror list: §4.1 decided fetch-not-bundle
# for steamdeck-dsp on licence grounds, and a copy-paste into the mirror list
# would redistribute a Proprietary package inside the ISO.
mirror_entries=$(read_entries "$mirror_list")
while IFS= read -r entry; do
  grep -qxF -- "$entry" <<<"$mirror_entries" &&
    fail "'$entry' is in BOTH deck-fetch.packages and deck-mirror.packages" \
      "T5-fork-plan.md §4.1 decided fetch-not-bundle for licence reasons; bundling it redistributes it."
done <<<"$(read_entries "$fetch_list")"
grep -qx 'steamdeck-dsp' <<<"$mirror_entries" &&
  fail "steamdeck-dsp must never be in deck-mirror.packages (Licenses: Proprietary)"
pass "no package is in both the fetch and mirror lists; steamdeck-dsp is not bundled"

# gamescope must stay repo-qualified: docs/PROGRESS.md §5.13 measured that a
# bare name resolves to Arch's compositor instead of Valve's session, because
# the Valve repos are appended last. This is the one place that decision is
# expressed in a file the build reads.
grep -qx 'jupiter-staging/gamescope' <<<"$mirror_entries" ||
  fail "deck-mirror.packages must request gamescope from jupiter-staging explicitly" \
    "docs/PROGRESS.md §5.13: a bare 'gamescope' resolves to Arch's build, which does not ship the session.
found: $(grep -i gamescope <<<"$mirror_entries" || echo '<no gamescope entry at all>')"
pass "gamescope is requested as jupiter-staging/gamescope (§5.13: repo order beats version)"

printf '\nall deck-nvidia-dry-run tests passed\n'
