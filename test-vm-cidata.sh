#!/usr/bin/env bash
# Unit tests for vm-cidata.sh — the cidata autoinstall drive builder.
# Schema for the two JSON files comes from reading archinstall_adapter.py
# and the configurator's own working template (session 1 research); these
# tests check structure/arithmetic this script controls, not that
# archinstall itself accepts the file (that needs a real install run).

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=vm-cidata.sh
source "$ROOT/vm-cidata.sh"

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; [[ -n ${2:-} ]] && printf '%s\n' "$2" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# --- render_config: JSON validity + partition arithmetic ---------------

config="$work/user_configuration.json"
disk_bytes=$((20 * 1024 * 1024 * 1024))  # 20GiB, matches the worked example from research
cidata::render_config /dev/vda "$disk_bytes" test-vm "$config"

jq empty "$config" || fail "render_config produces valid JSON"
pass "render_config produces valid JSON"

boot_start=$(jq '.disk_config.device_modifications[0].partitions[0].start.value' "$config")
boot_size=$(jq '.disk_config.device_modifications[0].partitions[0].size.value' "$config")
root_start=$(jq '.disk_config.device_modifications[0].partitions[1].start.value' "$config")
root_size=$(jq '.disk_config.device_modifications[0].partitions[1].size.value' "$config")

[[ $boot_start -eq 1048576 && $boot_size -eq 2147483648 ]] ||
  fail "boot partition is 1MiB-aligned, 2GiB fixed" "start=$boot_start size=$boot_size"
pass "boot partition offset/size match the fixed 1MiB+2GiB convention"

[[ $root_start -eq $((boot_start + boot_size)) ]] ||
  fail "root partition starts immediately after boot" "root_start=$root_start expected=$((boot_start + boot_size))"
# Matches the worked 20GiB example from session-1 research: root_size == disk_bytes - root_start - 1MiB reserve.
expected_root_size=$((disk_bytes - root_start - 1048576))
[[ $root_size -eq $expected_root_size ]] ||
  fail "root partition fills the disk minus the 1MiB GPT backup reserve" "got=$root_size expected=$expected_root_size"
pass "root partition arithmetic matches disk size minus boot partition minus GPT reserve"

device=$(jq -r '.disk_config.device_modifications[0].device' "$config")
[[ $device == /dev/vda ]] || fail "config targets the given device" "$device"
hostname=$(jq -r '.hostname' "$config")
[[ $hostname == test-vm ]] || fail "config carries the given hostname" "$hostname"
network_type=$(jq -r '.network_config.type' "$config")
[[ $network_type == iso ]] || fail "network_config.type stays 'iso' (offline install, no network dependency)" "$network_type"
pass "device/hostname/offline-network fields are set correctly"

if cidata::render_config /dev/vda 1000000 too-small "$work/tiny.json" 2>/dev/null; then
  fail "render_config refuses a disk too small to fit boot+root, rather than emitting a broken negative size"
fi
pass "render_config fails loudly on a disk too small for the fixed boot partition"

# --- render_credentials: hash format ------------------------------------

creds="$work/user_credentials.json"
cidata::render_credentials tester tester123 "$creds"
jq empty "$creds" || fail "render_credentials produces valid JSON"
pass "render_credentials produces valid JSON"

hash=$(jq -r '.root_enc_password' "$creds")
# shellcheck disable=SC2016 # deliberately literal: matching the $6$ prefix, not expanding it
[[ $hash == '$6$'* ]] || fail "password hash uses SHA-512 crypt (\$6\$), matching the configurator's own openssl passwd -6" "$hash"
user_hash=$(jq -r '.users[0].enc_password' "$creds")
[[ $hash == "$user_hash" ]] || fail "root and user share the same hash for the same input password"
username=$(jq -r '.users[0].username' "$creds")
[[ $username == tester ]] || fail "username carried through"
sudo_flag=$(jq -r '.users[0].sudo' "$creds")
[[ $sudo_flag == true ]] || fail "user is sudo-enabled"
pass "render_credentials produces a correctly-shaped users[] entry with a real SHA-512 hash"

# --- build_image: real FAT filesystem, readable back via mtools --------

img="$work/cidata.img"
extra_file="$work/authorized_keys"
echo "ssh-ed25519 AAAA test" >"$extra_file"
cidata::build_image "$img" "$config" "$creds" "$extra_file"

[[ -f $img ]] || fail "build_image produces a file"
label=$(MTOOLS_SKIP_CHECK=1 mdir -i "$img" :: 2>/dev/null | grep -i 'Volume in drive' || true)
grep -qi CIDATA <<<"$label" || fail "image is labeled CIDATA (by-label lookup depends on this)" "$label"
pass "build_image produces a FAT image labeled CIDATA"

for name in user_configuration.json user_credentials.json authorized_keys; do
  MTOOLS_SKIP_CHECK=1 mdir -i "$img" :: 2>/dev/null | grep -qi "${name%%.*}" ||
    fail "build_image includes $name on the volume"
done
pass "build_image writes the required pair plus the extra optional file"

readback="$work/config-readback.json"
MTOOLS_SKIP_CHECK=1 mcopy -i "$img" ::/user_configuration.json "$readback"
diff -q "$config" "$readback" >/dev/null || fail "config content round-trips through the image unmodified"
pass "config content round-trips through the built image unmodified"

echo "all vm-cidata.sh tests passed"
