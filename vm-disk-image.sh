#!/usr/bin/env bash
# Library: read a GPT partition table and pull partitions out of a raw disk
# image, all without root, a loop device, or mounting.
#
# Works directly on regular files: `sfdisk --json`/`parted` read plain files
# fine, `mtools ... -i img@@offset` reads FAT partitions by byte offset
# without mounting, and `dd` carves the btrfs root partition out to its own
# file for `btrfs restore` to read. Verified rootless on this dev machine
# before writing this (no `losetup`/`qemu-nbd`/sudo available here).
#
# Not meant to be run directly — source it.

set -uo pipefail

# GPT partition type GUIDs (systemd-id128 / UEFI spec well-known values).
readonly DISK_IMAGE_ESP_TYPE_GUID="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"

# disk_image::partition_json <disk> — sfdisk's JSON partition table.
disk_image::partition_json() {
  local disk=$1
  sfdisk --json "$disk"
}

# disk_image::sector_size <disk>
disk_image::sector_size() {
  local disk=$1
  disk_image::partition_json "$disk" | jq -r '.partitiontable.sectorsize'
}

# disk_image::esp_offset <disk> — byte offset of the ESP, for mtools '@@'.
# Fails loudly (empty stdout, exit 1) if no ESP-typed partition exists,
# rather than guessing a partition index.
disk_image::esp_offset() {
  local disk=$1 table sector_size start
  table=$(disk_image::partition_json "$disk")
  sector_size=$(jq -r '.partitiontable.sectorsize' <<<"$table")
  start=$(jq -r --arg t "$DISK_IMAGE_ESP_TYPE_GUID" \
    '.partitiontable.partitions[] | select((.type // "" ) | ascii_downcase == $t) | .start' \
    <<<"$table")
  [[ -n $start ]] || { echo "disk_image::esp_offset: no ESP-typed partition found on $disk" >&2; return 1; }
  echo $((start * sector_size))
}

# disk_image::root_partition <disk> — "start_bytes size_bytes" of the root
# filesystem partition. Assumes exactly the two-partition layout this
# project's installer produces (ESP + one root partition, PLAN.md §6.1a):
# "root" is whichever partition isn't ESP-typed. Fails loudly if that
# assumption doesn't hold (zero or more than one non-ESP partition) rather
# than silently picking the wrong one.
disk_image::root_partition() {
  local disk=$1 table sector_size non_esp count start size
  table=$(disk_image::partition_json "$disk")
  sector_size=$(jq -r '.partitiontable.sectorsize' <<<"$table")
  non_esp=$(jq -c --arg t "$DISK_IMAGE_ESP_TYPE_GUID" \
    '[.partitiontable.partitions[] | select((.type // "") | ascii_downcase != $t)]' \
    <<<"$table")
  count=$(jq 'length' <<<"$non_esp")
  if [[ $count -ne 1 ]]; then
    echo "disk_image::root_partition: expected exactly 1 non-ESP partition on $disk, found $count" >&2
    return 1
  fi
  start=$(jq -r '.[0].start' <<<"$non_esp")
  size=$(jq -r '.[0].size' <<<"$non_esp")
  echo "$((start * sector_size)) $((size * sector_size))"
}

# disk_image::extract <disk> <start_bytes> <size_bytes> <dest_file>
# Carves a byte range out of $disk into its own file via dd. Used to pull
# the btrfs root partition out so `btrfs restore` can read it standalone
# (btrfs superblock detection needs to see the partition's own byte 0, not
# an offset into a larger disk).
disk_image::extract() {
  local disk=$1 start=$2 size=$3 dest=$4
  dd if="$disk" of="$dest" bs=1MiB skip=$((start / 1048576)) \
    count=$(((size + 1048575) / 1048576)) status=none 2>/dev/null || {
    # Fall back to byte-exact (slow) dd if start/size aren't 1MiB-aligned.
    dd if="$disk" of="$dest" bs=512 skip=$((start / 512)) \
      count=$((size / 512)) status=none
  }
}

# disk_image::esp_list <disk> [mtools-path] — list files under a path on
# the ESP (default root) without mounting.
disk_image::esp_list() {
  local disk=$1 path=${2:-::}
  local offset
  offset=$(disk_image::esp_offset "$disk") || return 1
  MTOOLS_SKIP_CHECK=1 mdir -b -i "${disk}@@${offset}" "$path" 2>/dev/null
}

# disk_image::esp_read <disk> <path> <dest_file> — copy one file off the
# ESP without mounting.
disk_image::esp_read() {
  local disk=$1 path=$2 dest=$3
  local offset
  offset=$(disk_image::esp_offset "$disk") || return 1
  MTOOLS_SKIP_CHECK=1 mcopy -i "${disk}@@${offset}" "::${path}" "$dest"
}
