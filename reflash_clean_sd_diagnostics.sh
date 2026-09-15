#!/usr/bin/env bash
# One-time helper for the 2026-09-15 real-hardware SD-reliability
# investigation: does a NORMAL full reflash (flash_sd_card.sh) AND
# additionally zeroes the raw DharaFS/crypto-metadata region the FAT32
# partition never touches, so the next boot's own self-tests
# (DharaFS multi-block/compact/permissions/directory-hierarchy, DharaFS
# AEAD/two-time-pad/tamper/media-encryption, the SD 8-block sweep)
# start from a genuinely clean slate -- not just a fresh kernel.img on
# top of whatever real, possibly-corrupted DharaFS log data this card
# has already accumulated across many prior real-hardware test boots.
#
# WHY this extra step, beyond what flash_sd_card.sh already does:
# flash_sd_card.sh (and update_kernel.sh) only ever touch the FAT32
# boot partition (starting at sector 16384, per docs/HARDWARE_IN_
# LOOP.md's own partitioning). DharaFS's own log region (blocks
# 1-2048), this project's crypto-metadata region (blocks 4000+), and
# the SD self-test's own scratch blocks all live OUTSIDE that
# partition, in the 8MiB gap `flash_sd_card.sh` deliberately leaves
# unpartitioned -- neither `parted mklabel`/`mkpart` nor `mkfs.vfat`
# ever erases that gap's own existing content. A `parted`/`mkfs.vfat`
# reflash alone would leave any real, previously-written DharaFS data
# in that gap completely untouched.
#
# This matters for this specific investigation because one identified,
# fixed risk was the SD self-test's own OLD block range (2040-2047)
# sitting close enough to DharaFS's own declared 2048-block ceiling
# that real, accumulated log growth across many boots could plausibly
# have reached it -- if that already happened on THIS card before this
# fix landed, the corruption is still sitting there in blocks 2040-2047
# regardless of how many times kernel.img alone gets replaced. Zeroing
# the whole gap removes that specific variable from the next boot's own
# results, so a still-failing self-test after this reflash points
# cleanly at a genuine remaining code bug, not leftover damage from a
# no-longer-used unsafe block range.
#
# Usage:
#   ./reflash_clean_sd_diagnostics.sh /dev/sdX /path/to/firmware/dir
#
# Same firmware-dir requirement as flash_sd_card.sh (bootcode.bin,
# start.elf, fixup.dat -- see docs/HARDWARE_IN_LOOP.md §4.1).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Covers DharaFS's own log region (1-2048), this project's crypto-
# metadata region (4000 + up to 128 sectors for every block DharaFS's
# own ceiling could ever address, comfortably rounded up), and the SD
# self-test's own OLD (2040-2047) and NEW (2100-2107) scratch ranges,
# with real margin on top -- 4300 blocks * 512 bytes = ~2.1MB, still
# tiny against an 8MiB gap and a multi-GB card, a few seconds of `dd`
# at worst.
ZERO_BLOCK_COUNT=4300

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

echo "=== Target device details (VERIFY this is your SD card, not a disk you care about) ==="
lsblk "$DEVICE"
echo
echo "This will COMPLETELY ERASE $DEVICE (partition table + boot files,"
echo "same as flash_sd_card.sh) AND additionally zero the first"
echo "$ZERO_BLOCK_COUNT blocks (DharaFS's own log/crypto-metadata region,"
echo "outside the FAT32 partition -- a normal reflash alone never"
echo "touches this)."
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

echo "=== Zeroing the first $ZERO_BLOCK_COUNT blocks (DharaFS log + crypto-metadata region) ==="
sudo dd if=/dev/zero of="$DEVICE" bs=512 count="$ZERO_BLOCK_COUNT" conv=fsync status=progress

echo
echo "=== Running the normal full reflash (flash_sd_card.sh) ==="
# flash_sd_card.sh has its own two confirmation prompts too -- expected,
# not a bug in this wrapper; type the same answers again.
"$ROOT/flash_sd_card.sh" "$DEVICE" "$FW_DIR"

echo
echo "=== Done. Clean DharaFS region + fresh kernel.img written. ==="
echo "Safe to remove the card and insert it in the powered-off Pi."
