#!/usr/bin/env bash
# Dhruva Phase 0+1 build: boot.S + context_switch.S + kernel_main.vani ->
# dhruva.elf, bootable under `qemu-system-arm -M raspi1ap` with zero
# physical hardware.
#
# Pipeline, and why each step is shaped this way:
#   1. Assemble boot.S natively with arm-none-eabi-gcc.
#   2. Emit kernel_main.vani as LLVM IR (vanic's C --no-std emission has
#      an unrelated bug -- unconditionally includes <pthread.h>/<sched.h>
#      even in no-std mode -- so the LLVM path is used instead).
#   3. Lower to an ARM object file with -function-sections/-data-sections:
#      vani's LLVM emission always includes its entire builtin-runtime
#      helper library (string/math/threading functions) regardless of
#      whether the program actually calls them, and plain GlobalDCE won't
#      prune them since they carry external linkage on purpose (for
#      cross-module linking). Per-function sections let the *linker*
#      prune by real reachability from _start instead.
#   4. Link with --gc-sections against the custom linker script, which
#      also discards .ARM.exidx/.ARM.extab (C++ exception-unwind tables
#      neither boot.S nor kernel_main.vani need, but that pull in an
#      unresolvable personality-routine symbol if left in).
#   5. runtime_stubs.o supplies strlen/dprintf/exit -- vani's own
#      generated runtime support code assumes a hosted libc provides
#      these (str_len_bytes() calls strlen(); the compiler-inserted
#      bounds-check panic path calls dprintf()+exit()), so any bare-metal
#      vani program needs them from somewhere.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${ROOT}/build"
VANIC="${VANIC:-/home/virgo/source/vani-compiler/target/release/vanic}"
CPU="arm1176jzf-s"
TRIPLE="armv6-none-eabi"

mkdir -p "${BUILD_DIR}"

arm-none-eabi-gcc -c -mcpu="${CPU}" -marm \
  "${ROOT}/boot/rpi1/boot.S" -o "${BUILD_DIR}/boot.o"

arm-none-eabi-gcc -c -mcpu="${CPU}" -marm \
  "${ROOT}/boot/context_switch.S" -o "${BUILD_DIR}/context_switch.o"

arm-none-eabi-gcc -c -mcpu="${CPU}" -marm \
  "${ROOT}/boot/irq_entry.S" -o "${BUILD_DIR}/irq_entry.o"

arm-none-eabi-gcc -c -mcpu="${CPU}" -marm \
  "${ROOT}/boot/rpi1/vectors.S" -o "${BUILD_DIR}/vectors.o"

arm-none-eabi-gcc -c -mcpu="${CPU}" -marm \
  "${ROOT}/boot/sdcard_state.S" -o "${BUILD_DIR}/sdcard_state.o"

arm-none-eabi-gcc -c -mcpu="${CPU}" -marm \
  "${ROOT}/boot/fs_buf.S" -o "${BUILD_DIR}/fs_buf.o"

arm-none-eabi-gcc -c -mcpu="${CPU}" -marm \
  "${ROOT}/boot/fs_state.S" -o "${BUILD_DIR}/fs_state.o"

arm-none-eabi-gcc -c -mcpu="${CPU}" -marm -nostdlib -ffreestanding \
  "${ROOT}/boot/rpi1/runtime_stubs.c" -o "${BUILD_DIR}/runtime_stubs.o"

"${VANIC}" emit "${ROOT}/kernel/kernel_main.vani" --backend=llvm \
  -o "${BUILD_DIR}/kernel_main.ll"

llc -mtriple="${TRIPLE}" -mcpu="${CPU}" -filetype=obj \
  -function-sections -data-sections \
  "${BUILD_DIR}/kernel_main.ll" -o "${BUILD_DIR}/kernel_main.o"

arm-none-eabi-gcc -nostdlib -ffreestanding \
  -Wl,--gc-sections -Wl,-T,"${ROOT}/boot/rpi1/link.ld" \
  "${BUILD_DIR}/boot.o" "${BUILD_DIR}/context_switch.o" \
  "${BUILD_DIR}/irq_entry.o" "${BUILD_DIR}/vectors.o" \
  "${BUILD_DIR}/sdcard_state.o" "${BUILD_DIR}/fs_buf.o" \
  "${BUILD_DIR}/fs_state.o" \
  "${BUILD_DIR}/kernel_main.o" "${BUILD_DIR}/runtime_stubs.o" \
  -o "${BUILD_DIR}/dhruva.elf"

echo "Built ${BUILD_DIR}/dhruva.elf"
echo "Run under QEMU: python3 ${ROOT}/test/qemu_run.py ${BUILD_DIR}/dhruva.elf"
