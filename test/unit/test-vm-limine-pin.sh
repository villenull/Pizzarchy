#!/usr/bin/env bash
# Unit tests for the boot-chain pin check inside vm-neptune-image.sh.
#
# WHY THIS EXISTS
#
# The substrate is only useful if its limine stack matches the one the product
# boots. Until 2026-08-11 it pulled that stack from the `stable` channel while
# its own header claimed "same version stream as Quattro's" -- `stable` was
# measured 606 commits behind, and nothing enforced the claim, so every VM
# suite could pass green against a boot chain the product never runs
# (docs/findings/T9-coupling-inventory.md).
#
# The fix added an assertion. This suite exists so the assertion itself is not
# the next thing that is wrong about itself: a check nobody checks is exactly
# the failure mode being fixed.
#
# HOW IT REACHES THE CODE
#
# The check lives inside an unquoted-heredoc build script that is written out
# and executed inside a Docker container, so it cannot be sourced. This suite
# extracts the block between the two marker comments and RUNS it with a stubbed
# `arch-chroot`, which is the only part of it that touches the system.
#
# No Docker, no VM, no root, no network.

set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
BUILDER="$REPO_ROOT/test/images/vm-neptune-image.sh"

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; [[ -n ${2:-} ]] && printf '%s\n' "$2" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# --- extract the block ------------------------------------------------------

block=$(sed -n '/^# --- the boot-chain pin, asserted/,/^# --- end boot-chain pin ---$/p' "$BUILDER")

# ⚠️ Guard the extraction before trusting it. A renamed marker returns an empty
# string, and every case below would then "pass" while asserting nothing --
# the precise green-for-the-wrong-reason failure this file exists to prevent.
[[ -n $block ]] ||
  fail "extracted an EMPTY block from ${BUILDER}" \
    "the marker comments '# --- the boot-chain pin, asserted' / '# --- end boot-chain pin ---' must both exist"
grep -q 'IMG_LIMINE_PIN=any bypasses this' <<<"$block" ||
  fail "the extracted block does not contain the pin check" "extraction matched the wrong range"
grep -q 'pin_drift' <<<"$block" ||
  fail "the extracted block does not contain the drift comparison" "extraction matched the wrong range"
pass "the pin check extracts from the builder by its markers, and is not empty"

# --- the harness ------------------------------------------------------------
#
# Everything the block calls that touches a system: `arch-chroot`, plus the
# builder's own `step` and `die`. `die` must exit non-zero -- if it did not,
# a drift would print and carry on, which is the bug class being tested.

stub_bin="$work/bin"
mkdir -p "$stub_bin"

cat >"$stub_bin/arch-chroot" <<'STUB'
#!/usr/bin/env bash
# Stub: `arch-chroot /mnt pacman -Q <pkg>` -> "<pkg> <version>", from
# FAKE_PKGS ("pkg=ver pkg=ver"). A package absent from FAKE_PKGS exits 1 with
# no output, which is what pacman does for a package that is not installed.
set -uo pipefail
shift          # the root
shift; shift   # pacman -Q
[[ $# -ge 1 ]] || { for e in ${FAKE_PKGS:-}; do printf '%s %s\n' "${e%%=*}" "${e#*=}"; done; exit 0; }
for want in "$@"; do
  found=""
  for e in ${FAKE_PKGS:-}; do
    [[ ${e%%=*} == "$want" ]] || continue
    printf '%s %s\n' "${e%%=*}" "${e#*=}"
    found=yes
  done
  [[ -n $found ]] || exit 1
done
STUB
chmod +x "$stub_bin/arch-chroot"

# Run the extracted block with a given pin and a given fake installed set.
# Prints combined output; returns the block's exit status.
run_pin() {
  local pin=$1 pkgs=$2
  PATH="$stub_bin:$PATH" LIMINE_PIN="$pin" FAKE_PKGS="$pkgs" \
    bash -c '
      set -euo pipefail
      step() { printf "=== %s ===\n" "$*" >&2; }
      die()  { printf "FAIL: %s\n" "$*" >&2; exit 1; }
      '"$block"'
    ' 2>&1
}

matching='limine=12.5.2-1 limine-mkinitcpio-hook=1.37.1-1 limine-snapper-sync=1.31.0-1'

# --- the happy path ---------------------------------------------------------

out=$(run_pin "$matching" "$matching") ||
  fail "a matching stack passes the pin" "$out"
grep -q "boot-chain pin OK" <<<"$out" ||
  fail "a matching stack reports the pin as OK" "$out"
pass "a stack matching the pin passes, and says so"

# --- drift, the case this whole file exists for -----------------------------

drifted='limine=12.6.0-1 limine-mkinitcpio-hook=1.37.1-1 limine-snapper-sync=1.31.0-1'
if out=$(run_pin "$matching" "$drifted"); then
  fail "a drifted limine version FAILS the build" "it exited 0; output: $out"
fi
pass "a drifted limine version fails the build instead of building silently"

grep -q "pinned 12.5.2-1, got 12.6.0-1" <<<"$out" ||
  fail "the drift message names both versions" "$out"
pass "the drift message names what was pinned and what was found"

# Pin the DIAGNOSIS, not just the exit code. Two different failures in this
# block both exit 1; an exit-code-only assertion would pass with either one
# deleted. (Session 16's lesson, PROGRESS.md 7.)
grep -q "the substrate would test a boot chain the product does not run" <<<"$out" ||
  fail "the drift failure explains the consequence, not just the mismatch" "$out"
grep -q "IMG_LIMINE_PIN" <<<"$out" ||
  fail "the drift failure says how to re-pin" "$out"
pass "the drift failure explains the consequence and how to re-pin"

# Drift in the OTHER packages must fail too -- not just the first one checked.
for pkg in limine-mkinitcpio-hook limine-snapper-sync; do
  bumped=${matching/${pkg}=1/${pkg}=9}
  [[ $bumped != "$matching" ]] || fail "test bug: could not bump ${pkg} in the fixture"
  if out=$(run_pin "$matching" "$bumped"); then
    fail "a drifted ${pkg} fails the build" "it exited 0; output: $out"
  fi
  grep -q "${pkg}: pinned" <<<"$out" ||
    fail "the drift message names ${pkg}" "$out"
done
pass "drift is caught in every pinned package, not only the first"

# --- a package that is not installed at all ---------------------------------

if out=$(run_pin "$matching" 'limine=12.5.2-1 limine-mkinitcpio-hook=1.37.1-1'); then
  fail "a missing pinned package fails the build" "it exited 0; output: $out"
fi
grep -q "is not installed in the new root" <<<"$out" ||
  fail "a missing package is reported as missing, not as a version mismatch" "$out"
pass "a pinned package that is absent fails loudly, and says it is absent"

# --- a malformed pin --------------------------------------------------------

if out=$(run_pin 'limine-12.5.2-1' "$matching"); then
  fail "a malformed pin entry fails the build" "it exited 0; output: $out"
fi
grep -q "is not pkg=version" <<<"$out" ||
  fail "a malformed pin entry says what is wrong with it" "$out"
pass "a malformed pin entry fails loudly rather than matching nothing"

# An entry with an empty version is malformed too: `limine=` would otherwise
# compare against "" and could pass for a package pacman does not know.
if out=$(run_pin 'limine=' "$matching"); then
  fail "a pin entry with an empty version fails the build" "it exited 0; output: $out"
fi
pass "a pin entry with an empty version is rejected"

# --- the deliberate bypass --------------------------------------------------

out=$(run_pin any "$drifted") ||
  fail "IMG_LIMINE_PIN=any skips the check" "$out"
grep -q "NOT checked" <<<"$out" ||
  fail "the bypass announces itself" "$out"
grep -q "limine 12.6.0-1" <<<"$out" ||
  fail "the bypass still prints the versions it got" "$out"
pass "IMG_LIMINE_PIN=any skips the check, says so loudly, and prints what it found"

# --- the default in the builder ---------------------------------------------
#
# The pin and the channel are a pair: pinning versions while pointing at the
# wrong channel would fail every build for the right reason but the wrong
# cause. Both defaults are asserted here so a silent revert to `stable` is
# caught by a suite that runs in seconds.

grep -q "OMARCHY_SERVER=\${IMG_OMARCHY_SERVER:-'https://pkgs.omarchy.org/edge/\$arch'}" "$BUILDER" ||
  fail "the builder defaults to the edge channel" \
    "the product's ISO carries edge (docs/findings/T9-iso-comparison.md); stable was 606 commits behind"
pass "the builder still defaults to the channel the product's ISO carries"

grep -q "LIMINE_PIN=\${IMG_LIMINE_PIN:-" "$BUILDER" ||
  fail "the builder still declares a default pin"
# shellcheck disable=SC2016 # the literal '$7' is the pattern; expanding it is the bug
grep -q 'LIMINE_PIN=\$7' "$BUILDER" ||
  fail "the in-container script still receives the pin as \$7" \
    "the pin is passed positionally; adding an argument without updating both sides silently shifts them"
# shellcheck disable=SC2016 # ditto: the literal '$(id -u)' text is what must appear in the builder
grep -q '"\$(id -u)" "\$(id -g)" "\$LIMINE_PIN"' "$BUILDER" ||
  fail "the docker invocation still passes the pin" \
    "without it the in-container LIMINE_PIN is unset and the block dies on set -u"
pass "the pin is declared, passed to the container, and received in the right position"

printf 'all limine-pin tests passed\n'
