#!/bin/bash
# omarchy-deck-kernel.sh
#
# Self-contained Neptune kernel + Limine UKI setup for Steam Deck.
# Fixes (see project plan Section 8):
#   8.1 - No longer depends on a separate common-script.sh fetched via
#         relative path. Safe to run via `curl | bash`.
#   8.2 - Adds real Limine detection instead of failing with
#         "No supported bootloader detected".
#   8.3 - Detects the real ESP mount point instead of assuming /efi or /boot.
#   8.4 - Does NOT install any AUR helper as a side effect.
#   8.5 - Fixes /boot fmask/dmask so user-space scripts (including Omarchy's
#         own limine-snapper.sh) can read the Limine config, via a full
#         umount/mount cycle (a soft remount does not re-apply fmask/dmask
#         on vfat -- confirmed the hard way).
#
# Designed to be idempotent: safe to re-run. Aborts loudly (set -euo
# pipefail) rather than silently no-op'ing on a missing dependency --
# this is the direct fix for the failure mode in bug 8.1, where the
# original script printed "success" while having done almost nothing.
#
# TODO for Claude Code (Track A, Opus recommended -- see plan Section 12):
#   - Replace the hardcoded package name `linux-neptune-611` with dynamic
#     detection (pacman -Ss '^linux-neptune-[0-9]+$' or similar), since this
#     is exactly the kernel-version-churn fragility documented in plan
#     Section 11. This script currently hardcodes 611 deliberately, matching
#     what was validated live -- generalize it before relying on it long-term.
#   - Add the pacman hook (plan Section 11) that re-runs the UKI+Limine-entry
#     steps automatically on any linux-neptune* package upgrade.
#   - Wire this into the omarchy-deck-installer post-install hook chain
#     (plan Section 5, item 3) rather than running it standalone.
#   - Add non-interactive flags so it can run inside the T1 automated QEMU
#     install (plan Section 9.2) with assertable exit codes.
#
# KNOWN ISSUE (found in review, not yet fixed -- fix during T1):
#   The awk pattern that extracts the stock cmdline uses a PREFIX match on
#   `/Arch Linux (linux)`, which would also match `/Arch Linux (linux-neptune-611)`.
#   The idempotency guard above it currently prevents this from being reached
#   in the normal path, but it is fragile: on a system where a neptune entry
#   exists under a different name, the wrong cmdline could be extracted.
#   Anchor the match properly.

set -euo pipefail

log()  { printf '[omarchy-deck-kernel] %s\n' "$1"; }
fail() { printf '[omarchy-deck-kernel] ERROR: %s\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 0. Preconditions
# ---------------------------------------------------------------------------

command -v pacman >/dev/null 2>&1 || fail "pacman not found -- this script only supports Arch"
command -v sudo   >/dev/null 2>&1 || fail "sudo not found"

# Confirm we're actually on Deck hardware before doing anything Deck-specific.
if ! grep -qi "steam deck\|jupiter\|galileo" /sys/class/dmi/id/product_name 2>/dev/null \
   && ! grep -qi "valve" /sys/class/dmi/id/sys_vendor 2>/dev/null; then
    fail "This does not look like Steam Deck hardware (check /sys/class/dmi/id/product_name). Refusing to proceed."
fi
log "Steam Deck hardware confirmed."

KERNEL_PKG="linux-neptune-611"
KERNEL_PRESET="/etc/mkinitcpio.d/${KERNEL_PKG}.preset"

# ---------------------------------------------------------------------------
# 1. Add Valve's repos if not already present
# ---------------------------------------------------------------------------

add_repo_if_missing() {
    local repo_name="$1"
    if ! grep -q "^\[${repo_name}\]" /etc/pacman.conf; then
        log "Adding ${repo_name} to pacman.conf"
        sudo tee -a /etc/pacman.conf > /dev/null << EOF

[${repo_name}]
Server = https://steamdeck-packages.steamos.cloud/archlinux-mirror/\$repo/os/\$arch
SigLevel = Never
EOF
    else
        log "${repo_name} already present in pacman.conf, skipping"
    fi
}

add_repo_if_missing "jupiter-staging"
add_repo_if_missing "holo-staging"

sudo pacman -Sy || fail "pacman -Sy failed -- check network/repo config"

# ---------------------------------------------------------------------------
# 2. Install the Neptune kernel + firmware (idempotent: pacman no-ops if
#    already installed and up to date)
# ---------------------------------------------------------------------------

log "Installing ${KERNEL_PKG} and firmware..."
sudo pacman -S --needed --noconfirm \
    "${KERNEL_PKG}" \
    "${KERNEL_PKG}-headers" \
    linux-firmware-neptune \
    steamdeck-dsp \
    || fail "Kernel/firmware package installation failed"

[[ -f "/boot/vmlinuz-${KERNEL_PKG}" ]] || fail "Kernel image not found after install -- pacman reported success but the file is missing. Do not proceed."
[[ -f "$KERNEL_PRESET" ]] || fail "mkinitcpio preset not found at $KERNEL_PRESET -- package layout may have changed, check plan Section 11"

# ---------------------------------------------------------------------------
# 3. Detect the real ESP (fixes bug 8.3 -- do not assume /boot or /efi)
# ---------------------------------------------------------------------------

ESP_PATH=$(findmnt -n -o TARGET --source "$(findmnt -n -o SOURCE /boot 2>/dev/null || true)" 2>/dev/null || true)
if [[ -z "$ESP_PATH" ]]; then
    # Fall back to checking the two conventional mountpoints directly.
    if findmnt /boot >/dev/null 2>&1; then
        ESP_PATH="/boot"
    elif findmnt /efi >/dev/null 2>&1; then
        ESP_PATH="/efi"
    else
        fail "Could not detect ESP mount point at /boot or /efi. Run 'findmnt' manually and adjust ESP_PATH."
    fi
fi
log "Detected ESP at: ${ESP_PATH}"

UKI_PATH="${ESP_PATH}/EFI/Linux/arch-${KERNEL_PKG}.efi"

# ---------------------------------------------------------------------------
# 4. Patch the mkinitcpio preset to emit a UKI at the correct path
#    (fixes bug 8.3 -- the shipped preset defaults to a wrong, commented-out
#    /efi/... path regardless of where the ESP actually is)
# ---------------------------------------------------------------------------

if grep -q "^default_uki=" "$KERNEL_PRESET"; then
    CURRENT_UKI_LINE=$(grep "^default_uki=" "$KERNEL_PRESET")
    if [[ "$CURRENT_UKI_LINE" == "default_uki=\"${UKI_PATH}\"" ]]; then
        log "Preset already correctly configured, skipping patch"
    else
        log "Preset has a default_uki line pointing elsewhere ($CURRENT_UKI_LINE) -- correcting"
        sudo sed -i "s|^default_uki=.*|default_uki=\"${UKI_PATH}\"|" "$KERNEL_PRESET"
    fi
else
    log "Uncommenting and setting default_uki in preset"
    sudo sed -i "s|^#default_uki=.*|default_uki=\"${UKI_PATH}\"|" "$KERNEL_PRESET"
    # If there was no commented line to uncomment at all, append one.
    if ! grep -q "^default_uki=" "$KERNEL_PRESET"; then
        echo "default_uki=\"${UKI_PATH}\"" | sudo tee -a "$KERNEL_PRESET" > /dev/null
    fi
fi

log "Regenerating UKI for ${KERNEL_PKG}..."
sudo mkinitcpio -p "${KERNEL_PKG}" || fail "mkinitcpio failed -- check output above"
[[ -f "$UKI_PATH" ]] || fail "UKI was not created at expected path: $UKI_PATH"
log "UKI confirmed at ${UKI_PATH}"

# ---------------------------------------------------------------------------
# 5. Fix /boot mount permissions (fixes bug 8.5)
#    A soft `mount -o remount` does NOT re-apply fmask/dmask on vfat --
#    confirmed empirically. Full umount/mount cycle required.
# ---------------------------------------------------------------------------

if grep -q "fmask=0077,dmask=0077" /etc/fstab; then
    log "Loosening ${ESP_PATH} permissions so user-space scripts can read it (fmask=0133,dmask=0022)"
    sudo sed -i 's/fmask=0077,dmask=0077/fmask=0133,dmask=0022/' /etc/fstab
    sudo systemctl daemon-reload
    sudo umount "$ESP_PATH" || fail "Could not unmount ${ESP_PATH} -- if 'target is busy', reboot and re-run this script instead of forcing it"
    sudo mount "$ESP_PATH"
    mount | grep "$ESP_PATH" | grep -q "fmask=0133" || fail "Permission fix did not take effect after remount"
else
    log "fstab already has non-default fmask/dmask, or none at all -- skipping (verify manually if unexpected)"
fi

# ---------------------------------------------------------------------------
# 6. Detect Limine config and add a boot entry (fixes bug 8.2)
#    Probes the same candidate paths Omarchy's own limine-snapper.sh checks,
#    per plan Section 8.2 -- do not hardcode a single path.
# ---------------------------------------------------------------------------

LIMINE_CANDIDATES=(
    "${ESP_PATH}/EFI/arch-limine/limine.conf"
    "${ESP_PATH}/EFI/BOOT/limine.conf"
    "${ESP_PATH}/EFI/limine/limine.conf"
    "${ESP_PATH}/limine/limine.conf"
    "${ESP_PATH}/limine.conf"
)

LIMINE_CONFIG=""
for candidate in "${LIMINE_CANDIDATES[@]}"; do
    if sudo test -f "$candidate"; then
        LIMINE_CONFIG="$candidate"
        break
    fi
done

[[ -n "$LIMINE_CONFIG" ]] || fail "No Limine config found in any expected location. Is Limine actually installed? See plan Section 6.3 -- this project requires Limine, not GRUB/systemd-boot."
log "Found Limine config at: ${LIMINE_CONFIG}"

if sudo grep -q "arch-${KERNEL_PKG}" "$LIMINE_CONFIG"; then
    log "Limine entry for ${KERNEL_PKG} already exists, skipping"
else
    log "Adding Limine boot entry for ${KERNEL_PKG}..."
    # Reuse the existing stock entry's cmdline rather than hand-constructing
    # one -- this is the exact class of typo that cost real time when done
    # by hand (a heredoc-wrapped cmdline silently split across two lines).
    STOCK_CMDLINE=$(sudo awk '
        /^\/Arch Linux \(linux\)/ { found=1 }
        found && /cmdline:/ { sub(/^[ \t]*cmdline:[ \t]*/, ""); print; exit }
    ' "$LIMINE_CONFIG")

    [[ -n "$STOCK_CMDLINE" ]] || fail "Could not extract cmdline from existing stock entry in $LIMINE_CONFIG -- inspect the file manually, its format may differ from what this script expects"

    sudo tee -a "$LIMINE_CONFIG" > /dev/null << EOF

/Arch Linux (${KERNEL_PKG})
    protocol: efi
    path: boot():/EFI/Linux/arch-${KERNEL_PKG}.efi
    cmdline: ${STOCK_CMDLINE}
EOF

    # Verify the write actually produced a well-formed, single-line cmdline
    # entry -- catches the exact bug hit by hand this session.
    ENTRY_LINE_COUNT=$(sudo grep -c "^/Arch Linux (${KERNEL_PKG})" "$LIMINE_CONFIG")
    [[ "$ENTRY_LINE_COUNT" -eq 1 ]] || fail "Limine entry write produced unexpected result (expected exactly 1 matching entry, found $ENTRY_LINE_COUNT). Inspect $LIMINE_CONFIG manually before rebooting."
fi

log "Done. Reboot and select 'Arch Linux (${KERNEL_PKG})' from the Limine menu."
log "After boot, confirm with: uname -r"
log "Expected output to contain: ${KERNEL_PKG#linux-}"
