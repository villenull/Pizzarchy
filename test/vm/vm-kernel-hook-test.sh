#!/usr/bin/env bash
# T1 step 3: prove the pacman hook installed by omarchy-deck-kernel.sh really
# fires, really reconciles the UKI + Limine entry, and really cannot duplicate
# entries -- by doing it in a VM, not by reading the hook.
#
# Usage: ./vm-kernel-hook-test.sh [substrate-image] [work-dir]
#
# The substrate image defaults to ./neptune-substrate.raw and is built by
# vm-neptune-image.sh (read its header for what it is and why it is not a
# full Omarchy Quattro install). If the file is missing this script builds it.
#
# Env vars (all optional):
#   VM_MEM_MB          default 4096
#   VM_SMP             default min(nproc,4)
#   VM_RUN_TIMEOUT_SEC default 3600
#   VM_OVMF_CODE / VM_OVMF_VARS  override firmware probing
#   VM_NEPTUNE_SERIES  default 611; must match the image's kernel
#
# WHAT IT ASSERTS, AND WHY EACH ONE IS THERE
#
#   install         omarchy-deck-kernel.sh exits 0 and leaves
#                   /etc/pacman.d/hooks/95-omarchy-deck-kernel.hook and an
#                   executable /usr/local/bin/omarchy-deck-kernel behind.
#
#   reinstall 1     `pacman -S linux-neptune-<series>` (a reinstall, which
#                   libalpm classifies as an Upgrade) fires BOTH upstream's
#                   90-mkinitcpio-install hook and this project's 95- hook,
#                   the UKI is really regenerated, and the Limine config
#                   references it exactly once. It also asserts that OUR hook
#                   did not rebuild anything -- upstream's had already done
#                   it, and a 95- hook that rebuilt too would be exactly the
#                   redundant work this design set out not to do.
#
#                   "Really regenerated" is proven with a BUILD NONCE -- see
#                   WHY THE ORACLE IS A NONCE below. Two earlier oracles were
#                   tried here and both are wrong; do not "simplify" back to
#                   either one.
#
#   reinstall 2     Same again. entry_refs is still exactly 1. This is the
#                   "must not duplicate entries on repeat runs" requirement,
#                   tested rather than argued.
#
#   gap A           Delete the UKI behind Limine's back, then run the hook's
#                   own command by hand. This is the shape of upstream's
#                   silent failure (limine-mkinitcpio-install's per-kernel
#                   error paths are `error_msg ...; continue`, so it can
#                   leave no UKI and still exit 0). The reconcile must
#                   notice and rebuild -- if it only ever verified on a
#                   healthy system it would be decoration.
#
#   gap B           Fabricate a stale linux-neptune-999 UKI + Limine entry,
#                   the state upstream's remove path leaves behind when
#                   limine-entry-tool fails (post_remove never checks it and
#                   deletes removed_kernels.list unconditionally). The
#                   reconcile's prune must remove both.
#
#   remove          `pacman -Rdd linux-neptune-<series>` fires the hook with
#                   zero Neptune kernels installed; UKI and entry must both
#                   be gone and the run must still exit 0.
#
# WHY THE ORACLE IS A NONCE, AND NOT AN mtime SENTINEL OR A BARE sha256
#
# Proving "this UKI was really rebuilt" is harder than it looks, because the
# two obvious probes are each defeated by a different property of the stack.
#
#   sha256 alone.       Defeated by reproducibility. mkinitcpio's UKI output
#                       is byte-reproducible, so a genuine rebuild from
#                       unchanged inputs produces the identical file. The
#                       first version of this test asserted "the sha changed"
#                       and failed on a correct system. (That also corrects a
#                       claim in omarchy-deck-kernel.sh's own comments,
#                       written before anyone measured it.)
#
#   mtime sentinel.     Defeated by a content-addressed installer. The second
#                       version stamped the UKI to 2000-01-01 before the
#                       reinstall and asserted the stamp was gone afterwards.
#                       That held only because limine-mkinitcpio-hook 1.36.0
#                       ended limine-mkinitcpio-install with an unconditional
#                           mv -f "${tmp_uki_path}" "${uki_path}"
#                       so every rebuild rewrote the destination whether or
#                       not its bytes had changed. 1.37.1 deleted that mv:
#                       mkinitcpio now builds into a temp dir and the ESP
#                       write is delegated to the compiled limine-entry-tool
#                           limine-entry-tool --add-uki "$name" "$file" ...
#                       which is content-addressed and silently does not
#                       rewrite a byte-identical UKI. So on 1.37.1 the stamp
#                       survives a real rebuild and the assertion fails on a
#                       correct system. Measured 2026-08-11 by running this
#                       suite against both substrates: PASS on the `stable`
#                       one (hook 1.36.0-1), FAIL on the `edge` one (hook
#                       1.37.1-1), with limine itself identical at 12.5.2-1 in
#                       both. Gap A below rebuilt correctly in the same failing
#                       run -- when the destination is ABSENT the write does
#                       happen, with a fresh mtime -- which is what proved the
#                       skip is content-conditional and not our bug.
#
#                       Worse, the stamp perturbed the system under test.
#                       omarchy-deck-kernel's idempotency guard is
#                       `test "$uki" -nt "$moddir/vmlinuz"`, so a UKI stamped
#                       to 2000-01-01 looks stale to it and it correctly
#                       rebuilds -- tripping the "our hook must not rebuild"
#                       assertion too. On 1.36.0 the unconditional mv erased
#                       the stamp before our hook ever looked, which is the
#                       only reason that assertion used to pass.
#
#   nonce (current).    Perturb the INPUTS, not the artifact. A unique value
#                       is written to /etc/omarchy-deck-uki-nonce, which is
#                       listed in mkinitcpio's FILES=() and is therefore an
#                       input to every initramfs. Change it before a reinstall
#                       and a genuine rebuild MUST produce different bytes;
#                       assert the sha256 changed. This is immune to both
#                       defeats above -- reproducibility is what makes it
#                       sound (identical bytes now mean identical inputs, so a
#                       changed sha can only mean the build really re-ran) and
#                       a content-addressed installer is obliged to write
#                       because the content genuinely differs. It also proves
#                       strictly more than either predecessor: not "a file was
#                       written" but "the initramfs was regenerated from
#                       current inputs", which is the property that actually
#                       matters and the one that survives the next upstream
#                       rearrangement of who copies what to the ESP.
#
# The mtime is still reported at every phase, and reinstall{1,2} additionally
# report uki_mtime_changed. Those are OBSERVATIONS, deliberately not asserted.
# They are worth keeping because they are how the two stacks were told apart,
# but read them carefully -- the naive reading is wrong on BOTH, which is the
# whole reason this suite no longer asserts on them. Measured 2026-08-11, on
# runs where the nonce proved the UKI really was rebuilt each time:
#
#   1.36.0  uki_mtime_changed=0, mtime frozen at 2026-07-23 17:43:58Z across
#           every phase -- a rebuild that provably changed the UKI's bytes did
#           not move its mtime at all. mkinitcpio gives the UKI a REPRODUCIBLE
#           timestamp (a function of the inputs, not of when the build ran) and
#           `mv -f` carries that onto the ESP. So the mtime here says nothing
#           about whether a build happened. The old sentinel worked only by
#           accident: 2000-01-01 is not that canonical value, so restoring the
#           canonical value happened to erase the stamp.
#
#   1.37.1  uki_mtime_changed=1, mtimes advancing in real time (…906 → …924 →
#           …932). limine-entry-tool stamps wall-clock time WHEN IT WRITES,
#           and skips writing a byte-identical UKI -- which is why the sentinel
#           survives a real rebuild here and the old assertion failed.
#
# So mtime is input-derived on one stack and write-conditional on the other,
# and is a sound proof of regeneration on neither. Do not turn these back into
# assertions.
#
# Every assertion is on state read back from the ESP and the Limine config,
# never on log text -- except the two "did this hook run at all" checks,
# where pacman's own hook Description line is the only evidence there is.
# PLAN.md 8.1 is why: upstream has printed success while doing nothing.

set -uo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

# shellcheck source=../lib/vm-disk-image.sh
source "$REPO_ROOT/test/lib/vm-disk-image.sh"

BASE_DISK=${1:-$REPO_ROOT/test/images/neptune-substrate.raw}
WORK=${2:-$(mktemp -d /var/tmp/vm-kernel-hook.XXXXXX)}

MEM_MB=${VM_MEM_MB:-4096}
DEFAULT_SMP=$(( $(nproc) < 4 ? $(nproc) : 4 ))
SMP=${VM_SMP:-$DEFAULT_SMP}
RUN_TIMEOUT=${VM_RUN_TIMEOUT_SEC:-3600}
SERIES=${VM_NEPTUNE_SERIES:-611}

log() { printf '[vm-kernel-hook] %s\n' "$*" >&2; }
fail() { log "FAIL: $*"; exit 1; }

[[ -f $REPO_ROOT/src/omarchy-deck-kernel.sh ]] || fail "omarchy-deck-kernel.sh not found next to this script"

for tool in qemu-system-x86_64 qemu-img mcopy sfdisk base64; do
  command -v "$tool" >/dev/null || fail "$tool not found"
done

if [[ ! -f $BASE_DISK ]]; then
  log "substrate image not found at $BASE_DISK -- building it"
  IMG_NEPTUNE_SERIES=$SERIES "$REPO_ROOT/test/images/vm-neptune-image.sh" "$BASE_DISK" ||
    fail "could not build the substrate image"
fi

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
[[ -n $OVMF_CODE && -f $OVMF_CODE ]] || fail "OVMF CODE firmware not found — install edk2-ovmf (Arch) / ovmf (Debian). Override with VM_OVMF_CODE."
[[ -n $OVMF_VARS_TEMPLATE && -f $OVMF_VARS_TEMPLATE ]] || fail "OVMF VARS firmware not found. Override with VM_OVMF_VARS."

if [[ -r /dev/kvm && -w /dev/kvm ]]; then
  ACCEL_ARGS=(-cpu host -enable-kvm -machine "q35,accel=kvm")
else
  log "WARNING: /dev/kvm not accessible — falling back to TCG. This test rebuilds initramfses several times; under TCG expect it to exceed the default timeout."
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

probe_src="$WORK/omarchy-deck-hook-probe.sh"
cat >"$probe_src" <<'PROBE'
#!/usr/bin/env bash
# In-guest probe for the pacman hook. Deliberately NOT `set -e`: a failure of
# the thing under test is a result to report, not a reason to abort before
# reporting it.
set -uo pipefail

RESULT_DEV=/dev/disk/by-id/virtio-vmresult
OUT=/root/hook
mkdir -p "$OUT"
exec >"$OUT/probe.log" 2>&1
exec {xtrace_fd}>>"$OUT/probe.trace"
BASH_XTRACEFD=$xtrace_fd
set -x

SERIES=${OMARCHY_DECK_NEPTUNE_SERIES:-611}
KP="linux-neptune-${SERIES}"
UKI="/boot/EFI/Linux/omarchy_${KP}.efi"
STALE_KP="linux-neptune-999"
STALE_UKI="/boot/EFI/Linux/omarchy_${STALE_KP}.efi"
HOOK=/etc/pacman.d/hooks/95-omarchy-deck-kernel.hook
HOOK_SCRIPT=/usr/local/bin/omarchy-deck-kernel

# Nothing may execute out of /boot: bash holds an open fd on the script it is
# running, which makes the ESP busy and breaks the umount/mount cycle for a
# reason that has nothing to do with the system under test.
SCRIPT=/root/omarchy-deck-kernel.sh
[[ -f $SCRIPT ]] || exit 90

RESULTS=$OUT/results
: >"$RESULTS"
emit() { printf '%s\n' "$*" >>"$RESULTS"; }

online=0
for _ in $(seq 1 60); do
  if getent hosts steamdeck-packages.steamos.cloud >/dev/null 2>&1; then online=1; break; fi
  sleep 5
done
emit "network_resolved=$online"

NONCE_FILE=/etc/omarchy-deck-uki-nonce
nonce_seq=0

uki_sha()   { [[ -f $UKI ]] && sha256sum "$UKI" | cut -d' ' -f1; }
uki_mtime() { [[ -f $UKI ]] && stat -c %Y "$UKI"; }

# stamp_nonce -- write a fresh unique value into an initramfs INPUT, so that
# the next genuine rebuild is obliged to produce different bytes.
stamp_nonce() {
  nonce_seq=$((nonce_seq + 1))
  printf 'omarchy-deck-uki-nonce %s %s\n' "$nonce_seq" "$(date +%s%N)" >"$NONCE_FILE"
}

# --- 0. arm the regeneration oracle -------------------------------------------
# The UKI's mtime is NOT a usable proof of rebuild: limine-mkinitcpio-hook
# 1.36.0 ended limine-mkinitcpio-install with an unconditional
# `mv -f "$tmp_uki_path" "$uki_path"`, but 1.37.1 deleted that and delegates
# the ESP write to `limine-entry-tool --add-uki`, which is content-addressed
# and silently does not rewrite a byte-identical UKI. And a bare sha256 is no
# proof either, because mkinitcpio's UKI output is byte-reproducible. So make
# the INPUTS differ instead: listing the nonce in FILES=() puts it inside
# every initramfs, and then a changed sha256 can only mean the build re-ran.
# Full account: WHY THE ORACLE IS A NONCE at the top of this file.
#
# If the sed below ever stops matching, nonce_files_configured goes to 0 and
# the suite fails there rather than silently degrading into the sha256 oracle
# that reproducibility already defeated.
stamp_nonce
sed -i "s|^FILES=()\$|FILES=(${NONCE_FILE})|" /etc/mkinitcpio.conf
emit "nonce_file_present=$([[ -f $NONCE_FILE ]] && echo 1 || echo 0)"
emit "nonce_files_configured=$(LC_ALL=C command grep -qaxF "FILES=(${NONCE_FILE})" /etc/mkinitcpio.conf && echo 1 || echo 0)"

# State is read back from the ESP and the Limine config every time, never
# remembered from a previous step.
snap() {
  local tag=$1
  local present=0 sha="" mtime="" refs=0 stale_present=0 stale_refs=0 nept=0
  [[ -f $UKI ]] && present=1
  [[ -f $UKI ]] && sha=$(sha256sum "$UKI" | cut -d' ' -f1)
  [[ -f $UKI ]] && mtime=$(stat -c %Y "$UKI")
  # Anchored to real bootable entries under /EFI/Linux/, NOT a bare substring
  # count: the substrate now carries a genuine limine-snapper-sync Snapshots
  # submenu whose limine_history/ path lines embed the same UKI basenames. A
  # substring count reads 2 for a correct config -- the exact miscount that
  # failed the first physical hardware run (PROGRESS.md 3.6 bug 1), which
  # this probe itself carried until the substrate could finally expose it.
  #
  # ⚠️ A CHECK THAT PROVES SOMETHING IS ABSENT MUST ALSO PROVE IT WAS LOOKING.
  # Both counts below are asserted to be 0 somewhere in this suite
  # (after_gapB.stale_refs, after_remove.entry_refs), and `grep -c` on a file
  # that does not exist exits 2 and prints nothing -- which the `|| true` then
  # swallows. Emit whether the file was even there, so "0 references" and "no
  # config to reference anything" stop looking identical, and so does "the
  # config is there but empty".
  local conf_present=0 conf_lines=0
  if [[ -f /boot/limine.conf ]]; then
    conf_present=1
    conf_lines=$(LC_ALL=C command grep -ac '' /boot/limine.conf 2>/dev/null || echo 0)
  fi
  refs=$(LC_ALL=C command grep -acE "^[[:space:]]*path:.*/EFI/Linux/omarchy_${KP}\.efi(#|[[:space:]]|$)" /boot/limine.conf 2>/dev/null || true)
  [[ -f $STALE_UKI ]] && stale_present=1
  stale_refs=$(LC_ALL=C command grep -acE "^[[:space:]]*path:.*/EFI/Linux/omarchy_${STALE_KP}\.efi(#|[[:space:]]|$)" /boot/limine.conf 2>/dev/null || true)
  nept=$(find /boot/EFI/Linux -maxdepth 1 -name '*linux-neptune-*.efi' 2>/dev/null | wc -l)
  emit "${tag}.uki_present=${present}"
  emit "${tag}.uki_sha=${sha}"
  # OBSERVATION, not an assertion -- see the mtime note at the top of the file.
  emit "${tag}.uki_mtime=${mtime}"
  emit "${tag}.entry_refs=${refs}"
  emit "${tag}.stale_present=${stale_present}"
  emit "${tag}.stale_refs=${stale_refs}"
  emit "${tag}.neptune_ukis=${nept}"
  emit "${tag}.limine_conf_present=${conf_present}"
  emit "${tag}.limine_conf_lines=${conf_lines}"
  {
    echo "--- ${tag} ---"
    ls -la /boot/EFI/Linux/ 2>&1
    echo "--- ${tag} limine.conf ---"
    cat /boot/limine.conf 2>&1
    echo "--- ${tag} mount ---"
    findmnt -n -o TARGET,FSTYPE,OPTIONS --mountpoint /boot 2>&1
  } >>"$OUT/state.txt" 2>&1
}

# Did pacman announce each hook? The Description line pacman prints is the
# only evidence that a hook was selected and run at all.
hooks_fired() {
  local tag=$1 file=$2 up=0 ours=0 ours_rebuilt=0 log_lines=0
  # ⚠️ THE ONE BELOW THAT IS ASSERTED TO BE ZERO IS `our_hook_rebuilt`, and a
  # `grep -q` against a file that does not exist exits 2, which is
  # indistinguishable here from exit 1 ("looked, found nothing"). A pacman log
  # that failed to be written would therefore report the healthiest possible
  # result: hooks fired 0, rebuild 0 -- and only the first of those is checked
  # against 1. Count the file's lines first so the report can say whether this
  # function had anything to read at all.
  [[ -f $file ]] && log_lines=$(LC_ALL=C command grep -ac '' "$file" 2>/dev/null || echo 0)
  emit "${tag}.log_lines=${log_lines}"
  LC_ALL=C command grep -qaF 'Updating linux initcpios' "$file" && up=1
  LC_ALL=C command grep -qaF 'Verifying Neptune UKIs and Limine entries' "$file" && ours=1
  # Did OUR hook fall through to a rebuild, or did it only verify? On a
  # healthy transaction it must only verify -- upstream's hook has already
  # rebuilt by the time a 95- hook runs.
  LC_ALL=C command grep -qaF "[omarchy-deck-kernel] building UKI for ${KP}" "$file" && ours_rebuilt=1
  emit "${tag}.upstream_hook_fired=${up}"
  emit "${tag}.our_hook_fired=${ours}"
  emit "${tag}.our_hook_rebuilt=${ours_rebuilt}"
}

snap before

# --- 1. full install run ------------------------------------------------------
bash "$SCRIPT" >"$OUT/install.out" 2>&1
emit "install_exit=$?"
emit "hook_file_present=$([[ -f $HOOK ]] && echo 1 || echo 0)"
emit "hook_script_executable=$([[ -x $HOOK_SCRIPT ]] && echo 1 || echo 0)"
emit "hook_script_matches=$(cmp -s "$SCRIPT" "$HOOK_SCRIPT" && echo 1 || echo 0)"
snap after_install

# --- 2. forced reinstall, twice ----------------------------------------------
# Move the nonce before each reinstall, so "was it really regenerated?" is a
# state question with a yes/no answer: the initramfs inputs have provably
# changed, so a build that really re-ran must emit different bytes and a
# content-addressed installer must write them. uki_mtime_changed is recorded
# alongside purely as an observation -- asserting on it is what broke this
# suite before, and it reads 0 on 1.36.0 even for a UKI that provably WAS
# rebuilt. Read the mtime note at the top of this file before trusting it.
sha_pre=$(uki_sha); mtime_pre=$(uki_mtime)
stamp_nonce
pacman -S --noconfirm "$KP" >"$OUT/reinstall1.out" 2>&1
emit "reinstall1_exit=$?"
sha_post=$(uki_sha); mtime_post=$(uki_mtime)
emit "reinstall1.uki_content_changed=$([[ -n $sha_post && $sha_post != "$sha_pre" ]] && echo 1 || echo 0)"
emit "reinstall1.uki_mtime_changed=$([[ -n $mtime_post && $mtime_post != "$mtime_pre" ]] && echo 1 || echo 0)"
hooks_fired reinstall1 "$OUT/reinstall1.out"
snap after_reinstall1

# The second pass is also what proves the oracle itself is live: nothing but
# the nonce differs between these two transactions, so if this one reports no
# content change the nonce is not reaching the initramfs.
sha_pre=$(uki_sha); mtime_pre=$(uki_mtime)
stamp_nonce
pacman -S --noconfirm "$KP" >"$OUT/reinstall2.out" 2>&1
emit "reinstall2_exit=$?"
sha_post=$(uki_sha); mtime_post=$(uki_mtime)
emit "reinstall2.uki_content_changed=$([[ -n $sha_post && $sha_post != "$sha_pre" ]] && echo 1 || echo 0)"
emit "reinstall2.uki_mtime_changed=$([[ -n $mtime_post && $mtime_post != "$mtime_pre" ]] && echo 1 || echo 0)"
hooks_fired reinstall2 "$OUT/reinstall2.out"
snap after_reinstall2

# --- 3. gap A: UKI missing, upstream would have exited 0 ----------------------
rm -f "$UKI"
emit "gapA_uki_removed=$([[ -f $UKI ]] && echo 0 || echo 1)"
"$HOOK_SCRIPT" reconcile >"$OUT/gapA.out" 2>&1
emit "gapA_exit=$?"
emit "gapA_rebuilt=$(LC_ALL=C command grep -qaF "[omarchy-deck-kernel] building UKI for ${KP}" "$OUT/gapA.out" && echo 1 || echo 0)"
snap after_gapA

# --- 4. gap B: stale entry for a kernel that is not installed -----------------
cp "$UKI" "$STALE_UKI"
limine-entry-tool --add-uki "$STALE_KP" "$STALE_UKI" --comment "fabricated stale entry" \
  >"$OUT/gapB-setup.out" 2>&1
emit "gapB_setup_exit=$?"
snap before_gapB
"$HOOK_SCRIPT" reconcile >"$OUT/gapB.out" 2>&1
emit "gapB_exit=$?"
snap after_gapB

# --- 5. removal ---------------------------------------------------------------
pacman -Rdd --noconfirm "${KP}-headers" "$KP" >"$OUT/remove.out" 2>&1
emit "remove_exit=$?"
hooks_fired remove "$OUT/remove.out"
snap after_remove

{
  echo "=== OMARCHY-DECK-KERNEL PACMAN HOOK PROBE ==="
  cat "$RESULTS"
  echo "=== INSTALLED HOOK FILE ==="
  cat "$HOOK" 2>&1
  echo "=== INSTALL RUN ==="
  cat "$OUT/install.out"
  echo "=== REINSTALL 1 ==="
  cat "$OUT/reinstall1.out"
  echo "=== REINSTALL 2 ==="
  cat "$OUT/reinstall2.out"
  echo "=== GAP A (missing UKI) ==="
  cat "$OUT/gapA.out"
  echo "=== GAP B SETUP ==="
  cat "$OUT/gapB-setup.out"
  echo "=== GAP B (stale entry) ==="
  cat "$OUT/gapB.out"
  echo "=== REMOVE ==="
  cat "$OUT/remove.out"
  echo "=== STATE AT EVERY PHASE ==="
  cat "$OUT/state.txt"
  echo "=== JOURNAL (omarchy-deck-kernel) ==="
  journalctl -t omarchy-deck-kernel --no-pager 2>&1 | tail -n 50
  echo "=== END ==="
} >"$OUT/report.txt" 2>&1

if [[ -b $RESULT_DEV ]]; then
  dd if="$OUT/report.txt" of="$RESULT_DEV" bs=1M conv=fsync status=none
fi
sync
systemctl poweroff -i
PROBE

unit_text="[Unit]
Description=T1 omarchy-deck-kernel pacman hook probe
After=network-online.target
Wants=network-online.target
Before=graphical.target

[Service]
Type=oneshot
Environment=OMARCHY_DECK_NEPTUNE_SERIES=${SERIES}
ExecStartPre=/usr/bin/cp /boot/omarchy-deck-hook-probe.sh /root/omarchy-deck-hook-probe.sh
ExecStartPre=/usr/bin/cp /boot/omarchy-deck-kernel.sh /root/omarchy-deck-kernel.sh
ExecStart=/usr/bin/bash /root/omarchy-deck-hook-probe.sh
TimeoutStartSec=0
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console
"
dropin_text="[Unit]
Wants=omarchy-deck-hook.service
"

log "writing payload onto the guest ESP (rootless, mtools at byte offset)"
esp_offset=$(disk_image::esp_offset "$disk") || fail "could not locate the ESP on $disk"
MTOOLS_SKIP_CHECK=1 mcopy -o -i "${disk}@@${esp_offset}" \
  "$REPO_ROOT/src/omarchy-deck-kernel.sh" "::/omarchy-deck-kernel.sh" ||
  fail "mcopy of omarchy-deck-kernel.sh onto the ESP failed"
MTOOLS_SKIP_CHECK=1 mcopy -o -i "${disk}@@${esp_offset}" \
  "$probe_src" "::/omarchy-deck-hook-probe.sh" ||
  fail "mcopy of the probe onto the ESP failed"

esp_listing=$(MTOOLS_SKIP_CHECK=1 mdir -b -i "${disk}@@${esp_offset}" "::/" 2>/dev/null)
for f in omarchy-deck-kernel.sh omarchy-deck-hook-probe.sh; do
  grep -qi -- "/$f\$" <<<"$esp_listing" || fail "payload file '$f' is not on the ESP after mcopy"
done
log "payload verified on ESP"

cred_unit="io.systemd.credential.binary:systemd.extra-unit.omarchy-deck-hook.service=$(base64 -w0 <<<"$unit_text")"
cred_dropin="io.systemd.credential.binary:systemd.unit-dropin.multi-user.target=$(base64 -w0 <<<"$dropin_text")"

# --- boot --------------------------------------------------------------------

log "booting the substrate headless (timeout ${RUN_TIMEOUT}s)"
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
  -nic user,model=virtio-net-pci \
  -display none -vga std \
  -serial "file:${serial_log}" \
  -daemonize -pidfile "$pidfile" \
  -no-reboot ||
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
[[ -s $result_txt ]] || fail "the guest wrote nothing to the result device — it never reached the probe. Check $serial_log and $WORK."
log "report: $result_txt"

# Exact-prefix lookup rather than a regex: the keys contain dots
# (after_install.uki_sha), and a regex match on those would also accept a
# line this test never emitted.
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
# check_min <what> <got> <floor> -- for the facts whose only job is to prove a
# later "it is absent" check was LOOKING at something. An exact expected value
# would have to be updated every time the config or a pacman log grew a line;
# a floor cannot pass on 0, which is the only value that matters here.
check_min() {
  local what=$1 got=$2 floor=$3
  if [[ $got =~ ^[0-9]+$ ]] && (( got >= floor )); then
    log "ok   ${what} = ${got} (>= ${floor})"
  else
    log "FAIL ${what} = '${got}' (expected a number >= ${floor})"
    status=1
  fi
}

# Checked first and reported as itself: without network the script's
# stage_repos cannot `pacman -Sy`, and every later assertion fails for a
# reason that has nothing to do with the hook.
check "network_resolved" "$(field network_resolved)" 1

# 1. the install run leaves a usable hook behind
check "install_exit"            "$(field install_exit)" 0
check "hook_file_present"       "$(field hook_file_present)" 1
check "hook_script_executable"  "$(field hook_script_executable)" 1
check "hook_script_matches"     "$(field hook_script_matches)" 1
check "after_install.uki_present" "$(field after_install.uki_present)" 1
check "after_install.entry_refs"  "$(field after_install.entry_refs)" 1

# 2. a reinstall fires both hooks and really rebuilds
check "reinstall1_exit"                 "$(field reinstall1_exit)" 0
check "reinstall1.upstream_hook_fired"  "$(field reinstall1.upstream_hook_fired)" 1
check "reinstall1.our_hook_fired"       "$(field reinstall1.our_hook_fired)" 1
check "after_reinstall1.uki_present"    "$(field after_reinstall1.uki_present)" 1
check "after_reinstall1.entry_refs"     "$(field after_reinstall1.entry_refs)" 1

# The nonce proves regeneration; our hook not rebuilding proves the 95- hook
# is not duplicating upstream's work. Checked in that order so that a broken
# oracle reports itself as a broken oracle instead of as a product failure.
check "nonce_file_present"                "$(field nonce_file_present)" 1
check "nonce_files_configured"            "$(field nonce_files_configured)" 1
check "reinstall1.uki_content_changed"    "$(field reinstall1.uki_content_changed)" 1
check "reinstall1.our_hook_rebuilt"       "$(field reinstall1.our_hook_rebuilt)" 0

# 3. repeat runs must not duplicate anything
check "reinstall2_exit"              "$(field reinstall2_exit)" 0
check "reinstall2.our_hook_fired"    "$(field reinstall2.our_hook_fired)" 1
check "reinstall2.uki_content_changed" "$(field reinstall2.uki_content_changed)" 1
check "after_reinstall2.entry_refs"  "$(field after_reinstall2.entry_refs)" 1
check "after_reinstall2.neptune_ukis" "$(field after_reinstall2.neptune_ukis)" 1

# 4. gap A — the reconcile repairs a missing UKI
check "gapA_uki_removed"        "$(field gapA_uki_removed)" 1
check "gapA_exit"               "$(field gapA_exit)" 0
check "gapA_rebuilt"            "$(field gapA_rebuilt)" 1
check "after_gapA.uki_present"  "$(field after_gapA.uki_present)" 1
check "after_gapA.entry_refs"   "$(field after_gapA.entry_refs)" 1

# ⚠️ PROOF THAT THE ABSENCE CHECKS BELOW WERE LOOKING AT SOMETHING.
# after_gapB.stale_refs and after_remove.entry_refs are both asserted to be 0.
# `grep -c` against a missing /boot/limine.conf exits 2 and prints nothing, and
# the probe's `|| true` swallows that, so an ESP that failed to mount would
# produce the same reassuring zeros. These say the file was there and had
# content at exactly the two moments those zeros are read.
check     "after_gapB.limine_conf_present"  "$(field after_gapB.limine_conf_present)" 1
check_min "after_gapB.limine_conf_lines"    "$(field after_gapB.limine_conf_lines)" 1
check     "after_remove.limine_conf_present" "$(field after_remove.limine_conf_present)" 1
check_min "after_remove.limine_conf_lines"   "$(field after_remove.limine_conf_lines)" 1

# Same shape for reinstall1.our_hook_rebuilt, which is asserted to be 0: an
# absent or empty pacman log greps as "did not rebuild" just as convincingly
# as a log that really shows no rebuild.
check_min "reinstall1.log_lines" "$(field reinstall1.log_lines)" 1
check_min "reinstall2.log_lines" "$(field reinstall2.log_lines)" 1
check_min "remove.log_lines"     "$(field remove.log_lines)" 1

# 5. gap B — the reconcile prunes a stale entry nobody else will
check "before_gapB.stale_present" "$(field before_gapB.stale_present)" 1
check "before_gapB.stale_refs"    "$(field before_gapB.stale_refs)" 1
check "gapB_exit"                 "$(field gapB_exit)" 0
check "after_gapB.stale_present"  "$(field after_gapB.stale_present)" 0
check "after_gapB.stale_refs"     "$(field after_gapB.stale_refs)" 0
check "after_gapB.entry_refs"     "$(field after_gapB.entry_refs)" 1

# 6. removal
check "remove_exit"              "$(field remove_exit)" 0
check "remove.our_hook_fired"    "$(field remove.our_hook_fired)" 1
check "after_remove.uki_present" "$(field after_remove.uki_present)" 0
check "after_remove.entry_refs"  "$(field after_remove.entry_refs)" 0

if [[ $status -eq 0 ]]; then
  log "PASS — hook fires on install/upgrade/remove, reconciles state, and cannot duplicate entries"
else
  log "FAIL — see $result_txt"
fi
exit $status
