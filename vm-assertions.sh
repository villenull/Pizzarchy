#!/usr/bin/env bash
# Library: the actual "done when" assertions from
# TASK-T0-test-infrastructure.md §1 — asserting on installed *artifacts*
# (partition table, UKI files, Limine config, package set, enabled units),
# never on log text. PLAN.md §8.1 is the reason why: upstream's
# linux-neptune.sh printed "Installing Neptune kernel..." and exited 0
# while doing nothing. A log-scraping test would have passed on that bug.
#
# Split deliberately into two layers per assertion:
#   - extraction (reads the disk image: mtools/dd/btrfs restore)
#   - checking (pure logic over an already-extracted directory/file)
# so the checking half can be unit-tested with hand-built fixtures without
# needing a real install or root access, and only the extraction half needs
# a real disk image to exercise.
#
# Not meant to be run directly — source it (after vm-disk-image.sh).

set -uo pipefail

# Candidate Limine config paths, in probe order. Limine's config location
# isn't stable across versions (PLAN.md §8.2) — Omarchy's own
# limine-snapper.sh probes five candidates; do the same rather than
# hardcoding one, per §8.2's implied fix.
readonly -a VM_ASSERT_LIMINE_CONFIG_CANDIDATES=(
  "/EFI/arch-limine/limine.conf"
  "/EFI/BOOT/limine.conf"
  "/EFI/limine/limine.conf"
  "/limine/limine.conf"
  "/limine.conf"
)

# --- partition table -------------------------------------------------------

# assert::partition_table <disk>
# Exactly one ESP-typed partition and exactly one other (root) partition.
# Prints a one-line reason and returns 1 on failure.
assert::partition_table() {
  local disk=$1
  disk_image::esp_offset "$disk" >/dev/null 2>&1 || {
    echo "assert::partition_table: no ESP partition found" >&2
    return 1
  }
  disk_image::root_partition "$disk" >/dev/null 2>&1 || {
    echo "assert::partition_table: root partition check failed (expected exactly one non-ESP partition)" >&2
    return 1
  }
  return 0
}

# --- UKI files ---------------------------------------------------------

# assert::uki_files_present <dir> <expected-name...>
# Pure check: $dir already holds whatever was under /EFI/Linux (or
# wherever mkinitcpio's preset points, per PLAN.md §8.3 — configurable by
# caller, not hardcoded here). Fails loudly listing both sets on mismatch.
assert::uki_files_present() {
  local dir=$1; shift
  local -a expected=("$@")
  local -a found=()
  local f
  while IFS= read -r -d '' f; do
    found+=("$(basename "$f")")
  done < <(find "$dir" -maxdepth 1 -iname '*.efi' -print0 2>/dev/null | sort -z)

  local name ok
  for name in "${expected[@]}"; do
    ok=0
    for f in "${found[@]}"; do [[ $f == "$name" ]] && ok=1 && break; done
    if [[ $ok -eq 0 ]]; then
      echo "assert::uki_files_present: expected UKI '$name' not found; present: ${found[*]:-<none>}" >&2
      return 1
    fi
  done
  if [[ ${#found[@]} -ne ${#expected[@]} ]]; then
    echo "assert::uki_files_present: expected exactly ${#expected[@]} UKI(s) (${expected[*]}), found ${#found[@]} (${found[*]:-<none>})" >&2
    return 1
  fi
  return 0
}

# disk_image::esp_extract_ukis <disk> <dest-dir>
# Extraction half: pulls every *.efi under /EFI/Linux on the ESP into
# dest-dir, flat, for assert::uki_files_present to check.
disk_image::esp_extract_ukis() {
  local disk=$1 dest=$2
  mkdir -p "$dest"
  local offset
  offset=$(disk_image::esp_offset "$disk") || return 1
  local f
  while IFS= read -r f; do
    [[ $f == *.efi || $f == *.EFI ]] || continue
    MTOOLS_SKIP_CHECK=1 mcopy -i "${disk}@@${offset}" "::/EFI/Linux/${f}" "$dest/" 2>/dev/null || true
  done < <(MTOOLS_SKIP_CHECK=1 mdir -b -i "${disk}@@${offset}" "::/EFI/Linux" 2>/dev/null | xargs -n1 basename 2>/dev/null)
}

# --- Limine config -----------------------------------------------------

# disk_image::esp_find_limine_config <disk> <dest-file>
# Extraction half: probes VM_ASSERT_LIMINE_CONFIG_CANDIDATES in order,
# copies the first one found to dest-file, prints which candidate matched.
disk_image::esp_find_limine_config() {
  local disk=$1 dest=$2
  local offset candidate
  offset=$(disk_image::esp_offset "$disk") || return 1
  for candidate in "${VM_ASSERT_LIMINE_CONFIG_CANDIDATES[@]}"; do
    if MTOOLS_SKIP_CHECK=1 mcopy -i "${disk}@@${offset}" "::${candidate}" "$dest" 2>/dev/null; then
      echo "$candidate"
      return 0
    fi
  done
  echo "disk_image::esp_find_limine_config: none of the candidate paths exist on the ESP: ${VM_ASSERT_LIMINE_CONFIG_CANDIDATES[*]}" >&2
  return 1
}

# assert::limine_config_entries <config-file> <expected-path-substring...>
# Pure check: the Limine config (already extracted) contains a `path:`
# (or legacy `KERNEL_PATH=`) line referencing each expected substring —
# e.g. the neptune kernel's UKI filename. Limine config syntax uses
# `path: boot():/EFI/Linux/foo.efi`-style directives; match loosely on
# substring rather than parsing the full grammar, since the grammar isn't
# pinned to one Limine version.
assert::limine_config_entries() {
  local config=$1; shift
  local -a expected=("$@")
  [[ -f $config ]] || { echo "assert::limine_config_entries: $config does not exist" >&2; return 1; }
  local needle
  for needle in "${expected[@]}"; do
    grep -qi -- "$needle" "$config" || {
      echo "assert::limine_config_entries: '$needle' not referenced anywhere in $config" >&2
      return 1
    }
  done
  return 0
}

# --- package set / enabled units (root partition) -----------------------

# disk_image::root_extract <disk> <dest-raw-file>
# Extraction half, step 1: carve the root partition out to its own file
# (needs to see the partition's own byte 0 — see disk_image::root_mount in
# vm-disk-image.sh for step 2).
disk_image::root_extract() {
  local disk=$1 dest=$2
  local start size
  read -r start size < <(disk_image::root_partition "$disk") || return 1
  disk_image::extract "$disk" "$start" "$size" "$dest"
}

# assert::packages_present <pacman-local-db-dir> <package-name...>
# Pure check: pacman's local db is one directory per installed
# "name-version" under var/lib/pacman/local/, each holding a plain-text
# `desc` file — existence of a matching directory is enough, no need to
# parse desc's contents.
assert::packages_present() {
  local db_dir=$1; shift
  local -a expected=("$@")
  [[ -d $db_dir ]] || { echo "assert::packages_present: $db_dir does not exist (pacman local db not restored?)" >&2; return 1; }
  local pkg
  for pkg in "${expected[@]}"; do
    compgen -G "$db_dir/${pkg}-*/desc" >/dev/null || {
      echo "assert::packages_present: package '$pkg' not found under $db_dir" >&2
      return 1
    }
  done
  return 0
}

# assert::units_enabled <systemd-system-dir> <unit-name...>
# Pure check: each unit has at least one enabling symlink somewhere under
# the restored etc/systemd/system tree (systemd enables units via
# *.wants/ or *.requires/ symlinks pointing at the unit file).
assert::units_enabled() {
  local systemd_dir=$1; shift
  local -a expected=("$@")
  [[ -d $systemd_dir ]] || { echo "assert::units_enabled: $systemd_dir does not exist (systemd tree not restored?)" >&2; return 1; }
  local unit
  for unit in "${expected[@]}"; do
    find "$systemd_dir" -path '*.wants/*' -o -path '*.requires/*' 2>/dev/null \
      | grep -q -- "/${unit}$" || {
      echo "assert::units_enabled: '$unit' has no enabling symlink under $systemd_dir" >&2
      return 1
    }
  done
  return 0
}
