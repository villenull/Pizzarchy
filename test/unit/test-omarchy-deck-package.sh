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
#
# ---------------------------------------------------------------------------
# 2026-08-12: the package stopped being a skeleton
# ---------------------------------------------------------------------------
#
# It now carries T12's patch seam, so this suite grew a third question beside
# "does the pipeline carry it?" and "is it wired into the builder?":
#
#   does the ARCHIVE actually contain the applier, its hook, its unit (ENABLED),
#   and both halves of every patch, at the paths the consumers already expect?
#
# The consumers are two, and neither is edited here -- they are read:
#
#   src/omarchy-deck-patches/omarchy-deck-apply-patches   DEFAULT_PATCH_DIR
#   .../orchestrator/deck_patches.py                      APPLIER_REL,
#                                                         PATCH_DIR_REL
#
# Every path assertion below is DERIVED from one of those, never retyped. A
# suite that hard-codes /usr/bin/omarchy-deck-apply-patches would stay green
# while the package and the thing that runs it drifted apart, which is the
# exact failure this package existed to fix (`status: "absent"` on every
# install, deliberately loudly, until this slice).
#
# 🔴 And the payload is a COPY. src/omarchy-deck-patches/ stays canonical --
# two other suites and iso/bin/build's guard 6.6 read it there -- while makepkg
# can only see the pkgbuild directory. So section 2b asserts the two directories
# hold the SAME SET of files, byte for byte. Without that, a new patch could be
# build-checked and never shipped, or shipped and never build-checked.

set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
DECK_DIR="$REPO_ROOT/iso/overlay/configs/deck"
PKGBUILD_ROOT="$DECK_DIR/pkgbuilds"
PKG_DIR="$PKGBUILD_ROOT/omarchy-deck"
PKGBUILD="$PKG_DIR/PKGBUILD"
INSTALL_LIST="$DECK_DIR/deck-install.packages"
GUARD="$DECK_DIR/deck-nvidia-dry-run.sh"
ISO_ROOT="$REPO_ROOT/iso"

# The canonical home of T12's payload. The pkgbuild directory carries a copy of
# every file in here (makepkg cannot see outside its own recipe directory), and
# section 2b proves the two are the same set, byte for byte.
T12_SRC="$REPO_ROOT/src/omarchy-deck-patches"
APPLIER_SRC="$T12_SRC/omarchy-deck-apply-patches"
DECK_PATCHES_PY="$ISO_ROOT/overlay/configs/airootfs/usr/share/omarchy-iso/orchestrator/deck_patches.py"
# A real package manifest from a fresh Omarchy 4 install -- the package set the
# offline mirror is built to satisfy. Section 1's depends check resolves every
# dependency against it rather than against a list retyped here.
FRESH_MANIFEST="$ISO_ROOT/upstream/manifests/fresh-4.json"

# The README the skeleton slice shipped, and still ships. Named once here;
# every assertion about it reads this, so the test cannot drift from itself.
PAYLOAD_PATH=usr/share/omarchy-deck/README

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; [[ -n ${2:-} ]] && printf '%s\n' "$2" >&2; exit 1; }

ASSERTIONS=0
count() { ASSERTIONS=$((ASSERTIONS + 1)); pass "$1"; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# ===========================================================================
# 0. The contract, DERIVED from the two files that define it
#
# Nothing below retypes a path. Each derivation must produce something, or the
# suite stops here -- a scrape that came back empty and was then compared
# against an empty expectation is the "found nothing == found no problems" bug
# this repo has paid for before (docs/PROGRESS.md §5.30c).
# ===========================================================================

for f in "$APPLIER_SRC" "$DECK_PATCHES_PY" "$FRESH_MANIFEST"; do
  [[ -f $f ]] || fail "the files this suite derives its expectations from exist" \
    "missing: ${f#"$REPO_ROOT"/}"
done

# The applier's own default patch directory, absolute, from its readonly
# declaration. This is where it will look on a target no matter what the
# package does, so it is what the package has to hit.
APPLIER_PATCH_DIR=$(sed -n 's/^readonly DEFAULT_PATCH_DIR=\(.*\)$/\1/p' "$APPLIER_SRC")
[[ $APPLIER_PATCH_DIR == /* ]] ||
  fail "the applier declares an absolute DEFAULT_PATCH_DIR" \
    "scraped: '$APPLIER_PATCH_DIR' from ${APPLIER_SRC#"$REPO_ROOT"/} -- the scrape failed, so nothing below would have been checked against anything."

# The orchestrator step's view of the same two paths, relative to the target
# mount. deck_patches.py is NOT edited by this slice; it is the consumer whose
# expectations the package has to satisfy, and it says so itself.
#
# Read out by EVALUATING the module-level constants, not by grepping for a
# quoted literal: deck_patches.py composes them (`APPLIER_REL = f"usr/bin/..."`)
# precisely because iso/bin/build's guard 6.4a fails the build on a bare
# /usr/bin/omarchy-* literal anywhere in that directory. A regex for the string
# would find nothing and, if that silence were read as "no expectation", this
# whole section would assert against "".
py_field() {
  python3 - "$DECK_PATCHES_PY" "$1" <<'PY'
import ast, sys
src = open(sys.argv[1]).read()
ns = {}
for node in ast.parse(src).body:
    # Module-level `NAME = <expr>` only, and only expressions that fold to a
    # string out of names already read. Anything else is skipped rather than
    # executed: this reads a contract, it does not run somebody's module.
    if not isinstance(node, ast.Assign) or len(node.targets) != 1:
        continue
    target = node.targets[0]
    if not isinstance(target, ast.Name):
        continue
    try:
        value = eval(compile(ast.Expression(node.value), "<c>", "eval"), {"__builtins__": {}}, dict(ns))
    except Exception:
        continue
    if isinstance(value, str):
        ns[target.id] = value
if sys.argv[2] not in ns:
    sys.exit(1)
print(ns[sys.argv[2]])
PY
}
STEP_APPLIER_REL=$(py_field APPLIER_REL)
STEP_PATCH_DIR_REL=$(py_field PATCH_DIR_REL)
[[ -n $STEP_APPLIER_REL && $STEP_APPLIER_REL != /* ]] ||
  fail "deck_patches.py declares APPLIER_REL as a target-relative path" \
    "scraped: '$STEP_APPLIER_REL'"
[[ -n $STEP_PATCH_DIR_REL && $STEP_PATCH_DIR_REL != /* ]] ||
  fail "deck_patches.py declares PATCH_DIR_REL as a target-relative path" \
    "scraped: '$STEP_PATCH_DIR_REL'"

# The two consumers must already agree with each other; if they do not, the
# package cannot satisfy both and this suite would be asserting against a
# contradiction.
[[ "/$STEP_PATCH_DIR_REL" == "$APPLIER_PATCH_DIR" ]] ||
  fail "the applier and deck_patches.py disagree about the patch directory" \
    "applier DEFAULT_PATCH_DIR=$APPLIER_PATCH_DIR
deck_patches.py PATCH_DIR_REL=/$STEP_PATCH_DIR_REL
The package cannot install into both. Fix the consumers before the package."
count "the applier ($APPLIER_PATCH_DIR) and deck_patches.py agree on the patch directory, and APPLIER_REL is $STEP_APPLIER_REL"

# The payload, enumerated from the canonical directory rather than listed here:
# a patch added to src/omarchy-deck-patches/patches/ must show up in the
# package without anybody remembering to edit this file.
mapfile -t T12_PATCH_FILES < <(cd "$T12_SRC/patches" && find . -maxdepth 1 -type f -printf '%f\n' | sort)
((${#T12_PATCH_FILES[@]} > 0)) ||
  fail "src/omarchy-deck-patches/patches/ contains files" \
    "Everything about the patch payload below would assert over an empty set."
# Both halves of every patch. A .patch whose .meta never shipped is `bad_meta`
# and a non-zero exit on the target -- the applier refuses to apply a patch that
# declares no target and no post-conditions.
for p in "${T12_PATCH_FILES[@]}"; do
  case $p in
  *.patch) [[ -f "$T12_SRC/patches/${p%.patch}.meta" ]] ||
    fail "every .patch in src/omarchy-deck-patches/patches/ has a .meta sibling" \
      "missing: ${p%.patch}.meta" ;;
  *.meta) [[ -f "$T12_SRC/patches/${p%.meta}.patch" ]] ||
    fail "every .meta has a .patch sibling" "missing: ${p%.meta}.patch" ;;
  *) fail "unexpected file in src/omarchy-deck-patches/patches/: $p" \
    "Only *.patch and *.meta belong there; the package installs the whole directory." ;;
  esac
done
count "the T12 payload enumerates ${#T12_PATCH_FILES[@]} patch file(s), every .patch paired with its .meta"

# The three non-patch payload files, also enumerated from the canonical
# directory, with their destinations. The applier's is derived above; the other
# two are fixed by what reads them (pacman's hook directory, systemd's unit
# directory) and are stated here once.
T12_APPLIER=omarchy-deck-apply-patches
T12_HOOK=50-omarchy-deck-reapply-patches.hook
T12_UNIT=omarchy-deck-patch-check.service
HOOK_DEST="usr/share/libalpm/hooks/$T12_HOOK"
UNIT_DEST="usr/lib/systemd/system/$T12_UNIT"
# ...and the .wants directory is read out of the unit's own [Install] section,
# because that is exactly what `systemctl enable` would have used. A package
# that shipped the symlink under a target the unit never asked for would be
# enabled in name only.
WANTS_TARGET=$(sed -n 's/^WantedBy=//p' "$T12_SRC/$T12_UNIT" | head -1)
[[ $WANTS_TARGET == *.target ]] ||
  fail "$T12_UNIT declares a WantedBy= target in its [Install] section" \
    "scraped: '$WANTS_TARGET' -- without one, 'systemctl enable' has nothing to do and the shipped symlink below could point anywhere."
WANTS_DEST="usr/lib/systemd/system/$WANTS_TARGET.wants/$T12_UNIT"
[[ $(basename -- "$APPLIER_SRC") == "$T12_APPLIER" ]] ||
  fail "the applier's filename is $T12_APPLIER"
[[ $STEP_APPLIER_REL == */"$T12_APPLIER" ]] ||
  fail "deck_patches.py expects the applier under a different name" \
    "APPLIER_REL=$STEP_APPLIER_REL"

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

# ---------------------------------------------------------------------------
# depends -- 🔴 EVERY ENTRY MUST BE REACHABLE IN THE OFFLINE MIRROR
# ---------------------------------------------------------------------------
#
# The target install is offline. A dependency the mirror does not carry fails
# pacstrap ~1000 packages in, on a device with no terminal -- so this is not a
# style check. Each name is resolved against iso/upstream/manifests/fresh-4.json,
# a package manifest captured from a REAL fresh Omarchy 4 install: the mirror is
# built by `pacman -Syw` over the merged install list plus its dependency
# closure and pruned to what that resolve selected, so a package present on a
# fresh install is a package the mirror carries.
#
# It is evidence, not proof -- the mirror is not built here (no container, no
# network) -- and it is the strongest evidence available at this tier.
pkg_depends=$(field depends)
[[ -n $pkg_depends ]] ||
  fail "depends=() is empty, but the applier this package now ships shells out" \
    "omarchy-deck-apply-patches refuses to start without git (exit 4) and reports a postcondition_failed when it cannot find qmllint. An empty depends= makes both a runtime surprise on the target."
grep -q 'offline mirror' "$PKGBUILD" ||
  fail "the PKGBUILD records why depends= is not free to grow" \
    "Anything in depends must also be reachable in the offline mirror, or the offline pacstrap fails."

manifest_has() {
  python3 - "$FRESH_MANIFEST" "$1" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    doc = json.load(fh)
names = doc.get("packages", {}).get("all")
if not isinstance(names, list) or not names:
    sys.exit(2)  # the manifest did not parse the way this check assumes
sys.exit(0 if sys.argv[2] in names else 1)
PY
}
# ...and the lookup must be able to say no. A manifest_has that returned 0 for
# everything -- a wrong key, an empty list read as "no objection" -- would make
# the loop below pass over any dependency at all, including a typo.
if manifest_has 'omarchy-deck-there-is-no-such-package'; then
  fail "the offline-mirror lookup answers yes to a package that cannot exist" \
    "Its verdicts on the real dependencies below would mean nothing."
fi
manifest_has bash ||
  fail "the offline-mirror lookup cannot find a package that is certainly there" \
    "It reads packages.all from ${FRESH_MANIFEST#"$REPO_ROOT"/}; if that shape changed, every verdict below is wrong."

for dep in $pkg_depends; do
  [[ $dep != */* ]] ||
    fail "depends entry '$dep' is repo-qualified" \
      "The offline pacman.conf declares exactly one repo; a 'repo/name' dependency aborts the resolve."
  [[ $dep != *[\<\>=]* ]] ||
    fail "depends entry '$dep' carries a version constraint" \
      "The mirror carries whatever the pinned runtime resolved to; a constraint this suite cannot evaluate would be checked for the first time at pacstrap."
  manifest_has "$dep" ||
    fail "depends entry '$dep' is not in the fresh Omarchy 4 package manifest" \
      "Nothing else would notice until pacstrap failed on the target. Add it to deck-mirror.packages (or drop the dependency), and re-check."
done
count "every dependency ($pkg_depends) is unqualified, unversioned, and present in the fresh-install manifest the offline mirror is built from"

# The applier's actual external calls, so depends= cannot quietly fall behind
# what the code does. Only the two the applier treats as FATAL are demanded --
# it guards pacman and omarchy-notification-send with `command -v` and degrades
# in a defined way, and depending on those would be a claim the code does not
# make.
grep -q "command -v git" "$APPLIER_SRC" ||
  fail "the applier no longer checks for git" \
    "This assertion exists so the depends= entry below cannot outlive its reason."
grep -qw 'git' <<<"$pkg_depends" ||
  fail "the applier requires git (it exits 4 without it) but depends= does not name it"
grep -q 'qt6/bin' "$APPLIER_SRC" ||
  fail "the applier no longer searches Qt6's bin directory for qmllint"
grep -qw 'qt6-declarative' <<<"$pkg_depends" ||
  fail "the applier's qmllint post-condition needs qt6-declarative, and depends= does not name it" \
    "A qmllint it cannot find is a postcondition_failed, not a skip -- deliberately (a post-condition that did not run must never count as one that passed). Without the dependency that is a coin flip on what else pulled Qt6 in."
count "depends= names what the applier actually shells out to and treats as fatal (git, qt6-declarative), and nothing it merely probes"

# No install= scriptlet, no sudoers. The latter is also enforced at build time
# by tools/iso-payload-audit.sh reading inside the built archive; this is the
# cheap, early half of the same question.
#
# ⚠️ 'systemd/system' and '.service' USED to be on this list, when the package
# was a skeleton that shipped neither. They are gone deliberately: this package
# now ships omarchy-deck-patch-check.service on purpose, and section 2 asserts
# both that it lands and that it is ENABLED. The install= prohibition survives
# that change -- the unit is enabled by a shipped .wants symlink, not by a
# scriptlet -- so this is a narrowing of the rule, not a waiver of it.
[[ $(field install_scriptlet) == "<none>" ]] ||
  fail "no install= scriptlet" \
    "got: $(field install_scriptlet). The unit is enabled by the multi-user.target.wants symlink package() ships; a scriptlet would be a second mechanism enabling units in the same install."
# Comments are stripped first -- the PKGBUILD's own header names sudoers as
# something it does NOT ship, and a check that fired on the prohibition itself
# would have to be deleted rather than fixed.
pkgbuild_code=$(sed 's/#.*//' "$PKGBUILD")
[[ -n $(tr -d '[:space:]' <<<"$pkgbuild_code") ]] ||
  fail "stripping comments from the PKGBUILD left no code to inspect"
grep -qF -- 'sudoers.d' <<<"$pkgbuild_code" &&
  fail "the PKGBUILD must not ship a sudoers drop-in" \
    "$(grep -nF -- 'sudoers.d' <<<"$pkgbuild_code")"
# ...and the stripper must still be able to see a real one: a `sed` that ate
# the whole file would make the loop above pass on anything.
control_line='x=/etc/sudoers.d/99-x'
grep -qF -- 'sudoers.d' <<<"${control_line%%#*}" ||
  fail "the comment-stripping control failed: the forbidden-path check cannot see a real occurrence"
count "no install= scriptlet and no sudoers drop-in (tools/iso-payload-audit.sh owns the build-time half)"

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

# 🔴 No subdirectories in source=(). Measured by reading makepkg, not guessed:
# /usr/share/makepkg/util/source.sh's get_filename reduces a non-URL entry to
# ${netfile##*/} -- its BASENAME -- and get_filepath then looks for
# $startdir/<basename>. So source=('patches/x.patch') aborts the container build
# with "was not found in the build directory" while the file sits right there,
# and this suite's own `cp` above would have hidden it by succeeding.
for src_entry in $(field source); do
  [[ $src_entry != */* ]] ||
    fail "source=('$src_entry') contains a directory component" \
      "makepkg reduces a local source to its basename and then looks for \$startdir/<basename>; this entry can never be found. Put the file flat beside the PKGBUILD and re-nest it in package()."
done
count "every file in source=() exists beside the PKGBUILD, and none of them is a path makepkg cannot resolve"

# ===========================================================================
# 2b. The payload beside the PKGBUILD is the SAME payload as src/'s
#
# 🔴 The copy is unavoidable and therefore asserted, exactly like LICENSE:
# makepkg only ever sees the recipe directory, while src/omarchy-deck-patches/
# is what test-t12-patch-applier.sh, test-deck-configure-patches.py,
# test/t12-patch-seam-container-e2e.sh and iso/bin/build's guard 6.6 all read.
# A patch in one and not the other is either shipped-but-never-build-checked or
# build-checked-but-never-shipped, and both are silent until a target is wrong.
# ===========================================================================

payload_pairs=()
for f in "$T12_APPLIER" "$T12_HOOK" "$T12_UNIT"; do
  payload_pairs+=("$T12_SRC/$f|$PKG_DIR/$f")
done
for f in "${T12_PATCH_FILES[@]}"; do
  payload_pairs+=("$T12_SRC/patches/$f|$PKG_DIR/$f")
done
for pair in "${payload_pairs[@]}"; do
  canonical=${pair%%|*}
  copy=${pair##*|}
  [[ -f $copy ]] ||
    fail "the pkgbuild directory carries a copy of ${canonical#"$T12_SRC"/}" \
      "missing: ${copy#"$REPO_ROOT"/}
makepkg cannot see src/omarchy-deck-patches/, so a file that is not here never reaches the package."
  cmp -s "$canonical" "$copy" ||
    fail "the packaged copy of $(basename -- "$copy") differs from src/omarchy-deck-patches/" \
      "One was edited and the other was not. The ISO would ship the divergent copy.
  canonical: ${canonical#"$REPO_ROOT"/}
  packaged:  ${copy#"$REPO_ROOT"/}"
done
count "all ${#payload_pairs[@]} payload files beside the PKGBUILD are byte-identical to src/omarchy-deck-patches/"

# ...and the SET matches in the other direction too. Byte-identity over the
# canonical list alone would say nothing about a stray patch that exists only in
# the pkgbuild directory -- it would ship, and guard 6.6 would never have
# checked it against the pinned runtime.
canonical_set=$(printf '%s\n' "$T12_APPLIER" "$T12_HOOK" "$T12_UNIT" "${T12_PATCH_FILES[@]}" | sort)
packaged_set=$(
  cd "$PKG_DIR" && find . -maxdepth 1 -type f -printf '%f\n' |
    grep -vxE 'PKGBUILD|README|LICENSE' | sort
)
[[ $packaged_set == "$canonical_set" ]] ||
  fail "the pkgbuild directory and src/omarchy-deck-patches/ hold different sets of files" "in the pkgbuild directory:
$packaged_set
canonical:
$canonical_set"
count "neither directory carries a payload file the other does not (${#T12_PATCH_FILES[@]} patch files + applier + hook + unit)"

# Every payload file must also be in source=(), or makepkg never links it into
# $srcdir and package() installs from a path that does not exist.
read -r -a declared_source_array <<<"$(field source)"
declared_sources=$(printf '%s\n' "${declared_source_array[@]}" | sort)
while IFS= read -r needed; do
  grep -qx -- "$needed" <<<"$declared_sources" ||
    fail "the payload file '$needed' is not listed in source=()" \
      "makepkg links only what source=() names into \$srcdir; package() would install from a path that does not exist. source=($(field source))"
done <<<"$canonical_set"
count "every payload file is declared in source=(), so makepkg fails loudly on a missing one"

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

# ---------------------------------------------------------------------------
# 🔴 THE ENUMERATION. Still enumerated, never a prefix and never a count.
# ---------------------------------------------------------------------------
#
# The set was widened this slice (T12's payload landed), and it was widened by
# NAMING every new member -- each one derived above from the applier, from
# deck_patches.py, or from the canonical payload directory. A future slice that
# quietly adds a file to the archive still turns this line red, which is the
# only reason the line is worth having.
#
# `-type f -o -type l` because the .wants entry is a SYMLINK: an enumeration
# that only looked at regular files would let the unit be shipped un-enabled --
# or enabled under some other target -- without noticing.
LICENSE_PATH="usr/share/licenses/omarchy-deck/LICENSE"
patch_dests=()
for f in "${T12_PATCH_FILES[@]}"; do
  patch_dests+=("$STEP_PATCH_DIR_REL/$f")
done
expected_list=("$PAYLOAD_PATH" "$LICENSE_PATH" "$STEP_APPLIER_REL" "$HOOK_DEST"
  "$UNIT_DEST" "$WANTS_DEST" "${patch_dests[@]}")
expected_files=$(printf '%s\n' "${expected_list[@]}" | sort)
installed_files=$(cd "$pkg_dst" && find . \( -type f -o -type l \) | sed 's|^\./||' | sort)
[[ $installed_files == "$expected_files" ]] ||
  fail "package() installs exactly the enumerated payload" "got:
$installed_files
want:
$expected_files"
count "package() really installs exactly the ${#expected_list[@]} enumerated paths -- README, licence, applier, hook, unit, its .wants link, and ${#T12_PATCH_FILES[@]} patch file(s) (executed, not grepped)"

# --- the modes, which are contract, not cosmetics --------------------------
#
# deck_patches.find_applier() checks the mode and not merely existence: a 0644
# applier is recorded as status="absent" rather than run, because inside
# arch-chroot it would fail with "permission denied" and read like a broken
# machine instead of a broken package. So an applier that ships un-executable
# is the whole seam silently absent, which is precisely what this slice exists
# to end.
applier_mode=$(stat -c '%a' "$pkg_dst/$STEP_APPLIER_REL")
[[ $applier_mode == 755 ]] ||
  fail "package() installs the applier 0755" \
    "got: 0$applier_mode. deck_patches.find_applier() treats a non-executable applier as ABSENT -- the install would record status=absent and say the package was never installed."
[[ -x "$pkg_dst/$STEP_APPLIER_REL" ]] ||
  fail "the installed applier is executable"
count "the applier is installed executable (0$applier_mode) -- deck_patches.py reads a 0644 one as absent"

for data_file in "$HOOK_DEST" "$UNIT_DEST" "${patch_dests[@]}"; do
  data_mode=$(stat -c '%a' "$pkg_dst/$data_file")
  [[ $data_mode == 644 ]] ||
    fail "package() installs /$data_file 0644" "got: 0$data_mode"
done
count "the hook, the unit and every patch file are installed 0644"

# --- ENABLED, not merely installed -----------------------------------------
#
# An installed-but-not-enabled unit is silent, and this unit is the only drift
# channel that survives a reboot: pacman exits 0 even when a PostTransaction
# hook fails, so the hook's own complaint reaches nobody. systemd honours
# <target>.wants/ directories under /usr/lib/systemd/system (that is how
# dbus.service is enabled on a stock Arch box), so shipping the link is what
# `systemctl enable` would have done -- with no install= scriptlet.
[[ -L "$pkg_dst/$WANTS_DEST" ]] ||
  fail "package() ships /$WANTS_DEST as a symlink" \
    'The unit would be installed and never started: "systemctl --failed" stays empty on a drifted patch and the alarm this file exists to raise never rings.'
wants_link=$(readlink "$pkg_dst/$WANTS_DEST")
[[ $wants_link == "../$T12_UNIT" || $wants_link == "/$UNIT_DEST" ]] ||
  fail "the .wants symlink does not point at the unit this package installs" \
    "readlink says: $wants_link
want: ../$T12_UNIT (relative, so it resolves the same inside a pacstrap target) or /$UNIT_DEST"
# Resolved for real, not just string-compared: a relative link is only enabled
# if it lands on a file.
[[ -f "$pkg_dst/$(dirname -- "$WANTS_DEST")/$wants_link" || -f "$pkg_dst/$UNIT_DEST" ]] ||
  fail "the .wants symlink does not resolve to a file inside the package"
count "omarchy-deck-patch-check.service is ENABLED as shipped: /$WANTS_DEST -> $wants_link, derived from the unit's own WantedBy=$WANTS_TARGET"

# --- the patch payload, both halves ----------------------------------------
#
# The applier refuses a patch with no .meta (`bad_meta`, non-zero exit), so a
# package that shipped only the .patch files would fail on every target -- and
# a package that shipped patches into the wrong directory would exit 4 with
# "is omarchy-deck installed?" while the files sat right there.
for f in "${T12_PATCH_FILES[@]}"; do
  cmp -s "$T12_SRC/patches/$f" "$pkg_dst/$STEP_PATCH_DIR_REL/$f" ||
    fail "the installed patch file $f differs from src/omarchy-deck-patches/patches/$f" \
      "package() installed something other than the canonical payload."
done
count "every patch file lands in /$STEP_PATCH_DIR_REL (the applier's own DEFAULT_PATCH_DIR) byte-identical to the canonical copy"

for f in "$T12_HOOK|$HOOK_DEST" "$T12_UNIT|$UNIT_DEST"; do
  cmp -s "$T12_SRC/${f%%|*}" "$pkg_dst/${f##*|}" ||
    fail "the installed ${f%%|*} differs from src/omarchy-deck-patches/${f%%|*}"
done
cmp -s "$APPLIER_SRC" "$pkg_dst/$STEP_APPLIER_REL" ||
  fail "the installed applier differs from src/omarchy-deck-patches/$T12_APPLIER" \
    "The tested file and the shipped file must be the same file."
count "the applier, the ALPM hook and the unit that package() installs are byte-identical to the tested originals (executed)"

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
