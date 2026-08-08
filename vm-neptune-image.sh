#!/usr/bin/env bash
# vm-neptune-image.sh -- build a minimal bootable substrate for testing the
# Neptune boot chain in QEMU, without building an Omarchy ISO first.
#
# Usage: ./vm-neptune-image.sh [output.raw] [work-dir]
#
# Env vars (all optional):
#   IMG_SIZE_GB        default 14
#   IMG_ESP_MB         default 1024
#   IMG_NEPTUNE_SERIES default 611  (pre-installed into the image)
#   IMG_DOCKER_IMAGE   default archlinux/archlinux:latest
#   IMG_OMARCHY_SERVER default https://pkgs.omarchy.org/stable/$arch
#
# WHY THIS EXISTS
#
# vm-kernel-idempotency-test.sh (T1 steps 1-2) takes an *already installed*
# Omarchy Quattro disk as input -- the artifact vm-install-test.sh produces
# from a real ISO build. That is the right substrate for testing an
# installer, but producing it costs an ISO build plus a full unattended
# install, and the artifact is not kept in the repo.
#
# What T1 step 3 has to test is narrower: how pacman's ALPM hooks behave
# around limine-mkinitcpio-hook when a linux-neptune-* package is installed,
# reinstalled or removed. That needs a system with limine, limine-mkinitcpio-
# hook, a real vfat ESP mounted the way Omarchy mounts it, and a Neptune
# kernel -- not an Omarchy install. So this builds exactly that, in minutes,
# reproducibly, from packages.
#
# It is deliberately NOT a claim to be an Omarchy Quattro system. The four
# properties it does reproduce, because they are the ones the boot chain
# depends on, are:
#   1. limine + limine-mkinitcpio-hook (same version stream as Quattro's,
#      from Omarchy's own package repo).
#   2. /etc/default/limine with ENABLE_UKI=yes and CUSTOM_UKI_NAME="omarchy",
#      which is what makes the UKIs `omarchy_<pkgbase>.efi` rather than
#      `<machine-id>_<pkgbase>.efi`.
#   3. A vfat ESP at /boot mounted fmask=0077,dmask=0077 -- archinstall's
#      UKI hardening, i.e. PLAN.md 8.5's precondition.
#   4. The Valve repos and a real linux-neptune-* kernel installed through
#      them, including the linux-firmware-neptune swap.
#
# HOW IT IS BUILT WITHOUT ROOT ON THE HOST
#
# Everything happens inside a privileged `archlinux/archlinux` container:
# loop device, mkfs, pacstrap, arch-chroot. The host only ever sees the
# finished raw image, chowned back to the invoking uid. This host has no
# passwordless sudo, and a harness that needs an interactive password cannot
# run in CI -- the same constraint the rest of this project's harnesses are
# written under.
#
# One container-specific trick: limine-mkinitcpio-hook only builds UKIs when
# `[[ -d /sys/firmware/efi ]]`, and Docker masks /sys/firmware. A tmpfs is
# mounted over /sys/firmware inside the container so the chroot's UKI path is
# the one that runs. That affects only which code path limine takes at build
# time; the guest itself boots under real OVMF firmware.

set -uo pipefail

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

OUT=${1:-$SELF_DIR/neptune-substrate.raw}
WORK=${2:-$(mktemp -d /var/tmp/vm-neptune-image.XXXXXX)}

SIZE_GB=${IMG_SIZE_GB:-14}
ESP_MB=${IMG_ESP_MB:-1024}
SERIES=${IMG_NEPTUNE_SERIES:-611}
DOCKER_IMAGE=${IMG_DOCKER_IMAGE:-archlinux/archlinux:latest}
# shellcheck disable=SC2016 # $arch is pacman's variable and must stay unexpanded
OMARCHY_SERVER=${IMG_OMARCHY_SERVER:-'https://pkgs.omarchy.org/stable/$arch'}

log() { printf '[vm-neptune-image] %s\n' "$*" >&2; }
fail() { log "FAIL: $*"; exit 1; }

command -v docker >/dev/null || fail "docker not found"
docker info >/dev/null 2>&1 || fail "cannot talk to the docker daemon (is the current user in the 'docker' group?)"

[[ $SERIES =~ ^[0-9]+$ ]] || fail "IMG_NEPTUNE_SERIES must be digits only, got '$SERIES'"

mkdir -p "$WORK" || fail "could not create work dir $WORK"
log "work dir: $WORK"
log "output:   $OUT"

# --- the in-container build ---------------------------------------------------

build_src="$WORK/build-in-container.sh"
cat >"$build_src" <<'BUILD'
#!/usr/bin/env bash
# Runs as root inside a privileged archlinux container.
set -euo pipefail

SIZE_GB=$1
ESP_MB=$2
SERIES=$3
OMARCHY_SERVER=$4
HOST_UID=$5
HOST_GID=$6

IMG=/out/disk.raw
KERNEL_PKG="linux-neptune-${SERIES}"

step() { printf '\n=== [build] %s ===\n' "$*" >&2; }
die()  { printf '[build] FAIL: %s\n' "$*" >&2; exit 1; }

step "container prerequisites"
# limine-mkinitcpio-hook only builds UKIs when /sys/firmware/efi exists, and
# Docker masks /sys/firmware. See the note at the top of vm-neptune-image.sh.
mount -t tmpfs none /sys/firmware
mkdir -p /sys/firmware/efi
[[ -d /sys/firmware/efi ]] || die "could not fake /sys/firmware/efi; the chroot would build initramfs+vmlinuz instead of UKIs"

cat >>/etc/pacman.conf <<EOF

[omarchy]
SigLevel = Optional TrustAll
Server = ${OMARCHY_SERVER}
EOF

pacman -Sy --noconfirm --needed \
  arch-install-scripts dosfstools e2fsprogs util-linux gptfdisk parted >/dev/null ||
  die "could not install container build tools"

step "creating ${SIZE_GB}G image and partitioning it"
rm -f "$IMG"
truncate -s "${SIZE_GB}G" "$IMG"
esp_sectors=$(( ESP_MB * 1024 * 1024 / 512 ))
sfdisk --quiet "$IMG" <<EOF
label: gpt
start=2048, size=${esp_sectors}, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="EFI system partition"
type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="root"
EOF

loop=$(losetup --show -fP "$IMG") || die "losetup failed"
trap 'set +e; umount -R /mnt 2>/dev/null; losetup -d "$loop" 2>/dev/null' EXIT

# The kernel rescans the partition table and publishes the partitions under
# /sys/block, but Docker gives the container a plain tmpfs /dev with no udev
# running, so nothing ever creates the /dev/loopNpM nodes. Create them from
# sysfs by hand. (Mounting devtmpfs over /dev would also work and is one line,
# but it swaps out the container's whole /dev underneath everything else.)
loop_base=${loop##*/}
for pdir in /sys/block/"$loop_base"/"$loop_base"p*; do
  [[ -d $pdir ]] || continue
  pname=${pdir##*/}
  IFS=: read -r pmaj pmin <"$pdir/dev"
  [[ -b /dev/$pname ]] || mknod "/dev/$pname" b "$pmaj" "$pmin" ||
    die "could not create /dev/${pname} (b ${pmaj}:${pmin})"
done
[[ -b ${loop}p1 && -b ${loop}p2 ]] ||
  die "loop partitions did not appear (${loop}p1/p2); /sys/block/${loop_base} holds: $(echo /sys/block/"$loop_base"/*)"

step "making filesystems"
mkfs.vfat -F32 -n ESP "${loop}p1" >/dev/null || die "mkfs.vfat failed"
mkfs.ext4 -q -L root "${loop}p2" || die "mkfs.ext4 failed"

# fmask/dmask 0077 on purpose: that is archinstall's UKI hardening and the
# precondition for PLAN.md 8.5. The script under test is supposed to find and
# fix it, so the image must ship broken in exactly that way.
mkdir -p /mnt
mount "${loop}p2" /mnt || die "could not mount root"
mkdir -p /mnt/boot
mount -o fmask=0077,dmask=0077 "${loop}p1" /mnt/boot || die "could not mount ESP"

step "pacstrap base system"
pacstrap -c /mnt \
  base linux mkinitcpio limine limine-mkinitcpio-hook efibootmgr \
  sudo which findutils psmisc dosfstools e2fsprogs less vim ||
  die "pacstrap failed"

root_uuid=$(blkid -s UUID -o value "${loop}p2") || die "could not read root UUID"
esp_uuid=$(blkid -s UUID -o value "${loop}p1") || die "could not read ESP UUID"
[[ -n $root_uuid && -n $esp_uuid ]] || die "empty filesystem UUID (root='${root_uuid}' esp='${esp_uuid}')"

step "configuring the guest"
# fstab is written by hand, NOT with genfstab. genfstab resolves UUIDs through
# /dev/disk/by-uuid, and there is no udev in this container to populate it for
# loop partitions this script mknod'd itself -- so genfstab silently emitted
# `/dev/loop0p1` as the ESP's source. The guest then booted (root comes from
# the kernel cmdline, not fstab), waited 90s for a /dev/loop0p1 that will
# never exist in a VM, failed /boot, and dropped to an emergency shell. It
# looked exactly like a hung test: disk churn, then silence.
# The options string is copied from a real Omarchy Quattro /etc/fstab so the
# ESP is mounted the way PLAN.md 8.5 describes, down to the flags.
cat >/mnt/etc/fstab <<EOF
UUID=${root_uuid}	/	ext4	rw,relatime	0 1
UUID=${esp_uuid}	/boot	vfat	rw,relatime,fmask=0077,dmask=0077,codepage=437,iocharset=ascii,shortname=mixed,utf8,errors=remount-ro	0 2
EOF
grep -q 'fmask=0077' /mnt/etc/fstab ||
  die "the ESP's fmask=0077 is missing from fstab -- the 8.5 precondition would not be there"
if grep -q '^/dev/' /mnt/etc/fstab; then
  die "fstab names a device path instead of a UUID; that device will not exist in the VM"
fi

echo neptune-substrate >/mnt/etc/hostname

# Networking. Not optional: omarchy-deck-kernel.sh's stage_repos runs
# `pacman -Sy`, and the guest reaches Valve's mirror through QEMU's user-mode
# NAT. Without a DHCP client and a resolver the guest looks alive but every
# name lookup hangs, which reads as "the script under test is stuck" rather
# than "the image has no network" -- the exact ambiguity this project's rules
# are about.
cat >/mnt/etc/systemd/network/20-wired.network <<'EOF'
[Match]
Name=en* eth*

[Network]
DHCP=yes
EOF
arch-chroot /mnt systemctl enable systemd-networkd systemd-resolved >/dev/null ||
  die "could not enable systemd-networkd/systemd-resolved"
ln -sf /run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf
[[ -L /mnt/etc/systemd/system/multi-user.target.wants/systemd-networkd.service ||
   -L /mnt/etc/systemd/system/sockets.target.wants/systemd-networkd.socket ]] ||
  die "systemctl enable reported success but left no systemd-networkd symlink"

ln -sf /usr/share/zoneinfo/UTC /mnt/etc/localtime
echo 'en_US.UTF-8 UTF-8' >/mnt/etc/locale.gen
echo 'LANG=en_US.UTF-8' >/mnt/etc/locale.conf

# No `autodetect`: the initramfs is built inside a container whose hardware is
# this dev machine's, not the guest's. A full initramfs is bigger and boots
# anywhere, which is the property a test image needs.
cat >/mnt/etc/mkinitcpio.conf <<'EOF'
MODULES=()
BINARIES=()
FILES=()
HOOKS=(base udev modconf kms block filesystems keyboard fsck)
COMPRESSION="zstd"
EOF

cat >/mnt/etc/default/limine <<EOF
TARGET_OS_NAME="Omarchy"

ESP_PATH="/boot"

KERNEL_CMDLINE[default]+="root=UUID=${root_uuid} rw"
# console=ttyS0 LAST on purpose: the kernel makes the last console= the one
# /dev/console points at, and that is where systemd's boot output goes. With
# tty0 last, a guest that fails early prints its diagnosis to a VGA
# framebuffer no harness is capturing, and the serial log just stops.
KERNEL_CMDLINE[default]+=" console=tty0 console=ttyS0,115200"

ENABLE_UKI=yes
CUSTOM_UKI_NAME="omarchy"

ENABLE_LIMINE_FALLBACK=yes
FIND_BOOTLOADERS=no
BOOT_ORDER="*, *fallback"
EOF

# Write the guest's pacman.conf outright rather than appending to whatever
# pacstrap left. It leaves none: appending the Valve repos to a nonexistent
# file produced a pacman.conf whose only content was those two sections, with
# no `Architecture`, and every `pacman -Q` in the chroot then died with
# "mirror ... contains the '$arch' variable, but no 'Architecture' is
# defined". limine-mkinitcpio-install swallowed that whole -- its
# `pacman -Qqo "${pkgbase_file}" &>/dev/null || continue` guard skipped the
# only kernel and the script still exited 0, building nothing. That is
# precisely gap #1 this project's hook exists to catch, hit by accident while
# building the harness for it.
cp /etc/pacman.conf /mnt/etc/pacman.conf || die "could not seed the guest's pacman.conf"
cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist || die "could not seed the guest's mirrorlist"
grep -q '^Architecture' /mnt/etc/pacman.conf ||
  die "the seeded pacman.conf has no Architecture line -- pacman -Q would fail in the guest"

# Valve repos, added the same way omarchy-deck-kernel.sh's stage_repos adds
# them, so the guest starts from the state that script leaves behind.
cat >>/mnt/etc/pacman.conf <<'EOF'

[jupiter-staging]
Server = https://steamdeck-packages.steamos.cloud/archlinux-mirror/$repo/os/$arch
SigLevel = Never

[holo-staging]
Server = https://steamdeck-packages.steamos.cloud/archlinux-mirror/$repo/os/$arch
SigLevel = Never
EOF

step "deploying limine + building the UKI for the stock kernel"
# Sanity-check the chroot's pacman before relying on it: limine-mkinitcpio-
# install's kernel loop is gated on `pacman -Qqo`, and a broken pacman makes
# it skip every kernel and still exit 0.
arch-chroot /mnt bash -c 'pacman -Qqo /usr/lib/modules/*/pkgbase' >/dev/null ||
  die "pacman -Qqo does not work in the chroot; limine-mkinitcpio-install would silently skip every kernel"

arch-chroot /mnt limine-install --no-efi-register --fallback ||
  die "limine-install failed"
arch-chroot /mnt limine-mkinitcpio || die "limine-mkinitcpio failed"

# pacstrap's transaction ran mkinitcpio's own 90-mkinitcpio-install.hook,
# because limine-mkinitcpio-hook's /etc override was being installed by that
# same transaction and pacman had already read the hook list. That left a
# non-UKI /boot/vmlinuz-linux + initramfs behind. Harmless, but a real
# Quattro ESP does not have them and the test should not be looking at a
# layout no real system has.
rm -f /mnt/boot/vmlinuz-linux /mnt/boot/initramfs-linux.img /mnt/boot/initramfs-linux-fallback.img

# Verify against the ESP, not against exit codes (PLAN.md 8.1).
[[ -f /mnt/boot/limine.conf ]] || die "no /boot/limine.conf after limine-mkinitcpio"
[[ -f /mnt/boot/EFI/Linux/omarchy_linux.efi ]] ||
  die "no /boot/EFI/Linux/omarchy_linux.efi -- the UKI path did not run (is /sys/firmware/efi visible?)"
grep -qF 'omarchy_linux.efi' /mnt/boot/limine.conf ||
  die "the UKI exists but /boot/limine.conf does not reference it"
[[ -f /mnt/boot/EFI/BOOT/BOOTX64.EFI ]] ||
  die "no fallback /boot/EFI/BOOT/BOOTX64.EFI -- OVMF has no NVRAM entry to fall back to and the guest will not boot"

step "installing ${KERNEL_PKG} through the Valve repos"
arch-chroot /mnt pacman -Sy --noconfirm >/dev/null || die "pacman -Sy failed in the chroot"

# Same firmware swap omarchy-deck-kernel.sh's stage_firmware_swap performs,
# for the same reason (Valve's linux-firmware-neptune only declares conflicts
# against `linux-firmware` and `linux-firmware-whence`, not against Arch's ten
# split subpackages). Done here so the guest starts from a realistic state and
# the VM run does not spend its time re-downloading firmware.
mapfile -t colliding < <(arch-chroot /mnt pacman -Qq | grep -E '^linux-firmware(-[a-z0-9-]+)?$' | grep -vE 'neptune|^linux-firmware-whence$' || true)
if ((${#colliding[@]})); then
  arch-chroot /mnt pacman -Rdd --noconfirm "${colliding[@]}" >/dev/null ||
    die "could not remove Arch's linux-firmware packages: ${colliding[*]}"
fi

arch-chroot /mnt pacman -S --needed --noconfirm --ask=4 \
  "${KERNEL_PKG}" "${KERNEL_PKG}-headers" linux-firmware-neptune ||
  die "could not install ${KERNEL_PKG}"

[[ -f "/mnt/boot/EFI/Linux/omarchy_${KERNEL_PKG}.efi" ]] ||
  die "installed ${KERNEL_PKG} but no omarchy_${KERNEL_PKG}.efi on the ESP -- upstream's install hook did not build it"
grep -qF "omarchy_${KERNEL_PKG}.efi" /mnt/boot/limine.conf ||
  die "the Neptune UKI exists but is not referenced in /boot/limine.conf"

step "keeping the package cache so the guest can reinstall offline"
# The hook test reinstalls the kernel package; leaving the cache populated
# means that reinstall does not depend on the mirror being reachable from
# inside QEMU's user-mode NAT.
arch-chroot /mnt pacman -Sw --noconfirm --needed "${KERNEL_PKG}" "${KERNEL_PKG}-headers" >/dev/null || true

step "guest login + serial console"
arch-chroot /mnt bash -c 'echo "root:root" | chpasswd'
mkdir -p /mnt/etc/systemd/system/serial-getty@ttyS0.service.d
cat >/mnt/etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I 115200 linux
EOF

step "final state"
ls -la /mnt/boot/EFI/Linux/
cat /mnt/boot/limine.conf

sync
umount -R /mnt
losetup -d "$loop"
trap - EXIT

chown "${HOST_UID}:${HOST_GID}" "$IMG"
printf '[build] image ready: %s\n' "$IMG" >&2
BUILD
chmod +x "$build_src"

log "building the substrate image inside docker (this pulls ~1-2 GB of packages)"
# --network host: this dev machine's docker bridge network is throttled to
# ~2 KB/s (root-caused in session 2, see PROGRESS.md). Every Docker-based
# build tool here has to bypass the bridge.
docker run --rm \
  --privileged \
  --network host \
  -v "$WORK:/out" \
  "$DOCKER_IMAGE" \
  /out/build-in-container.sh \
  "$SIZE_GB" "$ESP_MB" "$SERIES" "$OMARCHY_SERVER" "$(id -u)" "$(id -g)" ||
  fail "the in-container build failed (work dir preserved: $WORK)"

[[ -f "$WORK/disk.raw" ]] || fail "the container reported success but produced no disk.raw (work dir: $WORK)"

# Verify the image really contains what the build claimed, from the host,
# before declaring success -- same rule the rest of this project follows.
if command -v sfdisk >/dev/null 2>&1; then
  sfdisk -l "$WORK/disk.raw" >/dev/null 2>&1 ||
    fail "the produced image has no readable partition table"
fi
if [[ -f $SELF_DIR/vm-disk-image.sh ]] && command -v mdir >/dev/null 2>&1; then
  # shellcheck source=vm-disk-image.sh
  source "$SELF_DIR/vm-disk-image.sh"
  esp_offset=$(disk_image::esp_offset "$WORK/disk.raw") ||
    fail "could not locate an ESP in the produced image"
  listing=$(MTOOLS_SKIP_CHECK=1 mdir -b -i "$WORK/disk.raw@@${esp_offset}" "::/EFI/Linux" 2>/dev/null) ||
    fail "the produced image's ESP has no /EFI/Linux directory"
  grep -qi "omarchy_linux-neptune-${SERIES}.efi" <<<"$listing" ||
    fail "the produced image's ESP has no omarchy_linux-neptune-${SERIES}.efi (got: ${listing})"
  log "verified from the host: ESP contains omarchy_linux-neptune-${SERIES}.efi"
fi

mv "$WORK/disk.raw" "$OUT" || fail "could not move the image to $OUT"
log "done: $OUT ($(du -h --apparent-size "$OUT" | cut -f1) apparent, $(du -h "$OUT" | cut -f1) on disk)"
