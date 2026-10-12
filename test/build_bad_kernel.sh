#!/usr/bin/env bash
# Task #308 Phase 6: builds the deliberately-broken "bad kernel" used
# to drill the A/B auto-revert path -- a candidate that stage0 will
# happily chain-load (correct checksum, correct length, marked ready)
# but which never reaches "PASS" because its own boot_entry does
# nothing but branch to itself forever. See boot/badkernel/bad_entry.S
# and the plan this came from for why this exact shape of failure is
# the one worth drilling (not a crash a fault handler could catch --
# a kernel that "boots" by stage0's own measure but is useless).
#
# Independent of build.sh/vanic, same reasoning as build_stage0.sh:
# no vani dependency, no need to touch the real kernel build at all.
#
# Usage: ./test/build_bad_kernel.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/build"
CPU="arm1176jzf-s"

mkdir -p "$BUILD_DIR"

arm-none-eabi-gcc -c -mcpu="${CPU}" -marm \
  "${ROOT}/boot/badkernel/bad_entry.S" -o "${BUILD_DIR}/bad_entry.o"

arm-none-eabi-gcc -nostdlib -ffreestanding \
  -Wl,--gc-sections -Wl,-T,"${ROOT}/boot/badkernel/link.ld" \
  "${BUILD_DIR}/bad_entry.o" \
  -o "${BUILD_DIR}/bad_kernel.elf"

arm-none-eabi-objcopy -O binary "${BUILD_DIR}/bad_kernel.elf" "${BUILD_DIR}/bad_kernel.img"

echo "Built ${BUILD_DIR}/bad_kernel.elf / ${BUILD_DIR}/bad_kernel.img"
echo "Size: $(stat -c%s "${BUILD_DIR}/bad_kernel.img") bytes"
