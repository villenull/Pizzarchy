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
#      the shape docs/tasks/T5-fork-plan.md §1 specifies -- including, since
#      T5c, that every promoted overlay patch APPLIES to the pinned upstream
#      and that the Valve repos it adds stay last in repo order. The
#      "iso/overlay/ is empty" assertion this suite carried from T5a was
#      retired in the same commit that first put content there; the block in
#      section 11 records why, and what replaced it.
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

# ---------------------------------------------------------------------------
# 🔴 RETIRED 2026-08-12 (T5c): "iso/overlay/ is empty of content".
#
# That assertion existed for one reason, recorded in src/iso-patches/README.md:
# bin/build applies EVERY overlay/patches/*.patch it finds, and an overlay
# whose base build had never been shown to reproduce the known-good ISO could
# not attribute a later failure to either cause. docs/findings/T5a-parity.md
# Appendix A closed that -- P1/P2/P3/P4 all pass against
# ~/ISOs/omarchy-2026.08.10-…iso, 1177 of 1180 same-version packages are
# byte-identical, and the three exceptions are exactly our --local-source
# builds -- so the reason expired and T5c is the slice entitled to add content.
#
# It is replaced, not deleted, because "the overlay is empty" was doing real
# work: it made every overlay file a deliberate act. What is true NOW, and what
# the assertions below pin instead:
#
#   A. the overlay is no longer empty, and says how much it carries -- so this
#      section cannot quietly regress to a vacuous pass over nothing;
#   B. the patch budget from T5-fork-plan.md §1 point 3 (<= 4 files, "a fifth
#      should have to argue for itself") is enforced rather than aspirational;
#   C. a patch is never staged and promoted at the same time (two divergent
#      copies of the same edit is worse than either place alone);
#   D. every promoted patch APPLIES to the pinned upstream, and the result
#      still parses -- which is the direct descendant of the retired rule's
#      purpose: attributability. A patch that no longer applies must be found
#      by a suite that runs in seconds, not by a 40-minute Docker build.
# ---------------------------------------------------------------------------

overlay_tracked=$(cd "$REPO_ROOT" && git ls-files iso/overlay | grep -v '\.gitkeep$' || true)
[[ -n $overlay_tracked ]] ||
  fail "iso/overlay/ has content" \
    "The empty-overlay rule was retired in T5c; an overlay that is empty again means content was reverted without its assertion being restored."
overlay_file_count=$(printf '%s\n' "$overlay_tracked" | grep -c .)
pass "iso/overlay/ carries content ($overlay_file_count tracked files) -- the T5a empty-overlay rule is retired, see the block above"

shopt -s nullglob
overlay_patches=("$ISO_ROOT"/overlay/patches/*.patch)
staged_patches=("$REPO_ROOT"/src/iso-patches/*.patch)
shopt -u nullglob

# B. The patch budget. T5-fork-plan.md §1 point 3: patches are only allowed for
# build-time behaviour, because anything install-time has to stay extractable
# into the omarchy-deck package for Phase 4 (T7's enablement layer). The budget
# is the pressure that keeps that line.
(( ${#overlay_patches[@]} <= 4 )) ||
  fail "iso/overlay/patches/ holds ${#overlay_patches[@]} patches; the budget is 4 (T5-fork-plan.md §1 point 3)" \
    "A fifth patch has to argue for itself -- and the argument is usually that the change belongs in the omarchy-deck package instead."
pass "the overlay patch budget is respected (${#overlay_patches[@]}/4 -- T5-fork-plan.md §1 point 3)"

# C. Staged and promoted are mutually exclusive states for the same patch.
for staged in "${staged_patches[@]}"; do
  staged_name=$(basename -- "$staged")
  [[ ! -f "$ISO_ROOT/overlay/patches/$staged_name" ]] ||
    fail "$staged_name exists in BOTH src/iso-patches/ and iso/overlay/patches/" \
      "Promotion is a git mv, not a copy: two divergent copies of one edit is worse than either location alone."
done
pass "no patch is simultaneously staged in src/iso-patches/ and promoted into iso/overlay/patches/ (${#staged_patches[@]} staged, ${#overlay_patches[@]} promoted)"

# D. Every promoted patch applies to the pinned upstream, and the result still
#    parses. Conditional on the submodule for the same reason as the pin check
#    below -- and reported out loud rather than skipped quietly.
if [[ -e "$ISO_ROOT/upstream/.git" ]]; then
  (( ${#overlay_patches[@]} > 0 )) ||
    fail "there are no overlay patches to apply" \
      "This assertion would otherwise pass vacuously; if the overlay legitimately has no patches, delete this block rather than letting it affirm nothing."
  apply_scratch="$work/overlay-apply"
  rm -rf "$apply_scratch"
  git clone --quiet --local --no-hardlinks "$ISO_ROOT/upstream" "$apply_scratch" ||
    fail "could not clone iso/upstream for the patch-apply check"
  # `checkout --quiet` still narrates the detached HEAD on stderr, which would
  # bury this suite's output; the status is checked instead of the chatter.
  git -C "$apply_scratch" -c advice.detachedHead=false checkout --quiet \
    "$(git -C "$ISO_ROOT/upstream" rev-parse HEAD)" 2>/dev/null ||
    fail "could not check the patch-apply clone out at the UPSTREAM pin"
  for p in "${overlay_patches[@]}"; do
    git -C "$apply_scratch" apply --3way "$p" >/dev/null 2>&1 ||
      fail "$(basename -- "$p") does not apply to the pinned upstream" \
        "iso/bin/build applies every overlay/patches/*.patch with git apply --3way and fails loudly on a reject; this suite finds that in seconds instead of 40 minutes into a Docker build. Rebase the patch by hand."
  done
  pass "all ${#overlay_patches[@]} overlay patches apply cleanly to $upstream_content"

  # The patched builder must still be valid bash. A patch can apply cleanly and
  # still produce a file that dies at line 1 of the container run.
  bash -n "$apply_scratch/builder/build-iso.sh" ||
    fail "the patched builder/build-iso.sh is valid bash"
  pass "the patched builder/build-iso.sh still parses"

  # The Valve repos must come AFTER [arch-mact2], i.e. last. pacman resolves
  # -S <name> by REPO ORDER, not version; putting Valve first was measured and
  # rejected (docs/findings/P16-repo-overlap-audit.md: 101 overlapping names,
  # Valve older in 50). This is the assertion that stops a well-meaning
  # "match SteamOS" edit from silently downgrading the mesa/vulkan stack.
  edge_conf="$apply_scratch/configs/pacman-online-edge.conf"
  repo_order=$(grep -n '^\[' "$edge_conf" | sed 's/:.*\[/ /; s/\]//')
  for valve in jupiter-staging holo-staging; do
    grep -q "^\[$valve\]" "$edge_conf" ||
      fail "the patched pacman-online-edge.conf declares [$valve]" "$repo_order"
    valve_line=$(grep -n "^\[$valve\]" "$edge_conf" | cut -d: -f1)
    for arch_repo in core extra multilib; do
      arch_line=$(grep -n "^\[$arch_repo\]" "$edge_conf" | cut -d: -f1)
      (( valve_line > arch_line )) ||
        fail "[$valve] is declared before [$arch_repo] in pacman-online-edge.conf" \
          "pacman resolves by repo order, not version. docs/PROGRESS.md §5.13: 101 names overlap and Valve's build is OLDER in 50 of them, the whole mesa/vulkan stack included. Qualify the one package that needs Valve's build (jupiter-staging/gamescope) instead of reordering."
    done
  done
  pass "Valve's repos are declared AFTER core/extra/multilib (docs/PROGRESS.md §5.13: repo order beats version)"

  # build-iso.sh extracts the [omarchy] stanza into the container's own
  # pacman.conf with `awk '/^\[omarchy\]/,/^$/'` -- a range that ends at the
  # first blank line. Appending repos is safe only while that stays true.
  extracted=$(awk '/^\[omarchy\]/,/^$/' "$edge_conf")
  [[ $extracted == *"pkgs.omarchy.org"* ]] ||
    fail "build-iso.sh's [omarchy] stanza extraction still finds the omarchy repo" "$extracted"
  [[ $extracted != *"steamdeck-packages"* && $extracted != *"arch-mact2"* ]] ||
    fail "build-iso.sh's awk range now swallows a repo beyond [omarchy]" \
      "It ends at the first blank line; a stanza appended without a blank line before it would leak into the container's /etc/pacman.conf.
extracted:
$extracted"
  pass "the [omarchy] stanza build-iso.sh copies into the container is still exactly one repo"
else
  printf 'skip - iso/upstream is not checked out here, so the overlay patches could not be applied against the pin (see the note below)\n'
fi

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
