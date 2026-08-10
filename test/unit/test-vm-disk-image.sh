#!/usr/bin/env bash
# Unit tests for vm-disk-image.sh. Builds small GPT+FAT32+btrfs raw images
# by hand (parted/mkfs.vfat/mkfs.btrfs all operate on plain files — no
# loop device, no root, verified interactively before writing this suite)
# so these run on a bare dev machine with no VM, no ISO, and no sudo.

set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

# shellcheck source=../lib/vm-disk-image.sh
source "$REPO_ROOT/test/lib/vm-disk-image.sh"

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; [[ -n ${2:-} ]] && printf '%s\n' "$2" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# --- fixture: ESP + btrfs root, matching this project's expected layout ---
disk="$work/disk.raw"
truncate -s 200M "$disk"
parted --script "$disk" mklabel gpt \
  mkpart ESP fat32 1MiB 65MiB set 1 esp on \
  mkpart root btrfs 65MiB 100% >/dev/null
# parted only writes the partition table entry — the ESP still needs an
# actual FAT filesystem before mtools can address it.
mkfs.vfat -n ESP "$disk" --offset 2048 >/dev/null

esp_offset=$(disk_image::esp_offset "$disk") || fail "esp_offset finds the ESP" "expected success, got exit $?"
[[ $esp_offset -eq 1048576 ]] || fail "esp_offset returns the right byte offset" "got $esp_offset, expected 1048576"
pass "esp_offset finds the ESP and returns its byte offset"

read -r root_start root_size < <(disk_image::root_partition "$disk") || fail "root_partition finds the root partition"
[[ $root_start -gt $esp_offset ]] || fail "root_partition starts after the ESP"
[[ $root_size -gt 0 ]] || fail "root_partition has nonzero size"
pass "root_partition finds exactly one non-ESP partition"

extracted="$work/root.raw"
disk_image::extract "$disk" "$root_start" "$root_size" "$extracted"
[[ -f $extracted ]] || fail "extract wrote a file"
extracted_size=$(stat -c%s "$extracted")
# dd may round up to whole MiB blocks; extracted must be at least root_size.
[[ $extracted_size -ge $root_size ]] || fail "extract produced a file at least as large as the partition" "extracted=$extracted_size want>=$root_size"
pass "extract carves the root partition out to its own file"

mkfs.btrfs -f -q "$extracted" >/dev/null 2>&1 || fail "extracted root partition accepts mkfs.btrfs (sanity: it's really a standalone filesystem-sized file)"
pass "extracted partition is a valid standalone filesystem target"

# --- ESP read/write via mtools offset ---
echo "unit test payload" >"$work/payload.efi"
MTOOLS_SKIP_CHECK=1 mcopy -i "${disk}@@${esp_offset}" "$work/payload.efi" ::/payload.efi
listing=$(disk_image::esp_list "$disk")
grep -q "payload" <<<"$listing" || fail "esp_list sees a file written via mtools" "$listing"
pass "esp_list lists files written to the ESP"

disk_image::esp_read "$disk" /payload.efi "$work/payload-readback.efi"
diff -q "$work/payload.efi" "$work/payload-readback.efi" >/dev/null || fail "esp_read round-trips file content"
pass "esp_read copies a file off the ESP unmodified"

# --- failure modes: must fail loudly, not silently pick the wrong partition ---
no_esp_disk="$work/no-esp.raw"
truncate -s 100M "$no_esp_disk"
parted --script "$no_esp_disk" mklabel gpt mkpart root btrfs 1MiB 100% >/dev/null
if disk_image::esp_offset "$no_esp_disk" >/dev/null 2>&1; then
  fail "esp_offset fails loudly when there's no ESP-typed partition"
fi
pass "esp_offset fails (not silently) when there's no ESP"

two_root_disk="$work/two-root.raw"
truncate -s 200M "$two_root_disk"
parted --script "$two_root_disk" mklabel gpt \
  mkpart ESP fat32 1MiB 65MiB set 1 esp on \
  mkpart root1 btrfs 65MiB 130MiB \
  mkpart root2 btrfs 130MiB 100% >/dev/null
if disk_image::root_partition "$two_root_disk" >/dev/null 2>&1; then
  fail "root_partition fails loudly on an unexpected multi-partition layout, rather than guessing"
fi
pass "root_partition refuses to guess when the layout doesn't match the expected two-partition shape"

echo "all vm-disk-image.sh tests passed"
