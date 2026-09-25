#!/usr/bin/env bash
# Updates kernel.img on an already-flashed Dhruva OS SD card (see
# flash_sd_card.sh for the original, destructive full-card setup this
# does NOT repeat -- partition table, FAT32 format, and firmware files
# are left completely untouched here). Use this after any kernel_main.
# vani/kernel_main_rpi4.vani change once real hardware bring-up is
# underway, instead of re-running flash_sd_card.sh from scratch.
#
# Usage:
#   ./update_kernel.sh /dev/sdX
#
# Safety: unlike flash_sd_card.sh, this never partitions or formats
# anything -- worst case here is overwriting the wrong device's own
# kernel.img file. No longer gated on a specific card size (2026-09-25:
# removed the original 55-68GB/"the one 64GB card" range check at the
# user's own explicit request -- media in use now varies, e.g. the
# 16GB card from the SD-wedge card-independence test). The real safety
# net is the existing-boot-files check further down (bootcode.bin/
# start.elf/fixup.dat/config.txt must already be present) -- that
# confirms this is genuinely an already-flashed Dhruva card regardless
# of its size, which size alone never actually verified anyway (a
# same-sized WRONG device would have passed the old check too). Still
# checks the target is a real block device, and shows the boot
# partition's own existing contents for a last visual check before
# overwriting.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOUNT_POINT="/tmp/dhruva_sdcard_mount_$$"

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <device, e.g. /dev/sdb>" >&2
    exit 1
fi

DEVICE="$1"

if [ ! -b "$DEVICE" ]; then
    echo "ERROR: $DEVICE is not a block device. Refusing to continue." >&2
    exit 1
fi

if [ ! -f "$ROOT/build/dhruva.elf" ]; then
    echo "ERROR: $ROOT/build/dhruva.elf not found. Run ./build.sh first." >&2
    exit 1
fi

SIZE_BYTES=$(sudo blockdev --getsize64 "$DEVICE")
echo "=== Target device (${SIZE_BYTES} bytes -- VERIFY this is your SD card) ==="
lsblk "$DEVICE"
echo

BOOT_PART="${DEVICE}1"
if [ ! -b "$BOOT_PART" ]; then
    BOOT_PART="${DEVICE}p1"
fi
if [ ! -b "$BOOT_PART" ]; then
    echo "ERROR: no partition found at ${DEVICE}1 or ${DEVICE}p1." >&2
    echo "This doesn't look like an already-flashed Dhruva card --" >&2
    echo "use flash_sd_card.sh for a first-time setup instead." >&2
    exit 1
fi

echo "=== Building kernel.img from build/dhruva.elf ==="
arm-none-eabi-objcopy -O binary "$ROOT/build/dhruva.elf" "$ROOT/build/kernel.img"

echo "=== Unmounting $BOOT_PART if already mounted ==="
sudo umount "$BOOT_PART" 2>/dev/null || true

echo "=== Mounting $BOOT_PART ==="
mkdir -p "$MOUNT_POINT"
sudo mount "$BOOT_PART" "$MOUNT_POINT"

echo "=== Existing contents (expect bootcode.bin, start.elf, fixup.dat, config.txt, kernel.img) ==="
ls -la "$MOUNT_POINT"
echo

for f in bootcode.bin start.elf fixup.dat config.txt; do
    if [ ! -f "$MOUNT_POINT/$f" ]; then
        echo "ERROR: $MOUNT_POINT/$f not found -- this doesn't look like" >&2
        echo "an already-flashed Dhruva card. Aborting without writing" >&2
        echo "anything. Unmounting and stopping." >&2
        sudo umount "$MOUNT_POINT"
        rmdir "$MOUNT_POINT"
        exit 1
    fi
done

echo "=== Replacing kernel.img (only file touched) ==="
sudo cp "$ROOT/build/kernel.img" "$MOUNT_POINT/kernel.img"
sync

echo "=== Unmounting ==="
sudo umount "$MOUNT_POINT"
rmdir "$MOUNT_POINT"

echo
echo "=== Done. kernel.img updated on $BOOT_PART. ==="
echo "bootcode.bin/start.elf/fixup.dat/config.txt left untouched."
echo "Safe to remove the card and insert it in the powered-off Pi."
