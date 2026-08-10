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

# disk_image::root_mount <root-raw-file>
# Mounts the extracted root partition via `udisksctl loop-setup` + `mount`
# — a real kernel mount, rootless (confirmed working on this dev machine:
# no sudo/polkit prompt for a read-only loop-setup + mount of a regular
# file, session 2). Prints "<loop-dev> <path-to-@-subvolume>" on success.
#
# This replaced an earlier `btrfs restore` (userspace recovery tool)
# approach that looked correct in unit tests against small fixtures but
# broke on a real install: `btrfs restore` errors on zstd-compressed
# extents ("zstd frame incomplete") and — worse — silently stops walking
# the rest of the tree after that error instead of failing loudly, so it
# never reached /etc or /var/lib/pacman/local at all (PLAN.md §8.1's exact
# failure mode: a tool that looks like it worked while doing nothing).
# Confirmed against a real disk from a real install (session 2) before
# relying on it, same as every other extraction function in this file.
#
# "@" is this project's own root-subvolume name (vm-cidata.sh's layout,
# matching the configurator's own template) — not a btrfs universal, so
# this only works against images this project's own cidata config built.
disk_image::root_mount() {
  local root_raw=$1
  local loop_line loop_dev mount_line mount_point

  loop_line=$(udisksctl loop-setup -r -f "$root_raw" 2>&1) || {
    echo "disk_image::root_mount: loop-setup failed: $loop_line" >&2
    return 1
  }
  loop_dev=$(grep -oP '(?<=as )/dev/loop[0-9]+' <<<"$loop_line")
  [[ -n $loop_dev ]] || {
    echo "disk_image::root_mount: could not parse loop device from: $loop_line" >&2
    return 1
  }

  mount_line=$(udisksctl mount -b "$loop_dev" 2>&1) || {
    udisksctl loop-delete -b "$loop_dev" >/dev/null 2>&1
    echo "disk_image::root_mount: mount failed: $mount_line" >&2
    return 1
  }
  mount_point=$(grep -oP '(?<=at ).*' <<<"$mount_line")
  if [[ -z $mount_point || ! -d "$mount_point/@" ]]; then
    udisksctl unmount -b "$loop_dev" >/dev/null 2>&1
    udisksctl loop-delete -b "$loop_dev" >/dev/null 2>&1
    echo "disk_image::root_mount: no @ subvolume found at '${mount_point:-<unparsed>}'" >&2
    return 1
  fi
  echo "$loop_dev $mount_point/@"
}

# disk_image::root_unmount <loop-dev> — always call this once done with
# whatever disk_image::root_mount handed back, success or failure.
disk_image::root_unmount() {
  local loop_dev=$1
  udisksctl unmount -b "$loop_dev" >/dev/null 2>&1 || true
  udisksctl loop-delete -b "$loop_dev" >/dev/null 2>&1 || true
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
