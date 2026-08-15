#!/usr/bin/env bash
# vm-outcome-assert.sh -- run the OUTCOME assertions against artifacts that
# already exist. No QEMU, no install, no waiting.
#
# Usage: ./vm-outcome-assert.sh <iso-path> <installed-disk-image> [work-dir]
#
#   <iso-path>              the live ISO the install came from (.iso)
#   <installed-disk-image>  the target disk AFTER a completed install, either
#                           a raw image or a qcow2 (converted here)
#
# Env:
#   VM_KEEP_WORK=1          keep the work dir even on success
#   VM_OUTCOME_SKIP_ISO=1   skip the live-ISO half (when only a disk is to hand)
#   VM_OUTCOME_SKIP_DISK=1  skip the installed-image half
#
# ===========================================================================
# WHY THIS IS A SEPARATE ENTRY POINT
# ===========================================================================
#
# test/vm/vm-install-controller-test.sh runs the same assertions -- it sources
# the same library, there is one implementation -- but it takes 20+ minutes
# because it drives a real controller-only install first. That is the right
# shape for proving an install works and the wrong shape for two things this
# file exists for:
#
#   1. PROVING AN ASSERTION FIRES. An outcome assertion that has never been
#      seen to fail is a decoration. Pointed at a known-bad image (the
#      2026-08-15 build: no steam, no steamdeck-dsp, stock linux, no session
#      shims, no mapper in the live ISO) every check here should go red, and
#      that takes seconds rather than a QEMU run.
#   2. RE-CHECKING AFTER A FIX without re-installing. The install harness
#      keeps its work dir under VM_KEEP_WORK=1; target.raw and the ISO are
#      all this needs.
#
# Everything it reads is read ROOTLESS: udisksctl loop-mounts the btrfs root
# read-only (the model test/lib/vm-disk-image.sh already established and
# proved against a real install), mtools reads the ESP by byte offset without
# mounting, and the ISO's squashfs is listed in place, never extracted.
# ===========================================================================

set -uo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

# shellcheck source=../lib/vm-installer-screens.sh
source "$REPO_ROOT/test/lib/vm-installer-screens.sh"
# shellcheck source=../lib/vm-disk-image.sh
source "$REPO_ROOT/test/lib/vm-disk-image.sh"
# shellcheck source=../lib/vm-assertions.sh
source "$REPO_ROOT/test/lib/vm-assertions.sh"
# shellcheck source=../lib/vm-outcome-assertions.sh
source "$REPO_ROOT/test/lib/vm-outcome-assertions.sh"

ISO=${1:?"usage: $0 <iso-path> <installed-disk-image> [work-dir]"}
DISK=${2:?"usage: $0 <iso-path> <installed-disk-image> [work-dir]"}
WORK=${3:-$(mktemp -d /var/tmp/vm-outcome-assert.XXXXXX)}
mkdir -p "$WORK"

SKIP_ISO=${VM_OUTCOME_SKIP_ISO:-0}
SKIP_DISK=${VM_OUTCOME_SKIP_DISK:-0}

log() { printf '[vm-outcome-assert] %s\n' "$*" >&2; }
fail() { log "FAIL: $*"; exit 1; }

[[ $SKIP_ISO == 1 || -f $ISO ]] || fail "ISO not found: $ISO"
[[ $SKIP_DISK == 1 || -f $DISK ]] || fail "installed disk image not found: $DISK"
for tool in jq sfdisk mdir mcopy udisksctl; do
  command -v "$tool" >/dev/null || fail "required tool '$tool' not found"
done

# ---------------------------------------------------------------------------
# SELF-TEST -- the positive control, and the only one available before the
# fetch/session/shim work lands.
#
# ⚠️ WHY IT IS HERE. Every assertion in this file was written against a
# known-BAD image and every one of them fired. That proves they can fail. It
# does not prove they can pass -- and an assertion that can only fail is a
# wall, not a check: the first person to meet it assumes it is broken and
# deletes it. Until a good image exists there is nothing to point them at, so
# the pass path is proved against synthetic roots instead, in a second, with
# no VM.
#
#   VM_OUTCOME_SELFTEST=1 ./vm-outcome-assert.sh <iso|-> -
#
# The bad root deliberately carries linux-api-headers and linux-firmware and
# NOT stock linux, because that is the trap: a glob-based package check
# (`linux-*`, which test/lib/vm-assertions.sh's assert::packages_present uses)
# reports stock linux as installed on a machine that does not have it, and can
# never answer the absence question at all.
# ---------------------------------------------------------------------------

outcome_selftest_root() {
  local dir=$1 flavour=$2 db pkg i
  db="$dir/var/lib/pacman/local"
  mkdir -p "$db"
  # Filler, so the "the db was really read" anti-vacuity control has a real
  # denominator rather than being satisfied by the handful of names below.
  for ((i = 0; i < 120; i++)); do
    mkdir -p "$db/filler$i-1.0-1"
    : >"$db/filler$i-1.0-1/desc"
  done
  # The prefix trap, in both roots.
  for pkg in linux-api-headers-7.1-1 linux-firmware-20260810-1 \
    steamdeck-dsp-1.0-1 linux-neptune-611-6.11.11-1 gamescope-3.16.25-3 \
    omarchy-deck-0.2.0-1; do
    mkdir -p "$db/$pkg"
    : >"$db/$pkg/desc"
  done
  if [[ $flavour == good ]]; then
    mkdir -p "$db/steam-1.0.0.87-1"
    : >"$db/steam-1.0.0.87-1/desc"
    for pkg in \
      usr/lib/steam/bootstraplinux_ubuntu12_32.tar.xz \
      usr/bin/steamos-session-select \
      usr/bin/steamos-polkit-helpers/steamos-update \
      usr/bin/steamos-polkit-helpers/steamos-priv-write \
      usr/local/bin/deck-input-mapper \
      usr/share/wayland-sessions/gamescope-wayland.desktop; do
      mkdir -p "$dir/$(dirname -- "$pkg")"
      : >"$dir/$pkg"
    done
  else
    # The 2026-08-15 image's actual shape: stock linux, no steam, no shims.
    mkdir -p "$db/linux-7.1.8.arch1-3"
    : >"$db/linux-7.1.8.arch1-3/desc"
  fi
}

if [[ ${VM_OUTCOME_SELFTEST:-0} == 1 ]]; then
  log "--- SELF-TEST: the assertions must PASS on a good root and FAIL on a bad one ---"
  selftest_status=0

  outcome_selftest_root "$WORK/selftest-good" good
  before_total=$SCREENS_CHECKS_TOTAL before_passed=$SCREENS_CHECKS_PASSED
  outcome::check_installed_root "$WORK/selftest-good" "$REPO_ROOT" \
    "omarchy_linux-neptune-611.efi" >/dev/null 2>&1
  good_total=$((SCREENS_CHECKS_TOTAL - before_total))
  good_failed=$((good_total - (SCREENS_CHECKS_PASSED - before_passed)))

  outcome_selftest_root "$WORK/selftest-bad" bad
  before_total=$SCREENS_CHECKS_TOTAL before_passed=$SCREENS_CHECKS_PASSED
  outcome::check_installed_root "$WORK/selftest-bad" "$REPO_ROOT" \
    omarchy_linux.efi omarchy_linux-neptune-611.efi >/dev/null 2>&1
  bad_total=$((SCREENS_CHECKS_TOTAL - before_total))
  bad_failed=$((bad_total - (SCREENS_CHECKS_PASSED - before_passed)))

  # The counters above were incremented by the two synthetic runs; they are
  # not results anybody should read, so put them back before the real run.
  SCREENS_CHECKS_TOTAL=0
  SCREENS_CHECKS_PASSED=0

  if (( good_total >= 14 && good_failed == 0 )); then
    log "ok   the outcome assertions PASS on a synthetic good root ($good_total checks, 0 failures)"
  else
    log "FAIL the outcome assertions must pass on a good root ($good_failed of $good_total failed) -- an assertion that can only fail is a wall, not a check"
    selftest_status=1
  fi
  # 8 = 2 packages (steam, stock linux present) + 6 files. The UKI pair is
  # extra on top; a floor, not an equality, so adding a check cannot fail this.
  if (( bad_failed >= 8 )); then
    log "ok   the outcome assertions FIRE on a synthetic bad root ($bad_failed of $bad_total failed)"
  else
    log "FAIL the outcome assertions must fire on the 2026-08-15 shape (only $bad_failed of $bad_total failed)"
    selftest_status=1
  fi
  if (( selftest_status != 0 )); then
    log "SELF-TEST FAILED -- not running the real assertions against real artifacts"
    exit 1
  fi
  log "--- SELF-TEST passed; running the real assertions ---"
fi

log "iso:  $ISO"
log "disk: $DISK"
log "work: $WORK"

# ---------------------------------------------------------------------------
# The installed image
# ---------------------------------------------------------------------------

disk_checks_run=0
if [[ $SKIP_DISK == 1 ]]; then
  log "--- installed-image assertions SKIPPED (VM_OUTCOME_SKIP_DISK=1) ---"
else
  log "--- installed-image assertions -------------------------------------"

  # Accept either a whole disk (GPT: ESP + root) or an already-extracted root
  # partition. Which one it is, is DISCOVERED -- sfdisk either finds a
  # partition table or it does not -- because being handed root.raw and
  # treating it as a whole disk produces a confusing "no ESP" instead of the
  # package results the caller wanted.
  target_raw="$WORK/target.raw"
  if [[ $DISK == *.qcow2 ]]; then
    log "converting qcow2 -> raw"
    command -v qemu-img >/dev/null || fail "qemu-img is needed to read a qcow2"
    qemu-img convert -O raw "$DISK" "$target_raw" || fail "qemu-img convert failed"
  else
    target_raw=$DISK
  fi

  root_raw=""
  uki_names=()
  if sfdisk --json "$target_raw" >/dev/null 2>&1; then
    log "whole-disk image: reading the ESP and carving the root partition out"
    uki_dir="$WORK/extracted-ukis"
    disk_image::esp_extract_ukis "$target_raw" "$uki_dir"
    while IFS= read -r -d '' f; do uki_names+=("$(basename "$f")"); done \
      < <(find "$uki_dir" -maxdepth 1 -iname '*.efi' -print0 2>/dev/null | sort -z)
    log "discovered UKI(s): ${uki_names[*]:-<none>}"

    root_raw="$WORK/root.raw"
    disk_image::root_extract "$target_raw" "$root_raw" ||
      fail "could not carve the root partition out of $target_raw"
  else
    log "no partition table: treating $target_raw as an already-extracted root partition"
    log "⚠️  the ESP/UKI checks cannot run against a bare root partition and will be reported as failures, not skipped"
    root_raw=$target_raw
  fi

  if read -r root_loop root_at < <(disk_image::root_mount "$root_raw"); then
    log "root mounted at $root_at"
    outcome::check_installed_root "$root_at" "$REPO_ROOT" ${uki_names[@]+"${uki_names[@]}"}
    disk_image::root_unmount "$root_loop"
    disk_checks_run=1
  else
    screens::check "the installed root partition could be mounted for inspection" FAIL ok
  fi
fi

# ---------------------------------------------------------------------------
# The live ISO
# ---------------------------------------------------------------------------

iso_checks_run=0
if [[ $SKIP_ISO == 1 ]]; then
  log "--- live-ISO assertions SKIPPED (VM_OUTCOME_SKIP_ISO=1) ---"
else
  log "--- live-ISO assertions --------------------------------------------"
  outcome::check_live_iso "$ISO" "$REPO_ROOT"
  iso_checks_run=1
fi

log "======================================================================="
screens::denominator
log "======================================================================="

status=0
if (( SCREENS_CHECKS_TOTAL == 0 )); then
  log "FAILED: zero checks ran. A run that checked nothing is not a pass."
  status=1
elif (( SCREENS_CHECKS_PASSED == SCREENS_CHECKS_TOTAL )); then
  log "PASS -- every outcome assertion holds (disk=$disk_checks_run iso=$iso_checks_run)."
  [[ ${VM_KEEP_WORK:-0} == 1 ]] || rm -rf "$WORK"
else
  log "FAILED -- $((SCREENS_CHECKS_TOTAL - SCREENS_CHECKS_PASSED)) outcome assertion(s) do not hold. Work dir kept: $WORK"
  status=1
fi

exit $status
