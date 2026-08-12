#!/usr/bin/env bash
# deck-nvidia-dry-run.sh -- build-time guard: the Steam Deck ISO must not
# resolve the NVIDIA driver stack.
#
# Run from inside builder/build-iso.sh's container (see the overlay patch
# deck-packages.patch), after the shipped omarchy-base.packages exists and
# BEFORE the ~6 GB `pacman -Syw` -- a bad package set should cost seconds, not
# a full mirror download.
#
# Usage:
#   deck-nvidia-dry-run.sh <pacman-conf> <base-packages> <archinstall-packages> \
#                          <deck-list-dir> [extra-target...]
#
# Env:
#   DECK_NVIDIA_DRYRUN_ROOT   scratch --root for the resolve
#                             (default /tmp/omarchy-deck-nvidia-dryrun)
#   DECK_LOCAL_PACKAGES       space-separated names that this build produces
#                             ITSELF and that therefore exist in no online
#                             repository (T5-fork-plan.md §3 seam S4). Empty or
#                             unset is legal and means "we build nothing".
#
# ---------------------------------------------------------------------------
# What it asserts, and why it is shaped this way
# ---------------------------------------------------------------------------
#
# docs/PROGRESS.md §3.8: `steam` depends on the VIRTUAL packages `vulkan-driver`
# and `lib32-vulkan-driver`. With no AMD provider selected, pacman picks the
# NVIDIA stack on its own. **Nothing errors.** Several hundred MB of driver that
# cannot run on this hardware just appears in an uncompressed offline mirror.
#
# 🔴 This is a SHAPE assertion. It is deliberately not a count and not a
# version. `iso/PKGS` pins only the three locally-built packages' *sources*;
# the other ~1241 packages in the offline mirror still come from the rolling
# `edge` channel, so a test asserting "1244 packages" or a pinned version would
# go red on an unrelated upstream repackage and teach everyone to ignore it.
#
# ⚠️ SCOPE: this is about what gets INSTALLED, not about what the mirror
# carries. The offline mirror deliberately contains nvidia-dkms,
# nvidia-open-dkms, nvidia-utils, lib32-nvidia-utils, egl-wayland and
# libva-nvidia-driver -- upstream lists them in `omarchy-other.packages` as
# hardware alternatives for machines that are not this one. Widening this guard
# to the mirror would make it permanently red against a decision that is not
# ours; dropping them is a SIZE question and belongs to T5g.
#
# ---------------------------------------------------------------------------
# 🔴 How this proves it was LOOKING
# ---------------------------------------------------------------------------
#
# docs/PROGRESS.md §5.30c catalogues a class of failure this project found four
# instances of in one day: **a check whose passing state is indistinguishable
# from its not-having-run state.** One of them was a `grep` citing a path that
# did not exist -- exit 2 reads exactly like "no match". So:
#
#  1. Every input file is checked for existence FIRST, and a missing one is a
#     hard failure. "The file wasn't there" must never read as "nothing found".
#  2. pacman's exit status is captured. `-S --print` aborts the entire
#     transaction if any single target is unresolvable, which would otherwise
#     produce empty output -- i.e. a perfect, silent green.
#  3. The resolved set must be plausibly large (>= MIN_CLOSURE), so a resolve
#     that returned almost nothing cannot pass.
#  4. POSITIVE CONTROL: every package we asked about by name -- both pins and
#     every fetched package -- must be present in the resolved output. If
#     `steam` is not in the answer, the question was not asked.
#  5. The accepted exception (`linux-firmware-nvidia`) must actually be
#     present. An exception nobody needs any more is an exception that will
#     silently widen later.
#  6. NEGATIVE CONTROL: the identical resolve is run again with the pins
#     removed, and the matcher is REQUIRED to fire. If it does not, either the
#     matcher matches nothing any more or upstream changed the default
#     provider -- and in both cases the green result above proves nothing, so
#     the build stops.
#  7. DECK_LOCAL_PACKAGES is an EXCLUSION, and an exclusion is a hole. It has
#     to prove it was deliberate, so each excluded name must (a) actually be in
#     deck-install.packages -- excluding a name nobody installs is excluding
#     nothing, and (b) actually be removed from the assembled target list, with
#     the arithmetic checked. A name that silently vanished from the list makes
#     the count wrong and fails the build. The positive control in (4) is NOT
#     widened to tolerate their absence; they get the opposite assertion
#     instead -- a locally built name that DOES resolve online is a name
#     collision with a real package, and that is its own failure.
#
# None of the matchers below use grep's exit status to mean "found/not found";
# they are awk filters, which exit 0 whether or not they printed. The
# found/not-found decision is made once, on the emptiness of a captured string.

set -euo pipefail

PROG=deck-nvidia-dry-run

log() { printf '[%s] %s\n' "$PROG" "$*"; }
fail() {
  printf '[%s] ERROR: %s\n' "$PROG" "$1" >&2
  shift
  local line
  for line in "$@"; do printf '[%s]        %s\n' "$PROG" "$line" >&2; done
  exit 1
}

# The smallest target closure that could plausibly be a real Omarchy install.
# Upstream's own resolve_expected_packages uses the same lower bound for the
# install dashboard's denominator (builder/build-iso.sh), and the measured
# value on 2026-08-12 was 934 before this slice's additions.
MIN_CLOSURE=600

# The only package matching the NVIDIA pattern that this build accepts, and the
# reason. `linux-firmware-nvidia` is a firmware blob pulled in by the
# `linux-firmware` meta-package; it carries no driver, no 32-bit userspace and
# no EGL, it has been in the target closure since long before this slice, and
# it has nothing to do with §3.8's provider-resolution mechanism.
readonly -a NVIDIA_EXCEPTIONS=(linux-firmware-nvidia)

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

(($# >= 4)) || fail \
  "usage: $0 <pacman-conf> <base-packages> <archinstall-packages> <deck-list-dir> [extra-target...]" \
  "got $# argument(s)."

PACMAN_CONF=$1
BASE_PACKAGES=$2
ARCHINSTALL_PACKAGES=$3
LIST_DIR=$4
shift 4
EXTRA_TARGETS=("$@")

INSTALL_LIST="$LIST_DIR/deck-install.packages"
FETCH_LIST="$LIST_DIR/deck-fetch.packages"

# (1) Existence first, always. A missing input is an error, never a quiet zero.
[[ -d $LIST_DIR ]] || fail "deck package list directory not found: $LIST_DIR"
for required in "$PACMAN_CONF" "$BASE_PACKAGES" "$ARCHINSTALL_PACKAGES" \
  "$INSTALL_LIST" "$FETCH_LIST"; do
  [[ -f $required ]] || fail \
    "input not found: $required" \
    "Refusing to run: a dry run over inputs that do not exist reports no NVIDIA" \
    "packages for exactly the wrong reason (docs/PROGRESS.md §5.30c)."
done

command -v pacman >/dev/null 2>&1 || fail \
  "pacman is not on PATH" \
  "This guard has to run where the online repositories are configured -- that" \
  "is inside builder/build-iso.sh's container, not on the dev machine."

# awk, not grep: awk exits 0 whether or not it printed, so no caller can
# mistake "matched nothing" for "could not read the file", and a genuinely
# unreadable file still aborts (awk exits non-zero and set -e catches it).
read_list() { awk '!/^[[:space:]]*(#|$)/' "$@"; }

# Membership test that reads its whole input. `... | grep -qx` would be
# shorter, but grep -q exits on the first match, and with `set -o pipefail`
# the writer's SIGPIPE then becomes the pipeline's status -- a spurious
# failure whose likelihood depends on the pipe buffer, i.e. on how big the
# package list happens to be that week.
contains() {
  local needle=$1 line
  while IFS= read -r line; do [[ $line == "$needle" ]] && return 0; done
  return 1
}

mapfile -t pinned < <(read_list "$INSTALL_LIST")
mapfile -t fetched < <(read_list "$FETCH_LIST")

((${#pinned[@]} > 0)) || fail "$INSTALL_LIST contains no package entries"
((${#fetched[@]} > 0)) || fail "$FETCH_LIST contains no package entries"

# ---------------------------------------------------------------------------
# (7) Locally built packages -- T5-fork-plan.md §3 seam S4
#
# These are produced by builder/build-iso.sh itself, straight into the offline
# mirror, and exist in no online repository. This whole script resolves against
# the ONLINE repos, and `pacman -S --print` aborts the entire transaction on a
# single unresolvable target -- so they must come out of the target set, and
# the hole that makes has to be shown to be deliberate.
# ---------------------------------------------------------------------------

# `read -a` on an empty string yields an empty array, which is the "we build
# nothing" case and is legal. Kept as text as well, so membership tests never
# have to expand a possibly-empty array under `set -u`.
local_packages=()
[[ -n ${DECK_LOCAL_PACKAGES:-} ]] && read -r -a local_packages <<<"$DECK_LOCAL_PACKAGES"
local_packages_text=${DECK_LOCAL_PACKAGES:-}
local_packages_text=${local_packages_text// /$'\n'}
pinned_text=$(printf '%s\n' "${pinned[@]}")

# (7a) Every excluded name must be one this ISO actually installs. Excluding a
# name that is in no install list excludes nothing and hides nothing -- it is
# the shape of an exclusion list that has outlived what it was for.
for local_pkg in "${local_packages[@]-}"; do
  [[ -n $local_pkg ]] || continue
  contains "$local_pkg" <<<"$pinned_text" || fail \
    "'$local_pkg' is named in DECK_LOCAL_PACKAGES but is not in $INSTALL_LIST" \
    "This variable exists to excuse a package from the ONLINE resolve because" \
    "we build it ourselves. A name that nothing installs needs no excuse, so" \
    "either add it to the install list or stop excluding it. Silently" \
    "tolerating it would leave a permanent hole in the target set below."
done

# The pins that the negative and positive controls can legitimately use: the
# locally built ones can never appear in an online resolve, so folding them
# into either control would make it assert a falsehood.
online_pinned=()
for entry in "${pinned[@]}"; do
  if contains "$entry" <<<"$local_packages_text"; then continue; fi
  online_pinned+=("$entry")
done
((${#online_pinned[@]} > 0)) || fail \
  "every entry in $INSTALL_LIST is a locally built package" \
  "The negative control below removes the online pins to prove the matcher can" \
  "fire; with none left to remove it would compare a set against itself and" \
  "pass for the wrong reason."

# deck-install.packages is resolved against the single-repo offline mirror
# twice (resolve_expected_packages, and pacstrap at install time), so a
# repo-qualified name there aborts both. Catch it here rather than 40 minutes
# later.
for entry in "${pinned[@]}"; do
  [[ $entry != */* ]] || fail \
    "'$entry' in $INSTALL_LIST is repo-qualified" \
    "Entries in this list are resolved against configs/pacman-offline.conf," \
    "which declares one repo ([offline]); 'repo/name' aborts that resolve and" \
    "would fail pacstrap the same way. Put repo-qualified names in" \
    "deck-mirror.packages, which is only ever resolved online."
done

# The pins are read from $INSTALL_LIST but the target set is read from the
# already-merged $BASE_PACKAGES. If those two ever disagree, the negative
# control removes names that were never in the transaction and its result is
# meaningless -- exactly the desync T5-fork-plan.md §3 seam S1 exists to
# prevent. Prove they agree rather than assuming the merge ran.
shipped_base=$(read_list "$BASE_PACKAGES")
for entry in "${pinned[@]}"; do
  contains "$entry" <<<"$shipped_base" || fail \
    "'$entry' is in $INSTALL_LIST but not in the shipped $BASE_PACKAGES" \
    "The seam S1 merge did not run, ran against a different list, or ran after" \
    "the shipped copy was made. Everything below this point would be measuring" \
    "a package set the ISO does not actually install."
done

# ---------------------------------------------------------------------------
# The resolve
# ---------------------------------------------------------------------------

DRY_ROOT=${DECK_NVIDIA_DRYRUN_ROOT:-/tmp/omarchy-deck-nvidia-dryrun}
rm -rf "$DRY_ROOT"
mkdir -p "$DRY_ROOT/var/lib/pacman"

pac() {
  pacman --config "$PACMAN_CONF" --root "$DRY_ROOT" \
    --dbpath "$DRY_ROOT/var/lib/pacman" --noconfirm "$@"
}

# An empty --root is the point: it makes pacman resolve the whole set from
# nothing, which is the question pacstrap asks. Against the container's own
# installed database, anything already present would be silently dropped from
# the answer.
resolve() { pac -S --print --print-format '%n' "$@" | sort -u; }

# `nvidia` appears in the middle of names too (lib32-nvidia-utils,
# libva-nvidia-driver), hence the (^|-)…($|-) anchors rather than a prefix
# match. The egl-* alternation is the userspace NVIDIA drags in; egl-wayland2
# is real and §3.8's list omitted it.
nvidia_matches() {
  awk -v exceptions="${NVIDIA_EXCEPTIONS[*]}" '
    BEGIN { n = split(exceptions, e, " "); for (i = 1; i <= n; i++) skip[e[i]] = 1 }
    $0 in skip { next }
    /(^|-)nvidia($|-)/ || /^egl-(gbm|wayland[0-9]*|x11)$/ { print }
  '
}

log "syncing package databases into $DRY_ROOT"
pac -Sy >/dev/null || fail \
  "could not sync the package databases for the dry run" \
  "config: $PACMAN_CONF"

mapfile -t assembled_targets < <(
  {
    read_list "$ARCHINSTALL_PACKAGES" "$BASE_PACKAGES" "$FETCH_LIST"
    if ((${#EXTRA_TARGETS[@]} > 0)); then printf '%s\n' "${EXTRA_TARGETS[@]}"; fi
  } | sort -u
)
((${#assembled_targets[@]} > 0)) || fail "assembled an empty target list"

# (7b) Drop the locally built names, and CHECK THE ARITHMETIC. Removing them is
# the only way this resolve can run at all, but a silent removal would also
# hide the case where one of them fell out of the shipped package lists
# entirely -- which is the failure that ends with the ISO carrying a package
# nothing installs. The count is the proof that the exclusion did work rather
# than that there was nothing to exclude.
#
# ⚠️ Stated honestly about what it can and cannot catch. No INPUT can make this
# fire on its own: $BASE_PACKAGES is both the list the shipped-base agreement
# check above reads and one of the files the target set is assembled from, so a
# name that passed (7a) and that check is necessarily in $assembled_targets.
# What it does catch, measured by mutation: a broken exclusion LOOP -- delete
# the filter below and this line is what notices, before anything downstream
# resolves a package no repo has. The end-to-end proof that the exclusion
# reached pacman lives in test/unit/test-deck-nvidia-dry-run.sh, which reads
# the resolve's actual argument list rather than this script's own account.
targets=()
for entry in "${assembled_targets[@]}"; do
  if contains "$entry" <<<"$local_packages_text"; then continue; fi
  targets+=("$entry")
done
excluded_count=$((${#assembled_targets[@]} - ${#targets[@]}))
((excluded_count == ${#local_packages[@]})) || fail \
  "excluding DECK_LOCAL_PACKAGES removed $excluded_count target(s), expected ${#local_packages[@]}" \
  "Names: ${DECK_LOCAL_PACKAGES:-<none>}" \
  "Every locally built package must be IN the assembled target set before it is" \
  "taken out -- it reaches that set through deck-install.packages, merged into" \
  "the shipped omarchy-base.packages by seam S1. A count that is short means" \
  "the name is not really being installed, so excluding it from this resolve" \
  "would be hiding a target that does not exist rather than one we build."
((${#targets[@]} > 0)) || fail "the target list is empty after the seam-S4 exclusion"
if ((excluded_count > 0)); then
  log "excluded ${excluded_count} locally built package(s) from the online resolve: ${DECK_LOCAL_PACKAGES:-}"
fi

log "dry run over ${#targets[@]} targets (installed set + ${fetched[*]})"

# ---------------------------------------------------------------------------
# (6) NEGATIVE CONTROL FIRST -- establish that the matcher can fire at all
#     before any passing result from it is believed.
# ---------------------------------------------------------------------------

# online_pinned, not pinned: the locally built names are already gone from
# $targets, so asking to remove them again would make the arithmetic below
# short by exactly the number of them and fail for a reason that is not real.
mapfile -t control_targets < <(
  awk 'NR == FNR { drop[$0] = 1; next } !($0 in drop)' \
    <(printf '%s\n' "${online_pinned[@]}") <(printf '%s\n' "${targets[@]}")
)
((${#control_targets[@]} == ${#targets[@]} - ${#online_pinned[@]})) || fail \
  "the negative control removed ${#targets[@]} - ${#control_targets[@]} targets, expected ${#online_pinned[@]}" \
  "Every non-locally-built entry in $INSTALL_LIST must appear in the assembled" \
  "target list, or the control is not testing the thing the real assertion" \
  "depends on."

if ! control=$(resolve "${control_targets[@]}"); then
  fail "the negative control's resolve failed" \
    "It uses the same targets as the real assertion minus ${online_pinned[*]}," \
    "so this is not a control-only problem."
fi
control_hits=$(printf '%s\n' "$control" | nvidia_matches)
if [[ -z $control_hits ]]; then
  fail \
    "the NEGATIVE CONTROL did not fire" \
    "Resolving the same targets WITHOUT ${online_pinned[*]} is supposed to make pacman" \
    "satisfy steam's virtual vulkan-driver / lib32-vulkan-driver dependencies" \
    "with the NVIDIA stack (docs/PROGRESS.md §3.8, measured 2026-08-12:" \
    "egl-gbm egl-wayland egl-wayland2 egl-x11 lib32-nvidia-utils nvidia-utils)." \
    "It did not. Either this matcher no longer matches anything, upstream" \
    "changed the default provider, or something else in the target set now" \
    "provides lib32-vulkan-driver on its own." \
    "Either way the assertion below would pass without proving anything, so" \
    "this build stops instead of shipping a guard that cannot fail."
fi
log "negative control fired as designed: $(printf '%s' "$control_hits" | tr '\n' ' ')"

# ---------------------------------------------------------------------------
# The assertion
# ---------------------------------------------------------------------------

# (2) A failed resolve must never look like a clean one.
if ! resolved=$(resolve "${targets[@]}"); then
  fail \
    "could not resolve the Steam Deck target package set" \
    "pacman -S --print aborts the entire transaction when any single target is" \
    "missing, so this is the same failure pacstrap -- and the first-boot" \
    "'pacman -S steam' -- would hit. It is NOT 'no NVIDIA packages found'."
fi

# (3) A resolve that came back nearly empty is a broken resolve, not a clean one.
resolved_count=$(printf '%s\n' "$resolved" | wc -l)
((resolved_count >= MIN_CLOSURE)) || fail \
  "the dry run resolved only $resolved_count packages (expected >= $MIN_CLOSURE)" \
  "A closure this small is not a Steam Deck install, so any statement about" \
  "its NVIDIA content is meaningless."

# (4) POSITIVE CONTROL: the packages we asked about by name must be in the answer.
#
# online_pinned rather than pinned -- and that is a NARROWING, not a widening.
# The locally built names were never asked about here (they cannot be, they are
# in no online repo), so demanding their presence would be a control nobody can
# satisfy; but they are not simply dropped either. They get the mirror-image
# assertion immediately below, and the exclusion that removed them was already
# proved deliberate by (7a)/(7b) above.
for probe in "${online_pinned[@]}" "${fetched[@]}"; do
  contains "$probe" <<<"$resolved" || fail \
    "'$probe' was a target but is not in the $resolved_count-package result" \
    "The dry run did not ask the question this guard claims it asked."
done

# (7c) The mirror image, for the names (4) can no longer cover: a package we
# build ourselves must NOT resolve out of the online repositories. If one does,
# the name collides with a real published package, and every later step --
# `pacman -Syw`, the prune keep-set, pacstrap -- would be silently choosing
# between two different packages with one name.
for local_pkg in "${local_packages[@]-}"; do
  [[ -n $local_pkg ]] || continue
  if contains "$local_pkg" <<<"$resolved"; then fail \
    "'$local_pkg' is supposed to be built by this ISO, but it RESOLVES ONLINE" \
    "A locally built package name that also exists in a configured online" \
    "repository is a collision: pacman -Syw would download the other one, the" \
    "prune keep-set would then hold two files for one name, and which of them" \
    "pacstrap installs on the target is not something this build decides." \
    "Rename our package, or stop building it."
  fi
done

# (5) The exception must still be needed. An exception that no longer matches
#     anything is dead weight that will quietly widen the next time someone
#     edits this file.
for exception in "${NVIDIA_EXCEPTIONS[@]}"; do
  contains "$exception" <<<"$resolved" || fail \
    "the accepted exception '$exception' is no longer in the resolved set" \
    "It was accepted because the linux-firmware meta-package pulls it in and it" \
    "is firmware, not a driver. If that is no longer true, DELETE it from" \
    "NVIDIA_EXCEPTIONS rather than leaving a stale hole in the matcher."
done

found=$(printf '%s\n' "$resolved" | nvidia_matches)
if [[ -n $found ]]; then
  fail \
    "the Steam Deck target set resolves NVIDIA driver packages" \
    "$(printf '%s' "$found" | tr '\n' ' ')" \
    "" \
    "docs/PROGRESS.md §3.8: steam depends on the virtual vulkan-driver and" \
    "lib32-vulkan-driver; with no AMD provider named, pacman picks the NVIDIA" \
    "stack and nothing errors. Fix by naming the providers in" \
    "$INSTALL_LIST -- BOTH vulkan-radeon and lib32-vulkan-radeon; the 32-bit" \
    "one alone leaves nvidia-utils and the egl-* set behind." \
    "" \
    "If one of these is genuinely acceptable, add it to NVIDIA_EXCEPTIONS in" \
    "this script WITH the reason -- do not widen the pattern."
fi

log "OK: $resolved_count packages resolved, 0 NVIDIA driver packages"
log "    accepted by exception: ${NVIDIA_EXCEPTIONS[*]}"
