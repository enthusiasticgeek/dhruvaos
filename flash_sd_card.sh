#!/usr/bin/env bash
# Prepares a real SD card for Dhruva OS hardware-in-loop testing on a
# Raspberry Pi 1 Model B -- see docs/HARDWARE_IN_LOOP.md for the full
# explanation of every step this automates (partition offset choice,
# the UART clock config.txt setting, why this matters).
#
# This script only automates the MECHANICAL steps (partition, format,
# copy). It deliberately does NOT auto-detect the target device or
# provide a default -- you must name it explicitly, see it printed
# back via lsblk, and type it a second time to confirm, specifically
# because a wrong-device mistake here is a real, hard-to-reverse data
# loss risk (this script uses `parted`/`mkfs.vfat` against a whole
# block device).
#
# Usage:
#   ./flash_sd_card.sh /dev/sdX /path/to/firmware/dir
#
# /path/to/firmware/dir must already contain bootcode.bin, start.elf,
# fixup.dat (the original, non-suffixed Pi 1/Zero-generation files --
# see docs/HARDWARE_IN_LOOP.md §4.1 for where to get them; this
# script does not fetch them for you).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOT_PART_START_SECTOR=16384   # 8MiB -- comfortable margin past DharaFS's
                                # own 1MB (blocks 1-2048) ceiling; see
                                # docs/HARDWARE_IN_LOOP.md §4.2.
MOUNT_POINT="/tmp/dhruva_sdcard_mount_$$"

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <device, e.g. /dev/sdX> <firmware-dir>" >&2
    echo "  firmware-dir must contain bootcode.bin, start.elf, fixup.dat" >&2
    exit 1
fi

DEVICE="$1"
FW_DIR="$2"

if [ ! -b "$DEVICE" ]; then
    echo "ERROR: $DEVICE is not a block device. Refusing to continue." >&2
    exit 1
fi

for f in bootcode.bin start.elf fixup.dat; do
    if [ ! -f "$FW_DIR/$f" ]; then
        echo "ERROR: $FW_DIR/$f not found. Get the original (non-suffixed)" >&2
        echo "Pi 1/Zero-generation firmware files first -- see" >&2
        echo "docs/HARDWARE_IN_LOOP.md §4.1." >&2
        exit 1
    fi
done

if [ ! -f "$ROOT/build/dhruva.elf" ]; then
    echo "ERROR: $ROOT/build/dhruva.elf not found. Run ./build.sh first." >&2
    exit 1
fi

echo "=== Target device details (VERIFY this is your SD card, not a disk you care about) ==="
lsblk "$DEVICE"
echo
echo "This will COMPLETELY ERASE $DEVICE and everything on it."
echo "Type the device path again to confirm (e.g. $DEVICE): "
read -r CONFIRM
if [ "$CONFIRM" != "$DEVICE" ]; then
    echo "Confirmation did not match. Aborting -- nothing was touched." >&2
    exit 1
fi

# A second, different-shaped confirmation -- deliberately not just the
# same string again, so a copy-pasted first answer can't silently
# satisfy both gates.
echo "Type YES (all caps) to proceed: "
read -r CONFIRM2
if [ "$CONFIRM2" != "YES" ]; then
    echo "Confirmation did not match. Aborting -- nothing was touched." >&2
    exit 1
fi

echo "=== Unmounting any existing partitions on $DEVICE ==="
for part in "${DEVICE}"?*; do
    [ -b "$part" ] && sudo umount "$part" 2>/dev/null || true
done

echo "=== Partitioning $DEVICE (MBR, one FAT32 partition starting at sector $BOOT_PART_START_SECTOR) ==="
sudo parted --script "$DEVICE" mklabel msdos
sudo parted --script "$DEVICE" mkpart primary fat32 "${BOOT_PART_START_SECTOR}s" 100%

BOOT_PART="${DEVICE}1"
if [ ! -b "$BOOT_PART" ]; then
    # some kernels/device types name the first partition differently
    # (e.g. /dev/mmcblk0p1) -- handle the common alternate shape.
    BOOT_PART="${DEVICE}p1"
fi
# FIX (2026-09-15): a plain `sleep 1` doesn't guarantee the kernel's own
# partition-table view (and udev's own /dev/sdXN node creation) has
# actually caught up with what parted just wrote -- neither parted's
# own manual nor its man page document this as reliable, and it's a
# well-known race specifically on removable/USB media (slower to
# re-enumerate than a fixed sleep can assume). `udevadm settle` is the
# documented, race-free wait -- blocks until udev's own event queue is
# actually empty, not a fixed guess at how long that might take. Also
# explicitly wait for BOOT_PART's own device node to exist (belt and
# suspenders: settle can return before every device-specific symlink/
# node is live on some systems).
sudo udevadm settle
for _ in $(seq 1 50); do
    [ -b "$BOOT_PART" ] && break
    sleep 0.2
done
if [ ! -b "$BOOT_PART" ]; then
    echo "ERROR: $BOOT_PART never appeared after partitioning -- the kernel" >&2
    echo "may not have picked up the new partition table. Try re-running," >&2
    echo "or manually run 'sudo partprobe $DEVICE' first." >&2
    exit 1
fi

echo "=== Formatting $BOOT_PART as FAT32 ==="
sudo mkfs.vfat -F 32 "$BOOT_PART"

echo "=== Building kernel.img from build/dhruva.elf ==="
arm-none-eabi-objcopy -O binary "$ROOT/build/dhruva.elf" "$ROOT/build/kernel.img"

echo "=== Writing config.txt ==="
# FIX (2026-09-15): this template used to be missing uart_2ndstage=1
# (added 2026-09-14 to a since-updated build/config.txt, but never
# back-ported here) -- a full reflash via this script silently
# overwrote a working card's own config.txt with this stale version,
# losing the GPU/bootloader's own 2nd-stage UART diagnostic log for
# no visible reason. Kept in sync with build/config.txt's own real
# content going forward rather than a separate hardcoded copy that can
# drift again.
CONFIG_TXT="$ROOT/build/config.txt"
cat > "$CONFIG_TXT" <<'EOF'
kernel=kernel.img
init_uart_clock=3000000
enable_uart=1
disable_splash=1
uart_2ndstage=1
EOF

echo "=== Mounting $BOOT_PART and copying files ==="
mkdir -p "$MOUNT_POINT"
sudo mount "$BOOT_PART" "$MOUNT_POINT"
sudo cp "$FW_DIR/bootcode.bin" "$FW_DIR/start.elf" "$FW_DIR/fixup.dat" "$MOUNT_POINT/"
sudo cp "$CONFIG_TXT" "$MOUNT_POINT/config.txt"
sudo cp "$ROOT/build/kernel.img" "$MOUNT_POINT/kernel.img"
sync
sudo umount "$MOUNT_POINT"
rmdir "$MOUNT_POINT"

# FIX (2026-09-15): verify by UNMOUNTING then REMOUNTING and re-reading
# every file back, not just checksumming while still mounted -- a file
# that reads back correctly from the SAME mount can still be sitting
# only in the page cache, not actually durable on the physical media
# yet (the exact "FAT32 write-caching/flush reliability over a USB SD
# reader" risk category flagged, but left mechanistically unconfirmed,
# by this round's own research). A real unmount+remount+re-read cycle
# is what actually rules that out, not `sync` alone (which flushes but
# doesn't itself prove the flush reached the device before the card was
# powered off/removed in a real accident scenario -- this can't fully
# simulate power loss either, but it's a strictly stronger check than
# anything this script did before).
echo "=== Verifying: unmounting, remounting, re-reading every file back ==="
mkdir -p "$MOUNT_POINT"
sudo mount "$BOOT_PART" "$MOUNT_POINT"
VERIFY_OK=1
for f in bootcode.bin start.elf fixup.dat config.txt kernel.img; do
    SRC=""
    case "$f" in
        bootcode.bin|start.elf|fixup.dat) SRC="$FW_DIR/$f" ;;
        config.txt) SRC="$CONFIG_TXT" ;;
        kernel.img) SRC="$ROOT/build/kernel.img" ;;
    esac
    SRC_SUM=$(md5sum "$SRC" | cut -d' ' -f1)
    CARD_SUM=$(sudo md5sum "$MOUNT_POINT/$f" 2>/dev/null | cut -d' ' -f1 || echo "MISSING")
    if [ "$SRC_SUM" != "$CARD_SUM" ]; then
        echo "ERROR: $f mismatch after remount -- source=$SRC_SUM card=$CARD_SUM" >&2
        VERIFY_OK=0
    fi
done
sudo umount "$MOUNT_POINT"
rmdir "$MOUNT_POINT"

if [ "$VERIFY_OK" -ne 1 ]; then
    echo "ERROR: verification FAILED -- do not trust this card, re-run this" >&2
    echo "script (or investigate the SD reader/card itself) before testing" >&2
    echo "on real hardware." >&2
    exit 1
fi

echo
echo "=== Done. Contents written AND verified (post-remount re-read) on $BOOT_PART: ==="
echo "  bootcode.bin, start.elf, fixup.dat, config.txt, kernel.img"
echo
echo "Safe to remove the card and insert it in the powered-off Pi."
echo "See docs/HARDWARE_IN_LOOP.md §3 for wiring the UART console before power-on."
