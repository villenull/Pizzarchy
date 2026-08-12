#!/usr/bin/env bash
# Unit tests for the `omarchy-deck` pacman package and its four wiring points
# in the patched builder/build-iso.sh -- T5d, docs/tasks/T5-fork-plan.md §3
# seam S4, docs/PROGRESS.md §3.1.
#
# No VM, no Docker, no network, no root, no makepkg. Seconds.
#
# ---------------------------------------------------------------------------
# What this suite is for
# ---------------------------------------------------------------------------
#
# Omarchy installs as a pacman package, so the Deck's install-time layer ships
# as its own pacman package, built into the ISO's offline mirror. Nothing about
# that is free: `omarchy-deck` exists in no online repository, and
# builder/build-iso.sh handles its three locally-built upstream packages in
# four separate places. Ours needs the same treatment in all four, or it is
#
#   1. never built                -> pacstrap fails on a missing target
#   2. left in the online -Syw    -> the ~6 GB download aborts
#   3. left out of the keep-set   -> prune-offline-mirror.sh DELETES it
#   4. left in the online resolve -> deck-nvidia-dry-run.sh's -S --print aborts
#
# Failures 1 and 3 are the dangerous ones: the build stays green and the
# install dies on the target, ~1000 packages in.
#
# ---------------------------------------------------------------------------
# 🔴 Two rules this suite follows, from docs/PROGRESS.md §5.30c
# ---------------------------------------------------------------------------
#
# (a) The wiring is asserted against the PATCHED TREE, never against the patch
#     text. A patch that stopped applying, or a hunk that landed somewhere
#     useless, still contains all the right words. So: clone the pinned
#     upstream, `git apply --3way` every overlay patch, and read the result.
#
# (b) A check that proves something is ABSENT must also prove it was LOOKING.
#     Every range assertion below first proves its range is non-empty and its
#     anchors were found; a missing anchor is an ERROR, never an empty range
#     that quietly matches nothing.

set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
DECK_DIR="$REPO_ROOT/iso/overlay/configs/deck"
PKGBUILD_ROOT="$DECK_DIR/pkgbuilds"
PKG_DIR="$PKGBUILD_ROOT/omarchy-deck"
PKGBUILD="$PKG_DIR/PKGBUILD"
INSTALL_LIST="$DECK_DIR/deck-install.packages"
GUARD="$DECK_DIR/deck-nvidia-dry-run.sh"
ISO_ROOT="$REPO_ROOT/iso"

# The one file the package installs. Named once here; every assertion about it
# reads this, so the test cannot drift from itself.
PAYLOAD_PATH=usr/share/omarchy-deck/README

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; [[ -n ${2:-} ]] && printf '%s\n' "$2" >&2; exit 1; }

ASSERTIONS=0
count() { ASSERTIONS=$((ASSERTIONS + 1)); pass "$1"; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# ===========================================================================
# 1. The PKGBUILD exists, parses, and declares what T5d requires of it
# ===========================================================================

[[ -d $PKGBUILD_ROOT ]] || fail "iso/overlay/configs/deck/pkgbuilds/ exists" \
  "This directory IS the declaration of which packages the build produces itself; the patched build-iso.sh derives deck_local_packages from its listing."
[[ -d $PKG_DIR ]] || fail "pkgbuilds/omarchy-deck/ exists"
[[ -f $PKGBUILD ]] || fail "pkgbuilds/omarchy-deck/PKGBUILD exists" "not found at $PKGBUILD"
bash -n "$PKGBUILD" || fail "the PKGBUILD is valid bash"
count "pkgbuilds/omarchy-deck/PKGBUILD exists and parses"

# Sourced in a subshell with a stubbed makepkg environment, so the fields are
# read as makepkg would evaluate them rather than grepped as text. A PKGBUILD
# that computes pkgver from `git describe` would fail here, which is the point:
# the build must not depend on the repo's git state or on the clock.
# shellcheck disable=SC2016 # the single-quoted body is a script for the inner
# bash, evaluated there with its own srcdir/pkgdir -- expanding it here is the bug
pkg_fields=$(
  env -i PATH="$PATH" HOME="$work" bash -c '
    set -e
    srcdir=/nonexistent/src
    pkgdir=/nonexistent/pkg
    startdir=/nonexistent
    # shellcheck disable=SC1090
    . "$1"
    printf "pkgname=%s\n" "$pkgname"
    printf "pkgver=%s\n" "$pkgver"
    printf "pkgrel=%s\n" "$pkgrel"
    printf "pkgdesc=%s\n" "$pkgdesc"
    printf "arch=%s\n" "${arch[*]}"
    printf "license=%s\n" "${license[*]}"
    printf "depends=%s\n" "${depends[*]:-}"
    printf "source=%s\n" "${source[*]:-}"
    printf "has_package_fn=%s\n" "$(declare -F package >/dev/null && echo yes || echo no)"
    printf "install_scriptlet=%s\n" "${install:-<none>}"
  ' _ "$PKGBUILD"
) || fail "the PKGBUILD can be sourced with a stubbed makepkg environment" "$pkg_fields"

field() { sed -n "s/^$1=//p" <<<"$pkg_fields"; }

[[ $(field pkgname) == omarchy-deck ]] ||
  fail "pkgname is omarchy-deck" "got: $(field pkgname)"
[[ $(field pkgname) == "$(basename "$PKG_DIR")" ]] ||
  fail "pkgname matches the directory name" \
    "build-iso.sh derives the package name from the DIRECTORY; a pkgname that disagrees means it builds an archive it then cannot find. dir=$(basename "$PKG_DIR") pkgname=$(field pkgname)"
[[ $(field arch) == any ]] || fail "arch=('any')" "got: $(field arch)"
[[ -n $(field pkgdesc) ]] || fail "the PKGBUILD has a real pkgdesc"
[[ $(field has_package_fn) == yes ]] || fail "the PKGBUILD defines a package() function"
count "pkgname=omarchy-deck, arch=any, a pkgdesc, and a package() function"

# A deterministic pkgver, stated as a property rather than a literal: sourcing
# it twice must give the same answer, and it must not be derived from git or
# from the date. `iso/bin/build` mounts /configs read-only with no .git in it,
# and a version that moves per build breaks the patched builder's
# "exactly one artifact per name" check.
pkgver_1=$(field pkgver)
[[ -n $pkgver_1 ]] || fail "pkgver is set"
[[ $pkgver_1 =~ ^[0-9]+(\.[0-9]+)*$ ]] ||
  fail "pkgver is a plain, hand-set version" "got: $pkgver_1"
grep -Eq 'pkgver *=.*(git|describe|date|\$\()' "$PKGBUILD" &&
  fail "pkgver must not be derived from git or the clock" "$(grep -n 'pkgver *=' "$PKGBUILD")"
grep -q '^pkgver()' "$PKGBUILD" &&
  fail "the PKGBUILD must not define a pkgver() function" \
    "makepkg would run it against a read-only /configs with no .git, and the version would move per build."
[[ $(field pkgrel) =~ ^[0-9]+$ ]] || fail "pkgrel is an integer" "got: $(field pkgrel)"
count "pkgver ($pkgver_1) is hand-set and deterministic -- no git describe, no date, no pkgver()"

# Licence. The repo declares none as of 2026-08-12 (no LICENSE file, no SPDX
# header), so this must be an explicitly flagged placeholder rather than an
# invented MIT. If a LICENSE ever lands, this assertion is what makes someone
# come back and replace the placeholder.
pkg_license=$(field license)
[[ -n $pkg_license ]] || fail "license is declared and non-empty"
if [[ $pkg_license == custom:* ]]; then
  [[ -f "$REPO_ROOT/LICENSE" || -f "$REPO_ROOT/LICENSE.md" || -f "$REPO_ROOT/COPYING" ]] &&
    fail "the PKGBUILD carries a placeholder licence but the repo now HAS a LICENSE file" \
      "Replace license=('$pkg_license') with the real one."
  grep -q 'PLACEHOLDER' "$PKGBUILD" ||
    fail "a placeholder licence must be flagged as one in the PKGBUILD" \
      "license=('$pkg_license') with no comment saying so is indistinguishable from a decision."
  count "license=('$pkg_license') is an explicitly flagged placeholder, and the repo still declares no licence"
else
  count "license=('$pkg_license') is a declared licence"

  # A declared licence brings three obligations, and all three are the kind that
  # look fine until someone reads the shipped ISO. The operator chose MIT on
  # 2026-08-12; MIT is NOT in /usr/share/licenses/common (every MIT text carries
  # its own copyright line), so a package under it must carry the text.
  root_license=""
  for cand in LICENSE LICENSE.md COPYING; do
    [[ -f "$REPO_ROOT/$cand" ]] && { root_license="$REPO_ROOT/$cand"; break; }
  done
  [[ -n $root_license ]] ||
    fail "license=('$pkg_license') is declared but the repo root has no LICENSE/LICENSE.md/COPYING" \
      "A licence named in metadata and absent from the tree grants nothing."
  count "the repo root carries the licence text (${root_license#"$REPO_ROOT"/})"

  # 🔴 The copy is unavoidable -- the container only sees this pkgbuild
  # directory -- so it is asserted instead of trusted. Two divergent grants in
  # one product is exactly the drift this project keeps paying for.
  pkg_license_file="$(dirname -- "$PKGBUILD")/LICENSE"
  [[ -f $pkg_license_file ]] ||
    fail "license=('$pkg_license') is declared but the pkgbuild directory has no LICENSE to ship" \
      "makepkg only sees this directory; a root-only licence never reaches the package."
  cmp -s "$root_license" "$pkg_license_file" ||
    fail "the pkgbuild directory's LICENSE differs from the repo root's" \
      "One of them was edited and the other was not. The ISO would ship the divergent copy."
  count "the packaged LICENSE is byte-identical to the repo root's"

  # shellcheck disable=SC2016 # the literal `$pkgname` is the string being searched for
  grep -q 'usr/share/licenses/\$pkgname/LICENSE' "$PKGBUILD" ||
    fail "package() does not install the licence text to /usr/share/licenses/\$pkgname/" \
      "license=('$pkg_license') without the text shipped is a claim, not a grant."
  count "package() installs the licence text to /usr/share/licenses/\$pkgname/"
fi

# depends=() is empty for now, and the reason has to be written down: anything
# added must also be in the offline mirror or pacstrap fails at install time.
[[ -z $(field depends) ]] ||
  fail "depends is empty in this slice" "got: $(field depends)"
grep -q 'offline mirror' "$PKGBUILD" ||
  fail "the PKGBUILD records why depends=() is not free to grow" \
    "Anything added to depends must also be present in the offline mirror (deck-install.packages or deck-mirror.packages), or the offline pacstrap fails."
count "depends=() and the PKGBUILD states the offline-mirror constraint on adding to it"

# No install= scriptlet, no units, no sudoers in this slice. The last of those
# is also enforced at build time by tools/iso-payload-audit.sh reading inside
# the built archive; this is the cheap, early half of the same question.
[[ $(field install_scriptlet) == "<none>" ]] ||
  fail "no install= scriptlet in this slice" "got: $(field install_scriptlet)"
# Comments are stripped first -- the PKGBUILD's own header names these three as
# things it does NOT ship, and a check that fired on the prohibition itself
# would have to be deleted rather than fixed.
pkgbuild_code=$(sed 's/#.*//' "$PKGBUILD")
[[ -n $(tr -d '[:space:]' <<<"$pkgbuild_code") ]] ||
  fail "stripping comments from the PKGBUILD left no code to inspect"
for forbidden in sudoers.d 'systemd/system' '.service'; do
  grep -qF -- "$forbidden" <<<"$pkgbuild_code" &&
    fail "the PKGBUILD must not ship '$forbidden' in this slice" \
      "$(grep -nF -- "$forbidden" <<<"$pkgbuild_code")"
done
# ...and the stripper must still be able to see a real one: a `sed` that ate
# the whole file would make the loop above pass on anything.
control_line='x=/etc/sudoers.d/99-x'
grep -qF -- 'sudoers.d' <<<"${control_line%%#*}" ||
  fail "the comment-stripping control failed: the forbidden-path check cannot see a real occurrence"
count "no install= scriptlet, no systemd unit and no sudoers drop-in (tools/iso-payload-audit.sh owns the build-time half)"

# ===========================================================================
# 2. package() actually installs the file it claims to
#
# Executed, not grepped: package() is run for real against a scratch pkgdir.
# `install -Dm644` needs no root and no makepkg.
# ===========================================================================

pkg_src="$work/src"
pkg_dst="$work/pkg"
mkdir -p "$pkg_src" "$pkg_dst"

# The local source listed in source=() must actually exist beside the PKGBUILD,
# or makepkg fails before package() is ever reached.
for src_entry in $(field source); do
  [[ -f "$PKG_DIR/$src_entry" ]] ||
    fail "source=('$src_entry') exists next to the PKGBUILD" \
      "makepkg copies local sources out of the recipe directory; a listed file that is not there fails the container build."
  cp "$PKG_DIR/$src_entry" "$pkg_src/$src_entry"
done
[[ -n $(field source) ]] || fail "the PKGBUILD declares its payload in source=()" \
  "Reaching into \$startdir instead would not be checked by makepkg at all."
count "every file in source=() exists beside the PKGBUILD ($(field source))"

# shellcheck disable=SC2016 # ditto: a script for the inner bash, not this one
pkg_run_out=$(
  env -i PATH="$PATH" HOME="$work" bash -c '
    set -e
    srcdir="$2"
    pkgdir="$3"
    # shellcheck disable=SC1090
    . "$1"
    package
  ' _ "$PKGBUILD" "$pkg_src" "$pkg_dst" 2>&1
) || fail "package() runs against a scratch pkgdir" "$pkg_run_out"

[[ -f "$pkg_dst/$PAYLOAD_PATH" ]] ||
  fail "package() installs /$PAYLOAD_PATH" \
    "produced instead: $(cd "$pkg_dst" && find . -type f | sort | head -20)"
[[ -s "$pkg_dst/$PAYLOAD_PATH" ]] || fail "the installed README is not empty"
# A package that installs nothing BEYOND its payload and its licence text -- so
# the [V]-tier probe after a QEMU install ("is our package on the target?") has
# exactly one answer to look for, and so a future slice cannot quietly widen the
# skeleton without this line going red.
#
# The licence text is admitted deliberately, not by loosening the check to a
# prefix or a count: the set is enumerated. MIT is not in
# /usr/share/licenses/common, so shipping it is an obligation of the licence the
# operator chose (2026-08-12), and the assertion above already proves it is
# byte-identical to the repo root's.
LICENSE_PATH="usr/share/licenses/omarchy-deck/LICENSE"
expected_files=$(printf '%s\n' "$PAYLOAD_PATH" "$LICENSE_PATH" | sort)
installed_files=$(cd "$pkg_dst" && find . -type f | sed 's|^\./||' | sort)
[[ $installed_files == "$expected_files" ]] ||
  fail "package() installs exactly the payload and the licence text in this slice" "got:
$installed_files
want:
$expected_files"
count "package() really installs exactly /$PAYLOAD_PATH and /$LICENSE_PATH (executed, not grepped)"

[[ -s "$pkg_dst/$LICENSE_PATH" ]] || fail "the installed licence text is not empty"
cmp -s "$REPO_ROOT/LICENSE" "$pkg_dst/$LICENSE_PATH" ||
  fail "the licence package() installed differs from the repo root's LICENSE" \
    "This is the executed proof, not the static one above: the file that would land on a target must be the grant this repo actually makes."
count "the licence that package() installs is byte-identical to the repo root's (executed)"

# The README has to say what it is for -- it IS the artefact someone finds on a
# target and has to make sense of.
readme_installed="$pkg_dst/$PAYLOAD_PATH"
for phrase in omarchy-deck 'S4' 'T5e' 'T5f' 'T12'; do
  grep -q -- "$phrase" "$readme_installed" ||
    fail "the installed README mentions '$phrase'" \
      "It states what the package is, which seam it implements, and what lands in it later."
done
count "the installed README names the package, seam S4, and the slices that will fill it (T5e/T5f/T12)"

# ===========================================================================
# 3. deck-install.packages carries the name, unqualified
# ===========================================================================

[[ -f $INSTALL_LIST ]] || fail "deck-install.packages exists"
install_entries=$(awk '!/^[[:space:]]*(#|$)/' "$INSTALL_LIST")
[[ -n $install_entries ]] || fail "deck-install.packages has entries"
grep -qx 'omarchy-deck' <<<"$install_entries" ||
  fail "deck-install.packages lists omarchy-deck" \
    "Without it the package is built, carried in the mirror, and installed by nothing. entries:
$install_entries"
grep -qx 'omarchy-deck' <<<"$install_entries" && [[ $(grep -c 'omarchy-deck' <<<"$install_entries") -eq 1 ]] ||
  fail "omarchy-deck appears exactly once in deck-install.packages"
count "deck-install.packages lists omarchy-deck exactly once"

while IFS= read -r entry; do
  [[ $entry != */* ]] ||
    fail "deck-install.packages entry '$entry' is repo-qualified" \
      "That file's own header: entries are resolved twice against the single-repo pacman-offline.conf, and 'repo/name' aborts both resolve_expected_packages and pacstrap."
done <<<"$install_entries"
count "no entry in deck-install.packages is repo-qualified (omarchy-deck included)"

# 🔴 The repo-level half of the single-source-of-truth property: the pkgbuilds
# directory listing IS the declaration, so every directory in it must be a real
# recipe AND must be in the install list. A recipe nobody installs is the
# silent half of the desync.
pkgbuild_dirs=()
while IFS= read -r -d '' d; do pkgbuild_dirs+=("$(basename "$d")"); done < <(
  find "$PKGBUILD_ROOT" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z
)
((${#pkgbuild_dirs[@]} > 0)) ||
  fail "pkgbuilds/ contains at least one package directory" \
    "An empty pkgbuilds/ makes the patched build-iso.sh exit 1 -- and would make every assertion in this section pass over nothing."
for d in "${pkgbuild_dirs[@]}"; do
  [[ -f "$PKGBUILD_ROOT/$d/PKGBUILD" ]] ||
    fail "pkgbuilds/$d has a PKGBUILD" "build-iso.sh treats a directory without one as a hard error."
  grep -qx -- "$d" <<<"$install_entries" ||
    fail "pkgbuilds/$d is built but is not in deck-install.packages" \
      "It would be built into the offline mirror, kept by the prune, and installed by nothing."
done
count "all ${#pkgbuild_dirs[@]} recipe directories (${pkgbuild_dirs[*]}) have a PKGBUILD and appear in deck-install.packages"

# ===========================================================================
# 4. The four wiring points, asserted against the PATCHED tree
# ===========================================================================

if [[ ! -e "$ISO_ROOT/upstream/.git" ]]; then
  printf 'skip - iso/upstream is not checked out here, so the following did NOT run:\n'
  printf 'skip -   * wiring point 1 (built into the offline mirror)\n'
  printf 'skip -   * wiring point 2 (stripped from the online pacman -Syw)\n'
  printf 'skip -   * wiring point 3 (added back to the prune keep-set)\n'
  printf 'skip -   * wiring point 4 (excluded from deck-nvidia-dry-run.sh)\n'
  printf 'skip -   * the single-source-of-truth property, and bash -n on the patched builder\n'
  printf 'skip - (.github/workflows/ci.yml has no submodules: key; test-iso-build.sh skips for the same reason)\n'
else
  shopt -s nullglob
  overlay_patches=("$ISO_ROOT"/overlay/patches/*.patch)
  shopt -u nullglob
  ((${#overlay_patches[@]} > 0)) ||
    fail "there are overlay patches to apply" "Everything in this section would otherwise assert over an unpatched tree."

  patched="$work/patched"
  # advice.detachedHead on the CLONE as well as the checkout: iso/upstream is a
  # submodule and is itself at a detached HEAD, so `git clone` emits the notice
  # too, and --quiet does not cover advice. Left unsuppressed it buries this
  # suite's output in eleven lines of git tutorial.
  git -c advice.detachedHead=false clone --quiet --local --no-hardlinks \
    "$ISO_ROOT/upstream" "$patched" ||
    fail "could not clone iso/upstream"
  git -C "$patched" -c advice.detachedHead=false checkout --quiet \
    "$(git -C "$ISO_ROOT/upstream" rev-parse HEAD)" 2>/dev/null ||
    fail "could not check the clone out at the UPSTREAM pin"
  for p in "${overlay_patches[@]}"; do
    git -C "$patched" apply --3way "$p" >/dev/null 2>&1 ||
      fail "$(basename -- "$p") does not apply to the pinned upstream" \
        "Every assertion below reads the PATCHED file, so a patch that no longer applies must go red here rather than be read around."
  done
  count "all ${#overlay_patches[@]} overlay patches apply to the pinned upstream (the tree everything below reads)"

  BUILD_ISO="$patched/builder/build-iso.sh"
  [[ -f $BUILD_ISO ]] || fail "the patched tree has builder/build-iso.sh"
  bash -n "$BUILD_ISO" || fail "the patched builder/build-iso.sh is valid bash"
  bash -n "$patched/configs/deck/deck-nvidia-dry-run.sh" 2>/dev/null ||
    bash -n "$GUARD" ||
    fail "deck-nvidia-dry-run.sh is valid bash"
  count "the patched builder/build-iso.sh and deck-nvidia-dry-run.sh both parse"

  # --- anchors -------------------------------------------------------------
  #
  # Every range assertion below is bounded by two of these. A missing anchor is
  # an ERROR, so a range can never silently collapse to nothing and let a grep
  # match zero lines for the wrong reason (docs/PROGRESS.md §5.30c).
# line_of <var> <pattern> <label> -- assigns in THIS shell, deliberately.
  # `x=$(line_of ...)` would run fail() in a subshell: its `exit 1` would leave
  # only that subshell and the caller would carry on with the error text as a
  # line number. That is precisely the passes-for-the-wrong-reason shape
  # docs/PROGRESS.md §5.30c is about, so the anchor lookup does not use one.
  line_of() {
    local __var=$1 pattern=$2 label=$3 n
    # `|| true` on the grep, not on the pipeline: with `set -o pipefail` a
    # no-match grep makes the whole substitution non-zero, `set -e` kills the
    # suite on the assignment, and the diagnostic below never prints. A tool
    # that dies without saying why is the same failure class as one that passes
    # without looking (docs/PROGRESS.md §5.30c). Measured, in the mutation run.
    n=$( { grep -n -- "$pattern" "$BUILD_ISO" || true; } | head -1 | cut -d: -f1)
    [[ -n $n ]] || fail "anchor not found in the patched build-iso.sh: $label" \
      "pattern: $pattern
Without it the range assertions below would read an empty or wrong region and pass over nothing."
    printf -v "$__var" '%s' "$n"
  }

  # Declared up front so the indirect assignment inside line_of reads as a real
  # assignment, both to a linter and to a person.
  L_decl='' L_makepkg='' L_dryrun='' L_syw='' L_prune=''
  line_of L_decl 'deck_local_packages=()' 'the deck_local_packages declaration'
  line_of L_makepkg 'makepkg --noconfirm' 'the makepkg call that builds our package'
  # The INVOCATIONS, not any mention: the comments around these blocks name the
  # scripts too, and anchoring on the first mention would end a region before
  # the code it is supposed to contain. (Measured: it did.)
  # shellcheck disable=SC2016 # a literal grep pattern, see above
  line_of L_dryrun 'bash "$deck_list_dir/deck-nvidia-dry-run.sh"' 'the NVIDIA dry-run invocation'
  line_of L_syw 'download_offline_packages() {' 'the offline mirror download function'
  line_of L_prune 'bash /builder/prune-offline-mirror.sh' 'the prune invocation'

  (( L_decl < L_makepkg && L_makepkg < L_dryrun && L_dryrun < L_syw && L_syw < L_prune )) ||
    fail "the patched build-iso.sh's wiring points are out of order" \
      "decl=$L_decl makepkg=$L_makepkg dryrun=$L_dryrun syw=$L_syw prune=$L_prune
The declaration must precede the build, the build must precede the dry run (which reads the merged lists), the strip must precede the download, and the keep-set must precede the prune."
  count "the five anchors are present and in order (decl=$L_decl build=$L_makepkg dryrun=$L_dryrun syw=$L_syw prune=$L_prune)"

  # region <first> <last> -- the patched file's lines in [first,last]
  region() { sed -n "${1},${2}p" "$BUILD_ISO"; }

  # require_in <first> <last> <label> <pattern...>
  # Proves the region is non-empty first, so "no match" can never be confused
  # with "no region".
  require_in() {
    local first=$1 last=$2 label=$3
    shift 3
    local text pattern
    text=$(region "$first" "$last")
    [[ -n $text ]] || fail "$label: the region ($first..$last) is empty" \
      "The assertion would have matched nothing for the wrong reason."
    for pattern in "$@"; do
      grep -qF -- "$pattern" <<<"$text" ||
        fail "$label" "expected to find, between lines $first and $last of the patched build-iso.sh:
  $pattern
region was $(grep -c '' <<<"$text") lines."
    done
  }

  # --- wiring point 1: built into the offline mirror -----------------------
  #
  # shellcheck disable=SC2016 # every argument below is a LITERAL grep pattern
  # that must match "${deck_local_packages[@]}" etc. verbatim in the patched
  # file; expanding it here would search for this suite's own empty variables.
  require_in "$L_decl" "$L_makepkg" \
    "wiring point 1: omarchy-deck is not built into the offline mirror" \
    'for deck_pkg in "${deck_local_packages[@]}"' \
    'makepkg --noconfirm' \
    'su builder -c' \
    'PKGDEST='
  # The mechanics build-omarchy-packages.sh established, and the reasons they
  # exist: makepkg refuses to run as root, and /configs is a read-only bind
  # mount (iso/bin/build passes it as :ro), so the recipe must be copied out.
  # shellcheck disable=SC2016 # a literal grep pattern, see above
  require_in "$L_decl" "$L_makepkg" \
    "wiring point 1: the recipe is not copied out of the read-only /configs mount" \
    'cp -a "$deck_pkgbuild_dir/$deck_pkg"' \
    'chown -R builder:builder'
  # The builder user may or may not exist: build-omarchy-packages.sh creates it
  # and only runs under --local-source.
  require_in "$L_decl" "$L_makepkg" \
    "wiring point 1: the builder user is not handled for both states" \
    'if id builder' \
    'useradd -m -s /bin/bash builder'
  # The offline mirror is a persistent bind mount across builds, so a previous
  # run's artifact survives; two files for one name fails the keep-set check.
  # shellcheck disable=SC2016 # a literal grep pattern, see above
  require_in "$L_decl" "$L_makepkg" \
    "wiring point 1: a stale artifact from a previous build is not cleared" \
    'rm -f "$offline_mirror_dir/$deck_pkg-"*.pkg.tar.*'
  count "wiring point 1: makepkg builds every deck_local_packages entry into the offline mirror, as non-root, out of a writable copy"

  # --- wiring point 2: excluded from the dry run's ONLINE resolve ----------
  # shellcheck disable=SC2016 # a literal grep pattern, see above
  require_in "$L_makepkg" "$L_dryrun" \
    "wiring point 2: deck-nvidia-dry-run.sh is not told which packages are locally built" \
    'DECK_LOCAL_PACKAGES="${deck_local_packages[*]}"'
  count "wiring point 2: the dry run is passed deck_local_packages, so its online -S --print does not abort on a package no repo has"

  # --- wiring point 3: stripped from the online pacman -Syw ---------------
# ⚠️ The patterns here must be OURS. Upstream's own LOCAL_OMARCHY_BUILD block
  # sits in this same region and also contains `grep -Fxv`, so a bare
  # 'grep -Fxv' would keep matching after our block was deleted -- measured, in
  # the mutation run that produced these patterns.
  # shellcheck disable=SC2016 # a literal grep pattern, see above
  require_in "$L_dryrun" "$L_syw" \
    "wiring point 3: omarchy-deck is not stripped from the online -Syw target list" \
    'for deck_pkg in "${deck_local_packages[@]}"' \
    'grep -Fxv "${deck_strip_args[@]}"'
  count "wiring point 3: deck_local_packages is stripped from all_packages before the ~6 GB pacman -Syw"

  # --- wiring point 4: added back to the prune keep-set -------------------
# ⚠️ Ours, not upstream's: the LOCAL_OMARCHY_BUILD keep-set block is in this
  # region too and also appends to required_package_files.
  # shellcheck disable=SC2016 # a literal grep pattern, see above
  require_in "$L_syw" "$L_prune" \
    "wiring point 4: omarchy-deck is not added back to the prune keep-set" \
    'for deck_pkg in "${deck_local_packages[@]}"' \
    'required_package_files+=("$deck_pkg_file")'
  # Identity read out of the archive, not guessed from the filename -- the same
  # verification upstream's own keep-set block does for its three.
  require_in "$L_syw" "$L_prune" \
    "wiring point 4: the kept artifact's identity is not verified with pacman -Qp" \
    'pacman -Qp'
  count "wiring point 4: deck_local_packages is appended to required_package_files, with its identity read via pacman -Qp"

  # --- 🔴 the single-source-of-truth property ------------------------------
  #
  # Four consumers, one declaration. A desync here is silent: the package
  # builds, the prune deletes it, and pacstrap fails on the target.
  #
  # The four require_in blocks above are what make this mutation-sensitive:
  # each reads deck_local_packages inside a region only that consumer occupies,
  # so deleting any single consumer's use goes red on its own assertion. What
  # is left to prove is that they are all reading ONE thing.

  decl_count=$(grep -c 'deck_local_packages=(' "$BUILD_ISO" || true)
  (( decl_count == 1 )) ||
    fail "deck_local_packages is assigned in $decl_count places, expected 1" \
      "$(grep -n 'deck_local_packages=(' "$BUILD_ISO")
Two declarations is exactly the desync this property exists to prevent."

  # The array's CONTENTS are derived from the pkgbuilds/ directory listing,
  # never enumerated. A hard-coded list here would be a second source of truth
  # that agrees with the directory only until someone edits one of them.
  # shellcheck disable=SC2016 # a literal grep pattern, see above
  require_in "$L_decl" "$L_makepkg" \
    "the declaration is not derived from the pkgbuilds directory" \
    'for deck_pkgbuild_path in "$deck_pkgbuild_dir"/*/' \
    'deck_local_packages+=("$deck_pkg_name")'

  # Scoped rather than blanket: the string "omarchy-deck" legitimately appears
  # in this file in prose and in scratch filenames. What must never appear is
  # the name used AS a package name -- on a line that manipulates the array, or
  # as a literal grep/strip argument. Both are what a "quick fix" to a broken
  # wiring point looks like.
  literal_uses=$(grep -nE 'deck_local_packages.*omarchy-deck|-e +"?omarchy-deck"?' "$BUILD_ISO" || true)
  [[ -z $literal_uses ]] ||
    fail "the patched build-iso.sh uses 'omarchy-deck' as a literal package name" \
      "$literal_uses
The name must reach every consumer from the pkgbuilds/ directory listing alone."
  # ...and the matcher must be able to see one, or its silence proves nothing.
  grep -qE 'deck_local_packages.*omarchy-deck|-e +"?omarchy-deck"?' \
    <<<'  deck_local_packages=(omarchy-deck)' ||
    fail "the literal-name matcher does not fire on a known-bad line" \
      "Its clean result above would be indistinguishable from a pattern that matches nothing."

  # ...and the derivation refuses to be vacuous. An empty pkgbuilds/, or a
  # directory without a PKGBUILD, would otherwise produce an empty array that
  # every one of the four consumers loops over zero times, silently.
  require_in "$L_decl" "$L_makepkg" \
    "an empty or malformed pkgbuilds/ does not fail the build" \
    'has no PKGBUILD' \
    'contains no package directories'
  count "🔴 one declaration, derived from pkgbuilds/, read by all four consumers -- and the name is never used as a literal package name"

  # The patched tree carries the patches only; iso/bin/build rsyncs
  # overlay/configs/ onto the scratch copy separately, which is why
  # configs/deck/ is legitimately absent here. Said out loud so a later reader
  # does not mistake the gap for a missing wiring point.
  printf 'note - configs/deck/ (the package lists and the pkgbuilds/ directory) reaches the container via iso/bin/build'"'"'s rsync, not via these patches, so it is absent from this patch-only tree -- section 3 covers it in the repo instead\n'
fi

# ===========================================================================
# 5. shellcheck on the shell files this slice touched
# ===========================================================================

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x "$GUARD" || fail "shellcheck -x on deck-nvidia-dry-run.sh is clean"
  shellcheck -x "${BASH_SOURCE[0]}" || fail "shellcheck -x on this suite is clean"
  count "shellcheck -x is clean on deck-nvidia-dry-run.sh and on this suite"
else
  # Loud, not silent: a skipped lint that printed nothing is the shape
  # docs/PROGRESS.md §5.30c catalogues.
  printf 'skip - shellcheck is not on PATH here, so deck-nvidia-dry-run.sh and this suite were NOT linted; CI installs a pinned build (.github/workflows/ci.yml)\n'
fi

printf '\nall omarchy-deck package tests passed (%d assertions)\n' "$ASSERTIONS"
