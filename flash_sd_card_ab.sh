#!/usr/bin/env bash
# One-command full A/B card setup for a BRAND NEW card: wraps
# flash_sd_card.sh (partition + stage0 + slot A, with its own full
# destructive-action confirmations -- device typed twice, then YES)
# and then seeds slot B with a second kernel image in the same run.
# Minimizes typing for the common "fresh card, also want to test a
# candidate kernel in slot B" workflow -- one command instead of two
# separate invocations with a manual wait in between.
#
# Usage:
#   ./flash_sd_card_ab.sh /dev/sdX /path/to/firmware/dir /path/to/slot_b_kernel.img [extra flash_sd_card.sh flags]
#
# firmware-dir must contain bootcode.bin, start.elf, fixup.dat (see
# flash_sd_card.sh's own header comment / docs/HARDWARE_IN_LOOP.md
# §4.1). slot-b-kernel-image is a flat kernel binary, e.g.
# build/dhruva_dma_test.img. Any extra flags (--with-wifi-firmware,
# --with-wifi-creds) are passed straight through to flash_sd_card.sh.
#
# Result: slot A = the known-good build/dhruva.elf this run built
# with (the proven, flag-off kernel), slot B = your candidate image,
# active_slot=B so the board boots the candidate first and
# auto-falls-back to slot A if it doesn't reach PASS within
# bootlimit attempts -- same safety net every real-HW test this
# project runs already relies on.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$#" -lt 3 ]; then
    echo "Usage: $0 <device, e.g. /dev/sdX> <firmware-dir> <slot-b-kernel-image> [extra flash_sd_card.sh flags]" >&2
    echo "  firmware-dir must contain bootcode.bin, start.elf, fixup.dat" >&2
    echo "  slot-b-kernel-image is a flat kernel binary (e.g. build/dhruva_dma_test.img)" >&2
    exit 1
fi

DEVICE="$1"
FW_DIR="$2"
SLOT_B_IMG="$3"
shift 3
EXTRA_FLAGS=("$@")

if [ ! -f "$SLOT_B_IMG" ]; then
    echo "ERROR: $SLOT_B_IMG not found." >&2
    exit 1
fi

echo "=== Step 1/2: full card setup (partition, stage0, slot A) ==="
# flash_sd_card.sh owns every destructive-action confirmation itself
# (lsblk review, device-typed-twice, then a separate YES prompt) --
# deliberately not duplicated or bypassed here.
"$ROOT/flash_sd_card.sh" "$DEVICE" "$FW_DIR" "${EXTRA_FLAGS[@]}"

echo
echo "=== Step 2/2: seeding slot B with $SLOT_B_IMG ==="
sudo python3 "$ROOT/test/kernel_slot_layout.py" "$DEVICE" --device seed "$SLOT_B_IMG" --slot b

echo
echo "Done. Slot A = known-good fallback (build/dhruva.elf), slot B = $SLOT_B_IMG."
echo "Power on the board and watch ~/dhruva_uart.log."
