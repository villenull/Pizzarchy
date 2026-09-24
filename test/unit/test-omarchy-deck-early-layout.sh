#!/usr/bin/env bash
# Unit tests for omarchy-deck-early's partition arithmetic (deck_early_layout).
#
# Why this suite exists: the first hardware install of the v2 ISO failed on
# every variant with archinstall's "Partition is misaligned"
# (docs/findings/HW-INSTALL-FEEDBACK-2026-09-24.md). archinstall 4.4 refuses
# any created partition whose start or LENGTH is not a whole MiB
# (lib/models/device.py:214). The early layout sized root as
# "disk - 2 GiB - 2 MiB", and a real drive is not a whole number of MiB. QEMU
# never caught it because every test disk is a round size. So this suite
# feeds REAL drive byte counts, not round ones.
#
# No VM, no root, no disks. Seconds.
set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
EARLY_SH="$REPO_ROOT/iso/overlay/configs/airootfs/usr/local/bin/omarchy-deck-early"

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; [[ -n ${2:-} ]] && printf '%s\n' "$2" >&2; exit 1; }

# The script dispatches on source (see test-omarchy-deck-early-gate.sh), so
# extract the function verbatim instead.
layout_src=$(sed -n '/^deck_early_layout() {$/,/^}$/p' "$EARLY_SH")
[[ -n $layout_src ]] || fail "could not extract deck_early_layout from $EARLY_SH"
eval "$layout_src"

# render_early_config must actually use it -- a correct helper nobody calls
# is how this project's QEMU runs passed while hardware failed.
render_src=$(sed -n '/^render_early_config() {$/,/^}$/p' "$EARLY_SH")
# shellcheck disable=SC2016 # a literal: the call as written in the source
LC_ALL=C grep -qF 'deck_early_layout "$disk_bytes"' <<<"$render_src" ||
  fail "render_early_config must take its layout from deck_early_layout"
pass "render_early_config sizes its partitions through deck_early_layout"

MIB=1048576

# archinstall's own rule, restated: start and length whole MiB, no overlap,
# and root must end at least 1 MiB before the disk end (GPT backup header).
archinstall_accepts() {
  local disk_bytes=$1 bs bz rs rz
  read -r bs bz rs rz < <(deck_early_layout "$disk_bytes")
  (( bs % MIB == 0 && bz % MIB == 0 && rs % MIB == 0 && rz % MIB == 0 )) || return 1
  (( rs >= bs + bz )) || return 1
  (( rz > 0 )) || return 1
  (( rs + rz <= disk_bytes - MIB )) || return 1
}

# Real byte counts (sectors x 512). None is a whole number of MiB.
declare -A disks=(
  ["1 TB NVMe (1953525168 sectors, Deck OLED 1TB class)"]=1000204886016
  ["512 GB NVMe (1000215216 sectors, Deck OLED 512GB class)"]=512110190592
  ["256 GB NVMe (500118192 sectors)"]=256060514304
  ["128 GB microSD (249737216 sectors)"]=127865454592
  ["64 GiB QEMU disk (round, the size that hid the bug)"]=68719476736
)
for name in "${!disks[@]}"; do
  bytes=${disks[$name]}
  archinstall_accepts "$bytes" ||
    fail "layout for $name must pass archinstall's alignment rule" "$(deck_early_layout "$bytes")"
done
pass "every real drive size yields a MiB-aligned, non-overlapping layout that leaves the GPT backup MiB free"

# Negative control: the premise. At least one of those real sizes really is
# not a whole MiB, and the OLD formula really produced a misaligned root on it.
# Without this, the loop above could pass on sizes that never exercised the bug.
old_root_size() { echo $(( $1 - (MIB + 2048 * MIB) - MIB )); }
(( 1000204886016 % MIB != 0 )) || fail "premise: the 1 TB test size must not be a whole MiB"
(( $(old_root_size 1000204886016) % MIB != 0 )) ||
  fail "premise: the pre-fix formula must be misaligned on a real 1 TB drive"
pass "negative control: the pre-fix formula is misaligned on a real 1 TB drive, so this suite would have caught it"

# Boot partition is unchanged: 1 MiB start, 2 GiB, root right behind it.
read -r bs bz rs _ < <(deck_early_layout 1000204886016)
[[ $bs == "$MIB" && $bz == $((2048 * MIB)) && $rs == $((MIB + 2048 * MIB)) ]] ||
  fail "the ESP must stay 1 MiB in and 2 GiB long, root immediately after" "$bs $bz $rs"
pass "ESP stays at 1 MiB / 2 GiB; root starts immediately after it"

# Too small still reports a non-positive root, which render_early_config
# turns into a loud failure.
read -r _ _ _ rz < <(deck_early_layout $((1024 * MIB)))
(( rz <= 0 )) || fail "a 1 GiB disk must leave no room for root" "$rz"
pass "a disk too small for the ESP yields a non-positive root size (render_early_config refuses it)"
