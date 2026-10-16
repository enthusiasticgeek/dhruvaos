#!/usr/bin/env bash
# Builds the A/B kernel-slot stage-0 loader (boot/stage0/) -- completely
# independent of build.sh/vanic: stage-0 has no vani dependency at all,
# so it gets its own tiny, fast build pipeline that never needs the
# (slow, llc -O1) real kernel rebuilt just to iterate on this.
#
# Usage: ./build_stage0.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$ROOT/build"
CPU="arm1176jzf-s"

# Task #353 follow-up (2026-10-15): optional -D override for stage0_main.c's
# own STAGE0_PREJUMP_WATCHDOG_FOR_REAL_HARDWARE gate (checked-in default 0).
# Example real-hardware deployment build:
#   STAGE0_CFLAGS="-DSTAGE0_PREJUMP_WATCHDOG_FOR_REAL_HARDWARE=1" ./build_stage0.sh
STAGE0_CFLAGS="${STAGE0_CFLAGS:-}"

mkdir -p "$BUILD_DIR"

arm-none-eabi-gcc -c -mcpu="${CPU}" -marm \
  "${ROOT}/boot/stage0/stage0_entry.S" -o "${BUILD_DIR}/stage0_entry.o"

arm-none-eabi-gcc -c -mcpu="${CPU}" -marm -nostdlib -ffreestanding -O1 \
  "${ROOT}/boot/stage0/sdread.c" -o "${BUILD_DIR}/stage0_sdread.o"

arm-none-eabi-gcc -c -mcpu="${CPU}" -marm -nostdlib -ffreestanding -O1 ${STAGE0_CFLAGS} \
  "${ROOT}/boot/stage0/stage0_main.c" -o "${BUILD_DIR}/stage0_main.o"

arm-none-eabi-gcc -c -mcpu="${CPU}" -marm -nostdlib -ffreestanding -O1 \
  "${ROOT}/boot/stage0/sha256.c" -o "${BUILD_DIR}/stage0_sha256.o"

arm-none-eabi-gcc -nostdlib -ffreestanding \
  -Wl,--gc-sections -Wl,-T,"${ROOT}/boot/stage0/link.ld" \
  "${BUILD_DIR}/stage0_entry.o" "${BUILD_DIR}/stage0_sdread.o" "${BUILD_DIR}/stage0_main.o" \
  "${BUILD_DIR}/stage0_sha256.o" \
  -lgcc \
  -o "${BUILD_DIR}/stage0.elf"

arm-none-eabi-objcopy -O binary "${BUILD_DIR}/stage0.elf" "${BUILD_DIR}/stage0.img"

echo "Built ${BUILD_DIR}/stage0.elf / ${BUILD_DIR}/stage0.img"
echo "Size: $(stat -c%s "${BUILD_DIR}/stage0.img") bytes"
