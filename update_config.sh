#!/usr/bin/env bash
# Updates config.txt on an already-flashed Dhruva OS SD card (see
# flash_sd_card.sh for the original, destructive full-card setup this
# does NOT repeat). Mirrors update_kernel.sh's own safety pattern --
# same existing-boot-files/partition check -- but touches config.txt
# instead of kernel.img. Use this when only a config.txt setting
# changed (e.g. adding a diagnostic flag, or reverting a config.txt
# override like flash_uboot_test.sh's own "kernel=u-boot.bin" append)
# and a full kernel rebuild+reflash isn't needed.
#
# Usage:
#   ./update_config.sh /dev/sdX
#
# Safety: never partitions or formats anything -- worst case here is
# overwriting the wrong device's own config.txt file. No longer gated
# on a specific card size (2026-09-26: dropped the old 55-68GB/"the
# one known 64GB card" range check to match update_kernel.sh's own
# already-approved 2026-09-25 fix -- media in use varies, e.g. the
# 14.9GB card in active use this session; a same-sized WRONG device
# would have passed the old check too). The real safety net is the
# existing-boot-files check further down (bootcode.bin/start.elf/
# fixup.dat/kernel.img must already be present).
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

if [ ! -f "$ROOT/build/config.txt" ]; then
    echo "ERROR: $ROOT/build/config.txt not found." >&2
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
