#!/usr/bin/env bash
# Unit tests for vm-assertions.sh. The "extraction" half of each assertion
# (mtools/dd/btrfs restore) is exercised against small hand-built fixture
# images; the "checking" half (pure logic) is exercised directly against
# hand-built directory fixtures, matching the deliberate extraction/
# checking split described at the top of vm-assertions.sh.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=vm-disk-image.sh
source "$ROOT/vm-disk-image.sh"
# shellcheck source=vm-assertions.sh
source "$ROOT/vm-assertions.sh"

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; [[ -n ${2:-} ]] && printf '%s\n' "$2" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# --- partition table --------------------------------------------------

good_disk="$work/good.raw"
truncate -s 200M "$good_disk"
parted --script "$good_disk" mklabel gpt \
  mkpart ESP fat32 1MiB 65MiB set 1 esp on \
  mkpart root btrfs 65MiB 100% >/dev/null
mkfs.vfat -n ESP "$good_disk" --offset 2048 >/dev/null

assert::partition_table "$good_disk" || fail "assert::partition_table accepts a real ESP+root layout"
pass "assert::partition_table accepts a real ESP+root layout"

bad_disk="$work/bad.raw"
truncate -s 100M "$bad_disk"
parted --script "$bad_disk" mklabel gpt mkpart primary btrfs 1MiB 100% >/dev/null
if assert::partition_table "$bad_disk" 2>/dev/null; then
  fail "assert::partition_table rejects a disk with no ESP"
fi
pass "assert::partition_table rejects a disk with no ESP"

# --- UKI files ----------------------------------------------------------

esp_offset=$(disk_image::esp_offset "$good_disk")
MTOOLS_SKIP_CHECK=1 mmd -i "${good_disk}@@${esp_offset}" ::/EFI ::/EFI/Linux
echo fake >"$work/arch-linux-neptune.efi"
MTOOLS_SKIP_CHECK=1 mcopy -i "${good_disk}@@${esp_offset}" "$work/arch-linux-neptune.efi" ::/EFI/Linux/arch-linux-neptune.efi

uki_dir="$work/ukis"
disk_image::esp_extract_ukis "$good_disk" "$uki_dir"
assert::uki_files_present "$uki_dir" arch-linux-neptune.efi ||
  fail "assert::uki_files_present accepts the extracted UKI that's really there"
pass "esp_extract_ukis + assert::uki_files_present find a real UKI end-to-end"

if assert::uki_files_present "$uki_dir" arch-linux-neptune.efi wrong-name.efi 2>/dev/null; then
  fail "assert::uki_files_present rejects a UKI name that isn't present"
fi
pass "assert::uki_files_present rejects an expected name that's missing"

if assert::uki_files_present "$uki_dir" 2>/dev/null; then
  fail "assert::uki_files_present rejects an unexpected extra UKI (expected none, found one)"
fi
pass "assert::uki_files_present rejects an extra UKI beyond what's expected"

# --- Limine config ------------------------------------------------------

MTOOLS_SKIP_CHECK=1 mmd -i "${good_disk}@@${esp_offset}" ::/EFI/BOOT
cat >"$work/limine.conf" <<'EOF'
TIMEOUT=5

/Arch Linux
    PROTOCOL=linux
    KERNEL_PATH=boot():/EFI/Linux/arch-linux-neptune.efi

/Arch Linux (fallback)
    PROTOCOL=linux
    KERNEL_PATH=boot():/EFI/Linux/arch-linux-neptune-fallback.efi
EOF
MTOOLS_SKIP_CHECK=1 mcopy -i "${good_disk}@@${esp_offset}" "$work/limine.conf" ::/EFI/BOOT/limine.conf

found_at="$work/found-limine.conf"
candidate=$(disk_image::esp_find_limine_config "$good_disk" "$found_at") ||
  fail "esp_find_limine_config finds the config at the second candidate path"
[[ $candidate == "/EFI/BOOT/limine.conf" ]] || fail "esp_find_limine_config reports the matching candidate path" "got $candidate"
pass "esp_find_limine_config probes candidates in order and finds a real config"

assert::limine_config_entries "$found_at" "arch-linux-neptune.efi" ||
  fail "assert::limine_config_entries finds the expected kernel reference"
pass "assert::limine_config_entries accepts a config that references the expected kernel"

if assert::limine_config_entries "$found_at" "arch-linux-neptune.efi" "some-other-kernel.efi" 2>/dev/null; then
  fail "assert::limine_config_entries rejects a reference that isn't in the config"
fi
pass "assert::limine_config_entries rejects a missing expected reference"

empty_disk="$work/empty-esp.raw"
truncate -s 100M "$empty_disk"
parted --script "$empty_disk" mklabel gpt mkpart ESP fat32 1MiB 100% set 1 esp on >/dev/null
mkfs.vfat -n ESP "$empty_disk" --offset 2048 >/dev/null
if disk_image::esp_find_limine_config "$empty_disk" "$work/none.conf" 2>/dev/null; then
  fail "esp_find_limine_config fails loudly when no candidate path exists"
fi
pass "esp_find_limine_config fails loudly (not silently) when no Limine config exists anywhere probed"

# --- package set / enabled units (pure-logic half, hand-built fixture) ---

db="$work/pacman-local"
mkdir -p "$db/omarchy-1.0.0-1" "$db/base-devel-1-1"
touch "$db/omarchy-1.0.0-1/desc" "$db/base-devel-1-1/desc"

assert::packages_present "$db" omarchy base-devel ||
  fail "assert::packages_present accepts packages that are really installed"
pass "assert::packages_present accepts real installed packages"

if assert::packages_present "$db" omarchy some-missing-package 2>/dev/null; then
  fail "assert::packages_present rejects a package that isn't installed"
fi
pass "assert::packages_present rejects a missing package"

systemd_dir="$work/systemd-system"
mkdir -p "$systemd_dir/multi-user.target.wants"
touch "$systemd_dir/sshd.service"
ln -s ../sshd.service "$systemd_dir/multi-user.target.wants/sshd.service"

assert::units_enabled "$systemd_dir" sshd.service ||
  fail "assert::units_enabled accepts a unit with a real .wants symlink"
pass "assert::units_enabled accepts a genuinely enabled unit"

if assert::units_enabled "$systemd_dir" NetworkManager.service 2>/dev/null; then
  fail "assert::units_enabled rejects a unit with no enabling symlink"
fi
pass "assert::units_enabled rejects a unit that isn't actually enabled"

echo "all vm-assertions.sh tests passed"
