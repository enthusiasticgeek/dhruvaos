#!/usr/bin/env bash
# Reusable helper for temporarily booting something OTHER than
# DhruvaOS's own kernel.img on a real, already-flashed SD card --
# e.g. a stock U-Boot build, to get independent ground truth on
# whether a real-HW symptom (task #325's USB enumeration STALL was
# the first use of this) is specific to DhruvaOS's own driver code or
# something board/chip-level that an unrelated, trusted stack would
# also hit.
#
# Deliberately narrower than flash_sd_card.sh: this never partitions
# or reformats anything. It only ever touches one file -- kernel.img
# -- on the boot (FAT32) partition of an SD card that's already set
# up and booting (bootcode.bin/start.elf/fixup.dat/config.txt already
# present and correct). See docs/PI1B_BOOT_SEQUENCE.md for why a
# single flat binary named by config.txt's own `kernel=` line, loaded
# at a fixed physical address (0x8000), is all the GPU firmware ever
# needs -- any image linked for that same address (DhruvaOS's own
# kernel.img, or e.g. a Pi1-targeted U-Boot's own u-boot.bin) is a
# directly interchangeable drop-in, no partition/firmware-file
# changes required.
#
# Usage:
#   ./swap_test_kernel.sh <device, e.g. /dev/sdX> swap <path/to/test-kernel.img>
#   ./swap_test_kernel.sh <device, e.g. /dev/sdX> restore
#   ./swap_test_kernel.sh <device, e.g. /dev/sdX> status
#
# swap:    backs up the CURRENT kernel.img to kernel.img.dhruva-backup
#          (only if no backup already exists there -- see below), then
#          copies the given test image in as kernel.img.
# restore: copies kernel.img.dhruva-backup back over kernel.img.
# status:  read-only -- reports what's currently live and whether a
#          backup exists. Makes no changes, asks no confirmation.
#
# Deliberately refuses to overwrite an existing kernel.img.dhruva-
# backup on a second `swap` call: if you swap, forget to restore, and
# swap again (e.g. trying a second test image), a naive "always
# backup current kernel.img" would silently replace the REAL DhruvaOS
# backup with the first test image, making it unrecoverable. `swap`
# with a backup already present just replaces the live kernel.img and
# leaves the existing backup alone -- the real DhruvaOS image stays
# recoverable via `restore` no matter how many swaps happen in
# between. Use --force-backup to intentionally re-snapshot the
# current kernel.img as the new backup instead (rarely what you want).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOUNT_POINT="/tmp/dhruva_swap_test_kernel_mount_$$"
BACKUP_NAME="kernel.img.dhruva-backup"

usage() {
    echo "Usage:" >&2
    echo "  $0 <device, e.g. /dev/sdX> swap <path/to/test-kernel.img> [--force-backup]" >&2
    echo "  $0 <device, e.g. /dev/sdX> restore" >&2
    echo "  $0 <device, e.g. /dev/sdX> status" >&2
    exit 1
}

if [ "$#" -lt 2 ]; then
    usage
fi

DEVICE="$1"
ACTION="$2"
shift 2 || true

if [ ! -b "$DEVICE" ]; then
    echo "ERROR: $DEVICE is not a block device. Refusing to continue." >&2
    exit 1
fi

case "$ACTION" in
    swap)
        if [ "$#" -lt 1 ]; then
            echo "ERROR: swap needs a path to the test kernel image." >&2
            usage
        fi
        TEST_IMAGE="$1"
        FORCE_BACKUP=0
        if [ "${2:-}" = "--force-backup" ]; then
            FORCE_BACKUP=1
        fi
        if [ ! -f "$TEST_IMAGE" ]; then
            echo "ERROR: $TEST_IMAGE not found." >&2
            exit 1
        fi
        ;;
    restore|status)
        :
        ;;
    *)
        echo "ERROR: unknown action '$ACTION'." >&2
        usage
        ;;
esac

BOOT_PART="${DEVICE}1"
if [ ! -b "$BOOT_PART" ]; then
    BOOT_PART="${DEVICE}p1"
fi
if [ ! -b "$BOOT_PART" ]; then
    echo "ERROR: couldn't find a boot partition for $DEVICE (tried ${DEVICE}1 and ${DEVICE}p1)." >&2
    exit 1
fi

# swap/restore both modify real boot media the user cares about --
# same two-step, differently-shaped confirmation flash_sd_card.sh
# uses, so a copy-pasted first answer can't silently satisfy both
# gates. status is read-only and skips this entirely.
if [ "$ACTION" != "status" ]; then
    echo "=== Target device details (VERIFY this is your SD card) ==="
    lsblk "$DEVICE"
    echo
    echo "About to run '$ACTION' against $BOOT_PART's own kernel.img."
    echo "Type the device path again to confirm (e.g. $DEVICE): "
    read -r CONFIRM
    if [ "$CONFIRM" != "$DEVICE" ]; then
        echo "Confirmation did not match. Aborting -- nothing was touched." >&2
        exit 1
    fi
    echo "Type YES (all caps) to proceed: "
    read -r CONFIRM2
    if [ "$CONFIRM2" != "YES" ]; then
        echo "Confirmation did not match. Aborting -- nothing was touched." >&2
        exit 1
    fi
fi

mkdir -p "$MOUNT_POINT"
cleanup() {
    sudo umount "$MOUNT_POINT" 2>/dev/null || true
    rmdir "$MOUNT_POINT" 2>/dev/null || true
}
trap cleanup EXIT

echo "=== Mounting $BOOT_PART ==="
sudo mount "$BOOT_PART" "$MOUNT_POINT"

case "$ACTION" in
    status)
        echo "=== Status ==="
        if [ -f "$MOUNT_POINT/$BACKUP_NAME" ]; then
            echo "Backup present: $BACKUP_NAME ($(stat -c '%y' "$MOUNT_POINT/$BACKUP_NAME"))"
            echo "  -> a test image is very likely the one currently live as kernel.img."
        else
            echo "No backup present -- kernel.img is very likely still the original DhruvaOS image"
            echo "  (or a swap was run with --force-backup, discarding the ability to tell)."
        fi
        if [ -f "$MOUNT_POINT/kernel.img" ]; then
            echo "Live kernel.img: $(stat -c '%s bytes, modified %y' "$MOUNT_POINT/kernel.img")"
        else
            echo "WARNING: no kernel.img present at all on $BOOT_PART." >&2
        fi
        ;;
    swap)
        if [ -f "$MOUNT_POINT/$BACKUP_NAME" ] && [ "$FORCE_BACKUP" -eq 0 ]; then
            echo "=== Backup already exists at $BACKUP_NAME -- leaving it alone ==="
            echo "    (pass --force-backup if you really want to re-snapshot the CURRENT"
            echo "    kernel.img over it -- only do this if you're certain it's still the"
            echo "    real DhruvaOS image and not a leftover test image from an unrestored"
            echo "    earlier swap)."
        else
            if [ ! -f "$MOUNT_POINT/kernel.img" ]; then
                echo "ERROR: no existing kernel.img to back up, and no backup present either." >&2
                echo "Refusing to guess -- restore a known-good DhruvaOS kernel.img first." >&2
                exit 1
            fi
            echo "=== Backing up current kernel.img -> $BACKUP_NAME ==="
            sudo cp "$MOUNT_POINT/kernel.img" "$MOUNT_POINT/$BACKUP_NAME"
        fi
        echo "=== Copying $TEST_IMAGE -> kernel.img ==="
        sudo cp "$TEST_IMAGE" "$MOUNT_POINT/kernel.img"
        sudo sync
        echo "=== Done. $BOOT_PART will now boot $TEST_IMAGE on next power-on. ==="
        echo "    Run '$0 $DEVICE restore' afterward to bring DhruvaOS back."
        ;;
    restore)
        if [ ! -f "$MOUNT_POINT/$BACKUP_NAME" ]; then
            echo "ERROR: no $BACKUP_NAME found on $BOOT_PART -- nothing to restore." >&2
            echo "(Was swap ever run? Or was it already restored?)" >&2
            exit 1
        fi
        echo "=== Restoring $BACKUP_NAME -> kernel.img ==="
        sudo cp "$MOUNT_POINT/$BACKUP_NAME" "$MOUNT_POINT/kernel.img"
        sudo sync
        echo "=== Done. $BOOT_PART will boot the restored DhruvaOS kernel.img on next power-on. ==="
        echo "    (backup left in place -- delete $BACKUP_NAME manually if you no longer need it)"
        ;;
esac
