#!/usr/bin/env bash
# Dhruva round 43 -- Raspberry Pi 4 (BCM2711) AArch64 boot skeleton
# build: boot.S + vectors.S -> dhruva_rpi4.elf, bootable under
# `qemu-system-aarch64 -M raspi4b` with zero physical hardware.
#
# Deliberately a SEPARATE script from build.sh, not a flag on it: this
# targets a completely different instruction set (AArch64 vs. this
# project's exclusively-ARM32-until-now Pi 1 target) and a different
# cross-compiler triple. Merging the two build paths into one script
# would buy nothing but a pile of target-specific conditionals;
# keeping them separate mirrors how cleanly the two targets' actual
# toolchains don't share anything below the shell script calling them.
#
# ROUND 74 UPDATE: first vani-compiled kernel piece on this port
# (kernel/kernel_main_rpi4.vani) -- same `vanic emit --backend=llvm`
# + `llc -mtriple=` + runtime-stub-object pipeline build.sh's own
# comment already documents for the Pi 1/ARMv6 target, just with an
# aarch64 triple and a smaller stub set (no libgcc divide helper
# needed -- AArch64 has hardware SDIV/UDIV). `-function-sections`/
# `-data-sections` + `--gc-sections` are load-bearing here for the
# exact same reason build.sh's own comment documents: vani's LLVM
# emission always includes its entire builtin-runtime helper library
# regardless of whether the program actually calls any of it, and
# only per-symbol sections let the linker prune by real reachability.
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
VANIC="${VANIC:-/home/virgo/source/vani-compiler/target/release/vanic}"
TRIPLE="aarch64-none-elf"

mkdir -p "${BUILD_DIR}"

"${CC}" -c -mgeneral-regs-only -ffreestanding \
  "${ROOT}/boot/rpi4/boot.S" -o "${BUILD_DIR}/rpi4_boot.o"

"${CC}" -c -mgeneral-regs-only -ffreestanding \
  "${ROOT}/boot/rpi4/vectors.S" -o "${BUILD_DIR}/rpi4_vectors.o"

"${CC}" -c -mgeneral-regs-only -ffreestanding \
  "${ROOT}/boot/rpi4/gic_timer.S" -o "${BUILD_DIR}/rpi4_gic_timer.o"

"${CC}" -c -mgeneral-regs-only -ffreestanding \
  "${ROOT}/boot/rpi4/mmu_init.S" -o "${BUILD_DIR}/rpi4_mmu_init.o"

"${CC}" -c -mgeneral-regs-only -ffreestanding \
  "${ROOT}/boot/rpi4/task_switch.S" -o "${BUILD_DIR}/rpi4_task_switch.o"

"${CC}" -c -mgeneral-regs-only -ffreestanding \
  "${ROOT}/boot/rpi4/preempt_switch.S" -o "${BUILD_DIR}/rpi4_preempt_switch.o"

"${CC}" -c -mgeneral-regs-only -ffreestanding \
  "${ROOT}/boot/rpi4/shell_state.S" -o "${BUILD_DIR}/rpi4_shell_state.o"

"${CC}" -c -mgeneral-regs-only -ffreestanding \
  "${ROOT}/boot/rpi4/netif_state.S" -o "${BUILD_DIR}/rpi4_netif_state.o"

"${CC}" -c -mgeneral-regs-only -ffreestanding \
  "${ROOT}/boot/rpi4/arp_state.S" -o "${BUILD_DIR}/rpi4_arp_state.o"

"${CC}" -c -mgeneral-regs-only -ffreestanding \
  "${ROOT}/boot/rpi4/filter_state.S" -o "${BUILD_DIR}/rpi4_filter_state.o"

"${CC}" -c -mgeneral-regs-only -ffreestanding \
  "${ROOT}/boot/rpi4/tcp_state.S" -o "${BUILD_DIR}/rpi4_tcp_state.o"

"${CC}" -c -mgeneral-regs-only -ffreestanding \
  "${ROOT}/boot/rpi4/dhcp_state.S" -o "${BUILD_DIR}/rpi4_dhcp_state.o"

"${CC}" -c -mgeneral-regs-only -ffreestanding \
  "${ROOT}/boot/rpi4/dhcp_server_state.S" -o "${BUILD_DIR}/rpi4_dhcp_server_state.o"

"${CC}" -c -mgeneral-regs-only -ffreestanding \
  "${ROOT}/boot/rpi4/netconfig_state.S" -o "${BUILD_DIR}/rpi4_netconfig_state.o"

"${CC}" -c -nostdlib -ffreestanding \
  "${ROOT}/boot/rpi4/runtime_stubs_rpi4.c" -o "${BUILD_DIR}/rpi4_runtime_stubs.o"

"${VANIC}" emit "${ROOT}/kernel/kernel_main_rpi4.vani" --backend=llvm \
  -o "${BUILD_DIR}/kernel_main_rpi4.ll"

llc -mtriple="${TRIPLE}" -filetype=obj \
  -function-sections -data-sections \
  "${BUILD_DIR}/kernel_main_rpi4.ll" -o "${BUILD_DIR}/kernel_main_rpi4.o"

"${CC}" -nostdlib -ffreestanding -static \
  -Wl,--gc-sections \
  -Wl,-T,"${ROOT}/boot/rpi4/link.ld" \
  "${BUILD_DIR}/rpi4_boot.o" "${BUILD_DIR}/rpi4_vectors.o" \
  "${BUILD_DIR}/rpi4_gic_timer.o" "${BUILD_DIR}/rpi4_mmu_init.o" \
  "${BUILD_DIR}/rpi4_task_switch.o" "${BUILD_DIR}/rpi4_preempt_switch.o" \
  "${BUILD_DIR}/rpi4_shell_state.o" "${BUILD_DIR}/rpi4_netif_state.o" \
  "${BUILD_DIR}/rpi4_arp_state.o" "${BUILD_DIR}/rpi4_filter_state.o" \
  "${BUILD_DIR}/rpi4_tcp_state.o" "${BUILD_DIR}/rpi4_dhcp_state.o" \
  "${BUILD_DIR}/rpi4_dhcp_server_state.o" "${BUILD_DIR}/rpi4_netconfig_state.o" \
  "${BUILD_DIR}/kernel_main_rpi4.o" "${BUILD_DIR}/rpi4_runtime_stubs.o" \
  -o "${BUILD_DIR}/dhruva_rpi4.elf"

echo "Built ${BUILD_DIR}/dhruva_rpi4.elf"
echo "Run under QEMU: python3 ${ROOT}/test/rpi4_boot_smoke.py ${BUILD_DIR}/dhruva_rpi4.elf"
