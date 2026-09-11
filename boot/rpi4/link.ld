/* Dhruva round 43 -- Raspberry Pi 4 (BCM2711, AArch64) linker script.
 *
 * 0x80000 matches the standard Linux arm64 "Image" kernel load
 * address -- also what round 40's throwaway spike used and confirmed
 * QEMU's raspi4b -kernel path accepts directly for a raw ELF, the
 * same convention this project's Pi 1 side already relies on (see
 * boot/rpi1/link.ld's own comment on 0x8000 there for the parallel).
 */

ENTRY(_start)

SECTIONS
{
    . = 0x80000;

    .text.boot : { *(.text.boot) }

    /* VBAR_EL1's low 11 bits are RES0 -- the vector table must start
     * on a 2KB boundary or the CPU silently truncates the address,
     * dispatching every exception to the wrong handler. ALIGN here
     * (not just vectors.S's own .align 11 directive) is what actually
     * guarantees this section lands on a 2KB-aligned LINK ADDRESS,
     * not just that its own content is internally aligned relative to
     * wherever the linker happens to place it. */
    . = ALIGN(0x800);
    .vectors : { KEEP(*(.vectors)) }

    .text : { *(.text*) }
    .rodata : { *(.rodata*) }

    /* Round 73: 2MB ALIGN, not just 16 -- boot/rpi4/mmu_init.S's
     * identity map uses 2MB block descriptors (this format's finest
     * granularity without a 3rd-level 4KB-page table this kernel
     * doesn't need yet), and gives the .text.boot/.vectors/.text/
     * .rodata block above read+execute-never-write permissions while
     * everything from here on is read+write-never-execute. Without
     * this, .data could land in the SAME 2MB block as code, forcing
     * one permission set on both -- exactly the problem boot/
     * mmu_init.S's own 1MB ALIGN before .data already solves for the
     * ARMv6 target, just at this format's 2MB granularity instead. */
    . = ALIGN(0x200000);
    .data : { *(.data*) }

    . = ALIGN(16);
    __bss_start = .;
    .bss : { *(.bss*) *(COMMON) }
    __bss_end = .;

    /* 64KB boot stack for EL1, growing down from _stack_top -- bumped
     * from the original 16KB (round 43/74's own size class, matching
     * boot/rpi1/link.ld's own main task stack) after round 166 found
     * a real, vani-compiler-`stack-depth`-CONFIRMED overflow: the
     * real call chain kmain_rpi4_vani -> tls_self_test_rpi4 ->
     * tls_decrypt_record_rpi4 -> chacha20_poly1305_decrypt ->
     * chacha20_encrypt -> cp_zero512_bytes -> cp_zero256_bytes needs
     * 27032 bytes -- 10648 bytes OVER the old 16KB budget, silently
     * corrupting whatever memory sits past the stack's own bottom
     * (this board's own boot stack has no guard page). `vanic
     * stack-depth kernel/kernel_main_rpi4.vani --entry=kmain_rpi4_vani
     * --max=<N>` is the tool that found this -- re-run it after any
     * future round adds a deep new call chain, rather than
     * discovering the ceiling via a live corruption bug again. Same
     * "map/allocate more, don't shrink working code to fit an
     * arbitrary old limit" philosophy as round 71's GPU-RAM fix and
     * round 108's own ARM-RAM-mapping fix on the Pi 1 side -- Pi 4/5's
     * own 2GB of real RAM (already generously mapped by mmu_init.S)
     * makes a 4x stack bump costless. No separate IRQ/Abort-mode
     * stacks yet (AArch64 has no banked-per-mode SP the way ARM32
     * does -- SP_EL1 is the only stack pointer this v1 kernel needs,
     * since it runs entirely at EL1 with interrupts masked; a future
     * round enabling real interrupts will need to decide whether EL1
     * exceptions share this stack or get their own, once there's an
     * actual handler that does meaningful work instead of just
     * reporting and halting). */
    . = ALIGN(16);
    . = . + 0x10000;
    _stack_top = .;
}
