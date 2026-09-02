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
#   6. -lgcc at link time -- ARMv6 (arm1176jzf-s) has no hardware
#      integer-divide instruction, so any `/` on an i64 (first needed by
#      Phase 4 task #10's expression evaluator; nothing before it ever
#      divided) compiles down to a call to `__aeabi_ldivmod`. That's a
#      *compiler support* routine, not part of libc -- arm-none-eabi's
#      own libgcc.a supplies it and is safe to link into a freestanding
#      build (no OS/libc dependencies of its own), unlike pulling in a
#      real libc would be.
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
  "${ROOT}/boot/mmu_init.S" -o "${BUILD_DIR}/mmu_init.o"

arm-none-eabi-gcc -c -mcpu="${CPU}" -marm \
  "${ROOT}/boot/context_switch.S" -o "${BUILD_DIR}/context_switch.o"

arm-none-eabi-gcc -c -mcpu="${CPU}" -marm \
  "${ROOT}/boot/irq_entry.S" -o "${BUILD_DIR}/irq_entry.o"

arm-none-eabi-gcc -c -mcpu="${CPU}" -marm \
  "${ROOT}/boot/rpi1/vectors.S" -o "${BUILD_DIR}/vectors.o"

arm-none-eabi-gcc -c -mcpu="${CPU}" -marm \
  "${ROOT}/boot/sdcard_state.S" -o "${BUILD_DIR}/sdcard_state.o"

arm-none-eabi-gcc -c -mcpu="${CPU}" -marm \
  "${ROOT}/boot/dharafs_buf.S" -o "${BUILD_DIR}/dharafs_buf.o"

arm-none-eabi-gcc -c -mcpu="${CPU}" -marm \
  "${ROOT}/boot/dharafs_state.S" -o "${BUILD_DIR}/dharafs_state.o"

arm-none-eabi-gcc -c -mcpu="${CPU}" -marm \
  "${ROOT}/boot/shell_state.S" -o "${BUILD_DIR}/shell_state.o"

arm-none-eabi-gcc -c -mcpu="${CPU}" -marm \
  "${ROOT}/boot/governor_state.S" -o "${BUILD_DIR}/governor_state.o"

arm-none-eabi-gcc -c -mcpu="${CPU}" -marm \
  "${ROOT}/boot/netif_state.S" -o "${BUILD_DIR}/netif_state.o"

arm-none-eabi-gcc -c -mcpu="${CPU}" -marm \
  "${ROOT}/boot/arp_state.S" -o "${BUILD_DIR}/arp_state.o"

arm-none-eabi-gcc -c -mcpu="${CPU}" -marm \
  "${ROOT}/boot/scratch_state.S" -o "${BUILD_DIR}/scratch_state.o"

arm-none-eabi-gcc -c -mcpu="${CPU}" -marm \
  "${ROOT}/boot/tcp_state.S" -o "${BUILD_DIR}/tcp_state.o"

arm-none-eabi-gcc -c -mcpu="${CPU}" -marm \
  "${ROOT}/boot/dhcp_state.S" -o "${BUILD_DIR}/dhcp_state.o"

arm-none-eabi-gcc -c -mcpu="${CPU}" -marm \
  "${ROOT}/boot/usb_msd_state.S" -o "${BUILD_DIR}/usb_msd_state.o"

arm-none-eabi-gcc -c -mcpu="${CPU}" -marm \
  "${ROOT}/boot/usb_net_state.S" -o "${BUILD_DIR}/usb_net_state.o"

arm-none-eabi-gcc -c -mcpu="${CPU}" -marm \
  "${ROOT}/boot/usb_bt_state.S" -o "${BUILD_DIR}/usb_bt_state.o"

arm-none-eabi-gcc -c -mcpu="${CPU}" -marm \
  "${ROOT}/boot/usb_wifi_state.S" -o "${BUILD_DIR}/usb_wifi_state.o"

arm-none-eabi-gcc -c -mcpu="${CPU}" -marm \
  "${ROOT}/boot/fw_state.S" -o "${BUILD_DIR}/fw_state.o"

arm-none-eabi-gcc -c -mcpu="${CPU}" -marm \
  "${ROOT}/boot/auth_state.S" -o "${BUILD_DIR}/auth_state.o"

arm-none-eabi-gcc -c -mcpu="${CPU}" -marm \
  "${ROOT}/boot/media_crypto_state.S" -o "${BUILD_DIR}/media_crypto_state.o"

arm-none-eabi-gcc -c -mcpu="${CPU}" -marm \
  "${ROOT}/boot/fault_inject_state.S" -o "${BUILD_DIR}/fault_inject_state.o"

arm-none-eabi-gcc -c -mcpu="${CPU}" -marm \
  "${ROOT}/boot/diag_ring_state.S" -o "${BUILD_DIR}/diag_ring_state.o"

arm-none-eabi-gcc -c -mcpu="${CPU}" -marm \
  "${ROOT}/boot/gatt_state.S" -o "${BUILD_DIR}/gatt_state.o"

arm-none-eabi-gcc -c -mcpu="${CPU}" -marm -nostdlib -ffreestanding \
  "${ROOT}/boot/rpi1/runtime_stubs.c" -o "${BUILD_DIR}/runtime_stubs.o"

"${VANIC}" emit "${ROOT}/kernel/kernel_main.vani" --backend=llvm \
  -o "${BUILD_DIR}/kernel_main.ll"

llc -mtriple="${TRIPLE}" -mcpu="${CPU}" -filetype=obj \
  -function-sections -data-sections \
  "${BUILD_DIR}/kernel_main.ll" -o "${BUILD_DIR}/kernel_main.o"

arm-none-eabi-gcc -nostdlib -ffreestanding \
  -Wl,--gc-sections -Wl,-T,"${ROOT}/boot/rpi1/link.ld" \
  "${BUILD_DIR}/boot.o" "${BUILD_DIR}/mmu_init.o" "${BUILD_DIR}/context_switch.o" \
  "${BUILD_DIR}/irq_entry.o" "${BUILD_DIR}/vectors.o" \
  "${BUILD_DIR}/sdcard_state.o" "${BUILD_DIR}/dharafs_buf.o" \
  "${BUILD_DIR}/dharafs_state.o" "${BUILD_DIR}/shell_state.o" \
  "${BUILD_DIR}/governor_state.o" "${BUILD_DIR}/netif_state.o" \
  "${BUILD_DIR}/arp_state.o" "${BUILD_DIR}/scratch_state.o" \
  "${BUILD_DIR}/tcp_state.o" "${BUILD_DIR}/dhcp_state.o" \
  "${BUILD_DIR}/usb_msd_state.o" \
  "${BUILD_DIR}/usb_net_state.o" \
  "${BUILD_DIR}/usb_bt_state.o" \
  "${BUILD_DIR}/usb_wifi_state.o" \
  "${BUILD_DIR}/fw_state.o" \
  "${BUILD_DIR}/auth_state.o" \
  "${BUILD_DIR}/media_crypto_state.o" \
  "${BUILD_DIR}/fault_inject_state.o" \
  "${BUILD_DIR}/diag_ring_state.o" \
  "${BUILD_DIR}/gatt_state.o" \
  "${BUILD_DIR}/kernel_main.o" "${BUILD_DIR}/runtime_stubs.o" \
  -lgcc \
  -o "${BUILD_DIR}/dhruva.elf"

echo "Built ${BUILD_DIR}/dhruva.elf"
echo "Run under QEMU: python3 ${ROOT}/test/qemu_run.py ${BUILD_DIR}/dhruva.elf"
