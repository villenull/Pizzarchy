#!/usr/bin/env bash
# omarchy-deck-kernel.sh
#
# Self-contained Neptune kernel + Limine UKI setup for Steam Deck, for a
# system installed from Omarchy Quattro (archinstall + Limine + UKI).
#
# Fixes the upstream bugs in PLAN.md §8:
#   8.1 - No dependency on a separate common-script.sh fetched via a
#         relative path. Safe to run via `curl | bash`. Every stage
#         verifies the state it claims to have produced, so no code path
#         can print progress while having done nothing.
#   8.2 - Real Limine support instead of "No supported bootloader
#         detected". The Limine config path is probed across all five
#         candidate locations, never hardcoded.
#   8.3 - The real ESP is detected, never assumed to be /boot or /efi.
#   8.4 - No AUR helper is installed as a side effect.
#   8.5 - The ESP's fmask/dmask is loosened so user-space scripts
#         (including Omarchy's own limine-snapper.sh) can read the Limine
#         config, via a full umount/mount cycle -- a soft `mount -o
#         remount` does NOT re-apply fmask/dmask on vfat. See the
#         SECURITY TRADEOFF note in stage_esp_permissions().
#
# Idempotent and re-runnable: running it twice in a row leaves byte-identical
# state (proven, not asserted -- see vm-kernel-idempotency-test.sh).
#
# ---------------------------------------------------------------------------
# T1 REVIEW FINDINGS (2026-08-08) -- why this is a rewrite, not a tidy-up
# ---------------------------------------------------------------------------
# The previous draft of this file was written from a manual install done on
# an older package set and had never been executed anywhere. Reviewing it
# against a real Omarchy Quattro install image and against the packages
# Valve actually publishes today turned up four premises that no longer
# hold. All four would have caused a hard failure or a wrong boot entry:
#
#   1. Valve's kernel packages no longer ship /boot/vmlinuz-<pkg>, and no
#      longer ship an /etc/mkinitcpio.d/<pkg>.preset at all. Verified by
#      unpacking linux-neptune-611-6.11.11.valve29-1 and
#      linux-neptune-618-6.18.39.valve1-1: each contains exactly
#      usr/lib/modules/<kver>/{pkgbase,vmlinuz} and nothing under /boot or
#      /etc. The draft's existence checks for both files, and its entire
#      "patch default_uki in the preset" stage, were therefore dead ends.
#      PLAN.md §8.3's preset bug is real but is now moot on current
#      packages -- there is no preset to be wrong.
#
#   2. Omarchy Quattro does not use mkinitcpio presets to build UKIs. It
#      uses limine-mkinitcpio-hook, whose pacman hook enumerates
#      /usr/lib/modules/*/pkgbase and builds
#      $ESP/EFI/Linux/<prefix>_<pkgbase>.efi for every installed kernel,
#      then registers it with `limine-entry-tool --add-uki`. <prefix> is
#      CUSTOM_UKI_NAME from /etc/default/limine when set ("omarchy" on
#      Quattro) and the machine-id otherwise -- so the path is discovered,
#      never constructed (see find_uki_for).
#      Installing the Neptune kernel is therefore *most* of the job; this
#      script's real work is making sure that machinery actually ran and
#      producing a loud failure when it did not.
#
#   3. The stock Limine config on a real Omarchy Quattro install has no
#      `/Arch Linux (linux)` entry. It is a nested tree written by
#      limine-entry-tool (`/+Omarchy` -> `//linux`), and the `path:` line
#      carries a blake2b hash of the UKI. The draft's awk cmdline
#      extraction matched nothing there, and its hand-rolled `tee -a` of a
#      flat top-level entry would have appended an entry outside the OS
#      branch, with no hash, that limine-entry-tool would later clobber.
#      Both are gone: the cmdline now comes from the supported source
#      (/etc/default/limine via limine-entry-tool) and entries are created
#      by limine-entry-tool itself.
#
#   4. `linux-neptune-611` is four series behind. Valve currently ships
#      series 60, 61, 65, 68, 611, 615, 616, 618 and 72. See the
#      NEPTUNE_SERIES constant below for why this script still pins 611
#      and how to move the pin.
#
# Deliberate scope decision: this script supports the limine-mkinitcpio-hook
# UKI mechanism only. A plain-archinstall Limine system without that hook
# gets a loud, actionable failure rather than an untested attempt to hand-
# write its boot chain. Shipping an untested code path that mutates a boot
# chain is the same class of defect as PLAN.md §8.1 -- it looks like it
# worked right up until the device does not boot.
#
# Still TODO in later T1 steps (not this change):
#   - Non-interactive flags + independently runnable stages (steps 4, 6).
#   - The §8.5 upstream reproduction and issue (step 5).
#
# ---------------------------------------------------------------------------
# T1 STEP 3 (2026-08-08) -- the pacman hook, and what upstream already does
# ---------------------------------------------------------------------------
# See the long comment block in hook_text() below, which is written verbatim
# into /etc/pacman.d/hooks/95-omarchy-deck-kernel.hook so the reasoning lives
# next to the artifact on the installed system. Summary: upstream's
# limine-mkinitcpio-hook already covers UKI *generation* on install/upgrade
# and *deregistration* on remove, so this script's hook does not rebuild
# anything by default -- it verifies what upstream produced and repairs it
# only when the verification fails. Usage:
#
#   omarchy-deck-kernel.sh              full install run (unchanged)
#   omarchy-deck-kernel.sh reconcile    verify/repair UKIs + Limine entries
#                                       only; what the pacman hook calls.

set -euo pipefail

readonly PROG=omarchy-deck-kernel

log()  { printf '[%s] %s\n' "$PROG" "$*"; }

# Failures also go to syslog. When this runs from the pacman hook the console
# output is one line among a hundred and scrolls away immediately, and a
# PostTransaction hook cannot roll anything back -- so the only thing that
# makes the failure findable afterwards is the journal.
fail() {
  printf '[%s] ERROR: %s\n' "$PROG" "$*" >&2
  if command -v logger >/dev/null 2>&1; then
    logger -p err -t "$PROG" -- "$*" 2>/dev/null || true
  fi
  exit 1
}

# ---------------------------------------------------------------------------
# The kernel version constant. This is the ONLY place a Neptune version
# appears in this script -- package name, UKI filename and Limine entry name
# are all derived from it, and every regeneration/prune path below is keyed
# on the `linux-neptune-*` glob rather than on this value.
#
# WHY PINNED RATHER THAN "TRACK LATEST" (PLAN.md §11, task step 2):
#
#   * The series suffix is not orderable. Valve's published series are
#     60, 61, 65, 68, 611, 615, 616, 618, 72. Sorted as integers, 618 > 72;
#     sorted as text, "68" > "618". Neither is right -- 72 (7.2.x) is the
#     newest. "Latest" cannot be computed from the package name at all, so
#     any auto-latest scheme is guessing.
#   * "Latest" is currently a release candidate. linux-neptune-72 is
#     7.2.0.rc3.valve.beta1. Auto-tracking would silently move users onto a
#     beta kernel during a routine `pacman -Syu`.
#   * The whole point of this project is that a wrong boot-chain guess is
#     expensive to discover. A pin that needs a one-line human bump is the
#     cheap failure; an auto-bump onto an unvalidated kernel is not.
#
# What *is* dynamic: the script reads the repos to confirm the pinned series
# actually exists, and tells you exactly which series are available if it
# does not (see stage_kernel). It never silently falls back to another one.
#
# TO MOVE THE PIN: change NEPTUNE_SERIES_DEFAULT, test on hardware, and note
# the validated series in PROGRESS.md. Override for a one-off test with
# OMARCHY_DECK_NEPTUNE_SERIES=618 ./omarchy-deck-kernel.sh
#
# 611 is the series validated live on the operator's OLED Deck. Nothing
# newer has been validated on hardware, and per CLAUDE.md untested hardware
# claims do not ship.
# ---------------------------------------------------------------------------
readonly NEPTUNE_SERIES_DEFAULT=611

NEPTUNE_SERIES=${OMARCHY_DECK_NEPTUNE_SERIES:-$NEPTUNE_SERIES_DEFAULT}
[[ $NEPTUNE_SERIES =~ ^[0-9]+$ ]] ||
  fail "OMARCHY_DECK_NEPTUNE_SERIES must be digits only (e.g. 611, 618, 72), got: '$NEPTUNE_SERIES'"
readonly NEPTUNE_SERIES
readonly KERNEL_PKG="linux-neptune-${NEPTUNE_SERIES}"

# Glob (not the pinned version) used by every enumerate/prune path, so a
# version bump reconciles stale entries instead of stacking duplicates.
readonly NEPTUNE_PKGBASE_GLOB='linux-neptune-*'

# Valve repos. steamdeck-dsp and linux-firmware-neptune both live in
# jupiter-staging; holo-staging is added because Omarchy's Deck packages
# expect it to be present, not because this script pulls from it.
readonly -a VALVE_REPOS=(jupiter-staging holo-staging)
# shellcheck disable=SC2016 # $repo/$arch are pacman's own variables and must reach pacman.conf unexpanded
readonly VALVE_MIRROR='https://steamdeck-packages.steamos.cloud/archlinux-mirror/$repo/os/$arch'

# Limine config candidate locations, relative to the ESP. Limine's config
# path is not stable across versions (PLAN.md §8.2); Omarchy's own
# limine-snapper.sh probes exactly these five. Never hardcode one.
readonly -a LIMINE_CONFIG_CANDIDATES=(
  /EFI/arch-limine/limine.conf
  /EFI/BOOT/limine.conf
  /EFI/limine/limine.conf
  /limine/limine.conf
  /limine.conf
)

# The pacman hook installed by stage_hook, and the copy of this script it
# calls. /etc/pacman.d/hooks is the admin hook directory; /usr/share/libalpm/
# hooks is for package-shipped hooks. This is installed by a script today, so
# /etc is the correct location -- and when the Deck logic becomes its own
# pacman package (FINDING-R1-10.1), the package can ship the SAME basename
# under /usr/share/libalpm/hooks: pacman de-duplicates hooks by filename with
# /etc winning, so the two never both fire, and removing the /etc copy hands
# over cleanly to the packaged one.
readonly HOOK_DIR=/etc/pacman.d/hooks
readonly HOOK_NAME=95-omarchy-deck-kernel.hook
readonly HOOK_PATH="${HOOK_DIR}/${HOOK_NAME}"
readonly HOOK_SCRIPT_PATH=/usr/local/bin/omarchy-deck-kernel

# Set by stage_preconditions/stage_esp_detect, consumed by later stages.
SUDO=""
ESP_PATH=""
LIMINE_CONFIG=""

# ---------------------------------------------------------------------------
# Stage 0: preconditions
# ---------------------------------------------------------------------------

stage_preconditions() {
  local tool
  for tool in pacman findmnt mount umount install; do
    command -v "$tool" >/dev/null 2>&1 ||
      fail "required tool '$tool' not found -- this script only supports Arch-based systems"
  done

  if [[ $EUID -eq 0 ]]; then
    SUDO=""
  else
    command -v sudo >/dev/null 2>&1 ||
      fail "not running as root and sudo not found"
    SUDO="sudo"
    # Prove escalation actually works now rather than failing halfway
    # through a boot-chain edit.
    $SUDO -n true 2>/dev/null || $SUDO true ||
      fail "sudo escalation failed -- re-run as root or fix sudo before touching the boot chain"
  fi

  # Deck hardware gate. product_name is "Jupiter" (LCD) or "Galileo" (OLED);
  # sys_vendor is "Valve". Only OLED is verified hardware (CLAUDE.md) -- the
  # LCD string is accepted here because refusing to run is worse than running
  # on an untested-but-plausible Deck, but nothing downstream claims LCD
  # support.
  local product="" vendor=""
  if [[ -r /sys/class/dmi/id/product_name ]]; then product=$(</sys/class/dmi/id/product_name); fi
  if [[ -r /sys/class/dmi/id/sys_vendor ]];   then vendor=$(</sys/class/dmi/id/sys_vendor);   fi
  if ! [[ ${product,,} =~ (steam\ deck|jupiter|galileo) || ${vendor,,} == *valve* ]]; then
    fail "not Steam Deck hardware (DMI product_name='${product:-<unreadable>}' sys_vendor='${vendor:-<unreadable>}'). Refusing to modify the boot chain."
  fi
  log "hardware: ${vendor:-unknown} ${product:-unknown}"

  # The UKI mechanism this script drives. See T1 REVIEW FINDINGS #2 above.
  command -v limine-entry-tool >/dev/null 2>&1 ||
    fail "limine-entry-tool not found. This script drives Omarchy Quattro's limine-mkinitcpio-hook UKI mechanism and does not hand-write boot entries. Install limine-mkinitcpio-hook (and limine), or boot-chain setup has to be done another way -- see the scope note at the top of this file."
  command -v limine-mkinitcpio >/dev/null 2>&1 ||
    fail "limine-mkinitcpio not found although limine-entry-tool is present -- the limine-mkinitcpio-hook install looks broken. Reinstall it rather than continuing."

}

# ---------------------------------------------------------------------------
# Stage 1: Valve repos
# ---------------------------------------------------------------------------

stage_repos() {
  local repo added=0
  for repo in "${VALVE_REPOS[@]}"; do
    if grep -qE "^\[${repo}\]" /etc/pacman.conf; then
      log "repo ${repo}: already in /etc/pacman.conf"
      continue
    fi
    log "repo ${repo}: adding to /etc/pacman.conf"
    # SigLevel = Never: Valve's mirror is unsigned for these repos. This is
    # a real trust reduction, scoped to these two repo sections only.
    $SUDO tee -a /etc/pacman.conf >/dev/null <<EOF

[${repo}]
Server = ${VALVE_MIRROR}
SigLevel = Never
EOF
    # Verify the append landed. `tee` can succeed into a full or read-only
    # filesystem in ways that leave nothing behind (PLAN.md §8.1).
    grep -qE "^\[${repo}\]" /etc/pacman.conf ||
      fail "wrote [${repo}] to /etc/pacman.conf but it is not there on re-read -- is / read-only or full?"
    added=$((added + 1))
  done

  log "syncing package databases"
  $SUDO pacman -Sy --noconfirm >/dev/null ||
    fail "pacman -Sy failed -- check network and the Valve mirror"

  # Verify the sync actually produced usable databases for the repos we
  # just claimed to add, instead of trusting pacman's exit code.
  for repo in "${VALVE_REPOS[@]}"; do
    pacman -Sl "$repo" >/dev/null 2>&1 ||
      fail "repo '${repo}' has no usable package database after pacman -Sy"
  done
  log "repos ready (${added} added this run, $(( ${#VALVE_REPOS[@]} - added )) already present)"
}

# ---------------------------------------------------------------------------
# Stage 2: ESP detection (PLAN.md §8.3 -- never assume a path)
#
# Replaces the previous draft's findmnt-into-findmnt chain, which could
# return multiple lines when one device is mounted at several points, and
# which never checked that what it found was actually a FAT ESP.
# ---------------------------------------------------------------------------

# esp_is_valid <path> -- mounted, vfat, and looks like an ESP.
esp_is_valid() {
  local path=$1 fstype
  findmnt --mountpoint "$path" >/dev/null 2>&1 || return 1
  fstype=$(findmnt -n -o FSTYPE --mountpoint "$path" 2>/dev/null) || return 1
  [[ $fstype == vfat ]] || return 1
  # Elevated: before stage_esp_permissions runs, the ESP is mounted 0700 and
  # an unprivileged `[[ -d /boot/EFI ]]` is false for a directory that exists.
  # That is bug §8.5 itself, and testing it unprivileged here would make the
  # real ESP look like it was not an ESP.
  $SUDO test -d "$path/EFI" || return 1
  return 0
}

stage_esp_detect() {
  local -a candidates=()

  # /etc/default/limine is authoritative on a limine-mkinitcpio-hook system:
  # it is the same value the UKI-building hook itself uses, so agreeing with
  # it is what keeps this script and the hook writing to the same place.
  if [[ -r /etc/default/limine ]]; then
    local declared
    declared=$(sed -nE 's/^[[:space:]]*ESP_PATH[[:space:]]*=[[:space:]]*"?([^"#]*[^"#[:space:]])"?.*/\1/p' \
      /etc/default/limine | tail -n 1)
    if [[ -n $declared ]]; then candidates+=("$declared"); fi
  fi
  candidates+=(/boot /efi /boot/efi)

  local c
  for c in "${candidates[@]}"; do
    if esp_is_valid "$c"; then
      ESP_PATH=$c
      break
    fi
  done
  [[ -n $ESP_PATH ]] ||
    fail "no mounted vfat ESP found at any of: ${candidates[*]}. Run 'findmnt -t vfat' and mount the ESP before re-running."
  readonly ESP_PATH

  log "ESP: ${ESP_PATH} ($(findmnt -n -o SOURCE --mountpoint "$ESP_PATH"))"

  # Limine config: probe all five candidates (PLAN.md §8.2). Read as root --
  # on an unfixed ESP the invoking user cannot traverse /boot at all, which
  # is exactly bug §8.5 and would make every candidate look absent.
  local candidate
  for candidate in "${LIMINE_CONFIG_CANDIDATES[@]}"; do
    if $SUDO test -f "${ESP_PATH}${candidate}"; then
      LIMINE_CONFIG="${ESP_PATH}${candidate}"
      break
    fi
  done
  [[ -n $LIMINE_CONFIG ]] ||
    fail "no Limine config at any candidate location under ${ESP_PATH}: ${LIMINE_CONFIG_CANDIDATES[*]}. This project requires Limine (PLAN.md §6.3) -- GRUB and systemd-boot are not supported."
  log "Limine config: ${LIMINE_CONFIG}"
  readonly LIMINE_CONFIG
}

# ---------------------------------------------------------------------------
# Stage 3: kernel + firmware
# ---------------------------------------------------------------------------

# neptune_series_available -- every linux-neptune-<digits> package name the
# configured repos offer, one per line. Excludes -headers, -wip, -kasan,
# -drm-exec and similar variants.
neptune_series_available() {
  local repo
  for repo in "${VALVE_REPOS[@]}"; do
    pacman -Sl "$repo" 2>/dev/null | awk '$2 ~ /^linux-neptune-[0-9]+$/ { print $2 }'
  done | sort -u
}

# installed_neptune_pkgbases -- pkgbase of every installed Neptune kernel,
# read from /usr/lib/modules/*/pkgbase (the same source limine-mkinitcpio-hook
# uses). Glob-keyed, so it sees every version, not just the pinned one.
installed_neptune_pkgbases() {
  local f name
  for f in /usr/lib/modules/*/pkgbase; do
    [[ -f $f ]] || continue
    name=$(<"$f")
    # shellcheck disable=SC2053 # intentional glob match, not a string compare
    if [[ $name == $NEPTUNE_PKGBASE_GLOB ]]; then printf '%s\n' "$name"; fi
  done | sort -u
}

# kernel_module_dir <pkgbase> -- /usr/lib/modules/<kver> for an installed
# kernel, or empty.
kernel_module_dir() {
  local want=$1 f
  for f in /usr/lib/modules/*/pkgbase; do
    if [[ -f $f && $(<"$f") == "$want" ]]; then
      printf '%s\n' "${f%/pkgbase}"
      return 0
    fi
  done
  return 1
}

# colliding_arch_firmware -- installed linux-firmware* packages that Valve's
# linux-firmware-neptune will collide with on disk.
#
# Arch split linux-firmware into per-vendor subpackages
# (linux-firmware-amdgpu, -atheros, -other, ...) with the old name kept as a
# metapackage. Valve's linux-firmware-neptune still declares
# conflicts/replaces against only `linux-firmware` and `linux-firmware-whence`,
# so pacman happily removes those two and then dies in the file-conflict
# check against the ten subpackages nobody declared anything about:
#   "linux-firmware-neptune: /usr/lib/firmware/... exists in filesystem
#    (owned by linux-firmware-other)"
# Found by running this script in a VM (vm-kernel-idempotency-test.sh), not
# by reading the PKGBUILDs. This is an upstream packaging gap on Valve's side
# and a candidate for the DRAFT-upstream-bugs report.
#
# Prints one package name per line; empty output means nothing collides.
colliding_arch_firmware() {
  pacman -Qq 2>/dev/null |
    grep -E '^linux-firmware(-[a-z0-9-]+)?$' |
    grep -vE 'neptune|^linux-firmware-whence$' || true
}

# stage_firmware_swap -- make room for Valve's firmware, idempotently.
#
# NOT done with --overwrite: overwriting would leave the Arch subpackages
# still owning those paths, so the next `pacman -Syu` would silently restore
# Arch's firmware over Valve's and nobody would find out until hardware
# misbehaved. Removing the packages is the honest end state, and it is what
# SteamOS itself ships.
stage_firmware_swap() {
  local -a colliding=()
  mapfile -t colliding < <(colliding_arch_firmware)

  if [[ ${#colliding[@]} -eq 0 ]]; then
    log "firmware: no Arch linux-firmware packages left to displace"
    return 0
  fi

  if pacman -Qq linux-firmware-neptune >/dev/null 2>&1; then
    log "firmware: linux-firmware-neptune already installed alongside ${colliding[*]} -- leaving them alone"
    return 0
  fi

  log "firmware: removing Arch's split linux-firmware packages so Valve's can be installed: ${colliding[*]}"
  # -dd because linux-firmware is a hard dependency of every installed kernel;
  # the replacement is installed immediately below, in the same script run.
  $SUDO pacman -Rdd --noconfirm "${colliding[@]}" ||
    fail "could not remove Arch's linux-firmware packages (${colliding[*]}). Nothing has been changed; the system still has its original firmware."

  local remaining
  remaining=$(colliding_arch_firmware | tr '\n' ' ')
  [[ -z ${remaining// /} ]] ||
    fail "pacman -Rdd exited 0 but these are still installed: ${remaining}. THE SYSTEM MAY NOW HAVE PARTIAL FIRMWARE -- run 'pacman -S linux-firmware' before rebooting."
}

stage_kernel() {
  local -a available
  mapfile -t available < <(neptune_series_available)
  [[ ${#available[@]} -gt 0 ]] ||
    fail "the Valve repos returned no linux-neptune-* packages at all -- the mirror layout may have changed"

  local found=0 pkg
  for pkg in "${available[@]}"; do
    if [[ $pkg == "$KERNEL_PKG" ]]; then found=1; break; fi
  done
  # Loud, actionable, never a silent fallback to a different kernel.
  [[ $found -eq 1 ]] ||
    fail "pinned kernel '${KERNEL_PKG}' is not available in the Valve repos. Available: ${available[*]}. Update NEPTUNE_SERIES_DEFAULT in this script (and validate on hardware) rather than picking one at runtime."

  log "installing ${KERNEL_PKG} + firmware (pinned series ${NEPTUNE_SERIES}; ${#available[@]} series available upstream)"

  # --ask=4 is ALPM_QUESTION_CONFLICT_PKG, and it is load-bearing.
  #
  # linux-firmware-neptune declares `replaces`/`conflicts`/`provides` against
  # stock linux-firmware. pacman only honours `replaces` during a full -Su;
  # under a targeted -S it surfaces as "linux-firmware-neptune and
  # linux-firmware are in conflict. Remove linux-firmware? [y/N]", whose
  # default is *No* -- so plain --noconfirm aborts the whole transaction with
  # "unresolvable package conflicts". Found by running this in a VM
  # (vm-kernel-idempotency-test.sh); it is the same shape of bug as PLAN.md
  # §8.4's yay/yay-bin conflict.
  #
  # --ask=4 pre-answers only the conflict question, not every question, so a
  # corrupted package or an unexpected provider choice still stops the run.
  # A whole-system -Syu would also work but would drag an unrelated full
  # upgrade into a kernel script.
  $SUDO pacman -S --needed --noconfirm --ask=4 \
    "${KERNEL_PKG}" \
    "${KERNEL_PKG}-headers" \
    linux-firmware-neptune \
    steamdeck-dsp ||
    fail "kernel/firmware package installation failed. If stage_firmware_swap removed Arch's linux-firmware packages just before this, the system is currently without firmware -- run 'pacman -S linux-firmware' before rebooting."

  # Verify against the filesystem and the local db, not pacman's exit code
  # (PLAN.md §8.1).
  local moddir
  moddir=$(kernel_module_dir "$KERNEL_PKG") ||
    fail "pacman reported success but no /usr/lib/modules/*/pkgbase contains '${KERNEL_PKG}'. Nothing was actually installed; do not reboot."
  [[ -f "$moddir/vmlinuz" ]] ||
    fail "kernel modules dir ${moddir} exists but has no vmlinuz -- the package layout changed, see PLAN.md §11"

  local p
  for p in "${KERNEL_PKG}" "${KERNEL_PKG}-headers" linux-firmware-neptune steamdeck-dsp; do
    pacman -Qq "$p" >/dev/null 2>&1 ||
      fail "pacman exited 0 but '${p}' is not in the local package database"
  done

  log "kernel installed: ${KERNEL_PKG} (${moddir##*/})"
}

# ---------------------------------------------------------------------------
# Stage 4: UKI + Limine entry
#
# limine-mkinitcpio-hook's pacman hook does this automatically on a fresh
# install. This stage exists to (a) verify it really happened and (b)
# reconcile the case where it did not run -- notably a re-run where
# `pacman -S --needed` is a no-op, so no hook fires.
# ---------------------------------------------------------------------------

# find_uki_for <pkgbase> -- the UKI limine-mkinitcpio-hook built for a kernel,
# discovered rather than constructed.
#
# The filename prefix is NOT predictable: limine-mkinitcpio-install uses
# CUSTOM_UKI_NAME from /etc/default/limine when it is set and matches
# ^[a-z0-9]+$, and the machine-id otherwise. Omarchy Quattro sets it to
# "omarchy", so the real files are `omarchy_linux.efi`,
# `omarchy_linux-neptune-611.efi` -- an earlier version of this script
# assumed the machine-id form and looked for a file that never existed.
# Discovering the path keeps the "never assume a path" property that the
# whole of PLAN.md §8.3 is about.
#
# Prints the path, or nothing (exit 1) if there is no match. Fails loudly on
# more than one match: two prefixes for the same kernel means two boot
# entries, and picking either silently would hide that.
find_uki_for() {
  local pkgbase=$1
  local -a matches=()
  mapfile -t matches < <($SUDO find "$ESP_PATH/EFI/Linux" -maxdepth 1 -type f \
    -name "*_${pkgbase}.efi" 2>/dev/null | LC_ALL=C sort)
  case ${#matches[@]} in
    0) return 1 ;;
    1) printf '%s\n' "${matches[0]}" ;;
    *) fail "found ${#matches[@]} UKIs for '${pkgbase}' on the ESP (${matches[*]}). Two boot entries for one kernel -- resolve this by hand before rebooting." ;;
  esac
}

# limine_entry_count <uki-path> -- how many times the Limine config references
# this UKI. limine-entry-tool writes the filename into the entry's `path:`
# line (with a #<blake2b> suffix), so matching the basename is enough.
limine_entry_count() {
  local uki=$1
  $SUDO grep -cF -- "${uki##*/}" "$LIMINE_CONFIG" || true
}

# reconcile_uki <pkgbase> -- verify, and repair only if verification fails,
# the UKI and Limine entry for ONE installed Neptune kernel.
#
# Parameterised by pkgbase (rather than closing over KERNEL_PKG) because the
# pacman hook has to reconcile whatever is installed, which after a pin move
# or a partial upgrade is not necessarily the pinned series.
reconcile_uki() {
  local pkgbase=$1
  local uki moddir
  moddir=$(kernel_module_dir "$pkgbase") ||
    fail "internal error: reconcile_uki called for '${pkgbase}', which has no /usr/lib/modules/*/pkgbase"
  uki=$(find_uki_for "$pkgbase") || uki=""

  # Idempotency rule. Skip only when the artifacts are provably current: the
  # UKI exists, is newer than the kernel image it was built from, and is
  # registered in the Limine config.
  #
  # CORRECTION (measured in vm-kernel-hook-test.sh, 2026-08-08): an earlier
  # version of this comment justified the skip by claiming an initramfs is
  # not byte-reproducible, so a needless rebuild would change the UKI's bytes
  # and therefore the blake2b hash limine-entry-tool records in the config.
  # That is false on current mkinitcpio: rebuilding this UKI from unchanged
  # inputs produced a byte-identical file, sha256 and all. The skip is still
  # right -- rebuilding a 140 MB UKI and rewriting the boot config to say the
  # same thing is minutes of work and an unnecessary write to the boot chain,
  # inside a pacman hook that runs on every kernel change -- but it is a cost
  # and blast-radius argument, not a reproducibility one.
  if [[ -z ${OMARCHY_DECK_FORCE_UKI:-} && -n $uki ]] &&
    $SUDO test "$uki" -nt "$moddir/vmlinuz" &&
    [[ $(limine_entry_count "$uki") -eq 1 ]]; then
    log "UKI up to date: ${uki} (newer than ${moddir}/vmlinuz, registered once in ${LIMINE_CONFIG##*/})"
  else
    log "building UKI for ${pkgbase} via limine-mkinitcpio"
    $SUDO limine-mkinitcpio ||
      fail "limine-mkinitcpio failed -- see output above. The boot entry was not updated."

    uki=$(find_uki_for "$pkgbase") ||
      fail "limine-mkinitcpio exited 0 but no *_${pkgbase}.efi appeared in ${ESP_PATH}/EFI/Linux. Do not reboot; this is exactly the PLAN.md §8.1 failure mode."

    # limine-mkinitcpio registers the entry itself. If it did not, register
    # explicitly -- and verify afterwards rather than assuming the call worked.
    if [[ $(limine_entry_count "$uki") -eq 0 ]]; then
      log "registering Limine entry for ${pkgbase}"
      $SUDO limine-entry-tool --add-uki "$pkgbase" "$uki" \
        --comment "Neptune kernel (${moddir##*/})" ||
        fail "limine-entry-tool --add-uki failed for ${pkgbase}"
    fi
  fi

  # Post-conditions, checked every run including the skip path.
  $SUDO test -f "$uki" || fail "UKI missing at ${uki} after reconcile_uki ${pkgbase}"
  local refs
  refs=$(limine_entry_count "$uki")
  [[ $refs -eq 1 ]] ||
    fail "expected exactly 1 Limine entry referencing ${uki##*/}, found ${refs}. The kernel is installed but its boot entry is wrong -- inspect ${LIMINE_CONFIG} before rebooting."

  log "boot entry verified: ${uki} referenced once in ${LIMINE_CONFIG##*/}"
}

stage_uki() {
  kernel_module_dir "$KERNEL_PKG" >/dev/null ||
    fail "internal error: stage_uki ran without an installed ${KERNEL_PKG}"
  reconcile_uki "$KERNEL_PKG"
}

# ---------------------------------------------------------------------------
# Stage 5: prune stale Neptune artifacts (glob-keyed, per task step 2)
#
# Keyed on the linux-neptune-* glob, never on the pinned version, so moving
# the pin removes the old series' entry instead of leaving a stale one that
# boots a kernel whose modules have been uninstalled.
# ---------------------------------------------------------------------------

stage_prune() {
  local -a installed=()
  mapfile -t installed < <(installed_neptune_pkgbases)

  # Enumerate with an elevated `find`, not a shell glob. Until
  # stage_esp_permissions has run, the ESP is mounted 0700, so a glob
  # expanded as the invoking user matches nothing and this stage would
  # cheerfully report "nothing stale" without ever having been able to look
  # -- PLAN.md §8.1's failure mode, reintroduced.
  local -a uki_files=()
  mapfile -t uki_files < <($SUDO find "$ESP_PATH/EFI/Linux" -maxdepth 1 -type f \
    -name "*_${NEPTUNE_PKGBASE_GLOB}.efi" 2>/dev/null | LC_ALL=C sort)

  local removed=0 f base keep
  for f in "${uki_files[@]}"; do
    [[ -n $f ]] || continue
    base=${f##*/}
    base=${base#*_}
    base=${base%.efi}
    base=${base%-fallback}

    keep=0
    local p
    for p in "${installed[@]}"; do
      if [[ $p == "$base" ]]; then keep=1; break; fi
    done
    if [[ $keep -eq 1 ]]; then continue; fi

    log "pruning stale boot artifact for uninstalled kernel '${base}'"
    $SUDO limine-entry-tool --remove-uki "$base" ||
      fail "limine-entry-tool --remove-uki '${base}' failed -- ${LIMINE_CONFIG} may now reference a kernel that is not installed"
    # Verify the removal instead of trusting the exit code.
    if $SUDO test -f "$f"; then
      $SUDO rm -f "$f" || fail "could not remove stale UKI ${f}"
    fi
    if $SUDO grep -qF -- "${base}.efi" "$LIMINE_CONFIG"; then
      fail "removed the UKI for '${base}' but ${LIMINE_CONFIG} still references it"
    fi
    removed=$((removed + 1))
  done

  if [[ $removed -eq 0 ]]; then
    # State the evidence, not just the verdict: "nothing to do" and "could not
    # look" must never print the same line.
    log "prune: nothing stale (${#uki_files[@]} Neptune UKI(s) on the ESP; installed Neptune kernels: ${installed[*]:-none})"
  else
    log "prune: removed ${removed} stale Neptune boot artifact(s)"
  fi
}

# ---------------------------------------------------------------------------
# Stage 6: the pacman hook (PLAN.md §11, TASK-T1 step 3)
# ---------------------------------------------------------------------------

# stage_reconcile -- what the pacman hook runs. Glob-keyed over every
# installed Neptune kernel, then prune.
#
# Deliberately does NOT include stage_repos (a `pacman -Sy` inside a pacman
# transaction would deadlock on the database lock) or stage_esp_permissions
# (unmounting the ESP mid-transaction, while pacman may still have files open
# on it, is not something a hook gets to do). Everything it does call is
# read-only against the pacman database -- `pacman -Q*` queries take no lock,
# which is also why upstream's own PostTransaction hook can call `pacman -Qqo`.
stage_reconcile() {
  local -a installed=()
  mapfile -t installed < <(installed_neptune_pkgbases)

  if [[ ${#installed[@]} -eq 0 ]]; then
    log "reconcile: no linux-neptune-* kernel is installed -- pruning only"
  else
    log "reconcile: verifying ${#installed[@]} installed Neptune kernel(s): ${installed[*]}"
    local pkgbase
    for pkgbase in "${installed[@]}"; do
      reconcile_uki "$pkgbase"
    done
  fi

  stage_prune
}

# hook_text -- the ALPM hook, written to stdout.
#
# The comment block is part of the artifact on purpose: it is the answer to
# "why does this exist when limine-mkinitcpio-hook already does all of this",
# and the person who asks that is reading the hook file, not this script.
hook_text() {
  cat <<HOOK
# ${HOOK_NAME} -- installed by ${PROG}.sh (TASK-T1 step 3, PLAN.md §11).
# Not shipped by any package yet. Remove this file and ${HOOK_SCRIPT_PATH}
# together; leaving the hook without the script makes every pacman
# transaction fail with "unable to run hook".
#
# ===========================================================================
# WHAT UPSTREAM ALREADY DOES -- verified against limine-mkinitcpio-hook
# 1.36.0-1, by reading the hooks and scripts it actually installs.
# ===========================================================================
#
# This hook does NOT build UKIs and does NOT register Limine entries as its
# normal path, because limine-mkinitcpio-hook already does both, correctly,
# for every kernel package including linux-neptune-*:
#
#   INSTALL / UPGRADE -- /etc/pacman.d/hooks/90-mkinitcpio-install.hook
#     (shipped by limine-mkinitcpio-hook into /etc, where it shadows
#     mkinitcpio's own same-named hook in /usr/share/libalpm/hooks).
#     Triggers: Type=Path, Operation=Install|Upgrade,
#     Target=usr/lib/modules/*/pkgbase  -- plus a second trigger on
#     usr/lib/firmware/* and friends that forces a rebuild of *every*
#     kernel. PostTransaction, NeedsTargets. Runs
#     /usr/share/libalpm/scripts/limine-mkinitcpio-install, which reads each
#     pkgbase file, builds \$ESP/EFI/Linux/<prefix>_<pkgbase>.efi (prefix =
#     CUSTOM_UKI_NAME from /etc/default/limine, else the machine-id) and
#     calls limine-entry-tool --add-uki. A plain \`pacman -S linux-neptune-*\`
#     reinstall counts as Upgrade (libalpm classifies a reinstall as an
#     upgrade because the package is already in the local db), so a reinstall
#     is fully covered.
#
#   REMOVE -- 60-limine-mkinitcpio-remove-pre.hook (PreTransaction, records
#     the pkgbase names into /var/lib/limine/removed_kernels.list) plus
#     90-limine-mkinitcpio-remove-post.hook (PostTransaction, runs
#     limine-mkinitcpio-remove post, which drops the Limine entries and
#     deletes the UKI files -- limine-entry-tool --remove-all deletes files
#     unless --keep-files is passed). So \`pacman -Rns linux-neptune-611\`
#     after a bump to -612 IS cleaned up; that is not the gap.
#
# ===========================================================================
# THE GAPS THIS HOOK ACTUALLY CLOSES
# ===========================================================================
#
# 1. limine-mkinitcpio-install can fail and still exit 0. Every one of its
#    per-kernel error paths is \`error_msg ...; continue\`: a failed
#    mkinitcpio, an empty pkgbase, a missing cmdline. The loop moves on, the
#    script exits 0, and pacman prints nothing unusual -- while the Limine
#    entry still points at the PREVIOUS UKI, whose modules directory the
#    upgrade just deleted. That is PLAN.md §8.1's failure mode exactly:
#    progress printed, nothing done, success reported. The machine looks fine
#    until it is rebooted.
#
# 2. Its whole-run failure path is also quiet. \`initialize_header || exit 1\`
#    fires when the ESP is not mounted (which on this project's systems is
#    one failed umount/mount cycle away, see PLAN.md §8.5). A PostTransaction
#    hook exiting non-zero cannot roll the transaction back, so the kernel is
#    installed with no UKI behind a single terse pacman error line.
#
# 3. limine-mkinitcpio-remove's post_remove never checks whether the removal
#    worked -- limine-entry-tool --remove-all is called unchecked and then
#    /var/lib/limine/removed_kernels.list is deleted unconditionally, so a
#    failed removal is forgotten permanently. The result is a Limine entry
#    pointing at a UKI that is gone. Nothing upstream ever revisits it.
#    stage_prune (glob-keyed on linux-neptune-*, not on any pinned version)
#    reconciles that on the next transaction.
#
# So: this hook VERIFIES, and only repairs when verification fails. For every
# installed linux-neptune-* it asserts the UKI exists, is newer than the
# vmlinuz it was built from, and is referenced exactly once in the Limine
# config; it rebuilds via limine-mkinitcpio only when one of those is false,
# and it prunes UKIs/entries belonging to Neptune kernels that are no longer
# installed. That makes it idempotent by construction -- the healthy path
# writes nothing, so repeat runs cannot duplicate entries.
#
# ===========================================================================
# WHAT THIS HOOK DELIBERATELY DOES NOT DO
# ===========================================================================
#
# The linux-firmware-neptune conflict (the --ask=4 fix in ${PROG}.sh's
# stage_kernel) is NOT handled here, and no ALPM hook can handle it: libalpm
# asks "Remove linux-firmware? [y/N]" during transaction *preparation*, before
# any hook -- including PreTransaction hooks -- has run. There is nothing to
# hook. In practice it only bites on the first swap, which stage_kernel owns;
# once Arch's split linux-firmware-* packages are gone there is nothing left
# to conflict with and a routine \`pacman -Syu\` upgrades
# linux-firmware-neptune in place. It recurs only if something drags Arch's
# linux-firmware back in as a dependency, and the fix for that belongs in
# packaging (a \`conflicts\` entry on the Deck package, T5), not in a hook.
#
# ===========================================================================

[Trigger]
Type = Package
Operation = Install
Operation = Upgrade
Operation = Remove
Target = linux-neptune-*
Target = linux-firmware-neptune

[Action]
Description = Verifying Neptune UKIs and Limine entries (omarchy-deck)
When = PostTransaction
Exec = ${HOOK_SCRIPT_PATH} reconcile
HOOK
}

# script_source_path -- an absolute path to the file this script is running
# from, so stage_hook can install a copy for the hook to call.
#
# Returns non-zero when there is no such file, which is the \`curl | bash\`
# case: bash has already consumed the pipe, so the source cannot be recovered
# from /proc/self/fd either. stage_hook turns that into a loud, actionable
# failure rather than quietly skipping hook installation -- a run that
# reports success without leaving the hook behind would be the §8.1 defect
# in this script instead of in upstream's.
script_source_path() {
  local src=${OMARCHY_DECK_SCRIPT_PATH:-${BASH_SOURCE[0]:-}}
  [[ -n $src && -f $src && -r $src ]] || return 1
  local dir base
  dir=$(cd -- "$(dirname -- "$src")" && pwd) || return 1
  base=$(basename -- "$src")
  printf '%s/%s\n' "$dir" "$base"
}

stage_hook() {
  local src
  src=$(script_source_path) ||
    fail "cannot install the pacman hook: this script is not running from a readable file (\$0='${0}'). Piping it straight into bash works for everything else, but the hook has to call a copy of it on disk. Download it to a file and re-run, or set OMARCHY_DECK_SCRIPT_PATH to its path."

  $SUDO install -d -m 0755 "$HOOK_DIR" ||
    fail "could not create ${HOOK_DIR}"

  # The callable copy. Compared byte-for-byte rather than copied every run:
  # an unconditional copy would change the mtime on every invocation, which
  # is exactly the kind of "idempotent except for the bits nobody snapshots"
  # claim this project does not accept.
  if $SUDO cmp -s "$src" "$HOOK_SCRIPT_PATH" 2>/dev/null; then
    log "hook: ${HOOK_SCRIPT_PATH} already current"
  else
    log "hook: installing ${HOOK_SCRIPT_PATH}"
    $SUDO install -D -m 0755 "$src" "$HOOK_SCRIPT_PATH" ||
      fail "could not install ${HOOK_SCRIPT_PATH}"
  fi

  local tmp_hook
  tmp_hook=$(mktemp) || fail "mktemp failed"
  hook_text >"$tmp_hook" || { rm -f "$tmp_hook"; fail "could not render the pacman hook"; }

  if $SUDO cmp -s "$tmp_hook" "$HOOK_PATH" 2>/dev/null; then
    log "hook: ${HOOK_PATH} already current"
  else
    log "hook: installing ${HOOK_PATH}"
    $SUDO install -D -m 0644 "$tmp_hook" "$HOOK_PATH" ||
      { rm -f "$tmp_hook"; fail "could not install ${HOOK_PATH}"; }
  fi
  rm -f "$tmp_hook"

  # Verify what is on disk, not what install(1) reported (PLAN.md §8.1).
  $SUDO test -x "$HOOK_SCRIPT_PATH" ||
    fail "${HOOK_SCRIPT_PATH} is missing or not executable after installing it"
  $SUDO cmp -s "$src" "$HOOK_SCRIPT_PATH" ||
    fail "${HOOK_SCRIPT_PATH} differs from ${src} after installing it -- is / read-only or full?"

  # An Exec= line pointing at something that does not exist turns every
  # future pacman transaction into a failure, so parse it back out of the
  # installed file and check the target rather than assuming the heredoc
  # rendered correctly.
  local exec_target
  exec_target=$($SUDO sed -nE 's/^Exec[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' "$HOOK_PATH" | head -n 1)
  [[ -n $exec_target ]] ||
    fail "wrote ${HOOK_PATH} but it has no Exec= line on re-read"
  [[ $exec_target == "$HOOK_SCRIPT_PATH" ]] ||
    fail "${HOOK_PATH}'s Exec= points at '${exec_target}', expected '${HOOK_SCRIPT_PATH}'"
  $SUDO test -x "$exec_target" ||
    fail "${HOOK_PATH} would run '${exec_target}', which is not executable -- every pacman transaction would fail. Refusing to leave that in place."

  log "pacman hook ready: ${HOOK_PATH} -> ${HOOK_SCRIPT_PATH} reconcile"
}

# ---------------------------------------------------------------------------
# Stage 7: ESP permissions (PLAN.md §8.5)
#
# SECURITY TRADEOFF -- deliberately visible, not buried:
#   archinstall hardens the ESP to fmask=0077,dmask=0077 on UKI setups, on
#   the defensible grounds that UKIs are bootable executables. Omarchy's own
#   limine-snapper.sh then does `[[ -f <limine.conf> ]]` as the invoking
#   user, which cannot traverse a 0700 /boot, and reports "Limine config not
#   found" for a file that exists. Loosening the mount to
#   fmask=0133,dmask=0022 unblocks that, but it is a global permission
#   loosening applied to work around one script's permission assumption:
#   afterwards, every local user can read the ESP, including the UKIs.
#   The cleaner fix belongs upstream (elevate the existence check). This
#   workaround stays until that lands -- see TASK-T1 step 5.
#
# Also: `mount -o remount` does NOT re-apply fmask/dmask on vfat. A full
# umount/mount cycle is required. This cost real time to learn; do not
# "simplify" it back to a remount.
#
# The check below tests the actual §8.5 symptom (can a non-root user read
# the Limine config?) rather than pattern-matching fstab text, so it cannot
# report success on a system where fstab says one thing and the live mount
# says another.
# ---------------------------------------------------------------------------

# esp_user_readable -- can an unprivileged user stat the Limine config?
# When already running as root there is no invoking user to test as, so
# fall back to reading the live mount options.
esp_user_readable() {
  local target_user=${SUDO_USER:-}
  if [[ $EUID -ne 0 ]]; then
    [[ -r $LIMINE_CONFIG ]]
    return
  fi
  if [[ -n $target_user && $target_user != root ]]; then
    runuser -u "$target_user" -- test -r "$LIMINE_CONFIG"
    return
  fi
  # No unprivileged user available: infer from the live mount options.
  local opts
  opts=$(findmnt -n -o OPTIONS --mountpoint "$ESP_PATH")
  [[ $opts == *fmask=0133* && $opts == *dmask=0022* ]]
}

# esp_holders -- best-effort description of what is keeping the ESP busy, for
# the error message. fuser/lsof are not guaranteed to be installed, so fall
# back to walking /proc rather than printing nothing useful.
esp_holders() {
  if command -v fuser >/dev/null 2>&1; then
    $SUDO fuser -vm "$ESP_PATH" 2>&1 | head -n 20
    return
  fi
  if command -v lsof >/dev/null 2>&1; then
    $SUDO lsof +D "$ESP_PATH" 2>/dev/null | head -n 20
    return
  fi
  local link pid
  for link in /proc/[0-9]*/cwd /proc/[0-9]*/root; do
    if [[ $($SUDO readlink -f "$link" 2>/dev/null) == "$ESP_PATH"* ]]; then
      pid=${link#/proc/}
      pid=${pid%%/*}
      printf '  pid %s: %s\n' "$pid" "$($SUDO cat "/proc/$pid/comm" 2>/dev/null)"
    fi
  done
}

# esp_umount_mount_cycle -- unmount and remount the ESP so vfat re-applies
# fmask/dmask (a soft `mount -o remount` does not).
#
# On an Omarchy Quattro system limine-snapper-sync is a running daemon that
# keeps the ESP busy, so a bare umount fails with "target is busy" -- found in
# a VM, not by reading code. Stop only the units known to hold it, and restart
# whatever was stopped no matter how the rest of this goes; leaving Limine's
# snapshot sync dead because a permission tweak failed would be a worse
# outcome than the permission problem.
esp_umount_mount_cycle() {
  local -a esp_units=(limine-snapper-sync.service limine-snapper-watcher.service)
  local -a stopped=()
  local unit

  restore_units() {
    local u
    for u in "${stopped[@]}"; do
      $SUDO systemctl start "$u" >/dev/null 2>&1 ||
        log "WARNING: could not restart ${u} -- start it by hand"
    done
    stopped=()
  }

  if ! $SUDO umount "$ESP_PATH" 2>/dev/null; then
    for unit in "${esp_units[@]}"; do
      if $SUDO systemctl is-active --quiet "$unit"; then
        log "stopping ${unit} (it holds ${ESP_PATH} open) for the umount/mount cycle"
        $SUDO systemctl stop "$unit" >/dev/null 2>&1 && stopped+=("$unit")
      fi
    done

    if ! $SUDO umount "$ESP_PATH"; then
      local holders
      holders=$(esp_holders)
      restore_units
      fail "could not unmount ${ESP_PATH} -- it is still busy after stopping ${esp_units[*]}. Nothing has been unmounted; /etc/fstab has been updated, so a reboot will apply the new options. Holders:
${holders:-  (could not determine -- install psmisc for fuser)}"
    fi
  fi

  if ! $SUDO mount "$ESP_PATH"; then
    restore_units
    fail "unmounted ${ESP_PATH} but could not mount it again. THE ESP IS CURRENTLY UNMOUNTED -- run 'mount ${ESP_PATH}' before rebooting."
  fi
  restore_units
}

stage_esp_permissions() {
  if esp_user_readable; then
    log "ESP permissions already allow user-space reads of ${LIMINE_CONFIG##*/} (options: $(findmnt -n -o OPTIONS --mountpoint "$ESP_PATH"))"
    return 0
  fi

  local fstab_line
  fstab_line=$(awk -v mp="$ESP_PATH" '$0 !~ /^[[:space:]]*#/ && $2 == mp { print NR; exit }' /etc/fstab) ||
    fstab_line=""
  [[ -n $fstab_line ]] ||
    fail "${ESP_PATH} is not readable by user-space and has no /etc/fstab entry to fix. Add one (or fix the mount options by hand) before re-running."

  log "loosening ${ESP_PATH} mount options to fmask=0133,dmask=0022 (see SECURITY TRADEOFF note in this script)"
  # Never overwrite an existing backup: on a re-run after a failed umount the
  # live fstab is already the edited one, and clobbering the backup with it
  # would destroy the only copy of the original.
  if [[ ! -e "/etc/fstab.${PROG}.bak" ]]; then
    $SUDO cp -a /etc/fstab "/etc/fstab.${PROG}.bak" ||
      fail "could not back up /etc/fstab -- refusing to edit it"
  fi

  local tmp_fstab
  tmp_fstab=$(mktemp) || fail "mktemp failed"

  # Field-aware rewrite of the ESP's line only, never a global sed: an
  # unanchored substitution would rewrite every vfat entry in fstab. Operating
  # on the options *field* rather than on the raw line means a line whose
  # options happen to lack fmask/dmask gets a well-formed comma-separated
  # value appended instead of a regex splice that could produce an
  # unmountable fstab -- and an unmountable /boot is an unbootable machine.
  # shellcheck disable=SC2016 # awk program: $NF/$4 are awk fields, not shell variables
  awk -v ln="$fstab_line" '
    NR != ln { print; next }
    {
      n = split($4, opt, ",")
      out = ""; seen_f = 0; seen_d = 0
      for (i = 1; i <= n; i++) {
        if (opt[i] ~ /^fmask=/) { opt[i] = "fmask=0133"; seen_f = 1 }
        else if (opt[i] ~ /^dmask=/) { opt[i] = "dmask=0022"; seen_d = 1 }
        out = (out == "" ? opt[i] : out "," opt[i])
      }
      if (!seen_f) out = out ",fmask=0133"
      if (!seen_d) out = out ",dmask=0022"
      $4 = out
      print
    }
  ' /etc/fstab >"$tmp_fstab" ||
    fail "failed to rewrite /etc/fstab (original untouched)"

  # Validate the rewrite before installing it. Both checks matter: the right
  # options, and a line that still has fstab's six fields.
  awk -v ln="$fstab_line" 'NR == ln { exit !(NF == 6 && $4 ~ /fmask=0133/ && $4 ~ /dmask=0022/) }' \
    "$tmp_fstab" ||
    fail "the rewritten /etc/fstab line is malformed or missing the new masks -- refusing to install it. Original untouched; the candidate is at ${tmp_fstab}."

  $SUDO install -m 0644 "$tmp_fstab" /etc/fstab ||
    fail "could not install the rewritten /etc/fstab (backup at /etc/fstab.${PROG}.bak)"
  rm -f "$tmp_fstab"

  $SUDO systemctl daemon-reload ||
    fail "systemctl daemon-reload failed after editing /etc/fstab"

  # Full cycle -- a remount does not re-apply fmask/dmask on vfat.
  esp_umount_mount_cycle

  local opts
  opts=$(findmnt -n -o OPTIONS --mountpoint "$ESP_PATH") ||
    fail "${ESP_PATH} is not mounted after the umount/mount cycle"
  [[ $opts == *fmask=0133* && $opts == *dmask=0022* ]] ||
    fail "remounted ${ESP_PATH} but the options did not take effect (got: ${opts}). A soft remount does not re-apply fmask/dmask on vfat -- if this happened after a full cycle, inspect /etc/fstab."
  esp_user_readable ||
    fail "mount options are correct (${opts}) but ${LIMINE_CONFIG} is still not readable by user-space -- check the on-disk permissions of the ESP's directory tree"

  log "ESP permissions fixed (options: ${opts})"
}

# ---------------------------------------------------------------------------

# Minimal argument dispatch. TASK-T1 step 6 will split the install path into
# independently runnable stages; this is deliberately just the two entry
# points step 3 needs, so that work has a clean slate.
usage() {
  cat <<USAGE
usage: ${PROG}.sh [install|reconcile]

  install    (default) full run: Valve repos, kernel + firmware, UKI, Limine
             entry, pacman hook, ESP permissions.
  reconcile  verify -- and repair only if verification fails -- the UKI and
             Limine entry of every installed linux-neptune-* kernel, then
             prune artifacts of ones that are no longer installed. This is
             what ${HOOK_PATH} runs; it touches no repos, installs nothing,
             and never unmounts the ESP.

environment:
  OMARCHY_DECK_NEPTUNE_SERIES  override the pinned series (digits only)
  OMARCHY_DECK_FORCE_UKI       rebuild the UKI even when it verifies clean
  OMARCHY_DECK_SCRIPT_PATH     path to install as ${HOOK_SCRIPT_PATH}
USAGE
}

main() {
  local cmd=${1:-install}
  case $cmd in
    install)
      stage_preconditions
      stage_repos
      stage_esp_detect
      stage_firmware_swap
      stage_kernel
      stage_uki
      stage_prune
      # Before stage_esp_permissions on purpose: the hook is what keeps the
      # boot chain correct across future updates, and it should not be
      # hostage to a umount/mount cycle that can legitimately fail on a busy
      # ESP. After the kernel stages, also on purpose: the hook is only
      # worth installing once this run has proven the machinery it verifies
      # actually works here.
      stage_hook
      stage_esp_permissions

      log "done. Reboot and select the '${KERNEL_PKG}' entry from the Limine menu."
      log "after boot, confirm with: uname -r  (expect it to contain 'neptune-${NEPTUNE_SERIES}')"
      ;;
    reconcile)
      stage_preconditions
      stage_esp_detect
      stage_reconcile
      log "reconcile: done"
      ;;
    -h | --help | help)
      usage
      ;;
    *)
      usage >&2
      fail "unknown command '${cmd}'"
      ;;
  esac
}

main "$@"
