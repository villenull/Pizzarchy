#!/usr/bin/env bash
# Unit tests for tools/iso-payload-audit.sh, run against hand-built fixture
# trees and hand-built package archives. No ISO, no VM, no Deck.
#
# What is being pinned here is not "does it find a bad line" -- that predicate
# is deck-session.sh's and has its own tests. It is the two properties that
# decide whether this check is worth having at all (PROGRESS.md 5.17, 5.25 #7):
#
#   1. it FAILS on the one file that must never ship, wherever it ships from
#      (loose tree, arbitrary depth, or inside a package archive), and
#   2. it cannot pass vacuously -- a missing root, an unreadable archive, or a
#      missing bsdtar is an ERROR, never a quiet zero.

set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
AUDIT="$REPO_ROOT/tools/iso-payload-audit.sh"

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; [[ -n ${2:-} ]] && printf '%s\n' "$2" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Run the audit, capturing output and status without tripping `set -e`.
run_audit() {
  AUDIT_OUT=""
  AUDIT_STATUS=0
  AUDIT_OUT=$("$AUDIT" "$@" 2>&1) || AUDIT_STATUS=$?
  return 0
}

# The exact line from the dev Deck (PROGRESS.md 5.17). Assembled rather than
# written literally so a future grep for the string in this repo lands on the
# documentation, not on a fixture that looks like a real grant.
DANGEROUS="deck ALL=(ALL) NOPASSWD: ALL"
# The ordinary admin grant every Arch/Omarchy install ships. Blanket, but
# password-protected. Failing on this is the false positive 5.17 warns about.
ORDINARY="deck ALL=(ALL) ALL"

# --- 1. a clean payload passes, and says what it looked at ------------------

clean="$work/clean"
mkdir -p "$clean/etc/sudoers.d"
printf '%s\n' "# nothing to see here" >"$clean/etc/sudoers.d/00-empty"
printf '%s\n' "deck ALL=(ALL) NOPASSWD: /usr/bin/steamos-priv-write" \
  >"$clean/etc/sudoers.d/99-deck-priv-write"

run_audit "$clean"
[[ $AUDIT_STATUS -eq 0 ]] || fail "a clean payload exits 0" "$AUDIT_OUT"
[[ $AUDIT_OUT == *"inspected 2 sudoers file(s)"* ]] ||
  fail "the audit prints the number of files it actually inspected" "$AUDIT_OUT"
pass "clean payload passes; a NARROW passwordless grant is not a blanket one"
pass "the summary states the denominator, so a run that scanned nothing is visible"

# --- 2. the ordinary admin grant is reported but does NOT fail -------------

ordinary="$work/ordinary"
mkdir -p "$ordinary/etc/sudoers.d"
printf '%s\n' "$ORDINARY" >"$ordinary/etc/sudoers.d/03_deck"

run_audit "$ordinary"
[[ $AUDIT_STATUS -eq 0 ]] ||
  fail "the ordinary password-protected admin grant must NOT fail the build" "$AUDIT_OUT"
[[ $AUDIT_OUT == *"password required"* && $AUDIT_OUT == *"03_deck"* ]] ||
  fail "the ordinary grant is still reported, by file name" "$AUDIT_OUT"
pass "blanket-but-password-protected is reported and tolerated (no false positive)"

# --- 3. the file that must never ship fails the build ----------------------

dirty="$work/dirty"
mkdir -p "$dirty/etc/sudoers.d"
printf '%s\n' "$DANGEROUS" >"$dirty/etc/sudoers.d/99-deck-testing"

run_audit "$dirty"
[[ $AUDIT_STATUS -eq 1 ]] ||
  fail "a payload carrying blanket passwordless root exits 1" "status=$AUDIT_STATUS $AUDIT_OUT"
[[ $AUDIT_OUT == *"PASSWORDLESS BLANKET ROOT"* && $AUDIT_OUT == *"99-deck-testing"* ]] ||
  fail "the failure names the offending file" "$AUDIT_OUT"
pass "99-deck-testing in the payload FAILS the build and is named"

# --- 4. depth does not matter ---------------------------------------------

deep="$work/deep"
mkdir -p "$deep/configs/airootfs/etc/sudoers.d" "$deep/pkgroot/etc/skel/nothing"
printf '%s\n' "$DANGEROUS" >"$deep/configs/airootfs/etc/sudoers.d/99-deck-testing"

run_audit "$deep"
[[ $AUDIT_STATUS -eq 1 ]] ||
  fail "a drop-in nested under configs/airootfs/ is still found" "$AUDIT_OUT"
pass "sudoers.d is matched at any depth, not only at a tree's root"

# `etc/sudoers` itself, not just the drop-in directory.
main_sudoers="$work/mainsudoers"
mkdir -p "$main_sudoers/etc"
printf '%s\n%s\n' "Defaults env_reset" "$DANGEROUS" >"$main_sudoers/etc/sudoers"
run_audit "$main_sudoers"
[[ $AUDIT_STATUS -eq 1 ]] || fail "etc/sudoers itself is audited, not only etc/sudoers.d/*" "$AUDIT_OUT"
pass "etc/sudoers is audited too -- the grant does not have to be in a drop-in"

# --- 5. comments are not grants -------------------------------------------

commented="$work/commented"
mkdir -p "$commented/etc/sudoers.d"
printf '%s\n' "# $DANGEROUS" "#   $DANGEROUS" >"$commented/etc/sudoers.d/99-notes"
run_audit "$commented"
[[ $AUDIT_STATUS -eq 0 ]] ||
  fail "a commented-out example must not fail the build" "$AUDIT_OUT"
pass "commented-out lines are documentation, not grants"

# --- 6. it cannot pass vacuously: a missing root is an ERROR ---------------

run_audit "$work/does-not-exist"
[[ $AUDIT_STATUS -eq 1 ]] ||
  fail "a payload root that does not exist must be an error, not a clean pass" "status=$AUDIT_STATUS $AUDIT_OUT"
[[ $AUDIT_OUT == *"does not exist"* ]] || fail "the missing-root error says so" "$AUDIT_OUT"
pass "an absent payload root fails loudly instead of auditing nothing and passing"

# --- 7. no arguments is a usage error (exit 2), not a pass -----------------

run_audit
[[ $AUDIT_STATUS -eq 2 ]] ||
  fail "no arguments must be a usage error, not a successful audit of nothing" "status=$AUDIT_STATUS"
pass "invoking it with no payload is a usage error, not a green build"

# --- 8. a drop-in inside a package archive is still shipped ----------------

command -v bsdtar >/dev/null 2>&1 ||
  fail "bsdtar is missing on this machine" \
    "The package-archive half of this audit is the most likely delivery route for our own sudoers drop-in, so it is not optional. Install libarchive (bsdtar)."

pkgroot="$work/pkgbuild"
mkdir -p "$pkgroot/etc/sudoers.d"
printf '%s\n' "$DANGEROUS" >"$pkgroot/etc/sudoers.d/99-deck-testing"
mirror="$work/mirror"
mkdir -p "$mirror"
( cd "$pkgroot" && bsdtar --zstd -cf "$mirror/omarchy-deck-1-1-any.pkg.tar.zst" etc )
# A signature file sitting beside it must not be mistaken for an archive.
printf 'not a real signature\n' >"$mirror/omarchy-deck-1-1-any.pkg.tar.zst.sig"

run_audit "$mirror"
[[ $AUDIT_STATUS -eq 1 ]] ||
  fail "a sudoers drop-in INSIDE a package archive must fail the build" "status=$AUDIT_STATUS $AUDIT_OUT"
[[ $AUDIT_OUT == *"omarchy-deck-1-1-any.pkg.tar.zst!etc/sudoers.d/99-deck-testing"* ]] ||
  fail "the failure names the archive AND the member inside it" "$AUDIT_OUT"
[[ $AUDIT_OUT == *"1 package archive(s)"* ]] ||
  fail "the .sig beside the package is not counted as a second archive" "$AUDIT_OUT"
pass "a drop-in inside a .pkg.tar.zst is found, named archive!member, and fails"
pass ".sig files beside packages are not treated as archives"

# A package with no sudoers member at all is clean, and still counted.
cleanpkgroot="$work/cleanpkgbuild"
mkdir -p "$cleanpkgroot/usr/bin"
printf '#!/bin/sh\n' >"$cleanpkgroot/usr/bin/deck-thing"
cleanmirror="$work/cleanmirror"
mkdir -p "$cleanmirror"
( cd "$cleanpkgroot" && bsdtar --zstd -cf "$cleanmirror/omarchy-deck-1-1-any.pkg.tar.zst" usr )
run_audit "$cleanmirror"
[[ $AUDIT_STATUS -eq 0 ]] || fail "a package with no sudoers member passes" "$AUDIT_OUT"
[[ $AUDIT_OUT == *"inspected 0 sudoers file(s)"* && $AUDIT_OUT == *"1 package archive(s)"* ]] ||
  fail "a clean package is still counted, so 'inspected 0' is visibly deliberate" "$AUDIT_OUT"
pass "a package carrying no sudoers file passes, and the archive is still counted"

# --- 9. an unreadable archive is an ERROR, not a clean package -------------

badmirror="$work/badmirror"
mkdir -p "$badmirror"
printf 'this is not a package archive at all\n' \
  >"$badmirror/omarchy-deck-9-9-any.pkg.tar.zst"
run_audit "$badmirror"
[[ $AUDIT_STATUS -eq 1 ]] ||
  fail "an archive bsdtar cannot read must be an error, not an empty member list" \
    "status=$AUDIT_STATUS $AUDIT_OUT"
[[ $AUDIT_OUT == *"could not list"* ]] || fail "the unreadable-archive error says so" "$AUDIT_OUT"
pass "a corrupt/unreadable package archive fails the audit instead of reading as clean"

# --- 10. no bsdtar + packages present is an ERROR, not a skip --------------
#
# The property under test is the one that makes this check trustworthy in a
# build container: it must refuse to report a clean payload it could not read.
# Built by handing the script a PATH with every tool it needs EXCEPT bsdtar.

# Mirror the whole real PATH as symlinks, minus bsdtar, rather than guessing a
# minimal tool list: the script's own dependencies (and deck-session.sh's, which
# it sources) are not this test's business, and a guessed list would make this
# test fail for the wrong reason the moment either grows one.
stubbin="$work/stubbin"
mkdir -p "$stubbin"
linked=0
while IFS= read -r -d ':' dir; do
  [[ -d $dir ]] || continue
  for entry in "$dir"/*; do
    [[ -f $entry && -x $entry ]] || continue
    name=${entry##*/}
    [[ $name == bsdtar ]] && continue
    [[ -e "$stubbin/$name" ]] && continue   # first match on PATH wins, as usual
    ln -s "$entry" "$stubbin/$name"
    linked=$((linked + 1))
  done
done <<<"$PATH:"
(( linked > 20 )) ||
  fail "the no-bsdtar PATH fixture only linked $linked binaries" \
    "It would fail for lack of a shell rather than for lack of bsdtar, which proves nothing."
[[ ! -e "$stubbin/bsdtar" ]] || fail "the no-bsdtar fixture accidentally contains bsdtar"

AUDIT_STATUS=0
AUDIT_OUT=$(PATH="$stubbin" "$AUDIT" "$mirror" 2>&1) || AUDIT_STATUS=$?
[[ $AUDIT_STATUS -eq 1 ]] ||
  fail "packages present but no bsdtar must be an error, not a silent skip" \
    "status=$AUDIT_STATUS $AUDIT_OUT"
[[ $AUDIT_OUT == *"bsdtar is not installed"* ]] ||
  fail "the missing-bsdtar error explains itself" "$AUDIT_OUT"
pass "packages present with no bsdtar fails loudly rather than reporting a clean payload"

# --- 11. several roots audit together, and one bad root fails the run ------

run_audit "$clean" "$ordinary" "$dirty"
[[ $AUDIT_STATUS -eq 1 ]] || fail "one bad root among several fails the whole run" "$AUDIT_OUT"
[[ $AUDIT_OUT == *"3 root(s)"* ]] || fail "all roots are reported in the summary" "$AUDIT_OUT"
pass "multiple payload roots are audited in one run; any offender fails it"

# --- 12. the shared predicate is a hard dependency, not a soft one ---------
#
# If deck-session.sh ever renames sudoers_line_is_blanket, this audit must stop
# rather than quietly find nothing. Checked by name here so the two files stay
# joined -- the whole point of sourcing instead of copying.
grep -q 'sudoers_line_is_blanket' "$REPO_ROOT/src/deck-session.sh" ||
  fail "src/deck-session.sh no longer defines sudoers_line_is_blanket" \
    "tools/iso-payload-audit.sh shares that predicate on purpose (PROGRESS.md 5.17). Re-point it before shipping."
grep -q 'sudoers_line_is_nopasswd' "$REPO_ROOT/src/deck-session.sh" ||
  fail "src/deck-session.sh no longer defines sudoers_line_is_nopasswd"
pass "the audit's shared predicate still exists in src/deck-session.sh"

printf '\nall iso-payload-audit tests passed\n'
