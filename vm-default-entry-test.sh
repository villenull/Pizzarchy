#!/usr/bin/env bash
# vm-default-entry-test.sh -- QEMU proof for stage-default-entry, plus T1's
# deliberate-failure tests.
#
# Usage: ./vm-default-entry-test.sh [substrate.raw]
#
# Env vars (all optional):
#   VM_RUN_TIMEOUT_SEC           whole-run ceiling, default 1800
#   VM_MEM_MB / VM_SMP           guest size, defaults 4096 / 4
#   VM_OVMF_CODE / VM_OVMF_VARS  override firmware probing
#   OMARCHY_DECK_NEPTUNE_SERIES  series under test, default 611
#
# ===========================================================================
# WHAT THIS PROVES, AND WHY A BOOT IS THE ONLY HONEST PROOF
# ===========================================================================
#
# stage-default-entry writes Limine's `default_entry:` as an ENTRY PATH
# ("Omarchy/linux-neptune-611") rather than a positional index, because
# limine-snapper-sync renumbers indices as snapshots come and go.
#
# The path form was applied by hand on the operator's Deck and the machine
# booted the right kernel -- but that target was ALSO entry #1, so the
# observation is equally consistent with Limine parsing the path correctly
# OR failing to parse it and silently falling back to the first entry
# (PROGRESS.md 5.3). A fix that works by accident is worse than none.
#
# So this test sets default_entry to an entry that is provably NOT first,
# boots, and asserts on two independent artifacts from inside the guest:
#
#   1. LoaderEntrySelected -- Limine implements the systemd Boot Loader
#      Interface, so the *bootloader itself* records which entry it selected
#      into an EFI variable. This is the bootloader's own testimony, not an
#      inference.
#   2. `uname -r` -- the non-first entry chosen boots a DIFFERENT KERNEL
#      (the stock `linux` UKI, not Neptune), so the running kernel string is
#      an independent witness that cannot agree with a first-entry fallback.
#
# Two boots, one QEMU invocation: boot 1 runs the failure tests and plants
# the non-first default (then reboots); boot 2 checks what actually booted,
# repairs the default with the stage under test, and proves the repair
# idempotent. The guest powers off only at the end of boot 2, so `-no-reboot`
# must NOT be set for this test.
#
# ===========================================================================
# THE DELIBERATE-FAILURE TESTS (TASK-T1 step 8)
# ===========================================================================
#
# "Corrupt the boot chain; confirm the script fails loudly rather than
# continuing." Run in boot 1, each restored before the next:
#
#   F1. Limine config missing entirely -> stage-uki must exit 1 from
#       stage-esp-detect's five-candidate probe, not proceed on a guess.
#   F2. A second UKI file matching the same kernel (omarchy2_<pkg>.efi)
#       -> find_uki_for sees two matches and must refuse (exit 1) rather
#       than pick one. Two boot entries for one kernel is exactly the state
#       whose silent variant cost the first hardware run.
#   F3. stage-default-entry with the UKI's menu entry missing from the
#       config -> must exit 1 refusing to write a default that cannot
#       resolve, not write it anyway.

set -uo pipefail

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BASE_DISK=${1:-$SELF_DIR/neptune-substrate.raw}

RUN_TIMEOUT=${VM_RUN_TIMEOUT_SEC:-1800}
MEM_MB=${VM_MEM_MB:-4096}
SMP=${VM_SMP:-4}
SERIES=${OMARCHY_DECK_NEPTUNE_SERIES:-611}

WORK=${VM_WORK_DIR:-$(mktemp -d /var/tmp/vm-default-entry.XXXXXX)}

log() { printf '[vm-default-entry] %s\n' "$*" >&2; }
fail() { log "FAIL: $*"; exit 1; }

[[ -f $SELF_DIR/omarchy-deck-kernel.sh ]] || fail "omarchy-deck-kernel.sh not found next to this script"
if [[ ! -f $BASE_DISK ]]; then
  log "substrate image not found at $BASE_DISK -- building it"
  IMG_NEPTUNE_SERIES=$SERIES "$SELF_DIR/vm-neptune-image.sh" "$BASE_DISK" ||
    fail "could not build the substrate image"
fi

for tool in qemu-system-x86_64 qemu-img mcopy sfdisk base64; do
  command -v "$tool" >/dev/null || fail "required tool '$tool' not found"
done

# shellcheck source=vm-disk-image.sh
source "$SELF_DIR/vm-disk-image.sh"

find_ovmf() {
  local c
  for c in "$@"; do [[ -f $c ]] && { printf '%s\n' "$c"; return 0; }; done
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
[[ -n $OVMF_CODE && -f $OVMF_CODE ]] || fail "OVMF CODE firmware not found — install edk2-ovmf. Override with VM_OVMF_CODE."
[[ -n $OVMF_VARS_TEMPLATE && -f $OVMF_VARS_TEMPLATE ]] || fail "OVMF VARS firmware not found. Override with VM_OVMF_VARS."

if [[ -r /dev/kvm && -w /dev/kvm ]]; then
  ACCEL_ARGS=(-cpu host -enable-kvm -machine "q35,accel=kvm")
else
  log "WARNING: /dev/kvm not accessible — falling back to TCG (slow)."
  ACCEL_ARGS=(-cpu max -machine "q35,accel=tcg")
fi

mkdir -p "$WORK"
log "work dir: $WORK"

disk="$WORK/target.raw"
ovmf_vars="$WORK/OVMF_VARS.fd"
result_img="$WORK/result.raw"
result_txt="$WORK/report.txt"
pidfile="$WORK/qemu.pid"
serial_log="$WORK/serial.log"

log "copying the substrate image (the test must not mutate it)"
case $BASE_DISK in
  *.qcow2) qemu-img convert -O raw "$BASE_DISK" "$disk" || fail "qemu-img convert failed" ;;
  *)       cp --reflink=auto --sparse=always "$BASE_DISK" "$disk" || fail "cp of the substrate image failed" ;;
esac

cp "$OVMF_VARS_TEMPLATE" "$ovmf_vars"
qemu-img create -f raw "$result_img" 64M >/dev/null

# --- payload -----------------------------------------------------------------

probe_src="$WORK/omarchy-deck-defent-probe.sh"
cat >"$probe_src" <<'PROBE'
#!/usr/bin/env bash
# In-guest probe. NOT `set -e`: a failure of the thing under test is a result
# to report, not a reason to abort before reporting it.
set -uo pipefail

RESULT_DEV=/dev/disk/by-id/virtio-vmresult
OUT=/root/defenttest
mkdir -p "$OUT"
exec >>"$OUT/probe.log" 2>&1
exec {xtrace_fd}>>"$OUT/probe.trace"
BASH_XTRACEFD=$xtrace_fd
set -x

SERIES=${OMARCHY_DECK_NEPTUNE_SERIES:-611}
KP="linux-neptune-${SERIES}"
SCRIPT=/root/omarchy-deck-kernel.sh
CONF=/boot/limine.conf
RESULTS=$OUT/results
STAGE_TIMEOUT=${STAGE_TIMEOUT_SEC:-900}

emit() { printf '%s\n' "$*" >>"$RESULTS"; }
run_isolated() {
  local logfile=$1
  shift
  setsid --wait timeout "$STAGE_TIMEOUT" "$@" >"$logfile" 2>&1 </dev/null
}

# menu_path_of <uki-basename> -- same parse stage-default-entry does, kept
# test-local on purpose: agreeing with the script by construction would prove
# nothing.
menu_path_of() {
  UKI_BASE="$1" awk '
    BEGIN {
      base = ENVIRON["UKI_BASE"]
      gsub(/[][\\.^$*+?(){}|]/, "\\\\&", base)
      uki_re = "/EFI/Linux/" base "(#|[[:space:]]|$)"
      curdepth = 0
    }
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line ~ /^\//) {
        depth = 0
        while (substr(line, depth + 1, 1) == "/") depth++
        name = substr(line, depth + 1)
        sub(/^\+/, "", name)
        sub(/[[:space:]]+$/, "", name)
        names[depth] = name
        curdepth = depth
        next
      }
      if (line ~ /^path:/ && line ~ uki_re && curdepth > 0) {
        p = names[1]
        for (i = 2; i <= curdepth; i++) p = p "/" names[i]
        print p
        found = 1
        exit
      }
    }
    END { if (!found) exit 1 }
  ' "$CONF"
}

# first_menu_path -- the menu path of the FIRST bootable leaf in the config,
# i.e. what a parse-failure fallback would boot.
first_menu_path() {
  awk '
    BEGIN { curdepth = 0 }
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line ~ /^\//) {
        depth = 0
        while (substr(line, depth + 1, 1) == "/") depth++
        name = substr(line, depth + 1)
        sub(/^\+/, "", name)
        sub(/[[:space:]]+$/, "", name)
        names[depth] = name
        curdepth = depth
        next
      }
      if (line ~ /^path:/ && curdepth > 0) {
        p = names[1]
        for (i = 2; i <= curdepth; i++) p = p "/" names[i]
        print p
        exit
      }
    }
  ' "$CONF"
}

read_default() {
  sed -nE 's/^[[:space:]]*default_entry:[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p' "$CONF" | head -n 1
}

set_default_raw() {
  # Raw write, deliberately NOT via the script under test: boot 2 must verify
  # what LIMINE does with a path-form default, not what the script wrote.
  if grep -qE '^[[:space:]]*default_entry:' "$CONF"; then
    sed -i -E "s|^[[:space:]]*default_entry:.*|default_entry: $1|" "$CONF"
  else
    sed -i "1i default_entry: $1" "$CONF"
  fi
  [[ $(read_default) == "$1" ]]
}

loader_entry_selected() {
  # UTF-16LE EFI variable with a 4-byte attribute prefix; Limine implements
  # the Boot Loader Interface (verified on hardware via bootctl, session 7).
  local var=/sys/firmware/efi/efivars/LoaderEntrySelected-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f
  [[ -e $var ]] || return 1
  tail -c +5 "$var" | iconv -f UTF-16LE -t ASCII 2>/dev/null | tr -d '\0'
}

if [[ ! -f /root/defenttest/phase1-done ]]; then
  # =========================================================================
  # BOOT 1 -- failure tests, then plant a non-first default and reboot
  # =========================================================================
  emit "phase1.ran=1"
  emit "phase1.uname=$(uname -r)"
  emit "phase1.initial_default=$(read_default)"

  cp "$CONF" "$OUT/limine.conf.original"

  neptune_path=$(menu_path_of "omarchy_${KP}.efi"); nrc=$?
  stock_path=$(menu_path_of "omarchy_linux.efi"); src=$?
  first_path=$(first_menu_path)
  emit "phase1.neptune_menu_path_rc=$nrc"
  emit "phase1.stock_menu_path_rc=$src"
  emit "phase1.neptune_menu_path=$neptune_path"
  emit "phase1.stock_menu_path=$stock_path"
  emit "phase1.first_menu_path=$first_path"

  # The boot-proof target must not be first. The stock `linux` entry is used
  # if it qualifies; if the menu ever ordered it first, neptune would be the
  # non-first one instead.
  if [[ -n $stock_path && $stock_path != "$first_path" ]]; then
    chosen=$stock_path chosen_kind=stock
  elif [[ -n $neptune_path && $neptune_path != "$first_path" ]]; then
    chosen=$neptune_path chosen_kind=neptune
  else
    chosen="" chosen_kind=none
  fi
  emit "phase1.chosen=$chosen"
  emit "phase1.chosen_kind=$chosen_kind"
  printf '%s\n' "$chosen" >"$OUT/chosen-path"
  printf '%s\n' "$chosen_kind" >"$OUT/chosen-kind"

  # --- F1: config missing -> stage-uki fails loudly --------------------------
  mv "$CONF" "$CONF.aside"
  run_isolated "$OUT/f1.out" bash "$SCRIPT" stage-uki
  emit "fail.missing_config_exit=$?"
  grep -q "no Limine config at any candidate location" "$OUT/f1.out"
  emit "fail.missing_config_msg=$((1 - $?))"
  mv "$CONF.aside" "$CONF"

  # --- F2: duplicate UKI for one kernel -> refuses to choose -----------------
  cp "/boot/EFI/Linux/omarchy_${KP}.efi" "/boot/EFI/Linux/omarchy2_${KP}.efi"
  run_isolated "$OUT/f2.out" bash "$SCRIPT" stage-uki
  emit "fail.dup_uki_exit=$?"
  grep -q "2 UKIs" "$OUT/f2.out"
  emit "fail.dup_uki_msg=$((1 - $?))"
  rm -f "/boot/EFI/Linux/omarchy2_${KP}.efi"

  # --- F3: menu entry missing -> stage-default-entry refuses -----------------
  # Strip the Neptune entry's path: line (keep the file valid otherwise).
  grep -vE "^[[:space:]]*path:.*/EFI/Linux/omarchy_${KP}\.efi(#|[[:space:]]|$)" "$CONF" >"$CONF.stripped"
  cp "$CONF" "$CONF.aside"
  cp "$CONF.stripped" "$CONF"
  run_isolated "$OUT/f3.out" bash "$SCRIPT" stage-default-entry
  emit "fail.no_menu_entry_exit=$?"
  grep -q "no Limine menu entry" "$OUT/f3.out"
  emit "fail.no_menu_entry_msg=$((1 - $?))"
  cp "$CONF.aside" "$CONF"
  rm -f "$CONF.stripped" "$CONF.aside"

  # Post-restore sanity: the config is byte-identical to how boot 1 found it.
  cmp -s "$CONF" "$OUT/limine.conf.original"
  emit "fail.config_restored=$((1 - $?))"

  # --- plant the non-first default for boot 2 --------------------------------
  if [[ -n $chosen ]]; then
    set_default_raw "$chosen"
    emit "phase1.planted=$((1 - $?))"
  else
    emit "phase1.planted=0"
  fi

  touch /root/defenttest/phase1-done
  sync
  systemctl reboot -i
else
  # =========================================================================
  # BOOT 2 -- what did Limine actually boot?
  # =========================================================================
  emit "phase2.ran=1"
  chosen=$(cat "$OUT/chosen-path" 2>/dev/null)
  chosen_kind=$(cat "$OUT/chosen-kind" 2>/dev/null)

  sel=$(loader_entry_selected); selrc=$?
  emit "phase2.loader_var_present=$((1 - (selrc > 0 ? 1 : 0)))"
  emit "phase2.loader_entry_selected=$sel"
  emit "phase2.chosen=$chosen"
  emit "phase2.selected_matches_chosen=$([[ -n $chosen && $sel == "$chosen" ]] && echo 1 || echo 0)"

  # Independent witness: the chosen stock entry boots the stock kernel, which
  # contains no 'neptune'. A first-entry fallback would have booted Neptune.
  running=$(uname -r)
  emit "phase2.uname=$running"
  case $chosen_kind in
    stock)   [[ $running != *neptune* ]] && emit "phase2.kernel_witness=1" || emit "phase2.kernel_witness=0" ;;
    neptune) [[ $running == *neptune* ]] && emit "phase2.kernel_witness=1" || emit "phase2.kernel_witness=0" ;;
    *)       emit "phase2.kernel_witness=0" ;;
  esac

  # --- the stage under test: repair to the Neptune path, prove idempotent ----
  run_isolated "$OUT/repair1.out" bash "$SCRIPT" stage-default-entry
  emit "repair.first_exit=$?"
  emit "repair.default_after=$(read_default)"
  neptune_path=$(menu_path_of "omarchy_${KP}.efi")
  emit "repair.expected=$neptune_path"
  emit "repair.matches=$([[ -n $neptune_path && $(read_default) == "$neptune_path" ]] && echo 1 || echo 0)"

  h_before=$(sha256sum "$CONF" | cut -d' ' -f1)
  run_isolated "$OUT/repair2.out" bash "$SCRIPT" stage-default-entry
  emit "repair.second_exit=$?"
  h_after=$(sha256sum "$CONF" | cut -d' ' -f1)
  emit "repair.second_writes_nothing=$([[ $h_before == "$h_after" ]] && echo 1 || echo 0)"
  grep -q "default_entry up to date" "$OUT/repair2.out"
  emit "repair.second_says_up_to_date=$((1 - $?))"

  # reconcile must also hold the value (the pacman hook re-asserts it).
  run_isolated "$OUT/reconcile.out" bash "$SCRIPT" reconcile
  emit "repair.reconcile_exit=$?"
  emit "repair.reconcile_default=$(read_default)"

  {
    echo "=== OMARCHY-DECK DEFAULT-ENTRY PROBE ==="
    cat "$RESULTS"
    echo "=== F1 (missing config) ==="; cat "$OUT/f1.out" 2>/dev/null
    echo "=== F2 (duplicate UKI) ==="; cat "$OUT/f2.out" 2>/dev/null
    echo "=== F3 (no menu entry) ==="; cat "$OUT/f3.out" 2>/dev/null
    echo "=== REPAIR 1 ==="; cat "$OUT/repair1.out" 2>/dev/null
    echo "=== REPAIR 2 ==="; cat "$OUT/repair2.out" 2>/dev/null
    echo "=== RECONCILE ==="; cat "$OUT/reconcile.out" 2>/dev/null
    echo "=== FINAL limine.conf ==="; cat "$CONF"
    echo "=== END ==="
  } >"$OUT/report.txt" 2>&1

  if [[ -b $RESULT_DEV ]]; then
    dd if="$OUT/report.txt" of="$RESULT_DEV" bs=1M conv=fsync status=none
  fi
  sync
  systemctl poweroff -i
fi
PROBE

unit_text="[Unit]
Description=T1 default-entry + deliberate-failure probe
Before=graphical.target

[Service]
Type=oneshot
Environment=OMARCHY_DECK_NEPTUNE_SERIES=${SERIES}
ExecStartPre=/usr/bin/cp /boot/omarchy-deck-defent-probe.sh /root/omarchy-deck-defent-probe.sh
ExecStartPre=/usr/bin/cp /boot/omarchy-deck-kernel.sh /root/omarchy-deck-kernel.sh
ExecStart=/usr/bin/bash /root/omarchy-deck-defent-probe.sh
TimeoutStartSec=0
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console
"
dropin_text="[Unit]
Wants=omarchy-deck-defent.service
"

log "writing payload onto the guest ESP (rootless, mtools at byte offset)"
esp_offset=$(disk_image::esp_offset "$disk") || fail "could not locate the ESP on $disk"
MTOOLS_SKIP_CHECK=1 mcopy -o -i "${disk}@@${esp_offset}" \
  "$SELF_DIR/omarchy-deck-kernel.sh" "::/omarchy-deck-kernel.sh" ||
  fail "mcopy of omarchy-deck-kernel.sh onto the ESP failed"
MTOOLS_SKIP_CHECK=1 mcopy -o -i "${disk}@@${esp_offset}" \
  "$probe_src" "::/omarchy-deck-defent-probe.sh" ||
  fail "mcopy of the probe onto the ESP failed"

cred_unit="io.systemd.credential.binary:systemd.extra-unit.omarchy-deck-defent.service=$(base64 -w0 <<<"$unit_text")"
cred_dropin="io.systemd.credential.binary:systemd.unit-dropin.multi-user.target=$(base64 -w0 <<<"$dropin_text")"

# --- boot (NO -no-reboot: the test's whole design is boot 1 -> reboot -> boot 2)

log "booting the substrate headless (timeout ${RUN_TIMEOUT}s, two boots expected)"
qemu-system-x86_64 \
  "${ACCEL_ARGS[@]}" \
  -smp "$SMP" -m "$MEM_MB" \
  -smbios type=1,manufacturer=Valve,product=Galileo,version=1 \
  -smbios type=2,manufacturer=Valve,product=Galileo \
  -smbios "type=11,value=${cred_unit}" \
  -smbios "type=11,value=${cred_dropin}" \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
  -drive if=pflash,format=raw,file="$ovmf_vars" \
  -drive file="$disk",format=raw,if=none,id=drive0 \
  -device virtio-blk-pci,drive=drive0,bootindex=1 \
  -drive file="$result_img",format=raw,if=none,id=result0 \
  -device virtio-blk-pci,drive=result0,serial=vmresult \
  -nic none \
  -display none -vga std \
  -serial "file:${serial_log}" \
  -daemonize -pidfile "$pidfile" ||
  fail "qemu-system-x86_64 failed to launch"

qemu_pid=$(cat "$pidfile")
log "qemu pid $qemu_pid"

elapsed=0
while kill -0 "$qemu_pid" 2>/dev/null; do
  sleep 15
  elapsed=$((elapsed + 15))
  if (( elapsed >= RUN_TIMEOUT )); then
    kill "$qemu_pid" 2>/dev/null
    sleep 2
    kill -9 "$qemu_pid" 2>/dev/null
    fail "guest did not power off within ${RUN_TIMEOUT}s (work dir preserved: $WORK)"
  fi
done
log "guest powered off after ${elapsed}s"

# --- results -----------------------------------------------------------------

tr -d '\0' <"$result_img" >"$result_txt"
[[ -s $result_txt ]] || fail "the guest wrote nothing to the result device — it never reached phase 2. Check $serial_log and $WORK."
log "report: $result_txt"

field() {
  local key=$1 line
  while IFS= read -r line; do
    if [[ $line == "${key}="* ]]; then
      printf '%s\n' "${line#*=}"
      return 0
    fi
  done <"$result_txt"
  return 1
}

status=0
check() {
  local what=$1 got=$2 want=$3
  if [[ $got == "$want" ]]; then
    log "ok   ${what} = ${got}"
  else
    log "FAIL ${what} = '${got}' (expected '${want}')"
    status=1
  fi
}
check_nonempty() {
  local what=$1 got=$2
  if [[ -n $got ]]; then
    log "ok   ${what} = ${got}"
  else
    log "FAIL ${what} is empty"
    status=1
  fi
}

# Phase 1 ran and could resolve both entries in the menu.
check "phase1.ran"                 "$(field phase1.ran)" 1
check "phase1.neptune_menu_path_rc" "$(field phase1.neptune_menu_path_rc)" 0
check "phase1.stock_menu_path_rc"   "$(field phase1.stock_menu_path_rc)" 0
check_nonempty "phase1.first_menu_path" "$(field phase1.first_menu_path)"

# The boot-proof target genuinely is not the first entry, or the test is vacuous.
chosen=$(field phase1.chosen)
first=$(field phase1.first_menu_path)
check_nonempty "phase1.chosen" "$chosen"
if [[ -n $chosen && $chosen == "$first" ]]; then
  log "FAIL chosen entry '$chosen' IS the first entry — the boot proof would be vacuous"
  status=1
fi
check "phase1.planted" "$(field phase1.planted)" 1

# Deliberate failures: loud, correct, and fully restored.
check "fail.missing_config_exit" "$(field fail.missing_config_exit)" 1
check "fail.missing_config_msg"  "$(field fail.missing_config_msg)" 1
check "fail.dup_uki_exit"        "$(field fail.dup_uki_exit)" 1
check "fail.dup_uki_msg"         "$(field fail.dup_uki_msg)" 1
check "fail.no_menu_entry_exit"  "$(field fail.no_menu_entry_exit)" 1
check "fail.no_menu_entry_msg"   "$(field fail.no_menu_entry_msg)" 1
check "fail.config_restored"     "$(field fail.config_restored)" 1

# THE claim: the bootloader itself says it selected the planted path.
check "phase2.ran"                     "$(field phase2.ran)" 1
check "phase2.loader_var_present"      "$(field phase2.loader_var_present)" 1
check "phase2.selected_matches_chosen" "$(field phase2.selected_matches_chosen)" 1
check "phase2.kernel_witness"          "$(field phase2.kernel_witness)" 1

# The stage repairs, verifies, and is idempotent; reconcile holds the value.
check "repair.first_exit"              "$(field repair.first_exit)" 0
check "repair.matches"                 "$(field repair.matches)" 1
check "repair.second_exit"             "$(field repair.second_exit)" 0
check "repair.second_writes_nothing"   "$(field repair.second_writes_nothing)" 1
check "repair.second_says_up_to_date"  "$(field repair.second_says_up_to_date)" 1
check "repair.reconcile_exit"          "$(field repair.reconcile_exit)" 0
check "repair.reconcile_default"       "$(field repair.reconcile_default)" "$(field repair.expected)"

if [[ $status -eq 0 ]]; then
  log "PASS — path-form default_entry proven by boot (LoaderEntrySelected='$(field phase2.loader_entry_selected)', kernel='$(field phase2.uname)'), failure tests loud, repair idempotent"
  rm -rf "$WORK"
else
  log "FAILED — full report: $result_txt (work dir preserved: $WORK)"
fi
exit $status
