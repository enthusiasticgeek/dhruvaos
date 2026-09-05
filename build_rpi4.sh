#!/usr/bin/env bash
# Dhruva round 43 -- Raspberry Pi 4 (BCM2711) AArch64 boot skeleton
# build: boot.S + vectors.S -> dhruva_rpi4.elf, bootable under
# `qemu-system-aarch64 -M raspi4b` with zero physical hardware.
#
# Deliberately a SEPARATE script from build.sh, not a flag on it: this
# targets a completely different instruction set (AArch64 vs. this
# project's exclusively-ARM32-until-now Pi 1 target), a different
# cross-compiler triple, and -- for now -- pure hand-written assembly
# with no vani-compiled kernel code at all (see boot/rpi4/boot.S's own
# header comment for why that's this round's deliberate v1 scope, not
# an oversight). Merging the two build paths into one script would
# buy nothing but a pile of target-specific conditionals; keeping them
# separate mirrors how cleanly the two targets' actual toolchains
# don't share anything below the shell script calling them.
#
# Toolchain note: no dedicated aarch64-none-elf-gcc is installed on
# this machine, but aarch64-linux-gnu-gcc (already installed, ordinarily
# a hosted-Linux cross-compiler) works fine for freestanding bare-metal
# output given -nostdlib -ffreestanding -- the "linux-gnu" in the
# triple only affects default include/library search paths and default
# libc linking, both of which are already avoided here regardless. This
# is the same CROSS_CC-style substitution docs/PORTING.md's round-40
# research section already flagged as viable for vani-compiler's own
# --target= pipeline, applied directly here since this round's kernel
# is hand-written assembly, not vani-compiled.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${ROOT}/build"
CC="${AARCH64_CC:-aarch64-linux-gnu-gcc}"

mkdir -p "${BUILD_DIR}"

"${CC}" -c -mgeneral-regs-only -ffreestanding \
  "${ROOT}/boot/rpi4/boot.S" -o "${BUILD_DIR}/rpi4_boot.o"

"${CC}" -c -mgeneral-regs-only -ffreestanding \
  "${ROOT}/boot/rpi4/vectors.S" -o "${BUILD_DIR}/rpi4_vectors.o"

"${CC}" -c -mgeneral-regs-only -ffreestanding \
  "${ROOT}/boot/rpi4/gic_timer.S" -o "${BUILD_DIR}/rpi4_gic_timer.o"

"${CC}" -nostdlib -ffreestanding -static \
  -Wl,-T,"${ROOT}/boot/rpi4/link.ld" \
  "${BUILD_DIR}/rpi4_boot.o" "${BUILD_DIR}/rpi4_vectors.o" \
  "${BUILD_DIR}/rpi4_gic_timer.o" \
  -o "${BUILD_DIR}/dhruva_rpi4.elf"

echo "Built ${BUILD_DIR}/dhruva_rpi4.elf"
echo "Run under QEMU: python3 ${ROOT}/test/rpi4_boot_smoke.py ${BUILD_DIR}/dhruva_rpi4.elf"
