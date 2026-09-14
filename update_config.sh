#!/usr/bin/env bash
# Updates config.txt on an already-flashed Dhruva OS SD card (see
# flash_sd_card.sh for the original, destructive full-card setup this
# does NOT repeat). Mirrors update_kernel.sh's own safety pattern --
# same size/partition checks -- but touches config.txt instead of
# kernel.img. Use this when only a config.txt setting changed (e.g.
# adding a diagnostic flag) and a full kernel rebuild+reflash isn't
# needed.
#
# Usage:
#   ./update_config.sh /dev/sdX
#
# Safety: never partitions or formats anything -- worst case here is
# overwriting the wrong device's own config.txt file. Still checks the
# target is a block device sized like the one known 64GB card on this
# machine (not any other disk) before touching it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOUNT_POINT="/tmp/dhruva_sdcard_mount_$$"

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

if [ ! -f "$ROOT/build/config.txt" ]; then
    echo "ERROR: $ROOT/build/config.txt not found." >&2
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

echo "=== Unmounting $BOOT_PART if already mounted ==="
sudo umount "$BOOT_PART" 2>/dev/null || true

echo "=== Mounting $BOOT_PART ==="
mkdir -p "$MOUNT_POINT"
sudo mount "$BOOT_PART" "$MOUNT_POINT"

echo "=== Existing contents (expect bootcode.bin, start.elf, fixup.dat, config.txt, kernel.img) ==="
ls -la "$MOUNT_POINT"
echo

for f in bootcode.bin start.elf fixup.dat kernel.img; do
    if [ ! -f "$MOUNT_POINT/$f" ]; then
        echo "ERROR: $MOUNT_POINT/$f not found -- this doesn't look like" >&2
        echo "an already-flashed Dhruva card. Aborting without writing" >&2
        echo "anything. Unmounting and stopping." >&2
        sudo umount "$MOUNT_POINT"
        rmdir "$MOUNT_POINT"
        exit 1
    fi
done

echo "=== Old config.txt on card ==="
cat "$MOUNT_POINT/config.txt" 2>/dev/null || echo "(none)"
echo

echo "=== New config.txt to write ==="
cat "$ROOT/build/config.txt"
echo

echo "=== Replacing config.txt (only file touched) ==="
sudo cp "$ROOT/build/config.txt" "$MOUNT_POINT/config.txt"
sync

echo "=== Unmounting ==="
sudo umount "$MOUNT_POINT"
rmdir "$MOUNT_POINT"

echo
echo "=== Done. config.txt updated on $BOOT_PART. ==="
echo "bootcode.bin/start.elf/fixup.dat/kernel.img left untouched."
echo "Safe to remove the card and insert it in the powered-off Pi."
