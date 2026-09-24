#!/usr/bin/env bash
# vm-fast-install-test.sh -- QEMU timing harness for FAST-INSTALL contract C6.
#
# Boots a given ISO under KVM/OVMF with the stick-throttled USB path from the
# research (docs/findings/INSTALL-SPEED.md §3.6: ISO as usb-storage behind
# qemu-xhci, read-throttled to the measured 82 MB/s), an NVMe target disk, and
# user-mode networking, then drives an UNATTENDED install whose cidata drive
# carries the `preinstalls` / `gaming` choice files (yes/no, matching
# /run/omarchy-deck/choices/*) plus `form-delay-seconds` = N (the simulated
# form length). When the guest finishes, reads the two timing records out of
# the installed disk and prints the C6 figures: early total + per-phase
# elapsed, late post-confirm (finished_at - confirmed_at), early_join_wait_s
# and steam_join_wait_s -- then asserts the variant's Steam outcome on disk
# (gaming=yes: launcher + client present; gaming=no: neither fetched).
#
# Usage: ./vm-fast-install-test.sh <iso-path> [work-dir]
#
# Env vars (all optional):
#   VM_DISK_SIZE_GB         default 20 (NVMe target, raw sparse file)
#   VM_MEM_MB               default 8192 (8 GiB; the Deck has 16 -- raise with
#                           VM_MEM_MB=16384 if image staging ever needs more)
#   VM_SMP                  default min(nproc,4)
#   VM_INSTALL_TIMEOUT_SEC  default 1800 (30 min)
#   VM_HOSTNAME             default test-vm
#   VM_USERNAME             default tester
#   VM_FULL_NAME            default 'Deck Tester'. cidata `user_full_name.txt`
#                           identity file (used for git; empty skips the name).
#   VM_EMAIL                default 'deck@example.invalid'. cidata
#                           `user_email_address.txt` identity file (used for
#                           git; empty skips the email).
#   VM_PREINSTALLS            default no. cidata `preinstalls` choice file
#                           (yes/no, matching /run/omarchy-deck/choices/*).
#   VM_GAMING                 default no. cidata `gaming` choice file (yes/no).
#                           no/no is the fastest path; run the four combos via
#                           separate invocations.
#   VM_GAMING_NET_CHECK       default 1. With gaming=yes, require user-mode
#                           network reachability before launching (the Steam
#                           fetch cannot succeed offline). Set to 0 to run the
#                           guest anyway and let the install record the fetch
#                           failure honestly.
#   VM_NET                    default user. user = NAT'd virtio NIC (required
#                           for gaming=yes); none = `-nic none`, the true
#                           offline bypass proof for gaming=no (a pass with a
#                           NIC present only proves no-fetch despite network).
#                           gaming=yes with VM_NET=none is refused outright.
#   VM_THROTTLE_BPS_READ    default 82000000 (the measured stick, §3.2).
#                           0 disables throttling.
#   VM_EXPECT_STAGES_TIMING default 1. The integrated ISO's LATE stage writes
#                           /var/log/omarchy-deck-stages-timing.json; require
#                           it. Set to 0 for a dry run against the release ISO,
#                           which predates that file (only the upstream
#                           omarchy-install-timing.json is expected there).
#   VM_FAST_REBOOT_CHECK    default 0. Set to 1 to boot the installed disk
#                           once and OCR the screen for a login/sddm/gamescope
#                           marker (up to VM_REBOOT_TIMEOUT_SEC, default 300).
#   VM_OVMF_CODE / VM_OVMF_VARS  firmware overrides (probed like
#                           vm-install-test.sh when unset).
#
# Completion detection, in order:
#   1. Serial marker `FASTINSTALL:DONE` in serial.log (the integrated ISO's
#      cidata branch prints it after LATE; C6 companion to the timing line).
#   2. QEMU process exit (poweroff/reboot path with -no-reboot), exactly the
#      signal vm-install-test.sh waits for.
# A screendump is OCR'd every minute purely as a liveness heartbeat in the
# log; it never decides anything.
#
# Timing records, in order:
#   1. A `FASTINSTALL_TIMING:<compact-json>` line in serial.log (same writer
#      as the marker above) -- primary, needs no disk layout assumptions.
#   2. The files /var/log/omarchy-deck-stages-timing.json and
#      /var/log/omarchy-install-timing.json read out of the installed disk
#      (rootless udisksctl loop-mount, the vm-disk-image.sh model).
#
# Exit status: 0 when the install completed AND every expected timing record
# was read and printed; 1 when the install failed, the guest timed out, or an
# expected timing file is missing; 2 for usage/environment errors. A non-zero
# exit always names the work dir, which is preserved.
#
# DRY-RUN MODE (until Main hands over an integrated ISO): run with
# VM_EXPECT_STAGES_TIMING=0 against the release ISO. The stock ISO ignores
# form-delay-seconds (its cidata branch predates it) and prints no serial
# markers, so completion falls through to QEMU-process-exit and only the
# upstream timing file is expected -- but the boot path, the throttle arming
# (asserted via QMP below), the cidata build, and the disk inspection are the
# real code paths Main will run later.

set -uo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

# shellcheck source=../lib/vm-disk-image.sh
source "$REPO_ROOT/test/lib/vm-disk-image.sh"
# shellcheck source=../lib/vm-assertions.sh
source "$REPO_ROOT/test/lib/vm-assertions.sh"
# shellcheck source=../lib/vm-cidata.sh
source "$REPO_ROOT/test/lib/vm-cidata.sh"

ISO=${1:?"usage: $0 <iso-path> [work-dir]"}
WORK=${2:-$(mktemp -d /tmp/vm-fast-install-test.XXXXXX)}
[[ -f $ISO ]] || { echo "vm-fast-install-test: ISO not found: $ISO" >&2; exit 2; }

DISK_SIZE_GB=${VM_DISK_SIZE_GB:-20}
MEM_MB=${VM_MEM_MB:-8192}
DEFAULT_SMP=$(( $(nproc) < 4 ? $(nproc) : 4 ))
SMP=${VM_SMP:-$DEFAULT_SMP}
INSTALL_TIMEOUT=${VM_INSTALL_TIMEOUT_SEC:-1800}
REBOOT_TIMEOUT=${VM_REBOOT_TIMEOUT_SEC:-300}
HOSTNAME_=${VM_HOSTNAME:-test-vm}
USERNAME=${VM_USERNAME:-tester}
FULL_NAME=${VM_FULL_NAME:-Deck Tester}
EMAIL=${VM_EMAIL:-deck@example.invalid}
PASSWORD=${VM_PASSWORD:-tester123}
FORM_DELAY=${VM_FORM_DELAY_SEC:-90}
PREINSTALLS=${VM_PREINSTALLS:-no}
GAMING=${VM_GAMING:-no}
NET_CHECK=${VM_GAMING_NET_CHECK:-1}
THROTTLE_BPS=${VM_THROTTLE_BPS_READ:-82000000}
EXPECT_STAGES=${VM_EXPECT_STAGES_TIMING:-1}
REBOOT_CHECK=${VM_FAST_REBOOT_CHECK:-0}

log() { printf '[vm-fast-install-test] %s\n' "$*" >&2; }
fail() { log "FAIL: $*"; exit 1; }

# shellcheck disable=SC2054  # the commas are qemu's own -netdev syntax, one arg (same idiom as vm-install-controller-test.sh)
case $PREINSTALLS in yes|no) ;; *) { log "FAIL: VM_PREINSTALLS must be yes or no, got '$PREINSTALLS'"; exit 2; } ;; esac
case $GAMING in yes|no) ;; *) { log "FAIL: VM_GAMING must be yes or no, got '$GAMING'"; exit 2; } ;; esac
# shellcheck disable=SC2054  # the commas are qemu's own -netdev syntax, one arg (same idiom as vm-install-controller-test.sh)
case ${VM_NET:-user} in
  user) NET_ARGS=(-netdev user,id=n0 -device virtio-net-pci,netdev=n0) ;;
  none) NET_ARGS=(-nic none) ;;
  *) { log "FAIL: VM_NET must be user or none, got '${VM_NET:-}'"; exit 2; } ;;
esac
if [[ $GAMING == yes && ${VM_NET:-user} == none ]]; then
  { log "FAIL: gaming=yes needs the network for the Steam fetch; VM_NET=none cannot prove it."; exit 2; }
fi

# The four installer variants (docs/tasks/FAST-INSTALL.md C2/C5): preinstalls
# and gaming are each exactly yes/no. The no/no combo is the fastest path;
# run all four via separate invocations.

# gaming=yes needs the network for the online Steam launcher + client fetch.
# Probe user-mode reachability with the same fetch primitive the installer
# uses (curl, short timeout) before spending a boot on a doomed fetch --
# unless explicitly disabled, in which case the guest records the failure
# honestly instead.
if [[ $GAMING == yes && $NET_CHECK == 1 ]]; then
  # The CDN's root answers 403 by design; probe the client manifest the
  # bootstrap itself downloads, which answers 200 when Steam is reachable.
  if curl -fsS --max-time 15 -o /dev/null https://client-update.steamstatic.com/steam_client_ubuntu12 2>/dev/null; then
    log "network reachability: Steam CDN answers (gaming=yes may fetch)"
  else
    { log "FAIL: gaming=yes needs network reachability (VM_GAMING_NET_CHECK=1); the Steam CDN did not answer. Set VM_GAMING_NET_CHECK=0 to run anyway."; exit 2; }
  fi
fi

# Same OVMF probe as vm-install-test.sh: Arch's edk2-ovmf vs Debian/Ubuntu's
# ovmf vs Fedora's all differ, and this must run on the operator's Arch dev
# machine and on CI alike. VM_OVMF_CODE/VM_OVMF_VARS override outright.
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
[[ -n $OVMF_CODE && -f $OVMF_CODE ]] || { log "FAIL: OVMF CODE firmware not found -- package edk2-ovmf (Arch) / ovmf (Debian/Ubuntu). Override with VM_OVMF_CODE."; exit 2; }
[[ -n $OVMF_VARS_TEMPLATE && -f $OVMF_VARS_TEMPLATE ]] || { log "FAIL: OVMF VARS firmware not found -- package edk2-ovmf (Arch) / ovmf (Debian/Ubuntu). Override with VM_OVMF_VARS."; exit 2; }

command -v qemu-system-x86_64 >/dev/null || { log "FAIL: qemu-system-x86_64 not found"; exit 2; }
command -v jq >/dev/null || { log "FAIL: jq not found"; exit 2; }
command -v socat >/dev/null || { log "FAIL: socat not found (needed for QMP)"; exit 2; }

# KVM or loud TCG fallback, same policy as vm-install-test.sh: CI runners
# without /dev/kvm must still run, but a TCG timeout means something else.
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
  ACCEL_ARGS=(-cpu host -enable-kvm -machine "q35,accel=kvm")
else
  log "WARNING: /dev/kvm not accessible -- falling back to TCG (software emulation, much slower). Consider a higher VM_INSTALL_TIMEOUT_SEC."
  ACCEL_ARGS=(-cpu max -machine "q35,accel=tcg")
fi

mkdir -p "$WORK"
log "work dir: $WORK"
log "iso: $ISO (preinstalls=${PREINSTALLS} gaming=${GAMING} form-delay=${FORM_DELAY}s, throttle=${THROTTLE_BPS} B/s, mem=${MEM_MB}MiB, smp=${SMP})"

target_raw="$WORK/target.raw"
ovmf_vars="$WORK/OVMF_VARS.fd"
cidata_img="$WORK/cidata.img"
config_json="$WORK/user_configuration.json"
creds_json="$WORK/user_credentials.json"
form_delay_file="$WORK/form-delay-seconds"
preinstalls_file="$WORK/preinstalls"
gaming_file="$WORK/gaming"
full_name_file="$WORK/user_full_name.txt"
email_file="$WORK/user_email_address.txt"
qmp_sock="$WORK/qmp.sock"
pidfile="$WORK/qemu.pid"
serial_log="$WORK/serial.log"

disk_bytes=$((DISK_SIZE_GB * 1024 * 1024 * 1024))

# Raw sparse target (truncate, no qemu-img dependency): the NVMe device the
# guest installs to. NVMe naming (/dev/nvme0n1) matches the Deck's own
# production target, so the cidata device must use it too.
log "creating ${DISK_SIZE_GB}G sparse NVMe target (guest device /dev/nvme0n1)"
truncate -s "${DISK_SIZE_GB}G" "$target_raw"

cp "$OVMF_VARS_TEMPLATE" "$ovmf_vars"

log "rendering cidata autoinstall config (hostname=$HOSTNAME_ user=$USERNAME full_name=$FULL_NAME email=$EMAIL preinstalls=$PREINSTALLS gaming=$GAMING)"
cidata::render_config /dev/nvme0n1 "$disk_bytes" "$HOSTNAME_" "$config_json"
# vm-cidata.sh renders the Deck kernel (linux-omarchy) in both config fields
# itself; the offline mirror carries no stock linux-headers, so selecting
# anything else fails pacstrap with "target not found: linux-headers".
cidata::render_credentials "$USERNAME" "$PASSWORD" "$creds_json"
printf '%s\n' "$FORM_DELAY" >"$form_delay_file"
# Variant choices: exact yes/no content and basenames, matching
# /run/omarchy-deck/choices/* (docs/tasks/FAST-INSTALL.md C2/C5). The stock
# release ISO predates them and ignores the extra files, like form-delay.
printf '%s\n' "$PREINSTALLS" >"$preinstalls_file"
printf '%s\n' "$GAMING" >"$gaming_file"
# Identity files: exact basenames the loader accepts (user_full_name.txt /
# user_email_address.txt, deck-install-invocation.patch optional_inputs),
# matching what configurator's write_user_files writes on the ISO path.
printf '%s\n' "$FULL_NAME" >"$full_name_file"
printf '%s\n' "$EMAIL" >"$email_file"
cidata::build_image "$cidata_img" "$config_json" "$creds_json" "$form_delay_file" "$preinstalls_file" "$gaming_file" "$full_name_file" "$email_file"

cleanup_qemu() {
  local pid
  if [[ -f $pidfile ]] && pid=$(cat "$pidfile" 2>/dev/null) && [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    sleep 1
    kill -9 "$pid" 2>/dev/null || true
  fi
}
trap cleanup_qemu EXIT

qmp() {
  printf '{"execute":"qmp_capabilities"}\n%s\n' "$1" |
    timeout 10 socat - "UNIX-CONNECT:${qmp_sock}" 2>/dev/null
}
send_screendump() {
  qmp "{\"execute\":\"screendump\",\"arguments\":{\"filename\":\"$WORK/shot.ppm\"}}" >/dev/null 2>&1
}
dump_guest_failure_log() {
  # The dashboard leaves a root shell after a failed install. Type one command
  # into it that copies the live logs to the serial port before the harness
  # shuts QEMU down; /var/log on the live ISO otherwise vanishes with the VM.
  local c key i
  for ((i=0; i<${#1}; i++)); do
    c=${1:i:1}
    case $c in
      /) key='slash' ;; -) key='minus' ;; .) key='dot' ;;
      ' ') key=spc ;; S) key=shift-s ;; '|') key=shift-backslash ;;
      [a-z0-9]) key=$c ;;
      *) log "unsupported guest command character: $c"; return 1 ;;
    esac
    qmp "{\"execute\":\"human-monitor-command\",\"arguments\":{\"command-line\":\"sendkey $key\"}}" >/dev/null || return 1
  done
  qmp '{"execute":"human-monitor-command","arguments":{"command-line":"sendkey ret"}}' >/dev/null
}

ocr_screen() {
  # Liveness heartbeat, plus one failure detector: the dashboard's own
  # "installation stopped" screen ends the run at once with the guest logs,
  # instead of idling to the timeout. Completion is still decided by the
  # serial marker / QEMU exit only; tesseract missing means silence.
  command -v tesseract >/dev/null 2>&1 || return 0
  send_screendump || return 0
  [[ -f $WORK/shot.ppm ]] || return 0
  local txt first
  txt=$(tesseract "$WORK/shot.ppm" stdout --psm 6 2>/dev/null || true)
  first=$(tr '\n' ' ' <<<"$txt" | tr -s ' ' | cut -c1-120)
  log "screen@${elapsed}s: ${first:-<unreadable>}"
  if [[ ${txt,,} == *'installation stopped'* ]]; then
    log "installer failed; copying guest early + install logs to serial before shutdown"
    cp "$WORK/shot.ppm" "$WORK/failure-screendump.ppm" 2>/dev/null || true
    dump_guest_failure_log 'tail -n 400 /var/log/omarchy-deck-early.log /var/log/omarchy-install.log | tee /dev/ttyS0' || true
    sleep 5
    if [[ -s $serial_log ]]; then
      log "guest serial diagnostic:"
      cat "$serial_log" >&2
    fi
    fail "installer stopped before completion"
  fi
}

throttle_opt=""
if (( THROTTLE_BPS > 0 )); then
  throttle_opt=",throttling.bps-read=${THROTTLE_BPS}"
fi

log "booting ISO as throttled usb-storage behind xhci (timeout ${INSTALL_TIMEOUT}s)"
qemu-system-x86_64 \
  "${ACCEL_ARGS[@]}" \
  -smp "$SMP" -m "$MEM_MB" \
  -smbios type=1,manufacturer=Valve,product=Galileo,version=1 \
  -smbios type=2,manufacturer=Valve,product=Galileo \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
  -drive if=pflash,format=raw,file="$ovmf_vars" \
  -device qemu-xhci,id=xhci \
  -drive "if=none,id=stick,format=raw,readonly=on,cache=none,aio=native,file=${ISO}${throttle_opt}" \
  -device usb-storage,bus=xhci.0,drive=stick,bootindex=0 \
  -drive if=none,id=tgt,format=raw,file="$target_raw" \
  -device nvme,drive=tgt,serial=VMFASTTARGET \
  -drive file="$cidata_img",format=raw,if=none,id=cidata0 \
  -device virtio-blk-pci,drive=cidata0 \
  "${NET_ARGS[@]}" \
  -display none -vga std \
  -qmp "unix:${qmp_sock},server,nowait" \
  -serial "file:${serial_log}" \
  -daemonize -pidfile "$pidfile" \
  -no-reboot \
  -boot menu=on ||
  fail "qemu-system-x86_64 failed to launch"

qemu_pid=$(cat "$pidfile")
log "qemu pid $qemu_pid"

# Prove the throttle is armed: query-block reports the throttle group's
# configured bps_rd per backend device. A boot that silently ignores
# throttling.bps-read would measure unthrottled I/O while claiming stick
# conditions. (query-named-block-nodes does NOT expose this: the throttle
# node shows bps_rd 0 there even when the limit is armed -- verified live
# against QEMU 11.1.1, where query-block reports the stick at bps_rd
# 82000000 exactly as requested.)
sleep 2
if (( THROTTLE_BPS == 0 )); then
  log "throttling disabled (VM_THROTTLE_BPS_READ=0) -- skipping arming check"
else
  # -s (slurp): QMP emits one JSON object per line plus the greeting, which
  # jaq/jq without -s reject as "extra data". Verified live: query-block
  # reports the stick at bps_rd 82000000 exactly as requested on QEMU 11.1.1.
  if qmp '{"execute":"query-block"}' >"$WORK/query-block.json" 2>/dev/null && [[ -s $WORK/query-block.json ]]; then
    armed=$(jq -s -r '[.[] | select(type == "object" and (.return | type) == "array") | .return[] | select(.device == "stick") | .inserted."bps_rd"] | .[0] // empty' "$WORK/query-block.json" 2>/dev/null || true)
    if [[ -n $armed ]]; then
      log "throttle armed: stick bps_rd=${armed} (requested ${THROTTLE_BPS})"
      [[ $armed == "$THROTTLE_BPS" ]] || fail "stick throttled at ${armed} B/s, requested ${THROTTLE_BPS} B/s"
    else
      log "WARNING: stick backend missing from query-block -- throttling unverified (see $WORK/query-block.json)"
    fi
  else
    log "WARNING: QMP query-block failed -- throttle arming unverified"
  fi
fi

elapsed=0
done_marker=0
tick=0
while kill -0 "$qemu_pid" 2>/dev/null; do
  sleep 5
  elapsed=$((elapsed + 5))
  tick=$((tick + 1))
  if [[ -f $serial_log ]] && LC_ALL=C command grep -aq 'FASTINSTALL:DONE' "$serial_log" 2>/dev/null; then
    log "completion marker FASTINSTALL:DONE seen after ${elapsed}s"
    done_marker=1
    break
  fi
  if (( tick % 12 == 0 )); then
    ocr_screen
  fi
  if (( elapsed >= INSTALL_TIMEOUT )); then
    log "TIMEOUT after ${elapsed}s waiting for guest completion"
    send_screendump && cp "$WORK/shot.ppm" "$WORK/timeout-screendump.ppm" || true
    fail "install did not complete within ${INSTALL_TIMEOUT}s (work dir preserved: $WORK)"
  fi
done
log "guest exited after ${elapsed}s (marker seen: ${done_marker})"
# Reap the exit status path: with -no-reboot any guest reboot/poweroff lands
# here, so exit alone is the release-ISO completion signal (see header).
wait "$qemu_pid" 2>/dev/null || true

# --- timing records ----------------------------------------------------
# Primary: the FASTINSTALL_TIMING line on serial (needs no disk assumptions).
# Fallback: the files on the installed disk (rootless mount, vm-disk-image.sh
# model). Either way both JSON blobs end up as files under $WORK for the
# summary step below.

status=0
check() { "$@" || status=1; }

timing_serial="$WORK/stages-timing-serial.json"
if [[ -f $serial_log ]] && LC_ALL=C command grep -aq 'FASTINSTALL_TIMING:' "$serial_log" 2>/dev/null; then
  LC_ALL=C command grep -a 'FASTINSTALL_TIMING:' "$serial_log" 2>/dev/null | tail -n 1 |
    sed 's/.*FASTINSTALL_TIMING://' | tr -d '\r' >"$timing_serial"
  log "stages timing arrived over serial"
fi

stages_json=""
upstream_json="$WORK/omarchy-install-timing.json"
mount_loop=""
timing_needed=0
if [[ ! -s $timing_serial || $EXPECT_STAGES == 1 ]]; then
  timing_needed=1
fi
if (( timing_needed )); then
  log "reading timing records out of the installed disk"
  check assert::partition_table "$target_raw"
  root_raw="$WORK/root.raw"
  # The btrfs layout mounts /var/log as its own @log subvolume
  # (vm-cidata.sh's template): at the loop-mount root that is a sibling of
  # @, so the timing files live under $log_dir = <mnt>/@log on a real
  # install. Fall back to $root_at/var/log for layouts without the split.
  if disk_image::root_extract "$target_raw" "$root_raw" &&
    read -r mount_loop root_at < <(disk_image::root_mount "$root_raw"); then
    mount_point=${root_at%/@}
    log_dir="$root_at/var/log"
    [[ -f $mount_point/@log/omarchy-install-timing.json ]] && log_dir="$mount_point/@log"
    if [[ -f $log_dir/omarchy-install-timing.json ]]; then
      cp "$log_dir/omarchy-install-timing.json" "$upstream_json"
      log "read omarchy-install-timing.json from the installed disk ($log_dir)"
    else
      log "omarchy-install-timing.json missing on the installed disk"
      status=1
    fi
    if [[ -f $log_dir/omarchy-deck-stages-timing.json ]]; then
      stages_json="$WORK/omarchy-deck-stages-timing.json"
      cp "$log_dir/omarchy-deck-stages-timing.json" "$stages_json"
      log "read omarchy-deck-stages-timing.json from the installed disk"
    elif [[ -s $timing_serial ]]; then
      stages_json=$timing_serial
    elif [[ $EXPECT_STAGES == 1 ]]; then
      log "omarchy-deck-stages-timing.json missing (disk and serial)"
      status=1
    else
      log "omarchy-deck-stages-timing.json absent (expected on a pre-C6 ISO)"
    fi
    # --- variant assertions (docs/tasks/FAST-INSTALL.md C2/C4) ------------
    # Gated to EXPECT_STAGES=1: the release ISO predates the choices path
    # (it installs full Steam unconditionally), so asserting variant absence
    # there would fail a correct stock install. Every check below asserts on
    # ARTIFACTS (pacman db, files, SDDM config), never on log text -- the
    # vm-install-test.sh rule.
    if [[ $EXPECT_STAGES == 1 ]]; then
      pacman_db="$root_at/var/lib/pacman/local"
      # No authorized_keys are supplied by this rig. Upstream's
      # configure_ssh_access must return before enabling sshd or opening ufw.
      for wants in "$root_at/etc/systemd/system/multi-user.target.wants/sshd.service" \
                   "$root_at/usr/lib/systemd/system/multi-user.target.wants/sshd.service"; do
        if [[ -e $wants || -L $wants ]]; then
          log "FAIL: sshd is enabled by default without an authorized key: $wants"
          status=1
        fi
      done
      # The installed system must keep the runtime's pacman.conf, never the
      # installer's offline one: that repo is a mirror on the USB stick, and
      # a Deck left pointing at it cannot update or install anything.
      if LC_ALL=C command grep -aq '^\[offline\]' "$root_at/etc/pacman.conf" 2>/dev/null ||
        ! LC_ALL=C command grep -aq '^\[core\]' "$root_at/etc/pacman.conf" 2>/dev/null; then
        log "FAIL: the installed /etc/pacman.conf is the installer's offline config (repos: $(LC_ALL=C command grep -ao '^\[[a-z-]*\]' "$root_at/etc/pacman.conf" | tr '\n' ' '))"
        status=1
      else
        log "installed pacman.conf repos: $(LC_ALL=C command grep -ao '^\[[a-z-]*\]' "$root_at/etc/pacman.conf" | grep -v options | tr '\n' ' ')"
      fi
      if [[ $GAMING == yes ]]; then
        check assert::packages_present "$pacman_db" steam
        [[ -f $root_at/usr/lib/steam/bootstraplinux_ubuntu12_32.tar.xz ]] || { log "FAIL: gaming=yes but the Steam bootstrap tarball is absent on the target"; status=1; }
        [[ -f $root_at/usr/share/wayland-sessions/gamescope-wayland.desktop ]] || { log "FAIL: gaming=yes but gamescope-wayland.desktop is absent on the target"; status=1; }
      else
        if compgen -G "$pacman_db/steam-*/desc" >/dev/null; then
          log "FAIL: gaming=no but the steam package is installed on the target (a fetch that must never start)"
          status=1
        fi
        if [[ -f $root_at/usr/lib/steam/bootstraplinux_ubuntu12_32.tar.xz ]]; then
          log "FAIL: gaming=no but the Steam bootstrap tarball is present on the target"
          status=1
        fi
        for pkg in gamescope vulkan-radeon lib32-vulkan-radeon mangohud lib32-mangohud; do
          if compgen -G "$pacman_db/${pkg}-*/desc" >/dev/null; then
            log "FAIL: gaming=no but gaming-only package '$pkg' is installed"
            status=1
          fi
        done
        if [[ -f $root_at/usr/share/wayland-sessions/gamescope-wayland.desktop ]]; then
          log "FAIL: gaming=no but the Gamescope login session is installed"
          status=1
        fi
        # The keyboard the Gaming=No login needs, as SDDM will resolve it:
        # files in name order, the LAST value of a key wins. InputMethod=
        # alone showed no keyboard on the Wayland greeter (QEMU, 2026-09-24);
        # it takes the omarchy-deck theme AND QT_IM_MODULE in the greeter env.
        sddm_last() { cat "$root_at"/etc/sddm.conf.d/*.conf 2>/dev/null | LC_ALL=C command grep -a "^$1=" | tail -n 1; }
        greeter_theme=$(sddm_last Current)
        greeter_env=$(sddm_last GreeterEnvironment)
        if [[ $greeter_theme != "Current=omarchy-deck" ]]; then
          log "FAIL: gaming=no but the effective SDDM theme is '${greeter_theme:-<none>}', not the omarchy-deck keyboard theme"
          status=1
        elif [[ ! -f $root_at/usr/share/sddm/themes/omarchy-deck/Main.qml ]]; then
          log "FAIL: gaming=no selects omarchy-deck but /usr/share/sddm/themes/omarchy-deck/Main.qml is absent"
          status=1
        elif [[ $greeter_env != *QT_IM_MODULE=qtvirtualkeyboard* ]]; then
          log "FAIL: gaming=no but the greeter environment lacks QT_IM_MODULE=qtvirtualkeyboard ('${greeter_env:-<none>}')"
          status=1
        else
          log "gaming=no greeter keyboard: ${greeter_theme}, ${greeter_env}"
        fi
      fi
      preinstall_pkgs=(aether cliamp libreoffice-fresh xournalpp pinta obsidian obs-studio kdenlive moonlight-qt lazydocker omacut omacalc omawrite)
      if [[ $PREINSTALLS == yes ]]; then
        check assert::packages_present "$pacman_db" "${preinstall_pkgs[@]}"
      else
        for pkg in "${preinstall_pkgs[@]}"; do
          if compgen -G "$pacman_db/${pkg}-*/desc" >/dev/null; then
            log "FAIL: preinstalls=no but optional package '$pkg' is installed on the target"
            status=1
          fi
        done
        marker_found=0
        for home in "$mount_point"/@home/*; do
          if [[ -f $home/.local/state/omarchy/preinstalls-removed ]]; then
            marker_found=1
            log "preinstalls-removed marker: $home"
            break
          fi
        done
        (( marker_found == 1 )) || { log "FAIL: preinstalls=no but no ~/.local/state/omarchy/preinstalls-removed marker in any installed home"; status=1; }
      fi
      # Identity (used for git): cidata's user_full_name.txt /
      # user_email_address.txt must reach the installed user's ~/.gitconfig
      # via the late stage (install/user/git.sh runs `git config --global`
      # as the installed user, so HOME there is @home/$USERNAME).
      gitconfig="$mount_point/@home/$USERNAME/.gitconfig"
      if [[ ! -f $gitconfig ]]; then
        log "FAIL: $USERNAME has no ~/.gitconfig on the target (expected name/email from cidata)"
        status=1
      else
        LC_ALL=C command grep -aqF "name = $FULL_NAME" "$gitconfig" ||
          { log "FAIL: ~/.gitconfig lacks 'name = $FULL_NAME'"; status=1; }
        LC_ALL=C command grep -aqF "email = $EMAIL" "$gitconfig" ||
          { log "FAIL: ~/.gitconfig lacks 'email = $EMAIL'"; status=1; }
      fi
      log "variant assertions done (preinstalls=$PREINSTALLS gaming=$GAMING)"
    else
      log "variant assertions skipped: pre-C6 release ISO predates the choices path (EXPECT_STAGES=0)"
    fi
    disk_image::root_unmount "$mount_loop"
    mount_loop=""
  else
    log "could not extract/mount the installed root partition -- see errors above"
    status=1
  fi
elif [[ -s $timing_serial ]]; then
  stages_json=$timing_serial
fi

# --- summary ------------------------------------------------------------
# C6 figures on stdout (machine-readable); everything else goes to stderr via
# log(). jq computes the clocks; python is not required on the host.

if [[ -s $upstream_json ]]; then
  log "upstream phases (omarchy-install-timing.json):"
  jq -r '.phases[]? | "  \(.name): \(.elapsed)"' "$upstream_json" >&2 || status=1
  jq -r '{early_total_s: ((.finished_at // 0) - (.started_at // 0))}' "$upstream_json" || status=1
else
  log "no upstream timing record available"
  status=1
fi

if [[ -n $stages_json && -s $stages_json ]]; then
  log "stages record (omarchy-deck-stages-timing.json):"
  jq -r '.early.phases[]? | "  early \(.name): \(.elapsed)"' "$stages_json" >&2 || status=1
  jq -r '.late.phases[]? | "  late \(.name): \(.elapsed)"' "$stages_json" >&2 || status=1
  jq '{early_total_s: ((.early.finished_at // 0) - (.early.started_at // 0)),
       late_post_confirm_s: ((.late.finished_at // 0) - (.late.confirmed_at // 0)),
       early_join_wait_s: (.late.early_join_wait_s // null),
       steam_join_wait_s: (.late.steam_join_wait_s // null)}' "$stages_json" || status=1
elif [[ $EXPECT_STAGES == 1 ]]; then
  log "no stages timing record available"
  status=1
fi

# --- optional: boot the installed disk once ------------------------------
if (( REBOOT_CHECK == 1 )) && (( status == 0 )); then
  log "reboot check: booting the installed disk (timeout ${REBOOT_TIMEOUT}s)"
  rb_vars="$WORK/OVMF_VARS.reboot.fd"
  rb_pidfile="$WORK/qemu-reboot.pid"
  rb_serial="$WORK/reboot-serial.log"
  cp "$OVMF_VARS_TEMPLATE" "$rb_vars"
  qemu-system-x86_64 \
    "${ACCEL_ARGS[@]}" \
    -smp "$SMP" -m "$MEM_MB" \
    -smbios type=1,manufacturer=Valve,product=Galileo,version=1 \
    -smbios type=2,manufacturer=Valve,product=Galileo \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$rb_vars" \
    -drive if=none,id=tgt,format=raw,file="$target_raw" \
    -device nvme,drive=tgt,serial=VMFASTTARGET,bootindex=0 \
    "${NET_ARGS[@]}" \
    -display none -vga std \
    -qmp "unix:${WORK}/qmp-reboot.sock,server,nowait" \
    -serial "file:${rb_serial}" \
    -daemonize -pidfile "$rb_pidfile" \
    -no-reboot \
    -boot menu=on ||
    fail "reboot-check qemu failed to launch"
  rb_pid=$(cat "$rb_pidfile")
  rb_elapsed=0
  rb_found=0
  while kill -0 "$rb_pid" 2>/dev/null; do
    sleep 5
    rb_elapsed=$((rb_elapsed + 5))
    # The installed system's serial getty prints "<hostname> login:" once
    # multi-user is up: exact, and independent of what the panel shows (the
    # Gaming=No SDDM greeter is a logo and a password box -- no OCR-able
    # text). The final screen is kept as rb-final.ppm for a human to check
    # WHICH login surface came up; OCR remains a second route for text ones.
    if LC_ALL=C command grep -aq "${HOSTNAME_} login:" "$rb_serial" 2>/dev/null; then
      sleep 20
      printf '{"execute":"qmp_capabilities"}\n{"execute":"screendump","arguments":{"filename":"%s/rb-final.ppm"}}\n' "$WORK" |
        timeout 10 socat - "UNIX-CONNECT:${WORK}/qmp-reboot.sock" >/dev/null 2>&1 || true
      log "reboot check: installed system reached '${HOSTNAME_} login:' on serial after ${rb_elapsed}s (screen: $WORK/rb-final.ppm)"
      rb_found=1
      break
    fi
    if command -v tesseract >/dev/null 2>&1; then
      printf '{"execute":"qmp_capabilities"}\n{"execute":"screendump","arguments":{"filename":"%s/rb-shot.ppm"}}\n' "$WORK" |
        timeout 10 socat - "UNIX-CONNECT:${WORK}/qmp-reboot.sock" >/dev/null 2>&1 || true
      if [[ -f $WORK/rb-shot.ppm ]]; then
        rb_txt=$(tesseract "$WORK/rb-shot.ppm" stdout --psm 6 2>/dev/null || true)
        if LC_ALL=C command grep -aqi -e 'login:' -e 'sddm' -e 'gamescope' -e "$HOSTNAME_" <<<"$rb_txt" 2>/dev/null; then
          log "reboot check: login marker reached after ${rb_elapsed}s"
          rb_found=1
          break
        fi
      fi
    fi
    if (( rb_elapsed >= REBOOT_TIMEOUT )); then
      log "reboot check: no login marker within ${REBOOT_TIMEOUT}s"
      break
    fi
  done
  if kill -0 "$rb_pid" 2>/dev/null; then
    kill "$rb_pid" 2>/dev/null || true
    sleep 1
    kill -9 "$rb_pid" 2>/dev/null || true
  fi
  wait "$rb_pid" 2>/dev/null || true
  (( rb_found == 1 )) || status=1
fi

trap - EXIT
cleanup_qemu

if [[ $status -eq 0 ]]; then
  log "PASS -- preinstalls=${PREINSTALLS} gaming=${GAMING} net=${VM_NET:-user} form-delay=${FORM_DELAY}s work dir: $WORK"
else
  log "FAIL -- see above. work dir preserved: $WORK"
fi
exit $status
