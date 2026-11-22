#!/usr/bin/env bash
# Rebuilds stage0 + the real kernel and pushes them to an already-
# flashed Dhruva SD card (stage0.img swap + seed kernel slot A) --
# the update-only path, not a full first-time flash (see
# flash_sd_card.sh for that).
#
# Originally written (task #353) specifically to deploy the real-
# hardware watchdog safety net, back when enabling it required a
# separate sed-patch-build-revert cycle on kernel_main.vani's own
# consts that was easy to forget. REVISED 2026-11-21 (user: "auto
# detect qemu or real hw... so you dont have to track manually"):
# both stage0 and the kernel now detect real hardware vs QEMU
# themselves at runtime (kernel_main.vani's hardware_is_real_hw_get(),
# boot/hwdetect_state.S; stage0_main.c's own matching stage0_detect_
# real_hardware() -- see either call site's own comment for the
# verified detection mechanism), so there is no separate "watchdog
# build" anymore -- a plain build already has it, on either binary,
# automatically. This script keeps its name (existing muscle memory)
# but is now just "rebuild and push the latest stage0+kernel to an
# already-flashed card" -- the three steps from docs/TODO.md's own
# task #353 deployment plan, minus the flag-patching that's no longer
# needed.
#
# Usage: ./deploy_realhw_watchdog.sh [/dev/sdX]
#   Defaults to /dev/sdb (this project's own reader device this
#   session). Card must already be a first-time-flashed Dhruva card
#   (flash_sd_card.sh already run on it once) -- same precondition
#   update_stage0.sh itself already checks for.
#
# Needs sudo for update_stage0.sh's own mount/cp and for
# kernel_slot_layout.py's raw block-device open (confirmed this
# session: /dev/sdb is root:disk 0660, and this user isn't in the
# disk group) -- prompts interactively, never stores a password.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVICE="${1:-/dev/sdb}"

if [ ! -b "$DEVICE" ]; then
    echo "ERROR: $DEVICE is not a block device. Usage: $0 [/dev/sdX]" >&2
    exit 1
fi

echo "=== Step 1/3: building stage0 and the real kernel ==="
"$ROOT/build_stage0.sh"
"$ROOT/build.sh"
arm-none-eabi-objcopy -O binary "$ROOT/build/dhruva.elf" "$ROOT/build/dhruva_real_hw.img"

echo "=== Step 2/3: update_stage0.sh -- stage0.img swap on $DEVICE (sudo) ==="
sudo -v
"$ROOT/update_stage0.sh" "$DEVICE"

echo "=== Step 3/3: seeding slot A with the freshly-built kernel (sudo) ==="
sudo python3 "$ROOT/test/kernel_slot_layout.py" "$DEVICE" --device seed "$ROOT/build/dhruva_real_hw.img"

echo
echo "=== Done. stage0 + kernel deployed to $DEVICE. ==="
echo "Safe to remove the card and insert it in the powered-off Pi."
