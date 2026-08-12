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
# T5b added the rest of the list, and it is the larger half:
#
#   7. iso/RUNTIME is enforced the same way iso/UPSTREAM is -- a runtime
#      checkout past the pin, or dirty, or absent, is refused. Before T5b the
#      file was read only to print it, which is the difference between a pin
#      and a comment;
#   8. guard 6.4a (T5-fork-plan.md §6.4) refuses the §0 scenario BEFORE
#      docker: an orchestrator that calls /usr/bin/omarchy-setup-system
#      against a runtime that only ships omarchy-apply-system. The fixture
#      reproduces the actual rename that happened upstream on 2026-08-10;
#   9. guard 6.4a cannot pass vacuously -- no orchestrator, no matches in it,
#      and no omarchy-* in the runtime's bin/ are each an ERROR, not a quiet
#      zero. This project's recurring failure is the measurement tool lying,
#      not the code;
#  10. guard 6.4b re-asks the same question of the BUILT PACKAGES, catches a
#      runtime whose version does not carry iso/RUNTIME's commit (i.e.
#      --local-source silently did not apply), and renames the ISO it
#      rejects so nothing downstream can pick it up;
#  11. both --local-source trees are actually mounted into the container.
#      build-iso.sh switches its package-list source on /omarchy-source alone
#      but its local package build on both, so "one of the two" is a real and
#      silent failure mode.
#
# Everything through step 5 is tested by running the ACTUAL iso/bin/build
# script against a throwaway fixture tree that has the same iso/ layout but a
# trivial local-git "upstream" instead of the real omarchy-iso submodule --
# the script has no way to tell the difference, and a trivial fixture repo
# needs no network to clone or to `submodule update --init` against (it has
# no submodules of its own). Docker is deliberately kept OFF PATH for these
# runs: the script's structure is such that reaching "docker is required and
# not on PATH" proves every step before it (pin check, guard 6.1, path
# safety, overlay rsync, patch application, guard 6.3's cache setup, guard
# 6.4a) already succeeded -- so that message is used as the fixture's
# stand-in for "made it to the point only Docker can take it further," not as
# a Docker test.
#
# The post-build half (guard 6.4b) is reached with a docker STUB instead: a
# script named `docker` that records its arguments and touches an ISO where
# mkarchiso would have written one. The offline mirror it inspects is a bind
# mount the container writes and the host reads, so a fixture can populate it
# with real (tiny) package archives and the guard cannot tell the difference.
# The fake packages are uncompressed tars named .pkg.tar.zst -- libarchive
# sniffs the format from content, never the extension, which is also why
# bsdtar is the right tool for the guard itself.

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
FIXTURE_RUNTIME_SHA=""
FIXTURE_PKGS_SHA=""

# The two binaries the fixture orchestrator calls. omarchy-setup-system is the
# real one from phases_impl.py's run_system_finalizer -- the name that got
# renamed to omarchy-apply-system upstream and started this whole guard.
FIXTURE_ORCHESTRATOR_PY='import subprocess
def run_system_finalizer(ctx):
    subprocess.run(["arch-chroot", ctx.target, "/usr/bin/omarchy-setup-system",
                    "--install-user", ctx.username], check=True)
def run_chroot_finalizer(ctx):
    subprocess.run(["/usr/bin/omarchy-provision-user", "--force"], check=True)
'

git_commit_all() {
  local repo=$1 msg=$2
  git -C "$repo" -c user.email=test@example.com -c user.name=test add -A
  git -C "$repo" -c user.email=test@example.com -c user.name=test commit --quiet -m "$msg"
}

git_init() {
  local repo=$1
  mkdir -p "$repo"
  git -C "$repo" init --quiet -b main 2>/dev/null || git -C "$repo" init --quiet
}

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
  local orchestrator="$up/configs/airootfs/usr/share/omarchy-iso/orchestrator"
  git_init "$up"
  mkdir -p "$up/configs" "$up/builder" "$orchestrator"
  printf 'placeholder\n' >"$up/configs/placeholder.conf"
  printf '#!/bin/bash\necho fixture build-iso.sh ran\n' >"$up/builder/build-iso.sh"
  printf '%s' "$FIXTURE_ORCHESTRATOR_PY" >"$orchestrator/phases_impl.py"
  git_commit_all "$up" 'fixture upstream commit'
  FIXTURE_UPSTREAM_SHA=$(git -C "$up" rev-parse HEAD)
  printf 'fixture/upstream@%s\n' "${FIXTURE_UPSTREAM_SHA:0:12}" >"$root/iso/UPSTREAM"

  # Stand-in for basecamp/omarchy: bin/ is what the PKGBUILD installs into
  # /usr/bin, so that is what guard 6.4a reads.
  local rt="$root/runtime-src"
  git_init "$rt"
  mkdir -p "$rt/bin"
  local b
  for b in omarchy-setup-system omarchy-provision-user omarchy-hibernation-setup omarchy-refresh-limine; do
    printf '#!/bin/bash\n: %s\n' "$b" >"$rt/bin/$b"
    chmod +x "$rt/bin/$b"
  done
  git_commit_all "$rt" 'fixture runtime commit'
  FIXTURE_RUNTIME_SHA=$(git -C "$rt" rev-parse HEAD)
  printf 'fixture/runtime@%s\n' "${FIXTURE_RUNTIME_SHA:0:12}" >"$root/iso/RUNTIME"

  # Stand-in for omacom-io/omarchy-pkgs: only the directory layout that
  # build-omarchy-packages.sh insists on.
  local pk="$root/pkgs-src"
  git_init "$pk"
  mkdir -p "$pk/pkgbuilds/omarchy-dev" "$pk/pkgbuilds/omarchy-settings-dev"
  printf 'pkgname=omarchy-dev\n' >"$pk/pkgbuilds/omarchy-dev/PKGBUILD"
  printf 'pkgname=omarchy-settings-dev\n' >"$pk/pkgbuilds/omarchy-settings-dev/PKGBUILD"
  git_commit_all "$pk" 'fixture pkgs commit'
  FIXTURE_PKGS_SHA=$(git -C "$pk" rev-parse HEAD)
}

# make_fake_package <mirror-dir> <pkgname> <pkgver> [usr/bin name...]
#
# An uncompressed tar named .pkg.tar.zst: bsdtar reads it by content, and the
# guard's own bsdtar calls therefore see exactly what they would see from a
# real zstd package.
make_fake_package() {
  local mirror=$1 name=$2 ver=$3
  shift 3
  local stage
  stage=$(mktemp -d)
  mkdir -p "$stage/usr/bin"
  printf 'pkgname = %s\npkgver = %s\narch = any\n' "$name" "$ver" >"$stage/.PKGINFO"
  local b
  for b in "$@"; do
    printf '#!/bin/bash\n: %s\n' "$b" >"$stage/usr/bin/$b"
  done
  mkdir -p "$mirror"
  bsdtar -cf "$mirror/$name-$ver-any.pkg.tar.zst" -C "$stage" .PKGINFO usr
  rm -rf "$stage"
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

# A second PATH with a `docker` stub, for the tests that need to get PAST the
# docker step to reach guard 6.4b. It records its arguments and produces an
# ISO where mkarchiso would have, which is all bin/build looks for.
STUB_DOCKER_PATH="$work/stub-docker-bin"
mkdir -p "$STUB_DOCKER_PATH"
ln -s "$NO_DOCKER_PATH"/* "$STUB_DOCKER_PATH/" 2>/dev/null || true
cat >"$STUB_DOCKER_PATH/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$DOCKER_STUB_ARGS"
mkdir -p "$DOCKER_STUB_RELEASE"
: >"$DOCKER_STUB_RELEASE/omarchy-2026.08.11-x86_64.iso"
EOF
chmod +x "$STUB_DOCKER_PATH/docker"

# bsdtar is not optional here. Guard 6.4b reads the built packages with it,
# and a suite that skipped the package half when libarchive was missing would
# be silent about exactly the check that inspects the shipped artifact --
# the same reasoning .github/workflows/ci.yml records for
# test-iso-payload-audit.sh.
command -v bsdtar >/dev/null 2>&1 ||
  fail "bsdtar (libarchive) is required by this suite" "guard 6.4b's package tests cannot be faked without it; install libarchive/libarchive-tools"

run_build_env() {
  # $1=fixture root, remaining args become the environment for the run.
  local root=$1; shift
  BUILD_OUT=""
  BUILD_STATUS=0
  BUILD_OUT=$(cd "$root" && env -i PATH="${BUILD_PATH:-$NO_DOCKER_PATH}" HOME="$work/home" "$@" "$root/iso/bin/build" 2>&1) || BUILD_STATUS=$?
  return 0
}

# The normal entry point: the fixture's own runtime and pkgs checkouts, which
# make_fixture already put at the pins iso/RUNTIME names. `env` applies
# assignments left to right, so a caller passing its own value for either
# overrides these.
run_build() {
  local root=$1; shift
  run_build_env "$root" \
    "OMARCHY_DECK_RUNTIME_SRC=$root/runtime-src" \
    "OMARCHY_DECK_PKGS_SRC=$root/pkgs-src" \
    "$@"
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
[[ $BUILD_OUT == *"runtime pin OK"* ]] || fail "the runtime pin is verified, not just printed" "$BUILD_OUT"
[[ $BUILD_OUT == *"guard 6.4a OK"* ]] || fail "guard 6.4a logs success when the runtime ships every called binary" "$BUILD_OUT"
# The denominator, not just the verdict: a 6.4a that checked nothing would
# also say OK.
[[ $BUILD_OUT == *"omarchy-provision-user omarchy-setup-system"* ]] ||
  fail "guard 6.4a names the binaries it actually checked" "$BUILD_OUT"
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
# Printing the complaint is not refusing: a build that logged it and carried
# on would reach the docker step, and both look like exit 1 from outside.
[[ $BUILD_OUT != *"docker is required"* ]] ||
  fail "a dirty submodule must STOP the build, not just be mentioned in the log" "$BUILD_OUT"
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

# ===========================================================================
# T5b: the runtime pin, and guard 6.4.
# ===========================================================================

# --- 11. iso/RUNTIME is enforced exactly as iso/UPSTREAM is ----------------

f11="$work/f11"
make_fixture "$f11"
git -C "$f11/runtime-src" -c user.email=test@example.com -c user.name=test \
  commit --quiet --allow-empty -m 'runtime moved past the pin'
run_build "$f11"
[[ $BUILD_STATUS -eq 1 ]] || fail "a runtime checkout ahead of iso/RUNTIME must be refused" "status=$BUILD_STATUS $BUILD_OUT"
[[ $BUILD_OUT == *"runtime source"*"Refusing to build from an unpinned checkout"* ]] ||
  fail "the refusal names the runtime source and the reason" "$BUILD_OUT"
[[ $BUILD_OUT != *"docker is required"* ]] ||
  fail "an unpinned runtime must stop the build before docker" "$BUILD_OUT"
pass "a runtime checkout past iso/RUNTIME's pin is refused -- RUNTIME is a pin, not a note"

f12="$work/f12"
make_fixture "$f12"
printf 'edited\n' >>"$f12/runtime-src/bin/omarchy-setup-system"
run_build "$f12"
[[ $BUILD_STATUS -eq 1 ]] || fail "a dirty runtime checkout must be refused" "status=$BUILD_STATUS $BUILD_OUT"
[[ $BUILD_OUT == *"local modifications"* ]] || fail "the refusal names the reason" "$BUILD_OUT"
[[ $BUILD_OUT != *"docker is required"* ]] ||
  fail "a dirty runtime checkout must STOP the build, not just be mentioned in the log" "$BUILD_OUT"
pass "a dirty runtime checkout is refused (makepkg copies the tree, untracked files included)"

f13="$work/f13"
make_fixture "$f13"
printf 'not-a-pin\n' >"$f13/iso/RUNTIME"
run_build "$f13"
[[ $BUILD_STATUS -eq 1 ]] || fail "a malformed iso/RUNTIME must be refused" "status=$BUILD_STATUS $BUILD_OUT"
[[ $BUILD_OUT == *"RUNTIME does not look like"* ]] || fail "the refusal names the file" "$BUILD_OUT"
pass "a malformed iso/RUNTIME is refused, with the same strictness as iso/UPSTREAM"

f14="$work/f14"
make_fixture "$f14"
rm -f "$f14/iso/RUNTIME"
run_build "$f14"
[[ $BUILD_STATUS -eq 1 ]] || fail "a missing iso/RUNTIME must be refused, not treated as 'no pin needed'" "status=$BUILD_STATUS $BUILD_OUT"
[[ $BUILD_OUT == *"missing"*"RUNTIME"* ]] || fail "the refusal names the missing file" "$BUILD_OUT"
pass "a missing iso/RUNTIME is refused (before T5b it was an 'if [[ -f ]]' that printed nothing)"

f15="$work/f15"
make_fixture "$f15"
run_build "$f15" "OMARCHY_DECK_RUNTIME_SRC=$f15/no-such-checkout"
[[ $BUILD_STATUS -eq 1 ]] || fail "a nonexistent OMARCHY_DECK_RUNTIME_SRC must be refused" "status=$BUILD_STATUS $BUILD_OUT"
[[ $BUILD_OUT == *"is not a directory"* ]] || fail "the refusal says what is wrong" "$BUILD_OUT"
pass "OMARCHY_DECK_RUNTIME_SRC pointed at nothing is refused rather than silently ignored"

# --- 12. guard 6.4a: the §0 rename, caught before docker -------------------

f16="$work/f16"
make_fixture "$f16"
# Exactly what basecamp/omarchy@536fcd5c did on 2026-08-10: the binary is
# renamed, the ISO at our fork point still calls the old name.
mv "$f16/runtime-src/bin/omarchy-setup-system" "$f16/runtime-src/bin/omarchy-apply-system"
git_commit_all "$f16/runtime-src" 'rename the finalizer'
printf 'fixture/runtime@%s\n' "$(git -C "$f16/runtime-src" rev-parse HEAD)" >"$f16/iso/RUNTIME"
run_build "$f16"
[[ $BUILD_STATUS -eq 1 ]] || fail "guard 6.4a must refuse a runtime missing a called binary" "status=$BUILD_STATUS $BUILD_OUT"
[[ $BUILD_OUT == *"guard 6.4a"* ]] || fail "the refusal cites guard 6.4a" "$BUILD_OUT"
[[ $BUILD_OUT == *"/usr/bin/omarchy-setup-system"* ]] ||
  fail "the refusal names the missing binary" "$BUILD_OUT"
# "Fail with the two versions named" -- T5-fork-plan.md §6.4.
[[ $BUILD_OUT == *"fixture/upstream@"* && $BUILD_OUT == *"fixture/runtime@"* ]] ||
  fail "the refusal names both pins, so the reader knows which one to move" "$BUILD_OUT"
[[ $BUILD_OUT != *"docker is required"* ]] ||
  fail "guard 6.4a must run BEFORE docker -- that is the point of the cheap half" "$BUILD_OUT"
pass "guard 6.4a refuses the §0 finalizer rename before the build starts, naming both pins"

# A binary the orchestrator calls that no runtime has ever had: same refusal,
# proving the guard reads the orchestrator rather than a hard-coded name list.
f17="$work/f17"
make_fixture "$f17"
orch17="$f17/iso/upstream/configs/airootfs/usr/share/omarchy-iso/orchestrator"
printf 'subprocess.run(["/usr/bin/omarchy-deck-configure"], check=True)\n' >"$orch17/deck_phase.py"
git_commit_all "$f17/iso/upstream" 'add a phase calling a new binary'
printf 'fixture/upstream@%s\n' "$(git -C "$f17/iso/upstream" rev-parse HEAD)" >"$f17/iso/UPSTREAM"
run_build "$f17"
[[ $BUILD_STATUS -eq 1 ]] || fail "guard 6.4a must see calls from NEW orchestrator modules too" "status=$BUILD_STATUS $BUILD_OUT"
[[ $BUILD_OUT == *"/usr/bin/omarchy-deck-configure"* ]] ||
  fail "the refusal names the binary the new module calls" "$BUILD_OUT"
pass "guard 6.4a scans the whole orchestrator directory, so our own new phases are covered (§3 S3)"

# --- 13. guard 6.4a refuses to pass vacuously ------------------------------

f18="$work/f18"
make_fixture "$f18"
git -C "$f18/iso/upstream" rm -r --quiet configs/airootfs/usr/share/omarchy-iso/orchestrator
git_commit_all "$f18/iso/upstream" 'orchestrator moved away'
printf 'fixture/upstream@%s\n' "$(git -C "$f18/iso/upstream" rev-parse HEAD)" >"$f18/iso/UPSTREAM"
run_build "$f18"
[[ $BUILD_STATUS -eq 1 ]] || fail "no orchestrator must be an ERROR, not zero findings" "status=$BUILD_STATUS $BUILD_OUT"
[[ $BUILD_OUT == *"guard 6.4a cannot run"* ]] || fail "the refusal says the guard could not see its subject" "$BUILD_OUT"
[[ $BUILD_OUT != *"docker is required"* ]] ||
  fail "saying the guard cannot run and then running the build anyway is the omarchy-hook failure mode, inherited" "$BUILD_OUT"
# "the pattern went stale" is the wrong diagnosis for "the directory is gone",
# and it would send the reader to edit the grep instead of the overlay.
[[ $BUILD_OUT != *"found no /usr/bin/omarchy-* references"* ]] ||
  fail "a missing orchestrator must be reported as missing, not as a grep that matched nothing" "$BUILD_OUT"
pass "guard 6.4a with no orchestrator to read fails; it does not report success on an empty scan"

f19="$work/f19"
make_fixture "$f19"
orch19="$f19/iso/upstream/configs/airootfs/usr/share/omarchy-iso/orchestrator"
printf 'def run_system_finalizer(ctx):\n    pass\n' >"$orch19/phases_impl.py"
git_commit_all "$f19/iso/upstream" 'orchestrator with no /usr/bin references'
printf 'fixture/upstream@%s\n' "$(git -C "$f19/iso/upstream" rev-parse HEAD)" >"$f19/iso/UPSTREAM"
run_build "$f19"
[[ $BUILD_STATUS -eq 1 ]] || fail "zero matches must be an ERROR (a stale pattern looks exactly like this)" "status=$BUILD_STATUS $BUILD_OUT"
[[ $BUILD_OUT == *"found no /usr/bin/omarchy-* references"* ]] || fail "the refusal explains what an empty match means" "$BUILD_OUT"
[[ $BUILD_OUT != *"docker is required"* ]] || fail "an empty match must stop the build, not just be logged" "$BUILD_OUT"
pass "guard 6.4a finding zero /usr/bin/omarchy-* references fails rather than passing on an empty set"

f20="$work/f20"
make_fixture "$f20"
git -C "$f20/runtime-src" rm -r --quiet bin
git_commit_all "$f20/runtime-src" 'runtime with no bin/'
printf 'fixture/runtime@%s\n' "$(git -C "$f20/runtime-src" rev-parse HEAD)" >"$f20/iso/RUNTIME"
run_build "$f20"
[[ $BUILD_STATUS -eq 1 ]] || fail "a runtime checkout with no bin/ must be an ERROR" "status=$BUILD_STATUS $BUILD_OUT"
[[ $BUILD_OUT == *"no bin/ directory"* ]] || fail "the refusal says the runtime has no bin/" "$BUILD_OUT"
[[ $BUILD_OUT != *"docker is required"* ]] || fail "it must stop the build" "$BUILD_OUT"
[[ $BUILD_OUT != *"contains no omarchy-* files"* ]] ||
  fail "an absent bin/ must be reported as absent, not as an empty one" "$BUILD_OUT"
pass "guard 6.4a refuses a runtime checkout with no bin/ instead of reporting every binary missing"

# bin/ present but holding nothing that looks like a runtime binary. Distinct
# from the case above, and the likelier one in practice: a checkout of the
# wrong repository, or one whose bin/ was renamed, still has *a* bin/.
f20b="$work/f20b"
make_fixture "$f20b"
git -C "$f20b/runtime-src" rm --quiet bin/omarchy-*
# git removes the now-empty directory with the last file in it.
mkdir -p "$f20b/runtime-src/bin"
printf 'not a runtime binary\n' >"$f20b/runtime-src/bin/README"
git_commit_all "$f20b/runtime-src" 'bin/ with nothing omarchy-shaped in it'
printf 'fixture/runtime@%s\n' "$(git -C "$f20b/runtime-src" rev-parse HEAD)" >"$f20b/iso/RUNTIME"
run_build "$f20b"
[[ $BUILD_STATUS -eq 1 ]] || fail "a runtime bin/ with no omarchy-* must be an ERROR" "status=$BUILD_STATUS $BUILD_OUT"
[[ $BUILD_OUT == *"contains no omarchy-* files"* ]] ||
  fail "the refusal says the bin/ holds nothing to check against" "$BUILD_OUT"
[[ $BUILD_OUT != *"docker is required"* ]] || fail "it must stop the build" "$BUILD_OUT"
# And with the right diagnosis: "the pins disagree" would send the reader off
# to compare two commits when the real answer is "that is not a runtime".
[[ $BUILD_OUT != *"the pinned ISO and the pinned runtime disagree"* ]] ||
  fail "an unusable runtime checkout must not be reported as a pin disagreement" "$BUILD_OUT"
pass "guard 6.4a refuses a runtime whose bin/ contains no omarchy-* at all ('that is not a runtime checkout')"

# --- 14. the pkgs checkout: --local-source's third, unpinned input ---------

f21="$work/f21"
make_fixture "$f21"
run_build_env "$f21" "OMARCHY_DECK_RUNTIME_SRC=$f21/runtime-src"
[[ $BUILD_STATUS -eq 1 ]] || fail "no pkgs checkout and no iso/PKGS must be refused" "status=$BUILD_STATUS $BUILD_OUT"
[[ $BUILD_OUT == *"OMARCHY_DECK_PKGS_SRC"* && $BUILD_OUT == *"iso/PKGS"* ]] ||
  fail "the refusal offers both remedies: supply a path, or pin it" "$BUILD_OUT"
[[ $BUILD_OUT != *"cloning pinned upstream"* ]] ||
  fail "the refusal must stop the run, not narrate it and continue" "$BUILD_OUT"
# The operator gets the remedy, not `set -u` tripping over the variable two
# lines later. A crash is a refusal nobody can act on.
[[ $BUILD_OUT != *"unbound variable"* ]] ||
  fail "the missing pkgs checkout must be diagnosed, not left to set -u" "$BUILD_OUT"
pass "--local-source's PKGBUILD checkout must be named explicitly while this repo does not pin it"

f22="$work/f22"
make_fixture "$f22"
printf 'edited\n' >>"$f22/pkgs-src/pkgbuilds/omarchy-dev/PKGBUILD"
run_build "$f22"
[[ $BUILD_STATUS -eq 1 ]] || fail "a dirty pkgs checkout must be refused" "status=$BUILD_STATUS $BUILD_OUT"
[[ $BUILD_OUT == *"local modifications"* ]] || fail "the refusal names the reason" "$BUILD_OUT"
[[ $BUILD_OUT != *"docker is required"* ]] ||
  fail "a dirty pkgs checkout must STOP the build, not just be mentioned in the log" "$BUILD_OUT"
pass "a dirty pkgs checkout is refused -- the PKGBUILDs decide what reaches /usr/bin"

f23="$work/f23"
make_fixture "$f23"
rm -rf "$f23/pkgs-src/pkgbuilds/omarchy-dev"
git_commit_all "$f23/pkgs-src" 'drop the runtime pkgbuild'
run_build "$f23"
[[ $BUILD_STATUS -eq 1 ]] || fail "a pkgs checkout with no omarchy-dev PKGBUILD must be refused" "status=$BUILD_STATUS $BUILD_OUT"
[[ $BUILD_OUT == *"pkgbuilds/omarchy-dev"* ]] || fail "the refusal names the missing recipe" "$BUILD_OUT"
[[ $BUILD_OUT != *"docker is required"* ]] || fail "it must stop the build" "$BUILD_OUT"
pass "a pkgs checkout missing pkgbuilds/omarchy-dev is refused here, not inside the container an hour later"

# An unpinned pkgs checkout is used, but never quietly: the run prints the sha
# and the exact line that would pin it.
f24="$work/f24"
make_fixture "$f24"
run_build "$f24"
[[ $BUILD_OUT == *"pkgs source is UNPINNED"* ]] || fail "an unpinned pkgs checkout is announced" "$BUILD_OUT"
[[ $BUILD_OUT == *"omacom-io/omarchy-pkgs@$FIXTURE_PKGS_SHA"* ]] ||
  fail "the warning prints the line that would pin it, with the real sha" "$BUILD_OUT"
pass "an unpinned pkgs checkout is loudly reported with its sha and the fix"

# With iso/PKGS present it becomes a real pin, enforced like the other two.
f25="$work/f25"
make_fixture "$f25"
printf 'fixture/pkgs@%s\n' "${FIXTURE_PKGS_SHA:0:12}" >"$f25/iso/PKGS"
run_build "$f25"
[[ $BUILD_OUT == *"pkgs pin OK"* ]] || fail "iso/PKGS at the checkout's sha is accepted" "$BUILD_OUT"
[[ $BUILD_OUT != *"UNPINNED"* ]] || fail "a pinned pkgs checkout must not warn" "$BUILD_OUT"
git -C "$f25/pkgs-src" -c user.email=test@example.com -c user.name=test \
  commit --quiet --allow-empty -m 'pkgs moved past the pin'
run_build "$f25"
[[ $BUILD_STATUS -eq 1 ]] || fail "a pkgs checkout past iso/PKGS must be refused" "status=$BUILD_STATUS $BUILD_OUT"
[[ $BUILD_OUT == *"pkgs source"*"Refusing to build from an unpinned checkout"* ]] ||
  fail "the refusal names the pkgs source" "$BUILD_OUT"
pass "iso/PKGS, when it exists, is enforced exactly like iso/UPSTREAM and iso/RUNTIME"

# --- 15. both --local-source trees reach the container ---------------------

f26="$work/f26"
make_fixture "$f26"
scratch26="$work/scratch-26"
mirror26="$scratch26/offline-mirror-cache/mirror/offline"
make_fake_package "$mirror26" omarchy-dev "4.0.0.r1617.g${FIXTURE_RUNTIME_SHA:0:7}" \
  omarchy-setup-system omarchy-provision-user
make_fake_package "$mirror26" omarchy-settings-dev "4.0.0.r1617.g${FIXTURE_RUNTIME_SHA:0:7}" \
  omarchy-upload-log
BUILD_PATH="$STUB_DOCKER_PATH" run_build "$f26" \
  "OMARCHY_DECK_ISO_BUILD_DIR=$scratch26" \
  "DOCKER_STUB_ARGS=$work/docker-args-26" \
  "DOCKER_STUB_RELEASE=$scratch26/release"
[[ $BUILD_STATUS -eq 0 ]] || fail "a complete fixture build should succeed through guard 6.4b" "$BUILD_OUT"
[[ $BUILD_OUT == *"guard 6.4b OK"* ]] || fail "guard 6.4b runs after the build" "$BUILD_OUT"
[[ $BUILD_OUT == *"build complete"* ]] || fail "the build reports its artifact" "$BUILD_OUT"
docker_args=$(cat "$work/docker-args-26")
[[ $docker_args == *"$f26/runtime-src:/omarchy-source:ro"* ]] ||
  fail "the runtime checkout is mounted at /omarchy-source" "$docker_args"
[[ $docker_args == *"$f26/pkgs-src:/omarchy-pkgs:ro"* ]] ||
  fail "the pkgs checkout is mounted at /omarchy-pkgs" "$docker_args"
[[ $docker_args == *"OMARCHY_RUNTIME_PACKAGE=omarchy-dev"* ]] ||
  fail "the runtime package name is stated to the container, not re-derived there" "$docker_args"
pass "--local-source: both source trees are mounted and the package names are passed explicitly"

# --- 16. guard 6.4b: the artifact, not the checkout ------------------------

# The PKGBUILD's exclusion list is the gap 6.4a cannot see: the file is in
# bin/, so 6.4a passes, and the package does not ship it.
f27="$work/f27"
make_fixture "$f27"
scratch27="$work/scratch-27"
mirror27="$scratch27/offline-mirror-cache/mirror/offline"
make_fake_package "$mirror27" omarchy-dev "4.0.0.r1617.g${FIXTURE_RUNTIME_SHA:0:7}" omarchy-provision-user
make_fake_package "$mirror27" omarchy-settings-dev "4.0.0.r1617.g${FIXTURE_RUNTIME_SHA:0:7}" omarchy-upload-log
BUILD_PATH="$STUB_DOCKER_PATH" run_build "$f27" \
  "OMARCHY_DECK_ISO_BUILD_DIR=$scratch27" \
  "DOCKER_STUB_ARGS=$work/docker-args-27" \
  "DOCKER_STUB_RELEASE=$scratch27/release"
[[ $BUILD_STATUS -eq 1 ]] || fail "guard 6.4b must refuse a package set missing a called binary" "status=$BUILD_STATUS $BUILD_OUT"
[[ $BUILD_OUT == *"guard 6.4a OK"* ]] ||
  fail "6.4a should have passed here -- the file IS in the checkout's bin/" "$BUILD_OUT"
[[ $BUILD_OUT == *"guard 6.4b"*"/usr/bin/omarchy-setup-system"* ]] ||
  fail "6.4b names the binary the packages do not contain" "$BUILD_OUT"
[[ -f "$scratch27/release/omarchy-2026.08.11-x86_64.iso.rejected" ]] ||
  fail "a rejected ISO is renamed so it cannot be flashed or picked up by a later run" "$BUILD_OUT"
[[ ! -f "$scratch27/release/omarchy-2026.08.11-x86_64.iso" ]] ||
  fail "the rejected ISO must not keep its .iso name"
pass "guard 6.4b catches what 6.4a structurally cannot, and renames the ISO it rejects"

# The pin that did not take: a channel build (its pkgver carries someone
# else's commit) sitting in the mirror where our local build should be.
f28="$work/f28"
make_fixture "$f28"
scratch28="$work/scratch-28"
mirror28="$scratch28/offline-mirror-cache/mirror/offline"
make_fake_package "$mirror28" omarchy-dev "4.0.0.r1652.g1c9dfc5" omarchy-setup-system omarchy-provision-user
make_fake_package "$mirror28" omarchy-settings-dev "4.0.0.r1652.g1c9dfc5" omarchy-upload-log
BUILD_PATH="$STUB_DOCKER_PATH" run_build "$f28" \
  "OMARCHY_DECK_ISO_BUILD_DIR=$scratch28" \
  "DOCKER_STUB_ARGS=$work/docker-args-28" \
  "DOCKER_STUB_RELEASE=$scratch28/release"
[[ $BUILD_STATUS -eq 1 ]] || fail "a runtime package not built from iso/RUNTIME must be refused" "status=$BUILD_STATUS $BUILD_OUT"
[[ $BUILD_OUT == *"runtime pin did not take effect"* ]] ||
  fail "the refusal says the pin did not take effect" "$BUILD_OUT"
[[ $BUILD_OUT == *"4.0.0.r1652.g1c9dfc5"* ]] || fail "the refusal quotes the version it found" "$BUILD_OUT"
pass "guard 6.4b rejects a package whose version does not carry iso/RUNTIME's commit (--local-source silently not applying)"

# No local build in the mirror at all: the channel path, which is the state
# this whole slice removes.
f29="$work/f29"
make_fixture "$f29"
scratch29="$work/scratch-29"
mkdir -p "$scratch29/offline-mirror-cache/mirror/offline"
BUILD_PATH="$STUB_DOCKER_PATH" run_build "$f29" \
  "OMARCHY_DECK_ISO_BUILD_DIR=$scratch29" \
  "DOCKER_STUB_ARGS=$work/docker-args-29" \
  "DOCKER_STUB_RELEASE=$scratch29/release"
[[ $BUILD_STATUS -eq 1 ]] || fail "an offline mirror with no locally built runtime must be refused" "status=$BUILD_STATUS $BUILD_OUT"
[[ $BUILD_OUT == *"no omarchy-dev package in"* ]] || fail "the refusal says which package is absent" "$BUILD_OUT"
[[ $BUILD_OUT != *"did not take effect"* ]] ||
  fail "an absent package must be reported as absent, not as a version mismatch against an empty version" "$BUILD_OUT"
pass "guard 6.4b refuses an offline mirror with no locally built runtime -- an empty scan is not a pass"

# Packages that exist, carry the right commit, and ship nothing. Without its
# own case this reads as "every binary is missing", which is true but points
# the reader at the runtime instead of at the packaging.
f30="$work/f30"
make_fixture "$f30"
scratch30="$work/scratch-30"
mirror30="$scratch30/offline-mirror-cache/mirror/offline"
make_fake_package "$mirror30" omarchy-dev "4.0.0.r1617.g${FIXTURE_RUNTIME_SHA:0:7}"
make_fake_package "$mirror30" omarchy-settings-dev "4.0.0.r1617.g${FIXTURE_RUNTIME_SHA:0:7}"
BUILD_PATH="$STUB_DOCKER_PATH" run_build "$f30" \
  "OMARCHY_DECK_ISO_BUILD_DIR=$scratch30" \
  "DOCKER_STUB_ARGS=$work/docker-args-30" \
  "DOCKER_STUB_RELEASE=$scratch30/release"
[[ $BUILD_STATUS -eq 1 ]] || fail "packages with no usr/bin at all must be refused" "status=$BUILD_STATUS $BUILD_OUT"
[[ $BUILD_OUT == *"ship no usr/bin members at all"* ]] ||
  fail "the refusal distinguishes 'shipped nothing' from 'missing these names'" "$BUILD_OUT"
[[ $BUILD_OUT != *"orchestrator calls binaries the packages it carries do not contain"* ]] ||
  fail "packages that shipped nothing must not be reported as a missing-name list" "$BUILD_OUT"
pass "guard 6.4b names an empty provider set as its own failure rather than reporting every binary missing"

# bsdtar itself absent: the tool the guard depends on. A skip here would be
# the check passing because it could not run -- the exact shape §5.4's audit
# refuses, inherited.
f31="$work/f31"
make_fixture "$f31"
scratch31="$work/scratch-31"
mirror31="$scratch31/offline-mirror-cache/mirror/offline"
make_fake_package "$mirror31" omarchy-dev "4.0.0.r1617.g${FIXTURE_RUNTIME_SHA:0:7}" \
  omarchy-setup-system omarchy-provision-user
make_fake_package "$mirror31" omarchy-settings-dev "4.0.0.r1617.g${FIXTURE_RUNTIME_SHA:0:7}" omarchy-upload-log
NO_BSDTAR_PATH="$work/no-bsdtar-bin"
mkdir -p "$NO_BSDTAR_PATH"
while IFS= read -r -d '' entry; do
  name=$(basename -- "$entry")
  [[ $name == bsdtar ]] && continue
  ln -sf "$entry" "$NO_BSDTAR_PATH/$name"
done < <(find "$STUB_DOCKER_PATH" -maxdepth 1 -mindepth 1 -print0)
[[ ! -e "$NO_BSDTAR_PATH/bsdtar" ]] || fail "no-bsdtar PATH fixture accidentally contains bsdtar"
[[ -e "$NO_BSDTAR_PATH/docker" ]] || fail "no-bsdtar PATH fixture lost the docker stub"
BUILD_PATH="$NO_BSDTAR_PATH" run_build "$f31" \
  "OMARCHY_DECK_ISO_BUILD_DIR=$scratch31" \
  "DOCKER_STUB_ARGS=$work/docker-args-31" \
  "DOCKER_STUB_RELEASE=$scratch31/release"
[[ $BUILD_STATUS -eq 1 ]] || fail "guard 6.4b must fail, not skip, when bsdtar is missing" "status=$BUILD_STATUS $BUILD_OUT"
[[ $BUILD_OUT == *"needs bsdtar"* ]] || fail "the refusal names the missing tool" "$BUILD_OUT"
[[ $BUILD_OUT != *"guard 6.4b OK"* ]] || fail "it must not also report success" "$BUILD_OUT"
[[ $BUILD_OUT != *"could not read .PKGINFO"* ]] ||
  fail "it must refuse for the absent tool, not stumble into using it and blame the package" "$BUILD_OUT"
pass "guard 6.4b with no bsdtar fails loudly instead of skipping the artifact check"

# ---------------------------------------------------------------------------
# 17. The real repo's iso/ skeleton matches docs/tasks/T5-fork-plan.md §1.
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
