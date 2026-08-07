#!/usr/bin/env bash
# T0 tier-1 test: boot a built ISO in QEMU, drive an unattended install via
# the `cidata` autoinstall drive (omacom-io/omarchy-iso's existing
# mechanism — see vm-cidata.sh), then assert on the *installed disk
# image's artifacts* (partition table, UKI files, Limine config, package
# set, enabled units) rather than log text. PLAN.md §8.1 is why: upstream
# tooling has printed "success" while doing nothing before; a test that
# only checks an exit code or greps a log would have passed on that bug.
#
# Usage: ./vm-install-test.sh <iso-path> [work-dir]
#
# Env vars (all optional):
#   VM_DISK_SIZE_GB        default 16
#   VM_MEM_MB               default 4096
#   VM_SMP                  default min(nproc,4)
#   VM_INSTALL_TIMEOUT_SEC  default 1800 (30 min)
#   VM_HOSTNAME             default test-vm
#   VM_USERNAME             default tester
#   VM_PASSWORD             default tester123
#   VM_EXPECT_UKI           space-separated expected /EFI/Linux/*.efi names
#                           (default: none checked — set once T1 fixes the
#                           preset/UKI filename, PLAN.md §8.3)
#   VM_EXPECT_LIMINE_REF    space-separated substrings expected in the
#                           Limine config (default: none checked)
#   VM_EXPECT_PACKAGES      space-separated pacman package names
#                           (default: the packages this script itself asks
#                           the install to include)
#   VM_EXPECT_UNITS         space-separated systemd unit names to confirm
#                           enabled (default: none — T3 hasn't run yet)
#
# KNOWN GAP (see PROGRESS.md "Local dev-machine limitations" and "T0 §1
# completion-signal gap"): completion detection here is "QEMU's process
# exits" (a clean guest poweroff/shutdown). Today's *unmodified* upstream
# omarchy-iso does not auto-poweroff after a non-interactive cidata
# install — omarchy-install-dashboard leaves an interactive
# confirm-and-reboot prompt unless OMARCHY_UI_AUTO_REBOOT/
# OMARCHY_UI_FAILURE_ACTION are set, and nothing in the cidata path sets
# them (only OMARCHY_UI_INTERACTIVE=no is automatic). Against a stock ISO
# this script will hit VM_INSTALL_TIMEOUT_SEC and exit non-zero with a
# screendump saved for inspection — that is a real, honest failure, not a
# bug in this harness. T5's Deck ISO fork needs a one-line addition to
# `configs/airootfs/root/.automated_script.sh`'s cidata branch:
# `export OMARCHY_UI_AUTO_REBOOT=no OMARCHY_UI_FAILURE_ACTION=exit` and a
# `systemctl poweroff` after the dashboard returns when non-interactive.
# This script has not yet been run against a real ISO end-to-end — no
# Docker/kvm-group/passwordless-sudo on this dev machine to build+boot one
# (see PROGRESS.md). Verify on a machine that has those before trusting
# the completion-detection path.

set -uo pipefail

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=vm-disk-image.sh
source "$SELF_DIR/vm-disk-image.sh"
# shellcheck source=vm-assertions.sh
source "$SELF_DIR/vm-assertions.sh"
# shellcheck source=vm-cidata.sh
source "$SELF_DIR/vm-cidata.sh"

ISO=${1:?"usage: $0 <iso-path> [work-dir]"}
WORK=${2:-$(mktemp -d /tmp/vm-install-test.XXXXXX)}
[[ -f $ISO ]] || { echo "vm-install-test: ISO not found: $ISO" >&2; exit 2; }

DISK_SIZE_GB=${VM_DISK_SIZE_GB:-16}
MEM_MB=${VM_MEM_MB:-4096}
DEFAULT_SMP=$(( $(nproc) < 4 ? $(nproc) : 4 ))
SMP=${VM_SMP:-$DEFAULT_SMP}
INSTALL_TIMEOUT=${VM_INSTALL_TIMEOUT_SEC:-1800}
HOSTNAME_=${VM_HOSTNAME:-test-vm}
USERNAME=${VM_USERNAME:-tester}
PASSWORD=${VM_PASSWORD:-tester123}
read -ra EXPECT_UKI <<<"${VM_EXPECT_UKI:-}"
read -ra EXPECT_LIMINE_REF <<<"${VM_EXPECT_LIMINE_REF:-}"
read -ra EXPECT_PACKAGES <<<"${VM_EXPECT_PACKAGES:-base-devel git omarchy-keyring omarchy-settings omarchy}"
read -ra EXPECT_UNITS <<<"${VM_EXPECT_UNITS:-}"

OVMF_CODE=/usr/share/edk2/x64/OVMF_CODE.4m.fd
OVMF_VARS_TEMPLATE=/usr/share/edk2/x64/OVMF_VARS.4m.fd

log() { printf '[vm-install-test] %s\n' "$*" >&2; }
fail() { log "FAIL: $*"; exit 1; }

[[ -f $OVMF_CODE && -f $OVMF_VARS_TEMPLATE ]] || fail "OVMF firmware not found at $OVMF_CODE / $OVMF_VARS_TEMPLATE (package edk2-ovmf) — see 'Escalate if' in TASK-T0-test-infrastructure.md, this is a Blocked-on-human item, not something to work around"
command -v qemu-system-x86_64 >/dev/null || fail "qemu-system-x86_64 not found"

mkdir -p "$WORK"
log "work dir: $WORK"

disk="$WORK/target.qcow2"
disk_raw="$WORK/target.raw"
ovmf_vars="$WORK/OVMF_VARS.fd"
cidata_img="$WORK/cidata.img"
config_json="$WORK/user_configuration.json"
creds_json="$WORK/user_credentials.json"
qmp_sock="$WORK/qmp.sock"
pidfile="$WORK/qemu.pid"
serial_log="$WORK/serial.log"

disk_bytes=$((DISK_SIZE_GB * 1024 * 1024 * 1024))

log "creating ${DISK_SIZE_GB}G target disk (qcow2, target device /dev/vda)"
qemu-img create -f qcow2 "$disk" "${DISK_SIZE_GB}G" >/dev/null

cp "$OVMF_VARS_TEMPLATE" "$ovmf_vars"

log "rendering cidata autoinstall config (hostname=$HOSTNAME_ user=$USERNAME)"
cidata::render_config /dev/vda "$disk_bytes" "$HOSTNAME_" "$config_json"
cidata::render_credentials "$USERNAME" "$PASSWORD" "$creds_json"
cidata::build_image "$cidata_img" "$config_json" "$creds_json"

log "booting ISO headless (timeout ${INSTALL_TIMEOUT}s)"
qemu-system-x86_64 \
  -cpu host -enable-kvm -machine q35,accel=kvm \
  -smp "$SMP" -m "$MEM_MB" \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
  -drive if=pflash,format=raw,file="$ovmf_vars" \
  -drive file="$disk",format=qcow2,if=none,id=drive0 \
  -device virtio-blk-pci,drive=drive0,bootindex=1 \
  -drive file="$ISO",media=cdrom,if=none,format=raw,id=cdrom0 \
  -device ide-cd,drive=cdrom0,bootindex=2 \
  -drive file="$cidata_img",format=raw,if=none,id=cidata0 \
  -device virtio-blk-pci,drive=cidata0 \
  -display none -vga std \
  -qmp "unix:${qmp_sock},server,nowait" \
  -serial "file:${serial_log}" \
  -daemonize -pidfile "$pidfile" \
  -no-reboot \
  -nic none \
  -boot menu=on ||
  fail "qemu-system-x86_64 failed to launch"

qemu_pid=$(cat "$pidfile")
log "qemu pid $qemu_pid"

elapsed=0
while kill -0 "$qemu_pid" 2>/dev/null; do
  sleep 5
  elapsed=$((elapsed + 5))
  if (( elapsed >= INSTALL_TIMEOUT )); then
    log "TIMEOUT after ${elapsed}s waiting for guest poweroff — see the 'KNOWN GAP' note at the top of this script"
    # Best-effort screendump for debugging before killing.
    if command -v qemu-img >/dev/null 2>&1 && [[ -S $qmp_sock ]]; then
      printf '{"execute":"qmp_capabilities"}\n{"execute":"screendump","arguments":{"filename":"%s/timeout-screendump.ppm"}}\n' "$WORK" \
        | timeout 5 socat - "UNIX-CONNECT:${qmp_sock}" >/dev/null 2>&1 || true
    fi
    kill "$qemu_pid" 2>/dev/null || true
    sleep 1
    kill -9 "$qemu_pid" 2>/dev/null || true
    fail "install did not complete within ${INSTALL_TIMEOUT}s (work dir preserved: $WORK)"
  fi
done
log "guest exited after ${elapsed}s"

log "converting qcow2 -> raw for rootless offline inspection"
qemu-img convert -O raw "$disk" "$disk_raw" || fail "qemu-img convert failed"

# --- artifact assertions ----------------------------------------------

status=0
check() { "$@" || status=1; }

log "asserting partition table"
check assert::partition_table "$disk_raw"

if [[ ${#EXPECT_UKI[@]} -gt 0 && -n ${EXPECT_UKI[0]} ]]; then
  log "asserting UKI files: ${EXPECT_UKI[*]}"
  uki_dir="$WORK/extracted-ukis"
  disk_image::esp_extract_ukis "$disk_raw" "$uki_dir"
  check assert::uki_files_present "$uki_dir" "${EXPECT_UKI[@]}"
else
  log "skipping UKI check (VM_EXPECT_UKI not set — T1 hasn't fixed the preset/filename yet, PLAN.md §8.3)"
fi

if [[ ${#EXPECT_LIMINE_REF[@]} -gt 0 && -n ${EXPECT_LIMINE_REF[0]} ]]; then
  log "asserting Limine config entries: ${EXPECT_LIMINE_REF[*]}"
  limine_conf="$WORK/limine.conf"
  if disk_image::esp_find_limine_config "$disk_raw" "$limine_conf" >"$WORK/limine-config-path.txt"; then
    check assert::limine_config_entries "$limine_conf" "${EXPECT_LIMINE_REF[@]}"
  else
    status=1
  fi
else
  log "skipping Limine config check (VM_EXPECT_LIMINE_REF not set)"
fi

log "extracting root partition for package/unit assertions"
root_raw="$WORK/root.raw"
if disk_image::root_extract "$disk_raw" "$root_raw"; then
  restored="$WORK/restored-root"
  disk_image::root_restore_matching "$root_raw" '^/(var/lib/pacman/local(|/.*)|etc/systemd/system(|/.*))$' "$restored"

  if [[ ${#EXPECT_PACKAGES[@]} -gt 0 && -n ${EXPECT_PACKAGES[0]} ]]; then
    log "asserting package set: ${EXPECT_PACKAGES[*]}"
    check assert::packages_present "$restored/var/lib/pacman/local" "${EXPECT_PACKAGES[@]}"
  fi

  if [[ ${#EXPECT_UNITS[@]} -gt 0 && -n ${EXPECT_UNITS[0]} ]]; then
    log "asserting enabled units: ${EXPECT_UNITS[*]}"
    check assert::units_enabled "$restored/etc/systemd/system" "${EXPECT_UNITS[@]}"
  else
    log "skipping enabled-units check (VM_EXPECT_UNITS not set — T3 hasn't run yet)"
  fi
else
  log "could not extract root partition — see errors above"
  status=1
fi

if [[ $status -eq 0 ]]; then
  log "PASS — work dir: $WORK"
else
  log "FAIL — one or more assertions failed, see above. work dir preserved: $WORK"
fi
exit $status
