#!/usr/bin/env bash
# Builds BOTH the kernel and stage0 for a real-hardware deployment.
#
# 2026-11-09 (real-HW board-hang incident): a real board hung at
# stage0 with no watchdog armed and no serial shell to recover it,
# requiring a physical power cycle -- root cause was a PROCESS gap,
# not a code gap. Enabling the watchdog used to require a SEPARATE
# build invocation per binary (build_stage0.sh's own STAGE0_CFLAGS,
# plus build.sh's own kernel_main.vani consts) -- two independent
# build systems, each with its own manually-tracked real-hardware
# flag, nothing ever forcing them to be set together. This script was
# originally written to make that "build one half without the other"
# mistake structurally impossible by sed-patching both source trees,
# building, then reverting -- and it still happened anyway, later the
# same investigation: a kernel fix got verified with a plain
# ./build.sh and the stale pre-fix real-HW image got flashed and
# tested instead of this script's own output, because re-running this
# script was the one step that had to be remembered by hand.
#
# REVISED 2026-11-21 (user: "it should auto detect qemu or real hw...
# so you dont have to track manually"): both binaries now detect real
# hardware vs QEMU themselves, at runtime, via a VideoCore mailbox
# GET_FIRMWARE_REVISION probe (kernel_main.vani's hardware_is_real_hw_
# get(), boot/hwdetect_state.S; stage0_main.c's own matching
# stage0_detect_real_hardware()) -- see either call site's own header
# comment for the full detection mechanism, verified against QEMU's
# real source rather than guessed, and its explicit fail-safe-to-0
# (treat as QEMU/unknown, watchdog off) default on any doubt. There is
# no longer a second set of source constants to patch: a plain
# ./build.sh + ./build_stage0.sh now produces the SAME single binary
# pair that self-configures correctly on either target. This script
# now just runs that normal build and reports the same artifact paths
# it always has, so existing deploy habits/docs that invoke it by name
# keep working -- it does not patch, revert, or rebuild anything twice
# anymore.
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
#   build/dhruva.elf          -- the same kernel build dhruva_real_hw.img
#                                 was objcopied from; also what QEMU runs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

echo "=== Building kernel ==="
./build.sh
arm-none-eabi-objcopy -O binary build/dhruva.elf build/dhruva_real_hw.img
echo "Built build/dhruva_real_hw.img: $(sha256sum build/dhruva_real_hw.img)"

echo "=== Building stage0 ==="
./build_stage0.sh
echo "Built build/stage0.img: $(sha256sum build/stage0.img)"

echo
echo "=== Done. Deploy: ==="
echo "  Kernel (over serial, A/B slot): test/kernel_upload.py ... build/dhruva_real_hw.img"
echo "  Stage0 (needs physical SD card access): ./update_stage0.sh /dev/sdX"
