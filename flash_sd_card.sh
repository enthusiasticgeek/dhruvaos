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
sleep 1  # let the kernel re-read the partition table

echo "=== Formatting $BOOT_PART as FAT32 ==="
sudo mkfs.vfat -F 32 "$BOOT_PART"

echo "=== Building kernel.img from build/dhruva.elf ==="
arm-none-eabi-objcopy -O binary "$ROOT/build/dhruva.elf" "$ROOT/build/kernel.img"

echo "=== Writing config.txt ==="
CONFIG_TXT="$ROOT/build/config.txt"
cat > "$CONFIG_TXT" <<'EOF'
kernel=kernel.img
init_uart_clock=3000000
enable_uart=1
disable_splash=1
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

echo
echo "=== Done. Contents written to $BOOT_PART: ==="
echo "  bootcode.bin, start.elf, fixup.dat, config.txt, kernel.img"
echo
echo "Safe to remove the card and insert it in the powered-off Pi."
echo "See docs/HARDWARE_IN_LOOP.md §3 for wiring the UART console before power-on."
