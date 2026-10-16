#!/usr/bin/env bash
# Updates kernel.img on an already-flashed Dhruva OS SD card (see
# flash_sd_card.sh for the original, destructive full-card setup this
# does NOT repeat -- partition table, FAT32 format, and firmware files
# are left completely untouched here).
#
# A/B kernel slots (task #308): the file named kernel.img on the card
# is now permanently stage-0, NOT the real DhruvaOS kernel -- that's
# what GPU firmware loads at the fixed physical address 0x8000, and
# stage-0 is the one piece of this feature that genuinely still needs
# the physical card-swap dance to update (expected to be extremely
# rare once proven). Routine kernel_main.vani/kernel_main_rpi4.vani
# changes go over UART instead (`kernelupload`/`kernelslot`, see
# test/kernel_upload.py) -- never through this script anymore.
#
# Usage:
#   ./update_kernel.sh /dev/sdX [--with-wifi-firmware /dev/ttyUSB0]
#
# --with-wifi-firmware <serial-device> / --with-wifi-creds <ssid-file>
# <pwd-file> (optional, 2026-10-10): same flags/behavior as
# flash_sd_card.sh's own -- see that script's header comment for why
# the WiFi firmware upload is a separate, later, live-UART step rather
# than something this script could write to the card directly, and
# why credentials are never auto-picked by convention.
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

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <device, e.g. /dev/sdb> [--with-wifi-firmware /dev/ttyUSB0] [--with-wifi-creds <ssid-file> <pwd-file>]" >&2
    exit 1
fi

if [ -n "$WIFI_SSID_FILE" ] && [ -z "$WIFI_SERIAL_DEVICE" ]; then
    echo "ERROR: --with-wifi-creds requires --with-wifi-firmware (it reuses that same" >&2
    echo "already-booted board rather than prompting for a second power-on)." >&2
    exit 1
fi

DEVICE="$1"

if [ ! -b "$DEVICE" ]; then
    echo "ERROR: $DEVICE is not a block device. Refusing to continue." >&2
    exit 1
fi

if [ ! -f "$ROOT/build/stage0.elf" ]; then
    echo "ERROR: $ROOT/build/stage0.elf not found. Run ./build_stage0.sh first." >&2
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

echo "=== Building kernel.img (stage-0) from build/stage0.elf ==="
arm-none-eabi-objcopy -O binary "$ROOT/build/stage0.elf" "$ROOT/build/stage0.img"

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

echo "=== Replacing kernel.img, i.e. stage-0 (only file touched) ==="
sudo cp "$ROOT/build/stage0.img" "$MOUNT_POINT/kernel.img"
sync

echo "=== Unmounting ==="
sudo umount "$MOUNT_POINT"
rmdir "$MOUNT_POINT"

# TASK #353 REAL-HW FOLLOW-UP (2026-10-16): this script used to declare
# "Done" right after the cp+sync+umount above, with NOTHING verifying
# the write actually reached physical media -- found live, the hard
# way: a USB SD reader that doesn't signal "media removed" when just
# the card (not the whole adapter) is pulled leaves the kernel's block
# layer with STALE size/partition/page-cache state, so every check
# this script already had (blockdev size, lsblk, the bootcode.bin/
# start.elf/etc. existence check above) can all read cached data and
# "pass" even with the card physically absent, and cp+sync can return
# success against that same stale state. A genuine UNMOUNT, already
# done above, drops this mount's own page cache -- but nothing forced
# a fresh READ afterward to prove the NEXT mount isn't ALSO just
# replaying stale cache. Remounting and reading the file straight back
# (same "don't trust a cache hit" discipline flash_sd_card.sh's own
# verify step already uses) is what actually proves this.
echo "=== Verifying: remounting and reading kernel.img straight back ==="
mkdir -p "$MOUNT_POINT"
sudo mount "$BOOT_PART" "$MOUNT_POINT"
SRC_SUM=$(md5sum "$ROOT/build/stage0.img" | cut -d' ' -f1)
CARD_SUM=$(sudo md5sum "$MOUNT_POINT/kernel.img" 2>/dev/null | cut -d' ' -f1 || echo "MISSING")
sudo umount "$MOUNT_POINT"
rmdir "$MOUNT_POINT"
if [ "$SRC_SUM" != "$CARD_SUM" ]; then
    echo "ERROR: kernel.img verification FAILED after remount -- source=$SRC_SUM card=$CARD_SUM" >&2
    echo "The write did NOT actually reach the card (or this device/reader" >&2
    echo "is reporting stale state -- check the card is genuinely inserted" >&2
    echo "and re-run). Do NOT trust this card until this passes clean." >&2
    exit 1
fi

echo
echo "=== Done and VERIFIED (remount + checksum match). kernel.img updated on $BOOT_PART. ==="
echo "bootcode.bin/start.elf/fixup.dat/config.txt left untouched."
echo "Safe to remove the card and insert it in the powered-off Pi."

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
