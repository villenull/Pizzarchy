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
# T5d added two more, both about things that were documented and enforced by
# nothing:
#
#  12. guard 6.5 (T5-fork-plan.md §5.4/§6.5) actually calls
#      tools/iso-payload-audit.sh from bin/build and a non-zero exit actually
#      STOPS the build -- proved by a fixture whose overlay carries the dev
#      Deck's real `deck ALL=(ALL) NOPASSWD: ALL` line, and by the tolerance
#      case beside it, because a check that fires on the ordinary
#      password-protected grant is a check people learn to ignore
#      (docs/PROGRESS.md §5.17). The post-build half is proved on a package
#      planted in the offline mirror, which is the route our own omarchy-deck
#      package would take;
#  13. a promoted overlay patch and the modules it imports move TOGETHER.
#      configure-deck-phase.patch makes main.py's build_phases do
#      `from .deck_configure import configure_deck`, evaluated before any phase
#      runs, so a promotion missing its additive files is an install that dies
#      before partitioning. That hazard lived in prose in src/iso-patches/README.md
#      and in T5-fork-plan.md §10 point 5 for a day; section 19 derives it.
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

  # bin/build derives REPO_ROOT as iso/.., and guard 6.5 runs
  # tools/iso-payload-audit.sh from there -- on the HOST, because the audit
  # sources src/deck-session.sh to share the blanket/passwordless predicate
  # rather than reimplement it. Symlinked, not stubbed: a fixture that faked
  # the audit would prove that bin/build calls SOMETHING, which is not the
  # claim. The symlinks are followed for content but not for $BASH_SOURCE, so
  # the audit still resolves its own repo root to this fixture -- which is why
  # deck-session.sh has to be here too.
  mkdir -p "$root/tools" "$root/src"
  ln -s "$REPO_ROOT/tools/iso-payload-audit.sh" "$root/tools/iso-payload-audit.sh"
  ln -s "$REPO_ROOT/src/deck-session.sh" "$root/src/deck-session.sh"

  # T12's runtime patches, for guard 6.6. NOT symlinked to the real
  # src/omarchy-deck-patches/: those apply to basecamp/omarchy's actual QML,
  # and this fixture's runtime is a stand-in with four shell stubs in bin/. The
  # fixture needs a patch that genuinely applies to the tree the guard will
  # check it against, or the positive case would be measuring the wrong thing.
  # bin/build hard-fails when it can find no patch directory at all, so every
  # fixture carries one -- which is itself the assertion in section 20.
  mkdir -p "$root/src/omarchy-deck-patches/patches"
  cat >"$root/src/omarchy-deck-patches/patches/0010-fixture-runtime.patch" <<'EOF'
--- a/bin/omarchy-setup-system
+++ b/bin/omarchy-setup-system
@@ -1,2 +1,3 @@
 #!/bin/bash
+# fixture runtime patch
 : omarchy-setup-system
EOF
  printf 'requirement: the fixture runtime patch must keep applying\n' \
    >"$root/src/omarchy-deck-patches/patches/0010-fixture-runtime.meta"

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
  local recipe
  for recipe in omarchy-dev omarchy-settings-dev omarchy-nvim; do
    mkdir -p "$pk/pkgbuilds/$recipe"
    printf 'pkgname=%s\n' "$recipe" >"$pk/pkgbuilds/$recipe/PKGBUILD"
  done
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

# make_sudoers_package <mirror-dir> <pkgname> <pkgver> <sudoers-line>
#
# A package that carries etc/sudoers.d/99-deck-testing. This is the shape of
# the accident guard 6.5b exists for: a drop-in that ships INSIDE a package
# installs exactly like one baked into airootfs, no tree scan would ever see
# it, and our own omarchy-deck package is the likeliest carrier
# (T5-fork-plan.md §5.4 names it as one of the four roots).
make_sudoers_package() {
  local mirror=$1 name=$2 ver=$3 line=$4
  local stage
  stage=$(mktemp -d)
  mkdir -p "$stage/etc/sudoers.d"
  printf 'pkgname = %s\npkgver = %s\narch = any\n' "$name" "$ver" >"$stage/.PKGINFO"
  printf '%s\n' "$line" >"$stage/etc/sudoers.d/99-deck-testing"
  mkdir -p "$mirror"
  bsdtar -cf "$mirror/$name-$ver-any.pkg.tar.zst" -C "$stage" .PKGINFO etc
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
# build-omarchy-packages.sh builds three recipes and stops on the first it
# cannot find, so checking only the runtime's would move the failure into the
# container rather than prevent it.
f23b="$work/f23b"
make_fixture "$f23b"
rm -rf "$f23b/pkgs-src/pkgbuilds/omarchy-nvim"
git_commit_all "$f23b/pkgs-src" 'drop the nvim pkgbuild'
run_build "$f23b"
[[ $BUILD_STATUS -eq 1 ]] || fail "a pkgs checkout missing any of the three recipes must be refused" "status=$BUILD_STATUS $BUILD_OUT"
[[ $BUILD_OUT == *"pkgbuilds/omarchy-nvim"* ]] || fail "the refusal names the recipe that is actually missing" "$BUILD_OUT"
pass "a pkgs checkout missing any of the three PKGBUILDs is refused here, not inside the container an hour later"

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

# ===========================================================================
# T5d: guard 6.5 -- tools/iso-payload-audit.sh, wired into bin/build.
#
# The audit itself has its own suite (test/unit/test-iso-payload-audit.sh, 16
# assertions). What is tested HERE is the wiring, which is a separate claim and
# was the missing half: §5.4 says "bin/build calls it ... and a non-zero exit
# stops the build", and until T5d bin/build never called it at all. The fixture
# symlinks the REAL audit into place (see make_fixture) rather than stubbing
# it, because "bin/build calls something" is not the claim being made.
# ===========================================================================

# --- 17. guard 6.5a: the audit runs before docker, and its findings stop the
#         build -----------------------------------------------------------

# A clean payload. The denominator line is the assertion that matters here:
# "guard 6.5a OK" would be printed just as happily by a call that inspected
# nothing, and in a green log an audit that never ran is indistinguishable from
# one that found nothing (docs/PROGRESS.md §5.30c).
f32="$work/f32"
make_fixture "$f32"
run_build "$f32"
[[ $BUILD_OUT == *"docker is required"* ]] ||
  fail "a clean fixture must still reach the docker step now that the audit is wired in" "$BUILD_OUT"
[[ $BUILD_OUT == *"guard 6.5a OK"* ]] || fail "guard 6.5a reports success on a clean payload" "$BUILD_OUT"
[[ $BUILD_OUT == *"[iso-payload-audit] inspected "*"across 2 root(s)"* ]] ||
  fail "the audit's own denominator line appears in the build log, over BOTH roots" "$BUILD_OUT"
[[ $BUILD_OUT == *"payload audit (overlay + overlaid airootfs source):"*"$f32/iso/overlay"* ]] ||
  fail "the build log names the roots it passed to the audit" "$BUILD_OUT"
pass "guard 6.5a runs the real payload audit over both roots and prints its denominator, not just a verdict"

# 🔴 THE NEGATIVE CONTROL. The exact line the dev Deck carries on purpose
# (docs/PROGRESS.md §5.17, operator decision §5.25 #7), in the exact file, in
# the overlay -- the likeliest route for the accident, since the file already
# exists on the machine this repo is developed on. A guard nobody has seen fail
# is not a guard.
f33="$work/f33"
make_fixture "$f33"
mkdir -p "$f33/iso/overlay/configs/airootfs/etc/sudoers.d"
printf 'deck ALL=(ALL) NOPASSWD: ALL\n' \
  >"$f33/iso/overlay/configs/airootfs/etc/sudoers.d/99-deck-testing"
run_build "$f33"
[[ $BUILD_STATUS -ne 0 ]] ||
  fail "an overlay carrying 99-deck-testing must FAIL the build" "status=$BUILD_STATUS $BUILD_OUT"
[[ $BUILD_OUT == *"guard 6.5a"* ]] || fail "the refusal cites guard 6.5a" "$BUILD_OUT"
[[ $BUILD_OUT == *"99-deck-testing"* ]] ||
  fail "the refusal names the offending file, so the reader can delete it" "$BUILD_OUT"
[[ $BUILD_OUT == *"NOPASSWD"* ]] || fail "the refusal quotes the offending line" "$BUILD_OUT"
[[ $BUILD_OUT != *"docker is required"* ]] ||
  fail "a payload finding must STOP the build before docker, not be logged and passed" "$BUILD_OUT"
pass "🔴 an overlay carrying 'deck ALL=(ALL) NOPASSWD: ALL' fails the build by name, before docker (§5.4)"

# The tolerance case, and it is not a footnote. `deck ALL=(ALL) ALL` is blanket
# but password-protected -- the ordinary admin grant every Arch/Omarchy install
# ships. Failing on it is the false positive that teaches people to ignore the
# check, which is how stage_audit_privileges' first version went wrong
# (docs/PROGRESS.md §5.17).
f34="$work/f34"
make_fixture "$f34"
mkdir -p "$f34/iso/overlay/configs/airootfs/etc/sudoers.d"
printf 'deck ALL=(ALL) ALL\n' >"$f34/iso/overlay/configs/airootfs/etc/sudoers.d/10-installer"
run_build "$f34"
[[ $BUILD_OUT == *"docker is required"* ]] ||
  fail "an ordinary password-protected blanket grant must NOT fail the build" "$BUILD_OUT"
[[ $BUILD_OUT == *"guard 6.5a OK"* ]] || fail "guard 6.5a passes on the ordinary admin grant" "$BUILD_OUT"
[[ $BUILD_OUT == *"blanket grant, password required"* ]] ||
  fail "the tolerated grant is still REPORTED -- tolerated is not invisible" "$BUILD_OUT"
[[ $BUILD_OUT != *"PASSWORDLESS BLANKET ROOT"* ]] ||
  fail "a password-protected grant must not be reported as passwordless" "$BUILD_OUT"
pass "guard 6.5a tolerates (and still reports) 'deck ALL=(ALL) ALL' -- the false positive that gets a check ignored"

# The audit missing is a FAILURE, not a skip. Without this, deleting
# tools/iso-payload-audit.sh would turn every build green.
f35="$work/f35"
make_fixture "$f35"
rm -f "$f35/tools/iso-payload-audit.sh"
run_build "$f35"
[[ $BUILD_STATUS -eq 1 ]] || fail "a missing payload audit must fail the build" "status=$BUILD_STATUS $BUILD_OUT"
[[ $BUILD_OUT == *"does not exist, so the audit did not run"* ]] ||
  fail "the refusal says the audit did not run, rather than reporting a clean payload" "$BUILD_OUT"
[[ $BUILD_OUT != *"docker is required"* ]] || fail "it must stop the build" "$BUILD_OUT"
pass "a missing tools/iso-payload-audit.sh fails the build instead of silently skipping the check"

# Present but not executable: a distinct code path in bin/build, and a distinct
# diagnosis. Copied rather than chmod'ing the symlink -- chmod follows symlinks,
# and this fixture would otherwise strip +x from the real repo's script.
f35b="$work/f35b"
make_fixture "$f35b"
rm -f "$f35b/tools/iso-payload-audit.sh"
cp "$REPO_ROOT/tools/iso-payload-audit.sh" "$f35b/tools/iso-payload-audit.sh"
chmod -x "$f35b/tools/iso-payload-audit.sh"
run_build "$f35b"
[[ $BUILD_STATUS -eq 1 ]] || fail "a non-executable payload audit must fail the build" "status=$BUILD_STATUS $BUILD_OUT"
[[ $BUILD_OUT == *"is not executable, so the audit did not run"* ]] ||
  fail "the refusal distinguishes 'not executable' from 'not there'" "$BUILD_OUT"
pass "a non-executable tools/iso-payload-audit.sh is refused with its own diagnosis, not treated as absent"

# --- 17b. guard 6.5b: the same question, asked of the packages -------------

# A drop-in inside a package is the route no tree scan can see, and the route
# our own omarchy-deck package would take. Reached through the same docker stub
# section 16 uses: the offline mirror is a bind mount the container writes and
# the host reads, so a fixture can populate it and the guard cannot tell.
f36="$work/f36"
make_fixture "$f36"
scratch36="$work/scratch-36"
mirror36="$scratch36/offline-mirror-cache/mirror/offline"
make_fake_package "$mirror36" omarchy-dev "4.0.0.r1617.g${FIXTURE_RUNTIME_SHA:0:7}" \
  omarchy-setup-system omarchy-provision-user
make_fake_package "$mirror36" omarchy-settings-dev "4.0.0.r1617.g${FIXTURE_RUNTIME_SHA:0:7}" \
  omarchy-upload-log
make_sudoers_package "$mirror36" omarchy-deck "1.0.0-1" 'deck ALL=(ALL) NOPASSWD: ALL'
BUILD_PATH="$STUB_DOCKER_PATH" run_build "$f36" \
  "OMARCHY_DECK_ISO_BUILD_DIR=$scratch36" \
  "DOCKER_STUB_ARGS=$work/docker-args-36" \
  "DOCKER_STUB_RELEASE=$scratch36/release"
[[ $BUILD_STATUS -eq 1 ]] ||
  fail "a sudoers drop-in inside a mirror package must fail the build" "status=$BUILD_STATUS $BUILD_OUT"
# The earlier guards must have PASSED, or this proves nothing about 6.5b.
[[ $BUILD_OUT == *"guard 6.5a OK"* && $BUILD_OUT == *"guard 6.4b OK"* ]] ||
  fail "6.5a and 6.4b should both pass here -- the finding is inside a package, which neither of them reads" "$BUILD_OUT"
[[ $BUILD_OUT == *"guard 6.5b"* ]] || fail "the refusal cites guard 6.5b" "$BUILD_OUT"
[[ $BUILD_OUT == *"omarchy-deck-1.0.0-1-any.pkg.tar.zst!etc/sudoers.d/99-deck-testing"* ]] ||
  fail "the refusal names the package AND the member inside it" "$BUILD_OUT"
[[ -f "$scratch36/release/omarchy-2026.08.11-x86_64.iso.rejected" ]] ||
  fail "an ISO rejected by 6.5b is renamed so it cannot be flashed or picked up by a later run" "$BUILD_OUT"
[[ ! -f "$scratch36/release/omarchy-2026.08.11-x86_64.iso" ]] ||
  fail "the rejected ISO must not keep its .iso name" "$BUILD_OUT"
pass "guard 6.5b catches a passwordless grant shipped INSIDE a mirror package and rejects the built ISO"

# ---------------------------------------------------------------------------
# 18. The real repo's iso/ skeleton matches docs/tasks/T5-fork-plan.md §1.
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

# ---------------------------------------------------------------------------
# 19. A promoted patch and the code it imports move TOGETHER.
#
# docs/tasks/T5-fork-plan.md §10 point 5, and src/iso-patches/README.md's
# "does not stand alone" section: configure-deck-phase.patch makes main.py's
# build_phases do `from .deck_configure import configure_deck`, and
# build_phases(ctx) is evaluated as an ARGUMENT to run() -- i.e. before any
# phase executes. So a patch promoted without its additive module does not
# degrade the install; it turns every install into an immediate traceback,
# before partitioning. The hazard was written down in two places and enforced
# by nothing. This section is the enforcement.
#
# The module list is DERIVED from the patches, never hard-coded, for exactly
# the reason guard 6.4a derives its binary names (bin/build's §6.4a comment): a
# hand-kept list goes stale against our own next edit, and it goes stale
# silently, which is worse than not having one.
# ---------------------------------------------------------------------------

ORCHESTRATOR_OVERLAY="$ISO_ROOT/overlay/configs/airootfs/usr/share/omarchy-iso/orchestrator"
ORCHESTRATOR_UPSTREAM="$ISO_ROOT/upstream/configs/airootfs/usr/share/omarchy-iso/orchestrator"

# orchestrator_module_missing <name> -- empty if the module resolves, otherwise
# a sentence saying why not. A relative import may legitimately name an
# UPSTREAM module (deck_configure's own `from .ui import error, info` does), so
# the overlay is checked first and upstream second. When the submodule is not
# checked out the upstream half cannot be consulted, and that is reported as
# part of the failure rather than quietly treated as a pass.
orchestrator_module_missing() {
  local name=$1
  [[ -f "$ORCHESTRATOR_OVERLAY/$name.py" ]] && return 0
  if [[ -d $ORCHESTRATOR_UPSTREAM ]]; then
    [[ -f "$ORCHESTRATOR_UPSTREAM/$name.py" ]] && return 0
    printf 'no %s.py in the overlay orchestrator, and none in the pinned upstream orchestrator either' "$name"
    return 0
  fi
  printf 'no %s.py in the overlay orchestrator (iso/upstream is not checked out here, so it could not be confirmed as an upstream module either)' "$name"
}

(( ${#overlay_patches[@]} > 0 )) ||
  fail "there are no promoted patches to derive imports from" \
    "This section would otherwise affirm nothing. If the overlay legitimately carries no patches, delete this block deliberately rather than letting it pass over an empty set."

# Added lines only ('^+'), because a relative import that a patch merely quotes
# in context is already in the tree it applies to.
mapfile -t patch_new_imports < <(
  grep -hoE '^\+.*from \.[A-Za-z_][A-Za-z0-9_]* import' "${overlay_patches[@]}" |
    sed -E 's/.*from \.([A-Za-z_][A-Za-z0-9_]*) import.*/\1/' | sort -u
)
(( ${#patch_new_imports[@]} > 0 )) ||
  fail "no promoted patch introduces a relative import" \
    "configure-deck-phase.patch adds 'from .deck_configure import configure_deck', so an empty derivation means the PATTERN went stale, not that the coupling went away -- the same shape guard 6.4a's empty-match case refuses. Fix the pattern, or remove this block on purpose."

for mod in "${patch_new_imports[@]}"; do
  why=$(orchestrator_module_missing "$mod")
  [[ -z $why ]] ||
    fail "a promoted patch imports .$mod, but $why" \
      "An overlay patch that introduces a relative import with no module behind it is an install that dies BEFORE phase 1: build_phases(ctx) is evaluated as an argument to run(), so the ImportError happens before partitioning, on every install. Promote the patch and its additive files in one commit (src/iso-patches/README.md)."
done
pass "every relative import promoted patches introduce (${patch_new_imports[*]}) has a module behind it"

# The transitive half. The patch names deck_configure; deck_configure names
# deck_wifi (`from . import deck_wifi`, imported lazily inside the step). A
# check that stopped at the patch would let deck_wifi.py be left behind, which
# fails later but just as hard.
shopt -s nullglob
overlay_orchestrator_modules=("$ORCHESTRATOR_OVERLAY"/*.py)
shopt -u nullglob
if (( ${#overlay_orchestrator_modules[@]} > 0 )); then
  mapfile -t overlay_module_imports < <(
    grep -hoE '^[[:space:]]*from \.[A-Za-z_][A-Za-z0-9_]* import|^[[:space:]]*from \. import [A-Za-z_][A-Za-z0-9_]*' \
      "${overlay_orchestrator_modules[@]}" |
      sed -E 's/^[[:space:]]*from \. import ([A-Za-z_][A-Za-z0-9_]*)$/\1/; s/^[[:space:]]*from \.([A-Za-z_][A-Za-z0-9_]*) import$/\1/' |
      sort -u
  )
  (( ${#overlay_module_imports[@]} > 0 )) ||
    fail "the overlay's orchestrator modules import nothing relative" \
      "${#overlay_orchestrator_modules[@]} module(s) are there and they are members of upstream's orchestrator package; zero relative imports means the pattern went stale."
  for mod in "${overlay_module_imports[@]}"; do
    why=$(orchestrator_module_missing "$mod")
    [[ -z $why ]] ||
      fail "the overlay's orchestrator imports .$mod, but $why" \
        "Every module an overlay orchestrator file imports must exist -- in the overlay if it is ours, in the pinned upstream if it is theirs."
  done
  pass "every relative import the overlay's own orchestrator modules make (${overlay_module_imports[*]}) resolves in the overlay or the pinned upstream"
else
  printf 'skip - the overlay carries no orchestrator modules, so there are no transitive imports to resolve\n'
fi

# The two ASSETS cannot be derived from the patch: the phase COPIES them onto
# the target, it does not import them, so nothing in the patch mentions them.
# They are derived from deck_wifi.py's constants instead -- ASSET_DIR plus the
# two names beside it are the one place those paths are written down. Deriving
# beats a hand-kept list here too: if the constants are renamed, the extraction
# below finds nothing and this block FAILS, rather than silently checking a
# stale pair of filenames.
mapfile -t asset_const_files < <(grep -lE '^ASSET_DIR = Path\("' "${overlay_orchestrator_modules[@]}" 2>/dev/null || true)
(( ${#asset_const_files[@]} == 1 )) ||
  fail "expected exactly one overlay orchestrator module to define ASSET_DIR, found ${#asset_const_files[@]}" \
    "That constant is meant to be the single place the on-ISO asset directory is written down (src/iso-patches/README.md). Zero means it was renamed and this derivation is now checking nothing; more than one means it was duplicated, which is the drift the single definition exists to prevent."
asset_src=${asset_const_files[0]}
asset_dir=$(sed -nE 's|^ASSET_DIR = Path\("([^"]+)"\).*|\1|p' "$asset_src" | head -n1)
[[ $asset_dir == /* ]] ||
  fail "could not derive an absolute ASSET_DIR from $(basename -- "$asset_src")" "got: '$asset_dir'"
mapfile -t asset_names < <(
  sed -nE 's#^(FIRST_BOOT_UNIT|FIRST_BOOT_SCRIPT_ASSET) = "([^"/]+)".*#\2#p' "$asset_src" | sort -u
)
(( ${#asset_names[@]} == 2 )) ||
  fail "expected two asset filenames (FIRST_BOOT_UNIT, FIRST_BOOT_SCRIPT_ASSET) in $(basename -- "$asset_src"), derived ${#asset_names[@]}" \
    "The constants were renamed or moved. Re-point this derivation rather than hard-coding the filenames -- ${asset_names[*]:-none}"
for asset in "${asset_names[@]}"; do
  [[ -f "$ISO_ROOT/overlay/configs/airootfs$asset_dir/$asset" ]] ||
    fail "$(basename -- "$asset_src") copies $asset_dir/$asset onto the target, but the overlay does not ship it" \
      "A missing asset does not stop the install (it is recorded in /var/log/omarchy-deck-install.json and test/unit/test-deck-configure-wifi.py asserts both halves), so nothing else would ever tell you: the Deck simply never reconnects to Wi-Fi after first boot. Promote the asset with the phase."
done
pass "both first-boot assets derived from $(basename -- "$asset_src") (${asset_names[*]}) ship in the overlay at $asset_dir"

# ---------------------------------------------------------------------------
# The SHELL half of the same hazard, added 2026-08-12 with T4a's promotion.
#
# A promoted patch can couple itself to a file it does not import: it can
# `source` one. omarchy-install-dashboard.patch adds
# `source /usr/share/omarchy-iso/deck-dashboard.sh` to a script that runs on
# EVERY install, and that script runs under `set -e` by the time the line
# executes -- so a missing target is not a degraded dashboard, it is a
# dashboard that dies, on every install, on hardware, at the one moment the
# user is watching a progress bar. Identical class to the ImportError above;
# different mechanism, so the import derivation above cannot see it.
#
# DERIVED, not hard-coded -- no filename appears below, for the same reason
# the import list is derived: a hand-kept list goes stale silently. The path
# comes out of the patch text, and where it resolves is decided the same way
# orchestrator_module_missing decides it: ours (the overlay) first, upstream's
# second, because a patch may legitimately source a file upstream already
# ships. When the submodule is not checked out, the upstream half cannot be
# consulted and that is said out loud in the failure rather than waved through.
# ---------------------------------------------------------------------------

# sourced_path_missing <abs-path> -- empty if the file resolves, otherwise a
# sentence saying why not.
sourced_path_missing() {
  local abs=$1
  [[ -f "$ISO_ROOT/overlay/configs/airootfs$abs" ]] && return 0
  if [[ -d "$ISO_ROOT/upstream/configs/airootfs" ]]; then
    [[ -f "$ISO_ROOT/upstream/configs/airootfs$abs" ]] && return 0
    printf 'nothing ships it at %s -- not in the overlay (iso/overlay/configs/airootfs%s) and not in the pinned upstream airootfs either' "$abs" "$abs"
    return 0
  fi
  printf 'the overlay does not ship it at %s (iso/upstream is not checked out here, so it could not be confirmed as an upstream file either)' "$abs"
}

# Added lines only ('^+'), and only where `source`/`.` opens the statement --
# a commented mention or a context line the patch merely quotes is already in
# the tree it applies to. The path may be quoted; the quotes are stripped.
mapfile -t patch_sourced_paths < <(
  grep -hoE '^\+[[:space:]]*(source|\.)[[:space:]]+["'"'"']?/usr/share/omarchy-iso/[^"'"'"'[:space:];&|)]+' "${overlay_patches[@]}" |
    sed -E 's|^\+[[:space:]]*(source\|\.)[[:space:]]+["'"'"']?||' | sort -u
)
(( ${#patch_sourced_paths[@]} > 0 )) ||
  fail "no promoted patch sources a file under /usr/share/omarchy-iso/" \
    "omarchy-install-dashboard.patch adds 'source /usr/share/omarchy-iso/deck-dashboard.sh', so an empty derivation means this PATTERN went stale, not that the coupling went away -- the same refusal-to-pass-vacuously the import block above uses. Fix the pattern, or remove this block on purpose."

for sourced in "${patch_sourced_paths[@]}"; do
  why=$(sourced_path_missing "$sourced")
  [[ -z $why ]] ||
    fail "a promoted patch sources $sourced, but $why" \
      "The patched script runs on every install, under 'set -e', and sourcing a file that is not there kills it there and then. A patch and the files it references are ONE unit: promote them in the same commit, into the overlay at their shipped path (src/iso-patches/README.md)."
done
pass "every absolute path promoted patches source (${patch_sourced_paths[*]}) has a file behind it"

# ===========================================================================
# 20. Guard 6.6 -- a runtime patch that no longer applies fails the BUILD.
#
# docs/tasks/T12-upstream-patch-seam.md §1 point 4. These patches are applied
# on the TARGET at pacman time, so a stale one breaks nothing here and nothing
# visible there: the Deck just quietly loses the customisation. The guard is
# the only thing that converts "upstream moved" into an event anybody sees, and
# docs/tasks/T5-fork-plan.md §5.4's rule applies with full force -- a guard
# nobody has seen fail is not a guard.
#
# make_fixture gives every fixture its own patch (see the block there), so the
# positive case below is not a special arrangement: it is what every other run
# in this suite has already been exercising since guard 6.6 landed.
# ===========================================================================

# --- 20a. the positive case, with its denominator --------------------------

f37="$work/f37"
make_fixture "$f37"
run_build "$f37"
[[ $BUILD_OUT == *"guard 6.6 OK"* ]] || fail "guard 6.6 reports success when the patches still apply" "$BUILD_OUT"
# The verdict alone would be printed just as happily by a guard that checked
# nothing -- section 17's lesson, and 6.4a's.
[[ $BUILD_OUT == *"all 1 runtime patch(es)"* && $BUILD_OUT == *"0010-fixture-runtime.patch"* ]] ||
  fail "guard 6.6 names how many patches it checked, and which" "$BUILD_OUT"
[[ $BUILD_OUT == *"docker is required"* ]] ||
  fail "a fixture whose patches apply must still reach the docker step" "$BUILD_OUT"
pass "guard 6.6 checks every runtime patch against the pinned runtime and prints its denominator, not just a verdict"

# --- 20b. 🔴 THE NEGATIVE CONTROL ------------------------------------------
#
# The stale patch here is deliberately the HARDEST kind to catch, not the
# easiest: it is generated by `git diff` in the runtime checkout (so it carries
# a real `index <blob>..<blob>` line), and upstream then drifts a line above the
# hunk. That combination means `git apply --check` rejects it -- and
# `git apply --3way` would find the pre-image blob in the object store, merge
# it, and report success. So this case fails ONLY while the guard uses --check
# and nothing else, which is precisely the property
# docs/tasks/T12-upstream-patch-seam.md demands: the reject is the product of
# this seam, and anything that makes a stale patch "apply anyway" is the
# failure mode the seam exists to make loud.
f38="$work/f38"
make_fixture "$f38"
rm -f "$f38/src/omarchy-deck-patches/patches/0010-fixture-runtime".*
# Author the patch against the runtime as it is now...
printf '#!/bin/bash\n: omarchy-setup-system-PATCHED\n' >"$f38/runtime-src/bin/omarchy-setup-system"
git -C "$f38/runtime-src" diff --src-prefix=a/ --dst-prefix=b/ \
  >"$f38/src/omarchy-deck-patches/patches/0020-fixture-lock-timer.patch"
git -C "$f38/runtime-src" checkout -- bin/omarchy-setup-system
printf 'requirement: the fixture panel must stay lit ~20s, not ~2s\n' \
  >"$f38/src/omarchy-deck-patches/patches/0020-fixture-lock-timer.meta"
# ...then upstream moves under it, and the pin moves with it. The checkout
# stays clean and exactly at iso/RUNTIME, so nothing before 6.6 objects.
printf '# upstream added this line\n#!/bin/bash\n: omarchy-setup-system\n' \
  >"$f38/runtime-src/bin/omarchy-setup-system"
git_commit_all "$f38/runtime-src" 'upstream drifts under the patch'
printf 'fixture/runtime@%s\n' "$(git -C "$f38/runtime-src" rev-parse HEAD)" >"$f38/iso/RUNTIME"
# Sanity: the fixture really is the 3way-rescuable shape, or 20b would be
# proving something weaker than it claims.
git -C "$f38/runtime-src" apply --check -p1 -- \
  "$f38/src/omarchy-deck-patches/patches/0020-fixture-lock-timer.patch" 2>/dev/null &&
  fail "fixture sanity: the stale patch must be rejected by git apply --check"
apply_probe="$work/apply-probe"
rm -rf "$apply_probe"
cp -a "$f38/runtime-src" "$apply_probe"
# cp -a carries the index's stat cache into a directory it no longer describes,
# and `git apply --3way` (which implies --index) refuses on "does not match
# index" before it ever looks at the patch. Refresh first, or this probe would
# report the wrong reason for the wrong thing.
git -C "$apply_probe" update-index --refresh >/dev/null 2>&1 || true
git -C "$apply_probe" apply --3way -p1 -- \
  "$f38/src/omarchy-deck-patches/patches/0020-fixture-lock-timer.patch" >/dev/null 2>&1 ||
  fail "fixture sanity: the stale patch must be SILENTLY RESCUED by git apply --3way" \
    "Without that property this case would not detect a guard weakened to --3way, which is the specific weakening docs/tasks/T12-upstream-patch-seam.md forbids."
rm -rf "$apply_probe"

run_build "$f38"
[[ $BUILD_STATUS -eq 1 ]] ||
  fail "🔴 a runtime patch that no longer applies must FAIL THE BUILD" "status=$BUILD_STATUS $BUILD_OUT"
# These three come FIRST on purpose. A guard 6.6 that has been deleted, or
# neutered into a no-op, still leaves a run that exits 1 (docker is off PATH by
# construction) and still prints the patch's name and both pins in its own
# success line -- so the weaker assertions below would all pass over a guard
# that checks nothing. What a no-op cannot do is stay silent about success or
# stop the build early.
[[ $BUILD_OUT != *"guard 6.6 OK"* ]] ||
  fail "the guard reported SUCCESS on a stale patch -- it is not checking" "$BUILD_OUT"
[[ $BUILD_OUT != *"docker is required"* ]] ||
  fail "guard 6.6 must stop the build BEFORE docker -- that is the point of putting it beside 6.4a" "$BUILD_OUT"
[[ $BUILD_OUT == *"runtime patch(es) no longer apply to the pinned runtime"* ]] ||
  fail "the refusal cites guard 6.6's own verdict, not just the string 'guard 6.6'" "$BUILD_OUT"
[[ $BUILD_OUT == *"0020-fixture-lock-timer.patch"* ]] ||
  fail "the refusal names the patch, so the reader knows which one to rebase" "$BUILD_OUT"
# "name the patch and both SHAs" -- T12 §1 point 4.
[[ $BUILD_OUT == *"fixture/upstream@"* && $BUILD_OUT == *"fixture/runtime@"* ]] ||
  fail "the refusal names both pins" "$BUILD_OUT"
# The user-visible consequence, taken from the patch's own .meta rather than
# from a sentence hard-coded in bin/build.
[[ $BUILD_OUT == *"the fixture panel must stay lit ~20s, not ~2s"* ]] ||
  fail "the refusal states what the patch is FOR, derived from its .meta" "$BUILD_OUT"
[[ $BUILD_OUT == *"patch does not apply"* ]] ||
  fail "the refusal quotes what git apply --check actually said" "$BUILD_OUT"
# And the checkout must be untouched: --check, never an apply.
[[ -z $(git -C "$f38/runtime-src" status --porcelain) ]] ||
  fail "guard 6.6 modified the pinned runtime checkout -- --check must not write" \
    "$(git -C "$f38/runtime-src" status --porcelain)"
pass "🔴 guard 6.6 fails the build on a stale runtime patch, by name, with both pins and the .meta consequence, before docker"

# --- 20c. every reject is collected, not just the first ---------------------

f39="$work/f39"
make_fixture "$f39"
rm -f "$f39/src/omarchy-deck-patches/patches/0010-fixture-runtime".*
cat >"$f39/src/omarchy-deck-patches/patches/0030-first-stale.patch" <<'EOF'
--- a/bin/omarchy-setup-system
+++ b/bin/omarchy-setup-system
@@ -1,2 +1,2 @@
 #!/usr/bin/zsh
-: something that was never there
+: nor this
EOF
printf 'requirement: the first fixture post-condition\n' \
  >"$f39/src/omarchy-deck-patches/patches/0030-first-stale.meta"
# Deliberately WITHOUT a .meta: a patch that cannot say what it is for must
# still be reported, and must say that it cannot say.
cat >"$f39/src/omarchy-deck-patches/patches/0040-second-stale.patch" <<'EOF'
--- a/bin/omarchy-provision-user
+++ b/bin/omarchy-provision-user
@@ -1,2 +1,2 @@
 #!/usr/bin/fish
-: also never there
+: nor this either
EOF
run_build "$f39"
[[ $BUILD_STATUS -eq 1 ]] || fail "two stale patches must fail the build" "status=$BUILD_STATUS $BUILD_OUT"
[[ $BUILD_OUT == *"2 of 2 runtime patch(es)"* ]] ||
  fail "guard 6.6 reports how many of how many failed" "$BUILD_OUT"
[[ $BUILD_OUT == *"0030-first-stale.patch"* && $BUILD_OUT == *"0040-second-stale.patch"* ]] ||
  fail "BOTH stale patches are named -- stopping at the first would cost a second 40-minute round trip" "$BUILD_OUT"
[[ $BUILD_OUT == *"0040-second-stale.meta"*"does not say what it is for"* ]] ||
  fail "a patch with no .meta requirement line says so, rather than printing an empty consequence" "$BUILD_OUT"
pass "guard 6.6 collects every reject in one run and names each, including one with no .meta behind it"

# --- 20d. it cannot pass vacuously ------------------------------------------

# No patch directory anywhere. "Nothing to check" is not a pass: it is the
# payload having gone missing, which on the Deck is silent.
f40="$work/f40"
make_fixture "$f40"
rm -rf "$f40/src/omarchy-deck-patches"
run_build "$f40"
[[ $BUILD_STATUS -eq 1 ]] ||
  fail "no runtime-patch directory at all must be an ERROR, not zero findings" "status=$BUILD_STATUS $BUILD_OUT"
[[ $BUILD_OUT == *"guard 6.6 cannot run: no runtime-patch directory found"* ]] ||
  fail "the refusal says the guard could not see its subject" "$BUILD_OUT"
[[ $BUILD_OUT != *"guard 6.6 OK"* ]] || fail "it must not also report success" "$BUILD_OUT"
[[ $BUILD_OUT != *"docker is required"* ]] || fail "it must stop the build" "$BUILD_OUT"
# And with the right diagnosis. "a directory exists but holds no *.patch"
# sends the reader to look inside a directory that is not there -- the same
# distinction f20/f20b draw between an absent bin/ and an empty one.
[[ $BUILD_OUT != *"exists but holds no *.patch files"* ]] ||
  fail "an ABSENT patch directory must not be reported as an empty one" "$BUILD_OUT"
pass "guard 6.6 with no patch directory to read fails, and says it is absent rather than empty"

# Present but empty -- the likelier of the two (a move that took the directory
# and left the files), and it gets its own diagnosis.
f41="$work/f41"
make_fixture "$f41"
rm -f "$f41/src/omarchy-deck-patches/patches"/*
run_build "$f41"
[[ $BUILD_STATUS -eq 1 ]] || fail "an empty patch directory must be an ERROR" "status=$BUILD_STATUS $BUILD_OUT"
[[ $BUILD_OUT == *"holds no *.patch files"* ]] ||
  fail "an empty directory is reported as empty, not as absent" "$BUILD_OUT"
[[ $BUILD_OUT != *"docker is required"* ]] || fail "it must stop the build" "$BUILD_OUT"
pass "guard 6.6 refuses an existing-but-empty patch directory with its own diagnosis"

# --- 20e. the copy the PACKAGE ships is the one that gets checked ----------
#
# The patches ship inside omarchy-deck (T12 §5), so when a copy exists under the
# package's pkgbuild dir AND in src/, the package's is authoritative -- it is
# the one that will run on the Deck. Proved by making the package's copy the
# BROKEN one: if the guard checked src/ instead, this build would pass.
f42="$work/f42"
make_fixture "$f42"
# Flat beside the PKGBUILD, which is where the payload actually landed --
# makepkg's source=() cannot reach outside the pkgbuild directory, so a
# `find -name patches` would have looked in the one place it is not.
pkg42="$f42/iso/overlay/configs/deck/pkgbuilds/omarchy-deck"
mkdir -p "$pkg42"
cat >"$pkg42/0050-shipped-stale.patch" <<'EOF'
--- a/bin/omarchy-setup-system
+++ b/bin/omarchy-setup-system
@@ -1,2 +1,2 @@
 #!/usr/bin/zsh
-: never there
+: nor this
EOF
run_build "$f42"
[[ $BUILD_STATUS -eq 1 ]] ||
  fail "the package's own patch copy is the authoritative one and must be checked" "status=$BUILD_STATUS $BUILD_OUT"
[[ $BUILD_OUT == *"0050-shipped-stale.patch"* ]] ||
  fail "the guard checked src/ instead of the copy the package ships" "$BUILD_OUT"
[[ $BUILD_OUT == *"Also present:"*"src/omarchy-deck-patches/patches"* ]] ||
  fail "a second copy of the patch set is reported out loud, not silently ignored" "$BUILD_OUT"
pass "guard 6.6 prefers the copy the omarchy-deck package ships and announces the duplicate"

# --- 20f. the REAL patches, against the REAL pin, at unit-test speed -------
#
# Everything above proves bin/build's guard works. This proves the thing the
# guard is guarding: that THIS repo's actual runtime patches still apply at
# iso/RUNTIME. bin/build cannot answer that here -- it needs a real
# basecamp/omarchy checkout, which CI does not have and this machine must not
# download on a whim -- but test/fixtures/t12-omarchy-<sha>/ is a verbatim copy
# of upstream at exactly that pin, put there for this. Same relationship as
# section 18D: the guard fires 40 minutes into a Docker build, this fires in
# milliseconds, and they are asking the same question.
#
# The fixture path is DERIVED from iso/RUNTIME rather than written out, so
# moving the pin without refetching the fixture fails here rather than silently
# checking the patches against last month's upstream.
runtime_pin_sha=${runtime_content##*@}
RUNTIME_FIXTURE="$REPO_ROOT/test/fixtures/t12-omarchy-$runtime_pin_sha"
[[ -d $RUNTIME_FIXTURE ]] ||
  fail "no runtime fixture at test/fixtures/t12-omarchy-$runtime_pin_sha" \
    "iso/RUNTIME says $runtime_content. docs/tasks/T12-upstream-patch-seam.md §5: when the pin moves, refetch the fixture and rename it -- otherwise guard 6.6's subject can only be checked by a real build."

# Same search order bin/build's guard 6.6 uses, and for the same reason: the
# payload was mid-move between src/ and the package's pkgbuild dir when this
# was written, and a hard-coded path here would go green against a directory
# nobody ships from.
real_patch_dirs=()
real_pkgbuild_dir="$ISO_ROOT/overlay/configs/deck/pkgbuilds/omarchy-deck"
if [[ -d $real_pkgbuild_dir ]]; then
  real_patch_dirs+=("$real_pkgbuild_dir")
  while IFS= read -r dir; do
    real_patch_dirs+=("$dir")
  done < <(find "$real_pkgbuild_dir" -mindepth 1 -type d | sort)
fi
if [[ -d "$REPO_ROOT/src/omarchy-deck-patches/patches" ]]; then
  real_patch_dirs+=("$REPO_ROOT/src/omarchy-deck-patches/patches")
fi
(( ${#real_patch_dirs[@]} > 0 )) ||
  fail "this repo carries no runtime-patch directory" \
    "Not in the omarchy-deck package's pkgbuild dir and not in src/omarchy-deck-patches/patches/. bin/build's guard 6.6 hard-fails on this too; if the T12 seam was retired, retire this block on purpose."

real_patches=()
for dir in "${real_patch_dirs[@]}"; do
  shopt -s nullglob
  real_patches=("$dir"/*.patch)
  shopt -u nullglob
  (( ${#real_patches[@]} > 0 )) && break
done
(( ${#real_patches[@]} > 0 )) ||
  fail "none of this repo's candidate patch directories holds a *.patch" \
    "An empty payload is the failure guard 6.6 refuses to call a pass; this block would otherwise affirm nothing."

for p in "${real_patches[@]}"; do
  git -C "$RUNTIME_FIXTURE" apply --check -p1 -- "$p" >/dev/null 2>&1 ||
    fail "$(basename -- "$p") no longer applies to $runtime_content" \
      "The patch is applied on the TARGET at pacman time, so nothing here breaks -- the Deck just quietly loses what the patch is for. Rebase it against the pin and update its .meta in the same commit. Do NOT use --3way or a sed fallback: the reject is the point (docs/findings/T12-upstream-patch-seam.md §4)."
  # A patch with no .meta has no post-conditions and no stated purpose, which
  # is also what guard 6.6 would have to report if it ever went stale.
  [[ -f "${p%.patch}.meta" ]] ||
    fail "$(basename -- "$p") has no .meta beside it" \
      "The applier parses .meta for post-conditions and guard 6.6 quotes its 'requirement:' line as the user-visible consequence. A patch without one fails loudly with nothing to say."
done
pass "all ${#real_patches[@]} of this repo's runtime patches (${real_patches[*]##*/}) still apply to $runtime_content, and each has a .meta"

# ===========================================================================
# 21. Guard 6.4a's SECOND provider set: binaries our own package ships.
#
# 6.4a's original premise -- every /usr/bin/omarchy-* the orchestrator calls
# comes from the pinned basecamp/omarchy checkout -- broke when our own
# configure_deck phase started calling /usr/bin/omarchy-deck-apply-patches,
# which comes from the omarchy-deck package in THIS repo. Against one provider
# that is a build failure with a completely wrong diagnosis ("the pins have
# drifted", about two pins that are both fine).
#
# It was dodged for a day: deck_patches.py composes the path so the grep cannot
# see it. These cases pin the actual fix, and the thing that must not happen
# alongside it -- the union quietly becoming "anything goes".
# ===========================================================================

# add_deck_pkgbuild <root> <package()-body> -- an omarchy-deck PKGBUILD in the
# overlay, where the rsync will carry it into the tree guard 6.4a reads.
add_deck_pkgbuild() {
  local root=$1 body=$2 dir
  dir="$root/iso/overlay/configs/deck/pkgbuilds/omarchy-deck"
  mkdir -p "$dir"
  { printf 'pkgname=omarchy-deck\npkgver=0.1.0\npkgrel=1\narch=(any)\n\npackage() {\n'
    printf '%s\n' "$body"
    printf '}\n'
  } >"$dir/PKGBUILD"
}

# calls_the_applier <root> -- an orchestrator module with the LITERAL path in
# it, which is what deck_patches.py currently goes out of its way to avoid.
calls_the_applier() {
  local root=$1 orch
  orch="$root/iso/upstream/configs/airootfs/usr/share/omarchy-iso/orchestrator"
  printf 'subprocess.run(["arch-chroot", t, "/usr/bin/omarchy-deck-apply-patches"], check=True)\n' \
    >"$orch/deck_patches.py"
  git_commit_all "$root/iso/upstream" 'a phase that calls our own applier by its literal path'
  printf 'fixture/upstream@%s\n' "$(git -C "$root/iso/upstream" rev-parse HEAD)" >"$root/iso/UPSTREAM"
}

# --- 21a. a binary OUR package ships is accepted, and said so --------------

f43="$work/f43"
make_fixture "$f43"
calls_the_applier "$f43"
# shellcheck disable=SC2016  # PKGBUILD text: $pkgdir/$srcdir must reach the file UNEXPANDED -- that is the string guard 6.4a's derivation reads.
add_deck_pkgbuild "$f43" '  install -Dm755 "$srcdir/omarchy-deck-apply-patches" "$pkgdir/usr/bin/omarchy-deck-apply-patches"'
run_build "$f43"
[[ $BUILD_OUT == *"guard 6.4a OK"* ]] ||
  fail "a binary our own omarchy-deck package installs must satisfy guard 6.4a" "$BUILD_OUT"
[[ $BUILD_OUT == *"docker is required"* ]] ||
  fail "the build must proceed past 6.4a, not fail on a name the runtime was never going to ship" "$BUILD_OUT"
# Not silently: which provider covered which name is the whole point.
[[ $BUILD_OUT == *"our own omarchy-deck package (omarchy-deck-apply-patches)"* ]] ||
  fail "the pass says WHICH names came from our package rather than blurring the two providers" "$BUILD_OUT"
pass "guard 6.4a accepts /usr/bin/omarchy-deck-apply-patches from our own package and names the provider"

# --- 21b. 🔴 the union is not a bypass -------------------------------------
#
# Same orchestrator call, and a PKGBUILD that genuinely installs a DIFFERENT
# binary into /usr/bin. So the derivation is demonstrably working (it is not
# returning the empty set, and it is not returning "everything"), and the name
# actually called is still shipped by nobody.
f44="$work/f44"
make_fixture "$f44"
calls_the_applier "$f44"
# shellcheck disable=SC2016  # PKGBUILD text: $pkgdir/$srcdir must reach the file UNEXPANDED -- that is the string guard 6.4a's derivation reads.
add_deck_pkgbuild "$f44" '  install -Dm755 "$srcdir/omarchy-deck-something-else" "$pkgdir/usr/bin/omarchy-deck-something-else"'
run_build "$f44"
[[ $BUILD_STATUS -eq 1 ]] ||
  fail "🔴 a name NEITHER provider ships must still fail the build" "status=$BUILD_STATUS $BUILD_OUT"
[[ $BUILD_OUT == *"guard 6.4a"* ]] || fail "the refusal cites guard 6.4a" "$BUILD_OUT"
[[ $BUILD_OUT == *"/usr/bin/omarchy-deck-apply-patches"* ]] ||
  fail "the refusal names the binary nobody ships" "$BUILD_OUT"
# The two provider sets must stay distinguishable: "the runtime does not ship
# it" and "our package does not ship it either" are different bugs.
[[ $BUILD_OUT == *"NO provider"* ]] ||
  fail "the refusal says no provider ships it, not that the pins disagree" "$BUILD_OUT"
[[ $BUILD_OUT == *"our package"*"omarchy-deck-something-else"* ]] ||
  fail "the refusal prints our package's actual /usr/bin list, so a stale derivation is visible" "$BUILD_OUT"
[[ $BUILD_OUT == *"THE PINNED RUNTIME DOES NOT SHIP IT"* && $BUILD_OUT == *"OUR PACKAGE DOES NOT SHIP IT EITHER"* ]] ||
  fail "the refusal separates the two bugs and their two different fixes" "$BUILD_OUT"
[[ $BUILD_OUT != *"docker is required"* ]] || fail "it must stop the build before docker" "$BUILD_OUT"
pass "🔴 guard 6.4a's second provider set is a union, not a bypass: a name neither ships still fails, with both providers named"

# --- 21c. the exemption is DERIVED, and refuses to under-derive -------------

# No PKGBUILD at all: our package provides nothing, and the pass line says so
# rather than implying an exemption that does not exist.
f45="$work/f45"
make_fixture "$f45"
run_build "$f45"
[[ $BUILD_OUT == *"guard 6.4a OK"* && $BUILD_OUT == *"there is no omarchy-deck PKGBUILD at"* ]] ||
  fail "with no omarchy-deck PKGBUILD, the pass line states that our package provides nothing" "$BUILD_OUT"
pass "guard 6.4a reports an absent omarchy-deck PKGBUILD in its pass line instead of an unexplained empty set"

# The skeleton case: a PKGBUILD that installs nothing into /usr/bin is a real
# state (it is what this repo ships today), and distinct from having none.
f46="$work/f46"
make_fixture "$f46"
# shellcheck disable=SC2016  # PKGBUILD text: $pkgdir/$srcdir must reach the file UNEXPANDED -- that is the string guard 6.4a's derivation reads.
add_deck_pkgbuild "$f46" '  install -Dm644 "$srcdir/README" "$pkgdir/usr/share/omarchy-deck/README"'
run_build "$f46"
[[ $BUILD_OUT == *"guard 6.4a OK"* && $BUILD_OUT == *"installs nothing into /usr/bin"* ]] ||
  fail "a PKGBUILD with no /usr/bin targets is reported as such, distinctly from having no PKGBUILD" "$BUILD_OUT"
pass "guard 6.4a distinguishes 'our package ships no binaries' from 'our package is not there'"

# 🔴 Under-deriving must never be quiet. A target-directory install writes into
# /usr/bin and names its files where this derivation cannot see them; resolving
# that to the empty set would report every binary our package ships as shipped
# by nobody -- the same wrong diagnosis, one layer down.
f47="$work/f47"
make_fixture "$f47"
calls_the_applier "$f47"
# shellcheck disable=SC2016  # PKGBUILD text: $pkgdir/$srcdir must reach the file UNEXPANDED -- that is the string guard 6.4a's derivation reads.
add_deck_pkgbuild "$f47" '  install -Dm755 "$srcdir/omarchy-deck-apply-patches" -t "$pkgdir/usr/bin"'
run_build "$f47"
[[ $BUILD_STATUS -eq 1 ]] ||
  fail "a PKGBUILD whose /usr/bin targets cannot be derived must be an ERROR" "status=$BUILD_STATUS $BUILD_OUT"
[[ $BUILD_OUT == *"guard 6.4a cannot run"* ]] ||
  fail "the refusal says the derivation could not do its job" "$BUILD_OUT"
[[ $BUILD_OUT == *"could not derive a single binary NAME"* ]] ||
  fail "the refusal explains that it under-derived rather than blaming the package" "$BUILD_OUT"
[[ $BUILD_OUT != *"NO provider"* ]] ||
  fail "an underivable PKGBUILD must not be reported as a package that ships nothing" "$BUILD_OUT"
[[ $BUILD_OUT != *"docker is required"* ]] || fail "it must stop the build" "$BUILD_OUT"
pass "🔴 guard 6.4a fails loudly when it cannot derive a PKGBUILD's /usr/bin targets, rather than silently exempting nothing"

printf '\nall iso-build tests passed\n'
