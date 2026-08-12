#!/usr/bin/env bash
# T12 destruction test: prove that a REAL pacman transaction re-applies the
# Omarchy Deck patch set, in a throwaway Arch container.
#
# WHY THIS EXISTS, AND WHY THE UNIT SUITE IS NOT ENOUGH
#
# test/unit/test-t12-patch-applier.sh proves the applier behaves. It cannot
# prove the thing the whole seam is for: that pacman, having silently reverted
# our patched file, then runs the hook that puts it back. Every link in that
# chain is an assumption until a real transaction runs --
#
#   * that a PostTransaction hook installed in the SAME transaction fires
#     (T12 finding M1 measured this once, in isolation);
#   * that `/usr/share/libalpm/hooks/` is read at all (as opposed to
#     `/etc/pacman.d/hooks/`);
#   * that `Type = Package` + `Target = omarchy-dev` matches a `pacman -U`;
#   * that upgrading the package really does revert our edit with no .pacnew,
#     no warning, and exit 0 -- the premise the entire design rests on;
#   * that `Depends = omarchy-deck` does not stop the hook from running.
#
# ⚠️ THE DESTRUCTION HALF IS THE TEST. Asserting "the value is right after
# install" passes for the wrong reason -- it would pass with no hook at all,
# because configure_deck applies the patches once. The load-bearing assertion
# is the one AFTER the package that owns the file is reinstalled over the top.
#
# The packages here are stand-ins, not upstream's: a minimal `omarchy-dev` that
# ships the real pinned Service.qml and limine.conf at the real paths, and a
# minimal `omarchy-deck` that ships THIS repo's applier, hook and patches.
# Nothing about upstream's PKGBUILD matters to what is being tested except the
# two facts already read from it: it installs those paths, and it declares no
# backup=(). Both are reproduced here.
#
# NOT part of the unit suite: it needs Docker and it pulls a base image. Run it
# by hand, or from a slice that has network:
#
#   ./test/t12-patch-seam-container-e2e.sh
#
# Nothing here touches the Steam Deck, the host's pacman, or the network beyond
# the container image and its packages.

set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PKG_DIR="$REPO_ROOT/src/omarchy-deck-patches"
FIXTURE="$REPO_ROOT/test/fixtures/t12-omarchy-6d7826d"
IMAGE=${T12_IMAGE:-archlinux/archlinux:latest}

pass() { printf 'ok - %s\n' "$1"; }
fail() {
  printf 'not ok - %s\n' "$1"
  [[ -n ${2:-} ]] && printf '%s\n' "$2" >&2
  exit 1
}

command -v docker >/dev/null 2>&1 ||
  fail "docker is available" "this destruction test needs a throwaway Arch container; install docker or run it elsewhere"
docker info >/dev/null 2>&1 ||
  fail "the docker daemon is reachable" "docker info failed"

[[ -x $PKG_DIR/omarchy-deck-apply-patches ]] || fail "the applier exists" "$PKG_DIR"
[[ -f $FIXTURE/shell/plugins/lock/Service.qml ]] || fail "the upstream fixture exists" "$FIXTURE"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

stage="$work/stage"
mkdir -p "$stage/deck" "$stage/upstream"
cp -a "$PKG_DIR/." "$stage/deck/"
cp -a "$FIXTURE/shell" "$FIXTURE/default" "$stage/upstream/"

# --- the in-container script ------------------------------------------------
#
# Quoted heredoc: nothing here is expanded by the host shell.

cat >"$work/run.sh" <<'INNER'
#!/usr/bin/env bash
set -euo pipefail

say() { printf '\n== %s\n' "$*"; }
boom() {
  printf '\nFAILED: %s\n' "$*" >&2
  exit 1
}

QML=/usr/share/omarchy/shell/plugins/lock/Service.qml
STATE=/var/lib/omarchy-deck/patch-state.json

say "prerequisites"
# No `|| fallback` here: a fallback that quietly dropped qt6-declarative would
# make the QML post-condition unrunnable and this test would then be asserting
# something weaker than it claims.
pacman -Sy --noconfirm --needed base-devel git qt6-declarative jq >/dev/null ||
  boom "could not install the prerequisites"
command -v git >/dev/null || boom "git did not install"

# 🔴 qt6-declarative installs qmllint at /usr/lib/qt6/bin/qmllint and puts
# NOTHING on PATH. docs/findings/T12-upstream-patch-seam.md §7 recorded only
# "qmllint is present", measured on a dev machine where /usr/bin/qmllint came
# from qt5-declarative -- a different parser for a different Qt. Assert the
# real location here so the correction cannot quietly regress.
[[ -x /usr/lib/qt6/bin/qmllint ]] ||
  boom "qt6-declarative did not put qmllint at /usr/lib/qt6/bin/qmllint; the applier's resolver assumes that path"
command -v qmllint >/dev/null &&
  printf 'note - something ALSO put a qmllint on PATH in this image: %s\n' "$(command -v qmllint)"
printf 'qt6 qmllint: %s\n' "$(/usr/lib/qt6/bin/qmllint --version)"

# makepkg will not run as root. /stage is mounted read-only; everything is
# copied into /build and chowned there instead.
useradd -m builder

say "build the stand-in omarchy-dev (owns /usr/share/omarchy, NO backup array)"
mkdir -p /build/omarchy-dev
cp -a /stage/upstream /build/omarchy-dev/src-tree
cat >/build/omarchy-dev/PKGBUILD <<'PKGB'
pkgname=omarchy-dev
pkgver=1
pkgrel=1
pkgdesc="stand-in for upstream omarchy-dev: ships the same paths, no backup()"
arch=(any)
provides=(omarchy)
conflicts=(omarchy)
# Deliberately no backup=(): this mirrors the real PKGBUILD, and it is the
# reason a local edit is reverted with no .pacnew.
package() {
  install -d "$pkgdir/usr/share/omarchy"
  cp -a "$startdir/src-tree/shell" "$pkgdir/usr/share/omarchy/"
  cp -a "$startdir/src-tree/default" "$pkgdir/usr/share/omarchy/"
}
PKGB

say "build the omarchy-deck package (applier + hook + patches + unit)"
mkdir -p /build/omarchy-deck
cp -a /stage/deck /build/omarchy-deck/payload
cat >/build/omarchy-deck/PKGBUILD <<'PKGB'
pkgname=omarchy-deck
pkgver=1
pkgrel=1
pkgdesc="stand-in for the omarchy-deck package: the T12 patch seam payload"
arch=(any)
depends=(git)
package() {
  install -Dm755 "$startdir/payload/omarchy-deck-apply-patches" \
    "$pkgdir/usr/bin/omarchy-deck-apply-patches"
  install -Dm644 "$startdir/payload/50-omarchy-deck-reapply-patches.hook" \
    "$pkgdir/usr/share/libalpm/hooks/50-omarchy-deck-reapply-patches.hook"
  install -Dm644 "$startdir/payload/omarchy-deck-patch-check.service" \
    "$pkgdir/usr/lib/systemd/system/omarchy-deck-patch-check.service"
  install -d "$pkgdir/usr/share/omarchy-deck/patches"
  install -m644 "$startdir"/payload/patches/* "$pkgdir/usr/share/omarchy-deck/patches/"
}
PKGB

chown -R builder /build
for p in omarchy-dev omarchy-deck; do
  su builder -c "cd /build/$p && makepkg -f" >/dev/null 2>&1 ||
    su builder -c "cd /build/$p && makepkg -f" || boom "makepkg failed for $p"
done
DEV_PKG=$(ls /build/omarchy-dev/omarchy-dev-*.pkg.tar.*)
DECK_PKG=$(ls /build/omarchy-deck/omarchy-deck-*.pkg.tar.*)
printf 'built: %s\n        %s\n' "$DEV_PKG" "$DECK_PKG"

# ---------------------------------------------------------------------------
say "PREMISE CHECK: a non-backup packaged file is reverted silently on upgrade"
# The entire design rests on this. Assert it here rather than trusting the
# note in the finding -- if pacman ever started emitting a .pacnew, the seam
# could be simpler, and we would want to know.
pacman -U --noconfirm "$DEV_PKG" >/dev/null
grep -q 'interval: 5000' "$QML" || boom "the stand-in package did not ship upstream's file"
sed -i 's/interval: 5000/interval: 20000/' "$QML"
before_pacnew=$(find /usr/share/omarchy -name '*.pacnew' -o -name '*.pacsave' | wc -l)
upgrade_out=$(pacman -U --noconfirm "$DEV_PKG" 2>&1)
upgrade_rc=$?
after_pacnew=$(find /usr/share/omarchy -name '*.pacnew' -o -name '*.pacsave' | wc -l)
grep -q 'interval: 5000' "$QML" ||
  boom "PREMISE BROKEN: pacman did NOT revert the hand edit; the whole seam may be unnecessary"
[[ $upgrade_rc -eq 0 ]] || boom "the reverting upgrade did not exit 0"
[[ $before_pacnew -eq $after_pacnew ]] ||
  boom "PREMISE CHANGED: pacman produced a .pacnew/.pacsave; re-read T12 finding §2 M2"
printf 'ok - a hand edit is reverted silently: no .pacnew, no .pacsave, pacman exit 0\n'

# ---------------------------------------------------------------------------
say "install omarchy-deck -- its own hook must run in that same transaction"
install_out=$(pacman -U --noconfirm "$DECK_PKG" 2>&1) || boom "installing omarchy-deck failed: $install_out"
printf '%s\n' "$install_out" | sed -n '/Re-applying/p'

# The hook targets omarchy-dev, not omarchy-deck, so installing omarchy-deck
# ALONE does not fire it. That is correct and is why configure_deck must call
# the applier once at install time (T12 finding §3.4). Emulate that call.
say "configure_deck's one-shot call at install time"
omarchy-deck-apply-patches || boom "the install-time applier call failed"
grep -q 'interval: 20000' "$QML" || boom "the install-time call did not patch the file"
[[ $(jq -r .overall "$STATE") == ok ]] || boom "patch-state.json is not ok after install: $(cat "$STATE")"
printf 'ok - after install: interval: 20000 present and patch-state.json says ok\n'

# ---------------------------------------------------------------------------
say "🔴 THE DESTRUCTION TEST: reinstall omarchy-dev over the top"
# `pacman -U` does not trip upstream's direct-upgrade guard (that aborts only
# when both -S and -u are present), which is why the test uses it.
reinstall_out=$(pacman -U --noconfirm "$DEV_PKG" 2>&1) || boom "the reinstall failed: $reinstall_out"
printf '%s\n' "$reinstall_out" | sed -n '/Re-applying/p'
grep -q 'Re-applying Omarchy Deck patches' <<<"$reinstall_out" ||
  boom "the ALPM hook did not run on the reinstall -- pacman never printed its Description"
grep -q 'interval: 20000' "$QML" ||
  boom "🔴 the patch was NOT re-applied after the owning package was reinstalled -- the seam does not work"
grep -q 'interface_rotation: 270' /usr/share/omarchy/default/limine/limine.conf ||
  boom "the limine template patch was not re-applied"
[[ $(jq -r .overall "$STATE") == ok ]] || boom "patch-state.json is not ok after the reinstall"
[[ $(jq -r .invocation "$STATE") == hook ]] ||
  boom "the state file was not written by the hook (invocation=$(jq -r .invocation "$STATE")) -- something else re-applied it"
printf 'ok - the hook re-applied both patches after the owning package was reinstalled\n'

# ---------------------------------------------------------------------------
say "🔴 DRIFT THROUGH A REAL UPGRADE: upstream retunes the literal to 3000"
# Not a hand edit -- an actual package upgrade whose content is upstream's own
# retune (commit 35a6940, 30000 -> 3000). This is the event the seam exists to
# notice, and it is the event a `sed -i` would no-op through in silence.
mkdir -p /build/omarchy-dev2
cp -a /stage/upstream /build/omarchy-dev2/src-tree
sed -i "s/interval: 5000/interval: 3000/" /build/omarchy-dev2/src-tree/shell/plugins/lock/Service.qml
grep -q "interval: 3000" /build/omarchy-dev2/src-tree/shell/plugins/lock/Service.qml ||
  boom "the drift package source was not retuned"
sed "s/^pkgver=1$/pkgver=2/" /build/omarchy-dev/PKGBUILD >/build/omarchy-dev2/PKGBUILD
chown -R builder /build/omarchy-dev2
su builder -c "cd /build/omarchy-dev2 && makepkg -f" >/dev/null 2>&1 ||
  su builder -c "cd /build/omarchy-dev2 && makepkg -f" || boom "makepkg failed for the drift package"
DEV2_PKG=$(ls /build/omarchy-dev2/omarchy-dev-2-*.pkg.tar.*)

set +e
drift_out=$(pacman -U --noconfirm "$DEV2_PKG" 2>&1)
drift_pacman_rc=$?
set -e
printf 'pacman exit status on a transaction whose PostTransaction hook failed: %s\n' "$drift_pacman_rc"
grep -q "Re-applying Omarchy Deck patches" <<<"$drift_out" ||
  boom "the hook did not run on the drift upgrade: $drift_out"
grep -qi "drift" <<<"$drift_out" ||
  boom "the pacman transcript does not name the drift -- channel 1 of four is dead: $drift_out"
grep -qi "are NOT in effect" <<<"$drift_out" ||
  boom "the transcript does not say what the failure MEANS to the user: $drift_out"
grep -q "interval: 3000" "$QML" ||
  boom "the applier modified the file despite reporting drift -- it complained and carried on"
[[ $(jq -r .overall "$STATE") == failed ]] || boom "patch-state.json does not record the drift: $(cat "$STATE")"
[[ $(jq -r '.patches[] | select(.patch=="0010-lock-blank-timer-20s.patch") | .status' "$STATE") == drift ]] ||
  boom "the drift is not diagnosed as drift: $(cat "$STATE")"
[[ $(jq -r .invocation "$STATE") == hook ]] || boom "the failing state file was not written by the hook"
printf 'ok - a real upgrade carrying upstream\x27s 3000 is caught: the hook runs, names the drift, changes nothing\n'

say "and --verify still fails afterwards, which is what leaves a failed unit"
set +e
omarchy-deck-apply-patches --verify >/tmp/verify.log 2>&1
verify_rc=$?
set -e
[[ $verify_rc -ne 0 ]] ||
  boom "--verify exited 0 on a drifted tree, so the boot unit would go active and nothing would be visible"
printf 'ok - --verify exits %s on drift, which is what leaves systemctl --failed non-empty\n' "$verify_rc"

say "back to a good state for the remaining checks"
pacman -U --noconfirm "$DEV_PKG" >/dev/null 2>&1 || true
omarchy-deck-apply-patches >/dev/null || boom "could not restore a patched state"

say "-Qkk reports the patched file as altered (the known, accepted cost)"
pacman -U --noconfirm "$DEV_PKG" >/dev/null
omarchy-deck-apply-patches >/dev/null
qkk_out=$(pacman -Qkk omarchy-dev 2>&1) || true
grep -q 'Service.qml' <<<"$qkk_out" ||
  boom "pacman -Qkk did NOT report the patched Service.qml as altered. T12 finding §3.5 accepts that it does, as a known cost and a free detector; if that has changed, the finding needs updating -- output was: $qkk_out"
printf 'ok - pacman -Qkk names the patched file (the known, accepted cost of T12 finding §3.5)\n'

# ---------------------------------------------------------------------------
say "--verify agrees the tree is good again"
omarchy-deck-apply-patches --verify >/dev/null || boom "--verify failed on a correctly patched tree"
printf 'ok - --verify exits 0 on a correctly patched tree\n'

printf '\nALL CONTAINER ASSERTIONS PASSED\n'
INNER

chmod +x "$work/run.sh"

printf 'running the T12 destruction test in %s ...\n' "$IMAGE"
if docker run --rm \
  -v "$stage:/stage:ro" \
  -v "$work/run.sh:/run.sh:ro" \
  "$IMAGE" bash /run.sh; then
  pass "the T12 patch seam survives a real pacman reinstall of the package that owns the file"
else
  fail "the T12 patch seam destruction test" "see the container output above"
fi
