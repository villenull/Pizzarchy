#!/usr/bin/env bash
# Unit tests for omarchy-deck-early's disk wipe gate: the last line of
# defence before the early stage erases anything.
#
# No VM, no root, no real disks, no DMI: `lsblk`/`findmnt` are fakes reached
# through DECK_EARLY_LSBLK_BIN/DECK_EARLY_FINDMNT_BIN, DMI through
# DECK_EARLY_DMI_PRODUCT/VENDOR -- the same seam discipline
# test-deck-form.sh uses for the form's own resolver. Seconds.
#
# What this suite is for: the gate must accept exactly the Deck's internal
# SSD and microSD card -- the same rule deck_form_disk_list enforces on the
# form side -- so a direct `omarchy-deck-early start` call cannot bypass the
# screens. Every refusal exits 2 with a message on stderr: never silent
# (CLAUDE.md), never a guess.
set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
EARLY_SH="$REPO_ROOT/iso/overlay/configs/airootfs/usr/local/bin/omarchy-deck-early"

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; [[ -n ${2:-} ]] && printf '%s\n' "$2" >&2; exit 1; }

[[ -f $EARLY_SH ]] || fail "the early-stage script exists" "expected $EARLY_SH"
[[ -x $EARLY_SH ]] || fail "the early-stage script is executable" "expected $EARLY_SH"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "--- loading the REAL gate functions (the dispatch case stays unexecuted) ---"

# The script ends in a `case ${1:-}` dispatch that RUNS on source (`*` calls
# `usage`, which exits 2), so sourcing the whole file is impossible -- the
# same reason test-deck-form.sh never re-sources deck-form.sh. Extract the
# two gate functions verbatim instead. What is under test stays
# byte-identical to the shipped file; the `start`-pattern cases further down
# exec the real file end to end, so the dispatch itself is covered there.
gate_src=$(sed -n '/^deck_early_require_oled() {$/,/^}$/p;/^deck_early_require_target_disk() {$/,/^}$/p' "$EARLY_SH")
[[ -n $gate_src ]] || fail "could not extract the gate functions from $EARLY_SH -- the sed range is broken, not the gate"
LC_ALL=C grep -qF "deck_early_require_oled() {" <<<"$gate_src" ||
  fail "the extracted source must contain deck_early_require_oled"
LC_ALL=C grep -qF "deck_early_require_target_disk() {" <<<"$gate_src" ||
  fail "the extracted source must contain deck_early_require_target_disk"
eval "$gate_src"

# The gates read these four fallbacks when the test seams are unset. Defined
# here so the extracted functions resolve; cross-checked against the script
# below so a renamed default fails here instead of silently testing nothing.
# shellcheck disable=SC2034 # read by the eval'd gate functions, not this file
DECK_EARLY_PROG=omarchy-deck-early
# shellcheck disable=SC2034 # same: the extracted gate's own fallback default
DECK_EARLY_LSBLK_BIN_DEFAULT=lsblk
# shellcheck disable=SC2034 # same
DECK_EARLY_FINDMNT_BIN_DEFAULT=findmnt
# shellcheck disable=SC2034 # same
DECK_EARLY_DMI_PRODUCT_DEFAULT=/sys/class/dmi/id/product_name
# shellcheck disable=SC2034 # same
DECK_EARLY_DMI_VENDOR_DEFAULT=/sys/class/dmi/id/sys_vendor
LC_ALL=C grep -qF 'readonly DECK_EARLY_LSBLK_BIN_DEFAULT=lsblk' "$EARLY_SH" ||
  fail "the suite's lsblk fallback drifted from the script's own default"
LC_ALL=C grep -qF 'readonly DECK_EARLY_FINDMNT_BIN_DEFAULT=findmnt' "$EARLY_SH" ||
  fail "the suite's findmnt fallback drifted from the script's own default"
pass "the gate functions load from the real file and the suite's fallbacks match its defaults"

# --- fakes ---------------------------------------------------------------

# Answers the two lsblk shapes the gate uses, from per-case env:
# FAKE_LSBLK_ROW answers `-dpno NAME,TYPE,RM,TRAN <disk>` (empty = invisible
# to lsblk); FAKE_LSBLK_PK answers `-no PKNAME <source>` (empty = no parent).
cat >"$work/fake-lsblk" <<'EOF'
#!/usr/bin/env bash
if [[ " $* " == *" PKNAME "* ]]; then
  [[ -n ${FAKE_LSBLK_PK:-} ]] && printf '%s\n' "$FAKE_LSBLK_PK"
  exit 0
fi
[[ -n ${FAKE_LSBLK_ROW:-} ]] && printf '%s\n' "$FAKE_LSBLK_ROW"
exit 0
EOF
# FAKE_FINDMNT_SOURCE answers the bootmnt SOURCE query (empty = no live
# medium found, the gate's non-booted path).
cat >"$work/fake-findmnt" <<'EOF'
#!/usr/bin/env bash
[[ -n ${FAKE_FINDMNT_SOURCE:-} ]] && printf '%s\n' "$FAKE_FINDMNT_SOURCE"
exit 0
EOF
chmod +x "$work/fake-lsblk" "$work/fake-findmnt"

mkdir -p "$work/dmi-oled" "$work/dmi-jupiter" "$work/dmi-generic"
printf 'Galileo\n' >"$work/dmi-oled/product_name"
printf 'Valve\n' >"$work/dmi-oled/sys_vendor"
printf 'Jupiter\n' >"$work/dmi-jupiter/product_name"
printf 'Valve\n' >"$work/dmi-jupiter/sys_vendor"
printf 'ThinkPad X1\n' >"$work/dmi-generic/product_name"
printf 'LENOVO\n' >"$work/dmi-generic/sys_vendor"

GATE_RC=0
run_gate() { # <disk> <lsblk-row> <pkname> <findmnt-source>
  local disk=$1 row=${2:-} pk=${3:-} src=${4:-}
  set +e
  FAKE_LSBLK_ROW="$row" FAKE_LSBLK_PK="$pk" FAKE_FINDMNT_SOURCE="$src" \
  DECK_EARLY_LSBLK_BIN="$work/fake-lsblk" \
  DECK_EARLY_FINDMNT_BIN="$work/fake-findmnt" \
    deck_early_require_target_disk "$disk" 2>"$work/gate.err"
  GATE_RC=$?
  set -e
}
run_oled() { # <product-file> <vendor-file>
  set +e
  DECK_EARLY_DMI_PRODUCT="$1" DECK_EARLY_DMI_VENDOR="$2" \
    deck_early_require_oled 2>"$work/oled.err"
  GATE_RC=$?
  set -e
}
run_start() { # <disk> -- execs the REAL script, end to end through `start`
  set +e
  bash "$EARLY_SH" start "$1" >"$work/start.out" 2>"$work/start.err"
  GATE_RC=$?
  set -e
}
expect_accept() { # <label> [err-file]
  local err=${2:-$work/gate.err}
  [[ $GATE_RC -eq 0 ]] || fail "$1 is accepted" "rc=$GATE_RC err: $(cat "$err")"
  pass "$1"
}
expect_refuse() { # <label> [err-file]
  local err=${2:-$work/gate.err}
  [[ $GATE_RC -eq 2 ]] || fail "$1 is refused with exit 2" "rc=$GATE_RC err: $(cat "$err")"
  LC_ALL=C grep -qF "refusing" "$err" || fail "$1 says why on stderr" "err: $(cat "$err")"
  pass "$1"
}

echo "--- accepts: NVMe whole disk, microSD in every TRAN/RM shape ---"

# The SD match is by NAME, not by TRAN/RM, on purpose: lsblk reports the
# reader's TRAN as empty or `mmc` and RM as 0 or 1 depending on
# kernel/card, so all four combinations must pass (same rule as
# deck_form_disk_list, enforced here so the CLI cannot bypass it).
run_gate /dev/nvme0n1 "/dev/nvme0n1 disk 0 nvme" "" ""
expect_accept "NVMe whole disk (TYPE=disk RM=0 TRAN=nvme) is accepted"
run_gate /dev/mmcblk0 "/dev/mmcblk0 disk 0" "" ""
expect_accept "microSD is accepted with TRAN empty, RM=0"
run_gate /dev/mmcblk0 "/dev/mmcblk0 disk 1" "" ""
expect_accept "microSD is accepted with TRAN empty, RM=1"
run_gate /dev/mmcblk0 "/dev/mmcblk0 disk 0 mmc" "" ""
expect_accept "microSD is accepted with TRAN=mmc, RM=0"
run_gate /dev/mmcblk0 "/dev/mmcblk0 disk 1 mmc" "" ""
expect_accept "microSD is accepted with TRAN=mmc, RM=1"

echo "--- refusals: USB, invisible disks, wrong types, the boot medium ---"

run_gate /dev/sda "/dev/sda disk 1 usb" "" ""
expect_refuse "a USB disk (TRAN=usb) is refused"
run_gate /dev/sda "/dev/sda disk 0 usb" "" ""
expect_refuse "a USB disk is refused even at RM=0"
run_gate /dev/nvme0n1 "" "" ""
expect_refuse "a disk lsblk cannot see is refused"
run_gate /dev/mmcblk0 "/dev/mmcblk0 part 0 mmc" "" ""
expect_refuse "a microSD name with a non-disk TYPE is refused"
# The ISO booted from SD: findmnt names the boot partition, lsblk resolves
# its parent to the card, and the card itself is refused.
run_gate /dev/mmcblk0 "/dev/mmcblk0 disk 1 mmc" "mmcblk0" "/dev/mmcblk0p1"
expect_refuse "the booted SD card (live boot medium) is refused"
# Same for NVMe, so the boot-medium check is not SD-only.
run_gate /dev/nvme0n1 "/dev/nvme0n1 disk 0 nvme" "nvme0n1" "/dev/nvme0n1p2"
expect_refuse "the booted NVMe (live boot medium) is refused"

echo "--- OLED gate: Galileo passes, everything else refuses ---"

run_oled "$work/dmi-oled/product_name" "$work/dmi-oled/sys_vendor"
expect_accept "Galileo/Valve passes the OLED gate" "$work/oled.err"
run_oled "$work/dmi-jupiter/product_name" "$work/dmi-jupiter/sys_vendor"
expect_refuse "Jupiter (unverified LCD) is refused" "$work/oled.err"
run_oled "$work/dmi-generic/product_name" "$work/dmi-generic/sys_vendor"
expect_refuse "a generic laptop is refused" "$work/oled.err"
run_oled "$work/does-not-exist/product_name" "$work/does-not-exist/sys_vendor"
expect_refuse "unreadable DMI is refused, never guessed" "$work/oled.err"

echo "--- start's name pattern: partitions refused, whole disks pass it ---"

# These exec the real script through `start`. The pattern check runs before
# the block-device probe, the OLED gate, and anything that writes state, so
# a refusal here touches nothing -- and a whole-disk name sails past the
# pattern to the `-b` probe, which fails loudly on a machine with no such
# device (proving the pattern accepted it, by message rather than by code
# reading). The whole-disk names use device numbers no machine carries so
# the `-b` probe is the only possible outcome past the pattern.
run_start /dev/nvme0n1p1
[[ $GATE_RC -eq 2 ]] || fail "start refuses the NVMe partition with exit 2" "rc=$GATE_RC"
LC_ALL=C grep -qF "internal SSD or microSD only" "$work/start.err" ||
  fail "start names the rule when refusing a partition" "err: $(cat "$work/start.err")"
pass "start refuses the NVMe partition /dev/nvme0n1p1"

run_start /dev/mmcblk0p1
[[ $GATE_RC -eq 2 ]] || fail "start refuses the microSD partition with exit 2" "rc=$GATE_RC"
LC_ALL=C grep -qF "internal SSD or microSD only" "$work/start.err" ||
  fail "start names the rule when refusing a partition" "err: $(cat "$work/start.err")"
pass "start refuses the microSD partition /dev/mmcblk0p1"

run_start /dev/sda1
[[ $GATE_RC -eq 2 ]] || fail "start refuses a USB-style partition with exit 2" "rc=$GATE_RC"
LC_ALL=C grep -qF "internal SSD or microSD only" "$work/start.err" ||
  fail "start names the rule when refusing a partition" "err: $(cat "$work/start.err")"
pass "start refuses /dev/sda1"

run_start /dev/nvme9n9
[[ $GATE_RC -eq 2 ]] || fail "start on a missing whole disk still exits 2" "rc=$GATE_RC"
LC_ALL=C grep -qF "no such block device" "$work/start.err" ||
  fail "a whole-disk NVMe name must pass the pattern and reach the block-device probe" "err: $(cat "$work/start.err")"
pass "start's pattern accepts a whole-disk NVMe name (fails later at the block-device probe)"

run_start /dev/mmcblk7
[[ $GATE_RC -eq 2 ]] || fail "start on a missing whole disk still exits 2" "rc=$GATE_RC"
LC_ALL=C grep -qF "no such block device" "$work/start.err" ||
  fail "a whole-disk microSD name must pass the pattern and reach the block-device probe" "err: $(cat "$work/start.err")"
pass "start's pattern accepts a whole-disk microSD name (fails later at the block-device probe)"

echo "========================================================================"
echo "ALL omarchy-deck-early gate TESTS PASSED"
