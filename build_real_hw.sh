#!/usr/bin/env bash
# Builds BOTH the kernel and stage0 for a real-hardware deployment,
# with every real-HW safety flag set TOGETHER, in one command.
#
# 2026-11-09 (real-HW board-hang incident): a real board hung at
# stage0 with no watchdog armed and no serial shell to recover it,
# requiring a physical power cycle -- root cause was a PROCESS gap,
# not a code gap. The watchdog mechanism itself (stage0_arm_watchdog,
# 15s timeout) has existed for a long time; it just wasn't compiled
# into the binary actually on the card, because enabling it requires
# a SEPARATE build invocation (build_stage0.sh's own STAGE0_CFLAGS)
# from the kernel-side flags (build.sh / kernel_main.vani's own
# WATCHDOG_ENABLE_FOR_REAL_HARDWARE / STAGE0_PREJUMP_WATCHDOG_DISARM_
# FOR_REAL_HARDWARE) -- two independent build systems, each with its
# own real-hardware safety flag, nothing ever forcing them to be set
# together. This whole session's own manual sed-the-vani-consts-then-
# build.sh-then-revert routine never once also rebuilt stage0 with its
# matching flag -- an easy, silent, repeatable mistake this script
# exists specifically to make structurally impossible going forward:
# there is now exactly one command for "build for real hardware," and
# it cannot build one half without the other.
#
# Usage: ./build_real_hw.sh
#
# Produces:
#   build/dhruva_real_hw.img  -- kernel image for the A/B kernel-slot
#                                 serial upload path (test/kernel_upload.py)
#   build/stage0.img          -- stage0 for the FAT32 boot partition
#                                 (./update_stage0.sh /dev/sdX -- needs
#                                 physical SD card access, NOT reachable
#                                 over the serial kernel-slot path at all)
#   build/dhruva.elf          -- left rebuilt at the checked-in-default
#                                 (non-real-HW) flag values afterward, so
#                                 the working tree's own build artifact
#                                 state matches a plain ./build.sh run --
#                                 only the *_real_hw.img copy carries the
#                                 real-HW flags.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

VANI_FILE="kernel/kernel_main.vani"
WD_PATTERN="const WATCHDOG_ENABLE_FOR_REAL_HARDWARE: i64 = "
DISARM_PATTERN="const STAGE0_PREJUMP_WATCHDOG_DISARM_FOR_REAL_HARDWARE: i64 = "

require_one_match() {
    local pattern="$1"
    local count
    count=$(grep -c "^${pattern}" "$VANI_FILE")
    if [ "$count" -ne 1 ]; then
        echo "ERROR: expected exactly 1 occurrence of '${pattern}...' in $VANI_FILE, found $count." >&2
        echo "Refusing to proceed -- the sed below would either do nothing or touch the wrong line." >&2
        exit 1
    fi
}

set_flag() {
    local pattern="$1"
    local value="$2"
    sed -i "s/^${pattern}[01];\$/${pattern}${value};/" "$VANI_FILE"
}

echo "=== Verifying both real-HW flags are present exactly once (not renamed/moved) ==="
require_one_match "$WD_PATTERN"
require_one_match "$DISARM_PATTERN"

echo "=== Building kernel with real-HW flags ON ==="
set_flag "$WD_PATTERN" 1
set_flag "$DISARM_PATTERN" 1
grep -n "^${WD_PATTERN}\|^${DISARM_PATTERN}" "$VANI_FILE"

rm -f build/dhruva.elf
./build.sh
arm-none-eabi-objcopy -O binary build/dhruva.elf build/dhruva_real_hw.img
echo "Built build/dhruva_real_hw.img: $(sha256sum build/dhruva_real_hw.img)"

echo "=== Reverting kernel real-HW flags to checked-in default (0), rebuilding normal variant ==="
set_flag "$WD_PATTERN" 0
set_flag "$DISARM_PATTERN" 0
grep -n "^${WD_PATTERN}\|^${DISARM_PATTERN}" "$VANI_FILE"
rm -f build/dhruva.elf
./build.sh

echo "=== Building stage0 with its own real-HW watchdog ON (the flag this incident found missing) ==="
STAGE0_CFLAGS="-DSTAGE0_PREJUMP_WATCHDOG_FOR_REAL_HARDWARE=1" ./build_stage0.sh
echo "Built build/stage0.img (watchdog ON): $(sha256sum build/stage0.img)"

echo
echo "=== Done. Deploy: ==="
echo "  Kernel (over serial, A/B slot): test/kernel_upload.py ... build/dhruva_real_hw.img"
echo "  Stage0 (needs physical SD card access): ./update_stage0.sh /dev/sdX"
