#!/usr/bin/env bash
# Library: OUTCOME assertions — "can the machine this build produced actually
# do its job", asked of the installed image and of the live ISO.
#
# ===========================================================================
# WHY THIS FILE EXISTS
# ===========================================================================
#
# On 2026-08-15 the QEMU install harness scored 18/18 against an image that
# could not reach Gaming Mode. The install's own record reported eleven green
# steps. Both were true and both were useless, for one reason:
#
#   EVERY ASSERTION CHECKED THAT OUR STEPS RAN. NONE CHECKED THAT THE OUTCOME
#   THOSE STEPS EXIST TO PRODUCE ACTUALLY EXISTS.
#
# `autologin status='gaming'` is a fact about a config file we wrote. It says
# nothing about whether Steam is installed, and Steam was not: the target's
# pacman DB had no `steam`, /usr/lib/steam did not exist, gamescope started
# with nothing to display, and the panel stayed black through two full boots.
# Three components hit this in a single day — the OSK mapper (built, unit
# tested, never put in the live ISO), steam/steamdeck-dsp (listed, never
# installed), the session layer (written, never run by the installer).
# docs/findings/P32-steam-never-installed.md and
# docs/findings/P32-osk-mapper-missing-from-live-iso.md are the write-ups.
#
# So every check here is phrased as a property of an ARTIFACT — a package in
# the target's pacman DB, a file at a path something else will open, a UKI on
# the ESP, a mode bit inside the ISO's squashfs — and every check names, in
# its own description, the finding it guards against. A future reader looking
# at a FAIL line should not have to ask why the assertion is there.
#
# ===========================================================================
# WHAT IS DELIBERATELY NOT HERE
# ===========================================================================
#
# No log scraping, no reading the install record to decide whether something
# passed. The install record is read in exactly ONE place (see
# outcome::install_record_status) and only to make a FAILURE message more
# useful — "the fetch step ran and reported an error" and "the fetch step
# never ran at all" need different fixes, and the artifact alone cannot tell
# them apart. It is never allowed to turn a missing artifact into a pass.
#
# Not meant to be run directly — source it, after test/lib/vm-installer-screens.sh
# (screens::check is the counter every assertion reports through) and
# test/lib/vm-disk-image.sh.

set -uo pipefail

# ---------------------------------------------------------------------------
# Derived facts. Nothing in this file spells a version or a package name it
# could read out of the product instead.
# ---------------------------------------------------------------------------

# outcome::neptune_series <repo-root>
# The Neptune kernel series, read from src/omarchy-deck-kernel.sh's
# NEPTUNE_SERIES_DEFAULT — the pin that file's own comment calls the one to
# move ("If the series moves, move it in both places",
# iso/overlay/configs/deck/deck-mirror.packages). Fails loudly rather than
# defaulting: a wrong series here would assert the presence of a kernel nobody
# ships and read as a broken install.
outcome::neptune_series() {
  local repo_root=$1 series
  series=$(grep -oE '^readonly NEPTUNE_SERIES_DEFAULT=[0-9]+' \
    "$repo_root/src/omarchy-deck-kernel.sh" 2>/dev/null | head -n1) || true
  series=${series##*=}
  if [[ ! $series =~ ^[0-9]+$ ]]; then
    echo "outcome::neptune_series: no 'readonly NEPTUNE_SERIES_DEFAULT=<n>' in $repo_root/src/omarchy-deck-kernel.sh — refusing to guess a kernel series" >&2
    return 1
  fi
  printf '%s\n' "$series"
}

# ---------------------------------------------------------------------------
# The target's package set
# ---------------------------------------------------------------------------

# outcome::pacman_pkgnames <pacman-local-db-dir>
# One package NAME per line. pacman's local db is one directory per installed
# package, named "<pkgname>-<pkgver>-<pkgrel>"; neither pkgver nor pkgrel may
# contain a '-', so stripping the last two dash-separated fields is exact.
#
# 🔴 EXACT, not a glob, and that is the whole point of this function.
# assert::packages_present (test/lib/vm-assertions.sh) matches
# "$db_dir/${pkg}-*/desc", which is right for the names it was written for and
# WRONG for this file's two hardest questions: `linux-*` matches
# linux-api-headers and linux-firmware, so "is stock linux installed?" would
# answer yes on a Neptune-only machine, and "is stock linux ABSENT?" could
# never be answered at all. Measured against the real 2026-08-15 install
# image, which carries linux-api-headers and linux-firmware and (wrongly)
# linux itself.
outcome::pacman_pkgnames() {
  local db_dir=$1 entry name
  [[ -d $db_dir ]] || {
    echo "outcome::pacman_pkgnames: $db_dir does not exist (pacman local db not mounted?)" >&2
    return 1
  }
  for entry in "$db_dir"/*/; do
    entry=${entry%/}
    name=${entry##*/}
    [[ -f "$entry/desc" ]] || continue
    name=${name%-*}     # drop pkgrel
    name=${name%-*}     # drop pkgver
    [[ -n $name ]] && printf '%s\n' "$name"
  done
}

# outcome::package_installed <pkgnames-file> <pkgname>
outcome::package_installed() {
  local names_file=$1 pkg=$2
  LC_ALL=C command grep -qxF -- "$pkg" "$names_file"
}

# ---------------------------------------------------------------------------
# The install record — used ONLY to sharpen a failure message
# ---------------------------------------------------------------------------

# outcome::install_record <root-mount>
# Prints the path of the Deck installer's own JSON record, or nothing.
#
# The record lives at /var/log/omarchy-deck-install.json on the running system,
# and on this project's btrfs layout /var/log is its OWN SUBVOLUME (@log),
# a sibling of @ — so from a mounted @ it is one level up, not under it.
# Measured on the 2026-08-15 install image. Both shapes are probed, because a
# layout change must not silently turn "no record" into "no diagnosis".
outcome::install_record() {
  local root_at=$1 candidate
  for candidate in \
    "$(dirname -- "$root_at")/@log/omarchy-deck-install.json" \
    "$root_at/var/log/omarchy-deck-install.json"; do
    [[ -f $candidate ]] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

# outcome::install_record_status <root-mount> <section>
# Prints one of:
#   no-record        the installer wrote no record at all
#   no-section       the record exists and has no such key — THE STEP NEVER RAN
#   <status-value>   the step ran and said this about itself
#
# ⚠️ This can only ever make a message better. Nothing in this file lets a
# green record substitute for a missing artifact: that substitution is the
# 18/18 failure this whole library exists because of.
outcome::install_record_status() {
  local root_at=$1 section=$2 record status
  record=$(outcome::install_record "$root_at") || { echo "no-record"; return 0; }
  command -v jq >/dev/null 2>&1 || { echo "no-jq"; return 0; }
  if [[ $(jq -r --arg s "$section" 'has($s)' "$record" 2>/dev/null) != true ]]; then
    echo "no-section"
    return 0
  fi
  status=$(jq -r --arg s "$section" '.[$s].status // "<no status field>"' "$record" 2>/dev/null)
  printf '%s\n' "$status"
}

# ---------------------------------------------------------------------------
# The ESP's UKI
# ---------------------------------------------------------------------------

# outcome::uki_matches_pkgbase <uki-name> <pkgbase>
# limine-mkinitcpio-hook writes $ESP/EFI/Linux/<prefix>_<pkgbase>.efi, where
# <prefix> is CUSTOM_UKI_NAME from /etc/default/limine ("omarchy" on this
# project's installs) and NOT the machine-id — src/omarchy-deck-kernel.sh's
# find_uki_for records the version of this file that got that wrong. So the
# prefix is discovered, never constructed; only the suffix is asserted.
outcome::uki_matches_pkgbase() {
  local uki=$1 pkgbase=$2
  [[ $uki == *"_${pkgbase}.efi" ]]
}

# ---------------------------------------------------------------------------
# The live ISO: iso9660 -> squashfs, rootless
# ---------------------------------------------------------------------------

# outcome::sfs_reader
# Prints the squashfs listing tool to use, or fails.
#
# ⚠️ ONE BACKEND, ON PURPOSE. `7z` is what this was written and measured
# against (7-Zip 26.02, SquashFS 4.0/ZSTD, 0.07s to answer a path query
# against a 6.2 GiB image without extracting anything). An `unsquashfs`
# backend would be the more obvious choice and is NOT here because it could
# not be exercised on the machine this was written on — squashfs-tools is not
# installed — and a listing parser nobody has ever run is exactly the kind of
# check that reports a cheerful nothing. Add it WITH a run against a real
# image, or leave this refusing loudly.
outcome::sfs_reader() {
  if command -v 7z >/dev/null 2>&1; then printf '7z\n'; return 0; fi
  echo "outcome::sfs_reader: no squashfs reader on PATH. Install p7zip (7z) — the live-ISO half of these assertions reads the ISO's airootfs.sfs without extracting it, and skipping them would leave the P32 shape (a component in the repo, absent from the image) uncovered again." >&2
  return 1
}

# outcome::iso_mount <iso-path>
# Rootless iso9660 mount via udisksctl, the same model
# disk_image::root_mount already uses for the installed root. Prints
# "<loop-dev> <mount-point>".
#
# Archiso images are isohybrid: the whole device carries the iso9660
# filesystem AND an MBR partition table over it, so udisks may decline the
# whole device and offer only the partitions. Both are tried, in that order,
# and a failure says which.
outcome::iso_mount() {
  local iso=$1 loop_line loop_dev mount_line mount_point candidate

  loop_line=$(udisksctl loop-setup -r -f "$iso" 2>&1) || {
    echo "outcome::iso_mount: loop-setup failed: $loop_line" >&2
    return 1
  }
  loop_dev=$(grep -oP '(?<=as )/dev/loop[0-9]+' <<<"$loop_line")
  [[ -n $loop_dev ]] || {
    echo "outcome::iso_mount: could not parse a loop device from: $loop_line" >&2
    return 1
  }

  mount_point=""
  for candidate in "$loop_dev" "${loop_dev}p1"; do
    [[ -b $candidate ]] || continue
    mount_line=$(udisksctl mount -b "$candidate" 2>&1) || continue
    mount_point=$(grep -oP '(?<=at ).*' <<<"$mount_line")
    [[ -n $mount_point ]] && break
  done
  if [[ -z $mount_point ]]; then
    udisksctl loop-delete -b "$loop_dev" >/dev/null 2>&1
    echo "outcome::iso_mount: mapped $iso as $loop_dev but neither it nor ${loop_dev}p1 would mount (last: ${mount_line:-<none>})" >&2
    return 1
  fi
  printf '%s %s\n' "$loop_dev" "$mount_point"
}

# outcome::iso_unmount <loop-dev> — always call this, success or failure.
outcome::iso_unmount() {
  local loop_dev=$1 part
  for part in "${loop_dev}p1" "$loop_dev"; do
    udisksctl unmount -b "$part" >/dev/null 2>&1 || true
  done
  udisksctl loop-delete -b "$loop_dev" >/dev/null 2>&1 || true
}

# outcome::iso_sfs <iso-mount-point>
# The airootfs squashfs inside a mounted archiso image. Discovered, not
# constructed: the directory is named after the profile's iso_name and this
# fork's has changed once already.
outcome::iso_sfs() {
  local mount_point=$1 found
  found=$(find "$mount_point" -maxdepth 3 -name '*.sfs' -type f 2>/dev/null | LC_ALL=C sort | head -n1)
  [[ -n $found ]] || {
    echo "outcome::iso_sfs: no *.sfs anywhere under $mount_point — this is not an archiso image, or its root filesystem is packed some other way" >&2
    return 1
  }
  printf '%s\n' "$found"
}

# outcome::sfs_entries <sfs> <path-or-glob>
# Prints "<mode>\t<path>" for every entry in the squashfs matching the
# pattern. Nothing is extracted; the archive is read in place.
outcome::sfs_entries() {
  local sfs=$1 pattern=$2 reader path="" mode="" line
  reader=$(outcome::sfs_reader) || return 1
  case $reader in
    7z)
      # `7z l -slt` emits one blank-line-separated block per entry, after a
      # header block that ALSO carries a `Path =` line (the archive's own
      # name). Everything before the first `----------` separator is header,
      # and dropping it is what stops the archive from reporting itself as a
      # match for whatever was asked about.
      while IFS= read -r line; do
        case $line in
          "Path = "*) path=${line#Path = } ;;
          "Mode = "*) mode=${line#Mode = } ;;
          "")
            if [[ -n $path ]]; then printf '%s\t%s\n' "${mode:-<no-mode>}" "$path"; fi
            path=""
            mode=""
            ;;
        esac
      done < <(7z l -slt "$sfs" "$pattern" 2>/dev/null |
        LC_ALL=C command sed -n '/^----------$/,$p')
      if [[ -n $path ]]; then printf '%s\t%s\n' "${mode:-<no-mode>}" "$path"; fi
      ;;
  esac
  return 0
}

# outcome::sfs_mode <sfs> <exact-path> — the mode string, or nothing.
outcome::sfs_mode() {
  local sfs=$1 path=$2 line
  line=$(outcome::sfs_entries "$sfs" "$path" | LC_ALL=C command grep -P "\t\Q$path\E$" | head -n1) || true
  [[ -n $line ]] || return 1
  printf '%s\n' "${line%%$'\t'*}"
}

# outcome::sfs_count <sfs> <path-or-glob> — how many entries match.
outcome::sfs_count() {
  local sfs=$1 pattern=$2
  outcome::sfs_entries "$sfs" "$pattern" | LC_ALL=C command grep -c '' || true
}

# ---------------------------------------------------------------------------
# THE CHECK BATCHES
#
# Both report through screens::check, so they land in the same denominator as
# the harness's own checks and a run that skipped them cannot look like a run
# that passed them. Each description ends with the finding it guards against.
# ---------------------------------------------------------------------------

outcome::log() { printf '[outcome] %s\n' "$*" >&2; }

# outcome::check_installed_root <root-mount> <repo-root> [uki-name...]
#
# Everything the installed machine needs in order to boot Neptune and reach
# Gaming Mode. Pass the UKI names the harness already discovered on the ESP
# (disk_image::esp_extract_ukis); pass none to skip only the UKI pair, which
# is reported as a FAIL rather than quietly omitted.
outcome::check_installed_root() {
  local root_at=$1 repo_root=$2
  shift 2
  local -a uki_names=("$@")
  local db_dir="$root_at/var/lib/pacman/local"
  local names_file pkg series neptune_pkg path mode found status

  series=$(outcome::neptune_series "$repo_root") || {
    screens::check "the Neptune series is readable from src/omarchy-deck-kernel.sh (this batch cannot run without it)" no yes
    return 1
  }
  neptune_pkg="linux-neptune-${series}"

  names_file=$(mktemp)
  if ! outcome::pacman_pkgnames "$db_dir" >"$names_file"; then
    screens::check "the target's pacman local db is readable at var/lib/pacman/local" no yes
    rm -f "$names_file"
    return 1
  fi
  # Anti-vacuity: an empty db reads as "nothing is installed", which would fail
  # every check below for a reason that has nothing to do with the install.
  local pkg_count
  pkg_count=$(LC_ALL=C command grep -c '' "$names_file" || true)
  screens::check "the target's pacman db was really read (found $pkg_count packages; 0 would fail everything below for the wrong reason)" \
    "$([[ ${pkg_count:-0} -gt 100 ]] && echo yes || echo no)" yes

  # --- packages that must be there ----------------------------------------
  #
  # steamdeck-dsp / linux-neptune-611 / gamescope: docs/findings/P32-steam-never-installed.md
  # steam:        same finding, and the direct cause of the black panel
  # omarchy-deck: our own package; nothing else installs the patch applier
  for pkg in steam steamdeck-dsp "$neptune_pkg" gamescope omarchy-deck; do
    screens::check "installed on the target: $pkg [guards against P32-steam-never-installed]" \
      "$(outcome::package_installed "$names_file" "$pkg" && echo yes || echo no)" yes || true
  done

  # steam is the one package this build fetches ONLINE, at install time, so a
  # missing steam has two very different causes and they need different fixes.
  # The artifact still decides the verdict above; this only says which fix.
  if ! outcome::package_installed "$names_file" steam; then
    status=$(outcome::install_record_status "$root_at" deck_pkgs)
    case $status in
      no-section)
        outcome::log "steam is absent and the install record has NO deck_pkgs section: the online fetch step NEVER RAN. That is P32-steam-never-installed exactly — a package list with no consumer. Fix the installer, not the network." ;;
      no-record)
        outcome::log "steam is absent and there is no /var/log/omarchy-deck-install.json at all: the Deck configure phase did not run, so this is a broader failure than the fetch step." ;;
      no-jq)
        outcome::log "steam is absent; jq is not on PATH so the install record could not be read to say whether the fetch step ran." ;;
      *)
        outcome::log "steam is absent and the install record's deck_pkgs section says status='$status': the fetch step RAN and did not deliver. Read that section's error field — this is a fetch failure, not a missing step." ;;
    esac
  fi

  # --- and the one that must NOT be ---------------------------------------
  #
  # Neptune only. Stock `linux` on the target means a second kernel, a second
  # UKI, and a Limine boot order to choose between them — and it is what the
  # 2026-08-15 image actually booted (linux 7.1.8.arch1-3), because nothing
  # ever installed the Neptune kernel the mirror was carrying.
  screens::check "NOT installed on the target: stock 'linux' (Neptune only) [guards against P32-steam-never-installed §'deck-mirror.packages has the same shape of problem']" \
    "$(outcome::package_installed "$names_file" linux && echo present || echo absent)" absent || true
  rm -f "$names_file"

  # --- files something else will open -------------------------------------
  #
  # Each of these is a path a DIFFERENT program looks for, which is why a
  # package check is not enough on its own:
  #   the steam bootstrap tarball   steam-launcher.service untars it at first
  #                                 boot; its absence is the literal error in
  #                                 the P32 journal
  #   /usr/bin/steamos-session-select   Steam's "Switch to Desktop" runs it via
  #                                 PATH, and /usr/local/bin is NOT on the PATH
  #                                 Steam's runtime hands it (src/deck-session.sh)
  #   the two polkit helpers        Steam calls them by absolute path
  #   /usr/local/bin/deck-input-mapper  the target-side OSK
  #   gamescope-wayland.desktop     deck_autologin.py's GAMING_SESSION
  for path in \
    /usr/lib/steam/bootstraplinux_ubuntu12_32.tar.xz \
    /usr/bin/steamos-session-select \
    /usr/bin/steamos-polkit-helpers/steamos-update \
    /usr/bin/steamos-polkit-helpers/steamos-priv-write \
    /usr/local/bin/deck-input-mapper \
    /usr/share/wayland-sessions/gamescope-wayland.desktop; do
    screens::check "present on the target: $path [guards against P32-steam-never-installed]" \
      "$([[ -e "$root_at$path" ]] && echo yes || echo no)" yes || true
  done

  # --- the UKI ------------------------------------------------------------
  if (( ${#uki_names[@]} == 0 )); then
    screens::check "UKI names were handed to the outcome checks (0 means the ESP was never read, which is not a pass)" no yes
  else
    screens::check "exactly one UKI on the ESP (a second kernel means a boot order to choose; found ${#uki_names[@]}: ${uki_names[*]})" \
      "${#uki_names[@]}" 1
    found=no
    for path in "${uki_names[@]}"; do
      outcome::uki_matches_pkgbase "$path" "$neptune_pkg" && found=yes
    done
    screens::check "the UKI is the Neptune one: <prefix>_${neptune_pkg}.efi (found: ${uki_names[*]}) [guards against P32-steam-never-installed §'the installed system runs stock linux']" \
      "$found" yes
  fi

  return 0
}

# outcome::check_live_iso <iso-path> <repo-root>
#
# The other half of the same defect, asked of the image you BOOT rather than
# the one you install: docs/findings/P32-osk-mapper-missing-from-live-iso.md.
# The mapper has to be in the live root, and it has to be EXECUTABLE there —
# mkarchiso copies airootfs with `cp -af --no-preserve=ownership,mode`, so a
# file staged 0755 on the host lands 0644 in the image unless profiledef.sh's
# file_permissions array says otherwise. Present-but-0644 reports itself as
# "mapper not found", which is why the mode is asserted and not just the path.
outcome::check_live_iso() {
  local iso=$1 repo_root=$2
  local loop_dev mount_point sfs mapper_mode evdev_count mapper_path
  # The mapper's path in the live root is the installer's own literal, read
  # from deck-form.sh — the same derivation iso/bin/build's staging step and
  # guard 6.7 use. Never spelled here: a hard-coded path would pass against an
  # ISO whose screens look somewhere else entirely.
  mapper_path=$(grep -oE '^readonly DECK_MAPPER_BIN=[^[:space:]]+' \
    "$repo_root/iso/overlay/configs/airootfs/usr/share/omarchy-iso/deck-form.sh" 2>/dev/null |
    LC_ALL=C command sed -E 's|^readonly DECK_MAPPER_BIN=||' | head -n1) || true
  if [[ -z $mapper_path ]]; then
    screens::check "deck-form.sh's DECK_MAPPER_BIN is readable (the live-ISO checks cannot run without it)" no yes
    return 1
  fi

  if ! outcome::sfs_reader >/dev/null; then
    screens::check "a squashfs reader (7z) is on PATH so the live ISO can be inspected [guards against P32-osk-mapper-missing-from-live-iso]" no yes
    return 1
  fi

  if ! read -r loop_dev mount_point < <(outcome::iso_mount "$iso"); then
    screens::check "the live ISO could be loop-mounted read-only for inspection" no yes
    return 1
  fi

  # No RETURN trap: `trap ... RETURN` set inside a function is GLOBAL unless
  # the shell runs with `set -T`, so it would fire again on the next function
  # the harness returns from. Unmount explicitly instead, on both paths.
  if ! sfs=$(outcome::iso_sfs "$mount_point"); then
    screens::check "the live ISO carries an airootfs squashfs" no yes
    outcome::iso_unmount "$loop_dev"
    return 1
  fi
  outcome::log "live ISO root filesystem: ${sfs#"$mount_point"/}"

  # Anti-vacuity first: if the reader returns nothing for a path upstream
  # certainly ships, every check below would "prove" absence of everything.
  local control_count
  control_count=$(outcome::sfs_count "$sfs" 'usr/local/bin/*')
  screens::check "the squashfs reader really read the image (found $control_count entries under usr/local/bin; 0 means the reader failed, not that the ISO is empty)" \
    "$([[ ${control_count:-0} -gt 0 ]] && echo yes || echo no)" yes

  # ⚠️ Paths inside the squashfs are relative — no leading slash.
  mapper_mode=$(outcome::sfs_mode "$sfs" "${mapper_path#/}") || mapper_mode=""
  screens::check "the live ISO carries $mapper_path [guards against P32-osk-mapper-missing-from-live-iso]" \
    "$([[ -n $mapper_mode ]] && echo yes || echo no)" yes
  # The mode bit, separately: present-and-0644 is a DIFFERENT bug from absent,
  # and deck-form.sh reports both as "mapper not found".
  screens::check "...and it is executable in the image (mode '${mapper_mode:-<absent>}'; archiso's --no-preserve=mode strips the host's bit) [guards against P32-osk-mapper-missing-from-live-iso]" \
    "$([[ $mapper_mode == *x* ]] && echo yes || echo no)" yes

  evdev_count=$(outcome::sfs_count "$sfs" 'var/lib/pacman/local/python-evdev-*')
  screens::check "python-evdev is installed in the live root (the mapper imports evdev at module scope; found $evdev_count db entries) [guards against P32-osk-mapper-missing-from-live-iso]" \
    "$([[ ${evdev_count:-0} -gt 0 ]] && echo yes || echo no)" yes

  outcome::iso_unmount "$loop_dev"
  return 0
}
