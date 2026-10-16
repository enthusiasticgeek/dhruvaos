#!/usr/bin/env bash
# One-shot deploy of task #353's real-hardware watchdog safety net:
# builds stage0 with its pre-jump watchdog armed
# (STAGE0_PREJUMP_WATCHDOG_FOR_REAL_HARDWARE=1), builds the real
# kernel with its own matching watchdog enabled
# (WATCHDOG_ENABLE_FOR_REAL_HARDWARE=1,
# STAGE0_PREJUMP_WATCHDOG_DISARM_FOR_REAL_HARDWARE=1), then runs
# update_kernel.sh (non-destructive stage0.img swap) and
# test/kernel_slot_layout.py's seed command (writes the watchdog-
# enabled kernel into slot A with a fresh generation-1 slot-state
# record) -- the exact three steps from docs/TODO.md's own task #353
# deployment plan, combined so nothing has to be typed or remembered
# by hand.
#
# Usage: ./deploy_realhw_watchdog.sh [/dev/sdX]
#   Defaults to /dev/sdb (this project's own reader device this
#   session). Card must already be a first-time-flashed Dhruva card
#   (flash_sd_card.sh already run on it once) -- same precondition
#   update_kernel.sh itself already checks for.
#
# vani has no preprocessor, so kernel_main.vani's two watchdog
# constants need a real (scripted, not hand-tracked) temporary edit-
# build-revert cycle -- the revert is a trap on EXIT, so the working
# tree always ends up back at its checked-in flags=0 state, even if
# a step fails partway through.
#
# Needs sudo for update_kernel.sh's own mount/cp and for
# kernel_slot_layout.py's raw block-device open (confirmed this
# session: /dev/sdb is root:disk 0660, and this user isn't in the
# disk group) -- prompts interactively, never stores a password.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVICE="${1:-/dev/sdb}"
KMAIN="$ROOT/kernel/kernel_main.vani"

if [ ! -b "$DEVICE" ]; then
    echo "ERROR: $DEVICE is not a block device. Usage: $0 [/dev/sdX]" >&2
    exit 1
fi

cleanup() {
    echo "=== Restoring kernel_main.vani's watchdog flags to their checked-in 0 ==="
    sed -i 's/^const WATCHDOG_ENABLE_FOR_REAL_HARDWARE: i64 = 1;/const WATCHDOG_ENABLE_FOR_REAL_HARDWARE: i64 = 0;/' "$KMAIN"
    sed -i 's/^const STAGE0_PREJUMP_WATCHDOG_DISARM_FOR_REAL_HARDWARE: i64 = 1;/const STAGE0_PREJUMP_WATCHDOG_DISARM_FOR_REAL_HARDWARE: i64 = 0;/' "$KMAIN"
    if ! git -C "$ROOT" diff --quiet -- "$KMAIN"; then
        echo "WARNING: kernel_main.vani still shows a diff after revert -- check by hand:" >&2
        git -C "$ROOT" diff -- "$KMAIN" >&2
    fi
}
trap cleanup EXIT

echo "=== Step 1/4: building stage0 with the pre-jump watchdog armed ==="
STAGE0_CFLAGS="-DSTAGE0_PREJUMP_WATCHDOG_FOR_REAL_HARDWARE=1" "$ROOT/build_stage0.sh"
cp "$ROOT/build/stage0.img" "$ROOT/build/stage0_realhw.img"
cp "$ROOT/build/stage0.elf" "$ROOT/build/stage0_realhw.elf"
# Rebuild the normal (flags=0) variant right away so build/stage0.img
# isn't left looking like the real-hw one if this script stops here.
"$ROOT/build_stage0.sh"

echo "=== Step 2/4: building the real kernel with its own watchdog enabled ==="
sed -i 's/^const WATCHDOG_ENABLE_FOR_REAL_HARDWARE: i64 = 0;/const WATCHDOG_ENABLE_FOR_REAL_HARDWARE: i64 = 1;/' "$KMAIN"
sed -i 's/^const STAGE0_PREJUMP_WATCHDOG_DISARM_FOR_REAL_HARDWARE: i64 = 0;/const STAGE0_PREJUMP_WATCHDOG_DISARM_FOR_REAL_HARDWARE: i64 = 1;/' "$KMAIN"
rm -f "$ROOT/build/dhruva.elf"
"$ROOT/build.sh"
arm-none-eabi-objcopy -O binary "$ROOT/build/dhruva.elf" "$ROOT/build/dhruva_real_hw.img"
rm -f "$ROOT/build/dhruva.elf"
# cleanup trap reverts kernel_main.vani on exit; rebuild the normal
# artifact now too so build/dhruva.elf matches flags=0 again before
# this script returns control.
trap 'cleanup; "$ROOT/build.sh" >/dev/null' EXIT

echo "=== Step 3/4: update_kernel.sh -- stage0.img swap on $DEVICE (sudo) ==="
sudo -v
cp "$ROOT/build/stage0_realhw.elf" "$ROOT/build/stage0.elf"
"$ROOT/update_kernel.sh" "$DEVICE"
"$ROOT/build_stage0.sh" >/dev/null   # restore build/stage0.elf to flags=0 too

echo "=== Step 4/4: seeding slot A with the watchdog-enabled kernel (sudo) ==="
sudo python3 "$ROOT/test/kernel_slot_layout.py" "$DEVICE" --device seed "$ROOT/build/dhruva_real_hw.img"

echo
echo "=== Done. Watchdog-enabled stage0 + kernel deployed to $DEVICE. ==="
echo "Safe to remove the card and insert it in the powered-off Pi."
