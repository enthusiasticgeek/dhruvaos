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
#   ./flash_sd_card.sh /dev/sdX /path/to/firmware/dir [--with-wifi-firmware /dev/ttyUSB0]
#
# /path/to/firmware/dir must already contain bootcode.bin, start.elf,
# fixup.dat (the original, non-suffixed Pi 1/Zero-generation files --
# see docs/HARDWARE_IN_LOOP.md §4.1 for where to get them; this
# script does not fetch them for you).
#
# --with-wifi-firmware <serial-device> (optional, 2026-10-10): the
# RTL8188CU/RTL8192CU WiFi firmware is NOT part of this script's own
# boot-partition write -- it's a proprietary binary this project has
# no FAT-write-from-kernel capability to place on the card directly
# (see docs/HARDWARE_IN_LOOP.md §6.1), so it has to go over a LIVE
# UART shell connection into DharaFS, which only exists once the board
# is actually powered on and booted -- a fundamentally later step than
# anything else this script does. Passing this flag fetches the
# firmware (via fetch_wifi_firmware.sh, if not already cached locally
# -- never committed to this repo either way), then, once this
# script's own card-prep work is done, prompts you to power on the
# board and uploads it automatically (test/wifikey_upload.py) once it
# answers on <serial-device>.
#
# --with-wifi-creds <ssid-file> <pwd-file> (optional, 2026-10-10):
# layered on top of --with-wifi-firmware's own power-on prompt (SSID/
# password are boot-time-only config, same as the firmware, so the
# SAME already-booted board is reused rather than prompting twice) --
# runs test/wifi_creds_upload.py right after the firmware upload,
# using YOUR explicit file paths. Deliberately NOT a default/
# convention-based path: unlike the firmware (one fixed binary, same
# for every user of this chip), SSID/password are per-user secrets --
# this script has no business guessing which files are "yours," and
# wifi_creds_upload.py's own design already keeps their contents out
# of every log/transcript it touches.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOT_PART_START_SECTOR=16384   # 8MiB -- comfortable margin past DharaFS's
                                # own 1MB (blocks 1-2048) ceiling; see
                                # docs/HARDWARE_IN_LOOP.md §4.2.
MOUNT_POINT="/tmp/dhruva_sdcard_mount_$$"

WIFI_SERIAL_DEVICE=""
WIFI_SSID_FILE=""
WIFI_PWD_FILE=""
POSITIONAL=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --with-wifi-firmware)
            WIFI_SERIAL_DEVICE="$2"
            shift 2
            ;;
        --with-wifi-creds)
            WIFI_SSID_FILE="$2"
            WIFI_PWD_FILE="$3"
            shift 3
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done
set -- "${POSITIONAL[@]}"

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <device, e.g. /dev/sdX> <firmware-dir> [--with-wifi-firmware /dev/ttyUSB0] [--with-wifi-creds <ssid-file> <pwd-file>]" >&2
    echo "  firmware-dir must contain bootcode.bin, start.elf, fixup.dat" >&2
    exit 1
fi

if [ -n "$WIFI_SSID_FILE" ] && [ -z "$WIFI_SERIAL_DEVICE" ]; then
    echo "ERROR: --with-wifi-creds requires --with-wifi-firmware (it reuses that same" >&2
    echo "already-booted board rather than prompting for a second power-on)." >&2
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

if [ -n "$WIFI_SERIAL_DEVICE" ]; then
    echo
    echo "=== --with-wifi-firmware given: fetching WiFi firmware (if not already cached) ==="
    WIFI_FW_PATH="$("$ROOT/fetch_wifi_firmware.sh")"
    echo
    echo "Insert the card and power on the Pi now."
    read -r -p "Press Enter once the board is powered on and booting: " _
    echo "=== Uploading $WIFI_FW_PATH over $WIFI_SERIAL_DEVICE (waits for boot to reach the shell) ==="
    python3 "$ROOT/test/wifikey_upload.py" "$WIFI_SERIAL_DEVICE" "$WIFI_FW_PATH" --boot-timeout 180

    if [ -n "$WIFI_SSID_FILE" ]; then
        echo "=== Writing WiFi SSID/password (contents never shown) over $WIFI_SERIAL_DEVICE ==="
        python3 "$ROOT/test/wifi_creds_upload.py" "$WIFI_SSID_FILE" "$WIFI_PWD_FILE" "$WIFI_SERIAL_DEVICE"
        echo "Reboot the board (power-cycle) for the firmware + credentials to take effect."
    fi
fi
