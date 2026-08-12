#!/usr/bin/env bash
# Unit tests for iso/bin/build (T5a, docs/tasks/T5-fork-plan.md §1/§7) and the
# skeleton it operates on. No VM, no Deck, no Docker, no network.
#
# What this pins is deliberately narrower than "does a full build work" --
# that is the parity proof from a real run against ~/ISOs/, documented in
# docs/findings/T5a-iso-build-skeleton.md, not something a fast unit suite can
# do (docker + ~6 GB + network is the wrong tier for "seconds" CI, per
# CLAUDE.md's testing table). What IS unit-testable, and load-bearing enough
# to be worth pinning here:
#
#   1. the pin-verification guard actually refuses an unpinned/dirty/missing
#      submodule -- "refuse otherwise" from §1 is not just a comment;
#   2. guard 6.1 (ref/mirror agreement, T5-fork-plan.md §6.1) actually refuses
#      a caller's conflicting environment rather than silently overriding it;
#   3. the scratch-root path safety check actually refuses an
#      OMARCHY_DECK_ISO_BUILD_DIR pointed back inside the repo -- "never in
#      the repo" (docs/PROGRESS.md §1.1) is enforced, not just documented;
#   4. overlay/configs/ is actually rsynced onto the scratch copy, and the
#      .gitkeep placeholders that keep the empty directories in git do NOT
#      leak into the built tree;
#   5. a patch that does not apply FAILS LOUDLY (git apply --3way, "failing
#      loudly on any reject" from §1) rather than being skipped;
#   6. the real iso/UPSTREAM, iso/RUNTIME, and iso/overlay/ in this repo match
#      the shape docs/tasks/T5-fork-plan.md §1 specifies.
#
# Everything through step 5 is tested by running the ACTUAL iso/bin/build
# script against a throwaway fixture tree that has the same iso/ layout but a
# trivial local-git "upstream" instead of the real omarchy-iso submodule --
# the script has no way to tell the difference, and a trivial fixture repo
# needs no network to clone or to `submodule update --init` against (it has
# no submodules of its own). Docker is deliberately kept OFF PATH for these
# runs: the script's structure is such that reaching "docker is required and
# not on PATH" proves every step before it (pin check, guard 6.1, path
# safety, overlay rsync, patch application, guard 6.3's cache setup) already
# succeeded -- so that message is used as the fixture's stand-in for "made it
# to the point only Docker can take it further," not as a Docker test.

set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
BUILD_SCRIPT="$REPO_ROOT/iso/bin/build"

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; [[ -n ${2:-} ]] && printf '%s\n' "$2" >&2; exit 1; }

[[ -f $BUILD_SCRIPT ]] || fail "iso/bin/build exists" "not found at $BUILD_SCRIPT"
[[ -x $BUILD_SCRIPT ]] || fail "iso/bin/build is executable"
bash -n "$BUILD_SCRIPT" || fail "iso/bin/build is valid bash"
pass "iso/bin/build exists, is executable, and parses"

# iso/bin/build has no .sh suffix (matching upstream's own bin/omarchy-iso-*
# convention, and the exact path docs/tasks/T5-fork-plan.md §1 specifies), so
# CI's shellcheck step -- which discovers files by `git ls-files '*.sh'` --
# will never select it. Cover it here instead, since this suite DOES match
# CI's test/unit/test-*.sh discovery glob. Skip (don't fail) if shellcheck
# itself isn't on PATH -- that's a local-environment gap, not a regression in
# the script; CI always has it (pinned, .github/workflows/ci.yml).
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x "$BUILD_SCRIPT" || fail "shellcheck -x iso/bin/build is clean"
  pass "shellcheck -x iso/bin/build is clean (extension-less, so CI's *.sh glob would otherwise never check it)"
else
  printf 'skip - shellcheck not on PATH locally; CI installs a pinned build and this suite covers it there\n'
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# ---------------------------------------------------------------------------
# Fixture: an iso/ tree with the real bin/build script but a trivial local
# git repo standing in for the omarchy-iso submodule. No network, no
# nested submodules, no Docker content -- just enough for the script's own
# guards to have something real to check.
# ---------------------------------------------------------------------------

FIXTURE_UPSTREAM_SHA=""

make_fixture() {
  local root=$1
  rm -rf "$root"
  mkdir -p "$root/iso/bin" "$root/iso/overlay/configs/airootfs" "$root/iso/overlay/patches"
  cp "$BUILD_SCRIPT" "$root/iso/bin/build"
  chmod +x "$root/iso/bin/build"
  touch "$root/iso/overlay/configs/airootfs/.gitkeep" "$root/iso/overlay/patches/.gitkeep"

  # A trivial repo standing in for omarchy-iso: enough files that later steps
  # (overlay rsync onto configs/, a patch touching a real file) have
  # somewhere real to land, but no submodules of its own -- `git submodule
  # update --init --recursive` against it is a fast, offline no-op.
  local up="$root/iso/upstream"
  mkdir -p "$up/configs" "$up/builder"
  git -C "$up" init --quiet -b main 2>/dev/null || git -C "$up" init --quiet
  printf 'placeholder\n' >"$up/configs/placeholder.conf"
  printf '#!/bin/bash\necho fixture build-iso.sh ran\n' >"$up/builder/build-iso.sh"
  git -C "$up" -c user.email=test@example.com -c user.name=test add -A
  git -C "$up" -c user.email=test@example.com -c user.name=test commit --quiet -m 'fixture upstream commit'
  FIXTURE_UPSTREAM_SHA=$(git -C "$up" rev-parse HEAD)

  printf 'fixture/upstream@%s\n' "${FIXTURE_UPSTREAM_SHA:0:12}" >"$root/iso/UPSTREAM"
  printf 'fixture/runtime@0000000\n' >"$root/iso/RUNTIME"
}

# A PATH with every real binary except docker, so runs that get far enough
# fail at "docker is required and not on PATH" -- proving everything before
# that line ran for real, while never touching the actual docker daemon.
# Mirrors the technique test-iso-payload-audit.sh uses for its bsdtar case.
NO_DOCKER_PATH="$work/no-docker-bin"
mkdir -p "$NO_DOCKER_PATH"
while IFS= read -r -d ':' dir; do
  [[ -d $dir ]] || continue
  while IFS= read -r -d '' entry; do
    name=$(basename -- "$entry")
    [[ $name == docker ]] && continue
    [[ -e "$NO_DOCKER_PATH/$name" ]] && continue
    ln -s "$entry" "$NO_DOCKER_PATH/$name" 2>/dev/null || true
  done < <(find "$dir" -maxdepth 1 -type f -print0 2>/dev/null)
done <<<"$PATH:"
[[ ! -e "$NO_DOCKER_PATH/docker" ]] || fail "no-docker PATH fixture accidentally contains docker"
linked=$(find "$NO_DOCKER_PATH" -maxdepth 1 | wc -l)
(( linked > 20 )) || fail "no-docker PATH fixture only linked $linked binaries -- would fail for lack of a shell, not lack of docker"

run_build() {
  # $1=fixture root, remaining args become the environment for the run.
  local root=$1; shift
  BUILD_OUT=""
  BUILD_STATUS=0
  BUILD_OUT=$(cd "$root" && env -i PATH="$NO_DOCKER_PATH" HOME="$work/home" "$@" "$root/iso/bin/build" 2>&1) || BUILD_STATUS=$?
  return 0
}
mkdir -p "$work/home"

# --- 1. a well-formed, pinned, clean fixture reaches the docker check ------

f1="$work/f1"
make_fixture "$f1"
run_build "$f1"
[[ $BUILD_STATUS -ne 0 ]] || fail "sanity: run should not succeed (docker is unreachable by construction)"
[[ $BUILD_OUT == *"docker is required and not on PATH"* ]] ||
  fail "a correctly pinned, clean fixture reaches the docker step" "$BUILD_OUT"
[[ $BUILD_OUT == *"upstream pin OK"* ]] || fail "pin check logs success on a valid pin" "$BUILD_OUT"
[[ $BUILD_OUT == *"guard 6.1 OK"* ]] || fail "guard 6.1 logs success when ref/mirror agree" "$BUILD_OUT"
[[ $BUILD_OUT == *"guard 6.3 OK"* ]] || fail "guard 6.3 logs success (scratch pacman cache in place)" "$BUILD_OUT"
pass "a correctly pinned, clean fixture passes every guard and reaches the docker step"

# --- 2. an unpinned submodule (wrong commit) is refused ---------------------

f2="$work/f2"
make_fixture "$f2"
git -C "$f2/iso/upstream" -c user.email=test@example.com -c user.name=test \
  commit --quiet --allow-empty -m 'moved past the pin'
run_build "$f2"
[[ $BUILD_STATUS -eq 1 ]] || fail "a submodule ahead of its pin must be refused" "status=$BUILD_STATUS $BUILD_OUT"
[[ $BUILD_OUT == *"Refusing to build from an unpinned checkout"* ]] ||
  fail "the refusal names the reason" "$BUILD_OUT"
pass "iso/upstream checked out past iso/UPSTREAM's pin is refused, not silently built"

# --- 3. a dirty submodule (uncommitted local change) is refused ------------

f3="$work/f3"
make_fixture "$f3"
printf 'local edit\n' >>"$f3/iso/upstream/configs/placeholder.conf"
run_build "$f3"
[[ $BUILD_STATUS -eq 1 ]] || fail "a dirty pinned submodule must be refused" "status=$BUILD_STATUS $BUILD_OUT"
[[ $BUILD_OUT == *"local modifications"* ]] || fail "the refusal names the reason" "$BUILD_OUT"
pass "a dirty iso/upstream (uncommitted changes) is refused -- 'exactly at UPSTREAM' means clean too"

# --- 4. an uninitialized submodule (no .git) is refused, not silently skipped

f4="$work/f4"
make_fixture "$f4"
rm -rf "$f4/iso/upstream"
mkdir -p "$f4/iso/upstream"
run_build "$f4"
[[ $BUILD_STATUS -eq 1 ]] || fail "an uninitialized submodule must be refused" "status=$BUILD_STATUS $BUILD_OUT"
[[ $BUILD_OUT == *"not a checked-out submodule"* ]] || fail "the refusal explains how to fix it" "$BUILD_OUT"
pass "an uninitialized iso/upstream is refused with a remedy, not a vacuous pass"

# --- 5. a malformed UPSTREAM file is refused --------------------------------

f5="$work/f5"
make_fixture "$f5"
printf 'not-a-valid-pin-line\n' >"$f5/iso/UPSTREAM"
run_build "$f5"
[[ $BUILD_STATUS -eq 1 ]] || fail "a malformed UPSTREAM file must be refused" "status=$BUILD_STATUS $BUILD_OUT"
[[ $BUILD_OUT == *"does not look like"* ]] || fail "the refusal names the problem" "$BUILD_OUT"
pass "a malformed iso/UPSTREAM ('owner/repo@sha' violated) is refused"

# --- 6. guard 6.1: a conflicting OMARCHY_ISO_REF/MIRROR in the environment --

f6="$work/f6"
make_fixture "$f6"
run_build "$f6" OMARCHY_MIRROR=stable
[[ $BUILD_STATUS -eq 1 ]] || fail "OMARCHY_MIRROR=stable in the environment must be refused (guard 6.1)" "status=$BUILD_STATUS $BUILD_OUT"
[[ $BUILD_OUT == *"guard 6.1"* ]] || fail "the refusal cites guard 6.1" "$BUILD_OUT"
pass "guard 6.1: a caller's conflicting OMARCHY_MIRROR is refused, never silently overridden"

run_build "$f6" OMARCHY_ISO_REF=edge
[[ $BUILD_STATUS -eq 1 ]] || fail "OMARCHY_ISO_REF=edge in the environment must be refused (guard 6.1)" "status=$BUILD_STATUS $BUILD_OUT"
pass "guard 6.1: a caller's conflicting OMARCHY_ISO_REF is refused too"

# Agreeing values are fine -- guard 6.1 checks agreement, not presence.
run_build "$f6" OMARCHY_ISO_REF=quattro OMARCHY_MIRROR=edge
[[ $BUILD_STATUS -ne 0 && $BUILD_OUT == *"docker is required"* ]] ||
  fail "OMARCHY_ISO_REF=quattro OMARCHY_MIRROR=edge (agreeing with the pin) must NOT be refused" "$BUILD_OUT"
pass "guard 6.1: values that already agree with the fork's pin pass through"

# --- 7. the scratch root may never be inside the repo -----------------------

f7="$work/f7"
make_fixture "$f7"
run_build "$f7" "OMARCHY_DECK_ISO_BUILD_DIR=$f7/inside-repo-scratch"
[[ $BUILD_STATUS -eq 1 ]] || fail "a build dir inside the repo must be refused" "status=$BUILD_STATUS $BUILD_OUT"
[[ $BUILD_OUT == *"inside this repo"* ]] || fail "the refusal explains why" "$BUILD_OUT"
pass "OMARCHY_DECK_ISO_BUILD_DIR pointed inside the repo is refused (docs/PROGRESS.md §1.1: never in the repo)"

run_build "$f7" "OMARCHY_DECK_ISO_BUILD_DIR=$work/outside-scratch-7"
[[ $BUILD_STATUS -ne 0 && $BUILD_OUT == *"docker is required"* ]] ||
  fail "a build dir outside the repo must be accepted" "$BUILD_OUT"
[[ -d "$work/outside-scratch-7/pacman-cache" ]] ||
  fail "the scratch pacman cache directory is actually created" "$BUILD_OUT"
[[ -d "$work/outside-scratch-7/src" ]] || fail "the scratch source clone directory is actually created"
pass "an out-of-repo OMARCHY_DECK_ISO_BUILD_DIR is accepted and populated"

# --- 8. overlay/configs/ lands on the scratch copy; .gitkeep does not ------

f8="$work/f8"
make_fixture "$f8"
mkdir -p "$f8/iso/overlay/configs/airootfs/etc/deck"
printf 'overlay content\n' >"$f8/iso/overlay/configs/airootfs/etc/deck/marker"
scratch8="$work/scratch-8"
run_build "$f8" "OMARCHY_DECK_ISO_BUILD_DIR=$scratch8"
[[ -f "$scratch8/src/configs/airootfs/etc/deck/marker" ]] ||
  fail "overlay/configs/ content is rsynced onto the scratch upstream copy" "$BUILD_OUT"
[[ $(cat "$scratch8/src/configs/airootfs/etc/deck/marker") == "overlay content" ]] ||
  fail "the rsynced file has the overlay's actual content, not something stale"
[[ ! -e "$scratch8/src/configs/airootfs/.gitkeep" ]] ||
  fail ".gitkeep placeholders must NOT leak into the built tree"
pass "overlay/configs/ is applied onto the scratch copy; .gitkeep placeholders are excluded"

# --- 9. a patch that fails to apply FAILS THE BUILD, loudly, by name -------

f9="$work/f9"
make_fixture "$f9"
# A patch against a file/context that does not exist in the fixture upstream.
cat >"$f9/iso/overlay/patches/0001-bogus.patch" <<'EOF'
--- a/configs/placeholder.conf
+++ b/configs/placeholder.conf
@@ -1,3 +1,3 @@
-this line does not exist in the fixture
+neither does this one
 and this context line is wrong too
EOF
run_build "$f9"
[[ $BUILD_STATUS -eq 1 ]] || fail "a patch that cannot apply must fail the build" "status=$BUILD_STATUS $BUILD_OUT"
[[ $BUILD_OUT == *"0001-bogus.patch"* ]] || fail "the failure names the offending patch" "$BUILD_OUT"
[[ $BUILD_OUT != *"docker is required"* ]] ||
  fail "a failed patch must stop the build BEFORE it ever reaches docker" "$BUILD_OUT"
pass "git apply --3way failing on a bad patch stops the build and names the file (§1: 'failing loudly on any reject')"

# --- 10. a patch that DOES apply lets the build continue past it -----------

f10="$work/f10"
make_fixture "$f10"
cat >"$f10/iso/overlay/patches/0001-good.patch" <<'EOF'
--- a/configs/placeholder.conf
+++ b/configs/placeholder.conf
@@ -1 +1 @@
-placeholder
+patched
EOF
scratch10="$work/scratch-10"
run_build "$f10" "OMARCHY_DECK_ISO_BUILD_DIR=$scratch10"
[[ $BUILD_OUT == *"docker is required"* ]] ||
  fail "a good patch should let the build proceed to the docker step" "$BUILD_OUT"
[[ $(cat "$scratch10/src/configs/placeholder.conf") == "patched" ]] ||
  fail "the patch's actual effect is present in the scratch copy" "$BUILD_OUT"
pass "git apply --3way applies a valid patch and the build proceeds past it"

# ---------------------------------------------------------------------------
# 11. The real repo's iso/ skeleton matches docs/tasks/T5-fork-plan.md §1.
#
# The submodule pin check is conditional: actions/checkout in
# .github/workflows/ci.yml does not fetch submodules (no `submodules:` key),
# so iso/upstream is an empty directory there. That is a CI-workflow
# property this suite does not own and cannot fix -- skip that one
# sub-assertion when the submodule isn't populated rather than failing on an
# environment precondition, but say so out loud rather than passing quietly.
# ---------------------------------------------------------------------------

ISO_ROOT="$REPO_ROOT/iso"

[[ -f "$ISO_ROOT/UPSTREAM" ]] || fail "iso/UPSTREAM exists"
upstream_content=$(cat "$ISO_ROOT/UPSTREAM")
[[ $upstream_content == "omacom-io/omarchy-iso@a12bfea7a86c" ]] ||
  fail "iso/UPSTREAM has the exact pin from T5-fork-plan.md §2" "got: $upstream_content"
pass "iso/UPSTREAM is exactly 'omacom-io/omarchy-iso@a12bfea7a86c'"

[[ -f "$ISO_ROOT/RUNTIME" ]] || fail "iso/RUNTIME exists"
runtime_content=$(cat "$ISO_ROOT/RUNTIME")
[[ $runtime_content == "basecamp/omarchy@6d7826d" ]] ||
  fail "iso/RUNTIME has the exact pin from T5-fork-plan.md §2" "got: $runtime_content"
pass "iso/RUNTIME is exactly 'basecamp/omarchy@6d7826d'"

[[ -d "$ISO_ROOT/overlay/configs/airootfs" ]] || fail "iso/overlay/configs/airootfs/ exists"
[[ -d "$ISO_ROOT/overlay/patches" ]] || fail "iso/overlay/patches/ exists"
# "EMPTY of content" -- only .gitkeep (or nothing) may be tracked under these.
overlay_tracked=$(cd "$REPO_ROOT" && git ls-files iso/overlay | grep -v '\.gitkeep$' || true)
[[ -z $overlay_tracked ]] ||
  fail "iso/overlay/ must be empty of content in this slice (T5a)" "tracked, non-.gitkeep files: $overlay_tracked"
pass "iso/overlay/ has the required directory structure and is empty of content"

if [[ -e "$ISO_ROOT/upstream/.git" ]]; then
  real_head=$(git -C "$ISO_ROOT/upstream" rev-parse HEAD)
  [[ $real_head == a12bfea7a86c* ]] ||
    fail "iso/upstream is checked out at the pinned commit" "HEAD=$real_head, expected a12bfea7a86c*"
  real_dirty=$(git -C "$ISO_ROOT/upstream" status --porcelain)
  [[ -z $real_dirty ]] || fail "iso/upstream has no local modifications" "$real_dirty"
  pass "the real iso/upstream submodule is checked out clean, exactly at the UPSTREAM pin"
else
  printf 'skip - iso/upstream is not checked out in this environment (actions/checkout has no submodules: key in .github/workflows/ci.yml, which this suite does not own) -- the fixture-based tests above cover bin/build'"'"'s pin-verification logic regardless\n'
fi

printf '\nall iso-build tests passed\n'
