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
# kernel.img file. Still checks the target is a block device sized
# like the one known 64GB card on this machine (not any other disk)
# before touching it, and shows the boot partition's own existing
# contents for a last visual check before overwriting.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOUNT_POINT="/tmp/dhruva_sdcard_mount_$$"

# The one real card this project has flashed is a 64GB unit -- actual
# reported capacity for "64GB" media is almost always a bit under that
# (flash/SD vendors count in decimal GB, block devices report binary
# bytes), so this checks a wide-but-still-specific band rather than an
# exact byte count.
MIN_BYTES=$((55 * 1000 * 1000 * 1000))
MAX_BYTES=$((68 * 1000 * 1000 * 1000))

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
if [ "$SIZE_BYTES" -lt "$MIN_BYTES" ] || [ "$SIZE_BYTES" -gt "$MAX_BYTES" ]; then
    echo "ERROR: $DEVICE is ${SIZE_BYTES} bytes -- not in the expected" >&2
    echo "55-68GB range for the known Dhruva SD card. Refusing to" >&2
    echo "continue -- this does not look like the right device." >&2
    exit 1
fi

echo "=== Target device (size check passed: ${SIZE_BYTES} bytes) ==="
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
