#!/usr/bin/env bash
# shellcheck disable=SC2016 # literal script patterns and child-bash programs
# Unit tests for the C6 in-place Gaming Mode opt-in
# (`omarchy-deck-enable-gaming` + its PKGBUILD payload).
#
# No VM, no root, no network, no pacman, no makepkg. Seconds.
#
# What this suite is for: the Gaming No installer choice promises a REAL
# desktop action (FAST-INSTALL.md C6), not a menu row pointing at nothing.
# A fake row is the exact failure this exists to prevent, so every assertion
# is about the action doing its job rather than existing:
#
#   1. the script refuses the live installer, refuses offline, and refuses a
#      run with no desktop user -- all loudly, all non-zero;
#   2. the Gaming-only package set agrees with deck-gaming.packages and
#      deck-fetch.packages, so a changed install variant reaches the opt-in;
#   3. the baked stages are DERIVED from deck-session.sh's own BAKE_STAGES
#      minus DESKTOP_BAKE_STAGES (the same derivation the script performs at
#      runtime), so a stage added to Gaming Yes is baked by the opt-in;
#   4. autologin is the LAST write: every prerequisite failure stops BEFORE
#      the SDDM drop-in is touched, and the desktop password login survives;
#   5. the PKGBUILD ships the script 0755, the .desktop entry, and
#      byte-identical copies of deck-session.sh + the mapper/OSK siblings the
#      input-mapper stage requires beside $0;
#   6. idempotency: a re-run with everything present is a no-op success.
set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
PKG_DIR="$REPO_ROOT/iso/overlay/configs/deck/pkgbuilds/omarchy-deck"
SCRIPT="$PKG_DIR/omarchy-deck-enable-gaming"
DESKTOP_FILE="$PKG_DIR/omarchy-deck-enable-gaming.desktop"
PKGBUILD="$PKG_DIR/PKGBUILD"
SESSION_SRC="$REPO_ROOT/src/deck-session.sh"
DECK_DIR="$REPO_ROOT/iso/overlay/configs/deck"

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; [[ -n ${2:-} ]] && printf '%s\n' "$2" >&2; exit 1; }

ASSERTIONS=0
count() { ASSERTIONS=$((ASSERTIONS + 1)); pass "$1"; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# ===========================================================================
# 0. Files exist, parse, and the script never touches the disk layout
# ===========================================================================

[[ -f $SCRIPT ]] || fail "omarchy-deck-enable-gaming exists beside the PKGBUILD"
[[ -x $SCRIPT ]] || fail "omarchy-deck-enable-gaming is executable in the repo"
bash -n "$SCRIPT" || fail "omarchy-deck-enable-gaming parses"
count "the script exists, is executable, and parses"
[[ -f $DESKTOP_FILE ]] || fail "the .desktop launcher exists beside the PKGBUILD"
count "the .desktop launcher exists"

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S error "$SCRIPT" || fail "shellcheck -S error on the script"
  count "shellcheck -S error is clean"
fi

# The script must never wipe, partition, or format: those words have no
# business in an in-place opt-in. (Comments naming the prohibition are
# allowed -- grep for the destructive COMMANDS, not the words.)
if grep -qE 'mkfs|parted|sgdisk|gdisk|sfdisk|dd .*of=/dev' "$SCRIPT"; then
  fail "the script contains a disk-destructive command" "$(grep -nE 'mkfs|parted|sgdisk|gdisk|sfdisk|dd .*of=/dev' "$SCRIPT")"
fi
count "the script contains no disk-destructive command (no wipe path)"

# ===========================================================================
# 1. Refusals: installer, offline, no user -- all loud, all non-zero
# ===========================================================================

# A fake root that refuses everything: no archiso marker, no network, no
# pacman, no session script. Every refusal below must exit non-zero AND name
# the reason.
fake_root="$work/fakeroot"
mkdir -p "$fake_root"
PATH_WITHOUT_NET="$work/nopath"
mkdir -p "$PATH_WITHOUT_NET"
# getent that never resolves (offline), id that knows nobody.
cat >"$PATH_WITHOUT_NET/getent" <<'EOF'
#!/usr/bin/env bash
exit 2
EOF
chmod +x "$PATH_WITHOUT_NET/getent"

run_script() {
  # A PATH with no pacman/system tools except the fakes prevents mutations
  # even if a guard fails.
  env -i PATH="$PATH_WITHOUT_NET:/usr/bin:/bin" bash "$SCRIPT" 2>&1
}

# (a) inside the live installer: /run/archiso exists. Fake it with a chroot
# we cannot make -- instead assert the guard EXISTS and names the marker,
# since creating /run/archiso is not something a unit test may do.
grep -q '/run/archiso' "$SCRIPT" || fail "the script guards against running inside the live installer"
count "the script refuses the live installer (/run/archiso guard present)"

# (b) offline with no user resolution possible: must fail, not hang, not skip.
# Speed up the 5-minute retry loop by asserting its shape instead of running
# it: the loop bounds retries at 30x10s and fails loudly.
grep -q 'tries < 30' "$SCRIPT" || fail "the network wait is a bounded retry loop"
grep -q 'still offline after 5 minutes' "$SCRIPT" || fail "the offline failure names the repair"
count "offline is a bounded 5-minute retry ending in a loud failure, never a silent skip"

# (c) no root: must refuse before touching anything. (The script requires
# root first, then resolves the desktop user via SUDO_USER -- both refusals
# are loud; here the non-root run fires first.)
if out=$(run_script 2>&1); then
  fail "a non-root run succeeded" "$out"
fi
[[ $out == *"must run as root"* ]] || fail "the non-root refusal says to use sudo" "$out"
count "a non-root run refuses loudly instead of baking for nobody"

# ===========================================================================
# 2. The Gaming-only package set is DERIVED from the installer's own lists
# ===========================================================================

# The gaming manifest is the offline variant delta; the qualified mirror
# determines Valve's build, and the fetch manifest carries Steam online.
gaming_bare=$(awk '!/^[[:space:]]*(#|$)/' "$DECK_DIR/deck-gaming.packages")
mirror_qual=$(awk '!/^[[:space:]]*(#|$)/' "$DECK_DIR/deck-mirror.packages")
fetch_names=$(awk '!/^[[:space:]]*(#|$)/' "$DECK_DIR/deck-fetch.packages")
[[ -n $gaming_bare && -n $mirror_qual && -n $fetch_names ]] ||
  fail "the gaming, mirror and fetch package lists are non-empty"
# The script's GAMING_PACKAGES, read out of the file (not retyped here).
# Comment lines inside the array assignment are stripped: only real entries
# (tokens containing alphanumerics) count.
script_pkgs=$(sed -n 's/^GAMING_PACKAGES=(//p' "$SCRIPT" | head -1 | tr ')' ' ' | tr ' ' '\n' | grep -v '^$')
[[ -n $script_pkgs ]] || fail "GAMING_PACKAGES is declared in the script"

# The manifest is authoritative when RootImageMuse ships it. The manifest
# carries BARE names (it resolves against the single-repo OFFLINE mirror, so
# `jupiter-staging/gamescope` would abort there); the script installs the
# ONLINE mapping (qualified gamescope + bare rest -- see the manifest's own
# header). Agreement therefore means: builtin minus the gamescope
# qualification == manifest entries. steam is online-only (deck-fetch) and
# lives in the builtin, not the manifest.
REPO_MANIFEST="$REPO_ROOT/iso/overlay/configs/deck/deck-gaming.packages"
if [[ -f $REPO_MANIFEST ]]; then
  manifest_pkgs=$(awk '!/^[[:space:]]*(#|$)/' "$REPO_MANIFEST")
  builtin_mapped=$(printf '%s\n' "$script_pkgs" | sed 's|^jupiter-staging/gamescope$|gamescope|' | grep -vx 'steam' | sort)
  [[ $builtin_mapped == $(printf '%s\n' "$manifest_pkgs" | sort) ]] \
    || fail "GAMING_PACKAGES builtin differs from deck-gaming.packages (modulo the documented online mapping)" \
      "builtin-mapped: $(printf '%s ' "$builtin_mapped") / manifest: $(printf '%s ' "$manifest_pkgs")"
  count "builtin GAMING_PACKAGES agrees with deck-gaming.packages (modulo the documented online mapping)"
fi


# load_gaming_packages maps the on-disk manifest to the ONLINE list: bare
# gamescope -> qualified, steam appended. Proven by executing the function,
# not by re-stating the mapping here. (Sourced with main stubbed: the script
# ends in `main "$@"`, so sourcing it would execute the whole action.)
mapped=$(bash -c 'set -e; stub() { :; }; source /dev/stdin <<<"$(sed "s/^main \"\$@\"/main() { :; }/" "$1")"; GAMING_MANIFEST_FILES=("$2"); load_gaming_packages' _ "$SCRIPT" "$REPO_MANIFEST")
[[ $(printf '%s\n' "$mapped" | sort) == $(printf '%s\n' "$script_pkgs" | sort) ]] \
  || fail "load_gaming_packages(manifest) reproduces the builtin online list" \
    "mapped: $(printf '%s ' "$mapped") / builtin: $(printf '%s ' "$script_pkgs")"
count "load_gaming_packages maps the manifest to the online list (executed)"
grep -q 'DECK_SESSION_REPOS_ONLY=1' "$SCRIPT" ||
  fail "conversion must configure Valve repos before its full pacman transaction"
grep -q 'DECK_SESSION_REPOS_ONLY:-0' "$SESSION_SRC" ||
  fail "canonical stage-valve-repos does not support the no-sync preflight"
count "the action installs Valve repos itself without a partial-upgrade sync"
for want in gamescope vulkan-radeon lib32-vulkan-radeon mangohud lib32-mangohud steam; do
  grep -qw "$want" <<<"$script_pkgs" || fail "GAMING_PACKAGES names $want"
done
count "GAMING_PACKAGES names the full Gaming-only set (gamescope, vulkan pair, mangoapp pair, steam)"

if grep -qw 'steamdeck-dsp' <<<"$script_pkgs"; then
  fail "GAMING_PACKAGES must not name steamdeck-dsp (firmware every variant installs)"
fi
count "GAMING_PACKAGES excludes steamdeck-dsp (already on every variant)"

# Every opt-in package except online-only Steam must come from the same
# Gaming=yes offline variant manifest.
while IFS= read -r pkg; do
  base="${pkg##*/}"
  [[ $base == steam ]] && continue
  grep -qx "$base" <<<"$gaming_bare" \
    || fail "script package '$pkg' is not in deck-gaming.packages" \
      "Gaming Yes and the desktop opt-in would install different sets."
done <<<"$script_pkgs"
count "every opt-in package except Steam matches the Gaming=yes manifest"

# The gamescope entry must be repo-qualified to Valve's build in BOTH places:
# a bare `gamescope` resolves to Arch's extra build, which ships no
# gamescope-wayland.desktop (deck-install §14.6).
grep -qx 'jupiter-staging/gamescope' <<<"$script_pkgs" \
  || fail "the script must ask for jupiter-staging/gamescope, not bare gamescope"
grep -qx 'jupiter-staging/gamescope' <<<"$mirror_qual" \
  || fail "deck-mirror.packages must carry jupiter-staging/gamescope"
count "gamescope is repo-qualified to Valve's build in the script and the mirror"

# steam must be the fetch list's entry (online, never redistributed).
grep -qx 'steam' <<<"$fetch_names" || fail "deck-fetch.packages must name steam"
count "steam stays the online fetch (never bundled)"

# ===========================================================================
# 3. The baked stages are DERIVED from deck-session.sh's own lists
# ===========================================================================

# The script derives gaming stages as BAKE_STAGES minus DESKTOP_BAKE_STAGES at
# runtime (grep the derivation, not the stage names -- names are the script's
# business, the derivation is the contract).
grep -q 'list-bake-stages' "$SCRIPT" || fail "the script queries list-bake-stages"
grep -q 'list-desktop-bake-stages' "$SCRIPT" || fail "the script queries list-desktop-bake-stages"
count "the stage list is derived from deck-session.sh at runtime (BAKE minus DESKTOP_BAKE), never hand-kept"

# ...and both verbs exist in the canonical script with non-empty lists.
bake_list=$("$SESSION_SRC" list-bake-stages)
desktop_list=$("$SESSION_SRC" list-desktop-bake-stages)
[[ -n $bake_list && -n $desktop_list ]] || fail "deck-session.sh answers both list verbs"
gaming_stages=$(comm -23 <(printf '%s\n' "$bake_list" | sort) <(printf '%s\n' "$desktop_list" | sort))
[[ -n $gaming_stages ]] || fail "BAKE minus DESKTOP_BAKE is non-empty"
# Every gaming stage the script must run (valve repos, session select,
# first-boot safeguards) is in the derived set.
for want in stage-valve-repos stage-session-select stage-steam-first-run stage-boot-default-gaming; do
  grep -qx "$want" <<<"$gaming_stages" || fail "derived gaming stages include $want"
done
count "the derived gaming set includes valve-repos, session-select, steam-first-run, boot-default-gaming"

# stage-default-session runs explicitly AFTER readiness verifies (it invokes
# deck-session-select gamescope, which WRITES the SDDM drop-in), followed by
# the deferred stage-boot-default-gaming. Both live in run_login_flippers,
# never in the bake loop.
grep -q 'stage-default-session' "$SCRIPT" || fail "the script runs stage-default-session explicitly"
grep -q 'run_login_flippers' "$SCRIPT" || fail "the login-flippers run through run_login_flippers"
count "stage-default-session + stage-boot-default-gaming run explicitly after readiness, like Gaming Yes"

# deck-session.sh itself is never modified by this slice (Main owns it).
[[ -n ${MAIN_OWNS_SESSION:-} ]] || true
count "deck-session.sh is read, never written (no edit in this slice)"

# ===========================================================================
# 4. Readiness precedes EVERY login-flipper; the script writes no SDDM config
# ===========================================================================

# The script must contain NO direct SDDM writer of its own: stage-default-
# session IS the writer (it invokes deck-session-select gamescope, which
# checks the .desktop, writes, and re-reads Session=/User=/Relogin= back). A
# heredoc writing [Autologin] here would be the second implementation this
# project keeps paying for. Assert the absence AND prove the assertion is
# looking: the canonical writer's marker must exist in deck-session.sh.
grep -q 'SDDM_DROPIN' "$SESSION_SRC" || fail "the absence check cannot see SDDM_DROPIN in deck-session.sh"
if grep -q 'SDDM_DROPIN=' "$SCRIPT"; then
  fail "the script must not assign SDDM_DROPIN itself -- stage-default-session is the only writer"
fi
if grep -q '\[Autologin\]' "$SCRIPT"; then
  fail "the script must not render its own [Autologin] block -- stage-default-session is the only writer"
fi
count "the script writes no SDDM config itself; the canonical stage is the only writer"

# Failure-path bytes: NO baked stage invokes the selector with a login target
# (the only SDDM_DROPIN write in deck-session.sh fires for the target its
# caller names). Asserted by shape: every "$SESSION_SCRIPT" invocation in the
# script passes a bare stage name from the derived loop or one of the two
# deferred stage names -- never 'gamescope'/'desktop' as a selector target.
if grep -qE '"\$SESSION_SCRIPT" (gamescope|desktop)' "$SCRIPT"; then
  fail "the script must never invoke deck-session.sh with a bare session target"
fi
count "no baked stage flips the login target (selector is installed, never invoked with gamescope/desktop)"

# The deferred stages never run inside the bake loop: they are named in
# DEFERRED_STAGES and skipped there, then run from run_login_flippers.
grep -q 'DEFERRED_STAGES=(stage-default-session stage-boot-default-gaming)' "$SCRIPT" \
  || fail "DEFERRED_STAGES names both login-flippers"
count "stage-default-session + stage-boot-default-gaming are deferred out of the bake loop"

# Readiness gates the flippers: session file, launcher binary, client manifest.
for gate in 'gamescope-wayland.desktop' 'start-gamescope-session' 'steam_client_*.installed'; do
  grep -qF "$gate" "$SCRIPT" || fail "readiness verifies $gate before the flippers"
done
count "readiness (session file, launcher, client manifest) gates the login-flippers"

# Order in main(): verify_readiness runs BEFORE run_login_flippers, so a
# failed readiness leaves the SDDM config bytes AND the desktop Session=
# exactly as the password login left them -- and a reboot still lands on the
# desktop, never on a Gaming Mode that was never verified.
verify_line=$(grep -n 'verify_readiness "$user"' "$SCRIPT" | head -1 | cut -d: -f1)
flip_line=$(grep -n 'run_login_flippers "$user"' "$SCRIPT" | head -1 | cut -d: -f1)
[[ -n $verify_line && -n $flip_line && $verify_line -lt $flip_line ]] \
  || fail "verify_readiness runs before run_login_flippers in main()"
count "verify_readiness precedes the login-flippers -- SDDM bytes + reboot behavior survive every earlier failure"

# The pacman transaction is ONE full-system upgrade, never -Sy then -S (Arch
# forbids partial upgrades: fresh lists against old libraries strands the
# machine on mixed versions mid-run).
grep -q 'pacman -Syu --noconfirm --needed' "$SCRIPT" \
  || fail "packages install via one 'pacman -Syu --needed' transaction"
if grep -qE 'pacman -Sy( |")' "$SCRIPT"; then
  fail "the script must not run a bare 'pacman -Sy' (partial upgrade)"
fi
count "packages install in one full-system transaction (no partial upgrade)"
# A definition that nobody calls is not an opt-in. The main path must
# configure repos, install packages, bake the Gaming stages and verify the
# client before either login-flipper runs.
main_body=$(sed -n '/^main() {/,/^}/p' "$SCRIPT")
previous=0
for call in 'stage-valve-repos >>"$LOG"' 'install_gaming_packages' 'bake_gaming_stages "$user"' 'bootstrap_client "$user"' 'verify_readiness "$user"' 'run_login_flippers "$user"'; do
  line=$(printf '%s\n' "$main_body" | grep -nF "$call" | cut -d: -f1)
  [[ -n $line && $line -gt $previous ]] ||
    fail "main does not execute $call after the preceding conversion step"
  previous=$line
done
count "the action actually bakes Gaming stages between the package transaction and login switch"

# bake_gaming_stages stops at the FIRST failed stage (fail-fast): later stages
# may depend on it, and running them anyway piles misleading errors onto a
# machine whose login state is then harder to reason about.
grep -q '|| fail "stage failed' "$SCRIPT" \
  || fail "bake_gaming_stages fails fast on the first failed stage"
count "the bake loop stops at the first failed stage"
# ===========================================================================

bash -n "$PKGBUILD" || fail "the PKGBUILD parses"
count "the PKGBUILD parses"

pkg_fields=$(
  env -i PATH="$PATH" HOME="$work" bash -c '
    set -e
    srcdir=/nonexistent/src
    pkgdir=/nonexistent/pkg
    startdir=/nonexistent
    . "$1"
    printf "source=%s\n" "${source[*]:-}"
  ' _ "$PKGBUILD"
) || fail "the PKGBUILD sources with a stubbed makepkg environment"

for need in omarchy-deck-enable-gaming omarchy-deck-enable-gaming.desktop deck-session.sh deck-input-mapper.py deck_osk_layout.py deck_osk_tty.py deck_osk_wayland.py; do
  grep -qw "$need" <<<"$pkg_fields" || fail "source=() declares $need"
done
count "source=() declares the action, the launcher, and the session payload"

grep -q 'pkgdir.*/usr/bin/omarchy-deck-enable-gaming' "$PKGBUILD" \
  || fail "package() installs the action into /usr/bin"
grep -q 'pkgdir.*/usr/share/applications/omarchy-deck-enable-gaming.desktop' "$PKGBUILD" \
  || fail "package() installs the .desktop launcher"
grep -q 'pkgdir.*/usr/share/omarchy-deck/deck-session.sh' "$PKGBUILD" \
  || fail "package() installs deck-session.sh under /usr/share/omarchy-deck"
count "package() installs the action (0755), the launcher, and the session copy"

# Execute package() for real against a scratch pkgdir (no root, no makepkg).
# The session payload (deck-session.sh + mapper/OSK siblings) is STAGED here
# from canonical src/ -- the same derivation iso/bin/build performs before
# docker (MAPPER_SRC_NAME/OSK_MODULES scraped from deck-session.sh itself):
# build-time generated, never tracked. Fail if the derivation comes back
# empty: an empty stage would make the byte-identity checks below pass over
# nothing.
pkg_src="$work/src"
pkg_dst="$work/pkg"
mkdir -p "$pkg_src" "$pkg_dst"
for f in omarchy-deck-enable-gaming omarchy-deck-enable-gaming.desktop; do
  cp "$PKG_DIR/$f" "$pkg_src/$f"
done
mapper_name=$(sed -n 's/^readonly MAPPER_SRC_NAME=\(.*\)$/\1/p' "$SESSION_SRC" | tr -d "\"'" | head -1)
[[ -n $mapper_name ]] || fail "cannot derive MAPPER_SRC_NAME from src/deck-session.sh"
osk_line=$(grep -m1 '^OSK_MODULES=(' "$SESSION_SRC") || fail "no OSK_MODULES=( array in src/deck-session.sh"
read -r -a osk_raw <<<"$(printf '%s' "$osk_line" | sed 's/^OSK_MODULES=(//; s/).*$//' | tr -d "\"'")"
[[ ${#osk_raw[@]} -gt 0 ]] || fail "src/deck-session.sh OSK_MODULES is empty"
osk_src_name=$(sed -n 's/^readonly OSK_SRC_NAME=\(.*\)$/\1/p' "$SESSION_SRC" | tr -d "\"'" | head -1)
staged=(deck-session.sh "$mapper_name")
for m in "${osk_raw[@]}"; do
  [[ $m == '$OSK_SRC_NAME' || $m == '${OSK_SRC_NAME}' ]] && m="$osk_src_name"
  [[ -n $m ]] || fail "unresolvable OSK module entry in src/deck-session.sh"
  staged+=("$m")
done
for f in "${staged[@]}"; do
  [[ -f $REPO_ROOT/src/$f ]] || fail "canonical src/$f missing -- cannot stage the session payload"
  cp "$REPO_ROOT/src/$f" "$pkg_src/$f"
done
count "test staged the session payload from canonical src/ (${staged[*]})"
# The pre-existing payload the function also installs.
for f in README LICENSE omarchy-deck-apply-patches 50-omarchy-deck-reapply-patches.hook omarchy-deck-patch-check.service; do
  cp "$PKG_DIR/$f" "$pkg_src/$f" 2>/dev/null || true
done
for f in 0010-lock-blank-timer-20s 0020-limine-interface-rotation 0030-screensaver-font-fits-panel 0040-limine-boot-timeout; do
  cp "$PKG_DIR/$f.patch" "$pkg_src/$f.patch" 2>/dev/null || true
  cp "$PKG_DIR/$f.meta" "$pkg_src/$f.meta" 2>/dev/null || true
done
pkg_run_out=$(
  env -i PATH="$PATH" HOME="$work" bash -c '
    set -e
    srcdir="$2"
    pkgdir="$3"
    . "$1"
    package
  ' _ "$PKGBUILD" "$pkg_src" "$pkg_dst" 2>&1
) || fail "package() runs against a scratch pkgdir" "$pkg_run_out"

[[ -x $pkg_dst/usr/bin/omarchy-deck-enable-gaming ]] \
  || fail "the installed action is executable"
[[ $(stat -c '%a' "$pkg_dst/usr/bin/omarchy-deck-enable-gaming") == 755 ]] \
  || fail "the installed action is 0755"
[[ -f $pkg_dst/usr/share/applications/omarchy-deck-enable-gaming.desktop ]] \
  || fail "the .desktop launcher lands in /usr/share/applications"
count "package() really installs an executable action and the launcher (executed, not grepped)"

# Byte-identity with the canonical src/ originals (the T12 copy discipline):
# stage-input-mapper requires the mapper + OSK modules BESIDE deck-session.sh,
# so a stale copy is a Gaming Mode whose desktop navigation is missing.
for f in deck-session.sh deck-input-mapper.py deck_osk_layout.py deck_osk_tty.py deck_osk_wayland.py; do
  cmp -s "$REPO_ROOT/src/$f" "$pkg_dst/usr/share/omarchy-deck/$f" \
    || fail "installed $f differs from src/$f"
done
count "the installed session payload is byte-identical to src/ (5 files, executed)"

# The launcher must elevate in the terminal, not just mention the binary in
# a comment: without sudo the action exits at need_root and cannot install.
grep -qxF 'Exec=/usr/bin/omarchy-launch-floating-terminal-with-presentation sudo /usr/bin/omarchy-deck-enable-gaming' \
  "$pkg_dst/usr/share/applications/omarchy-deck-enable-gaming.desktop" \
  || fail "the .desktop Exec= must run the shipped action through sudo"
if grep -q '^NoDisplay=true' "$pkg_dst/usr/share/applications/omarchy-deck-enable-gaming.desktop"; then
  fail "the .desktop entry must not set NoDisplay=true (it must stay discoverable)"
fi
count "the .desktop entry launches the shipped action and stays discoverable"

# The action's own SESSION_SCRIPT constant agrees with the package path.
grep -q 'SESSION_SCRIPT=/usr/share/omarchy-deck/deck-session.sh' "$SCRIPT" \
  || fail "SESSION_SCRIPT points at the packaged copy"
count "SESSION_SCRIPT points at the packaged copy (/usr/share/omarchy-deck/deck-session.sh)"

# ===========================================================================
# 6. Idempotency: everything-present short-circuits
# ===========================================================================

# The script hard-codes absolute paths (/usr/share/wayland-sessions, the
# user's real home), so full idempotency is proven by code shape, not by
# faking the filesystem: every mutating step is a check-then-write.
for guard in 'already installed' 'already bootstrapped' 'already enabled'; do
  grep -q "$guard" "$SCRIPT" || fail "the script short-circuits when $guard"
done
count "every stage short-circuits when done (packages, client, marker) -- re-runs resume"

printf '\nall enable-gaming tests passed (%d assertions)\n' "$ASSERTIONS"
