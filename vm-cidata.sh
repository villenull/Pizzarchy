#!/usr/bin/env bash
# Library: build a `cidata`-labeled autoinstall drive for
# omacom-io/omarchy-iso's unattended install path.
#
# Schema for user_configuration.json / user_credentials.json is
# archinstall's own --config/--creds JSON format (Omarchy passes both
# through to archinstall.lib.args.ArchConfigHandler mostly unmodified,
# only stripping its own `omarchy_install` key first) — confirmed by
# reading orchestrator/context.py and archinstall_adapter.py, and
# cross-checked against configs/airootfs/root/configurator's own working
# full-disk-btrfs-Limine template, which is the same code path the ISO's
# interactive wizard uses to write these files (session 1 research).
#
# Not meant to be run directly — source it.

set -uo pipefail

# cidata::render_config <disk-device> <disk-bytes> <hostname> <config-json-out>
# Single-disk, whole-disk-wipe, btrfs, Limine, unencrypted, fully-offline
# layout (network_config.type=iso — no network reads during install,
# confirmed by session-1 research: no curl/wget/reflector anywhere in the
# orchestrator's install phases).
#
# Partition layout mirrors the configurator's own template: 1MiB-aligned
# ESP start, 2GiB fixed ESP, btrfs root filling the rest minus a 1MiB GPT
# backup-table reserve at the end.
cidata::render_config() {
  local device=$1 disk_bytes=$2 hostname=$3 out=$4
  local boot_start=1048576 boot_size=2147483648
  local root_start=$((boot_start + boot_size))
  local root_size=$((disk_bytes - root_start - 1048576))

  if [[ $root_size -le 0 ]]; then
    echo "cidata::render_config: disk_bytes=$disk_bytes too small for a 2GiB ESP + any root (need > $((root_start + 1048576)))" >&2
    return 1
  fi

  jq -n \
    --arg device "$device" \
    --arg hostname "$hostname" \
    --argjson boot_start "$boot_start" --argjson boot_size "$boot_size" \
    --argjson root_start "$root_start" --argjson root_size "$root_size" \
    '{
      "archinstall-language": "English",
      "auth_config": {},
      "audio_config": { "audio": "pipewire" },
      "bootloader_config": { "bootloader": "Limine", "uki": false, "removable": false },
      "custom_commands": [],
      "omarchy_install": {
        "mode": "full_disk",
        "target_mount": "/mnt",
        "boot": {
          "esp_mount": "/boot",
          "esp_path": "/EFI/limine",
          "efi_binary": "limine_x64.efi",
          "enable_fallback": true
        },
        "storage": { "kernel": "linux" }
      },
      "disk_config": {
        "config_type": "default_layout",
        "device_modifications": [ {
          "device": $device,
          "wipe": true,
          "partitions": [
            {
              "btrfs": [], "dev_path": null, "flags": ["boot", "esp"],
              "fs_type": "fat32", "mount_options": [], "mountpoint": "/boot",
              "size": { "sector_size": {"unit":"B","value":512}, "unit": "B", "value": $boot_size },
              "start": { "sector_size": {"unit":"B","value":512}, "unit": "B", "value": $boot_start },
              "status": "create", "type": "primary"
            },
            {
              "btrfs": [
                {"mountpoint": "/", "name": "@"},
                {"mountpoint": "/home", "name": "@home"},
                {"mountpoint": "/var/log", "name": "@log"},
                {"mountpoint": "/var/cache/pacman/pkg", "name": "@pkg"}
              ],
              "dev_path": null, "flags": [], "fs_type": "btrfs",
              "mount_options": ["compress=zstd"], "mountpoint": null,
              "size": { "sector_size": {"unit":"B","value":512}, "unit": "B", "value": $root_size },
              "start": { "sector_size": {"unit":"B","value":512}, "unit": "B", "value": $root_start },
              "status": "create", "type": "primary"
            }
          ]
        } ]
      },
      "hostname": $hostname,
      "kernels": ["linux"],
      "network_config": { "type": "iso" },
      "ntp": true,
      "parallel_downloads": 8,
      "script": null,
      "services": [],
      "swap": true,
      "timezone": "UTC",
      "locale_config": { "kb_layout": "us", "sys_enc": "UTF-8", "sys_lang": "en_US.UTF-8" },
      "mirror_config": {
        "custom_repositories": [], "mirror_regions": {}, "optional_repositories": [],
        "custom_servers": [ {"url": "https://mirror.omarchy.org/$repo/os/$arch"} ]
      },
      "packages": ["base-devel", "git", "omarchy-keyring", "omarchy-settings", "omarchy"],
      "profile_config": { "gfx_driver": null, "greeter": null, "profile": {} },
      "version": "3.0.9"
    }' >"$out"
}

# cidata::render_credentials <username> <password> <creds-json-out>
# Hashes with the same scheme the configurator uses (yescrypt via
# `openssl passwd -6`, i.e. SHA-512 crypt — "-6" is openssl's SHA-512
# libcrypt identifier, not literal yescrypt, but it's what the wizard's
# own `write_user_files` produces, so match it).
cidata::render_credentials() {
  local username=$1 password=$2 out=$3
  local hash
  hash=$(openssl passwd -6 -stdin <<<"$password")
  jq -n --arg hash "$hash" --arg username "$username" \
    '{
      "root_enc_password": $hash,
      "users": [ { "enc_password": $hash, "groups": [], "sudo": true, "username": $username } ]
    }' >"$out"
}

# cidata::build_image <dest-img> <config-json> <creds-json> [extra-file...]
# FAT-labeled CIDATA image (mkfs.vfat + mtools), not ISO9660 — no
# xorriso/genisoimage/mkisofs available on this dev machine, and the
# loader (`omarchy-cidata-load`) just does `mount -o ro`, so any
# filesystem udev assigns a by-label symlink to works.
cidata::build_image() {
  local dest=$1 config=$2 creds=$3; shift 3
  local -a extra=("$@")

  truncate -s 8M "$dest"
  mkfs.vfat -n CIDATA "$dest" >/dev/null

  MTOOLS_SKIP_CHECK=1 mcopy -i "$dest" "$config" ::/user_configuration.json
  MTOOLS_SKIP_CHECK=1 mcopy -i "$dest" "$creds" ::/user_credentials.json
  local f
  for f in "${extra[@]}"; do
    MTOOLS_SKIP_CHECK=1 mcopy -i "$dest" "$f" "::/$(basename "$f")"
  done
}
