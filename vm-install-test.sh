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
# install. Reading omarchy-install-dashboard's actual source (session 2)
# corrected an earlier, wrong version of this note: non-interactive
# installs do NOT hang on a prompt — both the reboot confirm and the
# failure menu already short-circuit when OMARCHY_UI_INTERACTIVE=no. The
# real gap is narrower: on success the dashboard runs an in-guest `reboot`
# (into the freshly-installed disk) rather than powering off, so QEMU's
# process never exits either way — success or failure, this harness's
# process-exit wait will hit VM_INSTALL_TIMEOUT_SEC. Against a stock ISO
# that is a real, honest failure, not a bug in this harness. T5's Deck ISO
# fork needs a one-line addition to
# `configs/airootfs/root/.automated_script.sh`'s cidata branch: export
# `OMARCHY_UI_AUTO_REBOOT=no OMARCHY_UI_FAILURE_ACTION=exit` before the
# dashboard call, capture its exit status without tripping `set -e`, then
# unconditionally `systemctl poweroff` afterward when non-interactive
# (verified as a scratch patch against unmodified upstream in session 2 —
# see PROGRESS.md for the exact diff).
# This script has not yet been run against a real ISO end-to-end. Docker/
# kvm-group/disk-group access is confirmed working now (session 2), but
# every attempt to build an unmodified test ISO from this environment hit
# a real network-bandwidth ceiling (session 2, see PROGRESS.md) before a
# boot could even be attempted. Verify on a connection with real
# throughput before trusting the completion-detection path.

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

log() { printf '[vm-install-test] %s\n' "$*" >&2; }
fail() { log "FAIL: $*"; exit 1; }

# OVMF's install path isn't consistent across distros (Arch's edk2-ovmf
# vs. Debian/Ubuntu's ovmf vs. Fedora's edk2-ovmf all differ) and this
# needs to work both on the operator's Arch dev machine and on whatever
# CI runner (currently Ubuntu-based GitHub Actions) ends up running this.
# Probe known candidates; VM_OVMF_CODE/VM_OVMF_VARS override outright.
# Prints the first existing candidate path, or nothing (exit 1) if none
# exist — runs inside a command substitution below, so it must not call
# fail()/exit itself; a subshell's `exit` only ends the subshell, and a
# failure here has to actually stop the script, not silently continue
# with an empty path.
find_ovmf() {
  local c
  for c in "$@"; do
    [[ -f $c ]] && { echo "$c"; return 0; }
  done
  return 1
}
OVMF_CODE=${VM_OVMF_CODE:-$(find_ovmf \
  /usr/share/edk2/x64/OVMF_CODE.4m.fd \
  /usr/share/OVMF/OVMF_CODE_4M.fd \
  /usr/share/OVMF/OVMF_CODE.fd \
  /usr/share/edk2/ovmf/OVMF_CODE.fd)}
OVMF_VARS_TEMPLATE=${VM_OVMF_VARS:-$(find_ovmf \
  /usr/share/edk2/x64/OVMF_VARS.4m.fd \
  /usr/share/OVMF/OVMF_VARS_4M.fd \
  /usr/share/OVMF/OVMF_VARS.fd \
  /usr/share/edk2/ovmf/OVMF_VARS.fd)}
[[ -n $OVMF_CODE && -f $OVMF_CODE ]] || fail "OVMF CODE firmware not found — package edk2-ovmf (Arch) / ovmf (Debian/Ubuntu). See 'Escalate if' in TASK-T0-test-infrastructure.md: this is a Blocked-on-human item, not something to work around. Override with VM_OVMF_CODE."
[[ -n $OVMF_VARS_TEMPLATE && -f $OVMF_VARS_TEMPLATE ]] || fail "OVMF VARS firmware not found — package edk2-ovmf (Arch) / ovmf (Debian/Ubuntu). Override with VM_OVMF_VARS."

command -v qemu-system-x86_64 >/dev/null || fail "qemu-system-x86_64 not found"

# KVM acceleration isn't universal (notably: standard GitHub-hosted CI
# runners have no /dev/kvm — confirmed absent from upstream omarchy-iso's
# own CI for the same reason, session 1 research). Degrade to software
# emulation (TCG) rather than hard-failing when it's unavailable; just
# say so loudly, since TCG is dramatically slower and a timeout under TCG
# doesn't mean the same thing as a timeout under KVM.
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
  ACCEL_ARGS=(-cpu host -enable-kvm -machine "q35,accel=kvm")
else
  log "WARNING: /dev/kvm not accessible — falling back to TCG (software emulation, much slower). Consider a higher VM_INSTALL_TIMEOUT_SEC."
  ACCEL_ARGS=(-cpu max -machine "q35,accel=tcg")
fi

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
debug_log_img="$WORK/debug-log.raw"
debug_log_txt="$WORK/install-debug.log"

disk_bytes=$((DISK_SIZE_GB * 1024 * 1024 * 1024))

log "creating ${DISK_SIZE_GB}G target disk (qcow2, target device /dev/vda)"
qemu-img create -f qcow2 "$disk" "${DISK_SIZE_GB}G" >/dev/null

cp "$OVMF_VARS_TEMPLATE" "$ovmf_vars"

log "rendering cidata autoinstall config (hostname=$HOSTNAME_ user=$USERNAME)"
cidata::render_config /dev/vda "$disk_bytes" "$HOSTNAME_" "$config_json"
cidata::render_credentials "$USERNAME" "$PASSWORD" "$creds_json"
cidata::build_image "$cidata_img" "$config_json" "$creds_json"

# Debug-log capture drive: the real install log only ever exists in the
# guest's tmpfs (/var/log/omarchy-install.log), and tty1's actual text can
# be hidden behind plymouth's splash for the guest's whole lifetime — a
# screendump doesn't reliably show it. A fork's cidata branch of
# .automated_script.sh can dd its log (and state.json) onto this device,
# found in-guest at /dev/disk/by-id/virtio-vmdebuglog, right before its
# unconditional poweroff. Harmless no-op against a script that doesn't
# know about it — just an unused extra block device.
qemu-img create -f raw "$debug_log_img" 8M >/dev/null

log "booting ISO headless (timeout ${INSTALL_TIMEOUT}s)"
qemu-system-x86_64 \
  "${ACCEL_ARGS[@]}" \
  -smp "$SMP" -m "$MEM_MB" \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
  -drive if=pflash,format=raw,file="$ovmf_vars" \
  -drive file="$disk",format=qcow2,if=none,id=drive0 \
  -device virtio-blk-pci,drive=drive0,bootindex=1 \
  -drive file="$ISO",media=cdrom,if=none,format=raw,id=cdrom0 \
  -device ide-cd,drive=cdrom0,bootindex=2 \
  -drive file="$cidata_img",format=raw,if=none,id=cidata0 \
  -device virtio-blk-pci,drive=cidata0 \
  -drive file="$debug_log_img",format=raw,if=none,id=dbglog0 \
  -device virtio-blk-pci,drive=dbglog0,serial=vmdebuglog \
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

# Raw device, no filesystem — strip trailing NULs from the unused tail of
# the image so the saved log doesn't carry megabytes of padding.
tr -d '\0' <"$debug_log_img" >"$debug_log_txt" || true
if [[ -s $debug_log_txt ]]; then
  log "debug log captured: $debug_log_txt"
else
  log "debug log empty (fork's .automated_script.sh didn't write to it, or guest never got that far)"
fi

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
if disk_image::root_extract "$disk_raw" "$root_raw" &&
  read -r root_loop root_at < <(disk_image::root_mount "$root_raw"); then
  if [[ ${#EXPECT_PACKAGES[@]} -gt 0 && -n ${EXPECT_PACKAGES[0]} ]]; then
    log "asserting package set: ${EXPECT_PACKAGES[*]}"
    check assert::packages_present "$root_at/var/lib/pacman/local" "${EXPECT_PACKAGES[@]}"
  fi

  if [[ ${#EXPECT_UNITS[@]} -gt 0 && -n ${EXPECT_UNITS[0]} ]]; then
    log "asserting enabled units: ${EXPECT_UNITS[*]}"
    check assert::units_enabled "$root_at/etc/systemd/system" "${EXPECT_UNITS[@]}"
  else
    log "skipping enabled-units check (VM_EXPECT_UNITS not set — T3 hasn't run yet)"
  fi

  disk_image::root_unmount "$root_loop"
else
  log "could not extract/mount root partition — see errors above"
  status=1
fi

if [[ $status -eq 0 ]]; then
  log "PASS — work dir: $WORK"
else
  log "FAIL — one or more assertions failed, see above. work dir preserved: $WORK"
fi
exit $status
